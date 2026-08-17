import XCTest
@testable import SoloLedgerCore

/// D-2 · Q3 — the internal document number, against `electron/handlers/documents.js nextNumber`
/// and `NUMBER_PREFIX`.
///
/// Six of `scripts/test-handlers.mjs` §2B Batch 8's assertions are the `next-number` route (A) and
/// three more are `DOC_NUMBER_EXISTS` (D); both groups have counterparts below. Two of the six —
/// a missing `type` and a `type` outside the closed set — are unrepresentable through this API for
/// the same reason `create`'s `doc_type` refusal is, and that substitution is recorded on
/// ``LedgerStore/nextBusinessDocumentNumber(for:)`` rather than skipped.
///
/// **Every expected string here was produced by the real handler.** A 193-case corpus (55 suffix
/// lengths × 2 shapes, 40 pseudo-random digit runs, and every malformed shape below) was generated
/// by driving `dispatch('GET', '/api/documents/next-number')` against a migrated `:memory:`
/// database and replayed through ``LedgerStore/nextBusinessDocumentNumber(for:year:)``: 193 of 193
/// identical. The cases pinned in this file are the ones that discriminate — the corpus itself is
/// not committed, for the reason `DocumentMathTests` gives about its own.
final class DocumentNumberingTests: LedgerTestCase {

    /// A year the clock cannot reach, used with the seam so these assertions do not expire on
    /// 1 January. The live clock is exercised separately, once, below.
    private let year = 2026

    private func seed(_ store: LedgerStore, _ numbers: [String],
                      type: BusinessDocumentType = .quotation) throws {
        for (index, number) in numbers.enumerated() {
            try store.db.run("""
                INSERT INTO business_documents (id, doc_type, doc_number, doc_date, customer_name)
                VALUES (?, ?, ?, '2026-01-01', 'C')
                """, [.text("seed-\(index)-\(type.rawValue)"), .text(type.rawValue), .text(number)])
        }
    }

    private func suggestion(after numbers: [String],
                            type: BusinessDocumentType = .quotation) throws -> String {
        let store = try makeStore()
        defer { try? store.db.close() }
        try seed(store, numbers)
        return try store.nextBusinessDocumentNumber(for: type, year: year)
    }

    // MARK: - The prefix table

    /// `NUMBER_PREFIX`, all five. Exhaustiveness is the compiler's; which two letters each type
    /// gets is not, and a swapped pair would print `SO-…` on a quotation with nothing else
    /// noticing.
    func testEachDocumentTypeHasItsOwnTwoLetterPrefix() throws {
        XCTAssertEqual(DocumentNumbering.prefix(for: .quotation), "QT")
        XCTAssertEqual(DocumentNumbering.prefix(for: .salesOrder), "SO")
        XCTAssertEqual(DocumentNumbering.prefix(for: .proformaInvoice), "PI")
        XCTAssertEqual(DocumentNumbering.prefix(for: .commercialInvoice), "CI")
        XCTAssertEqual(DocumentNumbering.prefix(for: .statement), "ST")
        XCTAssertEqual(Set(BusinessDocumentType.allCases.map(DocumentNumbering.prefix(for:))).count, 5,
                       "two types sharing a prefix would merge two series into one")
    }

