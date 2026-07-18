import XCTest
@testable import SoloLedgerCore

/// 2B-3 C10: create-only activation of a prepared import. Covers the owner-record atomic
/// publication, the record+active double binding gates, same-/different-import concurrency,
/// crash/resume at every boundary, sidecar gates, and the durability-barrier semantics
/// (including repair-on-retry). All fixtures drive the REAL production chain
/// (ingest → gate → run → activate); primitives get their own focused tests.
final class PreparedImportActivatorTests: LedgerTestCase {

    private let fm = FileManager.default
    private var stagedIDs: [ImportID] = []

    override func tearDown() {
        for id in stagedIDs {
            if let d = try? AppPaths.stagedImportDirectory(importID: id) { try? fm.removeItem(at: d) }
        }
        stagedIDs = []
        super.tearDown()
    }

    // MARK: - Fixtures

    /// A fresh, EMPTY SQLite database at user_version 0 (migrated to head by the runner).
    private func makeSQLiteDB(named: String = "src.db") throws -> URL {
        let url = try trackedTempDir().appendingPathComponent(named)
        let db = try SQLiteDatabase(path: url.path, mode: .readWriteCreate)
        try db.execute("PRAGMA journal_mode = DELETE")
        try db.execute("PRAGMA user_version = 0")
        try db.close()
        return url
    }

