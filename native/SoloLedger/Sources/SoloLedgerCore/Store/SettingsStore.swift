import Foundation

/// Read/write the `settings` key/value table. Values are JSON-encoded exactly as
/// the Electron app does (`JSON.stringify`), so a bare string 'CN' is stored as
/// the 4-byte text `"CN"` and a bool as `true`. This keeps settings written by
/// either app mutually readable.
public struct SettingsStore {
    private let db: SQLiteDatabase

    public init(_ db: SQLiteDatabase) { self.db = db }

    // MARK: - Known keys used by the prototype
    public enum Key {
        public static let accountingLocale = "accounting_locale"
        public static let uiLanguage = "ui_language"
        public static let appearance = "appearance"        // native-only: system/light/dark
        public static let onboardingDone = "onboarding_done"
        public static let companyName = "company_name"
        public static let currency = "currency"
        // Report calculation parameters, shared with the Electron report engines.
        public static let vatRate = "vat_rate"
        public static let surchargeRate = "surcharge_rate"
        public static let incomeTaxRate = "income_tax_rate"
        public static let adminExpenseAnnual = "admin_expense_annual"
    }

    // MARK: - Raw JSON get/set

    public func rawValue(_ key: String) throws -> String? {
        try db.query("SELECT value FROM settings WHERE key = ?", [.text(key)]).first?.string("value")
    }

    private func writeRaw(_ key: String, _ json: String) throws {
        try db.run("""
            INSERT INTO settings (key, value, updated_at) VALUES (?, ?, datetime('now'))
            ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = datetime('now')
            """, [.text(key), .text(json)])
    }

    // MARK: - Typed accessors (JSON-encoded to match JSON.stringify)

    public func string(_ key: String) throws -> String? {
        guard let raw = try rawValue(key) else { return nil }
        return JSONFragment.decodeString(raw)
    }

    public func setString(_ value: String, for key: String) throws {
        try writeRaw(key, JSONFragment.encodeString(value))
    }

    public func bool(_ key: String, default fallback: Bool = false) throws -> Bool {
        guard let raw = try rawValue(key) else { return fallback }
        return JSONFragment.decodeBool(raw) ?? fallback
    }

    public func setBool(_ value: Bool, for key: String) throws {
        try writeRaw(key, value ? "true" : "false")
    }

    /// A numeric setting. Electron persists these inconsistently — its accounting
    /// section and onboarding wizard write JSON numbers (`13`) while its tax settings
    /// screen writes a JSON string (`"13"`) — so BOTH encodings are accepted here.
    /// Returns nil when the row is absent or the value is not a number.
    public func number(_ key: String) throws -> Double? {
        guard let raw = try rawValue(key) else { return nil }
        return JSONFragment.decodeNumber(raw)
    }

    /// Writes a JSON number, matching `JSON.stringify` (13 → `13`, 23.2 → `23.2`) —
    /// the encoding the report engines' `JSON.parse` + `Number()` path expects.
    public func setNumber(_ value: Double, for key: String) throws {
        guard value.isFinite else { throw SettingsStoreError.nonFiniteNumber(key: key) }
        try writeRaw(key, JSONFragment.encodeNumber(value))
    }

    /// Delete a setting. An absent row is a real, supported state: the report engines
    /// fall back to their own defaults for a key that is not there, so "unset" must be
    /// reachable rather than being approximated with a 0 the user never chose.
    public func remove(_ key: String) throws {
        try db.run("DELETE FROM settings WHERE key = ?", [.text(key)])
    }

    // MARK: - Convenience

    /// The regime to DISPLAY, with a deliberate fallback.
    ///
    /// The `.CN` returned for an absent or unrecognisable row is a **display fallback and
    /// nothing more**. It is not a claim that the ledger chose China: the report engines
    /// refuse that same row (`ReportBlocker.accountingLocaleNotConfigured` /
    /// `.accountingLocaleInvalid`) rather than compute under a regime nobody selected.
    ///
    /// It stays because the rest of the app needs SOME regime to keep working — categories
    /// are seeded per regime, and the editor and overview need them — and because two boot
    /// paths (`AppModel.finishBoot`, the C12 adoption) treat this as a REQUIRED read: making
    /// it throw would turn one damaged row into a ledger that cannot be opened at all.
    ///
    /// **Anything that must know whether the ledger really chose a regime asks
    /// ``accountingLocaleState()`` instead**, which answers with the same rule the engines use.
    public func accountingLocale() throws -> AccountingLocale {
        guard let raw = try string(Key.accountingLocale), let loc = AccountingLocale(rawValue: raw) else { return .CN }
        return loc
    }

