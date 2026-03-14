// Cloud Run Express server — serves static frontend + RAG agent endpoints
// Session-based auth, AI proxy endpoints, Cloudflare Worker proxy

// Load .env.local for local development (no-op if file doesn't exist)
import { readFileSync } from 'fs';
try {
  const envFile = readFileSync('.env.local', 'utf8');
  for (const line of envFile.split('\n')) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const eqIdx = trimmed.indexOf('=');
    if (eqIdx === -1) continue;
    const key = trimmed.slice(0, eqIdx);
    const val = trimmed.slice(eqIdx + 1);
    if (!process.env[key]) process.env[key] = val;
  }
} catch { /* .env.local not found, using process env */ }

import express from 'express';
import helmet from 'helmet';
import rateLimit from 'express-rate-limit';
import { createProxyMiddleware } from 'http-proxy-middleware';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

import { callGeminiWithFallback } from './server/gemini.js';
import { buildPlanPrompt, buildExtractPrompt, buildSynthesisPrompt, buildCritiquePrompt } from './server/prompts.js';
import {
  PLAN_RESPONSE_SCHEMA,
  SYNTHESIS_RESPONSE_SCHEMA,
  CRITIQUE_RESPONSE_SCHEMA,
  validateExtractResponse,
  parseGeminiJSON,
} from './server/schemas.js';
import { rankAndDedup, rankAndDedupSemantic } from './server/ranking.js';
import { embedTexts, cosineSimilarity, mmrSelect } from './server/embedding.js';
import { createSessionMiddleware, authGuard, verifyPassword, AUTH_USERNAME } from './server/auth.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const app = express();
app.set('trust proxy', 1); // Trust Cloud Run's HTTPS load balancer for secure cookies
const PORT = process.env.PORT || 8080;
const GEMINI_API_KEY = process.env.GEMINI_API_KEY;
const TAVILY_API_KEY = process.env.TAVILY_API_KEY;
const WORKER_API_URL = process.env.WORKER_API_URL || 'https://api.randomabc987.icu';
const WORKER_API_TOKEN = process.env.API_TOKEN; // Bearer token for Cloudflare Worker auth

// ==================== Security Headers ====================

app.use(helmet({
  contentSecurityPolicy: {
    directives: {
      defaultSrc: ["'self'"],
      scriptSrc: ["'self'", "'unsafe-inline'", "'unsafe-eval'", "https://cdn.tailwindcss.com", "https://esm.sh"],
      styleSrc: ["'self'", "'unsafe-inline'", "https://cdnjs.cloudflare.com", "https://fonts.googleapis.com"],
      fontSrc: ["'self'", "https://cdnjs.cloudflare.com", "https://fonts.gstatic.com"],
      imgSrc: ["'self'", "data:", "https:"],
      connectSrc: ["'self'", "https://generativelanguage.googleapis.com", "wss://generativelanguage.googleapis.com"],
    },
  },
}));

// ==================== Middleware ====================

app.use(express.json({ limit: '10mb' }));

// Session
app.use(createSessionMiddleware());

// Auth guard (before any routes)
app.use(authGuard);

// Request logging
app.use((req, res, next) => {
  if (req.path.startsWith('/api/') || req.path.startsWith('/auth/')) {
    const start = Date.now();
    res.on('finish', () => {
      console.log(JSON.stringify({
        ts: new Date().toISOString(),
        method: req.method,
        path: req.path,
        status: res.statusCode,
        duration_ms: Date.now() - start,
      }));
    });
  }
  next();
});

// ==================== Health ====================

app.get('/health', (req, res) => res.json({ status: 'ok', server: 'cloud-run' }));

// ==================== Auth Endpoints ====================

const loginLimiter = rateLimit({
  windowMs: 15 * 60 * 1000, // 15 minutes
  max: 10,
  message: { error: '登录尝试过多，请 15 分钟后再试' },
  standardHeaders: true,
  legacyHeaders: false,
});

app.post('/auth/login', loginLimiter, async (req, res) => {
  const { username, password } = req.body;
  if (!username || !password) {
    return res.status(400).json({ error: '请输入用户名和密码' });
  }
  if (username !== AUTH_USERNAME) {
    return res.status(401).json({ error: '用户名或密码错误' });
  }
  const valid = await verifyPassword(password);
  if (!valid) {
    return res.status(401).json({ error: '用户名或密码错误' });
  }
  req.session.authenticated = true;
  req.session.username = username;
  res.json({ ok: true, username });
});

app.post('/auth/logout', (req, res) => {
  req.session.destroy(() => {
    res.clearCookie('sid');
    res.json({ ok: true });
  });
});

