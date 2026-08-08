import XCTest
@testable import SoloLedgerCore

/// The `overview.metrics.*` six-language copy — eleven keys for the Overview page's
/// month-on-month / year-on-year block.
///
/// The engine landed first (`MonthlyComparisons`, d1-1) and the words second (d1-2, dormant).
/// The composition and the view are d1-3, which added the eleventh key and turned MC4 from
/// "nobody draws these" into "exactly one file does".
///
/// ## The sentences this file exists to protect
///
/// The basis notes state what these percentages are computed on, and an earlier draft said
/// "amounts exclude tax" — which is FALSE. In the five VAT regimes monthly revenue is
/// `ReportMath.netAmount(row.amountNet, row.amount)` (`CNReportEngine.monthlyBreakdown` and its
/// four siblings), and that helper FALLS BACK to the tax-inclusive `amount` whenever
/// `amount_net` is not truthy. So the basis is per transaction, not per ledger, and the sentence
/// has to say so.
///
/// **And there is a sixth engine.** `USReportEngine.monthlyBreakdown` sums the full recorded
/// amount and never calls that helper at all, because Schedule C works in gross receipts
/// throughout. One sentence therefore cannot be true for all six regimes, which is why d1-3
/// added `overview.metrics.basisNoteUS` and a dispatch to choose between them.
///
/// The oracle for a sentence about a calculation is the implementation, never a summary comment:
/// `_metrics.js` opens by saying 「按营业收入（不含税）计算」 and that summary is exactly where
/// the false claim came from. The narrower lesson is d1-3's, and it is in MC7c: pinning the
/// sentence to the shared HELPER passed while the sentence was still wrong for a US ledger,
/// because which engine runs decides whether the helper is reached. The oracle has to be the
/// dispatch, not the function.
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
        "overview.metrics.basisNoteUS",
        "overview.metrics.noBaseNote",
        "overview.metrics.empty.title",
        "overview.metrics.empty.message",
    ]

    // MARK: - MC1 · the absolute count, and the set

    func testMC1TheNamespaceIsExactlyElevenKeys() throws {
        XCTAssertEqual(Self.adjudicatedKeys.count, 11, "the adjudicated table itself must be eleven")
        XCTAssertEqual(Set(Self.adjudicatedKeys).count, 11, "the adjudicated table has a duplicate")
        for language in languages {
            let landed = try sourceTable(language).keys.filter { $0.hasPrefix("overview.metrics.") }
            XCTAssertEqual(landed.count, 11, "\(language) landed \(landed.count) overview.metrics.* keys")
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
            XCTAssertEqual(block.count, 11)
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

    // MARK: - MC4 · exactly one file names them

    /// The ownership proof, in the shape `InventoryCopyTests` IC11 uses — and with the same
    /// scanner, which reads RAW file text and does NOT skip comment lines. A key mentioned in a
    /// comment counts as a use, which is deliberate: a name written down anywhere in production
    /// is a name with an owner, and this block has exactly one owner.
    ///
    /// This replaces the DORMANCY form the copy round shipped, whose answer was "no file at
    /// all". The answer is now "one file, the same one, for every key" — a closed set rather
    /// than an empty one, so a key that leaks into the view fails here instead of quietly
    /// acquiring a second drawing site. It is also why the view draws the month heading from a
    /// literal of its own: that key belongs to the chart, is outside this prefix, and is not
    /// claimed here.
    ///
    /// Sorted before comparing. `FileManager`'s enumerator has no defined order, and an
    /// unsorted list compared against a multi-element expectation passes or fails by luck.
    func testMC4TheCompositionIsTheOnlyFileThatNamesTheseKeys() throws {
        let sources = try Self.productionSources()
        XCTAssertGreaterThan(sources.count, 40, "the scan is not reading the tree")
        var named: [String: [String]] = [:]
        for (path, text) in sources {
            for key in Self.adjudicatedKeys where text.contains("\"\(key)\"") {
                named[key, default: []].append(path)
            }
        }
        let expected = Dictionary(uniqueKeysWithValues:
            Self.adjudicatedKeys.map { ($0, [Self.compositionPath]) })
        XCTAssertEqual(named.mapValues { $0.sorted() }, expected, """
            every one of these keys must be named by \(Self.compositionPath) and by nothing \
            else. Named nowhere: \(Self.adjudicatedKeys.filter { named[$0] == nil }.sorted()).
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

    /// `empty.message` states two necessary conditions and one consequence. All three are checked
    /// here AT THE SHAPE THE BLOCK ACTUALLY PRODUCES — twelve rows, always.
    ///
    /// ## Why the shape is the whole point
    ///
    /// The sentence this replaces promised "at least two months of transactions", and the oracle
    /// that passed it drove the engine with a one-row and a two-row array. Both are true
    /// statements about the engine's array semantics and neither is a shape this block can hand
    /// it: the report's monthly breakdown is twelve calendar months whatever the ledger holds. A
    /// walkthrough on a ledger with twelve months of EXPENSES showed the empty state with
    /// "Entries: 12" on the same screen, telling a user who had twelve months of transactions
    /// that he needed two.
    ///
    /// So the oracle is now written over twelve-row years, and the quantity it talks about is
    /// revenue rather than transactions — because revenue is what the engine compares.
    func testMC7bTheEmptyStateSentenceMatchesTheEngineAtTheBlocksOwnShape() throws {
        func year(_ revenue: [Double]) -> [MonthlyComparisons.Row] {
            XCTAssertEqual(revenue.count, 12, "the block never hands the engine another length")
            return revenue.map { .init(revenue: $0) }
        }
        let noPriorYear = [Double?](repeating: nil, count: 12)

        // Claim 1 — month on month needs THE MONTH BEFORE IT to have revenue.
        var marchOnly = [Double](repeating: 0, count: 12)
        marchOnly[2] = 300
        let one = MonthlyComparisons.compute(year(marchOnly), priorRevenue: noPriorYear)
        XCTAssertNil(one[2].mom, "March's own base is a revenue-free February")
        XCTAssertEqual(one[3].mom, -100, "April compares — the month before it had revenue")

        // Claim 2 — year on year needs THE SAME MONTH LAST YEAR to have revenue.
        var lastMarch = [Double?](repeating: nil, count: 12)
        lastMarch[2] = 200
        let two = MonthlyComparisons.compute(year(marchOnly), priorRevenue: lastMarch)
        XCTAssertEqual(two[2].yoy, 50, "March has last March to compare against")
        XCTAssertNil(two[1].yoy, "February has no last February")

        // Claim 3 — a ledger with expenses only produces neither. This IS the empty state.
        let expensesOnly = MonthlyComparisons.compute(year(Array(repeating: 0, count: 12)),
                                                      priorRevenue: noPriorYear)
        XCTAssertEqual(expensesOnly.count, 12)
        XCTAssertTrue(expensesOnly.allSatisfy { $0.mom == nil && $0.yoy == nil },
                      "no revenue in any month means nothing to compare, in either direction")

        // And the sentence must not grow a month COUNT back. Each language's old threshold is
        // banned by name — a targeted guard for a wording defect that reached a user's screen.
        let retiredThresholds = ["en": "two months", "zh-Hans": "两个月", "zh-Hant": "兩個月",
                                 "ja": "2 か月分", "ko": "두 달치", "fr": "deux mois"]
        for language in languages {
            let message = try XCTUnwrap(sourceTable(language)["overview.metrics.empty.message"])
            let retired = try XCTUnwrap(retiredThresholds[language])
            XCTAssertFalse(message.contains(retired), """
                \(language): the empty-state sentence is back to counting months. The condition \
                is about REVENUE in specific months, and a ledger can satisfy any month count \
                while producing none.
                """)
        }
    }

    /// The basis sentences are answerable to the ENGINE that produces the figures, not to the
    /// helper the engines share.
    ///
    /// The copy round pinned its one sentence to `ReportMath.netAmount` and that check passed,
    /// because the sentence really does describe that function. It was still the wrong sentence
    /// for a US ledger — the US engine never calls it, and a check aimed at the helper cannot
    /// see which engine runs. So the oracle here is the dispatch: ONE ledger whose rows record a
    /// tax-exclusive amount DIFFERENT from the full one, driven through both regimes, with each
    /// sentence held against the engine that would state it.
    ///
    /// The two sums must differ, or the test would pass with the engines swapped.
    func testMC7cTheBasisSentencesMatchTheEnginesThatProduceThem() throws {
        let gross = 113.0, net = 100.0
        XCTAssertNotEqual(gross, net, "the fixture cannot tell the two bases apart")
        let db = try makeTwoBasisLedger(gross: gross, net: net, month: "2025-03")

        // A VAT regime takes the recorded tax-exclusive amount…
        XCTAssertEqual(try monthlyRevenue(db, locale: "CN", year: "2025", month: 3), net,
                       accuracy: 0.000_001,
                       "a VAT engine must sum the tax-exclusive amount where one was recorded")
        // …and the US regime takes the full recorded amount, always.
        XCTAssertEqual(try monthlyRevenue(db, locale: "US", year: "2025", month: 3), gross,
                       accuracy: 0.000_001,
                       "the US engine sums the full recorded amount and never the net one")

        // The fallback the VAT sentence describes, on the same engine: no recorded net amount
        // means the full amount is used…
        let fallback = try makeTwoBasisLedger(gross: gross, net: nil, month: "2025-03")
        XCTAssertEqual(try monthlyRevenue(fallback, locale: "CN", year: "2025", month: 3), gross,
                       accuracy: 0.000_001, "no recorded net amount must fall back to the full one")
        // …and so does a recorded ZERO, the degenerate edge the copy deliberately does not name.
        let zeroNet = try makeTwoBasisLedger(gross: gross, net: 0, month: "2025-03")
        XCTAssertEqual(try monthlyRevenue(zeroNet, locale: "CN", year: "2025", month: 3), gross,
                       accuracy: 0.000_001, "a recorded zero reads as not recorded, and falls back")

        // Each VAT-regime sentence points at the editor field by its real on-screen label, so a
        // user can act on the advice. A mismatch means the sentence names a control that does
        // not exist. The US sentence names the same field — to say it is NOT read — so the same
        // label has to be right there too.
        let editorLabels = ["zh-Hans": "不含税金额", "zh-Hant": "不含稅金額", "en": "Amount (excl. tax)",
                            "ja": "税抜金額", "ko": "세전 금액", "fr": "Montant HT"]
        for language in languages {
            let table = try sourceTable(language)
            let label = try XCTUnwrap(table["editor.amountNet"])
            XCTAssertEqual(label, editorLabels[language], "\(language): the editor's label moved")
            for key in ["overview.metrics.basisNote", "overview.metrics.basisNoteUS"] {
                let note = try XCTUnwrap(table[key])
                XCTAssertTrue(note.contains(label),
                              "\(language)/\(key): must name the field by its real label")
            }
        }
    }

    // MARK: - MC8 · the block states the sentence that is true for the ledger in front of it

    /// The regime dispatch lives in the App target, which this SwiftPM test target cannot link.
    /// It is therefore read out of the composition's SOURCE — weaker than calling the function,
    /// and the strongest thing available from here. It is not nothing: the extractor is proved
    /// on synthetic text in both directions below, so "found no mapping" and "cannot see the
    /// mapping" do not look the same.
    func testMC8TheCompositionDispatchesTheBasisSentenceByRegime() throws {
        let body = try Self.functionBody(named: "basisNoteKey", in: Self.compositionSource())

        let usArm = try XCTUnwrap(body.range(of: "case .US:"), "no US arm in the dispatch")
        let vatArm = try XCTUnwrap(body.range(of: "case .CN, .JP, .EU, .KR, .TW:"),
                                   "the other five regimes must share one arm")
        XCTAssertLessThan(usArm.lowerBound, vatArm.lowerBound)
        let us = String(body[usArm.upperBound..<vatArm.lowerBound])
        let vat = String(body[vatArm.upperBound...])

        // `"…basisNote"` is not a substring of `"…basisNoteUS"`: the closing quote separates them.
        XCTAssertTrue(us.contains("\"overview.metrics.basisNoteUS\""), "US must state the US sentence")
        XCTAssertFalse(us.contains("\"overview.metrics.basisNote\""), "US must not state the VAT one")
        XCTAssertTrue(vat.contains("\"overview.metrics.basisNote\""), "the five must state the VAT one")
        XCTAssertFalse(vat.contains("\"overview.metrics.basisNoteUS\""), "the five must not state the US one")

        // Exhaustive, and asserted to be: a `default` would let a seventh regime inherit a
        // sentence that may not describe its engine, silently.
        XCTAssertFalse(body.contains("default:"), "the dispatch must be exhaustive, not defaulted")
        for regime in AccountingLocale.allCases {
            XCTAssertTrue(body.contains(".\(regime.rawValue)"), "\(regime.rawValue) is not dispatched")
        }
        XCTAssertEqual(AccountingLocale.allCases.count, 6, "a regime was added or removed")

        // The extractor, proved both ways.
        XCTAssertEqual(try Self.functionBody(named: "probe", in: "func probe() -> Int { 1 }"), " 1 ")
        XCTAssertThrowsError(try Self.functionBody(named: "absent", in: "func probe() {}"))
    }

    /// Korean says the CONCEPT one way and names the FIELD another, because `세전` is overloaded.
    ///
    /// Both basis sentences may use `세전`, and only as the editor's on-screen label. The US one
    /// names that field in order to say it is NOT read, which is the same kind of pointing at a
    /// real control — so the licence is the SHAPE, not the key: every `세전` in either sentence
    /// has to sit inside `「세전 금액」`, and the check is written by deleting that label and
    /// requiring nothing to be left.
    ///
    /// The concept word belongs only to the VAT sentence: the US one has no tax-exclusive
    /// figure to talk about.
    func testMC7dKoreanKeepsTheConceptAndTheFieldLabelApart() throws {
        let table = try sourceTable("ko")
        let basisKeys = ["overview.metrics.basisNote", "overview.metrics.basisNoteUS"]

        let vat = try XCTUnwrap(table["overview.metrics.basisNote"])
        XCTAssertTrue(vat.contains("세금 제외"), "the concept must use the unambiguous rendering")

        for key in basisKeys {
            let text = try XCTUnwrap(table[key])
            XCTAssertTrue(text.contains("「세전 금액」"),
                          "ko/\(key): the field is named by its on-screen label")
            XCTAssertFalse(text.replacingOccurrences(of: "「세전 금액」", with: "").contains("세전"),
                           "ko/\(key): 세전 outside the field label also names pre-income-tax profit")
        }
        for key in Self.adjudicatedKeys where !basisKeys.contains(key) {
            let text = try XCTUnwrap(table[key])
            XCTAssertFalse(text.contains("세전"),
                           "ko/\(key): 세전 also names pre-income-tax profit — use 세금 제외")
        }
    }

    // MARK: - Ledger fixtures (MC7c)

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("MetricsCopyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        scratch = nil
    }

    /// One income row whose full and tax-exclusive amounts differ, in one month. The regime is
    /// NOT stored: each build passes its own, which is what lets one ledger answer for two.
    private func makeTwoBasisLedger(gross: Double, net: Double?, month: String) throws -> SQLiteDatabase {
        let db = try SQLiteDatabase(path: scratch
            .appendingPathComponent("\(UUID().uuidString).db").path)
        try db.execute("""
            CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at TEXT);
            CREATE TABLE transactions (
              id TEXT PRIMARY KEY, type TEXT, date TEXT, amount REAL, amount_net REAL,
              tax_amount REAL, category_id TEXT, currency TEXT NOT NULL DEFAULT 'USD',
              payment_status TEXT, paid_amount REAL, payment_date TEXT);
            """)
        _ = try db.run("INSERT INTO settings (key, value, updated_at) VALUES ('currency', ?, '')",
                       [.text("\"USD\"")])
        _ = try db.run("""
            INSERT INTO transactions (id, type, date, amount, amount_net, tax_amount,
                                      category_id, currency, payment_status, paid_amount, payment_date)
            VALUES (?, 'income', ?, ?, ?, 0, NULL, 'USD', 'paid', ?, NULL)
            """, [.text(UUID().uuidString), .text("\(month)-15"), .real(gross),
                  net.map { SQLiteValue.real($0) } ?? .null, .real(gross)])
        return db
    }

    /// One month's revenue as the engine for `locale` computes it, through the public shape the
    /// Overview block reads — so this measures the same value the block would show.
    private func monthlyRevenue(_ db: SQLiteDatabase, locale: String,
                                year: String, month: Int) throws -> Double {
        let outcome = try ReportBuilder.build(db, locale: locale, period: ReportPeriod(year: year))
        guard case .report(let report) = outcome else {
            XCTFail("expected a report for \(locale), got \(outcome)")
            throw XCTSkip("no report")
        }
        let row = try XCTUnwrap(report.monthlyBreakdown.first { $0.month == month })
        guard case .amount(let value) = row.revenue else {
            XCTFail("month \(month) revenue is not an amount: \(row.revenue)")
            throw XCTSkip("unclassified")
        }
        return value
    }

    // MARK: - Helpers

    /// The one production file allowed to name this block's keys, spelled the way
    /// ``productionSources()`` reports a path.
    private static let compositionPath = "SoloLedger/App/OverviewPageComposition.swift"

    private static func compositionSource() throws -> String {
        try String(contentsOf: packageRoot().appendingPathComponent("Sources/\(compositionPath)"),
                   encoding: .utf8)
    }

    private struct MissingFunction: Error { let name: String }

    /// The text between a named function's braces, by brace matching from its declaration.
    private static func functionBody(named name: String, in source: String) throws -> String {
        guard let decl = source.range(of: "func \(name)"),
              let open = source[decl.upperBound...].firstIndex(of: "{") else {
            throw MissingFunction(name: name)
        }
        var depth = 0
        var index = open
        while index < source.endIndex {
            if source[index] == "{" { depth += 1 }
            if source[index] == "}" {
                depth -= 1
                if depth == 0 { return String(source[source.index(after: open)..<index]) }
            }
            index = source.index(after: index)
        }
        throw MissingFunction(name: name)
    }

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
