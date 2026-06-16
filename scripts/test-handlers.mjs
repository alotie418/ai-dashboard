#!/usr/bin/env node
// IPC handler 往返测试（§2B）—— 第一批：核心记账 handler。此前这层零执行覆盖。
// 走真实生产路径：router.dispatch({method,path,body}) → 匹配路由 → handler → :memory: DB。
// db 句柄经 _setDbForTest 注入（绕过 initDatabase 对 electron app 路径的依赖）。
//
// 覆盖（第一批 #157）：transactions CRUD+summary+校验 · purchases CRUD+payment+校验 · sales CRUD+payment
//       · dashboard 端到端(settings→报表引擎→financialStatement) · router 未知路由报错。
// 覆盖（第二批 §2B Batch 2）：categories（locale-scoped list / is_cogs·is_deductible·is_system 布尔强转 /
//       is_cogs create 默认 0 / system 类别 slug·type·locale 不可改且不可删 / reset 只删用户类别并返回 count）
//       · products（unit 白名单 / default_unit_cost 负数·NaN→0 / is_service·is_active flags）
//       · inventory summary（qtyOnHand=in−out / 仅在库 / 默认成本 vs 加权平均 / 含税排除（tax-exclusive）/
//       service·inactive 排除 / 不同单位不合并）。
// 覆盖（第三批 §2B Batch 3）：alerts（list 仅未 dismiss / created_at DESC / unread_only / count /
//       mark-read·read-all·dismiss / limit / 非数字 id throw；无 create route→直插 DB seed）
//       · receivables/payables summary（totalReceivable·totalPayable / details 仅 unpaid>0 /
//       collectionRate·paymentRate（无单据=100）/ topCustomers·topSuppliers 排名 / 相对日期 aging
//       buckets（mid-bucket offset，绝不写固定过期日）/ 已付且有 due_date 不 inflate 应收·应付）。
// 覆盖（第四批 §2B Batch 4）：settings（GET/PUT 白名单读写双向过滤 / JSON 往返 / oversized→warnings /
//       array body throw / null body no-op）· reports（types locale 路由 + unknown→[] / generate 结构 +
//       period echo + monthlyBreakdown12 / **非税不变量** salesRevenue=Σamount_net·costOfSales=0·
//       grossProfit=revenue / incomeTax·netProfit·taxSurcharge 仅 typeof number 不锁值（T11/T12 不锁）/
//       unsupported throw / US smoke）· batch（sales·purchases 批量插入 / success·failed·errors / 部分成功 /
//       empty·>500 throw / 默认值 payment_status=paid·invoiceStatus / due_date persisted）。
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

