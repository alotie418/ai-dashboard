// Report data-source selector (PURE — no db, unit-testable without sqlite).
//
// Decides whether a report PERIOD reads the new `transactions` table or falls
// back to the legacy `sales`/`purchases` tables.
//
// Fix: the choice must be made PER REPORT PERIOD [from,to], not from a whole-table
// `SELECT COUNT(*) FROM transactions`. The old global count meant a single
// transaction in any year forced EVERY year to the transactions model, so a year
// that only has legacy sales/purchases would wrongly report 0 instead of falling
// back. Here we pass the count of transactions WITHIN the current period.
//
//   periodTxnCount > 0  → 'transactions'   (this period has its own transactions)
//   otherwise           → 'legacy'         (fall back to sales/purchases)

function selectReportSource({ hasTransactionsTable, periodTxnCount }) {
  if (hasTransactionsTable && periodTxnCount > 0) return 'transactions';
  return 'legacy';
}

module.exports = { selectReportSource };