app.get('/auth/check', (req, res) => {
  if (req.session && req.session.authenticated) {
    return res.json({ authenticated: true, username: req.session.username });
  }
  res.json({ authenticated: false });
});

app.post('/auth/change-password', async (req, res) => {
  if (!req.session || !req.session.authenticated) {
    return res.status(401).json({ error: '请先登录' });
  }
  const { currentPassword, newPassword } = req.body;
  if (!currentPassword || !newPassword) {
    return res.status(400).json({ error: '请填写所有密码字段' });
  }
  if (newPassword.length < 6) {
    return res.status(400).json({ error: '新密码至少 6 个字符' });
  }
  const valid = await verifyPassword(currentPassword);
  if (!valid) {
    return res.status(401).json({ error: '当前密码不正确' });
  }
  try {
    const bcrypt = await import('bcryptjs');
    const newHash = await bcrypt.default.hash(newPassword, 12);
    process.env.AUTH_PASSWORD_HASH = newHash;
    await savePasswordHashToDB(newHash);
    console.log(`[Auth] Password changed by ${req.session.username}`);
    res.json({ ok: true });
  } catch (err) {
    console.error('[Auth] Password change failed:', err.message);
    res.status(500).json({ error: '密码修改失败，请重试' });
  }
});

// ==================== Persistent Password Hash (D1 via Worker) ====================

async function loadPasswordHashFromDB() {
  try {
    const headers = { 'Content-Type': 'application/json' };
    if (WORKER_API_TOKEN) headers['Authorization'] = `Bearer ${WORKER_API_TOKEN}`;
    const res = await fetch(`${WORKER_API_URL}/api/settings`, { headers });
    if (!res.ok) return;
    const settings = await res.json();
    if (settings.auth_password_hash) {
      process.env.AUTH_PASSWORD_HASH = settings.auth_password_hash;
      console.log('[Auth] Loaded password hash from D1 database');
    }
  } catch (err) {
    console.warn('[Auth] Could not load password from D1, using env var:', err.message);
  }
}

async function savePasswordHashToDB(hash) {
  try {
    const headers = { 'Content-Type': 'application/json' };
    if (WORKER_API_TOKEN) headers['Authorization'] = `Bearer ${WORKER_API_TOKEN}`;
    // Read current settings first, then merge
    const getRes = await fetch(`${WORKER_API_URL}/api/settings`, { headers });
    const current = getRes.ok ? await getRes.json() : {};
    const updated = { ...current, auth_password_hash: hash };
    const putRes = await fetch(`${WORKER_API_URL}/api/settings`, {
      method: 'PUT',
      headers,
      body: JSON.stringify(updated),
    });
    if (!putRes.ok) throw new Error(`HTTP ${putRes.status}`);
    console.log('[Auth] Password hash saved to D1 database');
  } catch (err) {
    console.error('[Auth] Failed to save password to D1:', err.message);
  }
}

// ==================== API Rate Limit ====================

const apiLimiter = rateLimit({
  windowMs: 60 * 1000,
  max: 120,
  message: { error: 'API 请求过于频繁，请稍后再试' },
  standardHeaders: true,
  legacyHeaders: false,
});

app.use('/api', apiLimiter);

// ==================== AI Proxy Endpoints ====================

// --- AI Business Analysis ---
app.post('/api/ai/analyze', async (req, res) => {
  const start = Date.now();
  try {
    const { data, marketSummary } = req.body;
    if (!data) return res.status(400).json({ error: 'Missing data' });
    if (!GEMINI_API_KEY) return res.status(500).json({ error: 'GEMINI_API_KEY not configured' });

    const { GoogleGenAI, Type } = await import('@google/genai');
    const ai = new GoogleGenAI({ apiKey: GEMINI_API_KEY });

    const marketContext = marketSummary
      ? `\n\n## 最新市场搜索数据\n${marketSummary}\n请将市场价格信息纳入分析，在建议中结合市场行情给出采购/销售策略。`
      : '';

    const systemInstruction = `你是一位专业的商业分析师。请分析以下企业经营数据，给出：
1. summary: 一段简要的经营概况总结
2. topInsights: 3-5条关键洞察（数组）
3. recommendations: 3-5条改进建议（数组）
4. anomalies: 异常指标列表（数组）`;

    const response = await ai.models.generateContent({
      model: 'gemini-2.0-flash',
      contents: `Analyze this business data and provide insights: ${JSON.stringify(data)}${marketContext}`,
      config: {
        systemInstruction,
        responseMimeType: 'application/json',
        responseSchema: {
          type: Type.OBJECT,
          properties: {
            summary: { type: Type.STRING },
            topInsights: { type: Type.ARRAY, items: { type: Type.STRING } },
            recommendations: { type: Type.ARRAY, items: { type: Type.STRING } },
            anomalies: { type: Type.ARRAY, items: { type: Type.STRING } },
          },
          required: ['summary', 'topInsights', 'recommendations', 'anomalies'],
        },
      },
    });

    const result = JSON.parse(response.text || '{}');
    console.log(`[AI/Analyze] ${Date.now() - start}ms`);
    res.json(result);
  } catch (err) {
    console.error(`[AI/Analyze] Error (${Date.now() - start}ms):`, err.message);
    res.status(502).json({ error: err.message });
  }
});

