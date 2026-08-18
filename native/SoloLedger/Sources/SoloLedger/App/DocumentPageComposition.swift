import Foundation
import SoloLedgerCore

/// What the business-documents page draws, region by region, as a value a test can hold.
///
/// ## Why this exists
///
/// The same reason `ProductPageComposition` and `InventoryPageComposition` do: XCUITest cannot run
/// in a headless session, so "is this on screen" has to be answerable structurally. The view has no
/// other source of keys — each subview takes its slice of these values and renders exactly what the
/// slice names — so `DocumentsView.swift` contains no `documents.*` literal at all, and a key that
/// is not composed cannot reach the screen.
///
/// ## What this round draws, and what it does not
///
/// D-4 owns the list page, the editor, the line table and the tax-invoice association panel. Two
/// neighbouring slices of the same namespace belong to later rounds and are deliberately absent
/// from ``placement``:
///
///  * `documents.export.*` and `documents.print.*` — the exported artefact, D-5. They are listed in
///    ``deferredPrefixes`` rather than merged in, so "this page draws every key it names" stays an
///    equality instead of becoming a filtered comparison, and `DocumentCopyTests` can keep
///    asserting that nothing names those nine yet.
///  * `nav.documents` — the sidebar entry, D-6. It is not a literal anywhere: `SidebarSection`
///    spells it `"nav.\(rawValue)"`, so it arrives with the enum case and not before.
///
/// **This page is not reachable.** There is no `SidebarSection` case, no `RootView` branch and no
/// construction site, exactly as the inventory page shipped between N-PR-4 and N-PR-6.
/// `DocumentMountingTests` pins all three zeroes.
///
/// ## Three rulings are wired into the shapes below rather than into comments
///
///  * **A statement's lines are never sent through an edit** (ruling ① of 2026-08-18). Creating a
///    statement means generating it; editing one edits the header and shows the lines read-only.
///    The consequence is structural: ``EditorBody`` has no case in which a statement carries
///    editable lines, so `BusinessDocumentEdit.lines` cannot be reached with them.
///  * **Nothing here deletes an attachment** (ruling ③). ``AttachmentBlock`` offers pick, open and
///    remove-the-reference; removing clears the association and leaves the copy on disk. The
///    registered cost is a disk leak, and the seam is a single one for the atomicity round to
///    connect.
///  * **The sidebar is D-6's** (ruling ②). Nothing in this file names a section, a count of
///    sections or an icon.
enum DocumentPageComposition {

    // MARK: - Regions

    /// Where on the page a key is drawn.
    enum Region: String, CaseIterable, Equatable {
        /// Page title and subtitle.
        case header
        /// The one control that opens the new-document editor.
        case action
        /// The row of type pills above the table.
        case filter
        /// The single sentence a refused read or write leaves behind.
        case errorBanner
        /// The seven column headings.
        case listHeader
        case typeCell
        case statusCell
        /// The tax-invoice column's two-state badge.
        case taxInvoiceCell
        /// Per-row controls. Partly reached through ``sharedKeys``.
        case rowAction
        case voidDialog
        case deleteDialog
        case empty
        /// The editor's header fields.
        case form
        /// The line table: its title, its seven column labels and its dash note.
        case itemTable
        /// The unit control inside one line. Its eleven labels are ``sharedKeys``.
        case itemUnitPicker
        /// Add / remove a line.
        case itemAction
        /// The three footer amounts.
        case totals
        /// The statement generator, which is how a statement is created.
        case statementPanel
        /// The formal-invoice association sheet.
        case taxInvoicePanel
        /// The attachment control inside that sheet.
        case attachment
    }

    // MARK: - Placement

    /// Every `documents.*` key this round draws, and the regions it belongs to.
    ///
    /// Total over `documents.*` MINUS ``deferredPrefixes``, and asserted to be — ninety-four of the
    /// hundred and three keys D-3 landed. There are no exemptions: ``exemptKeys`` is empty and the
    /// emptiness is itself asserted, so a key that has nowhere to go has to change a declaration
    /// here rather than slip into a bag.
    static let placement: [String: Set<Region>] = [
        // MARK: header (2)
        "documents.page.title": [.header],
        "documents.page.subtitle": [.header],
        // MARK: empty (1)
        "documents.page.empty": [.empty],
        // MARK: action (1)
        "documents.page.add": [.action],
        // MARK: filter (1)
        "documents.filter.all": [.filter],
        // MARK: typeCell + filter + form (5)
        //
        // One label, three places: the pill that filters by it, the cell that reports it, and the
        // editor's type control. This is a fact about the page, which is why `placement` maps to a
        // SET — forcing one region per key would either lose two of the three or need ten more keys.
        "documents.type.quotation": [.typeCell, .filter, .form],
        "documents.type.salesOrder": [.typeCell, .filter, .form],
        "documents.type.proformaInvoice": [.typeCell, .filter, .form],
        "documents.type.commercialInvoice": [.typeCell, .filter, .form],
        "documents.type.statement": [.typeCell, .filter, .form],
        // MARK: statusCell + errorBanner (3)
        //
        // The status labels are also what fills `{from}` and `{to}` in
        // `documents.error.invalidStatusTransition`. Putting the RAW values there would print
        // `draft` inside a Chinese sentence that wraps the placeholder in 「」; every one of the six
        // translations reads as a localised status label and none of them reads as an enum case.
        "documents.status.draft": [.statusCell, .errorBanner],
        "documents.status.issued": [.statusCell, .errorBanner],
        "documents.status.void": [.statusCell, .errorBanner],
        // MARK: listHeader (7)
        "documents.col.number": [.listHeader],
        "documents.col.type": [.listHeader],
        "documents.col.date": [.listHeader],
        "documents.col.customer": [.listHeader],
        "documents.col.total": [.listHeader],
        "documents.col.status": [.listHeader],
        "documents.col.taxInvoice": [.listHeader],
        // MARK: rowAction (2)
        //
        // `documents.action.void` is also the destructive button inside the confirmation, which is
        // where the French collision registered by D-3 becomes visible: `Annuler` is this key AND
        // `common.cancel`, so that dialog offers two buttons reading the same word. Mirrored and
        // registered, not fixed — changing it is a copy ruling.
        "documents.action.issue": [.rowAction],
        "documents.action.void": [.rowAction, .voidDialog],
        // MARK: voidDialog (2)
        "documents.confirm.void.title": [.voidDialog],
        "documents.confirm.void.message": [.voidDialog],
        // MARK: deleteDialog (2)
        "documents.confirm.delete.title": [.deleteDialog],
        "documents.confirm.delete.message": [.deleteDialog],
        // MARK: form (13)
        "documents.form.title": [.form],
        "documents.form.editTitle": [.form],
        "documents.form.type": [.form],
        "documents.form.number": [.form],
        "documents.form.numberHint": [.form],
        "documents.form.date": [.form],
        "documents.form.validUntil": [.form],
        "documents.form.customer": [.form],
        "documents.form.customerPlaceholder": [.form],
        "documents.form.customerTaxID": [.form],
        "documents.form.customerAddress": [.form],
        "documents.form.customerContact": [.form],
        "documents.form.notes": [.form],
        // MARK: itemTable (10)
        "documents.item.title": [.itemTable],
        "documents.item.description": [.itemTable],
        "documents.item.quantity": [.itemTable],
        "documents.item.unit": [.itemTable],
        "documents.item.unitPrice": [.itemTable],
        "documents.item.taxRate": [.itemTable],
        "documents.item.taxAmount": [.itemTable],
        "documents.item.amount": [.itemTable],
        "documents.item.dashNote": [.itemTable],
        // MARK: itemUnitPicker (1)
        "documents.item.noUnit": [.itemUnitPicker],
        // MARK: itemAction (2)
        "documents.item.add": [.itemAction],
        "documents.item.remove": [.itemAction],
        // MARK: totals (3)
        "documents.total.subtotal": [.totals],
        "documents.total.taxAmount": [.totals],
        "documents.total.total": [.totals],
        // MARK: errorBanner (15)
        "documents.error.numberRequired": [.errorBanner],
        "documents.error.customerNameRequired": [.errorBanner],
        "documents.error.dateRequired": [.errorBanner],
        "documents.error.currencyIsGeneratedStatementsOnly": [.errorBanner],
        "documents.error.notFound": [.errorBanner],
        "documents.error.numberExists": [.errorBanner],
        "documents.error.invalidStatusTransition": [.errorBanner],
        "documents.error.onlyDraftCanBeEdited": [.errorBanner],
        "documents.error.issuedMustBeVoidedFirst": [.errorBanner],
        // Two regions on purpose: it is the sentence a refused save carries, and it is also the
        // standing notice a void document's association sheet shows instead of a save button.
        "documents.error.voidTaxInvoiceReadOnly": [.errorBanner, .taxInvoicePanel],
        "documents.error.invalidAttachmentPath": [.errorBanner],
        "documents.error.attachmentInUse": [.errorBanner],
        "documents.error.itemsRequired": [.errorBanner],
        "documents.error.saveFailed": [.errorBanner],
        "documents.error.loadFailed": [.errorBanner],
        // MARK: statementPanel (8)
        "documents.statement.customer": [.statementPanel],
        "documents.statement.periodStart": [.statementPanel],
        "documents.statement.periodEnd": [.statementPanel],
        "documents.statement.generate": [.statementPanel],
        "documents.statement.noRecords": [.statementPanel],
        "documents.statement.needInput": [.statementPanel],
        "documents.statement.basisNote": [.statementPanel],
        "documents.statement.currencySplitNote": [.statementPanel],
        // MARK: taxInvoicePanel (7) + rowAction (1) + taxInvoiceCell (2)
        "documents.taxInvoice.action": [.rowAction],
        "documents.taxInvoice.title": [.taxInvoicePanel],
        "documents.taxInvoice.issuedLabel": [.taxInvoicePanel],
        "documents.taxInvoice.numberLabel": [.taxInvoicePanel],
        "documents.taxInvoice.numberHint": [.taxInvoicePanel],
        "documents.taxInvoice.dateLabel": [.taxInvoicePanel],
        "documents.taxInvoice.attachmentLabel": [.taxInvoicePanel],
        "documents.taxInvoice.compliance": [.taxInvoicePanel],
        "documents.taxInvoice.recorded": [.taxInvoiceCell],
        "documents.taxInvoice.notRecorded": [.taxInvoiceCell],
        // MARK: attachment (7)
        "documents.attachment.pick": [.attachment],
        "documents.attachment.open": [.attachment],
        "documents.attachment.remove": [.attachment],
        "documents.attachment.missing": [.attachment],
        "documents.attachment.tooLarge": [.attachment],
        "documents.attachment.failed": [.attachment],
        "documents.attachment.invalidType": [.attachment],
    ]

