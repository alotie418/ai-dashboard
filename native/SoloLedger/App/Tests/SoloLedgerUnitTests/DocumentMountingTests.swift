import XCTest
@testable import SoloLedger
@testable import SoloLedgerCore

/// D-4 — what the business-documents page puts on screen, what it refuses to say, what it computes,
/// and the fact that no path opens it yet.
///
/// XCUITest is not available here (the runner hangs enabling automation mode in a headless session),
/// so "is it on screen" is answered structurally: `DocumentsView` holds no copy literal of its own,
/// every key it can draw comes from `DocumentPageComposition`, and the assertions below are about
/// that value. The page is also unreachable this round — there is no sidebar case, no detail-switch
/// branch and no construction site — so a behavioural test would have nothing to drive.
///
/// Three rulings of 2026-08-18 are measured here rather than described:
///
///  * **①** a statement's lines never travel through an edit, in either direction;
///  * **②** the sidebar is D-6's, so this round leaves `SidebarSection` at six;
///  * **③** nothing in this round deletes a file under the attachments directory.
@MainActor
final class DocumentMountingTests: XCTestCase {
    private let languages = ["zh-Hans", "zh-Hant", "en", "ja", "ko", "fr"]

    // MARK: - Fixtures

    private func doc(id: String = "d1",
                     type: BusinessDocumentType = .quotation,
                     number: String = "QT-2026-0001",
                     status: BusinessDocumentStatus = .draft,
                     date: String = "2026-08-18",
                     customer: String = "Acme",
                     total: Double? = 113,
                     currency: String? = nil,
                     locale: AccountingLocale? = .CN,
                     periodStart: String? = nil,
                     periodEnd: String? = nil,
                     invoiced: Bool = false,
                     attachment: String? = nil) -> BusinessDocument {
        BusinessDocument(id: id, type: type, number: number, status: status, date: date,
                         validUntil: nil, customerName: customer, customerTaxID: nil,
                         customerAddress: nil, customerContact: nil, accountingLocale: locale,
                         subtotal: 100, taxAmount: 13, total: total, notes: nil,
                         sourceSalesID: nil, periodStart: periodStart, periodEnd: periodEnd,
                         currency: currency, taxInvoiceIssued: invoiced, taxInvoiceNumber: nil,
                         taxInvoiceDate: nil, taxInvoiceAttachmentPath: attachment,
                         createdAt: nil, updatedAt: nil)
    }

    private func item(id: Int = 1,
                      description: String? = "Widget",
                      quantity: Double? = 2,
                      unit: String? = "piece",
                      unitPrice: Double? = 50,
                      taxRate: String? = "13%",
                      taxAmount: Double? = 13,
                      amount: Double? = 100,
                      refDate: String? = nil) -> BusinessDocumentItem {
        BusinessDocumentItem(id: id, productID: nil, description: description, quantity: quantity,
                             unit: unit, unitPrice: unitPrice, taxRate: taxRate,
                             taxAmount: taxAmount, amount: amount, lineNo: id - 1,
                             refSalesID: nil, refDate: refDate)
    }

    private func newEditor(type: BusinessDocumentType = .quotation) -> DocumentEditorDraft {
        DocumentEditorDraft(type: type, number: "QT-2026-0002", date: "2026-08-18",
                            accountingLocale: .CN)
    }

    /// Every shape the page has, so a key that only appears in one of them is still covered.
    private func compositions() -> [DocumentPageComposition.Page] {
        let rows = [doc(), doc(id: "d2", status: .issued), doc(id: "d3", status: .void),
                    doc(id: "d4", type: .statement, currency: "USD",
                        periodStart: "2026-01-01", periodEnd: "2026-01-31", invoiced: true,
                        attachment: "attachments/docs/a.pdf")]
        let page = BusinessDocumentPage(documents: rows, unreadableCount: 0)

        var manual = newEditor()
        manual.products = [DocumentPageComposition.ProductChoice(id: "p1", name: "Widget",
                                                                unit: "piece", defaultUnitCost: 5)]
        manual.lines[0].description = "Widget"
        manual.lines[0].quantity = "2"
        manual.lines[0].unitPrice = "50"
        manual.lines[0].taxRatePercent = "13"
        manual.addLine()

        var oddUnit = newEditor()
        oddUnit.lines[0].unit = "gross"

        var generating = newEditor(type: .statement)
        generating.statementCustomers = ["Acme", "Beta"]

        var needInput = generating
        needInput.statementOutcome = .needInput
        var noRecords = generating
        noRecords.statementOutcome = .noRecords

        let statement = DocumentEditorDraft(
            document: doc(id: "d4", type: .statement, number: "ST-2026-0001",
                          currency: "USD", periodStart: "2026-01-01", periodEnd: "2026-01-31"),
            items: [item(id: 1, description: "", quantity: nil, unit: nil, unitPrice: nil,
                         taxRate: nil, taxAmount: nil, amount: 500, refDate: "2026-01-09"),
                    item(id: 2, description: "Consulting", quantity: nil, unit: nil,
                         unitPrice: nil, taxRate: nil, taxAmount: 30, amount: 500,
                         refDate: "2026-01-20")])

        var attached = DocumentPageComposition.Input(page: page)
        attached.taxInvoice = TaxInvoiceDraft(document: doc(attachment: "attachments/docs/a.pdf"))
        var picking = DocumentPageComposition.Input(page: page)
        picking.taxInvoice = TaxInvoiceDraft(document: doc())
        var tooLarge = picking
        tooLarge.taxInvoice?.attachmentOutcome = DocumentPageComposition.AttachmentOutcome.tooLarge
        var invalidType = picking
        invalidType.taxInvoice?.attachmentOutcome = DocumentPageComposition.AttachmentOutcome.invalidType
        var missing = attached
        missing.taxInvoice?.attachmentOutcome = DocumentPageComposition.AttachmentOutcome.missing
        var failed = attached
        failed.taxInvoice?.attachmentOutcome = DocumentPageComposition.AttachmentOutcome.failed
        var badPath = attached
        badPath.taxInvoice?.attachmentOutcome = DocumentPageComposition.AttachmentOutcome.invalidPath
        var voided = DocumentPageComposition.Input(page: page)
        voided.taxInvoice = TaxInvoiceDraft(document: doc(status: .void))

        var inputs: [DocumentPageComposition.Input] = [
            DocumentPageComposition.Input(),
            DocumentPageComposition.Input(page: page),
            DocumentPageComposition.Input(page: page, filter: .type(.statement)),
            DocumentPageComposition.Input(page: page, editor: manual),
            DocumentPageComposition.Input(page: page, editor: oddUnit),
            DocumentPageComposition.Input(page: page, editor: generating),
            DocumentPageComposition.Input(page: page, editor: needInput),
            DocumentPageComposition.Input(page: page, editor: noRecords),
            DocumentPageComposition.Input(page: page, editor: statement),
            DocumentPageComposition.Input(page: page, pendingVoid: rows[0]),
            DocumentPageComposition.Input(page: page, pendingDelete: rows[0]),
            attached, picking, tooLarge, invalidType, missing, failed, badPath, voided,
        ]
        for error in Self.everyError {
            inputs.append(DocumentPageComposition.Input(page: page, error: error))
        }
        return inputs.map(DocumentPageComposition.compose)
    }

