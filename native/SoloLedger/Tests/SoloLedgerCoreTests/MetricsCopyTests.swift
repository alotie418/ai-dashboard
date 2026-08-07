import XCTest
@testable import SoloLedgerCore

/// The `overview.metrics.*` six-language copy — ten keys for the Overview page's
/// month-on-month / year-on-year block, landed DORMANT.
///
/// The engine is already in the tree (`MonthlyComparisons`, d1-1). This round lands only the
/// words; the composition and the view are d1-3, and MC4 asserts that nothing draws them yet.
///
/// ## The one sentence this file exists to protect
///
/// `overview.metrics.basisNote` states what these percentages are computed on, and an earlier
/// draft of it said "amounts exclude tax" — which is FALSE. Monthly revenue is
/// `ReportMath.netAmount(row.amountNet, row.amount)` (`CNReportEngine.swift:214` and its four
/// siblings, mirroring `cn.js:98`), and `netAmount` FALLS BACK to the tax-inclusive `amount`
/// whenever `amount_net` is not truthy. So the basis is per transaction, not per ledger, and the
/// sentence has to say so.
///
/// The oracle for a sentence about a calculation is the implementation, never a summary comment:
/// `_metrics.js:2` says 「按营业收入（不含税）计算」 and that summary is exactly where the false
/// claim came from.
///
/// **A degenerate edge the copy deliberately does not mention.** `ReportMath.isTruthy` is false
/// for `0` as well as for `nil`, so a transaction that records its tax-exclusive amount AS ZERO
/// also falls back to the full amount. Saying "where one was recorded" is therefore very slightly
/// generous — a recorded zero reads as not recorded. Naming that in the UI would cost a sentence
/// to describe a row that is already degenerate (a zero-net, non-zero-gross transaction), so it is
/// documented here instead.
///
/// ## Why the wording is not symmetric across the six
///
/// Traditional Chinese does not take the mainland terms 环比 / 同比 naturally, so it uses
/// 較上月 / 較去年同期 — which reads as a phrase rather than a noun, so its title, captions and
/// empty-state sentence are phrased around that instead of transliterating the other five.
///
/// Korean is the language where the house vocabulary genuinely collides: `세전` names BOTH the
/// tax-excluded amount (`editor.amountNet`) and pre-income-tax profit
/// (`legacy.convert.consequence.shipping`). The concept is therefore written `세금 제외` — the
/// inventory chapter's unambiguous rendering — and `세전 금액` appears only where the sentence
/// points at the editor field by its actual on-screen label.
final class MetricsCopyTests: XCTestCase {

    private let languages = ["zh-Hans", "zh-Hant", "en", "ja", "ko", "fr"]

    // MARK: - The adjudicated table

    private static let adjudicatedKeys = [
        "overview.metrics.title",
        "overview.metrics.revenue",
        "overview.metrics.mom",
        "overview.metrics.yoy",
        "overview.metrics.momCaption",
        "overview.metrics.yoyCaption",
        "overview.metrics.basisNote",
        "overview.metrics.noBaseNote",
        "overview.metrics.empty.title",
        "overview.metrics.empty.message",
    ]

    // MARK: - MC1 · the absolute count, and the set

    func testMC1TheNamespaceIsExactlyTenKeys() throws {
        XCTAssertEqual(Self.adjudicatedKeys.count, 10, "the adjudicated table itself must be ten")
        XCTAssertEqual(Set(Self.adjudicatedKeys).count, 10, "the adjudicated table has a duplicate")
        for language in languages {
            let landed = try sourceTable(language).keys.filter { $0.hasPrefix("overview.metrics.") }
            XCTAssertEqual(landed.count, 10, "\(language) landed \(landed.count) overview.metrics.* keys")
            XCTAssertEqual(Set(landed), Set(Self.adjudicatedKeys), """
                \(language): landed set differs from the adjudicated table.
                extra:   \(Set(landed).subtracting(Self.adjudicatedKeys).sorted())
                missing: \(Set(Self.adjudicatedKeys).subtracting(landed).sorted())
                """)
        }
    }

    /// The new prefix nests under `overview.`, which nothing counts today. Asserted rather than
    /// assumed, because the moment something does count it, this block joins that total silently.
    func testMC1bTheOverviewNamespaceHoldsBothTheOldKeysAndTheNewOnes() throws {
        for language in languages {
            let keys = try sourceTable(language).keys
            let all = keys.filter { $0.hasPrefix("overview.") }
            let block = keys.filter { $0.hasPrefix("overview.metrics.") }
            XCTAssertEqual(block.count, 10)
            XCTAssertEqual(all.count - block.count, 17,
                           "\(language): the pre-existing overview.* keys moved — was 17")
        }
    }

