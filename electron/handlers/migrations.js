// 旧数据迁移工具 — sales/purchases → transactions
// 详见 docs/INTERNATIONALIZATION_PLAN.md §3
//
// 关键设计：
//   1. 保留旧表（只读）— 不删除以便回滚
//   2. legacy_migrations 表记录 legacy_id → new_id 映射
//   3. 已迁移行不重复处理（按 legacy_migrations 判断）
//   4. 提供 detectLegacy / migrateAll / rollback 三个操作

const { getDb } = require('../db');

function readSetting(key, fallback) {
  try {
    const db = getDb();
    const row = db.prepare('SELECT value FROM settings WHERE key = ?').get(key);
    return row ? JSON.parse(row.value) : fallback;
  } catch { return fallback; }
}

// GET /api/migrations/detect-legacy
// 返回 sales/purchases 表是否存在 + 是否还有未迁移行
async function detectLegacy() {
  const db = getDb();
  // 检查表是否存在
  const tables = db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name IN ('sales','purchases')").all();
  const hasSales = tables.some(t => t.name === 'sales');
  const hasPurchases = tables.some(t => t.name === 'purchases');

  if (!hasSales && !hasPurchases) {
    return { hasLegacy: false, sales: { exists: false, total: 0, migrated: 0, pending: 0 }, purchases: { exists: false, total: 0, migrated: 0, pending: 0 } };
  }

  const counts = (table) => {
    if (!tables.some(t => t.name === table)) return { exists: false, total: 0, migrated: 0, pending: 0 };
    const total = db.prepare(`SELECT COUNT(*) as c FROM ${table}`).get().c;
    const migrated = db.prepare(`SELECT COUNT(*) as c FROM legacy_migrations WHERE legacy_table = ?`).get(table).c;
    return { exists: true, total, migrated, pending: Math.max(0, total - migrated) };
  };

  const salesCount = counts('sales');
  const purchasesCount = counts('purchases');

  return {
    hasLegacy: (salesCount.pending + purchasesCount.pending) > 0,
    sales: salesCount,
    purchases: purchasesCount,
  };
}

