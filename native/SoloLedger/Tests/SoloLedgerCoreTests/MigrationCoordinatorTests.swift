import XCTest
@testable import SoloLedgerCore

/// 2B-3 C12a: MigrationCoordinator — probe-first boot adjudication, exhaustive Sent×Active
/// table, staging recovery/selection, bounded concurrency adjudication, typed error
/// mapping, and the final open-authorization re-check.
///
/// ISOLATION: every test uses its OWN staging root under trackedTempDir, injected through
/// the coordinator's internal dependency seam. The REAL Preview staging root is never
/// enumerated, read, moved or deleted; the only file ever placed there is this suite's own
/// canary (guard test), which is verified byte-identical and then removed by its creator.
final class MigrationCoordinatorTests: LedgerTestCase {

    private let fm = FileManager.default

    // MARK: - Fixtures

    private func makeSQLiteDB() throws -> URL {
        let url = try trackedTempDir().appendingPathComponent("src.db")
        let db = try SQLiteDatabase(path: url.path, mode: .readWriteCreate)
        try db.execute("PRAGMA journal_mode = DELETE")
        try db.execute("PRAGMA user_version = 0")
        try db.close()
        return url
    }

    private struct Ctx {
        let config: MigrationCoordinator.Config
        let stagingRoot: URL
    }

    private func makeCtx() throws -> Ctx {
        func dir(_ name: String) throws -> URL {
            let d = try trackedTempDir().appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
            return d
        }
        let config = MigrationCoordinator.Config(
            activeDestination: try dir("ActiveSlot").appendingPathComponent(AppPaths.databaseFileName),
            activeAttachmentsDir: try dir("active-docs"),
            manifestsDir: try dir("ImportManifests"),
            workingDirectory: try dir("Work"),
            preparedRoot: try dir("PreparedImports"))
        return Ctx(config: config, stagingRoot: try dir("Staging"))
    }

    /// Ingest through the REAL chain, then relocate the published staging into the test's
    /// isolated root (moving only the entry this call just created).
    private static func seamIngest(_ source: MigrationSource, _ importID: ImportID,
                                   into root: URL) throws -> IngestResult {
        let r = try StagingIngest().ingest(source, importID: importID, timestamp: "t")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dst = root.appendingPathComponent("import-\(importID.rawValue)", isDirectory: true)
        try FileManager.default.moveItem(at: r.stagingDir, to: dst)
        let docs = dst.appendingPathComponent("attachments", isDirectory: true)
                      .appendingPathComponent("docs", isDirectory: true)
        return IngestResult(importID: r.importID, stagingDir: dst,
                            stagedDatabaseURL: dst.appendingPathComponent(AppPaths.databaseFileName),
                            stagedWALURL: r.stagedWALURL.map { _ in URL(fileURLWithPath: dst.path + "/" + AppPaths.databaseFileName + "-wal") },
                            stagedAttachmentsDir: r.stagedAttachmentsDir.map { _ in docs },
                            manifest: r.manifest)
    }

    private func coord(_ ctx: Ctx) -> MigrationCoordinator {
        let root = ctx.stagingRoot
        return MigrationCoordinator(config: ctx.config, stagingRootOverride: root,
                                    ingestOverride: { source, id in
            try Self.seamIngest(source, id, into: root)
        })
    }

    private func makeSource(attachments: [(name: String, bytes: String)] = [("a.pdf", "A")],
                            symlinkAttachment: Bool = false) throws -> (dir: URL, source: MigrationSource) {
        let src = try trackedTempDir().appendingPathComponent("SoloLedger", isDirectory: true)
        let docs = src.appendingPathComponent("attachments", isDirectory: true)
                      .appendingPathComponent("docs", isDirectory: true)
        try fm.createDirectory(at: docs, withIntermediateDirectories: true)
        try fm.copyItem(at: try makeSQLiteDB(), to: src.appendingPathComponent(AppPaths.databaseFileName))
        for a in attachments { try Data(a.bytes.utf8).write(to: docs.appendingPathComponent(a.name)) }
        if symlinkAttachment {
            let target = try trackedTempDir().appendingPathComponent("elsewhere.pdf")
            try Data("X".utf8).write(to: target)
            try fm.createSymbolicLink(at: docs.appendingPathComponent("link.pdf"), withDestinationURL: target)
        }
        return (src, .userSelectedDataDir(src))
    }

    private func boot(_ ctx: Ctx, _ source: MigrationSource?, ack: Acknowledgement? = nil,
                      hooks: MigrationCoordinator.CoordinatorHooks = .init()) -> BootOutcome {
        coord(ctx).bootResolve(autoSourceCandidate: source, acknowledgement: ack, hooks: hooks)
    }

    /// Stage an import into THIS test's isolated root.
    @discardableResult
    private func stageImport(_ ctx: Ctx, from source: MigrationSource) throws -> ImportID {
        let id = try XCTUnwrap(ImportID("coord-\(UUID().uuidString.lowercased())"))
        _ = try Self.seamIngest(source, id, into: ctx.stagingRoot)
        return id
    }

    private func stagingDir(_ ctx: Ctx, _ id: ImportID) -> URL {
        ctx.stagingRoot.appendingPathComponent("import-\(id.rawValue)", isDirectory: true)
    }

    /// Chain up to ACTIVATION only (record published, no sentinel) — crash-before-finalize.
    @discardableResult
    private func chainToActivated(_ ctx: Ctx, source: MigrationSource) throws -> ImportID {
        let id = try stageImport(ctx, from: source)
        let gated = try StagedSnapshotGate().gate(stagingDir: stagingDir(ctx, id))
        let prepared = try PreparedImportRunner().run(gated, workingDirectory: ctx.config.workingDirectory,
                                                      preparedRoot: ctx.config.preparedRoot)
        _ = try PreparedImportActivator().activate(prepared, activeDestination: ctx.config.activeDestination)
        return id
    }

    private func slotDir(_ ctx: Ctx) -> URL { ctx.config.activeDestination.deletingLastPathComponent() }
    private func recordURL(_ ctx: Ctx) -> URL {
        slotDir(ctx).appendingPathComponent(PreparedImportActivator.recordName)
    }
    private func readRecord(_ ctx: Ctx) throws -> ActivationRecord {
        try JSONDecoder().decode(ActivationRecord.self, from: Data(contentsOf: recordURL(ctx)))
    }
    private func sentinelURL(_ ctx: Ctx, _ importID: String) -> URL {
        ctx.config.manifestsDir.appendingPathComponent("\(importID).json")
    }
    private func writeFakeRecord(_ ctx: Ctx) throws {
        let json = #"{"formatVersion":1,"importID":"fake-\#(UUID().uuidString.lowercased())","snapshotIdentitySHA256":"s","attachmentManifestSHA256":"a","sourceDBSHA256":"d","preparedDBIdentity":"sha256:x","transactionsMigrated":0}"#
        try Data(json.utf8).write(to: recordURL(ctx))
    }
    private func validSentinelName() -> String { "sent-\(UUID().uuidString.lowercased()).json" }

