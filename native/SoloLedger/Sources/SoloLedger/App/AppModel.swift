import AppKit
import SwiftUI
import SoloLedgerCore

enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case overview
    case transactions
    case categories
    /// Master data, next to the categories it sits beside conceptually. Reports stay last:
    /// they are the output of everything above them.
    case products
    /// The stock those products carry, so it reads straight after the master data it counts
    /// and before the reports that summarise everything above.
    case inventory
    case reports
    var id: String { rawValue }
    var titleKey: String { "nav.\(rawValue)" }
    var systemImage: String {
        switch self {
        case .overview: return "chart.bar.doc.horizontal"
        case .transactions: return "list.bullet.rectangle"
        case .categories: return "tag"
        // The same symbol the products page's own empty state uses, so the sidebar row and
        // the page it opens are one visual thing.
        case .products: return "shippingbox"
        // Adjudicated, rather than derived from the page the way the row above is: the
        // inventory page's empty state draws `tray.full`, which is the empty SHELF and would
        // say nothing about movement here. This is the products box carrying an arrow —
        // recognisably the same goods as the row above, and recognisably not a second
        // products row.
        case .inventory: return "shippingbox.and.arrow.backward"
        case .reports: return "doc.text.magnifyingglass"
        }
    }
}

/// Filter for the transactions list (All / Income / Expense).
enum TransactionFilter: String, CaseIterable, Identifiable, Hashable {
    case all, income, expense
    var id: String { rawValue }
    var type: TransactionType? {
        switch self {
        case .all: return nil
        case .income: return .income
        case .expense: return .expense
        }
    }
    var titleKey: String { "filter.\(rawValue)" }
}

/// Overview time window.
enum OverviewPeriod: String, CaseIterable, Identifiable, Hashable {
    case month, year, all
    var id: String { rawValue }
    var titleKey: String { "period.\(rawValue)" }

    /// (from, to) as 'YYYY-MM-DD' strings, or nil for all-time.
    func range(now: Date = Date()) -> (from: String?, to: String?) {
        let cal = Calendar(identifier: .gregorian)
        switch self {
        case .all:
            return (nil, nil)
        case .month:
            let start = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
            return (DateFormat.string(from: start), DateFormat.string(from: now))
        case .year:
            let start = cal.date(from: cal.dateComponents([.year], from: now)) ?? now
            return (DateFormat.string(from: start), DateFormat.string(from: now))
        }
    }
}

/// Central observable app state. Owns the single `LedgerStore` connection and the
/// UI-language localizer. All mutations funnel through here so views stay thin.
@MainActor
final class AppModel: ObservableObject {
    // Data
    @Published private(set) var transactions: [Transaction] = []
    @Published private(set) var categories: [Category] = []
    @Published private(set) var summary = LedgerSummary()
    @Published private(set) var currencySummaries: [CurrencySummary] = []
    @Published private(set) var monthly: [MonthlyTotal] = []
    @Published private(set) var recent: [Transaction] = []
    /// The Overview metrics block's input, or `nil` when the block must not be drawn at all.
    /// Assembled by ``rebuildOverviewMetrics()``; see that method for what `nil` covers.
    @Published private(set) var overviewMetrics: OverviewPageComposition.Input?

    // Overview + transaction-list filters
    @Published var overviewPeriod: OverviewPeriod = .all
    @Published var searchText = ""
    @Published var sort: TransactionSort = .dateDescending
    @Published var dateFrom: Date?
    @Published var dateTo: Date?

    // Preferences
    @Published var section: SidebarSection = .overview
    @Published var filter: TransactionFilter = .all
    @Published private(set) var language: String
    @Published var appearance: Appearance = .system
    @Published var accountingLocale: AccountingLocale = .CN
    /// What the `accounting_locale` row really holds, by the rule the report engines use.
    /// `accountingLocale` above is the DISPLAY fallback — it answers `.CN` for a row that
    /// names no regime, which is why anything that must not invent a regime reads this.
    @Published private(set) var accountingLocaleState: StoredLocaleState = .absent
    @Published var companyName: String = ""
    /// Records still held in the legacy `sales` / `purchases` tables. Read-only: the
    /// app never converts them, it only says they are there.
    @Published private(set) var legacyLedger = LegacyLedgerSummary()
    /// The probe could not read the ledger, so "this ledger is empty" is unproven.
    /// Anything that would write into a supposedly-empty ledger stays disabled.
    @Published private(set) var legacyProbeFailed = false
    /// Report calculation parameters (rates in whole percent + the annual admin
    /// expense) EXACTLY as stored — an absent value stays absent rather than being
    /// resolved to a preset, so the Settings tab can never show a rate the report
    /// engines would not use. Nothing in this app consumes them yet; they are stored
    /// in the ledger for the report features that read them.
    @Published private(set) var reportParameters = ReportParametersStored()
    /// Each report parameter row judged by the rule the report engines are judged by.
    /// `reportParameters` above is the lenient DISPLAY read — it answers nil for an absent row
    /// and for a damaged one alike, which is exactly the distinction the Settings screen has to
    /// make. Absent from this dictionary means the read itself failed.
    @Published private(set) var reportParameterStates: [ReportParameterField: StoredSettingState] = [:]

    // Lifecycle / errors
    @Published var onboardingDone = false
    @Published var bootError: String?
    @Published var actionError: String?
    @Published private(set) var ready = false
    /// Non-nil → an Electron database exists but the upgrade FAILED. The app is in a
    /// blocking recovery state and MUST NOT open/create an active database until the
    /// user chooses a recovery action. The original data is never modified.
    ///
    /// LEGACY (DatabaseUpgrade) recovery only — retained as a separate guarded flow; C12b-2
    /// adds orchestration guards without changing DatabaseUpgrade internals. The C12 coordinator
    /// production boot reports through `migrationUIState` instead, never through this.
    @Published var migrationFailure: String?

    /// The C12 coordinator production-boot state. Distinct from the legacy `migrationFailure`
    /// DatabaseUpgrade screen; the two are mutually exclusive sources (RootView wiring is C12b-3).
    @Published private(set) var migrationUIState: MigrationUIState = .none

    // Editor sheet state (nil editingTransaction = creating a new one)
    @Published var showingEditor = false
    @Published var editingTransaction: Transaction?

    /// G4 — whether the main window currently exists. Written by `RootView`'s appear/disappear
    /// in `SoloLedgerApp`; read by `AppCommands` to disable every command that acts on, or
    /// reports into, that window.
    ///
    /// It has to be `@Published` rather than a `NSApp.windows` lookup: the menu items' enabled
    /// state is a SwiftUI `.disabled(…)`, which only re-evaluates when something observable
    /// changes. A poll would be correct at read time and stale on screen.
    ///
    /// Starts `false` — before the first window appears there is nothing to act on, and that is
    /// also the state the app is in when the last window closes.
    @Published var mainWindowIsOpen = false

    private var localizer: Localizer
    private(set) var store: LedgerStore?

    /// The authorization the C12 chain opened THIS ledger with, kept for the one other place
    /// that may open it: the legacy-conversion wizard's background connection. Internal so the
    /// hosted tests can drive the wizard without a real boot.
    ///
    /// Only the two EXISTING-ledger authorizations can ever confirm into `.proceed(.existing)`;
    /// `.createFreshExpectedAbsent` confirms into `.createFresh` and is refused by
    /// `confirmLegacyConversion` before any task starts. See `authorizesExistingLedger`.
    var storeOpenAuthorization: StoreOpenAuthorization?

    // C12b-2 boot orchestration. Internal (not private) so the hosted `@testable` unit tests
    // can inspect single-flight / generation state; no PUBLIC App API is added.
    var bootGeneration = 0
    var inFlight = false
    var currentBootTask: Task<Void, Never>?
    private var runner: BootChainRunner?

    init() {
        let initial = Localizer.systemDefault()
        self.language = initial
        self.localizer = Localizer(language: initial)
    }

    /// Internal test seam: inject a scripted boot runner so tests can drive outcomes,
    /// completion timing and Phase-B attempts deterministically. NOT public.
    init(runner: BootChainRunner) {
        let initial = Localizer.systemDefault()
        self.language = initial
        self.localizer = Localizer(language: initial)
        self.runner = runner
    }

    // MARK: - Localization

    func t(_ key: String) -> String { localizer.t(key) }
    func t(_ key: String, _ replacements: [String: String]) -> String { localizer.t(key, replacements) }
    func categoryLabel(_ category: Category) -> String { category.label(for: language) }

    // MARK: - Boot

    func boot() {
        guard store == nil else { return }
        #if DEBUG
        if CommandLine.arguments.contains("--demo") {
            let url = (try? AppPaths.dataDirectory().appendingPathComponent("demo.db"))
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("demo.db")
            bootDemo(databaseURL: url)
            return
        }
        // DEBUG UI-test boot harness (`--migration-boot-harness chooseSource`): UI tests drive
        // the REAL production chain RootView.resolvedRouteAndData → productionData →
        // MigrationViewData.production → render(.chooseSource) → MigrationSourceChoiceView →
        // AppModel. NO preview is active and NO synthetic action closures are supplied — the
        // harness fakes ONLY the BootChainRunner seam (each resolution records the received
        // intent into the witness and parks back in `.requiresSourceChoice`) and the modal
        // `runModal()` call (deterministic OK + fixed URL). Compiled out of Release.
        if DebugBootHarness.isActive {
            runner = DebugBootHarness.Runner()
            Self.migrationSourcePanelRunnerOverride = { panel in
                DebugActionWitness.shared.record("panel.run")
                if panel.canChooseDirectories && !panel.canChooseFiles && !panel.allowsMultipleSelection {
                    DebugActionWitness.shared.record("panel.singleDirectory")
                }
                return (.OK, DebugBootHarness.grantURL)
            }
        }
        #endif
        // Production migration boot runs through the C12 coordinator chain: the heavy probe
        // work executes OFF the main actor, then confirm→open run synchronously ON the main
        // actor. Errors surface through `migrationUIState` (never a raw `bootError`). The
        // legacy DatabaseUpgrade recovery (migrationFailure / restore / blank) below is
        // retained as a separate guarded flow; C12b-2 adds orchestration guards without
        // changing DatabaseUpgrade internals.
        startChain(.boot)
    }

    // MARK: - C12 coordinator boot orchestration

    /// Re-run the probe from a retriable/terminal state (never creates a store by itself).
    func retryProbe() { guard store == nil else { return }; startChain(.boot) }
    /// Consume a user acknowledgement and re-run the chain.
    func submitAcknowledgement(_ ack: Acknowledgement) { guard store == nil else { return }; startChain(.acknowledgement(ack)) }
    /// Consume a user import selection.
    func resolveImportSelection(importID: String) { guard store == nil else { return }; startChain(.selection(importID)) }
    /// N7.2: emitted by the source-choice screen's confirmed "create empty ledger" action
    /// (the confirmation dialog is view-local; only its confirm button calls this). Same
    /// discipline as every intent: only before a store exists, hard single-flight inside
    /// `startChain`.
    func confirmCreateFresh() { guard store == nil else { return }; startChain(.confirmCreateFresh) }
    /// N7.2: emitted after the user confirms a directory in the migration-source picker
    /// (`handleMigrationSourcePanelResult`). The chosen source rides the intent as a value type.
    func migrateFromUserDir(source: MigrationSource) { guard store == nil else { return }; startChain(.migrateFromUserDir(source)) }
    /// Cancel an import selection — never opens, creates, or auto-picks; lands terminal-ish.
    func cancelImportSelection() {
        guard case .awaitingImportSelection = migrationUIState else { return }
        migrationUIState = .terminal(MigrationBlock(code: .invalidSelection, classification: .terminal,
                                                    params: ["reason": "userCancelled"]))
    }

    private func startChain(_ intent: BootIntent) {
        guard !inFlight else { return }   // HARD single-flight FIRST — a rejected click changes nothing
        // A new C12 chain SUPERSEDES any legacy DatabaseUpgrade recovery screen: clear it here
        // (before the runner build) so the typed migration state is never masked by a stale
        // `migrationFailure`, even if `makeProductionRunner` fails.
        migrationFailure = nil
        let activeRunner: BootChainRunner
        if let runner {
            activeRunner = runner
        } else {
            do { let built = try makeProductionRunner(); runner = built; activeRunner = built }
            catch {
                migrationUIState = .retriable(MigrationBlock(code: .ioTransient, classification: .retriable,
                                                             params: ["op": "bootConfig"]))
                return
            }
        }
        inFlight = true
        bootGeneration += 1
        let gen = bootGeneration
        migrationUIState = .running(.resolving)
        currentBootTask = Task { await runChain(intent, using: activeRunner, generation: gen) }
    }

