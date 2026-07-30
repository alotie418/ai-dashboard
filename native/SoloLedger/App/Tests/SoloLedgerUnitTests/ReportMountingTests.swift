import XCTest
@testable import SoloLedger
import SoloLedgerCore

/// R8 P3d — where the report page puts things, and in particular where the four disclaimers go.
///
/// XCUITest is not available here (the runner hangs enabling automation mode in a headless
/// session), so "is the disclaimer on screen" is answered structurally instead: the page is built
/// from ``ReportPageComposition`` and nothing else, so asserting on the composition is asserting
/// on what the view can draw. The two halves are checked separately — the static placement table
/// covers the whole key namespace, and the per-state composition covers what one render uses.
final class ReportMountingTests: XCTestCase {

    private let languages = ["zh-Hans", "zh-Hant", "en", "ja", "ko", "fr"]
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try ReportFixtureBuilder.makeDirectory()
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func value(_ language: String, _ key: String) -> String {
        Localizer(language: language).t(key)
    }

    private func reportKeysInStrings(_ language: String) -> Set<String> {
        let path = Localizer.resourceBundle.path(forResource: language, ofType: "lproj")
            ?? Localizer.resourceBundle.path(forResource: language.lowercased(), ofType: "lproj")
        guard let path, let bundle = Bundle(path: path),
              let url = bundle.url(forResource: "Localizable", withExtension: "strings"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [],
                                                                     format: nil),
              let dict = plist as? [String: String] else {
            XCTFail("\(language): could not load Localizable.strings"); return []
        }
        return Set(dict.keys.filter { $0.hasPrefix(ReportPresenter.keyPrefix) })
    }

    /// Where one key sits: the region, plus the SLOT inside it.
    ///
    /// The slot matters for the ambiguity check. Two line labels side by side under one heading
    /// are ambiguous if they read the same; a heading that reads the same as one of its own
    /// lines is not — `US/se-tax` is titled "Self-Employment Tax" and its total line is called
    /// the same thing, which is the source's own shape and reads correctly. Bucketing by region
    /// alone would compare those two and fail on copy that was deliberately kept.
    private struct Slot: Hashable {
        let region: ReportPageComposition.Region
        /// `""` for regions with a single slot; otherwise which part of the block, and of which
        /// block — two different sections' line lists are also not side by side.
        let detail: String
    }

    private func placements(in page: ReportPageComposition.Page) -> [(key: String, slot: Slot)] {
        func slot(_ region: ReportPageComposition.Region, _ detail: String = "") -> Slot {
            Slot(region: region, detail: detail)
        }
        var out: [(String, Slot)] = page.headerKeys.map { ($0, slot(.header)) }
        out += (page.notRequestedKeys ?? []).map { ($0, slot(.notRequested)) }
        out += (page.failedKeys ?? []).map { ($0, slot(.failed)) }
        out += page.footerKeys.map { ($0, slot(.pageFooter)) }
        if let blocked = page.blocked {
            out.append((blocked.titleKey, slot(.blocked, "title")))
            out.append((blocked.bodyKey, slot(.blocked, "body")))
            out += blocked.factKeys.map { ($0 == "report.storedText.label"
                                           ? ($0, slot(.fieldState)) : ($0, slot(.blocked, "facts"))) }
            out += blocked.actionKeys.map { ($0, slot(.blocked, "action")) }
        }
        if let body = page.body {
            for section in body.sections {
                out.append((section.titleKey, slot(.section, "title:\(section.reportTypeID)")))
                out += section.lineKeys.map { ($0, slot(.section, "lines:\(section.reportTypeID)")) }
                out += section.noteKeys.map { ($0, slot(.section, "notes:\(section.reportTypeID)")) }
                out += section.disclaimerKeys.map {
                    ($0, slot(.section, "disclaimer:\(section.reportTypeID)"))
                }
            }
            if let block = body.undeclaredTaxInclusive {
                // The heading is an undeclared-block key; the three lines are the same shared
                // line labels the declared sections use.
                out.append((block.titleKey, slot(.undeclaredBlock)))
                out += block.lineKeys.map { ($0, slot(.section, "lines:\(block.reportTypeID)")) }
            }
            out.append((body.parameters.titleKey, slot(.parameters, "title")))
            out += body.parameters.axisKeys.map { ($0, slot(.parameters, "axes")) }
            for (index, row) in body.parameters.rows.enumerated() {
                out += row.map { ($0, slot(.parameters, "row\(index)")) }
            }
            out += body.parameters.disclaimerKeys.map { ($0, slot(.parameters, "disclaimer")) }
            out += body.cashflowKeys.map { ($0, slot(.cashflow)) }
            out += body.monthlyKeys.map { ($0, slot(.monthly)) }
            out += body.noteKeys.map { ($0, slot(.notes)) }
            out += body.warningKeys.map { ($0, slot(.warnings)) }
            out += body.footerKeys.map { ($0, slot(.pageFooter)) }
        }
        return out.map { (key: $0.0, slot: $0.1) }
    }