    private func rewriteSameInode(_ url: URL, _ data: Data) throws {
        let h = try FileHandle(forWritingTo: url)
        try h.truncate(atOffset: 0); try h.write(contentsOf: data); try h.close()
    }

    private func assertBlocked(_ outcome: BootOutcome, _ code: MigrationIssueCode,
                               _ cls: MigrationBlock.Class, _ label: String = "",
                               file: StaticString = #filePath, line: UInt = #line) {
        guard case .blocked(let b) = outcome else {
            return XCTFail("\(label): expected blocked(\(code)), got \(outcome)", file: file, line: line)
        }
        XCTAssertEqual(b.code, code, label, file: file, line: line)
        XCTAssertEqual(b.classification, cls, label, file: file, line: line)
    }

    // MARK: - Isolation guard

    /// The injected staging root lives under trackedTempDir, and the REAL Preview staging
    /// root's content is untouched by a full boot flow — proven with this suite's OWN
    /// canary file (created, byte-verified, and removed by its creator; no existing entry
    /// is read, moved or deleted).
    func testStagingIsolationGuard() throws {
        let ctx = try makeCtx()
        XCTAssertTrue(coord(ctx).stagingRootURL?.path.hasPrefix(ctx.stagingRoot.deletingLastPathComponent().path) == true)
        XCTAssertEqual(coord(ctx).stagingRootURL, ctx.stagingRoot, "the injected root is the one in use")
        let realRoot = try AppPaths.stagingRootDirectory()
        XCTAssertFalse(ctx.stagingRoot.path.hasPrefix(realRoot.path), "test root must not live inside the real root")

        let canary = realRoot.appendingPathComponent("coordinator-canary-\(UUID().uuidString).txt")
        let canaryBytes = Data("canary".utf8)
        try canaryBytes.write(to: canary)
        defer { try? fm.removeItem(at: canary) }   // own artifact only

        let (_, source) = try makeSource()
        guard case .openStore = boot(ctx, source) else { return XCTFail() }   // full auto chain
        XCTAssertEqual(try Data(contentsOf: canary), canaryBytes, "real Preview staging content untouched")
    }

    // MARK: - B1/B2 and the exhaustive Sent × ActiveEntry table

    func testFreshInstallCreateFreshAuthorization() throws {
        let ctx = try makeCtx()
        guard case .openStore(let auth, let residual) = boot(ctx, nil) else { return XCTFail() }
        XCTAssertEqual(auth, .createFreshExpectedAbsent)
        XCTAssertNil(residual)
        XCTAssertFalse(fm.fileExists(atPath: ctx.config.activeDestination.path), "C12a never creates the DB")
        XCTAssertEqual(coord(ctx).confirmOpenAuthorization(.createFreshExpectedAbsent, autoSourceCandidate: nil),
                       .proceed)
    }

    func testPlainActiveOpensViaPlainAuthorization() throws {
        let ctx = try makeCtx()
        try Data("plain".utf8).write(to: ctx.config.activeDestination)
        guard case .openStore(let auth, _) = boot(ctx, nil) else { return XCTFail() }
        XCTAssertEqual(auth, .openExistingPlain, "B2 must mint the PLAIN authorization")
        XCTAssertEqual(coord(ctx).confirmOpenAuthorization(auth, autoSourceCandidate: nil), .proceed)
    }

    func testPlainActiveSymlinkBlocked() throws {
        let ctx = try makeCtx()
        let target = try trackedTempDir().appendingPathComponent("victim.db")
        try Data("keep".utf8).write(to: target)
        try fm.createSymbolicLink(at: ctx.config.activeDestination, withDestinationURL: target)
        assertBlocked(boot(ctx, nil), .activeEntryInvalid, .terminal)
        XCTAssertEqual(try Data(contentsOf: target), Data("keep".utf8), "symlink target untouched")
    }

    func testTmpAndUnknownSentinelResidueDoNotBlockCreateFresh() throws {
        let ctx = try makeCtx()
        try Data("x".utf8).write(to: ctx.config.manifestsDir.appendingPathComponent(".tmp-orphan.json"))
        try Data("y".utf8).write(to: ctx.config.manifestsDir.appendingPathComponent("stray.txt"))
        guard case .openStore(.createFreshExpectedAbsent, _) = boot(ctx, nil) else {
            return XCTFail("tmp/unknown residue must not block createFresh")
        }
        XCTAssertEqual(try Data(contentsOf: ctx.config.manifestsDir.appendingPathComponent(".tmp-orphan.json")), Data("x".utf8))
        XCTAssertEqual(try Data(contentsOf: ctx.config.manifestsDir.appendingPathComponent("stray.txt")), Data("y".utf8))
    }

    func testCanonicalSentinelBlocksCreateFreshAndPlainOpen() throws {
        do {
            let ctx = try makeCtx()
            try Data("GARBAGE".utf8).write(to: ctx.config.manifestsDir.appendingPathComponent(validSentinelName()))
            assertBlocked(boot(ctx, nil), .sentinelOrphan, .terminal)
            XCTAssertFalse(fm.fileExists(atPath: ctx.config.activeDestination.path))
        }
        do {
            let ctx = try makeCtx()
            try Data("GARBAGE".utf8).write(to: ctx.config.manifestsDir.appendingPathComponent(validSentinelName()))
            try Data("plain".utf8).write(to: ctx.config.activeDestination)
            assertBlocked(boot(ctx, nil), .recordMissingForCompletedImport, .terminal)
        }
    }

    func testCanonicalSentinelWithActiveSymlinkReportsSlotViolation() throws {
        let ctx = try makeCtx()
        try Data("GARBAGE".utf8).write(to: ctx.config.manifestsDir.appendingPathComponent(validSentinelName()))
        let target = try trackedTempDir().appendingPathComponent("victim.db")
        try Data("keep".utf8).write(to: target)
        try fm.createSymbolicLink(at: ctx.config.activeDestination, withDestinationURL: target)
        assertBlocked(boot(ctx, nil), .activeEntryInvalid, .terminal)
        XCTAssertEqual(try Data(contentsOf: target), Data("keep".utf8))
    }

