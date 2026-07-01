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

module.exports = {
  meta: META,
  testConnection,
  publicMeta: () => publicMeta(module.exports),
  // exported for unit testing the URL normaliser without a network call
  _normalizeSiteUrl: normalizeSiteUrl,
};
