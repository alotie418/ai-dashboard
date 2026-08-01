import Foundation

/// A READ-ONLY preflight for converting legacy `sales` / `purchases` rows into
/// `transactions`. It decides nothing and writes nothing — it reports what a conversion
/// would meet, so the user can decide before anything is committed.
///
/// ## Why a separate, write-free stage exists at all
///
/// Converting a legacy row does not merely move it: it CHANGES WHAT THE REPORT ENGINES
/// COMPUTE for that period, because `_reportSource.js:15-18` picks the source per period
/// from the transaction count inside it. A period with zero transactions reads the legacy
/// tables; one transaction flips the whole period onto `transactions`, where the legacy
/// `shippingCost` column does not exist and every row now carries a `category_id`. That is
/// an accounting consequence, not a data move, and this app does not take it on the user's
/// behalf. The plan is the screen the decision is made on.
///
/// ## What it must never do
///
/// **Never write.** Not a row, not a setting, not a repair. `LegacyConversionPlanTests`
/// hashes the database file (and its `-wal`) either side of a full preflight and requires
/// both to be byte-identical, so "read-only" is measured rather than asserted in a comment.
///
/// **Never run from the boot chain.** It must be reached from an explicit user action only.
/// Two existing guarantees depend on that: `AppModelBootTests` T3 proves a ledger holding
/// unconverted legacy rows is refused by `seedCurrencyIfProvablyNew`, and `canLoadDemoData`
/// gates on the same `holdsHiddenRecords`. A preflight (or, later, a conversion) that ran
/// during boot would be operating on exactly the ledgers those two are protecting.
/// `testThePreflightIsNotReachableFromTheAppTarget` pins the current state: nothing outside
/// this module names these types at all.
///
/// **Never repair.** A value this file cannot vouch for is REPORTED, never rewritten. The
/// only two actions a caller may offer are "skip these rows and convert the rest" and
/// "cancel" — see ``LegacyRowGrade``.
public enum LegacyTable: String, CaseIterable, Equatable, Sendable {
    case sales
    case purchases

    /// The `transactions.type` a converted row of this table would carry.
    /// `sales` → income, `purchases` → expense — mirrored from
    /// `electron/handlers/migrations.js:117,154`, not reinvented.
    public var transactionType: TransactionType {
        switch self {
        case .sales: return .income
        case .purchases: return .expense
        }
    }

    /// The counterparty column: `sales.customer` / `purchases.supplier`.
    var counterpartyColumn: String {
        switch self {
        case .sales: return "customer"
        case .purchases: return "supplier"
        }
    }

    /// The child line-item table introduced by schema v20, if any.
    var lineItemTable: (table: String, parentColumn: String) {
        switch self {
        case .sales: return ("sales_items", "sale_id")
        case .purchases: return ("purchase_items", "purchase_id")
        }
    }
}

/// Something about ONE legacy row that a conversion cannot carry over without either
/// inventing a value or silently losing one.
///
/// Every case is a fact about the stored bytes, phrased so a screen can list it beside the
/// row's id. None of them is a repair instruction: this app does not know what the right
/// value would have been, and guessing one would be inventing accounting data.
public enum LegacyRowIssue: String, CaseIterable, Equatable, Sendable {
    /// The row's `id` has no reading as text — SQL NULL, or a BLOB that TEXT affinity left
    /// alone.
    ///
    /// `id TEXT PRIMARY KEY` does NOT imply NOT NULL in SQLite: only an INTEGER PRIMARY KEY
    /// gets that treatment, so both storage classes are accepted by the real DDL (measured
    /// against `electron/db/index.js:103` and `SchemaMigrator.swift:88`). Nothing in the
    /// Electron product writes such a row — `sales.js:34` throws `id required` and
    /// `batch.js:47` backfills one — but a hand-edited or damaged ledger can hold one, and
    /// the anti-join returns it, so this stage has to have an answer for it.
    ///
    /// It is `unconvertible` rather than adjudicable: `legacy_migrations.legacy_id` is
    /// `TEXT NOT NULL`, so no converter can ever record such a row as done, and no user
    /// decision changes that.
    case idNotReadableAsText

