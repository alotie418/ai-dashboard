import XCTest
@testable import SoloLedgerCore

/// `MonthlyComparisons` — the mirror of `electron/handlers/_metrics.js`.
///
/// Two groups, and the split is the point.
///
/// **M1–M5 restate `scripts/test-metrics.mjs` case for case.** That script is the JS side's
/// standing contract (it runs as `npm run check:metrics`, inside `check:all`), so every case it
/// pins is pinned here against the same numbers. If the two ever disagree, one of them has
/// drifted and this file says which.
///
/// **M6–M12 are the cases that script does NOT cover** — negative and `NaN` bases, `-0`, a short
/// `priorRevenue`, an empty or single-element input, and a negative revenue against real volume.
/// Their expected values were not derived by reading the source: each was produced by running the
/// real `_metrics.js` under node and recorded verbatim. Reasoning would not have been enough —
/// `pct(100.05, 100)` is `0` and not `0.1`, and no amount of reading the expression makes that
/// obvious.
final class MonthlyComparisonsTests: XCTestCase {

    // MARK: - Helpers

    /// `-0` and `+0` compare equal, so an assertion written with `==` cannot see the difference.
    /// Several results below ARE `-0`, and that is a fact about the mirror worth holding.
    private func assertIsNegativeZero(_ value: Double?, _ message: String,
                                      file: StaticString = #filePath, line: UInt = #line) {
        guard let value else {
            return XCTFail("\(message): expected -0, got nil", file: file, line: line)
        }
        XCTAssertTrue(value == 0 && value.sign == .minus,
                      "\(message): expected -0, got \(value)", file: file, line: line)
    }

    private func rows(_ pairs: [(Double?, Double?)]) -> [MonthlyComparisons.Row] {
        pairs.map { MonthlyComparisons.Row(revenue: $0.0, salesTons: $0.1) }
    }

    // ==============================================================================================
    // MARK: - M1…M5 — every case scripts/test-metrics.mjs pins
    // ==============================================================================================

    /// `test-metrics.mjs:18-21`.
    func testM1PctMatchesTheJavaScriptContract() {
        XCTAssertNil(MonthlyComparisons.pct(100, 0), "base 0 → null")
        XCTAssertNil(MonthlyComparisons.pct(100, nil), "base null → null")
        XCTAssertEqual(MonthlyComparisons.pct(120, 100), 20)
        XCTAssertEqual(MonthlyComparisons.pct(90, 120), -25)
    }

    /// `test-metrics.mjs:24-33` — mom and yoy over three months with a full prior year.
    func testM2MomAndYoyOverThreeMonths() {
        let out = MonthlyComparisons.compute(rows([(100, 0), (120, 0), (90, 0)]),
                                             priorRevenue: [80, 100, 100])
        XCTAssertNil(out[0].mom, "no prior month")
        XCTAssertEqual(out[1].mom, 20)
        XCTAssertEqual(out[2].mom, -25)
        XCTAssertEqual(out[0].yoy, 25)
        XCTAssertEqual(out[1].yoy, 20)
        XCTAssertEqual(out[2].yoy, -10)
    }

    /// `test-metrics.mjs:34-37` — an empty prior year makes every `yoy` null.
    ///
    /// The JS guard is `priorRevenue ? priorRevenue[i] : null`, and `[]` is TRUTHY in JS, so the
    /// empty array is indexed rather than short-circuited. It reaches the same answer by the
    /// other road, which is why this case is worth its own test.
    func testM3AnEmptyPriorYearMakesEveryYoyNull() {
        let out = MonthlyComparisons.compute(rows([(100, 0), (120, 0)]), priorRevenue: [])
        XCTAssertTrue(out.allSatisfy { $0.yoy == nil })
    }

    /// `test-metrics.mjs:38-43` — the contract this whole file exists for: a zero base period
    /// reports NOTHING, never `0.0%`.
    func testM4AZeroBasePeriodIsNullAndNotZeroPercent() {
        let out = MonthlyComparisons.compute(rows([(0, 0), (100, 0)]), priorRevenue: [0, 50])
        XCTAssertNil(out[1].mom, "mom base 0 → null, NOT 0.0%")
        XCTAssertNil(out[0].yoy, "yoy base 0 → null")
        XCTAssertEqual(out[1].yoy, 100)
    }

