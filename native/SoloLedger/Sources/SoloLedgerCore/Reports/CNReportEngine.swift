import Foundation

/// 中国大陆报表引擎 —— batch-1 的损益核心，加上流转税与月度块。Mirror of `electron/reports/cn.js`.
///
/// **China's lines below gross profit all depend on a configured rate, and that is
/// forced by the code, not chosen.** The chain is `profitBeforeTax`
/// (`cn.js profitBeforeTax`) ← `taxSurcharge` (`cn.js taxSurcharge`) ← `surchargeRate`.
/// Japan / EU / Korea / Taiwan reach operating profit without one, which is why they
/// carry an extra batch-1 field and China does not (plan §0). China's own pre-tax
/// profit, income tax and net profit arrive later in this file, each one refusing to
/// price itself when the rate it needs is missing.
///
/// **A truncated statement must never look complete.** Where a rate is absent the
/// value is a stated refusal, never a zero — the type cannot hold "computed to
/// nothing" and "never computed" as the same thing, so no view can render a zero for
/// a figure that was never priced.
enum CNReportEngine {

    /// `cn.js` batch-1 lines: 18-30 for the sums and margin, 43 for the rounder,
    /// 52-62 for the emitted block.
    static func batchOne(_ ctx: ReportContext) -> CNBatchOneIncomeStatement {
        let split = ExpenseSplit.splitExpenses(ctx.expenseRows, ctx.categories)

        // cn.js totalIncomeNet — `incomeRows.reduce((s, r) => s + (r.amount_net || r.amount || 0), 0)`
        var totalIncomeNet = 0.0
        for row in ctx.incomeRows { totalIncomeNet += ReportMath.netAmount(row.amountNet, row.amount) }

        // cn.js totalShipping — `incomeRows.reduce((s, r) => s + (r.shippingCost || 0), 0)`.
        // STRUCTURALLY ZERO on the transactions path: that table has no
        // shippingCost column, so every row contributes 0. Non-zero only for
        // legacy `sales` rows. Preserved deliberately — plan Appendix A4 files the
        // correction as a schema/accounting decision, not a display bug.
        var totalShipping = 0.0
        for row in ctx.incomeRows { totalShipping += ReportMath.orZero(row.shippingCost) }

        let salesRevenue = totalIncomeNet                       // cn.js salesRevenue
        let costOfSales = split.cogsNet                         // cn.js costOfSales — COGS only
        let grossProfit = salesRevenue - costOfSales            // cn.js grossProfit

        // cn.js grossMargin — `salesRevenue > 0 ? Math.round(gp / rev * 10000) / 100 : 0`.
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
        // `grossMargin` is also emitted RAW at cn.js incomeStatement, i.e. it does NOT go
        // through `r()` a second time.
        let grossMargin = salesRevenue > 0
            ? ReportMath.percent2(grossProfit / salesRevenue)
            : 0

        // cn.js generate — `const r = (v) => Math.round(v * 100) / 100`.
        //
        // NOTE the missing `|| 0`. China's rounder is the ONLY one without it, so a
        // NaN flows through and `JSON.stringify` writes null. Measured on a
        // batch-1 field: with a malformed `admin_expense_annual`, China emits
        // `adminExpense: null` where Japan and the EU emit 0. That asymmetry is
        // inside this batch's surface, so `round2` — not `round2OrZero` — is the
        // correct match here and using the wrong one would be invisible on the
        // happy path.
        let r = ReportMath.round2

        // ── Batch 5 (R7) — China's surcharge chain, then income tax ───────────
        //
        // TWO independent gates, and they are not the same gate. `taxSurcharge` and
        // pre-tax profit ride on the SURCHARGE rate alone; income tax and everything
        // below it ride on `cannotPrice = surchargeMissing || rateMissing`
        // (cn.js cannotPrice). So "surcharge usable, income-tax row corrupt" is a reachable
        // state where the first two are numbers and the last three refuse — no
        // golden covers that combination (the malformed variants break BOTH rows),
        // which is why ReportBatch5BlindSpotTests pins it directly.
        let surchargeRefusal = EstimatedValue.refusal(for: ctx.surchargeRate,
                                                      parameter: .surchargeRate)
        let rateRefusal = EstimatedValue.refusal(for: ctx.incomeTaxRate,
                                                 parameter: .incomeTaxRate)
        // `||` short-circuits in JS, so with BOTH rows unusable the blocker named is
        // the SURCHARGE. Reproduced by asking surcharge first, not by deciding
        // afterwards from which number came out.
        let cannotPrice = surchargeRefusal ?? rateRefusal

        // cn.js totalIncomeNet / :23 — the tax-amount sums. Recomputed here rather than read
        // back out of ``vatSummary(_:)``: that block emits them ROUNDED, and the
        // surcharge multiplies the raw clamped difference.
        var totalIncomeTax = 0.0
        for row in ctx.incomeRows { totalIncomeTax += ReportMath.orZero(row.taxAmount) }
        var totalExpenseTax = 0.0
        for row in ctx.expenseRows { totalExpenseTax += ReportMath.orZero(row.taxAmount) }

        // cn.js vatPayable — the RAW clamped payable, not the rounded `estimatedPayable` the
        // VAT block emits. Measured: the two disagree on 192,655 of the sampled
        // inputs, so reading the batch-4 field back out would be a different number.
        let vatPayable = ReportMath.max(0, totalIncomeTax - totalExpenseTax)
        // cn.js taxSurcharge — `Math.round(v * 100) / 100` INLINE, and China's rounder has
        // no `|| 0` guard.
        let taxSurchargeRaw = ctx.surchargeRate.rate.map { ReportMath.round2(vatPayable * ($0 / 100)) }
        // cn.js profitBeforeTax — five terms, left to right, all UNROUNDED. The shipping term
        // is non-zero only on the legacy path (Appendix A4) and `base-CN-2024` is
        // the single golden that proves it is subtracted at all.
        let profitBeforeTax = taxSurchargeRaw.map {
            grossProfit - split.operatingExpensesNet - $0 - totalShipping - ctx.adminExpense
        }
        // cn.js incomeTax — clamped, rounded once here and again at the emit (cn.js incomeTax).
        let incomeTaxRaw: Double? = (cannotPrice == nil)
            ? ReportMath.round2(ReportMath.max(0, profitBeforeTax ?? 0)
                                * ((ctx.incomeTaxRate.rate ?? 0) / 100))
            : nil
        let netProfitRaw = incomeTaxRaw.map { (profitBeforeTax ?? 0) - $0 }

        let taxSurcharge = surchargeRefusal ?? .computed(ReportMath.round2(taxSurchargeRaw ?? 0))
        let operatingProfit = surchargeRefusal ?? .computed(ReportMath.round2(profitBeforeTax ?? 0))
        let incomeTax = cannotPrice ?? .computed(ReportMath.round2(incomeTaxRaw ?? 0))
        let netProfit = cannotPrice ?? .computed(ReportMath.round2(netProfitRaw ?? 0))
        // cn.js netMargin — ×10000 ONCE, and emitted WITHOUT a second round (cn.js incomeStatement).
        let netMargin = cannotPrice ?? .computed(
            salesRevenue > 0 ? ReportMath.percent2((netProfitRaw ?? 0) / salesRevenue) : 0)

        return CNBatchOneIncomeStatement(
            salesRevenue: r(salesRevenue),               // cn.js salesRevenue
            costOfSales: r(costOfSales),                 // cn.js costOfSales
            costOfGoodsSold: r(split.cogsNet),           // cn.js costOfGoodsSold
            operatingExpenses: r(split.operatingExpensesNet), // cn.js operatingExpenses
            grossProfit: r(grossProfit),                 // cn.js grossProfit
            grossMargin: grossMargin,                    // cn.js incomeStatement — raw, not rounded again
            shippingFee: r(totalShipping),               // cn.js shippingFee
            adminExpense: r(ctx.adminExpense),            // cn.js generate

            // ── Batch 5 (R7) ──────────────────────────────────────────────────
            // `operatingProfit` carries PRE-TAX profit — the source's own naming
            // (plan §1.2), not a mistake to tidy.
            operatingProfit: operatingProfit,
            taxSurcharge: taxSurcharge,
            incomeTax: incomeTax,
            netProfit: netProfit,
            netMargin: netMargin
        )
    }
}

