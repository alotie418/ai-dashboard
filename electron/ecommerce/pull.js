// E-commerce order PULL → STAGING orchestrator (PR-EC3).
//
// Pulls orders from a connected platform (Shopify / WooCommerce) and lands them in
// ecommerce_staged_orders as PREVIEW data + writes one ecommerce_sync_log row per run.
//
// HARD BOUNDARIES (do NOT cross):
//   - writes ONLY ecommerce_staged_orders + ecommerce_sync_log (+ the connection's
//     sync watermark). NEVER writes sales / sales_items / purchases / inventory.
//   - carries NO accounting meaning: staged amounts are the platform's raw values for
//     preview; nothing is posted, no COGS / tax / AR-AP is computed.
//   - buyer PII (name/email/address/phone) is never stored; raw_excerpt_json stays NULL
//     (the full raw payload is not persisted).
//   - the sync log / errors never contain credentials (redact()).
//
// Correctness of incremental pulls rests on the STAGING UPSERT idempotency
// (unique (connection_id, external_order_id)), NOT on a perfect platform-side filter —
// a re-fetched order is de-duplicated, never double-inserted.

const { getDb } = require('../db');
const shopify = require('./providers/shopify');
const woocommerce = require('./providers/woocommerce');

const DEFAULT_PROVIDERS = { shopify, woocommerce };
const MAX_PAGES = 20;   // per-run page cap (constraint: hit → status 'partial', resume next run)

function getSafeStorage() { return require('electron').safeStorage; }
function decryptSecret(encrypted) {
  const ss = getSafeStorage();
  if (!ss.isEncryptionAvailable()) throw new Error('safeStorage 不可用，无法解密电商凭证');
  return ss.decryptString(Buffer.from(encrypted, 'base64'));
}

