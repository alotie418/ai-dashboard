// E-commerce staged-order COMMIT → sales / sales_items (PR-EC5a) — the FIRST code path
// that posts pulled platform orders into the ledger. Backend only; the UI is PR-EC5b.
//
// HARD BOUNDARIES (do NOT cross):
//   - writes ONLY sales + sales_items (+ the staged row's status backfill). NEVER touches
//     purchases / inventory / reports / transactions / categories, and creates NO AR/AP
//     entity — receivables pages DERIVE from sales.payment_status (existing read path).
//   - records the PLATFORM's reported amounts (per-line net / tax / gross) verbatim; it
//     computes NO tax policy of its own. Header money = Σ items via _lineItems
//     .sumHeaderTotals — the same math every manual / CSV multi-line sale uses, so the
//     app-wide header=Σitems invariant holds by construction.
//   - shipping / fees / refunds are NEVER posted (decisions D1/D3): shippingCost stays 0
//     (the platform's customer-paid shipping is NOT the header's seller-cost field);
//     orders carrying any refund are rejected outright (refund policy is EC6 + accountant).
//   - header taxRate: single uniform non-null line rate → that rate; otherwise NULL —
//     never the legacy ||13 fallback (decision D8; no invented tax rate).
//   - whole-order reconciliation: Σ line gross + shipping (+ shipping tax) must equal the
//     platform grand total, else 'total_mismatch' — tax-inclusive-price stores (Shopify
//     taxesIncluded) and unfetched charges are REJECTED, never posted as inflated revenue.
//   - PII: sales.customer = "<connection label> <order number>" — never buyer data
//     (normalized_json is already PII-minimised by the pull phase).
//
// Two-pass, all-or-nothing (mirrors handlers/batch.js):
//   Pass 1 validates EVERY selected staged order with NO db write; ANY failure returns
//   per-order machine-readable reason codes (EC5b maps them to i18n) and writes NOTHING.
//   Pass 2 writes all orders inside ONE transaction; any throw — including the partial
//   unique index on sales(ecommerce_connection_id, external_order_id) — rolls the ENTIRE
//   batch back. Never partial success.
//
// Idempotency layers: stage_status must be 'staged' (committed → rejected in Pass 1)
// → deterministic sale id 'sale-ec-<staged.id>' (PK collision) → partial unique index on
// sales(ecommerce_connection_id, external_order_id) (DB-level last line of defence).
// pull.js never overwrites a committed staged row, closing the loop. Matching is
// recomputed HERE against the live products table (matchItems.js) — the renderer's
// preview result is display-only and never trusted.

const { getDb } = require('../db');
const { normalizeItems, sumHeaderTotals, replaceItems, round2 } = require('../handlers/_lineItems');
const { matchOrderItems } = require('./matchItems');

const MAX_COMMIT = 100;   // per-call cap (the UI passes explicit selections)
const LINE_EPS = 0.011;   // per-line |net + tax − gross| tolerance (cent rounding)
const ORDER_EPS = 0.02;   // |Σ lineNet − platform subtotal| tolerance

// D2 — commit-eligible order statuses → payment_status mapping. Anything NOT listed is
// REJECTED ('status_not_committable'): partially-paid needs the platform's transactions
// API to know paid_amount (never guess), refunded / cancelled / voided need EC6's refund
// policy. Values per official docs (Shopify displayFinancialStatus enum; WooCommerce
// order statuses) — official-docs-confirm on each platform's next API-version bump.
const STATUS_MAP = {
  shopify: { PAID: 'paid', PENDING: 'unpaid', AUTHORIZED: 'unpaid' },
  woocommerce: { completed: 'paid', processing: 'paid', pending: 'unpaid', 'on-hold': 'unpaid' },
};

function paymentKind(platform, orderStatus) {
  const map = STATUS_MAP[platform];
  if (!map || orderStatus == null || orderStatus === '') return null;
  const key = platform === 'shopify' ? String(orderStatus).toUpperCase() : String(orderStatus).toLowerCase();
  // own-property check: a hostile/corrupt status like 'constructor' must not walk the
  // prototype chain into a truthy non-mapping value
  return Object.prototype.hasOwnProperty.call(map, key) ? map[key] : null;
}

