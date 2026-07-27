import Foundation

/// 台灣報表引擎 —— batch-1 fields only. Mirror of `electron/reports/tw.js`.
///
/// Batch-1 arithmetic matches Japan and Korea exactly today. Kept as its own file
/// on purpose — see the note in ``JPReportEngine``.
public enum TWReportEngine {

    /// `tw.js` batch-1 lines: 14 (rounder), 16-26 (sums, operating profit),
    /// 33-37 (emitted block).
    public static func batchOne(_ ctx: ReportContext) -> BatchOneIncomeStatementWithOperatingProfit {
        let split = ExpenseSplit.splitExpenses(ctx.expenseRows, ctx.categories)

        let r = ReportMath.round2OrZero                       // tw.js:14 — has `|| 0`

        // tw.js:17
        var totalIncomeNet = 0.0
        for row in ctx.incomeRows { totalIncomeNet += ReportMath.netAmount(row.amountNet, row.amount) }

        let revenue = totalIncomeNet                          // tw.js:23
        let cogs = split.cogsNet                              // tw.js:24 — COGS only
        let grossProfit = revenue - cogs                      // tw.js:25
        let operatingProfit = grossProfit - split.operatingExpensesNet - ctx.adminExpense // tw.js:26

        return BatchOneIncomeStatementWithOperatingProfit(
            salesRevenue: r(revenue),                         // tw.js:34
            costOfSales: r(cogs),                             // tw.js:34
            costOfGoodsSold: r(split.cogsNet),                // tw.js:35
            operatingExpenses: r(split.operatingExpensesNet), // tw.js:35
            grossProfit: r(grossProfit),                      // tw.js:36
            // tw.js:36 — inline, scaled by 100 twice (not 10000 once, as CN does).
            grossMargin: revenue > 0 ? r(grossProfit / revenue * 100) : 0,
            adminExpense: r(ctx.adminExpense),                // tw.js:37
            operatingProfit: r(operatingProfit)               // tw.js:37
        )
    }
}

// MARK: - Batch 2

public extension TWReportEngine {

    /// `tw.js:44-46` — the tax-inclusive summary.
    ///
    /// TAX-INCLUSIVE sums, not the net ones the P&L uses. This engine's rounder
    /// HAS the `|| 0` guard (`tw.js:14`), unlike China's — so a NaN becomes 0 here
    /// and `null` there.
    static func taxInclusiveSummary(_ ctx: ReportContext) -> TaxInclusiveSummary {
        let r = ReportMath.round2OrZero
        var totalIncome = 0.0
        for row in ctx.incomeRows { totalIncome += ReportMath.orZero(row.amount) }
        var totalExpense = 0.0
        for row in ctx.expenseRows { totalExpense += ReportMath.orZero(row.amount) }
        return TaxInclusiveSummary(
            purchaseTotal: r(totalExpense),
            salesTotal: r(totalIncome),
            // The subtraction is rounded ONCE; `r(a) - r(b)` can differ by a cent.
            difference: r(totalIncome - totalExpense))
    }

    /// `tw.js:52-62` — the monthly breakdown.
    ///
    /// Twelve entries keyed on `ctx.year`, never on the reporting period
    /// (Appendix A9). Uses the optional-chained date spelling and the guarded
    /// rounder.
    static func monthlyBreakdown(_ ctx: ReportContext) -> [ReportMonth] {
        let r = ReportMath.round2OrZero
        return ReportMonth.prefixes(year: ctx.year).enumerated().map { index, prefix in
            var revenue = 0.0
            for row in ctx.incomeRows where MonthMatch.optionalChained(row.date, prefix) {
                revenue += ReportMath.netAmount(row.amountNet, row.amount)
            }
            var cost = 0.0
            for row in ctx.expenseRows where MonthMatch.optionalChained(row.date, prefix) {
                cost += ReportMath.netAmount(row.amountNet, row.amount)
            }
            return ReportMonth(month: index + 1, revenue: r(revenue), cost: r(cost),
                               profit: r(revenue - cost))
        }
    }
}
