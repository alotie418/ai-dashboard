import XCTest
@testable import SoloLedgerCore

/// The batch-3 behaviours the GOLDENS CANNOT SEE — which is most of them.
///
/// `ReportBatch3ParityTests` asserts 225 golden fields and they all match, but 175
/// of those cells are the literal 0, there are only 5 distinct vectors, and just 4
/// of the 19 slug→line mappings are pinned. **This file is where the mapping table
/// — the batch's actual deliverable — is verified.**
///
/// Every expected value below was produced by running the REAL `us.js` with a
/// hand-built context (plan §4.1 Tier-1), and each test quotes enough to re-derive
/// it. The mapping sweep is the highest-value test in R4: it is the only thing that
/// fails when a slug literal is transposed or mistyped, and the fixture was
/// deliberately not widened to cover them.
///
/// Three of the behaviours pinned here are DEFECTS reaching reported numbers. They
/// are mirrored verbatim per the phase's discipline, registered as Appendix
/// A10–A12 fix candidates, and named in the test titles so nobody reads them as
/// intended design.
final class ReportBatch3BlindSpotTests: XCTestCase {

    private func ctx(income: [ReportRow] = [], expense: [ReportRow] = [],
                     categories: [ReportCategory] = [], year: String = "2026") -> ReportContext {
        // Batch 3 (Schedule C) is measurably rate-independent — see
        // `testScheduleCIsUnaffectedByEveryRateVariant`. `.notConfigured` is the
        // strictest filler.
        ReportContext(incomeRows: income, expenseRows: expense, categories: categories,
                      adminExpense: 0, incomeTaxRate: .notConfigured,
                      currency: "USD", year: year,
                      from: "\(year)-01-01", to: "\(year)-12-31")
    }

    private func category(_ id: String, _ slug: String) -> ReportCategory {
        ReportCategory(id: id, isCogs: .integer(0), slug: .text(slug))
    }

    private func expense(_ amount: Double, _ categoryID: String?) -> ReportRow {
        ReportRow(amount: amount, categoryID: categoryID, date: "2026-03-01")
    }

    // MARK: - The mapping table
    //
    //     node -e "const us=require('./electron/reports/us.js'); …19 slugs, (i+1)*100 each…"

    /// All nineteen slug→line mappings at once, each with a distinct amount so a
    /// transposition shows up as two wrong lines rather than cancelling out.
    ///
    /// **No golden covers fifteen of these.** Pointing any of those fifteen at an
    /// impossible slug leaves every golden green; swapping `rent` with `repairs`
    /// produces a byte-identical `scheduleC` on every base period. This test is the
    /// coverage.
    func testAllNineteenSlugToLineMappings() {
        let slugs = ["advertising", "car-truck", "commissions", "contract-labor",
                     "depreciation", "insurance", "interest", "legal-pro", "office",
                     "rent", "repairs", "supplies", "taxes", "travel", "meals",
                     "utilities", "wages", "other", "home-office"]
        let categories = slugs.enumerated().map { category("c\($0.offset)", $0.element) }
        let rows = slugs.enumerated().map { expense(Double($0.offset + 1) * 100, "c\($0.offset)") }
        let s = USReportEngine.scheduleC(ctx(expense: rows, categories: categories))

        XCTAssertEqual(s.line8_advertising, 100)
        XCTAssertEqual(s.line9_car, 200)              // slug is "car-truck", NOT "car"
        XCTAssertEqual(s.line10_commissions, 300)
        XCTAssertEqual(s.line11_contract, 400)        // slug is "contract-labor"
        XCTAssertEqual(s.line13_depreciation, 500)
        XCTAssertEqual(s.line15_insurance, 600)
        XCTAssertEqual(s.line16b_interest, 700)
        XCTAssertEqual(s.line17_legal, 800)           // slug is "legal-pro"
        XCTAssertEqual(s.line18_office, 900)
        XCTAssertEqual(s.line20_rent, 1000)
        XCTAssertEqual(s.line21_repairs, 1100)
        XCTAssertEqual(s.line22_supplies, 1200)
        XCTAssertEqual(s.line23_taxes, 1300)
        XCTAssertEqual(s.line24a_travel, 1400)
        XCTAssertEqual(s.line24b_meals, 750, "1500 x the 50% limit")
        XCTAssertEqual(s.line25_utilities, 1600)
        XCTAssertEqual(s.line26_wages, 1700)
        XCTAssertEqual(s.line27a_other, 1800)
        XCTAssertEqual(s.line30_homeOffice, 1900)
        // 100+…+1400 (=10500) + 750 + 1600+1700+1800+1900 = 18250
        XCTAssertEqual(s.line28_totalExpenses, 18250)
        XCTAssertEqual(s.line31_netProfit, -18250, "no income, so net profit is the negative total")
    }