    /// `date` is absent or empty. The column is `TEXT NOT NULL`, so NULL should be
    /// impossible — but the empty string satisfies NOT NULL and `validateSale` only tests
    /// `!data.date`, so `''` is reachable through a direct write. `transactions.date` is
    /// also NOT NULL, so there is no value to carry and no way to represent absence.
    case dateMissing

    /// `date`'s first ten characters are not a real calendar day in `YYYY-MM-DD` form.
    ///
    /// Ten characters, not the whole string, on purpose: the engines compare dates
    /// LEXICOGRAPHICALLY (`ReportFetch.rowSQL`, mirroring the period window in
    /// `electron/reports/index.js`), so a row stamped `2025-06-15T00:00:00` really does
    /// fall inside a `2025-06-01`…`2025-06-30` window and must NOT be flagged.
    ///
    /// What it catches divides into two kinds, and only one of them is invisible today:
    /// `2024/03/10` sorts ABOVE every `YYYY-` bound (`/` is 0x2F, `-` is 0x2D) and so falls
    /// out of every window, while `2023-02-29` sorts perfectly well INSIDE 2023 and is
    /// counted by the reports right now. Both are flagged, for the same reason: a value
    /// this app cannot read as a day is one it will not carry into a new table while
    /// claiming to know what it means.
    case dateNotACalendarDay

    /// `payment_date` is present but its first ten characters are not a calendar day.
    /// It selects rows for the realized-cash window (`_cashflow.js:52-58`), so a value that
    /// sorts nowhere silently drops the row out of cash flow.
    case paymentDateNotACalendarDay

    /// `due_date` is present but its first ten characters are not a calendar day.
    case dueDateNotACalendarDay

    /// `totalAmount` is absent, or is not a number this app can read.
    ///
    /// `transactions.amount` is `REAL NOT NULL`: there is no way to store "absent", so
    /// carrying this row would mean writing a number the ledger never held. Electron writes
    /// `0` here (`migrations.js:118,155`) and that is exactly the optimistic coercion this
    /// preflight exists to stop.
    case totalAmountNotANumber

    /// `taxAmount` is absent, or is not a number this app can read.
    case taxAmountNotANumber

    /// `taxRate` is absent, or is not a number this app can read.
    case taxRateNotANumber

    /// `paid_amount` is absent, or is not a number this app can read.
    case paidAmountNotANumber

    /// `amountWithoutTax` holds something that is not a number.
    ///
    /// Note what is NOT here: an ABSENT `amountWithoutTax` is fine and is carried as SQL
    /// NULL. That is not a coercion — `transactions.amount_net` is nullable and the engines'
    /// own convention is `amount_net || amount || 0` (`_expenseSplit.js:24`), so NULL means
    /// "fall back to the gross amount" in both places. Only a value that is present and
    /// unreadable is an issue.
    case amountWithoutTaxNotANumber

    /// `payment_status` holds a string that is none of `paid` / `partial` / `unpaid` and is
    /// not empty.
    ///
    /// The column has no CHECK constraint and `batch.js:85,91,150,156` writes
    /// `d.payment_status || 'paid'` straight from a CSV field it never validates, so an
    /// arbitrary string is reachable. Carrying it verbatim would be worse than dropping the
    /// row: `Transaction.from` maps an unknown value to `.paid`, which silently promotes an
    /// unknown state to "collected" and changes both the receivables picture and the
    /// realized-cash window (`payment_status IN ('paid','partial')`).
    case paymentStatusUnrecognized

    /// `customer` / `supplier` is longer than the write path will keep.
    ///
    /// Measured against `Transaction.normalized()` itself rather than restated as a number
    /// here, so the two cannot drift apart — see ``LegacyConversionPlan/wouldTruncateCounterparty(_:)``.
    case counterpartyWouldBeTruncated
}

