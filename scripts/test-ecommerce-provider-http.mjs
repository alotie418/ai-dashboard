#!/usr/bin/env node
// WooCommerce provider HTTP-branch coverage (local QA, NO network, NO real store).
//
// Gap this closes: the existing electron tests (test-handlers EC1–EC24) drive pull()/commit()
// through INJECTED mock adapters, so the real woocommerce.js testConnection() / pullOrdersPage()
// HTTP handling — Basic-auth header, endpoint selection, status→code mapping, JSON-parse guard,
// timeout/network branches, X-WP-TotalPages pagination, modified_after hint, 429 backoff — was
// never exercised by any automated test. Here we stub globalThis.fetch (the provider reads it
// fresh via getFetch() on every call, so a plain assignment intercepts all HTTP) and assert the
// real adapter's behaviour without a live WooCommerce store.
//
// Deliberately standalone (not folded into test-handlers.mjs): the WooCommerce adapter pulls in
// NO better-sqlite3 / electron native bindings, so this runs on a plain node with no rebuild —
// unlike test-handlers.mjs, which SKIPs when better-sqlite3's Electron ABI can't load locally.
//
// Boundaries honoured: no real network (fetch is stubbed), no real credentials (fake ck/cs),
// no ledger write (this file never touches a DB). Production code is imported read-only.

import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const require = createRequire(import.meta.url);
const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const woo = require(join(ROOT, 'electron/ecommerce/providers/woocommerce.js'));

const failures = [];
const ok = (cond, msg) => {
  if (cond) { console.log(`  ✓ ${msg}`); }
  else { console.log(`  ✗ ${msg}`); failures.push(msg); }
};

// ── fetch stub ────────────────────────────────────────────────────────────────
// The provider calls getFetch() → globalThis.fetch on every request, so replacing the
// global intercepts everything. `calls` records (url, opts) for header/param assertions.
const ORIG_FETCH = globalThis.fetch;
let calls = [];
function stub(handler) {
  calls = [];
  globalThis.fetch = async (url, opts) => { calls.push({ url: String(url), opts }); return handler(String(url), opts, calls.length - 1); };
}
function restoreFetch() { globalThis.fetch = ORIG_FETCH; }

// Minimal Response-like object matching exactly what woocommerce.js reads:
// .status, .ok, .json() and .headers.get(name) (case-insensitive, like a real Headers).
function res({ status = 200, ok: okFlag, jsonData, jsonThrows = false, headers = {} } = {}) {
  return {
    status,
    ok: okFlag !== undefined ? okFlag : (status >= 200 && status < 300),
    async json() { if (jsonThrows) throw new Error('invalid JSON'); return jsonData; },
    headers: {
      get(k) {
        const hit = Object.keys(headers).find((h) => h.toLowerCase() === String(k).toLowerCase());
        return hit != null ? headers[hit] : null;
      },
    },
  };
}

const CK = 'ck_live_abc123';
const CS = 'cs_live_xyz789';
const SHOP = 'https://demo-store.example.com';
const EXPECTED_AUTH = 'Basic ' + Buffer.from(`${CK}:${CS}`).toString('base64');
const creds = { shop: SHOP, consumerKey: CK, consumerSecret: CS };

