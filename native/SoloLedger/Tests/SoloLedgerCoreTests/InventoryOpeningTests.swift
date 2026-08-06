import CryptoKit
import XCTest
@testable import SoloLedgerCore

/// N-PR-5b: the opening-stock wizard's Core half — the read-only preflight and the runner.
///
/// The accounting is the engine's and is tested there. What is tested HERE is everything the
/// engine cannot see: that the preflight really writes nothing, that eligibility is D-5's own
/// question asked the engine's way, that the quantity-and-amount pair becomes the unit cost the
/// ledger will store, and that a batch is N independent facts rather than one.
final class InventoryOpeningTests: LedgerTestCase {

    // MARK: - Fixtures

    private func storeWithProducts(_ names: [String]) throws -> (LedgerStore, URL, [String]) {
        let url = try trackedTempDir().appendingPathComponent("opening.db")
        let store = try LedgerStore(databaseURL: url)
        var ids: [String] = []
        for (index, name) in names.enumerated() {
            let id = "p\(index)"
            try store.db.run("INSERT INTO products (id, name, unit) VALUES (?, ?, 'kg')",
                             [.text(id), .text(name)])
            ids.append(id)
        }
        return (store, url, ids)
    }

    private func entry(_ productID: String, quantityMilli: Int64,
                       amountMinor: Int64) -> InventoryOpeningEntry {
        InventoryOpeningEntry(productID: productID, quantityMilli: quantityMilli,
                              amountMinor: amountMinor)
    }

    private func request(_ entries: [InventoryOpeningEntry],
                         on occurredOn: String = "2026-01-10",
                         currency: String = "CNY") -> InventoryOpeningRequest {
        InventoryOpeningRequest(occurredOn: occurredOn, currency: currency, entries: entries)
    }

    /// SHA-256 of a file, or `nil` when it does not exist. Used on the database and its `-wal`.
    private func digest(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // ==============================================================================================
    // MARK: - O1 · the preflight writes nothing, and that is measured
    // ==============================================================================================

    /// "Read-only" is not a comment. The database file and its write-ahead log are hashed either
    /// side of a full preflight — over a ledger that has products, movements and an exception —
    /// and both must be byte-identical.
    func testO1ThePreflightLeavesTheDatabaseByteIdentical() throws {
        let (store, url, ids) = try storeWithProducts(["Alpha", "Beta", "Gamma"])
        try store.postInventoryMovement(.init(productID: ids[0], type: .opening,
                                              occurredOn: "2026-01-01", quantityMilli: 1_000,
                                              unitCostMicro: 100_000_000, currency: "CNY"))
        let wal = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + "-wal")

        let databaseBefore = digest(url)
        let walBefore = digest(wal)
        XCTAssertNotNil(databaseBefore, "the ledger file must exist to be worth hashing")

        for _ in 0..<3 { _ = try store.inventoryOpeningPreflight() }

        XCTAssertEqual(digest(url), databaseBefore, "the preflight wrote to the database")
        XCTAssertEqual(digest(wal), walBefore, "the preflight wrote to the write-ahead log")
    }

    // MARK: - O2 · the three answers

    func testO2AnEmptyCatalogueIsBlockedWithItsOwnReason() throws {
        let (store, _, _) = try storeWithProducts([])
        XCTAssertEqual(try store.inventoryOpeningPreflight(), .blocked(.noProduct))
    }

    func testO3EveryProductAlreadyMovingIsADifferentRefusal() throws {
        let (store, _, ids) = try storeWithProducts(["Alpha"])
        try store.postInventoryMovement(.init(productID: ids[0], type: .purchaseIn,
                                              occurredOn: "2026-01-01", quantityMilli: 1_000,
                                              unitCostMicro: 100_000_000, currency: "CNY"))
        XCTAssertEqual(try store.inventoryOpeningPreflight(), .blocked(.noneEligible))
    }

    func testO4AMixedCatalogueOffersOnlyTheEligibleProducts() throws {
        let (store, _, ids) = try storeWithProducts(["Alpha", "Beta", "Gamma"])
        try store.postInventoryMovement(.init(productID: ids[1], type: .purchaseIn,
                                              occurredOn: "2026-01-01", quantityMilli: 1_000,
                                              unitCostMicro: 100_000_000, currency: "CNY"))
        guard case .plan(let plan) = try store.inventoryOpeningPreflight() else {
            return XCTFail("expected a plan")
        }
        XCTAssertEqual(plan.candidates.map(\.productID), [ids[0], ids[2]])
        XCTAssertEqual(plan.candidates.map(\.name), ["Alpha", "Gamma"])
        XCTAssertEqual(plan.candidates.map(\.unit), ["kg", "kg"])
        XCTAssertEqual(plan.alreadyMovingCount, 1, "the list is not the whole catalogue")
    }

