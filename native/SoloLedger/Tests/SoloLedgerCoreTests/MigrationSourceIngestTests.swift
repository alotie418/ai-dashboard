import XCTest
@testable import SoloLedgerCore

/// MigrationSource URL wiring + FAILURE-ATOMIC staging ingest: byte-copy the source DB (and
/// its WAL only when legitimate) plus REL_RE-conforming REGULAR attachment files into an
/// isolated per-attempt temp dir, verify the source didn't change, then atomically PUBLISH;
/// any failure hard-cleans the attempt and never publishes. All fixtures are synthetic
/// temp files — no real DB or attachments.
final class MigrationSourceIngestTests: LedgerTestCase {

    private let fm = FileManager.default
    private struct TestError: Error {}
    private struct CleanupError: Error {}

    // MARK: - Fixtures (synthetic bytes; ingest never opens the DB, so raw bytes suffice)

    private func writeBytes(_ s: String, to url: URL) throws { try Data(s.utf8).write(to: url) }

    /// A synthetic Electron data directory: db (+ optional wal) + an attachments/docs tree
    /// with valid files, a symlink, a nested dir and an illegally-named file.
    private func makeDataDirFixture(withWal: Bool, withAttachments: Bool, db: String = "synthetic-db-bytes") throws -> URL {
        let dir = try trackedTempDir().appendingPathComponent("SoloLedger", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("sololedger.db")
        try writeBytes(db, to: dbURL)
        if withWal { try writeBytes("synthetic-wal-bytes", to: URL(fileURLWithPath: dbURL.path + "-wal")) }
        if withAttachments {
            let docs = dir.appendingPathComponent("attachments", isDirectory: true).appendingPathComponent("docs", isDirectory: true)
            try fm.createDirectory(at: docs, withIntermediateDirectories: true)
            try writeBytes("pdf-a", to: docs.appendingPathComponent("doc-a.pdf"))
            try writeBytes("jpg-b", to: docs.appendingPathComponent("doc-b.jpg"))
            try fm.createSymbolicLink(at: docs.appendingPathComponent("link.pdf"),
                                      withDestinationURL: docs.appendingPathComponent("doc-a.pdf"))
            let sub = docs.appendingPathComponent("sub", isDirectory: true)
            try fm.createDirectory(at: sub, withIntermediateDirectories: true)
            try writeBytes("nested", to: sub.appendingPathComponent("inner.pdf"))
            try writeBytes("bad", to: docs.appendingPathComponent("bad name.pdf"))   // space → illegal
        }
        return dir
    }

    private func newImportID() -> ImportID { ImportID("test-\(UUID().uuidString)")! }
    private func cleanStaging(_ id: ImportID) {
        if let dir = try? AppPaths.stagedImportDirectory(importID: id) { try? fm.removeItem(at: dir) }
    }
    private func attemptNames() -> Set<String> {
        guard let root = try? AppPaths.stagingRootDirectory(),
              let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return Set(items.map { $0.lastPathComponent }.filter { $0.hasPrefix(".attempt-") })
    }
    private func removeNewAttempts(since before: Set<String>) {
        guard let root = try? AppPaths.stagingRootDirectory(),
              let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for u in items where u.lastPathComponent.hasPrefix(".attempt-") && !before.contains(u.lastPathComponent) {
            try? fm.removeItem(at: u)
        }
    }
    private func finalExists(_ id: ImportID) -> Bool {
        guard let dir = try? AppPaths.stagedImportDirectory(importID: id) else { return false }
        return fm.fileExists(atPath: dir.path)
    }

    // MARK: - URL wiring / name validator

    func testSourceURLWiringForAllVariants() throws {
        let mas = MigrationSource.masContainer
        XCTAssertEqual(try mas.databaseURL(), try AppPaths.electronLegacyDatabaseURL())
        XCTAssertEqual(try mas.walURL()?.lastPathComponent, "sololedger.db-wal")
        XCTAssertEqual(try mas.attachmentsRootURL(), try AppPaths.electronLegacyAttachmentsURL())

        let dir = URL(fileURLWithPath: "/tmp/x/SoloLedger")
        let dataDir = MigrationSource.userSelectedDataDir(dir)
        XCTAssertEqual(try dataDir.databaseURL(), dir.appendingPathComponent("sololedger.db"))
        XCTAssertEqual(try dataDir.walURL()?.path, dir.appendingPathComponent("sololedger.db").path + "-wal")
        XCTAssertEqual(try dataDir.attachmentsRootURL()?.pathComponents.suffix(2).joined(separator: "/"), "attachments/docs")

        let bundle = MigrationSource.exportBundle(dir)
        XCTAssertNil(try bundle.walURL(), "export bundle must be pre-checkpointed — no WAL")

        let single = MigrationSource.legacySingleDB(URL(fileURLWithPath: "/tmp/x/foo.db"))
        XCTAssertNil(try single.walURL(), "standalone .db must be pre-checkpointed — no sibling WAL read")
        XCTAssertNil(try single.attachmentsRootURL())
    }

    func testAttachmentNameValidatorMatchesRelRe() {
        for ok in ["doc-a.pdf", "a", "A1._-x", "doc_b.JPG", "0start.png"] {
            XCTAssertTrue(AttachmentName.isValid(ok), "\(ok) should be valid")
        }
        for bad in ["", ".hidden", "-lead", "_lead", "bad name.pdf", "a/b", "..evil", "x..y", "café.pdf", "sub/inner.pdf"] {
            XCTAssertFalse(AttachmentName.isValid(bad), "\(bad) should be invalid")
        }
    }

    // MARK: - ImportID validation (strong typing + path containment)

    func testImportIDRejectsUnsafeValues() {
        XCTAssertNil(ImportID("../escape"))
        XCTAssertNil(ImportID("a/b"))
        XCTAssertNil(ImportID(".."))
        XCTAssertNil(ImportID("x..y"))
        XCTAssertNil(ImportID(""))
        XCTAssertNil(ImportID(String(repeating: "a", count: 65)), "over-long (> 64) must be rejected")
        XCTAssertNil(ImportID("has space"))
        XCTAssertNil(ImportID("emoji😀"))
        XCTAssertNotNil(ImportID("test-abc-123"))
        XCTAssertNotNil(ImportID(String(repeating: "a", count: 64)))
        XCTAssertNotNil(ImportID(ImportID.generate().rawValue), "generated IDs are always valid")
        // stagedImportDirectory stays strictly under the Staging root for a valid ID.
        let id = ImportID("test-contained")!
        let root = try! AppPaths.stagingRootDirectory()
        let dir = try! AppPaths.stagedImportDirectory(importID: id)
        XCTAssertTrue(dir.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/"))
    }

    // MARK: - Ingest: data dir (db + wal + conforming attachments only), published atomically

    func testIngestUserSelectedDataDirPublishesDbWalAndConformingAttachmentsOnly() throws {
        let dir = try makeDataDirFixture(withWal: true, withAttachments: true)
        let id = newImportID(); defer { cleanStaging(id) }

        let r = try StagingIngest().ingest(.userSelectedDataDir(dir), importID: id, timestamp: "20260101-000000")

        // Published to the per-import dir.
        XCTAssertEqual(r.stagingDir, try AppPaths.stagedImportDirectory(importID: id))
        XCTAssertTrue(fm.fileExists(atPath: r.stagedDatabaseURL.path))
        XCTAssertNotNil(r.stagedWALURL); XCTAssertTrue(fm.fileExists(atPath: r.stagedWALURL!.path))
        let docs = try XCTUnwrap(r.stagedAttachmentsDir)
        XCTAssertTrue(fm.fileExists(atPath: docs.appendingPathComponent("doc-a.pdf").path))
        XCTAssertTrue(fm.fileExists(atPath: docs.appendingPathComponent("doc-b.jpg").path))
        XCTAssertFalse(fm.fileExists(atPath: docs.appendingPathComponent("link.pdf").path))
        XCTAssertFalse(fm.fileExists(atPath: docs.appendingPathComponent("sub").path))
        XCTAssertFalse(fm.fileExists(atPath: docs.appendingPathComponent("bad name.pdf").path))

        var outcome: [String: ImportManifest.FileResult.Outcome] = [:]
        for f in r.manifest.files { outcome[f.name] = f.outcome }
        XCTAssertEqual(outcome["doc-a.pdf"], .ingested)
        XCTAssertEqual(outcome["link.pdf"], .skippedSymlink)
        XCTAssertEqual(outcome["sub"], .skippedDirectory)
        XCTAssertEqual(outcome["bad name.pdf"], .rejectedName)
        XCTAssertEqual(r.manifest.ingestedCount, 2)
        XCTAssertEqual(r.manifest.skippedCount, 3)
        XCTAssertNotNil(r.manifest.walSHA256)
    }

    func testIngestLegacySingleDBIgnoresSiblingWalAndHasNoAttachments() throws {
        let base = try trackedTempDir()
        let dbURL = base.appendingPathComponent("standalone.db")
        try writeBytes("db", to: dbURL)
        try writeBytes("stray-wal", to: URL(fileURLWithPath: dbURL.path + "-wal"))   // must be IGNORED
        let id = newImportID(); defer { cleanStaging(id) }

        let r = try StagingIngest().ingest(.legacySingleDB(dbURL), importID: id, timestamp: "t")
        XCTAssertNil(r.stagedWALURL, "legacySingleDB must NOT read a sibling -wal")
        XCTAssertFalse(fm.fileExists(atPath: r.stagedDatabaseURL.path + "-wal"))
        XCTAssertNil(r.stagedAttachmentsDir)
        XCTAssertNil(r.manifest.walSHA256, "no WAL → walSHA256 explicitly nil")
        XCTAssertFalse(r.manifest.snapshotIdentitySHA256.isEmpty)
    }

    func testIngestExportBundleHasNoWalEvenIfStrayWalPresent() throws {
        let bundle = try trackedTempDir().appendingPathComponent("bundle", isDirectory: true)
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        let dbURL = bundle.appendingPathComponent("sololedger.db")
        try writeBytes("db", to: dbURL)
        try writeBytes("stray", to: URL(fileURLWithPath: dbURL.path + "-wal"))   // must be IGNORED
        let docs = bundle.appendingPathComponent("attachments", isDirectory: true).appendingPathComponent("docs", isDirectory: true)
        try fm.createDirectory(at: docs, withIntermediateDirectories: true)
        try writeBytes("a", to: docs.appendingPathComponent("doc-a.pdf"))
        let id = newImportID(); defer { cleanStaging(id) }

        let r = try StagingIngest().ingest(.exportBundle(bundle), importID: id, timestamp: "t")
        XCTAssertNil(r.stagedWALURL, "export bundle is pre-checkpointed — no WAL copied")
        XCTAssertNil(r.manifest.walSHA256)
        XCTAssertEqual(r.manifest.ingestedCount, 1)
    }

    // MARK: - WAL identity

    func testWALIdentityDiffersForDifferentWalSameDb() throws {
        func makeWalFixture(_ wal: String) throws -> URL {
            let dir = try trackedTempDir().appendingPathComponent("SoloLedger", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let db = dir.appendingPathComponent("sololedger.db")
            try writeBytes("identical-db", to: db)
            try writeBytes(wal, to: URL(fileURLWithPath: db.path + "-wal"))
            return dir
        }
        let idA = newImportID(); defer { cleanStaging(idA) }
        let idB = newImportID(); defer { cleanStaging(idB) }
        let a = try StagingIngest().ingest(.userSelectedDataDir(makeWalFixture("wal-one")), importID: idA, timestamp: "t")
        let b = try StagingIngest().ingest(.userSelectedDataDir(makeWalFixture("wal-TWO")), importID: idB, timestamp: "t")

        XCTAssertEqual(a.manifest.sourceDBSHA256, b.manifest.sourceDBSHA256, "same main DB → same DB hash")
        XCTAssertNotEqual(a.manifest.walSHA256, b.manifest.walSHA256, "different WAL → different WAL hash")
        XCTAssertNotEqual(a.manifest.snapshotIdentitySHA256, b.manifest.snapshotIdentitySHA256,
                          "same DB but different WAL MUST yield a different snapshot identity")
    }

    // MARK: - importID already exists → reject (never silently overwrite)

    func testDuplicateImportIDIsRejected() throws {
        let dir = try makeDataDirFixture(withWal: false, withAttachments: false)
        let id = newImportID(); defer { cleanStaging(id) }
        _ = try StagingIngest().ingest(.userSelectedDataDir(dir), importID: id, timestamp: "t")

        XCTAssertThrowsError(try StagingIngest().ingest(.userSelectedDataDir(dir), importID: id, timestamp: "t")) { e in
            guard case IngestError.importIDAlreadyExists(let got) = e else { return XCTFail("expected importIDAlreadyExists, got \(e)") }
            XCTAssertEqual(got, id.rawValue)
        }
    }

    // MARK: - Concurrent-change handling

    func testIngestRetriesThenSucceedsWhenSourceStabilizes() throws {
        let dir = try makeDataDirFixture(withWal: false, withAttachments: true)
        let dbURL = dir.appendingPathComponent("sololedger.db")
        let id = newImportID(); defer { cleanStaging(id) }
        let before = attemptNames()

        let r = try StagingIngest().ingest(.userSelectedDataDir(dir), importID: id, timestamp: "t", maxAttempts: 3,
                                           hooks: IngestHooks(onRecheck: { attempt in
            if attempt == 1 {   // change source on attempt 1 only → attempt 2 is stable
                let h = try FileHandle(forWritingTo: dbURL); defer { try? h.close() }
                try h.seekToEnd(); h.write(Data([0x2A]))
            }
        }))
        XCTAssertTrue(finalExists(id))
        XCTAssertEqual(r.manifest.ingestedCount, 2)
        XCTAssertTrue(attemptNames().isSubset(of: before), "no attempt temp dir left behind after success")
    }

    func testIngestThrowsSourceBusyWhenSourceKeepsChanging() throws {
        let dir = try makeDataDirFixture(withWal: false, withAttachments: false)
        let dbURL = dir.appendingPathComponent("sololedger.db")
        let id = newImportID(); defer { cleanStaging(id) }
        let before = attemptNames()

        XCTAssertThrowsError(try StagingIngest().ingest(.userSelectedDataDir(dir), importID: id, timestamp: "t", maxAttempts: 2,
                                                        hooks: IngestHooks(onRecheck: { _ in
            let h = try FileHandle(forWritingTo: dbURL); defer { try? h.close() }
            try h.seekToEnd(); h.write(Data([0x2A]))   // changes every attempt → never stable
        }))) { e in
            guard case IngestError.sourceBusy(let attempts) = e else { return XCTFail("expected sourceBusy, got \(e)") }
            XCTAssertEqual(attempts, 2)
        }
        XCTAssertFalse(finalExists(id), "sourceBusy must not publish")
        XCTAssertTrue(attemptNames().isSubset(of: before), "every failed attempt temp dir is cleaned")
    }

    // MARK: - Failure atomicity (fault injection): never publish, always clean

    private func assertFaultCleansUp(_ hooks: IngestHooks, withAttachments: Bool = true, file: StaticString = #filePath, line: UInt = #line) throws {
        let dir = try makeDataDirFixture(withWal: true, withAttachments: withAttachments)
        let id = newImportID(); defer { cleanStaging(id) }
        let before = attemptNames()
        XCTAssertThrowsError(try StagingIngest().ingest(.userSelectedDataDir(dir), importID: id, timestamp: "t",
                                                        maxAttempts: 3, hooks: hooks), file: file, line: line)
        XCTAssertFalse(finalExists(id), "a failed attempt must never publish", file: file, line: line)
        XCTAssertTrue(attemptNames().isSubset(of: before), "the failed attempt temp dir must be cleaned", file: file, line: line)
    }

    func testFaultDuringDbCopyCleansUpAndDoesNotPublish() throws {
        try assertFaultCleansUp(IngestHooks(onStep: { if $0 == .afterDatabaseCopy { throw TestError() } }))
    }

    func testFaultDuringAttachmentCopyCleansUpAndDoesNotPublish() throws {
        try assertFaultCleansUp(IngestHooks(onStep: { if $0 == .duringAttachmentCopy { throw TestError() } }))
    }

    func testFaultDuringManifestWriteCleansUpAndDoesNotPublish() throws {
        try assertFaultCleansUp(IngestHooks(onStep: { if $0 == .beforeManifestWrite { throw TestError() } }))
    }

    func testCleanupFailureSurfacesAsCleanupFailed() throws {
        let dir = try makeDataDirFixture(withWal: false, withAttachments: false)
        let id = newImportID(); defer { cleanStaging(id) }
        let before = attemptNames()
        // A copy fault plus a cleanup that also fails → the cleanup failure is SURFACED (not swallowed).
        XCTAssertThrowsError(try StagingIngest().ingest(.userSelectedDataDir(dir), importID: id, timestamp: "t", maxAttempts: 1,
                                                        hooks: IngestHooks(onStep: { if $0 == .afterDatabaseCopy { throw TestError() } },
                                                                           cleanup: { _ in throw CleanupError() }))) { e in
            guard case IngestError.cleanupFailed = e else { return XCTFail("expected cleanupFailed, got \(e)") }
        }
        XCTAssertFalse(finalExists(id))
        removeNewAttempts(since: before)   // cleanup was (intentionally) prevented — tidy up the leftover here
    }

    // MARK: - Trust boundary: non-regular sources fail closed (2B-2 S2)

    /// The source DB must be an existing REGULAR file: a symlink (even to a valid DB),
    /// a dangling symlink, a directory or a FIFO is rejected fail-closed — never followed,
    /// never opened blocking, never copied.
    func testSourceDBNonRegularFailsClosed() throws {
        for kind in ["symlink", "dangling", "directory", "fifo"] {
            let dir = try makeDataDirFixture(withWal: false, withAttachments: false)
            let dbURL = dir.appendingPathComponent("sololedger.db")
            try fm.removeItem(at: dbURL)
            switch kind {
            case "symlink":
                let real = try trackedTempDir().appendingPathComponent("real.db")
                try writeBytes("real-db", to: real)
                try fm.createSymbolicLink(at: dbURL, withDestinationURL: real)
            case "dangling":
                try fm.createSymbolicLink(at: dbURL, withDestinationURL: dir.appendingPathComponent("absent"))
            case "directory":
                try fm.createDirectory(at: dbURL, withIntermediateDirectories: true)
            default:
                guard mkfifo(dbURL.path, 0o644) == 0 else { throw XCTSkip("mkfifo unavailable") }
            }
            let id = newImportID(); defer { cleanStaging(id) }
            let before = attemptNames()
            XCTAssertThrowsError(try StagingIngest().ingest(.userSelectedDataDir(dir), importID: id, timestamp: "t"), kind) { e in
                guard case IngestError.sourceNotRegularFile(let p) = e else { return XCTFail("\(kind): got \(e)") }
                XCTAssertEqual(p, dbURL.path)
            }
            XCTAssertFalse(finalExists(id), kind)
            XCTAssertTrue(attemptNames().isSubset(of: before), kind)
        }
    }

    func testSourceWalNonRegularFailsClosed() throws {
        for kind in ["symlink", "fifo"] {
            let dir = try makeDataDirFixture(withWal: false, withAttachments: false)
            let walURL = URL(fileURLWithPath: dir.appendingPathComponent("sololedger.db").path + "-wal")
            switch kind {
            case "symlink":
                let real = try trackedTempDir().appendingPathComponent("real-wal")
                try writeBytes("wal-bytes", to: real)
                try fm.createSymbolicLink(at: walURL, withDestinationURL: real)
            default:
                guard mkfifo(walURL.path, 0o644) == 0 else { throw XCTSkip("mkfifo unavailable") }
            }
            let id = newImportID(); defer { cleanStaging(id) }
            XCTAssertThrowsError(try StagingIngest().ingest(.userSelectedDataDir(dir), importID: id, timestamp: "t"), kind) { e in
                guard case IngestError.sourceNotRegularFile(let p) = e else { return XCTFail("\(kind): got \(e)") }
                XCTAssertEqual(p, walURL.path)
            }
            XCTAssertFalse(finalExists(id), kind)
        }
    }

    /// attachments/docs: ENOENT ⇒ "no attachments" (fine); anything present must be a REAL
    /// non-symlink directory — a symlinked root (final component) or a plain file is rejected.
    func testAttachmentsRootMustBeARealDirectory() throws {
        for kind in ["symlink", "file"] {
            let dir = try makeDataDirFixture(withWal: false, withAttachments: false)
            let attachments = dir.appendingPathComponent("attachments", isDirectory: true)
            try fm.createDirectory(at: attachments, withIntermediateDirectories: true)
            let docs = attachments.appendingPathComponent("docs")
            if kind == "symlink" {
                let real = try trackedTempDir().appendingPathComponent("real-docs", isDirectory: true)
                try fm.createDirectory(at: real, withIntermediateDirectories: true)
                try writeBytes("a", to: real.appendingPathComponent("doc-a.pdf"))
                try fm.createSymbolicLink(at: docs, withDestinationURL: real)
            } else {
                try writeBytes("not-a-dir", to: docs)
            }
            let id = newImportID(); defer { cleanStaging(id) }
            XCTAssertThrowsError(try StagingIngest().ingest(.userSelectedDataDir(dir), importID: id, timestamp: "t"), kind) { e in
                guard case IngestError.attachmentsRootNotADirectory = e else { return XCTFail("\(kind): got \(e)") }
            }
            XCTAssertFalse(finalExists(id), kind)
        }
    }

    // MARK: - Post-classification races (2B-2 S2)

    /// Classified as a regular file, swapped for a FIFO before its copy: the fd-bound copy
    /// gate must reject it IMMEDIATELY at copy time (no hang, no reliance on the later
    /// manifest hash), clean the attempt and never publish.
    func testAttachmentSwappedToFifoAfterClassificationFailsImmediately() throws {
        let dir = try makeDataDirFixture(withWal: false, withAttachments: true)
        let victim = dir.appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent("docs", isDirectory: true).appendingPathComponent("doc-a.pdf")
        let id = newImportID(); defer { cleanStaging(id) }
        let before = attemptNames()
        var swapped = false
        let hooks = IngestHooks(onStep: { step in
            if step == .duringAttachmentCopy && !swapped {
                swapped = true
                try self.fm.removeItem(at: victim)
                guard mkfifo(victim.path, 0o644) == 0 else { throw TestError() }
            }
        })
        XCTAssertThrowsError(try StagingIngest().ingest(.userSelectedDataDir(dir), importID: id, timestamp: "t",
                                                        maxAttempts: 3, hooks: hooks)) { e in
            guard case IngestError.sourceNotRegularFile(let p) = e else { return XCTFail("got \(e)") }
            // contentsOfDirectory may hand back /private/var for a /var fixture — compare resolved.
            XCTAssertEqual(URL(fileURLWithPath: p).resolvingSymlinksInPath().path,
                           victim.resolvingSymlinksInPath().path)
        }
        XCTAssertTrue(swapped)
        XCTAssertFalse(finalExists(id))
        XCTAssertTrue(attemptNames().isSubset(of: before))
    }

    /// Same-size replacement with the mtime forged back to the original: the inode change
    /// must still trip the stability fingerprint and force a retry (a size+mtime-only
    /// fingerprint accepted this silently).
    func testInodeSwapWithForgedMtimeTriggersRetryThenSucceeds() throws {
        let dir = try makeDataDirFixture(withWal: false, withAttachments: true)
        let victim = dir.appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent("docs", isDirectory: true).appendingPathComponent("doc-a.pdf")
        let id = newImportID(); defer { cleanStaging(id) }
        var rechecks = 0
        let hooks = IngestHooks(onRecheck: { _ in
            rechecks += 1
            guard rechecks == 1 else { return }   // only sabotage attempt 1
            let fp = try XCTUnwrap(FileFingerprint.capture(at: victim))
            let mtime = Date(timeIntervalSince1970: TimeInterval(fp.mtimeSec) + TimeInterval(fp.mtimeNSec) / 1e9)
            try self.fm.removeItem(at: victim)
            try self.writeBytes("pdf-X", to: victim)              // same 5-byte size as "pdf-a"
            try self.fm.setAttributes([.modificationDate: mtime], ofItemAtPath: victim.path)
            let swapped = try XCTUnwrap(FileFingerprint.capture(at: victim))
            XCTAssertEqual(swapped.size, fp.size, "swap must preserve size for this test to prove anything")
            XCTAssertNotEqual(swapped.inode, fp.inode)
        })
        let result = try StagingIngest().ingest(.userSelectedDataDir(dir), importID: id, timestamp: "t",
                                                maxAttempts: 3, hooks: hooks)
        XCTAssertEqual(rechecks, 2, "attempt 1 must be discarded, attempt 2 published")
        let staged = try XCTUnwrap(result.stagedAttachmentsDir).appendingPathComponent("doc-a.pdf")
        XCTAssertEqual(try Data(contentsOf: staged), Data("pdf-X".utf8), "attempt 2 staged the post-swap content")
        XCTAssertEqual(result.manifest.files.first { $0.name == "doc-a.pdf" }?.sha256,
                       try FileHash.sha256HexOfRegularFile(at: staged))
    }

    /// An entry that vanishes between classification and its copy (ENOENT) is treated as a
    /// source change: retry, then publish the source's new steady state — never a silent skip
    /// of a file the manifest would still have promised.
    func testAttachmentVanishingMidCopyRetriesThenPublishesWithoutIt() throws {
        let dir = try makeDataDirFixture(withWal: false, withAttachments: true)
        let victim = dir.appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent("docs", isDirectory: true).appendingPathComponent("doc-b.jpg")
        let id = newImportID(); defer { cleanStaging(id) }
        var copies = 0
        let hooks = IngestHooks(onStep: { step in
            if step == .duringAttachmentCopy {
                copies += 1
                if copies == 2 { try self.fm.removeItem(at: victim) }   // vanish right before ITS copy
            }
        })
        let result = try StagingIngest().ingest(.userSelectedDataDir(dir), importID: id, timestamp: "t",
                                                maxAttempts: 3, hooks: hooks)
        XCTAssertEqual(copies, 3, "attempt 1: doc-a + doc-b(vanished) → retry; attempt 2: doc-a only")
        XCTAssertNil(result.manifest.files.first { $0.name == "doc-b.jpg" }, "the vanished file is not promised")
        XCTAssertEqual(result.manifest.files.first { $0.name == "doc-a.pdf" }?.outcome, .ingested)
    }

    /// A STAGED file tampered between copy and manifest build fails the copy-digest
    /// consistency re-check — the manifest can never describe bytes other than the ones
    /// the verified copy wrote.
    func testStagedTamperAfterCopyFailsConsistencyCheck() throws {
        let dir = try makeDataDirFixture(withWal: false, withAttachments: false)
        let id = newImportID(); defer { cleanStaging(id) }
        let before = attemptNames()
        let hooks = IngestHooks(onRecheck: { _ in
            // Locate this run's attempt dir and corrupt the staged DB copy.
            let root = try AppPaths.stagingRootDirectory()
            let attempts = try self.fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix(".attempt-") && !before.contains($0.lastPathComponent) }
            let staged = try XCTUnwrap(attempts.first).appendingPathComponent("sololedger.db")
            let h = try FileHandle(forWritingTo: staged); defer { try? h.close() }
            try h.seekToEnd(); try h.write(contentsOf: Data([0xFF]))
        })
        XCTAssertThrowsError(try StagingIngest().ingest(.userSelectedDataDir(dir), importID: id, timestamp: "t",
                                                        maxAttempts: 1, hooks: hooks)) { e in
            guard case IngestError.stagedContentInconsistent(let what) = e else { return XCTFail("got \(e)") }
            XCTAssertEqual(what, "db")
        }
        XCTAssertFalse(finalExists(id))
        XCTAssertTrue(attemptNames().isSubset(of: before))
    }

    // MARK: - Pre-publish integrity gate (2B-2 S4)

    /// Locate the current run's fresh `.attempt-*` dir (exactly one) from inside a hook.
    private func currentAttemptDir(since before: Set<String>) throws -> URL {
        let root = try AppPaths.stagingRootDirectory()
        let fresh = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".attempt-") && !before.contains($0.lastPathComponent) }
        return try XCTUnwrap(fresh.first)
    }

