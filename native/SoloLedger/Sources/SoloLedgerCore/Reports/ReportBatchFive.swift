import Foundation

/// Batch-5 output shapes: the estimate layer.
///
/// This is the only batch whose fields move when a `settings` value changes, which is
/// why the plan schedules it last and why the whole four-state rate contract (R6,
/// A4-2) had to exist first. Every field here is either a number the engine computed
/// or an explicit statement that it refused to.

/// Which rate parameter a refusal is about.
///
/// Carried so R8 can point its repair or configure link at the right settings field
/// without re-deriving which row was to blame. China needs it: `incomeTax` there can
/// be blocked by EITHER the surcharge row or the income-tax row, and the two want
/// different doors.
///
/// Deliberately NO raw value. A settings-key string would invite a caller to take it
/// back to SQLite and re-derive the reason, and re-deriving is precisely what this
/// type exists to prevent — see the snapshot note on ``EstimatedValue``.
public enum ReportRateParameter: Equatable, Sendable {
    case incomeTaxRate
    case surchargeRate
}

/// A number the estimate layer produced, or the reason it produced none.
///
/// ## Why not `Double?`
///
/// The same reason ``CashflowSection`` is an enum rather than an optional, and it is
/// worth restating because this type has three cases instead of two: with `Double?`,
/// `?? 0` is a two-character edit that compiles, and no golden can catch it — a
/// golden observes the model, never a view rendering 0 from a model that said nil.
/// Here there is no `Double` to reach for.
///
/// Deliberately **no** `var value: Double?` accessor. ``ReportRateSetting/rate`` has
/// one and that is correct for an INPUT — an engine legitimately asks "may I price
/// with this". Copying it to the OUTPUT would reopen the hole: the caller that
/// matters is a view, and a view asking `value ?? 0` is exactly the defect.
///
/// ## Why two refusal cases and not one
///
/// They compute the same amount of nothing. They ask the user for different things —
/// "去配置" versus "修复损坏值" — and R8 has to be able to tell them apart. The JSON
/// the Electron engine emits cannot: both are `null` there, which is why this
/// distinction lives in the Swift model and is asserted by unit tests rather than by
/// golden parity. **No golden cell can distinguish them**, and that is stated here so
/// a green parity run is not misread as evidence that it does.
///
/// ## A self-contained snapshot, on purpose
///
/// The reason travels WITH the value, so a presentation layer never re-reads
/// `settings` to work out why a number is missing. That is not convenience, it is
/// correctness: between computing a report and rendering it the user can open the
/// settings page and change the very row that caused the refusal, and a view that
/// re-classified at render time would then explain the number with a state that no
/// longer produced it. The report is a statement about the ledger AT THE MOMENT IT
/// WAS COMPUTED, and everything needed to explain it is carried here.
enum EstimatedValue: Equatable, Sendable {
    /// The rate was usable and this is what the mirrored formula produced.
    case computed(Double)
    /// The settings row is absent and the regime is not China.
    case notConfigured(parameter: ReportRateParameter)
    /// The settings row exists and its stored text is not a usable rate.
    ///
    /// `rawValue` is what ``ReportRateSetting/needsRepair(rawValue:)`` carried: the
    /// `settings.value` TEXT before JSON parsing and before numeric coercion, lossy
    /// only for invalid UTF-8 at the SQLite decoding boundary.
    case needsRepair(parameter: ReportRateParameter, rawValue: String)

    /// The refusal a rate setting implies, or `nil` when it is usable.
    ///
    /// **The single mapping point**, and the reason it exists: the natural spelling
    /// at a call site is `guard let rate = ctx.incomeTaxRate.rate else { return .notConfigured }`,
    /// which is wrong in a way nothing would catch — it renders "the value is
    /// corrupt" as "go configure a rate". Routing every refusal through here makes
    /// that mistake un-writable.
    /// When more than one rate could block a value, the caller must ask in the
    /// engine's own order. China's `incomeTax` is gated by
    /// `cannotPrice = surchargeMissing || rateMissing` (`cn.js:53`), and `||`
    /// short-circuits — so with BOTH rows unusable the blocker is the SURCHARGE, and
    /// the refusal must name it. That order is a fact about the JS, not a preference,
    /// and `ReportBatch5BlindSpotTests` pins it; deriving it afterwards from which
    /// number came out is the value-based reasoning A-3 rules out.
    static func refusal(for setting: ReportRateSetting,
                               parameter: ReportRateParameter) -> EstimatedValue? {
        switch setting {
        case .configured, .chinaFallback:
            return nil
        case .notConfigured:
            return .notConfigured(parameter: parameter)
        case .needsRepair(let raw):
            return .needsRepair(parameter: parameter, rawValue: raw)
        }
    }
}

/// `us.js:91-99` — the Self-Employment Tax estimate.
///
/// Seven fields, mirrored verbatim. Two of them are duplicates that NO input can
/// separate, and saying so is cheaper than letting a green run imply otherwise:
///
/// * `netEarnings` is `scheduleC.line31_netProfit` — the same variable (`us.js:66`),
///   so these ten golden cells re-assert a number batch 3 already pinned;
/// * `totalSETax` is `estimatedTax.annualSETax` — again the same variable
///   (`us.js:74`), so wiring either to the other is undetectable by any golden.
///
/// A third measured gap: `additionalMedicare` is **0 in all ten US goldens**, and the
/// social-security wage cap never binds (the largest `seEarnings` in the fixture is
/// 39,479.63 against a cap of 168,600). Both branches are covered by
/// `ReportBatch5BlindSpotTests` instead, because the goldens cannot.
struct SelfEmploymentTax: Equatable, Sendable {
    let netEarnings: Double
    let seEarnings: Double
    let socialSecurityTax: Double
    let medicareTax: Double
    let additionalMedicare: Double
    let totalSETax: Double
    /// The YEAR whose constants were applied, after `resolveSeTaxParams`'s
    /// unknown-year fallback. The only golden-visible evidence that the constant
    /// table is year-keyed at all — every other SE figure is identical across the
    /// three keyed years.
    let paramYear: Int
}

/// `us.js:101-107` — the quarterly estimated-tax block.
///
/// `totalAnnual` is `annualIncomeTax + totalSETax` and is **NOT rounded** (`us.js:82`).
/// Two committed goldens carry the float tail that proves it — `base-US-2024` records
/// `1542.6599999999999` and `base-US-2026` records `14590.380000000001` — so an
/// implementation that adds a tidy `round2` here fails on exactly those two cells.
/// They are the sharpest discriminator in the batch, which is also why the parity
/// suite compares exactly rather than with the plan's `eps = 0.011`: that tolerance
/// would swallow the difference.
struct EstimatedTax: Equatable, Sendable {
    let annualIncomeTax: EstimatedValue
    /// Never refused: the SE tax reads no income-tax rate.
    let annualSETax: Double
    let totalAnnual: EstimatedValue
    let quarterlyPayment: EstimatedValue
    /// Calendar dates, so likewise never refused (`us.js:106`).
    let dueDates: [String]
}
