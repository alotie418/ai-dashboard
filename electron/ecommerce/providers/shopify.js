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

// ============================================================
// PR-EC3: order pull → staging (NO ledger write)
// ============================================================
//
// ⚠️ OFFICIAL-DOCS CONFIRMATION REQUIRED (Shopify GraphQL Admin API):
//   - `orders(first, after, query, sortKey, reverse)` connection shape, `pageInfo { hasNextPage endCursor }`;
//   - incremental filter via `query: "updated_at:>=<ISO>"` + `sortKey: UPDATED_AT` ascending;
//   - money is exposed as *Set { shopMoney { amount currencyCode } } — confirm exact field names;
//   - rate limiting is COST-BASED (`extensions.cost.throttleStatus`); on THROTTLED / 429 back off
//     using the restore rate. Confirm cost fields + limits.
// The field selection below is a MINIMAL, representative shape; confirm every field name against
// the pinned SHOPIFY_API_VERSION before real use. Idempotency (staging upsert) makes an imperfect
// incremental filter safe (re-fetched orders are de-duplicated, never double-inserted).

const ORDERS_PAGE_SIZE = 50;      // per-page order count (confirm max page size per docs)
const LINE_ITEMS_PER_ORDER = 100; // nested line-items page (confirm)

function buildOrdersQuery(pageSize, cursor, since) {
  const filter = since ? `updated_at:>='${since}'` : '';
  const afterArg = cursor ? `, after: ${JSON.stringify(cursor)}` : '';
  // sortKey UPDATED_AT ascending so the watermark advances monotonically.
  return `{
    orders(first: ${pageSize}${afterArg}, sortKey: UPDATED_AT, query: ${JSON.stringify(filter)}) {
      pageInfo { hasNextPage endCursor }
      edges { node {
        id name createdAt updatedAt displayFinancialStatus
        currentTotalPriceSet { shopMoney { amount currencyCode } }
        subtotalPriceSet { shopMoney { amount } }
        totalTaxSet { shopMoney { amount } }
        totalShippingPriceSet { shopMoney { amount } }
        customer { id }
        lineItems(first: ${LINE_ITEMS_PER_ORDER}) { edges { node {
          sku title quantity
          originalUnitPriceSet { shopMoney { amount } }
          discountedUnitPriceSet { shopMoney { amount } }
          taxLines { title ratePercentage priceSet { shopMoney { amount } } }
        } } }
        shippingLines { edges { node { title originalPriceSet { shopMoney { amount } } } } }
        taxLines { title ratePercentage priceSet { shopMoney { amount } } }
        refunds { id createdAt totalRefundedSet { shopMoney { amount } } }
      } }
    }
  }`;
}

// Fetch ONE page of orders. Returns { rawOrders, nextCursor, hasNextPage }. Throws a coded
// Error on hard failure (pull.js records it in the sync log). Does a small internal backoff
// on throttling. NEVER logs credentials.
async function pullOrdersPage(creds, { since, cursor, pageSize } = {}) {
  const { shop, token } = creds || {};
  const host = normalizeShopHost(shop);
  if (!host) { const e = new Error('invalid store domain'); e.code = 'config'; throw e; }
  if (!token) { const e = new Error('missing token'); e.code = 'config'; throw e; }
  const doFetch = getFetch();
  if (!doFetch) { const e = new Error('fetch unavailable'); e.code = 'unavailable'; throw e; }

  const url = `https://${host}/admin/api/${SHOPIFY_API_VERSION}/graphql.json`;
  const query = buildOrdersQuery(pageSize || ORDERS_PAGE_SIZE, cursor, since);

  for (let attempt = 0; attempt < 4; attempt++) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), TEST_TIMEOUT_MS);
    let resp;
    try {
      resp = await doFetch(url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'X-Shopify-Access-Token': token.trim(), 'Accept': 'application/json' },
        body: JSON.stringify({ query }),
        signal: controller.signal,
      });
    } catch (e) {
      clearTimeout(timer);
      const err = new Error(e?.name === 'AbortError' ? 'timeout' : (e?.message || 'network error'));
      err.code = e?.name === 'AbortError' ? 'timeout' : 'network';
      throw err;  // never carries creds
    }
    clearTimeout(timer);

    if (resp.status === 429) { await backoff(attempt); continue; }  // throttled → retry
    if (resp.status === 401 || resp.status === 403) { const e = new Error(`HTTP ${resp.status}`); e.code = 'auth'; e.status = resp.status; throw e; }
    if (!resp.ok) { const e = new Error(`HTTP ${resp.status}`); e.code = 'http'; e.status = resp.status; throw e; }

    let json;
    try { json = await resp.json(); } catch { const e = new Error('invalid JSON'); e.code = 'parse'; throw e; }

    // Cost-based throttling can also surface as a top-level error with THROTTLED code.
    const throttled = Array.isArray(json?.errors) && json.errors.some((x) => /throttl/i.test(x?.extensions?.code || x?.message || ''));
    if (throttled) { await backoff(attempt); continue; }
    if (Array.isArray(json?.errors) && json.errors.length) {
      const e = new Error(String(json.errors[0]?.message || 'graphql error').slice(0, 200)); e.code = 'graphql'; throw e;
    }

    const conn = json?.data?.orders;
    const edges = conn?.edges || [];
    return {
      rawOrders: edges.map((x) => x.node).filter(Boolean),
      nextCursor: conn?.pageInfo?.endCursor || null,
      hasNextPage: !!conn?.pageInfo?.hasNextPage,
    };
  }
  const e = new Error('throttled — retries exhausted'); e.code = 'throttled'; throw e;
}

