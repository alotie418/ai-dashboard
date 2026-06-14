// SQLite 数据库初始化 — Phase 1.2 主体在这里
// 表结构与原 Cloudflare D1 完全一致，用 user_version PRAGMA 管理迁移版本

const path = require('node:path');
const fs = require('node:fs');
const { app } = require('electron');

let db = null;

function getDbPath() {
  const userData = app.getPath('userData');
  if (!fs.existsSync(userData)) fs.mkdirSync(userData, { recursive: true });
  return path.join(userData, 'sololedger.db');
}

function initDatabase() {
  if (db) return db;

  let Database;
  try {
    Database = require('better-sqlite3');
  } catch (e) {
    console.warn('[db] better-sqlite3 not installed yet — run `npm install`');
    return null;
  }

  const dbPath = getDbPath();
  db = new Database(dbPath);
  db.pragma('journal_mode = WAL');
  db.pragma('foreign_keys = ON');

  runMigrations(db);
  console.log('[db] ready at', dbPath);
  return db;
}

function getDb() {
  if (!db) initDatabase();
  return db;
}

// ====== Migrations (照搬 worker D1 schema) ======
const MIGRATIONS = [
  // v1: 初始 schema
  (d) => {
    d.exec(`
      CREATE TABLE IF NOT EXISTS purchases (
        id TEXT PRIMARY KEY,
        date TEXT NOT NULL,
        supplier TEXT,
        tons REAL,
        pricePerTon REAL,
        totalAmount REAL,
        amountWithoutTax REAL,
        taxAmount REAL,
        taxRate REAL,
        invoiceNumber TEXT,
        invoiceStatus TEXT,
        payment_status TEXT DEFAULT 'unpaid',
        paid_amount REAL DEFAULT 0,
        due_date TEXT,
        payment_date TEXT,
        created_at TEXT DEFAULT (datetime('now'))
      );
      CREATE TABLE IF NOT EXISTS sales (
        id TEXT PRIMARY KEY,
        date TEXT NOT NULL,
        customer TEXT,
        tons REAL,
        pricePerTon REAL,
        totalAmount REAL,
        amountWithoutTax REAL,
        taxAmount REAL,
        taxRate REAL,
        shippingCost REAL DEFAULT 0,
        invoiceNumber TEXT,
        invoiceStatus TEXT,
        payment_status TEXT DEFAULT 'unpaid',
        paid_amount REAL DEFAULT 0,
        due_date TEXT,
        payment_date TEXT,
        created_at TEXT DEFAULT (datetime('now'))
      );
      CREATE TABLE IF NOT EXISTS settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL,
        updated_at TEXT DEFAULT (datetime('now'))
      );
      CREATE TABLE IF NOT EXISTS price_history (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        query TEXT NOT NULL,
        search_date TEXT NOT NULL,
        prices TEXT NOT NULL,
        created_at TEXT DEFAULT (datetime('now'))
      );
      CREATE TABLE IF NOT EXISTS alerts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        type TEXT NOT NULL,
        severity TEXT,
        title TEXT,
        body TEXT,
        related_id TEXT,
        is_read INTEGER DEFAULT 0,
        is_dismissed INTEGER DEFAULT 0,
        created_at TEXT DEFAULT (datetime('now'))
      );
      CREATE INDEX IF NOT EXISTS idx_sales_date ON sales(date);
      CREATE INDEX IF NOT EXISTS idx_purchases_date ON purchases(date);
      CREATE INDEX IF NOT EXISTS idx_alerts_read ON alerts(is_read);
      CREATE INDEX IF NOT EXISTS idx_sales_payment ON sales(payment_status);
      CREATE INDEX IF NOT EXISTS idx_purchases_payment ON purchases(payment_status);
    `);
  },
  // v2: AI providers (多服务商 BYOK) + 旧 gemini_key 平滑迁移
  (d) => {
    d.exec(`
      CREATE TABLE IF NOT EXISTS ai_providers (
        provider TEXT PRIMARY KEY,
        api_key_encrypted TEXT NOT NULL,
        model TEXT,
        enabled INTEGER DEFAULT 1,
        is_default INTEGER DEFAULT 0,
        created_at TEXT DEFAULT (datetime('now')),
        updated_at TEXT DEFAULT (datetime('now'))
      );
    `);
    // 把旧的单 provider Key 平滑迁移
    const legacy = d.prepare("SELECT value FROM settings WHERE key = 'gemini_key_encrypted'").get();
    if (legacy?.value) {
      d.prepare(`
        INSERT OR REPLACE INTO ai_providers (provider, api_key_encrypted, model, enabled, is_default, updated_at)
        VALUES ('gemini', ?, 'gemini-3.5-flash', 1, 1, datetime('now'))
      `).run(legacy.value);
      d.prepare("DELETE FROM settings WHERE key = 'gemini_key_encrypted'").run();
    }
  },
  // v3: 会计制度初始化 - 写入默认 'CN' 作为会计 locale
  (d) => {
    const has = d.prepare("SELECT 1 FROM settings WHERE key = 'accounting_locale'").get();
    if (!has) {
      d.prepare("INSERT INTO settings (key, value, updated_at) VALUES ('accounting_locale', ?, datetime('now'))").run(JSON.stringify('CN'));
    }
  },
  // v4: 国际化数据模型第一步 — categories 表 + 6 国预置种子数据
  // 详见 docs/INTERNATIONALIZATION_PLAN.md §2.2 / §4
  (d) => {
    d.exec(`
      CREATE TABLE IF NOT EXISTS categories (
        id TEXT PRIMARY KEY,
        locale TEXT NOT NULL,
        type TEXT NOT NULL CHECK (type IN ('income', 'expense')),
        slug TEXT NOT NULL,
        label_zh_cn TEXT NOT NULL,
        label_zh_tw TEXT,
        label_en TEXT NOT NULL,
        label_ja TEXT,
        label_ko TEXT,
        label_fr TEXT,
        schedule_line TEXT,
        is_deductible INTEGER DEFAULT 1,
        deductible_pct REAL DEFAULT 100,
        parent_id TEXT,
        sort_order INTEGER DEFAULT 0,
        is_system INTEGER DEFAULT 1,
        created_at TEXT DEFAULT (datetime('now')),
        UNIQUE(locale, type, slug)
      );
      CREATE INDEX IF NOT EXISTS idx_categories_locale_type ON categories(locale, type);
    `);
    // Seed 6 国预置类别（首次跑 v4 时插入；已有则 UNIQUE 约束跳过）
    try {
      const { SEEDS } = require('./seedCategories');
      const insert = d.prepare(`
        INSERT OR IGNORE INTO categories
          (id, locale, type, slug, label_zh_cn, label_zh_tw, label_en, label_ja, label_ko, label_fr,
           schedule_line, is_deductible, deductible_pct, sort_order, is_system)
        VALUES
          (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
      `);
      const tx = d.transaction((rows) => {
        for (const r of rows) {
          insert.run(
            r.id, r.locale, r.type, r.slug,
            r.label_zh_cn, r.label_zh_tw || null, r.label_en, r.label_ja || null, r.label_ko || null, r.label_fr || null,
            r.schedule_line || null,
            r.is_deductible == null ? 1 : r.is_deductible,
            r.deductible_pct == null ? 100 : r.deductible_pct,
            r.sort_order || 0,
          );
        }
      });
      tx(SEEDS);
      console.log(`[db] seeded ${SEEDS.length} categories across 6 locales`);
    } catch (e) {
      console.error('[db] seed categories failed:', e?.message || e);
    }
  },
  // v5: 国际化数据模型核心 — transactions 表 + legacy_migrations 映射表
  // 详见 docs/INTERNATIONALIZATION_PLAN.md §2.3 / §3
  // sales / purchases 表保留只读，由迁移工具一键转入 transactions
  (d) => {
    d.exec(`
      CREATE TABLE IF NOT EXISTS transactions (
        id TEXT PRIMARY KEY,
        type TEXT NOT NULL CHECK (type IN ('income', 'expense')),
        date TEXT NOT NULL,
        amount REAL NOT NULL,
        amount_net REAL,
        tax_amount REAL DEFAULT 0,
        tax_rate REAL DEFAULT 0,
        currency TEXT NOT NULL DEFAULT 'CNY',
        category_id TEXT,
        counterparty TEXT,
        invoice_no TEXT,
        invoice_status TEXT DEFAULT 'n/a',
        payment_status TEXT DEFAULT 'paid',
        paid_amount REAL DEFAULT 0,
        payment_date TEXT,
        due_date TEXT,
        description TEXT,
        attachment_path TEXT,
        source_meta TEXT,
        created_at TEXT DEFAULT (datetime('now')),
        updated_at TEXT DEFAULT (datetime('now')),
        FOREIGN KEY (category_id) REFERENCES categories(id)
      );
      CREATE INDEX IF NOT EXISTS idx_txn_date ON transactions(date);
      CREATE INDEX IF NOT EXISTS idx_txn_type_date ON transactions(type, date);
      CREATE INDEX IF NOT EXISTS idx_txn_category ON transactions(category_id);
      CREATE INDEX IF NOT EXISTS idx_txn_payment ON transactions(payment_status);

      CREATE TABLE IF NOT EXISTS legacy_migrations (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        legacy_table TEXT NOT NULL CHECK (legacy_table IN ('sales', 'purchases')),
        legacy_id TEXT NOT NULL,
        new_id TEXT NOT NULL,
        migrated_at TEXT DEFAULT (datetime('now')),
        UNIQUE(legacy_table, legacy_id)
      );
      CREATE INDEX IF NOT EXISTS idx_legacy_mig_new ON legacy_migrations(new_id);
    `);
    console.log('[db] created transactions + legacy_migrations tables');
  },
  // v6: US-specific — mileage_logs + home_office_settings (F stage)
  (d) => {
    d.exec(`
      CREATE TABLE IF NOT EXISTS mileage_logs (
        id TEXT PRIMARY KEY,
        date TEXT NOT NULL,
        start_location TEXT,
        end_location TEXT,
        miles REAL NOT NULL,
        purpose TEXT,
        round_trip INTEGER DEFAULT 0,
        rate_per_mile REAL DEFAULT 0.67,
        deduction REAL GENERATED ALWAYS AS (miles * rate_per_mile * (1 + round_trip)) STORED,
        created_at TEXT DEFAULT (datetime('now'))
      );
      CREATE INDEX IF NOT EXISTS idx_mileage_date ON mileage_logs(date);

      CREATE TABLE IF NOT EXISTS home_office (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        method TEXT DEFAULT 'simplified' CHECK (method IN ('simplified', 'actual')),
        sqft REAL DEFAULT 0,
        rate_per_sqft REAL DEFAULT 5.0,
        max_sqft REAL DEFAULT 300,
        total_home_sqft REAL DEFAULT 0,
        annual_rent REAL DEFAULT 0,
        annual_utilities REAL DEFAULT 0,
        annual_insurance REAL DEFAULT 0,
        annual_depreciation REAL DEFAULT 0,
        updated_at TEXT DEFAULT (datetime('now'))
      );
      INSERT OR IGNORE INTO home_office (id) VALUES (1);
    `);
    console.log('[db] created mileage_logs + home_office tables');
  },
  // v7: Fix alerts table schema — add is_read + is_dismissed if missing
  (d) => {
    // Guard: skip if alerts table doesn't exist (shouldn't happen but be safe)
    const tableExists = d.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='alerts'").get();
    if (!tableExists) {
      console.log('[db] v7: alerts table not found, skipping column fix');
      return;
    }
    const cols = d.prepare("PRAGMA table_info(alerts)").all().map(c => c.name);
    let fixed = 0;
    if (!cols.includes('is_read')) {
      d.exec('ALTER TABLE alerts ADD COLUMN is_read INTEGER DEFAULT 0');
      // Copy from old `read` column if it exists (bare identifier, not string)
      if (cols.includes('read')) {
        d.exec('UPDATE alerts SET is_read = `read`');
      }
      fixed++;
    }
    if (!cols.includes('is_dismissed')) {
      d.exec('ALTER TABLE alerts ADD COLUMN is_dismissed INTEGER DEFAULT 0');
      fixed++;
    }
    d.exec('CREATE INDEX IF NOT EXISTS idx_alerts_read ON alerts(is_read)');
    if (fixed > 0) console.log(`[db] v7: fixed alerts schema — added ${fixed} missing column(s)`);
    else console.log('[db] v7: alerts schema OK');
  },
  // v8: Repair corrupted is_read data from v7 (may have string "read" instead of integer)
  (d) => {
    const tableExists = d.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='alerts'").get();
    if (!tableExists) return;
    // Fix any non-integer values in is_read (v7 bug set it to string "read")
    try {
      d.exec("UPDATE alerts SET is_read = 0 WHERE typeof(is_read) != 'integer'");
      d.exec("UPDATE alerts SET is_dismissed = 0 WHERE typeof(is_dismissed) != 'integer'");
      console.log('[db] v8: alerts data repaired');
    } catch (e) {
      console.warn('[db] v8: alerts repair skipped:', e?.message);
    }
  },
  // v9: products / service items master data (per-item unit + service flag).
  //   Phase 1 — additive only; does NOT touch purchases/sales or inventory/calc.
  (d) => {
    d.exec(`
      CREATE TABLE IF NOT EXISTS products (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        unit TEXT NOT NULL DEFAULT 'piece',
        default_unit_cost REAL DEFAULT 0,
        is_service INTEGER DEFAULT 0,
        is_active INTEGER DEFAULT 1,
        sort_order INTEGER DEFAULT 0,
        created_at TEXT DEFAULT (datetime('now')),
        updated_at TEXT DEFAULT (datetime('now'))
      )
    `);
    d.exec('CREATE INDEX IF NOT EXISTS idx_products_active ON products(is_active)');
    console.log('[db] v9: products table ready');
  },
  // v10: per-record product reference + unit snapshot on purchases/sales (Phase 2).
  //   Snapshot freezes the item's name/unit at record time so later product edits
  //   don't change history. Nullable → legacy rows stay "unassigned". Calc unchanged.
  (d) => {
    for (const tbl of ['purchases', 'sales']) {
      const cols = d.prepare(`PRAGMA table_info(${tbl})`).all().map(c => c.name);
      if (!cols.includes('product_id')) d.exec(`ALTER TABLE ${tbl} ADD COLUMN product_id TEXT`);
      if (!cols.includes('product_name_snapshot')) d.exec(`ALTER TABLE ${tbl} ADD COLUMN product_name_snapshot TEXT`);
      if (!cols.includes('unit_snapshot')) d.exec(`ALTER TABLE ${tbl} ADD COLUMN unit_snapshot TEXT`);
      d.exec(`CREATE INDEX IF NOT EXISTS idx_${tbl}_product ON ${tbl}(product_id)`);
    }
    console.log('[db] v10: purchases/sales product snapshot columns ready');
  },
  // v11: business documents (报价单/销售单/形式发票/商业发票/对账单) — header + line
  //   items. Internal documents only: NOT formal tax-invoice issuance; tax_invoice_*
  //   columns record an EXTERNALLY issued invoice by hand (UI lands in a later phase).
  //   items.product_id is a plain column on purpose — an enforced FK would break the
  //   bare DELETE in products.remove (foreign_keys is ON); items are self-contained
  //   snapshots (description/unit frozen at save time). acc_locale freezes the
  //   accounting regime at creation so saved documents keep their currency/tax labels.
  (d) => {
    d.exec(`
      CREATE TABLE IF NOT EXISTS business_documents (
        id TEXT PRIMARY KEY,
        doc_type TEXT NOT NULL CHECK(doc_type IN ('quotation','sales_order','proforma_invoice','commercial_invoice','statement')),
        doc_number TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'draft' CHECK(status IN ('draft','issued','void')),
        doc_date TEXT NOT NULL,
        valid_until TEXT,
        customer_name TEXT NOT NULL,
        customer_tax_id TEXT,
        customer_address TEXT,
        customer_contact TEXT,
        acc_locale TEXT NOT NULL DEFAULT 'CN',
        subtotal REAL DEFAULT 0,
        tax_amount REAL DEFAULT 0,
        total REAL DEFAULT 0,
        notes TEXT,
        source_sales_id TEXT,
        period_start TEXT,
        period_end TEXT,
        tax_invoice_issued INTEGER DEFAULT 0,
        tax_invoice_number TEXT,
        tax_invoice_date TEXT,
        tax_invoice_attachment_path TEXT,
        created_at TEXT DEFAULT (datetime('now')),
        updated_at TEXT DEFAULT (datetime('now'))
      )
    `);
    d.exec('CREATE UNIQUE INDEX IF NOT EXISTS idx_docs_type_number ON business_documents(doc_type, doc_number)');
    d.exec('CREATE INDEX IF NOT EXISTS idx_docs_type_date ON business_documents(doc_type, doc_date)');
    d.exec(`
      CREATE TABLE IF NOT EXISTS business_document_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        doc_id TEXT NOT NULL REFERENCES business_documents(id) ON DELETE CASCADE,
        product_id TEXT,
        description TEXT NOT NULL,
        quantity REAL,
        unit TEXT,
        unit_price REAL,
        tax_rate TEXT,
        tax_amount REAL DEFAULT 0,
        amount REAL DEFAULT 0,
        line_no INTEGER DEFAULT 0,
        ref_sales_id TEXT,
        ref_date TEXT
      )
    `);
    d.exec('CREATE INDEX IF NOT EXISTS idx_doc_items_doc ON business_document_items(doc_id)');
    console.log('[db] v11: business_documents + business_document_items ready');
  },
  // v12: AI assistant conversation persistence — two tables.
  //   Stores chat history ONLY. The API key / any decrypted secret is NEVER written here.
  //   tool_trace holds the already-masked R2b trace (name / argsSummary / rowCount / truncated),
  //   no raw tool results, no key.
  (d) => {
    d.exec(`
      CREATE TABLE IF NOT EXISTS assistant_conversations (
        id TEXT PRIMARY KEY,
        title TEXT,
        acc_locale TEXT,
        ui_language TEXT,
        created_at TEXT DEFAULT (datetime('now')),
        updated_at TEXT DEFAULT (datetime('now'))
      )
    `);
    d.exec('CREATE INDEX IF NOT EXISTS idx_asst_conv_updated ON assistant_conversations(updated_at)');
    d.exec(`
      CREATE TABLE IF NOT EXISTS assistant_messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        conversation_id TEXT NOT NULL REFERENCES assistant_conversations(id) ON DELETE CASCADE,
        role TEXT NOT NULL CHECK(role IN ('user','model')),
        text TEXT NOT NULL,
        tool_trace TEXT,
        seq INTEGER DEFAULT 0,
        created_at TEXT DEFAULT (datetime('now'))
      )
    `);
    d.exec('CREATE INDEX IF NOT EXISTS idx_asst_msg_conv ON assistant_messages(conversation_id, seq)');
    console.log('[db] v12: assistant_conversations + assistant_messages ready');
  },
  // v13: COGS classification flag (PR-T5) — split COGS from operating expenses.
  //   Adds categories.is_cogs and backfills the seeded cost-of-goods categories
  //   (slug 'cogs' for CN/JP/KR/TW; slug 'purchases' for EU). Operating-expense
  //   and user-created categories stay 0. Idempotent (guarded on PRAGMA table_info).
  (d) => {
    const cols = d.prepare('PRAGMA table_info(categories)').all();
    if (!cols.some((c) => c.name === 'is_cogs')) {
      d.exec('ALTER TABLE categories ADD COLUMN is_cogs INTEGER DEFAULT 0');
    }
    d.exec("UPDATE categories SET is_cogs = 1 WHERE slug = 'cogs' OR (locale = 'EU' AND slug = 'purchases')");
    console.log('[db] v13: categories.is_cogs added + backfilled');
  },
];

