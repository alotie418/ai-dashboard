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

if (failures.length) {
  console.error(`✗ handlers: ${failures.length} assertion(s) failed:`);
  for (const f of failures) console.error('  - ' + f);
  process.exit(1);
}
console.log('✓ handlers: round-trips passed (transactions/purchases/sales CRUD+payment+validation + dashboard e2e + router + categories/products/inventory + alerts + receivables/payables aging + settings + reports(structural) + batch + conversations + mileage + homeOffice + legacy data-migrations + business documents(fs-free)) via real dispatch on :memory: DB');
