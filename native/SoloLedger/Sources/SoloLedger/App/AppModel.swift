import SwiftUI
import SoloLedgerCore

enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case overview
    case transactions
    case categories
    var id: String { rawValue }
    var titleKey: String { "nav.\(rawValue)" }
    var systemImage: String {
        switch self {
        case .overview: return "chart.bar.doc.horizontal"
        case .transactions: return "list.bullet.rectangle"
        case .categories: return "tag"
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
    @Published var companyName: String = ""

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

    private var localizer: Localizer
    private(set) var store: LedgerStore?

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
            do { let built = try Self.makeProductionRunner(); runner = built; activeRunner = built }
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
                    adopt(candidate, residual: candidateResidual, generation: gen); return
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
    private func adopt(_ candidate: LedgerStore, residual: MigrationResidual?, generation gen: Int) {
        guard gen == bootGeneration else { return }   // stale: a superseded chain owns NOTHING — never touch inFlight/state
        let savedLang: String?
        let savedAppearance: String?
        let loc: AccountingLocale
        do {
            savedLang = try candidate.settings.string(SettingsStore.Key.uiLanguage)
            savedAppearance = try candidate.settings.string(SettingsStore.Key.appearance)
            loc = try candidate.settings.accountingLocale()
        } catch {
            finish(.retriable(MigrationBlock(code: .storeOpenFailed, classification: .retriable,
                                             params: ["op": "adopt"])), generation: gen)
            return
        }
        let done = (try? candidate.settings.bool(SettingsStore.Key.onboardingDone)) ?? false
        let co = (try? candidate.settings.string(SettingsStore.Key.companyName)) ?? ""
        // Required reads passed; optional reads above are best-effort defaults. Publish now —
        // `reloadAll` below may set `actionError` but never un-publishes the store.
        store = candidate
        if let savedLang { setLanguage(savedLang, persist: false) }
        if let savedAppearance, let ap = Appearance(rawValue: savedAppearance) { appearance = ap }
        accountingLocale = loc
        onboardingDone = done
        companyName = co
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
    private static func makeProductionRunner() throws -> BootChainRunner {
        let config = try MigrationCoordinator.Config.standard()
        return makeBootChainRunner(coordinator: MigrationCoordinator(config: config),
                                   autoSourceCandidate: .masContainer,
                                   activeURL: config.activeDestination)
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
                                    activeURL: URL) -> ProductionBootChainRunner {
        ProductionBootChainRunner(
            resolveWork: { intent in
                switch intent {
                case .boot: return coordinator.bootResolve(autoSourceCandidate: auto)
                case .acknowledgement(let ack): return coordinator.bootResolve(autoSourceCandidate: auto, acknowledgement: ack)
                case .selection(let id): return coordinator.resolveSelectedImport(importID: id)
                // N7.1 DORMANT mappings — no UI emits these intents until N7.2. The confirmed
                // create-fresh goes to the coordinator's dedicated strong-typed entry (which
                // takes NO auto candidate by construction); an explicit user source goes 1:1
                // to `runImport`, never mixed with the auto candidate.
                case .confirmCreateFresh: return coordinator.confirmCreateFresh()
                case .migrateFromUserDir(let source): return coordinator.runImport(source: source)
                }
            },
            // The auto candidate is handed to EVERY confirm; the coordinator itself only
            // consults it for a createFresh authorization (where it can revoke → reResolve).
            confirm: { coordinator.confirmOpenAuthorization($0, autoSourceCandidate: auto) },
            openStore: { try Self.openStoreForPlan($0, activeURL: activeURL) })
    }

    /// The REAL production plan → store dispatch, extracted (internal, NOT an injected test double)
    /// so a hosted test can drive the exact wiring `makeProductionRunner` ships: an `.existing`
    /// plan MUST take the C12x hardened open, never a plain `existingOnly`. Reverting the
    /// `.existing` branch to `LedgerStore(open: .existingOnly)` is what the production-wiring guard
    /// test in `AppModelBootTests` catches.
    static func openStoreForPlan(_ plan: ConfirmedOpenPlan, activeURL: URL) throws -> LedgerStore {
        switch plan {
        case .createFresh:
            // C12x-A2: exclusive descriptor reservation + NOFOLLOW/HAS_MOVED/fingerprint before adopt.
            return try LedgerStore.createFreshReservedHardened(databaseURL: activeURL)
        case .existing(let evidence):
            return try LedgerStore.openActiveExistingHardened(databaseURL: activeURL, expect: evidence)
        }
    }

    /// Open + load an active store and mark the app ready.
    private func finishBoot(with store: LedgerStore) throws {
        self.store = store
        if let savedLang = try store.settings.string(SettingsStore.Key.uiLanguage) {
            setLanguage(savedLang, persist: false)
        }
        if let savedAppearance = try store.settings.string(SettingsStore.Key.appearance),
           let ap = Appearance(rawValue: savedAppearance) {
            appearance = ap
        }
        accountingLocale = try store.settings.accountingLocale()
        companyName = (try? store.settings.string(SettingsStore.Key.companyName)) ?? ""
        onboardingDone = (try? store.settings.bool(SettingsStore.Key.onboardingDone)) ?? false
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

    func reloadAll() {
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

    // MARK: - Demo data (DEBUG / .dev only — never touches production data)

    var isLedgerEmpty: Bool { transactions.isEmpty && currencySummaries.isEmpty }

    #if DEBUG
    /// Seed anonymized demo data. Idempotent: `DemoData.seed` is a no-op on a
    /// non-empty ledger, so repeated taps never duplicate.
    func loadDemoData() {
        guard let store else { return }
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

    func setAccountingLocale(_ locale: AccountingLocale) {
        accountingLocale = locale
        try? store?.settings.setString(locale.rawValue, for: SettingsStore.Key.accountingLocale)
        reloadAll()
    }

    func setCompanyName(_ name: String) {
        companyName = name
        try? store?.settings.setString(name, for: SettingsStore.Key.companyName)
    }

    func completeOnboarding() {
        onboardingDone = true
        try? store?.settings.setBool(true, for: SettingsStore.Key.onboardingDone)
        reloadAll()
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

    var schemaVersionText: String {
        (try? store?.schemaVersion()).flatMap { $0 }.map(String.init) ?? "—"
    }

    var databasePath: String {
        (try? AppPaths.databaseURL().path) ?? "—"
    }
}
