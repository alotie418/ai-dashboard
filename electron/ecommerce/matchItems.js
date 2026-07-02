// Conservative product matching for staged-order COMMIT (PR-EC5a) — the main-process
// twin of components/ecommerce/matchStagedItems.ts. The renderer's copy computes PREVIEW
// state only; THIS module is the authority at commit time (commit.js re-matches against
// the live products table and never trusts renderer-provided product ids). The two
// implementations MUST stay behaviourally identical — scripts/test-ecommerce-match.mjs
// runs the same cases against both.
//
// Rules (same as EC4 — name-only, NO SKU matching):
//   a. exact, UNIQUE match against an ACTIVE product.name  → 'matched' (productId)
//   b. exact name matches MORE THAN ONE active product     → 'ambiguous'
//   c. no exact active-name match                          → 'unmatched' (description-only)
//
// One deliberate difference in input tolerance: the frontend receives is_active as a
// BOOLEAN (products.list maps !!is_active) while this module reads raw DB rows where
// is_active is an INTEGER 0/1 — so "inactive" here means is_active === false OR === 0.
// The platform SKU is display-only; products has no SKU column, so product.id is NEVER
// treated as a SKU (real SKU matching is a later schema PR).

function isActive(p) {
  return p != null && p.is_active !== false && p.is_active !== 0;
}

// Match ONE staged line item by exact active-product name.
function matchItem(item, products) {
  const name = (item && item.name != null ? String(item.name) : '').trim();
  if (!name) return { status: 'unmatched', productId: null, matchedName: null };
  const hits = (products || []).filter(
    (p) => isActive(p) && String(p.name == null ? '' : p.name).trim() === name,
  );
  if (hits.length === 1) return { status: 'matched', productId: hits[0].id, matchedName: hits[0].name };
  if (hits.length > 1) return { status: 'ambiguous', productId: null, matchedName: null };
  return { status: 'unmatched', productId: null, matchedName: null };
}

// Aggregate an order's line matches into an order-level status.
function matchOrderItems(items, products) {
  const results = (items || []).map((i) => matchItem(i, products));
  if (results.length === 0) return { items: results, orderStatus: 'empty' };
  if (results.some((r) => r.status === 'ambiguous')) return { items: results, orderStatus: 'ambiguous' };
  const matched = results.filter((r) => r.status === 'matched').length;
  if (matched === results.length) return { items: results, orderStatus: 'matched' };
  if (matched === 0) return { items: results, orderStatus: 'unmatched' };
  return { items: results, orderStatus: 'partial' };
}

module.exports = { matchItem, matchOrderItems };
