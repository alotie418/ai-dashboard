// Settings get/save
const { getDb } = require('../db');
const { RATE_KEYS, rateValueIsUsable } = require('./_rateValue');

// 字段白名单
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
  // PR-7B P2-4a：管理口径留存收益 preview 所需（仅白名单·无 UI；取值校验在 retainedEarnings handler 读取侧）
  'entity_type',                 // 'individual'（默认）| 'company'
  'opening_retained_earnings',   // 期初未分配利润（本位币单一数值，允许负=累计亏损）
  // PR-7B P3-3：多币种参考折算 preview 所需（仅白名单·无 UI；JSON {币种:汇率}，rate=本位币/外币）
  'fx_reference_rates',          // 参考汇率 { "USD": 7.2, ... }；仅 fx-reference-conversion 只读消费，不写回、不抓实时
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

  const entries = Object.entries(data);

  // ── 税率类键的写侧封口(A4-1)────────────────────────────────────────────────
  //
  // 全部校验完再决定写不写:任何一个税率值不可用 → **整次请求失败,一个字节都不写**。
  // 刻意不做另外三件看起来更友好的事:
  //   • 不跳过那个键继续保存其余的 —— 那会让调用方拿到 success 却少存了一项;
  //   • 不改写成 null / 0 —— 那正是今天最坏的路径(NaN 经 JSON.stringify 变成
  //     字面量 null,再读回来是 0%,一次静默的税率变更);
  //   • 不部分保存 —— 事务在这之后才开始,所以失败时连已经合法的键也不落盘,
  //     调用方看到的状态与它发起请求前完全一致。
  //
  // 判定规则见 _rateValue.js,数字字符串("13")仍然合法,这是已发货路径的兼容点。
  const invalidRates = [];
  for (const [key, value] of entries) {
    if (!SETTINGS_ALLOWED_KEYS.has(key) || !RATE_KEYS.has(key)) continue;
    if (!rateValueIsUsable(value)) {
      invalidRates.push(`${key}=${JSON.stringify(value)}`);
      continue;
    }
    // 尺寸也在这里挡:税率键绝不能落进下面的 skippedKeys 分支,否则「不得跳过」
    // 就被一条 10000 字节的路径绕过去了。合法数字不可能这么长。
    if (JSON.stringify(value).length > 10000) invalidRates.push(`${key}=<oversized>`);
  }
  if (invalidRates.length > 0) {
    throw new Error(
      `Rate settings must be a finite number or a numeric string. Rejected: ${invalidRates.join(', ')}. ` +
      'Nothing was saved.'
    );
  }

  const skippedKeys = [];
  const upsert = db.prepare(
    "INSERT OR REPLACE INTO settings (key, value, updated_at) VALUES (?, ?, datetime('now'))"
  );

  const tx = db.transaction((rows) => {
    for (const [key, value] of rows) {
      if (!SETTINGS_ALLOWED_KEYS.has(key)) continue;
      const serialized = JSON.stringify(value);
      if (serialized.length > 10000) { skippedKeys.push(key); continue; }
      upsert.run(key, serialized);
    }
  });

  tx(entries);

  return {
    success: true,
    ...(skippedKeys.length > 0 ? { warnings: `以下设置值过大被跳过: ${skippedKeys.join(', ')}` } : {}),
  };
}

module.exports = { get, save };
