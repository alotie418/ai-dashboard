// Tax-payments ledger — manual master data (PR-7D-5, pipeline layer)
//
// 已缴税款手工登记台账（历史缴税流水记录）。POLICY-NEUTRAL（政策中性）：
//   • 只做录入 / 保存 / 读取 / 编辑 / 删除·停用；
//   • 不计算应交税费、不算税率、不抵扣 VAT、不对冲所得税/附加税；
//   • 不确认税费费用（不进 P&L）、不进 cashflow、不联动 accounts/transactions；
//   • 不接资产负债表、不 rollup 应交/已交税费；
//   • 不与报表既有税额估算（estimatedPayable/estimatedTax/vatSummary）做任何勾稽·抵扣·对冲·汇总；
//   • tax_type 仅中性登记分类，不映射任何制度科目码、不触发任何税务计算；
//   • amount 仅用户手输（NaN→0，不 clamp、允许负——仅用于退税/冲正/多缴退回，系统不解释方向、不抵扣、不汇总）；
//   • handler 内零税率字面量（不写任何税率数字）。
// 以上越界项一律留待 PR-7B / 后续税务政策 PR，且须会计确认。

const { getDb } = require('../db');

const TAX_TYPES = ['vat', 'income_tax', 'surcharge', 'payroll_tax', 'sales_tax', 'other'];

// 数字强转：有限数原样保留（允许负），NaN/非数 → 0（与前四表金额字段一致）。
function toNum0(v) {
  const n = Number(v);
  return Number.isFinite(n) ? n : 0;
}

// GET /api/tax-payments
async function list() {
  const db = getDb();
  const rows = db.prepare(
    `SELECT id, name, tax_type, amount, currency, payment_date, period_start, period_end,
            authority, reference_no, note, is_active, sort_order, created_at, updated_at
       FROM tax_payments ORDER BY is_active DESC, sort_order, created_at`
  ).all();
  return rows.map(r => ({ ...r, is_active: !!r.is_active }));
}

// POST /api/tax-payments
async function create({ body }) {
  const db = getDb();
  const { name, tax_type, amount, currency, payment_date, period_start, period_end,
          authority, reference_no, note, is_active, sort_order } = body || {};
  if (!name || !String(name).trim()) throw new Error('name required');
  const tt = tax_type || 'vat';
  if (!TAX_TYPES.includes(tt)) throw new Error(`tax_type must be one of ${TAX_TYPES.join('/')}`);
  // 随机后缀防同毫秒撞 PRIMARY KEY（与 accounts/liabilities/fixedAssets/equity.create 同形）。
  const id = `taxpay-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`;
  db.prepare(
    `INSERT INTO tax_payments (id, name, tax_type, amount, currency, payment_date, period_start,
                               period_end, authority, reference_no, note, is_active, sort_order)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
  ).run(
    id,
    String(name).trim(),
    tt,
    toNum0(amount),
    currency ? String(currency).trim() : null,
    payment_date || null,
    period_start || null,
    period_end || null,
    authority != null && String(authority).trim() ? String(authority).trim() : null,
    reference_no != null && String(reference_no).trim() ? String(reference_no).trim() : null,
    note != null && String(note).trim() ? String(note).trim() : null,
    is_active === false ? 0 : 1,
    Number.isFinite(Number(sort_order)) ? Number(sort_order) : 999,
  );
  return { success: true, id };
}

// PUT /api/tax-payments/:id
async function update({ params, body }) {
  const db = getDb();
  const id = params.id;
  if (!id) throw new Error('Invalid ID');
  const existing = db.prepare('SELECT id FROM tax_payments WHERE id = ?').get(id);
  if (!existing) throw new Error('Tax payment not found');

  const b = body || {};
  const sets = [];
  const vals = [];
  if (b.name !== undefined) {
    if (!String(b.name).trim()) throw new Error('name cannot be empty');
    sets.push('name = ?'); vals.push(String(b.name).trim());
  }
  if (b.tax_type !== undefined) {
    if (!TAX_TYPES.includes(b.tax_type)) throw new Error(`tax_type must be one of ${TAX_TYPES.join('/')}`);
    sets.push('tax_type = ?'); vals.push(b.tax_type);
  }
  if (b.amount !== undefined) { sets.push('amount = ?'); vals.push(toNum0(b.amount)); }
  if (b.currency !== undefined) { sets.push('currency = ?'); vals.push(b.currency ? String(b.currency).trim() : null); }
  if (b.payment_date !== undefined) { sets.push('payment_date = ?'); vals.push(b.payment_date || null); }
  if (b.period_start !== undefined) { sets.push('period_start = ?'); vals.push(b.period_start || null); }
  if (b.period_end !== undefined) { sets.push('period_end = ?'); vals.push(b.period_end || null); }
  if (b.authority !== undefined) { sets.push('authority = ?'); vals.push(b.authority != null && String(b.authority).trim() ? String(b.authority).trim() : null); }
  if (b.reference_no !== undefined) { sets.push('reference_no = ?'); vals.push(b.reference_no != null && String(b.reference_no).trim() ? String(b.reference_no).trim() : null); }
  if (b.note !== undefined) { sets.push('note = ?'); vals.push(b.note != null && String(b.note).trim() ? String(b.note).trim() : null); }
  if (b.is_active !== undefined) { sets.push('is_active = ?'); vals.push(b.is_active ? 1 : 0); }
  if (b.sort_order !== undefined) { sets.push('sort_order = ?'); vals.push(Number(b.sort_order) || 0); }
  if (sets.length === 0) return { success: true };

  sets.push("updated_at = datetime('now')");
  vals.push(id);
  db.prepare(`UPDATE tax_payments SET ${sets.join(', ')} WHERE id = ?`).run(...vals);
  return { success: true };
}

// DELETE /api/tax-payments/:id
async function remove({ params }) {
  const db = getDb();
  const id = params.id;
  if (!id) throw new Error('Invalid ID');
  const row = db.prepare('SELECT id FROM tax_payments WHERE id = ?').get(id);
  if (!row) throw new Error('Tax payment not found');
  db.prepare('DELETE FROM tax_payments WHERE id = ?').run(id);
  return { success: true };
}

module.exports = { list, create, update, remove };
