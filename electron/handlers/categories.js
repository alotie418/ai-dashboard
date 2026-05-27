// Categories CRUD — 6 国会计类别管理
// 详见 docs/INTERNATIONALIZATION_PLAN.md §2.2

const { getDb } = require('../db');

const VALID_LOCALES = ['CN', 'US', 'JP', 'EU', 'KR', 'TW'];
const VALID_TYPES = ['income', 'expense'];
const VALID_LANGS = ['zh-CN', 'zh-TW', 'en', 'ja', 'ko', 'fr'];

function langToColumn(lang) {
  const map = { 'zh-CN': 'label_zh_cn', 'zh-TW': 'label_zh_tw', en: 'label_en', ja: 'label_ja', ko: 'label_ko', fr: 'label_fr' };
  return map[lang] || 'label_en';
}

function readSetting(key, fallback) {
  try {
    const db = getDb();
    const row = db.prepare('SELECT value FROM settings WHERE key = ?').get(key);
    return row ? JSON.parse(row.value) : fallback;
  } catch { return fallback; }
}

// GET /api/categories?locale=US&type=expense&lang=en
async function list({ query }) {
  const db = getDb();
  // 默认从 settings 读 accounting_locale
  const locale = query.locale || readSetting('accounting_locale', 'CN');
  const type = query.type; // 可选
  const lang = query.lang || 'en';

  if (!VALID_LOCALES.includes(locale)) throw new Error(`Invalid locale: ${locale}`);
  if (type && !VALID_TYPES.includes(type)) throw new Error(`Invalid type: ${type}`);

  let sql = `SELECT id, locale, type, slug, label_zh_cn, label_zh_tw, label_en, label_ja, label_ko, label_fr,
                    schedule_line, is_deductible, deductible_pct, parent_id, sort_order, is_system
             FROM categories WHERE locale = ?`;
  const params = [locale];
  if (type) {
    sql += ' AND type = ?';
    params.push(type);
  }
  sql += ' ORDER BY type, sort_order, slug';

  const rows = db.prepare(sql).all(...params);
  // 附加 displayLabel（按 lang 取对应列），方便前端展示
  const col = langToColumn(lang);
  return rows.map(r => ({
    ...r,
    displayLabel: r[col] || r.label_en || r.label_zh_cn || r.slug,
    is_deductible: !!r.is_deductible,
    is_system: !!r.is_system,
  }));
}

// POST /api/categories — 用户自建类别
async function create({ body }) {
  const db = getDb();
  const { locale, type, slug, label_zh_cn, label_en, label_zh_tw, label_ja, label_ko, label_fr,
          schedule_line, is_deductible, deductible_pct, parent_id, sort_order } = body || {};

  if (!VALID_LOCALES.includes(locale)) throw new Error(`locale must be one of ${VALID_LOCALES.join('/')}`);
  if (!VALID_TYPES.includes(type)) throw new Error(`type must be 'income' or 'expense'`);
  if (!slug || !/^[a-z0-9-]+$/.test(slug)) throw new Error('slug required, lowercase alphanumeric + hyphen only');
  if (!label_en && !label_zh_cn) throw new Error('At least one of label_en or label_zh_cn required');

  const id = `user-${locale.toLowerCase()}-${type}-${slug}-${Date.now().toString(36)}`;

  db.prepare(`
    INSERT INTO categories
      (id, locale, type, slug, label_zh_cn, label_zh_tw, label_en, label_ja, label_ko, label_fr,
       schedule_line, is_deductible, deductible_pct, parent_id, sort_order, is_system)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
  `).run(
    id, locale, type, slug,
    label_zh_cn || label_en || slug,
    label_zh_tw || null,
    label_en || label_zh_cn || slug,
    label_ja || null,
    label_ko || null,
    label_fr || null,
    schedule_line || null,
    is_deductible === false ? 0 : 1,
    deductible_pct == null ? 100 : deductible_pct,
    parent_id || null,
    sort_order || 999,
  );
  return { success: true, id };
}

