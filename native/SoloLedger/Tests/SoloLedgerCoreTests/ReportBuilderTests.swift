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
    /// `seeded` adds one in-period transaction, because a period with none is now a hard
    /// stop (`legacySourceUnavailable`). Tests about that stop pass `seeded: false`.
    private func makeLedger(locale: String? = "\"CN\"", currency: String? = "\"CNY\"",
                            seeded: Bool = true) throws -> SQLiteDatabase {
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
        if seeded { try addTxn(db, date: "2025-06-01") }
        return db
    }

    private func put(_ db: SQLiteDatabase, _ key: String, _ raw: String) throws {
        _ = try db.run("""
            INSERT INTO settings (key, value, updated_at) VALUES (?, ?, '')
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """, [.text(key), .text(raw)])
    }

    /// `taxAmount` defaults to 0, but the mapping guard passes DISTINCT values on the income
    /// and expense sides on purpose: the turnover-tax blocks are `collected` / `paid` /
    /// `payable`, and with every tax 0 all three are 0 — so swapping two of them would be
    /// undetectable. Found by mutation.
    private func addTxn(_ db: SQLiteDatabase, type: String = "income", date: String,
                        amount: Double = 100, currency: String = "CNY",
                        paymentStatus: String = "paid", paymentDate: String? = nil,
                        taxAmount: Double = 0) throws {
        _ = try db.run("""
            INSERT INTO transactions (id, type, date, amount, amount_net, tax_amount,
                                      category_id, currency, payment_status, paid_amount, payment_date)
            VALUES (?, ?, ?, ?, ?, ?, NULL, ?, ?, ?, ?)
            """, [.text(UUID().uuidString), .text(type), .text(date), .real(amount),
                  .real(amount), .real(taxAmount), .text(currency), .text(paymentStatus),
                  .real(amount), paymentDate.map { .text($0) } ?? .null])
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
        let db = try makeLedger(currency: nil, seeded: false)
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
        let db = try makeLedger(locale: "\"US\"", currency: "\"EUR\"", seeded: false)
        try addTxn(db, date: "2025-06-01", currency: "EUR")
        let r = try report(try ReportBuilder.build(db, period: period("2025")))
        XCTAssertEqual(r.currency, "EUR")
    }

    func testCurrencyMismatchWithThePeriodsOnlyCurrencyIsBlocked() throws {
        let db = try makeLedger(currency: "\"CNY\"", seeded: false)
        try addTxn(db, date: "2025-06-01", currency: "USD")
        XCTAssertEqual(try ReportBuilder.build(db, period: period("2025")),
                       .blocked(.currencyMismatch(storedCurrency: "CNY", periodCurrency: "USD")))
    }

    func testMultipleCurrenciesInThePeriodAreBlockedRatherThanSummed() throws {
        let db = try makeLedger(seeded: false)
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
        let db = try makeLedger(seeded: false)
        try addTxn(db, date: "2025-06-01", currency: "CNY")
        try addTxn(db, date: "2024-11-01", currency: "USD",
                   paymentStatus: "unpaid", paymentDate: "2025-06-15")
        let r = try report(try ReportBuilder.build(db, period: period("2025")))
        XCTAssertEqual(r.currency, "CNY", "an unpaid foreign row must not create a false mismatch")
    }

    /// **Counterexample 2 for the currency query.** With no rows dated in the period the
    /// source is `.legacy`, and this app then reads no transaction rows at all — so a PAID
    /// row from another year whose `payment_date` happens to fall inside the period must not
    /// drag the period onto the transactions path.
    func testLegacyStopIgnoresForeignPaidRowWhosePaymentDateFallsInPeriod() throws {
        let db = try makeLedger(seeded: false)
        try addTxn(db, date: "2024-11-01", currency: "USD",
                   paymentStatus: "paid", paymentDate: "2025-06-15")
        XCTAssertEqual(try ReportBuilder.build(db, period: period("2025")),
                       .blocked(.legacySourceUnavailable),
                       "a cash date inside the period does not make the period reportable")
    }

    // MARK: - The legacy stop

    /// **The counterexample that matters.** A ledger with REAL money in the legacy
    /// `sales` / `purchases` tables and nothing in `transactions` for the period must NOT
    /// produce a report.
    ///
    /// Electron reads those tables and reports the money — `base-CN-2024` records inflow
    /// 9040 / outflow 7780 / net 1260 for exactly such a period. This app does not read them
    /// (plan §6.1, per #395), so running the engines over empty arrays would emit a
    /// complete-looking statement of zeros for a period in which real trade happened. That is
    /// the placeholder metric CLAUDE.md's product boundary forbids.
    func testLedgerWithRealLegacyRowsButNoPeriodTransactionsIsBlockedNotZeroed() throws {
        let db = try makeLedger(seeded: false)
        try db.execute("""
            CREATE TABLE sales (id TEXT PRIMARY KEY, date TEXT, amount REAL, amount_net REAL);
            CREATE TABLE purchases (id TEXT PRIMARY KEY, date TEXT, amount REAL, amount_net REAL);
            INSERT INTO sales VALUES ('s1','2025-03-04', 9040, 8000);
            INSERT INTO sales VALUES ('s2','2025-07-19', 3120, 2800);
            INSERT INTO purchases VALUES ('p1','2025-04-02', 7780, 7000);
            """)
        let outcome = try ReportBuilder.build(db, period: period("2025"))

        XCTAssertEqual(outcome, .blocked(.legacySourceUnavailable))
        // Stated separately, because the defect this replaces was a `.report` whose every
        // figure was a zero standing in for money nobody read.
        if case .report(let r) = outcome {
            XCTFail("""
                a report was produced for a period whose money is in the legacy tables: \
                sections=\(r.sections.map(\.reportTypeID)), months=\(r.monthlyBreakdown.count), \
                cashflow=\(r.cashflow.operating)
                """)
        }
    }

    /// A period with no rows at all stops for the SAME reason, deliberately: from here the
    /// two situations are indistinguishable. Without reading the legacy tables, "this ledger
    /// really is empty" and "this ledger's money is somewhere we do not look" present
    /// identical inputs, so both must stop.
    func testAPeriodWithNoRowsAtAllIsAlsoBlocked() throws {
        let db = try makeLedger(currency: "\"JPY\"", seeded: false)
        XCTAssertEqual(try ReportBuilder.build(db, period: period("2025")),
                       .blocked(.legacySourceUnavailable))
    }

    /// The stop is evaluated BEFORE the currency question, so a legacy period never reports a
    /// currency problem it cannot actually have.
    func testTheLegacyStopPreemptsCurrencyResolution() throws {
        let db = try makeLedger(currency: nil, seeded: false)
        XCTAssertEqual(try ReportBuilder.build(db, period: period("2025")),
                       .blocked(.legacySourceUnavailable),
                       "the source decision comes first; currency is never asked")
    }

    /// The pair that shows the stop is about UNREAD data, not about small numbers: a period
    /// WITH transactions but none of them realized still reports, and its zero is honest —
    /// the cash window was read and nothing was in it.
    func testAPeriodWithOnlyUnpaidRowsStillReportsAnHonestZeroCashflow() throws {
        let db = try makeLedger(seeded: false)
        try addTxn(db, date: "2025-06-01", paymentStatus: "unpaid")
        let r = try report(try ReportBuilder.build(db, period: period("2025")))
        XCTAssertEqual(r.cashflow.operating,
                       .computed(inflow: .amount(0), outflow: .amount(0), net: .amount(0)))
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
    }

    // MARK: - Warnings

    /// Warnings, at every arity the engine can produce: none, one, and two — with the exact
    /// case, the exact amount and the exact ORDER asserted, and cross-checked against
    /// `USReportEngine.warnings` so the two spellings of the predicates cannot drift.
    ///
    /// Order is load-bearing: `us.js:117-122` is a `.filter(Boolean)` literal, so when net
    /// profit is not positive the meals hint SLIDES from index 1 to index 0.
    func testWarningsAtEveryArityWithExactCasesAmountsAndOrder() throws {
        // (a) NONE — no profit, no meals.
        let none = try usLedger(income: 0, mealsExpense: 0)
        XCTAssertEqual(try report(try ReportBuilder.build(none, locale: "US",
                                                          period: period("2025"))).warnings, [])
        XCTAssertEqual(USReportEngine.warnings(try usContext(none)).count, 0)

        // (b) ONE — meals only. Net profit is negative, so the quarterly hint does not fire
        //     and the meals hint occupies index 0.
        let mealsOnly = try usLedger(income: 0, mealsExpense: 300)
        let one = try report(try ReportBuilder.build(mealsOnly, locale: "US",
                                                     period: period("2025"))).warnings
        XCTAssertEqual(one, [.mealsLimitedToFiftyPercent],
                       "with no profit the meals hint slides to index 0")
        XCTAssertEqual(USReportEngine.warnings(try usContext(mealsOnly)).count, one.count)

        // (c) TWO — profit and meals. The quarterly payment comes FIRST.
        let both = try usLedger(income: 50_000, mealsExpense: 300)
        let two = try report(try ReportBuilder.build(both, locale: "US",
                                                     period: period("2025"))).warnings
        let engineQuarterly = USReportEngine.estimatedTax(try usContext(both)).quarterlyPayment
        guard case .computed(let expected) = engineQuarterly else {
            return XCTFail("the engine must compute a quarterly payment here")
        }
        XCTAssertEqual(two, [.estimatedQuarterlyPayment(amount: .amount(expected)),
                             .mealsLimitedToFiftyPercent],
                       "exact cases, exact amount, exact order")
        XCTAssertEqual(USReportEngine.warnings(try usContext(both)).count, two.count)

        // The amount is the engine's own number, not a re-derivation.
        if case .estimatedQuarterlyPayment(let amount) = two[0] {
            XCTAssertEqual(amount, .amount(expected))
        } else {
            XCTFail("the quarterly payment must be first")
        }
    }

    /// A US ledger with a configured rate, some income and an optional meals expense.
    private func usLedger(income: Double, mealsExpense: Double) throws -> SQLiteDatabase {
        let db = try makeLedger(locale: "\"US\"", currency: "\"USD\"", seeded: false)
        try put(db, "income_tax_rate", "21")
        try db.execute("""
            CREATE TABLE categories (id TEXT PRIMARY KEY, locale TEXT, slug TEXT,
                                     is_cogs INTEGER, type TEXT, sort_order INTEGER);
            INSERT INTO categories VALUES ('meals','US','meals',0,'expense',1);
            """)
        if income > 0 {
            try addTxn(db, type: "income", date: "2025-03-01", amount: income, currency: "USD")
        } else {
            // A row must exist or the period is a legacy stop; make it a tiny expense.
            try addTxn(db, type: "expense", date: "2025-03-01", amount: 1, currency: "USD")
        }
        if mealsExpense > 0 {
            _ = try db.run("""
                INSERT INTO transactions (id, type, date, amount, amount_net, tax_amount,
                                          category_id, currency, payment_status, paid_amount,
                                          payment_date)
                VALUES (?, 'expense', '2025-04-01', ?, ?, 0, 'meals', 'USD', 'paid', ?, NULL)
                """, [.text(UUID().uuidString), .real(mealsExpense), .real(mealsExpense),
                      .real(mealsExpense)])
        }
        return db
    }

    private func usContext(_ db: SQLiteDatabase) throws -> ReportContext {
        let p = period("2025")
        return ReportContext(
            incomeRows: try ReportFetch.rows(db, type: "income", from: p.from, to: p.to),
            expenseRows: try ReportFetch.rows(db, type: "expense", from: p.from, to: p.to),
            categories: (try? ReportFetch.categories(db, locale: "US")) ?? [],
            adminExpense: ReportSettings.number(db, "admin_expense_annual", fallback: 0),
            incomeTaxRate: ReportSettings.incomeTaxRate(db, locale: "US"),
            surchargeRate: ReportSettings.surchargeRate(db, locale: "US"),
            currency: "USD", year: p.year, from: p.from, to: p.to)
    }

    // MARK: - The hand-written mapping, checked field by field

    /// **The mapping guard.** For each of the 13 pairs, assert the façade's ORDERED line ids
    /// AND their classified values equal what the engine actually returns.
    ///
    /// The earlier section test only checked the 13 ids, non-emptiness and finiteness — it
    /// would have passed with a dropped field, a duplicated one, a wrong order, or a line
    /// wired to the wrong engine member. `ReportBuilder.lines(locale:id:ctx:)` is a
    /// hand-written switch of ~90 lines; this is what holds it to the engines.
    func testEveryLineIdAndValueMatchesTheEngineOutputForAllThirteenPairs() throws {
        for locale in ["CN", "US", "JP", "EU", "KR", "TW"] {
            let db = try makeLedger(locale: "\"\(locale)\"", currency: "\"CNY\"", seeded: false)
            // Money on both sides plus a rate, so the estimate lines are real numbers rather
            // than a uniform refusal that would hide a mis-wiring.
            try addTxn(db, type: "income", date: "2025-03-01", amount: 8000, taxAmount: 920)
            try addTxn(db, type: "expense", date: "2025-04-01", amount: 3000, taxAmount: 340)
            try put(db, "income_tax_rate", "20")
            try put(db, "surcharge_rate", "12")
            try put(db, "admin_expense_annual", "1200")

            let r = try report(try ReportBuilder.build(db, locale: locale, period: period("2025")))
            let ctx = try engineContext(db, locale: locale)

            for section in r.sections {
                let expected = try Self.expectedLines(locale: locale, id: section.reportTypeID,
                                                      ctx: ctx)
                XCTAssertEqual(section.lines.map(\.id), expected.map(\.0),
                               "\(locale)/\(section.reportTypeID): ordered line ids")
                XCTAssertEqual(section.lines.map(\.value), expected.map(\.1),
                               "\(locale)/\(section.reportTypeID): classified values")
                XCTAssertEqual(Set(section.lines.map(\.id)).count, section.lines.count,
                               "\(locale)/\(section.reportTypeID): no duplicated line id")
            }
        }
    }

    /// The undeclared tax-inclusive block, likewise field by field.
    func testUndeclaredTaxInclusiveValuesMatchTheEngineOutput() throws {
        for locale in ["JP", "EU", "KR", "TW"] {
            let db = try makeLedger(locale: "\"\(locale)\"", seeded: false)
            try addTxn(db, type: "income", date: "2025-03-01", amount: 8000, taxAmount: 920)
            try addTxn(db, type: "expense", date: "2025-04-01", amount: 3000, taxAmount: 340)
            let r = try report(try ReportBuilder.build(db, locale: locale, period: period("2025")))
            let ctx = try engineContext(db, locale: locale)
            let block: TaxInclusiveSummary
            switch locale {
            case "JP": block = JPReportEngine.taxInclusiveSummary(ctx)
            case "EU": block = EUReportEngine.taxInclusiveSummary(ctx)
            case "KR": block = KRReportEngine.taxInclusiveSummary(ctx)
            default:   block = TWReportEngine.taxInclusiveSummary(ctx)
            }
            let presented = try XCTUnwrap(r.undeclaredTaxInclusiveSummary, locale)
            XCTAssertEqual(presented.purchaseTotal, ReportPresentation.field(block.purchaseTotal))
            XCTAssertEqual(presented.salesTotal, ReportPresentation.field(block.salesTotal))
            XCTAssertEqual(presented.difference, ReportPresentation.field(block.difference))
        }
    }

    /// The monthly breakdown, likewise — twelve months, each value from the engine.
    func testMonthlyBreakdownValuesMatchTheEngineOutput() throws {
        for locale in ["CN", "US", "JP", "EU", "KR", "TW"] {
            let db = try makeLedger(locale: "\"\(locale)\"", seeded: false)
            try addTxn(db, type: "income", date: "2025-03-01", amount: 8000, taxAmount: 920)
            try addTxn(db, type: "expense", date: "2025-04-01", amount: 3000, taxAmount: 340)
            let r = try report(try ReportBuilder.build(db, locale: locale, period: period("2025")))
            let ctx = try engineContext(db, locale: locale)
            let raw: [ReportMonth]
            switch locale {
            case "CN": raw = CNReportEngine.monthlyBreakdown(ctx)
            case "JP": raw = JPReportEngine.monthlyBreakdown(ctx)
            case "EU": raw = EUReportEngine.monthlyBreakdown(ctx)
            case "KR": raw = KRReportEngine.monthlyBreakdown(ctx)
            case "TW": raw = TWReportEngine.monthlyBreakdown(ctx)
            default:   raw = USReportEngine.monthlyBreakdown(ctx)
            }
            XCTAssertEqual(r.monthlyBreakdown.map(\.month), raw.map(\.month), locale)
            XCTAssertEqual(r.monthlyBreakdown.map(\.revenue),
                           raw.map { ReportPresentation.field($0.revenue) }, locale)
            XCTAssertEqual(r.monthlyBreakdown.map(\.cost),
                           raw.map { ReportPresentation.field($0.cost) }, locale)
            XCTAssertEqual(r.monthlyBreakdown.map(\.profit),
                           raw.map { ReportPresentation.field($0.profit) }, locale)
        }
    }

    /// The units the façade attaches: exactly the two margin lines are percentages.
    func testOnlyTheMarginLinesAreMarkedAsPercentages() throws {
        for locale in ["CN", "US", "JP", "EU", "KR", "TW"] {
            let db = try makeLedger(locale: "\"\(locale)\"")
            let r = try report(try ReportBuilder.build(db, locale: locale, period: period("2025")))
            for section in r.sections {
                for line in section.lines {
                    let isMargin = line.id == "grossMargin" || line.id == "netMargin"
                    XCTAssertEqual(line.unit, isMargin ? .percent : .money,
                                   "\(locale)/\(section.reportTypeID)/\(line.id)")
                }
            }
        }
    }

    /// Schedule C exports the 25 CONTRACT lines and NONE of the three intermediates the
    /// engine carries but never emits (`ReportBatch4ParityTests.nonContractFields`).
    func testScheduleCExportsTheContractLinesAndNoIntermediates() throws {
        let db = try makeLedger(locale: "\"US\"")
        let r = try report(try ReportBuilder.build(db, locale: "US", period: period("2025")))
        let ids = try XCTUnwrap(r.sections.first { $0.reportTypeID == "schedule-c" }).lines.map(\.id)
        XCTAssertEqual(ids.count, 25)
        for intermediate in ["unroundedGrossIncome", "unroundedTotalExpenses", "rawMealsTotal"] {
            XCTAssertFalse(ids.contains(intermediate), "\(intermediate) is not a contract field")
        }
    }

    /// **The notes mapping.** `ReportBuilder.notes(locale:id:ctx:)` hand-writes two ordered
    /// facts for exactly one pair, and nothing else asserted them: the public-API test walks
    /// `section.notes` but would pass over an empty array, so deleting both notes — or
    /// swapping them — was invisible.
    func testOnlyUSSeTaxCarriesNotesAndTheirValuesAndOrderMatchTheEngine() throws {
        var pairsWithNotes: [String] = []

        for locale in ["CN", "US", "JP", "EU", "KR", "TW"] {
            let db = try makeLedger(locale: "\"\(locale)\"", seeded: false)
            try addTxn(db, type: "income", date: "2025-03-01", amount: 8000, taxAmount: 920)
            try addTxn(db, type: "expense", date: "2025-04-01", amount: 3000, taxAmount: 340)
            let r = try report(try ReportBuilder.build(db, locale: locale, period: period("2025")))
            let ctx = try engineContext(db, locale: locale)

            for section in r.sections where !section.notes.isEmpty {
                pairsWithNotes.append("\(locale)/\(section.reportTypeID)")
            }
            for section in r.sections {
                guard locale == "US", section.reportTypeID == "se-tax" else {
                    XCTAssertTrue(section.notes.isEmpty,
                                  "\(locale)/\(section.reportTypeID) must carry no notes")
                    continue
                }
                // Exactly two, in this order.
                XCTAssertEqual(section.notes,
                               [.estimatedTaxDueDates(USReportEngine.estimatedTax(ctx).dueDates),
                                .selfEmploymentParameterYear(
                                    USReportEngine.selfEmploymentTax(ctx).paramYear)],
                               "notes must equal the engine's own values, in this order")
                // GUARD, not assert, before indexing: a dropped note must FAIL this test, not
                // trap out of the process — a crash produces no summary line and can take
                // other tests in the same run with it. (Found by mutation: deleting both
                // notes asserted correctly and then died on `notes[0]`.)
                guard section.notes.count == 2 else {
                    XCTFail("US/se-tax must carry two ordered facts, got \(section.notes.count)")
                    continue
                }
                // Each value spelled out too, so a failure names which one drifted.
                guard case .estimatedTaxDueDates(let dates) = section.notes[0] else {
                    return XCTFail("the due dates must come first")
                }
                XCTAssertEqual(dates, USReportEngine.estimatedTax(ctx).dueDates)
                XCTAssertEqual(dates.count, 4, "us.js:106 emits four quarterly dates")
                guard case .selfEmploymentParameterYear(let year) = section.notes[1] else {
                    return XCTFail("the parameter year must come second")
                }
                XCTAssertEqual(year, USReportEngine.selfEmploymentTax(ctx).paramYear)
            }
        }

        XCTAssertEqual(pairsWithNotes, ["US/se-tax"],
                       "exactly one of the 13 pairs carries notes")
    }

    private func engineContext(_ db: SQLiteDatabase, locale: String) throws -> ReportContext {
        let p = period("2025")
        return ReportContext(
            incomeRows: try ReportFetch.rows(db, type: "income", from: p.from, to: p.to),
            expenseRows: try ReportFetch.rows(db, type: "expense", from: p.from, to: p.to),
            categories: (try? ReportFetch.categories(db, locale: locale)) ?? [],
            adminExpense: ReportSettings.number(db, "admin_expense_annual", fallback: 0),
            incomeTaxRate: ReportSettings.incomeTaxRate(db, locale: locale),
            surchargeRate: ReportSettings.surchargeRate(db, locale: locale),
            currency: ReportSettings.string(db, "currency", fallback: "CNY"),
            year: p.year, from: p.from, to: p.to)
    }

    /// The expected (id, classified value) list for one pair, built DIRECTLY from the engine
    /// struct. Written out rather than reflected so a renamed or dropped engine field is a
    /// compile error here.
    private static func expectedLines(locale: String, id: String,
                                      ctx: ReportContext) throws -> [(String, ReportFieldPresentation)] {
        func m(_ v: Double) -> ReportFieldPresentation { ReportPresentation.field(v) }
        func m(_ v: EstimatedValue) -> ReportFieldPresentation { ReportPresentation.field(v) }
        switch (locale, id) {
        case ("CN", "income-statement"):
            let b = CNReportEngine.batchOne(ctx)
            return [("salesRevenue", m(b.salesRevenue)), ("costOfSales", m(b.costOfSales)),
                    ("costOfGoodsSold", m(b.costOfGoodsSold)),
                    ("operatingExpenses", m(b.operatingExpenses)),
                    ("grossProfit", m(b.grossProfit)), ("grossMargin", m(b.grossMargin)),
                    ("shippingFee", m(b.shippingFee)), ("adminExpense", m(b.adminExpense)),
                    ("operatingProfit", m(b.operatingProfit)), ("taxSurcharge", m(b.taxSurcharge)),
                    ("incomeTax", m(b.incomeTax)), ("netProfit", m(b.netProfit)),
                    ("netMargin", m(b.netMargin))]
        case ("JP", "income-statement"), ("KR", "income-statement"), ("TW", "income-statement"):
            let b = locale == "JP" ? JPReportEngine.batchOne(ctx)
                  : locale == "KR" ? KRReportEngine.batchOne(ctx) : TWReportEngine.batchOne(ctx)
            return [("salesRevenue", m(b.salesRevenue)), ("costOfSales", m(b.costOfSales)),
                    ("costOfGoodsSold", m(b.costOfGoodsSold)),
                    ("operatingExpenses", m(b.operatingExpenses)),
                    ("grossProfit", m(b.grossProfit)), ("grossMargin", m(b.grossMargin)),
                    ("adminExpense", m(b.adminExpense)),
                    ("operatingProfit", m(b.operatingProfit)), ("incomeTax", m(b.incomeTax)),
                    ("netProfit", m(b.netProfit)), ("netMargin", m(b.netMargin))]
        case ("EU", "profit-loss"):
            let b = EUReportEngine.batchOne(ctx)
            return [("revenue", m(b.revenue)), ("costOfSales", m(b.costOfSales)),
                    ("costOfGoodsSold", m(b.costOfGoodsSold)),
                    ("operatingExpenses", m(b.operatingExpenses)),
                    ("grossProfit", m(b.grossProfit)), ("grossMargin", m(b.grossMargin)),
                    ("adminExpense", m(b.adminExpense)),
                    ("operatingProfit", m(b.operatingProfit)), ("incomeTax", m(b.incomeTax)),
                    ("netProfit", m(b.netProfit)), ("netMargin", m(b.netMargin))]
        case ("CN", "vat-summary"):
            let b = CNReportEngine.vatSummary(ctx)
            return [("cumulativeInput", m(b.cumulativeInput)),
                    ("cumulativeOutput", m(b.cumulativeOutput)),
                    ("certifiedInput", m(b.certifiedInput)),
                    ("invoicedOutput", m(b.invoicedOutput)),
                    ("estimatedPayable", m(b.estimatedPayable))]
        case ("JP", "consumption-tax"):
            let b = JPReportEngine.consumptionTax(ctx)
            return [("collected", m(b.collected)), ("paid", m(b.paid)), ("payable", m(b.payable))]
        case ("EU", "vat-return"):
            let b = EUReportEngine.vatReturn(ctx)
            return [("outputVAT", m(b.outputVAT)), ("inputVAT", m(b.inputVAT)),
                    ("vatPayable", m(b.vatPayable))]
        case ("KR", "vat-summary"):
            let b = KRReportEngine.vatSummary(ctx)
            return [("outputVAT", m(b.outputVAT)), ("inputVAT", m(b.inputVAT)),
                    ("vatPayable", m(b.vatPayable))]
        case ("TW", "business-tax"):
            let b = TWReportEngine.businessTax(ctx)
            return [("collected", m(b.collected)), ("paid", m(b.paid)), ("payable", m(b.payable))]
        case ("CN", "tax-inclusive"):
            let b = CNReportEngine.taxInclusiveSummary(ctx)
            return [("purchaseTotal", m(b.purchaseTotal)), ("salesTotal", m(b.salesTotal)),
                    ("difference", m(b.difference))]
        case ("US", "schedule-c"):
            let c = USReportEngine.scheduleC(ctx)
            return [("line1_grossReceipts", m(c.line1_grossReceipts)),
                    ("line2_returns", m(c.line2_returns)),
                    ("line6_otherIncome", m(c.line6_otherIncome)),
                    ("line7_grossIncome", m(c.line7_grossIncome)),
                    ("line8_advertising", m(c.line8_advertising)), ("line9_car", m(c.line9_car)),
                    ("line10_commissions", m(c.line10_commissions)),
                    ("line11_contract", m(c.line11_contract)),
                    ("line13_depreciation", m(c.line13_depreciation)),
                    ("line15_insurance", m(c.line15_insurance)),
                    ("line16b_interest", m(c.line16b_interest)),
                    ("line17_legal", m(c.line17_legal)), ("line18_office", m(c.line18_office)),
                    ("line20_rent", m(c.line20_rent)), ("line21_repairs", m(c.line21_repairs)),
                    ("line22_supplies", m(c.line22_supplies)), ("line23_taxes", m(c.line23_taxes)),
                    ("line24a_travel", m(c.line24a_travel)), ("line24b_meals", m(c.line24b_meals)),
                    ("line25_utilities", m(c.line25_utilities)), ("line26_wages", m(c.line26_wages)),
                    ("line27a_other", m(c.line27a_other)),
                    ("line30_homeOffice", m(c.line30_homeOffice)),
                    ("line28_totalExpenses", m(c.line28_totalExpenses)),
                    ("line31_netProfit", m(c.line31_netProfit))]
        case ("US", "se-tax"):
            let se = USReportEngine.selfEmploymentTax(ctx)
            let est = USReportEngine.estimatedTax(ctx)
            return [("netEarnings", m(se.netEarnings)), ("seEarnings", m(se.seEarnings)),
                    ("socialSecurityTax", m(se.socialSecurityTax)),
                    ("medicareTax", m(se.medicareTax)),
                    ("additionalMedicare", m(se.additionalMedicare)),
                    ("totalSETax", m(se.totalSETax)),
                    ("annualIncomeTax", m(est.annualIncomeTax)),
                    ("annualSETax", m(est.annualSETax)),
                    ("totalAnnual", m(est.totalAnnual)),
                    ("quarterlyPayment", m(est.quarterlyPayment))]
        default:
            throw XCTSkip("unexpected pair \(locale)/\(id)")
        }
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
