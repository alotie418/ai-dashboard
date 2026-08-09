import Foundation

/// Mirror of `electron/reports/_expenseSplit.js` — partition expense rows into
/// COGS and operating expenses.
///
/// Verbatim, including the accumulation ORDER and the subtraction. Both matter in
/// binary64 and neither is a style choice.
enum ExpenseSplit {

    struct Result: Equatable, Sendable {
        let totalExpenseNet: Double
        let cogsNet: Double
        let operatingExpensesNet: Double
    }

    /// `isCogsRow` — `_expenseSplit.js isCogsRow`.
    ///
    /// Three steps, in this order: a missing `category_id` is not COGS; the
    /// category is found by the FIRST id match (`find`, strict `===`); the found
    /// row's `is_cogs` is read through JS truthiness. A `category_id` that matches
    /// nothing yields `undefined` and therefore false — which is what happens to a
    /// row whose category belongs to a different locale, because `index.js generate`
    /// fetches categories `WHERE locale = ?`. That row silently becomes an
    /// operating expense. Mirrored, not repaired (plan Appendix A: 类别在切换记账
    /// 制度后被"孤立").
    static func isCogsRow(_ row: ReportRow, _ categories: [ReportCategory]) -> Bool {
        guard let categoryID = row.categoryID else { return false }
        guard let category = categories.first(where: { $0.id == categoryID }) else { return false }
        return category.isCogsTruthy
    }

    /// `net(row)` — `_expenseSplit.js net`, i.e. `amount_net || amount || 0`.
    ///
    /// `ReportMath.netAmount` is the exact match. `??` is NOT: a row whose
    /// `amount_net` is exactly 0 falls back to the TAX-INCLUSIVE `amount` in JS,
    /// and the fixture carries such a row on purpose.
    static func net(_ row: ReportRow) -> Double {
        ReportMath.netAmount(row.amountNet, row.amount)
    }

    /// `splitExpenses` — `_expenseSplit.js splitExpenses`.
    ///
    /// TWO separate left-to-right accumulations over the rows in SQL order, then a
    /// SUBTRACTION. Not one pass with two accumulators, and above all not a second
    /// sum over the non-COGS rows:
    ///
    /// > `operatingExpensesNet = totalExpenseNet - cogsNet`
    ///
    /// The source comment calls `cogsNet + operatingExpensesNet === totalExpenseNet`
    /// an invariant, and in exact arithmetic it is. In binary64 it is not: summing
    /// the non-COGS rows directly disagrees with the subtraction on roughly 7% of
    /// random money-shaped multisets (measured: 14034 of 200000).
    ///
    /// HOW MUCH that matters, stated honestly: at the batch-1 EMITTED fields it has
    /// never been observed to matter at all. Both spellings go through
    /// `Math.round(v * 100) / 100`, and across 2,000,000 random money-shaped cases
    /// the rounded `operatingExpenses` and `operatingProfit` were identical every
    /// single time. So this is not a rule some golden is quietly enforcing — a test
    /// that claimed otherwise would be theatre, and `ExpenseSplitTests` pins the RAW
    /// values instead, where the difference is real.
    ///
    /// It is still a subtraction, for two reasons that do not depend on being
    /// caught: it is what the source does, which is the entire standard for this
    /// phase; and later batches consume the UNROUNDED value down a longer chain
    /// (`cn.js profitBeforeTax` → `incomeTax` → `netProfit`), where nothing guarantees the difference keeps
    /// washing out.
    ///
    /// Addition is not associative in binary64 either, so the row order is part of
    /// the answer: `ORDER BY date` in `index.js generate` is what fixes it.
    static func splitExpenses(_ expenseRows: [ReportRow]?,
                                     _ categories: [ReportCategory]) -> Result {
        let rows = expenseRows ?? []          // `expenseRows || []` (line 28)
        var totalExpenseNet = 0.0
        for row in rows { totalExpenseNet += net(row) }
        var cogsNet = 0.0
        for row in rows where isCogsRow(row, categories) { cogsNet += net(row) }
        return Result(totalExpenseNet: totalExpenseNet,
                      cogsNet: cogsNet,
                      operatingExpensesNet: totalExpenseNet - cogsNet)
    }
}
