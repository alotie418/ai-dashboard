// Batch import
const { getDb } = require('../db');
const { normalizeItems, sumHeaderTotals, replaceItems } = require('./_lineItems');

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

// P5d-2: a record carrying items[] is a multi-line document — its header money columns are
// summed from the lines and the legacy single-item columns are neutralised (tons=0,
// pricePerTon=0, product_id=NULL via the omitted column), mirroring purchases/sales.createWithItems
// exactly. A record WITHOUT items[] stays a legacy single row (unchanged behaviour). sales
// shippingCost stays a header field and is never part of the items sum.
//
// All-or-nothing (P5d-2): the whole file is validated FIRST with no DB write; if ANY record or
// item is invalid the import is a no-op (success=0, failed=records.length, errors[] returned).
// Otherwise every record — legacy and multi-line alike — is written inside ONE transaction, so a
// later write failure (e.g. a duplicate id) rolls the entire batch back. Never partial success.

async function batchSales({ body }) {
  const db = getDb();
  const records = Array.isArray(body?.records) ? body.records : [];
  if (records.length === 0) throw new Error('records array is required and must not be empty');
  if (records.length > 500) throw new Error('Maximum 500 records per batch');

  const result = { success: 0, failed: 0, errors: [] };

  // Pass 1 — validate every record, NO DB write. A failed record records an error and yields null.
  const prepared = records.map((data, i) => {
    if (!data.id) data.id = `sale-batch-${Date.now()}-${i}`;
    if (data.items != null) {
      const errs = [];
      if (!data.date) errs.push('date required');
      let rows, totals;
      try { rows = normalizeItems(data.items); totals = sumHeaderTotals(rows); }
      catch (e) { errs.push(e.message); }
      if (errs.length > 0) { result.errors.push({ row: i + 1, errors: errs }); return null; }
      return { data, hasItems: true, rows, totals };
    }
    data.tons = Number(data.tons) || 0;
    data.pricePerTon = Number(data.pricePerTon) || 0;
    data.totalAmount = Number(data.totalAmount) || 0;
    data.amountWithoutTax = Number(data.amountWithoutTax) || 0;
    data.taxAmount = Number(data.taxAmount) || 0;
    data.taxRate = Number(data.taxRate) || 13;
    data.shippingCost = Number(data.shippingCost) || 0;
    const errors = validateSale(data);
    if (errors.length > 0) { result.errors.push({ row: i + 1, errors }); return null; }
    return { data, hasItems: false };
  });

  // All-or-nothing: any invalid record → write nothing.
  if (result.errors.length > 0) { result.failed = records.length; return result; }

  const stmt = db.prepare(`INSERT INTO sales (id, date, customer, tons, pricePerTon, totalAmount, amountWithoutTax, taxAmount, taxRate, shippingCost, invoiceNumber, invoiceStatus, payment_status, paid_amount, due_date)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`);
  try {
    db.transaction(() => {
      for (const p of prepared) {
        const d = p.data;
        if (p.hasItems) {
          // multi-line: header neutralised (tons/pricePerTon=0, product_id omitted→NULL), money = Σ items;
          // shippingCost stays header-level, NOT summed into the items.
          stmt.run(d.id, d.date, safeString(d.customer), 0, 0,
            p.totals.totalAmount, p.totals.amountWithoutTax, p.totals.taxAmount, Number(d.taxRate) || 13,
            Number(d.shippingCost) || 0,
            safeString(d.invoiceNumber || '', 100), safeString(d.invoiceStatus || '待开', 20),
            d.payment_status || 'paid', d.paid_amount ?? p.totals.totalAmount, d.due_date || null);
          replaceItems(db, 'sales_items', 'sale_id', d.id, p.rows);
        } else {
          stmt.run(d.id, d.date, safeString(d.customer), d.tons, d.pricePerTon, d.totalAmount,
            d.amountWithoutTax, d.taxAmount, d.taxRate, d.shippingCost,
            safeString(d.invoiceNumber || '', 100), safeString(d.invoiceStatus || '待开', 20),
            d.payment_status || 'paid', d.paid_amount ?? d.totalAmount, d.due_date || null);
        }
      }
    })();
    result.success = records.length;
  } catch (e) {
    // an unexpected write failure (e.g. duplicate id) rolled the WHOLE batch back → no partial write
    result.success = 0;
    result.failed = records.length;
    result.errors.push({ row: 0, errors: [e.message || 'batch write failed'] });
  }
  return result;
}