// --- AI OCR (Invoice) ---
app.post('/api/ai/ocr', async (req, res) => {
  const start = Date.now();
  try {
    const { base64Data, mimeType } = req.body;
    if (!base64Data || !mimeType) return res.status(400).json({ error: 'Missing base64Data or mimeType' });
    if (!GEMINI_API_KEY) return res.status(500).json({ error: 'GEMINI_API_KEY not configured' });

    const { GoogleGenAI } = await import('@google/genai');
    const ai = new GoogleGenAI({ apiKey: GEMINI_API_KEY });

    const prompt = `
    你是一位专业的财务审计员。请从这张发票图片中提取以下信息，并严格以 JSON 格式返回（不要包含 markdown 代码块标记）：
    {
      "date": "开票日期，格式 YYYY-MM-DD",
      "customer": "客户名称/购方名称",
      "quantity": "货物总数量及单位，例如 36.5吨 / 3650袋（如有多行货物请合计总数量）",
      "price": 合计不含税金额数字（即"金额"栏的合计值）,
      "shipping": 运费数字（没有则为0）,
      "invoiceNo": "发票号码",
      "totalWithTax": 价税合计金额数字（即发票上"价税合计"或"（小写）"对应的含税总额）,
      "unitPriceWithoutTax": 不含税单价数字（即"单价"栏的值，如有多行货物取第一行的单价）,
      "taxAmount": 合计税额数字（即"税额"栏的合计值）
    }

    注意：price、shipping、totalWithTax、unitPriceWithoutTax、taxAmount 必须是数字，不要加引号。如果发票上没有对应字段则填 0。
    `;

    const response = await ai.models.generateContent({
      model: 'gemini-2.0-flash',
      contents: [
        {
          parts: [
            { text: prompt },
            { inlineData: { data: base64Data, mimeType } },
          ],
        },
      ],
    });

    const text = response.text;
    if (!text) throw new Error('AI response was empty');
    const cleaned = text.replace(/^```(?:json)?\s*\n?/i, '').replace(/\n?```\s*$/i, '').trim();
    const result = JSON.parse(cleaned);
    console.log(`[AI/OCR] ${Date.now() - start}ms`);
    res.json(result);
  } catch (err) {
    console.error(`[AI/OCR] Error (${Date.now() - start}ms):`, err.message);
    res.status(502).json({ error: err.message });
  }
});

