import XCTest
@testable import SoloLedgerCore

/// The report fetch is UNCAPPED, and this is what keeps it that way.
///
/// `LedgerStore.listTransactions` takes `limit: Int = 500`, clamps it to 5000, and
/// splices `LIMIT` into the SQL — returning no signal that it truncated. A report
/// built on it would print a confident, wrong total on any ledger past that size:
/// the same failure as Appendix A1, where same-period legacy rows are excluded
/// without saying so.
///
/// Plan §8.2 therefore requires a separate period-scoped, uncapped read for
/// reports. The tests below are the part that makes "uncapped" survive contact
/// with a future performance pass.
final class ReportFetchTests: LedgerTestCase {

    /// A ledger with more rows in one period than the cap `listTransactions` would
    /// have applied.
    private func largeLedger(rows: Int) throws -> (SQLiteDatabase, expectedSum: Double) {
        let db = try SQLiteDatabase(path: try trackedTempDir()
            .appendingPathComponent("large.db").path, mode: .readWriteCreate)
        try db.execute("""
            CREATE TABLE transactions (id TEXT, type TEXT, date TEXT, amount REAL,
              amount_net REAL, category_id TEXT, paid_amount REAL, payment_status TEXT,
              payment_date TEXT)
            """)
        try db.execute("BEGIN")
        var expected = 0.0
        for i in 0..<rows {
            // Two decimals, deterministic, spread across the year.
            let net = Double((i * 37) % 100_000) / 100
            expected += net
            let month = String(format: "%02d", (i % 12) + 1)
            try db.execute("""
                INSERT INTO transactions VALUES ('t\(i)', 'income', '2025-\(month)-15',
                  \(net), \(net), NULL, \(net), 'paid', NULL)
                """)
        }
        try db.execute("COMMIT")
        return (db, expected)
    }

    /// The read returns EVERY row in the period, not the first 500 and not the
    /// first 5000, and the totals equal what SQL says over the same predicate.
    ///
    /// 5001 rows is chosen deliberately: it is one past the ceiling
    /// `listTransactions` clamps to, so a mirror that reused it would fail here by
    /// exactly one row's worth of money rather than obviously.
    func testTheFetchReturnsEveryRowInThePeriod() throws {
        let (db, expectedSum) = try largeLedger(rows: 5001)

        let sqlCount = try XCTUnwrap(try db.query(
            "SELECT COUNT(*) AS c FROM transactions WHERE date >= ? AND date <= ?",
            [.text("2025-01-01"), .text("2025-12-31")]).first?.int("c"))
        XCTAssertEqual(sqlCount, 5001)

        let rows = try ReportFetch.rows(db, type: "income", from: "2025-01-01", to: "2025-12-31")
        XCTAssertEqual(rows.count, sqlCount, "the fetch truncated — that is the whole bug")

        // And the money agrees with SQL's own sum, so a partial read cannot pass by
        // matching a count while dropping value.
        let sqlSum = try XCTUnwrap(try db.query(
            "SELECT SUM(amount_net) AS s FROM transactions WHERE date >= ? AND date <= ?",
            [.text("2025-01-01"), .text("2025-12-31")]).first?.double("s"))
        let ctx = ReportContext(incomeRows: rows, expenseRows: [], categories: [],
                                adminExpense: 0, currency: "CNY",
                                year: "2025", from: "2025-01-01", to: "2025-12-31")
        XCTAssertEqual(CNReportEngine.taxInclusiveSummary(ctx).salesTotal,
                       ReportMath.round2(sqlSum), accuracy: 0.011,
                       "the report total must equal the ledger's own total")
        XCTAssertEqual(expectedSum, sqlSum, accuracy: 0.011)
    }

    /// The cash-flow read is uncapped too — a different SQL statement, so it needs
    /// its own assertion rather than inheriting the one above.
    func testTheCashflowFetchIsAlsoUncapped() throws {
        let (db, _) = try largeLedger(rows: 5001)
        let rows = try ReportFetch.cashflowRows(db, from: "2025-01-01", to: "2025-12-31")
        // Row 0 has amount_net 0, so its paid_amount is 0 and it is a legitimate
        // member of the SELECT even though it contributes no cash.
        XCTAssertEqual(rows.count, 5001)
    }

    /// **The guard that matters.** Every SQL statement this module emits must be
    /// free of `LIMIT`.
    ///
    /// Without it, "uncapped" is a property of today's code that a future
    /// optimization would silently remove — and the failure mode of that removal is
    /// not a crash or a slow query, it is a balance sheet that is quietly missing
    /// money. This turns it into a build-time failure instead.
    ///
    /// If a cap ever becomes genuinely necessary, the answer is a disclosed
    /// incompleteness flag that the type system will not let a view render as a
    /// total — never a silent `LIMIT`.
    func testNoReportSQLContainsALimit() {
        let statements = [
            ReportFetch.rowSQL(type: "income"),
            ReportFetch.rowSQL(type: "expense"),
            ReportFetch.cashflowSQL,
        ]
        for sql in statements {
            XCTAssertFalse(sql.uppercased().contains("LIMIT"),
                           "a report query grew a LIMIT:\n\(sql)\n\n" +
                           "Plan §8.2 requires the report read to be uncapped. A silent cap " +
                           "makes the app print a confident, wrong total.")
        }
    }

    /// The projection is narrow, which is what makes uncapped also cheap: the cost
    /// that drives people to add a cap is `SELECT *` boxing every column of every
    /// row, not the row count itself.
    func testTheProjectionIsNarrowRatherThanSelectStar() {
        for sql in [ReportFetch.rowSQL(type: "income"), ReportFetch.cashflowSQL] {
            XCTAssertFalse(sql.contains("SELECT *"), "report reads must project explicitly")
        }
        XCTAssertEqual(ReportFetch.rowColumns, "amount_net, amount, category_id, date",
                       "exactly the columns the engines read — widening this is not free")
    }

    /// `ORDER BY date` is on the P&L read and NOT on the cash-flow read, matching
    /// the source. It is not decoration: floating-point addition is not
    /// associative, so the accumulation order is part of the answer.
    func testOrderingMatchesTheSource() {
        XCTAssertTrue(ReportFetch.rowSQL(type: "income").contains("ORDER BY date"))
        XCTAssertFalse(ReportFetch.cashflowSQL.contains("ORDER BY"),
                       "_cashflow.js:52-58 has no ORDER BY; adding one is a behaviour change")
    }
}
