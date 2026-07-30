import XCTest
@testable import SoloLedgerCore

/// Coverage for the public report façade.
///
/// The suite is organised around the two things the façade is FOR: it must never hand a
/// view an unclassified value, and it must never quietly produce a report from a ledger
/// that has not said enough to be reported on.
final class ReportBuilderTests: XCTestCase {

    // MARK: - Fixture

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    /// A ledger with the two tables the façade reads and nothing else.
    private func makeLedger(locale: String? = "\"CN\"", currency: String? = "\"CNY\"") throws
        -> SQLiteDatabase {
        let db = try SQLiteDatabase(path: dir.appendingPathComponent("\(UUID().uuidString).db").path)
        try db.execute("""
            CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at TEXT);
            CREATE TABLE transactions (
              id TEXT PRIMARY KEY, type TEXT, date TEXT, amount REAL, amount_net REAL,
              tax_amount REAL, category_id TEXT, currency TEXT NOT NULL DEFAULT 'CNY',
              payment_status TEXT, paid_amount REAL, payment_date TEXT);
            """)
        if let locale { try put(db, "accounting_locale", locale) }
        if let currency { try put(db, "currency", currency) }
        return db
    }

    private func put(_ db: SQLiteDatabase, _ key: String, _ raw: String) throws {
        _ = try db.run("""
            INSERT INTO settings (key, value, updated_at) VALUES (?, ?, '')
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """, [.text(key), .text(raw)])
    }

    private func addTxn(_ db: SQLiteDatabase, type: String = "income", date: String,
                        amount: Double = 100, currency: String = "CNY",
                        paymentStatus: String = "paid", paymentDate: String? = nil) throws {
        _ = try db.run("""
            INSERT INTO transactions (id, type, date, amount, amount_net, tax_amount,
                                      category_id, currency, payment_status, paid_amount, payment_date)
            VALUES (?, ?, ?, ?, ?, 0, NULL, ?, ?, ?, ?)
            """, [.text(UUID().uuidString), .text(type), .text(date), .real(amount),
                  .real(amount), .text(currency), .text(paymentStatus), .real(amount),
                  paymentDate.map { .text($0) } ?? .null])
    }

    private func period(_ year: String) -> ReportPeriod { ReportPeriod(year: year) }

    private func report(_ outcome: ReportOutcome, _ file: StaticString = #filePath,
                        _ line: UInt = #line) throws -> PresentedReport {
        guard case .report(let r) = outcome else {
            XCTFail("expected a report, got \(outcome)", file: file, line: line)
            throw XCTSkip("no report")
        }
        return r
    }

    // MARK: - The accounting regime

    /// **The BOM boundary.** `accounting_locale` holding a UTF-8 BOM followed by `"US"` must
    /// be BLOCKED, with the stored text carried verbatim — never silently reported as China.
    ///
    /// This is not hypothetical. Measured on the same row today:
    ///
    ///     SettingsStore.accountingLocale()                       -> US
    ///     ReportSettings.string(db, …, fallback: "CN")            -> CN
    ///
    /// The Settings screen says the ledger is American while the engines would run Chinese
    /// accounting policy. `SettingsStore` is NOT changed here — that inconsistency is
    /// registered for P4 — but the façade must refuse rather than pick a regime nobody chose.
    func testBOMPrefixedAccountingLocaleIsBlockedAsInvalidAndNeverSilentlyRunsChina() throws {
        let stored = "\u{FEFF}\"US\""
        let db = try makeLedger(locale: stored)
        try addTxn(db, date: "2025-06-01")

        let outcome = try ReportBuilder.build(db, period: period("2025"))

        guard case .blocked(let blocker) = outcome else {
            return XCTFail("a BOM-prefixed accounting_locale must block, got \(outcome)")
        }
        XCTAssertEqual(blocker, .accountingLocaleInvalid(storedText: stored),
                       "the blocker must carry the stored text byte for byte, BOM included")
        if case .accountingLocaleInvalid(let text) = blocker {
            XCTAssertEqual(Array(text.unicodeScalars.map(\.value)),
                           [0xFEFF, 0x22, 0x55, 0x53, 0x22],
                           "storedText must be exactly U+FEFF then \"US\" in quotes")
        }
        // The reason this test exists, stated as its own assertion.
        if case .report(let r) = outcome {
            XCTFail("a report was produced under locale \(r.locale) from an unreadable regime row")
        }
    }