    /// A real PreparedImport via the production chain: ingest → gate → run.
    private func preparedFixture() throws -> PreparedImport {
        let src = try trackedTempDir().appendingPathComponent("SoloLedger", isDirectory: true)
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try fm.copyItem(at: try makeSQLiteDB(), to: src.appendingPathComponent("sololedger.db"))
        let id = try XCTUnwrap(ImportID("act-\(UUID().uuidString.lowercased())"))
        stagedIDs.append(id)
        let result = try StagingIngest().ingest(.userSelectedDataDir(src), importID: id, timestamp: "t")
        let gated = try StagedSnapshotGate().gate(result)
        let prep = try trackedTempDir().appendingPathComponent("PreparedImports", isDirectory: true)
        try fm.createDirectory(at: prep, withIntermediateDirectories: true)
        let work = try trackedTempDir().appendingPathComponent("Work", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        return try PreparedImportRunner().run(gated, workingDirectory: work, preparedRoot: prep)
    }

    private func freshSlot() throws -> (dir: URL, active: URL) {
        let dir = try trackedTempDir().appendingPathComponent("ActiveSlot", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir, dir.appendingPathComponent("sololedger.db"))
    }

    private func recordURL(_ dir: URL) -> URL { dir.appendingPathComponent(PreparedImportActivator.recordName) }

    private func entries(_ dir: URL, prefix: String) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix(prefix) }.sorted()
    }

    private func rewriteRecordField(_ dir: URL, _ mutate: (inout ActivationRecord) -> Void) throws {
        var rec = try JSONDecoder().decode(ActivationRecord.self, from: Data(contentsOf: recordURL(dir)))
        mutate(&rec)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(rec).write(to: recordURL(dir))
    }

    private struct Crash: Error {}

    // MARK: - Happy path

    func testActivateFreshPublishesActiveAndOwnerRecord() throws {
        let prepared = try preparedFixture()
        let (dir, active) = try freshSlot()
        let a = try PreparedImportActivator().activate(prepared, activeDestination: active)

        XCTAssertFalse(a.reusedExisting)
        XCTAssertEqual(a.importID.rawValue, prepared.importID.rawValue)
        XCTAssertEqual(try Data(contentsOf: active), try Data(contentsOf: prepared.preparedDatabaseURL),
                       "active bytes must equal the prepared artifact DB")
        for s in PreparedImportActivator.sidecarSuffixes {
            XCTAssertFalse(fm.fileExists(atPath: active.path + s), "no \(s) sidecar")
        }
        let rec = try JSONDecoder().decode(ActivationRecord.self, from: Data(contentsOf: recordURL(dir)))
        XCTAssertEqual(rec, ActivationRecord(binding: prepared), "owner record binds the full import identity")
        XCTAssertEqual(entries(dir, prefix: "."), [], "no hidden temp/candidate residue on success")
    }

    // MARK: - Ownership is a recorded fact, never inferred from bytes

    func testExistingActiveSameBytesWithoutRecordConflicts() throws {
        let prepared = try preparedFixture()
        let (dir, active) = try freshSlot()
        // Same BYTES as the prepared DB occupy the slot — but with NO owner record.
        let bytes = try Data(contentsOf: prepared.preparedDatabaseURL)
        try bytes.write(to: active)

        XCTAssertThrowsError(try PreparedImportActivator().activate(prepared, activeDestination: active)) { e in
            guard case ActivationError.activationRecordConflict = e else { return XCTFail("got \(e)") }
        }
        XCTAssertEqual(try Data(contentsOf: active), bytes, "existing active untouched")
        XCTAssertFalse(fm.fileExists(atPath: recordURL(dir).path), "no record fabricated")
    }

    func testRecordImportIDMismatchConflicts() throws {
        let prepared = try preparedFixture()
        let (dir, active) = try freshSlot()
        _ = try PreparedImportActivator().activate(prepared, activeDestination: active)
        // Same hashes, different importID — must conflict (identity hash alone never proves ownership).
        try rewriteRecordField(dir) { $0.importID = "other-import" }
        let recBytes = try Data(contentsOf: recordURL(dir))
        let activeBytes = try Data(contentsOf: active)

        XCTAssertThrowsError(try PreparedImportActivator().activate(prepared, activeDestination: active)) { e in
            guard case ActivationError.activationRecordConflict = e else { return XCTFail("got \(e)") }
        }
        XCTAssertEqual(try Data(contentsOf: recordURL(dir)), recBytes, "foreign record untouched")
        XCTAssertEqual(try Data(contentsOf: active), activeBytes, "active untouched")
    }

    func testRecordAttachmentManifestMismatchConflicts() throws {
        let prepared = try preparedFixture()
        let (dir, active) = try freshSlot()
        _ = try PreparedImportActivator().activate(prepared, activeDestination: active)
        try rewriteRecordField(dir) { $0.attachmentManifestSHA256 = String($0.attachmentManifestSHA256.reversed()) }

        XCTAssertThrowsError(try PreparedImportActivator().activate(prepared, activeDestination: active)) { e in
            guard case ActivationError.activationRecordConflict = e else { return XCTFail("got \(e)") }
        }
    }

    func testMalformedFinalRecordTerminal() throws {
        let prepared = try preparedFixture()
        // Case 1: garbage bytes.
        do {
            let (dir, active) = try freshSlot()
            let garbage = Data("not json {".utf8)
            try garbage.write(to: recordURL(dir))
            XCTAssertThrowsError(try PreparedImportActivator().activate(prepared, activeDestination: active)) { e in
                guard case ActivationError.activationRecordMalformed = e else { return XCTFail("got \(e)") }
            }
            XCTAssertEqual(try Data(contentsOf: recordURL(dir)), garbage, "malformed record never deleted/repaired")
            XCTAssertFalse(fm.fileExists(atPath: active.path), "nothing activated")
        }
        // Case 2: valid JSON, unsupported formatVersion.
        do {
            let (dir, active) = try freshSlot()
            var rec = ActivationRecord(binding: prepared)
            rec.formatVersion = 999
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(rec).write(to: recordURL(dir))
            XCTAssertThrowsError(try PreparedImportActivator().activate(prepared, activeDestination: active)) { e in
                guard case ActivationError.activationRecordMalformed = e else { return XCTFail("got \(e)") }
            }
        }
    }

    // MARK: - Resume / reuse

    func testResumeAfterCrashBeforeCandidatePublishes() throws {
        let prepared = try preparedFixture()
        let (dir, active) = try freshSlot()
        XCTAssertThrowsError(try PreparedImportActivator().activate(
            prepared, activeDestination: active,
            hooks: ActivationHooks(afterOwnerRecordPublished: { _ in throw Crash() })))
        XCTAssertTrue(fm.fileExists(atPath: recordURL(dir).path), "record published before the crash")
        XCTAssertFalse(fm.fileExists(atPath: active.path), "no active yet — official resumable state 2")
        let recBytes = try Data(contentsOf: recordURL(dir))

        let a = try PreparedImportActivator().activate(prepared, activeDestination: active)
        XCTAssertFalse(a.reusedExisting, "resume materializes a fresh candidate")
        XCTAssertEqual(try Data(contentsOf: recordURL(dir)), recBytes, "record adopted verbatim, not rewritten")
        XCTAssertEqual(try Data(contentsOf: active), try Data(contentsOf: prepared.preparedDatabaseURL))
    }

    func testReuseExistingMatchingActiveIdempotent() throws {
        let prepared = try preparedFixture()
        let (dir, active) = try freshSlot()
        _ = try PreparedImportActivator().activate(prepared, activeDestination: active)
        let activeBytes = try Data(contentsOf: active)
        let recBytes = try Data(contentsOf: recordURL(dir))

        let b = try PreparedImportActivator().activate(prepared, activeDestination: active)
        XCTAssertTrue(b.reusedExisting)
        XCTAssertEqual(try Data(contentsOf: active), activeBytes, "active never rewritten on reuse")
        XCTAssertEqual(try Data(contentsOf: recordURL(dir)), recBytes, "record never rewritten on reuse")
    }

    func testResumeActiveIdentityMismatchFailsClosed() throws {
        let prepared = try preparedFixture()
        let (_, active) = try freshSlot()
        _ = try PreparedImportActivator().activate(prepared, activeDestination: active)
        let h = try FileHandle(forWritingTo: active)
        try h.seekToEnd(); try h.write(contentsOf: Data([0])); try h.close()
        let tampered = try Data(contentsOf: active)

        XCTAssertThrowsError(try PreparedImportActivator().activate(prepared, activeDestination: active)) { e in
            guard case ActivationError.activeIdentityMismatch = e else { return XCTFail("got \(e)") }
        }
        XCTAssertEqual(try Data(contentsOf: active), tampered, "mismatching active left untouched")
    }

    func testActiveEntryDirectoryWithMatchingRecordFailsClosed() throws {
        let prepared = try preparedFixture()
        let (dir, active) = try freshSlot()
        XCTAssertThrowsError(try PreparedImportActivator().activate(
            prepared, activeDestination: active,
            hooks: ActivationHooks(afterOwnerRecordPublished: { _ in throw Crash() })))
        try fm.createDirectory(at: active, withIntermediateDirectories: false)   // directory at the active name
        try Data("x".utf8).write(to: active.appendingPathComponent("inner.txt"))

        XCTAssertThrowsError(try PreparedImportActivator().activate(prepared, activeDestination: active)) { e in
            guard case ActivationError.activeSlotOccupied = e else { return XCTFail("got \(e)") }
        }
        XCTAssertEqual(try Data(contentsOf: active.appendingPathComponent("inner.txt")), Data("x".utf8),
                       "planted directory contents untouched")
        XCTAssertTrue(fm.fileExists(atPath: recordURL(dir).path), "record never deleted")
    }

    // MARK: - Concurrency: the record is the exclusive owner gate and is never rolled back

    func testConcurrentSameImportLoserNeverDeletesRecord() throws {
        let prepared = try preparedFixture()
        let (dir, active) = try freshSlot()
        // A publishes the record, then — inside A's candidate window — B (same import) runs a
        // FULL activation to completion. A must lose cleanly and MUST NOT delete the record.
        var bResult: ActivatedDatabase?
        let hooks = ActivationHooks(afterCandidateMaterialized: { _ in
            bResult = try PreparedImportActivator().activate(prepared, activeDestination: active)
        })
        XCTAssertThrowsError(try PreparedImportActivator().activate(prepared, activeDestination: active, hooks: hooks)) { e in
            guard case ActivationError.publishRaceLost = e else { return XCTFail("got \(e)") }
        }
        let b = try XCTUnwrap(bResult)
        XCTAssertFalse(b.reusedExisting, "B adopted A's record and won the active publish")
        XCTAssertTrue(fm.fileExists(atPath: recordURL(dir).path), "record survives A's loss — NEVER rolled back")
        XCTAssertEqual(try JSONDecoder().decode(ActivationRecord.self, from: Data(contentsOf: recordURL(dir))),
                       ActivationRecord(binding: prepared))
        XCTAssertEqual(try Data(contentsOf: active), try Data(contentsOf: prepared.preparedDatabaseURL), "winner untouched")

        // And a third run reuses the winner idempotently.
        let c = try PreparedImportActivator().activate(prepared, activeDestination: active)
        XCTAssertTrue(c.reusedExisting)
    }

    // MARK: - Record atomic publication

    func testRecordFileSyncFailureLeavesNoFinalRecord() throws {
        let prepared = try preparedFixture()
        let (dir, active) = try freshSlot()
        let hooks = ActivationHooks(onSync: { p in if p == .recordFile { throw Crash() } })
        XCTAssertThrowsError(try PreparedImportActivator().activate(prepared, activeDestination: active, hooks: hooks)) { e in
            guard case ActivationError.durabilitySyncFailed(.recordFile, _) = e else { return XCTFail("got \(e)") }
        }
        XCTAssertFalse(fm.fileExists(atPath: recordURL(dir).path), "no half-published FINAL record")
        XCTAssertFalse(fm.fileExists(atPath: active.path))
        XCTAssertEqual(entries(dir, prefix: PreparedImportActivator.recordTempPrefix), [],
                       "own still-bound temp cleaned on the error path")
    }

    /// Constraint 3: the onSync closure can tamper with the disk — the post-sync gate must
    /// stop a tampered record BEFORE its rename; the final record must never appear.
    func testOnSyncRecordTamperBlockedBeforeRename() throws {
        let prepared = try preparedFixture()
        let (dir, active) = try freshSlot()
        let hooks = ActivationHooks(onSync: { p in
            guard p == .recordFile else { return }
            let temp = try XCTUnwrap(self.entries(dir, prefix: PreparedImportActivator.recordTempPrefix).first)
            try Data("{\"tampered\":true}".utf8).write(to: dir.appendingPathComponent(temp))   // same inode rewrite
        })
        XCTAssertThrowsError(try PreparedImportActivator().activate(prepared, activeDestination: active, hooks: hooks)) { e in
            guard case ActivationError.recordWritebackMismatch = e else { return XCTFail("got \(e)") }
        }
        XCTAssertFalse(fm.fileExists(atPath: recordURL(dir).path), "tampered record must not be published")
        XCTAssertFalse(fm.fileExists(atPath: active.path))
    }

    /// Constraint 3: tampering the candidate inside onSync(.candidateFile) must be caught by
    /// the post-sync bound re-hash BEFORE the active rename; the active must never appear.
    func testOnSyncCandidateTamperBlockedBeforeActiveRename() throws {
        let prepared = try preparedFixture()
        let (dir, active) = try freshSlot()
        let hooks = ActivationHooks(onSync: { p in
            guard p == .candidateFile else { return }
            let cand = try XCTUnwrap(self.entries(dir, prefix: PreparedImportActivator.candidatePrefix).first)
            let h = try FileHandle(forWritingTo: dir.appendingPathComponent(cand))
            try h.seekToEnd(); try h.write(contentsOf: Data([0xFF])); try h.close()
        })
        XCTAssertThrowsError(try PreparedImportActivator().activate(prepared, activeDestination: active, hooks: hooks)) { e in
            guard case ActivationError.candidateRehashMismatch = e else { return XCTFail("got \(e)") }
        }
        XCTAssertFalse(fm.fileExists(atPath: active.path), "tampered candidate must not be published")
        XCTAssertTrue(fm.fileExists(atPath: recordURL(dir).path), "published record retained (never rolled back)")
    }

    // MARK: - Durability barriers: failure states and repair-on-retry

    func testActiveDirEntrySyncFailureThenRepairedOnRetry() throws {
        let prepared = try preparedFixture()
        let (dir, active) = try freshSlot()
        // Run 1: the post-publish directory barrier fails → NOT a usable result.
        let failing = ActivationHooks(onSync: { p in if p == .activeDirEntry { throw Crash() } })
        XCTAssertThrowsError(try PreparedImportActivator().activate(prepared, activeDestination: active, hooks: failing)) { e in
            guard case ActivationError.durabilityNotConfirmed = e else { return XCTFail("got \(e)") }
        }
        XCTAssertTrue(fm.fileExists(atPath: active.path), "active IS published (process-crash safe)")
        XCTAssertTrue(fm.fileExists(atPath: recordURL(dir).path), "record retained")
        let activeBytes = try Data(contentsOf: active)
        let recBytes = try Data(contentsOf: recordURL(dir))

        // Run 2: the reuse path REDOES the barriers and only then returns success.
        var seq: [ActivationSyncPoint] = []
        let recorder = ActivationHooks(onSync: { seq.append($0) })
        let a = try PreparedImportActivator().activate(prepared, activeDestination: active, hooks: recorder)
        XCTAssertTrue(a.reusedExisting)
        XCTAssertEqual(seq, [.recordFile, .recordDirEntry, .activeFile, .activeDirEntry],
                       "retry replays the full barrier set")
        XCTAssertEqual(try Data(contentsOf: active), activeBytes, "winner bytes unchanged")
        XCTAssertEqual(try Data(contentsOf: recordURL(dir)), recBytes, "record bytes unchanged")
    }

    func testRecordDirEntrySyncFailureThenRepairedOnRetry() throws {
        let prepared = try preparedFixture()
        let (dir, active) = try freshSlot()
        let failing = ActivationHooks(onSync: { p in if p == .recordDirEntry { throw Crash() } })
        XCTAssertThrowsError(try PreparedImportActivator().activate(prepared, activeDestination: active, hooks: failing)) { e in
            guard case ActivationError.durabilitySyncFailed(.recordDirEntry, _) = e else { return XCTFail("got \(e)") }
        }
        XCTAssertTrue(fm.fileExists(atPath: recordURL(dir).path), "published record retained")
        XCTAssertFalse(fm.fileExists(atPath: active.path))

        var seq: [ActivationSyncPoint] = []
        let recorder = ActivationHooks(onSync: { seq.append($0) })
        let a = try PreparedImportActivator().activate(prepared, activeDestination: active, hooks: recorder)
        XCTAssertFalse(a.reusedExisting)
        XCTAssertEqual(seq, [.recordFile, .recordDirEntry, .candidateFile, .activeDirEntry],
                       "adopting the record REPLAYS its barriers before the candidate")
    }

    func testSyncSequenceOrderFreshAndReuse() throws {
        let prepared = try preparedFixture()
        let (_, active) = try freshSlot()
        var fresh: [ActivationSyncPoint] = []
        _ = try PreparedImportActivator().activate(prepared, activeDestination: active,
                                                   hooks: ActivationHooks(onSync: { fresh.append($0) }))
        XCTAssertEqual(fresh, [.recordFile, .recordDirEntry, .candidateFile, .activeDirEntry])

        var reuse: [ActivationSyncPoint] = []
        _ = try PreparedImportActivator().activate(prepared, activeDestination: active,
                                                   hooks: ActivationHooks(onSync: { reuse.append($0) }))
        XCTAssertEqual(reuse, [.recordFile, .recordDirEntry, .activeFile, .activeDirEntry])
    }

    // MARK: - Sidecar gates

    func testSidecarPrePlantedFailsClosed() throws {
        // -wal as a regular file, -shm as a symlink, -journal as a directory: each must fail
        // closed BEFORE anything is created, and the planted object must be untouched.
        let target = try trackedTempDir().appendingPathComponent("target.txt")
        try Data("keep".utf8).write(to: target)
        let plants: [(String, (URL) throws -> Void)] = [
            ("-wal", { url in try Data("wal".utf8).write(to: url) }),
            ("-shm", { url in try self.fm.createSymbolicLink(at: url, withDestinationURL: target) }),
            ("-journal", { url in
                try self.fm.createDirectory(at: url, withIntermediateDirectories: false)
                try Data("inner".utf8).write(to: url.appendingPathComponent("inner.txt"))
            }),
        ]
        for (suffix, plant) in plants {
            let prepared = try preparedFixture()
            let (dir, active) = try freshSlot()
            let side = URL(fileURLWithPath: active.path + suffix)
            try plant(side)
            XCTAssertThrowsError(try PreparedImportActivator().activate(prepared, activeDestination: active), suffix) { e in
                guard case ActivationError.activeSlotOccupied = e else { return XCTFail("\(suffix): got \(e)") }
            }
            XCTAssertFalse(fm.fileExists(atPath: recordURL(dir).path), "\(suffix): no record created (gate ① precedes it)")
            XCTAssertFalse(fm.fileExists(atPath: active.path), "\(suffix): nothing activated")
            switch suffix {
            case "-wal": XCTAssertEqual(try Data(contentsOf: side), Data("wal".utf8))
            case "-shm": XCTAssertEqual(try Data(contentsOf: target), Data("keep".utf8), "symlink target untouched")
            default: XCTAssertEqual(try Data(contentsOf: side.appendingPathComponent("inner.txt")), Data("inner".utf8),
                                    "planted directory contents untouched (never recursed)")
            }
        }
    }

    func testSidecarAppearsAfterRenameFailsClosedThenRecoverable() throws {
        let prepared = try preparedFixture()
        let (dir, active) = try freshSlot()
        let wal = URL(fileURLWithPath: active.path + "-wal")
        let hooks = ActivationHooks(afterActivateRename: { _ in try Data("sneaky".utf8).write(to: wal) })
        XCTAssertThrowsError(try PreparedImportActivator().activate(prepared, activeDestination: active, hooks: hooks)) { e in
            guard case ActivationError.sidecarAppeared = e else { return XCTFail("got \(e)") }
        }
        // Registered recovery state: active + record published, activation NOT complete.
        XCTAssertTrue(fm.fileExists(atPath: active.path))
        XCTAssertTrue(fm.fileExists(atPath: recordURL(dir).path))
        XCTAssertEqual(try Data(contentsOf: wal), Data("sneaky".utf8), "foreign sidecar never deleted")

        try fm.removeItem(at: wal)   // operator/reaper resolves the sidecar…
        let a = try PreparedImportActivator().activate(prepared, activeDestination: active)
        XCTAssertTrue(a.reusedExisting, "…then a re-run completes activation via the reuse path")
    }

    // MARK: - Candidate binding

    func testCandidateNameSwappedDetected() throws {
        let prepared = try preparedFixture()
        let (dir, active) = try freshSlot()
        let sentinel = Data("REPLACEMENT".utf8)
        var replaced: URL?
        let hooks = ActivationHooks(afterCandidateMaterialized: { _ in
            let cand = try XCTUnwrap(self.entries(dir, prefix: PreparedImportActivator.candidatePrefix).first)
            let url = dir.appendingPathComponent(cand)
            try self.fm.moveItem(at: url, to: dir.appendingPathComponent("aside.db"))
            try sentinel.write(to: url)
            replaced = url
        })
        XCTAssertThrowsError(try PreparedImportActivator().activate(prepared, activeDestination: active, hooks: hooks)) { e in
            guard case ActivationError.candidateNameSwapped = e else { return XCTFail("got \(e)") }
        }
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(replaced)), sentinel,
                       "replacement untouched — cleanup only unlinks the still-bound own candidate")
        XCTAssertFalse(fm.fileExists(atPath: active.path))
        XCTAssertTrue(fm.fileExists(atPath: recordURL(dir).path), "record retained")
    }

    func testCandidateTamperViaPathCaughtByBoundRehash() throws {
        let prepared = try preparedFixture()
        let (dir, active) = try freshSlot()
        let hooks = ActivationHooks(afterCandidateMaterialized: { url in
            let h = try FileHandle(forWritingTo: url)
            try h.seekToEnd(); try h.write(contentsOf: Data([0x00])); try h.close()
        })
        XCTAssertThrowsError(try PreparedImportActivator().activate(prepared, activeDestination: active, hooks: hooks)) { e in
            guard case ActivationError.candidateRehashMismatch = e else { return XCTFail("got \(e)") }
        }
        XCTAssertFalse(fm.fileExists(atPath: active.path))
        XCTAssertTrue(fm.fileExists(atPath: recordURL(dir).path), "record retained after candidate failure")
        XCTAssertEqual(entries(dir, prefix: PreparedImportActivator.candidatePrefix), [],
                       "own still-bound candidate cleaned")
    }

    // MARK: - Primitives

    func testBoundRegularFilePrimitive() throws {
        let dir = try trackedTempDir().appendingPathComponent("brf", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let parent = try DirectoryHandle.open(at: dir)

        // Directory / symlink at the name are refused.
        try fm.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: false)
        XCTAssertThrowsError(try BoundRegularFile.open(in: parent, named: "sub"))
        let target = try trackedTempDir().appendingPathComponent("t.txt")
        try Data("keep".utf8).write(to: target)
        try fm.createSymbolicLink(at: dir.appendingPathComponent("link"), withDestinationURL: target)
        XCTAssertThrowsError(try BoundRegularFile.open(in: parent, named: "link"))

        // Exclusive create refuses an existing name.
        _ = try BoundRegularFile.create(in: parent, named: "f.json", contents: Data("{\"a\":1}".utf8))
        XCTAssertThrowsError(try BoundRegularFile.create(in: parent, named: "f.json", contents: Data()))

        // The binding follows the INODE, not the name: after an unlink-and-replace, the
        // bound fd still hashes the ORIGINAL content while matchesChild reports false.
        let original = Data("original-bytes".utf8)
        let bound = try BoundRegularFile.create(in: parent, named: "swap.bin", contents: original)
        let originalHash = try bound.rehashSHA256()
        try fm.removeItem(at: dir.appendingPathComponent("swap.bin"))
        try Data("replacement".utf8).write(to: dir.appendingPathComponent("swap.bin"))
        XCTAssertEqual(try bound.rehashSHA256(), originalHash, "bound fd keeps hashing the original inode")
        XCTAssertFalse(try bound.matchesChild(named: "swap.bin", in: parent), "name now resolves elsewhere")

        // unlinkIfStillBound must NOT remove the replacement.
        bound.unlinkIfStillBound(named: "swap.bin", in: parent)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("swap.bin")), Data("replacement".utf8))
    }

    func testDirectorySyncMethodObserved() throws {
        // Report which barrier the target filesystem actually takes (F_FULLFSYNC vs the
        // documented fsync fallback) — observed, not assumed.
        let dir = try trackedTempDir()
        let handle = try DirectoryHandle.open(at: dir)
        let method = try fsyncDirectoryEntry(handle, pathHint: dir.path)
        print("C10 DirSyncMethod observed on this volume:", method)
    }
}
