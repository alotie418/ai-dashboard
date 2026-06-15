// Receivables / Payables summary
const { getDb } = require('../db');

function bucketize(daysDiff, amount, buckets) {
  if (daysDiff <= 30) buckets['0-30'] += amount;
  else if (daysDiff <= 60) buckets['31-60'] += amount;
  else if (daysDiff <= 90) buckets['61-90'] += amount;
  else buckets['90+'] += amount;
}

async function receivablesSummary() {
  const db = getDb();
  const allSales = db.prepare(
    `SELECT id, date, customer, totalAmount, paid_amount, payment_status, due_date, payment_date
     FROM sales WHERE payment_status != 'paid' OR due_date IS NOT NULL ORDER BY due_date ASC`
  ).all();

  const today = new Date().toISOString().split('T')[0];
  let totalReceivable = 0;
  let totalOverdue = 0;
  const agingBuckets = { '0-30': 0, '31-60': 0, '61-90': 0, '90+': 0 };
  const customerRanking = {};

  for (const s of allSales) {
    const unpaid = (s.totalAmount || 0) - (s.paid_amount || 0);
    if (unpaid <= 0) continue;
    totalReceivable += unpaid;

    const customer = s.customer || '未知';
    customerRanking[customer] = (customerRanking[customer] || 0) + unpaid;

    if (s.due_date && s.due_date < today) {
      totalOverdue += unpaid;
      const daysDiff = Math.floor((new Date(today) - new Date(s.due_date)) / 86400000);
      bucketize(daysDiff, unpaid, agingBuckets);
    }
  }

  const topCustomers = Object.entries(customerRanking)
    .sort((a, b) => b[1] - a[1])
    .slice(0, 10)
    .map(([name, amount]) => ({ name, amount }));

  const totalPaid = db.prepare('SELECT COALESCE(SUM(paid_amount), 0) as total FROM sales').get().total;
  const totalSales = db.prepare('SELECT COALESCE(SUM(totalAmount), 0) as total FROM sales').get().total;
  const collectionRate = totalSales > 0
    ? Math.round((totalPaid / totalSales) * 10000) / 100
    : 100;

  return {
    totalReceivable, totalOverdue, agingBuckets, topCustomers, collectionRate,
    details: allSales.filter(s => (s.totalAmount || 0) - (s.paid_amount || 0) > 0),
  };
}

async function payablesSummary() {
  const db = getDb();
  const allPurchases = db.prepare(
    `SELECT id, date, supplier, totalAmount, paid_amount, payment_status, due_date, payment_date
     FROM purchases WHERE payment_status != 'paid' OR due_date IS NOT NULL ORDER BY due_date ASC`
  ).all();

  const today = new Date().toISOString().split('T')[0];
  let totalPayable = 0;
  let totalOverdue = 0;
  const agingBuckets = { '0-30': 0, '31-60': 0, '61-90': 0, '90+': 0 };
  const supplierRanking = {};

  for (const p of allPurchases) {
    const unpaid = (p.totalAmount || 0) - (p.paid_amount || 0);
    if (unpaid <= 0) continue;
    totalPayable += unpaid;

    const supplier = p.supplier || '未知';
    supplierRanking[supplier] = (supplierRanking[supplier] || 0) + unpaid;

    if (p.due_date && p.due_date < today) {
      totalOverdue += unpaid;
      const daysDiff = Math.floor((new Date(today) - new Date(p.due_date)) / 86400000);
      bucketize(daysDiff, unpaid, agingBuckets);
    }
  }

  const topSuppliers = Object.entries(supplierRanking)
    .sort((a, b) => b[1] - a[1])
    .slice(0, 10)
    .map(([name, amount]) => ({ name, amount }));

  const totalPaid = db.prepare('SELECT COALESCE(SUM(paid_amount), 0) as total FROM purchases').get().total;
  const totalPurch = db.prepare('SELECT COALESCE(SUM(totalAmount), 0) as total FROM purchases').get().total;
  const paymentRate = totalPurch > 0
    ? Math.round((totalPaid / totalPurch) * 10000) / 100
    : 100;

  return {
    totalPayable, totalOverdue, agingBuckets, topSuppliers, paymentRate,
    details: allPurchases.filter(p => (p.totalAmount || 0) - (p.paid_amount || 0) > 0),
  };
}

module.exports = { receivablesSummary, payablesSummary };
