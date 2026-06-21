// FX reference conversion preview — management-basis, read-only (PR-7B P3-3).
//
// 「多币种参考折算」只读预览。POLICY-NEUTRAL，**NOT 正式外币报表折算**：
//   • 把 balanceOverview 各币种 totals(assets/liabilities/equity)+balanceDifference 按用户参考汇率折成本位币「参考合计」；
//   • 汇率方向：converted = amount × rate，rate = 本位币/外币（USD:7.2 表示 1 USD = 7.2 CNY）；本位币 rate=1；
//   • 汇率来源：settings.fx_reference_rates(主) + query rates(覆盖·query 优先)；本 PR 无 UI；
//   • 缺汇率 → missingRates(missing)；非法汇率(≤0/NaN) → missingRates(invalid_rate)+warning；
//     无币种代码(null 块) → missingRates(no_currency_code)；以上均排除出 totalsReference；
//   • **仅供参考**：不写回、不改 balanceOverview 原值/byCurrency 分组、不生成汇兑损益、不进 P&L、不入账、不改 reports。

const { getDb } = require('../db');
const balanceOverview = require('./balanceOverview');   // 只读复用（不修改其输出）

const round2 = (n) => Math.round((Number(n) || 0) * 100) / 100;
const isValidRate = (r) => Number.isFinite(r) && r > 0;

function readSetting(db, key, fallback) {
  try {
    const row = db.prepare('SELECT value FROM settings WHERE key = ?').get(key);
    return row ? JSON.parse(row.value) : fallback;
  } catch { return fallback; }
}

// settings.fx_reference_rates → { ccy: Number(rate) }（原样数字化，valid/invalid 判定留主流程）。
function readSettingsRates(db) {
  const raw = readSetting(db, 'fx_reference_rates', {});
  const out = {};
  if (raw && typeof raw === 'object' && !Array.isArray(raw)) {
    for (const [k, v] of Object.entries(raw)) {
      if (k) out[String(k)] = Number(v);
    }
  }
  return out;
}

// query ?rates=USD:7.2,EUR:7.85 → { USD:7.2, EUR:7.85 }（Number 化，非法值留主流程判 invalid）。
function parseQueryRates(ratesStr) {
  const out = {};
  if (!ratesStr) return out;
  for (const pair of String(ratesStr).split(',')) {
    const [k, v] = pair.split(':');
    if (k && k.trim()) out[k.trim()] = Number(v);
  }
  return out;
}

// GET /api/fx-reference-conversion?from&to[&rates=USD:7.2,EUR:7.85]
async function convert({ query } = {}) {
  const db = getDb();
  const q = query || {};
  const year = q.year || String(new Date().getFullYear());
  const from = q.from || `${year}-01-01`;
  const to = q.to || `${year}-12-31`;
  const baseCurrency = readSetting(db, 'currency', 'CNY');

  // 汇率来源：settings 主 + query 覆盖（query 优先）。本位币恒 1（不可被覆盖）。
  const settingsRates = readSettingsRates(db);
  const queryRates = parseQueryRates(q.rates);
  const hasQuery = Object.keys(queryRates).length > 0;
  const hasSettings = Object.keys(settingsRates).length > 0;
  const rateSource = hasQuery && hasSettings ? 'merged' : hasQuery ? 'query' : 'settings';
  const mergedRates = { ...settingsRates, ...queryRates };
  mergedRates[baseCurrency] = 1;

  // 只读复用 balanceOverview（同 period·不改其输出）。
  const bo = await balanceOverview.overview({ query: { from, to } });

  const converted = [];
  const missingRates = [];
  const effectiveRates = { [baseCurrency]: 1 };
  const includedCurrencies = [];
  const excludedCurrencies = [];
  const tref = { assets: 0, liabilities: 0, equity: 0, balanceDifference: 0 };
  let hasInvalid = false;

  for (const blk of bo.byCurrency) {
    const ccy = blk.currency;
    if (ccy == null) {                                   // 无币种代码 → 无法匹配汇率
      missingRates.push({ currency: null, reason: 'no_currency_code' });
      excludedCurrencies.push(null);
      continue;
    }
    if (ccy !== baseCurrency && !(ccy in mergedRates)) { // 缺汇率
      missingRates.push({ currency: ccy, reason: 'missing' });
      excludedCurrencies.push(ccy);
      continue;
    }
    const rate = ccy === baseCurrency ? 1 : mergedRates[ccy];
    if (!isValidRate(rate)) {                             // 非法汇率（≤0/NaN）
      hasInvalid = true;
      missingRates.push({ currency: ccy, reason: 'invalid_rate' });
      excludedCurrencies.push(ccy);
      continue;
    }
    effectiveRates[ccy] = rate;
    const original = {
      assets: round2(blk.totals.assets),
      liabilities: round2(blk.totals.liabilities),
      equity: round2(blk.totals.equity),
      balanceDifference: round2(blk.balanceDifference),
    };
    const conv = {
      assets: round2(original.assets * rate),
      liabilities: round2(original.liabilities * rate),
      equity: round2(original.equity * rate),
      balanceDifference: round2(original.balanceDifference * rate),   // 负值符号保留
    };
    converted.push({ currency: ccy, rate, original, converted: conv });
    tref.assets += conv.assets;
    tref.liabilities += conv.liabilities;
    tref.equity += conv.equity;
    tref.balanceDifference += conv.balanceDifference;
    includedCurrencies.push(ccy);
  }

  const warnings = [];
  if (hasInvalid) warnings.push('invalidRatePresent');
  if (missingRates.some((m) => m.reason === 'missing' || m.reason === 'no_currency_code')) warnings.push('missingRatesPresent');

  return {
    estimate: true,
    reportType: 'fx_reference_conversion',   // 非法定
    period: { from, to },
    baseCurrency,
    source: 'user_reference_rates',
    rateSource,
    rates: effectiveRates,
    converted,
    missingRates,
    totalsReference: {
      baseCurrency,
      assets: round2(tref.assets),
      liabilities: round2(tref.liabilities),
      equity: round2(tref.equity),
      balanceDifference: round2(tref.balanceDifference),
      includedCurrencies,
      excludedCurrencies,
    },
    warnings,
    limitations: [
      '参考折算，仅供参考，非折算入账、非法定外币报表折算；按用户提供的参考汇率整体折算',
      `汇率方向：converted = 金额 × rate，rate = 本位币/外币（如 USD:7.2 表示 1 USD = 7.2 ${baseCurrency}）`,
      '汇率为用户参考值，非实时、非官方；缺汇率/非法汇率/无币种代码的币种不计入参考合计',
      '不生成汇兑损益、不入账、不改 byCurrency 原值；byCurrency 分列仍以原币种为准',
    ],
    disclaimerKey: 'disclaimer.report',
  };
}

module.exports = { convert };
