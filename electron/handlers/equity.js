// Equity / capital ledger — manual master data (PR-7D-4, pipeline layer)
//
// 权益/资本手工登记台账。POLICY-NEUTRAL（政策中性）：
//   • 只做录入 / 保存 / 读取 / 编辑 / 删除·停用；
//   • 不做所有者权益合计、不做资产负债表/平衡；
//   • 不做留存收益/未分配利润/本年利润/资本公积/盈余公积的计算或结转；
//   • equity_type 仅中性登记分类，不映射任何制度科目码，不自动对应实收资本等科目；
//   • amount 仅用户手输（NaN→0，不 clamp、允许负，系统不解释方向、不汇总、不勾稽）；
//   • 不联动 accounts/transactions/P&L/cashflow/reports，不点亮 PR-7B 预留 key。
// 以上越界项一律留待 PR-7B，且须会计确认。

const { getDb } = require('../db');

const EQUITY_TYPES = ['capital_contribution', 'owner_draw', 'adjustment', 'other'];

// 数字强转：有限数原样保留（允许负），NaN/非数 → 0（与前三表金额字段一致）。
function toNum0(v) {
  const n = Number(v);
  return Number.isFinite(n) ? n : 0;
}

// GET /api/equity
async function list() {
  const db = getDb();
  const rows = db.prepare(
    `SELECT id, name, owner, equity_type, amount, currency, event_date, note,
            is_active, sort_order, created_at, updated_at
       FROM equity ORDER BY is_active DESC, sort_order, created_at`
  ).all();
  return rows.map(r => ({ ...r, is_active: !!r.is_active }));
}

// POST /api/equity
async function create({ body }) {
  const db = getDb();
  const { name, owner, equity_type, amount, currency, event_date, note, is_active, sort_order } = body || {};
  if (!name || !String(name).trim()) throw new Error('name required');
  const et = equity_type || 'capital_contribution';
  if (!EQUITY_TYPES.includes(et)) throw new Error(`equity_type must be one of ${EQUITY_TYPES.join('/')}`);
  // 随机后缀防同毫秒撞 PRIMARY KEY（与 accounts/liabilities/fixedAssets.create 同形）。
  const id = `equity-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`;
  db.prepare(
    `INSERT INTO equity (id, name, owner, equity_type, amount, currency, event_date, note, is_active, sort_order)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
  ).run(
    id,
    String(name).trim(),
    owner != null && String(owner).trim() ? String(owner).trim() : null,
    et,
    toNum0(amount),
    currency ? String(currency).trim() : null,
    event_date || null,
    note != null && String(note).trim() ? String(note).trim() : null,
    is_active === false ? 0 : 1,
    Number.isFinite(Number(sort_order)) ? Number(sort_order) : 999,
  );
  return { success: true, id };
}

// PUT /api/equity/:id
async function update({ params, body }) {
  const db = getDb();
  const id = params.id;
  if (!id) throw new Error('Invalid ID');
  const existing = db.prepare('SELECT id FROM equity WHERE id = ?').get(id);
  if (!existing) throw new Error('Equity entry not found');

  const b = body || {};
  const sets = [];
  const vals = [];
  if (b.name !== undefined) {
    if (!String(b.name).trim()) throw new Error('name cannot be empty');
    sets.push('name = ?'); vals.push(String(b.name).trim());
  }
  if (b.owner !== undefined) { sets.push('owner = ?'); vals.push(b.owner != null && String(b.owner).trim() ? String(b.owner).trim() : null); }
  if (b.equity_type !== undefined) {
    if (!EQUITY_TYPES.includes(b.equity_type)) throw new Error(`equity_type must be one of ${EQUITY_TYPES.join('/')}`);
    sets.push('equity_type = ?'); vals.push(b.equity_type);
  }
  if (b.amount !== undefined) { sets.push('amount = ?'); vals.push(toNum0(b.amount)); }
  if (b.currency !== undefined) { sets.push('currency = ?'); vals.push(b.currency ? String(b.currency).trim() : null); }
  if (b.event_date !== undefined) { sets.push('event_date = ?'); vals.push(b.event_date || null); }
  if (b.note !== undefined) { sets.push('note = ?'); vals.push(b.note != null && String(b.note).trim() ? String(b.note).trim() : null); }
  if (b.is_active !== undefined) { sets.push('is_active = ?'); vals.push(b.is_active ? 1 : 0); }
  if (b.sort_order !== undefined) { sets.push('sort_order = ?'); vals.push(Number(b.sort_order) || 0); }
  if (sets.length === 0) return { success: true };

  sets.push("updated_at = datetime('now')");
  vals.push(id);
  db.prepare(`UPDATE equity SET ${sets.join(', ')} WHERE id = ?`).run(...vals);
  return { success: true };
}

// DELETE /api/equity/:id
async function remove({ params }) {
  const db = getDb();
  const id = params.id;
  if (!id) throw new Error('Invalid ID');
  const row = db.prepare('SELECT id FROM equity WHERE id = ?').get(id);
  if (!row) throw new Error('Equity entry not found');
  db.prepare('DELETE FROM equity WHERE id = ?').run(id);
  return { success: true };
}

module.exports = { list, create, update, remove };
