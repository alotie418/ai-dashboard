import Foundation

/// Mirror of `electron/reports/index.js` — read settings, fetch rows, route to the
/// regional engine, append cash flow.
///
/// **The legacy fallback branch is not mirrored** (plan §1.1 / §6.1, per #395).
/// `index.js:56-65` falls back to the old `sales` / `purchases` tables when a
/// period holds no transactions; the native app does not read those tables at all.
/// No symbol in this file — or anywhere in `Sources/` — names them, and a test
/// asserts that.
///
/// What that decision costs is stated rather than hidden: for a period whose rows
/// live only in the legacy tables, Electron reports real money and this reports
/// nothing. See ``OperatingCashflowSection`` for why "nothing" is not `{0, 0, 0}`.
public enum ReportDispatcher {

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case unsupportedLocale(String)

        public var description: String {
            switch self {
            case .unsupportedLocale(let l):
                // index.js:30's message, kept recognisable.
                return "Unsupported accounting locale: \(l). Supported: CN/US/JP/EU/KR/TW"
            }
        }
    }

    /// The batch-2 slice of a report.
    ///
    /// `period` ships WITH `monthlyBreakdown` deliberately: the breakdown's window
    /// comes from `year`, not from `[from, to]`, so without the period beside it
    /// the Appendix A9 mismatch would leave no trace in the output at all.
    ///
    /// `reportTypes` is absent from THIS struct and stays absent. Batch 4 mirrored
    /// it as ``ReportTypes``, where the review it was waiting for is recorded: the
    /// `name` maps are historical copy covering two or three of six UI languages
    /// and carrying four defects, so they are mirrored verbatim and are not display
    /// strings. Putting them in a batch-2 result would hand a view a `name` it
    /// would reasonably render.
    public struct BatchTwo: Equatable, Sendable {
        public let locale: String
        public let year: String
        public let from: String
        public let to: String
        public let currency: String
        /// Absent for the US — `us.js` has no such block (not an empty one).
        public let taxInclusiveSummary: TaxInclusiveSummary?
        public let monthlyBreakdown: [ReportMonth]
        /// Hardcoded `[]` in all five VAT engines; the US warnings are derived from
        /// the estimate layer and are batch 5.
        public let warnings: [String]
        public let cashflowStatement: CashflowStatement
    }

    /// `index.js:26-91`, minus the legacy branch.
    ///
    /// - Parameter year: pass explicitly. `index.js:33` falls back to
    ///   `new Date().getFullYear()`, which would make output depend on the wall
    ///   clock; the goldens are generated with an explicit year for that reason
    ///   (plan §4.2 item 4) and callers here should do the same.
    public static func batchTwo(_ db: SQLiteDatabase,
                                locale explicitLocale: String? = nil,
                                year explicitYear: String? = nil,
                                from explicitFrom: String? = nil,
                                to explicitTo: String? = nil) throws -> BatchTwo {

        // index.js:27 — the opts value wins, else the stored setting, else 'CN'.
        let locale = try resolveLocale(db, explicitLocale)

        let year = explicitYear ?? String(Calendar(identifier: .gregorian)
            .component(.year, from: Date()))                       // index.js:33
        let from = explicitFrom ?? "\(year)-01-01"                  // index.js:34
        let to = explicitTo ?? "\(year)-12-31"                      // index.js:35

        // index.js:41-46 — the source decision, counted on `date`.
        let hasTable = try ReportFetch.hasTransactionsTable(db)
        let periodTxnCount = hasTable
            ? try ReportFetch.periodTransactionCount(db, from: from, to: to) : 0
        let source = selectReportSource(hasTransactionsTable: hasTable,
                                        periodTxnCount: periodTxnCount)

        let ctx = try context(db, locale: locale, source: source,
                              year: year, from: from, to: to)

        let taxInclusive: TaxInclusiveSummary?
        let monthly: [ReportMonth]
        switch locale {
        case "CN": taxInclusive = CNReportEngine.taxInclusiveSummary(ctx)
                   monthly = CNReportEngine.monthlyBreakdown(ctx)
        case "JP": taxInclusive = JPReportEngine.taxInclusiveSummary(ctx)
                   monthly = JPReportEngine.monthlyBreakdown(ctx)
        case "EU": taxInclusive = EUReportEngine.taxInclusiveSummary(ctx)
                   monthly = EUReportEngine.monthlyBreakdown(ctx)
        case "KR": taxInclusive = KRReportEngine.taxInclusiveSummary(ctx)
                   monthly = KRReportEngine.monthlyBreakdown(ctx)
        case "TW": taxInclusive = TWReportEngine.taxInclusiveSummary(ctx)
                   monthly = TWReportEngine.monthlyBreakdown(ctx)
        default:   taxInclusive = nil                       // US has no such block
                   monthly = USReportEngine.monthlyBreakdown(ctx)
        }

        return BatchTwo(
            locale: locale, year: year, from: from, to: to, currency: ctx.currency,
            taxInclusiveSummary: taxInclusive, monthlyBreakdown: monthly,
            warnings: [],
            // index.js:90 — appended LAST, after the engine has run.
            cashflowStatement: try cashflow(db, source: source, from: from, to: to))
    }

    /// `index.js:27-31` — the effective accounting locale, or a throw.
    ///
    /// Extracted so that anything else needing the locale (``context(_:locale:source:year:from:to:)``
    /// resolves the income-tax rate against it) asks the SAME question. Note this is
    /// NOT `SettingsStore.accountingLocale()`, which silently answers `.CN` for an
    /// unrecognised value: a ledger stamped "FR" would then be rendered under
    /// Chinese rules with no indication.
    static func resolveLocale(_ db: SQLiteDatabase, _ explicit: String?) throws -> String {
        let locale = explicit ?? ReportSettings.string(db, "accounting_locale", fallback: "CN")
        guard ["CN", "US", "JP", "EU", "KR", "TW"].contains(locale) else {
            throw Failure.unsupportedLocale(locale)      // index.js:29-31
        }
        return locale
    }

    /// `index.js:47-102` — the rows, the categories and the settings the engines see.
    ///
    /// Split out of ``batchTwo(_:locale:year:from:to:)`` for one reason: the
    /// income-tax rate's three states (plan §6.2) are decided HERE, from the
    /// database, and R6 has no engine that consumes them yet — R7's estimate layer
    /// is where they are first multiplied by anything. A test that could only
    /// observe them through a finished report would have to wait for R7 to exist,
    /// which is how a resolution rule ships unverified.
    ///
    /// The legacy branch is absent, per §6.1: rows are read only when the source is
    /// `transactions`; otherwise the engines see nothing, which is the honest
    /// consequence of not mirroring `index.js:56-65` rather than a bug.
    ///
    /// - Parameter locale: already resolved and validated by ``resolveLocale(_:_:)``.
    ///   The rate gate reads it, so handing it the stored setting where an explicit
    ///   `opts.locale` overrode it would gate on one regime and compute under another.
    static func context(_ db: SQLiteDatabase, locale: String, source: ReportSource,
                        year: String, from: String, to: String) throws -> ReportContext {
        let incomeRows = source == .transactions
            ? try ReportFetch.rows(db, type: "income", from: from, to: to) : []
        let expenseRows = source == .transactions
            ? try ReportFetch.rows(db, type: "expense", from: from, to: to) : []
        // index.js:79-83 — the categories read is wrapped in a swallowing catch
        // because the table may not exist on an early-schema database.
        let categories = (try? ReportFetch.categories(db, locale: locale)) ?? []

        return ReportContext(
            incomeRows: incomeRows, expenseRows: expenseRows, categories: categories,
            adminExpense: ReportSettings.number(db, "admin_expense_annual", fallback: 0),
            // index.js:88-99 — scheme A. Decided by whether the ROW exists, never by
            // the number it would have produced (A-3).
            incomeTaxRate: ReportSettings.incomeTaxRate(db, locale: locale),
            currency: ReportSettings.string(db, "currency", fallback: "CNY"),
            year: year, from: from, to: to)
    }

    /// `_cashflow.js:40-97`, transactions branch only.
    ///
    /// When the period has no transactions the operating block is
    /// `.notConfigured`, NOT `{0, 0, 0}` — see ``OperatingCashflowSection``. The
    /// legacy branch that would have produced real figures here is not mirrored,
    /// so a zero would be an artefact of a decision the reader cannot see.
    static func cashflow(_ db: SQLiteDatabase, source: ReportSource,
                         from: String, to: String) throws -> CashflowStatement {
        guard source == .transactions else {
            return CashflowStatement(source: source, operating: .notConfigured)
        }
        let rows = try ReportFetch.cashflowRows(db, from: from, to: to)
        return CashflowStatement(source: source,
                                 operating: .computed(Cashflow.operating(rows: rows)))
    }
}
