// Purchases CRUD — 从 worker/src/index.js 第 1063-1138 行迁移
const { getDb } = require('../db');

function safeString(v, maxLen = 255) {
  if (v == null) return '';
  return String(v).slice(0, maxLen);
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

  db.prepare(`
    INSERT INTO purchases (id, date, supplier, tons, pricePerTon, totalAmount, amountWithoutTax, taxAmount, taxRate, invoiceNumber, invoiceStatus)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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

  const info = db.prepare(`
    UPDATE purchases SET date=?, supplier=?, tons=?, pricePerTon=?, totalAmount=?,
      amountWithoutTax=?, taxAmount=?, taxRate=?, invoiceNumber=?, invoiceStatus=?
    WHERE id=?
  `).run(
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
    id,
  );
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