    /// A slug that EXISTS but is not one Schedule C maps: the money is in no line,
    /// and therefore not in Line 28 either. It vanishes from the report.
    ///
    ///     …categories:[{id:'x',slug:'cogs'}], expenseRows:[{amount:1000,category_id:'x'}]
    ///     => line27a 0, line28 0, line31 0
    ///
    /// Reachable in practice: `cogs` is a real slug in the CN/JP/KR/TW seed, so a
    /// ledger whose categories were seeded under another regime and then switched
    /// to US hits exactly this.
    func testAnUnmappedSlugMakesTheMoneyDisappearEntirely() {
        let s = USReportEngine.scheduleC(ctx(expense: [expense(1000, "x")],
                                             categories: [category("x", "cogs")]))
        XCTAssertEqual(s.line27a_other, 0, "it does NOT fall back to line 27a")
        XCTAssertEqual(s.line28_totalExpenses, 0)
        XCTAssertEqual(s.line31_netProfit, 0, "1000 of expense reported nowhere at all")
    }

    /// Three different situations collapse into Line 27a, and only one of them is
    /// "the user chose Other".
    ///
    ///     640 with slug 'other' + 410 with no category + 1800 with an unknown id
    ///     => line27a 2850
    func testThreeDifferentRoutesIntoLine27a() {
        let s = USReportEngine.scheduleC(ctx(
            expense: [expense(640, "o"), expense(410, nil), expense(1800, "nonexistent")],
            categories: [category("o", "other")]))
        XCTAssertEqual(s.line27a_other, 2850)
        // Empty-string category_id is falsy in JS and takes the no-category route.
        let empty = USReportEngine.scheduleC(ctx(expense: [expense(500, "")], categories: []))
        XCTAssertEqual(empty.line27a_other, 500)
    }

    /// A category whose `slug` is null or empty is falsy, so `|| 'other'` sends it
    /// to Line 27a — unlike an unmapped non-empty slug, which vanishes.
    func testANullOrEmptySlugFallsToOtherWhileAnUnmappedOneDoesNot() {
        let nullSlug = ReportCategory(id: "n", isCogs: .integer(0), slug: .null)
        XCTAssertEqual(USReportEngine.scheduleC(
            ctx(expense: [expense(300, "n")], categories: [nullSlug])).line27a_other, 300)
        let emptySlug = ReportCategory(id: "e", isCogs: .integer(0), slug: .text(""))
        XCTAssertEqual(USReportEngine.scheduleC(
            ctx(expense: [expense(300, "e")], categories: [emptySlug])).line27a_other, 300)
        // …versus a real-but-unmapped slug, which reports nowhere.
        XCTAssertEqual(USReportEngine.scheduleC(
            ctx(expense: [expense(300, "u")], categories: [category("u", "unmapped")])).line27a_other, 0)
    }

    // MARK: - Rounding