// --- AI Context Aggregation (全数据联通) ---
app.post('/api/ai/context', async (req, res) => {
  const start = Date.now();
  try {
    const { year } = req.body || {};
    const headers = { 'Content-Type': 'application/json' };
    if (WORKER_API_TOKEN) headers['Authorization'] = `Bearer ${WORKER_API_TOKEN}`;

    // Parallel fetch all module data from Worker
    const [dashboardRes, salesRes, purchasesRes, receivablesRes, payablesRes, alertsRes] = await Promise.allSettled([
      fetch(`${WORKER_API_URL}/api/dashboard${year ? `?year=${year}` : ''}`, { headers }),
      fetch(`${WORKER_API_URL}/api/sales${year ? `?year=${year}` : ''}`, { headers }),
      fetch(`${WORKER_API_URL}/api/purchases${year ? `?year=${year}` : ''}`, { headers }),
      fetch(`${WORKER_API_URL}/api/receivables/summary${year ? `?year=${year}` : ''}`, { headers }),
      fetch(`${WORKER_API_URL}/api/payables/summary${year ? `?year=${year}` : ''}`, { headers }),
      fetch(`${WORKER_API_URL}/api/alerts`, { headers }),
    ]);

    const safeJson = async (result) => {
      if (result.status === 'fulfilled' && result.value.ok) {
        try { return await result.value.json(); } catch { return null; }
      }
      return null;
    };

    const [dashboard, sales, purchases, receivables, payables, alerts] = await Promise.all([
      safeJson(dashboardRes), safeJson(salesRes), safeJson(purchasesRes),
      safeJson(receivablesRes), safeJson(payablesRes), safeJson(alertsRes),
    ]);

    // Build structured context text
    const sections = [];

    // 【经营看板】
    if (dashboard) {
      const fs = dashboard.financialStatement || {};
      const metrics = dashboard.metrics || {};
      const perf = dashboard.monthlyPerformance || [];
      const vat = dashboard.vatStatistics || {};
      const monthlyStr = perf.map(p => `${p.name}:营收¥${(p.revenue||0).toLocaleString()}/利润¥${(p.profit||0).toLocaleString()}/销量${p.salesTons||0}t`).join('；');
      sections.push(`【经营看板】
年度营收: ¥${(fs.salesRevenue||0).toLocaleString()}, 毛利率: ${fs.grossMargin||0}%, 净利率: ${fs.netMargin||0}%
库存余量: ${(metrics.inventoryTons||0).toLocaleString()}吨, 采购总量: ${(metrics.purchaseTons||0).toLocaleString()}吨, 销售总量: ${(metrics.salesTons||0).toLocaleString()}吨
月度趋势: ${monthlyStr}
增值税统计: 累计进项¥${(vat.cumulativeInput||0).toLocaleString()}, 累计销项¥${(vat.cumulativeOutput||0).toLocaleString()}, 应纳增值税¥${(vat.vatPayable||0).toLocaleString()}`);
    }

    // 【采购与进项】
    if (purchases) {
      const list = Array.isArray(purchases) ? purchases : (purchases.records || purchases.data || []);
      const totalAmount = list.reduce((s, r) => s + (r.totalAmount || r.amount || 0), 0);
      const totalTax = list.reduce((s, r) => s + (r.taxAmount || 0), 0);
      const recent = list.slice(0, 20).map(r =>
        `  ${r.date||''} ${r.supplier||r.company||''} ${r.quantity||''}吨 ¥${(r.unitPrice||0).toLocaleString()}/吨 总额¥${(r.totalAmount||r.amount||0).toLocaleString()} 发票:${r.invoiceStatus||r.invoice||'未知'}`
      ).join('\n');
      sections.push(`【采购与进项】
采购总额: ¥${totalAmount.toLocaleString()}, 共${list.length}笔
进项税合计: ¥${totalTax.toLocaleString()}
最近采购记录:
${recent || '  无记录'}`);
    }

    // 【销售与销项】
    if (sales) {
      const list = Array.isArray(sales) ? sales : (sales.records || sales.data || []);
      const totalAmount = list.reduce((s, r) => s + (r.totalAmount || r.amount || 0), 0);
      const totalTax = list.reduce((s, r) => s + (r.taxAmount || 0), 0);
      const recent = list.slice(0, 20).map(r =>
        `  ${r.date||''} ${r.customer||r.company||''} ${r.quantity||''}吨 ¥${(r.unitPrice||0).toLocaleString()}/吨 总额¥${(r.totalAmount||r.amount||0).toLocaleString()} 发票:${r.invoiceStatus||r.invoice||'未知'}`
      ).join('\n');
      sections.push(`【销售与销项】
销售总额: ¥${totalAmount.toLocaleString()}, 共${list.length}笔
销项税合计: ¥${totalTax.toLocaleString()}
最近销售记录:
${recent || '  无记录'}`);
    }

    // 【发票查询】(extracted from sales + purchases)
    if (sales || purchases) {
      const salesList = sales ? (Array.isArray(sales) ? sales : (sales.records || sales.data || [])) : [];
      const purchaseList = purchases ? (Array.isArray(purchases) ? purchases : (purchases.records || purchases.data || [])) : [];
      const salesInvoiced = salesList.filter(r => r.invoiceStatus === '已开票' || r.invoice === '已开票').length;
      const salesPending = salesList.length - salesInvoiced;
      const purchaseInvoiced = purchaseList.filter(r => r.invoiceStatus === '已开票' || r.invoice === '已开票').length;
      const purchasePending = purchaseList.length - purchaseInvoiced;
      sections.push(`【发票查询】
销项发票: 已开${salesInvoiced}张, 待开${salesPending}张
进项发票: 已收${purchaseInvoiced}张, 待收${purchasePending}张`);
    }

    // 【增值税统计】
    if (dashboard?.vatStatistics) {
      const vat = dashboard.vatStatistics;
      sections.push(`【增值税统计】
累计进项: ¥${(vat.cumulativeInput||0).toLocaleString()}, 累计销项: ¥${(vat.cumulativeOutput||0).toLocaleString()}
应纳增值税: ¥${(vat.vatPayable||0).toLocaleString()}`);
    }

    // 【应收账款】
    if (receivables) {
      const r = receivables;
      sections.push(`【应收账款】
应收总额: ¥${(r.totalReceivable||r.total||0).toLocaleString()}, 逾期金额: ¥${(r.overdueAmount||r.overdue||0).toLocaleString()}
回款率: ${r.collectionRate||r.rate||0}%${r.topCustomer ? `, 最大客户: ${r.topCustomer.name||r.topCustomer} (¥${(r.topCustomer.amount||0).toLocaleString()})` : ''}
${r.details ? r.details.slice(0, 10).map(d => `  ${d.customer||d.name||''}: ¥${(d.amount||0).toLocaleString()} ${d.overdue ? '(逾期)' : ''}`).join('\n') : ''}`);
    }

    // 【应付账款】
    if (payables) {
      const p = payables;
      sections.push(`【应付账款】
应付总额: ¥${(p.totalPayable||p.total||0).toLocaleString()}, 逾期金额: ¥${(p.overdueAmount||p.overdue||0).toLocaleString()}
付款率: ${p.paymentRate||p.rate||0}%${p.topSupplier ? `, 最大供应商: ${p.topSupplier.name||p.topSupplier} (¥${(p.topSupplier.amount||0).toLocaleString()})` : ''}
${p.details ? p.details.slice(0, 10).map(d => `  ${d.supplier||d.name||''}: ¥${(d.amount||0).toLocaleString()} ${d.overdue ? '(逾期)' : ''}`).join('\n') : ''}`);
    }

    // 【财务报表】
    if (dashboard?.financialStatement) {
      const f = dashboard.financialStatement;
      sections.push(`【财务报表】
营业收入: ¥${(f.salesRevenue||0).toLocaleString()}, 营业成本: ¥${(f.costOfGoods||0).toLocaleString()}
毛利润: ¥${(f.grossProfit||0).toLocaleString()}, 净利润: ¥${(f.netProfit||0).toLocaleString()}
税金及附加: ¥${(f.taxAndSurcharge||0).toLocaleString()}, 管理费用: ¥${(f.adminExpense||0).toLocaleString()}, 运费: ¥${(f.shippingCost||0).toLocaleString()}`);
    }

    // 【系统告警】
    if (alerts) {
      const list = Array.isArray(alerts) ? alerts : (alerts.alerts || alerts.data || []);
      if (list.length > 0) {
        const alertStr = list.slice(0, 10).map(a => `  [${a.type||a.level||''}] ${a.title||a.message||''}`).join('\n');
        sections.push(`【系统告警】
${list.length}条告警:
${alertStr}`);
      } else {
        sections.push(`【系统告警】\n无告警`);
      }
    }

    const context = sections.join('\n\n');
    console.log(`[AI/Context] ${Date.now() - start}ms, sections=${sections.length}, chars=${context.length}`);
    res.json({ context });
  } catch (err) {
    console.error(`[AI/Context] Error (${Date.now() - start}ms):`, err.message);
    res.status(502).json({ error: err.message });
  }
});

