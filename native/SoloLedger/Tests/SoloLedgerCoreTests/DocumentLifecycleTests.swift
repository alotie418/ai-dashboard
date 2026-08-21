import XCTest
@testable import SoloLedgerCore

/// D-2 · Q5 — editing, the status machine, deletion and the formal-tax-invoice association,
/// against `electron/handlers/documents.js`'s `update`, `remove` and `updateTaxInvoice`.
///
/// Twenty-eight of `scripts/test-handlers.mjs` §2B Batch 8's assertions are these three routes
/// (G 11, H 9, I 8) and every one has a counterpart below. **Each expected outcome was measured by
/// driving the real handler**, including the ones that are easy to guess wrong: an empty request
/// does not move `updated_at`; a void document refuses a tax-invoice request before it looks at the
/// body; a legal status change bundled with an edit is refused for the edit's sake; and re-pointing
/// a document at the path it already holds skips the in-use check.
///
/// Two of Batch 8's refusals are unrepresentable here rather than reproduced — an out-of-set
/// `status` and an out-of-set `doc_type` — because both parameters are enums. The storage layer's
/// own `CHECK` is what still refuses such a value, and that is measured directly.
final class DocumentLifecycleTests: LedgerTestCase {

    private let epoch = "1999-01-01 00:00:00"

    private func draft(_ number: String = "UP-1",
                       type: BusinessDocumentType = .quotation,
                       lines: [BusinessDocumentLineDraft] = []) -> BusinessDocumentDraft {
        BusinessDocumentDraft(type: type, number: number, date: "2026-01-01",
                              customerName: "Old Name", notes: "orig notes", lines: lines)
    }

    private func line(_ description: String, amount: Double?, tax: Double? = nil) -> BusinessDocumentLineDraft {
        BusinessDocumentLineDraft(description: description, taxAmount: tax, amount: amount)
    }

    /// Park `updated_at` on a value the clock cannot produce, so "did this write touch the row?" is
    /// a question with a yes/no answer even when two writes land in the same second.
    private func parkUpdatedAt(_ store: LedgerStore, _ id: String) throws {
        try store.db.run("UPDATE business_documents SET updated_at = ? WHERE id = ?",
                         [.text(epoch), .text(id)])
    }

    private func updatedAt(_ store: LedgerStore, _ id: String) throws -> String? {
        try store.db.query("SELECT updated_at FROM business_documents WHERE id = ?", [.text(id)])
            .first?.string("updated_at")
    }

    // MARK: - Batch 8 G · editing a draft

    /// Batch 8 G's first three: the whitelisted fields change, the lines are replaced whole and the
    /// totals follow them, and the accounting regime does not move — it is frozen at create and is
    /// not a field this API has.
    func testEditingADraftReplacesTheFieldsAndTheLinesTogether() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        try store.settings.setString(AccountingLocale.CN.rawValue, for: SettingsStore.Key.accountingLocale)
        let id = try store.createBusinessDocument(draft(lines: [line("orig", amount: 10, tax: 1)]))

        try store.updateBusinessDocument(id: id, BusinessDocumentEdit(
            customerName: "New Name", notes: "new notes",
            lines: [line("a", amount: 20, tax: 2), line("b", amount: 30, tax: 3)]))

        let detail = try XCTUnwrap(try store.businessDocument(id: id))
        XCTAssertEqual(detail.document.customerName, "New Name")
        XCTAssertEqual(detail.document.notes, "new notes")
        XCTAssertEqual(detail.items.map(\.description), ["a", "b"], "the old line is gone, not merged")
        XCTAssertEqual(detail.document.subtotal, 50)
        XCTAssertEqual(detail.document.taxAmount, 5)
        XCTAssertEqual(detail.document.total, 55)

