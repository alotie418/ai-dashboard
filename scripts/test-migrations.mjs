#!/usr/bin/env node
// 迁移专项测试（§2B）—— 12 版迁移是「数据丢失炸弹」，此前零执行覆盖。
// 在真 better-sqlite3（应用所用引擎）+ :memory: 库上验证：
//   1. 全新库 → head：user_version === MIGRATIONS.length === SCHEMA_VERSION。
//   2. runMigrations 幂等：再跑一次不报错、版本不变。
//   3. 种子：v4 类别已插入、v13 is_cogs 已回填。
//   4. 逐版幂等：把每个 MIGRATIONS[i] 直接重放到 head 库上，不报错、行数/表集不变
//      （证明每版都靠 IF NOT EXISTS / INSERT OR IGNORE / PRAGMA 守卫安全可重入）。
//   5. 旧→head 保 row：只建 v1、塞入 purchases/sales 行，迁到 head 后行仍在、新表已建。
//
// better-sqlite3 原生绑定按 Electron ABI 编（本机 / 普通 node 加载会 ERR_DLOPEN）；
// 加载不了时优雅 SKIP（exit 0），不算失败——CI 里把它 rebuild 成 node ABI 后真跑。

import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const require = createRequire(import.meta.url);
const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');

let Database;
try {
  Database = require('better-sqlite3');
  // 原生绑定是惰性加载的——require 不触发，首次 new Database() 才 dlopen。
  // 故在此实例化一次探测 ABI；不符会抛 ERR_DLOPEN_FAILED，落到下面优雅 SKIP。
  new Database(':memory:').close();
} catch (e) {
  console.log('⚠ test-migrations SKIPPED: better-sqlite3 unloadable under this node (built for Electron ABI).');
  console.log('  Runs for real in CI, where better-sqlite3 is rebuilt for the node ABI.');
  console.log('  原因:', e?.message?.split('\n')[0] || e);
  process.exit(0);
}

const { runMigrations, MIGRATIONS, SCHEMA_VERSION } = require(join(ROOT, 'electron/db/index.js'));

const failures = [];
const ok = (cond, msg) => { if (!cond) failures.push(msg); };
const fresh = () => new Database(':memory:');
const ver = (d) => d.pragma('user_version', { simple: true });
const tableExists = (d, name) =>
  !!d.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?").get(name);
const colExists = (d, table, col) =>
  d.prepare(`PRAGMA table_info(${table})`).all().some((c) => c.name === col);
const count = (d, table) => d.prepare(`SELECT COUNT(*) AS n FROM ${table}`).get().n;

// ---- 1. 全新库 → head ----
{
  const d = fresh();
  runMigrations(d);
  ok(MIGRATIONS.length === SCHEMA_VERSION, `[1] SCHEMA_VERSION(${SCHEMA_VERSION}) must equal MIGRATIONS.length(${MIGRATIONS.length})`);
  ok(ver(d) === MIGRATIONS.length, `[1] fresh→head should reach v${MIGRATIONS.length}, got v${ver(d)}`);
  for (const t of ['purchases', 'sales', 'settings', 'categories', 'transactions', 'products', 'business_documents', 'assistant_conversations', 'accounts', 'liabilities', 'fixed_assets', 'equity', 'tax_payments', 'ecommerce_connections']) {
    ok(tableExists(d, t), `[1] table '${t}' must exist at head`);
  }
  d.close();
}

// ---- 2. runMigrations 幂等 ----
{
  const d = fresh();
  runMigrations(d);
  const before = ver(d);
  const catsBefore = count(d, 'categories');
  let threw = null;
  try { runMigrations(d); } catch (e) { threw = e?.message || String(e); }
  ok(!threw, `[2] re-running runMigrations must not throw, threw: ${threw}`);
  ok(ver(d) === before, `[2] version must stay v${before}, got v${ver(d)}`);
  ok(count(d, 'categories') === catsBefore, `[2] category count must stay ${catsBefore}, got ${count(d, 'categories')}`);
  d.close();
}

