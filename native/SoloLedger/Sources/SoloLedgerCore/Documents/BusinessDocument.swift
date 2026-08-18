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
/// `create` writes the literal `'draft'`, exactly as the handler's `INSERT` does. The machine
/// itself is `LedgerStore.statusTransitions`, applied by
/// ``LedgerStore/updateBusinessDocument(id:_:)``; `void` maps to an EMPTY list of successors rather
/// than to a missing entry, because being terminal is a decision and not an omission.
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

    // The formal-tax-invoice association (Q5) — a record of an invoice somebody ELSE issued, never
    // one this app produced. `create` omits all four columns exactly as the handler's `INSERT` does,
    // so a new document takes their schema defaults; ``LedgerStore/updateTaxInvoice(documentID:_:)``
    // is the only writer, and the number it writes is always the one it was handed.
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

    /// The v25 column, and the one field on this type that is not free to set.
    ///
    /// Q2-d-② permits exactly one writer, so ``LedgerStore/createBusinessDocument(_:)`` **refuses**
    /// a draft that carries a value here unless it is a `statement` whose lines came from the
    /// generator — see ``BusinessDocumentError/currencyIsGeneratedStatementsOnly``. In practice the
    /// only thing that fills it is ``StatementDraft/documentDraft(number:date:accountingLocale:)``.
    ///
    /// It stays a plain `String?` rather than becoming a type only the generator can mint, because
    /// the guarantee has to be one a TEST can violate: a constraint that the compiler makes
    /// unrepresentable is also one no reverse proof can show is still being enforced.
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

/// What the four document writers refuse.
///
/// It does NOT include "a document needs at least one line": the handler accepts an empty `items`
/// array and writes a header with zero lines and zero totals. The requirement lives in the editor
/// (`DocumentModal.tsx handleSubmit`), which is a different layer and a later round.
///
/// **Three of Electron's message strings collapse into one case each, on purpose.** `create` says
/// `'doc_number required'` where `update` says `'doc_number cannot be empty'`, and likewise for the
/// customer name and the date. Those are English sentences, not stable codes; what a caller needs to
/// branch on is which field was refused, and the user-facing wording is D-3's. The five codes the
/// spec DOES name — `DOC_NUMBER_EXISTS`, `DOC_ISSUED_VOID_FIRST`, `DOC_VOID_TAX_INVOICE_READONLY`,
/// `INVALID_ATTACHMENT_PATH`, `ATTACHMENT_IN_USE` — each keep a case of their own.
public enum BusinessDocumentError: Error, Equatable, CustomStringConvertible {
    /// `doc_number` was empty, or became empty once trimmed.
    case numberRequired
    /// `customer_name` was empty, or became empty once trimmed.
    case customerNameRequired
    /// `doc_date` was empty. The handler's test is falsy rather than trimmed, so a date of `" "` is
    /// accepted there and here — it is stored verbatim.
    case dateRequired

    /// A `currency` was supplied for something Q2-d-② does not permit to record one.
    ///
    /// Not one of the handler's refusals — `currency` is a native column and Electron has never
    /// seen it. It is here because the ruling names exactly one writer, and a constraint with no
    /// enforcement is a comment. See ``LedgerStore/createBusinessDocument(_:)``.
    case currencyIsGeneratedStatementsOnly

    /// `'Document not found'` — no row with that id. The READ API answers `nil` instead; a write
    /// has nothing to hand back, so it throws.
    case notFound

    /// `DOC_NUMBER_EXISTS`. `(doc_type, doc_number)` is a unique index, so this arrives from
    /// `create`, from an edit that changes either half, and from re-using a **voided** document's
    /// number — voiding does not release it (Q3).
    case numberExists

    /// The status machine refused: `draft → issued | void`, `issued → void`, `void` terminal.
    /// Carries both ends because the handler's message does
    /// (`Invalid status transition: issued -> draft`).
    case invalidStatusTransition(from: BusinessDocumentStatus, to: BusinessDocumentStatus)

    /// `'Only draft documents can be edited'`. Note what counts as an edit: any of the nine
    /// whitelisted fields, or the lines. A status change **alone** is not an edit, which is how an
    /// issued document can still be voided — and a legal status change bundled WITH an edit is
    /// refused for the edit's sake.
    case onlyDraftCanBeEdited

    /// `DOC_ISSUED_VOID_FIRST` — an issued document cannot be deleted. Void it first; a void
    /// document deletes, and deleting is what gives its number back.
    case issuedMustBeVoidedFirst

