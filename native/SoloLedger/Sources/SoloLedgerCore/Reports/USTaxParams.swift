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
/// Batch 3 needs exactly one field: `mealsDeductiblePct`, the 50% limit applied to
/// Line 24b (`us.js:54`). The SE-tax constants that live in the same JS table —
/// `seEarningsFactor`, `ssRate`, `ssWageCap`, `medicareRate`,
/// `addlMedicareThreshold`, `addlMedicareRate` — belong to the estimate layer and
/// arrive with batch 5. They are not copied here "ready for later", because a
/// mirrored tax constant with no caller is a number nobody is checking.
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
public enum USTaxParams {

    public struct Year: Equatable, Sendable {
        /// The share of meal expense that Line 24b may deduct (`us.js:54`).
        public let mealsDeductiblePct: Double
    }

    /// `US_SE_TAX_PARAMS_BY_YEAR` — batch-3 fields only (`usTaxParams.js:17-21`).
    public static let byYear: [Int: Year] = [
        2024: Year(mealsDeductiblePct: 0.5),
        2025: Year(mealsDeductiblePct: 0.5),
        2026: Year(mealsDeductiblePct: 0.5),
    ]

    /// `LATEST_YEAR` — `Math.max(...YEARS)` at `usTaxParams.js:23-24`.
    ///
    /// Derived from the table rather than written as a literal, exactly as the
    /// source derives it. A literal would silently stop tracking the table the
    /// first time a year is added.
    public static let latestYear: Int = byYear.keys.max() ?? 0

    /// `resolveSeTaxParams(year)` — `usTaxParams.js:28-32`.
    ///
    /// Unknown, unparseable and future years all fall back to the latest keyed
    /// year, and it never throws. The year arrives as a String from the report
    /// context, so the coercion goes through `ReportMath.number` to match JS's
    /// `Number(year)` — `" 2025 "` resolves, `"2025x"` does not.
    public static func resolve(year: String) -> (year: Int, params: Year) {
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
        return (latestYear, byYear[latestYear] ?? Year(mealsDeductiblePct: 0.5))
    }
}
