import XCTest
@testable import SoloLedgerCore

/// D-3 · the `documents.*` six-language copy — 103 keys, plus `nav.documents`.
///
/// **Every key here is dormant.** No production source names one; D-4 draws the list page, the
/// editor, the line table and the tax-invoice association panel, D-5 draws the exported artifact,
/// and D-6 hangs `nav.documents` in the sidebar — exactly the shape `nav.inventory` had between
/// N-PR-3 and N-PR-6. DC9 is what keeps that claim true rather than stated.
///
/// ## Where the words came from
///
/// **75 mirrored, 8 rewritten, 21 native-only.** Those three numbers are not a description: DC13
/// holds the three lists to a partition of the namespace, and DC14 compares every mirrored key
/// against `i18n/locales/*.json` — Electron's own copy, in this same repository — in all six
/// languages. An earlier draft of this comment claimed a different split and was measurably wrong
/// in every language, with nothing in the suite able to see it.
///
/// A rewrite has to earn itself; `rewrittenWithReason` carries the reason next to the key, and
/// DC14's second half proves each one really does differ from its source. They fall into three
/// groups: a STRUCTURAL split (Electron's confirmations are one `window.confirm` string; a native
/// dialog has a title and a body), a SPEC narrowing (Q2 moved the statement's row source off
/// `sales`; Q7 turned the PDF into a self-contained HTML file; Q3 made "voiding keeps the number" a
/// promise the sentence has to carry), and one ORACLE gap (Electron's oversize-attachment message
/// names a 20 MB limit; nothing in this round measures such a limit, so the sentence does not
/// quote one).
///
/// Five of Electron's 87 keys have no counterpart, and the reason is the same in each case — the
/// sentence would be false here. `desktopOnly` and `pdfDesktopOnly` gate on "is this the desktop
/// app", which is unconditionally true of this one; `generateFromSale` and `generatedOk` belong to
/// a button on Electron's sales page, and the native ledger has no `sales` table for it to stand
/// on; and `attachmentNotBackedUp` warns that attachments are excluded from backups, while
/// `BackupExport.writeBundle` copies the whole `attachments/docs` directory into every bundle it
/// writes. A sixth, `saveButton`, is not missing but reused — `common.save` already says it.
///
/// ## The rule that shapes the sentences
///
/// No figure, rate or count appears inside a sentence: amounts, quantities and totals are cell
/// values the presentation layer formats, so the rounding is decided in one place. The three
/// placeholders are `{path}` — where an export landed — and `{from}` / `{to}`, the two ends of a
/// refused status change. DC4 holds them to exactly that.
final class DocumentCopyTests: XCTestCase {

    private let languages = ["zh-Hans", "zh-Hant", "en", "ja", "ko", "fr"]

    // MARK: - The adjudicated table

    private static let pageKeys = [
        "documents.page.title", "documents.page.subtitle",
        "documents.page.empty", "documents.page.add",
    ]
    private static let filterKeys = [
        "documents.filter.all",
    ]
    private static let typeKeys = [
        "documents.type.quotation", "documents.type.salesOrder",
        "documents.type.proformaInvoice", "documents.type.commercialInvoice",
        "documents.type.statement",
    ]
    private static let statusKeys = [
        "documents.status.draft", "documents.status.issued",
        "documents.status.void",
    ]
    private static let columnKeys = [
        "documents.col.number", "documents.col.type",
        "documents.col.date", "documents.col.customer",
        "documents.col.total", "documents.col.status",
        "documents.col.taxInvoice",
    ]
    private static let actionKeys = [
        "documents.action.issue", "documents.action.void",
    ]
    private static let confirmKeys = [
        "documents.confirm.void.title", "documents.confirm.void.message",
        "documents.confirm.delete.title", "documents.confirm.delete.message",
    ]
    private static let formKeys = [
        "documents.form.title", "documents.form.editTitle",
        "documents.form.type", "documents.form.number",
        "documents.form.numberHint", "documents.form.date",
        "documents.form.validUntil", "documents.form.customer",
        "documents.form.customerPlaceholder", "documents.form.customerTaxID",
        "documents.form.customerAddress", "documents.form.customerContact",
        "documents.form.notes",
    ]
    private static let itemKeys = [
        "documents.item.title", "documents.item.description",
        "documents.item.quantity", "documents.item.unit",
        "documents.item.noUnit", "documents.item.unitPrice",
        "documents.item.taxRate", "documents.item.taxAmount",
        "documents.item.amount", "documents.item.add",
        "documents.item.remove", "documents.item.dashNote",
    ]
    private static let totalKeys = [
        "documents.total.subtotal", "documents.total.taxAmount",
        "documents.total.total",
    ]
    private static let errorKeys = [
        "documents.error.numberRequired", "documents.error.customerNameRequired",
        "documents.error.dateRequired", "documents.error.currencyIsGeneratedStatementsOnly",
        "documents.error.notFound", "documents.error.numberExists",
        "documents.error.invalidStatusTransition", "documents.error.onlyDraftCanBeEdited",
        "documents.error.issuedMustBeVoidedFirst", "documents.error.voidTaxInvoiceReadOnly",
        "documents.error.invalidAttachmentPath", "documents.error.attachmentInUse",
        "documents.error.itemsRequired", "documents.error.saveFailed",
        "documents.error.loadFailed",
    ]
    private static let statementKeys = [
        "documents.statement.customer", "documents.statement.periodStart",
        "documents.statement.periodEnd", "documents.statement.generate",
        "documents.statement.noRecords", "documents.statement.needInput",
        "documents.statement.basisNote", "documents.statement.currencySplitNote",
    ]
    private static let exportKeys = [
        "documents.export.action", "documents.export.done",
        "documents.export.failed", "documents.export.formatNote",
    ]
    private static let printKeys = [
        "documents.print.generatedAt", "documents.print.period",
        "documents.print.disclaimer", "documents.print.voidBadge",
        "documents.print.currency",
    ]
    private static let taxInvoiceKeys = [
        "documents.taxInvoice.action", "documents.taxInvoice.title",
        "documents.taxInvoice.issuedLabel", "documents.taxInvoice.numberLabel",
        "documents.taxInvoice.numberHint", "documents.taxInvoice.dateLabel",
        "documents.taxInvoice.attachmentLabel", "documents.taxInvoice.compliance",
        "documents.taxInvoice.recorded", "documents.taxInvoice.notRecorded",
    ]
    private static let attachmentKeys = [
        "documents.attachment.pick", "documents.attachment.open",
        "documents.attachment.remove", "documents.attachment.missing",
        "documents.attachment.tooLarge", "documents.attachment.failed",
        "documents.attachment.invalidType",
    ]

