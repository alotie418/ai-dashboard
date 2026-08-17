import Foundation

/// The five document types — `electron/handlers/documents.js DOC_TYPES`, and the `CHECK` on
/// `business_documents.doc_type` at schema v11 on both sides.
///
/// The closed set is **exactly** these five (`docs/BUSINESS_DOCUMENTS_SPEC.md` Q1: "不增、不减、
/// 不改名"). There is no receipt type, and a formal tax invoice is NOT one of these — it is the four
/// `tax_invoice_*` columns on the header, which only ever RECORD an invoice somebody else issued.
///
/// Typing the parameter as this enum takes an out-of-set `doc_type` out of the domain rather than
/// reproducing the handler's runtime refusal; the storage layer's own `CHECK` is what still refuses
/// one written past this API, and `BusinessDocumentStoreTests` measures that directly.
public enum BusinessDocumentType: String, CaseIterable, Sendable {
    case quotation
    case salesOrder = "sales_order"
    case proformaInvoice = "proforma_invoice"
    case commercialInvoice = "commercial_invoice"
    case statement
}

/// `draft → issued | void`, `issued → void`, `void` terminal — `documents.js DOC_STATUSES`.
///
/// **The transitions themselves are not this round's subject** (Q5 / D-2). What D-1 uses is the
/// initial value: `create` writes `'draft'`, exactly as the handler's `INSERT` does with a literal.
public enum BusinessDocumentStatus: String, CaseIterable, Sendable {
    case draft
    case issued
    case void
}

// MARK: - Read models

/// One row of `business_documents`, as `documents.js`'s `HEADER_COLUMNS` returns it, plus the
/// native-only `currency` column added at schema v25.
///
/// `currency` is deliberately here even though Electron's own reads cannot see it: it is a native
/// column, and Q2-d-② gives it a meaning the presentation layer needs — `nil` means "derive the
/// display currency from ``accountingLocale``" (the Q8 rule, which every pre-v25 document and every
/// non-statement document keeps), and a value means "render the header, the badge and the money
/// symbol from THIS instead".
public struct BusinessDocument: Identifiable, Hashable, Sendable {
    public let id: String
    public let type: BusinessDocumentType
    public let number: String
    public let status: BusinessDocumentStatus
    public let date: String
    public let validUntil: String?
    public let customerName: String
    public let customerTaxID: String?
    public let customerAddress: String?
    public let customerContact: String?

    /// The accounting regime frozen at create time — `documents.js resolveAccLocale`, which reads
    /// the setting once and never lets `update` move it.
    ///
    /// Optional because the column carries `NOT NULL DEFAULT 'CN'` and **no `CHECK`**: a row written
    /// by something other than the two handlers can hold any text, and `nil` reports that fact
    /// rather than substituting a regime nobody selected. Neither this API nor Electron's can
    /// produce such a row.
    public let accountingLocale: AccountingLocale?

    /// Σ of the stored line amounts. See ``DocumentMath/totals(ofLines:)`` — never recomputed from
    /// quantity × unit price.
    public let subtotal: Double?
    /// Σ of the stored line taxes.
    public let taxAmount: Double?
    /// `subtotal + taxAmount`, rounded once more.
    public let total: Double?

    public let notes: String?
    /// Informational back-link to a legacy `sales` row. Always `nil` on statements, and always
    /// `nil` on anything this native API writes — nothing in the native ledger has a `sales` row to
    /// point at.
    public let sourceSalesID: String?
    /// The statement period, inclusive at both ends (Q2 · 3).
    public let periodStart: String?
    public let periodEnd: String?

    /// Schema v25, Q2-d-②. `nil` = follow ``accountingLocale``; a value = this document is in that
    /// currency. The statement generator is its only writer in this version.
    public let currency: String?

    // The formal-tax-invoice association (Q5). READ here, never written by this round's API —
    // `create` omits all four columns exactly as the handler's `INSERT` does, so they take their
    // schema defaults. `PUT /:id/tax-invoice` is D-2's.
    public let taxInvoiceIssued: Bool
    public let taxInvoiceNumber: String?
    public let taxInvoiceDate: String?
    public let taxInvoiceAttachmentPath: String?

