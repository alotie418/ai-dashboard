// AI 业务 handler — 薄壳层
// 把 (method, path) 翻译为 ai/index.js 的统一接口调用
// API Key 全程不出主进程，渲染端只传业务参数

const aiCore = require('../ai');
const { getDb } = require('../db');

// /api/ai/analyze — 经营数据分析
async function analyze({ body }) {
  if (!body?.data) throw new Error('Missing data');
  return aiCore.analyze(body);
}

// /api/ai/ocr — 发票识别
async function ocr({ body }) {
  if (!body?.base64Data || !body?.mimeType) throw new Error('Missing base64Data or mimeType');
  // Inject locale from request body or fall back to DB settings
  if (!body.accountingLocale || !body.uiLanguage) {
    const db = getDb();
    const row = db.prepare("SELECT value FROM settings WHERE key = 'accounting_locale'").get();
    if (!body.accountingLocale) body.accountingLocale = row?.value || 'CN';
    if (!body.uiLanguage) body.uiLanguage = 'zh-CN';
  }
  return aiCore.ocr(body);
}

// /api/ai/chat — 对话
async function chat({ body }) {
  if (!body?.messages) throw new Error('Missing messages');
  return aiCore.chat(body);
}

// /api/ai/agent-chat — 只读查账 agent 对话（主进程跑工具循环，API Key 不出主进程）
async function agentChat({ body }) {
  if (!body?.messages) throw new Error('Missing messages');
  return aiCore.agentChat(body);
}

// /api/ai/data-analysis — 数据分析（含 Web grounding，仅 Gemini 有效）
async function dataAnalysis({ body }) {
  if (!body?.prompt) throw new Error('Missing prompt');
  return aiCore.dataAnalysis(body);
}

// 语音（/api/ai/tts、/api/ai/live-key）已于 AI 助手重设计 R1 移除。