    private func runChain(_ intent: BootIntent, using runner: BootChainRunner, generation gen: Int) async {
        var reResolved = false
        var currentIntent = intent
        while true {
            let outcome = await runner.resolveOutcome(currentIntent)       // Phase A — OFF the main actor
            guard gen == bootGeneration else { return }   // stale: a superseded chain owns NOTHING — never touch inFlight/state  // resumed on the main actor
            switch MigrationBootDriver.classifyOutcome(outcome) {
            case .ui(let state):
                finish(state, generation: gen); return
            case .openStore(let authorization, let residual):
                // Phase B — synchronous ON the main actor: confirm → open, no await between them.
                switch runner.attempt(authorization, residual: residual) {
                case .opened(let candidate, let candidateResidual):
                    adopt(candidate, authorization: authorization,
                          residual: candidateResidual, generation: gen); return
                case .ui(let state):
                    finish(state, generation: gen); return
                case .needsReResolve:
                    guard !reResolved else {
                        finish(.retriable(MigrationBlock(code: .interference, classification: .retriable,
                                                         params: ["op": "reResolve"])), generation: gen)
                        return
                    }
                    reResolved = true
                    switch currentIntent {
                    case .migrateFromUserDir:
                        // §7.1 invariant (a): the explicit user-chosen source is STICKY. A
                        // collapse to `.boot` would re-inject the auto candidate and could
                        // silently re-adjudicate the user's selection back to the auto source
                        // in the pre-record window — forbidden. Slot conflicts stay visible
                        // as terminal `.importSlotOccupied`, never a silent source switch.
                        break
                    case .boot, .acknowledgement, .selection, .confirmCreateFresh:
                        // Deliberate for `.confirmCreateFresh` too: a revoked create-fresh
                        // authorization (e.g. an auto source appeared at confirm time) must
                        // re-adjudicate via `.boot`, which PREFERS migration over minting an
                        // empty ledger (§7.1 "re-adjudication prefers migration").
                        currentIntent = .boot
                    }
                    continue   // bounded to ONE re-resolve; loops back to Phase A off-main
                }
            }
        }
    }

    /// Atomic adoption of the store-open authorization. The REQUIRED settings reads (ui
    /// language, appearance, accounting locale) must ALL succeed on a LOCAL candidate before
    /// anything is published; only then are `store`, `ready` and the state published together.
    /// A required-read failure leaves `store == nil`, `ready == false`, a typed retriable state,
    /// and NO `bootError`. NOTE: `onboardingDone` / `companyName` are OPTIONAL best-effort reads
    /// (`try?` defaults), and `reloadAll` keeps its own `actionError` behavior — neither
    /// participates in the store-open authorization. This does NOT atomically pre-read every
    /// startup query; only the required settings gate publication.
    ///
    /// The `authorization` is RETAINED, not merely consumed: the legacy-conversion wizard opens
    /// a second connection off the main actor and must re-confirm it from disk immediately
    /// before doing so. It is a typed INTENT, never a capability — `confirmOpenAuthorization`
    /// re-derives every precondition at the moment it is used — so holding one across a session
    /// grants nothing that was not re-checked.
    private func adopt(_ candidate: LedgerStore, authorization: StoreOpenAuthorization,
                       residual: MigrationResidual?, generation gen: Int) {
        guard gen == bootGeneration else { return }   // stale: a superseded chain owns NOTHING — never touch inFlight/state
        let savedLang: String?
        let savedAppearance: String?
        let loc: AccountingLocale
        let locState: StoredLocaleState
        do {
            savedLang = try candidate.settings.string(SettingsStore.Key.uiLanguage)
            savedAppearance = try candidate.settings.string(SettingsStore.Key.appearance)
            loc = try candidate.settings.accountingLocale()
            // Same row, same primitive: if one of these two reads fails the other would too,
            // so this adds no new way for adoption to fail — only a second answer about it.
            locState = try candidate.settings.accountingLocaleState()
        } catch {
            finish(.retriable(MigrationBlock(code: .storeOpenFailed, classification: .retriable,
                                             params: ["op": "adopt"])), generation: gen)
            return
        }
        let done = (try? candidate.settings.bool(SettingsStore.Key.onboardingDone)) ?? false
        let co = (try? candidate.settings.string(SettingsStore.Key.companyName)) ?? ""
        let params = (try? candidate.settings.reportParameters()) ?? ReportParametersStored()
        // Required reads passed; optional reads above are best-effort defaults. Publish now —
        // `reloadAll` below may set `actionError` but never un-publishes the store.
        store = candidate
        storeOpenAuthorization = authorization
        if let savedLang { setLanguage(savedLang, persist: false) }
        if let savedAppearance, let ap = Appearance(rawValue: savedAppearance) { appearance = ap }
        accountingLocale = loc
        accountingLocaleState = locState
        onboardingDone = done
        companyName = co
        reportParameters = params
        reportParameterStates = Self.parameterStates(candidate.settings)
        reloadAll()
        migrationFailure = nil
        ready = true
        finish(residual.map(MigrationUIState.cleanupResidual) ?? .none, generation: gen)
    }

    private func finish(_ state: MigrationUIState, generation gen: Int) {
        guard gen == bootGeneration else { return }   // stale: a superseded chain owns NOTHING — never touch inFlight/state
        migrationUIState = state
        inFlight = false
    }

    /// The production runner: wraps the coordinator and the real off-main / main-actor
    /// boundaries. Built lazily so a fresh install never derives paths until boot.
    ///
    /// The snapshot plan's two directories are derived from the config PURELY — the same base
    /// `Config.standard()` uses — rather than through `AppPaths.backupsDirectory()`, which
    /// CREATES its directory. `Config.standard()` documents that it creates nothing so a
    /// probe-first boot mints no empty migration directories, and resolving the backups path the
    /// creating way here would break exactly that: every boot, including ones with no migration
    /// pending, would leave a `Backups/` behind. `PreMigrationSnapshot` creates it if and only if
    /// it actually writes a snapshot.
    ///
    /// An instance method (not `static`) so the snapshot-failure callback can reach `self` and put
    /// a localized, actionable message on screen; the store-open failure itself still travels the
    /// unchanged typed path into the retriable chain-recovery UI, which is where the retry lives.
    private func makeProductionRunner() throws -> BootChainRunner {
        let config = try MigrationCoordinator.Config.standard()
        let dataRoot = config.activeDestination.deletingLastPathComponent()
        let plan = PreMigrationSnapshotPlan(
            backupsDirectory: dataRoot.appendingPathComponent("Backups", isDirectory: true),
            attachmentsDirectory: config.activeAttachmentsDir,
            timestamp: Self.fileTimestamp(),
            retention: Self.preMigrationSnapshotRetention)
        return Self.makeBootChainRunner(coordinator: MigrationCoordinator(config: config),
                                        autoSourceCandidate: .masContainer,
                                        activeURL: config.activeDestination,
                                        snapshot: plan,
                                        onSnapshotFailure: { [weak self] error in
                                            self?.reportSnapshotFailure(error)
                                        })
    }

    /// How many pre-migration snapshots are kept. Three covers "upgraded three rungs in a row"
    /// and "rolled back then upgraded again"; beyond that a pre-migration snapshot is dead weight,
    /// because its only use is the upgrade that has by then succeeded.
    static let preMigrationSnapshotRetention = 3

    /// Put the snapshot failure on screen as an ACTIONABLE alert, without changing where the boot
    /// routes. `actionError` is rendered by an alert attached to the whole root view, so it shows
    /// ON TOP of the retriable chain-recovery screen — the user gets both the explanation and the
    /// retry button. Setting `bootError` instead would win the routing priority and replace that
    /// screen with a dead-end that has no retry.
    private func reportSnapshotFailure(_ error: PreMigrationSnapshotError) {
        switch error {
        case .writeFailed:        actionError = t("recovery.snapshotFailed.write")
        case .verificationFailed: actionError = t("recovery.snapshotFailed.verify")
        }
    }

    /// The ONE intent → coordinator mapping the app ships — `makeProductionRunner` above is
    /// only "this factory + the production config". Internal (NOT private, NOT public) so the
    /// hosted `@testable` tests drive the EXACT shipped wiring against an isolated
    /// coordinator/auto-source/activeURL instead of hand-copying the switch (a copy could
    /// stay green while the real mapping drifts — e.g. `.migrateFromUserDir` silently rerouted
    /// to `bootResolve`, losing the user's source). The production-mapping guard tests in
    /// `DormantSourceChoiceBootTests` pin each arm behaviorally.
    static func makeBootChainRunner(coordinator: MigrationCoordinator,
                                    autoSourceCandidate auto: MigrationSource?,
                                    activeURL: URL,
                                    snapshot: PreMigrationSnapshotPlan? = nil,
                                    onSnapshotFailure: (@MainActor (PreMigrationSnapshotError) -> Void)? = nil)
    -> ProductionBootChainRunner {
        ProductionBootChainRunner(
            resolveWork: { intent in
                switch intent {
                case .boot: return coordinator.bootResolve(autoSourceCandidate: auto)
                case .acknowledgement(let ack): return coordinator.bootResolve(autoSourceCandidate: auto, acknowledgement: ack)
                case .selection(let id): return coordinator.resolveSelectedImport(importID: id)
                // The two intents the source-choice screen emits since N7.2 (they landed dormant
                // in N7.1, one stage before any UI could emit them). The confirmed create-fresh
                // goes to the coordinator's dedicated strong-typed entry (which takes NO auto
                // candidate by construction); an explicit user source goes 1:1 to `runImport`,
                // never mixed with the auto candidate.
                case .confirmCreateFresh: return coordinator.confirmCreateFresh()
                case .migrateFromUserDir(let source): return coordinator.runImport(source: source)
                }
            },
            // The auto candidate is handed to EVERY confirm; the coordinator itself only
            // consults it for a createFresh authorization (where it can revoke → reResolve).
            confirm: { coordinator.confirmOpenAuthorization($0, autoSourceCandidate: auto) },
            // `openStore` is invoked on the main actor (`MigrationBootDriver.attemptOpen` is
            // `@MainActor`), so the failure callback can touch the model directly. It REPORTS and
            // RETHROWS: the typed error still travels the unchanged path into the retriable
            // chain-recovery state, so the retry button is exactly where it was.
            openStore: { plan in
                do {
                    return try Self.openStoreForPlan(plan, activeURL: activeURL, snapshot: snapshot)
                } catch let error as PreMigrationSnapshotError {
                    MainActor.assumeIsolated { onSnapshotFailure?(error) }
                    throw error
                }
            })
    }

    /// The REAL production plan → store dispatch, extracted (internal, NOT an injected test double)
    /// so a hosted test can drive the exact wiring `makeProductionRunner` ships: an `.existing`
    /// plan MUST take the C12x hardened open, never a plain `existingOnly`. Reverting the
    /// `.existing` branch to `LedgerStore(open: .existingOnly)` is what the production-wiring guard
    /// test in `AppModelBootTests` catches.
    /// `.createFresh` takes NO snapshot plan and that is structural, not an oversight: a ledger
    /// being created has nothing to roll back to, and `createFreshReservedHardened` never enters
    /// the hardened EXISTING open where the snapshot lives.
    static func openStoreForPlan(_ plan: ConfirmedOpenPlan, activeURL: URL,
                                 snapshot: PreMigrationSnapshotPlan? = nil) throws -> LedgerStore {
        switch plan {
        case .createFresh:
            // C12x-A2: exclusive descriptor reservation + NOFOLLOW/HAS_MOVED/fingerprint before adopt.
            return try LedgerStore.createFreshReservedHardened(databaseURL: activeURL)
        case .existing(let evidence):
            return try LedgerStore.openActiveExistingHardened(databaseURL: activeURL, expect: evidence,
                                                              snapshot: snapshot)
        }
    }

    /// Open + load an active store and mark the app ready.
    private func finishBoot(with store: LedgerStore) throws {
        self.store = store
        // These two paths (the DEBUG demo ledger and the confirmed blank ledger) open a store
        // WITHOUT a coordinator authorization, so there is none to retain — and any authorization
        // left over from an earlier open describes a different file. Clearing it means the
        // conversion wizard refuses rather than re-confirming somebody else's intent.
        storeOpenAuthorization = nil
        if let savedLang = try store.settings.string(SettingsStore.Key.uiLanguage) {
            setLanguage(savedLang, persist: false)
        }
        if let savedAppearance = try store.settings.string(SettingsStore.Key.appearance),
           let ap = Appearance(rawValue: savedAppearance) {
            appearance = ap
        }
        accountingLocale = try store.settings.accountingLocale()
        accountingLocaleState = try store.settings.accountingLocaleState()
        companyName = (try? store.settings.string(SettingsStore.Key.companyName)) ?? ""
        onboardingDone = (try? store.settings.bool(SettingsStore.Key.onboardingDone)) ?? false
        reportParameters = (try? store.settings.reportParameters()) ?? ReportParametersStored()
        reportParameterStates = Self.parameterStates(store.settings)
        reloadAll()
        migrationFailure = nil
        ready = true
    }

    // MARK: - Migration recovery (blocking state)

    /// Legacy DatabaseUpgrade recovery may run ONLY when no C12 chain is in flight and no
    /// ledger is open. Otherwise a recovery button pressed while the async chain runs could
    /// bypass C12 single-flight or replace a live active DB. Internal for `@testable` guards.
    var legacyRecoveryAllowed: Bool { !inFlight && store == nil && !ready }

    /// Retry the migration. Since a failed upgrade never created an active DB, boot
    /// re-discovers the (still-absent) active DB and runs the upgrade again.
    func retryMigration() {
        guard legacyRecoveryAllowed else { return }   // reject during a C12 chain / when a ledger is open
        migrationFailure = nil
        store = nil
        boot()
    }

    /// Adopt a user-picked backup / export database as the active DB, via the same
    /// safe upgrade path (integrity + backup + migrate + atomic swap).
    func restore(fromBackupAt fileURL: URL) {
        guard legacyRecoveryAllowed else { return }   // reject during a C12 chain / when a ledger is open
        do {
            let paths = DatabaseUpgrade.Paths(
                legacySource: fileURL,
                activeDestination: try AppPaths.databaseURL(),
                backupsDirectory: try AppPaths.backupsDirectory(),
                workingDirectory: try AppPaths.upgradeWorkingDirectory())
            let outcome = try DatabaseUpgrade(paths: paths, timestamp: DateFormat.timestamp()).run()
            guard case .upgraded = outcome else {
                migrationFailure = "所选文件不是有效的账本数据库（\(outcome)）。"
                return
            }
            migrationFailure = nil   // clear the recovery screen before handing off to the async boot
            store = nil
            boot()   // active DB now exists → the C12 chain opens it (store stays nil, ready false until adopted)
        } catch {
            migrationFailure = "从备份恢复失败：\(error)"
        }
    }

