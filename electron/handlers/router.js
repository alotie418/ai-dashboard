// 主路由分发器 — 把 (method, path, body) 翻译到对应业务 handler
// 前端 services/api.ts 的 apiFetch 在 Electron 模式下统一调 ipcMain.handle('api:request', ...)
//
// 路由顺序很关键：更具体的路径（如 /api/sales/batch）必须排在参数路由（/api/sales/:id）之前

const sales = require('./sales');
const purchases = require('./purchases');
const settings = require('./settings');
const dashboard = require('./dashboard');
const payment = require('./payment');
const accounts = require('./receivables');
const alertsH = require('./alerts');
const batch = require('./batch');
const ai = require('./ai');
const categories = require('./categories');
const products = require('./products');
const inventory = require('./inventory');
const transactions = require('./transactions');
const documentsH = require('./documents');
const migrationsH = require('./migrations');
const reportsH = require('./reports');
const mileageH = require('./mileage');
const homeOfficeH = require('./homeOffice');
const conversationsH = require('./conversations');
const cashAccountsH = require('./cashAccounts');
const liabilitiesH = require('./liabilities');
const fixedAssetsH = require('./fixedAssets');
const equityH = require('./equity');
const taxPaymentsH = require('./taxPayments');
const ledgerSummaryH = require('./ledgerSummary');
const cashPositionH = require('./cashPosition');
const balanceOverviewH = require('./balanceOverview');
const depreciationPreviewH = require('./depreciationPreview');
const retainedEarningsH = require('./retainedEarnings');
const incomeTaxPositionH = require('./incomeTaxPosition');
const fxReferenceH = require('./fxReference');

