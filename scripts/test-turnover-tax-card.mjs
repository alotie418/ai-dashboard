#!/usr/bin/env node
// Guard: the turnover-tax card must never fabricate zeros.
//
// THE BUG THIS EXISTS FOR
//
// `dashboard.js` used to pick a block with
//   report?.vatSummary || report?.consumptionTax || report?.vatReturn || report?.businessTax
// and hand it to a component that reads only CHINA's field names. The five
// engines emit DIFFERENT field names for the same concepts, so under JP / EU /
// KR / TW every lookup was `undefined`, `fmt(val || 0)` printed `0.00`, and four
// of six accounting profiles saw five fabricated zeros — with a disclaimer
// underneath implying they were real figures. The same object feeds the AI
// context in `ai.js`, so those ledgers handed the assistant three zeros too.
//
// That is CLAUDE.md's "do not show placeholder values as if they are official
// financial metrics", and it is the second instance of Appendix A7 (a naming
// mismatch making a downstream consumer read 0).
//
// WHAT IS ASSERTED
//
//   1. Every non-US locale maps to REAL numbers from its own block.
//   2. The China-only certified/invoiced pair is ABSENT (not 0) for the other
//      four, so the card can drop that section rather than print zeros.
//   3. The mapping is driven by the engines' actual output, not by a snapshot:
//      the blocks are produced by running the real engines.
import { strict as assert } from 'node:assert';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const require = createRequire(import.meta.url);
const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const dashboard = require(join(ROOT, 'electron/handlers/dashboard.js'));

// The helper is not exported; exercise it through the module's own surface if it
// is, otherwise re-derive it from the same source of truth the handler uses.
const normalize = dashboard.normalizeTurnoverTax;
assert.ok(typeof normalize === 'function',
  'dashboard.js must export normalizeTurnoverTax so this guard tests the real mapping');

// A context every VAT engine accepts, with recorded tax on both sides.
const ctx = (locale) => ({
  locale, from: '2025-01-01', to: '2025-12-31', year: '2025',
  incomeRows: [{ amount: 1130, amount_net: 1000, tax_amount: 130, date: '2025-03-01' }],
  expenseRows: [{ amount: 565, amount_net: 500, tax_amount: 65, date: '2025-03-01' }],
  categories: [], vatRate: 13, surchargeRate: 12, incomeTaxRate: 25,
  adminExpense: 0, currency: 'CNY',
});

const ENGINES = {
  CN: 'cn', JP: 'jp', EU: 'eu', KR: 'kr', TW: 'tw',
};

let failures = 0;
const fail = (msg) => { console.error(`  ✗ ${msg}`); failures++; };

for (const [locale, file] of Object.entries(ENGINES)) {
  const engine = require(join(ROOT, `electron/reports/${file}.js`));
  const report = engine.generate(ctx(locale));
  const card = normalize(report);

  if (!card) { fail(`${locale}: no card data at all`); continue; }

  // 1. Real numbers, taken from that engine's own block.
  if (card.cumulativeInput !== 65) fail(`${locale}: input tax ${card.cumulativeInput}, expected 65`);
  if (card.cumulativeOutput !== 130) fail(`${locale}: output tax ${card.cumulativeOutput}, expected 130`);
  if (card.estimatedPayable !== 65) fail(`${locale}: payable ${card.estimatedPayable}, expected 65`);

  // 2. The China-only pair.
  if (locale === 'CN') {
    if (card.certifiedInput !== 65 || card.invoicedOutput !== 130) {
      fail(`CN: the five-field block must keep certifiedInput/invoicedOutput`);
    }
  } else if (card.certifiedInput !== undefined || card.invoicedOutput !== undefined) {
    fail(`${locale}: certified/invoiced must be ABSENT, not ${card.certifiedInput}/${card.invoicedOutput} ` +
         `— printing 0 there is the bug this guard exists for`);
  }
  console.log(`  ✓ ${locale}: input ${card.cumulativeInput}, output ${card.cumulativeOutput}, ` +
              `payable ${card.estimatedPayable}` +
              (locale === 'CN' ? `, certified pair present` : `, certified pair absent`));
}

// 3. The regression itself: the OLD expression picks a block whose China field
//    names are undefined for four locales. Asserted so the guard fails if someone
//    reinstates it.
{
  const jp = require(join(ROOT, 'electron/reports/jp.js')).generate(ctx('JP'));
  const oldPick = jp.vatSummary || jp.consumptionTax || jp.vatReturn || jp.businessTax;
  assert.ok(oldPick, 'JP does produce a block');
  if (oldPick.cumulativeInput !== undefined) {
    fail('jp.js grew a cumulativeInput field — this guard needs rewriting');
  } else {
    console.log('  ✓ the old `a || b || c` pick still yields undefined China fields ' +
                '(which is why it printed 0.00)');
  }
}

if (failures) {
  console.error(`\n✗ turnover-tax card: ${failures} failure(s)`);
  process.exit(1);
}
console.log('\n✓ turnover-tax card: every locale maps to real numbers; no fabricated zeros');