    /// One value per refusal the page can carry: the store's twelve and the editor's three.
    private static let everyError: [DocumentPageComposition.PageError] = [
        .store(.numberRequired), .store(.customerNameRequired), .store(.dateRequired),
        .store(.currencyIsGeneratedStatementsOnly), .store(.notFound), .store(.numberExists),
        .store(.invalidStatusTransition(from: .issued, to: .draft)),
        .store(.onlyDraftCanBeEdited), .store(.issuedMustBeVoidedFirst),
        .store(.voidTaxInvoiceReadOnly), .store(.invalidAttachmentPath), .store(.attachmentInUse),
        .itemsRequired, .saveFailed, .loadFailed,
    ]

    // MARK: - DM1 · the placement table is total over what this round draws

    func testDM1ThePlacementTableCoversTheNamespaceMinusTheDeferredFamilies() throws {
        let table = try sourceTable("en")
        let namespace = Set(table.keys.filter { $0.hasPrefix("documents.") })
        XCTAssertEqual(namespace.count, 103, "the namespace D-3 landed")

        let placed = Set(DocumentPageComposition.placement.keys)
        let deferred = namespace.filter { key in
            DocumentPageComposition.deferredPrefixes.contains { key.hasPrefix($0) }
        }
        XCTAssertEqual(deferred.count, 9, "four exports and five printed lines belong to D-5")
        XCTAssertEqual(placed.count, 94)
        XCTAssertEqual(placed.union(deferred), namespace, """
            placement ∪ deferred is not the namespace.
            unplaced: \(namespace.subtracting(placed).subtracting(deferred).sorted())
            invented: \(placed.subtracting(namespace).sorted())
            """)
        XCTAssertTrue(placed.isDisjoint(with: deferred), "a key cannot be both drawn and deferred")
        XCTAssertTrue(DocumentPageComposition.exemptKeys.isEmpty, """
            the exemption list is not empty. It is kept at zero so the closure above is a plain \
            equality; an exemption has to change this declaration first.
            """)
        XCTAssertTrue(placed.contains(DocumentPageComposition.pageTitleKey))
    }

    // MARK: - DM2 · every region draws something, every key lands somewhere

    func testDM2EveryRegionHasAKeyAndEveryKeyHasARegion() {
        let all = DocumentPageComposition.placement.merging(DocumentPageComposition.sharedKeys) {
            $0.union($1)
        }
        for region in DocumentPageComposition.Region.allCases {
            XCTAssertTrue(all.values.contains { $0.contains(region) },
                          "\(region.rawValue) draws nothing at all")
        }
        for (key, regions) in all {
            XCTAssertFalse(regions.isEmpty, "\(key) is placed nowhere")
        }

        // The keys that MUST be multi-region. Naming them is the point: a refactor that quietly
        // makes one single-placed would take a label off a screen nobody is looking at.
        let multi = [
            "documents.type.quotation": 3,        // filter pill, type cell, editor control
            "documents.status.void": 2,           // status cell, and the {to} of a refused transition
            "documents.action.void": 2,           // the row control and the dialog's own button
            "documents.error.voidTaxInvoiceReadOnly": 2,   // a refusal, and a standing notice
            "common.cancel": 4,
            "common.delete": 2,
            "common.save": 2,
        ]
        for (key, count) in multi {
            XCTAssertEqual(all[key]?.count, count, "\(key) is no longer drawn in \(count) places")
        }
    }

    // MARK: - DM3 · what compose() can produce is exactly what is placed

    func testDM3EveryPlacedKeyIsComposedAndEveryComposedKeyIsPlaced() {
        let produced = compositions().reduce(into: Set<String>()) { $0.formUnion($1.allKeys) }
        let declared = Set(DocumentPageComposition.placement.keys)
            .union(DocumentPageComposition.sharedKeys.keys)
        XCTAssertEqual(produced, declared, """
            never composed: \(declared.subtracting(produced).sorted())
            composed but unplaced: \(produced.subtracting(declared).sorted())
            """)
    }

    // MARK: - DM4 · a deferred key is never composed

    func testDM4TheExportedArtefactsKeysAreNeverComposed() {
        let produced = compositions().reduce(into: Set<String>()) { $0.formUnion($1.allKeys) }
        for key in produced {
            for prefix in DocumentPageComposition.deferredPrefixes {
                XCTAssertFalse(key.hasPrefix(prefix), """
                    \(key) reached a render. The exported artefact is D-5's; drawing its copy here \
                    would ship a control with nothing behind it.
                    """)
            }
        }
        // …and the check is not vacuous: the prefixes match the keys they are meant to match.
        XCTAssertTrue(DocumentPageComposition.deferredPrefixes
            .contains { "documents.export.action".hasPrefix($0) })
        XCTAssertTrue(DocumentPageComposition.deferredPrefixes
            .contains { "documents.print.disclaimer".hasPrefix($0) })
    }

    // MARK: - DM5 · the borrowed keys do not go stale

    func testDM5TheBorrowedKeysAreRealAndStayInStep() {
        let shared = DocumentPageComposition.sharedKeys
        for key in shared.keys {
            XCTAssertFalse(key.hasPrefix("documents."), """
                \(key) is this page's own copy and belongs in `placement`. Folding it into \
                `sharedKeys` would weaken DM1's equality into a filtered comparison.
                """)
        }
        XCTAssertTrue(Set(shared.keys).isDisjoint(with: Set(DocumentPageComposition.placement.keys)))

        // The eleven unit labels are derived from a hand-written list, because naming
        // `ProductPageComposition` or a `product.*` literal here would trip the products page's own
        // closed sets. This is what keeps that list honest.
        XCTAssertEqual(DocumentPageComposition.unitRawValues, ProductUnit.allCases.map(\.rawValue),
                       "the hand-written unit list has drifted from the write-side whitelist")
        let derived = Set(DocumentPageComposition.unitRawValues.map { "product.unit.\($0)" })
        XCTAssertEqual(Set(shared.keys).intersection(derived), derived)
        XCTAssertEqual(derived.count, 11)
    }

