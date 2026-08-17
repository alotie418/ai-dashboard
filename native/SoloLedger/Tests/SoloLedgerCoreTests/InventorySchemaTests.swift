import XCTest
@testable import SoloLedgerCore

/// N-PR-1: schema v24 — the first rung of the native ladder that Electron has no counterpart for.
///
/// The suite is organised by the property each group protects:
///
///  * **G** — the migration itself: a v23 ledger reaches v24, the rung is idempotent, and the
///    declared rollback form (`DROP` the three tables + `PRAGMA user_version = 23`) is COMPLETE.
///    G3 performs the round trip and compares `sqlite_master` rather than asserting it in prose,
///    because "purely additive" is a claim about objects and nothing weaker proves it.
///  * **H** — the constraints are real at the storage layer: STRICT types, the two CHECK closed
///    sets, the foreign key, and the two unique indexes. Each is exercised in BOTH directions —
///    a constraint that only ever rejects could be a table nobody can write to.
///  * **L** — the link to N-PR-0b: an in-place upgrade of a real v23 ledger gets its
///    pre-migration snapshot, and that snapshot is restorable through the shipping chain.
///
/// There is no oracle here. Electron's inventory read is not being mirrored — it was audited and
/// rejected — so every expectation traces to the N0 ruling or to MEASURED SQLite behaviour, and
/// the measured ones say so at the assertion.
final class InventorySchemaTests: LedgerTestCase {

    private let fm = FileManager.default

    /// The three tables v24 adds, in ladder order.
    private let inventoryTables = ["inventory_movements", "inventory_balances", "inventory_exceptions"]

    // MARK: - Fixtures

    /// A REAL Electron v23 database (the committed fixture), as a writable copy.
    private func v23Ledger() throws -> URL { try electronFixtureCopy(named: "v23.db") }

    /// Open a database read-write with foreign keys enforced, as every production path does.
    private func openRW(_ url: URL) throws -> SQLiteDatabase {
        let db = try SQLiteDatabase(path: url.path, mode: .readWriteExisting)
        try db.execute("PRAGMA foreign_keys = ON")
        return db
    }

    private func tableNames(_ db: SQLiteDatabase) throws -> Set<String> {
        Set(try db.query("SELECT name FROM sqlite_master WHERE type = 'table'").compactMap { $0.string("name") })
    }

    /// Every schema object as `type|name|sql`, so two schemas can be compared exactly — including
    /// indexes, which a table-name comparison would miss.
    private func schemaObjects(_ db: SQLiteDatabase) throws -> Set<String> {
        Set(try db.query("SELECT type, name, IFNULL(sql, '') AS sql FROM sqlite_master")
            .map { "\($0.string("type") ?? "")|\($0.string("name") ?? "")|\($0.string("sql") ?? "")" })
    }

    /// A head (v24) store with one product to hang movements off.
    private func headStoreWithProduct(_ id: String = "p1") throws -> LedgerStore {
        let store = try makeStore()
        try store.db.run("INSERT INTO products (id, name, unit) VALUES (?, 'Widget', 'piece')", [.text(id)])
        return store
    }

    /// Insert a movement with only the columns a test cares about; everything else gets a legal value.
    @discardableResult
    private func insertMovement(_ db: SQLiteDatabase, id: String, product: String = "p1",
                                on date: String = "2026-08-01", seq: Int64 = 1,
                                type: String = "purchase_in",
                                quantity: SQLiteValue = .integer(10_000),
                                unitCost: SQLiteValue = .integer(100_000_000),
                                totalCost: SQLiteValue = .integer(100_000),
                                reverses: SQLiteValue = .null) throws -> Int {
        try db.run("""
            INSERT INTO inventory_movements
              (id, product_id, occurred_on, seq, movement_type, quantity_milli,
               unit_cost_micro, total_cost_minor, currency, reverses_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'CNY', ?)
            """, [.text(id), .text(product), .text(date), .integer(seq), .text(type),
                  quantity, unitCost, totalCost, reverses])
    }