    /// Batch 8 A, first two assertions, on every type rather than just the one the handler test
    /// uses: an empty ledger suggests `<prefix>-<year>-0001`.
    func testAnEmptyLedgerSuggestsTheFirstNumberOfEveryType() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        for type in BusinessDocumentType.allCases {
            XCTAssertEqual(try store.nextBusinessDocumentNumber(for: type, year: year),
                           "\(DocumentNumbering.prefix(for: type))-2026-0001")
        }
    }

    // MARK: - What feeds the maximum and what does not

    /// Batch 8 A's third assertion, plus the shape of the padding: the suffix is read as a number,
    /// so `0007` becomes `0008` and the four-digit pad is applied to the RESULT.
    func testTheSuggestionIsTheHighestMatchingSuffixPlusOne() throws {
        XCTAssertEqual(try suggestion(after: ["QT-2026-0007"]), "QT-2026-0008")
        XCTAssertEqual(try suggestion(after: ["QT-2026-0003", "QT-2026-0011"]), "QT-2026-0012")

        // **The maximum is NUMERIC, and this is the pair that says so.** Zero-padding makes the
        // two orders disagree: `QT-2026-9` is the largest doc_number by text and the smallest by
        // suffix. The insertion order is irrelevant — the query has no `ORDER BY` and SQLite serves
        // it from `idx_docs_type_number`, so both spellings below arrive text-ordered — which is
        // exactly why "the last row" and "the largest" had to be told apart by VALUE.
        XCTAssertEqual(try suggestion(after: ["QT-2026-0011", "QT-2026-9"]), "QT-2026-0012")
        XCTAssertEqual(try suggestion(after: ["QT-2026-9", "QT-2026-0011"]), "QT-2026-0012")
        XCTAssertEqual(try suggestion(after: ["QT-2026-0002", "QT-2026-10", "QT-2026-3"]),
                       "QT-2026-0011", "…and with three rows the text order is 2, 10, 3")
        XCTAssertEqual(try suggestion(after: ["QT-2026-0000009"]), "QT-2026-0010",
                       "leading zeros are part of the number, not part of the width")
        XCTAssertEqual(try suggestion(after: ["QT-2026-9999"]), "QT-2026-10000",
                       "the pad never truncates")
        XCTAssertEqual(try suggestion(after: ["QT-2026-12345"]), "QT-2026-12346")
    }

    /// Batch 8 A's fourth assertion, widened. Every one of these is fetched by the `LIKE` and then
    /// refused by the suffix reader, so the suggestion stays at `0001` — and each is refused for a
    /// DIFFERENT reason, which is why they are listed one by one instead of as "some bad input".
    func testNothingOutsideTheExactShapeFeedsTheMaximum() throws {
        for (number, why) in [
            ("CUSTOM-9999", "the handler test's own case: a user's own numbering scheme"),
            ("qt-2026-0500", "SQLite's LIKE is case-insensitive; the reader's [A-Z] is not"),
            ("Qt-2026-0500", "…and half a match is still no match"),
            ("QT-1999-0500", "another year's series"),
            ("QT-2026-0007x", "trailing text after the digits"),
            ("QT-2026-x0007", "leading text before them"),
            ("QT-2026-", "no digits at all"),
            ("QT-2026-0007-1", "a second group"),
            ("QTX-2026-0007", "a three-letter prefix"),
            ("QT-20261-0007", "a five-digit year"),
            ("QT-2026-٧", "Arabic-Indic digits: \\d is ASCII on both sides"),
            ("QT-2026-７", "…and so are full-width ones"),
            ("QT-2026-0007👍", "an astral character after the digits"),
            (" QT-2026-0007", "leading whitespace"),
            ("QT-2026-0007 ", "trailing whitespace"),
        ] {
            XCTAssertEqual(try suggestion(after: [number]), "QT-2026-0001", why)
        }
        // The control: the SAME seeding path with a well-formed number does move the suggestion, so
        // the fifteen results above are refusals rather than a broken query.
        XCTAssertEqual(try suggestion(after: ["QT-2026-0500"]), "QT-2026-0501")
    }

    /// **A trailing newline is the case a regex would have got wrong.**
    ///
    /// JavaScript's `$` (without `m`) matches only at the very end of the input, so
    /// `"QT-2026-0007\n"` does not match `/^[A-Z]{2}-\d{4}-(\d+)$/`. ICU's `$` — what
    /// `NSRegularExpression` would give — ALSO matches before a final line terminator, so the same
    /// row would have fed the maximum here and not there. Hand-walking the scalars is what avoids
    /// it, and this is the assertion that would have caught the shortcut.
    func testATrailingNewlineIsNotTheEndOfTheStringJavaScriptMeans() throws {
        XCTAssertNil(DocumentNumbering.numericSuffix(of: "QT-2026-0007\n"))
        XCTAssertNil(DocumentNumbering.numericSuffix(of: "QT-2026-0007\r\n"))
        XCTAssertEqual(DocumentNumbering.numericSuffix(of: "QT-2026-0007"), 7, "the control")
        XCTAssertEqual(try suggestion(after: ["QT-2026-0007\n"]), "QT-2026-0001")
        XCTAssertEqual(try suggestion(after: ["QT-2026-0007\n", "QT-2026-0002"]), "QT-2026-0003",
                       "the readable row still counts; only the newline-terminated one is skipped")
    }

    /// The suffix is a JS Number, and past 2^53 that stops being a formality.
    ///
    /// These four expectations came out of the real handler and are not reachable by intuition:
    /// twenty nines still print in full, twenty-one nines tip into exponential notation, and
    /// `+ 1` stops changing anything long before either.
    func testAnOversizedSuffixProducesJavaScriptsOwnExponentialForm() throws {
        XCTAssertEqual(try suggestion(after: ["QT-2026-" + String(repeating: "9", count: 16)]),
                       "QT-2026-10000000000000000")
        XCTAssertEqual(try suggestion(after: ["QT-2026-" + String(repeating: "9", count: 20)]),
                       "QT-2026-100000000000000000000")
        XCTAssertEqual(try suggestion(after: ["QT-2026-" + String(repeating: "9", count: 21)]),
                       "QT-2026-1e+21", "n > 21 is where Number::toString switches")
        XCTAssertEqual(try suggestion(after: ["QT-2026-" + String(repeating: "9", count: 22)]),
                       "QT-2026-1e+22")
        XCTAssertEqual(try suggestion(after: ["QT-2026-" + String(repeating: "9", count: 51)]),
                       "QT-2026-1e+51")
        XCTAssertEqual(try suggestion(after: ["QT-2026-1" + String(repeating: "0", count: 19)]),
                       "QT-2026-10000000000000000000",
                       "adding one to 1e19 changes nothing, and the answer says the same thing")
    }

    // MARK: - The year

    /// `new Date().getFullYear()`: the **local** zone, on the **Gregorian** calendar. Both halves
    /// have a counterexample here, because both are things Swift would do differently by default.
    func testTheYearIsTheLocalGregorianOne() throws {
        // 2025-12-31 23:30 UTC — the same instant is in two different years in two zones.
        var components = DateComponents()
        components.year = 2025; components.month = 12; components.day = 31
        components.hour = 23; components.minute = 30
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        let instant = try XCTUnwrap(utcCalendar.date(from: components))

        XCTAssertEqual(DocumentNumbering.year(at: instant, in: TimeZone(identifier: "UTC")!), 2025)
        XCTAssertEqual(DocumentNumbering.year(at: instant, in: TimeZone(identifier: "Asia/Tokyo")!), 2026,
                       "Q3 registers this: on New Year's Eve two machines suggest different years")
        XCTAssertEqual(DocumentNumbering.year(at: instant, in: TimeZone(identifier: "Pacific/Honolulu")!), 2025)

        // The calendar counterexample: a machine whose region uses the Japanese calendar would get
        // a Reiwa year out of `Calendar.current`, and `QT-8-0001` is not a number this app writes.
        var japanese = Calendar(identifier: .japanese)
        japanese.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        XCTAssertNotEqual(japanese.component(.year, from: instant), 2026,
                          "if this ever equals the Gregorian year, this counterexample is spent")
    }

    /// The shipping entry point reads the clock. Independent construction on purpose: a
    /// `DateFormatter` pinned to the Gregorian calendar and the POSIX locale, rather than a second
    /// call to the function under test.
    func testTheShippingEntryPointUsesTodaysLocalYear() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        XCTAssertEqual(try store.nextBusinessDocumentNumber(for: .quotation), "QT-\(liveYear())-0001")
    }

    /// Today's local Gregorian year, read with a `DateFormatter` rather than with a second call to
    /// the function under test — an independent construction, and the only thing in this file that
    /// depends on what day it is.
    private func liveYear() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy"
        return formatter.string(from: Date())
    }

    // MARK: - Q3 · voiding does not release a number; deleting does

    /// The spec's three-part assertion, measured end to end: after voiding, the number is still
    /// refused AND the series does not step back; after deleting, both go the other way.
    func testVoidingKeepsANumberAndOnlyDeletingGivesItBack() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        let id = try store.createBusinessDocument(
            BusinessDocumentDraft(type: .quotation, number: "QT-2026-0005", date: "2026-01-01",
                                  customerName: "C"))
        XCTAssertEqual(try store.nextBusinessDocumentNumber(for: .quotation, year: year), "QT-2026-0006")

        try store.updateBusinessDocument(id: id, BusinessDocumentEdit(status: .void))
        XCTAssertEqual(try store.nextBusinessDocumentNumber(for: .quotation, year: year), "QT-2026-0006",
                       "the series does not step back over a voided document")
        XCTAssertThrowsError(try store.createBusinessDocument(
            BusinessDocumentDraft(type: .quotation, number: "QT-2026-0005", date: "2026-01-02",
                                  customerName: "C2"))) {
            XCTAssertEqual($0 as? BusinessDocumentError, .numberExists,
                           "a voided document still occupies its number")
        }

        try store.deleteBusinessDocument(id: id)
        XCTAssertEqual(try store.nextBusinessDocumentNumber(for: .quotation, year: year), "QT-2026-0001")
        XCTAssertNoThrow(try store.createBusinessDocument(
            BusinessDocumentDraft(type: .quotation, number: "QT-2026-0005", date: "2026-01-02",
                                  customerName: "C2")), "deleting is what releases it")
    }

    // MARK: - Batch 8 D · DOC_NUMBER_EXISTS

    /// Batch 8 D, all three: the second identical `(doc_type, doc_number)` is refused with the
    /// stable code, and the same number under a different type is not — the index is on the PAIR.
    func testADuplicateIsRefusedPerTypeRatherThanGlobally() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        func draft(_ type: BusinessDocumentType, _ number: String, _ customer: String) -> BusinessDocumentDraft {
            BusinessDocumentDraft(type: type, number: number, date: "2026-01-01", customerName: customer)
        }
        XCTAssertNoThrow(try store.createBusinessDocument(draft(.quotation, "DUP-1", "C")))
        XCTAssertThrowsError(try store.createBusinessDocument(draft(.quotation, "DUP-1", "C2"))) {
            XCTAssertEqual($0 as? BusinessDocumentError, .numberExists)
        }
        XCTAssertNoThrow(try store.createBusinessDocument(draft(.salesOrder, "DUP-1", "C3")))
        XCTAssertEqual(try store.businessDocuments().documents.count, 2)
    }

    /// The same refusal through the edit path — both halves of the pair can move, so both can
    /// collide, and the handler wraps `update` in the same guard for exactly that reason.
    func testAnEditIntoAnOccupiedNumberIsRefusedToo() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        _ = try store.createBusinessDocument(
            BusinessDocumentDraft(type: .quotation, number: "N-1", date: "2026-01-01", customerName: "C"))
        let second = try store.createBusinessDocument(
            BusinessDocumentDraft(type: .quotation, number: "N-2", date: "2026-01-01", customerName: "C"))
        let other = try store.createBusinessDocument(
            BusinessDocumentDraft(type: .salesOrder, number: "N-1", date: "2026-01-01", customerName: "C"))

        XCTAssertThrowsError(try store.updateBusinessDocument(id: second,
                                                             BusinessDocumentEdit(number: "N-1"))) {
            XCTAssertEqual($0 as? BusinessDocumentError, .numberExists)
        }
        XCTAssertThrowsError(try store.updateBusinessDocument(id: other,
                                                             BusinessDocumentEdit(type: .quotation))) {
            XCTAssertEqual($0 as? BusinessDocumentError, .numberExists,
                           "changing the TYPE collides just as changing the number does")
        }
        XCTAssertNoThrow(try store.updateBusinessDocument(id: second, BusinessDocumentEdit(number: "N-3")))
        XCTAssertEqual(try store.businessDocument(id: second)?.document.number, "N-3")
    }

    // MARK: - The refusal survives the connection the app actually ships

    /// **The measurement `ProductCatalog.mapWriteFailure`'s `"(code 19)"` predicate does not
    /// survive.**
    ///
    /// The shipping active store is opened `activeExistingNoFollow`, which sets
    /// `SQLITE_OPEN_EXRESCODE`; `sqlite3_step` then returns the EXTENDED code, and a unique-index
    /// violation reads `(code 2067)` rather than `(code 19)`. This test measures both connection
    /// kinds on the same schema and asserts (a) the two really do report different numbers, and
    /// (b) the mapping answers `numberExists` on both anyway.
    ///
    /// Without (a) this would be a test that passes for the wrong reason on a default connection —
    /// which is exactly how the neighbouring predicate came to be wrong.
    func testTheDuplicateRefusalHoldsOnTheHardenedShippingConnection() throws {
        let directory = try symlinkFreeTempDir()
        let url = directory.appendingPathComponent("active.db")

        var defaultConnectionMessage = ""
        do {
            let store = try LedgerStore(databaseURL: url, open: .createIfMissing)
            try seedDuplicatePair(store)
            defaultConnectionMessage = try captureRawDuplicateMessage(store)
            try store.db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            try store.db.close()
        }

        let hardened = try SQLiteDatabase(path: url.path, mode: .activeExistingNoFollow)
        let store = try LedgerStore(adopting: hardened)
        defer { try? store.db.close() }
        let hardenedMessage = try captureRawDuplicateMessage(store)

        XCTAssertTrue(defaultConnectionMessage.contains("(code 19)"),
                      "default open: \(defaultConnectionMessage)")
        XCTAssertTrue(hardenedMessage.contains("(code 2067)"),
                      "hardened open reports the EXTENDED code: \(hardenedMessage)")
        XCTAssertFalse(hardenedMessage.contains("(code 19)"),
                       "…and a literal \"(code 19)\" test finds nothing to match on this path")

        // The mapping itself, on the connection that ships.
        XCTAssertThrowsError(try store.createBusinessDocument(
            BusinessDocumentDraft(type: .quotation, number: "DUP-1", date: "2026-01-01",
                                  customerName: "C3"))) {
            XCTAssertEqual($0 as? BusinessDocumentError, .numberExists)
        }
    }

    /// The extraction takes the LAST `(code N)` in the message, because the wrapper appends its own
    /// after whatever SQLite said — and what SQLite said can contain a parenthesised number of its
    /// own when a `CHECK` constraint quotes schema text.
    func testTheCodeIsReadFromTheEndOfTheMessageAndOnlyConstraintsMap() {
        XCTAssertTrue(LedgerStore.isConstraintViolation(
            SQLiteError.step("CHECK constraint failed: c IN ('x') (code 5) (code 2067)")),
            "a decoy earlier in the message must not win")
        XCTAssertFalse(LedgerStore.isConstraintViolation(
            SQLiteError.step("UNIQUE constraint failed (code 2067) (code 5)")),
            "…and neither must one later than the real code")
        for code in [19, 275, 787, 1299, 1555, 2067] {
            XCTAssertTrue(LedgerStore.isConstraintViolation(SQLiteError.step("failed (code \(code))")),
                          "every SQLITE_CONSTRAINT_* extended code shares the primary code")
        }
        for code in [5, 6922, 14, 1550, 101] {
            XCTAssertFalse(LedgerStore.isConstraintViolation(SQLiteError.step("failed (code \(code))")),
                           "\(code) is not a constraint and must be rethrown untouched")
        }
        XCTAssertFalse(LedgerStore.isConstraintViolation(SQLiteError.step("no code here at all")))
        XCTAssertFalse(LedgerStore.isConstraintViolation(
            SQLiteError.open(message: "x", primary: 19, extended: 2067, systemErrno: 0)),
            "an open failure carries structured codes and is never a constraint")
        XCTAssertFalse(LedgerStore.isConstraintViolation(BusinessDocumentError.notFound))
    }

    // MARK: - Q2-d ① · N currencies consume N numbers

    /// One statement per currency, numbered in a row, **in the generator's currency-code order**.
    ///
    /// The two currencies are chosen so the order is a measurement rather than a coincidence:
    /// `U+1D400` begins with the surrogate `U+D835`, which is BELOW `U+FFFD` as a UTF-16 code unit
    /// and ABOVE it as a scalar. Comparing with Swift's `<` therefore hands `ST-2026-0001` to the
    /// other one. ISO three-letter codes cannot tell the two orderings apart, which is why they are
    /// not what this test uses.
    func testStatementsTakeConsecutiveNumbersInCurrencyCodeUnitOrder() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        for (index, currency) in ["USD", "CNY", "\u{FFFD}", "\u{1D400}"].enumerated() {
            try store.db.run("""
                INSERT INTO transactions (id, type, date, amount, currency, counterparty)
                VALUES (?, 'income', '2026-01-10', 100, ?, 'Acme')
                """, [.text("t\(index)"), .text(currency)])
        }

        let drafts = try store.statementDrafts(customerName: "Acme",
                                               periodStart: "2026-01-01", periodEnd: "2026-01-31")
        XCTAssertEqual(drafts.map(\.currency), ["CNY", "USD", "\u{1D400}", "\u{FFFD}"],
                       "code-unit order: the astral code sorts before U+FFFD")

        // `createStatements` is the shipping path and reads the clock, so the expected series is
        // built from the live year — the same independent formatter
        // ``testTheShippingEntryPointUsesTodaysLocalYear`` uses. Hard-coding 2026 here would make
        // this test expire on 1 January.
        let live = liveYear()
        let ids = try store.createStatements(drafts, date: "2026-02-01")
        XCTAssertEqual(ids.count, 4)
        let written = try ids.map { try XCTUnwrap(try store.businessDocument(id: $0)?.document) }
        XCTAssertEqual(written.map(\.number),
                       ["ST-\(live)-0001", "ST-\(live)-0002", "ST-\(live)-0003", "ST-\(live)-0004"],
                       "four currencies advance the ST series four places")
        XCTAssertEqual(written.map(\.currency), ["CNY", "USD", "\u{1D400}", "\u{FFFD}"])
        XCTAssertEqual(try store.nextBusinessDocumentNumber(for: .statement), "ST-\(live)-0005")
        XCTAssertEqual(try store.nextBusinessDocumentNumber(for: .quotation), "QT-\(live)-0001",
                       "…and no other series moved")
    }

    // MARK: - helpers

    /// `FileManager.temporaryDirectory` lives under `/var/folders/…` and `/var` is a symlink, which
    /// whole-path `SQLITE_OPEN_NOFOLLOW` refuses outright. The real active store is symlink-free,
    /// so the hardened test canonicalises first — the same reason and the same recipe
    /// `HardenedActiveOpenTests` uses.
    private func symlinkFreeTempDir() throws -> URL {
        let directory = try trackedTempDir()
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(directory.path, &buffer) != nil else { return directory }
        return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
    }

    private func seedDuplicatePair(_ store: LedgerStore) throws {
        _ = try store.createBusinessDocument(
            BusinessDocumentDraft(type: .quotation, number: "DUP-1", date: "2026-01-01",
                                  customerName: "C"))
    }

    /// The raw `SQLiteError` text a duplicate produces on THIS connection, taken by going around
    /// the mapping — which is the only way to see the number the mapping is reading.
    private func captureRawDuplicateMessage(_ store: LedgerStore) throws -> String {
        do {
            try store.db.run("""
                INSERT INTO business_documents (id, doc_type, doc_number, doc_date, customer_name)
                VALUES (?, 'quotation', 'DUP-1', '2026-01-01', 'C2')
                """, [.text("raw-\(UUID().uuidString)")])
            XCTFail("the unique index did not refuse a duplicate")
            return ""
        } catch {
            return "\(error)"
        }
    }
}