    /// `DOC_VOID_TAX_INVOICE_READONLY` — the association is frozen once the document is void. This
    /// fires before the request body is looked at, so it fires for an empty body too.
    case voidTaxInvoiceReadOnly

    /// `INVALID_ATTACHMENT_PATH` — not a well-formed `attachments/docs/<name>` reference.
    case invalidAttachmentPath

    /// `ATTACHMENT_IN_USE` — another document already points at that file. Sharing one copy would
    /// let either document's next edit delete the file out from under the other.
    case attachmentInUse

    public var description: String {
        switch self {
        case .numberRequired: return "numberRequired"
        case .customerNameRequired: return "customerNameRequired"
        case .dateRequired: return "dateRequired"
        case .currencyIsGeneratedStatementsOnly: return "currencyIsGeneratedStatementsOnly"
        case .notFound: return "notFound"
        case .numberExists: return "numberExists"
        case let .invalidStatusTransition(from, to):
            return "invalidStatusTransition(\(from.rawValue) -> \(to.rawValue))"
        case .onlyDraftCanBeEdited: return "onlyDraftCanBeEdited"
        case .issuedMustBeVoidedFirst: return "issuedMustBeVoidedFirst"
        case .voidTaxInvoiceReadOnly: return "voidTaxInvoiceReadOnly"
        case .invalidAttachmentPath: return "invalidAttachmentPath"
        case .attachmentInUse: return "attachmentInUse"
        }
    }
}

// MARK: - Edit models

/// A partial edit of one document — the body `PUT /api/documents/:id` accepts, minus everything the
/// handler ignores.
///
/// ## `nil` means "leave it alone"; `""` means "clear it"
///
/// This is not a convention invented here, it is the handler's own expressiveness written down. Its
/// test is `b[field] !== undefined`, so an absent key is untouched; and every nullable column is
/// written as `safeString(v, n) || null`, so an empty value — and only a truly EMPTY one — lands on
/// SQL `NULL`. One `String?` therefore carries exactly the same outcomes the JSON body carries,
/// with `nil` playing `undefined`.
///
/// **Whitespace does not clear.** `safeString` never trims, so `"   "` is truthy and is stored as
/// itself; measured on the handler for `valid_until`, `customer_tax_id` and `tax_invoice_date`
/// alike.
///
/// The three REQUIRED fields refuse to be emptied instead of clearing — but not by one rule, and
/// the difference is the handler's:
///
///  * ``number`` and ``customerName`` are clamped and THEN trimmed, so `"   "` is empty to them and
///    is refused (``BusinessDocumentError/numberRequired``, ``customerNameRequired``);
///  * ``date`` is neither clamped nor trimmed — its test is `!b.doc_date`, plain falsiness — so
///    `""` is refused (``dateRequired``) while `" "` is ACCEPTED and stored verbatim.
///
/// ## What is deliberately not here
///
/// `acc_locale` (frozen at create), `currency` (Q2-d-② gives it one writer, and that writer is
/// `create`), `subtotal` / `tax_amount` / `total` (computed, never supplied), `period_start` /
/// `period_end`, `source_sales_id`, the four `tax_invoice_*` columns (their own entry point) and
/// `id` / `created_at` / `updated_at`. Sending any of them to the handler is silently ignored;
/// here they simply cannot be expressed, and `DocumentLifecycleTests` measures that an edit leaves
/// **every** column outside the whitelist byte-identical rather than trusting the type to say so.
public struct BusinessDocumentEdit: Equatable, Sendable {
    public var type: BusinessDocumentType?
    public var number: String?
    public var date: String?
    public var validUntil: String?
    public var customerName: String?
    public var customerTaxID: String?
    public var customerAddress: String?
    public var customerContact: String?
    public var notes: String?

    /// The status to move to. Supplying the status the document already has is **not** a
    /// transition: the handler compares before it validates, so it is neither checked nor written.
    public var status: BusinessDocumentStatus?

