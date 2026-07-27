import Foundation

/// The inputs the batch-1 engines read.
///
/// This is a DELIBERATELY SMALL subset of the dispatcher's context
/// (`index.js:80-84`). The plan's batching seam is "does this field read a
/// `settings` value" (§2), and batch 1 is the largest set that reads none — so the
/// three tax rates are absent from this type, not merely unused by it. Adding them
/// "for later" would erase the seam the batch exists to draw.
///
/// `adminExpense` is here and is not an exception: `admin_expense_annual` falls
/// back to 0 regardless of regime (`index.js:77`), so it needs no fallback policy,
/// no empty state and no confirmation prompt.
///
/// `vatRate` is absent for a different reason — the dispatcher loads it
/// (`index.js:74`, `:83`) and NO engine reads it (plan Appendix A6). Porting it as
/// a live parameter would mirror a bug.
public struct ReportContext: Equatable, Sendable {
    public let incomeRows: [ReportRow]
    public let expenseRows: [ReportRow]
    public let categories: [ReportCategory]
    /// `admin_expense_annual`, already coerced the way the dispatcher coerces it.
    public let adminExpense: Double
    public let currency: String
    public let year: String
    public let from: String
    public let to: String

    public init(incomeRows: [ReportRow], expenseRows: [ReportRow],
                categories: [ReportCategory], adminExpense: Double,
                currency: String, year: String, from: String, to: String) {
        self.incomeRows = incomeRows
        self.expenseRows = expenseRows
        self.categories = categories
        self.adminExpense = adminExpense
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
