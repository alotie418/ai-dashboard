import XCTest
@testable import SoloLedgerCore

/// D-1a: schema v25 — `business_documents.currency`, the second native-only rung.
///
/// The ruling is `docs/BUSINESS_DOCUMENTS_SPEC.md` Q2-d-② (and the Q8 exception it activates):
/// one **nullable** `TEXT` column, **no `CHECK`**, **no `DEFAULT`**. D-1 has since landed the one
/// writer the ruling allows — `LedgerStore.statementDrafts`, whose per-currency documents each
/// record their own currency (`StatementGeneratorTests`); every other document type still leaves it
/// `NULL`, which is what the tests below keep measuring. Every expectation here traces to that
/// ruling or to MEASURED SQLite behaviour, and the measured ones say so at the assertion.
///
/// Organised the way ``InventorySchemaTests`` is, because it protects the same three properties:
///
///  * **G** — the rung itself: a v24 ledger reaches head gaining exactly one column, the rung is
///    idempotent, and the declared rollback form (`DROP COLUMN` + `PRAGMA user_version = 24`) is
///    COMPLETE. G3 does the round trip and compares `sqlite_master`, because "purely additive" is
///    a claim about schema objects and nothing weaker proves it.
///  * **H** — the three column properties are real at the storage layer, each asserted in the
///    direction that would catch its opposite: nullable (a row without it lands `NULL`), no
///    DEFAULT (`dflt_value` is absent, so `NULL` means "follow `acc_locale`" rather than a value
///    somebody never chose), no CHECK (an arbitrary string is accepted — and the same is measured
///    of every other `currency` column, which is the convention this one follows).
///  * **L** — the in-place upgrade: a LIVE v24 ledger opened through the shipping hardened entry
///    gets its `pre-migrate-v24-*` snapshot BEFORE the rung runs, and that snapshot is restorable
///    through the shipping restore chain. No new mechanism — this rung only had to confirm the
///    one v24 built covers it.
final class DocumentCurrencySchemaTests: LedgerTestCase {

    private let fm = FileManager.default

    /// SQLite gained `ALTER TABLE … DROP COLUMN` in 3.35.0. The rollback form in G3 needs it.
    /// Measured on this machine at the time of writing: 3.51.0.
    private let dropColumnFloor = 3_035_000

    // MARK: - Fixtures and helpers

    private func openRW(_ url: URL) throws -> SQLiteDatabase {
        let db = try SQLiteDatabase(path: url.path, mode: .readWriteExisting)
        try db.execute("PRAGMA foreign_keys = ON")
        return db
    }

    /// Every schema object as `type|name|sql`, so two schemas can be compared exactly.
    private func schemaObjects(_ db: SQLiteDatabase) throws -> Set<String> {
        Set(try db.query("SELECT type, name, IFNULL(sql, '') AS sql FROM sqlite_master")
            .map { "\($0.string("type") ?? "")|\($0.string("name") ?? "")|\($0.string("sql") ?? "")" })
    }

    private func columns(_ db: SQLiteDatabase, _ table: String) throws -> [String] {
        try db.query("PRAGMA table_info(\(table))").compactMap { $0.string("name") }
    }

    private func sqliteVersionNumber(_ db: SQLiteDatabase) throws -> Int {
        let text = try db.query("SELECT sqlite_version() AS v").first?.string("v") ?? ""
        let parts = text.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 3 else { return 0 }
        return parts[0] * 1_000_000 + parts[1] * 1_000 + parts[2]
    }

    /// The declared rollback form, applied to a head database to produce a v24 one.
    ///
    /// This is how every v24 ledger in this file is built, and it is not circular with G3: G3
    /// proves the form is complete by comparing `sqlite_master` before and after the round trip,
    /// so once G3 is green this construction is known to produce the v24 shape and not merely
    /// something that resembles it. There is no other way to get a v24 file — the migrator only
    /// runs forward, and to head.
    private func rollBackToV24(_ db: SQLiteDatabase) throws {
        try db.execute("""
            ALTER TABLE business_documents DROP COLUMN currency;
            PRAGMA user_version = 24;
            """)
    }

