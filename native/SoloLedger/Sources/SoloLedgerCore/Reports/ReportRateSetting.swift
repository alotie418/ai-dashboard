import Foundation

/// A rate a report may price with — and, when it may not, WHICH kind of "may not".
///
/// One type for BOTH rate parameters (`income_tax_rate` and `surcharge_rate`),
/// replacing R6's income-tax-only `IncomeTaxRateSetting`. The generalisation is not
/// tidying: R6's own note said the surcharge "has no missing state to model", and
/// that was wrong — it has no *not-configured* state outside China, but it very much
/// has a **needs-repair** one. The `malformed` golden variant sets `surcharge_rate`
/// to `"12%"`, and China's five null fields in `malformed-CN-2025.json` come from
/// that row, not from the income-tax row.
///
/// ## The four states (plan §6.2 + §6.4)
///
/// | state | when | what the estimate layer may do |
/// | --- | --- | --- |
/// | ``configured`` | the row exists and holds a usable rate | price with it |
/// | ``chinaFallback`` | the row is absent and the regime is China | price with the fallback |
/// | ``notConfigured`` | the row is absent, non-Chinese regime | **nothing** — "去配置" |
/// | ``needsRepair`` | the row exists and its value is unusable | **nothing** — "修复损坏值" |
///
/// The last two are deliberately NOT one case. They compute the same amount of
/// nothing, but they ask the user for different things, and R8 has to be able to
/// tell them apart to put the right door in front of them. Collapsing them would
/// repeat, one level up, the mistake scheme A fixed: a state the app cannot
/// distinguish is a state the app will describe wrongly.
///
/// ## `.configured` cannot hold a NaN — structurally, not by convention
///
/// R6 represented "malformed" as `.configured(.nan)`, which was ruled out: it makes
/// the corrupt state a *kind of configured*, so every `guard let rate = setting.rate`
/// in R7 would sail straight past it and multiply by NaN. The payload is therefore
/// ``FiniteRate``, whose only non-literal initialiser is failable — so
/// `.configured(.nan)` does not compile, and a runtime value has to pass through a
/// check to get in. Integer and float LITERALS still work (`.configured(21)`), which
/// keeps call sites readable; there is no way to write a non-finite literal in Swift.
///
/// ## The decision is made on the STORED TEXT
///
/// Not on the coerced number, and this is the same hard constraint as A-3, one layer
/// down. Measured: `Number(null)`, `Number("")`, `Number([])` and `Number(false)` are
/// all **0**, `Number(true)` is **1**, and `Number([25])` is **25** — every one a
/// perfectly ordinary rate. A gate that looked at the coerced value would classify a
/// corrupt row as a deliberate 0% (or 1%, or 25%). Only the stored TEXT tells them
/// apart, which is why ``needsRepair`` carries it.
enum ReportRateSetting: Equatable, Sendable {

    /// The row exists and holds a usable rate.
    ///
    /// "Usable" is exactly what `electron/handlers/_rateValue.js` accepts on the way
    /// IN, so a value this app will price with is a value that app would have let a
    /// user store: a finite JSON number, or a JSON string that trims to a non-empty
    /// numeric literal. The string form is not leniency — `SettingsPage`'s `<select>`
    /// stores `vat_rate` as `"13"` and has since it shipped.
    case configured(FiniteRate)

    /// The row is absent and the regime is China, which keeps its fallback (A-2).
    ///
    /// Carried rather than implied so a reader of a value does not need to know the
    /// constant to know what was applied: 25 for income tax, 12 for the surcharge.
    case chinaFallback(FiniteRate)

    /// The row is absent and the regime is not China. **Nothing is computed.**
    ///
    /// The rejected alternative was a per-regime preset, which is two lines of code
    /// and amounts to choosing a tax rate on the user's behalf.
    case notConfigured

    /// The row EXISTS but its value is not a usable rate. **Nothing is computed.**
    ///
    /// The payload is the `settings.value` **TEXT as it stands before JSON parsing and
    /// before numeric coercion** — not the `JSON.parse` result and not the `Number()`
    /// result. Both of those destroy the evidence: parsing turns `abc` into a throw
    /// and `"25%"` into a string that no longer looks stored, and coercing turns half
    /// of them into ordinary numbers. R8's repair flow has to show the user what is in
    /// their ledger, so this is as close to it as the read path gets.
    ///
    /// **What "as it stands" does and does not promise.** Valid UTF-8 survives
    /// unchanged. Invalid UTF-8 does not: `SQLiteDatabase` decodes TEXT with
    /// `String(decoding:as: UTF8.self)`, which substitutes U+FFFD (its own comment
    /// says so, and it is the deliberate choice there — `String(cString:)` would stop
    /// at an embedded NUL and silently truncate). So a row holding bytes that are not
    /// valid UTF-8 arrives here already lossy, and this type does not claim otherwise.
    /// Widening the read path to `Data` was considered and declined: it would change a
    /// primitive every settings reader shares, for a case no write path can produce.
    /// The boundary is pinned by
    /// `ReportRateSettingTests.testInvalidUTF8ArrivesLossyAtTheDecodingBoundary`.
    case needsRepair(rawValue: String)

    /// The rate to price with, or `nil` when there is none.
    ///
    /// `nil` for BOTH ``notConfigured`` and ``needsRepair``: arithmetically they are
    /// the same refusal. The difference is what to tell the user, and that is asked
    /// for with ``needsRepairRawValue`` or by switching over the enum — never by
    /// finding a NaN in here, because a NaN can no longer get in here.
    var rate: Double? {
        switch self {
        case .configured(let r), .chinaFallback(let r): return r.value
        case .notConfigured, .needsRepair: return nil
        }
    }

    /// Whether the estimate layer may produce numbers at all.
    var isConfigured: Bool { rate != nil }

    /// The stored TEXT when this is ``needsRepair``, else `nil`.
    ///
    /// Same promise as ``needsRepair(rawValue:)``: pre-parse, pre-coercion, and
    /// lossy for invalid UTF-8 at the SQLite decoding boundary.
    ///
    /// Spelled as an accessor so a presentation layer can ask "is there something to
    /// repair, and what does it say" without switching, and so that the answer is
    /// impossible to confuse with ``rate``.
    var needsRepairRawValue: String? {
        if case .needsRepair(let raw) = self { return raw }
        return nil
    }
}

/// A rate that is known to be finite.
///
/// Exists for one reason: to make ``ReportRateSetting/configured(_:)`` unable to hold
/// a NaN. Swift cannot hide an enum case, so the guarantee has to live in the payload
/// type — and once it does, `.configured(.nan)` is a compile error rather than a code
/// review note.
///
/// Literals are still ergonomic (`.configured(21)`, `.configured(23.2)`) because a
/// non-finite literal cannot be written in Swift: `.nan` and `.infinity` are static
/// members of `Double`, not literals, and `FiniteRate` has no such members.
struct FiniteRate: Equatable, Sendable {
    let value: Double

    /// Fails for NaN and the infinities. This is the only way a runtime value gets in.
    init?(_ value: Double) {
        guard value.isFinite else { return nil }
        self.value = value
    }
}

extension FiniteRate: ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral {
    // Unreachable in practice — Swift has no non-finite numeric literal — but stated
    // rather than assumed, because "cannot happen" and "is not checked" read the same
    // in a diff.
    init(integerLiteral value: Int) {
        self.value = Double(value)
    }
    init(floatLiteral value: Double) {
        precondition(value.isFinite, "FiniteRate literal must be finite")
        self.value = value
    }
}

extension FiniteRate: CustomStringConvertible {
    var description: String { String(value) }
}
