// E-commerce connector — unified management face (MVP: connection settings only).
// - manage: listProviders / list / save / test / setEnabled / remove
//
// Credentials are encrypted at rest exactly like ai_providers: safeStorage
// encrypt → base64 → ecommerce_connections.credentials_encrypted. The renderer
// NEVER receives the plaintext (or the ciphertext); decryption happens only in
// the main process, right before a testConnection call, and is never logged.
//
// SCOPE GUARD: this module ONLY connects + stores credentials + tests. It does
// NOT pull orders, stage orders, sync, or write anything into sales/sales_items.

const { getDb } = require('../db');
const { assertValidProvider, publicMeta } = require('./providers/_providerInterface');

const shopify = require('./providers/shopify');

const PROVIDERS = {
  shopify,
};

// Fail fast at load: every registered provider must satisfy the interface.
for (const id of Object.keys(PROVIDERS)) assertValidProvider(PROVIDERS[id]);

const VALID_IDS = Object.keys(PROVIDERS);

// ── safeStorage helpers (same pattern as electron/ai/index.js) ──
function getSafeStorage() {
  return require('electron').safeStorage;
}
function encryptSecret(plain) {
  const ss = getSafeStorage();
  if (!ss.isEncryptionAvailable()) throw new Error('safeStorage 不可用，无法加密电商凭证');
  return ss.encryptString(plain).toString('base64');
}
function decryptSecret(encrypted) {
  const ss = getSafeStorage();
  if (!ss.isEncryptionAvailable()) throw new Error('safeStorage 不可用，无法解密电商凭证');
  return ss.decryptString(Buffer.from(encrypted, 'base64'));
}

// Self-heal: ensure the table exists (users upgrading before v21 ran also work).
function ensureTable() {
  const db = getDb();
  if (!db) throw new Error('数据库未初始化');
  db.exec(`
    CREATE TABLE IF NOT EXISTS ecommerce_connections (
      id                    TEXT PRIMARY KEY,
      platform              TEXT NOT NULL,
      label                 TEXT,
      shop_identifier       TEXT,
      credentials_encrypted TEXT NOT NULL,
      store_currency        TEXT,
      enabled               INTEGER DEFAULT 1,
      last_test_at          TEXT,
      last_test_ok          INTEGER,
      created_at            TEXT DEFAULT (datetime('now')),
      updated_at            TEXT DEFAULT (datetime('now'))
    );
  `);
}

function genId(platform) {
  const rand = Math.random().toString(36).slice(2, 8);
  return `ec-${platform}-${Date.now().toString(36)}${rand}`;
}

// ============================================================
// 管理面
// ============================================================

// The provider catalog (renderer-safe metas) — what platforms can be connected
// and which fields the "add connection" form should collect.
function listProviders() {
  return VALID_IDS.map((id) => publicMeta(PROVIDERS[id]));
}

// Saved connections — NEVER exposes credentials. hasCredentials is a boolean flag only.
function list() {
  ensureTable();
  const db = getDb();
  const rows = db.prepare(`
    SELECT id, platform, label, shop_identifier, store_currency, enabled,
           last_test_at, last_test_ok, credentials_encrypted, created_at, updated_at
    FROM ecommerce_connections
    ORDER BY created_at ASC
  `).all();
  return rows.map((r) => ({
    id: r.id,
    platform: r.platform,
    platformName: PROVIDERS[r.platform]?.meta?.name || r.platform,
    label: r.label || '',
    shopIdentifier: r.shop_identifier || '',
    storeCurrency: r.store_currency || null,
    enabled: !!r.enabled,
    lastTestAt: r.last_test_at || null,
    lastTestOk: r.last_test_ok == null ? null : !!r.last_test_ok,
    hasCredentials: !!r.credentials_encrypted,
    createdAt: r.created_at,
    updatedAt: r.updated_at,
  }));
}

function credsHaveSecret(credentials) {
  return credentials && typeof credentials === 'object' &&
    Object.values(credentials).some((v) => typeof v === 'string' && v.trim());
}