    /// mirroredFromElectron
    private static let mirroredFromElectron = [
        "documents.page.title", "documents.page.subtitle",
        "documents.page.empty", "documents.page.add",
        "documents.filter.all", "documents.type.quotation",
        "documents.type.salesOrder", "documents.type.proformaInvoice",
        "documents.type.commercialInvoice", "documents.type.statement",
        "documents.status.draft", "documents.status.issued",
        "documents.status.void", "documents.col.number",
        "documents.col.type", "documents.col.date",
        "documents.col.customer", "documents.col.total",
        "documents.col.status", "documents.col.taxInvoice",
        "documents.action.issue", "documents.action.void",
        "documents.form.title", "documents.form.editTitle",
        "documents.form.type", "documents.form.number",
        "documents.form.numberHint", "documents.form.date",
        "documents.form.validUntil", "documents.form.customer",
        "documents.form.customerPlaceholder", "documents.form.customerTaxID",
        "documents.form.customerAddress", "documents.form.customerContact",
        "documents.form.notes", "documents.item.title",
        "documents.item.description", "documents.item.quantity",
        "documents.item.unit", "documents.item.noUnit",
        "documents.item.unitPrice", "documents.item.amount",
        "documents.item.add", "documents.item.remove",
        "documents.total.subtotal", "documents.error.numberExists",
        "documents.error.voidTaxInvoiceReadOnly", "documents.error.itemsRequired",
        "documents.error.saveFailed", "documents.error.loadFailed",
        "documents.statement.customer", "documents.statement.periodStart",
        "documents.statement.periodEnd", "documents.statement.generate",
        "documents.statement.needInput", "documents.print.generatedAt",
        "documents.print.period", "documents.print.disclaimer",
        "documents.print.voidBadge", "documents.taxInvoice.action",
        "documents.taxInvoice.title", "documents.taxInvoice.issuedLabel",
        "documents.taxInvoice.numberLabel", "documents.taxInvoice.numberHint",
        "documents.taxInvoice.dateLabel", "documents.taxInvoice.attachmentLabel",
        "documents.taxInvoice.compliance", "documents.taxInvoice.recorded",
        "documents.taxInvoice.notRecorded", "documents.attachment.pick",
        "documents.attachment.open", "documents.attachment.remove",
        "documents.attachment.missing", "documents.attachment.failed",
        "documents.attachment.invalidType",
    ]

    /// nativeOnly
    private static let nativeOnly = [
        "documents.confirm.delete.message", "documents.item.taxRate",
        "documents.item.taxAmount", "documents.item.dashNote",
        "documents.total.taxAmount", "documents.total.total",
        "documents.error.numberRequired", "documents.error.customerNameRequired",
        "documents.error.dateRequired", "documents.error.currencyIsGeneratedStatementsOnly",
        "documents.error.notFound", "documents.error.invalidStatusTransition",
        "documents.error.onlyDraftCanBeEdited", "documents.error.issuedMustBeVoidedFirst",
        "documents.error.invalidAttachmentPath", "documents.error.attachmentInUse",
        "documents.statement.basisNote", "documents.statement.currencySplitNote",
        "documents.export.formatNote", "documents.print.currency",
        "nav.documents",
    ]

    /// The rewrites whose sentence SAYS something different, as opposed to the two that only
    /// change the shape Electron's own words arrive in. DC14 holds these six to differing from
    /// Electron in all six languages.
    private static let contentRewrites: Set<String> = [
        "documents.confirm.void.message", "documents.statement.noRecords",
        "documents.export.action", "documents.export.done", "documents.export.failed",
        "documents.attachment.tooLarge",
    ]

    private static let rewrittenWithReason: [String: String] = [
        "documents.confirm.void.title":
            "documents.voidConfirm",
        "documents.confirm.void.message":
            "documents.voidConfirm",
        "documents.confirm.delete.title":
            "documents.deleteConfirm",
        "documents.statement.noRecords":
            "documents.stmtNoRecords",
        "documents.export.action":
            "documents.exportPdf",
        "documents.export.done":
            "documents.pdfExported",
        "documents.export.failed":
            "documents.pdfFailed",
        "documents.attachment.tooLarge":
            "documents.attachmentTooLarge",
    ]

