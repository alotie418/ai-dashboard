import XCTest
@testable import SoloLedgerCore

/// N-PR-2: the persistence half — real SQLite, the v24 tables, one transaction per posting.
///
/// The accounting itself is tested in `InventoryPostingTests` without a database. What is tested
/// HERE is everything the pure state machine cannot see: that a refusal writes nothing, that `seq`
/// is the engine's, that a return finds its origin document, that a reversed pair stops counting,
/// and that none of it is reachable from the App yet.
final class InventoryLedgerTests: LedgerTestCase {

    // MARK: - Fixtures

    private func storeWithProduct(_ ids: [String] = ["p1"]) throws -> LedgerStore {
        let store = try makeStore()
        for id in ids {
            try store.db.run("INSERT INTO products (id, name, unit) VALUES (?, ?, 'piece')",
                             [.text(id), .text("Product \(id)")])
        }
        return store
    }

    @discardableResult
    private func receipt(_ store: LedgerStore, _ product: String = "p1", on date: String,
                         qty: Int64, unitCost: Int64, source: (String, String)? = nil) throws -> InventoryPostedMovement {
        try store.postInventoryMovement(.init(productID: product, type: .purchaseIn, occurredOn: date,
                                              quantityMilli: qty, unitCostMicro: unitCost,
                                              currency: "CNY",
                                              sourceType: source?.0, sourceID: source?.1))
    }

    @discardableResult
    private func issue(_ store: LedgerStore, _ product: String = "p1", on date: String,
                       qty: Int64, source: (String, String)? = nil) throws -> InventoryPostedMovement {
        try store.postInventoryMovement(.init(productID: product, type: .saleOut, occurredOn: date,
                                              quantityMilli: qty, currency: "CNY",
                                              sourceType: source?.0, sourceID: source?.1))
    }

    private func movementCount(_ store: LedgerStore) throws -> Int {
        try store.db.query("SELECT COUNT(*) AS c FROM inventory_movements").first?.int("c") ?? -1
    }

    // MARK: - L1 · one posting = one transaction, and a refusal writes nothing

    func testAPostingWritesTheRowTheBalanceAndNothingElse() throws {
        let store = try storeWithProduct()
        let posted = try receipt(store, on: "2026-01-01", qty: 10_000, unitCost: 100_000_000)

        XCTAssertEqual(try movementCount(store), 1)
        XCTAssertTrue(posted.id.hasPrefix("invm-"))
        let balance = try store.inventoryBalance(productID: "p1")
        XCTAssertEqual(balance.quantityMilli, 10_000)
        XCTAssertEqual(balance.costBalanceMinor, 1_000)
        XCTAssertEqual(balance.unitCostMicro, 100_000_000)
        XCTAssertEqual(balance.currency, "CNY")
        XCTAssertEqual(balance.lastMovementID, posted.id)
        XCTAssertEqual(balance.lastOccurredOn, "2026-01-01")
        XCTAssertEqual(balance.lastSeq, 1)
        // A plain receipt is not an exception.
        XCTAssertEqual(try store.inventoryExceptions(productID: "p1"), [])
    }

    func testARefusedPostingLeavesTheLedgerUntouched() throws {
        let store = try storeWithProduct()
        try receipt(store, on: "2026-01-01", qty: 5_000, unitCost: 100_000_000)
        let before = try store.inventoryBalance(productID: "p1")

        XCTAssertThrowsError(try issue(store, on: "2026-01-02", qty: 6_000)) {
            XCTAssertEqual($0 as? InventoryPostingError, .insufficientStock)
        }
        XCTAssertEqual(try movementCount(store), 1, "N-5 refused BEFORE anything was written")
        XCTAssertEqual(try store.inventoryBalance(productID: "p1"), before)
    }

    func testAMovementForAnUnknownProductIsRefusedByName() throws {
        let store = try storeWithProduct()
        XCTAssertThrowsError(try receipt(store, "ghost", on: "2026-01-01", qty: 1, unitCost: 1)) {
            XCTAssertEqual($0 as? InventoryPostingError, .productNotFound)
        }
        XCTAssertEqual(try movementCount(store), 0)
    }

