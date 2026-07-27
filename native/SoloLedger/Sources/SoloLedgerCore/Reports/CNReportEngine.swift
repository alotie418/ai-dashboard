import Foundation

/// 中国大陆报表引擎 —— batch-1 fields only. Mirror of `electron/reports/cn.js`.
///
/// **China stops at gross profit in this batch, and that is forced by the code,
/// not chosen.** The chain is `profitBeforeTax` (`cn.js:38`) ← `taxSurcharge`
/// (`cn.js:33`) ← `surchargeRate`, so every line below gross profit needs a
/// configured rate. Japan / EU / Korea / Taiwan reach operating profit without
/// one, which is why they get an extra field here and China does not (plan §0).
///
/// **A truncated statement must never look complete.** Batches 1-4 leave China
/// without pre-tax profit, income tax or net profit; plan §7.3 requires any build
/// shipping that state to render the missing rows as an explicit "not configured"
/// empty state. That gate lands with the view layer (R8); what this batch
/// contributes is the type — the absent fields do not exist, so no view can
/// accidentally render a zero for one.
public enum CNReportEngine {

    /// `cn.js` batch-1 lines: 18-30 for the sums and margin, 43 for the rounder,
    /// 52-62 for the emitted block.
    public static func batchOne(_ ctx: ReportContext) -> CNBatchOneIncomeStatement {
        let split = ExpenseSplit.splitExpenses(ctx.expenseRows, ctx.categories)

        // cn.js:19 — `incomeRows.reduce((s, r) => s + (r.amount_net || r.amount || 0), 0)`
        var totalIncomeNet = 0.0
        for row in ctx.incomeRows { totalIncomeNet += ReportMath.netAmount(row.amountNet, row.amount) }

        // cn.js:24 — `incomeRows.reduce((s, r) => s + (r.shippingCost || 0), 0)`.
        // STRUCTURALLY ZERO on the transactions path: that table has no
        // shippingCost column, so every row contributes 0. Non-zero only for
        // legacy `sales` rows. Preserved deliberately — plan Appendix A4 files the
        // correction as a schema/accounting decision, not a display bug.
        var totalShipping = 0.0
        for row in ctx.incomeRows { totalShipping += ReportMath.orZero(row.shippingCost) }

        let salesRevenue = totalIncomeNet                       // cn.js:27
        let costOfSales = split.cogsNet                         // cn.js:28 — COGS only
        let grossProfit = salesRevenue - costOfSales            // cn.js:29

        // cn.js:30 — `salesRevenue > 0 ? Math.round(gp / rev * 10000) / 100 : 0`.
        //
        // TWO things here are not interchangeable with the other four engines:
        //   * the scaling is ONE multiply by 10000, where JP/EU/KR/TW multiply by
        //     100 and then let their rounder multiply by 100 again. Algebraically
        //     identical, NOT identical in binary64 — measured, the two disagree by
        //     one hundredth on 791 of 80001 two-decimal COGS values at revenue 800
        //     (e.g. revenue 8.00 / COGS 1.73 gives 78.37 here and 78.38 there).
        //   * the guard tests the UNROUNDED revenue, and the false branch is the
        //     integer literal 0 — POSITIVE zero.
        //
        // `grossMargin` is also emitted RAW at cn.js:59, i.e. it does NOT go
        // through `r()` a second time.
        let grossMargin = salesRevenue > 0
            ? ReportMath.percent2(grossProfit / salesRevenue)
            : 0

        // cn.js:43 — `const r = (v) => Math.round(v * 100) / 100`.
        //
        // NOTE the missing `|| 0`. China's rounder is the ONLY one without it, so a
        // NaN flows through and `JSON.stringify` writes null. Measured on a
        // batch-1 field: with a malformed `admin_expense_annual`, China emits
        // `adminExpense: null` where Japan and the EU emit 0. That asymmetry is
        // inside this batch's surface, so `round2` — not `round2OrZero` — is the
        // correct match here and using the wrong one would be invisible on the
        // happy path.
        let r = ReportMath.round2

        return CNBatchOneIncomeStatement(
            salesRevenue: r(salesRevenue),               // cn.js:53
            costOfSales: r(costOfSales),                 // cn.js:54
            costOfGoodsSold: r(split.cogsNet),           // cn.js:55
            operatingExpenses: r(split.operatingExpensesNet), // cn.js:56
            grossProfit: r(grossProfit),                 // cn.js:58
            grossMargin: grossMargin,                    // cn.js:59 — raw, not rounded again
            shippingFee: r(totalShipping),               // cn.js:61
            adminExpense: r(ctx.adminExpense)            // cn.js:62
        )
    }
}
