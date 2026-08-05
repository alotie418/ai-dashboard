import XCTest
@testable import SoloLedgerCore

/// N-PR-2: the moving-average state machine, tested WITHOUT a database.
///
/// ## There is no oracle here, and that shapes everything below
///
/// The mirrored report engines have one: the JavaScript is run for real and Swift must reproduce
/// it bit for bit. Inventory has none — the audited Electron implementation is wrong (it reports
/// 1500 where the answer is 2000; see A3) and was rejected rather than ported. So the truth comes
/// from the N0 costing ruling itself, and every test below names the clause it is holding the
/// engine to. Two things stand in for the missing oracle:
///
///  * **Property tests** (P1–P8) over pseudo-random movement sequences — conservation identities
///    that must hold for ANY legal history, not just the ones someone thought to write down.
///  * **An independent second implementation**: the incremental path (`plan` → `apply`) and the
///    whole-history path (`replay`) must agree on every generated sequence. They are different
///    code, so agreement is evidence; that cross-check is P0 below.
///
/// Determinism is deliberate: a fixed-seed SplitMix64, no `Date`, no system randomness. A property
/// test that cannot be re-run identically is a flake generator, not a guard.
final class InventoryPostingTests: XCTestCase {

    // MARK: - Deterministic generator

    /// SplitMix64. Written out rather than pulled from `SystemRandomNumberGenerator` so a failing
    /// seed reproduces exactly, on any machine, forever.
    private struct Seeded: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    // MARK: - Harness

    /// A product's history, built by the INCREMENTAL path. Everything a property needs is recorded
    /// as it happens, so no assertion has to re-derive the thing it is checking.
    private struct Harness {
        let productID: String
        let currency: String
        var balance: InventoryBalance
        var live: [InventoryPostedMovement] = []
        private var seqByDate: [String: Int64] = [:]
        private var counter = 0

        /// P4b's bookkeeping: the quantity at the last average recompute, and how many
        /// average-priced issues have happened since.
        var quantityAtLastRecompute: Int64 = 0
        var averagePricedIssuesSinceRecompute = 0

        init(productID: String = "p1", currency: String = "CNY") {
            self.productID = productID
            self.currency = currency
            self.balance = .empty(productID: productID)
        }

        mutating func nextSeq(_ date: String) -> Int64 {
            let next = (seqByDate[date] ?? 0) + 1
            seqByDate[date] = next
            return next
        }

        @discardableResult
        mutating func post(_ type: InventoryMovementType, on date: String,
                           qty: Int64 = 0, unitCost: Int64? = nil, delta: Int64? = nil,
                           source: (String, String)? = nil,
                           origin: InventoryOriginFacts? = nil,
                           currencyOverride: String? = nil) throws -> InventoryPostedMovement {
            counter += 1
            let request = InventoryPostingRequest(
                productID: productID, type: type, occurredOn: date, quantityMilli: qty,
                unitCostMicro: unitCost, costDeltaMinor: delta,
                currency: currencyOverride ?? currency,
                sourceType: source?.0, sourceID: source?.1)
            let context = InventoryPostingContext(hasLiveMovements: !live.isEmpty, origin: origin,
                                                  seq: nextSeq(date), movementID: "m\(counter)")
            let plan = try InventoryPosting.plan(request: request, balance: balance, context: context)

            let zeroing = plan.balance.quantityMilli == 0
            if type.isAveragePricedOutbound && !zeroing {
                averagePricedIssuesSinceRecompute += 1
            } else {
                quantityAtLastRecompute = plan.balance.quantityMilli
                averagePricedIssuesSinceRecompute = 0
            }

            balance = plan.balance
            live.append(plan.movement)
            return plan.movement
        }

        /// What a reversal of the last movement lands on (F2 / G1): drop the pair, replay the rest.
        func balanceAfterReversingLast() throws -> InventoryBalance {
            try InventoryPosting.replay(live.dropLast(), productID: productID)
        }
    }