// ---- 3. 种子：v4 类别 + v13 is_cogs 回填 ----
{
  const d = fresh();
  runMigrations(d);
  ok(count(d, 'categories') > 0, '[3] v4 should seed categories');
  ok(colExists(d, 'categories', 'is_cogs'), '[3] v13 should add categories.is_cogs');
  const cogs = d.prepare('SELECT COUNT(*) AS n FROM categories WHERE is_cogs = 1').get().n;
  ok(cogs > 0, '[3] v13 should backfill at least one is_cogs=1 category (cogs / EU purchases)');
  d.close();
}

// ---- 4. 逐版幂等：每个迁移直接重放到 head 库上应是 no-op ----
{
  const d = fresh();
  runMigrations(d);
  const catsBefore = count(d, 'categories');
  const tablesBefore = d.prepare("SELECT COUNT(*) AS n FROM sqlite_master WHERE type='table'").get().n;
  for (let i = 0; i < MIGRATIONS.length; i++) {
    let threw = null;
    try { d.transaction(() => MIGRATIONS[i](d))(); } catch (e) { threw = e?.message || String(e); }
    ok(!threw, `[4] replaying MIGRATIONS[${i}] (v${i + 1}) on head must not throw, threw: ${threw}`);
  }
  ok(count(d, 'categories') === catsBefore, `[4] replay must not change category count (${catsBefore} → ${count(d, 'categories')})`);
  const tablesAfter = d.prepare("SELECT COUNT(*) AS n FROM sqlite_master WHERE type='table'").get().n;
  ok(tablesAfter === tablesBefore, `[4] replay must not change table count (${tablesBefore} → ${tablesAfter})`);
  d.close();
}

// ---- 5. 旧→head 保 row：v1 数据迁到 head 不丢 ----
{
  const d = fresh();
  // 只建 v1 base schema，停在 v1
  d.transaction(() => { MIGRATIONS[0](d); d.pragma('user_version = 1'); })();
  d.prepare('INSERT INTO purchases (id, date, supplier) VALUES (?, ?, ?)').run('p1', '2026-01-01', 'Acme');
  d.prepare('INSERT INTO purchases (id, date, supplier) VALUES (?, ?, ?)').run('p2', '2026-01-02', 'Beta');
  d.prepare('INSERT INTO sales (id, date, customer) VALUES (?, ?, ?)').run('s1', '2026-01-03', 'Cust');

  runMigrations(d); // v2 → head
  ok(ver(d) === MIGRATIONS.length, `[5] should migrate v1→head, got v${ver(d)}`);
  ok(count(d, 'purchases') === 2, `[5] purchases rows must survive migration, got ${count(d, 'purchases')}`);
  ok(count(d, 'sales') === 1, `[5] sales rows must survive migration, got ${count(d, 'sales')}`);
  ok(d.prepare('SELECT supplier FROM purchases WHERE id = ?').get('p1')?.supplier === 'Acme', '[5] row data must be intact after migration');
  ok(tableExists(d, 'transactions'), '[5] v5 transactions table must be added');
  ok(tableExists(d, 'products'), '[5] v9 products table must be added');
  ok(colExists(d, 'purchases', 'product_id'), '[5] v10 purchases.product_id must be added');
  ok(colExists(d, 'categories', 'is_cogs'), '[5] v13 categories.is_cogs must be added');
  ok(tableExists(d, 'accounts'), '[5] v14 accounts table must be added');
  ok(tableExists(d, 'liabilities'), '[5] v15 liabilities table must be added');
  ok(tableExists(d, 'fixed_assets'), '[5] v16 fixed_assets table must be added');
  ok(tableExists(d, 'equity'), '[5] v17 equity table must be added');
  ok(tableExists(d, 'tax_payments'), '[5] v18 tax_payments table must be added');
  d.close();
}

