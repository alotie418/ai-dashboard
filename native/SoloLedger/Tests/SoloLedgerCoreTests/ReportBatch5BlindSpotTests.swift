import XCTest
@testable import SoloLedgerCore

/// Batch-5 blind spots: everything the estimate layer does that NO golden observes.
///
/// `ReportBatch5ParityTests` compares 170 VAT cells and 120 US cells and its own
/// header explains why that number flatters the coverage. This file is the other
/// half — each test here corresponds to a branch, threshold or ordering rule that a
/// wrong implementation could get wrong while every committed golden stayed green.
///
/// Each one names the mutation it kills, because a blind-spot test whose motivating
/// mistake is not written down tends to be deleted by the next person who tidies.
final class ReportBatch5BlindSpotTests: LedgerTestCase {

    private func ctx(income: [ReportRow] = [], expense: [ReportRow] = [],
                     categories: [ReportCategory] = [],
                     adminExpense: Double = 0,
                     incomeTaxRate: ReportRateSetting = .configured(20),
                     surchargeRate: ReportRateSetting = .configured(10),
                     year: String = "2025") -> ReportContext {
        ReportContext(incomeRows: income, expenseRows: expense, categories: categories,
                      adminExpense: adminExpense, incomeTaxRate: incomeTaxRate,
                      surchargeRate: surchargeRate, currency: "USD", year: year,
                      from: "\(year)-01-01", to: "\(year)-12-31")
    }

    private func income(_ amount: Double, tax: Double = 0) -> ReportRow {
        ReportRow(amount: amount, taxAmount: tax, date: "2025-03-01")
    }
    private func expense(_ amount: Double, tax: Double = 0, slug: String? = nil) -> ReportRow {
        ReportRow(amount: amount, taxAmount: tax, categoryID: slug.map { "c-\($0)" },
                  date: "2025-03-02")
    }
    private func category(_ slug: String) -> ReportCategory {
        ReportCategory(id: "c-\(slug)", isCogs: .integer(0), slug: .text(slug))
    }

    // MARK: - US self-employment tax: the two thresholds no fixture reaches

    /// The social-security wage cap. **Kills:** deleting `Math.min`, or mistyping the
    /// cap by a digit.
    ///
    /// Every golden's `seEarnings` is under 40,000 against a cap of 176,100, so the
    /// `min` never binds there and its removal is invisible. Here the earnings are
    /// pushed past it deliberately.
    func testTheSocialSecurityCapActuallyBinds() {
        // 400,000 gross → line31 400,000 → seEarnings 369,400, well past the 2025 cap.
        let se = USReportEngine.selfEmploymentTax(ctx(income: [income(400_000)]))
        XCTAssertEqual(se.seEarnings, 369_400)
        // Capped at 176,100 × 12.4%, NOT 369,400 × 12.4% (which would be 45,805.60).
        XCTAssertEqual(se.socialSecurityTax, ReportMath.round2(176_100 * 0.124))
        XCTAssertEqual(se.socialSecurityTax, 21_836.4)
        XCTAssertNotEqual(se.socialSecurityTax, ReportMath.round2(369_400 * 0.124),
                          "an uncapped social-security tax is what deleting Math.min gives")
        // Medicare is NOT capped — the same earnings, no ceiling.
        XCTAssertEqual(se.medicareTax, ReportMath.round2(369_400 * 0.029))
    }

    /// The cap is YEAR-KEYED, and `ssWageCap` is the only constant that differs
    /// between the three keyed years. **Kills:** hard-coding one year's table while
    /// still passing `paramYear` through — which every golden would accept.
    func testTheCapDiffersByYearAndTheDifferenceIsObservable() {
        var caps: [Int: Double] = [:]
        for year in ["2024", "2025", "2026"] {
            let se = USReportEngine.selfEmploymentTax(ctx(income: [income(400_000)], year: year))
            caps[se.paramYear] = se.socialSecurityTax
        }
        XCTAssertEqual(caps[2024], ReportMath.round2(168_600 * 0.124))
        XCTAssertEqual(caps[2025], ReportMath.round2(176_100 * 0.124))
        XCTAssertEqual(caps[2026], ReportMath.round2(184_500 * 0.124))
        XCTAssertEqual(Set(caps.values).count, 3,
                       "three keyed years, three different capped taxes")
        // An unknown year takes the LATEST table, not a throw and not year zero.
        let future = USReportEngine.selfEmploymentTax(ctx(income: [income(400_000)], year: "2099"))
        XCTAssertEqual(future.paramYear, 2026)
        XCTAssertEqual(future.socialSecurityTax, caps[2026])
    }

