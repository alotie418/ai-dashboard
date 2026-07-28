import XCTest
@testable import SoloLedgerCore

/// The batch-2 behaviours the GOLDENS CANNOT SEE.
///
/// `ReportBatch2ParityTests` asserts 3267 golden fields and they all match. Ten
/// deliberate mutations were then applied to find out how much that proves:
///
/// | mutation | goldens catch it |
/// | --- | --- |
/// | CN `monthlyBreakdown` sums the tax-inclusive amount | yes — 14 |
/// | US `monthlyBreakdown` sums the net amount | yes — 14 |
/// | `txnCashAmount` drops the `> 0` test | **no** |
/// | `txnCashAmount` drops the paid-status fallback | **no** |
/// | `cashAmount <= 0` inverted to `> 0` | **no** — and unreachable, see below |
/// | an unknown `type` falls through to expense | **no** |
/// | CN's tax-inclusive rounder gains `\|\| 0` | **no** — and unreachable, see below |
/// | `difference` rounded twice instead of once | **no** |
/// | CN's date-match spelling swapped for the other one | **no** — and equivalent |
/// | the cash window drops `COALESCE(payment_date, date)` | **no** |
///
/// Eight of ten invisible — and of those eight, three are not behaviours at all
/// (see below); the remaining five are real and are what this file pins. `_cashflow.js` in particular is almost entirely
/// unpinned by the fixture, because every row in it is a plainly-paid row with a
/// positive `paid_amount`.
///
/// Every expected value below came from executing the REAL engine — `txnCashAmount`
/// and `computeOperatingCashflow` from `electron/reports/_cashflow.js` against an
/// in-memory SQLite, and the five report engines as pure functions (plan §4.1
/// Tier-1). The commands are quoted so the numbers can be re-derived.
///
/// Three of the ten turned out NOT to be behavioural at all — the two rounders
/// cannot be told apart through a tax-inclusive sum, the two date spellings agree
/// on every reachable input, and the `<= 0` polarity only differs on a NaN that
/// `txnCashAmount` can never produce. Each is recorded as a test that says so
/// rather than dressed up as a behaviour, because the alternative is a later
/// reader re-deriving the same dead end — or "simplifying" on the theory that the
/// difference must have mattered.
final class ReportBatch2BlindSpotTests: XCTestCase {

    private func row(_ type: String, amount: Double?, paid: Double?, status: String?) -> CashflowRow {
        CashflowRow(type: type, amount: amount, paidAmount: paid, paymentStatus: status)
    }

    // MARK: - txnCashAmount
    //
    //     ELECTRON_RUN_AS_NODE=1 ./node_modules/.bin/electron -e "
    //       const {txnCashAmount} = require('./electron/reports/_cashflow.js');
    //       console.log(txnCashAmount({payment_status:'paid', amount:500, paid_amount:-100}))"

    /// A NEGATIVE `paid_amount` is truthy, fails `> 0`, and therefore falls through
    /// to the FULL amount — it is not clamped to 0 and it is not used as −100.
    ///
    /// This is why `row.paid_amount && row.paid_amount > 0` is two tests and not
    /// one. Dropping the `> 0` makes the row contribute −100; dropping the
    /// truthiness test alone happens to agree.
    func testNegativePaidAmountFallsThroughToTheFullAmount() {
        XCTAssertEqual(Cashflow.txnCashAmount(row("income", amount: 500, paid: -100, status: "paid")), 500)
        // …but only because the status is `paid`. A `partial` row with a negative
        // paid_amount contributes nothing.
        XCTAssertEqual(Cashflow.txnCashAmount(row("income", amount: 500, paid: -100, status: "partial")), 0)
    }

    /// `paid_amount` of 0 or NULL on a `paid` row falls back to the full `amount`;
    /// on a `partial` row it does not.
    func testPaidRowFallsBackToAmountAndPartialDoesNot() {
        XCTAssertEqual(Cashflow.txnCashAmount(row("income", amount: 500, paid: nil, status: "paid")), 500)
        XCTAssertEqual(Cashflow.txnCashAmount(row("income", amount: 500, paid: 0, status: "paid")), 500)
        XCTAssertEqual(Cashflow.txnCashAmount(row("income", amount: 500, paid: 200, status: "paid")), 200)
        XCTAssertEqual(Cashflow.txnCashAmount(row("income", amount: 500, paid: nil, status: "partial")), 0)
        XCTAssertEqual(Cashflow.txnCashAmount(row("income", amount: 500, paid: 300, status: "partial")), 300)
        // `amount` null on a paid row with no paid_amount → `(row.amount || 0)` → 0.
        XCTAssertEqual(Cashflow.txnCashAmount(row("income", amount: nil, paid: nil, status: "paid")), 0)
    }

