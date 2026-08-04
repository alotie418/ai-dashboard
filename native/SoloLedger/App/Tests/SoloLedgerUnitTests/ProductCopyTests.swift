import XCTest
@testable import SoloLedger
import SoloLedgerCore

/// Stage 2b-A2 — the forty `product.*` strings the products page will need, landed in all six
/// languages and reachable by nothing.
///
/// ## What this file adds, given how much the tree already guards
///
/// Six-locale key parity, placeholder parity, duplicate keys and raw-key leaks are enforced over
/// the whole universe by `MigrationCopyParityTests`, and the banned-wording scan by
/// `LocalizationWordingGuardTests`. None of that is repeated here. What none of them can see is
/// what this stage can actually get wrong:
///
///  * **A miscount.** Key parity is satisfied by all six locales missing the same key. Only an
///    absolute count catches "the adjudicated table said forty and thirty-nine landed".
///  * **An unmapped case.** `ProductCatalogError` has six cases and `ProductUnit` eleven; a copy
///    set that is internally consistent but one short of either is invisible to every parity
///    check in the tree. Both are asserted in BOTH directions.
///  * **A quiet re-translation.** The eleven unit names are not new wording — they are the labels
///    the Electron app has been showing for these same keys. Re-typing them here would fork a
///    vocabulary that nothing would ever reconcile, so they are compared against that table.
///  * **A claim the app cannot keep.** Electron says service items *are* excluded from inventory.
///    This app has no inventory yet, so the present tense would be false; the copy says *will be*
///    and a ratchet keeps the retired sentences out.
///  * **Reachability.** 2b-A2's whole contract is that the copy lands dormant — the view, the
///    composition and the error mapping are 2b-A3.
///
/// ## The guard word lists are READ, not copied
///
/// ``testP10NewCopyHasZeroBannedWordingHits`` parses the tables out of
/// `LocalizationWordingGuardTests.swift` rather than restating them: that file lives in the
/// SwiftPM test target and cannot be imported from here, and a hand-copied vocabulary would go
/// stale in exactly the direction that matters — the guard grows a word, this file keeps passing.
final class ProductCopyTests: XCTestCase {

    private let languages = ["zh-Hans", "zh-Hant", "en", "ja", "ko", "fr"]

    // MARK: - The adjudicated table

    private static let pageKeys = ["product.page.title", "product.page.subtitle", "product.page.note"]
    private static let columnKeys = ["product.col.name", "product.col.unit", "product.col.cost",
                                     "product.col.type", "product.col.status"]
    private static let valueKeys = ["product.type.product", "product.type.service",
                                    "product.status.active", "product.status.inactive"]
    private static let unitKeys = ProductUnit.allCases.map { "product.unit.\($0.rawValue)" }
    private static let formKeys = ["product.form.newTitle", "product.form.editTitle",
                                   "product.form.namePlaceholder", "product.form.isService",
                                   "product.form.isServiceHint"]
    private static let actionKeys = ["product.action.add"]
    private static let deleteKeys = ["product.delete.confirmTitle", "product.delete.confirmMessage"]
    private static let emptyKeys = ["product.empty.title", "product.empty.message"]
    private static let errorKeys = allErrors.map(localizationKey(for:))
    private static let unreadableKeys = ["product.unreadable.notice"]

    private static var adjudicatedKeys: [String] {
        pageKeys + columnKeys + valueKeys + unitKeys + formKeys
            + actionKeys + deleteKeys + emptyKeys + errorKeys + unreadableKeys
    }

    /// Every `ProductCatalogError`, listed once.
    ///
    /// The list is kept honest by ``localizationKey(for:)`` below, whose switch is exhaustive and
    /// has no `default`: a new case stops this file compiling instead of quietly going unmapped.
    private static let allErrors: [ProductCatalogError] = [
        .invalidID, .nameRequired, .unitNotRecognized, .notFound, .idCollision, .storageFailure,
    ]