const routes = [
  // ---- Dashboard ----
  ['GET', '/api/dashboard', dashboard.summary],

  // ---- Sales（具体路径排前）----
  ['POST', '/api/sales/batch', batch.batchSales],
  ['PUT', '/api/sales/:id/payment', payment.recordSalePayment],
  ['GET', '/api/sales', sales.list],
  ['POST', '/api/sales', sales.create],
  ['PUT', '/api/sales/:id', sales.update],
  ['DELETE', '/api/sales/:id', sales.remove],

  // ---- Purchases ----
  ['POST', '/api/purchases/batch', batch.batchPurchases],
  ['PUT', '/api/purchases/:id/payment', payment.recordPurchasePayment],
  ['GET', '/api/purchases', purchases.list],
  ['POST', '/api/purchases', purchases.create],
  ['PUT', '/api/purchases/:id', purchases.update],
  ['DELETE', '/api/purchases/:id', purchases.remove],

  // ---- Receivables / Payables ----
  ['GET', '/api/receivables/summary', accounts.receivablesSummary],
  ['GET', '/api/payables/summary', accounts.payablesSummary],

  // ---- Alerts（read-all 和 count 必须排在 :id 路由前）----
  ['GET', '/api/alerts/count', alertsH.count],
  ['PUT', '/api/alerts/read-all', alertsH.markAllRead],
  ['PUT', '/api/alerts/:id/read', alertsH.markRead],
  ['DELETE', '/api/alerts/:id', alertsH.dismiss],
  ['GET', '/api/alerts', alertsH.list],

  // ---- Categories（国际化数据模型 v4）----
  ['POST', '/api/categories/reset', categories.resetToDefault],
  ['GET', '/api/categories', categories.list],
  ['POST', '/api/categories', categories.create],
  ['PUT', '/api/categories/:id', categories.update],
  ['DELETE', '/api/categories/:id', categories.remove],

  // ---- Inventory（按商品库存聚合，Phase 3；具体路径排前）----
  ['GET', '/api/inventory/summary', inventory.summary],

  // ---- Products / Service Items（商品/服务项目主数据，Phase 1）----
  ['GET', '/api/products', products.list],
  ['POST', '/api/products', products.create],
  ['PUT', '/api/products/:id', products.update],
  ['DELETE', '/api/products/:id', products.remove],

  // ---- Accounts: 现金/银行账户 + 期初余额（PR-7D-1 管道层；与 receivables 的 /api/receivables·/api/payables 不冲突）----
  ['GET', '/api/accounts', cashAccountsH.list],
  ['POST', '/api/accounts', cashAccountsH.create],
  ['PUT', '/api/accounts/:id', cashAccountsH.update],
  ['DELETE', '/api/accounts/:id', cashAccountsH.remove],

  // ---- Liabilities: 负债/借款手工台账（PR-7D-2 管道层；≠ 采购应付 payables；与 receivables/payables/accounts 不冲突）----
  ['GET', '/api/liabilities', liabilitiesH.list],
  ['POST', '/api/liabilities', liabilitiesH.create],
  ['PUT', '/api/liabilities/:id', liabilitiesH.update],
  ['DELETE', '/api/liabilities/:id', liabilitiesH.remove],

  // ---- Fixed Assets: 固定资产登记台账（PR-7D-3 管道层；仅登记不折旧·不出表；路径与其它账款不冲突）----
  ['GET', '/api/fixed-assets', fixedAssetsH.list],
  ['POST', '/api/fixed-assets', fixedAssetsH.create],
  ['PUT', '/api/fixed-assets/:id', fixedAssetsH.update],
  ['DELETE', '/api/fixed-assets/:id', fixedAssetsH.remove],

  // ---- Equity: 权益/资本登记台账（PR-7D-4 管道层；仅登记不合计·不结转·不出表；路径不冲突）----
  ['GET', '/api/equity', equityH.list],
  ['POST', '/api/equity', equityH.create],
  ['PUT', '/api/equity/:id', equityH.update],
  ['DELETE', '/api/equity/:id', equityH.remove],

  // ---- Tax Payments: 已缴税款登记台账（PR-7D-5 管道层；仅登记不算税·不抵扣·不对冲·不入报表；路径不冲突）----
  ['GET', '/api/tax-payments', taxPaymentsH.list],
  ['POST', '/api/tax-payments', taxPaymentsH.create],
  ['PUT', '/api/tax-payments/:id', taxPaymentsH.update],
  ['DELETE', '/api/tax-payments/:id', taxPaymentsH.remove],

  // ---- Ledger Summary: 各台账余额汇总快照（PR-7B-1 只读聚合；管理口径·非资产负债表·不分类·不平衡；不走 reports）----
  ['GET', '/api/ledger-summary', ledgerSummaryH.summary],

  // ---- Cash Position: 现金/银行期末结转只读预览（PR-7B P1-2；期末=期初+实收−实付·按币种·只读不写回·不走 reports formula）----
  ['GET', '/api/cash-position', cashPositionH.summary],

  // ---- Balance Overview: 管理口径资产负债概览（PR-7B P1-3 只读聚合；非法定 B/S·显式 balanceDifference·只读·不走 reports formula）----
  ['GET', '/api/balance-overview', balanceOverviewH.overview],

  // ---- Depreciation Preview: 固定资产直线法折旧只读预览（PR-7B P2-2；算净值/累计折旧·不写回·不走 reports formula）----
  ['GET', '/api/depreciation-preview', depreciationPreviewH.preview],

  // ---- Retained Earnings Preview: 留存/未分配利润只读预览（PR-7B P2-4a；期末=期初+本期净利−分红·单一本位币·只读不写回·只读复用 reports netProfit 不改 reports）----
  ['GET', '/api/retained-earnings-preview', retainedEarningsH.preview],

  // ---- Income Tax Position: 所得税同税种同期间对冲只读预览（PR-7B P3-1；期末应交=本期应计−本期已缴·仅 income_tax·本位币·只读不写回·只读复用 reports 不改 reports·不接概览）----
  ['GET', '/api/income-tax-position', incomeTaxPositionH.position],

  // ---- FX Reference Conversion: 多币种参考折算只读预览（PR-7B P3-3；balanceOverview totals × 用户参考汇率·仅供参考·不写回·不改 byCurrency 原值·无汇兑损益·不接 UI）----
  ['GET', '/api/fx-reference-conversion', fxReferenceH.convert],

  // ---- Business Documents（业务单据 Phase A；next-number/tax-invoice 排在 :id 前）----
  ['GET', '/api/documents/next-number', documentsH.nextNumber],
  ['PUT', '/api/documents/:id/tax-invoice', documentsH.updateTaxInvoice],
  ['GET', '/api/documents', documentsH.list],
  ['POST', '/api/documents', documentsH.create],
  ['GET', '/api/documents/:id', documentsH.get],
  ['PUT', '/api/documents/:id', documentsH.update],
  ['DELETE', '/api/documents/:id', documentsH.remove],

  // ---- Transactions（国际化数据模型 v5，C 阶段）----
  // 具体路径排前：summary 不和 :id 冲突
  ['GET', '/api/transactions/summary', transactions.summary],
  ['POST', '/api/transactions/recategorize', transactions.recategorize],
  ['GET', '/api/transactions', transactions.list],
  ['POST', '/api/transactions', transactions.create],
  ['GET', '/api/transactions/:id', transactions.get],
  ['PUT', '/api/transactions/:id', transactions.update],
  ['DELETE', '/api/transactions/:id', transactions.remove],

  // ---- Reports（D 阶段 — 6 国报表引擎）----
  ['POST', '/api/reports/generate', reportsH.generate],
  ['GET', '/api/reports/types', reportsH.types],

  // ---- US: Mileage Tracking（F 阶段）----
  ['GET', '/api/mileage/summary', mileageH.summary],
  ['GET', '/api/mileage', mileageH.list],
  ['POST', '/api/mileage', mileageH.create],
  ['PUT', '/api/mileage/:id', mileageH.update],
  ['DELETE', '/api/mileage/:id', mileageH.remove],

  // ---- US: Home Office（F 阶段）----
  ['GET', '/api/home-office', homeOfficeH.get],
  ['PUT', '/api/home-office', homeOfficeH.save],

  // ---- Legacy Data Migrations（sales/purchases → transactions）----
  ['GET', '/api/migrations/detect-legacy', migrationsH.detectLegacy],
  ['POST', '/api/migrations/run', migrationsH.migrateAll],
  ['POST', '/api/migrations/rollback', migrationsH.rollback],

  // ---- Settings ----
  ['GET', '/api/settings', settings.get],
  ['PUT', '/api/settings', settings.save],

  // ---- AI（BYOK：从 safeStorage 取 Key 注入 Gemini SDK）----
  ['POST', '/api/ai/analyze', ai.analyze],
  ['POST', '/api/ai/ocr', ai.ocr],
  ['POST', '/api/ai/context', ai.context],
  ['POST', '/api/ai/chat', ai.chat],
  ['POST', '/api/ai/agent-chat', ai.agentChat],
  ['POST', '/api/ai/data-analysis', ai.dataAnalysis],

  // ---- AI 助手会话持久化（R4a-1；具体路径 messages 排在 :id 之前）----
  ['GET', '/api/conversations', conversationsH.list],
  ['POST', '/api/conversations', conversationsH.create],
  ['GET', '/api/conversations/:id/messages', conversationsH.messages],
  ['POST', '/api/conversations/:id/messages', conversationsH.appendMessage],
  ['PUT', '/api/conversations/:id', conversationsH.rename],
  ['DELETE', '/api/conversations/:id', conversationsH.remove],
];