    /// Start a BLANK ledger, accepting that the Electron data is not imported. Only
    /// call this after explicit user confirmation in the recovery UI. The original
    /// Electron database is still never modified.
    func createBlankLedgerConfirmed() {
        guard legacyRecoveryAllowed else { return }   // reject during a C12 chain / when a ledger is open
        do {
            try finishBoot(with: LedgerStore(databaseURL: AppPaths.databaseURL()))
        } catch {
            bootError = "\(error)"
        }
    }

    #if DEBUG
    /// Boot against a specific DB (for screenshots), seeding demo data. Never used
    /// with the production container.
    func bootDemo(databaseURL: URL, language: String = "zh-Hans") {
        do {
            let store = try LedgerStore(databaseURL: databaseURL)
            if try DemoData.isEmpty(store) { try DemoData.seed(into: store) }
            try finishBoot(with: store)
            setLanguage(language, persist: false)
            onboardingDone = true
        } catch { bootError = "\(error)" }
    }
    #endif

    // MARK: - Loading

    /// Reload everything the pages read.
    ///
    /// `rebuildingMetrics` exists for exactly one caller: the Overview period selector. That
    /// block always describes a whole calendar year, so moving the selector cannot change it —
    /// and rebuilding it anyway would run the ledger's two most expensive reads for a value
    /// that is already correct. Every other path here follows a change to the DATA, where the
    /// block really can have moved, so the default rebuilds.
    func reloadAll(rebuildingMetrics: Bool = true) {
        guard let store else { return }
        do {
            categories = try store.categories(locale: accountingLocale)
            let (from, to) = overviewPeriod.range()
            summary = try store.summary(from: from, to: to)
            currencySummaries = try store.summaryByCurrency(from: from, to: to)
            // Chart: single primary currency within the SAME period — never a
            // nil-currency blend, never other periods' data; empty if the period has none.
            if let primary = currencySummaries.first?.currency {
                monthly = try store.monthlyTotals(currency: primary, from: from, to: to)
            } else {
                monthly = []
            }
            recent = try store.listTransactions(from: from, to: to, limit: 6)   // same period, latest
            reloadTransactions()
        } catch {
            actionError = "\(error)"
        }
        if rebuildingMetrics { rebuildOverviewMetrics() }
        reloadLegacySummary()
    }

    /// Assemble the Overview metrics block's input: two report builds, no cache.
    ///
    /// ## The year is read off the data, not off the clock
    ///
    /// The block is anchored on the most recent calendar year that holds a transaction. Two
    /// things follow that a clock-anchored year gets wrong. A ledger nobody has written to
    /// since last year keeps showing its last full picture instead of a permanently empty
    /// block. And the first of January is not a cliff: a year with no rows yet is refused by
    /// the report builder before any engine runs, which would blank the block for every user
    /// until their first entry of the new year.
    ///
    /// ## Why `nil` rather than a sentence
    ///
    /// Every refusal below leaves the block undrawn. The copy for this block can state what it
    /// computes and why a cell is blank; it cannot name a regime that was never configured, a
    /// currency the period disagrees about, or a failed read — and inventing a sentence out of
    /// the ones it does have would describe the wrong problem. A block that is not there claims
    /// nothing, which is the honest option when there is nothing true to say.
    ///
    /// ## The prior year is allowed to fail
    ///
    /// Its absence is the ORDINARY case — a ledger in its first year has no prior report at all,
    /// and the builder answers that in microseconds because it stops before reading any rows.
    /// An empty `priorRevenue` yields a `nil` year-on-year for every month, which is exactly
    /// what the no-base sentence promises. The mirrored source swallows this failure too.
    ///
    /// Synchronous on the main actor, for the same reason ``buildReport()`` is.
    private func rebuildOverviewMetrics() {
        overviewMetrics = nil
        guard let store else { return }
        let db = store.db

        let year: String
        let report: PresentedReport
        do {
            guard let latest = try store.listTransactions(limit: 1).first,
                  latest.date.count >= 4 else { return }
            year = String(latest.date.prefix(4))
            guard case .report(let built) = try ReportBuilder.build(db, period: ReportPeriod(year: year))
            else { return }
            report = built
        } catch {
            ReportDiagnostics.buildFailed(year: "", error: error)
            return
        }

        // The regime comes off the REPORT, never off `accountingLocale`: that property is the
        // display fallback and answers CN for a ledger that names no regime, which would pick
        // the wrong basis sentence without anything going wrong visibly.
        guard let regime = AccountingLocale(rawValue: report.locale) else { return }

        var priorRevenue: [Double?] = []
        // Integer arithmetic with an explicit domain check, deliberately not the report page's
        // year stepper: that one returns its input unchanged at the bounds, so year 0001 would
        // be compared against ITSELF and every month would read 0.0% — the one figure the
        // no-base sentence promises never to show.
        if let numeric = Int(year), numeric > 1 {
            let priorYear = String(format: "%04d", numeric - 1)
            do {
                if case .report(let prior) = try ReportBuilder.build(db, period: ReportPeriod(year: priorYear)) {
                    priorRevenue = prior.monthlyBreakdown.map(Self.amount)
                }
            } catch {
                ReportDiagnostics.buildFailed(year: priorYear, error: error)
            }
        }

        overviewMetrics = OverviewPageComposition.Input(
            regime: regime,
            year: year,
            currency: report.currency,
            revenue: report.monthlyBreakdown.map(Self.amount),
            priorRevenue: priorRevenue)
    }

    /// A month's revenue as a number, or `nil` when the report refused to classify it as one.
    /// A month that could not be classified must not be silently read as a zero: zero is a
    /// figure, and this is the absence of one.
    private static func amount(_ month: PresentedMonth) -> Double? {
        if case .amount(let value) = month.revenue { return value }
        return nil
    }

    /// Read-only count of the records this app cannot display, so an empty ledger is
    /// never presented as "you have no records". Advisory, and therefore kept OFF the
    /// critical path: it runs after the real data load and swallows its own failure —
    /// a probe error must never blank the transaction list, and must never silently
    /// restore the misleading empty state by leaving a zeroed summary behind.
    private func reloadLegacySummary() {
        guard let store else { return }
        do {
            legacyLedger = try store.legacyLedgerSummary()
        } catch {
            legacyProbeFailed = true
        }
    }

    func reloadTransactions() {
        guard let store else { return }
        do {
            transactions = try store.listTransactions(
                type: filter.type,
                from: dateFrom.map(DateFormat.string(from:)),
                to: dateTo.map(DateFormat.string(from:)),
                search: searchText,
                sort: sort)
        } catch { actionError = "\(error)" }
    }

    /// True when more than one currency is present → the UI must NOT show a single
    /// blended total; it presents per-currency figures instead.
    var isMultiCurrency: Bool { currencySummaries.count > 1 }

    func categories(for type: TransactionType) -> [Category] {
        categories.filter { $0.type == type }
    }

    /// The seeded categories of ANY regime, for read-only browsing. Looking at another
    /// regime's set must not switch the ledger's regime, so this never touches settings
    /// and never disturbs the published `categories` the editor uses.
    func categories(browsing locale: AccountingLocale) -> [Category] {
        guard locale != accountingLocale else { return categories }
        return (try? store?.categories(locale: locale)) ?? []
    }

    // MARK: - Demo data (DEBUG / .dev only — never touches production data)

    var isLedgerEmpty: Bool { transactions.isEmpty && currencySummaries.isEmpty }

    #if DEBUG
    /// Whether seeding demo data is safe. `DemoData.seed`'s own guard only inspects
    /// `transactions`, which is exactly the blind spot here: a ledger migrated from the
    /// Electron app can hold real records this app does not read and still look empty.
    /// Also refuses when the probe failed, since emptiness is then unproven.
    var canLoadDemoData: Bool { !legacyLedger.holdsHiddenRecords && !legacyProbeFailed }

    /// Seed anonymized demo data. Idempotent: `DemoData.seed` is a no-op on a
    /// non-empty ledger, so repeated taps never duplicate.
    func loadDemoData() {
        guard let store, canLoadDemoData else { return }
        do {
            try DemoData.seed(into: store, locale: accountingLocale)
            reloadAll()
        } catch { actionError = "\(error)" }
    }
    #endif

    /// Duplicate a transaction (new id, same fields) — a native list convenience.
    func duplicate(id: String) {
        guard let store, var t = try? store.transaction(id: id) else { return }
        t.id = IDGenerator.transactionID()
        t.createdAt = nil; t.updatedAt = nil
        save(t, isNew: true)
    }

    // MARK: - Editor intents

    func newTransaction() {
        editingTransaction = nil
        section = .transactions
        showingEditor = true
    }

    func edit(_ transaction: Transaction) {
        editingTransaction = transaction
        showingEditor = true
    }

    // MARK: - Mutations

    func save(_ transaction: Transaction, isNew: Bool) {
        guard let store else { return }
        do {
            if isNew { try store.create(transaction) } else { try store.update(transaction) }
            reloadAll()
        } catch LedgerError.nonFiniteAmounts(let fields) {
            // Named in the user's language, one sentence per field. The editor's own gate
            // normally catches this first; the path that reaches here is a write with no
            // editor open — `duplicate(id:)` on a row Electron wrote a non-finite value into.
            actionError = fields.map { t(TransactionAmountCopy.key(for: $0)) }
                .joined(separator: "\n")
        } catch { actionError = "\(error)" }
    }

    // MARK: - Delete (single confirmation flow for all entry points) + undo

    /// Non-nil → a delete is awaiting confirmation. The DB is NOT modified until
    /// `confirmDelete()`. All entry points (toolbar / Delete key / context menu)
    /// funnel through `requestDelete`.
    @Published var pendingDeleteIDs: Set<Transaction.ID>?
    /// Full snapshot of the last batch delete (transactions with original timestamps +
    /// legacy_migrations mappings) for a complete undo.
    @Published private(set) var lastDeletedSnapshot: DeletionSnapshot?

    var pendingDeleteCount: Int { pendingDeleteIDs?.count ?? 0 }
    var canUndoDelete: Bool { (lastDeletedSnapshot?.count ?? 0) > 0 }
    var undoDeleteCount: Int { lastDeletedSnapshot?.count ?? 0 }

    func requestDelete(_ ids: Set<Transaction.ID>) {
        guard !ids.isEmpty else { return }
        pendingDeleteIDs = ids
    }

    func cancelDelete() { pendingDeleteIDs = nil }

    func confirmDelete() {
        guard let store, let ids = pendingDeleteIDs else { return }
        pendingDeleteIDs = nil
        do {
            // Atomic all-or-nothing delete; the returned snapshot supports a full undo.
            lastDeletedSnapshot = try store.deleteBatch(ids: ids)
            reloadAll()
        } catch { actionError = "\(error)" }
    }

    func undoDelete() {
        guard let store, let snapshot = lastDeletedSnapshot else { return }
        do {
            try store.restore(snapshot)   // atomic; restores fields, timestamps AND mappings
            lastDeletedSnapshot = nil
            reloadAll()
        } catch { actionError = "\(error)" }
    }

    func dismissUndo() { lastDeletedSnapshot = nil }

    /// Default currency for a brand-new transaction, from the accounting regime.
    var defaultCurrency: String { accountingLocale.defaultCurrency }

    // MARK: - Preferences persistence

    func setLanguage(_ code: String, persist: Bool = true) {
        language = code
        localizer.setLanguage(code)
        objectWillChange.send()
        if persist { try? store?.settings.setString(code, for: SettingsStore.Key.uiLanguage) }
    }

    func setAppearance(_ appearance: Appearance) {
        self.appearance = appearance
        try? store?.settings.setString(appearance.rawValue, for: SettingsStore.Key.appearance)
    }

    /// Switch the accounting regime.
    ///
    /// `applyPresets` opts a call site into the regime rate cascade, which only the
    /// Settings/onboarding regime pickers do — and even then only when the regime
    /// ACTUALLY changes. Both guards matter: onboarding re-commits the unchanged
    /// regime on every first launch (including every ledger migrated from Electron,
    /// which carries no `onboarding_done`), and a cascade there would silently
    /// overwrite rates the user configured in the other app.
    func setAccountingLocale(_ locale: AccountingLocale, applyPresets: Bool = true) {
        let cascade = AccountingProfile.shouldApplyPresets(from: accountingLocale, to: locale,
                                                           requested: applyPresets)
        accountingLocale = locale
        do {
            if cascade {
                // Regime + its preset rates + its currency, atomically: a half-applied
                // switch would leave the ledger claiming one regime while holding
                // another's rates, and the report engines read the two independently.
                try store?.settings.applyRegimeSwitch(AccountingProfile.profile(for: locale))
            } else {
                try store?.settings.setString(locale.rawValue, for: SettingsStore.Key.accountingLocale)
            }
        } catch {
            actionError = "\(error)"
        }
        // Re-read rather than assume: writing a regime is exactly how a damaged row gets
        // repaired, and a published state left saying "unreadable" after the repair would be
        // the same kind of stale claim this change exists to remove. A failed re-read leaves
        // the previous answer standing rather than inventing a better-looking one.
        if let state = try? store?.settings.accountingLocaleState() { accountingLocaleState = state }
        reloadReportParameters()
        reloadAll()
    }

