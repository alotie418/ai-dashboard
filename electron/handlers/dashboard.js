// Dashboard 聚合查询 — 复用报表引擎 + locale 自适应
// 保留旧 sales/purchases 的 metrics/monthlyPerformance 作为 fallback
// 新增 report 字段返回报表引擎结果（按 accounting_locale 自动路由）

const { getDb } = require('../db');
const reportEngine = require('../reports');

const MONTH_NAMES = ['1月', '2月', '3月', '4月', '5月', '6月', '7月', '8月', '9月', '10月', '11月', '12月'];

function readSetting(db, key, fallback) {
  try {
    const row = db.prepare('SELECT value FROM settings WHERE key = ?').get(key);
    return row ? JSON.parse(row.value) : fallback;
  } catch { return fallback; }
}

async function summary({ query }) {
  const db = getDb();
  const year = query.year || String(new Date().getFullYear());
  const dateStart = `${year}-01-01`;
  const dateEnd = `${year}-12-31`;
  const locale = readSetting(db, 'accounting_locale', 'CN');

  // ===== 报表引擎（按 locale 生成）=====
  let report = null;
  try {
    report = reportEngine.generate(db, { locale, year });
  } catch (e) {
    console.warn('[dashboard] report engine failed, falling back to legacy:', e?.message);
  }

  // ===== US 附加数据：Mileage + Home Office =====
  let mileageSummary = null;
  let homeOffice = null;
  if (locale === 'US') {
    try {
      const mRow = db.prepare(`
        SELECT COUNT(*) as trips, COALESCE(SUM(miles), 0) as totalMiles,
               COALESCE(SUM(deduction), 0) as totalDeduction
        FROM mileage_logs WHERE date >= ? AND date <= ?
      `).get(dateStart, dateEnd);
      mileageSummary = { trips: mRow.trips, totalMiles: Math.round(mRow.totalMiles * 100) / 100, totalDeduction: Math.round(mRow.totalDeduction * 100) / 100 };
    } catch { /* mileage_logs may not exist */ }
    try {
      const hoHandler = require('./homeOffice');
      homeOffice = await hoHandler.get();
    } catch { /* home_office may not exist */ }
  }

  // ===== Legacy metrics（旧 sales/purchases 表 — 保留 backward compat）=====
  const hasSales = db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='sales'").get();
  const hasPurchases = db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='purchases'").get();

  let metrics = { inventoryTons: 0, purchaseTotalTons: 0, purchaseTotalAmount: 0, salesTotalTons: 0, salesTotalAmount: 0, avgCostPerTon: 0 };
  let monthlyPerformance = [];

  if (hasSales || hasPurchases) {
    const purchaseAgg = hasPurchases ? db.prepare(`
      SELECT COALESCE(SUM(tons), 0) as totalTons, COALESCE(SUM(totalAmount), 0) as totalAmount,
             COALESCE(SUM(amountWithoutTax), 0) as totalAmountWithoutTax
      FROM purchases WHERE date >= ? AND date <= ?
    `).get(dateStart, dateEnd) : { totalTons: 0, totalAmount: 0, totalAmountWithoutTax: 0 };

    const salesAgg = hasSales ? db.prepare(`
      SELECT COALESCE(SUM(tons), 0) as totalTons, COALESCE(SUM(totalAmount), 0) as totalAmount,
             COALESCE(SUM(amountWithoutTax), 0) as totalAmountWithoutTax, COALESCE(SUM(shippingCost), 0) as totalShipping
      FROM sales WHERE date >= ? AND date <= ?
    `).get(dateStart, dateEnd) : { totalTons: 0, totalAmount: 0, totalAmountWithoutTax: 0, totalShipping: 0 };

    const avgCostPerTon = purchaseAgg.totalTons > 0 ? Math.round(purchaseAgg.totalAmount / purchaseAgg.totalTons * 100) / 100 : 0;
    const invAll = db.prepare(`
      SELECT COALESCE((SELECT SUM(tons) FROM purchases), 0) - COALESCE((SELECT SUM(tons) FROM sales), 0) as inventoryTons
    `).get();

    metrics = {
      inventoryTons: Math.round((invAll.inventoryTons || 0) * 100) / 100,
      purchaseTotalTons: Math.round((purchaseAgg.totalTons || 0) * 100) / 100,
      purchaseTotalAmount: Math.round((purchaseAgg.totalAmount || 0) * 100) / 100,
      salesTotalTons: Math.round((salesAgg.totalTons || 0) * 100) / 100,
      salesTotalAmount: Math.round((salesAgg.totalAmount || 0) * 100) / 100,
      avgCostPerTon,
    };

    // Monthly breakdown from legacy tables
    const avgCostPerTonNoTax = purchaseAgg.totalTons > 0 ? purchaseAgg.totalAmountWithoutTax / purchaseAgg.totalTons : 0;
    const monthlyPurchases = hasPurchases ? db.prepare(`
      SELECT CAST(strftime('%m', date) AS INTEGER) as month, COALESCE(SUM(tons), 0) as purchaseTons
      FROM purchases WHERE date >= ? AND date <= ? GROUP BY strftime('%m', date)
    `).all(dateStart, dateEnd) : [];
    const monthlySales = hasSales ? db.prepare(`
      SELECT CAST(strftime('%m', date) AS INTEGER) as month, COALESCE(SUM(tons), 0) as salesTons,
             COALESCE(SUM(amountWithoutTax), 0) as salesAmountNoTax, COALESCE(SUM(shippingCost), 0) as salesShipping
      FROM sales WHERE date >= ? AND date <= ? GROUP BY strftime('%m', date)
    `).all(dateStart, dateEnd) : [];
    const pMap = Object.fromEntries(monthlyPurchases.map(r => [r.month, r]));
    const sMap = Object.fromEntries(monthlySales.map(r => [r.month, r]));
    for (let m = 1; m <= 12; m++) {
      const p = pMap[m] || {};
      const s = sMap[m] || {};
      const revenue = s.salesAmountNoTax || 0;
      const cost = (s.salesTons || 0) > 0 && avgCostPerTonNoTax > 0 ? Math.round(avgCostPerTonNoTax * (s.salesTons || 0) * 100) / 100 : 0;
      monthlyPerformance.push({
        name: MONTH_NAMES[m - 1], revenue, cost, profit: revenue - cost,
        purchaseTons: p.purchaseTons || 0, salesTons: s.salesTons || 0,
        netProfit: revenue - cost - (s.salesShipping || 0), yoy: 0, mom: 0, deflator: 0,
      });
    }
  }

  // Use report engine monthly if available
  if (report?.monthlyBreakdown) {
    monthlyPerformance = report.monthlyBreakdown.map((m, i) => ({
      name: MONTH_NAMES[i] || `${m.month}`,
      revenue: m.revenue, cost: m.cost, profit: m.profit,
      purchaseTons: monthlyPerformance[i]?.purchaseTons || 0,
      salesTons: monthlyPerformance[i]?.salesTons || 0,
      netProfit: m.profit, yoy: 0, mom: 0, deflator: 0,
    }));
  }

  // ===== 构建 financialStatement（从报表引擎或 fallback）=====
  const is = report?.incomeStatement || report?.profitLoss || report?.scheduleC;
  const financialStatement = is ? {
    salesRevenue: is.salesRevenue || is.revenue || is.line7_grossIncome || 0,
    costOfSales: is.costOfSales || is.line28_totalExpenses || 0,
    taxSurcharge: is.taxSurcharge || 0,
    shippingFee: is.shippingFee || 0,
    adminExpense: is.adminExpense || 0,
    incomeTax: is.incomeTax || 0,
    grossProfit: is.grossProfit || (is.line7_grossIncome || 0) - (is.line28_totalExpenses || 0),
    grossMargin: is.grossMargin || 0,
    netProfit: is.netProfit || is.line31_netProfit || 0,
    netMargin: is.netMargin || 0,
  } : { salesRevenue: 0, costOfSales: 0, taxSurcharge: 0, shippingFee: 0, adminExpense: 0, incomeTax: 0, grossProfit: 0, grossMargin: 0, netProfit: 0, netMargin: 0 };

  return {
    locale,
    metrics,
    monthlyPerformance,
    financialStatement,
    // 保留旧结构兼容（CN 用）
    vatStatistics: report?.vatSummary || report?.consumptionTax || report?.vatReturn || report?.businessTax || { cumulativeInput: 0, cumulativeOutput: 0, certifiedInput: 0, invoicedOutput: 0, estimatedPayable: 0 },
    taxInclusiveSummary: report?.taxInclusiveSummary || { purchaseTotal: 0, salesTotal: 0, difference: 0 },
    // 新增：完整报表引擎结果 + US 附加数据
    report,
    mileageSummary,
    homeOffice,
  };
}

module.exports = { summary };