    /// Additional Medicare. **Kills:** `return 0`, a mistyped 200,000 threshold, a
    /// mistyped 0.9% rate, and `>` flipped to `<`.
    ///
    /// `additionalMedicare` is 0 in all ten US goldens, so all four mutations are
    /// free there.
    func testAdditionalMedicareFiresOnlyAboveItsThreshold() {
        // Just under: seEarnings = 199,999.35, no additional Medicare.
        let under = USReportEngine.selfEmploymentTax(ctx(income: [income(216_566)]))
        XCTAssertLessThan(under.seEarnings, 200_000)
        XCTAssertEqual(under.additionalMedicare, 0)
        // Well over.
        let over = USReportEngine.selfEmploymentTax(ctx(income: [income(400_000)]))
        XCTAssertEqual(over.seEarnings, 369_400)
        XCTAssertEqual(over.additionalMedicare, ReportMath.round2((369_400 - 200_000) * 0.009))
        XCTAssertEqual(over.additionalMedicare, 1_524.6)
        XCTAssertGreaterThan(over.additionalMedicare, 0, "the branch must be reachable at all")
        // A loss period must not produce a negative additional Medicare: the
        // comparison is `>` against a positive threshold, so it cannot fire.
        let loss = USReportEngine.selfEmploymentTax(ctx(expense: [expense(9_000)]))
        XCTAssertLessThan(loss.seEarnings, 0)
        XCTAssertEqual(loss.additionalMedicare, 0)
    }

    /// `totalSETax` rounds the SUM once. **Kills:** rounding the three parts and
    /// adding them — measured, the two disagree on 1,641,186 of 4,000,000 one-cent
    /// inputs, and on none of the fixture's.
    func testTotalSETaxRoundsTheSumOnceNotThePartsSeparately() {
        let se = USReportEngine.selfEmploymentTax(ctx(income: [income(1_234.567)]))
        let partsRoundedFirst = ReportMath.round2(se.socialSecurityTax)
            + ReportMath.round2(se.medicareTax) + ReportMath.round2(se.additionalMedicare)
        // The emitted parts are already rounded, so this reconstruction is what a
        // "round each, then add" implementation would produce.
        XCTAssertEqual(se.totalSETax, ReportMath.round2(
            ReportMath.min(se.seEarnings, 176_100) * 0.124 + se.seEarnings * 0.029))
        // Documented rather than asserted equal/unequal: on THIS input they agree,
        // which is precisely why the golden set cannot separate them.
        XCTAssertEqual(se.totalSETax, ReportMath.round2(partsRoundedFirst), accuracy: 0.011)
    }

    /// The four VAT engines multiply the **unrounded** operating profit.
    ///
    /// **Kills:** `r(max(0, r(operatingProfit)) * rate/100)` — reading the rounded
    /// struct field back out instead of using the local (`jp.js:31` multiplies the
    /// local). Every committed golden agrees with both spellings, because the one
    /// period with a non-zero income tax has an integral operating profit.
    ///
    /// The discriminating input was SEARCHED FOR, not guessed: over five million
    /// random (profit, rate) pairs the first divergence is the one below, and it is
    /// a single cent.
    func testTheTaxIsComputedFromTheUnroundedOperatingProfit() {
        // operatingProfit = 1645.9839121471086, rate 99.9%.
        //   unrounded input → 1644.34   (the engine)
        //   rounded input   → 1644.33   (the mutation)
        let c = ctx(income: [ReportRow(amountNet: 1645.9839121471086, amount: 1645.9839121471086,
                                       date: "2025-03-01")],
                    incomeTaxRate: .configured(99.9))
        for (name, value) in [("JP", JPReportEngine.batchOne(c).incomeTax),
                              ("KR", KRReportEngine.batchOne(c).incomeTax),
                              ("TW", TWReportEngine.batchOne(c).incomeTax),
                              ("EU", EUReportEngine.batchOne(c).incomeTax)] {
            XCTAssertEqual(value, .computed(1644.34),
                           "\(name): the tax rides on the UNROUNDED operating profit")
            XCTAssertNotEqual(value, .computed(1644.33),
                              "\(name): 1644.33 is what rounding the input first produces")
        }
    }

    // MARK: - China: two gates, and their order