    /// The helper does NOT filter by status — the
    /// `payment_status IN ('paid','partial')` gate lives only in the SQL. So an
    /// `unpaid` row handed to it directly still yields its `paid_amount`.
    ///
    /// Both gates are load-bearing and they are in different places; a mirror that
    /// folded the status check into the helper would double-filter and one that
    /// dropped the SQL gate would let unpaid money into the total.
    func testTheHelperDoesNotApplyTheStatusFilter() {
        XCTAssertEqual(Cashflow.txnCashAmount(row("income", amount: 500, paid: 900, status: "unpaid")), 900)
        XCTAssertEqual(Cashflow.txnCashAmount(row("income", amount: 500, paid: 300, status: "")), 300)
        XCTAssertEqual(Cashflow.txnCashAmount(row("income", amount: 500, paid: 300, status: nil)), 300)
    }

    // MARK: - the accumulation

    /// A row whose `type` is neither `income` nor `expense` is DROPPED, not treated
    /// as an expense. `_cashflow.js:62-63` is `if / else if` with no `else`.
    ///
    ///     …computeOperatingCashflow over [{type:'refund', paid 500}, {type:'income', paid 10}]
    ///     => inflow 10, outflow 0, net 10
    func testAnUnknownTypeIsDroppedRatherThanDefaulted() {
        let out = Cashflow.operating(rows: [
            row("refund", amount: 500, paid: 500, status: "paid"),
            row("income", amount: 10, paid: 10, status: "paid"),
        ])
        XCTAssertEqual(out.inflow, 10)
        XCTAssertEqual(out.outflow, 0, "a 'refund' row must not become an outflow")
        XCTAssertEqual(out.net, 10)
    }

    /// Recorded as NOT behavioural, after checking rather than assuming.
    ///
    /// `if (cashAmt <= 0) continue` differs from `if (!(cashAmt > 0))` on exactly
    /// one value — NaN — and `txnCashAmount` **can never return one**:
    /// `paid_amount` of NaN is falsy so it is skipped, and the fallback is
    /// `(row.amount || 0)`, which flattens NaN to 0. Verified in node against the
    /// real helper.
    ///
    /// So the polarity is a fidelity choice, not a safety one. It is kept as the
    /// source spells it, and this test exists so the next reader does not have to
    /// re-derive that the mutation is undetectable — or, worse, "simplify" it on
    /// the theory that the difference must have mattered.
    func testTheSkipTestPolarityIsUnreachableBecauseCashIsNeverNaN() {
        // Every route into the comparison, and none of them is NaN.
        XCTAssertEqual(Cashflow.txnCashAmount(row("income", amount: .nan, paid: nil, status: "paid")), 0)
        XCTAssertEqual(Cashflow.txnCashAmount(row("income", amount: .nan, paid: .nan, status: "paid")), 0)
        XCTAssertEqual(Cashflow.txnCashAmount(row("income", amount: .nan, paid: .nan, status: "partial")), 0)
        let out = Cashflow.operating(rows: [row("income", amount: .nan, paid: nil, status: "paid")])
        XCTAssertEqual(out.inflow, 0, "the row contributes 0 and is then skipped, not NaN")
        // Infinity DOES reach the comparison — and both spellings agree on it.
        XCTAssertEqual(Cashflow.txnCashAmount(row("income", amount: .infinity, paid: nil, status: "paid")),
                       .infinity)
        // (The two comparisons themselves are not asserted here: the compiler
        // rejects `nan <= 0` as always-false, which is the same fact this test is
        // about, stated by the type checker instead.)
    }