    /// 每个镜像键在 Electron `documents` 对象里的来源键。
    private static let electronSourceKey: [String: String] = [
        "documents.page.title": "title",
        "documents.page.subtitle": "subtitle",
        "documents.page.empty": "empty",
        "documents.page.add": "addButton",
        "documents.filter.all": "filterAll",
        "documents.type.quotation": "typeQuotation",
        "documents.type.salesOrder": "typeSalesOrder",
        "documents.type.proformaInvoice": "typeProforma",
        "documents.type.commercialInvoice": "typeCommercial",
        "documents.type.statement": "typeStatement",
        "documents.status.draft": "statusDraft",
        "documents.status.issued": "statusIssued",
        "documents.status.void": "statusVoid",
        "documents.col.number": "colNumber",
        "documents.col.type": "colType",
        "documents.col.date": "colDate",
        "documents.col.customer": "colCustomer",
        "documents.col.total": "colTotal",
        "documents.col.status": "colStatus",
        "documents.col.taxInvoice": "colTaxInvoice",
        "documents.action.issue": "markIssued",
        "documents.action.void": "voidAction",
        "documents.confirm.void.title": "voidConfirm",
        "documents.confirm.void.message": "voidConfirm",
        "documents.confirm.delete.title": "deleteConfirm",
        "documents.form.title": "formTitle",
        "documents.form.editTitle": "formEditTitle",
        "documents.form.type": "formType",
        "documents.form.number": "formNumber",
        "documents.form.numberHint": "formNumberHint",
        "documents.form.date": "formDate",
        "documents.form.validUntil": "formValidUntil",
        "documents.form.customer": "formCustomer",
        "documents.form.customerPlaceholder": "formCustomerPlaceholder",
        "documents.form.customerTaxID": "formCustomerTaxId",
        "documents.form.customerAddress": "formCustomerAddress",
        "documents.form.customerContact": "formCustomerContact",
        "documents.form.notes": "formNotes",
        "documents.item.title": "itemsTitle",
        "documents.item.description": "itemDescription",
        "documents.item.quantity": "itemQty",
        "documents.item.unit": "itemUnit",
        "documents.item.noUnit": "noUnit",
        "documents.item.unitPrice": "itemUnitPrice",
        "documents.item.amount": "itemAmount",
        "documents.item.add": "addItem",
        "documents.item.remove": "removeItem",
        "documents.total.subtotal": "subtotal",
        "documents.error.numberExists": "numberConflict",
        "documents.error.voidTaxInvoiceReadOnly": "taxInvoiceVoidReadOnly",
        "documents.error.itemsRequired": "itemsRequired",
        "documents.error.saveFailed": "saveFailed",
        "documents.error.loadFailed": "loadFailed",
        "documents.statement.customer": "stmtCustomer",
        "documents.statement.periodStart": "stmtPeriodStart",
        "documents.statement.periodEnd": "stmtPeriodEnd",
        "documents.statement.generate": "stmtGenerate",
        "documents.statement.noRecords": "stmtNoRecords",
        "documents.statement.needInput": "stmtNeedInput",
        "documents.export.action": "exportPdf",
        "documents.export.done": "pdfExported",
        "documents.export.failed": "pdfFailed",
        "documents.print.generatedAt": "pdfGeneratedAt",
        "documents.print.period": "pdfPeriod",
        "documents.print.disclaimer": "pdfDisclaimer",
        "documents.print.voidBadge": "statusVoid",
        "documents.taxInvoice.action": "taxInvoiceAction",
        "documents.taxInvoice.title": "taxInvoiceTitle",
        "documents.taxInvoice.issuedLabel": "taxInvoiceIssuedLabel",
        "documents.taxInvoice.numberLabel": "taxInvoiceNumberLabel",
        "documents.taxInvoice.numberHint": "taxInvoiceNumberHint",
        "documents.taxInvoice.dateLabel": "taxInvoiceDateLabel",
        "documents.taxInvoice.attachmentLabel": "taxInvoiceAttachmentLabel",
        "documents.taxInvoice.compliance": "taxInvoiceCompliance",
        "documents.taxInvoice.recorded": "taxInvoiceYes",
        "documents.taxInvoice.notRecorded": "taxInvoiceNo",
        "documents.attachment.pick": "attachmentPick",
        "documents.attachment.open": "attachmentOpen",
        "documents.attachment.remove": "attachmentRemove",
        "documents.attachment.missing": "attachmentMissing",
        "documents.attachment.tooLarge": "attachmentTooLarge",
        "documents.attachment.failed": "attachmentFailed",
        "documents.attachment.invalidType": "attachmentInvalidType",
    ]

    private static let adjudicatedKeys =
        pageKeys + filterKeys + typeKeys + statusKeys + columnKeys + actionKeys + confirmKeys
        + formKeys + itemKeys + totalKeys + errorKeys + statementKeys + exportKeys + printKeys
        + taxInvoiceKeys + attachmentKeys

    /// The three sentences `docs/BUSINESS_DOCUMENTS_SPEC.md` §4 requires the native app to carry.
    /// Each DENIES something rather than claiming it, which is what DC12 measures.
    private static let boundarySentenceKeys = ["documents.print.disclaimer",
                                               "documents.taxInvoice.compliance",
                                               "documents.taxInvoice.numberHint"]

    /// The editor raises these three itself; they are not `BusinessDocumentError` cases.
    private static let editorOnlyErrorKeys = ["documents.error.itemsRequired",
                                              "documents.error.saveFailed",
                                              "documents.error.loadFailed"]

    private static let placeholderContract: [String: Set<String>] = [
        "documents.export.done": ["{path}"],
        "documents.error.invalidStatusTransition": ["{from}", "{to}"],
    ]
    private static let allowedPlaceholders: Set<String> = ["{path}", "{from}", "{to}"]

    // MARK: - DC1 · the key universe