// §2B Batch 2 helper: products.create derives its id from Date.now() ONLY (no random/seq
// suffix), so two creates inside the same millisecond collide on the PRIMARY KEY. Real UI
// pace never hits this; rapid programmatic creates do. Space product creates ≥2ms apart so
// each lands on a distinct timestamp — deterministic, and WITHOUT touching the handler.
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ───────────────────────── categories (i18n master data) ─────────────────────────
{
  const db = freshDb();

  // locale-scoped list: seeded CN categories all carry locale 'CN'
  const cnList = await call('GET', '/api/categories?locale=CN', null);
  ok(Array.isArray(cnList) && cnList.length > 0, `[cat] CN list non-empty, got ${cnList?.length}`);
  ok(cnList.every((c) => c.locale === 'CN'), '[cat] list?locale=CN → only CN rows');
  // boolean coercion: is_cogs / is_deductible / is_system come back as real booleans (not 0/1)
  ok(cnList.every((c) => typeof c.is_cogs === 'boolean' && typeof c.is_deductible === 'boolean' && typeof c.is_system === 'boolean'),
    '[cat] list flags coerced to booleans');
  // v13 seeded a COGS category (slug 'cogs' → is_cogs=1); most others are 0 → both values present proves coercion
  ok(cnList.some((c) => c.is_cogs === true) && cnList.some((c) => c.is_cogs === false),
    '[cat] is_cogs reflects both true (seeded cogs) and false');
  ok(cnList.every((c) => c.is_system === true), '[cat] seeded CN categories are is_system=true');

  // create user category — is_cogs unspecified → default false; is_deductible unspecified → default true
  const created = await call('POST', '/api/categories', { locale: 'CN', type: 'expense', slug: 'unit-test-cat', label_en: 'Unit Test Cat' });
  ok(created?.success && typeof created.id === 'string', `[cat] create → {success,id}, got ${JSON.stringify(created)}`);
  const mine = (await call('GET', '/api/categories?locale=CN', null)).find((c) => c.id === created.id);
  ok(mine && mine.is_system === false, '[cat] created user category is_system=false');
  ok(mine.is_cogs === false, '[cat] create default is_cogs=false (operating)');
  ok(mine.is_deductible === true, '[cat] create default is_deductible=true');

  // locale-scoping is deterministic: the CN user category must NOT appear under US
  const usList = await call('GET', '/api/categories?locale=US', null);
  ok(!usList.some((c) => c.id === created.id), '[cat] CN user category absent from US list (locale-scoped)');

  // explicit is_cogs:true + is_deductible:false → coerced and stored
  const cogsCat = await call('POST', '/api/categories', { locale: 'CN', type: 'expense', slug: 'unit-test-cogs', label_en: 'COGS Cat', is_cogs: true, is_deductible: false });
  const cogsRow = (await call('GET', '/api/categories?locale=CN', null)).find((c) => c.id === cogsCat.id);
  ok(cogsRow.is_cogs === true && cogsRow.is_deductible === false, '[cat] explicit is_cogs:true + is_deductible:false stored');

  // validation: bad locale / type / slug / missing label all throw (no row created)
  await expectThrow(() => call('POST', '/api/categories', { locale: 'XX', type: 'expense', slug: 'x', label_en: 'x' }), '[cat] invalid locale');
  await expectThrow(() => call('POST', '/api/categories', { locale: 'CN', type: 'bogus', slug: 'x', label_en: 'x' }), '[cat] invalid type');
  await expectThrow(() => call('POST', '/api/categories', { locale: 'CN', type: 'expense', slug: 'Bad Slug', label_en: 'x' }), '[cat] invalid slug');
  await expectThrow(() => call('POST', '/api/categories', { locale: 'CN', type: 'expense', slug: 'no-label' }), '[cat] missing label');

  // system category protection: slug/type/locale immutable; label + is_cogs ARE editable
  const sys = db.prepare("SELECT id, slug, type, locale FROM categories WHERE locale='CN' AND is_system=1 ORDER BY sort_order LIMIT 1").get();
  ok(sys?.id, '[cat] found a seeded CN system category');
  await call('PUT', `/api/categories/${sys.id}`, { slug: 'hacked', type: 'income', locale: 'US', label_en: 'Renamed', is_cogs: true });
  const sysAfter = db.prepare('SELECT slug, type, locale, label_en, is_cogs FROM categories WHERE id = ?').get(sys.id);
  ok(sysAfter.slug === sys.slug && sysAfter.type === sys.type && sysAfter.locale === sys.locale,
    '[cat] system category: slug/type/locale immutable via update');
  ok(sysAfter.label_en === 'Renamed' && sysAfter.is_cogs === 1, '[cat] system category: label + is_cogs ARE editable');
  await expectThrow(() => call('DELETE', `/api/categories/${sys.id}`, null), '[cat] system category delete blocked');

  // user category delete works
  await call('DELETE', `/api/categories/${created.id}`, null);
  ok(!(await call('GET', '/api/categories?locale=CN', null)).some((c) => c.id === created.id), '[cat] user category deleted');

  // reset: removes ONLY user categories for the locale, returns the count, keeps system rows.
  // After delete(created) the only user category left is cogsCat → add one more → reset removes exactly 2.
  await call('POST', '/api/categories', { locale: 'CN', type: 'income', slug: 'unit-test-extra', label_en: 'Extra' });
  const sysBefore = db.prepare("SELECT COUNT(*) AS c FROM categories WHERE locale='CN' AND is_system=1").get().c;
  const reset = await call('POST', '/api/categories/reset', { locale: 'CN' });
  ok(reset?.success && reset.removedUserCategories === 2, `[cat] reset removed exactly the 2 user categories, got ${JSON.stringify(reset)}`);
  ok(db.prepare("SELECT COUNT(*) AS c FROM categories WHERE locale='CN' AND is_system=0").get().c === 0, '[cat] reset left zero user categories');
  ok(db.prepare("SELECT COUNT(*) AS c FROM categories WHERE locale='CN' AND is_system=1").get().c === sysBefore, '[cat] reset preserved system categories');
}

