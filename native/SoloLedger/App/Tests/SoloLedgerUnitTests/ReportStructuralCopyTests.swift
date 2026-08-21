import XCTest
@testable import SoloLedger
import SoloLedgerCore

/// R8 P3b — the 82 structural copy keys: 13 section titles, 4 undeclared-block titles, two
/// notes, and 63 shared line labels.
///
/// The enumeration below starts from the MAPPING FUNCTIONS, never from the `.strings` files.
/// A test that walks the files can only ever confirm that what is there resolves; it is blind
/// to the failure that matters here — a key the code will ask for that nobody wrote. The
/// existing full-universe guards (`MigrationCopyParityTests`) cover the other direction, so
/// between them neither a missing key nor an orphaned one survives.
final class ReportStructuralCopyTests: XCTestCase {

    private let languages = ["zh-Hans", "zh-Hant", "en", "ja", "ko", "fr"]

    /// The 82 keys, derived from `ReportPresenter` rather than restated.
    private func structuralKeys() -> Set<String> {
        var keys = Set<String>()
        for id in ReportPresenter.knownLineIDs {
            guard case .key(let key) = ReportPresenter.lineLabel(for: id) else {
                XCTFail("\(id) is in the known set but does not map"); continue
            }
            keys.insert(key)
        }
        keys.formUnion(ReportPresenter.sectionTitleKeys.values)
        keys.formUnion(ReportPresenter.undeclaredTaxInclusiveTitleKeys.values)
        keys.insert("\(ReportPresenter.keyPrefix)section.missingLines")
        keys.insert(ReportPresenter.chinaTurnoverTaxAliasNoteKey)
        return keys
    }

    private func value(_ language: String, _ key: String) -> String {
        Localizer(language: language).t(key)
    }

    // MARK: - B2 — the universe is exactly 82, and exactly 37 are left for P3c

    func testStructuralKeyUniverseIsExactlyEightyTwo() {
        let keys = structuralKeys()
        XCTAssertEqual(keys.count, 82, "13 sections + 4 blocks + 2 notes + 63 lines")
        XCTAssertEqual(ReportPresenter.knownLineIDs.count, 63)
        XCTAssertEqual(ReportPresenter.sectionTitleKeys.count, 13)
        XCTAssertEqual(ReportPresenter.undeclaredTaxInclusiveTitleKeys.count, 4)

        let all = ReportPresenter.allEmittableKeys()
        XCTAssertTrue(keys.isSubset(of: all), "every structural key must be emittable")
        XCTAssertEqual(all.subtracting(keys).count, 37,
                       "the remainder is P3c's: 14 blocker + 3 field + 11 parameter + 4 names "
                       + "+ 1 cash-flow + 2 notes + 2 warnings")
    }

    // MARK: - B1 — every emittable structural key resolves, in all six languages

    func testEveryEmittableStructuralKeyResolvesInAllSixLocales() {
        let keys = structuralKeys().sorted()
        XCTAssertFalse(keys.isEmpty)
        for language in languages {
            let localizer = Localizer(language: language)
            for key in keys {
                let resolved = localizer.t(key)
                XCTAssertNotEqual(resolved, key, "\(language) leaks the raw key \(key)")
                XCTAssertFalse(resolved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                               "\(language)/\(key) is blank")
            }
        }
    }

    /// The six languages must say DIFFERENT things — a file filled with the zh-Hans value
    /// would pass the test above and be no translation at all. Checked on keys whose copy is
    /// genuinely language-specific (the `{tax}` templates and the Schedule C lines share
    /// Latin fragments across languages, so they are excluded from the strict form).
    func testTheSixLocalesAreNotCopiesOfOneAnother() {
        for key in ReportPresenter.sectionTitleKeys.values {
            let byLanguage = languages.map { value($0, key) }
            XCTAssertGreaterThanOrEqual(Set(byLanguage).count, 4,
                                        "\(key) reads the same in too many languages")
        }
    }