    func testDC1TheDocumentsNamespaceIsExactlyOneHundredAndThreeKeys() throws {
        XCTAssertEqual(Self.adjudicatedKeys.count, 103, "the adjudicated table itself must be 103")
        XCTAssertEqual(Set(Self.adjudicatedKeys).count, 103, "the adjudicated table has a duplicate")
        // The sixteen groups, each pinned, so a key that moves between two of them is a change of
        // meaning and not a rename. The sum is checked above; these are what it is a sum OF.
        XCTAssertEqual(Self.pageKeys.count, 4)
        XCTAssertEqual(Self.filterKeys.count, 1)
        XCTAssertEqual(Self.typeKeys.count, 5)
        XCTAssertEqual(Self.statusKeys.count, 3)
        XCTAssertEqual(Self.columnKeys.count, 7)
        XCTAssertEqual(Self.actionKeys.count, 2)
        XCTAssertEqual(Self.confirmKeys.count, 4)
        XCTAssertEqual(Self.formKeys.count, 13)
        XCTAssertEqual(Self.itemKeys.count, 12)
        XCTAssertEqual(Self.totalKeys.count, 3)
        XCTAssertEqual(Self.errorKeys.count, 15)
        XCTAssertEqual(Self.statementKeys.count, 8)
        XCTAssertEqual(Self.exportKeys.count, 4)
        XCTAssertEqual(Self.printKeys.count, 5)
        XCTAssertEqual(Self.taxInvoiceKeys.count, 10)
        XCTAssertEqual(Self.attachmentKeys.count, 7)

        for language in languages {
            let landed = try sourceTable(language).keys.filter { $0.hasPrefix("documents.") }.sorted()
            XCTAssertEqual(landed, Self.adjudicatedKeys.sorted(), """
                \(language): landed set differs from the adjudicated table.
                extra:   \(Set(landed).subtracting(Self.adjudicatedKeys).sorted())
                missing: \(Set(Self.adjudicatedKeys).subtracting(landed).sorted())
                """)
        }
    }

    // MARK: - DC2 · the whole universe, and six identical key sets

    func testDC2EverySixLocaleFileHoldsTheSameKeyCount() throws {
        var keySets: [Set<String>] = []
        for language in languages {
            let table = try sourceTable(language)
            XCTAssertEqual(table.count, 754, "\(language) has \(table.count) keys")
            // The neighbours, pinned in the same breath: landing a documents key in one of them is
            // the likeliest way to be right about the total and wrong about where it went.
            XCTAssertEqual(table.keys.filter { $0.hasPrefix("nav.") }.count, 8, "\(language) nav.*")
            XCTAssertEqual(table.keys.filter { $0.hasPrefix("inventory.") }.count, 93, "\(language) inventory.*")
            XCTAssertEqual(table.keys.filter { $0.hasPrefix("product.") }.count, 41, "\(language) product.*")
            XCTAssertEqual(table.keys.filter { $0.hasPrefix("common.") }.count, 8, "\(language) common.*")
            keySets.append(Set(table.keys.filter { $0.hasPrefix("documents.") }))
        }
        XCTAssertEqual(Set(keySets).count, 1, "the six locales do not agree on the documents.* key set")
    }

    // MARK: - DC3 · every key resolves, everywhere

    func testDC3EveryDocumentsKeyResolvesInAllSixLocales() throws {
        for language in languages {
            let table = try sourceTable(language)
            for key in Self.adjudicatedKeys + ["nav.documents"] {
                guard let value = table[key] else { return XCTFail("\(language) is missing \(key)") }
                XCTAssertFalse(value.trimmingCharacters(in: .whitespaces).isEmpty, "\(language)/\(key) is empty")
                XCTAssertNotEqual(value, key, "\(language)/\(key) renders its own key")
            }
        }
    }

    // MARK: - DC4 · the placeholder contract

    func testDC4PlaceholdersAreTheContractedTokensAndNothingElse() throws {
        for language in languages {
            let table = try sourceTable(language)
            for key in Self.adjudicatedKeys {
                let found = Self.placeholders(in: try XCTUnwrap(table[key]))
                let contracted = Self.placeholderContract[key] ?? []
                XCTAssertEqual(found, contracted, "\(language)/\(key) carries \(found), contracted \(contracted)")
                XCTAssertTrue(found.isSubset(of: Self.allowedPlaceholders), "\(language)/\(key)")
            }
        }
        // The contract is not vacuous: the two keys that HAVE placeholders really do.
        XCTAssertEqual(Self.placeholderContract.count, 2)
        XCTAssertEqual(Self.placeholders(in: "Exported to: {path}"), ["{path}"])
        XCTAssertEqual(Self.placeholders(in: "no tokens at all"), [])
    }

    // MARK: - DC5 / DC6 / DC7 · the three closed sets, both directions

    /// `BusinessDocumentError`'s twelve cases each have exactly one sentence, and no sentence
    /// exists for a case that does not. One-way would defend one direction only: a new case with
    /// no sentence leaves the screen rendering a raw key, and a sentence for a deleted case is dead
    /// copy that six-locale parity waves straight through.
    func testDC5EveryErrorCaseHasExactlyOneSentenceAndViceVersa() throws {
        let cases = try Self.errorCaseNamesFromSource()
        XCTAssertEqual(cases.count, 12, "BusinessDocumentError's declared cases: \(cases)")
        let expected = Set(cases.map { "documents.error." + $0 })
            .union(Self.editorOnlyErrorKeys)
        XCTAssertEqual(expected.count, 15)
        for language in languages {
            let landed = Set(try sourceTable(language).keys.filter { $0.hasPrefix("documents.error.") })
            XCTAssertEqual(landed, expected, """
                \(language): the error copy and the enum disagree.
                in the file, matching no case (delete it): \(landed.subtracting(expected).sorted())
                a case with no sentence (add it): \(expected.subtracting(landed).sorted())
                """)
        }
    }

