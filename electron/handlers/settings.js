// Settings get/save — 从 worker/src/index.js 第 1218-1256 行迁移
const { getDb } = require('../db');

// 与原 worker 保持一致的白名单
// AI 模型选择已移到 ai_providers 表（每 provider 独立），settings 不再存 ai_model
const SETTINGS_ALLOWED_KEYS = new Set([
  'company_info',
  'tax_auto_auth',
  'notifications',
  'admin_expense_annual',
  'vat_rate',
  // 国际化 / 会计制度
  'accounting_locale',     // 'CN' | 'US' | 'JP' | 'EU' | 'KR' | 'TW'
  'surcharge_rate',        // 附加税率，中国 12，其他多 0
  'income_tax_rate',       // 企业所得税率
  'currency',              // 'CNY' / 'USD' / 'JPY' ...
  'ui_language',           // 'zh-CN' / 'en' / ...（备份用，主存储仍是 localStorage）
  'product_unit',          // 库存/数量单位：'unit'|'kg'|'ton'|'piece'|'box'|'bag'|'liter'（前端按此动态显示单位，未配置回退 'unit'→单位）
]);

async function get() {
  const db = getDb();
  const rows = db.prepare('SELECT key, value FROM settings').all();
  const settings = {};
  for (const row of rows) {
    if (!SETTINGS_ALLOWED_KEYS.has(row.key)) continue;
    try {
      settings[row.key] = JSON.parse(row.value);
    } catch {
      settings[row.key] = row.value;
    }
  }
  return settings;
}

async function save({ body }) {
  const db = getDb();
  const data = body || {};
  if (typeof data !== 'object' || Array.isArray(data)) {
    throw new Error('Request body must be a JSON object');
  }

  const skippedKeys = [];
  const upsert = db.prepare(
    "INSERT OR REPLACE INTO settings (key, value, updated_at) VALUES (?, ?, datetime('now'))"
  );

  const tx = db.transaction((entries) => {
    for (const [key, value] of entries) {
      if (!SETTINGS_ALLOWED_KEYS.has(key)) continue;
      const serialized = JSON.stringify(value);
      if (serialized.length > 10000) { skippedKeys.push(key); continue; }
      upsert.run(key, serialized);
    }
  });

  tx(Object.entries(data));

  return {
    success: true,
    ...(skippedKeys.length > 0 ? { warnings: `以下设置值过大被跳过: ${skippedKeys.join(', ')}` } : {}),
  };
}

module.exports = { get, save };
