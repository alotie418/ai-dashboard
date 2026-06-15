// Alerts CRUD
const { getDb } = require('../db');

async function list({ query }) {
  const db = getDb();
  const unreadOnly = query.unread_only === 'true';
  const limit = Math.min(parseInt(query.limit, 10) || 20, 100);
  let sql = 'SELECT * FROM alerts WHERE is_dismissed = 0';
  if (unreadOnly) sql += ' AND is_read = 0';
  sql += ' ORDER BY created_at DESC LIMIT ?';
  return db.prepare(sql).all(limit);
}

async function count() {
  const db = getDb();
  const row = db.prepare('SELECT COUNT(*) as count FROM alerts WHERE is_read = 0 AND is_dismissed = 0').get();
  return { count: row.count };
}

async function markRead({ params }) {
  const db = getDb();
  const id = parseInt(params.id, 10);
  if (!Number.isFinite(id)) throw new Error('Invalid ID');
  db.prepare('UPDATE alerts SET is_read = 1 WHERE id = ?').run(id);
  return { success: true };
}

async function markAllRead() {
  const db = getDb();
  db.prepare('UPDATE alerts SET is_read = 1 WHERE is_read = 0').run();
  return { success: true };
}

async function dismiss({ params }) {
  const db = getDb();
  const id = parseInt(params.id, 10);
  if (!Number.isFinite(id)) throw new Error('Invalid ID');
  db.prepare('UPDATE alerts SET is_dismissed = 1 WHERE id = ?').run(id);
  return { success: true };
}

module.exports = { list, count, markRead, markAllRead, dismiss };