    /// `net` is `round2(inflow - outflow)` over the RAW sums — the subtraction
    /// happens before any rounding.
    ///
    ///     …0.145 in / 0.005 out => inflow 0.14, outflow 0.01, net 0.14
    ///
    /// Rounding first would give `0.14 - 0.01 = 0.13`, which is a cent wrong and
    /// inside plan §4.2's eps tolerance — one of the reasons the parity test
    /// compares exactly.
    func testNetIsTheRoundedDifferenceNotTheDifferenceOfRoundings() {
        let out = Cashflow.operating(rows: [
            row("income", amount: 0.145, paid: 0.145, status: "paid"),
            row("expense", amount: 0.005, paid: 0.005, status: "paid"),
        ])
        XCTAssertEqual(out.inflow, 0.14)
        XCTAssertEqual(out.outflow, 0.01)
        XCTAssertEqual(out.net, 0.14, "NOT 0.13 — the subtraction is rounded once")
        XCTAssertEqual(out.inflow - out.outflow, 0.13,
                       "the rounded-first spelling, shown so the one-cent gap is visible")
    }

    // MARK: - the SQL-level behaviours, through the real fetch

    private func ledger(_ rows: [(String, String, Double, Double?, String, String?)]) throws
        -> SQLiteDatabase {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cf-\(UUID().uuidString).db")
        let db = try SQLiteDatabase(path: url.path, mode: .readWriteCreate)
        try db.execute("""
            CREATE TABLE transactions (id TEXT, type TEXT, date TEXT, amount REAL,
              paid_amount REAL, payment_status TEXT, payment_date TEXT)
            """)
        for (i, r) in rows.enumerated() {
            let paid = r.3.map { "\($0)" } ?? "NULL"
            let payDate = r.5.map { "'\($0)'" } ?? "NULL"
            try db.execute("""
                INSERT INTO transactions VALUES ('t\(i)', '\(r.0)', '\(r.1)', \(r.2),
                  \(paid), '\(r.4)', \(payDate))
                """)
        }
        return db
    }

    /// The `payment_status IN ('paid','partial')` gate: unpaid, empty-string and
    /// NULL statuses are excluded by the SQL even when they carry a positive
    /// `paid_amount`.
    ///
    ///     …three 900-paid_amount rows with status unpaid/''/NULL plus one paid 1
    ///     => inflow 1
    func testTheStatusFilterExcludesUnpaidEmptyAndNullRows() throws {
        let db = try ledger([
            ("income", "2025-03-01", 900, 900, "unpaid", nil),
            ("income", "2025-03-01", 900, 900, "", nil),
            ("income", "2025-03-01", 1, 1, "paid", nil),
        ])
        // The NULL-status row is inserted separately, since the helper writes ''.
        try db.execute("""
            INSERT INTO transactions VALUES ('tn', 'income', '2025-03-01', 900, 900, NULL, NULL)
            """)
        let rows = try ReportFetch.cashflowRows(db, from: "2025-01-01", to: "2025-12-31")
        XCTAssertEqual(rows.count, 1, "only the 'paid' row survives the SQL gate")
        XCTAssertEqual(Cashflow.operating(rows: rows).inflow, 1,
                       "900 x 3 of unpaid money must not appear as cash")
    }

    /// `COALESCE(payment_date, date)`: a row with no payment date is windowed by
    /// its transaction date, and a row paid outside the period is excluded even
    /// though it is dated inside it.
    ///
    ///     row dated 2025-06-25, paid 2025-07-02
    ///       period Q2 (…06-30) => inflow 0
    ///       period 2025 full   => inflow 100
    func testCashIsWindowedByPaymentDateFallingBackToTransactionDate() throws {
        let db = try ledger([("income", "2025-06-25", 100, 100, "paid", "2025-07-02")])
        let q2 = try ReportFetch.cashflowRows(db, from: "2025-04-01", to: "2025-06-30")
        XCTAssertEqual(Cashflow.operating(rows: q2).inflow, 0,
                       "dated inside Q2 but PAID after it — cash-basis excludes it")
        let year = try ReportFetch.cashflowRows(db, from: "2025-01-01", to: "2025-12-31")
        XCTAssertEqual(Cashflow.operating(rows: year).inflow, 100)

        // The fallback half: no payment_date at all → windowed by `date`.
        let db2 = try ledger([("income", "2025-03-01", 100, 100, "paid", nil)])
        let rows = try ReportFetch.cashflowRows(db2, from: "2025-01-01", to: "2025-12-31")
        XCTAssertEqual(Cashflow.operating(rows: rows).inflow, 100)
    }

