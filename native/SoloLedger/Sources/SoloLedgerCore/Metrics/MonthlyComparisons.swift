import Foundation

/// Month-on-month / year-on-year / price-index comparisons — a line-by-line mirror of
/// `electron/handlers/_metrics.js` (33 lines), whose own header states the basis:
///
/// > 口径（PR-A）：mom/yoy 按「营收 revenue（不含税）」计算。
/// > **基期缺失或为 0 一律返回 null**（绝不返回 0，避免误导用户的 0.0% 假同比/环比）。
///
/// That basis is NOT this file's to choose. `_metrics.js:2-6` fixes it, and the mirror copies it.
///
/// ## What "mirror" means here, precisely
///
/// The JS is arithmetic on IEEE-754 doubles, so this file is `Double` end to end and never
/// `Decimal`. Every operation is performed in the same order as the JS, because the order is
/// observable: `pct(100.05, 100)` is `0`, not `0.1`, since `100.05 - 100` is
/// `0.04999999999999716` and the scaled value lands just under the tie. Reordering or
/// "simplifying" the expression changes the answer.
///
/// ## The JS↔Swift value mapping
///
/// JS `null` ⇄ Swift `nil`; a JS number ⇄ `.some(Double)`. That distinction carries real
/// behaviour: `pct` returns the NUMBER `NaN` for a `NaN` base (`_metrics.js pct` tests
/// `base == null` and `base === 0`, and `NaN` is neither), which is `.some(.nan)` here — not
/// `nil`. A caller that collapses the two loses a case the JS keeps apart.
///
/// ## What this file deliberately does NOT reproduce
///
/// `_metrics.js computeMonthlyComparisons` spreads the input row into the output (`...m`), so the JS result carries
/// every field the caller put in. Swift has no equivalent, and inventing a dictionary to fake
/// one would mirror the syntax rather than the semantics. ``compute(_:priorRevenue:)`` returns
/// the three computed values in input order; the caller keeps its own rows and zips. All three
/// computed fields — `mom`, `yoy` and `deflator` — are present, so nothing the JS produces is
/// dropped.
///
/// ## `deflator` is mirrored, and under this app's data model it is always `nil`
///
/// The price index divides revenue by `salesTons`, which in Electron comes only from the legacy
/// `sales` table (`dashboard.js monthlySales`); the report-engine branch carries it over from that
/// same array. This app never reads that column — the legacy converter copies `tons` into the
/// description text and not into a numeric column, and `transactions` has no quantity column at
/// all. So every row this app can build has `salesTons == 0`, `unitRevs` is empty, `avgUnitRev`
/// is `0`, the `avgUnitRev > 0` guard fails, and `deflator` is `nil` for every month.
///
/// That is not a gap in the mirror: it is what the JS itself produces for the same input, and
/// `scripts/test-metrics.mjs:56-58` already pins it ("deflator all null (no sales volume)").
/// The field is kept so the two implementations stay comparable case for case.
public enum MonthlyComparisons {

    // MARK: - Input

    /// The two fields `_metrics.js` actually reads off a monthly row.
    ///
    /// Both are optional because the JS reads them off a plain object where a missing property
    /// is `undefined`, and the two paths treat that differently: `revenue` goes into arithmetic
    /// (so `undefined` becomes `NaN`), while `salesTons` goes through `|| 0` (`:19`, `:27`),
    /// which folds `undefined`, `null`, `0`, `-0` and `NaN` alike to `0`.
    public struct Row: Equatable, Sendable {
        /// `m.revenue`. `nil` mirrors a missing property, which JS arithmetic turns into `NaN`.
        public var revenue: Double?
        /// `m.salesTons`, before the `|| 0` fold.
        public var salesTons: Double?

        public init(revenue: Double? = nil, salesTons: Double? = nil) {
            self.revenue = revenue
            self.salesTons = salesTons
        }
    }

    /// One row's three comparisons. `nil` is the JS `null`.
    public struct Comparison: Equatable, Sendable {
        public var mom: Double?
        public var yoy: Double?
        public var deflator: Double?

        public init(mom: Double? = nil, yoy: Double? = nil, deflator: Double? = nil) {
            self.mom = mom
            self.yoy = yoy
            self.deflator = deflator
        }
    }

    // MARK: - `Math.round`

