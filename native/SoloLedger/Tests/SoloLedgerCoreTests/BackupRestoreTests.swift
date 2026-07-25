import XCTest
@testable import SoloLedgerCore

/// `BackupRestore` — the destructive half of restore. Proves (1) read-only bundle validation
/// accepts a good bundle and rejects bad ones, (2) `clearActiveSlot` removes the slot but preserves
/// `Backups/`, and (3) the Approach-B round trip: clearing an OCCUPIED active slot and re-importing
/// a DIFFERENT bundle through the hardened chain rebuilds the ledger AND its attachments (closing G1),
/// with the previous ledger's attachments gone.
final class BackupRestoreTests: LedgerTestCase {

    private let fm = FileManager.default

    // MARK: - Isolated chain harness (same seam as ElectronFixtureMigrationChainTests)

    private struct Ctx { let config: MigrationCoordinator.Config; let stagingRoot: URL }

    private func td() throws -> URL {
        let d = try trackedTempDir()
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(d.path, &buf) != nil else { return d }
        return URL(fileURLWithPath: String(cString: buf), isDirectory: true)
    }

    private func makeCtx() throws -> Ctx {
        func dir(_ name: String) throws -> URL {
            let d = try trackedTempDir().appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: d, withIntermediateDirectories: true); return d
        }
        func canonicalDir(_ name: String) throws -> URL {
            let d = try td().appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: d, withIntermediateDirectories: true); return d
        }
        let config = MigrationCoordinator.Config(
            activeDestination: try canonicalDir("ActiveSlot").appendingPathComponent(AppPaths.databaseFileName),
            activeAttachmentsDir: try dir("active-docs"),
            manifestsDir: try dir("ImportManifests"),
            workingDirectory: try dir("Work"),
            preparedRoot: try dir("PreparedImports"))
        return Ctx(config: config, stagingRoot: try dir("Staging"))
    }

    private static func seamIngest(_ source: MigrationSource, _ importID: ImportID, into root: URL) throws -> IngestResult {
        let r = try StagingIngest().ingest(source, importID: importID, timestamp: "t")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dst = root.appendingPathComponent("import-\(importID.rawValue)", isDirectory: true)
        try FileManager.default.moveItem(at: r.stagingDir, to: dst)
        let docs = dst.appendingPathComponent("attachments", isDirectory: true).appendingPathComponent("docs", isDirectory: true)
        return IngestResult(importID: r.importID, stagingDir: dst,
                            stagedDatabaseURL: dst.appendingPathComponent(AppPaths.databaseFileName),
                            stagedWALURL: r.stagedWALURL.map { _ in URL(fileURLWithPath: dst.path + "/" + AppPaths.databaseFileName + "-wal") },
                            stagedAttachmentsDir: r.stagedAttachmentsDir.map { _ in docs },
                            manifest: r.manifest)
    }

    private func coord(_ ctx: Ctx) -> MigrationCoordinator {
        let root = ctx.stagingRoot
        return MigrationCoordinator(config: ctx.config, stagingRootOverride: root,
                                    ingestOverride: { source, id in try Self.seamIngest(source, id, into: root) })
    }

    @discardableResult
    private func importCompleted(_ ctx: Ctx, _ source: MigrationSource,
                                 file: StaticString = #filePath, line: UInt = #line) throws -> Bool {
        let outcome = coord(ctx).runImport(source: source)
        guard case .openStore(let auth, nil) = outcome, case .openExistingCompleted = auth else {
            XCTFail("import must converge to completed, got \(outcome)", file: file, line: line); return false
        }
        return true
    }

    // MARK: - Bundle builder (via the real BackupExport)

    /// A backup bundle carrying one transaction of `amount` and one attachment `name`/`bytes`.
    private func makeBundle(amount: Double, name: String, bytes: Data) throws -> URL {
        let root = try trackedTempDir()
        let store = try LedgerStore(databaseURL: root.appendingPathComponent(AppPaths.databaseFileName), open: .createIfMissing)
        try store.create(Transaction(type: .income, date: "2026-03-03", amount: amount, currency: "CNY"))
        let att = root.appendingPathComponent("docs", isDirectory: true)
        try fm.createDirectory(at: att, withIntermediateDirectories: true)
        try bytes.write(to: att.appendingPathComponent(name))
        let bundle = root.appendingPathComponent("bundle", isDirectory: true)
        try BackupExport.writeBundle(database: store.db, attachmentsDir: att, to: bundle)
        try store.db.close()
        return bundle
    }

    // MARK: - 1. validateBundle

    func testValidateBundleAcceptsGoodAndRejectsMissingDB() throws {
        let good = try makeBundle(amount: 10, name: "a.pdf", bytes: Data("a".utf8))
        XCTAssertNoThrow(try BackupRestore.validateBundle(good))

        let empty = try trackedTempDir().appendingPathComponent("empty-bundle", isDirectory: true)
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertThrowsError(try BackupRestore.validateBundle(empty)) { e in
            guard case BackupRestore.Failure.bundleDatabaseMissing = e else {
                return XCTFail("expected bundleDatabaseMissing, got \(e)")
            }
        }
    }

    // MARK: - 2. clearActiveSlot removes the slot, preserves Backups

    func testClearActiveSlotRemovesSlotArtifactsButPreservesBackups() throws {
        let ctx = try makeCtx()
        let base = ctx.config.activeDestination.deletingLastPathComponent()
        // Plant a full slot: active DB(+sidecars), record, attachment, sentinel, and a Backups file.
        try Data("db".utf8).write(to: ctx.config.activeDestination)
        try Data("wal".utf8).write(to: URL(fileURLWithPath: ctx.config.activeDestination.path + "-wal"))
        try Data("rec".utf8).write(to: base.appendingPathComponent(PreparedImportActivator.recordName))
        try Data("att".utf8).write(to: ctx.config.activeAttachmentsDir.appendingPathComponent("x.pdf"))
        try Data("sent".utf8).write(to: ctx.config.manifestsDir.appendingPathComponent("import-1.json"))
        let backups = base.appendingPathComponent("Backups", isDirectory: true)
        try fm.createDirectory(at: backups, withIntermediateDirectories: true)
        let safety = backups.appendingPathComponent("pre-restore.db")
        try Data("safety".utf8).write(to: safety)

        try BackupRestore.clearActiveSlot(config: ctx.config)

        XCTAssertFalse(fm.fileExists(atPath: ctx.config.activeDestination.path), "active db removed")
        XCTAssertFalse(fm.fileExists(atPath: ctx.config.activeDestination.path + "-wal"), "sidecar removed")
        XCTAssertFalse(fm.fileExists(atPath: base.appendingPathComponent(PreparedImportActivator.recordName).path), "record removed")
        XCTAssertFalse(fm.fileExists(atPath: ctx.config.activeAttachmentsDir.path), "attachments removed")
        XCTAssertFalse(fm.fileExists(atPath: ctx.config.manifestsDir.path), "sentinels removed")
        XCTAssertTrue(fm.fileExists(atPath: safety.path), "Backups/ (safety snapshot) MUST be preserved")
        // Idempotent: a second clear on the emptied slot does not throw.
        XCTAssertNoThrow(try BackupRestore.clearActiveSlot(config: ctx.config))
    }

    // MARK: - 3. Approach-B round trip: clear an occupied slot, re-import a different bundle

    func testClearThenReimportRebuildsLedgerAndAttachmentsReplacingPrevious() throws {
        let ctx = try makeCtx()
        let bundleA = try makeBundle(amount: 111, name: "aaa.pdf", bytes: Data("AAA".utf8))
        let bundleB = try makeBundle(amount: 222, name: "bbb.pdf", bytes: Data("BBB".utf8))

        // Occupy the slot with bundle A.
        XCTAssertTrue(try importCompleted(ctx, .exportBundle(bundleA)))
        let a = try LedgerStore(databaseURL: ctx.config.activeDestination, open: .createIfMissing)
        XCTAssertEqual(try a.listTransactions().first?.amount, 111)
        try a.db.close()
        XCTAssertTrue(fm.fileExists(atPath: ctx.config.activeAttachmentsDir.appendingPathComponent("aaa.pdf").path),
                      "bundle A attachment applied")

        // Restore bundle B: clear the slot, then re-import through the hardened chain.
        try BackupRestore.clearActiveSlot(config: ctx.config)
        XCTAssertTrue(try importCompleted(ctx, .exportBundle(bundleB)))

        let b = try LedgerStore(databaseURL: ctx.config.activeDestination, open: .createIfMissing)
        XCTAssertEqual(try b.listTransactions().count, 1, "restored ledger has exactly B's rows")
        XCTAssertEqual(try b.listTransactions().first?.amount, 222, "ledger is now bundle B's")
        try b.db.close()
        XCTAssertTrue(fm.fileExists(atPath: ctx.config.activeAttachmentsDir.appendingPathComponent("bbb.pdf").path),
                      "bundle B attachment applied (finalizer closed G1)")
        XCTAssertFalse(fm.fileExists(atPath: ctx.config.activeAttachmentsDir.appendingPathComponent("aaa.pdf").path),
                       "previous ledger's attachment is gone after restore")
    }
}