    /// Run one ingest with a `.beforePublish` saboteur; assert stagedContentInconsistent,
    /// no publish, no attempt residue, and byte-identical sources.
    private func assertPublishGateRejects(_ label: String, withWal: Bool = true, withAttachments: Bool = true,
                                          sabotage: @escaping (URL) throws -> Void,
                                          file: StaticString = #filePath, line: UInt = #line) throws {
        let dir = try makeDataDirFixture(withWal: withWal, withAttachments: withAttachments)
        let sourceHashesBefore = try sourceHashes(dir)
        let id = newImportID(); defer { cleanStaging(id) }
        let before = attemptNames()
        let hooks = IngestHooks(onStep: { step in
            if step == .beforePublish { try sabotage(try self.currentAttemptDir(since: before)) }
        })
        XCTAssertThrowsError(try StagingIngest().ingest(.userSelectedDataDir(dir), importID: id, timestamp: "t",
                                                        maxAttempts: 1, hooks: hooks), label, file: file, line: line) { e in
            guard case IngestError.stagedContentInconsistent = e else {
                return XCTFail("\(label): got \(e)", file: file, line: line)
            }
        }
        XCTAssertFalse(finalExists(id), "\(label): must not publish", file: file, line: line)
        XCTAssertTrue(attemptNames().isSubset(of: before), "\(label): attempt cleaned", file: file, line: line)
        XCTAssertEqual(try sourceHashes(dir), sourceHashesBefore, "\(label): source untouched", file: file, line: line)
    }

