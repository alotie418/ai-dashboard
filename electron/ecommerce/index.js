// E-commerce connector — unified management face (MVP: connection settings only).
// - manage: listProviders / list / save / test / setEnabled / remove
//
// Credentials are encrypted at rest exactly like ai_providers: safeStorage
// encrypt → base64 → ecommerce_connections.credentials_encrypted. The renderer
// NEVER receives the plaintext (or the ciphertext); decryption happens only in
// the main process, right before a testConnection call, and is never logged.
//
// SCOPE (through PR-EC3): connect + store credentials + test + PULL orders into a
// STAGING preview area (ecommerce_staged_orders) + a sync log. It STILL does NOT write
// anything into sales / sales_items / purchases / inventory — staging only, no posting.

const { getDb } = require('../db');
const { assertValidProvider, publicMeta } = require('./providers/_providerInterface');
const { pull } = require('./pull');

const shopify = require('./providers/shopify');
const woocommerce = require('./providers/woocommerce');

// Functional registry: ONLY platforms with a real adapter live here. This is the
// allowlist for save()/test() — anything not in PROVIDERS is rejected. The 9
// display-only platforms below (CATALOG) deliberately have NO adapter, so the
// backend refuses to store credentials or test them.
const PROVIDERS = {
  shopify,
  woocommerce,
};

// Fail fast at load: every registered provider must satisfy the interface.
for (const id of Object.keys(PROVIDERS)) assertValidProvider(PROVIDERS[id]);

const VALID_IDS = Object.keys(PROVIDERS);

// Platform catalog (display metadata for ALL target platforms). Connectable
// platforms (those in PROVIDERS) are merged from their adapter meta; the rest are
// DISPLAY-ONLY: no adapter, no credential fields, no testConnection — the settings
// UI shows their status and blocks any credential input, and save()/test() reject
// them via the VALID_IDS allowlist. authMode values here are architectural
// predictions and must be confirmed per each platform's official docs.
const CATALOG = [
  { id: 'shopify',      tier: 1 },  // available — from adapter
  { id: 'woocommerce',  tier: 1 },  // available — from adapter
  { id: 'amazon',       name: 'Amazon',       tier: 2, status: 'needs_authorization', authMode: 'oauth2',                docsUrl: 'https://developer-docs.amazon.com/sp-api/' },
  { id: 'tiktok_shop',  name: 'TikTok Shop',  tier: 2, status: 'needs_authorization', authMode: 'oauth2',                docsUrl: 'https://partner.tiktokshop.com/' },
  { id: 'temu',         name: 'TEMU',         tier: 2, status: 'needs_authorization', authMode: 'oauth2',                docsUrl: '' },
  { id: 'shein',        name: 'SHEIN',        tier: 2, status: 'needs_authorization', authMode: 'oauth2',                docsUrl: '' },
  { id: 'pinduoduo',    name: '拼多多',        tier: 3, status: 'planned',             authMode: 'signed_openapi',        docsUrl: '' },
  { id: 'taobao_tmall', name: '淘宝 / 天猫',   tier: 3, status: 'planned',             authMode: 'signed_openapi',        docsUrl: '' },
  { id: 'jd',           name: '京东',          tier: 3, status: 'planned',             authMode: 'signed_openapi',        docsUrl: '' },
  { id: 'douyin',       name: '抖店',          tier: 3, status: 'planned',             authMode: 'signed_openapi',        docsUrl: '' },
  { id: 'xiaohongshu',  name: '小红书',        tier: 3, status: 'planned',             authMode: 'partner_authorization', docsUrl: '' },
];

// Build the renderer-safe catalog: connectable entries carry the adapter's
// publicMeta (fields/docs) + connectable:true; display-only entries carry static
// metadata + connectable:false + empty credentialFields (so the UI renders NO input).
function buildCatalog() {
  return CATALOG.map((entry) => {
    const adapter = PROVIDERS[entry.id];
    if (adapter) {
      return { ...publicMeta(adapter), tier: entry.tier, connectable: true };
    }
    return {
      id: entry.id,
      name: entry.name,
      transport: null,
      authMode: entry.authMode,
      status: entry.status,
      tier: entry.tier,
      shopField: null,
      credentialFields: [],
      docsUrl: entry.docsUrl || '',
      connectable: false,
    };
  });
}

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