// --- AI Chat ---
app.post('/api/ai/chat', async (req, res) => {
  const start = Date.now();
  try {
    const { messages, systemInstruction } = req.body;
    if (!messages) return res.status(400).json({ error: 'Missing messages' });
    if (!GEMINI_API_KEY) return res.status(500).json({ error: 'GEMINI_API_KEY not configured' });

    const { GoogleGenAI } = await import('@google/genai');
    const ai = new GoogleGenAI({ apiKey: GEMINI_API_KEY });

    const response = await ai.models.generateContent({
      model: 'gemini-2.0-flash',
      contents: messages,
      config: {
        tools: [{ googleSearch: {} }],
        systemInstruction: systemInstruction || '',
      },
    });

    const text = response.candidates?.[0]?.content?.parts?.[0]?.text || response.text || '';
    console.log(`[AI/Chat] ${Date.now() - start}ms`);
    res.json({ text });
  } catch (err) {
    console.error(`[AI/Chat] Error (${Date.now() - start}ms):`, err.message);
    res.status(502).json({ error: err.message });
  }
});

// --- AI TTS ---
app.post('/api/ai/tts', async (req, res) => {
  const start = Date.now();
  try {
    const { text, voiceName } = req.body;
    if (!text) return res.status(400).json({ error: 'Missing text' });
    if (!GEMINI_API_KEY) return res.status(500).json({ error: 'GEMINI_API_KEY not configured' });

    const { GoogleGenAI, Modality } = await import('@google/genai');
    const ai = new GoogleGenAI({ apiKey: GEMINI_API_KEY });

    const response = await ai.models.generateContent({
      model: 'gemini-2.5-flash-preview-tts',
      contents: [{ parts: [{ text }] }],
      config: {
        responseModalities: [Modality.AUDIO],
        speechConfig: { voiceConfig: { prebuiltVoiceConfig: { voiceName: voiceName || 'Aoede' } } },
      },
    });

    const audioData = response.candidates?.[0]?.content?.parts?.[0]?.inlineData?.data;
    console.log(`[AI/TTS] ${Date.now() - start}ms`);
    res.json({ data: audioData || null });
  } catch (err) {
    console.error(`[AI/TTS] Error (${Date.now() - start}ms):`, err.message);
    res.status(502).json({ error: err.message });
  }
});

