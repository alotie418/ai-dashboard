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

module.exports = { initDatabase, getDb, getDbPath };
