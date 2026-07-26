#!/usr/bin/env node
// Build the *synthetic* report-parity fixture using the REAL production migration
// code (electron/db/index.js MIGRATIONS + seedCategories), so the Swift report
// mirror is validated against a database produced by the actual Electron engine.
// Anonymized test data only; it never reads or copies the user's real database.
//
// This is SEPARATE from make-electron-fixture.mjs on purpose: electron-v23.db is
// pinned by the migration/read tests, whose job is migration fidelity. Growing it
// to cover report cases would churn assertions that have nothing to do with
// reports. This fixture exists solely to feed report parity.
//
// The Electron-ABI native binding (better-sqlite3) does not load under plain node
// on this machine, so run this via the repo's Electron binary as node:
//   ELECTRON_RUN_AS_NODE=1 ./node_modules/.bin/electron \
//     native/SoloLedger/Tests/Fixtures/make-report-fixture.mjs
//
// Usage: ... make-report-fixture.mjs [outputPath]
//   default output: ../SoloLedgerCoreTests/Fixtures/reports/reports-base.db
//
// ---------------------------------------------------------------------------
// WHAT THIS FIXTURE COVERS (the R0 checklist)
//
//   2024  legacy-only period      — sales/purchases rows, ZERO transactions, so
//                                   electron/reports/_reportSource.js picks the
//                                   legacy branch for this year
//   2025  transactions period     — the ADJACENT year, so a golden pair proves the
//                                   source is chosen per period and does not bleed
//         edge rows within 2025:   amount_net = 0 (JS `||` falls back to gross),
//                                   an uncategorized expense, a zero-amount row,
//                                   an empty payment_status, a partial payment,
//                                   a non-ISO date string, a USD row
//   2026  US Schedule C period    — one transaction per mapped Schedule C line,
//                                   including the meals x0.5 path, home office,
//                                   an expense whose category belongs to ANOTHER
//                                   locale (US has no `cogs` category at all, so
//                                   this also covers "a purchase with no COGS
//                                   category"), and an uncategorized expense
//
// The rate settings are PRESENT here on purpose: this fixture represents a fully
// configured ledger, so its goldens stay invariant when the cross-regime fallback
// changes. The "missing rows" and "explicit 0%" cases are derived from this same
// file by make-report-goldens.mjs — see RATE_VARIANTS there.
// ---------------------------------------------------------------------------
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { existsSync, rmSync, mkdirSync } from 'node:fs';

const require = createRequire(import.meta.url);
const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '../../../..'); // repo root
const out = process.argv[2] || join(HERE, '../SoloLedgerCoreTests/Fixtures/reports/reports-base.db');
mkdirSync(dirname(out), { recursive: true });

let Database;
try {
  Database = require('better-sqlite3');
  new Database(':memory:').close(); // probe native ABI
} catch (e) {
  console.error('better-sqlite3 unloadable under this node:', e?.message?.split('\n')[0]);
  console.error('run with: ELECTRON_RUN_AS_NODE=1 ./node_modules/.bin/electron <this file>');
  process.exit(2);
}

const { runMigrations, SCHEMA_VERSION } = require(join(ROOT, 'electron/db/index.js'));

for (const f of [out, out + '-wal', out + '-shm']) if (existsSync(f)) rmSync(f);

const db = new Database(out);
db.pragma('journal_mode = WAL');
db.pragma('foreign_keys = ON');
db.pragma('synchronous = FULL');

runMigrations(db); // fresh DB to head (user_version = 23) + 78 seeded categories