    /// The source decision counts on plain `date` while the rows are selected on
    /// `COALESCE(payment_date, date)` — two different windows over one table
    /// (`_cashflow.js:43` vs `:56-57`).
    ///
    /// Mirrored, not reconciled: a period can be judged "has transactions" by one
    /// rule and yield no cash rows under the other. Registered as an Appendix-A
    /// candidate rather than fixed here.
    func testTheSourceWindowAndTheCashWindowAreDifferent() throws {
        let db = try ledger([("income", "2025-06-25", 100, 100, "paid", "2026-01-05")])
        // Judged by `date`: the row is inside 2025, so the period has transactions.
        XCTAssertEqual(try ReportFetch.periodTransactionCount(db, from: "2025-01-01", to: "2025-12-31"), 1)
        // Judged by the cash window: it was paid in 2026, so no cash moved in 2025.
        let rows = try ReportFetch.cashflowRows(db, from: "2025-01-01", to: "2025-12-31")
        XCTAssertEqual(rows.count, 0)
        XCTAssertEqual(Cashflow.operating(rows: rows).net, 0)
    }

    // MARK: - tax-inclusive summary

    private func ctx(income: [ReportRow], expense: [ReportRow], year: String = "2025",
                     from: String = "2025-01-01", to: String = "2025-12-31") -> ReportContext {
        // Batch 2 reads no tax rate (plan §2); `.notConfigured` is the strictest
        // filler — a batch that started reading one would produce nothing rather
        // than quietly pricing at some default.
        ReportContext(incomeRows: income, expenseRows: expense, categories: [],
                      adminExpense: 0, incomeTaxRate: .notConfigured,
                      currency: "X", year: year, from: from, to: to)
    }

    /// `difference` is `r(income - expense)`, rounded ONCE.
    ///
    ///     …income 0.145, expense 0.005 => {purchaseTotal 0.01, salesTotal 0.14, difference 0.14}
    ///
    /// `r(income) - r(expense)` gives 0.13 — a cent out, and again inside eps.
    func testDifferenceIsRoundedOnceNotTwice() {
        let c = ctx(income: [ReportRow(amountNet: 0.145, amount: 0.145, date: "2025-03-01")],
                    expense: [ReportRow(amountNet: 0.005, amount: 0.005, date: "2025-03-01")])
        for tis in [CNReportEngine.taxInclusiveSummary(c), JPReportEngine.taxInclusiveSummary(c),
                    EUReportEngine.taxInclusiveSummary(c), KRReportEngine.taxInclusiveSummary(c),
                    TWReportEngine.taxInclusiveSummary(c)] {
            XCTAssertEqual(tis.salesTotal, 0.14)
            XCTAssertEqual(tis.purchaseTotal, 0.01)
            XCTAssertEqual(tis.difference, 0.14, "NOT 0.13")
        }
    }

    /// The tax-inclusive summary sums `amount`, NOT `amount_net || amount || 0`.
    /// A row with a net amount of 100 and a gross of 113 contributes 113 here and
    /// 100 to the P&L.
    func testTaxInclusiveSummaryUsesTheGrossAmount() {
        let c = ctx(income: [ReportRow(amountNet: 100, amount: 113, date: "2025-03-01")], expense: [])
        XCTAssertEqual(CNReportEngine.taxInclusiveSummary(c).salesTotal, 113)
        XCTAssertEqual(CNReportEngine.batchOne(c).salesRevenue, 100, "the P&L uses the NET amount")
    }

    /// Recorded as NOT behavioural. China's `round2` and the others'
    /// `round2OrZero` cannot be distinguished through a tax-inclusive sum, because
    /// `cn.js:18` already guards each term with `(r.amount || 0)` — so a NaN
    /// contributes 0 and never reaches the rounder.
    ///
    ///     …incomeRows:[{amount:NaN}] => CN {0,0,0} AND JP {0,0,0}
    ///
    /// The correct function is still used, because the source says so. This test
    /// exists so nobody later "discovers" the mutation is undetectable and
    /// concludes the distinction was imaginary — it is real in `cn.js:43`, it is
    /// simply out of reach from here.
    func testTheRounderAsymmetryIsUnreachableFromTaxInclusiveSums() {
        let c = ctx(income: [ReportRow(amountNet: 0, amount: .nan, date: "2025-03-01")], expense: [])
        XCTAssertEqual(CNReportEngine.taxInclusiveSummary(c).salesTotal, 0)
        XCTAssertEqual(JPReportEngine.taxInclusiveSummary(c).salesTotal, 0)
        // Where the asymmetry IS reachable, R2 already pins it:
        XCTAssertTrue(ReportMath.round2(.nan).isNaN)
        XCTAssertEqual(ReportMath.round2OrZero(.nan), 0)
    }