    private func compositions() throws -> [ReportPageComposition.Page] {
        var pages: [ReportPageComposition.Page] = [
            ReportPageComposition.compose(.notRequested, uiLanguage: "zh-Hans"),
            ReportPageComposition.compose(.failed(year: "2025"), uiLanguage: "zh-Hans"),
        ]
        for blocker in ReportPresenter.allBlockerRepresentatives {
            pages.append(ReportPageComposition.compose(.blocked(year: "2025", blocker),
                                                       uiLanguage: "zh-Hans"))
        }
        for (_, report) in try ReportFixtureBuilder.allReports(in: directory) {
            pages.append(ReportPageComposition.compose(.report(report), uiLanguage: "zh-Hans"))
        }
        return pages
    }

    // MARK: - D1 / D2 — the placement table is total over the namespace

    func testTheKeyUniverseIsExactlyOneHundredAndSixtyFive() {
        let declared = Set(ReportPageComposition.placement.keys)
        XCTAssertEqual(declared.count, 165, "161 landed by the copy PRs + 4 disclaimers")
        for language in languages {
            XCTAssertEqual(reportKeysInStrings(language), declared, """
                \(language): the copy and the page's placement table disagree.
                written but never drawn: \(reportKeysInStrings(language).subtracting(declared).sorted())
                drawn but never written: \(declared.subtracting(reportKeysInStrings(language)).sorted())
                """)
        }
        // And still closed against the code that emits keys, so P3c's guarantee survives.
        let accounted = ReportPresenter.allEmittableKeys()
            .union(ReportStateCopyTests.viewLayerKeys)
            .union(["report.disclaimer.report", "report.disclaimer.tax",
                    "report.disclaimer.usTax", "report.disclaimer.rates"])
        XCTAssertEqual(declared, accounted)
    }

    func testEveryRegionIsUsedAndEveryKeyHasOne() {
        let byRegion = Dictionary(grouping: ReportPageComposition.placement, by: \.value)
        for region in ReportPageComposition.Region.allCases {
            XCTAssertFalse((byRegion[region] ?? []).isEmpty, "\(region) has no keys")
        }
        XCTAssertEqual(ReportPageComposition.placement.count, 165)
    }

    // MARK: - D3 — the page-level disclaimer

    func testThePageFooterCarriesTheReportDisclaimerInThreeStatesAndNotTheFourth() throws {
        let report = try ReportFixtureBuilder.report(regime: .CN, in: directory)
        let key = ReportPageComposition.reportDisclaimerKey
        for state in [ReportPageState.report(report),
                      .blocked(year: "2025", .legacySourceUnavailable),
                      .failed(year: "2025")] {
            let page = ReportPageComposition.compose(state, uiLanguage: "zh-Hans")
            XCTAssertTrue(page.footerKeys.contains(key), "\(state) must carry the page disclaimer")
        }
        // Nothing is on screen yet, so there is nothing for it to qualify.
        XCTAssertTrue(ReportPageComposition.compose(.notRequested, uiLanguage: "zh-Hans")
            .footerKeys.isEmpty)
    }

    // MARK: - D4 — the tax disclaimer, on exactly five sections and nowhere else