    /// The one place a `ProductCatalogError` is turned into a key. Exhaustive on purpose.
    private static func localizationKey(for error: ProductCatalogError) -> String {
        switch error {
        case .invalidID:          return "product.error.invalidID"
        case .nameRequired:       return "product.error.nameRequired"
        case .unitNotRecognized:  return "product.error.unitNotRecognized"
        case .notFound:           return "product.error.notFound"
        case .idCollision:        return "product.error.idCollision"
        case .storageFailure:     return "product.error.storageFailure"
        }
    }

    private static let allowedPlaceholders: Set<String> = ["{name}", "{count}"]

    /// Which keys carry which placeholders. A key absent from this map must carry none.
    private static let placeholderContract: [String: Set<String>] = [
        "product.delete.confirmTitle": ["{name}"],
        "product.unreadable.notice": ["{count}"],
    ]

    // MARK: - P1 · the absolute count

    func testP1TheProductNamespaceIsExactlyFortyKeys() throws {
        XCTAssertEqual(Self.adjudicatedKeys.count, 40, "the adjudicated table itself must be forty")
        XCTAssertEqual(Set(Self.adjudicatedKeys).count, 40, "the adjudicated table has a duplicate")
        for language in languages {
            let landed = try sourceTable(language).keys.filter { $0.hasPrefix("product.") }
            XCTAssertEqual(landed.count, 40, "\(language) landed \(landed.count) product.* keys")
            XCTAssertEqual(Set(landed), Set(Self.adjudicatedKeys), """
                \(language): landed set differs from the adjudicated table.
                extra:   \(Set(landed).subtracting(Self.adjudicatedKeys).sorted())
                missing: \(Set(Self.adjudicatedKeys).subtracting(landed).sorted())
                """)
        }
    }

    // MARK: - P2 · the whole universe, and six identical key sets

    func testP2EverySixLocaleFileHoldsFiveHundredThirtySixKeys() throws {
        var keySets: [Set<String>] = []
        for language in languages {
            let table = try sourceTable(language)
            XCTAssertEqual(table.count, 536, "\(language) has \(table.count) keys")
            keySets.append(Set(table.keys.filter { $0.hasPrefix("product.") }))
        }
        XCTAssertEqual(Set(keySets).count, 1, "the six locales do not agree on the product.* key set")
    }

    // MARK: - P3 · every key resolves, everywhere

    func testP3EveryProductKeyResolvesInAllSixLocales() throws {
        for language in languages {
            for key in Self.adjudicatedKeys {
                let resolved = value(language, key)
                XCTAssertNotEqual(resolved, key, "\(language)/\(key) resolved to the key itself")
                XCTAssertFalse(resolved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                               "\(language)/\(key) is blank")
            }
        }
    }

    // MARK: - P4 · the placeholder contract

    func testP4PlaceholdersAreTheContractedTokensAndNothingElse() throws {
        for language in languages {
            for key in Self.adjudicatedKeys {
                let text = value(language, key)
                let expected = Self.placeholderContract[key] ?? []
                XCTAssertEqual(placeholders(in: text), expected,
                               "\(language)/\(key) placeholder set")
                XCTAssertTrue(expected.isSubset(of: Self.allowedPlaceholders),
                              "\(key) contracts a token outside the allowed set")
                // Full-width braces are the blind spot the ASCII regex cannot see: `｛count｝`
                // reads as "this key has no placeholder" and passes every parity check.
                XCTAssertNil(text.range(of: "[｛｝]", options: .regularExpression),
                             "\(language)/\(key) contains a full-width brace")
            }
        }
    }

    // MARK: - P5 · every placeholder substitutes away

    func testP5EveryPlaceholderSubstitutesAwayIncludingAtZeroAndOne() {
        for language in languages {
            for (key, tokens) in Self.placeholderContract {
                for sample in ["0", "1", "42"] {
                    var rendered = value(language, key)
                    for token in tokens {
                        let replacement = token == "{name}" ? "A 型包装盒" : sample
                        rendered = rendered.replacingOccurrences(of: token, with: replacement)
                    }
                    XCTAssertNil(rendered.range(of: "[{}｛｝]", options: .regularExpression),
                                 "\(language)/\(key) at \(sample) still holds a brace: \(rendered)")
                }
            }
        }
    }

    // MARK: - P6 · ProductCatalogError, both directions