    // MARK: - G · migration, idempotence, and the rollback round trip

    /// G1 — a real v23 Electron ledger migrates to v24, gains exactly the three tables, and
    /// carries the D-7(乙) evidence row.
    func testG1AV23LedgerReachesV24WithTheThreeInventoryTables() throws {
        let url = try v23Ledger()
        let db = try openRW(url)
        defer { try? db.close() }

        XCTAssertEqual(try db.userVersion(), 23, "the committed fixture is a genuine v23 file")
        let before = try tableNames(db)
        for t in inventoryTables { XCTAssertFalse(before.contains(t), "\(t) must not pre-exist at v23") }

        try SchemaMigrator.migrate(db)

        XCTAssertEqual(try db.userVersion(), SchemaMigrator.schemaVersion)
        let after = try tableNames(db)
        for t in inventoryTables { XCTAssertTrue(after.contains(t), "v24 must create \(t)") }
        XCTAssertEqual(after.subtracting(before), Set(inventoryTables),
                       "v24 adds THESE THREE tables and nothing else")

        // The one-way evidence row (D-7 案乙). JSON-encoded like every other settings value.
        XCTAssertEqual(try db.query("SELECT value FROM settings WHERE key = 'native_inventory_active'")
                          .first?.string("value"), "\"24\"")
    }

    /// G2 — the rung is idempotent in both senses: re-running `migrate` at head does nothing, and
    /// re-running the RUNG ITSELF (version rewound, tables already present) is not an error either.
    /// The second is the one that matters — it is what a resumed/retried migration does.
    func testG2TheV24RungIsIdempotent() throws {
        let url = try v23Ledger()
        let db = try openRW(url)
        defer { try? db.close() }
        try SchemaMigrator.migrate(db)
        let objectsAfterFirst = try schemaObjects(db)

        try SchemaMigrator.migrate(db)                       // no-op: already at head
        XCTAssertEqual(try db.userVersion(), SchemaMigrator.schemaVersion)
        XCTAssertEqual(try schemaObjects(db), objectsAfterFirst)

        try db.setUserVersion(23)                            // force the rung to run again
        try SchemaMigrator.migrate(db)
        XCTAssertEqual(try db.userVersion(), SchemaMigrator.schemaVersion)
        XCTAssertEqual(try schemaObjects(db), objectsAfterFirst,
                       "re-running the rung must not duplicate or alter a single object")
        XCTAssertEqual(try db.query("SELECT COUNT(*) AS c FROM settings WHERE key = 'native_inventory_active'")
                          .first?.int("c"), 1, "the evidence row is REPLACEd, not appended")
    }