    /// Every conservation identity, checked against a harness's recorded history.
    private func assertInvariants(_ h: Harness, _ label: String,
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        let b = h.balance

        // P1 — quantity is exactly what went in minus what went out (manual adjusts move none).
        let qtyIn = h.live.filter { $0.type.direction == .inbound }.reduce(Int64(0)) { $0 + $1.quantityMilli }
        let qtyOut = h.live.filter { $0.type.direction == .outbound }.reduce(Int64(0)) { $0 + $1.quantityMilli }
        XCTAssertEqual(b.quantityMilli, qtyIn - qtyOut, "\(label): P1", file: file, line: line)

        // P2 — the amended three-term form (G3). Cost-only adjustments carry a SIGNED delta, so
        // leaving them out would make this identity false the moment F1 案丙 is used.
        let costIn = h.live.filter { $0.type.direction == .inbound }.reduce(Int64(0)) { $0 + ($1.totalCostMinor ?? 0) }
        let costOut = h.live.filter { $0.type.direction == .outbound }.reduce(Int64(0)) { $0 + ($1.totalCostMinor ?? 0) }
        let adjust = h.live.filter { $0.type.direction == .costOnly }.reduce(Int64(0)) { $0 + ($1.totalCostMinor ?? 0) }
        XCTAssertEqual(b.costBalanceMinor, costIn - costOut + adjust,
                       "\(label): P2 (exact — D-3 parks the remainder in the balance)", file: file, line: line)

        // P3 — N-2. Sold out means sold out: no cost stranded behind a zero quantity.
        if b.quantityMilli == 0 {
            XCTAssertEqual(b.costBalanceMinor, 0, "\(label): P3 cost", file: file, line: line)
            XCTAssertEqual(b.unitCostMicro, 0, "\(label): P3 unit cost", file: file, line: line)
        }

        // P4a — always true: truncation toward zero can only leave the balance ABOVE the average's
        // implied value, never below.
        let implied = b.quantityMilli * b.unitCostMicro
        XCTAssertGreaterThanOrEqual(b.costBalanceMinor * InventoryPosting.scaleBridge, implied,
                                    "\(label): P4a", file: file, line: line)
        // P4b — the drift's real bound. Each average-priced issue can add up to one minor unit of
        // residue because the average is NOT recomputed (N-1); the earlier "< quantityMilli/1e9"
        // form held only in the instant after a recompute.
        let residue = b.costBalanceMinor * InventoryPosting.scaleBridge - implied
        let bound = h.quantityAtLastRecompute
            + Int64(h.averagePricedIssuesSinceRecompute) * InventoryPosting.scaleBridge
        XCTAssertLessThanOrEqual(residue, bound, """
            \(label): P4b — residue \(residue) exceeded \(h.quantityAtLastRecompute) + \
            \(h.averagePricedIssuesSinceRecompute)×1e9
            """, file: file, line: line)

        // P6 — never negative, under any sequence.
        XCTAssertGreaterThanOrEqual(b.quantityMilli, 0, "\(label): P6", file: file, line: line)
        XCTAssertGreaterThanOrEqual(b.costBalanceMinor, 0, "\(label): P6 cost side", file: file, line: line)

        // P0 — the cross-check. The incremental fold and a whole-history replay are separate code
        // paths; if either drifts, this is what catches it.
        XCTAssertEqual(try InventoryPosting.replay(h.live, productID: h.productID), b,
                       "\(label): P0 incremental == replay", file: file, line: line)
    }

    // MARK: - P0…P7 · property tests over pseudo-random histories

    /// The generator posts a mix of every kind. Refusals are EXPECTED and are themselves part of
    /// the property: a refused movement must leave the balance untouched, which is asserted at the
    /// point of refusal rather than inferred.
    func testP0toP7HoldOverPseudoRandomHistories() throws {
        for seed in [UInt64(1), 42, 1_337, 20_260_805, 0xDEAD_BEEF] {
            var rng = Seeded(seed: seed)
            var h = Harness()
            let dates = ["2026-01-01", "2026-01-02", "2026-02-01", "2026-03-15"]
            var dateIndex = 0

            for step in 0..<60 {
                if Int.random(in: 0..<10, using: &rng) == 0, dateIndex < dates.count - 1 { dateIndex += 1 }
                let date = dates[dateIndex]
                let before = h.balance
                let pick = Int.random(in: 0..<10, using: &rng)

                do {
                    switch pick {
                    case 0...3:
                        try h.post(.purchaseIn, on: date,
                                   qty: Int64.random(in: 1...9_000, using: &rng),
                                   unitCost: Int64.random(in: 0...5_000_000, using: &rng))
                    case 4...6:
                        // P5's subject: an average-priced issue must not move the unit cost.
                        let qty = Int64.random(in: 1...9_000, using: &rng)
                        let unitBefore = before.unitCostMicro
                        let posted = try h.post(.saleOut, on: date, qty: qty)
                        if h.balance.quantityMilli > 0 {
                            XCTAssertEqual(h.balance.unitCostMicro, unitBefore,
                                           "seed \(seed) step \(step): P5 — an issue moved the average")
                        }
                        XCTAssertNil(posted.unitCostMicro,
                                     "an average-priced issue carries no price of its own")
                    case 7:
                        try h.post(.countLoss, on: date, qty: Int64.random(in: 1...4_000, using: &rng))
                    case 8:
                        try h.post(.countGain, on: date,
                                   qty: Int64.random(in: 1...4_000, using: &rng),
                                   unitCost: Int64.random(in: 0...5_000_000, using: &rng))
                    default:
                        try h.post(.manualAdjust, on: date,
                                   delta: Int64.random(in: -200...200, using: &rng))
                    }
                } catch let error as InventoryPostingError {
                    XCTAssertEqual(h.balance, before, """
                        seed \(seed) step \(step): a refusal (\(error)) must leave the balance \
                        byte-identical — no partial application
                        """)
                    continue
                }
                try assertInvariants(h, "seed \(seed) step \(step)")
            }

            // P7 — reversing the last movement lands on the state before it. THREE components,
            // including the unit cost: restoring only (quantity, cost) is what G1 showed to be
            // insufficient, and replay is what makes the third exact.
            guard h.live.count >= 2 else { continue }
            let beforeLast = try InventoryPosting.replay(h.live.dropLast(), productID: h.productID)
            let reversed = try h.balanceAfterReversingLast()
            XCTAssertEqual(reversed.triple.quantityMilli, beforeLast.triple.quantityMilli, "seed \(seed): P7 qty")
            XCTAssertEqual(reversed.triple.costBalanceMinor, beforeLast.triple.costBalanceMinor, "seed \(seed): P7 cost")
            XCTAssertEqual(reversed.triple.unitCostMicro, beforeLast.triple.unitCostMicro, "seed \(seed): P7 unit cost")
        }
    }