    func testP6EveryErrorCaseHasExactlyOneSentenceAndViceVersa() throws {
        let mapped = Self.allErrors.map(Self.localizationKey(for:))
        XCTAssertEqual(Set(mapped).count, Self.allErrors.count,
                       "two error cases were mapped to the same key")
        for language in languages {
            let landed = Set(try sourceTable(language).keys.filter { $0.hasPrefix("product.error.") })
            XCTAssertEqual(landed, Set(mapped), """
                \(language): the error copy and the error cases disagree.
                copy with no case: \(landed.subtracting(mapped).sorted())
                case with no copy: \(Set(mapped).subtracting(landed).sorted())
                """)
        }
    }

    /// The sentences a user sees must not be the machine's own words. `ProductCatalogError`
    /// carries no payload precisely so a leak is impossible in the type; this checks the copy
    /// did not re-introduce one by hand.
    func testP6bErrorCopyNeverPrintsTheCaseNameOrAMachineToken() throws {
        let machineWords = ["SQLite", "sqlite", "ProductCatalogError", "nil", "Error",
                            "code 19", "UNIQUE", "constraint"]
            + Self.allErrors.map(\.description)
        for language in languages {
            for error in Self.allErrors {
                let sentence = value(language, Self.localizationKey(for: error))
                for word in machineWords {
                    XCTAssertFalse(sentence.contains(word),
                                   "\(language)/\(error.description) copy contains “\(word)”: \(sentence)")
                }
            }
        }
    }

    // MARK: - P7 · ProductUnit, both directions

    func testP7EveryUnitHasExactlyOneLabelAndViceVersa() throws {
        XCTAssertEqual(ProductUnit.allCases.count, 11)
        for language in languages {
            let landed = Set(try sourceTable(language).keys.filter { $0.hasPrefix("product.unit.") })
            XCTAssertEqual(landed, Set(Self.unitKeys), """
                \(language): the unit copy and ProductUnit disagree.
                copy with no case: \(landed.subtracting(Self.unitKeys).sorted())
                case with no copy: \(Set(Self.unitKeys).subtracting(landed).sorted())
                """)
        }
    }

    // MARK: - P8 · the unit labels are Electron's, not a re-translation

    /// Read out of `components/accountingHelpers.ts` rather than restated. These eleven labels
    /// are what the other app has been putting on screen for these same keys; typing them again
    /// here would fork a vocabulary nothing reconciles, and the fork would show up as two apps
    /// disagreeing about what a `bag` is called in Korean.
    func testP8TheUnitLabelsMatchTheElectronTableVerbatim() throws {
        let table = try Self.electronUnitLabels()
        let localeColumn = ["zh-Hans": "zh-CN", "zh-Hant": "zh-TW",
                            "en": "en", "ja": "ja", "ko": "ko", "fr": "fr"]
        for unit in ProductUnit.allCases {
            let row = try XCTUnwrap(table[unit.rawValue],
                                    "\(unit.rawValue) is not in INVENTORY_UNIT_LABELS")
            for language in languages {
                let column = try XCTUnwrap(localeColumn[language])
                let expected = try XCTUnwrap(row[column], "\(unit.rawValue)/\(column) missing")
                XCTAssertEqual(value(language, "product.unit.\(unit.rawValue)"), expected,
                               "\(language)/product.unit.\(unit.rawValue) drifted from Electron")
            }
        }
    }

    // MARK: - P9 · nothing on one screen says the same thing twice

    func testP9NoTwoKeysInOneScreenRegionRenderTheSameLabel() {
        let buckets: [String: [String]] = [
            "list header": Self.columnKeys,
            "type cell": ["product.type.product", "product.type.service"],
            "status cell": ["product.status.active", "product.status.inactive"],
            "unit picker": Self.unitKeys,
            "page header": Self.pageKeys + Self.actionKeys,
            "form": ["product.form.newTitle", "product.col.name", "product.col.unit",
                     "product.col.cost", "product.form.namePlaceholder",
                     "product.form.isService", "product.form.isServiceHint",
                     "common.cancel", "common.save"],
            "delete dialog": Self.deleteKeys + ["common.delete", "common.cancel"],
            "empty state": Self.emptyKeys,
            "error banner": Self.errorKeys,
        ]
        for (region, keys) in buckets {
            for language in languages {
                var seen: [String: String] = [:]
                for key in keys {
                    let rendered = value(language, key)
                    if let other = seen[rendered] {
                        XCTFail("\(region)/\(language): “\(rendered)” is rendered by both \(other) and \(key)")
                    }
                    seen[rendered] = key
                }
            }
        }
    }

