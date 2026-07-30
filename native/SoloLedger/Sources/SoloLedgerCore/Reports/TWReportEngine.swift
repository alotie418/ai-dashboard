import Foundation

/// 台灣報表引擎 —— batch-1 fields only. Mirror of `electron/reports/tw.js`.
///
/// Batch-1 arithmetic matches Japan and Korea exactly today. Kept as its own file
/// on purpose — see the note in ``JPReportEngine``.
enum TWReportEngine {

    /// `tw.js` batch-1 lines: 14 (rounder), 16-26 (sums, operating profit),
    /// 33-37 (emitted block).
    static func batchOne(_ ctx: ReportContext) -> BatchOneIncomeStatementWithOperatingProfit {
        let split = ExpenseSplit.splitExpenses(ctx.expenseRows, ctx.categories)

        let r = ReportMath.round2OrZero                       // tw.js:14 — has `|| 0`

        // tw.js:17
        var totalIncomeNet = 0.0
        for row in ctx.incomeRows { totalIncomeNet += ReportMath.netAmount(row.amountNet, row.amount) }

        let revenue = totalIncomeNet                          // tw.js:23
        let cogs = split.cogsNet                              // tw.js:24 — COGS only
        let grossProfit = revenue - cogs                      // tw.js:25
        let operatingProfit = grossProfit - split.operatingExpensesNet - ctx.adminExpense // tw.js:26

        // tw.js:30-33 — the estimate layer. `refusal` is the ONLY path to a refusal:
        // asking `ctx.incomeTaxRate.rate` and defaulting to `.notConfigured` would
        // render a corrupt value as "go configure one".
        let refusal = EstimatedValue.refusal(for: ctx.incomeTaxRate, parameter: .incomeTaxRate)
        let rate = ctx.incomeTaxRate.rate
        // tw.js:31 — clamped at 0, so a loss period pays no income tax and netProfit
        // equals operatingProfit. Rounded ONCE here…
        let taxPayable = rate.map { r(ReportMath.max(0, operatingProfit) * ($0 / 100)) }
        // …and NOT rounded again at the emit (tw.js:42 passes `taxPayable`
        // straight through), unlike China which rounds it twice.
        let incomeTax = refusal ?? .computed(taxPayable ?? 0)
        // tw.js:32 — the UNROUNDED operating profit minus the ROUNDED tax.
        let netProfitRaw = taxPayable.map { operatingProfit - $0 }
        let netProfit = refusal ?? .computed(r(netProfitRaw ?? 0))
        // tw.js:43 — ×100 then the rounder's ×100 again. China multiplies by
        // 10000 once (cn.js:60); algebraically equal, measurably different in
        // binary64, so the two must not be "unified".
        let netMargin = refusal ?? .computed(
            revenue > 0 ? r((netProfitRaw ?? 0) / revenue * 100) : 0)

        return BatchOneIncomeStatementWithOperatingProfit(
            salesRevenue: r(revenue),                         // tw.js:34
            costOfSales: r(cogs),                             // tw.js:34
            costOfGoodsSold: r(split.cogsNet),                // tw.js:35
            operatingExpenses: r(split.operatingExpensesNet), // tw.js:35
            grossProfit: r(grossProfit),                      // tw.js:36
            // tw.js:36 — inline, scaled by 100 twice (not 10000 once, as CN does).
            grossMargin: revenue > 0 ? r(grossProfit / revenue * 100) : 0,
            adminExpense: r(ctx.adminExpense),                // tw.js:37
            operatingProfit: r(operatingProfit),               // tw.js:37
            // ── Batch 5 (R7) — the estimate layer ──────────────────────────────
            //
            // Reads the UNROUNDED `operatingProfit` local, not the rounded field
            // emitted above: tw.js:31 multiplies the local. Taking the struct's
            // value back out would round twice.
            incomeTax: incomeTax,
            netProfit: netProfit,
            netMargin: netMargin
        )
    }
}

// MARK: - Batch 2

extension TWReportEngine {

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

    /// `tw.js:29`, `:41-43` — 營業稅.
    ///
    /// Field-for-field identical to Japan's block and named differently
    /// (`businessTax` vs `consumptionTax`) for a different tax. Kept as its own
    /// type for the same reason Korea's is.
    static func businessTax(_ ctx: ReportContext) -> TWBusinessTax {
        let r = ReportMath.round2OrZero
        // tw.js:18 / :21
        var totalIncomeTax = 0.0
        for row in ctx.incomeRows { totalIncomeTax += ReportMath.orZero(row.taxAmount) }
        var totalExpenseTax = 0.0
        for row in ctx.expenseRows { totalExpenseTax += ReportMath.orZero(row.taxAmount) }

        // tw.js:29 — the local name is `businessTaxPayable`.
        let businessTaxPayable = r(ReportMath.max(0, totalIncomeTax - totalExpenseTax))

        return TWBusinessTax(
            collected: r(totalIncomeTax),                                // tw.js:42
            paid: r(totalExpenseTax),                                    // tw.js:42
            payable: businessTaxPayable)                                 // tw.js:42 — NOT re-rounded
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
