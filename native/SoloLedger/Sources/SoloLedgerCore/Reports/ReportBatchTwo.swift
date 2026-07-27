import Foundation

/// Batch-2 output shapes: the tax-inclusive summary and the monthly breakdown.

/// `taxInclusiveSummary` — the five VAT engines (`cn.js:78-82`, `jp.js:50-53`,
/// `eu.js:47-49`, `kr.js:44-46`, `tw.js:44-46`).
///
/// **The US has no such block at all.** Not an empty one — the key is absent from
/// `us.js`'s output entirely, which is why the golden field count is 3 × 45 rather
/// than 3 × 54.
///
/// Every figure here is TAX-INCLUSIVE: these sum `row.amount`, where the P&L sums
/// `amount_net || amount || 0`. Two different questions over the same rows.
public struct TaxInclusiveSummary: Equatable, Sendable {
    public let purchaseTotal: Double
    public let salesTotal: Double
    public let difference: Double
}

/// One entry of `monthlyBreakdown`.
///
/// `month` is 1...12 and there are ALWAYS twelve of them — see
/// ``ReportMonth/prefixes(year:)``.
public struct ReportMonth: Equatable, Sendable {
    public let month: Int
    public let revenue: Double
    public let cost: Double
    public let profit: Double

    /// The twelve `"YYYY-MM"` prefixes a breakdown matches against, built from
    /// **`ctx.year`** — not from the reporting period.
    ///
    /// This is Appendix A9, and it is stronger than the plan states. The window is
    /// the calendar year, so:
    ///
    /// * a quarterly report still emits twelve months, nine of them empty;
    /// * `base-CN-2024H2-2025H1` (period 2024-07-01…2025-06-30, year 2025) has a
    ///   `monthlyBreakdown` **byte-identical** to `base-CN-2025` — its 2024 half
    ///   appears in no month;
    /// * a row inside `[from, to]` but outside `ctx.year` counts in the period
    ///   totals and appears in NO month, so the months need not sum to the
    ///   statement.
    ///
    /// Mirrored exactly. The correction is registered in Appendix A9 as needing to
    /// be designed together with the period selector.
    public static func prefixes(year: String) -> [String] {
        (1...12).map { "\(year)-\(String(format: "%02d", $0))" }
    }
}

/// The two spellings the engines use to test a row's date against a month prefix.
///
/// **They agree on every input reachable here, and that was measured rather than
/// assumed.** An empty-string date is excluded by both — China's because `""` is
/// falsy, the others' because `"".startsWith("2025-01")` is false — and a null
/// date is excluded by both. The prefixes are never empty, which is the only input
/// that would separate them.
///
/// So this is a fidelity distinction, not a behavioural one, and it is written
/// that way rather than as a claim that one is safer. They are kept apart because
/// "these looked the same, so I unified them" is the class of edit this phase
/// exists to not make — and because a future divergence in one engine would then
/// show up as a change to one function instead of a change to a shared one.
enum MonthMatch {
    /// `cn.js:96` — `r.date && r.date.startsWith(prefix)`.
    static func cn(_ date: String?, _ prefix: String) -> Bool {
        guard let date, !date.isEmpty else { return false }   // JS: "" is falsy
        return date.hasPrefix(prefix)
    }

    /// `jp.js:64`, `eu.js:60`, `kr.js:57`, `tw.js:57`, `us.js:135` —
    /// `x.date?.startsWith(p)`.
    static func optionalChained(_ date: String?, _ prefix: String) -> Bool {
        guard let date else { return false }
        return date.hasPrefix(prefix)
    }
}
