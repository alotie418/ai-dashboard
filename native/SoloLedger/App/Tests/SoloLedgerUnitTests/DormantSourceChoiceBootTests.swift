import XCTest
@testable import SoloLedger
@testable import SoloLedgerCore

/// N7.2 App-hosted guards (design §1.2/§6/§7.1/§11.1): the two source-choice boot intents
/// (`.confirmCreateFresh`, `.migrateFromUserDir`), the `.awaitingSourceChoice` waiting state's
/// store-free invariants, the §7.1(a) reResolve stickiness of an explicit user source, the
/// directory-picker contract (single-directory config; cancel = ZERO intents; OK = exactly
/// `.migrateFromUserDir(.userSelectedDataDir)`), the end-to-end FLIP pin (a production-shaped
/// clean-slot boot lands in the source choice, and both choices complete), and the
/// PRODUCTION-MAPPING guards: every production-shaped runner here comes from the real
/// `AppModel.makeBootChainRunner` factory (the single shipped intent→coordinator switch, no
/// hand-copied mapping), so wiring drift in the production factory fails these tests.
@MainActor
final class DormantSourceChoiceBootTests: XCTestCase {

    private let fm = FileManager.default
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = fm.temporaryDirectory
            .appendingPathComponent("SLDormantTest-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot { try? fm.removeItem(at: tempRoot) }
        tempRoot = nil
    }

    // MARK: - Test doubles (same shape as AppModelBootTests)

    private final class FakeRunner: BootChainRunner {
        var outcomes: [BootOutcome] = []
        var attempts: [MigrationBootDriver.Attempt] = []
        private(set) var resolveCount = 0
        private(set) var receivedIntents: [BootIntent] = []

        @MainActor func resolveOutcome(_ intent: BootIntent) async -> BootOutcome {
            receivedIntents.append(intent)
            let idx = resolveCount
            resolveCount += 1
            guard !outcomes.isEmpty else { return .blocked(MigrationBlock(code: .internalError, classification: .terminal)) }
            return outcomes[Swift.min(idx, outcomes.count - 1)]
        }

        @MainActor func attempt(_ authorization: StoreOpenAuthorization,
                                residual: MigrationResidual?) -> MigrationBootDriver.Attempt {
            guard !attempts.isEmpty else { return .ui(.terminal(MigrationBlock(code: .internalError, classification: .terminal))) }
            let a = attempts.removeFirst()
            return a
        }
    }

    private func sourceURL(_ name: String = "ChosenSource") -> URL {
        tempRoot.appendingPathComponent(name, isDirectory: true)
    }

    // MARK: - BootIntent value semantics

    func testNewBootIntentsAreExactlyEquatable() {
        let a = sourceURL("a"), b = sourceURL("b")
        XCTAssertEqual(BootIntent.confirmCreateFresh, .confirmCreateFresh)
        XCTAssertEqual(BootIntent.migrateFromUserDir(.userSelectedDataDir(a)),
                       .migrateFromUserDir(.userSelectedDataDir(a)))
        XCTAssertNotEqual(BootIntent.migrateFromUserDir(.userSelectedDataDir(a)),
                          .migrateFromUserDir(.userSelectedDataDir(b)))
        XCTAssertNotEqual(BootIntent.migrateFromUserDir(.userSelectedDataDir(a)),
                          .migrateFromUserDir(.legacySingleDB(a)))
        XCTAssertNotEqual(BootIntent.confirmCreateFresh, .boot)
    }

    // MARK: - awaitingSourceChoice: store-free waiting state

    func testRequiresSourceChoiceLandsInAwaitingSourceChoiceWithNoStore() async {
        let fake = FakeRunner(); fake.outcomes = [.requiresSourceChoice]
        let model = AppModel(runner: fake)
        model.boot()
        await model.currentBootTask?.value
        guard case .awaitingSourceChoice = model.migrationUIState else {
            return XCTFail("requiresSourceChoice must land in awaitingSourceChoice, got \(model.migrationUIState)")
        }
        XCTAssertNil(model.store, "the source-choice waiting state must never publish a store")
        XCTAssertFalse(model.ready)
        XCTAssertFalse(model.inFlight, "the chain must finish so a follow-up intent can start cleanly")
    }

