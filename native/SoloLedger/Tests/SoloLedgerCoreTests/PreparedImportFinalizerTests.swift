import XCTest
@testable import SoloLedgerCore

/// 2B-3 C11b: PreparedImportFinalizer — bracketed apply → audit → complete over the
/// activated DB, plus the disk-derived completion probe. All fixtures drive the REAL
/// production chain (ingest → gate → run → activate → finalize).
final class PreparedImportFinalizerTests: LedgerTestCase {

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

    private func makeSQLiteDB(named: String = "src.db") throws -> URL {
        let url = try trackedTempDir().appendingPathComponent(named)
        let db = try SQLiteDatabase(path: url.path, mode: .readWriteCreate)
        try db.execute("PRAGMA journal_mode = DELETE")
        try db.execute("PRAGMA user_version = 0")
        try db.close()
        return url
    }

    private struct Fix {
        let gated: GatedStagedSnapshot
        let prepared: PreparedImport
        let activated: ActivatedDatabase
        let activeURL: URL
        let attachmentsDir: URL
        let manifests: URL
        var sentinelURL: URL { manifests.appendingPathComponent("\(gated.importID.rawValue).json") }
        var recordURL: URL { activeURL.deletingLastPathComponent().appendingPathComponent(PreparedImportActivator.recordName) }
        func stagedDoc(_ name: String) -> URL {
            gated.stagingDir.appendingPathComponent("attachments", isDirectory: true)
                            .appendingPathComponent("docs", isDirectory: true)
                            .appendingPathComponent(name)
        }
    }

    /// Real chain: source dir (empty v0 DB + attachments) → ingest → gate → run → activate.
    private func fixture(attachments: [(name: String, bytes: String)] = [("a.pdf", "A")]) throws -> Fix {
        let src = try trackedTempDir().appendingPathComponent("SoloLedger", isDirectory: true)
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try fm.copyItem(at: try makeSQLiteDB(), to: src.appendingPathComponent(AppPaths.databaseFileName))
        if !attachments.isEmpty {
            let docs = src.appendingPathComponent("attachments", isDirectory: true)
                          .appendingPathComponent("docs", isDirectory: true)
            try fm.createDirectory(at: docs, withIntermediateDirectories: true)
            for a in attachments { try Data(a.bytes.utf8).write(to: docs.appendingPathComponent(a.name)) }
        }
        let id = try XCTUnwrap(ImportID("fin-\(UUID().uuidString.lowercased())"))
        stagedIDs.append(id)
        let result = try StagingIngest().ingest(.userSelectedDataDir(src), importID: id, timestamp: "t")
        let gated = try StagedSnapshotGate().gate(result)
        let prep = try trackedTempDir().appendingPathComponent("PreparedImports", isDirectory: true)
        try fm.createDirectory(at: prep, withIntermediateDirectories: true)
        let work = try trackedTempDir().appendingPathComponent("Work", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let prepared = try PreparedImportRunner().run(gated, workingDirectory: work, preparedRoot: prep)
        let slot = try trackedTempDir().appendingPathComponent("ActiveSlot", isDirectory: true)
        try fm.createDirectory(at: slot, withIntermediateDirectories: true)
        let activeURL = slot.appendingPathComponent(AppPaths.databaseFileName)
        let activated = try PreparedImportActivator().activate(prepared, activeDestination: activeURL)
        let attachmentsDir = try trackedTempDir().appendingPathComponent("active-docs", isDirectory: true)
        try fm.createDirectory(at: attachmentsDir, withIntermediateDirectories: true)
        let manifests = try trackedTempDir().appendingPathComponent("ImportManifests", isDirectory: true)
        try fm.createDirectory(at: manifests, withIntermediateDirectories: true)
        return Fix(gated: gated, prepared: prepared, activated: activated, activeURL: activeURL,
                   attachmentsDir: attachmentsDir, manifests: manifests)
    }

    private func finalize(_ fix: Fix, ack: Acknowledgement? = nil,
                          hooks: FinalizeHooks = FinalizeHooks()) throws -> FinalizeOutcome {
        try PreparedImportFinalizer().finalize(fix.activated, gated: fix.gated,
                                               activeAttachmentsDir: fix.attachmentsDir,
                                               acknowledgement: ack, manifestsDir: fix.manifests, hooks: hooks)
    }

    private func record(_ fix: Fix) throws -> ActivationRecord {
        try fix.activated.boundOwnerRecord.decode(ActivationRecord.self)
    }
    private func probe(_ fix: Fix, stagingDir: URL? = nil,
                       hooks: ApplyHooks = ApplyHooks()) throws -> PreparedImportFinalizer.CompletionProbe {
        try PreparedImportFinalizer.probeCompletion(expected: try record(fix), importID: fix.gated.importID,
                                                    manifestsDir: fix.manifests, stagingDir: stagingDir, hooks: hooks)
    }
    private func readSentinel(_ fix: Fix) throws -> ImportManifest {
        try JSONDecoder().decode(ImportManifest.self, from: Data(contentsOf: fix.sentinelURL))
    }
    private func writeSentinel(_ m: ImportManifest, _ fix: Fix) throws {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(m).write(to: fix.sentinelURL)
    }

    private struct Crash: Error {}

    // MARK: - Happy paths / outcomes

    func testFinalizeHappyPathCompletes() throws {
        let fix = try fixture()
        guard case .completed(let f) = try finalize(fix) else { return XCTFail() }
        XCTAssertEqual(f.importID.rawValue, fix.gated.importID.rawValue)
        XCTAssertEqual(f.preparedDBIdentity, fix.activated.preparedDBIdentity)
        XCTAssertTrue(f.applyResult.stagingCleaned)
        XCTAssertFalse(fm.fileExists(atPath: fix.gated.stagingDir.path), "staging cleaned")
        XCTAssertEqual(try Data(contentsOf: fix.attachmentsDir.appendingPathComponent("a.pdf")), Data("A".utf8))
        // The persisted sentinel satisfies EVERY completed-sentinel invariant.
        XCTAssertNil(PreparedImportFinalizer.validateCompletedSentinel(try readSentinel(fix),
                                                                       record: try record(fix),
                                                                       importID: fix.gated.importID))
    }

    func testFinalizeReuseExistingActivePath() throws {
        let fix = try fixture()
        let reused = try PreparedImportActivator().activate(fix.prepared, activeDestination: fix.activeURL)
        XCTAssertTrue(reused.reusedExisting)
        let outcome = try PreparedImportFinalizer().finalize(reused, gated: fix.gated,
                                                             activeAttachmentsDir: fix.attachmentsDir,
                                                             manifestsDir: fix.manifests)
        guard case .completed = outcome else { return XCTFail("got \(outcome)") }
    }

    func testFinalizeCleanupFailedThenRerunConverges() throws {
        let fix = try fixture()
        let o1 = try finalize(fix, hooks: FinalizeHooks(apply: ApplyHooks(cleanup: { _ in throw Crash() })))
        guard case .completedButCleanupFailed(let f1, let why) = o1 else { return XCTFail("got \(o1)") }
        XCTAssertFalse(f1.applyResult.stagingCleaned); XCTAssertFalse(why.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: fix.gated.stagingDir.path), "staging kept")
        let sentinelBytes = try Data(contentsOf: fix.sentinelURL)

        guard case .completed(let f2) = try finalize(fix) else { return XCTFail() }
        XCTAssertTrue(f2.applyResult.stagingCleaned)
        XCTAssertFalse(fm.fileExists(atPath: fix.gated.stagingDir.path))
        XCTAssertEqual(try Data(contentsOf: fix.sentinelURL), sentinelBytes, "sentinel adopted, not rewritten")
    }