    /// The v24 foreign key is ON DELETE RESTRICT, so a product with movements cannot be deleted.
    /// Surfacing that refusal through `ProductCatalog`'s own error surface is N-PR-3's job; what
    /// matters here is that the engine's rows are what make it bite.
    func testAProductWithMovementsCannotBeDeletedUnderneathTheEngine() throws {
        let store = try storeWithProduct()
        try receipt(store, on: "2026-01-01", qty: 1_000, unitCost: 1_000_000)
        XCTAssertThrowsError(try store.db.run("DELETE FROM products WHERE id = 'p1'"))
        XCTAssertEqual(try movementCount(store), 1)
    }

    // MARK: - L2 · D-4 the engine assigns seq

    func testSeqIsAssignedByTheEngineMonotonicallyWithinADay() throws {
        let store = try storeWithProduct(["p1", "p2"])
        let a = try receipt(store, on: "2026-01-01", qty: 1_000, unitCost: 1_000_000)
        let b = try receipt(store, on: "2026-01-01", qty: 1_000, unitCost: 1_000_000)
        let c = try receipt(store, on: "2026-01-02", qty: 1_000, unitCost: 1_000_000)
        XCTAssertEqual([a.seq, b.seq, c.seq], [1, 2, 1], "per (product, day), restarting each day")

        // A different product's ordering is its own — the unique index is per product.
        let d = try receipt(store, "p2", on: "2026-01-01", qty: 1_000, unitCost: 1_000_000)
        XCTAssertEqual(d.seq, 1)
    }

    // MARK: - L3 · N-4 / D-11 against real rows

    func testACustomerReturnFindsItsSaleAndIsPricedAtWhatTheSaleRemoved() throws {
        let store = try storeWithProduct()
        try receipt(store, on: "2026-01-01", qty: 10_000, unitCost: 100_000_000)
        try issue(store, on: "2026-01-02", qty: 10_000, source: ("sale", "s1"))
        XCTAssertEqual(try store.inventoryBalance(productID: "p1").quantityMilli, 0)

        let back = try store.postInventoryMovement(
            .init(productID: "p1", type: .saleReturnIn, occurredOn: "2026-01-03",
                  quantityMilli: 4_000, currency: "CNY", sourceType: "sale", sourceID: "s1"))
        XCTAssertEqual(back.unitCostMicro, 100_000_000,
                       "N-4: the price the sale took out, not today's average (which is 0)")
        let balance = try store.inventoryBalance(productID: "p1")
        XCTAssertEqual(balance.costBalanceMinor, 400)
        XCTAssertEqual(try store.inventoryExceptions(productID: "p1"), [],
                       "a return whose origin WAS found is not an exception")
    }

    func testTheReturnCeilingIsCumulativeAcrossReturnsAgainstTheSameOrigin() throws {
        let store = try storeWithProduct()
        try receipt(store, on: "2026-01-01", qty: 10_000, unitCost: 100_000_000)
        try issue(store, on: "2026-01-02", qty: 10_000, source: ("sale", "s1"))

        func returnQty(_ qty: Int64, on date: String) throws {
            try store.postInventoryMovement(
                .init(productID: "p1", type: .saleReturnIn, occurredOn: date, quantityMilli: qty,
                      currency: "CNY", sourceType: "sale", sourceID: "s1"))
        }
        try returnQty(6_000, on: "2026-01-03")
        // Each is ≤ 10 on its own; together they are 12. Per-return would have let this through.
        XCTAssertThrowsError(try returnQty(6_000, on: "2026-01-04")) {
            XCTAssertEqual($0 as? InventoryPostingError, .returnExceedsOrigin)
        }
        try returnQty(4_000, on: "2026-01-04")     // exactly to the ceiling is allowed
        XCTAssertEqual(try store.inventoryBalance(productID: "p1").quantityMilli, 10_000)
    }

