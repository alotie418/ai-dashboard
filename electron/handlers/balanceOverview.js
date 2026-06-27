// Balance overview — management-basis, read-only aggregation (PR-7B P1-3).
//
// 「管理口径资产负债概览」后端只读聚合。**NOT 法定资产负债表。** POLICY-NEUTRAL：
//   • 按币种把各来源归入 资产(流动/非流动) / 负债(流动/非流动) / 权益 + 各小计 + balanceDifference；
//   • balanceDifference = totals.assets − totals.liabilities − totals.equity（按币种·显式·非 0 为常态·不隐藏·不强制平衡）；
//   • 现金 = 复用 cashPosition.summary 的 endingEstimate（按币种）；应收/应付/存货无币种 → 本位币桶；
//   • 固定资产按账面净值（P2-3·复用 depreciation-preview·disposed 已排除·meta 含原值/累计折旧）；借款按 maturity_date 一年线分流动/非流动（基准日=period.to；空→流动+warning）；
//   • 权益（PR-7B P2-4b）= 两行：出资（实收资本/业主资本，entity-aware）+ 未分配利润（来自 retained-earnings-preview，本位币块）；
//     出资基数 = capital_contribution + adjustment + other（adj/other 折进出资行，金额守恒）；
//     individual：owner_draw 冲减出资行；company：owner_draw 已在 retained preview 作 distributions 扣减（出资行不重复扣）；
//   • 税（应交估算/已缴税款）**不进入任何 section/totals**，仅 excludedNotes（避免税费对冲风险）；
//   • 多币种**不折算、不跨币种合计**，每币种各自算 balanceDifference；
//   • **只读**：不写回任何表、不改 electron/reports/*。复用各 handler 已导出的只读函数（require）。

const { getDb } = require('../db');
const cashPosition = require('./cashPosition');
const { receivablesSummary, payablesSummary } = require('./receivables');
const inventory = require('./inventory');
const depreciationPreview = require('./depreciationPreview');   // PR-7B P2-3：固定资产用净值（只读复用）
const retainedEarnings = require('./retainedEarnings');         // PR-7B P2-4b：权益未分配利润（只读复用）
const incomeTaxPosition = require('./incomeTaxPosition');       // PR-7B P3-4：所得税应交/预缴（只读复用·仅本位币）

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

