import Foundation

/// Mirror of `electron/reports/index.js` — read settings, fetch rows, route to the
/// regional engine, append cash flow.
///
/// **The legacy fallback branch is not mirrored** (plan §1.1 / §6.1, per #395).
/// `index.js generate` falls back to the old `sales` / `purchases` tables when a
/// period holds no transactions; nothing on the report path here reads them. No
/// production line under `Sources/SoloLedgerCore/Reports` names either table, and
/// `ReportBatch2ParityTests.testNoProductionSymbolReadsTheLegacyTables` pins exactly
/// that scope — that one directory, non-comment lines, the two literals. It says
/// nothing about the rest of `Sources/`, which reads those tables on purpose and
/// always has: `LegacyLedgerProbe` counts them by name, and the conversion path
/// selects from them through an interpolated table name.
///
/// What that decision costs is stated rather than hidden: for a period whose rows
/// live only in the legacy tables, Electron reports real money and this reports
/// nothing. See ``OperatingCashflowSection`` for why "nothing" is not `{0, 0, 0}`.
enum ReportDispatcher {

    enum Failure: Error, CustomStringConvertible, Equatable {
        case unsupportedLocale(String)

        var description: String {
            switch self {
            case .unsupportedLocale(let l):
                // index.js generate's message, kept recognisable.
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
    struct BatchTwo: Equatable, Sendable {
        let locale: String
        let year: String
        let from: String
        let to: String
        let currency: String
        /// Absent for the US — `us.js` has no such block (not an empty one).
        let taxInclusiveSummary: TaxInclusiveSummary?
        let monthlyBreakdown: [ReportMonth]
        /// Hardcoded `[]` in all five VAT engines; the US warnings are derived from
        /// the estimate layer and are batch 5.
        let warnings: [String]
        let cashflowStatement: CashflowStatement
    }

    /// `index.js generate`, minus the legacy branch.
    ///
    /// - Parameter year: pass explicitly. `index.js year` falls back to
    ///   `new Date().getFullYear()`, which would make output depend on the wall
    ///   clock; the goldens are generated with an explicit year for that reason
    ///   (plan §4.2 item 4) and callers here should do the same.
    static func batchTwo(_ db: SQLiteDatabase,
                                locale explicitLocale: String? = nil,
                                year explicitYear: String? = nil,
                                from explicitFrom: String? = nil,
                                to explicitTo: String? = nil) throws -> BatchTwo {

        // index.js locale — the opts value wins, else the stored setting, else 'CN'.
        let locale = try resolveLocale(db, explicitLocale)

        let year = explicitYear ?? String(Calendar(identifier: .gregorian)
            .component(.year, from: Date()))                       // index.js year
        let from = explicitFrom ?? "\(year)-01-01"                  // index.js from
        let to = explicitTo ?? "\(year)-12-31"                      // index.js generate

        // index.js hasTransactionsTable — the source decision, counted on `date`.
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
            // index.js generate — appended LAST, after the engine has run.
            cashflowStatement: try cashflow(db, source: source, from: from, to: to))
    }

    /// `index.js generate` — the effective accounting locale, or a throw.
    ///
    /// Extracted so that anything else needing the locale (``context(_:locale:source:year:from:to:)``
    /// resolves the income-tax rate against it) asks the SAME question. Note this is
    /// NOT `SettingsStore.accountingLocale()`, which silently answers `.CN` for an
    /// unrecognised value: a ledger stamped "FR" would then be rendered under
    /// Chinese rules with no indication.
    static func resolveLocale(_ db: SQLiteDatabase, _ explicit: String?) throws -> String {
        let locale = explicit ?? ReportSettings.string(db, "accounting_locale", fallback: "CN")
        guard ["CN", "US", "JP", "EU", "KR", "TW"].contains(locale) else {
            throw Failure.unsupportedLocale(locale)      // index.js generate — the `if (!engine)` throw
        }
        return locale
    }

    /// `index.js generate` — the rows, the categories and the settings the engines see.
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
    /// consequence of not mirroring `index.js generate` rather than a bug.
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
        // index.js generate — the categories read is wrapped in a swallowing catch
        // because the table may not exist on an early-schema database.
        let categories = (try? ReportFetch.categories(db, locale: locale)) ?? []

        return ReportContext(
            incomeRows: incomeRows, expenseRows: expenseRows, categories: categories,
            adminExpense: ReportSettings.number(db, "admin_expense_annual", fallback: 0),
            // index.js resolveRate — schemes A and A-4. Decided by whether the ROW exists
            // (A-3) and then by its stored BYTES (A-4), never by the number it would
            // have produced. Both rates go through the same resolution; only China's
            // engine may consume the surcharge.
            incomeTaxRate: ReportSettings.incomeTaxRate(db, locale: locale),
            surchargeRate: ReportSettings.surchargeRate(db, locale: locale),
            currency: ReportSettings.string(db, "currency", fallback: "CNY"),
            year: year, from: from, to: to)
    }

    /// `_cashflow.js computeOperatingCashflow`, transactions branch only.
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
