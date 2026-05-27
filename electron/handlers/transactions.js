// transactions CRUD — 国际化数据模型核心实体
// 详见 docs/INTERNATIONALIZATION_PLAN.md §2.3
//
// 与旧 sales/purchases 的区别：
//   - 单表用 type=income/expense 区分（替代两张表）
//   - 通过 category_id 关联到对应国家的会计类别
//   - 业务隐喻不再绑定中国 VAT（tons/含税分离字段保留可空，给 CN 用户填）
//   - description 自由文本承接旧的「吨位 / 单价 / 运费」展示需求

const { getDb } = require('../db');

const VALID_TYPES = ['income', 'expense'];
const VALID_INVOICE_STATUS = ['issued', 'pending', 'n/a'];
const VALID_PAYMENT_STATUS = ['paid', 'partial', 'unpaid'];

function safeString(v, maxLen = 500) {
  if (v == null) return '';
  return String(v).slice(0, maxLen);
}

function validate(data) {
  const errors = [];
  if (!data.id) errors.push('id required');
  if (!data.type || !VALID_TYPES.includes(data.type)) errors.push('type must be income or expense');
  if (!data.date) errors.push('date required');
  if (typeof data.amount !== 'number' || !Number.isFinite(data.amount)) errors.push('amount must be a number');
  if (data.invoice_status && !VALID_INVOICE_STATUS.includes(data.invoice_status)) {
    errors.push(`invoice_status must be one of ${VALID_INVOICE_STATUS.join('/')}`);
  }
  if (data.payment_status && !VALID_PAYMENT_STATUS.includes(data.payment_status)) {
    errors.push(`payment_status must be one of ${VALID_PAYMENT_STATUS.join('/')}`);
  }
  return errors;
}

function normalize(data) {
  return {
    id: data.id,
    type: data.type,
    date: data.date,
    amount: Number(data.amount) || 0,
    amount_net: data.amount_net != null ? Number(data.amount_net) : null,
    tax_amount: Number(data.tax_amount) || 0,
    tax_rate: Number(data.tax_rate) || 0,
    currency: safeString(data.currency || 'CNY', 8),
    category_id: data.category_id ? safeString(data.category_id, 100) : null,
    counterparty: safeString(data.counterparty, 200),
    invoice_no: safeString(data.invoice_no, 100),
    invoice_status: data.invoice_status || 'n/a',
    payment_status: data.payment_status || 'paid',
    paid_amount: Number(data.paid_amount) || 0,
    payment_date: data.payment_date || null,
    due_date: data.due_date || null,
    description: safeString(data.description, 1000),
    attachment_path: data.attachment_path || null,
    source_meta: data.source_meta ? (typeof data.source_meta === 'string' ? data.source_meta : JSON.stringify(data.source_meta)) : null,
  };
}

// GET /api/transactions?type=income|expense&from=YYYY-MM-DD&to=YYYY-MM-DD&category_id=...&limit=200
async function list({ query }) {
  const db = getDb();
  const { type, from, to, category_id, limit } = query || {};

  const where = [];
  const params = [];
  if (type && VALID_TYPES.includes(type)) { where.push('type = ?'); params.push(type); }
  if (from) { where.push('date >= ?'); params.push(from); }
  if (to)   { where.push('date <= ?'); params.push(to); }
  if (category_id) { where.push('category_id = ?'); params.push(category_id); }

  let sql = 'SELECT * FROM transactions';
  if (where.length > 0) sql += ' WHERE ' + where.join(' AND ');
  sql += ' ORDER BY date DESC, created_at DESC';

  const lim = Math.min(Math.max(parseInt(limit, 10) || 500, 1), 5000);
  sql += ` LIMIT ${lim}`;

  return db.prepare(sql).all(...params);
}

// GET /api/transactions/:id
async function get({ params }) {
  const db = getDb();
  const row = db.prepare('SELECT * FROM transactions WHERE id = ?').get(params.id);
  if (!row) throw new Error('Transaction not found');
  return row;
}