    /// A real Electron v23 fixture migrated to head and then rolled back one rung.
    private func v24Ledger(named name: String = "v24.db") throws -> URL {
        let url = try electronFixtureCopy(named: name)
        let db = try openRW(url)
        try SchemaMigrator.migrate(db)
        try rollBackToV24(db)
        try db.close()
        return url
    }

    /// Insert a document with only the columns the table demands.
    private func insertDocument(_ db: SQLiteDatabase, id: String, number: String,
                                currency: SQLiteValue? = nil) throws {
        if let currency {
            try db.run("""
                INSERT INTO business_documents (id, doc_type, doc_number, doc_date, customer_name, currency)
                VALUES (?, 'quotation', ?, '2026-08-01', 'Acme', ?)
                """, [.text(id), .text(number), currency])
        } else {
            try db.run("""
                INSERT INTO business_documents (id, doc_type, doc_number, doc_date, customer_name)
                VALUES (?, 'quotation', ?, '2026-08-01', 'Acme')
                """, [.text(id), .text(number)])
        }
    }

    // MARK: - G · the rung, idempotence, and the rollback round trip

    /// G1 — a v24 ledger reaches head, and the ONLY thing that changed anywhere in the schema is
    /// that `business_documents` gained `currency`. Not "the column appeared": nothing else moved.
    func testG1AV24LedgerReachesHeadGainingExactlyTheCurrencyColumn() throws {
        let url = try v24Ledger()
        let db = try openRW(url)
        defer { try? db.close() }

        XCTAssertEqual(try db.userVersion(), 24, "the fixture starts one rung below head")
        let before = try schemaObjects(db)
        let columnsBefore = try columns(db, "business_documents")
        XCTAssertFalse(columnsBefore.contains("currency"), "v24 must not already have the column")

        try SchemaMigrator.migrate(db)

        XCTAssertEqual(try db.userVersion(), SchemaMigrator.schemaVersion)
        let columnsAfter = try columns(db, "business_documents")
        XCTAssertEqual(columnsAfter, columnsBefore + ["currency"],
                       "the column is APPENDED and no existing column moved or changed name")

        // The whole-schema difference: exactly one object's SQL, and it is this table's.
        let after = try schemaObjects(db)
        XCTAssertEqual(after.count, before.count, "the rung adds no schema OBJECT, only a column")
        let changed = after.subtracting(before)
        XCTAssertEqual(changed.count, 1, "exactly one object's definition may differ; changed: \(changed)")
        XCTAssertTrue(changed.first?.hasPrefix("table|business_documents|") == true,
                      "and it must be business_documents; got \(changed)")
        XCTAssertEqual(before.subtracting(after).count, 1, "…the same object, in its old form")
    }

    /// G2 — the rung is idempotent, in both the shapes that matter: re-running the migrator at
    /// head, and forcing `user_version` back so the rung itself executes a second time. SQLite has
    /// no `ADD COLUMN IF NOT EXISTS`, so a rung written as a raw `ALTER` would throw here.
    func testG2TheV25RungIsIdempotent() throws {
        let url = try v24Ledger()
        let db = try openRW(url)
        defer { try? db.close() }
        try SchemaMigrator.migrate(db)
        let objectsAfterFirst = try schemaObjects(db)
        let columnsAfterFirst = try columns(db, "business_documents")

        try SchemaMigrator.migrate(db)                       // no-op: already at head
        XCTAssertEqual(try db.userVersion(), SchemaMigrator.schemaVersion)
        XCTAssertEqual(try schemaObjects(db), objectsAfterFirst)

        try db.setUserVersion(24)                            // force the rung to run again
        try SchemaMigrator.migrate(db)
        XCTAssertEqual(try db.userVersion(), SchemaMigrator.schemaVersion)
        XCTAssertEqual(try schemaObjects(db), objectsAfterFirst,
                       "re-running the rung must not alter a single object")
        XCTAssertEqual(try columns(db, "business_documents"), columnsAfterFirst,
                       "and must not add a second currency column")
        XCTAssertEqual(columnsAfterFirst.filter { $0 == "currency" }.count, 1)
    }

