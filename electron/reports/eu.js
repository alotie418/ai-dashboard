// EU 通用报表引擎 — Profit & Loss + VAT Return

const reportTypes = [
  { id: 'profit-loss', name: { 'zh-CN': '损益表', en: 'Profit & Loss', fr: 'Compte de résultat' } },
  { id: 'vat-return', name: { 'zh-CN': 'VAT 申报概要', en: 'VAT Return Summary', fr: 'Déclaration TVA' } },
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
  const costs = totalExpenseNet;
  const grossProfit = revenue - costs;
  const operatingProfit = grossProfit - adminExpense;
  const tax = r(Math.max(0, operatingProfit) * (incomeTaxRate / 100));
  const netProfit = operatingProfit - tax;

  const vatCollected = totalIncomeTax;
  const vatDeductible = totalExpenseTax;
  const vatPayable = r(Math.max(0, vatCollected - vatDeductible));

  return {
    locale: 'EU', period: { from, to, year }, currency, reportTypes,
    profitLoss: {
      revenue: r(revenue), costOfSales: r(costs),
      costOfGoodsSold: r(cogsNet), operatingExpenses: r(operatingExpensesNet),
      grossProfit: r(grossProfit), grossMargin: revenue > 0 ? r(grossProfit / revenue * 100) : 0,
      adminExpense: r(adminExpense), operatingProfit: r(operatingProfit),
      incomeTax: tax, netProfit: r(netProfit),
      netMargin: revenue > 0 ? r(netProfit / revenue * 100) : 0,
    },
    vatReturn: {
      outputVAT: r(vatCollected), inputVAT: r(vatDeductible), vatPayable,
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
