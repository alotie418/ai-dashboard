// Sales CRUD — 从 worker/src/index.js 第 1139-1214 行迁移
const { getDb } = require('../db');

function safeString(v, maxLen = 255) {
  if (v == null) return '';
  const s = String(v).slice(0, maxLen);
  return s;
}

// Snapshot the product's name/unit at record time (Phase 2). Display-only; the
// quantity (tons) and all money/tax math are unchanged. Unassigned → all null.
function productSnapshot(db, productId) {
  const pid = productId || null;
  if (!pid) return { id: null, name: null, unit: null };
  const p = db.prepare('SELECT name, unit FROM products WHERE id = ?').get(pid);
  return { id: pid, name: p ? p.name : null, unit: p ? p.unit : null };
}

function validateSale(data) {
  const errors = [];
  if (!data.id) errors.push('id required');
  if (!data.date) errors.push('date required');
  if (typeof data.tons !== 'number' || data.tons < 0) errors.push('tons must be non-negative number');
  return errors;
}

async function list() {
  const db = getDb();
  return db.prepare('SELECT * FROM sales ORDER BY date DESC').all();
}

async function create({ body }) {
  const db = getDb();
  const data = body || {};
  const errors = validateSale(data);
  if (errors.length > 0) throw new Error(errors.join('; '));

  const snap = productSnapshot(db, data.product_id);
  db.prepare(`
    INSERT INTO sales (id, date, customer, tons, pricePerTon, totalAmount, amountWithoutTax, taxAmount, taxRate, shippingCost, invoiceNumber, invoiceStatus, product_id, product_name_snapshot, unit_snapshot)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `).run(
    data.id,
    data.date,
    safeString(data.customer),
    Number(data.tons) || 0,
    Number(data.pricePerTon) || 0,
    Number(data.totalAmount) || 0,
    Number(data.amountWithoutTax) || 0,
    Number(data.taxAmount) || 0,
    Number(data.taxRate) || 13,
    Number(data.shippingCost) || 0,
    safeString(data.invoiceNumber, 100),
    safeString(data.invoiceStatus, 20),
    snap.id,
    snap.name,
    snap.unit,
  );
  return { success: true, id: data.id };
}

async function update({ params, body }) {
  const db = getDb();
  const id = params.id;
  if (!id) throw new Error('Invalid ID');
  const data = body || {};
  data.id = id;
  data.tons = Number(data.tons) || 0;
  data.pricePerTon = Number(data.pricePerTon) || 0;
  data.totalAmount = Number(data.totalAmount) || 0;
  data.amountWithoutTax = Number(data.amountWithoutTax) || 0;
  data.taxAmount = Number(data.taxAmount) || 0;
  data.taxRate = Number(data.taxRate) || 13;
  data.shippingCost = Number(data.shippingCost) || 0;

  const errors = validateSale(data);
  if (errors.length > 0) throw new Error(errors.join('; '));

  // Re-snapshot only when the linked product changes; otherwise preserve history.
  const existing = db.prepare('SELECT product_id, product_name_snapshot, unit_snapshot FROM sales WHERE id = ?').get(id);
  if (!existing) throw new Error('Sale not found');
  let pid = existing.product_id || null, pname = existing.product_name_snapshot ?? null, punit = existing.unit_snapshot ?? null;
  if (data.product_id !== undefined && (data.product_id || null) !== (existing.product_id || null)) {
    const snap = productSnapshot(db, data.product_id);
    pid = snap.id; pname = snap.name; punit = snap.unit;
  }

  const info = db.prepare(`
    UPDATE sales SET date=?, customer=?, tons=?, pricePerTon=?, totalAmount=?,
      amountWithoutTax=?, taxAmount=?, taxRate=?, shippingCost=?, invoiceNumber=?, invoiceStatus=?,
      product_id=?, product_name_snapshot=?, unit_snapshot=?
    WHERE id=?
  `).run(
    data.date,
    safeString(data.customer),
    data.tons,
    data.pricePerTon,
    data.totalAmount,
    data.amountWithoutTax,
    data.taxAmount,
    data.taxRate,
    data.shippingCost,
    safeString(data.invoiceNumber, 100),
    safeString(data.invoiceStatus, 20),
    pid,
    pname,
    punit,
    id,
  );
  if (info.changes === 0) throw new Error('Sale not found');
  return { success: true };
}

async function remove({ params }) {
  const db = getDb();
  const id = params.id;
  if (!id) throw new Error('Invalid ID');
  db.prepare('DELETE FROM sales WHERE id = ?').run(id);
  return { success: true };
}

module.exports = { list, create, update, remove };
