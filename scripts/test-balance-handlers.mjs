#!/usr/bin/env node
// Balance-overview read-only handler guards (G1). Regression coverage for the three
// management-basis preview handlers that feed the balance overview but had no test:
//   • depreciationPreview  (straight-line net book value)
//   • retainedEarnings     (ending = opening + netProfit − distributions; entity dispatch)
//   • incomeTaxPosition    (netPosition = accrued − paid; period / currency / tax-type filters)
//
// Same harness as test-handlers.mjs: a fresh migrated :memory: DB injected via
// _setDbForTest, handlers called directly (read-only). It does NOT modify any
// handler / report engine / schema — it only seeds fixtures and asserts output.
//
// better-sqlite3 is built for the Electron ABI; under a plain node it fails to load,
// so this SKIPs (exit 0) — and runs for real in CI (rebuilt for the node ABI), same
// as test-handlers / test-migrations.

import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const require = createRequire(import.meta.url);
const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');

let Database;
try {
  Database = require('better-sqlite3');
  new Database(':memory:').close();
} catch (e) {
  console.log('⚠ test-balance-handlers SKIPPED: better-sqlite3 unloadable under this node (Electron ABI).');
  console.log('  Runs for real in CI, where better-sqlite3 is rebuilt for the node ABI.');
  console.log('  原因:', e?.message?.split('\n')[0] || e);
  process.exit(0);
}

const { runMigrations, _setDbForTest } = require(join(ROOT, 'electron/db/index.js'));
const { dispatch } = require(join(ROOT, 'electron/handlers/router.js'));
const depreciation = require(join(ROOT, 'electron/handlers/depreciationPreview.js'));
const retained = require(join(ROOT, 'electron/handlers/retainedEarnings.js'));
const incomeTax = require(join(ROOT, 'electron/handlers/incomeTaxPosition.js'));

const failures = [];
const ok = (cond, msg) => { if (!cond) failures.push(msg); };
const approx = (a, b, eps = 0.011) => Math.abs((a || 0) - (b || 0)) < eps;
const round2 = (n) => Math.round((Number(n) || 0) * 100) / 100;

function freshDb() {
  const db = new Database(':memory:');
  db.pragma('foreign_keys = ON');
  runMigrations(db);            // full schema + seeds (accounting_locale='CN', categories)
  _setDbForTest(db);
  return db;
}
const setSetting = (db, k, v) => db.prepare(
  'INSERT INTO settings(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value'
).run(k, JSON.stringify(v));
const seedAsset = (db, o) => db.prepare(
  `INSERT INTO fixed_assets (id,name,category,original_value,currency,status,acquisition_date,
     useful_life_months,salvage_rate,depreciation_start_policy,disposal_date,is_active,sort_order)
   VALUES (?,?,?,?,?,?,?,?,?,?,?,1,?)`
).run(o.id, o.name || o.id, o.category ?? null, o.original_value ?? 0, o.currency ?? null,
  o.status || 'in_use', o.acquisition_date ?? null, o.useful_life_months ?? null,
  o.salvage_rate ?? null, o.depreciation_start_policy ?? null, o.disposal_date ?? null, o.sort_order ?? 0);
const seedDraw = (db, o) => db.prepare(
  `INSERT INTO equity (id,name,equity_type,amount,currency,event_date,is_active)
   VALUES (?,?, 'owner_draw', ?,?,?,1)`
).run(o.id, o.name || o.id, o.amount ?? 0, o.currency ?? null, o.event_date ?? null);
const seedTaxPayment = (db, o) => db.prepare(
  `INSERT INTO tax_payments (id,name,tax_type,amount,currency,payment_date,period_start,period_end,is_active)
   VALUES (?,?,?,?,?,?,?,?,1)`
).run(o.id, o.name || o.id, o.tax_type || 'income_tax', o.amount ?? 0, o.currency ?? null,
  o.payment_date ?? null, o.period_start ?? null, o.period_end ?? null);
const PERIOD = { from: '2026-01-01', to: '2026-12-31' };
const assetById = (out, id) => out.byCurrency.flatMap((b) => b.assets).find((a) => a.id === id);

