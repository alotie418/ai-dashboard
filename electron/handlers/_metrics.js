// 月度环比/同比/价格指数 —— 纯函数，无 DB / provider 无关，便于离线单测（scripts/test-metrics.mjs）。
// 口径（PR-A）：mom/yoy 按「营收 revenue（不含税）」计算。
//   - mom 环比 = 本月营收 vs 上月营收
//   - yoy 同比 = 本月营收 vs 去年同月营收（去年数据由 dashboard 经报表引擎同源提供）
//   - deflator 价格指数 = 本月单位营收(revenue/salesTons) ÷ 有销量月份单位营收均值 × 100
// **基期缺失或为 0 一律返回 null**（绝不返回 0，避免误导用户的 0.0% 假同比/环比）。

// 百分比变化（一位小数）；基期为 null/0 → null。
function pct(cur, base) {
  if (base == null || base === 0) return null;
  return Math.round(((cur - base) / base) * 1000) / 10;
}

// monthly: [{ revenue, salesTons, ... }]（按月 1–12，空月 revenue=0 / salesTons=0）
// priorRevenue: number[]（去年同月营收，按月对齐 index 0=1月；缺失用 null/undefined）
function computeMonthlyComparisons(monthly, priorRevenue = []) {
  // 价格指数基准：有销量月份的「单位营收」均值。
  const unitRevs = (monthly || [])
    .filter(m => (m.salesTons || 0) > 0)
    .map(m => m.revenue / m.salesTons);
  const avgUnitRev = unitRevs.length ? unitRevs.reduce((a, b) => a + b, 0) / unitRevs.length : 0;

  return (monthly || []).map((m, i) => ({
    ...m,
    mom: i > 0 ? pct(m.revenue, monthly[i - 1].revenue) : null,
    yoy: pct(m.revenue, priorRevenue ? priorRevenue[i] : null),
    deflator: (m.salesTons || 0) > 0 && avgUnitRev > 0
      ? Math.round(((m.revenue / m.salesTons) / avgUnitRev) * 1000) / 10
      : null,
  }));
}

module.exports = { computeMonthlyComparisons, pct };