// ───────────────────────── products (per-item unit master data) ─────────────────────────
{
  freshDb();
  const mkProduct = async (body) => { await sleep(2); return call('POST', '/api/products', body); };

  ok((await call('GET', '/api/products', null)).length === 0, '[prod] list starts empty');

  // create defaults: unit→piece, is_service→false, is_active→true; provided cost kept
  const p1 = await mkProduct({ name: 'Widget', default_unit_cost: 12.5 });
  ok(p1?.success && p1.id, `[prod] create → {success,id}, got ${JSON.stringify(p1)}`);
  const w = (await call('GET', '/api/products', null)).find((p) => p.id === p1.id);
  ok(w && w.unit === 'piece' && w.default_unit_cost === 12.5, '[prod] create defaults unit=piece, cost kept');
  ok(typeof w.is_service === 'boolean' && typeof w.is_active === 'boolean', '[prod] is_service/is_active coerced to booleans');
  ok(w.is_service === false && w.is_active === true, '[prod] defaults is_service=false, is_active=true');

  // unit whitelist: invalid throws; valid accepted
  await expectThrow(() => call('POST', '/api/products', { name: 'Bad', unit: 'parsec' }), '[prod] invalid unit throws');
  const p2 = await mkProduct({ name: 'Sand', unit: 'kg', default_unit_cost: 3 });
  ok((await call('GET', '/api/products', null)).find((p) => p.id === p2.id).unit === 'kg', '[prod] valid unit kg accepted');

  // cost coercion: negative → 0; NaN → 0
  const pNeg = await mkProduct({ name: 'Neg', default_unit_cost: -5 });
  const pNaN = await mkProduct({ name: 'NaN', default_unit_cost: 'abc' });
  const afterCost = await call('GET', '/api/products', null);
  ok(afterCost.find((p) => p.id === pNeg.id).default_unit_cost === 0, '[prod] negative cost coerced to 0');
  ok(afterCost.find((p) => p.id === pNaN.id).default_unit_cost === 0, '[prod] NaN cost coerced to 0');

  // service + inactive flags persist
  const svc = await mkProduct({ name: 'Consulting', unit: 'hour', is_service: true });
  const inact = await mkProduct({ name: 'Old', is_active: false });
  const afterFlags = await call('GET', '/api/products', null);
  ok(afterFlags.find((p) => p.id === svc.id).is_service === true, '[prod] is_service=true persists');
  ok(afterFlags.find((p) => p.id === inact.id).is_active === false, '[prod] is_active=false persists');

  // name required (create + update); update validates unit; missing id throws
  await expectThrow(() => call('POST', '/api/products', { name: '   ' }), '[prod] blank name throws');
  await expectThrow(() => call('PUT', `/api/products/${p1.id}`, { name: '' }), '[prod] update blank name throws');
  await expectThrow(() => call('PUT', `/api/products/${p1.id}`, { unit: 'parsec' }), '[prod] update invalid unit throws');
  await expectThrow(() => call('PUT', '/api/products/nope', { name: 'x' }), '[prod] update missing id throws');

  // update applies; delete removes; delete missing throws
  await call('PUT', `/api/products/${p1.id}`, { name: 'Widget v2', unit: 'box', default_unit_cost: 9 });
  const upd = (await call('GET', '/api/products', null)).find((p) => p.id === p1.id);
  ok(upd.name === 'Widget v2' && upd.unit === 'box' && upd.default_unit_cost === 9, '[prod] update applied');
  await call('DELETE', `/api/products/${p2.id}`, null);
  ok(!(await call('GET', '/api/products', null)).some((p) => p.id === p2.id), '[prod] delete removes row');
  await expectThrow(() => call('DELETE', '/api/products/nope', null), '[prod] delete missing throws');
}