// ---- 6. v14 accounts schema：列齐 + type CHECK + 期初余额可负 ----
{
  const d = fresh();
  runMigrations(d);
  ok(tableExists(d, 'accounts'), '[6] v14 accounts table exists');
  for (const c of ['id', 'name', 'type', 'currency', 'opening_balance', 'opening_date', 'note', 'is_active', 'sort_order', 'created_at', 'updated_at']) {
    ok(colExists(d, 'accounts', c), `[6] accounts.${c} column must exist`);
  }
  // type CHECK：cash/bank 放行，其它在 DB 层拒绝（handler 之外的最后一道防线）
  let badType = null;
  try { d.prepare("INSERT INTO accounts (id, name, type) VALUES ('a-bad', 'X', 'crypto')").run(); }
  catch (e) { badType = e?.message || String(e); }
  ok(badType, '[6] accounts.type CHECK rejects values other than cash/bank');
  d.prepare("INSERT INTO accounts (id, name, type, opening_balance) VALUES ('a-ok', 'Cash', 'cash', -250.5)").run();
  const row = d.prepare("SELECT type, opening_balance, is_active FROM accounts WHERE id = 'a-ok'").get();
  ok(row.type === 'cash', '[6] cash type accepted');
  ok(row.opening_balance === -250.5, '[6] opening_balance accepts negative (overdraft / 信用账户)');
  ok(row.is_active === 1, '[6] is_active defaults to 1');
  d.close();
}

// ---- 7. v15 liabilities schema：列齐 + liability_type CHECK + 期初余额可负 + interest_rate 默认 NULL ----
{
  const d = fresh();
  runMigrations(d);
  ok(tableExists(d, 'liabilities'), '[7] v15 liabilities table exists');
  for (const c of ['id', 'name', 'lender', 'liability_type', 'currency', 'principal', 'opening_balance',
                   'opening_date', 'interest_rate', 'maturity_date', 'note', 'is_active', 'sort_order',
                   'created_at', 'updated_at']) {
    ok(colExists(d, 'liabilities', c), `[7] liabilities.${c} column must exist`);
  }
  // liability_type CHECK：loan/other 放行，其它在 DB 层拒绝
  let badType = null;
  try { d.prepare("INSERT INTO liabilities (id, name, liability_type) VALUES ('l-bad', 'X', 'bond')").run(); }
  catch (e) { badType = e?.message || String(e); }
  ok(badType, '[7] liabilities.liability_type CHECK rejects values other than loan/other');
  d.prepare("INSERT INTO liabilities (id, name, liability_type, opening_balance) VALUES ('l-ok', 'Loan', 'loan', -1000.25)").run();
  const row = d.prepare("SELECT liability_type, opening_balance, interest_rate, is_active FROM liabilities WHERE id = 'l-ok'").get();
  ok(row.liability_type === 'loan', '[7] loan type accepted');
  ok(row.opening_balance === -1000.25, '[7] opening_balance accepts negative (NaN→0 / 不 clamp)');
  ok(row.interest_rate === null, '[7] interest_rate defaults to NULL (no hardcoded rate)');
  ok(row.is_active === 1, '[7] is_active defaults to 1');
  d.close();
}

// ---- 8. v16 fixed_assets schema：列齐 + status CHECK + original_value 默认 0（NaN→0/不 clamp）----
{
  const d = fresh();
  runMigrations(d);
  ok(tableExists(d, 'fixed_assets'), '[8] v16 fixed_assets table exists');
  for (const c of ['id', 'name', 'category', 'acquisition_date', 'original_value', 'currency', 'supplier',
                   'serial_no', 'note', 'status', 'is_active', 'sort_order', 'created_at', 'updated_at']) {
    ok(colExists(d, 'fixed_assets', c), `[8] fixed_assets.${c} column must exist`);
  }
  // 注：PR-7D-3 曾断言「折旧字段缺席（deferred PR-7B）」；PR-7B P2-1 已正式新增折旧参数字段，
  // 故该负向断言移除，改由 block [11]（v19）正向断言折旧列存在。
  // status CHECK：in_use/idle/disposed 放行，其它在 DB 层拒绝
  let badStatus = null;
  try { d.prepare("INSERT INTO fixed_assets (id, name, status) VALUES ('a-bad', 'X', 'sold')").run(); }
  catch (e) { badStatus = e?.message || String(e); }
  ok(badStatus, '[8] fixed_assets.status CHECK rejects values other than in_use/idle/disposed');
  d.prepare("INSERT INTO fixed_assets (id, name, status, original_value) VALUES ('a-ok', 'Laptop', 'disposed', -10.5)").run();
  const row = d.prepare("SELECT status, original_value, is_active FROM fixed_assets WHERE id = 'a-ok'").get();
  ok(row.status === 'disposed', '[8] disposed status accepted (登记标签，不触发处置损益)');
  ok(row.original_value === -10.5, '[8] original_value not clamped (NaN→0 仅在 handler，DB 不强制 ≥0)');
  ok(row.is_active === 1, '[8] is_active defaults to 1');
  d.close();
}

