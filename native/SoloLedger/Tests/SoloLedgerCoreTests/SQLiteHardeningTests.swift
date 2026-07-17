import XCTest
@testable import SoloLedgerCore

/// SQLite open-mode + explicit close() hardening, and SchemaMigrator negative-version /
/// required-table guards (Phase 2B-3 C3 primitives). Synthetic temp DBs only.
final class SQLiteHardeningTests: LedgerTestCase {

    private let fm = FileManager.default

    // MARK: - Open modes

    func testReadWriteExistingNeverCreatesAnEmptyDatabase() throws {
        let url = try trackedTempDir().appendingPathComponent("absent.db")
        XCTAssertThrowsError(try SQLiteDatabase(path: url.path, mode: .readWriteExisting),
                             "opening an absent file read-write-EXISTING must fail closed") { e in
            guard case SQLiteError.open = e else { return XCTFail("got \(e)") }
        }
        XCTAssertFalse(fm.fileExists(atPath: url.path), "no empty database may be fabricated")
    }

    func testReadWriteCreateStillCreates() throws {
        let url = try trackedTempDir().appendingPathComponent("fresh.db")
        let db = try SQLiteDatabase(path: url.path, mode: .readWriteCreate)
        try db.execute("PRAGMA user_version = 1")
        try db.close()
        XCTAssertTrue(fm.fileExists(atPath: url.path))
    }

    func testReadWriteExistingOpensAnExistingDatabase() throws {
        let url = try trackedTempDir().appendingPathComponent("exists.db")
        do { let d = try SQLiteDatabase(path: url.path, mode: .readWriteCreate); try d.execute("PRAGMA user_version = 7"); try d.close() }
        let db = try SQLiteDatabase(path: url.path, mode: .readWriteExisting)
        XCTAssertEqual(try db.userVersion(), 7)
        try db.close()
    }

    // MARK: - Explicit close()

    func testCloseIsIdempotentAndReleasesTheConnection() throws {
        let url = try trackedTempDir().appendingPathComponent("c.db")
        let db = try SQLiteDatabase(path: url.path, mode: .readWriteCreate)
        try db.execute("CREATE TABLE t (id INTEGER)")
        try db.close()
        XCTAssertNoThrow(try db.close(), "second close is a no-op")
        // After close, further use fails visibly (connection released).
        XCTAssertThrowsError(try db.execute("SELECT 1"))
    }

    // MARK: - SchemaMigrator hardening

    func testMigrateRejectsNegativeVersionWithoutTrapping() throws {
        let url = try trackedTempDir().appendingPathComponent("neg.db")
        let db = try SQLiteDatabase(path: url.path, mode: .readWriteCreate)
        try db.execute("PRAGMA user_version = -5")
        XCTAssertThrowsError(try SchemaMigrator.migrate(db)) { e in
            guard case SchemaMigrator.MigrationError.corruptVersion(let f) = e else { return XCTFail("got \(e)") }
            XCTAssertEqual(f, -5)
        }
        try db.close()
    }

    func testMigrateRejectsNewerThanSupported() throws {
        let url = try trackedTempDir().appendingPathComponent("new.db")
        let db = try SQLiteDatabase(path: url.path, mode: .readWriteCreate)
        try db.execute("PRAGMA user_version = 99")
        XCTAssertThrowsError(try SchemaMigrator.migrate(db)) { e in
            guard case SchemaMigrator.MigrationError.newerThanSupported = e else { return XCTFail("got \(e)") }
        }
        try db.close()
    }

    /// The central required-table list must be exactly the tables the ladder builds at head,
    /// so the runner's completeness check can never drift from the schema.
    func testRequiredTablesMatchLadderHead() throws {
        XCTAssertEqual(SchemaMigrator.requiredTables.count, 26, "26 tables at head")
        let url = try trackedTempDir().appendingPathComponent("head.db")
        let db = try SQLiteDatabase(path: url.path, mode: .readWriteCreate)
        try SchemaMigrator.migrate(db)
        XCTAssertEqual(try db.userVersion(), SchemaMigrator.schemaVersion)
        let present = Set(try db.query("SELECT name FROM sqlite_master WHERE type='table'").compactMap { $0.string("name") })
        XCTAssertEqual(Set(SchemaMigrator.requiredTables), Set(SchemaMigrator.requiredTables).intersection(present),
                       "every required table must exist at head")
        // No required table is missing; and none is a duplicate.
        XCTAssertEqual(SchemaMigrator.requiredTables.count, Set(SchemaMigrator.requiredTables).count, "no duplicates")
        for t in SchemaMigrator.requiredTables { XCTAssertTrue(present.contains(t), "ladder head missing \(t)") }
        try db.close()
    }
}
