import XCTest
@testable import SoloLedger
@testable import SoloLedgerCore

/// D-5 — the exported artefact (Q7), and the line that says when it is right.
///
/// ## The acceptance line, and why it has a domain
///
/// Q9 asks for "byte-for-byte equal to Electron on the same input". Q7-b writes down where that can
/// actually hold: **a non-statement document, `currency IS NULL`, the CN regime, and an injected
/// `generatedAt`**. Inside that domain `DX1` compares against six committed goldens that node
/// produced from `components/documentPdf.ts` itself. Outside it, five registered divergences (§3 ·
/// B3–B7) and one template variant (Q7's statement four columns) mean the bytes CANNOT match, and
/// each of those gets a test that pins only itself — D-3's judgment 47, which exists because a
/// divergence with no test of its own is one an implementation can quietly undo.
///
/// ## What "same input" means here
///
/// The labels fed to the two sides are the SAME strings — the generator reads this app's
/// `.strings` and hands them to the other app's template. That is deliberate: label wording is B3
/// and B4's subject and has its own tests, so folding it in here would make one failure look like
/// the other. What this test measures is structure, escaping and number formatting.
///
/// Number formatting is pinned to `en_US` on both sides. `formatMoney` over there ends in
/// `toLocaleString(undefined, …)`, which follows the HOST — so a golden generated on one machine
/// would otherwise carry that machine's thousands separator into the repository.
@MainActor
final class DocumentExportTests: XCTestCase {

    private static let languages = ["zh-Hans", "zh-Hant", "en", "ja", "ko", "fr"]
    /// The instant the generator injected. Must match `GENERATED_AT` in the generator.
    private static let generatedAt = "2026-08-19T03:04:05Z"
    private static let pinnedLocale = Locale(identifier: "en_US")

    // MARK: - DX1 · the artefact is the other app's artefact, byte for byte

    func testDX1TheArtefactMatchesTheCommittedGoldenInEveryLanguage() throws {
        let detail = try Self.fixture()
        XCTAssertNotEqual(detail.document.type, .statement, "the golden fixture must be in Q7-b's domain")
        XCTAssertNil(detail.document.currency)
        XCTAssertEqual(detail.document.accountingLocale, .CN)

        for language in Self.languages {
            let model = AppModel()
            model.setLanguage(language, persist: false)
            model.companyName = "SoloLedger Trading Co., Ltd."
            let produced = model.documentArtefactHTML(for: detail,
                                                      locale: Self.pinnedLocale,
                                                      generatedAt: Self.generatedAt)
            let golden = try Self.golden(language)
            if produced != golden {
                let (line, mine, theirs) = Self.firstDifference(produced, golden)
                XCTFail("""
                    \(language): the artefact does not match what `buildDocumentHtml` produced from \
                    the same input. First difference at line \(line):
                      native  : \(mine)
                      electron: \(theirs)
                    """)
            }
        }
    }

    /// The golden cannot be trivially satisfiable: it has to contain the things the fixture put in.
    func testDX1bTheGoldenIsNotVacuous() throws {
        let golden = try Self.golden("en")
        for expected in ["¥1,234.50", "&amp;", "&lt;Holdings&gt;", "&#39;", "2 pcs", "0 carton",
                        "<td class=\"val\">1234.5</td>", "2026-08-19T03:04:05Z"] {
            XCTAssertTrue(golden.contains(expected), "the golden lost \(expected)")
        }
        XCTAssertFalse(golden.contains("No unit"), """
            the artefact printed the picker's "no unit" label into a table cell. Over there
            `getProductUnitLabel('')` is the empty string, so a line with no unit shows just the
            number.
            """)
    }

    // MARK: - DX2 · Q7-a's file name