    func testRequiresAcknowledgementThenAckCompletes() throws {
        let fix = try fixture(attachments: [("a.pdf", "A"), ("b.pdf", "B")])
        try fm.removeItem(at: fix.stagedDoc("b.pdf"))   // post-gate loss ⇒ unresolved
        guard case .requiresAcknowledgement(let request, let unresolved) = try finalize(fix) else { return XCTFail() }
        XCTAssertEqual(unresolved.items.map { $0.name }, ["b.pdf"])
        XCTAssertFalse(fm.fileExists(atPath: fix.sentinelURL.path), "nothing persisted")
        XCTAssertTrue(fm.fileExists(atPath: fix.gated.stagingDir.path), "staging kept")

        guard case .completed = try finalize(fix, ack: request.acknowledge()) else { return XCTFail() }
        XCTAssertEqual(try readSentinel(fix).acknowledgedReportHash, request.unresolvedReportHash)
    }

    func testStaleAcknowledgementRejected() throws {
        let fix = try fixture(attachments: [("a.pdf", "A"), ("b.pdf", "B")])
        try fm.removeItem(at: fix.stagedDoc("b.pdf"))
        guard case .requiresAcknowledgement(let req1, _) = try finalize(fix) else { return XCTFail() }
        try fm.removeItem(at: fix.stagedDoc("a.pdf"))   // the unresolved set changes
        let o2 = try finalize(fix, ack: req1.acknowledge())
        guard case .requiresAcknowledgement(let req2, _) = o2 else { return XCTFail("stale ack must be rejected") }
        XCTAssertNotEqual(req2.unresolvedReportHash, req1.unresolvedReportHash)
        guard case .completed = try finalize(fix, ack: req2.acknowledge()) else { return XCTFail() }
    }

    // MARK: - E0 evidence cross-verification

    func testEvidenceMismatchCrossImport() throws {
        let a = try fixture(), b = try fixture()
        XCTAssertThrowsError(try PreparedImportFinalizer().finalize(a.activated, gated: b.gated,
                                                                    activeAttachmentsDir: a.attachmentsDir,
                                                                    manifestsDir: a.manifests)) { e in
            guard case FinalizeError.evidenceMismatch(let f) = e else { return XCTFail("got \(e)") }
            XCTAssertEqual(f, "importID")
            XCTAssertEqual((e as? FinalizeError)?.classification, .terminal)
        }
        XCTAssertFalse(fm.fileExists(atPath: a.sentinelURL.path))
    }

    func testEvidenceMismatchTamperedOwnerRecord() throws {
        let fix = try fixture()
        var rec = try record(fix)
        rec.snapshotIdentitySHA256 = String(rec.snapshotIdentitySHA256.reversed())
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let bytes = try enc.encode(rec)
        let h = try FileHandle(forWritingTo: fix.recordURL)   // in-place, SAME inode
        try h.truncate(atOffset: 0); try h.write(contentsOf: bytes); try h.close()

        XCTAssertThrowsError(try finalize(fix)) { e in
            guard case FinalizeError.evidenceMismatch(let f) = e else { return XCTFail("got \(e)") }
            XCTAssertEqual(f, "record.snapshotIdentitySHA256")
        }
        XCTAssertEqual(try Data(contentsOf: fix.recordURL), bytes, "tampered record never repaired")
    }

    // MARK: - Envelope violations (name swap / same-inode rewrite / record / sidecar)

    func testActiveNameSwappedFailsClosed() throws {
        let fix = try fixture()
        let hooks = FinalizeHooks(afterEntryGate: {
            let aside = fix.activeURL.deletingLastPathComponent().appendingPathComponent("aside.db")
            try self.fm.moveItem(at: fix.activeURL, to: aside)
            try Data("impostor".utf8).write(to: fix.activeURL)
        })
        XCTAssertThrowsError(try finalize(fix, hooks: hooks)) { e in
            guard case FinalizeError.activeEnvelopeViolated = e else { return XCTFail("got \(e)") }
            XCTAssertEqual((e as? FinalizeError)?.classification, .retriable)
        }
        XCTAssertFalse(fm.fileExists(atPath: fix.sentinelURL.path))
        XCTAssertFalse(fm.fileExists(atPath: fix.attachmentsDir.appendingPathComponent("a.pdf").path),
                       "apply never ran")
    }

