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
  for (const t of ['purchases', 'sales', 'settings', 'categories', 'transactions', 'products', 'business_documents', 'assistant_conversations', 'accounts', 'liabilities', 'fixed_assets']) {
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
  // 故意不应存在折旧政策字段（留 PR-7B）
  for (const c of ['depreciation_method', 'useful_life', 'salvage_value']) {
    ok(!colExists(d, 'fixed_assets', c), `[8] fixed_assets must NOT carry depreciation-policy column '${c}' (deferred to PR-7B)`);
  }
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

if (failures.length) {
  console.error(`✗ migrations: ${failures.length} assertion(s) failed:`);
  for (const f of failures) console.error('  - ' + f);
  process.exit(1);
}
console.log(`✓ migrations: all checks passed (fresh→head v${MIGRATIONS.length} + idempotent + seeds + per-version replay + old→head row preservation + v14 accounts schema + v15 liabilities schema + v16 fixed_assets schema)`);
