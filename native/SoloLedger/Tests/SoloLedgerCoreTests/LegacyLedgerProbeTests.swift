import XCTest
@testable import SoloLedgerCore

/// A ledger whose records were never converted out of the legacy `sales` /
/// `purchases` tables renders as an EMPTY ledger in this app, because the app reads
/// only `transactions`. These guards pin the counts the UI uses to say so plainly —
/// the probe must never under-report, or a migrated user is told their data is gone.
final class LegacyLedgerProbeTests: LedgerTestCase {

    private func insertSale(_ store: LedgerStore, id: String) throws {
        try store.db.run("INSERT INTO sales (id, date, customer, totalAmount) VALUES (?, ?, ?, ?)",
                         [.text(id), .text("2026-03-01"), .text("Acme"), .real(1000)])
    }

    private func insertPurchase(_ store: LedgerStore, id: String) throws {
        try store.db.run("INSERT INTO purchases (id, date, supplier, totalAmount) VALUES (?, ?, ?, ?)",
                         [.text(id), .text("2026-03-02"), .text("Supplier"), .real(400)])
    }

    /// Mark a legacy row as already converted, exactly as the Electron converter does.
    private func mapAsMigrated(_ store: LedgerStore, table: String, legacyID: String, newID: String) throws {
        // `id` is INTEGER PRIMARY KEY AUTOINCREMENT — let SQLite assign it.
        try store.db.run("""
            INSERT INTO legacy_migrations (legacy_table, legacy_id, new_id)
            VALUES (?, ?, ?)
            """, [.text(table), .text(legacyID), .text(newID)])
    }

    func testFreshLedgerReportsNoLegacyRecords() throws {
        let summary = try makeStore().legacyLedgerSummary()
        XCTAssertEqual(summary, LegacyLedgerSummary())
        XCTAssertFalse(summary.hasUnconverted)
    }

    func testCountsUnconvertedSalesAndPurchases() throws {
        let store = try makeStore()
        try insertSale(store, id: "s-1")
        try insertSale(store, id: "s-2")
        try insertPurchase(store, id: "p-1")

        let summary = try store.legacyLedgerSummary()
        XCTAssertEqual(summary.salesTotal, 2)
        XCTAssertEqual(summary.purchasesTotal, 1)
        XCTAssertEqual(summary.salesUnconverted, 2)
        XCTAssertEqual(summary.purchasesUnconverted, 1)
        XCTAssertEqual(summary.total, 3)
        XCTAssertEqual(summary.unconverted, 3)
        XCTAssertTrue(summary.hasUnconverted)
    }

    func testAlreadyConvertedRowsAreNotCountedAsUnconverted() throws {
        let store = try makeStore()
        try insertSale(store, id: "s-1")
        try insertSale(store, id: "s-2")
        try insertPurchase(store, id: "p-1")
        try mapAsMigrated(store, table: "sales", legacyID: "s-1", newID: "txn-mig-sales-s-1")

        let summary = try store.legacyLedgerSummary()
        XCTAssertEqual(summary.salesTotal, 2, "the legacy row itself is never removed by a conversion")
        XCTAssertEqual(summary.salesUnconverted, 1)
        XCTAssertEqual(summary.purchasesUnconverted, 1)
        XCTAssertTrue(summary.hasUnconverted)
    }

    func testFullyConvertedLedgerReportsNothingUnconverted() throws {
        let store = try makeStore()
        try insertSale(store, id: "s-1")
        try insertPurchase(store, id: "p-1")
        try mapAsMigrated(store, table: "sales", legacyID: "s-1", newID: "txn-a")
        try mapAsMigrated(store, table: "purchases", legacyID: "p-1", newID: "txn-b")

        let summary = try store.legacyLedgerSummary()
        XCTAssertEqual(summary.total, 2)
        XCTAssertEqual(summary.unconverted, 0)
        XCTAssertFalse(summary.hasUnconverted, "a fully converted ledger must show no notice")
    }

    func testMappingIsMatchedPerTableNotJustByLegacyID() throws {
        // sales and purchases ids are independent; a mapping for sales 'x-1' must not
        // silently mark purchase 'x-1' as converted.
        let store = try makeStore()
        try insertSale(store, id: "x-1")
        try insertPurchase(store, id: "x-1")
        try mapAsMigrated(store, table: "sales", legacyID: "x-1", newID: "txn-a")

        let summary = try store.legacyLedgerSummary()
        XCTAssertEqual(summary.salesUnconverted, 0)
        XCTAssertEqual(summary.purchasesUnconverted, 1)
    }