    /// `test-metrics.mjs:45-58` — the price index, and the month with no volume in the middle.
    func testM5DeflatorMatchesTheJavaScriptContract() {
        let out = MonthlyComparisons.compute(rows([(100, 10), (50, 0), (80, 5)]))
        XCTAssertEqual(out[0].deflator ?? .nan, 76.9, accuracy: 0.05)
        XCTAssertNil(out[1].deflator, "salesTons 0 → null")
        XCTAssertEqual(out[2].deflator ?? .nan, 123.1, accuracy: 0.05)

        let none = MonthlyComparisons.compute(rows([(100, 0), (50, 0)]))
        XCTAssertTrue(none.allSatisfy { $0.deflator == nil }, "no sales volume → all null")
    }

    // ==============================================================================================
    // MARK: - M6…M12 — the boundaries test-metrics.mjs leaves open
    // ==============================================================================================

    /// `Math.round` ties go toward +∞, and the result keeps a negative zero.
    ///
    /// Swift's own `rounded()` rounds ties AWAY from zero, so `(-1.5).rounded()` is `-2` where
    /// JS gives `-1`. Every value here was read off the real engine.
    func testM6JsRoundTiesGoTowardPositiveInfinity() {
        XCTAssertEqual(MonthlyComparisons.jsRound(0.5), 1)
        XCTAssertEqual(MonthlyComparisons.jsRound(1.5), 2)
        XCTAssertEqual(MonthlyComparisons.jsRound(2.5), 3)
        XCTAssertEqual(MonthlyComparisons.jsRound(-1.5), -1, "JS gives -1; Swift's rounded() gives -2")
        XCTAssertEqual(MonthlyComparisons.jsRound(-2.5), -2)

        assertIsNegativeZero(MonthlyComparisons.jsRound(-0.5), "Math.round(-0.5)")
        assertIsNegativeZero(MonthlyComparisons.jsRound(-0.4), "Math.round(-0.4)")

        // Not `floor(x + 0.5)`: that addition would round up to exactly 1.0 first.
        XCTAssertEqual(MonthlyComparisons.jsRound(0.49999999999999994), 0)
        assertIsNegativeZero(MonthlyComparisons.jsRound(-0.49999999999999994),
                             "Math.round(-0.49999999999999994)")

        // Sign-preserving pass-through.
        assertIsNegativeZero(MonthlyComparisons.jsRound(-0.0), "Math.round(-0)")
        XCTAssertTrue(MonthlyComparisons.jsRound(.nan).isNaN)
        XCTAssertEqual(MonthlyComparisons.jsRound(.infinity), .infinity)
        XCTAssertEqual(MonthlyComparisons.jsRound(-.infinity), -.infinity)
    }

    /// A `NaN` base is NOT a missing base. `_metrics.js:10` tests `base == null` and
    /// `base === 0`; `NaN` is neither, so the function returns the NUMBER `NaN`.
    ///
    /// This is the one case where "null-ish" intuition gives the wrong answer, and it is why the
    /// mirror's return type distinguishes `nil` from `.some(.nan)`.
    func testM7ANaNBaseReturnsNaNAndNotNull() {
        let result = MonthlyComparisons.pct(100, .nan)
        XCTAssertNotNil(result, "a NaN base must NOT collapse to null")
        XCTAssertTrue(result?.isNaN == true)

        XCTAssertTrue(MonthlyComparisons.pct(.nan, 100)?.isNaN == true, "a NaN current is NaN too")
    }

    /// `-0` as a base is caught by `base === 0`, because `-0 === 0` is true.
    /// A negative base, by contrast, is an ordinary case.
    func testM8NegativeZeroBaseIsNullButANegativeBaseIsNot() {
        XCTAssertNil(MonthlyComparisons.pct(100, -0.0), "-0 === 0 in JS, so this is null")
        XCTAssertEqual(MonthlyComparisons.pct(90, -100), -190)
    }

    /// Percentages that land just under a tie, and the `-0` results that come out of it.
    ///
    /// `pct(100.05, 100)` is `0` and not `0.1`: `100.05 - 100` is `0.04999999999999716`, so the
    /// scaled value is `0.4999999999999716` and rounds DOWN. Doing the arithmetic in a different
    /// order — or in `Decimal` — gives `0.1` and silently breaks the mirror.
    func testM9FloatingPointOrderIsObservable() {
        XCTAssertEqual(MonthlyComparisons.pct(100.05, 100), 0,
                       "the subtraction loses the exact 0.05, so this rounds down")
        assertIsNegativeZero(MonthlyComparisons.pct(99.95, 100), "pct(99.95, 100)")
        assertIsNegativeZero(MonthlyComparisons.pct(99.9999999, 100), "a tiny drop")
        XCTAssertEqual(MonthlyComparisons.pct(100.0000001, 100), 0, "a tiny rise is +0")
        XCTAssertEqual(MonthlyComparisons.pct(100, 100), 0, "no change")
    }