    /// G3 — the declared rollback form is COMPLETE. Dropping the three tables and rewinding
    /// `user_version` must leave a schema with no v24 residue (the indexes go with their tables),
    /// must preserve the data, and re-migrating must reproduce v24 object-for-object.
    ///
    /// This is the test behind the PR's stop condition: if the rollback form ever stops being
    /// "DROP three tables + PRAGMA user_version = 23", this goes red.
    func testG3TheRollbackRoundTripIsComplete() throws {
        let url = try v23Ledger()
        let db = try openRW(url)
        defer { try? db.close() }
        try SchemaMigrator.migrate(db)
        let headObjects = try schemaObjects(db)

        // The ladder now runs past v24, so migrating lands at head and NOT at v24. Rewind the
        // rungs above v24 first, or the "v23" state this test constructs below still carries
        // them and the byte-identical comparison compares two v25 schemas to each other —
        // green, and proving nothing about v23. (D-1a added v25; its own rollback form is
        // pinned by `DocumentCurrencySchemaTests` G3, which is what makes this line safe to
        // rely on here.)
        try db.execute("""
            ALTER TABLE business_documents DROP COLUMN currency;
            PRAGMA user_version = 24;
            """)
        XCTAssertEqual(try db.userVersion(), 24, "the v24 baseline this test needs")

        let v24Objects = try schemaObjects(db)
        XCTAssertNotEqual(v24Objects, headObjects, """
            rewinding the rungs above v24 must actually change the schema — if it does not, this \
            test is comparing head to itself again and proves nothing about v23.
            """)
        let transactionsBefore = try db.query("SELECT COUNT(*) AS c FROM transactions").first?.int("c")

        // ── the rollback, exactly as documented ──
        try db.execute("""
            DROP TABLE inventory_movements;
            DROP TABLE inventory_balances;
            DROP TABLE inventory_exceptions;
            PRAGMA user_version = 23;
            """)

        XCTAssertEqual(try db.userVersion(), 23)
        let rolledBack = try schemaObjects(db)
        XCTAssertTrue(rolledBack.allSatisfy { !$0.contains("inventory_") },
                      "no v24 object may survive the rollback — indexes are dropped with their tables")
        XCTAssertEqual(rolledBack, v24Objects.filter { !$0.contains("inventory_") },
                       "and NOTHING ELSE may change: every v1…v23 object is byte-identical")
        XCTAssertEqual(try db.query("SELECT COUNT(*) AS c FROM transactions").first?.int("c"),
                       transactionsBefore, "the rollback touches no data")

        // ── and forward again ── (all the way to head, which is above v24 since D-1a)
        try SchemaMigrator.migrate(db)
        XCTAssertEqual(try db.userVersion(), SchemaMigrator.schemaVersion)
        XCTAssertEqual(try schemaObjects(db), headObjects, "the round trip reproduces head exactly")
    }

    /// G4 — `requiredTables` is the list every completeness check filters against, so the three
    /// new names have to be IN it and present at head, not merely created by the rung.
    func testG4TheInventoryTablesAreRequiredAtHead() throws {
        for t in inventoryTables {
            XCTAssertTrue(SchemaMigrator.requiredTables.contains(t), "\(t) missing from requiredTables")
        }
        XCTAssertEqual(SchemaMigrator.requiredTables.count, 29)

        let store = try makeStore()
        let present = try tableNames(store.db)
        for t in SchemaMigrator.requiredTables { XCTAssertTrue(present.contains(t), "head is missing \(t)") }
    }

    /// G5 — the payoff of G4: `PreparedImportRunner`'s schema gate now REFUSES a prepared library
    /// that claims head but has no inventory tables. Driven through the SHIPPING entry point, on a
    /// database built to look exactly like a tampered/partial prepare.
    func testG5ThePreparedImportGateRefusesAHeadLibraryWithoutTheInventoryTables() throws {
        // A head-version database with the three tables removed.
        let src = try trackedTempDir().appendingPathComponent("no-inventory.db")
        let build = try SQLiteDatabase(path: src.path, mode: .readWriteCreate)
        try build.execute("PRAGMA journal_mode = DELETE")
        try SchemaMigrator.migrate(build)
        try build.execute("""
            DROP TABLE inventory_movements;
            DROP TABLE inventory_balances;
            DROP TABLE inventory_exceptions;
            """)
        XCTAssertEqual(try build.userVersion(), SchemaMigrator.schemaVersion,
                       "it still CLAIMS head — only the tables are gone")
        try build.close()

        let staged = try trackedTempDir().appendingPathComponent("SoloLedger", isDirectory: true)
        try fm.createDirectory(at: staged, withIntermediateDirectories: true)
        try fm.copyItem(at: src, to: staged.appendingPathComponent("sololedger.db"))
        let importID = ImportID("inv-\(UUID().uuidString)")!
        defer { if let d = try? AppPaths.stagedImportDirectory(importID: importID) { try? fm.removeItem(at: d) } }
        let gated = try StagedSnapshotGate().gate(
            try StagingIngest().ingest(.userSelectedDataDir(staged), importID: importID, timestamp: "t"))

        let working = try trackedTempDir().appendingPathComponent("Upgrade", isDirectory: true)
        let prepared = try trackedTempDir().appendingPathComponent("PreparedImports", isDirectory: true)
        try fm.createDirectory(at: working, withIntermediateDirectories: true)
        try fm.createDirectory(at: prepared, withIntermediateDirectories: true)

        XCTAssertThrowsError(try PreparedImportRunner().run(gated, workingDirectory: working, preparedRoot: prepared)) { e in
            guard case PreparedRunFailure.schemaIncomplete(let missing) = e else {
                return XCTFail("expected .schemaIncomplete, got \(e)")
            }
            for t in inventoryTables { XCTAssertTrue(missing.contains(t), "gate did not name \(t): \(missing)") }
        }
    }