    /// P8 — quantities of different products never enter the same addition. A source guard rather
    /// than a value assertion, because the property is about what the code CAN do: an aggregate
    /// without a `product_id` filter would be wrong even on a ledger holding one product.
    func testP8NoAggregateCrossesProducts() throws {
        let ledger = try Self.engineSource("InventoryLedger.swift")
        let reads = Self.readsOfInventoryTables(in: ledger)
        XCTAssertGreaterThanOrEqual(reads.count, 6,
                                    "the scan found almost nothing — it is not reading the source")
        for read in reads {
            XCTAssertTrue(read.contains("product_id = ?") || read.contains("m.id = ?"), """
                An inventory read that is not scoped to ONE product. Quantities of different \
                products are in different units (N-9 / G23), so an aggregate across them is \
                meaningless: \(read.prefix(200))
                """)
        }
        // And the pure state machine has no notion of a second product at all.
        let posting = try Self.engineSource("InventoryPosting.swift")
        XCTAssertFalse(posting.contains("SELECT"), "the state machine must stay free of SQL")
    }

    /// The scan must be able to see an unscoped read, or a clean result proves nothing.
    func testP8ScanDetectsAnUnscopedRead() {
        let offending = "let x = db.query(\"SELECT SUM(quantity_milli) FROM inventory_movements\")"
        let reads = Self.readsOfInventoryTables(in: offending)
        XCTAssertEqual(reads.count, 1)
        XCTAssertFalse(reads[0].contains("product_id = ?"), "the scan would have missed this one")
    }

    // MARK: - A · N-1 / N-2 moving average

    func testA1TwoReceiptsAverage() throws {
        var h = Harness()
        try h.post(.purchaseIn, on: "2026-01-01", qty: 10_000, unitCost: 100_000_000)   // 10 @ 100
        try h.post(.purchaseIn, on: "2026-01-02", qty: 10_000, unitCost: 200_000_000)   // 10 @ 200
        XCTAssertEqual(h.balance.unitCostMicro, 150_000_000, "N-1: (1000+2000)/20 = 150")
        XCTAssertEqual(h.balance.costBalanceMinor, 3_000)
        try assertInvariants(h, "A1")
    }

    func testA2AnIssueDoesNotMoveTheAverage() throws {
        var h = Harness()
        try h.post(.purchaseIn, on: "2026-01-01", qty: 10_000, unitCost: 100_000_000)
        try h.post(.saleOut, on: "2026-01-02", qty: 4_000)
        XCTAssertEqual(h.balance.unitCostMicro, 100_000_000, "N-1 / P5")
        XCTAssertEqual(h.balance.quantityMilli, 6_000)
        XCTAssertEqual(h.balance.costBalanceMinor, 600)
        try assertInvariants(h, "A2")
    }

