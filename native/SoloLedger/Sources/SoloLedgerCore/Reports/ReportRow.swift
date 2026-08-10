import Foundation

/// The row shape the batch-1 report engines read.
///
/// Deliberately NOT the app's `Transaction` model. The engines are being mirrored
/// from `electron/reports/*.js`, where the rows are whatever `SELECT *` handed
/// back — so what matters is which COLUMNS the formulas touch and how JavaScript
/// treats them when they are absent. Reusing the app model would quietly supply
/// defaults the engines never had.
///
/// Only the columns batches 1–4 read are carried.
///
/// `date` was absent in batch 1 — the period filter happens in SQL
/// (`index.js generate`), so the engines never needed it. Batch 2 changed that:
/// `monthlyBreakdown` re-filters the SAME rows by month IN SWIFT (`cn.js mIncome`,
/// `jp.js revenue`, `us.js income`), against a prefix built from `ctx.year`. So the column
/// is now read twice for two different purposes, and the second one is the reason
/// Appendix A9 exists — see ``ReportMonth``.
struct ReportRow: Equatable, Sendable {
    /// `amount_net` — the pre-tax amount. Optional because SQL NULL is a real
    /// value here, and because `ReportMath.netAmount` needs to see the difference
    /// between "absent" and "0" (JS treats both as falsy, but only after the
    /// column has been read).
    let amountNet: Double?
    /// `amount` — the tax-inclusive amount.
    let amount: Double?
    /// `tax_amount` — the tax carried on the row, read by batch 4 alone.
    ///
    /// The turnover-tax blocks are the ONLY place this column is used, and they use
    /// it through `(row.tax_amount || 0)` (`cn.js totalIncomeTax` / `totalExpenseTax` and the same pair in
    /// jp/eu/kr/tw). That guard is why a NaN here contributes 0 rather than
    /// poisoning the sum — so China's unguarded rounder (`cn.js generate`) cannot emit
    /// `null` from this path, even though it can from others. Measured in node: a
    /// `NaN` tax on one row of two yields the other row's tax, under every engine.
    ///
    /// Optional for the same reason as ``amountNet``: SQL NULL and a real 0 are
    /// different values, and only `ReportMath.orZero` may collapse them.
    let taxAmount: Double?
    /// `category_id`.
    ///
    /// SQL NULL and "this query never selected the column" collapse to the SAME
    /// `nil`, on purpose. `_expenseSplit.js isCogsRow` tests `row.category_id == null`
    /// with LOOSE equality, which is true for JS `null` AND `undefined` — and the
    /// legacy query (`index.js generate`) selects 24 columns, none of them
    /// `category_id`, so every legacy row hits the `undefined` side. That is the
    /// mechanism behind the quirk that COGS is structurally 0 on every legacy
    /// period, and it is preserved rather than repaired.
    let categoryID: String?
    /// `shippingCost` — legacy `sales` only.
    ///
    /// The `transactions` table HAS NO SUCH COLUMN (verified against the fixture
    /// schema), so on the transactions path this is always nil and China's
    /// shipping deduction at `cn.js totalShipping` is structurally 0. Mirrored, not fixed —
    /// plan Appendix A4 records the correction as needing a schema decision.
    let shippingCost: Double?
    /// `date`, as STORED — never parsed.
    ///
    /// `monthlyBreakdown` matches it with a string prefix (`"\(year)-\(mm)"`), not
    /// with a date comparison, so a row stamped `2025-06-15T00:00:00` matches
    /// `2025-06` for exactly the reason a lexicographic prefix does. Parsing it
    /// into a `Date` here would introduce a time zone the engines do not have.
    let date: String?

    init(amountNet: Double? = nil, amount: Double? = nil,
                taxAmount: Double? = nil, categoryID: String? = nil,
                shippingCost: Double? = nil, date: String? = nil) {
        self.amountNet = amountNet
        self.amount = amount
        self.taxAmount = taxAmount
        self.categoryID = categoryID
        self.shippingCost = shippingCost
        self.date = date
    }
}