// ───────────── inventory summary (per-product on-hand + tax-exclusive cost) ─────────────
{
  freshDb();
  const mkProduct = async (body) => { await sleep(2); return (await call('POST', '/api/products', body)).id; };
  const byId = (details, id) => details.find((d) => d.product_id === id);

  // P1 weighted-avg basis (default_unit_cost=0); P2 explicit default cost overrides avg;
  // P5 sells out (onHand 0 → excluded); P3 service / P4 inactive → excluded.
  const P1 = await mkProduct({ name: 'Steel', unit: 'kg', default_unit_cost: 0 });
  const P2 = await mkProduct({ name: 'Coal', unit: 'ton', default_unit_cost: 50 });
  const P5 = await mkProduct({ name: 'Flux', unit: 'bag', default_unit_cost: 0 });
  const P3 = await mkProduct({ name: 'Install', unit: 'hour', is_service: true });
  const P4 = await mkProduct({ name: 'Retired', unit: 'box', is_active: false });

  // purchases (qty in). P1 totalAmount 1130 vs amountWithoutTax 1000 → cost basis must use the
  // tax-EXCLUSIVE 1000 (avg 100), NOT 1130. P2's amountWithoutTax (1800) is ignored (default wins).
  await call('POST', '/api/purchases', { id: 'in-p1', date: `${YEAR}-02-01`, supplier: 'S', tons: 10, totalAmount: 1130, amountWithoutTax: 1000, product_id: P1 });
  await call('POST', '/api/purchases', { id: 'in-p2', date: `${YEAR}-02-01`, supplier: 'S', tons: 9, totalAmount: 2260, amountWithoutTax: 1800, product_id: P2 });
  await call('POST', '/api/purchases', { id: 'in-p5', date: `${YEAR}-02-01`, supplier: 'S', tons: 3, totalAmount: 100, amountWithoutTax: 90, product_id: P5 });
  await call('POST', '/api/purchases', { id: 'in-p3', date: `${YEAR}-02-01`, supplier: 'S', tons: 5, totalAmount: 100, amountWithoutTax: 90, product_id: P3 });
  await call('POST', '/api/purchases', { id: 'in-p4', date: `${YEAR}-02-01`, supplier: 'S', tons: 5, totalAmount: 100, amountWithoutTax: 90, product_id: P4 });

  // sales (qty out)
  await call('POST', '/api/sales', { id: 'out-p1', date: `${YEAR}-03-01`, customer: 'C', tons: 4, totalAmount: 800, product_id: P1 });
  await call('POST', '/api/sales', { id: 'out-p2', date: `${YEAR}-03-01`, customer: 'C', tons: 2, totalAmount: 400, product_id: P2 });
  await call('POST', '/api/sales', { id: 'out-p5', date: `${YEAR}-03-01`, customer: 'C', tons: 3, totalAmount: 200, product_id: P5 });

  const inv = await call('GET', '/api/inventory/summary', null);
  ok(inv && Array.isArray(inv.details), '[inv] summary shape {inStockCount,totalInventoryCost,details}');

  // only P1 + P2 in stock (P5 onHand 0; P3 service; P4 inactive)
  ok(inv.inStockCount === 2, `[inv] inStockCount=2 (in-stock, non-service, active), got ${inv.inStockCount}`);
  ok(inv.details.length === 2, `[inv] details has 2 rows, got ${inv.details.length}`);
  ok(!byId(inv.details, P5), '[inv] sold-out product excluded (qtyOnHand<=0)');
  ok(!byId(inv.details, P3), '[inv] service product excluded');
  ok(!byId(inv.details, P4), '[inv] inactive product excluded');

  const d1 = byId(inv.details, P1);
  const d2 = byId(inv.details, P2);
  ok(d1 && approx(d1.qtyOnHand, 6), `[inv] P1 qtyOnHand = 10 - 4 = 6, got ${d1?.qtyOnHand}`);
  // tax-exclusive + weighted-average: 1000/10 = 100 (would be 113 if it used totalAmount 1130)
  ok(d1 && approx(d1.unitCost, 100), `[inv] P1 unitCost = 1000/10 = 100 (tax-exclusive avg, not 113), got ${d1?.unitCost}`);
  ok(d1 && approx(d1.lineCost, 600), `[inv] P1 lineCost = 6 × 100 = 600, got ${d1?.lineCost}`);
  ok(d1 && d1.unit === 'kg', '[inv] P1 keeps its own unit (kg)');

  ok(d2 && approx(d2.qtyOnHand, 7), `[inv] P2 qtyOnHand = 9 - 2 = 7, got ${d2?.qtyOnHand}`);
  // explicit default_unit_cost 50 overrides the weighted average (1800/9 = 200)
  ok(d2 && approx(d2.unitCost, 50), `[inv] P2 unitCost = default 50 (overrides avg 200), got ${d2?.unitCost}`);
  ok(d2 && approx(d2.lineCost, 350), `[inv] P2 lineCost = 7 × 50 = 350, got ${d2?.lineCost}`);
  ok(d2 && d2.unit === 'ton', '[inv] P2 keeps its own unit (ton)');

  // money IS summable across products; quantities are NOT merged across units
  ok(approx(inv.totalInventoryCost, 950), `[inv] totalInventoryCost = 600 + 350 = 950, got ${inv.totalInventoryCost}`);
  ok(d1.unit !== d2.unit, '[inv] different-unit products stay separate rows (kg vs ton, never summed)');
}

// §2B Batch 3 — relative-date helper so aging tests never go stale. Use mid-bucket offsets
// (15/45/75/120), NEVER boundary values (30/60/90): the handler's daysDiff is a floor, so a
// boundary row could flip buckets on a sub-day/UTC edge. Both test and handler derive dates
// via toISOString() UTC, so daysDiff is exact integer days and mid-bucket offsets absorb edges.
const dayMs = 86400000;
const isoDay = (offset) => new Date(Date.now() - offset * dayMs).toISOString().split('T')[0];