    private func sourceHashes(_ dir: URL) throws -> [String: String] {
        var out: [String: String] = [:]
        let db = dir.appendingPathComponent("sololedger.db")
        out["db"] = try FileHash.sha256Hex(of: db)
        let wal = URL(fileURLWithPath: db.path + "-wal")
        if fm.fileExists(atPath: wal.path) { out["wal"] = try FileHash.sha256Hex(of: wal) }
        let docs = dir.appendingPathComponent("attachments/docs")
        for name in ["doc-a.pdf", "doc-b.jpg"] {
            let f = docs.appendingPathComponent(name)
            if fm.fileExists(atPath: f.path) { out[name] = try FileHash.sha256Hex(of: f) }
        }
        return out
    }

    /// Staged DB / WAL / attachment content tampered AFTER the manifest was written:
    /// the pre-publish gate must reject each one.
    func testTamperAfterManifestWriteRejectsPublish() throws {
        func append(_ url: URL) throws {
            let h = try FileHandle(forWritingTo: url); defer { try? h.close() }
            try h.seekToEnd(); try h.write(contentsOf: Data([0x00]))
        }
        try assertPublishGateRejects("db tamper") { try append($0.appendingPathComponent("sololedger.db")) }
        try assertPublishGateRejects("wal tamper") { try append(URL(fileURLWithPath: $0.appendingPathComponent("sololedger.db").path + "-wal")) }
        try assertPublishGateRejects("attachment tamper") { try append($0.appendingPathComponent("attachments/docs/doc-a.pdf")) }
        // A same-size REPLACEMENT (not just an append) is caught by the content hash.
        try assertPublishGateRejects("attachment replace") { attempt in
            let f = attempt.appendingPathComponent("attachments/docs/doc-a.pdf")
            try self.fm.removeItem(at: f)
            try Data("pdf-X".utf8).write(to: f)   // same 5-byte size as "pdf-a"
        }
    }

