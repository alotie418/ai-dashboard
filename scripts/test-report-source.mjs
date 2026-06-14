#!/usr/bin/env node
// Report data-source selection (PURE — no sqlite, runs under plain node).
// Pins the core bug fix: the choice is made PER REPORT PERIOD, so a transaction in
// one year must NOT stop another year from falling back to legacy sales/purchases.

import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const require = createRequire(import.meta.url);
const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const { selectReportSource } = require(join(ROOT, 'electron/reports/_reportSource.js'));

const failures = [];
const ok = (cond, msg) => { if (!cond) failures.push(msg); };

// ── Bug scenario ──────────────────────────────────────────────────────────
// transactions table EXISTS and has only 2025 rows; legacy sales/purchases hold
// 2026 rows. The 2026 report's period-scoped count is 0 → it MUST pick 'legacy'
// (old whole-table COUNT(*) would have returned >0 and wrongly used transactions,
// reporting 0 revenue/cost for 2026). 2025 (which has txns) still uses transactions.
const txnDates = ['2025-03-01', '2025-09-01'];
const countInPeriod = (from, to) => txnDates.filter((d) => d >= from && d <= to).length;

ok(selectReportSource({ hasTransactionsTable: true, periodTxnCount: countInPeriod('2026-01-01', '2026-12-31') }) === 'legacy',
  '2026 (no transactions in period) must fall back to legacy');
ok(selectReportSource({ hasTransactionsTable: true, periodTxnCount: countInPeriod('2025-01-01', '2025-12-31') }) === 'transactions',
  '2025 (has transactions in period) must use transactions');

// ── Direct cases ─────────────────────────────────────────────────────────
ok(selectReportSource({ hasTransactionsTable: true, periodTxnCount: 0 }) === 'legacy', 'period count 0 → legacy');
ok(selectReportSource({ hasTransactionsTable: true, periodTxnCount: 1 }) === 'transactions', 'period count 1 → transactions');
ok(selectReportSource({ hasTransactionsTable: false, periodTxnCount: 0 }) === 'legacy', 'no transactions table → legacy');
ok(selectReportSource({ hasTransactionsTable: false, periodTxnCount: 5 }) === 'legacy', 'no table → legacy even if a (stale) count is passed');

console.log('\n=== Report Source Selection Test (per-period fallback) ===\n');
console.log(`Failures: ${failures.length}\n`);
if (failures.length) {
  for (const f of failures) console.error('  ✗ ' + f);
  console.error('');
  process.exit(1);
}
console.log('✓ Per-period source selection: a year with no transactions falls back to legacy; other years are unaffected.\n');