    /// The two families of this namespace that a LATER round draws.
    ///
    /// Named by PREFIX rather than one key at a time, and that is not a shortcut: `DocumentCopyTests`
    /// asserts each of the nine is named in production NOWHERE, and spelling them out here would be
    /// this file naming them. A prefix cannot collide with a whole key, so the declaration stays
    /// visible without becoming a use.
    ///
    /// `documents.export.*` puts the artefact on disk and `documents.print.*` goes inside it, which
    /// is D-5's subject in the split table and in `DocumentCopyTests`' own header. Drawing the
    /// export button here and leaving the artefact for D-5 would ship a control with nothing behind
    /// it, so the button waits with the file. `DocumentMountingTests` measures that the keys these
    /// prefixes cover are exactly the nine that ``placement`` does not hold.
    static let deferredPrefixes = ["documents.export.", "documents.print."]

    /// The keys this page borrows from other namespaces, and where they land.
    ///
    /// Kept OUT of ``placement`` for the reason the products page states: that map's contract is an
    /// equality against the namespace, and folding borrowed keys in would weaken it into a filtered
    /// comparison.
    ///
    /// The eleven unit labels are spelled from their stored keys rather than written out.
    /// `ProductCopyTests` asserts every `product.*` key is named as a literal by
    /// `ProductPageComposition.swift` and by no other file, and `ProductMountingTests` asserts that
    /// `ProductPageComposition` itself is named by exactly three files, none of them this one.
    /// Deriving the keys satisfies both; `DocumentMountingTests` pins the derived list against the
    /// real unit enum so a twelfth unit fails there rather than quietly losing a label.
    static let sharedKeys: [String: Set<Region>] = {
        var out: [String: Set<Region>] = [
            "common.edit": [.rowAction],
            "common.delete": [.rowAction, .deleteDialog],
            "common.cancel": [.form, .voidDialog, .deleteDialog, .taxInvoicePanel],
            "common.save": [.form, .taxInvoicePanel],
        ]
        for raw in unitRawValues { out["product.unit.\(raw)"] = [.itemUnitPicker] }
        return out
    }()

    /// The stored unit keys, in the write-side whitelist's own order.
    ///
    /// Hand-written here and nowhere else in this target, for the naming reasons above; pinned
    /// against the real enum by `DocumentMountingTests`.
    static let unitRawValues = ["piece", "box", "bag", "kg", "ton", "liter",
                               "bottle", "pack", "session", "hour", "month"]

    /// Keys written into the copy that this page deliberately does not place.
    ///
    /// Empty, and asserted to be empty. Keeping it at zero means the closure test is a plain
    /// equality; anyone who needs an exemption has to change this declaration first.
    static let exemptKeys: Set<String> = []

    /// The window title. Named here rather than in the view, so every string the page draws is
    /// reachable from this one file.
    static let pageTitleKey = "documents.page.title"

    // MARK: - Closed-set labels

    /// Q1's five types. Exhaustive with no `default`: a sixth type stops this file compiling.
    static func key(for type: BusinessDocumentType) -> String {
        switch type {
        case .quotation:         return "documents.type.quotation"
        case .salesOrder:        return "documents.type.salesOrder"
        case .proformaInvoice:   return "documents.type.proformaInvoice"
        case .commercialInvoice: return "documents.type.commercialInvoice"
        case .statement:         return "documents.type.statement"
        }
    }

    /// Q5's three states. Exhaustive with no `default`.
    static func key(for status: BusinessDocumentStatus) -> String {
        switch status {
        case .draft:  return "documents.status.draft"
        case .issued: return "documents.status.issued"
        case .void:   return "documents.status.void"
        }
    }

    // MARK: - Error copy

    /// Everything this page can refuse: the twelve the store raises, plus the three the editor
    /// raises on its own.
    ///
    /// The store's twelve arrive as a case rather than as text, so a SQLite message, a path or a
    /// driver's own wording cannot travel to the screen — only
    /// ``BusinessDocumentError/invalidStatusTransition(from:to:)`` carries a payload, and both ends
    /// of it are closed-set enums that ``key(for:)`` turns into copy keys.
    enum PageError: Equatable {
        case store(BusinessDocumentError)
        /// `documents.js` has no counterpart: the editor refuses a document with no usable line
        /// before it calls anything (`DocumentModal.tsx handleSubmit`).
        case itemsRequired
        /// Anything a write raised that is not one of the store's twelve.
        case saveFailed
        /// A read failed — opening a document for editing, or listing.
        case loadFailed
    }

    /// One refusal, ready to render.
    ///
    /// ``keyReplacements`` maps a placeholder name to ANOTHER COPY KEY, not to a literal: the view
    /// resolves both and substitutes. That is what keeps `{from}` and `{to}` reading as localised
    /// status labels in all six languages instead of leaking `draft` / `issued` / `void`.
    struct ErrorBlock: Equatable {
        let messageKey: String
        let keyReplacements: [String: String]

        var allKeys: [String] { [messageKey] + keyReplacements.values.sorted() }
    }

