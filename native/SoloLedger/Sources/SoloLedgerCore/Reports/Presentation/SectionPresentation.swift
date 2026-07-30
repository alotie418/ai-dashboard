import Foundation

/// A whole report, with every value already classified.
///
/// The type is the enforcement: there is no `EstimatedValue`, no bare `Double` for money,
/// no `ReportTypeEntry`, no `ReportRateSetting` anywhere in it. A view holding one of these
/// cannot write `?? 0`, cannot print a `NaN`, cannot render a report type without its
/// availability, and cannot reach the engines' historical `name` copy — not because it is
/// asked not to, but because none of those things is present.
public struct PresentedReport: Equatable, Sendable {
    public let locale: String
    public let period: ReportPeriod
    /// Proven against the period's rows. Never a silent `"CNY"` fallback.
    public let currency: String
    /// `.legacy` means this period's rows live in tables this app does not read, so every
    /// figure below is structurally empty rather than measured (plan §6.1, per #395).
    public let source: ReportSource
    /// All four keys, always — including the ones this locale does not read.
    public let parameters: [PresentedParameter]
    /// One entry per report type the locale DECLARES, in the engines' own order.
    public let sections: [PresentedSection]
    /// R3's tax-inclusive block for the four regimes that EMIT it without DECLARING a
    /// report type for it. China declares `tax-inclusive`, so its block is an ordinary
    /// `sections` entry; the US engine has no such block at all (not an empty one).
    /// Non-nil for exactly JP / EU / KR / TW — the asymmetry is the source's
    /// (`ReportTypes.cn` alone lists the id) and is surfaced rather than smoothed over.
    public let undeclaredTaxInclusiveSummary: PresentedTaxInclusiveSummary?
    public let monthlyBreakdown: [PresentedMonth]
    public let cashflow: PresentedCashflow
    public let warnings: [PresentedWarning]

    public init(locale: String, period: ReportPeriod, currency: String, source: ReportSource,
                parameters: [PresentedParameter], sections: [PresentedSection],
                undeclaredTaxInclusiveSummary: PresentedTaxInclusiveSummary?,
                monthlyBreakdown: [PresentedMonth], cashflow: PresentedCashflow,
                warnings: [PresentedWarning]) {
        self.locale = locale
        self.period = period
        self.currency = currency
        self.source = source
        self.parameters = parameters
        self.sections = sections
        self.undeclaredTaxInclusiveSummary = undeclaredTaxInclusiveSummary
        self.monthlyBreakdown = monthlyBreakdown
        self.cashflow = cashflow
        self.warnings = warnings
    }
}

/// One declared report type, already combined with what may be shown of it.
///
/// This combination is plan §7.3's requirement. `lines` is EMPTY when `availability` is
/// `.withhold`, so a withheld section has nothing to render even by accident.
public struct PresentedSection: Equatable, Sendable {
    /// The engine's stable id — `income-statement`, `schedule-c`, `se-tax`, … Never the
    /// historical `name` copy, which covers two or three of six languages and carries four
    /// recorded defects.
    public let reportTypeID: String
    public let availability: ReportSectionPresentation
    public let lines: [PresentedLine]
    public let notes: [PresentedNote]

    public init(reportTypeID: String, availability: ReportSectionPresentation,
                lines: [PresentedLine], notes: [PresentedNote]) {
        self.reportTypeID = reportTypeID
        self.availability = availability
        self.lines = lines
        self.notes = notes
    }
}

/// One numeric line.
public struct PresentedLine: Equatable, Sendable {
    /// The ENGINE's own field name — `salesRevenue`, `line24b_meals`, and the EU block's
    /// `revenue` rather than `salesRevenue` (plan §1.2 forbids tidying that). A stable
    /// identifier, not display copy: R8's next step maps it to reviewed six-language keys.
    public let id: String
    public let unit: ReportLineUnit
    public let value: ReportFieldPresentation

    public init(id: String, unit: ReportLineUnit, value: ReportFieldPresentation) {
        self.id = id
        self.unit = unit
        self.value = value
    }
}

