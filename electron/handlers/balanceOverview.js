// Balance overview — management-basis, read-only aggregation (PR-7B P1-3).
//
// 「管理口径资产负债概览」后端只读聚合。**NOT 法定资产负债表。** POLICY-NEUTRAL：
//   • 按币种把各来源归入 资产(流动/非流动) / 负债(流动/非流动) / 权益 + 各小计 + balanceDifference；
//   • balanceDifference = totals.assets − totals.liabilities − totals.equity（按币种·显式·非 0 为常态·不隐藏·不强制平衡）；
//   • 现金 = 复用 cashPosition.summary 的 endingEstimate（按币种）；应收/应付/存货无币种 → 本位币桶；
//   • 固定资产按 original_value（**不折旧·不算净值**）；借款按 maturity_date 一年线分流动/非流动（基准日=period.to；空→流动+warning）；
//   • 权益 = Σ equity.amount（**不做留存/利润结转**，差额由 balanceDifference 承接）；
//   • 税（应交估算/已缴税款）**不进入任何 section/totals**，仅 excludedNotes（避免税费对冲风险）；
//   • 多币种**不折算、不跨币种合计**，每币种各自算 balanceDifference；
//   • **只读**：不写回任何表、不改 electron/reports/*。复用各 handler 已导出的只读函数（require）。

const { getDb } = require('../db');
const cashPosition = require('./cashPosition');
const { receivablesSummary, payablesSummary } = require('./receivables');
const inventory = require('./inventory');

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
// 'YYYY-MM-DD' → 次年同日（字符串安全；仅用于一年线字典序比较，不依赖 Date）。
function addOneYear(iso) {
  const m = /^(\d{4})(-\d{2}-\d{2})$/.exec(String(iso || ''));
  return m ? `${Number(m[1]) + 1}${m[2]}` : iso;
}
// 按 currency 分组求和某表金额列（启用行）。返回 Map<currency|null, number>。
function sumByCurrency(db, table, amountCol) {
  const map = new Map();
  if (!tableExists(db, table)) return map;
  const rows = db.prepare(
    `SELECT currency AS currency, COALESCE(SUM(${amountCol}), 0) AS total FROM ${table} WHERE is_active = 1 GROUP BY currency`
  ).all();
  for (const r of rows) map.set(r.currency == null ? null : r.currency, round2(r.total));
  return map;
}