    func testActiveSameInodeRewriteCaughtBeforeSentinel() throws {
        let fix = try fixture()
        let hooks = FinalizeHooks(afterAudit: {
            let h = try FileHandle(forWritingTo: fix.activeURL)   // same inode
            try h.seekToEnd(); try h.write(contentsOf: Data([0x7F])); try h.close()
        })
        XCTAssertThrowsError(try finalize(fix, hooks: hooks)) { e in
            guard case FinalizeError.activeIdentityMismatch = e else { return XCTFail("got \(e)") }
            XCTAssertEqual((e as? FinalizeError)?.classification, .terminal)
        }
        XCTAssertFalse(fm.fileExists(atPath: fix.sentinelURL.path))
        XCTAssertTrue(fm.fileExists(atPath: fix.gated.stagingDir.path), "staging kept")
    }

    /// Tampering INSIDE the sentinel-publication window (after complete's own identity
    /// recompute, before the exclusive rename) — only the second prePublishGate invocation
    /// (GX′) can catch this; the finalizer's injected bound re-hash must fail closed.
    func testActiveTamperDuringSentinelPublishCaughtByGateRehash() throws {
        let fix = try fixture()
        let hooks = FinalizeHooks(apply: ApplyHooks(onCompletionTempWrite: {
            let h = try FileHandle(forWritingTo: fix.activeURL)   // same inode, mid-publication
            try h.seekToEnd(); try h.write(contentsOf: Data([0x00])); try h.close()
        }))
        XCTAssertThrowsError(try finalize(fix, hooks: hooks)) { e in
            guard case FinalizeError.activeIdentityMismatch = e else { return XCTFail("got \(e)") }
        }
        XCTAssertFalse(fm.fileExists(atPath: fix.sentinelURL.path), "no sentinel for a tampered DB")
    }

    func testOwnerRecordRewrittenMidFinalizeFailsClosed() throws {
        let fix = try fixture()
        var tampered = try record(fix)
        tampered.importID = "someone-else"
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let bytes = try enc.encode(tampered)
        let hooks = FinalizeHooks(afterApply: {
            let h = try FileHandle(forWritingTo: fix.recordURL)   // in-place, SAME inode
            try h.truncate(atOffset: 0); try h.write(contentsOf: bytes); try h.close()
        })
        XCTAssertThrowsError(try finalize(fix, hooks: hooks)) { e in
            guard case FinalizeError.activeEnvelopeViolated = e else { return XCTFail("got \(e)") }
        }
        XCTAssertFalse(fm.fileExists(atPath: fix.sentinelURL.path))
    }

    func testOwnerRecordNameSwappedMidFinalizeFailsClosed() throws {
        let fix = try fixture()
        let hooks = FinalizeHooks(afterApply: {
            let aside = fix.recordURL.deletingLastPathComponent().appendingPathComponent("record-aside.json")
            try self.fm.moveItem(at: fix.recordURL, to: aside)
            try Data("{\"foreign\":true}".utf8).write(to: fix.recordURL)   // different inode
        })
        XCTAssertThrowsError(try finalize(fix, hooks: hooks)) { e in
            guard case FinalizeError.activeEnvelopeViolated = e else { return XCTFail("got \(e)") }
        }
        XCTAssertEqual(try Data(contentsOf: fix.recordURL), Data("{\"foreign\":true}".utf8), "replacement untouched")
    }

    func testSidecarAppearsMidFinalizeFailsClosedThenRecoverable() throws {
        let fix = try fixture()
        let wal = URL(fileURLWithPath: fix.activeURL.path + "-wal")
        let hooks = FinalizeHooks(afterAudit: { try Data("sneaky".utf8).write(to: wal) })
        XCTAssertThrowsError(try finalize(fix, hooks: hooks)) { e in
            guard case FinalizeError.activeEnvelopeViolated = e else { return XCTFail("got \(e)") }
        }
        XCTAssertFalse(fm.fileExists(atPath: fix.sentinelURL.path))
        try fm.removeItem(at: wal)   // operator resolves…
        guard case .completed = try finalize(fix) else { return XCTFail("…then a re-run completes") }
    }

    // MARK: - Staging binding

    func testStagingSwappedBeforeApplyStagingUnbound() throws {
        let fix = try fixture()
        let aside = try trackedTempDir().appendingPathComponent("real-staging-aside", isDirectory: true)
        let hooks = FinalizeHooks(afterEntryGate: {
            try self.fm.moveItem(at: fix.gated.stagingDir, to: aside)
            let docs = fix.gated.stagingDir.appendingPathComponent("attachments", isDirectory: true)
                                            .appendingPathComponent("docs", isDirectory: true)
            try self.fm.createDirectory(at: docs, withIntermediateDirectories: true)
            try Data("VICTIM".utf8).write(to: docs.appendingPathComponent("a.pdf"))
        })
        XCTAssertThrowsError(try finalize(fix, hooks: hooks)) { e in
            guard case FinalizeError.stagingUnbound = e else { return XCTFail("got \(e)") }
            XCTAssertEqual((e as? FinalizeError)?.classification, .retriable)
        }
        XCTAssertEqual(try Data(contentsOf: fix.gated.stagingDir.appendingPathComponent("attachments", isDirectory: true)
                                                                .appendingPathComponent("docs", isDirectory: true)
                                                                .appendingPathComponent("a.pdf")),
                       Data("VICTIM".utf8), "impostor untouched")
        XCTAssertFalse(fm.fileExists(atPath: fix.attachmentsDir.appendingPathComponent("a.pdf").path), "apply never ran")
        try? fm.removeItem(at: fix.gated.stagingDir)   // impostor hygiene
    }