    /// The one place a refusal becomes a sentence. Exhaustive over both enums, no `default`.
    static func block(for error: PageError) -> ErrorBlock {
        switch error {
        case .itemsRequired: return ErrorBlock(messageKey: "documents.error.itemsRequired",
                                               keyReplacements: [:])
        case .saveFailed:    return ErrorBlock(messageKey: "documents.error.saveFailed",
                                               keyReplacements: [:])
        case .loadFailed:    return ErrorBlock(messageKey: "documents.error.loadFailed",
                                               keyReplacements: [:])
        case .store(let storeError):
            switch storeError {
            case .numberRequired:
                return ErrorBlock(messageKey: "documents.error.numberRequired", keyReplacements: [:])
            case .customerNameRequired:
                return ErrorBlock(messageKey: "documents.error.customerNameRequired", keyReplacements: [:])
            case .dateRequired:
                return ErrorBlock(messageKey: "documents.error.dateRequired", keyReplacements: [:])
            case .currencyIsGeneratedStatementsOnly:
                return ErrorBlock(messageKey: "documents.error.currencyIsGeneratedStatementsOnly",
                                  keyReplacements: [:])
            case .notFound:
                return ErrorBlock(messageKey: "documents.error.notFound", keyReplacements: [:])
            case .numberExists:
                return ErrorBlock(messageKey: "documents.error.numberExists", keyReplacements: [:])
            case let .invalidStatusTransition(from, to):
                return ErrorBlock(messageKey: "documents.error.invalidStatusTransition",
                                  keyReplacements: ["from": key(for: from), "to": key(for: to)])
            case .onlyDraftCanBeEdited:
                return ErrorBlock(messageKey: "documents.error.onlyDraftCanBeEdited", keyReplacements: [:])
            case .issuedMustBeVoidedFirst:
                return ErrorBlock(messageKey: "documents.error.issuedMustBeVoidedFirst", keyReplacements: [:])
            case .voidTaxInvoiceReadOnly:
                return ErrorBlock(messageKey: "documents.error.voidTaxInvoiceReadOnly", keyReplacements: [:])
            case .invalidAttachmentPath:
                return ErrorBlock(messageKey: "documents.error.invalidAttachmentPath", keyReplacements: [:])
            case .attachmentInUse:
                return ErrorBlock(messageKey: "documents.error.attachmentInUse", keyReplacements: [:])
            }
        }
    }

    // MARK: - Outcomes the filesystem and the generator hand back

    /// What happened to an attachment control, as a value rather than as a key.
    ///
    /// The copy keys stay in THIS file. `DocumentCopyTests` pins every `documents.*` key to exactly
    /// one naming file, and the code that touches the filesystem lives in another one; handing back
    /// a case instead of a key is what keeps that closure a single-element set.
    enum AttachmentOutcome: Equatable {
        case none
        case invalidType
        case tooLarge
        case failed
        case missing
        case invalidPath

        var messageKey: String? {
            switch self {
            case .none:        return nil
            case .invalidType: return "documents.attachment.invalidType"
            case .tooLarge:    return "documents.attachment.tooLarge"
            case .failed:      return "documents.attachment.failed"
            case .missing:     return "documents.attachment.missing"
            case .invalidPath: return "documents.error.invalidAttachmentPath"
            }
        }
    }

    /// The picker panel's title — the same sentence as the button that opens it.
    static let attachmentPanelTitleKey = "documents.attachment.pick"

    /// What the generator has to say when it produced nothing, for the same reason.
    enum StatementOutcome: Equatable {
        case needInput
        case noRecords

        var messageKey: String {
            switch self {
            case .needInput: return "documents.statement.needInput"
            case .noRecords: return "documents.statement.noRecords"
            }
        }
    }

    // MARK: - Money

    /// What goes in front of a document's digits, and how many of them there are.
    ///
    /// Mirrors `components/accountingHelpers.ts formatMoney`, which Q8 names as its evidence anchor:
    /// a symbol taken from the accounting regime, two decimals except for `JPY` and `KRW` which take
    /// none, the sign in front of the symbol rather than in front of the digits.
    struct MoneyStyle: Equatable {
        /// The symbol, or — under Q8's exception — the currency code the document itself records.
        let prefix: String
        let fractionDigits: Int
    }

    /// The six regime symbols, from `components/accountingLocaleConfig.ts`. Exhaustive, no `default`.
    static func currencySymbol(_ locale: AccountingLocale) -> String {
        switch locale {
        case .CN: return "¥"
        case .US: return "$"
        case .JP: return "¥"
        case .EU: return "€"
        case .KR: return "₩"
        case .TW: return "NT$"
        }
    }

    /// `config.defaultCurrency === 'JPY' || config.defaultCurrency === 'KRW' ? 0 : 2` — an exact,
    /// case-sensitive comparison against a currency CODE, which is why it applies unchanged to the
    /// code Q8's exception puts in the `currency` column.
    static func fractionDigits(forCurrencyCode code: String) -> Int {
        (code == "JPY" || code == "KRW") ? 0 : 2
    }

    /// How one document's money reads.
    ///
    /// Q8 in its two halves. With no `currency` recorded, the display follows the regime frozen on
    /// the row (`nil` there means the column holds something outside the six, and `getAccountingLocale`
    /// answers that with `CN` — mirrored rather than guessed at).
    ///
    /// With a `currency` recorded — Q2-d-②'s exception, and only a generated statement has one — the
    /// header, the badge and the money all follow THAT. The prefix is the stored code itself: the
    /// column holds `USD`, not `$`, and this app does not own a code-to-symbol table. Handing the
    /// code to a currency formatter would replace "what the ledger says the currency is" with "what
    /// this OS version thinks it is", which is the reason `ReportFormat` refuses the same shortcut.
    ///
    /// An EMPTY stored currency is treated as none, the truthiness rule every other nullable text
    /// column in this chapter follows. Both writers of `transactions.currency` clamp an empty value
    /// to `CNY` before storing it, so no supported path produces one.
    static func moneyStyle(currency: String?, accountingLocale: AccountingLocale?) -> MoneyStyle {
        if let currency, !currency.isEmpty {
            return MoneyStyle(prefix: currency + "\u{00A0}",
                              fractionDigits: fractionDigits(forCurrencyCode: currency))
        }
        let regime = accountingLocale ?? .CN
        return MoneyStyle(prefix: currencySymbol(regime),
                          fractionDigits: fractionDigits(forCurrencyCode: regime.defaultCurrency))
    }

    /// One amount as text, or `nil` for the em dash.
    ///
    /// `formatMoney` word for word:
    ///
    /// ```js
    /// const abs = Math.abs(amount || 0);
    /// const formatted = abs.toLocaleString(undefined, { minimumFractionDigits: d, maximumFractionDigits: d });
    /// const sign = amount < 0 ? '-' : '';
    /// return `${sign}${symbol}${formatted}`;
    /// ```
    ///
    /// Two details are load-bearing. The sign is decided on the ORIGINAL value and printed before
    /// the symbol, so a negative total reads `-¥1,234.50` and never `¥-1,234.50`. And `amount || 0`
    /// folds `NaN` and `-0` to `+0`, which is why neither can print a stray minus.
    ///
    /// `nil` is NOT zero: Q2-a says an amount the ledger never recorded shows a dash, and the
    /// dash note under the table says what the dash means.
    ///
    /// The locale is the caller's. `toLocaleString(undefined, …)` uses the HOST's default locale,
    /// not the app's UI language — so the view passes `Locale.autoupdatingCurrent` and this stays a
    /// pure function a test can pin with a fixed locale. That is a deliberate difference from the
    /// report page, which formats in the chosen UI language because its own mirror does.
    static func money(_ value: Double?, style: MoneyStyle, locale: Locale) -> String? {
        guard let value else { return nil }
        let folded = (value.isNaN || value == 0) ? 0 : value
        let sign = value < 0 ? "-" : ""
        return sign + style.prefix + digits(abs(folded), fractionDigits: style.fractionDigits,
                                            locale: locale)
    }

    /// A stored quantity or unit price as text, or `nil` for the em dash.
    ///
    /// JS `String(n)` rather than a formatter: these two columns hold whatever the other app's
    /// `parseFloat` read out of a text field, they carry no currency and no fixed scale, and putting
    /// grouping separators or a fixed decimal count on them would show a number the ledger does not
    /// hold. `nil` is a column the ledger never filled in — every line of a generated statement, by
    /// Q2-a, since a period summary describes no goods.
    static func quantityText(_ value: Double?) -> String? {
        value.map(DocumentMath.jsNumberToString)
    }

    private static func digits(_ value: Double, fractionDigits: Int, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = locale
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        return formatter.string(from: NSNumber(value: value))
            ?? String(format: "%.\(fractionDigits)f", value)
    }

    // MARK: - The type filter