    /// Persist one report calculation parameter exactly as typed — no derivation from
    /// another parameter, no rounding, no range policy. Passing nil clears the setting,
    /// which is a real state (the report features fall back to their own default), and
    /// a non-finite value is refused rather than written, because the report engines
    /// coerce with a bare `Number()`.
    /// The Settings FIELD's editing path, and the only thing the parameter fields call.
    ///
    /// `setReportParameter` below is unchanged: a value writes, a nil deletes. What this adds
    /// is which of those a field is entitled to ask for. A parameter row this app cannot use
    /// renders as an EMPTY field — the lenient read answers nil for it — and SwiftUI writes
    /// that emptiness back through the binding when the field loses focus. Measured on `main`:
    /// clicking into such a field and clicking away, without typing anything at all, DELETED
    /// the damaged row. Focus is not an intent to delete, and the row that vanished is exactly
    /// the evidence the report page shows the user.
    ///
    /// So a nil is honoured only when the field HAD a usable value to clear. Clearing a value
    /// that is really there still deletes the row, unchanged and still a deliberate act.
    func editReportParameter(_ field: ReportParameterField, to value: Double?) {
        if value == displayedReportParameter(field) { return }
        setReportParameter(field, to: value)
    }

    /// What the parameter FIELD shows: nothing at all for a row this app cannot use.
    ///
    /// `reportParameters` is the lenient read, and for a damaged row it can still produce a
    /// number — a `U+FEFF`-prefixed `5000` reads as 5000 there while the engines subtracted 0.
    /// Showing it would invite the user to confirm a value nothing computed with, so the field
    /// is empty and the notice beneath it carries the row's actual bytes instead.
    func displayedReportParameter(_ field: ReportParameterField) -> Double? {
        if case .needsRepair = reportParameterStates[field] { return nil }
        return reportParameters[field]
    }

    func setReportParameter(_ field: ReportParameterField, to value: Double?) {
        do {
            guard let settings = store?.settings else { return }
            if let value {
                guard value.isFinite else { return }
                try settings.setNumber(value, for: field.settingsKey)
            } else {
                try settings.remove(field.settingsKey)
            }
        } catch {
            actionError = "\(error)"
        }
        reloadReportParameters()
    }

    /// Re-publish the parameters straight from the ledger, so what the Settings tab
    /// shows is exactly what the report engines would read — never a resolved,
    /// clamped, or optimistic value. With no ledger open the last known values stay
    /// put: blanking them would read as "unset", which is a different claim.
    private func reloadReportParameters() {
        guard let settings = store?.settings else { return }
        do {
            reportParameters = try settings.reportParameters()
        } catch {
            actionError = "\(error)"
        }
        reportParameterStates = Self.parameterStates(settings)
    }

    /// The four parameter rows judged the way the report engines judge them.
    ///
    /// A read that fails leaves that field OUT of the dictionary rather than claiming
    /// `.absent` — a row this app could not read is not a row it may describe. Published
    /// alongside the lenient `reportParameters` so a screen can never show one while acting
    /// on the other.
    private static func parameterStates(_ settings: SettingsStore)
        -> [ReportParameterField: StoredSettingState] {
        var out: [ReportParameterField: StoredSettingState] = [:]
        for field in ReportParameterField.allCases {
            if let state = try? settings.reportParameterState(field) { out[field] = state }
        }
        return out
    }

    func setCompanyName(_ name: String) {
        companyName = name
        try? store?.settings.setString(name, for: SettingsStore.Key.companyName)
    }

    func completeOnboarding() {
        seedCurrencyIfProvablyNew()
        onboardingDone = true
        try? store?.settings.setBool(true, for: SettingsStore.Key.onboardingDone)
        reloadAll()
    }

    /// Give a brand-new ledger the currency row its own onboarding screen just showed it.
    ///
    /// The screen displays the regime's currency and never stored it, so the first report a
    /// new user asked for was always refused for a currency they had just been shown.
    ///
    /// Writing it unconditionally here would be worse than the bug. Onboarding runs for EVERY
    /// ledger with no `onboarding_done` row — which is every ledger migrated from the Electron
    /// app (see the note on `setAccountingLocale`) — so an unguarded write would pick a
    /// currency for money somebody else's app already recorded. This writes ONLY into a ledger
    /// that can be PROVEN empty:
    ///
    ///   - the `currency` row does not exist. Read as a ROW, not as a decodable value: a row
    ///     holding something unusable is what `currencyInvalid` shows the user verbatim, and
    ///     overwriting it would destroy the evidence on screen. A failed READ is not "absent"
    ///     either — a ledger this app could not inspect is not one it may write into.
    ///   - no transactions this app can see;
    ///   - no legacy records it cannot see. A ledger migrated from Electron can hold real
    ///     records this app never reads and still look empty;
    ///   - the legacy probe succeeded, because otherwise "empty" is unproven;
    ///   - no products. Asked SEPARATELY rather than through the probe, and that separation is
    ///     the point. `products` left `otherRecordTables` when the products page landed, because
    ///     that list means "records the user cannot see here" — a question about VISIBILITY. This
    ///     predicate asks a different question, whether the ledger is provably NEW, and a ledger
    ///     carrying a product catalogue is not, however visible it now is. Reading the two
    ///     through one flag would have quietly loosened this one the moment the other changed.
    ///     Unreadable rows count too: a catalogue this app could not decode is not an absent one.
    ///
    /// The probe pair is the one `canLoadDemoData` already uses, for the same reason. That
    /// predicate is deliberately NOT given the products conjunct: it guards a DEBUG-only seed of
    /// demo transactions, which no product row conflicts with.
    ///
    /// The value is the chosen regime's existing `AccountingProfile` currency — the one the
    /// screen displayed and the one `applyRegimeSwitch` would have written. No currency is
    /// inferred from the data and no tax rate is touched: the regime cascade stays exactly as
    /// deliberate as it was.
    private func seedCurrencyIfProvablyNew() {
        guard let store else { return }
        guard case .some(.none) = (try? store.settings.rawValue(SettingsStore.Key.currency)),
              case .configured = accountingLocaleState,
              transactions.isEmpty,
              !legacyLedger.holdsHiddenRecords,
              !legacyProbeFailed,
              // A read that FAILS is not "no products", for the same reason a failed probe is not
              // "no legacy records": `nil` here means the catalogue could not be inspected, and a
              // ledger this app could not inspect is not one it may write into.
              productCatalogIsProvablyEmpty(store) == true
        else { return }
        do {
            try store.settings.setString(AccountingProfile.profile(for: accountingLocale).currency,
                                         for: SettingsStore.Key.currency)
        } catch {
            // Never silent. Onboarding still completes — a missing currency only means the
            // report page states its refusal, which is a true statement about a real state.
            actionError = "\(error)"
        }
    }

    /// Whether the product catalogue is provably empty: no decoded rows AND none that failed to
    /// decode. `nil` when the catalogue could not be read at all.
    ///
    /// Internal rather than private so the hosted test can isolate this one conjunct without
    /// driving the other four.
    func productCatalogIsProvablyEmpty(_ store: LedgerStore) -> Bool? {
        guard let page = try? store.productCatalog() else { return nil }
        return page.products.isEmpty && page.unreadableCount == 0
    }

    // MARK: - Reports (R8 P3a state model; reached from the `.reports` sidebar section since P3e)

    /// The report page's state. Every non-empty case carries its own year, so the heading and
    /// the numbers under it cannot come from different years.
    @Published private(set) var reportState: ReportPageState = .notRequested

    /// The year the picker holds, as typed — four ASCII digits, `0001`–`9999`.
    ///
    /// The initialiser here is **the only wall-clock read in the report feature**, and it runs
    /// once per `AppModel`. Neither `buildReport()` nor anything in `ReportPresenter` /
    /// `ReportFormat` asks the clock again, so a page left open across midnight on 31 December
    /// keeps describing the year it was describing.
    @Published var reportYearText: String = ReportYear.currentYearText()

    var reportYearIsValid: Bool { ReportYear.isValid(reportYearText) }

    /// Build the report for `reportYearText`.
    ///
    /// The old state is cleared FIRST. A rebuild after a year change must never leave the
    /// previous year's figures on screen under the new heading — and because every non-empty
    /// `ReportPageState` carries its own year, a view that reads the year from the state
    /// cannot show a mismatched pair even if this ordering were ever changed.
    ///
    /// Synchronous on the main actor, deliberately: `ReportBuilder.build` answers from one
    /// local snapshot in milliseconds, and a `.loading` case would be a spinner no frame ever
    /// renders. An invalid year does not attempt a build at all — a malformed period would be
    /// refused as a missing source, which is a true statement about the wrong question.
    func buildReport() {
        reportState = .notRequested
        guard let db = store?.db, ReportYear.isValid(reportYearText) else { return }
        let year = reportYearText
        do {
            switch try ReportBuilder.build(db, period: ReportPeriod(year: year)) {
            case .report(let report):   reportState = .report(report)
            case .blocked(let blocker): reportState = .blocked(year: year, blocker)
            }
        } catch {
            // The detail goes to the log and NOT to the UI: `.failed` has nowhere to put it.
            ReportDiagnostics.buildFailed(year: year, error: error)
            reportState = .failed(year: year)
        }
    }

    // MARK: - Legacy conversion wizard (2a-4)

    /// The wizard's state. `.idle` is also "the sheet is closed".
    @Published private(set) var legacyConversion: LegacyConversionState = .idle
    /// The sheet's presentation, mounted once in `RootView`.
    @Published var showingLegacyConversion = false
    /// The two category choices, cleared whenever the wizard closes. Nil means "not chosen" —
    /// the runner refuses a conversion that needs one and did not get it, and this app does
    /// not pick one on the user's behalf.
    @Published var conversionIncomeCategoryID: String?
    @Published var conversionExpenseCategoryID: String?

    /// Whether the confirm button may be pressed: every direction the execution set actually
    /// contains has a category. The runner re-checks all three questions (existence, direction,
    /// regime) inside its own transaction; this only keeps the user from being told about a
    /// choice they were never offered.
    var legacyConversionCanStart: Bool {
        guard case .summary(let plan) = legacyConversion, !plan.hasNothingToConvert else {
            return false
        }
        let directions = LegacyConversionComposition.requiredDirections(plan)
        if directions.contains(.income), conversionIncomeCategoryID == nil { return false }
        if directions.contains(.expense), conversionExpenseCategoryID == nil { return false }
        return true
    }

    /// Run the preflight and open the wizard on what it found.
    ///
    /// Reachable ONLY from the two entry points, which render only for `hasUnconverted` — the
    /// same gate is re-asserted here so a future caller cannot bypass it. The preflight writes
    /// nothing (`LegacyConversionPlanTests` hashes the database file and its `-wal` either side
    /// of a full run), so opening the wizard is free and cancelling it costs nothing.
    func beginLegacyConversion() {
        guard let store, legacyLedger.hasUnconverted else { return }
        guard case .idle = legacyConversion else { return }
        conversionIncomeCategoryID = nil
        conversionExpenseCategoryID = nil
        do {
            switch try store.legacyConversionPreflight() {
            case .blocked(let blocker): legacyConversion = .blocked(blocker)
            case .plan(let plan):       legacyConversion = .summary(plan)
            }
        } catch {
            LegacyConversionDiagnostics.preflightFailed(error)
            legacyConversion = .failed(.internalFailure)
        }
        showingLegacyConversion = true
    }

    /// Convert the plan the user is looking at.
    ///
    /// The `guard case .summary` is the double-submit gate: the first press moves the state to
    /// `.running`, and a second one therefore matches nothing and changes nothing.
    func confirmLegacyConversion() {
        guard case .summary(let plan) = legacyConversion, !plan.hasNothingToConvert,
              legacyConversionCanStart else { return }
        // Only an EXISTING-ledger authorization may reach the hardened open; a createFresh one
        // confirms into a plan this feature must never take. A freshly created ledger holds no
        // legacy rows, so this is a guard against a future caller rather than a reachable state.
        guard let authorization = storeOpenAuthorization, authorization.authorizesExistingLedger else {
            LegacyConversionDiagnostics.openRefused("no existing-ledger authorization retained")
            legacyConversion = .failed(.internalFailure)
            return
        }
        let backups: URL
        let attachments: URL
        do {
            backups = try AppPaths.backupsDirectory()
            attachments = try AppPaths.nativeAttachmentsDirectory()
        } catch {
            LegacyConversionDiagnostics.conversionFailed(error)
            legacyConversion = .failed(.internalFailure)
            return
        }
        // `skipped` is EMPTY, and stays empty: 2a-4 offers no per-record skip control, so the
        // execution set is exactly the plan's convertible set. `needsAdjudication` and
        // `unconvertible` rows are excluded by the plan itself and were disclosed by count and
        // by row on the page the user just confirmed.
        let request = LegacyConversionRequest(
            plan: plan,
            skipped: [],
            defaultIncomeCategoryID: conversionIncomeCategoryID,
            defaultExpenseCategoryID: conversionExpenseCategoryID,
            backupDestination: Self.conversionBackupDestination(in: backups,
                                                                timestamp: Self.fileTimestamp()),
            attachmentsDirectory: attachments)
        legacyConversion = .running(plan)
        let rowCount = plan.rows.count
        Task { [weak self] in
            // Everything heavy happens on the detached task, on a connection it opens and
            // closes itself. Only `Sendable` values cross in either direction: the
            // authorization and the request go in, an outcome comes back. No `LedgerStore`,
            // no `SQLiteDatabase` and no `LegacyConversionFailure` ever does.
            let outcome = await Task.detached(priority: .userInitiated) {
                LegacyConversionWorker.run(authorization: authorization, request: request)
            }.value
            self?.finishLegacyConversion(outcome, plannedRowCount: rowCount)
        }
    }

