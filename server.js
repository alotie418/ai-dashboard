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
      // PR-D: assets are bundled at build time (no runtime CDN), so the CDN hosts and
      // 'unsafe-eval' (which the Tailwind Play CDN needed) are no longer allow-listed.
      scriptSrc: ["'self'", "'unsafe-inline'"],
      styleSrc: ["'self'", "'unsafe-inline'"],
      fontSrc: ["'self'", "data:"],
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

// 语音（/api/ai/tts、/api/ai/live-key）已于 AI 助手重设计 R1 移除。

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
