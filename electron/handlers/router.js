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
const transactions = require('./transactions');
const migrationsH = require('./migrations');
const reportsH = require('./reports');

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

  // ---- Transactions（国际化数据模型 v5，C 阶段）----
  // 具体路径排前：summary 不和 :id 冲突
  ['GET', '/api/transactions/summary', transactions.summary],
  ['GET', '/api/transactions', transactions.list],
  ['POST', '/api/transactions', transactions.create],
  ['GET', '/api/transactions/:id', transactions.get],
  ['PUT', '/api/transactions/:id', transactions.update],
  ['DELETE', '/api/transactions/:id', transactions.remove],

  // ---- Reports（D 阶段 — 6 国报表引擎）----
  ['GET', '/api/reports/generate', reportsH.generate],
  ['GET', '/api/reports/types', reportsH.types],

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
  ['POST', '/api/ai/tts', ai.tts],
  ['POST', '/api/ai/data-analysis', ai.dataAnalysis],
  ['GET', '/api/ai/live-key', ai.liveKey],
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
