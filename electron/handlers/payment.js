// Payment 记账
const { getDb } = require('../db');

function computeStatus(paid, total) {
  if (paid >= total) return 'paid';
  if (paid > 0) return 'partial';
  return 'unpaid';
}

async function recordSalePayment({ params, body }) {
  const db = getDb();
  const id = params.id;
  if (!id) throw new Error('Invalid ID');

  const paidAmount = Math.round(Number(body?.paid_amount) * 100) / 100;
  if (!Number.isFinite(paidAmount) || paidAmount < 0) {
    throw new Error('paid_amount must be a non-negative number');
  }

  const row = db.prepare('SELECT totalAmount FROM sales WHERE id = ?').get(id);
  if (!row) throw new Error('Sale not found');

  const paymentStatus = computeStatus(paidAmount, row.totalAmount);
  const paymentDate = body?.payment_date || new Date().toISOString().split('T')[0];

  db.prepare('UPDATE sales SET paid_amount = ?, payment_status = ?, payment_date = ? WHERE id = ?')
    .run(paidAmount, paymentStatus, paymentDate, id);

  return { success: true, payment_status: paymentStatus };
}

async function recordPurchasePayment({ params, body }) {
  const db = getDb();
  const id = params.id;
  if (!id) throw new Error('Invalid ID');

  const paidAmount = Math.round(Number(body?.paid_amount) * 100) / 100;
  if (!Number.isFinite(paidAmount) || paidAmount < 0) {
    throw new Error('paid_amount must be a non-negative number');
  }

  const row = db.prepare('SELECT totalAmount FROM purchases WHERE id = ?').get(id);
  if (!row) throw new Error('Purchase not found');

  const paymentStatus = computeStatus(paidAmount, row.totalAmount);
  const paymentDate = body?.payment_date || new Date().toISOString().split('T')[0];

  db.prepare('UPDATE purchases SET paid_amount = ?, payment_status = ?, payment_date = ? WHERE id = ?')
    .run(paidAmount, paymentStatus, paymentDate, id);

  return { success: true, payment_status: paymentStatus };
}

module.exports = { recordSalePayment, recordPurchasePayment };