// ───────────────────────── alerts (no create route → seed directly) ─────────────────────────
{
  const db = freshDb();
  // alerts has no POST/create handler → arrange via direct insert. Explicit DISTINCT created_at
  // makes ORDER BY created_at DESC deterministic (avoids same-second ties from datetime('now')).
  // created_at may be fixed strings here: it drives ordering only, never aging.
  const seed = (title, isRead, isDismissed, createdAt) =>
    Number(db.prepare(
      'INSERT INTO alerts (type, severity, title, body, is_read, is_dismissed, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)'
    ).run('test', 'info', title, 'body', isRead, isDismissed, createdAt).lastInsertRowid);
  const A1 = seed('A1-newest-unread', 0, 0, '2024-01-01 00:00:03');
  const A2 = seed('A2-mid-unread',    0, 0, '2024-01-01 00:00:02');
  const A3 = seed('A3-oldest-read',   1, 0, '2024-01-01 00:00:01');

  // list: only non-dismissed, newest-first
  const list = await call('GET', '/api/alerts', null);
  ok(list.length === 3, `[alert] list → 3 non-dismissed, got ${list.length}`);
  ok(list[0].id === A1 && list[1].id === A2 && list[2].id === A3, '[alert] list ordered created_at DESC');

  // unread_only → is_read=0 AND not dismissed (A3 is read → excluded)
  const unread = await call('GET', '/api/alerts?unread_only=true', null);
  ok(unread.length === 2 && !unread.some((a) => a.id === A3), '[alert] unread_only excludes read A3');

  // count = unread AND undismissed
  ok((await call('GET', '/api/alerts/count', null)).count === 2, '[alert] count = 2 unread+undismissed');

  // limit caps rows
  ok((await call('GET', '/api/alerts?limit=1', null)).length === 1, '[alert] limit=1 → 1 row');

  // non-numeric id → throw (parseInt → NaN)
  await expectThrow(() => call('PUT', '/api/alerts/abc/read', null), '[alert] read non-numeric id throws');
  await expectThrow(() => call('DELETE', '/api/alerts/xyz', null), '[alert] dismiss non-numeric id throws');

  // mark one read → count drops
  await call('PUT', `/api/alerts/${A1}/read`, null);
  ok((await call('GET', '/api/alerts/count', null)).count === 1, '[alert] after read A1 → count 1');

  // read-all → count 0
  await call('PUT', '/api/alerts/read-all', null);
  ok((await call('GET', '/api/alerts/count', null)).count === 0, '[alert] read-all → count 0');

  // dismiss → drops from list
  await call('DELETE', `/api/alerts/${A2}`, null);
  const afterDismiss = await call('GET', '/api/alerts', null);
  ok(afterDismiss.length === 2 && !afterDismiss.some((a) => a.id === A2), '[alert] dismissed A2 removed from list');
}

// ───────────── receivables summary (aging via relative dates; sales round-trip) ─────────────
{
  const db = freshDb();
  // base records via real round-trip: create (defaults payment_status='unpaid', paid_amount=0) + payment route.
  // `date` is not aging-relevant; only due_date (set below) is. isoDay used just for a valid date.
  await call('POST', '/api/sales', { id: 's1', date: isoDay(30), customer: 'Cust-A', tons: 1, totalAmount: 1000 });
  await call('POST', '/api/sales', { id: 's2', date: isoDay(30), customer: 'Cust-B', tons: 1, totalAmount: 2000 });
  await call('POST', '/api/sales', { id: 's3', date: isoDay(30), customer: 'Cust-C', tons: 1, totalAmount: 800 });
  ok((await call('PUT', '/api/sales/s2/payment', { paid_amount: 500 })).payment_status === 'partial', '[recv] s2 → partial');
  ok((await call('PUT', '/api/sales/s3/payment', { paid_amount: 800 })).payment_status === 'paid', '[recv] s3 → paid');

  const r1 = await call('GET', '/api/receivables/summary', null);
  ok(approx(r1.totalReceivable, 2500), `[recv] totalReceivable = 1000 + 1500 = 2500, got ${r1.totalReceivable}`);
  ok(r1.details.length === 2 && !r1.details.some((d) => d.id === 's3'), '[recv] details = unpaid>0 only (s3 paid excluded)');
  // collectionRate = totalPaid/totalSales × 100 = 1300/3800 ≈ 34.21 (handler rounds to 2dp)
  ok(approx(r1.collectionRate, 34.21), `[recv] collectionRate = 1300/3800 ≈ 34.21, got ${r1.collectionRate}`);
  // topCustomers ranked by unpaid desc: Cust-B (1500) > Cust-A (1000); Cust-C (0) absent
  ok(r1.topCustomers[0].name === 'Cust-B' && approx(r1.topCustomers[0].amount, 1500), '[recv] topCustomers[0] = Cust-B 1500');
  ok(r1.topCustomers[1].name === 'Cust-A' && r1.topCustomers.length === 2, '[recv] topCustomers[1] = Cust-A, length 2');

  // aging: set due_dates via direct UPDATE (no handler sets due_date). Relative, mid-bucket.
  db.prepare('UPDATE sales SET due_date = ? WHERE id = ?').run(isoDay(45), 's1');   // overdue → 31-60
  db.prepare('UPDATE sales SET due_date = ? WHERE id = ?').run(isoDay(-10), 's2');  // future → not overdue
  db.prepare('UPDATE sales SET due_date = ? WHERE id = ?').run(isoDay(20), 's3');   // paid + due_date → must NOT inflate

  const r2 = await call('GET', '/api/receivables/summary', null);
  ok(approx(r2.totalReceivable, 2500), `[recv] paid s3 w/ due_date does NOT inflate totalReceivable, got ${r2.totalReceivable}`);
  ok(approx(r2.totalOverdue, 1000), `[recv] totalOverdue = s1 only (s2 future) = 1000, got ${r2.totalOverdue}`);
  ok(approx(r2.agingBuckets['31-60'], 1000), `[recv] s1 (45d overdue) lands in 31-60, got ${r2.agingBuckets['31-60']}`);
  ok(approx(r2.agingBuckets['0-30'], 0) && approx(r2.agingBuckets['61-90'], 0) && approx(r2.agingBuckets['90+'], 0),
    '[recv] no other aging buckets populated');

  // collectionRate = 100 when there are no sales at all
  freshDb();
  const empty = await call('GET', '/api/receivables/summary', null);
  ok(empty.collectionRate === 100 && approx(empty.totalReceivable, 0) && empty.details.length === 0,
    '[recv] no sales → collectionRate 100, receivable 0, no details');
}

