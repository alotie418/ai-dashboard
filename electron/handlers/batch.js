// Batch import
const { getDb } = require('../db');

function safeString(v, maxLen = 255) {
  if (v == null) return '';
  return String(v).slice(0, maxLen);
}

function validateSale(d) {
  const e = [];
  if (!d.id) e.push('id required');
  if (!d.date) e.push('date required');
  if (typeof d.tons !== 'number' || d.tons < 0) e.push('tons must be non-negative number');
  return e;
}

function validatePurchase(d) {
  const e = [];
  if (!d.id) e.push('id required');
  if (!d.date) e.push('date required');
  if (typeof d.tons !== 'number' || d.tons < 0) e.push('tons must be non-negative number');
  return e;
}

async function batchSales({ body }) {
  const db = getDb();
  const records = Array.isArray(body?.records) ? body.records : [];
  if (records.length === 0) throw new Error('records array is required and must not be empty');
  if (records.length > 500) throw new Error('Maximum 500 records per batch');

  const result = { success: 0, failed: 0, errors: [] };
  const validRows = [];

  for (let i = 0; i < records.length; i++) {
    const data = records[i];
    data.tons = Number(data.tons) || 0;
    data.pricePerTon = Number(data.pricePerTon) || 0;
    data.totalAmount = Number(data.totalAmount) || 0;
    data.amountWithoutTax = Number(data.amountWithoutTax) || 0;
    data.taxAmount = Number(data.taxAmount) || 0;
    data.taxRate = Number(data.taxRate) || 13;
    data.shippingCost = Number(data.shippingCost) || 0;
    if (!data.id) data.id = `sale-batch-${Date.now()}-${i}`;

    const errors = validateSale(data);
    if (errors.length > 0) {
      result.failed++;
      result.errors.push({ row: i + 1, errors });
      continue;
    }
    validRows.push(data);
  }

  if (validRows.length > 0) {
    const stmt = db.prepare(`INSERT INTO sales (id, date, customer, tons, pricePerTon, totalAmount, amountWithoutTax, taxAmount, taxRate, shippingCost, invoiceNumber, invoiceStatus, payment_status, paid_amount, due_date)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`);
    const tx = db.transaction((rows) => {
      for (const d of rows) {
        stmt.run(d.id, d.date, safeString(d.customer), d.tons, d.pricePerTon, d.totalAmount,
          d.amountWithoutTax, d.taxAmount, d.taxRate, d.shippingCost,
          safeString(d.invoiceNumber || '', 100), safeString(d.invoiceStatus || '待开', 20),
          d.payment_status || 'paid', d.paid_amount ?? d.totalAmount, d.due_date || null);
      }
    });
    tx(validRows);
    result.success = validRows.length;
  }
  return result;
}

async function batchPurchases({ body }) {
  const db = getDb();
  const records = Array.isArray(body?.records) ? body.records : [];
  if (records.length === 0) throw new Error('records array is required and must not be empty');
  if (records.length > 500) throw new Error('Maximum 500 records per batch');

  const result = { success: 0, failed: 0, errors: [] };
  const validRows = [];

  for (let i = 0; i < records.length; i++) {
    const data = records[i];
    data.tons = Number(data.tons) || 0;
    data.pricePerTon = Number(data.pricePerTon) || 0;
    data.totalAmount = Number(data.totalAmount) || 0;
    data.amountWithoutTax = Number(data.amountWithoutTax) || 0;
    data.taxAmount = Number(data.taxAmount) || 0;
    data.taxRate = Number(data.taxRate) || 13;
    if (!data.id) data.id = `purchase-batch-${Date.now()}-${i}`;

    const errors = validatePurchase(data);
    if (errors.length > 0) {
      result.failed++;
      result.errors.push({ row: i + 1, errors });
      continue;
    }
    validRows.push(data);
  }

  if (validRows.length > 0) {
    const stmt = db.prepare(`INSERT INTO purchases (id, date, supplier, tons, pricePerTon, totalAmount, amountWithoutTax, taxAmount, taxRate, invoiceNumber, invoiceStatus, payment_status, paid_amount, due_date)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`);
    const tx = db.transaction((rows) => {
      for (const d of rows) {
        stmt.run(d.id, d.date, safeString(d.supplier), d.tons, d.pricePerTon, d.totalAmount,
          d.amountWithoutTax, d.taxAmount, d.taxRate,
          safeString(d.invoiceNumber || '', 100), safeString(d.invoiceStatus || '已收', 20),
          d.payment_status || 'paid', d.paid_amount ?? d.totalAmount, d.due_date || null);
      }
    });
    tx(validRows);
    result.success = validRows.length;
  }
  return result;
}

module.exports = { batchSales, batchPurchases };
