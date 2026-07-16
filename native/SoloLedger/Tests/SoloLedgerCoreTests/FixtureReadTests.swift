import XCTest
@testable import SoloLedgerCore

/// Verifies the Swift Core reads a REAL Electron-produced v23 database completely
/// (the fixture is built by the actual electron/db migration code). Covers the six
/// read categories required by the Electron→SwiftUI upgrade verification.
final class FixtureReadTests: LedgerTestCase {

    private func openFixture() throws -> LedgerStore {
        // Open a writable copy so LedgerStore's open-time PRAGMAs/migrator (a no-op
        // at v23) don't touch the committed fixture.
        try LedgerStore(databaseURL: electronFixtureCopy())
    }

    func testSchemaVersion() throws {
        XCTAssertEqual(try openFixture().schemaVersion(), 23)
    }

    func testTablesAndIndexes() throws {
        let store = try openFixture()
        let tables = try store.db.query("SELECT name FROM sqlite_master WHERE type='table'")
            .compactMap { $0.string("name") }
        let expected = ["purchases", "sales", "settings", "price_history", "alerts", "ai_providers",
                        "categories", "transactions", "legacy_migrations", "mileage_logs", "home_office",
                        "products", "business_documents", "business_document_items",
                        "assistant_conversations", "assistant_messages", "accounts", "liabilities",
                        "fixed_assets", "equity", "tax_payments", "purchase_items", "sales_items",
                        "ecommerce_connections", "ecommerce_staged_orders", "ecommerce_sync_log"]
        for t in expected { XCTAssertTrue(tables.contains(t), "missing table \(t)") }

        let indexes = try store.db.query("SELECT name FROM sqlite_master WHERE type='index'")
            .compactMap { $0.string("name") }
        for idx in ["idx_txn_date", "idx_txn_type_date", "idx_txn_category", "idx_categories_locale_type"] {
            XCTAssertTrue(indexes.contains(idx), "missing index \(idx)")
        }
    }

    func testTransactionCountAndSums() throws {
        let store = try openFixture()
        XCTAssertEqual(try store.listTransactions().count, 7)
        XCTAssertEqual(try store.listTransactions(type: .income).count, 4)
        XCTAssertEqual(try store.listTransactions(type: .expense).count, 3)
        let s = try store.summary()
        XCTAssertEqual(s.incomeTotal, 4600.75, accuracy: 0.001)
        XCTAssertEqual(s.expenseTotal, 1750.74, accuracy: 0.001)
        XCTAssertEqual(s.net, 2850.01, accuracy: 0.001)
    }

    func testSettings() throws {
        let store = try openFixture()
        XCTAssertEqual(try store.settings.rawValue("accounting_locale"), "\"CN\"") // JSON-encoded on disk
        XCTAssertEqual(try store.settings.string("accounting_locale"), "CN")
        XCTAssertEqual(try store.settings.accountingLocale(), .CN)
        XCTAssertEqual(try store.settings.string("company_name"), "示例商贸有限公司")
        XCTAssertEqual(try store.settings.string("currency"), "CNY")
        XCTAssertEqual(try store.settings.string("ui_language"), "zh-CN")
    }

    func testCategoryAssociations() throws {
        let store = try openFixture()
        XCTAssertEqual(try store.categories(locale: .CN).count, 9)

        // Every transaction's category_id resolves to a real category (FK integrity).
        let allCats = Set(try store.db.query("SELECT id FROM categories").compactMap { $0.string("id") })
        for t in try store.listTransactions() {
            if let cid = t.categoryID { XCTAssertTrue(allCats.contains(cid), "dangling category \(cid)") }
        }
        // A specific association + localized label.
        let t1 = try store.transaction(id: "txn-fixture-1")
        XCTAssertEqual(t1?.categoryID, "cn-income-sales")
        let sales = try store.categories(locale: .CN, type: .income).first { $0.id == "cn-income-sales" }
        XCTAssertEqual(sales?.label(for: "zh-Hans"), "主营业务收入")
        XCTAssertEqual(sales?.label(for: "en"), "Sales Revenue")
    }

    func testDateAmountEnumFields() throws {
        let store = try openFixture()

        let t2 = try XCTUnwrap(try store.transaction(id: "txn-fixture-2"))
        XCTAssertEqual(t2.date, "2025-12-10")                 // TEXT date
        XCTAssertEqual(t2.amount, 2500.50, accuracy: 0.001)   // REAL amount (Double)
        XCTAssertEqual(try XCTUnwrap(t2.amountNet), 2358.96, accuracy: 0.001)
        XCTAssertEqual(t2.taxRate, 0.06, accuracy: 0.0001)
        XCTAssertEqual(t2.paidAmount, 1000, accuracy: 0.001)
        XCTAssertEqual(t2.dueDate, "2026-01-10")
        XCTAssertEqual(t2.paymentStatus, .partial)            // enum
        XCTAssertEqual(t2.invoiceStatus, .pending)            // enum

        let t4 = try XCTUnwrap(try store.transaction(id: "txn-fixture-4"))
        XCTAssertEqual(t4.currency, "USD")
        XCTAssertEqual(t4.paymentStatus, .unpaid)
        XCTAssertEqual(t4.invoiceStatus, .na)                 // raw "n/a"
        XCTAssertTrue(t4.sourceMeta?.contains("migrated_from") ?? false, "source_meta JSON not read")

        // Full enum coverage present across the fixture.
        let all = try store.listTransactions()
        XCTAssertEqual(Set(all.map { $0.paymentStatus }), [.paid, .partial, .unpaid])
        XCTAssertEqual(Set(all.map { $0.invoiceStatus }), [.issued, .pending, .na])
        XCTAssertEqual(Set(all.map { $0.type }), [.income, .expense])
    }
}