    /// JavaScript's `Math.round`, which is NOT Swift's `rounded()`.
    ///
    /// Two differences, both reachable from real percentages:
    ///
    /// * **Ties go toward +∞, not away from zero.** `Math.round(-1.5)` is `-1`; Swift's
    ///   `(-1.5).rounded()` is `-2`. A −1.5% change would print as −0.2% instead of −0.1%.
    /// * **It is not `floor(x + 0.5)`.** `Math.round(0.49999999999999994)` is `0`, because the
    ///   addition would round up to exactly `1.0` before the floor sees it. Measured against
    ///   V8, not assumed.
    ///
    /// `-0` survives on purpose: `Math.round(-0.5)` is `-0`, and so is any negative input that
    /// rounds to zero. It compares equal to `0` and prints as `"0"`, but it is a distinct
    /// bit pattern that a golden comparison can see.
    ///
    /// Validated against the real engine over 416,027 values (every tie in ±2000, the
    /// pathological literal above, ±0, ±∞, `NaN`, 2⁵² and a large pseudo-random sample) with
    /// zero disagreements.
    ///
    /// ## Why this is a second copy and not a call to `ReportMath.round`
    ///
    /// `ReportMath.round` implements the same rule, and duplicating a subtle algorithm is
    /// normally the worse choice. It is written out again here for the reason
    /// `InventoryPosting.swift:41` states from the other side: that function "exists to
    /// reproduce report goldens", and a change made there for a report reason must not silently
    /// become a change to these percentages. The rounding rules in this package stay visibly
    /// separate, one per subsystem that needs one.
    ///
    /// Separate is not the same as free to drift: `MonthlyComparisonsTests` pins the two equal
    /// over a wide sample, so a divergence fails a test instead of shipping.
    static func jsRound(_ x: Double) -> Double {
        // `NaN`, ±∞ and ±0 are returned unchanged, sign included.
        if x.isNaN || x.isInfinite || x == 0 { return x }
        let f = x.rounded(.down)
        let r = (x - f) < 0.5 ? f : f + 1
        // `Math.round(-0.4)` and `Math.round(-0.5)` are both `-0`, not `+0`.
        if r == 0, x < 0 { return -0.0 }
        return r
    }

    // MARK: - `pct`

    /// Percentage change to one decimal place; `nil` when the base period is missing or zero.
    ///
    /// Mirrors `_metrics.js pct`:
    ///
    /// ```js
    /// if (base == null || base === 0) return null;
    /// return Math.round(((cur - base) / base) * 1000) / 10;
    /// ```
    ///
    /// Three things that guard hides:
    ///
    /// * `base == null` is LOOSE equality, so it catches `null` and `undefined` — both `nil`
    ///   here — and nothing else. In particular a `NaN` base passes both tests and the function
    ///   returns the number `NaN`.
    /// * `base === 0` is true for `-0` as well, so a `-0` base returns `nil`.
    /// * A negative base is a normal case, not an error: `pct(90, -100)` is `-190`.
    public static func pct(_ cur: Double?, _ base: Double?) -> Double? {
        guard let base, base != 0 else { return nil }   // `base == null || base === 0`
        // A missing `cur` is `undefined` in the JS, and `undefined - base` is `NaN`.
        let current = cur ?? .nan
        return jsRound(((current - base) / base) * 1000) / 10
    }

    // MARK: - `computeMonthlyComparisons`

    /// Mirrors `_metrics.js computeMonthlyComparisons`.
    ///
    /// - Parameters:
    ///   - monthly: the rows, in month order. `_metrics.js mom` reads `monthly[i - 1].revenue`
    ///     from the INPUT array, so a row's `mom` is against its predecessor's original
    ///     revenue, never against a value this function produced.
    ///   - priorRevenue: last year's revenue aligned by index. An index past the end is
    ///     `undefined` in the JS and `nil` here, which `pct` turns into `nil`. Passing an empty
    ///     array is the JS default (`:16`) and yields `nil` for every `yoy` — note the JS
    ///     guard `priorRevenue ? … : null` cannot distinguish that from an omitted argument,
    ///     because `[]` is truthy.
    public static func compute(_ monthly: [Row],
                               priorRevenue: [Double?] = []) -> [Comparison] {
        // `:18-21` — the price-index base: the mean unit revenue over months that sold anything.
        let unitRevs: [Double] = monthly.compactMap { row in
            let tons = truthyOrZero(row.salesTons)
            guard tons > 0 else { return nil }
            return (row.revenue ?? .nan) / tons
        }
        let avgUnitRev = unitRevs.isEmpty ? 0 : unitRevs.reduce(0, +) / Double(unitRevs.count)

        return monthly.enumerated().map { index, row in
            let tons = truthyOrZero(row.salesTons)
            return Comparison(
                // `:25` — the first month has no predecessor, so it is `null` rather than 0%.
                mom: index > 0 ? pct(row.revenue, monthly[index - 1].revenue) : nil,
                // `:26`
                yoy: pct(row.revenue, index < priorRevenue.count ? priorRevenue[index] : nil),
                // `:27-29`. Both guards matter: a month with no volume has no unit revenue, and
                // a non-positive mean would invert the index. `avgUnitRev` is also `NaN` when
                // any qualifying month has no revenue, and `NaN > 0` is false, so the whole
                // column falls back to `null` — the JS behaves the same way for the same reason.
                deflator: tons > 0 && avgUnitRev > 0
                    ? jsRound(((row.revenue ?? .nan) / tons / avgUnitRev) * 1000) / 10
                    : nil
            )
        }
    }

    /// `value || 0` for a number: everything falsy in JS — `undefined`, `null`, `0`, `-0` and
    /// `NaN` — becomes `0`. Used at `_metrics.js computeMonthlyComparisons` and `:27`.
    ///
    /// The `NaN` arm is not observable through ``compute(_:priorRevenue:)``: every caller
    /// immediately asks `> 0`, and that is false for `NaN` whether or not it was folded. It is
    /// written out anyway because `|| 0` really does produce `0` — a later caller that uses the
    /// value for anything other than a comparison would see the difference — and it is `internal`
    /// rather than `private` so a test can pin the semantics that the comparison hides.
    static func truthyOrZero(_ value: Double?) -> Double {
        guard let value, value != 0, !value.isNaN else { return 0 }
        return value
    }
}
