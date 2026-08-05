import Foundation

/// The moving-average state machine — PURE. No database, no clock, no randomness.
///
/// Everything that decides an accounting outcome lives here, so all of it can be property-tested
/// and mutation-tested without SQLite in the way. `InventoryLedger` supplies the facts this cannot
/// read for itself (does the product have live movements, what did the origin document carry, what
/// `seq` comes next) and persists what this returns.
///
/// ## Three entry points, and why they are separate
///
///  * ``plan(request:balance:context:)`` — decides the cost basis and runs every guard. This is
///    where N-1/N-4/N-5/N-6/N-7/D-1/D-5/D-10/D-11 and the F1 guards are enforced.
///  * ``apply(_:to:)`` — folds an ALREADY-COSTED row into a balance. Total and deterministic; it
///    re-derives nothing, so replaying stored rows and posting them live cannot disagree.
///  * ``replay(_:productID:)`` — folds a whole history. Reversal uses it (F2/G1), and the property
///    tests use it as an independent oracle against the incremental path.
///
/// ## Why reversal replays instead of subtracting (G1)
///
/// N-1 freezes the unit cost across average-priced issues, so the average is a STATE and not a
/// function of `(quantity, cost)`. Restoring the pair therefore does not restore the average:
///
/// ```
/// buy 3 units / 1000 minor →  (qty 3000, cost 1000, u 333_333_333)
/// sell 1 unit, flow 333    →  (qty 2000, cost  667, u 333_333_333)   ← the state to restore
/// sell 2 units, flow 667   →  (qty    0, cost    0, u           0)   ← N-2 zeroing
/// reverse that sale, by subtraction → (qty 2000, cost 667, u 333_500_000)   ✗ off by 166_667
/// ```
///
/// The same happens when reversing a RECEIPT — it has nothing to do with selling out. So a
/// reversal drops the reversed pair and rebuilds from the remaining rows, which reproduces the
/// state bit-for-bit because ``apply`` is deterministic.
///
/// This is not the recomputation N-6 defers. N-6 refuses to insert a movement into the middle of
/// history and re-derive everything after it; this inserts nothing, rewrites no posted row, and
/// lands on a state that already existed.
///
/// ## Rounding (N-8 derived prohibition)
///
/// Nothing here calls `ReportMath.round` / `round2`. Those mirror JavaScript's `Math.round`
/// (ties toward +∞) and exist to reproduce report goldens; inventory truncates toward zero per
/// D-3 and the two must stay visibly separate in the source. The only rounding in this file is
/// integer division, written out at ``averageMicro(costMinor:quantityMilli:)``.
public enum InventoryPosting {

    /// The bridge between the three integer scales: `quantityMilli × unitCostMicro / 1e9`.
    static let scaleBridge: Int64 = 1_000_000_000

    // MARK: - Arithmetic (N-8 / N1 §2.4)

    /// `quantityMilli × unitCostMicro / 1e9`, truncated toward zero.
    ///
    /// REFUSES on overflow rather than wrapping. The ceiling is real and worth knowing: the
    /// product must stay inside Int64, i.e. roughly 9.2 × 10⁹ minor units of line cost.
    static func costOfQuantity(quantityMilli: Int64, unitCostMicro: Int64) throws -> Int64 {
        let (product, overflow) = quantityMilli.multipliedReportingOverflow(by: unitCostMicro)
        guard !overflow else { throw InventoryPostingError.arithmeticOverflow }
        return product / scaleBridge          // both operands ≥ 0 → toward zero == floor
    }

    /// `costMinor × 1e9 / quantityMilli`, truncated toward zero — D-3.
    ///
    /// D-3 puts the remainder in the COST BALANCE, not in the average: the balance stays the
    /// conserved quantity (P2 is an exact equality) and the average is the derived approximation.
    /// That is the choice this one truncation encodes.
    static func averageMicro(costMinor: Int64, quantityMilli: Int64) throws -> Int64 {
        guard quantityMilli > 0 else { return 0 }
        let (numerator, overflow) = costMinor.multipliedReportingOverflow(by: scaleBridge)
        guard !overflow else { throw InventoryPostingError.arithmeticOverflow }
        return numerator / quantityMilli
    }

    static func addChecked(_ a: Int64, _ b: Int64) throws -> Int64 {
        let (sum, overflow) = a.addingReportingOverflow(b)
        guard !overflow else { throw InventoryPostingError.arithmeticOverflow }
        return sum
    }

