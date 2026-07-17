import XCTest
@testable import SoloLedgerCore

/// Staging-sourced prepared-DB runner (Phase 2B-3 C3): copy the gated staged DB/WAL through
/// the gate descriptor into a private attempt, normalize (checkpoint→DELETE→quick_check),
/// gate the version, migrate to head, verify integrity/FK/all-26-tables, then compute the
/// identity on a closed, sidecar-free file and publish it atomically. Real SQLite fixtures.
final class PreparedImportRunnerTests: LedgerTestCase {

    private let fm = FileManager.default

    // MARK: - Fixtures

    /// Publish a genuine staging from `sourceDB` (+ optional sibling WAL / attachments) and gate it.
    private func gatedFixture(sourceDB: URL, withWAL: Bool = false,
                              attachments: [(String, String)] = []) throws -> (gated: GatedStagedSnapshot, id: ImportID) {
        let src = try trackedTempDir().appendingPathComponent("SoloLedger", isDirectory: true)
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try fm.copyItem(at: sourceDB, to: src.appendingPathComponent("sololedger.db"))
        if withWAL {
            let srcWal = URL(fileURLWithPath: sourceDB.path + "-wal")
            try fm.copyItem(at: srcWal, to: URL(fileURLWithPath: src.appendingPathComponent("sololedger.db").path + "-wal"))
        }
        if !attachments.isEmpty {
            let docs = src.appendingPathComponent("attachments", isDirectory: true).appendingPathComponent("docs", isDirectory: true)
            try fm.createDirectory(at: docs, withIntermediateDirectories: true)
            for (n, b) in attachments { try Data(b.utf8).write(to: docs.appendingPathComponent(n)) }
        }
        let id = ImportID("run-\(UUID().uuidString)")!
        let result = try StagingIngest().ingest(.userSelectedDataDir(src), importID: id, timestamp: "t")
        return (try StagedSnapshotGate().gate(result), id)
    }

    private func workingRoot() throws -> URL {
        let d = try trackedTempDir().appendingPathComponent("Upgrade", isDirectory: true)
        try fm.createDirectory(at: d, withIntermediateDirectories: true); return d
    }
    private func preparedRoot() throws -> URL {
        let d = try trackedTempDir().appendingPathComponent("PreparedImports", isDirectory: true)
        try fm.createDirectory(at: d, withIntermediateDirectories: true); return d
    }
    private func cleanStaging(_ id: ImportID) { if let d = try? AppPaths.stagedImportDirectory(importID: id) { try? fm.removeItem(at: d) } }

    private func setUserVersion(_ url: URL, _ v: Int) throws {
        let d = try SQLiteDatabase(path: url.path); try d.execute("PRAGMA user_version = \(v)"); try d.close()
    }

    /// A fresh, EMPTY SQLite database at the given user_version (default 0 = pre-migration).
    private func makeSQLiteDB(userVersion: Int = 0, named: String = "src.db") throws -> URL {
        let url = try trackedTempDir().appendingPathComponent(named)
        let db = try SQLiteDatabase(path: url.path, mode: .readWriteCreate)
        try db.execute("PRAGMA journal_mode = DELETE")
        try db.execute("PRAGMA user_version = \(userVersion)")   // writes the header → valid file
        try db.close()
        return url
    }

    /// A v23 DB with a committed-but-un-checkpointed row living ONLY in a sibling -wal.
    private func walSourceDB(rowId: String) throws -> URL {
        let live = try electronFixtureCopy(named: "live.db")
        let conn = try SQLiteDatabase(path: live.path)
        try conn.execute("PRAGMA journal_mode = WAL")
        try conn.execute("PRAGMA wal_autocheckpoint = 0")
        try conn.run("INSERT INTO transactions (id,type,date,amount,currency) VALUES ('\(rowId)','income','2026-04-01',999,'CNY')")
        let out = try trackedTempDir().appendingPathComponent("walsrc.db")
        try withExtendedLifetime(conn) {
            try fm.copyItem(at: live, to: out)
            try fm.copyItem(at: URL(fileURLWithPath: live.path + "-wal"), to: URL(fileURLWithPath: out.path + "-wal"))
        }
        return out
    }

    private func assertNoSidecars(_ dbURL: URL, _ label: String = "") {
        for s in ["-wal", "-shm", "-journal"] {
            XCTAssertFalse(fm.fileExists(atPath: dbURL.path + s), "\(label): unexpected \(s) sidecar")
        }
    }

    // MARK: - Happy paths