    /// Land the background result and, on success, refresh every read model it invalidated.
    ///
    /// The completion state is published BEFORE the reload. `reloadAll` reports its own
    /// failures through `actionError`, and a conversion that committed must never be presented
    /// as one that rolled back because the screen behind it could not be redrawn.
    ///
    /// Internal rather than private, and NOT an injected double: it is the real landing point,
    /// driven directly by the hosted tests so the refresh contract is asserted against the
    /// shipped code instead of a copy of it.
    func finishLegacyConversion(_ outcome: LegacyConversionOutcome, plannedRowCount: Int) {
        switch outcome {
        case .converted(let convertedCount, let backupPath):
            legacyConversion = .completed(convertedCount: convertedCount,
                                          notConvertedCount: max(0, plannedRowCount - convertedCount),
                                          backupPath: backupPath)
            // The affected years are computed from `transactions` from now on, so any report
            // already on screen describes a ledger that no longer exists. Cleared rather than
            // rebuilt: rebuilding would be a second decision taken on the user's behalf, and
            // the year in the picker need not be one this conversion touched.
            reportState = .notRequested
            reloadAll()
        case .failed(let copy):
            legacyConversion = .failed(copy)
        }
    }

    /// Close the wizard. Refused while a conversion is in flight — the transaction is open and
    /// there is nothing a dismissal could mean except a second opinion on a decision taken.
    func dismissLegacyConversion() {
        guard !legacyConversion.isRunning else { return }
        showingLegacyConversion = false
        legacyConversion = .idle
        conversionIncomeCategoryID = nil
        conversionExpenseCategoryID = nil
    }

    /// A `pre-convert-<timestamp>` directory that does not exist yet.
    ///
    /// `BackupExport.writeBundle` refuses an existing destination, so a retry must be handed a
    /// fresh one — and the timestamp is only second-resolution, so two attempts inside one
    /// second would otherwise collide and surface as "the backup could not be written" when
    /// nothing was wrong with the backup. The suffix is what makes
    /// `legacy.convert.failed.retryNote`'s promise — a new bundle beside the old one, never
    /// over it — true at every retry interval rather than most of them.
    /// The timestamp is a PARAMETER rather than a default that reads the clock: `fileTimestamp`
    /// is main-actor isolated, and a pure naming function that cannot be called off it — or
    /// pinned by a test — would be the wrong shape for both callers.
    static func conversionBackupDestination(
        in directory: URL,
        timestamp: String,
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        let base = directory.appendingPathComponent("pre-convert-\(timestamp)", isDirectory: true)
        guard exists(base) else { return base }
        for attempt in 2...99 {
            let candidate = directory.appendingPathComponent("pre-convert-\(timestamp)-\(attempt)",
                                                             isDirectory: true)
            if !exists(candidate) { return candidate }
        }
        return directory.appendingPathComponent("pre-convert-\(timestamp)-\(UUID().uuidString)",
                                                isDirectory: true)
    }

    // MARK: - Products / service items (2b-A3 page state; reachable from the sidebar since 2b-A4)

    /// The product catalogue as last read, together with the rows that could not be decoded.
    ///
    /// Loaded LAZILY — `ProductsView` asks for it when it appears, and `reloadAll()` deliberately
    /// does not. A session that never opens that page must not pay for its query on every refresh
    /// of every other screen. Before 2b-A4 gave the sidebar its entry, the same laziness also kept
    /// each intermediate `main` byte-for-byte identical to the one before it.
    @Published private(set) var products = ProductCatalogPage(products: [], unreadableCount: 0)

    /// The last refused write, as a case and never as text. `ProductCatalogError` has no
    /// payload, so nothing the database said can travel from here to the screen.
    @Published private(set) var productError: ProductCatalogError?

    /// The inline new/edit panel's state, or `nil` when it is closed.
    @Published var productForm: ProductFormDraft?

    /// The row a delete is awaiting confirmation for. The ledger is NOT touched until
    /// `confirmProductDelete()`.
    @Published private(set) var pendingProductDelete: Product?

    /// One undecided write at a time. Opening the form while a delete is pending — or deleting
    /// the row that is open in the form — would leave the user confirming one thing while
    /// looking at another, so every intent below refuses while this is true.
    var productWriteIsPending: Bool { productForm != nil || pendingProductDelete != nil }

    /// What the page draws, assembled from the state above and nothing else.
    var productInput: ProductPageComposition.Input {
        ProductPageComposition.Input(catalog: products, form: productForm,
                                     pendingDelete: pendingProductDelete, error: productError)
    }

    func reloadProducts() {
        guard let store else { return }
        do { products = try store.productCatalog() } catch { productError = .storageFailure }
    }

    func newProduct() {
        guard !productWriteIsPending else { return }
        productForm = ProductFormDraft(editing: nil)
    }

    func editProduct(_ product: Product) {
        guard !productWriteIsPending else { return }
        productForm = ProductFormDraft(editing: product)
    }

    func cancelProductForm() { productForm = nil }

    /// Create or update, and close the panel only if the ledger accepted it.
    ///
    /// An edit submits ONLY the fields that differ from what the panel is showing
    /// (`ProductFormDraft.changes`), and an edit that changes nothing is not a write at all —
    /// it never reaches the store, so `updated_at` does not move and a leniently-read value is
    /// never written back as though the user had confirmed it.
    func saveProductForm() {
        guard let store, let draft = productForm else { return }
        guard let editing = draft.editing else {
            let created = performProductWrite {
                _ = try store.createProduct(name: draft.name,
                                            unit: draft.unit ?? ProductUnit.piece.rawValue,
                                            defaultUnitCost: ProductFormDraft.parseCost(draft.costText),
                                            isService: draft.isService)
            }
            if created { productForm = nil }
            return
        }
        let changes = draft.changes
        guard !changes.isEmpty else { productForm = nil; productError = nil; return }
        let updated = performProductWrite {
            try store.updateProduct(id: editing.id, name: changes.name, unit: changes.unit,
                                    defaultUnitCost: changes.defaultUnitCost,
                                    isService: changes.isService)
        }
        if updated { productForm = nil }
    }

    /// Flip one row's active flag. Not a form field on either side — the list cell is the
    /// control, exactly as it is in the other app.
    func toggleProductActive(_ product: Product) {
        guard let store, !productWriteIsPending else { return }
        performProductWrite { try store.updateProduct(id: product.id, isActive: !product.isActive) }
    }

    func requestProductDelete(_ product: Product) {
        guard !productWriteIsPending else { return }
        pendingProductDelete = product
    }

    func cancelProductDelete() { pendingProductDelete = nil }

    func confirmProductDelete() {
        guard let store, let product = pendingProductDelete else { return }
        pendingProductDelete = nil
        performProductWrite { try store.deleteProduct(id: product.id) }
    }

    func dismissProductError() { productError = nil }

    /// Run one catalogue write and land its outcome.
    ///
    /// On success the read model is refreshed HERE, so no caller can forget: a list that still
    /// shows the row a moment after it was deleted is the same defect class the conversion
    /// wizard's M14 mutation exposed — "the state is right" is not "the screen is right".
    /// On failure nothing is reloaded and the list stays exactly as it was, because nothing in
    /// the ledger changed.
    @discardableResult
    private func performProductWrite(_ work: () throws -> Void) -> Bool {
        do {
            try work()
        } catch let error as ProductCatalogError {
            productError = error
            return false
        } catch {
            // Anything the store raises that is not one of the six adjudicated refusals — a raw
            // SQLite failure, say. Mapped rather than printed: its text carries the statement.
            productError = .storageFailure
            return false
        }
        productError = nil
        reloadProducts()
        return true
    }

    // MARK: - Inventory (N-PR-4 page state; reachable from the sidebar since N-PR-6)

    /// The products a movement can be recorded against.
    ///
    /// Loaded LAZILY rather than with the app-wide refresh, for two reasons: the page is one
    /// section of six and a session that never opens it must not pay for it, and the reads
    /// behind it are heavier — a product's whole movement history, with no paging under it.
    ///
    /// Rows that could not be decoded are not here and are not counted here. An undecodable row
    /// is not something a movement can be recorded against, and the one page that reports such
    /// rows is the products page — which is exactly where the empty state sends the user.
    @Published private(set) var inventoryProducts: [InventoryPageComposition.ProductChoice] = []

    /// The product whose movements are on screen. Never `nil` while any product exists: the copy
    /// has no sentence for "nothing is selected", so every sentence this page owns would be
    /// false in that state.
    @Published private(set) var inventoryProductID: String?

    /// How that product's unit reads, classified ONCE by the products page's own three-armed
    /// rule and carried here as a value.
    @Published private(set) var inventoryUnit: InventoryPageComposition.UnitLabel = .none

    @Published private(set) var inventoryBalanceRow: InventoryBalance?

    /// The audit view: reversed rows and their reversals included, in the ledger's own order.
    @Published private(set) var inventoryRows: [InventoryPostedMovement] = []

    /// The ids of the rows that still count, in the engine's order. Kept as the engine's answer
    /// rather than re-derived here, so "what a reversed pair is" has exactly one definition.
    @Published private(set) var inventoryLiveIDs: [String] = []

    @Published private(set) var inventoryExceptionRows: [InventoryException] = []

    /// The last refused write, as a case and never as text. `InventoryPostingError` has no
    /// payload, so nothing the engine or the database said can travel from here to the screen.
    @Published private(set) var inventoryError: InventoryPostingError?

    /// The new-movement panel's state, or `nil` when it is closed.
    @Published var inventoryForm: InventoryFormDraft?

    /// The movement a reversal is awaiting confirmation for. The ledger is NOT touched until
    /// `confirmInventoryReversal()`.
    @Published private(set) var pendingInventoryReversal: InventoryPostedMovement?

    /// One undecided write at a time, for the reason the products page has the same rule:
    /// confirming one thing while looking at another is how a user reverses the wrong row.
    var inventoryWriteIsPending: Bool {
        inventoryForm != nil || pendingInventoryReversal != nil
    }

    /// The currency a new movement is posted in: the one this product's stock is already held
    /// in, or — for a product with no stock yet — the accounting regime's own. Never read from
    /// the settings row, so a ledger missing that row does not turn into a refusal here, and
    /// never empty, which the engine would refuse outright.
    var inventoryCurrency: String {
        if let held = inventoryBalanceRow?.currency, !held.isEmpty { return held }
        return defaultCurrency
    }

    /// The panel's selected kind, as the picker's tag. A raw string so the view never has to
    /// name an engine type of its own.
    var inventoryFormTypeRawValue: String { inventoryForm?.type.rawValue ?? "" }

    /// What the page draws, assembled from the state above and nothing else.
    var inventoryInput: InventoryPageComposition.Input {
        InventoryPageComposition.Input(products: inventoryProducts,
                                       selectedProductID: inventoryProductID,
                                       unit: inventoryUnit,
                                       balance: inventoryBalanceRow,
                                       movements: inventoryRows,
                                       liveIDs: inventoryLiveIDs,
                                       exceptions: inventoryExceptionRows,
                                       form: inventoryForm,
                                       pendingReversal: pendingInventoryReversal,
                                       error: inventoryError)
    }

    /// Re-read everything this page shows, in one place.
    ///
    /// The balance, the movements, the live set and the exceptions move together or not at all:
    /// a card showing three figures the list does not account for is the same defect class as a
    /// list that still holds a deleted row.
    func reloadInventory() {
        guard let store else { return }
        do {
            let catalog = try store.productCatalog()
            inventoryProducts = catalog.products.map {
                InventoryPageComposition.ProductChoice(id: $0.id, name: $0.name)
            }
            let selected = catalog.products.first { $0.id == inventoryProductID }
                ?? catalog.products.first
            inventoryProductID = selected?.id
            inventoryUnit = Self.inventoryUnitLabel(for: selected)
            guard let selected else {
                inventoryBalanceRow = nil
                inventoryRows = []
                inventoryLiveIDs = []
                inventoryExceptionRows = []
                return
            }
            inventoryBalanceRow = try store.inventoryBalance(productID: selected.id)
            inventoryRows = try store.inventoryMovements(productID: selected.id)
            inventoryLiveIDs = try store.liveInventoryMovements(productID: selected.id).map(\.id)
            inventoryExceptionRows = try store.inventoryExceptions(productID: selected.id)
        } catch let error as InventoryPostingError {
            // A stored row that does not decode is `ledgerInconsistent`, which is a different
            // statement from "the ledger could not be read" and has its own sentence.
            inventoryError = error
        } catch {
            inventoryError = .storageFailure
        }
    }

    func selectInventoryProduct(_ id: String) {
        guard !inventoryWriteIsPending, id != inventoryProductID else { return }
        inventoryProductID = id
        inventoryError = nil
        reloadInventory()
    }

    func newInventoryMovement() {
        guard !inventoryWriteIsPending, inventoryProductID != nil else { return }
        inventoryForm = InventoryFormDraft(occurredOn: DateFormat.today())
    }

    func cancelInventoryForm() { inventoryForm = nil }

    /// Switch the panel's kind. An unknown raw value changes nothing — the picker offers only
    /// the eight the engine knows, so this can only be reached by something that is not it.
    func selectInventoryFormType(_ rawValue: String) {
        guard inventoryForm != nil, let type = InventoryMovementType(rawValue: rawValue) else {
            return
        }
        inventoryForm?.type = type
    }