// POST /api/transactions
async function create({ body }) {
  const db = getDb();
  const data = normalize(body || {});
  const errors = validate(data);
  if (errors.length > 0) throw new Error(errors.join('; '));

  db.prepare(`
    INSERT INTO transactions
      (id, type, date, amount, amount_net, tax_amount, tax_rate, currency,
       category_id, counterparty, invoice_no, invoice_status,
       payment_status, paid_amount, payment_date, due_date,
       description, attachment_path, source_meta)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `).run(
    data.id, data.type, data.date, data.amount, data.amount_net, data.tax_amount, data.tax_rate, data.currency,
    data.category_id, data.counterparty, data.invoice_no, data.invoice_status,
    data.payment_status, data.paid_amount, data.payment_date, data.due_date,
    data.description, data.attachment_path, data.source_meta,
  );
  return { success: true, id: data.id };
}

// PUT /api/transactions/:id
async function update({ params, body }) {
  const db = getDb();
  const id = params.id;
  if (!id) throw new Error('Invalid ID');
  const existing = db.prepare('SELECT 1 FROM transactions WHERE id = ?').get(id);
  if (!existing) throw new Error('Transaction not found');

  const data = normalize({ ...body, id });
  const errors = validate(data);
  if (errors.length > 0) throw new Error(errors.join('; '));

  db.prepare(`
    UPDATE transactions SET
      type = ?, date = ?, amount = ?, amount_net = ?, tax_amount = ?, tax_rate = ?, currency = ?,
      category_id = ?, counterparty = ?, invoice_no = ?, invoice_status = ?,
      payment_status = ?, paid_amount = ?, payment_date = ?, due_date = ?,
      description = ?, attachment_path = ?, source_meta = ?,
      updated_at = datetime('now')
    WHERE id = ?
  `).run(
    data.type, data.date, data.amount, data.amount_net, data.tax_amount, data.tax_rate, data.currency,
    data.category_id, data.counterparty, data.invoice_no, data.invoice_status,
    data.payment_status, data.paid_amount, data.payment_date, data.due_date,
    data.description, data.attachment_path, data.source_meta,
    id,
  );
  return { success: true };
}

// DELETE /api/transactions/:id
async function remove({ params }) {
  const db = getDb();
  const id = params.id;
  if (!id) throw new Error('Invalid ID');
  // 同时清除 legacy_migrations 映射，避免后续误算"已迁移"
  const tx = db.transaction(() => {
    db.prepare('DELETE FROM legacy_migrations WHERE new_id = ?').run(id);
    db.prepare('DELETE FROM transactions WHERE id = ?').run(id);
  });
  tx();
  return { success: true };
}

// GET /api/transactions/summary?from=...&to=...
// 简单按 type 求和，按需扩展
async function summary({ query }) {
  const db = getDb();
  const { from, to } = query || {};
  const where = [];
  const params = [];
  if (from) { where.push('date >= ?'); params.push(from); }
  if (to)   { where.push('date <= ?'); params.push(to); }
  const whereClause = where.length > 0 ? 'WHERE ' + where.join(' AND ') : '';

  const incomeRow = db.prepare(
    `SELECT COALESCE(SUM(amount), 0) AS total, COUNT(*) AS count FROM transactions WHERE type = 'income' ${where.length ? ' AND ' + where.join(' AND ') : ''}`
  ).get(...params);
  const expenseRow = db.prepare(
    `SELECT COALESCE(SUM(amount), 0) AS total, COUNT(*) AS count FROM transactions WHERE type = 'expense' ${where.length ? ' AND ' + where.join(' AND ') : ''}`
  ).get(...params);

  return {
    income: { total: incomeRow.total, count: incomeRow.count },
    expense: { total: expenseRow.total, count: expenseRow.count },
    net: incomeRow.total - expenseRow.total,
  };
}

module.exports = { list, get, create, update, remove, summary };
