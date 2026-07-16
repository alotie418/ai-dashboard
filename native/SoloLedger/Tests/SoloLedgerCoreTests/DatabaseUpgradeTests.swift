import XCTest
@testable import SoloLedgerCore

/// Exercises the full Electron→SwiftUI upgrade flow against the real v23 fixture:
/// normal upgrade, corrupted DB, unknown version, backup failure, and a mid-flight
/// interruption — plus WAL-consistent backup. The original is never modified.
final class DatabaseUpgradeTests: LedgerTestCase {

    private struct Boom: Error {}

    private func makePaths(source: URL) throws -> DatabaseUpgrade.Paths {
        let work = try trackedTempDir()
        return DatabaseUpgrade.Paths(
            legacySource: source,
            activeDestination: work.appendingPathComponent("native/sololedger.db"),
            backupsDirectory: work.appendingPathComponent("Backups"),
            workingDirectory: work.appendingPathComponent("Upgrade")
        )
    }

    private func fileSize(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
    }

    // MARK: - Normal upgrade

    func testNormalUpgrade() throws {
        let source = try electronFixtureCopy()
        let sizeBefore = fileSize(source)
        let paths = try makePaths(source: source)

        let outcome = try DatabaseUpgrade(paths: paths, timestamp: "T1").run()
        guard case let .upgraded(backupPath, migrated) = outcome else {
            return XCTFail("expected .upgraded, got \(outcome)")
        }
        XCTAssertEqual(migrated, 7)

        // Destination opens with all data intact.
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.activeDestination.path))
        let store = try LedgerStore(databaseURL: paths.activeDestination)
        XCTAssertEqual(try store.schemaVersion(), 23)
        XCTAssertEqual(try store.listTransactions().count, 7)
        XCTAssertEqual(try store.summary().net, 2850.01, accuracy: 0.001)

        // Backup exists, is valid and complete.
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupPath))
        let backup = try SQLiteDatabase(path: backupPath, readOnly: true)
        XCTAssertTrue(try backup.quickCheck())
        XCTAssertEqual(try backup.userVersion(), 23)
        XCTAssertEqual(try backup.query("SELECT COUNT(*) c FROM transactions").first?.int("c"), 7)

        // Original never modified.
        XCTAssertEqual(sizeBefore, fileSize(source), "original file size changed")
        XCTAssertEqual(try SQLiteDatabase(path: source.path, readOnly: true).userVersion(), 23)
    }

    // MARK: - Corrupted database

    func testCorruptedDatabaseRejected() throws {
        let source = try electronFixtureCopy()
        let handle = try FileHandle(forWritingTo: source)
        try handle.seek(toOffset: 8192)
        try handle.write(contentsOf: Data(repeating: 0xEE, count: 4096))  // clobber a b-tree page
        try handle.truncate(atOffset: 24576)                              // + page-count/size mismatch
        try handle.close()

        let paths = try makePaths(source: source)
        XCTAssertThrowsError(try DatabaseUpgrade(paths: paths, timestamp: "T2").run()) { error in
            guard case DatabaseUpgrade.Failure.integrityFailed = error else {
                return XCTFail("expected .integrityFailed, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.activeDestination.path))
    }

    // MARK: - Unknown / newer schema version

    func testUnknownVersionRejected() throws {
        let source = try electronFixtureCopy()
        try SQLiteDatabase(path: source.path).setUserVersion(99)   // pretend it came from a newer app

        let paths = try makePaths(source: source)
        XCTAssertThrowsError(try DatabaseUpgrade(paths: paths, timestamp: "T3").run()) { error in
            guard case let DatabaseUpgrade.Failure.unknownVersion(found, supported) = error else {
                return XCTFail("expected .unknownVersion, got \(error)")
            }
            XCTAssertEqual(found, 99)
            XCTAssertEqual(supported, 23)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.activeDestination.path))
    }

    // MARK: - Backup failure

    func testBackupFailureAborts() throws {
        let source = try electronFixtureCopy()
        let paths = try makePaths(source: source)
        try FileManager.default.createDirectory(at: paths.backupsDirectory, withIntermediateDirectories: true)
        // Read-only backups dir → the snapshot file cannot be created.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: paths.backupsDirectory.path)

        XCTAssertThrowsError(try DatabaseUpgrade(paths: paths, timestamp: "T4").run()) { error in
            guard case DatabaseUpgrade.Failure.backupFailed = error else {
                return XCTFail("expected .backupFailed, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.activeDestination.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "original must survive")
    }

    // MARK: - Interruption mid-upgrade + idempotent recovery

    func testInterruptedBeforeSwapRollsBackAndRecovers() throws {
        let source = try electronFixtureCopy()
        let paths = try makePaths(source: source)

        let hooks = DatabaseUpgrade.Hooks(beforeSwap: { throw Boom() })
        XCTAssertThrowsError(try DatabaseUpgrade(paths: paths, hooks: hooks, timestamp: "T5").run()) { error in
            guard case DatabaseUpgrade.Failure.interrupted = error else {
                return XCTFail("expected .interrupted, got \(error)")
            }
        }
        // No destination; working copy cleaned; backup already taken; source intact.
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.activeDestination.path))
        let working = (try? FileManager.default.contentsOfDirectory(atPath: paths.workingDirectory.path)) ?? []
        XCTAssertTrue(working.filter { $0.hasSuffix(".db") }.isEmpty, "working copy left behind")
        let backups = (try? FileManager.default.contentsOfDirectory(atPath: paths.backupsDirectory.path)) ?? []
        XCTAssertFalse(backups.isEmpty, "pre-swap backup should exist")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))

        // A clean re-run recovers (destination still absent → discover runs again).
        let outcome = try DatabaseUpgrade(paths: paths, timestamp: "T6").run()
        guard case .upgraded = outcome else { return XCTFail("re-run should succeed, got \(outcome)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.activeDestination.path))
    }

    // MARK: - WAL-consistent backup (req #6: no raw copy of a live WAL db)

    func testBackupCapturesUncheckpointedWALRows() throws {
        let source = try electronFixtureCopy()
        let db = try SQLiteDatabase(path: source.path)
        try db.execute("PRAGMA journal_mode = WAL")
        try db.execute("PRAGMA wal_autocheckpoint = 0")     // keep the new row only in -wal
        try db.run("INSERT INTO transactions (id, type, date, amount, currency) VALUES ('wal-row','income','2026-03-01',77,'CNY')")

        let dest = try trackedTempDir().appendingPathComponent("walbackup.db")
        try db.backup(toPath: dest.path)                     // Backup API sees the live WAL view

        // The backup inherits the source's WAL header, so open it read-write.
        let check = try SQLiteDatabase(path: dest.path)
        XCTAssertEqual(try check.query("SELECT COUNT(*) c FROM transactions WHERE id='wal-row'").first?.int("c"), 1,
                       "consistent backup must include un-checkpointed WAL rows")
    }

    // MARK: - No legacy data / already upgraded

    func testNoLegacyData() throws {
        let work = try trackedTempDir()
        let paths = DatabaseUpgrade.Paths(
            legacySource: work.appendingPathComponent("absent.db"),
            activeDestination: work.appendingPathComponent("native.db"),
            backupsDirectory: work.appendingPathComponent("B"),
            workingDirectory: work.appendingPathComponent("W"))
        XCTAssertEqual(try DatabaseUpgrade(paths: paths, timestamp: "T7").run(), .noLegacyData)
    }

    func testAlreadyUpgradedIsNoOp() throws {
        let paths = try makePaths(source: try electronFixtureCopy())
        _ = try DatabaseUpgrade(paths: paths, timestamp: "T8").run()
        XCTAssertEqual(try DatabaseUpgrade(paths: paths, timestamp: "T9").run(), .alreadyUpgraded)
    }
}