    func testAReturnWithNoFindableOriginIsPostedAtTheAverageAndWritesAnException() throws {
        let store = try storeWithProduct()
        try receipt(store, on: "2026-01-01", qty: 10_000, unitCost: 100_000_000)
        try issue(store, on: "2026-01-02", qty: 2_000, source: ("sale", "s1"))

        let orphan = try store.postInventoryMovement(
            .init(productID: "p1", type: .saleReturnIn, occurredOn: "2026-01-03",
                  quantityMilli: 1_000, currency: "CNY", sourceType: "sale", sourceID: "no-such"))
        XCTAssertEqual(orphan.unitCostMicro, 100_000_000, "priced at the current average")

        let exceptions = try store.inventoryExceptions(productID: "p1")
        XCTAssertEqual(exceptions.map(\.kind), [.returnOriginNotFound])
        XCTAssertEqual(exceptions.first?.movementID, orphan.id,
                       "N-4 requires the flagged row to be findable afterwards")
    }

    // MARK: - L4 · exceptions the ruling attaches

    func testOpeningAndManualAdjustmentEachLeaveTheirAuditRow() throws {
        let store = try storeWithProduct()
        let opening = try store.postInventoryMovement(
            .init(productID: "p1", type: .opening, occurredOn: "2026-01-01",
                  quantityMilli: 10_000, unitCostMicro: 100_000_000, currency: "CNY"))
        let adjust = try store.postInventoryMovement(
            .init(productID: "p1", type: .manualAdjust, occurredOn: "2026-01-02",
                  quantityMilli: 0, costDeltaMinor: 250, currency: "CNY"))

        let exceptions = try store.inventoryExceptions(productID: "p1")
        XCTAssertEqual(Set(exceptions.map(\.kind)), [.openingSeeded, .manualAdjust])
        XCTAssertEqual(Set(exceptions.compactMap(\.movementID)), [opening.id, adjust.id])

        let balance = try store.inventoryBalance(productID: "p1")
        XCTAssertEqual(balance.quantityMilli, 10_000, "F1 案丙: the adjustment moved no quantity")
        XCTAssertEqual(balance.costBalanceMinor, 1_250)
        XCTAssertEqual(balance.unitCostMicro, 125_000_000)
    }

    // MARK: - L5 · reversal (F2)

    func testOnlyTheLastLiveMovementCanBeReversedAndTheChainUndoesBackwards() throws {
        let store = try storeWithProduct()
        let first = try receipt(store, on: "2026-01-01", qty: 10_000, unitCost: 100_000_000)
        let second = try receipt(store, on: "2026-01-02", qty: 10_000, unitCost: 200_000_000)

        XCTAssertThrowsError(try store.reverseInventoryMovement(id: first.id, occurredOn: "2026-01-03")) {
            XCTAssertEqual($0 as? InventoryPostingError, .onlyTheLastMovementCanBeReversed)
        }
        XCTAssertEqual(try movementCount(store), 2, "the refusal wrote nothing")

        let undo = try store.reverseInventoryMovement(id: second.id, occurredOn: "2026-01-03")
        XCTAssertEqual(undo.type, .purchaseIn, "F2: the SAME type, with reversesID set")
        XCTAssertEqual(undo.reversesID, second.id)
        XCTAssertEqual(undo.effectiveDirection, .outbound, "…and therefore the opposite direction")
        XCTAssertEqual(try store.inventoryBalance(productID: "p1").unitCostMicro, 100_000_000)

        // Nothing was deleted: the audit view still holds all three rows.
        XCTAssertEqual(try store.inventoryMovements(productID: "p1").count, 3)
        // …and the live view holds only the first receipt.
        XCTAssertEqual(try store.liveInventoryMovements(productID: "p1").map(\.id), [first.id])
        // Which makes the FIRST receipt reversible now — undo chains backwards, one step at a time.
        XCTAssertNoThrow(try store.reverseInventoryMovement(id: first.id, occurredOn: "2026-01-04"))
        XCTAssertEqual(try store.inventoryBalance(productID: "p1").triple.quantityMilli, 0)
    }