// --- transactions ----------------------------------------------------------
const insertTxn = db.prepare(`
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

const t = (o) => ({
  amount_net: null, tax_amount: 0, tax_rate: 0, currency: 'CNY',
  category_id: null, counterparty: '', invoice_no: '', invoice_status: 'n/a',
  payment_status: 'paid', paid_amount: 0, payment_date: null, due_date: null,
  description: '', attachment_path: null, source_meta: null, ...o,
});

const txns = [
  // --- 2025: the transactions-source year -------------------------------------
  t({ id: 'rpt-2025-inc-1', type: 'income', date: '2025-02-10', amount: 10000.00,
      amount_net: 9433.96, tax_amount: 566.04, tax_rate: 6, category_id: 'cn-income-sales',
      paid_amount: 10000.00, payment_date: '2025-02-12', description: '含税收入(有净额)' }),

  // amount_net = 0 — JS `r.amount_net || r.amount` treats 0 as falsy and falls back
  // to the GROSS amount. A Swift port using `??` would keep 0 and diverge.
  t({ id: 'rpt-2025-inc-2', type: 'income', date: '2025-03-05', amount: 2000.00,
      amount_net: 0, tax_amount: 0, category_id: 'cn-income-other',
      paid_amount: 2000.00, payment_date: '2025-03-05', description: '净额为 0 的收入' }),

  // Non-ISO date string: sorts INSIDE a 'YYYY-01-01'..'YYYY-12-31' string range.
  t({ id: 'rpt-2025-inc-3', type: 'income', date: '2025-06-15T00:00:00', amount: 500.00,
      category_id: 'cn-income-interest', paid_amount: 500.00, payment_date: '2025-06-15',
      description: '非标准日期格式' }),

  // Multi-currency: summed WITHOUT conversion by every engine. Pinned, not fixed.
  t({ id: 'rpt-2025-inc-4', type: 'income', date: '2025-06-20', amount: 300.00,
      currency: 'USD', category_id: 'cn-income-sales', payment_status: 'unpaid',
      paid_amount: 0, due_date: '2025-07-20', description: '外币收入' }),

  t({ id: 'rpt-2025-exp-1', type: 'expense', date: '2025-02-15', amount: 4000.00,
      amount_net: 3773.58, tax_amount: 226.42, tax_rate: 6, category_id: 'cn-expense-cogs',
      paid_amount: 4000.00, payment_date: '2025-02-15', description: '营业成本(计入 COGS)' }),

  // Uncategorized -> operating expense in the VAT-model engines, line 27a in US.
  t({ id: 'rpt-2025-exp-2', type: 'expense', date: '2025-04-02', amount: 750.00,
      category_id: null, paid_amount: 750.00, payment_date: '2025-04-02',
      description: '未分类支出' }),

  // Zero amount.
  t({ id: 'rpt-2025-exp-3', type: 'expense', date: '2025-05-01', amount: 0,
      category_id: 'cn-expense-admin', paid_amount: 0, payment_date: '2025-05-01',
      description: '零金额' }),

  // Empty payment_status (the column default is 'unpaid'; '' is neither).
  t({ id: 'rpt-2025-exp-4', type: 'expense', date: '2025-06-10', amount: 1250.00,
      category_id: 'cn-expense-selling', payment_status: '', paid_amount: 0,
      description: '收付状态为空' }),

  // Partial payment — cash flow counts paid_amount, accrual counts amount.
  t({ id: 'rpt-2025-exp-5', type: 'expense', date: '2025-06-25', amount: 2400.00,
      amount_net: 2264.15, tax_amount: 135.85, tax_rate: 6, category_id: 'cn-expense-admin',
      payment_status: 'partial', paid_amount: 900.00, payment_date: '2025-06-28',
      description: '部分付款' }),

  // --- 2026: the US Schedule C year -------------------------------------------
  t({ id: 'rpt-2026-inc-1', type: 'income', date: '2026-01-10', amount: 50000.00,
      amount_net: 50000.00, currency: 'USD', category_id: 'us-income-gross-receipts',
      paid_amount: 50000.00, payment_date: '2026-01-10', description: 'gross receipts' }),
  t({ id: 'rpt-2026-inc-2', type: 'income', date: '2026-01-20', amount: 1500.00,
      currency: 'USD', category_id: 'us-income-returns', paid_amount: 1500.00,
      payment_date: '2026-01-20', description: 'returns and allowances' }),
  t({ id: 'rpt-2026-inc-3', type: 'income', date: '2026-02-01', amount: 900.00,
      currency: 'USD', category_id: 'us-income-other', paid_amount: 900.00,
      payment_date: '2026-02-01', description: 'other income' }),

  t({ id: 'rpt-2026-exp-1', type: 'expense', date: '2026-02-05', amount: 3200.00,
      currency: 'USD', category_id: 'us-expense-advertising', paid_amount: 3200.00,
      payment_date: '2026-02-05', description: 'advertising' }),
  // Meals: the only Schedule C line with a statutory multiplier (x0.5).
  t({ id: 'rpt-2026-exp-2', type: 'expense', date: '2026-03-11', amount: 1000.00,
      currency: 'USD', category_id: 'us-expense-meals', paid_amount: 1000.00,
      payment_date: '2026-03-11', description: 'meals (50% limitation)' }),
  t({ id: 'rpt-2026-exp-3', type: 'expense', date: '2026-03-20', amount: 2500.00,
      currency: 'USD', category_id: 'us-expense-home-office', paid_amount: 2500.00,
      payment_date: '2026-03-20', description: 'home office' }),
  t({ id: 'rpt-2026-exp-4', type: 'expense', date: '2026-04-02', amount: 640.00,
      currency: 'USD', category_id: 'us-expense-other', paid_amount: 640.00,
      payment_date: '2026-04-02', description: 'other expenses (line 27a)' }),
  // A category from ANOTHER locale: index.js loads categories WHERE locale = ?, so
  // under US this resolves to nothing and lands in line 27a — which also covers
  // "an expense with no COGS category", since US seeds none at all.
  t({ id: 'rpt-2026-exp-5', type: 'expense', date: '2026-04-15', amount: 1800.00,
      currency: 'USD', category_id: 'cn-expense-cogs', paid_amount: 1800.00,
      payment_date: '2026-04-15', description: '跨制度类别的支出' }),
  t({ id: 'rpt-2026-exp-6', type: 'expense', date: '2026-05-01', amount: 410.00,
      currency: 'USD', category_id: null, payment_status: 'unpaid', paid_amount: 0,
      due_date: '2026-06-01', description: 'uncategorized US expense' }),
];
db.transaction(() => { for (const r of txns) insertTxn.run(r); })();

// --- 2024: legacy-only period ----------------------------------------------
// No transactions are dated 2024, so selectReportSource picks 'legacy' for that
// year while 2025 stays on 'transactions' — adjacent periods, different sources.
// shippingCost only exists here: the transactions table has no such column, which
// is why cn.js's shipping deduction is structurally 0 on the transactions path.
// Column lists follow electron/db/index.js verbatim: `sales` carries shippingCost,
// `purchases` does not, and neither table has a notes column.
const insertSale = db.prepare(`
  INSERT INTO sales (id, date, customer, tons, pricePerTon, amountWithoutTax, taxRate,
                     taxAmount, shippingCost, totalAmount, invoiceNumber, invoiceStatus,
                     payment_status, paid_amount, due_date, payment_date)
  VALUES (@id,@date,@customer,@tons,@pricePerTon,@amountWithoutTax,@taxRate,
          @taxAmount,@shippingCost,@totalAmount,@invoiceNumber,@invoiceStatus,
          @payment_status,@paid_amount,@due_date,@payment_date)
`);
const insertPurchase = db.prepare(`
  INSERT INTO purchases (id, date, supplier, tons, pricePerTon, amountWithoutTax, taxRate,
                         taxAmount, totalAmount, invoiceNumber, invoiceStatus,
                         payment_status, paid_amount, due_date, payment_date)
  VALUES (@id,@date,@supplier,@tons,@pricePerTon,@amountWithoutTax,@taxRate,
          @taxAmount,@totalAmount,@invoiceNumber,@invoiceStatus,
          @payment_status,@paid_amount,@due_date,@payment_date)
`);
db.transaction(() => {
  insertSale.run({ id: 'lg-sale-1', date: '2024-03-10', customer: '旧客户甲', tons: 10,
    pricePerTon: 800, amountWithoutTax: 8000, taxRate: 13, taxAmount: 1040,
    shippingCost: 300, totalAmount: 9040, invoiceNumber: 'OLD-001', invoiceStatus: '已开',
    payment_status: 'paid', paid_amount: 9040, due_date: null, payment_date: '2024-03-15' });
  insertSale.run({ id: 'lg-sale-2', date: '2024-06-20', customer: '旧客户乙', tons: 4,
    pricePerTon: 950, amountWithoutTax: 3800, taxRate: 13, taxAmount: 494,
    shippingCost: 0, totalAmount: 4294, invoiceNumber: null, invoiceStatus: '待开',
    payment_status: 'unpaid', paid_amount: 0, due_date: '2024-07-20', payment_date: null });
  insertPurchase.run({ id: 'lg-purch-1', date: '2024-03-01', supplier: '旧供应商甲', tons: 12,
    pricePerTon: 500, amountWithoutTax: 6000, taxRate: 13, taxAmount: 780,
    totalAmount: 6780, invoiceNumber: 'OLD-P1', invoiceStatus: '已收',
    payment_status: 'paid', paid_amount: 6780, due_date: null, payment_date: '2024-03-02' });
  insertPurchase.run({ id: 'lg-purch-2', date: '2024-07-05', supplier: '旧供应商乙', tons: 3,
    pricePerTon: 600, amountWithoutTax: 1800, taxRate: 13, taxAmount: 234,
    totalAmount: 2034, invoiceNumber: null, invoiceStatus: '待收',
    payment_status: 'partial', paid_amount: 1000, due_date: '2024-08-05',
    payment_date: '2024-07-20' });
})();

// --- settings: a FULLY CONFIGURED ledger ------------------------------------
// Every rate row is present, so these goldens do not move when the cross-regime
// fallback changes.
//
// Every value here is deliberately DIFFERENT from the engine's own fallback
// (surcharge 12, income tax 25, admin expense 0 at electron/reports/index.js:75-77):
// if a port ever reads a fallback where it should have read the stored row, the
// number changes and the parity test fails instead of coincidentally matching.
const putSetting = db.prepare(`INSERT INTO settings (key, value, updated_at)
  VALUES (?, ?, datetime('now'))
  ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=datetime('now')`);
putSetting.run('accounting_locale', JSON.stringify('CN'));
putSetting.run('currency', JSON.stringify('CNY'));
putSetting.run('company_name', JSON.stringify('示例报表账本'));
putSetting.run('ui_language', JSON.stringify('zh-CN'));
putSetting.run('vat_rate', JSON.stringify(9));            // fallback is 13
putSetting.run('surcharge_rate', JSON.stringify(10));     // fallback is 12
putSetting.run('income_tax_rate', JSON.stringify(20));    // fallback is 25
putSetting.run('admin_expense_annual', JSON.stringify(12000));  // fallback is 0

db.pragma('wal_checkpoint(TRUNCATE)');
db.pragma('journal_mode = DELETE');
db.close();
for (const f of [out + '-wal', out + '-shm']) if (existsSync(f)) rmSync(f);

const v = new Database(out, { readonly: true });
const c = (sql) => v.prepare(sql).get().c;
console.log(`report fixture written: ${out}`);
console.log(`  user_version=${v.pragma('user_version', { simple: true })} (SCHEMA_VERSION=${SCHEMA_VERSION})`);
console.log(`  transactions=${c('SELECT COUNT(*) c FROM transactions')} ` +
            `sales=${c('SELECT COUNT(*) c FROM sales')} purchases=${c('SELECT COUNT(*) c FROM purchases')} ` +
            `categories=${c('SELECT COUNT(*) c FROM categories')}`);
console.log(`  txns by year: 2024=${c("SELECT COUNT(*) c FROM transactions WHERE date LIKE '2024%'")} ` +
            `2025=${c("SELECT COUNT(*) c FROM transactions WHERE date LIKE '2025%'")} ` +
            `2026=${c("SELECT COUNT(*) c FROM transactions WHERE date LIKE '2026%'")}`);
v.close();