    func testDX2TheFileNameIsTheEscapedNumberWithAnHTMLExtension() {
        func name(_ number: String, id: String = "doc-1") -> String {
            DocumentHTML.fileName(for: Self.document(number: number, id: id))
        }
        XCTAssertEqual(name("QT-2026-0001"), "QT-2026-0001.html")
        // A RUN of illegal characters folds into one underscore, which is what `+` in the other
        // app's `/[\\/:*?"<>|\s]+/g` does — one underscore each would be a different name.
        XCTAssertEqual(name("A/B:C"), "A_B_C.html")
        XCTAssertEqual(name("A///B"), "A_B.html")
        XCTAssertEqual(name("A  B"), "A_B.html")
        XCTAssertEqual(name("A*?\"<>|B"), "A_B.html")
        XCTAssertEqual(name("A/"), "A_.html", "a trailing run still becomes an underscore")
        // Measured against the real expression rather than reasoned about: `"///"` escapes to a
        // single underscore, and `"_" || full.id` is `"_"` — the fallback needs an EMPTY string,
        // which only an empty number produces. A first draft of this test asserted the fallback
        // here and was wrong about the other app.
        XCTAssertEqual(name("///"), "_.html")
        XCTAssertEqual(name("", id: "doc-9"), "doc-9.html", """
            a number that escapes to nothing must fall back to the id, exactly as `|| full.id` does \
            over there — otherwise the panel opens on a file called ".html".
            """)
        // The whitespace class is JS's `\\s`, and it is NOT `Character.isWhitespace`. Measured in
        // node: U+FEFF matches `\\s` and U+0085 does not; Swift's property says the opposite about
        // both, so a number carrying either would be named differently on the two sides.
        XCTAssertEqual(name("A\u{FEFF}B"), "A_B.html", "U+FEFF is whitespace to JS")
        XCTAssertEqual(name("A\u{0085}B"), "A\u{0085}B.html", """
            U+0085 is not in JS's whitespace class, so the other app keeps it. Swift's \
            `Character.isWhitespace` calls it whitespace — that disagreement is the whole reason \
            this port borrows the set D-1 measured instead of asking Foundation.
            """)
        XCTAssertEqual(name("A\u{00A0}B"), "A_B.html", "…and U+00A0 is in both")
        // A grapheme cluster that merely BEGINS with a space is not whitespace: JS replaces the
        // space alone and the combining mark survives, so this iterates scalars.
        XCTAssertEqual(name("A\u{0020}\u{0301}B"), "A_\u{0301}B.html")

        XCTAssertFalse(name("QT-1").hasPrefix("SoloLedger-"), """
            Q7-a's name is the number alone. The other app prefixes `SoloLedger-`; that difference \
            is the ruling's, not an oversight.
            """)
    }

    // MARK: - R1 · the statement's four columns (Q7's one template variant)

    /// Only this test pins the variant. Q2-b took the date OUT of the description and gave it a
    /// column; the other app glues it on the front (`salesToRow`) and shows six columns with three
    /// of them blank. Copying the six-column table here would therefore lose the date entirely —
    /// `ref_date` is the only date a line carries.
    func testR1AStatementsArtefactIsFourColumnsWithTheDateOfItsOwn() throws {
        let html = try Self.render(Self.detail(
            type: .statement,
            items: [Self.item(description: "", taxAmount: nil, amount: 500, refDate: "2026-01-09")]))

        XCTAssertTrue(html.contains("<thead><tr><th>Description</th><th>Date</th>"
                                    + "<th class=\"val\">Tax Amount</th>"
                                    + "<th class=\"val\">Amount</th></tr></thead>"), """
            a statement's table is not the adjudicated four columns. Q2-b: description, date, \
            amount and tax — no quantity, no unit price, and the rate forbidden outright.
            """)
        XCTAssertTrue(html.contains("<td>2026-01-09</td>"), "the date is a cell of its own")
        XCTAssertFalse(html.contains("Tax Rate"), "Q2-b forbids the rate column outright")
        XCTAssertFalse(html.contains("Qty"), "a period summary describes no goods")
        XCTAssertFalse(html.contains(">2026-01-09 "), """
            the date was glued onto the front of the description. That is the other app's practice \
            and the exact thing Q2-b departs from.
            """)

        // …and the other four types keep the six-column table.
        let invoice = try Self.render(Self.detail(type: .commercialInvoice, items: [Self.item()]))
        XCTAssertTrue(invoice.contains("<th class=\"val\">Tax Rate</th>"))
        XCTAssertTrue(invoice.contains("<th class=\"val\">Qty</th>"))
        XCTAssertFalse(invoice.contains("<th>Date</th>"), "the date column is the statement's alone")
    }