    // MARK: - DM6 · every refusal has exactly one sentence, and it is never a raw value

    func testDM6TheErrorMappingIsExhaustiveAndLocalised() throws {
        let produced = Set(Self.everyError.map { DocumentPageComposition.block(for: $0).messageKey })
        let table = try sourceTable("en")
        let landed = Set(table.keys.filter { $0.hasPrefix("documents.error.") })
        XCTAssertEqual(produced, landed, """
            never produced: \(landed.subtracting(produced).sorted())
            produced without copy: \(produced.subtracting(landed).sorted())
            """)
        XCTAssertEqual(produced.count, 15, "twelve the store raises plus the editor's three")

        // The one refusal with a payload. Its placeholders take COPY KEYS, not raw values: five of
        // the six translations wrap them in a sentence that only reads if a localised status label
        // goes in, and one wraps them in 「」.
        let block = DocumentPageComposition.block(
            for: .store(.invalidStatusTransition(from: .issued, to: .draft)))
        XCTAssertEqual(block.keyReplacements,
                       ["from": "documents.status.issued", "to": "documents.status.draft"])
        for language in languages {
            let localizer = Localizer(language: language)
            let rendered = localizer.t(block.messageKey,
                                       block.keyReplacements.mapValues { localizer.t($0) })
            XCTAssertFalse(rendered.contains("{from}"), "\(language) left a placeholder unfilled")
            XCTAssertFalse(rendered.contains("{to}"), "\(language) left a placeholder unfilled")
            XCTAssertTrue(rendered.contains(localizer.t("documents.status.issued")),
                          "\(language) does not read the {from} label: \(rendered)")
            XCTAssertTrue(rendered.contains(localizer.t("documents.status.draft")),
                          "\(language) does not read the {to} label: \(rendered)")

            // A "does it contain the word" probe cannot see this: the English sentence says
            // "a draft can be issued or voided" all by itself. The discriminating question is
            // whether the SUBSTITUTED text is the label or the raw value, so compare against the
            // rendering a raw substitution would give.
            let raw = localizer.t(block.messageKey, ["from": "issued", "to": "draft"])
            XCTAssertNotEqual(rendered, raw, """
                \(language) renders the same whether it is handed the status LABELS or the raw \
                case names, so nothing here would notice the raw ones going in.
                """)
        }
        let unfilled = Localizer(language: "en").t(block.messageKey)
        XCTAssertTrue(unfilled.contains("{from}"), "the probe cannot detect an unfilled placeholder")
    }

    /// The banner draws one sentence, or none — never two, and never nothing when there was a
    /// refusal.
    func testDM6bTheBannerCarriesExactlyOneSentence() {
        XCTAssertTrue(DocumentPageComposition.compose(DocumentPageComposition.Input()).errorKeys.isEmpty)
        for error in Self.everyError {
            let page = DocumentPageComposition.compose(
                DocumentPageComposition.Input(error: error))
            XCTAssertEqual(page.error?.messageKey.isEmpty, false)
            XCTAssertEqual(page.errorKeys.count,
                           1 + DocumentPageComposition.block(for: error).keyReplacements.count)
        }
    }

    /// Two keys that read the same word in one place, mirrored on purpose.
    ///
    /// French has one verb for both, and D-3 measured it: `documents.action.void` and
    /// `common.cancel` are both `Annuler`, and so the void confirmation offers two buttons reading
    /// the same word — one destructive, one not. The other app has the collision too, but it uses
    /// the system's own confirmation, whose buttons come from the OS; drawing our own is what makes
    /// it visible. Changing either word is a copy decision that has not been taken, so it is
    /// REGISTERED here rather than papered over — and registered as this exact pair, in this exact
    /// language and region, so any other collision still fails.
    private struct Collision {
        let language: String
        let region: DocumentPageComposition.Region
        let keys: Set<String>
    }

    private static let registeredCollisions = [
        Collision(language: "fr", region: .voidDialog,
                  keys: ["documents.action.void", "common.cancel"]),
    ]

    // MARK: - DM7 · no two keys in one place read the same

    func testDM7NoTwoKeysInOneRegionRenderTheSameText() throws {
        for language in languages {
            let table = try sourceTable(language)
            var byRegion: [DocumentPageComposition.Region: [String: String]] = [:]
            let all = DocumentPageComposition.placement.merging(DocumentPageComposition.sharedKeys) {
                $0.union($1)
            }
            for (key, regions) in all {
                guard let text = table[key] else {
                    XCTFail("\(language) has no value for \(key)"); continue
                }
                for region in regions {
                    if let clash = byRegion[region]?[text], clash != key {
                        let pair = Set([key, clash])
                        let allowed = Self.registeredCollisions
                            .contains { $0.language == language && $0.region == region && $0.keys == pair }
                        XCTAssertTrue(allowed, """
                            \(language): \(key) and \(clash) both read \(text.debugDescription) \
                            in \(region.rawValue)
                            """)
                    }
                    byRegion[region, default: [:]][text] = key
                }
            }
        }
    }

    // MARK: - DM8 · the page is reachable from nowhere

    func testDM8TheDocumentsPageIsConstructedNowhereAtAll() throws {
        let sources = try Self.appSources()
        XCTAssertGreaterThan(sources.count, 10, "the scan must have seen the app target")

        XCTAssertEqual(Self.mentions(of: "DocumentsView(", in: sources), [],
                       "nothing may construct the documents page yet — the entry point is D-6's")
        XCTAssertEqual(Self.mentions(of: "DocumentPageComposition", in: sources),
                       ["App/AppModel.swift", "App/DocumentPageComposition.swift",
                        "App/FilePanels.swift", "Views/DocumentsView.swift"])
        XCTAssertEqual(Self.mentions(of: "DocumentEditorDraft", in: sources),
                       ["App/AppModel.swift", "App/DocumentPageComposition.swift"])
        XCTAssertEqual(Self.mentions(of: "TaxInvoiceDraft", in: sources),
                       ["App/AppModel.swift", "App/DocumentPageComposition.swift"],
                       "the file-panel extension moves the model's property, never the type")

        let root = try Self.appSource("Views/RootView.swift")
        XCTAssertEqual(Self.occurrences(of: "case .documents", inCodeOf: root), 0)
        XCTAssertEqual(Self.occurrences(of: "DocumentsView(", inCodeOf: root), 0)
        XCTAssertEqual(SidebarSection.allCases.map(\.rawValue),
                       ["overview", "transactions", "categories", "products", "inventory", "reports"],
                       "ruling ②: the sidebar is untouched by this round")

        // Scanner self-proof, so a zero above means "nothing is there" and not "the scan is broken".
        XCTAssertEqual(Self.mentions(of: "DocumentsView(", in: [("X.swift", "  DocumentsView()")]),
                       ["X.swift"])
        XCTAssertEqual(Self.mentions(of: "DocumentsView(",
                                     in: [("X.swift", "  // DocumentsView() lands in D-6")]), [])
        XCTAssertEqual(Self.mentions(of: "DocumentsView(",
                                     in: [("X.swift", "  DocumentsViewModel()")]), [],
                       "whole-prefix matching only")
    }