    /// **Kills:** collapsing China's two gates into one.
    ///
    /// The reachable state no golden covers: the surcharge row is usable and the
    /// income-tax row is corrupt. The `malformed` variants break BOTH rows, so the
    /// asymmetry never appears there.
    func testChinaRefusesTheIncomeTaxChainWhileTheSurchargeChainStillComputes() {
        let s = CNReportEngine.batchOne(ctx(
            income: [income(1_130, tax: 130)], expense: [expense(226, tax: 26)],
            incomeTaxRate: .needsRepair(rawValue: "\"25%\""),
            surchargeRate: .configured(12)))

        // The surcharge chain survives: 104 payable × 12% = 12.48.
        XCTAssertEqual(s.taxSurcharge, .computed(12.48))
        guard case .computed = s.operatingProfit else {
            return XCTFail("pre-tax profit rides on the surcharge alone and must compute")
        }
        // …and everything gated on the income-tax rate refuses, naming THAT row.
        XCTAssertEqual(s.incomeTax, .needsRepair(parameter: .incomeTaxRate, rawValue: "\"25%\""))
        XCTAssertEqual(s.netProfit, .needsRepair(parameter: .incomeTaxRate, rawValue: "\"25%\""))
        XCTAssertEqual(s.netMargin, .needsRepair(parameter: .incomeTaxRate, rawValue: "\"25%\""))
    }

    /// **Kills:** naming the wrong blocker when BOTH rows are unusable.
    ///
    /// `cn.js:53` is `cannotPrice = surchargeMissing || rateMissing` and `||`
    /// short-circuits, so the surcharge is the blocker. The two rows carry different
    /// bytes here on purpose — an implementation that asks the income-tax rate first
    /// produces a refusal that names the wrong field, and R8 would send the user to
    /// repair the wrong row.
    func testWhenBothRowsAreUnusableTheSurchargeIsNamedFirst() {
        let s = CNReportEngine.batchOne(ctx(
            income: [income(1_130, tax: 130)],
            incomeTaxRate: .needsRepair(rawValue: "\"25%\""),
            surchargeRate: .needsRepair(rawValue: "\"12%\"")))
        XCTAssertEqual(s.incomeTax, .needsRepair(parameter: .surchargeRate, rawValue: "\"12%\""),
                       "|| short-circuits: the SURCHARGE is the blocker, not the income-tax rate")
        XCTAssertEqual(s.netProfit, .needsRepair(parameter: .surchargeRate, rawValue: "\"12%\""))
        XCTAssertEqual(s.taxSurcharge, .needsRepair(parameter: .surchargeRate, rawValue: "\"12%\""))
    }

    /// China's surcharge multiplies the RAW clamped VAT payable.
    ///
    /// **Kills:** rounding the payable first — i.e. reaching for the `estimatedPayable`
    /// the batch-4 block emits (`cn.js:74` rounds it) instead of recomputing the raw
    /// difference `cn.js:33` uses. Every golden agrees with both, because the
    /// fixture's payables are already 2-decimal.
    ///
    /// The input was SEARCHED FOR: over eight million random (payable, rate) pairs
    /// the first divergence is the one below, and it is a single cent.
    func testTheSurchargeMultipliesTheRawClampedPayable() {
        // payable 10702.926 at 7% → engine 749.2, rounding-first 749.21.
        let c = ctx(income: [income(0, tax: 10_702.926)], surchargeRate: .configured(7))
        XCTAssertEqual(CNReportEngine.batchOne(c).taxSurcharge, .computed(749.2))
        XCTAssertNotEqual(CNReportEngine.batchOne(c).taxSurcharge, .computed(749.21),
                          "749.21 is what rounding the payable before the multiply gives")
    }

