// AI 助手只读查账工具白名单（R2b-1）。
//
// 每个工具仅映射 router 里既有的【只读】handler（GET / summary / list / get 系列）；本文件绝不
// 引用任何写操作（新增 / 修改 / 删除 / 保存 / 收付款 / 签发 / 作废 / 单据正式发票 / 数据库恢复 /
// 附件），也不触及 API 密钥或加密存储。AI 永不写数据——这条边界由 scripts/check-raw-key-leaks.mjs
// 的 checkAIToolsReadonly 机器强制（扫描本文件，禁止出现写 handler 调用与敏感引用）。
//
// executeReadonlyTool 只返回业务查询结果；行数截断与 toolTrace 由调用方（agent loop）负责，
// trace 只回工具名 / 参数摘要 / 行数 / 截断标志，绝不含密钥或结果明细。

const dashboard = require('../handlers/dashboard');
const sales = require('../handlers/sales');
const purchases = require('../handlers/purchases');
const transactions = require('../handlers/transactions');
const inventory = require('../handlers/inventory');
const products = require('../handlers/products');
const accounts = require('../handlers/receivables');
const documentsH = require('../handlers/documents');
const alertsH = require('../handlers/alerts');

// name → { description, input_schema(JSON Schema), run(args) -> Promise<data> }
// run 一律只调既有只读 handler；handler 入参约定为 ({ params, query, body })。
const READONLY_TOOLS = {
  get_dashboard: {
    description: '查询经营看板汇总：年度营收 / 毛利率 / 净利率 / 库存 / 进销总量 / 增值税累计与预估应纳。可选 year(YYYY)。',
    input_schema: { type: 'object', properties: { year: { type: 'string', description: 'YYYY，缺省=当前设置年度' } } },
    run: (a) => dashboard.summary({ query: a.year ? { year: String(a.year) } : {} }),
  },
  get_sales: {
    description: '最近销售记录（日期 / 客户 / 数量 / 单价 / 金额 / 税额 / 开票状态）。',
    input_schema: { type: 'object', properties: {} },
    run: () => sales.list({}),
  },
  get_purchases: {
    description: '最近采购记录（日期 / 供应商 / 数量 / 单价 / 金额 / 税额 / 收票状态）。',
    input_schema: { type: 'object', properties: {} },
    run: () => purchases.list({}),
  },
  get_transactions: {
    description: '收支流水。可选 type(income|expense)、from / to(YYYY-MM-DD)、limit。',
    input_schema: {
      type: 'object',
      properties: {
        type: { type: 'string', description: 'income 或 expense' },
        from: { type: 'string', description: '起始日期 YYYY-MM-DD' },
        to: { type: 'string', description: '结束日期 YYYY-MM-DD' },
        limit: { type: 'number' },
      },
    },
    run: (a) => transactions.list({ query: { type: a.type, from: a.from, to: a.to, limit: a.limit } }),
  },
  get_inventory: {
    description: '按商品库存余量与库存总成本（不跨商品合并数量）。',
    input_schema: { type: 'object', properties: {} },
    run: () => inventory.summary({}),
  },
  get_products: {
    description: '商品 / 服务主数据（名称 / 单位 / 默认成本 / 是否服务）。',
    input_schema: { type: 'object', properties: {} },
    run: () => products.list({}),
  },
  get_receivables: {
    description: '应收汇总（总额 / 逾期 / 回款率 / Top 客户）。',
    input_schema: { type: 'object', properties: {} },
    run: () => accounts.receivablesSummary(),
  },
  get_payables: {
    description: '应付汇总（总额 / 逾期 / 付款率 / Top 供应商）。',
    input_schema: { type: 'object', properties: {} },
    run: () => accounts.payablesSummary(),
  },
  get_documents: {
    description: '业务单据列表。可选 type(quotation|sales_order|proforma|commercial|statement)。',
    input_schema: { type: 'object', properties: { type: { type: 'string' } } },
    run: (a) => documentsH.list({ query: { type: a.type } }),
  },
  get_alerts: {
    description: '当前经营预警列表。可选 limit。',
    input_schema: { type: 'object', properties: { limit: { type: 'number' } } },
    run: (a) => alertsH.list({ query: { limit: String(a.limit || 20) } }),
  },
};

// 给 adapter 的中立工具定义（name / description / input_schema 均为标准 JSON Schema）。
function toolDefs() {
  return Object.keys(READONLY_TOOLS).map((name) => ({
    name,
    description: READONLY_TOOLS[name].description,
    input_schema: READONLY_TOOLS[name].input_schema,
  }));
}

// 执行一个只读工具。未知 / 非白名单工具名 → 返回 error 对象（不抛、不执行），喂回模型自纠。
async function executeReadonlyTool(name, args) {
  const tool = READONLY_TOOLS[name];
  if (!tool) return { error: 'forbidden_or_unknown_tool', name };
  return await tool.run(args || {});
}

module.exports = { toolDefs, executeReadonlyTool, READONLY_TOOLS };