    // MARK: - H · the constraints are real at the storage layer

    /// H1 — STRICT refuses a value that cannot be stored in an INTEGER column, AND accepts one
    /// that converts losslessly. The second half is not padding: it is the documented carve-out
    /// STRICT does NOT close, measured on SQLite 3.51.0, and a reviewer who assumes "STRICT
    /// rejects all TEXT" would write the engine against a guarantee that does not exist.
    func testH1StrictRefusesUnstorableTextInAnIntegerColumnAndConvertsLosslessText() throws {
        let store = try headStoreWithProduct()

        XCTAssertThrowsError(try insertMovement(store.db, id: "m-bad", quantity: .text("abc")),
                             "TEXT that is not a number must be refused, not silently coerced")
        XCTAssertThrowsError(try insertMovement(store.db, id: "m-bad2", quantity: .text("")),
                             "and neither may the empty string become 0")

        // MEASURED carve-out: '5000' IS losslessly convertible, so STRICT stores INTEGER 5000.
        try insertMovement(store.db, id: "m-lossless", quantity: .text("5000"))
        XCTAssertEqual(try store.db.query("SELECT typeof(quantity_milli) AS t FROM inventory_movements WHERE id = 'm-lossless'")
                          .first?.string("t"), "integer",
                       "STRICT converts losslessly-convertible text rather than rejecting it (SQLite 3.51.0)")
    }

    /// H2 — the same rule for money: a fractional REAL cannot be stored in an INTEGER column, an
    /// integral one can. This is the storage-layer half of "money is integers" (N-8).
    func testH2StrictRefusesFractionalRealsInTheMoneyColumns() throws {
        let store = try headStoreWithProduct()

        XCTAssertThrowsError(try insertMovement(store.db, id: "m-frac", totalCost: .real(1.5)))
        XCTAssertThrowsError(try insertMovement(store.db, id: "m-frac2", unitCost: .real(0.5)))
        XCTAssertThrowsError(try insertMovement(store.db, id: "m-frac3", totalCost: .text("1.5")),
                             "text that parses to a fractional real is refused too")

        try insertMovement(store.db, id: "m-int", totalCost: .real(2.0))
        XCTAssertEqual(try store.db.query("SELECT typeof(total_cost_minor) AS t FROM inventory_movements WHERE id = 'm-int'")
                          .first?.string("t"), "integer")

        // N-7 / D-10: a MISSING inbound unit cost is representable (NULL) and distinct from an
        // explicit zero. The engine, not the schema, is what refuses the first and allows the
        // second — the schema's job is only to keep them tellable apart.
        try insertMovement(store.db, id: "m-null-cost", on: "2026-08-02", unitCost: .null)
        try insertMovement(store.db, id: "m-zero-cost", on: "2026-08-03", unitCost: .integer(0))
        let kinds = try store.db.query("""
            SELECT id, typeof(unit_cost_micro) AS t FROM inventory_movements
            WHERE id IN ('m-null-cost', 'm-zero-cost') ORDER BY id
            """).map { "\($0.string("id") ?? "")=\($0.string("t") ?? "")" }
        XCTAssertEqual(kinds, ["m-null-cost=null", "m-zero-cost=integer"])
    }

