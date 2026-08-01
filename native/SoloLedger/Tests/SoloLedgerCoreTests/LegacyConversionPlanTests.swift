import XCTest
@testable import SoloLedgerCore

/// The conversion preflight: what it grades, what it refuses, and the one property the
/// whole stage rests on — that it writes nothing.
///
/// Several tests here carry a CONTROL alongside the assertion: they first prove that the
/// naive reading really would have accepted the value, then that the preflight rejects it.
/// Without the control, "the guard passes" and "the guard is looking at the wrong thing"
/// are indistinguishable — and for two of these rules (the date round-trip and the storage
/// class) the naive reading is the one a reasonable person would have written.
final class LegacyConversionPlanTests: LedgerTestCase {

    // MARK: - Fixtures

    /// A ledger with both settings a conversion needs. Everything else is stock.
    private func configuredStore(locale: String = "CN",
                                 currency: String = "CNY") throws -> (LedgerStore, URL) {
        let url = try trackedTempDir().appendingPathComponent("legacy.db")
        let store = try LedgerStore(databaseURL: url)
        try store.settings.setString(locale, for: SettingsStore.Key.accountingLocale)
        try store.settings.setString(currency, for: SettingsStore.Key.currency)
        return (store, url)
    }

    /// Defaults populate every column the preflight GRADES and nothing else. `tons`,
    /// `pricePerTon`, `shippingCost`, `invoiceNumber` and `invoiceStatus` are deliberately
    /// left unset: 2a-1 does not read them, and a fixture that filled them would suggest it
    /// did. They arrive with the converter (2a-2), which carries all five.
    ///
    /// Every column is overridable as a RAW `SQLiteValue` so a test can pin the storage
    /// class it means, not just the text. `id` is the exception — it is a `String` because
    /// every test but one wants an ordinary id; the one that does not binds it raw.
    private func insertSale(_ store: LedgerStore, id: String,
                            date: SQLiteValue = .text("2024-03-10"),
                            customer: SQLiteValue = .text("旧客户甲"),
                            totalAmount: SQLiteValue = .real(9040),
                            amountWithoutTax: SQLiteValue = .real(8000),
                            taxAmount: SQLiteValue = .real(1040),
                            taxRate: SQLiteValue = .real(13),
                            paidAmount: SQLiteValue = .real(9040),
                            paymentStatus: SQLiteValue = .text("paid"),
                            paymentDate: SQLiteValue = .null,
                            dueDate: SQLiteValue = .null) throws {
        try store.db.run("""
            INSERT INTO sales (id, date, customer, totalAmount, amountWithoutTax, taxAmount,
                               taxRate, paid_amount, payment_status, payment_date, due_date)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [.text(id), date, customer, totalAmount, amountWithoutTax, taxAmount,
                  taxRate, paidAmount, paymentStatus, paymentDate, dueDate])
    }

    private func insertPurchase(_ store: LedgerStore, id: String,
                                date: SQLiteValue = .text("2024-03-01"),
                                supplier: SQLiteValue = .text("旧供应商甲"),
                                totalAmount: SQLiteValue = .real(6780),
                                amountWithoutTax: SQLiteValue = .real(6000),
                                taxAmount: SQLiteValue = .real(780),
                                taxRate: SQLiteValue = .real(13),
                                paidAmount: SQLiteValue = .real(6780),
                                paymentStatus: SQLiteValue = .text("paid")) throws {
        try store.db.run("""
            INSERT INTO purchases (id, date, supplier, totalAmount, amountWithoutTax, taxAmount,
                                   taxRate, paid_amount, payment_status)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [.text(id), date, supplier, totalAmount, amountWithoutTax, taxAmount,
                  taxRate, paidAmount, paymentStatus])
    }

    private func markConverted(_ store: LedgerStore, table: String, legacyID: String) throws {
        try store.db.run("""
            INSERT INTO legacy_migrations (legacy_table, legacy_id, new_id) VALUES (?, ?, ?)
            """, [.text(table), .text(legacyID), .text("txn-\(legacyID)")])
    }

