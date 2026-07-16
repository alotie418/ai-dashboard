import XCTest
@testable import SoloLedgerCore

/// MigrationSource URL wiring + staging ingest: byte-copy the source DB (and its WAL only
/// when legitimate) plus REL_RE-conforming REGULAR attachment files into isolated native
/// staging, skipping symlinks / special files / nested dirs / illegal names, verifying the
/// source did not change mid-copy, and recording an out-of-DB per-import manifest.
/// All fixtures are synthetic/anonymized temp files — no real DB or attachments.
final class MigrationSourceIngestTests: LedgerTestCase {

    private let fm = FileManager.default

    // MARK: - Fixtures (synthetic bytes; ingest never opens the DB, so raw bytes suffice)

    private func writeBytes(_ s: String, to url: URL) throws {
        try Data(s.utf8).write(to: url)
    }

    /// A synthetic Electron data directory: db (+ optional wal) + an attachments/docs tree
    /// containing valid files, a symlink, a nested dir and an illegally-named file.
    private func makeDataDirFixture(withWal: Bool, withAttachments: Bool) throws -> URL {
        let dir = try trackedTempDir().appendingPathComponent("SoloLedger", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("sololedger.db")
        try writeBytes("synthetic-db-bytes", to: dbURL)
        if withWal { try writeBytes("synthetic-wal-bytes", to: URL(fileURLWithPath: dbURL.path + "-wal")) }
        if withAttachments {
            let docs = dir.appendingPathComponent("attachments", isDirectory: true)
                .appendingPathComponent("docs", isDirectory: true)
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

    private func cleanStaging(_ importID: String) {
        if let dir = try? AppPaths.stagingDirectory(importID: importID) { try? fm.removeItem(at: dir) }
    }

    // MARK: - URL wiring

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
        XCTAssertEqual(try bundle.databaseURL(), dir.appendingPathComponent("sololedger.db"))
        XCTAssertNil(try bundle.walURL(), "export bundle must be pre-checkpointed — no WAL")
        XCTAssertNotNil(try bundle.attachmentsRootURL())

        let single = MigrationSource.legacySingleDB(URL(fileURLWithPath: "/tmp/x/foo.db"))
        XCTAssertEqual(try single.databaseURL().lastPathComponent, "foo.db")
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

    // MARK: - Ingest: data dir (db + wal + conforming attachments only)

    func testIngestUserSelectedDataDirCopiesDbWalAndConformingAttachmentsOnly() throws {
        let dir = try makeDataDirFixture(withWal: true, withAttachments: true)
        let id = "test-\(UUID().uuidString)"; defer { cleanStaging(id) }

        let r = try StagingIngest().ingest(.userSelectedDataDir(dir), importID: id, timestamp: "20260101-000000")

        XCTAssertTrue(fm.fileExists(atPath: r.stagedDatabaseURL.path))
        XCTAssertNotNil(r.stagedWALURL); XCTAssertTrue(fm.fileExists(atPath: r.stagedWALURL!.path))
        let docs = try XCTUnwrap(r.stagedAttachmentsDir)
        XCTAssertTrue(fm.fileExists(atPath: docs.appendingPathComponent("doc-a.pdf").path))
        XCTAssertTrue(fm.fileExists(atPath: docs.appendingPathComponent("doc-b.jpg").path))
        // Skipped: symlink, nested dir, illegal name — none materialize in staging.
        XCTAssertFalse(fm.fileExists(atPath: docs.appendingPathComponent("link.pdf").path))
        XCTAssertFalse(fm.fileExists(atPath: docs.appendingPathComponent("sub").path))
        XCTAssertFalse(fm.fileExists(atPath: docs.appendingPathComponent("bad name.pdf").path))

        // Manifest records every entry's outcome.
        var outcome: [String: ImportManifest.FileResult.Outcome] = [:]
        for f in r.manifest.files { outcome[f.name] = f.outcome }
        XCTAssertEqual(outcome["doc-a.pdf"], .ingested)
        XCTAssertEqual(outcome["doc-b.jpg"], .ingested)
        XCTAssertEqual(outcome["link.pdf"], .skippedSymlink)
        XCTAssertEqual(outcome["sub"], .skippedDirectory)
        XCTAssertEqual(outcome["bad name.pdf"], .rejectedName)
        XCTAssertEqual(r.manifest.ingestedCount, 2)
        XCTAssertEqual(r.manifest.skippedCount, 3)
        XCTAssertEqual(r.manifest.sourceKind, "userSelectedDataDir")
    }

    // MARK: - WAL policy per source

    func testIngestLegacySingleDBIgnoresSiblingWalAndHasNoAttachments() throws {
        let base = try trackedTempDir()
        let dbURL = base.appendingPathComponent("standalone.db")
        try writeBytes("db", to: dbURL)
        try writeBytes("stray-wal", to: URL(fileURLWithPath: dbURL.path + "-wal"))   // must be IGNORED
        let id = "test-\(UUID().uuidString)"; defer { cleanStaging(id) }

        let r = try StagingIngest().ingest(.legacySingleDB(dbURL), importID: id, timestamp: "t")
        XCTAssertTrue(fm.fileExists(atPath: r.stagedDatabaseURL.path))
        XCTAssertNil(r.stagedWALURL, "legacySingleDB must NOT read a sibling -wal")
        XCTAssertFalse(fm.fileExists(atPath: r.stagedDatabaseURL.path + "-wal"))
        XCTAssertNil(r.stagedAttachmentsDir)
    }

    func testIngestExportBundleHasNoWalEvenIfStrayWalPresent() throws {
        let bundle = try trackedTempDir().appendingPathComponent("bundle", isDirectory: true)
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        let dbURL = bundle.appendingPathComponent("sololedger.db")
        try writeBytes("db", to: dbURL)
        try writeBytes("stray", to: URL(fileURLWithPath: dbURL.path + "-wal"))   // must be IGNORED
        let docs = bundle.appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent("docs", isDirectory: true)
        try fm.createDirectory(at: docs, withIntermediateDirectories: true)
        try writeBytes("a", to: docs.appendingPathComponent("doc-a.pdf"))
        let id = "test-\(UUID().uuidString)"; defer { cleanStaging(id) }

        let r = try StagingIngest().ingest(.exportBundle(bundle), importID: id, timestamp: "t")
        XCTAssertNil(r.stagedWALURL, "export bundle is pre-checkpointed — no WAL copied")
        XCTAssertFalse(fm.fileExists(atPath: r.stagedDatabaseURL.path + "-wal"))
        XCTAssertEqual(r.manifest.ingestedCount, 1)
    }

    // MARK: - Concurrent-change handling

    func testIngestRetriesThenSucceedsWhenSourceStabilizes() throws {
        let dir = try makeDataDirFixture(withWal: false, withAttachments: true)
        let dbURL = dir.appendingPathComponent("sololedger.db")
        let id = "test-\(UUID().uuidString)"; defer { cleanStaging(id) }

        // Mutate the source (append bytes → size change) ONLY on attempt 1 → attempt 2 is stable.
        let r = try StagingIngest().ingest(.userSelectedDataDir(dir), importID: id, timestamp: "t",
                                           maxAttempts: 3, midAttemptHook: { attempt in
            if attempt == 1 {
                let h = try FileHandle(forWritingTo: dbURL); defer { try? h.close() }
                try h.seekToEnd(); h.write(Data([0x2A]))
            }
        })
        XCTAssertTrue(fm.fileExists(atPath: r.stagedDatabaseURL.path))
        XCTAssertEqual(r.manifest.ingestedCount, 2)
    }

    func testIngestThrowsSourceBusyWhenSourceKeepsChanging() throws {
        let dir = try makeDataDirFixture(withWal: false, withAttachments: false)
        let dbURL = dir.appendingPathComponent("sololedger.db")
        let id = "test-\(UUID().uuidString)"; defer { cleanStaging(id) }

        XCTAssertThrowsError(try StagingIngest().ingest(.userSelectedDataDir(dir), importID: id, timestamp: "t",
                                                        maxAttempts: 2, midAttemptHook: { _ in
            let h = try FileHandle(forWritingTo: dbURL); defer { try? h.close() }
            try h.seekToEnd(); h.write(Data([0x2A]))   // changes every attempt → never stable
        })) { error in
            guard case IngestError.sourceBusy(let attempts) = error else { return XCTFail("expected sourceBusy, got \(error)") }
            XCTAssertEqual(attempts, 2)
        }
        // Staging cleaned up on sourceBusy.
        XCTAssertFalse(fm.fileExists(atPath: (try AppPaths.stagingDirectory(importID: id)).appendingPathComponent("sololedger.db").path))
        cleanStaging(id)
    }

    // MARK: - Manifest persistence + deterministic hashes

    func testManifestPersistedWithDeterministicHashes() throws {
        let dir = try makeDataDirFixture(withWal: false, withAttachments: true)
        let idA = "test-\(UUID().uuidString)"; defer { cleanStaging(idA) }
        let idB = "test-\(UUID().uuidString)"; defer { cleanStaging(idB) }

        let a = try StagingIngest().ingest(.userSelectedDataDir(dir), importID: idA, timestamp: "t")
        // manifest.json persisted in staging (out-of-DB record).
        let manifestFile = a.stagingDir.appendingPathComponent("manifest.json")
        XCTAssertTrue(fm.fileExists(atPath: manifestFile.path))
        let decoded = try JSONDecoder().decode(ImportManifest.self, from: Data(contentsOf: manifestFile))
        XCTAssertEqual(decoded, a.manifest)

        // sourceDBSHA256 is the streaming hash of the staged DB.
        XCTAssertEqual(a.manifest.sourceDBSHA256, try FileHash.sha256Hex(of: a.stagedDatabaseURL))
        XCTAssertFalse(a.manifest.attachmentManifestSHA256.isEmpty)

        // Identical source content → identical content hashes (deterministic), regardless of import ID.
        let b = try StagingIngest().ingest(.userSelectedDataDir(dir), importID: idB, timestamp: "t2")
        XCTAssertEqual(a.manifest.sourceDBSHA256, b.manifest.sourceDBSHA256)
        XCTAssertEqual(a.manifest.attachmentManifestSHA256, b.manifest.attachmentManifestSHA256)
        XCTAssertNotEqual(a.manifest.importID, b.manifest.importID)
    }
}
