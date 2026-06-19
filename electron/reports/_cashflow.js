// Cash-flow statement — OPERATING activities MVP (additive; PR-7C).
//
// Management-basis, CASH-basis (收付实现制) operating cash flow. This is NOT a
// statutory cash-flow statement: only operating activities are derived from
// actually-recorded payments; investing / financing / beginning / ending cash are
// returned as null ("not configured") because the data model has no cash accounts,
// fixed-asset register, liabilities or opening balances. The UI must render those
// nulls as "未配置 / 不适用", never as 0.
//
// It does NOT touch the P&L / VAT / Schedule C engines or their formulas — it only
// aggregates existing payment columns by their payment date. No schema change.
//
// Source mirrors the P&L (selectReportSource): if the period has its own
// transactions, cash comes from `transactions`; otherwise from legacy
// `sales`/`purchases`.
//
// Cash rules (per PR-7C confirmation):
//   • sales/purchases: count paid_amount of rows whose payment_status is
//     'paid'/'partial' AND whose payment_date falls within [from,to].
//   • transactions: cash date = payment_date || date; cash amount =
//     paid_amount when > 0, else `amount` when payment_status='paid'; only
//     'paid'/'partial' rows count. Unpaid records never count (no cash moved yet).

const { selectReportSource } = require('./_reportSource');

const round2 = (n) => Math.round((Number(n) || 0) * 100) / 100;

// Pure (sqlite-free, unit-testable): realized cash for a transactions-source row that
// is already known to be 'paid'/'partial'. paid_amount wins when > 0; otherwise a fully
// 'paid' row falls back to its full `amount`, a 'partial' row with no paid_amount → 0.
function txnCashAmount(row) {
  if (row && row.paid_amount && row.paid_amount > 0) return row.paid_amount;
  return row && row.payment_status === 'paid' ? (row.amount || 0) : 0;
}

function tableExists(db, name) {
  return !!db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name=?").get(name);
}

function computeOperatingCashflow(db, { from, to }) {
  const hasTransactionsTable = tableExists(db, 'transactions');
  const periodTxnCount = hasTransactionsTable
    ? db.prepare('SELECT COUNT(*) AS c FROM transactions WHERE date >= ? AND date <= ?').get(from, to).c
    : 0;
  const source = selectReportSource({ hasTransactionsTable, periodTxnCount });

  let inflow = 0;
  let outflow = 0;

  if (source === 'transactions') {
    // Cash date = payment_date || date; only realized (paid/partial) rows count.
    const rows = db.prepare(
      `SELECT type, amount, paid_amount, payment_status
         FROM transactions
        WHERE payment_status IN ('paid','partial')
          AND COALESCE(payment_date, date) >= ?
          AND COALESCE(payment_date, date) <= ?`
    ).all(from, to);
    for (const r of rows) {
      const cashAmt = txnCashAmount(r);
      if (cashAmt <= 0) continue;
      if (r.type === 'income') inflow += cashAmt;
      else if (r.type === 'expense') outflow += cashAmt;
    }
  } else {
    // Legacy: sum paid_amount of sales/purchases paid (or partially paid) within the period.
    if (tableExists(db, 'sales')) {
      inflow = db.prepare(
        `SELECT COALESCE(SUM(paid_amount), 0) AS s FROM sales
          WHERE payment_status IN ('paid','partial')
            AND payment_date IS NOT NULL AND payment_date >= ? AND payment_date <= ?`
      ).get(from, to).s || 0;
    }
    if (tableExists(db, 'purchases')) {
      outflow = db.prepare(
        `SELECT COALESCE(SUM(paid_amount), 0) AS s FROM purchases
          WHERE payment_status IN ('paid','partial')
            AND payment_date IS NOT NULL AND payment_date >= ? AND payment_date <= ?`
      ).get(from, to).s || 0;
    }
  }

  return {
    basis: 'cash',            // 收付实现制 (management basis)
    statutory: false,         // NOT a statutory cash-flow statement
    source,                   // 'transactions' | 'legacy'
    operating: {
      inflow: round2(inflow),
      outflow: round2(outflow),
      net: round2(inflow - outflow),
    },
    // Not derivable from the current data model → UI shows "未配置 / 不适用" (never 0).
    investing: null,
    financing: null,
    beginningCash: null,
    endingCash: null,
  };
}

module.exports = { computeOperatingCashflow, txnCashAmount };