async function batchPurchases({ body }) {
  const db = getDb();
  const records = Array.isArray(body?.records) ? body.records : [];
  if (records.length === 0) throw new Error('records array is required and must not be empty');
  if (records.length > 500) throw new Error('Maximum 500 records per batch');

  const result = { success: 0, failed: 0, errors: [] };

  // Pass 1 — validate every record, NO DB write.
  const prepared = records.map((data, i) => {
    if (!data.id) data.id = `purchase-batch-${Date.now()}-${i}`;
    if (data.items != null) {
      const errs = [];
      if (!data.date) errs.push('date required');
      let rows, totals;
      try { rows = normalizeItems(data.items); totals = sumHeaderTotals(rows); }
      catch (e) { errs.push(e.message); }
      if (errs.length > 0) { result.errors.push({ row: i + 1, errors: errs }); return null; }
      return { data, hasItems: true, rows, totals };
    }
    data.tons = Number(data.tons) || 0;
    data.pricePerTon = Number(data.pricePerTon) || 0;
    data.totalAmount = Number(data.totalAmount) || 0;
    data.amountWithoutTax = Number(data.amountWithoutTax) || 0;
    data.taxAmount = Number(data.taxAmount) || 0;
    data.taxRate = Number(data.taxRate) || 13;
    const errors = validatePurchase(data);
    if (errors.length > 0) { result.errors.push({ row: i + 1, errors }); return null; }
    return { data, hasItems: false };
  });

  // All-or-nothing: any invalid record → write nothing.
  if (result.errors.length > 0) { result.failed = records.length; return result; }

  const stmt = db.prepare(`INSERT INTO purchases (id, date, supplier, tons, pricePerTon, totalAmount, amountWithoutTax, taxAmount, taxRate, invoiceNumber, invoiceStatus, payment_status, paid_amount, due_date)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`);
  try {
    db.transaction(() => {
      for (const p of prepared) {
        const d = p.data;
        if (p.hasItems) {
          // multi-line: header neutralised (tons/pricePerTon=0, product_id omitted→NULL), money = Σ items.
          stmt.run(d.id, d.date, safeString(d.supplier), 0, 0,
            p.totals.totalAmount, p.totals.amountWithoutTax, p.totals.taxAmount, Number(d.taxRate) || 13,
            safeString(d.invoiceNumber || '', 100), safeString(d.invoiceStatus || '已收', 20),
            d.payment_status || 'paid', d.paid_amount ?? p.totals.totalAmount, d.due_date || null);
          replaceItems(db, 'purchase_items', 'purchase_id', d.id, p.rows);
        } else {
          stmt.run(d.id, d.date, safeString(d.supplier), d.tons, d.pricePerTon, d.totalAmount,
            d.amountWithoutTax, d.taxAmount, d.taxRate,
            safeString(d.invoiceNumber || '', 100), safeString(d.invoiceStatus || '已收', 20),
            d.payment_status || 'paid', d.paid_amount ?? d.totalAmount, d.due_date || null);
        }
      }
    })();
    result.success = records.length;
  } catch (e) {
    result.success = 0;
    result.failed = records.length;
    result.errors.push({ row: 0, errors: [e.message || 'batch write failed'] });
  }
  return result;
}

module.exports = { batchSales, batchPurchases };