    /// The pill row: `all` plus the five types, in the order the other app lists them.
    enum TypeFilter: Equatable, Hashable {
        case all
        case type(BusinessDocumentType)

        /// What the list query is asked for. `nil` is every type, which is what omitting the query
        /// parameter does on the other side.
        var storeArgument: BusinessDocumentType? {
            if case .type(let value) = self { return value }
            return nil
        }
    }

    static let filterOrder: [TypeFilter] =
        [.all] + BusinessDocumentType.allCases.map { TypeFilter.type($0) }

    struct FilterOption: Equatable, Identifiable {
        let filter: TypeFilter
        let labelKey: String
        var id: String { labelKey }
    }

    struct FilterBlock: Equatable {
        let options: [FilterOption]
        let selected: TypeFilter

        var allKeys: [String] { options.map(\.labelKey) }
    }

    // MARK: - The page's input

    /// Everything the composition needs, and nothing that could let it read the ledger itself.
    struct Input: Equatable {
        var page: BusinessDocumentPage
        var filter: TypeFilter
        /// The editor sheet, or `nil` when it is closed.
        var editor: DocumentEditorDraft?
        /// The association sheet, or `nil` when it is closed.
        var taxInvoice: TaxInvoiceDraft?
        var pendingVoid: BusinessDocument?
        var pendingDelete: BusinessDocument?
        var error: PageError?

        init(page: BusinessDocumentPage = BusinessDocumentPage(documents: [], unreadableCount: 0),
             filter: TypeFilter = .all,
             editor: DocumentEditorDraft? = nil,
             taxInvoice: TaxInvoiceDraft? = nil,
             pendingVoid: BusinessDocument? = nil,
             pendingDelete: BusinessDocument? = nil,
             error: PageError? = nil) {
            self.page = page
            self.filter = filter
            self.editor = editor
            self.taxInvoice = taxInvoice
            self.pendingVoid = pendingVoid
            self.pendingDelete = pendingDelete
            self.error = error
        }
    }

    // MARK: - One render · the list

    /// One row's controls, in the other app's own left-to-right order.
    enum RowAction: String, Equatable, Identifiable, CaseIterable {
        case edit, issue, void, delete, taxInvoice

        var labelKey: String {
            switch self {
            case .edit:       return "common.edit"
            case .issue:      return "documents.action.issue"
            case .void:       return "documents.action.void"
            case .delete:     return "common.delete"
            case .taxInvoice: return "documents.taxInvoice.action"
            }
        }

        var isDestructive: Bool { self == .delete || self == .void }
        var id: String { rawValue }
    }

    /// The tax-invoice column: a two-state badge and a paperclip that is independent of it.
    ///
    /// `taxInvoiceIssued` is a plain Bool on both sides — not the three-state free text the sales
    /// and purchase pages classify, which belongs to those pages and has no counterpart here.
    struct TaxInvoiceCell: Equatable {
        let labelKey: String
        let isRecorded: Bool
        let hasAttachment: Bool
    }

    struct RowBlock: Equatable, Identifiable {
        let document: BusinessDocument
        let typeKey: String
        let statusKey: String
        let taxInvoice: TaxInvoiceCell
        let style: MoneyStyle
        /// `start ~ end`, drawn under the date, and only for a statement that has both.
        let period: String?
        let actions: [RowAction]

        var id: String { document.id }
        var actionKeys: [String] { actions.map(\.labelKey) }
        var allKeys: [String] { [typeKey, statusKey, taxInvoice.labelKey] + actionKeys }
    }

    struct ListBlock: Equatable {
        /// The seven headings in DRAW order — the other app's screen, not the copy file's order.
        let numberHeaderKey: String
        let typeHeaderKey: String
        let dateHeaderKey: String
        let customerHeaderKey: String
        let totalHeaderKey: String
        let statusHeaderKey: String
        let taxInvoiceHeaderKey: String
        let rows: [RowBlock]

        var headerKeys: [String] {
            [numberHeaderKey, typeHeaderKey, dateHeaderKey, customerHeaderKey,
             totalHeaderKey, statusHeaderKey, taxInvoiceHeaderKey]
        }
        var allKeys: [String] { headerKeys + rows.flatMap(\.allKeys) }
    }

    // MARK: - One render · the editor

    struct TypeOption: Equatable, Identifiable {
        let type: BusinessDocumentType
        let labelKey: String
        var id: String { type.rawValue }
    }

    /// Which header field a row of the form edits. The view binds by this, so it never has to know
    /// a key or a column name.
    enum EditorField: String, Equatable, CaseIterable {
        case number, date, validUntil, customerName, customerTaxID, customerContact, customerAddress, notes
    }

    struct FieldBlock: Equatable, Identifiable {
        let field: EditorField
        let labelKey: String
        let placeholderKey: String?
        let hintKey: String?

        var id: String { field.rawValue }
        var allKeys: [String] { [labelKey] + [placeholderKey, hintKey].compactMap { $0 } }
    }

    /// One selectable product for a line. Deliberately not the store's own row type — this page
    /// reads master data, it does not manage it, and the catalogue's symbols are pinned to the page
    /// that does.
    /// Which text field of a line is being edited. The view binds by this rather than by a key
    /// path, so it names no draft type and the closed-set scan over this page's symbols stays tight.
    enum LineField: String, Equatable, CaseIterable {
        case description, quantity, unit, unitPrice, taxRatePercent
    }

    struct ProductChoice: Equatable, Identifiable {
        let id: String
        let name: String
        let unit: String
        let defaultUnitCost: Double

        init(id: String, name: String, unit: String, defaultUnitCost: Double) {
            self.id = id
            self.name = name
            self.unit = unit
            self.defaultUnitCost = defaultUnitCost
        }
    }

    /// Picking a product from a line's control — `DocumentModal.tsx onPickProduct`, mirrored.
    ///
    /// A HIT overwrites the description unconditionally, takes the product's unit, takes its default
    /// price only when that price is positive, and fills the quantity with `1` only when the field
    /// is empty. It also UNLOCKS the line, because two of the fields it writes are unlock triggers —
    /// the other app's patch carries both keys whether or not their values change.
    ///
    /// A MISS clears the product reference and touches nothing else, so a line that was carrying
    /// copied money keeps it.
    static func applyProduct(_ choice: ProductChoice?, to line: inout DocumentLineDraft) {
        guard let choice else {
            line.productID = ""
            return
        }
        let keptPrice = line.unitPrice
        let keptQuantity = line.quantity
        line.productID = choice.id
        line.description = choice.name
        line.unit = choice.unit
        // Both assignments happen unconditionally, values unchanged or not: the other app's patch
        // carries both keys either way, and carrying them is what unlocks the line.
        line.unitPrice = choice.defaultUnitCost > 0
            ? DocumentMath.jsNumberToString(choice.defaultUnitCost)
            : keptPrice
        line.quantity = keptQuantity.isEmpty ? "1" : keptQuantity
    }

    struct UnitOption: Equatable, Identifiable {
        /// What would be written. Empty means the column is cleared.
        let rawValue: String
        /// `nil` for an option that shows stored text this app has no label for.
        let labelKey: String?
        /// The text to draw when there is no label.
        let verbatim: String?

        var id: String { rawValue }
    }

    /// One editable line, already carrying its computed money.
    struct LineBlock: Equatable, Identifiable {
        let id: Int
        let productID: String
        let unitOptions: [UnitOption]
        /// The current unit selection, which is one of ``unitOptions``' raw values.
        let unit: String
        /// The two running figures. Copied verbatim for a line that is still locked, recomputed
        /// from quantity × unit price × rate for one the user has touched.
        let amount: Double
        let taxAmount: Double
        let isLocked: Bool
    }

    struct TotalsBlock: Equatable {
        let subtotalLabelKey: String
        let taxLabelKey: String
        let totalLabelKey: String
        /// `nil` draws a dash — reachable only on a stored header whose column is `NULL`.
        let subtotal: Double?
        let taxAmount: Double?
        let total: Double?
        let style: MoneyStyle

        var allKeys: [String] { [subtotalLabelKey, taxLabelKey, totalLabelKey] }
    }

