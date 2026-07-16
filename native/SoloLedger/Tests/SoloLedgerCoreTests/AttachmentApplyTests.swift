import XCTest
@testable import SoloLedgerCore

/// Non-destructive attachment apply + per-import completion sentinel: copy only absent
/// files, skip byte-identical ones, BLOCK (never overwrite) same-name-different-content,
/// atomically persist the completion sentinel BEFORE cleaning staging, and keep staging on
/// any failure for idempotent retry. All fixtures are synthetic temp files.
final class AttachmentApplyTests: LedgerTestCase {

    private let fm = FileManager.default
    private struct TestError: Error {}

    // MARK: - Fixtures (all in temp — never the real Staging/attachments/ImportManifests)

    private func makeStaging(_ files: [(name: String, bytes: String)]) throws -> (dir: URL, id: ImportID) {
        let id = ImportID("apply-\(UUID().uuidString)")!
        let dir = try trackedTempDir().appendingPathComponent("import-\(id.rawValue)", isDirectory: true)
        let docs = dir.appendingPathComponent("attachments", isDirectory: true).appendingPathComponent("docs", isDirectory: true)
        try fm.createDirectory(at: docs, withIntermediateDirectories: true)
        var results: [ImportManifest.FileResult] = []
        for f in files {
            let url = docs.appendingPathComponent(f.name)
            try Data(f.bytes.utf8).write(to: url)
            results.append(.init(name: f.name, outcome: .ingested,
                                 sha256: try FileHash.sha256Hex(of: url), size: Int64(f.bytes.utf8.count)))
        }
        let manifest = ImportManifest(importID: id.rawValue, sourceKind: "test", createdAt: "t",
                                      sourceDBSHA256: "db", walSHA256: nil, snapshotIdentitySHA256: "snap",
                                      attachmentManifestSHA256: "att", files: results, status: .ingested, report: nil)
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        try enc.encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
        return (dir, id)
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
    private func tempManifestFiles(_ manifests: URL) -> [String] {
        ((try? fm.contentsOfDirectory(at: manifests, includingPropertiesForKeys: nil)) ?? [])
            .map { $0.lastPathComponent }.filter { $0.hasPrefix(".tmp-") }
    }

    // MARK: - Happy path

    func testApplyCopiesAbsentSkipsIdenticalCompletesAndCleansStaging() throws {
        let (staging, id) = try makeStaging([("doc-a.pdf", "A"), ("doc-b.jpg", "B")])
        let active = try makeActive([("doc-b.jpg", "B")])       // doc-b already present, identical
        let manifests = try makeManifestsDir()

        let r = try AttachmentApply().apply(stagingDir: staging, activeAttachmentsDir: active,
                                            manifestsDir: manifests, hooks: ApplyHooks())

        XCTAssertEqual(r.copied, ["doc-a.pdf"])
        XCTAssertEqual(r.skippedIdentical, ["doc-b.jpg"])
        XCTAssertEqual(try String(contentsOf: active.appendingPathComponent("doc-a.pdf")), "A")
        XCTAssertFalse(fm.fileExists(atPath: active.appendingPathComponent("doc-a.pdf.part").path))

        // Completion sentinel persisted, status .complete.
        XCTAssertEqual(r.completionSentinelURL, sentinelURL(manifests, id))
        XCTAssertTrue(fm.fileExists(atPath: r.completionSentinelURL.path))
        let sentinel = try JSONDecoder().decode(ImportManifest.self, from: Data(contentsOf: r.completionSentinelURL))
        XCTAssertEqual(sentinel.status, .complete)
        XCTAssertEqual(sentinel.applied?.copied, ["doc-a.pdf"])
        XCTAssertEqual(sentinel.applied?.skippedIdentical, ["doc-b.jpg"])

        // Staging cleaned only AFTER completion.
        XCTAssertTrue(r.stagingCleaned)
        XCTAssertNil(r.stagingCleanupError)
        XCTAssertFalse(fm.fileExists(atPath: staging.path))
    }

    // MARK: - Plan classification

    func testPlanClassifiesCopyIdenticalConflictAndMissing() throws {
        let (staging, _) = try makeStaging([("a.pdf", "A"), ("b.pdf", "B"), ("c.pdf", "C")])
        let active = try makeActive([("b.pdf", "B"), ("c.pdf", "DIFFERENT")])   // b identical, c conflict, a absent

        let plan = try AttachmentApply().plan(stagingDir: staging, activeAttachmentsDir: active)
        XCTAssertEqual(plan.toCopy, ["a.pdf"])
        XCTAssertEqual(plan.identical, ["b.pdf"])
        XCTAssertEqual(plan.conflicts.map { $0.name }, ["c.pdf"])
        XCTAssertTrue(plan.hasConflicts)
    }

    // MARK: - Conflict blocks before swap, never overwrites

    func testApplyBlocksOnConflictKeepsStagingAndNeverOverwrites() throws {
        let (staging, id) = try makeStaging([("a.pdf", "A")])
        let active = try makeActive([("a.pdf", "DIFFERENT")])
        let manifests = try makeManifestsDir()

        XCTAssertThrowsError(try AttachmentApply().apply(stagingDir: staging, activeAttachmentsDir: active,
                                                         manifestsDir: manifests, hooks: ApplyHooks())) { e in
            guard case AttachmentApplyError.conflicts(let c) = e else { return XCTFail("expected .conflicts, got \(e)") }
            XCTAssertEqual(c.map { $0.name }, ["a.pdf"])
        }
        XCTAssertEqual(try String(contentsOf: active.appendingPathComponent("a.pdf")), "DIFFERENT", "must never overwrite")
        XCTAssertFalse(fm.fileExists(atPath: sentinelURL(manifests, id).path), "no completion on conflict")
        XCTAssertTrue(fm.fileExists(atPath: staging.path), "staging kept on conflict")
    }

    // MARK: - Idempotent re-run

    func testApplyIsIdempotentOnRerun() throws {
        let (staging, id) = try makeStaging([("a.pdf", "A")])
        let active = try makeActive()
        let manifests = try makeManifestsDir()

        // First run: force a staging-cleanup failure so staging survives for a re-run.
        let r1 = try AttachmentApply().apply(stagingDir: staging, activeAttachmentsDir: active,
                                             manifestsDir: manifests, hooks: ApplyHooks(cleanup: { _ in throw TestError() }))
        XCTAssertEqual(r1.copied, ["a.pdf"])
        XCTAssertFalse(r1.stagingCleaned)
        XCTAssertNotNil(r1.stagingCleanupError)
        XCTAssertTrue(fm.fileExists(atPath: staging.path))                 // residue
        XCTAssertTrue(fm.fileExists(atPath: sentinelURL(manifests, id).path))

        // Second run over the surviving staging: copies nothing (identical), re-completes, cleans.
        let r2 = try AttachmentApply().apply(stagingDir: staging, activeAttachmentsDir: active,
                                             manifestsDir: manifests, hooks: ApplyHooks())
        XCTAssertEqual(r2.copied, [], "idempotent: nothing re-copied")
        XCTAssertEqual(r2.skippedIdentical, ["a.pdf"])
        XCTAssertTrue(r2.stagingCleaned)
        XCTAssertFalse(fm.fileExists(atPath: staging.path))
    }

    // MARK: - Fault injection: keep staging, no completion

    func testAttachmentCopyFaultKeepsStagingAndDoesNotComplete() throws {
        let (staging, id) = try makeStaging([("a.pdf", "A")])
        let active = try makeActive()
        let manifests = try makeManifestsDir()

        XCTAssertThrowsError(try AttachmentApply().apply(stagingDir: staging, activeAttachmentsDir: active,
                                                         manifestsDir: manifests,
                                                         hooks: ApplyHooks(onAttachmentCopy: { _ in throw TestError() })))
        XCTAssertFalse(fm.fileExists(atPath: active.appendingPathComponent("a.pdf").path))
        XCTAssertFalse(fm.fileExists(atPath: active.appendingPathComponent("a.pdf.part").path), "no partial")
        XCTAssertFalse(fm.fileExists(atPath: sentinelURL(manifests, id).path), "no completion sentinel")
        XCTAssertTrue(fm.fileExists(atPath: staging.path), "staging kept for retry")
    }

    func testCompletionTempWriteFailureKeepsStagingAndDoesNotComplete() throws {
        let (staging, id) = try makeStaging([("a.pdf", "A")])
        let active = try makeActive()
        let manifests = try makeManifestsDir()

        XCTAssertThrowsError(try AttachmentApply().apply(stagingDir: staging, activeAttachmentsDir: active,
                                                         manifestsDir: manifests,
                                                         hooks: ApplyHooks(onCompletionTempWrite: { throw TestError() })))
        XCTAssertFalse(fm.fileExists(atPath: sentinelURL(manifests, id).path))
        XCTAssertTrue(tempManifestFiles(manifests).isEmpty, "no temp written when temp-write faults")
        XCTAssertTrue(fm.fileExists(atPath: staging.path), "staging kept")
        // The copy happened before completion — fine; a retry re-completes idempotently.
        XCTAssertTrue(fm.fileExists(atPath: active.appendingPathComponent("a.pdf").path))
    }

    func testCompletionPublishFailureKeepsStagingAndLeavesNoTempOrSentinel() throws {
        let (staging, id) = try makeStaging([("a.pdf", "A")])
        let active = try makeActive()
        let manifests = try makeManifestsDir()

        XCTAssertThrowsError(try AttachmentApply().apply(stagingDir: staging, activeAttachmentsDir: active,
                                                         manifestsDir: manifests,
                                                         hooks: ApplyHooks(onCompletionPublish: { throw TestError() })))
        XCTAssertFalse(fm.fileExists(atPath: sentinelURL(manifests, id).path), "sentinel NOT published")
        XCTAssertTrue(tempManifestFiles(manifests).isEmpty, "unpublished temp is cleaned on publish failure")
        XCTAssertTrue(fm.fileExists(atPath: staging.path), "staging kept for retry")
    }

    // MARK: - Staging cleanup failure is surfaced but non-fatal (residue kept)

    func testStagingCleanupFailureSurfacedButCompletionRecorded() throws {
        let (staging, id) = try makeStaging([("a.pdf", "A")])
        let active = try makeActive()
        let manifests = try makeManifestsDir()

        // Does NOT throw — completion is already recorded; cleanup failure is surfaced in the result.
        let r = try AttachmentApply().apply(stagingDir: staging, activeAttachmentsDir: active,
                                            manifestsDir: manifests, hooks: ApplyHooks(cleanup: { _ in throw TestError() }))
        XCTAssertTrue(fm.fileExists(atPath: r.completionSentinelURL.path), "completion recorded despite cleanup failure")
        XCTAssertFalse(r.stagingCleaned)
        XCTAssertNotNil(r.stagingCleanupError)
        XCTAssertTrue(fm.fileExists(atPath: staging.path), "residue kept for a later reaper")
    }
}