    /// H3 — both CHECK closed sets. Every declared member is accepted (so the engine can actually
    /// post all eight kinds) and anything outside is refused.
    func testH3TheMovementTypeAndExceptionKindClosedSetsHold() throws {
        let store = try headStoreWithProduct()

        let allTypes = ["purchase_in", "sale_out", "sale_return_in", "purchase_return_out",
                        "count_gain", "count_loss", "manual_adjust", "opening"]
        for (i, type) in allTypes.enumerated() {
            XCTAssertNoThrow(try insertMovement(store.db, id: "m-\(type)", seq: Int64(i + 1), type: type),
                             "\(type) is a declared movement type and must be postable")
        }
        for bad in ["teleport", "PURCHASE_IN", "", "purchase_in "] {
            XCTAssertThrowsError(try insertMovement(store.db, id: "m-bad-\(bad)", seq: 99, type: bad),
                                 "'\(bad)' is outside the closed set and must be refused")
        }

        for kind in ["return_origin_not_found", "manual_adjust", "opening_seeded"] {
            XCTAssertNoThrow(try store.db.run("INSERT INTO inventory_exceptions (id, kind) VALUES (?, ?)",
                                              [.text("x-\(kind)"), .text(kind)]))
        }
        XCTAssertThrowsError(try store.db.run("INSERT INTO inventory_exceptions (id, kind) VALUES ('x-bad', 'whatever')"))
    }

    /// H4 — D-6 案(b): `inventory_movements.product_id` is a real foreign key with ON DELETE
    /// RESTRICT. Both directions, plus the case that must still WORK: deleting a product that has
    /// no movements. Without that last one, RESTRICT could have been a blanket "products are
    /// undeletable" and the test would not notice.
    func testH4TheProductForeignKeyRestrictsBothWays() throws {
        let store = try headStoreWithProduct()
        try store.db.run("INSERT INTO products (id, name, unit) VALUES ('p2', 'Untouched', 'piece')")

        XCTAssertThrowsError(try insertMovement(store.db, id: "m-ghost", product: "ghost"),
                             "a movement may not reference a product that does not exist")

        try insertMovement(store.db, id: "m-real")
        XCTAssertThrowsError(try store.db.run("DELETE FROM products WHERE id = 'p1'"),
                             "a product with inventory movements may not be deleted")
        XCTAssertEqual(try store.db.query("SELECT COUNT(*) AS c FROM inventory_movements").first?.int("c"), 1,
                       "and the refused delete leaves the movement in place")

        XCTAssertNoThrow(try store.db.run("DELETE FROM products WHERE id = 'p2'"),
                         "a product with NO movements is still deletable — RESTRICT is not a blanket ban")
    }

    /// H5 — the two unique indexes. `reverses_id` is unique only where it is NOT NULL (a posted
    /// row may be reversed once; the many un-reversing rows are unconstrained), and
    /// `(product_id, occurred_on, seq)` is the total order the moving-average posting needs.
    func testH5TheReversalAndOrderingUniqueIndexesHold() throws {
        let store = try headStoreWithProduct()
        try store.db.run("INSERT INTO products (id, name, unit) VALUES ('p2', 'Other', 'piece')")
        try insertMovement(store.db, id: "m1")

        try insertMovement(store.db, id: "r1", on: "2026-09-01", type: "manual_adjust", reverses: .text("m1"))
        XCTAssertThrowsError(try insertMovement(store.db, id: "r2", on: "2026-09-02",
                                                type: "manual_adjust", reverses: .text("m1")),
                             "a posted movement may be reversed at most once")

        // NULL is not a value for a UNIQUE index: any number of non-reversing rows coexist.
        try insertMovement(store.db, id: "n1", on: "2026-10-01")
        XCTAssertNoThrow(try insertMovement(store.db, id: "n2", on: "2026-10-02"))

        XCTAssertThrowsError(try insertMovement(store.db, id: "dup", on: "2026-08-01", seq: 1),
                             "(product_id, occurred_on, seq) is unique — that ordering is what the posting order rests on")
        XCTAssertNoThrow(try insertMovement(store.db, id: "other-product", product: "p2", on: "2026-08-01", seq: 1),
                         "the same (date, seq) on a DIFFERENT product is legal — the order is per product")
    }

    // MARK: - L · the link to N-PR-0b — an in-place upgrade gets its rollback point