    // MARK: - O5 · D-5, including the reversal that makes a product eligible again

    /// D-5 asks about LIVE movements, and a reversed pair does not exist. So a mis-keyed opening
    /// that was undone leaves the product eligible — which is the whole reason the wizard can be
    /// opened twice without a repair path.
    func testO5AProductWhoseMovementsWereAllReversedIsEligibleAgain() throws {
        let (store, _, ids) = try storeWithProducts(["Alpha"])
        let opening = try store.postInventoryMovement(.init(productID: ids[0], type: .opening,
                                                            occurredOn: "2026-01-01",
                                                            quantityMilli: 1_000,
                                                            unitCostMicro: 100_000_000,
                                                            currency: "CNY"))
        XCTAssertEqual(try store.inventoryOpeningPreflight(), .blocked(.noneEligible))

        try store.reverseInventoryMovement(id: opening.id, occurredOn: "2026-01-02")

        guard case .plan(let plan) = try store.inventoryOpeningPreflight() else {
            return XCTFail("a reversed opening must leave the product eligible")
        }
        XCTAssertEqual(plan.candidates.map(\.productID), [ids[0]])
        XCTAssertEqual(plan.alreadyMovingCount, 0)
        // …and the second attempt really posts.
        let outcome = store.runInventoryOpening(request([entry(ids[0], quantityMilli: 2_000,
                                                                amountMinor: 500)]))
        XCTAssertEqual(outcome.refusedCount, 0)
        XCTAssertEqual(try store.inventoryBalance(productID: ids[0]).quantityMilli, 2_000)
    }

    func testO5bAProductThatAlreadyHasAnOpeningIsRefusedByTheEngine() throws {
        let (store, _, ids) = try storeWithProducts(["Alpha"])
        _ = store.runInventoryOpening(request([entry(ids[0], quantityMilli: 1_000, amountMinor: 100)]))
        let second = store.runInventoryOpening(request([entry(ids[0], quantityMilli: 1_000,
                                                               amountMinor: 100)],
                                                        on: "2026-01-11"))
        XCTAssertEqual(second.results.first?.refusal, .openingMustBeFirst)
        XCTAssertEqual(try store.inventoryMovements(productID: ids[0]).count, 1)
    }

    // MARK: - O6 · N-7 and D-10 on the amount

    func testO6ZeroIsAPriceAndANegativeAmountIsNot() throws {
        let (store, _, ids) = try storeWithProducts(["Alpha", "Beta"])
        // D-10: goods that cost nothing are legal, and they dilute nothing because this is the
        // product's first movement.
        let free = store.runInventoryOpening(request([entry(ids[0], quantityMilli: 5_000,
                                                             amountMinor: 0)]))
        XCTAssertEqual(free.refusedCount, 0)
        XCTAssertEqual(try store.inventoryBalance(productID: ids[0]).unitCostMicro, 0)
        XCTAssertEqual(try store.inventoryBalance(productID: ids[0]).quantityMilli, 5_000)

        let negative = store.runInventoryOpening(request([entry(ids[1], quantityMilli: 5_000,
                                                                 amountMinor: -1)]))
        XCTAssertEqual(negative.results.first?.refusal, .unitCostMustNotBeNegative)
        XCTAssertEqual(try store.inventoryMovements(productID: ids[1]).count, 0)
    }

    /// N-7's other half is structural: the request this wizard builds ALWAYS carries a unit cost,
    /// because the amount is required to reach an entry at all. A quantity with no amount is not
    /// representable here — and a zero quantity is refused rather than silently treated as blank.
    func testO6bAZeroQuantityIsRefusedRatherThanTreatedAsBlank() throws {
        let (store, _, ids) = try storeWithProducts(["Alpha"])
        let outcome = store.runInventoryOpening(request([entry(ids[0], quantityMilli: 0,
                                                                amountMinor: 100)]))
        XCTAssertEqual(outcome.results.first?.refusal, .quantityMustBePositive)
        XCTAssertEqual(try store.inventoryMovements(productID: ids[0]).count, 0)
    }