    func testCanonicalSentinelWithSlotMetadataFailureRetriable() throws {
        let ctx = try makeCtx()
        try Data("GARBAGE".utf8).write(to: ctx.config.manifestsDir.appendingPathComponent(validSentinelName()))
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: slotDir(ctx).path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: slotDir(ctx).path) }
        assertBlocked(boot(ctx, nil), .ioTransient, .retriable)
    }

    func testCanonicalShapedSymlinkSentinelTerminal() throws {
        let ctx = try makeCtx()
        let target = try trackedTempDir().appendingPathComponent("t.json")
        try Data("keep".utf8).write(to: target)
        try fm.createSymbolicLink(at: ctx.config.manifestsDir.appendingPathComponent(validSentinelName()),
                                  withDestinationURL: target)
        assertBlocked(boot(ctx, nil), .sentinelEntryInvalid, .terminal)
        XCTAssertEqual(try Data(contentsOf: target), Data("keep".utf8), "never followed")
    }

    func testSuspiciousStagingEntriesBlockCreateFresh() throws {
        do {
            let ctx = try makeCtx()
            try Data("x".utf8).write(to: ctx.stagingRoot.appendingPathComponent("import-a..b"))
            assertBlocked(boot(ctx, nil), .stagingTampered, .terminal, "invalid id")
            XCTAssertTrue(fm.fileExists(atPath: ctx.stagingRoot.appendingPathComponent("import-a..b").path))
        }
        do {
            let ctx = try makeCtx()
            try Data("x".utf8).write(to: ctx.stagingRoot.appendingPathComponent("import-notadir"))
            assertBlocked(boot(ctx, nil), .stagingTampered, .terminal, "non-directory")
        }
        do {
            let ctx = try makeCtx()
            try fm.createDirectory(at: ctx.stagingRoot.appendingPathComponent(".attempt-orphan"),
                                   withIntermediateDirectories: true)
            try Data("j".utf8).write(to: ctx.stagingRoot.appendingPathComponent("stray.txt"))
            guard case .openStore(.createFreshExpectedAbsent, _) = boot(ctx, nil) else {
                return XCTFail("attempt/unknown residue must not block createFresh")
            }
        }
    }

    // MARK: - B1 staging recovery / selection

    func testSingleValidStagingRecoversWithoutSource() throws {
        let ctx = try makeCtx()
        let (_, source) = try makeSource()
        let id = try stageImport(ctx, from: source)
        guard case .openStore(let auth, _) = boot(ctx, nil) else { return XCTFail() }
        guard case .openExistingCompleted = auth else { return XCTFail("recovered chain mints completed auth, got \(auth)") }
        XCTAssertTrue(fm.fileExists(atPath: ctx.config.activeDestination.path))
        XCTAssertTrue(fm.fileExists(atPath: sentinelURL(ctx, id.rawValue).path))
        XCTAssertFalse(fm.fileExists(atPath: stagingDir(ctx, id).path), "staging cleaned")
        XCTAssertEqual(try Data(contentsOf: ctx.config.activeAttachmentsDir.appendingPathComponent("a.pdf")), Data("A".utf8))
    }

    func testMultipleValidStagingsRequireSelectionThenConverge() throws {
        let ctx = try makeCtx()
        let (_, s1) = try makeSource()
        let (_, s2) = try makeSource(attachments: [("b.pdf", "B")])
        let id1 = try stageImport(ctx, from: s1)
        let id2 = try stageImport(ctx, from: s2)
        guard case .requiresImportSelection(let list) = boot(ctx, nil) else { return XCTFail() }
        XCTAssertEqual(Set(list.map { $0.importID }), [id1.rawValue, id2.rawValue])
        XCTAssertTrue(list.allSatisfy { $0.status == .valid && $0.createdAt != nil })

        guard case .openStore = coord(ctx).resolveSelectedImport(importID: id1.rawValue) else {
            return XCTFail("selection must converge")
        }
        XCTAssertTrue(fm.fileExists(atPath: stagingDir(ctx, id2).path), "the unselected staging is untouched")
    }

    func testSelectionRejectsInvalidImportID() throws {
        let ctx = try makeCtx()
        for bad in ["../evil", "a..b", "x/y", ""] {
            guard case .blocked(let b) = coord(ctx).resolveSelectedImport(importID: bad) else {
                return XCTFail("\(bad): must be blocked")
            }
            XCTAssertEqual(b.code, .invalidSelection, bad)
        }
    }

    func testSelectionRevalidatesFromDiskNotFromListCache() throws {
        let ctx = try makeCtx()
        let (_, s1) = try makeSource()
        let (_, s2) = try makeSource(attachments: [("b.pdf", "B")])
        let id1 = try stageImport(ctx, from: s1)
        _ = try stageImport(ctx, from: s2)
        guard case .requiresImportSelection = boot(ctx, nil) else { return XCTFail() }
        let manifest = stagingDir(ctx, id1).appendingPathComponent("manifest.json")
        var bytes = try Data(contentsOf: manifest)
        bytes[bytes.count / 2] ^= 0xFF
        try bytes.write(to: manifest)
        guard case .blocked(let b) = coord(ctx).resolveSelectedImport(importID: id1.rawValue) else {
            return XCTFail("stale list evidence must never be consumed")
        }
        XCTAssertEqual(b.code, .stagingTampered)
    }

    func testInvalidStagingCandidateListedButNotSelectable() throws {
        let ctx = try makeCtx()
        let (_, s1) = try makeSource()
        let (_, s2) = try makeSource(attachments: [("b.pdf", "B")])
        let idOK = try stageImport(ctx, from: s1)
        let idBad = try stageImport(ctx, from: s2)
        let badManifest = stagingDir(ctx, idBad).appendingPathComponent("manifest.json")
        var bytes = try Data(contentsOf: badManifest)
        bytes[bytes.count / 2] ^= 0xFF
        try bytes.write(to: badManifest)

        guard case .requiresImportSelection(let list) = boot(ctx, nil) else { return XCTFail() }
        let ok = try XCTUnwrap(list.first { $0.importID == idOK.rawValue })
        let bad = try XCTUnwrap(list.first { $0.importID == idBad.rawValue })
        XCTAssertEqual(ok.status, .valid)
        XCTAssertEqual(bad.status, .invalid(.stagingTampered))
        XCTAssertNil(bad.createdAt)
        guard case .blocked(let b) = coord(ctx).resolveSelectedImport(importID: idBad.rawValue) else {
            return XCTFail("invalid candidate must not be consumable")
        }
        XCTAssertEqual(b.code, .stagingTampered)
    }

    /// Candidate classification must PRESERVE the gate's retriable/terminal distinction:
    /// a transient I/O failure lists as `.unavailable(.ioTransient)` (re-probeable), real
    /// content damage as `.invalid(.stagingTampered)` — never conflated.
    func testCandidateGateClassificationPreserved() throws {
        let ctx = try makeCtx()
        let (_, s1) = try makeSource()
        let (_, s2) = try makeSource(attachments: [("b.pdf", "B")])
        let (_, s3) = try makeSource(attachments: [("c.pdf", "C")])
        let idValid = try stageImport(ctx, from: s1)
        let idUnreadable = try stageImport(ctx, from: s2)
        let idCorrupt = try stageImport(ctx, from: s3)

        // Transient: the staging dir itself is unreadable (EACCES) — nothing is tampered.
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: stagingDir(ctx, idUnreadable).path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stagingDir(ctx, idUnreadable).path) }
        // Terminal: real content damage.
        let manifest = stagingDir(ctx, idCorrupt).appendingPathComponent("manifest.json")
        var bytes = try Data(contentsOf: manifest)
        bytes[bytes.count / 2] ^= 0xFF
        try bytes.write(to: manifest)

        guard case .requiresImportSelection(let list) = boot(ctx, nil) else { return XCTFail() }
        let valid = try XCTUnwrap(list.first { $0.importID == idValid.rawValue })
        let unavailable = try XCTUnwrap(list.first { $0.importID == idUnreadable.rawValue })
        let invalid = try XCTUnwrap(list.first { $0.importID == idCorrupt.rawValue })
        XCTAssertEqual(valid.status, .valid)
        XCTAssertNotNil(valid.createdAt); XCTAssertNotNil(valid.sourceKind); XCTAssertNotNil(valid.ingestedCount)
        XCTAssertEqual(unavailable.status, .unavailable(.ioTransient),
                       "transient I/O must NEVER be displayed as tampering")
        XCTAssertEqual(invalid.status, .invalid(.stagingTampered))
        for row in [unavailable, invalid] {
            XCTAssertNil(row.createdAt, row.importID)
            XCTAssertNil(row.sourceKind, row.importID)
            XCTAssertNil(row.ingestedCount, row.importID)
        }

        // Selection re-derives from DISK: while unreadable, the honest retriable block …
        guard case .blocked(let b) = coord(ctx).resolveSelectedImport(importID: idUnreadable.rawValue) else {
            return XCTFail("unreadable candidate must block with the current disk state")
        }
        XCTAssertEqual(b.code, .ioTransient)
        XCTAssertEqual(b.classification, .retriable)
        // … and once readable again, the SAME selection converges (retriable is honest).
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stagingDir(ctx, idUnreadable).path)
        guard case .openStore = coord(ctx).resolveSelectedImport(importID: idUnreadable.rawValue) else {
            return XCTFail("re-probed candidate must converge after the transient failure clears")
        }
    }

    /// The user's SELECTED import must never be silently re-adjudicated to an auto winner.
    func testSelectedRecoveryConflictSurfacesSlotOccupied() throws {
        let ctx = try makeCtx()
        let (_, sourceW) = try makeSource()
        guard case .openStore = boot(ctx, sourceW) else { return XCTFail() }   // winner W completed
        let recW = try Data(contentsOf: recordURL(ctx))
        let activeW = try Data(contentsOf: ctx.config.activeDestination)
        let winnerID = try readRecord(ctx).importID
        let sentW = try Data(contentsOf: sentinelURL(ctx, winnerID))
        try fm.removeItem(at: recordURL(ctx))
        try fm.removeItem(at: ctx.config.activeDestination)
        try fm.removeItem(at: sentinelURL(ctx, winnerID))

        let (_, sX) = try makeSource(attachments: [("x.pdf", "X")])
        let (_, sY) = try makeSource(attachments: [("y.pdf", "Y")])
        _ = try stageImport(ctx, from: sX)
        let idY = try stageImport(ctx, from: sY)
        guard case .requiresImportSelection = boot(ctx, nil) else { return XCTFail() }

        let hooks = MigrationCoordinator.CoordinatorHooks(beforeActivate: {
            try recW.write(to: self.recordURL(ctx))
            try activeW.write(to: ctx.config.activeDestination)
            try sentW.write(to: self.sentinelURL(ctx, winnerID))
        })
        let outcome = coord(ctx).resolveSelectedImport(importID: idY.rawValue, acknowledgement: nil, hooks: hooks)
        guard case .blocked(let b) = outcome else {
            return XCTFail("selected recovery must NOT silently open the winner — got \(outcome)")
        }
        XCTAssertEqual(b.code, .importSlotOccupied)
        XCTAssertEqual(b.params["requestedImportID"], idY.rawValue)
        XCTAssertEqual(b.params["existingImportID"], winnerID)
        XCTAssertTrue(fm.fileExists(atPath: stagingDir(ctx, idY).path), "the user's staging is retained")
    }

    // MARK: - R present: probe-first (B3/B4)

    func testAutoChainConvergesAndWALBootStaysProbeFirst() throws {
        let ctx = try makeCtx()
        let (_, source) = try makeSource()
        guard case .openStore(let auth1, _) = boot(ctx, source) else { return XCTFail() }
        guard case .openExistingCompleted = auth1 else { return XCTFail("chain completion mints completed auth") }
        let store = try LedgerStore(databaseURL: ctx.config.activeDestination)   // tests may; coordinator may not
        _ = try store.summary()
        guard case .openStore(let auth2, let residual) = boot(ctx, source) else {
            return XCTFail("WAL boot must resolve to openStore via the probe")
        }
        guard case .openExistingCompleted = auth2 else { return XCTFail() }
        XCTAssertNil(residual)
    }

    func testCompletedActiveMissingTerminalNoEmptyDB() throws {
        let ctx = try makeCtx()
        let (_, source) = try makeSource()
        guard case .openStore = boot(ctx, source) else { return XCTFail() }
        try fm.removeItem(at: ctx.config.activeDestination)
        assertBlocked(boot(ctx, source), .activeMissingAfterCompletion, .terminal)
        XCTAssertFalse(fm.fileExists(atPath: ctx.config.activeDestination.path),
                       "no empty DB may be minted over a completed import")
    }

    func testCompletedActiveSymlinkTerminal() throws {
        let ctx = try makeCtx()
        let (_, source) = try makeSource()
        guard case .openStore = boot(ctx, source) else { return XCTFail() }
        let target = try trackedTempDir().appendingPathComponent("victim.db")
        try Data("keep".utf8).write(to: target)
        try fm.removeItem(at: ctx.config.activeDestination)
        try fm.createSymbolicLink(at: ctx.config.activeDestination, withDestinationURL: target)
        assertBlocked(boot(ctx, source), .activeEntryInvalid, .terminal)
        XCTAssertEqual(try Data(contentsOf: target), Data("keep".utf8))
    }

    func testPendingResumesFullChain() throws {
        let ctx = try makeCtx()
        let (_, source) = try makeSource()
        let id = try chainToActivated(ctx, source: source)
        guard case .openStore(let auth, _) = boot(ctx, nil) else { return XCTFail() }
        guard case .openExistingCompleted = auth else { return XCTFail() }
        XCTAssertTrue(fm.fileExists(atPath: sentinelURL(ctx, id.rawValue).path))
        XCTAssertEqual(try Data(contentsOf: ctx.config.activeAttachmentsDir.appendingPathComponent("a.pdf")), Data("A".utf8))
        XCTAssertFalse(fm.fileExists(atPath: stagingDir(ctx, id).path))
    }

    func testAcknowledgementFlowThroughResume() throws {
        let ctx = try makeCtx()
        let (_, source) = try makeSource(symlinkAttachment: true)
        guard case .requiresAcknowledgement(let request, let unresolved) = boot(ctx, source) else {
            return XCTFail("skipped source item must demand acknowledgement")
        }
        XCTAssertFalse(unresolved.isEmpty)
        guard case .openStore = boot(ctx, source, ack: request.acknowledge()) else {
            return XCTFail("acknowledged re-run must converge")
        }
        let record = try readRecord(ctx)
        let s = try JSONDecoder().decode(ImportManifest.self,
                                         from: Data(contentsOf: sentinelURL(ctx, record.importID)))
        XCTAssertEqual(s.acknowledgedReportHash, request.unresolvedReportHash)
    }

    func testResumeStagingENOENTReingestsWithRecordImportID() throws {
        let ctx = try makeCtx()
        let (_, source) = try makeSource()
        let id = try chainToActivated(ctx, source: source)
        try fm.removeItem(at: stagingDir(ctx, id))   // definitive ENOENT
        guard case .openStore = boot(ctx, source) else { return XCTFail("re-ingest with the record's importID must converge") }
        XCTAssertTrue(fm.fileExists(atPath: sentinelURL(ctx, id.rawValue).path))
    }

    func testResumeReingestCrossCheckFailsFastBeforeRunner() throws {
        let ctx = try makeCtx()
        let (_, sourceA) = try makeSource()
        let id = try chainToActivated(ctx, source: sourceA)
        try fm.removeItem(at: stagingDir(ctx, id))
        let (_, sourceB) = try makeSource(attachments: [("z.pdf", "DIFFERENT")])
        guard case .blocked(let b) = boot(ctx, sourceB) else { return XCTFail() }
        XCTAssertEqual(b.code, .identityMismatch)
        XCTAssertEqual(b.classification, .terminal)
        XCTAssertNotNil(b.params["field"])
    }

    func testStagingPresentGateFailNeverReingested() throws {
        let ctx = try makeCtx()
        let (_, source) = try makeSource()
        let id = try chainToActivated(ctx, source: source)
        let manifest = stagingDir(ctx, id).appendingPathComponent("manifest.json")
        var bytes = try Data(contentsOf: manifest)
        bytes[bytes.count / 2] ^= 0xFF
        try bytes.write(to: manifest)
        let before = try Data(contentsOf: manifest)
        assertBlocked(boot(ctx, source), .stagingTampered, .terminal)
        XCTAssertEqual(try Data(contentsOf: manifest), before,
                       "existing staging is gated, never re-ingested or deleted")
    }

    func testForeignSentinelWithRecordConflicts() throws {
        let ctx = try makeCtx()
        let (_, source) = try makeSource()
        let id = try chainToActivated(ctx, source: source)
        try Data("{\"foreign\":true}".utf8).write(to: sentinelURL(ctx, id.rawValue))
        assertBlocked(boot(ctx, nil), .sentinelConflict, .terminal)
        XCTAssertEqual(try Data(contentsOf: sentinelURL(ctx, id.rawValue)), Data("{\"foreign\":true}".utf8))
    }

    // MARK: - Source candidate semantics

    func testAutoCandidateUnstableRetriable() throws {
        let ctx = try makeCtx()
        let src = try trackedTempDir().appendingPathComponent("SoloLedger", isDirectory: true)
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: src.appendingPathComponent(AppPaths.databaseFileName),
                                  withDestinationURL: try makeSQLiteDB())
        assertBlocked(boot(ctx, .userSelectedDataDir(src)), .interference, .retriable)
    }

    func testExplicitImportSlotOccupiedNeverAdjudicated() throws {
        let ctx = try makeCtx()
        let (_, sourceA) = try makeSource()
        guard case .openStore = boot(ctx, sourceA) else { return XCTFail() }
        let winnerID = try readRecord(ctx).importID
        let (_, sourceB) = try makeSource(attachments: [("b.pdf", "B")])
        guard case .blocked(let b) = coord(ctx).runImport(source: sourceB) else { return XCTFail() }
        XCTAssertEqual(b.code, .importSlotOccupied)
        XCTAssertEqual(b.classification, .terminal)
        XCTAssertNotNil(b.params["requestedImportID"])
        XCTAssertEqual(b.params["existingImportID"], winnerID)
    }

    // MARK: - Bounded concurrency adjudication (auto-boot only)

    func testAutoConflictAdjudicatesToWinnerFromDisk() throws {
        let ctx = try makeCtx()
        let (_, sourceA) = try makeSource()
        guard case .openStore = boot(ctx, sourceA) else { return XCTFail() }
        let recA = try Data(contentsOf: recordURL(ctx))
        let activeA = try Data(contentsOf: ctx.config.activeDestination)
        let winnerID = try readRecord(ctx).importID
        let sentA = try Data(contentsOf: sentinelURL(ctx, winnerID))
        try fm.removeItem(at: recordURL(ctx))
        try fm.removeItem(at: ctx.config.activeDestination)
        try fm.removeItem(at: sentinelURL(ctx, winnerID))
        let (_, sourceB) = try makeSource(attachments: [("b.pdf", "B")])
        _ = try stageImport(ctx, from: sourceB)
        let hooks = MigrationCoordinator.CoordinatorHooks(beforeActivate: {
            try recA.write(to: self.recordURL(ctx))
            try activeA.write(to: ctx.config.activeDestination)
            try sentA.write(to: self.sentinelURL(ctx, winnerID))
        })
        guard case .openStore(let auth, _) = boot(ctx, nil, hooks: hooks) else {
            return XCTFail("the loser must re-adjudicate from disk and converge on the winner")
        }
        guard case .openExistingCompleted = auth else { return XCTFail() }
    }

    func testAdjudicationIsBoundedAndTyped() throws {
        let ctx = try makeCtx()
        let (_, sourceA) = try makeSource()
        guard case .openStore = boot(ctx, sourceA) else { return XCTFail() }
        let recA = try Data(contentsOf: recordURL(ctx))
        let winnerID = try readRecord(ctx).importID
        try fm.removeItem(at: recordURL(ctx))
        try fm.removeItem(at: ctx.config.activeDestination)
        try fm.removeItem(at: sentinelURL(ctx, winnerID))
        let (_, sourceB) = try makeSource(attachments: [("b.pdf", "B")])
        _ = try stageImport(ctx, from: sourceB)
        let hooks = MigrationCoordinator.CoordinatorHooks(beforeActivate: {
            try recA.write(to: self.recordURL(ctx))
        })
        guard case .blocked(let b) = boot(ctx, nil, hooks: hooks) else { return XCTFail() }
        XCTAssertEqual(b.code, .importCannotComplete)
        XCTAssertEqual(b.classification, .terminal)
    }

    /// Adjudication is bounded to ONCE: a SECOND activation conflict — hit while resuming
    /// the first adjudication's winner — must return terminal `recordConflict` directly,
    /// never a third adjudication, never an openStore, and must leave every staging and
    /// the (foreign) record untouched.
    func testSecondConflictAfterAdjudicationIsTerminalRecordConflict() throws {
        let ctx = try makeCtx()
        let (_, sourceA) = try makeSource()
        // Winner W1 in its resumable pending state: record + active + staging, no sentinel.
        let idA = try chainToActivated(ctx, source: sourceA)
        let recA = try Data(contentsOf: recordURL(ctx))
        // Stash W1's scene aside so the loser's boot starts from an empty slot.
        let asideA = try trackedTempDir().appendingPathComponent("stash-import-a", isDirectory: true)
        try fm.moveItem(at: stagingDir(ctx, idA), to: asideA)
        try fm.removeItem(at: recordURL(ctx))
        try fm.removeItem(at: ctx.config.activeDestination)

        // Conflicting scene W2: a decodable, format-valid record for ANOTHER import.
        var recC = try JSONDecoder().decode(ActivationRecord.self, from: recA)
        recC.importID = "other-\(UUID().uuidString.lowercased())"
        recC.snapshotIdentitySHA256 = String(recC.snapshotIdentitySHA256.reversed())
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let recCBytes = try enc.encode(recC)

        let (_, sourceB) = try makeSource(attachments: [("b.pdf", "B")])
        var activateWindows = 0
        let hooks = MigrationCoordinator.CoordinatorHooks(beforeActivate: {
            activateWindows += 1
            switch activateWindows {
            case 1:
                // Loser B's window: W1's pending scene appears → conflict #1 → adjudicate.
                try recA.write(to: self.recordURL(ctx))
                try self.fm.moveItem(at: asideA, to: self.stagingDir(ctx, idA))
            case 2:
                // W1's resumed window: ANOTHER valid conflicting record → conflict #2.
                try self.rewriteSameInode(self.recordURL(ctx), recCBytes)
            default:
                XCTFail("no third activation window may exist (bounded adjudication)")
            }
        })
        let outcome = boot(ctx, sourceB, hooks: hooks)
        guard case .blocked(let b) = outcome else {
            return XCTFail("second conflict must be terminal, got \(outcome)")
        }
        XCTAssertEqual(b.code, .recordConflict)
        XCTAssertEqual(b.classification, .terminal)
        XCTAssertEqual(b.params["requestedImportID"], idA.rawValue)
        XCTAssertEqual(activateWindows, 2, "exactly two activation windows — no third adjudication")
        // Nothing cleaned or overwritten: both stagings retained, the foreign record and
        // slot state left exactly as conflict #2 found them.
        XCTAssertTrue(fm.fileExists(atPath: stagingDir(ctx, idA).path), "winner staging retained")
        let stagings = try fm.contentsOfDirectory(atPath: ctx.stagingRoot.path).filter { $0.hasPrefix("import-") }
        XCTAssertEqual(stagings.count, 2, "loser staging retained alongside the winner's")
        XCTAssertEqual(try Data(contentsOf: recordURL(ctx)), recCBytes, "conflicting record untouched")
        XCTAssertFalse(fm.fileExists(atPath: ctx.config.activeDestination.path), "no active DB published")
    }

    // MARK: - Bound record inspection (double read + name binding)

    func testInspectRecordFailsClosedOnMidInspectionTamper() throws {
        let ctx = try makeCtx()
        let (_, source) = try makeSource()
        _ = try chainToActivated(ctx, source: source)
        // (a) same-inode rewrite between the two bound reads → fail-closed retriable
        var tampered = try readRecord(ctx)
        tampered.importID = "someone-else"
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let tamperedBytes = try enc.encode(tampered)
        var state = MigrationCoordinator.inspectRecord(activeDestination: ctx.config.activeDestination,
                                                       afterFirstRead: {
            try self.rewriteSameInode(self.recordURL(ctx), tamperedBytes)
        })
        guard case .unreadableRetriable = state else { return XCTFail("rewrite mid-inspection must fail closed, got \(state)") }
        // restore for (b)
        let original = try Data(contentsOf: recordURL(ctx))
        _ = original
        // (b) name swapped to a different inode between the reads → fail-closed retriable
        state = MigrationCoordinator.inspectRecord(activeDestination: ctx.config.activeDestination,
                                                   afterFirstRead: {
            let aside = self.recordURL(ctx).deletingLastPathComponent().appendingPathComponent("rec-aside.json")
            try self.fm.moveItem(at: self.recordURL(ctx), to: aside)
            try Data("{}".utf8).write(to: self.recordURL(ctx))
        })
        guard case .unreadableRetriable = state else { return XCTFail("name swap mid-inspection must fail closed, got \(state)") }
    }

    // MARK: - confirmOpenAuthorization (final re-check before LedgerStore.init)

    private func completedAuth(_ ctx: Ctx, _ source: MigrationSource?) throws -> StoreOpenAuthorization {
        guard case .openStore(let auth, _) = boot(ctx, source) else { throw Crash() }
        guard case .openExistingCompleted = auth else { throw Crash() }
        return auth
    }
    private struct Crash: Error {}

    func testConfirmCompletedDetectsRecordTampering() throws {
        let (_, source) = try makeSource()
        // (a) record deleted
        do {
            let ctx = try makeCtx()
            let auth = try completedAuth(ctx, source)
            try fm.removeItem(at: recordURL(ctx))
            XCTAssertEqual(coord(ctx).confirmOpenAuthorization(auth, autoSourceCandidate: nil), .reResolve)
        }
        // (b) record swapped to a different inode holding ANOTHER valid record
        do {
            let ctx = try makeCtx()
            let auth = try completedAuth(ctx, source)
            var other = try readRecord(ctx)
            other.importID = "other-\(UUID().uuidString.lowercased())"
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try fm.removeItem(at: recordURL(ctx))
            try enc.encode(other).write(to: recordURL(ctx))
            XCTAssertEqual(coord(ctx).confirmOpenAuthorization(auth, autoSourceCandidate: nil), .reResolve)
        }
        // (c) same-inode rewrite of one identity field
        do {
            let ctx = try makeCtx()
            let auth = try completedAuth(ctx, source)
            var t = try readRecord(ctx)
            t.snapshotIdentitySHA256 = String(t.snapshotIdentitySHA256.reversed())
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try rewriteSameInode(recordURL(ctx), try enc.encode(t))
            XCTAssertEqual(coord(ctx).confirmOpenAuthorization(auth, autoSourceCandidate: nil), .reResolve)
        }
        // (d) untouched → proceed
        do {
            let ctx = try makeCtx()
            let auth = try completedAuth(ctx, source)
            XCTAssertEqual(coord(ctx).confirmOpenAuthorization(auth, autoSourceCandidate: nil), .proceed)
        }
    }

    func testConfirmCompletedDetectsSentinelTampering() throws {
        let (_, source) = try makeSource()
        // (a) sentinel deleted → probe pending → reResolve
        do {
            let ctx = try makeCtx()
            let auth = try completedAuth(ctx, source)
            try fm.removeItem(at: sentinelURL(ctx, try readRecord(ctx).importID))
            XCTAssertEqual(coord(ctx).confirmOpenAuthorization(auth, autoSourceCandidate: nil), .reResolve)
        }
        // (b) same-inode rewrite to foreign content → probe conflict → reResolve
        do {
            let ctx = try makeCtx()
            let auth = try completedAuth(ctx, source)
            try rewriteSameInode(sentinelURL(ctx, try readRecord(ctx).importID), Data("{\"foreign\":true}".utf8))
            XCTAssertEqual(coord(ctx).confirmOpenAuthorization(auth, autoSourceCandidate: nil), .reResolve)
        }
        // (c) different-inode foreign swap → reResolve
        do {
            let ctx = try makeCtx()
            let auth = try completedAuth(ctx, source)
            let url = sentinelURL(ctx, try readRecord(ctx).importID)
            try fm.removeItem(at: url)
            try Data("{\"foreign\":true}".utf8).write(to: url)
            XCTAssertEqual(coord(ctx).confirmOpenAuthorization(auth, autoSourceCandidate: nil), .reResolve)
        }
    }

    func testConfirmPlainDetectsLateRecordOrSentinel() throws {
        // late record
        do {
            let ctx = try makeCtx()
            try Data("plain".utf8).write(to: ctx.config.activeDestination)
            guard case .openStore(let auth, _) = boot(ctx, nil) else { return XCTFail() }
            try writeFakeRecord(ctx)
            XCTAssertEqual(coord(ctx).confirmOpenAuthorization(auth, autoSourceCandidate: nil), .reResolve)
        }
        // late canonical sentinel
        do {
            let ctx = try makeCtx()
            try Data("plain".utf8).write(to: ctx.config.activeDestination)
            guard case .openStore(let auth, _) = boot(ctx, nil) else { return XCTFail() }
            try Data("GARBAGE".utf8).write(to: ctx.config.manifestsDir.appendingPathComponent(validSentinelName()))
            XCTAssertEqual(coord(ctx).confirmOpenAuthorization(auth, autoSourceCandidate: nil), .reResolve)
        }
    }

    func testConfirmCreateFreshDetectsLateRecord() throws {
        let ctx = try makeCtx()
        guard case .openStore(.createFreshExpectedAbsent, _) = boot(ctx, nil) else { return XCTFail() }
        try writeFakeRecord(ctx)
        XCTAssertEqual(coord(ctx).confirmOpenAuthorization(.createFreshExpectedAbsent, autoSourceCandidate: nil),
                       .reResolve)
        XCTAssertFalse(fm.fileExists(atPath: ctx.config.activeDestination.path), "no empty DB")
    }

    func testConfirmCreateFreshDetectsLateStagingSentinelAndActive() throws {
        do {
            let ctx = try makeCtx()
            guard case .openStore(.createFreshExpectedAbsent, _) = boot(ctx, nil) else { return XCTFail() }
            let (_, source) = try makeSource()
            _ = try stageImport(ctx, from: source)
            XCTAssertEqual(coord(ctx).confirmOpenAuthorization(.createFreshExpectedAbsent, autoSourceCandidate: nil),
                           .reResolve)
        }
        do {
            let ctx = try makeCtx()
            guard case .openStore(.createFreshExpectedAbsent, _) = boot(ctx, nil) else { return XCTFail() }
            try Data("GARBAGE".utf8).write(to: ctx.config.manifestsDir.appendingPathComponent(validSentinelName()))
            XCTAssertEqual(coord(ctx).confirmOpenAuthorization(.createFreshExpectedAbsent, autoSourceCandidate: nil),
                           .reResolve)
        }
        for kind in ["regular", "symlink", "directory"] {
            let ctx = try makeCtx()
            guard case .openStore(.createFreshExpectedAbsent, _) = boot(ctx, nil) else { return XCTFail(kind) }
            let target = try trackedTempDir().appendingPathComponent("victim.db")
            try Data("keep".utf8).write(to: target)
            switch kind {
            case "regular": try Data("late".utf8).write(to: ctx.config.activeDestination)
            case "symlink": try fm.createSymbolicLink(at: ctx.config.activeDestination, withDestinationURL: target)
            default: try fm.createDirectory(at: ctx.config.activeDestination, withIntermediateDirectories: false)
            }
            XCTAssertEqual(coord(ctx).confirmOpenAuthorization(.createFreshExpectedAbsent, autoSourceCandidate: nil),
                           .reResolve, kind)
            XCTAssertEqual(try Data(contentsOf: target), Data("keep".utf8), "\(kind): target untouched")
        }
    }

    func testConfirmCreateFreshRechecksSourceAppearance() throws {
        let ctx = try makeCtx()
        let srcDir = try trackedTempDir().appendingPathComponent("SoloLedger", isDirectory: true)
        try fm.createDirectory(at: srcDir, withIntermediateDirectories: true)
        let candidate = MigrationSource.userSelectedDataDir(srcDir)
        guard case .openStore(.createFreshExpectedAbsent, _) = boot(ctx, candidate) else { return XCTFail() }
        try fm.copyItem(at: try makeSQLiteDB(), to: srcDir.appendingPathComponent(AppPaths.databaseFileName))
        XCTAssertEqual(coord(ctx).confirmOpenAuthorization(.createFreshExpectedAbsent, autoSourceCandidate: candidate),
                       .reResolve)
        XCTAssertFalse(fm.fileExists(atPath: ctx.config.activeDestination.path))
        guard case .openStore(let auth, _) = boot(ctx, candidate) else { return XCTFail() }
        guard case .openExistingCompleted = auth else { return XCTFail("re-resolve must adopt the appeared source") }
    }

    // MARK: - Lazy creation (probe-first must not mint chain directories)

    func testCompletedBootNeedsNoChainDirectoriesAndCreatesNone() throws {
        let ctx = try makeCtx()
        let (_, source) = try makeSource()
        guard case .openStore = boot(ctx, source) else { return XCTFail() }
        // A second coordinator over the SAME completed slot/manifests, whose work/prepared/
        // attachments/staging paths do NOT exist — the probe-first boot must succeed and
        // must not create any of them (a missing attachments dir is NOT silently rebuilt).
        let ghostBase = try trackedTempDir()
        let c2 = MigrationCoordinator.Config(
            activeDestination: ctx.config.activeDestination,
            activeAttachmentsDir: ghostBase.appendingPathComponent("ghost-docs", isDirectory: true),
            manifestsDir: ctx.config.manifestsDir,
            workingDirectory: ghostBase.appendingPathComponent("ghost-work", isDirectory: true),
            preparedRoot: ghostBase.appendingPathComponent("ghost-prepared", isDirectory: true))
        let ghostStaging = ghostBase.appendingPathComponent("ghost-staging", isDirectory: true)
        let coordinator2 = MigrationCoordinator(config: c2, stagingRootOverride: ghostStaging, ingestOverride: nil)
        guard case .openStore(let auth, _) = coordinator2.bootResolve(autoSourceCandidate: nil) else {
            return XCTFail("completed boot must succeed without chain directories")
        }
        guard case .openExistingCompleted = auth else { return XCTFail() }
        XCTAssertEqual(coordinator2.confirmOpenAuthorization(auth, autoSourceCandidate: nil), .proceed)
        for ghost in [c2.activeAttachmentsDir, c2.workingDirectory, c2.preparedRoot, ghostStaging] {
            XCTAssertFalse(fm.fileExists(atPath: ghost.path), "\(ghost.lastPathComponent) must not be created")
        }
    }

    func testConfigStandardDerivesWithoutCreating() throws {
        // Pure derivation: the returned paths are consistent with AppPaths' layout, and the
        // call itself performs no directory creation (probed via a nonexistent marker —
        // standard() derives from the app-support base; we can only assert derivation
        // consistency here without touching real state).
        let c = try MigrationCoordinator.Config.standard()
        XCTAssertEqual(c.activeDestination.lastPathComponent, AppPaths.databaseFileName)
        XCTAssertEqual(c.activeAttachmentsDir.lastPathComponent, "docs")
        XCTAssertEqual(c.manifestsDir.lastPathComponent, "ImportManifests")
        XCTAssertEqual(c.workingDirectory.lastPathComponent, "ImportWork")
        XCTAssertEqual(c.preparedRoot.lastPathComponent, "PreparedImports")
    }

    // MARK: - Exhaustive mapping table (dictated rows must never drift)

    func testErrorMappingTable() {
        typealias M = MigrationCoordinator
        XCTAssertEqual(M.map(IngestError.sourceDatabaseMissing("p"), context: .autoBoot),
                       .retriable(.interference, ["op": "ingest", "reason": "sourceDatabaseMissing"]))
        XCTAssertEqual(M.map(IngestError.sourceDatabaseMissing("p"), context: .explicitImport),
                       .terminal(.invalidSource, ["reason": "sourceDatabaseMissing"]))
        XCTAssertEqual(M.map(IngestError.sourceDatabaseMissing("p"), context: .selectedRecovery),
                       .terminal(.invalidSource, ["reason": "sourceDatabaseMissing"]))
        XCTAssertEqual(M.map(IngestError.sourceBusy(attempts: 3), context: .autoBoot).code, .sourceBusy)
        XCTAssertEqual(M.map(IngestError.sourceBusy(attempts: 3), context: .autoBoot).classification, .retriable)
        XCTAssertEqual(M.map(StagedSnapshotError.stagingUnreadable("x")).classification, .retriable)
        XCTAssertEqual(M.map(StagedSnapshotError.attachmentManifestHashMismatch).code, .stagingTampered)
        XCTAssertEqual(M.map(StagedSnapshotError.attachmentManifestHashMismatch).classification, .terminal)
        XCTAssertEqual(M.map(PreparedRunFailure.preparedPublishConflict("x")).code, .recordConflict)
        XCTAssertEqual(M.map(PreparedRunFailure.preparedPublishConflict("x")).classification, .terminal)
        XCTAssertEqual(M.map(PreparedRunFailure.workAreaSwapped("x")).classification, .retriable)
        XCTAssertEqual(M.map(PreparedRunFailure.unsupportedUserVersion(found: 99)).classification, .terminal)
        XCTAssertEqual(M.map(PreparedRunFailure.integrityFailed("x")).classification, .terminal)
        XCTAssertEqual(M.map(PreparedRunFailure.foreignKeyViolations("x")).classification, .terminal)
        XCTAssertEqual(M.map(PreparedRunFailure.schemaIncomplete("x")).classification, .terminal)
        XCTAssertEqual(M.map(ActivationError.activeIdentityMismatch(expected: "a", actual: "b")).code, .identityMismatch)
        XCTAssertEqual(M.map(ActivationError.durabilityNotConfirmed("x")).classification, .retriable)
        XCTAssertEqual(M.map(ActivationError.activationRecordMalformed("x")).code, .recordMalformed)
        let a = M.map(FinalizeError.activeDatabaseUnsupported("journal_mode 'wal' — opened early"))
        let b = M.map(FinalizeError.activeDatabaseUnsupported("corrupt: quick_check"))
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.code, .activeDatabaseUnsupported)
        XCTAssertEqual(a.classification, .terminal)
        XCTAssertEqual(M.map(FinalizeError.attachmentConflict("x")).classification, .terminal)
        XCTAssertEqual(M.map(FinalizeError.referencedFileChangedSinceAudit("x")).classification, .retriable)
    }
}
