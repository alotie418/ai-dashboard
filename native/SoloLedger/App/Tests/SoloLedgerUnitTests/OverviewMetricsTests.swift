import XCTest
@testable import SoloLedger
import SoloLedgerCore

/// Stage 2b-d1-3 — the Overview month-on-month / year-on-year block, tested through the symbols
/// the app actually calls.
///
/// ## Why this file exists at all
///
/// `MetricsCopyTests` (Core) can only read this block's SOURCE: the composition lives in the App
/// target, which a SwiftPM test target cannot link. That gave the round two structural guards —
/// "one file names these keys", "the dispatch maps US to the US sentence" — and no coverage of
/// what the code DOES. Three behaviours were verified during the round by running a hand-copied
/// duplicate of the formatter in a scratch harness, which proves something about the copy and
/// nothing about the shipped function. `MonthlyComparisons.truthyOrZero` set the precedent for
/// this exact situation: when a behaviour matters, pin the real symbol.
///
/// ## The values under test come from the ENGINE, not from literals
///
/// A negative zero and a `NaN` are the two cell states that a hand-written literal would let a
/// reader dismiss as hypothetical. Both are produced HERE by calling `MonthlyComparisons.pct`
/// with inputs the block really can hand it, and only then fed to the formatter — so if the
/// engine ever stops producing them, these tests say so instead of quietly testing nothing.
@MainActor
final class OverviewMetricsTests: XCTestCase {

    private let languages = ["zh-Hans", "zh-Hant", "en", "ja", "ko", "fr"]

    // ==============================================================================================
    // MARK: - OM1 — a rounded-away minus sign never reaches the screen
    // ==============================================================================================

    /// The engine really does answer `-0.0`, and `-0.0%` reads as a decline that did not happen.
    ///
    /// This is the mirror image of what `overview.metrics.noBaseNote` promises. That sentence says
    /// a MISSING base is left blank rather than shown as `0.0%`; this test says a base that is
    /// present and produced a genuine zero change IS shown as `0.0%` — with no sign in front of it.
    /// The two together are the whole contract of that cell: blank means "nothing to compare",
    /// `0.0%` means "compared, and unchanged".
    func testOM1TheEnginesNegativeZeroPrintsWithoutASign() throws {
        let negativeZero = try XCTUnwrap(MonthlyComparisons.pct(99_999.99, 100_000),
                                         "the engine no longer answers this comparison")
        XCTAssertEqual(negativeZero, 0, "the fixture must produce a zero change")
        XCTAssertEqual(negativeZero.sign, .minus, """
            this test is only meaningful while the engine can still produce a NEGATIVE zero — it \
            mirrors a language whose own formatter hides the sign, so Swift keeps it.
            """)

        for language in languages {
            let text = try XCTUnwrap(OverviewPageComposition.percentText(negativeZero,
                                                                         language: language))
            XCTAssertFalse(text.hasPrefix("-"), "\(language): printed \(text) for a zero change")
            XCTAssertFalse(text.contains("−"), "\(language): printed a minus for a zero change")
        }
    }

    // ==============================================================================================
    // MARK: - OM2 — the engine's third state is a dash, not the word NaN
    // ==============================================================================================

    /// `pct` answers `nil` when the BASE is missing, and a non-nil `NaN` when the CURRENT month is.
    /// Only the first is an absence the formatter would notice on its own; the second is a number,
    /// and a number gets formatted. Both must leave the cell blank.
    func testOM2ANonFiniteComparisonFormatsAsNothing() throws {
        let missingCurrent = MonthlyComparisons.pct(nil, 100)
        XCTAssertNotNil(missingCurrent, "a missing current month is NOT nil — it is NaN")
        XCTAssertTrue(try XCTUnwrap(missingCurrent).isNaN, "the engine no longer answers NaN here")
        XCTAssertNil(MonthlyComparisons.pct(100, nil), "a missing base IS nil")

        for language in languages {
            XCTAssertNil(OverviewPageComposition.percentText(missingCurrent, language: language),
                         "\(language): a NaN comparison must format as nothing")
            XCTAssertNil(OverviewPageComposition.percentText(nil, language: language),
                         "\(language): a missing comparison must format as nothing")
            XCTAssertNil(OverviewPageComposition.percentText(.infinity, language: language),
                         "\(language): an infinite comparison must format as nothing")
        }
    }

