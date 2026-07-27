import Foundation

/// 日本報表引擎 —— batch-1 fields only. Mirror of `electron/reports/jp.js`.
///
/// Japan, the EU, Korea and Taiwan reach OPERATING PROFIT without any configured
/// rate, because their operating profit carries no surcharge. China cannot
/// (`cn.js:38` needs `surchargeRate`), which is the whole reason the batch cut
/// falls where it does.
///
/// Batch-1 arithmetic is currently identical across JP / KR / TW. They are
/// deliberately NOT collapsed into one implementation: what this phase is buying
/// is the ability to read a Swift file next to its JavaScript original line by
/// line. A shared helper would make the next divergence between them — a
/// jurisdiction is free to acquire one — silent instead of obvious.
public enum JPReportEngine {

    /// `jp.js` batch-1 lines: 14 (rounder), 16-27 (sums, margin, operating
    /// profit), 38-42 (emitted block).
    public static func batchOne(_ ctx: ReportContext) -> BatchOneIncomeStatementWithOperatingProfit {
        let split = ExpenseSplit.splitExpenses(ctx.expenseRows, ctx.categories)

        // jp.js:14 — `const r = (v) => Math.round((v || 0) * 100) / 100`.
        // Japan HAS the `|| 0` guard that cn.js:43 lacks, so a NaN becomes 0 here
        // where China would emit null.
        let r = ReportMath.round2OrZero

        // jp.js:17
        var totalIncomeNet = 0.0
        for row in ctx.incomeRows { totalIncomeNet += ReportMath.netAmount(row.amountNet, row.amount) }

        let salesRevenue = totalIncomeNet                     // jp.js:23
        let costOfSales = split.cogsNet                       // jp.js:24 — COGS only
        let grossProfit = salesRevenue - costOfSales          // jp.js:25

        // jp.js:26 — `salesRevenue > 0 ? r(grossProfit / salesRevenue * 100) : 0`.
        // Multiply by 100, then the rounder multiplies by 100 again. China instead
        // multiplies by 10000 once (cn.js:30); the two are algebraically equal and
        // measurably different in binary64, so this must not be "unified" with it.
        let grossMargin = salesRevenue > 0 ? r(grossProfit / salesRevenue * 100) : 0

        // jp.js:27 — operating expenses and admin expense come off here. Not
        // rounded before being emitted; the emit at jp.js:42 rounds it once.
        let operatingProfit = grossProfit - split.operatingExpensesNet - ctx.adminExpense

        return BatchOneIncomeStatementWithOperatingProfit(
            salesRevenue: r(salesRevenue),                     // jp.js:39
            costOfSales: r(costOfSales),                       // jp.js:39
            costOfGoodsSold: r(split.cogsNet),                 // jp.js:40
            operatingExpenses: r(split.operatingExpensesNet),  // jp.js:40
            grossProfit: r(grossProfit),                       // jp.js:41
            grossMargin: grossMargin,                          // jp.js:41 — already rounded
            adminExpense: r(ctx.adminExpense),                 // jp.js:42
            operatingProfit: r(operatingProfit)                // jp.js:42
        )
    }
}
