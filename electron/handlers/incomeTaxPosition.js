// Income-tax position preview — management-basis, read-only (PR-7B P3-1).
//
// 「所得税同税种同期间对冲」只读预览。POLICY-NEUTRAL，**NOT 法定税务申报/计算**：
//   • 公式（会计师 K-6）：期末应交所得税 = 本期应计所得税 − 本期已缴所得税。
//   • 本期应计：只读复用 reports 引擎 incomeStatement.incomeTax（CN/JP/EU/KR/TW）；
//     **US 无 incomeStatement → estimatedTax.annualIncomeTax**（仅所得税·不含 SE tax·locale 特判）。
//     **不修改 electron/reports/***（仅 require·只读）。
//   • 本期已缴：tax_payments 中 tax_type='income_tax'·is_active=1·**本位币**·同期间 的 amount 之和。
//   • 「同期间」：period_start/period_end 都在 → 区间重叠(period_start<=to AND period_end>=from)；
//     缺则回退 payment_date∈[from,to]；都无法定位时间 → 排除。
//   • **仅所得税**：VAT/sales_tax/surcharge/payroll_tax/other 不参与（SQL 上游过滤）。
//   • **仅本位币**：非本位币 income_tax 缴款排除并入 excludedPayments/excludedNotes（不折算·K-10）。
//   • amount 允许负（退税/冲正）→ 减少已缴 + warning；US 亏损期 accrued 可为负 → 忠实保留 + warning。
//   • **只读**：不写回 tax_payments、不接 balanceOverview、不改 FinancePage、不改 schema、不生成分录。

const { getDb } = require('../db');
const reportEngine = require('../reports');

const round2 = (n) => Math.round((Number(n) || 0) * 100) / 100;
const EPS = 0.005;

function readSetting(db, key, fallback) {
  try {
    const row = db.prepare('SELECT value FROM settings WHERE key = ?').get(key);
    return row ? JSON.parse(row.value) : fallback;
  } catch { return fallback; }
}

function tableExists(db, name) {
  return !!db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name=?").get(name);
}

// 「同期间」判定。返回 { matched, basis: 'period'|'payment_date'|null, partial, noDate }。
//  • period_start & period_end 都在：区间重叠（period_start<=to AND period_end>=from）；
//    matched 但区间越出 [from,to] → partial=true（潜在跨期双计 → warning，不静默）。
//  • period 缺一/全缺：回退 payment_date∈[from,to]。
//  • 既无完整 period 又无 payment_date：noDate → 排除。
function matchPeriod(p, from, to) {
  const ps = p.period_start ? String(p.period_start) : null;
  const pe = p.period_end ? String(p.period_end) : null;
  if (ps && pe) {
    const matched = ps <= to && pe >= from;
    const partial = matched && (ps < from || pe > to);
    return { matched, basis: matched ? 'period' : null, partial, noDate: false };
  }
  const pd = p.payment_date ? String(p.payment_date) : null;
  if (pd) {
    const matched = pd >= from && pd <= to;
    return { matched, basis: matched ? 'payment_date' : null, partial: false, noDate: false };
  }
  return { matched: false, basis: null, partial: false, noDate: true };
}