    // MARK: - monthly breakdown

    /// The US sums the TAX-INCLUSIVE amount where the other five sum the net one.
    /// The same ledger therefore produces different monthly revenue under the US
    /// regime than under any other.
    func testUSMonthlyUsesGrossWhereTheOthersUseNet() {
        let c = ctx(income: [ReportRow(amountNet: 100, amount: 113, date: "2025-03-01")], expense: [])
        XCTAssertEqual(USReportEngine.monthlyBreakdown(c)[2].revenue, 113)
        XCTAssertEqual(CNReportEngine.monthlyBreakdown(c)[2].revenue, 100)
        XCTAssertEqual(JPReportEngine.monthlyBreakdown(c)[2].revenue, 100)
    }

    /// Appendix A9's negative half, which no golden covers: a row inside
    /// `[from, to]` but OUTSIDE `ctx.year` is counted in the period totals and
    /// appears in NO month. The months therefore need not sum to the statement.
    ///
    ///     year 2025, period 2024-07-01…2025-06-30, one row dated 2024-08-15
    ///     => salesRevenue 777, Σ monthlyBreakdown.revenue 0
    func testARowInsideThePeriodButOutsideTheYearAppearsInNoMonth() {
        let c = ctx(income: [ReportRow(amountNet: 777, amount: 777, date: "2024-08-15")],
                    expense: [], year: "2025", from: "2024-07-01", to: "2025-06-30")
        XCTAssertEqual(CNReportEngine.batchOne(c).salesRevenue, 777, "counted in the totals")
        let months = CNReportEngine.monthlyBreakdown(c)
        XCTAssertEqual(months.count, 12)
        XCTAssertEqual(months.reduce(0) { $0 + $1.revenue }, 0, "and in no month at all")
    }

    /// Always twelve entries, even for a one-month period, and an empty period
    /// still yields twelve zero rows starting at month 1.
    func testTwelveMonthsAlways() {
        let quarter = ctx(income: [], expense: [], year: "2025",
                          from: "2025-04-01", to: "2025-06-30")
        for months in [CNReportEngine.monthlyBreakdown(quarter),
                       JPReportEngine.monthlyBreakdown(quarter),
                       USReportEngine.monthlyBreakdown(quarter)] {
            XCTAssertEqual(months.count, 12)
            XCTAssertEqual(months[0], ReportMonth(month: 1, revenue: 0, cost: 0, profit: 0))
            XCTAssertEqual(months.map(\.month), Array(1...12))
        }
    }

    /// Recorded as NOT behavioural: the two date spellings agree on every input
    /// reachable here. Measured, not assumed — an empty-string date is excluded by
    /// both, a null date by both.
    func testTheTwoDateSpellingsAgree() {
        for date: String? in [nil, "", "2025-03-01", "2025-03-01T00:00:00", "2024-03-01"] {
            XCTAssertEqual(MonthMatch.cn(date, "2025-03"),
                           MonthMatch.optionalChained(date, "2025-03"),
                           "date \(String(describing: date))")
        }
        let c = ctx(income: [ReportRow(amountNet: 100, amount: 100, date: "")], expense: [])
        XCTAssertEqual(CNReportEngine.monthlyBreakdown(c)[0].revenue, 0)
        XCTAssertEqual(JPReportEngine.monthlyBreakdown(c)[0].revenue, 0)
    }

    /// The month match is a STRING PREFIX, not a date comparison — which is why a
    /// timestamped date still lands in its month.
    func testMonthMatchingIsALexicographicPrefix() {
        let c = ctx(income: [ReportRow(amountNet: 50, amount: 50, date: "2025-06-15T00:00:00")],
                    expense: [])
        XCTAssertEqual(CNReportEngine.monthlyBreakdown(c)[5].revenue, 50, "June")
        XCTAssertEqual(CNReportEngine.monthlyBreakdown(c)[4].revenue, 0, "not May")
    }
}
