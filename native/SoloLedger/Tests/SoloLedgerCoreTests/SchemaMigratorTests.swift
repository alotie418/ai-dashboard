import XCTest
@testable import SoloLedgerCore

final class SchemaMigratorTests: LedgerTestCase {

    func testMigratesToHead() throws {
        let store = try makeStore()
        XCTAssertEqual(try store.schemaVersion(), 23)
        XCTAssertEqual(SchemaMigrator.schemaVersion, 23)
    }

    func testAllExpectedTablesExist() throws {
        let store = try makeStore()
        let names = try store.db.query("SELECT name FROM sqlite_master WHERE type='table'")
            .compactMap { $0.string("name") }
        let expected = ["purchases", "sales", "settings", "price_history", "alerts", "ai_providers",
                        "categories", "transactions", "legacy_migrations", "mileage_logs", "home_office",
                        "products", "business_documents", "business_document_items",
                        "assistant_conversations", "assistant_messages", "accounts", "liabilities",
                        "fixed_assets", "equity", "tax_payments", "purchase_items", "sales_items",
                        "ecommerce_connections", "ecommerce_staged_orders", "ecommerce_sync_log"]
        for table in expected {
            XCTAssertTrue(names.contains(table), "missing table \(table)")
        }
        XCTAssertEqual(expected.count, 26)
    }

    func testReopenIsIdempotent() throws {
        let url = try tempDatabaseURL()
        do {
            let store = try LedgerStore(databaseURL: url)
            XCTAssertEqual(try store.schemaVersion(), 23)
        }
        // Reopen the same file: no re-migration, no duplicate seed.
        let store2 = try LedgerStore(databaseURL: url)
        XCTAssertEqual(try store2.schemaVersion(), 23)
        let count = try store2.db.query("SELECT COUNT(*) AS c FROM categories").first?.int("c")
        XCTAssertEqual(count, 78)
    }

    /// Verifies the ported generated STORED column matches the JS expression.
    func testGeneratedDeductionColumn() throws {
        let store = try makeStore()
        try store.db.run("""
            INSERT INTO mileage_logs (id, date, miles, round_trip, rate_per_mile)
            VALUES ('m1', '2026-01-01', 100, 1, 0.5)
            """)
        let deduction = try store.db.query("SELECT deduction FROM mileage_logs WHERE id='m1'").first?.double("deduction")
        XCTAssertEqual(deduction ?? 0, 100.0, accuracy: 0.0001) // 100 * 0.5 * (1+1)
    }

    func testForeignKeysEnforced() throws {
        let store = try makeStore()
        // category_id → categories(id) is an enforced FK; a bogus id must fail.
        XCTAssertThrowsError(try store.db.run("""
            INSERT INTO transactions (id, type, date, amount, category_id, currency)
            VALUES ('bad', 'income', '2026-01-01', 1, 'no-such-category', 'CNY')
            """))
    }
}