/// What a conversion may do with one legacy row.
///
/// There is deliberately no fourth case for "repair it". `needsAdjudication` is not a
/// request for this app to fix anything; it is a request for the USER to accept that the
/// row will be left behind.
public enum LegacyRowGrade: String, CaseIterable, Equatable, Sendable {
    /// Every value carries over without inventing or losing one.
    case convertible
    /// Carrying it over would require inventing a value or silently losing one. The user
    /// may skip these rows and convert the rest, or cancel. Nothing else.
    case needsAdjudication
    /// There is no representable target value at all, so no user choice can rescue it.
    case unconvertible
}

/// One unconverted legacy row, graded.
public struct LegacyConversionRow: Equatable, Sendable {
    public let table: LegacyTable
    /// The row's `id` as text, or nil when it has no reading as one — see
    /// ``LegacyRowIssue/idNotReadableAsText``. Two such rows are indistinguishable here,
    /// and that is honest rather than sloppy: they are indistinguishable to any converter
    /// too, because neither can ever be recorded in `legacy_migrations`.
    public let id: String?
    /// `date` exactly as stored (nil when the column is SQL NULL), so a screen can show the
    /// offending value rather than a description of it.
    public let storedDate: String?
    /// Sorted by `rawValue`, so two runs over the same ledger compare equal.
    public let issues: [LegacyRowIssue]

    /// The two `unconvertible` issues are the ones where the TARGET column cannot represent
    /// the answer at all — `transactions.date` and `legacy_migrations.legacy_id` are both
    /// `TEXT NOT NULL` — so no user decision can rescue the row.
    public var grade: LegacyRowGrade {
        if issues.contains(.dateMissing) || issues.contains(.idNotReadableAsText) {
            return .unconvertible
        }
        return issues.isEmpty ? .convertible : .needsAdjudication
    }

    public init(table: LegacyTable, id: String?, storedDate: String?, issues: [LegacyRowIssue]) {
        self.table = table
        self.id = id
        self.storedDate = storedDate
        self.issues = issues.sorted { $0.rawValue < $1.rawValue }
    }
}

/// What converting would mean for ONE calendar year's report.
///
/// The year is the one a convertible row's `date` starts with. Two facts are reported and
/// nothing is concluded from them:
public struct LegacyYearOutlook: Equatable, Sendable {
    /// `YYYY`, from the first four characters of a convertible row's stored date.
    public let year: String
    /// How many `transactions` rows already fall in `[year-01-01, year-12-31]`. **Zero means
    /// this year's report is refused today** (`ReportBlocker.legacySourceUnavailable`) and
    /// will start computing once anything is converted into it.
    public let existingTransactionCount: Int
    /// The currency codes the period already holds, by the SAME two-window union
    /// `ReportBuilder` gates on. Sorted.
    public let existingCurrencies: [String]
    /// True when the period already holds a currency other than the one conversion would
    /// stamp — so after conversion the period holds two, and the report for that year turns
    /// from whatever it shows today into `ReportBlocker.multipleCurrenciesInPeriod`.
    ///
    /// **This is an UPPER BOUND and never under-reports.** A convertible row whose date
    /// carries a time suffix on 31 December (`2024-12-31T08:00`) sorts ABOVE the period's
    /// `to` bound and would not actually join the period, so the flag can be true for a year
    /// conversion leaves alone. It cannot be false for a year conversion breaks, which is
    /// the direction that matters.
    ///
    /// The opposite blocker, `currencyMismatch`, is NOT modelled because it is unreachable
    /// here: it fires only when the period holds exactly one currency and that one differs
    /// from the stored setting, and every converted row carries the stored setting — so the
    /// stored code is in the set whenever conversion added anything, leaving only "one code,
    /// and it matches" or "more than one".
    public let wouldHoldASecondCurrency: Bool

    public init(year: String, existingTransactionCount: Int,
                existingCurrencies: [String], wouldHoldASecondCurrency: Bool) {
        self.year = year
        self.existingTransactionCount = existingTransactionCount
        self.existingCurrencies = existingCurrencies
        self.wouldHoldASecondCurrency = wouldHoldASecondCurrency
    }
}