    // MARK: - MC2 · six identical key sets

    func testMC2TheSixLocalesAgreeOnTheKeySet() throws {
        var keySets: [Set<String>] = []
        for language in languages {
            keySets.append(Set(try sourceTable(language).keys.filter {
                $0.hasPrefix("overview.metrics.")
            }))
        }
        XCTAssertEqual(Set(keySets).count, 1,
                       "the six locales do not agree on the overview.metrics.* key set")
    }

    // MARK: - MC3 · every key resolves, everywhere

    func testMC3EveryKeyResolvesInAllSixLocales() throws {
        for language in languages {
            let table = try sourceTable(language)
            for key in Self.adjudicatedKeys {
                let resolved = try XCTUnwrap(table[key], "\(language)/\(key) is missing")
                XCTAssertNotEqual(resolved, key, "\(language)/\(key) resolved to the key itself")
                XCTAssertFalse(resolved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                               "\(language)/\(key) is blank")
            }
        }
    }

    // MARK: - MC4 · nobody draws these yet

    /// The dormancy proof, in the shape `InventoryCopyTests` IC11 uses — and with the same
    /// scanner, which reads RAW file text and does NOT skip comment lines. A key mentioned in a
    /// comment counts as a use, which is deliberate: a name written down anywhere in production is
    /// a name this round has not yet decided who owns.
    func testMC4NoProductionFileNamesTheseKeysYet() throws {
        let sources = try Self.productionSources()
        XCTAssertGreaterThan(sources.count, 40, "the scan is not reading the tree")
        var named: [String: [String]] = [:]
        for (path, text) in sources {
            for key in Self.adjudicatedKeys where text.contains("\"\(key)\"") {
                named[key, default: []].append(path)
            }
        }
        XCTAssertEqual(named, [:], """
            these keys are named in production before their composition exists: \
            \(named.keys.sorted()). The block is d1-3.
            """)
    }

    /// The dormancy scan must be able to see a real use, or an empty offender list proves nothing.
    func testMC4bTheDormancyScanDetectsARealUse() throws {
        let sources = try Self.productionSources()
        XCTAssertTrue(sources.contains { $0.text.contains("\"overview.dataSourceNote\"") },
                      "the scan cannot see a key that IS referenced in production")
    }

    // MARK: - MC5 · the banned vocabularies

    /// Read out of `LocalizationWordingGuardTests` rather than restated, so the two cannot drift:
    /// if that file grows a word, this test starts checking it on the next run.
    func testMC5NewCopyHasZeroBannedWordingHits() throws {
        let filing = LocalizationWordingGuardTests.filingWords
        let statutory = LocalizationWordingGuardTests.statutoryStatementNames
        XCTAssertEqual(filing.count, 22, "filingWords changed size — re-scan the copy")
        XCTAssertEqual(statutory.count, 21, "statutoryStatementNames changed size — re-scan the copy")

        for language in languages {
            let table = try sourceTable(language)
            for key in Self.adjudicatedKeys {
                let text = try XCTUnwrap(table[key])
                for banned in filing + statutory {
                    XCTAssertNil(text.range(of: banned.pattern, options: .regularExpression),
                                 "\(language)/\(key) carries the banned wording “\(banned.label)”")
                }
            }
        }
    }

    // MARK: - MC6 · no placeholders at all

