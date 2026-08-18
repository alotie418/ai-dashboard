import XCTest
@testable import SoloLedgerCore

/// D-3 · the `documents.*` six-language copy — 104 keys, plus `nav.documents`.
///
/// **Every key here is dormant.** No production source names one; D-4 draws the list page, the
/// editor, the line table and the tax-invoice association panel, D-5 draws the exported artifact,
/// and D-6 hangs `nav.documents` in the sidebar — exactly the shape `nav.inventory` had between
/// N-PR-3 and N-PR-6. DC9 is what keeps that claim true rather than stated.
///
/// ## Where the words came from
///
/// 83 keys are Electron's `documents.*` sentences unchanged; five are rewritten because Electron's
/// wording is untrue of this app; 17 are new because the spec requires a sentence Electron never
/// had. The rewrites are worth naming, since "mirror" is this chapter's default and each departure
/// is a decision:
///
///  * `statement.noRecords` — Electron says "no SALES records"; Q2 redirected the row source to
///    the transaction ledger, because this app writes no `sales` table at all.
///  * `export.action` / `export.done` / `export.failed` — Q7 narrows the artifact from PDF to a
///    self-contained HTML file. Keeping the PDF wording would promise a file the app never writes.
///  * `confirm.void.message` — Electron says only that a voided document cannot be edited. Q3 makes
///    the number rule a promise ("作废不释放编号"), so the sentence says that too.
///
/// Four of Electron's 87 have no counterpart at all, and the reason is the same in each case — the
/// sentence would be false here. `desktopOnly` and `pdfDesktopOnly` gate on "is this the desktop
/// app", which is unconditionally true of this one; `generateFromSale` and `generatedOk` belong to
/// a button on Electron's sales page, and the native ledger has no `sales` table for it to stand on.
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
        "documents.attachment.invalidType", "documents.attachment.notBackedUp",
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

    func testDC1TheDocumentsNamespaceIsExactlyOneHundredAndFourKeys() throws {
        XCTAssertEqual(Self.adjudicatedKeys.count, 104, "the adjudicated table itself must be 104")
        XCTAssertEqual(Set(Self.adjudicatedKeys).count, 104, "the adjudicated table has a duplicate")
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
        XCTAssertEqual(Self.attachmentKeys.count, 8)

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
            XCTAssertEqual(table.count, 755, "\(language) has \(table.count) keys")
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
        XCTAssertEqual(scanned, 630, "105 keys x 6 languages")
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
        let denial: [String: [String]] = [
            "zh-Hans": ["并非", "不", "永不"], "zh-Hant": ["並非", "不", "永不"],
            "en": ["not", "never", "does not"], "ja": ["ありません", "ません"],
            "ko": ["아닙니다", "않습니다"], "fr": ["ne ", "pas", "aucune", "jamais"],
        ]
        XCTAssertEqual(Self.boundarySentenceKeys.count, 3)
        for language in languages {
            let table = try sourceTable(language)
            for key in Self.boundarySentenceKeys {
                let value = try XCTUnwrap(table[key])
                XCTAssertTrue(denial[language]!.contains { value.contains($0) }, """
                    \(language)/\(key) states something without denying anything: \(value)
                    """)
            }
        }
        // The markers are discriminating: an ordinary label carries none of them.
        for language in languages {
            let label = try XCTUnwrap(try sourceTable(language)["documents.col.date"])
            XCTAssertFalse(denial[language]!.contains { label.contains($0) },
                           "\(language): the denial markers fire on a plain column header")
        }
    }

    // MARK: - Reading

    static func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Read one locale's `.strings` from SOURCE. The App bundle resolves through the fallback
    /// chain, which would hide a missing key behind zh-Hans instead of failing.
    private func sourceTable(_ language: String) throws -> [String: String] {
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