    func testTheTaxDisclaimerMountsOnEveryTurnoverTaxSectionAndNowhereElse() throws {
        let expected: [String: String] = ["CN": "vat-summary", "JP": "consumption-tax",
                                          "EU": "vat-return", "KR": "vat-summary",
                                          "TW": "business-tax"]
        var mounts = 0
        for (regime, report) in try ReportFixtureBuilder.allReports(in: directory) {
            let page = ReportPageComposition.compose(.report(report), uiLanguage: "zh-Hans")
            let body = try XCTUnwrap(page.body)
            for section in body.sections {
                let carries = section.disclaimerKeys.contains(ReportPageComposition.taxDisclaimerKey)
                let shouldCarry = expected[regime.rawValue] == section.reportTypeID
                XCTAssertEqual(carries, shouldCarry,
                               "\(regime.rawValue)/\(section.reportTypeID): tax disclaimer "
                               + (carries ? "must not be here" : "is missing"))
                if carries { mounts += 1 }
            }
            // The tax-inclusive blocks add up recorded amounts and estimate no tax, so they do
            // not carry it either — declared (China) or undeclared (the other four).
            XCTAssertFalse(body.undeclaredTaxInclusive?.disclaimerKeys
                .contains(ReportPageComposition.taxDisclaimerKey) ?? false,
                           "\(regime.rawValue): the undeclared tax-inclusive block must not carry it")
        }
        XCTAssertEqual(mounts, 5, "exactly five turnover-tax sections across the six regimes")
    }

    // MARK: - D5 — the US disclaimer

    func testTheUSTaxDisclaimerMountsOnlyOnTheSelfEmploymentSection() throws {
        var mounts = 0
        for (regime, report) in try ReportFixtureBuilder.allReports(in: directory) {
            let body = try XCTUnwrap(ReportPageComposition
                .compose(.report(report), uiLanguage: "zh-Hans").body)
            for section in body.sections
            where section.disclaimerKeys.contains(ReportPageComposition.usTaxDisclaimerKey) {
                XCTAssertEqual(regime, .US)
                XCTAssertEqual(section.reportTypeID, "se-tax")
                mounts += 1
            }
        }
        XCTAssertEqual(mounts, 1)
    }

    // MARK: - D6 — the rates disclaimer

    func testTheRatesDisclaimerMountsOnTheParameterBlockOnly() throws {
        for (_, report) in try ReportFixtureBuilder.allReports(in: directory) {
            let body = try XCTUnwrap(ReportPageComposition
                .compose(.report(report), uiLanguage: "zh-Hans").body)
            XCTAssertEqual(body.parameters.disclaimerKeys,
                           [ReportPageComposition.ratesDisclaimerKey])
            for section in body.sections {
                XCTAssertFalse(section.disclaimerKeys
                    .contains(ReportPageComposition.ratesDisclaimerKey))
            }
        }
        // A page with no report has no parameter block, so it cannot carry it.
        for state in [ReportPageState.notRequested, .failed(year: "2025"),
                      .blocked(year: "2025", .legacySourceUnavailable)] {
            let page = ReportPageComposition.compose(state, uiLanguage: "zh-Hans")
            XCTAssertFalse(page.allKeys.contains(ReportPageComposition.ratesDisclaimerKey))
        }
    }

    // MARK: - D7 — composed placement agrees with the declared placement

    func testEveryComposedKeyMatchesItsDeclaredRegion() throws {
        for page in try compositions() {
            for (key, slot) in placements(in: page) {
                guard let declared = ReportPageComposition.placement[key] else {
                    XCTFail("\(key) is composed but has no declared region"); continue
                }
                XCTAssertEqual(declared, slot.region,
                               "\(key) is drawn in \(slot.region), declared \(declared)")
            }
        }
    }

    /// Everything a real page can draw is in the namespace, and the states between them reach
    /// most of it. The keys no fixture reaches are the ones whose state has no producer or needs
    /// a hand-built ledger; they are still declared, which is what D1 checks.
    func testComposedPagesStayInsideTheDeclaredUniverse() throws {
        let declared = Set(ReportPageComposition.placement.keys)
        for page in try compositions() {
            XCTAssertTrue(page.allKeys.isSubset(of: declared),
                          "outside the universe: \(page.allKeys.subtracting(declared).sorted())")
        }
    }

    // MARK: - D8 — a withheld section is not drawable

    func testAWithheldSectionProducesNoBlock() throws {
        // Every declared pair is `.renderInFull` today, so this is a check of the MAPPING and
        // not evidence that a real ledger reaches `.withhold`.
        XCTAssertEqual(ReportPresenter.rendering(for: .withhold), .withheld)
        for (_, report) in try ReportFixtureBuilder.allReports(in: directory) {
            let body = try XCTUnwrap(ReportPageComposition
                .compose(.report(report), uiLanguage: "zh-Hans").body)
            XCTAssertEqual(body.sections.count, report.sections.count,
                           "no section is withheld today, so every one produces a block")
        }
    }

    // MARK: - D9 — China's five turnover-tax lines and their note