/// A whole-batch precondition that stops a conversion before any row is even graded.
///
/// Both are about the two settings a converted row cannot be written without: the regime
/// (which decides the category set the user picks from) and the currency (which is stamped
/// on every row, because the legacy tables have no currency column at all).
public enum LegacyConversionBlocker: Equatable, Sendable {
    case accountingLocaleNotConfigured
    case accountingLocaleInvalid(storedText: String)
    case currencyNotConfigured
    /// Carries the stored text byte for byte so a screen can show what is actually there —
    /// the same treatment `ReportBlocker.currencyInvalid` gives it.
    case currencyInvalid(storedText: String)
}

/// The complete, write-free answer.
public struct LegacyConversionPlan: Equatable, Sendable {
    /// The regime the ledger claims, by the rule the report engines apply.
    public let accountingLocale: AccountingLocale
    /// The currency every converted row would carry.
    public let currency: String
    /// Every UNCONVERTED legacy row, graded. Ordered by `(date, id)` within each table,
    /// sales before purchases, so the list is stable across runs.
    public let rows: [LegacyConversionRow]
    /// How many legacy HEADERS in the work set have at least one `sales_items` /
    /// `purchase_items` child. Converting one collapses it into a single transaction — the
    /// header's money columns are already the line sum, so no money is lost, but the
    /// per-line breakdown becomes unreachable. The child rows themselves are left untouched.
    ///
    /// Counted over the WHOLE work set, so it is an UPPER BOUND on the breakdowns a
    /// conversion would actually collapse: a header that is also graded `needsAdjudication`
    /// is counted here and would then be skipped. That is the right bound for a preflight,
    /// which is read before the user has chosen anything — including whether to go ahead at
    /// all — and it errs towards disclosing a loss rather than towards hiding one.
    public let headersWithLineItems: Int
    /// One entry per calendar year a convertible row would land in, ordered by year.
    public let yearOutlook: [LegacyYearOutlook]

    public init(accountingLocale: AccountingLocale, currency: String,
                rows: [LegacyConversionRow], headersWithLineItems: Int,
                yearOutlook: [LegacyYearOutlook]) {
        self.accountingLocale = accountingLocale
        self.currency = currency
        self.rows = rows
        self.headersWithLineItems = headersWithLineItems
        self.yearOutlook = yearOutlook
    }

    public func rows(graded grade: LegacyRowGrade) -> [LegacyConversionRow] {
        rows.filter { $0.grade == grade }
    }

    public var convertibleCount: Int { rows(graded: .convertible).count }
    public var needsAdjudicationCount: Int { rows(graded: .needsAdjudication).count }
    public var unconvertibleCount: Int { rows(graded: .unconvertible).count }

    /// True when there is nothing to convert — either the ledger has no unconverted legacy
    /// rows at all, or none of them can be carried. Distinct from a blocker: the ledger is
    /// fine, there is simply no work.
    public var hasNothingToConvert: Bool { convertibleCount == 0 }
}

/// Either the whole batch is refused, or there is a plan. A caller cannot reach the plan
/// without having handled the refusal.
public enum LegacyConversionPreflight: Equatable, Sendable {
    case blocked(LegacyConversionBlocker)
    case plan(LegacyConversionPlan)
}

// MARK: - The grading rules, as pure functions

extension LegacyConversionPlan {

    /// How a REAL-affinity column's stored value reads.
    ///
    /// The distinction that matters is the STORAGE CLASS, not what Swift's `Double(_:)`
    /// would make of the text. SQLite applies REAL affinity on write, so text that looks
    /// like a number is already a number by the time it is stored — measured:
    ///
    ///     '1000'   → real 1000.0        '1,000'  → text (kept)
    ///     ' 42 '   → real 42.0          '0x1388' → text (kept)
    ///     '1e3'    → real 1000.0        'abc'    → text (kept)
    ///
    /// So anything still stored as TEXT in one of these columns is something SQLite ITSELF
    /// refused to read as a number, and this app must not out-read it. `0x1388` is the case
    /// that makes the rule load-bearing rather than academic: Swift's `Double("0x1388")` is
    /// 5000, and no report path would ever see that 5000.
    ///
    /// `notFinite` is reachable and separate: `9e999` stores and reads back as `Inf` (SQLite
    /// coerces NaN to NULL on write, so only the infinities survive), and
    /// `Transaction.normalized()` would silently turn it into 0.
    enum NumericField: Equatable {
        case usable(Double)
        case absent
        case notANumber
        case notFinite
    }