    // MARK: - R4 / Q8 · the currency row, and only when there is a currency

    func testR4TheCurrencyRowAppearsOnlyWhenTheColumnHoldsOne() throws {
        let withCurrency = try Self.render(Self.detail(type: .statement, currency: "USD",
                                                       items: [Self.item()]))
        XCTAssertTrue(withCurrency.contains("<div class=\"meta\"><span>Currency: USD</span></div>"), """
            Q8's fourth extension: a document carrying a currency says so in the artefact's header, \
            as a CODE — this repository has no code-to-symbol table.
            """)

        let without = try Self.render(Self.detail(type: .commercialInvoice, items: [Self.item()]))
        XCTAssertFalse(without.contains("Currency:"), """
            a NULL currency produced a row anyway. That row is exactly what would put every ordinary \
            document outside Q7-b's byte-for-byte domain.
            """)
    }

    // MARK: - R3 / B5 · the letterhead is the company name and nothing else

    func testR3TheLetterheadCarriesOnlyTheCompanyName() throws {
        let html = try Self.render(Self.detail(type: .quotation, items: [Self.item()]),
                                   companyName: "Acme Ltd")
        XCTAssertTrue(html.contains("<div class=\"company\">Acme Ltd</div>"))
        XCTAssertFalse(html.contains("class=\"cmeta\""), """
            the small-print line appeared. The other app fills it from `company_info`'s credit code, \
            address and legal person; this app's settings hold `company_name` and nothing else, \
            which §3 · B5 registers rather than papering over.
            """)

        let anonymous = try Self.render(Self.detail(type: .quotation, items: [Self.item()]),
                                        companyName: "")
        XCTAssertTrue(anonymous.contains("<div class=\"company\">—</div>"),
                      "an empty name falls back to the em dash, exactly as `company?.name || '—'` does")
    }

    // MARK: - R5 / B6 · the timestamp is ISO-8601 UTC

    func testR5TheGeneratedAtIsISO8601UTCAndInjectable() {
        XCTAssertEqual(AppModel.artefactGeneratedAt(Date(timeIntervalSince1970: 1_767_225_600)),
                       "2026-01-01T00:00:00Z")
        XCTAssertEqual(AppModel.artefactGeneratedAt(Date(timeIntervalSince1970: 1_767_225_599)),
                       "2025-12-31T23:59:59Z", "one second earlier is the previous UTC day")

        // On any host that is not itself UTC, prove the answer is not the local clock's.
        let instant = Date(timeIntervalSince1970: 1_767_225_600)
        if TimeZone.current.secondsFromGMT(for: instant) != 0 {
            var local = Calendar(identifier: .gregorian)
            local.timeZone = TimeZone.current
            let day = local.dateComponents([.day], from: instant).day ?? 0
            XCTAssertFalse(AppModel.artefactGeneratedAt(instant).contains(String(format: "-%02dT", day)),
                           "the artefact's timestamp followed this host's clock instead of UTC")
        }
    }

    // MARK: - R6 / B7 · the artefact speaks the other app's language codes

    func testR6TheArtefactCarriesElectronsLanguageCodes() throws {
        XCTAssertEqual(DocumentHTML.artefactLanguage(for: "zh-Hans"), "zh-CN")
        XCTAssertEqual(DocumentHTML.artefactLanguage(for: "zh-Hant"), "zh-TW")
        for shared in ["en", "ja", "ko", "fr"] {
            XCTAssertEqual(DocumentHTML.artefactLanguage(for: shared), shared,
                           "only the two Chinese codes differ between the apps")
        }

        // …and it reaches the file, on both halves: the lang attribute and the font stack.
        let html = try Self.render(Self.detail(type: .quotation, items: [Self.item()]),
                                   language: "zh-Hant")
        XCTAssertTrue(html.contains("<html lang=\"zh-TW\">"))
        XCTAssertTrue(html.contains("\"PingFang TC\""), """
            the traditional-Chinese font stack did not come out. `cjkFonts` keys on the same string \
            as the lang attribute, so getting the code wrong changes the glyphs a reader sees too.
            """)
        XCTAssertFalse(html.contains("zh-Hant"), "this app's own code must not reach the file")
    }

