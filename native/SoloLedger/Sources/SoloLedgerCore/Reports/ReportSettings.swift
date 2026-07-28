import Foundation

/// `readSetting` — mirror of `electron/reports/index.js:16-21`.
///
/// ```js
/// function readSetting(db, key, fallback) {
///   try {
///     const row = db.prepare('SELECT value FROM settings WHERE key = ?').get(key);
///     return row ? JSON.parse(row.value) : fallback;
///   } catch { return fallback; }
/// }
/// ```
///
/// Two details that a reasonable-looking Swift version gets wrong:
///
/// 1. **A missing row returns the FALLBACK LITERAL, not null.** So the coercion
///    that follows (`Number(...)` at `index.js:74-78`) never sees the absence.
///    This is the mechanism behind plan §6.2's hard constraint: "not configured"
///    cannot be inferred from the computed value, because a missing rate row
///    produces a perfectly ordinary number.
/// 2. **A `JSON.parse` failure also returns the fallback**, because the `try`
///    wraps the whole body. It does NOT produce NaN. (The R2 parity test has a
///    helper that returns `.nan` there; that branch is unreachable from the
///    fixture and would be a bug if promoted to production, so this type exists
///    rather than that helper being lifted.)
///
/// Deliberately NOT `SettingsStore.number`, which returns `nil` both for a missing
/// row and for an unparseable one — collapsing the two states §6.2 depends on
/// telling apart. Batch 2 reads no tax rates, so it needs no three-state
/// machinery; it needs a primitive that does not destroy the distinction before
/// R6 arrives to use it.
public enum ReportSettings {

    /// The raw stored JSON text for a key, or nil when the row (or the table) is
    /// absent. The caller applies the fallback, exactly as the JS does.
    static func rawValue(_ db: SQLiteDatabase, _ key: String) -> String? {
        // The catch is load-bearing: `settings` may not exist at all on an
        // early-schema database, and index.js:20 swallows that too.
        guard let rows = try? db.query("SELECT value FROM settings WHERE key = ?", [.text(key)])
        else { return nil }
        return rows.first?.string("value")
    }

    /// `settingRowExists` — mirror of `electron/reports/index.js:23-33` (the function itself is `:29-33`).
    ///
    /// ```js
    /// function settingRowExists(db, key) {
    ///   try {
    ///     return !!db.prepare('SELECT 1 AS present FROM settings WHERE key = ?').get(key);
    ///   } catch { return false; }
    /// }
    /// ```
    ///
    /// A SEPARATE query, not `rawValue(...) != nil`. The two agree today —
    /// `settings.value` is `TEXT NOT NULL` in both schemas — so this is not a bug
    /// fix; it is the question being asked in the form it is meant. `rawValue`
    /// reads the VALUE and would report a row with a SQL NULL value as no row at
    /// all, which is the one confusion A-3 cannot afford. Asking about the row
    /// stays correct if that column ever loosens.
    ///
    /// The `catch` is load-bearing for the same reason it is in ``rawValue``: on an
    /// early-schema database the `settings` table may not exist, and `index.js:31`
    /// swallows that too. "Cannot ask" answers false, which for a non-Chinese
    /// regime means not-configured — the honest reading, since a ledger with no
    /// settings table has certainly not configured a tax rate.
    static func rowExists(_ db: SQLiteDatabase, _ key: String) -> Bool {
        guard let rows = try? db.query("SELECT 1 AS present FROM settings WHERE key = ?",
                                       [.text(key)])
        else { return false }
        return !rows.isEmpty
    }

    /// `index.js:88-99` — the income-tax rate, as the three states of plan §6.2.
    ///
    /// ```js
    /// const incomeTaxRate = (locale === 'CN' || settingRowExists(db, 'income_tax_rate'))
    ///   ? Number(readSetting(db, 'income_tax_rate', 25))
    ///   : null;
    /// ```
    ///
    /// The order of the two conditions is the mirror's, and it matters: China never
    /// asks about the row, so a Chinese ledger's behaviour is byte-for-byte what it
    /// was before scheme A landed.
    ///
    /// - Parameter locale: the ALREADY-RESOLVED accounting locale — the one the
    ///   dispatcher will route on (`index.js:27`), not whatever is in `settings`.
    ///   Passing the stored value where an explicit `opts.locale` overrode it would
    ///   gate on one regime and compute under another.
    public static func incomeTaxRate(_ db: SQLiteDatabase, locale: String) -> IncomeTaxRateSetting {
        if locale == "CN" {
            // A-2: China keeps the fallback. Whether the row exists still decides
            // WHICH case, because "the app applied 25" and "the user stored 25" are
            // different facts even when they are the same number.
            guard rowExists(db, "income_tax_rate") else { return .chinaFallback(25) }
            return .configured(number(db, "income_tax_rate", fallback: 25))
        }
        guard rowExists(db, "income_tax_rate") else { return .notConfigured }
        return .configured(number(db, "income_tax_rate", fallback: 25))
    }

    /// `readSetting(db, key, fallback)` for a STRING-valued setting
    /// (`accounting_locale`, `currency`).
    public static func string(_ db: SQLiteDatabase, _ key: String, fallback: String) -> String {
        guard let raw = rawValue(db, key) else { return fallback }
        guard case .string(let s)? = jsonFragment(raw) else {
            // JSON.parse succeeded but the value is not a string, or it threw.
            // Either way index.js hands the raw parsed value straight on; for the
            // two string keys R3 reads, anything non-string is out of contract and
            // the fallback is the honest answer. Recorded rather than invented:
            // no fixture and no golden exercises it.
            return fallback
        }
        return s
    }

    /// `Number(readSetting(db, key, fallback))` for a NUMERIC setting
    /// (`admin_expense_annual`).
    ///
    /// The fallback is substituted BEFORE the coercion, so `Number()` never sees a
    /// missing row — which is the whole of point 1 above.
    public static func number(_ db: SQLiteDatabase, _ key: String, fallback: Double) -> Double {
        guard let raw = rawValue(db, key) else { return fallback }
        guard let parsed = jsonFragment(raw) else { return fallback }   // JSON.parse threw
        return ReportMath.number(parsed)
    }

    /// `JSON.parse` of a settings value, as a `ReportMath.JSValue`; nil when the
    /// parse throws.
    static func jsonFragment(_ text: String) -> ReportMath.JSValue? {
        guard let data = text.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return nil }
        return jsValue(any)
    }

    static func jsValue(_ any: Any) -> ReportMath.JSValue {
        if any is NSNull { return .null }
        if let n = any as? NSNumber {
            // NSNumber erases Bool into a number, and CFBoolean identity is the
            // only way back — `Number(true)` is 1 where `Number("true")` is NaN.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .boolean(n.boolValue) }
            return .number(n.doubleValue)
        }
        if let s = any as? String { return .string(s) }
        if let a = any as? [Any] { return .array(a.map(jsValue)) }
        return .object
    }
}