    static func numericField(_ value: SQLiteValue) -> NumericField {
        switch value {
        case .null: return .absent
        case .integer(let i): return .usable(Double(i))
        case .real(let d): return d.isFinite ? .usable(d) : .notFinite
        case .text, .blob: return .notANumber
        }
    }

    static func isUsable(_ field: NumericField) -> Bool {
        if case .usable = field { return true }
        return false
    }

    /// `payment_status`, by the ruling: NULL or empty carries over as `unpaid` (the column
    /// DEFAULT, not Electron's optimistic `paid`); the three recognised values carry over
    /// verbatim; anything else is an issue.
    ///
    /// Whitespace is NOT trimmed. A value of `"  "` is not "empty" — it is a string nobody
    /// can account for, and normalising it here would be the silent repair this whole stage
    /// exists to refuse.
    static func paymentStatusIsUnrecognized(_ value: SQLiteValue) -> Bool {
        switch value {
        case .null: return false
        case .text(let s):
            if s.isEmpty { return false }
            return PaymentStatus(rawValue: s) == nil
        case .integer, .real, .blob: return true
        }
    }

    /// True when the first ten characters of `stored` are a real calendar day written
    /// `YYYY-MM-DD`.
    ///
    /// ## Why this is plain arithmetic and touches no `Date`, `Calendar` or `TimeZone`
    ///
    /// The obvious implementation — parse the ten characters with the app's `DateFormat`
    /// and require that formatting the result reproduces them — was written first, and it
    /// is wrong in a way that only shows up on some machines. `DateFormatter` cannot
    /// produce a `Date` for a day its timezone SKIPPED, and whole calendar days really have
    /// been skipped: Kiritimati jumped from 1994-12-30 to 1995-01-01 and Samoa from
    /// 2011-12-29 to 2011-12-31 when they crossed the date line. Measured, same binary,
    /// only `TZ` changed:
    ///
    ///     TZ=UTC                 1994-12-31 accepted   2011-12-30 accepted
    ///     TZ=Pacific/Kiritimati  1994-12-31 REJECTED   2011-12-30 accepted
    ///     TZ=Pacific/Apia        1994-12-31 accepted   2011-12-30 REJECTED
    ///
    /// A perfectly ordinary legacy row would have been graded `dateNotACalendarDay` on one
    /// user's Mac and `convertible` on another's, and the only thing this stage offers a
    /// flagged row is "skip it". Whether a ledger's data can be carried must not depend on
    /// where the machine thinks it is, so the check answers the question directly instead
    /// of asking a calendar that has an opinion about local midnight.
    ///
    /// The rule remains "the first TEN characters", not the whole string: the engines
    /// compare dates LEXICOGRAPHICALLY (`ReportFetch.rowSQL`, mirroring the period window
    /// in `electron/reports/index.js`), so `2025-06-15T00:00:00` really does fall inside a
    /// `2025-06-01`…`2025-06-30` window and must not be flagged.
    ///
    /// `0000-01-01` is accepted. It is a well-formed day in the proleptic Gregorian
    /// calendar and it sorts like one; the `DateFormatter` version rejected it only as a
    /// side effect of formatting year 0 back as `0001`, which was never a decision.
    static func isCalendarDayPrefix(_ stored: String) -> Bool {
        let head = Array(stored.prefix(10))
        guard head.count == 10, head[4] == "-", head[7] == "-" else { return false }
        // ASCII-only: `Character("１").wholeNumberValue` is 1, so without this guard the
        // full-width `１９９９-０１-０１` would read as a date the engines can never match.
        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for index in range {
                guard head[index].isASCII, let digit = head[index].wholeNumberValue,
                      head[index].isNumber else { return nil }
                value = value * 10 + digit
            }
            return value
        }
        guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
              (1...12).contains(month), day >= 1, day <= daysInMonth(year: year, month: month)
        else { return false }
        return true
    }

    static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        case 2: return isLeapYear(year) ? 29 : 28
        default: return 0
        }
    }

    static func isLeapYear(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    /// True when the write path would not keep this counterparty whole.
    ///
    /// The cap is MEASURED against the function that would do the truncating rather than
    /// restated as a literal, so a future change to `Transaction.normalized()` moves this
    /// check with it instead of leaving a stale number behind. Only `counterparty` can
    /// differ for the value built here: the other clamped fields are left at their defaults,
    /// which are already inside their own limits.
    static func wouldTruncateCounterparty(_ stored: String) -> Bool {
        Transaction(counterparty: stored).normalized().counterparty != stored
    }

    /// One legacy row's stored columns, straight from SQLite with no coercion applied —
    /// `id` included, because whether it has a text reading at all is one of the questions.
    struct StoredRow: Equatable {
        var id: SQLiteValue = .null
        var date: SQLiteValue = .null
        var counterparty: SQLiteValue = .null
        var totalAmount: SQLiteValue = .null
        var amountWithoutTax: SQLiteValue = .null
        var taxAmount: SQLiteValue = .null
        var taxRate: SQLiteValue = .null
        var paidAmount: SQLiteValue = .null
        var paymentStatus: SQLiteValue = .null
        var paymentDate: SQLiteValue = .null
        var dueDate: SQLiteValue = .null
    }

    /// The whole per-row rule set, pure, so it can be proved against synthetic values as
    /// well as against real rows.
    static func issues(in row: StoredRow) -> [LegacyRowIssue] {
        var found: [LegacyRowIssue] = []

        if row.id.stringValue == nil { found.append(.idNotReadableAsText) }

        // — the date, and the two optional dates that select report windows —
        //
        // A value with no text reading at all (SQL NULL, or a BLOB that TEXT affinity left
        // alone) is `dateMissing` rather than `dateNotACalendarDay`: `transactions.date` is
        // `TEXT NOT NULL`, so the question is not "is this day real" but "is there anything
        // to carry", and the answer decides the GRADE, not just the label.
        let storedDate = row.date.stringValue ?? ""
        if storedDate.isEmpty {
            found.append(.dateMissing)
        } else if !isCalendarDayPrefix(storedDate) {
            found.append(.dateNotACalendarDay)
        }
        for (value, issue) in [(row.paymentDate, LegacyRowIssue.paymentDateNotACalendarDay),
                               (row.dueDate, LegacyRowIssue.dueDateNotACalendarDay)] {
            guard let stored = value.stringValue, !stored.isEmpty else { continue }
            if !isCalendarDayPrefix(stored) { found.append(issue) }
        }

        // — the four columns Electron coerces with `|| 0`: `totalAmount`, `taxAmount`,
        //   `taxRate`, `paid_amount` (`migrations.js:118,121,155,158`). Absent or
        //   unreadable, all four are an issue — writing 0 would state a number the ledger
        //   never held. `amountWithoutTax` is deliberately NOT in this family, and the line
        //   is Electron's own: it is the one money column `migrations.js` guards with
        //   `|| null` rather than `|| 0`, because `transactions.amount_net` can represent
        //   absence and the other four cannot.
        for (value, issue) in [(row.totalAmount, LegacyRowIssue.totalAmountNotANumber),
                               (row.taxAmount, LegacyRowIssue.taxAmountNotANumber),
                               (row.taxRate, LegacyRowIssue.taxRateNotANumber),
                               (row.paidAmount, LegacyRowIssue.paidAmountNotANumber)] {
            if !isUsable(numericField(value)) { found.append(issue) }
        }
        // — and the one it guards with `|| null`, where absence is representable —
        switch numericField(row.amountWithoutTax) {
        case .notANumber, .notFinite: found.append(.amountWithoutTaxNotANumber)
        case .usable, .absent: break
        }

        if paymentStatusIsUnrecognized(row.paymentStatus) {
            found.append(.paymentStatusUnrecognized)
        }
        if let name = row.counterparty.stringValue, wouldTruncateCounterparty(name) {
            found.append(.counterpartyWouldBeTruncated)
        }
        return found.sorted { $0.rawValue < $1.rawValue }
    }
}