    /// The staged WAL swapped for a symlink / directory / FIFO right before publish:
    /// immediate fail-closed rejection, no follow, no hang.
    func testWalSwappedForNonRegularBeforePublishFailsClosed() throws {
        for kind in ["symlink", "directory", "fifo"] {
            try assertPublishGateRejects("wal → \(kind)") { attempt in
                let wal = URL(fileURLWithPath: attempt.appendingPathComponent("sololedger.db").path + "-wal")
                let original = try Data(contentsOf: wal)
                try self.fm.removeItem(at: wal)
                switch kind {
                case "symlink":
                    let elsewhere = try self.trackedTempDir().appendingPathComponent("wal-copy")
                    try original.write(to: elsewhere)   // identical bytes behind the link
                    try self.fm.createSymbolicLink(at: wal, withDestinationURL: elsewhere)
                case "directory":
                    try self.fm.createDirectory(at: wal, withIntermediateDirectories: true)
                default:
                    guard mkfifo(wal.path, 0o644) == 0 else { throw TestError() }
                }
            }
        }
        // A WAL that simply DISAPPEARS after the manifest recorded it is equally fatal.
        try assertPublishGateRejects("wal removed") { attempt in
            try self.fm.removeItem(at: URL(fileURLWithPath: attempt.appendingPathComponent("sololedger.db").path + "-wal"))
        }
        // And a WAL APPEARING when none was recorded (fixture without one).
        try assertPublishGateRejects("wal planted", withWal: false) { attempt in
            try Data("stray".utf8).write(to: URL(fileURLWithPath: attempt.appendingPathComponent("sololedger.db").path + "-wal"))
        }
    }