/// A category row, as the COGS split sees it.
struct ReportCategory: Equatable, Sendable {
    let id: String
    /// `is_cogs`, kept in its RAW SQLite storage class rather than as a `Bool`.
    ///
    /// `index.js generate` fetches categories with `SELECT *`, so the value reaching
    /// `_expenseSplit.js isCogsRow` is whatever better-sqlite3 returns for the stored
    /// cell — it does NOT pass through the `is_cogs: !!r.is_cogs` coercion in
    /// `electron/handlers/categories.js is_cogs`, which is a different code path.
    /// Decoding to `Bool` here would silently pick one interpretation; keeping the
    /// storage class lets ``isCogsTruthy`` apply JS's `!!` to the same value the
    /// engine sees.
    let isCogs: SQLiteValue

    /// `slug`, also in its RAW storage class and for the same reason: `index.js generate`
    /// is `SELECT *`, so the value reaching `us.js`'s category lookups is whatever
    /// the cell holds, not a decoded `String`.
    ///
    /// Batch 3 uses it in TWO different ways, and they are not the same rule:
    /// the income side compares it with `===` against a literal
    /// (`us.js matchCategory`), while the expense side uses it as an OBJECT KEY
    /// (`us.js slug`) after a `|| 'other'` fallback. See ``slugKeyOrOther`` and
    /// ``slugEquals(_:)``.
    let slug: SQLiteValue

    init(id: String, isCogs: SQLiteValue, slug: SQLiteValue = .null) {
        self.id = id
        self.isCogs = isCogs
        self.slug = slug
    }

    /// `cat.slug === literal` — the INCOME side (`us.js matchCategory`).
    ///
    /// Strict equality against a string literal, so only a TEXT cell can ever
    /// match: a numeric or null slug is simply not equal to `"returns"`.
    func slugEquals(_ literal: String) -> Bool {
        if case .text(let s) = slug { return s == literal }
        return false
    }

    /// `findCategorySlug(row, categories) || 'other'` — the EXPENSE side
    /// (`us.js slug`), as the object key it becomes at `us.js generate`.
    ///
    /// The `|| 'other'` is JS truthiness on the slug value, so an empty string and
    /// a null slug BOTH fall to `other` and land on line 27a — the same bucket as a
    /// row with no category at all. Three different situations, one line.
    ///
    /// A slug that is a real string but not one Schedule C maps (say `cogs`, from
    /// another regime's category table) becomes a key nothing reads, and the money
    /// **disappears from the report entirely** — it is in no line, so it is also
    /// not in line 28. That is the source's behaviour, mirrored, and it is pinned
    /// by a test rather than left to be discovered.
    ///
    /// Non-TEXT slugs are unreachable in practice (the column is TEXT) and are
    /// mapped to a key nothing reads, which is what a stringified number would do
    /// anyway.
    var slugKeyOrOther: String {
        if case .text(let s) = slug, !s.isEmpty { return s }
        if case .integer(let i) = slug, i != 0 { return String(i) }
        if case .real(let d) = slug, !(d == 0 || d.isNaN) { return String(d) }
        return "other"
    }

    /// JS `!!value` over a SQLite storage class — the `!!(cat && cat.is_cogs)`
    /// at `_expenseSplit.js isCogsRow`.
    ///
    /// Defensive rather than load-bearing today: every `is_cogs` cell in the
    /// fixture is `typeof = integer`, and `categories.js` writes `is_cogs ? 1 : 0`
    /// at each of its three write sites. But `SELECT *` imposes no affinity of its
    /// own, so the rule is written out for the values that COULD arrive rather
    /// than for the ones that do.
    var isCogsTruthy: Bool {
        switch isCogs {
        case .null:            return false
        case .integer(let i):  return i != 0
        case .real(let d):     return !(d == 0 || d.isNaN)   // JS: 0, -0 and NaN are falsy
        case .text(let s):     return !s.isEmpty             // JS: only "" is falsy
        case .blob:            return true                   // any object is truthy
        }
    }
}