// 按 currency 分组求和 equity.amount（启用行），限定 equity_type 集合（PR-7B P2-4b）。返回 Map<currency|null, number>。
function sumEquityByCurrency(db, types) {
  const map = new Map();
  if (!tableExists(db, 'equity') || !types.length) return map;
  const placeholders = types.map(() => '?').join(',');
  const rows = db.prepare(
    `SELECT currency AS currency, COALESCE(SUM(amount), 0) AS total FROM equity
      WHERE is_active = 1 AND equity_type IN (${placeholders}) GROUP BY currency`
  ).all(...types);
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

  // ── 3) 固定资产：PR-7B P2-3 改用「净值」（复用 depreciation-preview，同 asOf；disposed 已排除）/ 权益：按币种 ──
  const dep = await depreciationPreview.preview({ query: { asOf } });
  const fixedNetMap = new Map();   // currency|null → { net, original, accum, hasWarnings }
  for (const b of dep.byCurrency) {
    const hasWarnings = b.assets.some((a) => Array.isArray(a.warnings) && a.warnings.length > 0);
    fixedNetMap.set(b.currency, {
      net: round2(b.totals.netBookValue),
      original: round2(b.totals.originalValue),
      accum: round2(b.totals.accumulatedDepreciation),
      hasWarnings,
    });
  }
  // 权益（PR-7B P2-4b）：拆「出资行 + 未分配利润行」。只读复用 retained-earnings-preview（同 period·不改 reports）。
  const re = await retainedEarnings.preview({ query: { from, to } });
  const entityType = re.entityType;                               // 'individual' | 'company'
  const retainedBase = round2(re.endingRetainedEarnings);         // 本位币单一数值（仅本位币块）
  const capitalKey = entityType === 'company' ? 'contributedCapital' : 'ownerCapital';
  const capitalMap = sumEquityByCurrency(db, ['capital_contribution', 'adjustment', 'other']);  // 出资基数（adj/other 折进出资行）
  const ownerDrawMap = sumEquityByCurrency(db, ['owner_draw']);                                  // 业主支取（individual 冲减出资行）

  // 所得税净额（PR-7B P3-4）：仅 income_tax·同税种同期间·本位币（只读复用 income-tax-position·不改 reports）。
  //   netPosition>0 → 流动负债「应交税费（所得税·估算）」；<0 → 流动资产「预缴税款（所得税·估算）」；=0 → 不显示行。
  //   VAT/sales_tax/surcharge/payroll_tax/other 上游已过滤、根本不入 netPosition（仍仅备查）。
  const itp = await incomeTaxPosition.position({ query: { from, to } });
  const itpNet = round2(itp.netPosition);                         // 本位币·应计−已缴
  const itpLossCaveat = (itp.warnings || []).includes('accruedNegativeLossPeriod');
  const itpForeignExcluded = (itp.excludedPayments || []).some((e) => e.reason === 'non_base_currency');

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
    ...cashMap.keys(), ...fixedNetMap.keys(), ...capitalMap.keys(), ...ownerDrawMap.keys(),
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
      // P3-4：所得税净多缴 → 流动资产「预缴税款（所得税·估算）」（仅本位币·netPosition<0；=0 不显示）
      if (itpNet < -0.005) assetsCurrent.push({ key: 'incomeTaxPrepaid', amount: round2(-itpNet) });
    }
    // 资产·非流动（固定资产净值，P2-3：来自 depreciation-preview；disposed 已排除）
    if (fixedNetMap.has(ccy)) {
      const fnm = fixedNetMap.get(ccy);
      assetsNonCurrent.push({
        key: 'fixedAssets',
        amount: fnm.net,
        meta: { originalValue: fnm.original, accumulatedDepreciation: fnm.accum, netBookValue: fnm.net, estimate: true, hasWarnings: fnm.hasWarnings },
      });
      if (fnm.hasWarnings) warnings.push('fixedAssetsDepreciationWarnings');
    }
    // 负债·流动
    if (ccy === baseCurrency) {
      liabilitiesCurrent.push({ key: 'payables', amount: totalPayable });
      // P3-4：所得税净欠缴 → 流动负债「应交税费（所得税·估算）」（仅本位币·netPosition>0；=0 不显示）
      if (itpNet > 0.005) liabilitiesCurrent.push({ key: 'incomeTaxPayable', amount: round2(itpNet) });
    }
    if (borrowCurrent.has(ccy)) liabilitiesCurrent.push({ key: 'borrowings', amount: borrowCurrent.get(ccy) });
    // 负债·非流动
    if (borrowNonCurrent.has(ccy)) liabilitiesNonCurrent.push({ key: 'borrowings', amount: borrowNonCurrent.get(ccy) });
    // 权益（P2-4b 两行）：出资行（entity-aware key）+ 未分配利润行（仅本位币块）
    const capBase = capitalMap.get(ccy) || 0;
    const draw = ownerDrawMap.get(ccy) || 0;
    // individual：出资行 = 出资基数 − 同币种 owner_draw（拍板：owner_draw 冲减出资行）。
    // company：出资行 = 出资基数（owner_draw 已在 retained preview 作 distributions 扣减，不重复扣）。
    const capitalAmt = entityType === 'individual' ? round2(capBase - draw) : round2(capBase);
    const hasCapital = capitalMap.has(ccy) || (entityType === 'individual' && ownerDrawMap.has(ccy));
    if (hasCapital) equityLines.push({ key: capitalKey, amount: capitalAmt });
    // 未分配利润：本位币单一口径 → 仅放入本位币块。
    if (ccy === baseCurrency) equityLines.push({ key: 'retainedEarnings', amount: retainedBase });

    if (nullMaturityCcy.has(ccy)) warnings.push('borrowingsNullMaturityDefaultCurrent');
    // P3-4：亏损期所得税估算 caveat（accrued<0 → 预缴行不代表真实预缴；仅本位币块·有税款行时）
    if (ccy === baseCurrency && Math.abs(itpNet) > 0.005 && itpLossCaveat) warnings.push('incomeTaxLossPeriodCaveat');

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

  // company：非本位币 owner_draw 既不进出资行也不进分红（不折算）→ excludedNotes 备查（与 P2-4a 一致）。
  const foreignDrawNotes = [];
  if (entityType === 'company') {
    const foreign = [...ownerDrawMap.entries()].filter(([c]) => c !== baseCurrency);
    if (foreign.length > 0) {
      foreignDrawNotes.push('公司口径：非本位币 owner_draw（业主支取/分红）未计入分红或出资抵减，不折算：'
        + foreign.map(([c, a]) => `${c == null ? '(未指定)' : c}=${a}`).join(', '));
    }
  }

  return {
    estimate: true,
    reportType: 'management_balance_overview',   // 非法定 balance sheet
    entityType,                                  // 'individual' | 'company'（出资行 entity-aware；UI 按行 key 取标签）
    period: { from, to },
    asOf,
    baseCurrency,
    byCurrency,
    disclaimerKey: 'disclaimer.report',
    limitations: [
      '管理口径概览，非法定资产负债表，不做法定严格平衡；balanceDifference 为待调整项',
      'balanceDifference = 资产 − 负债 − 权益（按币种）；非 0 为常态，差额为待调整项（不强制平衡、不隐藏）',
      '权益拆「出资（实收资本/业主资本）+ 未分配利润」两行；未分配利润=期初+本期净利−分红的管理估算（来自 retained-earnings-preview，本位币口径，未做年结、不写回 equity）',
      '现金为期末估算（来自 cash-position：期初+实收−实付，仅经营活动，未含投资/筹资现金）',
      '固定资产按直线法估算净值（P2-3，来自 depreciation-preview，非法定/税务折旧；行 meta 含原值/累计折旧）；已处置资产不计入净值',
      '应收/应付/存货为 as-of 当前快照，与现金的期间口径不完全一致',
      '多币种分别列示，不折算、不跨币种合计；每币种各自算 balanceDifference',
      '只读：不写回任何数据',
    ],
    excludedNotes: [
      '仅所得税(income_tax)同税种同期间净额作为「应交税费/预缴税款（估算）」进入概览（管理估算·本位币·来自 income-tax-position）；VAT/消费税/销售税/附加税/工资税/其它税种仍不进合计、仅备查（见已缴税款台账）',
      ...(itpForeignExcluded ? ['非本位币所得税缴款未计入概览（不折算·见 income-tax-position excludedPayments）'] : []),
      '应收/应付/存货无币种字段，按本位币(' + baseCurrency + ')归集',
      `未分配利润为本位币(${baseCurrency})单一口径，仅列入本位币分组；非本位币分组只含出资类权益，不做折算（折算属 P3）`,
      ...foreignDrawNotes,
    ],
  };
}

module.exports = { overview };