    public let createdAt: String?
    public let updatedAt: String?
}

/// One row of `business_document_items`.
///
/// Three fields are optional in a way that carries meaning rather than convenience:
///
///  * ``description`` is `nil` only when the cell holds no text reading at all (a BLOB). The column
///    is `TEXT NOT NULL`, so `nil` is NOT "empty" — an empty description is `""`, which is what a
///    generated statement line holds when its source transaction had none.
///  * ``taxAmount`` is `nil` when the column is SQL `NULL`, which Q2-a makes meaningful: a
///    statement line whose source transaction recorded no tax must read back as *no tax recorded*
///    so the presentation layer can show a dash instead of a confident zero.
///  * ``amount`` is `nil` on the same footing, though no writer in this package produces one.
public struct BusinessDocumentItem: Identifiable, Hashable, Sendable {
    public let id: Int
    public let productID: String?
    public let description: String?
    public let quantity: Double?
    public let unit: String?
    public let unitPrice: Double?
    /// The stored `"13%"`-form text. Parse with ``DocumentMath/taxRatePercent(from:)``.
    public let taxRate: String?
    public let taxAmount: Double?
    public let amount: Double?
    public let lineNo: Int?
    /// Back-link to the record this line was generated from — a `transactions.id` for statement
    /// lines (Q2-a), a legacy `sales.id` for anything Electron generated.
    public let refSalesID: String?
    /// The source record's date. The ONLY date carrier on a line: of the 13 columns, this is the
    /// only one whose name contains "date", which is why Q2-a lands the statement's date column
    /// here rather than choosing it.
    public let refDate: String?
}

/// A header together with its lines, in `line_no, id` order — what `GET /api/documents/:id` returns.
public struct BusinessDocumentDetail: Equatable, Sendable {
    public let document: BusinessDocument
    public let items: [BusinessDocumentItem]
}

/// The result of listing documents.
///
/// A header that cannot be identified is **counted, not dropped** — the same rule and the same
/// reason as ``ProductCatalogPage``: silently returning a shorter list makes a missing document
/// indistinguishable from one that was never there. Nothing this package writes can produce such a
/// row; the count exists so a ledger written by something else does not read as smaller than it is.
public struct BusinessDocumentPage: Equatable, Sendable {
    public let documents: [BusinessDocument]
    public let unreadableCount: Int
}

// MARK: - Write models

/// Where a document's lines came from, which decides two rules `create` applies to them.
///
/// The two faces of this chapter treat the same two edge cases differently, and the difference is
/// a ruling rather than an accident (`docs/BUSINESS_DOCUMENTS_SPEC.md` Q2-a already established the
/// principle for `COALESCE`: the invention face is under no obligation to reproduce the mirror
/// face's defects).
public enum BusinessDocumentLineOrigin: Equatable, Sendable {
    /// Somebody typed these lines. `documents.js sanitizeItems` word for word: a line whose
    /// description is blank after trimming is **dropped**, and a missing tax is **coerced to 0**.
    case handEntered

    /// The statement generator produced these lines (Q2). Two departures, both authorized:
    ///
    ///  * A blank description **keeps its line**, stored as `""`. Electron never meets this case —
    ///    its `salesToRow` prefixes the date into the description, so the text is never empty — and
    ///    Q2-b removed that prefix by giving the date its own column. Applying the drop rule here
    ///    would delete a real income transaction's money from a document that goes to a customer,
    ///    and take it out of the header totals with it.
    ///  * A `NULL` tax **stays `NULL`**. `sanitizeItems` would flatten it to `0`, after which
    ///    Q2-a's "show a dash, not a zero" is unreachable for the rest of time. The column is
    ///    nullable, so `NULL` is a value it can carry.
    ///
    /// Everything else — the trim, the length clamps, the amount rounding — is identical.
    case statementGenerator
}

/// A document to be written. Mirrors the body `POST /api/documents` accepts, minus the fields the
/// handler ignores.
public struct BusinessDocumentDraft: Equatable, Sendable {
    public var type: BusinessDocumentType
    public var number: String
    public var date: String
    public var validUntil: String?
    public var customerName: String
    public var customerTaxID: String?
    public var customerAddress: String?
    public var customerContact: String?
    public var notes: String?
    public var sourceSalesID: String?
    public var periodStart: String?
    public var periodEnd: String?
    public var currency: String?