// Strip anything credential-shaped so it can never reach the sync log / error_json / console.
function redact(msg) {
  if (msg == null) return msg;
  return String(msg)
    .replace(/(bearer|basic|token|key|secret|authorization|shpat_|ck_|cs_)[^\s"']*/ig, '[redacted]')
    .slice(0, 300);
}

// Idempotent upsert of one normalized order. Returns 'new' | 'updated' | 'skipped'.
function upsertStaged(db, conn, normalized) {
  const ext = normalized.externalOrderId;
  const row = db.prepare(
    'SELECT id, stage_status FROM ecommerce_staged_orders WHERE connection_id = ? AND external_order_id = ?'
  ).get(conn.id, ext);
  const total = normalized.totals && Number.isFinite(normalized.totals.grandTotalGross) ? normalized.totals.grandTotalGross : null;
  const json = JSON.stringify(normalized);   // normalized already PII-minimised by the adapter
  if (row) {
    // Committed rows (PR-EC5) are never silently overwritten. EC3 produces none.
    if (row.stage_status === 'committed') return 'skipped';
    db.prepare(`UPDATE ecommerce_staged_orders SET
      order_number = ?, order_status = ?, order_created_at = ?, order_updated_at = ?, currency = ?, total_gross = ?,
      normalized_json = ?, raw_excerpt_json = NULL, last_pulled_at = datetime('now'), updated_at = datetime('now'), error = NULL
      WHERE id = ?`).run(
      normalized.orderNumber, normalized.orderStatus, normalized.createdAt, normalized.updatedAt,
      normalized.currency, total, json, row.id);
    return 'updated';
  }
  db.prepare(`INSERT INTO ecommerce_staged_orders
    (connection_id, platform, external_order_id, order_number, order_status, order_created_at, order_updated_at,
     currency, total_gross, normalized_json, raw_excerpt_json, match_status, stage_status)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, 'unresolved', 'staged')`).run(
    conn.id, conn.platform, ext, normalized.orderNumber, normalized.orderStatus,
    normalized.createdAt, normalized.updatedAt, normalized.currency, total, json);
  return 'new';
}

// pull(connectionId, opts) → { status, pulled, stagedNew, stagedUpdated, errors, pages, error? }
//   opts.providers : override the adapter registry (tests inject mocks — no network)
//   opts.creds     : TEST-ONLY — skip safeStorage decrypt (node test env has no safeStorage)
//   opts.maxPages  : override the 20-page cap (tests)
async function pull(connectionId, opts = {}) {
  const providers = opts.providers || DEFAULT_PROVIDERS;
  const maxPages = opts.maxPages || MAX_PAGES;
  const db = getDb();

  const conn = db.prepare('SELECT * FROM ecommerce_connections WHERE id = ?').get(connectionId);
  if (!conn) throw new Error('连接不存在');
  const adapter = providers[conn.platform];
  if (!adapter || typeof adapter.pullOrdersPage !== 'function' || typeof adapter.normalizeOrder !== 'function') {
    throw new Error(`platform ${conn.platform} does not support order pull`);
  }
  // Real runs decrypt in the main process; tests pass opts.creds and never touch safeStorage.
  const creds = opts.creds || JSON.parse(decryptSecret(conn.credentials_encrypted));

  const since = conn.last_order_updated_at || null;
  const cursorBefore = conn.last_cursor || null;
  const started = Date.now();

  let cursor = cursorBefore;
  let hasNext = true;
  let pages = 0, pulled = 0, stagedNew = 0, stagedUpdated = 0, errors = 0;
  let maxUpdated = since;
  let status = 'ok';
  let errObj = null;

  try {
    while (hasNext && pages < maxPages) {
      const page = await adapter.pullOrdersPage(creds, { since, cursor, pageSize: opts.pageSize });
      pages++;
      const raws = Array.isArray(page?.rawOrders) ? page.rawOrders : [];
      const applyPage = db.transaction(() => {
        for (const raw of raws) {
          let normalized;
          try { normalized = adapter.normalizeOrder(raw); } catch { errors++; continue; }
          if (!normalized || !normalized.externalOrderId) { errors++; continue; }
          pulled++;
          const r = upsertStaged(db, conn, normalized);
          if (r === 'new') stagedNew++; else if (r === 'updated') stagedUpdated++;
          if (normalized.updatedAt && (!maxUpdated || normalized.updatedAt > maxUpdated)) maxUpdated = normalized.updatedAt;
        }
      });
      applyPage();
      cursor = page?.nextCursor != null ? page.nextCursor : null;
      hasNext = !!page?.hasNextPage;
    }
    if (hasNext && pages >= maxPages) status = 'partial';   // cap reached, more remain → resume next run
  } catch (e) {
    status = 'error';
    errors++;
    errObj = { code: e?.code || 'unknown', message: redact(e?.message) };
  }

  const duration = Date.now() - started;

  db.prepare(`INSERT INTO ecommerce_sync_log
    (connection_id, platform, status, pulled, staged_new, staged_updated, errors, pages,
     since_used, cursor_before, cursor_after, duration_ms, error_json)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`).run(
    conn.id, conn.platform, status, pulled, stagedNew, stagedUpdated, errors, pages,
    since, cursorBefore != null ? String(cursorBefore) : null,
    status === 'partial' && cursor != null ? String(cursor) : null,
    duration, errObj ? JSON.stringify(errObj) : null);

  if (status !== 'error') {
    // advance watermark only when the run had no hard error (partial = pages all succeeded, just capped)
    db.prepare(`UPDATE ecommerce_connections SET last_synced_at = datetime('now'),
      last_order_updated_at = ?, last_cursor = ?, updated_at = datetime('now') WHERE id = ?`).run(
      maxUpdated || conn.last_order_updated_at || null,
      status === 'partial' && cursor != null ? String(cursor) : null,
      conn.id);
  } else {
    // error → record the attempt time but DO NOT advance watermark/cursor (re-pull safely; upsert dedups)
    db.prepare("UPDATE ecommerce_connections SET last_synced_at = datetime('now'), updated_at = datetime('now') WHERE id = ?").run(conn.id);
  }

  return { status, pulled, stagedNew, stagedUpdated, errors, pages, ...(errObj ? { error: errObj } : {}) };
}

module.exports = { pull, upsertStaged, redact, MAX_PAGES };