    func testChinaVatSummaryKeepsFiveLinesAndCarriesTheAliasNote() throws {
        let report = try ReportFixtureBuilder.report(regime: .CN, in: directory)
        let body = try XCTUnwrap(ReportPageComposition
            .compose(.report(report), uiLanguage: "zh-Hans").body)
        let block = try XCTUnwrap(body.sections.first { $0.reportTypeID == "vat-summary" })
        XCTAssertEqual(block.lineKeys.count, 5)
        XCTAssertTrue(block.noteKeys.contains(ReportPresenter.chinaTurnoverTaxAliasNoteKey))
        XCTAssertTrue(block.disclaimerKeys.contains(ReportPageComposition.taxDisclaimerKey))

        let lines = report.sections.first { $0.reportTypeID == "vat-summary" }?.lines ?? []
        func amount(_ id: String) -> Double? {
            guard case .amount(let v)? = lines.first(where: { $0.id == id })?.value else { return nil }
            return v
        }
        XCTAssertEqual(amount("certifiedInput"), amount("cumulativeInput"))
        XCTAssertEqual(amount("invoicedOutput"), amount("cumulativeOutput"))
    }

    // MARK: - D10 / D11 — what a refusal offers

    func testOnlyTheTwoLocaleBlockersCarryActionKeys() {
        var offering = 0
        for blocker in ReportPresenter.allBlockerRepresentatives {
            let page = ReportPageComposition.compose(.blocked(year: "2025", blocker),
                                                     uiLanguage: "zh-Hans")
            let block = page.blocked
            XCTAssertNotNil(block)
            guard let block else { continue }
            if block.action == .openSettings {
                offering += 1
                XCTAssertEqual(block.actionKeys,
                               ["report.action.openSettings", "report.action.openSettings.hint"])
            } else {
                XCTAssertTrue(block.actionKeys.isEmpty,
                              "a refusal with no control must not describe one")
            }
        }
        XCTAssertEqual(offering, 2)
    }

    func testTheLegacyRefusalOffersNothingAndPointsAtNothing() {
        let page = ReportPageComposition.compose(.blocked(year: "2025", .legacySourceUnavailable),
                                                 uiLanguage: "zh-Hans")
        let block = try? XCTUnwrap(page.blocked)
        XCTAssertEqual(block?.actionKeys, [])
        // It has no fact to show either: not reading the older tables is exactly why it cannot
        // say anything about them.
        XCTAssertEqual(block?.factKeys, [])
        XCTAssertEqual(block?.action, ReportPresenter.BlockerAction.none)
    }

    // MARK: - D12 / D13 — money and currency on a composed page

    func testTheCurrencyCaptionComesFromTheReportAndNotTheLedger() throws {
        let store = try ReportFixtureBuilder.makeStore(regime: .CN, in: directory)
        defer { try? store.db.close() }
        guard case .report(let report) =
                try ReportBuilder.build(store.db,
                                        period: ReportPeriod(year: ReportFixtureBuilder.year))
        else { return XCTFail("CN fixture blocked") }
        XCTAssertEqual(ReportFormat.currencyDisplay(report.currency), "CNY")
        try store.settings.applyRegimeSwitch(AccountingProfile.us)
        XCTAssertEqual(ReportFormat.currencyDisplay(report.currency), "CNY",
                       "a held report must not follow the ledger")
        // No formatter anywhere may put a symbol next to the number.
        for language in languages {
            let text = ReportFormat.money(1234.5, language: language)
            XCTAssertFalse(text.contains(where: { $0.isLetter }))
            for symbol in ["¥", "$", "€", "₩", "￥"] { XCTAssertFalse(text.contains(symbol)) }
        }
    }

    func testTheFormatNoteAppearsOnlyForACodeThatIsNotThreeLetters() throws {
        let report = try ReportFixtureBuilder.report(regime: .CN, in: directory)
        let page = ReportPageComposition.compose(.report(report), uiLanguage: "zh-Hans")
        XCTAssertEqual(ReportFormat.currencyShape(report.currency), .threeLetter)
        XCTAssertFalse(page.headerKeys.contains("report.currency.formatNote"),
                       "a three-letter code gets no comment — the app cannot judge it")
        // The uniform disclosure is there whatever the code says.
        XCTAssertTrue(page.headerKeys.contains("report.currency.note"))

        // …and the shape rule itself, which decides that branch.
        for code in ["CNY", "USD", "XYZ", "usd"] {
            XCTAssertEqual(ReportFormat.currencyShape(code), .threeLetter, code)
        }
        for code in ["CN", "CNYY", " CNY ", "人民币", "\u{202E}USD", ""] {
            XCTAssertEqual(ReportFormat.currencyShape(code), .other, code.debugDescription)
        }
    }