    // MARK: - O7 · D-1, the currency this freezes

    func testO7TheOpeningFreezesTheCurrencyAndALaterOtherCurrencyIsRefused() throws {
        let (store, _, ids) = try storeWithProducts(["Alpha"])
        _ = store.runInventoryOpening(request([entry(ids[0], quantityMilli: 1_000, amountMinor: 100)],
                                               currency: "EUR"))
        XCTAssertEqual(try store.inventoryBalance(productID: ids[0]).currency, "EUR")

        XCTAssertThrowsError(try store.postInventoryMovement(
            .init(productID: ids[0], type: .purchaseIn, occurredOn: "2026-02-01",
                  quantityMilli: 1_000, unitCostMicro: 100_000_000, currency: "CNY"))) { error in
            XCTAssertEqual(error as? InventoryPostingError, .currencyMismatch)
        }
    }

    // MARK: - O8 · N-6, the consequence the wizard warns about

    /// The date the wizard writes becomes the backdating baseline. A movement dated the day before
    /// is refused, and this version does not recompute history — which is exactly what
    /// `inventory.opening.date.note` says beside the date field.
    func testO8AMovementDatedBeforeTheOpeningIsRefused() throws {
        let (store, _, ids) = try storeWithProducts(["Alpha"])
        _ = store.runInventoryOpening(request([entry(ids[0], quantityMilli: 1_000, amountMinor: 100)],
                                               on: "2026-03-10"))
        XCTAssertThrowsError(try store.postInventoryMovement(
            .init(productID: ids[0], type: .purchaseIn, occurredOn: "2026-03-09",
                  quantityMilli: 1_000, unitCostMicro: 100_000_000, currency: "CNY"))) { error in
            XCTAssertEqual(error as? InventoryPostingError, .backdatedNotSupported)
        }
        // …and the same day is fine, because `seq` orders within a date.
        XCTAssertNoThrow(try store.postInventoryMovement(
            .init(productID: ids[0], type: .purchaseIn, occurredOn: "2026-03-10",
                  quantityMilli: 1_000, unitCostMicro: 100_000_000, currency: "CNY")))
    }

    // MARK: - O9 · a stale line is refused on its own, and the rest go in

    /// The batch is N independent facts. A product another writer got to first is refused by D-5 —
    /// which IS the staleness gate, so there is no second one to forget — and every other line is
    /// in the ledger afterwards.
    func testO9OneStaleProductDoesNotTakeTheBatchWithIt() throws {
        let (store, url, ids) = try storeWithProducts(["Alpha", "Beta", "Gamma"])
        guard case .plan = try store.inventoryOpeningPreflight() else { return XCTFail("no plan") }

        let other = try LedgerStore(databaseURL: url)
        try other.postInventoryMovement(.init(productID: ids[1], type: .purchaseIn,
                                              occurredOn: "2026-01-05", quantityMilli: 1_000,
                                              unitCostMicro: 100_000_000, currency: "CNY"))

        let outcome = store.runInventoryOpening(request([
            entry(ids[0], quantityMilli: 1_000, amountMinor: 100),
            entry(ids[1], quantityMilli: 2_000, amountMinor: 200),
            entry(ids[2], quantityMilli: 3_000, amountMinor: 300),
        ]))

        XCTAssertEqual(outcome.results.map(\.productID), ids, "one result per entry, in order")
        XCTAssertEqual(outcome.recordedCount, 2)
        XCTAssertEqual(outcome.refusedCount, 1)
        XCTAssertEqual(outcome.refusals.map(\.productID), [ids[1]])
        XCTAssertEqual(outcome.refusals.first?.refusal, .openingMustBeFirst)

        XCTAssertEqual(try store.inventoryMovements(productID: ids[0]).map(\.type), [.opening])
        XCTAssertEqual(try store.inventoryMovements(productID: ids[1]).map(\.type), [.purchaseIn])
        XCTAssertEqual(try store.inventoryMovements(productID: ids[2]).map(\.type), [.opening])
    }

    // MARK: - O10 · the quantity-and-amount pair becomes the stored unit cost

