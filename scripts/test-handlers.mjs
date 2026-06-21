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
//       collectionRate·paymentRate（无单据=null）/ topCustomers·topSuppliers 排名 / 相对日期 aging
//       buckets（mid-bucket offset，绝不写固定过期日）/ 已付且有 due_date 不 inflate 应收·应付）。
// 覆盖（第四批 §2B Batch 4）：settings（GET/PUT 白名单读写双向过滤 / JSON 往返 / oversized→warnings /
//       array body throw / null body no-op）· reports（types locale 路由 + unknown→[] / generate 结构 +
//       period echo + monthlyBreakdown12 / **非税不变量** salesRevenue=Σamount_net·costOfSales=0·
//       grossProfit=revenue / incomeTax·netProfit·taxSurcharge 仅 typeof number 不锁值（T11/T12 不锁）/
//       unsupported throw / US smoke）· batch（sales·purchases 批量插入 / success·failed·errors / 部分成功 /
//       empty·>500 throw / 默认值 payment_status=paid·invoiceStatus / due_date persisted）。
// 覆盖（第五批 §2B Batch 5）：conversations（create/list 字段持久化 + 列含 created_at/updated_at /
//       list 排序按 updated_at DESC〔直插 updated_at 保证确定性，不靠真实时间〕/ append 缺会话 throw +
//       seq 顺序 + role 归一化〔非 model→user〕/ auto-title〔首条 user 派生·≤40·空白折叠·后续不覆盖·
//       model-first 保持 null〕/ toolTrace array 往返〔无则不带 key〕/ rename〔空/纯空白→null〕/ delete + CASCADE 删消息）。
// 覆盖（第六批 §2B mileage + homeOffice）：mileage（create 校验 date/miles>0 / one-way·round-trip deduction
//       〔**generated column** miles·rate_per_mile·(1+round_trip)，用显式 rate=0.5 锁公式·不锁 0.67 默认〕/
//       summary?year= 年份过滤 + trips·totalMiles·totalDeduction / update 重算 generated / delete）·homeOffice
//       （get 默认结构 / simplified·cap·actual deduction〔显式 rate=4·max=250 锁算法·不锁 5/300 默认〕/ COALESCE
//       partial 保留未传字段 / invalid method CHECK throw）。**只用显式非默认输入锁算法，绝不锁 IRS 政策默认常量。**
// 覆盖（第七批 §2B legacy data-migration handler）：electron/handlers/migrations.js（数据迁移 handler，
//       ≠ schema 迁移 test-migrations.mjs）。detectLegacy（空 head 库 exists:true + 计数全 0 + hasLegacy:false /
//       seed 后 pending 正确）· migrateAll〔sales→income · purchases→expense · 字段映射 totalAmount→amount ·
//       amountWithoutTax→amount_net · customer/supplier→counterparty · invoiceStatus 已开·已收→issued /
//       待开·待收→pending / 其它·null→n/a · source_meta 含 migrated_from·legacy_id · category 已赋值且为真实类别
//       〔不锁具体 id〕· 无 body 时默认 currency=CNY〕· idempotency（重跑迁 0 · 无重复 txn · legacy_migrations 数不变）·
//       detect-after-run（migrated=total · pending=0 · hasLegacy:false）· rollback（removed 正确 · 删迁移 txn ·
//       清 legacy_migrations · 原 sales/purchases 保留）· rerun-after-rollback（映射真清 · 可再迁）· body override
//       （defaultIncome/ExpenseCategoryId + currency 采用，category id 不锁默认值）。**只锁现有行为，不锁默认 category id。**
// 覆盖（第八批 §2B documents handler — fs-free 子集）：electron/handlers/documents.js。next-number（空库
//       PREFIX-YYYY-0001 / 同类型已有编号后缀递增 / 缺·非法 type throw）· create（doc_type·doc_number·
//       customer_name·doc_date 必填校验 / 成功 {success,id} / status 默认 draft / acc_locale 创建冻结）·
//       DOC_NUMBER_EXISTS（同 doc_type+doc_number 重复 throw / 复合唯一：不同 doc_type 同号放行）· get/list
//       （header+items / ?type 过滤·all·无 type 全量 / 非法 type throw / 不存在 'Document not found' / doc_date DESC）·
//       items+totals（sumTotals 只对已存 amount·tax_amount 求和〔不重算 qty×price〕/ line_no 排序 / 空白 description
//       行 sanitizeItems 丢弃）· update（draft 改字段·items·notes 重算 totals / acc_locale 更新忽略·冻结 /
//       空 body no-op / 状态机 draft→issued→void·void 终态·非法值 throw / 非 draft 改字段 'Only draft …'）·
//       updateTaxInvoice **fs-free 子集**（首次设 issued/number/date·首次设合法 path〔oldPathToDelete 恒 null·不触
//       safeDeleteAttachment〕/ 空 body no-op / issued 布尔强转 / INVALID_ATTACHMENT_PATH 纯正则先抛 / ATTACHMENT_IN_USE
//       共享守卫先抛 / void→DOC_VOID_TAX_INVOICE_READONLY）· remove **fs-free 子集**（draft 删除 + items FK CASCADE /
//       不存在 'Document not found' / issued→DOC_ISSUED_VOID_FIRST / void 且**无附件**可删）。
//       **out-of-scope（本批故意不覆盖，留真 Electron e2e / attachment IPC）**：updateTaxInvoice 替换·清除已有
//       attachment path 时的 safeDeleteAttachment fs 分支；remove 带 tax_invoice_attachment_path 的 void 单据时的
//       safeDeleteAttachment fs 分支。两者需 require('electron').app（本测试环境为 undefined）→ 不 mock 整个 electron、不做真实 fs。
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
const { computeOperatingCashflow } = require(join(ROOT, 'electron/reports/_cashflow.js'));
const aiCore = require(join(ROOT, 'electron/ai/index.js'));

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

