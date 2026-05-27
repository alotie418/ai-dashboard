// 报表引擎统一接口
// 按 accounting_locale 路由到对应国家的报表生成器
// 详见 docs/INTERNATIONALIZATION_PLAN.md §5

const cn = require('./cn');
const us = require('./us');
const jp = require('./jp');
const eu = require('./eu');
const kr = require('./kr');
const tw = require('./tw');

const ENGINES = { CN: cn, US: us, JP: jp, EU: eu, KR: kr, TW: tw };

function readSetting(db, key, fallback) {
  try {
    const row = db.prepare('SELECT value FROM settings WHERE key = ?').get(key);
    return row ? JSON.parse(row.value) : fallback;
  } catch { return fallback; }
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

  // 读取交易数据（优先 transactions 新表，fallback 到旧 sales/purchases）
  let incomeRows, expenseRows;
  const hasTransactions = db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='transactions'").get();

  if (hasTransactions) {
    const txnCount = db.prepare('SELECT COUNT(*) as c FROM transactions').get().c;
    if (txnCount > 0) {
      incomeRows = db.prepare(
        "SELECT * FROM transactions WHERE type = 'income' AND date >= ? AND date <= ? ORDER BY date"
      ).all(from, to);
      expenseRows = db.prepare(
        "SELECT * FROM transactions WHERE type = 'expense' AND date >= ? AND date <= ? ORDER BY date"
      ).all(from, to);
    }
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
  const incomeTaxRate = Number(readSetting(db, 'income_tax_rate', 25));
  const adminExpense = Number(readSetting(db, 'admin_expense_annual', 0));
  const currency = readSetting(db, 'currency', 'CNY');

  const context = {
    locale, from, to, year,
    incomeRows, expenseRows, categories,
    vatRate, surchargeRate, incomeTaxRate, adminExpense, currency,
  };

  return engine.generate(context);
}

// 获取支持的报表类型列表
function getAvailableReports(locale) {
  const engine = ENGINES[locale || 'CN'];
  return engine ? engine.reportTypes : [];
}

module.exports = { generate, getAvailableReports, ENGINES };
