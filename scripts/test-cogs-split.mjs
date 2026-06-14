#!/usr/bin/env node
// COGS/operating split invariants (PR-T5 backend core). Pure-function test of the
// non-US report engines + the _expenseSplit helper — no DB, no provider.
//
// Anchors:
//   1. cogsNet + operatingExpensesNet === totalExpenseNet  (the split never adds
//      or drops an expense — same total, just re-partitioned).
//   2. costOfGoodsSold === sum of is_cogs-category rows; operating gets the rest
//      (incl. uncategorized).
//   3. Net-profit identity holds from the engine's OWN output fields, proving the
//      split did not change the bottom line (display-neutral in stage 1).

import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const require = createRequire(import.meta.url);
const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const load = (p) => require(join(ROOT, p));

const failures = [];
const approx = (a, b, eps = 0.011) => Math.abs((a || 0) - (b || 0)) < eps;
const ok = (cond, msg) => { if (!cond) failures.push(msg); };

// ---- 1. _expenseSplit helper ----
const { splitExpenses } = load('electron/reports/_expenseSplit.js');
{
  const cats = [{ id: 'c1', is_cogs: 1 }, { id: 'c2', is_cogs: 0 }];
  const rows = [
    { amount_net: 600, category_id: 'c1' },   // COGS
    { amount_net: 100, category_id: 'c2' },   // operating
    { amount_net: 50, category_id: null },    // uncategorized -> operating
    { amount: 30, category_id: 'cX' },        // unknown cat, amount_net missing -> operating, uses amount
  ];
  const s = splitExpenses(rows, cats);
  ok(approx(s.totalExpenseNet, 780), `helper totalExpenseNet expected 780, got ${s.totalExpenseNet}`);
  ok(approx(s.cogsNet, 600), `helper cogsNet expected 600, got ${s.cogsNet}`);
  ok(approx(s.operatingExpensesNet, 180), `helper operatingExpensesNet expected 180, got ${s.operatingExpensesNet}`);
  ok(approx(s.cogsNet + s.operatingExpensesNet, s.totalExpenseNet), 'helper: cogsNet + operatingExpensesNet !== totalExpenseNet');
  // empty / null safety
  const e = splitExpenses([], cats);
  ok(e.totalExpenseNet === 0 && e.cogsNet === 0 && e.operatingExpensesNet === 0, 'helper: empty rows should be all zero');
}

// ---- 2. each non-US engine ----
const ENGINES = [
  { locale: 'CN', file: 'electron/reports/cn.js', key: 'incomeStatement', cogsSlug: 'cogs', hasSurchargeShipping: true },
  { locale: 'JP', file: 'electron/reports/jp.js', key: 'incomeStatement', cogsSlug: 'cogs', hasSurchargeShipping: false },
  { locale: 'EU', file: 'electron/reports/eu.js', key: 'profitLoss',      cogsSlug: 'purchases', hasSurchargeShipping: false },
  { locale: 'KR', file: 'electron/reports/kr.js', key: 'incomeStatement', cogsSlug: 'cogs', hasSurchargeShipping: false },
  { locale: 'TW', file: 'electron/reports/tw.js', key: 'incomeStatement', cogsSlug: 'cogs', hasSurchargeShipping: false },
];

for (const eng of ENGINES) {
  const mod = load(eng.file);
  const categories = [
    { id: 'cogs1', locale: eng.locale, type: 'expense', slug: eng.cogsSlug, is_cogs: 1 },
    { id: 'op1', locale: eng.locale, type: 'expense', slug: 'admin', is_cogs: 0 },
  ];
  const incomeRows = [{ amount: 1130, amount_net: 1000, tax_amount: 130, shippingCost: 0 }];
  const expenseRows = [
    { amount: 678, amount_net: 600, tax_amount: 78, category_id: 'cogs1' },  // COGS 600
    { amount: 113, amount_net: 100, tax_amount: 13, category_id: 'op1' },    // operating 100
    { amount: 50, amount_net: 50, tax_amount: 0, category_id: null },        // uncategorized -> operating 50
  ];
  const ctx = {
    incomeRows, expenseRows, categories,
    surchargeRate: 12, incomeTaxRate: 25, adminExpense: 0,
    currency: 'X', year: '2026', from: '2026-01-01', to: '2026-12-31',
  };
  const out = mod.generate(ctx);
  const st = out[eng.key];
  ok(!!st, `${eng.locale}: missing ${eng.key} in report`);
  if (!st) continue;

  // Anchor 1: COGS classification + the split partitions the FULL expense total.
  const totalExpenseNet = expenseRows.reduce((s, r) => s + (r.amount_net || r.amount || 0), 0); // 750
  ok(approx(st.costOfGoodsSold, 600), `${eng.locale}: costOfGoodsSold expected 600, got ${st.costOfGoodsSold}`);
  ok(approx(st.operatingExpenses, 150), `${eng.locale}: operatingExpenses expected 150, got ${st.operatingExpenses}`);
  ok(approx(st.costOfGoodsSold + st.operatingExpenses, totalExpenseNet),
    `${eng.locale}: cogs + operating (${st.costOfGoodsSold}+${st.operatingExpenses}) !== totalExpenseNet (${totalExpenseNet})`);

  // Anchor 2 (PR-T5-2A flip): costOfSales is now COGS-only; gross profit = revenue − COGS.
  const revenue = st.salesRevenue != null ? st.salesRevenue : st.revenue;
  ok(approx(st.costOfSales, st.costOfGoodsSold), `${eng.locale}: costOfSales (${st.costOfSales}) should now equal COGS (${st.costOfGoodsSold})`);
  ok(approx(st.grossProfit, revenue - st.costOfGoodsSold), `${eng.locale}: grossProfit (${st.grossProfit}) should be revenue − COGS (${revenue - st.costOfGoodsSold})`);

  // Anchor 3: net-profit identity now subtracts operating expenses too — net profit
  // is numerically unchanged by the flip (cogs + operating === old total).
  const surcharge = eng.hasSurchargeShipping ? (st.taxSurcharge || 0) : 0;
  const shipping = eng.hasSurchargeShipping ? (st.shippingFee || 0) : 0;
  const expectedNet = revenue - st.costOfGoodsSold - st.operatingExpenses - surcharge - shipping - (st.adminExpense || 0) - (st.incomeTax || 0);
  ok(approx(st.netProfit, expectedNet),
    `${eng.locale}: netProfit (${st.netProfit}) !== revenue − COGS − operating − surcharge − shipping − admin − incomeTax (${expectedNet})`);
}

console.log('\n=== COGS / Operating Split Test (PR-T5 backend core) ===\n');
console.log(`Engines checked: ${ENGINES.map((e) => e.locale).join(', ')} + _expenseSplit helper`);
console.log(`Failures: ${failures.length}\n`);
if (failures.length) {
  for (const f of failures) console.error('  ✗ ' + f);
  console.error('');
  process.exit(1);
}
console.log('✓ Split invariant holds (cogs + operating === total) and net profit is unchanged by the split.\n');