// PUT /api/categories/:id
async function update({ params, body }) {
  const db = getDb();
  const id = params.id;
  if (!id) throw new Error('Invalid ID');

  const existing = db.prepare('SELECT is_system FROM categories WHERE id = ?').get(id);
  if (!existing) throw new Error('Category not found');
  if (existing.is_system) {
    // 系统类别只允许修改 label / sort_order，不允许动 slug / type / locale
    const { label_zh_cn, label_zh_tw, label_en, label_ja, label_ko, label_fr, sort_order, is_deductible, deductible_pct } = body || {};
    const sets = [];
    const vals = [];
    if (label_zh_cn !== undefined) { sets.push('label_zh_cn = ?'); vals.push(label_zh_cn); }
    if (label_zh_tw !== undefined) { sets.push('label_zh_tw = ?'); vals.push(label_zh_tw); }
    if (label_en !== undefined)    { sets.push('label_en = ?'); vals.push(label_en); }
    if (label_ja !== undefined)    { sets.push('label_ja = ?'); vals.push(label_ja); }
    if (label_ko !== undefined)    { sets.push('label_ko = ?'); vals.push(label_ko); }
    if (label_fr !== undefined)    { sets.push('label_fr = ?'); vals.push(label_fr); }
    if (sort_order !== undefined)  { sets.push('sort_order = ?'); vals.push(sort_order); }
    if (is_deductible !== undefined) { sets.push('is_deductible = ?'); vals.push(is_deductible ? 1 : 0); }
    if (deductible_pct !== undefined) { sets.push('deductible_pct = ?'); vals.push(deductible_pct); }
    if (sets.length === 0) return { success: true };
    vals.push(id);
    db.prepare(`UPDATE categories SET ${sets.join(', ')} WHERE id = ?`).run(...vals);
    return { success: true };
  }
  // 用户类别：允许全字段更新（除 id / is_system）
  const fields = ['label_zh_cn', 'label_zh_tw', 'label_en', 'label_ja', 'label_ko', 'label_fr',
                  'schedule_line', 'is_deductible', 'deductible_pct', 'parent_id', 'sort_order'];
  const sets = [];
  const vals = [];
  for (const f of fields) {
    if (body[f] !== undefined) {
      sets.push(`${f} = ?`);
      vals.push(f === 'is_deductible' ? (body[f] ? 1 : 0) : body[f]);
    }
  }
  if (sets.length === 0) return { success: true };
  vals.push(id);
  db.prepare(`UPDATE categories SET ${sets.join(', ')} WHERE id = ?`).run(...vals);
  return { success: true };
}

// DELETE /api/categories/:id
async function remove({ params }) {
  const db = getDb();
  const id = params.id;
  if (!id) throw new Error('Invalid ID');
  const row = db.prepare('SELECT is_system FROM categories WHERE id = ?').get(id);
  if (!row) throw new Error('Category not found');
  if (row.is_system) throw new Error('系统预置类别不可删除，可在设置中隐藏或编辑名称');
  db.prepare('DELETE FROM categories WHERE id = ?').run(id);
  return { success: true };
}

// POST /api/categories/reset — 重置当前 locale 的所有类别到预置默认（删除用户类别 + 恢复系统类别）
async function resetToDefault({ body }) {
  const db = getDb();
  const locale = body?.locale || readSetting('accounting_locale', 'CN');
  if (!VALID_LOCALES.includes(locale)) throw new Error(`Invalid locale: ${locale}`);

  const tx = db.transaction(() => {
    // 删除当前 locale 的用户类别
    const userDeleted = db.prepare('DELETE FROM categories WHERE locale = ? AND is_system = 0').run(locale);
    // 系统类别保持现状（v4 migration 已 seed；如有人手动 DELETE 也不重新插入——这是设计取舍）
    return userDeleted.changes;
  });
  const removed = tx();
  return { success: true, removedUserCategories: removed };
}

module.exports = { list, create, update, remove, resetToDefault };
