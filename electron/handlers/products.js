// Products / service items CRUD — per-item unit master data (Phase 1)
// 商品/服务项目基础资料：单位由本表决定；服务类(is_service=1)后续不参与库存。
// 纯增量主数据，不引用/影响 purchases/sales/库存/Dashboard 计算。

const { getDb } = require('../db');

// Keys must mirror PRODUCT_UNIT_KEYS / INVENTORY_UNIT_LABELS in components/accountingHelpers.ts.
const VALID_UNITS = ['piece', 'box', 'bag', 'kg', 'ton', 'liter', 'bottle', 'pack', 'session', 'hour', 'month'];

// GET /api/products
async function list() {
  const db = getDb();
  const rows = db.prepare(
    `SELECT id, name, unit, default_unit_cost, is_service, is_active, sort_order, created_at, updated_at
       FROM products ORDER BY is_active DESC, sort_order, name`
  ).all();
  return rows.map(r => ({ ...r, is_service: !!r.is_service, is_active: !!r.is_active }));
}

// POST /api/products
async function create({ body }) {
  const db = getDb();
  const { name, unit, default_unit_cost, is_service, is_active, sort_order } = body || {};
  if (!name || !String(name).trim()) throw new Error('name required');
  const u = unit || 'piece';
  if (!VALID_UNITS.includes(u)) throw new Error(`unit must be one of ${VALID_UNITS.join('/')}`);
  const cost = Number(default_unit_cost);
  // 随机后缀防同毫秒重复创建撞 PRIMARY KEY（与 documents.create 同形）。
  const id = `prod-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`;
  db.prepare(
    `INSERT INTO products (id, name, unit, default_unit_cost, is_service, is_active, sort_order)
       VALUES (?, ?, ?, ?, ?, ?, ?)`
  ).run(
    id,
    String(name).trim(),
    u,
    Number.isFinite(cost) && cost >= 0 ? cost : 0,
    is_service ? 1 : 0,
    is_active === false ? 0 : 1,
    Number.isFinite(Number(sort_order)) ? Number(sort_order) : 999,
  );
  return { success: true, id };
}

// PUT /api/products/:id
async function update({ params, body }) {
  const db = getDb();
  const id = params.id;
  if (!id) throw new Error('Invalid ID');
  const existing = db.prepare('SELECT id FROM products WHERE id = ?').get(id);
  if (!existing) throw new Error('Product not found');

  const b = body || {};
  const sets = [];
  const vals = [];
  if (b.name !== undefined) {
    if (!String(b.name).trim()) throw new Error('name cannot be empty');
    sets.push('name = ?'); vals.push(String(b.name).trim());
  }
  if (b.unit !== undefined) {
    if (!VALID_UNITS.includes(b.unit)) throw new Error(`unit must be one of ${VALID_UNITS.join('/')}`);
    sets.push('unit = ?'); vals.push(b.unit);
  }
  if (b.default_unit_cost !== undefined) {
    const c = Number(b.default_unit_cost);
    sets.push('default_unit_cost = ?'); vals.push(Number.isFinite(c) && c >= 0 ? c : 0);
  }
  if (b.is_service !== undefined) { sets.push('is_service = ?'); vals.push(b.is_service ? 1 : 0); }
  if (b.is_active !== undefined) { sets.push('is_active = ?'); vals.push(b.is_active ? 1 : 0); }
  if (b.sort_order !== undefined) { sets.push('sort_order = ?'); vals.push(Number(b.sort_order) || 0); }
  if (sets.length === 0) return { success: true };

  sets.push("updated_at = datetime('now')");
  vals.push(id);
  db.prepare(`UPDATE products SET ${sets.join(', ')} WHERE id = ?`).run(...vals);
  return { success: true };
}

// DELETE /api/products/:id
async function remove({ params }) {
  const db = getDb();
  const id = params.id;
  if (!id) throw new Error('Invalid ID');
  const row = db.prepare('SELECT id FROM products WHERE id = ?').get(id);
  if (!row) throw new Error('Product not found');
  db.prepare('DELETE FROM products WHERE id = ?').run(id);
  return { success: true };
}

module.exports = { list, create, update, remove };