    func testAReversalCannotBeRepeatedOrItselfReversed() throws {
        let store = try storeWithProduct()
        let posted = try receipt(store, on: "2026-01-01", qty: 1_000, unitCost: 1_000_000)
        let undo = try store.reverseInventoryMovement(id: posted.id, occurredOn: "2026-01-02")

        XCTAssertThrowsError(try store.reverseInventoryMovement(id: posted.id, occurredOn: "2026-01-03")) {
            XCTAssertEqual($0 as? InventoryPostingError, .movementAlreadyReversed)
        }
        XCTAssertThrowsError(try store.reverseInventoryMovement(id: undo.id, occurredOn: "2026-01-03")) {
            XCTAssertEqual($0 as? InventoryPostingError, .onlyTheLastMovementCanBeReversed)
        }
        XCTAssertThrowsError(try store.reverseInventoryMovement(id: "nope", occurredOn: "2026-01-03")) {
            XCTAssertEqual($0 as? InventoryPostingError, .reversalTargetNotFound)
        }
        XCTAssertEqual(try movementCount(store), 2, "none of the three refusals wrote a row")
    }

    /// The backdating baseline moves to the REVERSAL, not back to what it undid — it is the newest
    /// row in the ledger, and N-6 measures against the newest row.
    func testTheBaselineMovesForwardToTheReversal() throws {
        let store = try storeWithProduct()
        let posted = try receipt(store, on: "2026-01-01", qty: 1_000, unitCost: 1_000_000)
        let undo = try store.reverseInventoryMovement(id: posted.id, occurredOn: "2026-02-01")

        let balance = try store.inventoryBalance(productID: "p1")
        XCTAssertEqual(balance.lastMovementID, undo.id)
        XCTAssertEqual(balance.lastOccurredOn, "2026-02-01")
        XCTAssertThrowsError(try receipt(store, on: "2026-01-15", qty: 1, unitCost: 1)) {
            XCTAssertEqual($0 as? InventoryPostingError, .backdatedNotSupported)
        }
    }

    /// D-5 — a mis-keyed opening can be reversed and re-entered. "The product already has an
    /// opening" is judged over LIVE rows, which is the same definition the reversal replay uses.
    func testAReversedOpeningDoesNotBlockACorrectedOne() throws {
        let store = try storeWithProduct()
        let wrong = try store.postInventoryMovement(
            .init(productID: "p1", type: .opening, occurredOn: "2026-01-01",
                  quantityMilli: 10_000, unitCostMicro: 999_000_000, currency: "CNY"))
        XCTAssertThrowsError(try store.postInventoryMovement(
            .init(productID: "p1", type: .opening, occurredOn: "2026-01-02",
                  quantityMilli: 10_000, unitCostMicro: 100_000_000, currency: "CNY"))) {
            XCTAssertEqual($0 as? InventoryPostingError, .openingMustBeFirst)
        }

        try store.reverseInventoryMovement(id: wrong.id, occurredOn: "2026-01-02")
        XCTAssertNoThrow(try store.postInventoryMovement(
            .init(productID: "p1", type: .opening, occurredOn: "2026-01-03",
                  quantityMilli: 10_000, unitCostMicro: 100_000_000, currency: "CNY")))
        XCTAssertEqual(try store.inventoryBalance(productID: "p1").unitCostMicro, 100_000_000)
    }

    // MARK: - L6 · G1's counterexamples, end to end through SQLite

    /// Counterexample A — reversing an issue that emptied the stock restores ALL THREE numbers.
    /// Subtracting the reversed row would land the average on 333_500_000.
    func testG1CounterexampleAThroughTheDatabase() throws {
        let store = try storeWithProduct()
        try receipt(store, on: "2026-01-01", qty: 3_000, unitCost: 333_333_334)
        try issue(store, on: "2026-01-02", qty: 1_000)
        let target = try store.inventoryBalance(productID: "p1").triple
        XCTAssertEqual(target.unitCostMicro, 333_333_333)

        let zeroing = try issue(store, on: "2026-01-03", qty: 2_000)
        XCTAssertEqual(try store.inventoryBalance(productID: "p1").triple.costBalanceMinor, 0)

        try store.reverseInventoryMovement(id: zeroing.id, occurredOn: "2026-01-04")
        let restored = try store.inventoryBalance(productID: "p1").triple
        XCTAssertEqual(restored.quantityMilli, target.quantityMilli)
        XCTAssertEqual(restored.costBalanceMinor, target.costBalanceMinor)
        XCTAssertEqual(restored.unitCostMicro, target.unitCostMicro, "P7's third component")
    }

