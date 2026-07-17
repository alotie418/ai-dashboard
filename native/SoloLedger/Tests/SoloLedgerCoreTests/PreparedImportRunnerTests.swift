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

    /// Like `gatedFixture` but with a caller-chosen importID string (for same-importID conflict tests).
    private func gatedFixtureFixedID(sourceDB: URL, idString: String) throws -> (gated: GatedStagedSnapshot, id: ImportID) {
        let src = try trackedTempDir().appendingPathComponent("SoloLedger", isDirectory: true)
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try fm.copyItem(at: sourceDB, to: src.appendingPathComponent("sololedger.db"))
        let id = ImportID(idString)!
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

    // MARK: - Artifact model + crash-resume (2B-3 C5, M1)

    private func artifactDir(_ prep: URL, _ id: ImportID) -> URL {
        prep.appendingPathComponent("import-\(id.rawValue)", isDirectory: true)
    }
    private func readProvenance(_ artifact: URL) throws -> PreparedProvenance {
        try JSONDecoder().decode(PreparedProvenance.self, from: Data(contentsOf: artifact.appendingPathComponent("provenance.json")))
    }
    private func writeProvenance(_ p: PreparedProvenance, _ artifact: URL) throws {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        try e.encode(p).write(to: artifact.appendingPathComponent("provenance.json"))
    }
    private func attemptsLeft(_ dir: URL, _ prefix: String) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix(prefix) }
    }

    /// The published artifact is a DIRECTORY {sololedger.db, provenance.json}; the DB URL points
    /// inside it. A re-run reuses it (crash-resume) — NOT by re-deriving identical bytes.
    func testPublishesArtifactDirWithProvenanceAndDBInside() throws {
        let (gated, id) = try gatedFixture(sourceDB: try electronFixtureCopy()); defer { cleanStaging(id) }
        let prep = try preparedRoot()
        let p = try PreparedImportRunner().run(gated, workingDirectory: try workingRoot(), preparedRoot: prep)
        let art = artifactDir(prep, id)
        XCTAssertEqual(p.preparedDatabaseURL, art.appendingPathComponent("sololedger.db"))
        XCTAssertEqual(Set(try fm.contentsOfDirectory(atPath: art.path)), ["sololedger.db", "provenance.json"])
        assertNoSidecars(p.preparedDatabaseURL, "artifact db")
        XCTAssertFalse(p.reusedExisting)
        let prov = try readProvenance(art)
        XCTAssertEqual(prov.preparedDBIdentity, p.preparedDBIdentity)
        XCTAssertEqual(prov.snapshotIdentitySHA256, gated.manifest.snapshotIdentitySHA256)
    }

    /// The regression the old "idempotent" test missed: a MIGRATING (user_version=0) snapshot
    /// re-run reuses the FIRST published artifact instead of re-deriving (non-deterministic)
    /// bytes and conflicting. Reuse takes the fast path (reusedExisting), returning the
    /// artifact's recorded identity — no re-migration, so timing/datetime cannot cause a mismatch.
    func testMigratingSnapshotRerunReusesPublishedArtifact() throws {
        let (gated, id) = try gatedFixture(sourceDB: try makeSQLiteDB(userVersion: 0)); defer { cleanStaging(id) }
        let prep = try preparedRoot()
        let a = try PreparedImportRunner().run(gated, workingDirectory: try workingRoot(), preparedRoot: prep)
        XCTAssertFalse(a.reusedExisting)
        let bytesA = try Data(contentsOf: a.preparedDatabaseURL)

        let b = try PreparedImportRunner().run(gated, workingDirectory: try workingRoot(), preparedRoot: prep)
        XCTAssertTrue(b.reusedExisting, "second run must RESUME the published artifact, not re-migrate")
        XCTAssertEqual(b.preparedDBIdentity, a.preparedDBIdentity)
        XCTAssertEqual(b.preparedDatabaseURL, a.preparedDatabaseURL)
        XCTAssertEqual(try Data(contentsOf: b.preparedDatabaseURL), bytesA, "artifact DB never rewritten on reuse")
    }

    /// A crash AFTER the atomic publish but BEFORE the PreparedImport is returned must be
    /// recoverable: the next run finds the artifact and resumes.
    func testCrashAfterPublishRecoversOnNextRun() throws {
        let (gated, id) = try gatedFixture(sourceDB: try makeSQLiteDB(userVersion: 0)); defer { cleanStaging(id) }
        let prep = try preparedRoot()
        struct Crash: Error {}
        XCTAssertThrowsError(try PreparedImportRunner().run(gated, workingDirectory: try workingRoot(), preparedRoot: prep,
                                                            hooks: RunnerHooks(afterPublish: { _ in throw Crash() })))
        // The artifact WAS published atomically before the "crash".
        XCTAssertTrue(fm.fileExists(atPath: artifactDir(prep, id).appendingPathComponent("provenance.json").path))
        // Recovery: next run resumes it.
        let ok = try PreparedImportRunner().run(gated, workingDirectory: try workingRoot(), preparedRoot: prep)
        XCTAssertTrue(ok.reusedExisting)
        XCTAssertEqual(ok.preparedDBIdentity, try PreparedDatabaseIdentity.compute(at: ok.preparedDatabaseURL))
    }

    // MARK: - Reuse is fail-closed against a tampered / mismatched artifact (winner untouched)

    /// Every tamper of a published artifact must make a re-run CONFLICT (fail-closed) and never
    /// touch the winner. Drives the real reuseIfConsistent path.
    func testTamperedArtifactRejectedOnRerunWinnerUntouched() throws {
        let mutations: [(String, (URL) throws -> Void)] = [
            ("provenance snapshot mismatch", { art in
                var p = try self.readProvenance(art); p.snapshotIdentitySHA256 = String(p.snapshotIdentitySHA256.reversed())
                try self.writeProvenance(p, art) }),
            ("provenance dbIdentity mismatch", { art in
                var p = try self.readProvenance(art); p.preparedDBIdentity = "sha256:0000"; try self.writeProvenance(p, art) }),
            ("provenance formatVersion", { art in
                var p = try self.readProvenance(art); p.formatVersion = 999; try self.writeProvenance(p, art) }),
            ("provenance missing", { art in try self.fm.removeItem(at: art.appendingPathComponent("provenance.json")) }),
            ("provenance symlink", { art in
                let pv = art.appendingPathComponent("provenance.json"); let copy = try self.trackedTempDir().appendingPathComponent("p.json")
                try self.fm.copyItem(at: pv, to: copy); try self.fm.removeItem(at: pv)
                try self.fm.createSymbolicLink(at: pv, withDestinationURL: copy) }),
            ("db bytes changed", { art in
                let db = art.appendingPathComponent("sololedger.db")
                let h = try FileHandle(forWritingTo: db); try h.seekToEnd(); try h.write(contentsOf: Data([0])); try h.close() }),
            ("txn count only", { art in
                var p = try self.readProvenance(art); p.transactionsMigrated = Int.max; try self.writeProvenance(p, art) }),
            ("db symlink", { art in
                let db = art.appendingPathComponent("sololedger.db"); let copy = try self.trackedTempDir().appendingPathComponent("d.db")
                try self.fm.copyItem(at: db, to: copy); try self.fm.removeItem(at: db)
                try self.fm.createSymbolicLink(at: db, withDestinationURL: copy) }),
            ("extra entry", { art in try Data("x".utf8).write(to: art.appendingPathComponent("stray.txt")) }),
        ]
        for (label, mutate) in mutations {
            let (gated, id) = try gatedFixture(sourceDB: try electronFixtureCopy()); defer { cleanStaging(id) }
            let prep = try preparedRoot()
            _ = try PreparedImportRunner().run(gated, workingDirectory: try workingRoot(), preparedRoot: prep)
            let art = artifactDir(prep, id)
            let before = try fm.contentsOfDirectory(atPath: art.path).sorted()
            try mutate(art)
            let afterTamper = try fm.contentsOfDirectory(atPath: art.path).sorted()

            XCTAssertThrowsError(try PreparedImportRunner().run(gated, workingDirectory: try workingRoot(), preparedRoot: prep), label) { e in
                guard case PreparedRunFailure.preparedPublishConflict = e else { return XCTFail("\(label): got \(e)") }
            }
            // The runner must NOT touch the (tampered) winner artifact.
            XCTAssertEqual(try fm.contentsOfDirectory(atPath: art.path).sorted(), afterTamper, "\(label): winner modified")
            XCTAssertFalse(before.isEmpty)
        }
    }

    /// A DIFFERENT snapshot sharing the same importID (re-ingested source) must never overwrite
    /// an already-published artifact.
    func testDifferentSnapshotAtSameImportIDNeverOverwritten() throws {
        let idStr = "run-\(UUID().uuidString)"
        let prep = try preparedRoot()

        // Publish artifact A from an EMPTY (v0) source.
        let (gatedA, idA) = try gatedFixtureFixedID(sourceDB: try makeSQLiteDB(userVersion: 0, named: "a.db"), idString: idStr)
        _ = try PreparedImportRunner().run(gatedA, workingDirectory: try workingRoot(), preparedRoot: prep)
        let art = artifactDir(prep, idA)
        let provA = try readProvenance(art)

        // Re-ingest a genuinely DIFFERENT source (v23 fixture, different bytes) under the SAME
        // importID → different snapshotIdentity.
        cleanStaging(idA)
        let (gatedB, _) = try gatedFixtureFixedID(sourceDB: try electronFixtureCopy(named: "b.db"), idString: idStr)
        XCTAssertNotEqual(gatedB.manifest.snapshotIdentitySHA256, gatedA.manifest.snapshotIdentitySHA256)

        XCTAssertThrowsError(try PreparedImportRunner().run(gatedB, workingDirectory: try workingRoot(), preparedRoot: prep)) { e in
            guard case PreparedRunFailure.preparedPublishConflict = e else { return XCTFail("got \(e)") }
        }
        XCTAssertEqual(try readProvenance(art), provA, "the winner's provenance must be byte-identical")
        cleanStaging(idA)
    }

    // MARK: - Publish race: exclusive rename maps a mid-flight winner to a conflict

    func testPublishRaceMapsToConflictWinnerUntouched() throws {
        let (gated, id) = try gatedFixture(sourceDB: try makeSQLiteDB(userVersion: 0)); defer { cleanStaging(id) }
        let prep = try preparedRoot()
        let art = artifactDir(prep, id)
        // A winner appears AFTER the fast-path check, just before our exclusive rename.
        let hooks = RunnerHooks(beforePublish: { _ in
            try self.fm.createDirectory(at: art, withIntermediateDirectories: true)
            try Data("winner-db".utf8).write(to: art.appendingPathComponent("sololedger.db"))
            try Data("{}".utf8).write(to: art.appendingPathComponent("provenance.json"))
        })
        let work = try workingRoot()
        XCTAssertThrowsError(try PreparedImportRunner().run(gated, workingDirectory: work, preparedRoot: prep, hooks: hooks)) { e in
            guard case PreparedRunFailure.preparedPublishConflict = e else { return XCTFail("got \(e)") }
        }
        XCTAssertEqual(try Data(contentsOf: art.appendingPathComponent("sololedger.db")), Data("winner-db".utf8), "winner untouched")
        XCTAssertEqual(attemptsLeft(work, ".prep-"), [], "working attempt cleaned")
        XCTAssertEqual(attemptsLeft(prep, ".artifact-"), [], "artifact attempt cleaned")
    }

    /// RENAME_EXCL specifically: a plain rename() REPLACES an existing EMPTY directory, but the
    /// exclusive rename must refuse ANY existing destination. An empty winner dir must survive.
    func testExclusiveRenameNeverReplacesExistingEmptyDirWinner() throws {
        let (gated, id) = try gatedFixture(sourceDB: try makeSQLiteDB(userVersion: 0)); defer { cleanStaging(id) }
        let prep = try preparedRoot()
        let art = artifactDir(prep, id)
        let hooks = RunnerHooks(beforePublish: { _ in try self.fm.createDirectory(at: art, withIntermediateDirectories: true) })
        XCTAssertThrowsError(try PreparedImportRunner().run(gated, workingDirectory: try workingRoot(), preparedRoot: prep, hooks: hooks)) { e in
            guard case PreparedRunFailure.preparedPublishConflict = e else { return XCTFail("got \(e)") }
        }
        XCTAssertTrue(fm.fileExists(atPath: art.path), "empty winner dir must survive")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: art.path), [], "empty winner dir never replaced")
    }

    // MARK: - Descriptor-bound publish: swaps + beforePublish tamper fail closed (2B-3 C6)

    private func currentArtifactAttemptName(_ prep: URL) throws -> String {
        try XCTUnwrap(fm.contentsOfDirectory(atPath: prep.path).first { $0.hasPrefix(".artifact-") })
    }

    /// The preparedRoot PATH is replaced with a DIFFERENT real directory (holding a same-named
    /// empty impostor attempt) during beforePublish. Because the runner bound preparedRoot once
    /// and re-verifies its inode before publishing, it fails closed and the impostor is NEVER
    /// promoted to a published artifact.
    func testPreparedRootSwappedBeforePublishFailsClosedImpostorNeverPromoted() throws {
        let (gated, id) = try gatedFixture(sourceDB: try makeSQLiteDB(userVersion: 0)); defer { cleanStaging(id) }
        let prep = try preparedRoot()
        let newRoot = try trackedTempDir().appendingPathComponent("swapped-root", isDirectory: true)
        try fm.createDirectory(at: newRoot, withIntermediateDirectories: true)
        let importName = "import-\(id.rawValue)"
        let hooks = RunnerHooks(beforePublish: { _ in
            let art = try self.currentArtifactAttemptName(prep)
            // Same-named empty impostor in the new root.
            try self.fm.createDirectory(at: newRoot.appendingPathComponent(art), withIntermediateDirectories: true)
            // Swap the preparedRoot PATH → newRoot (a real directory, different inode).
            let aside = try self.trackedTempDir().appendingPathComponent("orig-root", isDirectory: true)
            try self.fm.moveItem(at: prep, to: aside)
            try self.fm.moveItem(at: newRoot, to: prep)
        })
        XCTAssertThrowsError(try PreparedImportRunner().run(gated, workingDirectory: try workingRoot(), preparedRoot: prep, hooks: hooks)) { e in
            guard case PreparedRunFailure.publishFailed = e else { return XCTFail("got \(e)") }
        }
        XCTAssertFalse(fm.fileExists(atPath: prep.appendingPathComponent(importName).path),
                       "the impostor must never be promoted to a published artifact")
    }

    /// Tampering the ARTIFACT ATTEMPT during beforePublish (after build, before the final gate)
    /// must fail closed — the gate re-verifies the whole artifact THROUGH the bound descriptor.
    func testArtifactAttemptTamperDuringBeforePublishFailsClosed() throws {
        let cases: [(String, (URL) throws -> Void)] = [
            ("db append", { art in
                let db = art.appendingPathComponent("sololedger.db")
                let h = try FileHandle(forWritingTo: db); try h.seekToEnd(); try h.write(contentsOf: Data([0])); try h.close() }),
            ("db same-size replace", { art in
                let db = art.appendingPathComponent("sololedger.db")
                let n = (try self.fm.attributesOfItem(atPath: db.path)[.size] as? NSNumber)?.intValue ?? 0
                try self.fm.removeItem(at: db); try Data(repeating: 0xFF, count: n).write(to: db) }),
            ("db symlink", { art in
                let db = art.appendingPathComponent("sololedger.db"); let elsewhere = try self.trackedTempDir().appendingPathComponent("x.db")
                try self.fm.copyItem(at: db, to: elsewhere); try self.fm.removeItem(at: db)
                try self.fm.createSymbolicLink(at: db, withDestinationURL: elsewhere) }),
            ("db fifo", { art in
                let db = art.appendingPathComponent("sololedger.db"); try self.fm.removeItem(at: db)
                guard mkfifo(db.path, 0o644) == 0 else { throw TestError() } }),
            ("provenance tamper", { art in
                var p = try self.readProvenance(art); p.snapshotIdentitySHA256 = String(p.snapshotIdentitySHA256.reversed())
                try self.writeProvenance(p, art) }),
            ("extra entry", { art in try Data("x".utf8).write(to: art.appendingPathComponent("stray.txt")) }),
        ]
        for (label, mutate) in cases {
            let (gated, id) = try gatedFixture(sourceDB: try makeSQLiteDB(userVersion: 0)); defer { cleanStaging(id) }
            let prep = try preparedRoot(); let work = try workingRoot()
            let hooks = RunnerHooks(beforePublish: { _ in try mutate(prep.appendingPathComponent(try self.currentArtifactAttemptName(prep))) })
            XCTAssertThrowsError(try PreparedImportRunner().run(gated, workingDirectory: work, preparedRoot: prep, hooks: hooks), label) { e in
                switch e {
                case PreparedRunFailure.preparedPublishConflict, PreparedRunFailure.publishFailed: break
                default: XCTFail("\(label): got \(e)")
                }
            }
            XCTAssertFalse(fm.fileExists(atPath: artifactDir(prep, id).path), "\(label): must not publish")
            XCTAssertEqual(attemptsLeft(prep, ".artifact-"), [], "\(label): attempt cleaned")
        }
    }

    private struct TestError: Error {}

    // MARK: - Attempt cleanup is keyed on the BOUND handle, never a replacement (2B-3 C7)

    /// The real bound `.artifact-*` attempt is MOVED AWAY during beforePublish and a same-named
    /// NON-EMPTY replacement (carrying a sentinel) is planted at that name. The run fails closed
    /// (pre-rename inode gate), and — critically — attempt cleanup, which is keyed on the bound
    /// `art` handle and NOT the re-resolved name, must NEVER enumerate or delete the replacement:
    /// the replacement dir and its sentinel bytes must be completely unchanged, and never
    /// promoted to a published artifact.
    func testArtifactAttemptReplacedDuringBeforePublishReplacementUntouchedNotPublished() throws {
        let (gated, id) = try gatedFixture(sourceDB: try makeSQLiteDB(userVersion: 0)); defer { cleanStaging(id) }
        let prep = try preparedRoot(); let work = try workingRoot()
        let importName = "import-\(id.rawValue)"
        let sentinel = Data("REPLACEMENT-SENTINEL-do-not-delete".utf8)
        var replacementURL: URL?
        let hooks = RunnerHooks(beforePublish: { _ in
            let artName = try self.currentArtifactAttemptName(prep)
            // Move the real, bound attempt away, then plant a same-named NON-EMPTY replacement.
            let aside = try self.trackedTempDir().appendingPathComponent("real-attempt-aside", isDirectory: true)
            try self.fm.moveItem(at: prep.appendingPathComponent(artName), to: aside)
            let planted = prep.appendingPathComponent(artName)
            try self.fm.createDirectory(at: planted, withIntermediateDirectories: false)
            try sentinel.write(to: planted.appendingPathComponent("sentinel"))
            replacementURL = planted
        })
        XCTAssertThrowsError(try PreparedImportRunner().run(gated, workingDirectory: work, preparedRoot: prep, hooks: hooks)) { e in
            guard case PreparedRunFailure.publishFailed = e else { return XCTFail("got \(e)") }
        }
        let planted = try XCTUnwrap(replacementURL)
        XCTAssertTrue(fm.fileExists(atPath: planted.path), "planted replacement dir must survive cleanup")
        XCTAssertEqual(try? Data(contentsOf: planted.appendingPathComponent("sentinel")), sentinel,
                       "replacement sentinel bytes must be untouched (never enumerated/deleted)")
        XCTAssertFalse(fm.fileExists(atPath: prep.appendingPathComponent(importName).path),
                       "the replacement must never be promoted to a published artifact")
    }

    // MARK: - Post-publish outcome is verified against the bound handle (2B-3 C7, blockers B/D)

    /// The published `import-<id>` entry is swapped for a DIFFERENT directory during the
    /// afterPublish (crash-simulation) window. The authoritative post-publish check re-verifies
    /// the published entry against the BOUND artifact inode, so the runner fails closed and never
    /// returns a PreparedImport whose public URL would point at object B while the handle
    /// validated object A.
    func testPublishedEntrySwapAfterPublishFailsClosedNeverReturnsMismatchedURL() throws {
        let (gated, id) = try gatedFixture(sourceDB: try makeSQLiteDB(userVersion: 0)); defer { cleanStaging(id) }
        let prep = try preparedRoot(); let work = try workingRoot()
        let hooks = RunnerHooks(afterPublish: { finalURL in
            let aside = try self.trackedTempDir().appendingPathComponent("published-aside", isDirectory: true)
            try self.fm.moveItem(at: finalURL, to: aside)                       // move our real artifact away
            try self.fm.createDirectory(at: finalURL, withIntermediateDirectories: false)   // impostor inode
            try Data("impostor".utf8).write(to: finalURL.appendingPathComponent("sololedger.db"))
        })
        XCTAssertThrowsError(try PreparedImportRunner().run(gated, workingDirectory: work, preparedRoot: prep, hooks: hooks)) { e in
            guard case PreparedRunFailure.publishFailed = e else { return XCTFail("got \(e)") }
        }
    }

    // MARK: - Resume re-verifies HEAD SCHEMA, not just identity + count (2B-3 C7, blocker C)

    /// A COORDINATED tamper — swap the published DB for a valid, openable, DELETE-journal DB that
    /// has a `transactions` table but is NOT head schema, AND rewrite provenance
    /// preparedDBIdentity + transactionsMigrated to the replacement's real values — must still
    /// make resume CONFLICT. The schema gate is checked against SchemaMigrator constants
    /// (user_version == head, required-table NAMES, integrity, foreign keys), which
    /// attacker-writable provenance cannot forge. Three distinct defects, each tripping a
    /// distinct gate. (A right-NAMES/wrong-COLUMNS substitution is the registered same-UID
    /// residual — the gate proves table presence, not per-column DDL — and is intentionally not
    /// asserted here; byte-exact DDL would false-reject legitimate Electron-authored v23 imports.)
    func testResumeRejectsCoordinatedSchemaTamper() throws {
        func wrongVersionDB() throws -> URL {
            let url = try trackedTempDir().appendingPathComponent("wrong-version.db")
            let d = try SQLiteDatabase(path: url.path, mode: .readWriteCreate)
            try d.execute("PRAGMA journal_mode = DELETE")
            try d.execute("CREATE TABLE transactions (id TEXT)")
            try d.run("INSERT INTO transactions (id) VALUES ('x')")
            try d.execute("PRAGMA user_version = 1")
            try d.close(); return url
        }
        func missingTablesDB() throws -> URL {
            let url = try trackedTempDir().appendingPathComponent("missing-tables.db")
            let d = try SQLiteDatabase(path: url.path, mode: .readWriteCreate)
            try d.execute("PRAGMA journal_mode = DELETE")
            try d.execute("CREATE TABLE transactions (id TEXT)")
            try d.run("INSERT INTO transactions (id) VALUES ('x')")
            try d.execute("PRAGMA user_version = \(SchemaMigrator.schemaVersion)")   // head version, tables missing
            try d.close(); return url
        }
        func danglingFKDB() throws -> URL {
            let url = try makeSQLiteDB(userVersion: 0, named: "fk.db")
            let d = try SQLiteDatabase(path: url.path, mode: .readWriteExisting)
            try SchemaMigrator.migrate(d)                                            // full head schema
            try d.execute("PRAGMA foreign_keys = OFF")
            try d.run("INSERT INTO transactions (id,type,date,amount,currency,category_id) VALUES ('fk','income','2026-01-01',1,'CNY','no-cat')")
            try d.execute("PRAGMA journal_mode = DELETE")
            try d.close(); return url
        }
        let builders: [(String, () throws -> URL)] = [
            ("wrong user_version", wrongVersionDB),
            ("head version, missing required tables", missingTablesDB),
            ("head schema, dangling foreign key", danglingFKDB),
        ]
        for (label, build) in builders {
            let (gated, id) = try gatedFixture(sourceDB: try makeSQLiteDB(userVersion: 0)); defer { cleanStaging(id) }
            let prep = try preparedRoot()
            _ = try PreparedImportRunner().run(gated, workingDirectory: try workingRoot(), preparedRoot: prep)
            let art = artifactDir(prep, id)
            let db = art.appendingPathComponent("sololedger.db")
            let fake = try build()
            let fakeCount: Int = try {
                let d = try SQLiteDatabase(path: fake.path, readOnly: true); defer { try? d.close() }
                return try d.query("SELECT COUNT(*) AS c FROM transactions").first?.int("c") ?? -1
            }()
            // Coordinated swap: replace the published DB AND rewrite provenance identity + count
            // to the replacement's real values, so only the schema gate can catch it.
            try fm.removeItem(at: db); try fm.copyItem(at: fake, to: db)
            var p = try readProvenance(art)
            p.preparedDBIdentity = try PreparedDatabaseIdentity.compute(at: db)
            p.transactionsMigrated = fakeCount
            try writeProvenance(p, art)
            XCTAssertThrowsError(try PreparedImportRunner().run(gated, workingDirectory: try workingRoot(), preparedRoot: prep), label) { e in
                guard case PreparedRunFailure.preparedPublishConflict = e else { return XCTFail("\(label): got \(e)") }
            }
        }
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
        XCTAssertEqual(attemptsLeft(work, ".prep-"), [], "working attempt cleaned")
        XCTAssertEqual(attemptsLeft(prep, ".artifact-"), [], "artifact attempt cleaned")
        XCTAssertFalse(fm.fileExists(atPath: artifactDir(prep, id).path), "nothing published")

        let ok = try PreparedImportRunner().run(gated, workingDirectory: work, preparedRoot: prep)
        XCTAssertFalse(ok.reusedExisting)
        XCTAssertEqual(ok.preparedDBIdentity, try PreparedDatabaseIdentity.compute(at: ok.preparedDatabaseURL))
    }

    // MARK: - C3 gate direct regressions (2B-3 C5 tail)

    func testMissingRequiredTableRejectedSchemaIncomplete() throws {
        let src = try electronFixtureCopy()
        do { let d = try SQLiteDatabase(path: src.path); try d.execute("DROP TABLE alerts"); try d.close() }
        let (gated, id) = try gatedFixture(sourceDB: src); defer { cleanStaging(id) }
        XCTAssertThrowsError(try PreparedImportRunner().run(gated, workingDirectory: try workingRoot(), preparedRoot: try preparedRoot())) { e in
            guard case PreparedRunFailure.schemaIncomplete(let m) = e else { return XCTFail("got \(e)") }
            XCTAssertTrue(m.contains("alerts"), m)
        }
    }

    func testForeignKeyViolationRejected() throws {
        let src = try electronFixtureCopy()
        do {
            let d = try SQLiteDatabase(path: src.path)
            try d.execute("PRAGMA foreign_keys = OFF")   // plant a dangling FK
            try d.run("INSERT INTO transactions (id,type,date,amount,currency,category_id) VALUES ('fk-bad','income','2026-01-01',1,'CNY','no-such-category')")
            try d.close()
        }
        let (gated, id) = try gatedFixture(sourceDB: src); defer { cleanStaging(id) }
        XCTAssertThrowsError(try PreparedImportRunner().run(gated, workingDirectory: try workingRoot(), preparedRoot: try preparedRoot())) { e in
            guard case PreparedRunFailure.foreignKeyViolations = e else { return XCTFail("got \(e)") }
        }
    }

    func testWorkingDatabaseVanishingAfterCopyNeverCreatesEmptyDB() throws {
        let (gated, id) = try gatedFixture(sourceDB: try electronFixtureCopy()); defer { cleanStaging(id) }
        let prep = try preparedRoot(); let work = try workingRoot()
        // Delete the just-copied working DB before normalize: readWriteExisting must fail closed.
        let hooks = RunnerHooks(afterCopy: { attempt in try self.fm.removeItem(at: attempt.appendingPathComponent("sololedger.db")) })
        XCTAssertThrowsError(try PreparedImportRunner().run(gated, workingDirectory: work, preparedRoot: prep, hooks: hooks)) { e in
            guard case PreparedRunFailure.integrityFailed = e else { return XCTFail("got \(e)") }
        }
        XCTAssertFalse(fm.fileExists(atPath: artifactDir(prep, id).path), "no empty DB fabricated / published")
        XCTAssertEqual(attemptsLeft(work, ".prep-"), [], "attempt cleaned")
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