    /// The seven labels above the line table, shared by both of its shapes.
    struct LineHeaderKeys: Equatable {
        let titleKey = "documents.item.title"
        let descriptionKey = "documents.item.description"
        let quantityKey = "documents.item.quantity"
        let unitKey = "documents.item.unit"
        let unitPriceKey = "documents.item.unitPrice"
        let taxRateKey = "documents.item.taxRate"
        let taxAmountKey = "documents.item.taxAmount"
        let amountKey = "documents.item.amount"

        var allKeys: [String] {
            [titleKey, descriptionKey, quantityKey, unitKey, unitPriceKey, taxRateKey,
             taxAmountKey, amountKey]
        }
    }

    struct LineEditorBlock: Equatable {
        let headers = LineHeaderKeys()
        let noUnitKey = "documents.item.noUnit"
        let addActionKey = "documents.item.add"
        let removeActionKey = "documents.item.remove"
        /// The catalogue a line can point at. Only the active items, which is the filter the other
        /// app applies to the same control.
        let productOptions: [ProductChoice]
        let lines: [LineBlock]
        let totals: TotalsBlock

        var actionKeys: [String] { [addActionKey, removeActionKey] }
        var allKeys: [String] {
            headers.allKeys + [noUnitKey] + actionKeys + totals.allKeys
                + lines.flatMap { $0.unitOptions.compactMap(\.labelKey) }
        }
    }

    /// One stored line, shown and never sent.
    struct DisplayLineBlock: Equatable, Identifiable {
        let id: Int
        let description: String
        /// `nil` in any of these draws the dash the note explains.
        let quantity: Double?
        let unitLabelKey: String?
        let unitVerbatim: String?
        let unitPrice: Double?
        let taxRate: String?
        let taxAmount: Double?
        let amount: Double?
        let refDate: String?

        var allKeys: [String] { [unitLabelKey].compactMap { $0 } }
    }

    /// Ruling ①'s shape: a statement's lines are drawn, and there is no control that could put them
    /// into a ``BusinessDocumentEdit``.
    struct LineDisplayBlock: Equatable {
        let headers = LineHeaderKeys()
        let dashNoteKey = "documents.item.dashNote"
        let lines: [DisplayLineBlock]
        let totals: TotalsBlock

        var allKeys: [String] {
            headers.allKeys + [dashNoteKey] + totals.allKeys + lines.flatMap(\.allKeys)
        }
    }

    /// The statement generator — how a statement comes into being.
    struct StatementBlock: Equatable {
        let customerLabelKey = "documents.statement.customer"
        let periodStartLabelKey = "documents.statement.periodStart"
        let periodEndLabelKey = "documents.statement.periodEnd"
        let generateActionKey = "documents.statement.generate"
        let basisNoteKey = "documents.statement.basisNote"
        let currencySplitNoteKey = "documents.statement.currencySplitNote"
        /// The picker's value domain: `transactions.counterparty`, trimmed, de-duplicated, sorted
        /// on code units. No transaction-type filter — Q2 · 4 names the column, not a subset, and
        /// the registered consequence is that a supplier can be picked and yields nothing.
        let customers: [String]
        /// `needInput` before anything was chosen, `noRecords` after a generate that found none.
        let messageKey: String?

        var noteKeys: [String] { [basisNoteKey, currencySplitNoteKey] }
        var allKeys: [String] {
            [customerLabelKey, periodStartLabelKey, periodEndLabelKey, generateActionKey]
                + noteKeys + [messageKey].compactMap { $0 }
        }
    }

    /// What the editor's body is, which is decided by the type and by whether it already exists.
    enum EditorBody: Equatable {
        /// Four of the five types, and a statement never.
        case lines(LineEditorBlock)
        /// A statement that already exists (ruling ①).
        case readOnlyLines(LineDisplayBlock)
        /// A statement being created (ruling ①: creating one means generating it).
        case generator(StatementBlock)
    }

    struct EditorBlock: Equatable {
        let titleKey: String
        let typeLabelKey: String
        let typeOptions: [TypeOption]
        /// The other app disables the control once the document exists, though its handler would
        /// accept the change. Mirrored on the tighter side, which also keeps the registered
        /// `doc_type`-changes-but-`currency`-stays shape unreachable from the interface here too.
        let typeIsLocked: Bool
        let typeKey: String
        let fields: [FieldBlock]
        /// Drawn under the line table rather than with the other header fields, which is where the
        /// other app puts it.
        let notesField: FieldBlock?
        let body: EditorBody
        let cancelActionKey: String
        /// `nil` while creating a statement: the generator writes, so there is nothing to save.
        let saveActionKey: String?

        var actionKeys: [String] { [cancelActionKey] + [saveActionKey].compactMap { $0 } }
        var allKeys: [String] {
            var keys = [titleKey, typeLabelKey] + typeOptions.map(\.labelKey) + actionKeys
            keys += fields.flatMap(\.allKeys)
            keys += notesField?.allKeys ?? []
            switch body {
            case .lines(let block):         keys += block.allKeys
            case .readOnlyLines(let block): keys += block.allKeys
            case .generator(let block):     keys += block.allKeys
            }
            return keys
        }
    }

    // MARK: - One render · the association sheet

    /// The attachment control. Ruling ③: pick, open, and drop the reference — never delete a file.
    struct AttachmentBlock: Equatable {
        let pickActionKey = "documents.attachment.pick"
        let openActionKey = "documents.attachment.open"
        let removeActionKey = "documents.attachment.remove"
        /// The name shown beside the paperclip, or `nil` when nothing is attached.
        let fileName: String?
        let canPick: Bool
        let canRemove: Bool
        /// One of the four attachment sentences, or none.
        let messageKey: String?

        var actionKeys: [String] {
            var keys: [String] = []
            if canPick { keys.append(pickActionKey) }
            if fileName != nil { keys.append(openActionKey) }
            if canRemove { keys.append(removeActionKey) }
            return keys
        }
        var allKeys: [String] { actionKeys + [messageKey].compactMap { $0 } }
    }

    struct TaxInvoiceBlock: Equatable {
        let titleKey = "documents.taxInvoice.title"
        let complianceKey = "documents.taxInvoice.compliance"
        let issuedLabelKey = "documents.taxInvoice.issuedLabel"
        let numberLabelKey = "documents.taxInvoice.numberLabel"
        let numberHintKey = "documents.taxInvoice.numberHint"
        let dateLabelKey = "documents.taxInvoice.dateLabel"
        let attachmentLabelKey = "documents.taxInvoice.attachmentLabel"
        /// The document's own number, drawn as the sheet's subtitle. A value, not a key.
        let documentNumber: String
        let attachment: AttachmentBlock
        /// A void document's association is frozen — the check that comes FIRST in the store, so a
        /// sheet with no save button is the interface saying the same thing.
        let readOnlyNoticeKey: String?
        let cancelActionKey = "common.cancel"
        /// `nil` when the document is void: the other app does not render the button either.
        let saveActionKey: String?

        var labelKeys: [String] {
            [titleKey, complianceKey, issuedLabelKey, numberLabelKey, numberHintKey,
             dateLabelKey, attachmentLabelKey]
        }
        var actionKeys: [String] { [cancelActionKey] + [saveActionKey].compactMap { $0 } }
        var allKeys: [String] {
            labelKeys + actionKeys + attachment.allKeys + [readOnlyNoticeKey].compactMap { $0 }
        }
    }

    // MARK: - One render · the two confirmations

    struct ConfirmBlock: Equatable {
        let titleKey: String
        let messageKey: String
        let confirmActionKey: String
        let cancelActionKey: String

        var actionKeys: [String] { [confirmActionKey, cancelActionKey] }
        var allKeys: [String] { [titleKey, messageKey] + actionKeys }
    }

    // MARK: - One render · the page

    struct Page: Equatable {
        let titleKey: String
        let headerKeys: [String]
        let actionKeys: [String]
        let filter: FilterBlock
        let error: ErrorBlock?
        let list: ListBlock?
        let emptyKeys: [String]
        let editor: EditorBlock?
        let taxInvoice: TaxInvoiceBlock?
        let voidConfirm: ConfirmBlock?
        let deleteConfirm: ConfirmBlock?

        var errorKeys: [String] { error?.allKeys ?? [] }

