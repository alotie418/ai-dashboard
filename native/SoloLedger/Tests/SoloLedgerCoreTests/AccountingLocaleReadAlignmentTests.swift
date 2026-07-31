import XCTest
@testable import SoloLedgerCore

/// P4c-1: the `accounting_locale` row has ONE reader.
///
/// It used to have two. `SettingsStore.accountingLocale()` decoded with
/// `JSONSerialization`, which eats a leading U+FEFF; the report engines go through
/// `ReportSettings.jsonFragment`, which rejects it. On one BOM-prefixed `"US"` row the
/// Settings screen said United States while `ReportBuilder` refused the same row — measured
/// and registered for P4 by `ReportBuilderTests` and the P2 commit.
///
/// The matrix below is that registration turned into an assertion: for EVERY shape the row
/// can take, the two answers must be the same verdict. A future change to the rule that lands
/// on one reader and misses the other fails here.
final class AccountingLocaleReadAlignmentTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SLLocaleAlign-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    /// A ledger whose `accounting_locale` row holds `raw` VERBATIM (nil = no row at all).
    /// Deliberately the raw table rather than `SettingsStore.setString`, which can only
    /// produce well-formed JSON and therefore cannot express most of the matrix.
    private func ledger(_ raw: String?) throws -> LedgerStore {
        let store = try LedgerStore(databaseURL: dir.appendingPathComponent("\(UUID().uuidString).db"))
        if let raw {
            _ = try store.db.run("INSERT OR REPLACE INTO settings (key, value) VALUES ('accounting_locale', ?)",
                                 [.text(raw)])
        } else {
            _ = try store.db.run("DELETE FROM settings WHERE key = 'accounting_locale'")
        }
        return store
    }

    /// The two verdicts, reduced to the same three-way vocabulary so they can be compared.
    private enum Verdict: Equatable {
        case regime(String)
        case unreadable(storedText: String)
        case absent
    }

    private func storeVerdict(_ store: LedgerStore) throws -> Verdict {
        switch try store.settings.accountingLocaleState() {
        case .configured(let locale):        return .regime(locale.rawValue)
        case .unreadable(let storedText):    return .unreadable(storedText: storedText)
        case .absent:                        return .absent
        }
    }

    private func builderVerdict(_ store: LedgerStore) throws -> Verdict {
        // A currency row keeps the builder from stopping earlier for a different reason; the
        // regime gate runs first regardless, so this only removes noise from the failures.
        try store.settings.setString("CNY", for: SettingsStore.Key.currency)
        switch try ReportBuilder.build(store.db, period: ReportPeriod(year: "2025")) {
        case .blocked(.accountingLocaleNotConfigured):          return .absent
        case .blocked(.accountingLocaleInvalid(let storedText)): return .unreadable(storedText: storedText)
        case .blocked(.legacySourceUnavailable):
            // The regime passed and the source gate stopped it — the ledger has no rows. That
            // IS a resolved regime, so read it back the same way the builder just did.
            let raw = ReportSettings.rawValue(store.db, "accounting_locale") ?? ""
            guard let locale = ReportSettings.recognizedAccountingLocale(fromStoredText: raw) else {
                return .unreadable(storedText: raw)
            }
            return .regime(locale.rawValue)
        case .blocked(let other):
            XCTFail("unexpected blocker for a regime question: \(other)")
            return .absent
        case .report(let r):
            return .regime(r.locale)
        }
    }

    // MARK: - C1 — the matrix, as an assertion

    func testEveryStoredShapeGetsTheSameVerdictFromBothReaders() throws {
        let shapes: [(name: String, raw: String?, expected: Verdict)] = [
            ("缺行",            nil,                    .absent),
            ("合法 CN",         "\"CN\"",               .regime("CN")),
            ("合法 US",         "\"US\"",               .regime("US")),
            ("BOM + 合法 US",   "\u{FEFF}\"US\"",       .unreadable(storedText: "\u{FEFF}\"US\"")),
            ("非法字符串",       "\"FR\"",               .unreadable(storedText: "\"FR\"")),
            ("非字符串类型",     "123",                  .unreadable(storedText: "123")),
            ("布尔",            "true",                 .unreadable(storedText: "true")),
            ("空串",            "\"\"",                 .unreadable(storedText: "\"\"")),
            ("非 JSON 字节",     "US",                   .unreadable(storedText: "US")),
        ]
        for shape in shapes {
            let store = try ledger(shape.raw)
            defer { try? store.db.close() }
            let fromStore = try storeVerdict(store)
            let fromBuilder = try builderVerdict(store)
            XCTAssertEqual(fromStore, shape.expected, "\(shape.name): SettingsStore")
            XCTAssertEqual(fromBuilder, shape.expected, "\(shape.name): ReportBuilder")
            XCTAssertEqual(fromStore, fromBuilder,
                           "\(shape.name): the two readers disagree — that is the P4c defect")
        }
    }

    // MARK: - C2 — the BOM row keeps its bytes

    func testTheBOMRowIsUnreadableAndKeepsItsBytes() throws {
        let raw = "\u{FEFF}\"US\""
        let store = try ledger(raw)
        defer { try? store.db.close() }
        guard case .unreadable(let storedText) = try store.settings.accountingLocaleState() else {
            return XCTFail("a BOM-prefixed regime must be unreadable, never the United States")
        }
        XCTAssertEqual(Array(storedText.unicodeScalars.map(\.value)),
                       [0xFEFF, 0x22, 0x55, 0x53, 0x22],
                       "storedText must be exactly U+FEFF then \"US\" in quotes")
        // The divergence this whole change exists to remove, stated as its own assertion.
        XCTAssertNotEqual(try store.settings.accountingLocaleState(), .configured(.US))
    }

    // MARK: - C3 — a recognisable row is unchanged for both readers

    func testARecognisedRegimeIsUnchangedForBothReaders() throws {
        for regime in AccountingLocale.allCases {
            let store = try ledger("\"\(regime.rawValue)\"")
            defer { try? store.db.close() }
            XCTAssertEqual(try store.settings.accountingLocaleState(), .configured(regime))
            XCTAssertEqual(try store.settings.accountingLocale(), regime,
                           "the display accessor must not regress for a good row")
        }
    }

    // MARK: - C4 — the display fallback is deliberate, and it is only a display fallback

    /// `accountingLocale()` is unchanged, and this pins what it actually does — which is not
    /// one behaviour but two, and the second one is the reason this PR exists:
    ///
    ///   - a row whose text decodes but names no regime (`"FR"`, `123`, `""`, absent) falls
    ///     back to `.CN`. Deliberate: the app needs a regime to keep working, and two boot
    ///     paths treat this read as required, so making it throw would cost the user their
    ///     ledger over one damaged row;
    ///   - a BOM-prefixed `"US"` does NOT fall back. `JSONSerialization` eats the U+FEFF, so
    ///     it confidently answers **the United States** — a different country from the one the
    ///     engines refuse to assume. Pinned so the asymmetry is on the record rather than
    ///     discovered again.
    ///
    /// In both cases the state accessor declines to name a regime at all.
    func testTheDisplayAccessorIsPinnedIncludingWhereItNamesAnotherCountry() throws {
        for raw in [nil, "\"FR\"", "123", "\"\""] as [String?] {
            let store = try ledger(raw)
            defer { try? store.db.close() }
            XCTAssertEqual(try store.settings.accountingLocale(), .CN,
                           "\(raw ?? "nil"): the display fallback is deliberate")
            XCTAssertNotEqual(try store.settings.accountingLocaleState(), .configured(.CN),
                              "\(raw ?? "nil"): the state accessor must never invent China")
        }
        let bom = try ledger("\u{FEFF}\"US\"")
        defer { try? bom.db.close() }
        XCTAssertEqual(try bom.settings.accountingLocale(), .US,
                       "the display accessor still reads the BOM row as the United States")
        XCTAssertEqual(try bom.settings.accountingLocaleState(),
                       .unreadable(storedText: "\u{FEFF}\"US\""),
                       "while the state accessor refuses to name a regime for the same bytes")
    }

    // MARK: - C5 — the shared classifier is load-bearing

    /// Direct assertions on the one function both readers now call. Deleting the BOM rejection
    /// in `jsonFragment`, or widening the six-regime membership test, makes these red — and
    /// because BOTH readers go through here, it can no longer be red on one side only.
    func testTheSharedClassifierIsTheOneRule() {
        XCTAssertEqual(ReportSettings.recognizedAccountingLocale(fromStoredText: "\"US\""), .US)
        XCTAssertNil(ReportSettings.recognizedAccountingLocale(fromStoredText: "\u{FEFF}\"US\""),
                     "the BOM rule lives here now")
        XCTAssertNil(ReportSettings.recognizedAccountingLocale(fromStoredText: "\"FR\""),
                     "six regimes, no seventh")
        XCTAssertNil(ReportSettings.recognizedAccountingLocale(fromStoredText: "123"))
        XCTAssertNil(ReportSettings.recognizedAccountingLocale(fromStoredText: "true"))
        XCTAssertNil(ReportSettings.recognizedAccountingLocale(fromStoredText: "US"))
        for regime in AccountingLocale.allCases {
            XCTAssertEqual(ReportSettings.recognizedAccountingLocale(fromStoredText: "\"\(regime.rawValue)\""),
                           regime)
        }
    }
}