    /// The division is truncating, so when it does not come out evenly the ledger holds LESS than
    /// the amount that was typed, and the gap goes nowhere — which is the fact
    /// `inventory.opening.roundingNote` exists to state.
    ///
    /// The size of that gap is asserted MEASURED, not assumed. There are two truncations on the
    /// path — the unit cost, then the amount recomputed from it — and the loss works out to
    /// `ceil(r / 1e9)` where `r = (amount × 1e9) mod quantityMilli`. For any quantity below a
    /// million units that is exactly one minor unit whenever the division is uneven, and zero
    /// otherwise. It is NOT "less than one".
    func testO10TheImpliedUnitCostDividesEvenlyOrLosesExactlyOneMinorUnit() throws {
        // Even: 125.00 over ten units is 12.50 each.
        XCTAssertEqual(try InventoryOpening.unitCostMicro(amountMinor: 12_500,
                                                          quantityMilli: 10_000),
                       1_250_000_000)
        // Not even: 10.00 over three units. 1000 × 1e9 / 3000 = 333_333_333 (truncated).
        XCTAssertEqual(try InventoryOpening.unitCostMicro(amountMinor: 1_000,
                                                          quantityMilli: 3_000),
                       333_333_333)

        let (store, _, ids) = try storeWithProducts(["Even", "Uneven"])
        _ = store.runInventoryOpening(request([entry(ids[0], quantityMilli: 10_000,
                                                      amountMinor: 12_500)]))
        XCTAssertEqual(try store.inventoryBalance(productID: ids[0]).costBalanceMinor, 12_500,
                       "an even division stores exactly what was typed")

        _ = store.runInventoryOpening(request([entry(ids[1], quantityMilli: 3_000,
                                                      amountMinor: 1_000)]))
        let stored = try store.inventoryBalance(productID: ids[1]).costBalanceMinor
        XCTAssertLessThan(stored, 1_000, "the truncation can only lose, never gain")
        XCTAssertEqual(stored, 999, "10.00 over three units records 9.99 — one minor unit down")
        XCTAssertEqual(1_000 - stored, 1)
    }

    func testO10bTheDerivationRefusesRatherThanWrapping() {
        XCTAssertThrowsError(try InventoryOpening.unitCostMicro(amountMinor: Int64.max,
                                                                quantityMilli: 1_000)) { error in
            XCTAssertEqual(error as? InventoryPostingError, .arithmeticOverflow)
        }
        XCTAssertThrowsError(try InventoryOpening.unitCostMicro(amountMinor: 100,
                                                                quantityMilli: 0)) { error in
            XCTAssertEqual(error as? InventoryPostingError, .quantityMustBePositive)
        }
        XCTAssertThrowsError(try InventoryOpening.unitCostMicro(amountMinor: -1,
                                                                quantityMilli: 1_000)) { error in
            XCTAssertEqual(error as? InventoryPostingError, .unitCostMustNotBeNegative)
        }
    }

    /// The 1e9 bridge is written out in this file rather than borrowed from the engine, so that
    /// `InventoryPosting` stays a name nothing outside the engine mentions. This is the price of
    /// that: the two constants are pinned equal here.
    func testO10cTheScaleBridgeMatchesTheEngines() {
        XCTAssertEqual(InventoryOpening.scaleBridge, InventoryPosting.scaleBridge)
    }

    // MARK: - O11 · every opening is flagged as entered by hand

    /// N-10: an opening balance is an estimate carried in at switch-over, and its provenance has
    /// to stay visible. The engine writes that exception; this asserts the wizard's path produces
    /// it, because the wizard is the one place openings come from.
    func testO11EveryOpeningTheWizardPostsIsFlagged() throws {
        let (store, _, ids) = try storeWithProducts(["Alpha", "Beta"])
        _ = store.runInventoryOpening(request([
            entry(ids[0], quantityMilli: 1_000, amountMinor: 100),
            entry(ids[1], quantityMilli: 2_000, amountMinor: 200),
        ]))
        for id in ids {
            XCTAssertEqual(try store.inventoryExceptions(productID: id).map(\.kind),
                           [.openingSeeded], "\(id) has no provenance record")
        }
    }

    // MARK: - O12 · an empty batch touches nothing

    func testO12AnEmptyRequestWritesNothingAndReportsNothing() throws {
        let (store, url, _) = try storeWithProducts(["Alpha"])
        let before = digest(url)
        let outcome = store.runInventoryOpening(request([]))
        XCTAssertTrue(outcome.results.isEmpty)
        XCTAssertEqual(outcome.recordedCount, 0)
        XCTAssertEqual(outcome.refusedCount, 0)
        XCTAssertEqual(digest(url), before)
    }
}
