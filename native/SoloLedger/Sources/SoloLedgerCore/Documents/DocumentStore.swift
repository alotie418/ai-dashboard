import Foundation

/// Reading and writing the two business-document tables — the native half of
/// `electron/handlers/documents.js`, under `docs/BUSINESS_DOCUMENTS_SPEC.md` Q9 (case 甲):
/// **write the tables schema v11 already built, add nothing, and reproduce the handler's storage
/// semantics word for word.** The one column beyond v11 is `currency`, added by D-1a at v25 for
/// Q2-d-②.
///
/// ## What is here and what is deliberately not
///
/// This round covers `create` / `get` / `list` and the line round trip. **Numbering, the status
/// machine, the editable whitelist and the delete rules are Q3/Q5 and belong to D-2**, so there is
/// no `nextNumber`, no `update`, no `remove` and no tax-invoice association in this file. Two
/// consequences worth stating rather than discovering:
///
///  * A duplicate `(doc_type, doc_number)` is refused by the unique index, and the failure arrives
///    as the raw `SQLiteError` the write threw. Mapping it to a stable code is D-2's — see the note
///    on ``BusinessDocumentError``, which carries a measurement D-2 needs.
///  * Registered form A8 — Electron's `update` recomputes the header totals only when the request
///    carried `items` — has nothing to attach to yet. The design constraint it produces (an API in
///    which lines and totals cannot move apart) binds D-2, and `create` already satisfies it: the
///    totals are computed from the lines being written, in the same transaction, always.
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

            for line in lines {
                try db.run("""
                    INSERT INTO business_document_items
                      (doc_id, product_id, description, quantity, unit, unit_price, tax_rate,
                       tax_amount, amount, line_no, ref_sales_id, ref_date)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, [
                        .text(id),
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
        return id
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
}
