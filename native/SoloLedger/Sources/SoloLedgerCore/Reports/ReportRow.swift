import Foundation

/// The row shape the batch-1 report engines read.
///
/// Deliberately NOT the app's `Transaction` model. The engines are being mirrored
/// from `electron/reports/*.js`, where the rows are whatever `SELECT *` handed
/// back — so what matters is which COLUMNS the formulas touch and how JavaScript
/// treats them when they are absent. Reusing the app model would quietly supply
/// defaults the engines never had.
///
/// Only batch-1 columns are carried. `date` is not here because the period filter
/// happens in SQL (`index.js:47-52`), and `tax_amount` is not here because the
/// turnover-tax blocks are batch 4.
public struct ReportRow: Equatable, Sendable {
    /// `amount_net` — the pre-tax amount. Optional because SQL NULL is a real
    /// value here, and because `ReportMath.netAmount` needs to see the difference
    /// between "absent" and "0" (JS treats both as falsy, but only after the
    /// column has been read).
    public let amountNet: Double?
    /// `amount` — the tax-inclusive amount.
    public let amount: Double?
    /// `category_id`.
    ///
    /// SQL NULL and "this query never selected the column" collapse to the SAME
    /// `nil`, on purpose. `_expenseSplit.js:18` tests `row.category_id == null`
    /// with LOOSE equality, which is true for JS `null` AND `undefined` — and the
    /// legacy query (`index.js:60-63`) selects 24 columns, none of them
    /// `category_id`, so every legacy row hits the `undefined` side. That is the
    /// mechanism behind the quirk that COGS is structurally 0 on every legacy
    /// period, and it is preserved rather than repaired.
    public let categoryID: String?
    /// `shippingCost` — legacy `sales` only.
    ///
    /// The `transactions` table HAS NO SUCH COLUMN (verified against the fixture
    /// schema), so on the transactions path this is always nil and China's
    /// shipping deduction at `cn.js:24` is structurally 0. Mirrored, not fixed —
    /// plan Appendix A4 records the correction as needing a schema decision.
    public let shippingCost: Double?

    public init(amountNet: Double? = nil, amount: Double? = nil,
                categoryID: String? = nil, shippingCost: Double? = nil) {
        self.amountNet = amountNet
        self.amount = amount
        self.categoryID = categoryID
        self.shippingCost = shippingCost
    }
}

/// A category row, as the COGS split sees it.
public struct ReportCategory: Equatable, Sendable {
    public let id: String
    /// `is_cogs`, kept in its RAW SQLite storage class rather than as a `Bool`.
    ///
    /// `index.js:70` fetches categories with `SELECT *`, so the value reaching
    /// `_expenseSplit.js:20` is whatever better-sqlite3 returns for the stored
    /// cell — it does NOT pass through the `is_cogs: !!r.is_cogs` coercion in
    /// `electron/handlers/categories.js:51`, which is a different code path.
    /// Decoding to `Bool` here would silently pick one interpretation; keeping the
    /// storage class lets ``isCogsTruthy`` apply JS's `!!` to the same value the
    /// engine sees.
    public let isCogs: SQLiteValue

    public init(id: String, isCogs: SQLiteValue) {
        self.id = id
        self.isCogs = isCogs
    }

    /// JS `!!value` over a SQLite storage class — the `!!(cat && cat.is_cogs)`
    /// at `_expenseSplit.js:20`.
    ///
    /// Defensive rather than load-bearing today: every `is_cogs` cell in the
    /// fixture is `typeof = integer`, and `categories.js` writes `is_cogs ? 1 : 0`
    /// at each of its three write sites. But `SELECT *` imposes no affinity of its
    /// own, so the rule is written out for the values that COULD arrive rather
    /// than for the ones that do.
    public var isCogsTruthy: Bool {
        switch isCogs {
        case .null:            return false
        case .integer(let i):  return i != 0
        case .real(let d):     return !(d == 0 || d.isNaN)   // JS: 0, -0 and NaN are falsy
        case .text(let s):     return !s.isEmpty             // JS: only "" is falsy
        case .blob:            return true                   // any object is truthy
        }
    }
}