// --- Tavily Search (Chat context) ---
app.post('/api/ai/tavily-search', async (req, res) => {
  const start = Date.now();
  try {
    const { query } = req.body;
    if (!query) return res.status(400).json({ error: 'Missing query' });
    if (!TAVILY_API_KEY) return res.json({ results: [] });

    const response = await fetch('https://api.tavily.com/search', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        api_key: TAVILY_API_KEY,
        query,
        search_depth: 'basic',
        max_results: 5,
        include_answer: false,
      }),
    });

    if (!response.ok) {
      console.error(`[AI/Tavily] HTTP ${response.status}`);
      return res.json({ results: [] });
    }

    const data = await response.json();
    console.log(`[AI/Tavily] ${Date.now() - start}ms, results=${data.results?.length || 0}`);
    res.json({ results: data.results || [] });
  } catch (err) {
    console.error(`[AI/Tavily] Error (${Date.now() - start}ms):`, err.message);
    res.json({ results: [] });
  }
});

// --- AI Data Analysis (with Google Search grounding) ---
app.post('/api/ai/data-analysis', async (req, res) => {
  const start = Date.now();
  try {
    const { prompt, systemInstruction, responseSchema } = req.body;
    if (!prompt) return res.status(400).json({ error: 'Missing prompt' });
    if (!GEMINI_API_KEY) return res.status(500).json({ error: 'GEMINI_API_KEY not configured' });

    const { GoogleGenAI, Type } = await import('@google/genai');
    const ai = new GoogleGenAI({ apiKey: GEMINI_API_KEY });

    const response = await ai.models.generateContent({
      model: 'gemini-3-flash-preview',
      contents: prompt,
      config: {
        tools: [{ googleSearch: {} }],
        systemInstruction: systemInstruction || '',
        responseMimeType: 'application/json',
        responseSchema: responseSchema || undefined,
      },
    });

    const text = response.text || '{}';
    const result = JSON.parse(text);

    // Extract grounding sources
    const chunks = response.candidates?.[0]?.groundingMetadata?.groundingChunks;
    const groundingSources = [];
    if (chunks) {
      for (const chunk of chunks) {
        if (chunk.web) {
          groundingSources.push({ title: chunk.web.title || 'Reference', uri: chunk.web.uri });
        }
      }
    }

    console.log(`[AI/DataAnalysis] ${Date.now() - start}ms, sources=${groundingSources.length}`);
    res.json({ ...result, groundingSources });
  } catch (err) {
    console.error(`[AI/DataAnalysis] Error (${Date.now() - start}ms):`, err.message);
    res.status(502).json({ error: err.message });
  }
});

// --- Live Audio Key (short-lived key endpoint for WebSocket live sessions) ---
app.get('/api/ai/live-key', (req, res) => {
  if (!GEMINI_API_KEY) return res.status(500).json({ error: 'GEMINI_API_KEY not configured' });
  // Return key for authenticated sessions only (authGuard already checked session)
  res.json({ key: GEMINI_API_KEY });
});

// ==================== Agent Endpoints ====================

// --- Plan Agent ---
app.post('/api/agent/plan', async (req, res) => {
  const start = Date.now();
  try {
    const { query } = req.body;
    if (!query) return res.status(400).json({ error: 'Missing query' });
    if (!GEMINI_API_KEY) return res.status(500).json({ error: 'GEMINI_API_KEY not configured' });

    const prompt = buildPlanPrompt(query);
    const { text, modelUsed } = await callGeminiWithFallback(GEMINI_API_KEY, {
      contents: [{ parts: [{ text: prompt }] }],
      generationConfig: {
        responseMimeType: 'application/json',
        responseSchema: PLAN_RESPONSE_SCHEMA,
      },
    });

    const parsed = parseGeminiJSON(text);
    if (!parsed) {
      return res.status(502).json({ error: 'Failed to parse plan response', raw: text.slice(0, 500) });
    }

    console.log(`[Plan] ${Date.now() - start}ms, model=${modelUsed}, sub_queries=${parsed.sub_queries?.length || 0}`);
    res.json(parsed);
  } catch (err) {
    console.error(`[Plan] Error (${Date.now() - start}ms):`, err.message);
    res.status(502).json({ error: err.message });
  }
});

