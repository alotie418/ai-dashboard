// Shopify connector — GraphQL Admin API adapter.
//
// Shopify's REST Admin API is legacy; new integrations use the GraphQL Admin API.
// This MVP slice implements ONLY testConnection (verify the store domain + Admin
// API access token reach a live shop). Order pull / normalization are a later phase.
//
// ⚠️ OFFICIAL-DOCS CONFIRMATION REQUIRED before relying on any of the constants
// below — verify against the current Shopify GraphQL Admin API docs:
//   - endpoint path:  https://{shop}.myshopify.com/admin/api/{version}/graphql.json
//   - auth header:    X-Shopify-Access-Token: <admin api access token>
//   - API version:    Shopify versions the Admin API quarterly (YYYY-MM). SHOPIFY_API_VERSION
//                     below is the single source of truth — bump it each quarter per Shopify's
//                     version calendar and confirm against official docs (versions are supported
//                     for ~12 months, so keep it recent).
//   - query fields:   `shop { name myshopifyDomain currencyCode }` are stable, but
//                     confirm field availability for the pinned version.
// Auth model for MVP: single-store CUSTOM APP admin token (no OAuth redirect flow).

const { publicMeta } = require('./_providerInterface');

// Single source of truth for the Admin API version. Shopify versions quarterly (YYYY-MM);
// bump this each quarter and confirm the current stable version against official docs.
const SHOPIFY_API_VERSION = '2026-07';
const TEST_TIMEOUT_MS = 15000;

const META = {
  id: 'shopify',
  name: 'Shopify',
  transport: 'graphql',
  authMode: 'manual_token',
  status: 'available',
  shopField: {
    key: 'shop',
    label: 'Store domain',
    placeholder: 'your-store.myshopify.com',
  },
  credentialFields: [
    { key: 'token', label: 'Admin API access token', placeholder: 'shpat_...', secret: true },
  ],
  // Official docs entry point (for the UI "how to create a token" link).
  docsUrl: 'https://shopify.dev/docs/api/admin-graphql',
};

// Normalise user input to a canonical "<store>.myshopify.com" host.
// Accepts: "mystore", "mystore.myshopify.com", "https://mystore.myshopify.com/…".
// Returns null when the input can't be resolved to a myshopify.com host — the
// caller reports a 'config' error rather than firing a request at a bad host.
function normalizeShopHost(input) {
  if (!input || typeof input !== 'string') return null;
  let s = input.trim().toLowerCase();
  if (!s) return null;
  // strip scheme + any path/query
  s = s.replace(/^https?:\/\//, '').replace(/\/.*$/, '').replace(/\s+/g, '');
  if (!s) return null;
  // bare handle → add the myshopify.com suffix
  if (!s.includes('.')) s = `${s}.myshopify.com`;
  // only allow myshopify.com store hosts for this MVP (custom domains → confirm later)
  if (!/^[a-z0-9][a-z0-9-]*\.myshopify\.com$/.test(s)) return null;
  return s;
}

function getFetch() {
  const f = globalThis.fetch;
  if (typeof f !== 'function') return null;
  return f;
}

// testConnection({ shop, token }) → { ok, storeInfo?, code?, providerMessage? }
// Never throws for expected failures; never returns the token in any field.
async function testConnection(creds) {
  const { shop, token } = creds || {};
  const host = normalizeShopHost(shop);
  if (!host) return { ok: false, code: 'config', providerMessage: 'invalid or missing store domain' };
  if (!token || typeof token !== 'string' || !token.trim()) {
    return { ok: false, code: 'config', providerMessage: 'missing admin api access token' };
  }

  const doFetch = getFetch();
  if (!doFetch) return { ok: false, code: 'unavailable', providerMessage: 'fetch is not available in this runtime' };

  const url = `https://${host}/admin/api/${SHOPIFY_API_VERSION}/graphql.json`;
  const query = '{ shop { name myshopifyDomain currencyCode } }';

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TEST_TIMEOUT_MS);
  let resp;
  try {
    resp = await doFetch(url, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-Shopify-Access-Token': token.trim(),
        'Accept': 'application/json',
      },
      body: JSON.stringify({ query }),
      signal: controller.signal,
    });
  } catch (e) {
    const aborted = e && (e.name === 'AbortError');
    return {
      ok: false,
      code: aborted ? 'timeout' : 'network',
      providerMessage: aborted ? `timed out after ${TEST_TIMEOUT_MS}ms` : (e?.message || 'network error'),
    };
  } finally {
    clearTimeout(timer);
  }

  // HTTP-level classification (do NOT echo response bodies that could carry data;
  // keep providerMessage to status + a short generic hint).
  if (resp.status === 401 || resp.status === 403) {
    return { ok: false, code: 'auth', status: resp.status, providerMessage: `HTTP ${resp.status} — token rejected` };
  }
  if (resp.status === 404) {
    return { ok: false, code: 'notFound', status: resp.status, providerMessage: `HTTP 404 — store domain or API version not found` };
  }
  if (!resp.ok) {
    return { ok: false, code: 'http', status: resp.status, providerMessage: `HTTP ${resp.status}` };
  }

  let json;
  try {
    json = await resp.json();
  } catch (e) {
    return { ok: false, code: 'parse', providerMessage: 'response was not valid JSON' };
  }

  if (json && Array.isArray(json.errors) && json.errors.length) {
    const first = json.errors[0]?.message || 'graphql error';
    return { ok: false, code: 'graphql', providerMessage: String(first).slice(0, 200) };
  }

  const shopNode = json?.data?.shop;
  if (!shopNode || !shopNode.name) {
    return { ok: false, code: 'unexpected', providerMessage: 'shop query returned no data' };
  }

  return {
    ok: true,
    storeInfo: {
      name: shopNode.name,
      domain: shopNode.myshopifyDomain || host,
      currency: shopNode.currencyCode || null,
    },
  };
}

module.exports = {
  meta: META,
  testConnection,
  publicMeta: () => publicMeta(module.exports),
  // exported for unit testing the domain normaliser without a network call
  _normalizeShopHost: normalizeShopHost,
};