    /// `nil` reads the ledger's `accounting_locale` setting, which is what the handler does for any
    /// body value outside the six regimes — including a missing one.
    public var accountingLocale: AccountingLocale?

    public var lines: [BusinessDocumentLineDraft]
    public var lineOrigin: BusinessDocumentLineOrigin

    public init(type: BusinessDocumentType,
                number: String,
                date: String,
                validUntil: String? = nil,
                customerName: String,
                customerTaxID: String? = nil,
                customerAddress: String? = nil,
                customerContact: String? = nil,
                notes: String? = nil,
                sourceSalesID: String? = nil,
                periodStart: String? = nil,
                periodEnd: String? = nil,
                currency: String? = nil,
                accountingLocale: AccountingLocale? = nil,
                lines: [BusinessDocumentLineDraft] = [],
                lineOrigin: BusinessDocumentLineOrigin = .handEntered) {
        self.type = type
        self.number = number
        self.date = date
        self.validUntil = validUntil
        self.customerName = customerName
        self.customerTaxID = customerTaxID
        self.customerAddress = customerAddress
        self.customerContact = customerContact
        self.notes = notes
        self.sourceSalesID = sourceSalesID
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.currency = currency
        self.accountingLocale = accountingLocale
        self.lines = lines
        self.lineOrigin = lineOrigin
    }
}

/// One line to be written. `nil` means the column is left empty, which the handler expresses as
/// `null` for every column except the two money ones — see ``BusinessDocumentLineOrigin``.
public struct BusinessDocumentLineDraft: Equatable, Sendable {
    public var productID: String?
    public var description: String
    public var quantity: Double?
    public var unit: String?
    public var unitPrice: Double?
    /// Stored verbatim in `"13%"` form. Build it from a number with the editor's own formatter when
    /// that lands (D-4); this round never converts a number into this text.
    public var taxRate: String?
    public var taxAmount: Double?
    public var amount: Double?
    /// `nil` takes the line's position in the array, which is `sanitizeItems`' `line_no: i`.
    public var lineNo: Int?
    public var refSalesID: String?
    public var refDate: String?

    public init(productID: String? = nil,
                description: String,
                quantity: Double? = nil,
                unit: String? = nil,
                unitPrice: Double? = nil,
                taxRate: String? = nil,
                taxAmount: Double? = nil,
                amount: Double? = nil,
                lineNo: Int? = nil,
                refSalesID: String? = nil,
                refDate: String? = nil) {
        self.productID = productID
        self.description = description
        self.quantity = quantity
        self.unit = unit
        self.unitPrice = unitPrice
        self.taxRate = taxRate
        self.taxAmount = taxAmount
        self.amount = amount
        self.lineNo = lineNo
        self.refSalesID = refSalesID
        self.refDate = refDate
    }
}

/// The three refusals `documents.js create` raises before it touches the database, and nothing else.
///
/// It does NOT include "a document needs at least one line": the handler accepts an empty `items`
/// array and writes a header with zero lines and zero totals. The requirement lives in the editor
/// (`DocumentModal.tsx handleSubmit`), which is a different layer and a later round.
///
/// It also does not include the duplicate-number refusal. `(doc_type, doc_number)` is a unique
/// index, so a collision surfaces as the raw `SQLiteError` the write threw; translating it into a
/// stable code is Q3's, i.e. D-2's. **A note for that round:** `ProductCatalog.mapWriteFailure`
/// discriminates by matching `"(code 19)"` in the message, and the shipping active connection is
/// opened with `SQLITE_OPEN_EXRESCODE`, so the number in that message is the EXTENDED code on the
/// path that matters. Do not copy that predicate without measuring it on a hardened connection.
public enum BusinessDocumentError: Error, Equatable, CustomStringConvertible {
    /// `doc_number` was empty, or became empty once trimmed.
    case numberRequired
    /// `customer_name` was empty, or became empty once trimmed.
    case customerNameRequired
    /// `doc_date` was empty. The handler's test is falsy rather than trimmed, so a date of `" "` is
    /// accepted there and here — it is stored verbatim.
    case dateRequired