// MARK: - The scan

extension LedgerStore {

    /// Grade every unconverted legacy row and report what converting them would mean.
    /// Performs NO writes of any kind.
    ///
    /// The whole scan runs inside one read transaction. That is not tidiness: the row list,
    /// the line-item counts and the per-year currency sets are eight-odd statements that must
    /// describe ONE ledger, and the Electron app may be writing between any two of them.
    public func legacyConversionPreflight() throws -> LegacyConversionPreflight {
        try db.readSnapshot {
            // ── 1. The two settings a converted row cannot be written without ────────────
            //
            // Both are classified by the rule the REPORT ENGINES apply, not by the lenient
            // display readers, and the reason is the asymmetry P4c-1 was spent removing: a
            // row holding a byte-order mark reads as a perfectly good `"CNY"` through
            // `SettingsStore.string` (JSONSerialization eats U+FEFF) and is refused by the
            // engines (JSON.parse does not). Converting under the lenient reading would
            // stamp a currency the app itself will not stand behind, and every converted
            // period would then be blocked on the very setting the conversion trusted.
            switch try settings.accountingLocaleState() {
            case .absent:
                return .blocked(.accountingLocaleNotConfigured)
            case .unreadable(let storedText):
                return .blocked(.accountingLocaleInvalid(storedText: storedText))
            case .configured(let locale):
                // `rowExists` and `rawValue` are two separate questions, asked in the same
                // order and answered by the same three functions that
                // `ReportBuilder.resolveCurrency` uses. That function is `private static`
                // and cannot be called from here, so the agreement rests on sharing the
                // PRIMITIVES, not on sharing the routine — the parser is one
                // (`ReportSettings.jsonFragment`), the sequence is copied. Anything that
                // changes the rule must change `jsonFragment`, which moves both.
                guard ReportSettings.rowExists(db, SettingsStore.Key.currency) else {
                    return .blocked(.currencyNotConfigured)
                }
                let raw = ReportSettings.rawValue(db, SettingsStore.Key.currency) ?? ""
                guard case .string(let currency)? = ReportSettings.jsonFragment(raw),
                      !currency.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return .blocked(.currencyInvalid(storedText: raw))
                }
                return .plan(try scanLegacyRows(locale: locale, currency: currency))
            }
        }
    }

    private func scanLegacyRows(locale: AccountingLocale,
                                currency: String) throws -> LegacyConversionPlan {
        let mappingExists = try legacyTableExists("legacy_migrations")
        var rows: [LegacyConversionRow] = []
        var headersWithLineItems = 0

        for table in LegacyTable.allCases where try legacyTableExists(table.rawValue) {
            rows += try gradedRows(in: table, unmappedOnly: mappingExists)
            headersWithLineItems += try lineItemHeaderCount(in: table, unmappedOnly: mappingExists)
        }

        return LegacyConversionPlan(
            accountingLocale: locale,
            currency: currency,
            rows: rows,
            headersWithLineItems: headersWithLineItems,
            yearOutlook: try yearOutlook(for: rows, currency: currency))
    }

    /// The work set is picked by the SAME anti-join the Electron converter uses to pick its
    /// own (`migrations.js:98-102,138-142`) and `LegacyLedgerProbe` uses to count it, so
    /// "rows a conversion would carry" is one question with one answer across all three.
    ///
    /// When `legacy_migrations` is absent there is nothing to anti-join against and every
    /// row is unconverted — the same fallback the probe takes.
    private func gradedRows(in table: LegacyTable,
                            unmappedOnly: Bool) throws -> [LegacyConversionRow] {
        // Table and column names are FIXED literals derived from a closed enum; nothing here
        // is interpolated from stored data.
        let source = table.rawValue
        let antiJoin = unmappedOnly
            ? """
              LEFT JOIN legacy_migrations m ON m.legacy_table = '\(source)' AND m.legacy_id = r.id
               WHERE m.id IS NULL
              """
            : ""
        let sql = """
            SELECT r.id AS id, r.date AS date, r.\(table.counterpartyColumn) AS counterparty,
                   r.totalAmount AS totalAmount, r.amountWithoutTax AS amountWithoutTax,
                   r.taxAmount AS taxAmount, r.taxRate AS taxRate,
                   r.paid_amount AS paid_amount, r.payment_status AS payment_status,
                   r.payment_date AS payment_date, r.due_date AS due_date
              FROM \(source) r
            \(antiJoin)
             ORDER BY r.date, r.id
            """
        // `map`, never `compactMap`. A row the anti-join returned is a row a conversion
        // would have to face, and dropping one here would put it in NONE of the three
        // grades — the single outcome this whole stage exists to make impossible, and the
        // one the probe would keep counting forever afterwards. A row whose `id` has no
        // text reading is therefore GRADED (unconvertible), not skipped.
        return try db.query(sql).map { row in
            let stored = LegacyConversionPlan.StoredRow(
                id: row["id"],
                date: row["date"],
                counterparty: row["counterparty"],
                totalAmount: row["totalAmount"],
                amountWithoutTax: row["amountWithoutTax"],
                taxAmount: row["taxAmount"],
                taxRate: row["taxRate"],
                paidAmount: row["paid_amount"],
                paymentStatus: row["payment_status"],
                paymentDate: row["payment_date"],
                dueDate: row["due_date"])
            return LegacyConversionRow(table: table, id: row.string("id"),
                                       storedDate: row.string("date"),
                                       issues: LegacyConversionPlan.issues(in: stored))
        }
    }

    /// How many headers in the work set carry line items. Counted over the same work set, so
    /// a header that was converted long ago is not reported as something about to be lost.
    private func lineItemHeaderCount(in table: LegacyTable, unmappedOnly: Bool) throws -> Int {
        let child = table.lineItemTable
        guard try legacyTableExists(child.table) else { return 0 }
        let source = table.rawValue
        let antiJoin = unmappedOnly
            ? """
              LEFT JOIN legacy_migrations m ON m.legacy_table = '\(source)' AND m.legacy_id = r.id
               WHERE m.id IS NULL
              """
            : ""
        let sql = """
            SELECT COUNT(DISTINCT r.id) AS c
              FROM \(source) r
              JOIN \(child.table) i ON i.\(child.parentColumn) = r.id
            \(antiJoin)
            """
        return try db.query(sql).first?.int("c") ?? 0
    }

    /// One outlook per calendar year a CONVERTIBLE row would land in.
    ///
    /// Rows that need adjudication are excluded on purpose: the only offer a caller may make
    /// about them is "skip", so they cannot land anywhere and must not colour the forecast.
    private func yearOutlook(for rows: [LegacyConversionRow],
                             currency: String) throws -> [LegacyYearOutlook] {
        let years = Set(rows.filter { $0.grade == .convertible }
            .compactMap { $0.storedDate.map { String($0.prefix(4)) } })
        return try years.sorted().map { year in
            let from = "\(year)-01-01", to = "\(year)-12-31"
            let count = try db.query(
                "SELECT COUNT(*) AS c FROM transactions WHERE date >= ? AND date <= ?",
                [.text(from), .text(to)]).first?.int("c") ?? 0
            // The two windows `ReportBuilder.periodCurrencySet` unions, word for word: the
            // P&L window and the realized-cash window. A set built from anything else would
            // gate on one question and forecast another.
            let codes = try db.query("""
                SELECT DISTINCT currency FROM transactions
                 WHERE type IN ('income','expense') AND date >= ? AND date <= ?
                UNION
                SELECT DISTINCT currency FROM transactions
                 WHERE payment_status IN ('paid','partial')
                   AND COALESCE(payment_date, date) >= ? AND COALESCE(payment_date, date) <= ?
                """, [.text(from), .text(to), .text(from), .text(to)])
                .compactMap { $0.string("currency") }.sorted()
            return LegacyYearOutlook(year: year,
                                     existingTransactionCount: count,
                                     existingCurrencies: codes,
                                     wouldHoldASecondCurrency: codes.contains { $0 != currency })
        }
    }

    private func legacyTableExists(_ name: String) throws -> Bool {
        try db.query("SELECT name FROM sqlite_master WHERE type='table' AND name = ?",
                     [.text(name)]).isEmpty == false
    }
}
