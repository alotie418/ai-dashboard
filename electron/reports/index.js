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
// A4-1 建立的唯一税率判定处。reports → handlers 这个方向是有意的:该模块零依赖,
// 不构成环;把它复制进 reports/ 才是问题的开始(两套逐渐分叉的解析器)。
const { classifyStoredRate } = require('../handlers/_rateValue');

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

// 存储原文(SQLite 里那串 TEXT),行不存在时为 null。
//
// 与 readSetting 分开,是因为 readSetting **吞掉解析异常并返回兜底**,而这里要的正是
// 「解析不了」这个事实本身。
function settingRawText(db, key) {
  try {
    const row = db.prepare('SELECT value FROM settings WHERE key = ?').get(key);
    return row ? row.value : null;
  } catch { return null; }
}

// 税率参数的解析 —— A-4「需修复」态(计划 §6.4)。
//
// 四个状态,只看两件事:**行在不在**,以及**存储文本长什么样**。绝不从算出的值反推。
//
//   行不在 + 中国       → 兜底(25 / 12),与方案 A 之前完全一致
//   行不在 + 非中国     → null,不计算(方案 A,PR #419)
//   行在 + 值可用       → 那个数
//   行在 + 值不可用     → null,不计算(本次 A4-3)
//
// 最后一条堵的是方案 A 的一个洞:存储文本**根本不是合法 JSON** 时(`abc`、裸的 `25%`),
// readSetting 的 catch 会返回兜底 25,而 settingRowExists 已经答了 true,于是闸门照常
// 放行 —— 实测美国账本 annualIncomeTax 又变回 1100,正是 #419 修掉的那个数换了一扇门。
// 现在解析失败一律判「需修复」,**禁止回退到 25 / 12**。
//
// 判定逻辑不在这里,在 electron/handlers/_rateValue.js —— 那是 A4-1 写侧封口用的同一份
// 规则,原生侧 ReportSettings.classifyRate 也镜像它。三处共用一条规则,而不是各写一套
// 慢慢分叉的解析器。引擎侧对「未配置」与「需修复」的处置相同(都不计算),所以这里把
// 两者都编码成 null;两个状态的区分留在各自 App 的设置读取层,由 R8 分别呈现。
function resolveRate(db, key, locale, chinaFallback) {
  if (!settingRowExists(db, key)) return locale === 'CN' ? chinaFallback : null;
  const raw = settingRawText(db, key);
  if (raw === null) return null;
  const verdict = classifyStoredRate(raw);
  return verdict.usable ? verdict.value : null;
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
  // 两个税率都走同一条四态判定(见 resolveRate 的注释)。中国的兜底仍是 12 / 25。
  //   • admin_expense_annual 不是税率,它的兜底 0 不参与判定 —— 缺行仍是 0,
  //     所以营业利润及其以上各行不受任何影响;
  //   • vat_rate 六个引擎都不读(附录 A6),按现状原样载入,不接入判定。
  const surchargeRate = resolveRate(db, 'surcharge_rate', locale, 12);
  const incomeTaxRate = resolveRate(db, 'income_tax_rate', locale, 25);
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