// --- Rank Agent (Semantic with Embedding 2, fallback to keyword) ---
app.post('/api/agent/rank', async (req, res) => {
  const start = Date.now();
  try {
    const { query, results } = req.body;
    if (!query || !results) return res.status(400).json({ error: 'Missing query or results' });

    let result;
    if (GEMINI_API_KEY) {
      result = await rankAndDedupSemantic(GEMINI_API_KEY, query, results);
    } else {
      result = rankAndDedup(query, results);
    }
    console.log(`[Rank] ${Date.now() - start}ms, method=${result.dedup_stats.method || 'keyword'}, before=${result.dedup_stats.before}, after=${result.dedup_stats.after}`);
    res.json(result);
  } catch (err) {
    console.error(`[Rank] Error (${Date.now() - start}ms):`, err.message);
    res.status(500).json({ error: err.message });
  }
});

// --- Extract Agent (with MMR evidence re-ranking) ---
app.post('/api/agent/extract', async (req, res) => {
  const start = Date.now();
  try {
    const { query, search_results } = req.body;
    if (!query || !search_results) return res.status(400).json({ error: 'Missing query or search_results' });
    if (!GEMINI_API_KEY) return res.status(500).json({ error: 'GEMINI_API_KEY not configured' });

    const prompt = buildExtractPrompt(query, search_results);
    const { text, modelUsed } = await callGeminiWithFallback(GEMINI_API_KEY, {
      contents: [{ parts: [{ text: prompt }] }],
      generationConfig: { responseMimeType: 'application/json' },
    });

    const parsed = parseGeminiJSON(text);
    const validated = validateExtractResponse(parsed);

    // MMR re-ranking
    let finalEvidence = validated.evidence;
    if (finalEvidence.length > 2) {
      try {
        const evidenceTexts = finalEvidence.map(e => e.text);
        const allTexts = [query, ...evidenceTexts];
        const embeddings = await embedTexts(GEMINI_API_KEY, allTexts, 'RETRIEVAL_DOCUMENT');

        if (embeddings.length === allTexts.length) {
          const queryEmb = embeddings[0];
          const evidenceEmbs = embeddings.slice(1);
          const mmrIndices = mmrSelect(queryEmb, evidenceEmbs, finalEvidence.length, 0.7);

          const reranked = mmrIndices.map(idx => {
            const e = finalEvidence[idx];
            const sim = cosineSimilarity(queryEmb, evidenceEmbs[idx]);
            if (sim < 0.3) {
              e.confidence = Math.round(e.confidence * 0.5 * 100) / 100;
            }
            return { ...e, semantic_relevance: Math.round(sim * 1000) / 1000 };
          });

          finalEvidence = reranked;
          console.log(`[Extract] MMR re-ranked ${reranked.length} evidence items`);
        }
      } catch (embErr) {
        console.warn(`[Extract] MMR re-ranking skipped: ${embErr.message}`);
      }
    }

    console.log(`[Extract] ${Date.now() - start}ms, model=${modelUsed}, evidence=${finalEvidence.length}`);
    res.json({ evidence: finalEvidence });
  } catch (err) {
    console.error(`[Extract] Error (${Date.now() - start}ms):`, err.message);
    res.status(502).json({ error: err.message });
  }
});

// --- Synthesize Agent ---
app.post('/api/agent/synthesize', async (req, res) => {
  const start = Date.now();
  try {
    const { query, question_type, evidence_pool, iteration } = req.body;
    if (!query || !evidence_pool) return res.status(400).json({ error: 'Missing required fields' });
    if (!GEMINI_API_KEY) return res.status(500).json({ error: 'GEMINI_API_KEY not configured' });

    const prompt = buildSynthesisPrompt(query, question_type, evidence_pool, iteration || 1);
    const { text, modelUsed } = await callGeminiWithFallback(GEMINI_API_KEY, {
      contents: [{ parts: [{ text: prompt }] }],
      generationConfig: {
        responseMimeType: 'application/json',
        responseSchema: SYNTHESIS_RESPONSE_SCHEMA,
      },
    }, [
      { model: 'gemini-3-flash-preview', timeout: 120000 },
    ]);

    const parsed = parseGeminiJSON(text);
    if (!parsed) {
      return res.status(502).json({ error: 'Failed to parse synthesis response', raw: text.slice(0, 500) });
    }

    if (parsed.prices && Array.isArray(parsed.prices)) {
      parsed.prices = parsed.prices.map(p => ({
        ...p,
        link: (p.link && (p.link.startsWith('http://') || p.link.startsWith('https://'))) ? p.link : '',
      }));
    }

    console.log(`[Synthesize] ${Date.now() - start}ms, model=${modelUsed}, prices=${parsed.prices?.length || 0}`);
    res.json(parsed);
  } catch (err) {
    console.error(`[Synthesize] Error (${Date.now() - start}ms):`, err.message);
    res.status(502).json({ error: err.message });
  }
});

