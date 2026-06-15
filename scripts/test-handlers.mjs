#!/usr/bin/env node
// IPC handler 往返测试（§2B）—— 第一批：核心记账 handler。此前这层零执行覆盖。
// 走真实生产路径：router.dispatch({method,path,body}) → 匹配路由 → handler → :memory: DB。
// db 句柄经 _setDbForTest 注入（绕过 initDatabase 对 electron app 路径的依赖）。
//
// 覆盖：transactions CRUD+summary+校验 · purchases CRUD+payment+校验 · sales CRUD+payment
//       · dashboard 端到端(settings→报表引擎→financialStatement) · router 未知路由报错。
//
// better-sqlite3 原生绑定按 Electron ABI 编（本机/普通 node 加载会 ERR_DLOPEN）；
// 加载不了时优雅 SKIP（exit 0）——CI 里 rebuild 成 node ABI 后真跑（同 test-migrations）。

import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const require = createRequire(import.meta.url);
const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');

let Database;
try {
  Database = require('better-sqlite3');
  new Database(':memory:').close(); // 触发原生绑定加载；ABI 不符在此抛 → 下面 SKIP
} catch (e) {
  console.log('⚠ test-handlers SKIPPED: better-sqlite3 unloadable under this node (Electron ABI).');
  console.log('  Runs for real in CI, where better-sqlite3 is rebuilt for the node ABI.');
  console.log('  原因:', e?.message?.split('\n')[0] || e);
  process.exit(0);
}

const { runMigrations, _setDbForTest } = require(join(ROOT, 'electron/db/index.js'));
const { dispatch } = require(join(ROOT, 'electron/handlers/router.js'));

const failures = [];
const ok = (cond, msg) => { if (!cond) failures.push(msg); };
const approx = (a, b, eps = 0.011) => Math.abs((a || 0) - (b || 0)) < eps;
const YEAR = String(new Date().getFullYear());

// 每个用例一个全新的迁移到 head 的 :memory: 库（v3 已 seed accounting_locale='CN'，v4 seed 类别）
function freshDb() {
  const db = new Database(':memory:');
  db.pragma('foreign_keys = ON');
  runMigrations(db);
  _setDbForTest(db);
  return db;
}
const call = (method, path, body) => dispatch({ method, path, body });
async function expectThrow(fn, label) {
  try { await fn(); failures.push(`${label}: expected throw, but resolved`); }
  catch { /* expected */ }
}

// ───────────────────────── transactions ─────────────────────────
{
  freshDb();
  // create income + expense
  const r1 = await call('POST', '/api/transactions', { id: 'txn-i1', type: 'income', date: `${YEAR}-06-01`, amount: 1000, amount_net: 1000 });
  ok(r1?.success && r1.id === 'txn-i1', `[txn] create income → {success,id}, got ${JSON.stringify(r1)}`);
  await call('POST', '/api/transactions', { id: 'txn-e1', type: 'expense', date: `${YEAR}-06-02`, amount: 300, amount_net: 300 });

  // list
  const list = await call('GET', '/api/transactions', null);
  ok(Array.isArray(list) && list.length === 2, `[txn] list → 2 rows, got ${list?.length}`);

  // list filtered by type
  const incomeOnly = await call('GET', '/api/transactions?type=income', null);
  ok(incomeOnly.length === 1 && incomeOnly[0].id === 'txn-i1', '[txn] list?type=income → only income');

  // get by id
  const got = await call('GET', '/api/transactions/txn-i1', null);
  ok(got?.id === 'txn-i1' && got.amount === 1000, '[txn] get/:id → the row');

  // update
  await call('PUT', '/api/transactions/txn-i1', { type: 'income', date: `${YEAR}-06-01`, amount: 1500, amount_net: 1500 });
  const got2 = await call('GET', '/api/transactions/txn-i1', null);
  ok(got2.amount === 1500, `[txn] update → amount 1500, got ${got2.amount}`);

  // summary: net = income - expense
  const sum = await call('GET', '/api/transactions/summary', null);
  ok(approx(sum.income.total, 1500) && approx(sum.expense.total, 300) && approx(sum.net, 1200),
    `[txn] summary net=income-expense, got ${JSON.stringify(sum)}`);

  // delete → gone (get throws)
  await call('DELETE', '/api/transactions/txn-e1', null);
  const after = await call('GET', '/api/transactions', null);
  ok(after.length === 1, `[txn] delete → 1 row left, got ${after.length}`);
  await expectThrow(() => call('GET', '/api/transactions/txn-e1', null), '[txn] get deleted');

  // validation: bad type / missing date both throw (these pass through normalize unchanged)
  await expectThrow(() => call('POST', '/api/transactions', { id: 'x', type: 'bogus', date: `${YEAR}-01-01`, amount: 1 }), '[txn] invalid type');
  await expectThrow(() => call('POST', '/api/transactions', { id: 'y2', type: 'income' }), '[txn] missing date');
  // contract: missing amount is NOT rejected — normalize coerces it to 0 before validate runs
  // (the amount check in validate is effectively dead for create). Lock the real behavior.
  const z = await call('POST', '/api/transactions', { id: 'txn-z', type: 'income', date: `${YEAR}-01-01` });
  ok(z?.success, '[txn] missing amount → coerced to 0 (not rejected)');
  ok((await call('GET', '/api/transactions/txn-z', null)).amount === 0, '[txn] missing amount stored as 0');
}

