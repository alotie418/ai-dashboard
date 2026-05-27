// 报表生成 handler — D 阶段
// GET /api/reports/generate?locale=CN&year=2026&from=&to=
// GET /api/reports/types?locale=CN

const { getDb } = require('../db');
const reportEngine = require('../reports');

async function generate({ query }) {
  const db = getDb();
  return reportEngine.generate(db, {
    locale: query.locale,
    year: query.year,
    from: query.from,
    to: query.to,
  });
}

async function types({ query }) {
  return reportEngine.getAvailableReports(query.locale);
}

module.exports = { generate, types };