    // MARK: - P10 · zero banned wording, and no new sanction

    func testP10NewCopyHasZeroBannedWordingHits() throws {
        let source = try String(contentsOf: Self.guardSourceURL(), encoding: .utf8)
        let filing = try Self.patterns(inArrayNamed: "filingWords", of: source)
        let statutory = try Self.patterns(inArrayNamed: "statutoryStatementNames", of: source)
        XCTAssertEqual(filing.count, 22, "filingWords changed size — re-scan the copy")
        XCTAssertEqual(statutory.count, 21, "statutoryStatementNames changed size — re-scan the copy")

        for (label, patterns) in [("filingWords", filing), ("statutoryStatementNames", statutory)] {
            for pattern in patterns {
                let regex = try NSRegularExpression(pattern: pattern)
                for language in languages {
                    for key in Self.adjudicatedKeys {
                        let text = value(language, key)
                        let range = NSRange(text.startIndex..., in: text)
                        XCTAssertEqual(regex.numberOfMatches(in: text, range: range), 0,
                                       "\(language)/\(key) hits \(label) /\(pattern)/: \(text)")
                    }
                }
            }
        }
    }

    /// The copy earns its place without an exemption. A sanction added for a product string
    /// would mean a banned word landed and was waved through rather than rewritten.
    func testP10bTheSanctionTableDidNotGrow() throws {
        let source = try String(contentsOf: Self.guardSourceURL(), encoding: .utf8)
        XCTAssertEqual(Self.sanctionCount(of: source), 40,
                       "sanctionedUses moved; 2b-A2 adds no exemption")
    }

    // MARK: - P11 · the inventory claim is in the future tense (C13-style ratchet)

    /// Electron states that service items *are* excluded from inventory. This app has no
    /// inventory, so that sentence would be a claim it cannot keep. The retired clauses are
    /// forbidden by whole phrase; the anti-vacuity half proves they are real text over there,
    /// so the ratchet is holding something back rather than nothing.
    func testP11TheRetiredPresentTenseInventoryClaimsStayOut() throws {
        let retired = [
            "zh-Hans": ["服务类项目不参与库存统计", "不计库存"],
            "zh-Hant": ["服務類項目不參與庫存統計", "不計庫存"],
            "en": ["Service items are excluded from inventory", "not counted in inventory"],
            "ja": ["サービス項目は在庫に含まれません", "在庫対象外"],
            "ko": ["서비스 항목은 재고에 포함되지 않습니다", "재고 미포함"],
            "fr": ["Les services sont exclus du stock", "hors stock"],
        ]
        for language in languages {
            for clause in retired[language] ?? [] {
                for key in Self.adjudicatedKeys {
                    XCTAssertFalse(value(language, key).contains(clause),
                                   "\(language)/\(key) re-introduced “\(clause)”")
                }
            }
        }
    }

    func testP11bTheRetiredClausesWereRealTextInTheOtherApp() throws {
        let json = try Self.electronLocaleJSON("zh-CN")
        let products = try XCTUnwrap(json["products"] as? [String: Any])
        let subtitle = try XCTUnwrap(products["subtitle"] as? String)
        let isService = try XCTUnwrap(products["isService"] as? String)
        XCTAssertTrue(subtitle.contains("服务类项目不参与库存统计"),
                      "the clause the ratchet retires is not in Electron's copy — check the anchor")
        XCTAssertTrue(isService.contains("不计库存"),
                      "the clause the ratchet retires is not in Electron's copy — check the anchor")
    }

    /// And the replacement really does speak about the future rather than dropping the point.
    func testP11cTheServiceHintStillMakesTheInventoryPointInTheFutureTense() {
        let futureMarker = ["zh-Hans": "将来", "zh-Hant": "將來", "en": "will be",
                            "ja": "際には", "ko": "향후", "fr": "lorsque"]
        for language in languages {
            let hint = value(language, "product.form.isServiceHint")
            let marker = futureMarker[language] ?? ""
            XCTAssertTrue(hint.contains(marker),
                          "\(language) service hint lost its future tense: \(hint)")
        }
    }