    /// China's net margin scales by 10000 ONCE; JP/EU/KR/TW scale by 100 twice.
    ///
    /// **Kills:** reusing the JP spelling for China. Algebraically identical, and
    /// measurably different in binary64 — the input below was searched for, and the
    /// two spellings differ by a hundredth of a percentage point.
    func testChinaScalesTheMarginByTenThousandOnce() {
        // The input was searched for through the ENGINE's own float chain (a revenue
        // and an expense, subtracted as the engine subtracts them), not through a
        // ratio written by hand — a hand-written ratio is not necessarily a value the
        // engine can produce. Revenue 56,040 less expenses 96,739.05:
        //   China's ×10000-once   → -72.63
        //   Japan's ×100-twice    → -72.62
        let net = 56_040.0 - 96_739.05
        XCTAssertEqual(ReportMath.percent2(net / 56_040), -72.63)
        XCTAssertEqual(ReportMath.round2OrZero(net / 56_040 * 100), -72.62)
        XCTAssertNotEqual(ReportMath.percent2(net / 56_040),
                          ReportMath.round2OrZero(net / 56_040 * 100),
                          "the two spellings are not interchangeable")

        // …and the engine uses China's. A 0% rate makes net profit equal pre-tax
        // profit, so the ratio above is exactly the margin.
        let c = ctx(income: [ReportRow(amountNet: 56_040, amount: 56_040, date: "2025-03-01")],
                    expense: [ReportRow(amountNet: 96_739.05, amount: 96_739.05,
                                        date: "2025-03-02")],
                    incomeTaxRate: .configured(0), surchargeRate: .configured(0))
        XCTAssertEqual(CNReportEngine.batchOne(c).netMargin, .computed(-72.63),
                       "China's own scaling, not Japan's")
    }

    // MARK: - The five VAT regimes

    /// **Kills:** removing `Math.max(0, …)` from the four non-Chinese engines, which
    /// the US deliberately does NOT have.
    func testTheFourVATRegimesClampALossPeriodToZeroTaxButTheUSDoesNot() {
        let losing = ctx(expense: [expense(9_000)], incomeTaxRate: .configured(20))
        for (name, value) in [("JP", JPReportEngine.batchOne(losing).incomeTax),
                              ("KR", KRReportEngine.batchOne(losing).incomeTax),
                              ("TW", TWReportEngine.batchOne(losing).incomeTax),
                              ("EU", EUReportEngine.batchOne(losing).incomeTax)] {
            XCTAssertEqual(value, .computed(0), "\(name): clamped at 0, so a loss pays no tax")
        }
        // The US has no clamp — the same loss estimates a NEGATIVE income tax.
        guard case .computed(let us) = USReportEngine.estimatedTax(losing).annualIncomeTax else {
            return XCTFail("US must compute")
        }
        XCTAssertEqual(us, -1_800)
    }

    /// `netMargin`'s zero-revenue branch. **Kills:** writing it as `nil`, `NaN`, or a
    /// refusal — no golden has a period with zero revenue.
    func testNetMarginFallsBackToIntegerZeroWhenThereIsNoRevenue() {
        let empty = ctx(incomeTaxRate: .configured(20), surchargeRate: .configured(10))
        XCTAssertEqual(JPReportEngine.batchOne(empty).netMargin, .computed(0))
        XCTAssertEqual(EUReportEngine.batchOne(empty).netMargin, .computed(0))
        XCTAssertEqual(CNReportEngine.batchOne(empty).netMargin, .computed(0))
    }

    // MARK: - The two refusals stay distinguishable

    /// **Kills:** funnelling both refusals through `ReportRateSetting.rate` and a
    /// single `.notConfigured`.
    ///
    /// No golden can catch this: both states are `null` in the JSON. It is asserted
    /// here, on the produced value, and nowhere else.
    func testNotConfiguredAndNeedsRepairSurviveIntoTheProducedValue() {
        let absent = ctx(income: [income(1_000)], incomeTaxRate: .notConfigured)
        let corrupt = ctx(income: [income(1_000)], incomeTaxRate: .needsRepair(rawValue: "null"))

        XCTAssertEqual(JPReportEngine.batchOne(absent).incomeTax,
                       .notConfigured(parameter: .incomeTaxRate))
        XCTAssertEqual(JPReportEngine.batchOne(corrupt).incomeTax,
                       .needsRepair(parameter: .incomeTaxRate, rawValue: "null"))
        XCTAssertNotEqual(JPReportEngine.batchOne(absent).incomeTax,
                          JPReportEngine.batchOne(corrupt).incomeTax,
                          "R8 shows a different door for each; merging them loses that")

        // …through the US block too, and with the stored bytes intact.
        XCTAssertEqual(USReportEngine.estimatedTax(corrupt).annualIncomeTax,
                       .needsRepair(parameter: .incomeTaxRate, rawValue: "null"))
        XCTAssertEqual(USReportEngine.estimatedTax(absent).totalAnnual,
                       .notConfigured(parameter: .incomeTaxRate))
    }