    /// A3 — THE regression. This is the sequence the audited Electron implementation gets wrong:
    /// it reports a remaining cost of 1500 because its denominator never sees the sale. Any change
    /// that reintroduces a purchases-to-date average fails here.
    func testA3TheElectronCounterexampleSellOutThenRebuyAtANewPrice() throws {
        var h = Harness()
        try h.post(.purchaseIn, on: "2026-01-01", qty: 10_000, unitCost: 100_000_000)
        try h.post(.saleOut, on: "2026-01-02", qty: 10_000)
        try h.post(.purchaseIn, on: "2026-01-03", qty: 10_000, unitCost: 200_000_000)
        XCTAssertEqual(h.balance.unitCostMicro, 200_000_000, "N-2: the new stock owes nothing to the old price")
        XCTAssertEqual(h.balance.costBalanceMinor, 2_000, "the audited Electron read gives 1500 here")
        try assertInvariants(h, "A3")
    }

    func testA4SellingOutZeroesAllThree() throws {
        var h = Harness()
        try h.post(.purchaseIn, on: "2026-01-01", qty: 10_000, unitCost: 100_000_000)
        try h.post(.saleOut, on: "2026-01-02", qty: 10_000)
        XCTAssertEqual(h.balance.triple.quantityMilli, 0)
        XCTAssertEqual(h.balance.triple.costBalanceMinor, 0)
        XCTAssertEqual(h.balance.triple.unitCostMicro, 0)
        try assertInvariants(h, "A4")
    }

    func testA5AfterSellingOutTheNextReceiptSetsThePriceAlone() throws {
        var h = Harness()
        try h.post(.purchaseIn, on: "2026-01-01", qty: 10_000, unitCost: 100_000_000)
        try h.post(.saleOut, on: "2026-01-02", qty: 10_000)
        try h.post(.purchaseIn, on: "2026-01-03", qty: 5_000, unitCost: 300_000_000)
        XCTAssertEqual(h.balance.unitCostMicro, 300_000_000)
        try assertInvariants(h, "A5")
    }

    /// A6 — D-3's truncation, and the seam N-2 makes with it: the residue the average cannot carry
    /// stays in the balance and LEAVES with the last unit, so nothing is ever silently dropped.
    func testA6TheTruncationResidueRidesOutWithTheZeroingIssue() throws {
        var h = Harness()
        try h.post(.purchaseIn, on: "2026-01-01", qty: 3_000, unitCost: 333_333_333)
        XCTAssertEqual(h.balance.costBalanceMinor, 999, "3000 × 333333333 / 1e9 truncates to 999")
        try h.post(.saleOut, on: "2026-01-02", qty: 1_000)
        XCTAssertEqual(h.balance.costBalanceMinor, 666)
        let zeroing = try h.post(.saleOut, on: "2026-01-03", qty: 2_000)
        XCTAssertEqual(zeroing.totalCostMinor, 666,
                       "N-2: a zeroing issue takes the WHOLE remaining balance, residue included")
        XCTAssertEqual(h.balance.triple.costBalanceMinor, 0)
        try assertInvariants(h, "A6")
    }

    // MARK: - B · N-5 no negative stock

    func testBGroupNegativeStockIsRefusedAndChangesNothing() throws {
        var h = Harness()
        try h.post(.purchaseIn, on: "2026-01-01", qty: 5_000, unitCost: 100_000_000)
        let before = h.balance

        // B1 — more than is on hand.
        XCTAssertThrowsError(try h.post(.saleOut, on: "2026-01-02", qty: 6_000)) {
            XCTAssertEqual($0 as? InventoryPostingError, .insufficientStock)
        }
        XCTAssertEqual(h.balance, before, "B1: a refusal leaves the balance byte-identical")

        // B2 — exactly what is on hand succeeds and zeroes.
        try h.post(.saleOut, on: "2026-01-02", qty: 5_000)
        XCTAssertEqual(h.balance.quantityMilli, 0)

        // B3 — nothing on hand at all.
        XCTAssertThrowsError(try h.post(.saleOut, on: "2026-01-03", qty: 1)) {
            XCTAssertEqual($0 as? InventoryPostingError, .insufficientStock)
        }
        try assertInvariants(h, "B")
    }

    // MARK: - C · N-6 no backdating

    func testCGroupBackdatedMovementsAreRefused() throws {
        var h = Harness()
        try h.post(.purchaseIn, on: "2026-08-05", qty: 5_000, unitCost: 100_000_000)
        let before = h.balance

        // C1 — dated before the last movement.
        XCTAssertThrowsError(try h.post(.purchaseIn, on: "2026-08-01", qty: 1_000, unitCost: 1)) {
            XCTAssertEqual($0 as? InventoryPostingError, .backdatedNotSupported)
        }
        XCTAssertEqual(h.balance, before, "C4: nothing was written")

        // C3 — the same day is fine; `seq` orders it after, and the caller never chooses `seq`
        // (D-4), so "same day, earlier position" is not expressible.
        XCTAssertNoThrow(try h.post(.purchaseIn, on: "2026-08-05", qty: 1_000, unitCost: 1))
        XCTAssertEqual(h.live.last?.seq, 2, "D-4: the engine assigned the next position")
        try assertInvariants(h, "C")
    }

