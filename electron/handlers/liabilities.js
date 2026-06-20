// Liabilities / loans ledger — manual master data (PR-7D-2, pipeline layer)
//
// 负债 / 借款手工台账。POLICY-NEUTRAL（政策中性）：
//   • 只做录入 / 保存 / 读取 / 编辑 / 删除·结清；
//   • 这是借款/其他负债台账，**不是采购应付账款**（应付仍由 payables.js 从 purchases 聚合，本文件不碰）；
//   • 不编制资产负债表、不 roll-up、不做流动/非流动分类、不做还款计划、不算利息、不碰 P&L/cashflow/reports；
//   • opening_balance 仅用户手输（NaN→0，允许为负，不 clamp、不强制 ≥0）；
//   • interest_rate 仅作备查字段保存，默认 NULL，绝不参与任何计算。
// 以上越界项一律留待 PR-7B，且须会计确认。

const { getDb } = require('../db');

const LIABILITY_TYPES = ['loan', 'other'];

// 数字强转：有限数原样保留（允许负），NaN/非数 → 0。
function toNum0(v) {
  const n = Number(v);
  return Number.isFinite(n) ? n : 0;
}
// 可空数字：未传/空 → null；否则有限数保留，NaN → null（备查字段，不归零以区分「未填」）。
function toNumOrNull(v) {
  if (v === undefined || v === null || v === '') return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}

// GET /api/liabilities
async function list() {
  const db = getDb();
  const rows = db.prepare(
    `SELECT id, name, lender, liability_type, currency, principal, opening_balance, opening_date,
            interest_rate, maturity_date, note, is_active, sort_order, created_at, updated_at
       FROM liabilities ORDER BY is_active DESC, sort_order, created_at`
  ).all();
  return rows.map(r => ({ ...r, is_active: !!r.is_active }));
}

// POST /api/liabilities
async function create({ body }) {
  const db = getDb();
  const { name, lender, liability_type, currency, principal, opening_balance, opening_date,
          interest_rate, maturity_date, note, is_active, sort_order } = body || {};
  if (!name || !String(name).trim()) throw new Error('name required');
  const lt = liability_type || 'loan';
  if (!LIABILITY_TYPES.includes(lt)) throw new Error(`liability_type must be one of ${LIABILITY_TYPES.join('/')}`);
  // 随机后缀防同毫秒撞 PRIMARY KEY（与 accounts/products.create 同形）。
  const id = `liab-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`;
  db.prepare(
    `INSERT INTO liabilities (id, name, lender, liability_type, currency, principal, opening_balance,
                              opening_date, interest_rate, maturity_date, note, is_active, sort_order)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
  ).run(
    id,
    String(name).trim(),
    lender != null && String(lender).trim() ? String(lender).trim() : null,
    lt,
    currency ? String(currency).trim() : null,
    toNumOrNull(principal),
    toNum0(opening_balance),
    opening_date || null,
    toNumOrNull(interest_rate),
    maturity_date || null,
    note != null && String(note).trim() ? String(note).trim() : null,
    is_active === false ? 0 : 1,
    Number.isFinite(Number(sort_order)) ? Number(sort_order) : 999,
  );
  return { success: true, id };
}

// PUT /api/liabilities/:id
async function update({ params, body }) {
  const db = getDb();
  const id = params.id;
  if (!id) throw new Error('Invalid ID');
  const existing = db.prepare('SELECT id FROM liabilities WHERE id = ?').get(id);
  if (!existing) throw new Error('Liability not found');

  const b = body || {};
  const sets = [];
  const vals = [];
  if (b.name !== undefined) {
    if (!String(b.name).trim()) throw new Error('name cannot be empty');
    sets.push('name = ?'); vals.push(String(b.name).trim());
  }
  if (b.lender !== undefined) { sets.push('lender = ?'); vals.push(b.lender != null && String(b.lender).trim() ? String(b.lender).trim() : null); }
  if (b.liability_type !== undefined) {
    if (!LIABILITY_TYPES.includes(b.liability_type)) throw new Error(`liability_type must be one of ${LIABILITY_TYPES.join('/')}`);
    sets.push('liability_type = ?'); vals.push(b.liability_type);
  }
  if (b.currency !== undefined) { sets.push('currency = ?'); vals.push(b.currency ? String(b.currency).trim() : null); }
  if (b.principal !== undefined) { sets.push('principal = ?'); vals.push(toNumOrNull(b.principal)); }
  if (b.opening_balance !== undefined) { sets.push('opening_balance = ?'); vals.push(toNum0(b.opening_balance)); }
  if (b.opening_date !== undefined) { sets.push('opening_date = ?'); vals.push(b.opening_date || null); }
  if (b.interest_rate !== undefined) { sets.push('interest_rate = ?'); vals.push(toNumOrNull(b.interest_rate)); }
  if (b.maturity_date !== undefined) { sets.push('maturity_date = ?'); vals.push(b.maturity_date || null); }
  if (b.note !== undefined) { sets.push('note = ?'); vals.push(b.note != null && String(b.note).trim() ? String(b.note).trim() : null); }
  if (b.is_active !== undefined) { sets.push('is_active = ?'); vals.push(b.is_active ? 1 : 0); }
  if (b.sort_order !== undefined) { sets.push('sort_order = ?'); vals.push(Number(b.sort_order) || 0); }
  if (sets.length === 0) return { success: true };

  sets.push("updated_at = datetime('now')");
  vals.push(id);
  db.prepare(`UPDATE liabilities SET ${sets.join(', ')} WHERE id = ?`).run(...vals);
  return { success: true };
}

// DELETE /api/liabilities/:id
async function remove({ params }) {
  const db = getDb();
  const id = params.id;
  if (!id) throw new Error('Invalid ID');
  const row = db.prepare('SELECT id FROM liabilities WHERE id = ?').get(id);
  if (!row) throw new Error('Liability not found');
  db.prepare('DELETE FROM liabilities WHERE id = ?').run(id);
  return { success: true };
}

module.exports = { list, create, update, remove };
