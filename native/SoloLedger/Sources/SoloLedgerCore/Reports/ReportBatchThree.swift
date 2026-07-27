import Foundation

/// `scheduleC` — the US batch-3 block (`us.js:34-59`, `:85-89`).
///
/// Twenty-five fields in the SOURCE's order, which is not the form's order:
/// `line30_homeOffice` sits before `line28_totalExpenses` and `line31_netProfit`
/// because those two are spread in afterwards (`us.js:86-88`). The order is
/// preserved because it is the order a reader comparing this file to the JS will
/// scan, not because anything depends on it.
///
/// ## Three mirrored defects that reach reported numbers
///
/// Each is reproduced exactly and pinned by a test that says what it is. They are
/// accounting judgements, which CLAUDE.md says an AI must not settle, so they are
/// registered as fix candidates rather than repaired here:
///
/// 1. **`other-income` is counted twice.** `line1_grossReceipts` sums ALL income
///    rows, and `line6_otherIncome` sums the `other-income` subset again;
///    `line7_grossIncome` is `line1 - line2 + line6`. A lone 900 row therefore
///    reports 900 / 900 / 1800. The doubling is already baked into
///    `base-US-2026.json` (52400 − 1500 + 900 = 51800).
/// 2. **`line30_homeOffice` is summed into `line28_totalExpenses`.** On the real
///    form, home-office is Form 8829 and Line 28 covers lines 8–27a only. The
///    fixture's own `categories.schedule_line` column says `Form 8829` for that
///    slug, so the ledger disagrees with the engine about where the number belongs.
/// 3. **A negative `returns` row makes `line2` negative** and leaves `line7`
///    unchanged in sign. Unreachable from the fixture, so no golden constrains it.
public struct ScheduleC: Equatable, Sendable {
    // Part I — income (us.js:35-38)
    public let line1_grossReceipts: Double
    public let line2_returns: Double
    public let line6_otherIncome: Double
    public let line7_grossIncome: Double
    // Part II — expenses (us.js:40-58)
    public let line8_advertising: Double
    public let line9_car: Double
    public let line10_commissions: Double
    public let line11_contract: Double
    public let line13_depreciation: Double
    public let line15_insurance: Double
    public let line16b_interest: Double
    public let line17_legal: Double
    public let line18_office: Double
    public let line20_rent: Double
    public let line21_repairs: Double
    public let line22_supplies: Double
    public let line23_taxes: Double
    public let line24a_travel: Double
    public let line24b_meals: Double
    public let line25_utilities: Double
    public let line26_wages: Double
    public let line27a_other: Double
    public let line30_homeOffice: Double
    // Spread in after the literal (us.js:86-88)
    public let line28_totalExpenses: Double
    public let line31_netProfit: Double

    /// Unrounded intermediates the estimate layer consumes (`us.js:65` feeds
    /// `:68`, `:76`, `:92`, `:102`). Carried so batch 5 does not have to re-mirror
    /// the whole mapping to get at them; not part of the golden comparison.
    public let unroundedGrossIncome: Double
    public let unroundedTotalExpenses: Double
    /// The RAW `meals` slug total, before the 50% and before rounding. Batch 5's
    /// meals warning tests this, not `line24b_meals` — a total of 0.004 fires the
    /// warning while its Line 24b rounds to 0.
    public let rawMealsTotal: Double
}
