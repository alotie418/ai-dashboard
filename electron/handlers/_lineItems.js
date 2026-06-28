// Shared write-side helpers for the purchases / sales multi-line items path (P2).
//
// The header tables (purchases / sales) stay the source of truth for ALL money the
// rest of the app reads — reports, dashboard, AR/AP and cashflow read the header
// columns (totalAmount / amountWithoutTax / taxAmount), never the line items. So the
// ONLY contract this layer enforces is: when a record carries items[], the header
// money columns equal Σ items. Read paths are untouched (inventory line-item reads are
// a later phase). These helpers are pure DB-write support and assume foreign_keys = ON.

const round2 = (n) => Math.round((Number(n) || 0) * 100) / 100;

// Coerce a numeric line field. Absent / null → 0. Present-but-not-finite → throw: a bad
// row must fail the whole transaction, never silently coerce garbage to 0.
function numField(v, label, i) {
  if (v == null) return 0;
  const n = Number(v);
  if (!Number.isFinite(n)) throw new Error(`item[${i}].${label} must be a number`);
  return n;
}

function str(v, maxLen = 255) {
  if (v == null) return null;
  return String(v).slice(0, maxLen);
}

// Validate + normalize an items[] payload into DB-ready rows. Throws on:
//   • not an array, or an empty array  — an empty multi-line document is illegal input
//     (callers must never persist a header with zero items);
//   • a line that is not a plain object;
//   • a non-finite numeric field;
//   • a negative quantity (mirrors the header's non-negative invariant).
// Pure (no DB) so callers may validate before opening a transaction; it is invoked
// INSIDE the transaction here so any throw rolls the write back as well.
function normalizeItems(items) {
  if (!Array.isArray(items) || items.length === 0) {
    throw new Error('items must be a non-empty array');
  }
  return items.map((it, i) => {
    if (!it || typeof it !== 'object' || Array.isArray(it)) {
      throw new Error(`item[${i}] must be an object`);
    }
    const quantity = numField(it.quantity, 'quantity', i);
    if (quantity < 0) throw new Error(`item[${i}].quantity must be non-negative`);
    return {
      line_no: Number.isFinite(Number(it.line_no)) ? Number(it.line_no) : i,
      product_id: it.product_id != null ? String(it.product_id) : null,
      description: str(it.description),
      unit_snapshot: str(it.unit_snapshot, 50),
      quantity,
      unit_price: numField(it.unit_price, 'unit_price', i),
      amount_net: round2(numField(it.amount_net, 'amount_net', i)),
      tax_rate: it.tax_rate == null ? null : numField(it.tax_rate, 'tax_rate', i),
      tax_amount: round2(numField(it.tax_amount, 'tax_amount', i)),
      amount_gross: round2(numField(it.amount_gross, 'amount_gross', i)),
    };
  });
}

// Sum the header money totals from normalized lines. The server is the authority here —
// the header amount columns ALWAYS equal Σ items, so report/AR-AP/cashflow reads of the
// header stay correct without those modules knowing about line items.
function sumHeaderTotals(rows) {
  return {
    amountWithoutTax: round2(rows.reduce((s, r) => s + r.amount_net, 0)),
    taxAmount: round2(rows.reduce((s, r) => s + r.tax_amount, 0)),
    totalAmount: round2(rows.reduce((s, r) => s + r.amount_gross, 0)),
  };
}

// Replace ALL child rows for a header (delete-then-insert). MUST be called inside a
// db.transaction so a failure rolls back the delete — a header is never left with no or
// half its items. On create the delete is a harmless no-op. table / fkCol come from
// fixed handler literals (no injection surface).
function replaceItems(db, table, fkCol, parentId, rows) {
  db.prepare(`DELETE FROM ${table} WHERE ${fkCol} = ?`).run(parentId);
  const stmt = db.prepare(
    `INSERT INTO ${table} (${fkCol}, line_no, product_id, description, unit_snapshot, quantity, unit_price, amount_net, tax_rate, tax_amount, amount_gross)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
  );
  for (const r of rows) {
    stmt.run(parentId, r.line_no, r.product_id, r.description, r.unit_snapshot, r.quantity, r.unit_price, r.amount_net, r.tax_rate, r.tax_amount, r.amount_gross);
  }
}

module.exports = { normalizeItems, sumHeaderTotals, replaceItems, round2 };