// --- Critique Agent ---
app.post('/api/agent/critique', async (req, res) => {
  const start = Date.now();
  try {
    const { query, question_type, synthesis, evidence_pool, iteration, max_iterations } = req.body;
    if (!query || !synthesis || !evidence_pool) return res.status(400).json({ error: 'Missing required fields' });
    if (!GEMINI_API_KEY) return res.status(500).json({ error: 'GEMINI_API_KEY not configured' });

    const prompt = buildCritiquePrompt(query, question_type, synthesis, evidence_pool, iteration || 1, max_iterations || 3);
    const { text, modelUsed } = await callGeminiWithFallback(GEMINI_API_KEY, {
      contents: [{ parts: [{ text: prompt }] }],
      generationConfig: {
        responseMimeType: 'application/json',
        responseSchema: CRITIQUE_RESPONSE_SCHEMA,
      },
    }, [
      { model: 'gemini-3-flash-preview', timeout: 120000 },
    ]);

    const parsed = parseGeminiJSON(text);
    if (!parsed) {
      return res.status(502).json({ error: 'Failed to parse critique response', raw: text.slice(0, 500) });
    }

    console.log(`[Critique] ${Date.now() - start}ms, model=${modelUsed}, needs_more=${parsed.needs_more_search}, confidence=${parsed.confidence_score}`);
    res.json(parsed);
  } catch (err) {
    console.error(`[Critique] Error (${Date.now() - start}ms):`, err.message);
    res.status(502).json({ error: err.message });
  }
});

// ==================== Proxy non-agent API calls to Cloudflare Worker ====================

app.use('/api', createProxyMiddleware({
  target: WORKER_API_URL,
  changeOrigin: true,
  pathRewrite: (path) => `/api${path}`,
  on: {
    proxyReq: (proxyReq, req) => {
      // Inject Bearer token for Worker authentication
      if (WORKER_API_TOKEN) {
        proxyReq.setHeader('Authorization', `Bearer ${WORKER_API_TOKEN}`);
      }
      if (req.body && (req.method === 'POST' || req.method === 'PUT')) {
        const bodyData = JSON.stringify(req.body);
        proxyReq.setHeader('Content-Type', 'application/json');
        proxyReq.setHeader('Content-Length', Buffer.byteLength(bodyData));
        proxyReq.write(bodyData);
      }
    },
    error: (err, req, res) => {
      console.error(`[Proxy] Error for ${req.path}:`, err.message);
      if (!res.headersSent) {
        res.status(502).json({ error: `Proxy error: ${err.message}` });
      }
    },
  },
}));

// ==================== Static Files + SPA Fallback ====================

app.use(express.static(join(__dirname, 'dist'), {
  maxAge: '1d',
  immutable: true,
  index: false,
}));

// SPA fallback
app.get('*', (req, res) => {
  res.setHeader('Cache-Control', 'no-cache, no-store, must-revalidate');
  res.setHeader('Pragma', 'no-cache');
  res.setHeader('Expires', '0');
  res.sendFile(join(__dirname, 'dist', 'index.html'));
});

// ==================== Start Server ====================

app.listen(PORT, '0.0.0.0', async () => {
  console.log(`Cloud Run server listening on port ${PORT}`);
  console.log(`Worker proxy target: ${WORKER_API_URL}`);
  console.log(`Gemini API key: ${GEMINI_API_KEY ? 'configured' : 'MISSING'}`);
  console.log(`Tavily API key: ${TAVILY_API_KEY ? 'configured' : 'MISSING'}`);
  console.log(`Session secret: ${process.env.SESSION_SECRET ? 'configured' : 'using default (dev)'}`);
  console.log(`Auth password hash: ${process.env.AUTH_PASSWORD_HASH ? 'configured' : 'MISSING'}`);

  // Load password hash from D1 database (overrides env var if set)
  await loadPasswordHashFromDB();
});