    /// Infinities, which arithmetic can produce even when no input is infinite.
    func testM10Infinities() {
        XCTAssertEqual(MonthlyComparisons.pct(.infinity, 100), .infinity)
        XCTAssertTrue(MonthlyComparisons.pct(100, .infinity)?.isNaN == true)
        XCTAssertTrue(MonthlyComparisons.pct(.infinity, .infinity)?.isNaN == true)
    }

    /// Shapes of the input arrays that `test-metrics.mjs` never builds.
    func testM11EmptySingleAndShortPriorArrays() {
        XCTAssertTrue(MonthlyComparisons.compute([], priorRevenue: [1, 2, 3]).isEmpty)

        let single = MonthlyComparisons.compute(rows([(100, 0)]))
        XCTAssertEqual(single.count, 1)
        XCTAssertEqual(single[0], MonthlyComparisons.Comparison(mom: nil, yoy: nil, deflator: nil))

        // A prior-year array shorter than the input: past its end the JS reads `undefined`.
        let short = MonthlyComparisons.compute(rows([(100, 0), (120, 0), (90, 0)]),
                                               priorRevenue: [80])
        XCTAssertEqual(short[0].yoy, 25)
        XCTAssertNil(short[1].yoy)
        XCTAssertNil(short[2].yoy)

        // An explicit `null` entry and an explicit `0` entry are both null bases.
        let holes = MonthlyComparisons.compute(rows([(100, 0), (120, 0)]),
                                               priorRevenue: [nil, 0])
        XCTAssertNil(holes[0].yoy)
        XCTAssertNil(holes[1].yoy)
    }

    /// Volume with a NEGATIVE revenue — a refund-heavy month — and the guard that catches the
    /// case where the mean unit revenue itself goes non-positive.
    func testM12NegativeRevenueAgainstRealVolume() {
        // Unit revenues −10 and 16 → mean 3 → a negative index, which the JS does produce.
        let mixed = MonthlyComparisons.compute(rows([(-100, 10), (80, 5)]))
        XCTAssertEqual(mixed[0].deflator ?? .nan, -333.3, accuracy: 0.05)
        XCTAssertEqual(mixed[1].deflator ?? .nan, 533.3, accuracy: 0.05)
        XCTAssertEqual(mixed[1].mom, -180)

        // Both unit revenues negative → mean ≤ 0 → the guard drops the whole column.
        let allNegative = MonthlyComparisons.compute(rows([(-100, 10), (-80, 5)]))
        XCTAssertTrue(allNegative.allSatisfy { $0.deflator == nil })
        XCTAssertEqual(allNegative[1].mom, -20)

        // `|| 0` folds NaN and a missing property alike, so those months never enter the mean.
        let nanTons = MonthlyComparisons.compute(rows([(100, .nan), (80, 5)]))
        XCTAssertNil(nanTons[0].deflator)
        XCTAssertEqual(nanTons[1].deflator, 100, "the only qualifying month IS the mean")

        let missingTons = MonthlyComparisons.compute(rows([(100, nil), (80, 5)]))
        XCTAssertNil(missingTons[0].deflator)
        XCTAssertEqual(missingTons[1].deflator, 100)

        // A qualifying month with no revenue poisons the mean with NaN, and `NaN > 0` is false,
        // so every deflator falls back to null.
        let missingRevenue = MonthlyComparisons.compute(rows([(nil, 5), (80, 5)]))
        XCTAssertTrue(missingRevenue.allSatisfy { $0.deflator == nil })
        XCTAssertNil(missingRevenue[1].mom, "a missing predecessor revenue is a null base")
    }