    /// L1 — the whole reason v24 could be written at all. A real v23 ledger opened through the
    /// SHIPPING hardened entry: it gets a `pre-migrate-v23-*` snapshot BEFORE the rung runs, then
    /// migrates; and the snapshot is restorable through the shipping restore chain.
    ///
    /// It also pins the recovery semantics the FEATURE_GAP declaration states, because they are
    /// easy to misread: what the snapshot restores is the pre-upgrade DATA, not a pre-upgrade
    /// SCHEMA. The bundle is at v23; re-opening it runs the ladder to head again.
    func testL1AnInPlaceV23UpgradeIsSnapshottedFirstAndTheSnapshotRestores() throws {
        // The hardened open refuses any symlink in the path; `/var/folders/…` is one, so
        // canonicalize exactly as `PreMigrationSnapshotTests` and `HardenedActiveOpenTests` do.
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        let raw = try trackedTempDir()
        let dir = realpath(raw.path, &buf) != nil
            ? URL(fileURLWithPath: String(cString: buf), isDirectory: true) : raw

        let active = dir.appendingPathComponent("active.db")
        try fm.copyItem(at: try fixtureURL(), to: active)
        XCTAssertEqual(try SQLiteDatabase(path: active.path, readOnly: true).userVersion(), 23)

        let backups = dir.appendingPathComponent("Backups", isDirectory: true)
        let plan = PreMigrationSnapshotPlan(backupsDirectory: backups,
                                            attachmentsDirectory: dir.appendingPathComponent("docs", isDirectory: true),
                                            timestamp: "2026-08-05-101112", retention: 3)
        guard case .captured(let evidence) = MigrationCoordinator.captureActiveEvidence(activeDestination: active) else {
            return XCTFail("could not capture active evidence")
        }

        let store = try LedgerStore.openActiveExistingHardened(databaseURL: active, expect: evidence, snapshot: plan)
        XCTAssertEqual(try store.schemaVersion(), SchemaMigrator.schemaVersion,
                       "the v24 rung ran on the live ledger")
        XCTAssertTrue(try tableNames(store.db).isSuperset(of: Set(inventoryTables)))
        try store.db.close()

        let dirs = ((try? fm.contentsOfDirectory(atPath: backups.path)) ?? [])
            .filter { $0.hasPrefix(PreMigrationSnapshot.namePrefix) }.sorted()
        XCTAssertEqual(dirs, ["pre-migrate-v23-2026-08-05-101112"],
                       "upgrading to v24 must leave exactly one rollback point, named for the version it came FROM")

        let bundle = backups.appendingPathComponent(dirs[0], isDirectory: true)
        XCTAssertNoThrow(try BackupRestore.validateBundle(bundle),
                         "a snapshot the restore chain refuses is a dead backup")

        // What the bundle holds: the PRE-upgrade state — v23, no inventory tables, data intact.
        let snapshotDB = try SQLiteDatabase(path: bundle.appendingPathComponent(AppPaths.databaseFileName).path,
                                            readOnly: true)
        XCTAssertEqual(try snapshotDB.userVersion(), 23)
        XCTAssertTrue(try tableNames(snapshotDB).isDisjoint(with: Set(inventoryTables)))
        XCTAssertEqual(try snapshotDB.query("SELECT COUNT(*) AS c FROM transactions").first?.int("c"), 7)
        try snapshotDB.close()

        // What restoring it GIVES BACK: the data, re-migrated to head. Restoring a pre-migrate
        // snapshot is not a way to get back to v23 — the ladder runs again on open.
        let restored = dir.appendingPathComponent("restored.db")
        try fm.copyItem(at: bundle.appendingPathComponent(AppPaths.databaseFileName), to: restored)
        let reopened = try LedgerStore(databaseURL: restored)
        defer { try? reopened.db.close() }
        XCTAssertEqual(try reopened.schemaVersion(), SchemaMigrator.schemaVersion)
        XCTAssertEqual(try reopened.listTransactions().count, 7)
    }
}
