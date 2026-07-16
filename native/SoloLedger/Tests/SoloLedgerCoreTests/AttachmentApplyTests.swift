import XCTest
@testable import SoloLedgerCore

/// Identity-bound, fail-closed, two-phase attachment migration. apply() copies absent files
/// non-destructively; complete() finalizes only with un-forgeable, import-bound reference-audit
/// evidence + (if unresolved) an acknowledgement bound to the full operation identity. All
/// fixtures are synthetic temp files.
final class AttachmentApplyTests: LedgerTestCase {

    private let fm = FileManager.default
    private let preparedDB = "preparedDB-identity-abc"
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
    private func matchingAudit(_ r: AttachmentApplyReport, dangling: [String] = []) -> ReferenceAudit {
        ReferenceAudit(importID: r.importID.rawValue, snapshotIdentitySHA256: r.manifest.snapshotIdentitySHA256,
                       attachmentManifestSHA256: r.manifest.attachmentManifestSHA256,
                       preparedDBIdentity: r.preparedDBIdentity, danglingReferences: dangling)
    }
    private func apply(_ staging: URL, _ active: URL, hooks: ApplyHooks = ApplyHooks()) throws -> AttachmentApplyReport {
        try AttachmentApply().apply(stagingDir: staging, activeAttachmentsDir: active, preparedDBIdentity: preparedDB, hooks: hooks)
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
                                                     acknowledgement: nil, manifestsDir: manifests, hooks: ApplyHooks())
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
                                                acknowledgement: nil, manifestsDir: manifests, hooks: ApplyHooks())
        guard case .requiresAcknowledgement(let request, let unresolved) = o1 else { return XCTFail("got \(o1)") }
        XCTAssertEqual(unresolved.items.map { $0.name }, ["doc-b.jpg"])
        XCTAssertFalse(fm.fileExists(atPath: sentinelURL(manifests, id).path))
        XCTAssertTrue(fm.fileExists(atPath: staging.path))

        let o2 = try AttachmentApply().complete(report: report, referenceAudit: matchingAudit(report),
                                                acknowledgement: request.acknowledge(), manifestsDir: manifests, hooks: ApplyHooks())
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
                                                acknowledgement: nil, manifestsDir: manifests, hooks: ApplyHooks())
        guard case .requiresAcknowledgement(let request, _) = o1 else { return XCTFail() }
        let o2 = try AttachmentApply().complete(report: report, referenceAudit: matchingAudit(report),
                                                acknowledgement: request.acknowledge(), manifestsDir: manifests, hooks: ApplyHooks())
        guard case .completed(let r) = o2 else { return XCTFail() }
        XCTAssertEqual(r.unresolved.items.count, 2)
    }

    // MARK: - 4. Ack invalidated when the report changes (dangling refs added)

    func testAcknowledgementInvalidatedWhenReportChanges() throws {
        let (staging, _) = try makeStaging(ingested: [("doc-a.pdf", "A")])
        let active = try makeActive(); let manifests = try makeManifestsDir()
        let report = try apply(staging, active)

        let o1 = try AttachmentApply().complete(report: report, referenceAudit: matchingAudit(report, dangling: ["ref1"]),
                                                acknowledgement: nil, manifestsDir: manifests, hooks: ApplyHooks())
        guard case .requiresAcknowledgement(let req1, _) = o1 else { return XCTFail() }

        // Report changes (audit finds ref2) → an ack for req1 is stale.
        let o2 = try AttachmentApply().complete(report: report, referenceAudit: matchingAudit(report, dangling: ["ref1", "ref2"]),
                                                acknowledgement: req1.acknowledge(), manifestsDir: manifests, hooks: ApplyHooks())
        guard case .requiresAcknowledgement(let req2, _) = o2 else { return XCTFail("stale ack must be rejected") }
        XCTAssertNotEqual(req2.unresolvedReportHash, req1.unresolvedReportHash)

        let o3 = try AttachmentApply().complete(report: report, referenceAudit: matchingAudit(report, dangling: ["ref1", "ref2"]),
                                                acknowledgement: req2.acknowledge(), manifestsDir: manifests, hooks: ApplyHooks())
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
        for bad: Int? in [nil, 0, 999] {
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
                                                            acknowledgement: nil, manifestsDir: manifests, hooks: ApplyHooks())) { e in
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
                                                            manifestsDir: manifests, hooks: ApplyHooks(onCompletionTempWrite: { throw TestError() })))
        XCTAssertFalse(fm.fileExists(atPath: sentinelURL(manifests, id).path))
        XCTAssertTrue(tempManifests(manifests).isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: staging.path))
    }
    func testCompletionPublishFailureKeepsStagingNoSentinelNoTemp() throws {
        let (staging, id) = try makeStaging(ingested: [("a.pdf", "A")]); let active = try makeActive(); let manifests = try makeManifestsDir()
        let report = try apply(staging, active)
        XCTAssertThrowsError(try AttachmentApply().complete(report: report, referenceAudit: matchingAudit(report), acknowledgement: nil,
                                                            manifestsDir: manifests, hooks: ApplyHooks(onCompletionPublish: { throw TestError() })))
        XCTAssertFalse(fm.fileExists(atPath: sentinelURL(manifests, id).path))
        XCTAssertTrue(tempManifests(manifests).isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: staging.path))
    }
    func testStagingCleanupFailureSurfacedButCompletionRecorded() throws {
        let (staging, _) = try makeStaging(ingested: [("a.pdf", "A")]); let active = try makeActive(); let manifests = try makeManifestsDir()
        let report = try apply(staging, active)
        let outcome = try AttachmentApply().complete(report: report, referenceAudit: matchingAudit(report), acknowledgement: nil,
                                                     manifestsDir: manifests, hooks: ApplyHooks(cleanup: { _ in throw TestError() }))
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
                                                manifestsDir: manifests, hooks: ApplyHooks(cleanup: { _ in throw TestError() }))
        guard case .completed(let r1) = o1, !r1.stagingCleaned else { return XCTFail() }
        let o2 = try AttachmentApply().complete(report: report, referenceAudit: matchingAudit(report), acknowledgement: nil,
                                                manifestsDir: manifests, hooks: ApplyHooks())
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
                                                            acknowledgement: nil, manifestsDir: manifests, hooks: ApplyHooks())) { e in
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
                           attachmentManifestSHA256: attach, preparedDBIdentity: prepared, danglingReferences: [])
        }
        let good = matchingAudit(report)
        for (a, field) in [(audit(snapshot: "X", attach: good.attachmentManifestSHA256, prepared: preparedDB), "snapshotIdentity"),
                           (audit(snapshot: good.snapshotIdentitySHA256, attach: "X", prepared: preparedDB), "attachmentManifest"),
                           (audit(snapshot: good.snapshotIdentitySHA256, attach: good.attachmentManifestSHA256, prepared: "X"), "preparedDBIdentity")] {
            XCTAssertThrowsError(try AttachmentApply().complete(report: report, referenceAudit: a, acknowledgement: nil,
                                                                manifestsDir: manifests, hooks: ApplyHooks())) { e in
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
                                                manifestsDir: manifests, hooks: ApplyHooks())
        guard case .requiresAcknowledgement(let reqA, let uA) = oA else { return XCTFail() }
        let oB = try AttachmentApply().complete(report: reportB, referenceAudit: matchingAudit(reportB), acknowledgement: nil,
                                                manifestsDir: manifests, hooks: ApplyHooks())
        guard case .requiresAcknowledgement(let reqB, let uB) = oB else { return XCTFail() }
        XCTAssertEqual(uA.reportHash, uB.reportHash, "identical unresolved lists share a report hash")
        XCTAssertNotEqual(reqA.importID, reqB.importID)

        // A's acknowledgement must NOT complete B.
        let rejected = try AttachmentApply().complete(report: reportB, referenceAudit: matchingAudit(reportB),
                                                      acknowledgement: reqA.acknowledge(), manifestsDir: manifests, hooks: ApplyHooks())
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
                                                manifestsDir: manifests, hooks: ApplyHooks())
        guard case .requiresAcknowledgement(let reqX, _) = ox else { return XCTFail() }
        // The ack for detail v1 must NOT confirm the v2 report.
        let oy = try AttachmentApply().complete(report: ry, referenceAudit: matchingAudit(ry), acknowledgement: reqX.acknowledge(),
                                                manifestsDir: manifests, hooks: ApplyHooks())
        guard case .requiresAcknowledgement(let reqY, _) = oy else { return XCTFail("detail change must invalidate the old ack") }
        XCTAssertNotEqual(reqX.unresolvedReportHash, reqY.unresolvedReportHash)
    }

    func testAcknowledgementFromPreparedDBAcannotConfirmB() throws {
        // Same staging (same import/snapshot/attachment identity) applied against TWO different
        // prepared DBs → an ack bound to prepared-DB A cannot confirm the prepared-DB-B report.
        let (staging, _) = try makeStaging(ingested: [("doc-a.pdf", "A"), ("doc-b.jpg", "B")])
        try fm.removeItem(at: stagedDoc(staging, "doc-b.jpg"))   // unresolved (missing) → ack required
        let manifests = try makeManifestsDir()
        let reportA = try AttachmentApply().apply(stagingDir: staging, activeAttachmentsDir: try makeActive(), preparedDBIdentity: "DB-A")
        let reportB = try AttachmentApply().apply(stagingDir: staging, activeAttachmentsDir: try makeActive(), preparedDBIdentity: "DB-B")
        XCTAssertEqual(reportA.manifest.snapshotIdentitySHA256, reportB.manifest.snapshotIdentitySHA256)
        XCTAssertNotEqual(reportA.preparedDBIdentity, reportB.preparedDBIdentity)

        let oA = try AttachmentApply().complete(report: reportA, referenceAudit: matchingAudit(reportA), acknowledgement: nil,
                                                manifestsDir: manifests, hooks: ApplyHooks())
        guard case .requiresAcknowledgement(let reqA, _) = oA else { return XCTFail() }
        // A's acknowledgement must NOT confirm B (different prepared DB).
        let rejected = try AttachmentApply().complete(report: reportB, referenceAudit: matchingAudit(reportB),
                                                      acknowledgement: reqA.acknowledge(), manifestsDir: manifests, hooks: ApplyHooks())
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

        let rA = try AttachmentApply().apply(stagingDir: stagingA, activeAttachmentsDir: try makeActive(), preparedDBIdentity: "DB-A")
        let oA = try AttachmentApply().complete(report: rA, referenceAudit: matchingAudit(rA), acknowledgement: nil,
                                                manifestsDir: manifests, hooks: ApplyHooks())
        guard case .completed(let cA) = oA else { return XCTFail() }
        XCTAssertEqual(try readManifest(cA.completionSentinelURL).preparedDBIdentity, "DB-A")

        let rB = try AttachmentApply().apply(stagingDir: stagingB, activeAttachmentsDir: try makeActive(), preparedDBIdentity: "DB-B")
        XCTAssertEqual(rA.manifest.snapshotIdentitySHA256, rB.manifest.snapshotIdentitySHA256)
        XCTAssertThrowsError(try AttachmentApply().complete(report: rB, referenceAudit: matchingAudit(rB), acknowledgement: nil,
                                                            manifestsDir: manifests, hooks: ApplyHooks())) { e in
            guard case AttachmentApplyError.sentinelIdentityMismatch = e else { return XCTFail("got \(e)") }
        }
        XCTAssertEqual(try readManifest(sentinelURL(manifests, id)).preparedDBIdentity, "DB-A", "existing sentinel not overwritten")
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
                                                            manifestsDir: manifests,
                                                            hooks: ApplyHooks(onCompletionPublish: {
            try self.writeManifest(intruder, to: self.sentinelURL(manifests, id))   // race: sentinel appears now
        }))) { e in
            guard case AttachmentApplyError.sentinelIdentityMismatch = e else { return XCTFail("got \(e)") }
        }
        XCTAssertEqual(try readManifest(sentinelURL(manifests, id)).snapshotIdentitySHA256, "snapINTRUDER", "intruder sentinel not overwritten")
        XCTAssertTrue(tempManifests(manifests).isEmpty, "our temp is cleaned")
        XCTAssertTrue(fm.fileExists(atPath: staging.path), "staging kept")
    }

    // MARK: - 27. The reference auditor is not implemented → App cannot fabricate completion

    func testReferenceAuditorNotImplementedThrows() throws {
        let (staging, _) = try makeStaging(ingested: [("a.pdf", "A")])
        let report = try apply(staging, try makeActive())
        XCTAssertThrowsError(try AttachmentReferenceAuditor().audit(report: report,
                                                                    preparedDatabaseAt: try makeActive())) { e in
            guard case AttachmentApplyError.referenceAuditNotImplemented = e else { return XCTFail("got \(e)") }
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
}
