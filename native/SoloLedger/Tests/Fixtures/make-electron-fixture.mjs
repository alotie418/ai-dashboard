#!/usr/bin/env node
// Build a *synthetic* Electron-shaped SoloLedger database fixture using the REAL
// production migration code (electron/db/index.js MIGRATIONS + seedCategories),
// so the Swift Core is validated against a DB produced by the actual Electron
// engine — not by its own port. This is anonymized test data only; it never
// reads or copies the user's real production database.
//
// The Electron-ABI native binding (better-sqlite3) does not load under plain
// node on this machine, so run this via the repo's Electron binary as node:
//   ELECTRON_RUN_AS_NODE=1 ./node_modules/.bin/electron \
//     native/SoloLedger/Tests/Fixtures/make-electron-fixture.mjs
//
// Usage: ... make-electron-fixture.mjs [outputPath]
//   default output: ../SoloLedgerCoreTests/Fixtures/electron-v23.db (the test resource)
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { existsSync, rmSync, mkdirSync } from 'node:fs';

const require = createRequire(import.meta.url);
const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '../../../..'); // repo root
const out = process.argv[2] || join(HERE, '../SoloLedgerCoreTests/Fixtures/electron-v23.db');
mkdirSync(dirname(out), { recursive: true });

let Database;
try {
  Database = require('better-sqlite3');
  new Database(':memory:').close(); // probe native ABI
} catch (e) {
  console.error('better-sqlite3 unloadable under this node:', e?.message?.split('\n')[0]);
  process.exit(2);
}

const { runMigrations, SCHEMA_VERSION } = require(join(ROOT, 'electron/db/index.js'));

// Fresh file
for (const f of [out, out + '-wal', out + '-shm']) if (existsSync(f)) rmSync(f);

const db = new Database(out);
db.pragma('journal_mode = WAL');   // Electron runtime posture
db.pragma('foreign_keys = ON');
db.pragma('synchronous = FULL');

runMigrations(db); // brings a fresh DB to head (user_version = SCHEMA_VERSION = 23) + seeds 78 categories

// --- anonymized sample transactions (cover enums / fields / source_meta JSON) ---
const insert = db.prepare(`
  INSERT INTO transactions
    (id, type, date, amount, amount_net, tax_amount, tax_rate, currency,
     category_id, counterparty, invoice_no, invoice_status,
     payment_status, paid_amount, payment_date, due_date,
     description, attachment_path, source_meta)
  VALUES (@id,@type,@date,@amount,@amount_net,@tax_amount,@tax_rate,@currency,
          @category_id,@counterparty,@invoice_no,@invoice_status,
          @payment_status,@paid_amount,@payment_date,@due_date,
          @description,@attachment_path,@source_meta)
`);

