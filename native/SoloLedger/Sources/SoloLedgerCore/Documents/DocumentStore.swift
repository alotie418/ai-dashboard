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
    func updateBusinessDocument(id: String, _ edit: BusinessDocumentEdit) throws {
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
            let sanitized = Self.sanitizedLines(drafts, origin: edit.lineOrigin)
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

        try Self.mappingConstraintToNumberExists {
            try db.transaction {
                try db.run("UPDATE business_documents SET \(assignments.joined(separator: ", ")) WHERE id = ?",
                           values)
                if let lines {
                    try db.run("DELETE FROM business_document_items WHERE doc_id = ?", [.text(id)])
                    try insertDocumentLines(lines, documentID: id)
                }
            }
        }
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
    @discardableResult
    func deleteBusinessDocument(id: String) throws -> String? {
        guard let row = try db.query(
            "SELECT id, status, tax_invoice_attachment_path FROM business_documents WHERE id = ?",
            [.text(id)]).first,
              let statusRaw = row.string("status"),
              let status = BusinessDocumentStatus(rawValue: statusRaw)
        else { throw BusinessDocumentError.notFound }
        guard status != .issued else { throw BusinessDocumentError.issuedMustBeVoidedFirst }

        try db.run("DELETE FROM business_documents WHERE id = ?", [.text(id)])
        return row.string("tax_invoice_attachment_path")
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
    @discardableResult
    func updateTaxInvoice(documentID: String, _ edit: TaxInvoiceEdit) throws -> String? {
        guard let row = try db.query(
            "SELECT id, status, tax_invoice_attachment_path FROM business_documents WHERE id = ?",
            [.text(documentID)]).first,
              let statusRaw = row.string("status"),
              let status = BusinessDocumentStatus(rawValue: statusRaw)
        else { throw BusinessDocumentError.notFound }
        guard status != .void else { throw BusinessDocumentError.voidTaxInvoiceReadOnly }

        let existingPath = row.string("tax_invoice_attachment_path")
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
        if let rawPath = edit.attachmentPath {
            // The handler's own shape: `null` and `''` both mean "clear it"; anything else is taken
            // as written, with NO length clamp — the whitelist below is the only thing narrowing it.
            let path: String? = rawPath.isEmpty ? nil : rawPath
            if let path {
                guard AttachmentRelPath.bareName(of: path) != nil else {
                    throw BusinessDocumentError.invalidAttachmentPath
                }
                // Ownership guard. Compared by UTF-16 code units, as JS `!==` does — Swift's own
                // `==` folds canonically equivalent spellings together, and "is this the same
                // stored string" must not.
                if !(existingPath.map { StatementText.areEqual($0, path) } ?? false) {
                    let claimed = try db.query("""
                        SELECT 1 FROM business_documents
                         WHERE tax_invoice_attachment_path = ? AND id != ? LIMIT 1
                        """, [.text(path), .text(documentID)])
                    guard claimed.isEmpty else { throw BusinessDocumentError.attachmentInUse }
                }
            }
            set("tax_invoice_attachment_path", path.map { SQLiteValue.text($0) } ?? .null)
            if let existingPath, !(path.map { StatementText.areEqual(existingPath, $0) } ?? false) {
                orphaned = existingPath
            }
        }

        if assignments.isEmpty { return nil }
        assignments.append("updated_at = datetime('now')")
        values.append(.text(documentID))
        try db.run("UPDATE business_documents SET \(assignments.joined(separator: ", ")) WHERE id = ?",
                   values)
        return orphaned
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
    /// ## Why the neighbouring `"(code 19)"` predicate must not be copied
    ///
    /// `ProductCatalog.mapWriteFailure` discriminates by matching the literal `"(code 19)"`. That
    /// works on a connection opened without `SQLITE_OPEN_EXRESCODE` and **stops working on the one
    /// the app actually ships**, which sets it: `sqlite3_step` then returns the extended code, and
    /// the message reads `(code 2067)`. Measured on this machine, SQLite 3.51.0, the same five
    /// violations on the two connection kinds:
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
    /// every test written on a default connection. `HardenedDocumentNumberConflictTests` measures
    /// this mapping on a real `SQLITE_OPEN_EXRESCODE` connection for exactly that reason.
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