    /// An error sentence never prints the case name or a machine token — the reader gets a
    /// sentence, not a symbol. `ProductCopyTests` and `InventoryCopyTests` hold their namespaces
    /// to the same rule.
    func testDC5bErrorCopyNeverPrintsTheCaseNameOrAMachineToken() throws {
        let machineTokens = ["DOC_NUMBER_EXISTS", "DOC_ISSUED_VOID_FIRST",
                             "DOC_VOID_TAX_INVOICE_READONLY", "INVALID_ATTACHMENT_PATH",
                             "ATTACHMENT_IN_USE", "SQLITE", "nil", "NULL"]
        for language in languages {
            let table = try sourceTable(language)
            for key in Self.errorKeys {
                let value = try XCTUnwrap(table[key])
                let caseName = String(key.dropFirst("documents.error.".count))
                XCTAssertFalse(value.contains(caseName), "\(language)/\(key) prints its own case name")
                for token in machineTokens {
                    XCTAssertFalse(value.contains(token), "\(language)/\(key) prints \(token)")
                }
            }
        }
    }

    func testDC6EveryDocumentTypeHasExactlyOneLabelAndViceVersa() throws {
        let expected = Set(BusinessDocumentType.allCases.map { "documents.type." + $0.copyName })
        XCTAssertEqual(expected.count, 5)
        for language in languages {
            let landed = Set(try sourceTable(language).keys.filter { $0.hasPrefix("documents.type.") })
            XCTAssertEqual(landed, expected, "\(language): the type labels and the enum disagree")
        }
    }

    func testDC7EveryStatusHasExactlyOneLabelAndViceVersa() throws {
        let expected = Set(BusinessDocumentStatus.allCases.map { "documents.status." + $0.rawValue })
        XCTAssertEqual(expected, ["documents.status.draft", "documents.status.issued",
                                  "documents.status.void"])
        for language in languages {
            let landed = Set(try sourceTable(language).keys.filter { $0.hasPrefix("documents.status.") })
            XCTAssertEqual(landed, expected, "\(language): the status labels and the enum disagree")
        }
    }

    // MARK: - DC8 · the wording guard, re-run over this namespace

    /// The two banned lists, applied to all 624 new values, with the patterns read out of the
    /// guard's own source so this cannot drift from what the suite enforces — and fired at known
    /// targets first, so a clean result is a measurement rather than a broken pattern.
    func testDC8NoDocumentsCopyTripsEitherBannedList() throws {
        let filing = try Self.bannedPatterns(named: "filingWords")
        let statutory = try Self.bannedPatterns(named: "statutoryStatementNames")
        XCTAssertEqual(filing.count, 22, "the filing list is 22 entries; the reader found \(filing.count)")
        XCTAssertEqual(statutory.count, 21, "the statutory list is 21; the reader found \(statutory.count)")

        // Self-check, both directions, before a single new value is scanned.
        for (probe, patterns) in [("增值税申报表", filing), ("Auto-certify", filing),
                                  ("확정 신고", filing), ("déclaration de TVA", filing),
                                  ("资产负债表", statutory), ("Income Statement", statutory),
                                  ("손익계산서", statutory)] {
            XCTAssertTrue(patterns.contains { Self.matches($0, probe) }, "no pattern fires on \(probe)")
        }
        for (probe, patterns) in [("业务单据", filing), ("Statement of Account", statutory),
                                  ("Business Documents", statutory)] {
            XCTAssertFalse(patterns.contains { Self.matches($0, probe) }, "a pattern fires on \(probe)")
        }

        var scanned = 0
        for language in languages {
            let table = try sourceTable(language)
            for key in Self.adjudicatedKeys + ["nav.documents"] {
                let value = try XCTUnwrap(table[key])
                scanned += 1
                for pattern in filing where Self.matches(pattern, value) {
                    XCTFail("\(language)/\(key) trips filingWords /\(pattern)/: \(value)")
                }
                for pattern in statutory where Self.matches(pattern, value) {
                    XCTFail("\(language)/\(key) trips statutoryStatementNames /\(pattern)/: \(value)")
                }
            }
        }
        XCTAssertEqual(scanned, 624, "104 keys x 6 languages")
    }

    // MARK: - DC9 · the whole namespace is dormant

    /// **No production source names a `documents.*` key.** This round wrote copy and nothing else;
    /// the first reference belongs to D-4. Stated as a scan rather than as a promise, because a
    /// half-wired key is exactly the thing a copy round cannot see in its own diff.
    ///
    /// `nav.documents` is held to the same rule and for the same reason `nav.inventory` was
    /// between N-PR-3 and N-PR-6: the sidebar entry arrives with the page, not before it.
    func testDC9NoProductionSourceReferencesAnyDocumentsKey() throws {
        let sources = try Self.productionSources()
        XCTAssertGreaterThan(sources.count, 100, "the walk found \(sources.count) files — it is broken")

        // The scan is on the PREFIX with its opening quote, not on whole keys. A key drawn as
        // `t("documents.\(group).title")` is invisible to a whole-key scan, and this package
        // already builds one namespace that way — `SidebarSection.titleKey` is `"nav.\(rawValue)"`,
        // which is why `nav.inventory` appears nowhere as a literal. One substring covers both.
        for (path, text) in sources {
            XCTAssertFalse(text.contains("\"documents."), """
                \(path) already names a documents.* key. D-3 is a copy round: the namespace is \
                dormant until D-4/D-5/D-6 wire it. If this is that round, move this assertion.
                """)
        }

        // `nav.documents` cannot be scanned for at all, for the reason above — it would be drawn by
        // the enum, not by a literal. So the dormancy check is the MECHANISM: the sidebar has no
        // documents section yet. D-6 adds it, and §6 of the spec calls it the seventh.
        XCTAssertEqual(SidebarSectionProbe.caseNames, ["overview", "transactions", "categories",
                                                       "products", "inventory", "reports"],
                       "the sidebar gained a section; nav.documents may no longer be dormant")

        // Neither assertion is vacuous: the same walk sees a literal key that IS drawn today, and
        // the same reader sees the six sections that exist.
        XCTAssertTrue(sources.contains { $0.text.contains("\"inventory.page.title\"") },
                      "the walk cannot see a key known to be drawn — it is not scanning code")
        XCTAssertEqual(SidebarSectionProbe.caseNames.count, 6)
    }

