// 韩国报表引擎 — 손익계산서 + 부가가치세

const reportTypes = [
  { id: 'income-statement', name: { 'zh-CN': '损益计算书', en: 'Income Statement', ko: '손익계산서' } },
  { id: 'vat-summary', name: { 'zh-CN': '附加价值税概要', en: 'VAT Summary', ko: '부가가치세 요약' } },
];

function generate(ctx) {
  const { incomeRows, expenseRows, incomeTaxRate, adminExpense, currency, year, from, to } = ctx;
  const r = (v) => Math.round((v || 0) * 100) / 100;

  const totalIncome = incomeRows.reduce((s, row) => s + (row.amount || 0), 0);
  const totalIncomeNet = incomeRows.reduce((s, row) => s + (row.amount_net || row.amount || 0), 0);
  const totalIncomeTax = incomeRows.reduce((s, row) => s + (row.tax_amount || 0), 0);
  const totalExpense = expenseRows.reduce((s, row) => s + (row.amount || 0), 0);
  const totalExpenseNet = expenseRows.reduce((s, row) => s + (row.amount_net || row.amount || 0), 0);
  const totalExpenseTax = expenseRows.reduce((s, row) => s + (row.tax_amount || 0), 0);

  const revenue = totalIncomeNet;
  const cogs = totalExpenseNet;
  const grossProfit = revenue - cogs;
  const operatingProfit = grossProfit - adminExpense;
  const tax = r(Math.max(0, operatingProfit) * (incomeTaxRate / 100));
  const netProfit = operatingProfit - tax;
  const vatPayable = r(Math.max(0, totalIncomeTax - totalExpenseTax));

  return {
    locale: 'KR', period: { from, to, year }, currency, reportTypes,
    incomeStatement: {
      salesRevenue: r(revenue), costOfSales: r(cogs),
      grossProfit: r(grossProfit), grossMargin: revenue > 0 ? r(grossProfit / revenue * 100) : 0,
      adminExpense: r(adminExpense), operatingProfit: r(operatingProfit),
      incomeTax: tax, netProfit: r(netProfit),
      netMargin: revenue > 0 ? r(netProfit / revenue * 100) : 0,
    },
    vatSummary: {
      outputVAT: r(totalIncomeTax), inputVAT: r(totalExpenseTax), vatPayable,
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
