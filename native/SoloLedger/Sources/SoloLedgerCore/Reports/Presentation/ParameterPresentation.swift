import Foundation

/// The four `settings` keys the report dispatcher loads.
public enum ReportParameterKey: String, Equatable, Sendable, CaseIterable {
    case vatRate = "vat_rate"
    case surchargeRate = "surcharge_rate"
    case incomeTaxRate = "income_tax_rate"
    case adminExpenseAnnual = "admin_expense_annual"
}

/// One parameter as it stood when the report was computed, on TWO INDEPENDENT AXES.
///
/// Splitting them is not tidiness — a measured corpus proves they disagree, and collapsing
/// them loses evidence a repair flow needs:
///
/// | stored text | is it a sound setting | what the engines subtracted |
/// | --- | --- | --- |
/// | `true` | **no** | **1** |
/// | `[5000]` | **no** | **5000** |
/// | `""`, `null`, `false`, `[]` | **no** | 0 |
/// | `5000元` (bare) | **no** | 0, via the dispatcher fallback |
/// | `{}`, `"5000元"` | **no** | NaN |
///
/// `true` and `[5000]` are the point: judging soundness by "did a finite number come out"
/// would call both of them settings the user chose.
public struct PresentedParameter: Equatable, Sendable {
    public let key: ReportParameterKey
    /// AXIS 1 — is the stored text a sound setting, and if not, what does it literally say.
    public let stored: StoredSettingState
    /// AXIS 2 — what THIS app's engines actually used for this report.
    public let nativeEffect: ParameterEffect
    /// Whether any engine for this accounting locale reads the parameter at all.
    public let consumption: ParameterConsumption

    public init(key: ReportParameterKey, stored: StoredSettingState,
                nativeEffect: ParameterEffect, consumption: ParameterConsumption) {
        self.key = key
        self.stored = stored
        self.nativeEffect = nativeEffect
        self.consumption = consumption
    }
}

/// AXIS 1 — the stored value, judged by the rule BOTH apps implement:
/// `electron/handlers/_rateValue.js`'s `classifyStoredRate` and `ReportSettings.classifyRate`.
/// Usable iff a finite JSON number, or a JSON string that trims to a non-empty numeric
/// literal. Applied to all four keys, so "is this row sound" is one question everywhere.
public enum StoredSettingState: Equatable, Sendable {
    case absent
    case usable(Double)
    /// Present and not usable. `storedText` is the `settings.value` TEXT verbatim —
    /// pre-`JSON.parse`, pre-`Number()`, lossy only for invalid UTF-8 at the SQLite
    /// decoding boundary. It survives even when ``ParameterEffect`` below is a perfectly
    /// ordinary finite number, which is the whole reason the two axes are separate.
    case needsRepair(storedText: String)
}

/// AXIS 2 — what reached the engines, in THIS app.
///
/// Named `nativeEffect` on ``PresentedParameter`` rather than `effect` so it cannot be read
/// as a claim about the JavaScript engines. Where the two runtimes' coercions are known to
/// disagree, that is recorded in an internal register and a committed corpus — deliberately
/// not in this public type, because the set of divergences is neither closed nor fully
/// characterised, and a public enum over it would be a contract this app cannot keep.
public enum ParameterEffect: Equatable, Sendable {
    /// A finite number reached the engines.
    case appliedValue(Double, origin: EffectOrigin)
    /// A non-finite value reached the engines. What each engine then DID with it is
    /// regime-dependent and is NOT normalised: China's `ReportMath.round2` has no `|| 0`
    /// guard and keeps the NaN, while the other five use `round2OrZero` and flatten it to a
    /// confident 0. Both are mirrored behaviour. Only `adminExpenseAnnual` can reach this —
    /// `FiniteRate` makes it structurally impossible for a rate.
    case appliedNonFinite
    /// The estimate layer computed nothing. Rates only; `adminExpenseAnnual` never refuses,
    /// because `index.js:100` falls back to 0 regardless of regime.
    case refused(ReportRateParameter)
}

public enum EffectOrigin: Equatable, Sendable {
    /// The stored value coerced to this.
    case storedValue
    /// China's 25 / 12 for a MISSING rate row (scheme A-2). **Must be disclosed** — the
    /// user did not choose it, and `EstimatedValue` cannot say so because
    /// `EstimatedValue.refusal` maps `.configured` and `.chinaFallback` through one arm.
    case regimeDefault
    /// `index.js:100`'s 0 for the admin expense — row absent, or `JSON.parse` threw and
    /// `readSetting`'s catch returned the fallback. A real zero, not a refusal.
    case dispatcherFallback
}

public enum ParameterConsumption: Equatable, Sendable {
    case consumed
    /// `vat_rate` in every regime — the dispatcher loads it (`index.js:86`) and no engine
    /// reads it (Appendix A6) — and `surcharge_rate` outside China, where only `cn.js:33`
    /// consumes it. A view must be able to say "unset, and nothing here reads it" rather
    /// than prompting for a value that would change no number.
    case storedButUnread
}