    /// An EXACT tie, built from a dyadic base so no floating-point slop can hide it — and the
    /// asymmetry it exposes.
    ///
    /// `(1088 - 1024) / 1024 * 1000` is exactly `62.5`, and the negative case exactly `-62.5`
    /// (both verified `=== ` in node). Ties go toward +∞, so **+6.25% reports 6.3 while −6.25%
    /// reports −6.2**. That asymmetry is the whole reason `jsRound` cannot be `.rounded()`.
    ///
    /// The companion case matters just as much: `pct(102.05, 100)` LOOKS like a tie and is not —
    /// the scaled value is `20.49999999999997`, so it answers `2`, not `2.1`.
    func testM9bAnExactTieRoundsTowardPositiveInfinityAndIsNotSymmetric() {
        XCTAssertEqual(MonthlyComparisons.pct(1088, 1024), 6.3, "+6.25% at an exact tie")
        XCTAssertEqual(MonthlyComparisons.pct(960, 1024), -6.2,
                       "−6.25% at an exact tie — NOT −6.3, which is what away-from-zero gives")
        XCTAssertEqual(MonthlyComparisons.pct(102.05, 100), 2, "looks like a tie, is not one")
    }

    /// The other route to `-0`, and it has nothing to do with small numbers: an UNCHANGED month
    /// whose base is negative.
    ///
    /// `(-100) - (-100)` is `+0`, and `+0 / -100` is `-0`. So a flat month reports `-0` or `+0`
    /// purely by the sign of its base. A test suite that only probes tiny deltas never sees this.
    func testM9cAFlatMonthOnANegativeBaseIsNegativeZero() {
        assertIsNegativeZero(MonthlyComparisons.pct(-100, -100), "pct(-100, -100)")
        XCTAssertEqual(MonthlyComparisons.pct(100, 100), 0)
        XCTAssertFalse(MonthlyComparisons.pct(100, 100)?.sign == .minus, "a positive base gives +0")

        // The exact `-0.5` endpoint of the small-negative window is reachable too:
        // `(1999 - 2000) / 2000 * 1000` is exactly `-0.5`.
        assertIsNegativeZero(MonthlyComparisons.pct(1999, 2000), "pct(1999, 2000)")
    }

    /// `|| 0`, pinned directly, because the comparison that consumes it hides half its work.
    ///
    /// A mutation that dropped the `NaN` arm survived the whole suite: every consumer asks
    /// `> 0`, and `NaN > 0` is false either way. The arm is real behaviour of `|| 0` all the
    /// same, so it is asserted here rather than deleted — the mutation was pointing at a gap in
    /// the tests, not at dead code.
    func testM16TruthyOrZeroFoldsEveryFalsyNumber() {
        XCTAssertEqual(MonthlyComparisons.truthyOrZero(nil), 0, "undefined → 0")
        XCTAssertEqual(MonthlyComparisons.truthyOrZero(0), 0)
        XCTAssertEqual(MonthlyComparisons.truthyOrZero(-0.0), 0)
        XCTAssertEqual(MonthlyComparisons.truthyOrZero(.nan), 0, "NaN is falsy in JS, so `|| 0` gives 0")
        XCTAssertFalse(MonthlyComparisons.truthyOrZero(.nan).isNaN, "the fold must not pass NaN through")
        XCTAssertEqual(MonthlyComparisons.truthyOrZero(5), 5)
        XCTAssertEqual(MonthlyComparisons.truthyOrZero(-5), -5, "negative is truthy in JS")
        XCTAssertEqual(MonthlyComparisons.truthyOrZero(.infinity), .infinity)
    }

