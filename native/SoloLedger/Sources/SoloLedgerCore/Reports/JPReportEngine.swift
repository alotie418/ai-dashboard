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

        // jp.js:30-33 — the estimate layer. `refusal` is the ONLY path to a refusal:
        // asking `ctx.incomeTaxRate.rate` and defaulting to `.notConfigured` would
        // render a corrupt value as "go configure one".
        let refusal = EstimatedValue.refusal(for: ctx.incomeTaxRate, parameter: .incomeTaxRate)
        let rate = ctx.incomeTaxRate.rate
        // jp.js:31 — clamped at 0, so a loss period pays no income tax and netProfit
        // equals operatingProfit. Rounded ONCE here…
        let taxPayable = rate.map { r(ReportMath.max(0, operatingProfit) * ($0 / 100)) }
        // …and NOT rounded again at the emit (jp.js:47 passes `taxPayable` straight
        // through), unlike China which rounds it twice.
        let incomeTax = refusal ?? .computed(taxPayable ?? 0)
        // jp.js:32 — the UNROUNDED operating profit minus the ROUNDED tax.
        let netProfitRaw = taxPayable.map { operatingProfit - $0 }
        let netProfit = refusal ?? .computed(r(netProfitRaw ?? 0))
        // jp.js:48 — ×100 then the rounder's ×100 again. China multiplies by 10000
        // once (cn.js:60); algebraically equal, measurably different in binary64,
        // so the two must not be "unified".
        let netMargin = refusal ?? .computed(
            salesRevenue > 0 ? r((netProfitRaw ?? 0) / salesRevenue * 100) : 0)

        return BatchOneIncomeStatementWithOperatingProfit(
            salesRevenue: r(salesRevenue),                     // jp.js:39
            costOfSales: r(costOfSales),                       // jp.js:39
            costOfGoodsSold: r(split.cogsNet),                 // jp.js:40
            operatingExpenses: r(split.operatingExpensesNet),  // jp.js:40
            grossProfit: r(grossProfit),                       // jp.js:41
            grossMargin: grossMargin,                          // jp.js:41 — already rounded
            adminExpense: r(ctx.adminExpense),                 // jp.js:42
            operatingProfit: r(operatingProfit),               // jp.js:42

            // ── Batch 5 (R7) — the estimate layer ──────────────────────────────
            //
            // Reads the UNROUNDED `operatingProfit` local, not the rounded field
            // emitted above: jp.js:31 multiplies the local. Taking the struct's value
            // back out would round twice.
            incomeTax: incomeTax,
            netProfit: netProfit,
            netMargin: netMargin
        )
    }
}

// MARK: - Batch 2

public extension JPReportEngine {

    /// `jp.js:50-53` — the tax-inclusive summary.
    ///
    /// TAX-INCLUSIVE sums, not the net ones the P&L uses. This engine's rounder
    /// HAS the `|| 0` guard (`jp.js:14`), unlike China's — so a NaN becomes 0 here
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

    /// `jp.js:32-34`, `:46-49` — 消費税（仕入税額控除方式）.
    ///
    /// Note the shape difference from China's: the payable is rounded ONCE, at
    /// `jp.js:34`, and placed into the block already rounded (`:48`). China clamps
    /// at `:32` and rounds at the emit (`:74`). Same result, different line — and
    /// the JS is what is being mirrored, so the rounding stays where the source
    /// puts it.
    ///
    /// The currency is irrelevant here. A JPY ledger is still rounded to two
    /// decimals (Appendix A8) because the rounder is `Math.round(v * 100) / 100`
    /// regardless of regime — measured: a 1234.567 tax gives 1234.57 under a JPY
    /// context exactly as under CNY. Mirrored, not repaired.
    static func consumptionTax(_ ctx: ReportContext) -> JPConsumptionTax {
        let r = ReportMath.round2OrZero
        // jp.js:18 / :21
        var totalIncomeTax = 0.0
        for row in ctx.incomeRows { totalIncomeTax += ReportMath.orZero(row.taxAmount) }
        var totalExpenseTax = 0.0
        for row in ctx.expenseRows { totalExpenseTax += ReportMath.orZero(row.taxAmount) }

        let collected = totalIncomeTax                                  // jp.js:32
        let paid = totalExpenseTax                                      // jp.js:33
        let payable = r(ReportMath.max(0, collected - paid))            // jp.js:34

        return JPConsumptionTax(
            collected: r(collected),                                    // jp.js:47
            paid: r(paid),                                              // jp.js:47
            payable: payable)                                           // jp.js:48 — NOT re-rounded
    }

    /// `jp.js:59-69` — the monthly breakdown.
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
