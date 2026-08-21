import CSQLite
import Foundation

/// Reading and writing the two business-document tables — the native half of
/// `electron/handlers/documents.js`, under `docs/BUSINESS_DOCUMENTS_SPEC.md` Q9 (case 甲):
/// **write the tables schema v11 already built, add nothing, and reproduce the handler's storage
/// semantics word for word.** The one column beyond v11 is `currency`, added by D-1a at v25 for
/// Q2-d-②.
///
/// ## What is here and what is deliberately not
///
/// `create` / `get` / `list` and the line round trip (D-1), plus `update`, `remove` and the
/// tax-invoice association (D-2 · Q5). The numbering suggestion is Q3 and lives next door in
/// ``DocumentNumbering`` — a separation this package's guards depend on, because "the tax-invoice
/// path cannot generate a number" is checked by that symbol being absent from this file.
///
/// Two properties worth stating rather than discovering:
///
///  * A duplicate `(doc_type, doc_number)` is refused by the unique index and surfaces as the stable
///    ``BusinessDocumentError/numberExists``, through ``mappingConstraintToNumberExists(_:)`` —
///    which discriminates on the PRIMARY result code, for a reason measured and written out there.
///  * Registered form A8 — Electron's `update` recomputes the header totals only when the request
///    carried `items` — is reproduced as storage semantics. What is NOT reproduced is a reachable
///    stale total: both writers compute the totals from the lines they are writing, in the same
///    transaction, always, and ``insertDocumentLines(_:documentID:)`` is the only insert there is.
///
/// ## Non-finite money is flattened, not refused
///
/// `documents.js`'s `round2` runs its input through `num()` first, so `±∞` and `NaN` are stored as
/// `0` — silently. That is the handler's behaviour and Q9 says to reproduce it, so this file does,
/// and `ProductCatalog.normalizedUnitCost` is the existing precedent for a clamp-rather-than-refuse
/// money path. It is deliberately NOT the transaction path's rule: `LedgerStore.create(_:)` refuses
/// a non-finite amount outright (`LedgerError.nonFiniteAmounts`). The two policies differ because
/// the two mirrors differ, and this one is registered rather than harmonized.
public extension LedgerStore {

    // MARK: - Reads

    /// `GET /api/documents[?type=…]` — `documents.js list`.
    ///
    /// Same explicit column list and the same `ORDER BY doc_date DESC, created_at DESC` as the
    /// handler, with no row cap. `nil` means every type, which is what both `?type=all` and an
    /// absent `type` do there; the handler's third branch — refusing a type outside the closed set —
    /// has no counterpart because ``BusinessDocumentType`` removes those inputs from the domain.
    func businessDocuments(type: BusinessDocumentType? = nil) throws -> BusinessDocumentPage {
        var sql = "SELECT \(Self.documentHeaderColumns) FROM business_documents"
        var params: [SQLiteValue] = []
        if let type {
            sql += " WHERE doc_type = ?"
            params.append(.text(type.rawValue))
        }
        sql += " ORDER BY doc_date DESC, created_at DESC"

        var documents: [BusinessDocument] = []
        var unreadable = 0
        for row in try db.query(sql, params) {
            if let document = BusinessDocument.from(row) { documents.append(document) } else { unreadable += 1 }
        }
        return BusinessDocumentPage(documents: documents, unreadableCount: unreadable)
    }

    /// `GET /api/documents/:id` — `documents.js get`, header plus lines.
    ///
    /// `nil` is the handler's `'Document not found'`. A row that exists but cannot be identified
    /// also reads as `nil` here; it is the ``BusinessDocumentPage/unreadableCount`` on the list that
    /// reports such a row exists at all, because a single-row read has nowhere to put a count.
    func businessDocument(id: String) throws -> BusinessDocumentDetail? {
        guard let row = try db.query("SELECT \(Self.documentHeaderColumns) FROM business_documents WHERE id = ?",
                                     [.text(id)]).first,
              let document = BusinessDocument.from(row)
        else { return nil }
        return BusinessDocumentDetail(document: document, items: try businessDocumentItems(documentID: id))
    }

    /// The lines of one document, in `line_no, id` order — `documents.js loadItems`.
    ///
    /// Ordering happens in SQL, never in Swift. SQLite orders by storage class first
    /// (NULL < numeric < TEXT < BLOB), and no in-memory comparison over the decoded model
    /// reproduces that for a `line_no` holding something other than an integer.
    func businessDocumentItems(documentID: String) throws -> [BusinessDocumentItem] {
        try db.query("""
            SELECT id, product_id, description, quantity, unit, unit_price, tax_rate,
                   tax_amount, amount, line_no, ref_sales_id, ref_date
              FROM business_document_items WHERE doc_id = ? ORDER BY line_no, id
            """, [.text(documentID)]).compactMap(BusinessDocumentItem.from)
    }

    // MARK: - Write

