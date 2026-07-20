import XCTest
@testable import SoloLedgerCore

/// Batch delete must be atomic (all-or-nothing) and fully undoable. Undo restores
/// each row VERBATIM from a raw snapshot — every column value, its SQLite storage
/// class, its NULL state, the original created_at/updated_at, and every related
/// legacy_migrations row (incl its primary key id and migrated_at).
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

    /// Read a single row verbatim (raw column values + NULL/type state).
    private func rawTransaction(_ store: LedgerStore, id: String) throws -> RawRow {
        RawRow(try XCTUnwrap(try store.db.query("SELECT * FROM transactions WHERE id = ?", [.text(id)]).first))
    }
    private func rawMappings(_ store: LedgerStore, newID: String) throws -> [RawRow] {
        try store.db.query("SELECT * FROM legacy_migrations WHERE new_id = ? ORDER BY id", [.text(newID)]).map { RawRow($0) }
    }

    func testBatchDeleteRemovesTransactionsAndMappingsAtomically() throws {
        let store = try makeStore()
        try seedRich(store)

        let snap = try store.deleteBatch(ids: ["t1", "t2"])
        XCTAssertEqual(try store.listTransactions().count, 0)
        XCTAssertEqual(try store.db.query("SELECT * FROM legacy_migrations").count, 0)
        XCTAssertEqual(snap.transactionRows.count, 2)
        XCTAssertEqual(snap.legacyMappingRows.count, 1)
        XCTAssertEqual(snap.legacyMappingRows.first?.value("legacy_id"), .text("s1"))
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

    // MARK: - Undo restores everything exactly, incl FIXED past timestamps

    /// Hardened against the "same-wall-clock-second" coincidence: the created_at /
    /// updated_at / migrated_at are overwritten with FIXED, clearly-past literal values
    /// BEFORE the snapshot. A regression that let restore re-default them to
    /// datetime('now') (2026) would produce a different string than 2018/2019/2020 and
    /// FAIL — the test can no longer pass by coincidence.
    func testUndoRestoresFieldsTimestampsAndMappingsExactly() throws {
        let store = try makeStore()
        try seedRich(store)

        try store.db.run("UPDATE transactions SET created_at = ?, updated_at = ? WHERE id = 't1'",
                         [.text("2020-01-01 00:00:00"), .text("2020-06-15 12:34:56")])
        try store.db.run("UPDATE transactions SET created_at = ?, updated_at = ? WHERE id = 't2'",
                         [.text("2019-03-03 03:03:03"), .text("2019-09-09 09:09:09")])
        try store.db.run("UPDATE legacy_migrations SET migrated_at = ? WHERE new_id = 't1'",
                         [.text("2018-07-07 07:07:07")])

        // Capture exact pre-delete raw rows.
        let before1 = try rawTransaction(store, id: "t1")
        let before2 = try rawTransaction(store, id: "t2")
        let beforeMap = try XCTUnwrap(try rawMappings(store, newID: "t1").first)
        // Preconditions: the fixed timestamps are actually present (and are NOT now()).
        XCTAssertEqual(before1.value("created_at"), .text("2020-01-01 00:00:00"))
        XCTAssertEqual(before1.value("updated_at"), .text("2020-06-15 12:34:56"))
        XCTAssertEqual(beforeMap.value("migrated_at"), .text("2018-07-07 07:07:07"))

        // Delete, then restore.
        let snap = try store.deleteBatch(ids: ["t1", "t2"])
        XCTAssertEqual(try store.listTransactions().count, 0)
        XCTAssertEqual(snap.legacyMappingRows.count, 1)
        try store.restore(snap)

        // Count + IDs.
        let after = try store.listTransactions()
        XCTAssertEqual(after.count, 2)
        XCTAssertEqual(Set(after.map { $0.id }), ["t1", "t2"])

        // Every column verbatim, including the FIXED timestamps.
        let after1 = try rawTransaction(store, id: "t1")
        let after2 = try rawTransaction(store, id: "t2")
        let afterMap = try XCTUnwrap(try rawMappings(store, newID: "t1").first)
        XCTAssertEqual(after1, before1)
        XCTAssertEqual(after2, before2)
        // Explicit: a now()-default regression on restore would change these → assertion fails.
        XCTAssertEqual(after1.value("created_at"), .text("2020-01-01 00:00:00"))
        XCTAssertEqual(after1.value("updated_at"), .text("2020-06-15 12:34:56"))
        XCTAssertEqual(after2.value("created_at"), .text("2019-03-03 03:03:03"))

        // Legacy mapping restored verbatim — ALL columns incl original primary key id
        // and the fixed migrated_at.
        XCTAssertEqual(afterMap, beforeMap)
        XCTAssertEqual(afterMap.value("id"), beforeMap.value("id"))            // original PK preserved
        XCTAssertEqual(afterMap.value("migrated_at"), .text("2018-07-07 07:07:07"))
    }

    // MARK: - NULL / storage-class fidelity (raw snapshot, no model coercion)

    /// A row written with SQL NULL in every nullable column (as an Electron-migrated
    /// or hand-edited row legitimately can be) must come back byte-for-byte after
    /// delete+undo — NULLs stay NULL, not coerced to "" / 0 / a default enum, and the
    /// storage class (REAL vs TEXT) is preserved. Written via raw SQL to bypass
    /// create()/normalized(), which would never produce these NULLs.
    func testUndoRestoresRawNullStateAndTypesVerbatim() throws {
        let store = try makeStore()
        try store.db.run("""
            INSERT INTO transactions
              (id, type, date, amount, amount_net, tax_amount, tax_rate, currency,
               category_id, counterparty, invoice_no, invoice_status,
               payment_status, paid_amount, payment_date, due_date,
               description, attachment_path, source_meta, created_at, updated_at)
            VALUES
              ('tnull', 'income', '2026-02-02', 1234.5, NULL, NULL, NULL, 'CNY',
               NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL)
            """)
        try store.db.run("""
            INSERT INTO legacy_migrations (legacy_table, legacy_id, new_id, migrated_at)
            VALUES ('purchases', 'p9', 'tnull', NULL)
            """)

        let beforeTxn = try rawTransaction(store, id: "tnull")
        let beforeMap = try XCTUnwrap(try rawMappings(store, newID: "tnull").first)

        // Precondition: these really are stored NULL (the whole point of the test).
        let nullableCols = ["amount_net", "tax_amount", "tax_rate", "category_id", "counterparty",
                            "invoice_no", "invoice_status", "payment_status", "paid_amount",
                            "payment_date", "due_date", "description", "attachment_path",
                            "source_meta", "created_at", "updated_at"]
        for col in nullableCols {
            XCTAssertEqual(beforeTxn.value(col), .null, "precondition: \(col) should be stored NULL")
        }
        XCTAssertEqual(beforeMap.value("migrated_at"), .null)
        // Storage class preserved for the non-null numeric column.
        XCTAssertEqual(beforeTxn.value("amount"), .real(1234.5))

        // Delete + undo.
        let snap = try store.deleteBatch(ids: ["tnull"])
        XCTAssertEqual(try store.db.query("SELECT * FROM transactions WHERE id='tnull'").count, 0)
        XCTAssertEqual(try store.db.query("SELECT * FROM legacy_migrations WHERE new_id='tnull'").count, 0)
        try store.restore(snap)

        let afterTxn = try rawTransaction(store, id: "tnull")
        let afterMap = try XCTUnwrap(try rawMappings(store, newID: "tnull").first)

        // Whole-row verbatim (RawRow Equatable compares value + storage class + NULL per column).
        XCTAssertEqual(afterTxn, beforeTxn)
        XCTAssertEqual(afterMap, beforeMap)
        // And column-by-column, per the reviewer's requirement to compare all columns'
        // value AND SQLite type/NULL state before vs after.
        for col in beforeTxn.columns {
            XCTAssertEqual(afterTxn.value(col), beforeTxn.value(col), "column \(col) not restored verbatim")
        }
        // Explicit: NULLs are still NULL — NOT coerced to "" / 0 / default enum.
        for col in nullableCols {
            XCTAssertEqual(afterTxn.value(col), .null, "\(col) must remain NULL after undo, not coerced")
        }
        XCTAssertEqual(afterMap.value("migrated_at"), .null)
        XCTAssertEqual(afterTxn.value("amount"), .real(1234.5))   // storage class preserved
    }

    // MARK: - Multiple legacy mappings per transaction

    /// A transaction can map to more than one legacy row (UNIQUE is on
    /// (legacy_table, legacy_id), not new_id). Undo must restore ALL of them verbatim.
    func testUndoRestoresMultipleLegacyMappingsPerTransaction() throws {
        let store = try makeStore()
        try store.create(Transaction(id: "tm", type: .income, date: "2026-01-01", amount: 100, currency: "CNY"))
        try store.db.run("INSERT INTO legacy_migrations (legacy_table, legacy_id, new_id) VALUES ('sales','s1','tm')")
        try store.db.run("INSERT INTO legacy_migrations (legacy_table, legacy_id, new_id) VALUES ('purchases','p1','tm')")
        let before = try rawMappings(store, newID: "tm")
        XCTAssertEqual(before.count, 2)

        let snap = try store.deleteBatch(ids: ["tm"])
        XCTAssertEqual(snap.legacyMappingRows.count, 2)                       // BOTH captured
        XCTAssertEqual(try store.db.query("SELECT * FROM legacy_migrations WHERE new_id='tm'").count, 0)
        try store.restore(snap)

        let after = try rawMappings(store, newID: "tm")
        XCTAssertEqual(after.count, 2)
        XCTAssertEqual(after, before)                                         // both rows, all columns incl original ids
    }

    // MARK: - Edge-case batches (empty / single / non-existent)

    func testEmptyBatchReturnsEmptySnapshotAndIsNoOp() throws {
        let store = try makeStore()
        try store.create(Transaction(id: "e1", type: .income, date: "2026-01-01", amount: 10, currency: "CNY"))

        let snap = try store.deleteBatch(ids: [])
        XCTAssertTrue(snap.isEmpty)
        XCTAssertEqual(snap.transactionRows.count, 0)
        XCTAssertEqual(snap.legacyMappingRows.count, 0)
        XCTAssertEqual(try store.listTransactions().count, 1)                 // untouched
    }

    func testSingleElementBatchDeletesAndUndoesExactly() throws {
        let store = try makeStore()
        try store.create(Transaction(id: "s1", type: .expense, date: "2026-01-02", amount: 42, currency: "USD"))
        let before = try rawTransaction(store, id: "s1")

        let snap = try store.deleteBatch(ids: ["s1"])
        XCTAssertEqual(snap.transactionRows.count, 1)
        XCTAssertEqual(try store.listTransactions().count, 0)
        try store.restore(snap)

        XCTAssertEqual(try rawTransaction(store, id: "s1"), before)
    }

    /// Ids that don't exist are skipped (no snapshot entry fabricated) and neither
    /// throw nor corrupt the batch; the existing row is deleted and fully undoable.
    func testNonExistentIDsAreSkippedNotFabricated() throws {
        let store = try makeStore()
        try store.create(Transaction(id: "real", type: .income, date: "2026-01-03", amount: 5, currency: "CNY"))

        let snap = try store.deleteBatch(ids: ["real", "ghost1", "ghost2"])
        XCTAssertEqual(snap.transactionRows.count, 1)                         // only the existing row — nothing fabricated
        XCTAssertEqual(snap.legacyMappingRows.count, 0)
        XCTAssertEqual(try store.listTransactions().count, 0)

        try store.restore(snap)
        let after = try store.listTransactions()
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after.first?.id, "real")
    }
}