    // MARK: - DM9 · the view says nothing of its own

    func testDM9TheViewHoldsNoCopyAndNoHiddenCode() throws {
        let view = try Self.appSource("Views/DocumentsView.swift")
        let composition = try Self.appSource("App/DocumentPageComposition.swift")

        for key in DocumentPageComposition.placement.keys {
            XCTAssertFalse(view.contains("\"\(key)\""), "\(key) is written into the view")
        }
        XCTAssertFalse(view.contains("\"documents."), """
            the view holds a documents key prefix. The whole-key loop above cannot see one that is \
            built by interpolation, and this is the half that can.
            """)
        // The identifiers it DOES hold are the page-scoped ones, which is why the prefix above is
        // safe to ban outright.
        XCTAssertTrue(view.contains("\"documentsPage.table\""))
        XCTAssertTrue(view.contains("\"documentsPage.editor\""))

        for (name, source) in [("the view", view), ("the composition", composition)] {
            XCTAssertFalse(source.contains("/*"), """
                \(name) contains a block comment. Every scan in this suite skips `//` lines only, \
                so a `/* */` block can hide code from all of them.
                """)
        }
        XCTAssertFalse(Self.namesIdentifier("ProgressView", in: view), """
            the page draws a spinner. Its reads are synchronous, so a loading frame is never \
            rendered and a spinner would be a state the page cannot be in.
            """)
    }

    // MARK: - DM10 · money reads the way the other app writes it

    func testDM10TheMoneyFormatMirrorsTheOtherApp() {
        let us = Locale(identifier: "en_US")
        let cn = DocumentPageComposition.moneyStyle(currency: nil, accountingLocale: .CN)
        XCTAssertEqual(DocumentPageComposition.money(1234.5, style: cn, locale: us), "¥1,234.50")
        XCTAssertEqual(DocumentPageComposition.money(-1234.5, style: cn, locale: us), "-¥1,234.50",
                       "the sign goes in FRONT of the symbol, as `${sign}${symbol}${n}` does")
        XCTAssertEqual(DocumentPageComposition.money(-0.0, style: cn, locale: us), "¥0.00",
                       "`amount || 0` turns -0 into +0, so no stray minus")
        XCTAssertEqual(DocumentPageComposition.money(Double.nan, style: cn, locale: us), "¥0.00",
                       "…and NaN with it")
        XCTAssertNil(DocumentPageComposition.money(nil, style: cn, locale: us),
                     "an amount the ledger never recorded is a dash, not a zero")

        for (locale, symbol, digits) in [(AccountingLocale.CN, "¥", 2), (.US, "$", 2),
                                         (.JP, "¥", 0), (.EU, "€", 2), (.KR, "₩", 0),
                                         (.TW, "NT$", 2)] {
            let style = DocumentPageComposition.moneyStyle(currency: nil, accountingLocale: locale)
            XCTAssertEqual(style.prefix, symbol)
            XCTAssertEqual(style.fractionDigits, digits, "\(locale.rawValue) decimal places")
        }
        // A regime the column does not name reads as CN, which is what `getAccountingLocale`
        // answers for anything outside its table.
        XCTAssertEqual(DocumentPageComposition.moneyStyle(currency: nil, accountingLocale: nil).prefix,
                       "¥")

        // Q8's exception: a recorded currency wins, and it is drawn as the CODE. This app owns no
        // code-to-symbol table and will not borrow the OS's.
        let usd = DocumentPageComposition.moneyStyle(currency: "USD", accountingLocale: .CN)
        XCTAssertEqual(usd.fractionDigits, 2)
        XCTAssertEqual(DocumentPageComposition.money(1234.5, style: usd, locale: us),
                       "USD\u{00A0}1,234.50")
        XCTAssertEqual(DocumentPageComposition.moneyStyle(currency: "JPY",
                                                         accountingLocale: .CN).fractionDigits, 0)
        XCTAssertEqual(DocumentPageComposition.moneyStyle(currency: "KRW",
                                                         accountingLocale: .US).fractionDigits, 0)
        // An empty cell is no currency, the truthiness rule every nullable text column here follows.
        XCTAssertEqual(DocumentPageComposition.moneyStyle(currency: "",
                                                         accountingLocale: .US).prefix, "$")
    }

    // MARK: - DM11 · ruling ① — a statement's lines never travel through an edit

    func testDM11AStatementsLinesAreNeverSentThroughAnEdit() {
        let statementDraft = DocumentEditorDraft(
            document: doc(type: .statement, number: "ST-2026-0001"),
            items: [item(id: 1, description: ""), item(id: 2)])
        XCTAssertNil(statementDraft.edit().lines, """
            ruling ①: an edit of a statement carries header fields only. Sending its lines would \
            re-sanitise them by the hand-entered rules — dropping the blank-description line and \
            the income it carries, and flattening a NULL tax into a zero nobody recorded.
            """)
        XCTAssertEqual(statementDraft.edit().customerName, "Acme",
                       "…and the header fields still travel")

        let quotationDraft = DocumentEditorDraft(document: doc(), items: [item()])
        XCTAssertEqual(quotationDraft.edit().lines?.count, 1,
                       "the other four types keep the mirrored behaviour")

        // The shape, not just the value: a statement being CREATED gets the generator and no save
        // button, and a statement being EDITED gets a read-only table.
        var generating = newEditor(type: .statement)
        generating.statementCustomers = ["Acme"]
        let creating = DocumentPageComposition.compose(
            DocumentPageComposition.Input(editor: generating))
        guard case .generator = creating.editor?.body else {
            return XCTFail("creating a statement must show the generator")
        }
        XCTAssertNil(creating.editor?.saveActionKey,
                     "the generator writes; there is nothing for a save button to do")

        let editing = DocumentPageComposition.compose(
            DocumentPageComposition.Input(editor: statementDraft))
        guard case .readOnlyLines = editing.editor?.body else {
            return XCTFail("editing a statement must show its lines read-only")
        }
        XCTAssertNotNil(editing.editor?.saveActionKey, "its header fields are still savable")

        var manual = newEditor(type: .commercialInvoice)
        manual.lines[0].description = "Widget"
        guard case .lines = DocumentPageComposition
            .compose(DocumentPageComposition.Input(editor: manual)).editor?.body else {
            return XCTFail("the other four types get the editable table")
        }
    }

