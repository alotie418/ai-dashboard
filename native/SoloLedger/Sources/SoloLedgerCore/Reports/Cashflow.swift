import Foundation

/// Mirror of `electron/reports/_cashflow.js` — the operating-activities block.
///
/// Management-basis, CASH-basis. NOT a statutory cash-flow statement: only
/// operating activities are derived, from payments actually recorded. Investing,
/// financing, beginning and ending cash are not derivable from this data model at
/// all — there are no cash accounts, no fixed-asset register, no liabilities and
/// no opening balances.

/// A section that can never carry a number.
///
/// `_cashflow.js:92-96` returns `null` for investing / financing / beginningCash /
/// endingCash, and `:5-8` states the obligation this creates: *the UI must render
/// those nulls as "未配置 / 不适用", never as 0.*
///
/// That obligation is carried by a zero-payload enum rather than by `Double?`,
/// and the difference is the whole point. With `Double?`, `?? 0` is a
/// two-character edit that compiles, and NO test can catch it: a golden can
/// observe the model, never a view rendering 0 from a model that said nil. With
/// this type there is no `Double` to reach for — the compiler refuses instead of
/// a reviewer having to notice.
///
/// Deliberately no `case amount(Double)`. Adding one "for later" would restore
/// exactly the reachable-zero this exists to remove.
enum CashflowSection: Equatable, Sendable {
    case notConfigured
}

/// Realized operating cash for a period.
struct OperatingCashflow: Equatable, Sendable {
    let inflow: Double
    let outflow: Double
    let net: Double

    init(inflow: Double, outflow: Double, net: Double) {
        self.inflow = inflow
        self.outflow = outflow
        self.net = net
    }
}

/// Operating cash flow, which — unlike the four sections above — is *sometimes*
/// derivable.
///
/// `.notConfigured` here means something narrower and more specific than it does
/// for investing or financing: **this period has no transactions, and the native
/// app does not read the legacy tables** (plan §6.1, per #395). Electron, reading
/// those tables, reports real money for such a period — `base-CN-2024` records
/// inflow 9040 / outflow 7780 / net 1260 — so emitting `{0, 0, 0}` would not be
/// "no data", it would be a confident and WRONG statement that no cash moved.
///
/// CLAUDE.md's product boundary forbids exactly that ("Do not show placeholder
/// values as if they are official financial metrics"), and the honest answer is
/// not a smaller number but a different KIND of answer. Making it a separate case
/// rather than a zero means the presentation layer cannot print a total here
/// even by accident — the same reasoning as `CashflowSection`, applied to a
/// condition that is per-period rather than permanent.
enum OperatingCashflowSection: Equatable, Sendable {
    case computed(OperatingCashflow)
    /// The period holds no transactions. Not "zero cash moved".
    case notConfigured
}

/// The block `index.js:90` appends to every engine's output.
struct CashflowStatement: Equatable, Sendable {
    /// `'cash'` — 收付实现制 (`_cashflow.js:84`).
    let basis: String
    /// Always `false` (`_cashflow.js:85`). Carried, not asserted away: it is the
    /// machine-readable half of the disclaimer.
    let statutory: Bool
    /// `'transactions' | 'legacy'` (`_cashflow.js:86`).
    let source: ReportSource
    let operating: OperatingCashflowSection
    let investing: CashflowSection
    let financing: CashflowSection
    let beginningCash: CashflowSection
    let endingCash: CashflowSection

    init(source: ReportSource, operating: OperatingCashflowSection) {
        self.basis = "cash"
        self.statutory = false
        self.source = source
        self.operating = operating
        self.investing = .notConfigured
        self.financing = .notConfigured
        self.beginningCash = .notConfigured
        self.endingCash = .notConfigured
    }
}