    // MARK: - P12 · exactly one file names the copy

    /// 2b-A2 landed these forty strings dormant and this test asserted nobody named them. 2b-A3
    /// gives them a page, so the assertion becomes a CLOSED SET rather than an empty one: every
    /// key is named by `ProductPageComposition.swift` and by nothing else.
    ///
    /// Both directions matter. A key named nowhere is copy the page cannot reach; a key named in
    /// a second file means the page has grown a source of strings the composition does not know
    /// about, which is precisely what makes `ProductMountingTests`' placement proof meaningful.
    func testP12EveryProductKeyIsNamedByTheCompositionAndByNothingElse() throws {
        let sources = try Self.allSources()
        for key in Self.adjudicatedKeys {
            let files = Set(sources.filter { source in
                source.text.split(separator: "\n", omittingEmptySubsequences: false).contains {
                    let trimmed = $0.trimmingCharacters(in: .whitespaces)
                    return !trimmed.hasPrefix("//") && !trimmed.hasPrefix("*")
                        && !trimmed.hasPrefix("/*") && $0.contains("\"\(key)\"")
                }
            }.map(\.path))
            XCTAssertEqual(files, ["ProductPageComposition.swift"], "\(key) is named by \(files.sorted())")
        }
    }

    /// The scan is worthless if it cannot see a use, or is reading nothing.
    func testP12bTheDormancyScanReadsTheTreeAndDetectsARealUse() throws {
        let sources = try Self.allSources()
        XCTAssertGreaterThan(sources.count, 40, "the scan is not reading the tree")
        let probe = [("Probe.swift", "let t = model.t(\"product.page.title\")\n// product.col.name")]
        XCTAssertEqual(Self.mentions(of: Self.adjudicatedKeys, in: probe),
                       ["product.page.title"],
                       "a real use must be seen and a commented one must not")
    }

    // MARK: - Helpers

    /// …/native/SoloLedger/App/Tests/SoloLedgerUnitTests/<this>.swift → …/native/SoloLedger
    private static func packageRoot() -> URL {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { dir.deleteLastPathComponent() }
        return dir
    }

    /// …/native/SoloLedger → the repository root.
    private static func repositoryRoot() -> URL {
        var dir = packageRoot()
        dir.deleteLastPathComponent(); dir.deleteLastPathComponent()
        return dir
    }

    private static func sourceStringsURL(_ language: String) -> URL {
        packageRoot()
            .appendingPathComponent("Sources/SoloLedger/Resources/\(language).lproj/Localizable.strings")
    }

    private static func guardSourceURL() -> URL {
        packageRoot()
            .appendingPathComponent("Tests/SoloLedgerCoreTests/LocalizationWordingGuardTests.swift")
    }

    /// The COMMITTED `.strings` of a locale, parsed as the old-style property list it is.
    private func sourceTable(_ language: String) throws -> [String: String] {
        let data = try Data(contentsOf: Self.sourceStringsURL(language))
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return try XCTUnwrap(plist as? [String: String],
                             "\(language): Localizable.strings is not a string dictionary")
    }

    private func value(_ language: String, _ key: String) -> String {
        Localizer(language: language).t(key)
    }

    private func placeholders(in text: String) -> Set<String> {
        let regex = try! NSRegularExpression(pattern: #"\{[A-Za-z]+\}"#)
        let range = NSRange(text.startIndex..., in: text)
        return Set(regex.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        })
    }

    /// `INVENTORY_UNIT_LABELS` from `components/accountingHelpers.ts`, parsed out of the source.
    /// Skips rather than fails when the package is detached from the monorepo, matching how
    /// `SchemaVersionParityTests` treats the same situation.
    private static func electronUnitLabels() throws -> [String: [String: String]] {
        let url = repositoryRoot().appendingPathComponent("components/accountingHelpers.ts")
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("components/accountingHelpers.ts is not reachable from here")
        }
        let start = try XCTUnwrap(source.range(of: "const INVENTORY_UNIT_LABELS"),
                                  "INVENTORY_UNIT_LABELS is gone — the unit labels lost their source")
        let rest = source[start.upperBound...]
        let end = try XCTUnwrap(rest.range(of: "\n};"), "INVENTORY_UNIT_LABELS has no closing brace")
        let body = String(rest[..<end.lowerBound])

