import XCTest
@testable import SoloLedgerCore

/// Identity-bound, fail-closed, two-phase attachment migration. apply() copies absent files
/// non-destructively; complete() finalizes only with un-forgeable, import-bound reference-audit
/// evidence + (if unresolved) an acknowledgement bound to the full operation identity. All
/// fixtures are synthetic temp files.
final class AttachmentApplyTests: LedgerTestCase {

    private let fm = FileManager.default
    /// A real, quiescent prepared-DB file: complete() recomputes its identity from disk,
    /// so a fabricated identity string can no longer stand in for it.
    private var preparedDBURL: URL!
    private var preparedDB = ""   // the computed identity every report/audit binds to
    private struct TestError: Error {}

    override func setUpWithError() throws {
        try super.setUpWithError()
        preparedDBURL = try trackedTempDir().appendingPathComponent("prepared.db")
        do {
            let db = try SQLiteDatabase(path: preparedDBURL.path)
            try db.execute("PRAGMA journal_mode = DELETE")
            try db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY)")
        }
        preparedDB = try PreparedDatabaseIdentity.compute(at: preparedDBURL)
    }

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

    private func makeManifest(importID: String, files: [ImportManifest.FileResult], snapshot: String) -> ImportManifest {
        ImportManifest(formatVersion: ImportManifest.currentFormatVersion, importID: importID, sourceKind: "test",
                       createdAt: "t", sourceDBSHA256: "db", walSHA256: nil, snapshotIdentitySHA256: snapshot,
                       attachmentManifestSHA256: ImportManifest.attachmentSetHash(files), files: files,
                       status: .ingested, report: nil)
    }

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
        try writeManifest(makeManifest(importID: importID.rawValue, files: files, snapshot: snapshot), to: manifestURL(dir))
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

    /// Un-forgeable audit evidence bound to `report`, produced here (tests are `@testable`).
    private func matchingAudit(_ r: AttachmentApplyReport,
                               dangling: [ReferenceAudit.DanglingReference] = [],
                               invalid: [ReferenceAudit.InvalidReference] = [],
                               resolved: [ReferenceAudit.ResolvedReference] = []) -> ReferenceAudit {
        ReferenceAudit(importID: r.importID.rawValue, snapshotIdentitySHA256: r.manifest.snapshotIdentitySHA256,
                       attachmentManifestSHA256: r.manifest.attachmentManifestSHA256,
                       preparedDBIdentity: r.preparedDBIdentity,
                       resolved: resolved, dangling: dangling, invalid: invalid)
    }
    private func matchingAudit(_ r: AttachmentApplyReport, dangling: [String]) -> ReferenceAudit {
        matchingAudit(r, dangling: dangling.map { .init(name: $0, provenance: "transactions.attachment_path×1") })
    }
    private func apply(_ staging: URL, _ active: URL, hooks: ApplyHooks = ApplyHooks()) throws -> AttachmentApplyReport {
        try AttachmentApply().apply(stagingDir: staging, activeAttachmentsDir: active, preparedDBIdentity: preparedDB, hooks: hooks)
    }
    /// A second real prepared DB with a DIFFERENT identity (cross-database tests).
    private func makeAltPreparedDB() throws -> (url: URL, identity: String) {
        let url = try trackedTempDir().appendingPathComponent("prepared-alt.db")
        do {
            let db = try SQLiteDatabase(path: url.path)
            try db.execute("PRAGMA journal_mode = DELETE")
            try db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY)")
            try db.run("INSERT INTO t (id) VALUES (1)")
        }
        return (url, try PreparedDatabaseIdentity.compute(at: url))
    }

    // MARK: - 1. Happy path

    func testApplyThenCompleteHappyPath() throws {
        let (staging, _) = try makeStaging(ingested: [("doc-a.pdf", "A"), ("doc-b.jpg", "B")])
        let active = try makeActive([("doc-b.jpg", "B")]); let manifests = try makeManifestsDir()
        let report = try apply(staging, active)
        XCTAssertEqual(report.applied.copied, ["doc-a.pdf"])
        XCTAssertEqual(report.applied.skippedIdentical, ["doc-b.jpg"])
        XCTAssertTrue(report.fileUnresolved.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: staging.path), "apply must NOT clean staging")

        let outcome = try AttachmentApply().complete(report: report, referenceAudit: matchingAudit(report),
                                                     acknowledgement: nil, preparedDatabaseAt: preparedDBURL, manifestsDir: manifests, hooks: ApplyHooks())
        guard case .completed(let r) = outcome else { return XCTFail("expected .completed, got \(outcome)") }
        let s = try readManifest(r.completionSentinelURL)
        XCTAssertEqual(s.status, .complete)
        XCTAssertEqual(s.formatVersion, ImportManifest.currentFormatVersion)
        XCTAssertEqual(s.referenceAuditPerformed, true)
        XCTAssertEqual(s.preparedDBIdentity, preparedDB, "sentinel must record the prepared DB it was audited against")
        XCTAssertNil(s.acknowledgedReportHash)
        XCTAssertTrue(r.stagingCleaned)
        XCTAssertFalse(fm.fileExists(atPath: staging.path))
    }

    // MARK: - 1b. Report is produced only by apply() (App cannot fabricate it)

    /// AttachmentApplyReport's initializer is INTERNAL — the App module (a non-@testable
    /// consumer of SoloLedgerCore) cannot construct one; it must obtain it from apply(). This
    /// test documents the sanctioned producer and that the identity it stamps is carried through.
    func testReportProducedOnlyByApplyCarriesPreparedDBIdentity() throws {
        let (staging, id) = try makeStaging(ingested: [("doc-a.pdf", "A")])
        let report = try apply(staging, try makeActive())
        XCTAssertEqual(report.preparedDBIdentity, preparedDB)
        XCTAssertEqual(report.importID.rawValue, id.rawValue)
    }

    // MARK: - 2/3. Unresolved gates

    func testMissingStagedFileRequiresAcknowledgement() throws {
        let (staging, id) = try makeStaging(ingested: [("doc-a.pdf", "A"), ("doc-b.jpg", "B")])
        try fm.removeItem(at: stagedDoc(staging, "doc-b.jpg"))
        let active = try makeActive(); let manifests = try makeManifestsDir()
        let report = try apply(staging, active)
        XCTAssertEqual(report.fileUnresolved.items.map { $0.name }, ["doc-b.jpg"])

        let o1 = try AttachmentApply().complete(report: report, referenceAudit: matchingAudit(report),
                                                acknowledgement: nil, preparedDatabaseAt: preparedDBURL, manifestsDir: manifests, hooks: ApplyHooks())
        guard case .requiresAcknowledgement(let request, let unresolved) = o1 else { return XCTFail("got \(o1)") }
        XCTAssertEqual(unresolved.items.map { $0.name }, ["doc-b.jpg"])
        XCTAssertFalse(fm.fileExists(atPath: sentinelURL(manifests, id).path))
        XCTAssertTrue(fm.fileExists(atPath: staging.path))

        let o2 = try AttachmentApply().complete(report: report, referenceAudit: matchingAudit(report),
                                                acknowledgement: request.acknowledge(), preparedDatabaseAt: preparedDBURL, manifestsDir: manifests, hooks: ApplyHooks())
        guard case .completed(let r) = o2 else { return XCTFail() }
        XCTAssertEqual(try readManifest(r.completionSentinelURL).acknowledgedReportHash, request.unresolvedReportHash)
        XCTAssertTrue(r.stagingCleaned)
    }

    func testSkippedAndIllegalItemsBlockCompletionUntilAcknowledged() throws {
        let (staging, _) = try makeStaging(ingested: [("doc-a.pdf", "A")],
                                           skipped: [("link.pdf", .skippedSymlink), ("bad name.pdf", .rejectedName)])
        let active = try makeActive(); let manifests = try makeManifestsDir()
        let report = try apply(staging, active)
        XCTAssertEqual(Set(report.fileUnresolved.items.map { $0.kind }), [.skippedSymlink, .rejectedName])
        let o1 = try AttachmentApply().complete(report: report, referenceAudit: matchingAudit(report),
                                                acknowledgement: nil, preparedDatabaseAt: preparedDBURL, manifestsDir: manifests, hooks: ApplyHooks())
        guard case .requiresAcknowledgement(let request, _) = o1 else { return XCTFail() }
        let o2 = try AttachmentApply().complete(report: report, referenceAudit: matchingAudit(report),
                                                acknowledgement: request.acknowledge(), preparedDatabaseAt: preparedDBURL, manifestsDir: manifests, hooks: ApplyHooks())
        guard case .completed(let r) = o2 else { return XCTFail() }
        XCTAssertEqual(r.unresolved.items.count, 2)
    }

    // MARK: - 4. Ack invalidated when the report changes (dangling refs added)

    func testAcknowledgementInvalidatedWhenReportChanges() throws {
        let (staging, _) = try makeStaging(ingested: [("doc-a.pdf", "A")])
        let active = try makeActive(); let manifests = try makeManifestsDir()
        let report = try apply(staging, active)

        let o1 = try AttachmentApply().complete(report: report, referenceAudit: matchingAudit(report, dangling: ["ref1"]),
                                                acknowledgement: nil, preparedDatabaseAt: preparedDBURL, manifestsDir: manifests, hooks: ApplyHooks())
        guard case .requiresAcknowledgement(let req1, _) = o1 else { return XCTFail() }

        // Report changes (audit finds ref2) → an ack for req1 is stale.
        let o2 = try AttachmentApply().complete(report: report, referenceAudit: matchingAudit(report, dangling: ["ref1", "ref2"]),
                                                acknowledgement: req1.acknowledge(), preparedDatabaseAt: preparedDBURL, manifestsDir: manifests, hooks: ApplyHooks())
        guard case .requiresAcknowledgement(let req2, _) = o2 else { return XCTFail("stale ack must be rejected") }
        XCTAssertNotEqual(req2.unresolvedReportHash, req1.unresolvedReportHash)

        let o3 = try AttachmentApply().complete(report: report, referenceAudit: matchingAudit(report, dangling: ["ref1", "ref2"]),
                                                acknowledgement: req2.acknowledge(), preparedDatabaseAt: preparedDBURL, manifestsDir: manifests, hooks: ApplyHooks())
        guard case .completed = o3 else { return XCTFail() }
    }

    // MARK: - 5..11. Fail-closed validation

    func testTamperedImportIDFailsClosed() throws {
        let (staging, _) = try makeStaging(ingested: [("doc-a.pdf", "A")])
        var m = try readManifest(manifestURL(staging)); m.importID = "../evil"; try writeManifest(m, to: manifestURL(staging))
        XCTAssertThrowsError(try apply(staging, try makeActive())) { e in
            guard case AttachmentApplyError.invalidImportID = e else { return XCTFail("got \(e)") }
        }
    }
    func testTamperedFilenameFailsClosed() throws {
        let (staging, _) = try makeStaging(ingested: [("doc-a.pdf", "A")])
        var m = try readManifest(manifestURL(staging)); m.files[0].name = "doc-z.pdf"; try writeManifest(m, to: manifestURL(staging))
        XCTAssertThrowsError(try apply(staging, try makeActive())) { e in
            guard case AttachmentApplyError.attachmentManifestHashMismatch = e else { return XCTFail("got \(e)") }
        }
    }
    func testTamperedStagingBytesFailsClosed() throws {
        let (staging, _) = try makeStaging(ingested: [("doc-a.pdf", "A")])
        try Data("TAMPERED".utf8).write(to: stagedDoc(staging, "doc-a.pdf"))
        XCTAssertThrowsError(try apply(staging, try makeActive())) { e in
            guard case AttachmentApplyError.stagedFileHashMismatch = e else { return XCTFail("got \(e)") }
        }
    }
    func testWrongAttachmentManifestHashFailsClosed() throws {
        let (staging, _) = try makeStaging(ingested: [("doc-a.pdf", "A")])
        var m = try readManifest(manifestURL(staging)); m.attachmentManifestSHA256 = "deadbeef"; try writeManifest(m, to: manifestURL(staging))
        XCTAssertThrowsError(try apply(staging, try makeActive())) { e in
            guard case AttachmentApplyError.attachmentManifestHashMismatch = e else { return XCTFail("got \(e)") }
        }
    }
    func testTamperedSkippedEntryFailsClosed() throws {
        let (staging, _) = try makeStaging(ingested: [("doc-a.pdf", "A")], skipped: [("link.pdf", .skippedSymlink)])
        var m = try readManifest(manifestURL(staging)); m.files.removeAll { $0.outcome == .skippedSymlink }
        try writeManifest(m, to: manifestURL(staging))
        XCTAssertThrowsError(try apply(staging, try makeActive())) { e in
            guard case AttachmentApplyError.attachmentManifestHashMismatch = e else { return XCTFail("got \(e)") }
        }
    }
    func testDuplicateNameFailsClosed() throws {
        let id = ImportID("apply-dup-\(UUID().uuidString)")!
        let dir = try trackedTempDir().appendingPathComponent("import-\(id.rawValue)", isDirectory: true)
        let docs = dir.appendingPathComponent("attachments", isDirectory: true).appendingPathComponent("docs", isDirectory: true)
        try fm.createDirectory(at: docs, withIntermediateDirectories: true)
        try Data("A".utf8).write(to: docs.appendingPathComponent("doc-a.pdf"))
        let sha = try FileHash.sha256Hex(of: docs.appendingPathComponent("doc-a.pdf"))
        let files = [ImportManifest.FileResult(name: "doc-a.pdf", outcome: .ingested, sha256: sha, size: 1),
                     ImportManifest.FileResult(name: "doc-a.pdf", outcome: .skippedSymlink, sha256: nil, size: nil)]
        try writeManifest(makeManifest(importID: id.rawValue, files: files, snapshot: "snap"), to: manifestURL(dir))
        XCTAssertThrowsError(try apply(dir, try makeActive())) { e in
            guard case AttachmentApplyError.duplicateAttachmentName = e else { return XCTFail("got \(e)") }
        }
    }
    func testUnknownManifestFormatVersionRejected() throws {
        let (staging, _) = try makeStaging(ingested: [("doc-a.pdf", "A")])
        // 1 is the RETIRED pre-invalidReference format: rejected fail-closed, never upgraded.
        for bad: Int? in [nil, 0, 1, 999] {
            var m = try readManifest(manifestURL(staging)); m.formatVersion = bad; try writeManifest(m, to: manifestURL(staging))
            XCTAssertThrowsError(try apply(staging, try makeActive())) { e in
                guard case AttachmentApplyError.unsupportedManifestFormat = e else { return XCTFail("formatVersion \(String(describing: bad)) → \(e)") }
            }
        }
    }

    // MARK: - 12. Existing sentinel identity

    func testExistingSentinelDifferentSnapshotRejected() throws {
        let (staging, id) = try makeStaging(ingested: [("doc-a.pdf", "A")], snapshot: "snapNEW")
        let active = try makeActive(); let manifests = try makeManifestsDir()
        var other = try readManifest(manifestURL(staging)); other.snapshotIdentitySHA256 = "snapOLD"; other.status = .complete
        try writeManifest(other, to: sentinelURL(manifests, id))
        let report = try apply(staging, active)
        XCTAssertThrowsError(try AttachmentApply().complete(report: report, referenceAudit: matchingAudit(report),
                                                            acknowledgement: nil, preparedDatabaseAt: preparedDBURL, manifestsDir: manifests, hooks: ApplyHooks())) { e in
            guard case AttachmentApplyError.sentinelIdentityMismatch = e else { return XCTFail("got \(e)") }
        }
        XCTAssertEqual(try readManifest(sentinelURL(manifests, id)).snapshotIdentitySHA256, "snapOLD")
        XCTAssertTrue(fm.fileExists(atPath: staging.path))
    }

    // MARK: - 13..14. Target race during apply (onAttachmentCopy)

    func testTargetRaceSameContentRecordedAsSkippedIdentical() throws {
        let (staging, _) = try makeStaging(ingested: [("doc-a.pdf", "A")]); let active = try makeActive()
        let report = try apply(staging, active, hooks: ApplyHooks(onAttachmentCopy: { name in
            try Data("A".utf8).write(to: active.appendingPathComponent(name))
        }))
        XCTAssertEqual(report.applied.copied, [])
        XCTAssertEqual(report.applied.skippedIdentical, ["doc-a.pdf"])
        XCTAssertTrue(partFiles(active).isEmpty)
    }
    func testTargetRaceDifferentContentConflictsNeverOverwrites() throws {
        let (staging, _) = try makeStaging(ingested: [("doc-a.pdf", "A")]); let active = try makeActive()
        XCTAssertThrowsError(try apply(staging, active, hooks: ApplyHooks(onAttachmentCopy: { name in
            try Data("DIFFERENT".utf8).write(to: active.appendingPathComponent(name))
        }))) { e in guard case AttachmentApplyError.conflictDuringApply = e else { return XCTFail("got \(e)") } }
        XCTAssertEqual(try String(contentsOf: active.appendingPathComponent("doc-a.pdf")), "DIFFERENT")
        XCTAssertTrue(partFiles(active).isEmpty)
    }

    // MARK: - 15..16. Final-publish race (onBeforePublish) — target appears just before rename

    func testFinalPublishRaceSameContentSkipped() throws {
        let (staging, _) = try makeStaging(ingested: [("doc-a.pdf", "A")]); let active = try makeActive()
        let report = try apply(staging, active, hooks: ApplyHooks(onBeforePublish: { name in
            try Data("A".utf8).write(to: active.appendingPathComponent(name))   // race at the last instant, same content
        }))
        XCTAssertEqual(report.applied.copied, [])
        XCTAssertEqual(report.applied.skippedIdentical, ["doc-a.pdf"])
        XCTAssertTrue(partFiles(active).isEmpty)
    }
    func testFinalPublishRaceDifferentContentConflictsNeverOverwrites() throws {
        let (staging, _) = try makeStaging(ingested: [("doc-a.pdf", "A")]); let active = try makeActive()
        XCTAssertThrowsError(try apply(staging, active, hooks: ApplyHooks(onBeforePublish: { name in
            try Data("DIFFERENT".utf8).write(to: active.appendingPathComponent(name))
        }))) { e in guard case AttachmentApplyError.conflictDuringApply = e else { return XCTFail("got \(e)") } }
        XCTAssertEqual(try String(contentsOf: active.appendingPathComponent("doc-a.pdf")), "DIFFERENT")
        XCTAssertTrue(partFiles(active).isEmpty)
    }

    // MARK: - 17. Attachment copy fault

    func testAttachmentCopyFaultKeepsStagingNoCompletionNoPart() throws {
        let (staging, _) = try makeStaging(ingested: [("doc-a.pdf", "A")]); let active = try makeActive()
        XCTAssertThrowsError(try apply(staging, active, hooks: ApplyHooks(onAttachmentCopy: { _ in throw TestError() })))
        XCTAssertFalse(fm.fileExists(atPath: active.appendingPathComponent("doc-a.pdf").path))
        XCTAssertTrue(partFiles(active).isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: staging.path))
    }

    // MARK: - 18. Plan-time conflict blocks

    func testPlanTimeConflictBlocksBeforeSwapNeverOverwrites() throws {
        let (staging, _) = try makeStaging(ingested: [("a.pdf", "A")]); let active = try makeActive([("a.pdf", "DIFFERENT")])
        XCTAssertThrowsError(try apply(staging, active)) { e in
            guard case AttachmentApplyError.conflicts = e else { return XCTFail("got \(e)") }
        }
        XCTAssertEqual(try String(contentsOf: active.appendingPathComponent("a.pdf")), "DIFFERENT")
        XCTAssertTrue(try AttachmentApply().plan(stagingDir: staging, activeAttachmentsDir: active).hasConflicts)
    }

    // MARK: - 19..21. Completion / cleanup fault injection

    func testCompletionTempWriteFailureKeepsStagingNoSentinel() throws {
        let (staging, id) = try makeStaging(ingested: [("a.pdf", "A")]); let active = try makeActive(); let manifests = try makeManifestsDir()
        let report = try apply(staging, active)
        XCTAssertThrowsError(try AttachmentApply().complete(report: report, referenceAudit: matchingAudit(report), acknowledgement: nil,
                                                            preparedDatabaseAt: preparedDBURL, manifestsDir: manifests, hooks: ApplyHooks(onCompletionTempWrite: { throw TestError() })))
        XCTAssertFalse(fm.fileExists(atPath: sentinelURL(manifests, id).path))
        XCTAssertTrue(tempManifests(manifests).isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: staging.path))
    }
    func testCompletionPublishFailureKeepsStagingNoSentinelNoTemp() throws {
        let (staging, id) = try makeStaging(ingested: [("a.pdf", "A")]); let active = try makeActive(); let manifests = try makeManifestsDir()
        let report = try apply(staging, active)
        XCTAssertThrowsError(try AttachmentApply().complete(report: report, referenceAudit: matchingAudit(report), acknowledgement: nil,
                                                            preparedDatabaseAt: preparedDBURL, manifestsDir: manifests, hooks: ApplyHooks(onCompletionPublish: { throw TestError() })))
        XCTAssertFalse(fm.fileExists(atPath: sentinelURL(manifests, id).path))
        XCTAssertTrue(tempManifests(manifests).isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: staging.path))
    }
    func testStagingCleanupFailureSurfacedButCompletionRecorded() throws {
        let (staging, _) = try makeStaging(ingested: [("a.pdf", "A")]); let active = try makeActive(); let manifests = try makeManifestsDir()
        let report = try apply(staging, active)
        let outcome = try AttachmentApply().complete(report: report, referenceAudit: matchingAudit(report), acknowledgement: nil,
                                                     preparedDatabaseAt: preparedDBURL, manifestsDir: manifests, hooks: ApplyHooks(cleanup: { _ in throw TestError() }))
        guard case .completed(let r) = outcome else { return XCTFail() }
        XCTAssertTrue(fm.fileExists(atPath: r.completionSentinelURL.path))
        XCTAssertFalse(r.stagingCleaned); XCTAssertNotNil(r.stagingCleanupError)
        XCTAssertTrue(fm.fileExists(atPath: staging.path))
    }

    // MARK: - 22. Idempotent re-complete

    func testIdempotentReCompleteReplacesSameIdentityAndCleans() throws {
        let (staging, id) = try makeStaging(ingested: [("a.pdf", "A")]); let active = try makeActive(); let manifests = try makeManifestsDir()
        let report = try apply(staging, active)
        let o1 = try AttachmentApply().complete(report: report, referenceAudit: matchingAudit(report), acknowledgement: nil,
                                                preparedDatabaseAt: preparedDBURL, manifestsDir: manifests, hooks: ApplyHooks(cleanup: { _ in throw TestError() }))
        guard case .completed(let r1) = o1, !r1.stagingCleaned else { return XCTFail() }
        let o2 = try AttachmentApply().complete(report: report, referenceAudit: matchingAudit(report), acknowledgement: nil,
                                                preparedDatabaseAt: preparedDBURL, manifestsDir: manifests, hooks: ApplyHooks())
        guard case .completed(let r2) = o2 else { return XCTFail() }
        XCTAssertTrue(r2.stagingCleaned)
        XCTAssertFalse(fm.fileExists(atPath: staging.path))
        XCTAssertTrue(fm.fileExists(atPath: sentinelURL(manifests, id).path))
    }

    // MARK: - 23..26. Identity binding of audit + acknowledgement

    func testReferenceAuditFromAnotherImportRejected() throws {
        let (stagingA, _) = try makeStaging(ingested: [("a.pdf", "A")])
        let (stagingB, _) = try makeStaging(ingested: [("a.pdf", "A")])
        let manifests = try makeManifestsDir()
        let reportA = try apply(stagingA, try makeActive())
        let reportB = try apply(stagingB, try makeActive())
        // A's audit against B → importID mismatch.
        XCTAssertThrowsError(try AttachmentApply().complete(report: reportB, referenceAudit: matchingAudit(reportA),
                                                            acknowledgement: nil, preparedDatabaseAt: preparedDBURL, manifestsDir: manifests, hooks: ApplyHooks())) { e in
            guard case AttachmentApplyError.referenceAuditMismatch(let f) = e else { return XCTFail("got \(e)") }
            XCTAssertEqual(f, "importID")
        }
    }

    func testReferenceAuditFieldMismatchesRejected() throws {
        let (staging, _) = try makeStaging(ingested: [("a.pdf", "A")])
        let manifests = try makeManifestsDir()
        let report = try apply(staging, try makeActive())
        func audit(snapshot: String, attach: String, prepared: String) -> ReferenceAudit {
            ReferenceAudit(importID: report.importID.rawValue, snapshotIdentitySHA256: snapshot,
                           attachmentManifestSHA256: attach, preparedDBIdentity: prepared)
        }
        let good = matchingAudit(report)
        for (a, field) in [(audit(snapshot: "X", attach: good.attachmentManifestSHA256, prepared: preparedDB), "snapshotIdentity"),
                           (audit(snapshot: good.snapshotIdentitySHA256, attach: "X", prepared: preparedDB), "attachmentManifest"),
                           (audit(snapshot: good.snapshotIdentitySHA256, attach: good.attachmentManifestSHA256, prepared: "X"), "preparedDBIdentity")] {
            XCTAssertThrowsError(try AttachmentApply().complete(report: report, referenceAudit: a, acknowledgement: nil,
                                                                preparedDatabaseAt: preparedDBURL, manifestsDir: manifests, hooks: ApplyHooks())) { e in
                guard case AttachmentApplyError.referenceAuditMismatch(let got) = e else { return XCTFail("got \(e)") }
                XCTAssertEqual(got, field)
            }
        }
    }

    func testAcknowledgementFromAnotherImportRejectedEvenWithSameUnresolved() throws {
        // Two imports with an IDENTICAL unresolved list (both missing doc-b, same bytes) but
        // different importID → an ack from A cannot confirm B.
        func mk() throws -> (URL, AttachmentApplyReport) {
            let (staging, _) = try makeStaging(ingested: [("doc-a.pdf", "A"), ("doc-b.jpg", "B")])
            try fm.removeItem(at: stagedDoc(staging, "doc-b.jpg"))
            return (staging, try apply(staging, try makeActive()))
        }
        let manifests = try makeManifestsDir()
        let (_, reportA) = try mk()
        let (_, reportB) = try mk()
        let oA = try AttachmentApply().complete(report: reportA, referenceAudit: matchingAudit(reportA), acknowledgement: nil,
                                                preparedDatabaseAt: preparedDBURL, manifestsDir: manifests, hooks: ApplyHooks())
        guard case .requiresAcknowledgement(let reqA, let uA) = oA else { return XCTFail() }
        let oB = try AttachmentApply().complete(report: reportB, referenceAudit: matchingAudit(reportB), acknowledgement: nil,
                                                preparedDatabaseAt: preparedDBURL, manifestsDir: manifests, hooks: ApplyHooks())
        guard case .requiresAcknowledgement(let reqB, let uB) = oB else { return XCTFail() }
        XCTAssertEqual(uA.reportHash, uB.reportHash, "identical unresolved lists share a report hash")
        XCTAssertNotEqual(reqA.importID, reqB.importID)

        // A's acknowledgement must NOT complete B.
        let rejected = try AttachmentApply().complete(report: reportB, referenceAudit: matchingAudit(reportB),
                                                      acknowledgement: reqA.acknowledge(), preparedDatabaseAt: preparedDBURL, manifestsDir: manifests, hooks: ApplyHooks())
        guard case .requiresAcknowledgement = rejected else { return XCTFail("A's ack must not confirm B") }
    }

    func testUnresolvedDetailChangeInvalidatesOldAcknowledgement() throws {
        // Two reports identical except one unresolved item's `detail`.
        let (staging, id) = try makeStaging(ingested: [("a.pdf", "A")])
        let active = try makeActive(); let manifests = try makeManifestsDir()
        let base = try apply(staging, active)   // gives us a real manifest/preparedDB/importID
        func report(detail: String) -> AttachmentApplyReport {
            AttachmentApplyReport(importID: id, stagingDir: staging, activeAttachmentsDir: active, manifest: base.manifest,
                                  preparedDBIdentity: preparedDB, applied: .init(copied: [], skippedIdentical: [], missing: []),
                                  fileUnresolved: UnresolvedReport(items: [.init(name: "x", kind: .danglingReference, detail: detail)]))
        }
        let rx = report(detail: "v1"), ry = report(detail: "v2")
        let ox = try AttachmentApply().complete(report: rx, referenceAudit: matchingAudit(rx), acknowledgement: nil,
                                                preparedDatabaseAt: preparedDBURL, manifestsDir: manifests, hooks: ApplyHooks())
        guard case .requiresAcknowledgement(let reqX, _) = ox else { return XCTFail() }
        // The ack for detail v1 must NOT confirm the v2 report.
        let oy = try AttachmentApply().complete(report: ry, referenceAudit: matchingAudit(ry), acknowledgement: reqX.acknowledge(),
                                                preparedDatabaseAt: preparedDBURL, manifestsDir: manifests, hooks: ApplyHooks())
        guard case .requiresAcknowledgement(let reqY, _) = oy else { return XCTFail("detail change must invalidate the old ack") }
        XCTAssertNotEqual(reqX.unresolvedReportHash, reqY.unresolvedReportHash)
    }

    func testAcknowledgementFromPreparedDBAcannotConfirmB() throws {
        // Same staging (same import/snapshot/attachment identity) applied against TWO different
        // prepared DBs → an ack bound to prepared-DB A cannot confirm the prepared-DB-B report.
        let (staging, _) = try makeStaging(ingested: [("doc-a.pdf", "A"), ("doc-b.jpg", "B")])
        try fm.removeItem(at: stagedDoc(staging, "doc-b.jpg"))   // unresolved (missing) → ack required
        let manifests = try makeManifestsDir()
        let alt = try makeAltPreparedDB()
        let reportA = try AttachmentApply().apply(stagingDir: staging, activeAttachmentsDir: try makeActive(),
                                                  preparedDBIdentity: preparedDB, hooks: ApplyHooks())
        let reportB = try AttachmentApply().apply(stagingDir: staging, activeAttachmentsDir: try makeActive(),
                                                  preparedDBIdentity: alt.identity, hooks: ApplyHooks())
        XCTAssertEqual(reportA.manifest.snapshotIdentitySHA256, reportB.manifest.snapshotIdentitySHA256)
        XCTAssertNotEqual(reportA.preparedDBIdentity, reportB.preparedDBIdentity)

        let oA = try AttachmentApply().complete(report: reportA, referenceAudit: matchingAudit(reportA), acknowledgement: nil,
                                                preparedDatabaseAt: preparedDBURL, manifestsDir: manifests, hooks: ApplyHooks())
        guard case .requiresAcknowledgement(let reqA, _) = oA else { return XCTFail() }
        // A's acknowledgement must NOT confirm B (different prepared DB).
        let rejected = try AttachmentApply().complete(report: reportB, referenceAudit: matchingAudit(reportB),
                                                      acknowledgement: reqA.acknowledge(), preparedDatabaseAt: alt.url, manifestsDir: manifests, hooks: ApplyHooks())
        guard case .requiresAcknowledgement = rejected else { return XCTFail("ack for prepared-DB A must not confirm B") }
    }

    func testSentinelRecordsAndVerifiesPreparedDB() throws {
        // Two independent stagings with the SAME import id + content (⇒ same snapshot + attachment
        // identity) but applied against DIFFERENT prepared DBs. The first completes; the second
        // must not overwrite that sentinel.
        let id = ImportID("apply-\(UUID().uuidString)")!
        let (stagingA, _) = try makeStaging(ingested: [("doc-a.pdf", "A")], id: id)
        let (stagingB, _) = try makeStaging(ingested: [("doc-a.pdf", "A")], id: id)
        let manifests = try makeManifestsDir()

        let alt = try makeAltPreparedDB()
        let rA = try AttachmentApply().apply(stagingDir: stagingA, activeAttachmentsDir: try makeActive(),
                                             preparedDBIdentity: preparedDB, hooks: ApplyHooks())
        let oA = try AttachmentApply().complete(report: rA, referenceAudit: matchingAudit(rA), acknowledgement: nil,
                                                preparedDatabaseAt: preparedDBURL, manifestsDir: manifests, hooks: ApplyHooks())
        guard case .completed(let cA) = oA else { return XCTFail() }
        XCTAssertEqual(try readManifest(cA.completionSentinelURL).preparedDBIdentity, preparedDB)

        let rB = try AttachmentApply().apply(stagingDir: stagingB, activeAttachmentsDir: try makeActive(),
                                             preparedDBIdentity: alt.identity, hooks: ApplyHooks())
        XCTAssertEqual(rA.manifest.snapshotIdentitySHA256, rB.manifest.snapshotIdentitySHA256)
        XCTAssertThrowsError(try AttachmentApply().complete(report: rB, referenceAudit: matchingAudit(rB), acknowledgement: nil,
                                                            preparedDatabaseAt: alt.url, manifestsDir: manifests, hooks: ApplyHooks())) { e in
            guard case AttachmentApplyError.sentinelIdentityMismatch = e else { return XCTFail("got \(e)") }
        }
        XCTAssertEqual(try readManifest(sentinelURL(manifests, id)).preparedDBIdentity, preparedDB, "existing sentinel not overwritten")
    }

    func testReportHashNilVsEmptyDetailDiffer() {
        let nilDetail = UnresolvedReport(items: [.init(name: "n", kind: .danglingReference, detail: nil)])
        let emptyDetail = UnresolvedReport(items: [.init(name: "n", kind: .danglingReference, detail: "")])
        XCTAssertNotEqual(nilDetail.reportHash, emptyDetail.reportHash, "absent detail must hash differently from empty-string detail")
    }

    func testConcurrentDifferentIdentitySentinelNotOverwritten() throws {
        let (staging, id) = try makeStaging(ingested: [("doc-a.pdf", "A")], snapshot: "snapNEW")
        let active = try makeActive(); let manifests = try makeManifestsDir()
        let report = try apply(staging, active)
        // A different-identity sentinel appears in the TOCTOU window (after the initial absent
        // check, before the exclusive rename). It must NOT be overwritten.
        var intruder = try readManifest(manifestURL(staging))
        intruder.snapshotIdentitySHA256 = "snapINTRUDER"; intruder.status = .complete; intruder.preparedDBIdentity = "other"
        XCTAssertThrowsError(try AttachmentApply().complete(report: report, referenceAudit: matchingAudit(report), acknowledgement: nil,
                                                            preparedDatabaseAt: preparedDBURL, manifestsDir: manifests,
                                                            hooks: ApplyHooks(onCompletionPublish: {
            try self.writeManifest(intruder, to: self.sentinelURL(manifests, id))   // race: sentinel appears now
        }))) { e in
            guard case AttachmentApplyError.sentinelIdentityMismatch = e else { return XCTFail("got \(e)") }
        }
        XCTAssertEqual(try readManifest(sentinelURL(manifests, id)).snapshotIdentitySHA256, "snapINTRUDER", "intruder sentinel not overwritten")
        XCTAssertTrue(tempManifests(manifests).isEmpty, "our temp is cleaned")
        XCTAssertTrue(fm.fileExists(atPath: staging.path), "staging kept")
    }

    func testExistingNonIdenticalSentinelRejectedEvenWithSameIdentityHashes() throws {
        // A sentinel that shares the three identity HASHES but differs in any other field —
        // status, importID, formatVersion, referenceAuditPerformed, applied, unresolved, report —
        // must NOT be reused; re-completion is rejected and staging is kept.
        let mutations: [(String, (inout ImportManifest) -> Void)] = [
            ("status .ingested", { $0.status = .ingested }),
            ("wrong importID", { $0.importID = "apply-other-\(UUID().uuidString)" }),
            ("old formatVersion", { $0.formatVersion = 0 }),
            ("unknown formatVersion", { $0.formatVersion = 999 }),
            ("not audited", { $0.referenceAuditPerformed = nil }),
            ("audited false", { $0.referenceAuditPerformed = false }),
            ("different applied", { $0.applied = .init(copied: ["ghost.pdf"], skippedIdentical: [], missing: []) }),
            ("different unresolved", { $0.unresolved = UnresolvedReport(items: [.init(name: "z", kind: .danglingReference)]) }),
            ("different ack hash", { $0.acknowledgedReportHash = "tampered" }),
            ("different report string", { $0.report = "tampered" }),
        ]
        for (label, mutate) in mutations {
            let (staging, id) = try makeStaging(ingested: [("a.pdf", "A")])
            let active = try makeActive(); let manifests = try makeManifestsDir()
            let report = try apply(staging, active)   // empty unresolved → completes without ack
            // First complete keeps staging (cleanup throws) and writes the CORRECT sentinel.
            let o1 = try AttachmentApply().complete(report: report, referenceAudit: matchingAudit(report), acknowledgement: nil,
                                                    preparedDatabaseAt: preparedDBURL, manifestsDir: manifests, hooks: ApplyHooks(cleanup: { _ in throw TestError() }))
            guard case .completed = o1 else { return XCTFail("\(label): first complete should succeed") }
            // Tamper the persisted sentinel so it is no longer identical to a fresh completion.
            var s = try readManifest(sentinelURL(manifests, id)); mutate(&s); try writeManifest(s, to: sentinelURL(manifests, id))
            // Re-complete on the surviving staging → rejected, never overwritten, staging kept.
            XCTAssertThrowsError(try AttachmentApply().complete(report: report, referenceAudit: matchingAudit(report), acknowledgement: nil,
                                                                preparedDatabaseAt: preparedDBURL, manifestsDir: manifests, hooks: ApplyHooks())) { e in
                guard case AttachmentApplyError.sentinelIdentityMismatch = e else { return XCTFail("\(label): got \(e)") }
            }
            XCTAssertTrue(fm.fileExists(atPath: staging.path), "\(label): staging must be kept on rejection")
        }
    }

    func testIdenticalCompletedSentinelIsIdempotentlyReused() throws {
        let (staging, id) = try makeStaging(ingested: [("a.pdf", "A")])
        let active = try makeActive(); let manifests = try makeManifestsDir()
        let report = try apply(staging, active)
        // First complete keeps staging (cleanup throws), writing the sentinel.
        let o1 = try AttachmentApply().complete(report: report, referenceAudit: matchingAudit(report), acknowledgement: nil,
                                                preparedDatabaseAt: preparedDBURL, manifestsDir: manifests, hooks: ApplyHooks(cleanup: { _ in throw TestError() }))
        guard case .completed(let r1) = o1, !r1.stagingCleaned else { return XCTFail() }
        let before = try Data(contentsOf: sentinelURL(manifests, id))
        // Re-complete with the IDENTICAL report → the byte-identical sentinel is reused (not
        // rewritten) and staging is cleaned.
        let o2 = try AttachmentApply().complete(report: report, referenceAudit: matchingAudit(report), acknowledgement: nil,
                                                preparedDatabaseAt: preparedDBURL, manifestsDir: manifests, hooks: ApplyHooks())
        guard case .completed(let r2) = o2 else { return XCTFail() }
        XCTAssertTrue(r2.stagingCleaned)
        XCTAssertFalse(fm.fileExists(atPath: staging.path))
        XCTAssertEqual(try Data(contentsOf: sentinelURL(manifests, id)), before, "identical sentinel reused, not rewritten")
    }

    // MARK: - 26b. Non-regular filesystem entries fail closed across the whole flow (C4)

    /// A same-name symlink (even to IDENTICAL content — the sharpest case: it used to
    /// classify as skippedIdentical), directory or FIFO in the ACTIVE dir must be an
    /// explicit pre-swap error: never followed, never opened blocking.
    func testPlanAndApplyFailClosedOnNonRegularActiveEntry() throws {
        for kind in ["symlink", "directory", "fifo"] {
            let (staging, _) = try makeStaging(ingested: [("a.pdf", "A")])
            let active = try makeActive()
            let target = active.appendingPathComponent("a.pdf")
            switch kind {
            case "symlink":
                let elsewhere = try trackedTempDir().appendingPathComponent("a.pdf")
                try Data("A".utf8).write(to: elsewhere)   // identical content
                try fm.createSymbolicLink(at: target, withDestinationURL: elsewhere)
            case "directory":
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            default:
                guard mkfifo(target.path, 0o644) == 0 else { throw XCTSkip("mkfifo unavailable") }
            }
            XCTAssertThrowsError(try AttachmentApply().plan(stagingDir: staging, activeAttachmentsDir: active), kind) { e in
                guard case AttachmentApplyError.activeEntryNotRegularFile("a.pdf") = e else { return XCTFail("\(kind): got \(e)") }
            }
            XCTAssertThrowsError(try apply(staging, active), kind) { e in
                guard case AttachmentApplyError.activeEntryNotRegularFile("a.pdf") = e else { return XCTFail("\(kind): got \(e)") }
            }
            XCTAssertTrue(fm.fileExists(atPath: staging.path), "\(kind): staging kept")
        }
    }

    /// A staged entry that is not a regular file where the manifest promises an ingested
    /// file is tampering — fail closed even when the symlink target has matching content.
    func testStagedNonRegularEntryFailsClosed() throws {
        for kind in ["symlink", "directory", "fifo"] {
            let (staging, _) = try makeStaging(ingested: [("a.pdf", "A")])
            let staged = stagedDoc(staging, "a.pdf")
            try fm.removeItem(at: staged)
            switch kind {
            case "symlink":
                let elsewhere = try trackedTempDir().appendingPathComponent("a.pdf")
                try Data("A".utf8).write(to: elsewhere)   // content matches the manifest SHA
                try fm.createSymbolicLink(at: staged, withDestinationURL: elsewhere)
            case "directory":
                try fm.createDirectory(at: staged, withIntermediateDirectories: true)
            default:
                guard mkfifo(staged.path, 0o644) == 0 else { throw XCTSkip("mkfifo unavailable") }
            }
            XCTAssertThrowsError(try apply(staging, try makeActive()), kind) { e in
                guard case AttachmentApplyError.stagedEntryNotRegularFile("a.pdf") = e else { return XCTFail("\(kind): got \(e)") }
            }
        }
    }

    /// A symlink appearing at the destination in the publish TOCTOU window is re-classified
    /// by the no-follow primitive: explicit error, part cleaned, nothing followed.
    func testPublishRaceSymlinkTargetFailsClosed() throws {
        let (staging, _) = try makeStaging(ingested: [("a.pdf", "A")])
        let active = try makeActive()
        let elsewhere = try trackedTempDir().appendingPathComponent("a.pdf")
        try Data("A".utf8).write(to: elsewhere)
        let hooks = ApplyHooks(onBeforePublish: { name in
            try self.fm.createSymbolicLink(at: active.appendingPathComponent(name), withDestinationURL: elsewhere)
        })
        XCTAssertThrowsError(try apply(staging, active, hooks: hooks)) { e in
            guard case AttachmentApplyError.activeEntryNotRegularFile("a.pdf") = e else { return XCTFail("got \(e)") }
        }
        XCTAssertEqual(partFiles(active), [], "no .part leftovers")
        XCTAssertTrue(fm.fileExists(atPath: staging.path), "staging kept")
    }

    /// After apply, an applied file swapped for a same-content symlink must fail the
    /// complete-stage re-verification (the primitive never follows it).
    func testCompleteAppliedFileSwappedForSymlinkFailsClosed() throws {
        let (staging, id) = try makeStaging(ingested: [("a.pdf", "A")])
        let active = try makeActive(); let manifests = try makeManifestsDir()
        let report = try apply(staging, active)
        XCTAssertEqual(report.applied.copied, ["a.pdf"])

        let target = active.appendingPathComponent("a.pdf")
        let elsewhere = try trackedTempDir().appendingPathComponent("a.pdf")
        try Data("A".utf8).write(to: elsewhere)   // identical content
        try fm.removeItem(at: target)
        try fm.createSymbolicLink(at: target, withDestinationURL: elsewhere)

        XCTAssertThrowsError(try AttachmentApply().complete(report: report, referenceAudit: matchingAudit(report),
                                                            acknowledgement: nil, preparedDatabaseAt: preparedDBURL,
                                                            manifestsDir: manifests, hooks: ApplyHooks())) { e in
            guard case AttachmentApplyError.activeFileHashMismatch("a.pdf") = e else { return XCTFail("got \(e)") }
        }
        XCTAssertFalse(fm.fileExists(atPath: sentinelURL(manifests, id).path), "no sentinel")
        XCTAssertTrue(fm.fileExists(atPath: staging.path), "staging kept")
    }

    // MARK: - 27. The auditor only yields evidence for the bound prepared DB (fail-closed)

    /// The real auditor (AttachmentReferenceAuditorTests covers its scan) still cannot be
    /// used to fabricate completion: a target that is not the quiescent prepared database
    /// the report was applied against is rejected before any evidence is produced.
    func testReferenceAuditorRejectsNonDatabaseTarget() throws {
        let (staging, _) = try makeStaging(ingested: [("a.pdf", "A")])
        let report = try apply(staging, try makeActive())
        XCTAssertThrowsError(try AttachmentReferenceAuditor().audit(report: report,
                                                                    preparedDatabaseAt: try makeActive())) { e in
            guard let pe = e as? PreparedDatabaseError, case .databaseNotRegularFile = pe else { return XCTFail("got \(e)") }
        }
    }

    // MARK: - 28. reportHash canonical encoding includes detail

    func testReportHashCanonicalIncludesDetail() {
        let a = UnresolvedReport(items: [.init(name: "n", kind: .danglingReference, detail: "d1")])
        let b = UnresolvedReport(items: [.init(name: "n", kind: .danglingReference, detail: "d2")])
        let c = UnresolvedReport(items: [.init(name: "n", kind: .danglingReference, detail: "d1")])
        XCTAssertNotEqual(a.reportHash, b.reportHash, "detail change must change the hash")
        XCTAssertEqual(a.reportHash, c.reportHash, "same content → same hash")
        // Order independence.
        let m1 = UnresolvedReport(items: [.init(name: "b", kind: .rejectedName), .init(name: "a", kind: .missingStagedFile)])
        let m2 = UnresolvedReport(items: [.init(name: "a", kind: .missingStagedFile), .init(name: "b", kind: .rejectedName)])
        XCTAssertEqual(m1.reportHash, m2.reportHash)
    }

    /// A rejectedName carries the raw source filename, which the filesystem allows to contain
    /// the separator control chars — the encoding must remain INJECTIVE so a crafted name cannot
    /// collide two distinct reports and let a stale acknowledgement through.
    func testReportHashInjectiveAgainstSeparatorInjection() {
        // These two reports collide under a naive U+001F/U+001E-joined encoding.
        let crafted = "x\u{1f}\u{1e}rejectedName\u{1f}y"
        let r1 = UnresolvedReport(items: [.init(name: crafted, kind: .rejectedName)])
        let r2 = UnresolvedReport(items: [.init(name: "x", kind: .rejectedName), .init(name: "y", kind: .rejectedName)])
        XCTAssertNotEqual(r1.reportHash, r2.reportHash, "distinct reports must not hash-collide via separator injection")
    }

    // MARK: - C11a. Descriptor-rooted, barriered sentinel publication (2B-3 C11a)

    private func completeSimple(_ report: AttachmentApplyReport, manifests: URL,
                                prePublishGate: (() throws -> Void)? = nil,
                                hooks: ApplyHooks = ApplyHooks()) throws -> CompleteOutcome {
        try AttachmentApply().complete(report: report, referenceAudit: matchingAudit(report), acknowledgement: nil,
                                       preparedDatabaseAt: preparedDBURL, manifestsDir: manifests,
                                       prePublishGate: prePublishGate, hooks: hooks)
    }

    /// Fresh publication runs BOTH barriers in order; an idempotent re-complete ADOPTS the
    /// existing sentinel and REPLAYS both barriers (repair-on-retry), never rewriting it.
    func testSentinelSyncSequenceFreshAndAdoptReplay() throws {
        let (staging, id) = try makeStaging(ingested: [("a.pdf", "A")])
        let active = try makeActive(); let manifests = try makeManifestsDir()
        let report = try apply(staging, active)
        var fresh: [SentinelSyncPoint] = []
        guard case .completed = try completeSimple(report, manifests: manifests,
                                                   hooks: ApplyHooks(onSentinelSync: { fresh.append($0) })) else { return XCTFail() }
        XCTAssertEqual(fresh, [.sentinelFile, .sentinelDirEntry])
        let before = try Data(contentsOf: sentinelURL(manifests, id))

        var adopt: [SentinelSyncPoint] = []
        let o2 = try completeSimple(report, manifests: manifests,
                                    hooks: ApplyHooks(onSentinelSync: { adopt.append($0) }))
        guard case .completed(let r2) = o2 else { return XCTFail() }
        XCTAssertEqual(adopt, [.sentinelFile, .sentinelDirEntry], "adopt replays both barriers")
        XCTAssertTrue(r2.stagingCleaned, "staging already gone → idempotent clean")
        XCTAssertEqual(try Data(contentsOf: sentinelURL(manifests, id)), before, "adopted sentinel never rewritten")
    }

    func testSentinelFileBarrierFailureNoFinalSentinel() throws {
        let (staging, id) = try makeStaging(ingested: [("a.pdf", "A")])
        let active = try makeActive(); let manifests = try makeManifestsDir()
        let report = try apply(staging, active)
        XCTAssertThrowsError(try completeSimple(report, manifests: manifests,
                                                hooks: ApplyHooks(onSentinelSync: { p in if p == .sentinelFile { throw TestError() } }))) { e in
            guard case AttachmentApplyError.sentinelDurabilityFailed(.sentinelFile, _) = e else { return XCTFail("got \(e)") }
        }
        XCTAssertFalse(fm.fileExists(atPath: sentinelURL(manifests, id).path), "no half-published sentinel")
        XCTAssertTrue(tempManifests(manifests).isEmpty, "own still-bound temp cleaned")
        XCTAssertTrue(fm.fileExists(atPath: staging.path), "staging kept")
    }

    /// THE ordering guarantee this step exists for: a directory-barrier failure happens with
    /// the sentinel already published (process-crash safe) but completion NOT returned — and
    /// staging MUST still exist, because cleanup runs strictly after both barriers. The retry
    /// adopts the sentinel, replays the barriers, and only then cleans staging.
    func testSentinelDirBarrierFailureKeepsStagingThenRepairedOnRetry() throws {
        let (staging, id) = try makeStaging(ingested: [("a.pdf", "A")])
        let active = try makeActive(); let manifests = try makeManifestsDir()
        let report = try apply(staging, active)
        XCTAssertThrowsError(try completeSimple(report, manifests: manifests,
                                                hooks: ApplyHooks(onSentinelSync: { p in if p == .sentinelDirEntry { throw TestError() } }))) { e in
            guard case AttachmentApplyError.sentinelDurabilityFailed(.sentinelDirEntry, _) = e else { return XCTFail("got \(e)") }
        }
        XCTAssertTrue(fm.fileExists(atPath: sentinelURL(manifests, id).path), "sentinel IS published (crash safe)")
        XCTAssertTrue(fm.fileExists(atPath: staging.path), "staging MUST survive a barrier failure — cleanup is after the barriers")
        let bytes = try Data(contentsOf: sentinelURL(manifests, id))

        var seq: [SentinelSyncPoint] = []
        let o2 = try completeSimple(report, manifests: manifests, hooks: ApplyHooks(onSentinelSync: { seq.append($0) }))
        guard case .completed(let r2) = o2 else { return XCTFail() }
        XCTAssertEqual(seq, [.sentinelFile, .sentinelDirEntry], "retry replays the full barrier set")
        XCTAssertTrue(r2.stagingCleaned)
        XCTAssertFalse(fm.fileExists(atPath: staging.path))
        XCTAssertEqual(try Data(contentsOf: sentinelURL(manifests, id)), bytes, "sentinel bytes unchanged")
    }

    /// The onSentinelSync seam may tamper via the path (same inode) — the post-sync P5 gate
    /// must stop the tampered temp BEFORE its rename; the final sentinel must never appear.
    func testSentinelTempTamperAfterFileBarrierBlockedBeforeRename() throws {
        let (staging, id) = try makeStaging(ingested: [("a.pdf", "A")])
        let active = try makeActive(); let manifests = try makeManifestsDir()
        let report = try apply(staging, active)
        XCTAssertThrowsError(try completeSimple(report, manifests: manifests,
                                                hooks: ApplyHooks(onSentinelSync: { p in
            guard p == .sentinelFile else { return }
            let temp = try XCTUnwrap(self.tempManifests(manifests).first)
            try Data("{\"tampered\":true}".utf8).write(to: manifests.appendingPathComponent(temp))   // same inode rewrite
        }))) { e in
            guard case AttachmentApplyError.sentinelPublishIncomplete = e else { return XCTFail("got \(e)") }
        }
        XCTAssertFalse(fm.fileExists(atPath: sentinelURL(manifests, id).path), "tampered temp must not be published")
        XCTAssertTrue(tempManifests(manifests).isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: staging.path))
    }

    /// P5′ (name): the prePublishGate runs arbitrary code immediately before the rename —
    /// swapping the temp NAME to a different inode there must fail closed BEFORE P6, with
    /// the replacement untouched and no final sentinel.
    func testSentinelTempNameSwappedAfterPrePublishGateBlockedBeforeRename() throws {
        let (staging, id) = try makeStaging(ingested: [("a.pdf", "A")])
        let active = try makeActive(); let manifests = try makeManifestsDir()
        let report = try apply(staging, active)
        var calls = 0
        var replaced: URL?
        XCTAssertThrowsError(try completeSimple(report, manifests: manifests, prePublishGate: {
            calls += 1
            guard calls == 2 else { return }   // GX′ — the invocation directly before P6
            let temp = try XCTUnwrap(self.tempManifests(manifests).first)
            let url = manifests.appendingPathComponent(temp)
            try self.fm.moveItem(at: url, to: manifests.appendingPathComponent("aside.json"))
            try Data("IMPOSTOR".utf8).write(to: url)   // different inode at the temp name
            replaced = url
        })) { e in
            guard case AttachmentApplyError.sentinelPublishIncomplete = e else { return XCTFail("got \(e)") }
        }
        XCTAssertEqual(calls, 2, "gate must run before the manifests dir is touched AND directly before publish")
        XCTAssertFalse(fm.fileExists(atPath: sentinelURL(manifests, id).path), "no final sentinel")
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(replaced)), Data("IMPOSTOR".utf8),
                       "replacement untouched — cleanup only unlinks the still-bound temp")
        XCTAssertTrue(fm.fileExists(atPath: staging.path))
    }

    /// P5′ (bytes): rewriting the temp's SAME inode inside the gate must be caught by the
    /// final bound decode BEFORE P6 — no final sentinel.
    func testSentinelTempContentRewrittenAfterPrePublishGateBlockedBeforeRename() throws {
        let (staging, id) = try makeStaging(ingested: [("a.pdf", "A")])
        let active = try makeActive(); let manifests = try makeManifestsDir()
        let report = try apply(staging, active)
        var calls = 0
        XCTAssertThrowsError(try completeSimple(report, manifests: manifests, prePublishGate: {
            calls += 1
            guard calls == 2 else { return }
            let temp = try XCTUnwrap(self.tempManifests(manifests).first)
            try Data("{\"late\":true}".utf8).write(to: manifests.appendingPathComponent(temp))   // same inode
        })) { e in
            guard case AttachmentApplyError.sentinelPublishIncomplete = e else { return XCTFail("got \(e)") }
        }
        XCTAssertEqual(calls, 2)
        XCTAssertFalse(fm.fileExists(atPath: sentinelURL(manifests, id).path))
        XCTAssertTrue(tempManifests(manifests).isEmpty, "still-bound tampered temp cleaned")
        XCTAssertTrue(fm.fileExists(atPath: staging.path))
    }

    /// A DIRECTORY planted at the final sentinel name is a conflict: never adopted, never
    /// recursed into, never overwritten (RENAME_EXCL cannot replace it either).
    func testDirectoryAtFinalSentinelNameFailsClosed() throws {
        let (staging, id) = try makeStaging(ingested: [("a.pdf", "A")])
        let active = try makeActive(); let manifests = try makeManifestsDir()
        let report = try apply(staging, active)
        let dirAtName = sentinelURL(manifests, id)
        try fm.createDirectory(at: dirAtName, withIntermediateDirectories: false)
        try Data("inner".utf8).write(to: dirAtName.appendingPathComponent("inner.txt"))
        XCTAssertThrowsError(try completeSimple(report, manifests: manifests)) { e in
            guard case AttachmentApplyError.sentinelIdentityMismatch = e else { return XCTFail("got \(e)") }
        }
        XCTAssertEqual(try Data(contentsOf: dirAtName.appendingPathComponent("inner.txt")), Data("inner".utf8),
                       "planted directory contents untouched")
        XCTAssertTrue(fm.fileExists(atPath: staging.path))
    }

    /// A SYMLINK planted at the final sentinel name is never followed — the no-follow bind
    /// fails closed and the link target is untouched.
    func testSymlinkAtFinalSentinelNameFailsClosed() throws {
        let (staging, id) = try makeStaging(ingested: [("a.pdf", "A")])
        let active = try makeActive(); let manifests = try makeManifestsDir()
        let report = try apply(staging, active)
        let target = try trackedTempDir().appendingPathComponent("target.json")
        try Data("keep".utf8).write(to: target)
        try fm.createSymbolicLink(at: sentinelURL(manifests, id), withDestinationURL: target)
        XCTAssertThrowsError(try completeSimple(report, manifests: manifests)) { e in
            guard case AttachmentApplyError.sentinelIdentityMismatch = e else { return XCTFail("got \(e)") }
        }
        XCTAssertEqual(try Data(contentsOf: target), Data("keep".utf8), "symlink target untouched (never followed)")
    }

    /// Unlinking the published sentinel in the post-publish window (afterSentinelPublished,
    /// before the dir barrier) is detected by P9 as retriable — and a re-run republishes.
    func testPublishedSentinelUnlinkedBeforeDirBarrierRetriableThenRepublished() throws {
        let (staging, id) = try makeStaging(ingested: [("a.pdf", "A")])
        let active = try makeActive(); let manifests = try makeManifestsDir()
        let report = try apply(staging, active)
        XCTAssertThrowsError(try completeSimple(report, manifests: manifests,
                                                hooks: ApplyHooks(afterSentinelPublished: { url in try self.fm.removeItem(at: url) }))) { e in
            guard case AttachmentApplyError.sentinelPublishIncomplete = e else { return XCTFail("got \(e)") }
        }
        XCTAssertTrue(fm.fileExists(atPath: staging.path), "staging kept — completion did not return")
        guard case .completed = try completeSimple(report, manifests: manifests) else { return XCTFail() }
        XCTAssertTrue(fm.fileExists(atPath: sentinelURL(manifests, id).path))
    }

    /// Replacing the published sentinel with a FOREIGN object in the post-publish window is
    /// a terminal conflict; the foreign object is never overwritten or deleted.
    func testPublishedSentinelSwappedToForeignConflicts() throws {
        let (staging, id) = try makeStaging(ingested: [("a.pdf", "A")])
        let active = try makeActive(); let manifests = try makeManifestsDir()
        let report = try apply(staging, active)
        let foreign = Data("{\"foreign\":true}".utf8)
        XCTAssertThrowsError(try completeSimple(report, manifests: manifests,
                                                hooks: ApplyHooks(afterSentinelPublished: { url in
            try self.fm.removeItem(at: url)
            try foreign.write(to: url)   // different inode, foreign content
        }))) { e in
            guard case AttachmentApplyError.sentinelIdentityMismatch = e else { return XCTFail("got \(e)") }
        }
        XCTAssertEqual(try Data(contentsOf: sentinelURL(manifests, id)), foreign, "foreign object untouched")
        XCTAssertTrue(fm.fileExists(atPath: staging.path))
    }

    /// Cleanup is descriptor-rooted: after the bound check, the staging NAME is swapped for
    /// an impostor tree — every deletion stays on the BOUND (moved-aside) tree, the impostor
    /// is never entered or deleted, and the blocked cleanup is surfaced (completion stands).
    func testStagingCleanupDescriptorRootedImpostorUntouched() throws {
        let (staging, id) = try makeStaging(ingested: [("a.pdf", "A")])
        let active = try makeActive(); let manifests = try makeManifestsDir()
        let report = try apply(staging, active)
        let aside = staging.deletingLastPathComponent().appendingPathComponent("aside-staging", isDirectory: true)
        let hooks = ApplyHooks(beforeStagingRemoval: { url in
            try self.fm.moveItem(at: url, to: aside)   // our bound tree moves aside…
            let docs = url.appendingPathComponent("attachments", isDirectory: true)
                          .appendingPathComponent("docs", isDirectory: true)
            try self.fm.createDirectory(at: docs, withIntermediateDirectories: true)
            try Data("VICTIM-A".utf8).write(to: docs.appendingPathComponent("a.pdf"))
            try Data("VICTIM-M".utf8).write(to: url.appendingPathComponent("manifest.json"))
        })
        let outcome = try completeSimple(report, manifests: manifests, hooks: hooks)
        guard case .completed(let r) = outcome else { return XCTFail() }
        XCTAssertFalse(r.stagingCleaned); XCTAssertNotNil(r.stagingCleanupError)
        XCTAssertTrue(fm.fileExists(atPath: sentinelURL(manifests, id).path), "completion stands")
        // The impostor at the original name is COMPLETELY untouched.
        XCTAssertEqual(try Data(contentsOf: staging.appendingPathComponent("attachments", isDirectory: true)
                                                   .appendingPathComponent("docs", isDirectory: true)
                                                   .appendingPathComponent("a.pdf")), Data("VICTIM-A".utf8))
        XCTAssertEqual(try Data(contentsOf: staging.appendingPathComponent("manifest.json")), Data("VICTIM-M".utf8))
        // Our own (moved-aside) tree was cleaned through the bound fds — its known entries are gone.
        XCTAssertFalse(fm.fileExists(atPath: aside.appendingPathComponent("manifest.json").path),
                       "deletions followed the bound inode, not the name")
    }

    /// Unknown entries are never enumerated or deleted: known files go, the non-empty dirs
    /// stay as residue (surfaced), and removing the unknowns lets a re-run converge.
    func testStagingCleanupLeavesUnknownEntriesAsResidueThenConverges() throws {
        let (staging, id) = try makeStaging(ingested: [("a.pdf", "A")])
        let active = try makeActive(); let manifests = try makeManifestsDir()
        let unknownDoc = stagedDoc(staging, "unknown.bin")
        try Data("U".utf8).write(to: unknownDoc)
        let unknownRoot = staging.appendingPathComponent("extra.txt")
        try Data("X".utf8).write(to: unknownRoot)
        let report = try apply(staging, active)

        let o1 = try completeSimple(report, manifests: manifests)
        guard case .completed(let r1) = o1 else { return XCTFail() }
        XCTAssertFalse(r1.stagingCleaned); XCTAssertNotNil(r1.stagingCleanupError)
        XCTAssertFalse(fm.fileExists(atPath: stagedDoc(staging, "a.pdf").path), "known file removed")
        XCTAssertEqual(try Data(contentsOf: unknownDoc), Data("U".utf8), "unknown doc untouched")
        XCTAssertEqual(try Data(contentsOf: unknownRoot), Data("X".utf8), "unknown root entry untouched")
        XCTAssertTrue(fm.fileExists(atPath: sentinelURL(manifests, id).path))

        try fm.removeItem(at: unknownDoc); try fm.removeItem(at: unknownRoot)
        let o2 = try completeSimple(report, manifests: manifests)
        guard case .completed(let r2) = o2 else { return XCTFail() }
        XCTAssertTrue(r2.stagingCleaned, "re-run converges once the residue is resolved")
        XCTAssertFalse(fm.fileExists(atPath: staging.path))
    }

    func testStagingAlreadyRemovedIsCleanNoop() throws {
        let (staging, _) = try makeStaging(ingested: [("a.pdf", "A")])
        let active = try makeActive(); let manifests = try makeManifestsDir()
        let report = try apply(staging, active)
        try fm.removeItem(at: staging)
        let outcome = try completeSimple(report, manifests: manifests)
        guard case .completed(let r) = outcome else { return XCTFail() }
        XCTAssertTrue(r.stagingCleaned, "absent staging is an idempotent no-op")
    }

    /// A symlink swapped in at the staging PATH is never followed by cleanup: the no-follow
    /// bind fails closed and the link target's contents survive.
    func testStagingCleanupSymlinkAtStagingPathNotFollowed() throws {
        let (staging, id) = try makeStaging(ingested: [("a.pdf", "A")])
        let active = try makeActive(); let manifests = try makeManifestsDir()
        let report = try apply(staging, active)
        let victim = try trackedTempDir().appendingPathComponent("victim", isDirectory: true)
        try fm.createDirectory(at: victim, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: victim.appendingPathComponent("manifest.json"))
        try fm.removeItem(at: staging)
        try fm.createSymbolicLink(at: staging, withDestinationURL: victim)

        let outcome = try completeSimple(report, manifests: manifests)
        guard case .completed(let r) = outcome else { return XCTFail() }
        XCTAssertFalse(r.stagingCleaned); XCTAssertNotNil(r.stagingCleanupError)
        XCTAssertEqual(try Data(contentsOf: victim.appendingPathComponent("manifest.json")), Data("keep".utf8),
                       "symlink target untouched")
        XCTAssertTrue(fm.fileExists(atPath: sentinelURL(manifests, id).path))
    }

    /// Swapping the WHOLE ImportManifests dir after publish (moved aside, fresh dir at the
    /// canonical path) must NOT count as completed: every in-dir check passes inside the
    /// bound (moved) dir, but the sentinel is no longer at its canonical path — no restart
    /// probe could find it. P10 fails retriable, staging is kept, and a re-run publishes at
    /// the canonical path.
    func testManifestsDirReplacedAfterPublishNotCompleted() throws {
        let (staging, id) = try makeStaging(ingested: [("a.pdf", "A")])
        let active = try makeActive(); let manifests = try makeManifestsDir()
        let report = try apply(staging, active)
        let aside = manifests.deletingLastPathComponent().appendingPathComponent("manifests-aside", isDirectory: true)
        XCTAssertThrowsError(try completeSimple(report, manifests: manifests,
                                                hooks: ApplyHooks(afterSentinelPublished: { _ in
            try self.fm.moveItem(at: manifests, to: aside)
            try self.fm.createDirectory(at: manifests, withIntermediateDirectories: false)
        }))) { e in
            guard case AttachmentApplyError.sentinelPublishIncomplete = e else { return XCTFail("got \(e)") }
        }
        XCTAssertTrue(fm.fileExists(atPath: staging.path), "staging must be kept — completion did not return")
        XCTAssertFalse(fm.fileExists(atPath: sentinelURL(manifests, id).path), "no sentinel at the canonical path")
        // A re-run publishes into the (new) canonical dir and completes.
        guard case .completed(let r) = try completeSimple(report, manifests: manifests) else { return XCTFail() }
        XCTAssertTrue(fm.fileExists(atPath: sentinelURL(manifests, id).path))
        XCTAssertTrue(r.stagingCleaned)
    }

    /// Swapping the whole staging tree for a STRUCTURALLY IDENTICAL impostor in the
    /// post-publish window: cleanup must act only on the PRE-PUBLISH bound evidence — the
    /// swapped-in tree is never entered, nothing is deleted anywhere, and the failure is
    /// surfaced (completion stands).
    func testStagingReplacedAfterPublishImpostorUntouched() throws {
        let (staging, id) = try makeStaging(ingested: [("a.pdf", "A")])
        let active = try makeActive(); let manifests = try makeManifestsDir()
        let report = try apply(staging, active)
        let aside = staging.deletingLastPathComponent().appendingPathComponent("real-staging-aside", isDirectory: true)
        let impostorDocs = staging.appendingPathComponent("attachments", isDirectory: true)
                                  .appendingPathComponent("docs", isDirectory: true)
        let outcome = try completeSimple(report, manifests: manifests,
                                         hooks: ApplyHooks(afterSentinelPublished: { _ in
            try self.fm.moveItem(at: staging, to: aside)
            try self.fm.createDirectory(at: impostorDocs, withIntermediateDirectories: true)
            try Data("VICTIM-A".utf8).write(to: impostorDocs.appendingPathComponent("a.pdf"))
            try Data("VICTIM-M".utf8).write(to: staging.appendingPathComponent("manifest.json"))
        }))
        guard case .completed(let r) = outcome else { return XCTFail() }
        XCTAssertFalse(r.stagingCleaned, "cleanup must refuse the swapped-in tree")
        XCTAssertNotNil(r.stagingCleanupError)
        XCTAssertTrue(fm.fileExists(atPath: sentinelURL(manifests, id).path), "completion stands")
        // The impostor — including its known-named files — is COMPLETELY untouched.
        XCTAssertEqual(try Data(contentsOf: impostorDocs.appendingPathComponent("a.pdf")), Data("VICTIM-A".utf8))
        XCTAssertEqual(try Data(contentsOf: staging.appendingPathComponent("manifest.json")), Data("VICTIM-M".utf8))
        // And nothing was deleted from the real (moved-aside) tree either.
        XCTAssertEqual(try Data(contentsOf: aside.appendingPathComponent("attachments", isDirectory: true)
                                                 .appendingPathComponent("docs", isDirectory: true)
                                                 .appendingPathComponent("a.pdf")), Data("A".utf8))
        XCTAssertTrue(fm.fileExists(atPath: aside.appendingPathComponent("manifest.json").path))
    }

    /// Swapping only attachments/docs after publish: deletions follow the PRE-PUBLISH bound
    /// docs inode (the moved-aside real dir), the replacement docs dir is never entered,
    /// and the blocked collapse is surfaced.
    func testStagedDocsReplacedAfterPublishReplacementUntouched() throws {
        let (staging, id) = try makeStaging(ingested: [("a.pdf", "A")])
        let active = try makeActive(); let manifests = try makeManifestsDir()
        let report = try apply(staging, active)
        let docs = staging.appendingPathComponent("attachments", isDirectory: true)
                          .appendingPathComponent("docs", isDirectory: true)
        let docsAside = staging.appendingPathComponent("attachments", isDirectory: true)
                               .appendingPathComponent("docs-aside", isDirectory: true)
        let outcome = try completeSimple(report, manifests: manifests,
                                         hooks: ApplyHooks(afterSentinelPublished: { _ in
            try self.fm.moveItem(at: docs, to: docsAside)
            try self.fm.createDirectory(at: docs, withIntermediateDirectories: false)
            try Data("VICTIM-A".utf8).write(to: docs.appendingPathComponent("a.pdf"))
        }))
        guard case .completed(let r) = outcome else { return XCTFail() }
        XCTAssertFalse(r.stagingCleaned); XCTAssertNotNil(r.stagingCleanupError)
        // The replacement docs dir and its file are untouched.
        XCTAssertEqual(try Data(contentsOf: docs.appendingPathComponent("a.pdf")), Data("VICTIM-A".utf8))
        // Deletions followed the bound inode: the REAL docs (moved aside) lost its known file.
        XCTAssertFalse(fm.fileExists(atPath: docsAside.appendingPathComponent("a.pdf").path))
        XCTAssertTrue(fm.fileExists(atPath: sentinelURL(manifests, id).path))
    }

    // MARK: - C11a. Trusted staging root (the C11b hand-off: GatedStagedSnapshot.root)

    /// Real gate evidence via the production chain: source dir (DB + one attachment) →
    /// StagingIngest → StagedSnapshotGate. The caller must remove `gated.stagingDir`.
    private func makeGatedStaging() throws -> GatedStagedSnapshot {
        let src = try trackedTempDir().appendingPathComponent("SoloLedger", isDirectory: true)
        let srcDocs = src.appendingPathComponent("attachments", isDirectory: true)
                         .appendingPathComponent("docs", isDirectory: true)
        try fm.createDirectory(at: srcDocs, withIntermediateDirectories: true)
        try fm.copyItem(at: preparedDBURL, to: src.appendingPathComponent(AppPaths.databaseFileName))
        try Data("A".utf8).write(to: srcDocs.appendingPathComponent("a.pdf"))
        let id = try XCTUnwrap(ImportID("c11a-\(UUID().uuidString.lowercased())"))
        let result = try StagingIngest().ingest(.userSelectedDataDir(src), importID: id, timestamp: "t")
        return try StagedSnapshotGate().gate(result)
    }

    /// The C11b hand-off works end-to-end: `complete` with `trustedStagingRoot: gated.root`
    /// cleans the real staged tree through the gate's bound descriptor.
    func testTrustedStagingRootCleansViaGateEvidence() throws {
        let gated = try makeGatedStaging()
        defer { try? fm.removeItem(at: gated.stagingDir) }
        let active = try makeActive(); let manifests = try makeManifestsDir()
        let report = try apply(gated.stagingDir, active)
        let outcome = try AttachmentApply().complete(report: report, referenceAudit: matchingAudit(report),
                                                     acknowledgement: nil, preparedDatabaseAt: preparedDBURL,
                                                     manifestsDir: manifests, trustedStagingRoot: gated.root,
                                                     hooks: ApplyHooks())
        guard case .completed(let r) = outcome else { return XCTFail() }
        XCTAssertTrue(r.stagingCleaned, "cleanup through the gate's bound root must succeed")
        XCTAssertFalse(fm.fileExists(atPath: gated.stagingDir.path))
    }

    /// The staging URL is swapped for a structurally identical impostor BEFORE complete()
    /// even runs. With `trustedStagingRoot` (the gate's bound root) the impostor is NEVER
    /// bound, never entered, never deleted — cleanup blocks with nothing touched anywhere.
    func testTrustedStagingRootRefusesPreSwappedImpostor() throws {
        let gated = try makeGatedStaging()
        defer { try? fm.removeItem(at: gated.stagingDir) }
        let active = try makeActive(); let manifests = try makeManifestsDir()
        let report = try apply(gated.stagingDir, active)

        // Swap BEFORE complete: real tree moves aside, impostor with the same known names appears.
        let aside = try trackedTempDir().appendingPathComponent("real-staging-aside", isDirectory: true)
        try fm.moveItem(at: gated.stagingDir, to: aside)
        let impostorDocs = gated.stagingDir.appendingPathComponent("attachments", isDirectory: true)
                                           .appendingPathComponent("docs", isDirectory: true)
        try fm.createDirectory(at: impostorDocs, withIntermediateDirectories: true)
        try Data("VICTIM-A".utf8).write(to: impostorDocs.appendingPathComponent("a.pdf"))
        try Data("VICTIM-M".utf8).write(to: gated.stagingDir.appendingPathComponent("manifest.json"))
        try Data("VICTIM-DB".utf8).write(to: gated.stagingDir.appendingPathComponent(AppPaths.databaseFileName))

        let outcome = try AttachmentApply().complete(report: report, referenceAudit: matchingAudit(report),
                                                     acknowledgement: nil, preparedDatabaseAt: preparedDBURL,
                                                     manifestsDir: manifests, trustedStagingRoot: gated.root,
                                                     hooks: ApplyHooks())
        guard case .completed(let r) = outcome else { return XCTFail() }
        XCTAssertFalse(r.stagingCleaned, "cleanup must refuse the pre-swapped tree")
        XCTAssertNotNil(r.stagingCleanupError)
        // The impostor — including every known-named file — is COMPLETELY untouched.
        XCTAssertEqual(try Data(contentsOf: impostorDocs.appendingPathComponent("a.pdf")), Data("VICTIM-A".utf8))
        XCTAssertEqual(try Data(contentsOf: gated.stagingDir.appendingPathComponent("manifest.json")), Data("VICTIM-M".utf8))
        XCTAssertEqual(try Data(contentsOf: gated.stagingDir.appendingPathComponent(AppPaths.databaseFileName)), Data("VICTIM-DB".utf8))
        // And the REAL (moved-aside) tree is also untouched — nothing was deleted at all.
        XCTAssertTrue(fm.fileExists(atPath: aside.appendingPathComponent("manifest.json").path))
        XCTAssertEqual(try Data(contentsOf: aside.appendingPathComponent("attachments", isDirectory: true)
                                                 .appendingPathComponent("docs", isDirectory: true)
                                                 .appendingPathComponent("a.pdf")), Data("A".utf8))
    }

    /// An oversize file at the sentinel name is malformed/hostile: the size-capped bound
    /// read refuses it (never a truncated success), classified as a conflict, left untouched.
    func testOversizeExistingSentinelRejected() throws {
        let (staging, id) = try makeStaging(ingested: [("a.pdf", "A")])
        let active = try makeActive(); let manifests = try makeManifestsDir()
        let report = try apply(staging, active)
        var big = Data("{\"pad\":\"".utf8)
        big.append(Data(repeating: 0x41, count: AttachmentApply.maxSentinelBytes + 1024))
        big.append(Data("\"}".utf8))
        try big.write(to: sentinelURL(manifests, id))
        XCTAssertThrowsError(try completeSimple(report, manifests: manifests)) { e in
            guard case AttachmentApplyError.sentinelIdentityMismatch = e else { return XCTFail("got \(e)") }
        }
        XCTAssertEqual(try Data(contentsOf: sentinelURL(manifests, id)).count, big.count, "oversize file untouched")
        XCTAssertTrue(fm.fileExists(atPath: staging.path))
    }
}