// GET /api/balance-overview?from=YYYY-MM-DD&to=YYYY-MM-DD
async function overview({ query } = {}) {
  const db = getDb();
  const q = query || {};
  const year = q.year || String(new Date().getFullYear());
  const from = q.from || `${year}-01-01`;
  const to = q.to || `${year}-12-31`;
  const asOf = to;                       // 借款流动/非流动一年线基准日（拍板2）
  const cutoff = addOneYear(asOf);       // ≤ cutoff → 流动；> cutoff → 非流动
  const baseCurrency = readBaseCurrency(db);

  // ── 1) 现金：复用 cashPosition.summary 的 endingEstimate（按币种）──
  const cash = await cashPosition.summary({ query: { from, to, year } });
  const cashMap = new Map();             // currency|null → endingEstimate
  for (const r of cash.byCurrency) cashMap.set(r.currency, round2(r.endingEstimate));

  // ── 2) AR / AP / 存货：无币种 → 本位币桶 ──
  const recv = await receivablesSummary();
  const pay = await payablesSummary();
  const inv = await inventory.summary();
  const totalReceivable = round2(recv?.totalReceivable);
  const totalPayable = round2(pay?.totalPayable);
  const totalInventory = round2(inv?.totalInventoryCost);

  // ── 3) 固定资产(原值) / 权益：按币种 ──
  const fixedMap = sumByCurrency(db, 'fixed_assets', 'original_value');
  const equityMap = sumByCurrency(db, 'equity', 'amount');

  // ── 4) 借款：按币种 + 一年线分流动/非流动（空到期日→流动+warning）──
  const borrowCurrent = new Map();       // currency|null → sum
  const borrowNonCurrent = new Map();
  const nullMaturityCcy = new Set();     // 出现过空到期日的币种
  if (tableExists(db, 'liabilities')) {
    const rows = db.prepare('SELECT currency, opening_balance, maturity_date FROM liabilities WHERE is_active = 1').all();
    for (const r of rows) {
      const ccy = r.currency == null ? null : r.currency;
      const amt = Number(r.opening_balance) || 0;
      const md = r.maturity_date;
      let target;
      if (!md) { target = borrowCurrent; nullMaturityCcy.add(ccy); }   // 空到期日 → 流动 + warning
      else if (String(md) <= cutoff) target = borrowCurrent;          // ≤ 基准日+1年（含过期）→ 流动
      else target = borrowNonCurrent;                                  // > 基准日+1年 → 非流动
      target.set(ccy, round2((target.get(ccy) || 0) + amt));
    }
  }

  // ── 5) 组装：币种并集（含本位币，给 AR/AP/存货）──
  const currencies = new Set([
    ...cashMap.keys(), ...fixedMap.keys(), ...equityMap.keys(),
    ...borrowCurrent.keys(), ...borrowNonCurrent.keys(),
    baseCurrency,
  ]);

  const byCurrency = [...currencies].map((ccy) => {
    const assetsCurrent = [];
    const assetsNonCurrent = [];
    const liabilitiesCurrent = [];
    const liabilitiesNonCurrent = [];
    const equityLines = [];
    const warnings = [];

    // 资产·流动
    if (cashMap.has(ccy)) assetsCurrent.push({ key: 'cash', amount: cashMap.get(ccy) });
    if (ccy === baseCurrency) {
      assetsCurrent.push({ key: 'receivables', amount: totalReceivable });
      assetsCurrent.push({ key: 'inventory', amount: totalInventory });
    }
    // 资产·非流动（固定资产原值）
    if (fixedMap.has(ccy)) assetsNonCurrent.push({ key: 'fixedAssets', amount: fixedMap.get(ccy) });
    // 负债·流动
    if (ccy === baseCurrency) liabilitiesCurrent.push({ key: 'payables', amount: totalPayable });
    if (borrowCurrent.has(ccy)) liabilitiesCurrent.push({ key: 'borrowings', amount: borrowCurrent.get(ccy) });
    // 负债·非流动
    if (borrowNonCurrent.has(ccy)) liabilitiesNonCurrent.push({ key: 'borrowings', amount: borrowNonCurrent.get(ccy) });
    // 权益
    if (equityMap.has(ccy)) equityLines.push({ key: 'equity', amount: equityMap.get(ccy) });

    if (nullMaturityCcy.has(ccy)) warnings.push('borrowingsNullMaturityDefaultCurrent');

    const sum = (arr) => round2(arr.reduce((s, l) => s + l.amount, 0));
    const totalAssets = round2(sum(assetsCurrent) + sum(assetsNonCurrent));
    const totalLiabilities = round2(sum(liabilitiesCurrent) + sum(liabilitiesNonCurrent));
    const totalEquity = sum(equityLines);

    return {
      currency: ccy,
      assets: { current: assetsCurrent, nonCurrent: assetsNonCurrent },
      liabilities: { current: liabilitiesCurrent, nonCurrent: liabilitiesNonCurrent },
      equity: equityLines,
      totals: { assets: totalAssets, liabilities: totalLiabilities, equity: totalEquity },
      // 显式差额（非 0 为常态；不隐藏、不强制平衡）
      balanceDifference: round2(totalAssets - totalLiabilities - totalEquity),
      warnings,
    };
  }).sort((a, b) => (a.currency === null ? 1 : b.currency === null ? -1 : String(a.currency).localeCompare(String(b.currency))));

  return {
    estimate: true,
    reportType: 'management_balance_overview',   // 非法定 balance sheet
    period: { from, to },
    asOf,
    baseCurrency,
    byCurrency,
    disclaimerKey: 'disclaimer.report',
    limitations: [
      '管理口径概览，非法定资产负债表，不做法定严格平衡；balanceDifference 为待调整项',
      'balanceDifference = 资产 − 负债 − 权益（按币种）；非 0 为常态（权益取自台账，未做利润结转/配平）',
      '现金为期末估算（来自 cash-position：期初+实收−实付，仅经营活动，未含投资/筹资现金）',
      '固定资产按原值列示，未做折旧/累计折旧/净值（属 P2）',
      '应收/应付/存货为 as-of 当前快照，与现金的期间口径不完全一致',
      '多币种分别列示，不折算、不跨币种合计；每币种各自算 balanceDifference',
      '只读：不写回任何数据',
    ],
    excludedNotes: [
      '已缴税款(tax_payments) 与 应交税费估算 不进入任何 section/totals（税费抵扣/对冲属 P3）',
      '应收/应付/存货无币种字段，按本位币(' + baseCurrency + ')归集',
      '留存收益/未分配利润/本年利润结转未实现（属 P2），差额由 balanceDifference 承接',
    ],
  };
}

module.exports = { overview };