    // MARK: - D · N-7 tax basis, D-10 zero cost

    func testDGroupAnInboundWithoutANetPriceIsRefusedButZeroIsLegal() throws {
        var h = Harness()

        // D1 — N-7. Absent is refused, and never falls back to a tax-inclusive figure.
        XCTAssertThrowsError(try h.post(.purchaseIn, on: "2026-01-01", qty: 1_000, unitCost: nil)) {
            XCTAssertEqual($0 as? InventoryPostingError, .netAmountRequired)
        }
        // A count gain is an inbound too: it may NOT quietly borrow the current average.
        XCTAssertThrowsError(try h.post(.countGain, on: "2026-01-01", qty: 1_000, unitCost: nil)) {
            XCTAssertEqual($0 as? InventoryPostingError, .netAmountRequired)
        }
        // Negative is structural nonsense, and distinct from the legal zero below.
        XCTAssertThrowsError(try h.post(.purchaseIn, on: "2026-01-01", qty: 1_000, unitCost: -1)) {
            XCTAssertEqual($0 as? InventoryPostingError, .unitCostMustNotBeNegative)
        }

        // D2 / D-10 — an explicit zero is a free sample, not a missing figure. It dilutes normally.
        try h.post(.purchaseIn, on: "2026-01-01", qty: 10_000, unitCost: 100_000_000)
        try h.post(.purchaseIn, on: "2026-01-02", qty: 10_000, unitCost: 0)
        XCTAssertEqual(h.balance.unitCostMicro, 50_000_000, "D-10: 1000 minor over 20 units")

        // D3 — an issue carries no price of its own; that is N-1 working, not a missing field.
        XCTAssertNoThrow(try h.post(.saleOut, on: "2026-01-03", qty: 1_000))
        try assertInvariants(h, "D")
    }

    // MARK: - E · N-4 returns, D-11 ceiling

    func testEGroupReturnsUseTheOriginPriceAndAreCappedCumulatively() throws {
        var h = Harness()
        try h.post(.purchaseIn, on: "2026-01-01", qty: 10_000, unitCost: 100_000_000)
        try h.post(.saleOut, on: "2026-01-02", qty: 10_000)     // sells out; average was 100
        let origin = InventoryOriginFacts(quantityMilli: 10_000, unitCostMicro: 100_000_000,
                                          alreadyReturnedMilli: 0)

        // E1 — the origin is findable, so the return restores what the sale removed, NOT today's
        // average (which is zero here, the stock having gone).
        try h.post(.saleReturnIn, on: "2026-01-03", qty: 4_000,
                   source: ("sale", "s1"), origin: origin)
        XCTAssertEqual(h.balance.costBalanceMinor, 400, "N-4: 4 units at the sale's own 100")
        XCTAssertEqual(h.balance.unitCostMicro, 100_000_000)
        try assertInvariants(h, "E1")

        // E4 / D-11 — CUMULATIVE. 4 back already, 7 more would be 11 against an order of 10.
        let after4 = InventoryOriginFacts(quantityMilli: 10_000, unitCostMicro: 100_000_000,
                                          alreadyReturnedMilli: 4_000)
        XCTAssertThrowsError(try h.post(.saleReturnIn, on: "2026-01-04", qty: 7_000,
                                        source: ("sale", "s1"), origin: after4)) {
            XCTAssertEqual($0 as? InventoryPostingError, .returnExceedsOrigin)
        }
        // …and 6 more, reaching exactly 10, is allowed.
        XCTAssertNoThrow(try h.post(.saleReturnIn, on: "2026-01-04", qty: 6_000,
                                    source: ("sale", "s1"), origin: after4))
        try assertInvariants(h, "E4")
    }

    func testE2AReturnWithNoFindableOriginIsPostedAtTheAverageAndFlagged() throws {
        var h = Harness()
        try h.post(.purchaseIn, on: "2026-01-01", qty: 10_000, unitCost: 100_000_000)
        try h.post(.saleOut, on: "2026-01-02", qty: 2_000)

        let request = InventoryPostingRequest(productID: "p1", type: .saleReturnIn,
                                              occurredOn: "2026-01-03", quantityMilli: 1_000,
                                              currency: "CNY")
        let plan = try InventoryPosting.plan(
            request: request, balance: h.balance,
            context: InventoryPostingContext(hasLiveMovements: true, origin: nil, seq: 1, movementID: "x"))
        XCTAssertEqual(plan.exception, .returnOriginNotFound,
                       "N-4 requires this to be visible afterwards, not merely accepted")
        XCTAssertEqual(plan.movement.unitCostMicro, 100_000_000, "priced at the current average")
        // No ceiling is applied — there is no document to measure against (F3). The flag is what
        // keeps it traceable.
        XCTAssertNoThrow(try InventoryPosting.plan(
            request: InventoryPostingRequest(productID: "p1", type: .saleReturnIn,
                                             occurredOn: "2026-01-03", quantityMilli: 9_999_000,
                                             currency: "CNY"),
            balance: h.balance,
            context: InventoryPostingContext(hasLiveMovements: true, origin: nil, seq: 2, movementID: "y")))
    }

