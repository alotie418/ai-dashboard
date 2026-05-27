// Home Office deduction handler — US Form 8829 / Simplified method
// Simplified: $5/sqft × area (max 300 sqft = $1,500 max)
// Actual: (office_sqft / total_sqft) × (rent + utilities + insurance + depreciation)

const { getDb } = require('../db');

async function get() {
  const db = getDb();
  const row = db.prepare('SELECT * FROM home_office WHERE id = 1').get();
  if (!row) return { method: 'simplified', sqft: 0, rate_per_sqft: 5, max_sqft: 300, total_home_sqft: 0, annual_rent: 0, annual_utilities: 0, annual_insurance: 0, annual_depreciation: 0 };

  // Calculate deduction
  let deduction = 0;
  if (row.method === 'simplified') {
    const effectiveSqft = Math.min(row.sqft || 0, row.max_sqft || 300);
    deduction = effectiveSqft * (row.rate_per_sqft || 5);
  } else {
    // Actual method
    const ratio = row.total_home_sqft > 0 ? (row.sqft || 0) / row.total_home_sqft : 0;
    const totalExpenses = (row.annual_rent || 0) + (row.annual_utilities || 0) + (row.annual_insurance || 0) + (row.annual_depreciation || 0);
    deduction = Math.round(totalExpenses * ratio * 100) / 100;
  }

  return { ...row, deduction: Math.round(deduction * 100) / 100 };
}

async function save({ body }) {
  const db = getDb();
  const { method, sqft, rate_per_sqft, max_sqft, total_home_sqft, annual_rent, annual_utilities, annual_insurance, annual_depreciation } = body || {};

  db.prepare(`
    UPDATE home_office SET
      method = COALESCE(?, method),
      sqft = COALESCE(?, sqft),
      rate_per_sqft = COALESCE(?, rate_per_sqft),
      max_sqft = COALESCE(?, max_sqft),
      total_home_sqft = COALESCE(?, total_home_sqft),
      annual_rent = COALESCE(?, annual_rent),
      annual_utilities = COALESCE(?, annual_utilities),
      annual_insurance = COALESCE(?, annual_insurance),
      annual_depreciation = COALESCE(?, annual_depreciation),
      updated_at = datetime('now')
    WHERE id = 1
  `).run(
    method || null, sqft ?? null, rate_per_sqft ?? null, max_sqft ?? null,
    total_home_sqft ?? null, annual_rent ?? null, annual_utilities ?? null,
    annual_insurance ?? null, annual_depreciation ?? null,
  );
  return get(); // Return updated with calculated deduction
}

module.exports = { get, save };
