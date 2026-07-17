import XCTest
@testable import SoloLedgerCore

/// Descriptor-rooted staged-snapshot gate (Phase 2B-3 C2). The gate validates a PUBLISHED
/// staging dir against its manifest.json + the filesystem, and NEVER opens the staged SQLite
/// database. All fixtures are synthetic temp files — the "DB" bytes are arbitrary (the gate
/// only hashes them), which itself proves it never tries to open them as SQLite.
final class StagedSnapshotGateTests: LedgerTestCase {

    private let fm = FileManager.default

    // MARK: - Fixture: a genuine published staging via real ingest

    /// Build a source data dir and run the REAL StagingIngest to publish a self-consistent
    /// staging dir + manifest (status .ingested, correct hashes). Returns the published dir.
    private func publishStaging(withWAL: Bool = false, withAttachments: Bool = true) throws -> (dir: URL, id: ImportID) {
        let src = try trackedTempDir().appendingPathComponent("SoloLedger", isDirectory: true)
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        let dbURL = src.appendingPathComponent("sololedger.db")
        try Data("synthetic-db-bytes-not-real-sqlite".utf8).write(to: dbURL)
        if withWAL { try Data("synthetic-wal-bytes".utf8).write(to: URL(fileURLWithPath: dbURL.path + "-wal")) }
        if withAttachments {
            let docs = src.appendingPathComponent("attachments", isDirectory: true).appendingPathComponent("docs", isDirectory: true)
            try fm.createDirectory(at: docs, withIntermediateDirectories: true)
            try Data("pdf-a".utf8).write(to: docs.appendingPathComponent("doc-a.pdf"))
            try Data("jpg-b".utf8).write(to: docs.appendingPathComponent("doc-b.jpg"))
            try fm.createSymbolicLink(at: docs.appendingPathComponent("link.pdf"),
                                      withDestinationURL: docs.appendingPathComponent("doc-a.pdf"))   // skipped
            try Data("bad".utf8).write(to: docs.appendingPathComponent("bad name.pdf"))               // rejectedName
        }
        let id = ImportID("gate-\(UUID().uuidString)")!
        let source: MigrationSource = withWAL ? .userSelectedDataDir(src) : .userSelectedDataDir(src)
        let result = try StagingIngest().ingest(source, importID: id, timestamp: "t")
        return (result.stagingDir, id)
    }

    private func cleanup(_ id: ImportID) { if let d = try? AppPaths.stagedImportDirectory(importID: id) { try? fm.removeItem(at: d) } }
    private func manifestURL(_ dir: URL) -> URL { dir.appendingPathComponent("manifest.json") }
    private func readManifest(_ dir: URL) throws -> ImportManifest {
        try JSONDecoder().decode(ImportManifest.self, from: Data(contentsOf: manifestURL(dir)))
    }
    private func writeManifest(_ m: ImportManifest, to dir: URL) throws {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(m).write(to: manifestURL(dir))
    }
    private func docsDir(_ dir: URL) -> URL {
        dir.appendingPathComponent("attachments", isDirectory: true).appendingPathComponent("docs", isDirectory: true)
    }