// ───────────── due_date round-trip (single-record create/update; gap A) ─────────────
// Single-record create/update now carry due_date; update only sets it when explicitly
// provided (omitting it preserves the existing value, never clears it). list = SELECT *.
{
  freshDb();
  const DUE1 = `${YEAR}-07-15`, DUE2 = `${YEAR}-08-20`;
  const getPur = async (id) => (await call('GET', '/api/purchases', null)).find((p) => p.id === id);
  const getSal = async (id) => (await call('GET', '/api/sales', null)).find((s) => s.id === id);

  // purchases
  await call('POST', '/api/purchases', { id: 'pd-1', date: `${YEAR}-06-01`, supplier: 'DueCo', tons: 1, totalAmount: 100, due_date: DUE1 });
  ok((await getPur('pd-1')).due_date === DUE1, '[pur] create persists due_date');
  await call('PUT', '/api/purchases/pd-1', { date: `${YEAR}-06-02`, supplier: 'DueCo2', tons: 2, totalAmount: 200 });
  ok((await getPur('pd-1')).due_date === DUE1, '[pur] update WITHOUT due_date preserves existing (not cleared)');
  await call('PUT', '/api/purchases/pd-1', { date: `${YEAR}-06-02`, supplier: 'DueCo2', tons: 2, totalAmount: 200, due_date: DUE2 });
  ok((await getPur('pd-1')).due_date === DUE2, '[pur] update WITH due_date changes it');
  await call('POST', '/api/purchases', { id: 'pd-0', date: `${YEAR}-06-01`, supplier: 'NoDue', tons: 1, totalAmount: 100 });
  ok((await getPur('pd-0')).due_date === null, '[pur] create WITHOUT due_date → null');

  // sales
  await call('POST', '/api/sales', { id: 'sd-1', date: `${YEAR}-06-01`, customer: 'DueCust', tons: 1, totalAmount: 100, due_date: DUE1 });
  ok((await getSal('sd-1')).due_date === DUE1, '[sal] create persists due_date');
  await call('PUT', '/api/sales/sd-1', { date: `${YEAR}-06-02`, customer: 'DueCust2', tons: 2, totalAmount: 200 });
  ok((await getSal('sd-1')).due_date === DUE1, '[sal] update WITHOUT due_date preserves existing (not cleared)');
  await call('PUT', '/api/sales/sd-1', { date: `${YEAR}-06-02`, customer: 'DueCust2', tons: 2, totalAmount: 200, due_date: DUE2 });
  ok((await getSal('sd-1')).due_date === DUE2, '[sal] update WITH due_date changes it');
  await call('POST', '/api/sales', { id: 'sd-0', date: `${YEAR}-06-01`, customer: 'NoDue', tons: 1, totalAmount: 100 });
  ok((await getSal('sd-0')).due_date === null, '[sal] create WITHOUT due_date → null');
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

// §2B Batch 2 note: products.create now appends a short random suffix to its Date.now() id
// (prod-<ts>-<rand>, mirroring documents.create), so rapid same-millisecond creates no longer
// collide on the PRIMARY KEY — the former sleep(2) spacing workaround is removed (the burst
// uniqueness test below exercises the hardened path directly).

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
  const mkProduct = async (body) => call('POST', '/api/products', body);

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

// ───────────────────────── accounts (cash/bank master data + opening balance, PR-7D-1 pipeline) ─────────────────────────
// 管道层 round-trip：证明账户/期初余额能录入·保存·读取·编辑·删除·停用，且边界守得住——
// 不接资产负债表、不 roll-up、不勾稽。锁住：create 默认值 / type 白名单（cash·bank）/ opening_balance
// 可负（透支）·NaN→0·缺省→0 / is_active 布尔强转回 list / name·type 校验 / partial update 不清空其它字段 /
// 编辑 name·type·note / 停用持久 / delete + delete-missing。
{
  freshDb();
  const mkAcct = async (body) => call('POST', '/api/accounts', body);

  ok((await call('GET', '/api/accounts', null)).length === 0, '[acct] list starts empty');

  // create defaults: type→cash, is_active→true; provided opening_balance/currency/date kept
  const a1 = await mkAcct({ name: '基本户', opening_balance: 1000.5, currency: 'CNY', opening_date: '2026-01-01' });
  ok(a1?.success && a1.id, `[acct] create → {success,id}, got ${JSON.stringify(a1)}`);
  const r1 = (await call('GET', '/api/accounts', null)).find((a) => a.id === a1.id);
  ok(r1 && r1.type === 'cash' && r1.opening_balance === 1000.5, '[acct] create defaults type=cash, opening_balance kept');
  ok(r1.currency === 'CNY' && r1.opening_date === '2026-01-01', '[acct] currency/opening_date persist');
  ok(typeof r1.is_active === 'boolean' && r1.is_active === true, '[acct] is_active coerced to boolean, defaults true');

  // type whitelist: invalid throws (handler guard before DB); bank accepted
  await expectThrow(() => call('POST', '/api/accounts', { name: 'Bad', type: 'crypto' }), '[acct] invalid type throws');
  const a2 = await mkAcct({ name: '招行', type: 'bank' });
  ok((await call('GET', '/api/accounts', null)).find((a) => a.id === a2.id).type === 'bank', '[acct] bank type accepted');

  // opening_balance: negative allowed (overdraft), NaN → 0, missing → 0
  const aNeg = await mkAcct({ name: '透支户', type: 'bank', opening_balance: -500 });
  const aNaN = await mkAcct({ name: 'NaN', opening_balance: 'abc' });
  const aMiss = await mkAcct({ name: 'NoBal' });
  const after = await call('GET', '/api/accounts', null);
  ok(after.find((a) => a.id === aNeg.id).opening_balance === -500, '[acct] negative opening_balance preserved (overdraft)');
  ok(after.find((a) => a.id === aNaN.id).opening_balance === 0, '[acct] NaN opening_balance coerced to 0');
  ok(after.find((a) => a.id === aMiss.id).opening_balance === 0, '[acct] missing opening_balance defaults to 0');

  // name required (create + update); update validates type; missing id throws
  await expectThrow(() => call('POST', '/api/accounts', { name: '   ' }), '[acct] blank name throws');
  await expectThrow(() => call('PUT', `/api/accounts/${a1.id}`, { name: '' }), '[acct] update blank name throws');
  await expectThrow(() => call('PUT', `/api/accounts/${a1.id}`, { type: 'gold' }), '[acct] update invalid type throws');
  await expectThrow(() => call('PUT', '/api/accounts/nope', { name: 'x' }), '[acct] update missing id throws');

  // partial update: only provided field changes; untouched fields preserved (not cleared)
  await call('PUT', `/api/accounts/${a1.id}`, { opening_balance: 2000 });
  const u1 = (await call('GET', '/api/accounts', null)).find((a) => a.id === a1.id);
  ok(u1.opening_balance === 2000 && u1.name === '基本户' && u1.currency === 'CNY' && u1.opening_date === '2026-01-01',
    '[acct] partial update changes only opening_balance, leaves name/currency/opening_date intact');

  // edit name + type + note together
  await call('PUT', `/api/accounts/${a1.id}`, { name: '基本户(改)', type: 'bank', note: '主账户' });
  const u2 = (await call('GET', '/api/accounts', null)).find((a) => a.id === a1.id);
  ok(u2.name === '基本户(改)' && u2.type === 'bank' && u2.note === '主账户', '[acct] edit applies name/type/note');

  // toggle active (停用) persists as boolean false
  await call('PUT', `/api/accounts/${a2.id}`, { is_active: false });
  ok((await call('GET', '/api/accounts', null)).find((a) => a.id === a2.id).is_active === false, '[acct] is_active=false (停用) persists');

  // delete removes; delete missing throws
  await call('DELETE', `/api/accounts/${a2.id}`, null);
  ok(!(await call('GET', '/api/accounts', null)).some((a) => a.id === a2.id), '[acct] delete removes row');
  await expectThrow(() => call('DELETE', '/api/accounts/nope', null), '[acct] delete missing throws');
}

// ───────────────────────── liabilities (loans / other liabilities ledger, PR-7D-2 pipeline) ─────────────────────────
// 管道层 round-trip：证明借款/其他负债能录入·保存·读取·编辑·删除·结清，且边界守得住——
// ≠ 采购应付（payables 另算）、不接资产负债表、不算利息、不做还款计划。锁住：create 默认值（type=loan·
// is_active=true·interest_rate=null）/ liability_type 白名单（loan·other）/ opening_balance 可负·NaN→0·缺省→0 /
// principal·interest_rate 可空（缺省→null，仅备查）/ name·type 校验 / partial update 不清空 / 编辑 name·type·rate /
// 结清(is_active=false)持久 / delete + delete-missing。
{
  freshDb();
  const mkLiab = async (body) => call('POST', '/api/liabilities', body);

  ok((await call('GET', '/api/liabilities', null)).length === 0, '[liab] list starts empty');

  // create defaults: type→loan, is_active→true, principal/interest_rate→null; opening_balance kept
  const l1 = await mkLiab({ name: '工行经营贷', lender: '工商银行', opening_balance: 50000, interest_rate: 4.85, currency: 'CNY', opening_date: '2026-01-01', maturity_date: '2027-01-01' });
  ok(l1?.success && l1.id, `[liab] create → {success,id}, got ${JSON.stringify(l1)}`);
  const r1 = (await call('GET', '/api/liabilities', null)).find((l) => l.id === l1.id);
  ok(r1 && r1.liability_type === 'loan' && r1.opening_balance === 50000, '[liab] create defaults type=loan, opening_balance kept');
  ok(r1.lender === '工商银行' && r1.interest_rate === 4.85 && r1.maturity_date === '2027-01-01', '[liab] lender/interest_rate(备查)/maturity persist');
  ok(typeof r1.is_active === 'boolean' && r1.is_active === true, '[liab] is_active coerced to boolean, defaults true');

  // type whitelist: invalid throws (handler guard before DB); other accepted
  await expectThrow(() => call('POST', '/api/liabilities', { name: 'Bad', liability_type: 'bond' }), '[liab] invalid liability_type throws');
  const l2 = await mkLiab({ name: '股东借款', liability_type: 'other' });
  ok((await call('GET', '/api/liabilities', null)).find((l) => l.id === l2.id).liability_type === 'other', '[liab] other type accepted');

  // opening_balance: negative allowed, NaN → 0, missing → 0; principal/interest_rate missing → null
  const lNeg = await mkLiab({ name: '负余额', opening_balance: -300 });
  const lNaN = await mkLiab({ name: 'NaN', opening_balance: 'xyz' });
  const lMiss = await mkLiab({ name: 'Bare' });
  const after = await call('GET', '/api/liabilities', null);
  ok(after.find((l) => l.id === lNeg.id).opening_balance === -300, '[liab] negative opening_balance preserved (不 clamp)');
  ok(after.find((l) => l.id === lNaN.id).opening_balance === 0, '[liab] NaN opening_balance coerced to 0');
  const bare = after.find((l) => l.id === lMiss.id);
  ok(bare.opening_balance === 0 && bare.principal === null && bare.interest_rate === null, '[liab] missing → opening_balance 0, principal/interest_rate null');

  // name required (create + update); update validates type; missing id throws
  await expectThrow(() => call('POST', '/api/liabilities', { name: '   ' }), '[liab] blank name throws');
  await expectThrow(() => call('PUT', `/api/liabilities/${l1.id}`, { name: '' }), '[liab] update blank name throws');
  await expectThrow(() => call('PUT', `/api/liabilities/${l1.id}`, { liability_type: 'mortgage' }), '[liab] update invalid type throws');
  await expectThrow(() => call('PUT', '/api/liabilities/nope', { name: 'x' }), '[liab] update missing id throws');

  // partial update: only provided field changes; untouched fields preserved (not cleared)
  await call('PUT', `/api/liabilities/${l1.id}`, { opening_balance: 40000 });
  const u1 = (await call('GET', '/api/liabilities', null)).find((l) => l.id === l1.id);
  ok(u1.opening_balance === 40000 && u1.name === '工行经营贷' && u1.lender === '工商银行' && u1.interest_rate === 4.85,
    '[liab] partial update changes only opening_balance, leaves name/lender/interest_rate intact');

  // edit name + type + interest_rate (备查) together
  await call('PUT', `/api/liabilities/${l1.id}`, { name: '工行经营贷(续)', liability_type: 'other', interest_rate: 5.1 });
  const u2 = (await call('GET', '/api/liabilities', null)).find((l) => l.id === l1.id);
  ok(u2.name === '工行经营贷(续)' && u2.liability_type === 'other' && u2.interest_rate === 5.1, '[liab] edit applies name/type/interest_rate');

  // toggle active (结清) persists as boolean false
  await call('PUT', `/api/liabilities/${l2.id}`, { is_active: false });
  ok((await call('GET', '/api/liabilities', null)).find((l) => l.id === l2.id).is_active === false, '[liab] is_active=false (已结清) persists');

  // delete removes; delete missing throws
  await call('DELETE', `/api/liabilities/${l2.id}`, null);
  ok(!(await call('GET', '/api/liabilities', null)).some((l) => l.id === l2.id), '[liab] delete removes row');
  await expectThrow(() => call('DELETE', '/api/liabilities/nope', null), '[liab] delete missing throws');
}

// ───────────────────────── fixed_assets (fixed-assets register, PR-7D-3 pipeline) ─────────────────────────
// 管道层 round-trip：证明固定资产能录入·保存·读取·编辑·删除·停用，且边界守得住——仅登记，
// 不折旧、不出净值、不接资产负债表、不出表。锁住：create 默认值（status=in_use·is_active=true）/
// status 白名单（in_use·idle·disposed）/ original_value 可负·NaN→0·缺省→0 / category 自由文本 /
// name·status 校验 / partial update 不清空 / 编辑 name·category·status / disposed 仅存标签 /
// 停用(is_active=false)持久 / delete + delete-missing。
{
  freshDb();
  const mkAsset = async (body) => call('POST', '/api/fixed-assets', body);

  ok((await call('GET', '/api/fixed-assets', null)).length === 0, '[asset] list starts empty');

  // create defaults: status→in_use, is_active→true; original_value/category/etc kept
  const a1 = await mkAsset({ name: '办公电脑', category: '电子设备', original_value: 6800, currency: 'CNY', acquisition_date: '2026-01-15', supplier: '京东', serial_no: 'SN-001' });
  ok(a1?.success && a1.id, `[asset] create → {success,id}, got ${JSON.stringify(a1)}`);
  const r1 = (await call('GET', '/api/fixed-assets', null)).find((a) => a.id === a1.id);
  ok(r1 && r1.status === 'in_use' && r1.original_value === 6800, '[asset] create defaults status=in_use, original_value kept');
  ok(r1.category === '电子设备' && r1.supplier === '京东' && r1.serial_no === 'SN-001' && r1.acquisition_date === '2026-01-15', '[asset] category/supplier/serial/acq date persist');
  ok(typeof r1.is_active === 'boolean' && r1.is_active === true, '[asset] is_active coerced to boolean, defaults true');

  // status whitelist: invalid throws (handler guard before DB); idle/disposed accepted
  await expectThrow(() => call('POST', '/api/fixed-assets', { name: 'Bad', status: 'sold' }), '[asset] invalid status throws');
  const a2 = await mkAsset({ name: '旧打印机', status: 'disposed' });
  ok((await call('GET', '/api/fixed-assets', null)).find((a) => a.id === a2.id).status === 'disposed', '[asset] disposed status accepted (登记标签)');

  // original_value: negative allowed, NaN → 0, missing → 0
  const aNeg = await mkAsset({ name: '负值', original_value: -50 });
  const aNaN = await mkAsset({ name: 'NaN', original_value: 'oops' });
  const aMiss = await mkAsset({ name: 'Bare' });
  const after = await call('GET', '/api/fixed-assets', null);
  ok(after.find((a) => a.id === aNeg.id).original_value === -50, '[asset] negative original_value preserved (不 clamp)');
  ok(after.find((a) => a.id === aNaN.id).original_value === 0, '[asset] NaN original_value coerced to 0');
  ok(after.find((a) => a.id === aMiss.id).original_value === 0, '[asset] missing original_value defaults to 0');

  // name required (create + update); update validates status; missing id throws
  await expectThrow(() => call('POST', '/api/fixed-assets', { name: '   ' }), '[asset] blank name throws');
  await expectThrow(() => call('PUT', `/api/fixed-assets/${a1.id}`, { name: '' }), '[asset] update blank name throws');
  await expectThrow(() => call('PUT', `/api/fixed-assets/${a1.id}`, { status: 'scrapped' }), '[asset] update invalid status throws');
  await expectThrow(() => call('PUT', '/api/fixed-assets/nope', { name: 'x' }), '[asset] update missing id throws');

  // partial update: only provided field changes; untouched fields preserved (not cleared)
  await call('PUT', `/api/fixed-assets/${a1.id}`, { original_value: 5000 });
  const u1 = (await call('GET', '/api/fixed-assets', null)).find((a) => a.id === a1.id);
  ok(u1.original_value === 5000 && u1.name === '办公电脑' && u1.category === '电子设备' && u1.supplier === '京东',
    '[asset] partial update changes only original_value, leaves name/category/supplier intact');

  // edit name + category + status together; disposed is just a recorded label
  await call('PUT', `/api/fixed-assets/${a1.id}`, { name: '办公电脑(旧)', category: '办公设备', status: 'disposed' });
  const u2 = (await call('GET', '/api/fixed-assets', null)).find((a) => a.id === a1.id);
  ok(u2.name === '办公电脑(旧)' && u2.category === '办公设备' && u2.status === 'disposed', '[asset] edit applies name/category/status');

  // toggle active (停用) persists as boolean false
  await call('PUT', `/api/fixed-assets/${a2.id}`, { is_active: false });
  ok((await call('GET', '/api/fixed-assets', null)).find((a) => a.id === a2.id).is_active === false, '[asset] is_active=false (停用) persists');

  // delete removes; delete missing throws
  await call('DELETE', `/api/fixed-assets/${a2.id}`, null);
  ok(!(await call('GET', '/api/fixed-assets', null)).some((a) => a.id === a2.id), '[asset] delete removes row');
  await expectThrow(() => call('DELETE', '/api/fixed-assets/nope', null), '[asset] delete missing throws');
}

// ───────────── fixed_assets 折旧参数（PR-7B P2-1：仅登记，不计算）─────────────
// 锁住：create 默认值（method=straight_line·start_policy=next_month）/ method·start_policy 白名单 /
// useful_life_months·salvage_rate 空/NaN→null（非 0，null=用类别默认）/ disposal_date 往返 /
// partial update 不清空 / list 返回 5 新字段。**不验证任何折旧计算（P2-1 不算）。**
{
  freshDb();
  const mk = async (body) => call('POST', '/api/fixed-assets', body);

  // create 默认值：未传折旧参数 → method/start_policy 默认、useful_life/salvage null
  const a1 = await mk({ name: '电脑', original_value: 6000 });
  const r1 = (await call('GET', '/api/fixed-assets', null)).find((a) => a.id === a1.id);
  ok(r1.depreciation_method === 'straight_line' && r1.depreciation_start_policy === 'next_month', '[deprec] create defaults method=straight_line, start=next_month');
  ok(r1.useful_life_months === null && r1.salvage_rate === null && r1.disposal_date === null, '[deprec] useful_life/salvage/disposal default null');

  // 显式折旧参数往返
  const a2 = await mk({ name: '车辆', original_value: 100000, useful_life_months: 48, salvage_rate: 0.05, depreciation_start_policy: 'same_month', status: 'disposed', disposal_date: '2026-06-30' });
  const r2 = (await call('GET', '/api/fixed-assets', null)).find((a) => a.id === a2.id);
  ok(r2.useful_life_months === 48 && r2.salvage_rate === 0.05, '[deprec] useful_life_months/salvage_rate persist');
  ok(r2.depreciation_start_policy === 'same_month' && r2.disposal_date === '2026-06-30', '[deprec] start_policy/disposal_date persist');

  // 白名单：非法 method / start_policy throw
  await expectThrow(() => mk({ name: 'bad', depreciation_method: 'accelerated' }), '[deprec] invalid depreciation_method throws');
  await expectThrow(() => mk({ name: 'bad', depreciation_start_policy: 'weekly' }), '[deprec] invalid depreciation_start_policy throws');

  // 空/NaN → null（非 0）
  const aNull = await mk({ name: '空参数', useful_life_months: '', salvage_rate: 'abc' });
  const rNull = (await call('GET', '/api/fixed-assets', null)).find((a) => a.id === aNull.id);
  ok(rNull.useful_life_months === null && rNull.salvage_rate === null, '[deprec] empty/NaN → null (NOT 0)');

  // partial update：只改 salvage_rate，不清空 useful_life_months
  await call('PUT', `/api/fixed-assets/${a2.id}`, { salvage_rate: 0.1 });
  const u2 = (await call('GET', '/api/fixed-assets', null)).find((a) => a.id === a2.id);
  ok(u2.salvage_rate === 0.1 && u2.useful_life_months === 48 && u2.depreciation_start_policy === 'same_month', '[deprec] partial update changes only salvage_rate');
  // update 白名单
  await expectThrow(() => call('PUT', `/api/fixed-assets/${a2.id}`, { depreciation_method: 'ddb' }), '[deprec] update invalid method throws');
}

// ───────────────────────── equity (equity / capital ledger, PR-7D-4 pipeline) ─────────────────────────
// 管道层 round-trip：证明权益/资本事项能录入·保存·读取·编辑·删除·停用，且边界守得住——仅登记，
// 不合计、不结转、不平衡、不映射科目、不联动。锁住：create 默认值（equity_type=capital_contribution·
// is_active=true）/ equity_type 白名单（4 中性值）/ amount 可负·NaN→0·缺省→0（系统不解释方向）/
// name·type 校验 / partial update 不清空 / 编辑 name·type·amount / owner_draw 仅存标签 /
// 停用(is_active=false)持久 / delete + delete-missing。
{
  freshDb();
  const mkEquity = async (body) => call('POST', '/api/equity', body);

  ok((await call('GET', '/api/equity', null)).length === 0, '[equity] list starts empty');

  // create defaults: equity_type→capital_contribution, is_active→true; amount/owner/etc kept
  const e1 = await mkEquity({ name: '创始人增资', owner: '张三', amount: 100000, currency: 'CNY', event_date: '2026-01-01' });
  ok(e1?.success && e1.id, `[equity] create → {success,id}, got ${JSON.stringify(e1)}`);
  const r1 = (await call('GET', '/api/equity', null)).find((x) => x.id === e1.id);
  ok(r1 && r1.equity_type === 'capital_contribution' && r1.amount === 100000, '[equity] create defaults type=capital_contribution, amount kept');
  ok(r1.owner === '张三' && r1.currency === 'CNY' && r1.event_date === '2026-01-01', '[equity] owner/currency/event_date persist');
  ok(typeof r1.is_active === 'boolean' && r1.is_active === true, '[equity] is_active coerced to boolean, defaults true');

  // type whitelist: invalid throws (handler guard before DB); the 4 neutral labels accepted
  await expectThrow(() => call('POST', '/api/equity', { name: 'Bad', equity_type: 'dividend' }), '[equity] invalid equity_type throws');
  const e2 = await mkEquity({ name: '创始人支取', equity_type: 'owner_draw', amount: -3000 });
  const r2 = (await call('GET', '/api/equity', null)).find((x) => x.id === e2.id);
  ok(r2.equity_type === 'owner_draw' && r2.amount === -3000, '[equity] owner_draw accepted, negative amount preserved (sign not interpreted)');

  // amount: NaN → 0, missing → 0
  const eNaN = await mkEquity({ name: 'NaN', amount: 'nope' });
  const eMiss = await mkEquity({ name: 'Bare' });
  const after = await call('GET', '/api/equity', null);
  ok(after.find((x) => x.id === eNaN.id).amount === 0, '[equity] NaN amount coerced to 0');
  ok(after.find((x) => x.id === eMiss.id).amount === 0, '[equity] missing amount defaults to 0');

  // name required (create + update); update validates type; missing id throws
  await expectThrow(() => call('POST', '/api/equity', { name: '   ' }), '[equity] blank name throws');
  await expectThrow(() => call('PUT', `/api/equity/${e1.id}`, { name: '' }), '[equity] update blank name throws');
  await expectThrow(() => call('PUT', `/api/equity/${e1.id}`, { equity_type: 'bonus' }), '[equity] update invalid type throws');
  await expectThrow(() => call('PUT', '/api/equity/nope', { name: 'x' }), '[equity] update missing id throws');

  // partial update: only provided field changes; untouched fields preserved (not cleared)
  await call('PUT', `/api/equity/${e1.id}`, { amount: 120000 });
  const u1 = (await call('GET', '/api/equity', null)).find((x) => x.id === e1.id);
  ok(u1.amount === 120000 && u1.name === '创始人增资' && u1.owner === '张三' && u1.currency === 'CNY',
    '[equity] partial update changes only amount, leaves name/owner/currency intact');

  // edit name + type + amount together
  await call('PUT', `/api/equity/${e1.id}`, { name: '创始人增资(调整)', equity_type: 'adjustment', amount: 90000 });
  const u2 = (await call('GET', '/api/equity', null)).find((x) => x.id === e1.id);
  ok(u2.name === '创始人增资(调整)' && u2.equity_type === 'adjustment' && u2.amount === 90000, '[equity] edit applies name/type/amount');

  // toggle active (停用) persists as boolean false
  await call('PUT', `/api/equity/${e2.id}`, { is_active: false });
  ok((await call('GET', '/api/equity', null)).find((x) => x.id === e2.id).is_active === false, '[equity] is_active=false (停用) persists');

  // delete removes; delete missing throws
  await call('DELETE', `/api/equity/${e2.id}`, null);
  ok(!(await call('GET', '/api/equity', null)).some((x) => x.id === e2.id), '[equity] delete removes row');
  await expectThrow(() => call('DELETE', '/api/equity/nope', null), '[equity] delete missing throws');
}

// ───────────────────────── tax_payments (tax-payments ledger, PR-7D-5 pipeline) ─────────────────────────
// 管道层 round-trip：证明已缴税款能录入·保存·读取·编辑·删除·停用，且边界守得住——仅登记，
// 不算税额、不抵扣、不对冲、不与估算勾稽、不入报表。锁住：create 默认值（tax_type=vat·is_active=true）/
// tax_type 白名单（6 中性值）/ amount 可负（退税）·NaN→0·缺省→0（系统不解释方向）/ period_start·
// period_end·authority·reference_no 往返 / name·type 校验 / partial update 不清空 / 编辑 name·type·amount /
// 停用(is_active=false)持久 / delete + delete-missing。
{
  freshDb();
  const mkTax = async (body) => call('POST', '/api/tax-payments', body);

  ok((await call('GET', '/api/tax-payments', null)).length === 0, '[tax] list starts empty');

  // create defaults: tax_type→vat, is_active→true; amount/period/authority/ref kept
  const t1 = await mkTax({ name: '2026Q1 增值税', amount: 12000, currency: 'CNY', payment_date: '2026-04-15', period_start: '2026-01-01', period_end: '2026-03-31', authority: '国家税务总局', reference_no: 'PAY-2026-001' });
  ok(t1?.success && t1.id, `[tax] create → {success,id}, got ${JSON.stringify(t1)}`);
  const r1 = (await call('GET', '/api/tax-payments', null)).find((x) => x.id === t1.id);
  ok(r1 && r1.tax_type === 'vat' && r1.amount === 12000, '[tax] create defaults tax_type=vat, amount kept');
  ok(r1.period_start === '2026-01-01' && r1.period_end === '2026-03-31' && r1.authority === '国家税务总局' && r1.reference_no === 'PAY-2026-001', '[tax] period/authority/reference persist');
  ok(typeof r1.is_active === 'boolean' && r1.is_active === true, '[tax] is_active coerced to boolean, defaults true');

  // type whitelist: invalid throws (handler guard before DB); the 6 neutral labels accepted
  await expectThrow(() => call('POST', '/api/tax-payments', { name: 'Bad', tax_type: 'tariff' }), '[tax] invalid tax_type throws');
  const t2 = await mkTax({ name: '退税', tax_type: 'vat', amount: -500 });
  const r2 = (await call('GET', '/api/tax-payments', null)).find((x) => x.id === t2.id);
  ok(r2.amount === -500, '[tax] negative amount preserved (退税/冲正; sign not interpreted)');
  const t3 = await mkTax({ name: '所得税', tax_type: 'income_tax' });
  ok((await call('GET', '/api/tax-payments', null)).find((x) => x.id === t3.id).tax_type === 'income_tax', '[tax] income_tax type accepted');

  // amount: NaN → 0, missing → 0
  const tNaN = await mkTax({ name: 'NaN', amount: 'oops' });
  const tMiss = await mkTax({ name: 'Bare' });
  const after = await call('GET', '/api/tax-payments', null);
  ok(after.find((x) => x.id === tNaN.id).amount === 0, '[tax] NaN amount coerced to 0');
  ok(after.find((x) => x.id === tMiss.id).amount === 0, '[tax] missing amount defaults to 0');

  // name required (create + update); update validates type; missing id throws
  await expectThrow(() => call('POST', '/api/tax-payments', { name: '   ' }), '[tax] blank name throws');
  await expectThrow(() => call('PUT', `/api/tax-payments/${t1.id}`, { name: '' }), '[tax] update blank name throws');
  await expectThrow(() => call('PUT', `/api/tax-payments/${t1.id}`, { tax_type: 'duty' }), '[tax] update invalid type throws');
  await expectThrow(() => call('PUT', '/api/tax-payments/nope', { name: 'x' }), '[tax] update missing id throws');

  // partial update: only provided field changes; untouched fields preserved (not cleared)
  await call('PUT', `/api/tax-payments/${t1.id}`, { amount: 11000 });
  const u1 = (await call('GET', '/api/tax-payments', null)).find((x) => x.id === t1.id);
  ok(u1.amount === 11000 && u1.name === '2026Q1 增值税' && u1.authority === '国家税务总局' && u1.reference_no === 'PAY-2026-001',
    '[tax] partial update changes only amount, leaves name/authority/reference intact');

  // edit name + type + amount together
  await call('PUT', `/api/tax-payments/${t1.id}`, { name: '2026Q1 增值税(调整)', tax_type: 'surcharge', amount: 800 });
  const u2 = (await call('GET', '/api/tax-payments', null)).find((x) => x.id === t1.id);
  ok(u2.name === '2026Q1 增值税(调整)' && u2.tax_type === 'surcharge' && u2.amount === 800, '[tax] edit applies name/type/amount');

  // toggle active (停用) persists as boolean false
  await call('PUT', `/api/tax-payments/${t2.id}`, { is_active: false });
  ok((await call('GET', '/api/tax-payments', null)).find((x) => x.id === t2.id).is_active === false, '[tax] is_active=false (停用) persists');

  // delete removes; delete missing throws
  await call('DELETE', `/api/tax-payments/${t2.id}`, null);
  ok(!(await call('GET', '/api/tax-payments', null)).some((x) => x.id === t2.id), '[tax] delete removes row');
  await expectThrow(() => call('DELETE', '/api/tax-payments/nope', null), '[tax] delete missing throws');
}

// ───────────────────────── ledger-summary (各台账余额汇总快照, PR-7B-1 只读聚合) ─────────────────────────
// 只读管理口径快照：5 张 7D 台账各自 SUM、按币种分组、仅启用行；tax_payments 独立备查。
// 锁住：空库全 0 / 各台账分币种小计正确 / **仅 is_active=1 计入**（停用排除）/ 不跨币种合计（CNY·USD 各自一行）/
// taxPaidMemo 独立（不并入 accounts/liabilities/fixedAssets/equity）/ snapshot·statutory·balanced 标志 /
// **响应不含任何跨台账合计或资产=负债+权益字段**（assets/liabilities total / balance / totalAssets 一律 undefined）。
{
  freshDb();

  // 空库：结构齐、全 0
  const empty = await call('GET', '/api/ledger-summary', null);
  ok(empty.snapshot === true && empty.statutory === false && empty.balanced === false, '[ledger] flags: snapshot=true, statutory=false, balanced=false');
  ok(empty.accounts.count === 0 && empty.accounts.byCurrency.length === 0, '[ledger] empty accounts → count 0, byCurrency []');
  // 边界守卫：响应绝不含跨台账合计 / 平衡 / 资产负债权益总计字段
  for (const k of ['assets', 'liabilities_total', 'totalAssets', 'totalLiabilities', 'totalEquity', 'balance', 'difference', 'grandTotal']) {
    ok(empty[k] === undefined, `[ledger] response must NOT carry cross-ledger/balance field '${k}'`);
  }

  // seed accounts: 2×CNY active (100, 200) + 1×USD active (50) + 1×CNY inactive (999, 应排除)
  await call('POST', '/api/accounts', { name: 'A1', opening_balance: 100, currency: 'CNY' });
  await call('POST', '/api/accounts', { name: 'A2', opening_balance: 200, currency: 'CNY' });
  await call('POST', '/api/accounts', { name: 'A3', opening_balance: 50, currency: 'USD' });
  await call('POST', '/api/accounts', { name: 'A4', opening_balance: 999, currency: 'CNY', is_active: false });
  // seed liabilities / fixed_assets / equity (各 1 CNY active)
  await call('POST', '/api/liabilities', { name: 'L1', opening_balance: 5000, currency: 'CNY' });
  await call('POST', '/api/fixed-assets', { name: 'F1', original_value: 8000, currency: 'CNY' });
  await call('POST', '/api/equity', { name: 'E1', amount: 30000, currency: 'CNY' });
  // seed tax_payments: 1 CNY active (memo only)
  await call('POST', '/api/tax-payments', { name: 'T1', amount: 1200, currency: 'CNY' });

  const s = await call('GET', '/api/ledger-summary', null);

  // accounts：CNY 小计 300（仅 2 启用行；999 停用排除）、USD 小计 50；count=3（启用行）
  const accCny = s.accounts.byCurrency.find((r) => r.currency === 'CNY');
  const accUsd = s.accounts.byCurrency.find((r) => r.currency === 'USD');
  ok(accCny && approx(accCny.total, 300) && accCny.count === 2, `[ledger] accounts CNY=300 count=2 (inactive 999 excluded), got ${JSON.stringify(accCny)}`);
  ok(accUsd && approx(accUsd.total, 50) && accUsd.count === 1, '[ledger] accounts USD=50 count=1');
  ok(s.accounts.count === 3, `[ledger] accounts active count=3 (停用排除), got ${s.accounts.count}`);
  // 不跨币种合计：byCurrency 两行，不存在把 300+50 折成 350 的单一 total
  ok(s.accounts.byCurrency.length === 2 && s.accounts.total === undefined, '[ledger] accounts grouped by currency, no cross-currency single total');

  // liabilities / fixedAssets / equity 各自小计
  ok(approx(s.liabilities.byCurrency.find((r) => r.currency === 'CNY')?.total, 5000), '[ledger] liabilities CNY=5000');
  ok(approx(s.fixedAssets.byCurrency.find((r) => r.currency === 'CNY')?.total, 8000), '[ledger] fixedAssets CNY=8000');
  ok(approx(s.equity.byCurrency.find((r) => r.currency === 'CNY')?.total, 30000), '[ledger] equity CNY=30000');

  // taxPaidMemo 独立备查：自身正确，且 1200 绝不混入其它任何台账小计
  ok(approx(s.taxPaidMemo.byCurrency.find((r) => r.currency === 'CNY')?.total, 1200), '[ledger] taxPaidMemo CNY=1200 (独立备查)');
  ok(accCny.total === 300 && s.equity.byCurrency.find((r) => r.currency === 'CNY')?.total === 30000, '[ledger] tax 1200 not folded into accounts/equity totals');
}

// ───────────────────────── cash-position (现金/银行期末结转只读预览, PR-7B P1-2) ─────────────────────────
// 只读 preview：endingEstimate = 期初 + 本期实收 − 本期实付，按币种。锁住：transactions 选源时按币种聚合·
// 期末公式·缺 payment_date 回退 date·selectReportSource 防双计(本期有 txn → legacy sale 被忽略)·
// **不写回 accounts**·estimate/limitations/excludedNotes·legacy 选源按本位币归集(缺 payment_date 行不计入)。
const PD = '2026-06-15';        // 期间内
const Q = '?from=2026-01-01&to=2026-12-31';
{
  const db = freshDb();
  // 期初：CNY 1000(启用) + USD 500(启用) + CNY 999(停用→排除)
  await call('POST', '/api/accounts', { name: 'A-CNY', opening_balance: 1000, currency: 'CNY' });
  await call('POST', '/api/accounts', { name: 'A-USD', opening_balance: 500, currency: 'USD' });
  await call('POST', '/api/accounts', { name: 'A-OFF', opening_balance: 999, currency: 'CNY', is_active: false });

  // 本期 transactions（直插以精确控制 currency/payment_date/paid_amount）
  const insTxn = db.prepare(`INSERT INTO transactions (id, type, date, amount, amount_net, currency, payment_status, paid_amount, payment_date) VALUES (?,?,?,?,?,?,?,?,?)`);
  insTxn.run('cp-i1', 'income',  PD, 300, 300, 'CNY', 'paid', 300, PD);          // CNY 实收 300
  insTxn.run('cp-e1', 'expense', PD, 100, 100, 'CNY', 'paid', 100, PD);          // CNY 实付 100
  insTxn.run('cp-i2', 'income',  PD,  50,  50, 'USD', 'paid',  50, PD);          // USD 实收 50
  insTxn.run('cp-i3', 'income',  PD,  70,  70, 'CNY', 'paid',  70, null);        // 缺 payment_date → 回退 date → 计入 CNY 实收 70
  insTxn.run('cp-i4', 'income',  PD, 999, 999, 'CNY', 'unpaid', 0, PD);          // 未付 → 不计入
  // legacy sale（同期）：因本期有 transactions → 选源 transactions → 此 sale 必须被忽略（防双计）
  db.prepare(`INSERT INTO sales (id, date, customer, totalAmount, payment_status, paid_amount, payment_date) VALUES (?,?,?,?,?,?,?)`)
    .run('cp-legacy-sale', PD, 'X', 8888, 'paid', 8888, PD);

  const r = await call('GET', `/api/cash-position${Q}`, null);
  ok(r.estimate === true && r.source === 'transactions', `[cash] estimate=true, source=transactions, got ${r.source}`);
  const cny = r.byCurrency.find((x) => x.currency === 'CNY');
  const usd = r.byCurrency.find((x) => x.currency === 'USD');
  ok(cny && approx(cny.opening, 1000), `[cash] CNY opening=1000 (停用 999 排除), got ${cny?.opening}`);
  ok(approx(cny.inflow, 370), `[cash] CNY inflow=370 (300+70, 缺 payment_date 的 70 经 date 回退计入), got ${cny.inflow}`);
  ok(approx(cny.outflow, 100), `[cash] CNY outflow=100, got ${cny.outflow}`);
  ok(approx(cny.endingEstimate, 1270), `[cash] CNY ending=期初+实收−实付=1270, got ${cny.endingEstimate}`);
  ok(usd && approx(usd.opening, 500) && approx(usd.inflow, 50) && approx(usd.outflow, 0) && approx(usd.endingEstimate, 550), `[cash] USD opening500/in50/out0/end550, got ${JSON.stringify(usd)}`);
  // 防双计：legacy sale 8888 未进 CNY 实收
  ok(cny.inflow < 8888, '[cash] selectReportSource 防双计：本期有 txn → legacy sale 8888 被忽略');
  // 按币种、不跨币种合计：恰两个币种，无单一总额字段
  ok(r.byCurrency.length === 2 && r.total === undefined && r.endingTotal === undefined, '[cash] grouped by currency, no cross-currency total');
  ok(Array.isArray(r.limitations) && r.limitations.length > 0 && Array.isArray(r.excludedNotes) && r.excludedNotes.length > 0, '[cash] limitations/excludedNotes present');

  // **不写回 accounts**：调用后 accounts.opening_balance 不变
  const accs = await call('GET', '/api/accounts', null);
  ok(accs.find((a) => a.name === 'A-CNY').opening_balance === 1000 && accs.find((a) => a.name === 'A-USD').opening_balance === 500,
    '[cash] read-only: accounts.opening_balance NOT written back');
}

// legacy 选源：本期无 transactions → source=legacy → sales/purchases 按本位币归集；缺 payment_date 行不计入
{
  const db = freshDb();
  await call('POST', '/api/accounts', { name: 'A-CNY', opening_balance: 200, currency: 'CNY' });
  db.prepare(`INSERT INTO sales (id, date, customer, totalAmount, payment_status, paid_amount, payment_date) VALUES (?,?,?,?,?,?,?)`)
    .run('cp-s1', PD, 'X', 400, 'paid', 400, PD);        // 实收 400
  db.prepare(`INSERT INTO sales (id, date, customer, totalAmount, payment_status, paid_amount, payment_date) VALUES (?,?,?,?,?,?,?)`)
    .run('cp-s2', PD, 'Y', 60, 'paid', 60, null);        // 缺 payment_date → 不计入
  db.prepare(`INSERT INTO purchases (id, date, supplier, totalAmount, payment_status, paid_amount, payment_date) VALUES (?,?,?,?,?,?,?)`)
    .run('cp-p1', PD, 'Z', 150, 'paid', 150, PD);        // 实付 150

  const r = await call('GET', `/api/cash-position${Q}`, null);
  ok(r.source === 'legacy', `[cash-legacy] source=legacy (本期无 txn), got ${r.source}`);
  const cny = r.byCurrency.find((x) => x.currency === r.baseCurrency);
  ok(cny && approx(cny.opening, 200) && approx(cny.inflow, 400) && approx(cny.outflow, 150) && approx(cny.endingEstimate, 450),
    `[cash-legacy] 本位币 opening200/in400(缺payment_date 60 排除)/out150/end450, got ${JSON.stringify(cny)}`);
}

// ───────────────────────── balance-overview (管理口径资产负债概览, PR-7B P1-3 只读聚合) ─────────────────────────
// 只读：按币种归集 资产/负债/权益 + 小计 + 显式 balanceDifference。锁住：按币种分组·cash 接 cash-position·
// 固资按原值进非流动·借款 maturity 一年线分(空→流动+warning)·tax 不进合计·balanceDifference 显式·
// 不跨币种合计·**不写回任何表**。基准日 asOf=period.to=2026-12-31 → cutoff=2027-12-31。
{
  const db = freshDb();
  const find = (arr, key) => (arr.find((l) => l.key === key) || {}).amount;

  // 期初账户：CNY 1000 + USD 500
  await call('POST', '/api/accounts', { name: 'A-CNY', opening_balance: 1000, currency: 'CNY' });
  await call('POST', '/api/accounts', { name: 'A-USD', opening_balance: 500, currency: 'USD' });
  // 本期 transactions → 现金：CNY 1000+300−100=1200；USD 500+50=550（选源=transactions）
  const insTxn = db.prepare(`INSERT INTO transactions (id, type, date, amount, amount_net, currency, payment_status, paid_amount, payment_date) VALUES (?,?,?,?,?,?,?,?,?)`);
  insTxn.run('bo-i1', 'income',  PD, 300, 300, 'CNY', 'paid', 300, PD);
  insTxn.run('bo-e1', 'expense', PD, 100, 100, 'CNY', 'paid', 100, PD);
  insTxn.run('bo-i2', 'income',  PD,  50,  50, 'USD', 'paid',  50, PD);
  // 固定资产（原值）：CNY 8000 + USD 2000
  await call('POST', '/api/fixed-assets', { name: 'F-CNY', original_value: 8000, currency: 'CNY' });
  await call('POST', '/api/fixed-assets', { name: 'F-USD', original_value: 2000, currency: 'USD' });
  // 借款（CNY）：流动 2000(到期≤cutoff) + 非流动 5000(到期>cutoff) + 空到期日 1500(默认流动+warning)
  await call('POST', '/api/liabilities', { name: 'L-cur', opening_balance: 2000, currency: 'CNY', maturity_date: '2026-09-01' });
  await call('POST', '/api/liabilities', { name: 'L-non', opening_balance: 5000, currency: 'CNY', maturity_date: '2030-01-01' });
  await call('POST', '/api/liabilities', { name: 'L-nul', opening_balance: 1500, currency: 'CNY' });
  // 权益（CNY 30000）
  await call('POST', '/api/equity', { name: 'E1', amount: 30000, currency: 'CNY' });
  // 税：已缴税款（不得进任何合计）
  await call('POST', '/api/tax-payments', { name: 'T1', amount: 1200, currency: 'CNY' });
  // 应收/应付（本位币 CNY，无币种）：未收销售 800、未付采购 300
  db.prepare(`INSERT INTO sales (id, date, customer, totalAmount, payment_status, paid_amount) VALUES (?,?,?,?,?,?)`).run('bo-s1', PD, 'X', 800, 'unpaid', 0);
  db.prepare(`INSERT INTO purchases (id, date, supplier, totalAmount, payment_status, paid_amount) VALUES (?,?,?,?,?,?)`).run('bo-p1', PD, 'Y', 300, 'unpaid', 0);

  const bo = await call('GET', `/api/balance-overview${Q}`, null);

  // 元信息
  ok(bo.estimate === true && bo.reportType === 'management_balance_overview', '[bo] estimate=true + reportType=management_balance_overview');
  ok(bo.asOf === '2026-12-31' && bo.disclaimerKey === 'disclaimer.report', '[bo] asOf=period.to + disclaimerKey');
  ok(Array.isArray(bo.limitations) && bo.limitations.length > 0 && Array.isArray(bo.excludedNotes) && bo.excludedNotes.length > 0, '[bo] limitations/excludedNotes present');
  // 不跨币种合计：无顶层 totals/balanceDifference；按币种分组（CNY+USD）
  ok(bo.totals === undefined && bo.balanceDifference === undefined, '[bo] no top-level total / cross-currency aggregate');
  ok(bo.byCurrency.length === 2, `[bo] grouped by 2 currencies, got ${bo.byCurrency.length}`);
  const cny = bo.byCurrency.find((b) => b.currency === 'CNY');
  const usd = bo.byCurrency.find((b) => b.currency === 'USD');

  // cash-position 接入：cash 行 = cash-position endingEstimate（同 from/to）
  const cp = await call('GET', `/api/cash-position${Q}`, null);
  const cpCny = cp.byCurrency.find((x) => x.currency === 'CNY').endingEstimate;
  ok(approx(find(cny.assets.current, 'cash'), cpCny) && approx(cpCny, 1200), `[bo] cash 接 cash-position endingEstimate CNY=1200, got ${find(cny.assets.current, 'cash')}`);
  ok(approx(find(usd.assets.current, 'cash'), 550), `[bo] cash USD=550, got ${find(usd.assets.current, 'cash')}`);

  // AR/AP/存货：本位币 CNY 桶 = 各 summary
  const recv = await call('GET', '/api/receivables/summary', null);
  const pay = await call('GET', '/api/payables/summary', null);
  const inv = await call('GET', '/api/inventory/summary', null);
  ok(approx(find(cny.assets.current, 'receivables'), recv.totalReceivable) && approx(recv.totalReceivable, 800), '[bo] receivables 接 totalReceivable=800');
  ok(approx(find(cny.liabilities.current, 'payables'), pay.totalPayable) && approx(pay.totalPayable, 300), '[bo] payables 接 totalPayable=300');
  ok(approx(find(cny.assets.current, 'inventory'), inv.totalInventoryCost), '[bo] inventory 接 totalInventoryCost');
  // USD 桶无 AR/AP/inventory（仅本位币桶）
  ok(find(usd.assets.current, 'receivables') === undefined && find(usd.liabilities.current, 'payables') === undefined, '[bo] AR/AP only in base-currency bucket');

  // 固定资产按原值进非流动资产
  ok(approx(find(cny.assets.nonCurrent, 'fixedAssets'), 8000) && approx(find(usd.assets.nonCurrent, 'fixedAssets'), 2000), '[bo] fixedAssets(原值) → assets.nonCurrent (CNY 8000 / USD 2000)');

  // 借款一年线分类 + 空到期日默认流动 + warning
  ok(approx(find(cny.liabilities.current, 'borrowings'), 3500), `[bo] borrowings 流动=3500 (2000+空1500), got ${find(cny.liabilities.current, 'borrowings')}`);
  ok(approx(find(cny.liabilities.nonCurrent, 'borrowings'), 5000), `[bo] borrowings 非流动=5000 (到期>cutoff), got ${find(cny.liabilities.nonCurrent, 'borrowings')}`);
  ok(cny.warnings.includes('borrowingsNullMaturityDefaultCurrent'), '[bo] 空到期日 → warning');

  // 权益（PR-7B P2-4b 两行）：业主资本/出资（individual 默认）+ 未分配利润（本位币块）
  ok(bo.entityType === 'individual', '[bo] entityType=individual (默认)');
  ok(approx(find(cny.equity, 'ownerCapital'), 30000), `[bo] ownerCapital(individual) = Σcapital_contribution = 30000, got ${find(cny.equity, 'ownerCapital')}`);
  ok(find(cny.equity, 'equity') === undefined, '[bo] 旧单行 key=equity 已移除');
  const reBo = await call('GET', `/api/retained-earnings-preview${Q}`, null);
  ok(approx(find(cny.equity, 'retainedEarnings'), reBo.endingRetainedEarnings), '[bo] retainedEarnings 行 = retained-earnings-preview.endingRetainedEarnings（本位币块）');
  ok(usd.equity.every((l) => l.key !== 'retainedEarnings'), '[bo] 非本位币块(USD)无 retainedEarnings 行');

  // tax 不进任何 section/totals
  const allCnyLines = [...cny.assets.current, ...cny.assets.nonCurrent, ...cny.liabilities.current, ...cny.liabilities.nonCurrent, ...cny.equity];
  ok(!allCnyLines.some((l) => /tax/i.test(l.key)), '[bo] no tax line in any section');
  ok(approx(cny.totals.liabilities, 300 + 3500 + 5000), `[bo] totals.liabilities=8800 (payables+borrowings, tax 1200 排除), got ${cny.totals.liabilities}`);
  ok(bo.excludedNotes.some((n) => /tax|税/.test(n)), '[bo] excludedNotes 提及 tax 排除');

  // balanceDifference 显式 = 资产 − 负债 − 权益（按币种）
  ok(approx(cny.balanceDifference, cny.totals.assets - cny.totals.liabilities - cny.totals.equity), '[bo] balanceDifference = assets − liabilities − equity (CNY)');
  ok(approx(usd.balanceDifference, usd.totals.assets - usd.totals.liabilities - usd.totals.equity), '[bo] balanceDifference per currency (USD)');
  // totals.assets 自洽（cash1200+AR800+inv+fixed8000）
  ok(approx(cny.totals.assets, 1200 + 800 + (inv.totalInventoryCost || 0) + 8000), `[bo] CNY totals.assets 自洽, got ${cny.totals.assets}`);

  // **不写回任何表**：调用后各表行数/样本值不变
  ok(db.prepare('SELECT opening_balance FROM accounts WHERE name=?').get('A-CNY').opening_balance === 1000, '[bo] read-only: accounts unchanged');
  ok(db.prepare("SELECT COUNT(*) AS c FROM liabilities").get().c === 3, '[bo] read-only: liabilities row count unchanged');
  ok(db.prepare('SELECT original_value FROM fixed_assets WHERE name=?').get('F-CNY').original_value === 8000, '[bo] read-only: fixed_assets unchanged');
  ok(db.prepare('SELECT amount FROM equity WHERE name=?').get('E1').amount === 30000, '[bo] read-only: equity unchanged');
  ok(db.prepare("SELECT COUNT(*) AS c FROM tax_payments").get().c === 1, '[bo] read-only: tax_payments unchanged');
}

// ───────────────────────── depreciation-preview (直线法折旧只读预览, PR-7B P2-2) ─────────────────────────
// 只读：累计折旧/净值/月折旧。锁住：next_month/same_month 计提月数·useful/salvage 空回退默认·
// clamp 到可折旧额·净值≥残值·disposed+日期处置次月停·disposed 无日期 warning·无购置日 warning·
// daily fallback warning·多币种分组·disposed 不计入 totals·**不写回 fixed_assets**·category 解析。
{
  const db = freshDb();
  const asOf = '?asOf=2026-12-31';
  const mk = async (body) => call('POST', '/api/fixed-assets', body);
  await mk({ name: 'A1', original_value: 12000, salvage_rate: 0.1, useful_life_months: 12, acquisition_date: '2026-01-15', depreciation_start_policy: 'next_month', currency: 'CNY' });
  await mk({ name: 'A2', original_value: 12000, salvage_rate: 0, useful_life_months: 12, acquisition_date: '2026-01-15', depreciation_start_policy: 'same_month', currency: 'CNY' });
  await mk({ name: 'A3', category: '办公电脑', original_value: 6000, acquisition_date: '2026-01-15', currency: 'CNY' });   // useful/salvage 空 → 默认
  await mk({ name: 'A4', original_value: 10000, salvage_rate: 0, useful_life_months: 4, acquisition_date: '2025-01-15', depreciation_start_policy: 'next_month', currency: 'CNY' }); // clamp 超龄
  await mk({ name: 'A5', original_value: 12000, salvage_rate: 0, useful_life_months: 12, acquisition_date: '2026-01-15', depreciation_start_policy: 'next_month', currency: 'CNY', status: 'disposed', disposal_date: '2026-06-30' });
  await mk({ name: 'A6', original_value: 6000, useful_life_months: 12, acquisition_date: '2026-01-15', currency: 'CNY', status: 'disposed' });   // disposed 无日期
  await mk({ name: 'A7', original_value: 5000, useful_life_months: 12, currency: 'CNY' });                       // 无购置日期
  await mk({ name: 'A8', original_value: 12000, salvage_rate: 0, useful_life_months: 12, acquisition_date: '2026-01-15', depreciation_start_policy: 'daily', currency: 'CNY' });
  await mk({ name: 'A9', original_value: 1000, salvage_rate: 0, useful_life_months: 12, acquisition_date: '2026-01-15', currency: 'USD' });

  const dp = await call('GET', `/api/depreciation-preview${asOf}`, null);
  ok(dp.estimate === true && dp.reportType === 'depreciation_preview' && dp.asOf === '2026-12-31', '[dp] estimate/reportType/asOf');
  const cny = dp.byCurrency.find((b) => b.currency === 'CNY');
  const usd = dp.byCurrency.find((b) => b.currency === 'USD');
  const A = (n) => cny.assets.find((a) => a.name === n);

  // next_month：A1 月数 11、累计 9900、净值 2100（depreciable 10800, monthly 900）
  ok(A('A1').monthsElapsed === 11 && approx(A('A1').accumulatedDepreciation, 9900) && approx(A('A1').netBookValue, 2100), `[dp] A1 next_month 11mo acc=9900 net=2100, got ${JSON.stringify({m:A('A1').monthsElapsed,a:A('A1').accumulatedDepreciation,n:A('A1').netBookValue})}`);
  // same_month：A2 月数 12、净值 0（== 残值 0）
  ok(A('A2').monthsElapsed === 12 && approx(A('A2').netBookValue, 0), '[dp] A2 same_month 12mo net=0');
  // 默认回退：A3 useful 空→36、salvage 空→0.05、category→electronics
  ok(A('A3').usefulLifeMonths === 36 && approx(A('A3').salvageRate, 0.05), '[dp] A3 useful/salvage default (36mo / 0.05)');
  ok(A('A3').usedDefaults.usefulLifeMonths === true && A('A3').usedDefaults.salvageRate === true && A('A3').categoryResolved === 'electronics', '[dp] A3 usedDefaults flags + categoryResolved=electronics');
  // clamp + 净值≥残值：A4 超龄 → 累计=可折旧额=10000、净值=残值=0
  ok(approx(A('A4').accumulatedDepreciation, A('A4').depreciableAmount) && approx(A('A4').accumulatedDepreciation, 10000) && approx(A('A4').netBookValue, 0), '[dp] A4 clamp accumulated=depreciable=10000, net=0 (≥salvage)');
  // disposed + 日期：A5 处置次月停 → 月数 5（Feb..June）
  ok(A('A5').disposed === true && A('A5').monthsElapsed === 5, `[dp] A5 disposed+date → 5mo (Feb..June), got ${A('A5').monthsElapsed}`);
  // disposed 无日期：A6 warning disposedNoDate
  ok(A('A6').disposed === true && A('A6').warnings.includes('disposedNoDate'), '[dp] A6 disposedNoDate warning');
  // 无购置日期：A7 warning + 不计提
  ok(A('A7').warnings.includes('noAcquisitionDate') && A('A7').accumulatedDepreciation === 0 && approx(A('A7').netBookValue, 5000), '[dp] A7 noAcquisitionDate → 0 accumulated, net=original');
  // daily fallback：A8 warning + 按次月口径（月数 11）
  ok(A('A8').warnings.includes('dailyPolicyFallback') && A('A8').monthsElapsed === 11, '[dp] A8 dailyPolicyFallback + computed as next_month (11mo)');
  // 多币种分组：USD 独立块
  ok(usd && usd.assets.length === 1 && usd.assets[0].name === 'A9', '[dp] multi-currency: USD block separate');
  // 净值 + 累计 = 原值（不变量，robust，不受 round2 口径影响）；月数 11
  ok(usd.assets[0].monthsElapsed === 11 && approx(usd.assets[0].netBookValue + usd.assets[0].accumulatedDepreciation, 1000), '[dp] USD A9 computed in its own block (net+accumulated=original, 11mo)');

  // disposed 不计入 totals：CNY totals.originalValue = 在用 6 项 = 57000（A5/A6 排除）
  ok(approx(cny.totals.originalValue, 57000), `[dp] CNY totals.originalValue=57000 (disposed A5/A6 excluded), got ${cny.totals.originalValue}`);
  // totals.netBookValue 仅在用资产（不含 disposed）
  ok(cny.totals.netBookValue < cny.totals.originalValue, '[dp] CNY totals.netBookValue < originalValue (depreciated)');

  // **不写回 fixed_assets**：调用后 original_value / 折旧参数列不变，且无 accumulated/net 列写入
  const a1Row = db.prepare("SELECT original_value, useful_life_months, salvage_rate FROM fixed_assets WHERE name='A1'").get();
  ok(a1Row.original_value === 12000 && a1Row.useful_life_months === 12 && a1Row.salvage_rate === 0.1, '[dp] read-only: fixed_assets A1 params unchanged');
  const cols = db.prepare("PRAGMA table_info(fixed_assets)").all().map((c) => c.name);
  ok(!cols.includes('accumulated_depreciation') && !cols.includes('net_book_value'), '[dp] read-only: no accumulated/net columns written to schema');
}

// ───────────── balance-overview 固定资产接入净值（PR-7B P2-3）─────────────
// 锁住：fixedAssets 行金额=净值(非原值)·meta 原值/累计折旧/净值/estimate·disposed 不计入·多币种·
// balanceDifference 随净值变·不写回 fixed_assets。
{
  const db = freshDb();
  const Q3 = '?from=2026-01-01&to=2026-12-31';   // asOf=2026-12-31
  await call('POST', '/api/accounts', { name: 'A-CNY', opening_balance: 1000, currency: 'CNY' });
  // 可折旧资产：original 12000·salvage 0.1·useful 12·acq 2026-01-15·next_month → net 2100（acc 9900）
  await call('POST', '/api/fixed-assets', { name: 'NetA', original_value: 12000, salvage_rate: 0.1, useful_life_months: 12, acquisition_date: '2026-01-15', depreciation_start_policy: 'next_month', currency: 'CNY' });
  // 已处置资产：不计入净值合计
  await call('POST', '/api/fixed-assets', { name: 'DispA', original_value: 5000, useful_life_months: 12, acquisition_date: '2026-01-15', currency: 'CNY', status: 'disposed', disposal_date: '2026-06-30' });
  // USD 可折旧资产：进 USD 块
  await call('POST', '/api/fixed-assets', { name: 'NetU', original_value: 1000, salvage_rate: 0, useful_life_months: 12, acquisition_date: '2026-01-15', currency: 'USD' });

  const bo = await call('GET', `/api/balance-overview${Q3}`, null);
  const cny = bo.byCurrency.find((b) => b.currency === 'CNY');
  const usd = bo.byCurrency.find((b) => b.currency === 'USD');
  const fa = cny.assets.nonCurrent.find((l) => l.key === 'fixedAssets');

  // 固定资产行金额 = 净值 2100（非原值 12000，且 disposed 的 5000 排除）
  ok(fa && approx(fa.amount, 2100), `[bo-net] fixedAssets line = netBookValue 2100 (not original), got ${fa?.amount}`);
  // meta：原值/累计折旧/净值/estimate（disposed 排除 → original 12000 非 17000）
  ok(fa.meta && approx(fa.meta.originalValue, 12000) && approx(fa.meta.accumulatedDepreciation, 9900) && approx(fa.meta.netBookValue, 2100) && fa.meta.estimate === true,
    `[bo-net] meta originalValue=12000(disposed excluded)/accumulated=9900/net=2100/estimate, got ${JSON.stringify(fa.meta)}`);
  // 多币种：USD 块固定资产净值独立（< 1000）
  const faU = usd.assets.nonCurrent.find((l) => l.key === 'fixedAssets');
  ok(faU && faU.amount < 1000 && faU.amount > 0, `[bo-net] USD fixedAssets net in its own block, got ${faU?.amount}`);
  // balanceDifference 体现净值（CNY totals.assets 含 2100 而非 12000）
  ok(approx(cny.totals.assets, fa.amount + (cny.assets.current.reduce((s, l) => s + l.amount, 0))), '[bo-net] CNY totals.assets uses net value');
  ok(approx(cny.balanceDifference, cny.totals.assets - cny.totals.liabilities - cny.totals.equity), '[bo-net] balanceDifference recomputed with net value');
  // limitations 提及净值
  ok(bo.limitations.some((n) => /净值|直线法/.test(n)), '[bo-net] limitations mention net value / straight-line');

  // 不写回 fixed_assets：original_value 不变，无 accumulated/net 列
  ok(db.prepare("SELECT original_value FROM fixed_assets WHERE name='NetA'").get().original_value === 12000, '[bo-net] read-only: fixed_assets original_value unchanged');
  const cols = db.prepare("PRAGMA table_info(fixed_assets)").all().map((c) => c.name);
  ok(!cols.includes('net_book_value') && !cols.includes('accumulated_depreciation'), '[bo-net] read-only: no net/accumulated columns');
}

// ───────────── balance-overview 权益拆两行（PR-7B P2-4b）─────────────
// 锁住：equity 单行→两行(出资+未分配利润)·entity-aware key·individual owner_draw 冲减出资行·
// company owner_draw 不进出资行(已在 retained 作 distributions)·adjustment/other 折进出资行·
// retained 仅本位币块·非本位币 company owner_draw 进 excludedNotes·totalEquity=出资+retained·
// balanceDifference 随拆分·无重复扣减·不写回 equity。
{
  const db = freshDb();
  const Q4 = '?from=2026-01-01&to=2026-12-31';
  await call('PUT', '/api/settings', { opening_retained_earnings: 0, currency: 'CNY', accounting_locale: 'CN' });
  // 权益台账（CNY）：capital 100000 + adjustment 5000 + other 2000 + owner_draw 8000（无交易→净利 0，retained 全由 distributions 决定）
  await call('POST', '/api/equity', { name: 'Cap', equity_type: 'capital_contribution', amount: 100000, currency: 'CNY', event_date: PD });
  await call('POST', '/api/equity', { name: 'Adj', equity_type: 'adjustment', amount: 5000, currency: 'CNY', event_date: PD });
  await call('POST', '/api/equity', { name: 'Oth', equity_type: 'other', amount: 2000, currency: 'CNY', event_date: PD });
  await call('POST', '/api/equity', { name: 'Draw', equity_type: 'owner_draw', amount: 8000, currency: 'CNY', event_date: PD });
  // 非本位币（USD）：capital 3000 + owner_draw 1000
  await call('POST', '/api/equity', { name: 'CapU', equity_type: 'capital_contribution', amount: 3000, currency: 'USD', event_date: PD });
  await call('POST', '/api/equity', { name: 'DrawU', equity_type: 'owner_draw', amount: 1000, currency: 'USD', event_date: PD });
  const eq = (blk, key) => (blk.equity.find((l) => l.key === key) || {}).amount;

  // ── individual（默认）：ownerCapital = (100000+5000+2000) − owner_draw 8000 = 99000 ──
  const reI = await call('GET', `/api/retained-earnings-preview${Q4}`, null);
  const boI = await call('GET', `/api/balance-overview${Q4}`, null);
  const cnyI = boI.byCurrency.find((b) => b.currency === 'CNY');
  const usdI = boI.byCurrency.find((b) => b.currency === 'USD');
  ok(boI.entityType === 'individual', '[bo-eq] default entityType=individual');
  ok(approx(eq(cnyI, 'ownerCapital'), 99000), `[bo-eq] individual ownerCapital = (100000+5000+2000) − owner_draw 8000 = 99000, got ${eq(cnyI, 'ownerCapital')}`);
  ok(eq(cnyI, 'contributedCapital') === undefined && eq(cnyI, 'equity') === undefined, '[bo-eq] individual 用 ownerCapital key（无 contributedCapital/旧 equity）');
  ok(approx(reI.distributions, 0) && approx(eq(cnyI, 'retainedEarnings'), reI.endingRetainedEarnings), '[bo-eq] individual retained = preview.ending（distributions=0，未扣 owner_draw）');
  // USD 块：ownerCapital = 3000 − 1000 = 2000（同币种 owner_draw 冲减）；无 retained
  ok(approx(eq(usdI, 'ownerCapital'), 2000), `[bo-eq] individual USD ownerCapital = 3000 − 1000 = 2000, got ${eq(usdI, 'ownerCapital')}`);
  ok(eq(usdI, 'retainedEarnings') === undefined, '[bo-eq] 非本位币块无 retainedEarnings');
  // totalEquity = 出资 + retained（本位币块）；balanceDifference 自洽
  ok(approx(cnyI.totals.equity, eq(cnyI, 'ownerCapital') + eq(cnyI, 'retainedEarnings')), '[bo-eq] individual totalEquity = ownerCapital + retained');
  ok(approx(cnyI.balanceDifference, cnyI.totals.assets - cnyI.totals.liabilities - cnyI.totals.equity), '[bo-eq] individual balanceDifference = assets − liab − equity');

  // ── company：contributedCapital = 100000+5000+2000 = 107000（不扣 owner_draw）；retained 扣 base owner_draw 8000 ──
  await call('PUT', '/api/settings', { entity_type: 'company' });
  const reC = await call('GET', `/api/retained-earnings-preview${Q4}`, null);
  const boC = await call('GET', `/api/balance-overview${Q4}`, null);
  const cnyC = boC.byCurrency.find((b) => b.currency === 'CNY');
  const usdC = boC.byCurrency.find((b) => b.currency === 'USD');
  ok(boC.entityType === 'company', '[bo-eq] entityType=company');
  ok(approx(eq(cnyC, 'contributedCapital'), 107000), `[bo-eq] company contributedCapital = 100000+5000+2000 = 107000 (owner_draw 不扣), got ${eq(cnyC, 'contributedCapital')}`);
  ok(eq(cnyC, 'ownerCapital') === undefined, '[bo-eq] company 用 contributedCapital key（无 ownerCapital）');
  ok(approx(reC.distributions, 8000) && approx(eq(cnyC, 'retainedEarnings'), reC.endingRetainedEarnings), '[bo-eq] company retained = preview.ending（distributions=base owner_draw 8000）');
  // 无重复扣减：8000 只在 retained 扣，不从 contributedCapital 再扣
  ok(approx(eq(cnyC, 'contributedCapital'), 107000), '[bo-eq] no double-count: company owner_draw 未从出资行重复扣');
  // company USD：contributedCapital = 3000（不扣 USD owner_draw）；USD owner_draw 1000 进 excludedNotes
  ok(approx(eq(usdC, 'contributedCapital'), 3000), `[bo-eq] company USD contributedCapital = 3000 (USD owner_draw 不扣), got ${eq(usdC, 'contributedCapital')}`);
  ok(boC.excludedNotes.some((n) => /USD/.test(n) && /owner_draw/i.test(n)), '[bo-eq] company 非本位币 owner_draw 进 excludedNotes');
  // retained 仅本位币：excludedNotes 说明
  ok(boC.excludedNotes.some((n) => /未分配利润/.test(n) && /本位币/.test(n)), '[bo-eq] excludedNotes 说明 retained 仅本位币口径');

  // ── 不写回 equity ──
  ok(db.prepare("SELECT COUNT(*) AS c FROM equity").get().c === 6, '[bo-eq] read-only: equity 行数不变(6)');
  ok(db.prepare("SELECT amount FROM equity WHERE name='Draw'").get().amount === 8000, '[bo-eq] read-only: owner_draw amount 不变');
}

// ───────────── products.create id hardening (prod-<ts>-<rand>) ─────────────
// A tight loop with no spacing lands many creates on the SAME millisecond; the random suffix
// must keep every id unique (no PRIMARY KEY collision). Pre-fix (pure Date.now) this collides.
{
  freshDb();
  const N = 50;
  let allOk = true;
  const ids = new Set();
  for (let i = 0; i < N; i++) {
    try {
      const r = await call('POST', '/api/products', { name: `Burst-${i}` });
      if (r?.success && typeof r.id === 'string') ids.add(r.id); else allOk = false;
    } catch { allOk = false; }
  }
  ok(allOk && ids.size === N, `[prod] ${N} rapid same-ms creates all succeed + unique ids (no PK collision), got ok=${allOk} unique=${ids.size}`);
}

// ───────────── inventory summary (per-product on-hand + tax-exclusive cost) ─────────────
{
  freshDb();
  const mkProduct = async (body) => (await call('POST', '/api/products', body)).id;
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

  // collectionRate = null (NOT 100) when there are no sales at all — no billing base,
  // so the rate is undefined and the UI shows an N/A empty state instead of a fake 100%.
  freshDb();
  const empty = await call('GET', '/api/receivables/summary', null);
  ok(empty.collectionRate === null && approx(empty.totalReceivable, 0) && empty.details.length === 0,
    '[recv] no sales → collectionRate null, receivable 0, no details');
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

  // paymentRate = null (NOT 100) when no purchases — see receivables empty case above.
  freshDb();
  const empty = await call('GET', '/api/payables/summary', null);
  ok(empty.paymentRate === null && approx(empty.totalPayable, 0) && empty.details.length === 0,
    '[pay] no purchases → paymentRate null, payable 0, no details');
}

// ───────────────── retained-earnings-preview (留存/未分配利润只读预览, PR-7B P2-4a) ─────────────────
// 只读：期末未分配利润 = 期初(settings) + 本期净利(P&L incomeStatement.netProfit；US→scheduleC.line31_netProfit) − 分红。
// 锁住：单一本位币(无 byCurrency)·entity_type 默认 individual·individual 下 owner_draw 不冲减·
// company 下 owner_draw 冲减(仅本位币·期间内·有日期; USD/无日期/期间外/capital 排除)·entity_type 非法→fallback·
// opening 允许负/NaN→0·netProfit 取自 reports·**不写回 equity/settings**·不自动年结。
{
  const db = freshDb();
  const RE = '?from=2026-01-01&to=2026-12-31';
  const mkDraw = (body) => call('POST', '/api/equity', { equity_type: 'owner_draw', ...body });

  // settings：期初 10000、本位币 CNY、CN 制度
  await call('PUT', '/api/settings', { opening_retained_earnings: 10000, currency: 'CNY', accounting_locale: 'CN' });
  // 本期损益：income 5000 / expense 2000（净利由 reports 引擎计算，交叉验证）
  const insTxn = db.prepare(`INSERT INTO transactions (id, type, date, amount, amount_net, currency, payment_status, paid_amount, payment_date) VALUES (?,?,?,?,?,?,?,?,?)`);
  insTxn.run('re-i1', 'income',  PD, 5000, 5000, 'CNY', 'paid', 5000, PD);
  insTxn.run('re-e1', 'expense', PD, 2000, 2000, 'CNY', 'paid', 2000, PD);
  // owner_draw：本位币期间内 1000(计入 company) + USD 300(非本位币排除) + 无日期 500(排除) + 期间外 700(排除)
  await mkDraw({ name: 'D-cny', amount: 1000, currency: 'CNY', event_date: PD });
  await mkDraw({ name: 'D-usd', amount: 300, currency: 'USD', event_date: PD });
  await mkDraw({ name: 'D-nodate', amount: 500, currency: 'CNY' });
  await mkDraw({ name: 'D-outside', amount: 700, currency: 'CNY', event_date: '2025-06-15' });
  // capital_contribution（非 owner_draw）不得计入分红
  await call('POST', '/api/equity', { name: 'C1', equity_type: 'capital_contribution', amount: 50000, currency: 'CNY', event_date: PD });

  // 交叉验证净利：reports 引擎 incomeStatement.netProfit
  const rep = await call('POST', '/api/reports/generate', { locale: 'CN', from: '2026-01-01', to: '2026-12-31' });
  const repNet = rep.incomeStatement.netProfit;

  // ── default entity_type=individual（settings 未设 entity_type）──
  const ind = await call('GET', `/api/retained-earnings-preview${RE}`, null);
  ok(ind.estimate === true && ind.reportType === 'retained_earnings_preview', '[re] estimate=true + reportType=retained_earnings_preview');
  ok(ind.entityType === 'individual', '[re] default entityType=individual (settings 未设 entity_type)');
  ok(ind.baseCurrency === 'CNY' && ind.byCurrency === undefined && ind.disclaimerKey === 'disclaimer.report', '[re] 单一本位币口径(无 byCurrency) + disclaimerKey');
  ok(approx(ind.openingRetainedEarnings, 10000), `[re] openingRetainedEarnings 取自 settings=10000, got ${ind.openingRetainedEarnings}`);
  ok(approx(ind.netProfit, repNet) && ind.netProfitSource === 'incomeStatement', `[re] netProfit 取自 incomeStatement.netProfit=${repNet}, got ${ind.netProfit}`);
  ok(approx(ind.distributions, 0), '[re] individual: distributions=0 (owner_draw 不冲减未分配利润)');
  ok(approx(ind.endingRetainedEarnings, 10000 + repNet - 0), '[re] individual ending = 期初 + 净利 − 0');
  ok(ind.excludedNotes.some((n) => /owner_draw|业主支取/.test(n)), '[re] individual excludedNotes 说明 owner_draw 留 P2-4b');

  // ── entity_type=company：owner_draw 冲减（仅本位币·期间内·有日期 → 仅 D-cny 1000）──
  await call('PUT', '/api/settings', { entity_type: 'company' });
  const comp = await call('GET', `/api/retained-earnings-preview${RE}`, null);
  ok(comp.entityType === 'company', '[re] entityType=company');
  ok(approx(comp.distributions, 1000), `[re] company distributions=1000 (仅本位币·期间内·有日期; USD/无日期/期间外/capital 排除), got ${comp.distributions}`);
  ok(approx(comp.endingRetainedEarnings, 10000 + comp.netProfit - 1000), '[re] company ending = 期初 + 净利 − 分红1000');
  ok(comp.excludedNotes.some((n) => /USD/.test(n)), '[re] company excludedNotes 提及非本位币 owner_draw 排除');
  ok(comp.excludedNotes.some((n) => /event_date|无法落入/.test(n)), '[re] company excludedNotes 提及无日期 owner_draw 排除');

  // ── entity_type 非法值 → fallback individual ──
  await call('PUT', '/api/settings', { entity_type: 'partnership' });
  ok((await call('GET', `/api/retained-earnings-preview${RE}`, null)).entityType === 'individual', '[re] 非法 entity_type → fallback individual');

  // ── opening 允许负 / NaN→0 ──
  await call('PUT', '/api/settings', { entity_type: 'individual', opening_retained_earnings: -2500 });
  ok(approx((await call('GET', `/api/retained-earnings-preview${RE}`, null)).openingRetainedEarnings, -2500), '[re] opening 允许负 (-2500)');
  db.prepare("INSERT OR REPLACE INTO settings (key, value) VALUES ('opening_retained_earnings', ?)").run(JSON.stringify('not-a-number'));
  ok(approx((await call('GET', `/api/retained-earnings-preview${RE}`, null)).openingRetainedEarnings, 0), '[re] opening NaN → 0');

  // ── 只读：调用后 equity / owner_draw 行不被写回 ──
  ok(db.prepare("SELECT COUNT(*) AS c FROM equity WHERE equity_type='owner_draw'").get().c === 4, '[re] read-only: owner_draw 行数不变(4)');
  ok(db.prepare("SELECT amount FROM equity WHERE name='D-cny'").get().amount === 1000, '[re] read-only: equity amount 不变');
}

// ── retained-earnings US 特判：netProfit 取 scheduleC.line31_netProfit ──
{
  const db = freshDb();
  const RE = '?from=2026-01-01&to=2026-12-31';
  await call('PUT', '/api/settings', { accounting_locale: 'US', currency: 'USD', opening_retained_earnings: 1000 });
  const insTxn = db.prepare(`INSERT INTO transactions (id, type, date, amount, amount_net, currency, payment_status, paid_amount, payment_date) VALUES (?,?,?,?,?,?,?,?,?)`);
  insTxn.run('us-i1', 'income',  PD, 9000, 9000, 'USD', 'paid', 9000, PD);
  insTxn.run('us-e1', 'expense', PD, 4000, 4000, 'USD', 'paid', 4000, PD);

  const rep = await call('POST', '/api/reports/generate', { locale: 'US', from: '2026-01-01', to: '2026-12-31' });
  const usNet = rep.scheduleC.line31_netProfit;

  const re = await call('GET', `/api/retained-earnings-preview${RE}`, null);
  ok(re.locale === 'US' && re.netProfitSource === 'scheduleC', '[re-us] US → netProfitSource=scheduleC (incomeStatement 缺席)');
  ok(approx(re.netProfit, usNet), `[re-us] netProfit 取自 scheduleC.line31_netProfit=${usNet}, got ${re.netProfit}`);
  ok(re.baseCurrency === 'USD' && approx(re.endingRetainedEarnings, 1000 + usNet - 0), '[re-us] ending = 期初 + scheduleC净利 − 0 (US default individual)');
  ok(re.limitations.some((l) => /Schedule C/.test(l)), '[re-us] limitations 标注 Schedule C 口径');
}

// ───────────────── income-tax-position (所得税同税种同期间对冲只读预览, PR-7B P3-1) ─────────────────
// 只读：期末应交所得税 = 本期应计(reports incomeStatement.incomeTax / US estimatedTax.annualIncomeTax) − 本期已缴(tax_payments)。
// 锁住：仅 income_tax·is_active=1·本位币·period 重叠 / payment_date 回退·partialPeriodOverlap warning·
// 非本位币/out_of_period/no_date 排除·负额冲正 warning·三态 payable/prepaid/zero·US accruedSource 特判·
// 亏损期 accrued<0 warning·**不写回 tax_payments·不触碰 reports**·VAT/other 排除。
{
  const db = freshDb();
  const ITQ = '?from=2026-01-01&to=2026-12-31';
  const mkTax = (body) => call('POST', '/api/tax-payments', { tax_type: 'income_tax', currency: 'CNY', ...body });

  await call('PUT', '/api/settings', { accounting_locale: 'CN', currency: 'CNY', income_tax_rate: 25 });
  // 本期损益（利润 → 应计所得税 > 0）
  const insTxn = db.prepare(`INSERT INTO transactions (id, type, date, amount, amount_net, currency, payment_status, paid_amount, payment_date) VALUES (?,?,?,?,?,?,?,?,?)`);
  insTxn.run('it-i1', 'income',  PD, 100000, 100000, 'CNY', 'paid', 100000, PD);
  insTxn.run('it-e1', 'expense', PD,  20000,  20000, 'CNY', 'paid',  20000, PD);

  // 已缴 income_tax 缴款：
  await mkTax({ name: 'T1-period', amount: 5000, period_start: '2026-01-01', period_end: '2026-12-31' });   // period 重叠(含)→matched basis=period
  await mkTax({ name: 'T2-paydate', amount: 3000, payment_date: '2026-03-10' });                            // 无 period → payment_date 回退
  await mkTax({ name: 'T3-partial', amount: 2000, period_start: '2026-10-01', period_end: '2027-03-31' });  // 越界→matched+partial warning
  await mkTax({ name: 'T4-outside', amount: 1000, period_start: '2025-01-01', period_end: '2025-12-31' });  // 期间外→excluded out_of_period
  await mkTax({ name: 'T5-nodate', amount: 9999 });                                                          // 无 period 无 payment_date→excluded no_date
  await mkTax({ name: 'T6-usd', amount: 500, currency: 'USD', payment_date: PD });                           // 非本位币→excluded non_base_currency
  await mkTax({ name: 'T7-neg', amount: -800, period_start: '2026-01-01', period_end: '2026-12-31' });       // 负额冲正→matched + negative warning
  await mkTax({ name: 'T8-vat', tax_type: 'vat', amount: 7777, period_start: '2026-01-01', period_end: '2026-12-31' }); // VAT→SQL 过滤，不出现
  await mkTax({ name: 'T9-inactive', amount: 6666, period_start: '2026-01-01', period_end: '2026-12-31', is_active: false }); // 停用→SQL 过滤

  const pos = await call('GET', `/api/income-tax-position${ITQ}`, null);
  // 元信息
  ok(pos.estimate === true && pos.reportType === 'income_tax_position' && pos.taxType === 'income_tax', '[itp] estimate/reportType/taxType');
  ok(pos.baseCurrency === 'CNY' && pos.locale === 'CN' && pos.accruedSource === 'incomeStatement.incomeTax', '[itp] CN accruedSource=incomeStatement.incomeTax');
  ok(pos.disclaimerKey === 'disclaimer.tax', '[itp] disclaimerKey=disclaimer.tax');
  // 应计交叉验证 reports
  const rep = await call('POST', '/api/reports/generate', { locale: 'CN', from: '2026-01-01', to: '2026-12-31' });
  ok(approx(pos.accruedIncomeTax, rep.incomeStatement.incomeTax) && pos.accruedIncomeTax > 0, `[itp] accrued 取自 incomeStatement.incomeTax=${rep.incomeStatement.incomeTax}, got ${pos.accruedIncomeTax}`);
  // 匹配：T1+T2+T3+T7 = 4 笔；paid = 5000+3000+2000−800 = 9200
  ok(pos.matchedPayments.length === 4, `[itp] matched 4 (T1/T2/T3/T7), got ${pos.matchedPayments.length}`);
  ok(approx(pos.paidIncomeTax, 9200), `[itp] paid=9200 (5000+3000+2000−800), got ${pos.paidIncomeTax}`);
  ok(pos.matchedPayments.find((m) => m.name === 'T1-period').matchBasis === 'period', '[itp] T1 matchBasis=period');
  ok(pos.matchedPayments.find((m) => m.name === 'T2-paydate').matchBasis === 'payment_date', '[itp] T2 matchBasis=payment_date (period 缺→回退)');
  // 排除：T4 out_of_period / T5 no_date / T6 non_base_currency = 3 笔；VAT/inactive 不出现
  ok(pos.excludedPayments.length === 3, `[itp] excluded 3 (T4/T5/T6), got ${pos.excludedPayments.length}`);
  ok(pos.excludedPayments.find((e) => e.name === 'T4-outside').reason === 'out_of_period', '[itp] T4 reason=out_of_period');
  ok(pos.excludedPayments.find((e) => e.name === 'T5-nodate').reason === 'no_date', '[itp] T5 reason=no_date');
  ok(pos.excludedPayments.find((e) => e.name === 'T6-usd').reason === 'non_base_currency', '[itp] T6 reason=non_base_currency');
  const allNames = [...pos.matchedPayments, ...pos.excludedPayments].map((x) => x.name);
  ok(!allNames.includes('T8-vat') && !allNames.includes('T9-inactive'), '[itp] VAT/inactive 经 SQL 过滤，不出现在 matched/excluded');
  // warnings：partialPeriodOverlap(T3) + negativePaymentPresent(T7)
  ok(pos.warnings.includes('partialPeriodOverlap'), '[itp] T3 越界 → partialPeriodOverlap warning');
  ok(pos.warnings.includes('negativePaymentPresent'), '[itp] T7 负额 → negativePaymentPresent warning');
  // netPosition = 应计 − 9200；应计>9200 → payable
  ok(approx(pos.netPosition, pos.accruedIncomeTax - 9200) && pos.positionType === 'payable', `[itp] netPosition=应计−9200·payable, got ${pos.netPosition}/${pos.positionType}`);
  // excludedNotes 提及非本位币 + 其它税种备查
  ok(pos.excludedNotes.some((n) => /USD/.test(n)) && pos.excludedNotes.some((n) => /VAT|备查/.test(n)), '[itp] excludedNotes 非本位币 + 其它税种备查');
  // **不写回 tax_payments**：9 行不变，T1 amount 不变
  ok(db.prepare('SELECT COUNT(*) AS c FROM tax_payments').get().c === 9, '[itp] read-only: tax_payments 行数不变(9)');
  ok(db.prepare("SELECT amount FROM tax_payments WHERE name='T1-period'").get().amount === 5000, '[itp] read-only: T1 amount 不变');
}

// ── income-tax-position：prepaid + zero 三态 ──
{
  const ITQ = '?from=2026-01-01&to=2026-12-31';
  // prepaid：无损益(应计 0) + 已缴 5000 → netPosition -5000 → prepaid
  freshDb();
  await call('PUT', '/api/settings', { accounting_locale: 'CN', currency: 'CNY', income_tax_rate: 25 });
  await call('POST', '/api/tax-payments', { tax_type: 'income_tax', currency: 'CNY', name: 'P1', amount: 5000, period_start: '2026-01-01', period_end: '2026-12-31' });
  const prepaid = await call('GET', `/api/income-tax-position${ITQ}`, null);
  ok(approx(prepaid.accruedIncomeTax, 0) && approx(prepaid.paidIncomeTax, 5000) && prepaid.positionType === 'prepaid', `[itp] prepaid: accrued 0 / paid 5000 / prepaid, got ${prepaid.positionType}`);
  // zero：无损益 + 无缴款 → 0/0 → zero
  freshDb();
  await call('PUT', '/api/settings', { accounting_locale: 'CN', currency: 'CNY', income_tax_rate: 25 });
  const zero = await call('GET', `/api/income-tax-position${ITQ}`, null);
  ok(approx(zero.accruedIncomeTax, 0) && approx(zero.paidIncomeTax, 0) && zero.positionType === 'zero' && zero.matchedPayments.length === 0, '[itp] zero: accrued 0 / paid 0 / zero / no matched');
}

// ── income-tax-position US 特判：accruedSource=estimatedTax.annualIncomeTax + 亏损期 accrued<0 warning ──
{
  const db = freshDb();
  const ITQ = '?from=2026-01-01&to=2026-12-31';
  await call('PUT', '/api/settings', { accounting_locale: 'US', currency: 'USD', income_tax_rate: 20 });
  // 亏损：expense > income → US annualIncomeTax = netProfit×率 < 0（不 clamp）
  const insTxn = db.prepare(`INSERT INTO transactions (id, type, date, amount, amount_net, currency, payment_status, paid_amount, payment_date) VALUES (?,?,?,?,?,?,?,?,?)`);
  insTxn.run('itu-i1', 'income',  PD, 3000, 3000, 'USD', 'paid', 3000, PD);
  insTxn.run('itu-e1', 'expense', PD, 9000, 9000, 'USD', 'paid', 9000, PD);

  const repUs = await call('POST', '/api/reports/generate', { locale: 'US', from: '2026-01-01', to: '2026-12-31' });
  const usAccrued = repUs.estimatedTax.annualIncomeTax;
  const pos = await call('GET', `/api/income-tax-position${ITQ}`, null);
  ok(pos.locale === 'US' && pos.accruedSource === 'estimatedTax.annualIncomeTax', '[itp-us] US accruedSource=estimatedTax.annualIncomeTax (incomeStatement 缺席)');
  ok(approx(pos.accruedIncomeTax, usAccrued) && pos.accruedIncomeTax < 0, `[itp-us] accrued 取自 estimatedTax.annualIncomeTax=${usAccrued} (亏损期为负), got ${pos.accruedIncomeTax}`);
  ok(pos.warnings.includes('accruedNegativeLossPeriod'), '[itp-us] 亏损期 accrued<0 → accruedNegativeLossPeriod warning');
  ok(pos.limitations.some((l) => /SE tax|自雇/.test(l)), '[itp-us] limitations 注明仅所得税不含 SE tax');
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

  // PR-7B P2-4a 新增白名单键 entity_type / opening_retained_earnings 往返（无 UI，仅白名单可持久化）
  await call('PUT', '/api/settings', { entity_type: 'company', opening_retained_earnings: 12345.67 });
  const s4 = await call('GET', '/api/settings', null);
  ok(s4.entity_type === 'company' && s4.opening_retained_earnings === 12345.67, '[set] entity_type/opening_retained_earnings round-trip (PR-7B P2-4a)');
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

// ───────────────────────── §2B Batch 5: conversations (chat history persistence) ─────────────────────────

// ── create / list (fields persist; documented columns) ──
{
  freshDb();
  const c1 = await call('POST', '/api/conversations', {});
  ok(c1?.id && typeof c1.id === 'string', `[conv] create → {id}, got ${JSON.stringify(c1)}`);
  const list1 = await call('GET', '/api/conversations', null);
  ok(list1.length === 1 && list1[0].id === c1.id && list1[0].title === null, '[conv] empty create → list 1 row, title null');

  const c2 = await call('POST', '/api/conversations', { title: 'My Chat', accLocale: 'CN', uiLanguage: 'zh-CN' });
  const row2 = (await call('GET', '/api/conversations', null)).find((c) => c.id === c2.id);
  ok(row2 && row2.title === 'My Chat' && row2.acc_locale === 'CN' && row2.ui_language === 'zh-CN', '[conv] create with title/accLocale/uiLanguage persists');
  ok('created_at' in row2 && 'updated_at' in row2, '[conv] list rows carry created_at/updated_at');
}

// ── list ordering by updated_at DESC (deterministic via direct UPDATE — datetime(now) is second-res) ──
{
  const db = freshDb();
  const a = (await call('POST', '/api/conversations', { title: 'A' })).id;
  const b = (await call('POST', '/api/conversations', { title: 'B' })).id;
  db.prepare("UPDATE assistant_conversations SET updated_at = ? WHERE id = ?").run('2024-01-01 00:00:02', a);
  db.prepare("UPDATE assistant_conversations SET updated_at = ? WHERE id = ?").run('2024-01-01 00:00:01', b);
  const ordered = await call('GET', '/api/conversations', null);
  ok(ordered[0].id === a && ordered[1].id === b, '[conv] list ordered by updated_at DESC (newest first)');
}

// ── append: missing-conv throw, seq order, role normalization ──
{
  freshDb();
  await expectThrow(() => call('POST', '/api/conversations/ghost/messages', { role: 'user', text: 'hi' }), '[conv] append to missing conversation throws');

  const cid = (await call('POST', '/api/conversations', {})).id;
  ok((await call('POST', `/api/conversations/${cid}/messages`, { role: 'user', text: 'first' }))?.ok === true, '[conv] append returns {ok:true}');
  await call('POST', `/api/conversations/${cid}/messages`, { role: 'model', text: 'second' });
  await call('POST', `/api/conversations/${cid}/messages`, { role: 'weird', text: 'third' }); // non-model → user

  const msgs = await call('GET', `/api/conversations/${cid}/messages`, null);
  ok(msgs.length === 3, `[conv] messages → 3 in seq order, got ${msgs.length}`);
  ok(msgs[0].role === 'user' && msgs[0].text === 'first', '[conv] msg1 user/first');
  ok(msgs[1].role === 'model' && msgs[1].text === 'second', '[conv] msg2 model/second');
  ok(msgs[2].role === 'user' && msgs[2].text === 'third', '[conv] msg3 role normalized (weird → user)');
}

// ── auto-title: first user message derives title (≤40, not overwritten); model-first stays null ──
{
  freshDb();
  const cid = (await call('POST', '/api/conversations', {})).id;
  await call('POST', `/api/conversations/${cid}/messages`, { role: 'user', text: 'What is my Q1 revenue?' });
  let row = (await call('GET', '/api/conversations', null)).find((c) => c.id === cid);
  ok(row.title === 'What is my Q1 revenue?' && row.title.length <= 40, '[conv] auto-title from first user message (≤40)');
  await call('POST', `/api/conversations/${cid}/messages`, { role: 'user', text: 'A completely different question' });
  row = (await call('GET', '/api/conversations', null)).find((c) => c.id === cid);
  ok(row.title === 'What is my Q1 revenue?', '[conv] second user message does NOT overwrite title');

  // title is truncated to 40 chars
  const cidLong = (await call('POST', '/api/conversations', {})).id;
  await call('POST', `/api/conversations/${cidLong}/messages`, { role: 'user', text: 'x'.repeat(50) });
  ok((await call('GET', '/api/conversations', null)).find((c) => c.id === cidLong).title.length === 40, '[conv] auto-title truncated to 40 chars');

  // model-first: title stays null until a user message arrives
  freshDb();
  const cid2 = (await call('POST', '/api/conversations', {})).id;
  await call('POST', `/api/conversations/${cid2}/messages`, { role: 'model', text: 'I can help.' });
  ok((await call('GET', '/api/conversations', null)).find((c) => c.id === cid2).title === null, '[conv] model-first message leaves title null');
  await call('POST', `/api/conversations/${cid2}/messages`, { role: 'user', text: 'Hello there' });
  ok((await call('GET', '/api/conversations', null)).find((c) => c.id === cid2).title === 'Hello there', '[conv] user message after model derives title');
}

// ── toolTrace round-trip (array present; absent → no key) ──
{
  freshDb();
  const cid = (await call('POST', '/api/conversations', {})).id;
  await call('POST', `/api/conversations/${cid}/messages`, { role: 'model', text: 'traced', toolTrace: [{ name: 'queryLedger', rowCount: 3 }] });
  await call('POST', `/api/conversations/${cid}/messages`, { role: 'user', text: 'plain' });
  const msgs = await call('GET', `/api/conversations/${cid}/messages`, null);
  const traced = msgs.find((m) => m.text === 'traced');
  const plain = msgs.find((m) => m.text === 'plain');
  ok(Array.isArray(traced.toolTrace) && traced.toolTrace.length === 1 && traced.toolTrace[0].name === 'queryLedger', '[conv] toolTrace array round-trips');
  ok(!('toolTrace' in plain), '[conv] message without toolTrace has no toolTrace key');
}

// ── rename (empty / whitespace → null) ──
{
  freshDb();
  const cid = (await call('POST', '/api/conversations', { title: 'Old' })).id;
  await call('PUT', `/api/conversations/${cid}`, { title: 'New Title' });
  ok((await call('GET', '/api/conversations', null)).find((c) => c.id === cid).title === 'New Title', '[conv] rename updates title');
  await call('PUT', `/api/conversations/${cid}`, { title: '' });
  ok((await call('GET', '/api/conversations', null)).find((c) => c.id === cid).title === null, '[conv] rename empty title → null');
  await call('PUT', `/api/conversations/${cid}`, { title: '   ' });
  ok((await call('GET', '/api/conversations', null)).find((c) => c.id === cid).title === null, '[conv] rename whitespace title → null');
}

// ── delete + CASCADE (messages removed; missing conv → []) ──
{
  freshDb();
  const cid = (await call('POST', '/api/conversations', { title: 'ToDelete' })).id;
  await call('POST', `/api/conversations/${cid}/messages`, { role: 'user', text: 'm1' });
  await call('POST', `/api/conversations/${cid}/messages`, { role: 'model', text: 'm2' });
  ok((await call('GET', `/api/conversations/${cid}/messages`, null)).length === 2, '[conv] 2 messages before delete');
  ok((await call('DELETE', `/api/conversations/${cid}`, null))?.ok === true, '[conv] delete returns {ok:true}');
  ok(!(await call('GET', '/api/conversations', null)).some((c) => c.id === cid), '[conv] deleted conversation gone from list');
  ok((await call('GET', `/api/conversations/${cid}/messages`, null)).length === 0, '[conv] CASCADE removed its messages (foreign_keys=ON)');
  ok((await call('GET', '/api/conversations/never/messages', null)).length === 0, '[conv] messages on never-existed conv → [] (no throw)');
}

// ───────────────────────── §2B: mileage + homeOffice (US Schedule C, deduction estimates) ─────────────────────────
// NOTE: lock arithmetic via EXPLICIT non-default inputs only. NEVER assert the IRS policy defaults
// (mileage rate_per_mile 0.67; home-office rate_per_sqft 5 / max_sqft 300) — those are policy constants.

// ── mileage: validation, generated `deduction` column, year filter, recompute, delete ──
{
  freshDb();
  // validation: date required; miles must be a number > 0
  await expectThrow(() => call('POST', '/api/mileage', { miles: 10 }), '[mile] missing date throws');
  await expectThrow(() => call('POST', '/api/mileage', { date: '2023-01-01', miles: 0 }), '[mile] miles 0 throws');
  await expectThrow(() => call('POST', '/api/mileage', { date: '2023-01-01', miles: -5 }), '[mile] miles -5 throws');
  await expectThrow(() => call('POST', '/api/mileage', { date: '2023-01-01', miles: '10' }), '[mile] non-number miles throws');

  // one-way: deduction = miles * rate_per_mile * (1 + round_trip) = 100 * 0.5 * 1 = 50 (generated column)
  const c1 = await call('POST', '/api/mileage', { date: '2023-03-01', miles: 100, rate_per_mile: 0.5, round_trip: false });
  ok(c1?.success && c1.id, `[mile] create → {success,id}, got ${JSON.stringify(c1)}`);
  let m1 = (await call('GET', '/api/mileage', null)).find((r) => r.id === c1.id);
  ok(m1 && m1.round_trip === 0, '[mile] one-way round_trip stored 0');
  ok(approx(m1.deduction, 50), `[mile] one-way deduction = 100*0.5*(1+0) = 50, got ${m1.deduction}`);

  // round-trip doubles via the (1 + round_trip) factor: 40 * 0.5 * 2 = 40
  const c2 = await call('POST', '/api/mileage', { date: '2023-03-02', miles: 40, rate_per_mile: 0.5, round_trip: true });
  const m2 = (await call('GET', '/api/mileage', null)).find((r) => r.id === c2.id);
  ok(m2 && m2.round_trip === 1, '[mile] round-trip round_trip stored 1');
  ok(approx(m2.deduction, 40), `[mile] round-trip deduction = 40*0.5*(1+1) = 40 (locks the (1+round_trip) factor), got ${m2.deduction}`);

  // a 2022 trip must be EXCLUDED from summary?year=2023
  await call('POST', '/api/mileage', { date: '2022-12-31', miles: 999, rate_per_mile: 0.5, round_trip: false });

  const sum = await call('GET', '/api/mileage/summary?year=2023', null);
  ok(sum.trips === 2, `[mile] summary?year=2023 trips = 2 (2022 excluded), got ${sum.trips}`);
  ok(approx(sum.totalMiles, 140), `[mile] totalMiles = 100+40 = 140, got ${sum.totalMiles}`);
  ok(approx(sum.totalDeduction, 90), `[mile] totalDeduction = 50+40 = 90, got ${sum.totalDeduction}`);

  // update a base column → generated deduction recomputes: 200 * 0.5 * 1 = 100
  await call('PUT', `/api/mileage/${c1.id}`, { miles: 200 });
  const m1b = (await call('GET', '/api/mileage', null)).find((r) => r.id === c1.id);
  ok(approx(m1b.deduction, 100), `[mile] update miles 200 → deduction recomputes = 200*0.5*1 = 100, got ${m1b.deduction}`);

  // delete
  await call('DELETE', `/api/mileage/${c2.id}`, null);
  ok(!(await call('GET', '/api/mileage', null)).some((r) => r.id === c2.id), '[mile] delete removes row');
}

// ── homeOffice: singleton get/save, simplified/cap/actual deduction, COALESCE partial, method CHECK ──
{
  freshDb();
  // default seeded singleton — structure only (deduction 0 because sqft 0; not a policy assertion)
  const def = await call('GET', '/api/home-office', null);
  ok(def.method === 'simplified' && approx(def.sqft, 0) && typeof def.deduction === 'number' && approx(def.deduction, 0),
    '[ho] default get: simplified, sqft 0, deduction 0');

  // simplified with EXPLICIT rate=4 (not the IRS 5) → deduction = min(100,300)*4 = 400
  const r1 = await call('PUT', '/api/home-office', { method: 'simplified', sqft: 100, rate_per_sqft: 4, max_sqft: 300 });
  ok(approx(r1.deduction, 400), `[ho] simplified deduction = min(100,300)*4 = 400 (reads stored rate, not 5), got ${r1.deduction}`);
  const g1 = await call('GET', '/api/home-office', null);
  ok(g1.method === 'simplified' && approx(g1.sqft, 100) && approx(g1.rate_per_sqft, 4) && approx(g1.max_sqft, 300), '[ho] save persists fields');
  ok(approx(g1.deduction, 400), '[ho] get recomputes deduction 400');

  // cap with EXPLICIT max=250 (not the IRS 300): min(400,250)*4 = 1000
  const r2 = await call('PUT', '/api/home-office', { sqft: 400, rate_per_sqft: 4, max_sqft: 250 });
  ok(approx(r2.deduction, 1000), `[ho] cap: min(400,250)*4 = 1000 (reads stored cap), got ${r2.deduction}`);

  // actual: round((rent+utilities+insurance+depreciation) * sqft/total_home_sqft) = round(13000*0.2) = 2600
  const r3 = await call('PUT', '/api/home-office', {
    method: 'actual', sqft: 200, total_home_sqft: 1000,
    annual_rent: 10000, annual_utilities: 2000, annual_insurance: 500, annual_depreciation: 500,
  });
  ok(approx(r3.deduction, 2600), `[ho] actual deduction = round(13000 * 200/1000) = 2600, got ${r3.deduction}`);

  // COALESCE partial: save only sqft → other fields retained
  await call('PUT', '/api/home-office', { sqft: 300 });
  const g4 = await call('GET', '/api/home-office', null);
  ok(g4.method === 'actual' && approx(g4.rate_per_sqft, 4) && approx(g4.max_sqft, 250) && approx(g4.total_home_sqft, 1000),
    '[ho] partial save retains untouched fields (COALESCE)');
  ok(approx(g4.sqft, 300), '[ho] partial save updated sqft');

  // invalid method violates CHECK(method IN ('simplified','actual')) → throws
  await expectThrow(() => call('PUT', '/api/home-office', { method: 'bogus' }), '[ho] invalid method → CHECK constraint throws');
}

// ───────────── §2B Batch 7: legacy data-migration handler (sales/purchases → transactions) ─────────────
// 对象：electron/handlers/migrations.js（detectLegacy / migrateAll / rollback）。纯 DB，零 fs/electron。
// ≠ schema 迁移（test-migrations.mjs，勿碰）。只锁现有行为；category 只断言「已赋值且为真实类别」，不锁具体默认 id。
{
  const db = freshDb();

  // A. detectLegacy on empty head DB — tables exist, all counts 0, no legacy
  const d0 = await call('GET', '/api/migrations/detect-legacy', null);
  ok(d0.sales.exists === true && d0.purchases.exists === true, '[mig] empty: sales/purchases tables exist');
  ok(d0.sales.total === 0 && d0.sales.migrated === 0 && d0.sales.pending === 0, `[mig] empty: sales counts all 0, got ${JSON.stringify(d0.sales)}`);
  ok(d0.purchases.total === 0 && d0.purchases.migrated === 0 && d0.purchases.pending === 0, `[mig] empty: purchases counts all 0, got ${JSON.stringify(d0.purchases)}`);
  ok(d0.hasLegacy === false, '[mig] empty: hasLegacy false');

  // B. seed legacy rows (arrange via direct INSERT — no single-row legacy create handler exists), then detect
  const insSale = db.prepare('INSERT INTO sales (id, date, customer, tons, pricePerTon, totalAmount, amountWithoutTax, taxAmount, taxRate, invoiceNumber, invoiceStatus) VALUES (?,?,?,?,?,?,?,?,?,?,?)');
  const insPur = db.prepare('INSERT INTO purchases (id, date, supplier, tons, pricePerTon, totalAmount, amountWithoutTax, taxAmount, taxRate, invoiceNumber, invoiceStatus) VALUES (?,?,?,?,?,?,?,?,?,?,?)');
  insSale.run('s1', `${YEAR}-03-01`, 'Cust A', 10, 200, 2260, 2000, 260, 13, 'INV-S1', '已开'); // → issued
  insSale.run('s2', `${YEAR}-03-02`, 'Cust B', 5, 100, 1130, 1000, 130, 13, 'INV-S2', '待收');  // → pending
  insPur.run('p1', `${YEAR}-03-03`, 'Sup A', 8, 50, 565, 500, 65, 13, 'INV-P1', '已收');         // → issued
  insPur.run('p2', `${YEAR}-03-04`, 'Sup B', 4, 30, 339, 300, 39, 13, null, 'foo');              // → n/a

  const d1 = await call('GET', '/api/migrations/detect-legacy', null);
  ok(d1.sales.total === 2 && d1.sales.migrated === 0 && d1.sales.pending === 2, `[mig] seeded: sales pending 2, got ${JSON.stringify(d1.sales)}`);
  ok(d1.purchases.total === 2 && d1.purchases.migrated === 0 && d1.purchases.pending === 2, `[mig] seeded: purchases pending 2, got ${JSON.stringify(d1.purchases)}`);
  ok(d1.hasLegacy === true, '[mig] seeded: hasLegacy true');

  // C. run migration — sales→income · purchases→expense · field mapping · default currency CNY (no body, no settings 'currency')
  const run1 = await call('POST', '/api/migrations/run', {});
  ok(run1.salesMigrated === 2 && run1.purchasesMigrated === 2, `[mig] run: 2 sales + 2 purchases migrated, got ${JSON.stringify(run1)}`);
  ok(run1.salesSkipped === 0 && run1.purchasesSkipped === 0 && run1.errors.length === 0, `[mig] run: no skips/errors, got ${JSON.stringify(run1)}`);

  const incomeTxns = db.prepare("SELECT * FROM transactions WHERE type='income'").all();
  const expenseTxns = db.prepare("SELECT * FROM transactions WHERE type='expense'").all();
  ok(incomeTxns.length === 2, `[mig] run: 2 income transactions, got ${incomeTxns.length}`);
  ok(expenseTxns.length === 2, `[mig] run: 2 expense transactions, got ${expenseTxns.length}`);

  // sales s1 → income field mapping (locate via source_meta.legacy_id; never assert by generated txn id)
  const tS1 = incomeTxns.find((t) => JSON.parse(t.source_meta).legacy_id === 's1');
  ok(!!tS1, '[mig] run: income txn for s1 exists');
  ok(tS1.counterparty === 'Cust A', '[mig] map: sales.customer → counterparty');
  ok(approx(tS1.amount, 2260), `[mig] map: totalAmount → amount (2260), got ${tS1.amount}`);
  ok(approx(tS1.amount_net, 2000), `[mig] map: amountWithoutTax → amount_net (2000), got ${tS1.amount_net}`);
  ok(approx(tS1.tax_amount, 260), `[mig] map: taxAmount → tax_amount (260), got ${tS1.tax_amount}`);
  ok(tS1.invoice_no === 'INV-S1', '[mig] map: invoiceNumber → invoice_no');
  ok(tS1.invoice_status === 'issued', '[mig] map: invoiceStatus 已开 → issued');
  ok(tS1.currency === 'CNY', `[mig] run: default currency CNY (no body, no settings), got ${tS1.currency}`);
  ok(tS1.category_id != null, '[mig] run: income category assigned (id not locked)');
  ok(!!db.prepare('SELECT 1 FROM categories WHERE id=?').get(tS1.category_id), '[mig] run: income category_id is a real category');
  const smS1 = JSON.parse(tS1.source_meta);
  ok(smS1.migrated_from === 'sales' && smS1.legacy_id === 's1', '[mig] run: source_meta has migrated_from/legacy_id (sales)');

  // purchases p1 → expense field mapping
  const tP1 = expenseTxns.find((t) => JSON.parse(t.source_meta).legacy_id === 'p1');
  ok(!!tP1 && tP1.counterparty === 'Sup A', '[mig] map: purchases.supplier → counterparty');
  ok(tP1.invoice_status === 'issued', '[mig] map: invoiceStatus 已收 → issued');
  ok(tP1.category_id != null && !!db.prepare('SELECT 1 FROM categories WHERE id=?').get(tP1.category_id), '[mig] run: expense category assigned (real category, id not locked)');
  ok(JSON.parse(tP1.source_meta).migrated_from === 'purchases', '[mig] run: source_meta migrated_from purchases');

  // D. idempotency — re-run skips everything, no dup transactions, mapping count stable
  const mapBefore = db.prepare('SELECT COUNT(*) AS n FROM legacy_migrations').get().n;
  const run2 = await call('POST', '/api/migrations/run', {});
  ok(run2.salesMigrated === 0 && run2.purchasesMigrated === 0, `[mig] idempotent: re-run migrates 0, got ${JSON.stringify(run2)}`);
  ok(db.prepare('SELECT COUNT(*) AS n FROM transactions').get().n === 4, '[mig] idempotent: still 4 transactions (no dup)');
  ok(db.prepare('SELECT COUNT(*) AS n FROM legacy_migrations').get().n === mapBefore, '[mig] idempotent: legacy_migrations count unchanged');

  // E. detect after run — migrated=total, pending=0, hasLegacy false
  const d2 = await call('GET', '/api/migrations/detect-legacy', null);
  ok(d2.sales.migrated === 2 && d2.sales.pending === 0, `[mig] post-run: sales migrated=total, pending 0, got ${JSON.stringify(d2.sales)}`);
  ok(d2.purchases.migrated === 2 && d2.purchases.pending === 0, `[mig] post-run: purchases migrated=total, pending 0, got ${JSON.stringify(d2.purchases)}`);
  ok(d2.hasLegacy === false, '[mig] post-run: hasLegacy false');

  // F. rollback — removes migrated transactions + clears mapping; legacy rows untouched
  const rb = await call('POST', '/api/migrations/rollback', {});
  ok(rb.success === true && rb.removed === 4, `[mig] rollback: removed 4, got ${JSON.stringify(rb)}`);
  ok(db.prepare('SELECT COUNT(*) AS n FROM transactions').get().n === 0, '[mig] rollback: transactions cleared');
  ok(db.prepare('SELECT COUNT(*) AS n FROM legacy_migrations').get().n === 0, '[mig] rollback: legacy_migrations cleared');
  ok(db.prepare('SELECT COUNT(*) AS n FROM sales').get().n === 2, '[mig] rollback: legacy sales preserved');
  ok(db.prepare('SELECT COUNT(*) AS n FROM purchases').get().n === 2, '[mig] rollback: legacy purchases preserved');

  // G. rerun after rollback — mapping truly cleared, migrates again
  const run3 = await call('POST', '/api/migrations/run', {});
  ok(run3.salesMigrated === 2 && run3.purchasesMigrated === 2, `[mig] rerun-after-rollback: re-migrates 2+2, got ${JSON.stringify(run3)}`);
  ok(db.prepare('SELECT COUNT(*) AS n FROM transactions').get().n === 4, '[mig] rerun-after-rollback: 4 transactions again');
}

// H. invoiceStatus mapping matrix (已开·已收→issued / 待开·待收→pending / else·null→n/a)
{
  const db = freshDb();
  const insSale = db.prepare('INSERT INTO sales (id, date, customer, totalAmount, invoiceStatus) VALUES (?,?,?,?,?)');
  insSale.run('m_open', `${YEAR}-04-01`, 'C1', 100, '已开');  // → issued
  insSale.run('m_recv', `${YEAR}-04-02`, 'C2', 100, '已收');  // → issued
  insSale.run('m_topn', `${YEAR}-04-03`, 'C3', 100, '待开');  // → pending
  insSale.run('m_trcv', `${YEAR}-04-04`, 'C4', 100, '待收');  // → pending
  insSale.run('m_othr', `${YEAR}-04-05`, 'C5', 100, '草稿');  // → n/a
  insSale.run('m_null', `${YEAR}-04-06`, 'C6', 100, null);    // → n/a
  await call('POST', '/api/migrations/run', {});
  const rows = db.prepare("SELECT invoice_status, source_meta FROM transactions WHERE type='income'").all();
  const statusOf = (lid) => {
    const t = rows.find((r) => JSON.parse(r.source_meta).legacy_id === lid);
    return t && t.invoice_status;
  };
  ok(statusOf('m_open') === 'issued' && statusOf('m_recv') === 'issued', '[mig] map: 已开/已收 → issued');
  ok(statusOf('m_topn') === 'pending' && statusOf('m_trcv') === 'pending', '[mig] map: 待开/待收 → pending');
  ok(statusOf('m_othr') === 'n/a' && statusOf('m_null') === 'n/a', '[mig] map: other/null → n/a');
}

// I. body override — defaultIncomeCategoryId / defaultExpenseCategoryId / currency honored (passed ids used verbatim, not locked to defaults)
{
  const db = freshDb();
  // pick real category ids without hardcoding which: take the LAST by sort_order so override is provably distinct from the handler default (first by sort_order)
  const incCats = db.prepare("SELECT id FROM categories WHERE locale='CN' AND type='income' ORDER BY sort_order").all();
  const expCats = db.prepare("SELECT id FROM categories WHERE locale='CN' AND type='expense' ORDER BY sort_order").all();
  ok(incCats.length > 0 && expCats.length > 0, '[mig] override: CN income/expense categories seeded (precondition)');
  const pickedInc = incCats[incCats.length - 1].id;
  const pickedExp = expCats[expCats.length - 1].id;
  db.prepare('INSERT INTO sales (id, date, customer, totalAmount) VALUES (?,?,?,?)').run('ov_s', `${YEAR}-05-01`, 'OvCust', 500);
  db.prepare('INSERT INTO purchases (id, date, supplier, totalAmount) VALUES (?,?,?,?)').run('ov_p', `${YEAR}-05-02`, 'OvSup', 400);
  const runOv = await call('POST', '/api/migrations/run', { defaultIncomeCategoryId: pickedInc, defaultExpenseCategoryId: pickedExp, currency: 'USD' });
  ok(runOv.salesMigrated === 1 && runOv.purchasesMigrated === 1, `[mig] override: 1+1 migrated, got ${JSON.stringify(runOv)}`);
  const ti = db.prepare("SELECT * FROM transactions WHERE type='income'").get();
  const te = db.prepare("SELECT * FROM transactions WHERE type='expense'").get();
  ok(ti.category_id === pickedInc, '[mig] override: income uses body defaultIncomeCategoryId');
  ok(te.category_id === pickedExp, '[mig] override: expense uses body defaultExpenseCategoryId');
  ok(ti.currency === 'USD' && te.currency === 'USD', `[mig] override: body currency USD applied, got income=${ti.currency} expense=${te.currency}`);
}

// ───────────── §2B Batch 8: business documents handler (fs-free subset) ─────────────
// 对象：electron/handlers/documents.js（next-number / list / create / get / update / tax-invoice / remove）。
// 只覆盖无 fs 子集——绝不触发 safeDeleteAttachment 的真实 fs 删除路径（require('electron').app 在本测试环境为 undefined）。
// OUT-OF-SCOPE（本批故意不覆盖，留真 Electron e2e / attachment IPC 测试）：
//   1) updateTaxInvoice 替换/清除「已有」attachment path 时的 safeDeleteAttachment fs 分支（oldPathToDelete 非空）。
//   2) remove 带 tax_invoice_attachment_path 的 void 单据时的 safeDeleteAttachment fs 分支。
// 为守住该边界，本批：任何被赋予 attachment path 的单据都不再改路径、不再 remove；不 mock electron、不做真实 fs。

// A. next-number — empty→PREFIX-YYYY-0001 · suffix bumps after a matching number · missing/invalid type throws
{
  freshDb();
  const n0 = await call('GET', '/api/documents/next-number?type=quotation', null);
  ok(n0.number === `QT-${YEAR}-0001`, `[doc] next-number empty quotation = QT-${YEAR}-0001, got ${n0.number}`);
  ok(n0.number.startsWith(`QT-${YEAR}-`), '[doc] next-number includes prefix + current year');
  // seed a matching number (QT-YEAR-####) → suffix max bumps
  await call('POST', '/api/documents', { doc_type: 'quotation', doc_number: `QT-${YEAR}-0007`, customer_name: 'C', doc_date: `${YEAR}-01-01` });
  const n1 = await call('GET', '/api/documents/next-number?type=quotation', null);
  ok(n1.number === `QT-${YEAR}-0008`, `[doc] next-number bumps to QT-${YEAR}-0008, got ${n1.number}`);
  // a custom (non PREFIX-YEAR-####) number must not pollute the max
  await call('POST', '/api/documents', { doc_type: 'quotation', doc_number: 'CUSTOM-9999', customer_name: 'C', doc_date: `${YEAR}-01-02` });
  ok((await call('GET', '/api/documents/next-number?type=quotation', null)).number === `QT-${YEAR}-0008`, '[doc] custom number does not pollute next-number max');
  await expectThrow(() => call('GET', '/api/documents/next-number', null), '[doc] next-number missing type throws');
  await expectThrow(() => call('GET', '/api/documents/next-number?type=bogus', null), '[doc] next-number invalid type throws');
}

// B. create validation — each missing required field throws; invalid doc_type throws
{
  freshDb();
  await expectThrow(() => call('POST', '/api/documents', { doc_number: 'X-1', customer_name: 'C', doc_date: `${YEAR}-01-01` }), '[doc] create missing doc_type throws');
  await expectThrow(() => call('POST', '/api/documents', { doc_type: 'quotation', customer_name: 'C', doc_date: `${YEAR}-01-01` }), '[doc] create missing doc_number throws');
  await expectThrow(() => call('POST', '/api/documents', { doc_type: 'quotation', doc_number: 'X-1', doc_date: `${YEAR}-01-01` }), '[doc] create missing customer_name throws');
  await expectThrow(() => call('POST', '/api/documents', { doc_type: 'quotation', doc_number: 'X-1', customer_name: 'C' }), '[doc] create missing doc_date throws');
  await expectThrow(() => call('POST', '/api/documents', { doc_type: 'bogus', doc_number: 'X-1', customer_name: 'C', doc_date: `${YEAR}-01-01` }), '[doc] create invalid doc_type throws');
}

// C. create success — {success,id} · default status draft · acc_locale frozen at create (from body, distinct from settings)
{
  freshDb();
  const r = await call('POST', '/api/documents', {
    id: 'ignored-by-handler', doc_type: 'quotation', doc_number: 'QT-FIX-001', customer_name: 'Acme Co', doc_date: `${YEAR}-02-01`,
    acc_locale: 'CN',
    items: [{ description: 'Item A', amount: 100, tax_amount: 13 }, { description: 'Item B', amount: 200, tax_amount: 26 }],
  });
  ok(r && r.success === true && typeof r.id === 'string', `[doc] create → {success,id}, got ${JSON.stringify(r)}`);
  ok(r.id !== 'ignored-by-handler' && r.id.startsWith('doc-'), '[doc] create generates its own id (body.id ignored)');
  const doc = await call('GET', `/api/documents/${r.id}`, null);
  ok(doc.status === 'draft', `[doc] create default status draft, got ${doc.status}`);
  ok(doc.acc_locale === 'CN', `[doc] acc_locale frozen CN, got ${doc.acc_locale}`);
  ok(doc.doc_number === 'QT-FIX-001' && doc.customer_name === 'Acme Co', '[doc] create persists number + customer');
  ok(doc.items.length === 2, `[doc] create persists 2 items, got ${doc.items.length}`);
  ok(approx(doc.subtotal, 300) && approx(doc.tax_amount, 39) && approx(doc.total, 339), `[doc] header totals = Σamount/Σtax/total, got ${JSON.stringify({ s: doc.subtotal, t: doc.tax_amount, tot: doc.total })}`);
  // acc_locale honored from body (JP), proving the frozen value is the create-time input, not the CN setting
  const r2 = await call('POST', '/api/documents', { doc_type: 'quotation', doc_number: 'QT-FIX-002', customer_name: 'JP Co', doc_date: `${YEAR}-02-02`, acc_locale: 'JP' });
  ok((await call('GET', `/api/documents/${r2.id}`, null)).acc_locale === 'JP', '[doc] acc_locale honors body value (JP, not settings CN)');
}

// D. DOC_NUMBER_EXISTS — composite unique is (doc_type, doc_number)
{
  freshDb();
  const a = await call('POST', '/api/documents', { doc_type: 'quotation', doc_number: 'DUP-1', customer_name: 'C', doc_date: `${YEAR}-01-01` });
  ok(a.success, '[doc] dup: first create ok');
  let dupErr = null;
  try { await call('POST', '/api/documents', { doc_type: 'quotation', doc_number: 'DUP-1', customer_name: 'C2', doc_date: `${YEAR}-01-02` }); } catch (e) { dupErr = e?.message || String(e); }
  ok(dupErr === 'DOC_NUMBER_EXISTS', `[doc] same type+number → DOC_NUMBER_EXISTS, got ${dupErr}`);
  // different doc_type, same doc_number → allowed (unique is on the (doc_type, doc_number) pair)
  const b = await call('POST', '/api/documents', { doc_type: 'sales_order', doc_number: 'DUP-1', customer_name: 'C3', doc_date: `${YEAR}-01-03` });
  ok(b.success === true, '[doc] different doc_type, same doc_number → allowed (composite unique)');
}

// E. get / list — header+items · type filter · all · no-type · invalid type throw · missing id throw · doc_date DESC
{
  freshDb();
  const q1 = await call('POST', '/api/documents', { doc_type: 'quotation', doc_number: 'L-1', customer_name: 'C1', doc_date: `${YEAR}-01-01`, items: [{ description: 'x', amount: 10 }] });
  await call('POST', '/api/documents', { doc_type: 'quotation', doc_number: 'L-2', customer_name: 'C2', doc_date: `${YEAR}-03-01` });
  await call('POST', '/api/documents', { doc_type: 'sales_order', doc_number: 'SO-1', customer_name: 'C3', doc_date: `${YEAR}-02-01` });

  const got = await call('GET', `/api/documents/${q1.id}`, null);
  ok(got.id === q1.id && Array.isArray(got.items) && got.items.length === 1, '[doc] get returns header + items');

  const lq = await call('GET', '/api/documents?type=quotation', null);
  ok(lq.length === 2 && lq.every((d) => d.doc_type === 'quotation'), `[doc] list?type=quotation → 2 quotations, got ${lq.length}`);
  ok(lq[0].doc_number === 'L-2' && lq[1].doc_number === 'L-1', `[doc] list ordered by doc_date DESC, got ${lq.map((d) => d.doc_number)}`);

  ok((await call('GET', '/api/documents?type=all', null)).length === 3, '[doc] list?type=all → 3');
  ok((await call('GET', '/api/documents', null)).length === 3, '[doc] list no type → all 3');
  await expectThrow(() => call('GET', '/api/documents?type=bogus', null), '[doc] list invalid type throws');

  let getErr = null;
  try { await call('GET', '/api/documents/nope', null); } catch (e) { getErr = e?.message || String(e); }
  ok(getErr === 'Document not found', `[doc] get missing id → 'Document not found', got ${getErr}`);
}

// F. items / totals — sumTotals sums stored amount/tax_amount ONLY (never recompute qty×price) · line_no order · blank desc dropped
{
  freshDb();
  const r = await call('POST', '/api/documents', {
    doc_type: 'quotation', doc_number: 'IT-1', customer_name: 'C', doc_date: `${YEAR}-01-01`,
    items: [
      { description: 'second', amount: 50, tax_amount: 5, line_no: 2 },
      { description: 'first', amount: 100, tax_amount: 13, line_no: 1 },
      { description: '   ', amount: 999, tax_amount: 999 }, // blank description → dropped by sanitizeItems
    ],
  });
  const doc = await call('GET', `/api/documents/${r.id}`, null);
  ok(doc.items.length === 2, `[doc] blank-description row dropped → 2 items, got ${doc.items.length}`);
  ok(doc.items[0].line_no === 1 && doc.items[0].description === 'first', '[doc] items ordered by line_no ASC (1st)');
  ok(doc.items[1].line_no === 2 && doc.items[1].description === 'second', '[doc] items ordered by line_no ASC (2nd)');
  ok(approx(doc.subtotal, 150), `[doc] subtotal = 100+50 = 150 (blank excluded), got ${doc.subtotal}`);
  ok(approx(doc.tax_amount, 18), `[doc] tax_amount = 13+5 = 18, got ${doc.tax_amount}`);
  ok(approx(doc.total, 168), `[doc] total = subtotal+tax = 168, got ${doc.total}`);
}

// G. update — draft edits + totals recompute · acc_locale ignored (frozen) · empty no-op · state machine · non-draft edit rejected
{
  freshDb();
  const r = await call('POST', '/api/documents', {
    doc_type: 'quotation', doc_number: 'UP-1', customer_name: 'Old Name', doc_date: `${YEAR}-01-01`, acc_locale: 'CN',
    items: [{ description: 'orig', amount: 10, tax_amount: 1 }], notes: 'orig notes',
  });

  await call('PUT', `/api/documents/${r.id}`, {
    customer_name: 'New Name', notes: 'new notes',
    items: [{ description: 'a', amount: 20, tax_amount: 2 }, { description: 'b', amount: 30, tax_amount: 3 }],
    acc_locale: 'US', // must be IGNORED (frozen at create)
  });
  const d1 = await call('GET', `/api/documents/${r.id}`, null);
  ok(d1.customer_name === 'New Name' && d1.notes === 'new notes', '[doc] update edits customer_name/notes');
  ok(d1.items.length === 2 && approx(d1.subtotal, 50) && approx(d1.tax_amount, 5), '[doc] update replaces items + recomputes totals');
  ok(d1.acc_locale === 'CN', '[doc] update IGNORES acc_locale (frozen at create)');

  // empty body → no-op success (draft state preserved)
  const noop = await call('PUT', `/api/documents/${r.id}`, {});
  ok(noop && noop.success === true, '[doc] empty update body → no-op success');

  // invalid status value rejected (still draft here)
  await expectThrow(() => call('PUT', `/api/documents/${r.id}`, { status: 'bogus' }), '[doc] invalid status value rejected');

  // draft → issued
  ok((await call('PUT', `/api/documents/${r.id}`, { status: 'issued' })).success === true, '[doc] draft → issued ok');
  ok((await call('GET', `/api/documents/${r.id}`, null)).status === 'issued', '[doc] status now issued');

  // issued: editing EDITABLE fields rejected (Only draft can be edited)
  await expectThrow(() => call('PUT', `/api/documents/${r.id}`, { customer_name: 'Nope' }), '[doc] issued: field edit rejected');

  // issued → void (status-only transition allowed)
  ok((await call('PUT', `/api/documents/${r.id}`, { status: 'void' })).success === true, '[doc] issued → void ok');
  ok((await call('GET', `/api/documents/${r.id}`, null)).status === 'void', '[doc] status now void');

  // void terminal: void → issued rejected
  await expectThrow(() => call('PUT', `/api/documents/${r.id}`, { status: 'issued' }), '[doc] void → issued rejected (terminal)');
}

// H. updateTaxInvoice (fs-free subset) — see OUT-OF-SCOPE note above; never sets oldPathToDelete, never triggers safeDeleteAttachment
{
  // doc1: set issued/number/date (no path), then a VALID path FIRST time (existing path null → oldPathToDelete stays null)
  const d1c = await call('POST', '/api/documents', { doc_type: 'commercial_invoice', doc_number: 'TI-1', customer_name: 'C1', doc_date: `${YEAR}-01-01` });
  const u1 = await call('PUT', `/api/documents/${d1c.id}/tax-invoice`, { tax_invoice_issued: true, tax_invoice_number: 'FP-12345', tax_invoice_date: `${YEAR}-01-05` });
  ok(u1.success === true, '[doc] tax-invoice set issued/number/date → success');
  const g1 = await call('GET', `/api/documents/${d1c.id}`, null);
  ok(g1.tax_invoice_issued === 1 && g1.tax_invoice_number === 'FP-12345' && g1.tax_invoice_date === `${YEAR}-01-05`, '[doc] tax invoice fields persisted (issued stored as 1)');
  const u2 = await call('PUT', `/api/documents/${d1c.id}/tax-invoice`, { tax_invoice_attachment_path: 'attachments/docs/ti-1-abc.pdf' });
  ok(u2.success === true, '[doc] first-time attachment path set → success (no fs: previous path was null)');
  ok((await call('GET', `/api/documents/${d1c.id}`, null)).tax_invoice_attachment_path === 'attachments/docs/ti-1-abc.pdf', '[doc] attachment path persisted');
  // NOTE: d1c now holds a path → it is deliberately never re-pathed or removed below (would hit the fs branch).

  // empty tax-invoice body → no-op success
  ok((await call('PUT', `/api/documents/${d1c.id}/tax-invoice`, {})).success === true, '[doc] empty tax-invoice body → no-op success');

  // d2: issued boolean coercion (false → 0) on a separate doc with NO path
  const d2c = await call('POST', '/api/documents', { doc_type: 'commercial_invoice', doc_number: 'TI-2', customer_name: 'C2', doc_date: `${YEAR}-01-02` });
  await call('PUT', `/api/documents/${d2c.id}/tax-invoice`, { tax_invoice_issued: false });
  ok((await call('GET', `/api/documents/${d2c.id}`, null)).tax_invoice_issued === 0, '[doc] tax_invoice_issued false → stored 0');

  // INVALID_ATTACHMENT_PATH — pure regex throws before any fs (d2 has no existing path)
  let invErr = null;
  try { await call('PUT', `/api/documents/${d2c.id}/tax-invoice`, { tax_invoice_attachment_path: '../escape.pdf' }); } catch (e) { invErr = e?.message || String(e); }
  ok(invErr === 'INVALID_ATTACHMENT_PATH', `[doc] invalid attachment path → INVALID_ATTACHMENT_PATH, got ${invErr}`);

  // ATTACHMENT_IN_USE — first-time set of a path already owned by d1c throws before sets/oldPathToDelete (no fs)
  let useErr = null;
  try { await call('PUT', `/api/documents/${d2c.id}/tax-invoice`, { tax_invoice_attachment_path: 'attachments/docs/ti-1-abc.pdf' }); } catch (e) { useErr = e?.message || String(e); }
  ok(useErr === 'ATTACHMENT_IN_USE', `[doc] shared attachment path → ATTACHMENT_IN_USE, got ${useErr}`);

  // void document → tax-invoice readonly (throws before any path logic / fs)
  const d3c = await call('POST', '/api/documents', { doc_type: 'commercial_invoice', doc_number: 'TI-3', customer_name: 'C3', doc_date: `${YEAR}-01-03` });
  await call('PUT', `/api/documents/${d3c.id}`, { status: 'void' });
  let voErr = null;
  try { await call('PUT', `/api/documents/${d3c.id}/tax-invoice`, { tax_invoice_number: 'X' }); } catch (e) { voErr = e?.message || String(e); }
  ok(voErr === 'DOC_VOID_TAX_INVOICE_READONLY', `[doc] void doc tax-invoice → DOC_VOID_TAX_INVOICE_READONLY, got ${voErr}`);
}

// I. remove (fs-free subset) — only documents WITHOUT an attachment path (see OUT-OF-SCOPE note)
{
  const db = freshDb();
  // draft with items → delete → gone + items FK CASCADE
  const dr = await call('POST', '/api/documents', { doc_type: 'quotation', doc_number: 'RM-1', customer_name: 'C', doc_date: `${YEAR}-01-01`, items: [{ description: 'x', amount: 10 }, { description: 'y', amount: 20 }] });
  ok(db.prepare('SELECT COUNT(*) AS n FROM business_document_items WHERE doc_id = ?').get(dr.id).n === 2, '[doc] precondition: 2 items inserted');
  ok((await call('DELETE', `/api/documents/${dr.id}`, null)).success === true, '[doc] delete draft → success');
  await expectThrow(() => call('GET', `/api/documents/${dr.id}`, null), '[doc] deleted doc get → throws');
  ok(db.prepare('SELECT COUNT(*) AS n FROM business_document_items WHERE doc_id = ?').get(dr.id).n === 0, '[doc] items removed via FK CASCADE');

  // non-existent id → Document not found
  let rmErr = null;
  try { await call('DELETE', '/api/documents/nope', null); } catch (e) { rmErr = e?.message || String(e); }
  ok(rmErr === 'Document not found', `[doc] delete missing id → 'Document not found', got ${rmErr}`);

  // issued doc → DOC_ISSUED_VOID_FIRST
  const di = await call('POST', '/api/documents', { doc_type: 'quotation', doc_number: 'RM-2', customer_name: 'C', doc_date: `${YEAR}-01-02` });
  await call('PUT', `/api/documents/${di.id}`, { status: 'issued' });
  let issErr = null;
  try { await call('DELETE', `/api/documents/${di.id}`, null); } catch (e) { issErr = e?.message || String(e); }
  ok(issErr === 'DOC_ISSUED_VOID_FIRST', `[doc] delete issued → DOC_ISSUED_VOID_FIRST, got ${issErr}`);

  // void doc WITHOUT attachment path → deletable (no safeDeleteAttachment fs branch)
  const dv = await call('POST', '/api/documents', { doc_type: 'quotation', doc_number: 'RM-3', customer_name: 'C', doc_date: `${YEAR}-01-03` });
  await call('PUT', `/api/documents/${dv.id}`, { status: 'void' });
  ok((await call('DELETE', `/api/documents/${dv.id}`, null)).success === true, '[doc] delete void (no attachment) → success');
  await expectThrow(() => call('GET', `/api/documents/${dv.id}`, null), '[doc] deleted void doc gone');
}

// ───────────────────────── cash-flow operating aggregation (PR-7E) ─────────────────────────
// DB-level test of computeOperatingCashflow — the layer NOT covered by check:cashflow's pure
// txnCashAmount unit test nor the e2e cashflow mock: inflow / outflow / net, [from,to] window,
// unpaid exclusion, partial → paid_amount only, transactions-over-legacy source selection, and
// the null investing/financing/beginningCash/endingCash + basis='cash' + statutory=false invariants.
// Seeds via direct INSERT (arrange) and calls computeOperatingCashflow(db,{from,to}) directly for
// precise window control. Reads electron/reports/_cashflow.js only — no production code/schema change.
{
  const seedTxn = (db, r) => db.prepare(
    `INSERT INTO transactions (id,type,date,amount,amount_net,payment_status,paid_amount,payment_date)
     VALUES (?,?,?,?,?,?,?,?)`
  ).run(r.id, r.type, r.date, r.amount, r.amount_net ?? r.amount, r.payment_status, r.paid_amount, r.payment_date ?? null);
  const seedRow = (db, table, r) => db.prepare(
    `INSERT INTO ${table} (id,date,payment_status,paid_amount,payment_date) VALUES (?,?,?,?,?)`
  ).run(r.id, r.date, r.payment_status, r.paid_amount, r.payment_date ?? null);
  const assertInvariants = (cf, tag) => {
    ok(cf.investing === null, `${tag} investing=null`);
    ok(cf.financing === null, `${tag} financing=null`);
    ok(cf.beginningCash === null, `${tag} beginningCash=null`);
    ok(cf.endingCash === null, `${tag} endingCash=null`);
    ok(cf.basis === 'cash', `${tag} basis=cash`);
    ok(cf.statutory === false, `${tag} statutory=false`);
  };

  // ── Scenario A: transactions source (period 2026-01) ──
  // inflow = i1 1000 + i2 300(partial→paid_amount) + i5 200(paid+paid_amount0→full amount) + i6 700(payment_date null→date) = 2200
  // outflow = e1 400 + e2 100(partial) + e3 0(partial no paid_amount) = 500 ; i3 unpaid & i4 02-05(out of window) excluded
  {
    const db = freshDb();
    seedTxn(db, { id: 'cfA-i1', type: 'income',  date: '2026-01-10', amount: 1000, payment_status: 'paid',    paid_amount: 1000, payment_date: '2026-01-10' });
    seedTxn(db, { id: 'cfA-i2', type: 'income',  date: '2026-01-20', amount: 1000, payment_status: 'partial', paid_amount: 300,  payment_date: '2026-01-20' });
    seedTxn(db, { id: 'cfA-i3', type: 'income',  date: '2026-01-15', amount: 500,  payment_status: 'unpaid',  paid_amount: 0,    payment_date: '2026-01-15' });
    seedTxn(db, { id: 'cfA-i4', type: 'income',  date: '2026-01-30', amount: 500,  payment_status: 'paid',    paid_amount: 500,  payment_date: '2026-02-05' });
    seedTxn(db, { id: 'cfA-e1', type: 'expense', date: '2026-01-12', amount: 400,  payment_status: 'paid',    paid_amount: 400,  payment_date: '2026-01-12' });
    seedTxn(db, { id: 'cfA-e2', type: 'expense', date: '2026-01-25', amount: 800,  payment_status: 'partial', paid_amount: 100,  payment_date: '2026-01-25' });
    seedTxn(db, { id: 'cfA-e3', type: 'expense', date: '2026-01-18', amount: 800,  payment_status: 'partial', paid_amount: 0,    payment_date: '2026-01-18' });
    seedTxn(db, { id: 'cfA-i5', type: 'income',  date: '2026-01-22', amount: 200,  payment_status: 'paid',    paid_amount: 0,    payment_date: '2026-01-22' });
    seedTxn(db, { id: 'cfA-i6', type: 'income',  date: '2026-01-28', amount: 700,  payment_status: 'paid',    paid_amount: 700,  payment_date: null });
    const cf = computeOperatingCashflow(db, { from: '2026-01-01', to: '2026-01-31' });
    ok(cf.source === 'transactions', '[cashflow A] source=transactions');
    ok(approx(cf.operating.inflow, 2200), `[cashflow A] inflow=2200 (got ${cf.operating.inflow})`);
    ok(approx(cf.operating.outflow, 500), `[cashflow A] outflow=500 (got ${cf.operating.outflow})`);
    ok(approx(cf.operating.net, 1700), `[cashflow A] net=1700 (got ${cf.operating.net})`);
    assertInvariants(cf, '[cashflow A]');
  }

  // ── Scenario B: legacy source (period 2026-03, no transactions) ──
  // inflow = s1 1000 + s2 400(partial) + s5 0(paid+paid_amount0; legacy does NOT fall back to full amount) = 1400
  // outflow = p1 500 + p2 200(partial) = 700 ; s3 unpaid, s4 04-02(out), s6 payment_date NULL(legacy requires NOT NULL) excluded
  {
    const db = freshDb();
    seedRow(db, 'sales', { id: 'cfB-s1', date: '2026-03-10', payment_status: 'paid',    paid_amount: 1000, payment_date: '2026-03-10' });
    seedRow(db, 'sales', { id: 'cfB-s2', date: '2026-03-20', payment_status: 'partial', paid_amount: 400,  payment_date: '2026-03-20' });
    seedRow(db, 'sales', { id: 'cfB-s3', date: '2026-03-15', payment_status: 'unpaid',  paid_amount: 0,    payment_date: '2026-03-15' });
    seedRow(db, 'sales', { id: 'cfB-s4', date: '2026-04-02', payment_status: 'paid',    paid_amount: 600,  payment_date: '2026-04-02' });
    seedRow(db, 'sales', { id: 'cfB-s5', date: '2026-03-22', payment_status: 'paid',    paid_amount: 0,    payment_date: '2026-03-22' });
    seedRow(db, 'sales', { id: 'cfB-s6', date: '2026-03-08', payment_status: 'paid',    paid_amount: 900,  payment_date: null });
    seedRow(db, 'purchases', { id: 'cfB-p1', date: '2026-03-12', payment_status: 'paid',    paid_amount: 500, payment_date: '2026-03-12' });
    seedRow(db, 'purchases', { id: 'cfB-p2', date: '2026-03-25', payment_status: 'partial', paid_amount: 200, payment_date: '2026-03-25' });
    const cf = computeOperatingCashflow(db, { from: '2026-03-01', to: '2026-03-31' });
    ok(cf.source === 'legacy', '[cashflow B] source=legacy');
    ok(approx(cf.operating.inflow, 1400), `[cashflow B] inflow=1400 (got ${cf.operating.inflow})`);
    ok(approx(cf.operating.outflow, 700), `[cashflow B] outflow=700 (got ${cf.operating.outflow})`);
    ok(approx(cf.operating.net, 700), `[cashflow B] net=700 (got ${cf.operating.net})`);
    assertInvariants(cf, '[cashflow B]');
  }

  // ── Scenario C: transactions take priority over legacy in the same period (2026-05) ──
  // one txn (income 1000) + legacy sale 9999 / purchase 8888 in the same period → legacy ignored.
  {
    const db = freshDb();
    seedTxn(db, { id: 'cfC-i1', type: 'income', date: '2026-05-10', amount: 1000, payment_status: 'paid', paid_amount: 1000, payment_date: '2026-05-10' });
    seedRow(db, 'sales',     { id: 'cfC-s1', date: '2026-05-12', payment_status: 'paid', paid_amount: 9999, payment_date: '2026-05-12' });
    seedRow(db, 'purchases', { id: 'cfC-p1', date: '2026-05-14', payment_status: 'paid', paid_amount: 8888, payment_date: '2026-05-14' });
    const cf = computeOperatingCashflow(db, { from: '2026-05-01', to: '2026-05-31' });
    ok(cf.source === 'transactions', '[cashflow C] source=transactions (txn present → legacy ignored)');
    ok(approx(cf.operating.inflow, 1000), `[cashflow C] inflow=1000, legacy sale 9999 ignored (got ${cf.operating.inflow})`);
    ok(approx(cf.operating.outflow, 0), `[cashflow C] outflow=0, legacy purchase 8888 ignored (got ${cf.operating.outflow})`);
    ok(approx(cf.operating.net, 1000), `[cashflow C] net=1000 (got ${cf.operating.net})`);
    assertInvariants(cf, '[cashflow C]');
  }
}

// ───────────── cash-flow acceptance via real reports.generate (PR-7E · B) ─────────────
// End-to-end through the REAL report pipeline: seed via dispatch (real create + recordPayment
// status computation), then POST /api/reports/generate (year → [from,to] window) and assert
// report.cashflowStatement. Complements #231 (which unit-tests computeOperatingCashflow with
// explicit windows): here the full-year 2026 window + report-level wiring + recordPayment are
// exercised. All seed ids carry the PR7E_ACCEPTANCE_ marker. :memory: freshDb per scenario =
// auto-isolated (no cleanup). Reads only — no production code/schema change.
{
  const seedSale = async (id, date, totalAmount, pay) => {
    await call('POST', '/api/sales', { id, date, tons: 0, customer: 'PR7E', totalAmount });
    if (pay) await call('PUT', `/api/sales/${id}/payment`, { paid_amount: pay.paid, payment_date: pay.date });
  };
  const seedPurchase = async (id, date, totalAmount, pay) => {
    await call('POST', '/api/purchases', { id, date, tons: 0, supplier: 'PR7E', totalAmount });
    if (pay) await call('PUT', `/api/purchases/${id}/payment`, { paid_amount: pay.paid, payment_date: pay.date });
  };
  const M = 'PR7E_ACCEPTANCE_';

  // ── B1: legacy source, full-year 2026 → 1300 / 500 / 800 ──
  // sA paid 1000 + sB partial 300 = 1300 ; sC unpaid & sD paid-but-2025 excluded.
  // pE paid 400 + pF partial 100 = 500. No 2026 transactions → source 'legacy'.
  {
    freshDb();
    await seedSale(`${M}sA`, '2026-03-10', 1000, { paid: 1000, date: '2026-03-10' });
    await seedSale(`${M}sB`, '2026-04-20', 1000, { paid: 300,  date: '2026-04-20' });
    await seedSale(`${M}sC`, '2026-05-01', 800,  null);                                   // unpaid → excluded
    await seedSale(`${M}sD`, '2025-12-20', 500,  { paid: 500,  date: '2025-12-20' });     // prior-year payment → excluded
    await seedPurchase(`${M}pE`, '2026-05-15', 400,  { paid: 400, date: '2026-05-15' });
    await seedPurchase(`${M}pF`, '2026-06-25', 1000, { paid: 100, date: '2026-06-25' });  // partial → 100
    const r = await call('POST', '/api/reports/generate', { locale: 'CN', year: '2026' });
    const cf = r.cashflowStatement;
    ok(cf && cf.source === 'legacy', '[cashflow-acc B1] source=legacy');
    ok(approx(cf?.operating.inflow, 1300), `[cashflow-acc B1] inflow=1300 (got ${cf?.operating.inflow})`);
    ok(approx(cf?.operating.outflow, 500), `[cashflow-acc B1] outflow=500 (got ${cf?.operating.outflow})`);
    ok(approx(cf?.operating.net, 800), `[cashflow-acc B1] net=800 (got ${cf?.operating.net})`);
    ok(cf?.investing === null && cf?.financing === null && cf?.beginningCash === null && cf?.endingCash === null,
      '[cashflow-acc B1] investing/financing/beginning/ending = null');
    ok(cf?.basis === 'cash' && cf?.statutory === false, '[cashflow-acc B1] basis=cash, statutory=false');
  }

  // ── B2: transactions take priority over legacy (same 2026 period) → 50 / 0 / 50 ──
  // Same legacy set (would give 1300/500 under legacy) PLUS one 2026 income transaction (50)
  // → periodTxnCount>0 → source 'transactions' → legacy IGNORED.
  {
    freshDb();
    await seedSale(`${M}sA`, '2026-03-10', 1000, { paid: 1000, date: '2026-03-10' });
    await seedSale(`${M}sB`, '2026-04-20', 1000, { paid: 300,  date: '2026-04-20' });
    await seedPurchase(`${M}pE`, '2026-05-15', 400,  { paid: 400, date: '2026-05-15' });
    await seedPurchase(`${M}pF`, '2026-06-25', 1000, { paid: 100, date: '2026-06-25' });
    await call('POST', '/api/transactions', { id: `${M}tx1`, type: 'income', date: '2026-07-01', amount: 50, amount_net: 50, payment_status: 'paid' });
    const r = await call('POST', '/api/reports/generate', { locale: 'CN', year: '2026' });
    const cf = r.cashflowStatement;
    ok(cf && cf.source === 'transactions', '[cashflow-acc B2] source=transactions (txn present → legacy ignored)');
    ok(approx(cf?.operating.inflow, 50), `[cashflow-acc B2] inflow=50, legacy 1300 ignored (got ${cf?.operating.inflow})`);
    ok(approx(cf?.operating.outflow, 0), `[cashflow-acc B2] outflow=0, legacy 500 ignored (got ${cf?.operating.outflow})`);
    ok(approx(cf?.operating.net, 50), `[cashflow-acc B2] net=50 (got ${cf?.operating.net})`);
  }
}

// ───────────── PR-6 §N security: providers list/remove (N5 renderer never gets plaintext, N6 delete clears) ─────────────
// Seed a row by DIRECT insert (a fake ciphertext) to bypass safeStorage (unavailable under node),
// then exercise aiCore.list()/remove() — the real renderer-facing surface. list() must report
// hasKey but expose NO key field; remove() must clear the row. aiCore.getDb() and the harness share
// the same db module instance (_setDbForTest), so they hit the same :memory: DB. Reads only.
{
  const db = freshDb();
  const FAKE_ENC = 'QkFTRTY0RFVNTVlDSVBIRVI='; // base64 dummy "ciphertext" — never a real key
  db.prepare(`INSERT INTO ai_providers (provider, api_key_encrypted, model, enabled, is_default)
              VALUES (?, ?, ?, 1, 1)`).run('deepseek', FAKE_ENC, 'deepseek-chat');

  // N5: list() exposes hasKey but no key/ciphertext anywhere in the returned shape
  const list = aiCore.list();
  const ds = list.find((p) => p.provider === 'deepseek');
  ok(!!ds && ds.hasKey === true, '[N5] list(): configured provider → hasKey=true');
  const dsJson = JSON.stringify(ds || {});
  ok(!/api_key|apiKey|api_key_encrypted/i.test(dsJson), '[N5] list() entry has no api_key/apiKey/encrypted field');
  ok(!dsJson.includes(FAKE_ENC), '[N5] list() entry does not leak the stored ciphertext');
  // whole-payload sweep: no provider entry carries a key field or the ciphertext
  const allJson = JSON.stringify(list);
  ok(!/api_key|apiKey/i.test(allJson) && !allJson.includes(FAKE_ENC), '[N5] full list() payload carries no key material');
  // unconfigured providers report hasKey=false (no row)
  const unconfigured = list.find((p) => p.provider === 'anthropic');
  ok(!!unconfigured && unconfigured.hasKey === false, '[N5] unconfigured provider → hasKey=false');

  // N6: remove() clears the row and the credential
  aiCore.remove({ provider: 'deepseek' });
  const after = aiCore.list().find((p) => p.provider === 'deepseek');
  ok(!!after && after.hasKey === false, '[N6] after remove(): hasKey=false');
  const cnt = db.prepare("SELECT COUNT(*) AS c FROM ai_providers WHERE provider = 'deepseek'").get().c;
  ok(cnt === 0, '[N6] after remove(): ai_providers row physically deleted');
}

if (failures.length) {
  console.error(`✗ handlers: ${failures.length} assertion(s) failed:`);
  for (const f of failures) console.error('  - ' + f);
  process.exit(1);
}
console.log('✓ handlers: round-trips passed (transactions/purchases/sales CRUD+payment+validation + dashboard e2e + router + categories/products/inventory + accounts(cash/bank master data + opening balance, PR-7D-1) + liabilities(loans/other liabilities ledger, PR-7D-2) + fixed_assets(fixed-assets register, PR-7D-3) + equity(equity/capital ledger, PR-7D-4) + tax_payments(tax-payments ledger, PR-7D-5) + ledger-summary(read-only snapshot, PR-7B-1) + cash-position(read-only roll-forward preview, PR-7B P1-2) + balance-overview(management-basis read-only aggregation, PR-7B P1-3) + depreciation-preview(straight-line read-only, PR-7B P2-2) + retained-earnings-preview(management-basis read-only, PR-7B P2-4a) + income-tax-position(income-tax accrual−paid read-only, PR-7B P3-1) + alerts + receivables/payables aging + settings + reports(structural) + batch + conversations + mileage + homeOffice + legacy data-migrations + business documents(fs-free) + cashflow operating aggregation + cashflow acceptance(reports.generate, PR-7E) + provider key security(N5 no-plaintext/N6 delete-clears)) via real dispatch on :memory: DB');
