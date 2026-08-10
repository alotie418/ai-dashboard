import Foundation

/// US tax-law constants, keyed by tax year — MIRRORED verbatim from
/// `electron/reports/usTaxParams.js`.
///
/// ## Do not derive, update, or "correct" a value here
///
/// These are statutory figures. The rule from CLAUDE.md is that AI may implement a
/// confirmed formula and must never invent accounting policy, and a tax constant is
/// the sharpest case of that: every number below has a counterpart in the Electron
/// file, and changing one is a tax decision, not a code change. If a figure looks
/// stale, the fix is to confirm it against the IRS/SSA publication and update BOTH
/// sides in a separately-labelled PR — not to adjust it here.
///
/// ## What is mirrored, and what is deliberately absent
///
/// Schedule C needs exactly one field: `mealsDeductiblePct`, the 50% limit applied to
/// Line 24b (`us.js line24b_meals`). The SE-tax constants that live in the same JS table —
/// `seEarningsFactor`, `ssRate`, `ssWageCap`, `medicareRate`,
/// `addlMedicareThreshold`, `addlMedicareRate` — belong to the estimate layer, and they
/// are mirrored below now that that layer has a caller. The rule they were held back
/// under still stands: a mirrored tax constant with no caller is a number nobody is
/// checking, so none of them is copied ahead of the code that reads it.
///
/// The year-keyed SHAPE is mirrored even though the one value it currently holds is
/// the same for every year. That is not redundancy: the table is year-keyed because
/// these figures change by year, and flattening it to a constant would mean the
/// next year that differs gets noticed by nobody. The structure is the part that
/// carries the intent.
///
/// ## What the tests do and do not establish, precisely
///
/// The VALUE is pinned. Changing 0.5 to 1.0 turns 12 assertions in
/// `ReportBatch3BlindSpotTests` red and moves three cells in `base-US-2026`, so a
/// typo cannot ship. What no test in this repository can establish is anything
/// about the number's **legal correctness** — whether 50% is what the IRS says for
/// these years. That check is a human reading the source publication, and it was
/// made explicitly rather than assumed.
///
/// The year-keyed SHAPE is likewise unverifiable from here: `mealsDeductiblePct`
/// is 0.5 for all three keyed years and unknown years fall back to the latest, so a
/// flat constant would satisfy every test. It is a table because the underlying
/// figures are year-dependent, and the first year that differs is the one where
/// that matters.
enum USTaxParams {

    struct Year: Equatable, Sendable {
        /// The share of meal expense that Line 24b may deduct (`us.js line24b_meals`).
        let mealsDeductiblePct: Double
        /// Schedule SE's net-earnings factor (`us.js seEarnings`).
        let seEarningsFactor: Double
        /// Social-security rate on the capped earnings (`us.js ssTax`).
        let ssRate: Double
        /// The SSA Contribution and Benefit Base — the only figure that differs
        /// between the three keyed years, and the one the fixture never reaches.
        let ssWageCap: Double
        let medicareRate: Double
        let addlMedicareThreshold: Double
        let addlMedicareRate: Double
    }

    /// `US_SE_TAX_PARAMS_BY_YEAR` — `usTaxParams.js US_SE_TAX_PARAMS_BY_YEAR`, now complete.
    ///
    /// Batch 3 copied one field and said why the rest were absent: "a mirrored tax
    /// constant with no caller is a number nobody is checking". R7 is that caller,
    /// so the six SE constants arrive here — transcribed digit for digit, never
    /// derived. Changing one is a tax decision, not a code change.
    ///
    /// **What no test in this repository can establish**, restated because the SE
    /// figures make it sharper than `mealsDeductiblePct` did: `ssWageCap` differs by
    /// year and the fixture's largest `seEarnings` is 39,479.63 against a cap of
    /// 168,600, so the cap NEVER binds in any golden; `addlMedicareThreshold` is
    /// 200,000 and `additionalMedicare` is 0 in all ten US goldens. Hard-coding one
    /// year's constants for all three, or mistyping either threshold, moves no
    /// golden cell. `ReportBatch5BlindSpotTests` covers those branches directly, and
    /// the legal correctness of the numbers is a human reading the SSA/IRS
    /// publication — made explicitly, not assumed.
    static let byYear: [Int: Year] = [
        2024: Year(mealsDeductiblePct: 0.5, seEarningsFactor: 0.9235, ssRate: 0.124,
                   ssWageCap: 168600, medicareRate: 0.029,
                   addlMedicareThreshold: 200000, addlMedicareRate: 0.009),
        2025: Year(mealsDeductiblePct: 0.5, seEarningsFactor: 0.9235, ssRate: 0.124,
                   ssWageCap: 176100, medicareRate: 0.029,
                   addlMedicareThreshold: 200000, addlMedicareRate: 0.009),
        2026: Year(mealsDeductiblePct: 0.5, seEarningsFactor: 0.9235, ssRate: 0.124,
                   ssWageCap: 184500, medicareRate: 0.029,
                   addlMedicareThreshold: 200000, addlMedicareRate: 0.009),
    ]

    /// `usTaxParams.js LATEST_YEAR` — `Math.max(...YEARS)`.
    ///
    /// Derived from the table rather than written as a literal, exactly as the
    /// source derives it. A literal would silently stop tracking the table the
    /// first time a year is added.
    static let latestYear: Int = byYear.keys.max() ?? 0

    /// `resolveSeTaxParams(year)` — `usTaxParams.js resolveSeTaxParams`.
    ///
    /// Unknown, unparseable and future years all fall back to the latest keyed
    /// year, and it never throws. The year arrives as a String from the report
    /// context, so the coercion goes through `ReportMath.number` to match JS's
    /// `Number(year)` — `" 2025 "` resolves, `"2025x"` does not.
    static func resolve(year: String) -> (year: Int, params: Year) {
        let coerced = ReportMath.number(.string(year))
        // `Number.isFinite(y) && TABLE[y]` — a non-integral or out-of-table year
        // takes the fallback.
        if coerced.isFinite, coerced == coerced.rounded(.towardZero),
           let key = Int(exactly: coerced.rounded(.towardZero)),
           let params = byYear[key] {
            return (key, params)
        }
        // `byYear[latestYear]` is non-nil whenever the table is non-empty; the
        // fallback keeps this total rather than force-unwrapping.
        return (latestYear, byYear[latestYear] ?? Year(
            mealsDeductiblePct: 0.5, seEarningsFactor: 0.9235, ssRate: 0.124,
            ssWageCap: 176100, medicareRate: 0.029,
            addlMedicareThreshold: 200000, addlMedicareRate: 0.009))
    }
}
