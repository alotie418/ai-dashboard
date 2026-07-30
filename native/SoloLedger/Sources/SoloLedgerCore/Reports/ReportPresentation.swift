import Foundation

/// The pure decision layer between the mirrored report model and any view.
///
/// Nothing here reads SQLite, formats a number, or knows a language. It answers one
/// question — *what KIND of thing does this field / this report type resolve to* —
/// and it answers it exhaustively, so the wording and the layout that R8's views add
/// on top cannot invent a fourth kind by accident.
///
/// ## Why the layer exists at all
///
/// The model already distinguishes the states. What it does not do is make a view
/// USE the distinction:
///
/// * `EstimatedValue` (``ReportBatchFive``) has three cases, and a `switch` in a
///   `@ViewBuilder` compiles perfectly well with a `default:` that swallows two of
///   them;
/// * plain `Double` fields carry no state at all, yet **China's rounder has no
///   `|| 0` guard** (`ReportMath.round2`), so `adminExpense` on a Chinese ledger is a
///   plain `Double` that can be `NaN` — measured, and the reason
///   `malformed-CN-2025.json` records five nulls where `malformed-US-2025.json`
///   records zeros;
/// * `ReportTypes.table(for:)` and `ReportTypeEntry.name` are public, so a view can
///   enumerate report types **without ever asking** `ReportTypes/availability(for:locale:)`
///   — which is exactly what plan §7.3 says must not happen.
///
/// So the three funnels below are the point: ``field(_:)-(EstimatedValue)`` for an
/// estimate, ``field(_:)-(Double)`` for a plain line, and ``reportTypes(locale:)`` for
/// the picker. A row that goes through them cannot print `NaN`, cannot print `0` for
/// a refusal, and cannot reach a report type without its availability attached.
///
/// ## What it deliberately does NOT do
///
/// * **No localized text.** Every case is a semantic token; the six-language wording
///   is R8's next step and is a human decision (CLAUDE.md).
/// * **No new field on any mirrored payload.** ``provenance(_:)`` is a function OVER
///   `ReportRateSetting`, not a field added to an engine's output, so the Electron
///   contract and every golden are untouched.
/// * **No database.** A presentation layer that could re-read `settings` would be able
///   to explain a number with a state that no longer produced it — the snapshot rule
///   `EstimatedValue` is documented with.
enum ReportPresentation {

    // MARK: - A single field

    /// Resolve one estimate field.
    ///
    /// The `.computed` case is split on FINITENESS, and that split is the whole reason
    /// this function is not a one-line rename. `EstimatedValue.computed` promises a
    /// `Double`, not a finite one: `FiniteRate` guarantees the RATE is finite, and
    /// nothing guarantees the RESULT is. Reachable today — a `settings` row holding
    /// the JSON string `"5000元"` under `admin_expense_annual` coerces to `NaN`
    /// (`ReportSettings.number` → `ReportMath.number`), flows through China's unguarded
    /// `round2`, and arrives here as `.computed(nan)`.
    ///
    /// A view handed that would render whatever `NumberFormatter` does with a NaN.
    /// ``ReportFieldPresentation/corrupted`` exists so it renders "the data is damaged"
    /// instead, and so the compiler asks.
    static func field(_ value: EstimatedValue) -> ReportFieldPresentation {
        switch value {
        case .computed(let x):
            return field(x)
        case .notConfigured(let parameter):
            return .notConfigured(parameter: parameter)
        case .needsRepair(let parameter, let rawValue):
            return .needsRepair(parameter: parameter, storedText: rawValue)
        }
    }

    /// Resolve one PLAIN `Double` line — revenue, gross profit, a Schedule C line, a
    /// VAT total.
    ///
    /// These have no refusal state and never will: the engines compute them without
    /// reading a rate. They are funnelled here anyway for the finiteness gate, because
    /// "this field cannot refuse" and "this field cannot be `NaN`" are different
    /// claims and only the first one is true.
    ///
    /// Note the asymmetry this makes visible: JP/EU/KR/TW round with
    /// `ReportMath.round2OrZero`, which flattens `NaN` to `0`, so the same corrupt
    /// `admin_expense_annual` renders as a **confident 0** there and as damaged data on
    /// China. Both are the mirror's behaviour and neither is repaired here; this
    /// function only stops the Chinese one from reaching a formatter.
    static func field(_ value: Double) -> ReportFieldPresentation {
        guard value.isFinite else { return .corrupted }
        // Negative zero is normalised to positive zero HERE and nowhere else. The
        // engines' rounders can produce it (`round2(-0.001)` is `-0.0`, because
        // `(-0.1).rounded()` is `-0.0`), `-0.0 == 0.0` is already true so the two are
        // indistinguishable to `Equatable`, and a currency formatter will nevertheless
        // print "-0.00". A minus sign in front of a zero reads as a loss that is not
        // there. No computed value changes: this is the display funnel, and the value
        // it is handed is equal to the value it returns.
        return .amount(value == 0 ? 0 : value)
    }

