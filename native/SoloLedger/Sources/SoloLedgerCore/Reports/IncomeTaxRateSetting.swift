import Foundation

/// The income-tax rate a report may price with — and, when it may not, WHY.
///
/// Mirror of `electron/reports/index.js:88-99` as it stands after the scheme-A
/// correction (plan §9.1, PR #419):
///
/// ```js
/// const incomeTaxRate = (locale === 'CN' || settingRowExists(db, 'income_tax_rate'))
///   ? Number(readSetting(db, 'income_tax_rate', 25))
///   : null;
/// ```
///
/// ## Why this is an enum and not a `Double?`
///
/// A `Double?` would carry the value and lose the reason. The three cases below are
/// plan §6.2's three states, and they are not interchangeable:
/// `.chinaFallback(25)` and `.configured(25)` compute the same number for the same
/// ledger, yet one of them is a number the app chose and the other is a number the
/// user chose. A view that must say "未配置" needs to know which, and so does anyone
/// reading a bug report.
///
/// ## The hard constraint this type exists to make unbreakable (A-3)
///
/// **"Not configured" is decided by the ABSENCE of the settings row, never by the
/// computed value.** That is a measured conclusion, not a preference: plan §6.2's
/// four-variant matrix shows a missing row producing 1100 on a US ledger — China's
/// 25% fallback quietly applied — which is indistinguishable from a user who really
/// did store 25%. So the constructor is ``ReportSettings/incomeTaxRate(_:locale:)``,
/// which asks SQLite whether the row exists, and there is no way to build a case
/// from a computed figure.
///
/// ## There is deliberately no `rateOrZero`
///
/// The whole defect being corrected is "we do not know" being rendered as a
/// confident number, and in JavaScript the slip is one character wide — `null / 100`
/// is `0`, so a forgotten branch prices a ledger at 0% and looks fine. ``rate``
/// returns `Double?` and nothing else does; a caller that wants a `Double` has to
/// write the `nil` branch, which is the branch that owes the user an explanation.
///
/// ## malformed is NOT a case here
///
/// A row that EXISTS but holds `"25%"` is a fourth state — plan §6.4's explicit
/// "needs repair" — and it is **not** this batch's business (A-4, separate PR). It
/// arrives as `.configured(.nan)`, exactly as the JS arrives at `NaN`, and is
/// mirrored rather than repaired. Reading it as `.notConfigured` would silently
/// merge two states the plan spends four golden variants keeping apart, so
/// ``rate`` hands the NaN back unchanged and lets the estimate layer reproduce the
/// JS behaviour (`|| 0` guards in four engines, a JSON `null` in China's).
public enum IncomeTaxRateSetting: Equatable, Sendable {

    /// The `income_tax_rate` row exists.
    ///
    /// The payload is exactly what `Number(readSetting(db, 'income_tax_rate', 25))`
    /// yields for that row, including the two values that are not a rate a user
    /// meaningfully typed:
    ///
    /// * `.nan` — the row holds a JSON string like `"25%"` (the malformed state
    ///   above; `Number("25%")` is `NaN`).
    /// * `25` — the row holds text that is not valid JSON at all, so
    ///   `readSetting`'s `catch` returns the fallback (`index.js:20`). The row is
    ///   present, so scheme A does not fire; the number is the engine's, not the
    ///   user's. No fixture reaches this and no golden pins it — recorded here
    ///   rather than invented into a case of its own.
    case configured(Double)

    /// The row is absent and the regime is China, which keeps its fallback (A-2).
    ///
    /// The payload is always 25 — `index.js:97`'s fallback literal. It is carried
    /// rather than implied so a reader of a value does not have to know the constant
    /// to know what was applied.
    ///
    /// China is not an oversight in scheme A, it is the rule: `index.js:74-78`'s
    /// fallbacks are the NORMAL path for a Chinese ledger (a fresh install stores
    /// only `accounting_locale`), so refusing to compute there would break the
    /// common case to fix the uncommon one.
    case chinaFallback(Double)

    /// The row is absent and the regime is not China. **Nothing is computed.**
    ///
    /// The estimate layer must emit `null` — not 0, not a guessed rate, not a
    /// regional preset. A preset was the rejected scheme B: two lines of code that
    /// amount to choosing a tax rate on the user's behalf, which is precisely what
    /// CLAUDE.md's "AI must not invent accounting policy" forbids.
    case notConfigured

    /// The rate to price with, or `nil` when the ledger has not configured one.
    ///
    /// `nil` for `.notConfigured` ONLY. A `.configured(.nan)` returns the NaN,
    /// because that is the malformed state and it is mirrored, not repaired.
    public var rate: Double? {
        switch self {
        case .configured(let r), .chinaFallback(let r): return r
        case .notConfigured: return nil
        }
    }

    /// Whether the estimate layer may produce numbers at all.
    ///
    /// Spelled out so a call site reads as the question it is asking. Equivalent to
    /// `rate != nil`; both exist because `if setting.isConfigured` and
    /// `guard let rate = setting.rate` want different shapes at different sites.
    public var isConfigured: Bool { rate != nil }
}