// MARK: - Batch 2

extension CNReportEngine {

    /// `cn.js taxInclusiveSummary` — 含税金额汇总.
    ///
    /// TAX-INCLUSIVE sums (`cn.js totalIncome`, `:21`), not the net ones the P&L uses.
    ///
    /// China's rounder is `round2`, the one WITHOUT `|| 0` (`cn.js generate`). Stated
    /// honestly: here that is a FIDELITY choice and not a behavioural one, because
    /// the sums cannot reach the rounder as NaN — `cn.js totalIncome` already guards each
    /// term with `(r.amount || 0)`, so a NaN amount contributes 0 and never
    /// survives to be rounded. Verified in node: a NaN `amount` yields
    /// `{0, 0, 0}` under China AND Japan alike. The functions differ only where a
    /// falsy total can arise, and no batch-2 input produces one. `round2` is used
    /// because that is what the source says, not because a test can tell.
    static func taxInclusiveSummary(_ ctx: ReportContext) -> TaxInclusiveSummary {
        var totalIncome = 0.0
        for row in ctx.incomeRows { totalIncome += ReportMath.orZero(row.amount) }   // cn.js totalIncome
        var totalExpense = 0.0
        for row in ctx.expenseRows { totalExpense += ReportMath.orZero(row.amount) } // cn.js totalExpense
        return TaxInclusiveSummary(
            purchaseTotal: ReportMath.round2(totalExpense),                 // cn.js purchaseTotal
            salesTotal: ReportMath.round2(totalIncome),                     // cn.js salesTotal
            // cn.js difference — the SUBTRACTION happens first and is rounded ONCE.
            // `r(a) - r(b)` would round twice and can differ by a cent.
            difference: ReportMath.round2(totalIncome - totalExpense))
    }