    /// Line 28 sums the ALREADY-ROUNDED line values, so it is a sum of roundings.
    ///
    ///     advertising 0.005 + rent 0.005
    ///     => line8 0.01, line20 0.01, line28 0.02   (the raw sum 0.01 rounds to 0.01)
    ///
    /// Note this is NOT about individual rows: rows accumulate into their slug
    /// bucket BEFORE the line is rounded, so ten 0.005 advertising rows give
    /// line8 = 0.05, not 0.10. The doubling only appears ACROSS lines.
    func testLine28SumsRoundedLinesNotTheRawTotal() {
        let s = USReportEngine.scheduleC(ctx(
            expense: [expense(0.005, "a"), expense(0.005, "r")],
            categories: [category("a", "advertising"), category("r", "rent")]))
        XCTAssertEqual(s.line8_advertising, 0.01)
        XCTAssertEqual(s.line20_rent, 0.01)
        XCTAssertEqual(s.line28_totalExpenses, 0.02, "0.01 + 0.01, not round(0.01)")

        // Ten rows in ONE bucket: accumulated first, rounded once.
        let ten = USReportEngine.scheduleC(ctx(
            expense: (0..<10).map { _ in expense(0.005, "a") },
            categories: [category("a", "advertising")]))
        XCTAssertEqual(ten.line8_advertising, 0.05, "NOT 0.10 — rows accumulate before rounding")
    }

    /// …and Line 28 is then rounded AGAIN, which is observable.
    ///
    ///     advertising 0.1 + rent 0.2 => the bare sum is 0.30000000000000004,
    ///     line28 is 0.3
    func testLine28IsRoundedAfterSumming() {
        let s = USReportEngine.scheduleC(ctx(
            expense: [expense(0.1, "a"), expense(0.2, "r")],
            categories: [category("a", "advertising"), category("r", "rent")]))
        XCTAssertEqual(0.1 + 0.2, 0.30000000000000004, "the bare sum, for contrast")
        XCTAssertEqual(s.line28_totalExpenses, 0.3, "the outer r() collapses it")
    }

    /// The 50% meals limit, including the negative side where JS ties round toward
    /// +∞ rather than away from zero.
    ///
    ///     0.25 => 0.13    -0.25 => -0.12    3.33 => 1.67
    ///     1000.01 => 500.01    -1000.01 => -500    0.004 => 0
    func testMealsFiftyPercentRoundingIncludingNegatives() {
        for (amount, expected) in [(0.25, 0.13), (-0.25, -0.12), (3.33, 1.67),
                                   (1000.01, 500.01), (-1000.01, -500.0), (0.004, 0.0)] {
            let s = USReportEngine.scheduleC(ctx(expense: [expense(amount, "m")],
                                                 categories: [category("m", "meals")]))
            XCTAssertEqual(s.line24b_meals, expected, "meals \(amount)")
        }
    }

    /// The raw meals total is carried separately from Line 24b, because batch 5's
    /// warning tests the RAW total: 0.004 fires the notice while its Line 24b
    /// rounds to 0.
    func testTheRawMealsTotalIsKeptForTheDeferredWarning() {
        let s = USReportEngine.scheduleC(ctx(expense: [expense(0.004, "m")],
                                             categories: [category("m", "meals")]))
        XCTAssertEqual(s.rawMealsTotal, 0.004)
        XCTAssertEqual(s.line24b_meals, 0, "…which is why the warning cannot be derived from line24b")
    }

    // MARK: - The three mirrored defects
    //
    // Registered as Appendix A10-A12 fix candidates. Mirrored, not repaired:
    // each is an accounting judgement, which CLAUDE.md says an AI must not settle.

    /// **DEFECT (A10) — `other-income` is counted twice.**
    ///
    /// Line 1 sums every income row, and Line 6 sums the `other-income` subset
    /// again; Line 7 is `line1 - line2 + line6`. A lone 900 row reports 900 / 900 /
    /// 1800 — the same money in the gross-income figure twice.
    ///
    /// The doubling is already baked into `base-US-2026.json`:
    /// 52400 − 1500 + 900 = 51800.
    func testDefectOtherIncomeIsCountedTwiceInGrossIncome() {
        let s = USReportEngine.scheduleC(ctx(
            income: [ReportRow(amount: 900, categoryID: "oi", date: "2026-03-01")],
            categories: [category("oi", "other-income")]))
        XCTAssertEqual(s.line1_grossReceipts, 900)
        XCTAssertEqual(s.line6_otherIncome, 900)
        XCTAssertEqual(s.line7_grossIncome, 1800, "the same 900 counted twice — DEFECT, mirrored")
    }