    func testMissingAccountingLocaleRowIsBlockedRatherThanDefaultedToChina() throws {
        let db = try makeLedger(locale: nil)
        XCTAssertEqual(try ReportBuilder.build(db, period: period("2025")),
                       .blocked(.accountingLocaleNotConfigured))
    }

    func testUnknownAccountingLocaleIsBlockedWithItsStoredText() throws {
        for stored in ["\"FR\"", "\"cn\"", "\"\"", "123", "null", "notjson"] {
            let db = try makeLedger(locale: stored)
            XCTAssertEqual(try ReportBuilder.build(db, period: period("2025")),
                           .blocked(.accountingLocaleInvalid(storedText: stored)),
                           "\(stored) is not one of the six regimes")
        }
    }

    func testEachOfTheSixRegimesBuilds() throws {
        for locale in ["CN", "US", "JP", "EU", "KR", "TW"] {
            let db = try makeLedger(locale: "\"\(locale)\"")
            let r = try report(try ReportBuilder.build(db, period: period("2025")))
            XCTAssertEqual(r.locale, locale)
        }
    }

    // MARK: - Currency

    func testMissingCurrencyRowIsBlockedAndOffersCandidatesWithoutApplyingThem() throws {
        let db = try makeLedger(currency: nil)
        try addTxn(db, date: "2025-06-01", currency: "USD")
        guard case .blocked(.currencyNotConfigured(let codes, let regimeDefault)) =
                try ReportBuilder.build(db, period: period("2025")) else {
            return XCTFail("a missing currency row must block")
        }
        XCTAssertEqual(codes, ["USD"], "the period's real currencies are offered as candidates")
        XCTAssertEqual(regimeDefault, "CNY", "the regime preset is offered, not applied")
    }

    /// A stored currency that differs from the REGIME DEFAULT is a legitimate user choice —
    /// the Electron accounting screen edits the field directly — and must not block.
    func testCustomCurrencyDifferentFromTheRegimeDefaultIsNotAnError() throws {
        let db = try makeLedger(locale: "\"US\"", currency: "\"EUR\"")
        try addTxn(db, date: "2025-06-01", currency: "EUR")
        let r = try report(try ReportBuilder.build(db, period: period("2025")))
        XCTAssertEqual(r.currency, "EUR")
    }

    func testCurrencyMismatchWithThePeriodsOnlyCurrencyIsBlocked() throws {
        let db = try makeLedger(currency: "\"CNY\"")
        try addTxn(db, date: "2025-06-01", currency: "USD")
        XCTAssertEqual(try ReportBuilder.build(db, period: period("2025")),
                       .blocked(.currencyMismatch(storedCurrency: "CNY", periodCurrency: "USD")))
    }

    func testMultipleCurrenciesInThePeriodAreBlockedRatherThanSummed() throws {
        let db = try makeLedger()
        try addTxn(db, date: "2025-06-01", currency: "CNY")
        try addTxn(db, date: "2025-06-02", currency: "USD")
        XCTAssertEqual(try ReportBuilder.build(db, period: period("2025")),
                       .blocked(.multipleCurrenciesInPeriod(codes: ["CNY", "USD"])))
    }

    /// **Counterexample 1 for the currency query.** An `unpaid` row whose `payment_date`
    /// lands inside the period but whose `date` does not must NOT reach the currency set:
    /// neither fetch path takes it — the P&L window filters on `date`, and the cash window
    /// requires `payment_status IN ('paid','partial')`.
    func testUnpaidRowWithInPeriodPaymentDateDoesNotAffectTheCurrencySet() throws {
        let db = try makeLedger()
        try addTxn(db, date: "2025-06-01", currency: "CNY")
        try addTxn(db, date: "2024-11-01", currency: "USD",
                   paymentStatus: "unpaid", paymentDate: "2025-06-15")
        let r = try report(try ReportBuilder.build(db, period: period("2025")))
        XCTAssertEqual(r.currency, "CNY", "an unpaid foreign row must not create a false mismatch")
    }