    /// The window only `trustedStagingRoot` protects: staging swapped AFTER the audit
    /// (past the finalizer's apply brackets, before complete). The pre-bound gate root
    /// refuses the impostor — completion stands, cleanup is refused, the impostor keeps
    /// every known-named file.
    func testStagingSwappedAfterAuditRefusedViaTrustedRoot() throws {
        let fix = try fixture()
        let aside = try trackedTempDir().appendingPathComponent("real-staging-aside", isDirectory: true)
        let impostorDocs = fix.gated.stagingDir.appendingPathComponent("attachments", isDirectory: true)
                                               .appendingPathComponent("docs", isDirectory: true)
        let hooks = FinalizeHooks(afterAudit: {
            try self.fm.moveItem(at: fix.gated.stagingDir, to: aside)
            try self.fm.createDirectory(at: impostorDocs, withIntermediateDirectories: true)
            try Data("VICTIM-A".utf8).write(to: impostorDocs.appendingPathComponent("a.pdf"))
            try Data("VICTIM-M".utf8).write(to: fix.gated.stagingDir.appendingPathComponent("manifest.json"))
            try Data("VICTIM-DB".utf8).write(to: fix.gated.stagingDir.appendingPathComponent(AppPaths.databaseFileName))
        })
        let outcome = try finalize(fix, hooks: hooks)
        guard case .completedButCleanupFailed(_, let why) = outcome else { return XCTFail("got \(outcome)") }
        XCTAssertFalse(why.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: fix.sentinelURL.path), "completion stands")
        // Impostor completely untouched — including every known-named file.
        XCTAssertEqual(try Data(contentsOf: impostorDocs.appendingPathComponent("a.pdf")), Data("VICTIM-A".utf8))
        XCTAssertEqual(try Data(contentsOf: fix.gated.stagingDir.appendingPathComponent("manifest.json")), Data("VICTIM-M".utf8))
        XCTAssertEqual(try Data(contentsOf: fix.gated.stagingDir.appendingPathComponent(AppPaths.databaseFileName)), Data("VICTIM-DB".utf8))
        // Nothing deleted from the real moved-aside tree either.
        XCTAssertTrue(fm.fileExists(atPath: aside.appendingPathComponent("manifest.json").path))
        try? fm.removeItem(at: fix.gated.stagingDir)   // impostor hygiene
    }

    // MARK: - Attachments dir binding

    func testAttachmentsDirSwappedMidFinalizeFailsClosed() throws {
        let fix = try fixture()
        let hooks = FinalizeHooks(afterApply: {
            let aside = fix.attachmentsDir.deletingLastPathComponent().appendingPathComponent("docs-aside", isDirectory: true)
            try self.fm.moveItem(at: fix.attachmentsDir, to: aside)
            try self.fm.createDirectory(at: fix.attachmentsDir, withIntermediateDirectories: true)
            try Data("VICTIM".utf8).write(to: fix.attachmentsDir.appendingPathComponent("a.pdf"))
        })
        XCTAssertThrowsError(try finalize(fix, hooks: hooks)) { e in
            guard case FinalizeError.activeEnvelopeViolated = e else { return XCTFail("got \(e)") }
        }
        XCTAssertEqual(try Data(contentsOf: fix.attachmentsDir.appendingPathComponent("a.pdf")),
                       Data("VICTIM".utf8), "replacement untouched")
        XCTAssertFalse(fm.fileExists(atPath: fix.sentinelURL.path))
    }

    // MARK: - Attachment conflicts (terminal, never overwrite)

    func testApplyPlanConflictTerminalNeverOverwrites() throws {
        let fix = try fixture()
        try Data("DIFFERENT".utf8).write(to: fix.attachmentsDir.appendingPathComponent("a.pdf"))
        XCTAssertThrowsError(try finalize(fix)) { e in
            guard case FinalizeError.attachmentConflict = e else { return XCTFail("got \(e)") }
            XCTAssertEqual((e as? FinalizeError)?.classification, .terminal)
        }
        XCTAssertEqual(try Data(contentsOf: fix.attachmentsDir.appendingPathComponent("a.pdf")),
                       Data("DIFFERENT".utf8), "existing attachment never overwritten")
        XCTAssertFalse(fm.fileExists(atPath: fix.sentinelURL.path))
        XCTAssertTrue(fm.fileExists(atPath: fix.gated.stagingDir.path), "staging kept")
    }

    func testApplyRaceConflictNeverOverwrites() throws {
        let fix = try fixture()
        let hooks = FinalizeHooks(apply: ApplyHooks(onAttachmentCopy: { name in
            try Data("DIFFERENT".utf8).write(to: fix.attachmentsDir.appendingPathComponent(name))
        }))
        XCTAssertThrowsError(try finalize(fix, hooks: hooks)) { e in
            guard case FinalizeError.attachmentConflict = e else { return XCTFail("got \(e)") }
        }
        XCTAssertEqual(try Data(contentsOf: fix.attachmentsDir.appendingPathComponent("a.pdf")),
                       Data("DIFFERENT".utf8))
    }

    // MARK: - Audit window

    func testActiveChangedDuringAuditBusy() throws {
        let fix = try fixture()
        let hooks = FinalizeHooks(audit: .init(afterScan: {
            let h = try FileHandle(forWritingTo: fix.activeURL)
            try h.seekToEnd(); try h.write(contentsOf: Data([0x01])); try h.close()
        }))
        XCTAssertThrowsError(try finalize(fix, hooks: hooks)) { e in
            guard case FinalizeError.activeDatabaseBusy = e else { return XCTFail("got \(e)") }
            XCTAssertEqual((e as? FinalizeError)?.classification, .retriable)
        }
        XCTAssertFalse(fm.fileExists(atPath: fix.sentinelURL.path))
    }

    // MARK: - Sentinel machinery through the finalizer

    func testSentinelDirBarrierFailureThenRerunConverges() throws {
        let fix = try fixture()
        let failing = FinalizeHooks(apply: ApplyHooks(onSentinelSync: { p in
            if p == .sentinelDirEntry { throw Crash() }
        }))
        XCTAssertThrowsError(try finalize(fix, hooks: failing)) { e in
            guard case FinalizeError.sentinelDurabilityFailed(.sentinelDirEntry, _) = e else { return XCTFail("got \(e)") }
            XCTAssertEqual((e as? FinalizeError)?.classification, .retriable)
        }
        XCTAssertTrue(fm.fileExists(atPath: fix.sentinelURL.path), "sentinel IS published")
        XCTAssertTrue(fm.fileExists(atPath: fix.gated.stagingDir.path), "staging survives a barrier failure")
        guard case .completed = try finalize(fix) else { return XCTFail() }
        XCTAssertFalse(fm.fileExists(atPath: fix.gated.stagingDir.path))
    }

    func testForeignSentinelConflict() throws {
        let fix = try fixture()
        let foreign = Data("{\"foreign\":true}".utf8)
        try foreign.write(to: fix.sentinelURL)
        XCTAssertThrowsError(try finalize(fix)) { e in
            guard case FinalizeError.sentinelConflict = e else { return XCTFail("got \(e)") }
            XCTAssertEqual((e as? FinalizeError)?.classification, .terminal)
        }
        XCTAssertEqual(try Data(contentsOf: fix.sentinelURL), foreign, "foreign sentinel untouched")
        XCTAssertTrue(fm.fileExists(atPath: fix.gated.stagingDir.path), "staging kept")
    }

    // MARK: - Crash / rerun convergence at every boundary

    func testCrashAtEachBoundaryThenRerunConverges() throws {
        let seams: [(String, FinalizeHooks)] = [
            ("afterEntryGate", FinalizeHooks(afterEntryGate: { throw Crash() })),
            ("afterApply", FinalizeHooks(afterApply: { throw Crash() })),
            ("afterAudit", FinalizeHooks(afterAudit: { throw Crash() })),
            ("onCompletionTempWrite", FinalizeHooks(apply: ApplyHooks(onCompletionTempWrite: { throw Crash() }))),
            ("onCompletionPublish", FinalizeHooks(apply: ApplyHooks(onCompletionPublish: { throw Crash() }))),
            ("afterSentinelPublished", FinalizeHooks(apply: ApplyHooks(afterSentinelPublished: { _ in throw Crash() }))),
        ]
        for (label, hooks) in seams {
            let fix = try fixture()
            XCTAssertThrowsError(try finalize(fix, hooks: hooks), label)
            guard case .completed = try finalize(fix) else { return XCTFail("\(label): rerun must converge") }
            // Attachments applied exactly once, bytes exact; sentinel valid; staging gone.
            XCTAssertEqual(try Data(contentsOf: fix.attachmentsDir.appendingPathComponent("a.pdf")),
                           Data("A".utf8), label)
            let names = try fm.contentsOfDirectory(atPath: fix.attachmentsDir.path)
            XCTAssertEqual(names.sorted(), ["a.pdf"], "\(label): no duplicates / leftovers")
            XCTAssertNil(PreparedImportFinalizer.validateCompletedSentinel(try readSentinel(fix),
                                                                           record: try record(fix),
                                                                           importID: fix.gated.importID), label)
            XCTAssertFalse(fm.fileExists(atPath: fix.gated.stagingDir.path), label)
        }
    }

    // MARK: - Completion probe

    func testProbePendingBeforeFinalize() throws {
        let fix = try fixture()
        XCTAssertEqual(try probe(fix), .pending)
        // A nonexistent manifests dir is also pending, never an error.
        let ghost = try trackedTempDir().appendingPathComponent("no-such-manifests", isDirectory: true)
        XCTAssertEqual(try PreparedImportFinalizer.probeCompletion(expected: try record(fix),
                                                                   importID: fix.gated.importID,
                                                                   manifestsDir: ghost), .pending)
    }

    func testProbeCompletedAndCleanupPending() throws {
        let fix = try fixture()
        let o1 = try finalize(fix, hooks: FinalizeHooks(apply: ApplyHooks(cleanup: { _ in throw Crash() })))
        guard case .completedButCleanupFailed = o1 else { return XCTFail() }
        guard case .cleanupPending(let v1) = try probe(fix, stagingDir: fix.gated.stagingDir) else { return XCTFail() }
        XCTAssertEqual(v1.sentinelURL, fix.sentinelURL)
        XCTAssertEqual(v1.manifest, try readSentinel(fix), "probe carries the bound-verified manifest")

        guard case .completed = try finalize(fix) else { return XCTFail() }
        guard case .completed(let v2) = try probe(fix, stagingDir: fix.gated.stagingDir) else { return XCTFail() }
        XCTAssertEqual(v2.sentinelURL, fix.sentinelURL)
    }

    func testProbeConflictOnInvariantViolations() throws {
        let mutations: [(String, (inout ImportManifest) -> Void)] = [
            ("status .ingested", { $0.status = .ingested }),
            ("ack hash violation", { $0.acknowledgedReportHash = "bogus" }),
            ("attachment set tamper", { $0.files[0].name = "ghost.pdf" }),
            ("snapshot identity flip", { $0.snapshotIdentitySHA256 = String($0.snapshotIdentitySHA256.reversed()) }),
            ("audit flag dropped", { $0.referenceAuditPerformed = nil }),
            ("applied dropped", { $0.applied = nil }),
        ]
        for (label, mutate) in mutations {
            let fix = try fixture()
            guard case .completed = try finalize(fix) else { return XCTFail(label) }
            var s = try readSentinel(fix); mutate(&s); try writeSentinel(s, fix)
            guard case .conflict = try probe(fix) else { return XCTFail("\(label): expected .conflict") }
        }
    }

    /// After completion the store opens and the active DB becomes WAL (sidecars appear).
    /// The probe must still answer from the sentinel alone — it never recomputes DB
    /// identity/quiescence (which would now fail forever).
    func testProbeSafeOnWALActiveDB() throws {
        let fix = try fixture()
        guard case .completed = try finalize(fix) else { return XCTFail() }
        let store = try LedgerStore(databaseURL: fix.activeURL)   // WAL mode from here on
        _ = try store.summary()
        guard case .completed(let v) = try probe(fix) else { return XCTFail() }
        XCTAssertEqual(v.sentinelURL, fix.sentinelURL)
    }

    func testProbeReplaysBarriersAndRetriesAfterFailure() throws {
        let fix = try fixture()
        guard case .completed = try finalize(fix) else { return XCTFail() }
        var seq: [SentinelSyncPoint] = []
        guard case .completed = try probe(fix, hooks: ApplyHooks(onSentinelSync: { seq.append($0) })) else { return XCTFail() }
        XCTAssertEqual(seq, [.sentinelFile, .sentinelDirEntry], "probe replays both barriers")

        XCTAssertThrowsError(try probe(fix, hooks: ApplyHooks(onSentinelSync: { p in
            if p == .sentinelDirEntry { throw Crash() }
        }))) { e in
            guard case FinalizeError.sentinelDurabilityFailed(.sentinelDirEntry, _) = e else { return XCTFail("got \(e)") }
        }
        guard case .completed = try probe(fix) else { return XCTFail("re-probe converges") }
    }

    // MARK: - Security-review fixes: entry envelope before probe; barrier-replay content re-verify

    /// A VALID sentinel with cleanup residue must not shortcut past a violated active slot:
    /// swapping the active inode, swapping the owner-record name, or planting a sidecar all
    /// fail closed at the entry envelope BEFORE any probe — staging retained, no completed.
    func testCompletedResidueActiveTamperFailsClosedBeforeProbe() throws {
        // (a) active inode swapped
        do {
            let fix = try fixture()
            guard case .completedButCleanupFailed = try finalize(fix, hooks: FinalizeHooks(apply: ApplyHooks(cleanup: { _ in throw Crash() }))) else { return XCTFail() }
            let aside = fix.activeURL.deletingLastPathComponent().appendingPathComponent("aside.db")
            try fm.moveItem(at: fix.activeURL, to: aside)
            try Data("impostor".utf8).write(to: fix.activeURL)
            XCTAssertThrowsError(try finalize(fix)) { e in
                guard case FinalizeError.activeEnvelopeViolated(let stage, _) = e else { return XCTFail("got \(e)") }
                XCTAssertEqual(stage, .entry)
            }
            XCTAssertTrue(fm.fileExists(atPath: fix.gated.stagingDir.path), "staging retained")
        }
        // (b) owner-record name swapped
        do {
            let fix = try fixture()
            guard case .completedButCleanupFailed = try finalize(fix, hooks: FinalizeHooks(apply: ApplyHooks(cleanup: { _ in throw Crash() }))) else { return XCTFail() }
            let aside = fix.recordURL.deletingLastPathComponent().appendingPathComponent("record-aside.json")
            try fm.moveItem(at: fix.recordURL, to: aside)
            try Data("{}".utf8).write(to: fix.recordURL)
            XCTAssertThrowsError(try finalize(fix)) { e in
                guard case FinalizeError.activeEnvelopeViolated(let stage, _) = e else { return XCTFail("got \(e)") }
                XCTAssertEqual(stage, .entry)
            }
            XCTAssertTrue(fm.fileExists(atPath: fix.gated.stagingDir.path), "staging retained")
        }
        // (c) sidecar planted — then removed, the re-run converges via the short-circuit
        do {
            let fix = try fixture()
            guard case .completedButCleanupFailed = try finalize(fix, hooks: FinalizeHooks(apply: ApplyHooks(cleanup: { _ in throw Crash() }))) else { return XCTFail() }
            let wal = URL(fileURLWithPath: fix.activeURL.path + "-wal")
            try Data("w".utf8).write(to: wal)
            XCTAssertThrowsError(try finalize(fix)) { e in
                guard case FinalizeError.activeEnvelopeViolated(let stage, _) = e else { return XCTFail("got \(e)") }
                XCTAssertEqual(stage, .entry)
            }
            XCTAssertTrue(fm.fileExists(atPath: fix.gated.stagingDir.path), "staging retained")
            try fm.removeItem(at: wal)
            guard case .completed = try finalize(fix) else { return XCTFail("converges after the sidecar is resolved") }
            XCTAssertFalse(fm.fileExists(atPath: fix.gated.stagingDir.path))
        }
    }

    /// Same-inode rewrites of the sentinel INSIDE each barrier-replay seam — both to
    /// undecodable bytes and to a syntactically valid but semantically different manifest —
    /// must never probe as completed.
    func testProbeBarrierSeamSameInodeTamperNotCompleted() throws {
        let fix = try fixture()
        guard case .completed = try finalize(fix) else { return XCTFail() }
        let original = try Data(contentsOf: fix.sentinelURL)
        var different = try readSentinel(fix)
        different.report = "tampered-history"
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let differentBytes = try enc.encode(different)
        func rewriteSameInode(_ data: Data) throws {
            let h = try FileHandle(forWritingTo: fix.sentinelURL)
            try h.truncate(atOffset: 0); try h.write(contentsOf: data); try h.close()
        }
        for seam in [SentinelSyncPoint.sentinelFile, .sentinelDirEntry] {
            for (label, payload) in [("undecodable", Data("not json {".utf8)), ("semantically-different", differentBytes)] {
                let outcome = try probe(fix, hooks: ApplyHooks(onSentinelSync: { p in
                    guard p == seam else { return }
                    try rewriteSameInode(payload)
                }))
                guard case .conflict = outcome else { return XCTFail("\(seam.rawValue)/\(label): got \(outcome)") }
                try rewriteSameInode(original)   // restore for the next combo
            }
        }
        // Tamper at the FILE seam, restore at the DIR seam: only the after-file-barrier
        // content re-verify can observe this — the file barrier momentarily made WRONG
        // bytes durable, which must never probe as completed.
        let flicker = try probe(fix, hooks: ApplyHooks(onSentinelSync: { p in
            if p == .sentinelFile { try rewriteSameInode(differentBytes) }
            if p == .sentinelDirEntry { try rewriteSameInode(original) }
        }))
        guard case .conflict = flicker else { return XCTFail("tamper-then-restore: got \(flicker)") }
        try rewriteSameInode(original)
        guard case .completed = try probe(fix) else { return XCTFail("restored sentinel probes completed") }
    }

    /// `shortCircuitResult` is a PURE function over `ValidatedCompletion`: with a
    /// sentinelURL pointing at a nonexistent path, and at a foreign file whose content is a
    /// decodable but different manifest, the result must still come from
    /// `validated.manifest` — proving there is no `Data(contentsOf:)` re-read path. The
    /// sentinelURL is never read for expectations.
    func testShortCircuitResultIsPureOverValidatedManifest() throws {
        let fix = try fixture()
        guard case .completed = try finalize(fix) else { return XCTFail() }
        var m = try readSentinel(fix)   // a REAL completed manifest (read from fix.sentinelURL, not the ghost URLs)
        m.applied = .init(copied: ["from-validated.pdf"], skippedIdentical: [], missing: [])

        // (a) nonexistent path — any URL re-read would fail/fall back.
        let ghostURL = try trackedTempDir().appendingPathComponent("no-such-dir", isDirectory: true)
            .appendingPathComponent("no-such-sentinel.json")
        let v1 = PreparedImportFinalizer.ValidatedCompletion(sentinelURL: ghostURL, manifest: m)
        let f1 = PreparedImportFinalizer.shortCircuitResult(activated: fix.activated, validated: v1,
                                                            stagingCleaned: true, cleanupError: nil)
        XCTAssertEqual(f1.applyResult.applied.copied, ["from-validated.pdf"])
        XCTAssertEqual(f1.applyResult.completionSentinelURL, ghostURL)
        XCTAssertFalse(fm.fileExists(atPath: ghostURL.path), "the URL was never created")

        // (b) foreign path holding a DECODABLE but different manifest — a URL re-read
        // would yield "ghost.pdf"; the pure function must yield the validated history.
        var ghost = m
        ghost.applied = .init(copied: ["ghost.pdf"], skippedIdentical: [], missing: [])
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let foreignURL = try trackedTempDir().appendingPathComponent("foreign-sentinel.json")
        try enc.encode(ghost).write(to: foreignURL)
        let v2 = PreparedImportFinalizer.ValidatedCompletion(sentinelURL: foreignURL, manifest: m)
        let f2 = PreparedImportFinalizer.shortCircuitResult(activated: fix.activated, validated: v2,
                                                            stagingCleaned: false, cleanupError: "residue")
        XCTAssertEqual(f2.applyResult.applied.copied, ["from-validated.pdf"],
                       "result must come from validated.manifest, never the URL's bytes")
        XCTAssertEqual(f2.applyResult.stagingCleanupError, "residue")
    }

    /// With the active slot violated, the finalizer must fail closed BEFORE interpreting
    /// ANY sentinel state: a foreign sentinel alongside a tampered slot must be reported as
    /// the (retriable) slot violation — never as a (terminal) sentinelConflict that would
    /// misdirect the operator while the slot itself is the problem.
    func testViolatedSlotReportedBeforeSentinelConflict() throws {
        let fix = try fixture()
        guard case .completedButCleanupFailed = try finalize(fix, hooks: FinalizeHooks(apply: ApplyHooks(cleanup: { _ in throw Crash() }))) else { return XCTFail() }
        try Data("{\"foreign\":true}".utf8).write(to: fix.sentinelURL)   // sentinel becomes foreign
        let aside = fix.activeURL.deletingLastPathComponent().appendingPathComponent("aside.db")
        try fm.moveItem(at: fix.activeURL, to: aside)                    // AND the slot is violated
        try Data("impostor".utf8).write(to: fix.activeURL)
        XCTAssertThrowsError(try finalize(fix)) { e in
            guard case FinalizeError.activeEnvelopeViolated(let stage, _) = e else {
                return XCTFail("the slot violation must be reported before any sentinel interpretation — got \(e)")
            }
            XCTAssertEqual(stage, .entry)
        }
        XCTAssertTrue(fm.fileExists(atPath: fix.gated.stagingDir.path), "staging retained")
    }

    /// The probe's barrier-replay seams run arbitrary code — an active-slot tamper there
    /// (active inode swap / owner-record name swap / sidecar plant) must be caught by the
    /// finalizer's EXIT envelope after the probe returns: no cleanup, no completed, staging
    /// retained. The probe itself may finish its replay (it never inspects the DB slot).
    func testProbeSeamActiveTamperCaughtByFinalizerExitEnvelope() throws {
        for seam in [SentinelSyncPoint.sentinelFile, .sentinelDirEntry] {
            for kind in ["active-swap", "record-swap", "sidecar"] {
                let fix = try fixture()
                guard case .completedButCleanupFailed = try finalize(fix, hooks: FinalizeHooks(apply: ApplyHooks(cleanup: { _ in throw Crash() }))) else { return XCTFail("\(seam.rawValue)/\(kind)") }
                var fired = false
                let hooks = FinalizeHooks(apply: ApplyHooks(onSentinelSync: { p in
                    guard p == seam, !fired else { return }
                    fired = true
                    switch kind {
                    case "active-swap":
                        let aside = fix.activeURL.deletingLastPathComponent().appendingPathComponent("aside.db")
                        try self.fm.moveItem(at: fix.activeURL, to: aside)
                        try Data("impostor".utf8).write(to: fix.activeURL)
                    case "record-swap":
                        let aside = fix.recordURL.deletingLastPathComponent().appendingPathComponent("rec-aside.json")
                        try self.fm.moveItem(at: fix.recordURL, to: aside)
                        try Data("{}".utf8).write(to: fix.recordURL)
                    default:
                        try Data("w".utf8).write(to: URL(fileURLWithPath: fix.activeURL.path + "-wal"))
                    }
                }))
                XCTAssertThrowsError(try finalize(fix, hooks: hooks), "\(seam.rawValue)/\(kind)") { e in
                    guard case FinalizeError.activeEnvelopeViolated(let stage, _) = e else {
                        return XCTFail("\(seam.rawValue)/\(kind): got \(e)")
                    }
                    XCTAssertEqual(stage, .entry, "\(seam.rawValue)/\(kind)")
                }
                XCTAssertTrue(fm.fileExists(atPath: fix.gated.stagingDir.path), "\(seam.rawValue)/\(kind): staging retained")
            }
        }
    }

    /// A non-ENOENT metadata failure probing the staging residue must fail closed as
    /// cleanup-pending — never reported as completed/cleaned.
    func testProbeStagingMetadataErrorFailsClosed() throws {
        let fix = try fixture()
        guard case .completed = try finalize(fix) else { return XCTFail() }
        let guarded = try trackedTempDir().appendingPathComponent("guarded", isDirectory: true)
        try fm.createDirectory(at: guarded, withIntermediateDirectories: true)
        let blocked = guarded.appendingPathComponent("staging-probe")
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: guarded.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: guarded.path) }
        let outcome = try probe(fix, stagingDir: blocked)
        guard case .cleanupPending = outcome else { return XCTFail("metadata error must fail closed, got \(outcome)") }
    }

    /// Duplicate entries in files / applied / unresolved must each make the probe conflict —
    /// the set-based invariants must never be satisfied through silent Set deduplication.
    func testProbeConflictOnDuplicateEntries() throws {
        // (a) applied.copied duplicates — reachable with the REAL owner record.
        do {
            let fix = try fixture()
            guard case .completed = try finalize(fix) else { return XCTFail() }
            var s = try readSentinel(fix)
            s.applied = .init(copied: ["a.pdf", "a.pdf"], skippedIdentical: [], missing: [])
            try writeSentinel(s, fix)
            guard case .conflict(let why) = try probe(fix) else { return XCTFail("applied dup must conflict") }
            XCTAssertTrue(why.contains("duplicates"), why)
        }
        // (b) files duplicates — the identity hashes pin the real record, so a crafted
        // expected record proves the duplicate invariant fires on its own.
        do {
            let fix = try fixture()
            guard case .completed = try finalize(fix) else { return XCTFail() }
            var s = try readSentinel(fix)
            s.files.append(s.files[0])
            s.attachmentManifestSHA256 = ImportManifest.attachmentSetHash(s.files)
            try writeSentinel(s, fix)
            var rec = try record(fix)
            rec.attachmentManifestSHA256 = s.attachmentManifestSHA256
            let outcome = try PreparedImportFinalizer.probeCompletion(expected: rec, importID: fix.gated.importID,
                                                                      manifestsDir: fix.manifests)
            guard case .conflict(let why) = outcome else { return XCTFail("files dup must conflict") }
            XCTAssertTrue(why.contains("duplicate name"), why)
        }
        // (c) duplicate missingStagedFile items in unresolved (ack re-bound to keep ⑨ green).
        do {
            let fix = try fixture(attachments: [("a.pdf", "A"), ("b.pdf", "B")])
            try fm.removeItem(at: fix.stagedDoc("b.pdf"))
            guard case .requiresAcknowledgement(let req, _) = try finalize(fix) else { return XCTFail() }
            guard case .completed = try finalize(fix, ack: req.acknowledge()) else { return XCTFail() }
            var s = try readSentinel(fix)
            let dup = UnresolvedReport.Item(name: "b.pdf", kind: .missingStagedFile)
            s.unresolved = UnresolvedReport(items: (s.unresolved?.items ?? []) + [dup])
            s.acknowledgedReportHash = s.unresolved?.reportHash
            try writeSentinel(s, fix)
            guard case .conflict(let why) = try probe(fix) else { return XCTFail("unresolved dup must conflict") }
            XCTAssertTrue(why.contains("duplicate missingStagedFile"), why)
        }
    }

    // MARK: - Error classification table

    func testErrorClassificationTable() {
        // The dictated mappings that must never drift.
        XCTAssertEqual(FinalizeError.map(AttachmentApplyError.activeFileHashMismatch("x"), stage: .complete),
                       .attachmentConflict("active attachment content mismatch: x"))
        XCTAssertEqual(FinalizeError.map(AttachmentApplyError.activeFileHashMismatch("x"), stage: .complete).classification,
                       .terminal, "activeFileHashMismatch must be terminal")
        XCTAssertEqual(FinalizeError.map(AttachmentApplyError.referencedFileChangedSinceAudit("x"), stage: .complete),
                       .referencedFileChangedSinceAudit("x"))
        XCTAssertEqual(FinalizeError.referencedFileChangedSinceAudit("x").classification, .retriable)
        XCTAssertEqual(FinalizeError.map(AttachmentApplyError.referenceAuditMismatch(field: "importID"), stage: .complete),
                       .evidenceMismatch(field: "referenceAudit.importID"))
        XCTAssertEqual(FinalizeError.map(AttachmentApplyError.conflicts([]), stage: .apply).classification, .terminal)
        XCTAssertEqual(FinalizeError.map(AttachmentApplyError.sentinelIdentityMismatch("id"), stage: .complete),
                       .sentinelConflict("id"))
        XCTAssertEqual(FinalizeError.map(AttachmentApplyError.preparedDatabaseChangedDuringAudit(before: "a", after: "b"),
                                         stage: .audit).classification, .retriable)
        XCTAssertEqual(FinalizeError.map(PreparedDatabaseError.wrongJournalMode("wal"), stage: .complete).classification,
                       .terminal, "store opened before completion is terminal")
        XCTAssertEqual(FinalizeError.map(PreparedDatabaseError.notQuiescent(sidecar: "s"), stage: .complete).classification,
                       .retriable)
        XCTAssertEqual(FinalizeError.map(AttachmentApplyError.stagedFileHashMismatch("x"), stage: .apply).classification,
                       .terminal)
        XCTAssertEqual(FinalizeError.map(Crash(), stage: .apply).classification, .retriable, "unknown errors → transientIO")
    }
}