    // MARK: - DM12 · the line unlock rule

    func testDM12OnlyTheThreeNumberFieldsUnlockALine() {
        var line = DocumentLineDraft(id: 0, item: item(taxAmount: 99, amount: 999))
        XCTAssertNotNil(line.locked, "a stored line arrives carrying the money it was saved with")
        XCTAssertEqual(DocumentPageComposition.lineBlock(for: line).amount, 999,
                       "and that money is copied, not recomputed from 2 × 50")

        line.setValue(.description, to: "Other")
        line.setValue(.unit, to: "box")
        XCTAssertNotNil(line.locked, "description and unit do not unlock it")

        line.setValue(.quantity, to: "2")
        XCTAssertNil(line.locked, "…and quantity does")
        XCTAssertEqual(DocumentPageComposition.lineBlock(for: line).amount, 100,
                       "an unlocked line recomputes 2 × 50")

        for field in [DocumentPageComposition.LineField.unitPrice, .taxRatePercent] {
            var other = DocumentLineDraft(id: 1, item: item())
            other.setValue(field, to: "1")
            XCTAssertNil(other.locked, "\(field.rawValue) must unlock the line")
        }

        // Q4's two-step rounding, at the input the one-step spelling gets wrong.
        var rounding = DocumentLineDraft(id: 2)
        rounding.quantity = "1"
        rounding.unitPrice = "3.335"
        rounding.taxRatePercent = "25"
        XCTAssertEqual(DocumentPageComposition.lineBlock(for: rounding).taxAmount, 0.84,
                       "round the amount to the cent FIRST; one step gives 0.83")
    }

    func testDM12bPickingAProductUnlocksAndPickingNothingDoesNot() {
        let choice = DocumentPageComposition.ProductChoice(id: "p1", name: "Widget",
                                                           unit: "box", defaultUnitCost: 7)
        var hit = DocumentLineDraft(id: 0, item: item())
        DocumentPageComposition.applyProduct(choice, to: &hit)
        XCTAssertEqual(hit.productID, "p1")
        XCTAssertEqual(hit.description, "Widget", "a hit overwrites the description unconditionally")
        XCTAssertEqual(hit.unit, "box")
        XCTAssertEqual(hit.unitPrice, "7")
        XCTAssertNil(hit.locked, "a hit writes two unlock fields, so the line recomputes")

        var zeroPriced = DocumentLineDraft(id: 1)
        zeroPriced.unitPrice = "9"
        DocumentPageComposition.applyProduct(
            DocumentPageComposition.ProductChoice(id: "p2", name: "Free", unit: "",
                                                  defaultUnitCost: 0), to: &zeroPriced)
        XCTAssertEqual(zeroPriced.unitPrice, "9", "a non-positive default price does not overwrite")
        XCTAssertEqual(zeroPriced.quantity, "1", "an empty quantity is filled with one")

        var miss = DocumentLineDraft(id: 2, item: item())
        DocumentPageComposition.applyProduct(nil, to: &miss)
        XCTAssertEqual(miss.productID, "")
        XCTAssertNotNil(miss.locked, "clearing the product touches nothing else")
        XCTAssertEqual(miss.description, "Widget")
    }

    // MARK: - DM13 · no table cell reads the environment

    func testDM13NoTableCellLooksUpTheEnvironmentObject() throws {
        let view = try Self.appSource("Views/DocumentsView.swift")
        let cells = ["DocumentTextCell", "DocumentDateCell", "DocumentAmountCell",
                     "DocumentTaxInvoiceCell", "DocumentRowActions"]
        for cell in cells {
            let body = try Self.structBody(named: cell, in: view)
            XCTAssertFalse(Self.namesIdentifier("EnvironmentObject", in: body), """
                \(cell) declares an @EnvironmentObject. `Table` materialises its cells again \
                outside the render pass when an accessibility client walks the page, and the \
                lookup traps there.
                """)
        }
        // The reverse half, without which "the whole file never reads the model" would also pass.
        let container = try Self.structBody(named: "DocumentsTable", in: view)
        XCTAssertTrue(Self.namesIdentifier("EnvironmentObject", in: container),
                      "the enclosing table must be the one that reads the model")
        // …and the parser is not returning an empty string.
        XCTAssertGreaterThan(container.count, 200)
    }

    // MARK: - DM14 · what a save would send

    func testDM14ABlankDescriptionDropsItsLineAndTheRestClosesUp() {
        var draft = newEditor()
        draft.lines[0].description = "First"
        draft.lines[0].quantity = "1"
        draft.lines[0].unitPrice = "10"
        draft.addLine()
        draft.lines[1].description = "   "
        draft.lines[1].quantity = "1"
        draft.lines[1].unitPrice = "999"
        draft.addLine()
        draft.lines[2].description = "Third"
        draft.lines[2].quantity = "1"
        draft.lines[2].unitPrice = "20"
        draft.lines[2].taxRatePercent = "13"

        let lines = draft.submittableLines
        XCTAssertEqual(lines.count, 2, "the blank-description line is dropped before anything is sent")
        XCTAssertEqual(lines.map(\.description), ["First", "Third"])
        XCTAssertEqual(lines.map(\.lineNo), [0, 1], """
            line_no takes the position among the lines that SURVIVED, so a dropped line leaves no \
            hole behind it.
            """)
        XCTAssertEqual(lines[1].taxRate, "13%", "the rate is stored in its text form")
        XCTAssertNil(lines[0].taxRate, "an empty rate field clears the column rather than storing 0%")
        XCTAssertEqual(lines[1].amount, 20)
        XCTAssertEqual(lines[1].taxAmount, 2.6)
    }

