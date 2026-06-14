#!/usr/bin/env node
// Recategorize handler + report-shift invariants (PR-T5-2B-1).
//
// Part A: unit-tests the PURE _recategorize handler with an injected MOCK db, so
//   it runs under plain node (no better-sqlite3 / Electron ABI). Covers parameter
//   validation (400), dryRun preview vs commit behavior, and the expectedAffected
//   drift guard (409).
// Part B: engine-level invariant — moving an expense row from a COGS category to
//   an operating category leaves netProfit unchanged, shrinks COGS, grows operating
//   expenses and gross profit (the "fix a mis-classified expense" path).

import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const require = createRequire(import.meta.url);
const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const load = (p) => require(join(ROOT, p));

const failures = [];
const ok = (cond, msg) => { if (!cond) failures.push(msg); };
const approx = (a, b, eps = 0.011) => Math.abs((a || 0) - (b || 0)) < eps;

function expectStatus(fn, status, label) {
  try {
    fn();
    failures.push(`${label}: expected throw with status ${status}, but it returned`);
  } catch (e) {
    ok(e && e.status === status, `${label}: expected status ${status}, got ${e && e.status} (${e && e.message})`);
  }
}

// ---- Mock db ----------------------------------------------------------------
function makeDb({ categories = {}, fromCount = 0, locale = 'CN' } = {}) {
  const log = { updates: [], counts: 0, txn: 0 };
  return {
    log,
    prepare(sql) {
      if (sql.includes('FROM settings')) return { get: () => ({ value: JSON.stringify(locale) }) };
      if (sql.includes('FROM categories')) return { get: (id) => categories[id] };
      if (sql.includes('SELECT COUNT(*)')) return { get: () => { log.counts++; return { n: fromCount }; } };
      if (sql.trim().startsWith('UPDATE transactions')) {
        return { run: (toId, fromId) => { log.updates.push({ toId, fromId }); return { changes: fromCount }; } };
      }
      return { get: () => undefined, run: () => ({ changes: 0 }) };
    },
    transaction(fn) { return (...a) => { log.txn++; return fn(...a); }; },
  };
}

const { recategorize } = load('electron/handlers/_recategorize.js');
const CN_CATS = {
  cogs1: { id: 'cogs1', type: 'expense', locale: 'CN' },
  op1: { id: 'op1', type: 'expense', locale: 'CN' },
  inc1: { id: 'inc1', type: 'income', locale: 'CN' },
  usOp: { id: 'usOp', type: 'expense', locale: 'US' },
};

// ---- Part A: validation (400) ----
expectStatus(() => recategorize({ body: { fromCategoryId: 'cogs1', toCategoryId: 'op1' }, db: makeDb({ categories: CN_CATS }) }), 400, 'missing dryRun');
expectStatus(() => recategorize({ body: { fromCategoryId: 'cogs1', toCategoryId: 'op1', dryRun: 'true' }, db: makeDb({ categories: CN_CATS }) }), 400, 'non-boolean dryRun');
expectStatus(() => recategorize({ body: { fromCategoryId: 'cogs1', toCategoryId: 'cogs1', dryRun: true }, db: makeDb({ categories: CN_CATS }) }), 400, 'from === to');
expectStatus(() => recategorize({ body: { fromCategoryId: 'cogs1', toCategoryId: 'missing', dryRun: true }, db: makeDb({ categories: CN_CATS }) }), 400, 'missing category');
expectStatus(() => recategorize({ body: { fromCategoryId: 'cogs1', toCategoryId: 'inc1', dryRun: true }, db: makeDb({ categories: CN_CATS }) }), 400, 'non-expense category');
expectStatus(() => recategorize({ body: { fromCategoryId: 'cogs1', toCategoryId: 'usOp', dryRun: true }, db: makeDb({ categories: CN_CATS }) }), 400, 'cross-locale');
expectStatus(() => recategorize({ body: { fromCategoryId: 'usOp', toCategoryId: 'usOp', dryRun: true }, db: makeDb({ categories: CN_CATS, locale: 'CN' }) }), 400, 'same from/to is caught before locale');
expectStatus(() => recategorize({ body: { fromCategoryId: 'cogs1', toCategoryId: 'op1', dryRun: false, expectedAffected: -1 }, db: makeDb({ categories: CN_CATS }) }), 400, 'negative expectedAffected');
// locale != accounting_locale: both US categories but settings = CN
{
  const db = makeDb({ categories: { a: { id: 'a', type: 'expense', locale: 'US' }, b: { id: 'b', type: 'expense', locale: 'US' } }, locale: 'CN' });
  expectStatus(() => recategorize({ body: { fromCategoryId: 'a', toCategoryId: 'b', dryRun: true }, db }), 400, 'locale != accounting_locale');
}