    private func plan(_ store: LedgerStore,
                      file: StaticString = #filePath, line: UInt = #line) throws
    -> LegacyConversionPlan {
        switch try store.legacyConversionPreflight() {
        case .plan(let p): return p
        case .blocked(let b):
            XCTFail("expected a plan, got \(b)", file: file, line: line)
            throw XCTSkip("blocked")
        }
    }

    private func issues(_ store: LedgerStore, _ id: String,
                        file: StaticString = #filePath, line: UInt = #line) throws
    -> [LegacyRowIssue] {
        let p = try plan(store)
        guard let row = p.rows.first(where: { $0.id == id }) else {
            XCTFail("row \(id) is not in the plan", file: file, line: line); return []
        }
        return row.issues
    }

    // MARK: - P1 — a clean row converts

    func testP1CleanRowsAreAllConvertible() throws {
        let (store, _) = try configuredStore()
        try insertSale(store, id: "s-1")
        try insertPurchase(store, id: "p-1")

        let p = try plan(store)
        XCTAssertEqual(p.rows.count, 2)
        XCTAssertEqual(p.convertibleCount, 2)
        XCTAssertEqual(p.needsAdjudicationCount, 0)
        XCTAssertEqual(p.unconvertibleCount, 0)
        XCTAssertEqual(p.rows.map(\.issues), [[], []])
        XCTAssertFalse(p.hasNothingToConvert)
        XCTAssertEqual(p.currency, "CNY")
        XCTAssertEqual(p.accountingLocale, .CN)
    }

    func testAnEmptyLedgerYieldsAnEmptyPlanRatherThanABlocker() throws {
        let (store, _) = try configuredStore()
        let p = try plan(store)
        XCTAssertTrue(p.rows.isEmpty)
        XCTAssertTrue(p.hasNothingToConvert)
        XCTAssertEqual(p.headersWithLineItems, 0)
        XCTAssertTrue(p.yearOutlook.isEmpty)
    }

    // MARK: - P2 / P3 — the date rule, with its control

    func testP2ASlashSeparatedDateNeedsAdjudication() throws {
        let (store, _) = try configuredStore()
        try insertSale(store, id: "s-1", date: .text("2024/03/10"))
        XCTAssertEqual(try issues(store, "s-1"), [.dateNotACalendarDay])
        XCTAssertEqual(try plan(store).rows.first?.grade, .needsAdjudication)
    }

    /// **The counterexample that decides the rule.** A stored timestamp really does fall
    /// inside a period window, because every comparison on `date` is lexicographic
    /// (`ReportFetch.rowSQL`). A validator that parsed the WHOLE string would reject a row
    /// the reports handle perfectly well, and the user would be told to fix healthy data.
    func testP3ATimestampSuffixIsConvertibleNotFlagged() throws {
        let (store, _) = try configuredStore()
        try insertSale(store, id: "s-1", date: .text("2025-06-15T00:00:00"))
        try insertSale(store, id: "s-2", date: .text("2025-06-15 08:30"))
        let p = try plan(store)
        XCTAssertEqual(p.convertibleCount, 2, "a timestamp suffix must not be an issue")
        // And the property that makes it true: SQLite really does place it in the window.
        let inWindow = try store.db.query("""
            SELECT COUNT(*) AS c FROM sales WHERE date >= ? AND date <= ?
            """, [.text("2025-06-01"), .text("2025-06-30")]).first?.int("c")
        XCTAssertEqual(inWindow, 2)
    }

    /// CONTROL + assertion. `DateFormatter` is not strict even with `isLenient` false: it
    /// reads all four of these as real dates (`2024-02-30` as 1 March, `2024/03/10` as
    /// 10 March — the separator is ignored — and the full-width `１９９９-０１-０１` as
    /// 1 January 1999). The control is what makes the assertion mean something: a check
    /// built on parsing alone would have accepted every one of them.
    func testDeceptiveDatesAParserWouldAcceptAreRejected() {
        for text in ["2024-02-30", "2023-02-29", "2024/03/10", "１９９９-０１-０１"] {
            XCTAssertNotNil(DateFormat.date(from: String(text.prefix(10))),
                            "control: plain parsing accepts \(text)")
            XCTAssertFalse(LegacyConversionPlan.isCalendarDayPrefix(text),
                           "\(text) must not be accepted as a calendar day")
        }
        for text in ["2025-06-15", "2024-02-29", "2025-06-15T00:00:00", "2025-06-15 08:30",
                     "9999-12-31", "0000-01-01"] {
            XCTAssertTrue(LegacyConversionPlan.isCalendarDayPrefix(text), text)
        }
        for text in ["", "0", "2025-06-1", "20250615", "2025-13-01", "2025-06-32",
                     "2025-06-00", "2025-00-10", "-001-01-01", "2024-2-05"] {
            XCTAssertFalse(LegacyConversionPlan.isCalendarDayPrefix(text), text)
        }
    }

    /// **The bug the first draft had, pinned two ways.**
    ///
    /// The check used to parse with `DateFormat` and require a round-trip, which cannot
    /// produce a `Date` for a day the process timezone SKIPPED. Kiritimati jumped from
    /// 1994-12-30 to 1995-01-01 and Samoa from 2011-12-29 to 2011-12-31 when they crossed
    /// the date line, so the very same ledger row was `convertible` on one user's Mac and
    /// `dateNotACalendarDay` on another's — and a flagged row can only be skipped.
    ///
    /// Values alone cannot pin this (CI runs in one zone), so the structural half does:
    /// the implementation must name no clock, calendar or zone at all. Together they fail
    /// if anyone reintroduces the formatter.
    func testTheDateRuleCannotDependOnTheMachinesTimezone() throws {
        for skipped in ["1994-12-31", "2011-12-30"] {
            XCTAssertTrue(LegacyConversionPlan.isCalendarDayPrefix(skipped),
                          "\(skipped) is an ordinary calendar day and must grade the same "
                          + "everywhere, including where that day was never lived through")
        }
        let source = try String(contentsOf: Self.packageRoot()
            .appendingPathComponent("Sources/SoloLedgerCore/Conversion/LegacyConversionPlan.swift"),
                                encoding: .utf8)
        // The three date functions' bodies, from the first to the declaration after the
        // last. The doc comment above them is excluded on purpose: it NAMES the formatter
        // in order to explain why it is gone.
        let start = try XCTUnwrap(source.range(of: "static func isCalendarDayPrefix"))
        let end = try XCTUnwrap(source.range(of: "static func wouldTruncateCounterparty",
                                             range: start.upperBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])
        // Whole-identifier, or the check fires on its own name: `isCalendarDayPrefix`
        // contains "Calendar". Measured — the first version of this assertion did exactly
        // that and reported a defect that was not there.
        let banned = ["Date", "DateFormat", "DateFormatter", "Calendar", "TimeZone", "Locale"]
        let found = Self.mentions(of: banned, in: [("<isCalendarDayPrefix…>", body)])
        XCTAssertTrue(found.isEmpty, """
            the calendar-day rule consults \(found.joined(separator: ", ")) — that is how \
            the verdict became machine-dependent the first time
            """)
        // The scan is real: the code it replaced would fail it.
        XCTAssertFalse(Self.mentions(of: banned,
                                     in: [("x", "  guard let d = DateFormat.date(from: h)")]).isEmpty)
    }

    func testLeapYearsFollowTheGregorianRuleIncludingTheCenturyExceptions() {
        for year in [2024, 2000, 1600] {
            XCTAssertTrue(LegacyConversionPlan.isLeapYear(year), "\(year)")
            XCTAssertEqual(LegacyConversionPlan.daysInMonth(year: year, month: 2), 29)
        }
        for year in [2023, 1900, 2100] {
            XCTAssertFalse(LegacyConversionPlan.isLeapYear(year), "\(year)")
            XCTAssertEqual(LegacyConversionPlan.daysInMonth(year: year, month: 2), 28)
        }
        XCTAssertEqual((1...12).map { LegacyConversionPlan.daysInMonth(year: 2025, month: $0) },
                       [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31])
        XCTAssertEqual(LegacyConversionPlan.daysInMonth(year: 2025, month: 13), 0)
    }

    func testAnEmptyDateIsUnconvertibleNotMerelyAdjudicable() throws {
        let (store, _) = try configuredStore()
        // `date` is TEXT NOT NULL, so '' is the reachable form of "absent" — and
        // `validateSale` only tests `!data.date`, which '' fails but '0' passes.
        try insertSale(store, id: "s-1", date: .text(""))
        let p = try plan(store)
        XCTAssertEqual(p.rows.first?.issues, [.dateMissing])
        XCTAssertEqual(p.rows.first?.grade, .unconvertible,
                       "there is no representable target value, so no user choice rescues it")
        XCTAssertEqual(p.unconvertibleCount, 1)
        XCTAssertEqual(p.convertibleCount, 0)
    }

    func testPaymentAndDueDatesAreHeldToTheSameRuleButOnlyWhenPresent() throws {
        let (store, _) = try configuredStore()
        try insertSale(store, id: "s-1", paymentDate: .null, dueDate: .null)
        try insertSale(store, id: "s-2", paymentDate: .text("2024/03/15"), dueDate: .text(""))
        try insertSale(store, id: "s-3", paymentDate: .text("2024-03-15"),
                       dueDate: .text("2024-13-01"))
        XCTAssertEqual(try issues(store, "s-1"), [])
        XCTAssertEqual(try issues(store, "s-2"), [.paymentDateNotACalendarDay])
        XCTAssertEqual(try issues(store, "s-3"), [.dueDateNotACalendarDay])
    }

    // MARK: - P4 / P5 — the money columns, with their control

    func testP4AnAbsentTotalAmountNeedsAdjudicationInsteadOfBecomingZero() throws {
        let (store, _) = try configuredStore()
        try insertSale(store, id: "s-1", totalAmount: .null)
        XCTAssertEqual(try issues(store, "s-1"), [.totalAmountNotANumber])
        // The value Electron would have written instead (`migrations.js:118`).
        XCTAssertEqual(try store.db.query("SELECT totalAmount FROM sales").first?["totalAmount"],
                       .null, "control: the ledger really holds no number here")
    }

    /// CONTROL + assertion, and the case that makes the storage-class rule load-bearing.
    /// SQLite's REAL affinity keeps `0x1388` as TEXT because it is not a SQL numeric
    /// literal; Swift's `Double(_:)` would read the very same bytes as 5000. Grading on the
    /// storage class means this app never out-reads the database it is describing.
    func testP5ANonNumericPaidAmountNeedsAdjudicationEvenWhenSwiftCouldParseIt() throws {
        let (store, _) = try configuredStore()
        try insertSale(store, id: "s-1", paidAmount: .text("0x1388"))
        try insertSale(store, id: "s-2", paidAmount: .text("1,000"))

        XCTAssertEqual(Double("0x1388"), 5000,
                       "control: the lenient reading would have produced a number")
        let kinds = try store.db.query("SELECT id, typeof(paid_amount) AS t FROM sales ORDER BY id")
            .compactMap { $0.string("t") }
        XCTAssertEqual(kinds, ["text", "text"],
                       "control: REAL affinity really did refuse both values")

        XCTAssertEqual(try issues(store, "s-1"), [.paidAmountNotANumber])
        XCTAssertEqual(try issues(store, "s-2"), [.paidAmountNotANumber])
    }

    /// REAL affinity converts anything it CAN, so a numeric-looking string is already a
    /// number by the time it is stored and must not be flagged.
    func testANumericLookingStringIsStoredAsANumberAndPassesCleanly() throws {
        let (store, _) = try configuredStore()
        try insertSale(store, id: "s-1", totalAmount: .text("1000"), paidAmount: .text(" 42 "),
                       paymentStatus: .text("unpaid"))
        XCTAssertEqual(try store.db.query("SELECT typeof(totalAmount) AS t FROM sales")
            .first?.string("t"), "real", "control: affinity converted it")
        XCTAssertEqual(try issues(store, "s-1"), [])
    }

    /// `9e999` stores and reads back as `Inf` (SQLite coerces NaN to NULL on write, so the
    /// infinities are the only non-finite values that survive). `Transaction.normalized()`
    /// would silently turn it into 0, which is the substitution this stage refuses.
    func testAnInfiniteAmountIsAnIssueRatherThanASilentZero() throws {
        let (store, _) = try configuredStore()
        try store.db.run("""
            INSERT INTO sales (id, date, customer, totalAmount, amountWithoutTax, taxAmount,
                               taxRate, paid_amount, payment_status)
            VALUES ('s-1','2024-03-10','x', 9e999, 8000, 1040, 13, 0, 'unpaid')
            """)
        XCTAssertEqual(try store.db.query("SELECT typeof(totalAmount) AS t FROM sales")
            .first?.string("t"), "real", "control: it is stored as a REAL, not as text")
        XCTAssertEqual(LegacyConversionPlan.numericField(.real(.infinity)), .notFinite)
        XCTAssertEqual(try issues(store, "s-1"), [.totalAmountNotANumber])
    }

    /// The one money column where ABSENCE is representable, so absence is not an issue.
    /// `transactions.amount_net` is nullable and the engines read `amount_net || amount`, so
    /// carrying NULL is the faithful move — which is exactly why `migrations.js:118` guards
    /// this column with `|| null` while guarding the other four with `|| 0`.
    func testAnAbsentAmountWithoutTaxIsCarriedRatherThanFlagged() throws {
        let (store, _) = try configuredStore()
        try insertSale(store, id: "s-1", amountWithoutTax: .null)
        try insertSale(store, id: "s-2", amountWithoutTax: .real(0))
        try insertSale(store, id: "s-3", amountWithoutTax: .text("abc"))
        try store.db.run("""
            INSERT INTO sales (id, date, customer, totalAmount, amountWithoutTax, taxAmount,
                               taxRate, paid_amount, payment_status)
            VALUES ('s-4','2024-03-10','x', 9040, 9e999, 1040, 13, 0, 'unpaid')
            """)
        XCTAssertEqual(try issues(store, "s-1"), [], "NULL amount_net is representable")
        XCTAssertEqual(try issues(store, "s-2"), [], "a real zero is a real value")
        XCTAssertEqual(try issues(store, "s-3"), [.amountWithoutTaxNotANumber])
        // The fifth column's own `.notFinite` arm — absence is fine here, an infinity is
        // not, and the two arms have to be separable or the switch is only half tested.
        XCTAssertEqual(try issues(store, "s-4"), [.amountWithoutTaxNotANumber],
                       "an infinite amount_net is not 'absent'")
    }

    func testEachCoercedMoneyColumnIsFlaggedOnItsOwn() throws {
        let (store, _) = try configuredStore()
        try insertSale(store, id: "total", totalAmount: .null)
        try insertSale(store, id: "tax", taxAmount: .null)
        try insertSale(store, id: "rate", taxRate: .null)
        try insertSale(store, id: "paid", paidAmount: .null)
        XCTAssertEqual(try issues(store, "total"), [.totalAmountNotANumber])
        XCTAssertEqual(try issues(store, "tax"), [.taxAmountNotANumber])
        XCTAssertEqual(try issues(store, "rate"), [.taxRateNotANumber])
        XCTAssertEqual(try issues(store, "paid"), [.paidAmountNotANumber])
    }

    // MARK: - P6 — payment status

    func testP6AnUnrecognizedPaymentStatusNeedsAdjudication() throws {
        let (store, _) = try configuredStore()
        try insertSale(store, id: "s-1", paymentStatus: .text("已付"))
        XCTAssertEqual(try issues(store, "s-1"), [.paymentStatusUnrecognized])
        // CONTROL: the reading this app uses everywhere else would have called it `paid`,
        // silently promoting an unknown state to "collected".
        XCTAssertEqual(PaymentStatus(rawValue: "已付") ?? .paid, .paid)
    }

    /// Named for what it ASSERTS. The mapping of empty/NULL to `unpaid` is 2a-2's job —
    /// nothing in this PR produces the string `unpaid` — so a name promising to have
    /// observed it would be promising more than the test does.
    func testEmptyAndAbsentPaymentStatusAreNotIssues() throws {
        let (store, _) = try configuredStore()
        try insertSale(store, id: "null", paymentStatus: .null)
        try insertSale(store, id: "empty", paymentStatus: .text(""))
        for value in ["paid", "partial", "unpaid"] {
            try insertSale(store, id: value, paymentStatus: .text(value))
        }
        XCTAssertEqual(try plan(store).convertibleCount, 5)
    }

    /// Whitespace is NOT trimmed into "empty". A value nobody can account for stays an
    /// issue, because normalising it here would be the silent repair this stage refuses.
    func testAWhitespaceOnlyPaymentStatusIsUnrecognizedRatherThanEmpty() {
        XCTAssertTrue(LegacyConversionPlan.paymentStatusIsUnrecognized(.text("  ")))
        XCTAssertFalse(LegacyConversionPlan.paymentStatusIsUnrecognized(.text("")))
        XCTAssertFalse(LegacyConversionPlan.paymentStatusIsUnrecognized(.null))
        XCTAssertTrue(LegacyConversionPlan.paymentStatusIsUnrecognized(.integer(0)))
    }

    // MARK: - P7 — the counterparty cap

    func testP7ACounterpartyTheWritePathWouldTruncateNeedsAdjudication() throws {
        let (store, _) = try configuredStore()
        let long = String(repeating: "字", count: 201)
        try insertSale(store, id: "s-1", customer: .text(long))
        try insertSale(store, id: "s-2", customer: .text(String(repeating: "字", count: 200)))
        XCTAssertEqual(try issues(store, "s-1"), [.counterpartyWouldBeTruncated])
        XCTAssertEqual(try issues(store, "s-2"), [], "exactly at the cap is kept whole")
        // CONTROL: the cap is real and belongs to the write path, not to this file.
        XCTAssertEqual(Transaction(counterparty: long).normalized().counterparty.count, 200)
    }

    /// The converter copies exactly two strings from a legacy row. The counterparty rule was
    /// ruled first; this is the same rule on the other one, and it exists because a rule that
    /// holds for one of two copied columns is not a rule. Both caps are MEASURED against the
    /// write path rather than restated.
    func testAnInvoiceNumberTheWritePathWouldTruncateNeedsAdjudication() throws {
        let (store, _) = try configuredStore()
        let long = String(repeating: "I", count: 101)
        try store.db.run("""
            INSERT INTO sales (id, date, customer, invoiceNumber, totalAmount, amountWithoutTax,
                               taxAmount, taxRate, paid_amount, payment_status)
            VALUES ('s-1','2024-03-10','Acme',?,9040,8000,1040,13,0,'unpaid'),
                   ('s-2','2024-03-10','Acme',?,9040,8000,1040,13,0,'unpaid')
            """, [.text(long), .text(String(repeating: "I", count: 100))])
        XCTAssertEqual(try issues(store, "s-1"), [.invoiceNoWouldBeTruncated])
        XCTAssertEqual(try issues(store, "s-2"), [], "exactly at the cap is kept whole")
        // CONTROL: the cap is real and belongs to the write path, not to the grader.
        XCTAssertEqual(Transaction(invoiceNo: long).normalized().invoiceNo.count, 100)
    }

    /// **Present-but-unreadable is not absence.** All four columns the converter copies AS
    /// TEXT read their value through `stringValue` in every other rule, so a BLOB slips past
    /// all of them — and would have arrived at the writer as `""` (the two strings) or SQL
    /// NULL (the two dates), reporting a value that exists as one that does not.
    ///
    /// Graded per column, and each in isolation, so a rule that covered three of the four
    /// could not pass.
    func testABlobInAColumnCopiedAsTextNeedsAdjudication() throws {
        let (store, _) = try configuredStore()
        let blob = SQLiteValue.blob(Data([0x00, 0xff, 0x10]))
        let columns: [(String, String, LegacyRowIssue)] = [
            ("customer", "b-party", .counterpartyNotReadableAsText),
            ("invoiceNumber", "b-invoice", .invoiceNoNotReadableAsText),
            ("payment_date", "b-paid", .paymentDateNotReadableAsText),
            ("due_date", "b-due", .dueDateNotReadableAsText),
        ]
        for (column, id, _) in columns {
            // Exactly one column is bound raw per row, so each iteration isolates one class.
            try store.db.run("""
                INSERT INTO sales (id, date, totalAmount, amountWithoutTax,
                                   taxAmount, taxRate, paid_amount, payment_status, \(column))
                VALUES (?, '2024-03-10', 9040, 8000, 1040, 13, 0, 'unpaid', ?)
                """, [.text(id), blob])
        }
        // CONTROL: SQLite really kept each one as a BLOB — TEXT affinity does not convert them.
        let kinds = try store.db.query("""
            SELECT id, typeof(customer) AS c, typeof(invoiceNumber) AS i,
                   typeof(payment_date) AS p, typeof(due_date) AS d FROM sales ORDER BY id
            """).map { "\($0.string("id")!):\($0.string("c")!)/\($0.string("i")!)/\($0.string("p")!)/\($0.string("d")!)" }
        XCTAssertEqual(kinds, ["b-due:null/null/null/blob", "b-invoice:null/blob/null/null",
                               "b-paid:null/null/blob/null", "b-party:blob/null/null/null"])

        for (_, id, expected) in columns {
            XCTAssertEqual(try issues(store, id), [expected], id)
            XCTAssertEqual(try plan(store).rows.first { $0.id == id }?.grade,
                           .needsAdjudication, id)
        }
        XCTAssertTrue(try plan(store).convertibleIdentities.isEmpty,
                      "not one of the four may be offered for conversion")
    }

    /// SQL NULL keeps its already-ruled treatment. The new rule must not have widened into
    /// "anything without a text reading", which would have made ordinary empty columns
    /// unconvertible.
    func testASqlNullInThoseSameColumnsIsStillAnOrdinaryAbsence() throws {
        let (store, _) = try configuredStore()
        try store.db.run("""
            INSERT INTO sales (id, date, customer, invoiceNumber, totalAmount, amountWithoutTax,
                               taxAmount, taxRate, paid_amount, payment_status,
                               payment_date, due_date)
            VALUES ('s-1','2024-03-10',NULL,NULL,9040,8000,1040,13,0,'unpaid',NULL,NULL)
            """)
        XCTAssertEqual(try issues(store, "s-1"), [])
        XCTAssertFalse(LegacyConversionPlan.hasNoTextReading(.null))
        XCTAssertTrue(LegacyConversionPlan.hasNoTextReading(.blob(Data([0x00]))))
        XCTAssertFalse(LegacyConversionPlan.hasNoTextReading(.text("")))
        XCTAssertFalse(LegacyConversionPlan.hasNoTextReading(.integer(1)))
    }

    /// A currency the write path would shorten makes the plan STATE a code no converted row
    /// could carry, so it stops the whole batch rather than any one row.
    func testACurrencyTheWritePathWouldShortenBlocksTheWholeBatch() throws {
        let (store, _) = try configuredStore(currency: "VERYLONGCODE")
        try insertSale(store, id: "s-1")
        XCTAssertEqual(try store.legacyConversionPreflight(),
                       .blocked(.currencyNotStorableVerbatim(currency: "VERYLONGCODE")))
        // CONTROL + boundary: eight characters survive, nine do not.
        XCTAssertFalse(LegacyConversionPlan.wouldTruncateCurrency("12345678"))
        XCTAssertTrue(LegacyConversionPlan.wouldTruncateCurrency("123456789"))
        XCTAssertEqual(Transaction(currency: "VERYLONGCODE").normalized().currency, "VERYLONG")
    }

    /// The internal split the runner needs: the public entry point still opens a snapshot,
    /// and the extracted body answers identically when called inside one.
    func testTheExtractedPreflightBodyAnswersTheSameAsThePublicEntryPoint() throws {
        let (store, _) = try configuredStore()
        try insertSale(store, id: "s-1")
        try insertSale(store, id: "bad", date: .text("2024/03/10"))
        let viaPublic = try store.legacyConversionPreflight()
        let viaBody = try store.db.readSnapshot { try store.legacyConversionPreflightBody() }
        XCTAssertEqual(viaPublic, viaBody)
    }

    /// The split's whole point, pinned from both sides: the PUBLIC entry point really does
    /// open a transaction (so it cannot nest inside one), and the extracted body really does
    /// not (so the runner can call it inside its write transaction). A test that only
    /// compared their answers would pass with the snapshot removed.
    func testOnlyThePublicEntryPointOpensATransaction() throws {
        let (store, _) = try configuredStore()
        try insertSale(store, id: "s-1")
        XCTAssertThrowsError(try store.db.transaction {
            _ = try store.legacyConversionPreflight()
        }, "the public entry point takes a snapshot, so BEGIN inside BEGIN must fail")
        XCTAssertNoThrow(try store.db.transaction {
            _ = try store.legacyConversionPreflightBody()
        })
    }

    // MARK: - P8 — line items

    func testP8HeadersCarryingLineItemsAreCountedOverTheWorkSetOnly() throws {
        let (store, _) = try configuredStore()
        try insertSale(store, id: "s-1")
        try insertSale(store, id: "s-2")
        try insertPurchase(store, id: "p-1")
        for line in 0..<3 {
            try store.db.run("""
                INSERT INTO sales_items (sale_id, line_no, description, quantity, unit_price)
                VALUES (?, ?, ?, ?, ?)
                """, [.text("s-1"), .integer(Int64(line)), .text("line"), .real(1), .real(10)])
        }
        try store.db.run("""
            INSERT INTO purchase_items (purchase_id, line_no, description, quantity, unit_price)
            VALUES ('p-1', 0, 'line', 1, 10)
            """)

        XCTAssertEqual(try plan(store).headersWithLineItems, 2,
                       "two HEADERS carry lines — not four line rows")

        // A header already converted is no longer about to lose anything.
        try markConverted(store, table: "sales", legacyID: "s-1")
        XCTAssertEqual(try plan(store).headersWithLineItems, 1)
    }

    // MARK: - P9 — the currency outlook

    func testP9AYearAlreadyHoldingAnotherCurrencyIsForecastAsAConflict() throws {
        let (store, _) = try configuredStore(currency: "CNY")
        try store.create(Transaction(id: "t-usd", type: .income, date: "2024-05-01",
                                     amount: 100, currency: "USD", paymentStatus: .unpaid))
        try insertSale(store, id: "s-1", date: .text("2024-03-10"))
        try insertSale(store, id: "s-2", date: .text("2025-03-10"))

        let outlook = try plan(store).yearOutlook
        XCTAssertEqual(outlook.map(\.year), ["2024", "2025"])
        XCTAssertEqual(outlook[0].existingCurrencies, ["USD"])
        XCTAssertEqual(outlook[0].existingTransactionCount, 1)
        XCTAssertTrue(outlook[0].wouldHoldASecondCurrency,
                      "converting stamps CNY into a period that already holds USD")
        XCTAssertEqual(outlook[1].existingCurrencies, [])
        XCTAssertEqual(outlook[1].existingTransactionCount, 0,
                       "a year with no transactions is refused today and starts computing")
        XCTAssertFalse(outlook[1].wouldHoldASecondCurrency)
    }

    func testAYearAlreadyHoldingTheSameCurrencyIsNotForecastAsAConflict() throws {
        let (store, _) = try configuredStore(currency: "CNY")
        try store.create(Transaction(id: "t-cny", type: .expense, date: "2024-05-01",
                                     amount: 10, currency: "CNY", paymentStatus: .unpaid))
        try insertSale(store, id: "s-1", date: .text("2024-03-10"))
        let outlook = try plan(store).yearOutlook
        XCTAssertEqual(outlook.map(\.existingCurrencies), [["CNY"]])
        XCTAssertFalse(outlook[0].wouldHoldASecondCurrency)
    }

    /// The realized-cash window is part of the union, so a row the P&L window misses can
    /// still put a currency in the period. Dropping either half would under-report.
    func testTheOutlookUnionsBothWindowsTheReportBuilderGatesOn() throws {
        let (store, _) = try configuredStore(currency: "CNY")
        // Dated OUTSIDE 2024 but PAID inside it: invisible to the P&L window, selected by
        // the cash window through COALESCE(payment_date, date).
        try store.create(Transaction(id: "t", type: .income, date: "2023-12-01", amount: 5,
                                     currency: "JPY", paymentStatus: .paid,
                                     paymentDate: "2024-02-02"))
        try insertSale(store, id: "s-1", date: .text("2024-03-10"))
        let outlook = try plan(store).yearOutlook
        XCTAssertEqual(outlook[0].existingCurrencies, ["JPY"])
        XCTAssertTrue(outlook[0].wouldHoldASecondCurrency)
    }

    /// Rows the user can only skip must not colour the forecast.
    func testTheOutlookCoversConvertibleRowsOnly() throws {
        let (store, _) = try configuredStore()
        try insertSale(store, id: "bad", date: .text("2019/01/01"))
        try insertSale(store, id: "good", date: .text("2024-03-10"))
        XCTAssertEqual(try plan(store).yearOutlook.map(\.year), ["2024"])
    }

    /// The year window's own bounds. Every other outlook fixture sits mid-year, so
    /// `\(year)-01-01`…`\(year)-12-31` could be narrowed to any inner pair and nothing
    /// would notice; these two transactions sit exactly on the edges.
    func testTheYearWindowIncludesBothItsEndpoints() throws {
        let (store, _) = try configuredStore(currency: "CNY")
        try store.create(Transaction(id: "jan", type: .income, date: "2024-01-01", amount: 1,
                                     currency: "USD", paymentStatus: .unpaid))
        try store.create(Transaction(id: "dec", type: .expense, date: "2024-12-31", amount: 1,
                                     currency: "JPY", paymentStatus: .unpaid))
        try insertSale(store, id: "s-1", date: .text("2024-06-01"))
        let outlook = try plan(store).yearOutlook
        XCTAssertEqual(outlook[0].existingTransactionCount, 2,
                       "1 January and 31 December are both inside the year")
        XCTAssertEqual(outlook[0].existingCurrencies, ["JPY", "USD"])
        XCTAssertTrue(outlook[0].wouldHoldASecondCurrency)
    }

    // MARK: - P10 — the property the whole stage rests on

    /// A full preflight — every branch of the scan exercised, including a blocked
    /// precondition's neighbour, an unconvertible row, line items and a year outlook —
    /// changes no byte of the database or of its write-ahead log.
    ///
    /// The fixture is not "every issue class" and does not claim to be; what it has to
    /// cover is every QUERY the scan runs, which is what could write.
    func testP10ThePreflightWritesNothing() throws {
        let (store, url) = try configuredStore()
        try insertSale(store, id: "clean")
        try insertSale(store, id: "bad-date", date: .text("2024/03/10"))
        try insertSale(store, id: "bad-money", totalAmount: .null, paidAmount: .text("abc"))
        try insertSale(store, id: "bad-status", paymentStatus: .text("已付"))
        try insertSale(store, id: "no-date", date: .text(""))
        try insertPurchase(store, id: "p-1")
        try store.create(Transaction(id: "t", type: .income, date: "2024-05-01",
                                     amount: 1, currency: "USD"))
        try store.db.run("""
            INSERT INTO sales_items (sale_id, line_no, description) VALUES ('clean', 0, 'x')
            """)

        let wal = URL(fileURLWithPath: url.path + "-wal")
        let before = try Data(contentsOf: url)
        let walBefore = try? Data(contentsOf: wal)

        let outcome = try store.legacyConversionPreflight()
        guard case .plan(let p) = outcome else { return XCTFail("expected a plan") }
        XCTAssertEqual(p.rows.count, 6, "the scan really did run over every row")
        XCTAssertEqual(p.needsAdjudicationCount, 3)
        XCTAssertEqual(p.unconvertibleCount, 1)
        XCTAssertEqual(p.headersWithLineItems, 1)
        XCTAssertFalse(p.yearOutlook.isEmpty, "the per-year queries really did run")

        XCTAssertEqual(try Data(contentsOf: url), before,
                       "the preflight changed the database file")
        XCTAssertEqual(try? Data(contentsOf: wal), walBefore,
                       "the preflight changed the write-ahead log")
    }

    // MARK: - The work set

    /// The same anti-join the Electron converter picks its work set with, so "rows a
    /// conversion would carry" has one answer across the converter, the probe and this plan.
    func testAlreadyConvertedRowsAreNotInThePlan() throws {
        let (store, _) = try configuredStore()
        try insertSale(store, id: "s-1")
        try insertSale(store, id: "s-2")
        try insertPurchase(store, id: "p-1")
        try markConverted(store, table: "sales", legacyID: "s-1")

        let p = try plan(store)
        XCTAssertEqual(p.rows.compactMap(\.id).sorted(), ["p-1", "s-2"])
        // The probe must agree, row for row.
        let summary = try store.legacyLedgerSummary()
        XCTAssertEqual(summary.unconverted, p.rows.count)
    }

    /// **The row that used to vanish.** `id TEXT PRIMARY KEY` does not imply NOT NULL in
    /// SQLite — only an INTEGER PRIMARY KEY gets that — so a hand-edited ledger can hold a
    /// sale whose id is SQL NULL or a BLOB. The first draft read the id with
    /// `guard let ... else { return nil }` inside a `compactMap`, which put such a row in
    /// NONE of the three grades: the probe counted it forever, the plan never mentioned it,
    /// and `hasNothingToConvert` could be true on a ledger that visibly still held records.
    ///
    /// The invariant that makes it impossible is asserted directly: the plan and the probe
    /// must agree on how many unconverted rows exist, whatever is in the id column.
    func testARowWhoseIDHasNoTextReadingIsGradedNotDropped() throws {
        let (store, _) = try configuredStore()
        try insertSale(store, id: "s-clean")
        for id in [SQLiteValue.null, .blob(Data([0x00, 0xff]))] {
            try store.db.run("""
                INSERT INTO sales (id, date, customer, totalAmount, amountWithoutTax,
                                   taxAmount, taxRate, paid_amount, payment_status)
                VALUES (?, '2024-03-10', 'x', 9040, 8000, 1040, 13, 9040, 'paid')
                """, [id])
        }
        let kinds = try store.db.query("SELECT typeof(id) AS t FROM sales")
            .compactMap { $0.string("t") }.sorted()
        XCTAssertEqual(kinds, ["blob", "null", "text"], "control: SQLite really stores all three")

        let p = try plan(store)
        XCTAssertEqual(p.rows.count, 3, "a row the anti-join returned must be graded")
        XCTAssertEqual(try store.legacyLedgerSummary().unconverted, p.rows.count,
                       "the plan and the probe must count the same ledger")
        XCTAssertEqual(p.convertibleCount, 1)
        XCTAssertEqual(p.unconvertibleCount, 2)
        XCTAssertEqual(p.rows.filter { $0.id == nil }.map(\.issues),
                       [[.idNotReadableAsText], [.idNotReadableAsText]])
        XCTAssertFalse(p.hasNothingToConvert)
    }

    /// And the degenerate case the drop made worst: when EVERY unconverted row has an
    /// unreadable id, the plan used to be empty while the ledger visibly was not.
    func testALedgerOfOnlyUnreadableIDsIsNotReportedAsHavingNothingHidden() throws {
        let (store, _) = try configuredStore()
        try store.db.run("""
            INSERT INTO sales (id, date, customer, totalAmount, amountWithoutTax, taxAmount,
                               taxRate, paid_amount, payment_status)
            VALUES (NULL, '2024-03-10', 'x', 9040, 8000, 1040, 13, 9040, 'paid')
            """)
        let p = try plan(store)
        XCTAssertTrue(p.hasNothingToConvert, "nothing here CAN be converted")
        XCTAssertEqual(p.unconvertibleCount, 1, "but the plan says why, rather than staying silent")
        XCTAssertTrue(try store.legacyLedgerSummary().holdsHiddenRecords)
    }

    /// Mappings are scoped per table: a `sales` mapping for id `x` must not hide the
    /// `purchases` row that happens to share it.
    func testMappingsDoNotLeakAcrossTables() throws {
        let (store, _) = try configuredStore()
        try insertSale(store, id: "x")
        try insertPurchase(store, id: "x")
        try markConverted(store, table: "sales", legacyID: "x")
        let p = try plan(store)
        XCTAssertEqual(p.rows.count, 1)
        XCTAssertEqual(p.rows.first?.table, .purchases)
    }

    func testTheRowOrderIsStableAcrossRuns() throws {
        let (store, _) = try configuredStore()
        for (i, date) in ["2024-05-01", "2024-01-01", "2024-03-01"].enumerated() {
            try insertSale(store, id: "s-\(i)", date: .text(date))
        }
        let first = try plan(store).rows.map(\.id)
        let second = try plan(store).rows.map(\.id)
        XCTAssertEqual(first, ["s-1", "s-2", "s-0"], "ordered by (date, id)")
        XCTAssertEqual(first, second)
    }

    // MARK: - The whole-batch preconditions

    /// A brand-new ledger is blocked on the CURRENCY, not on the regime — and the asymmetry
    /// is not incidental. Schema v3 (`SchemaMigrator.swift:133-139`) seeds
    /// `accounting_locale` on every migrated ledger; nothing seeds `currency`, which is the
    /// gap `AppModel.seedCurrencyIfProvablyNew` was added to close for ledgers this app can
    /// prove are new. So `accountingLocaleNotConfigured` is reachable only on a ledger whose
    /// row was removed afterwards, while `currencyNotConfigured` is the state a fresh
    /// install actually starts in.
    func testAFreshLedgerIsBlockedOnTheCurrencyBeforeAnythingIsGraded() throws {
        let store = try makeStore()
        try insertSale(store, id: "s-1")
        XCTAssertEqual(try store.settings.rawValue(SettingsStore.Key.accountingLocale), "\"CN\"",
                       "control: v3 really does seed the regime")
        XCTAssertNil(try store.settings.rawValue(SettingsStore.Key.currency),
                     "control: nothing seeds the currency")
        XCTAssertEqual(try store.legacyConversionPreflight(), .blocked(.currencyNotConfigured))
    }

    func testAnUnreadableRegimeRowIsReportedVerbatim() throws {
        let (store, _) = try configuredStore()
        try store.db.run("UPDATE settings SET value = ? WHERE key = ?",
                         [.text("\u{FEFF}\"CN\""), .text(SettingsStore.Key.accountingLocale)])
        XCTAssertEqual(try store.legacyConversionPreflight(),
                       .blocked(.accountingLocaleInvalid(storedText: "\u{FEFF}\"CN\"")))
    }

    func testAMissingCurrencyRowBlocksTheWholeBatch() throws {
        let (store, _) = try configuredStore()
        try insertSale(store, id: "s-1")
        try store.settings.remove(SettingsStore.Key.currency)
        XCTAssertEqual(try store.legacyConversionPreflight(), .blocked(.currencyNotConfigured))
    }

    /// **The asymmetry this precondition exists for.** A byte-order mark makes the row read
    /// as a perfectly good `"CNY"` through the lenient display reader and be REFUSED by the
    /// report engines. Converting under the lenient reading would stamp a currency the app
    /// itself will not stand behind, and every converted period would then be blocked on the
    /// very setting the conversion trusted.
    func testABOMPrefixedCurrencyIsRefusedRatherThanReadLeniently() throws {
        let (store, _) = try configuredStore()
        let stored = "\u{FEFF}\"CNY\""
        try store.db.run("UPDATE settings SET value = ? WHERE key = ?",
                         [.text(stored), .text(SettingsStore.Key.currency)])
        XCTAssertEqual(try store.settings.string(SettingsStore.Key.currency), "CNY",
                       "control: the lenient reader sees a perfectly good currency")
        XCTAssertEqual(try store.legacyConversionPreflight(),
                       .blocked(.currencyInvalid(storedText: stored)))
    }

    func testABlankCurrencyIsRefused() throws {
        let (store, _) = try configuredStore()
        try store.settings.setString("   ", for: SettingsStore.Key.currency)
        guard case .blocked(.currencyInvalid) = try store.legacyConversionPreflight() else {
            return XCTFail("a whitespace-only currency must be refused")
        }
    }

    /// The preconditions are answered BEFORE any row is read, so a ledger that cannot be
    /// converted never produces a half-answer about its rows.
    func testTheRegimeIsAnsweredBeforeTheCurrency() throws {
        let (store, _) = try configuredStore()
        try store.settings.remove(SettingsStore.Key.accountingLocale)
        try store.settings.remove(SettingsStore.Key.currency)
        XCTAssertEqual(try store.legacyConversionPreflight(),
                       .blocked(.accountingLocaleNotConfigured),
                       "the regime question comes first, as it does in ReportBuilder")
    }

    // MARK: - Completeness controls

    /// A stored row with every column populated and nothing wrong with any of them.
    ///
    /// `StoredRow`'s own defaults are all `.null`, which is the honest default for "what
    /// SQLite handed back" — but it means a row that leaves the four coerced money columns
    /// alone carries four issues. Isolation tests need a clean base, so they build from
    /// this one and change exactly one thing.
    private static func cleanStoredRow(id: SQLiteValue = .text("x")) -> LegacyConversionPlan.StoredRow {
        LegacyConversionPlan.StoredRow(
            id: id, date: .text("2024-03-10"), counterparty: .text("Acme"),
            invoiceNo: .text("OLD-001"),
            totalAmount: .real(9040), amountWithoutTax: .real(8000), taxAmount: .real(1040),
            taxRate: .real(13), paidAmount: .real(9040), paymentStatus: .text("paid"),
            paymentDate: .null, dueDate: .null)
    }

    /// Every issue the type can express is reachable, AND each one is produced in isolation
    /// by exactly the value it names. An issue nobody can produce is dead code; an issue
    /// that only ever appears alongside three others is not really being tested.
    func testEveryIssueCaseIsReachableInIsolationFromARealStoredValue() {
        let long = String(repeating: "a", count: 201)
        let mutations: [(LegacyRowIssue, (inout LegacyConversionPlan.StoredRow) -> Void)] = [
            (.idNotReadableAsText, { $0.id = .null }),
            (.dateMissing, { $0.date = .null }),
            (.dateNotACalendarDay, { $0.date = .text("2024/03/10") }),
            (.paymentDateNotACalendarDay, { $0.paymentDate = .text("x") }),
            (.dueDateNotACalendarDay, { $0.dueDate = .text("x") }),
            (.totalAmountNotANumber, { $0.totalAmount = .text("abc") }),
            (.taxAmountNotANumber, { $0.taxAmount = .text("abc") }),
            (.taxRateNotANumber, { $0.taxRate = .text("abc") }),
            (.paidAmountNotANumber, { $0.paidAmount = .text("abc") }),
            (.amountWithoutTaxNotANumber, { $0.amountWithoutTax = .text("abc") }),
            (.paymentStatusUnrecognized, { $0.paymentStatus = .text("?") }),
            (.counterpartyWouldBeTruncated, { $0.counterparty = .text(long) }),
            (.invoiceNoWouldBeTruncated, { $0.invoiceNo = .text(String(repeating: "I", count: 101)) }),
            (.counterpartyNotReadableAsText, { $0.counterparty = .blob(Data([0x00])) }),
            (.invoiceNoNotReadableAsText, { $0.invoiceNo = .blob(Data([0x00])) }),
            (.paymentDateNotReadableAsText, { $0.paymentDate = .blob(Data([0x00])) }),
            (.dueDateNotReadableAsText, { $0.dueDate = .blob(Data([0x00])) }),
        ]
        XCTAssertEqual(LegacyConversionPlan.issues(in: Self.cleanStoredRow()), [],
                       "the base row must be clean or every case below is meaningless")

        var seen: Set<LegacyRowIssue> = []
        for (expected, mutate) in mutations {
            var row = Self.cleanStoredRow()
            mutate(&row)
            XCTAssertEqual(LegacyConversionPlan.issues(in: row), [expected],
                           "\(expected.rawValue) must be produced alone by its own value")
            seen.insert(expected)
        }
        XCTAssertEqual(seen, Set(LegacyRowIssue.allCases),
                       "unreachable: \(Set(LegacyRowIssue.allCases).subtracting(seen))")
    }

    /// A row can carry several at once, and they arrive in a stable order so two scans of
    /// the same ledger compare equal.
    func testIssuesAccumulateAndAreOrderStable() {
        var row = Self.cleanStoredRow()
        row.date = .text("2024/03/10")
        row.counterparty = .text(String(repeating: "a", count: 201))
        row.totalAmount = .null
        row.paymentStatus = .text("?")
        let found = LegacyConversionPlan.issues(in: row)
        XCTAssertEqual(found, [.counterpartyWouldBeTruncated, .dateNotACalendarDay,
                               .paymentStatusUnrecognized, .totalAmountNotANumber])
        XCTAssertEqual(found, found.sorted { $0.rawValue < $1.rawValue })
    }

    /// `StoredRow`'s all-`.null` defaults are the honest reading of "nothing was selected",
    /// and the id, the date and the four coerced columns all say so. Pinned because a future
    /// change to those defaults would silently weaken every isolation test above.
    func testAnEntirelyEmptyStoredRowFlagsEveryColumnThatCannotBeAbsent() {
        XCTAssertEqual(LegacyConversionPlan.issues(in: .init()),
                       [.dateMissing, .idNotReadableAsText, .paidAmountNotANumber,
                        .taxAmountNotANumber, .taxRateNotANumber, .totalAmountNotANumber])
    }

    /// The direction ruling (7-A), pinned rather than left in a comment.
    func testTheDirectionMappingMirrorsTheElectronConverter() {
        XCTAssertEqual(LegacyTable.sales.transactionType, .income)
        XCTAssertEqual(LegacyTable.purchases.transactionType, .expense)
        XCTAssertEqual(Set(LegacyTable.allCases.map(\.rawValue)), ["sales", "purchases"])
    }

    func testGradeIsDerivedFromTheIssuesAndNothingElse() {
        func grade(_ issues: [LegacyRowIssue]) -> LegacyRowGrade {
            LegacyConversionRow(table: .sales, id: "x", storedDate: nil, issues: issues).grade
        }
        XCTAssertEqual(grade([]), .convertible)
        XCTAssertEqual(grade([.dateNotACalendarDay]), .needsAdjudication)
        XCTAssertEqual(grade([.dateMissing]), .unconvertible)
        XCTAssertEqual(grade([.idNotReadableAsText]), .unconvertible)
        XCTAssertEqual(grade([.dateMissing, .totalAmountNotANumber]), .unconvertible,
                       "unconvertible dominates")
        XCTAssertEqual(grade([.idNotReadableAsText, .paymentStatusUnrecognized]), .unconvertible)
        // Exactly two issues are unconvertible, and it is because their TARGET column is
        // NOT NULL. Every other case must leave the row rescuable by skipping it.
        for issue in LegacyRowIssue.allCases where ![.dateMissing, .idNotReadableAsText].contains(issue) {
            XCTAssertEqual(grade([issue]), .needsAdjudication, issue.rawValue)
        }
    }

    // MARK: - Reachability

    /// The preflight ships UNREACHABLE: no file in the SwiftUI target names any of it.
    ///
    /// That is not a stylistic claim. Two existing guarantees depend on the conversion
    /// machinery never running by itself — `AppModelBootTests` T3 proves a ledger holding
    /// unconverted legacy rows is refused by `seedCurrencyIfProvablyNew`, and
    /// `canLoadDemoData` gates on the same `holdsHiddenRecords`. Wiring this into the boot
    /// chain would put it on exactly the ledgers those two protect. The wizard (2a-4) is
    /// where it becomes reachable, deliberately and from a user action.
    func testThePreflightIsNotReachableFromTheAppTarget() throws {
        let sources = try Self.appSources()
        XCTAssertGreaterThan(sources.count, 10, "the App target did not resolve")
        let found = Self.mentions(of: Self.conversionSymbols, in: sources)
        XCTAssertTrue(found.isEmpty, """
            the SwiftUI target already names the conversion preflight: \
            \(found.sorted().joined(separator: ", ")). 2a-1 ships unreachable; \
            activation is 2a-4, and it must arrive with the wizard that discloses what \
            converting changes.
            """)
    }

    /// The scan itself, proved against synthetic sources — otherwise "no hits" and "the
    /// scanner is broken" look identical.
    func testTheReachabilityScanReallyDetectsAUseAndIgnoresAComment() {
        let use = [("Views/X.swift", "let p = try store.legacyConversionPreflight()")]
        XCTAssertFalse(Self.mentions(of: Self.conversionSymbols, in: use).isEmpty)

        let comment = [("Views/X.swift", "    // legacyConversionPreflight() lands in 2a-4")]
        XCTAssertTrue(Self.mentions(of: Self.conversionSymbols, in: comment).isEmpty)

        let longer = [("Views/X.swift", "let x = LegacyConversionPlanner()")]
        XCTAssertTrue(Self.mentions(of: ["LegacyConversionPlan"], in: longer).isEmpty,
                      "whole-identifier matching only")

        for symbol in Self.conversionSymbols {
            XCTAssertEqual(Self.mentions(of: Self.conversionSymbols,
                                         in: [("X.swift", "let v = \(symbol)")]).count, 1,
                           "\(symbol) must be individually detectable")
        }
    }

    // MARK: - Scan helpers

    private static let conversionSymbols = [
        "LegacyConversionPreflight", "LegacyConversionPlan", "LegacyConversionRow",
        "LegacyConversionBlocker", "LegacyRowIssue", "LegacyRowGrade",
        "LegacyYearOutlook", "LegacyTable", "legacyConversionPreflight",
    ]

    /// …/native/SoloLedger/Tests/SoloLedgerCoreTests/<this>.swift → …/native/SoloLedger
    private static func packageRoot() -> URL {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { dir.deleteLastPathComponent() }
        return dir
    }

    private static func appSources() throws -> [(path: String, text: String)] {
        let root = packageRoot().appendingPathComponent("Sources/SoloLedger")
        guard let walker = FileManager.default.enumerator(atPath: root.path) else {
            XCTFail("cannot enumerate \(root.path)"); return []
        }
        var out: [(String, String)] = []
        for case let rel as String in walker where rel.hasSuffix(".swift") {
            let url = root.appendingPathComponent(rel)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                XCTFail("cannot read \(rel)"); continue
            }
            out.append(("Sources/SoloLedger/\(rel)", text))
        }
        return out
    }

    /// Whole-identifier hits, skipping comment lines — a doc comment naming the symbol is
    /// not a use, and this very file's own doc comments are the reason that matters.
    private static func mentions(of names: [String],
                                 in sources: [(path: String, text: String)]) -> [String] {
        var out: [String] = []
        for (path, text) in sources {
            for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated() {
                let line = String(raw)
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                for name in names {
                    guard let re = try? NSRegularExpression(
                        pattern: "(?<![A-Za-z0-9_])\(name)(?![A-Za-z0-9_])") else { continue }
                    if re.firstMatch(in: line,
                                     range: NSRange(line.startIndex..., in: line)) != nil {
                        out.append("\(path):\(index + 1) \(name)")
                    }
                }
            }
        }
        return out
    }
}