    private func assertRejects(_ dir: URL, _ expected: (StagedSnapshotError) -> Bool,
                               _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try StagedSnapshotGate().gate(stagingDir: dir), label, file: file, line: line) { e in
            guard let se = e as? StagedSnapshotError, expected(se) else {
                return XCTFail("\(label): got \(e)", file: file, line: line)
            }
        }
    }

    // MARK: - Happy path

    func testGateAcceptsLegalStagingNoWAL() throws {
        let (dir, id) = try publishStaging(withWAL: false, withAttachments: true); defer { cleanup(id) }
        let gated = try StagedSnapshotGate().gate(stagingDir: dir)
        XCTAssertEqual(gated.importID.rawValue, id.rawValue)
        XCTAssertFalse(gated.hasWAL)
        XCTAssertTrue(gated.hasAttachments)
        XCTAssertEqual(gated.manifest.status, .ingested)
        XCTAssertNil(gated.manifest.walSHA256)
    }

    func testGateAcceptsLegalStagingWithWAL() throws {
        let (dir, id) = try publishStaging(withWAL: true, withAttachments: false); defer { cleanup(id) }
        let gated = try StagedSnapshotGate().gate(stagingDir: dir)
        XCTAssertTrue(gated.hasWAL)
        XCTAssertFalse(gated.hasAttachments)
        XCTAssertNotNil(gated.manifest.walSHA256)
    }

    /// Regression (2B-3 C4): ingest publishes an attachments/docs dir whenever the source
    /// docs folder had ANY entry — even if every entry was SKIPPED (symlink / subdir / invalid
    /// name like a .DS_Store). The gate must ACCEPT that legitimately-published staging, not
    /// reject it on a root-entry-set mismatch. (The docs dir is empty on disk; manifest.files
    /// carries the skipped entries.)
    func testGateAcceptsStagingWhoseAttachmentsAreAllSkipped() throws {
        let src = try trackedTempDir().appendingPathComponent("SoloLedger", isDirectory: true)
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try Data("db".utf8).write(to: src.appendingPathComponent("sololedger.db"))
        let docs = src.appendingPathComponent("attachments", isDirectory: true).appendingPathComponent("docs", isDirectory: true)
        try fm.createDirectory(at: docs, withIntermediateDirectories: true)
        // ONLY skippable entries — nothing ingestable.
        try fm.createSymbolicLink(at: docs.appendingPathComponent("link.pdf"),
                                  withDestinationURL: docs.appendingPathComponent("nowhere"))
        try Data("cruft".utf8).write(to: docs.appendingPathComponent(".DS_Store"))   // rejectedName
        try fm.createDirectory(at: docs.appendingPathComponent("sub"), withIntermediateDirectories: true)

        let id = ImportID("gate-\(UUID().uuidString)")!; defer { cleanup(id) }
        let result = try StagingIngest().ingest(.userSelectedDataDir(src), importID: id, timestamp: "t")
        // Sanity: ingest DID publish an attachments dir but recorded ZERO ingested files.
        XCTAssertTrue(fm.fileExists(atPath: result.stagingDir.appendingPathComponent("attachments").path))
        XCTAssertFalse(result.manifest.files.contains { $0.outcome == .ingested })
        XCTAssertFalse(result.manifest.files.isEmpty)

        let gated = try StagedSnapshotGate().gate(result)   // must NOT throw
        XCTAssertTrue(gated.hasAttachments, "an all-skipped attachments dir still exists on disk")
    }

    func testGateAcceptsViaIngestResultConvenience() throws {
        let src = try trackedTempDir().appendingPathComponent("SoloLedger", isDirectory: true)
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try Data("db".utf8).write(to: src.appendingPathComponent("sololedger.db"))
        let id = ImportID("gate-\(UUID().uuidString)")!; defer { cleanup(id) }
        let result = try StagingIngest().ingest(.userSelectedDataDir(src), importID: id, timestamp: "t")
        XCTAssertEqual(try StagedSnapshotGate().gate(result).importID.rawValue, id.rawValue)
    }

    // MARK: - Content tampering (digests / entry sets)

    func testTamperedDBBytesRejected() throws {
        let (dir, id) = try publishStaging(); defer { cleanup(id) }
        let db = dir.appendingPathComponent("sololedger.db")
        let h = try FileHandle(forWritingTo: db); try h.seekToEnd(); try h.write(contentsOf: Data([0])); try h.close()
        assertRejects(dir, { if case .snapshotContentInconsistent = $0 { return true }; return false }, "db tamper")
    }

    func testTamperedWALBytesRejected() throws {
        let (dir, id) = try publishStaging(withWAL: true, withAttachments: false); defer { cleanup(id) }
        let wal = URL(fileURLWithPath: dir.appendingPathComponent("sololedger.db").path + "-wal")
        let h = try FileHandle(forWritingTo: wal); try h.seekToEnd(); try h.write(contentsOf: Data([0])); try h.close()
        assertRejects(dir, { if case .snapshotContentInconsistent = $0 { return true }; return false }, "wal tamper")
    }

    func testTamperedAttachmentBytesRejected() throws {
        let (dir, id) = try publishStaging(); defer { cleanup(id) }
        try Data("TAMPERED".utf8).write(to: docsDir(dir).appendingPathComponent("doc-a.pdf"))
        assertRejects(dir, { if case .snapshotContentInconsistent = $0 { return true }; return false }, "attachment tamper")
    }

    func testTamperedAttachmentManifestHashRejected() throws {
        let (dir, id) = try publishStaging(); defer { cleanup(id) }
        var m = try readManifest(dir); m.attachmentManifestSHA256 = "deadbeef"; try writeManifest(m, to: dir)
        assertRejects(dir, { if case .attachmentManifestHashMismatch = $0 { return true }; return false }, "attachmentSetHash")
    }

    func testTamperedSnapshotIdentityRejected() throws {
        // This is precisely why C1 promoted a shared snapshotIdentity recompute.
        let (dir, id) = try publishStaging(); defer { cleanup(id) }
        var m = try readManifest(dir); m.snapshotIdentitySHA256 = String(m.snapshotIdentitySHA256.reversed())
        try writeManifest(m, to: dir)
        assertRejects(dir, { if case .snapshotContentInconsistent = $0 { return true }; return false }, "snapshotIdentity")
    }

    func testExtraRootEntryRejected() throws {
        for junk in ["sololedger.db-shm", "sololedger.db-journal", "stray.txt"] {
            let (dir, id) = try publishStaging(withWAL: false, withAttachments: false); defer { cleanup(id) }
            try Data("x".utf8).write(to: dir.appendingPathComponent(junk))
            assertRejects(dir, { if case .rootEntrySetMismatch = $0 { return true }; return false }, junk)
        }
    }

    func testExtraDocsEntryRejected() throws {
        let (dir, id) = try publishStaging(); defer { cleanup(id) }
        try Data("extra".utf8).write(to: docsDir(dir).appendingPathComponent("extra.pdf"))
        assertRejects(dir, { if case .attachmentTreeMismatch = $0 { return true }; return false }, "extra docs entry")
    }

    // MARK: - WAL presence vs record

    func testWALPlantedWhenUnrecordedRejected() throws {
        let (dir, id) = try publishStaging(withWAL: false, withAttachments: false); defer { cleanup(id) }
        try Data("stray".utf8).write(to: URL(fileURLWithPath: dir.appendingPathComponent("sololedger.db").path + "-wal"))
        assertRejects(dir, { if case .rootEntrySetMismatch = $0 { return true }; return false }, "unrecorded wal")
    }

    func testWALMissingWhenRecordedRejected() throws {
        let (dir, id) = try publishStaging(withWAL: true, withAttachments: false); defer { cleanup(id) }
        try fm.removeItem(at: URL(fileURLWithPath: dir.appendingPathComponent("sololedger.db").path + "-wal"))
        assertRejects(dir, { if case .rootEntrySetMismatch = $0 { return true }; return false }, "missing wal")
    }

    // MARK: - Manifest form / identity binding

    func testStatusCompleteRejected() throws {
        let (dir, id) = try publishStaging(); defer { cleanup(id) }
        var m = try readManifest(dir); m.status = .complete; try writeManifest(m, to: dir)
        assertRejects(dir, { if case .notIngested = $0 { return true }; return false }, "status .complete")
    }

    func testUnsupportedFormatVersionsRejected() throws {
        for bad: Int? in [nil, 0, 1, 3, 999] {
            let (dir, id) = try publishStaging(); defer { cleanup(id) }
            var m = try readManifest(dir); m.formatVersion = bad; try writeManifest(m, to: dir)
            assertRejects(dir, { if case .unsupportedManifestFormat = $0 { return true }; return false }, "fmt \(String(describing: bad))")
        }
    }

    func testNonCanonicalTerminalFieldsRejected() throws {
        let mutations: [(String, (inout ImportManifest) -> Void)] = [
            ("report", { $0.report = "x" }),
            ("applied", { $0.applied = .init(copied: [], skippedIdentical: [], missing: []) }),
            ("unresolved", { $0.unresolved = UnresolvedReport(items: []) }),
            ("ackHash", { $0.acknowledgedReportHash = "x" }),
            ("auditPerformed", { $0.referenceAuditPerformed = true }),
            ("preparedDBIdentity", { $0.preparedDBIdentity = "x" }),
        ]
        for (label, mutate) in mutations {
            let (dir, id) = try publishStaging(); defer { cleanup(id) }
            var m = try readManifest(dir); mutate(&m)
            // Keep attachmentSetHash consistent (these fields are outside it) so the gate
            // reaches the canonical-form check, not the hash check.
            try writeManifest(m, to: dir)
            assertRejects(dir, { if case .nonCanonicalManifest = $0 { return true }; return false }, label)
        }
    }

    func testIngestedFileMissingShaOrSizeRejected() throws {
        let (dir, id) = try publishStaging(); defer { cleanup(id) }
        var m = try readManifest(dir)
        let i = m.files.firstIndex { $0.outcome == .ingested }!
        m.files[i].sha256 = nil
        m.attachmentManifestSHA256 = ImportManifest.attachmentSetHash(m.files)   // keep hash consistent
        try writeManifest(m, to: dir)
        assertRejects(dir, { if case .nonCanonicalManifest = $0 { return true }; return false }, "ingested missing sha")
    }

    func testSkippedFileCarryingPayloadRejected() throws {
        let (dir, id) = try publishStaging(); defer { cleanup(id) }
        var m = try readManifest(dir)
        let i = m.files.firstIndex { $0.outcome != .ingested }!
        m.files[i].sha256 = "deadbeef"; m.files[i].size = 3
        m.attachmentManifestSHA256 = ImportManifest.attachmentSetHash(m.files)   // keep hash consistent
        try writeManifest(m, to: dir)
        assertRejects(dir, { if case .nonCanonicalManifest = $0 { return true }; return false }, "skipped with payload")
    }

    func testImportIDDirNameMismatchRejected() throws {
        let (dir, id) = try publishStaging(); defer { cleanup(id) }
        var m = try readManifest(dir); m.importID = "gate-\(UUID().uuidString)"   // valid ImportID, wrong dir
        m.attachmentManifestSHA256 = ImportManifest.attachmentSetHash(m.files)
        // snapshotIdentity/attachmentSetHash unaffected by importID; recompute not needed.
        try writeManifest(m, to: dir)
        assertRejects(dir, { if case .importIDMismatch = $0 { return true }; return false }, "importID vs dir")
    }

    // MARK: - Descriptor-rooted no-follow (never follows a swapped component)

    func testSymlinkedStagingRootRejected() throws {
        let (dir, id) = try publishStaging(); defer { cleanup(id) }
        let link = try trackedTempDir().appendingPathComponent("import-link")
        try fm.createSymbolicLink(at: link, withDestinationURL: dir)
        assertRejects(link, { if case .stagingUnreadable = $0 { return true }; return false }, "symlinked root")
    }

    func testSymlinkedDBRejected() throws {
        let (dir, id) = try publishStaging(); defer { cleanup(id) }
        let db = dir.appendingPathComponent("sololedger.db")
        let real = try trackedTempDir().appendingPathComponent("real.db")
        try fm.moveItem(at: db, to: real)
        try fm.createSymbolicLink(at: db, withDestinationURL: real)   // same bytes behind the link
        assertRejects(dir, { if case .rootEntrySetMismatch = $0 { return true }; return false }, "symlinked db")
    }

    func testSymlinkedDocsRejected() throws {
        let (dir, id) = try publishStaging(); defer { cleanup(id) }
        let docs = docsDir(dir)
        let aside = try trackedTempDir().appendingPathComponent("aside-docs")
        try fm.moveItem(at: docs, to: aside)
        try fm.createSymbolicLink(at: docs, withDestinationURL: aside)   // identical bytes behind the link
        assertRejects(dir, { if case .attachmentTreeMismatch = $0 { return true }; return false }, "symlinked docs")
    }

    // MARK: - Gate never opens the staged DB as SQLite

    func testGateNeverOpensStagedDatabase() throws {
        // The staged "DB" is not a valid SQLite file; the gate still succeeds because it only
        // hashes bytes. If the gate ever tried to open it, this would throw.
        let (dir, id) = try publishStaging(withWAL: false, withAttachments: false); defer { cleanup(id) }
        XCTAssertNoThrow(try StagedSnapshotGate().gate(stagingDir: dir))
        // And no journal/WAL sidecar was created beside the staged DB by the gate.
        for suffix in ["-wal", "-shm", "-journal"] {
            XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("sololedger.db").path + suffix),
                           "gate must not create \(suffix)")
        }
    }

    // MARK: - Evidence lifetime (reference semantics keeps the descriptor alive)

    func testGatedEvidenceKeepsDescriptorUsableAfterGateReturns() throws {
        let (dir, id) = try publishStaging(); defer { cleanup(id) }
        let gated = try StagedSnapshotGate().gate(stagingDir: dir)
        // The bound root fd must still be valid long after gate() returned — read through it.
        let names = try gated.root.entryNames()
        XCTAssertTrue(names.contains("manifest.json") && names.contains("sololedger.db"))
    }
}
