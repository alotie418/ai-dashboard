import Foundation

/// 美国报表引擎 — **batch-2 fields only**. Mirror of `electron/reports/us.js`.
///
/// The US is the odd one out twice over, and R3 touches both oddities:
///
/// * **No `taxInclusiveSummary`.** Not an empty block — the key does not exist in
///   `us.js`'s output at all, which is why the golden field count for that block
///   is 3 × 45 rather than 3 × 54.
/// * **`monthlyBreakdown` sums the TAX-INCLUSIVE `amount`** (`us.js:135-136`),
///   where the five VAT engines sum `amount_net || amount || 0`. Schedule C works
///   in gross receipts throughout, so this is consistent with its own model — and
///   it means the same ledger produces different monthly figures under the US
///   regime than under any other. Mirrored, not reconciled.
///
/// Everything else in `us.js` — Schedule C, self-employment tax, estimated tax and
/// the warnings derived from them — is batch 3 / batch 5 and is deliberately not
/// here. That is also why this type has no P&L block: the US engine has none.
public enum USReportEngine {

    /// `us.js:130-140` — the monthly breakdown.
    ///
    /// Twelve entries keyed on `ctx.year` regardless of the reporting period
    /// (Appendix A9), the optional-chained date spelling, and `r()` — which for
    /// the US is the guarded rounder (`us.js:142`, `Math.round((v || 0) * 100) / 100`).
    public static func monthlyBreakdown(_ ctx: ReportContext) -> [ReportMonth] {
        let r = ReportMath.round2OrZero
        return ReportMonth.prefixes(year: ctx.year).enumerated().map { index, prefix in
            // us.js:135-136 — `r.amount`, the TAX-INCLUSIVE column. The other five
            // engines use `amount_net || amount || 0` here.
            var income = 0.0
            for row in ctx.incomeRows where MonthMatch.optionalChained(row.date, prefix) {
                income += ReportMath.orZero(row.amount)
            }
            var expense = 0.0
            for row in ctx.expenseRows where MonthMatch.optionalChained(row.date, prefix) {
                expense += ReportMath.orZero(row.amount)
            }
            return ReportMonth(month: index + 1, revenue: r(income), cost: r(expense),
                               profit: r(income - expense))   // us.js:137
        }
    }
}

// MARK: - Batch 3 — Schedule C

public extension USReportEngine {

    /// `us.js:14-65` and `:85-89` — the Schedule C mapping.
    ///
    /// Reads NO tax rate. `incomeTaxRate` never touches these fields, which is why
    /// this batch could land before the estimate layer; the parity test proves it
    /// by asserting the block is identical across the base/unset/zero/malformed
    /// rate variants.
    static func scheduleC(_ ctx: ReportContext) -> ScheduleC {
        let r = ReportMath.round2OrZero                     // us.js:142 — guarded
        let meals = USTaxParams.resolve(year: ctx.year)     // us.js:12

        // --- Part I (us.js:15-24) ---------------------------------------------
        // Line 1 sums EVERY income row…
        var grossReceipts = 0.0
        for row in ctx.incomeRows { grossReceipts += ReportMath.orZero(row.amount) }
        // …and lines 2 and 6 sum subsets of those same rows again. The `returns`
        // subset is subtracted back out at line 7, but `other-income` is ADDED —
        // so an other-income row is counted twice. Defect 1; mirrored.
        var returns = 0.0, otherIncome = 0.0
        for row in ctx.incomeRows {
            guard let categoryID = row.categoryID, !categoryID.isEmpty,   // us.js:119
                  let category = ctx.categories.first(where: { $0.id == categoryID })
            else { continue }
            if category.slugEquals("returns") { returns += ReportMath.orZero(row.amount) }
            if category.slugEquals("other-income") { otherIncome += ReportMath.orZero(row.amount) }
        }
        let grossIncome = grossReceipts - returns + otherIncome            // us.js:24

        // --- Part II (us.js:27-31) --------------------------------------------
        // Every expense row lands in exactly one bucket keyed by its slug. A slug
        // no line reads means the money is in NO line — and therefore not in line
        // 28 either. Pinned by a test rather than left to be discovered.
        var bySlug: [String: Double] = [:]
        for row in ctx.expenseRows {
            let key: String
            if let categoryID = row.categoryID, !categoryID.isEmpty,
               let category = ctx.categories.first(where: { $0.id == categoryID }) {
                key = category.slugKeyOrOther
            } else {
                key = "other"                                              // us.js:125
            }
            bySlug[key, default: 0] += ReportMath.orZero(row.amount)
        }
        func line(_ slug: String) -> Double { r(bySlug[slug]) }

        let rawMeals = bySlug["meals"] ?? 0
        // us.js:54 — the `|| 0` is INSIDE, before the multiply, so an absent meals
        // bucket multiplies 0 rather than flooring the product afterwards.
        let line24b = r(ReportMath.orZero(bySlug["meals"]) * meals.params.mealsDeductiblePct)

        let line8 = line("advertising"), line9 = line("car-truck")
        let line10 = line("commissions"), line11 = line("contract-labor")
        let line13 = line("depreciation"), line15 = line("insurance")
        let line16b = line("interest"), line17 = line("legal-pro")
        let line18 = line("office"), line20 = line("rent")
        let line21 = line("repairs"), line22 = line("supplies")
        let line23 = line("taxes"), line24a = line("travel")
        let line25 = line("utilities"), line26 = line("wages")
        let line27a = line("other"), line30 = line("home-office")

        // us.js:61-63 — a SUM OF ALREADY-ROUNDED values, then rounded again at
        // us.js:87. Not a rounding of the raw sum: ten 0.005 rows each round to
        // 0.01 and total 0.10, where the raw sum would be 0.05.
        //
        // Written as an explicit ordered list rather than by filtering the output
        // struct's fields, because the source filters the object literal — which
        // at that point does NOT yet contain line28 or line31. A filter over the
        // finished 25-field shape would add those two to themselves.
        //
        // NOTE line30 is in this list. That is defect 2, mirrored: the real Line 28
        // covers lines 8-27a, and home-office is Form 8829.
        let totalExpenses = [line8, line9, line10, line11, line13, line15, line16b,
                             line17, line18, line20, line21, line22, line23, line24a,
                             line24b, line25, line26, line27a, line30]
            .reduce(0, +)
        let netProfit = grossIncome - totalExpenses                        // us.js:65

        return ScheduleC(
            line1_grossReceipts: r(grossReceipts), line2_returns: r(returns),
            line6_otherIncome: r(otherIncome), line7_grossIncome: r(grossIncome),
            line8_advertising: line8, line9_car: line9, line10_commissions: line10,
            line11_contract: line11, line13_depreciation: line13, line15_insurance: line15,
            line16b_interest: line16b, line17_legal: line17, line18_office: line18,
            line20_rent: line20, line21_repairs: line21, line22_supplies: line22,
            line23_taxes: line23, line24a_travel: line24a, line24b_meals: line24b,
            line25_utilities: line25, line26_wages: line26, line27a_other: line27a,
            line30_homeOffice: line30,
            line28_totalExpenses: r(totalExpenses), line31_netProfit: r(netProfit),
            unroundedGrossIncome: grossIncome, unroundedTotalExpenses: totalExpenses,
            rawMealsTotal: rawMeals)
    }
}
