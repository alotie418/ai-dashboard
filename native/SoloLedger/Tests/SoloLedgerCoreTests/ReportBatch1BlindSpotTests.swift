import XCTest
@testable import SoloLedgerCore

/// The batch-1 behaviours the GOLDENS CANNOT SEE.
///
/// `ReportBatch1ParityTests` compares 360 fields against the committed goldens and
/// they all match — but matching goldens is not the same as being right, because a
/// golden can only discriminate behaviour the FIXTURE happens to exercise. Six
/// deliberate mutations were applied to the engines to find out which:
///
/// | mutation | goldens catch it |
/// | --- | --- |
/// | `isCogsRow` always false | yes — 31 assertions |
/// | CN `shippingFee` hardcoded 0 | yes — 2 assertions (legacy period only) |
/// | CN `grossMargin` uses Japan's formula | **no** |
/// | CN's rounder gains the `\|\| 0` guard | **no** |
/// | expense-side `netAmount` becomes `??` | **no** |
/// | `operatingExpensesNet` re-summed instead of subtracted | **no** |
///
/// This file covers the four blind spots. Every expected value below was produced
/// by running the REAL engine in node with a hand-built context — plan §4.1's
/// Tier-1 mechanism, which needs no sqlite and no Electron binary. The exact
/// command is quoted at each test so the number can be re-derived rather than
/// trusted.
final class ReportBatch1BlindSpotTests: XCTestCase {

    private func ctx(income: [ReportRow], expense: [ReportRow],
                     adminExpense: Double = 0) -> ReportContext {
        ReportContext(
            incomeRows: income, expenseRows: expense,
            categories: [ReportCategory(id: "c", isCogs: .integer(1))],
            adminExpense: adminExpense,
            // Batches 1-4 read no tax rate at all (plan §2). `.notConfigured` is the
            // strictest filler: if this batch ever started reading one, it would
            // produce nothing rather than quietly pricing at some default.
            incomeTaxRate: .notConfigured, surchargeRate: .notConfigured, currency: "X",
            year: "2025", from: "2025-01-01", to: "2025-12-31")
    }

    private func amount(_ v: Double, cogs: Bool = false) -> ReportRow {
        ReportRow(amountNet: v, amount: v, categoryID: cogs ? "c" : nil)
    }

    /// BLIND SPOT 1 — China scales the margin by 10000 in ONE multiply
    /// (`cn.js:30`); Japan/EU/Korea/Taiwan multiply by 100 and let their rounder
    /// multiply by 100 again (`jp.js:26` etc). Algebraically the same, and NOT the
    /// same in binary64.
    ///
    /// The fixture's revenue and COGS happen to agree under both formulas, so the
    /// goldens are blind to it: swapping China onto Japan's formula passes all 360
    /// field assertions. These three pairs do not agree.
    ///
    ///     node -e "const cn=require('./electron/reports/cn.js'),jp=require('./electron/reports/jp.js');
    ///              const c={categories:[{id:'c',is_cogs:1}],surchargeRate:0,incomeTaxRate:0,adminExpense:0,
    ///              currency:'X',year:'2025',from:'2025-01-01',to:'2025-12-31',
    ///              incomeRows:[{amount_net:8,amount:8}],
    ///              expenseRows:[{amount_net:1.73,amount:1.73,category_id:'c'}]};
    ///              console.log(cn.generate(c).incomeStatement.grossMargin,
    ///                          jp.generate(c).incomeStatement.grossMargin)"
    ///     => 78.37 78.38
    func testChinasMarginFormulaIsNotInterchangeableWithTheOtherFour() {
        // revenue 8.00, COGS 1.73
        let a = ctx(income: [amount(8.00)], expense: [amount(1.73, cogs: true)])
        XCTAssertEqual(CNReportEngine.batchOne(a).grossMargin, 78.37, "cn.js:30 — one ×10000")
        XCTAssertEqual(JPReportEngine.batchOne(a).grossMargin, 78.38, "jp.js:26 — ×100 twice")
        XCTAssertEqual(EUReportEngine.batchOne(a).grossMargin, 78.38)
        XCTAssertEqual(KRReportEngine.batchOne(a).grossMargin, 78.38)
        XCTAssertEqual(TWReportEngine.batchOne(a).grossMargin, 78.38)

        // revenue 24.00, COGS 0.03 — here China is the HIGHER one, so this is not
        // a fixed bias that could be "corrected" with an offset.
        let b = ctx(income: [amount(24.00)], expense: [amount(0.03, cogs: true)])
        XCTAssertEqual(CNReportEngine.batchOne(b).grossMargin, 99.88)
        XCTAssertEqual(JPReportEngine.batchOne(b).grossMargin, 99.87)

        // Scaling both sides by 100 keeps the divergence — it is the formula, not
        // the magnitude.
        let c = ctx(income: [amount(800)], expense: [amount(173, cogs: true)])
        XCTAssertEqual(CNReportEngine.batchOne(c).grossMargin, 78.37)
        XCTAssertEqual(JPReportEngine.batchOne(c).grossMargin, 78.38)
    }

