// Depreciation preview — read-only straight-line depreciation (PR-7B P2-2).
//
// 固定资产直线法折旧「只读预览」。POLICY-NEUTRAL：
//   • 计算每资产 累计折旧 / 账面净值 / 月折旧，**只读不写回 fixed_assets**；
//   • 仅 straight_line；空 useful_life_months / salvage_rate 回退类别默认（_depreciationDefaults）；
//   • next_month / same_month 起算；daily → fallback 到 next_month 口径 + warning；
//   • disposed 有日期 → 处置次月停止；无日期 → 按 asOf 估算 + warning；**disposed 不计入 totals**；
//   • 多币种分别列示、不折算、不跨币种合计；
//   • **不做处置损益、不进 P&L、不接 balanceOverview、不改 reports、不改 schema、不改历史。**

const { getDb } = require('../db');
const { DEPRECIATION_DEFAULTS, resolveCategory } = require('./_depreciationDefaults');

const round2 = (n) => Math.round((Number(n) || 0) * 100) / 100;

function tableExists(db, name) {
  return !!db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name=?").get(name);
}
function readBaseCurrency(db) {
  try {
    const row = db.prepare('SELECT value FROM settings WHERE key = ?').get('currency');
    return row ? JSON.parse(row.value) : 'CNY';
  } catch { return 'CNY'; }
}
// 'YYYY-MM-DD' → 月序号 year*12+(month-1)；无效/空 → null。
function monthIndex(dateStr) {
  const m = /^(\d{4})-(\d{2})/.exec(String(dateStr || ''));
  return m ? Number(m[1]) * 12 + (Number(m[2]) - 1) : null;
}

