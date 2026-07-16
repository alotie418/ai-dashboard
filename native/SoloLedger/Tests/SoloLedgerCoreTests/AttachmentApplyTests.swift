import XCTest
@testable import SoloLedgerCore

/// Fail-closed, two-phase (apply → complete) attachment migration: validate staging (ImportID
/// / names / per-file + manifest SHA-256), copy only absent files non-destructively, gate
/// completion on an unresolved-items acknowledgement bound to the report hash, and only then
/// atomically persist the sentinel and clean staging. All fixtures are synthetic temp files.
final class AttachmentApplyTests: LedgerTestCase {

    private let fm = FileManager.default
    private struct TestError: Error {}

    // MARK: - Fixtures / helpers

    private func encode(_ m: ImportManifest) throws -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return try e.encode(m)
    }
    private func writeManifest(_ m: ImportManifest, to url: URL) throws { try encode(m).write(to: url) }
    private func readManifest(_ url: URL) throws -> ImportManifest {
        try JSONDecoder().decode(ImportManifest.self, from: Data(contentsOf: url))
    }
    private func manifestURL(_ stagingDir: URL) -> URL { stagingDir.appendingPathComponent("manifest.json") }
    private func stagedDoc(_ stagingDir: URL, _ name: String) -> URL {
        stagingDir.appendingPathComponent("attachments", isDirectory: true).appendingPathComponent("docs", isDirectory: true).appendingPathComponent(name)
    }

    /// Build a VALID staged import (correct per-file + attachmentManifest SHA-256).
    private func makeStaging(ingested: [(name: String, bytes: String)],
                             skipped: [(name: String, outcome: ImportManifest.FileResult.Outcome)] = [],
                             snapshot: String = "snap", id: ImportID? = nil) throws -> (dir: URL, id: ImportID) {
        let importID = id ?? ImportID("apply-\(UUID().uuidString)")!
        let dir = try trackedTempDir().appendingPathComponent("import-\(importID.rawValue)", isDirectory: true)
        let docs = dir.appendingPathComponent("attachments", isDirectory: true).appendingPathComponent("docs", isDirectory: true)
        try fm.createDirectory(at: docs, withIntermediateDirectories: true)
        var files: [ImportManifest.FileResult] = []
        for f in ingested {
            let url = docs.appendingPathComponent(f.name)
            try Data(f.bytes.utf8).write(to: url)
            files.append(.init(name: f.name, outcome: .ingested, sha256: try FileHash.sha256Hex(of: url), size: Int64(f.bytes.utf8.count)))
        }
        for s in skipped { files.append(.init(name: s.name, outcome: s.outcome, sha256: nil, size: nil)) }
        let manifest = ImportManifest(importID: importID.rawValue, sourceKind: "test", createdAt: "t",
                                      sourceDBSHA256: "db", walSHA256: nil, snapshotIdentitySHA256: snapshot,
                                      attachmentManifestSHA256: ImportManifest.attachmentSetHash(files),
                                      files: files, status: .ingested, report: nil)
        try writeManifest(manifest, to: manifestURL(dir))
        return (dir, importID)
    }

    private func makeActive(_ files: [(name: String, bytes: String)] = []) throws -> URL {
        let dir = try trackedTempDir().appendingPathComponent("active-docs", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in files { try Data(f.bytes.utf8).write(to: dir.appendingPathComponent(f.name)) }
        return dir
    }
    private func makeManifestsDir() throws -> URL {
        let dir = try trackedTempDir().appendingPathComponent("ImportManifests", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private func sentinelURL(_ manifests: URL, _ id: ImportID) -> URL { manifests.appendingPathComponent("\(id.rawValue).json") }
    private func names(_ dir: URL, matching f: (String) -> Bool) -> [String] {
        ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).map { $0.lastPathComponent }.filter(f)
    }
    private func partFiles(_ dir: URL) -> [String] { names(dir) { $0.contains(".part-") } }
    private func tempManifests(_ dir: URL) -> [String] { names(dir) { $0.hasPrefix(".tmp-") } }

    // MARK: - 1. Happy path (apply → complete, no unresolved)

    func testApplyThenCompleteCopiesAbsentSkipsIdenticalPersistsAndCleans() throws {
        let (staging, _) = try makeStaging(ingested: [("doc-a.pdf", "A"), ("doc-b.jpg", "B")])
        let active = try makeActive([("doc-b.jpg", "B")])
        let manifests = try makeManifestsDir()

        let report = try AttachmentApply().apply(stagingDir: staging, activeAttachmentsDir: active)
        XCTAssertEqual(report.applied.copied, ["doc-a.pdf"])
        XCTAssertEqual(report.applied.skippedIdentical, ["doc-b.jpg"])
        XCTAssertTrue(report.fileUnresolved.isEmpty)
        XCTAssertEqual(try String(contentsOf: active.appendingPathComponent("doc-a.pdf")), "A")
        XCTAssertTrue(fm.fileExists(atPath: staging.path), "apply must NOT clean staging")

        let outcome = try AttachmentApply().complete(report: report, referenceAudit: .audited(), acknowledgement: nil,
                                                     manifestsDir: manifests, hooks: ApplyHooks())
        guard case .completed(let r) = outcome else { return XCTFail("expected .completed, got \(outcome)") }
        let sentinel = try readManifest(r.completionSentinelURL)
        XCTAssertEqual(sentinel.status, .complete)
        XCTAssertEqual(sentinel.applied?.copied, ["doc-a.pdf"])
        XCTAssertNil(sentinel.acknowledgedReportHash)
        XCTAssertEqual(sentinel.referenceAuditPerformed, true, "sentinel must record that the DB reference audit ran")
        XCTAssertTrue(r.stagingCleaned)
        XCTAssertFalse(fm.fileExists(atPath: staging.path))
    }

    // MARK: - 1b/1c. Reference-audit + skip-set integrity fail-closed

    func testCompleteRefusesWhenReferenceAuditNotPerformed() throws {
        let (staging, id) = try makeStaging(ingested: [("doc-a.pdf", "A")])
        let active = try makeActive(); let manifests = try makeManifestsDir()
        let report = try AttachmentApply().apply(stagingDir: staging, activeAttachmentsDir: active)
        XCTAssertThrowsError(try AttachmentApply().complete(report: report, referenceAudit: .notPerformed,
                                                            acknowledgement: nil, manifestsDir: manifests, hooks: ApplyHooks())) { e in
            guard case AttachmentApplyError.referenceAuditNotPerformed = e else { return XCTFail("got \(e)") }
        }
        XCTAssertFalse(fm.fileExists(atPath: sentinelURL(manifests, id).path), "never complete without an audit")
        XCTAssertTrue(fm.fileExists(atPath: staging.path))
    }

    func testTamperedSkippedEntryFailsClosed() throws {
        // A skipped entry is inside the integrity envelope: dropping it trips a hash mismatch,
        // so it can't be silently removed to shrink the unresolved report.
        let (staging, _) = try makeStaging(ingested: [("doc-a.pdf", "A")], skipped: [("link.pdf", .skippedSymlink)])
        var m = try readManifest(manifestURL(staging))
        m.files.removeAll { $0.outcome == .skippedSymlink }   // drop the skip; leave attachmentManifestSHA256 as-is
        try writeManifest(m, to: manifestURL(staging))
        XCTAssertThrowsError(try AttachmentApply().apply(stagingDir: staging, activeAttachmentsDir: try makeActive())) { e in
            guard case AttachmentApplyError.attachmentManifestHashMismatch = e else { return XCTFail("got \(e)") }
        }
    }

    func testDuplicateNameAcrossIngestedAndSkippedFailsClosed() throws {
        let id = ImportID("apply-dupmix-\(UUID().uuidString)")!
        let dir = try trackedTempDir().appendingPathComponent("import-\(id.rawValue)", isDirectory: true)
        let docs = dir.appendingPathComponent("attachments", isDirectory: true).appendingPathComponent("docs", isDirectory: true)
        try fm.createDirectory(at: docs, withIntermediateDirectories: true)
        try Data("A".utf8).write(to: docs.appendingPathComponent("doc-a.pdf"))
        let sha = try FileHash.sha256Hex(of: docs.appendingPathComponent("doc-a.pdf"))
        let files = [ImportManifest.FileResult(name: "doc-a.pdf", outcome: .ingested, sha256: sha, size: 1),
                     ImportManifest.FileResult(name: "doc-a.pdf", outcome: .skippedSymlink, sha256: nil, size: nil)]
        let m = ImportManifest(importID: id.rawValue, sourceKind: "test", createdAt: "t", sourceDBSHA256: "db",
                               walSHA256: nil, snapshotIdentitySHA256: "snap",
                               attachmentManifestSHA256: ImportManifest.attachmentSetHash(files),
                               files: files, status: .ingested, report: nil)
        try writeManifest(m, to: manifestURL(dir))
        XCTAssertThrowsError(try AttachmentApply().apply(stagingDir: dir, activeAttachmentsDir: try makeActive())) { e in
            guard case AttachmentApplyError.duplicateAttachmentName = e else { return XCTFail("got \(e)") }
        }
    }

    // MARK: - 2. Missing staged file → requiresAcknowledgement, no sentinel, staging kept

    func testMissingStagedFileRequiresAcknowledgement() throws {
        let (staging, id) = try makeStaging(ingested: [("doc-a.pdf", "A"), ("doc-b.jpg", "B")])
        try fm.removeItem(at: stagedDoc(staging, "doc-b.jpg"))   // actually delete a staged file
        let active = try makeActive()
        let manifests = try makeManifestsDir()

        let report = try AttachmentApply().apply(stagingDir: staging, activeAttachmentsDir: active)
        XCTAssertEqual(report.applied.copied, ["doc-a.pdf"])
        XCTAssertEqual(report.fileUnresolved.items.map { $0.kind }, [.missingStagedFile])
        XCTAssertEqual(report.fileUnresolved.items.map { $0.name }, ["doc-b.jpg"])

        let o1 = try AttachmentApply().complete(report: report, referenceAudit: .audited(), acknowledgement: nil,
                                                manifestsDir: manifests, hooks: ApplyHooks())
        guard case .requiresAcknowledgement(let hash, let unresolved) = o1 else { return XCTFail("expected requiresAck, got \(o1)") }
        XCTAssertEqual(unresolved.items.map { $0.name }, ["doc-b.jpg"])
        XCTAssertFalse(fm.fileExists(atPath: sentinelURL(manifests, id).path), "no sentinel while unresolved")
        XCTAssertTrue(fm.fileExists(atPath: staging.path), "staging kept while unresolved")

        let o2 = try AttachmentApply().complete(report: report, referenceAudit: .audited(),
                                                acknowledgement: Acknowledgement(reportHash: hash),
                                                manifestsDir: manifests, hooks: ApplyHooks())
        guard case .completed(let r) = o2 else { return XCTFail() }
        let sentinel = try readManifest(r.completionSentinelURL)
        XCTAssertEqual(sentinel.acknowledgedReportHash, hash)
        XCTAssertEqual(sentinel.unresolved?.items.map { $0.name }, ["doc-b.jpg"])
        XCTAssertTrue(r.stagingCleaned)
    }

    // MARK: - 3. Skipped / illegal items enter the unresolved report and block completion

    func testSkippedAndIllegalItemsBlockCompletionUntilAcknowledged() throws {
        let (staging, _) = try makeStaging(ingested: [("doc-a.pdf", "A")],
                                           skipped: [("link.pdf", .skippedSymlink), ("bad name.pdf", .rejectedName)])
        let active = try makeActive()
        let manifests = try makeManifestsDir()

        let report = try AttachmentApply().apply(stagingDir: staging, activeAttachmentsDir: active)
        XCTAssertEqual(Set(report.fileUnresolved.items.map { $0.kind }), [.skippedSymlink, .rejectedName])

        let o1 = try AttachmentApply().complete(report: report, referenceAudit: .audited(), acknowledgement: nil,
                                                manifestsDir: manifests, hooks: ApplyHooks())
        guard case .requiresAcknowledgement(let hash, _) = o1 else { return XCTFail() }
        let o2 = try AttachmentApply().complete(report: report, referenceAudit: .audited(),
                                                acknowledgement: Acknowledgement(reportHash: hash),
                                                manifestsDir: manifests, hooks: ApplyHooks())
        guard case .completed(let r) = o2 else { return XCTFail() }
        XCTAssertEqual(r.unresolved.items.count, 2)
    }

    // MARK: - 4. Acknowledgement is bound to the current report hash

    func testAcknowledgementBoundToReportHashAndInvalidatedWhenReportChanges() throws {
        let (staging, _) = try makeStaging(ingested: [("doc-a.pdf", "A")])   // no file-level unresolved
        let active = try makeActive()
        let manifests = try makeManifestsDir()
        let app = AttachmentApply()
        let report = try app.apply(stagingDir: staging, activeAttachmentsDir: active)

        // DB audit adds a dangling ref → unresolved; no ack → requiresAck(hash1).
        let o1 = try app.complete(report: report, referenceAudit: ReferenceAudit.audited(danglingReferences: ["ref1"]),
                                  acknowledgement: nil, manifestsDir: manifests, hooks: ApplyHooks())
        guard case .requiresAcknowledgement(let hash1, let u1) = o1 else { return XCTFail() }
        XCTAssertEqual(u1.items.map { $0.kind }, [.danglingReference])

        // A stale ack (bound to the empty report) must NOT complete.
        let stale = Acknowledgement(reportHash: UnresolvedReport(items: []).reportHash)
        let o2 = try app.complete(report: report, referenceAudit: ReferenceAudit.audited(danglingReferences: ["ref1"]),
                                  acknowledgement: stale, manifestsDir: manifests, hooks: ApplyHooks())
        guard case .requiresAcknowledgement = o2 else { return XCTFail("stale ack must be rejected") }

        // Report CHANGES (audit finds ref2) → an ack bound to hash1 is now stale.
        let o3 = try app.complete(report: report, referenceAudit: ReferenceAudit.audited(danglingReferences: ["ref1", "ref2"]),
                                  acknowledgement: Acknowledgement(reportHash: hash1), manifestsDir: manifests, hooks: ApplyHooks())
        guard case .requiresAcknowledgement(let hash3, _) = o3 else { return XCTFail("ack for a changed report must be rejected") }
        XCTAssertNotEqual(hash3, hash1)

        // The correct ack for the current report completes.
        let o4 = try app.complete(report: report, referenceAudit: ReferenceAudit.audited(danglingReferences: ["ref1", "ref2"]),
                                  acknowledgement: Acknowledgement(reportHash: hash3), manifestsDir: manifests, hooks: ApplyHooks())
        guard case .completed = o4 else { return XCTFail() }
    }

    // MARK: - 5..9. Fail-closed manifest / staging validation

    func testTamperedImportIDFailsClosed() throws {
        let (staging, _) = try makeStaging(ingested: [("doc-a.pdf", "A")])
        var m = try readManifest(manifestURL(staging)); m.importID = "../evil"; try writeManifest(m, to: manifestURL(staging))
        XCTAssertThrowsError(try AttachmentApply().apply(stagingDir: staging, activeAttachmentsDir: try makeActive())) { e in
            guard case AttachmentApplyError.invalidImportID = e else { return XCTFail("got \(e)") }
        }
    }

    func testTamperedFilenameFailsClosed() throws {
        let (staging, _) = try makeStaging(ingested: [("doc-a.pdf", "A")])
        var m = try readManifest(manifestURL(staging)); m.files[0].name = "doc-z.pdf"   // hash NOT updated
        try writeManifest(m, to: manifestURL(staging))
        XCTAssertThrowsError(try AttachmentApply().apply(stagingDir: staging, activeAttachmentsDir: try makeActive())) { e in
            guard case AttachmentApplyError.attachmentManifestHashMismatch = e else { return XCTFail("got \(e)") }
        }
    }

    func testTamperedStagingBytesFailsClosed() throws {
        let (staging, _) = try makeStaging(ingested: [("doc-a.pdf", "A")])
        try Data("TAMPERED".utf8).write(to: stagedDoc(staging, "doc-a.pdf"))   // change bytes, not the manifest
        XCTAssertThrowsError(try AttachmentApply().apply(stagingDir: staging, activeAttachmentsDir: try makeActive())) { e in
            guard case AttachmentApplyError.stagedFileHashMismatch = e else { return XCTFail("got \(e)") }
        }
    }

    func testDuplicateFilenameFailsClosed() throws {
        let id = ImportID("apply-dup-\(UUID().uuidString)")!
        let dir = try trackedTempDir().appendingPathComponent("import-\(id.rawValue)", isDirectory: true)
        let docs = dir.appendingPathComponent("attachments", isDirectory: true).appendingPathComponent("docs", isDirectory: true)
        try fm.createDirectory(at: docs, withIntermediateDirectories: true)
        try Data("A".utf8).write(to: docs.appendingPathComponent("doc-a.pdf"))
        let sha = try FileHash.sha256Hex(of: docs.appendingPathComponent("doc-a.pdf"))
        let dup = [ImportManifest.FileResult(name: "doc-a.pdf", outcome: .ingested, sha256: sha, size: 1),
                   ImportManifest.FileResult(name: "doc-a.pdf", outcome: .ingested, sha256: sha, size: 1)]
        let m = ImportManifest(importID: id.rawValue, sourceKind: "test", createdAt: "t", sourceDBSHA256: "db",
                               walSHA256: nil, snapshotIdentitySHA256: "snap",
                               attachmentManifestSHA256: ImportManifest.attachmentSetHash(dup),
                               files: dup, status: .ingested, report: nil)
        try writeManifest(m, to: manifestURL(dir))
        XCTAssertThrowsError(try AttachmentApply().apply(stagingDir: dir, activeAttachmentsDir: try makeActive())) { e in
            guard case AttachmentApplyError.duplicateAttachmentName = e else { return XCTFail("got \(e)") }
        }
    }

    func testWrongAttachmentManifestHashFailsClosed() throws {
        let (staging, _) = try makeStaging(ingested: [("doc-a.pdf", "A")])
        var m = try readManifest(manifestURL(staging)); m.attachmentManifestSHA256 = "deadbeef"
        try writeManifest(m, to: manifestURL(staging))
        XCTAssertThrowsError(try AttachmentApply().apply(stagingDir: staging, activeAttachmentsDir: try makeActive())) { e in
            guard case AttachmentApplyError.attachmentManifestHashMismatch = e else { return XCTFail("got \(e)") }
        }
    }

    // MARK: - 10. Existing sentinel with a different identity is not overwritten

    func testExistingSentinelDifferentSnapshotRejected() throws {
        let (staging, id) = try makeStaging(ingested: [("doc-a.pdf", "A")], snapshot: "snapNEW")
        let active = try makeActive()
        let manifests = try makeManifestsDir()
        var other = try readManifest(manifestURL(staging))
        other.snapshotIdentitySHA256 = "snapOLD"; other.status = .complete
        try writeManifest(other, to: sentinelURL(manifests, id))

        let report = try AttachmentApply().apply(stagingDir: staging, activeAttachmentsDir: active)
        XCTAssertThrowsError(try AttachmentApply().complete(report: report, referenceAudit: .audited(), acknowledgement: nil,
                                                            manifestsDir: manifests, hooks: ApplyHooks())) { e in
            guard case AttachmentApplyError.sentinelIdentityMismatch = e else { return XCTFail("got \(e)") }
        }
        XCTAssertEqual(try readManifest(sentinelURL(manifests, id)).snapshotIdentitySHA256, "snapOLD", "old sentinel unchanged")
        XCTAssertTrue(fm.fileExists(atPath: staging.path))
    }

    // MARK: - 11..12. Target race during apply

    func testTargetRaceSameContentRecordedAsSkippedIdentical() throws {
        let (staging, _) = try makeStaging(ingested: [("doc-a.pdf", "A")])
        let active = try makeActive()
        let report = try AttachmentApply().apply(stagingDir: staging, activeAttachmentsDir: active,
                                                 hooks: ApplyHooks(onAttachmentCopy: { name in
            try Data("A".utf8).write(to: active.appendingPathComponent(name))   // race: same content appears
        }))
        XCTAssertEqual(report.applied.copied, [])
        XCTAssertEqual(report.applied.skippedIdentical, ["doc-a.pdf"], "actual outcome, not the plan's guess")
        XCTAssertTrue(partFiles(active).isEmpty, "no .part-* leftover")
    }

    func testTargetRaceDifferentContentConflictsNeverOverwritesNoPart() throws {
        let (staging, _) = try makeStaging(ingested: [("doc-a.pdf", "A")])
        let active = try makeActive()
        XCTAssertThrowsError(try AttachmentApply().apply(stagingDir: staging, activeAttachmentsDir: active,
                                                         hooks: ApplyHooks(onAttachmentCopy: { name in
            try Data("DIFFERENT".utf8).write(to: active.appendingPathComponent(name))
        }))) { e in
            guard case AttachmentApplyError.conflictDuringApply = e else { return XCTFail("got \(e)") }
        }
        XCTAssertEqual(try String(contentsOf: active.appendingPathComponent("doc-a.pdf")), "DIFFERENT", "never overwritten")
        XCTAssertTrue(partFiles(active).isEmpty, "this round's part cleaned")
    }

    // MARK: - 13. Attachment copy fault

    func testAttachmentCopyFaultKeepsStagingNoCompletionNoPart() throws {
        let (staging, _) = try makeStaging(ingested: [("doc-a.pdf", "A")])
        let active = try makeActive()
        XCTAssertThrowsError(try AttachmentApply().apply(stagingDir: staging, activeAttachmentsDir: active,
                                                         hooks: ApplyHooks(onAttachmentCopy: { _ in throw TestError() })))
        XCTAssertFalse(fm.fileExists(atPath: active.appendingPathComponent("doc-a.pdf").path))
        XCTAssertTrue(partFiles(active).isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: staging.path))
    }

    // MARK: - 14. Plan-time conflict blocks before swap

    func testPlanTimeConflictBlocksBeforeSwapNeverOverwrites() throws {
        let (staging, _) = try makeStaging(ingested: [("a.pdf", "A")])
        let active = try makeActive([("a.pdf", "DIFFERENT")])
        XCTAssertThrowsError(try AttachmentApply().apply(stagingDir: staging, activeAttachmentsDir: active)) { e in
            guard case AttachmentApplyError.conflicts(let c) = e else { return XCTFail("got \(e)") }
            XCTAssertEqual(c.map { $0.name }, ["a.pdf"])
        }
        XCTAssertEqual(try String(contentsOf: active.appendingPathComponent("a.pdf")), "DIFFERENT")
        XCTAssertTrue(try AttachmentApply().plan(stagingDir: staging, activeAttachmentsDir: active).hasConflicts)
    }

    // MARK: - 15..17. Completion / cleanup fault injection

    func testCompletionTempWriteFailureKeepsStagingNoSentinel() throws {
        let (staging, id) = try makeStaging(ingested: [("a.pdf", "A")])
        let active = try makeActive(); let manifests = try makeManifestsDir()
        let report = try AttachmentApply().apply(stagingDir: staging, activeAttachmentsDir: active)
        XCTAssertThrowsError(try AttachmentApply().complete(report: report, referenceAudit: .audited(), acknowledgement: nil,
                                                            manifestsDir: manifests,
                                                            hooks: ApplyHooks(onCompletionTempWrite: { throw TestError() })))
        XCTAssertFalse(fm.fileExists(atPath: sentinelURL(manifests, id).path))
        XCTAssertTrue(tempManifests(manifests).isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: staging.path))
    }

    func testCompletionPublishFailureKeepsStagingNoSentinelNoTemp() throws {
        let (staging, id) = try makeStaging(ingested: [("a.pdf", "A")])
        let active = try makeActive(); let manifests = try makeManifestsDir()
        let report = try AttachmentApply().apply(stagingDir: staging, activeAttachmentsDir: active)
        XCTAssertThrowsError(try AttachmentApply().complete(report: report, referenceAudit: .audited(), acknowledgement: nil,
                                                            manifestsDir: manifests,
                                                            hooks: ApplyHooks(onCompletionPublish: { throw TestError() })))
        XCTAssertFalse(fm.fileExists(atPath: sentinelURL(manifests, id).path))
        XCTAssertTrue(tempManifests(manifests).isEmpty, "unpublished temp cleaned on publish failure")
        XCTAssertTrue(fm.fileExists(atPath: staging.path))
    }

    func testStagingCleanupFailureSurfacedButCompletionRecorded() throws {
        let (staging, _) = try makeStaging(ingested: [("a.pdf", "A")])
        let active = try makeActive(); let manifests = try makeManifestsDir()
        let report = try AttachmentApply().apply(stagingDir: staging, activeAttachmentsDir: active)
        let outcome = try AttachmentApply().complete(report: report, referenceAudit: .audited(), acknowledgement: nil,
                                                     manifestsDir: manifests, hooks: ApplyHooks(cleanup: { _ in throw TestError() }))
        guard case .completed(let r) = outcome else { return XCTFail() }
        XCTAssertTrue(fm.fileExists(atPath: r.completionSentinelURL.path), "completion recorded despite cleanup failure")
        XCTAssertFalse(r.stagingCleaned)
        XCTAssertNotNil(r.stagingCleanupError)
        XCTAssertTrue(fm.fileExists(atPath: staging.path), "residue kept for a later reaper")
    }

    // MARK: - 18. Idempotent re-complete over a surviving staging

    func testIdempotentReCompleteReplacesSameIdentityAndCleans() throws {
        let (staging, id) = try makeStaging(ingested: [("a.pdf", "A")])
        let active = try makeActive(); let manifests = try makeManifestsDir()
        let report = try AttachmentApply().apply(stagingDir: staging, activeAttachmentsDir: active)

        // First complete fails to clean staging → sentinel written, staging survives.
        let o1 = try AttachmentApply().complete(report: report, referenceAudit: .audited(), acknowledgement: nil,
                                                manifestsDir: manifests, hooks: ApplyHooks(cleanup: { _ in throw TestError() }))
        guard case .completed(let r1) = o1, !r1.stagingCleaned else { return XCTFail() }
        XCTAssertTrue(fm.fileExists(atPath: staging.path))

        // Re-complete over the surviving staging: same identity ⇒ replace sentinel, clean staging.
        let o2 = try AttachmentApply().complete(report: report, referenceAudit: .audited(), acknowledgement: nil,
                                                manifestsDir: manifests, hooks: ApplyHooks())
        guard case .completed(let r2) = o2 else { return XCTFail() }
        XCTAssertTrue(r2.stagingCleaned)
        XCTAssertFalse(fm.fileExists(atPath: staging.path))
        XCTAssertTrue(fm.fileExists(atPath: sentinelURL(manifests, id).path))
    }
}
