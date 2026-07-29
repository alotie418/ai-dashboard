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

        // eu.js:29-32 — the estimate layer. `refusal` is the ONLY path to a refusal.
        let refusal = EstimatedValue.refusal(for: ctx.incomeTaxRate, parameter: .incomeTaxRate)
        let rate = ctx.incomeTaxRate.rate
        // eu.js:30 — clamped at 0; rounded ONCE here and NOT again at the emit
        // (eu.js:45 passes it straight through), unlike China's double round.
        let tax = rate.map { r(ReportMath.max(0, operatingProfit) * ($0 / 100)) }
        let incomeTax = refusal ?? .computed(tax ?? 0)
        // eu.js:31 — UNROUNDED operating profit minus the ROUNDED tax.
        let netProfitRaw = tax.map { operatingProfit - $0 }
        let netProfit = refusal ?? .computed(r(netProfitRaw ?? 0))
        // eu.js:46 — ×100 then the rounder's ×100 again (cn.js:60 does ×10000 once).
        let netMargin = refusal ?? .computed(
            revenue > 0 ? r((netProfitRaw ?? 0) / revenue * 100) : 0)

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
            operatingProfit: r(operatingProfit),               // eu.js:40

            // ── Batch 5 (R7) ──────────────────────────────────────────────────
            // Reads the UNROUNDED `operatingProfit` local (eu.js:30 multiplies the
            // local); taking the struct's rounded field back out would round twice.
            incomeTax: incomeTax,
            netProfit: netProfit,
            netMargin: netMargin
        )
    }
}

// MARK: - Batch 2

public extension EUReportEngine {

    /// `eu.js:47-49` — the tax-inclusive summary.
    ///
    /// TAX-INCLUSIVE sums, not the net ones the P&L uses. This engine's rounder
    /// HAS the `|| 0` guard (`eu.js:14`), unlike China's — so a NaN becomes 0 here
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

    /// `eu.js:30-32`, `:44-46` — the VAT return summary.
    ///
    /// The block is named `vatReturn`, and its two component names are
    /// `vatCollected` / `vatDeductible` inside the function (`eu.js:30-31`) but
    /// `outputVAT` / `inputVAT` in the emitted object (`:45`). Both spellings are
    /// kept where the source puts them.
    static func vatReturn(_ ctx: ReportContext) -> EUVATReturn {
        let r = ReportMath.round2OrZero
        // eu.js:18 / :21
        var totalIncomeTax = 0.0
        for row in ctx.incomeRows { totalIncomeTax += ReportMath.orZero(row.taxAmount) }
        var totalExpenseTax = 0.0
        for row in ctx.expenseRows { totalExpenseTax += ReportMath.orZero(row.taxAmount) }

        let vatCollected = totalIncomeTax                                // eu.js:30
        let vatDeductible = totalExpenseTax                              // eu.js:31
        let vatPayable = r(ReportMath.max(0, vatCollected - vatDeductible)) // eu.js:32

        return EUVATReturn(
            outputVAT: r(vatCollected),                                  // eu.js:45
            inputVAT: r(vatDeductible),                                  // eu.js:45
            vatPayable: vatPayable)                                      // eu.js:45 — NOT re-rounded
    }

    /// `eu.js:55-65` — the monthly breakdown.
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