        var allKeys: Set<String> {
            var keys: Set<String> = [titleKey]
            keys.formUnion(headerKeys)
            keys.formUnion(actionKeys)
            keys.formUnion(filter.allKeys)
            keys.formUnion(errorKeys)
            keys.formUnion(list?.allKeys ?? [])
            keys.formUnion(emptyKeys)
            keys.formUnion(editor?.allKeys ?? [])
            keys.formUnion(taxInvoice?.allKeys ?? [])
            keys.formUnion(voidConfirm?.allKeys ?? [])
            keys.formUnion(deleteConfirm?.allKeys ?? [])
            return keys
        }
    }

    /// Compose the page for one input.
    static func compose(_ input: Input) -> Page {
        let rows = input.page.documents.map(row(for:))
        return Page(
            titleKey: pageTitleKey,
            headerKeys: ["documents.page.subtitle"],
            actionKeys: ["documents.page.add"],
            filter: FilterBlock(options: filterOrder.map(filterOption(for:)),
                                selected: input.filter),
            error: input.error.map(block(for:)),
            list: rows.isEmpty ? nil : ListBlock(numberHeaderKey: "documents.col.number",
                                                 typeHeaderKey: "documents.col.type",
                                                 dateHeaderKey: "documents.col.date",
                                                 customerHeaderKey: "documents.col.customer",
                                                 totalHeaderKey: "documents.col.total",
                                                 statusHeaderKey: "documents.col.status",
                                                 taxInvoiceHeaderKey: "documents.col.taxInvoice",
                                                 rows: rows),
            // The other app's list shows its empty line only when the table has no rows at all.
            // There is no "some rows could not be read" sentence in this namespace, so a page whose
            // documents are unreadable says nothing extra rather than borrowing another page's
            // wording — see ``BusinessDocumentPage/unreadableCount``, which stays uncounted here.
            emptyKeys: rows.isEmpty ? ["documents.page.empty"] : [],
            editor: input.editor.map(editorBlock(for:)),
            taxInvoice: input.taxInvoice.map(taxInvoiceBlock(for:)),
            voidConfirm: input.pendingVoid.map { _ in
                ConfirmBlock(titleKey: "documents.confirm.void.title",
                             messageKey: "documents.confirm.void.message",
                             confirmActionKey: "documents.action.void",
                             cancelActionKey: "common.cancel")
            },
            deleteConfirm: input.pendingDelete.map { _ in
                ConfirmBlock(titleKey: "documents.confirm.delete.title",
                             messageKey: "documents.confirm.delete.message",
                             confirmActionKey: "common.delete",
                             cancelActionKey: "common.cancel")
            })
    }

    private static func filterOption(for filter: TypeFilter) -> FilterOption {
        switch filter {
        case .all:              return FilterOption(filter: filter, labelKey: "documents.filter.all")
        case .type(let value):  return FilterOption(filter: filter, labelKey: key(for: value))
        }
    }

    // MARK: - Rows

    static func row(for document: BusinessDocument) -> RowBlock {
        RowBlock(document: document,
                 typeKey: key(for: document.type),
                 statusKey: key(for: document.status),
                 taxInvoice: TaxInvoiceCell(
                     labelKey: document.taxInvoiceIssued ? "documents.taxInvoice.recorded"
                                                         : "documents.taxInvoice.notRecorded",
                     isRecorded: document.taxInvoiceIssued,
                     hasAttachment: (document.taxInvoiceAttachmentPath.map { !$0.isEmpty }) ?? false),
                 style: moneyStyle(currency: document.currency,
                                   accountingLocale: document.accountingLocale),
                 period: period(of: document),
                 actions: actions(for: document.status))
    }

    /// The statement period line under the date, mirroring the condition the other app draws it on:
    /// a statement, and BOTH ends present.
    static func period(of document: BusinessDocument) -> String? {
        guard document.type == .statement,
              let start = document.periodStart, !start.isEmpty,
              let end = document.periodEnd, !end.isEmpty
        else { return nil }
        return "\(start) ~ \(end)"
    }

    /// Which controls a row offers. Q5's rules, in the other app's own left-to-right order:
    /// only a draft can be edited or issued, an issued document can still be voided, and only a
    /// document that is not issued can be deleted. The association is offered on every row —
    /// deliberately, because an invoice is recorded against documents that have been issued.
    static func actions(for status: BusinessDocumentStatus) -> [RowAction] {
        var out: [RowAction] = []
        if status == .draft { out += [.edit, .issue] }
        if status == .draft || status == .issued { out.append(.void) }
        if status != .issued { out.append(.delete) }
        out.append(.taxInvoice)
        return out
    }

    // MARK: - The editor

    private static func editorBlock(for draft: DocumentEditorDraft) -> EditorBlock {
        let isCreating = draft.editing == nil
        let isStatement = draft.type == .statement
        let generating = isCreating && isStatement
        return EditorBlock(
            titleKey: isCreating ? "documents.form.title" : "documents.form.editTitle",
            typeLabelKey: "documents.form.type",
            typeOptions: BusinessDocumentType.allCases.map {
                TypeOption(type: $0, labelKey: key(for: $0))
            },
            typeIsLocked: !isCreating,
            typeKey: key(for: draft.type),
            fields: fields(generating: generating),
            notesField: generating ? nil : FieldBlock(field: .notes,
                                                      labelKey: "documents.form.notes",
                                                      placeholderKey: nil, hintKey: nil),
            body: body(for: draft, generating: generating, isStatement: isStatement),
            cancelActionKey: "common.cancel",
            saveActionKey: generating ? nil : "common.save")
    }

    /// The header fields, in draw order.
    ///
    /// While a statement is being generated there is nothing here to fill in but the date: the
    /// number is taken one per document by the generator, the customer comes from its picker, and
    /// the remaining columns are not part of what ``StatementDraft`` writes. Showing fields whose
    /// contents would be discarded is the thing this avoids.
    private static func fields(generating: Bool) -> [FieldBlock] {
        let date = FieldBlock(field: .date, labelKey: "documents.form.date",
                              placeholderKey: nil, hintKey: nil)
        guard !generating else { return [date] }
        return [
            FieldBlock(field: .number, labelKey: "documents.form.number",
                       placeholderKey: nil, hintKey: "documents.form.numberHint"),
            date,
            FieldBlock(field: .validUntil, labelKey: "documents.form.validUntil",
                       placeholderKey: nil, hintKey: nil),
            FieldBlock(field: .customerName, labelKey: "documents.form.customer",
                       placeholderKey: "documents.form.customerPlaceholder", hintKey: nil),
            FieldBlock(field: .customerTaxID, labelKey: "documents.form.customerTaxID",
                       placeholderKey: nil, hintKey: nil),
            FieldBlock(field: .customerContact, labelKey: "documents.form.customerContact",
                       placeholderKey: nil, hintKey: nil),
            FieldBlock(field: .customerAddress, labelKey: "documents.form.customerAddress",
                       placeholderKey: nil, hintKey: nil),
        ]
    }

    private static func body(for draft: DocumentEditorDraft,
                             generating: Bool,
                             isStatement: Bool) -> EditorBody {
        if generating {
            return .generator(StatementBlock(customers: draft.statementCustomers,
                                             messageKey: draft.statementOutcome?.messageKey))
        }
        let style = moneyStyle(currency: draft.editing?.currency,
                               accountingLocale: draft.accountingLocale)
        if isStatement {
            return .readOnlyLines(LineDisplayBlock(
                lines: draft.storedLines.enumerated().map { index, item in
                    displayLine(item, position: index)
                },
                totals: TotalsBlock(subtotalLabelKey: "documents.total.subtotal",
                                    taxLabelKey: "documents.total.taxAmount",
                                    totalLabelKey: "documents.total.total",
                                    subtotal: draft.editing?.subtotal,
                                    taxAmount: draft.editing?.taxAmount,
                                    total: draft.editing?.total,
                                    style: style)))
        }
        let lines = draft.lines.map(lineBlock(for:))
        let totals = DocumentMath.totals(ofLines: lines.map {
            (amount: Optional($0.amount), taxAmount: Optional($0.taxAmount))
        })
        return .lines(LineEditorBlock(
            productOptions: draft.products,
            lines: lines,
            totals: TotalsBlock(subtotalLabelKey: "documents.total.subtotal",
                                taxLabelKey: "documents.total.taxAmount",
                                totalLabelKey: "documents.total.total",
                                subtotal: totals.subtotal,
                                taxAmount: totals.taxAmount,
                                total: totals.total,
                                style: style)))
    }