    /// Counterexample B — the same, reversing a RECEIPT, with nothing having sold out.
    func testG1CounterexampleBThroughTheDatabase() throws {
        let store = try storeWithProduct()
        try receipt(store, on: "2026-01-01", qty: 3_000, unitCost: 333_333_334)
        try issue(store, on: "2026-01-02", qty: 1_000)
        let target = try store.inventoryBalance(productID: "p1").triple

        let later = try receipt(store, on: "2026-01-03", qty: 2_000, unitCost: 250_000_000)
        XCTAssertNotEqual(try store.inventoryBalance(productID: "p1").triple.unitCostMicro,
                          target.unitCostMicro)

        try store.reverseInventoryMovement(id: later.id, occurredOn: "2026-01-04")
        XCTAssertEqual(try store.inventoryBalance(productID: "p1").triple.quantityMilli, target.quantityMilli)
        XCTAssertEqual(try store.inventoryBalance(productID: "p1").triple.costBalanceMinor, target.costBalanceMinor)
        XCTAssertEqual(try store.inventoryBalance(productID: "p1").triple.unitCostMicro, target.unitCostMicro)
    }

    /// The stored balance and a replay of the stored rows must agree — the same cross-check the
    /// property tests run, but over what SQLite actually holds.
    func testTheStoredBalanceAgreesWithAReplayOfTheStoredRows() throws {
        let store = try storeWithProduct()
        try receipt(store, on: "2026-01-01", qty: 7_000, unitCost: 142_857_142)
        try issue(store, on: "2026-01-02", qty: 3_000)
        try store.postInventoryMovement(.init(productID: "p1", type: .manualAdjust,
                                              occurredOn: "2026-01-03", quantityMilli: 0,
                                              costDeltaMinor: -37, currency: "CNY"))
        try receipt(store, on: "2026-01-04", qty: 2_000, unitCost: 500_000_000)
        let last = try issue(store, on: "2026-01-05", qty: 1_000)
        try store.reverseInventoryMovement(id: last.id, occurredOn: "2026-01-06")

        let stored = try store.inventoryBalance(productID: "p1")
        let replayed = try InventoryPosting.replay(try store.liveInventoryMovements(productID: "p1"),
                                                   productID: "p1")
        XCTAssertEqual(stored.triple.quantityMilli, replayed.triple.quantityMilli)
        XCTAssertEqual(stored.triple.costBalanceMinor, replayed.triple.costBalanceMinor)
        XCTAssertEqual(stored.triple.unitCostMicro, replayed.triple.unitCostMicro)
    }

    // MARK: - L7 · balances stay per product (N-9 / G23)

    func testTwoProductsKeepEntirelySeparateBalances() throws {
        let store = try storeWithProduct(["p1", "p2"])
        try receipt(store, "p1", on: "2026-01-01", qty: 10_000, unitCost: 100_000_000)
        try receipt(store, "p2", on: "2026-01-01", qty: 10_000, unitCost: 900_000_000)
        try issue(store, "p1", on: "2026-01-02", qty: 10_000)

        XCTAssertEqual(try store.inventoryBalance(productID: "p1").triple.quantityMilli, 0)
        XCTAssertEqual(try store.inventoryBalance(productID: "p2").triple.quantityMilli, 10_000)
        XCTAssertEqual(try store.inventoryBalance(productID: "p2").unitCostMicro, 900_000_000,
                       "p1 selling out says nothing about p2")
    }

    // MARK: - L8 · unreachable from the App