    // MARK: - Fold (deterministic, total)

    /// Fold one POSTED row into a balance.
    ///
    /// Reversal rows never reach here: a reversed pair is excluded wholesale by ``replay(_:productID:)``
    /// and by the ledger's live-row queries, which is what makes "a reversed pair does not exist"
    /// one rule rather than a special case in every caller.
    public static func apply(_ movement: InventoryPostedMovement,
                             to balance: InventoryBalance) throws -> InventoryBalance {
        precondition(!movement.isReversal, "a reversal row is excluded from folding, never folded")
        let recorded = movement.totalCostMinor ?? 0

        switch movement.type.direction {

        case .costOnly:
            // F1 案丙. Both guards are the engine's, not the schema's: `total_cost_minor` has no
            // sign constraint and `quantity_milli` has no CHECK, so nothing below would catch these.
            guard movement.quantityMilli == 0 else { throw InventoryPostingError.manualAdjustMustNotMoveQuantity }
            guard balance.quantityMilli > 0 else { throw InventoryPostingError.manualAdjustRequiresStock }
            let newCost = try addChecked(balance.costBalanceMinor, recorded)
            guard newCost >= 0 else { throw InventoryPostingError.costBalanceWouldGoNegative }
            return InventoryBalance(
                productID: balance.productID,
                quantityMilli: balance.quantityMilli,
                costBalanceMinor: newCost,
                unitCostMicro: try averageMicro(costMinor: newCost, quantityMilli: balance.quantityMilli),
                currency: balance.currency ?? movement.currency,
                lastMovementID: movement.id,
                lastOccurredOn: movement.occurredOn,
                lastSeq: movement.seq)

        case .inbound:
            guard movement.quantityMilli > 0 else { throw InventoryPostingError.quantityMustBePositive }
            guard recorded >= 0 else { throw InventoryPostingError.ledgerInconsistent }
            let newQty = try addChecked(balance.quantityMilli, movement.quantityMilli)
            let newCost = try addChecked(balance.costBalanceMinor, recorded)
            // N-1: the receipt IS the moment the average is recomputed.
            return InventoryBalance(
                productID: balance.productID,
                quantityMilli: newQty,
                costBalanceMinor: newCost,
                unitCostMicro: try averageMicro(costMinor: newCost, quantityMilli: newQty),
                currency: balance.currency ?? movement.currency,
                lastMovementID: movement.id,
                lastOccurredOn: movement.occurredOn,
                lastSeq: movement.seq)

        case .outbound:
            guard movement.quantityMilli > 0 else { throw InventoryPostingError.quantityMustBePositive }
            guard recorded >= 0 else { throw InventoryPostingError.ledgerInconsistent }
            guard movement.quantityMilli <= balance.quantityMilli else { throw InventoryPostingError.insufficientStock }
            let newQty = balance.quantityMilli - movement.quantityMilli
            let newCost = balance.costBalanceMinor - recorded
            guard newCost >= 0 else { throw InventoryPostingError.ledgerInconsistent }

            let newUnitCost: Int64
            if newQty == 0 {
                // N-2. The planner sizes a zeroing issue's flow as the WHOLE remaining balance, so
                // this holds by construction; a stored row that says otherwise is a corrupt ledger
                // and is refused rather than published as `qty == 0 ∧ cost != 0`.
                guard newCost == 0 else { throw InventoryPostingError.ledgerInconsistent }
                newUnitCost = 0
            } else if movement.type.isAveragePricedOutbound {
                newUnitCost = balance.unitCostMicro       // N-1 / P5: an issue does not move it
            } else {
                // `purchaseReturnOut` removed stock at the ORIGIN's price, not the average, so the
                // average of what remains genuinely changed and has to be re-derived (N-4).
                newUnitCost = try averageMicro(costMinor: newCost, quantityMilli: newQty)
            }
            return InventoryBalance(
                productID: balance.productID,
                quantityMilli: newQty,
                costBalanceMinor: newCost,
                unitCostMicro: newUnitCost,
                currency: balance.currency ?? movement.currency,
                lastMovementID: movement.id,
                lastOccurredOn: movement.occurredOn,
                lastSeq: movement.seq)
        }
    }