    /// Post what the panel holds, and close it only if the ledger accepted it.
    func submitInventoryForm() {
        guard let store, let draft = inventoryForm, let productID = inventoryProductID else {
            return
        }
        guard let request = draft.request(productID: productID, currency: inventoryCurrency) else {
            return
        }
        let posted = performInventoryWrite { try store.postInventoryMovement(request) }
        if posted { inventoryForm = nil }
    }

    func requestInventoryReversal(_ id: String) {
        guard !inventoryWriteIsPending else { return }
        pendingInventoryReversal = inventoryRows.first { $0.id == id }
    }

    func cancelInventoryReversal() { pendingInventoryReversal = nil }

    /// Reverse the confirmed movement, dated on the movement's own day.
    ///
    /// Not "today": the engine accepts any date at or after the target's, so today would be
    /// refused outright for a movement dated in the future and leave the control with nothing it
    /// can do. The reversal has no economic date of its own either — it cancels its target and
    /// the balance is rebuilt by replaying what remains — so the target's day is both always
    /// legal and the one that keeps the pair together in the list.
    func confirmInventoryReversal() {
        guard let store, let target = pendingInventoryReversal else { return }
        pendingInventoryReversal = nil
        performInventoryWrite {
            try store.reverseInventoryMovement(id: target.id, occurredOn: target.occurredOn)
        }
    }

    func dismissInventoryError() { inventoryError = nil }

    /// Run one inventory write and land its outcome.
    ///
    /// On success the read model is refreshed HERE, so no caller can forget: a balance card that
    /// still shows the figures from before the posting is the same defect the conversion
    /// wizard's M14 mutation exposed. On failure nothing is reloaded and the page stays exactly
    /// as it was, because a refused posting writes nothing at all.
    @discardableResult
    private func performInventoryWrite(_ work: () throws -> Void) -> Bool {
        do {
            try work()
        } catch let error as InventoryPostingError {
            inventoryError = error
            return false
        } catch {
            // Anything the store raises that is not one of the eighteen adjudicated refusals.
            // Mapped rather than printed: its text carries the statement.
            inventoryError = .storageFailure
            return false
        }
        inventoryError = nil
        reloadInventory()
        return true
    }

    /// The products page's three-armed unit rule, called rather than reimplemented — a unit the
    /// whitelist does not know is shown as it stands on both pages, and a cell with no text
    /// reading draws nothing on both.
    private static func inventoryUnitLabel(for product: Product?) -> InventoryPageComposition.UnitLabel {
        guard let product else { return InventoryPageComposition.UnitLabel.none }
        switch ProductPageComposition.unit(product.unit) {
        case .key(let key):       return .key(key)
        case .verbatim(let text): return .verbatim(text)
        case .none:               return InventoryPageComposition.UnitLabel.none
        }
    }

    // MARK: - Opening-stock wizard (N-PR-5b; reached from the inventory page since N-PR-6)

    /// The wizard's whole state. `private(set)` — only the four intents below move it.
    @Published private(set) var inventoryOpening: InventoryOpeningState = .idle

    /// The sheet's presentation, mounted once, inside `InventoryView`.
    @Published var showingInventoryOpening = false

    /// What the user has typed so far, or `nil` when the wizard is not on its editing page.
    var inventoryOpeningDraft: InventoryOpeningDraft? {
        if case .editing(let draft) = inventoryOpening { return draft }
        return nil
    }

    /// Read the ledger for what can still be opened, then show the sheet.
    ///
    /// The preflight is synchronous and writes nothing — it runs inside one read snapshot so the
    /// N+1 eligibility reads describe one ledger. A read that fails does NOT open the sheet: the
    /// page's own banner says so instead, because a wizard that opens onto an empty list would be
    /// claiming the catalogue is empty when it is only unreadable.
    func beginInventoryOpening() {
        guard let store, case .idle = inventoryOpening else { return }
        do {
            switch try store.inventoryOpeningPreflight() {
            case .blocked(let blocker):
                inventoryOpening = .blocked(blocker)
            case .plan(let plan):
                inventoryOpening = .editing(InventoryOpeningDraft(plan: plan,
                                                                  occurredOn: DateFormat.today()))
            }
        } catch let error as InventoryPostingError {
            inventoryError = error
            return
        } catch {
            inventoryError = .storageFailure
            return
        }
        showingInventoryOpening = true
    }

    func setInventoryOpeningDate(_ occurredOn: String) {
        guard case .editing(var draft) = inventoryOpening else { return }
        draft.occurredOn = occurredOn
        inventoryOpening = .editing(draft)
    }

    func setInventoryOpeningQuantity(_ text: String, at index: Int) {
        guard case .editing(var draft) = inventoryOpening, draft.lines.indices.contains(index)
        else { return }
        draft.lines[index].quantityText = text
        inventoryOpening = .editing(draft)
    }

    func setInventoryOpeningAmount(_ text: String, at index: Int) {
        guard case .editing(var draft) = inventoryOpening, draft.lines.indices.contains(index)
        else { return }
        draft.lines[index].amountText = text
        inventoryOpening = .editing(draft)
    }

    /// Post the openings, one product at a time, and land what happened.
    ///
    /// `guard case .editing` is the double-submit gate: the state leaves that case before the
    /// screen can offer the button again. Each product is its own transaction — see
    /// `runInventoryOpening` — so a refusal on one leaves the others in the ledger, and the
    /// outcome page names every line that was refused rather than claiming a rollback.
    ///
    /// The currency is the accounting regime's, once, for the whole batch. An eligible product
    /// has no live movement and therefore no frozen currency to disagree with, so there is nothing
    /// per-product to resolve here — and these amounts are what freeze it (D-1).
    func confirmInventoryOpening() {
        guard let store, case .editing(let draft) = inventoryOpening else { return }
        guard let request = draft.request(currency: defaultCurrency) else { return }

        let outcome = store.runInventoryOpening(request)
        let names = Dictionary(draft.lines.map { ($0.productID, $0.name) },
                               uniquingKeysWith: { first, _ in first })
        let refusals = outcome.refusals.map { result in
            InventoryOpeningRefusal(
                productName: names[result.productID] ?? result.productID,
                messageKey: InventoryPageComposition.key(for: result.refusal ?? .storageFailure))
        }
        inventoryOpening = refusals.isEmpty ? .done : .partial(refusals)
        // The page behind the sheet is now wrong in three places at once — the balance card, the
        // movement list and the opening advice all depend on what was just written.
        reloadInventory()
    }

    /// The one way out, for every state. A system dismissal writes `false` straight into the
    /// presentation binding without coming through here, which is why the sheet disables it: the
    /// state would stay on an outcome page and the next press of the entry point would hit the
    /// `guard case .idle` above and do nothing at all.
    func dismissInventoryOpening() {
        showingInventoryOpening = false
        inventoryOpening = .idle
    }

    // MARK: - CSV

    func exportCSV(to url: URL) {
        guard let store else { return }
        do {
            let csv = try store.exportTransactionsCSV(type: filter.type)
            try csv.write(to: url, atomically: true, encoding: .utf8)
        } catch { actionError = "\(error)" }
    }

    func importCSV(from url: URL) {
        guard let store else { return }
        do {
            let csv = try String(contentsOf: url, encoding: .utf8)
            let result = try store.importTransactionsCSV(csv)
            reloadAll()
            if result.skipped > 0 {
                actionError = t("csv.import.partial", ["imported": String(result.imported), "skipped": String(result.skipped)])
            }
        } catch { actionError = "\(error)" }
    }

    // MARK: - Restore from backup (replace the active ledger)

    /// Whether a destructive restore may START. **One predicate, two readers** — the Settings
    /// button's `disabled` and the restore orchestration itself.
    ///
    /// The Settings window is a SEPARATE window: the conversion sheet's
    /// `interactiveDismissDisabled` does not reach it, and a Settings window opened before the
    /// wizard stays fully usable while the wizard is on screen. So the UI's `disabled` is a
    /// first hint, not the control — a restore confirmed just as the state changes must still
    /// be refused, and that decision belongs where the destruction happens.
    var canRestoreFromBackup: Bool { legacyConversion.permitsDestructiveRestore }

    /// Replace the current ledger with the backup bundle at `bundleURL`, using production paths.
    ///
    /// The guard comes FIRST, before the paths are even resolved: `AppPaths.backupsDirectory()`
    /// and `nativeAttachmentsDirectory()` both create their directory, and a refused restore
    /// should leave no trace at all.
    func restoreFromBackup(bundleURL: URL) {
        guard canRestoreFromBackup else {
            LegacyConversionDiagnostics.restoreRefused(legacyConversion)
            return
        }
        let config: MigrationCoordinator.Config
        let backups: URL
        let attachments: URL
        do {
            config = try MigrationCoordinator.Config.standard()
            backups = try AppPaths.backupsDirectory()
            attachments = try AppPaths.nativeAttachmentsDirectory()
        } catch { actionError = t("restore.error.failed"); return }
        restoreFromBackup(bundleURL: bundleURL, config: config, backupsDir: backups, currentAttachmentsDir: attachments)
    }

    /// Restore orchestration (internal seam so tests drive it with an isolated config/paths).
    /// Safety-first ORDER: validate the incoming bundle (read-only) → snapshot the CURRENT ledger to
    /// `Backups/` (BackupExport) → close the live store → clear the active slot → re-import the bundle
    /// through the hardened chain (rebuilds DB + attachments, closing G1). Any failure BEFORE the store
    /// closes aborts with the current ledger untouched; after that, the `Backups/` snapshot is the net.
    ///
    /// ## The conversion interlock, and why it is HERE
    ///
    /// A conversion runs off the main actor on its OWN connection to the active file. Nothing
    /// about this function knew that: it would close the main store, clear the active slot and
    /// import another ledger while that worker went on committing to the old file handle —
    /// after which the wizard reports success for transactions that are not in the ledger the
    /// user is now looking at.
    ///
    /// The interlock is the FIRST statement, ahead of every side effect this function has:
    /// the security-scope grant, `validateBundle`, the `pre-restore-` safety backup,
    /// `store.db.close()`, `store = nil`, `ready = false`, `clearActiveSlot` and the
    /// re-import. Refusing after any of them would already have cost the user something.
    ///
    /// It refuses on EVERY non-idle state, not only `.running`. `.summary` holds a plan of a
    /// ledger that is about to be replaced; `.completed` holds the only on-screen copy of the
    /// backup path; `.blocked` and `.failed` describe a ledger that would no longer be the one
    /// on disk. Each of them would survive the restore as a true-looking statement about a
    /// ledger that is gone.
    ///
    /// Silent, like the `legacyRecoveryAllowed` guards above it: the button that reaches here
    /// is already disabled, so this fires only on a race, and there is no localized copy for it
    /// (2a-4 may not add a key). The reason goes to the log instead.
    func restoreFromBackup(bundleURL: URL, config: MigrationCoordinator.Config,
                           backupsDir: URL, currentAttachmentsDir: URL) {
        guard canRestoreFromBackup else {
            LegacyConversionDiagnostics.restoreRefused(legacyConversion)
            return
        }
        guard let store else { return }
        let scoped = bundleURL.startAccessingSecurityScopedResource()
        defer { if scoped { bundleURL.stopAccessingSecurityScopedResource() } }

        do { try BackupRestore.validateBundle(bundleURL) }
        catch { actionError = t("restore.error.invalidBundle"); return }

        // Safety net: snapshot the CURRENT ledger to Backups BEFORE any destruction.
        do {
            let safety = backupsDir.appendingPathComponent("pre-restore-\(Self.fileTimestamp())", isDirectory: true)
            try BackupExport.writeBundle(database: store.db, attachmentsDir: currentAttachmentsDir, to: safety)
        } catch { actionError = t("restore.error.safetyBackupFailed"); return }

        // Close the live store (must succeed before replacing the slot), then reset app state.
        do { try store.db.close() } catch { actionError = t("restore.error.failed"); return }
        self.store = nil
        ready = false

        do { try BackupRestore.clearActiveSlot(config: config) }
        catch { actionError = t("restore.error.failed"); boot(); return }

        // Rebuild the active slot from the bundle through the hardened import chain (finalizer
        // re-applies attachments, closing G1).
        migrateFromUserDir(source: .exportBundle(bundleURL))
    }

    var schemaVersionText: String {
        (try? store?.schemaVersion()).flatMap { $0 }.map(String.init) ?? "—"
    }

    var databasePath: String {
        (try? AppPaths.databaseURL().path) ?? "—"
    }

    // MARK: - Business documents (D-4 page state; NOT reachable — the sidebar entry is D-6's)

    /// The list as last read, together with the headers that could not be decoded.
    ///
    /// Loaded LAZILY — `DocumentsView` asks for it when it appears, and `reloadAll()` deliberately
    /// does not. A session that never opens that page must not pay for its query on every refresh
    /// of every other screen; and while the page has no sidebar entry, that laziness is also what
    /// keeps each intermediate `main` byte-for-byte identical to the one before it.
    @Published private(set) var documents = BusinessDocumentPage(documents: [], unreadableCount: 0)

    /// Which type the list is showing. The filter is applied by the QUERY, not by this class —
    /// picking one re-reads, exactly as the other app does.
    @Published private(set) var documentFilter: DocumentPageComposition.TypeFilter = .all

    /// The last refusal, as a case and never as text.
    @Published private(set) var documentError: DocumentPageComposition.PageError?

    /// Where the last export landed, or that it failed. A cancelled save panel leaves this `nil` —
    /// the other app is silent on a cancelled save too, and inventing a sentence for it would be
    /// this page telling the user something their own Escape key already told them.
    @Published private(set) var documentExportOutcome: DocumentPageComposition.ExportOutcome?