// ---- 9. v17 equity schema：列齐 + equity_type CHECK + amount 可负 + 无结转/合计列 ----
{
  const d = fresh();
  runMigrations(d);
  ok(tableExists(d, 'equity'), '[9] v17 equity table exists');
  for (const c of ['id', 'name', 'owner', 'equity_type', 'amount', 'currency', 'event_date',
                   'note', 'is_active', 'sort_order', 'created_at', 'updated_at']) {
    ok(colExists(d, 'equity', c), `[9] equity.${c} column must exist`);
  }
  // 故意不应存在合计/结转/科目列（留 PR-7B）
  for (const c of ['total', 'retained_earnings', 'undistributed_profit', 'paid_in_capital', 'capital_reserve', 'surplus_reserve']) {
    ok(!colExists(d, 'equity', c), `[9] equity must NOT carry rollup/carry-forward column '${c}' (deferred to PR-7B)`);
  }
  // equity_type CHECK：四个中性值放行，其它在 DB 层拒绝
  let badType = null;
  try { d.prepare("INSERT INTO equity (id, name, equity_type) VALUES ('e-bad', 'X', 'dividend')").run(); }
  catch (e) { badType = e?.message || String(e); }
  ok(badType, '[9] equity.equity_type CHECK rejects values other than the 4 neutral labels');
  d.prepare("INSERT INTO equity (id, name, equity_type, amount) VALUES ('e-ok', 'Draw', 'owner_draw', -2000.5)").run();
  const row = d.prepare("SELECT equity_type, amount, is_active FROM equity WHERE id = 'e-ok'").get();
  ok(row.equity_type === 'owner_draw', '[9] owner_draw type accepted (中性标签，不触发计算)');
  ok(row.amount === -2000.5, '[9] amount accepts negative (NaN→0 仅在 handler，DB 不强制方向)');
  ok(row.is_active === 1, '[9] is_active defaults to 1');
  d.close();
}

// ---- 10. v18 tax_payments schema：列齐 + tax_type CHECK + amount 可负 + 无计算/抵扣列 ----
{
  const d = fresh();
  runMigrations(d);
  ok(tableExists(d, 'tax_payments'), '[10] v18 tax_payments table exists');
  for (const c of ['id', 'name', 'tax_type', 'amount', 'currency', 'payment_date', 'period_start',
                   'period_end', 'authority', 'reference_no', 'note', 'is_active', 'sort_order',
                   'created_at', 'updated_at']) {
    ok(colExists(d, 'tax_payments', c), `[10] tax_payments.${c} column must exist`);
  }
  // 故意不应存在计算/抵扣/对冲列（留 PR-7B / 后续税务政策 PR）
  for (const c of ['rate', 'tax_rate', 'deductible', 'deductible_amount', 'payable', 'offset', 'credited']) {
    ok(!colExists(d, 'tax_payments', c), `[10] tax_payments must NOT carry calc/deduction/offset column '${c}' (deferred to PR-7B / tax-policy PR)`);
  }
  // tax_type CHECK：六个中性值放行，其它在 DB 层拒绝
  let badType = null;
  try { d.prepare("INSERT INTO tax_payments (id, name, tax_type) VALUES ('t-bad', 'X', 'tariff')").run(); }
  catch (e) { badType = e?.message || String(e); }
  ok(badType, '[10] tax_payments.tax_type CHECK rejects values other than the 6 neutral labels');
  d.prepare("INSERT INTO tax_payments (id, name, tax_type, amount) VALUES ('t-ok', 'Refund', 'vat', -888.8)").run();
  const row = d.prepare("SELECT tax_type, amount, is_active FROM tax_payments WHERE id = 't-ok'").get();
  ok(row.tax_type === 'vat', '[10] vat type accepted (中性标签，不触发税务计算)');
  ok(row.amount === -888.8, '[10] amount accepts negative (退税/冲正；NaN→0 仅在 handler，DB 不强制方向)');
  ok(row.is_active === 1, '[10] is_active defaults to 1');
  d.close();
}

