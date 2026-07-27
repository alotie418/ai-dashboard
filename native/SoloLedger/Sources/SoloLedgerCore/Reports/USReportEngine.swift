import Foundation

/// 美国报表引擎 — **batch-2 fields only**. Mirror of `electron/reports/us.js`.
///
/// The US is the odd one out twice over, and R3 touches both oddities:
///
/// * **No `taxInclusiveSummary`.** Not an empty block — the key does not exist in
///   `us.js`'s output at all, which is why the golden field count for that block
///   is 3 × 45 rather than 3 × 54.
/// * **`monthlyBreakdown` sums the TAX-INCLUSIVE `amount`** (`us.js:135-136`),
///   where the five VAT engines sum `amount_net || amount || 0`. Schedule C works
///   in gross receipts throughout, so this is consistent with its own model — and
///   it means the same ledger produces different monthly figures under the US
///   regime than under any other. Mirrored, not reconciled.
///
/// Everything else in `us.js` — Schedule C, self-employment tax, estimated tax and
/// the warnings derived from them — is batch 3 / batch 5 and is deliberately not
/// here. That is also why this type has no P&L block: the US engine has none.
public enum USReportEngine {

    /// `us.js:130-140` — the monthly breakdown.
    ///
    /// Twelve entries keyed on `ctx.year` regardless of the reporting period
    /// (Appendix A9), the optional-chained date spelling, and `r()` — which for
    /// the US is the guarded rounder (`us.js:142`, `Math.round((v || 0) * 100) / 100`).
    public static func monthlyBreakdown(_ ctx: ReportContext) -> [ReportMonth] {
        let r = ReportMath.round2OrZero
        return ReportMonth.prefixes(year: ctx.year).enumerated().map { index, prefix in
            // us.js:135-136 — `r.amount`, the TAX-INCLUSIVE column. The other five
            // engines use `amount_net || amount || 0` here.
            var income = 0.0
            for row in ctx.incomeRows where MonthMatch.optionalChained(row.date, prefix) {
                income += ReportMath.orZero(row.amount)
            }
            var expense = 0.0
            for row in ctx.expenseRows where MonthMatch.optionalChained(row.date, prefix) {
                expense += ReportMath.orZero(row.amount)
            }
            return ReportMonth(month: index + 1, revenue: r(income), cost: r(expense),
                               profit: r(income - expense))   // us.js:137
        }
    }
}