// Validate ONE staged row for commit. Returns { reasons: [], prepared } — reasons are
// STABLE machine codes (the EC5b UI localises them); `detail` optionally carries the
// ambiguous product names. Read-only; never writes. Codes: not_found / already_committed /
// not_staged / bad_normalized / duplicate_external_order / status_not_committable /
// has_refunds / store_currency_missing / currency_missing / currency_mismatch /
// date_missing / empty_items / quantity_invalid / amount_missing / amount_inconsistent /
// totals_missing / total_mismatch / ambiguous_product (+ write_failed from Pass 2).
function validateOne(db, row, conn, products) {
  if (!row || row.connection_id !== conn.id) return { reasons: ['not_found'] };
  if (row.stage_status === 'committed') return { reasons: ['already_committed'] };
  if (row.stage_status !== 'staged') return { reasons: ['not_staged'] };

  let n = null;
  try { n = row.normalized_json ? JSON.parse(row.normalized_json) : null; } catch { n = null; }
  if (!n || !row.external_order_id) return { reasons: ['bad_normalized'] };

  // Pass-1 duplicate precheck — a readable per-order reason instead of an opaque
  // whole-batch write_failed. The DB backstops (deterministic PK + partial unique index)
  // stay in place as the last defence against anything this read misses.
  if (db.prepare('SELECT 1 FROM sales WHERE id = ?').get(`sale-ec-${row.id}`)
    || db.prepare('SELECT 1 FROM sales WHERE ecommerce_connection_id = ? AND external_order_id = ?').get(conn.id, row.external_order_id)) {
    return { reasons: ['duplicate_external_order'] };
  }

  const reasons = [];
  let detail;

  // status whitelist (D2)
  const kind = paymentKind(row.platform, n.orderStatus);
  if (!kind) reasons.push('status_not_committable');

  // refunds blocked (D3) — refund posting policy is EC6 + accountant
  if (Array.isArray(n.refunds) && n.refunds.length > 0) reasons.push('has_refunds');

  // currency guards: never guess a currency (sales has no currency column — MVP is
  // single-store-currency; the user must set store_currency on the connection first)
  const store = (conn.store_currency || '').trim().toUpperCase();
  const cur = (n.currency || '').trim().toUpperCase();
  if (!store) reasons.push('store_currency_missing');
  if (!cur) reasons.push('currency_missing');
  else if (store && cur !== store) reasons.push('currency_mismatch');

  // order date = platform createdAt date part (UTC approximation, documented)
  const date = String(n.createdAt || '').slice(0, 10);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) reasons.push('date_missing');

  // items + money guards — the platform's own numbers must be internally consistent,
  // otherwise the order is data-anomalous and must not reach the ledger
  const items = Array.isArray(n.items) ? n.items : [];
  if (items.length === 0) reasons.push('empty_items');
  let sumNet = 0, sumTax = 0, sumGross = 0;
  let qtyBad = false, moneyBad = false, inconsistent = false;
  for (const it of items) {
    const qty = it ? it.quantity : null;
    if (!Number.isFinite(qty) || qty <= 0) { qtyBad = true; continue; }
    const net = it.lineNet;
    const tax = it.lineTax == null ? 0 : it.lineTax;
    const gross = it.lineGross;
    if (!Number.isFinite(net) || !Number.isFinite(tax) || !Number.isFinite(gross)) { moneyBad = true; continue; }
    if (Math.abs(net + tax - gross) > LINE_EPS) inconsistent = true;
    sumNet += net; sumTax += tax; sumGross += gross;
  }
  if (qtyBad) reasons.push('quantity_invalid');
  if (moneyBad) reasons.push('amount_missing');
  const t = n.totals || {};
  if (!Number.isFinite(t.grandTotalGross) || !Number.isFinite(t.subtotalNet)) {
    reasons.push('totals_missing');
  } else if (!qtyBad && !moneyBad && items.length > 0) {
    // catches Shopify order-level discounts not allocated down to the lines —
    // conservative: block instead of inventing an allocation policy. (WooCommerce's
    // adapter computes subtotalNet from the lines, so this check is tautological there.)
    if (Math.abs(round2(sumNet) - round2(t.subtotalNet)) > ORDER_EPS) inconsistent = true;
    // whole-order reconciliation: what we would post (Σ line gross) plus what we
    // deliberately do NOT post (shipping + shipping tax) must equal what the platform
    // says the customer pays. This is the tripwire that keeps TAX-INCLUSIVE price stores
    // (Shopify taxesIncluded — there lineGross = net+tax OVERSTATES the real charge) and
    // any unfetched charge (tips, gift wrap) OUT of the ledger instead of posting
    // inflated revenue. Supporting tax-inclusive stores needs a later provider PR that
    // fetches taxesIncluded; until then such orders are rejected, never mis-posted.
    const shipTotal = Number.isFinite(t.shippingTotal) ? t.shippingTotal : 0;
    const shippingTax = Number.isFinite(t.taxTotal) ? Math.max(0, round2(t.taxTotal - round2(sumTax))) : 0;
    const expectedGrand = round2(round2(sumGross) + shipTotal + shippingTax);
    if (Math.abs(round2(t.grandTotalGross) - expectedGrand) > ORDER_EPS) reasons.push('total_mismatch');
  }
  if (inconsistent) reasons.push('amount_inconsistent');

  // authoritative product matching (never trust the renderer's preview)
  let match = null;
  if (items.length > 0) {
    match = matchOrderItems(items, products);
    if (match.orderStatus === 'ambiguous') {
      reasons.push('ambiguous_product');
      detail = items
        .filter((_, i) => match.items[i].status === 'ambiguous')
        .map((it) => (it && it.name != null ? String(it.name) : ''))
        .filter(Boolean);
    }
  }

  if (reasons.length > 0) return { reasons, detail };

  // build DB-ready line rows; normalizeItems re-validates + rounds (same math as every
  // other multi-line write path)
  let rows, totals;
  try {
    rows = normalizeItems(items.map((it, i) => {
      const m = match.items[i];
      const qty = it.quantity;
      const net = it.lineNet;
      const tax = it.lineTax == null ? 0 : it.lineTax;
      return {
        line_no: i,
        product_id: m.status === 'matched' ? m.productId : null,   // description-only stays NULL
        description: it.name != null && String(it.name).trim() !== '' ? String(it.name) : null,
        unit_snapshot: null,
        quantity: qty,
        unit_price: it.unitPriceNet != null ? it.unitPriceNet : (qty > 0 ? net / qty : 0),
        amount_net: net,
        tax_rate: it.taxRate == null ? null : it.taxRate,
        tax_amount: tax,
        amount_gross: it.lineGross,
      };
    }));
    totals = sumHeaderTotals(rows);
  } catch {
    return { reasons: ['amount_missing'] };
  }

  // D8: uniform non-null line tax rate → header rate; mixed / absent → NULL (never 13)
  const rates = new Set(rows.map((r) => r.tax_rate));
  const headerTaxRate = rates.size === 1 && !rates.has(null) ? rows[0].tax_rate : null;

  const orderNumber = row.order_number || n.orderNumber || null;
  const grand = round2(t.grandTotalGross);
  const difference = round2(grand - totals.totalAmount);
  const shippingNotPosted = Number.isFinite(t.shippingTotal) ? round2(t.shippingTotal) : 0;
  const matchedLines = match.items.filter((m) => m.status === 'matched').length;

  return {
    reasons: [],
    prepared: {
      stagedId: row.id,
      saleId: `sale-ec-${row.id}`,
      date,
      customer: `${conn.label || row.platform} ${orderNumber || row.external_order_id}`.slice(0, 255),
      paymentStatus: kind,                                        // 'paid' | 'unpaid'
      paidAmount: kind === 'paid' ? totals.totalAmount : 0,
      headerTaxRate,
      rows,
      totals,
      externalOrderId: row.external_order_id,
      platform: row.platform,
      // for the commit result (EC5b displays what was / wasn't posted — nothing here is written)
      report: {
        stagedId: row.id,
        saleId: `sale-ec-${row.id}`,
        externalOrderId: row.external_order_id,
        orderNumber,
        grandTotalGross: grand,                                   // platform order total (preview value)
        committedTotalAmount: totals.totalAmount,                 // = header total = Σ items gross
        difference,                                               // grand − committed (informational)
        breakdown: {
          shippingNotPosted,                                      // D1-A: customer-paid shipping, not posted
          otherDifference: round2(difference - shippingNotPosted), // shipping tax / platform adjustments etc.
        },
        lines: { total: rows.length, matched: matchedLines, descriptionOnly: rows.length - matchedLines },
      },
    },
  };
}