async function run() {
  // ─────────────── testConnection ───────────────
  console.log('woocommerce.testConnection:');

  // 200 + JSON → ok, minimal storeInfo (host only), correct endpoint + Basic auth, no leak
  stub(() => res({ status: 200, jsonData: { environment: { version: '8.0' } } }));
  {
    const r = await woo.testConnection(creds);
    ok(r.ok === true, '200 + JSON → ok:true');
    ok(r.storeInfo && r.storeInfo.name === 'demo-store.example.com' && r.storeInfo.currency === null,
      'storeInfo host-only, currency null (system_status body discarded)');
    ok(calls.length === 1 && calls[0].url === 'https://demo-store.example.com/wp-json/wc/v3/system_status',
      'hits read-only system_status endpoint (never /orders)');
    ok(calls[0].opts.headers.Authorization === EXPECTED_AUTH, 'Authorization = Basic base64(ck:cs)');
    ok(calls[0].opts.headers.Accept === 'application/json', 'Accept: application/json');
    const dump = JSON.stringify(r);
    ok(!dump.includes(CK) && !dump.includes(CS), 'result never echoes the consumer key/secret');
  }

  // status → code mapping
  stub(() => res({ status: 401, ok: false }));
  ok(await woo.testConnection(creds).then((r) => r.code === 'auth' && r.status === 401), '401 → code auth');
  stub(() => res({ status: 403, ok: false }));
  ok(await woo.testConnection(creds).then((r) => r.code === 'auth' && r.status === 403), '403 → code auth');
  stub(() => res({ status: 404, ok: false }));
  ok(await woo.testConnection(creds).then((r) => r.code === 'notFound' && r.status === 404), '404 → code notFound');
  stub(() => res({ status: 500, ok: false }));
  ok(await woo.testConnection(creds).then((r) => r.code === 'http' && r.status === 500), '500 → code http');

  // 200 but body is not JSON → parse
  stub(() => res({ status: 200, jsonThrows: true }));
  ok(await woo.testConnection(creds).then((r) => r.code === 'parse'), '200 + non-JSON body → code parse');

  // fetch throws (plain) → network ; fetch throws AbortError → timeout
  stub(() => { throw new Error('ECONNREFUSED'); });
  ok(await woo.testConnection(creds).then((r) => r.code === 'network'), 'fetch throws → code network');
  stub(() => { const e = new Error('aborted'); e.name = 'AbortError'; throw e; });
  ok(await woo.testConnection(creds).then((r) => r.code === 'timeout'), 'AbortError → code timeout');

  // http:// is rejected BEFORE any network call (config), and missing creds too
  stub(() => res({ status: 200, jsonData: {} }));
  {
    const r = await woo.testConnection({ ...creds, shop: 'http://demo-store.example.com' });
    ok(r.ok === false && r.code === 'config', 'http:// store URL → code config');
    ok(calls.length === 0, 'http:// rejected before ANY network call (no fetch)');
  }
  stub(() => res({ status: 200, jsonData: {} }));
  {
    const r = await woo.testConnection({ shop: SHOP, consumerKey: '', consumerSecret: '' });
    ok(r.ok === false && r.code === 'config' && calls.length === 0, 'missing key/secret → code config, no network');
  }

  // ─────────────── pullOrdersPage ───────────────
  console.log('woocommerce.pullOrdersPage:');

  // page 1 of 2 via X-WP-TotalPages: hasNextPage true, nextCursor = 2; params + auth correct
  stub(() => res({ status: 200, jsonData: [{ id: 1 }, { id: 2 }], headers: { 'X-WP-TotalPages': '2' } }));
  {
    const p = await woo.pullOrdersPage(creds, { cursor: 1, pageSize: 2 });
    ok(p.rawOrders.length === 2 && p.hasNextPage === true && p.nextCursor === 2,
      'X-WP-TotalPages=2 on page 1 → hasNextPage, nextCursor 2');
    const u = new URL(calls[0].url);
    ok(u.pathname.endsWith('/wp-json/wc/v3/orders'), 'hits /orders endpoint');
    ok(u.searchParams.get('per_page') === '2' && u.searchParams.get('page') === '1', 'per_page & page query params set');
    ok(calls[0].opts.headers.Authorization === EXPECTED_AUTH, 'pull uses the same Basic auth');
  }

  // page 2 of 2 → last page
  stub(() => res({ status: 200, jsonData: [{ id: 3 }], headers: { 'X-WP-TotalPages': '2' } }));
  ok(await woo.pullOrdersPage(creds, { cursor: 2, pageSize: 2 }).then((p) => p.hasNextPage === false && p.nextCursor === null),
    'page 2 of 2 → hasNextPage false, nextCursor null');

  // no X-WP-TotalPages header → fallback to "full page ⇒ more"
  stub(() => res({ status: 200, jsonData: [{ id: 1 }, { id: 2 }], headers: {} }));
  ok(await woo.pullOrdersPage(creds, { cursor: 1, pageSize: 2 }).then((p) => p.hasNextPage === true && p.nextCursor === 2),
    'no total-pages header, page full → fallback hasNextPage true');
  stub(() => res({ status: 200, jsonData: [{ id: 1 }], headers: {} }));
  ok(await woo.pullOrdersPage(creds, { cursor: 1, pageSize: 2 }).then((p) => p.hasNextPage === false && p.nextCursor === null),
    'no total-pages header, page partial → last page');

  // since → modified_after volume-reduction hint
  stub(() => res({ status: 200, jsonData: [], headers: { 'X-WP-TotalPages': '1' } }));
  await woo.pullOrdersPage(creds, { cursor: 1, since: '2026-06-01T00:00:00' });
  ok(new URL(calls[0].url).searchParams.get('modified_after') === '2026-06-01T00:00:00', 'since → modified_after query param');

  // error statuses throw a coded Error; non-array payload → unexpected
  const codeOf = async (fn) => { try { await fn(); return '(no throw)'; } catch (e) { return e && e.code; } };
  stub(() => res({ status: 401, ok: false }));
  ok((await codeOf(() => woo.pullOrdersPage(creds, {}))) === 'auth', 'pull 401 → throws code auth');
  stub(() => res({ status: 404, ok: false }));
  ok((await codeOf(() => woo.pullOrdersPage(creds, {}))) === 'notFound', 'pull 404 → throws code notFound');
  stub(() => res({ status: 200, jsonData: { not: 'an array' }, headers: {} }));
  ok((await codeOf(() => woo.pullOrdersPage(creds, {}))) === 'unexpected', 'non-array orders payload → throws code unexpected');

  // 429 then 200 → internal backoff retries once and recovers (waits one ~500ms backoff)
  {
    let n = 0;
    stub(() => { n++; return n === 1 ? res({ status: 429, ok: false }) : res({ status: 200, jsonData: [{ id: 9 }], headers: { 'X-WP-TotalPages': '1' } }); });
    const p = await woo.pullOrdersPage(creds, { cursor: 1, pageSize: 50 });
    ok(p.rawOrders.length === 1 && calls.length === 2, '429 then 200 → backoff+retry recovers (2 fetches)');
  }

  // 429 forever → retries exhausted → throttled (4 attempts; inherently waits ~7.5s of backoff,
  // there is no injection seam to shorten the provider's own backoff timer)
  stub(() => res({ status: 429, ok: false }));
  {
    const code = await codeOf(() => woo.pullOrdersPage(creds, {}));
    ok(code === 'throttled' && calls.length === 4, '429 on every attempt → code throttled after 4 tries');
  }
}

try {
  await run();
} finally {
  restoreFetch();
}

if (failures.length) {
  console.log(`\n✗ ecommerce provider HTTP: ${failures.length} failure(s)`);
  process.exit(1);
}
console.log('\n✓ ecommerce provider HTTP: all WooCommerce testConnection/pullOrdersPage branches pass');