    /// E3 — a supplier return reverses the ORIGINAL purchase price, which in general is not the
    /// current average. P5 therefore does not apply to it, and the average of what remains moves.
    func testE3ASupplierReturnUsesTheOriginalPurchasePriceAndMovesTheAverage() throws {
        var h = Harness()
        try h.post(.purchaseIn, on: "2026-01-01", qty: 10_000, unitCost: 100_000_000)
        try h.post(.purchaseIn, on: "2026-01-02", qty: 10_000, unitCost: 200_000_000)
        XCTAssertEqual(h.balance.unitCostMicro, 150_000_000)

        let origin = InventoryOriginFacts(quantityMilli: 10_000, unitCostMicro: 200_000_000,
                                          alreadyReturnedMilli: 0)
        try h.post(.purchaseReturnOut, on: "2026-01-03", qty: 10_000,
                   source: ("purchase", "p-2"), origin: origin)
        XCTAssertEqual(h.balance.costBalanceMinor, 1_000, "3000 − the returned 2000")
        XCTAssertEqual(h.balance.unitCostMicro, 100_000_000,
                       "N-4 pulled out the 200 batch, so what remains is the 100 batch")
        XCTAssertFalse(InventoryMovementType.purchaseReturnOut.isAveragePricedOutbound,
                       "P5 is scoped to average-priced issues and this is not one")
        try assertInvariants(h, "E3")
    }

    // MARK: - F1 案丙 · the cost-only adjustment and its two guards

    func testTheManualAdjustmentMovesCostOnlyAndRecomputesTheAverage() throws {
        var h = Harness()
        try h.post(.purchaseIn, on: "2026-01-01", qty: 10_000, unitCost: 100_000_000)

        // Positive: the purchase price was keyed in low.
        try h.post(.manualAdjust, on: "2026-01-02", delta: 200)
        XCTAssertEqual(h.balance.quantityMilli, 10_000, "quantity is untouched — that is the point")
        XCTAssertEqual(h.balance.costBalanceMinor, 1_200)
        XCTAssertEqual(h.balance.unitCostMicro, 120_000_000, "D-3: recomputed as trunc(cost/qty)")

        // Negative: keyed in high.
        try h.post(.manualAdjust, on: "2026-01-03", delta: -400)
        XCTAssertEqual(h.balance.costBalanceMinor, 800)
        XCTAssertEqual(h.balance.unitCostMicro, 80_000_000)
        try assertInvariants(h, "manual adjust")
    }

    func testTheManualAdjustmentsTwoGuards() throws {
        var h = Harness()
        try h.post(.purchaseIn, on: "2026-01-01", qty: 10_000, unitCost: 100_000_000)
        let before = h.balance

        // Guard ① — N-5's dual on the cost side.
        XCTAssertThrowsError(try h.post(.manualAdjust, on: "2026-01-02", delta: -1_001)) {
            XCTAssertEqual($0 as? InventoryPostingError, .costBalanceWouldGoNegative)
        }
        XCTAssertEqual(h.balance, before)
        // …and exactly to zero is allowed: the guard is on going BELOW zero.
        XCTAssertNoThrow(try h.post(.manualAdjust, on: "2026-01-02", delta: -1_000))
        XCTAssertEqual(h.balance.costBalanceMinor, 0)
        XCTAssertEqual(h.balance.unitCostMicro, 0)

        // A quantity on a cost-only kind is a category error, not a rounding detail.
        XCTAssertThrowsError(try h.post(.manualAdjust, on: "2026-01-03", qty: 1, delta: 1)) {
            XCTAssertEqual($0 as? InventoryPostingError, .manualAdjustMustNotMoveQuantity)
        }
        // A missing amount is refused rather than treated as zero.
        XCTAssertThrowsError(try h.post(.manualAdjust, on: "2026-01-03", delta: nil)) {
            XCTAssertEqual($0 as? InventoryPostingError, .netAmountRequired)
        }

        // Guard ② — nothing on hand. Allowing it would create qty == 0 with cost != 0, which is
        // exactly what N-2 and P3 forbid.
        var empty = Harness(productID: "p2")
        try empty.post(.purchaseIn, on: "2026-01-01", qty: 1_000, unitCost: 1_000_000)
        try empty.post(.saleOut, on: "2026-01-02", qty: 1_000)
        XCTAssertThrowsError(try empty.post(.manualAdjust, on: "2026-01-03", delta: 50)) {
            XCTAssertEqual($0 as? InventoryPostingError, .manualAdjustRequiresStock)
        }
        try assertInvariants(empty, "manual adjust guard 2")
    }

