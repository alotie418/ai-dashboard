// 美国报表引擎 — Schedule C (Profit or Loss from Business) + SE Tax estimate

const reportTypes = [
  { id: 'schedule-c', name: { 'zh-CN': 'Schedule C（个体经营损益）', en: 'Schedule C (Profit or Loss)' } },
  { id: 'se-tax', name: { 'zh-CN': 'Self-Employment Tax 估算', en: 'Self-Employment Tax Estimate' } },
];

function generate(ctx) {
  const { incomeRows, expenseRows, categories, incomeTaxRate, currency, year, from, to } = ctx;
  // SE-tax constants are year-keyed (see usTaxParams.js); unknown years fall
  // back to the latest. Management estimate only — not tax-filing advice.
  const { params: se, year: seParamYear } = require('./usTaxParams').resolveSeTaxParams(year);

  // Gross receipts (Line 1)
  const grossReceipts = incomeRows.reduce((s, r) => s + (r.amount || 0), 0);
  // Returns & allowances (Line 2) — filter by category slug if available
  const returns = incomeRows
    .filter(r => matchCategory(r, categories, 'returns'))
    .reduce((s, r) => s + (r.amount || 0), 0);
  // Other income (Line 6)
  const otherIncome = incomeRows
    .filter(r => matchCategory(r, categories, 'other-income'))
    .reduce((s, r) => s + (r.amount || 0), 0);
  const grossIncome = grossReceipts - returns + otherIncome; // Line 7

  // Expenses by category (Part II, Lines 8-27)
  const expenseBySlug = {};
  for (const row of expenseRows) {
    const slug = findCategorySlug(row, categories) || 'other';
    expenseBySlug[slug] = (expenseBySlug[slug] || 0) + (row.amount || 0);
  }

  // Schedule C standard lines
  const scheduleC = {
    line1_grossReceipts: r(grossReceipts),
    line2_returns: r(returns),
    line6_otherIncome: r(otherIncome),
    line7_grossIncome: r(grossIncome),
    // Part II expenses
    line8_advertising: r(expenseBySlug['advertising'] || 0),
    line9_car: r(expenseBySlug['car-truck'] || 0),
    line10_commissions: r(expenseBySlug['commissions'] || 0),
    line11_contract: r(expenseBySlug['contract-labor'] || 0),
    line13_depreciation: r(expenseBySlug['depreciation'] || 0),
    line15_insurance: r(expenseBySlug['insurance'] || 0),
    line16b_interest: r(expenseBySlug['interest'] || 0),
    line17_legal: r(expenseBySlug['legal-pro'] || 0),
    line18_office: r(expenseBySlug['office'] || 0),
    line20_rent: r(expenseBySlug['rent'] || 0),
    line21_repairs: r(expenseBySlug['repairs'] || 0),
    line22_supplies: r(expenseBySlug['supplies'] || 0),
    line23_taxes: r(expenseBySlug['taxes'] || 0),
    line24a_travel: r(expenseBySlug['travel'] || 0),
    line24b_meals: r((expenseBySlug['meals'] || 0) * se.mealsDeductiblePct), // meals partial-deductible (year-keyed)
    line25_utilities: r(expenseBySlug['utilities'] || 0),
    line26_wages: r(expenseBySlug['wages'] || 0),
    line27a_other: r(expenseBySlug['other'] || 0),
    line30_homeOffice: r(expenseBySlug['home-office'] || 0),
  };

  const totalExpenses = Object.entries(scheduleC)
    .filter(([k]) => k.startsWith('line') && k !== 'line1_grossReceipts' && k !== 'line2_returns' && k !== 'line6_otherIncome' && k !== 'line7_grossIncome')
    .reduce((s, [, v]) => s + v, 0);

  const netProfit = grossIncome - totalExpenses; // Line 31

  // Self-Employment Tax estimate — rates/cap from usTaxParams.js (year-keyed)
  const seEarnings = netProfit * se.seEarningsFactor; // net-earnings factor
  const ssTaxCap = se.ssWageCap; // SSA contribution & benefit base for the year
  const ssTax = Math.min(seEarnings, ssTaxCap) * se.ssRate;
  const medicareTax = seEarnings * se.medicareRate;
  const additionalMedicare = seEarnings > se.addlMedicareThreshold ? (seEarnings - se.addlMedicareThreshold) * se.addlMedicareRate : 0;
  const totalSETax = r(ssTax + medicareTax + additionalMedicare);

  // Quarterly estimated tax
  const estimatedAnnualTax = r(netProfit * (incomeTaxRate / 100)) + totalSETax;
  const quarterlyPayment = r(estimatedAnnualTax / 4);

  return {
    locale: 'US',
    period: { from, to, year },
    currency,
    reportTypes,

    scheduleC: {
      ...scheduleC,
      line28_totalExpenses: r(totalExpenses),
      line31_netProfit: r(netProfit),
    },

    selfEmploymentTax: {
      netEarnings: r(netProfit),
      seEarnings: r(seEarnings),
      socialSecurityTax: r(ssTax),
      medicareTax: r(medicareTax),
      additionalMedicare: r(additionalMedicare),
      totalSETax,
      paramYear: seParamYear,
    },

    estimatedTax: {
      annualIncomeTax: r(netProfit * (incomeTaxRate / 100)),
      annualSETax: totalSETax,
      totalAnnual: estimatedAnnualTax,
      quarterlyPayment,
      dueDates: [`${year}-04-15`, `${year}-06-15`, `${year}-09-15`, `${Number(year) + 1}-01-15`],
    },

    monthlyBreakdown: buildMonthly(incomeRows, expenseRows, year),

    warnings: [
      netProfit > 0 && totalSETax > 0 ? `Estimated quarterly tax payment: $${quarterlyPayment.toLocaleString()}` : null,
      expenseBySlug['meals'] ? 'Meals expense is automatically limited to 50% deductible (Line 24b)' : null,
    ].filter(Boolean),
  };
}

function matchCategory(row, categories, slug) {
  if (!row.category_id) return false;
  const cat = categories.find(c => c.id === row.category_id);
  return cat && cat.slug === slug;
}

function findCategorySlug(row, categories) {
  if (!row.category_id) return null;
  const cat = categories.find(c => c.id === row.category_id);
  return cat ? cat.slug : null;
}

function buildMonthly(incomeRows, expenseRows, year) {
  const months = [];
  for (let m = 1; m <= 12; m++) {
    const mm = String(m).padStart(2, '0');
    const prefix = `${year}-${mm}`;
    const income = incomeRows.filter(r => r.date?.startsWith(prefix)).reduce((s, r) => s + (r.amount || 0), 0);
    const expense = expenseRows.filter(r => r.date?.startsWith(prefix)).reduce((s, r) => s + (r.amount || 0), 0);
    months.push({ month: m, revenue: r(income), cost: r(expense), profit: r(income - expense) });
  }
  return months;
}

function r(v) { return Math.round((v || 0) * 100) / 100; }

module.exports = { reportTypes, generate };