    func testDM14bTheCreateDraftCarriesNoCurrencyAndNoRegime() {
        var draft = newEditor()
        draft.lines[0].description = "Widget"
        let created = draft.createDraft()
        XCTAssertNil(created.currency, """
            Q2-d-② allows one writer of that column and it is the generator; a hand-made draft \
            carrying one is refused with currencyIsGeneratedStatementsOnly.
            """)
        XCTAssertNil(created.accountingLocale, """
            nil makes the store read the setting itself at create time, which is how the other app \
            dodges the race between its asynchronous settings load and a fast save.
            """)
        XCTAssertEqual(created.lineOrigin, .handEntered)
    }

    // MARK: - DM15 · which controls a row offers

    func testDM15TheRowControlsFollowTheStatusMachine() {
        XCTAssertEqual(DocumentPageComposition.actions(for: .draft),
                       [.edit, .issue, .void, .delete, .taxInvoice])
        XCTAssertEqual(DocumentPageComposition.actions(for: .issued), [.void, .taxInvoice],
                       "an issued document cannot be edited, re-issued, or deleted directly")
        XCTAssertEqual(DocumentPageComposition.actions(for: .void), [.delete, .taxInvoice],
                       "a void document can be deleted — that is what gives its number back")
        for status in BusinessDocumentStatus.allCases {
            XCTAssertTrue(DocumentPageComposition.actions(for: status).contains(.taxInvoice), """
                the association is offered on every row: an invoice is recorded against documents \
                that have already been issued.
                """)
        }
        // The period sub-line, on the one type and the one condition that draws it.
        XCTAssertEqual(DocumentPageComposition.period(of: doc(type: .statement,
                                                             periodStart: "2026-01-01",
                                                             periodEnd: "2026-01-31")),
                       "2026-01-01 ~ 2026-01-31")
        XCTAssertNil(DocumentPageComposition.period(of: doc(type: .statement,
                                                           periodStart: "2026-01-01")),
                     "one end is not a period")
        XCTAssertNil(DocumentPageComposition.period(of: doc(periodStart: "2026-01-01",
                                                           periodEnd: "2026-01-31")),
                     "and a quotation that somehow holds one does not show it")
    }

    // MARK: - DM16 · ruling ③ — the attachment control never deletes

    func testDM16NothingInThisRoundDeletesAnAttachment() throws {
        for relative in ["App/FilePanels.swift", "App/AppModel.swift",
                         "App/DocumentPageComposition.swift", "Views/DocumentsView.swift"] {
            let source = try Self.appSource(relative)
            for deleter in ["removeItem", "trashItem", "unlink", "removeFile"] {
                XCTAssertFalse(Self.namesIdentifier(deleter, in: source), """
                    \(relative) names \(deleter). Ruling ③ keeps this round free of any path that \
                    removes a file under the attachments directory: the spec's §3 upgrade clause \
                    turns the three registered check-then-act windows into must-fix items the \
                    moment one exists.
                    """)
            }
        }
        // The probe can see a deleter — otherwise the four zeroes above mean nothing.
        XCTAssertTrue(Self.namesIdentifier("removeItem", in: "try FileManager.default.removeItem(at: url)"))

        // Dropping the reference is a state change and nothing more.
        var draft = TaxInvoiceDraft(document: doc(attachment: "attachments/docs/a.pdf"))
        XCTAssertEqual(draft.attachmentPath, "attachments/docs/a.pdf")
        draft.detach()
        XCTAssertNil(draft.attachmentPath)
        XCTAssertEqual(draft.edit.attachmentPath, "", "an empty string is what clears the column")
    }

    func testDM16bThePickedCopysNameSatisfiesTheAttachmentWhitelist() {
        for id in ["d-1_A", "..///..", "", String(repeating: "x", count: 90), "__lead", "-lead"] {
            let name = AppModel.taxInvoiceAttachmentName(documentID: id, extension: "pdf")
            XCTAssertNotNil(AttachmentRelPath.bareName(of: "attachments/docs/\(name)"), """
                \(name.debugDescription) (from id \(id.debugDescription)) is not a name the \
                attachment whitelist accepts, so the reference could never be opened again.
                """)
            XCTAssertTrue(name.hasSuffix(".pdf"))
        }
        XCTAssertEqual(AppModel.taxInvoiceAttachmentMaxBytes, 20 * 1024 * 1024,
                       "the other app's MAX_BYTES, to the byte")
        XCTAssertEqual(AppModel.taxInvoiceAttachmentMaxBytes, 20_971_520)
        XCTAssertEqual(AppModel.taxInvoiceAttachmentExtensions, ["pdf", "jpg", "jpeg", "png"])
    }

    // MARK: - DM17 · the unit control preserves what it cannot label

    func testDM17AnUnrecognisedUnitKeepsItsOwnOption() {
        let known = DocumentPageComposition.unitOptions(including: "kg")
        XCTAssertEqual(known.count, 12, "no unit, plus the eleven")
        XCTAssertEqual(known.first?.rawValue, "")
        XCTAssertEqual(known.first?.labelKey, "documents.item.noUnit")

        let odd = DocumentPageComposition.unitOptions(including: "gross")
        XCTAssertEqual(odd.count, 13)
        XCTAssertEqual(odd.last?.rawValue, "gross")
        XCTAssertNil(odd.last?.labelKey, "this app has no label for a unit it does not know")
        XCTAssertEqual(odd.last?.verbatim, "gross", """
            …so it shows the stored text. Dropping the option would make the control select nothing \
            and a save would then replace a unit the ledger holds with one the user never chose.
            """)
        XCTAssertEqual(DocumentPageComposition.unitOptions(including: "").count, 12)
    }

    // MARK: - DM18 · the editor's header fields

    func testDM18TheGeneratorShowsOnlyTheFieldsItActuallyUses() {
        var generating = newEditor(type: .statement)
        generating.statementCustomers = ["Acme"]
        let creating = DocumentPageComposition.compose(
            DocumentPageComposition.Input(editor: generating))
        XCTAssertEqual(creating.editor?.fields.map(\.field), [.date], """
            the generator takes its own number per document and its customer from the picker; a \
            field whose contents would be discarded should not be on screen.
            """)
        XCTAssertNil(creating.editor?.notesField)
        XCTAssertFalse(creating.editor?.typeIsLocked ?? true, "the type is still choosable")

        var manual = newEditor()
        manual.lines[0].description = "Widget"
        let editor = DocumentPageComposition.compose(
            DocumentPageComposition.Input(editor: manual)).editor
        XCTAssertEqual(editor?.fields.map(\.field),
                       [.number, .date, .validUntil, .customerName, .customerTaxID,
                        .customerContact, .customerAddress])
        XCTAssertEqual(editor?.notesField?.field, .notes)
        XCTAssertEqual(Set(DocumentPageComposition.EditorField.allCases),
                       Set((editor?.fields.map(\.field) ?? []) + [.notes]),
                       "every field the enum names has a row somewhere")

        let existing = DocumentPageComposition.compose(
            DocumentPageComposition.Input(editor: DocumentEditorDraft(document: doc(),
                                                                      items: [item()])))
        XCTAssertTrue(existing.editor?.typeIsLocked ?? false,
                      "the other app locks the type control once the document exists")
    }