    // MARK: - D-1 currency freeze · D-5 opening first

    func testD1TheFirstReceiptFreezesTheCurrencyAndNoRateIsEverApplied() throws {
        var h = Harness()
        try h.post(.purchaseIn, on: "2026-01-01", qty: 1_000, unitCost: 1_000_000)
        XCTAssertEqual(h.balance.currency, "CNY")
        XCTAssertThrowsError(try h.post(.purchaseIn, on: "2026-01-02", qty: 1_000,
                                        unitCost: 1_000_000, currencyOverride: "USD")) {
            XCTAssertEqual($0 as? InventoryPostingError, .currencyMismatch)
        }
        XCTAssertEqual(h.balance.quantityMilli, 1_000, "the refused receipt changed nothing")
    }

    func testD5AnOpeningMustBeTheFirstMovement() throws {
        var h = Harness()
        try h.post(.opening, on: "2026-01-01", qty: 10_000, unitCost: 100_000_000)
        XCTAssertThrowsError(try h.post(.opening, on: "2026-01-02", qty: 1_000, unitCost: 1)) {
            XCTAssertEqual($0 as? InventoryPostingError, .openingMustBeFirst)
        }
        // And on a product that already has ordinary movements.
        var used = Harness(productID: "p3")
        try used.post(.purchaseIn, on: "2026-01-01", qty: 1_000, unitCost: 1_000_000)
        XCTAssertThrowsError(try used.post(.opening, on: "2026-01-02", qty: 1_000, unitCost: 1)) {
            XCTAssertEqual($0 as? InventoryPostingError, .openingMustBeFirst)
        }
    }

    // MARK: - G1 · the two measured counterexamples, as regressions

    /// Counterexample A — reversing an issue that emptied the stock. Subtraction restores the
    /// quantity and the cost but lands the average on 333_500_000 instead of 333_333_333; replay
    /// lands on all three.
    func testG1CounterexampleAReversingAZeroingIssueRestoresAllThree() throws {
        var h = Harness()
        try h.post(.purchaseIn, on: "2026-01-01", qty: 3_000, unitCost: 333_333_334)
        try h.post(.saleOut, on: "2026-01-02", qty: 1_000)
        let target = h.balance.triple
        XCTAssertEqual(target.quantityMilli, 2_000)
        XCTAssertEqual(target.costBalanceMinor, 667)
        XCTAssertEqual(target.unitCostMicro, 333_333_333,
                       "the average carries a residue: 667 × 1e9 / 2000 would be 333_500_000")

        try h.post(.saleOut, on: "2026-01-03", qty: 2_000)          // zeroing
        XCTAssertEqual(h.balance.triple.costBalanceMinor, 0)

        let restored = try h.balanceAfterReversingLast()
        XCTAssertEqual(restored.triple.quantityMilli, target.quantityMilli)
        XCTAssertEqual(restored.triple.costBalanceMinor, target.costBalanceMinor)
        XCTAssertEqual(restored.triple.unitCostMicro, target.unitCostMicro, """
            P7's third component. Subtracting the reversed row would give 333500000 here — the \
            average is a STATE (N-1 freezes it across issues), not a function of (qty, cost).
            """)
    }

    /// Counterexample B — the same failure with no sell-out anywhere in sight: reversing a RECEIPT
    /// after an earlier issue left a residue.
    func testG1CounterexampleBReversingAReceiptRestoresAllThree() throws {
        var h = Harness()
        try h.post(.purchaseIn, on: "2026-01-01", qty: 3_000, unitCost: 333_333_334)
        try h.post(.saleOut, on: "2026-01-02", qty: 1_000)
        let target = h.balance.triple
        XCTAssertEqual(target.unitCostMicro, 333_333_333)

        try h.post(.purchaseIn, on: "2026-01-03", qty: 2_000, unitCost: 250_000_000)  // +500 minor
        XCTAssertNotEqual(h.balance.triple.unitCostMicro, target.unitCostMicro)

        let restored = try h.balanceAfterReversingLast()
        XCTAssertEqual(restored.triple.quantityMilli, target.quantityMilli)
        XCTAssertEqual(restored.triple.costBalanceMinor, target.costBalanceMinor)
        XCTAssertEqual(restored.triple.unitCostMicro, target.unitCostMicro,
                       "subtraction would give 333500000 here too — and nothing sold out")
    }

