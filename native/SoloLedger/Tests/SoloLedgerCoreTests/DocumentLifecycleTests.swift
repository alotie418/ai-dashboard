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

        for edit in [BusinessDocumentEdit(notes: "nope"),
                     BusinessDocumentEdit(customerName: "Nope"),
                     BusinessDocumentEdit(lines: []),
                     BusinessDocumentEdit(notes: "nope", status: .void)] {
            XCTAssertThrowsError(try store.updateBusinessDocument(id: id, edit)) {
                XCTAssertEqual($0 as? BusinessDocumentError, .onlyDraftCanBeEdited)
            }
        }
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
            for document in try store.businessDocuments().documents {
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

    /// Replacement lines take the same two sanitising rules `create` applies, chosen by the same
    /// parameter — including the generated-statement case, where a blank description keeps its line
    /// and a missing tax stays `NULL`.
    func testReplacementLinesFollowTheirOriginsRules() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        let id = try store.createBusinessDocument(draft())

        try store.updateBusinessDocument(id: id, BusinessDocumentEdit(
            lines: [line("kept", amount: 10), line("   ", amount: 99)]))
        XCTAssertEqual(try store.businessDocumentItems(documentID: id).map(\.description), ["kept"])
        XCTAssertEqual(try store.businessDocument(id: id)?.document.subtotal, 10)

        try store.updateBusinessDocument(id: id, BusinessDocumentEdit(
            lines: [line("kept", amount: 10), line("", amount: 99)], lineOrigin: .statementGenerator))
        let items = try store.businessDocumentItems(documentID: id)
        XCTAssertEqual(items.map(\.description), ["kept", ""], "the generator's line survives")
        XCTAssertNil(items.last?.taxAmount, "…and its missing tax is still NULL, not a zero")
        XCTAssertEqual(try store.businessDocument(id: id)?.document.subtotal, 109)
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
}
