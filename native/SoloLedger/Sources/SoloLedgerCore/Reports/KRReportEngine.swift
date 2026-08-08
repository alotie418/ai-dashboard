import Foundation

/// 韩国报表引擎 —— batch-1 的损益核心，加上流转税与月度块。Mirror of `electron/reports/kr.js`.
///
/// Batch-1 arithmetic matches Japan and Taiwan exactly today. Kept as its own file
/// on purpose — see the note in ``JPReportEngine``.
enum KRReportEngine {

    /// `kr.js` batch-1 lines: 14 (rounder), 16-26 (sums, operating profit),
    /// 33-37 (emitted block).
    static func batchOne(_ ctx: ReportContext) -> BatchOneIncomeStatementWithOperatingProfit {
        let split = ExpenseSplit.splitExpenses(ctx.expenseRows, ctx.categories)

        let r = ReportMath.round2OrZero                       // kr.js generate — has `|| 0`

        // kr.js totalIncomeNet
        var totalIncomeNet = 0.0
        for row in ctx.incomeRows { totalIncomeNet += ReportMath.netAmount(row.amountNet, row.amount) }

        let revenue = totalIncomeNet                          // kr.js revenue@3d7138b
        let cogs = split.cogsNet                              // kr.js cogs — COGS only
        let grossProfit = revenue - cogs                      // kr.js grossProfit
        let operatingProfit = grossProfit - split.operatingExpensesNet - ctx.adminExpense // kr.js operatingProfit

        // kr.js rateMissing — the estimate layer. `refusal` is the ONLY path to a refusal:
        // asking `ctx.incomeTaxRate.rate` and defaulting to `.notConfigured` would
        // render a corrupt value as "go configure one".
        let refusal = EstimatedValue.refusal(for: ctx.incomeTaxRate, parameter: .incomeTaxRate)
        let rate = ctx.incomeTaxRate.rate
        // kr.js tax — clamped at 0, so a loss period pays no income tax and netProfit
        // equals operatingProfit. Rounded ONCE here…
        let taxPayable = rate.map { r(ReportMath.max(0, operatingProfit) * ($0 / 100)) }
        // …and NOT rounded again at the emit (kr.js incomeTax passes `taxPayable`
        // straight through), unlike China which rounds it twice.
        let incomeTax = refusal ?? .computed(taxPayable ?? 0)
        // kr.js netProfit — the UNROUNDED operating profit minus the ROUNDED tax.
        let netProfitRaw = taxPayable.map { operatingProfit - $0 }
        let netProfit = refusal ?? .computed(r(netProfitRaw ?? 0))
        // kr.js netMargin — ×100 then the rounder's ×100 again. China multiplies by
        // 10000 once (cn.js generate); algebraically equal, measurably different in
        // binary64, so the two must not be "unified".
        let netMargin = refusal ?? .computed(
            revenue > 0 ? r((netProfitRaw ?? 0) / revenue * 100) : 0)

        return BatchOneIncomeStatementWithOperatingProfit(
            salesRevenue: r(revenue),                         // kr.js salesRevenue
            costOfSales: r(cogs),                             // kr.js salesRevenue
            costOfGoodsSold: r(split.cogsNet),                // kr.js costOfGoodsSold
            operatingExpenses: r(split.operatingExpensesNet), // kr.js costOfGoodsSold
            grossProfit: r(grossProfit),                      // kr.js grossProfit
            // kr.js grossProfit — inline, scaled by 100 twice (not 10000 once, as CN does).
            grossMargin: revenue > 0 ? r(grossProfit / revenue * 100) : 0,
            adminExpense: r(ctx.adminExpense),                // kr.js adminExpense
            operatingProfit: r(operatingProfit),               // kr.js incomeStatement
            // ── Batch 5 (R7) — the estimate layer ──────────────────────────────
            //
            // Reads the UNROUNDED `operatingProfit` local, not the rounded field
            // emitted above: kr.js tax multiplies the local. Taking the struct's
            // value back out would round twice.
            incomeTax: incomeTax,
            netProfit: netProfit,
            netMargin: netMargin
        )
    }
}

// MARK: - Batch 2

extension KRReportEngine {

    /// `kr.js taxInclusiveSummary` — the tax-inclusive summary.
    ///
    /// TAX-INCLUSIVE sums, not the net ones the P&L uses. This engine's rounder
    /// HAS the `|| 0` guard (`kr.js generate`), unlike China's — so a NaN becomes 0 here
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

    /// `kr.js vatPayable`, `:41-43` — 부가가치세 요약.
    ///
    /// Korea emits this under the key `vatSummary` — the same key China uses for a
    /// FIVE-field block with different field names. Nothing in the JSON says which
    /// shape a `vatSummary` is; only the ledger's locale does. That is the trap
    /// `#414` fell into, and the reason ``KRVATSummary`` is its own type here.
    ///
    /// Korea also skips the intermediate names Japan and the EU use: the clamp at
    /// `kr.js vatPayable` reads `totalIncomeTax` / `totalExpenseTax` directly.
    static func vatSummary(_ ctx: ReportContext) -> KRVATSummary {
        let r = ReportMath.round2OrZero
        // kr.js totalIncomeTax / :21
        var totalIncomeTax = 0.0
        for row in ctx.incomeRows { totalIncomeTax += ReportMath.orZero(row.taxAmount) }
        var totalExpenseTax = 0.0
        for row in ctx.expenseRows { totalExpenseTax += ReportMath.orZero(row.taxAmount) }

        let vatPayable = r(ReportMath.max(0, totalIncomeTax - totalExpenseTax)) // kr.js vatPayable

        return KRVATSummary(
            outputVAT: r(totalIncomeTax),                                // kr.js outputVAT
            inputVAT: r(totalExpenseTax),                                // kr.js outputVAT
            vatPayable: vatPayable)                                      // kr.js outputVAT — NOT re-rounded
    }

    /// `kr.js buildMonthly` — the monthly breakdown.
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