    func testRunV23HappyPathProducesQuiescentIdentityBoundDB() throws {
        let (gated, id) = try gatedFixture(sourceDB: try electronFixtureCopy()); defer { cleanStaging(id) }
        let prepared = try PreparedImportRunner().run(gated, workingDirectory: try workingRoot(), preparedRoot: try preparedRoot())

        XCTAssertEqual(prepared.importID.rawValue, id.rawValue)
        assertNoSidecars(prepared.preparedDatabaseURL, "prepared")
        XCTAssertEqual(prepared.preparedDBIdentity, try PreparedDatabaseIdentity.compute(at: prepared.preparedDatabaseURL),
                       "the returned identity must equal a fresh compute of the published file")
        XCTAssertEqual(prepared.transactionsMigrated, 7, "the v23 fixture has 7 transactions")
        XCTAssertNotNil(prepared.gated, "gate evidence must be carried forward for attachment apply")

        // Prepared DB is DELETE-journal, single-file, and migrated to head.
        let db = try SQLiteDatabase(path: prepared.preparedDatabaseURL.path, readOnly: true)
        XCTAssertEqual(try db.userVersion(), SchemaMigrator.schemaVersion)
    }

    func testRunEmptyDatabaseMigratesFullLadderToHeadWithAll26Tables() throws {
        let (gated, id) = try gatedFixture(sourceDB: try makeSQLiteDB(userVersion: 0)); defer { cleanStaging(id) }
        let prepared = try PreparedImportRunner().run(gated, workingDirectory: try workingRoot(), preparedRoot: try preparedRoot())

        let db = try SQLiteDatabase(path: prepared.preparedDatabaseURL.path, readOnly: true)
        XCTAssertEqual(try db.userVersion(), 23, "the full ladder must reach head")
        let present = Set(try db.query("SELECT name FROM sqlite_master WHERE type='table'").compactMap { $0.string("name") })
        for t in SchemaMigrator.requiredTables { XCTAssertTrue(present.contains(t), "missing table \(t)") }
        XCTAssertEqual(prepared.transactionsMigrated, 0)
    }

    func testRunWithWALCheckpointsPendingRowIntoPreparedDB() throws {
        let (gated, id) = try gatedFixture(sourceDB: try walSourceDB(rowId: "wal-only"), withWAL: true); defer { cleanStaging(id) }
        XCTAssertTrue(gated.hasWAL)
        let prepared = try PreparedImportRunner().run(gated, workingDirectory: try workingRoot(), preparedRoot: try preparedRoot())
        assertNoSidecars(prepared.preparedDatabaseURL, "checkpointed")

        let db = try SQLiteDatabase(path: prepared.preparedDatabaseURL.path, readOnly: true)
        XCTAssertEqual(try db.query("SELECT COUNT(*) c FROM transactions WHERE id='wal-only'").first?.int("c"), 1,
                       "the WAL-only committed row must survive checkpoint into the prepared DB")
    }

    // MARK: - Version gates

    func testUnknownNewerUserVersionRejected() throws {
        let src = try electronFixtureCopy()
        try setUserVersion(src, 24)
        let (gated, id) = try gatedFixture(sourceDB: src); defer { cleanStaging(id) }
        XCTAssertThrowsError(try PreparedImportRunner().run(gated, workingDirectory: try workingRoot(), preparedRoot: try preparedRoot())) { e in
            guard case PreparedRunFailure.unsupportedUserVersion(let v) = e else { return XCTFail("got \(e)") }
            XCTAssertEqual(v, 24)
        }
    }

    func testNegativeUserVersionRejectedWithoutCrash() throws {
        let src = try electronFixtureCopy()
        try setUserVersion(src, -1)
        let (gated, id) = try gatedFixture(sourceDB: src); defer { cleanStaging(id) }
        XCTAssertThrowsError(try PreparedImportRunner().run(gated, workingDirectory: try workingRoot(), preparedRoot: try preparedRoot())) { e in
            guard case PreparedRunFailure.unsupportedUserVersion(let v) = e else { return XCTFail("got \(e)") }
            XCTAssertEqual(v, -1)
        }
    }

    // MARK: - Corruption

    func testCorruptDatabaseFailsClosed() throws {
        let src = try electronFixtureCopy()
        // Corrupt interior pages BEFORE ingest so the manifest records the corrupt bytes and
        // the gate (which only hashes) passes — the failure must surface in the runner.
        let size = (try fm.attributesOfItem(atPath: src.path)[.size] as? NSNumber)?.int64Value ?? 0
        XCTAssertGreaterThan(size, 5 * 4096)
        let h = try FileHandle(forWritingTo: src)
        for page in [2, 4, 6] { try h.seek(toOffset: UInt64(page * 4096)); try h.write(contentsOf: Data(repeating: 0xFF, count: 200)) }
        try h.close()
        let (gated, id) = try gatedFixture(sourceDB: src); defer { cleanStaging(id) }
        XCTAssertThrowsError(try PreparedImportRunner().run(gated, workingDirectory: try workingRoot(), preparedRoot: try preparedRoot())) { e in
            switch e {
            case PreparedRunFailure.integrityFailed, PreparedRunFailure.migrationFailed, PreparedRunFailure.foreignKeyViolations: break
            default: XCTFail("expected a fail-closed corruption error, got \(e)")
            }
        }
    }