    /// One editable line's running figures — `DocumentModal.tsx computed`, mirrored.
    ///
    /// A LOCKED line copies the money it arrived with and is not recomputed; registered form A5.
    /// An unlocked one goes through Q4's two-step rounding: the line amount to the cent first, then
    /// the rate, then to the cent again. One step is a different answer.
    static func lineBlock(for line: DocumentLineDraft) -> LineBlock {
        let amount: Double
        let taxAmount: Double
        if let locked = line.locked {
            amount = DocumentMath.lineRound2(locked.amount)
            taxAmount = DocumentMath.lineRound2(locked.taxAmount)
        } else {
            amount = DocumentMath.lineAmount(
                quantity: DocumentMath.editorNumber(from: line.quantity),
                unitPrice: DocumentMath.editorNumber(from: line.unitPrice))
            taxAmount = DocumentMath.lineTax(
                amount: amount,
                ratePercent: DocumentMath.editorNumber(from: line.taxRatePercent))
        }
        return LineBlock(id: line.id,
                         productID: line.productID,
                         unitOptions: unitOptions(including: line.unit),
                         unit: line.unit,
                         amount: amount,
                         taxAmount: taxAmount,
                         isLocked: line.locked != nil)
    }

    /// The unit control's options: "no unit", the eleven, and — only when the line already holds
    /// something else — that stored text as an option of its own.
    ///
    /// The extra option exists so that opening a document written by another tool and saving it
    /// again cannot silently replace a unit the ledger holds with one this app happens to know.
    /// It is the same rule the products page applies when it shows an unrecognised unit verbatim.
    static func unitOptions(including stored: String) -> [UnitOption] {
        var out = [UnitOption(rawValue: "", labelKey: "documents.item.noUnit", verbatim: nil)]
        out += unitRawValues.map {
            UnitOption(rawValue: $0, labelKey: "product.unit.\($0)", verbatim: nil)
        }
        if !stored.isEmpty, !unitRawValues.contains(stored) {
            out.append(UnitOption(rawValue: stored, labelKey: nil, verbatim: stored))
        }
        return out
    }

    private static func displayLine(_ item: BusinessDocumentItem, position: Int) -> DisplayLineBlock {
        var labelKey: String?
        var verbatim: String?
        if let unit = item.unit, !unit.isEmpty {
            if unitRawValues.contains(unit) { labelKey = "product.unit.\(unit)" } else { verbatim = unit }
        }
        return DisplayLineBlock(id: item.id,
                                description: item.description ?? "",
                                quantity: item.quantity,
                                unitLabelKey: labelKey,
                                unitVerbatim: verbatim,
                                unitPrice: item.unitPrice,
                                taxRate: item.taxRate,
                                taxAmount: item.taxAmount,
                                amount: item.amount,
                                refDate: item.refDate)
    }

    // MARK: - The association sheet

    private static func taxInvoiceBlock(for draft: TaxInvoiceDraft) -> TaxInvoiceBlock {
        let readOnly = draft.document.status == .void
        return TaxInvoiceBlock(
            documentNumber: draft.document.number,
            attachment: AttachmentBlock(fileName: draft.attachmentFileName,
                                        canPick: !readOnly && draft.attachmentPath == nil,
                                        canRemove: !readOnly && draft.attachmentPath != nil,
                                        messageKey: draft.attachmentOutcome.messageKey),
            readOnlyNoticeKey: readOnly ? "documents.error.voidTaxInvoiceReadOnly" : nil,
            saveActionKey: readOnly ? nil : "common.save")
    }
}

// MARK: - The editor's draft

/// One editable line of a document — `DocumentModal.tsx`'s `ItemRow`, and the unlock rule with it.
///
/// The three number fields are TEXT, as they are there: an empty field and a zero are different
/// things, and a half-typed one has to survive being half-typed.
struct DocumentLineDraft: Equatable, Identifiable {
    /// The money a line arrived carrying, when it arrived carrying any.
    struct Locked: Equatable {
        let amount: Double
        let taxAmount: Double
    }

    let id: Int
    var productID: String = ""
    var description: String = ""
    /// Touching any of the three number fields UNLOCKS the line, which is exactly `setRow`'s
    /// `unlocks` condition: `patch.quantity !== undefined || patch.unitPrice !== undefined ||
    /// patch.taxRatePct !== undefined`. Description, unit and product do not unlock it.
    var quantity: String = "" { didSet { locked = nil } }
    var unit: String = ""
    var unitPrice: String = "" { didSet { locked = nil } }
    var taxRatePercent: String = "" { didSet { locked = nil } }
    private(set) var locked: Locked?
    var refSalesID: String?
    var refDate: String?

    init(id: Int) { self.id = id }

    /// Read one text field by name.
    func value(_ field: DocumentPageComposition.LineField) -> String {
        switch field {
        case .description:    return description
        case .quantity:       return quantity
        case .unit:           return unit
        case .unitPrice:      return unitPrice
        case .taxRatePercent: return taxRatePercent
        }
    }

    /// Write one text field by name. Three of the five unlock the line, and they do so through the
    /// stored properties' own observers rather than through a rule repeated here.
    mutating func setValue(_ field: DocumentPageComposition.LineField, to text: String) {
        switch field {
        case .description:    description = text
        case .quantity:       quantity = text
        case .unit:           unit = text
        case .unitPrice:      unitPrice = text
        case .taxRatePercent: taxRatePercent = text
        }
    }

    /// Seed from a stored line. Every line of an existing document arrives LOCKED — the other app's
    /// `toRow` copies the stored money rather than recomputing it, so a save that changes nothing
    /// cannot move a cent through a rounding difference.
    init(id: Int, item: BusinessDocumentItem) {
        self.id = id
        productID = item.productID ?? ""
        description = item.description ?? ""
        quantity = item.quantity.map { DocumentMath.jsNumberToString($0) } ?? ""
        unit = item.unit ?? ""
        unitPrice = item.unitPrice.map { DocumentMath.jsNumberToString($0) } ?? ""
        taxRatePercent = DocumentMath.taxRatePercent(from: item.taxRate)
            .map { DocumentMath.jsNumberToString($0) } ?? ""
        refSalesID = item.refSalesID
        refDate = item.refDate
        // Assigned last: the three `didSet`s above would otherwise clear it as the fields are seeded.
        locked = Locked(amount: item.amount ?? 0, taxAmount: item.taxAmount ?? 0)
    }

    /// What this line would be written as. `nil` for a line the other app's editor drops before it
    /// sends anything — a blank description.
    func lineDraft(position: Int) -> BusinessDocumentLineDraft? {
        guard !DocumentMath.trimmedIsEmpty(description) else { return nil }
        let amount: Double
        let taxAmount: Double
        if let locked {
            amount = DocumentMath.lineRound2(locked.amount)
            taxAmount = DocumentMath.lineRound2(locked.taxAmount)
        } else {
            amount = DocumentMath.lineAmount(quantity: DocumentMath.editorNumber(from: quantity),
                                             unitPrice: DocumentMath.editorNumber(from: unitPrice))
            taxAmount = DocumentMath.lineTax(
                amount: amount,
                ratePercent: DocumentMath.editorNumber(from: taxRatePercent))
        }
        return BusinessDocumentLineDraft(
            productID: productID.isEmpty ? nil : productID,
            description: description,
            quantity: quantity.isEmpty ? nil : DocumentMath.editorNumberOrZero(from: quantity),
            unit: unit.isEmpty ? nil : unit,
            unitPrice: unitPrice.isEmpty ? nil : DocumentMath.editorNumberOrZero(from: unitPrice),
            taxRate: DocumentMath.storedTaxRate(fromInput: taxRatePercent),
            taxAmount: taxAmount,
            amount: amount,
            lineNo: position,
            refSalesID: refSalesID,
            refDate: refDate)
    }
}

