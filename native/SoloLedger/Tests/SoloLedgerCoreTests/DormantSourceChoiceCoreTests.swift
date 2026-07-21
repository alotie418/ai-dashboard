import XCTest
@testable import SoloLedgerCore

/// N7.1 dormancy + entry-semantics guards (design §1.1-§1.3, §7.1, §11.1):
///  - `.requiresSourceChoice` can ONLY become `.awaitingSourceChoice` (never an authorization);
///  - the PRODUCTION boot resolution is UNFLIPPED: a clean disk with an unavailable auto
///    candidate still mints the old `.createFreshExpectedAbsent` — never `.requiresSourceChoice`;
///  - the strong-typed `confirmCreateFresh` entry takes no auto candidate, cannot bypass an
///    existing active store or published staging, and its authorization stays revocable at
///    `confirmOpenAuthorization` when an auto source appears (re-adjudication prefers migration).
final class DormantSourceChoiceCoreTests: LedgerTestCase {

    private let fm = FileManager.default

    // MARK: - Harness (same isolation seams as MigrationCoordinatorTests)

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

    private func coord(_ ctx: Ctx) -> MigrationCoordinator {
        let root = ctx.stagingRoot
        return MigrationCoordinator(config: ctx.config, stagingRootOverride: root,
                                    ingestOverride: { source, id in
            let r = try StagingIngest().ingest(source, importID: id, timestamp: "t")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let dst = root.appendingPathComponent("import-\(id.rawValue)", isDirectory: true)
            try FileManager.default.moveItem(at: r.stagingDir, to: dst)
            let docs = dst.appendingPathComponent("attachments", isDirectory: true)
                          .appendingPathComponent("docs", isDirectory: true)
            return IngestResult(importID: r.importID, stagingDir: dst,
                                stagedDatabaseURL: dst.appendingPathComponent(AppPaths.databaseFileName),
                                stagedWALURL: r.stagedWALURL.map { _ in URL(fileURLWithPath: dst.path + "/" + AppPaths.databaseFileName + "-wal") },
                                stagedAttachmentsDir: r.stagedAttachmentsDir.map { _ in docs },
                                manifest: r.manifest)
        })
    }

    /// A synthetic v0 source tree (`<tmp>/SoloLedger/sololedger.db`) — an AVAILABLE source.
    private func makeAvailableSource() throws -> MigrationSource {
        let src = try trackedTempDir().appendingPathComponent("SoloLedger", isDirectory: true)
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        let db = try SQLiteDatabase(path: src.appendingPathComponent(AppPaths.databaseFileName).path,
                                    mode: .readWriteCreate)
        try db.execute("PRAGMA journal_mode = DELETE")
        try db.execute("PRAGMA user_version = 0")
        try db.close()
        return .userSelectedDataDir(src)
    }

    /// A definitively ABSENT candidate (unavailable auto source).
    private func makeUnavailableSource() throws -> MigrationSource {
        .userSelectedDataDir(try trackedTempDir().appendingPathComponent("nothing-here", isDirectory: true))
    }

    // MARK: - classifyOutcome: the dormant outcome can only become a UI state

    func testRequiresSourceChoiceClassifiesToAwaitingSourceChoiceOnly() {
        let step = MigrationBootDriver.classifyOutcome(.requiresSourceChoice)
        XCTAssertEqual(step, .ui(.awaitingSourceChoice),
                       "requiresSourceChoice is a NON-openStore outcome: it must map to the waiting state and can never become an authorization (so it can never reach attemptOpen or construct a store)")
    }

    // MARK: - N7.1 UNREACHABILITY PIN: resolveB1 is not flipped

    func testProductionBootResolutionStillMintsCreateFreshNeverSourceChoice() throws {
        let ctx = try makeCtx()
        for auto in [try makeUnavailableSource(), nil] {
            let outcome = coord(ctx).bootResolve(autoSourceCandidate: auto)
            if case .requiresSourceChoice = outcome {
                return XCTFail("N7.1 REGRESSION: production boot resolution emitted requiresSourceChoice — resolveB1 must stay unflipped until N7.2")
            }
            guard case .openStore(let auth, nil) = outcome, case .createFreshExpectedAbsent = auth else {
                return XCTFail("clean-disk boot with an unavailable auto candidate must still mint the OLD createFreshExpectedAbsent authorization, got \(outcome)")
            }
        }
    }

    // MARK: - confirmCreateFresh entry semantics

    func testConfirmCreateFreshMintsCreateFreshOnCleanDisk() throws {
        let ctx = try makeCtx()
        guard case .openStore(let auth, nil) = coord(ctx).confirmCreateFresh(),
              case .createFreshExpectedAbsent = auth else {
            return XCTFail("confirmed create-fresh over a clean disk must mint the createFresh authorization")
        }
    }

    func testConfirmCreateFreshNeverBypassesExistingActive() throws {
        let ctx = try makeCtx()
        try Data("existing".utf8).write(to: ctx.config.activeDestination)
        guard case .openStore(let auth, nil) = coord(ctx).confirmCreateFresh() else {
            return XCTFail("existing active must resolve to an open authorization")
        }
        guard case .openExistingPlain = auth else {
            return XCTFail("an existing active store DOMINATES a confirmed create-fresh — got \(auth)")
        }
    }

    func testConfirmCreateFreshDefersToPublishedStaging() throws {
        // A published staging (a real, resumable import) must dominate: the confirmed
        // create-fresh entry resumes it to completion instead of minting an empty ledger.
        let ctx = try makeCtx()
        let source = try makeAvailableSource()
        guard case .openStore(let auth1, _) = coord(ctx).runImport(source: source),
              case .openExistingCompleted = auth1 else {
            return XCTFail("priming import must complete")
        }
        guard case .openStore(let auth2, nil) = coord(ctx).confirmCreateFresh(),
              case .openExistingCompleted = auth2 else {
            return XCTFail("a completed import must dominate a confirmed create-fresh")
        }
    }

    func testCreateFreshAuthorizationRevocableWhenAutoSourceAppears() throws {
        // §7.1 decision 5: the auto candidate is consulted ONLY at the createFresh confirm
        // gate — and there it can revoke the authorization so re-adjudication prefers
        // migration over silently minting an empty ledger.
        let ctx = try makeCtx()
        guard case .openStore(let auth, nil) = coord(ctx).confirmCreateFresh(),
              case .createFreshExpectedAbsent = auth else {
            return XCTFail("clean disk must authorize createFresh")
        }
        let nowAvailable = try makeAvailableSource()
        let precheck = coord(ctx).confirmOpenAuthorization(auth, autoSourceCandidate: nowAvailable)
        XCTAssertEqual(precheck, .reResolve,
                       "an auto source appearing before the fresh open must revoke the createFresh authorization")
        XCTAssertFalse(fm.fileExists(atPath: ctx.config.activeDestination.path),
                       "revocation must not create anything at the active path")
        // Without a candidate the same authorization still confirms — the revocation above
        // was the auto source, not an unrelated precondition.
        XCTAssertEqual(coord(ctx).confirmOpenAuthorization(auth, autoSourceCandidate: nil),
                       .proceed(.createFresh))
    }
}
