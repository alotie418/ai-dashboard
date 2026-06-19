#!/usr/bin/env node
// Cash-flow operating MVP — pure unit test (no sqlite, runs under plain node).
// Pins the trickiest rule: the per-transactions-row realized cash amount
// (paid_amount wins when > 0; a fully-'paid' row falls back to its full amount;
// a 'partial' row with no paid_amount contributes 0). The SQL date filtering and
// legacy SUM run against the real DB and are covered in CI / manual reconciliation.

import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const require = createRequire(import.meta.url);
const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const { txnCashAmount } = require(join(ROOT, 'electron/reports/_cashflow.js'));

const failures = [];
const eq = (got, want, msg) => { if (got !== want) failures.push(`${msg} — got ${got}, want ${want}`); };

// paid_amount > 0 always wins (the recorded cash actually moved).
eq(txnCashAmount({ payment_status: 'paid', paid_amount: 80, amount: 100 }), 80, 'paid + paid_amount=80 → 80');
eq(txnCashAmount({ payment_status: 'partial', paid_amount: 30, amount: 100 }), 30, 'partial + paid_amount=30 → 30');

// paid (fully) but paid_amount empty/0 → fall back to full amount (transactions default quirk).
eq(txnCashAmount({ payment_status: 'paid', paid_amount: 0, amount: 100 }), 100, 'paid + paid_amount=0 → amount 100');
eq(txnCashAmount({ payment_status: 'paid', amount: 100 }), 100, 'paid + no paid_amount → amount 100');

// partial with no paid_amount → 0 (no realized cash known).
eq(txnCashAmount({ payment_status: 'partial', paid_amount: 0, amount: 100 }), 0, 'partial + paid_amount=0 → 0');
eq(txnCashAmount({ payment_status: 'partial', amount: 100 }), 0, 'partial + no paid_amount → 0');

// defensive: missing amount → 0, null row → 0.
eq(txnCashAmount({ payment_status: 'paid' }), 0, 'paid + no amount → 0');
eq(txnCashAmount(null), 0, 'null row → 0');

console.log('\n=== Cash-flow operating MVP — txnCashAmount rule ===\n');
console.log(`Failures: ${failures.length}\n`);
if (failures.length) {
  for (const f of failures) console.error('  ✗ ' + f);
  console.error('');
  process.exit(1);
}
console.log('✓ all cash-amount cases passed');
