// 台灣報表引擎 — 損益表 + 營業稅

const reportTypes = [
  { id: 'income-statement', name: { 'zh-CN': '损益表', en: 'Income Statement', 'zh-TW': '損益表' } },
  { id: 'business-tax', name: { 'zh-CN': '营业税概要', en: 'Business Tax Summary', 'zh-TW': '營業稅概要' } },
];

function generate(ctx) {
  const { incomeRows, expenseRows, categories, incomeTaxRate, adminExpense, currency, year, from, to } = ctx;
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

  const revenue = totalIncomeNet;
  const cogs = cogsNet; // PR-T5-2A: COGS-only (was totalExpenseNet)
  const grossProfit = revenue - cogs; // now revenue − COGS
  const operatingProfit = grossProfit - operatingExpensesNet - adminExpense; // PR-T5-2A: subtract operating expenses (netProfit unchanged)
  const tax = r(Math.max(0, operatingProfit) * (incomeTaxRate / 100));
  const netProfit = operatingProfit - tax;
  const businessTaxPayable = r(Math.max(0, totalIncomeTax - totalExpenseTax));

  return {
    locale: 'TW', period: { from, to, year }, currency, reportTypes,
    incomeStatement: {
      salesRevenue: r(revenue), costOfSales: r(cogs),
      costOfGoodsSold: r(cogsNet), operatingExpenses: r(operatingExpensesNet),
      grossProfit: r(grossProfit), grossMargin: revenue > 0 ? r(grossProfit / revenue * 100) : 0,
      adminExpense: r(adminExpense), operatingProfit: r(operatingProfit),
      incomeTax: tax, netProfit: r(netProfit),
      netMargin: revenue > 0 ? r(netProfit / revenue * 100) : 0,
    },
    businessTax: {
      collected: r(totalIncomeTax), paid: r(totalExpenseTax), payable: businessTaxPayable,
    },
    taxInclusiveSummary: {
      purchaseTotal: r(totalExpense), salesTotal: r(totalIncome), difference: r(totalIncome - totalExpense),
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