    // MARK: - DC10 · no two keys in one screen region read the same

    /// Two controls that sit together and render the same word are a bug the six-locale parity
    /// check cannot see. Regions are the groups a user looks at in one glance.
    func testDC10NoTwoKeysInOneScreenRegionRenderTheSameLabel() throws {
        let regions: [String: [String]] = [
            "type": Self.typeKeys,
            "status": Self.statusKeys,
            "column": Self.columnKeys,
            "form": Self.formKeys,
            "item": Self.itemKeys,
            "total": Self.totalKeys,
            "statement": Self.statementKeys,
            "error": Self.errorKeys,
        ]
        for (region, keys) in regions {
            XCTAssertGreaterThan(keys.count, 1, "\(region) is not a collision region")
            for language in languages {
                let table = try sourceTable(language)
                var seen: [String: String] = [:]
                for key in keys {
                    let value = try XCTUnwrap(table[key])
                    if let other = seen[value] {
                        XCTFail("\(language): \(region) renders \(other) and \(key) identically (\(value))")
                    }
                    seen[value] = key
                }
            }
        }
    }

    // MARK: - DC11 · the Korean punctuation convention

    /// Korean copy in this repository ends its sentences with an ASCII full stop, not the CJK
    /// ideographic one; Japanese does the opposite. Nothing enforced it before, and a mixed file
    /// is the kind of thing a guard catches and a reader does not.
    func testDC11KoreanUsesAsciiPunctuationAndJapaneseUsesTheCJKForm() throws {
        let korean = try sourceTable("ko")
        for key in Self.adjudicatedKeys + ["nav.documents"] {
            let value = try XCTUnwrap(korean[key])
            for mark in ["。", "，", "、", "？", "！"] {
                XCTAssertFalse(value.contains(mark), "ko/\(key) uses the CJK mark \(mark): \(value)")
            }
        }
        // The control: Japanese in the same block DOES use them, so the assertion above is about
        // a convention and not about an alphabet that never carries punctuation at all.
        let japanese = try sourceTable("ja")
        let cjkSentences = Self.adjudicatedKeys.filter { key in
            (japanese[key] ?? "").contains("。")
        }
        XCTAssertGreaterThan(cjkSentences.count, 20, "ja should carry the ideographic stop widely")
    }

    // MARK: - DC12 · the three sentences the product boundary is made of

    /// `docs/BUSINESS_DOCUMENTS_SPEC.md` §4 names three sentences the native app must carry: the
    /// artifact's footer, the association's scope, and the numbering hint. Each has to DENY
    /// something — that is what makes it a boundary rather than a description — so each is checked
    /// against a per-language denial marker.
    func testDC12TheThreeBoundarySentencesArePresentAndEachDeniesSomething() throws {
        // Matched as REGULAR EXPRESSIONS, word-anchored where the language has word boundaries.
        // A bare substring is not a denial detector: `"ne "` sits inside `"une "` and `"not"` inside
        // `"notice"`, so a boundary sentence stripped of its denial would still pass. Measured, and
        // the reason this is a regex list rather than the substring list it started as.
        let denial: [String: [String]] = [
            "zh-Hans": ["并非", "不", "永不"], "zh-Hant": ["並非", "不", "永不"],
            "en": [#"\bnot\b"#, #"\bnever\b"#], "ja": ["ありません", "ません"],
            "ko": ["아닙니다", "않습니다"],
            "fr": [#"\bne\b"#, #"\bn’"#, #"\bpas\b"#, #"\baucune?\b"#, #"\bjamais\b"#],
        ]
        XCTAssertEqual(Self.boundarySentenceKeys.count, 3)
        for language in languages {
            let table = try sourceTable(language)
            for key in Self.boundarySentenceKeys {
                let value = try XCTUnwrap(table[key])
                XCTAssertTrue(denial[language]!.contains { Self.matches($0, value) }, """
                    \(language)/\(key) states something without denying anything: \(value)
                    """)
            }
        }
        // The markers are discriminating: an ordinary label carries none of them.
        for language in languages {
            let label = try XCTUnwrap(try sourceTable(language)["documents.col.date"])
            XCTAssertFalse(denial[language]!.contains { Self.matches($0, label) },
                           "\(language): the denial markers fire on a plain column header")
        }
        // The markers are word-anchored, not substrings — the case that broke the first draft.
        for (sample, language) in [("une facture commerciale interne", "fr"),
                                   ("a notice about documents", "en")] {
            XCTAssertFalse(denial[language]!.contains { Self.matches($0, sample) },
                           "\(language): a substring marker fires on \(sample)")
        }
    }

    // MARK: - Reading

    static func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Read one locale's `.strings` from SOURCE. The App bundle resolves through the fallback
    /// chain, which would hide a missing key behind zh-Hans instead of failing.
    func sourceTable(_ language: String) throws -> [String: String] {
        let url = Self.packageRoot()
            .appendingPathComponent("Sources/SoloLedger/Resources/\(language).lproj/Localizable.strings")
        let text = try String(contentsOf: url, encoding: .utf8)
        var table: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\""), trimmed.hasSuffix("\";") else { continue }
            let body = trimmed.dropFirst().dropLast(2)
            guard let split = body.range(of: "\" = \"") else { continue }
            let key = String(body[body.startIndex..<split.lowerBound])
            XCTAssertNil(table[key], "\(language) declares \(key) twice")
            table[key] = String(body[split.upperBound...])
        }
        return table
    }

