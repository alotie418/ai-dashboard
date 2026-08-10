import Foundation

/// `scheduleC` — the US batch-3 block (`us.js scheduleC` — the local literal and the emitted key).
///
/// Twenty-five fields in the SOURCE's order, which is not the form's order:
/// `line30_homeOffice` sits before `line28_totalExpenses` and `line31_netProfit`
/// because those two are spread in afterwards (`us.js scheduleC`). The order is
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
struct ScheduleC: Equatable, Sendable {
    // Part I — income (us.js line1_grossReceipts)
    let line1_grossReceipts: Double
    let line2_returns: Double
    let line6_otherIncome: Double
    let line7_grossIncome: Double
    // Part II — expenses (us.js line8_advertising)
    let line8_advertising: Double
    let line9_car: Double
    let line10_commissions: Double
    let line11_contract: Double
    let line13_depreciation: Double
    let line15_insurance: Double
    let line16b_interest: Double
    let line17_legal: Double
    let line18_office: Double
    let line20_rent: Double
    let line21_repairs: Double
    let line22_supplies: Double
    let line23_taxes: Double
    let line24a_travel: Double
    let line24b_meals: Double
    let line25_utilities: Double
    let line26_wages: Double
    let line27a_other: Double
    let line30_homeOffice: Double
    // Spread in after the literal (us.js scheduleC)
    let line28_totalExpenses: Double
    let line31_netProfit: Double

    /// Unrounded intermediates the estimate layer consumes (`us.js netProfit` feeds
    /// `us.js seEarnings`, `estimatedAnnualTax`, `netEarnings`, `annualIncomeTax`). Carried so
    /// batch 5 does not have to re-mirror
    /// the whole mapping to get at them; not part of the golden comparison.
    let unroundedGrossIncome: Double
    let unroundedTotalExpenses: Double
    /// The RAW `meals` slug total, before the 50% and before rounding. Batch 5's
    /// meals warning tests this, not `line24b_meals` — a total of 0.004 fires the
    /// warning while its Line 24b rounds to 0.
    let rawMealsTotal: Double
}