// ---- Part A: dryRun preview (no write) ----
{
  const db = makeDb({ categories: CN_CATS, fromCount: 7 });
  const res = recategorize({ body: { fromCategoryId: 'cogs1', toCategoryId: 'op1', dryRun: true }, db });
  ok(res.dryRun === true && res.affected === 7, `dryRun preview should return affected=7, got ${JSON.stringify(res)}`);
  ok(db.log.updates.length === 0, 'dryRun must NOT issue an UPDATE');
}

// ---- Part A: commit (UPDATE in a txn, only category_id) ----
{
  const db = makeDb({ categories: CN_CATS, fromCount: 7 });
  const res = recategorize({ body: { fromCategoryId: 'cogs1', toCategoryId: 'op1', dryRun: false }, db });
  ok(res.dryRun === false && res.moved === 7, `commit should return moved=7, got ${JSON.stringify(res)}`);
  ok(db.log.txn === 1, 'commit must run inside a transaction');
  ok(db.log.updates.length === 1, 'commit must issue exactly one UPDATE');
  ok(db.log.updates[0] && db.log.updates[0].toId === 'op1' && db.log.updates[0].fromId === 'cogs1',
    `UPDATE must move from cogs1 → op1, got ${JSON.stringify(db.log.updates[0])}`);
}

// ---- Part A: expectedAffected drift → 409 (no write) ----
{
  const db = makeDb({ categories: CN_CATS, fromCount: 7 });
  expectStatus(() => recategorize({ body: { fromCategoryId: 'cogs1', toCategoryId: 'op1', dryRun: false, expectedAffected: 3 }, db }), 409, 'expectedAffected drift');
  ok(db.log.updates.length === 0, '409 drift must NOT issue an UPDATE');
}
// ---- Part A: expectedAffected match → commits ----
{
  const db = makeDb({ categories: CN_CATS, fromCount: 7 });
  const res = recategorize({ body: { fromCategoryId: 'cogs1', toCategoryId: 'op1', dryRun: false, expectedAffected: 7 }, db });
  ok(res.moved === 7 && db.log.updates.length === 1, 'matching expectedAffected should commit the move');
}

// ---- Part B: engine-level recategorization invariant (cn) ----
{
  const cn = load('electron/reports/cn.js');
  const categories = [
    { id: 'cogs1', type: 'expense', locale: 'CN', slug: 'cogs', is_cogs: 1 },
    { id: 'op1', type: 'expense', locale: 'CN', slug: 'admin', is_cogs: 0 },
  ];
  const incomeRows = [{ amount: 1130, amount_net: 1000, tax_amount: 130, shippingCost: 0 }];
  const ctx = (rows) => ({
    incomeRows, expenseRows: rows, categories,
    surchargeRate: 12, incomeTaxRate: 25, adminExpense: 0,
    currency: 'CNY', year: '2026', from: '2026-01-01', to: '2026-12-31',
  });
  // A 50-unit operating expense is mis-filed under the COGS category.
  const before = cn.generate(ctx([
    { amount_net: 600, category_id: 'cogs1' },
    { amount_net: 100, category_id: 'op1' },
    { amount_net: 50, category_id: 'cogs1' },
  ])).incomeStatement;
  // Recategorize the 50 → operating (what the endpoint's UPDATE does).
  const after = cn.generate(ctx([
    { amount_net: 600, category_id: 'cogs1' },
    { amount_net: 100, category_id: 'op1' },
    { amount_net: 50, category_id: 'op1' },
  ])).incomeStatement;

  ok(approx(before.netProfit, after.netProfit), `recat: netProfit must be unchanged (${before.netProfit} vs ${after.netProfit})`);
  ok(after.costOfGoodsSold < before.costOfGoodsSold, `recat: COGS should drop (${before.costOfGoodsSold} → ${after.costOfGoodsSold})`);
  ok(after.operatingExpenses > before.operatingExpenses, `recat: operating expenses should rise (${before.operatingExpenses} → ${after.operatingExpenses})`);
  ok(after.grossProfit > before.grossProfit, `recat: gross profit should rise (${before.grossProfit} → ${after.grossProfit})`);
  ok(approx(before.costOfGoodsSold + before.operatingExpenses, after.costOfGoodsSold + after.operatingExpenses),
    'recat: total expense (cogs + operating) must be conserved');
}

console.log('\n=== Recategorize Handler + Invariant Test (PR-T5-2B-1) ===\n');
console.log('Covered: param validation (400), dryRun preview, commit UPDATE, expectedAffected drift (409), engine recat invariant');
console.log(`Failures: ${failures.length}\n`);
if (failures.length) {
  for (const f of failures) console.error('  ✗ ' + f);
  console.error('');
  process.exit(1);
}
console.log('✓ Recategorize validates inputs, previews without writing, commits only category_id, guards drift, and preserves net profit.\n');