// The platform catalog (renderer-safe metas) — ALL target platforms with their
// status; connectable ones also carry the fields the "add connection" form needs.
function listProviders() {
  return buildCatalog();
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
    throw new Error('新建连接需要填写凭证');
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

// ============================================================
// 拉单 → 暂存（PR-EC3）—— 只读账本，只写 staged / sync_log
// ============================================================

// List staged orders (preview data). NEVER contains credentials. normalized_json is
// parsed into `normalized` for the renderer. Read-only.
function listStaged({ connectionId, status, limit = 200 } = {}) {
  const db = getDb();
  const where = [];
  const args = [];
  if (connectionId) { where.push('connection_id = ?'); args.push(connectionId); }
  if (status) { where.push('stage_status = ?'); args.push(status); }
  const sql = `SELECT id, connection_id, platform, external_order_id, order_number, order_status,
      order_created_at, order_updated_at, currency, total_gross, normalized_json, match_status,
      stage_status, committed_sale_id, first_seen_at, last_pulled_at, error
    FROM ecommerce_staged_orders
    ${where.length ? 'WHERE ' + where.join(' AND ') : ''}
    ORDER BY order_updated_at DESC, id DESC LIMIT ?`;
  const rows = db.prepare(sql).all(...args, Math.max(1, Math.min(1000, limit)));
  return rows.map((r) => {
    let normalized = null;
    try { normalized = r.normalized_json ? JSON.parse(r.normalized_json) : null; } catch { normalized = null; }
    return {
      id: r.id, connectionId: r.connection_id, platform: r.platform, externalOrderId: r.external_order_id,
      orderNumber: r.order_number, orderStatus: r.order_status,
      orderCreatedAt: r.order_created_at, orderUpdatedAt: r.order_updated_at,
      currency: r.currency, totalGross: r.total_gross, normalized,
      matchStatus: r.match_status, stageStatus: r.stage_status, committedSaleId: r.committed_sale_id,
      firstSeenAt: r.first_seen_at, lastPulledAt: r.last_pulled_at, error: r.error,
    };
  });
}

// List sync-log runs. error_json is parsed; never contains credentials (pull.js redacts). Read-only.
function listSyncLog({ connectionId, limit = 50 } = {}) {
  const db = getDb();
  const sql = `SELECT id, connection_id, platform, run_at, status, pulled, staged_new, staged_updated,
      errors, pages, since_used, cursor_before, cursor_after, duration_ms, error_json
    FROM ecommerce_sync_log
    ${connectionId ? 'WHERE connection_id = ?' : ''}
    ORDER BY id DESC LIMIT ?`;
  const args = connectionId ? [connectionId, Math.max(1, Math.min(500, limit))] : [Math.max(1, Math.min(500, limit))];
  const rows = db.prepare(sql).all(...args);
  return rows.map((r) => {
    let error = null;
    try { error = r.error_json ? JSON.parse(r.error_json) : null; } catch { error = null; }
    return {
      id: r.id, connectionId: r.connection_id, platform: r.platform, runAt: r.run_at, status: r.status,
      pulled: r.pulled, stagedNew: r.staged_new, stagedUpdated: r.staged_updated, errors: r.errors,
      pages: r.pages, sinceUsed: r.since_used, cursorBefore: r.cursor_before, cursorAfter: r.cursor_after,
      durationMs: r.duration_ms, error,
    };
  });
}

// PR-EC5a: staged → sales/sales_items commit (the ONLY ledger-writing path in this
// module tree; two-pass all-or-nothing, see ./commit.js)
const { commit } = require('./commit');

module.exports = {
  listProviders, list, save, test, setEnabled, remove,
  // PR-EC3: pull → staging (no ledger write)
  pull, listStaged, listSyncLog,
  // PR-EC5a: commit staged orders into the ledger
  commit,
  // exported for tests
  _PROVIDERS: PROVIDERS, _VALID_IDS: VALID_IDS,
};