// POST /api/migrations/run
// 把 sales + purchases 全量迁移到 transactions（已迁移行跳过）
// 入参 body: { defaultIncomeCategoryId?, defaultExpenseCategoryId?, currency? }
async function migrateAll({ body }) {
  const db = getDb();
  const accountingLocale = readSetting('accounting_locale', 'CN');
  const currency = (body && body.currency) || readSetting('currency', 'CNY');

  // 找当前 locale 默认类别：sales 默认归到收入第一项；purchases 默认归到 COGS（如有 slug='cogs'）
  const defaultIncomeCat = (body && body.defaultIncomeCategoryId) ||
    db.prepare("SELECT id FROM categories WHERE locale = ? AND type = 'income' ORDER BY sort_order LIMIT 1").get(accountingLocale)?.id;
  const defaultExpenseCat = (body && body.defaultExpenseCategoryId) ||
    db.prepare("SELECT id FROM categories WHERE locale = ? AND type = 'expense' AND slug = 'cogs' LIMIT 1").get(accountingLocale)?.id ||
    db.prepare("SELECT id FROM categories WHERE locale = ? AND type = 'expense' ORDER BY sort_order LIMIT 1").get(accountingLocale)?.id;

  if (!defaultIncomeCat || !defaultExpenseCat) {
    throw new Error('未找到当前会计制度的默认类别，迁移已中止。请先在「会计类别」检查 categories 表');
  }

  // 检查表存在
  const tables = db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name IN ('sales','purchases')").all();
  const hasSales = tables.some(t => t.name === 'sales');
  const hasPurchases = tables.some(t => t.name === 'purchases');

  const result = {
    salesMigrated: 0,
    purchasesMigrated: 0,
    salesSkipped: 0,
    purchasesSkipped: 0,
    errors: [],
  };

  const insertTxn = db.prepare(`
    INSERT INTO transactions
      (id, type, date, amount, amount_net, tax_amount, tax_rate, currency,
       category_id, counterparty, invoice_no, invoice_status,
       payment_status, paid_amount, payment_date, due_date,
       description, source_meta)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `);
  const insertMap = db.prepare(`
    INSERT INTO legacy_migrations (legacy_table, legacy_id, new_id) VALUES (?, ?, ?)
  `);

  const mapInvoiceStatus = (s) => (s === '已开' || s === '已收') ? 'issued' : (s === '待开' || s === '待收') ? 'pending' : 'n/a';

  // === 迁移 sales（type=income）===
  if (hasSales) {
    const rows = db.prepare(`
      SELECT s.* FROM sales s
      LEFT JOIN legacy_migrations m ON m.legacy_table = 'sales' AND m.legacy_id = s.id
      WHERE m.id IS NULL
    `).all();

    const tx = db.transaction(() => {
      for (const r of rows) {
        try {
          const newId = `txn-mig-sales-${r.id}-${Date.now().toString(36)}`;
          // Legacy-data migration: keep description language-neutral.
          // Raw legacy fields are preserved in source_meta below.
          const desc = [
            r.tons ? `qty=${r.tons}` : null,
            r.pricePerTon ? `unit=${r.pricePerTon}` : null,
            r.shippingCost ? `shipping=${r.shippingCost}` : null,
          ].filter(Boolean).join(' · ');

          insertTxn.run(
            newId, 'income', r.date,
            r.totalAmount || 0, r.amountWithoutTax || null, r.taxAmount || 0, r.taxRate || 0,
            currency, defaultIncomeCat, r.customer || null,
            r.invoiceNumber || null, mapInvoiceStatus(r.invoiceStatus),
            r.payment_status || 'paid', r.paid_amount || 0, r.payment_date || null, r.due_date || null,
            desc || null,
            JSON.stringify({ migrated_from: 'sales', legacy_id: r.id, tons: r.tons, pricePerTon: r.pricePerTon, shippingCost: r.shippingCost }),
          );
          insertMap.run('sales', r.id, newId);
          result.salesMigrated++;
        } catch (e) {
          result.errors.push({ legacy_table: 'sales', legacy_id: r.id, error: e?.message || String(e) });
          result.salesSkipped++;
        }
      }
    });
    tx();
  }

  // === 迁移 purchases（type=expense）===
  if (hasPurchases) {
    const rows = db.prepare(`
      SELECT p.* FROM purchases p
      LEFT JOIN legacy_migrations m ON m.legacy_table = 'purchases' AND m.legacy_id = p.id
      WHERE m.id IS NULL
    `).all();

    const tx = db.transaction(() => {
      for (const r of rows) {
        try {
          const newId = `txn-mig-purch-${r.id}-${Date.now().toString(36)}`;
          const desc = [
            r.tons ? `qty=${r.tons}` : null,
            r.pricePerTon ? `unit=${r.pricePerTon}` : null,
          ].filter(Boolean).join(' · ');

          insertTxn.run(
            newId, 'expense', r.date,
            r.totalAmount || 0, r.amountWithoutTax || null, r.taxAmount || 0, r.taxRate || 0,
            currency, defaultExpenseCat, r.supplier || null,
            r.invoiceNumber || null, mapInvoiceStatus(r.invoiceStatus),
            r.payment_status || 'paid', r.paid_amount || 0, r.payment_date || null, r.due_date || null,
            desc || null,
            JSON.stringify({ migrated_from: 'purchases', legacy_id: r.id, tons: r.tons, pricePerTon: r.pricePerTon }),
          );
          insertMap.run('purchases', r.id, newId);
          result.purchasesMigrated++;
        } catch (e) {
          result.errors.push({ legacy_table: 'purchases', legacy_id: r.id, error: e?.message || String(e) });
          result.purchasesSkipped++;
        }
      }
    });
    tx();
  }

  console.log(`[migration] sales: ${result.salesMigrated} migrated / ${result.salesSkipped} errors`);
  console.log(`[migration] purchases: ${result.purchasesMigrated} migrated / ${result.purchasesSkipped} errors`);

  return result;
}

// POST /api/migrations/rollback
// 把之前迁移生成的 transactions 全部删除 + 清空 legacy_migrations
// 旧 sales/purchases 数据保持不变
async function rollback() {
  const db = getDb();
  let removed = 0;
  const tx = db.transaction(() => {
    const newIds = db.prepare('SELECT new_id FROM legacy_migrations').all().map(r => r.new_id);
    if (newIds.length === 0) return;
    const placeholders = newIds.map(() => '?').join(',');
    const info = db.prepare(`DELETE FROM transactions WHERE id IN (${placeholders})`).run(...newIds);
    removed = info.changes;
    db.prepare('DELETE FROM legacy_migrations').run();
  });
  tx();
  console.log(`[migration] rolled back ${removed} migrated transactions`);
  return { success: true, removed };
}

module.exports = { detectLegacy, migrateAll, rollback };