// ───────────── payables summary (symmetric to receivables; 61-90 bucket for variety) ─────────────
{
  const db = freshDb();
  await call('POST', '/api/purchases', { id: 'p1', date: isoDay(30), supplier: 'Supp-A', tons: 1, totalAmount: 1000 });
  await call('POST', '/api/purchases', { id: 'p2', date: isoDay(30), supplier: 'Supp-B', tons: 1, totalAmount: 2000 });
  await call('POST', '/api/purchases', { id: 'p3', date: isoDay(30), supplier: 'Supp-C', tons: 1, totalAmount: 800 });
  ok((await call('PUT', '/api/purchases/p2/payment', { paid_amount: 500 })).payment_status === 'partial', '[pay] p2 → partial');
  ok((await call('PUT', '/api/purchases/p3/payment', { paid_amount: 800 })).payment_status === 'paid', '[pay] p3 → paid');

  const q1 = await call('GET', '/api/payables/summary', null);
  ok(approx(q1.totalPayable, 2500), `[pay] totalPayable = 1000 + 1500 = 2500, got ${q1.totalPayable}`);
  ok(q1.details.length === 2 && !q1.details.some((d) => d.id === 'p3'), '[pay] details = unpaid>0 only (p3 paid excluded)');
  ok(approx(q1.paymentRate, 34.21), `[pay] paymentRate = 1300/3800 ≈ 34.21, got ${q1.paymentRate}`);
  ok(q1.topSuppliers[0].name === 'Supp-B' && approx(q1.topSuppliers[0].amount, 1500), '[pay] topSuppliers[0] = Supp-B 1500');
  ok(q1.topSuppliers[1].name === 'Supp-A' && q1.topSuppliers.length === 2, '[pay] topSuppliers[1] = Supp-A, length 2');

  // aging — 61-90 bucket here (mid-bucket offset 75) for variety vs receivables' 31-60
  db.prepare('UPDATE purchases SET due_date = ? WHERE id = ?').run(isoDay(75), 'p1');  // overdue → 61-90
  db.prepare('UPDATE purchases SET due_date = ? WHERE id = ?').run(isoDay(-5), 'p2');  // future
  db.prepare('UPDATE purchases SET due_date = ? WHERE id = ?').run(isoDay(20), 'p3');  // paid + due_date

  const q2 = await call('GET', '/api/payables/summary', null);
  ok(approx(q2.totalPayable, 2500), `[pay] paid p3 w/ due_date does NOT inflate totalPayable, got ${q2.totalPayable}`);
  ok(approx(q2.totalOverdue, 1000), `[pay] totalOverdue = p1 only = 1000, got ${q2.totalOverdue}`);
  ok(approx(q2.agingBuckets['61-90'], 1000), `[pay] p1 (75d overdue) lands in 61-90, got ${q2.agingBuckets['61-90']}`);
  ok(approx(q2.agingBuckets['0-30'], 0) && approx(q2.agingBuckets['31-60'], 0) && approx(q2.agingBuckets['90+'], 0),
    '[pay] no other aging buckets populated');

  // paymentRate = 100 when no purchases
  freshDb();
  const empty = await call('GET', '/api/payables/summary', null);
  ok(empty.paymentRate === 100 && approx(empty.totalPayable, 0) && empty.details.length === 0,
    '[pay] no purchases → paymentRate 100, payable 0, no details');
}

// ───────────────────────── §2B Batch 4: settings + reports + batch ─────────────────────────

