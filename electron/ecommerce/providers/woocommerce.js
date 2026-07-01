// WooCommerce connector — REST API adapter (authMode: key_secret).
//
// This MVP slice implements ONLY testConnection (verify the store URL + REST API
// Consumer key/secret reach a live WooCommerce store with read access). Order pull
// / normalization are a later phase — this adapter never touches order data.
//
// ⚠️ OFFICIAL-DOCS CONFIRMATION REQUIRED before relying on the constants below —
// verify against the current WooCommerce REST API docs
// (https://woocommerce.github.io/woocommerce-rest-api-docs/):
//   - keys:      customer generates a Consumer key / Consumer secret at
//                WooCommerce > Settings > Advanced > REST API (Read permission is
//                enough for this MVP).
//   - auth:      over HTTPS, HTTP Basic Auth — Consumer key as username,
//                Consumer secret as password (Authorization: Basic base64(ck:cs)).
//   - endpoint:  a MINIMAL, READ-ONLY, AUTH-PROTECTED endpoint is used purely to
//                validate site + credentials. GET {siteRoot}/wp-json/wc/v3/system_status
//                requires read auth and returns no order/customer data. We inspect
//                ONLY the HTTP status + that the body parses as JSON — the response
//                body is NEVER saved or logged.
//   - HTTPS ONLY: http:// is rejected outright. No OAuth 1.0a, no HTTP fallback.
//   - We deliberately DO NOT call orders (e.g. /orders?per_page=1) — this PR must
//     not touch order data.

const { publicMeta } = require('./_providerInterface');

// Minimal auth-protected read endpoint used only to validate site + credentials.
const WC_TEST_PATH = '/wp-json/wc/v3/system_status';
const TEST_TIMEOUT_MS = 15000;

const META = {
  id: 'woocommerce',
  name: 'WooCommerce',
  transport: 'rest',
  authMode: 'key_secret',
  status: 'available',
  shopField: {
    key: 'shop',
    label: 'Store URL',
    placeholder: 'https://your-store.com',
  },
  credentialFields: [
    { key: 'consumerKey', label: 'Consumer key', placeholder: 'ck_...', secret: true },
    { key: 'consumerSecret', label: 'Consumer secret', placeholder: 'cs_...', secret: true },
  ],
  docsUrl: 'https://woocommerce.github.io/woocommerce-rest-api-docs/',
};