// ───────────────────────── A. depreciationPreview ─────────────────────────
// A1 — straight-line: 12000, salvage 0, life 12m, acq 2026-01, next_month, asOf 2026-07.
{
  const db = freshDb();
  seedAsset(db, { id: 'sl', original_value: 12000, salvage_rate: 0, useful_life_months: 12,
    acquisition_date: '2026-01-01', depreciation_start_policy: 'next_month', currency: 'CNY' });
  const a = assetById(await depreciation.preview({ query: { asOf: '2026-07-31' } }), 'sl');
  ok(a && approx(a.monthlyDepreciation, 1000) && a.monthsElapsed === 6
     && approx(a.accumulatedDepreciation, 6000) && approx(a.netBookValue, 6000),
    `[dep A1] SL net book value: ${JSON.stringify(a && { m: a.monthlyDepreciation, n: a.monthsElapsed, acc: a.accumulatedDepreciation, nbv: a.netBookValue })}`);
}
// A2 — accumulated capped at depreciable amount; net book value floors at salvage value.
{
  const db = freshDb();
  seedAsset(db, { id: 'cap', original_value: 10000, salvage_rate: 0.1, useful_life_months: 12,
    acquisition_date: '2020-01-01', depreciation_start_policy: 'next_month', currency: 'CNY' });
  const a = assetById(await depreciation.preview({ query: { asOf: '2026-12-31' } }), 'cap');
  ok(a && approx(a.accumulatedDepreciation, 9000) && approx(a.netBookValue, 1000) && approx(a.salvageValue, 1000),
    `[dep A2] capped at salvage: ${JSON.stringify(a && { acc: a.accumulatedDepreciation, nbv: a.netBookValue, sv: a.salvageValue })}`);
}
// A3 — disposed asset excluded from totals (still shown in the assets list).
{
  const db = freshDb();
  seedAsset(db, { id: 'live', original_value: 5000, salvage_rate: 0, useful_life_months: 10,
    acquisition_date: '2026-01-01', currency: 'CNY' });
  seedAsset(db, { id: 'gone', original_value: 3000, status: 'disposed', disposal_date: '2026-03-31',
    salvage_rate: 0, useful_life_months: 10, acquisition_date: '2026-01-01', currency: 'CNY' });
  const out = await depreciation.preview({ query: { asOf: '2026-12-31' } });
  const cny = out.byCurrency.find((b) => b.currency === 'CNY');
  ok(cny && approx(cny.totals.originalValue, 5000), `[dep A3] disposed excluded from totals.originalValue, got ${cny?.totals.originalValue}`);
  ok(!!assetById(out, 'gone')?.disposed, '[dep A3] disposed asset still present in assets list (disposed=true)');
}
// A4 — null useful_life_months falls back to the category default (vehicle = 4y = 48m).
{
  const db = freshDb();
  seedAsset(db, { id: 'veh', category: 'vehicle', original_value: 4800, salvage_rate: 0,
    useful_life_months: null, acquisition_date: '2026-01-01', currency: 'CNY' });
  const a = assetById(await depreciation.preview({ query: { asOf: '2026-12-31' } }), 'veh');
  ok(a && a.usefulLifeMonths === 48 && a.usedDefaults?.usefulLifeMonths === true && a.categoryResolved === 'vehicle',
    `[dep A4] vehicle default 48m: ${JSON.stringify(a && { life: a.usefulLifeMonths, used: a.usedDefaults, cat: a.categoryResolved })}`);
}
// A5 — multi-currency: per-currency groups, no cross-currency total.
{
  const db = freshDb();
  seedAsset(db, { id: 'c1', original_value: 1000, currency: 'CNY', salvage_rate: 0, useful_life_months: 10, acquisition_date: '2026-01-01' });
  seedAsset(db, { id: 'u1', original_value: 2000, currency: 'USD', salvage_rate: 0, useful_life_months: 10, acquisition_date: '2026-01-01' });
  const out = await depreciation.preview({ query: { asOf: '2026-12-31' } });
  const cur = out.byCurrency.map((b) => b.currency).sort();
  ok(cur.length === 2 && cur.includes('CNY') && cur.includes('USD'), `[dep A5] two currency groups, got ${JSON.stringify(cur)}`);
  ok(approx(out.byCurrency.find((b) => b.currency === 'CNY').totals.originalValue, 1000)
     && approx(out.byCurrency.find((b) => b.currency === 'USD').totals.originalValue, 2000),
    '[dep A5] per-currency totals not cross-summed');
}

