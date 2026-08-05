import Foundation

/// The persistence half of the inventory engine: read the facts ``InventoryPosting`` needs, write
/// what it decided, all in ONE transaction.
///
/// No accounting decision is taken in this file. Every refusal it raises is either a lookup that
/// failed (`productNotFound`, `reversalTargetNotFound`) or a structural rule about the ledger's
/// shape (`onlyTheLastMovementCanBeReversed`); the costing, the guards and the arithmetic are all
/// in the pure state machine, where they can be property-tested without a database.
///
/// ## One product at a time, always (N-9 / audit G23)
///
/// EVERY statement here filters on `product_id`. Quantities of different products are in different
/// units, so an aggregate across products is meaningless — there is deliberately no query in this
/// file that could produce one, and `InventoryLedgerTests` asserts that mechanically over the
/// source rather than trusting the reading.
///
/// ## Reversed pairs do not exist
///
/// A reversal is an appended row pointing at what it undoes; nothing is ever deleted. Every read
/// that asks "what is true now" uses ``liveInventoryMovements(productID:)``, which drops the
/// reversed row AND its reversal together. That one definition is what makes D-5 work after a
/// mis-keyed opening is reversed, and what makes the reversal replay land on the right state.
public extension LedgerStore {

    // MARK: - Reads

    /// The stored running balance, or an empty one for a product that has never been posted to.
    func inventoryBalance(productID: String) throws -> InventoryBalance {
        let rows = try db.query("""
            SELECT product_id, quantity_milli, cost_balance_minor, unit_cost_micro, currency,
                   last_movement_id, last_occurred_on, last_seq
              FROM inventory_balances WHERE product_id = ?
            """, [.text(productID)])
        guard let row = rows.first else { return .empty(productID: productID) }
        return InventoryBalance(
            productID: row.string("product_id") ?? productID,
            quantityMilli: Int64(row.int("quantity_milli") ?? 0),
            costBalanceMinor: Int64(row.int("cost_balance_minor") ?? 0),
            unitCostMicro: Int64(row.int("unit_cost_micro") ?? 0),
            currency: row.string("currency"),
            lastMovementID: row.string("last_movement_id"),
            lastOccurredOn: row.string("last_occurred_on"),
            lastSeq: row.int("last_seq").map(Int64.init))
    }

    /// Every movement of one product, reversed pairs INCLUDED, in `(occurred_on, seq)` order.
    /// This is the audit view — nothing is ever removed from it.
    func inventoryMovements(productID: String) throws -> [InventoryPostedMovement] {
        try decodeMovements(try db.query("""
            \(Self.inventoryMovementColumns)
              FROM inventory_movements m WHERE m.product_id = ?
             ORDER BY m.occurred_on, m.seq
            """, [.text(productID)]))
    }

    /// The movements that still count: neither reversed nor a reversal.
    func liveInventoryMovements(productID: String) throws -> [InventoryPostedMovement] {
        try decodeMovements(try db.query("""
            \(Self.inventoryMovementColumns)
              FROM inventory_movements m
             WHERE m.product_id = ?
               AND m.reverses_id IS NULL
               AND NOT EXISTS (SELECT 1 FROM inventory_movements r
                                WHERE r.product_id = ? AND r.reverses_id = m.id)
             ORDER BY m.occurred_on, m.seq
            """, [.text(productID), .text(productID)]))
    }

    func inventoryExceptions(productID: String) throws -> [InventoryException] {
        try db.query("""
            SELECT id, product_id, movement_id, kind, detail
              FROM inventory_exceptions WHERE product_id = ? ORDER BY id
            """, [.text(productID)]).compactMap { row in
            guard let id = row.string("id"),
                  let raw = row.string("kind"),
                  let kind = InventoryExceptionKind(rawValue: raw) else { return nil }
            return InventoryException(id: id, productID: row.string("product_id"),
                                      movementID: row.string("movement_id"), kind: kind,
                                      detail: row.string("detail"))
        }
    }

    // MARK: - Post