    // MARK: - Determinism / idempotent publish / never-overwrite

    func testIdenticalSnapshotReRunIsIdempotentAndDeterministic() throws {
        let (gated, id) = try gatedFixture(sourceDB: try electronFixtureCopy()); defer { cleanStaging(id) }
        let work = try workingRoot(); let prep = try preparedRoot()
        let a = try PreparedImportRunner().run(gated, workingDirectory: work, preparedRoot: prep)
        let bytesA = try Data(contentsOf: a.preparedDatabaseURL)
        let b = try PreparedImportRunner().run(gated, workingDirectory: work, preparedRoot: prep)
        XCTAssertEqual(a.preparedDBIdentity, b.preparedDBIdentity, "same snapshot ⇒ same identity (deterministic)")
        XCTAssertEqual(a.preparedDatabaseURL, b.preparedDatabaseURL, "idempotent reuse of the published prepared DB")
        XCTAssertEqual(try Data(contentsOf: b.preparedDatabaseURL), bytesA, "published prepared DB not rewritten")
    }

    func testDifferentIdentityAtPublishTargetNeverOverwritten() throws {
        let (gated, id) = try gatedFixture(sourceDB: try electronFixtureCopy()); defer { cleanStaging(id) }
        let prep = try preparedRoot()
        let finalURL = prep.appendingPathComponent("import-\(id.rawValue).db")
        // Plant a DIFFERENT-identity file at the publish target just before the rename.
        let hooks = RunnerHooks(beforePublish: { url in try Data("not-the-prepared-db".utf8).write(to: url) })
        let before = try workingRoot()
        XCTAssertThrowsError(try PreparedImportRunner().run(gated, workingDirectory: before, preparedRoot: prep, hooks: hooks)) { e in
            guard case PreparedRunFailure.preparedPublishConflict = e else { return XCTFail("got \(e)") }
        }
        XCTAssertEqual(try Data(contentsOf: finalURL), Data("not-the-prepared-db".utf8), "the winner must be untouched")
        // No attempt dir leaked in the working root.
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: before.path).filter { $0.hasPrefix(".prep-") }, [], "attempt cleaned")
    }

    // MARK: - Fault → rollback → retriable; no attempt leak

    func testMigrationStageFailureCleansUpAndIsRetriable() throws {
        let (gated, id) = try gatedFixture(sourceDB: try electronFixtureCopy()); defer { cleanStaging(id) }
        let work = try workingRoot(); let prep = try preparedRoot()
        struct Boom: Error {}
        XCTAssertThrowsError(try PreparedImportRunner().run(gated, workingDirectory: work, preparedRoot: prep,
                                                            hooks: RunnerHooks(beforeMigrate: { _ in throw Boom() }))) { e in
            guard case PreparedRunFailure.migrationFailed = e else { return XCTFail("got \(e)") }
        }
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: work.path).filter { $0.hasPrefix(".prep-") }, [], "attempt cleaned")
        XCTAssertFalse(fm.fileExists(atPath: prep.appendingPathComponent("import-\(id.rawValue).db").path), "nothing published")

        // Retriable: the same gated snapshot runs cleanly on a second attempt.
        let ok = try PreparedImportRunner().run(gated, workingDirectory: work, preparedRoot: prep)
        XCTAssertEqual(ok.preparedDBIdentity, try PreparedDatabaseIdentity.compute(at: ok.preparedDatabaseURL))
    }

    // MARK: - Runner reads the DB only through the gate descriptor

    func testRunnerCopiesThroughGateDescriptorNotByPath() throws {
        // After gating, replace the on-disk staged DB with a symlink to different content.
        // The runner reads via the gate's bound fd (openat on the still-open directory handle),
        // so the swap cannot redirect it — the copy still yields the gated bytes.
        let (gated, id) = try gatedFixture(sourceDB: try electronFixtureCopy()); defer { cleanStaging(id) }
        let stagedDB = gated.stagingDir.appendingPathComponent("sololedger.db")
        let decoy = try trackedTempDir().appendingPathComponent("decoy.db")
        try Data("decoy-not-a-db".utf8).write(to: decoy)
        // NOTE: replacing the directory ENTRY does not change what the already-open descriptor
        // resolves for openat by name — openat re-looks-up the name in the bound dir inode, so a
        // symlink swap at that name WOULD be followed by openat(name). The gate's copy uses
        // openRegularFile(named:) with O_NOFOLLOW, so a symlink at the name fails closed instead.
        try fm.removeItem(at: stagedDB)
        try fm.createSymbolicLink(at: stagedDB, withDestinationURL: decoy)
        XCTAssertThrowsError(try PreparedImportRunner().run(gated, workingDirectory: try workingRoot(), preparedRoot: try preparedRoot())) { e in
            // Copy through the descriptor with O_NOFOLLOW rejects the symlinked entry.
            guard case PreparedRunFailure.snapshotCopyFailed = e else { return XCTFail("got \(e)") }
        }
    }
}