// save({ id?, platform, label?, shopIdentifier, credentials?, storeCurrency?, enabled? })
// New connection: credentials required. Existing connection: credentials optional
// (blank = keep the saved secret; lets the user edit the domain/label without re-pasting).
function save({ id, platform, label, shopIdentifier, credentials, storeCurrency, enabled = true } = {}) {
  if (!VALID_IDS.includes(platform)) throw new Error(`Unknown e-commerce platform: ${platform}`);
  ensureTable();
  const db = getDb();

  const existing = id ? db.prepare('SELECT * FROM ecommerce_connections WHERE id = ?').get(id) : null;

  let encrypted;
  if (credsHaveSecret(credentials)) {
    // store only non-empty fields; encrypt the whole JSON blob
    const clean = {};
    for (const [k, v] of Object.entries(credentials)) {
      if (typeof v === 'string' && v.trim()) clean[k] = v.trim();
    }
    encrypted = encryptSecret(JSON.stringify(clean));
  } else if (existing) {
    encrypted = existing.credentials_encrypted;
  } else {
    throw new Error('新建连接需要填写凭证（如 Admin API token）');
  }

  const finalId = existing ? existing.id : (id || genId(platform));
  const shopVal = (typeof shopIdentifier === 'string' ? shopIdentifier.trim() : (existing?.shop_identifier || null)) || null;
  const labelVal = (typeof label === 'string' ? label.trim() : (existing?.label || '')) || null;
  const currencyVal = (typeof storeCurrency === 'string' ? storeCurrency.trim() : (existing?.store_currency || null)) || null;
  const enabledVal = enabled ? 1 : 0;

  db.prepare(`
    INSERT INTO ecommerce_connections
      (id, platform, label, shop_identifier, credentials_encrypted, store_currency, enabled, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, datetime('now'))
    ON CONFLICT(id) DO UPDATE SET
      label = excluded.label,
      shop_identifier = excluded.shop_identifier,
      credentials_encrypted = excluded.credentials_encrypted,
      store_currency = excluded.store_currency,
      enabled = excluded.enabled,
      updated_at = datetime('now')
  `).run(finalId, platform, labelVal, shopVal, encrypted, currencyVal, enabledVal);

  return { success: true, id: finalId };
}

// test({ id?, platform, shopIdentifier?, credentials? }) → { ok, storeInfo?, code?, providerMessage? }
// Inline creds (from the add/edit form) take priority; else the saved connection's
// stored domain + decrypted credentials are used. Never returns the secret.
async function test({ id, platform, shopIdentifier, credentials } = {}) {
  let plat = platform;
  let shop = shopIdentifier;
  let creds = credsHaveSecret(credentials) ? { ...credentials } : null;

  if (id) {
    ensureTable();
    const row = getDb().prepare('SELECT * FROM ecommerce_connections WHERE id = ?').get(id);
    if (!row) throw new Error('连接不存在');
    plat = plat || row.platform;
    if (!shop) shop = row.shop_identifier;
    if (!creds) {
      try { creds = JSON.parse(decryptSecret(row.credentials_encrypted)); }
      catch { creds = null; }
    }
  }

  if (!VALID_IDS.includes(plat)) throw new Error(`Unknown e-commerce platform: ${plat}`);
  const adapter = PROVIDERS[plat];

  const result = await adapter.testConnection({ shop, ...(creds || {}) });

  // Persist the last-test outcome for a saved connection (UI shows it).
  if (id) {
    try {
      getDb().prepare(
        "UPDATE ecommerce_connections SET last_test_at = datetime('now'), last_test_ok = ?, updated_at = datetime('now') WHERE id = ?"
      ).run(result?.ok ? 1 : 0, id);
    } catch { /* best-effort; never block the test result on a write */ }
  }

  // Strip anything secret-shaped defensively; adapters already avoid echoing creds.
  const { ok, storeInfo, code, status, providerMessage } = result || {};
  return { ok: !!ok, storeInfo: storeInfo || null, code: code || null, status: status || null, providerMessage: providerMessage || null };
}

function setEnabled({ id, enabled } = {}) {
  ensureTable();
  const db = getDb();
  const row = db.prepare('SELECT 1 FROM ecommerce_connections WHERE id = ?').get(id);
  if (!row) throw new Error('连接不存在');
  db.prepare("UPDATE ecommerce_connections SET enabled = ?, updated_at = datetime('now') WHERE id = ?")
    .run(enabled ? 1 : 0, id);
  return { success: true };
}

function remove({ id } = {}) {
  ensureTable();
  const db = getDb();
  db.prepare('DELETE FROM ecommerce_connections WHERE id = ?').run(id);
  return { success: true };
}

module.exports = {
  listProviders, list, save, test, setEnabled, remove,
  // exported for tests
  _PROVIDERS: PROVIDERS, _VALID_IDS: VALID_IDS,
};