// ---- 11. v19 fixed_assets 折旧参数：列齐 + 默认值 + nullable + 不动现有列 ----
{
  const d = fresh();
  runMigrations(d);
  for (const c of ['depreciation_method', 'useful_life_months', 'salvage_rate', 'depreciation_start_policy', 'disposal_date']) {
    ok(colExists(d, 'fixed_assets', c), `[11] fixed_assets.${c} column must exist (v19)`);
  }
  // 插一行（仅必填 id/name）→ method/start_policy 得默认、其余 3 字段 NULL；现有列行为不变
  d.prepare("INSERT INTO fixed_assets (id, name) VALUES ('fa-v19', 'X')").run();
  const row = d.prepare("SELECT depreciation_method, useful_life_months, salvage_rate, depreciation_start_policy, disposal_date, original_value, status FROM fixed_assets WHERE id = 'fa-v19'").get();
  ok(row.depreciation_method === 'straight_line', '[11] depreciation_method default = straight_line');
  ok(row.depreciation_start_policy === 'next_month', '[11] depreciation_start_policy default = next_month');
  ok(row.useful_life_months === null && row.salvage_rate === null && row.disposal_date === null, '[11] useful_life_months/salvage_rate/disposal_date are nullable (NULL)');
  ok(row.original_value === 0 && row.status === 'in_use', '[11] existing columns (original_value/status) defaults unchanged');
  d.close();
}

// ---- 12. 旧→head：v16 期 fixed_assets 行升级到 head(含 v19) 保值 + 新列得默认/NULL（不回填）----
{
  const d = fresh();
  // 跑到 v16（建 fixed_assets），停在 v16
  for (let v = 0; v < 16; v++) d.transaction(() => { MIGRATIONS[v](d); d.pragma(`user_version = ${v + 1}`); })();
  ok(tableExists(d, 'fixed_assets'), '[12] fixed_assets created at v16');
  ok(!colExists(d, 'fixed_assets', 'depreciation_method'), '[12] no depreciation columns yet at v16');
  d.prepare("INSERT INTO fixed_assets (id, name, original_value, status) VALUES ('fa-old', 'OldAsset', 5000, 'in_use')").run();
  runMigrations(d); // v17 → head（含 v19 加折旧列）
  ok(ver(d) === MIGRATIONS.length, `[12] v16→head, got v${ver(d)}`);
  const row = d.prepare("SELECT original_value, status, depreciation_method, useful_life_months, depreciation_start_policy FROM fixed_assets WHERE id = 'fa-old'").get();
  ok(row.original_value === 5000 && row.status === 'in_use', '[12] old fixed_assets row VALUE preserved after v19');
  ok(row.depreciation_method === 'straight_line' && row.depreciation_start_policy === 'next_month', '[12] new columns get schema defaults on old row');
  ok(row.useful_life_months === null, '[12] new nullable column = NULL on old row (no data backfill)');
  d.close();
}

