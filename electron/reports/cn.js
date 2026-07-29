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
  const { rateIsMissing } = require('./_missingRate');
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
  const costOfSales = cogsNet; // PR-T5-2A: COGS-only (was totalExpenseNet)
  const grossProfit = salesRevenue - costOfSales; // now revenue − COGS (true gross profit)
  const grossMargin = salesRevenue > 0 ? Math.round(grossProfit / salesRevenue * 10000) / 100 : 0;

  const vatPayable = Math.max(0, totalIncomeTax - totalExpenseTax);
  // A4-3:附加税率/所得税率不可用(缺行在中国不会发生,但**行在、值不可用**会)→
  // 显式拒算,产出 null。中国此前是靠 NaN 顺着链条传下去、由 JSON 序列化成 null 的
  // ——`cn.js` 的 r 没有 `|| 0` 守卫(其余四个引擎有)。同样的 null,现在是明说的拒绝
  // 而不是一次意外;而对「非合法 JSON」那一族,此前根本走不到 NaN,它会静默回退到
  // 兜底 12 / 25 并照常出数,那才是这条分支真正堵住的东西。
  const surchargeMissing = rateIsMissing(surchargeRate);
  const rateMissing = rateIsMissing(incomeTaxRate);
  const taxSurcharge = surchargeMissing
    ? null
    : Math.round(vatPayable * (surchargeRate / 100) * 100) / 100;

  // PR-T5-2A: gross profit is now COGS-only, so operating expenses are subtracted
  // here. profitBeforeTax (and netProfit) are numerically unchanged: grossProfit −
  // operatingExpensesNet === old (revenue − totalExpenseNet).
  // 税前利润吃附加税,所以附加税不可用时它也算不出来 —— 这条依赖链是中国独有的
  // (cn.js 的 operatingProfit 装的就是 profitBeforeTax)。
  const profitBeforeTax = surchargeMissing
    ? null
    : grossProfit - operatingExpensesNet - taxSurcharge - totalShipping - adminExpense;
  const cannotPrice = surchargeMissing || rateMissing;
  const incomeTax = cannotPrice
    ? null
    : Math.round(Math.max(0, profitBeforeTax) * (incomeTaxRate / 100) * 100) / 100;
  const netProfit = cannotPrice ? null : profitBeforeTax - incomeTax;
  const netMargin = cannotPrice
    ? null
    : (salesRevenue > 0 ? Math.round(netProfit / salesRevenue * 10000) / 100 : 0);

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
      operatingProfit: surchargeMissing ? null : r(profitBeforeTax),
      grossProfit: r(grossProfit),
      grossMargin,
      taxSurcharge: surchargeMissing ? null : r(taxSurcharge),
      shippingFee: r(totalShipping),
      adminExpense: r(adminExpense),
      incomeTax: cannotPrice ? null : r(incomeTax),
      netProfit: cannotPrice ? null : r(netProfit),
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