// ───────────────────────── settings (whitelist read+write filter, JSON round-trip) ─────────────────────────
{
  const db = freshDb();

  // save then get round-trips a whitelisted object + scalar; JSON value preserved
  await call('PUT', '/api/settings', { company_info: { name: 'Acme', industry: 'Steel' }, accounting_locale: 'US' });
  const s1 = await call('GET', '/api/settings', null);
  ok(s1.company_info && s1.company_info.name === 'Acme' && s1.company_info.industry === 'Steel', '[set] company_info object round-trips (JSON preserved)');
  ok(s1.accounting_locale === 'US', '[set] scalar accounting_locale round-trips');

  // save-time whitelist enforcement: non-whitelisted key skipped, whitelisted kept
  const saveRes = await call('PUT', '/api/settings', { evil_key: 'pwned', currency: 'USD' });
  ok(saveRes?.success === true, '[set] save returns {success:true}');
  const s2 = await call('GET', '/api/settings', null);
  ok(s2.currency === 'USD' && !('evil_key' in s2), '[set] save skips non-whitelisted evil_key, keeps currency');

  // read-time whitelist enforcement: a non-whitelisted row already in DB is filtered out by get
  db.prepare('INSERT INTO settings (key, value) VALUES (?, ?)').run('not_allowed_key', JSON.stringify('x'));
  ok(!('not_allowed_key' in (await call('GET', '/api/settings', null))), '[set] get filters non-whitelisted DB rows');

  // oversized value (>10000 serialized) is skipped + named in warnings; prior value left untouched
  const big = await call('PUT', '/api/settings', { company_info: 'x'.repeat(10001) });
  ok(typeof big.warnings === 'string' && big.warnings.includes('company_info'), '[set] oversized value → warnings names company_info');
  const s3 = await call('GET', '/api/settings', null);
  ok(s3.company_info && s3.company_info.name === 'Acme', '[set] oversized value skipped — prior company_info unchanged (not overwritten)');

  // non-object / array body throws
  await expectThrow(() => call('PUT', '/api/settings', [1, 2]), '[set] array body throws');

  // null body is a no-op per existing contract (body || {} → {})
  ok((await call('PUT', '/api/settings', null))?.success === true, '[set] null body → {success:true} no-op');
}

// ───────────── reports (structural + non-tax invariants ONLY; never lock T11/T12 amounts) ─────────────
{
  freshDb();
  const YR = '2023', FROM = '2023-01-01', TO = '2023-12-31';

  // types: locale routing
  const cnTypes = await call('GET', '/api/reports/types?locale=CN', null);
  ok(Array.isArray(cnTypes) && cnTypes.some((t) => t.id === 'income-statement'), '[rep] CN types include income-statement');
  const usTypes = await call('GET', '/api/reports/types?locale=US', null);
  ok(Array.isArray(usTypes) && usTypes.length > 0 && usTypes.some((t) => t.id === 'schedule-c'), '[rep] US types non-empty (schedule-c) — smoke');
  ok((await call('GET', '/api/reports/types?locale=XX', null)).length === 0, '[rep] unknown locale types → []');
  ok((await call('GET', '/api/reports/types', null)).some((t) => t.id === 'income-statement'), '[rep] no locale → defaults to CN types');

  // seed income via real round-trip. amount(gross) deliberately ≠ amount_net so salesRevenue proves NET basis.
  await call('POST', '/api/transactions', { id: 'rep-i1', type: 'income', date: '2023-03-01', amount: 6000, amount_net: 5000 });
  await call('POST', '/api/transactions', { id: 'rep-i2', type: 'income', date: '2023-07-01', amount: 3000, amount_net: 2500 });

  const rep = await call('POST', '/api/reports/generate', { locale: 'CN', year: YR, from: FROM, to: TO });
  // structure
  ok(rep.locale === 'CN', '[rep] generate result.locale === CN');
  ok(rep.period && rep.period.from === FROM && rep.period.to === TO && rep.period.year === YR, '[rep] period echoes from/to/year');
  ok(Array.isArray(rep.reportTypes) && rep.reportTypes.length > 0, '[rep] reportTypes present');
  ok(Array.isArray(rep.monthlyBreakdown) && rep.monthlyBreakdown.length === 12, '[rep] monthlyBreakdown has 12 months');
  ok(Array.isArray(rep.warnings), '[rep] warnings is an array');
  ok(rep.incomeStatement && rep.vatSummary && rep.taxInclusiveSummary, '[rep] incomeStatement + vatSummary + taxInclusiveSummary present');
  // non-tax invariants (income-only seed): salesRevenue = Σ amount_net = 7500 (NOT gross 9000); costOfSales 0; grossProfit = revenue
  ok(approx(rep.incomeStatement.salesRevenue, 7500), `[rep] salesRevenue = Σ amount_net (5000+2500) = 7500 NET (not gross 9000), got ${rep.incomeStatement.salesRevenue}`);
  ok(approx(rep.incomeStatement.costOfSales, 0), `[rep] income-only seed → costOfSales 0, got ${rep.incomeStatement.costOfSales}`);
  ok(approx(rep.incomeStatement.grossProfit, rep.incomeStatement.salesRevenue), '[rep] grossProfit === salesRevenue (no COGS)');
  // tax/net fields exist but ARE NOT value-locked (T11/T12 unsettled) — type-only assertion
  ok(typeof rep.incomeStatement.incomeTax === 'number'
    && typeof rep.incomeStatement.netProfit === 'number'
    && typeof rep.incomeStatement.taxSurcharge === 'number', '[rep] incomeTax/netProfit/taxSurcharge are numbers (values intentionally NOT locked)');

  // unsupported locale throws
  await expectThrow(() => call('POST', '/api/reports/generate', { locale: 'XX', year: YR, from: FROM, to: TO }), '[rep] unsupported locale generate throws');

  // US smoke: locale echo only (engine-specific shape intentionally NOT asserted)
  ok((await call('POST', '/api/reports/generate', { locale: 'US', year: YR, from: FROM, to: TO })).locale === 'US', '[rep] US generate result.locale === US (smoke)');
}