function runMigrations(d) {
  const current = d.pragma('user_version', { simple: true });
  for (let v = current; v < MIGRATIONS.length; v++) {
    d.transaction(() => {
      MIGRATIONS[v](d);
      d.pragma(`user_version = ${v + 1}`);
    })();
    console.log(`[db] migrated to v${v + 1}`);
  }
}

// 当前应用支持的最高 schema 版本（= 迁移数）。恢复备份时若备份的 user_version
// 高于此值，说明它来自更新版本的应用，schema 可能不兼容，拒绝恢复。
const SCHEMA_VERSION = MIGRATIONS.length;

// 关闭数据库连接（恢复备份前调用）：
//   1. 先 wal_checkpoint(TRUNCATE) 把 WAL 落盘到主库，清空 -wal
//   2. db.close() 释放句柄，避免覆盖主库文件时旧句柄回写脏数据
//   3. db = null，下次 getDb() 会惰性重连（但恢复后我们走重启，不在本进程重连）
function closeDb() {
  if (!db) return;
  try { db.pragma('wal_checkpoint(TRUNCATE)'); } catch (e) { console.warn('[db] checkpoint before close failed:', e?.message || e); }
  try { db.close(); } catch (e) { console.warn('[db] close failed:', e?.message || e); }
  db = null;
}

module.exports = { initDatabase, getDb, getDbPath, closeDb, SCHEMA_VERSION };