const rows = [
  { id: 'txn-fixture-1', type: 'income',  date: '2025-11-05', amount: 1000.00, amount_net: null,   tax_amount: 0,      tax_rate: 0,    currency: 'CNY', category_id: 'cn-income-sales',    counterparty: '客户A', invoice_no: 'INV-001', invoice_status: 'issued',  payment_status: 'paid',    paid_amount: 1000.00, payment_date: '2025-11-06', due_date: null,         description: '咨询费', attachment_path: null, source_meta: null },
  { id: 'txn-fixture-2', type: 'income',  date: '2025-12-10', amount: 2500.50, amount_net: 2358.96, tax_amount: 141.54, tax_rate: 0.06, currency: 'CNY', category_id: 'cn-income-sales',    counterparty: '客户B', invoice_no: null,      invoice_status: 'pending', payment_status: 'partial', paid_amount: 1000.00, payment_date: null,         due_date: '2026-01-10', description: '预付款',  attachment_path: null, source_meta: null },
  { id: 'txn-fixture-3', type: 'income',  date: '2026-01-15', amount: 800.25,  amount_net: null,   tax_amount: 0,      tax_rate: 0,    currency: 'CNY', category_id: 'cn-income-interest', counterparty: '银行',   invoice_no: null,      invoice_status: 'n/a',     payment_status: 'paid',    paid_amount: 800.25,  payment_date: '2026-01-15', due_date: null,         description: '利息',   attachment_path: null, source_meta: null },
  { id: 'txn-fixture-4', type: 'income',  date: '2026-02-20', amount: 300.00,  amount_net: null,   tax_amount: 0,      tax_rate: 0,    currency: 'USD', category_id: 'cn-income-other',    counterparty: 'Acme',  invoice_no: null,      invoice_status: 'n/a',     payment_status: 'unpaid',  paid_amount: 0,       payment_date: null,         due_date: '2026-03-20', description: 'misc',   attachment_path: null, source_meta: JSON.stringify({ migrated_from: 'sales', legacy_id: 's7', tons: 3 }) },
  { id: 'txn-fixture-5', type: 'expense', date: '2025-11-20', amount: 450.00,  amount_net: null,   tax_amount: 0,      tax_rate: 0,    currency: 'CNY', category_id: 'cn-expense-cogs',    counterparty: '供应商X', invoice_no: null,    invoice_status: 'issued',  payment_status: 'paid',    paid_amount: 450.00,  payment_date: '2025-11-20', due_date: null,         description: '进货',   attachment_path: null, source_meta: null },
  { id: 'txn-fixture-6', type: 'expense', date: '2026-01-05', amount: 1200.75, amount_net: 1132.78, tax_amount: 67.97,  tax_rate: 0.06, currency: 'CNY', category_id: 'cn-expense-admin',   counterparty: '房东',   invoice_no: 'R-88',    invoice_status: 'issued',  payment_status: 'paid',    paid_amount: 1200.75, payment_date: '2026-01-05', due_date: null,         description: '房租',   attachment_path: null, source_meta: null },
  { id: 'txn-fixture-7', type: 'expense', date: '2026-02-10', amount: 99.99,   amount_net: null,   tax_amount: 0,      tax_rate: 0,    currency: 'CNY', category_id: 'cn-expense-selling', counterparty: '广告商', invoice_no: null,      invoice_status: 'pending', payment_status: 'unpaid',  paid_amount: 0,       payment_date: null,         due_date: '2026-03-10', description: '推广',   attachment_path: null, source_meta: JSON.stringify({ migrated_from: 'purchases', legacy_id: 'p1' }) },
];
const tx = db.transaction(() => { for (const r of rows) insert.run(r); });
tx();

// settings (JSON-encoded, matching JSON.stringify) — accounting_locale/currency/company/ui_language
const putSetting = db.prepare(`INSERT INTO settings (key, value, updated_at)
  VALUES (?, ?, datetime('now'))
  ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=datetime('now')`);
putSetting.run('accounting_locale', JSON.stringify('CN'));
putSetting.run('currency', JSON.stringify('CNY'));
putSetting.run('company_name', JSON.stringify('示例商贸有限公司'));
putSetting.run('ui_language', JSON.stringify('zh-CN'));

// Collapse WAL into the main file so the fixture is a clean single .db to commit.
db.pragma('wal_checkpoint(TRUNCATE)');
db.pragma('journal_mode = DELETE');
db.close();
for (const f of [out + '-wal', out + '-shm']) if (existsSync(f)) rmSync(f);

// Report
const verify = new Database(out, { readonly: true });
const uv = verify.pragma('user_version', { simple: true });
const txnCount = verify.prepare('SELECT COUNT(*) c FROM transactions').get().c;
const catCount = verify.prepare('SELECT COUNT(*) c FROM categories').get().c;
const inc = verify.prepare("SELECT COALESCE(SUM(amount),0) s FROM transactions WHERE type='income'").get().s;
const exp = verify.prepare("SELECT COALESCE(SUM(amount),0) s FROM transactions WHERE type='expense'").get().s;
verify.close();
console.log(`fixture written: ${out}`);
console.log(`  user_version=${uv} (SCHEMA_VERSION=${SCHEMA_VERSION}) transactions=${txnCount} categories=${catCount}`);
console.log(`  income_sum=${inc} expense_sum=${exp} net=${(inc - exp).toFixed(2)}`);