    /// manifest.json tampered (field flip, truncation, symlink swap) after being written:
    /// the gate re-reads it through a verified fd and requires full-field equality.
    func testManifestTamperBeforePublishRejected() throws {
        try assertPublishGateRejects("manifest field flip") { attempt in
            let url = attempt.appendingPathComponent("manifest.json")
            var m = try JSONDecoder().decode(ImportManifest.self, from: Data(contentsOf: url))
            m.sourceDBSHA256 = String(m.sourceDBSHA256.reversed())
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(m).write(to: url)
        }
        try assertPublishGateRejects("manifest truncated") { attempt in
            let url = attempt.appendingPathComponent("manifest.json")
            let h = try FileHandle(forWritingTo: url); defer { try? h.close() }
            try h.truncate(atOffset: 10)
        }
        try assertPublishGateRejects("manifest symlink swap") { attempt in
            let url = attempt.appendingPathComponent("manifest.json")
            let copy = try self.trackedTempDir().appendingPathComponent("manifest.json")
            try self.fm.copyItem(at: url, to: copy)   // identical bytes behind the link
            try self.fm.removeItem(at: url)
            try self.fm.createSymbolicLink(at: url, withDestinationURL: copy)
        }
    }

    // MARK: - WAL presence flips inside the stability window (2B-2 S4)