    /// None of the ten interpolates anything. Stated as a contract rather than left implicit: a
    /// later round that adds a `{count}` has to come here and say so, which is where someone will
    /// notice that a count in a sentence needs an oracle.
    func testMC6NoKeyCarriesAPlaceholder() throws {
        for language in languages {
            let table = try sourceTable(language)
            for key in Self.adjudicatedKeys {
                let text = try XCTUnwrap(table[key])
                XCTAssertNil(text.range(of: #"\{[a-zA-Z]+\}"#, options: .regularExpression),
                             "\(language)/\(key) carries a placeholder")
            }
        }
    }

    // MARK: - MC7 · the two sentences that make a claim, and their oracles

    /// `noBaseNote` promises the block never prints `0.0%`. The engine is what keeps that promise.
    func testMC7TheNoBasePromiseMatchesTheEngine() throws {
        // The promise, restated against the engine that has to keep it.
        XCTAssertNil(MonthlyComparisons.pct(100, 0), "a zero base must be nil, never 0")
        XCTAssertNil(MonthlyComparisons.pct(100, nil), "a missing base must be nil, never 0")

        // And the sentence really does make that promise, in every language: each one names the
        // one-decimal zero it refuses to print.
        for language in languages {
            let text = try XCTUnwrap(sourceTable(language)["overview.metrics.noBaseNote"])
            let zero = language == "fr" ? "0,0" : "0.0"
            XCTAssertTrue(text.contains(zero),
                          "\(language): the sentence must name the value it refuses to show")
        }
    }

    /// `empty.message` promises month-on-month needs at least two months. The engine's first row
    /// is unconditionally `nil`, which is exactly that claim.
    func testMC7bTheTwoMonthClaimMatchesTheEngine() {
        let one = MonthlyComparisons.compute([.init(revenue: 100, salesTons: 0)])
        XCTAssertNil(one[0].mom, "one month can have no month-on-month")
        let two = MonthlyComparisons.compute([.init(revenue: 100, salesTons: 0),
                                              .init(revenue: 120, salesTons: 0)])
        XCTAssertNil(two[0].mom)
        XCTAssertEqual(two[1].mom, 20, "the second month is the first that can have one")
    }

    /// `basisNote` describes a FALLBACK, and the fallback is `ReportMath.netAmount`. If that
    /// function ever stops falling back, this sentence becomes wrong in the other direction.
    func testMC7cTheBasisSentenceMatchesTheAmountItDescribes() throws {
        // Recorded tax-exclusive amount wins…
        XCTAssertEqual(ReportMath.netAmount(90, 100), 90)
        // …and where there is none, the full amount is used. This is what the sentence says.
        XCTAssertEqual(ReportMath.netAmount(nil, 100), 100)
        // The degenerate edge the copy does not mention: a RECORDED zero also falls back.
        XCTAssertEqual(ReportMath.netAmount(0, 100), 100)

        // Each language points at the editor field by its real on-screen label, so a user can act
        // on the advice. A mismatch here means the sentence names a control that does not exist.
        let editorLabels = ["zh-Hans": "不含税金额", "zh-Hant": "不含稅金額", "en": "Amount (excl. tax)",
                            "ja": "税抜金額", "ko": "세전 금액", "fr": "Montant HT"]
        for language in languages {
            let table = try sourceTable(language)
            let note = try XCTUnwrap(table["overview.metrics.basisNote"])
            let label = try XCTUnwrap(table["editor.amountNet"])
            XCTAssertEqual(label, editorLabels[language], "\(language): the editor's label moved")
            XCTAssertTrue(note.contains(label),
                          "\(language): the basis note must name the field by its real label")
        }
    }

    /// Korean says the CONCEPT one way and names the FIELD another, because `세전` is overloaded.
    func testMC7dKoreanKeepsTheConceptAndTheFieldLabelApart() throws {
        let note = try XCTUnwrap(sourceTable("ko")["overview.metrics.basisNote"])
        XCTAssertTrue(note.contains("세금 제외"), "the concept must use the unambiguous rendering")
        XCTAssertTrue(note.contains("「세전 금액」"), "the field is named by its on-screen label")
        for key in Self.adjudicatedKeys where key != "overview.metrics.basisNote" {
            let text = try XCTUnwrap(sourceTable("ko")[key])
            XCTAssertFalse(text.contains("세전"),
                           "ko/\(key): 세전 also names pre-income-tax profit — use 세금 제외")
        }
    }

    // MARK: - Helpers

    /// Read one locale's `.strings` from SOURCE. The bundle would resolve a missing key through
    /// the fallback chain and hide it behind zh-Hans.
    private func sourceTable(_ language: String) throws -> [String: String] {
        let url = Self.packageRoot()
            .appendingPathComponent("Sources/SoloLedger/Resources/\(language).lproj/Localizable.strings")
        let text = try String(contentsOf: url, encoding: .utf8)
        var out: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\""), trimmed.hasSuffix("\";") else { continue }
            let body = trimmed.dropFirst().dropLast(2)
            guard let split = body.range(of: "\" = \"") else { continue }
            out[String(body[body.startIndex..<split.lowerBound])] = String(body[split.upperBound...])
        }
        return out
    }

    private static func productionSources() throws -> [(path: String, text: String)] {
        let root = packageRoot().appendingPathComponent("Sources")
        guard let walker = FileManager.default.enumerator(atPath: root.path) else {
            XCTFail("cannot enumerate \(root.path)"); return []
        }
        var out: [(String, String)] = []
        for case let relative as String in walker where relative.hasSuffix(".swift") {
            guard let text = try? String(contentsOf: root.appendingPathComponent(relative),
                                         encoding: .utf8) else {
                XCTFail("cannot read \(relative)"); continue
            }
            out.append((relative, text))
        }
        return out
    }

    /// …/native/SoloLedger/Tests/SoloLedgerCoreTests/<this>.swift → …/native/SoloLedger
    private static func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
}
