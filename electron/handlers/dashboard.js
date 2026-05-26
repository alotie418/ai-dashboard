// Dashboard 聚合查询 — 从 worker/src/index.js 第 2399-2570 行迁移
// 所有计算口径与 worker 完全一致，单元测试在使用真实数据时的输出应当 bit-for-bit 相等
const { getDb } = require('../db');

const MONTH_NAMES = ['1月', '2月', '3月', '4月', '5月', '6月', '7月', '8月', '9月', '10月', '11月', '12月'];

async function summary({ query }) {
  const db = getDb();
  const year = query.year || String(new Date().getFullYear());
  const dateStart = `${year}-01-01`;
  const dateEnd = `${year}-12-31`;

  const purchaseAgg = db.prepare(`
    SELECT
      COALESCE(SUM(tons), 0) as totalTons,
      COALESCE(SUM(totalAmount), 0) as totalAmount,
      COALESCE(SUM(amountWithoutTax), 0) as totalAmountWithoutTax,
      COALESCE(SUM(taxAmount), 0) as totalTaxAmount,
      COUNT(*) as recordCount
    FROM purchases WHERE date >= ? AND date <= ?
  `).get(dateStart, dateEnd);

  const salesAgg = db.prepare(`
    SELECT
      COALESCE(SUM(tons), 0) as totalTons,
      COALESCE(SUM(totalAmount), 0) as totalAmount,
      COALESCE(SUM(amountWithoutTax), 0) as totalAmountWithoutTax,
      COALESCE(SUM(taxAmount), 0) as totalTaxAmount,
      COALESCE(SUM(shippingCost), 0) as totalShipping,
      COUNT(*) as recordCount
    FROM sales WHERE date >= ? AND date <= ?
  `).get(dateStart, dateEnd);

  const avgCostPerTon = purchaseAgg.totalTons > 0
    ? Math.round(purchaseAgg.totalAmount / purchaseAgg.totalTons * 100) / 100
    : 0;
  const avgCostPerTonNoTax = purchaseAgg.totalTons > 0
    ? purchaseAgg.totalAmountWithoutTax / purchaseAgg.totalTons
    : 0;

  const invAll = db.prepare(`
    SELECT
      COALESCE((SELECT SUM(tons) FROM purchases), 0) -
      COALESCE((SELECT SUM(tons) FROM sales), 0) as inventoryTons
  `).get();

  const monthlyPurchases = db.prepare(`
    SELECT
      CAST(strftime('%m', date) AS INTEGER) as month,
      COALESCE(SUM(tons), 0) as purchaseTons,
      COALESCE(SUM(totalAmount), 0) as purchaseAmount,
      COALESCE(SUM(amountWithoutTax), 0) as purchaseAmountNoTax,
      COALESCE(SUM(taxAmount), 0) as purchaseTax
    FROM purchases WHERE date >= ? AND date <= ?
    GROUP BY strftime('%m', date)
  `).all(dateStart, dateEnd);

  const monthlySales = db.prepare(`
    SELECT
      CAST(strftime('%m', date) AS INTEGER) as month,
      COALESCE(SUM(tons), 0) as salesTons,
      COALESCE(SUM(totalAmount), 0) as salesAmount,
      COALESCE(SUM(amountWithoutTax), 0) as salesAmountNoTax,
      COALESCE(SUM(taxAmount), 0) as salesTax,
      COALESCE(SUM(shippingCost), 0) as salesShipping
    FROM sales WHERE date >= ? AND date <= ?
    GROUP BY strftime('%m', date)
  `).all(dateStart, dateEnd);

  const pMap = Object.fromEntries(monthlyPurchases.map(r => [r.month, r]));
  const sMap = Object.fromEntries(monthlySales.map(r => [r.month, r]));

  const monthlyPerformance = [];
  for (let m = 1; m <= 12; m++) {
    const p = pMap[m] || {};
    const s = sMap[m] || {};
    const revenue = s.salesAmountNoTax || 0;
    const cost = (s.salesTons || 0) > 0 && avgCostPerTonNoTax > 0
      ? Math.round(avgCostPerTonNoTax * (s.salesTons || 0) * 100) / 100
      : 0;
    const shipping = s.salesShipping || 0;
    const grossProfit = revenue - cost;
    monthlyPerformance.push({
      name: MONTH_NAMES[m - 1],
      revenue,
      cost,
      profit: grossProfit,
      purchaseTons: p.purchaseTons || 0,
      salesTons: s.salesTons || 0,
      netProfit: grossProfit - shipping,
      yoy: 0,
      mom: 0,
      deflator: 0,
    });
  }

  // 财务报表（不含税口径）
  const salesRevenue = salesAgg.totalAmountWithoutTax || 0;
  const costOfSales = salesAgg.totalTons > 0 && avgCostPerTonNoTax > 0
    ? Math.round(avgCostPerTonNoTax * salesAgg.totalTons * 100) / 100
    : 0;
  const grossProfit = salesRevenue - costOfSales;
  const grossMargin = salesRevenue > 0 ? Math.round(grossProfit / salesRevenue * 10000) / 100 : 0;
  const shippingFee = salesAgg.totalShipping || 0;

  // ===== 动态税率参数（来自会计制度预设，由用户在设置中选择）=====
  function readSettingNum(key, fallback) {
    try {
      const row = db.prepare("SELECT value FROM settings WHERE key = ?").get(key);
      if (!row) return fallback;
      const parsed = parseFloat(JSON.parse(row.value));
      return Number.isFinite(parsed) ? parsed : fallback;
    } catch { return fallback; }
  }
  const surchargePct = readSettingNum('surcharge_rate', 12);   // 中国默认 12%
  const incomeTaxPct = readSettingNum('income_tax_rate', 25);   // 中国默认 25%

  // 税金及附加 = 应纳增值税 × 附加税率
  const vatPayable = Math.max(0, (salesAgg.totalTaxAmount || 0) - (purchaseAgg.totalTaxAmount || 0));
  const taxSurcharge = Math.round(vatPayable * (surchargePct / 100) * 100) / 100;

  // 管理费用：从设置中读取
  let adminExpense = 0;
  try {
    const adminSetting = db.prepare("SELECT value FROM settings WHERE key = 'admin_expense_annual'").get();
    if (adminSetting) adminExpense = parseFloat(JSON.parse(adminSetting.value)) || 0;
  } catch { /* fallback to 0 */ }

  const profitBeforeTax = grossProfit - taxSurcharge - shippingFee - adminExpense;
  const incomeTax = Math.round(Math.max(0, profitBeforeTax) * (incomeTaxPct / 100) * 100) / 100;
  const netProfit = profitBeforeTax - incomeTax;
  const netMargin = salesRevenue > 0 ? Math.round(netProfit / salesRevenue * 10000) / 100 : 0;

  const cumulativeInput = purchaseAgg.totalTaxAmount || 0;
  const cumulativeOutput = salesAgg.totalTaxAmount || 0;
  const estimatedPayable = cumulativeOutput - cumulativeInput;
  const purchaseTotal = purchaseAgg.totalAmount || 0;
  const salesTotal = salesAgg.totalAmount || 0;

  return {
    metrics: {
      inventoryTons: Math.round((invAll.inventoryTons || 0) * 100) / 100,
      purchaseTotalTons: Math.round((purchaseAgg.totalTons || 0) * 100) / 100,
      purchaseTotalAmount: Math.round((purchaseAgg.totalAmount || 0) * 100) / 100,
      salesTotalTons: Math.round((salesAgg.totalTons || 0) * 100) / 100,
      salesTotalAmount: Math.round((salesAgg.totalAmount || 0) * 100) / 100,
      avgCostPerTon,
    },
    monthlyPerformance,
    financialStatement: {
      salesRevenue: Math.round(salesRevenue * 100) / 100,
      costOfSales: Math.round(costOfSales * 100) / 100,
      taxSurcharge,
      shippingFee: Math.round(shippingFee * 100) / 100,
      adminExpense,
      incomeTax,
      grossProfit: Math.round(grossProfit * 100) / 100,
      grossMargin,
      netProfit: Math.round(netProfit * 100) / 100,
      netMargin,
    },
    vatStatistics: {
      cumulativeInput: Math.round(cumulativeInput * 100) / 100,
      cumulativeOutput: Math.round(cumulativeOutput * 100) / 100,
      certifiedInput: Math.round(cumulativeInput * 100) / 100,
      invoicedOutput: Math.round(cumulativeOutput * 100) / 100,
      estimatedPayable: Math.round(estimatedPayable * 100) / 100,
    },
    taxInclusiveSummary: {
      purchaseTotal: Math.round(purchaseTotal * 100) / 100,
      salesTotal: Math.round(salesTotal * 100) / 100,
      difference: Math.round((salesTotal - purchaseTotal) * 100) / 100,
    },
  };
}

module.exports = { summary };
