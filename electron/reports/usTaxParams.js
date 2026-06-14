// US Self-Employment-tax parameters, keyed by tax year (PR-T3).
//
// Source of the wage cap (`ssWageCap`): the SSA "Contribution and Benefit Base"
// — a.k.a. the Social Security taxable maximum — published annually by the SSA.
// The SE-tax / Medicare rates and the net-earnings factor are the standard
// IRS Schedule SE constants (stable across these years).
//
//   2024 ssWageCap = 168600
//   2025 ssWageCap = 176100
//   2026 ssWageCap = 184500
//
// Boundary: these values drive SoloLedger management ESTIMATES only. They do
// NOT constitute tax-filing advice; confirm against the current IRS/SSA figures
// before filing. Update this table yearly — mirrors the year-keyed pattern of
// US_MILEAGE_RATES in components/USTaxToolsPage.tsx.

const US_SE_TAX_PARAMS_BY_YEAR = {
  2024: { seEarningsFactor: 0.9235, ssRate: 0.124, ssWageCap: 168600, medicareRate: 0.029, addlMedicareThreshold: 200000, addlMedicareRate: 0.009, mealsDeductiblePct: 0.5 },
  2025: { seEarningsFactor: 0.9235, ssRate: 0.124, ssWageCap: 176100, medicareRate: 0.029, addlMedicareThreshold: 200000, addlMedicareRate: 0.009, mealsDeductiblePct: 0.5 },
  2026: { seEarningsFactor: 0.9235, ssRate: 0.124, ssWageCap: 184500, medicareRate: 0.029, addlMedicareThreshold: 200000, addlMedicareRate: 0.009, mealsDeductiblePct: 0.5 },
};

const YEARS = Object.keys(US_SE_TAX_PARAMS_BY_YEAR).map(Number);
const LATEST_YEAR = Math.max(...YEARS);

// Resolve SE-tax params for a tax year. Unknown / future years fall back to the
// latest keyed year. Never throws, never returns undefined params.
function resolveSeTaxParams(year) {
  const y = Number(year);
  const key = Number.isFinite(y) && US_SE_TAX_PARAMS_BY_YEAR[y] ? y : LATEST_YEAR;
  return { year: key, params: US_SE_TAX_PARAMS_BY_YEAR[key] };
}

module.exports = { US_SE_TAX_PARAMS_BY_YEAR, resolveSeTaxParams, LATEST_YEAR };