    // MARK: - R2 / B3 · the tax labels are the screen's, not the regime's

    func testR2TheArtefactUsesTheSameFixedTaxLabelsTheScreenDoes() throws {
        // A US-regime document: over there the artefact would say "Sales Tax Rate", from a concept
        // table this app deliberately does not carry (§3 · B3 / B4).
        let html = try Self.render(Self.detail(type: .commercialInvoice, locale: .US,
                                               items: [Self.item()]),
                                   language: "en")
        XCTAssertTrue(html.contains("<th class=\"val\">Tax Rate</th>"), """
            the artefact's rate heading is the screen's fixed one. Taking the regime's word instead \
            would need `formTaxRate` from an accounting-locale concept table, which is a profile \
            change and a ruling of its own.
            """)
        XCTAssertFalse(html.contains("Sales Tax"))

        // The screen says the same word, which is the point of B3 — the file and the page agree.
        let editor = DocumentEditorDraft(document: Self.document(number: "CI-1"), items: [Self.item()])
        let page = DocumentPageComposition.compose(DocumentPageComposition.Input(editor: editor))
        let model = AppModel()
        model.setLanguage("en", persist: false)
        XCTAssertEqual(model.t("documents.item.taxRate"), "Tax Rate")
        XCTAssertNotNil(page.editor)
    }

    // MARK: - DX3 · what a save-panel run leaves on the page

    /// The case a panel test could never reach: **cancelling says nothing.**
    func testDX3ACancelledSaveLeavesNoSentenceBehind() {
        XCTAssertEqual(AppModel.exportOutcome(for: .written(path: "/tmp/QT-1.html")),
                       .done(path: "/tmp/QT-1.html"))
        XCTAssertEqual(AppModel.exportOutcome(for: .failed), .failed)
        XCTAssertNil(AppModel.exportOutcome(for: .cancelled), """
            a cancelled save panel reported something. The other app is silent there too — its
            `ok=false` with no error falls straight through — and a failure sentence would tell the
            user their own Escape key broke something.
            """)

        // The two sentences the page can leave, and the one that carries a path.
        XCTAssertEqual(DocumentPageComposition.ExportOutcome.failed.messageKey,
                       "documents.export.failed")
        XCTAssertNil(DocumentPageComposition.ExportOutcome.failed.path)
        XCTAssertEqual(DocumentPageComposition.ExportOutcome.done(path: "/tmp/x").messageKey,
                       "documents.export.done")
        XCTAssertEqual(DocumentPageComposition.ExportOutcome.done(path: "/tmp/x").path, "/tmp/x")
    }

    // MARK: - Fixtures

    private static func render(_ detail: BusinessDocumentDetail,
                               companyName: String = "Acme Ltd",
                               language: String = "en") throws -> String {
        let model = AppModel()
        model.setLanguage(language, persist: false)
        model.companyName = companyName
        return model.documentArtefactHTML(for: detail, locale: pinnedLocale, generatedAt: generatedAt)
    }

    private static func document(number: String = "CI-2026-0001",
                                 id: String = "doc-1",
                                 type: BusinessDocumentType = .commercialInvoice,
                                 currency: String? = nil,
                                 locale: AccountingLocale? = .CN) -> BusinessDocument {
        BusinessDocument(id: id, type: type, number: number, status: .draft, date: "2026-08-18",
                         validUntil: nil, customerName: "Acme", customerTaxID: nil,
                         customerAddress: nil, customerContact: nil, accountingLocale: locale,
                         subtotal: 100, taxAmount: 13, total: 113, notes: nil, sourceSalesID: nil,
                         periodStart: nil, periodEnd: nil, currency: currency,
                         taxInvoiceIssued: false, taxInvoiceNumber: nil, taxInvoiceDate: nil,
                         taxInvoiceAttachmentPath: nil, createdAt: nil, updatedAt: nil)
    }