// 所有路由都已迁移，PENDING_ROUTES 清空
const PENDING_ROUTES = new Set();

function matchRoute(method, path) {
  for (const [m, pattern, handler] of routes) {
    if (m !== method) continue;
    const params = matchPattern(pattern, path);
    if (params) return { handler, params };
  }
  return null;
}

function matchPattern(pattern, path) {
  const patternSegs = pattern.split('/');
  const pathSegs = path.split('/');
  if (patternSegs.length !== pathSegs.length) return null;
  const params = {};
  for (let i = 0; i < patternSegs.length; i++) {
    const ps = patternSegs[i];
    const xs = pathSegs[i];
    if (ps.startsWith(':')) {
      params[ps.slice(1)] = decodeURIComponent(xs);
    } else if (ps !== xs) {
      return null;
    }
  }
  return params;
}

async function dispatch({ method, path, body }) {
  const [cleanPath, queryStr] = path.split('?');
  const query = queryStr ? Object.fromEntries(new URLSearchParams(queryStr)) : {};

  const matched = matchRoute(method, cleanPath);
  if (matched) {
    return await matched.handler({ params: matched.params, query, body });
  }

  for (const prefix of PENDING_ROUTES) {
    if (cleanPath === prefix || cleanPath.startsWith(prefix + '/')) {
      throw new Error(`AI 功能正在迁移到桌面版（${method} ${cleanPath}），下个版本提供`);
    }
  }

  throw new Error(`Unknown route: ${method} ${cleanPath}`);
}

module.exports = { dispatch };
