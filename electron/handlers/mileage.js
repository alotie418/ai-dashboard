// Mileage tracking handler — US Schedule C Line 9 (Car & Truck Expenses)
// IRS standard mileage rate: $0.67/mile (2024 business)

const { getDb } = require('../db');

async function list({ query }) {
  const db = getDb();
  const { from, to, limit } = query || {};
  const where = [];
  const params = [];
  if (from) { where.push('date >= ?'); params.push(from); }
  if (to) { where.push('date <= ?'); params.push(to); }
  let sql = 'SELECT * FROM mileage_logs';
  if (where.length) sql += ' WHERE ' + where.join(' AND ');
  sql += ' ORDER BY date DESC LIMIT ' + Math.min(parseInt(limit, 10) || 500, 5000);
  return db.prepare(sql).all(...params);
}

async function create({ body }) {
  const db = getDb();
  const { date, start_location, end_location, miles, purpose, round_trip, rate_per_mile } = body || {};
  if (!date || typeof miles !== 'number' || miles <= 0) throw new Error('date and miles > 0 required');
  const id = `mile-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`;
  db.prepare(`
    INSERT INTO mileage_logs (id, date, start_location, end_location, miles, purpose, round_trip, rate_per_mile)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
  `).run(id, date, start_location || null, end_location || null, miles, purpose || null, round_trip ? 1 : 0, rate_per_mile || 0.67);
  return { success: true, id };
}

async function update({ params, body }) {
  const db = getDb();
  const id = params.id;
  if (!id) throw new Error('Invalid ID');
  const fields = ['date', 'start_location', 'end_location', 'miles', 'purpose', 'round_trip', 'rate_per_mile'];
  const sets = [];
  const vals = [];
  for (const f of fields) {
    if (body[f] !== undefined) {
      sets.push(`${f} = ?`);
      vals.push(f === 'round_trip' ? (body[f] ? 1 : 0) : body[f]);
    }
  }
  if (sets.length === 0) return { success: true };
  vals.push(id);
  db.prepare(`UPDATE mileage_logs SET ${sets.join(', ')} WHERE id = ?`).run(...vals);
  return { success: true };
}

async function remove({ params }) {
  const db = getDb();
  db.prepare('DELETE FROM mileage_logs WHERE id = ?').run(params.id);
  return { success: true };
}

async function summary({ query }) {
  const db = getDb();
  const year = query.year || String(new Date().getFullYear());
  const row = db.prepare(`
    SELECT COUNT(*) as trips, COALESCE(SUM(miles), 0) as totalMiles,
           COALESCE(SUM(deduction), 0) as totalDeduction
    FROM mileage_logs WHERE date >= ? AND date <= ?
  `).get(`${year}-01-01`, `${year}-12-31`);
  return { year, trips: row.trips, totalMiles: Math.round(row.totalMiles * 100) / 100, totalDeduction: Math.round(row.totalDeduction * 100) / 100 };
}

module.exports = { list, create, update, remove, summary };