        var table: [String: [String: String]] = [:]
        let rowPattern = try NSRegularExpression(pattern: #"(\w+)\s*:\s*\{([^}]*)\}"#)
        let cellPattern = try NSRegularExpression(pattern: #"'?([\w-]+)'?\s*:\s*'([^']*)'"#)
        let bodyRange = NSRange(body.startIndex..., in: body)
        for match in rowPattern.matches(in: body, range: bodyRange) {
            guard let keyRange = Range(match.range(at: 1), in: body),
                  let cellsRange = Range(match.range(at: 2), in: body) else { continue }
            let cells = String(body[cellsRange])
            var row: [String: String] = [:]
            for cell in cellPattern.matches(in: cells, range: NSRange(cells.startIndex..., in: cells)) {
                guard let name = Range(cell.range(at: 1), in: cells),
                      let text = Range(cell.range(at: 2), in: cells) else { continue }
                row[String(cells[name])] = String(cells[text])
            }
            table[String(body[keyRange])] = row
        }
        XCTAssertGreaterThanOrEqual(table.count, 11, "parsed \(table.count) unit rows — parser drifted")
        return table
    }

    private static func electronLocaleJSON(_ locale: String) throws -> [String: Any] {
        let url = repositoryRoot().appendingPathComponent("i18n/locales/\(locale).json")
        guard let data = try? Data(contentsOf: url) else {
            throw XCTSkip("i18n/locales/\(locale).json is not reachable from here")
        }
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The patterns of one `[BannedWord]` table, read out of the guard's own source.
    private static func patterns(inArrayNamed name: String, of source: String) throws -> [String] {
        let start = try XCTUnwrap(source.range(of: "static let \(name): [BannedWord] = ["),
                                  "\(name) is no longer a [BannedWord] array in the guard")
        let rest = source[start.upperBound...]
        let end = try XCTUnwrap(rest.range(of: "\n    ]"), "\(name) has no closing bracket")
        let body = String(rest[..<end.lowerBound])
        // `##"…"##`, because the pattern itself contains `"#` — the raw-string delimiter the
        // guard uses for its own Latin patterns — and a single-hash literal would end there.
        let regex = try NSRegularExpression(pattern: ##"\.init\(pattern:\s*(#"[^"]*"#|"[^"]*")"##)
        let range = NSRange(body.startIndex..., in: body)
        return try regex.matches(in: body, range: range).map { match -> String in
            let captured = try XCTUnwrap(Range(match.range(at: 1), in: body))
            let literal = String(body[captured])
            if literal.hasPrefix("#\"") { return String(literal.dropFirst(2).dropLast(2)) }
            let plain = String(literal.dropFirst().dropLast())
            XCTAssertFalse(plain.contains("\\"),
                           "a plain literal now carries an escape — the decoder would corrupt it")
            return plain
        }
    }

    private static func sanctionCount(of source: String) -> Int {
        guard let start = source.range(of: "static let sanctionedUses: [SanctionedUse] = ["),
              let end = source.range(of: "// MARK: - The scan", range: start.upperBound..<source.endIndex)
        else { return -1 }
        return source[start.upperBound..<end.lowerBound].components(separatedBy: ".init(locale:").count - 1
    }

    /// Every `.swift` under `Sources/` — the App target and the Core library both.
    private static func allSources() throws -> [(path: String, text: String)] {
        let root = packageRoot().appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        return try files.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    /// Which of `keys` appear as a whole quoted literal in non-comment source text.
    private static func mentions(of keys: [String],
                                 in sources: [(path: String, text: String)]) -> Set<String> {
        var found: Set<String> = []
        for source in sources {
            for line in source.text.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("*"), !trimmed.hasPrefix("/*")
                else { continue }
                for key in keys where line.contains("\"\(key)\"") { found.insert(key) }
            }
        }
        return found
    }
}