// GET /api/depreciation-preview?asOf=YYYY-MM-DD  (或 ?year=YYYY → asOf=year-12-31)
async function preview({ query } = {}) {
  const db = getDb();
  const q = query || {};
  const year = q.year || String(new Date().getFullYear());
  const asOf = q.asOf || `${year}-12-31`;
  const asOfIdx = monthIndex(asOf);
  const baseCurrency = readBaseCurrency(db);

  const COMMON = {
    estimate: true,
    reportType: 'depreciation_preview',
    asOf,
    baseCurrency,
    disclaimerKey: 'disclaimer.report',
    limitations: [
      '直线法折旧估算（管理口径），非法定/税务折旧；累计折旧/净值为只读估算，不写回固定资产台账',
      '折旧参数为空时按类别默认回退（usedDefaults 标记）；free-text 类别匹配不到时用 DEFAULT_FALLBACK',
      'daily 起算暂按次月口径估算（dailyPolicyFallback）；多币种分别列示、不折算、不跨币种合计',
      'disposed 资产不计入 totals（仅在 assets 透明展示）；不做处置损益、不进 P&L',
    ],
  };

  if (!tableExists(db, 'fixed_assets')) return { ...COMMON, byCurrency: [] };

  // 仅启用行（is_active=1）；disposed 也读（单独标，排除 totals）。
  const rows = db.prepare(
    `SELECT id, name, category, currency, original_value, status,
            depreciation_method, useful_life_months, salvage_rate, depreciation_start_policy,
            acquisition_date, disposal_date
       FROM fixed_assets WHERE is_active = 1 ORDER BY sort_order, created_at`
  ).all();

  const NULL_KEY = '__null__';
  const groups = new Map();
  const bucket = (ccy) => {
    const k = ccy == null ? NULL_KEY : ccy;
    if (!groups.has(k)) groups.set(k, { assets: [], totO: 0, totA: 0, totN: 0 });
    return groups.get(k);
  };

  for (const r of rows) {
    const warnings = [];
    const originalValue = round2(r.original_value);
    const canonical = resolveCategory(r.category);                 // free-text → canonical（无匹配 DEFAULT_FALLBACK）
    const def = DEPRECIATION_DEFAULTS[canonical] || DEPRECIATION_DEFAULTS.DEFAULT_FALLBACK;

    // useful_life_months：用户值优先；空 → 类别默认(年×12)
    const usedLife = r.useful_life_months == null;
    const usefulLifeMonths = usedLife ? def.usefulLifeYears * 12 : r.useful_life_months;

    // salvage_rate：用户值优先；空 → 默认；非法(<0 或 >=1) → 回退默认 + warning
    let salvageRate = r.salvage_rate;
    let usedSalvage = false;
    if (salvageRate == null) { salvageRate = def.salvageRate; usedSalvage = true; }
    else if (!(salvageRate >= 0 && salvageRate < 1)) { salvageRate = def.salvageRate; usedSalvage = true; warnings.push('invalidSalvageRate'); }

    const disposed = r.status === 'disposed';
    if (disposed && !r.disposal_date) warnings.push('disposedNoDate');

    const salvageValue = round2(originalValue * salvageRate);
    const depreciableAmount = Math.max(0, round2(originalValue - salvageValue));

    // 起算政策：daily → fallback next_month 口径 + warning
    let startPolicy = r.depreciation_start_policy || 'next_month';
    if (startPolicy === 'daily') { warnings.push('dailyPolicyFallback'); startPolicy = 'next_month'; }

    const acqIdx = monthIndex(r.acquisition_date);
    const monthlyDepreciation = (usefulLifeMonths > 0 && depreciableAmount > 0) ? round2(depreciableAmount / usefulLifeMonths) : 0;

    let monthsElapsed = 0;
    if (acqIdx == null) warnings.push('noAcquisitionDate');
    else if (!(usefulLifeMonths > 0)) warnings.push('invalidUsefulLife');
    else if (originalValue <= 0) warnings.push('nonPositiveOriginal');
    else if (asOfIdx != null && acqIdx > asOfIdx) warnings.push('notStarted');
    else {
      const startIdx = acqIdx + (startPolicy === 'next_month' ? 1 : 0);
      // disposed 有日期 → 处置次月停止：截止月 = min(asOf, disposal)
      let endIdx = asOfIdx;
      if (disposed && r.disposal_date) {
        const dIdx = monthIndex(r.disposal_date);
        if (dIdx != null) endIdx = (asOfIdx == null) ? dIdx : Math.min(asOfIdx, dIdx);
      }
      if (endIdx != null && endIdx >= startIdx) {
        monthsElapsed = Math.max(0, Math.min(endIdx - startIdx + 1, usefulLifeMonths));
      }
    }
    const accumulatedDepreciation = Math.min(round2(monthsElapsed * monthlyDepreciation), depreciableAmount);
    const netBookValue = round2(originalValue - accumulatedDepreciation);

    const g = bucket(r.currency);
    g.assets.push({
      id: r.id, name: r.name, category: r.category, currency: r.currency || null,
      originalValue, usefulLifeMonths, salvageRate, salvageValue,
      depreciableAmount, monthlyDepreciation, monthsElapsed,
      accumulatedDepreciation, netBookValue,
      acquisitionDate: r.acquisition_date || null,
      depreciationStartPolicy: r.depreciation_start_policy || 'next_month',
      disposalDate: r.disposal_date || null, status: r.status, disposed,
      usedDefaults: { usefulLifeMonths: usedLife, salvageRate: usedSalvage },
      categoryResolved: canonical,
      warnings,
    });
    // totals 仅在用资产（disposed 排除）
    if (!disposed) { g.totO += originalValue; g.totA += accumulatedDepreciation; g.totN += netBookValue; }
  }

  const byCurrency = [...groups.entries()].map(([k, g]) => ({
    currency: k === NULL_KEY ? null : k,
    assets: g.assets,
    totals: { originalValue: round2(g.totO), accumulatedDepreciation: round2(g.totA), netBookValue: round2(g.totN) },
  })).sort((a, b) => (a.currency === null ? 1 : b.currency === null ? -1 : String(a.currency).localeCompare(String(b.currency))));

  return { ...COMMON, byCurrency };
}

module.exports = { preview };