        try store.settings.setString(AccountingLocale.US.rawValue, for: SettingsStore.Key.accountingLocale)
        try store.updateBusinessDocument(id: id, BusinessDocumentEdit(notes: "again"))
        XCTAssertEqual(try store.businessDocument(id: id)?.document.accountingLocale, .CN,
                       "the regime is frozen; changing the setting does not reach an existing document")
    }

    /// Batch 8 G's fourth: a request that carries nothing is a success **and not a write** —
    /// `updated_at` does not move. Measured on the handler, where the early return happens before
    /// the timestamp is appended.
    func testARequestThatChangesNothingIsNotAWrite() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        let id = try store.createBusinessDocument(draft())
        try parkUpdatedAt(store, id)

        try store.updateBusinessDocument(id: id, BusinessDocumentEdit())
        XCTAssertEqual(try updatedAt(store, id), epoch, "an empty edit must not stamp the row")

        try store.updateBusinessDocument(id: id, BusinessDocumentEdit(status: .draft))
        XCTAssertEqual(try updatedAt(store, id), epoch,
                       "asking for the status it already has is not a transition and not a write")

        // The control: one real change does move it, so the two results above are the early exit
        // and not a broken clock.
        try store.updateBusinessDocument(id: id, BusinessDocumentEdit(notes: "x"))
        XCTAssertNotEqual(try updatedAt(store, id), epoch)
    }

    /// Batch 8 G's remaining seven, as the machine itself: every legal move, every illegal one, and
    /// the terminal state. `void` is reachable from both live states and leads nowhere.
    func testTheStatusMachineAllowsExactlyQ5sTransitions() throws {
        let store = try makeStore()
        defer { try? store.db.close() }

        let id = try store.createBusinessDocument(draft())
        XCTAssertEqual(try store.businessDocument(id: id)?.document.status, .draft)
        try store.updateBusinessDocument(id: id, BusinessDocumentEdit(status: .issued))
        XCTAssertEqual(try store.businessDocument(id: id)?.document.status, .issued)
        try store.updateBusinessDocument(id: id, BusinessDocumentEdit(status: .void))
        XCTAssertEqual(try store.businessDocument(id: id)?.document.status, .void)

        for wanted in [BusinessDocumentStatus.draft, .issued] {
            XCTAssertThrowsError(try store.updateBusinessDocument(id: id,
                                                                  BusinessDocumentEdit(status: wanted))) {
                XCTAssertEqual($0 as? BusinessDocumentError,
                               .invalidStatusTransition(from: .void, to: wanted), "void is terminal")
            }
        }

        let second = try store.createBusinessDocument(draft("UP-2"))
        try store.updateBusinessDocument(id: second, BusinessDocumentEdit(status: .void))
        XCTAssertEqual(try store.businessDocument(id: second)?.document.status, .void,
                       "draft goes straight to void as well")

        let third = try store.createBusinessDocument(draft("UP-3"))
        try store.updateBusinessDocument(id: third, BusinessDocumentEdit(status: .issued))
        XCTAssertThrowsError(try store.updateBusinessDocument(id: third,
                                                              BusinessDocumentEdit(status: .draft))) {
            XCTAssertEqual($0 as? BusinessDocumentError,
                           .invalidStatusTransition(from: .issued, to: .draft), "issuing is one-way")
        }
        // The whole machine, spelled out where a reader can see it.
        XCTAssertEqual(LedgerStore.statusTransitions[.draft], [.issued, .void])
        XCTAssertEqual(LedgerStore.statusTransitions[.issued], [.void])
        XCTAssertEqual(LedgerStore.statusTransitions[.void], [],
                       "an EMPTY list, not a missing key — being terminal is a decision")
        XCTAssertEqual(LedgerStore.statusTransitions.count, BusinessDocumentStatus.allCases.count)
    }

    /// Batch 8 G's eighth, and the ordering that decides which error a caller sees.
    ///
    /// An edit is any whitelisted field or the lines; the status is not one. So an issued document
    /// can still be voided — and a request that voids it **and** edits it is refused, for the edit.
    func testOnlyADraftCanBeEditedAndAStatusChangeIsNotAnEdit() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        let id = try store.createBusinessDocument(draft(lines: [line("orig", amount: 10)]))
        try store.updateBusinessDocument(id: id, BusinessDocumentEdit(status: .issued))

        // **All ten things that count as an edit, one at a time.** The rule is a ten-way `||`, and
        // a test that only ever sends three of them leaves the other seven free to be deleted: the
        // handler refuses every one of these on an issued document (measured, field by field), and
        // so must this.
        let everyEdit: [(String, BusinessDocumentEdit)] = [
            ("doc_type", BusinessDocumentEdit(type: .commercialInvoice)),
            ("doc_number", BusinessDocumentEdit(number: "NOPE-1")),
            ("doc_date", BusinessDocumentEdit(date: "2099-12-31")),
            ("valid_until", BusinessDocumentEdit(validUntil: "2099-12-31")),
            ("customer_name", BusinessDocumentEdit(customerName: "Nope")),
            ("customer_tax_id", BusinessDocumentEdit(customerTaxID: "T-9")),
            ("customer_address", BusinessDocumentEdit(customerAddress: "Elsewhere")),
            ("customer_contact", BusinessDocumentEdit(customerContact: "them")),
            ("notes", BusinessDocumentEdit(notes: "nope")),
            ("items", BusinessDocumentEdit(lines: [])),
            ("a legal status change bundled with an edit",
             BusinessDocumentEdit(notes: "nope", status: .void)),
        ]
        let before = try XCTUnwrap(try store.businessDocument(id: id))
        for (field, edit) in everyEdit {
            XCTAssertThrowsError(try store.updateBusinessDocument(id: id, edit), field) {
                XCTAssertEqual($0 as? BusinessDocumentError, .onlyDraftCanBeEdited, field)
            }
        }
        XCTAssertEqual(try store.businessDocument(id: id)?.document, before.document,
                       "not one of the eleven requests wrote anything")
        XCTAssertEqual(try store.businessDocumentItems(documentID: id), before.items)
        XCTAssertEqual(try store.businessDocument(id: id)?.document.status, .issued,
                       "the bundled request wrote neither half")

        // …and the same status change on its own goes through.
        try store.updateBusinessDocument(id: id, BusinessDocumentEdit(status: .void))
        XCTAssertEqual(try store.businessDocument(id: id)?.document.status, .void)
    }

    /// The transition is checked BEFORE the draft-only rule, so an illegal move on a non-draft
    /// reports the move. Reversing the two would report `onlyDraftCanBeEdited` for a request that
    /// contains no edit at all.
    func testAnIllegalTransitionIsReportedBeforeTheDraftRule() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        let id = try store.createBusinessDocument(draft())
        try store.updateBusinessDocument(id: id, BusinessDocumentEdit(status: .void))

        XCTAssertThrowsError(try store.updateBusinessDocument(
            id: id, BusinessDocumentEdit(notes: "x", status: .issued))) {
            XCTAssertEqual($0 as? BusinessDocumentError,
                           .invalidStatusTransition(from: .void, to: .issued),
                           "the transition is judged first, even with an edit in the same request")
        }
    }

    /// The out-of-set `status` and `doc_type` values Batch 8 refuses at runtime are unrepresentable
    /// through this API. What is still measurable is the OTHER half: the table refuses them.
    func testTheSchemaStillRefusesAStatusOutsideTheClosedSet() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        let id = try store.createBusinessDocument(draft())
        XCTAssertThrowsError(try store.db.run("UPDATE business_documents SET status = 'bogus' WHERE id = ?",
                                              [.text(id)]))
        XCTAssertNoThrow(try store.db.run("UPDATE business_documents SET status = 'issued' WHERE id = ?",
                                          [.text(id)]), "the control: a member of the set is accepted")
        XCTAssertEqual(BusinessDocumentStatus.allCases.map(\.rawValue), ["draft", "issued", "void"])
    }

    // MARK: - `nil` leaves alone, `""` clears, and the required three refuse

    func testAnAbsentFieldIsUntouchedAndAnEmptyOneIsCleared() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        var input = draft()
        input.validUntil = "2026-06-30"
        input.customerTaxID = "TAX-1"
        input.customerAddress = "Street 1"
        input.customerContact = "someone"
        let id = try store.createBusinessDocument(input)

        try store.updateBusinessDocument(id: id, BusinessDocumentEdit(customerTaxID: ""))
        var document = try XCTUnwrap(try store.businessDocument(id: id)?.document)
        XCTAssertNil(document.customerTaxID, "an empty value clears the column")
        XCTAssertEqual(document.validUntil, "2026-06-30", "…and the absent ones are untouched")
        XCTAssertEqual(document.customerAddress, "Street 1")
        XCTAssertEqual(document.customerContact, "someone")

        // **Only the truly empty string clears.** These columns go through
        // `safeString(v, n) || null`, which never trims, so whitespace is truthy and is stored as
        // itself. A port that trimmed before testing for empty would pass every other assertion in
        // this file and fail here — which is the whole reason this case is here.
        try store.updateBusinessDocument(id: id, BusinessDocumentEdit(validUntil: "   "))
        document = try XCTUnwrap(try store.businessDocument(id: id)?.document)
        XCTAssertEqual(document.validUntil, "   ", "whitespace is a value, not an absence")
        XCTAssertEqual(document.notes, "orig notes")

        try store.updateBusinessDocument(id: id, BusinessDocumentEdit(validUntil: ""))
        XCTAssertNil(try store.businessDocument(id: id)?.document.validUntil)
    }

    /// The three required fields refuse to be emptied, and the refusal happens while the statement
    /// is being built — i.e. BEFORE the "nothing to do" exit, so a request that would otherwise be
    /// a no-op still throws.
    func testTheThreeRequiredFieldsRefuseToBeEmptied() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        let id = try store.createBusinessDocument(draft())
        try parkUpdatedAt(store, id)

        for (edit, expected) in [
            (BusinessDocumentEdit(number: "  "), BusinessDocumentError.numberRequired),
            (BusinessDocumentEdit(number: "\u{FEFF}"), .numberRequired),
            (BusinessDocumentEdit(date: ""), .dateRequired),
            (BusinessDocumentEdit(customerName: ""), .customerNameRequired),
        ] {
            XCTAssertThrowsError(try store.updateBusinessDocument(id: id, edit)) {
                XCTAssertEqual($0 as? BusinessDocumentError, expected)
            }
        }
        XCTAssertEqual(try updatedAt(store, id), epoch, "none of the four wrote anything")
        // A date of one space is NOT empty by the handler's falsy test, so it is accepted and
        // stored verbatim — the same asymmetry `create` has.
        try store.updateBusinessDocument(id: id, BusinessDocumentEdit(date: " "))
        XCTAssertEqual(try store.businessDocument(id: id)?.document.date, " ")
    }

    func testUpdatingADocumentThatIsNotThereIsRefused() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        XCTAssertThrowsError(try store.updateBusinessDocument(id: "nope",
                                                              BusinessDocumentEdit(notes: "x"))) {
            XCTAssertEqual($0 as? BusinessDocumentError, .notFound)
        }
    }

    // MARK: - The whitelist, measured against the table rather than against the type

    /// **Every column an edit is not allowed to touch is byte-identical afterwards.**
    ///
    /// The closed set comes from `PRAGMA table_info`, so a column added later joins the untouched
    /// side automatically instead of quietly escaping the check. Both halves are pinned by size:
    /// an exclusion list that grew to swallow the table would fail here rather than pass over
    /// nothing.
    ///
    /// This is the assertion a mutation adding `acc_locale = ?` to the statement has to get past,
    /// and it is deliberately not "the type has no such field" — a constraint the compiler enforces
    /// is one no reverse proof can show is still being enforced.
    ///
    /// **One consequence is registered rather than prevented.** The edit below turns a generated
    /// statement into a quotation while leaving `currency` set, so a document of a type Q2-d-②
    /// forbids from RECORDING a currency ends up holding one — and Q8's exception then renders the
    /// header, the badge and the money symbol from it. The ruling names the WRITERS of that column
    /// and `update` is not one of them; the handler behaves identically on a v25 ledger (its
    /// `update` cannot see the column at all), so refusing here would be an invention rather than a
    /// mirror. Registered for the round that first shows a currency to a user.
    func testAnEditLeavesEveryColumnOutsideTheWhitelistByteIdentical() throws {
        let store = try makeStore()
        defer { try? store.db.close() }

        // A statement from the generator, so `currency`, the period and the tax-invoice columns all
        // hold something other than their defaults before the edit runs.
        try store.db.run("""
            INSERT INTO transactions (id, type, date, amount, currency, counterparty)
            VALUES ('t1', 'income', '2026-01-10', 100, 'USD', 'Acme')
            """)
        let drafts = try store.statementDrafts(customerName: "Acme",
                                               periodStart: "2026-01-01", periodEnd: "2026-01-31")
        let id = try XCTUnwrap(try store.createStatements(drafts, date: "2026-02-01").first)
        try store.updateTaxInvoice(documentID: id, TaxInvoiceEdit(
            issued: true, number: "FP-1", date: "2026-01-05",
            attachmentPath: "attachments/docs/ti-1.pdf"))

        let writable: Set<String> = ["doc_type", "doc_number", "doc_date", "valid_until",
                                     "customer_name", "customer_tax_id", "customer_address",
                                     "customer_contact", "notes", "status",
                                     "subtotal", "tax_amount", "total", "updated_at"]
        let columns = try store.db.query("PRAGMA table_info(business_documents)")
            .compactMap { $0.string("name") }
        XCTAssertEqual(columns.count, 25, "the v25 header; a new column changes this number")
        XCTAssertEqual(writable.count, 14, "9 whitelisted fields + status + 3 totals + updated_at")
        let untouchable = columns.filter { !writable.contains($0) }
        XCTAssertEqual(untouchable.count, 11, "…leaving 11 columns an edit may not reach")
        XCTAssertTrue(writable.isSubset(of: Set(columns)), "every name here is a real column")

        func snapshot() throws -> [String: String] {
            var out: [String: String] = [:]
            for column in untouchable {
                out[column] = try store.db.query(
                    "SELECT quote(\(column)) AS v FROM business_documents WHERE id = ?", [.text(id)]
                ).first?.string("v")
            }
            return out
        }
        let before = try snapshot()
        XCTAssertEqual(before["currency"], "'USD'", "the fixture really did set the awkward ones")
        XCTAssertEqual(before["tax_invoice_number"], "'FP-1'")
        XCTAssertNotEqual(before["period_start"], "NULL")

        try store.updateBusinessDocument(id: id, BusinessDocumentEdit(
            type: .quotation, number: "CHANGED-1", date: "2026-03-03", validUntil: "2026-12-31",
            customerName: "Someone Else", customerTaxID: "T-9", customerAddress: "Elsewhere",
            customerContact: "them", notes: "rewritten", status: .issued,
            lines: [line("new", amount: 7, tax: 1)]))

        XCTAssertEqual(try snapshot(), before, "an edit reached a column it has no business in")
        let document = try XCTUnwrap(try store.businessDocument(id: id)?.document)
        XCTAssertEqual(document.number, "CHANGED-1", "…while the whitelisted half really did change")
        XCTAssertEqual(document.subtotal, 7)
    }

    // MARK: - A8 · lines and totals cannot move apart

    /// The A8 design constraint as a measurement: after every write this API offers, each header's
    /// three totals equal ``DocumentMath/totals(ofLines:)`` over the lines actually stored.
    ///
    /// The last step is what gives the assertion teeth — a raw `INSERT` around the API breaks the
    /// invariant, which proves the check can fail at all.
    func testTheStoredTotalsAlwaysDescribeTheStoredLines() throws {
        let store = try makeStore()
        defer { try? store.db.close() }

        func assertConsistent(_ message: String) throws {
            let documents = try store.businessDocuments().documents
            // Fail closed. Every assertion below lives inside this loop, and an empty ledger would
            // satisfy all of them by having nothing to check — the same trap `requireShippedSources`
            // guards against in the sibling file.
            XCTAssertGreaterThan(documents.count, 0, "nothing to check: \(message)")
            for document in documents {
                let lines = try store.businessDocumentItems(documentID: document.id)
                let expected = DocumentMath.totals(
                    ofLines: lines.map { (amount: $0.amount, taxAmount: $0.taxAmount) })
                XCTAssertEqual(document.subtotal, expected.subtotal, "\(message) / \(document.number)")
                XCTAssertEqual(document.taxAmount, expected.taxAmount, "\(message) / \(document.number)")
                XCTAssertEqual(document.total, expected.total, "\(message) / \(document.number)")
            }
        }

        let id = try store.createBusinessDocument(draft(lines: [line("a", amount: 10.005, tax: 1.005),
                                                               line("b", amount: 20.004, tax: 2.004)]))
        try assertConsistent("after create")
        try store.updateBusinessDocument(id: id, BusinessDocumentEdit(lines: [line("c", amount: 33.335, tax: 4.335)]))
        try assertConsistent("after replacing the lines")
        try store.updateBusinessDocument(id: id, BusinessDocumentEdit(notes: "header only"))
        try assertConsistent("after a header-only edit")
        try store.updateBusinessDocument(id: id, BusinessDocumentEdit(lines: []))
        try assertConsistent("after clearing the lines")
        XCTAssertEqual(try store.businessDocument(id: id)?.document.total, 0)
        try store.updateBusinessDocument(id: id, BusinessDocumentEdit(status: .issued))
        try store.updateTaxInvoice(documentID: id, TaxInvoiceEdit(issued: true))
        try assertConsistent("after a status change and a tax-invoice record")

        // The control. Nothing in the package can do this; a raw statement can, and the invariant
        // notices — so a green run above is a measurement rather than a vacuous loop.
        try store.db.run("""
            INSERT INTO business_document_items (doc_id, description, amount, tax_amount, line_no)
            VALUES (?, 'smuggled', 500, 50, 0)
            """, [.text(id)])
        let lines = try store.businessDocumentItems(documentID: id)
        let recomputed = DocumentMath.totals(ofLines: lines.map { (amount: $0.amount, taxAmount: $0.taxAmount) })
        XCTAssertEqual(recomputed.subtotal, 500)
        XCTAssertNotEqual(try store.businessDocument(id: id)?.document.subtotal, recomputed.subtotal,
                          "a line written around the API is exactly the stale total A8 warns about")
    }

    /// Replacement lines always take `sanitizeItems`' hand-entered rules — a blank description
    /// drops its line, and a missing tax becomes `0`. There is no second mode, because the handler
    /// has none.
    ///
    /// **The consequence is registered rather than designed around** (see
    /// ``BusinessDocumentEdit/lines``): a GENERATED statement's line may legitimately have no
    /// description, so re-saving such a statement through this path would drop it and take its
    /// money out of the header with it. Nothing in this package can reach that — the second half
    /// below measures what would be lost, so the round that first CAN reach it has the number in
    /// front of it when it goes to ask for a ruling.
    func testReplacementLinesAlwaysTakeTheHandEnteredRules() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        let id = try store.createBusinessDocument(draft())

        try store.updateBusinessDocument(id: id, BusinessDocumentEdit(
            lines: [line("kept", amount: 10), line("   ", amount: 99)]))
        XCTAssertEqual(try store.businessDocumentItems(documentID: id).map(\.description), ["kept"])
        XCTAssertEqual(try store.businessDocument(id: id)?.document.subtotal, 10)

        // A generated statement's shape, handed to the edit path: the blank-description line goes,
        // and the `NULL` tax on the surviving line is flattened to 0.
        try store.updateBusinessDocument(id: id, BusinessDocumentEdit(
            lines: [line("kept", amount: 10), line("", amount: 99)]))
        let items = try store.businessDocumentItems(documentID: id)
        XCTAssertEqual(items.map(\.description), ["kept"],
                       "an undescribed line does not survive this path — D-4 must raise it")
        XCTAssertEqual(items.first?.taxAmount, 0, "…and a missing tax lands as a zero, not as NULL")
        XCTAssertEqual(try store.businessDocument(id: id)?.document.subtotal, 10,
                       "the 99 that vanished is missing from the header too")

        // …while `create` still has both rules, which is where Q2's ruling lives and stays.
        let generated = try store.createBusinessDocument(BusinessDocumentDraft(
            type: .statement, number: "GEN-1", date: "2026-01-01", customerName: "C",
            lines: [line("", amount: 99)], lineOrigin: .statementGenerator))
        let generatedItems = try store.businessDocumentItems(documentID: generated)
        XCTAssertEqual(generatedItems.map(\.description), [""], "create keeps it")
        XCTAssertNil(generatedItems.first?.taxAmount)
    }

    // MARK: - Batch 8 I · deletion

    /// Batch 8 I, all eight: a draft goes and takes its lines with it, a missing id is refused, an
    /// issued document must be voided first, and a void one deletes.
    func testDeletionRefusesIssuedDocumentsAndCascadesToTheLines() throws {
        let store = try makeStore()
        defer { try? store.db.close() }

        func lineCount(_ id: String) throws -> Int {
            try store.db.query("SELECT COUNT(*) AS c FROM business_document_items WHERE doc_id = ?",
                               [.text(id)]).first?.int("c") ?? -1
        }

        let drafted = try store.createBusinessDocument(
            draft("RM-1", lines: [line("x", amount: 10), line("y", amount: 20)]))
        XCTAssertEqual(try lineCount(drafted), 2, "the precondition")
        try store.deleteBusinessDocument(id: drafted)
        XCTAssertNil(try store.businessDocument(id: drafted))
        XCTAssertEqual(try lineCount(drafted), 0, "ON DELETE CASCADE took the lines")

        XCTAssertThrowsError(try store.deleteBusinessDocument(id: "nope")) {
            XCTAssertEqual($0 as? BusinessDocumentError, .notFound)
        }

        let issued = try store.createBusinessDocument(draft("RM-2"))
        try store.updateBusinessDocument(id: issued, BusinessDocumentEdit(status: .issued))
        XCTAssertThrowsError(try store.deleteBusinessDocument(id: issued)) {
            XCTAssertEqual($0 as? BusinessDocumentError, .issuedMustBeVoidedFirst)
        }
        XCTAssertNotNil(try store.businessDocument(id: issued), "and it is still there")

        try store.updateBusinessDocument(id: issued, BusinessDocumentEdit(status: .void))
        try store.deleteBusinessDocument(id: issued)
        XCTAssertNil(try store.businessDocument(id: issued))
    }

    /// Deletion hands back the attachment reference the document held, because Core owns no
    /// directories and will not pretend the copy was cleaned up. `nil` when there was none.
    func testDeletionReportsTheAttachmentItLeavesBehind() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        let plain = try store.createBusinessDocument(draft("RM-3"))
        XCTAssertNil(try store.deleteBusinessDocument(id: plain))

        let withCopy = try store.createBusinessDocument(draft("RM-4"))
        try store.updateTaxInvoice(documentID: withCopy,
                                   TaxInvoiceEdit(attachmentPath: "attachments/docs/keep.pdf"))
        try store.updateBusinessDocument(id: withCopy, BusinessDocumentEdit(status: .void))
        XCTAssertEqual(try store.deleteBusinessDocument(id: withCopy), "attachments/docs/keep.pdf")
    }

    // MARK: - Batch 8 H · the formal-tax-invoice association

    /// Batch 8 H's first six: the three plain fields persist (with `issued` stored as 1/0), the
    /// first attachment path is accepted and stored, and an empty request is a no-op success.
    func testTheAssociationRecordsWhatItIsGivenOnDraftsAndIssuedDocumentsAlike() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        let id = try store.createBusinessDocument(draft("TI-1", type: .commercialInvoice))

        try store.updateTaxInvoice(documentID: id, TaxInvoiceEdit(
            issued: true, number: "FP-12345", date: "2026-01-05"))
        var document = try XCTUnwrap(try store.businessDocument(id: id)?.document)
        XCTAssertTrue(document.taxInvoiceIssued)
        XCTAssertEqual(document.taxInvoiceNumber, "FP-12345")
        XCTAssertEqual(document.taxInvoiceDate, "2026-01-05")
        XCTAssertEqual(try store.db.query("SELECT tax_invoice_issued AS v FROM business_documents WHERE id = ?",
                                          [.text(id)]).first?.int("v"), 1, "stored as 1, as JS stores it")

        XCTAssertNil(try store.updateTaxInvoice(documentID: id,
                                                TaxInvoiceEdit(attachmentPath: "attachments/docs/ti-1-abc.pdf")),
                     "the first path orphans nothing")
        XCTAssertEqual(try store.businessDocument(id: id)?.document.taxInvoiceAttachmentPath,
                       "attachments/docs/ti-1-abc.pdf")

        try parkUpdatedAt(store, id)
        XCTAssertNil(try store.updateTaxInvoice(documentID: id, TaxInvoiceEdit()))
        XCTAssertEqual(try updatedAt(store, id), epoch, "an empty request is not a write either")

        try store.updateTaxInvoice(documentID: id, TaxInvoiceEdit(issued: false))
        XCTAssertEqual(try store.db.query("SELECT tax_invoice_issued AS v FROM business_documents WHERE id = ?",
                                          [.text(id)]).first?.int("v"), 0)

        // The rule this route exists for: it stays available after the document is issued, which is
        // exactly what the draft-only edit rule would have forbidden.
        try store.updateBusinessDocument(id: id, BusinessDocumentEdit(status: .issued))
        try store.updateTaxInvoice(documentID: id, TaxInvoiceEdit(number: "FP-2"))
        document = try XCTUnwrap(try store.businessDocument(id: id)?.document)
        XCTAssertEqual(document.taxInvoiceNumber, "FP-2")
        XCTAssertEqual(document.status, .issued)
    }

    /// The number is trimmed and an empty one is `NULL`; the DATE is not trimmed. That asymmetry is
    /// the handler's and it is the kind of thing a tidy-up would erase.
    func testTheNumberIsTrimmedAndTheDateIsNot() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        let id = try store.createBusinessDocument(draft("TI-2"))
        try store.updateTaxInvoice(documentID: id, TaxInvoiceEdit(number: "  FP-3  ", date: "  "))
        var document = try XCTUnwrap(try store.businessDocument(id: id)?.document)
        XCTAssertEqual(document.taxInvoiceNumber, "FP-3")
        XCTAssertEqual(document.taxInvoiceDate, "  ", "a whitespace date is truthy, so it is stored")

        try store.updateTaxInvoice(documentID: id, TaxInvoiceEdit(number: "   ", date: ""))
        document = try XCTUnwrap(try store.businessDocument(id: id)?.document)
        XCTAssertNil(document.taxInvoiceNumber)
        XCTAssertNil(document.taxInvoiceDate)
    }

    /// Batch 8 H's last three: a malformed path, a path another document already holds, and a void
    /// document — which refuses **before** it looks at the request, so even an empty one is refused.
    func testTheAssociationRefusesBadPathsSharedPathsAndVoidDocuments() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        let first = try store.createBusinessDocument(draft("TI-3"))
        let second = try store.createBusinessDocument(draft("TI-4"))
        try store.updateTaxInvoice(documentID: first,
                                   TaxInvoiceEdit(attachmentPath: "attachments/docs/shared.pdf"))

        XCTAssertThrowsError(try store.updateTaxInvoice(documentID: second,
                                                        TaxInvoiceEdit(attachmentPath: "../escape.pdf"))) {
            XCTAssertEqual($0 as? BusinessDocumentError, .invalidAttachmentPath)
        }
        XCTAssertThrowsError(try store.updateTaxInvoice(
            documentID: second, TaxInvoiceEdit(attachmentPath: "attachments/docs/shared.pdf"))) {
            XCTAssertEqual($0 as? BusinessDocumentError, .attachmentInUse)
        }
        XCTAssertNil(try store.businessDocument(id: second)?.document.taxInvoiceAttachmentPath,
                     "neither refusal wrote anything")

        // Re-pointing a document at the path it ALREADY holds skips the ownership check — the
        // handler compares before it queries, and without that it would report itself in use.
        XCTAssertNoThrow(try store.updateTaxInvoice(
            documentID: first, TaxInvoiceEdit(attachmentPath: "attachments/docs/shared.pdf")))

        try store.updateBusinessDocument(id: second, BusinessDocumentEdit(status: .void))
        for edit in [TaxInvoiceEdit(number: "X"), TaxInvoiceEdit()] {
            XCTAssertThrowsError(try store.updateTaxInvoice(documentID: second, edit)) {
                XCTAssertEqual($0 as? BusinessDocumentError, .voidTaxInvoiceReadOnly,
                               "the void check runs before the body is read")
            }
        }
        XCTAssertThrowsError(try store.updateTaxInvoice(documentID: "nope", TaxInvoiceEdit(number: "X"))) {
            XCTAssertEqual($0 as? BusinessDocumentError, .notFound)
        }
    }

    /// Replacing or clearing a path hands back the one that is now unreferenced — the reference
    /// Electron deletes from disk at this point and Core does not.
    func testReplacingOrClearingAPathReportsTheOrphan() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        let id = try store.createBusinessDocument(draft("TI-5"))
        XCTAssertNil(try store.updateTaxInvoice(documentID: id,
                                                TaxInvoiceEdit(attachmentPath: "attachments/docs/one.pdf")))
        XCTAssertEqual(try store.updateTaxInvoice(documentID: id,
                                                  TaxInvoiceEdit(attachmentPath: "attachments/docs/two.pdf")),
                       "attachments/docs/one.pdf")
        XCTAssertNil(try store.updateTaxInvoice(documentID: id,
                                                TaxInvoiceEdit(attachmentPath: "attachments/docs/two.pdf")),
                     "re-setting the same path orphans nothing")
        XCTAssertEqual(try store.updateTaxInvoice(documentID: id, TaxInvoiceEdit(attachmentPath: "")),
                       "attachments/docs/two.pdf", "clearing it orphans it too")
        XCTAssertNil(try store.businessDocument(id: id)?.document.taxInvoiceAttachmentPath)
    }

    /// **A number is never invented.** Every write puts back exactly what it was handed, and a
    /// document that is never handed one keeps `NULL` through its whole life — issue, associate,
    /// void. The source side of this claim is `DocumentWriteSurfaceGuardTests`.
    func testNoPathThroughTheAssociationEverProducesANumber() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        let id = try store.createBusinessDocument(draft("TI-6", type: .commercialInvoice))
        XCTAssertNil(try store.businessDocument(id: id)?.document.taxInvoiceNumber)

        try store.updateTaxInvoice(documentID: id, TaxInvoiceEdit(issued: true))
        XCTAssertNil(try store.businessDocument(id: id)?.document.taxInvoiceNumber,
                     "marking an invoice issued does not conjure its number")
        try store.updateTaxInvoice(documentID: id, TaxInvoiceEdit(date: "2026-01-05"))
        try store.updateTaxInvoice(documentID: id,
                                   TaxInvoiceEdit(attachmentPath: "attachments/docs/scan.pdf"))
        try store.updateBusinessDocument(id: id, BusinessDocumentEdit(status: .issued))
        XCTAssertNil(try store.businessDocument(id: id)?.document.taxInvoiceNumber)
        XCTAssertNotEqual(try store.businessDocument(id: id)?.document.number, nil,
                          "…while the INTERNAL number is there, which is the pair being kept apart")

        for typed in ["FP-1", "0", "  spaced  ", "\u{1F44D}"] {
            try store.updateTaxInvoice(documentID: id, TaxInvoiceEdit(number: typed))
            XCTAssertEqual(try store.businessDocument(id: id)?.document.taxInvoiceNumber,
                           DocumentMath.jsTrim(typed), "stored verbatim but for the trim")
        }
    }

    /// The whitelist the association's path field is held to, checked against
    /// `isValidAttachmentRelPath`'s answers **measured in node** for the same eighteen strings.
    ///
    /// The native side reuses `AttachmentRelPath.bareName(of:)`, which the import machinery already
    /// had; this is the evidence that the two really do agree, rather than an assumption that a
    /// function written for one caller fits another.
    func testThePathWhitelistAgreesWithTheHandlersRegex() {
        let expectations: [(String, Bool)] = [
            ("attachments/docs/a.pdf", true),
            ("attachments/docs/9", true),
            ("attachments/docs/A_b-c.PDF", true),
            ("attachments/docs/.hidden", false),
            ("attachments/docs/-x", false),
            ("attachments/docs/", false),
            ("attachments/docs/a..b", false),
            ("attachments/docs/a/b", false),
            ("attachments/docs/a b", false),
            ("attachments/docs/a\n", false),
            ("attachments/docs/a\nb", false),
            ("ATTACHMENTS/docs/a", false),
            ("attachments/docs/ä", false),
            ("/attachments/docs/a", false),
            ("attachments/docs/a/", false),
            ("../escape.pdf", false),
            ("attachments/docs/a.pdf ", false),
            ("attachments/docs/\u{0301}a", false),
        ]
        for (value, accepted) in expectations {
            XCTAssertEqual(AttachmentRelPath.bareName(of: value) != nil, accepted,
                           "isValidAttachmentRelPath(\(value.debugDescription)) is \(accepted) in node")
        }
        XCTAssertEqual(expectations.filter(\.1).count, 3, "three of the eighteen are accepted")
    }

    /// The ownership comparison is by UTF-16 code units, and that is a distinction with a
    /// difference: `attachments/docs/K.pdf` spelled with U+212A KELVIN SIGN is **canonically
    /// equivalent** to the ASCII spelling, so Swift `==` calls the two the same string and JS
    /// `!==` calls them different. Measured on both sides.
    ///
    /// A path in that spelling cannot get PAST the whitelist, but one can already be stored — which
    /// is exactly the side the comparison reads. With `==` in place of
    /// ``StatementText/areEqual(_:_:)`` the second document below would be told the file is its own
    /// and allowed to claim it.
    func testTheOwnershipComparisonIsByCodeUnitsRatherThanCanonicalEquivalence() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        let kelvin = "attachments/docs/\u{212A}.pdf"
        let ascii = "attachments/docs/K.pdf"
        XCTAssertTrue(kelvin == ascii, "Swift folds them; this test exists because of that")
        XCTAssertFalse(StatementText.areEqual(kelvin, ascii), "…and JS does not")

        let owner = try store.createBusinessDocument(draft("TI-K1"))
        try store.db.run("UPDATE business_documents SET tax_invoice_attachment_path = ? WHERE id = ?",
                         [.text(kelvin), .text(owner)])

        // **The consequence that bites.** Another document already holds the ASCII path. Pointing
        // the KELVIN one at it is a CHANGE, so the ownership query has to run and refuse — but a
        // folding comparison calls the two spellings the same string, decides nothing changed, and
        // skips the query, letting two documents share one file.
        let holder = try store.createBusinessDocument(draft("TI-K2"))
        try store.updateTaxInvoice(documentID: holder, TaxInvoiceEdit(attachmentPath: ascii))
        XCTAssertThrowsError(try store.updateTaxInvoice(documentID: owner,
                                                        TaxInvoiceEdit(attachmentPath: ascii))) {
            XCTAssertEqual($0 as? BusinessDocumentError, .attachmentInUse)
        }
        XCTAssertEqual(try store.businessDocument(id: owner)?.document.taxInvoiceAttachmentPath,
                       kelvin, "and the refusal wrote nothing")

        // …and once the other document lets go, the same request is accepted and reports the
        // KELVIN spelling as the orphan.
        try store.updateTaxInvoice(documentID: holder, TaxInvoiceEdit(attachmentPath: ""))
        XCTAssertEqual(try store.updateTaxInvoice(documentID: owner,
                                                  TaxInvoiceEdit(attachmentPath: ascii)),
                       kelvin, "the KELVIN spelling is orphaned, which a folding comparison would deny")
        XCTAssertEqual(try store.businessDocument(id: owner)?.document.taxInvoiceAttachmentPath, ascii)
    }

    /// An empty stored path is **no path**: the handler's tests on that column are truthiness
    /// (`if (row.tax_invoice_attachment_path)`, `existing && existing !== p`), and `''` is falsy
    /// there. Measured on the handler with `''` written straight into the column.
    func testAnEmptyStoredAttachmentPathCountsAsNoPath() throws {
        let store = try makeStore()
        defer { try? store.db.close() }

        let id = try store.createBusinessDocument(draft("TI-E1"))
        try store.db.run("UPDATE business_documents SET tax_invoice_attachment_path = '' WHERE id = ?",
                         [.text(id)])
        XCTAssertNil(try store.updateTaxInvoice(documentID: id,
                                                TaxInvoiceEdit(attachmentPath: "attachments/docs/new.pdf")),
                     "an empty previous value orphans nothing")

        let deleted = try store.createBusinessDocument(draft("TI-E2"))
        try store.db.run("UPDATE business_documents SET tax_invoice_attachment_path = '' WHERE id = ?",
                         [.text(deleted)])
        XCTAssertNil(try store.deleteBusinessDocument(id: deleted),
                     "…and deleting such a document leaves nothing behind either")

        // The control: a real path in the same two places IS reported, so the two nils above are
        // the truthiness rule and not a broken read.
        let real = try store.createBusinessDocument(draft("TI-E3"))
        try store.updateTaxInvoice(documentID: real,
                                   TaxInvoiceEdit(attachmentPath: "attachments/docs/one.pdf"))
        XCTAssertEqual(try store.updateTaxInvoice(documentID: real,
                                                  TaxInvoiceEdit(attachmentPath: "attachments/docs/two.pdf")),
                       "attachments/docs/one.pdf")
        XCTAssertEqual(try store.deleteBusinessDocument(id: real), "attachments/docs/two.pdf")
    }

    // MARK: - The clamps on the two write paths D-2 adds

    /// Every field the edit path writes is cut at the handler's own width, and the two trimmed ones
    /// are cut BEFORE they are trimmed.
    ///
    /// `update` re-spells these clamps rather than sharing `create`'s, so they need measuring on
    /// their own — every width below came from driving the real handler. `doc_number`'s in
    /// particular decides what `idx_docs_type_number` calls a collision.
    func testTheEditPathClampsEveryFieldAtTheHandlersWidth() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        let id = try store.createBusinessDocument(draft("CL-1"))

        func stored(_ column: String) throws -> String? {
            try store.db.query("SELECT \(column) AS v FROM business_documents WHERE id = ?",
                               [.text(id)]).first?.string("v")
        }
        func edit(_ field: String, _ value: String) throws {
            switch field {
            case "doc_number": try store.updateBusinessDocument(id: id, BusinessDocumentEdit(number: value))
            case "doc_date": try store.updateBusinessDocument(id: id, BusinessDocumentEdit(date: value))
            case "valid_until": try store.updateBusinessDocument(id: id, BusinessDocumentEdit(validUntil: value))
            case "customer_name": try store.updateBusinessDocument(id: id, BusinessDocumentEdit(customerName: value))
            case "customer_tax_id": try store.updateBusinessDocument(id: id, BusinessDocumentEdit(customerTaxID: value))
            case "customer_address": try store.updateBusinessDocument(id: id, BusinessDocumentEdit(customerAddress: value))
            case "customer_contact": try store.updateBusinessDocument(id: id, BusinessDocumentEdit(customerContact: value))
            case "notes": try store.updateBusinessDocument(id: id, BusinessDocumentEdit(notes: value))
            default: XCTFail("unknown field \(field)")
            }
        }

        for (field, width) in [("doc_number", 60), ("customer_name", 200), ("valid_until", 30),
                               ("customer_tax_id", 100), ("customer_address", 300),
                               ("customer_contact", 200), ("notes", 2000)] {
            try edit(field, String(repeating: "X", count: width) + "TAIL")
            let value = try XCTUnwrap(try stored(field), field)
            XCTAssertEqual(value.count, width, field)
            XCTAssertFalse(value.hasSuffix("TAIL"), "\(field) kept text past its width")
        }

        // The two trimmed fields: cut at the width — inside the run of spaces — and trimmed after,
        // so the tail is gone AND the spaces are gone. Trimming first would have kept part of TAIL.
        try edit("doc_number", "ABC" + String(repeating: " ", count: 57) + "TAIL")
        XCTAssertEqual(try stored("doc_number"), "ABC")
        try edit("customer_name", "ABC" + String(repeating: " ", count: 197) + "TAIL")
        XCTAssertEqual(try stored("customer_name"), "ABC")

        // …and the width counts UTF-16 code units, which is what decides whether two numbers
        // collide: "A" + 30 emoji is 61 units, so one unit is cut and SQLite counts 31 characters.
        try edit("doc_number", "A" + String(repeating: "\u{1F44D}", count: 30))
        XCTAssertEqual(try store.db.query("SELECT length(doc_number) AS n FROM business_documents WHERE id = ?",
                                          [.text(id)]).first?.int("n"), 31)

        // `doc_date` is the one field with no clamp at all — the handler stores `String(b.doc_date)`.
        let longDate = String(repeating: "D", count: 120)
        try edit("doc_date", longDate)
        XCTAssertEqual(try stored("doc_date"), longDate, "doc_date is neither clamped nor trimmed")
    }

    /// The association's own two clamps: 100 code units for the number, 30 for the date. Measured
    /// on the handler; nothing else in the suite pins them.
    func testTheAssociationClampsItsTwoTextFieldsAtTheHandlersWidths() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        let id = try store.createBusinessDocument(draft("CL-2"))

        try store.updateTaxInvoice(documentID: id, TaxInvoiceEdit(
            number: String(repeating: "Y", count: 100) + "TAIL",
            date: String(repeating: "Z", count: 30) + "TAIL"))
        let document = try XCTUnwrap(try store.businessDocument(id: id)?.document)
        XCTAssertEqual(document.taxInvoiceNumber?.count, 100)
        XCTAssertEqual(document.taxInvoiceDate?.count, 30)
        XCTAssertEqual(document.taxInvoiceNumber?.hasSuffix("TAIL"), false)
        XCTAssertEqual(document.taxInvoiceDate?.hasSuffix("TAIL"), false)

        // The number is clamped and THEN trimmed, same as `doc_number`.
        try store.updateTaxInvoice(documentID: id, TaxInvoiceEdit(
            number: "ABC" + String(repeating: " ", count: 97) + "TAIL"))
        XCTAssertEqual(try store.businessDocument(id: id)?.document.taxInvoiceNumber, "ABC")

        // The path is the one field with NO clamp: the handler hands `String(v)` straight to the
        // whitelist, which is what ends up narrowing it.
        let longName = String(repeating: "n", count: 400)
        try store.updateTaxInvoice(documentID: id,
                                   TaxInvoiceEdit(attachmentPath: "attachments/docs/\(longName).pdf"))
        XCTAssertEqual(try store.businessDocument(id: id)?.document.taxInvoiceAttachmentPath?.count,
                       "attachments/docs/".count + longName.count + 4)
    }

    // MARK: - A8 · the edit's two writes are one transaction

    /// The header UPDATE and the line rewrite are in ONE transaction, so a failure part way through
    /// leaves neither. Same fault-injection shape `BusinessDocumentStoreTests` uses on `create`:
    /// the ledger's own trigger machinery, so the production write path runs exactly as it ships.
    ///
    /// Without this, dropping `db.transaction` from the edit path is caught by nothing: the source
    /// guard counts statements and the totals invariant is checked only after successful writes.
    func testAFailureRewritingTheLinesRollsBackTheHeaderEditToo() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        let id = try store.createBusinessDocument(draft("TX-1", lines: [line("orig", amount: 10, tax: 1)]))
        // Park the timestamp BEFORE the snapshot, so `before` records the parked value and the
        // comparison below covers `updated_at` along with everything else.
        try parkUpdatedAt(store, id)
        let before = try XCTUnwrap(try store.businessDocument(id: id))

        try store.db.execute("""
            CREATE TRIGGER refuse_items BEFORE INSERT ON business_document_items
            BEGIN SELECT RAISE(ABORT, 'injected'); END;
            """)
        XCTAssertThrowsError(try store.updateBusinessDocument(id: id, BusinessDocumentEdit(
            notes: "should not survive", lines: [line("new", amount: 500, tax: 50)])))

        let after = try XCTUnwrap(try store.businessDocument(id: id))
        XCTAssertEqual(after.document, before.document, "the header edit rolled back with the lines")
        XCTAssertEqual(after.items, before.items, "…and the old lines are still there")
        XCTAssertEqual(try updatedAt(store, id), epoch, "nothing was written at all")

        try store.db.execute("DROP TRIGGER refuse_items")
        XCTAssertNoThrow(try store.updateBusinessDocument(id: id, BusinessDocumentEdit(
            notes: "fine now", lines: [line("new", amount: 500, tax: 50)])),
            "…and the same edit lands once the injected fault is gone")
        XCTAssertEqual(try store.businessDocument(id: id)?.document.subtotal, 500)
    }

    // MARK: - Q5 · the boundary a status transition must not cross

    /// Spec §2 Q5's third boundary assertion, which belongs to the round that introduces the
    /// transitions: **no state change on a document produces a `transactions` row or an inventory
    /// movement.** Q9 says this is held by the assertion and not by convention, so here it is.
    ///
    /// Every mutating path D-2 adds is exercised: issue, void, edit, line replacement, the
    /// tax-invoice association, and delete.
    func testNoDocumentStateChangePostsToTheLedgerOrTheInventory() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        let watched = ["transactions", "inventory_movements", "inventory_balances",
                       "inventory_exceptions"]

        func counts() throws -> [String: Int] {
            var out: [String: Int] = [:]
            for table in watched {
                out[table] = try store.db.query("SELECT COUNT(*) AS c FROM \(table)").first?.int("c") ?? -1
            }
            return out
        }
        // The control: every table exists and reads as a number, so a zero below is a measurement
        // rather than a failed query.
        XCTAssertEqual(try counts(), watched.reduce(into: [:]) { $0[$1] = 0 })

        let id = try store.createBusinessDocument(
            draft("Q5-1", type: .commercialInvoice, lines: [line("a", amount: 10, tax: 1)]))
        try store.updateBusinessDocument(id: id, BusinessDocumentEdit(
            notes: "edited", lines: [line("b", amount: 20, tax: 2)]))
        try store.updateBusinessDocument(id: id, BusinessDocumentEdit(status: .issued))
        try store.updateTaxInvoice(documentID: id,
                                   TaxInvoiceEdit(issued: true, number: "FP-1", date: "2026-01-05"))
        try store.updateBusinessDocument(id: id, BusinessDocumentEdit(status: .void))
        XCTAssertEqual(try counts(), watched.reduce(into: [:]) { $0[$1] = 0 },
                       "signing, associating and voiding post nothing")

        try store.deleteBusinessDocument(id: id)
        XCTAssertEqual(try counts(), watched.reduce(into: [:]) { $0[$1] = 0 },
                       "…and neither does deleting")
        XCTAssertEqual(try store.businessDocuments().documents.count, 0)
    }

    // MARK: - The twelfth ruling · A9 / A10 / A11 as conditional writes

    /// A REAL second connection to the same file, with a short busy timeout. Every test below drives
    /// it from inside the worker's `interleave`, i.e. at the exact instant the check-then-act window
    /// is open — the instant no amount of luck would let a test hit reliably.
    private func secondConnection(to store: LedgerStore) throws -> SQLiteDatabase {
        let other = try SQLiteDatabase(path: store.db.path, mode: .readWriteExisting)
        try other.execute("PRAGMA busy_timeout = 5000")
        return other
    }

    private func status(_ store: LedgerStore, _ id: String) throws -> String? {
        try store.db.query("SELECT status FROM business_documents WHERE id = ?", [.text(id)])
            .first?.string("status")
    }

    private func attachmentPath(_ store: LedgerStore, _ id: String) throws -> String? {
        try store.db.query("SELECT tax_invoice_attachment_path FROM business_documents WHERE id = ?",
                           [.text(id)]).first?.string("tax_invoice_attachment_path")
    }

    /// **Reverse proof 1 — delete `AND status IN (…)` from the edit and this goes green wrongly.**
    ///
    /// The document is a draft when the status is read and issued by the time the `UPDATE` runs.
    /// Without the predicate the edit lands on an issued document; with it, nothing is written and the
    /// caller gets the same `onlyDraftCanBeEdited` the pre-check would have given.
    func testAnEditRefusesAfterAConcurrentIssueAndChangesNothing() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        let id = try store.createBusinessDocument(draft())
        try parkUpdatedAt(store, id)
        let other = try secondConnection(to: store)
        defer { try? other.close() }

        XCTAssertThrowsError(try store.applyDocumentEdit(id: id, BusinessDocumentEdit(notes: "sneaked in"),
                                                         interleave: {
            try other.run("UPDATE business_documents SET status = 'issued' WHERE id = ?", [.text(id)])
        })) {
            XCTAssertEqual($0 as? BusinessDocumentError, .onlyDraftCanBeEdited)
        }
        XCTAssertEqual(try store.businessDocument(id: id)?.document.notes, "orig notes",
                       "the edit must not have landed on the issued document")
        XCTAssertEqual(try updatedAt(store, id), epoch, "…and the refused write is not a write")
    }

    /// The same window, with lines in the request: the header refused, so the LINES must not move
    /// either. A9's "all or nothing" half, measured rather than promised.
    func testARefusedEditDoesNotRewriteTheLinesEither() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        let id = try store.createBusinessDocument(draft(lines: [line("orig", amount: 10, tax: 1)]))
        let other = try secondConnection(to: store)
        defer { try? other.close() }

        XCTAssertThrowsError(try store.applyDocumentEdit(
            id: id, BusinessDocumentEdit(lines: [line("replacement", amount: 99)]), interleave: {
                try other.run("UPDATE business_documents SET status = 'issued' WHERE id = ?", [.text(id)])
            }))
        let detail = try XCTUnwrap(try store.businessDocument(id: id))
        XCTAssertEqual(detail.items.map(\.description), ["orig"], "the lines were rewritten anyway")
        XCTAssertEqual(detail.document.subtotal, 10, "…and so were the totals")
    }

    /// **Reverse proof 2 — delete `AND status != ?` from the delete.** The row is a draft when read
    /// and issued when the `DELETE` runs; without the predicate the issued document is deleted.
    func testADeleteRefusesAfterAConcurrentIssueAndLeavesTheRow() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        let id = try store.createBusinessDocument(draft("DEL-1"))
        let other = try secondConnection(to: store)
        defer { try? other.close() }

        XCTAssertThrowsError(try store.applyDocumentDelete(id: id, interleave: {
            try other.run("UPDATE business_documents SET status = 'issued' WHERE id = ?", [.text(id)])
        })) {
            XCTAssertEqual($0 as? BusinessDocumentError, .issuedMustBeVoidedFirst)
        }
        XCTAssertEqual(try status(store, id), "issued", "the issued document is still there")
    }

    /// **Reverse proof 3 — delete `AND status != ?` from the tax-invoice write.** The document is
    /// issued when read and void when the `UPDATE` runs; the association must stay frozen.
    func testATaxInvoiceWriteRefusesAfterAConcurrentVoidAndLeavesTheAssociation() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        let id = try store.createBusinessDocument(draft("TI-1"))
        try store.updateBusinessDocument(id: id, BusinessDocumentEdit(status: .issued))
        try store.updateTaxInvoice(documentID: id, TaxInvoiceEdit(number: "FP-ORIGINAL"))
        let other = try secondConnection(to: store)
        defer { try? other.close() }

        XCTAssertThrowsError(try store.applyTaxInvoiceEdit(
            documentID: id, TaxInvoiceEdit(number: "FP-SNEAKED"), interleave: {
                try other.run("UPDATE business_documents SET status = 'void' WHERE id = ?", [.text(id)])
            })) {
            XCTAssertEqual($0 as? BusinessDocumentError, .voidTaxInvoiceReadOnly)
        }
        XCTAssertEqual(try store.businessDocument(id: id)?.document.taxInvoiceNumber, "FP-ORIGINAL")
    }

    /// **Reverse proof 4 — delete the `NOT EXISTS` term.** The path is free when the pre-check asks
    /// and claimed by another document by the time the `UPDATE` runs. Without the term both documents
    /// end up pointing at one copy, which is precisely the state `ATTACHMENT_IN_USE` exists to prevent
    /// — either one's next edit would delete the file out from under the other.
    func testAnAttachmentClaimedInsideTheWindowIsRefusedAndTheHolderStaysExactlyOne() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        let mine = try store.createBusinessDocument(draft("OWN-1"))
        let rival = try store.createBusinessDocument(draft("OWN-2"))
        let path = "attachments/docs/shared.pdf"
        let other = try secondConnection(to: store)
        defer { try? other.close() }

        XCTAssertThrowsError(try store.applyTaxInvoiceEdit(
            documentID: mine, TaxInvoiceEdit(attachmentPath: path), interleave: {
                try other.run("UPDATE business_documents SET tax_invoice_attachment_path = ? WHERE id = ?",
                              [.text(path), .text(rival)])
            })) {
            XCTAssertEqual($0 as? BusinessDocumentError, .attachmentInUse)
        }
        let holders = try store.db.query(
            "SELECT id FROM business_documents WHERE tax_invoice_attachment_path = ?", [.text(path)])
        XCTAssertEqual(holders.compactMap { $0.string("id") }, [rival],
                       "exactly one document may hold a copy, and it is the one that claimed it")
    }

    /// **Reverse proof 5 — delete the affected-row check.** Every worker above would then return
    /// normally after writing nothing, and a caller that got no error would believe its change landed.
    /// Stated as its own assertion so the property is named rather than implied by the three above.
    func testAConditionalWriteThatMatchedNothingIsNeverASilentSuccess() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        let id = try store.createBusinessDocument(draft("SILENT-1"))
        let other = try secondConnection(to: store)
        defer { try? other.close() }
        let issue: () throws -> Void = {
            try other.run("UPDATE business_documents SET status = 'issued' WHERE id = ?", [.text(id)])
        }

        var thrown: [String] = []
        do { try store.applyDocumentEdit(id: id, BusinessDocumentEdit(notes: "x"), interleave: issue) }
        catch { thrown.append("edit") }
        do { _ = try store.applyDocumentDelete(id: id, interleave: {}) } catch { thrown.append("delete") }
        XCTAssertEqual(thrown, ["edit", "delete"], "a write that matched no row must say so")
    }

    /// **Reverse proof 6 — map every zero-row outcome to `notFound`.** Three of the four cases here
    /// have a different stable answer, and only the genuine absence is `notFound`. Collapsing them
    /// would tell a user their document had been deleted when it had merely been issued.
    func testOnlyAGenuineAbsenceIsReportedAsNotFound() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        let other = try secondConnection(to: store)
        defer { try? other.close() }

        let edited = try store.createBusinessDocument(draft("NF-1"))
        XCTAssertThrowsError(try store.applyDocumentEdit(id: edited, BusinessDocumentEdit(notes: "x"),
                                                         interleave: {
            try other.run("UPDATE business_documents SET status = 'issued' WHERE id = ?", [.text(edited)])
        })) { XCTAssertEqual($0 as? BusinessDocumentError, .onlyDraftCanBeEdited) }

        let deleted = try store.createBusinessDocument(draft("NF-2"))
        XCTAssertThrowsError(try store.applyDocumentDelete(id: deleted, interleave: {
            try other.run("UPDATE business_documents SET status = 'issued' WHERE id = ?", [.text(deleted)])
        })) { XCTAssertEqual($0 as? BusinessDocumentError, .issuedMustBeVoidedFirst) }

        // …and the row that really is gone. Removed by the SECOND connection between the read and the
        // write, so this is the zero-row path and not the pre-check's own `notFound`.
        let vanishing = try store.createBusinessDocument(draft("NF-3"))
        XCTAssertThrowsError(try store.applyDocumentEdit(id: vanishing, BusinessDocumentEdit(notes: "x"),
                                                         interleave: {
            try other.run("DELETE FROM business_documents WHERE id = ?", [.text(vanishing)])
        })) { XCTAssertEqual($0 as? BusinessDocumentError, .notFound) }

        let alsoVanishing = try store.createBusinessDocument(draft("NF-4"))
        XCTAssertThrowsError(try store.applyDocumentDelete(id: alsoVanishing, interleave: {
            try other.run("DELETE FROM business_documents WHERE id = ?", [.text(alsoVanishing)])
        })) { XCTAssertEqual($0 as? BusinessDocumentError, .notFound) }
    }

    /// The predicate pins the RULE, not the value that was read — so a request that is still legal
    /// against the new status still lands. A draft asked to become void, issued by someone else in the
    /// window, is `issued → void`: an edge the machine allows and Electron would also have written.
    /// A `status = <observed>` predicate would refuse it with nothing honest to say.
    func testAStatusChangeStillLandsWhenTheNewStatusIsAlsoALegalStartingPoint() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        let id = try store.createBusinessDocument(draft("RULE-1"))
        let other = try secondConnection(to: store)
        defer { try? other.close() }

        XCTAssertNoThrow(try store.applyDocumentEdit(id: id, BusinessDocumentEdit(status: .void),
                                                     interleave: {
            try other.run("UPDATE business_documents SET status = 'issued' WHERE id = ?", [.text(id)])
        }))
        XCTAssertEqual(try status(store, id), "void")
    }

    /// …and the opposite edge is still refused: `void → issued` is not an edge, so a document voided
    /// inside the window cannot be issued by a request that read it as a draft.
    func testAStatusChangeIsRefusedWhenTheNewStatusIsNotALegalStartingPoint() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        let id = try store.createBusinessDocument(draft("RULE-2"))
        let other = try secondConnection(to: store)
        defer { try? other.close() }

        XCTAssertThrowsError(try store.applyDocumentEdit(id: id, BusinessDocumentEdit(status: .issued),
                                                         interleave: {
            try other.run("UPDATE business_documents SET status = 'void' WHERE id = ?", [.text(id)])
        })) {
            XCTAssertEqual($0 as? BusinessDocumentError,
                           .invalidStatusTransition(from: .void, to: .issued))
        }
        XCTAssertEqual(try status(store, id), "void")
    }

    /// The one zero-row outcome that is NOT an error: the request asked for the status the row now
    /// already has. The pre-check answers that case by writing nothing, so the conditional write does
    /// the same — and `updated_at` proves nothing was written.
    func testAStatusChangeToTheStatusItNowAlreadyHoldsIsASilentSuccess() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        let id = try store.createBusinessDocument(draft("SAME-1"))
        try parkUpdatedAt(store, id)
        let other = try secondConnection(to: store)
        defer { try? other.close() }

        XCTAssertNoThrow(try store.applyDocumentEdit(id: id, BusinessDocumentEdit(status: .issued),
                                                     interleave: {
            try other.run("UPDATE business_documents SET status = 'issued' WHERE id = ?", [.text(id)])
        }))
        XCTAssertEqual(try status(store, id), "issued")
        XCTAssertEqual(try updatedAt(store, id), epoch, "nothing was written by THIS connection")
    }

    /// The admitted-status set, over the whole request space rather than over the cases somebody
    /// thought to write. Two properties: it is never empty for a request the pre-check let through,
    /// and it never admits a row the pre-check would have refused.
    func testTheAdmittedStatusSetMatchesThePreCheckOnEveryRequestShape() {
        let wanted: [BusinessDocumentStatus?] = [nil, .draft, .issued, .void]
        var covered = 0
        for observed in BusinessDocumentStatus.allCases {
            for want in wanted {
                for touchesFields in [false, true] {
                    let edit = touchesFields
                        ? BusinessDocumentEdit(notes: "n", status: want)
                        : BusinessDocumentEdit(status: want)

                    // Only requests the pre-check admits reach the write.
                    if let want, want != observed,
                       !LedgerStore.statusTransitions[observed, default: []].contains(want) { continue }
                    if touchesFields, observed != .draft { continue }
                    covered += 1

                    let admitted = LedgerStore.statusesAdmitting(edit, observed: observed)
                    XCTAssertFalse(admitted.isEmpty,
                                   "empty admitted set for observed=\(observed) want=\(String(describing: want))")
                    for candidate in admitted {
                        // The transition term exists only when a status is actually written, which is
                        // only when the wanted status differs from the one that was read — asking for
                        // the status a row already has is not a transition and is not a write.
                        if let want, want != observed {
                            XCTAssertTrue(LedgerStore.statusTransitions[candidate, default: []].contains(want),
                                          "\(candidate) is admitted but cannot reach \(want)")
                        }
                        if touchesFields {
                            XCTAssertEqual(candidate, .draft, "only a draft may be edited")
                        }
                    }
                }
            }
        }
        XCTAssertEqual(covered, 13, """
            the walk must cover every (observed, wanted, touches-fields) shape the pre-check admits: \
            eight on a draft, three on an issued document, two on a void one
            """)
    }

    /// The orphan a delete hands back is the path the DELETED ROW held, not the one the read saw. A
    /// stale path handed to a deleter is a new leak: it names a file somebody may still be pointing
    /// at, while the file that really came free goes unreported.
    func testTheOrphanHandedBackByADeleteComesFromTheRowThatWasRemoved() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        let id = try store.createBusinessDocument(draft("ORPH-1"))
        try store.updateTaxInvoice(documentID: id,
                                   TaxInvoiceEdit(attachmentPath: "attachments/docs/stale.pdf"))
        let other = try secondConnection(to: store)
        defer { try? other.close() }

        let orphan = try store.applyDocumentDelete(id: id, interleave: {
            try other.run("UPDATE business_documents SET tax_invoice_attachment_path = ? WHERE id = ?",
                          [.text("attachments/docs/current.pdf"), .text(id)])
        })
        XCTAssertEqual(orphan, "attachments/docs/current.pdf", """
            the reported orphan is the one the read saw, not the one the row actually held when it \
            was deleted
            """)
    }

    /// The same property for the association, where SQLite cannot hand back a pre-image: the write is
    /// conditioned on the row still holding the copy this request believes it is replacing. When it
    /// does not, nothing is written and NOTHING is reported as orphaned — the refusal is deliberately
    /// not one of the chapter's user-facing codes, because none of them says "somebody else moved it".
    func testATaxInvoiceWriteRefusesRatherThanReportAStaleOrphan() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        let id = try store.createBusinessDocument(draft("ORPH-2"))
        try store.updateTaxInvoice(documentID: id,
                                   TaxInvoiceEdit(attachmentPath: "attachments/docs/old.pdf"))
        let other = try secondConnection(to: store)
        defer { try? other.close() }

        XCTAssertThrowsError(try store.applyTaxInvoiceEdit(
            documentID: id, TaxInvoiceEdit(attachmentPath: "attachments/docs/mine.pdf"), interleave: {
                try other.run("UPDATE business_documents SET tax_invoice_attachment_path = ? WHERE id = ?",
                              [.text("attachments/docs/theirs.pdf"), .text(id)])
            })) { error in
            XCTAssertNil(error as? BusinessDocumentError, """
                no stable code says "another writer moved this row"; inventing one would need six \
                languages of copy for a state the shipping app cannot reach
                """)
            XCTAssertTrue(error is DocumentRowMovedUnderTheWrite)
        }
        XCTAssertEqual(try attachmentPath(store, id), "attachments/docs/theirs.pdf",
                       "the other writer's association is intact")
    }

    /// …and the term is not a blanket refusal: the ordinary replace, with nobody interfering, still
    /// writes and still reports the copy it displaced.
    func testTheUndisturbedReplaceStillReportsTheCopyItDisplaced() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        let id = try store.createBusinessDocument(draft("ORPH-3"))
        try store.updateTaxInvoice(documentID: id,
                                   TaxInvoiceEdit(attachmentPath: "attachments/docs/first.pdf"))
        let orphan = try store.updateTaxInvoice(
            documentID: id, TaxInvoiceEdit(attachmentPath: "attachments/docs/second.pdf"))
        XCTAssertEqual(orphan, "attachments/docs/first.pdf")
        XCTAssertEqual(try attachmentPath(store, id), "attachments/docs/second.pdf")
    }
}