    /// What the `accounting_locale` row actually holds, classified by the SAME rule the
    /// report engines apply — see ``ReportSettings/recognizedAccountingLocale(fromStoredText:)``.
    ///
    /// Distinct from ``accountingLocale()``, which answers with a display fallback. This one
    /// never invents a regime: an absent row is `.absent` and an unrecognisable one is
    /// `.unreadable`, carrying the stored text byte for byte so a screen can show it verbatim.
    /// A read failure throws rather than being reported as `.absent` — a row this app could
    /// not read is not a row it may describe.
    public func accountingLocaleState() throws -> StoredLocaleState {
        guard let raw = try rawValue(Key.accountingLocale) else { return .absent }
        guard let locale = ReportSettings.recognizedAccountingLocale(fromStoredText: raw) else {
            return .unreadable(storedText: raw)
        }
        return .configured(locale)
    }

    /// Commit an accounting-regime switch: the regime itself plus that regime's preset
    /// rates and currency, in ONE transaction. Mirrors `applyProfile` in
    /// components/AccountingSection.tsx, which saves the same five keys in a single
    /// request — a half-applied switch would leave the ledger claiming one regime while
    /// holding another's rates, and the report engines read the two independently.
    public func applyRegimeSwitch(_ profile: AccountingProfile) throws {
        try db.transaction {
            try setString(profile.locale.rawValue, for: Key.accountingLocale)
            try setNumber(profile.vatRate, for: Key.vatRate)
            try setNumber(profile.surchargeRate, for: Key.surchargeRate)
            try setNumber(profile.incomeTaxRate, for: Key.incomeTaxRate)
            try setString(profile.currency, for: Key.currency)
        }
    }

    /// The four report calculation parameters exactly as stored (absent stays absent —
    /// an absent row is what the report engines' own fallbacks are for).
    public func reportParameters() throws -> ReportParametersStored {
        ReportParametersStored(
            vatRate: try number(Key.vatRate),
            surchargeRate: try number(Key.surchargeRate),
            incomeTaxRate: try number(Key.incomeTaxRate),
            adminExpenseAnnual: try number(Key.adminExpenseAnnual)
        )
    }
}

/// What the `accounting_locale` row holds, as the report engines read it.
///
/// Three states and no fourth: the row is there and names one of the six regimes, the row is
/// there and does not, or the row is not there. `.unreadable` keeps the stored text byte for
/// byte — including a leading U+FEFF, which is exactly the byte that used to make two readers
/// disagree — so a screen can show the user what is really in their ledger.
public enum StoredLocaleState: Equatable {
    case configured(AccountingLocale)
    case unreadable(storedText: String)
    case absent
}

public enum SettingsStoreError: Error, Equatable {
    /// A NaN/infinite value was never written — it would poison the report engines,
    /// whose `Number()` coercion has no finiteness guard.
    case nonFiniteNumber(key: String)
}

/// Minimal JSON-fragment (top-level scalar) encode/decode, matching JSON.stringify.
enum JSONFragment {
    static func encodeString(_ s: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        // Fallback manual escaping.
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    static func decodeString(_ json: String) -> String? {
        if let data = json.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            if let s = obj as? String { return s }
            return nil
        }
        return nil
    }

    /// `JSON.stringify` for a finite Double: integral values lose the `.0` Swift adds
    /// (13.0 → "13"), everything else uses Swift's shortest round-trip form, which
    /// agrees with JS for the values a settings field can produce (23.2 → "23.2").
    static func encodeNumber(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return String(value)
    }

    /// Accepts a JSON number (`13`) or a JSON string holding one (`"13"`); rejects
    /// booleans, which `JSONSerialization` would otherwise hand back as 1/0.
    static func decodeNumber(_ json: String) -> Double? {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "true" || trimmed == "false" { return nil }
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        if let n = obj as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            return n.doubleValue.isFinite ? n.doubleValue : nil
        }
        if let s = obj as? String {
            guard let d = Double(s.trimmingCharacters(in: .whitespaces)), d.isFinite else { return nil }
            return d
        }
        return nil
    }

    static func decodeBool(_ json: String) -> Bool? {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "true" { return true }
        if trimmed == "false" { return false }
        return nil
    }
}