    private static func item(description: String? = "Widget",
                             quantity: Double? = 2,
                             unit: String? = "piece",
                             unitPrice: Double? = 50,
                             taxRate: String? = "13%",
                             taxAmount: Double? = 13,
                             amount: Double? = 100,
                             refDate: String? = nil) -> BusinessDocumentItem {
        BusinessDocumentItem(id: 1, productID: nil, description: description, quantity: quantity,
                             unit: unit, unitPrice: unitPrice, taxRate: taxRate,
                             taxAmount: taxAmount, amount: amount, lineNo: 0, refSalesID: nil,
                             refDate: refDate)
    }

    private static func detail(type: BusinessDocumentType,
                               currency: String? = nil,
                               locale: AccountingLocale? = .CN,
                               items: [BusinessDocumentItem]) -> BusinessDocumentDetail {
        BusinessDocumentDetail(document: document(type: type, currency: currency, locale: locale),
                               items: items)
    }

    /// The very document the goldens were generated from, decoded from the JSON the generator wrote.
    ///
    /// Decoded rather than restated in Swift: "the same input" is the whole claim, and two hand-kept
    /// copies of a fixture drift in exactly the way that makes a byte comparison stop meaning
    /// anything.
    private static func fixture() throws -> BusinessDocumentDetail {
        let url = fixtureRoot().appendingPathComponent("fixture.json")
        let raw = try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
        let root = try XCTUnwrap(raw as? [String: Any])
        let d = try XCTUnwrap(root["document"] as? [String: Any])
        let document = BusinessDocument(
            id: d["id"] as? String ?? "",
            type: .commercialInvoice,
            number: d["docNumber"] as? String ?? "",
            status: .draft,
            date: d["docDate"] as? String ?? "",
            validUntil: d["validUntil"] as? String,
            customerName: d["customerName"] as? String ?? "",
            customerTaxID: d["customerTaxId"] as? String,
            customerAddress: d["customerAddress"] as? String,
            customerContact: d["customerContact"] as? String,
            accountingLocale: .CN,
            subtotal: d["subtotal"] as? Double,
            taxAmount: d["taxAmount"] as? Double,
            total: d["total"] as? Double,
            notes: d["notes"] as? String,
            sourceSalesID: nil,
            periodStart: d["periodStart"] as? String,
            periodEnd: d["periodEnd"] as? String,
            currency: d["currency"] as? String,
            taxInvoiceIssued: false, taxInvoiceNumber: nil, taxInvoiceDate: nil,
            taxInvoiceAttachmentPath: nil, createdAt: nil, updatedAt: nil)
        let items = try XCTUnwrap(d["items"] as? [[String: Any]]).enumerated().map { index, raw in
            BusinessDocumentItem(id: index + 1, productID: nil,
                                 description: raw["description"] as? String,
                                 quantity: raw["quantity"] as? Double,
                                 unit: raw["unit"] as? String,
                                 unitPrice: raw["unitPrice"] as? Double,
                                 taxRate: raw["taxRate"] as? String,
                                 taxAmount: raw["taxAmount"] as? Double,
                                 amount: raw["amount"] as? Double,
                                 lineNo: index, refSalesID: nil, refDate: nil)
        }
        return BusinessDocumentDetail(document: document, items: items)
    }

    private static func golden(_ language: String) throws -> String {
        try String(contentsOf: fixtureRoot().appendingPathComponent("\(language).html"),
                   encoding: .utf8)
    }

    /// …/native/SoloLedger/App/Tests/SoloLedgerUnitTests/<this>.swift → …/native/SoloLedger
    private static func fixtureRoot() -> URL {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { dir.deleteLastPathComponent() }
        return dir.appendingPathComponent("Tests/Fixtures/documentHtml")
    }

    /// The first line that differs, so a failure names the byte instead of printing 4 kB twice.
    private static func firstDifference(_ a: String, _ b: String) -> (Int, String, String) {
        let left = a.components(separatedBy: "\n")
        let right = b.components(separatedBy: "\n")
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : "<missing>"
            let r = index < right.count ? right[index] : "<missing>"
            if l != r { return (index + 1, String(l.prefix(200)), String(r.prefix(200))) }
        }
        return (0, "", "")
    }
}