    // ==============================================================================================
    // MARK: - OM3 — one decimal, in each locale's own separator
    // ==============================================================================================

    /// The engine quantises to one decimal and the six no-base sentences each name a one-decimal
    /// zero. The report page's percentage helper is fixed at TWO decimals, so this block has its
    /// own — and this is the test that says why it could not just reuse the other one.
    func testOM3PercentagesCarryExactlyOneDecimalInEachLocale() throws {
        let separators = ["zh-Hans": ".", "zh-Hant": ".", "en": ".", "ja": ".", "ko": ".", "fr": ","]
        for language in languages {
            let separator = try XCTUnwrap(separators[language])
            let text = try XCTUnwrap(OverviewPageComposition.percentText(20, language: language))
            XCTAssertEqual(text, "20\(separator)0%", "\(language)")

            let negative = try XCTUnwrap(OverviewPageComposition.percentText(-6.2, language: language))
            XCTAssertEqual(negative, "-6\(separator)2%", "\(language)")

            // Exactly one decimal — never the two the report page's helper would give.
            let fraction = text.drop { $0 != Character(separator) }.dropFirst().dropLast()
            XCTAssertEqual(fraction.count, 1, "\(language): \(text) does not carry one decimal")
        }
    }

    /// Half-way values round away from zero on both sides, the way the shared display rule does.
    func testOM3bHalfWayValuesRoundAwayFromZero() throws {
        XCTAssertEqual(OverviewPageComposition.percentText(6.25, language: "en"), "6.3%")
        XCTAssertEqual(OverviewPageComposition.percentText(-6.25, language: "en"), "-6.3%")
        // …and a value that rounds TO zero from below still loses its sign.
        XCTAssertEqual(OverviewPageComposition.percentText(-0.04, language: "en"), "0.0%")
        XCTAssertEqual(OverviewPageComposition.percentText(-0.05, language: "en"), "-0.1%",
                       "a value that rounds to a non-zero figure keeps its sign")
    }

    // ==============================================================================================
    // MARK: - OM4 — the basis sentence follows the ledger's regime
    // ==============================================================================================

    /// The real dispatch, called. `MetricsCopyTests` MC8 reads the same mapping out of the source
    /// because it cannot link this target; this one runs it.
    func testOM4TheBasisSentenceIsDispatchedByRegime() {
        for regime in AccountingLocale.allCases {
            let expected = regime == .US
                ? "overview.metrics.basisNoteUS" : "overview.metrics.basisNote"
            XCTAssertEqual(OverviewPageComposition.basisNoteKey(for: regime), expected,
                           "\(regime.rawValue) states the wrong basis sentence")
            let page = OverviewPageComposition.compose(input(regime: regime))
            XCTAssertEqual(page.noteKeys.first, expected,
                           "\(regime.rawValue): the composed page states the wrong one")
            XCTAssertEqual(page.noteKeys.last, "overview.metrics.noBaseNote",
                           "\(regime.rawValue): the no-base sentence must always be stated")
        }
    }

    // ==============================================================================================
    // MARK: - OM5 — the empty state, and the shape that does NOT reach it
    // ==============================================================================================

    /// A year of expenses only AND no prior year: revenue is zero every month, so every base is
    /// zero, every comparison is `nil`, and there is genuinely nothing to compare.
    ///
    /// BOTH halves are required, which is the narrow thing this test exists to pin. A prior year
    /// that did have revenue makes every month of a revenue-free year a real −100%, so the block
    /// draws a full table of them — see ``testOM5cAPriorYearRescuesARevenueFreeYear``.
    func testOM5AYearWithNoRevenueAndNoPriorYearShowsTheEmptyState() {
        let page = OverviewPageComposition.compose(
            input(revenue: Array(repeating: 0, count: 12), priorRevenue: []))
        XCTAssertTrue(page.rows.isEmpty, "a year with no revenue must not draw a table")
        XCTAssertEqual(page.emptyKeys, ["overview.metrics.empty.title",
                                        "overview.metrics.empty.message"])
        XCTAssertTrue(page.columnHeaderKeys.isEmpty)
        XCTAssertTrue(page.noteKeys.isEmpty, "there is no basis to declare when nothing is shown")
    }

