import XCTest
@testable import SoloLedgerCore

/// P4d: the four report-parameter rows have ONE reader for "is this a usable setting".
///
/// They had two. `SettingsStore.number` decodes leniently with `JSONSerialization`; the report
/// side judges every one of the four with `ReportSettings.classifyRate`. On one row the two
/// answered different NUMBERS — a `U+FEFF`-prefixed `5000` reads as 5000 through the lenient
/// path and reached the engines as 0 — and on every other damaged shape the lenient path
/// answered `nil`, which the Settings screen renders identically to a row that is not there.
/// Measured and registered for P4 by `ReportParameterMatrixTests` and the P2 commit.
///
/// The engines are NOT touched here. `classifyRate` and `ReportSettings.number` are frozen by
/// the goldens and by `js-settings-coercion.json`; the alignment runs the other way, with
/// `SettingsStore` gaining a strict accessor beside the lenient one.
final class ParameterReadAlignmentTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SLParamAlign-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    /// A ledger whose row for `field` holds `raw` VERBATIM (nil = no row at all). Written
    /// straight to the table: `setNumber` can only produce well-formed JSON and therefore
    /// cannot express most of the matrix.
    private func ledger(_ field: ReportParameterField, _ raw: String?) throws -> LedgerStore {
        let store = try LedgerStore(databaseURL: dir.appendingPathComponent("\(UUID().uuidString).db"))
        if let raw {
            _ = try store.db.run("INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)",
                                 [.text(field.settingsKey), .text(raw)])
        } else {
            _ = try store.db.run("DELETE FROM settings WHERE key = ?", [.text(field.settingsKey)])
        }
        return store
    }

    /// What the REPORT side says about the same row, taken from the built report's parameter
    /// table — not from a second hand-written rule.
    private func reportSideStored(_ store: LedgerStore,
                                  _ key: ReportParameterKey) throws -> StoredSettingState {
        try store.settings.setString("CNY", for: SettingsStore.Key.currency)
        try store.create(Transaction(type: .income, date: "2025-03-01", amount: 1_000, currency: "CNY"))
        guard case .report(let report) = try ReportBuilder.build(store.db,
                                                                 period: ReportPeriod(year: "2025")),
              let parameter = report.parameters.first(where: { $0.key == key })
        else {
            XCTFail("the fixture must produce a report carrying \(key)")
            throw XCTSkip("no report")
        }
        return parameter.stored
    }

    private func field(for key: ReportParameterKey) -> ReportParameterField {
        switch key {
        case .vatRate:            return .vatRate
        case .surchargeRate:      return .surchargeRate
        case .incomeTaxRate:      return .incomeTaxRate
        case .adminExpenseAnnual: return .adminExpenseAnnual
        }
    }

    /// Every shape the matrix covers. `expected` is the verdict BOTH readers must reach.
    private static let shapes: [(name: String, raw: String?, expected: StoredSettingState)] = [
        ("缺行",              nil,            .absent),
        ("合法数值",           "5000",         .usable(5000)),
        ("JSON 串数字",        "\"5000\"",     .usable(5000)),
        ("带空格的串",         "\" 5000 \"",   .usable(5000)),
        ("十六进制串",         "\"0x1388\"",   .usable(5000)),
        ("BOM 前缀",           "\u{FEFF}5000", .needsRepair(storedText: "\u{FEFF}5000")),
        ("裸文本",             "5000元",        .needsRepair(storedText: "5000元")),
        ("裸 abc",            "abc",          .needsRepair(storedText: "abc")),
        ("裸 Infinity",       "Infinity",     .needsRepair(storedText: "Infinity")),
        ("裸 1e999",          "1e999",        .needsRepair(storedText: "1e999")),
        ("JSON 空串",          "\"\"",         .needsRepair(storedText: "\"\"")),
        ("布尔",              "true",         .needsRepair(storedText: "true")),
        ("数组",              "[5000]",       .needsRepair(storedText: "[5000]")),
        ("对象",              "{}",           .needsRepair(storedText: "{}")),
        ("JSON 串非数字",      "\"5000元\"",    .needsRepair(storedText: "\"5000元\"")),
        ("百分号串",           "\"13%\"",      .needsRepair(storedText: "\"13%\"")),
    ]

    // MARK: - N1 — the matrix, as an assertion

    func testEveryStoredShapeGetsTheSameVerdictFromBothReaders() throws {
        for key in ReportParameterKey.allCases {
            for shape in Self.shapes {
                let f = field(for: key)
                let store = try ledger(f, shape.raw)
                defer { try? store.db.close() }
                XCTAssertEqual(try store.settings.reportParameterState(f), shape.expected,
                               "\(key.rawValue) / \(shape.name): SettingsStore")
                XCTAssertEqual(try reportSideStored(store, key), shape.expected,
                               "\(key.rawValue) / \(shape.name): the report's parameter table")
            }
        }
    }

    // MARK: - N2 — the BOM row keeps its bytes

    func testTheBOMRowIsNeedsRepairAndKeepsItsBytes() throws {
        let store = try ledger(.adminExpenseAnnual, "\u{FEFF}5000")
        defer { try? store.db.close() }
        guard case .needsRepair(let storedText) = try store.settings
            .reportParameterState(.adminExpenseAnnual) else {
            return XCTFail("a BOM-prefixed number is not a usable setting")
        }
        XCTAssertEqual(Array(storedText.unicodeScalars.map(\.value)),
                       [0xFEFF, 0x35, 0x30, 0x30, 0x30],
                       "storedText must be exactly U+FEFF then 5000")
    }

    // MARK: - N3 — a sound row is unchanged for both readers

    func testASoundRowIsUnchangedForBothReaders() throws {
        for f in ReportParameterField.allCases {
            let store = try ledger(f, "25")
            defer { try? store.db.close() }
            XCTAssertEqual(try store.settings.reportParameterState(f), .usable(25))
            XCTAssertEqual(try store.settings.number(f.settingsKey), 25,
                           "the lenient accessor must not regress for a good row")
        }
    }

    // MARK: - N4 — the lenient reader's two answers, pinned as deliberate

    /// `number(_:)` is unchanged, and this records what it actually does — which is not one
    /// behaviour but two, and the second is why P4d exists:
    ///
    ///   - for a damaged row it answers `nil`, indistinguishable from an absent row;
    ///   - for a BOM-prefixed number it answers the NUMBER, which the engines did not use.
    ///
    /// Both are pinned so nobody "tidies" the lenient accessor without deciding to, and so the
    /// asymmetry is on the record rather than discovered again.
    func testTheLenientReaderIsPinnedIncludingWhereItAnswersANumberTheEnginesDidNotUse() throws {
        for raw in ["5000元", "abc", "\"\"", "true", "[5000]", "{}", "\"13%\"", "1e999"] {
            let store = try ledger(.adminExpenseAnnual, raw)
            defer { try? store.db.close() }
            XCTAssertNil(try store.settings.number(SettingsStore.Key.adminExpenseAnnual),
                         "\(raw): the lenient read collapses damaged into nil")
            XCTAssertNotEqual(try store.settings.reportParameterState(.adminExpenseAnnual), .absent,
                              "\(raw): the strict read must not repeat that collapse")
        }
        let bom = try ledger(.adminExpenseAnnual, "\u{FEFF}5000")
        defer { try? bom.db.close() }
        XCTAssertEqual(try bom.settings.number(SettingsStore.Key.adminExpenseAnnual), 5000,
                       "the lenient read still answers 5000 for the BOM row")
        XCTAssertEqual(ReportSettings.number(bom.db, "admin_expense_annual", fallback: 0), 0,
                       "while the engines subtracted 0 from the same row")
    }

    // MARK: - N5 — the shared classifier is load-bearing

    /// Direct assertions on the one rule both readers now go through. Deleting the empty-string
    /// guard or the BOM rejection inside `classifyRate` / `jsonFragment` makes these red — and
    /// because BOTH readers go through it, it can no longer be red on one side only.
    func testTheSharedClassifierIsTheOneRule() {
        XCTAssertEqual(ReportSettings.classifyRate("5000"), .configured(5000))
        XCTAssertEqual(ReportSettings.classifyRate("\"0x1388\""), .configured(5000))
        XCTAssertEqual(ReportSettings.classifyRate("\u{FEFF}5000"),
                       .needsRepair(rawValue: "\u{FEFF}5000"), "the BOM rule lives here")
        XCTAssertEqual(ReportSettings.classifyRate("\"\""), .needsRepair(rawValue: "\"\""),
                       "an empty string must not read as a deliberate 0")
        XCTAssertEqual(ReportSettings.classifyRate("true"), .needsRepair(rawValue: "true"))
        XCTAssertEqual(ReportSettings.classifyRate("[5000]"), .needsRepair(rawValue: "[5000]"))
    }

    // MARK: - N6 — the hexadecimal string, measured on both sides

    /// `"0x1388"` was the one shape whose two answers could not be derived from the source with
    /// confidence: JS `Number("0x1388")` is 5000, and Swift's `Double(String)` accepts hex
    /// without a `p` exponent — but that had to be measured rather than assumed. Both give
    /// 5000, so this row is NOT a divergence. Pinned because the next person will wonder too.
    func testTheHexadecimalStringAgreesOnBothSides() throws {
        XCTAssertEqual(Double("0x1388"), 5000, "Swift's own parser accepts hex without an exponent")
        let store = try ledger(.adminExpenseAnnual, "\"0x1388\"")
        defer { try? store.db.close() }
        XCTAssertEqual(try store.settings.number(SettingsStore.Key.adminExpenseAnnual), 5000)
        XCTAssertEqual(try store.settings.reportParameterState(.adminExpenseAnnual), .usable(5000))
        XCTAssertEqual(ReportSettings.number(store.db, "admin_expense_annual", fallback: 0), 5000)
    }
}
