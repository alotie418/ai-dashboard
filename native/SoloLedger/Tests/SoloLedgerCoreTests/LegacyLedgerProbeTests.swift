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
        // A ledger whose records are invoices/fixed assets — no transactions and no legacy
        // sales — is just as non-empty, and must never be offered a demo-data seed nor be
        // told "you have no records". The fixture uses a table this app still does not show;
        // `products` used to serve here and no longer can — see the test below.
        let store = try makeStore()
        try store.db.run("INSERT INTO fixed_assets (id, name) VALUES (?, ?)",
                         [.text("fa-1"), .text("Van")])

        let summary = try store.legacyLedgerSummary()
        XCTAssertFalse(summary.hasUnconverted, "no legacy sales/purchases here")
        XCTAssertEqual(summary.otherRecords, 1)
        XCTAssertTrue(summary.holdsHiddenRecords)
    }

    /// 2b-A4. `products` is no longer a hidden record, because the app now has a page that shows
    /// it. Leaving it in `otherRecordTables` would have told a user who had just created their
    /// first product that this ledger holds records the app does not show — while showing them.
    ///
    /// A positive claim rather than an absence: the row really is there, the probe really does
    /// see the table, and it still answers zero.
    func testAProductRowIsNotAHiddenRecordBecauseTheAppShowsProducts() throws {
        let store = try makeStore()
        try store.db.run("INSERT INTO products (id, name) VALUES (?, ?)",
                         [.text("p-1"), .text("Widget")])
        XCTAssertEqual(try store.db.query("SELECT COUNT(*) AS c FROM products").first?.int("c"), 1,
                       "fixture assumption: the row is really in the file")

        let summary = try store.legacyLedgerSummary()
        XCTAssertEqual(summary.otherRecords, 0, "a visible record is not a hidden one")
        XCTAssertFalse(summary.holdsHiddenRecords,
                       "a ledger holding only products is not one whose records are out of reach")
        XCTAssertFalse(summary.hasUnconverted)
        // And the table is out of the list by name, so a re-added entry fails here too.
        XCTAssertFalse(LegacyLedgerSummary.otherRecordTables.contains("products"))
        XCTAssertEqual(LegacyLedgerSummary.otherRecordTables.count, 9)
        XCTAssertTrue(LegacyLedgerSummary.otherRecordTables.contains("fixed_assets"),
                      "the tables this app still does not show must stay counted")
    }

    /// D-6, and the same rule 2b-A4 applied to `products`: a record the user can now see on a page
    /// of its own is not a hidden one. Both document tables leave together — the items table is a
    /// child of the headers table, and counting the lines of a document the page lists would say
    /// "records you cannot see" about the rows of a document on screen.
    ///
    /// A positive claim rather than an absence: the rows really are there, the probe really does
    /// see the tables, and it still answers zero.
    func testABusinessDocumentIsNotAHiddenRecordBecauseTheAppShowsDocuments() throws {
        let store = try makeStore()
        let id = try store.createBusinessDocument(
            BusinessDocumentDraft(type: .quotation, number: "QT-2026-0001",
                                  date: "2026-08-21", customerName: "Acme",
                                  lines: [BusinessDocumentLineDraft(description: "Widget", quantity: 2,
                                                                    unitPrice: 50, taxRate: "13%")],
                                  lineOrigin: .handEntered))
        XCTAssertEqual(try store.db.query("SELECT COUNT(*) AS c FROM business_documents").first?.int("c"), 1,
                       "fixture assumption: the header row is really in the file")
        XCTAssertGreaterThan(try store.db.query(
            "SELECT COUNT(*) AS c FROM business_document_items").first?.int("c") ?? 0, 0,
            "fixture assumption: the item row is really in the file, so removing that table matters too")
        XCTAssertFalse(id.isEmpty)

        let summary = try store.legacyLedgerSummary()
        XCTAssertEqual(summary.otherRecords, 0, "a visible record is not a hidden one")
        XCTAssertFalse(summary.holdsHiddenRecords,
                       "a ledger holding only business documents is not one whose records are out of reach")
        XCTAssertFalse(summary.hasUnconverted)

        // Out of the list by name, so a re-added entry fails here too — either one of them.
        XCTAssertFalse(LegacyLedgerSummary.otherRecordTables.contains("business_documents"))
        XCTAssertFalse(LegacyLedgerSummary.otherRecordTables.contains("business_document_items"))
        XCTAssertEqual(LegacyLedgerSummary.otherRecordTables.sorted(),
                       ["accounts", "equity", "fixed_assets", "liabilities", "mileage_logs",
                        "price_history", "purchase_items", "sales_items", "tax_payments"],
                       "the closed set of tables this app still does not show")
    }

    /// Not vacuous: the probe DOES count a table that is still hidden, on the same ledger shape.
    /// Without this, "otherRecords == 0" above could equally mean the probe stopped working.
    func testTheProbeStillCountsATableTheAppDoesNotShow() throws {
        let store = try makeStore()
        _ = try store.createBusinessDocument(
            BusinessDocumentDraft(type: .quotation, number: "QT-2026-0002",
                                  date: "2026-08-21", customerName: "Acme"))
        try store.db.run("INSERT INTO liabilities (id, name) VALUES (?, ?)",
                         [.text("l-1"), .text("Loan")])

        let summary = try store.legacyLedgerSummary()
        XCTAssertEqual(summary.otherRecords, 1,
                       "the liability counts and the document does not — one probe, two answers")
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
