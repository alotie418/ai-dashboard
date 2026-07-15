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
            let url = try AppPaths.databaseURL()
            let store = try LedgerStore(databaseURL: url)
            self.store = store

            // Load persisted preferences (created lazily on first run).
            if let savedLang = try store.settings.string(SettingsStore.Key.uiLanguage) {
                setLanguage(savedLang, persist: false)
            }
            if let savedAppearance = try store.settings.string(SettingsStore.Key.appearance),
               let ap = Appearance(rawValue: savedAppearance) {
                appearance = ap
            }
            accountingLocale = try store.settings.accountingLocale()
            companyName = (try? store.settings.string(SettingsStore.Key.companyName)) ?? "" ?? ""
            onboardingDone = (try? store.settings.bool(SettingsStore.Key.onboardingDone)) ?? false

            reloadAll()
            ready = true
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
