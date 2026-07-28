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

// MARK: - Batch 2

public extension CNReportEngine {

    /// `cn.js:78-82` — 含税金额汇总.
    ///
    /// TAX-INCLUSIVE sums (`cn.js:18`, `:21`), not the net ones the P&L uses.
    ///
    /// China's rounder is `round2`, the one WITHOUT `|| 0` (`cn.js:43`). Stated
    /// honestly: here that is a FIDELITY choice and not a behavioural one, because
    /// the sums cannot reach the rounder as NaN — `cn.js:18` already guards each
    /// term with `(r.amount || 0)`, so a NaN amount contributes 0 and never
    /// survives to be rounded. Verified in node: a NaN `amount` yields
    /// `{0, 0, 0}` under China AND Japan alike. The functions differ only where a
    /// falsy total can arise, and no batch-2 input produces one. `round2` is used
    /// because that is what the source says, not because a test can tell.
    static func taxInclusiveSummary(_ ctx: ReportContext) -> TaxInclusiveSummary {
        var totalIncome = 0.0
        for row in ctx.incomeRows { totalIncome += ReportMath.orZero(row.amount) }   // cn.js:18
        var totalExpense = 0.0
        for row in ctx.expenseRows { totalExpense += ReportMath.orZero(row.amount) } // cn.js:21
        return TaxInclusiveSummary(
            purchaseTotal: ReportMath.round2(totalExpense),                 // cn.js:79
            salesTotal: ReportMath.round2(totalIncome),                     // cn.js:80
            // cn.js:81 — the SUBTRACTION happens first and is rounded ONCE.
            // `r(a) - r(b)` would round twice and can differ by a cent.
            difference: ReportMath.round2(totalIncome - totalExpense))
    }

    /// `cn.js:69-75` — 增值税统计, plus the disclosure the clamp would hide.
    ///
    /// Reads `tax_amount` and nothing else — no rate, no `amount`, no `amount_net`.
    ///
    /// `round2` (not `round2OrZero`) because `cn.js:43` is the rounder without the
    /// `|| 0`. Stated honestly, as in ``taxInclusiveSummary(_:)``: here that is a
    /// FIDELITY choice, not a behavioural one. `cn.js:20` and `:23` already guard
    /// each term with `(r.tax_amount || 0)`, so a NaN tax contributes 0 and no NaN
    /// can reach the rounder. Measured in node — a NaN tax on one of two rows gives
    /// `{20, 50, 20, 50, 30}` under China exactly as it does under Japan.
    static func vatSummary(_ ctx: ReportContext) -> CNVATSummary {
        // cn.js:20 / :23
        var totalIncomeTax = 0.0
        for row in ctx.incomeRows { totalIncomeTax += ReportMath.orZero(row.taxAmount) }
        var totalExpenseTax = 0.0
        for row in ctx.expenseRows { totalExpenseTax += ReportMath.orZero(row.taxAmount) }

        // cn.js:32 — the clamp. `ReportMath.max`, not `Swift.max`: the two differ
        // on NaN and on signed zero, and this is the same expression whose NaN
        // behaviour makes `malformed-CN-2025` record nulls further down the file.
        let vatPayable = ReportMath.max(0, totalIncomeTax - totalExpenseTax)
        let r = ReportMath.round2

        return CNVATSummary(
            cumulativeInput: r(totalExpenseTax),        // cn.js:70
            cumulativeOutput: r(totalIncomeTax),        // cn.js:71
            certifiedInput: r(totalExpenseTax),         // cn.js:72 — the SAME expression as :70
            invoicedOutput: r(totalIncomeTax),          // cn.js:73 — the SAME expression as :71
            estimatedPayable: r(vatPayable),            // cn.js:74
            // NOT in cn.js. The clamp above reports a credit position as 0; this
            // carries what it discarded. Rounded ONCE, with this engine's rounder,
            // so it is comparable with `estimatedPayable` rather than being a
            // differently-scaled number.
            unclampedDifference: r(totalIncomeTax - totalExpenseTax))
    }

    /// `cn.js:91-108` — 月度明细.
    ///
    /// China rounds INLINE here (`cn.js:102-104`) rather than through `r`, but the
    /// expression is the same `Math.round(x * 100) / 100`, so it is still the
    /// unguarded rounder. And it uses the `r.date && r.date.startsWith(...)`
    /// spelling, not optional chaining.
    static func monthlyBreakdown(_ ctx: ReportContext) -> [ReportMonth] {
        ReportMonth.prefixes(year: ctx.year).enumerated().map { index, prefix in
            var revenue = 0.0
            for row in ctx.incomeRows where MonthMatch.cn(row.date, prefix) {
                revenue += ReportMath.netAmount(row.amountNet, row.amount)   // cn.js:98
            }
            var cost = 0.0
            for row in ctx.expenseRows where MonthMatch.cn(row.date, prefix) {
                cost += ReportMath.netAmount(row.amountNet, row.amount)      // cn.js:99
            }
            return ReportMonth(month: index + 1,
                               revenue: ReportMath.round2(revenue),          // cn.js:102
                               cost: ReportMath.round2(cost),                // cn.js:103
                               profit: ReportMath.round2(revenue - cost))    // cn.js:104
        }
    }
}