    func testStaleMappingRowsCannotHideUnconvertedRecords() throws {
        // Electron's detectLegacy derives pending as total - COUNT(mappings), which
        // under-reports once a mapped legacy row is deleted. The anti-join used here
        // counts the actual work set instead.
        let store = try makeStore()
        try insertSale(store, id: "s-1")
        try insertSale(store, id: "s-2")
        try mapAsMigrated(store, table: "sales", legacyID: "gone-1", newID: "txn-a")
        try mapAsMigrated(store, table: "sales", legacyID: "gone-2", newID: "txn-b")

        let summary = try store.legacyLedgerSummary()
        XCTAssertEqual(summary.salesTotal, 2)
        XCTAssertEqual(summary.salesUnconverted, 2,
                       "two live unconverted rows must stay visible despite two stale mappings")
    }

    func testOtherElectronTablesAlsoCountAsHiddenRecords() throws {
        // A ledger whose records are invoices/products/fixed assets — no transactions
        // and no legacy sales — is just as non-empty, and must never be offered a
        // demo-data seed nor be told "you have no records".
        let store = try makeStore()
        try store.db.run("INSERT INTO products (id, name) VALUES (?, ?)", [.text("p-1"), .text("Widget")])

        let summary = try store.legacyLedgerSummary()
        XCTAssertFalse(summary.hasUnconverted, "no legacy sales/purchases here")
        XCTAssertEqual(summary.otherRecords, 1)
        XCTAssertTrue(summary.holdsHiddenRecords)
    }

    func testInfrastructureAndSingletonRowsDoNotCountAsRecords() throws {
        // Alerts are plumbing, and `home_office` is a singleton every ledger is seeded
        // with (schema v6). Counting either would put a "you have hidden records"
        // notice on a genuinely empty ledger — and would disable the demo seed there.
        let store = try makeStore()
        try store.db.run("INSERT INTO alerts (type, title, body) VALUES (?, ?, ?)",
                         [.text("info"), .text("hi"), .text("hello")])
        let homeOffice = try store.db.query("SELECT COUNT(*) AS c FROM home_office").first?.int("c")
        XCTAssertEqual(homeOffice, 1, "fixture assumption: home_office is seeded on every ledger")

        let summary = try store.legacyLedgerSummary()
        XCTAssertEqual(summary.otherRecords, 0)
        XCTAssertFalse(summary.holdsHiddenRecords)
    }

    func testMissingLegacyTablesAreTreatedAsAbsentNotAsAnError() throws {
        // Defensive path for a hand-edited file: the probe must degrade to zero rather
        // than throw, since a throw would leave the UI unable to say anything at all.
        let store = try makeStore()
        try store.db.execute("DROP TABLE sales; DROP TABLE purchases; DROP TABLE legacy_migrations;")

        let summary = try store.legacyLedgerSummary()
        XCTAssertEqual(summary.salesTotal, 0)
        XCTAssertEqual(summary.purchasesTotal, 0)
        XCTAssertFalse(summary.hasUnconverted)
    }

    func testWithoutAMappingTableEveryLegacyRowCountsAsUnconverted() throws {
        let store = try makeStore()
        try insertSale(store, id: "s-1")
        try store.db.execute("DROP TABLE legacy_migrations;")

        let summary = try store.legacyLedgerSummary()
        XCTAssertEqual(summary.salesUnconverted, 1, "nothing can be proven converted without the mapping")
    }

    func testProbeNeverWritesToTheLedger() throws {
        let store = try makeStore()
        try insertSale(store, id: "s-1")
        try insertPurchase(store, id: "p-1")

        _ = try store.legacyLedgerSummary()
        _ = try store.legacyLedgerSummary()

        XCTAssertEqual(try store.listTransactions().count, 0, "the probe must never create transactions")
        let mappings = try store.db.query("SELECT COUNT(*) AS c FROM legacy_migrations").first?.int("c")
        XCTAssertEqual(mappings, 0, "the probe must never record a migration")
        let sales = try store.db.query("SELECT COUNT(*) AS c FROM sales").first?.int("c")
        XCTAssertEqual(sales, 1, "the probe must never modify the legacy tables")
    }
}
