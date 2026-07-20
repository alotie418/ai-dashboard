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
}