    // MARK: - D14 — a stored setting reaches the page verbatim

    func testTheInvalidBlockersShowTheStoredTextAndKeepItsQuotes() {
        for blocker in [ReportBlocker.accountingLocaleInvalid(storedText: "\"XX\""),
                        .currencyInvalid(storedText: "\"\"", periodCurrencies: ["CNY"],
                                         regimeDefault: "CNY")] {
            let page = ReportPageComposition.compose(.blocked(year: "2025", blocker),
                                                     uiLanguage: "zh-Hans")
            XCTAssertTrue(page.blocked?.factKeys.contains("report.storedText.label") ?? false,
                          "\(blocker) must show what the ledger actually holds")
        }
        // The falsification the whole preview exists for: stripping the quotes would make the
        // `malformed` and `malformed-raw` rows indistinguishable, and they are different rows.
        XCTAssertEqual(ReportFormat.safePreview("\"25%\""), "\"25%\"")
        XCTAssertEqual(ReportFormat.safePreview("25%"), "25%")
        XCTAssertNotEqual(ReportFormat.safePreview("\"25%\""), ReportFormat.safePreview("25%"))
        XCTAssertEqual(ReportFormat.safePreview("2\u{0}5"), "2<U+0000>5")
        XCTAssertEqual(ReportFormat.safePreview("a\u{202E}b"), "a<U+202E>b")
    }

    // MARK: - D15 / D16 — the year

    func testTheYearControlAcceptsOnlyFourDigitsAndTheInvalidHintIsAlwaysAvailable() {
        for text in ["0001", "1998", "2025", "9999"] { XCTAssertTrue(ReportYear.isValid(text)) }
        for text in ["999", "10000", "20a5", "", " 2025", "0000"] {
            XCTAssertFalse(ReportYear.isValid(text), text.debugDescription)
        }
        XCTAssertEqual(ReportYear.stepped("9999", by: 1), "9999")
        XCTAssertEqual(ReportYear.stepped("0001", by: -1), "0001")
        // The hint belongs to the header in every state, because the control does.
        for state in [ReportPageState.notRequested, .failed(year: "2025"),
                      .blocked(year: "2025", .legacySourceUnavailable)] {
            XCTAssertTrue(ReportPageComposition.compose(state, uiLanguage: "zh-Hans")
                .headerKeys.contains("report.year.invalid"))
        }
    }

    func testEveryNonEmptyStateCarriesItsOwnYear() throws {
        let report = try ReportFixtureBuilder.report(regime: .CN, in: directory)
        XCTAssertEqual(ReportPageState.report(report).year, report.period.year)
        XCTAssertEqual(ReportPageState.blocked(year: "2019", .legacySourceUnavailable).year, "2019")
        XCTAssertEqual(ReportPageState.failed(year: "2019").year, "2019")
        XCTAssertNil(ReportPageState.notRequested.year)
    }

    // MARK: - D17 — no loading state, and no spinner to go with it

    func testThePageHasNoLoadingStateAndDrawsNoSpinner() throws {
        // A synchronous build never renders a loading frame, so a spinner would be a control the
        // user can never see.
        let source = try ReportFixtureBuilder.appSource("Views/ReportsView.swift")
        XCTAssertFalse(source.contains("ProgressView"), "the report page must not show a spinner")
        XCTAssertFalse(source.contains("/*"), "block comments are invisible to the bypass guard")
        XCTAssertNil(ReportPageState.notRequested.year)
    }

    // MARK: - D18 — no two keys in one SLOT render the same label

    /// The extension of P3b's line-against-line check to this page's other lists. It stays
    /// line-against-line: a section heading is not compared with its own lines, because
    /// `US/se-tax` deliberately titles the block and its total with the same string, matching
    /// the source. Comparing across slots would fail on copy that was kept on purpose.
    func testNoTwoKeysInOneSlotRenderTheSameLabel() throws {
        for page in try compositions() {
            for language in languages {
                var bySlotText: [String: [String]] = [:]
                for (key, slot) in placements(in: page) {
                    bySlotText["\(slot.region.rawValue)/\(slot.detail)|\(value(language, key))",
                               default: []].append(key)
                }
                for (bucket, keys) in bySlotText where Set(keys).count > 1 {
                    XCTFail("\(language) \(bucket): \(Set(keys).sorted()) render identically")
                }
            }
        }
    }