    /// Plan one movement and commit it: the row, the balance it produces, and the exception the
    /// ruling attaches to it, in a single transaction. Returns the row as stored.
    ///
    /// A refusal writes NOTHING — the guards all run before `BEGIN`, and the transaction rolls back
    /// on any failure inside it, so a rejected posting leaves the balance byte-identical.
    @discardableResult
    func postInventoryMovement(_ request: InventoryPostingRequest) throws -> InventoryPostedMovement {
        guard try inventoryProductExists(request.productID) else { throw InventoryPostingError.productNotFound }

        let balance = try inventoryBalance(productID: request.productID)
        let context = InventoryPostingContext(
            hasLiveMovements: try liveInventoryMovements(productID: request.productID).isEmpty == false,
            origin: try originFacts(for: request),
            seq: try nextInventorySeq(productID: request.productID, occurredOn: request.occurredOn),
            movementID: Self.newInventoryMovementID())

        let plan = try InventoryPosting.plan(request: request, balance: balance, context: context)

        try withInventoryStorageMapping {
            try db.transaction {
                try insert(plan.movement)
                try upsert(plan.balance)
                if let kind = plan.exception {
                    try insertException(kind: kind, productID: request.productID,
                                        movementID: plan.movement.id)
                }
            }
        }
        return plan.movement
    }

    /// Reverse the product's LAST live movement (F2 案 a).
    ///
    /// Earlier mistakes are corrected by posting FORWARD — a stock count, a return, a cost
    /// adjustment — never by rewriting history. That restriction is what makes the reversal's
    /// landing state well-defined: it is a state the ledger actually passed through.
    ///
    /// The balance afterwards is REBUILT by replaying the remaining live rows, not by subtracting
    /// this one. N-1 freezes the average across average-priced issues, so the average is a state
    /// rather than a function of `(quantity, cost)`, and subtracting restores the pair but not the
    /// average — measured, and pinned by the two regression tests named for it.
    @discardableResult
    func reverseInventoryMovement(id targetID: String, occurredOn: String,
                                  note: String? = nil) throws -> InventoryPostedMovement {
        guard let target = try inventoryMovementRow(id: targetID) else {
            throw InventoryPostingError.reversalTargetNotFound
        }
        // A reversal is not itself reversible: undoing an undo is a FORWARD posting, which is the
        // same rule as everywhere else here.
        guard !target.isReversal else { throw InventoryPostingError.onlyTheLastMovementCanBeReversed }
        let live = try liveInventoryMovements(productID: target.productID)
        guard live.contains(where: { $0.id == targetID }) else {
            throw InventoryPostingError.movementAlreadyReversed
        }
        guard live.last?.id == targetID else { throw InventoryPostingError.onlyTheLastMovementCanBeReversed }
        if occurredOn < target.occurredOn { throw InventoryPostingError.backdatedNotSupported }

        let productID = target.productID
        let reversal = InventoryPosting.reversalRow(
            target: target,
            id: Self.newInventoryMovementID(),
            occurredOn: occurredOn,
            seq: try nextInventorySeq(productID: productID, occurredOn: occurredOn),
            note: note)

        // The pair cancels, so the state is whatever the REMAINING live rows fold to.
        let remaining = live.filter { $0.id != targetID }
        let replayed = try InventoryPosting.replay(remaining, productID: productID)
        // …but the backdating baseline moves FORWARD to the reversal itself: it is the newest row
        // in the ledger, and N-6 measures against the newest row, not against the newest row that
        // still counts.
        let balance = InventoryBalance(productID: productID,
                                       quantityMilli: replayed.quantityMilli,
                                       costBalanceMinor: replayed.costBalanceMinor,
                                       unitCostMicro: replayed.unitCostMicro,
                                       currency: replayed.currency,
                                       lastMovementID: reversal.id,
                                       lastOccurredOn: reversal.occurredOn,
                                       lastSeq: reversal.seq)

        try withInventoryStorageMapping {
            try db.transaction {
                try insert(reversal)
                try upsert(balance)
            }
        }
        return reversal
    }
}

// MARK: - Internals

private extension LedgerStore {