    // MARK: - DM19 · the empty state

    func testDM19TheEmptyLineShowsOnlyWhenThereIsNothingToList() {
        let empty = DocumentPageComposition.compose(DocumentPageComposition.Input())
        XCTAssertEqual(empty.emptyKeys, ["documents.page.empty"])
        XCTAssertNil(empty.list)

        let filled = DocumentPageComposition.compose(
            DocumentPageComposition.Input(page: BusinessDocumentPage(documents: [doc()],
                                                                    unreadableCount: 0)))
        XCTAssertTrue(filled.emptyKeys.isEmpty, "the list and the empty line never share a screen")
        XCTAssertEqual(filled.list?.rows.count, 1)

        // There is no "some rows could not be read" sentence in this namespace, so a page whose
        // documents are unreadable says nothing extra rather than borrowing another page's wording.
        let unreadable = DocumentPageComposition.compose(
            DocumentPageComposition.Input(page: BusinessDocumentPage(documents: [],
                                                                    unreadableCount: 3)))
        XCTAssertEqual(unreadable.emptyKeys, ["documents.page.empty"])
    }

    // MARK: - DM20 · the filter row

    func testDM20TheFilterOffersAllSixAndAsksTheQueryForOne() {
        let page = DocumentPageComposition.compose(
            DocumentPageComposition.Input(filter: .type(.statement)))
        XCTAssertEqual(page.filter.options.count, 6)
        XCTAssertEqual(page.filter.options.first?.labelKey, "documents.filter.all")
        XCTAssertEqual(page.filter.selected, .type(.statement))
        XCTAssertEqual(DocumentPageComposition.TypeFilter.all.storeArgument, nil,
                       "all is the absent query parameter, not a sixth type")
        for type in BusinessDocumentType.allCases {
            XCTAssertEqual(DocumentPageComposition.TypeFilter.type(type).storeArgument, type)
        }
    }


    // MARK: - DM21 · the statement line table is Q2-b's four columns

    /// A statement's lines are NOT the six-column table with cells left blank.
    ///
    /// Q2-b: "对账单行只列四样：描述 / 日期 / 金额 / 税额。不列税率" and "日期在这里是独立的一列，
    /// 而 Electron 是把日期揉进描述串里的 —— 这是有意分叉". The first spelling of this view reused the
    /// editable table's headings and glued `ref_date` back into the description, which is precisely
    /// the practice the ruling departs from; it also drew a rate column the ruling forbids. Caught in
    /// review, so this is what keeps it caught.
    func testDM21TheStatementLineTableIsTheFourAdjudicatedColumns() {
        let draft = DocumentEditorDraft(
            document: doc(type: .statement, number: "ST-2026-0001", currency: "CNY"),
            items: [item(id: 1, description: "", quantity: nil, unit: nil, unitPrice: nil,
                         taxRate: nil, taxAmount: nil, amount: 500, refDate: "2026-01-09")])
        let page = DocumentPageComposition.compose(DocumentPageComposition.Input(editor: draft))
        guard case .readOnlyLines(let block) = page.editor?.body else {
            return XCTFail("a stored statement must show its lines read-only")
        }

        XCTAssertEqual(block.headers.allKeys,
                       ["documents.item.title", "documents.item.description", "documents.col.date",
                        "documents.item.taxAmount", "documents.item.amount"],
                       "four columns plus the section title — no quantity, unit, unit price or RATE")
        for forbidden in ["documents.item.quantity", "documents.item.unit",
                          "documents.item.unitPrice", "documents.item.taxRate",
                          "documents.item.noUnit"] {
            XCTAssertFalse(block.allKeys.contains(forbidden), """
                \(forbidden) reached a statement's line table. A period summary describes no goods, \
                and Q2-b forbids the rate outright: `transactions.tax_rate` has no agreed dimension \
                anywhere in this schema.
                """)
        }

        // The date is a FIELD of its own, and the description is not carrying it.
        let line = try? XCTUnwrap(block.lines.first)
        XCTAssertEqual(line?.date, "2026-01-09")
        XCTAssertEqual(line?.description, "", """
            the date was glued into the description. Q2-b took it out and gave it a column; putting \
            it back is the other app's practice, which this chapter deliberately departs from.
            """)
        XCTAssertNil(line?.taxAmount, "a NULL tax stays NULL so the dash can mean what it says")
        XCTAssertEqual(line?.amount, 500)

        // …and the six-column table is still the shape the other four types get, so none of the
        // keys above is left with nowhere to be drawn.
        var manual = newEditor()
        manual.lines[0].description = "Widget"
        guard case .lines(let editable) = DocumentPageComposition
            .compose(DocumentPageComposition.Input(editor: manual)).editor?.body else {
            return XCTFail("the other four types keep the editable table")
        }
        for key in ["documents.item.quantity", "documents.item.unit",
                    "documents.item.unitPrice", "documents.item.taxRate"] {
            XCTAssertTrue(editable.allKeys.contains(key), "\(key) is drawn nowhere at all")
        }
    }

    // MARK: - DM22 · a period the generator cannot use is refused, not answered with "none"

    /// The store compares the two period strings against `transactions.date` as TEXT. A
    /// locale-shaped date sorts nowhere near the column's ISO values, so the generator would report
    /// "there are no income transactions in that period" for a period that has them — a false
    /// statement rather than an empty result. The other app cannot produce one: its control is
    /// `input type="date"`.
    func testDM22TheISOShapeTestAcceptsWhatTheStoreCanCompare() {
        for good in ["2026-01-01", "0001-12-31", "2026-02-31"] {
            XCTAssertTrue(DocumentPageComposition.isISODate(good), "\(good) is ISO-shaped")
        }
        for bad in ["8/1/2026", "2026-1-1", "26-01-01", "2026-01-01 ", "", "2026-01",
                    "2026-01-01-01", "٢٠٢٦-٠١-٠١", "2026/01/01", "Jan 1 2026"] {
            XCTAssertFalse(DocumentPageComposition.isISODate(bad), """
                \(bad.debugDescription) passed the shape test. It cannot be compared against the \
                date column, so accepting it turns a real period into "no records".
                """)
        }
    }

