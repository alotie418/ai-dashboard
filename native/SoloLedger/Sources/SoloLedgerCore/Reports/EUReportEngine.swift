import Foundation

/// EU 通用报表引擎 —— batch-1 的损益核心，加上流转税与月度块。Mirror of `electron/reports/eu.js`.
///
/// The EU block is called `profitLoss` and its revenue field is `revenue`, where
/// the other four say `incomeStatement` / `salesRevenue`. That is NOT tidied here
/// (plan §1.2), and the reason is stronger than consistency-for-its-own-sake: the
/// naming has already caused two Electron downstream handlers to read 0, because
/// they only recognise `incomeStatement` (Appendix A7). A mirror that quietly
/// renamed it would hide a live defect rather than reproduce the system.
enum EUReportEngine {

    /// `eu.js` batch-1 lines: 14 (rounder), 16-26 (sums, operating profit),
    /// 36-40 (emitted block).
    static func batchOne(_ ctx: ReportContext) -> EUBatchOneProfitLoss {
        let split = ExpenseSplit.splitExpenses(ctx.expenseRows, ctx.categories)

        let r = ReportMath.round2OrZero                       // eu.js generate — has `|| 0`

        // eu.js totalIncomeNet
        var totalIncomeNet = 0.0
        for row in ctx.incomeRows { totalIncomeNet += ReportMath.netAmount(row.amountNet, row.amount) }

        let revenue = totalIncomeNet                          // eu.js revenue@3d7138b
        let costs = split.cogsNet                             // eu.js costs — COGS only
        let grossProfit = revenue - costs                     // eu.js grossProfit
        let operatingProfit = grossProfit - split.operatingExpensesNet - ctx.adminExpense // eu.js operatingProfit

        // eu.js generate — the estimate layer. `refusal` is the ONLY path to a refusal.
        let refusal = EstimatedValue.refusal(for: ctx.incomeTaxRate, parameter: .incomeTaxRate)
        let rate = ctx.incomeTaxRate.rate
        // eu.js rateMissing — clamped at 0; rounded ONCE here and NOT again at the emit
        // (eu.js incomeTax passes it straight through), unlike China's double round.
        let tax = rate.map { r(ReportMath.max(0, operatingProfit) * ($0 / 100)) }
        let incomeTax = refusal ?? .computed(tax ?? 0)
        // eu.js tax — UNROUNDED operating profit minus the ROUNDED tax.
        let netProfitRaw = tax.map { operatingProfit - $0 }
        let netProfit = refusal ?? .computed(r(netProfitRaw ?? 0))
        // eu.js netMargin — ×100 then the rounder's ×100 again (cn.js generate does ×10000 once).
        let netMargin = refusal ?? .computed(
            revenue > 0 ? r((netProfitRaw ?? 0) / revenue * 100) : 0)

        return EUBatchOneProfitLoss(
            revenue: r(revenue),                              // eu.js revenue@3d7138b
            costOfSales: r(costs),                            // eu.js revenue@3d7138b
            costOfGoodsSold: r(split.cogsNet),                // eu.js costOfGoodsSold
            operatingExpenses: r(split.operatingExpensesNet), // eu.js costOfGoodsSold
            grossProfit: r(grossProfit),                      // eu.js grossProfit
            // eu.js grossProfit — the margin is computed INLINE in the object literal, and
            // like Japan's it scales by 100 twice rather than by 10000 once.
            grossMargin: revenue > 0 ? r(grossProfit / revenue * 100) : 0,
            adminExpense: r(ctx.adminExpense),                // eu.js adminExpense
            operatingProfit: r(operatingProfit),               // eu.js profitLoss

            // ── Batch 5 (R7) ──────────────────────────────────────────────────
            // Reads the UNROUNDED `operatingProfit` local (eu.js rateMissing multiplies the
            // local); taking the struct's rounded field back out would round twice.
            incomeTax: incomeTax,
            netProfit: netProfit,
            netMargin: netMargin
        )
    }
}

// MARK: - Batch 2

extension EUReportEngine {

    /// `eu.js taxInclusiveSummary` — the tax-inclusive summary.
    ///
    /// TAX-INCLUSIVE sums, not the net ones the P&L uses. This engine's rounder
    /// HAS the `|| 0` guard (`eu.js generate`), unlike China's — so a NaN becomes 0 here
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

    /// `eu.js vatCollected`, `:44-46` — the VAT return summary.
    ///
    /// The block is named `vatReturn`, and its two component names are
    /// `vatCollected` / `vatDeductible` inside the function (`eu.js vatCollected`) but
    /// `outputVAT` / `inputVAT` in the emitted object (`:45`). Both spellings are
    /// kept where the source puts them.
    static func vatReturn(_ ctx: ReportContext) -> EUVATReturn {
        let r = ReportMath.round2OrZero
        // eu.js totalIncomeTax / :21
        var totalIncomeTax = 0.0
        for row in ctx.incomeRows { totalIncomeTax += ReportMath.orZero(row.taxAmount) }
        var totalExpenseTax = 0.0
        for row in ctx.expenseRows { totalExpenseTax += ReportMath.orZero(row.taxAmount) }

        let vatCollected = totalIncomeTax                                // eu.js vatCollected
        let vatDeductible = totalExpenseTax                              // eu.js vatDeductible
        let vatPayable = r(ReportMath.max(0, vatCollected - vatDeductible)) // eu.js vatPayable

        return EUVATReturn(
            outputVAT: r(vatCollected),                                  // eu.js outputVAT
            inputVAT: r(vatDeductible),                                  // eu.js outputVAT
            vatPayable: vatPayable)                                      // eu.js outputVAT — NOT re-rounded
    }

    /// `eu.js buildMonthly` — the monthly breakdown.
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
