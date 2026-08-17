import XCTest
@testable import SoloLedgerCore

/// D-1 · Q2 — the statement generator, the one invention this chapter accepts.
///
/// There is no Electron counterpart to compare against: `generateStatement` reads the `sales` table
/// and the native ledger has none, which is the whole reason for the redirection. So the oracle
/// here is `docs/BUSINESS_DOCUMENTS_SPEC.md` Q2 itself, clause by clause, plus the three rulings
/// this round asked for and received:
///
///  * a source transaction with **no description keeps its line**, stored as `""`;
///  * a source transaction with **no tax keeps SQL `NULL`**, not a zero;
///  * the per-currency documents come out in **currency-code order**.
final class StatementGeneratorTests: LedgerTestCase {

    /// Insert straight into `transactions` rather than through `LedgerStore.create`, because the
    /// `Transaction` model cannot express two of the states under test: its `taxAmount` is a
    /// non-optional `Double`, and `normalized()` rewrites an empty currency to `"CNY"`.
    @discardableResult
    private func insert(_ store: LedgerStore,
                        id: String,
                        date: String,
                        counterparty: String?,
                        description: SQLiteValue = .null,
                        amount: Double,
                        amountNet: SQLiteValue = .null,
                        taxAmount: SQLiteValue = .null,
                        currency: SQLiteValue = .text("CNY"),
                        type: TransactionType = .income) throws -> String {
        try store.db.run("""
            INSERT INTO transactions (id, type, date, amount, amount_net, tax_amount, currency,
                                      counterparty, description)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [.text(id), .text(type.rawValue), .text(date), .real(amount), amountNet, taxAmount,
                  currency, counterparty.map { SQLiteValue.text($0) } ?? .null, description])
        return id
    }

    // MARK: - Q2 · 1–3 — which rows are selected

    /// The three selection clauses at once, each with a row that must be excluded for exactly one
    /// reason, plus both boundary days.
    func testTheSelectionIsIncomeThisCustomerAndTheClosedInterval() throws {
        let store = try makeStore()
        defer { try? store.db.close() }

        try insert(store, id: "in-start", date: "2026-01-01", counterparty: "Acme", amount: 10)
        try insert(store, id: "in-mid", date: "2026-01-15", counterparty: "Acme", amount: 20)
        try insert(store, id: "in-end", date: "2026-01-31", counterparty: "Acme", amount: 30)
        try insert(store, id: "out-before", date: "2025-12-31", counterparty: "Acme", amount: 40)
        try insert(store, id: "out-after", date: "2026-02-01", counterparty: "Acme", amount: 50)
        try insert(store, id: "out-expense", date: "2026-01-15", counterparty: "Acme", amount: 60,
                   type: .expense)
        try insert(store, id: "out-other", date: "2026-01-15", counterparty: "Beta", amount: 70)

        let drafts = try store.statementDrafts(customerName: "Acme",
                                               periodStart: "2026-01-01", periodEnd: "2026-01-31")
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(try at(drafts, 0).lines.map(\.refSalesID), ["in-start", "in-mid", "in-end"],
                       "both boundary days are included and nothing else is")
        XCTAssertEqual(try at(drafts, 0).lines.map(\.amount), [10, 20, 30])
    }

    /// A customer with nothing in the period produces no documents at all — not one empty one.
    func testACustomerWithNoIncomeInThePeriodProducesNoDocuments() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        try insert(store, id: "t1", date: "2026-03-01", counterparty: "Acme", amount: 10)
        XCTAssertEqual(try store.statementDrafts(customerName: "Acme",
                                                 periodStart: "2026-01-01",
                                                 periodEnd: "2026-01-31").count, 0)
    }

    /// Lines come out in `date, id` order. Electron sorts by date alone and inherits its source
    /// order for ties; `id` is this side's tiebreak, chosen because it is deterministic.
    func testLinesAreOrderedByDateThenID() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        try insert(store, id: "c", date: "2026-01-02", counterparty: "Acme", amount: 1)
        try insert(store, id: "b", date: "2026-01-01", counterparty: "Acme", amount: 2)
        try insert(store, id: "a", date: "2026-01-01", counterparty: "Acme", amount: 3)

        let drafts = try store.statementDrafts(customerName: "Acme",
                                               periodStart: "2026-01-01", periodEnd: "2026-01-31")
        XCTAssertEqual(try at(drafts, 0).lines.map(\.refSalesID), ["a", "b", "c"])
    }

    // MARK: - Q2-c · the one normalisation

    /// Q2-c's own testable assertion: `" Acme "` and `"Acme"` are one customer, the picker offers
    /// it once, and picking it collects BOTH spellings' money.
    func testTrimmedSpellingsAreOneCustomerForBothThePickerAndTheFilter() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        try insert(store, id: "padded", date: "2026-01-05", counterparty: " Acme ", amount: 10)
        try insert(store, id: "bare", date: "2026-01-06", counterparty: "Acme", amount: 20)
        try insert(store, id: "tabbed", date: "2026-01-07", counterparty: "\tAcme\n", amount: 30)

        let names = try store.statementCustomerNames()
        XCTAssertEqual(names, ["Acme"], "the picker offers one entry, not three")

        let drafts = try store.statementDrafts(customerName: try at(names, 0),
                                               periodStart: "2026-01-01", periodEnd: "2026-01-31")
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(try at(drafts, 0).lines.map(\.refSalesID), ["padded", "bare", "tabbed"],
                       "all three spellings' money, in date order")
        XCTAssertEqual(try at(drafts, 0).customerName, "Acme")

        // …and the third clause: the two sides judge the same strings the same way, because they
        // call the same function.
        for spelling in [" Acme ", "Acme", "\tAcme\n", "\u{FEFF}Acme"] {
            XCTAssertTrue(StatementText.areEqual(StatementText.normalized(spelling), try at(names, 0)),
                          "\(String(reflecting: spelling)) normalises to something the picker offers")
        }
    }

    /// Empty and whitespace-only counterparties are dropped from the picker, and a `NULL` one is
    /// dropped for the same reason — `filter(Boolean)` on the trimmed string.
    func testThePickerDropsNamesThatTrimToNothing() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        try insert(store, id: "n1", date: "2026-01-01", counterparty: nil, amount: 1)
        try insert(store, id: "n2", date: "2026-01-01", counterparty: "", amount: 1)
        try insert(store, id: "n3", date: "2026-01-01", counterparty: "   ", amount: 1)
        try insert(store, id: "n4", date: "2026-01-01", counterparty: "\u{FEFF}", amount: 1)
        try insert(store, id: "n5", date: "2026-01-01", counterparty: "Real", amount: 1)
        XCTAssertEqual(try store.statementCustomerNames(), ["Real"])
    }

    /// The picker is ordered by UTF-16 code units, which is JS's default comparator and NOT
    /// Swift's. Measured in node: `["\u{FFFD}x", "\u{1D400}x"].sort()` puts the astral one FIRST,
    /// because its first code unit is the surrogate U+D835 — below U+FFFD. Swift's own `sorted()`
    /// compares scalars and answers the other way round.
    func testThePickerIsOrderedByCodeUnitsRatherThanByScalars() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        try insert(store, id: "a", date: "2026-01-01", counterparty: "\u{FFFD}x", amount: 1)
        try insert(store, id: "b", date: "2026-01-01", counterparty: "\u{1D400}x", amount: 1)

        XCTAssertEqual(try store.statementCustomerNames(), ["\u{1D400}x", "\u{FFFD}x"])
        XCTAssertEqual(["\u{FFFD}x", "\u{1D400}x"].sorted(), ["\u{1D400}x", "\u{FFFD}x"].sorted(),
                       "…and Swift's own sort is stable about this, so the control is meaningful")
        XCTAssertNotEqual(try store.statementCustomerNames(), ["\u{FFFD}x", "\u{1D400}x"].sorted(),
                          "Swift's sorted() answers the other order, which is why this is not it")
    }

    /// **Canonical equivalence must not be applied.** A precomposed `é` and a decomposed `e` +
    /// U+0301 render identically and Swift's `==` calls them equal; JS's `===` does not, and Q2 · 2
    /// says exact equality with no folding of any kind. Getting this wrong merges two picker
    /// entries and then pulls both customers' money onto one statement.
    func testTwoSpellingsOfTheSameLookingNameStayTwoCustomers() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        let precomposed = "Jos\u{00E9}"
        let decomposed = "Jose\u{0301}"
        XCTAssertEqual(precomposed, decomposed, "Swift's own == calls these equal — that is the trap")
        XCTAssertFalse(StatementText.areEqual(precomposed, decomposed), "JS's === does not")

        try insert(store, id: "pre", date: "2026-01-01", counterparty: precomposed, amount: 10)
        try insert(store, id: "dec", date: "2026-01-02", counterparty: decomposed, amount: 20)

        XCTAssertEqual(try store.statementCustomerNames().count, 2, "two picker entries, not one")

        let drafts = try store.statementDrafts(customerName: precomposed,
                                               periodStart: "2026-01-01", periodEnd: "2026-01-31")
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(try at(drafts, 0).lines.map(\.refSalesID), ["pre"],
                       "the decomposed spelling's money belongs to the other customer")
    }

    /// Registered consequence of Q2 · 4 naming the column rather than a subset of it: a name that
    /// only ever appears on expenses is offered by the picker, and picking it yields no documents.
    /// Electron cannot show this — its picker reads `sales.customer` — but the native ledger has
    /// one counterparty namespace and nothing that distinguishes a supplier from a customer.
    func testASupplierAppearsInThePickerAndProducesNothing() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        try insert(store, id: "e1", date: "2026-01-05", counterparty: "Supplier", amount: 10,
                   type: .expense)
        XCTAssertEqual(try store.statementCustomerNames(), ["Supplier"])
        XCTAssertEqual(try store.statementDrafts(customerName: "Supplier",
                                                 periodStart: "2026-01-01",
                                                 periodEnd: "2026-01-31").count, 0)
    }

    // MARK: - Q2-a · the field mapping

    /// `COALESCE(amount_net, amount)` is an explicit `NULL` test, not a falsy one: a tax-exclusive
    /// amount of exactly `0` must survive as `0` rather than falling back to the gross figure.
    func testTheAmountFallsBackOnNullOnlyAndKeepsAZeroNetAmount() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        try insert(store, id: "null-net", date: "2026-01-01", counterparty: "Acme",
                   amount: 118, amountNet: .null)
        try insert(store, id: "zero-net", date: "2026-01-02", counterparty: "Acme",
                   amount: 118, amountNet: .real(0))
        try insert(store, id: "real-net", date: "2026-01-03", counterparty: "Acme",
                   amount: 118, amountNet: .real(100))

        let drafts = try store.statementDrafts(customerName: "Acme",
                                               periodStart: "2026-01-01", periodEnd: "2026-01-31")
        XCTAssertEqual(try at(drafts, 0).lines.map(\.amount), [118, 0, 100],
                       "a falsy fallback would answer 118 for the middle one")
    }

    /// The tax is copied as it stands, `NULL` included — the ruling this round asked for. A
    /// statement line whose source recorded no tax must read back as *no tax recorded*, so the
    /// presentation layer can show a dash instead of a zero nobody entered.
    func testAMissingTaxStaysNullAllTheWayIntoTheTable() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        try insert(store, id: "no-tax", date: "2026-01-01", counterparty: "Acme", amount: 100,
                   taxAmount: .null)
        try insert(store, id: "zero-tax", date: "2026-01-02", counterparty: "Acme", amount: 100,
                   taxAmount: .real(0))
        try insert(store, id: "some-tax", date: "2026-01-03", counterparty: "Acme", amount: 100,
                   taxAmount: .real(13))

        let draft = try XCTUnwrap(try store.statementDrafts(customerName: "Acme",
                                                            periodStart: "2026-01-01",
                                                            periodEnd: "2026-01-31").first)
        XCTAssertEqual(draft.lines.map(\.taxAmount), [nil, 0, 13], "in the draft")

        let id = try store.createBusinessDocument(draft.documentDraft(number: "ST-1", date: "2026-02-01"))
        let items = try store.businessDocumentItems(documentID: id)
        XCTAssertEqual(items.map(\.taxAmount), [nil, 0, 13], "…and after the round trip through SQLite")

        // The distinction is real at the storage layer, not just in the decoded model.
        let nulls = try store.db.query("""
            SELECT COUNT(*) AS c FROM business_document_items
             WHERE doc_id = ? AND tax_amount IS NULL
            """, [.text(id)]).first?.int("c")
        XCTAssertEqual(nulls, 1, "exactly one row holds SQL NULL")

        // And the header still adds up: `num(NULL)` is 0, so the missing tax contributes nothing.
        XCTAssertEqual(try store.businessDocument(id: id)?.document.taxAmount, 13)
        XCTAssertEqual(try store.businessDocument(id: id)?.document.subtotal, 300)
        XCTAssertEqual(try store.businessDocument(id: id)?.document.total, 313)
    }

    /// The ruling on blank descriptions: the line stays, and so does its money. Applying
    /// `sanitizeItems`' drop rule here would take a real income transaction off a document that
    /// goes to a customer — and out of the header totals with it.
    func testATransactionWithNoDescriptionKeepsItsLineAndItsMoney() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        try insert(store, id: "no-desc", date: "2026-01-01", counterparty: "Acme",
                   description: .null, amount: 100)
        try insert(store, id: "blank-desc", date: "2026-01-02", counterparty: "Acme",
                   description: .text("   "), amount: 200)
        try insert(store, id: "has-desc", date: "2026-01-03", counterparty: "Acme",
                   description: .text("Consulting"), amount: 300)

        let draft = try XCTUnwrap(try store.statementDrafts(customerName: "Acme",
                                                            periodStart: "2026-01-01",
                                                            periodEnd: "2026-01-31").first)
        XCTAssertEqual(draft.lines.count, 3)

        let id = try store.createBusinessDocument(draft.documentDraft(number: "ST-1", date: "2026-02-01"))
        let items = try store.businessDocumentItems(documentID: id)
        XCTAssertEqual(items.count, 3, "all three lines survived the write")
        XCTAssertEqual(items.map(\.description), ["", "", "Consulting"],
                       "a NULL description and a blank one both land as the empty string")
        XCTAssertEqual(try store.businessDocument(id: id)?.document.subtotal, 600,
                       "600, not 300 — the two undescribed transactions' money is on the statement")
    }

    /// A summary describes no goods, and it carries no tax rate. Q2-a leaves the three measurement
    /// columns empty; Q2-b keeps `tax_rate` empty because `transactions.tax_rate` has no agreed
    /// dimension anywhere in this schema and an unlabelled number does not go to a customer.
    func testASummaryLineCarriesNoQuantityNoUnitPriceAndNoTaxRate() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        try store.db.run("""
            INSERT INTO transactions (id, type, date, amount, tax_rate, currency, counterparty)
            VALUES ('t1', 'income', '2026-01-01', 100, 13, 'CNY', 'Acme')
            """)

        let draft = try XCTUnwrap(try store.statementDrafts(customerName: "Acme",
                                                            periodStart: "2026-01-01",
                                                            periodEnd: "2026-01-31").first)
        let id = try store.createBusinessDocument(draft.documentDraft(number: "ST-1", date: "2026-02-01"))
        let item = try XCTUnwrap(try store.businessDocumentItems(documentID: id).first)
        XCTAssertNil(item.quantity)
        XCTAssertNil(item.unit)
        XCTAssertNil(item.unitPrice)
        XCTAssertNil(item.taxRate, "the source row HAS a rate of 13; the statement still carries none")
        XCTAssertNil(DocumentMath.taxRatePercent(from: item.taxRate))
    }

    /// The back-links: `ref_sales_id` carries the source transaction's id and `ref_date` its date.
    /// `ref_date` is the only date carrier the line table has, which is why Q2-b's separate date
    /// column lands there.
    func testEachLineLinksBackToItsTransactionAndCarriesItsDate() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        try insert(store, id: "txn-42", date: "2026-01-09", counterparty: "Acme", amount: 100)

        let draft = try XCTUnwrap(try store.statementDrafts(customerName: "Acme",
                                                            periodStart: "2026-01-01",
                                                            periodEnd: "2026-01-31").first)
        let id = try store.createBusinessDocument(draft.documentDraft(number: "ST-1", date: "2026-02-01"))
        let item = try XCTUnwrap(try store.businessDocumentItems(documentID: id).first)
        XCTAssertEqual(item.refSalesID, "txn-42")
        XCTAssertEqual(item.refDate, "2026-01-09")
        XCTAssertEqual(item.lineNo, 0, "line numbers start at 0, as `sanitizeItems`' index does")
    }

    // MARK: - Q2-d · one document per currency

    /// N currencies produce N documents, each holding one currency's lines and nothing else, in
    /// currency-code order.
    func testEachCurrencyGetsItsOwnDocumentInCurrencyCodeOrder() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        try insert(store, id: "u1", date: "2026-01-01", counterparty: "Acme", amount: 10,
                   currency: .text("USD"))
        try insert(store, id: "c1", date: "2026-01-02", counterparty: "Acme", amount: 20,
                   currency: .text("CNY"))
        try insert(store, id: "j1", date: "2026-01-03", counterparty: "Acme", amount: 30,
                   currency: .text("JPY"))
        try insert(store, id: "c2", date: "2026-01-04", counterparty: "Acme", amount: 40,
                   currency: .text("CNY"))

        let drafts = try store.statementDrafts(customerName: "Acme",
                                               periodStart: "2026-01-01", periodEnd: "2026-01-31")
        XCTAssertEqual(drafts.map(\.currency), ["CNY", "JPY", "USD"],
                       "three documents, in currency-code order rather than in entry order")
        XCTAssertEqual(try at(drafts, 0).lines.map(\.refSalesID), ["c1", "c2"])
        XCTAssertEqual(try at(drafts, 1).lines.map(\.refSalesID), ["j1"])
        XCTAssertEqual(try at(drafts, 2).lines.map(\.refSalesID), ["u1"])
        // Every document's lines are of one currency — measured as "each line's source row carries
        // this document's currency", not merely as "the counts add up".
        for draft in drafts {
            for line in draft.lines {
                let stored = try store.db.query("SELECT currency FROM transactions WHERE id = ?",
                                                [.text(XCTUnwrap(line.refSalesID))]).first?.string("currency")
                XCTAssertEqual(stored, draft.currency)
            }
        }
    }

    /// Each document records its own currency in the v25 column — the generator is that column's
    /// first and only writer.
    func testEachSplitDocumentRecordsItsOwnCurrency() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        try insert(store, id: "u1", date: "2026-01-01", counterparty: "Acme", amount: 10,
                   currency: .text("USD"))
        try insert(store, id: "c1", date: "2026-01-02", counterparty: "Acme", amount: 20,
                   currency: .text("CNY"))

        let drafts = try store.statementDrafts(customerName: "Acme",
                                               periodStart: "2026-01-01", periodEnd: "2026-01-31")
        for (index, draft) in drafts.enumerated() {
            let id = try store.createBusinessDocument(
                draft.documentDraft(number: "ST-2026-000\(index + 1)", date: "2026-02-01"))
            let document = try XCTUnwrap(try store.businessDocument(id: id)?.document)
            XCTAssertEqual(document.currency, draft.currency)
            XCTAssertEqual(document.type, .statement)
            XCTAssertEqual(document.periodStart, "2026-01-01")
            XCTAssertEqual(document.periodEnd, "2026-01-31")
            XCTAssertEqual(document.customerName, "Acme")
        }
        XCTAssertEqual(try store.businessDocuments(type: .statement).documents.compactMap(\.currency).sorted(),
                       ["CNY", "USD"])
    }

    /// One currency is still one document, and it still records that currency — the split is not a
    /// special case that only fires for two or more.
    func testASingleCurrencyStillRecordsItsCurrency() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        try insert(store, id: "c1", date: "2026-01-02", counterparty: "Acme", amount: 20,
                   currency: .text("CNY"))
        let drafts = try store.statementDrafts(customerName: "Acme",
                                               periodStart: "2026-01-01", periodEnd: "2026-01-31")
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(try at(drafts, 0).currency, "CNY")
    }

    /// The document order uses the same code-unit comparator the picker does, and this is the case
    /// that can tell the two apart — three-letter ISO codes cannot, because Swift's `<` and JS's
    /// agree on ASCII. The column carries no `CHECK` (Q2-d-②), so these values are storable.
    ///
    /// Without this test the comparator inside the split would be free to be Swift's `<` and every
    /// other assertion in this file would still pass; the ordering decides which of the N
    /// documents takes which `ST` number in D-2, so it is not a cosmetic choice.
    func testTheDocumentOrderUsesTheSameCodeUnitComparatorAsThePicker() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        try insert(store, id: "a", date: "2026-01-01", counterparty: "Acme", amount: 10,
                   currency: .text("\u{FFFD}"))
        try insert(store, id: "b", date: "2026-01-02", counterparty: "Acme", amount: 20,
                   currency: .text("\u{1D400}"))

        let drafts = try store.statementDrafts(customerName: "Acme",
                                               periodStart: "2026-01-01", periodEnd: "2026-01-31")
        XCTAssertEqual(drafts.map(\.currency), ["\u{1D400}", "\u{FFFD}"],
                       "code-unit order: the astral code's first unit is the surrogate U+D835")
        XCTAssertEqual(["\u{FFFD}", "\u{1D400}"].sorted(), ["\u{FFFD}", "\u{1D400}"],
                       "…while Swift's own sort answers the other way, which is what makes this a test")
    }

    /// A currency cell with no text reading carries `nil` — which lands as SQL `NULL`, i.e. as the
    /// Q8 reading "derive it from `acc_locale`" — and sorts last. Unreachable through either app's
    /// writers (both clamp an empty currency to `"CNY"`), so this pins a carried case rather than a
    /// live one.
    func testAnUnreadableCurrencySortsLastAndLandsAsNull() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        try insert(store, id: "blob", date: "2026-01-01", counterparty: "Acme", amount: 10,
                   currency: .blob(Data([0xFF])))
        try insert(store, id: "usd", date: "2026-01-02", counterparty: "Acme", amount: 20,
                   currency: .text("USD"))

        let drafts = try store.statementDrafts(customerName: "Acme",
                                               periodStart: "2026-01-01", periodEnd: "2026-01-31")
        XCTAssertEqual(drafts.map(\.currency), ["USD", nil])

        let id = try store.createBusinessDocument(try at(drafts, 1).documentDraft(number: "ST-2", date: "2026-02-01"))
        XCTAssertNil(try store.businessDocument(id: id)?.document.currency)
    }

    // MARK: - Q2-d-② · the generator is the only writer, checked over the source

    /// Q2-d-② names ONE writer of the currency column. The store refuses everything else at run
    /// time (`BusinessDocumentStoreTests`), and this is the other half: inside the shipped package,
    /// the only thing that declares a draft's lines to have come FROM the generator is the
    /// generator, so there is nothing else that could satisfy the store's guard.
    ///
    /// Written as a closed-set comparison rather than as "no other file does it": a scan that only
    /// asserts the absence of something proves nothing when the pattern is wrong. The positive half
    /// — the set must contain exactly this one file — is what makes the negative half evidence.
    /// Comments are stripped first, for the same reason the capability guard strips them: the
    /// prose here explains the very thing being scanned for.
    ///
    /// **The pattern is PRODUCTION, not mention.** A first attempt scanned for `.statementGenerator`
    /// and came back with `DocumentStore.swift` as well — correctly, because that file CONSUMES the
    /// value (`switch origin`, and the currency guard's `==`). Consuming it is the point; producing
    /// it is what has one legitimate site. So the pattern matches only the two spellings that SET
    /// it — an argument label and an assignment — and both spellings are pinned below, along with
    /// the consumer forms that must NOT match.
    func testTheGeneratorIsTheOnlyProducerOfGeneratorOriginDraftsInTheShippedSource() throws {
        let files = try CapabilityImportGuardTests.strippedSources(of: "SoloLedgerCore")
        XCTAssertGreaterThan(files.count, 40, "the walker found the package")

        let producing = #"lineOrigin\s*[:=]\s*\.statementGenerator"#
        var producers: Set<String> = []
        for (path, code) in files where code.range(of: producing, options: .regularExpression) != nil {
            producers.insert(path)
        }
        XCTAssertEqual(producers, ["StatementGenerator.swift"],
                       "somebody else can now produce a draft the currency guard would accept")

        // The pattern's discriminating power, both directions, on real strings from this package.
        for produces in ["lineOrigin: .statementGenerator", "lineOrigin = .statementGenerator",
                         "lineOrigin:.statementGenerator"] {
            XCTAssertNotNil(produces.range(of: producing, options: .regularExpression),
                            "\(produces) must count as production")
        }
        for consumes in ["case .statementGenerator:", "draft.lineOrigin == .statementGenerator",
                         "case statementGenerator"] {
            XCTAssertNil(consumes.range(of: producing, options: .regularExpression),
                         "\(consumes) is a consumer and must not count")
        }

        // …and the consumer really is present in the file the narrower pattern now excludes, so
        // the exclusion is a decision rather than a pattern that happens to find nothing.
        let store = try XCTUnwrap(files.first { $0.path == "DocumentStore.swift" })
        XCTAssertTrue(store.code.contains(".statementGenerator"), "DocumentStore consumes it")
        XCTAssertFalse(producers.contains("DocumentStore.swift"), "…but does not produce it")
    }

    // MARK: - The whole round trip

    /// One generated statement, written and read back: every clause of Q2 landing at once on the
    /// same document.
    func testAGeneratedStatementRoundTripsThroughTheStore() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        try insert(store, id: "t1", date: "2026-01-03", counterparty: " Acme ",
                   description: .text("March retainer"), amount: 118, amountNet: .real(100),
                   taxAmount: .real(18))
        try insert(store, id: "t2", date: "2026-01-20", counterparty: "Acme",
                   description: .null, amount: 50, taxAmount: .null)

        let draft = try XCTUnwrap(try store.statementDrafts(customerName: "Acme",
                                                            periodStart: "2026-01-01",
                                                            periodEnd: "2026-01-31").first)
        let id = try store.createBusinessDocument(
            draft.documentDraft(number: "ST-2026-0001", date: "2026-02-01", accountingLocale: .CN))

        let detail = try XCTUnwrap(try store.businessDocument(id: id))
        XCTAssertEqual(detail.document.type, .statement)
        XCTAssertEqual(detail.document.status, .draft)
        XCTAssertEqual(detail.document.number, "ST-2026-0001")
        XCTAssertEqual(detail.document.customerName, "Acme")
        XCTAssertEqual(detail.document.accountingLocale, .CN)
        XCTAssertEqual(detail.document.currency, "CNY")
        XCTAssertEqual(detail.document.subtotal, 150, "100 (net) + 50 (gross, no net recorded)")
        XCTAssertEqual(detail.document.taxAmount, 18)
        XCTAssertEqual(detail.document.total, 168)
        XCTAssertEqual(detail.items.map(\.description), ["March retainer", ""])
        XCTAssertEqual(detail.items.map(\.amount), [100, 50])
        XCTAssertEqual(detail.items.map(\.taxAmount), [18, nil])
        XCTAssertEqual(detail.items.map(\.lineNo), [0, 1])
        XCTAssertEqual(detail.items.map(\.refSalesID), ["t1", "t2"])
        XCTAssertEqual(detail.items.map(\.refDate), ["2026-01-03", "2026-01-20"])
    }

    /// Generating and writing a statement adds no transaction and no inventory movement — Q5's
    /// zero-coupling boundary, measured on the one path in this chapter that READS the ledger.
    func testGeneratingAStatementWritesNothingBackToTheLedger() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        try insert(store, id: "t1", date: "2026-01-03", counterparty: "Acme", amount: 100)

        func count(_ table: String) throws -> Int {
            try store.db.query("SELECT COUNT(*) AS c FROM \(table)").first?.int("c") ?? -1
        }
        XCTAssertEqual(try count("transactions"), 1, "the control: the source row is there")

        let draft = try XCTUnwrap(try store.statementDrafts(customerName: "Acme",
                                                            periodStart: "2026-01-01",
                                                            periodEnd: "2026-01-31").first)
        _ = try store.createBusinessDocument(draft.documentDraft(number: "ST-1", date: "2026-02-01"))

        XCTAssertEqual(try count("transactions"), 1, "the source row is neither copied nor consumed")
        XCTAssertEqual(try count("inventory_movements"), 0)
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
