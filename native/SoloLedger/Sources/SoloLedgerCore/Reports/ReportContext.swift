import Foundation

/// The inputs the engines read.
///
/// A DELIBERATELY SMALL subset of the dispatcher's context (`index.js:80-84`). The
/// plan's batching seam is "does this field read a `settings` value" (§2), and
/// batch 1 was the largest set that reads none — which is why this type carried no
/// tax rate at all through R2–R5, and why adding one "for later" would have erased
/// the seam those batches existed to draw.
///
/// **R6 is the batch where that stops being true**, and A4-2 completes the move.
/// ``incomeTaxRate`` and ``surchargeRate`` are here because their subject is the
/// parameters' four states and getting them to the engines intact; the estimate
/// layer that READS them is R7. So the fields arrive before their first consumer,
/// on purpose — the alternative was for R7 to introduce both the state model and
/// the arithmetic that depends on it in a single diff, where a mistake in the
/// former would be reviewed as if it were part of the latter.
///
/// R6 said `surchargeRate` "has no missing state to model" and left it out. That
/// was true of *not-configured* and **false of needs-repair**: the `malformed`
/// golden sets `surcharge_rate` to `"12%"`, and China's five null fields in
/// `malformed-CN-2025.json` come from that row. A4-2 is the correction.
///
/// `vatRate` stays absent, for an unrelated reason: the dispatcher loads it
/// (`index.js:86`, `:105`) and NO engine reads it (plan Appendix A6). Porting it as
/// a live parameter would mirror a bug.
///
/// `adminExpense` is here and is not an exception: `admin_expense_annual` falls
/// back to 0 regardless of regime (`index.js:100`), so it needs no fallback policy,
/// no empty state and no confirmation prompt. It is **not** a tax rate and scheme A
/// deliberately does not gate on it — a missing admin-expense row still means 0,
/// and operating profit is therefore unaffected by everything above.
public struct ReportContext: Equatable, Sendable {
    public let incomeRows: [ReportRow]
    public let expenseRows: [ReportRow]
    public let categories: [ReportCategory]
    /// `admin_expense_annual`, already coerced the way the dispatcher coerces it.
    public let adminExpense: Double
    /// `income_tax_rate` as the four states of plan §6.2 / §6.4 — resolved from
    /// whether the settings ROW exists (A-3) and then from its stored BYTES (A-4),
    /// never from a computed figure.
    ///
    /// Every engine in R7 must branch on this. There is no `Double` spelling of it
    /// for the same reason `index.js` hands the engines `null`: a rate that is not
    /// there must be impossible to multiply by.
    public let incomeTaxRate: ReportRateSetting
    /// `surcharge_rate`, in the same four states.
    ///
    /// **Only China's engine may consume it** (`cn.js:33`). Outside China a missing
    /// row answers `.notConfigured` and R7 must simply not look: a Japanese report
    /// must not be blocked because a rate no Japanese line reads has no row.
    public let surchargeRate: ReportRateSetting
    public let currency: String
    public let year: String
    public let from: String
    public let to: String

    public init(incomeRows: [ReportRow], expenseRows: [ReportRow],
                categories: [ReportCategory], adminExpense: Double,
                incomeTaxRate: ReportRateSetting, surchargeRate: ReportRateSetting,
                currency: String, year: String, from: String, to: String) {
        self.incomeRows = incomeRows
        self.expenseRows = expenseRows
        self.categories = categories
        self.adminExpense = adminExpense
        self.incomeTaxRate = incomeTaxRate
        self.surchargeRate = surchargeRate
        self.currency = currency
        self.year = year
        self.from = from
        self.to = to
    }
}

/// The batch-1 income-statement fields shared by CN / JP / KR / TW.
///
/// The absent fields are absent, not `nil`. `operatingProfit` for China,
/// `incomeTax`, `netProfit` and `netMargin` for everyone are batch 5 — declaring
/// them as `Double?` now would make "not yet mirrored" and "computed to nothing"
/// the same value, which is the exact confusion plan §6.2 spends four variants
/// keeping apart. A later batch adds the field and every call site that must learn
/// about it fails to compile.
public struct BatchOneIncomeStatement: Equatable, Sendable {
    public let salesRevenue: Double
    public let costOfSales: Double
    public let costOfGoodsSold: Double
    public let operatingExpenses: Double
    public let grossProfit: Double
    public let grossMargin: Double
    public let adminExpense: Double
}

/// China's batch-1 block.
///
/// Separate from ``BatchOneIncomeStatement`` for one reason: `shippingFee`. China
/// is the only engine with it (`cn.js:61`), and China is also the only engine that
/// CANNOT reach operating profit without a tax rate — `operatingProfit` at
/// `cn.js:57` holds `profitBeforeTax`, which consumes `surchargeRate`. So China
/// stops at gross profit in batch 1 while the others do not. That asymmetry is
/// forced by the dependency chain, not chosen (plan §0).
public struct CNBatchOneIncomeStatement: Equatable, Sendable {
    public let salesRevenue: Double
    public let costOfSales: Double
    public let costOfGoodsSold: Double
    public let operatingExpenses: Double
    public let grossProfit: Double
    public let grossMargin: Double
    public let shippingFee: Double
    public let adminExpense: Double
}

/// JP / KR / TW batch-1 block: the shared fields plus operating profit.
public struct BatchOneIncomeStatementWithOperatingProfit: Equatable, Sendable {
    public let salesRevenue: Double
    public let costOfSales: Double
    public let costOfGoodsSold: Double
    public let operatingExpenses: Double
    public let grossProfit: Double
    public let grossMargin: Double
    public let adminExpense: Double
    public let operatingProfit: Double
}

/// The EU block.
///
/// Named `profitLoss` upstream, and its revenue field is `revenue`, not
/// `salesRevenue` (`eu.js:36-37`). The plan forbids "tidying" that (§1.2), and the
/// naming is not cosmetic: it has already caused two Electron downstream handlers
/// to read 0, because they only know `incomeStatement` (Appendix A7). Keeping the
/// name here keeps the mirror honest about what it is mirroring; the Electron-side
/// defect is a separate, separately-approved PR.
public struct EUBatchOneProfitLoss: Equatable, Sendable {
    public let revenue: Double
    public let costOfSales: Double
    public let costOfGoodsSold: Double
    public let operatingExpenses: Double
    public let grossProfit: Double
    public let grossMargin: Double
    public let adminExpense: Double
    public let operatingProfit: Double
}