    // MARK: - Where a rate came from

    /// What produced the rate a report priced with — or why it priced with nothing.
    ///
    /// A function over the INPUT type, called by whatever assembles a report result for
    /// a view. It is here rather than on `ReportRateSetting` itself so the mirrored
    /// input model stays a mirror.
    ///
    /// The case that justifies the whole function is
    /// ``ReportRateProvenance/regimeDefault(percent:)``. `EstimatedValue.refusal` maps
    /// `.configured` and `.chinaFallback` through the SAME arm to `nil`, so by the time
    /// a number reaches the output it is `.computed` either way and **the fact that the
    /// app chose 25% on the user's behalf has been erased**. Measured on the committed
    /// goldens: `unset-CN-2025` — every rate row deleted — still reports
    /// `incomeTax: 1042.95`, while `unset-US-2025` reports `null`. A Chinese user who
    /// has never opened Settings is shown a tax figure derived from a rate nobody
    /// chose, and CLAUDE.md forbids exactly that ("do not silently choose a policy
    /// without documentation"). This is the only channel through which a view can find
    /// out, and it carries the percent so the disclosure can name it.
    static func provenance(_ setting: ReportRateSetting) -> ReportRateProvenance {
        switch setting {
        case .configured:
            return .userConfigured
        case .chinaFallback(let rate):
            return .regimeDefault(percent: rate.value)
        case .notConfigured:
            return .notConfigured
        case .needsRepair(let raw):
            return .needsRepair(storedText: raw)
        }
    }

    // MARK: - Report types, never without their availability

    /// Every report type an accounting locale declares, each already paired with what
    /// may be shown of it — or `nil` for a locale no engine serves.
    ///
    /// **This is the §7.3 combination, and its shape is the enforcement.** The plan's
    /// complaint is not that `availability(for:locale:)` is wrong, it is that
    /// `ReportTypes.table(for:)` and `ReportTypeEntry.name` are public, so a caller can
    /// walk the table and render `name` without ever asking. Those two stay public —
    /// they are the mirrored contract and this phase does not narrow it — so the fix
    /// here is to offer a door that CANNOT be walked through incorrectly:
    /// ``ReportTypePresentation`` carries the stable `id` and the decision, and it
    /// carries no `name`. A view that uses this function has nothing to render the
    /// historical copy FROM.
    ///
    /// `nil` rather than `[]`, matching `ReportTypes.table(for:)`: `index.js:29-31`
    /// throws on an unknown locale, so "no report types" is not a state the source can
    /// reach, and an empty array would let a caller render an empty picker for a ledger
    /// that should have been rejected outright.
    static func reportTypes(locale: String) -> [ReportTypePresentation]? {
        guard let table = ReportTypes.table(for: locale) else { return nil }
        return table.map {
            ReportTypePresentation(id: $0.id,
                                   section: section(ReportTypes.availability(for: $0.id,
                                                                            locale: locale)))
        }
    }

    /// Availability → what a view may draw.
    ///
    /// **Internal on purpose, and this is a deliberate constraint rather than an
    /// oversight.** Making it public would hand production code a way to obtain a
    /// section decision for an availability it made up, which is precisely the bypass
    /// ``reportTypes(locale:)`` exists to remove. The tests reach it through
    /// `@testable import`, which is also the only way `.truncated` can be exercised at
    /// all right now: R7 moved all 13 declared pairs to `.mirrored`, so
    /// `ReportTypes.availability` has **no `.truncated` producer**, and a test driving
    /// the production path could never reach that branch.
    ///
    /// Stated plainly because a green test must not be read as more than it is: the
    /// `.truncated` case below is verified as a MAPPING, not as a path a real ledger
    /// takes today. When a future batch reintroduces a partially-mirrored report type,
    /// the mapping is already pinned and the view already has the branch.
    static func section(_ availability: ReportTypeAvailability) -> ReportSectionPresentation {
        switch availability {
        case .mirrored:  return .renderInFull
        case .truncated: return .renderWithMissingLines
        case .absent:    return .withhold
        }
    }
}

