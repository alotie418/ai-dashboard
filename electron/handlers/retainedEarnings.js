// Retained earnings preview — management-basis, read-only (PR-7B P2-4a).
//
// 「留存收益/未分配利润」只读预览。POLICY-NEUTRAL，**NOT 法定财务报表**：
//   • 公式（会计师 K-9）：期末未分配利润 = 期初未分配利润 + 本期净利润 − 本期分红/利润分配。
//   • 本期净利润：只读复用 reports 引擎的 incomeStatement.netProfit（US 无此字段 → scheduleC.line31_netProfit）。
//     **不修改 electron/reports/***（仅 require·只读）。
//   • 单一本位币口径：netProfit / openingRetainedEarnings 均本位币；**不做 byCurrency、不折算**（折算属 P3）。
//   • entity_type=individual（默认）：业主支取(owner_draw) **不冲减未分配利润**（留 P2-4b 冲减出资行）→ distributions=0。
//   • entity_type=company：owner_draw 暂按分红/利润分配冲减未分配利润（仅本位币·event_date 在期间内·非空）。
//   • dividend 专用类型 **不在 P2 做**（留 P3）；adjustment/其它 equity_type 不计入 distributions。
//   • **只读**：不写回 equity、不自动年结、不改历史、不生成会计分录、不接 balanceOverview、不改 schema。

const { getDb } = require('../db');
const reportEngine = require('../reports');

const round2 = (n) => Math.round((Number(n) || 0) * 100) / 100;

function readSetting(db, key, fallback) {
  try {
    const row = db.prepare('SELECT value FROM settings WHERE key = ?').get(key);
    return row ? JSON.parse(row.value) : fallback;
  } catch { return fallback; }
}

function tableExists(db, name) {
  return !!db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name=?").get(name);
}

// entity_type：仅 'individual' | 'company'，缺失/非法值 → 'individual'（拍板默认，读取侧校验）。
function readEntityType(db) {
  return readSetting(db, 'entity_type', 'individual') === 'company' ? 'company' : 'individual';
}

// 期初未分配利润：本位币单一数值；Number 强转·NaN→0·允许负（累计亏损）。
function readOpeningRetained(db) {
  const n = Number(readSetting(db, 'opening_retained_earnings', 0));
  return Number.isFinite(n) ? n : 0;
}

// GET /api/retained-earnings-preview?from=YYYY-MM-DD&to=YYYY-MM-DD（或 ?year=）
async function preview({ query } = {}) {
  const db = getDb();
  const q = query || {};
  const year = q.year || String(new Date().getFullYear());
  const from = q.from || `${year}-01-01`;
  const to = q.to || `${year}-12-31`;
  const baseCurrency = readSetting(db, 'currency', 'CNY');
  const locale = readSetting(db, 'accounting_locale', 'CN');
  const entityType = readEntityType(db);
  const openingRetainedEarnings = round2(readOpeningRetained(db));

  // ── 本期净利润：只读复用 reports 引擎（**不改 reports**）。US 无 incomeStatement → scheduleC.line31_netProfit ──
  const report = reportEngine.generate(db, { locale, from, to });
  let netProfit = 0;
  let netProfitSource = 'incomeStatement';
  if (report && report.incomeStatement && typeof report.incomeStatement.netProfit === 'number') {
    netProfit = report.incomeStatement.netProfit;
    netProfitSource = 'incomeStatement';
  } else if (report && report.scheduleC && typeof report.scheduleC.line31_netProfit === 'number') {
    netProfit = report.scheduleC.line31_netProfit;
    netProfitSource = 'scheduleC';
  }
  netProfit = round2(netProfit);

  // ── 分红/利润分配（distributions）──
  //  • individual：恒 0（owner_draw 留 P2-4b 冲减出资行，不冲未分配利润）。
  //  • company：Σ owner_draw（is_active=1·currency=本位币·event_date 在 [from,to]·非空）。
  //    非本位币（不折算）、无日期、期间外 → 排除并入 excludedNotes 备查。adjustment/dividend 不计入（P3）。
  let distributions = 0;
  const foreignDrawByCurrency = [];   // company：非本位币 owner_draw（排除·备查）
  let nullDateDrawCount = 0;          // company：event_date 为空的 owner_draw（排除·备查）
  if (entityType === 'company' && tableExists(db, 'equity')) {
    const rows = db.prepare(
      `SELECT currency, amount, event_date FROM equity
        WHERE equity_type = 'owner_draw' AND is_active = 1`
    ).all();
    const foreignMap = new Map();
    for (const r of rows) {
      const ccy = r.currency == null ? null : r.currency;
      const amt = Number(r.amount) || 0;
      if (!r.event_date) { nullDateDrawCount += 1; continue; }                 // 无日期 → 排除
      if (String(r.event_date) < from || String(r.event_date) > to) continue;  // 期间外 → 排除
      if (ccy !== baseCurrency) {                                              // 非本位币 → 排除（不折算）
        foreignMap.set(ccy, round2((foreignMap.get(ccy) || 0) + amt));
        continue;
      }
      distributions += amt;
    }
    distributions = round2(distributions);
    for (const [currency, amount] of foreignMap.entries()) foreignDrawByCurrency.push({ currency, amount });
  }

  const endingRetainedEarnings = round2(openingRetainedEarnings + netProfit - distributions);

  const limitations = [
    '管理口径估算，非法定财务报表；期末未分配利润 = 期初 + 本期净利 − 本期分红/利润分配',
    netProfitSource === 'scheduleC'
      ? '本期净利取自 Schedule C line31（US 口径，所得税前）'
      : '本期净利取自经营损益概览 incomeStatement.netProfit（CN/JP/EU/KR/TW 为所得税后净利）',
    '净利口径随会计制度不同（CN/JP/EU/KR/TW 税后、US 为 Schedule C 税前），未强行统一',
    `单一本位币口径（${baseCurrency}），不做多币种折算（折算属 P3）`,
    '不自动跨年结转：期初未分配利润取自设置固定值，视作所选期间期初；多年滚存需用户自行更新（年结属后续）',
    '只读：不写回 equity、不修改历史、不生成会计分录',
  ];

  const excludedNotes = [];
  if (entityType === 'individual') {
    excludedNotes.push('个体/独资口径：业主支取(owner_draw) 不冲减未分配利润，留待概览冲减业主资本/出资行(P2-4b)');
  } else {
    excludedNotes.push('公司口径：owner_draw 暂按分红/利润分配冲减未分配利润（dividend 专用类型属 P3）');
    if (foreignDrawByCurrency.length > 0) {
      excludedNotes.push('非本位币 owner_draw 未计入分红（不折算）：' + foreignDrawByCurrency.map((f) => `${f.currency}=${f.amount}`).join(', '));
    }
    if (nullDateDrawCount > 0) {
      excludedNotes.push(`event_date 为空的 owner_draw 共 ${nullDateDrawCount} 笔未计入本期分红（无法落入期间）`);
    }
  }
  excludedNotes.push('资本公积/盈余公积等权益明细未拆分（属高级选项/后续）');

  return {
    estimate: true,
    reportType: 'retained_earnings_preview',   // 非法定
    entityType,
    locale,
    period: { from, to },
    baseCurrency,
    openingRetainedEarnings,
    netProfit,
    netProfitSource,
    distributions,
    endingRetainedEarnings,
    disclaimerKey: 'disclaimer.report',
    limitations,
    excludedNotes,
  };
}

module.exports = { preview };
