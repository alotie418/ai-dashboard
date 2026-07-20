import XCTest
@testable import SoloLedger
@testable import SoloLedgerCore

/// N7.1 App-hosted guards (design §1.2/§7.1/§11.1): the two DORMANT boot intents
/// (`.confirmCreateFresh`, `.migrateFromUserDir`), the `.awaitingSourceChoice` waiting state's
/// store-free invariants, the §7.1(a) reResolve stickiness of an explicit user source, and the
/// end-to-end UNREACHABILITY pin — a production-shaped boot over a clean slot still lands in
/// the old create-fresh behavior, never the source-choice state.
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

    func testProductionShapedBootOverCleanSlotStillCreatesFreshNeverSourceChoice() async throws {
        let (config, staging) = try makeCtx()
        let coordinator = MigrationCoordinator(config: config, stagingRootOverride: staging,
                                               ingestOverride: nil)
        // An auto candidate that is UNAVAILABLE — the exact precondition N7.2 will one day
        // flip into the source-choice screen. Today it MUST still mint a fresh ledger.
        let auto = MigrationSource.userSelectedDataDir(tempRoot.appendingPathComponent("no-electron-here"))
        let activeURL = config.activeDestination
        let runner = ProductionBootChainRunner(
            resolveWork: { intent in
                switch intent {
                case .boot: return coordinator.bootResolve(autoSourceCandidate: auto)
                case .acknowledgement(let ack): return coordinator.bootResolve(autoSourceCandidate: auto, acknowledgement: ack)
                case .selection(let id): return coordinator.resolveSelectedImport(importID: id)
                case .confirmCreateFresh: return coordinator.confirmCreateFresh()
                case .migrateFromUserDir(let source): return coordinator.runImport(source: source)
                }
            },
            confirm: { coordinator.confirmOpenAuthorization($0, autoSourceCandidate: auto) },
            openStore: { try AppModel.openStoreForPlan($0, activeURL: activeURL) })
        let model = AppModel(runner: runner)
        model.boot()
        await model.currentBootTask?.value

        if case .awaitingSourceChoice = model.migrationUIState {
            return XCTFail("N7.1 REGRESSION: a production-shaped clean-slot boot reached the source-choice state — resolveB1 must stay unflipped until N7.2")
        }
        XCTAssertTrue(model.ready, "the OLD behavior must hold: a clean slot boots into a fresh ledger")
        XCTAssertNotNil(model.store)
        XCTAssertEqual(try model.store?.schemaVersion(), SchemaMigrator.schemaVersion)
    }
}