/// The editor sheet's editable state, and the rules for what a save is allowed to write.
///
/// A value type rather than a handful of `@Published` fields, so those rules are pure functions a
/// test can exercise without a view, a model or a ledger.
struct DocumentEditorDraft: Equatable {
    /// The document being edited, or `nil` for a new one.
    let editing: BusinessDocument?
    /// The lines as stored, kept whole for a statement's read-only table.
    let storedLines: [BusinessDocumentItem]
    /// The regime a new document will be created under, used only to pick a money symbol. It is
    /// never SENT: `BusinessDocumentDraft.accountingLocale` stays `nil` so the store reads the
    /// setting itself at create time, which is how the other app dodges the race between its own
    /// asynchronous settings load and a fast save.
    let accountingLocale: AccountingLocale?

    var type: BusinessDocumentType
    var number: String
    /// Once the user has typed in the number field the suggestion stops following the type, and it
    /// also has to stop an in-flight suggestion from landing. One flag does both jobs here because
    /// the suggestion is applied synchronously through the model rather than by a promise.
    var numberEdited: Bool
    var date: String
    var validUntil: String
    var customerName: String
    var customerTaxID: String
    var customerContact: String
    var customerAddress: String
    var notes: String
    var lines: [DocumentLineDraft]
    private(set) var nextLineID: Int
    /// The catalogue a line's product control offers. Seeded when the sheet opens and never read
    /// again from here — this type holds no store.
    var products: [DocumentPageComposition.ProductChoice]

    /// The generator's own fields, used only while creating a statement.
    var statementCustomers: [String]
    var statementCustomer: String
    var statementPeriodStart: String
    var statementPeriodEnd: String
    var statementOutcome: DocumentPageComposition.StatementOutcome?

    /// A new document. `date` is the caller's — the model passes today's date in its own calendar
    /// rather than this type reading a clock.
    init(type: BusinessDocumentType,
         number: String,
         date: String,
         accountingLocale: AccountingLocale?) {
        editing = nil
        storedLines = []
        self.accountingLocale = accountingLocale
        self.type = type
        self.number = number
        numberEdited = false
        self.date = date
        validUntil = ""
        customerName = ""
        customerTaxID = ""
        customerContact = ""
        customerAddress = ""
        notes = ""
        lines = [DocumentLineDraft(id: 0)]
        nextLineID = 1
        products = []
        statementCustomers = []
        statementCustomer = ""
        statementPeriodStart = ""
        statementPeriodEnd = ""
        statementOutcome = nil
    }

    /// An existing document. Only a draft ever gets here — the list offers no edit control on
    /// anything else, which is the interface saying what Q5 says.
    init(document: BusinessDocument, items: [BusinessDocumentItem]) {
        editing = document
        storedLines = items
        accountingLocale = document.accountingLocale
        type = document.type
        number = document.number
        numberEdited = true
        date = document.date
        validUntil = document.validUntil ?? ""
        customerName = document.customerName
        customerTaxID = document.customerTaxID ?? ""
        customerContact = document.customerContact ?? ""
        customerAddress = document.customerAddress ?? ""
        notes = document.notes ?? ""
        var seeded: [DocumentLineDraft] = []
        for (index, item) in items.enumerated() {
            seeded.append(DocumentLineDraft(id: index, item: item))
        }
        if seeded.isEmpty { seeded = [DocumentLineDraft(id: 0)] }
        lines = seeded
        nextLineID = seeded.count
        products = []
        statementCustomers = []
        statementCustomer = ""
        statementPeriodStart = ""
        statementPeriodEnd = ""
        statementOutcome = nil
    }

    var isCreating: Bool { editing == nil }
    /// Ruling ①: a statement's lines never travel through an edit, in either direction.
    var isGenerating: Bool { isCreating && type == .statement }
    var showsReadOnlyLines: Bool { !isCreating && type == .statement }

    mutating func addLine() {
        lines.append(DocumentLineDraft(id: nextLineID))
        nextLineID += 1
    }

    /// The other app keeps the last line: its remove control is not rendered when only one row is
    /// left, so a document can never be left with no line at all through this path.
    mutating func removeLine(id: Int) {
        guard lines.count > 1 else { return }
        lines.removeAll { $0.id == id }
    }

    var canRemoveLines: Bool { lines.count > 1 }

    /// The lines a save would send, already renumbered.
    ///
    /// `line_no` takes the position among the lines that SURVIVED the blank-description drop, which
    /// is what the other app's `validRows.map((…, idx) => …)` produces — so a dropped line leaves no
    /// hole behind it.
    var submittableLines: [BusinessDocumentLineDraft] {
        var out: [BusinessDocumentLineDraft] = []
        for line in lines {
            if let draft = line.lineDraft(position: out.count) { out.append(draft) }
        }
        return out
    }

    /// What ``LedgerStore/createBusinessDocument(_:)`` would be handed.
    ///
    /// `currency` is absent, and that is the constraint rather than an omission: Q2-d-② allows one
    /// writer and it is the generator. A hand-made draft that carried one would be refused with
    /// ``BusinessDocumentError/currencyIsGeneratedStatementsOnly``.
    func createDraft() -> BusinessDocumentDraft {
        BusinessDocumentDraft(type: type,
                              number: number,
                              date: date,
                              validUntil: nonEmpty(validUntil),
                              customerName: customerName,
                              customerTaxID: nonEmpty(customerTaxID),
                              customerAddress: nonEmpty(customerAddress),
                              customerContact: nonEmpty(customerContact),
                              notes: nonEmpty(notes),
                              accountingLocale: nil,
                              lines: submittableLines,
                              lineOrigin: .handEntered)
    }

    /// What an edit would be handed.
    ///
    /// **Ruling ① lives here.** For a statement the `lines` argument stays `nil`, so the header
    /// fields travel and the lines do not — which is what keeps a generated statement's
    /// blank-description lines and its `NULL` taxes from being rewritten by the hand-entered rules
    /// on a save that was only meant to fix a customer's name.
    func edit() -> BusinessDocumentEdit {
        BusinessDocumentEdit(type: nil,
                             number: number,
                             date: date,
                             validUntil: validUntil,
                             customerName: customerName,
                             customerTaxID: customerTaxID,
                             customerAddress: customerAddress,
                             customerContact: customerContact,
                             notes: notes,
                             lines: type == .statement ? nil : submittableLines)
    }

    private func nonEmpty(_ text: String) -> String? { text.isEmpty ? nil : text }
}

// MARK: - The association sheet's draft

/// The tax-invoice sheet's editable state.
///
/// Ruling ③ shapes one field: ``attachmentPath`` can be replaced or cleared, and nothing here — or
/// anywhere this round adds — deletes the file it used to point at. The copy that stops being
/// referenced stays on disk. That is a registered leak with a single seam, not an oversight.
struct TaxInvoiceDraft: Equatable {
    let document: BusinessDocument
    var issued: Bool
    var number: String
    var date: String
    /// The relative `attachments/docs/<name>` reference, or `nil` for none.
    private(set) var attachmentPath: String?
    /// What to show beside the paperclip: the name the user picked, or the copy's own name.
    private(set) var attachmentFileName: String?
    var attachmentOutcome: DocumentPageComposition.AttachmentOutcome = .none

    init(document: BusinessDocument) {
        self.document = document
        issued = document.taxInvoiceIssued
        number = document.taxInvoiceNumber ?? ""
        date = document.taxInvoiceDate ?? ""
        let stored = document.taxInvoiceAttachmentPath.flatMap { $0.isEmpty ? nil : $0 }
        attachmentPath = stored
        attachmentFileName = stored.map { String($0.split(separator: "/").last ?? "") }
    }

    mutating func attach(path: String, fileName: String) {
        attachmentPath = path
        attachmentFileName = fileName
        attachmentOutcome = .none
    }

    /// Drop the reference. The file is NOT removed — ruling ③.
    mutating func detach() {
        attachmentPath = nil
        attachmentFileName = nil
        attachmentOutcome = .none
    }

    /// What ``LedgerStore/updateTaxInvoice(documentID:_:)`` would be handed.
    ///
    /// Every field is supplied, including the empty ones: `nil` there means "leave it alone", and
    /// this sheet shows all four at once, so leaving one alone would silently keep a value the user
    /// had just cleared on screen. An empty string is what clears the column.
    var edit: TaxInvoiceEdit {
        TaxInvoiceEdit(issued: issued,
                       number: number,
                       date: date,
                       attachmentPath: attachmentPath ?? "")
    }
}