// ---- 13. v21 ecommerce_connections：列齐 + credentials_encrypted NOT NULL + enabled 默认 1 + 无订单拉取列 ----
{
  const d = fresh();
  runMigrations(d);
  ok(tableExists(d, 'ecommerce_connections'), '[13] v21 ecommerce_connections table exists');
  for (const c of ['id', 'platform', 'label', 'shop_identifier', 'credentials_encrypted', 'store_currency',
                   'enabled', 'last_test_at', 'last_test_ok', 'created_at', 'updated_at']) {
    ok(colExists(d, 'ecommerce_connections', c), `[13] ecommerce_connections.${c} column must exist`);
  }
  // credentials_encrypted NOT NULL：缺失应被 DB 拒绝（最后一道防线，凭证不可为空）
  let missingCred = null;
  try { d.prepare("INSERT INTO ecommerce_connections (id, platform) VALUES ('ec-bad', 'shopify')").run(); }
  catch (e) { missingCred = e?.message || String(e); }
  ok(missingCred, '[13] credentials_encrypted is NOT NULL (row without it rejected)');
  // 正常插入：enabled 默认 1；last_test_ok 首次测试前为 NULL
  d.prepare("INSERT INTO ecommerce_connections (id, platform, shop_identifier, credentials_encrypted) VALUES ('ec-ok', 'shopify', 'x.myshopify.com', 'QkFTRTY0')").run();
  const row = d.prepare("SELECT enabled, last_test_ok FROM ecommerce_connections WHERE id = 'ec-ok'").get();
  ok(row.enabled === 1, '[13] enabled defaults to 1');
  ok(row.last_test_ok === null, '[13] last_test_ok nullable (NULL before first test)');
  // 边界：连接表不承载订单/暂存字段（last_cursor 由 v21→改为 v22 的同步列，见 block 14；此处只守订单/暂存列）
  for (const c of ['external_order_id', 'order_json', 'sync_state', 'staged_at', 'normalized_json']) {
    ok(!colExists(d, 'ecommerce_connections', c), `[13] ecommerce_connections must NOT carry order/staging column '${c}'`);
  }
  d.close();
}

// ---- 14. v22 拉单→暂存：连接同步列 + staged_orders + sync_log；且 sales/sales_items 未被改动 ----
{
  const d = fresh();
  runMigrations(d);
  // 14a. ecommerce_connections 新增 3 个同步列（nullable，additive）
  for (const c of ['last_cursor', 'last_synced_at', 'last_order_updated_at']) {
    ok(colExists(d, 'ecommerce_connections', c), `[14] ecommerce_connections.${c} sync column must exist (v22)`);
  }
  // 14b. ecommerce_staged_orders 列齐
  ok(tableExists(d, 'ecommerce_staged_orders'), '[14] v22 ecommerce_staged_orders table exists');
  for (const c of ['id', 'connection_id', 'platform', 'external_order_id', 'order_number', 'order_status',
                   'order_created_at', 'order_updated_at', 'currency', 'total_gross', 'normalized_json',
                   'raw_excerpt_json', 'match_status', 'stage_status', 'committed_sale_id',
                   'first_seen_at', 'last_pulled_at', 'error', 'updated_at']) {
    ok(colExists(d, 'ecommerce_staged_orders', c), `[14] ecommerce_staged_orders.${c} column must exist`);
  }
  // 14c. 唯一约束 (connection_id, external_order_id) 幂等：同键第二次插入被拒
  d.prepare("INSERT INTO ecommerce_staged_orders (connection_id, platform, external_order_id) VALUES ('c1','shopify','o1')").run();
  let dupErr = null;
  try { d.prepare("INSERT INTO ecommerce_staged_orders (connection_id, platform, external_order_id) VALUES ('c1','shopify','o1')").run(); }
  catch (e) { dupErr = e?.message || String(e); }
  ok(dupErr, '[14] UNIQUE(connection_id, external_order_id) rejects a duplicate staged row (idempotency)');
  // 不同 connection 同 external_order_id 允许
  d.prepare("INSERT INTO ecommerce_staged_orders (connection_id, platform, external_order_id) VALUES ('c2','shopify','o1')").run();
  ok(count(d, 'ecommerce_staged_orders') === 2, '[14] same external id under a different connection is allowed');
  // 默认值
  const srow = d.prepare("SELECT stage_status, match_status, raw_excerpt_json FROM ecommerce_staged_orders WHERE connection_id='c1'").get();
  ok(srow.stage_status === 'staged' && srow.match_status === 'unresolved', '[14] staged defaults: stage_status=staged / match_status=unresolved');
  ok(srow.raw_excerpt_json === null, '[14] raw_excerpt_json defaults NULL (full raw not persisted)');
  // 14d. ecommerce_sync_log 列齐
  ok(tableExists(d, 'ecommerce_sync_log'), '[14] v22 ecommerce_sync_log table exists');
  for (const c of ['id', 'connection_id', 'platform', 'run_at', 'status', 'pulled', 'staged_new',
                   'staged_updated', 'errors', 'pages', 'since_used', 'cursor_before', 'cursor_after',
                   'duration_ms', 'error_json']) {
    ok(colExists(d, 'ecommerce_sync_log', c), `[14] ecommerce_sync_log.${c} column must exist`);
  }
  // 14e. 红线（改为 v22 时点断言）：截至 v22，sales/sales_items 尚无任何订单列——
  //      sales 侧溯源列由 v23（PR-EC5a）新增，见 block 15；sales_items 永不加。
  {
    const d22 = fresh();
    for (let v = 0; v < 22; v++) d22.transaction(() => { MIGRATIONS[v](d22); d22.pragma(`user_version = ${v + 1}`); })();
    for (const c of ['external_order_id', 'platform_source', 'ecommerce_connection_id']) {
      ok(!colExists(d22, 'sales', c), `[14] sales must NOT carry '${c}' at v22 (added by v23)`);
      ok(!colExists(d22, 'sales_items', c), `[14] sales_items must NOT carry '${c}' at v22`);
    }
    d22.close();
  }
  d.close();
}

