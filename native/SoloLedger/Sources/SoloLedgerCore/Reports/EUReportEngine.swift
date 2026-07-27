import Foundation

/// EU 通用报表引擎 —— batch-1 fields only. Mirror of `electron/reports/eu.js`.
///
/// The EU block is called `profitLoss` and its revenue field is `revenue`, where
/// the other four say `incomeStatement` / `salesRevenue`. That is NOT tidied here
/// (plan §1.2), and the reason is stronger than consistency-for-its-own-sake: the
/// naming has already caused two Electron downstream handlers to read 0, because
/// they only recognise `incomeStatement` (Appendix A7). A mirror that quietly
/// renamed it would hide a live defect rather than reproduce the system.
public enum EUReportEngine {

    /// `eu.js` batch-1 lines: 14 (rounder), 16-26 (sums, operating profit),
    /// 36-40 (emitted block).
    public static func batchOne(_ ctx: ReportContext) -> EUBatchOneProfitLoss {
        let split = ExpenseSplit.splitExpenses(ctx.expenseRows, ctx.categories)

        let r = ReportMath.round2OrZero                       // eu.js:14 — has `|| 0`

        // eu.js:17
        var totalIncomeNet = 0.0
        for row in ctx.incomeRows { totalIncomeNet += ReportMath.netAmount(row.amountNet, row.amount) }

        let revenue = totalIncomeNet                          // eu.js:23
        let costs = split.cogsNet                             // eu.js:24 — COGS only
        let grossProfit = revenue - costs                     // eu.js:25
        let operatingProfit = grossProfit - split.operatingExpensesNet - ctx.adminExpense // eu.js:26

        return EUBatchOneProfitLoss(
            revenue: r(revenue),                              // eu.js:37
            costOfSales: r(costs),                            // eu.js:37
            costOfGoodsSold: r(split.cogsNet),                // eu.js:38
            operatingExpenses: r(split.operatingExpensesNet), // eu.js:38
            grossProfit: r(grossProfit),                      // eu.js:39
            // eu.js:39 — the margin is computed INLINE in the object literal, and
            // like Japan's it scales by 100 twice rather than by 10000 once.
            grossMargin: revenue > 0 ? r(grossProfit / revenue * 100) : 0,
            adminExpense: r(ctx.adminExpense),                // eu.js:40
            operatingProfit: r(operatingProfit)               // eu.js:40
        )
    }
}