    /// The other way in: revenue in DECEMBER only. December's own base is a revenue-free
    /// November, and there is no thirteenth month to fall from — so one month of revenue can
    /// still leave nothing to compare, while eleven other placements cannot.
    func testOM5dDecemberOnlyRevenueAlsoHasNothingToCompare() {
        var revenue = [Double?](repeating: 0, count: 12)
        revenue[11] = 5_000
        let page = OverviewPageComposition.compose(input(revenue: revenue, priorRevenue: []))
        XCTAssertTrue(page.rows.isEmpty, "December has no successor to fall from")
        XCTAssertEqual(page.emptyKeys.count, 2)
    }

    /// A prior year with revenue turns a revenue-free year into twelve real −100% rows. Measured,
    /// because it is the case that makes the empty state rarer than it looks.
    func testOM5cAPriorYearRescuesARevenueFreeYear() {
        let page = OverviewPageComposition.compose(
            input(revenue: Array(repeating: 0, count: 12),
                  priorRevenue: Array(repeating: 80, count: 12)))
        XCTAssertFalse(page.rows.isEmpty)
        XCTAssertTrue(page.rows.allSatisfy { $0.yoy == -100 }, "every month fell to zero")
    }

    /// The shape that looks like it should be empty and is not — measured, and the reason the
    /// predicate is written over the COMPARISONS rather than over "how many months have data".
    ///
    /// One month of revenue in an otherwise empty year still produces a comparison: the month
    /// AFTER it falls from that figure to zero, which is a real −100%.
    func testOM5bASingleMonthOfRevenueStillHasSomethingToCompare() throws {
        var revenue = [Double?](repeating: 0, count: 12)
        revenue[6] = 1_500
        let page = OverviewPageComposition.compose(input(revenue: revenue))
        XCTAssertFalse(page.rows.isEmpty, "July→August is a comparison; this is not the empty state")
        XCTAssertTrue(page.emptyKeys.isEmpty)
        XCTAssertEqual(page.rows[7].mom, -100, "August fell to zero from July")
        XCTAssertNil(page.rows[6].mom, "July's base is a zero June, so it has no comparison")
    }

    // ==============================================================================================
    // MARK: - OM6 — the table itself
    // ==============================================================================================

    func testOM6TwelveRowsAndNoComparisonForJanuary() {
        let page = OverviewPageComposition.compose(
            input(revenue: (1...12).map { Double($0) * 100 },
                  priorRevenue: (1...12).map { Double($0) * 80 }))
        XCTAssertEqual(page.rows.count, 12)
        XCTAssertEqual(page.rows.map(\.month), Array(1...12))
        XCTAssertNil(page.rows[0].mom, "January has no predecessor inside the year")
        XCTAssertNotNil(page.rows[0].yoy, "…but it does have the same month last year")
        XCTAssertEqual(page.year, "2025")
    }

    /// A month the report could not classify is an ABSENCE, not a zero — and its own comparison
    /// comes back non-finite, which the composition folds to nothing rather than printing.
    func testOM6bAnUnclassifiedMonthLeavesItsCellsBlank() {
        var revenue = [Double?](repeating: 100, count: 12)
        revenue[3] = nil
        let page = OverviewPageComposition.compose(input(revenue: revenue))
        XCTAssertNil(page.rows[3].revenue, "an unclassified month must not read as a figure")
        XCTAssertNil(page.rows[3].mom, "…and neither must its comparison")
        XCTAssertNil(OverviewPageComposition.revenueText(page.rows[3].revenue, currency: "CNY"))
        XCTAssertNotNil(OverviewPageComposition.revenueText(page.rows[2].revenue, currency: "CNY"))
    }

