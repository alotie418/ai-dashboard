import XCTest
@testable import SoloLedgerCore

/// D-1 · Q9 — the document store, against `electron/handlers/documents.js`.
///
/// The comparison list is `scripts/test-handlers.mjs` §2B Batch 8. **That section holds 63
/// assertions**, confirmed two ways: 50 `ok(` plus 13 `expectThrow(` between its header and the
/// next one, and 63 occurrences of the `[doc]` tag every one of its assertions carries.
/// `docs/BUSINESS_DOCUMENTS_SPEC.md` §7 recorded 259 until this round; that number came from
/// counting from the Batch 8 header to the END OF THE FILE, which sweeps in eleven later sections.
/// The spec's fourth ruling corrects it.
///
/// Of those 63, **26 are in this round's scope** (create validation 5, create success 8, get/list 7,
/// lines and totals 6) and each has a counterpart below. The other 37 are Q3/Q5 and belong to D-2:
/// `next-number` 6, `DOC_NUMBER_EXISTS` 3, `update` and the status machine 11, the tax-invoice
/// association 9, `remove` 8. None of them is tested here, and nothing here depends on them.
final class BusinessDocumentStoreTests: LedgerTestCase {

    private func draft(type: BusinessDocumentType = .quotation,
                       number: String = "QT-FIX-001",
                       date: String = "2026-02-01",
                       customerName: String = "Acme Co",
                       lines: [BusinessDocumentLineDraft] = [],
                       origin: BusinessDocumentLineOrigin = .handEntered) -> BusinessDocumentDraft {
        BusinessDocumentDraft(type: type, number: number, date: date, customerName: customerName,
                              lines: lines, lineOrigin: origin)
    }

    private func line(_ description: String, amount: Double?, tax: Double? = nil,
                      lineNo: Int? = nil) -> BusinessDocumentLineDraft {
        BusinessDocumentLineDraft(description: description, taxAmount: tax, amount: amount, lineNo: lineNo)
    }

    // MARK: - Batch 8 · B — create validation

    /// Batch 8 B: each missing required field refuses. The fourth assertion there — an invalid
    /// `doc_type` — has no counterpart because ``BusinessDocumentType`` removes those inputs from
    /// the domain; the storage layer's own refusal is measured separately below.
    func testCreateRefusesEachMissingRequiredField() throws {
        let store = try makeStore()
        defer { try? store.db.close() }

        XCTAssertThrowsError(try store.createBusinessDocument(draft(number: ""))) {
            XCTAssertEqual($0 as? BusinessDocumentError, .numberRequired)
        }
        XCTAssertThrowsError(try store.createBusinessDocument(draft(number: "   "))) {
            XCTAssertEqual($0 as? BusinessDocumentError, .numberRequired, "…and one that trims to empty")
        }
        XCTAssertThrowsError(try store.createBusinessDocument(draft(customerName: ""))) {
            XCTAssertEqual($0 as? BusinessDocumentError, .customerNameRequired)
        }
        XCTAssertThrowsError(try store.createBusinessDocument(draft(customerName: "\u{FEFF}"))) {
            XCTAssertEqual($0 as? BusinessDocumentError, .customerNameRequired,
                           "U+FEFF is whitespace to `trim`, so a name of one is empty")
        }
        XCTAssertThrowsError(try store.createBusinessDocument(draft(date: ""))) {
            XCTAssertEqual($0 as? BusinessDocumentError, .dateRequired)
        }
        XCTAssertEqual(try store.businessDocuments().documents.count, 0, "nothing was written")
    }