// ───────────────────────── B. retainedEarnings ─────────────────────────
// B6 — core identity + netProfit flows from the report engine; individual → distributions 0.
{
  const db = freshDb();
  setSetting(db, 'opening_retained_earnings', 5000);
  await dispatch({ method: 'POST', path: '/api/transactions', body: { id: 'inc', type: 'income', date: '2026-06-01', amount: 1000, amount_net: 1000 } });
  const out = await retained.preview({ query: PERIOD });
  ok(out.openingRetainedEarnings === 5000, `[ret B6] opening read 5000, got ${out.openingRetainedEarnings}`);
  ok(out.netProfit > 0, `[ret B6] netProfit flows from report (>0), got ${out.netProfit}`);
  ok(out.distributions === 0 && out.entityType === 'individual', `[ret B6] individual → distributions 0, got ${out.distributions}/${out.entityType}`);
  ok(approx(out.endingRetainedEarnings, round2(out.openingRetainedEarnings + out.netProfit - out.distributions)),
    `[ret B6] ending = opening + netProfit − distributions, got ${out.endingRetainedEarnings}`);
}
// B7 — opening read: negative allowed (accumulated loss); invalid/NaN → 0.
{
  const db = freshDb();
  setSetting(db, 'opening_retained_earnings', -2000);
  ok((await retained.preview({ query: PERIOD })).openingRetainedEarnings === -2000, '[ret B7] negative opening allowed');
  setSetting(db, 'opening_retained_earnings', 'abc');
  ok((await retained.preview({ query: PERIOD })).openingRetainedEarnings === 0, '[ret B7] invalid opening → 0');
}
// B8 — individual ignores owner_draw entirely.
{
  const db = freshDb();
  seedDraw(db, { id: 'd1', amount: 999, currency: 'CNY', event_date: '2026-06-01' });
  const out = await retained.preview({ query: PERIOD });
  ok(out.distributions === 0 && out.entityType === 'individual', `[ret B8] individual owner_draw not deducted, got ${out.distributions}`);
}
// B9 — company: distributions = Σ base-currency owner_draw in period.
{
  const db = freshDb();
  setSetting(db, 'entity_type', 'company');
  seedDraw(db, { id: 'd1', amount: 1000, currency: 'CNY', event_date: '2026-03-01' });
  seedDraw(db, { id: 'd2', amount: 500, currency: 'CNY', event_date: '2026-09-01' });
  const out = await retained.preview({ query: PERIOD });
  ok(out.entityType === 'company' && approx(out.distributions, 1500), `[ret B9] company distributions Σ=1500, got ${out.distributions}`);
}
// B10 — company filters: foreign-currency / null-date / out-of-period owner_draw excluded.
{
  const db = freshDb();
  setSetting(db, 'entity_type', 'company');
  seedDraw(db, { id: 'ok', amount: 100, currency: 'CNY', event_date: '2026-06-01' });   // counted
  seedDraw(db, { id: 'fx', amount: 999, currency: 'USD', event_date: '2026-06-01' });   // foreign → excluded
  seedDraw(db, { id: 'nd', amount: 888, currency: 'CNY', event_date: null });           // null date → excluded
  seedDraw(db, { id: 'oo', amount: 777, currency: 'CNY', event_date: '2025-06-01' });   // out of period → excluded
  const out = await retained.preview({ query: PERIOD });
  ok(approx(out.distributions, 100), `[ret B10] only in-period base-ccy counted (100), got ${out.distributions}`);
  ok(out.excludedNotes.some((n) => n.includes('USD')), '[ret B10] foreign owner_draw noted in excludedNotes');
}

