import XCTest
import SoloLedgerCore

/// Xcode Unit-Test target. Exercises the local `SoloLedgerCore` package through
/// its PUBLIC API only (no `@testable`), so it links the same library the app
/// links. The exhaustive suite lives in the SwiftPM package
/// (`Tests/SoloLedgerCoreTests`, run via `swift test`); this verifies the Xcode
/// test action wires up and the Core works when linked into the app project.
final class AppUnitTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SLXcodeTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    private func makeStore() throws -> LedgerStore {
        // Unique file per call so two stores in one test are genuinely separate DBs.
        try LedgerStore(databaseURL: tempDir.appendingPathComponent("\(UUID().uuidString).db"))
    }

    func testSchemaAndSeed() throws {
        let store = try makeStore()
        XCTAssertEqual(try store.schemaVersion(), SchemaMigrator.schemaVersion)
        XCTAssertEqual(try store.categories(locale: .CN).count, 9)
        XCTAssertEqual(CategorySeed.all.count, 78)
    }

    func testCrudAndSummary() throws {
        let store = try makeStore()
        try store.create(Transaction(type: .income, date: "2026-01-01", amount: 1000, currency: "CNY"))
        try store.create(Transaction(type: .expense, date: "2026-01-02", amount: 300, currency: "CNY"))
        let summary = try store.summary()
        XCTAssertEqual(summary.incomeTotal, 1000)
        XCTAssertEqual(summary.expenseTotal, 300)
        XCTAssertEqual(summary.net, 700)
        XCTAssertEqual(try store.listTransactions().count, 2)
    }

    func testCSVRoundTrip() throws {
        let store = try makeStore()
        try store.create(Transaction(type: .income, date: "2026-01-01", amount: 500, currency: "CNY", counterparty: "Doe, Inc"))
        let csv = try store.exportTransactionsCSV()
        XCTAssertTrue(csv.hasPrefix("\u{FEFF}"))
        let store2 = try makeStore()
        let result = try store2.importTransactionsCSV(csv)
        XCTAssertEqual(result.imported, 1)
        XCTAssertEqual(try store2.summary().incomeTotal, 500)
    }

    func testDefaultCurrencyByLocale() {
        XCTAssertEqual(AccountingLocale.US.defaultCurrency, "USD")
        XCTAssertEqual(AccountingLocale.CN.defaultCurrency, "CNY")
    }

    // MARK: - P4c-2 copy (S1–S4)
    //
    // Read straight off the COMMITTED `.strings` files rather than through the app's
    // `Localizer`, so these stay inside this file's contract: public Core API only, no
    // `@testable import SoloLedger`. The claims here are about what is written on disk;
    // the ones that need the app itself live in `AppModelBootTests`.

    private static let languages = ["zh-Hans", "zh-Hant", "en", "ja", "ko", "fr"]

    /// The four keys P4c-2 adds, and — for the three that are deliberate verbatim reuse —
    /// the already-approved key whose value they must equal in every language.
    private static let newKeys: [(key: String, mirrors: String?)] = [
        ("settings.accountingLocale.unreadable.title", "report.blocker.accountingLocaleInvalid.title"),
        ("settings.accountingLocale.absent.title", "report.blocker.accountingLocaleNotConfigured.title"),
        ("settings.accountingLocale.repairHint", nil),
        ("settings.storedText.label", "report.storedText.label"),
        // P4d
        ("settings.reportParams.needsRepair", "report.param.stored.needsRepair"),
        ("settings.reportParams.repairHint", nil),
    ]

    /// …/App/Tests/SoloLedgerUnitTests/<this>.swift → …/native/SoloLedger
    private func strings(_ language: String) throws -> [String: String] {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { dir.deleteLastPathComponent() }
        let url = dir.appendingPathComponent("Sources/SoloLedger/Resources/\(language).lproj/Localizable.strings")
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return try XCTUnwrap(plist as? [String: String], "\(language): not a string dictionary")
    }

    // S1 ────────────────────────────────────────────────────────────────────────────────
    func testS1TheFourNewKeysExistAndAreNotBlankInEveryLanguage() throws {
        for language in Self.languages {
            let table = try strings(language)
            for (key, _) in Self.newKeys {
                let value = try XCTUnwrap(table[key], "\(language) is missing \(key)")
                XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                               "\(language)/\(key) is blank")
                XCTAssertNotEqual(value, key, "\(language)/\(key) holds its own key")
            }
        }
    }

    // S2 ────────────────────────────────────────────────────────────────────────────────
    /// The point of P4c is that the two screens stop saying different things about one row.
    /// Three of the four keys therefore carry the report page's wording VERBATIM, and that
    /// is a guard rather than a coincidence: editing one side alone fails here.
    func testS2TheReusedKeysMatchTheirReportCounterpartsVerbatim() throws {
        for language in Self.languages {
            let table = try strings(language)
            for (key, mirrors) in Self.newKeys {
                guard let mirrors else { continue }
                XCTAssertEqual(table[key], table[mirrors],
                               "\(language): \(key) must read exactly like \(mirrors) — the two "
                               + "screens describe the same row")
            }
        }
    }

    // S3 ────────────────────────────────────────────────────────────────────────────────
    /// Everything visible on Settings ▸ Accounting at once. Two labels that read the same
    /// there are an ambiguity the user has no way to resolve.
    func testS3TheAccountingTabHasNoTwoIdenticalStrings() throws {
        let region = ["settings.accountingLocale", "settings.currency", "settings.company",
                      "settings.accountingNote", "settings.reportParams", "settings.surchargeRate",
                      "settings.incomeTaxRate", "settings.adminExpenseAnnual",
                      "settings.reportParamsPending", "settings.reportParamsNote"]
            + Self.newKeys.map(\.key)
        for language in Self.languages {
            let table = try strings(language)
            let values = try region.map { try XCTUnwrap(table[$0], "\(language) is missing \($0)") }
            XCTAssertEqual(Set(values).count, values.count,
                           "\(language): two strings on the accounting tab read the same")
        }
    }

    // S4 ────────────────────────────────────────────────────────────────────────────────
    /// The new keys landed in `settings.*` and NOT in `report.*`. The report namespace is
    /// held to an exact closed set by the report page's placement table, so a stray key
    /// there would be a different kind of failure — this catches it as a miscount first.
    func testS4TheNewKeysLandedInTheSettingsNamespaceOnly() throws {
        for language in Self.languages {
            let table = try strings(language)
            XCTAssertEqual(table.keys.filter { $0.hasPrefix("settings.") }.count, 36,
                           "\(language): 30 + 4 (P4c-2) + 2 (P4d)")
            XCTAssertEqual(table.keys.filter { $0.hasPrefix("report.") }.count, 165,
                           "\(language): the report namespace must not have moved")
        }
    }
}
