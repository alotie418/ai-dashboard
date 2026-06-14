// 中国大陆报表引擎 — 损益表 + 增值税统计 + 含税金额汇总
// 与 dashboard.js 的计算逻辑一致，但读取 transactions 表 + 参数化

const reportTypes = [
  { id: 'income-statement', name: { 'zh-CN': '损益表（利润表）', en: 'Income Statement (P&L)' } },
  { id: 'vat-summary', name: { 'zh-CN': '增值税统计', en: 'VAT Summary' } },
  { id: 'tax-inclusive', name: { 'zh-CN': '含税金额汇总', en: 'Tax-Inclusive Summary' } },
];

function generate(ctx) {
  const { incomeRows, expenseRows, categories, surchargeRate, incomeTaxRate, adminExpense, currency, year, from, to } = ctx;
  // PR-T5: split expenses into COGS vs operating (additive fields; costOfSales
  // and netProfit are unchanged — cogsNet + operatingExpensesNet === totalExpenseNet).
  const { splitExpenses } = require('./_expenseSplit');
  const { cogsNet, operatingExpensesNet } = splitExpenses(expenseRows, categories);

  // 汇总
  const totalIncome = incomeRows.reduce((s, r) => s + (r.amount || 0), 0);
  const totalIncomeNet = incomeRows.reduce((s, r) => s + (r.amount_net || r.amount || 0), 0);
  const totalIncomeTax = incomeRows.reduce((s, r) => s + (r.tax_amount || 0), 0);
  const totalExpense = expenseRows.reduce((s, r) => s + (r.amount || 0), 0);
  const totalExpenseNet = expenseRows.reduce((s, r) => s + (r.amount_net || r.amount || 0), 0);
  const totalExpenseTax = expenseRows.reduce((s, r) => s + (r.tax_amount || 0), 0);
  const totalShipping = incomeRows.reduce((s, r) => s + (r.shippingCost || 0), 0);

  // 损益表
  const salesRevenue = totalIncomeNet;
  const costOfSales = totalExpenseNet;
  const grossProfit = salesRevenue - costOfSales;
  const grossMargin = salesRevenue > 0 ? Math.round(grossProfit / salesRevenue * 10000) / 100 : 0;

  const vatPayable = Math.max(0, totalIncomeTax - totalExpenseTax);
  const taxSurcharge = Math.round(vatPayable * (surchargeRate / 100) * 100) / 100;

  const profitBeforeTax = grossProfit - taxSurcharge - totalShipping - adminExpense;
  const incomeTax = Math.round(Math.max(0, profitBeforeTax) * (incomeTaxRate / 100) * 100) / 100;
  const netProfit = profitBeforeTax - incomeTax;
  const netMargin = salesRevenue > 0 ? Math.round(netProfit / salesRevenue * 10000) / 100 : 0;

  const r = (v) => Math.round(v * 100) / 100;

  return {
    locale: 'CN',
    period: { from, to, year },
    currency,
    reportTypes,

    // 损益表
    incomeStatement: {
      salesRevenue: r(salesRevenue),
      costOfSales: r(costOfSales),
      costOfGoodsSold: r(cogsNet),
      operatingExpenses: r(operatingExpensesNet),
      operatingProfit: r(profitBeforeTax),
      grossProfit: r(grossProfit),
      grossMargin,
      taxSurcharge: r(taxSurcharge),
      shippingFee: r(totalShipping),
      adminExpense: r(adminExpense),
      incomeTax: r(incomeTax),
      netProfit: r(netProfit),
      netMargin,
    },

    // 增值税统计
    vatSummary: {
      cumulativeInput: r(totalExpenseTax),
      cumulativeOutput: r(totalIncomeTax),
      certifiedInput: r(totalExpenseTax),
      invoicedOutput: r(totalIncomeTax),
      estimatedPayable: r(vatPayable),
    },

    // 含税金额汇总
    taxInclusiveSummary: {
      purchaseTotal: r(totalExpense),
      salesTotal: r(totalIncome),
      difference: r(totalIncome - totalExpense),
    },

    // 月度明细（用于图表）
    monthlyBreakdown: buildMonthly(incomeRows, expenseRows, ctx),

    warnings: [],
  };
}

function buildMonthly(incomeRows, expenseRows, ctx) {
  const months = [];
  for (let m = 1; m <= 12; m++) {
    const mm = String(m).padStart(2, '0');
    const prefix = `${ctx.year}-${mm}`;
    const mIncome = incomeRows.filter(r => r.date && r.date.startsWith(prefix));
    const mExpense = expenseRows.filter(r => r.date && r.date.startsWith(prefix));
    const revenue = mIncome.reduce((s, r) => s + (r.amount_net || r.amount || 0), 0);
    const cost = mExpense.reduce((s, r) => s + (r.amount_net || r.amount || 0), 0);
    months.push({
      month: m,
      revenue: Math.round(revenue * 100) / 100,
      cost: Math.round(cost * 100) / 100,
      profit: Math.round((revenue - cost) * 100) / 100,
    });
  }
  return months;
}

module.exports = { reportTypes, generate };