    /// The two rounding mirrors in this package must not drift apart.
    ///
    /// `jsRound` is deliberately a second implementation of the rule `ReportMath.round` already
    /// mirrors — see that function's doc comment for why the subsystems keep separate copies.
    /// Separate, however, must not mean divergent, so the two are pinned equal here over every
    /// tie in ±2000, the pathological literals, and a deterministic pseudo-random sample.
    func testM15TheTwoRoundingMirrorsAgree() {
        func agree(_ x: Double) -> Bool {
            let a = MonthlyComparisons.jsRound(x), b = ReportMath.round(x)
            if a.isNaN || b.isNaN { return a.isNaN && b.isNaN }
            return a == b && a.sign == b.sign          // `==` cannot see -0 vs +0
        }
        for x in [0.0, -0.0, 0.5, -0.5, 1.5, -1.5, 2.5, -2.5, 0.4, -0.4,
                  0.49999999999999994, -0.49999999999999994,
                  .infinity, -.infinity, .nan, 4503599627370495.5, -4503599627370495.5] {
            XCTAssertTrue(agree(x), "jsRound and ReportMath.round disagree at \(x)")
        }
        for k in -2000...2000 {
            let base = Double(k)
            XCTAssertTrue(agree(base + 0.5), "disagree at \(base + 0.5)")
            XCTAssertTrue(agree(base - 0.5), "disagree at \(base - 0.5)")
            XCTAssertTrue(agree(base))
        }
        var seed: UInt64 = 12345
        for _ in 0..<20000 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let unit = Double(seed >> 11) * (1.0 / 9007199254740992.0)
            let value = (unit - 0.5) * pow(10, Double((seed >> 3) % 8) - 3)
            XCTAssertTrue(agree(value), "disagree at \(value)")
        }
    }

    // ==============================================================================================
    // MARK: - M13 — this app's own data can never produce a deflator
    // ==============================================================================================

    /// The ruling that keeps the field: mirror it, and let it answer `nil`.
    ///
    /// Every row this app can build has no volume — `transactions` has no quantity column and the
    /// legacy converter copies `tons` into description text rather than a numeric column — so the
    /// price index is `nil` for every month. That is the JS's own answer for the same input, not
    /// a divergence.
    func testM13WithoutVolumeEveryDeflatorIsNull() {
        let twelve = (1...12).map { MonthlyComparisons.Row(revenue: Double($0) * 1000, salesTons: 0) }
        let out = MonthlyComparisons.compute(twelve, priorRevenue: Array(repeating: 500, count: 12))
        XCTAssertEqual(out.count, 12)
        XCTAssertTrue(out.allSatisfy { $0.deflator == nil }, "no volume anywhere → no price index")
        // …while the two comparisons that DO have inputs still answer.
        XCTAssertNil(out[0].mom)
        XCTAssertEqual(out[1].mom, 100)
        XCTAssertEqual(out[0].yoy, 100)
    }

    // ==============================================================================================
    // MARK: - M14 — exactly one file calls this
    // ==============================================================================================

    /// The engine landed with no caller at all (d1-1) and acquired exactly one in d1-3: the
    /// Overview block's composition. Nothing else may reach it — not the view, not the app
    /// model, not a report engine.
    ///
    /// Keeping it at one is the point. The model assembles the block's input and hands over
    /// plain numbers; the arithmetic happens in one place, so there is one file to read when a
    /// percentage looks wrong.
    ///
    /// Asserted by scanning the tree rather than trusted, in the shape `InventoryMountingTests`
    /// and `ProductMountingTests` use for their own pages. Unlike MC4's scanner this one SKIPS
    /// comment lines — the two halves of this chapter differ on that, deliberately: a key named
    /// in a comment has been chosen, while a type named in a comment has only been discussed.
    ///
    /// Sorted before comparing, because `FileManager`'s enumerator has no defined order and a
    /// multi-element expectation would otherwise pass or fail by luck.
    func testM14TheCompositionIsTheOnlyCaller() throws {
        let root = Self.packageRoot().appendingPathComponent("Sources")
        let walker = try XCTUnwrap(FileManager.default.enumerator(atPath: root.path))
        var scanned = 0
        var callers: [String] = []
        for case let relative as String in walker where relative.hasSuffix(".swift") {
            if relative.hasSuffix("Metrics/MonthlyComparisons.swift") { continue }
            guard let text = try? String(contentsOf: root.appendingPathComponent(relative),
                                         encoding: .utf8) else { continue }
            scanned += 1
            let named = text.split(separator: "\n", omittingEmptySubsequences: false).contains {
                let trimmed = $0.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//") && !trimmed.hasPrefix("*")
                    && !trimmed.hasPrefix("/*") && trimmed.contains("MonthlyComparisons")
            }
            if named { callers.append(relative) }
        }
        XCTAssertGreaterThan(scanned, 40, "the scan is not reading the tree")
        XCTAssertEqual(callers.sorted(), ["SoloLedger/App/OverviewPageComposition.swift"], """
            the metrics engine must be reached from the Overview block's composition and \
            nowhere else.
            """)

        // And the scanner can see a real use, or the empty list above proves nothing.
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent(
            "SoloLedgerCore/Metrics/MonthlyComparisons.swift"), encoding: .utf8)
            .contains("public enum MonthlyComparisons"))
    }

    /// …/native/SoloLedger/Tests/SoloLedgerCoreTests/<this>.swift → …/native/SoloLedger
    private static func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
}