    public var description: String {
        switch self {
        case .numberRequired: return "numberRequired"
        case .customerNameRequired: return "customerNameRequired"
        case .dateRequired: return "dateRequired"
        }
    }
}

// MARK: - Decoding

extension BusinessDocument {
    /// Decode one `business_documents` row, or `nil` when it cannot be identified.
    ///
    /// The six columns treated as identifying are the ones the table declares `NOT NULL` and the
    /// two whose `CHECK` names a closed set. A `TEXT NOT NULL` column in a non-`STRICT` table can
    /// still hold a BLOB, which has no text reading — that is the case this returns `nil` for.
    static func from(_ row: SQLiteRow) -> BusinessDocument? {
        guard let id = row.string("id"),
              let typeRaw = row.string("doc_type"), let type = BusinessDocumentType(rawValue: typeRaw),
              let number = row.string("doc_number"),
              let statusRaw = row.string("status"), let status = BusinessDocumentStatus(rawValue: statusRaw),
              let date = row.string("doc_date"),
              let customerName = row.string("customer_name")
        else { return nil }

        return BusinessDocument(
            id: id,
            type: type,
            number: number,
            status: status,
            date: date,
            validUntil: row.string("valid_until"),
            customerName: customerName,
            customerTaxID: row.string("customer_tax_id"),
            customerAddress: row.string("customer_address"),
            customerContact: row.string("customer_contact"),
            accountingLocale: row.string("acc_locale").flatMap(AccountingLocale.init(rawValue:)),
            subtotal: row.double("subtotal"),
            taxAmount: row.double("tax_amount"),
            total: row.double("total"),
            notes: row.string("notes"),
            sourceSalesID: row.string("source_sales_id"),
            periodStart: row.string("period_start"),
            periodEnd: row.string("period_end"),
            currency: row.string("currency"),
            // Any non-zero reading is "issued", which is how JS reads the column too. Read through
            // `doubleValue` rather than `SQLiteRow.int`: that accessor converts a `.real` with
            // `Int(d)`, which TRAPS on `NaN` and on magnitudes outside `Int` — a crash where an
            // unusable cell should simply read as `false`.
            taxInvoiceIssued: (row["tax_invoice_issued"].doubleValue ?? 0) != 0,
            taxInvoiceNumber: row.string("tax_invoice_number"),
            taxInvoiceDate: row.string("tax_invoice_date"),
            taxInvoiceAttachmentPath: row.string("tax_invoice_attachment_path"),
            createdAt: row.string("created_at"),
            updatedAt: row.string("updated_at"))
    }
}

extension BusinessDocumentItem {
    /// Decode one `business_document_items` row, or `nil` when it has no usable primary key.
    ///
    /// `id` is `INTEGER PRIMARY KEY AUTOINCREMENT`, so a row without an integer reading of it is
    /// not a row this table produced. Everything else decodes to whatever is stored, `nil`
    /// included — see the type's own note on why `description` is optional.
    static func from(_ row: SQLiteRow) -> BusinessDocumentItem? {
        guard let id = safeInt(row["id"]) else { return nil }
        return BusinessDocumentItem(
            id: id,
            productID: row.string("product_id"),
            description: row.string("description"),
            quantity: row.double("quantity"),
            unit: row.string("unit"),
            unitPrice: row.double("unit_price"),
            taxRate: row.string("tax_rate"),
            taxAmount: row.double("tax_amount"),
            amount: row.double("amount"),
            lineNo: safeInt(row["line_no"]),
            refSalesID: row.string("ref_sales_id"),
            refDate: row.string("ref_date"))
    }

    /// `SQLiteValue.intValue` without the trap: it spells the `.real` case `Int(d)`, which is a
    /// runtime crash for `NaN`, `±∞` and any magnitude outside `Int`. Nothing in this package writes
    /// such a value into these two columns; a ledger written by something else could.
    private static func safeInt(_ value: SQLiteValue) -> Int? {
        switch value {
        case .integer(let i): return Int(exactly: i)
        case .real(let d): return Int(exactly: d.rounded(.towardZero))
        case .text(let s): return Int(s)
        case .null, .blob: return nil
        }
    }
}
