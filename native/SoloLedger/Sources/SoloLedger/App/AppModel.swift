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

/// Central observable app state. Owns the single `LedgerStore` connection and the
/// UI-language localizer. All mutations funnel through here so views stay thin.
@MainActor
final class AppModel: ObservableObject {
    // Data
    @Published private(set) var transactions: [Transaction] = []
    @Published private(set) var categories: [Category] = []
    @Published private(set) var summary = LedgerSummary()
    @Published private(set) var monthly: [MonthlyTotal] = []

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
    @Published var migrationFailure: String?

    // Editor sheet state (nil editingTransaction = creating a new one)
    @Published var showingEditor = false
    @Published var editingTransaction: Transaction?

    private var localizer: Localizer
    private var store: LedgerStore?

    init() {
        let initial = Localizer.systemDefault()
        self.language = initial
        self.localizer = Localizer(language: initial)
    }

    // MARK: - Localization

    func t(_ key: String) -> String { localizer.t(key) }
    func t(_ key: String, _ replacements: [String: String]) -> String { localizer.t(key, replacements) }
    func categoryLabel(_ category: Category) -> String { category.label(for: language) }

    // MARK: - Boot

    func boot() {
        guard store == nil else { return }
        do {
            // Decide what to do about the active database. In the native RELEASE app
            // (same Bundle ID → same MAS container) this discovers an Electron DB and
            // migrates it via backup/integrity/atomic-swap; the original is only read
            // and is never modified. In DEBUG (.dev, isolated container) there is no
            // legacy data, so it creates a fresh DB — no extra entitlement to reach the
            // production container is ever requested.
            //
            // CRITICAL: if a legacy DB exists but the upgrade FAILS, the decision is
            // .blockedMigrationFailed and NO active database is created. We must never
            // paper over a failed migration with an empty ledger — the user recovers
            // from the blocking screen (retry / restore / explicit blank).
            let decision = try DatabaseUpgrade.standard(timestamp: DateFormat.timestamp()).prepareActiveDatabase()
            switch decision {
            case .blockedMigrationFailed(let error):
                migrationFailure = error   // ready stays false, store stays nil
                return
            case let .adopted(_, migrated):
                NSLog("[upgrade] adopted Electron database: \(migrated) transactions")
            case .openExisting, .createFresh:
                break
            }
            try finishBoot(with: LedgerStore(databaseURL: AppPaths.databaseURL()))
        } catch {
            bootError = "\(error)"
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

    /// Retry the migration. Since a failed upgrade never created an active DB, boot
    /// re-discovers the (still-absent) active DB and runs the upgrade again.
    func retryMigration() {
        migrationFailure = nil
        store = nil
        boot()
    }

    /// Adopt a user-picked backup / export database as the active DB, via the same
    /// safe upgrade path (integrity + backup + migrate + atomic swap).
    func restore(fromBackupAt fileURL: URL) {
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
            store = nil
            boot()   // active DB now exists → opens it
        } catch {
            migrationFailure = "从备份恢复失败：\(error)"
        }
    }

    /// Start a BLANK ledger, accepting that the Electron data is not imported. Only
    /// call this after explicit user confirmation in the recovery UI. The original
    /// Electron database is still never modified.
    func createBlankLedgerConfirmed() {
        do {
            try finishBoot(with: LedgerStore(databaseURL: AppPaths.databaseURL()))
        } catch {
            bootError = "\(error)"
        }
    }

    // MARK: - Loading

    func reloadAll() {
        guard let store else { return }
        do {
            categories = try store.categories(locale: accountingLocale)
            transactions = try store.listTransactions(type: filter.type)
            summary = try store.summary()
            monthly = try store.monthlyTotals()
        } catch {
            actionError = "\(error)"
        }
    }

    func reloadTransactions() {
        guard let store else { return }
        do {
            transactions = try store.listTransactions(type: filter.type)
        } catch { actionError = "\(error)" }
    }

    func categories(for type: TransactionType) -> [Category] {
        categories.filter { $0.type == type }
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

    func delete(ids: Set<Transaction.ID>) {
        guard let store, !ids.isEmpty else { return }
        do {
            for id in ids { try store.delete(id: id) }
            reloadAll()
        } catch { actionError = "\(error)" }
    }

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
