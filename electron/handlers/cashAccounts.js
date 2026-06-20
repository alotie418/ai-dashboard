// Cash / bank accounts + opening balance — master data (PR-7D-1, pipeline layer)
//
// 现金/银行账户与期初余额主数据。POLICY-NEUTRAL（政策中性）：
//   • 只做录入 / 保存 / 读取 / 编辑 / 删除·停用；
//   • 不编制资产负债表、不 roll-up、不做任何平衡断言（资产=负债+权益 属 PR-7B）；
//   • opening_balance 仅为用户手输数字，不与任何流水勾稽、不自动跟 sales/purchases/transactions 联动；
//   • 不含任何会计公式 / 折旧 / 权益结转 / 税款对冲 / 制度科目码映射。
// 以上越界项一律留待 PR-7B，且须会计确认。文件名 cashAccounts 以避开 router 里
// 既有的 `accounts`（= receivables/payables）变量名。
//
// 注意：opening_balance 允许为负（银行透支 / 信用账户），故仅把 NaN 归零，不 clamp 负值。

const { getDb } = require('../db');

const ACCOUNT_TYPES = ['cash', 'bank'];

// GET /api/accounts
async function list() {
  const db = getDb();
  const rows = db.prepare(
    `SELECT id, name, type, currency, opening_balance, opening_date, note, is_active, sort_order, created_at, updated_at
       FROM accounts ORDER BY is_active DESC, sort_order, created_at`
  ).all();
  return rows.map(r => ({ ...r, is_active: !!r.is_active }));
}

// POST /api/accounts
async function create({ body }) {
  const db = getDb();
  const { name, type, currency, opening_balance, opening_date, note, is_active, sort_order } = body || {};
  if (!name || !String(name).trim()) throw new Error('name required');
  const t = type || 'cash';
  if (!ACCOUNT_TYPES.includes(t)) throw new Error(`type must be one of ${ACCOUNT_TYPES.join('/')}`);
  const ob = Number(opening_balance);
  // 随机后缀防同毫秒重复创建撞 PRIMARY KEY（与 products/documents.create 同形）。
  const id = `acct-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`;
  db.prepare(
    `INSERT INTO accounts (id, name, type, currency, opening_balance, opening_date, note, is_active, sort_order)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`
  ).run(
    id,
    String(name).trim(),
    t,
    currency ? String(currency).trim() : null,
    Number.isFinite(ob) ? ob : 0,
    opening_date || null,
    note != null && String(note).trim() ? String(note).trim() : null,
    is_active === false ? 0 : 1,
    Number.isFinite(Number(sort_order)) ? Number(sort_order) : 999,
  );
  return { success: true, id };
}

// PUT /api/accounts/:id
async function update({ params, body }) {
  const db = getDb();
  const id = params.id;
  if (!id) throw new Error('Invalid ID');
  const existing = db.prepare('SELECT id FROM accounts WHERE id = ?').get(id);
  if (!existing) throw new Error('Account not found');

  const b = body || {};
  const sets = [];
  const vals = [];
  if (b.name !== undefined) {
    if (!String(b.name).trim()) throw new Error('name cannot be empty');
    sets.push('name = ?'); vals.push(String(b.name).trim());
  }
  if (b.type !== undefined) {
    if (!ACCOUNT_TYPES.includes(b.type)) throw new Error(`type must be one of ${ACCOUNT_TYPES.join('/')}`);
    sets.push('type = ?'); vals.push(b.type);
  }
  if (b.currency !== undefined) { sets.push('currency = ?'); vals.push(b.currency ? String(b.currency).trim() : null); }
  if (b.opening_balance !== undefined) {
    const ob = Number(b.opening_balance);
    sets.push('opening_balance = ?'); vals.push(Number.isFinite(ob) ? ob : 0);
  }
  if (b.opening_date !== undefined) { sets.push('opening_date = ?'); vals.push(b.opening_date || null); }
  if (b.note !== undefined) { sets.push('note = ?'); vals.push(b.note != null && String(b.note).trim() ? String(b.note).trim() : null); }
  if (b.is_active !== undefined) { sets.push('is_active = ?'); vals.push(b.is_active ? 1 : 0); }
  if (b.sort_order !== undefined) { sets.push('sort_order = ?'); vals.push(Number(b.sort_order) || 0); }
  if (sets.length === 0) return { success: true };

  sets.push("updated_at = datetime('now')");
  vals.push(id);
  db.prepare(`UPDATE accounts SET ${sets.join(', ')} WHERE id = ?`).run(...vals);
  return { success: true };
}

// DELETE /api/accounts/:id
async function remove({ params }) {
  const db = getDb();
  const id = params.id;
  if (!id) throw new Error('Invalid ID');
  const row = db.prepare('SELECT id FROM accounts WHERE id = ?').get(id);
  if (!row) throw new Error('Account not found');
  db.prepare('DELETE FROM accounts WHERE id = ?').run(id);
  return { success: true };
}

module.exports = { list, create, update, remove };