// GET /api/income-tax-position?from=YYYY-MM-DD&to=YYYY-MM-DD（或 ?year=）
async function position({ query } = {}) {
  const db = getDb();
  const q = query || {};
  const year = q.year || String(new Date().getFullYear());
  const from = q.from || `${year}-01-01`;
  const to = q.to || `${year}-12-31`;
  const baseCurrency = readSetting(db, 'currency', 'CNY');
  const locale = readSetting(db, 'accounting_locale', 'CN');

  // ── 本期应计所得税：只读复用 reports（**不改 reports**）。US 无 incomeStatement → estimatedTax.annualIncomeTax ──
  const report = reportEngine.generate(db, { locale, from, to });
  let accruedIncomeTax = 0;
  let accruedSource = 'incomeStatement.incomeTax';
  if (report && report.incomeStatement && typeof report.incomeStatement.incomeTax === 'number') {
    accruedIncomeTax = report.incomeStatement.incomeTax;
    accruedSource = 'incomeStatement.incomeTax';
  } else if (report && report.estimatedTax && typeof report.estimatedTax.annualIncomeTax === 'number') {
    accruedIncomeTax = report.estimatedTax.annualIncomeTax;
    accruedSource = 'estimatedTax.annualIncomeTax';
  }
  accruedIncomeTax = round2(accruedIncomeTax);

  // ── 本期已缴所得税：tax_payments（income_tax·启用·本位币·同期间）──
  const matchedPayments = [];
  const excludedPayments = [];
  let paidIncomeTax = 0;
  let hasNegative = false;
  let hasPartialOverlap = false;
  if (tableExists(db, 'tax_payments')) {
    const rows = db.prepare(
      `SELECT id, name, amount, currency, payment_date, period_start, period_end
         FROM tax_payments WHERE tax_type = 'income_tax' AND is_active = 1`
    ).all();
    for (const p of rows) {
      const ccy = p.currency == null ? null : p.currency;
      const amt = Number(p.amount) || 0;
      // 非本位币 → 排除（不折算）
      if (ccy !== baseCurrency) {
        excludedPayments.push({ id: p.id, name: p.name, amount: round2(amt), currency: ccy, reason: 'non_base_currency' });
        continue;
      }
      const m = matchPeriod(p, from, to);
      if (!m.matched) {
        excludedPayments.push({
          id: p.id, name: p.name, amount: round2(amt), currency: ccy,
          reason: m.noDate ? 'no_date' : 'out_of_period',
        });
        continue;
      }
      if (amt < 0) hasNegative = true;
      if (m.partial) hasPartialOverlap = true;
      paidIncomeTax += amt;
      matchedPayments.push({
        id: p.id, name: p.name, amount: round2(amt), currency: ccy,
        payment_date: p.payment_date || null, period_start: p.period_start || null, period_end: p.period_end || null,
        matchBasis: m.basis,
      });
    }
  }
  paidIncomeTax = round2(paidIncomeTax);

  const netPosition = round2(accruedIncomeTax - paidIncomeTax);
  let positionType = 'zero';
  if (netPosition > EPS) positionType = 'payable';
  else if (netPosition < -EPS) positionType = 'prepaid';

  const warnings = [];
  if (hasNegative) warnings.push('negativePaymentPresent');
  if (hasPartialOverlap) warnings.push('partialPeriodOverlap');
  if (accruedIncomeTax < 0) warnings.push('accruedNegativeLossPeriod');

  const limitations = [
    '管理口径估算，非法定税务申报/计算；期末应交所得税 = 本期应计 − 本期已缴（同税种·同期间·本位币）',
    accruedSource === 'estimatedTax.annualIncomeTax'
      ? '本期应计所得税取自 US estimatedTax.annualIncomeTax（仅所得税，不含自雇税 SE tax）'
      : '本期应计所得税取自 incomeStatement.incomeTax（应纳税所得 × 单一税率的简化估算，非真实应纳税额）',
    '仅匹配 tax_type=income_tax 且本位币的已缴税款；其它税种与非本位币缴款不参与对冲',
  ];
  if (hasNegative) limitations.push('含负额缴款（退税/冲正），已抵减本期已缴；请核对方向');
  if (hasPartialOverlap) limitations.push('部分缴款的所属期间越出当前期间（partialPeriodOverlap），跨期可能重复计入，请核对');
  if (accruedIncomeTax < 0) limitations.push('应计为负（亏损期，US 不 clamp）；此 preview 不代表真实预缴，亏损期通常无当期应交所得税');

  const excludedNotes = [];
  const foreignExcluded = excludedPayments.filter((e) => e.reason === 'non_base_currency');
  if (foreignExcluded.length > 0) {
    excludedNotes.push('非本位币 income_tax 缴款未计入（不折算·K-10）：'
      + foreignExcluded.map((e) => `${e.currency == null ? '(未指定)' : e.currency}=${e.amount}`).join(', '));
  }
  excludedNotes.push('VAT/消费税/销售税/附加税/工资税/其它税种 不在本所得税对冲范围（默认备查）');

  return {
    estimate: true,
    reportType: 'income_tax_position',   // 非法定
    taxType: 'income_tax',
    locale,
    accruedSource,
    period: { from, to },
    baseCurrency,
    accruedIncomeTax,
    paidIncomeTax,
    netPosition,
    positionType,
    matchedPayments,
    excludedPayments,
    warnings,
    limitations,
    excludedNotes,
    disclaimerKey: 'disclaimer.tax',
  };
}

module.exports = { position };