    // MARK: - D19 — the page is still unreachable

    /// Two independent facts, and both are needed. `SidebarSection` having no case proves there
    /// is no route to the page; this proves nothing constructs it by another path.
    func testReportsViewHasNoCallSite() throws {
        let root = ReportFixtureBuilder.packageRoot().appendingPathComponent("Sources/SoloLedger")
        let walker = try XCTUnwrap(FileManager.default.enumerator(atPath: root.path))
        var scanned = 0
        for case let relative as String in walker where relative.hasSuffix(".swift") {
            guard !relative.hasSuffix("ReportsView.swift") else { continue }
            let text = try String(contentsOf: root.appendingPathComponent(relative),
                                  encoding: .utf8)
            scanned += 1
            XCTAssertFalse(text.contains("ReportsView("),
                           "\(relative) constructs ReportsView — the page must stay unreachable")
        }
        XCTAssertGreaterThan(scanned, 10, "the scan must have seen the app target")
        XCTAssertEqual(SidebarSection.allCases.map(\.rawValue),
                       ["overview", "transactions", "categories"])
        XCTAssertNil(SidebarSection(rawValue: "reports"))
    }

    // MARK: - D20 — the exemption table grew by exactly eleven

    /// `sanctionedUses` lives in the SwiftPM test target, which this one cannot import, so the
    /// count is read from the committed source. The BEHAVIOUR of those entries is checked where
    /// they live — `testSanctionedTableMatchesTheRealHitsExactly` makes the table and the real
    /// hits equal as SETS, in both directions.
    func testTheSanctionedTableIsExactlyTwentyTwoEntries() throws {
        let url = ReportFixtureBuilder.packageRoot()
            .appendingPathComponent("Tests/SoloLedgerCoreTests/LocalizationWordingGuardTests.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        guard let start = source.range(of: "static let sanctionedUses"),
              let end = source.range(of: "\n    ]", range: start.upperBound..<source.endIndex) else {
            return XCTFail("could not locate the sanctionedUses array")
        }
        let table = String(source[start.lowerBound..<end.lowerBound])
        let entries = table.components(separatedBy: ".init(locale:").count - 1
        XCTAssertEqual(entries, 22, "11 pre-existing + 11 for the report page's disclaimers")

        let onReportDisclaimers = table.components(separatedBy: "key: \"report.disclaimer.").count - 1
        XCTAssertEqual(onReportDisclaimers, 11)
        XCTAssertEqual(entries - onReportDisclaimers, 11)

        // The rates disclaimer says nothing about filing and must claim no exemption. Matched on
        // the ENTRY, not on the substring: the array carries a comment explaining why that key
        // is absent, and a substring test would be tripped by the explanation.
        XCTAssertFalse(table.contains("key: \"report.disclaimer.rates\""))
        // Every new entry names a key that really exists in the copy.
        for suffix in ["report", "tax", "usTax"] {
            for language in languages {
                XCTAssertNotEqual(value(language, "report.disclaimer.\(suffix)"),
                                  "report.disclaimer.\(suffix)")
            }
        }
    }

    /// The four disclaimers resolve in all six languages and none of them names a statutory
    /// statement — that list has zero sanctioned uses and may not gain one.
    func testTheFourDisclaimersResolveAndNameNoStatutoryStatement() throws {
        let banned = ["利润表", "利潤表", "损益表", "損益表", "资产负债表", "資產負債表",
                      "貸借対照表", "재무상태표", "现金流量表", "現金流量表",
                      #"(?i)Income Statement"#, #"(?i)Balance Sheet"#,
                      #"(?i)Cash Flow Statement"#, #"(?i)Profit\s*&?\s*Loss\s+Statement"#]
        let regexes = try banned.map { try NSRegularExpression(pattern: $0) }
        for suffix in ["report", "tax", "usTax", "rates"] {
            let key = "report.disclaimer.\(suffix)"
            for language in languages {
                let text = value(language, key)
                XCTAssertNotEqual(text, key, "\(language)/\(key) leaks the raw key")
                XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                for (pattern, regex) in zip(banned, regexes) {
                    XCTAssertNil(regex.firstMatch(in: text,
                                                  range: NSRange(text.startIndex..., in: text)),
                                 "\(language)/\(key) matches \(pattern)")
                }
            }
        }
    }
}
