import XCTest
@testable import SoloLedger
@testable import SoloLedgerCore

/// 2B-3 C12b-2: AppModel production-boot orchestration over the C12 coordinator seam.
/// Hosted unit tests (`@testable import SoloLedger`) drive a scripted `BootChainRunner` to
/// exercise single-flight, generation, the off-main/main-actor split, bounded reResolve,
/// atomic adoption and typed error mapping — deterministically, with no real container I/O.
@MainActor
final class AppModelBootTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SLBootTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    private func tempURL(_ name: String) -> URL { tempDir.appendingPathComponent(name) }

    // MARK: - Test doubles

    /// Reference flag so a `@Sendable` probe closure can report the thread it ran on.
    private final class ThreadFlag: @unchecked Sendable { var wasMain = true }
    private enum TestError: Error { case boom }

    /// An async gate so a test can hold a chain in-flight while it exercises other intents.
    private actor Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var opened = false
        func wait() async {
            if opened { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func open() { opened = true; continuation?.resume(); continuation = nil }
    }

    /// Scripts Phase-A outcomes, Phase-B attempts, completion timing, and records intents.
    private final class FakeRunner: BootChainRunner {
        var outcomes: [BootOutcome] = []
        var attempts: [MigrationBootDriver.Attempt] = []
        private(set) var resolveCount = 0
        private(set) var attemptCount = 0
        private(set) var receivedIntents: [BootIntent] = []
        /// Runs inside `resolveOutcome` before it returns (e.g. to gate / simulate supersession).
        var duringResolve: ((Int) async -> Void)?

        @MainActor func resolveOutcome(_ intent: BootIntent) async -> BootOutcome {
            receivedIntents.append(intent)
            let idx = resolveCount
            resolveCount += 1
            if let hook = duringResolve { await hook(idx) }
            guard !outcomes.isEmpty else { return .blocked(MigrationBlock(code: .internalError, classification: .terminal)) }
            return outcomes[Swift.min(idx, outcomes.count - 1)]
        }

        @MainActor func attempt(_ authorization: StoreOpenAuthorization,
                                residual: MigrationResidual?) -> MigrationBootDriver.Attempt {
            let idx = attemptCount
            attemptCount += 1
            guard !attempts.isEmpty else { return .ui(.terminal(MigrationBlock(code: .internalError, classification: .terminal))) }
            return attempts[Swift.min(idx, attempts.count - 1)]
        }
    }

    private func terminalOutcome() -> BootOutcome {
        .blocked(MigrationBlock(code: .stagingTampered, classification: .terminal))
    }
    private func openStoreOutcome(_ auth: StoreOpenAuthorization = .createFreshExpectedAbsent,
                                  residual: MigrationResidual? = nil) -> BootOutcome {
        .openStore(authorization: auth, residual: residual)
    }

    // MARK: - Running / single-flight / generation

    func testBootImmediatelyEntersRunning() {
        let fake = FakeRunner(); fake.outcomes = [terminalOutcome()]
        let model = AppModel(runner: fake)
        model.boot()
        guard case .running(.resolving) = model.migrationUIState else {
            return XCTFail("boot must immediately enter .running(.resolving)")
        }
        XCTAssertTrue(model.inFlight)
    }

    func testHardSingleFlightIgnoresSecondClick() async {
        let fake = FakeRunner(); fake.outcomes = [terminalOutcome()]
        let model = AppModel(runner: fake)
        model.boot()
        XCTAssertEqual(model.bootGeneration, 1)
        model.boot()   // rejected while inFlight — must change nothing
        XCTAssertEqual(model.bootGeneration, 1, "a rejected click must not advance generation")
        await model.currentBootTask?.value
        XCTAssertEqual(fake.resolveCount, 1, "only one chain may run")
        XCTAssertEqual(fake.attemptCount, 0)
        XCTAssertFalse(model.inFlight, "inFlight must clear after completion")
        guard case .terminal = model.migrationUIState else { return XCTFail("first result must be applied") }
    }

    func testStaleGenerationResultNotPublished() async {
        let fake = FakeRunner(); fake.outcomes = [terminalOutcome()]
        let model = AppModel(runner: fake)
        fake.duringResolve = { [weak model] _ in
            await MainActor.run { model?.bootGeneration += 1 }   // simulate supersession mid-resolve
        }
        model.boot()
        await model.currentBootTask?.value
        guard case .running(.resolving) = model.migrationUIState else {
            return XCTFail("a stale-generation result must not be published; got \(model.migrationUIState)")
        }
        XCTAssertNil(model.store)
        XCTAssertFalse(model.ready)
        XCTAssertTrue(model.inFlight, "a stale chain must NOT clear the new generation's inFlight ownership")
    }

    // MARK: - Thread boundaries (production runner)

    func testProductionPhaseARunsOffTheMainActor() async {
        let probe = ThreadFlag()
        let runner = ProductionBootChainRunner(
            resolveWork: { _ in probe.wasMain = Thread.isMainThread
                               return .blocked(MigrationBlock(code: .ioTransient, classification: .retriable)) },
            confirm: { _ in .proceed },
            openStore: { _ in throw TestError.boom })
        _ = await runner.resolveOutcome(.boot)
        XCTAssertFalse(probe.wasMain, "Phase A resolveWork must run OFF the main thread")
    }

    func testProductionPhaseBFactoryRunsOnTheMainActor() throws {
        let probe = ThreadFlag(); probe.wasMain = false
        let url = tempURL("pb.db")
        let runner = ProductionBootChainRunner(
            resolveWork: { _ in .blocked(MigrationBlock(code: .ioTransient, classification: .retriable)) },
            confirm: { _ in .proceed },
            openStore: { intent in probe.wasMain = Thread.isMainThread
                                    return try LedgerStore(databaseURL: url, open: intent) })
        let attempt = runner.attempt(.createFreshExpectedAbsent, residual: nil)
        guard case .opened = attempt else { return XCTFail("expected opened") }
        XCTAssertTrue(probe.wasMain, "Phase B store factory must run ON the main thread")
    }

    // MARK: - bounded reResolve

    func testFirstReResolveRerunsSecondMapsInterference() async {
        let fake = FakeRunner()
        fake.outcomes = [openStoreOutcome(), openStoreOutcome()]     // resolve #1 and the reResolve rerun #2
        fake.attempts = [.needsReResolve, .needsReResolve]           // both attempts ask to re-resolve
        let model = AppModel(runner: fake)
        model.boot()
        await model.currentBootTask?.value
        guard case .retriable(let block) = model.migrationUIState else {
            return XCTFail("second reResolve must map to retriable(.interference); got \(model.migrationUIState)")
        }
        XCTAssertEqual(block.code, .interference)
        XCTAssertEqual(fake.resolveCount, 2, "reResolve must re-run Phase A exactly once")
        XCTAssertEqual(fake.attemptCount, 2)
        XCTAssertEqual(fake.receivedIntents, [.boot, .boot], "the reResolve rerun must use a .boot intent")
        XCTAssertNil(model.store)
        XCTAssertFalse(model.ready)
    }

    // MARK: - non-openStore outcomes never construct a store

    func testBlockedAndSelectionNeverConstructStore() async {
        let cases: [BootOutcome] = [
            terminalOutcome(),
            .requiresImportSelection([]),
            .requiresAcknowledgement(request: AcknowledgementRequest(importID: "i",
                                                                     snapshotIdentitySHA256: "s",
                                                                     attachmentManifestSHA256: "a",
                                                                     preparedDBIdentity: "sha256:p",
                                                                     unresolvedReportHash: "h"),
                                     unresolved: UnresolvedReport(items: [])),
        ]
        for outcome in cases {
            let fake = FakeRunner(); fake.outcomes = [outcome]
            let model = AppModel(runner: fake)
            model.boot()
            await model.currentBootTask?.value
            XCTAssertEqual(fake.attemptCount, 0, "a non-openStore outcome must never attempt a store open: \(outcome)")
            XCTAssertNil(model.store)
            XCTAssertFalse(model.ready)
            XCTAssertNil(model.bootError, "production path must never write a raw bootError")
        }
    }

    // MARK: - atomic adoption

    func testAtomicAdoptionFailureDoesNotHalfPublish() async throws {
        let url = tempURL("adopt.db")
        let candidate = try LedgerStore(databaseURL: url, open: .createIfMissing)
        try candidate.db.close()   // subsequent settings reads throw → adoption must fail closed
        let fake = FakeRunner()
        fake.outcomes = [openStoreOutcome()]
        fake.attempts = [.opened(candidate, nil)]
        let model = AppModel(runner: fake)
        model.boot()
        await model.currentBootTask?.value
        XCTAssertNil(model.store, "a failed adoption must not half-publish the store")
        XCTAssertFalse(model.ready)
        guard case .retriable(let block) = model.migrationUIState else {
            return XCTFail("adoption failure must map to retriable(.storeOpenFailed); got \(model.migrationUIState)")
        }
        XCTAssertEqual(block.code, .storeOpenFailed)
        XCTAssertNil(model.bootError)
    }

    func testCleanupResidualPublishesStoreReadyWithResidual() async throws {
        let url = tempURL("residual.db")
        let candidate = try LedgerStore(databaseURL: url, open: .createIfMissing)
        let residual = MigrationResidual(importID: "leftover-9")
        let fake = FakeRunner()
        fake.outcomes = [openStoreOutcome(residual: residual)]
        fake.attempts = [.opened(candidate, residual)]
        let model = AppModel(runner: fake)
        model.boot()
        await model.currentBootTask?.value
        XCTAssertNotNil(model.store)
        XCTAssertTrue(model.ready, "cleanupResidual is non-blocking — the store opens and ready is true")
        guard case .cleanupResidual(let r) = model.migrationUIState else {
            return XCTFail("expected cleanupResidual; got \(model.migrationUIState)")
        }
        XCTAssertEqual(r.importID, "leftover-9")
    }

    func testSuccessfulAdoptionSetsReadyAndNoneState() async throws {
        let url = tempURL("ok.db")
        let candidate = try LedgerStore(databaseURL: url, open: .createIfMissing)
        let fake = FakeRunner()
        fake.outcomes = [openStoreOutcome()]
        fake.attempts = [.opened(candidate, nil)]
        let model = AppModel(runner: fake)
        model.boot()
        await model.currentBootTask?.value
        XCTAssertNotNil(model.store)
        XCTAssertTrue(model.ready)
        XCTAssertEqual(model.migrationUIState, .none)
        XCTAssertEqual(model.ready, model.store != nil, "invariant: ready == (store != nil)")
    }

    // MARK: - typed error mapping

    func testStoreOpenFailureMapsToRetriable() async {
        let fake = FakeRunner()
        fake.outcomes = [openStoreOutcome(.openExistingPlain)]
        fake.attempts = [.ui(.retriable(MigrationBlock(code: .storeOpenFailed, classification: .retriable)))]
        let model = AppModel(runner: fake)
        model.boot()
        await model.currentBootTask?.value
        guard case .retriable(let block) = model.migrationUIState else { return XCTFail() }
        XCTAssertEqual(block.code, .storeOpenFailed)
        XCTAssertNil(model.store)
        XCTAssertNil(model.bootError)
    }

    // MARK: - legacy isolation

    func testCoordinatorBootDoesNotPopulateLegacyMigrationFailure() async {
        let fake = FakeRunner(); fake.outcomes = [terminalOutcome()]
        let model = AppModel(runner: fake)
        model.boot()
        await model.currentBootTask?.value
        XCTAssertNil(model.migrationFailure, "the coordinator path must not touch the legacy migrationFailure state")
        XCTAssertNil(model.bootError, "production errors never fall into bootError")
        guard case .terminal = model.migrationUIState else { return XCTFail() }
    }

    func testStartChainClearsLegacyMigrationFailure() async {
        let fake = FakeRunner(); fake.outcomes = [terminalOutcome()]
        let model = AppModel(runner: fake)
        model.migrationFailure = "old legacy DatabaseUpgrade failure"
        model.boot()
        XCTAssertNil(model.migrationFailure, "a new C12 chain must clear the legacy recovery screen (mutual exclusion)")
        guard case .running(.resolving) = model.migrationUIState else { return XCTFail() }
        await model.currentBootTask?.value
    }

    func testLegacyRecoveryAllowedGuardTracksChainAndStore() async {
        let gate = Gate()
        let fake = FakeRunner(); fake.outcomes = [terminalOutcome()]
        fake.duringResolve = { idx in if idx == 0 { await gate.wait() } }
        let model = AppModel(runner: fake)
        XCTAssertTrue(model.legacyRecoveryAllowed, "allowed before any chain (not in flight, no store)")
        model.boot()
        XCTAssertFalse(model.legacyRecoveryAllowed, "legacy recovery must be rejected while a C12 chain is in flight")
        await gate.open()
        await model.currentBootTask?.value
        XCTAssertTrue(model.legacyRecoveryAllowed, "allowed again after a terminal chain (no store opened)")
    }

    func testRetryMigrationRejectedDuringChain() async {
        let gate = Gate()
        let fake = FakeRunner(); fake.outcomes = [terminalOutcome()]
        fake.duringResolve = { idx in if idx == 0 { await gate.wait() } }
        let model = AppModel(runner: fake)
        model.boot()                                   // in-flight (inFlight set synchronously)
        model.migrationFailure = "preset-during-chain" // a value a bypassing legacy intent would wrongly clear
        let genBefore = model.bootGeneration
        model.retryMigration()                         // must be rejected — legacyRecoveryAllowed == false
        XCTAssertEqual(model.migrationFailure, "preset-during-chain", "a rejected retryMigration must not clear migrationFailure")
        XCTAssertEqual(model.bootGeneration, genBefore, "a rejected legacy intent must not advance generation")
        XCTAssertNil(model.store)
        await gate.open()
        await model.currentBootTask?.value
        XCTAssertEqual(fake.resolveCount, 1, "retryMigration must not have started a second chain")
    }

    // MARK: - intent fidelity

    func testRetryProbeUsesBootIntent() async {
        let fake = FakeRunner(); fake.outcomes = [terminalOutcome()]
        let model = AppModel(runner: fake)
        model.retryProbe()
        await model.currentBootTask?.value
        XCTAssertEqual(fake.receivedIntents, [.boot])
    }

    func testSubmitAcknowledgementPassesExactIntent() async {
        let fake = FakeRunner(); fake.outcomes = [terminalOutcome()]
        let model = AppModel(runner: fake)
        let ack = AcknowledgementRequest(importID: "ack-import", snapshotIdentitySHA256: "s",
                                         attachmentManifestSHA256: "a", preparedDBIdentity: "sha256:p",
                                         unresolvedReportHash: "h").acknowledge()
        model.submitAcknowledgement(ack)
        await model.currentBootTask?.value
        XCTAssertEqual(fake.receivedIntents, [.acknowledgement(ack)])
    }

    func testResolveImportSelectionPassesExactImportID() async {
        let fake = FakeRunner(); fake.outcomes = [terminalOutcome()]
        let model = AppModel(runner: fake)
        model.resolveImportSelection(importID: "imp-42")
        await model.currentBootTask?.value
        XCTAssertEqual(fake.receivedIntents, [.selection("imp-42")])
    }

    func testCancelImportSelectionLandsTerminalWithoutSideEffects() async {
        let fake = FakeRunner(); fake.outcomes = [.requiresImportSelection([])]
        let model = AppModel(runner: fake)
        model.boot()
        await model.currentBootTask?.value
        guard case .awaitingImportSelection = model.migrationUIState else { return XCTFail("expected awaitingImportSelection") }
        let resolveBefore = fake.resolveCount, attemptBefore = fake.attemptCount
        model.cancelImportSelection()
        guard case .terminal(let block) = model.migrationUIState else { return XCTFail("cancel must land terminal") }
        XCTAssertEqual(block.code, .invalidSelection)
        XCTAssertEqual(block.params["reason"], "userCancelled")
        XCTAssertEqual(fake.resolveCount, resolveBefore, "cancel must not resolve")
        XCTAssertEqual(fake.attemptCount, attemptBefore, "cancel must not attempt a store open")
        XCTAssertNil(model.store, "cancel must not construct or auto-select a store")
    }

    func testCancelImportSelectionIsNoOpOutsideSelection() {
        let fake = FakeRunner()
        let model = AppModel(runner: fake)
        model.cancelImportSelection()   // migrationUIState is .none
        XCTAssertEqual(model.migrationUIState, .none, "cancel is a no-op outside awaitingImportSelection")
    }
}
