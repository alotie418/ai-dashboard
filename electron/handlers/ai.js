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
  return aiCore.ocr(body);
}

// /api/ai/chat — 对话
async function chat({ body }) {
  if (!body?.messages) throw new Error('Missing messages');
  return aiCore.chat(body);
}

// /api/ai/tts — 语音合成
async function tts({ body }) {
  if (!body?.text) throw new Error('Missing text');
  return aiCore.tts(body);
}

// /api/ai/data-analysis — 数据分析（含 Web grounding，仅 Gemini 有效）
async function dataAnalysis({ body }) {
  if (!body?.prompt) throw new Error('Missing prompt');
  return aiCore.dataAnalysis(body);
}

// /api/ai/live-key — Live Audio 用 Key（仅 Gemini）
async function liveKey() {
  return aiCore.liveKey();
}

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

  if (dash) {
    const fs = dash.financialStatement || {};
    const metrics = dash.metrics || {};
    const perf = dash.monthlyPerformance || [];
    const vat = dash.vatStatistics || {};
    const monthlyStr = perf
      .map(p => `${p.name}:营收¥${(p.revenue || 0).toLocaleString()}/利润¥${(p.profit || 0).toLocaleString()}/销量${p.salesTons || 0}t`)
      .join('；');
    sections.push(`【经营看板】
年度营收: ¥${(fs.salesRevenue || 0).toLocaleString()}, 毛利率: ${fs.grossMargin || 0}%, 净利率: ${fs.netMargin || 0}%
库存余量: ${(metrics.inventoryTons || 0).toLocaleString()}吨, 采购总量: ${(metrics.purchaseTotalTons || 0).toLocaleString()}吨, 销售总量: ${(metrics.salesTotalTons || 0).toLocaleString()}吨
月度趋势: ${monthlyStr}
增值税统计: 累计进项¥${(vat.cumulativeInput || 0).toLocaleString()}, 累计销项¥${(vat.cumulativeOutput || 0).toLocaleString()}, 估算应纳增值税¥${(vat.estimatedPayable || 0).toLocaleString()}`);
  }

  if (purchases) {
    const totalAmount = purchases.reduce((s, r) => s + (r.totalAmount || 0), 0);
    const totalTax = purchases.reduce((s, r) => s + (r.taxAmount || 0), 0);
    const recent = purchases.slice(0, 20).map(r =>
      `  ${r.date || ''} ${r.supplier || ''} ${r.tons || 0}吨 ¥${(r.pricePerTon || 0).toLocaleString()}/吨 总额¥${(r.totalAmount || 0).toLocaleString()} 发票:${r.invoiceStatus || '未知'}`
    ).join('\n');
    sections.push(`【采购与进项】
采购总额: ¥${totalAmount.toLocaleString()}, 共${purchases.length}笔
进项税合计: ¥${totalTax.toLocaleString()}
最近采购记录:
${recent || '  无记录'}`);
  }

  if (sales) {
    const totalAmount = sales.reduce((s, r) => s + (r.totalAmount || 0), 0);
    const totalTax = sales.reduce((s, r) => s + (r.taxAmount || 0), 0);
    const recent = sales.slice(0, 20).map(r =>
      `  ${r.date || ''} ${r.customer || ''} ${r.tons || 0}吨 ¥${(r.pricePerTon || 0).toLocaleString()}/吨 总额¥${(r.totalAmount || 0).toLocaleString()} 发票:${r.invoiceStatus || '未知'}`
    ).join('\n');
    sections.push(`【销售与销项】
销售总额: ¥${totalAmount.toLocaleString()}, 共${sales.length}笔
销项税合计: ¥${totalTax.toLocaleString()}
最近销售记录:
${recent || '  无记录'}`);
  }

  if (sales || purchases) {
    const salesL = sales || [];
    const purchL = purchases || [];
    const salesInvoiced = salesL.filter(r => r.invoiceStatus === '已开').length;
    const purchaseInvoiced = purchL.filter(r => r.invoiceStatus === '已收').length;
    sections.push(`【发票查询】
销项发票: 已开${salesInvoiced}张, 待开${salesL.length - salesInvoiced}张
进项发票: 已收${purchaseInvoiced}张, 待收${purchL.length - purchaseInvoiced}张`);
  }

  if (receivables) {
    sections.push(`【应收账款】
应收总额: ¥${(receivables.totalReceivable || 0).toLocaleString()}, 逾期金额: ¥${(receivables.totalOverdue || 0).toLocaleString()}
回款率: ${receivables.collectionRate || 0}%${receivables.topCustomers?.[0] ? `, 最大客户: ${receivables.topCustomers[0].name} (¥${(receivables.topCustomers[0].amount || 0).toLocaleString()})` : ''}`);
  }

  if (payables) {
    sections.push(`【应付账款】
应付总额: ¥${(payables.totalPayable || 0).toLocaleString()}, 逾期金额: ¥${(payables.totalOverdue || 0).toLocaleString()}
付款率: ${payables.paymentRate || 0}%${payables.topSuppliers?.[0] ? `, 最大供应商: ${payables.topSuppliers[0].name} (¥${(payables.topSuppliers[0].amount || 0).toLocaleString()})` : ''}`);
  }

  if (dash?.financialStatement) {
    const f = dash.financialStatement;
    sections.push(`【财务报表】
营业收入: ¥${(f.salesRevenue || 0).toLocaleString()}, 营业成本: ¥${(f.costOfSales || 0).toLocaleString()}
毛利润: ¥${(f.grossProfit || 0).toLocaleString()}, 净利润: ¥${(f.netProfit || 0).toLocaleString()}
税金及附加: ¥${(f.taxSurcharge || 0).toLocaleString()}, 管理费用: ¥${(f.adminExpense || 0).toLocaleString()}, 运费: ¥${(f.shippingFee || 0).toLocaleString()}`);
  }

  if (alerts && alerts.length > 0) {
    const alertStr = alerts.slice(0, 10).map(a => `  [${a.type || ''}] ${a.title || ''}`).join('\n');
    sections.push(`【系统告警】\n${alerts.length}条告警:\n${alertStr}`);
  } else {
    sections.push(`【系统告警】\n无告警`);
  }

  return { context: sections.join('\n\n') };
}

module.exports = { analyze, ocr, context, chat, tts, dataAnalysis, liveKey };