// Normalise the store URL to a canonical HTTPS root (supports sub-directory WP
// installs by preserving the path). HTTPS ONLY:
//   - http://…            → { error: 'http' }  (rejected; no fallback)
//   - bare "example.com"  → assume https://example.com
//   - trailing slashes stripped
// Returns { url } on success or { error: 'http' | 'invalid' }.
function normalizeSiteUrl(input) {
  if (!input || typeof input !== 'string') return { error: 'invalid' };
  let s = input.trim();
  if (!s) return { error: 'invalid' };
  if (/^http:\/\//i.test(s)) return { error: 'http' };          // explicit http → reject
  if (!/^https:\/\//i.test(s)) s = `https://${s}`;              // bare domain → assume https
  try {
    const u = new URL(s);
    if (u.protocol !== 'https:') return { error: 'http' };
    if (!u.hostname || !u.hostname.includes('.')) return { error: 'invalid' };
    const root = `${u.origin}${u.pathname}`.replace(/\/+$/, '');  // keep subdir path, strip trailing slash
    return { url: root };
  } catch {
    return { error: 'invalid' };
  }
}

function getFetch() {
  const f = globalThis.fetch;
  if (typeof f !== 'function') return null;
  return f;
}

// testConnection({ shop, consumerKey, consumerSecret }) → { ok, storeInfo?, code?, providerMessage? }
// Never throws for expected failures; never returns/logs the credentials or the response body.
async function testConnection(creds) {
  const { shop, consumerKey, consumerSecret } = creds || {};
  const norm = normalizeSiteUrl(shop);
  if (norm.error === 'http') {
    return { ok: false, code: 'config', providerMessage: 'http:// is not supported — use an https store URL' };
  }
  if (norm.error) {
    return { ok: false, code: 'config', providerMessage: 'invalid or missing store URL' };
  }
  if (!consumerKey || typeof consumerKey !== 'string' || !consumerKey.trim() ||
      !consumerSecret || typeof consumerSecret !== 'string' || !consumerSecret.trim()) {
    return { ok: false, code: 'config', providerMessage: 'missing consumer key/secret' };
  }

  const doFetch = getFetch();
  if (!doFetch) return { ok: false, code: 'unavailable', providerMessage: 'fetch is not available in this runtime' };

  const url = `${norm.url}${WC_TEST_PATH}`;
  // HTTPS Basic Auth: consumer key = username, consumer secret = password.
  const auth = 'Basic ' + Buffer.from(`${consumerKey.trim()}:${consumerSecret.trim()}`).toString('base64');

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TEST_TIMEOUT_MS);
  let resp;
  try {
    resp = await doFetch(url, {
      method: 'GET',
      headers: { 'Authorization': auth, 'Accept': 'application/json' },
      signal: controller.signal,
    });
  } catch (e) {
    const aborted = e && e.name === 'AbortError';
    return {
      ok: false,
      code: aborted ? 'timeout' : 'network',
      providerMessage: aborted ? `timed out after ${TEST_TIMEOUT_MS}ms` : (e?.message || 'network error'),
    };
  } finally {
    clearTimeout(timer);
  }

  if (resp.status === 401 || resp.status === 403) {
    return { ok: false, code: 'auth', status: resp.status, providerMessage: `HTTP ${resp.status} — consumer key/secret rejected` };
  }
  if (resp.status === 404) {
    return { ok: false, code: 'notFound', status: resp.status, providerMessage: 'HTTP 404 — WooCommerce REST API not found at this URL' };
  }
  if (!resp.ok) {
    return { ok: false, code: 'http', status: resp.status, providerMessage: `HTTP ${resp.status}` };
  }

  // Validate the body parses as JSON, then DISCARD it — never saved or logged
  // (avoids persisting store configuration returned by system_status).
  try {
    await resp.json();
  } catch {
    return { ok: false, code: 'parse', providerMessage: 'response was not valid JSON (is this a WooCommerce store?)' };
  }

  // storeInfo kept minimal on purpose (host only); no store config is retained.
  let host = norm.url;
  try { host = new URL(norm.url).host; } catch { /* keep root */ }
  return { ok: true, storeInfo: { name: host, domain: host, currency: null } };
}

// ============================================================
// PR-EC3: order pull → staging (NO ledger write)
// ============================================================
//
// ⚠️ OFFICIAL-DOCS CONFIRMATION REQUIRED (WooCommerce / WordPress REST API):
//   - endpoint:   GET {siteRoot}/wp-json/wc/v3/orders?per_page=&page=
//   - pagination: page/per_page; total pages from response header `X-WP-TotalPages`
//                 (fallback: a page returning < per_page rows is the last page).
//   - INCREMENTAL: `modified_after` (based on date_modified_gmt) IS the intended filter, BUT
//                  per the EC3 constraint we do NOT hard-depend on `orderby=modified` (its
//                  availability for the orders endpoint is not reliably confirmable). Strategy:
//                    * pass `modified_after=<watermark>` ONLY as a volume-reduction hint
//                      (confirm it is honoured; if not, it is simply ignored by the server);
//                    * rely on page-based pagination with the DEFAULT ordering (no orderby=modified);
//                    * CORRECTNESS comes from the staging UPSERT idempotency (re-fetched orders
//                      are de-duplicated), NOT from a perfect incremental filter.
//                  The watermark is advanced to the max date_modified_gmt actually seen.
//   - auth:       HTTPS Basic Auth base64(ck:cs), same as testConnection. HTTPS-only.
// Confirm every field/param name against the official docs before real use.

const WC_ORDERS_PATH = '/wp-json/wc/v3/orders';
const WC_PAGE_SIZE = 50;

// Fetch ONE page of orders → { rawOrders, nextCursor, hasNextPage }. nextCursor is the next
// PAGE NUMBER (page-based); pull.js passes it back as `cursor`. Throws a coded Error on hard
// failure. Small internal backoff on 429/503. NEVER logs credentials.
async function pullOrdersPage(creds, { since, cursor, pageSize } = {}) {
  const { shop, consumerKey, consumerSecret } = creds || {};
  const norm = normalizeSiteUrl(shop);
  if (norm.error === 'http') { const e = new Error('http not supported'); e.code = 'config'; throw e; }
  if (norm.error) { const e = new Error('invalid store URL'); e.code = 'config'; throw e; }
  if (!consumerKey || !consumerSecret) { const e = new Error('missing key/secret'); e.code = 'config'; throw e; }
  const doFetch = getFetch();
  if (!doFetch) { const e = new Error('fetch unavailable'); e.code = 'unavailable'; throw e; }

  const page = Number.isFinite(cursor) && cursor > 0 ? cursor : 1;
  const per = pageSize || WC_PAGE_SIZE;
  const params = new URLSearchParams({ per_page: String(per), page: String(page) });
  if (since) params.set('modified_after', since);   // volume-reduction hint only (see header note)
  const url = `${norm.url}${WC_ORDERS_PATH}?${params.toString()}`;
  const auth = 'Basic ' + Buffer.from(`${consumerKey.trim()}:${consumerSecret.trim()}`).toString('base64');

  for (let attempt = 0; attempt < 4; attempt++) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), TEST_TIMEOUT_MS);
    let resp;
    try {
      resp = await doFetch(url, { method: 'GET', headers: { 'Authorization': auth, 'Accept': 'application/json' }, signal: controller.signal });
    } catch (e) {
      clearTimeout(timer);
      const err = new Error(e?.name === 'AbortError' ? 'timeout' : (e?.message || 'network error'));
      err.code = e?.name === 'AbortError' ? 'timeout' : 'network';
      throw err;
    }
    clearTimeout(timer);

    if (resp.status === 429 || resp.status === 503) { await backoff(attempt); continue; }
    if (resp.status === 401 || resp.status === 403) { const e = new Error(`HTTP ${resp.status}`); e.code = 'auth'; e.status = resp.status; throw e; }
    if (resp.status === 404) { const e = new Error('HTTP 404 — WooCommerce REST API not found'); e.code = 'notFound'; e.status = 404; throw e; }
    if (!resp.ok) { const e = new Error(`HTTP ${resp.status}`); e.code = 'http'; e.status = resp.status; throw e; }

    let arr;
    try { arr = await resp.json(); } catch { const e = new Error('invalid JSON'); e.code = 'parse'; throw e; }
    if (!Array.isArray(arr)) { const e = new Error('unexpected orders payload'); e.code = 'unexpected'; throw e; }

    const totalPages = parseInt(resp.headers.get('X-WP-TotalPages') || '', 10);
    const hasNextPage = Number.isFinite(totalPages) ? page < totalPages : arr.length >= per;
    return { rawOrders: arr, nextCursor: hasNextPage ? page + 1 : null, hasNextPage };
  }
  const e = new Error('rate limited — retries exhausted'); e.code = 'throttled'; throw e;
}

