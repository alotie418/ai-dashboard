import Foundation

/// Row reads for the report engines.
///
/// ## Why this exists instead of `LedgerStore.listTransactions`
///
/// `listTransactions` takes `limit: Int = 500`, clamps it to 5000, and splices
/// `LIMIT` into the SQL — returning no signal that it did. On a ledger past that
/// size a report built on it would print a total that is confidently, silently
/// wrong. That is the same failure as Appendix A1 (same-period legacy rows
/// excluded without saying so), and plan §8.2 requires a period-scoped, UNCAPPED
/// read for reports instead.
///
/// **There is no `LIMIT` anywhere in this file, and that is enforced rather than
/// intended** — `ReportFetchTests` asserts the emitted SQL contains none, so a
/// future "optimization" that reintroduces a cap fails the build instead of
/// quietly truncating a balance sheet.
///
/// ## Uncapped is also the cheap option, because the projection is narrow
///
/// The cost that makes people reach for a cap is not the row count, it is
/// `SELECT *`: every column is boxed into a `SQLiteValue` and every row into a
/// dictionary. Measured on release/arm64, a two-query period fetch costs roughly
/// 2 KB of resident memory per row under `SELECT *` (about 1.9 GB at a million
/// rows) against a small fraction of that when only the five columns the engines
/// read are selected. At sizes a real ledger reaches — 100 orders a day for a
/// year is on the order of 10^5 rows — the narrow fetch is tens of milliseconds.
///
/// So the honest option and the fast option are the same one, and no trade-off
/// between them had to be made. If that ever stops being true, the answer is a
/// disclosed incompleteness flag, never a silent cap.
enum ReportFetch {

    /// The P&L / monthly projection: exactly the columns the engines read.
    ///
    /// `ReportRow` documents which those are; adding a column here without adding
    /// it there would silently widen the read for nothing.
    static let rowColumns = "amount_net, amount, tax_amount, category_id, date"

    /// `index.js:47-52` — income and expense rows for the period.
    ///
    /// `ORDER BY date` is part of the answer, not a nicety: floating-point
    /// addition is not associative, so the accumulation order changes the last
    /// cent. Bounds bind as TEXT because the column is TEXT and the comparison is
    /// lexicographic — which is why a row stamped `2025-06-15T00:00:00` still
    /// falls inside a `2025-06-01`…`2025-06-30` window.
    static func rowSQL(type: String) -> String {
        "SELECT \(rowColumns) FROM transactions WHERE type = '\(type)' " +
        "AND date >= ? AND date <= ? ORDER BY date"
    }

    /// `_cashflow.js:52-58` — realized-cash rows.
    ///
    /// A DIFFERENT window over the same table: rows are selected by
    /// `COALESCE(payment_date, date)` here, while the source decision counts on
    /// plain `date` (`_cashflow.js:43`). The two disagree for a row dated inside
    /// the period but paid outside it, or vice versa. That inconsistency is in the
    /// source and is mirrored, not repaired.
    ///
    /// No `ORDER BY`: the JS has none, and the accumulation is over a filtered set
    /// whose order SQLite chooses. Adding one would be a behaviour change dressed
    /// as tidiness.
    static let cashflowSQL = """
        SELECT type, amount, paid_amount, payment_status
           FROM transactions
          WHERE payment_status IN ('paid','partial')
            AND COALESCE(payment_date, date) >= ?
            AND COALESCE(payment_date, date) <= ?
        """

    /// `index.js:43` — how many transactions fall in the period, which decides the
    /// source. Counted on `date`, NOT on the cash date.
    static func periodTransactionCount(_ db: SQLiteDatabase,
                                              from: String, to: String) throws -> Int {
        try db.query("SELECT COUNT(*) AS c FROM transactions WHERE date >= ? AND date <= ?",
                     [.text(from), .text(to)]).first?.int("c") ?? 0
    }

    static func hasTransactionsTable(_ db: SQLiteDatabase) throws -> Bool {
        !(try db.query(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='transactions'")).isEmpty
    }

    static func rows(_ db: SQLiteDatabase, type: String,
                            from: String, to: String) throws -> [ReportRow] {
        try db.query(rowSQL(type: type), [.text(from), .text(to)]).map {
            ReportRow(amountNet: $0.double("amount_net"),
                      amount: $0.double("amount"),
                      // Batch 4's only new column. The turnover-tax blocks read it
                      // and nothing else does.
                      taxAmount: $0.double("tax_amount"),
                      categoryID: $0.string("category_id"),
                      // The transactions table has no shippingCost column, which is
                      // why China's shipping deduction is structurally 0 here.
                      shippingCost: nil,
                      date: $0.string("date"))
        }
    }

    static func cashflowRows(_ db: SQLiteDatabase,
                                    from: String, to: String) throws -> [CashflowRow] {
        try db.query(cashflowSQL, [.text(from), .text(to)]).map {
            CashflowRow(type: $0.string("type"),
                        amount: $0.double("amount"),
                        paidAmount: $0.double("paid_amount"),
                        paymentStatus: $0.string("payment_status"))
        }
    }

    /// `index.js:68-71` — categories for the regime.
    ///
    /// `WHERE locale = ?` is why a row whose category belongs to another regime
    /// matches nothing and falls to operating expenses. The whole read is wrapped
    /// in a swallowing catch upstream because the table may not exist.
    static func categories(_ db: SQLiteDatabase, locale: String) throws -> [ReportCategory] {
        try db.query("SELECT * FROM categories WHERE locale = ? ORDER BY type, sort_order",
                     [.text(locale)]).map {
            ReportCategory(id: $0.string("id") ?? "", isCogs: $0["is_cogs"], slug: $0["slug"])
        }
    }
}
