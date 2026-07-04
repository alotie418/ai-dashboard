// In-memory DEMO provider — ZERO network. Used ONLY in demo mode (see electron/db/index.js
// isDemoMode) to exercise the full connect → pull → preview → commit → unlock flow with sample
// data, without any real Shopify / WooCommerce store.
//
// Hard properties (constraint compliance):
//   - NEVER calls fetch; reads no real credentials; never touches safeStorage.
//   - Reuses the REAL woocommerce.normalizeOrder, so staged rows are shaped exactly like a real
//     WooCommerce pull (same fields, same PII minimisation).
//   - Presents as platform 'woocommerce' so the UNCHANGED commit.js STATUS_MAP maps its order
//     statuses — the committable demo orders stay committable without touching commit.js.
//   - Injected via opts.providers (seed + demo-mode IPC handlers); NEVER registered in the
//     global PROVIDERS registry, so normal (non-demo) mode is completely unaffected.

const woocommerce = require('./woocommerce');

const DEMO_STORE_CURRENCY = 'EUR';

// Raw-WooCommerce-shaped sample orders (line_items.total = post-discount net; total_tax on it).
// Each committable order reconciles: Σ(net+tax) + shipping + shipping-tax === total.
const raw = (o) => ({ shipping_lines: [], fee_lines: [], refunds: [], customer_id: 1, ...o });
const line = (name, qty, net, tax) => ({ name, sku: null, quantity: qty, subtotal: net.toFixed(2), total: net.toFixed(2), total_tax: tax.toFixed(2) });
const tax10 = (net) => ({ rate_code: 'VAT', rate_percent: 10, tax_total: (net * 0.1).toFixed(2) });

// 9 sample orders → the demo scenarios the UI showcases:
//  1001 committable → paid (with shipping, shows the "shipping not posted" difference)
//  1002 committable → unpaid (pending)
//  1003 committable → paid (completed)
//  1004 committable, description-only (product name has no match)
//  1005 ambiguous product ("Dup Item" matches two active products)
//  1006 has refunds  → commit rejected
//  1007 currency mismatch (USD vs store EUR) → commit rejected
//  1008 committable → seed commits it (stays "committed", read-only)
//  1009 committable → seed commits it, then deletes the sale → orphan (unlock & re-commit demo)
const D = {
  1001: raw({ id: 1001, number: '1001', status: 'processing', date_created_gmt: '2026-06-01T10:00:00', date_modified_gmt: '2026-06-01T10:00:00', currency: 'EUR',
    total: '115.00', total_tax: '10.00', shipping_total: '5.00',
    line_items: [line('Demo Widget', 2, 100, 10)], shipping_lines: [{ method_title: 'Standard', total: '5.00' }], tax_lines: [tax10(100)] }),
  1002: raw({ id: 1002, number: '1002', status: 'pending', date_created_gmt: '2026-06-02T10:00:00', date_modified_gmt: '2026-06-02T10:00:00', currency: 'EUR',
    total: '88.00', total_tax: '8.00', shipping_total: '0.00',
    line_items: [line('Demo Widget', 1, 50, 5), line('Demo Gadget', 1, 30, 3)], tax_lines: [tax10(80)] }),
  1003: raw({ id: 1003, number: '1003', status: 'completed', date_created_gmt: '2026-06-03T10:00:00', date_modified_gmt: '2026-06-03T10:00:00', currency: 'EUR',
    total: '99.00', total_tax: '9.00', shipping_total: '0.00',
    line_items: [line('Demo Gadget', 3, 90, 9)], tax_lines: [tax10(90)] }),
  1004: raw({ id: 1004, number: '1004', status: 'processing', date_created_gmt: '2026-06-04T10:00:00', date_modified_gmt: '2026-06-04T10:00:00', currency: 'EUR',
    total: '44.00', total_tax: '4.00', shipping_total: '0.00',
    line_items: [line('Mystery Box', 1, 40, 4)], tax_lines: [tax10(40)] }),
  1005: raw({ id: 1005, number: '1005', status: 'processing', date_created_gmt: '2026-06-05T10:00:00', date_modified_gmt: '2026-06-05T10:00:00', currency: 'EUR',
    total: '22.00', total_tax: '2.00', shipping_total: '0.00',
    line_items: [line('Dup Item', 1, 20, 2)], tax_lines: [tax10(20)] }),
  1006: raw({ id: 1006, number: '1006', status: 'processing', date_created_gmt: '2026-06-06T10:00:00', date_modified_gmt: '2026-06-06T10:00:00', currency: 'EUR',
    total: '55.00', total_tax: '5.00', shipping_total: '0.00',
    line_items: [line('Demo Widget', 1, 50, 5)], tax_lines: [tax10(50)], refunds: [{ id: 1, total: '-10.00' }] }),
  1007: raw({ id: 1007, number: '1007', status: 'processing', date_created_gmt: '2026-06-07T10:00:00', date_modified_gmt: '2026-06-07T10:00:00', currency: 'USD',
    total: '55.00', total_tax: '5.00', shipping_total: '0.00',
    line_items: [line('Demo Widget', 1, 50, 5)], tax_lines: [tax10(50)] }),
  1008: raw({ id: 1008, number: '1008', status: 'processing', date_created_gmt: '2026-06-08T10:00:00', date_modified_gmt: '2026-06-08T10:00:00', currency: 'EUR',
    total: '55.00', total_tax: '5.00', shipping_total: '0.00',
    line_items: [line('Demo Widget', 1, 50, 5)], tax_lines: [tax10(50)] }),
  1009: raw({ id: 1009, number: '1009', status: 'completed', date_created_gmt: '2026-06-09T10:00:00', date_modified_gmt: '2026-06-09T10:00:00', currency: 'EUR',
    total: '33.00', total_tax: '3.00', shipping_total: '0.00',
    line_items: [line('Demo Gadget', 1, 30, 3)], tax_lines: [tax10(30)] }),
};
const PAGE1 = [D[1001], D[1002], D[1003], D[1004], D[1005]];
const PAGE2 = [D[1006], D[1007], D[1008], D[1009]];

const demoProvider = {
  meta: { id: 'woocommerce', name: 'WooCommerce（演示）', transport: 'rest', authMode: 'key_secret', status: 'available' },
  // always OK — pure in-memory, never hits the network
  testConnection: async () => ({ ok: true, storeInfo: { name: 'demo-store.local', domain: 'demo-store.local', currency: null } }),
  // two pages of sample orders (page-based cursor, mirrors woocommerce.pullOrdersPage contract)
  async pullOrdersPage(_creds, { cursor } = {}) {
    const page = Number.isFinite(cursor) && cursor > 1 ? 2 : 1;
    return page === 1
      ? { rawOrders: PAGE1, hasNextPage: true, nextCursor: 2 }
      : { rawOrders: PAGE2, hasNextPage: false, nextCursor: null };
  },
  normalizeOrder: woocommerce.normalizeOrder,   // REAL normalization (identical to a live pull)
};

// Registry override for demo mode: both real platform ids resolve to the demo provider, so a
// demo connection (seeded as 'woocommerce') pulls/tests through it. Injected, never registered.
function demoProviders() {
  return { shopify: demoProvider, woocommerce: demoProvider };
}

module.exports = { demoProvider, demoProviders, DEMO_STORE_CURRENCY };