    func testWalDisappearingInWindowRetriesThenPublishesWithoutIt() throws {
        let dir = try makeDataDirFixture(withWal: true, withAttachments: false)
        let walURL = URL(fileURLWithPath: dir.appendingPathComponent("sololedger.db").path + "-wal")
        let id = newImportID(); defer { cleanStaging(id) }
        var rechecks = 0
        let result = try StagingIngest().ingest(.userSelectedDataDir(dir), importID: id, timestamp: "t", maxAttempts: 3,
                                                hooks: IngestHooks(onRecheck: { _ in
            rechecks += 1
            if rechecks == 1 { try self.fm.removeItem(at: walURL) }   // checkpoint finished mid-window
        }))
        XCTAssertEqual(rechecks, 2, "attempt 1 discarded, attempt 2 published")
        XCTAssertNil(result.manifest.walSHA256)
        XCTAssertNil(result.stagedWALURL)
        XCTAssertFalse(fm.fileExists(atPath: result.stagedDatabaseURL.path + "-wal"))
    }

    func testWalAppearingInWindowRetriesThenPublishesWithIt() throws {
        let dir = try makeDataDirFixture(withWal: false, withAttachments: false)
        let walURL = URL(fileURLWithPath: dir.appendingPathComponent("sololedger.db").path + "-wal")
        let id = newImportID(); defer { cleanStaging(id) }
        var rechecks = 0
        let result = try StagingIngest().ingest(.userSelectedDataDir(dir), importID: id, timestamp: "t", maxAttempts: 3,
                                                hooks: IngestHooks(onRecheck: { _ in
            rechecks += 1
            if rechecks == 1 { try Data("late-wal".utf8).write(to: walURL) }   // writer became active
        }))
        XCTAssertEqual(rechecks, 2, "attempt 1 discarded, attempt 2 published")
        XCTAssertEqual(result.manifest.walSHA256, try FileHash.sha256Hex(of: walURL))
        XCTAssertNotNil(result.stagedWALURL)
        XCTAssertTrue(fm.fileExists(atPath: result.stagedDatabaseURL.path + "-wal"))
    }

