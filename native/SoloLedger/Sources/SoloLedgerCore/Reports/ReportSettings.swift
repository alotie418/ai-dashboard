import Foundation

/// `readSetting` — mirror of `electron/reports/index.js readSetting`.
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
///    that follows (`Number(...)` at `index.js vatRate`) never sees the absence.
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
enum ReportSettings {

    /// The raw stored JSON text for a key, or nil when the row (or the table) is
    /// absent. The caller applies the fallback, exactly as the JS does.
    static func rawValue(_ db: SQLiteDatabase, _ key: String) -> String? {
        // The catch is load-bearing: `settings` may not exist at all on an
        // early-schema database, and index.js readSetting swallows that too.
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
    /// early-schema database the `settings` table may not exist, and `index.js settingRowExists`
    /// swallows that too. "Cannot ask" answers false, which for a non-Chinese
    /// regime means not-configured — the honest reading, since a ledger with no
    /// settings table has certainly not configured a tax rate.
    static func rowExists(_ db: SQLiteDatabase, _ key: String) -> Bool {
        guard let rows = try? db.query("SELECT 1 AS present FROM settings WHERE key = ?",
                                       [.text(key)])
        else { return false }
        return !rows.isEmpty
    }

    /// `index.js:88-99` — the income-tax rate, as the four states of plan §6.2 / §6.4.
    ///
    /// ```js
    /// const incomeTaxRate = (locale === 'CN' || settingRowExists(db, 'income_tax_rate'))
    ///   ? Number(readSetting(db, 'income_tax_rate', 25))
    ///   : null;
    /// ```
    ///
    /// - Parameter locale: the ALREADY-RESOLVED accounting locale — the one the
    ///   dispatcher will route on (`index.js:27`), not whatever is in `settings`.
    ///   Passing the stored value where an explicit `opts.locale` overrode it would
    ///   gate on one regime and compute under another.
    static func incomeTaxRate(_ db: SQLiteDatabase, locale: String) -> ReportRateSetting {
        rate(db, "income_tax_rate", locale: locale, chinaFallback: 25)
    }

    /// `index.js:87` — the surcharge rate, in the same four states.
    ///
    /// ```js
    /// const surchargeRate = Number(readSetting(db, 'surcharge_rate', 12));
    /// ```
    ///
    /// **Only China's engine reads it** (`cn.js:33`), so outside China this answers
    /// ``ReportRateSetting/notConfigured`` for a missing row and R7 must simply not
    /// look — a Japanese report must NOT be blocked because a rate no Japanese line
    /// consumes has no row. Modelled anyway, and not skipped, because the state that
    /// does matter everywhere is ``ReportRateSetting/needsRepair``: the `malformed`
    /// golden sets this key to `"12%"`, and China's five null fields in
    /// `malformed-CN-2025.json` come from THIS row, not from the income-tax one.
    ///
    /// R6's `ReportContext` note said this parameter "has no missing state to model".
    /// That was true of *not-configured* and false of *needs-repair*; this is the
    /// correction.
    static func surchargeRate(_ db: SQLiteDatabase, locale: String) -> ReportRateSetting {
        rate(db, "surcharge_rate", locale: locale, chinaFallback: 12)
    }

    /// The shared resolution: row presence first (A-3), then the STORED TEXT (A-4).
    ///
    /// The order of the two questions is the mirror's, and it matters: China never
    /// asks about row presence, so a Chinese ledger's not-configured behaviour is
    /// byte-for-byte what it was before scheme A landed.
    ///
    /// Note what is deliberately NOT used here: ``number(_:_:fallback:)``. That
    /// function mirrors `readSetting`'s swallowing `catch`, so an unparseable row
    /// comes back as the FALLBACK — a US ledger reading 25. Faithful to today's
    /// JavaScript, and exactly the state A-4 exists to stop treating as a rate. The
    /// classification below therefore reads ``rawValue(_:_:)`` and decides for itself.
    ///
    /// **This is where the two apps currently disagree, on purpose.** Until A4-3 lands
    /// the Electron engines still coerce these rows (to `NaN`, to `0`, or to the
    /// fallback 25 — see ``classifyRate(_:)``), so for a malformed row the native
    /// model says "needs repair" while `electron/reports/*` still emits a number. The
    /// divergence is inert because the estimate layer that would consume it is R7, and
    /// `ReportRateSettingTests` pins it explicitly rather than leaving it to be
    /// discovered.
    static func rate(_ db: SQLiteDatabase, _ key: String,
                     locale: String, chinaFallback: Double) -> ReportRateSetting {
        guard rowExists(db, key) else {
            // A-2 / A-1: absence. China keeps its fallback; nobody else invents one.
            guard let fallback = FiniteRate(chinaFallback) else { return .notConfigured }
            return locale == "CN" ? .chinaFallback(fallback) : .notConfigured
        }
        // The row exists, so `rawValue` can only be nil if the value column itself is
        // unreadable. `settings.value` is TEXT NOT NULL in both schemas, so this is
        // unreachable today; answering "needs repair" is the honest reading of a row
        // that is there but says nothing.
        guard let raw = rawValue(db, key) else { return .needsRepair(rawValue: "") }
        return classifyRate(raw)
    }

    /// The stored TEXT → one of the two "row exists" states.
    ///
    /// "Stored TEXT" means the `settings.value` string as it stands BEFORE JSON
    /// parsing and BEFORE numeric coercion. Valid UTF-8 is preserved verbatim;
    /// invalid UTF-8 has already been substituted with U+FFFD by ``SQLiteDatabase``'s
    /// TEXT decoding, which is the existing boundary and is not changed here.
    ///
    /// Mirrors `electron/handlers/_rateValue.js`'s `classifyStoredRate` — the write
    /// gate that shipped in A4-1 — so a value this app prices with is a value that app
    /// would have let a user store. Two implementations of one rule, because the
    /// renderer cannot import main-process CommonJS; the corpus in
    /// `ReportRateSettingTests` is what keeps them from drifting.
    ///
    /// **One residual divergence is known and is NOT closed here**, because closing it
    /// means writing a JSON number parser. `JSONSerialization` and V8 disagree on bare
    /// numeric literals that carry more than 17 significant digits AND an exponent
    /// outside roughly ±[111, 144]: Foundation throws where `JSON.parse` yields a
    /// finite double. Measured — `1.12345678912345678e144` parses on both sides,
    /// `…e145` parses in JS and throws here. Direction: this side is the STRICTER one,
    /// so such a row reads as needs-repair rather than as a rate, which is the safe
    /// way round. No such value is reachable through any UI, and both `_rateValue.js`
    /// and this agree on every shape a human could plausibly store. Registered rather
    /// than papered over.
    ///
    /// Usable, and ONLY these:
    ///   * a finite JSON number — `25`, `25.5`, `0`, `-5`, `1e3`;
    ///   * a JSON string that trims to a non-empty JS numeric literal — `"25"`,
    ///     `" 25 "`, `"13"`. Not leniency: `SettingsPage`'s `<select>` has stored
    ///     `vat_rate` in this shape since it shipped.
    ///
    /// Everything else is ``ReportRateSetting/needsRepair``, and the three families
    /// are worth naming because they behave differently in today's JavaScript:
    ///   * **not JSON at all** (`abc`, a bare `25%`, empty text) — `readSetting`'s
    ///     catch returns the fallback, so `electron/reports` prices a US ledger at
    ///     China's 25% (measured: `annualIncomeTax` 1100). The scheme-A hole.
    ///   * **JSON, coerces to a number** (`null`, `""`, `true`, `false`, `[]`, `[25]`)
    ///     — silently 0, 1 or 25. The most dangerous family, because the result looks
    ///     like a deliberate setting.
    ///   * **JSON, coerces to NaN** (`"25%"`, `{}`, `[1,2]`) — China serialises null,
    ///     the other four engines' `|| 0` guards flatten it to 0.
    static func classifyRate(_ raw: String) -> ReportRateSetting {
        guard let parsed = jsonFragment(raw) else {
            return .needsRepair(rawValue: raw)          // JSON.parse threw
        }
        switch parsed {
        case .number(let d):
            guard let finite = FiniteRate(d) else { return .needsRepair(rawValue: raw) }
            return .configured(finite)
        case .string(let s):
            // Emptiness has to be asked BEFORE coercion: Number("") is 0, so an empty
            // string would otherwise read as a deliberate 0%.
            guard !ReportMath.jsTrim(s).isEmpty,
                  let finite = FiniteRate(ReportMath.stringToNumber(s))
            else { return .needsRepair(rawValue: raw) }
            return .configured(finite)
        case .null, .boolean, .array, .object, .undefined:
            return .needsRepair(rawValue: raw)
        }
    }

    /// `readSetting(db, key, fallback)` for a STRING-valued setting
    /// (`accounting_locale`, `currency`).
    static func string(_ db: SQLiteDatabase, _ key: String, fallback: String) -> String {
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
    static func number(_ db: SQLiteDatabase, _ key: String, fallback: Double) -> Double {
        guard let raw = rawValue(db, key) else { return fallback }
        guard let parsed = jsonFragment(raw) else { return fallback }   // JSON.parse threw
        return ReportMath.number(parsed)
    }

    /// **The one reading of what `accounting_locale` holds.** nil = this app does not
    /// recognise it.
    ///
    /// Extracted because there used to be two readings of the same bytes.
    /// `SettingsStore.accountingLocale()` decoded with `JSONSerialization`, which
    /// implements RFC 4627 encoding sniffing and therefore EATS a leading U+FEFF; the
    /// engines go through ``jsonFragment``, which rejects it (`JSON.parse` does too).
    /// One BOM-prefixed `"US"` row was read as the United States by the Settings screen
    /// and refused by the report engines — the same ledger, two countries, in one app.
    ///
    /// Everything that decides what regime a ledger claims now asks THIS function, so a
    /// future change to the rule cannot land on one reader and miss the other.
    /// `SettingsStore.accountingLocaleState()` is the App-facing door onto it.
    static func recognizedAccountingLocale(fromStoredText raw: String) -> AccountingLocale? {
        guard case .string(let value)? = jsonFragment(raw) else { return nil }
        return AccountingLocale(rawValue: value)
    }

    /// `JSON.parse` of a settings value, as a `ReportMath.JSValue`; nil when the
    /// parse throws.
    static func jsonFragment(_ text: String) -> ReportMath.JSValue? {
        // A leading U+FEFF is rejected BEFORE Foundation sees it.
        //
        // `JSONSerialization` implements RFC 4627's encoding sniffing, which treats a
        // byte-order mark as an encoding announcement and silently eats it;
        // `JSON.parse` does not — U+FEFF is not JSON whitespace, so it throws.
        // Measured on the same bytes:
        //
        //     EF BB BF 32 35        ("\u{FEFF}25")   Foundation → 25     JSON.parse → throws
        //     EF BB BF 22 55 53 22  ("\u{FEFF}\"US\"") Foundation → "US" JSON.parse → throws
        //
        // Left alone, the divergence is not academic: `accounting_locale` goes through
        // this function, so one BOM-prefixed row routes the SAME ledger to the Chinese
        // engine in Electron and the US engine here — a different regime for the whole
        // report. `admin_expense_annual` reads 5000 here and 0 there.
        //
        // Only a BOM at offset 0 is affected. A space before it, a second one, a
        // trailing one, or one INSIDE a JSON string all already agree (the last is
        // usable on both sides — `ReportMath.jsWhitespace` contains U+FEFF, so
        // `Number("\u{FEFF}25")` is 25 in both languages).
        if text.unicodeScalars.first == "\u{FEFF}" { return nil }
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