// commit({ connectionId, stagedIds }) → { success, failed, committed[], errors[] }
// Synchronous on purpose: better-sqlite3 is sync, so NOTHING can interleave between
// Pass 1 (validate) and Pass 2 (write) — no TOCTOU window inside one call. The
// connection's `enabled` flag is a SYNC switch and deliberately not checked here:
// committing already-staged local data needs no network and no live connection.
function commit({ connectionId, stagedIds } = {}) {
  const db = getDb();
  if (!connectionId) throw new Error('connectionId required');
  const conn = db.prepare('SELECT * FROM ecommerce_connections WHERE id = ?').get(connectionId);
  if (!conn) throw new Error('连接不存在');

  // dedupe defensively — a repeated id in one request must not double-post in Pass 2
  const ids = [...new Set((Array.isArray(stagedIds) ? stagedIds : [])
    .map((v) => Number(v)).filter((v) => Number.isInteger(v)))];
  if (ids.length === 0) throw new Error('stagedIds required');
  if (ids.length > MAX_COMMIT) throw new Error(`Maximum ${MAX_COMMIT} orders per commit`);

  const products = db.prepare('SELECT id, name, is_active FROM products').all();

  // Pass 1 — validate everything, write nothing
  const errors = [];
  const prepared = [];
  for (const sid of ids) {
    const row = db.prepare('SELECT * FROM ecommerce_staged_orders WHERE id = ?').get(sid);
    const v = validateOne(db, row, conn, products);
    if (v.reasons.length > 0) {
      errors.push({
        stagedId: sid,
        orderNumber: row ? row.order_number : null,
        reasons: v.reasons,
        ...(v.detail && v.detail.length ? { detail: v.detail } : {}),
      });
    } else {
      prepared.push(v.prepared);
    }
  }
  // all-or-nothing: any invalid order → the whole selection posts nothing
  if (errors.length > 0) return { success: 0, failed: ids.length, committed: [], errors };

  // Pass 2 — ONE transaction for every order
  const insertSale = db.prepare(`INSERT INTO sales
    (id, date, customer, tons, pricePerTon, totalAmount, amountWithoutTax, taxAmount, taxRate,
     shippingCost, invoiceNumber, invoiceStatus, payment_status, paid_amount, due_date,
     product_id, product_name_snapshot, unit_snapshot,
     external_order_id, platform_source, ecommerce_connection_id)
    VALUES (?, ?, ?, 0, 0, ?, ?, ?, ?, 0, '', '待开', ?, ?, NULL, NULL, NULL, NULL, ?, ?, ?)`);
  const markCommitted = db.prepare(`UPDATE ecommerce_staged_orders
    SET stage_status = 'committed', committed_sale_id = ?, error = NULL, updated_at = datetime('now')
    WHERE id = ? AND stage_status = 'staged'`);

  try {
    db.transaction(() => {
      for (const p of prepared) {
        insertSale.run(
          p.saleId, p.date, p.customer,
          p.totals.totalAmount, p.totals.amountWithoutTax, p.totals.taxAmount, p.headerTaxRate,
          p.paymentStatus, p.paidAmount,
          p.externalOrderId, p.platform, conn.id,
        );
        replaceItems(db, 'sales_items', 'sale_id', p.saleId, p.rows);
        // defence-in-depth: the row was 'staged' in Pass 1 and nothing can interleave,
        // but a 0-change update would mean state drift → abort the whole batch
        const u = markCommitted.run(p.saleId, p.stagedId);
        if (u.changes !== 1) throw new Error(`staged row ${p.stagedId} changed state during commit`);
      }
    })();
  } catch (e) {
    // e.g. PK / partial-unique-index violation → the WHOLE batch rolled back, no partial post
    return {
      success: 0, failed: ids.length, committed: [],
      errors: [{ stagedId: null, orderNumber: null, reasons: ['write_failed'], message: String(e && e.message ? e.message : 'write failed').slice(0, 300) }],
    };
  }

  return { success: prepared.length, failed: 0, committed: prepared.map((p) => p.report), errors: [] };
}

module.exports = { commit, MAX_COMMIT, _validateOne: validateOne, _paymentKind: paymentKind };