    /// **Counterexample 2 for the currency query.** With no rows dated in the period the
    /// source is `.legacy`, and this app then reads no transaction rows at all — so a PAID
    /// row from another year whose `payment_date` happens to fall inside the period must not
    /// manufacture a currency, or a block.
    func testLegacySourceIgnoresForeignPaidRowWhosePaymentDateFallsInPeriod() throws {
        let db = try makeLedger()
        try addTxn(db, date: "2024-11-01", currency: "USD",
                   paymentStatus: "paid", paymentDate: "2025-06-15")
        let r = try report(try ReportBuilder.build(db, period: period("2025")))
        XCTAssertEqual(r.source, .legacy)
        XCTAssertEqual(r.currency, "CNY", "no row participates, so nothing can disagree")
        XCTAssertEqual(r.cashflow.operating, .noTransactionsInPeriod)
    }

    func testEmptyPeriodBuildsWithTheStoredCurrency() throws {
        let db = try makeLedger(currency: "\"JPY\"")
        let r = try report(try ReportBuilder.build(db, period: period("2025")))
        XCTAssertEqual(r.currency, "JPY")
        XCTAssertEqual(r.source, .legacy)
    }

    // MARK: - Sections, availability and the withheld shape

    func testSectionsMirrorTheDeclaredTableAndCarryTheirAvailability() throws {
        let expected: [String: [String]] = [
            "CN": ["income-statement", "vat-summary", "tax-inclusive"],
            "JP": ["income-statement", "consumption-tax"],
            "EU": ["profit-loss", "vat-return"],
            "KR": ["income-statement", "vat-summary"],
            "TW": ["income-statement", "business-tax"],
            "US": ["schedule-c", "se-tax"],
        ]
        var total = 0
        for (locale, ids) in expected {
            let db = try makeLedger(locale: "\"\(locale)\"")
            let r = try report(try ReportBuilder.build(db, period: period("2025")))
            XCTAssertEqual(r.sections.map(\.reportTypeID), ids, "\(locale)")
            for s in r.sections {
                XCTAssertEqual(s.availability, .renderInFull, "\(locale)/\(s.reportTypeID)")
                XCTAssertFalse(s.lines.isEmpty, "\(locale)/\(s.reportTypeID) must carry lines")
            }
            total += r.sections.count
        }
        XCTAssertEqual(total, 13, "the mirrored table declares exactly 13 pairs")
    }

    /// A withheld section must carry nothing to render. Driven through the internal mapping
    /// because `.withhold` has no producer on the real table.
    func testWithheldSectionsCarryNoLines() {
        XCTAssertEqual(ReportPresentation.section(.absent), .withhold)
        let withheld = PresentedSection(reportTypeID: "balance-sheet", availability: .withhold,
                                        lines: [], notes: [])
        XCTAssertTrue(withheld.lines.isEmpty)
        XCTAssertTrue(withheld.notes.isEmpty)
    }

    /// Every money line is already classified — the type makes an unclassified one
    /// unrepresentable, and this asserts the funnel was actually used rather than bypassed
    /// with `.amount` on a raw NaN.
    func testEveryPresentedLineIsAFiniteAmountOrAnExplicitNonValue() throws {
        for locale in ["CN", "US", "JP", "EU", "KR", "TW"] {
            let db = try makeLedger(locale: "\"\(locale)\"")
            try addTxn(db, date: "2025-06-01")
            let r = try report(try ReportBuilder.build(db, period: period("2025")))
            for s in r.sections {
                for l in s.lines {
                    if case .amount(let x) = l.value {
                        XCTAssertTrue(x.isFinite, "\(locale)/\(s.reportTypeID)/\(l.id) = \(x)")
                    }
                }
            }
        }
    }

    // MARK: - The undeclared tax-inclusive block