    /// `POST /api/documents` — `documents.js create`. Returns the new id.
    ///
    /// The order of operations is the handler's, and each step is load-bearing:
    ///
    ///  1. **Clamp, then trim, then require.** `doc_number` and `customer_name` are cut to their
    ///     column budgets FIRST and trimmed after (`safeString(v, n)` then `.trim()`), so a value
    ///     that is 60 characters of text followed by spaces keeps the text. Reversing the two would
    ///     accept strings the handler refuses.
    ///  2. **`doc_date` is neither clamped nor trimmed**, only required to be non-empty — the
    ///     handler's test is `!b.doc_date`, so `" "` passes and is stored as `" "`.
    ///  3. **The lines are sanitised before the totals are computed**, because the totals are the
    ///     sum of what will actually be stored, including the effect of any dropped line.
    ///  4. **The header and the lines are written in ONE transaction.** They are never separately
    ///     visible, which is the storage half of the A8 design constraint.
    ///
    /// `status` is written as the literal `draft`, exactly as the handler's `INSERT` does. The four
    /// `tax_invoice_*` columns are omitted so they take their schema defaults, also as there.
    ///
    /// ## The `currency` column is refused to everything but a generated statement
    ///
    /// Q2-d-② is not a description of what the first version happens to do — it is a constraint:
    /// "首版写入者只有对账单生成器；其余四种类型、以及手工新建的单据，一律不写，保持 `NULL`". A
    /// non-`NULL` value there makes Q8's exception fire, and the header, the badge and the money
    /// symbol all render from it instead of from `acc_locale`; a hand-made quotation that acquired
    /// one would print the wrong currency onto a document that goes to a customer.
    ///
    /// So the boundary REFUSES rather than trusts, and refuses rather than silently drops — quietly
    /// discarding a caller's value is the shape this chapter rejects everywhere else. The two
    /// conditions are the two halves of the ruling's sentence: the document must BE a statement, and
    /// its lines must have come FROM the generator.
    @discardableResult
    func createBusinessDocument(_ draft: BusinessDocumentDraft) throws -> String {
        if draft.currency != nil {
            guard draft.type == .statement, draft.lineOrigin == .statementGenerator else {
                throw BusinessDocumentError.currencyIsGeneratedStatementsOnly
            }
        }
        let number = DocumentMath.jsTrim(DocumentMath.jsSlice(draft.number, to: 60))
        guard !number.isEmpty else { throw BusinessDocumentError.numberRequired }
        let customerName = DocumentMath.jsTrim(DocumentMath.jsSlice(draft.customerName, to: 200))
        guard !customerName.isEmpty else { throw BusinessDocumentError.customerNameRequired }
        guard !draft.date.isEmpty else { throw BusinessDocumentError.dateRequired }

        let lines = Self.sanitizedLines(draft.lines, origin: draft.lineOrigin)
        let totals = DocumentMath.totals(ofLines: lines.map { (amount: $0.amount, taxAmount: $0.taxAmount) })
        let locale = try draft.accountingLocale ?? settings.accountingLocale()
        let id = Self.newBusinessDocumentID()

        try Self.mappingConstraintToNumberExists {
            try db.transaction {
                try db.run("""
                    INSERT INTO business_documents (
                      id, doc_type, doc_number, status, doc_date, valid_until,
                      customer_name, customer_tax_id, customer_address, customer_contact,
                      acc_locale, subtotal, tax_amount, total, notes, source_sales_id,
                      period_start, period_end, currency
                    ) VALUES (?, ?, ?, 'draft', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, [
                        .text(id),
                        .text(draft.type.rawValue),
                        .text(number),
                        .text(draft.date),
                        Self.clamped(draft.validUntil, 30),
                        .text(customerName),
                        Self.clamped(draft.customerTaxID, 100),
                        Self.clamped(draft.customerAddress, 300),
                        Self.clamped(draft.customerContact, 200),
                        .text(locale.rawValue),
                        .real(totals.subtotal),
                        .real(totals.taxAmount),
                        .real(totals.total),
                        Self.clamped(draft.notes, 2000),
                        Self.clamped(draft.sourceSalesID, 200),
                        Self.clamped(draft.periodStart, 30),
                        Self.clamped(draft.periodEnd, 30),
                        // v25, Q2-d-②. Stored verbatim: the ruling is that this column constrains
                        // nothing and follows `transactions.currency`'s loose form, so there is no
                        // length clamp and no empty-to-NULL coercion to invent. `nil` stays `NULL`,
                        // which is the "derive it from acc_locale" reading every other document keeps.
                        draft.currency.map { SQLiteValue.text($0) } ?? .null,
                    ])
                try insertDocumentLines(lines, documentID: id)
            }
        }
        return id
    }

    // MARK: - Update

    /// `PUT /api/documents/:id` — `documents.js update`. Q3 numbering and Q5's status machine and
    /// editing rules.
    ///
    /// The handler's order of operations is the contract, because each step decides which error a
    /// caller sees, and they are not interchangeable:
    ///
    ///  1. **The row must exist** → ``BusinessDocumentError/notFound``.
    ///  2. **The status transition is checked FIRST**, before anything is asked about editability.
    ///     So an illegal transition on an issued document reports the transition, not the draft
    ///     rule. Asking for the status it already has is not a transition at all: it is compared
    ///     before it is validated, so it is neither checked nor written.
    ///  3. **Then the draft-only rule.** An edit is any of the nine whitelisted fields or the
    ///     lines — the status is NOT one of them, which is exactly how an issued document can still
    ///     be voided. A legal status change bundled with an edit is refused, for the edit's sake.
    ///  4. **Then the per-field refusals**, in the whitelist's own order. These run while the SET
    ///     list is being built, i.e. BEFORE the "nothing to do" exit — so an edit that only clears
    ///     the number throws rather than quietly doing nothing.
    ///  5. **Nothing supplied is not a write.** `updated_at` does not move, which is the same rule
    ///     `updateProduct` follows.
    ///
    /// ## The lines and the totals move together or not at all
    ///
    /// Supplying ``BusinessDocumentEdit/lines`` replaces the whole set and rewrites the three header
    /// totals in the SAME transaction; not supplying them leaves both alone. Registered form A8
    /// describes the storage semantics and they are reproduced — what is not reproduced is a path
    /// to a stale total, because there is no way through this API to move one without the other.
    ///
    /// ## A9 is closed by a conditional write (twelfth ruling)
    ///
    /// The status is still read first — the errors above are decided from it — but the rule that read
    /// establishes is now also spelled INTO the write, and the affected row count is checked. A second
    /// connection that moves the status in between makes the `UPDATE` match nothing instead of writing
    /// anyway, and the caller gets the same stable error. See
    /// ``LedgerStore/applyDocumentEdit(id:_:interleave:)``.
    func updateBusinessDocument(id: String, _ edit: BusinessDocumentEdit) throws {
        try applyDocumentEdit(id: id, edit, interleave: nil)
    }

    // MARK: - Delete

    /// `DELETE /api/documents/:id` — `documents.js remove`.
    ///
    /// An **issued** document is refused (``BusinessDocumentError/issuedMustBeVoidedFirst``); a
    /// draft or a void one goes, and its lines go with it through the schema's
    /// `ON DELETE CASCADE`. Deleting is also the ONLY thing that gives a number back (Q3): the row
    /// stops occupying `(doc_type, doc_number)` and stops feeding the numbering suggestion.
    ///
    /// **Returns the attachment reference the deleted document held**, or `nil`. Electron deletes
    /// that file itself, best-effort, right after the row; Core owns no directories and does no
    /// filesystem work, so it hands the reference back instead of dropping it silently. Deleting
    /// the copy is the caller's, and until a round owns the attachments directory nobody does it —
    /// registered here rather than hidden.
    ///
    /// ## A10 is closed by a conditional delete (twelfth ruling)
    ///
    /// `… WHERE id = ? AND status != 'issued'`, and the returned reference comes out of the row the
    /// statement actually removed rather than out of the read that preceded it. See
    /// ``LedgerStore/applyDocumentDelete(id:interleave:)``.
    @discardableResult
    func deleteBusinessDocument(id: String) throws -> String? {
        try applyDocumentDelete(id: id, interleave: nil)
    }

    // MARK: - The formal-tax-invoice association

    /// `PUT /api/documents/:id/tax-invoice` — `documents.js updateTaxInvoice`.
    ///
    /// **It records an invoice that already exists. It cannot issue one and it cannot invent a
    /// number** — the number written is exactly the number handed in.
    ///
    /// Deliberately NOT part of ``updateBusinessDocument(id:_:)``, because the two obey different
    /// rules and `documents.js:6-7` says why: an association must be recordable on an **issued**
    /// document, which the draft-only edit rule would forbid. Void is the one state that freezes it,
    /// and that check comes first — so a void document refuses even an empty request.
    ///
    /// **Returns the attachment reference that just became unreferenced**, or `nil` — same
    /// arrangement, and same registered gap, as ``deleteBusinessDocument(id:)``.
    ///
    /// ## A11 is closed by a conditional write (twelfth ruling)
    ///
    /// Three judged facts move into the one `UPDATE`'s predicate: the document is not void, the file
    /// being pointed at is not spoken for by another document, and the row still holds the copy this
    /// request believes it is replacing. See ``LedgerStore/applyTaxInvoiceEdit(documentID:_:interleave:)``.
    @discardableResult
    func updateTaxInvoice(documentID: String, _ edit: TaxInvoiceEdit) throws -> String? {
        try applyTaxInvoiceEdit(documentID: documentID, edit, interleave: nil)
    }
}

// MARK: - The three conditional writes (A9 / A10 / A11)

/// The twelfth ruling's first item, in one place: `update`, `remove` and `updateTaxInvoice` fold the
/// facts they judged into the PREDICATE of the statement that acts on them, and check how many rows
/// that statement actually touched.
///
/// Registered forms A9–A11 stay in the spec with their evidence and their numbers; their disposition
/// column now records that this ruling supersedes "照搬" for them, and **B11** registers the
/// resulting deliberate difference from Electron, which still writes unconditionally.
///
/// ## Why each worker takes an `interleave`
///
/// A conditional write is only worth something against a SECOND connection, and no test can produce
/// that race by luck. Each worker therefore takes an internal closure fired **after the facts are
/// read and before the write** — precisely when the window is open — so a test can commit a
/// conflicting change from a real second connection to the same file at that instant, every time.
/// It is `nil` on every shipped path (the three public entry points pass nothing), it is internal so
/// the App target cannot reach it, and it is a parameter rather than global mutable state, which is
/// the discipline ``LedgerStore/HardenedOpenHooks`` already sets for a test seam in this package.
///
/// ## What a zero-row outcome may become
///
/// Never a silent success, never a second unconditional write, and never a blanket
/// ``BusinessDocumentError/notFound``. Each worker RE-READS the row and re-derives the refusal
/// through the same guards, in the same order, the pre-checks use — so the caller sees the error that
/// fact would have produced had it been visible from the start.
extension LedgerStore {

    /// ``updateBusinessDocument(id:_:)``, plus the seam.
    ///
    /// **The predicate carries the JUDGED RULE, not the OBSERVED VALUE**, and the difference is not
    /// stylistic. `status = <what we read>` would refuse a request that is still perfectly legal
    /// against the new status — a draft asked to become void, which someone else issued in between,
    /// is `issued → void`, an edge the machine allows — and there is no stable error for "legal, but
    /// not written". Pinning the rule refuses exactly what the pre-check refuses and nothing else:
    ///
    ///  * an edit of fields or lines admits `draft` alone (the draft-only rule);
    ///  * a status change to `W` admits the statuses `W` is reachable FROM (the machine's own edges).
    ///
    /// Both terms apply when both are asked for, which is how a draft can be edited and issued in one
    /// request. ``statusesAdmitting(_:observed:)`` is that intersection, and it is never empty for a
    /// request that got this far — proved rather than assumed by the exhaustive walk in
    /// `DocumentLifecycleTests`, because an empty set would have to be spelled `AND 0` and would then
    /// be a silent refusal of everything.
    func applyDocumentEdit(id: String, _ edit: BusinessDocumentEdit,
                           interleave: (() throws -> Void)?) throws {
        guard let existing = try db.query("SELECT id, status FROM business_documents WHERE id = ?",
                                          [.text(id)]).first,
              let statusRaw = existing.string("status"),
              let currentStatus = BusinessDocumentStatus(rawValue: statusRaw)
        else { throw BusinessDocumentError.notFound }

        if let wanted = edit.status, wanted != currentStatus {
            guard Self.statusTransitions[currentStatus, default: []].contains(wanted) else {
                throw BusinessDocumentError.invalidStatusTransition(from: currentStatus, to: wanted)
            }
        }
        if edit.changesFieldsOrLines, currentStatus != .draft {
            throw BusinessDocumentError.onlyDraftCanBeEdited
        }

        var assignments: [String] = []
        var values: [SQLiteValue] = []
        func set(_ column: String, _ value: SQLiteValue) {
            assignments.append("\(column) = ?")
            values.append(value)
        }

        if let type = edit.type { set("doc_type", .text(type.rawValue)) }
        if let number = edit.number {
            let cleaned = DocumentMath.jsTrim(DocumentMath.jsSlice(number, to: 60))
            guard !cleaned.isEmpty else { throw BusinessDocumentError.numberRequired }
            set("doc_number", .text(cleaned))
        }
        if let date = edit.date {
            guard !date.isEmpty else { throw BusinessDocumentError.dateRequired }
            set("doc_date", .text(date))
        }
        if let validUntil = edit.validUntil { set("valid_until", Self.clamped(validUntil, 30)) }
        if let customerName = edit.customerName {
            let cleaned = DocumentMath.jsTrim(DocumentMath.jsSlice(customerName, to: 200))
            guard !cleaned.isEmpty else { throw BusinessDocumentError.customerNameRequired }
            set("customer_name", .text(cleaned))
        }
        if let taxID = edit.customerTaxID { set("customer_tax_id", Self.clamped(taxID, 100)) }
        if let address = edit.customerAddress { set("customer_address", Self.clamped(address, 300)) }
        if let contact = edit.customerContact { set("customer_contact", Self.clamped(contact, 200)) }
        if let notes = edit.notes { set("notes", Self.clamped(notes, 2000)) }
        if let wanted = edit.status, wanted != currentStatus { set("status", .text(wanted.rawValue)) }
        // `acc_locale` is frozen at create and ignored here, so a document's regime cannot drift
        // when the setting changes. It is not in `BusinessDocumentEdit` at all.

        var lines: [SanitizedDocumentLine]?
        if let drafts = edit.lines {
            // Always the hand-entered rules: `sanitizeItems` has no mode, so neither does this.
            // See ``BusinessDocumentEdit/lines`` for what that costs a generated statement, and why
            // widening it is a ruling rather than a refactor.
            let sanitized = Self.sanitizedLines(drafts, origin: .handEntered)
            let totals = DocumentMath.totals(
                ofLines: sanitized.map { (amount: $0.amount, taxAmount: $0.taxAmount) })
            set("subtotal", .real(totals.subtotal))
            set("tax_amount", .real(totals.taxAmount))
            set("total", .real(totals.total))
            lines = sanitized
        }

        if assignments.isEmpty, lines == nil { return }

        // A SQL expression, not a bound value: `datetime('now')` is what the handler writes, and it
        // is the database's clock rather than this process's.
        assignments.append("updated_at = datetime('now')")
        values.append(.text(id))

        let admitted = Self.statusesAdmitting(edit, observed: currentStatus)
        let condition = admitted.isEmpty
            ? "0"
            : "status IN (\(admitted.map { _ in "?" }.joined(separator: ", ")))"
        values.append(contentsOf: admitted.map { SQLiteValue.text($0.rawValue) })

        try interleave?()

        var affected = 0
        try Self.mappingConstraintToNumberExists {
            try db.transaction {
                affected = try db.run("""
                    UPDATE business_documents SET \(assignments.joined(separator: ", ")) \
                    WHERE id = ? AND \(condition)
                    """, values)
                // A9's other half: the header and the lines move together or not at all. Returning
                // here leaves the transaction with nothing in it, so a refused header cannot be
                // followed by a rewritten set of lines.
                guard affected > 0 else { return }
                if let lines {
                    try db.run("DELETE FROM business_document_items WHERE doc_id = ?", [.text(id)])
                    try insertDocumentLines(lines, documentID: id)
                }
            }
        }
        guard affected > 0 else {
            if let refusal = try refusalForDocumentEdit(id: id, edit) { throw refusal }
            return
        }
        // A `nil` refusal is the request having asked for the status the row already holds, which the
        // pre-check itself answers by writing nothing. `DocumentLifecycleTests` walks the whole
        // request space to show that is the only way to get one.
    }

    /// ``deleteBusinessDocument(id:)``, plus the seam.
    ///
    /// `RETURNING` rather than a read followed by a delete, because the reference handed back has to
    /// describe the row that was ACTUALLY removed. A path read before the statement can be stale by
    /// the time the statement runs, and a stale path handed to a deleter is a NEW leak — it names a
    /// file somebody may still be pointing at while the file that really came free goes unreported.
    /// One statement decides both: the row count is the number of rows it gave back, and the path is
    /// the one that row held.
    func applyDocumentDelete(id: String, interleave: (() throws -> Void)?) throws -> String? {
        guard let row = try db.query(
            "SELECT id, status, tax_invoice_attachment_path FROM business_documents WHERE id = ?",
            [.text(id)]).first,
              let statusRaw = row.string("status"),
              let status = BusinessDocumentStatus(rawValue: statusRaw)
        else { throw BusinessDocumentError.notFound }
        guard status != .issued else { throw BusinessDocumentError.issuedMustBeVoidedFirst }

        try interleave?()

        let removed = try db.query("""
            DELETE FROM business_documents WHERE id = ? AND status != ?
            RETURNING tax_invoice_attachment_path
            """, [.text(id), .text(BusinessDocumentStatus.issued.rawValue)])
        guard let deleted = removed.first else {
            // `id` is the primary key and `status != 'issued'` is the only other term, so a row that
            // is still there was `issued` at the instant the statement ran. A later change to `void`
            // does not make the refused attempt retroactively legal, and naming the fact that refused
            // it is the same stable error the handler gives.
            let stillThere = try db.query("SELECT id FROM business_documents WHERE id = ?", [.text(id)])
            throw stillThere.isEmpty
                ? BusinessDocumentError.notFound
                : BusinessDocumentError.issuedMustBeVoidedFirst
        }
        // Truthiness, as `if (row.tax_invoice_attachment_path)` is on the other side: an empty
        // stored path is no path.
        return deleted.string("tax_invoice_attachment_path").flatMap { $0.isEmpty ? nil : $0 }
    }

    /// ``updateTaxInvoice(documentID:_:)``, plus the seam.
    ///
    /// Three terms beyond `id`, each one a fact this function judged in Swift and used to be willing
    /// to write against:
    ///
    ///  1. `status != 'void'` — the association is frozen once the document is void.
    ///  2. `NOT EXISTS (… tax_invoice_attachment_path = ? AND id != ?)` — the copy being pointed at is
    ///     not spoken for. Added under exactly the condition the pre-check runs under, so re-pointing
    ///     a document at the path it already holds still skips the question, as it does over there.
    ///  3. `tax_invoice_attachment_path IS ?` — the row still holds the copy this request believes it
    ///     is replacing. Only when the column is being written, and it is what makes the returned
    ///     orphan PROVABLE: `UPDATE … RETURNING` in SQLite hands back post-update values, so the
    ///     pre-image cannot be recovered from the statement and has to be pinned by the predicate
    ///     instead. Bound as the RAW cell rather than the decoded string, with `IS` rather than `=`,
    ///     so `NULL` compares and a cell holding a non-TEXT value compares as itself.
    ///
    /// **Term 3 has one registered cost.** `SQLiteDatabase.readColumn` decodes TEXT lossily — invalid
    /// UTF-8 becomes U+FFFD — so a cell a foreign writer filled with bytes that are not UTF-8 cannot be
    /// bound back byte-for-byte, and this term can never match it. The effect is bounded and it is the
    /// safe direction: on THAT row, a request that writes the attachment column is refused (nothing is
    /// written, nothing is reported as orphaned), while a request that only touches the issued flag,
    /// the number or the date carries no such term and works normally. Refusing is also the honest
    /// answer — a request that cannot name what it is replacing has no business reporting what it
    /// displaced.
    ///
    /// Term 3 is the one with no stable error of its own: a zero-row outcome that survives the re-read
    /// means another writer re-pointed this document while the sheet was open. That is not
    /// ``BusinessDocumentError/attachmentInUse`` (no other document is involved) and not
    /// ``BusinessDocumentError/notFound`` (the row is there), so it leaves as a non-`BusinessDocumentError`
    /// and the page reports its generic "save failed, try again" — accurate, because nothing was
    /// written. No new error case, no new key, no new copy.
    func applyTaxInvoiceEdit(documentID: String, _ edit: TaxInvoiceEdit,
                             interleave: (() throws -> Void)?) throws -> String? {
        guard let row = try db.query(
            "SELECT id, status, tax_invoice_attachment_path FROM business_documents WHERE id = ?",
            [.text(documentID)]).first,
              let statusRaw = row.string("status"),
              let status = BusinessDocumentStatus(rawValue: statusRaw)
        else { throw BusinessDocumentError.notFound }
        guard status != .void else { throw BusinessDocumentError.voidTaxInvoiceReadOnly }

        // An empty stored path is NO path. The handler decides whether a copy has been orphaned
        // with `if (existing.tax_invoice_attachment_path …)` — a truthiness test, and `''` is
        // falsy there. Measured on the handler with `''` written straight into the column: it
        // neither reports nor deletes anything. Nothing either API writes produces that cell; a
        // foreign writer can.
        let storedCell = row["tax_invoice_attachment_path"]
        let existingPath = row.string("tax_invoice_attachment_path").flatMap { $0.isEmpty ? nil : $0 }
        var assignments: [String] = []
        var values: [SQLiteValue] = []
        func set(_ column: String, _ value: SQLiteValue) {
            assignments.append("\(column) = ?")
            values.append(value)
        }

        if let issued = edit.issued { set("tax_invoice_issued", .integer(issued ? 1 : 0)) }
        if let number = edit.number {
            // Clamp, THEN trim, and an empty result is NULL. Note the asymmetry with the date
            // below: only this one is trimmed.
            let cleaned = DocumentMath.jsTrim(DocumentMath.jsSlice(number, to: 100))
            set("tax_invoice_number", cleaned.isEmpty ? .null : .text(cleaned))
        }
        if let date = edit.date { set("tax_invoice_date", Self.clamped(date, 30)) }

        var orphaned: String?
        var ownership: (sql: String, values: [SQLiteValue])?
        if let rawPath = edit.attachmentPath {
            // The handler's own shape: `null` and `''` both mean "clear it"; anything else is taken
            // as written, with NO length clamp — the whitelist below is the only thing narrowing it.
            let path: String? = rawPath.isEmpty ? nil : rawPath
            if let path {
                guard AttachmentRelPath.bareName(of: path) != nil else {
                    throw BusinessDocumentError.invalidAttachmentPath
                }
                // Ownership guard. The pre-check is the handler's and is kept for that reason
                // rather than for a reason of its own: the query below already excludes this
                // document (`id != ?`), so skipping it when the path has not changed cannot change
                // the answer — it only saves the query.
                //
                // What DOES matter is how the two strings are compared. JS `!==` is code-unit
                // identity; Swift `==` is canonical equivalence, and the two disagree on inputs
                // this whitelist admits: `attachments/docs/K.pdf` with U+212A KELVIN SIGN is
                // canonically equal to the ASCII `K` spelling in Swift and different in JS
                // (measured both ways). A stored path can hold that spelling even though a new one
                // cannot get past the whitelist above.
                if !(existingPath.map { StatementText.areEqual($0, path) } ?? false) {
                    let claimed = try db.query("""
                        SELECT 1 FROM business_documents
                         WHERE tax_invoice_attachment_path = ? AND id != ? LIMIT 1
                        """, [.text(path), .text(documentID)])
                    guard claimed.isEmpty else { throw BusinessDocumentError.attachmentInUse }
                    ownership = ("""
                         AND NOT EXISTS (SELECT 1 FROM business_documents
                                          WHERE tax_invoice_attachment_path = ? AND id != ?)
                        """, [.text(path), .text(documentID)])
                }
            }
            set("tax_invoice_attachment_path", path.map { SQLiteValue.text($0) } ?? .null)
            if let existingPath, !(path.map { StatementText.areEqual(existingPath, $0) } ?? false) {
                orphaned = existingPath
            }
        }

        if assignments.isEmpty { return nil }
        assignments.append("updated_at = datetime('now')")

        var predicate = "WHERE id = ? AND status != ?"
        values.append(.text(documentID))
        values.append(.text(BusinessDocumentStatus.void.rawValue))
        if edit.attachmentPath != nil {
            predicate += " AND tax_invoice_attachment_path IS ?"
            values.append(storedCell)
        }
        if let ownership {
            predicate += ownership.sql
            values.append(contentsOf: ownership.values)
        }

        try interleave?()

        let affected = try db.run(
            "UPDATE business_documents SET \(assignments.joined(separator: ", ")) \(predicate)", values)
        guard affected > 0 else { throw try refusalForTaxInvoiceEdit(documentID: documentID, edit) }
        return orphaned
    }

    // MARK: The refusals a zero-row write is allowed to become

    /// The stable error for an edit that matched no row, or `nil` when the request's effect already
    /// holds. Re-reads, then walks the SAME two guards in the SAME order the pre-check uses.
    ///
    /// **`nil` is granted only to the one case that has earned it**: a status-only request whose
    /// wanted status the row now already holds. That case IS the pre-check's own answer — it compares
    /// before it validates, finds nothing to write, and returns. Every other way of reaching the end
    /// of this function means the row moved between the write and this re-read (a writer running an
    /// edge the machine does not have, e.g. back to `draft`), and answering `nil` there would report
    /// success for a request that did not happen. That gets the same non-`BusinessDocumentError`
    /// ``DocumentRowMovedUnderTheWrite`` the association path uses, for the same reason: no stable
    /// code says it, and the page's generic "save failed, try again" is true.
    func refusalForDocumentEdit(id: String, _ edit: BusinessDocumentEdit) throws -> Error? {
        guard let row = try db.query("SELECT id, status FROM business_documents WHERE id = ?",
                                     [.text(id)]).first,
              let statusRaw = row.string("status"),
              let status = BusinessDocumentStatus(rawValue: statusRaw)
        else { return BusinessDocumentError.notFound }

        if let wanted = edit.status, wanted != status,
           !Self.statusTransitions[status, default: []].contains(wanted) {
            return BusinessDocumentError.invalidStatusTransition(from: status, to: wanted)
        }
        if edit.changesFieldsOrLines, status != .draft { return BusinessDocumentError.onlyDraftCanBeEdited }
        if edit.status == status, !edit.changesFieldsOrLines { return nil }
        return DocumentRowMovedUnderTheWrite(term: "status")
    }

    /// The refusal for a tax-invoice write that matched no row. The three terms, re-asked in the
    /// order the function asks them; the last one has no stable code and says so.
    func refusalForTaxInvoiceEdit(documentID: String, _ edit: TaxInvoiceEdit) throws -> Error {
        guard let row = try db.query("SELECT id, status FROM business_documents WHERE id = ?",
                                     [.text(documentID)]).first,
              let statusRaw = row.string("status"),
              let status = BusinessDocumentStatus(rawValue: statusRaw)
        else { return BusinessDocumentError.notFound }
        if status == .void { return BusinessDocumentError.voidTaxInvoiceReadOnly }
        if let rawPath = edit.attachmentPath, !rawPath.isEmpty {
            let claimed = try db.query("""
                SELECT 1 FROM business_documents
                 WHERE tax_invoice_attachment_path = ? AND id != ? LIMIT 1
                """, [.text(rawPath), .text(documentID)])
            if !claimed.isEmpty { return BusinessDocumentError.attachmentInUse }
        }
        return DocumentRowMovedUnderTheWrite(term: "tax_invoice_attachment_path")
    }

    /// The stored statuses under which THIS request is legal — the intersection of every rule the
    /// pre-check applied, expressed as a set of rows the write is allowed to touch.
    ///
    /// Returned in ``BusinessDocumentStatus``'s own declaration order so the SQL is deterministic.
    static func statusesAdmitting(_ edit: BusinessDocumentEdit,
                                  observed: BusinessDocumentStatus) -> [BusinessDocumentStatus] {
        var admitted = Set(BusinessDocumentStatus.allCases)
        if edit.changesFieldsOrLines { admitted.formIntersection([.draft]) }
        if let wanted = edit.status, wanted != observed {
            admitted.formIntersection(statusPredecessors(of: wanted))
        }
        return BusinessDocumentStatus.allCases.filter { admitted.contains($0) }
    }

    /// The statuses `wanted` is reachable FROM, read off ``statusTransitions`` rather than restated —
    /// so the machine has exactly one spelling and an edge cannot be added to one and not the other.
    static func statusPredecessors(of wanted: BusinessDocumentStatus) -> Set<BusinessDocumentStatus> {
        Set(statusTransitions.filter { $0.value.contains(wanted) }.keys)
    }
}

/// The one refusal these writers raise that is NOT a ``BusinessDocumentError``.
///
/// It exists so that "another writer moved the fact under us" cannot be dressed up as one of the
/// chapter's user-facing codes: none of them says that, and inventing one would need six languages of
/// copy for a state the shipping single-connection app cannot reach. The page's write helper turns any
/// non-`BusinessDocumentError` into its generic save-failed sentence, which is exactly true here —
/// nothing was written.
struct DocumentRowMovedUnderTheWrite: Error, CustomStringConvertible {
    let term: String
    var description: String {
        "a conditional document write matched no row: \(term) no longer holds the value it was read with"
    }
}

// MARK: - Internals

extension LedgerStore {

    /// `documents.js HEADER_COLUMNS`, plus the native-only `currency`.
    ///
    /// Spelled out rather than `SELECT *` for the reason the handler gives: an explicit list is
    /// what makes a schema addition invisible to a reader that does not want it. That property is
    /// what let v25 land without touching Electron at all.
    static let documentHeaderColumns = """
        id, doc_type, doc_number, status, doc_date, valid_until,
        customer_name, customer_tax_id, customer_address, customer_contact,
        acc_locale, subtotal, tax_amount, total, notes, source_sales_id,
        period_start, period_end, currency, tax_invoice_issued, tax_invoice_number,
        tax_invoice_date, tax_invoice_attachment_path, created_at, updated_at
        """

    /// One sanitised line, ready to bind. `description` is non-optional because the column is, and
    /// the two money fields stay optional because SQL `NULL` is a value they can hold.
    struct SanitizedDocumentLine: Equatable {
        var productID: String?
        var description: String
        var quantity: Double?
        var unit: String?
        var unitPrice: Double?
        var taxRate: String?
        var taxAmount: Double?
        var amount: Double?
        var lineNo: Int
        var refSalesID: String?
        var refDate: String?
    }

    /// `documents.js sanitizeItems`, with the two departures ``BusinessDocumentLineOrigin`` names.
    ///
    /// The clamps are the handler's, and each is applied on the side it is applied there:
    /// `description` is trimmed and THEN cut to 500, while `doc_number` (in `create`) is cut and
    /// THEN trimmed. That asymmetry is in the source, not in this port.
    ///
    /// `quantity` and `unitPrice` go through `num(v, null)`, whose fallback is `null` rather than
    /// `0` — so a non-finite number lands as SQL `NULL`, not as a zero. `taxAmount` and `amount` go
    /// through `round2`, whose fallback IS `0`; the statement origin is what keeps a `nil` tax out
    /// of that path.
    static func sanitizedLines(_ drafts: [BusinessDocumentLineDraft],
                               origin: BusinessDocumentLineOrigin) -> [SanitizedDocumentLine] {
        let kept: [BusinessDocumentLineDraft]
        switch origin {
        case .handEntered:
            kept = drafts.filter { !DocumentMath.jsTrim($0.description).isEmpty }
        case .statementGenerator:
            kept = drafts
        }

        return kept.enumerated().map { index, draft in
            SanitizedDocumentLine(
                productID: nonEmpty(draft.productID, 200),
                description: DocumentMath.jsSlice(DocumentMath.jsTrim(draft.description), to: 500),
                quantity: finiteOrNil(draft.quantity),
                unit: nonEmpty(draft.unit, 30),
                unitPrice: finiteOrNil(draft.unitPrice),
                taxRate: nonEmpty(draft.taxRate, 20),
                taxAmount: {
                    switch origin {
                    case .handEntered: return DocumentMath.storedRound2(draft.taxAmount)
                    // Q2-a: a source transaction with no tax must read back as no tax, so the
                    // `NULL` survives instead of being flattened into a zero nobody recorded.
                    case .statementGenerator: return draft.taxAmount.map(DocumentMath.storedRound2)
                    }
                }(),
                amount: DocumentMath.storedRound2(draft.amount),
                // `line_no: Number.isFinite(Number(it.line_no)) ? Number(it.line_no) : i` — an
                // absent position takes the line's index among the lines that SURVIVED the filter,
                // which is why this enumerates `kept` rather than `drafts`.
                lineNo: draft.lineNo ?? index,
                refSalesID: nonEmpty(draft.refSalesID, 200),
                refDate: nonEmpty(draft.refDate, 30))
        }
    }

    /// `safeString(v, n) || null` — clamp, then treat the empty string as absent.
    ///
    /// The clamp counts **UTF-16 code units**, via ``DocumentMath/jsSlice(_:to:)``, because that is
    /// what `slice(0, n)` counts. An earlier revision of this file used `String.prefix(n)` and
    /// registered the difference as inherited from `Transaction.normalized()`; that registration was
    /// wrong twice over — the difference is reachable (a 31-emoji `doc_number` is clamped on one
    /// side and untouched on the other, which changes what `idx_docs_type_number` calls a
    /// collision), and Q9's bar is equality with Electron rather than consistency with a different
    /// mirror. `Transaction.normalized()` is left alone: changing what IT clamps is a transactions
    /// question, not this chapter's.
    private static func nonEmpty(_ value: String?, _ maxLength: Int) -> String? {
        guard let value else { return nil }
        let clamped = DocumentMath.jsSlice(value, to: maxLength)
        return clamped.isEmpty ? nil : clamped
    }

    static func clamped(_ value: String?, _ maxLength: Int) -> SQLiteValue {
        nonEmpty(value, maxLength).map { SQLiteValue.text($0) } ?? .null
    }

    /// `num(v, null)` — `Number.isFinite(n) ? n : null`. Note the fallback: a `±∞` or `NaN`
    /// quantity is stored as SQL `NULL`, NOT as `0`.
    private static func finiteOrNil(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    /// Mirrors the ROLE of `documents.js create`'s `doc-<base36 ts>-<4 random chars>`, not its
    /// FORMAT — the same reasoning `ProductCatalog.newProductID` records: the random suffix there
    /// exists to break same-millisecond `Date.now()` collisions, a window a UUID does not have, and
    /// both sides only ever store and compare this as opaque TEXT.
    static func newBusinessDocumentID() -> String {
        "doc-" + UUID().uuidString.lowercased()
    }

    /// `documents.js STATUS_TRANSITIONS` — Q5's machine, `void` terminal.
    ///
    /// A dictionary rather than a `switch` because the empty case carries meaning: `void` maps to
    /// an EMPTY list, not to a missing key, and a reader has to be able to see that spelled out.
    static let statusTransitions: [BusinessDocumentStatus: [BusinessDocumentStatus]] = [
        .draft: [.issued, .void],
        .issued: [.void],
        .void: [],
    ]

    /// The ONE place either writer inserts document lines.
    ///
    /// Factored out so `create` and `update` cannot drift apart, and so the A8 design constraint is
    /// a countable property rather than an aspiration: `DocumentWriteSurfaceGuardTests` pins that
    /// this is the only `INSERT INTO business_document_items` in the package and that it has exactly
    /// two callers, both of which write the three header totals in the same transaction.
    ///
    /// It does NOT open a transaction of its own — SQLite has no nested transactions, and both
    /// callers are already inside one. That is the point: the lines are never visible without the
    /// totals that describe them.
    func insertDocumentLines(_ lines: [SanitizedDocumentLine], documentID: String) throws {
        for line in lines {
            try db.run("""
                INSERT INTO business_document_items
                  (doc_id, product_id, description, quantity, unit, unit_price, tax_rate,
                   tax_amount, amount, line_no, ref_sales_id, ref_date)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, [
                    .text(documentID),
                    Self.clamped(line.productID, 200),
                    .text(line.description),
                    line.quantity.map { SQLiteValue.real($0) } ?? .null,
                    Self.clamped(line.unit, 30),
                    line.unitPrice.map { SQLiteValue.real($0) } ?? .null,
                    Self.clamped(line.taxRate, 20),
                    line.taxAmount.map { SQLiteValue.real($0) } ?? .null,
                    line.amount.map { SQLiteValue.real($0) } ?? .null,
                    .integer(Int64(line.lineNo)),
                    Self.clamped(line.refSalesID, 200),
                    Self.clamped(line.refDate, 30),
                ])
        }
    }

    // MARK: - `runGuardingNumberConflict`

    /// `documents.js runGuardingNumberConflict` — a constraint violation becomes the stable code
    /// ``BusinessDocumentError/numberExists``; everything else is rethrown untouched.
    ///
    /// **The predicate is the PRIMARY result code, and that is not a detail.** The handler's test is
    /// `String(e.code).startsWith('SQLITE_CONSTRAINT')`, and better-sqlite3 fills `e.code` with the
    /// EXTENDED name — `SQLITE_CONSTRAINT_UNIQUE`, `_NOTNULL`, `_CHECK`, `_FOREIGNKEY`,
    /// `_PRIMARYKEY`. All five share the prefix, so the JS predicate is "the primary code is
    /// `SQLITE_CONSTRAINT`", and this is that predicate rather than a narrower guess at it.
    ///
    /// ## Why the neighbouring `"(code 19)"` predicate could not be copied
    ///
    /// `ProductCatalog.mapWriteFailure` used to discriminate by matching the literal `"(code 19)"`.
    /// That works on a connection opened without `SQLITE_OPEN_EXRESCODE` and **stops working on the
    /// one the app actually ships**, which sets it: `sqlite3_step` then returns the extended code, and
    /// the message reads `(code 2067)`. D-2 measured it and left the evidence here; the twelfth ruling
    /// fixed that predicate, and it now asks ``isConstraintViolation(_:)`` — this one — rather than
    /// carrying a second spelling of the same question. Measured on this machine, SQLite 3.51.0, the
    /// same five violations on the two connection kinds:
    ///
    /// ```text
    ///                 default open   activeExistingNoFollow (EXRESCODE)
    ///   UNIQUE index        19                2067
    ///   PRIMARY KEY         19                1555
    ///   NOT NULL            19                1299
    ///   FOREIGN KEY         19                 787
    ///   CHECK               19                 275
    /// ```
    ///
    /// `idx_docs_type_number` is a unique INDEX, so the number that matters here is 2067 — and a
    /// `"(code 19)"` test would call it "not a duplicate number" on the shipping path while passing
    /// every test written on a default connection. `DocumentNumberingTests` measures this mapping on a
    /// real `SQLITE_OPEN_EXRESCODE` connection for exactly that reason, and `ProductCatalogTests` now
    /// measures the whole matrix on `products` itself, both connection kinds side by side.
    ///
    /// The code is read with `LegacyConversionRunner.resultCodes(in:)` — the complete form of the
    /// `(code N)` / `(rc N)` extraction, reused rather than re-spelled — and the LAST match is the
    /// one taken, because the wrapper appends `(code N)` after the SQLite message and a `CHECK`
    /// constraint's message can quote schema text that contains a parenthesis of its own.
    static func mappingConstraintToNumberExists<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch {
            if isConstraintViolation(error) { throw BusinessDocumentError.numberExists }
            throw error
        }
    }

    static func isConstraintViolation(_ error: Error) -> Bool {
        guard let sqlite = error as? SQLiteError else { return false }
        let message: String
        switch sqlite {
        case .step(let m), .prepare(let m), .message(let m): message = m
        // The structured case: it carries its codes as fields and cannot be a constraint anyway —
        // `sqlite3_open_v2` does not fail with SQLITE_CONSTRAINT.
        case .open: return false
        }
        guard let code = LegacyConversionRunner.resultCodes(in: message).last else { return false }
        return Int32(code) & 0xFF == SQLITE_CONSTRAINT
    }
}