    /// An empty prior year — the ordinary case for a ledger in its first year — blanks the whole
    /// year-on-year column and touches nothing else.
    func testOM6cAnAbsentPriorYearBlanksOnlyTheYearOnYearColumn() {
        let page = OverviewPageComposition.compose(
            input(revenue: (1...12).map { Double($0) * 100 }, priorRevenue: []))
        XCTAssertTrue(page.rows.allSatisfy { $0.yoy == nil }, "no prior year, no year-on-year")
        XCTAssertTrue(page.rows.dropFirst().allSatisfy { $0.mom != nil },
                      "month-on-month is unaffected by a missing prior year")
    }

    // ==============================================================================================
    // MARK: - OM7 — the placement table is the block's namespace, in both directions
    // ==============================================================================================

    /// The PM1 shape, narrowed to this block's own prefix: the seventeen older `overview.*` keys
    /// have no placement table and are registered debt, so the equality is written against
    /// `overview.metrics.` and the excluded half is pinned by size so the filter cannot widen.
    func testOM7ThePlacementTableIsExactlyTheElevenBlockKeys() throws {
        let placed = Set(OverviewPageComposition.placement.keys)
        XCTAssertEqual(placed.count, 11, "d1-2 landed ten; d1-3 adds the US basis sentence")
        XCTAssertTrue(OverviewPageComposition.sharedKeys.isEmpty,
                      "the month heading is drawn by the chart and is not claimed here")
        XCTAssertTrue(OverviewPageComposition.exemptKeys.isEmpty)

        for language in languages {
            let table = try sourceTable(language)
            let landed = Set(table.keys.filter { $0.hasPrefix("overview.metrics.") })
            XCTAssertEqual(landed, placed, """
                \(language): the copy and the block's placement table disagree.
                written but never drawn: \(landed.subtracting(placed).sorted())
                drawn but never written: \(placed.subtracting(landed).sorted())
                """)
            // The counterweight: an exclusion filter with nothing pinning the excluded half is
            // how a guard rots. Seventeen is the debt, and it must stay seventeen.
            let all = table.keys.filter { $0.hasPrefix("overview.") }
            XCTAssertEqual(all.count - landed.count, 17,
                           "\(language): the unclaimed overview.* keys moved — was 17")
        }
        XCTAssertTrue(placed.contains(OverviewPageComposition.blockTitleKey))
    }

    /// Every key a composed page can emit is one the placement table declares — for both the
    /// populated and the empty shape, so neither branch can invent a key.
    func testOM7bEveryKeyAPageEmitsIsPlaced() {
        let placed = Set(OverviewPageComposition.placement.keys)
        for page in [OverviewPageComposition.compose(input()),
                     OverviewPageComposition.compose(input(revenue: Array(repeating: 0, count: 12)))] {
            var emitted = Set([page.titleKey])
            emitted.formUnion(page.columnHeaderKeys)
            emitted.formUnion(page.captionKeys)
            emitted.formUnion(page.noteKeys)
            emitted.formUnion(page.emptyKeys)
            XCTAssertTrue(emitted.isSubset(of: placed),
                          "unplaced: \(emitted.subtracting(placed).sorted())")
        }
    }

    // MARK: - Helpers

    private func input(regime: AccountingLocale = .CN,
                       revenue: [Double?] = Array(repeating: 100, count: 12),
                       priorRevenue: [Double?] = Array(repeating: 80, count: 12))
    -> OverviewPageComposition.Input {
        OverviewPageComposition.Input(regime: regime, year: "2025", currency: "CNY",
                                      revenue: revenue, priorRevenue: priorRevenue)
    }

    /// One locale's `.strings` read from SOURCE, so a missing key cannot be hidden by the bundle's
    /// fallback chain.
    private func sourceTable(_ language: String) throws -> [String: String] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent(
            "Sources/SoloLedger/Resources/\(language).lproj/Localizable.strings")
        let text = try String(contentsOf: url, encoding: .utf8)
        var out: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\""), trimmed.hasSuffix("\";") else { continue }
            let body = trimmed.dropFirst().dropLast(2)
            guard let split = body.range(of: "\" = \"") else { continue }
            out[String(body[body.startIndex..<split.lowerBound])] = String(body[split.upperBound...])
        }
        return out
    }
}