    static var inventoryMovementColumns: String {
        """
        SELECT m.id AS id, m.product_id AS product_id, m.occurred_on AS occurred_on, m.seq AS seq,
               m.movement_type AS movement_type, m.quantity_milli AS quantity_milli,
               m.unit_cost_micro AS unit_cost_micro, m.total_cost_minor AS total_cost_minor,
               m.currency AS currency, m.source_type AS source_type, m.source_id AS source_id,
               m.reverses_id AS reverses_id, m.note AS note
        """
    }

    static func newInventoryMovementID() -> String { "invm-\(UUID().uuidString.lowercased())" }
    static func newInventoryExceptionID() -> String { "invx-\(UUID().uuidString.lowercased())" }

    func decodeMovements(_ rows: [SQLiteRow]) throws -> [InventoryPostedMovement] {
        try rows.map { row in
            guard let id = row.string("id"),
                  let productID = row.string("product_id"),
                  let rawType = row.string("movement_type"),
                  let type = InventoryMovementType(rawValue: rawType),
                  let occurredOn = row.string("occurred_on") else {
                // A row the engine wrote always decodes. One that does not is a tampered or
                // foreign write, and inventing a movement out of it would be worse than refusing.
                throw InventoryPostingError.ledgerInconsistent
            }
            return InventoryPostedMovement(
                id: id,
                productID: productID,
                type: type,
                occurredOn: occurredOn,
                seq: Int64(row.int("seq") ?? 0),
                quantityMilli: Int64(row.int("quantity_milli") ?? 0),
                unitCostMicro: row.int("unit_cost_micro").map(Int64.init),
                totalCostMinor: row.int("total_cost_minor").map(Int64.init),
                currency: row.string("currency") ?? "",
                sourceType: row.string("source_type"),
                sourceID: row.string("source_id"),
                reversesID: row.string("reverses_id"),
                note: row.string("note"))
        }
    }

    func inventoryProductExists(_ id: String) throws -> Bool {
        try db.query("SELECT 1 AS present FROM products WHERE id = ?", [.text(id)]).isEmpty == false
    }

    /// One movement by id. The only query here not scoped to a product — it is a primary-key
    /// lookup, so it reaches exactly one row and cannot aggregate across products (P8).
    func inventoryMovementRow(id: String) throws -> InventoryPostedMovement? {
        try decodeMovements(try db.query("""
            \(Self.inventoryMovementColumns) FROM inventory_movements m WHERE m.id = ?
            """, [.text(id)])).first
    }

    /// D-4 — the engine assigns `seq`, monotonically within `(product, date)`. A caller cannot
    /// pass one: the moving average is order-dependent, so choosing the order is choosing the
    /// answer. The v24 unique index on `(product_id, occurred_on, seq)` is the enforcement.
    func nextInventorySeq(productID: String, occurredOn: String) throws -> Int64 {
        let row = try db.query("""
            SELECT COALESCE(MAX(seq), 0) AS top FROM inventory_movements
             WHERE product_id = ? AND occurred_on = ?
            """, [.text(productID), .text(occurredOn)]).first
        return Int64(row?.int("top") ?? 0) + 1
    }

    /// N-4 / D-11 — find the document a return points at, and how much of it has come back already.
    ///
    /// The counterpart is the movement kind the return undoes: a customer return points at the
    /// issue, a supplier return at the receipt. Only LIVE rows count on both sides, so a reversed
    /// sale is not a findable origin and a reversed return does not consume the ceiling.
    func originFacts(for request: InventoryPostingRequest) throws -> InventoryOriginFacts? {
        guard request.type.isReturn,
              let sourceType = request.sourceType, let sourceID = request.sourceID,
              !sourceType.isEmpty, !sourceID.isEmpty else { return nil }

        let originType: InventoryMovementType = request.type == .saleReturnIn ? .saleOut : .purchaseIn
        let live = try liveInventoryMovements(productID: request.productID)
        guard let origin = live.first(where: {
            $0.type == originType && $0.sourceType == sourceType && $0.sourceID == sourceID
        }) else { return nil }

        let alreadyReturned = live
            .filter { $0.type == request.type && $0.sourceType == sourceType && $0.sourceID == sourceID }
            .reduce(Int64(0)) { $0 + $1.quantityMilli }

        // A sale carries no unit price of its own (it was costed at the average), so the price to
        // restore is the one the sale actually took out, per unit — N-4's "the cost the sale
        // removed", not today's average.
        let unitCost: Int64
        if let stated = origin.unitCostMicro {
            unitCost = stated
        } else {
            unitCost = try InventoryPosting.averageMicro(costMinor: origin.totalCostMinor ?? 0,
                                                         quantityMilli: origin.quantityMilli)
        }
        return InventoryOriginFacts(quantityMilli: origin.quantityMilli,
                                    unitCostMicro: unitCost,
                                    alreadyReturnedMilli: alreadyReturned)
    }