    // MARK: - Single-flight for the dormant intents

    func testDormantIntentsRespectHardSingleFlight() async {
        let fake = FakeRunner(); fake.outcomes = [.requiresSourceChoice]
        let model = AppModel(runner: fake)
        model.migrateFromUserDir(source: .userSelectedDataDir(sourceURL()))
        XCTAssertEqual(model.bootGeneration, 1)
        model.confirmCreateFresh()                                     // rejected: in flight
        model.migrateFromUserDir(source: .userSelectedDataDir(sourceURL("other")))   // rejected
        XCTAssertEqual(model.bootGeneration, 1, "rejected clicks must not advance the generation")
        await model.currentBootTask?.value
        XCTAssertEqual(fake.receivedIntents,
                       [.migrateFromUserDir(.userSelectedDataDir(sourceURL()))],
                       "only the FIRST intent may run; later clicks during flight are dropped")
    }

    // MARK: - §7.1(a): explicit source is STICKY across reResolve

    func testMigrateFromUserDirReResolveKeepsTheChosenSource() async {
        let chosen = MigrationSource.userSelectedDataDir(sourceURL())
        let fake = FakeRunner()
        fake.outcomes = [.openStore(authorization: .openExistingPlain, residual: nil),
                         .requiresSourceChoice]   // second Phase A parks the chain harmlessly
        fake.attempts = [.needsReResolve]
        let model = AppModel(runner: fake)
        model.migrateFromUserDir(source: chosen)
        await model.currentBootTask?.value
        XCTAssertEqual(fake.receivedIntents,
                       [.migrateFromUserDir(chosen), .migrateFromUserDir(chosen)],
                       "§7.1(a): a reResolve of an explicit user source must KEEP that source — never collapse to .boot (which would re-inject the auto candidate: a silent source switch)")
    }

    func testConfirmCreateFreshReResolveCollapsesToBootForReadjudication() async {
        let fake = FakeRunner()
        fake.outcomes = [.openStore(authorization: .createFreshExpectedAbsent, residual: nil),
                         .requiresSourceChoice]
        fake.attempts = [.needsReResolve]
        let model = AppModel(runner: fake)
        model.confirmCreateFresh()
        await model.currentBootTask?.value
        XCTAssertEqual(fake.receivedIntents, [.confirmCreateFresh, .boot],
                       "a revoked create-fresh must re-adjudicate via .boot, which PREFERS migration over minting an empty ledger (§7.1 decision 5)")
    }

    func testBootIntentReResolveStillCollapsesToBoot() async {
        // Control: the pre-N7.1 behavior for the existing intents is unchanged.
        let fake = FakeRunner()
        fake.outcomes = [.openStore(authorization: .openExistingPlain, residual: nil),
                         .requiresSourceChoice]
        fake.attempts = [.needsReResolve]
        let model = AppModel(runner: fake)
        model.boot()
        await model.currentBootTask?.value
        XCTAssertEqual(fake.receivedIntents, [.boot, .boot])
    }

    // MARK: - End-to-end unreachability pin (production-shaped wiring, real coordinator)

    private func makeCtx() throws -> (config: MigrationCoordinator.Config, staging: URL) {
        func dir(_ name: String) throws -> URL {
            let d = tempRoot.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
            return d
        }
        // The active slot is hardened-open NOFOLLOW territory — canonicalize its root.
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        let slotDir = try dir("ActiveSlot")
        let canonicalSlot = realpath(slotDir.path, &buf).map { URL(fileURLWithPath: String(cString: $0), isDirectory: true) } ?? slotDir
        return (MigrationCoordinator.Config(
                    activeDestination: canonicalSlot.appendingPathComponent(AppPaths.databaseFileName),
                    activeAttachmentsDir: try dir("active-docs"),
                    manifestsDir: try dir("ImportManifests"),
                    workingDirectory: try dir("Work"),
                    preparedRoot: try dir("PreparedImports")),
                try dir("Staging"))
    }