// ───────────────────────── C. incomeTaxPosition ─────────────────────────
// C11 — positionType + identity: prepaid (accrued 0, paid 500), payable (accrued>0, paid 0), zero.
{
  // prepaid
  const db = freshDb();
  seedTaxPayment(db, { id: 'p1', amount: 500, currency: 'CNY', payment_date: '2026-06-01' });
  const pre = await incomeTax.position({ query: PERIOD });
  ok(pre.accruedIncomeTax === 0 && approx(pre.paidIncomeTax, 500) && approx(pre.netPosition, -500)
     && pre.positionType === 'prepaid' && approx(pre.netPosition, round2(pre.accruedIncomeTax - pre.paidIncomeTax)),
    `[itp C11-prepaid] ${JSON.stringify({ a: pre.accruedIncomeTax, p: pre.paidIncomeTax, n: pre.netPosition, t: pre.positionType })}`);
}
{
  // payable — a profitable income makes accrued > 0; no payment.
  const db = freshDb();
  await dispatch({ method: 'POST', path: '/api/transactions', body: { id: 'inc', type: 'income', date: '2026-06-01', amount: 10000, amount_net: 10000 } });
  const pay = await incomeTax.position({ query: PERIOD });
  ok(pay.accruedIncomeTax > 0 && pay.paidIncomeTax === 0 && pay.positionType === 'payable'
     && approx(pay.netPosition, round2(pay.accruedIncomeTax - pay.paidIncomeTax)),
    `[itp C11-payable] ${JSON.stringify({ a: pay.accruedIncomeTax, p: pay.paidIncomeTax, t: pay.positionType })}`);
}
{
  // zero — empty report, no payment.
  const z = await (freshDb(), incomeTax.position({ query: PERIOD }));
  ok(z.accruedIncomeTax === 0 && z.paidIncomeTax === 0 && z.netPosition === 0 && z.positionType === 'zero',
    `[itp C11-zero] ${JSON.stringify({ a: z.accruedIncomeTax, p: z.paidIncomeTax, t: z.positionType })}`);
}
// C12/13/14 — paid sum (income_tax only); VAT excluded; non-base-currency excluded.
{
  const db = freshDb();
  seedTaxPayment(db, { id: 'i1', tax_type: 'income_tax', amount: 500, currency: 'CNY', payment_date: '2026-03-01' });
  seedTaxPayment(db, { id: 'i2', tax_type: 'income_tax', amount: 300, currency: 'CNY', payment_date: '2026-09-01' });
  seedTaxPayment(db, { id: 'v1', tax_type: 'vat', amount: 9999, currency: 'CNY', payment_date: '2026-06-01' });        // excluded: not income_tax
  seedTaxPayment(db, { id: 'f1', tax_type: 'income_tax', amount: 7777, currency: 'USD', payment_date: '2026-06-01' }); // excluded: non-base ccy
  const out = await incomeTax.position({ query: PERIOD });
  ok(approx(out.paidIncomeTax, 800), `[itp C12] income_tax paid Σ=800 (VAT not counted), got ${out.paidIncomeTax}`);
  ok(out.excludedPayments.some((e) => e.id === 'f1' && e.reason === 'non_base_currency'), '[itp C14] non-base-currency payment excluded');
  ok(!out.matchedPayments.some((m) => m.id === 'v1'), '[itp C13] VAT payment not in matched income_tax payments');
}
// C15 — period matching: no date → excluded(no_date); period straddling boundary → partial warning.
{
  const db = freshDb();
  seedTaxPayment(db, { id: 'nd', tax_type: 'income_tax', amount: 100, currency: 'CNY' });                                  // no date → no_date
  seedTaxPayment(db, { id: 'pp', tax_type: 'income_tax', amount: 200, currency: 'CNY', period_start: '2025-10-01', period_end: '2026-03-31' }); // straddles from
  const out = await incomeTax.position({ query: PERIOD });
  ok(out.excludedPayments.some((e) => e.id === 'nd' && e.reason === 'no_date'), '[itp C15] undated payment excluded(no_date)');
  ok(out.warnings.includes('partialPeriodOverlap'), '[itp C15] straddling period → partialPeriodOverlap warning');
}

console.log('\n=== Balance-Overview Handler Guards (G1) ===\n');
console.log('depreciationPreview (SL/cap/disposed/default/multi-ccy) · retainedEarnings (identity/opening/entity) · incomeTaxPosition (position/paid/filters/period)');
console.log(`Failures: ${failures.length}\n`);
if (failures.length) {
  for (const f of failures) console.error('  ✗ ' + f);
  console.error('');
  process.exit(1);
}
console.log('✓ The three balance-overview preview handlers hold their core invariants.\n');