    /// Every `.swift` under `Sources/` — the Core library and the SwiftUI App target.
    static func productionSources() throws -> [(path: String, text: String)] {
        let root = packageRoot().appendingPathComponent("Sources")
        guard let walker = FileManager.default.enumerator(atPath: root.path) else {
            XCTFail("cannot enumerate \(root.path)"); return []
        }
        var out: [(String, String)] = []
        for case let relative as String in walker where relative.hasSuffix(".swift") {
            guard let text = try? String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8) else {
                XCTFail("cannot read \(relative)"); continue
            }
            out.append((relative, text))
        }
        return out
    }

    /// The `case` names `BusinessDocumentError` declares, read from the model's own source.
    static func errorCaseNamesFromSource() throws -> [String] {
        let url = packageRoot()
            .appendingPathComponent("Sources/SoloLedgerCore/Documents/BusinessDocument.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        guard let start = source.range(of: "public enum BusinessDocumentError"),
              let end = source.range(of: "\n    public var description",
                                     range: start.upperBound..<source.endIndex)
        else {
            throw NSError(domain: "DocumentCopyTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "cannot locate BusinessDocumentError"])
        }
        var out: [String] = []
        for line in source[start.upperBound..<end.lowerBound].split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("case ") else { continue }
            // `case invalidStatusTransition(from:…)` — the key follows the case NAME, not its
            // associated values.
            let name = String(text.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            out.append(String(name.prefix(while: { $0 != "(" })))
        }
        XCTAssertGreaterThan(out.count, 5, "the case parser found almost nothing — it is broken")
        return out
    }

    /// The banned patterns, read out of `LocalizationWordingGuardTests` so the two lists cannot
    /// drift apart. Both literal spellings are handled: a plain `"…"` and a raw `#"…"#`. An
    /// earlier draft of this reader knew only the first and silently under-counted by seven.
    static func bannedPatterns(named name: String) throws -> [String] {
        let url = packageRoot()
            .appendingPathComponent("Tests/SoloLedgerCoreTests/LocalizationWordingGuardTests.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        guard let start = source.range(of: "static let \(name): [BannedWord] = ["),
              let end = source.range(of: "\n    ]", range: start.upperBound..<source.endIndex)
        else {
            throw NSError(domain: "DocumentCopyTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "cannot locate \(name)"])
        }
        var out: [String] = []
        for line in source[start.upperBound..<end.lowerBound].split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix(".init(pattern:") else { continue }
            if let r = text.range(of: "#\""),
               let e = text.range(of: "\"#", range: r.upperBound..<text.endIndex) {
                out.append(String(text[r.upperBound..<e.lowerBound]))
            } else if let r = text.range(of: "pattern: \""),
                      let e = text.range(of: "\"", range: r.upperBound..<text.endIndex) {
                out.append(String(text[r.upperBound..<e.lowerBound]))
            }
        }
        return out
    }

    static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    static func placeholders(in value: String) -> Set<String> {
        var found: Set<String> = []
        guard let re = try? NSRegularExpression(pattern: #"\{[a-zA-Z]+\}"#) else { return found }
        let ns = value as NSString
        re.enumerateMatches(in: value, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            if let m { found.insert(ns.substring(with: m.range)) }
        }
        return found
    }
}

// MARK: - Key spelling

private extension BusinessDocumentType {
    /// The localization key follows the SWIFT case name, the way `product.unit.*` follows
    /// `ProductUnit` — the stored `rawValue` is snake_case and the key is not.
    var copyName: String {
        switch self {
        case .quotation: return "quotation"
        case .salesOrder: return "salesOrder"
        case .proformaInvoice: return "proformaInvoice"
        case .commercialInvoice: return "commercialInvoice"
        case .statement: return "statement"
        }
    }
}

/// The sidebar's case list, read from the App target's source. The Core test target cannot import
/// the App module, and the point of the check is the DECLARATION anyway — a `documents` case
/// appearing there is what makes `nav.documents` reachable.
private enum SidebarSectionProbe {
    static let caseNames: [String] = {
        let url = DocumentCopyTests.packageRoot()
            .appendingPathComponent("Sources/SoloLedger/App/AppModel.swift")
        guard let source = try? String(contentsOf: url, encoding: .utf8),
              let start = source.range(of: "enum SidebarSection"),
              let end = source.range(of: "\n    var id:", range: start.upperBound..<source.endIndex)
        else { return [] }
        return source[start.upperBound..<end.lowerBound]
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("case ") }
            .map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
    }()
}

extension DocumentCopyTests {

    // MARK: - DC13 · the classification partitions the namespace

    /// Every key is exactly one of three things, and the three lists cover the namespace with no
    /// overlap and no gap. The header comment quotes these three numbers; this is what makes them
    /// true rather than asserted.
    func testDC13TheThreeSourceListsPartitionTheNamespace() throws {
        let mirrored = Set(Self.mirroredFromElectron)
        let rewritten = Set(Self.rewrittenWithReason.keys)
        let native = Set(Self.nativeOnly)
        let all = Set(Self.adjudicatedKeys + ["nav.documents"])

        XCTAssertEqual(mirrored.count, 75, "keys that are Electron's sentence, unchanged")
        XCTAssertEqual(rewritten.count, 8, "keys that depart from it, each with a reason")
        XCTAssertEqual(native.count, 21, "keys Electron has no counterpart for")
        XCTAssertEqual(mirrored.count + rewritten.count + native.count, 104)
        XCTAssertEqual(all.count, 104)
        XCTAssertEqual(mirrored.union(rewritten).union(native), all, """
            the three lists do not cover the namespace.
            uncovered: \(all.subtracting(mirrored).subtracting(rewritten).subtracting(native).sorted())
            unknown:   \(mirrored.union(rewritten).union(native).subtracting(all).sorted())
            """)
        XCTAssertTrue(mirrored.isDisjoint(with: rewritten))
        XCTAssertTrue(mirrored.isDisjoint(with: native))
        XCTAssertTrue(rewritten.isDisjoint(with: native))

        // A reason is a sentence, not a shrug.
        for (key, reason) in Self.rewrittenWithReason {
            XCTAssertGreaterThan(reason.count, 12, "\(key)'s reason says nothing: \(reason)")
        }
        // Every mirrored and rewritten key names the Electron key it came from; a native-only key
        // must not, because there is nothing for it to name.
        for key in mirrored.union(rewritten) {
            XCTAssertNotNil(Self.electronSourceKey[key], "\(key) does not name its Electron source")
        }
        for key in native {
            XCTAssertNil(Self.electronSourceKey[key], "\(key) claims an Electron source it cannot have")
        }
    }

    // MARK: - DC14 · "mirrored" is measured against Electron, not asserted

    /// **The 75 mirrored keys are byte-identical to Electron's sentence in all six languages.**
    ///
    /// Read straight out of `i18n/locales/*.json` — the Electron app in this same repository — so
    /// the claim is a comparison and not a memory of one. An earlier draft of this file simply
    /// stated a split ("83 mirrored, 5 rewritten"); it was measurably wrong in every language, and
    /// nothing in the suite could see that. This test is the repair.
    func testDC14EveryMirroredKeyIsElectronsSentenceUnchanged() throws {
        let electron = try Self.electronDocumentsCopy()
        XCTAssertEqual(electron.count, 6, "six locale files")
        for (_, table) in electron {
            XCTAssertEqual(table.count, 87, "Electron's documents namespace is 87 keys")
        }

        var compared = 0
        for key in Self.mirroredFromElectron {
            let source = try XCTUnwrap(Self.electronSourceKey[key])
            for (native, foreign) in Self.localePairs {
                let mine = try XCTUnwrap(try sourceTable(native)[key], "\(native)/\(key)")
                let theirs = try XCTUnwrap(electron[foreign]?[source], "\(foreign)/documents.\(source)")
                XCTAssertEqual(mine, theirs, "\(native)/\(key) is not Electron's documents.\(source)")
                compared += 1
            }
        }
        XCTAssertEqual(compared, 75 * 6, "75 mirrored keys x 6 languages")

        // The other direction, so this is a partition and not a filter. The bar differs by KIND of
        // rewrite, and the difference is not pedantry:
        //
        //  * a CONTENT rewrite says something Electron's sentence does not, and that has to be true
        //    in every language — one locale quietly reverting to Electron's wording is exactly the
        //    regression this classification exists to catch (an `Export PDF` label on a round whose
        //    whole point is that the artifact is HTML);
        //  * a STRUCTURAL rewrite reuses Electron's words in a different shape — its confirmations
        //    are one `window.confirm` string and a native dialog has a title and a body — so a
        //    language whose title happens to BE Electron's whole sentence is correct, not a lapse.
        for (key, _) in Self.rewrittenWithReason {
            let source = try XCTUnwrap(Self.electronSourceKey[key])
            let differing = Self.localePairs.filter { native, foreign in
                (try? sourceTable(native)[key]) ?? nil != electron[foreign]?[source]
            }
            if Self.contentRewrites.contains(key) {
                XCTAssertEqual(differing.count, 6, """
                    \(key) is a content rewrite, but \(6 - differing.count) language(s) still carry \
                    Electron's sentence: \(Self.localePairs.map(\.0).filter { l in !differing.contains { $0.0 == l } })
                    """)
            } else {
                XCTAssertGreaterThan(differing.count, 0,
                                     "\(key) is listed as rewritten but matches Electron in every language")
            }
        }
        XCTAssertEqual(Self.contentRewrites.count, 6)
        XCTAssertTrue(Self.contentRewrites.isSubset(of: Set(Self.rewrittenWithReason.keys)))
    }

    /// `native locale → Electron locale`. The two apps spell three of the six differently.
    static let localePairs: [(String, String)] = [
        ("zh-Hans", "zh-CN"), ("zh-Hant", "zh-TW"), ("en", "en"),
        ("ja", "ja"), ("ko", "ko"), ("fr", "fr"),
    ]

    /// Electron's `documents` object, per locale, read from `i18n/locales/*.json`.
    static func electronDocumentsCopy() throws -> [String: [String: String]] {
        let root = packageRoot().deletingLastPathComponent().deletingLastPathComponent()
        var out: [String: [String: String]] = [:]
        for (_, foreign) in localePairs {
            let url = root.appendingPathComponent("i18n/locales/\(foreign).json")
            let data = try Data(contentsOf: url)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let documents = json?["documents"] as? [String: String] else {
                throw NSError(domain: "DocumentCopyTests", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "no documents object in \(foreign).json"])
            }
            out[foreign] = documents
        }
        return out
    }
}