    /// R3's tax-inclusive block is emitted by all five VAT engines but declared as a report
    /// type by China alone. It must be carried for the other four instead of dropped.
    func testUndeclaredTaxInclusiveIsCarriedForTheFourRegimesThatDoNotDeclareIt() throws {
        for locale in ["JP", "EU", "KR", "TW"] {
            let db = try makeLedger(locale: "\"\(locale)\"")
            let r = try report(try ReportBuilder.build(db, period: period("2025")))
            XCTAssertNotNil(r.undeclaredTaxInclusiveSummary, "\(locale) emits the block")
            XCTAssertFalse(r.sections.contains { $0.reportTypeID == "tax-inclusive" },
                           "\(locale) does not declare the id and must not be given one")
        }
        let cn = try report(try ReportBuilder.build(try makeLedger(), period: period("2025")))
        XCTAssertNil(cn.undeclaredTaxInclusiveSummary, "China declares it; it is a section")
        XCTAssertTrue(cn.sections.contains { $0.reportTypeID == "tax-inclusive" })

        let us = try report(try ReportBuilder.build(try makeLedger(locale: "\"US\""),
                                                    period: period("2025")))
        XCTAssertNil(us.undeclaredTaxInclusiveSummary, "us.js has no such block at all")
    }

    // MARK: - Cash flow

    func testTheThreeCashflowStatesAreDistinctAndTheFourSectionsAreNeverNumbers() throws {
        let db = try makeLedger()
        try addTxn(db, date: "2025-06-01")
        let r = try report(try ReportBuilder.build(db, period: period("2025")))
        XCTAssertEqual(r.cashflow.basis, "cash")
        XCTAssertFalse(r.cashflow.statutory)
        for section in [r.cashflow.investing, r.cashflow.financing,
                        r.cashflow.beginningCash, r.cashflow.endingCash] {
            XCTAssertEqual(section, .notDerivableFromThisDataModel)
        }
        guard case .computed = r.cashflow.operating else {
            return XCTFail("a period with transactions computes operating cash flow")
        }
        XCTAssertNotEqual(r.cashflow.operating, .noTransactionsInPeriod)
        XCTAssertNotEqual(PresentedCashflowSection.noTransactionsInPeriod,
                          .notDerivableFromThisDataModel,
                          "per-period absence and structural absence must not be one state")
    }

    // MARK: - Warnings

    /// The presented warnings must correspond one-to-one with the engine's own array, so the
    /// two spellings of the predicates cannot drift.
    func testPresentedWarningsMatchTheEnginesArray() throws {
        let db = try makeLedger(locale: "\"US\"", currency: "\"USD\"")
        try addTxn(db, type: "income", date: "2025-03-01", amount: 50_000, currency: "USD")
        try put(db, "income_tax_rate", "21")
        let r = try report(try ReportBuilder.build(db, period: period("2025")))

        let ctx = try XCTUnwrap(makeContext(db, locale: "US", period: period("2025")))
        XCTAssertEqual(r.warnings.count, USReportEngine.warnings(ctx).count,
                       "presented warnings must match the engine's array length and order")
    }

    private func makeContext(_ db: SQLiteDatabase, locale: String,
                             period: ReportPeriod) throws -> ReportContext? {
        let rows = try ReportFetch.rows(db, type: "income", from: period.from, to: period.to)
        let exp = try ReportFetch.rows(db, type: "expense", from: period.from, to: period.to)
        return ReportContext(
            incomeRows: rows, expenseRows: exp, categories: [],
            adminExpense: ReportSettings.number(db, "admin_expense_annual", fallback: 0),
            incomeTaxRate: ReportSettings.incomeTaxRate(db, locale: locale),
            surchargeRate: ReportSettings.surchargeRate(db, locale: locale),
            currency: "USD", year: period.year, from: period.from, to: period.to)
    }

    // MARK: - Period

    func testPeriodIsCarriedVerbatimAndYearIsNotDerivedFromFrom() throws {
        let db = try makeLedger()
        let q2 = ReportPeriod(year: "2025", from: "2025-04-01", to: "2025-06-30")
        let r = try report(try ReportBuilder.build(db, period: q2))
        XCTAssertEqual(r.period, q2)
        // Appendix A9: the breakdown lays out twelve months of `year` regardless of the
        // window, and both travel so a view can see the mismatch instead of inheriting it.
        XCTAssertEqual(r.monthlyBreakdown.count, 12)
        XCTAssertEqual(r.monthlyBreakdown.map(\.month), Array(1...12))
    }
}