// ───────────────────────── purchases + payment ─────────────────────────
{
  freshDb();
  const c = await call('POST', '/api/purchases', { id: 'pur-1', date: `${YEAR}-06-01`, supplier: 'Acme', tons: 10, totalAmount: 1130 });
  ok(c?.success, `[pur] create → success, got ${JSON.stringify(c)}`);
  const list = await call('GET', '/api/purchases', null);
  ok(list.length === 1 && list[0].supplier === 'Acme', '[pur] list reflects create');

  // update
  await call('PUT', '/api/purchases/pur-1', { date: `${YEAR}-06-01`, supplier: 'Acme2', tons: 12, totalAmount: 1356 });
  const list2 = await call('GET', '/api/purchases', null);
  ok(list2[0].supplier === 'Acme2' && approx(list2[0].tons, 12), '[pur] update reflected');

  // payment: full / partial / zero → status
  const full = await call('PUT', '/api/purchases/pur-1/payment', { paid_amount: 1356 });
  ok(full.payment_status === 'paid', `[pur] full payment → paid, got ${full.payment_status}`);
  const partial = await call('PUT', '/api/purchases/pur-1/payment', { paid_amount: 500 });
  ok(partial.payment_status === 'partial', `[pur] partial → partial, got ${partial.payment_status}`);
  const zero = await call('PUT', '/api/purchases/pur-1/payment', { paid_amount: 0 });
  ok(zero.payment_status === 'unpaid', `[pur] zero → unpaid, got ${zero.payment_status}`);

  // validation: negative tons; payment on missing id; negative paid
  await expectThrow(() => call('POST', '/api/purchases', { id: 'bad', date: `${YEAR}-01-01`, tons: -5 }), '[pur] negative tons');
  await expectThrow(() => call('PUT', '/api/purchases/nope/payment', { paid_amount: 10 }), '[pur] payment on missing');
  await expectThrow(() => call('PUT', '/api/purchases/pur-1/payment', { paid_amount: -1 }), '[pur] negative paid');

  // delete
  await call('DELETE', '/api/purchases/pur-1', null);
  ok((await call('GET', '/api/purchases', null)).length === 0, '[pur] delete → empty');
}

// ───────────────────────── sales + payment ─────────────────────────
{
  freshDb();
  await call('POST', '/api/sales', { id: 'sal-1', date: `${YEAR}-06-01`, customer: 'Cust', tons: 8, totalAmount: 2260, shippingCost: 50 });
  const list = await call('GET', '/api/sales', null);
  ok(list.length === 1 && list[0].customer === 'Cust' && approx(list[0].shippingCost, 50), '[sal] create+list reflects (incl shippingCost)');

  const pay = await call('PUT', '/api/sales/sal-1/payment', { paid_amount: 2260 });
  ok(pay.payment_status === 'paid', `[sal] full payment → paid, got ${pay.payment_status}`);

  await expectThrow(() => call('POST', '/api/sales', { id: 'bad', date: `${YEAR}-01-01`, tons: -1 }), '[sal] negative tons');
  await call('DELETE', '/api/sales/sal-1', null);
  ok((await call('GET', '/api/sales', null)).length === 0, '[sal] delete → empty');
}

// ───────────── dashboard end-to-end (settings → report engine → financialStatement) ─────────────
{
  const db = freshDb();
  // accounting_locale='CN' already seeded by migration v3. Categorize with seeded CN categories.
  const incomeCat = db.prepare("SELECT id FROM categories WHERE locale='CN' AND type='income' ORDER BY sort_order LIMIT 1").get();
  const expenseCat = db.prepare("SELECT id FROM categories WHERE locale='CN' AND type='expense' ORDER BY sort_order LIMIT 1").get();
  ok(incomeCat?.id && expenseCat?.id, '[dash] migration v4 seeded CN income+expense categories');

  await call('POST', '/api/transactions', { id: 'd-i1', type: 'income', date: `${YEAR}-03-01`, amount: 5000, amount_net: 5000, category_id: incomeCat.id });
  await call('POST', '/api/transactions', { id: 'd-e1', type: 'expense', date: `${YEAR}-03-02`, amount: 2000, amount_net: 2000, category_id: expenseCat.id });

  const dash = await call('GET', `/api/dashboard?year=${YEAR}`, null);
  ok(dash?.locale === 'CN', `[dash] locale CN, got ${dash?.locale}`);
  const fs = dash.financialStatement;
  ok(fs && typeof fs === 'object', '[dash] financialStatement present');
  for (const k of ['salesRevenue', 'costOfSales', 'grossProfit', 'netProfit', 'netMargin']) {
    ok(typeof fs[k] === 'number', `[dash] financialStatement.${k} is a number, got ${typeof fs[k]}`);
  }
  ok(fs.salesRevenue > 0, `[dash] income reflected in salesRevenue, got ${fs.salesRevenue}`);
  ok(dash.inventory && typeof dash.inventory === 'object', '[dash] inventory overview present');
}

// ───────────────────────── router ─────────────────────────
{
  freshDb();
  await expectThrow(() => call('GET', '/api/this-route-does-not-exist', null), '[router] unknown route throws');
}

if (failures.length) {
  console.error(`✗ handlers: ${failures.length} assertion(s) failed:`);
  for (const f of failures) console.error('  - ' + f);
  process.exit(1);
}
console.log('✓ handlers: round-trips passed (transactions/purchases/sales CRUD+payment+validation + dashboard e2e + router) via real dispatch on :memory: DB');
