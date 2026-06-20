// Fixed-assets register — manual master data (PR-7D-3, pipeline layer)
//
// 固定资产登记台账。POLICY-NEUTRAL（政策中性）：
//   • 只做录入 / 保存 / 读取 / 编辑 / 删除·停用；
//   • 不折旧、不出净值(net book value)、不计提累计折旧、不生成折旧费用；
//   • 不编制资产负债表、不 roll-up、不碰 P&L/cashflow/reports；
//   • 无 depreciation_method/useful_life/salvage_value 字段（折旧政策输入，留 PR-7B）；
//   • category 为自由文本，无任何 B/S 科目 / 折旧年限映射；
//   • status='disposed' 仅为登记标签，不触发处置损益、不出表；
//   • original_value 仅用户手输（NaN→0，不 clamp、不强制 ≥0）。
// 以上越界项一律留待 PR-7B，且须会计确认。

const { getDb } = require('../db');

const ASSET_STATUSES = ['in_use', 'idle', 'disposed'];

// 数字强转：有限数原样保留，NaN/非数 → 0（与 accounts/liabilities opening_balance 一致）。
function toNum0(v) {
  const n = Number(v);
  return Number.isFinite(n) ? n : 0;
}

// GET /api/fixed-assets
async function list() {
  const db = getDb();
  const rows = db.prepare(
    `SELECT id, name, category, acquisition_date, original_value, currency, supplier, serial_no,
            note, status, is_active, sort_order, created_at, updated_at
       FROM fixed_assets ORDER BY is_active DESC, sort_order, created_at`
  ).all();
  return rows.map(r => ({ ...r, is_active: !!r.is_active }));
}

// POST /api/fixed-assets
async function create({ body }) {
  const db = getDb();
  const { name, category, acquisition_date, original_value, currency, supplier, serial_no,
          note, status, is_active, sort_order } = body || {};
  if (!name || !String(name).trim()) throw new Error('name required');
  const st = status || 'in_use';
  if (!ASSET_STATUSES.includes(st)) throw new Error(`status must be one of ${ASSET_STATUSES.join('/')}`);
  // 随机后缀防同毫秒撞 PRIMARY KEY（与 accounts/liabilities/products.create 同形）。
  const id = `asset-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`;
  db.prepare(
    `INSERT INTO fixed_assets (id, name, category, acquisition_date, original_value, currency,
                               supplier, serial_no, note, status, is_active, sort_order)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
  ).run(
    id,
    String(name).trim(),
    category != null && String(category).trim() ? String(category).trim() : null,
    acquisition_date || null,
    toNum0(original_value),
    currency ? String(currency).trim() : null,
    supplier != null && String(supplier).trim() ? String(supplier).trim() : null,
    serial_no != null && String(serial_no).trim() ? String(serial_no).trim() : null,
    note != null && String(note).trim() ? String(note).trim() : null,
    st,
    is_active === false ? 0 : 1,
    Number.isFinite(Number(sort_order)) ? Number(sort_order) : 999,
  );
  return { success: true, id };
}

// PUT /api/fixed-assets/:id
async function update({ params, body }) {
  const db = getDb();
  const id = params.id;
  if (!id) throw new Error('Invalid ID');
  const existing = db.prepare('SELECT id FROM fixed_assets WHERE id = ?').get(id);
  if (!existing) throw new Error('Fixed asset not found');

  const b = body || {};
  const sets = [];
  const vals = [];
  if (b.name !== undefined) {
    if (!String(b.name).trim()) throw new Error('name cannot be empty');
    sets.push('name = ?'); vals.push(String(b.name).trim());
  }
  if (b.category !== undefined) { sets.push('category = ?'); vals.push(b.category != null && String(b.category).trim() ? String(b.category).trim() : null); }
  if (b.acquisition_date !== undefined) { sets.push('acquisition_date = ?'); vals.push(b.acquisition_date || null); }
  if (b.original_value !== undefined) { sets.push('original_value = ?'); vals.push(toNum0(b.original_value)); }
  if (b.currency !== undefined) { sets.push('currency = ?'); vals.push(b.currency ? String(b.currency).trim() : null); }
  if (b.supplier !== undefined) { sets.push('supplier = ?'); vals.push(b.supplier != null && String(b.supplier).trim() ? String(b.supplier).trim() : null); }
  if (b.serial_no !== undefined) { sets.push('serial_no = ?'); vals.push(b.serial_no != null && String(b.serial_no).trim() ? String(b.serial_no).trim() : null); }
  if (b.note !== undefined) { sets.push('note = ?'); vals.push(b.note != null && String(b.note).trim() ? String(b.note).trim() : null); }
  if (b.status !== undefined) {
    if (!ASSET_STATUSES.includes(b.status)) throw new Error(`status must be one of ${ASSET_STATUSES.join('/')}`);
    sets.push('status = ?'); vals.push(b.status);
  }
  if (b.is_active !== undefined) { sets.push('is_active = ?'); vals.push(b.is_active ? 1 : 0); }
  if (b.sort_order !== undefined) { sets.push('sort_order = ?'); vals.push(Number(b.sort_order) || 0); }
  if (sets.length === 0) return { success: true };

  sets.push("updated_at = datetime('now')");
  vals.push(id);
  db.prepare(`UPDATE fixed_assets SET ${sets.join(', ')} WHERE id = ?`).run(...vals);
  return { success: true };
}

// DELETE /api/fixed-assets/:id
async function remove({ params }) {
  const db = getDb();
  const id = params.id;
  if (!id) throw new Error('Invalid ID');
  const row = db.prepare('SELECT id FROM fixed_assets WHERE id = ?').get(id);
  if (!row) throw new Error('Fixed asset not found');
  db.prepare('DELETE FROM fixed_assets WHERE id = ?').run(id);
  return { success: true };
}

module.exports = { list, create, update, remove };
