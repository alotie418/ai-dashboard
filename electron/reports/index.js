// 报表引擎统一接口
// 按 accounting_locale 路由到对应国家的报表生成器
// 详见 docs/INTERNATIONALIZATION_PLAN.md §5

const cn = require('./cn');
const us = require('./us');
const jp = require('./jp');
const eu = require('./eu');
const kr = require('./kr');
const tw = require('./tw');
const { selectReportSource } = require('./_reportSource');
const { computeOperatingCashflow } = require('./_cashflow');

const ENGINES = { CN: cn, US: us, JP: jp, EU: eu, KR: kr, TW: tw };

function readSetting(db, key, fallback) {
  try {
    const row = db.prepare('SELECT value FROM settings WHERE key = ?').get(key);
    return row ? JSON.parse(row.value) : fallback;
  } catch { return fallback; }
}

// 「设置行在不在」与「值等于多少」是两个问题,方案 A 只问前者。
//
// 这不是风格偏好,是实测结论(docs/SWIFTUI_REPORTS_MIRROR_PLAN.md §6.2 四变体矩阵):
// income_tax_rate 缺行时,readSetting 会套用中国兜底 25,于是美国账本产出 1100 —— 一个
// 完全正常的数字,与「用户真的配了 25%」在数值上不可分。所以「未配置」只能由行的缺失
// 来判定,绝不能从算出的值反推。
function settingRowExists(db, key) {
  try {
    return !!db.prepare('SELECT 1 AS present FROM settings WHERE key = ?').get(key);
  } catch { return false; }
}

// 生成报表
// opts: { locale?, from?, to?, year? }
// 返回: { locale, period, sections[], totals, warnings[] }
function generate(db, opts = {}) {
  const locale = opts.locale || readSetting(db, 'accounting_locale', 'CN');
  const engine = ENGINES[locale];
  if (!engine) {
    throw new Error(`Unsupported accounting locale: ${locale}. Supported: ${Object.keys(ENGINES).join('/')}`);
  }

  const year = opts.year || String(new Date().getFullYear());
  const from = opts.from || `${year}-01-01`;
  const to = opts.to || `${year}-12-31`;

  // 读取交易数据：按「当前报表期间 [from,to]」决定数据源（详见 _reportSource.js）。
  // 修复：仅当本期间内有 transaction 才用 transactions，否则 fallback 到旧
  // sales/purchases —— 避免别的年份的一条 transaction 让本年份不再 fallback。
  let incomeRows, expenseRows;
  const hasTransactionsTable = !!db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='transactions'").get();
  const periodTxnCount = hasTransactionsTable
    ? db.prepare('SELECT COUNT(*) as c FROM transactions WHERE date >= ? AND date <= ?').get(from, to).c
    : 0;

  if (selectReportSource({ hasTransactionsTable, periodTxnCount }) === 'transactions') {
    incomeRows = db.prepare(
      "SELECT * FROM transactions WHERE type = 'income' AND date >= ? AND date <= ? ORDER BY date"
    ).all(from, to);
    expenseRows = db.prepare(
      "SELECT * FROM transactions WHERE type = 'expense' AND date >= ? AND date <= ? ORDER BY date"
    ).all(from, to);
  }

  // Fallback: 旧表
  if (!incomeRows) {
    const hasSales = db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='sales'").get();
    const hasPurchases = db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='purchases'").get();
    incomeRows = hasSales
      ? db.prepare('SELECT *, totalAmount as amount, amountWithoutTax as amount_net, taxAmount as tax_amount, taxRate as tax_rate, customer as counterparty FROM sales WHERE date >= ? AND date <= ? ORDER BY date').all(from, to)
      : [];
    expenseRows = hasPurchases
      ? db.prepare('SELECT *, totalAmount as amount, amountWithoutTax as amount_net, taxAmount as tax_amount, taxRate as tax_rate, supplier as counterparty FROM purchases WHERE date >= ? AND date <= ? ORDER BY date').all(from, to)
      : [];
  }

  // 读取 categories 用于分类汇总
  let categories = [];
  try {
    categories = db.prepare('SELECT * FROM categories WHERE locale = ? ORDER BY type, sort_order').all(locale);
  } catch { /* categories 表可能不存在 */ }

  // 读取会计参数
  const vatRate = Number(readSetting(db, 'vat_rate', 13));
  const surchargeRate = Number(readSetting(db, 'surcharge_rate', 12));
  // 方案 A(失败即拒)—— 见 docs/SWIFTUI_REPORTS_MIRROR_PLAN.md §9.1。
  //
  // 非中国制度 + income_tax_rate 设置行缺失 → 不再静默套用中国兜底 25%,而是把 null
  // 交给引擎,由引擎产出 null、由 UI 渲染「未配置」。不发明任何税率:把「我们不知道」
  // 写成一个看起来权威的数字,正是这里要消灭的东西。
  //   • 中国制度保留兜底(A-2),与本次改动前完全一致;
  //   • 行存在但值不可解析(如 "25%")不走这条路 —— 那是另一个可区分的「需修复」
  //     状态(A-4),行为保持不变,留给单独 PR;
  //   • admin_expense_annual 不是税率,它的兜底 0 也不参与本判定。
  const incomeTaxRate = (locale === 'CN' || settingRowExists(db, 'income_tax_rate'))
    ? Number(readSetting(db, 'income_tax_rate', 25))
    : null;
  const adminExpense = Number(readSetting(db, 'admin_expense_annual', 0));
  const currency = readSetting(db, 'currency', 'CNY');

  const context = {
    locale, from, to, year,
    incomeRows, expenseRows, categories,
    vatRate, surchargeRate, incomeTaxRate, adminExpense, currency,
  };

  // PR-7C (additive): attach a management-basis operating cash-flow block alongside the
  // engine output. Does NOT modify incomeStatement / vatSummary / scheduleC or any P&L /
  // VAT / tax formula — it only aggregates existing payment columns by payment date.
  const result = engine.generate(context);
  return { ...result, cashflowStatement: computeOperatingCashflow(db, { from, to }) };
}

// 获取支持的报表类型列表
function getAvailableReports(locale) {
  const engine = ENGINES[locale || 'CN'];
  return engine ? engine.reportTypes : [];
}

module.exports = { generate, getAvailableReports, ENGINES };