    /// A REAL coordinator whose ingest is the genuine `StagingIngest` relocated into the
    /// test's isolated staging root (the established seam pattern).
    private func makeCoordinator(_ config: MigrationCoordinator.Config, staging: URL) -> MigrationCoordinator {
        MigrationCoordinator(config: config, stagingRootOverride: staging,
                             ingestOverride: { source, id in
            let r = try StagingIngest().ingest(source, importID: id, timestamp: "t")
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let dst = staging.appendingPathComponent("import-\(id.rawValue)", isDirectory: true)
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

    /// An AVAILABLE v0 source tree carrying a distinguishing marker attachment, so tests can
    /// prove WHICH source a chain actually ingested.
    private func makeMarkedSource(_ name: String, marker: String) throws -> MigrationSource {
        let src = tempRoot.appendingPathComponent(name, isDirectory: true)
        let docs = src.appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent("docs", isDirectory: true)
        try fm.createDirectory(at: docs, withIntermediateDirectories: true)
        let db = try SQLiteDatabase(path: src.appendingPathComponent(AppPaths.databaseFileName).path,
                                    mode: .readWriteCreate)
        try db.execute("PRAGMA journal_mode = DELETE")
        try db.execute("PRAGMA user_version = 0")
        try db.close()
        try Data(marker.utf8).write(to: docs.appendingPathComponent("\(marker).pdf"))
        return .userSelectedDataDir(src)
    }

    /// A production-shaped model whose auto candidate is UNAVAILABLE — a first launch with no
    /// discoverable Electron data. N7.2: it must land in the source choice, not a fresh ledger.
    private func makeCleanSlotModel(_ config: MigrationCoordinator.Config, staging: URL) -> AppModel {
        AppModel(runner: AppModel.makeBootChainRunner(
            coordinator: MigrationCoordinator(config: config, stagingRootOverride: staging,
                                              ingestOverride: nil),
            autoSourceCandidate: .userSelectedDataDir(tempRoot.appendingPathComponent("no-electron-here")),
            activeURL: config.activeDestination))
    }

    func testProductionShapedBootOverCleanSlotLandsInSourceChoiceNeverAFreshLedger() async throws {
        let (config, staging) = try makeCtx()
        let model = makeCleanSlotModel(config, staging: staging)
        model.boot()
        await model.currentBootTask?.value

        guard case .awaitingSourceChoice = model.migrationUIState else {
            return XCTFail("N7.2 REGRESSION: a production-wired clean-slot boot must land in the source choice, got \(model.migrationUIState)")
        }
        XCTAssertNil(model.store, "no ledger may be silently minted before the user chooses a source")
        XCTAssertFalse(model.ready)
        XCTAssertFalse(model.inFlight, "the chain must finish so the user's choice can start cleanly")
        XCTAssertFalse(fm.fileExists(atPath: config.activeDestination.path),
                       "nothing may be created at the active path while awaiting the choice")
    }

    // MARK: - The atomic loop completes: BOTH choices lead out of the source-choice state

    func testConfirmCreateFreshFromSourceChoiceBootsAFreshLedger() async throws {
        let (config, staging) = try makeCtx()
        let model = makeCleanSlotModel(config, staging: staging)
        model.boot()
        await model.currentBootTask?.value
        guard case .awaitingSourceChoice = model.migrationUIState else { return XCTFail("precondition") }

        model.confirmCreateFresh()
        await model.currentBootTask?.value
        XCTAssertTrue(model.ready, "the confirmed create-fresh must complete into a usable empty ledger")
        XCTAssertNotNil(model.store)
        XCTAssertEqual(try model.store?.schemaVersion(), SchemaMigrator.schemaVersion)
        XCTAssertEqual(model.migrationUIState, .none)
    }

    func testMigrateFromUserDirFromSourceChoiceImportsTheChosenSource() async throws {
        // Drives the REAL production runner mapping end-to-end from the source-choice state:
        // the chosen directory (as `.userSelectedDataDir`) is imported by `runImport`, never
        // the auto candidate, and the app becomes ready on the migrated store.
        let (config, staging) = try makeCtx()
        let chosen = try makeMarkedSource("Chosen", marker: "chosen-marker")
        let model = AppModel(runner: AppModel.makeBootChainRunner(
            coordinator: makeCoordinator(config, staging: staging),
            autoSourceCandidate: .userSelectedDataDir(tempRoot.appendingPathComponent("no-electron-here")),
            activeURL: config.activeDestination))
        model.boot()
        await model.currentBootTask?.value
        guard case .awaitingSourceChoice = model.migrationUIState else { return XCTFail("precondition") }

        model.migrateFromUserDir(source: chosen)
        await model.currentBootTask?.value
        XCTAssertTrue(model.ready, "the explicit migration must complete into a usable migrated ledger")
        XCTAssertNotNil(model.store)
        XCTAssertEqual(try Data(contentsOf: config.activeAttachmentsDir.appendingPathComponent("chosen-marker.pdf")),
                       Data("chosen-marker".utf8),
                       "the CHOSEN source must be the one imported")
    }

    // MARK: - Directory-picker contract (§3.1/§6)

    func testMigrationSourcePanelConfiguredForSingleDirectoryChoice() {
        let panel = AppModel.makeMigrationSourceDirectoryPanel(message: "prompt-copy")
        XCTAssertTrue(panel.canChooseDirectories, "the migration-source picker must choose DIRECTORIES")
        XCTAssertFalse(panel.canChooseFiles, "the migration-source picker must never choose files")
        XCTAssertFalse(panel.allowsMultipleSelection, "exactly one directory may be granted")
        XCTAssertEqual(panel.message, "prompt-copy")
    }

    /// Boot a FakeRunner model into `.awaitingSourceChoice` (one `.boot` intent consumed).
    private func makeAwaitingChoiceModel(_ fake: FakeRunner) async -> AppModel {
        fake.outcomes = [.requiresSourceChoice]
        let model = AppModel(runner: fake)
        model.boot()
        await model.currentBootTask?.value
        return model
    }

    func testMigrationSourcePanelCancelFiresNoIntentAndStaysOnChoice() async {
        let fake = FakeRunner()
        let model = await makeAwaitingChoiceModel(fake)
        model.handleMigrationSourcePanelResult(.cancel, url: nil)
        model.handleMigrationSourcePanelResult(.abort, url: nil)
        model.handleMigrationSourcePanelResult(.OK, url: nil)   // OK without a URL is also a no-op
        XCTAssertEqual(fake.receivedIntents, [.boot],
                       "cancelling the directory panel must fire ZERO intents — a pure no-op")
        guard case .awaitingSourceChoice = model.migrationUIState else {
            return XCTFail("cancel must stay on the source-choice screen, got \(model.migrationUIState)")
        }
        XCTAssertFalse(model.inFlight)
    }

    func testMigrationSourcePanelOKEmitsExactlyMigrateFromUserDir() async {
        let fake = FakeRunner()
        let model = await makeAwaitingChoiceModel(fake)
        let chosen = sourceURL("GrantedDir")
        model.handleMigrationSourcePanelResult(.OK, url: chosen)
        await model.currentBootTask?.value
        XCTAssertEqual(fake.receivedIntents, [.boot, .migrateFromUserDir(.userSelectedDataDir(chosen))],
                       "a confirmed directory must emit exactly .migrateFromUserDir(.userSelectedDataDir) — never a plain boot (which would re-inject the auto candidate) and never a bare URL")
    }

    func testConfirmCreateFreshEmitsExactlyTheConfirmIntent() async {
        let fake = FakeRunner()
        let model = await makeAwaitingChoiceModel(fake)
        model.confirmCreateFresh()
        await model.currentBootTask?.value
        XCTAssertEqual(fake.receivedIntents, [.boot, .confirmCreateFresh],
                       "the confirmed create action must emit exactly .confirmCreateFresh — no other intent, no boolean side channel")
    }

    // MARK: - Production mapping guards (the REAL makeBootChainRunner, no hand-copied switch)

    func testProductionMappingMigrateFromUserDirRunsExplicitImportWithChosenSource() async throws {
        let (config, staging) = try makeCtx()
        let chosen = try makeMarkedSource("Chosen", marker: "chosen-marker")
        let autoTrap = try makeMarkedSource("AutoTrap", marker: "auto-trap")
        let runner = AppModel.makeBootChainRunner(
            coordinator: makeCoordinator(config, staging: staging),
            autoSourceCandidate: autoTrap,   // a live decoy: any silent reroute would import THIS
            activeURL: config.activeDestination)

        let outcome = await runner.resolveOutcome(.migrateFromUserDir(chosen))
        guard case .openStore(let auth, _) = outcome, case .openExistingCompleted = auth else {
            return XCTFail("the shipped mapping must run the explicit import to completion, got \(outcome)")
        }
        let applied = config.activeAttachmentsDir
        XCTAssertEqual(try Data(contentsOf: applied.appendingPathComponent("chosen-marker.pdf")),
                       Data("chosen-marker".utf8),
                       "the CHOSEN source must be the one ingested — the user's selection may never be lost")
        XCTAssertFalse(fm.fileExists(atPath: applied.appendingPathComponent("auto-trap.pdf").path),
                       "the auto candidate must NOT be imported: .migrateFromUserDir goes to runImport(source:), never bootResolve/auto")
    }

    func testProductionMappingConfirmCreateFreshDoesNotAbsorbAutoCandidate() async throws {
        let (config, staging) = try makeCtx()
        let availableAuto = try makeMarkedSource("AvailableAuto", marker: "auto-live")
        let runner = AppModel.makeBootChainRunner(
            coordinator: makeCoordinator(config, staging: staging),
            autoSourceCandidate: availableAuto,
            activeURL: config.activeDestination)

        // Divergence pin: with an AVAILABLE auto candidate on a clean disk, `bootResolve(auto)`
        // would run the WHOLE import (→ .openExistingCompleted). The strong-typed
        // confirmCreateFresh entry consults no candidate → the createFresh authorization.
        let outcome = await runner.resolveOutcome(.confirmCreateFresh)
        guard case .openStore(let auth, nil) = outcome, case .createFreshExpectedAbsent = auth else {
            return XCTFail(".confirmCreateFresh must map to the strong-typed confirmCreateFresh entry (createFresh authorization) — got \(outcome), which means the mapping absorbed the auto candidate (bootResolve wiring)")
        }
        XCTAssertFalse(fm.fileExists(atPath: config.activeDestination.path),
                       "resolution must not have imported or created anything")
    }

    func testProductionMappingConfirmStageStillPassesAutoCandidateForRevocation() throws {
        let (config, staging) = try makeCtx()
        let availableAuto = try makeMarkedSource("AvailableAuto", marker: "auto-live")
        let runner = AppModel.makeBootChainRunner(
            coordinator: makeCoordinator(config, staging: staging),
            autoSourceCandidate: availableAuto,
            activeURL: config.activeDestination)

        // Phase B of a createFresh authorization: the shipped confirm closure must hand the
        // auto candidate to confirmOpenAuthorization, which revokes createFresh when the
        // candidate is available (re-adjudication prefers migration, §7.1 decision 5).
        let attempt = runner.attempt(.createFreshExpectedAbsent, residual: nil)
        guard case .needsReResolve = attempt else {
            return XCTFail("an AVAILABLE auto candidate must revoke the createFresh authorization at confirm (needsReResolve); got \(attempt) — the confirm closure dropped the auto candidate")
        }
        XCTAssertFalse(fm.fileExists(atPath: config.activeDestination.path),
                       "a revoked authorization must not create the fresh store")
    }
}
