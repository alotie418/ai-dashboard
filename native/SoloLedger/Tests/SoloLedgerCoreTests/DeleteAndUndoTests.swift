import XCTest
@testable import SoloLedgerCore

/// Batch delete must be atomic (all-or-nothing) and fully undoable — every field,
/// the original created_at/updated_at, and the related legacy_migrations mappings.
final class DeleteAndUndoTests: LedgerTestCase {

    private struct Boom: Error {}

    /// A transaction with (almost) every field populated + a legacy mapping.
    private func seedRich(_ store: LedgerStore) throws {
        let inc = try store.categories(locale: .CN, type: .income).first
        try store.create(Transaction(
            id: "t1", type: .income, date: "2026-01-05", amount: 1000, amountNet: 943.4,
            taxAmount: 56.6, taxRate: 0.06, currency: "CNY", categoryID: inc?.id,
            counterparty: "客户A", invoiceNo: "INV-1", invoiceStatus: .issued,
            paymentStatus: .partial, paidAmount: 600, paymentDate: "2026-01-06",
            dueDate: "2026-02-05", description: "项目款", sourceMeta: "{\"migrated_from\":\"sales\"}"))
        try store.create(Transaction(id: "t2", type: .expense, date: "2026-01-10", amount: 300, currency: "USD"))
        // legacy mapping referencing t1
        try store.db.run("INSERT INTO legacy_migrations (legacy_table, legacy_id, new_id) VALUES ('sales','s1','t1')")
    }

    func testBatchDeleteRemovesTransactionsAndMappingsAtomically() throws {
        let store = try makeStore()
        try seedRich(store)

        let snap = try store.deleteBatch(ids: ["t1", "t2"])
        XCTAssertEqual(try store.listTransactions().count, 0)
        XCTAssertEqual(try store.db.query("SELECT * FROM legacy_migrations").count, 0)
        XCTAssertEqual(snap.transactions.count, 2)
        XCTAssertEqual(snap.legacyMappings.count, 1)
        XCTAssertEqual(snap.legacyMappings.first?.legacyId, "s1")
    }

    // MARK: - Fault injection: a mid-batch failure must lose NOTHING

    func testBatchDeleteRollsBackEntirelyOnMidBatchFailure() throws {
        let store = try makeStore()
        for i in 1...5 {
            try store.create(Transaction(id: "t\(i)", type: .income, date: "2026-01-0\(i)", amount: Double(i * 100), currency: "CNY"))
        }
        try store.db.run("INSERT INTO legacy_migrations (legacy_table, legacy_id, new_id) VALUES ('sales','s3','t3')")
        let beforeTxns = try store.listTransactions().count
        let beforeMaps = try store.db.query("SELECT * FROM legacy_migrations").count

        XCTAssertThrowsError(try store.deleteBatch(ids: ["t1", "t2", "t3", "t4", "t5"], faultInjection: { throw Boom() }))

        // Whole batch rolled back — not a single row (or mapping) is missing.
        XCTAssertEqual(try store.listTransactions().count, beforeTxns)   // all 5 remain
        XCTAssertEqual(try store.db.query("SELECT * FROM legacy_migrations").count, beforeMaps)
    }

    // MARK: - Undo restores everything exactly

    func testUndoRestoresFieldsTimestampsAndMappingsExactly() throws {
        let store = try makeStore()
        try seedRich(store)

        // Capture BEFORE (full rows incl created_at/updated_at, and the mapping).
        let before1 = try XCTUnwrap(store.transaction(id: "t1"))
        let before2 = try XCTUnwrap(store.transaction(id: "t2"))
        XCTAssertNotNil(before1.createdAt); XCTAssertNotNil(before1.updatedAt)
        let beforeMapRow = try XCTUnwrap(try store.db.query(
            "SELECT id, legacy_table, legacy_id, new_id, migrated_at FROM legacy_migrations WHERE new_id='t1'").first)
        let beforeMapping = LegacyMapping(
            id: try XCTUnwrap(beforeMapRow.int("id")),
            legacyTable: try XCTUnwrap(beforeMapRow.string("legacy_table")),
            legacyId: try XCTUnwrap(beforeMapRow.string("legacy_id")),
            newId: try XCTUnwrap(beforeMapRow.string("new_id")),
            migratedAt: beforeMapRow.string("migrated_at"))

        // Delete, then restore.
        let snap = try store.deleteBatch(ids: ["t1", "t2"])
        XCTAssertEqual(try store.listTransactions().count, 0)
        XCTAssertEqual(snap.legacyMappings.count, 1)
        XCTAssertEqual(snap.legacyMappings.first, beforeMapping)   // snapshot captured ALL mapping fields (incl id)
        try store.restore(snap)

        // Count + IDs.
        let after = try store.listTransactions()
        XCTAssertEqual(after.count, 2)
        XCTAssertEqual(Set(after.map { $0.id }), ["t1", "t2"])

        // Field-by-field equality (Transaction is Hashable → Equatable over ALL fields,
        // including created_at / updated_at).
        XCTAssertEqual(try XCTUnwrap(store.transaction(id: "t1")), before1)
        XCTAssertEqual(try XCTUnwrap(store.transaction(id: "t2")), before2)

        // Legacy mapping restored verbatim — ALL fields: id, legacy_table, legacy_id,
        // new_id, migrated_at.
        let afterMapRow = try XCTUnwrap(try store.db.query(
            "SELECT id, legacy_table, legacy_id, new_id, migrated_at FROM legacy_migrations WHERE new_id='t1'").first)
        let afterMapping = LegacyMapping(
            id: try XCTUnwrap(afterMapRow.int("id")),
            legacyTable: try XCTUnwrap(afterMapRow.string("legacy_table")),
            legacyId: try XCTUnwrap(afterMapRow.string("legacy_id")),
            newId: try XCTUnwrap(afterMapRow.string("new_id")),
            migratedAt: afterMapRow.string("migrated_at"))
        XCTAssertEqual(afterMapping, beforeMapping)
        XCTAssertEqual(afterMapping.id, beforeMapping.id)      // original primary key preserved
    }
}