    /// The refusal is a SNAPSHOT: it carries its reason, so nothing downstream needs
    /// to re-read `settings` and re-classify. **Kills:** dropping the payload and
    /// having R8 look the reason up again — which would report whatever the ledger
    /// says at render time, not what produced the number.
    func testTheRefusalCarriesEnoughToExplainItselfWithoutTheDatabase() {
        let s = CNReportEngine.batchOne(ctx(
            incomeTaxRate: .needsRepair(rawValue: "\"25%\""),
            surchargeRate: .configured(12)))
        guard case .needsRepair(let parameter, let raw) = s.incomeTax else {
            return XCTFail("expected a needs-repair refusal")
        }
        XCTAssertEqual(parameter, .incomeTaxRate)
        XCTAssertEqual(raw, "\"25%\"", "the stored text travels with the refusal")
    }

    // MARK: - The US warnings array

    /// **Kills:** shipping the two warnings independently — the plan's whole reason
    /// for putting the array in this batch.
    ///
    /// The array is a `.filter(Boolean)` literal, so when net profit is ≤ 0 the first
    /// entry disappears and the meals hint SLIDES to index 0. No golden reaches that
    /// state: the only golden with meals (`base-US-2026`) has a +42,750 profit.
    func testTheMealsHintSlidesToIndexZeroWhenThereIsNoQuarterlyPayment() {
        let cats = [category("meals")]
        // Profitable: both entries, quarterly payment first.
        let profitable = USReportEngine.warnings(ctx(
            income: [income(50_000)], expense: [expense(100, slug: "meals")], categories: cats))
        XCTAssertEqual(profitable.count, 2)
        XCTAssertTrue(profitable[0].hasPrefix("Estimated quarterly tax payment: $"))
        XCTAssertTrue(profitable[1].contains("Meals"))

        // Loss: the first entry is gone and the meals hint is now index 0.
        let losing = USReportEngine.warnings(ctx(
            income: [income(10)], expense: [expense(9_000), expense(100, slug: "meals")],
            categories: cats))
        XCTAssertEqual(losing.count, 1)
        XCTAssertTrue(losing[0].contains("Meals"), "it slid from index 1 to index 0")
    }

    /// **Kills:** testing `line24b_meals` instead of `rawMealsTotal`.
    ///
    /// A 0.004 meals total is truthy in JS and fires the hint, while Line 24b rounds
    /// it to 0. Batch 3 carried `rawMealsTotal` precisely so this batch could ask the
    /// right question.
    func testTheMealsHintTestsTheRawTotalNotTheRoundedLine() {
        let c = ctx(income: [income(50_000)], expense: [expense(0.004, slug: "meals")],
                    categories: [category("meals")])
        XCTAssertEqual(USReportEngine.scheduleC(c).line24b_meals, 0, "Line 24b rounds it away")
        XCTAssertTrue(USReportEngine.warnings(c).contains { $0.contains("Meals") },
                      "…but the raw total is truthy, so the hint still fires")
    }

    /// **Kills:** emitting a quarterly-payment warning built from a refusal.
    func testNoQuarterlyWarningWhenTheRateIsUnusable() {
        for setting: ReportRateSetting in [.notConfigured, .needsRepair(rawValue: "\"25%\"")] {
            let w = USReportEngine.warnings(ctx(income: [income(50_000)], incomeTaxRate: setting))
            XCTAssertTrue(w.isEmpty, "\(setting): nothing to announce, and no \"$null\"")
            XCTAssertFalse(w.joined().contains("null"))
        }
    }

    /// **Kills:** formatting the warning with a device-locale `NumberFormatter`.
    ///
    /// The shim is pinned vector-by-vector in `ReportToLocaleStringTests`; this checks
    /// that the ENGINE actually routes through it, which that suite cannot see.
    func testTheWarningUsesTheGroupedEnUSFormatting() {
        let w = USReportEngine.warnings(ctx(income: [income(200_000)]))
        XCTAssertEqual(w.count, 1)
        XCTAssertTrue(w[0].contains(","), "a five-figure payment must carry a grouping separator")
        // fr-FR groups with U+202F (narrow no-break space) and de-DE with ".", so a
        // device-locale NumberFormatter shows up as one of these rather than as ",".
        XCTAssertFalse(w[0].unicodeScalars.contains("\u{202F}"), "U+202F means a French locale")
        XCTAssertFalse(w[0].unicodeScalars.contains("\u{00A0}"), "U+00A0 likewise")
        XCTAssertTrue(w[0].hasSuffix("$16,798.18"),
                      "the exact string, so a plausible-but-different format cannot pass: \(w[0])")
    }
}
