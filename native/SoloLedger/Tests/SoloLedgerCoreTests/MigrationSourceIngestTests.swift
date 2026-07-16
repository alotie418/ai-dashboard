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