    func insert(_ movement: InventoryPostedMovement) throws {
        try db.run("""
            INSERT INTO inventory_movements
              (id, product_id, occurred_on, seq, movement_type, quantity_milli, unit_cost_micro,
               total_cost_minor, currency, source_type, source_id, reverses_id, note)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [.text(movement.id), .text(movement.productID), .text(movement.occurredOn),
                  .integer(movement.seq), .text(movement.type.rawValue),
                  .integer(movement.quantityMilli),
                  movement.unitCostMicro.map { SQLiteValue.integer($0) } ?? .null,
                  movement.totalCostMinor.map { SQLiteValue.integer($0) } ?? .null,
                  .text(movement.currency),
                  movement.sourceType.map { SQLiteValue.text($0) } ?? .null,
                  movement.sourceID.map { SQLiteValue.text($0) } ?? .null,
                  movement.reversesID.map { SQLiteValue.text($0) } ?? .null,
                  movement.note.map { SQLiteValue.text($0) } ?? .null])
    }

    func upsert(_ balance: InventoryBalance) throws {
        try db.run("""
            INSERT INTO inventory_balances
              (product_id, quantity_milli, cost_balance_minor, unit_cost_micro, currency,
               last_movement_id, last_occurred_on, last_seq, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, datetime('now'))
            ON CONFLICT(product_id) DO UPDATE SET
              quantity_milli = excluded.quantity_milli,
              cost_balance_minor = excluded.cost_balance_minor,
              unit_cost_micro = excluded.unit_cost_micro,
              currency = excluded.currency,
              last_movement_id = excluded.last_movement_id,
              last_occurred_on = excluded.last_occurred_on,
              last_seq = excluded.last_seq,
              updated_at = datetime('now')
            """, [.text(balance.productID), .integer(balance.quantityMilli),
                  .integer(balance.costBalanceMinor), .integer(balance.unitCostMicro),
                  balance.currency.map { SQLiteValue.text($0) } ?? .null,
                  balance.lastMovementID.map { SQLiteValue.text($0) } ?? .null,
                  balance.lastOccurredOn.map { SQLiteValue.text($0) } ?? .null,
                  balance.lastSeq.map { SQLiteValue.integer($0) } ?? .null])
    }

    func insertException(kind: InventoryExceptionKind, productID: String, movementID: String) throws {
        try db.run("""
            INSERT INTO inventory_exceptions (id, product_id, movement_id, kind, detail)
            VALUES (?, ?, ?, ?, NULL)
            """, [.text(Self.newInventoryExceptionID()), .text(productID), .text(movementID),
                  .text(kind.rawValue)])
    }

    /// Keep raw SQLite text out of the engine's error surface, the same way the product catalog
    /// does. A foreign-key failure means one thing here — the product is gone — because
    /// `inventory_movements.product_id` is the only foreign key these tables have.
    func withInventoryStorageMapping(_ body: () throws -> Void) throws {
        do {
            try body()
        } catch let error as InventoryPostingError {
            throw error
        } catch let error as SQLiteError {
            guard case .step(let message) = error else { throw InventoryPostingError.storageFailure }
            throw message.contains("FOREIGN KEY") ? InventoryPostingError.productNotFound
                                                  : InventoryPostingError.storageFailure
        } catch {
            throw InventoryPostingError.storageFailure
        }
    }
}