// /api/ai/context — 全数据聚合（本地直查 DB，不依赖外部 AI）
async function context({ body }) {
  const dashboard = require('./dashboard');
  const accounts = require('./receivables');
  const alertsH = require('./alerts');

  const year = body?.year ? String(body.year) : undefined;
  const db = getDb();

  const [dashboardData, salesList, purchasesList, receivablesData, payablesData, alertsList] = await Promise.allSettled([
    dashboard.summary({ query: year ? { year } : {} }),
    Promise.resolve(db.prepare('SELECT * FROM sales ORDER BY date DESC LIMIT 200').all()),
    Promise.resolve(db.prepare('SELECT * FROM purchases ORDER BY date DESC LIMIT 200').all()),
    accounts.receivablesSummary(),
    accounts.payablesSummary(),
    alertsH.list({ query: { limit: '20' } }),
  ]);

  const ok = (p) => p.status === 'fulfilled' ? p.value : null;
  const dash = ok(dashboardData);
  const sales = ok(salesList);
  const purchases = ok(purchasesList);
  const receivables = ok(receivablesData);
  const payables = ok(payablesData);
  const alerts = ok(alertsList);

  const sections = [];

  // Context text is locale-neutral (numeric only). The AI knows
  // the actual currency / tax regime from the system prompt
  // (buildAIFinanceContext) provided by the frontend, and renders
  // its response in the user's uiLanguage.
  const num = (v) => Number(v || 0).toLocaleString();

  if (dash) {
    const fs = dash.financialStatement || {};
    const metrics = dash.metrics || {};
    const perf = dash.monthlyPerformance || [];
    const vat = dash.vatStatistics || {};
    const monthlyStr = perf
      .map(p => `${p.name}: revenue=${num(p.revenue)} / profit=${num(p.profit)} / volume=${num(p.salesTons)}`)
      .join('; ');
    sections.push(`[Dashboard]
Annual revenue: ${num(fs.salesRevenue)}, gross margin: ${fs.grossMargin || 0}%, net margin: ${fs.netMargin || 0}%
Inventory on hand: ${num(metrics.inventoryTons)}, total purchases: ${num(metrics.purchaseTotalTons)}, total sales: ${num(metrics.salesTotalTons)}
Monthly trend: ${monthlyStr}
Tax summary: cumulative input=${num(vat.cumulativeInput)}, cumulative output=${num(vat.cumulativeOutput)}, estimated payable=${num(vat.estimatedPayable)}`);
  }

  if (purchases) {
    const totalAmount = purchases.reduce((s, r) => s + (r.totalAmount || 0), 0);
    const totalTax = purchases.reduce((s, r) => s + (r.taxAmount || 0), 0);
    const recent = purchases.slice(0, 20).map(r =>
      `  ${r.date || ''} ${r.supplier || ''} qty=${num(r.tons)} unit_price=${num(r.pricePerTon)} total=${num(r.totalAmount)} invoice=${r.invoiceStatus || 'unknown'}`
    ).join('\n');
    sections.push(`[Purchases]
Total purchases: ${num(totalAmount)} (${purchases.length} records)
Total input tax: ${num(totalTax)}
Recent purchases:
${recent || '  (none)'}`);
  }

  if (sales) {
    const totalAmount = sales.reduce((s, r) => s + (r.totalAmount || 0), 0);
    const totalTax = sales.reduce((s, r) => s + (r.taxAmount || 0), 0);
    const recent = sales.slice(0, 20).map(r =>
      `  ${r.date || ''} ${r.customer || ''} qty=${num(r.tons)} unit_price=${num(r.pricePerTon)} total=${num(r.totalAmount)} invoice=${r.invoiceStatus || 'unknown'}`
    ).join('\n');
    sections.push(`[Sales]
Total sales: ${num(totalAmount)} (${sales.length} records)
Total output tax: ${num(totalTax)}
Recent sales:
${recent || '  (none)'}`);
  }

  if (sales || purchases) {
    const salesL = sales || [];
    const purchL = purchases || [];
    const salesInvoiced = salesL.filter(r => r.invoiceStatus === '已开').length;
    const purchaseInvoiced = purchL.filter(r => r.invoiceStatus === '已收').length;
    sections.push(`[Invoices]
Output invoices: ${salesInvoiced} issued, ${salesL.length - salesInvoiced} pending
Input invoices: ${purchaseInvoiced} received, ${purchL.length - purchaseInvoiced} pending`);
  }

  if (receivables) {
    sections.push(`[Receivables]
Total receivable: ${num(receivables.totalReceivable)}, overdue: ${num(receivables.totalOverdue)}
Collection rate: ${receivables.collectionRate || 0}%${receivables.topCustomers?.[0] ? `, top customer: ${receivables.topCustomers[0].name} (${num(receivables.topCustomers[0].amount)})` : ''}`);
  }

  if (payables) {
    sections.push(`[Payables]
Total payable: ${num(payables.totalPayable)}, overdue: ${num(payables.totalOverdue)}
Payment rate: ${payables.paymentRate || 0}%${payables.topSuppliers?.[0] ? `, top supplier: ${payables.topSuppliers[0].name} (${num(payables.topSuppliers[0].amount)})` : ''}`);
  }

  if (dash?.financialStatement) {
    const f = dash.financialStatement;
    sections.push(`[Financial statement]
Revenue: ${num(f.salesRevenue)}, COGS: ${num(f.costOfSales)}
Gross profit: ${num(f.grossProfit)}, net profit: ${num(f.netProfit)}
Tax surcharge: ${num(f.taxSurcharge)}, admin expense: ${num(f.adminExpense)}, shipping: ${num(f.shippingFee)}`);
  }

  if (alerts && alerts.length > 0) {
    const alertStr = alerts.slice(0, 10).map(a => `  [${a.type || ''}] ${a.title || ''}`).join('\n');
    sections.push(`[Alerts]\n${alerts.length} active:\n${alertStr}`);
  } else {
    sections.push(`【系统告警】\n无告警`);
  }

  return { context: sections.join('\n\n') };
}

module.exports = { analyze, ocr, context, chat, agentChat, dataAnalysis };