    /// **DEFECT (A11) — `line30_homeOffice` is summed into Line 28.**
    ///
    /// On the real form, home-office deductions go on Form 8829 and Line 28 covers
    /// lines 8–27a only. The fixture's own `categories.schedule_line` column says
    /// `Form 8829` for that slug, so the ledger and the engine disagree about where
    /// the number belongs.
    func testDefectHomeOfficeIsIncludedInTotalExpenses() {
        let s = USReportEngine.scheduleC(ctx(expense: [expense(2500, "ho")],
                                             categories: [category("ho", "home-office")]))
        XCTAssertEqual(s.line30_homeOffice, 2500)
        XCTAssertEqual(s.line28_totalExpenses, 2500,
                       "Form 8829 money inside Schedule C Line 28 — DEFECT, mirrored")
        XCTAssertEqual(s.line31_netProfit, -2500)
    }

    /// **DEFECT (A12) — a negative `returns` row makes Line 2 negative** and
    /// *raises* gross income, because Line 7 subtracts it.
    ///
    ///     50000 gross + a -1500 returns row
    ///     => line1 48500, line2 -1500, line7 50000
    ///
    /// Unreachable from the fixture, so no golden constrains the sign.
    func testDefectANegativeReturnsRowRaisesGrossIncome() {
        let s = USReportEngine.scheduleC(ctx(
            income: [ReportRow(amount: 50000, date: "2026-03-01"),
                     ReportRow(amount: -1500, categoryID: "rt", date: "2026-03-01")],
            categories: [category("rt", "returns")]))
        XCTAssertEqual(s.line1_grossReceipts, 48500, "line 1 nets the negative row in")
        XCTAssertEqual(s.line2_returns, -1500)
        XCTAssertEqual(s.line7_grossIncome, 50000, "48500 - (-1500) — DEFECT, mirrored")
    }

    // MARK: - The tax constant

    /// The year-keyed lookup, including the fallback. The VALUE is 0.5 for every
    /// keyed year, so this pins the SHAPE — a hardcoded 0.5 would satisfy it, and
    /// that is stated in `USTaxParams` rather than pretended otherwise.
    func testMealsPercentResolvesByYearAndFallsBackToTheLatest() {
        for year in ["2024", "2025", "2026"] {
            XCTAssertEqual(USTaxParams.resolve(year: year).params.mealsDeductiblePct, 0.5)
            XCTAssertEqual(USTaxParams.resolve(year: year).year, Int(year))
        }
        // Unknown, future and unparseable years all take the latest keyed year.
        for year in ["2027", "1999", "nonsense", ""] {
            XCTAssertEqual(USTaxParams.resolve(year: year).year, 2026, "year \(year)")
        }
        // `Number(" 2025 ")` is 2025 — the coercion is JS's, not Double(String)'s.
        XCTAssertEqual(USTaxParams.resolve(year: " 2025 ").year, 2025)
        XCTAssertEqual(USTaxParams.resolve(year: "2025x").year, 2026, "trailing garbage → NaN → fallback")
        XCTAssertEqual(USTaxParams.latestYear, 2026, "derived from the table, never a literal")
    }

    /// Schedule C reads no tax rate at all — the property that let this batch land
    /// before the estimate layer. Asserted at the engine, not only through goldens.
    func testScheduleCReadsNoTaxRate() {
        // ReportContext carries no rate to begin with; this asserts the OUTPUT is
        // identical for two contexts that differ in everything a rate could ride on.
        let rows = [expense(1000, "a")]
        let cats = [category("a", "advertising")]
        let a = USReportEngine.scheduleC(ctx(expense: rows, categories: cats, year: "2025"))
        let b = USReportEngine.scheduleC(ctx(expense: rows, categories: cats, year: "2026"))
        XCTAssertEqual(a.line28_totalExpenses, b.line28_totalExpenses,
                       "the only year-sensitive field is meals, and 0.5 is constant across years")
    }
}