    /// BLIND SPOT 2 — `cn.js:43`'s rounder has NO `|| 0`; every other engine's
    /// does. With a NaN input China propagates it (JS then serializes null) while
    /// the others flatten it to 0.
    ///
    /// `adminExpense` is a batch-1 field, so this asymmetry is inside this batch's
    /// surface — but the goldens never exercise it, because the generator's
    /// `malformed` variant corrupts `surcharge_rate` and `income_tax_rate` only,
    /// never `admin_expense_annual`.
    ///
    ///     node -e "…adminExpense:NaN… JSON.stringify(cn.generate(c).incomeStatement.adminExpense)"
    ///     => CN null, JP 0, JP operatingProfit 0
    func testOnlyChinaPropagatesANaNAdminExpense() {
        let a = ctx(income: [amount(100)], expense: [], adminExpense: .nan)
        XCTAssertTrue(CNReportEngine.batchOne(a).adminExpense.isNaN,
                      "cn.js:43 has no `|| 0` — JSON.stringify writes this as null")
        XCTAssertEqual(JPReportEngine.batchOne(a).adminExpense, 0, "jp.js:14 flattens it")
        XCTAssertEqual(EUReportEngine.batchOne(a).adminExpense, 0)
        XCTAssertEqual(KRReportEngine.batchOne(a).adminExpense, 0)
        XCTAssertEqual(TWReportEngine.batchOne(a).adminExpense, 0)
        // …and the NaN does not leak into Japan's operating profit either, because
        // the same guard catches it on the way out.
        XCTAssertEqual(JPReportEngine.batchOne(a).operatingProfit, 0)
    }

    /// BLIND SPOT 3 — `_expenseSplit.js:24` is `amount_net || amount || 0`, so an
    /// expense row whose net amount is exactly 0 falls back to the TAX-INCLUSIVE
    /// amount. Swift's `??` would keep the 0.
    ///
    /// The income side of this is caught by the goldens; the EXPENSE side is not,
    /// because no expense row in the fixture has `amount_net = 0`.
    ///
    ///     node -e "…expenseRows:[{amount_net:0,amount:113,category_id:'c'}]…
    ///              cn.generate(c).incomeStatement.costOfGoodsSold"
    ///     => 113
    func testZeroNetExpenseFallsBackToTheTaxInclusiveAmount() {
        let a = ctx(income: [ReportRow(amountNet: 1000, amount: 1130)],
                    expense: [ReportRow(amountNet: 0, amount: 113, categoryID: "c")])
        let cn = CNReportEngine.batchOne(a)
        XCTAssertEqual(cn.costOfGoodsSold, 113, "0 here would mean `??` semantics crept in")
        XCTAssertEqual(cn.costOfSales, 113)
        XCTAssertEqual(cn.operatingExpenses, 0)
        XCTAssertEqual(cn.grossProfit, 887)
        // Same row through the split helper directly.
        let split = ExpenseSplit.splitExpenses(
            [ReportRow(amountNet: 0, amount: 113, categoryID: "c")],
            [ReportCategory(id: "c", isCogs: .integer(1))])
        XCTAssertEqual(split.cogsNet, 113)
        XCTAssertEqual(split.totalExpenseNet, 113)
    }