    // MARK: - Manifest write must never follow a pre-planted link (2B-2 S5)

    func testManifestWriteNeverFollowsPreplantedSymlink() throws {
        // Variant A: link → an EXTERNAL sentinel file that must stay byte-identical.
        // Variant B: dangling link → a path that must NEVER come into existence.
        for variant in ["sentinel", "dangling"] {
            let dir = try makeDataDirFixture(withWal: false, withAttachments: false)
            let external = try trackedTempDir()
            let sentinel = external.appendingPathComponent("sentinel.json")
            let neverCreated = external.appendingPathComponent("never-created.json")
            if variant == "sentinel" { try Data("SENTINEL".utf8).write(to: sentinel) }

            let id = newImportID(); defer { cleanStaging(id) }
            let before = attemptNames()
            let hooks = IngestHooks(onStep: { step in
                if step == .beforeManifestWrite {
                    let attempt = try self.currentAttemptDir(since: before)
                    try self.fm.createSymbolicLink(at: attempt.appendingPathComponent("manifest.json"),
                                                   withDestinationURL: variant == "sentinel" ? sentinel : neverCreated)
                }
            })
            XCTAssertThrowsError(try StagingIngest().ingest(.userSelectedDataDir(dir), importID: id, timestamp: "t",
                                                            maxAttempts: 1, hooks: hooks), variant) { e in
                guard let fe = e as? FileHashError, case .destinationUnwritable = fe else {
                    return XCTFail("\(variant): got \(e)")
                }
            }
            if variant == "sentinel" {
                XCTAssertEqual(try Data(contentsOf: sentinel), Data("SENTINEL".utf8),
                               "the planted link's target must be byte-identical")
            } else {
                XCTAssertNil(try FileFingerprint.capture(at: neverCreated),
                             "nothing may be created through the dangling link")
            }
            XCTAssertFalse(finalExists(id), variant)
            XCTAssertTrue(attemptNames().isSubset(of: before), "\(variant): attempt (incl. planted link) cleaned")
        }
    }

    // MARK: - Descriptor-rooted final gate (2B-2 S5)

    /// The attempt ENTRY itself swapped for a symlink (to the real, byte-identical tree,
    /// or dangling): O_NOFOLLOW|O_DIRECTORY refuses it; cleanup removes the LINK (lstat
    /// semantics) and never reaches through it.
    func testAttemptEntrySwappedForSymlinkFailsClosed() throws {
        for variant in ["real-target", "dangling"] {
            let dir = try makeDataDirFixture(withWal: false, withAttachments: true)
            let aside = try trackedTempDir().appendingPathComponent("aside", isDirectory: true)
            let id = newImportID(); defer { cleanStaging(id) }
            let before = attemptNames()
            let hooks = IngestHooks(onStep: { step in
                if step == .beforePublish {
                    let attempt = try self.currentAttemptDir(since: before)
                    if variant == "real-target" {
                        try self.fm.moveItem(at: attempt, to: aside)          // the very same bytes...
                        try self.fm.createSymbolicLink(at: attempt, withDestinationURL: aside)
                    } else {
                        try self.fm.removeItem(at: attempt)
                        try self.fm.createSymbolicLink(at: attempt,
                                                       withDestinationURL: aside.appendingPathComponent("gone"))
                    }
                }
            })
            XCTAssertThrowsError(try StagingIngest().ingest(.userSelectedDataDir(dir), importID: id, timestamp: "t",
                                                            maxAttempts: 1, hooks: hooks), variant) { e in
                guard case IngestError.stagedContentInconsistent = e else { return XCTFail("\(variant): got \(e)") }
            }
            XCTAssertFalse(finalExists(id), variant)
            XCTAssertTrue(attemptNames().isSubset(of: before), "\(variant): dangling/planted attempt link cleaned")
            if variant == "real-target" {
                XCTAssertTrue(fm.fileExists(atPath: aside.appendingPathComponent("manifest.json").path),
                              "cleanup must remove the LINK, never the tree behind it")
            }
        }
    }

    /// `attachments` / `docs` swapped for symlinks pointing at directories with the SAME
    /// bytes: openat(O_NOFOLLOW|O_DIRECTORY) refuses the hop.
    func testAttachmentsOrDocsSwappedForSymlinkFailsClosed() throws {
        for target in ["attachments", "docs"] {
            let dir = try makeDataDirFixture(withWal: false, withAttachments: true)
            let aside = try trackedTempDir().appendingPathComponent("aside", isDirectory: true)
            let id = newImportID(); defer { cleanStaging(id) }
            let before = attemptNames()
            let hooks = IngestHooks(onStep: { step in
                if step == .beforePublish {
                    let attempt = try self.currentAttemptDir(since: before)
                    let victim = target == "attachments"
                        ? attempt.appendingPathComponent("attachments")
                        : attempt.appendingPathComponent("attachments/docs")
                    try self.fm.moveItem(at: victim, to: aside)               // identical bytes behind the link
                    try self.fm.createSymbolicLink(at: victim, withDestinationURL: aside)
                }
            })
            XCTAssertThrowsError(try StagingIngest().ingest(.userSelectedDataDir(dir), importID: id, timestamp: "t",
                                                            maxAttempts: 1, hooks: hooks), target) { e in
                guard case IngestError.stagedContentInconsistent = e else { return XCTFail("\(target): got \(e)") }
            }
            XCTAssertFalse(finalExists(id), target)
            XCTAssertTrue(attemptNames().isSubset(of: before), target)
        }
    }