    /// The handler tests `doc_date` for falsiness, not for blankness — so a date of one space is
    /// accepted, and stored verbatim. Reproduced rather than tidied (Q9).
    func testABlankButNonEmptyDateIsAcceptedAndStoredVerbatim() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        let id = try store.createBusinessDocument(draft(date: " "))
        XCTAssertEqual(try store.businessDocument(id: id)?.document.date, " ")
    }

    /// The clamp runs BEFORE the trim, which is the order `safeString(v, n)` then `.trim()` gives.
    /// Reversing them would keep text the handler discards.
    func testTheLengthClampRunsBeforeTheTrim() throws {
        let store = try makeStore()
        defer { try? store.db.close() }

        // 60 characters of text, then more text. The clamp keeps the first 60; the trim finds no
        // whitespace to remove, so the tail is simply gone.
        let long = String(repeating: "N", count: 60) + "TAIL"
        let id = try store.createBusinessDocument(draft(number: long))
        XCTAssertEqual(try store.businessDocument(id: id)?.document.number,
                       String(repeating: "N", count: 60))

        // 3 characters of text, then 57 spaces, then more text: the clamp cuts at 60 — inside the
        // spaces — and the trim then removes them, so the tail is gone AND the spaces are gone.
        let spaced = "ABC" + String(repeating: " ", count: 57) + "TAIL"
        let id2 = try store.createBusinessDocument(draft(number: spaced, date: "2026-02-02"))
        XCTAssertEqual(try store.businessDocument(id: id2)?.document.number, "ABC",
                       "trimming BEFORE clamping would have kept part of TAIL")
    }

    /// **The clamp counts UTF-16 code units, end to end, and the bytes in the column match what a
    /// real `better-sqlite3` writes.**
    ///
    /// Each expectation below was measured by running `documents.js`'s own `safeString(v, n)` in
    /// node and binding the result through `better-sqlite3`, then reading `hex()` back out — the
    /// same three quantities this test reads from SQLite here:
    ///
    /// ```text
    ///   field        input              cut  sqlite length()  utf8 bytes  last 4 bytes
    ///   doc_number   "A" + 30 emoji      60        31            120      8D EF BF BD
    ///   customer     "A" + 100 emoji    200       101            400      8D EF BF BD
    ///   description  "A" + 250 emoji    500       251           1000      8D EF BF BD
    ///   unit         15 emoji + "X"      30        15             60      F0 9F 91 8D
    /// ```
    ///
    /// The three ending `EF BF BD` are the cuts that fall INSIDE a surrogate pair; the `unit` row
    /// is the control — its cut lands on a pair boundary, so nothing is replaced and the trailing
    /// `X` is simply gone.
    ///
    /// Expectations are byte ARRAYS rather than hex strings on purpose: a hex literal of the right
    /// length reads as an Apple Team ID to `SigningConfigurationGuardTests`, which caught the first
    /// draft of this test. Bytes are also the thing actually being claimed.
    func testEveryClampCutsAtTheSameCodeUnitElectronDoes() throws {
        let store = try makeStore()
        defer { try? store.db.close() }

        let thumb = "\u{1F44D}"
        var input = draft(number: "A" + String(repeating: thumb, count: 30),
                          customerName: "A" + String(repeating: thumb, count: 100),
                          lines: [BusinessDocumentLineDraft(
                            description: "A" + String(repeating: thumb, count: 250),
                            unit: String(repeating: thumb, count: 15) + "X",
                            amount: 1)])
        input.accountingLocale = .CN
        let id = try store.createBusinessDocument(input)

        /// The stored cell as SQLite holds it: its bytes, and the character count `length()` gives.
        func stored(_ column: String, _ table: String, _ key: String) throws -> (bytes: [UInt8], length: Int) {
            let row = try XCTUnwrap(try store.db.query(
                "SELECT \(column) AS v, length(\(column)) AS n FROM \(table) WHERE \(key) = ?",
                [.text(id)]).first)
            return (Array(try XCTUnwrap(row.string("v")).utf8), try XCTUnwrap(row.int("n")))
        }

        let replacement: [UInt8] = [0xEF, 0xBF, 0xBD]   // U+FFFD, one per unpaired surrogate
        let thumbBytes: [UInt8] = [0xF0, 0x9F, 0x91, 0x8D]

        for (column, table, key, length, byteCount) in [
            ("doc_number", "business_documents", "id", 31, 120),
            ("customer_name", "business_documents", "id", 101, 400),
            ("description", "business_document_items", "doc_id", 251, 1000),
        ] {
            let cell = try stored(column, table, key)
            XCTAssertEqual(cell.length, length, "\(column) character count")
            XCTAssertEqual(cell.bytes.count, byteCount, "\(column) byte count")
            XCTAssertEqual(Array(cell.bytes.suffix(3)), replacement,
                           "\(column) must end in the replacement character the JS side stores")
            XCTAssertEqual(Array(cell.bytes.suffix(7).prefix(4)), thumbBytes,
                           "\(column): a whole emoji precedes it, so exactly one unit was lost")
        }

        // The control: a clean cut, so nothing is replaced and the trailing "X" is simply gone.
        let unit = try stored("unit", "business_document_items", "doc_id")
        XCTAssertEqual(unit.length, 15)
        XCTAssertEqual(unit.bytes.count, 60)
        XCTAssertEqual(Array(unit.bytes.suffix(4)), thumbBytes)
        XCTAssertFalse(unit.bytes.contains(0xEF), "nothing was replaced on a clean boundary")
        XCTAssertFalse(unit.bytes.contains(UInt8(ascii: "X")), "…and the character past the cut is gone")
    }

    // MARK: - Batch 8 · C — create success

    /// Batch 8 C, all eight assertions: the id is the store's own, the status defaults to draft,
    /// the accounting regime is frozen, the number and customer persist, both lines land, and the
    /// header totals are Σ amount / Σ tax / their sum.
    func testCreatePersistsTheHeaderTheLinesAndTheThreeTotals() throws {
        let store = try makeStore()
        defer { try? store.db.close() }

        var input = draft(lines: [line("Item A", amount: 100, tax: 13),
                                  line("Item B", amount: 200, tax: 26)])
        input.accountingLocale = .CN
        let id = try store.createBusinessDocument(input)

        XCTAssertTrue(id.hasPrefix("doc-"), "the store mints the id; the caller cannot supply one")
        let detail = try XCTUnwrap(try store.businessDocument(id: id))
        XCTAssertEqual(detail.document.status, .draft)
        XCTAssertEqual(detail.document.accountingLocale, .CN)
        XCTAssertEqual(detail.document.number, "QT-FIX-001")
        XCTAssertEqual(detail.document.customerName, "Acme Co")
        XCTAssertEqual(detail.items.count, 2)
        XCTAssertEqual(detail.document.subtotal, 300)
        XCTAssertEqual(detail.document.taxAmount, 39)
        XCTAssertEqual(detail.document.total, 339)
    }

    /// Two documents created in the same instant get different ids. Electron needs a random suffix
    /// for this because `Date.now()` has millisecond resolution; a UUID has no such window.
    func testEveryCreatedDocumentGetsItsOwnID() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        var ids = Set<String>()
        for i in 0..<50 { ids.insert(try store.createBusinessDocument(draft(number: "N-\(i)"))) }
        XCTAssertEqual(ids.count, 50)
    }

    /// Batch 8 C's last assertion: the regime comes from the request when it names one, and from
    /// the ledger's setting when it does not — `resolveAccLocale`, both branches.
    func testTheAccountingRegimeIsFrozenFromTheRequestOrElseFromTheSetting() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        try store.settings.setString(AccountingLocale.CN.rawValue, for: SettingsStore.Key.accountingLocale)

        var explicit = draft(number: "QT-JP")
        explicit.accountingLocale = .JP
        let jp = try store.createBusinessDocument(explicit)
        XCTAssertEqual(try store.businessDocument(id: jp)?.document.accountingLocale, .JP,
                       "the request's regime wins over the setting")

        let inherited = try store.createBusinessDocument(draft(number: "QT-CN"))
        XCTAssertEqual(try store.businessDocument(id: inherited)?.document.accountingLocale, .CN)

        try store.settings.setString(AccountingLocale.EU.rawValue, for: SettingsStore.Key.accountingLocale)
        let later = try store.createBusinessDocument(draft(number: "QT-EU"))
        XCTAssertEqual(try store.businessDocument(id: later)?.document.accountingLocale, .EU)
        XCTAssertEqual(try store.businessDocument(id: inherited)?.document.accountingLocale, .CN,
                       "…and the regime already frozen on an existing document does not follow it")
    }

    /// The four `tax_invoice_*` columns are omitted from the `INSERT`, exactly as the handler omits
    /// them, so they take their schema defaults. Writing them is D-2's.
    func testCreateWritesNoTaxInvoiceAssociation() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        let id = try store.createBusinessDocument(draft())
        let document = try XCTUnwrap(try store.businessDocument(id: id)?.document)
        XCTAssertFalse(document.taxInvoiceIssued)
        XCTAssertNil(document.taxInvoiceNumber)
        XCTAssertNil(document.taxInvoiceDate)
        XCTAssertNil(document.taxInvoiceAttachmentPath)
    }

    // MARK: - Batch 8 · F — lines and totals

    /// Batch 8 F, all six: a blank-description line is dropped, the survivors order by `line_no`,
    /// and the totals count only what was stored.
    func testABlankDescriptionDropsItsLineAndTheTotalsFollow() throws {
        let store = try makeStore()
        defer { try? store.db.close() }

        let id = try store.createBusinessDocument(draft(lines: [
            line("second", amount: 50, tax: 5, lineNo: 2),
            line("first", amount: 100, tax: 13, lineNo: 1),
            line("   ", amount: 999, tax: 999),
        ]))

        let detail = try XCTUnwrap(try store.businessDocument(id: id))
        XCTAssertEqual(detail.items.count, 2)
        XCTAssertEqual(try at(detail.items, 0).lineNo, 1)
        XCTAssertEqual(try at(detail.items, 0).description, "first")
        XCTAssertEqual(try at(detail.items, 1).lineNo, 2)
        XCTAssertEqual(try at(detail.items, 1).description, "second")
        XCTAssertEqual(detail.document.subtotal, 150, "the dropped line's 999 is not in the total")
        XCTAssertEqual(detail.document.taxAmount, 18)
        XCTAssertEqual(detail.document.total, 168)
    }

    /// An absent `line_no` takes the line's index among the lines that SURVIVED the filter, not
    /// among the lines submitted — `sanitizeItems` maps after it filters.
    func testAnAbsentLineNumberTakesTheIndexAfterTheFilterNotBefore() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        let id = try store.createBusinessDocument(draft(lines: [
            line("  ", amount: 1),
            line("kept A", amount: 10),
            line("", amount: 2),
            line("kept B", amount: 20),
        ]))
        let items = try store.businessDocumentItems(documentID: id)
        XCTAssertEqual(items.map(\.lineNo), [0, 1], "indices 1 and 3 before the filter, 0 and 1 after")
        XCTAssertEqual(items.map(\.description), ["kept A", "kept B"])
    }

    /// Line text is trimmed and then clamped to 500 — the opposite order from the header's number,
    /// and that asymmetry is in the handler rather than in this port.
    func testALineDescriptionIsTrimmedThenClampedTo500() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        let padded = "  " + String(repeating: "D", count: 600) + "  "
        let id = try store.createBusinessDocument(draft(lines: [line(padded, amount: 1)]))
        let stored = try XCTUnwrap(try store.businessDocumentItems(documentID: id).first?.description)
        XCTAssertEqual(stored.count, 500)
        XCTAssertEqual(stored, String(repeating: "D", count: 500))
    }

    /// A document with no lines is legal — the handler accepts an empty `items` array and writes a
    /// header with three zero totals. The "at least one line" rule lives in the editor, not here.
    func testADocumentWithNoLinesIsWrittenWithZeroTotals() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        let id = try store.createBusinessDocument(draft())
        let detail = try XCTUnwrap(try store.businessDocument(id: id))
        XCTAssertEqual(detail.items.count, 0)
        XCTAssertEqual(detail.document.subtotal, 0)
        XCTAssertEqual(detail.document.taxAmount, 0)
        XCTAssertEqual(detail.document.total, 0)
    }

    // MARK: - Batch 8 · E — get and list

    /// Batch 8 E: the type filter, the unfiltered read, `doc_date DESC` ordering, and the
    /// not-found case. The handler's fifth branch — refusing a type outside the closed set — is
    /// unrepresentable through this API.
    func testListFiltersByTypeAndOrdersByDateDescending() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        let q1 = try store.createBusinessDocument(draft(number: "L-1", date: "2026-01-01",
                                                        customerName: "C1",
                                                        lines: [line("x", amount: 10)]))
        _ = try store.createBusinessDocument(draft(number: "L-2", date: "2026-03-01", customerName: "C2"))
        _ = try store.createBusinessDocument(draft(type: .salesOrder, number: "SO-1",
                                                   date: "2026-02-01", customerName: "C3"))

        let detail = try XCTUnwrap(try store.businessDocument(id: q1))
        XCTAssertEqual(detail.document.id, q1)
        XCTAssertEqual(detail.items.count, 1)

        let quotations = try store.businessDocuments(type: .quotation)
        XCTAssertEqual(quotations.documents.count, 2)
        XCTAssertTrue(quotations.documents.allSatisfy { $0.type == .quotation })
        XCTAssertEqual(quotations.documents.map(\.number), ["L-2", "L-1"], "doc_date DESC")

        XCTAssertEqual(try store.businessDocuments().documents.count, 3, "no filter means every type")
        XCTAssertEqual(try store.businessDocuments(type: .statement).documents.count, 0)
        XCTAssertNil(try store.businessDocument(id: "nope"), "the handler's 'Document not found'")
    }

    /// A header that cannot be identified is counted rather than dropped, so a list is never
    /// silently shorter than the table. Nothing in this package writes such a row — this one is
    /// planted with a BLOB in a `TEXT NOT NULL` column, which a non-`STRICT` table accepts.
    func testAnUnidentifiableHeaderIsCountedRatherThanDropped() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        _ = try store.createBusinessDocument(draft())

        try store.db.run("""
            INSERT INTO business_documents (id, doc_type, doc_number, doc_date, customer_name)
            VALUES ('blob-1', 'quotation', 'B-1', '2026-01-01', ?)
            """, [.blob(Data([0xFF, 0xFE]))])

        let page = try store.businessDocuments()
        XCTAssertEqual(page.documents.count, 1)
        XCTAssertEqual(page.unreadableCount, 1)
        XCTAssertEqual(try store.db.query("SELECT COUNT(*) AS c FROM business_documents").first?.int("c"), 2,
                       "…and the row really is in the table")
    }

    // MARK: - Q1 · the closed set at the storage layer

    /// The type parameter makes an out-of-set `doc_type` unrepresentable; this measures the OTHER
    /// half of Q1's assertion — that a value written past this API is refused by the table rather
    /// than stored.
    func testTheSchemaRefusesADocumentTypeOutsideTheClosedSet() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        XCTAssertThrowsError(try store.db.run("""
            INSERT INTO business_documents (id, doc_type, doc_number, doc_date, customer_name)
            VALUES ('x', 'receipt', 'R-1', '2026-01-01', 'C')
            """))
        XCTAssertEqual(BusinessDocumentType.allCases.count, 5)
        XCTAssertEqual(Set(BusinessDocumentType.allCases.map(\.rawValue)),
                       ["quotation", "sales_order", "proforma_invoice", "commercial_invoice", "statement"])
        // The control: the same statement with a type from the set succeeds, so the refusal above
        // is the CHECK and not a typo in the SQL.
        XCTAssertNoThrow(try store.db.run("""
            INSERT INTO business_documents (id, doc_type, doc_number, doc_date, customer_name)
            VALUES ('y', 'statement', 'R-1', '2026-01-01', 'C')
            """))
    }

    // MARK: - Storage forms that are registered rather than fixed

    /// Non-finite money is silently stored as `0`, because `round2` runs its input through `num()`.
    /// This is the handler's behaviour and Q9 says to reproduce it. It is NOT the transactions
    /// path's rule, which refuses instead — the two mirrors differ and so do the two policies.
    func testANonFiniteLineAmountIsSilentlyStoredAsZero() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        let id = try store.createBusinessDocument(draft(lines: [
            line("infinite", amount: .infinity, tax: .nan),
        ]))
        let item = try XCTUnwrap(try store.businessDocumentItems(documentID: id).first)
        XCTAssertEqual(item.amount, 0)
        XCTAssertEqual(item.taxAmount, 0)
        XCTAssertEqual(try store.businessDocument(id: id)?.document.total, 0)
    }

    /// `quantity` and `unitPrice` take `num(v, null)`, whose fallback is `null` rather than `0` —
    /// so a non-finite one lands as SQL `NULL`, not as a zero somebody could mistake for a reading.
    /// The two money columns and the two measurement columns really do differ.
    func testANonFiniteQuantityIsStoredAsNullRatherThanZero() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        var draftLine = line("q", amount: 1)
        draftLine.quantity = .infinity
        draftLine.unitPrice = .nan
        let id = try store.createBusinessDocument(draft(lines: [draftLine]))
        let item = try XCTUnwrap(try store.businessDocumentItems(documentID: id).first)
        XCTAssertNil(item.quantity)
        XCTAssertNil(item.unitPrice)
    }

    // MARK: - Q2-d-② · the currency column has exactly one writer

    /// Every hand-entered document, of every type, stores `NULL` — the Q8 reading, "derive the
    /// display currency from `acc_locale`". This is the outcome the ruling asks for, measured on
    /// the whole closed set rather than on one type.
    func testEveryHandEnteredDocumentTypeStoresANullCurrency() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        for (index, type) in BusinessDocumentType.allCases.enumerated() {
            let id = try store.createBusinessDocument(draft(type: type, number: "N-\(index)"))
            XCTAssertNil(try store.businessDocument(id: id)?.document.currency,
                         "\(type.rawValue) acquired a currency it is not allowed to record")
        }
        XCTAssertEqual(try store.businessDocuments().documents.count, BusinessDocumentType.allCases.count)
    }

    /// **The boundary refuses; it does not trust and it does not silently drop.** A draft carrying
    /// a currency is rejected unless it is a statement whose lines came from the generator — the
    /// two halves of Q2-d-②'s own sentence. All three ways of getting it wrong are covered, because
    /// each is a different mistake a later round could make.
    func testACurrencyIsRefusedForAnythingButAGeneratedStatement() throws {
        let store = try makeStore()
        defer { try? store.db.close() }

        // (1) an ordinary hand-entered document that was handed a currency
        var handEntered = draft(number: "QT-USD")
        handEntered.currency = "USD"
        XCTAssertThrowsError(try store.createBusinessDocument(handEntered)) {
            XCTAssertEqual($0 as? BusinessDocumentError, .currencyIsGeneratedStatementsOnly)
        }

        // (2) the right TYPE but the wrong provenance — a statement somebody typed by hand
        var typedStatement = draft(type: .statement, number: "ST-TYPED")
        typedStatement.currency = "USD"
        XCTAssertThrowsError(try store.createBusinessDocument(typedStatement)) {
            XCTAssertEqual($0 as? BusinessDocumentError, .currencyIsGeneratedStatementsOnly,
                           "the type alone must not be enough")
        }

        // (3) the right PROVENANCE but the wrong type — a generated draft retyped afterwards
        var retyped = draft(type: .quotation, number: "QT-RETYPED", origin: .statementGenerator)
        retyped.currency = "USD"
        XCTAssertThrowsError(try store.createBusinessDocument(retyped)) {
            XCTAssertEqual($0 as? BusinessDocumentError, .currencyIsGeneratedStatementsOnly,
                           "the provenance alone must not be enough either")
        }

        XCTAssertEqual(try store.businessDocuments().documents.count, 0, "and none of the three landed")
    }

    /// A statement whose lines came from the generator and that carries NO currency is still fine —
    /// the guard is about a value being present, not about statements being special.
    func testAGeneratedStatementWithoutACurrencyIsAccepted() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        let id = try store.createBusinessDocument(draft(type: .statement, number: "ST-NIL",
                                                        origin: .statementGenerator))
        XCTAssertNil(try store.businessDocument(id: id)?.document.currency)
    }

    /// The header and its lines are written in one transaction, so a failure part way through
    /// leaves neither. The fault is injected with a trigger — the ledger's own machinery, so the
    /// production write path is exercised exactly as it ships.
    func testAFailureWritingALineRollsBackTheHeaderToo() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        try store.db.execute("""
            CREATE TRIGGER refuse_items BEFORE INSERT ON business_document_items
            BEGIN SELECT RAISE(ABORT, 'injected'); END;
            """)

        XCTAssertThrowsError(try store.createBusinessDocument(draft(lines: [line("a", amount: 1)])))
        XCTAssertEqual(try store.businessDocuments().documents.count, 0,
                       "the header must not survive its own lines failing")
        XCTAssertEqual(try store.db.query("SELECT COUNT(*) AS c FROM business_documents").first?.int("c"), 0)

        try store.db.execute("DROP TRIGGER refuse_items")
        XCTAssertNoThrow(try store.createBusinessDocument(draft(lines: [line("a", amount: 1)])),
                         "…and the same write succeeds once the injected fault is removed")
    }

    // MARK: - Q5 · the boundary this chapter must not cross

    /// Q5's first two boundary assertions, measured rather than asserted in prose: creating
    /// documents produces no transaction and no inventory movement.
    func testWritingDocumentsTouchesNeitherTheLedgerNorTheInventory() throws {
        let store = try makeStore()
        defer { try? store.db.close() }

        func count(_ table: String) throws -> Int {
            try store.db.query("SELECT COUNT(*) AS c FROM \(table)").first?.int("c") ?? -1
        }
        // The control: these tables exist and are readable, so a zero below is a measurement.
        XCTAssertEqual(try count("transactions"), 0)
        XCTAssertEqual(try count("inventory_movements"), 0)

        _ = try store.createBusinessDocument(draft(lines: [line("a", amount: 10, tax: 1)]))
        _ = try store.createBusinessDocument(draft(type: .commercialInvoice, number: "CI-1",
                                                   lines: [line("b", amount: 20, tax: 2)]))

        XCTAssertEqual(try count("transactions"), 0, "signing nothing, posting nothing")
        XCTAssertEqual(try count("inventory_movements"), 0)
        XCTAssertEqual(try count("inventory_balances"), 0)
        XCTAssertEqual(try count("business_documents"), 2, "…while the documents themselves landed")
    }
}

/// Index without a trap.
///
/// A bare subscript on a list an assertion has just been wrong about takes the WHOLE suite down
/// rather than failing one test — the mutation campaign for this round produced exactly that (a
/// mutation that collapsed the currency split left no test summary at all, only a crash). This
/// fails the one test and stops it, which is what a reverse proof needs to be readable.
private func at<T>(_ items: [T], _ index: Int,
                   file: StaticString = #filePath, line: UInt = #line) throws -> T {
    try XCTUnwrap(items.indices.contains(index) ? items[index] : nil,
                  "index \(index) is out of range for \(items.count) element(s)",
                  file: file, line: line)
}