    /// G3 — the declared rollback form is COMPLETE: dropping the column and rewinding
    /// `user_version` leaves a schema with no v25 residue, preserves the data, and re-migrating
    /// reproduces head object-for-object.
    ///
    /// This is the test behind the PR's stop condition: if the rollback form ever stops being
    /// "DROP COLUMN currency + PRAGMA user_version = 24", this goes red.
    func testG3TheRollbackRoundTripIsComplete() throws {
        let url = try electronFixtureCopy(named: "roundtrip.db")
        let db = try openRW(url)
        defer { try? db.close() }

        XCTAssertGreaterThanOrEqual(
            try sqliteVersionNumber(db), dropColumnFloor,
            """
            this SQLite predates ALTER TABLE … DROP COLUMN (3.35.0), so the rollback form declared \
            for v25 cannot be executed here. The form would have to become a full table rebuild.
            """)

        try SchemaMigrator.migrate(db)
        let headObjects = try schemaObjects(db)
        try insertDocument(db, id: "d1", number: "QT-2026-0001")
        let documentsBefore = try db.query("SELECT COUNT(*) AS c FROM business_documents").first?.int("c")
        let transactionsBefore = try db.query("SELECT COUNT(*) AS c FROM transactions").first?.int("c")

        // ── the rollback, exactly as documented ──
        try rollBackToV24(db)

        XCTAssertEqual(try db.userVersion(), 24)
        XCTAssertFalse(try columns(db, "business_documents").contains("currency"),
                       "no v25 residue may survive the rollback")
        let rolledBack = try schemaObjects(db)
        XCTAssertEqual(rolledBack.count, headObjects.count, "the rollback drops no schema object")
        XCTAssertEqual(rolledBack.subtracting(headObjects).count, 1,
                       "exactly one object differs — business_documents, without the column")
        XCTAssertEqual(rolledBack.filter { $0.hasPrefix("table|business_documents|") }.count, 1)
        XCTAssertEqual(rolledBack.filter { !$0.hasPrefix("table|business_documents|") },
                       headObjects.filter { !$0.hasPrefix("table|business_documents|") },
                       "and NOTHING ELSE may change: every other object is byte-identical")
        XCTAssertEqual(try db.query("SELECT COUNT(*) AS c FROM business_documents").first?.int("c"),
                       documentsBefore, "the rollback touches no document row")
        XCTAssertEqual(try db.query("SELECT COUNT(*) AS c FROM transactions").first?.int("c"),
                       transactionsBefore, "…and no other data either")

        // ── and forward again ──
        try SchemaMigrator.migrate(db)
        XCTAssertEqual(try db.userVersion(), SchemaMigrator.schemaVersion)
        XCTAssertEqual(try schemaObjects(db), headObjects, "the round trip reproduces head exactly")
        XCTAssertNil(try db.query("SELECT currency FROM business_documents WHERE id = 'd1'")
                        .first?.string("currency"),
                     "the row that survived the round trip comes back with NULL, not a value")
    }