    // MARK: - B3 / B4 — dynamic keys follow the language switch

    func testDynamicLineLabelFollowsLanguageSwitch() {
        guard case .key(let key) = ReportPresenter.lineLabel(for: "netProfit") else {
            return XCTFail("netProfit must be a known line")
        }
        let zh = value("zh-Hans", key), ja = value("ja", key), fr = value("fr", key)
        XCTAssertNotEqual(zh, ja)
        XCTAssertNotEqual(zh, fr)
        XCTAssertNotEqual(ja, fr)
        for text in [zh, ja, fr] { XCTAssertNotEqual(text, key) }
    }

    func testRegimeSpecificSectionTitleFollowsLanguageSwitch() {
        guard case .key(let key) = ReportPresenter.sectionTitle(locale: "JP",
                                                                reportTypeID: "consumption-tax")
        else { return XCTFail("JP/consumption-tax must be a declared pair") }
        let zh = value("zh-Hans", key), ja = value("ja", key), ko = value("ko", key)
        XCTAssertNotEqual(zh, ja)
        XCTAssertNotEqual(ja, ko)
        for text in [zh, ja, ko] { XCTAssertNotEqual(text, key) }
    }

    // MARK: - B5 — the filing-word guard does not fold diacritics

    /// `certifiedInput` and `cumulativeInput` are French `TVA déductible …`, and they are legal
    /// only because `(?i)\bDeductible\b` does not match `déductible`: `NSRegularExpression`'s
    /// case-insensitive flag folds case and nothing else.
    ///
    /// That is a load-bearing accident. Anyone who "improves" the guard by adding
    /// `.diacriticInsensitive` would make five French labels illegal overnight, and the
    /// failure would look like a copy problem rather than a guard change. This states the
    /// dependency out loud so the change fails HERE, next to the explanation.
    func testTheFilingWordGuardDoesNotFoldDiacritics() throws {
        let pattern = #"(?i)\bDeductible\b"#
        let regex = try NSRegularExpression(pattern: pattern)
        func matches(_ text: String) -> Bool {
            regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
        XCTAssertFalse(matches("TVA déductible (total)"),
                       "é is not e; if this now matches, the guard started folding diacritics")
        XCTAssertFalse(matches("TVA déductible cumulée"))
        // …and the guard must still catch the word it is actually for.
        XCTAssertTrue(matches("VAT deductible"))
        XCTAssertTrue(matches("Deductible"))

        // The French values really are the ones this protects.
        guard case .key(let certified) = ReportPresenter.lineLabel(for: "certifiedInput"),
              case .key(let cumulative) = ReportPresenter.lineLabel(for: "cumulativeInput") else {
            return XCTFail("both China input lines must be known")
        }
        XCTAssertTrue(value("fr", certified).contains("déductible"))
        XCTAssertTrue(value("fr", cumulative).contains("déductible"))
    }

    // MARK: - B6 — no turnover-tax label claims a filing, a certification or a debt

    /// Five of the six engines emit a field literally called `payable` or `vatPayable`, and the
    /// obvious label for it is the one that asserts a debt to a tax authority — which this
    /// product does not compute. Same for `certifiedInput` / `invoicedOutput`, whose engine
    /// names are two more of the banned words verbatim.
    ///
    /// Checked on the FULLY EXPANDED text, so a `{tax}` substitution cannot smuggle a banned
    /// word in through the regime's own tax name.
    func testNoTurnoverTaxLabelCarriesAFilingWord() throws {
        let banned = [#"申报"#, #"申報"#, #"报税"#, #"報稅"#, #"认证"#, #"認證"#,
                      #"已开票"#, #"已開票"#, #"可抵扣"#, #"应交"#, #"應交"#, #"应缴"#, #"應繳"#,
                      #"(?i)\bFiling\b"#, #"(?i)\bCertified\b"#,
                      #"(?i)Invoiced\s+(?:Input|Output)"#, #"(?i)\bDeductible\b"#,
                      #"(?i)Auto-certify"#, #"(?i)\bPayable\b"#]
        let regexes = try banned.map { try NSRegularExpression(pattern: $0) }
        let ids = ["certifiedInput", "invoicedOutput", "estimatedPayable",
                   "paid", "collected", "payable", "inputVAT", "outputVAT", "vatPayable"]
        for id in ids {
            for language in languages {
                for regime in AccountingLocale.allCases {
                    let label = ReportPresenter.lineLabelText(
                        for: id, reportLocale: regime.rawValue, uiLanguage: language,
                        localized: { Localizer(language: language).t($0) })
                    guard case .text(let text) = label else {
                        return XCTFail("\(id)/\(language)/\(regime.rawValue) did not resolve: \(label)")
                    }
                    XCTAssertFalse(text.contains(ReportPresenter.taxToken),
                                   "\(id)/\(language)/\(regime.rawValue) still shows a raw token")
                    for (pattern, regex) in zip(banned, regexes) {
                        XCTAssertNil(regex.firstMatch(in: text,
                                                      range: NSRange(text.startIndex..., in: text)),
                                     "\(id)/\(language)/\(regime.rawValue) “\(text)” matches \(pattern)")
                    }
                }
            }
        }
    }

    // MARK: - B7 — no section title claims to be a statutory statement

    /// Zero sanctioned uses exist for this list and none may be added: a screen titled 损益表 /
    /// Income Statement claims to BE the statutory document, which is the product boundary
    /// CLAUDE.md draws. The titles shipped here say 概览 / 统计 / 汇总 / Management P&L instead.
    func testNoSectionTitleCarriesAStatutoryStatementName() throws {
        let banned = ["利润表", "利潤表", "损益表", "損益表", "资产负债表", "資產負債表",
                      "貸借対照表", "재무상태표", "现金流量表", "現金流量表",
                      #"(?i)Income Statement"#, #"(?i)Balance Sheet"#,
                      #"(?i)Cash Flow Statement"#, #"(?i)Profit\s*&?\s*Loss\s+Statement"#]
        let regexes = try banned.map { try NSRegularExpression(pattern: $0) }
        var titleKeys = Set(ReportPresenter.sectionTitleKeys.values)
        titleKeys.formUnion(ReportPresenter.undeclaredTaxInclusiveTitleKeys.values)
        XCTAssertEqual(titleKeys.count, 17)
        for key in titleKeys {
            for language in languages {
                let text = value(language, key)
                for (pattern, regex) in zip(banned, regexes) {
                    XCTAssertNil(regex.firstMatch(in: text,
                                                  range: NSRange(text.startIndex..., in: text)),
                                 "\(key)/\(language) “\(text)” matches \(pattern)")
                }
            }
        }
        // The whole 82-key set, not just the titles — a line label is no more allowed to name
        // a statutory statement than a heading is.
        for key in structuralKeys() {
            for language in languages {
                let text = value(language, key)
                for regex in regexes {
                    XCTAssertNil(regex.firstMatch(in: text,
                                                  range: NSRange(text.startIndex..., in: text)),
                                 "\(key)/\(language) names a statutory statement")
                }
            }
        }
    }

    // MARK: - B8 — no two lines of one section render the same label

    /// The defect this exists for was found by measurement, not by review: `finance.kpiGrossMargin`
    /// and `plGrossProfit` are BOTH `Marge brute` in French, so a figure and a percentage would
    /// have sat under one label in five of the six regimes.
    ///
    /// Section titles are deliberately out of scope: `US/se-tax`'s heading and its `totalSETax`
    /// line share one string in all six languages, which is the source's own shape (Electron's
    /// card title and total line are the same string) and reads correctly. This checks
    /// line-against-line, which is where a repeated label is genuinely ambiguous.
    func testNoTwoLinesOfOneSectionRenderTheSameLabel() throws {
        let directory = try ReportFixtureBuilder.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for (regime, report) in try ReportFixtureBuilder.allReports(in: directory) {
            for section in report.sections {
                for language in languages {
                    var byText: [String: [String]] = [:]
                    for line in section.lines {
                        let label = ReportPresenter.lineLabelText(
                            for: line.id, reportLocale: report.locale, uiLanguage: language,
                            localized: { Localizer(language: language).t($0) })
                        guard case .text(let text) = label else {
                            return XCTFail("\(regime.rawValue)/\(line.id) did not resolve: \(label)")
                        }
                        byText[text, default: []].append(line.id)
                    }
                    for (text, ids) in byText where ids.count > 1 {
                        XCTFail("""
                            \(regime.rawValue)/\(section.reportTypeID) [\(language)]: \
                            \(ids.sorted()) all render as “\(text)”
                            """)
                    }
                }
            }
        }
    }

    // MARK: - B9 — the `{tax}` contract holds in all six languages

    func testOnlyTheSixTurnoverTaxKeysCarryTheTaxToken() {
        XCTAssertEqual(ReportPresenter.taxInterpolatedLineIDs.count, 6)
        for id in ReportPresenter.knownLineIDs {
            guard case .key(let key) = ReportPresenter.lineLabel(for: id) else {
                XCTFail("\(id) does not map"); continue
            }
            let wantsToken = ReportPresenter.taxInterpolatedLineIDs.contains(id)
            XCTAssertEqual(ReportPresenter.requiredPlaceholders[key],
                           wantsToken ? [ReportPresenter.taxToken] : nil,
                           "\(id): the placeholder contract disagrees with the token set")
            for language in languages {
                XCTAssertEqual(value(language, key).contains(ReportPresenter.taxToken), wantsToken,
                               "\(language)/\(key) token presence is wrong")
            }
        }
        // The two notes and every title are plain text.
        var plain = Set(ReportPresenter.sectionTitleKeys.values)
        plain.formUnion(ReportPresenter.undeclaredTaxInclusiveTitleKeys.values)
        plain.insert("\(ReportPresenter.keyPrefix)section.missingLines")
        plain.insert(ReportPresenter.chinaTurnoverTaxAliasNoteKey)
        for key in plain {
            XCTAssertNil(ReportPresenter.requiredPlaceholders[key])
            for language in languages {
                XCTAssertFalse(value(language, key).contains("{"), "\(language)/\(key) has a token")
            }
        }
    }

    /// The regime comes from the REPORT, the language from the UI — and a settings change after
    /// the report was built cannot reach either.
    func testTheTaxNameFollowsTheReportsRegimeNotTheLedgers() throws {
        let directory = try ReportFixtureBuilder.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ReportFixtureBuilder.makeStore(regime: .JP, in: directory)
        defer { try? store.db.close() }
        guard case .report(let report) =
                try ReportBuilder.build(store.db,
                                        period: ReportPeriod(year: ReportFixtureBuilder.year))
        else { return XCTFail("JP fixture blocked") }

        func label(_ language: String) -> String {
            guard case .text(let text) = ReportPresenter.lineLabelText(
                for: "payable", reportLocale: report.locale, uiLanguage: language,
                localized: { Localizer(language: language).t($0) }) else { return "" }
            return text
        }
        XCTAssertEqual(label("zh-Hans"), "消费税估算额")
        XCTAssertEqual(label("en"), "Estimated Consumption Tax")

        try store.settings.applyRegimeSwitch(AccountingProfile.tw)
        XCTAssertEqual(label("zh-Hans"), "消费税估算额",
                       "the held report's regime must survive a settings change")
        XCTAssertEqual(label("en"), "Estimated Consumption Tax")
    }

    /// An unknown regime leaves the refusal visible rather than dropping the tax name and
    /// producing a label that looks finished.
    func testAnUnknownRegimeRefusesInsteadOfDroppingTheTaxName() {
        let label = ReportPresenter.lineLabelText(
            for: "payable", reportLocale: "XX", uiLanguage: "en",
            localized: { Localizer(language: "en").t($0) })
        XCTAssertEqual(label, .unresolvedTaxName(id: "payable"))

        // A line with no token resolves regardless of the regime.
        guard case .text = ReportPresenter.lineLabelText(
            for: "netProfit", reportLocale: "XX", uiLanguage: "en",
            localized: { Localizer(language: "en").t($0) }) else {
            return XCTFail("a token-free label must not depend on the regime")
        }
        XCTAssertEqual(ReportPresenter.lineLabelText(
            for: "notALine", reportLocale: "CN", uiLanguage: "en",
            localized: { Localizer(language: "en").t($0) }), .unmapped(id: "notALine"))
    }

    // MARK: - The two notes say what they were commissioned to say

    /// `section.missingLines` must not read as "there is no data". Its whole job is the
    /// opposite: some lines are not computed yet, and an absent line is not a zero.
    func testTheMissingLinesNoteDeniesThatAnAbsentLineIsZero() {
        let key = "\(ReportPresenter.keyPrefix)section.missingLines"
        XCTAssertTrue(value("zh-Hans", key).contains("不代表其数值为零"))
        XCTAssertTrue(value("zh-Hant", key).contains("不代表其數值為零"))
        XCTAssertTrue(value("en", key).lowercased().contains("zero"))
    }

    /// The China alias note states a FACT about the source and claims no accounting
    /// difference — L2. It must name both pairs, in each language's own labels.
    func testTheChinaAliasNoteNamesBothPairsAndClaimsNoAccountingDifference() {
        let key = ReportPresenter.chinaTurnoverTaxAliasNoteKey
        for language in languages {
            let note = value(language, key)
            for id in ["cumulativeInput", "certifiedInput", "cumulativeOutput", "invoicedOutput"] {
                guard case .key(let labelKey) = ReportPresenter.lineLabel(for: id) else {
                    XCTFail("\(id) does not map"); continue
                }
                XCTAssertTrue(note.contains(value(language, labelKey)),
                              "\(language): the note must quote \(id)'s own label")
            }
        }
        XCTAssertTrue(value("zh-Hans", key).contains("不代表二者在会计上不同"))
        XCTAssertTrue(value("en", key).lowercased().contains("does not mean"))
    }

    /// The two aliased pairs really are the same number — the fact the note states.
    func testTheAliasedPairsAreEqualInARealReport() throws {
        let directory = try ReportFixtureBuilder.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let report = try ReportFixtureBuilder.report(regime: .CN, in: directory)
        let lines = report.sections.first { $0.reportTypeID == "vat-summary" }?.lines ?? []
        func amount(_ id: String) -> Double? {
            guard case .amount(let v)? = lines.first(where: { $0.id == id })?.value else { return nil }
            return v
        }
        XCTAssertEqual(amount("certifiedInput"), amount("cumulativeInput"))
        XCTAssertEqual(amount("invoicedOutput"), amount("cumulativeOutput"))
        XCTAssertEqual(lines.count, 5, "all five are kept; the note explains the repetition")
    }

    // MARK: - The entry point, in every language

    /// P3e made the page reachable. Every sidebar row must resolve in all six languages, and no
    /// two rows may read the same: they sit in one region and one slot, so identical text there
    /// is an ambiguity the user has no way to resolve.
    func testTheEntryPointResolvesInEveryLanguage() {
        XCTAssertEqual(SidebarSection.allCases.map(\.rawValue),
                       ["overview", "transactions", "categories", "products", "inventory",
                        "documents", "reports"])
        for language in languages {
            var labels: [String] = []
            for section in SidebarSection.allCases {
                let text = value(language, section.titleKey)
                XCTAssertNotEqual(text, section.titleKey,
                                  "\(language)/\(section.titleKey) leaks the raw key")
                XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                               "\(language)/\(section.titleKey) is blank")
                labels.append(text)
            }
            XCTAssertEqual(Set(labels).count, labels.count,
                           "\(language): two sidebar rows read the same — \(labels)")
        }
    }
}
