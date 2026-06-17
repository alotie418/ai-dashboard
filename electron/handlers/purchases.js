// Purchases CRUD
const { getDb } = require('../db');

function safeString(v, maxLen = 255) {
  if (v == null) return '';
  return String(v).slice(0, maxLen);
}

// Snapshot the product's name/unit at record time (Phase 2). Display-only; the
// quantity (tons) and all money/tax math are unchanged. Unassigned → all null.
function productSnapshot(db, productId) {
  const pid = productId || null;
  if (!pid) return { id: null, name: null, unit: null };
  const p = db.prepare('SELECT name, unit FROM products WHERE id = ?').get(pid);
  return { id: pid, name: p ? p.name : null, unit: p ? p.unit : null };
}

function validatePurchase(data) {
  const errors = [];
  if (!data.id) errors.push('id required');
  if (!data.date) errors.push('date required');
  if (typeof data.tons !== 'number' || data.tons < 0) errors.push('tons must be non-negative number');
  return errors;
}

async function list() {
  const db = getDb();
  return db.prepare('SELECT * FROM purchases ORDER BY date DESC').all();
}

async function create({ body }) {
  const db = getDb();
  const data = body || {};
  const errors = validatePurchase(data);
  if (errors.length > 0) throw new Error(errors.join('; '));

  const snap = productSnapshot(db, data.product_id);
  db.prepare(`
    INSERT INTO purchases (id, date, supplier, tons, pricePerTon, totalAmount, amountWithoutTax, taxAmount, taxRate, invoiceNumber, invoiceStatus, product_id, product_name_snapshot, unit_snapshot, due_date)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `).run(
    data.id,
    data.date,
    safeString(data.supplier),
    Number(data.tons) || 0,
    Number(data.pricePerTon) || 0,
    Number(data.totalAmount) || 0,
    Number(data.amountWithoutTax) || 0,
    Number(data.taxAmount) || 0,
    Number(data.taxRate) || 13,
    safeString(data.invoiceNumber, 100),
    safeString(data.invoiceStatus, 20),
    snap.id,
    snap.name,
    snap.unit,
    data.due_date || null, // 未传/空 → null（与 list SELECT * 一致；payment 字段不在此处理）
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

  const errors = validatePurchase(data);
  if (errors.length > 0) throw new Error(errors.join('; '));

  // Re-snapshot only when the linked product changes; otherwise preserve history.
  const existing = db.prepare('SELECT product_id, product_name_snapshot, unit_snapshot FROM purchases WHERE id = ?').get(id);
  if (!existing) throw new Error('Purchase not found');
  let pid = existing.product_id || null, pname = existing.product_name_snapshot ?? null, punit = existing.unit_snapshot ?? null;
  if (data.product_id !== undefined && (data.product_id || null) !== (existing.product_id || null)) {
    const snap = productSnapshot(db, data.product_id);
    pid = snap.id; pname = snap.name; punit = snap.unit;
  }

  // due_date 仅在 body 显式提供时纳入 SET（部分更新）；未传则保留库中已有 due_date，不清空。
  const setDueDate = data.due_date !== undefined;
  const args = [
    data.date,
    safeString(data.supplier),
    data.tons,
    data.pricePerTon,
    data.totalAmount,
    data.amountWithoutTax,
    data.taxAmount,
    data.taxRate,
    safeString(data.invoiceNumber, 100),
    safeString(data.invoiceStatus, 20),
    pid,
    pname,
    punit,
  ];
  if (setDueDate) args.push(data.due_date || null);
  args.push(id);
  const info = db.prepare(`
    UPDATE purchases SET date=?, supplier=?, tons=?, pricePerTon=?, totalAmount=?,
      amountWithoutTax=?, taxAmount=?, taxRate=?, invoiceNumber=?, invoiceStatus=?,
      product_id=?, product_name_snapshot=?, unit_snapshot=?${setDueDate ? ', due_date=?' : ''}
    WHERE id=?
  `).run(...args);
  if (info.changes === 0) throw new Error('Purchase not found');
  return { success: true };
}

async function remove({ params }) {
  const db = getDb();
  const id = params.id;
  if (!id) throw new Error('Invalid ID');
  db.prepare('DELETE FROM purchases WHERE id = ?').run(id);
  return { success: true };
}

module.exports = { list, create, update, remove };