    /// BLIND SPOT 4 — `operatingExpensesNet` is `totalExpenseNet - cogsNet`, never a
    /// second sum over the non-COGS rows. The two disagree in binary64 on ~7% of
    /// money-shaped inputs.
    ///
    /// Asserted on the RAW split, deliberately. At the emitted fields the
    /// difference has never been observed to survive `Math.round(v * 100) / 100` —
    /// 2,000,000 random cases, zero differences — so an engine-level test would
    /// pass under both spellings and prove nothing. The raw value is where the
    /// choice is real, and later batches consume the raw value.
    ///
    ///     node -e "const rows=[9927.6,3840.64,719.93]; // first two are COGS
    ///              const total=rows.reduce((s,v)=>s+v,0), cogs=9927.6+3840.64;
    ///              console.log(total-cogs, 719.93)"
    ///     => 719.9300000000003  719.93
    func testOperatingExpensesIsASubtractionNotASecondSum() {
        let cats = [ReportCategory(id: "c", isCogs: .integer(1))]
        let rows = [amount(9927.60, cogs: true), amount(3840.64, cogs: true), amount(719.93)]
        let split = ExpenseSplit.splitExpenses(rows, cats)

        XCTAssertEqual(split.operatingExpensesNet, 719.9300000000003,
                       "the SUBTRACTION result; a second sum over the non-COGS rows gives 719.93")
        XCTAssertNotEqual(split.operatingExpensesNet, 719.93,
                          "if these become equal, the subtraction was replaced")
        // What DOES hold for this input, and is the reason the source subtracts:
        // the partition is exact by construction, so the three numbers reconcile
        // even though the second sum would not have produced the same middle term.
        XCTAssertEqual(split.cogsNet + split.operatingExpensesNet, split.totalExpenseNet)
    }

    /// Row ORDER is part of the answer — addition is not associative in binary64,
    /// which is why `index.js:47-52` carries `ORDER BY date` and why the mirror
    /// accumulates left to right rather than, say, sorting or using a parallel sum.
    func testAccumulationOrderIsPreserved() {
        let cats: [ReportCategory] = []
        let a = ExpenseSplit.splitExpenses([amount(0.1), amount(0.2), amount(0.3)], cats)
        let b = ExpenseSplit.splitExpenses([amount(0.3), amount(0.2), amount(0.1)], cats)
        XCTAssertEqual(a.totalExpenseNet, 0.6000000000000001)
        XCTAssertEqual(b.totalExpenseNet, 0.6)
        XCTAssertNotEqual(a.totalExpenseNet, b.totalExpenseNet,
                          "left-to-right accumulation is observable; the SQL ORDER BY fixes it")
    }

    /// `is_cogs` truthiness follows the SQLite storage class, because `index.js:70`
    /// is `SELECT *` and the value never passes through `categories.js`'s
    /// `!!` coercion. Not reachable from today's fixture — every cell is an
    /// integer — so this states the rule the code implements rather than a
    /// behaviour the goldens could confirm.
    func testIsCogsFollowsJavaScriptTruthinessOverTheRawStorageClass() {
        let cases: [(SQLiteValue, Bool)] = [
            (.integer(1), true), (.integer(0), false), (.integer(-1), true),
            (.real(0.5), true), (.real(0), false), (.real(.nan), false),
            (.text("yes"), true), (.text(""), false), (.text("0"), true),  // JS: "0" is TRUTHY
            (.null, false),
        ]
        for (raw, expected) in cases {
            XCTAssertEqual(ReportCategory(id: "c", isCogs: raw).isCogsTruthy, expected,
                           "\(raw)")
        }
        // The one that most often gets written the other way round: the STRING "0"
        // is truthy in JavaScript, while the INTEGER 0 is not.
        XCTAssertTrue(ReportCategory(id: "c", isCogs: .text("0")).isCogsTruthy)
        XCTAssertFalse(ReportCategory(id: "c", isCogs: .integer(0)).isCogsTruthy)
    }

    /// A `category_id` matching no category is not COGS — which is what happens to
    /// a row whose category belongs to another regime, since `index.js:70` filters
    /// `WHERE locale = ?`. It silently becomes an operating expense.
    func testAnOrphanedCategoryFallsToOperatingExpenses() {
        let split = ExpenseSplit.splitExpenses(
            [ReportRow(amountNet: 500, amount: 500, categoryID: "belongs-to-another-locale")],
            [ReportCategory(id: "c", isCogs: .integer(1))])
        XCTAssertEqual(split.cogsNet, 0)
        XCTAssertEqual(split.operatingExpensesNet, 500)
    }
}