    // MARK: - Overflow (N1 §2.4)

    func testTheScaledProductRefusesOverflowInsteadOfWrapping() throws {
        // A line cost that leaves Int64: 1e12 milli-units at 1e9 micro is 1e21, far past 9.2e18.
        XCTAssertThrowsError(try InventoryPosting.costOfQuantity(quantityMilli: 1_000_000_000_000,
                                                                 unitCostMicro: 1_000_000_000)) {
            XCTAssertEqual($0 as? InventoryPostingError, .arithmeticOverflow)
        }
        // The average's numerator has the same ceiling — a cost balance above ~9.2e9 minor units.
        XCTAssertThrowsError(try InventoryPosting.averageMicro(costMinor: 10_000_000_000,
                                                               quantityMilli: 1_000)) {
            XCTAssertEqual($0 as? InventoryPostingError, .arithmeticOverflow)
        }
        // And a legal figure still computes, so the guard is not simply refusing everything.
        XCTAssertEqual(try InventoryPosting.costOfQuantity(quantityMilli: 3_000, unitCostMicro: 333_333_333), 999)
        XCTAssertEqual(try InventoryPosting.averageMicro(costMinor: 1_000, quantityMilli: 3_000), 333_333_333)
    }

    /// The truncation is toward ZERO and D-3 says the remainder stays in the balance. Both halves,
    /// because a change of rounding direction here would move money and pass every scenario above.
    func testTheAverageTruncatesTowardZero() throws {
        XCTAssertEqual(try InventoryPosting.averageMicro(costMinor: 1_000, quantityMilli: 3_000), 333_333_333,
                       "not 333_333_334 — D-3 truncates, it does not round")
        XCTAssertEqual(try InventoryPosting.averageMicro(costMinor: 2, quantityMilli: 3), 666_666_666)
        XCTAssertEqual(try InventoryPosting.averageMicro(costMinor: 0, quantityMilli: 0), 0)
    }

    // MARK: - The mutation points, named

    /// Not a behaviour test: the checklist a reviewer holds against the code. Each entry names a
    /// decision whose removal must turn a test red; the PR report records the measured result.
    ///
    /// The list is longer than the ruling asked for because running it found something: the F1
    /// guards had been written TWICE — once in `plan` and once in `apply` — so removing either copy
    /// changed no observable behaviour and the mutation survived. They are now enforced once, in
    /// `apply`, which is also the copy replay needs. A surviving mutation is a fact about the code,
    /// not a gap in the test.
    func testTheMutationPointsAreEnumerated() {
        let points = [
            "N-1: an average-priced issue leaves unitCostMicro alone (→ A2/P5/G1)",
            "N-2: a zeroing issue takes the whole remaining balance (→ A4/A6/G1-A)",
            "N-5: the insufficient-stock guard (→ B)",
            "N-6: the backdating guard (→ C)",
            "N-7: the missing-net-price guard (→ D)",
            "D-1: the currency freeze (→ the D-1 group)",
            "D-3: the average truncates toward zero (→ A6 + the truncation test)",
            "D-5: the opening-must-be-first guard (→ the D-5 group)",
            "D-11: the return ceiling is cumulative (→ E4)",
            "F1 案丙: manual_adjust is cost-only, not an inbound (→ the manual-adjustment group)",
            "F1 guard ①: the cost balance may not go negative (→ the two-guards test)",
            "F1 guard ②: a cost adjustment needs stock on hand (→ the two-guards test)",
            "F1: manual_adjust may not carry a quantity (→ the two-guards test)",
            "F2: a reversal row takes the opposite direction (→ the reversal chain test)",
        ]
        XCTAssertEqual(points.count, 14, "fourteen mutation points, each with its guarding test")
    }

    // MARK: - Source helpers

    private static func engineSource(_ name: String) throws -> String {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { dir.deleteLastPathComponent() }
        let url = dir.appendingPathComponent("Sources/SoloLedgerCore/Inventory/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Every read of an inventory table, as the text that follows its `FROM`.
    ///
    /// Anchored on `FROM inventory_` rather than on `SELECT`, because several queries build their
    /// column list by interpolation and so carry no literal `SELECT` at all — a `SELECT`-anchored
    /// scan would silently skip exactly those.
    private static func readsOfInventoryTables(in source: String) -> [String] {
        source.components(separatedBy: "FROM inventory_").dropFirst().map { chunk in
            String(chunk.prefix(400))
        }
    }
}
