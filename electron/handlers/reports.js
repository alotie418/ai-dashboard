// 报表生成 handler — D 阶段
// POST /api/reports/generate { locale, year, from, to }
// GET  /api/reports/types?locale=CN

const { getDb } = require('../db');
const reportEngine = require('../reports');

async function generate({ body, query }) {
  const db = getDb();
  const opts = body || query || {};
  return reportEngine.generate(db, {
    locale: opts.locale,
    year: opts.year,
    from: opts.from,
    to: opts.to,
  });
}

async function types({ query }) {
  return reportEngine.getAvailableReports(query.locale);
}

module.exports = { generate, types };
