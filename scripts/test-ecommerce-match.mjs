#!/usr/bin/env node
// Pure-function test for the EC4 staged-order product matcher (name-only, read-only).
// Run via the TS resolver (same as check:locale-matrix) so we import the exact .ts the app uses:
//   node --experimental-loader ./scripts/_ts-resolver.mjs scripts/test-ecommerce-match.mjs
//
// Asserts the three EC4 rules: matched / ambiguous / description-only(unmatched), plus that
// the platform SKU is NOT used for matching (product.id must never be treated as a SKU).

// Import the exact .ts the app uses via an EXPLICIT .ts path (same pattern as
// check-locale-matrix.mjs) so Node's native type-stripping handles it.
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const { matchItem, matchOrderItems } = await import(join(ROOT, 'components/ecommerce/matchStagedItems.ts'));

const failures = [];
const ok = (cond, msg) => { if (!cond) failures.push(msg); };

const products = [
  { id: 'p1', name: 'Widget', is_active: true },
  { id: 'p2', name: 'Dup', is_active: true },
  { id: 'p3', name: 'Dup', is_active: true },
  { id: 'p4', name: 'OldThing', is_active: false },   // inactive → excluded
  { id: 'SKU-9', name: 'ByName', is_active: true },     // id looks like a SKU on purpose
];

// a. exact unique active name → matched
{
  const r = matchItem({ name: 'Widget' }, products);
  ok(r.status === 'matched' && r.productId === 'p1', '[M1] exact unique active name → matched (p1)');
}
// b. multiple same active name → ambiguous
{
  const r = matchItem({ name: 'Dup' }, products);
  ok(r.status === 'ambiguous' && r.productId === null, '[M2] duplicate active name → ambiguous (no productId)');
}
// c. no match → unmatched (description-only)
{
  const r = matchItem({ name: 'Unknown' }, products);
  ok(r.status === 'unmatched' && r.productId === null, '[M3] no name match → unmatched (description-only)');
}
// inactive product name is NOT matched
{
  const r = matchItem({ name: 'OldThing' }, products);
  ok(r.status === 'unmatched', '[M4] inactive product name → unmatched (inactive excluded)');
}
// empty / missing name → unmatched
{
  ok(matchItem({ name: '' }, products).status === 'unmatched', '[M5] empty name → unmatched');
  ok(matchItem({}, products).status === 'unmatched', '[M5] missing name → unmatched');
}
// SKU is NOT used for matching: an item whose SKU equals a product.id but whose name has no
// product must stay unmatched (proves product.id is never treated as a SKU).
{
  const r = matchItem({ sku: 'SKU-9', name: 'NoSuchProductName' }, products);
  ok(r.status === 'unmatched', '[M6] SKU==product.id does NOT match (sku is display-only, not a matching key)');
  // and name match still works regardless of SKU value
  const r2 = matchItem({ sku: 'whatever', name: 'Widget' }, products);
  ok(r2.status === 'matched' && r2.productId === 'p1', '[M6] name match works irrespective of sku value');
}

// order-level aggregation
{
  ok(matchOrderItems([], products).orderStatus === 'empty', '[M7] no items → empty');
  ok(matchOrderItems([{ name: 'Widget' }, { name: 'Widget' }], products).orderStatus === 'matched', '[M7] all matched → matched');
  ok(matchOrderItems([{ name: 'Widget' }, { name: 'Unknown' }], products).orderStatus === 'partial', '[M7] some matched → partial');
  ok(matchOrderItems([{ name: 'Unknown' }, { name: 'Nope' }], products).orderStatus === 'unmatched', '[M7] none matched → unmatched');
  ok(matchOrderItems([{ name: 'Widget' }, { name: 'Dup' }], products).orderStatus === 'ambiguous', '[M7] any ambiguous → ambiguous');
}

// ── PR-EC5a parity: the main-process matcher (electron/ecommerce/matchItems.js) is the
// AUTHORITY at commit time and MUST behave identically to the renderer's preview matcher
// above. Run the same cases through both and require field-identical results.
{
  const backend = await import(join(ROOT, 'electron/ecommerce/matchItems.js'));
  const jsMatchItem = backend.matchItem ?? backend.default?.matchItem;
  const jsMatchOrderItems = backend.matchOrderItems ?? backend.default?.matchOrderItems;
  ok(typeof jsMatchItem === 'function' && typeof jsMatchOrderItems === 'function', '[P0] backend matcher exports matchItem/matchOrderItems');

  const itemCases = [
    { name: 'Widget' }, { name: 'Dup' }, { name: 'Unknown' }, { name: 'OldThing' },
    { name: '' }, {}, { sku: 'SKU-9', name: 'NoSuchProductName' }, { sku: 'whatever', name: 'Widget' },
    { name: '  Widget  ' },   // trimming parity
  ];
  for (const c of itemCases) {
    const ts = matchItem(c, products);
    const js = jsMatchItem(c, products);
    ok(ts.status === js.status && ts.productId === js.productId && ts.matchedName === js.matchedName,
      `[P1] matchItem parity for ${JSON.stringify(c)}: ts=${JSON.stringify(ts)} js=${JSON.stringify(js)}`);
  }
  const orderCases = [
    [], [{ name: 'Widget' }, { name: 'Widget' }], [{ name: 'Widget' }, { name: 'Unknown' }],
    [{ name: 'Unknown' }, { name: 'Nope' }], [{ name: 'Widget' }, { name: 'Dup' }],
  ];
  for (const c of orderCases) {
    const ts = matchOrderItems(c, products);
    const js = jsMatchOrderItems(c, products);
    ok(ts.orderStatus === js.orderStatus && JSON.stringify(ts.items) === JSON.stringify(js.items),
      `[P2] matchOrderItems parity for ${JSON.stringify(c)}: ts=${ts.orderStatus} js=${js.orderStatus}`);
  }

  // backend-only tolerance: raw DB rows carry is_active as INTEGER 0/1 (the renderer gets
  // booleans from products.list). 0 must count as INACTIVE for the authoritative matcher.
  const dbRows = [
    { id: 'p1', name: 'Widget', is_active: 1 },
    { id: 'p4', name: 'OldThing', is_active: 0 },
  ];
  ok(jsMatchItem({ name: 'Widget' }, dbRows).status === 'matched', '[P3] backend: is_active=1 (integer) → active');
  ok(jsMatchItem({ name: 'OldThing' }, dbRows).status === 'unmatched', '[P3] backend: is_active=0 (integer) → inactive, excluded');
}

if (failures.length) {
  console.error(`✗ ecommerce-match: ${failures.length} assertion(s) failed:`);
  for (const f of failures) console.error('  - ' + f);
  process.exit(1);
}
console.log('✓ ecommerce-match: all checks passed (matched / ambiguous / description-only + SKU-not-used + order aggregation + frontend/backend parity)');