    /// The editor sheet's state, or `nil` when it is closed. Writable so the view can bind fields.
    @Published var documentEditor: DocumentEditorDraft?

    /// The association sheet's state, or `nil` when it is closed.
    @Published var taxInvoiceDraft: TaxInvoiceDraft?

    @Published private(set) var pendingDocumentVoid: BusinessDocument?
    @Published private(set) var pendingDocumentDelete: BusinessDocument?

    /// One undecided write at a time, the same rule the products and inventory pages follow.
    var documentWriteIsPending: Bool {
        documentEditor != nil || taxInvoiceDraft != nil
            || pendingDocumentVoid != nil || pendingDocumentDelete != nil
    }

    /// What the page draws, assembled from the state above and nothing else.
    var documentInput: DocumentPageComposition.Input {
        DocumentPageComposition.Input(page: documents,
                                      filter: documentFilter,
                                      editor: documentEditor,
                                      taxInvoice: taxInvoiceDraft,
                                      pendingVoid: pendingDocumentVoid,
                                      pendingDelete: pendingDocumentDelete,
                                      error: documentError,
                                      exportOutcome: documentExportOutcome)
    }

    func reloadDocuments() {
        guard let store else { return }
        do { documents = try store.businessDocuments(type: documentFilter.storeArgument) }
        catch { documentError = .loadFailed }
    }

    func setDocumentFilter(_ filter: DocumentPageComposition.TypeFilter) {
        guard !documentWriteIsPending else { return }
        documentFilter = filter
        reloadDocuments()
    }

    func dismissDocumentError() { documentError = nil }

    // MARK: Editor

    /// Open the editor on a new document, with the number the ledger suggests for its type.
    ///
    /// The suggestion is only a suggestion: Q3 reserves nothing, so two editors opened at once
    /// would be offered the same number and the second save would be refused with
    /// `DOC_NUMBER_EXISTS`. That is the other app's behaviour and it is the ledger's unique index
    /// doing the work, not this method.
    func newDocument() {
        guard !documentWriteIsPending else { return }
        let type = BusinessDocumentType.quotation
        var draft = DocumentEditorDraft(type: type,
                                        number: suggestedDocumentNumber(for: type),
                                        date: Self.documentToday(),
                                        accountingLocale: accountingLocale)
        draft.products = documentProductChoices()
        draft.statementCustomers = statementCustomers(for: type)
        documentEditor = draft
    }

    /// Open the editor on an existing document. Only a draft ever gets here — the list offers no
    /// edit control on anything else.
    func editDocument(_ document: BusinessDocument) {
        guard let store, !documentWriteIsPending else { return }
        do {
            guard let detail = try store.businessDocument(id: document.id) else {
                documentError = .store(.notFound)
                return
            }
            var draft = DocumentEditorDraft(document: detail.document, items: detail.items)
            draft.products = documentProductChoices()
            documentEditor = draft
            documentError = nil
        } catch {
            documentError = .loadFailed
        }
    }

    func cancelDocumentEditor() { documentEditor = nil }

    var documentEditorType: BusinessDocumentType { documentEditor?.type ?? .quotation }

    var documentEditorCanRemoveLines: Bool { documentEditor?.canRemoveLines ?? false }

    /// Changing the type re-asks for a suggestion, but only while the user has not typed one.
    ///
    /// Both halves are the other app's: its effect depends on `docType`, and the flag it checks
    /// first is set the moment the field is edited. Here the suggestion is fetched synchronously,
    /// so the in-flight race that needs a second guard over there cannot arise.
    func setDocumentEditorType(_ type: BusinessDocumentType) {
        guard var draft = documentEditor, draft.isCreating, draft.type != type else { return }
        draft.type = type
        if !draft.numberEdited { draft.number = suggestedDocumentNumber(for: type) }
        draft.statementCustomers = statementCustomers(for: type)
        draft.statementOutcome = nil
        documentEditor = draft
    }

    func documentEditorField(_ field: DocumentPageComposition.EditorField) -> String {
        guard let draft = documentEditor else { return "" }
        switch field {
        case .number:          return draft.number
        case .date:            return draft.date
        case .validUntil:      return draft.validUntil
        case .customerName:    return draft.customerName
        case .customerTaxID:   return draft.customerTaxID
        case .customerContact: return draft.customerContact
        case .customerAddress: return draft.customerAddress
        case .notes:           return draft.notes
        }
    }

    func setDocumentEditorField(_ field: DocumentPageComposition.EditorField, to text: String) {
        guard var draft = documentEditor else { return }
        switch field {
        case .number:
            draft.number = text
            // Typing in the number field stops the suggestion following the type, for good.
            draft.numberEdited = true
        case .date:            draft.date = text
        case .validUntil:      draft.validUntil = text
        case .customerName:    draft.customerName = text
        case .customerTaxID:   draft.customerTaxID = text
        case .customerContact: draft.customerContact = text
        case .customerAddress: draft.customerAddress = text
        case .notes:           draft.notes = text
        }
        documentEditor = draft
    }

    func documentLineValue(id: Int, _ field: DocumentPageComposition.LineField) -> String {
        documentEditor?.lines.first { $0.id == id }?.value(field) ?? ""
    }

    func setDocumentLineValue(id: Int,
                              _ field: DocumentPageComposition.LineField,
                              to text: String) {
        guard var draft = documentEditor,
              let index = draft.lines.firstIndex(where: { $0.id == id }) else { return }
        // The three numeric fields are `<input type="number">` over there, and a letter typed into
        // one is dropped by the control rather than stored and refused later. Description and unit
        // are plain text and take whatever is typed. `numberInput` is layer ONE of that control —
        // what ends up in the editor; the value it reads back and the submit it allows are two
        // further layers, and neither of them is decided here.
        let cleaned: String
        switch field {
        case .quantity, .unitPrice, .taxRatePercent:
            cleaned = DocumentPageComposition.numberInput(text)
        case .description, .unit:
            cleaned = text
        }
        // "Dropped by the control" means the editor text does not change, so this assignment is
        // skipped and `didSet` never runs on an equal value. The republish still happens, so the
        // field snaps back to the text the control would be holding.
        //
        // That is only HALF of what keeps a locked line locked, and D-4 shipped only this half. A
        // character the control DOES insert can still leave the bound value alone — typing `.`
        // after `2` gives the editor `2.` and the value `2`, and over there `onChange` does not
        // fire, so `setRow` is not called and the line keeps the money it was saved with. The other
        // half therefore lives where the lock does, in `DocumentLineDraft.unlock(ifBoundValue…)`:
        // the text still updates here, and the lock survives it.
        if draft.lines[index].value(field) != cleaned {
            draft.lines[index].setValue(field, to: cleaned)
        }
        documentEditor = draft
    }

    func addDocumentLine() {
        guard var draft = documentEditor else { return }
        draft.addLine()
        documentEditor = draft
    }

    func removeDocumentLine(id: Int) {
        guard var draft = documentEditor else { return }
        draft.removeLine(id: id)
        documentEditor = draft
    }

    func pickDocumentProduct(lineID: Int, productID: String) {
        guard var draft = documentEditor,
              let index = draft.lines.firstIndex(where: { $0.id == lineID }) else { return }
        let choice = draft.products.first { $0.id == productID }
        DocumentPageComposition.applyProduct(choice, to: &draft.lines[index])
        documentEditor = draft
    }

    /// Create or update, and close the sheet only if the ledger accepted it.
    ///
    /// The editor refuses a document with no usable line before it calls anything, which is where
    /// `documents.error.itemsRequired` comes from — the store accepts an empty line array and would
    /// write a header with nothing under it.
    func saveDocumentEditor() {
        guard let store, let draft = documentEditor else { return }
        guard !draft.isGenerating else { return }
        // The other app's form simply does not submit when a control's own attributes are violated,
        // and the view keeps the button unavailable for the same reason. This is the second half of
        // that: a save arriving any other way is refused here rather than written.
        guard draft.passesTheControlsOwnRules else { return }
        guard !draft.submittableLines.isEmpty || draft.showsReadOnlyLines else {
            documentError = .itemsRequired
            return
        }
        let saved: Bool
        if let editing = draft.editing {
            saved = performDocumentWrite {
                try store.updateBusinessDocument(id: editing.id, draft.edit())
            }
        } else {
            saved = performDocumentWrite { _ = try store.createBusinessDocument(draft.createDraft()) }
        }
        if saved { documentEditor = nil }
    }

    // MARK: The statement generator

    func setStatementCustomer(_ name: String) {
        guard var draft = documentEditor else { return }
        draft.statementCustomer = name
        draft.statementOutcome = nil
        documentEditor = draft
    }

    func setStatementPeriodStart(_ text: String) {
        guard var draft = documentEditor else { return }
        draft.statementPeriodStart = text
        draft.statementOutcome = nil
        documentEditor = draft
    }

    func setStatementPeriodEnd(_ text: String) {
        guard var draft = documentEditor else { return }
        draft.statementPeriodEnd = text
        draft.statementOutcome = nil
        documentEditor = draft
    }

    /// Q2-d: write one statement per currency found, taking one number for each.
    ///
    /// Nothing is written when the period holds no matching income transaction, and the panel says
    /// so rather than producing an empty document. When something IS written the sheet closes and
    /// the list re-reads, which is how the user sees how many documents came out — the standing note
    /// above the button is what told them it could be more than one.
    func generateStatements() {
        guard let store, var draft = documentEditor, draft.isGenerating else { return }
        // The document date this stamps on every statement it writes comes from a field the user
        // can type into, and the other app's control cannot produce anything but a real date. The
        // button is unavailable for the same reason; this is the half that decides the write.
        guard draft.passesTheControlsOwnRules else { return }
        // A period that is not ISO is not a period this generator can use: the store compares these
        // strings against `transactions.date` as TEXT, so `8/1/2026` would sort away from every row
        // and report "no transactions" on a period that has them. Refusing it as "not filled in"
        // keeps the sentence the panel shows TRUE, which reporting an empty result would not.
        guard !draft.statementCustomer.isEmpty,
              DocumentPageComposition.isCalendarDate(draft.statementPeriodStart),
              DocumentPageComposition.isCalendarDate(draft.statementPeriodEnd) else {
            draft.statementOutcome = .needInput
            documentEditor = draft
            return
        }
        let drafts: [StatementDraft]
        do {
            drafts = try store.statementDrafts(customerName: draft.statementCustomer,
                                               periodStart: draft.statementPeriodStart,
                                               periodEnd: draft.statementPeriodEnd)
        } catch {
            documentError = .loadFailed
            return
        }
        guard !drafts.isEmpty else {
            draft.statementOutcome = .noRecords
            documentEditor = draft
            return
        }
        let written = performDocumentWrite {
            _ = try store.createStatements(drafts, date: draft.date, accountingLocale: nil)
        }
        if written { documentEditor = nil }
    }

    // MARK: Row actions

    /// Dispatch one row control. The identifiers are the composition's own, so a control that is
    /// not offered cannot be invoked by name from anywhere else either.
    func performDocumentRowAction(_ id: String, on document: BusinessDocument) {
        guard let action = DocumentPageComposition.RowAction(rawValue: id),
              DocumentPageComposition.actions(for: document.status).contains(action) else { return }
        switch action {
        case .edit:       editDocument(document)
        case .issue:      issueDocument(document)
        case .void:       requestDocumentVoid(document)
        case .delete:     requestDocumentDelete(document)
        case .taxInvoice: openTaxInvoice(document)
        case .export:     exportDocument(document)
        }
    }

    /// Issuing has no confirmation on either side: it is reversible by voiding, and voiding is what
    /// asks.
    func issueDocument(_ document: BusinessDocument) {
        guard let store, !documentWriteIsPending else { return }
        performDocumentWrite {
            try store.updateBusinessDocument(id: document.id, BusinessDocumentEdit(status: .issued))
        }
    }

    func requestDocumentVoid(_ document: BusinessDocument) {
        guard !documentWriteIsPending else { return }
        pendingDocumentVoid = document
    }

    func cancelDocumentVoid() { pendingDocumentVoid = nil }

    // MARK: The artefact (Q7)

    /// One document as HTML, exactly as the file will hold it.
    ///
    /// Split out from ``exportDocument(_:)`` because that one opens a save panel, and a panel is
    /// not something a test can drive. Everything that decides BYTES lives here; the panel only
    /// chooses where they land.
    ///
    /// `locale` is what formats the numbers. Production passes the host's, exactly as the other
    /// app's `toLocaleString(undefined, …)` does; the parity test pins `en_US` on both sides so a
    /// committed golden cannot carry one machine's thousands separator.
    func documentArtefactHTML(for detail: BusinessDocumentDetail,
                              locale: Locale = .autoupdatingCurrent,
                              generatedAt: String = artefactGeneratedAt()) -> String {
        let style = DocumentPageComposition.moneyStyle(currency: detail.document.currency,
                                                       accountingLocale: detail.document.accountingLocale)
        return DocumentHTML.build(
            detail,
            companyName: companyName,
            labels: DocumentPageComposition.artefactLabels(for: detail.document,
                                                           language: language,
                                                           t: { self.t($0) }),
            options: DocumentHTML.Options(
                money: { DocumentPageComposition.money($0, style: style, locale: locale) ?? "" },
                unitLabel: { DocumentPageComposition.artefactUnitLabel($0, t: { self.t($0) }) },
                generatedAt: generatedAt))
    }

