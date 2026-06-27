#!/usr/bin/env node
// Surcharge locale guard (G2). Pure-function test of the report engines — no DB,
// no provider. Locks in: the CN-specific tax surcharge (城建/教育/地方教育附加,
// surchargeRate 12%) must NEVER be applied by a non-CN engine, even when the
// dispatcher passes a non-zero surchargeRate (electron/reports/index.js defaults
// surcharge_rate to 12 and hands it to every engine).
//
// Anchors:
//   • JP / EU / KR / TW: taxSurcharge stays 0 even with surchargeRate = 12 — the
//     non-CN engines have no surcharge logic at all.
//   • US (Schedule C): output carries no taxSurcharge field whatsoever.
//   • CN positive control: surchargeRate 12 + vatPayable > 0 → taxSurcharge > 0,
//     so the guard is not vacuously passing (CN surcharge really fires).
//   • CN zero control: surchargeRate 0 → taxSurcharge 0 — rate-driven, not hardcoded.
//
// This is a guard test only: it loads the engines read-only and asserts on their
// output. It does NOT change any engine / formula / business logic.

import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const require = createRequire(import.meta.url);
const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const load = (p) => require(join(ROOT, p));

const failures = [];
const ok = (cond, msg) => { if (!cond) failures.push(msg); };
const surchargeOf = (st) => (st && st.taxSurcharge) || 0;

// Shared fixture: output VAT 130 > input VAT (78 + 13 = 91) → vatPayable 39 (> 0),
// so a CN surcharge would be 39 × 12% = 4.68 (non-zero) — and must stay 0 for non-CN.
const fixture = (locale, cogsSlug) => ({
  incomeRows: [{ amount: 1130, amount_net: 1000, tax_amount: 130, shippingCost: 0 }],
  expenseRows: [
    { amount: 678, amount_net: 600, tax_amount: 78, category_id: 'cogs1' },
    { amount: 113, amount_net: 100, tax_amount: 13, category_id: 'op1' },
  ],
  categories: [
    { id: 'cogs1', locale, type: 'expense', slug: cogsSlug, is_cogs: 1 },
    { id: 'op1', locale, type: 'expense', slug: 'admin', is_cogs: 0 },
  ],
  incomeTaxRate: 25, adminExpense: 0,
  currency: 'X', year: '2026', from: '2026-01-01', to: '2026-12-31',
});

// ---- 1. non-CN VAT engines: surcharge stays 0 even with surchargeRate = 12 ----
const NON_CN = [
  { locale: 'JP', file: 'electron/reports/jp.js', key: 'incomeStatement', cogsSlug: 'cogs' },
  { locale: 'EU', file: 'electron/reports/eu.js', key: 'profitLoss',      cogsSlug: 'purchases' },
  { locale: 'KR', file: 'electron/reports/kr.js', key: 'incomeStatement', cogsSlug: 'cogs' },
  { locale: 'TW', file: 'electron/reports/tw.js', key: 'incomeStatement', cogsSlug: 'cogs' },
];
for (const eng of NON_CN) {
  const out = load(eng.file).generate({ ...fixture(eng.locale, eng.cogsSlug), surchargeRate: 12 });
  ok(surchargeOf(out[eng.key]) === 0,
    `${eng.locale}: taxSurcharge must be 0 with surchargeRate=12, got ${surchargeOf(out[eng.key])}`);
}

// ---- 2. US (Schedule C): no taxSurcharge field at all ----
{
  const usOut = load('electron/reports/us.js').generate({
    incomeRows: [{ amount: 1000 }], expenseRows: [{ amount: 200 }], categories: [],
    incomeTaxRate: 21, currency: 'X', year: '2026', from: '2026-01-01', to: '2026-12-31',
  });
  ok(!JSON.stringify(usOut).includes('taxSurcharge'),
    'US: Schedule C output must contain no taxSurcharge field');
}

// ---- 3. CN positive control: surcharge fires when rate=12 and vatPayable>0 ----
{
  const out = load('electron/reports/cn.js').generate({ ...fixture('CN', 'cogs'), surchargeRate: 12 });
  ok(surchargeOf(out.incomeStatement) > 0,
    `CN: taxSurcharge must be > 0 with surchargeRate=12 and vatPayable>0, got ${surchargeOf(out.incomeStatement)}`);
}

// ---- 4. CN zero control: surcharge is rate-driven (0 → 0), not hardcoded ----
{
  const out = load('electron/reports/cn.js').generate({ ...fixture('CN', 'cogs'), surchargeRate: 0 });
  ok(surchargeOf(out.incomeStatement) === 0,
    `CN: taxSurcharge must be 0 with surchargeRate=0, got ${surchargeOf(out.incomeStatement)}`);
}

console.log('\n=== Surcharge Locale Guard (G2) ===\n');
console.log('JP/EU/KR/TW: surcharge 0 @ rate 12 · US: no field · CN: rate-driven (12 -> >0, 0 -> 0)');
console.log(`Failures: ${failures.length}\n`);
if (failures.length) {
  for (const f of failures) console.error('  ✗ ' + f);
  console.error('');
  process.exit(1);
}
console.log('✓ Non-CN engines never apply the CN tax surcharge; CN surcharge is rate-driven.\n');