    /// The engine is Core-only at this stage: no view, no composition, no `AppModel` state. Asserted
    /// per symbol over the whole production tree so this fails on the first accidental wiring —
    /// whole-identifier matching, and `//` comments are not uses.
    ///
    /// Same shape as `ProductCatalogTests`' scan, for the same reason: an "it is not reachable yet"
    /// claim in a PR description decays; a test does not.
    func testNothingInTheProductionTreeNamesTheInventoryEngine() throws {
        let symbols = ["InventoryPosting", "InventoryPostedMovement", "InventoryBalance",
                       "InventoryMovementType", "InventoryMovementDirection", "InventoryException",
                       "InventoryExceptionKind", "InventoryPostingError", "InventoryPostingRequest",
                       "InventoryPostingContext", "InventoryPostingPlan", "InventoryOriginFacts",
                       "inventoryBalance", "inventoryMovements", "liveInventoryMovements",
                       "inventoryExceptions", "postInventoryMovement", "reverseInventoryMovement"]
        var offenders: [String: [String]] = [:]
        for (path, text) in try Self.productionSources() {
            let code = text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { line -> String in
                    guard let comment = line.range(of: "//") else { return String(line) }
                    return String(line[line.startIndex..<comment.lowerBound])
                }
                .joined(separator: "\n")
            for symbol in symbols {
                let pattern = "(^|[^A-Za-z0-9_])\(symbol)([^A-Za-z0-9_]|$)"
                if code.range(of: pattern, options: .regularExpression) != nil {
                    offenders[symbol, default: []].append(path)
                }
            }
        }
        XCTAssertEqual(offenders, [:], """
            The inventory engine is named outside its own three files. This stage has no UI and no \
            App wiring; the entry point lands in a later PR with its copy and its mounting test.
            """)
    }

    /// The scan must actually read files and must be able to see a use, or an empty offender list
    /// proves nothing at all.
    func testTheUnreachabilityScanReadsTheTreeAndCanSeeAUse() throws {
        let sources = try Self.productionSources()
        XCTAssertGreaterThan(sources.count, 40, "the production tree should be far larger than this")
        XCTAssertTrue(sources.contains { $0.path.hasSuffix("Store/LedgerStore.swift") })
        XCTAssertTrue(sources.contains { $0.path.hasSuffix("Inventory/ProductCatalog.swift") },
                      "the neighbouring catalog is IN scope — only the three engine files are excluded")
        for excluded in ["InventoryModels.swift", "InventoryPosting.swift", "InventoryLedger.swift"] {
            XCTAssertFalse(sources.contains { $0.path.hasSuffix("Inventory/\(excluded)") },
                           "\(excluded) declares the engine and is excluded by path")
        }
        let pattern = "(^|[^A-Za-z0-9_])postInventoryMovement([^A-Za-z0-9_]|$)"
        XCTAssertNotNil("try store.postInventoryMovement(r)".range(of: pattern, options: .regularExpression))
        XCTAssertNil("postInventoryMovementLater()".range(of: pattern, options: .regularExpression),
                     "a longer identifier is not a hit")
    }

    // MARK: - Scan helpers

    /// …/native/SoloLedger/Tests/SoloLedgerCoreTests/<this>.swift → …/native/SoloLedger
    private static func packageRoot() -> URL {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { dir.deleteLastPathComponent() }
        return dir
    }

    /// Every `.swift` file under `Sources/` — Core library and SwiftUI App target — except the
    /// three that declare the engine.
    private static func productionSources() throws -> [(path: String, text: String)] {
        let declaring = ["Inventory/InventoryModels.swift", "Inventory/InventoryPosting.swift",
                         "Inventory/InventoryLedger.swift"]
        let root = packageRoot().appendingPathComponent("Sources")
        guard let walker = FileManager.default.enumerator(atPath: root.path) else {
            XCTFail("cannot enumerate \(root.path)"); return []
        }
        var out: [(String, String)] = []
        for case let relative as String in walker where relative.hasSuffix(".swift") {
            if declaring.contains(where: { relative.hasSuffix($0) }) { continue }
            let url = root.appendingPathComponent(relative)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                XCTFail("cannot read \(relative)"); continue
            }
            out.append((relative, text))
        }
        return out
    }
}
