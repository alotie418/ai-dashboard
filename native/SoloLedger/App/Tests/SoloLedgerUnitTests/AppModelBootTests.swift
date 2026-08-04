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
            confirm: { _ in .proceed(.createFresh) },
            openStore: { _ in throw TestError.boom })
        _ = await runner.resolveOutcome(.boot)
        XCTAssertFalse(probe.wasMain, "Phase A resolveWork must run OFF the main thread")
    }

    func testProductionPhaseBFactoryRunsOnTheMainActor() throws {
        let probe = ThreadFlag(); probe.wasMain = false
        let url = tempURL("pb.db")
        let runner = ProductionBootChainRunner(
            resolveWork: { _ in .blocked(MigrationBlock(code: .ioTransient, classification: .retriable)) },
            confirm: { _ in .proceed(.createFresh) },
            openStore: { plan in probe.wasMain = Thread.isMainThread
                                  guard case .createFresh = plan else { throw TestError.boom }
                                  return try LedgerStore(databaseURL: url, open: .createIfMissing) })
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

    // MARK: - production wiring: an existing plan takes the C12x HARDENED open (not existingOnly)

    /// Drives the REAL production dispatch `AppModel.openStoreForPlan` (the exact mapping
    /// `makeProductionRunner` ships) against an isolated temp path: an `.existing` plan MUST use
    /// the hardened NOFOLLOW open and refuse a leaf-symlink identity attack, leaving the decoy
    /// target untouched. Reverting the `.existing` branch to `LedgerStore(open: .existingOnly)`
    /// makes the open follow the symlink and NOT throw — which fails this test.
    func testProductionExistingPlanUsesHardenedOpenAndRejectsSymlink() throws {
        let fm = FileManager.default
        // temporaryDirectory is under /var/folders (a /var symlink); canonicalize so whole-path
        // NOFOLLOW is not tripped by an ancestor symlink (production active path is symlink-free).
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        _ = realpath(tempDir.path, &buf)
        let dir = URL(fileURLWithPath: String(cString: buf), isDirectory: true)

        let url = dir.appendingPathComponent("active.db")
        let s = try LedgerStore(databaseURL: url, open: .createIfMissing)
        try s.db.execute("PRAGMA wal_checkpoint(TRUNCATE)"); try s.db.close()
        try? fm.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))
        try? fm.removeItem(at: URL(fileURLWithPath: url.path + "-shm"))
        guard case .captured(let ev) = MigrationCoordinator.captureActiveEvidence(activeDestination: url) else {
            return XCTFail("evidence capture failed")
        }
        // The decoy DB the attacker points the active leaf at.
        let decoy = dir.appendingPathComponent("decoy.db")
        let d = try LedgerStore(databaseURL: decoy, open: .createIfMissing); try d.db.close()
        let decoyBefore = try Data(contentsOf: decoy)
        try fm.removeItem(at: url)
        try fm.createSymbolicLink(at: url, withDestinationURL: decoy)

        XCTAssertThrowsError(try AppModel.openStoreForPlan(.existing(ev), activeURL: url)) { e in
            guard case HardenedOpenError.identity(.unsupportedSymlinkedActivePath) = e else {
                return XCTFail("production existing plan must take the hardened NOFOLLOW open, got \(e)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: decoy), decoyBefore, "the symlink target must never be opened or written")
    }

    // MARK: - production wiring: a createFresh plan takes the C12x-A2 exclusive reservation

    /// Drives the REAL production dispatch for `.createFresh` against an isolated temp path with a
    /// pre-placed regular-DB squatter: it MUST fail closed with `freshCollision` (the exclusive
    /// reservation), never open+migrate the squatter. Reverting the `.createFresh` branch to
    /// `LedgerStore(open: .createIfMissing)` opens the squatter and does NOT throw — failing this test.
    func testProductionCreateFreshPlanUsesReservationAndRejectsSquatter() throws {
        let fm = FileManager.default
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        _ = realpath(tempDir.path, &buf)
        let dir = URL(fileURLWithPath: String(cString: buf), isDirectory: true)

        let url = dir.appendingPathComponent("fresh-active.db")
        let squatter = try LedgerStore(databaseURL: url, open: .createIfMissing)   // a valid DB squats the name
        try squatter.db.execute("PRAGMA wal_checkpoint(TRUNCATE)"); try squatter.db.close()
        try? fm.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))
        try? fm.removeItem(at: URL(fileURLWithPath: url.path + "-shm"))
        let before = try Data(contentsOf: url)

        XCTAssertThrowsError(try AppModel.openStoreForPlan(.createFresh, activeURL: url)) { e in
            guard case HardenedOpenError.freshCollision = e else {
                return XCTFail("production createFresh plan must take the exclusive reservation, got \(e)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: url), before, "the squatter DB must not be opened or migrated")
    }

    // MARK: - P4b: onboarding seeds a currency ONLY into a provably-empty ledger

    private func freshStore(_ name: String) throws -> LedgerStore {
        try LedgerStore(databaseURL: tempURL(name), open: .createIfMissing)
    }

    /// A model booted onto `store` through the real adoption path, so `transactions`,
    /// `legacyLedger` and `legacyProbeFailed` are populated exactly as they are in production
    /// by the time the onboarding screen can be submitted.
    private func booted(_ store: LedgerStore) async -> AppModel {
        let fake = FakeRunner()
        fake.outcomes = [openStoreOutcome()]
        fake.attempts = [.opened(store, nil)]
        let model = AppModel(runner: fake)
        model.boot()
        await model.currentBootTask?.value
        return model
    }

    /// `String??`: outer nil = the read failed, `.some(nil)` = the read succeeded and the row
    /// is absent. The distinction is the point — see `seedCurrencyIfProvablyNew`.
    private func currencyRow(_ store: LedgerStore) -> String?? {
        try? store.settings.rawValue(SettingsStore.Key.currency)
    }

    /// `OnboardingView.finish`'s submit sequence, minus the language / company writes that
    /// play no part here.
    private func finishOnboarding(_ model: AppModel, regime: AccountingLocale) {
        model.setAccountingLocale(regime)
        model.completeOnboarding()
    }

    private func aTransaction(_ store: LedgerStore, currency: String = "CNY",
                              date: String = "2025-03-01") throws {
        try store.create(Transaction(type: .income, date: date, amount: 1_000, currency: currency))
    }

    /// One legacy sale with no `legacy_migrations` mapping — `holdsHiddenRecords` becomes true
    /// while the `transactions` table this app reads stays empty. The shape that looks empty
    /// and is not.
    private func anUnconvertedLegacySale(_ store: LedgerStore) throws {
        _ = try store.db.run(
            "INSERT INTO sales (id, date, customer, totalAmount) VALUES (?, ?, ?, ?)",
            [.text("legacy-1"), .text("2025-03-01"), .text("someone"), .real(1_000)])
    }

    // T1 ────────────────────────────────────────────────────────────────────────────────
    func testT1OnboardingSeedsTheRegimeCurrencyOnAProvablyNewLedger() async throws {
        // CN first and isolated, because the DEFAULT regime is the one that does NOT cascade
        // (`shouldApplyPresets` is false for CN → CN). On this path the row can only have come
        // from the seed — which is exactly the case the user hit.
        let cn = try freshStore("t1-cn.db")
        let cnModel = await booted(cn)
        XCTAssertEqual(currencyRow(cn), .some(.none), "a fresh ledger carries no currency row")
        cnModel.setAccountingLocale(.CN)
        XCTAssertEqual(currencyRow(cn), .some(.none),
                       "the unchanged-regime path must still not have written a currency")
        cnModel.completeOnboarding()
        XCTAssertEqual(try cn.settings.string(SettingsStore.Key.currency), "CNY")
        try cn.db.close()

        // And the end state holds for all six. For the other five the regime cascade writes it;
        // either way the ledger leaves onboarding stating the currency it displayed.
        for regime in AccountingLocale.allCases {
            let store = try freshStore("t1-\(regime.rawValue).db")
            let model = await booted(store)
            finishOnboarding(model, regime: regime)
            XCTAssertEqual(try store.settings.string(SettingsStore.Key.currency),
                           AccountingProfile.profile(for: regime).currency, "\(regime)")
            try store.db.close()
        }
    }

    // T2 ────────────────────────────────────────────────────────────────────────────────
    /// Byte-for-byte, and deliberately including the two rows that are NOT decodable as a
    /// currency: those are what `currencyInvalid` puts on screen verbatim.
    func testT2AnExistingCurrencyRowIsNeverTouched() async throws {
        for (index, stored) in ["\"USD\"", "123", "\"\""].enumerated() {
            let store = try freshStore("t2-\(index).db")
            _ = try store.db.run(
                "INSERT INTO settings (key, value, updated_at) VALUES ('currency', ?, datetime('now'))",
                [.text(stored)])
            let model = await booted(store)
            finishOnboarding(model, regime: .CN)
            XCTAssertEqual(try store.settings.rawValue(SettingsStore.Key.currency), stored,
                           "an existing currency row must survive onboarding byte for byte")
            try store.db.close()
        }
    }

    // T3 ────────────────────────────────────────────────────────────────────────────────
    /// Isolates the `holdsHiddenRecords` conjunct: the transactions table IS empty here, so
    /// only the legacy probe can refuse. The build then answers `legacySourceUnavailable`
    /// rather than `currencyNotConfigured` — the source gate comes first, on purpose, and it
    /// is the honest answer for a period whose money may sit in tables this app does not read.
    func testT3AMigratedLedgerWithHiddenLegacyRecordsIsNeverSeeded() async throws {
        let store = try freshStore("t3.db")
        try anUnconvertedLegacySale(store)
        let model = await booted(store)
        XCTAssertTrue(model.transactions.isEmpty)
        XCTAssertTrue(model.legacyLedger.holdsHiddenRecords, "the fixture must present the hidden-records shape")
        finishOnboarding(model, regime: .CN)
        XCTAssertEqual(currencyRow(store), .some(.none), "no currency may be chosen for records this app cannot read")
        guard case .blocked(let blocker) = try ReportBuilder.build(store.db, period: ReportPeriod(year: "2025")) else {
            return XCTFail("a ledger with hidden legacy records must still be refused")
        }
        guard case .legacySourceUnavailable = blocker else {
            return XCTFail("expected legacySourceUnavailable, got \(blocker)")
        }
        try store.db.close()
    }

    // T4 ────────────────────────────────────────────────────────────────────────────────
    /// Isolates the `transactions.isEmpty` conjunct: no legacy rows at all, one real
    /// transaction. The source gate passes, so the refusal is the currency one.
    func testT4ALedgerWithTransactionsIsNeverSeeded() async throws {
        let store = try freshStore("t4.db")
        try aTransaction(store)
        let model = await booted(store)
        XCTAssertFalse(model.transactions.isEmpty)
        XCTAssertFalse(model.legacyLedger.holdsHiddenRecords)
        finishOnboarding(model, regime: .CN)
        XCTAssertEqual(currencyRow(store), .some(.none), "no currency may be chosen for money already recorded")
        guard case .blocked(.currencyNotConfigured) = try ReportBuilder.build(
            store.db, period: ReportPeriod(year: "2025")) else {
            return XCTFail("the currency refusal must still stand")
        }
        try store.db.close()
    }

    // T5 ────────────────────────────────────────────────────────────────────────────────
    /// Isolates the `legacyProbeFailed` conjunct. Renaming the column the unconverted-count
    /// anti-join reads makes `legacyLedgerSummary()` throw while every settings read still
    /// works — so the guard is refusing on "emptiness unproven", not on a dead connection.
    func testT5AFailedLegacyProbeRefusesToSeed() async throws {
        let store = try freshStore("t5.db")
        try store.db.execute("ALTER TABLE legacy_migrations RENAME COLUMN legacy_table TO legacy_table_x")
        let model = await booted(store)
        XCTAssertTrue(model.legacyProbeFailed, "the fixture must actually break the probe")
        XCTAssertTrue(model.transactions.isEmpty, "and must not break the ordinary reads")
        finishOnboarding(model, regime: .CN)
        XCTAssertEqual(currencyRow(store), .some(.none), "unproven emptiness is not emptiness")
        try store.db.close()
    }

    // T5b ───────────────────────────────────────────────────────────────────────────────
    /// Isolates the `products` conjunct that 2b-A4 added, and it is the only one this fixture
    /// lets speak: the transactions table is empty, there are no legacy rows, the probe works,
    /// and `holdsHiddenRecords` is FALSE — because the products page now shows product rows, so
    /// they stopped being hidden records the moment that page landed.
    ///
    /// That is exactly why the conjunct had to be asked separately. The probe answers a question
    /// about VISIBILITY; this predicate asks whether the ledger is provably NEW. A ledger with a
    /// product catalogue is not, however visible it now is — and reading both through one flag
    /// would have loosened this one silently when the other changed.
    func testT5bALedgerHoldingProductsIsNotProvablyNewEvenThoughTheyAreNoLongerHidden() async throws {
        let store = try freshStore("t5b.db")
        _ = try store.createProduct(name: "Steel plate", unit: "kg")
        let model = await booted(store)

        XCTAssertTrue(model.transactions.isEmpty)
        XCTAssertFalse(model.legacyProbeFailed)
        XCTAssertFalse(model.legacyLedger.holdsHiddenRecords,
                       "the fixture must isolate the new conjunct: every OTHER one passes here")
        XCTAssertEqual(model.productCatalogIsProvablyEmpty(store), false)

        finishOnboarding(model, regime: .CN)
        XCTAssertEqual(currencyRow(store), .some(.none),
                       "a ledger carrying a product catalogue is not one this app may write into")
        try store.db.close()
    }

    /// The other direction, so T5b is not merely "the seed never runs": remove the product and
    /// the very same path seeds. An unreadable row counts as a product too — a catalogue this
    /// app could not decode is not an absent one.
    func testT5cAnEmptyCatalogueSeedsAndAnUnreadableRowStillCounts() async throws {
        let empty = try freshStore("t5c-empty.db")
        let emptyModel = await booted(empty)
        XCTAssertEqual(emptyModel.productCatalogIsProvablyEmpty(empty), true)
        finishOnboarding(emptyModel, regime: .CN)
        XCTAssertEqual(currencyRow(empty), .some("\"CNY\""), "the seed still runs when it should")
        try empty.db.close()

        let damaged = try freshStore("t5c-damaged.db")
        // A row with no text reading for its id: counted, never decoded — see `ProductCatalogPage`.
        try damaged.db.run("INSERT INTO products (id, name) VALUES (?, ?)",
                           [.blob(Data([0x00, 0x01])), .text("Widget")])
        let damagedModel = await booted(damaged)
        XCTAssertEqual(try damaged.productCatalog().products.count, 0)
        XCTAssertEqual(try damaged.productCatalog().unreadableCount, 1)
        XCTAssertEqual(damagedModel.productCatalogIsProvablyEmpty(damaged), false)
        finishOnboarding(damagedModel, regime: .CN)
        XCTAssertEqual(currencyRow(damaged), .some(.none),
                       "a catalogue that could not be decoded is not an empty one")
        try damaged.db.close()
    }

    // T6 ────────────────────────────────────────────────────────────────────────────────
    /// The seed writes the currency and nothing else. Asserted on the CN path, because that is
    /// the one where no cascade runs — on a regime CHANGE the three rates are written on
    /// purpose, and this must not be read as a claim about that path.
    func testT6TheSeedWritesNoTaxRateRow() async throws {
        let store = try freshStore("t6.db")
        let model = await booted(store)
        finishOnboarding(model, regime: .CN)
        XCTAssertNotNil(try store.settings.rawValue(SettingsStore.Key.currency))
        for rate in [SettingsStore.Key.vatRate, SettingsStore.Key.surchargeRate,
                     SettingsStore.Key.incomeTaxRate, SettingsStore.Key.adminExpenseAnnual] {
            XCTAssertNil(try store.settings.rawValue(rate),
                         "\(rate) must stay absent — an absent rate is a real state the engines fall back for")
        }
        try store.db.close()
    }

    // T7 ────────────────────────────────────────────────────────────────────────────────
    /// The bug, end to end: a brand-new ledger with a year's worth of one transaction used to
    /// be refused for a currency the onboarding screen had just displayed.
    func testT7AfterOnboardingTheFirstReportIsNoLongerRefusedForACurrency() async throws {
        let store = try freshStore("t7.db")
        let model = await booted(store)
        finishOnboarding(model, regime: .CN)
        try aTransaction(store)
        let outcome = try ReportBuilder.build(store.db, period: ReportPeriod(year: "2025"))
        if case .blocked(let blocker) = outcome {
            if case .currencyNotConfigured = blocker {
                XCTFail("the currency refusal must be gone")
            } else {
                XCTFail("unexpected refusal: \(blocker)")
            }
        }
        try store.db.close()
    }

    // T8 ────────────────────────────────────────────────────────────────────────────────
    /// Idempotent by the first conjunct alone. Proved with a sentinel rather than a timestamp:
    /// `datetime('now')` has one-second resolution and would hide a rewrite.
    func testT8SeedingIsIdempotent() async throws {
        let store = try freshStore("t8.db")
        let model = await booted(store)
        finishOnboarding(model, regime: .CN)
        XCTAssertEqual(try store.settings.string(SettingsStore.Key.currency), "CNY")
        _ = try store.db.run("UPDATE settings SET value = ? WHERE key = 'currency'", [.text("\"ZZZ\"")])
        model.completeOnboarding()
        XCTAssertEqual(try store.settings.rawValue(SettingsStore.Key.currency), "\"ZZZ\"",
                       "a second run must not write again")
        try store.db.close()
    }

    // T9 ────────────────────────────────────────────────────────────────────────────────
    /// A write failure is surfaced, never swallowed — and it does not trap the user in
    /// onboarding. The failure is injected with a trigger so READS keep working: the guard
    /// must reach the write and the write must be the thing that fails.
    func testT9AFailedSeedSurfacesAndStillCompletesOnboarding() async throws {
        let store = try freshStore("t9.db")
        let model = await booted(store)
        model.setAccountingLocale(.CN)
        try store.db.execute("""
            CREATE TRIGGER settings_readonly BEFORE INSERT ON settings
            BEGIN SELECT RAISE(ABORT, 'injected write failure'); END;
            """)
        XCTAssertNil(model.actionError)
        model.completeOnboarding()
        XCTAssertNotNil(model.actionError, "a failed currency write must not be swallowed")
        XCTAssertTrue(model.onboardingDone, "and must not trap the user in onboarding")
        XCTAssertEqual(currencyRow(store), .some(.none))
        try store.db.execute("DROP TRIGGER settings_readonly")
        try store.db.close()
    }

    // MARK: - P4c-1: a damaged regime row is described honestly, and never opens a hole

    /// A U+FEFF before `"US"`. `JSONSerialization` eats it and `JSON.parse` does not, which is
    /// why this one row used to be read as two different countries by two parts of one app.
    private static let bomUS = "\u{FEFF}\"US\""

    private func withDamagedRegime(_ store: LedgerStore, _ raw: String = bomUS) throws {
        _ = try store.db.run("INSERT OR REPLACE INTO settings (key, value) VALUES ('accounting_locale', ?)",
                             [.text(raw)])
    }

    // A1 ────────────────────────────────────────────────────────────────────────────────
    /// The ledger still OPENS. Making the regime read strict enough to throw would turn one
    /// damaged row into a ledger nobody can get into, which is why `accountingLocale()` keeps
    /// its display fallback — and why the honest answer lives beside it rather than replacing it.
    func testA1ADamagedRegimeRowStillOpensAndIsPublishedAsUnreadable() async throws {
        let store = try freshStore("a1.db")
        try withDamagedRegime(store)
        let model = await booted(store)
        XCTAssertNotNil(model.store, "a damaged regime row must not cost the user their ledger")
        XCTAssertTrue(model.ready)
        XCTAssertNil(model.bootError)
        XCTAssertEqual(model.migrationUIState, .none)
        XCTAssertEqual(model.accountingLocale, .US,
                       "the display accessor reads the BOM row as the United States — the very "
                       + "answer the engines refuse to assume")
        XCTAssertEqual(model.accountingLocaleState, .unreadable(storedText: Self.bomUS),
                       "and the truth is published alongside it, bytes intact")
        try store.db.close()
    }

    // A2 ────────────────────────────────────────────────────────────────────────────────
    /// P4b's seed gains the same conjunct for the same reason: a currency chosen from a regime
    /// this app cannot read is a currency nobody chose.
    func testA2AnUnreadableRegimeStopsTheCurrencySeed() async throws {
        let store = try freshStore("a2.db")
        try withDamagedRegime(store)
        let model = await booted(store)
        XCTAssertTrue(model.transactions.isEmpty, "every other conjunct must be satisfied")
        XCTAssertFalse(model.legacyLedger.holdsHiddenRecords)
        XCTAssertFalse(model.legacyProbeFailed)
        model.completeOnboarding()
        XCTAssertEqual(currencyRow(store), .some(.none),
                       "no currency may be seeded off a regime the app cannot read")
        try store.db.close()
    }

    // A3 ────────────────────────────────────────────────────────────────────────────────
    /// Repairing to the regime the screen was already showing writes the regime row and
    /// NOTHING else — `shouldApplyPresets` is false for an unchanged regime, so the three tax
    /// rates the user configured survive the repair.
    func testA3RepairingToTheDisplayedRegimeWritesOnlyTheRegimeRow() async throws {
        let store = try freshStore("a3.db")
        try store.settings.setNumber(3, for: SettingsStore.Key.vatRate)
        try store.settings.setNumber(7, for: SettingsStore.Key.surchargeRate)
        try store.settings.setNumber(11, for: SettingsStore.Key.incomeTaxRate)
        try withDamagedRegime(store)
        let model = await booted(store)
        XCTAssertEqual(model.accountingLocale, .US, "the screen is showing the United States")

        model.setAccountingLocale(.US)          // the regime the screen was showing

        XCTAssertEqual(try store.settings.accountingLocaleState(), .configured(.US),
                       "the damaged row is repaired")
        XCTAssertEqual(model.accountingLocaleState, .configured(.US),
                       "and the published state follows the repair without a relaunch")
        XCTAssertEqual(try store.settings.number(SettingsStore.Key.vatRate), 3)
        XCTAssertEqual(try store.settings.number(SettingsStore.Key.surchargeRate), 7)
        XCTAssertEqual(try store.settings.number(SettingsStore.Key.incomeTaxRate), 11,
                       "an unchanged regime must not cascade over the user's own rates")
        try store.db.close()
    }

    // A4 ────────────────────────────────────────────────────────────────────────────────
    /// Repairing to a DIFFERENT regime cascades, exactly as an ordinary switch does and as
    /// `settings.reportParamsNote` tells the user on screen. Not a regression — the contrast
    /// with A3 is the point.
    func testA4RepairingToADifferentRegimeCascadesLikeAnyOtherSwitch() async throws {
        let store = try freshStore("a4.db")
        try store.settings.setNumber(3, for: SettingsStore.Key.vatRate)
        try withDamagedRegime(store)
        let model = await booted(store)
        XCTAssertEqual(model.accountingLocale, .US, "the screen is showing the United States")

        model.setAccountingLocale(.JP)          // a DIFFERENT regime from the displayed one

        XCTAssertEqual(try store.settings.accountingLocaleState(), .configured(.JP))
        XCTAssertEqual(model.accountingLocaleState, .configured(.JP))
        XCTAssertEqual(try store.settings.number(SettingsStore.Key.vatRate), 10,
                       "a real regime change applies that regime's presets")
        XCTAssertEqual(try store.settings.string(SettingsStore.Key.currency), "JPY")
        try store.db.close()
    }

    // MARK: - P4c-2: the Settings screen tells the truth about the same row (S5–S7)

    // S5 ────────────────────────────────────────────────────────────────────────────────
    /// The notice shows the row's own bytes, through the SAME escape the report page uses —
    /// and the BOM, which is the entire damage here, is now visible in it.
    ///
    /// Two halves, and both matter: the escape makes it LEGIBLE, and the published
    /// `storedText` is still byte for byte what the ledger holds. A preview that tidied the
    /// row would destroy the only evidence the user has.
    func testS5TheNoticeShowsTheStoredBytesThroughTheSharedEscape() async throws {
        let store = try freshStore("s5.db")
        try withDamagedRegime(store)
        let model = await booted(store)
        guard case .unreadable(let storedText) = model.accountingLocaleState else {
            return XCTFail("the fixture must present the unreadable state")
        }
        XCTAssertEqual(Array(storedText.unicodeScalars.map(\.value)),
                       [0xFEFF, 0x22, 0x55, 0x53, 0x22],
                       "the published stored text is the row, verbatim")
        let shown = ReportFormat.safePreview(storedText)
        XCTAssertEqual(shown, "<U+FEFF>\"US\"", "the invisible byte must be made visible")
        XCTAssertNotEqual(shown, ReportFormat.safePreview("\"US\""),
                          "a damaged row must not render like a good one")
        try store.db.close()
    }

    // S6 ────────────────────────────────────────────────────────────────────────────────
    /// A settled ledger sees NOTHING new. Two independent facts, because either alone would
    /// be weak: an ordinary ledger really is `.configured` (so the notice takes its
    /// empty branch), and the three notice keys appear in `SettingsView` only inside the
    /// notice itself — nothing else on that screen can draw them.
    func testS6AConfiguredLedgerDrawsNoneOfTheNewCopy() async throws {
        let store = try freshStore("s6.db")
        let model = await booted(store)
        model.setAccountingLocale(.CN)
        XCTAssertEqual(model.accountingLocaleState, .configured(.CN),
                       "an ordinary ledger is configured, so the notice renders nothing")

        let source = try ReportFixtureBuilder.appSource("Views/SettingsView.swift")
        let notice = try XCTUnwrap(source.range(of: "private struct UnreadableLocaleNotice"))
        let before = String(source[source.startIndex..<notice.lowerBound])
        // The locale notice's OWN keys, which nothing else on the screen may draw.
        // `settings.storedText.label` is deliberately absent from this list since P4d: the
        // damaged-parameter notice legitimately shows the same label, so its position in the
        // file no longer says anything. That notice's own keys are pinned by `testM3…`.
        for key in ["settings.accountingLocale.unreadable.title",
                    "settings.accountingLocale.absent.title",
                    "settings.accountingLocale.repairHint"] {
            XCTAssertFalse(before.contains(key),
                           "\(key) is drawn outside the notice — the settled screen would change")
            XCTAssertTrue(source.contains(key), "\(key) must actually be drawn by the notice")
        }
        XCTAssertTrue(source.contains("settings.storedText.label"),
                      "the shared stored-text label must still be drawn somewhere")
        try store.db.close()
    }

    // S7 ────────────────────────────────────────────────────────────────────────────────
    /// The repair the notice points at, at the two layers a unit test can reach.
    ///
    /// The picker binding is unchanged by P4c-2 — asserted on the source, because the whole
    /// design rests on it: SwiftUI DOES call the setter when the user re-picks the value
    /// already shown (measured before this work), so the existing binding is already a
    /// working repair. What was missing was any reason to use it, which the notice supplies.
    ///
    /// The model half then shows that a same-value call really does write: the `.absent`
    /// ledger below displays the `.CN` fallback, and choosing `.CN` puts the row back.
    func testS7TheUnchangedPickerBindingStillWritesOnASameValueChoice() async throws {
        let source = try ReportFixtureBuilder.appSource("Views/SettingsView.swift")
        XCTAssertTrue(source.contains("get: { model.accountingLocale }, set: { model.setAccountingLocale($0) }"),
                      "the picker binding must stay the one that already repairs the row")

        let store = try freshStore("s7.db")
        _ = try store.db.run("DELETE FROM settings WHERE key = 'accounting_locale'")
        let model = await booted(store)
        XCTAssertEqual(model.accountingLocaleState, .absent)
        XCTAssertEqual(model.accountingLocale, .CN, "the screen shows the fallback")

        model.setAccountingLocale(.CN)          // exactly what re-picking the shown row does

        XCTAssertEqual(model.accountingLocaleState, .configured(.CN),
                       "choosing the displayed regime writes it — a same value is not a no-op")
        XCTAssertEqual(try store.settings.rawValue(SettingsStore.Key.accountingLocale), "\"CN\"")
        try store.db.close()
    }

    // MARK: - P4d: damaged parameter rows are described honestly and never silently deleted

    private func writeRawSetting(_ store: LedgerStore, _ field: ReportParameterField,
                                 _ raw: String) throws {
        _ = try store.db.run("INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)",
                             [.text(field.settingsKey), .text(raw)])
    }

    // M1 ────────────────────────────────────────────────────────────────────────────────
    func testM1ADamagedParameterRowStillOpensAndIsPublishedAsNeedsRepair() async throws {
        let store = try freshStore("m1.db")
        try writeRawSetting(store, .adminExpenseAnnual, "5000元")
        let model = await booted(store)
        XCTAssertNotNil(model.store)
        XCTAssertTrue(model.ready)
        XCTAssertNil(model.bootError)
        XCTAssertNil(model.reportParameters[.adminExpenseAnnual],
                     "the lenient read still answers nil, which renders as an empty field")
        XCTAssertEqual(model.reportParameterStates[.adminExpenseAnnual],
                       .needsRepair(storedText: "5000元"),
                       "and the truth is published alongside it, bytes intact")
        try store.db.close()
    }

    // M2 ────────────────────────────────────────────────────────────────────────────────
    /// Typing a number repairs that row and leaves the other three alone.
    func testM2TypingAValueRepairsOnlyThatRow() async throws {
        let store = try freshStore("m2.db")
        try writeRawSetting(store, .adminExpenseAnnual, "5000元")
        try writeRawSetting(store, .vatRate, "abc")
        try store.settings.setNumber(11, for: SettingsStore.Key.incomeTaxRate)
        let model = await booted(store)

        model.editReportParameter(.adminExpenseAnnual, to: 8000)

        XCTAssertEqual(model.reportParameterStates[.adminExpenseAnnual], .usable(8000))
        XCTAssertEqual(try store.settings.rawValue(SettingsStore.Key.adminExpenseAnnual), "8000")
        XCTAssertEqual(try store.settings.rawValue(SettingsStore.Key.vatRate), "abc",
                       "the other damaged row is untouched, byte for byte")
        XCTAssertEqual(try store.settings.number(SettingsStore.Key.incomeTaxRate), 11)
        try store.db.close()
    }

    // M3 ────────────────────────────────────────────────────────────────────────────────
    /// A settled ledger draws none of the new copy. Two independent facts, as in P4c-2.
    func testM3AUsableLedgerDrawsNoneOfTheNewCopy() async throws {
        let store = try freshStore("m3.db")
        try store.settings.setNumber(13, for: SettingsStore.Key.vatRate)
        let model = await booted(store)
        XCTAssertEqual(model.reportParameterStates[.vatRate], .usable(13))
        XCTAssertEqual(model.reportParameterStates[.surchargeRate], .absent,
                       "an absent row is not a damaged one, and draws nothing either")

        let source = try ReportFixtureBuilder.appSource("Views/SettingsView.swift")
        let notice = try XCTUnwrap(source.range(of: "private struct DamagedParameterNotice"))
        let before = String(source[source.startIndex..<notice.lowerBound])
        for key in ["settings.reportParams.needsRepair", "settings.reportParams.repairHint"] {
            XCTAssertFalse(before.contains(key), "\(key) is drawn outside the notice")
            XCTAssertTrue(source.contains(key), "\(key) must actually be drawn by the notice")
        }
        try store.db.close()
    }

    // M4 ────────────────────────────────────────────────────────────────────────────────
    /// The regime cascade still writes three sound rates — the alignment did not disturb it.
    func testM4TheRegimeCascadeStillLeavesAllThreeRatesUsable() async throws {
        let store = try freshStore("m4.db")
        try writeRawSetting(store, .vatRate, "abc")
        let model = await booted(store)
        XCTAssertEqual(model.reportParameterStates[.vatRate], .needsRepair(storedText: "abc"))

        model.setAccountingLocale(.JP)

        for f in [ReportParameterField.vatRate, .surchargeRate, .incomeTaxRate] {
            guard case .usable = model.reportParameterStates[f] else {
                return XCTFail("\(f) should be usable after a cascade, got \(String(describing: model.reportParameterStates[f]))")
            }
        }
        try store.db.close()
    }

    // M5 ────────────────────────────────────────────────────────────────────────────────
    /// **The silent deletion, pinned.**
    ///
    /// A damaged row renders as an EMPTY field, and SwiftUI writes that emptiness back through
    /// the binding when the field loses focus. Measured on `main` before this change: clicking
    /// into such a field and clicking away, without typing anything, DELETED the row — the very
    /// row the report page shows the user as evidence. Focus is not an intent to delete.
    ///
    /// `editReportParameter` is what the field calls now, and it forwards a nil only when there
    /// was a usable value to clear. The second half of this test keeps the deliberate behaviour
    /// honest: clearing a value that really is there still deletes the row.
    func testM5FocusingADamagedFieldCannotDeleteItsRow() async throws {
        let store = try freshStore("m5.db")
        try writeRawSetting(store, .adminExpenseAnnual, "5000元")
        try writeRawSetting(store, .vatRate, "abc")
        try writeRawSetting(store, .surchargeRate, "[25]")
        let model = await booted(store)

        // Exactly what a focus-then-blur does to a field the lenient read left empty.
        for f in [ReportParameterField.adminExpenseAnnual, .vatRate, .surchargeRate] {
            model.editReportParameter(f, to: nil)
        }

        XCTAssertEqual(try store.settings.rawValue(SettingsStore.Key.adminExpenseAnnual), "5000元")
        XCTAssertEqual(try store.settings.rawValue(SettingsStore.Key.vatRate), "abc")
        XCTAssertEqual(try store.settings.rawValue(SettingsStore.Key.surchargeRate), "[25]")

        // And clearing a row that IS usable still deletes it — unchanged, still deliberate.
        // Set it THROUGH the model so the published value the guard consults is the real one.
        model.editReportParameter(.incomeTaxRate, to: 25)
        XCTAssertEqual(model.reportParameters[.incomeTaxRate], 25)
        model.editReportParameter(.incomeTaxRate, to: nil)
        XCTAssertNil(try store.settings.rawValue(SettingsStore.Key.incomeTaxRate),
                     "clearing a value that is really there must still remove the row")
        try store.db.close()
    }

    // M6 ────────────────────────────────────────────────────────────────────────────────
    /// The OTHER direction of the same defect, found by the walkthrough after M5 was written.
    ///
    /// A `U+FEFF`-prefixed number is damaged, but the lenient read still produces a number for
    /// it — so that field was NOT empty, and a focus-then-blur wrote that number back. Measured:
    /// `vat_rate` went from `U+FEFF13` to a clean `13` without anyone typing. On
    /// `admin_expense_annual` the same move would turn the 0 the engines used into 5000 and
    /// change the report, still without a keystroke.
    ///
    /// So the field shows NOTHING for a damaged row (`displayedReportParameter`), and a write
    /// that merely repeats what the field was showing is not an edit.
    func testM6FocusingABOMDamagedFieldCannotRewriteItsRow() async throws {
        let store = try freshStore("m6.db")
        try writeRawSetting(store, .vatRate, "\u{FEFF}13")
        try writeRawSetting(store, .adminExpenseAnnual, "\u{FEFF}5000")
        let model = await booted(store)

        XCTAssertEqual(model.reportParameters[.vatRate], 13,
                       "the lenient read still produces a number for this row")
        XCTAssertNil(model.displayedReportParameter(.vatRate),
                     "but the field must show nothing, so no value is put in the user's mouth")

        // Exactly what focus-then-blur sends: whatever the field was displaying.
        model.editReportParameter(.vatRate, to: model.displayedReportParameter(.vatRate))
        model.editReportParameter(.adminExpenseAnnual,
                                  to: model.displayedReportParameter(.adminExpenseAnnual))

        XCTAssertEqual(try store.settings.rawValue(SettingsStore.Key.vatRate), "\u{FEFF}13",
                       "the row keeps its bytes, BOM included")
        XCTAssertEqual(try store.settings.rawValue(SettingsStore.Key.adminExpenseAnnual),
                       "\u{FEFF}5000")

        // And typing a real number over it still repairs.
        model.editReportParameter(.vatRate, to: 9)
        XCTAssertEqual(try store.settings.rawValue(SettingsStore.Key.vatRate), "9")
        XCTAssertEqual(model.reportParameterStates[.vatRate], .usable(9))
        try store.db.close()
    }

    // M7 ────────────────────────────────────────────────────────────────────────────────
    /// A sound row is not churned either: focus-then-blur on a field showing 25 writes nothing.
    func testM7FocusingASoundFieldWritesNothing() async throws {
        let store = try freshStore("m7.db")
        try store.settings.setNumber(25, for: SettingsStore.Key.incomeTaxRate)
        let model = await booted(store)
        XCTAssertEqual(model.displayedReportParameter(.incomeTaxRate), 25)

        model.editReportParameter(.incomeTaxRate, to: 25)

        XCTAssertEqual(try store.settings.rawValue(SettingsStore.Key.incomeTaxRate), "25")
        XCTAssertEqual(model.reportParameterStates[.incomeTaxRate], .usable(25))
        try store.db.close()
    }
}
