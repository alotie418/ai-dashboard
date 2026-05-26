// Sales CRUD — 从 worker/src/index.js 第 1139-1214 行迁移
const { getDb } = require('../db');

function safeString(v, maxLen = 255) {
  if (v == null) return '';
  const s = String(v).slice(0, maxLen);
  return s;
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

  db.prepare(`
    INSERT INTO sales (id, date, customer, tons, pricePerTon, totalAmount, amountWithoutTax, taxAmount, taxRate, shippingCost, invoiceNumber, invoiceStatus)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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

  const info = db.prepare(`
    UPDATE sales SET date=?, customer=?, tons=?, pricePerTon=?, totalAmount=?,
      amountWithoutTax=?, taxAmount=?, taxRate=?, shippingCost=?, invoiceNumber=?, invoiceStatus=?
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