function backoff(attempt) {
  const ms = Math.min(4000, 500 * Math.pow(2, attempt));
  return new Promise((r) => setTimeout(r, ms));
}

const money = (set) => { const a = parseFloat(set?.shopMoney?.amount); return Number.isFinite(a) ? a : null; };

// PURE: Shopify order node → neutral NormalizedOrder. No buyer PII (only an opaque customer id ref).
function normalizeOrder(o) {
  const currency = o?.currentTotalPriceSet?.shopMoney?.currencyCode || null;
  const items = (o?.lineItems?.edges || []).map((x) => x.node).filter(Boolean).map((li) => {
    const unitNet = money(li.discountedUnitPriceSet) ?? money(li.originalUnitPriceSet);
    const qty = Number.isFinite(li.quantity) ? li.quantity : null;
    const lineTax = (li.taxLines || []).reduce((s, t) => s + (money(t.priceSet) || 0), 0);
    const lineNet = unitNet != null && qty != null ? unitNet * qty : null;
    // a single tax jurisdiction gives an honest per-line rate; multiple taxLines (e.g. CA
    // GST+PST, US state+county) would make rate×net ≠ tax — report NULL instead of the
    // first jurisdiction's rate (PR-EC5a review fix; lineTax stays the Σ of all taxLines)
    const rate = li.taxLines && li.taxLines.length === 1 && li.taxLines[0].ratePercentage != null ? Number(li.taxLines[0].ratePercentage) : null;
    return {
      sku: li.sku || null, name: li.title || null, quantity: qty,
      unitPriceNet: unitNet, lineNet, lineTax: lineTax || null,
      lineGross: lineNet != null ? lineNet + (lineTax || 0) : null, taxRate: rate,
    };
  });
  const shipLines = (o?.shippingLines?.edges || []).map((x) => x.node).filter(Boolean).map((s) => ({ title: s.title || null, amount: money(s.originalPriceSet) }));
  const taxLines = (o?.taxLines || []).map((t) => ({ title: t.title || null, rate: t.ratePercentage != null ? Number(t.ratePercentage) : null, amount: money(t.priceSet) }));
  const refunds = (o?.refunds || []).map((r) => ({ id: r.id || null, createdAt: r.createdAt || null, amount: money(r.totalRefundedSet) }));
  return {
    platform: 'shopify',
    externalOrderId: String(o?.id || ''),
    orderNumber: o?.name || null,
    orderStatus: o?.displayFinancialStatus || null,
    createdAt: o?.createdAt || null,
    updatedAt: o?.updatedAt || null,
    currency,
    header: { customerRef: o?.customer?.id ? String(o.customer.id) : null },   // opaque id only — NO name/email/address/phone
    items,
    shipping: { total: money(o?.totalShippingPriceSet), lines: shipLines },
    taxes: { total: money(o?.totalTaxSet), lines: taxLines },
    fees: [],   // Shopify Payments fees live in a separate balance API, not the order object (later phase)
    refunds,
    totals: {
      subtotalNet: money(o?.subtotalPriceSet),
      taxTotal: money(o?.totalTaxSet),
      shippingTotal: money(o?.totalShippingPriceSet),
      grandTotalGross: money(o?.currentTotalPriceSet),
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
  _normalizeShopHost: normalizeShopHost,
  _buildOrdersQuery: buildOrdersQuery,
};
