// 日本報表引擎 — 損益計算書 + 消費税

const reportTypes = [
  { id: 'income-statement', name: { 'zh-CN': '損益計算書', en: 'Income Statement (P&L)', ja: '損益計算書' } },
  { id: 'consumption-tax', name: { 'zh-CN': '消費税概要', en: 'Consumption Tax Summary', ja: '消費税概要' } },
];

function generate(ctx) {
  const { incomeRows, expenseRows, categories, surchargeRate, incomeTaxRate, adminExpense, currency, year, from, to } = ctx;
  // PR-T5: split expenses into COGS vs operating (additive fields; costOfSales
  // and netProfit are unchanged — cogsNet + operatingExpensesNet === totalExpenseNet).
  const { splitExpenses } = require('./_expenseSplit');
  const { cogsNet, operatingExpensesNet } = splitExpenses(expenseRows, categories);
  const r = (v) => Math.round((v || 0) * 100) / 100;

  const totalIncome = incomeRows.reduce((s, row) => s + (row.amount || 0), 0);
  const totalIncomeNet = incomeRows.reduce((s, row) => s + (row.amount_net || row.amount || 0), 0);
  const totalIncomeTax = incomeRows.reduce((s, row) => s + (row.tax_amount || 0), 0);
  const totalExpense = expenseRows.reduce((s, row) => s + (row.amount || 0), 0);
  const totalExpenseNet = expenseRows.reduce((s, row) => s + (row.amount_net || row.amount || 0), 0);
  const totalExpenseTax = expenseRows.reduce((s, row) => s + (row.tax_amount || 0), 0);

  const salesRevenue = totalIncomeNet;
  const costOfSales = cogsNet; // PR-T5-2A: COGS-only (was totalExpenseNet)
  const grossProfit = salesRevenue - costOfSales; // now revenue − COGS
  const grossMargin = salesRevenue > 0 ? r(grossProfit / salesRevenue * 100) : 0;
  const operatingProfit = grossProfit - operatingExpensesNet - adminExpense; // PR-T5-2A: subtract operating expenses (netProfit unchanged)
  const taxPayable = r(Math.max(0, operatingProfit) * (incomeTaxRate / 100));
  const netProfit = operatingProfit - taxPayable;

  // 消費税（仕入税額控除方式）
  const consumptionTaxCollected = totalIncomeTax;
  const consumptionTaxPaid = totalExpenseTax;
  const consumptionTaxPayable = r(Math.max(0, consumptionTaxCollected - consumptionTaxPaid));

  return {
    locale: 'JP', period: { from, to, year }, currency, reportTypes,
    incomeStatement: {
      salesRevenue: r(salesRevenue), costOfSales: r(costOfSales),
      costOfGoodsSold: r(cogsNet), operatingExpenses: r(operatingExpensesNet),
      grossProfit: r(grossProfit), grossMargin,
      adminExpense: r(adminExpense), operatingProfit: r(operatingProfit),
      incomeTax: taxPayable, netProfit: r(netProfit),
      netMargin: salesRevenue > 0 ? r(netProfit / salesRevenue * 100) : 0,
    },
    consumptionTax: {
      collected: r(consumptionTaxCollected), paid: r(consumptionTaxPaid),
      payable: consumptionTaxPayable,
    },
    taxInclusiveSummary: {
      purchaseTotal: r(totalExpense), salesTotal: r(totalIncome),
      difference: r(totalIncome - totalExpense),
    },
    monthlyBreakdown: buildMonthly(incomeRows, expenseRows, year),
    warnings: [],
  };
}

function buildMonthly(inc, exp, year) {
  const r = (v) => Math.round((v || 0) * 100) / 100;
  const months = [];
  for (let m = 1; m <= 12; m++) {
    const p = `${year}-${String(m).padStart(2, '0')}`;
    const revenue = inc.filter(x => x.date?.startsWith(p)).reduce((s, x) => s + (x.amount_net || x.amount || 0), 0);
    const cost = exp.filter(x => x.date?.startsWith(p)).reduce((s, x) => s + (x.amount_net || x.amount || 0), 0);
    months.push({ month: m, revenue: r(revenue), cost: r(cost), profit: r(revenue - cost) });
  }
  return months;
}

module.exports = { reportTypes, generate };
