import Foundation

/// 韩国报表引擎 —— batch-1 fields only. Mirror of `electron/reports/kr.js`.
///
/// Batch-1 arithmetic matches Japan and Taiwan exactly today. Kept as its own file
/// on purpose — see the note in ``JPReportEngine``.
public enum KRReportEngine {

    /// `kr.js` batch-1 lines: 14 (rounder), 16-26 (sums, operating profit),
    /// 33-37 (emitted block).
    public static func batchOne(_ ctx: ReportContext) -> BatchOneIncomeStatementWithOperatingProfit {
        let split = ExpenseSplit.splitExpenses(ctx.expenseRows, ctx.categories)

        let r = ReportMath.round2OrZero                       // kr.js:14 — has `|| 0`

        // kr.js:17
        var totalIncomeNet = 0.0
        for row in ctx.incomeRows { totalIncomeNet += ReportMath.netAmount(row.amountNet, row.amount) }

        let revenue = totalIncomeNet                          // kr.js:23
        let cogs = split.cogsNet                              // kr.js:24 — COGS only
        let grossProfit = revenue - cogs                      // kr.js:25
        let operatingProfit = grossProfit - split.operatingExpensesNet - ctx.adminExpense // kr.js:26

        return BatchOneIncomeStatementWithOperatingProfit(
            salesRevenue: r(revenue),                         // kr.js:34
            costOfSales: r(cogs),                             // kr.js:34
            costOfGoodsSold: r(split.cogsNet),                // kr.js:35
            operatingExpenses: r(split.operatingExpensesNet), // kr.js:35
            grossProfit: r(grossProfit),                      // kr.js:36
            // kr.js:36 — inline, scaled by 100 twice (not 10000 once, as CN does).
            grossMargin: revenue > 0 ? r(grossProfit / revenue * 100) : 0,
            adminExpense: r(ctx.adminExpense),                // kr.js:37
            operatingProfit: r(operatingProfit)               // kr.js:37
        )
    }
}