// ---- 15. v23 sales 电商溯源列：3 列可空 + 连接级部分唯一索引 + 旧写路径/手工行不受影响 ----
{
  const d = fresh();
  runMigrations(d);
  // 15a. 3 列存在于 sales；sales_items 永不承载溯源列（溯源只在表头）
  for (const c of ['external_order_id', 'platform_source', 'ecommerce_connection_id']) {
    ok(colExists(d, 'sales', c), `[15] sales.${c} column must exist (v23)`);
    ok(!colExists(d, 'sales_items', c), `[15] sales_items must NOT carry '${c}' (provenance is header-level only)`);
  }
  // 15b. 旧写路径（不带新列）不受影响；两行全 NULL 共存 → 部分索引不误伤手工/CSV 记录
  d.prepare("INSERT INTO sales (id, date, customer) VALUES ('s-m1', '2026-01-01', 'A')").run();
  d.prepare("INSERT INTO sales (id, date, customer) VALUES ('s-m2', '2026-01-02', 'B')").run();
  ok(count(d, 'sales') === 2, '[15] two manual rows with NULL provenance coexist (partial index ignores NULL)');
  const r = d.prepare("SELECT external_order_id, platform_source, ecommerce_connection_id FROM sales WHERE id='s-m1'").get();
  ok(r.external_order_id === null && r.platform_source === null && r.ecommerce_connection_id === null,
    '[15] new columns default NULL (no backfill)');
  // 15c. 同 (connection, external_order_id) 第二行被部分唯一索引拒绝（幂等的 DB 层最后防线）
  d.prepare("INSERT INTO sales (id, date, external_order_id, platform_source, ecommerce_connection_id) VALUES ('s-e1', '2026-01-03', 'o1', 'shopify', 'conn1')").run();
  let dup = null;
  try { d.prepare("INSERT INTO sales (id, date, external_order_id, platform_source, ecommerce_connection_id) VALUES ('s-e2', '2026-01-04', 'o1', 'shopify', 'conn1')").run(); }
  catch (e) { dup = e?.message || String(e); }
  ok(dup && /unique/i.test(dup), '[15] partial unique index rejects duplicate (connection, external_order_id)');
  // 15d. 不同连接同订单号允许——同平台两家店订单号可撞（Woo 站内自增），索引取连接级正是为此
  d.prepare("INSERT INTO sales (id, date, external_order_id, platform_source, ecommerce_connection_id) VALUES ('s-e3', '2026-01-05', 'o1', 'woocommerce', 'conn2')").run();
  ok(count(d, 'sales') === 4, '[15] same external id under a DIFFERENT connection is allowed');
  d.close();
}

if (failures.length) {
  console.error(`✗ migrations: ${failures.length} assertion(s) failed:`);
  for (const f of failures) console.error('  - ' + f);
  process.exit(1);
}
console.log(`✓ migrations: all checks passed (fresh→head v${MIGRATIONS.length} + idempotent + seeds + per-version replay + old→head row preservation + v14 accounts schema + v15 liabilities schema + v16 fixed_assets schema + v17 equity schema + v18 tax_payments schema + v19 fixed_assets depreciation params + v21 ecommerce_connections schema + v22 staged_orders/sync_log + v23 sales provenance/partial-unique)`);