/// What one report field resolves to. Four kinds, and no fifth.
///
/// Deliberately **no `var value: Double?`**, for the reason `EstimatedValue` gives for
/// not having one: the caller that matters is a view, and a view writing `value ?? 0`
/// is the entire defect. ``amount(_:)`` is the only case carrying a `Double` and its
/// payload is always finite — pinned by a test over a corpus that includes `NaN`, both
/// infinities and `-0.0`.
public enum ReportFieldPresentation: Equatable, Sendable {
    /// A finite number, ready to be formatted. Includes a legitimate `0`.
    ///
    /// A `0` here can mean several true things — a clamped loss period
    /// (`ReportMath.max(0, ·)`), a zero-revenue margin, a structurally-zero COGS on a
    /// legacy-categorised ledger, a deliberately configured 0% rate — and this type
    /// does NOT distinguish them. That is a decision, not an omission: telling them
    /// apart would require the engines to report whether a clamp bound, which is a
    /// change to the mirrored formula surface. A zero is shown as a zero.
    case amount(Double)
    /// The engine produced a non-finite value. **Never render the number.**
    ///
    /// Carries no parameter: the reachable source is a corrupt `admin_expense_annual`,
    /// which is not a rate parameter, so naming one would be a guess.
    case corrupted
    /// No rate row, and the regime has no fallback. Nothing was computed.
    case notConfigured(parameter: ReportRateParameter)
    /// The rate row exists and its stored text is not a usable rate. Nothing was
    /// computed, and `storedText` is that text as it stands — pre-`JSON.parse`,
    /// pre-`Number()`, lossy only for invalid UTF-8 at the SQLite decoding boundary.
    ///
    /// It is passed through verbatim, INCLUDING its JSON quoting: the `malformed`
    /// golden variant stores the five bytes `"25%"` and the `malformed-raw` variant
    /// stores the three bytes `25%`. Those look different to a user and they are
    /// different rows; stripping the quotes here would destroy the only evidence a
    /// repair flow has to show.
    case needsRepair(parameter: ReportRateParameter, storedText: String)
}

/// Where the rate behind a computed figure came from.
public enum ReportRateProvenance: Equatable, Sendable {
    /// The ledger holds a usable rate the user stored.
    case userConfigured
    /// No row; the regime supplied this percent on the user's behalf. **Must be
    /// disclosed** — see ``ReportPresentation/provenance(_:)``.
    case regimeDefault(percent: Double)
    /// No row and no fallback.
    case notConfigured
    /// A row that is not a usable rate. Same verbatim promise as
    /// ``ReportFieldPresentation/needsRepair(parameter:storedText:)``.
    case needsRepair(storedText: String)
}

/// What may be drawn for a report type.
public enum ReportSectionPresentation: Equatable, Sendable {
    /// Every field the engine emits is mirrored; draw the statement.
    case renderInFull
    /// Some fields are mirrored and some are not. Drawing this as a finished statement
    /// is the plan §7.3 violation — the missing lines must be marked as not provided.
    case renderWithMissingLines
    /// Nothing of this report type is mirrored. Do not draw it.
    case withhold
}

/// A report type as a view is allowed to see it: a stable id and a decision.
///
/// **Carries no `name`, and a test asserts it never gains one.** The engines' `name`
/// maps are historical copy — two or three of six UI languages, Japanese in `jp.js`'s
/// `zh-CN` slot, a filing word in `eu.js` — mirrored verbatim as a fact about the
/// engines and never display copy. R8 maps `id` to its own reviewed six-language
/// strings.
public struct ReportTypePresentation: Equatable, Sendable {
    /// The engine's stable identifier — `income-statement`, `schedule-c`, `se-tax`, …
    public let id: String
    public let section: ReportSectionPresentation

    public init(id: String, section: ReportSectionPresentation) {
        self.id = id
        self.section = section
    }
}