public enum ReportLineUnit: Equatable, Sendable {
    case money
    case percent
}

/// A non-numeric fact. Kept out of `lines` so the numeric funnel stays uniform and no view
/// has to special-case a "line" holding a date.
public enum PresentedNote: Equatable, Sendable {
    /// `us.js:106` — calendar dates, never refused.
    case estimatedTaxDueDates([String])
    /// The year whose SE-tax constants were applied, after `resolveSeTaxParams`'s
    /// unknown-year fallback.
    case selfEmploymentParameterYear(Int)
}

public struct PresentedTaxInclusiveSummary: Equatable, Sendable {
    public let purchaseTotal: ReportFieldPresentation
    public let salesTotal: ReportFieldPresentation
    public let difference: ReportFieldPresentation

    public init(purchaseTotal: ReportFieldPresentation, salesTotal: ReportFieldPresentation,
                difference: ReportFieldPresentation) {
        self.purchaseTotal = purchaseTotal
        self.salesTotal = salesTotal
        self.difference = difference
    }
}

public struct PresentedMonth: Equatable, Sendable {
    public let month: Int
    public let revenue: ReportFieldPresentation
    public let cost: ReportFieldPresentation
    public let profit: ReportFieldPresentation

    public init(month: Int, revenue: ReportFieldPresentation,
                cost: ReportFieldPresentation, profit: ReportFieldPresentation) {
        self.month = month
        self.revenue = revenue
        self.cost = cost
        self.profit = profit
    }
}

/// Management-basis, CASH-basis. `statutory` is always false and is carried, not asserted
/// away: it is the machine-readable half of the disclaimer.
public struct PresentedCashflow: Equatable, Sendable {
    public let basis: String
    public let statutory: Bool
    public let source: ReportSource
    public let operating: PresentedCashflowSection
    public let investing: PresentedCashflowSection
    public let financing: PresentedCashflowSection
    public let beginningCash: PresentedCashflowSection
    public let endingCash: PresentedCashflowSection

    public init(basis: String, statutory: Bool, source: ReportSource,
                operating: PresentedCashflowSection, investing: PresentedCashflowSection,
                financing: PresentedCashflowSection, beginningCash: PresentedCashflowSection,
                endingCash: PresentedCashflowSection) {
        self.basis = basis
        self.statutory = statutory
        self.source = source
        self.operating = operating
        self.investing = investing
        self.financing = financing
        self.beginningCash = beginningCash
        self.endingCash = endingCash
    }
}

/// Three DISTINCT names for what the model spells with two same-named `.notConfigured`s.
///
/// Merging them would be a category error: one is permanent and structural, the other is
/// per-period and is emphatically not "no cash moved" — Electron, which reads the legacy
/// tables, reports real money for such a period (`base-CN-2024`: inflow 9040 / net 1260).
public enum PresentedCashflowSection: Equatable, Sendable {
    case computed(inflow: ReportFieldPresentation,
                  outflow: ReportFieldPresentation,
                  net: ReportFieldPresentation)
    /// Operating only: this period holds no transactions and this app does not read the
    /// legacy tables. NOT a claim that no cash moved.
    case noTransactionsInPeriod
    /// Investing / financing / opening / closing: there are no cash accounts, no
    /// fixed-asset register, no liabilities and no opening balances in this data model, so
    /// these can never carry a number.
    case notDerivableFromThisDataModel
}

/// The engine's warnings as FACTS, not as its hardcoded English strings.
///
/// `us.js:112` builds its first warning with `toLocaleString()`, producing e.g.
/// `"Estimated quarterly tax payment: $3,647.6"` — English, ICU-dependent, and missing a
/// trailing zero (Appendix A3). Handing that to a Japanese UI is not an option, so the
/// amount travels classified and the wording is supplied by the presentation layer.
public enum PresentedWarning: Equatable, Sendable {
    case estimatedQuarterlyPayment(amount: ReportFieldPresentation)
    case mealsLimitedToFiftyPercent
}