/// The four columns `_cashflow.js:53` projects.
///
/// Deliberately NOT ``ReportRow``. That type mirrors the P&L path's `SELECT *`;
/// this one mirrors a four-column projection over the same table, chosen by a
/// different window (`COALESCE(payment_date, date)` rather than `date`). Merging
/// them would hide that two different questions are being asked of one table.
///
/// No `date` and no `payment_date`: all windowing stays in SQL
/// (`_cashflow.js:56-57`), so a Swift-side date comparison cannot drift from it.
struct CashflowRow: Equatable, Sendable {
    /// `'income' | 'expense'` — and anything else is silently dropped, see
    /// ``Cashflow/operating(rows:)``.
    let type: String?
    let amount: Double?
    let paidAmount: Double?
    let paymentStatus: String?

    init(type: String?, amount: Double?, paidAmount: Double?, paymentStatus: String?) {
        self.type = type
        self.amount = amount
        self.paidAmount = paidAmount
        self.paymentStatus = paymentStatus
    }
}

enum Cashflow {

    /// `txnCashAmount` — `_cashflow.js:31-34`.
    ///
    /// ```js
    /// if (row && row.paid_amount && row.paid_amount > 0) return row.paid_amount;
    /// return row && row.payment_status === 'paid' ? (row.amount || 0) : 0;
    /// ```
    ///
    /// Two things that look redundant and are not:
    ///
    /// * `row.paid_amount && row.paid_amount > 0` tests truthiness AND positivity.
    ///   A NEGATIVE `paid_amount` is truthy, fails `> 0`, and therefore falls
    ///   through to the second line — so a `paid` row with `paid_amount = -100`
    ///   contributes its FULL `amount`, not −100 and not 0. Collapsing the two
    ///   tests into `paid_amount > 0` happens to agree; collapsing them into
    ///   truthiness alone does not.
    /// * This helper does NOT filter by status. The
    ///   `payment_status IN ('paid','partial')` exclusion lives only in the SQL
    ///   (`_cashflow.js:55`), so calling this on an `unpaid` row with a positive
    ///   `paid_amount` returns that amount. The two are separate gates and the
    ///   mirror keeps them separate.
    static func txnCashAmount(_ row: CashflowRow) -> Double {
        if ReportMath.isTruthy(row.paidAmount), row.paidAmount! > 0 { return row.paidAmount! }
        return row.paymentStatus == "paid" ? ReportMath.orZero(row.amount) : 0
    }

    /// `_cashflow.js:59-64` — the accumulation, given rows the SQL already
    /// filtered and windowed.
    ///
    /// `if (cashAmt <= 0) continue` is kept in that exact polarity. Inverting it to
    /// `> 0` looks equivalent and is not: a NaN fails BOTH comparisons, so `<= 0`
    /// lets it through to be added (poisoning the total) while `> 0` would skip it.
    ///
    /// The three-way `if / else if` is also kept: a row whose `type` is neither
    /// `income` nor `expense` is silently dropped rather than defaulting either
    /// way.
    static func operating(rows: [CashflowRow]) -> OperatingCashflow {
        var inflow = 0.0
        var outflow = 0.0
        for row in rows {
            let cashAmount = txnCashAmount(row)
            if cashAmount <= 0 { continue }
            if row.type == "income" { inflow += cashAmount }
            else if row.type == "expense" { outflow += cashAmount }
        }
        return OperatingCashflow(inflow: round2(inflow),
                                 outflow: round2(outflow),
                                 net: round2(inflow - outflow))
    }

    /// `_cashflow.js:26` — `Math.round((Number(n) || 0) * 100) / 100`.
    ///
    /// Composed from the R1 primitives so the `Number()` is not quietly dropped.
    /// At both call sites the argument is already a `Double`, so the coercion is
    /// the identity here — but it is written out because the JS is written out,
    /// and because the only inputs where `Number()` would change the answer
    /// (strings, arrays, `undefined`) are excluded by Swift's static type rather
    /// than by anything in this expression.
    static func round2(_ v: Double) -> Double {
        ReportMath.round2OrZero(ReportMath.number(.number(v)))
    }
}