// ───────────────────────── batch import (sales + purchases bulk) ─────────────────────────
{
  freshDb();
  const due = '2025-09-30'; // fixed date — persistence only, not aging

  // valid batchSales — omit payment/invoice fields to exercise defaults; set due_date (batch is the only writer)
  const okRes = await call('POST', '/api/sales/batch', {
    records: [
      { id: 'bs1', date: '2023-01-05', customer: 'C1', tons: 2, totalAmount: 1000, due_date: due },
      { id: 'bs2', date: '2023-01-06', customer: 'C2', tons: 3, totalAmount: 2000, due_date: due },
    ],
  });
  ok(okRes.success === 2 && okRes.failed === 0, `[batch] sales valid → success 2 failed 0, got ${JSON.stringify(okRes)}`);
  const sales = await call('GET', '/api/sales', null);
  const bs1 = sales.find((s) => s.id === 'bs1');
  ok(sales.length === 2 && bs1, '[batch] GET /api/sales reflects 2 inserted');
  ok(bs1.payment_status === 'paid' && approx(bs1.paid_amount, 1000), '[batch] sales defaults payment_status=paid, paid_amount=totalAmount');
  ok(bs1.invoiceStatus === '待开', '[batch] sales default invoiceStatus=待开');
  ok(bs1.due_date === due, '[batch] sales due_date persisted');

  // partial: valid + missing-date + negative-tons
  freshDb();
  const part = await call('POST', '/api/sales/batch', {
    records: [
      { id: 'v1', date: '2023-02-01', customer: 'Ok', tons: 1, totalAmount: 500 },
      { id: 'bad-date', customer: 'NoDate', tons: 1, totalAmount: 100 },                 // missing date
      { id: 'bad-tons', date: '2023-02-02', customer: 'Neg', tons: -5, totalAmount: 100 }, // negative tons
    ],
  });
  ok(part.success === 1 && part.failed === 2, `[batch] partial → success 1 failed 2, got ${JSON.stringify(part)}`);
  ok(Array.isArray(part.errors) && part.errors.length === 2 && part.errors.every((e) => e.row && Array.isArray(e.errors)), '[batch] errors carry {row, errors[]}');
  ok((await call('GET', '/api/sales', null)).length === 1, '[batch] only the valid row inserted');

  // empty + over-cap throw
  await expectThrow(() => call('POST', '/api/sales/batch', { records: [] }), '[batch] empty records throws');
  const over = Array.from({ length: 501 }, (_, i) => ({ id: `o${i}`, date: '2023-01-01', tons: 1, totalAmount: 1 }));
  await expectThrow(() => call('POST', '/api/sales/batch', { records: over }), '[batch] >500 records throws');

  // batchPurchases symmetric smoke
  freshDb();
  const pRes = await call('POST', '/api/purchases/batch', {
    records: [{ id: 'bp1', date: '2023-03-01', supplier: 'S1', tons: 4, totalAmount: 1500, due_date: due }],
  });
  ok(pRes.success === 1 && pRes.failed === 0, `[batch] purchases valid → success 1, got ${JSON.stringify(pRes)}`);
  const purch = await call('GET', '/api/purchases', null);
  const bp1 = purch.find((p) => p.id === 'bp1');
  ok(purch.length === 1 && bp1 && bp1.due_date === due, '[batch] GET /api/purchases reflects insert + due_date persisted');
  ok(bp1.invoiceStatus === '已收', '[batch] purchases default invoiceStatus=已收');
}

if (failures.length) {
  console.error(`✗ handlers: ${failures.length} assertion(s) failed:`);
  for (const f of failures) console.error('  - ' + f);
  process.exit(1);
}
console.log('✓ handlers: round-trips passed (transactions/purchases/sales CRUD+payment+validation + dashboard e2e + router + categories/products/inventory + alerts + receivables/payables aging + settings + reports(structural) + batch) via real dispatch on :memory: DB');