    /// The same thing through the model, on a real ledger that HAS the transactions: a
    /// locale-shaped period is refused as "fill the period in", and the ISO one then produces the
    /// documents.
    func testDM22bALocaleShapedPeriodIsRefusedRatherThanReportedEmpty() async throws {
        let model = try await bootedModel()
        let store = try XCTUnwrap(model.store)
        try store.create(Transaction(id: "t-1", type: .income, date: "2026-01-15", amount: 1130,
                                     amountNet: 1000, taxAmount: 130, currency: "CNY",
                                     counterparty: "Acme", description: "January"))

        model.newDocument()
        model.setDocumentEditorType(.statement)
        model.setStatementCustomer("Acme")
        model.setStatementPeriodStart("1/1/2026")
        model.setStatementPeriodEnd("31/1/2026")
        model.generateStatements()

        XCTAssertEqual(model.documentEditor?.statementOutcome, .needInput, """
            a period the store cannot compare must be refused. Reporting "no income transactions in \
            that period" here would be false — there is one.
            """)
        XCTAssertNotEqual(model.documentEditor?.statementOutcome, .noRecords)
        XCTAssertTrue(model.documents.documents.isEmpty, "and nothing was written")

        model.setStatementPeriodStart("2026-01-01")
        model.setStatementPeriodEnd("2026-01-31")
        model.generateStatements()

        XCTAssertNil(model.documentEditor, "the sheet closes once the generator has written")
        XCTAssertEqual(model.documents.documents.count, 1)
        XCTAssertEqual(model.documents.documents.first?.type, .statement)
        XCTAssertEqual(model.documents.documents.first?.currency, "CNY")
        XCTAssertEqual(model.documents.documents.first?.number, "ST-2026-0001")
    }

    // MARK: - A booted model over a real temporary ledger

    private var temporaryDirectory: URL?

    override func tearDownWithError() throws {
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
    }

    /// A model over a REAL temporary ledger, adopted through the same Phase-B seam the production
    /// chain uses, so the path under test is the shipping one.
    private func bootedModel() async throws -> AppModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SLDocuments-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectory = directory
        let store = try LedgerStore(databaseURL: directory.appendingPathComponent("documents.db"),
                                    open: .createIfMissing)
        try store.settings.setString("CN", for: SettingsStore.Key.accountingLocale)
        let model = AppModel(runner: DocumentsFakeRunner(store: store))
        model.boot()
        await model.currentBootTask?.value
        XCTAssertNotNil(model.store, "the fixture model must have adopted a store")
        return model
    }

    /// Drives one adoption through the real Phase-A/Phase-B seam.
    private final class DocumentsFakeRunner: BootChainRunner {
        private let store: LedgerStore
        init(store: LedgerStore) { self.store = store }

        @MainActor func resolveOutcome(_ intent: BootIntent) async -> BootOutcome {
            .openStore(authorization: .openExistingPlain, residual: nil)
        }

        @MainActor func attempt(_ authorization: StoreOpenAuthorization,
                                residual: MigrationResidual?) -> MigrationBootDriver.Attempt {
            .opened(store, residual)
        }
    }

    // ==============================================================================================
    // MARK: - Helpers
    // ==============================================================================================

    private func sourceTable(_ language: String) throws -> [String: String] {
        let url = Self.packageRoot()
            .appendingPathComponent("Sources/SoloLedger/Resources/\(language).lproj/Localizable.strings")
        let plist = try PropertyListSerialization.propertyList(from: try Data(contentsOf: url),
                                                              options: [], format: nil)
        return try XCTUnwrap(plist as? [String: String], "\(language) is not a string dictionary")
    }

    /// …/native/SoloLedger/App/Tests/SoloLedgerUnitTests/<this>.swift → …/native/SoloLedger
    private static func packageRoot() -> URL {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { dir.deleteLastPathComponent() }
        return dir
    }

    private static func appSource(_ relative: String) throws -> String {
        try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources/SoloLedger/\(relative)"), encoding: .utf8)
    }

    private static func appSources() throws -> [(path: String, text: String)] {
        let root = packageRoot().appendingPathComponent("Sources/SoloLedger")
        guard let walker = FileManager.default.enumerator(atPath: root.path) else { return [] }
        var out: [(String, String)] = []
        for case let relative as String in walker where relative.hasSuffix(".swift") {
            guard let text = try? String(contentsOf: root.appendingPathComponent(relative),
                                         encoding: .utf8) else { continue }
            out.append((relative, text))
        }
        return out.sorted { $0.0 < $1.0 }
    }

    /// The brace-matched body of `struct <name>`, comments and all.
    private static func structBody(named name: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: "struct \(name)"), "no struct named \(name)")
        let open = try XCTUnwrap(source.range(of: "{", range: start.upperBound..<source.endIndex))
        var depth = 1
        var index = open.upperBound
        while index < source.endIndex, depth > 0 {
            if source[index] == "{" { depth += 1 }
            if source[index] == "}" { depth -= 1; if depth == 0 { break } }
            index = source.index(after: index)
        }
        XCTAssertEqual(depth, 0, "\(name) is unbalanced")
        return String(source[open.upperBound..<index])
    }

    /// Whether `identifier` appears as a WHOLE identifier on a non-comment line.
    private static func namesIdentifier(_ identifier: String, in source: String) -> Bool {
        let pattern = "(^|[^A-Za-z0-9_])\(identifier)([^A-Za-z0-9_]|$)"
        return source.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("*"), !trimmed.hasPrefix("/*") else {
                return false
            }
            return line.range(of: pattern, options: .regularExpression) != nil
        }
    }

    /// How many times `needle` appears on non-comment lines of one file.
    private static func occurrences(of needle: String, inCodeOf source: String) -> Int {
        source.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) { total, line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("*"), !trimmed.hasPrefix("/*") else {
                return total
            }
            return total + (line.components(separatedBy: needle).count - 1)
        }
    }

    /// Which files mention `needle` on a non-comment line.
    private static func mentions(of needle: String,
                                 in sources: [(path: String, text: String)]) -> [String] {
        sources.filter { source in
            source.text.split(separator: "\n", omittingEmptySubsequences: false).contains {
                let trimmed = $0.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//") && !trimmed.hasPrefix("*") && trimmed.contains(needle)
            }
        }.map(\.path)
    }
}