    /// The tree must contain EXACTLY what the manifest promises: extra attachments,
    /// root-level junk, -shm / -journal sidecars, and on-disk entities for names the
    /// manifest recorded as SKIPPED are all rejected.
    func testExtraEntriesInAttemptRejected() throws {
        let plants: [(String, (URL) throws -> Void)] = [
            ("extra attachment", { try Data("x".utf8).write(to: $0.appendingPathComponent("attachments/docs/extra.pdf")) }),
            ("root junk file", { try Data("x".utf8).write(to: $0.appendingPathComponent("junk.txt")) }),
            ("-shm sidecar", { try Data("x".utf8).write(to: $0.appendingPathComponent("sololedger.db-shm")) }),
            ("-journal sidecar", { try Data("x".utf8).write(to: $0.appendingPathComponent("sololedger.db-journal")) }),
            ("unrecorded wal", { try Data("x".utf8).write(to: $0.appendingPathComponent("sololedger.db-wal")) }),
            ("entity for a skipped name", { try Data("x".utf8).write(to: $0.appendingPathComponent("attachments/docs/link.pdf")) }),
            ("root subdirectory", { try self.fm.createDirectory(at: $0.appendingPathComponent("nested"), withIntermediateDirectories: true) }),
        ]
        for (label, plant) in plants {
            let dir = try makeDataDirFixture(withWal: false, withAttachments: true)
            let id = newImportID(); defer { cleanStaging(id) }
            let before = attemptNames()
            let hooks = IngestHooks(onStep: { step in
                if step == .beforePublish { try plant(try self.currentAttemptDir(since: before)) }
            })
            XCTAssertThrowsError(try StagingIngest().ingest(.userSelectedDataDir(dir), importID: id, timestamp: "t",
                                                            maxAttempts: 1, hooks: hooks), label) { e in
                guard case IngestError.stagedContentInconsistent = e else { return XCTFail("\(label): got \(e)") }
            }
            XCTAssertFalse(finalExists(id), label)
            XCTAssertTrue(attemptNames().isSubset(of: before), label)
        }
    }

    /// AFTER the final gate, BEFORE the rename: the attempt entry replaced by a fresh
    /// directory — the device/inode re-check refuses to publish the impostor.
    func testAttemptReplacedAfterValidationRejected() throws {
        let dir = try makeDataDirFixture(withWal: false, withAttachments: false)
        let aside = try trackedTempDir().appendingPathComponent("aside", isDirectory: true)
        let id = newImportID(); defer { cleanStaging(id) }
        let before = attemptNames()
        let hooks = IngestHooks(onStep: { step in
            if step == .afterValidation {
                let attempt = try self.currentAttemptDir(since: before)
                try self.fm.moveItem(at: attempt, to: aside)
                try self.fm.createDirectory(at: attempt, withIntermediateDirectories: true)   // impostor
            }
        })
        XCTAssertThrowsError(try StagingIngest().ingest(.userSelectedDataDir(dir), importID: id, timestamp: "t",
                                                        maxAttempts: 1, hooks: hooks)) { e in
            guard case IngestError.stagedContentInconsistent(let what) = e else { return XCTFail("got \(e)") }
            XCTAssertTrue(what.contains("after validation"), what)
        }
        XCTAssertFalse(finalExists(id))
        XCTAssertTrue(attemptNames().isSubset(of: before), "the impostor at the attempt path is cleaned")
    }

    // MARK: - Publish race (2B-2 S3; hook corrected to .afterValidation in S5)

    /// A concurrent ingest publishes the same importID inside our window (after the
    /// up-front existence check, before our rename): the loss maps to
    /// importIDAlreadyExists, the winner's directory is byte-for-byte untouched, and only
    /// OUR attempt dir is cleaned.
    func testPublishRaceMapsToImportIDAlreadyExistsAndNeverTouchesTheWinner() throws {
        let dir = try makeDataDirFixture(withWal: false, withAttachments: false)
        let id = newImportID(); defer { cleanStaging(id) }
        let finalDir = try AppPaths.stagedImportDirectory(importID: id)
        let sentinel = finalDir.appendingPathComponent("winner.txt")
        let before = attemptNames()
        let hooks = IngestHooks(onStep: { step in
            if step == .afterValidation {   // genuinely after the final gate, before the rename
                try self.fm.createDirectory(at: finalDir, withIntermediateDirectories: true)
                try Data("winner".utf8).write(to: sentinel)
            }
        })
        XCTAssertThrowsError(try StagingIngest().ingest(.userSelectedDataDir(dir), importID: id, timestamp: "t",
                                                        maxAttempts: 3, hooks: hooks)) { e in
            guard case IngestError.importIDAlreadyExists(let got) = e else { return XCTFail("got \(e)") }
            XCTAssertEqual(got, id.rawValue)
        }
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("winner".utf8), "the winner's dir must be untouched")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: finalDir.path), ["winner.txt"],
                       "nothing of ours may leak into the winner's dir")
        XCTAssertTrue(attemptNames().isSubset(of: before), "only OUR attempt is cleaned")
    }

    // MARK: - Manifest persistence + deterministic hashes

    func testManifestPersistedWithDeterministicHashes() throws {
        let dir = try makeDataDirFixture(withWal: false, withAttachments: true)
        let idA = newImportID(); defer { cleanStaging(idA) }
        let idB = newImportID(); defer { cleanStaging(idB) }

        let a = try StagingIngest().ingest(.userSelectedDataDir(dir), importID: idA, timestamp: "t")
        let manifestFile = a.stagingDir.appendingPathComponent("manifest.json")
        XCTAssertTrue(fm.fileExists(atPath: manifestFile.path))
        XCTAssertEqual(try JSONDecoder().decode(ImportManifest.self, from: Data(contentsOf: manifestFile)), a.manifest)
        XCTAssertEqual(a.manifest.sourceDBSHA256, try FileHash.sha256Hex(of: a.stagedDatabaseURL))

        let b = try StagingIngest().ingest(.userSelectedDataDir(dir), importID: idB, timestamp: "t2")
        XCTAssertEqual(a.manifest.sourceDBSHA256, b.manifest.sourceDBSHA256)
        XCTAssertEqual(a.manifest.attachmentManifestSHA256, b.manifest.attachmentManifestSHA256)
        XCTAssertEqual(a.manifest.snapshotIdentitySHA256, b.manifest.snapshotIdentitySHA256)
        XCTAssertNotEqual(a.manifest.importID, b.manifest.importID)
    }
}
