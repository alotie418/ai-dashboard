// Conservative, READ-ONLY product matching for staged e-commerce order preview (PR-EC4).
//
// Rules (per the EC4 scope — name-only; NO SKU matching):
//   a. exact, UNIQUE match against an ACTIVE product.name  → 'matched' (productId)
//   b. exact name matches MORE THAN ONE active product     → 'ambiguous'
//   c. no exact active-name match                          → 'unmatched' (description-only)
//
// The platform SKU is DISPLAY-ONLY here. `products` has no SKU column, so we do NOT
// treat product.id as a SKU — real SKU matching is deferred to a later schema PR.
// This is a PURE function: it computes preview state only. Nothing is persisted, no
// product selection is offered, and it never writes to the ledger.

export type ItemMatchStatus = 'matched' | 'ambiguous' | 'unmatched';
export type OrderMatchStatus = 'matched' | 'partial' | 'unmatched' | 'ambiguous' | 'empty';

export interface MatchProduct {
  id: string;
  name: string;
  is_active?: boolean;
}

export interface StagedItemLike {
  sku?: string | null;   // platform SKU — display only, NOT used for matching
  name?: string | null;
  quantity?: number | null;
}

export interface ItemMatchResult {
  status: ItemMatchStatus;
  productId: string | null;   // set only when 'matched'
  matchedName: string | null;
}

// Match ONE staged line item by exact active-product name.
export function matchItem(item: StagedItemLike, products: MatchProduct[]): ItemMatchResult {
  const name = (item && item.name != null ? String(item.name) : '').trim();
  if (!name) return { status: 'unmatched', productId: null, matchedName: null };
  const hits = (products || []).filter(
    (p) => p && p.is_active !== false && String(p.name == null ? '' : p.name).trim() === name,
  );
  if (hits.length === 1) return { status: 'matched', productId: hits[0].id, matchedName: hits[0].name };
  if (hits.length > 1) return { status: 'ambiguous', productId: null, matchedName: null };
  return { status: 'unmatched', productId: null, matchedName: null };
}

// Aggregate an order's line matches into an order-level status.
export function matchOrderItems(
  items: StagedItemLike[],
  products: MatchProduct[],
): { items: ItemMatchResult[]; orderStatus: OrderMatchStatus } {
  const results = (items || []).map((i) => matchItem(i, products));
  if (results.length === 0) return { items: results, orderStatus: 'empty' };
  if (results.some((r) => r.status === 'ambiguous')) return { items: results, orderStatus: 'ambiguous' };
  const matched = results.filter((r) => r.status === 'matched').length;
  if (matched === results.length) return { items: results, orderStatus: 'matched' };
  if (matched === 0) return { items: results, orderStatus: 'unmatched' };
  return { items: results, orderStatus: 'partial' };
}