    /// `cn.js vatSummary` — 增值税统计, plus the disclosure the clamp would hide.
    ///
    /// Reads `tax_amount` and nothing else — no rate, no `amount`, no `amount_net`.
    ///
    /// `round2` (not `round2OrZero`) because `cn.js generate` is the rounder without the
    /// `|| 0`. Stated honestly, as in ``taxInclusiveSummary(_:)``: here that is a
    /// FIDELITY choice, not a behavioural one. `cn.js totalIncomeTax` and `:23` already guard
    /// each term with `(r.tax_amount || 0)`, so a NaN tax contributes 0 and no NaN
    /// can reach the rounder. Measured in node — a NaN tax on one of two rows gives
    /// `{20, 50, 20, 50, 30}` under China exactly as it does under Japan.
    static func vatSummary(_ ctx: ReportContext) -> CNVATSummary {
        // cn.js totalIncomeTax / :23
        var totalIncomeTax = 0.0
        for row in ctx.incomeRows { totalIncomeTax += ReportMath.orZero(row.taxAmount) }
        var totalExpenseTax = 0.0
        for row in ctx.expenseRows { totalExpenseTax += ReportMath.orZero(row.taxAmount) }

        // cn.js vatPayable — the clamp. `ReportMath.max`, not `Swift.max`: the two differ
        // on NaN and on signed zero, and this is the same expression whose NaN
        // behaviour makes `malformed-CN-2025` record nulls further down the file.
        let vatPayable = ReportMath.max(0, totalIncomeTax - totalExpenseTax)
        let r = ReportMath.round2

        return CNVATSummary(
            cumulativeInput: r(totalExpenseTax),        // cn.js cumulativeInput
            cumulativeOutput: r(totalIncomeTax),        // cn.js cumulativeOutput
            certifiedInput: r(totalExpenseTax),         // cn.js certifiedInput — the SAME expression as :70
            invoicedOutput: r(totalIncomeTax),          // cn.js invoicedOutput — the SAME expression as :71
            estimatedPayable: r(vatPayable))            // cn.js estimatedPayable
    }

    /// `cn.js buildMonthly` — 月度明细.
    ///
    /// China rounds INLINE here (`cn.js revenue`) rather than through `r`, but the
    /// expression is the same `Math.round(x * 100) / 100`, so it is still the
    /// unguarded rounder. And it uses the `r.date && r.date.startsWith(...)`
    /// spelling, not optional chaining.
    static func monthlyBreakdown(_ ctx: ReportContext) -> [ReportMonth] {
        ReportMonth.prefixes(year: ctx.year).enumerated().map { index, prefix in
            var revenue = 0.0
            for row in ctx.incomeRows where MonthMatch.cn(row.date, prefix) {
                revenue += ReportMath.netAmount(row.amountNet, row.amount)   // cn.js revenue
            }
            var cost = 0.0
            for row in ctx.expenseRows where MonthMatch.cn(row.date, prefix) {
                cost += ReportMath.netAmount(row.amountNet, row.amount)      // cn.js cost
            }
            return ReportMonth(month: index + 1,
                               revenue: ReportMath.round2(revenue),          // cn.js revenue
                               cost: ReportMath.round2(cost),                // cn.js cost
                               profit: ReportMath.round2(revenue - cost))    // cn.js profit
        }
    }
}