    /// Fold a whole history, in `(occurredOn, seq)` order.
    ///
    /// `movements` must be the product's LIVE rows — reversed pairs already removed. Sorting here
    /// rather than trusting the caller's order keeps the function's result a property of the SET,
    /// which is what lets the property tests use it as an oracle for the incremental path.
    public static func replay(_ movements: [InventoryPostedMovement],
                              productID: String) throws -> InventoryBalance {
        var balance = InventoryBalance.empty(productID: productID)
        for movement in movements.sorted(by: { $0.orderKey < $1.orderKey }) {
            guard movement.productID == productID else { throw InventoryPostingError.ledgerInconsistent }
            guard !movement.isReversal else { throw InventoryPostingError.ledgerInconsistent }
            balance = try apply(movement, to: balance)
        }
        return balance
    }

    // MARK: - Plan (every guard lives here)

    /// Decide the cost basis, run every refusal, and return the row to write plus the balance that
    /// follows it.
    public static func plan(request: InventoryPostingRequest,
                            balance: InventoryBalance,
                            context: InventoryPostingContext) throws -> InventoryPostingPlan {
        guard !request.productID.isEmpty, request.productID == balance.productID else {
            throw InventoryPostingError.productNotFound
        }
        guard !request.currency.isEmpty else { throw InventoryPostingError.currencyMismatch }

        // D-1 — the first receipt freezes the currency; a later one in another currency is refused
        // outright. No rate is applied anywhere in this engine, deliberately.
        if let held = balance.currency, held != request.currency {
            throw InventoryPostingError.currencyMismatch
        }

        // N-6 — dated before the last posted movement. `seq` is the engine's (D-4), so a same-day
        // movement always sorts after and needs no comparison of its own.
        if let last = balance.lastOccurredOn, request.occurredOn < last {
            throw InventoryPostingError.backdatedNotSupported
        }

        // D-5 — an opening must be the product's first LIVE movement. "Live" is what lets a
        // mis-keyed opening be reversed and re-entered; a reversed pair does not exist.
        if request.type == .opening && context.hasLiveMovements {
            throw InventoryPostingError.openingMustBeFirst
        }

        let exception: InventoryExceptionKind?
        let movement: InventoryPostedMovement

        switch request.type.direction {

        case .costOnly:
            // Only the guard `apply` cannot express lives here: an ABSENT amount is different from
            // a zero one, and by the time a row exists the difference is gone. The other three
            // F1 rules (no quantity, stock must exist, the balance may not go negative) are
            // enforced once, in `apply`, and the request's quantity is passed through UNCHANGED so
            // that a caller supplying one is refused rather than silently normalised to zero.
            guard let delta = request.costDeltaMinor else { throw InventoryPostingError.netAmountRequired }
            movement = row(request, context, quantityMilli: request.quantityMilli,
                           unitCostMicro: nil, totalCostMinor: delta)
            exception = .manualAdjust

        case .inbound:
            guard request.quantityMilli > 0 else { throw InventoryPostingError.quantityMustBePositive }
            if request.type.isReturn {
                // N-4 — a sale coming back is costed at what the sale took out, when the origin is
                // findable; otherwise at the current average, flagged.
                let (unitCost, flagged) = try returnBasis(request: request, balance: balance, context: context)
                movement = row(request, context, quantityMilli: request.quantityMilli,
                               unitCostMicro: unitCost,
                               totalCostMinor: try costOfQuantity(quantityMilli: request.quantityMilli,
                                                                  unitCostMicro: unitCost))
                exception = flagged ? .returnOriginNotFound : nil
            } else {
                // N-7 — purchase / count-gain / opening must carry their own tax-exclusive price.
                // A count gain may NOT quietly borrow the average: that would invent a cost.
                guard let unitCost = request.unitCostMicro else { throw InventoryPostingError.netAmountRequired }
                guard unitCost >= 0 else { throw InventoryPostingError.unitCostMustNotBeNegative }
                // D-10: `0` is a legal price (a free sample) and dilutes the average normally. It
                // reaches here only because the model types the field as optional — a sentinel
                // zero would have made this indistinguishable from "not filled in".
                movement = row(request, context, quantityMilli: request.quantityMilli,
                               unitCostMicro: unitCost,
                               totalCostMinor: try costOfQuantity(quantityMilli: request.quantityMilli,
                                                                  unitCostMicro: unitCost))
                exception = request.type == .opening ? .openingSeeded : nil
            }

        case .outbound:
            guard request.quantityMilli > 0 else { throw InventoryPostingError.quantityMustBePositive }
            // N-5 — refused before anything is written, and the balance is left untouched.
            guard request.quantityMilli <= balance.quantityMilli else { throw InventoryPostingError.insufficientStock }

            var flagged = false
            let basis: Int64
            if request.type.isReturn {
                (basis, flagged) = try returnBasis(request: request, balance: balance, context: context)
            } else {
                basis = balance.unitCostMicro                      // N-1: the average BEFORE the issue
            }

            let zeroing = request.quantityMilli == balance.quantityMilli
            // N-2 — an issue that empties the stock takes the WHOLE remaining balance, so the
            // truncation residue D-3 parks in the balance leaves with the last unit instead of
            // being dropped. This is what keeps P2 an exact equality across a sell-out.
            let flow = zeroing ? balance.costBalanceMinor
                               : try costOfQuantity(quantityMilli: request.quantityMilli, unitCostMicro: basis)
            // Cannot issue more cost than is on hand; for average-priced issues this is implied,
            // for an origin-priced return it is not.
            guard flow <= balance.costBalanceMinor else { throw InventoryPostingError.costBalanceWouldGoNegative }

            movement = row(request, context, quantityMilli: request.quantityMilli,
                           unitCostMicro: request.type.isReturn ? basis : nil,
                           totalCostMinor: flow)
            exception = flagged ? .returnOriginNotFound : nil
        }

        return InventoryPostingPlan(movement: movement,
                                    balance: try apply(movement, to: balance),
                                    exception: exception)
    }