    /// Q7: build the file, then let the user say where it goes.
    ///
    /// Reads the document again rather than exporting the row the list is holding: the list carries
    /// headers only, and the artefact is mostly lines.
    func exportDocument(_ document: BusinessDocument) {
        guard let store else { return }
        documentExportOutcome = nil
        guard let detail = try? store.businessDocument(id: document.id) else {
            documentError = .loadFailed
            return
        }
        let block = DocumentPageComposition.ExportBlock(outcome: nil)
        documentExportOutcome = Self.exportOutcome(
            for: saveDocumentHTMLViaPanel(html: documentArtefactHTML(for: detail),
                                          suggestedName: DocumentHTML.fileName(for: detail.document),
                                          panelMessage: t(block.formatNoteKey)))
    }

    /// What a save-panel run leaves on the page.
    ///
    /// Its own function because the interesting case is the one a test could otherwise never see:
    /// **a cancelled panel says nothing at all.** The other app is silent there too (`ok=false` with
    /// no error falls through its `if`), and reporting a failure would tell the user their own
    /// Escape key broke something.
    nonisolated static func exportOutcome(for result: DocumentSaveResult)
        -> DocumentPageComposition.ExportOutcome? {
        switch result {
        case .written(let path): return .done(path: path)
        case .failed:            return .failed
        case .cancelled:         return nil
        }
    }

    /// **B6**: the artefact's timestamp is ISO-8601 UTC, not the host's localized string.
    ///
    /// The other app writes `new Date().toLocaleString(uiLang)`, which has no stable format
    /// contract to port — the same instant reads differently across ICU versions, let alone across
    /// regions. A fixed shape is also what lets Q7-b's byte-for-byte domain exist: an injectable
    /// `now` is only useful if what it produces is deterministic.
    nonisolated static func artefactGeneratedAt(_ now: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: now)
    }

    func confirmDocumentVoid() {
        guard let store, let document = pendingDocumentVoid else { return }
        pendingDocumentVoid = nil
        performDocumentWrite {
            try store.updateBusinessDocument(id: document.id, BusinessDocumentEdit(status: .void))
        }
    }

    func requestDocumentDelete(_ document: BusinessDocument) {
        guard !documentWriteIsPending else { return }
        pendingDocumentDelete = document
    }

    func cancelDocumentDelete() { pendingDocumentDelete = nil }

    /// Delete the row. The store hands back the attachment reference the document held; this round
    /// deliberately does NOT act on it — ruling ③ — so the copy stays on disk. The value is dropped
    /// here rather than passed anywhere, and this is one of the two seams **D-6** connects. The
    /// storage-atomicity round landed what that connection requires — the conditional writes and
    /// `AttachmentDeletion` — but left the wiring alone, and D-6 is gated on TWO rulings that
    /// primitive's registered residuals demand, neither of which answers the other: **race E** (a
    /// freed name re-claimed) and **the `fstatat`→`unlinkat` gap** inside the unlink itself.
    func confirmDocumentDelete() {
        guard let store, let document = pendingDocumentDelete else { return }
        pendingDocumentDelete = nil
        performDocumentWrite { _ = try store.deleteBusinessDocument(id: document.id) }
    }

    // MARK: The association sheet

    func openTaxInvoice(_ document: BusinessDocument) {
        guard !documentWriteIsPending else { return }
        taxInvoiceDraft = TaxInvoiceDraft(document: document)
    }

    func cancelTaxInvoice() { taxInvoiceDraft = nil }

    func setTaxInvoiceIssued(_ value: Bool) { taxInvoiceDraft?.issued = value }
    func setTaxInvoiceNumber(_ text: String) { taxInvoiceDraft?.number = text }
    func setTaxInvoiceDate(_ text: String) { taxInvoiceDraft?.date = text }

    /// Save the association. The store hands back a reference that has just become unreferenced;
    /// ruling ③ says this round does not delete it, so it is dropped here at the single seam.
    func saveTaxInvoice() {
        guard let store, let draft = taxInvoiceDraft else { return }
        // This sheet's save is NOT inside a `<form>` over there. `TaxInvoiceModal.tsx` has no
        // `<form>` element at all and its save is `<button type="button" onClick={handleSave}>`, so
        // NO constraint validation runs on that side — and the date input does not carry `required`
        // either. What refuses over there is the control alone, and it refuses exactly one thing: a
        // date that does not exist. It does not refuse a five-digit year; that one it holds and
        // saves. Here the field is a plain `TextField`, so this gate makes the first guarantee and
        // — by B10 — narrows the second, which is why the sheet draws `dateHintKey` beside it.
        guard DocumentPageComposition.isOptionalCalendarDate(draft.date) else { return }
        let saved = performDocumentWrite {
            _ = try store.updateTaxInvoice(documentID: draft.document.id, draft.edit)
        }
        if saved { taxInvoiceDraft = nil }
    }

    /// One catalogue read, turned into the page's own choice type.
    ///
    /// Only the active items, which is the filter the other app applies to the same control. Rows
    /// that could not be decoded are not among them: an undecodable product is not selectable, and
    /// the page that reports such rows is the products page.
    private func documentProductChoices() -> [DocumentPageComposition.ProductChoice] {
        guard let store, let catalog = try? store.productCatalog() else { return [] }
        return catalog.products
            .filter(\.isActive)
            .map { DocumentPageComposition.ProductChoice(id: $0.id,
                                                         name: $0.name,
                                                         unit: $0.unit ?? "",
                                                         defaultUnitCost: $0.defaultUnitCost) }
    }

    /// The generator's picker domain, read only when the type that has one is selected.
    ///
    /// Q2 · 4: `transactions.counterparty`, trimmed, de-duplicated and ordered on code units by the
    /// Core function — this does not re-sort it, because the ordering rule belongs in one place.
    /// An empty list is what a ledger with no transactions gives, and the panel then offers nothing
    /// to pick, which is the truthful state rather than an error.
    private func statementCustomers(for type: BusinessDocumentType) -> [String] {
        guard type == .statement, let store else { return [] }
        return (try? store.statementCustomerNames()) ?? []
    }

    /// Q3's suggestion for a type, or an empty field when the ledger cannot be asked.
    ///
    /// An empty field is refused on save (`documents.error.numberRequired`) rather than filled with
    /// something invented, which is what the other app's silently-swallowed request leaves behind
    /// too.
    private func suggestedDocumentNumber(for type: BusinessDocumentType) -> String {
        guard let store else { return "" }
        return (try? store.nextBusinessDocumentNumber(for: type)) ?? ""
    }

    /// The date the editor opens on — `new Date().toISOString().split('T')[0]`, which is **UTC**.
    ///
    /// This is NOT the same clock as the document number's year, and the difference is the other
    /// app's rather than a choice made here: `nextNumber` reads `new Date().getFullYear()`, which is
    /// LOCAL, while the form's default date is an ISO string, which is UTC. Q3 records the local
    /// year for the number; the field beside it disagrees with it for up to a day, on both sides,
    /// and mirroring means reproducing that rather than tidying it up.
    ///
    /// Spelled out rather than taken from `Calendar`: the calendar this needs is the proleptic
    /// Gregorian one `toISOString` uses, and `Calendar(identifier: .gregorian)` is ICU's mixed
    /// calendar, which is a different function before 1582. `ISO8601DateFormatter` with an explicit
    /// UTC zone is that calendar.
    static func documentToday(_ now: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withFullDate]
        return formatter.string(from: now)
    }

    /// One amount as the editor shows it, or `nil` for the em dash.
    func documentMoney(_ value: Double?) -> String? {
        DocumentPageComposition.money(value, style: documentMoneyStyle,
                                      locale: Locale.autoupdatingCurrent)
    }

    private var documentMoneyStyle: DocumentPageComposition.MoneyStyle {
        DocumentPageComposition.moneyStyle(
            currency: documentEditor?.editing?.currency,
            accountingLocale: documentEditor?.accountingLocale ?? accountingLocale)
    }

    /// Run one document write and land its outcome.
    ///
    /// On success the list is re-read HERE, so no caller can forget. On failure nothing is reloaded
    /// and the list stays as it was, because nothing in the ledger changed. Anything that is not one
    /// of the store's twelve refusals is mapped to a single sentence rather than printed: its text
    /// carries the statement, the path, or the driver's own words.
    @discardableResult
    private func performDocumentWrite(_ work: () throws -> Void) -> Bool {
        do {
            try work()
        } catch let error as BusinessDocumentError {
            documentError = .store(error)
            return false
        } catch {
            documentError = .saveFailed
            return false
        }
        documentError = nil
        reloadDocuments()
        return true
    }
}

// MARK: - The restore interlock, as one predicate

extension LegacyConversionState {
    /// Whether a destructive restore-from-backup may start while the wizard is in this state.
    ///
    /// **Only `.idle`.** Written as an allow-list of one rather than as a deny-list, so a state
    /// added later is refused until somebody decides otherwise — the safe direction for a check
    /// that guards a ledger replacement.
    ///
    /// Every other state is a claim about the ledger that is on disk NOW: `.summary` holds a
    /// plan (row identities, source fingerprints) of it, `.running` has a second connection
    /// writing to it, `.completed` holds the only on-screen copy of the pre-conversion backup
    /// path, and `.blocked` / `.failed` describe its settings and its refusals. A restore
    /// replaces the file underneath all of them, leaving statements that still read as true.
    ///
    /// The single source both the model guard and the Settings button read — see
    /// ``AppModel/canRestoreFromBackup``.
    var permitsDestructiveRestore: Bool {
        switch self {
        case .idle:
            return true
        case .blocked, .summary, .running, .completed, .failed:
            return false
        }
    }

    /// The state's NAME, and nothing from inside it.
    ///
    /// ## Why this exists rather than `String(describing:)`
    ///
    /// Every case but `.idle` carries a payload, and `String(describing:)` walks straight into
    /// it: `.blocked` would print the ledger's stored accounting-profile or currency bytes,
    /// `.summary` / `.running` the whole plan — legacy row identities, stored dates, issue
    /// names, the currency — and `.completed` the pre-conversion backup PATH. The refusal is
    /// logged at `.public`, which is the level that survives into a sysdiagnose, so that string
    /// is the one place where a diagnostic aid would have become a disclosure.
    ///
    /// Six literals, one per case, and an EXHAUSTIVE switch with no `default`: a case added
    /// later fails the build here instead of silently falling into an "unknown" bucket that
    /// somebody would then be tempted to fill with the value itself.
    var diagnosticLabel: String {
        switch self {
        case .idle:      return "idle"
        case .blocked:   return "blocked"
        case .summary:   return "summary"
        case .running:   return "running"
        case .completed: return "completed"
        case .failed:    return "failed"
        }
    }
}

extension LegacyConversionDiagnostics {
    /// A refused restore.
    ///
    /// Takes the STATE, not a string, and does the narrowing itself. A `String` parameter is
    /// what let `String(describing:)` reach the log in the first place; with the state as the
    /// parameter there is no argument a caller can construct that carries a payload, because
    /// the only thing that ever reaches the format string is
    /// ``LegacyConversionState/diagnosticLabel`` — one of six literals.
    ///
    /// That label is the only part logged at `.public`. It is what makes a report of "the
    /// restore button did nothing" diagnosable, and it says nothing about the ledger.
    static func restoreRefused(_ state: LegacyConversionState) {
        logger.error("""
            restore-from-backup refused: a legacy conversion is in \
            \(state.diagnosticLabel, privacy: .public)
            """)
    }
}

#if DEBUG
/// DEBUG-only UI-test boot harness, activated by `--migration-boot-harness chooseSource`.
/// It lets UI tests exercise the REAL production consumption point — RootView's non-preview
/// `productionData` supplying `MigrationSourceChoiceView`'s closures — by faking ONLY the
/// `BootChainRunner` seam (the same seam every hosted intent guard fakes) plus the blocking
/// panel `runModal()` (see `boot()`). Nothing here touches the DEBUG preview or supplies
/// synthetic action closures; none of it is compiled into Release, and it is inert without
/// the launch argument.
enum DebugBootHarness {
    /// The deterministic "granted" directory the panel override returns. Never touched on
    /// disk — the harness runner is scripted, so no ingest ever runs.
    static var grantURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("HarnessGrantedDir", isDirectory: true)
    }

    /// Witness keys the read-out bar renders in harness mode (all seeded at 0 by default).
    static let witnessKeys = ["panel.run", "panel.singleDirectory",
                              "intent.migrateFromUserDir", "intent.migrateFromUserDir.grantMatched",
                              "intent.confirmCreateFresh"]

    static var isActive: Bool {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--migration-boot-harness"), i + 1 < args.count else { return false }
        return args[i + 1] == "chooseSource"
    }

    /// Scripted runner: records each received intent into the witness and parks EVERY
    /// resolution back in `.requiresSourceChoice` — no store is ever constructed and the
    /// choice screen returns after each action, so a single launch can exercise both actions.
    struct Runner: BootChainRunner {
        @MainActor func resolveOutcome(_ intent: BootIntent) async -> BootOutcome {
            switch intent {
            case .migrateFromUserDir(let source):
                DebugActionWitness.shared.record("intent.migrateFromUserDir")
                if case .userSelectedDataDir(let url) = source, url == DebugBootHarness.grantURL {
                    DebugActionWitness.shared.record("intent.migrateFromUserDir.grantMatched")
                }
            case .confirmCreateFresh:
                DebugActionWitness.shared.record("intent.confirmCreateFresh")
            case .boot, .acknowledgement, .selection:
                break
            }
            return .requiresSourceChoice
        }

        @MainActor func attempt(_ authorization: StoreOpenAuthorization,
                                residual: MigrationResidual?) -> MigrationBootDriver.Attempt {
            // Unreachable: the harness never authorizes an open. Park harmlessly.
            .ui(.awaitingSourceChoice)
        }
    }
}
#endif