    /// The replacement lines. `nil` leaves them alone; `[]` removes them all.
    ///
    /// **Supplying these always rewrites the three header totals in the same transaction** — the
    /// A8 design constraint. Registered form A8 says Electron recomputes the totals only when the
    /// request carried `items`; that is the storage semantics and it is reproduced. What is NOT
    /// reproduced is the reachability of a stale total: there is no way through this API to move
    /// the lines without the totals following, and `DocumentWriteSurfaceGuardTests` pins that the
    /// two writers of `business_document_items` are the only ones there are.
    ///
    /// **These lines are always sanitised as hand-entered**, because that is the only rule the
    /// handler's `update` has — `sanitizeItems` takes no mode. There is deliberately no
    /// ``BusinessDocumentLineOrigin`` here: the chapter accepts no invention outside Q2, and
    /// "Electron has no counterpart" makes the answer "do not do it" rather than "add a parameter"
    /// (spec §1). **Registered for D-4, which owns the editor:** re-saving a GENERATED statement
    /// through this path applies the blank-description drop rule, and a generated statement's lines
    /// may legitimately have no description (D-1's first ruling), so such a line — and the income it
    /// carries — would disappear from a document that goes to a customer. Nothing in this package
    /// can reach that today; the round that first can must stop and ask for a ruling rather than
    /// widen this type on its own.
    public var lines: [BusinessDocumentLineDraft]?

    public init(type: BusinessDocumentType? = nil,
                number: String? = nil,
                date: String? = nil,
                validUntil: String? = nil,
                customerName: String? = nil,
                customerTaxID: String? = nil,
                customerAddress: String? = nil,
                customerContact: String? = nil,
                notes: String? = nil,
                status: BusinessDocumentStatus? = nil,
                lines: [BusinessDocumentLineDraft]? = nil) {
        self.type = type
        self.number = number
        self.date = date
        self.validUntil = validUntil
        self.customerName = customerName
        self.customerTaxID = customerTaxID
        self.customerAddress = customerAddress
        self.customerContact = customerContact
        self.notes = notes
        self.status = status
        self.lines = lines
    }

    /// The nine fields `EDITABLE` names, plus the lines. Everything the handler counts when it asks
    /// "is this an edit?", and nothing else — the status is not on the list.
    var changesFieldsOrLines: Bool {
        type != nil || number != nil || date != nil || validUntil != nil || customerName != nil
            || customerTaxID != nil || customerAddress != nil || customerContact != nil
            || notes != nil || lines != nil
    }
}

/// The formal-tax-invoice association — the body `PUT /api/documents/:id/tax-invoice` accepts.
///
/// **This records an invoice somebody else issued. It never issues one and it never invents a
/// number** (`docs/BUSINESS_DOCUMENTS_SPEC.md` §4 · 2 and · 3; `documents.js:1-3`). ``number`` is
/// stored exactly as it arrives, trimmed; nothing in this package can put a value there that the
/// caller did not supply, and `DocumentWriteSurfaceGuardTests` checks that as source, not prose.
///
/// Same `nil`-is-absent / `""`-clears convention as ``BusinessDocumentEdit``.
///
/// The entry point is deliberately separate from ``BusinessDocumentEdit`` because the two obey
/// different rules: an association can be recorded on an **issued** document, which the draft-only
/// edit rule would forbid. `documents.js:6-7` says so in as many words.
public struct TaxInvoiceEdit: Equatable, Sendable {
    /// Whether a formal invoice was issued elsewhere. Stored as `1` / `0`, which is how the column
    /// and its JS reader both treat it.
    public var issued: Bool?
    /// The external invoice number, **typed in by a human**. Clamped to 100 code units, then
    /// trimmed; empty after that is `NULL`.
    public var number: String?
    /// The date of the external invoice. Clamped to 30 code units and stored verbatim — **not**
    /// trimmed, so `" "` is stored as `" "`. That asymmetry with ``number`` is the handler's
    /// (`safeString(v, 30) || null` versus `n && n.trim() ? n.trim() : null`), not this port's.
    public var date: String?
    /// A relative `attachments/docs/<name>` reference to the app's own copy of the invoice.
    ///
    /// The **only** field here with no length clamp: the handler passes it through `String(v)` and
    /// straight into the whitelist. A value that is not a well-formed reference is refused
    /// (``BusinessDocumentError/invalidAttachmentPath``), and one already claimed by another
    /// document is refused too (``BusinessDocumentError/attachmentInUse``) — sharing a single copy
    /// would let either document's next edit delete the file the other still points at.
    public var attachmentPath: String?

    public init(issued: Bool? = nil,
                number: String? = nil,
                date: String? = nil,
                attachmentPath: String? = nil) {
        self.issued = issued
        self.number = number
        self.date = date
        self.attachmentPath = attachmentPath
    }

    var isEmpty: Bool { issued == nil && number == nil && date == nil && attachmentPath == nil }
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