    /// N-4 + D-11 for the two return kinds. Returns the unit cost to use and whether the row has
    /// to be flagged.
    private static func returnBasis(request: InventoryPostingRequest,
                                    balance: InventoryBalance,
                                    context: InventoryPostingContext) throws -> (unitCostMicro: Int64, flagged: Bool) {
        guard let origin = context.origin else {
            // N-4's explicit fallback. D-11 has nothing to measure against here, so no ceiling is
            // applied — refusing outright would block a legitimate return of goods bought before
            // the ledger existed. The exception row is what keeps it traceable, which is exactly
            // the action N-4 already requires.
            return (balance.unitCostMicro, true)
        }
        // D-11 — CUMULATIVE. Per-return would be no ceiling at all: two returns of 6 against an
        // order of 10 each pass on their own.
        let total = try addChecked(origin.alreadyReturnedMilli, request.quantityMilli)
        guard total <= origin.quantityMilli else { throw InventoryPostingError.returnExceedsOrigin }
        return (origin.unitCostMicro, false)
    }

    private static func row(_ request: InventoryPostingRequest, _ context: InventoryPostingContext,
                            quantityMilli: Int64, unitCostMicro: Int64?,
                            totalCostMinor: Int64) -> InventoryPostedMovement {
        InventoryPostedMovement(id: context.movementID,
                                productID: request.productID,
                                type: request.type,
                                occurredOn: request.occurredOn,
                                seq: context.seq,
                                quantityMilli: quantityMilli,
                                unitCostMicro: unitCostMicro,
                                totalCostMinor: totalCostMinor,
                                currency: request.currency,
                                sourceType: request.sourceType,
                                sourceID: request.sourceID,
                                reversesID: nil,
                                note: request.note)
    }

    // MARK: - Reversal (F2)

    /// Build the row that reverses `target`.
    ///
    /// Same type, `reversesID` set, the reversed row's numbers carried verbatim. The DIRECTION is
    /// implied (``InventoryPostedMovement/effectiveDirection``) rather than expressed by picking a
    /// mirror-image type, because the mirror would erase the difference between "we returned goods
    /// to the supplier" and "that purchase was keyed in wrong".
    ///
    /// The resulting balance is NOT computed by folding this row — see the type's note and G1. The
    /// caller replays the remaining live rows.
    public static func reversalRow(target: InventoryPostedMovement, id: String, occurredOn: String,
                                   seq: Int64, note: String? = nil) -> InventoryPostedMovement {
        InventoryPostedMovement(id: id,
                                productID: target.productID,
                                type: target.type,
                                occurredOn: occurredOn,
                                seq: seq,
                                quantityMilli: target.quantityMilli,
                                unitCostMicro: target.unitCostMicro,
                                totalCostMinor: target.totalCostMinor,
                                currency: target.currency,
                                sourceType: target.sourceType,
                                sourceID: target.sourceID,
                                reversesID: target.id,
                                note: note)
    }
}