function backoff(attempt) {
  const ms = Math.min(4000, 500 * Math.pow(2, attempt));
  return new Promise((r) => setTimeout(r, ms));
}

const num = (v) => { const n = parseFloat(v); return Number.isFinite(n) ? n : null; };

// PURE: WooCommerce order → neutral NormalizedOrder. Buyer PII (billing/shipping name/email/
// address/phone) is DELIBERATELY IGNORED — only an opaque customer_id ref is kept.
function normalizeOrder(o) {
  const items = (o?.line_items || []).map((li) => {
    const qty = Number.isFinite(li.quantity) ? li.quantity : num(li.quantity);
    const lineNet = num(li.subtotal);              // WooCommerce: subtotal = net line before tax (confirm)
    const lineTax = num(li.total_tax);
    const lineGross = num(li.total) != null && lineTax != null ? num(li.total) + lineTax : num(li.total);
    return {
      sku: li.sku || null, name: li.name || null, quantity: qty,
      unitPriceNet: lineNet != null && qty ? lineNet / qty : null,
      lineNet, lineTax, lineGross, taxRate: null,
    };
  });
  const shipLines = (o?.shipping_lines || []).map((s) => ({ title: s.method_title || null, amount: num(s.total) }));
  const taxLines = (o?.tax_lines || []).map((t) => ({ title: t.rate_code || t.label || null, rate: num(t.rate_percent), amount: num(t.tax_total) }));
  const fees = (o?.fee_lines || []).map((f) => ({ title: f.name || null, amount: num(f.total) }));
  const refunds = (o?.refunds || []).map((r) => ({ id: r.id != null ? String(r.id) : null, createdAt: null, amount: num(r.total) }));
  return {
    platform: 'woocommerce',
    externalOrderId: String(o?.id ?? ''),
    orderNumber: o?.number != null ? String(o.number) : null,
    orderStatus: o?.status || null,
    createdAt: o?.date_created_gmt || o?.date_created || null,
    updatedAt: o?.date_modified_gmt || o?.date_modified || null,
    currency: o?.currency || null,
    header: { customerRef: o?.customer_id ? `wc-${o.customer_id}` : null },   // opaque id only — NO PII
    items,
    shipping: { total: num(o?.shipping_total), lines: shipLines },
    taxes: { total: num(o?.total_tax), lines: taxLines },
    fees,
    refunds,
    totals: {
      subtotalNet: items.reduce((s, i) => s + (i.lineNet || 0), 0) || null,
      taxTotal: num(o?.total_tax),
      shippingTotal: num(o?.shipping_total),
      grandTotalGross: num(o?.total),
    },
  };
}

module.exports = {
  meta: META,
  testConnection,
  pullOrdersPage,
  normalizeOrder,
  publicMeta: () => publicMeta(module.exports),
  // exported for unit testing without a network call
  _normalizeSiteUrl: normalizeSiteUrl,
};
