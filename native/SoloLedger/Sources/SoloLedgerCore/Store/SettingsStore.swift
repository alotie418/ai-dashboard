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

    // MARK: - Convenience

    public func accountingLocale() throws -> AccountingLocale {
        guard let raw = try string(Key.accountingLocale), let loc = AccountingLocale(rawValue: raw) else { return .CN }
        return loc
    }
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

    static func decodeBool(_ json: String) -> Bool? {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "true" { return true }
        if trimmed == "false" { return false }
        return nil
    }
}