    /// G4 — a ledger created fresh at head has the column too. G1 proves the rung ADDS it to an
    /// existing file; this proves the ladder as a whole DELIVERS it, which is what every new
    /// install gets.
    func testG4AFreshLedgerHasTheColumnAtHead() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        XCTAssertEqual(try store.schemaVersion(), SchemaMigrator.schemaVersion)
        XCTAssertTrue(try columns(store.db, "business_documents").contains("currency"))
    }

    // MARK: - H · the column's three declared properties, at the storage layer

    /// H1 — nullable, in both directions: a row that omits the column is accepted and reads back
    /// `NULL`, and an explicit `NULL` is accepted too. A `NOT NULL` column would reject both.
    func testH1TheColumnIsNullableAndAnOmittedValueReadsBackAsNull() throws {
        let store = try makeStore()
        defer { try? store.db.close() }

        try insertDocument(store.db, id: "d1", number: "QT-1")
        try insertDocument(store.db, id: "d2", number: "QT-2", currency: .null)

        for id in ["d1", "d2"] {
            let row = try store.db.query("SELECT currency FROM business_documents WHERE id = ?", [.text(id)]).first
            XCTAssertNotNil(row, "\(id) was not inserted")
            XCTAssertNil(row?.string("currency"), "\(id) must read back NULL")
        }
        let notNull = try store.db.query("PRAGMA table_info(business_documents)")
            .first { $0.string("name") == "currency" }?.int("notnull")
        XCTAssertEqual(notNull, 0, "the column is declared nullable")
    }

    /// H2 — no `DEFAULT`. This is the property that makes `NULL` mean something: the ruling says
    /// `NULL` = "derive the display currency from `acc_locale`", and a DEFAULT would make every
    /// new row claim a currency nobody chose.
    func testH2TheColumnHasNoDefaultSoNullIsAValueRatherThanAGap() throws {
        let store = try makeStore()
        defer { try? store.db.close() }

        let info = try store.db.query("PRAGMA table_info(business_documents)")
            .first { $0.string("name") == "currency" }
        XCTAssertNotNil(info, "the column is missing entirely")
        XCTAssertNil(info?.string("dflt_value"), "the column declares a DEFAULT")

        // …and the observable consequence, which is what actually matters.
        try insertDocument(store.db, id: "d1", number: "QT-1")
        XCTAssertNil(try store.db.query("SELECT currency FROM business_documents WHERE id = 'd1'")
                        .first?.string("currency"))
    }

    /// H3 — no `CHECK`. Asserted three ways, because "there is no constraint" is exactly the claim
    /// a green test can make vacuously: the table's own SQL carries no CHECK naming the column, an
    /// arbitrary string is accepted at the storage layer, and — the part that makes this a
    /// convention rather than an oversight — no OTHER `currency` column in this schema has one
    /// either. That last one is measured here rather than quoted from the spec.
    func testH3TheColumnHasNoCheckAndNeitherDoesAnyOtherCurrencyColumn() throws {
        let store = try makeStore()
        defer { try? store.db.close() }

        let sql = try store.db.query("SELECT sql FROM sqlite_master WHERE type='table' AND name='business_documents'")
            .first?.string("sql") ?? ""
        XCTAssertFalse(sql.isEmpty, "business_documents has no SQL in sqlite_master")
        XCTAssertTrue(sql.contains("currency"), "…and the scan below would prove nothing")
        XCTAssertNil(sql.range(of: "CHECK", options: [.caseInsensitive], range: sql.range(of: "currency")!.upperBound..<sql.endIndex),
                     "a CHECK follows the currency column in: \(sql)")

        // A value no currency table would recognise. The ruling is that this column constrains
        // nothing; the statement generator, not the schema, decides what it writes.
        try insertDocument(store.db, id: "d1", number: "QT-1", currency: .text("not-a-currency"))
        XCTAssertEqual(try store.db.query("SELECT currency FROM business_documents WHERE id = 'd1'")
                        .first?.string("currency"), "not-a-currency")

        // The convention, measured across the whole schema.
        let tablesWithCurrency = try store.db.query("""
            SELECT name, sql FROM sqlite_master WHERE type='table' AND sql LIKE '%currency%'
            """).map { ($0.string("name") ?? "", $0.string("sql") ?? "") }
        XCTAssertGreaterThanOrEqual(tablesWithCurrency.count, 3,
                                    "expected several currency-bearing tables; found \(tablesWithCurrency.map(\.0))")
        for (name, tableSQL) in tablesWithCurrency {
            guard let start = tableSQL.range(of: "currency")?.upperBound else { continue }
            let tail = tableSQL[start...].prefix(60)
            XCTAssertFalse(tail.uppercased().contains("CHECK"),
                           "\(name).currency carries a CHECK — the convention this column follows just changed")
        }
    }

    /// H4 — the rows that existed BEFORE the rung come out with `NULL`, i.e. keeping exactly the
    /// meaning they had. This is the sentence in the ruling that says no existing document's
    /// behaviour changes, turned into a measurement.
    func testH4DocumentsThatPredateTheRungKeepTheirMeaningAsNull() throws {
        let url = try v24Ledger(named: "predating.db")
        let db = try openRW(url)
        defer { try? db.close() }

        try insertDocument(db, id: "old1", number: "QT-OLD-1")
        try insertDocument(db, id: "old2", number: "QT-OLD-2")

        try SchemaMigrator.migrate(db)

        let rows = try db.query("SELECT id, currency FROM business_documents ORDER BY id")
        XCTAssertEqual(rows.count, 2)
        for row in rows {
            XCTAssertNil(row.string("currency"),
                         "\(row.string("id") ?? "?") gained a currency it never had")
        }
    }

    // MARK: - L · the in-place upgrade of a live ledger

    /// L1 — a LIVE v24 ledger opened through the SHIPPING hardened entry gets a
    /// `pre-migrate-v24-*` snapshot BEFORE the rung runs, and the snapshot is restorable through
    /// the shipping restore chain.
    ///
    /// The mechanism is v24's (`PreMigrationSnapshot`); D-1a builds nothing new. What this test
    /// establishes is that it COVERS the new rung — the snapshot trigger is
    /// `from < SchemaMigrator.schemaVersion`, so a rung that raises head brings its own coverage,
    /// and the directory is named for the version it came FROM, which is now 24 rather than 23.
    func testL1AnInPlaceV24UpgradeIsSnapshottedFirstAndTheSnapshotRestores() throws {
        // The hardened open refuses any symlink in the path; `/var/folders/…` is one, so
        // canonicalize exactly as the v24 suite does.
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        let raw = try trackedTempDir()
        let dir = realpath(raw.path, &buf) != nil
            ? URL(fileURLWithPath: String(cString: buf), isDirectory: true) : raw

        let active = dir.appendingPathComponent("active.db")
        try fm.copyItem(at: try v24Ledger(named: "live.db"), to: active)
        let probe = try SQLiteDatabase(path: active.path, readOnly: true)
        XCTAssertEqual(try probe.userVersion(), 24)
        XCTAssertFalse(try columns(probe, "business_documents").contains("currency"))
        let transactionsBefore = try probe.query("SELECT COUNT(*) AS c FROM transactions").first?.int("c")
        try probe.close()

        let backups = dir.appendingPathComponent("Backups", isDirectory: true)
        let plan = PreMigrationSnapshotPlan(backupsDirectory: backups,
                                            attachmentsDirectory: dir.appendingPathComponent("docs", isDirectory: true),
                                            timestamp: "2026-08-17-090000", retention: 3)
        guard case .captured(let evidence) = MigrationCoordinator.captureActiveEvidence(activeDestination: active) else {
            return XCTFail("could not capture active evidence")
        }

        let store = try LedgerStore.openActiveExistingHardened(databaseURL: active, expect: evidence, snapshot: plan)
        XCTAssertEqual(try store.schemaVersion(), SchemaMigrator.schemaVersion, "the v25 rung ran on the live ledger")
        XCTAssertTrue(try columns(store.db, "business_documents").contains("currency"))
        try store.db.close()

        let dirs = ((try? fm.contentsOfDirectory(atPath: backups.path)) ?? [])
            .filter { $0.hasPrefix(PreMigrationSnapshot.namePrefix) }.sorted()
        XCTAssertEqual(dirs, ["pre-migrate-v24-2026-08-17-090000"],
                       "upgrading to v25 must leave exactly one rollback point, named for the version it came FROM")

        let bundle = backups.appendingPathComponent(dirs[0], isDirectory: true)
        XCTAssertNoThrow(try BackupRestore.validateBundle(bundle),
                         "a snapshot the restore chain refuses is a dead backup")

        // What the bundle holds: the PRE-upgrade state — v24, no currency column, data intact.
        let snapshotDB = try SQLiteDatabase(path: bundle.appendingPathComponent(AppPaths.databaseFileName).path,
                                            readOnly: true)
        XCTAssertEqual(try snapshotDB.userVersion(), 24)
        XCTAssertFalse(try columns(snapshotDB, "business_documents").contains("currency"))
        XCTAssertEqual(try snapshotDB.query("SELECT COUNT(*) AS c FROM transactions").first?.int("c"),
                       transactionsBefore)
        try snapshotDB.close()

        // What restoring it GIVES BACK: the data, re-migrated to head. Restoring a pre-migrate
        // snapshot is not a way to get back to v24 — the ladder runs again on open.
        let restored = dir.appendingPathComponent("restored.db")
        try fm.copyItem(at: bundle.appendingPathComponent(AppPaths.databaseFileName), to: restored)
        let reopened = try LedgerStore(databaseURL: restored)
        defer { try? reopened.db.close() }
        XCTAssertEqual(try reopened.schemaVersion(), SchemaMigrator.schemaVersion)
        XCTAssertEqual(try reopened.listTransactions().count, transactionsBefore)
    }
}
