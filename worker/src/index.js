// ==================== Validation Helpers ====================

const ID_REGEX = /^[a-zA-Z0-9_-]{1,100}$/;
const DATE_REGEX = /^\d{4}-\d{2}-\d{2}$/;
const MAX_STRING_LEN = 500;
const SETTINGS_ALLOWED_KEYS = new Set([
  'company_info', 'tax_auto_auth', 'ai_auto_insight', 'notifications',
]);

function isValidId(id) {
  return typeof id === 'string' && ID_REGEX.test(id);
}

function isValidDate(d) {
  return typeof d === 'string' && DATE_REGEX.test(d);
}

function isFiniteNumber(v) {
  return typeof v === 'number' && Number.isFinite(v);
}

function safeString(v, maxLen = MAX_STRING_LEN) {
  if (typeof v !== 'string') return '';
  return v.slice(0, maxLen);
}

function validatePurchase(data) {
  const errors = [];
  if (!data || typeof data !== 'object') return ['Request body must be a JSON object'];
  if (!isValidId(data.id)) errors.push('id: must be 1-100 alphanumeric/dash/underscore chars');
  if (!isValidDate(data.date)) errors.push('date: must be YYYY-MM-DD format');
  if (!isFiniteNumber(data.tons) || data.tons < 0) errors.push('tons: must be a non-negative number');
  if (!isFiniteNumber(data.pricePerTon) || data.pricePerTon < 0) errors.push('pricePerTon: must be a non-negative number');
  if (!isFiniteNumber(data.totalAmount) || data.totalAmount < 0) errors.push('totalAmount: must be a non-negative number');
  if (data.taxRate !== undefined && (!isFiniteNumber(data.taxRate) || data.taxRate < 0 || data.taxRate > 100)) {
    errors.push('taxRate: must be 0-100');
  }
  return errors;
}

function validateSale(data) {
  const errors = [];
  if (!data || typeof data !== 'object') return ['Request body must be a JSON object'];
  if (!isValidId(data.id)) errors.push('id: must be 1-100 alphanumeric/dash/underscore chars');
  if (!isValidDate(data.date)) errors.push('date: must be YYYY-MM-DD format');
  if (!isFiniteNumber(data.tons) || data.tons < 0) errors.push('tons: must be a non-negative number');
  if (!isFiniteNumber(data.pricePerTon) || data.pricePerTon < 0) errors.push('pricePerTon: must be a non-negative number');
  if (!isFiniteNumber(data.totalAmount) || data.totalAmount < 0) errors.push('totalAmount: must be a non-negative number');
  if (data.shippingCost !== undefined && (!isFiniteNumber(data.shippingCost) || data.shippingCost < 0)) {
    errors.push('shippingCost: must be a non-negative number');
  }
  if (data.taxRate !== undefined && (!isFiniteNumber(data.taxRate) || data.taxRate < 0 || data.taxRate > 100)) {
    errors.push('taxRate: must be 0-100');
  }
  return errors;
}

// ==================== Rate Limiter (in-memory per isolate) ====================

const rateLimitMap = new Map(); // ip -> { count, resetAt }
const RATE_LIMIT_WINDOW_MS = 60_000; // 1 minute
const RATE_LIMIT_MAX = 120; // requests per window

function checkRateLimit(ip) {
  const now = Date.now();
  let entry = rateLimitMap.get(ip);
  if (!entry || now > entry.resetAt) {
    entry = { count: 0, resetAt: now + RATE_LIMIT_WINDOW_MS };
    rateLimitMap.set(ip, entry);
  }
  entry.count++;
  rateLimitMap.set(ip, entry);
  // Garbage collect old entries
  if (rateLimitMap.size > 10000) {
    for (const [k, v] of rateLimitMap) {
      if (now > v.resetAt) rateLimitMap.delete(k);
    }
  }
  return entry.count <= RATE_LIMIT_MAX;
}

// ==================== Search Infrastructure ====================

const CACHE_TTL_SECONDS = 1800; // 30 minutes
const GEMINI_MODEL = 'gemini-3.1-pro-preview';
const GEMINI_FALLBACK_MODEL = 'gemini-2.5-flash';
const GEMINI_API_BASE = 'https://generativelanguage.googleapis.com/v1beta/models';
const FETCH_TIMEOUT_MS = 25000; // 25s per-request timeout (Worker has 30s wall limit)

/** KV cache wrapper: check cache first, call fetchFn on miss, store result */
async function getCachedOrFetch(env, cacheKey, fetchFn, ttlSeconds = CACHE_TTL_SECONDS) {
  if (!env.CACHE) return { data: await fetchFn(), cacheHit: false };
  try {
    const cached = await env.CACHE.get(cacheKey);
    if (cached) {
      return { data: JSON.parse(cached), cacheHit: true };
    }
  } catch (e) {
    console.error('Cache read error:', e.message);
  }
  const data = await fetchFn();
  try {
    await env.CACHE.put(cacheKey, JSON.stringify(data), { expirationTtl: ttlSeconds });
  } catch (e) {
    console.error('Cache write error:', e.message);
  }
  return { data, cacheHit: false };
}

/** Fetch with 1 retry on 5xx / network errors, 2s delay between attempts, per-request timeout */
async function fetchWithRetry(url, options, maxRetries = 1, timeoutMs = FETCH_TIMEOUT_MS) {
  let lastError;
  for (let attempt = 0; attempt <= maxRetries; attempt++) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
      const res = await fetch(url, {
        ...options,
        signal: controller.signal,
      });
      clearTimeout(timer);
      if (res.ok || res.status < 500) return res;
      lastError = new Error(`HTTP ${res.status}`);
      if (attempt < maxRetries) await new Promise(r => setTimeout(r, 2000));
    } catch (err) {
      clearTimeout(timer);
      lastError = err.name === 'AbortError' ? new Error(`Timeout after ${timeoutMs}ms`) : err;
      if (attempt < maxRetries) await new Promise(r => setTimeout(r, 2000));
    }
  }
  throw lastError;
}

/** Structured search log — appears in Cloudflare Workers Logs */
function logSearch(engine, queryLen, cacheHit, status, durationMs, error) {
  console.log(JSON.stringify({
    ts: new Date().toISOString(),
    type: 'search',
    engine,
    query_len: queryLen,
    cache: cacheHit ? 'HIT' : 'MISS',
    status,
    duration_ms: durationMs,
    error: error || null,
  }));
}

/** Simple hash for cache keys (not crypto-grade, just for dedup) */
async function hashQuery(query) {
  const encoder = new TextEncoder();
  const data = encoder.encode(query);
  const hashBuffer = await crypto.subtle.digest('SHA-256', data);
  const hashArray = Array.from(new Uint8Array(hashBuffer));
  return hashArray.map(b => b.toString(16).padStart(2, '0')).join('').slice(0, 16);
}

/**
 * Call Gemini API with automatic model fallback:
 * Try primary model first → on 503/timeout → retry with fallback model.
 * Returns { response, modelUsed }.
 */
async function callGeminiWithFallback(geminiKey, requestBody) {
  // Primary model: short timeout (fast-fail if unavailable)
  // Fallback model: longer timeout (allow full response time)
  const modelConfig = [
    { model: GEMINI_MODEL, timeout: 12000 },
    { model: GEMINI_FALLBACK_MODEL, timeout: 55000 },
  ];
  let lastError;
  for (const { model, timeout } of modelConfig) {
    try {
      const url = `${GEMINI_API_BASE}/${model}:generateContent?key=${geminiKey}`;
      const res = await fetchWithRetry(url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(requestBody),
      }, 0, timeout); // 0 retries per model (fallback handles retry)
      if (!res.ok) {
        const errText = await res.text();
        throw new Error(`HTTP ${res.status}: ${errText.slice(0, 200)}`);
      }
      return { response: res, modelUsed: model };
    } catch (err) {
      console.warn(`Gemini model ${model} failed: ${err.message}, trying next...`);
      lastError = err;
    }
  }
  throw lastError;
}

// ==================== Gemini Search Prompt (server-side, tamper-proof) ====================

function buildGeminiSearchPrompt(productQuery) {
  return `作为一名专业的市场销售调研员，请帮我查找产品"${productQuery}"在全网主要渠道的当前实时价格。

重点覆盖以下六大类平台（共30+个渠道）：

1. **综合型传统电商**：淘宝(taobao.com)、天猫(tmall.com)、京东(jd.com)、拼多多(pinduoduo.com)、亚马逊(amazon.com)
2. **内容/兴趣电商**：抖音(douyin.com)、快手(kuaishou.com)、小红书(xiaohongshu.com)
3. **即时零售**：美团(meituan.com)、京东到家(jddj.com)
4. **综合B2B/批发**：1688(1688.com)、阿里巴巴国际站(alibaba.com)、慧聪网(hc360.com)、中国制造网(made-in-china.com)、马可波罗(makepolo.com)、百度爱采购(b2b.baidu.com)、义乌购(yiwugo.com)
5. **垂直行业批发**：
   - 服装鞋包：17网(17zwd.com)、3e3e(3e3e.cn)、衣联网(eelly.com)、网商园(wsy.com)、PP(pp.cn)
   - 电子元器件：华强电子网(hqew.com)、Digi-Key(digikey.cn)、Mouser(mouser.cn)
   - 农业：一亩田(ymt.com)、惠农网(cnhnb.com)
   - 工业MRO：震坤行(ehsy.com)、工邦邦(gongbangbang.com)、Grainger(grainger.com)、ThomasNet(thomasnet.com)
6. **跨境/海外平台**：
   - B2B：Global Sources(globalsources.com)、DHgate(dhgate.com)、TradeKey(tradekey.com)
   - B2C：eBay(ebay.com)、AliExpress(aliexpress.com)、Walmart(walmart.com)、Shopee(shopee.com)、Lazada(lazada.com)
7. **二手/回收**：爱回收(aihuishou.com)、找靓机(zhaoliangji.com)

请提供一份结构清晰的【市场分析报告】，包含以下 Markdown 章节：

### 1. 📊 价格行情
- **最低价**：[平台] ￥xx
- **最高价**：[平台] ￥xx
- **主流价格区间**：￥xx - ￥xx

### 2. 💡 销售建议 (针对卖家)
- **定价策略**：...
- **渠道推荐**：...

### 3. 🛍️ 购买建议 (针对买家)
- **最佳入手渠道**：...
- **避坑指南**：...

请务必使用搜索功能获取最新数据。返回结果请尽量包含具体价格数字和来源平台。不要返回 Markdown代码块标记，直接返回内容。`;
}

// ==================== Gemini Merge Prompt (server-side, tamper-proof) ====================

function buildMergePrompt(geminiRaw, braveSummary, tavilySummary) {
  return `你是一名专业的市场销售调研员。我通过三个搜索引擎查找了产品的市场价格信息，请你整合分析这些数据。

## 搜索引擎 1: Google Search(Gemini Grounding) 返回结果
    涵盖领域：综合零售(淘宝 / 京东 / 拼多多 / 亚马逊)、B2B批发(1688 / 慧聪 / 中国制造网 / 义乌购)、内容电商(抖音 / 快手 / 小红书)、即时零售(美团 / 京东到家)、垂直行业(17网 / 3e3e / 华强电子 / 一亩田 / 惠农 / 工邦邦 / 震坤行)、二手(爱回收 / 找靓机)。
${geminiRaw}

## 搜索引擎 2: Brave Search 返回结果
${braveSummary || '（无结果）'}

## 搜索引擎 3: Tavily 搜索引擎返回结果
${tavilySummary || '（无结果）'}

请完成以下任务：
1. ** 合并去重 **：将三个引擎的价格数据合并，去掉明显重复的条目。
2. ** summaryTable 汇总表格 **：生成一个关键数据汇总表，每行包含 label 和 value。包含：
   - "最低价" → 最低价格及平台
   - "最高价" → 最高价格及平台
   - "价格区间" → 如 "18.0 - 65.0 元"
   - "市场均价" → 如 "32.5 元"
   - "推荐对标平台" → 综合竞争最激烈的平台
   - "数据来源数量" → 如 "Google: 5条, Brave: 3条, Tavily: 4条"
   如有其他有价值的统计数据也请加入。
3. ** analysis 综合分析报告 **：请生成一份结构清晰的 Markdown 格式分析报告，必须包含以下三个章节：
   - ### 📊 价格行情：简述主流价格区间和市场均价。
   - ### 💡 销售建议 (卖家)：定价策略、渠道选择、竞争对手分析。
   - ### 🛍️ 购买建议 (买家)：最佳入手渠道、避坑指南、促销建议。
   请使用列表和加粗增强可读性。禁止使用三个星号 (***)，仅使用两个星号 (**)。不要返回 Markdown代码块标记，直接返回内容。
4. ** 输出格式 **：按指定 JSON Schema 返回，prices 数组中每条记录的 platform 字段请在平台名后标注数据来源（如 "京东 [Google]"、"Amazon [Brave]" 或 "1688 [Tavily]"）。

请确保分析专业、数据准确。`;
}

const MERGE_RESPONSE_SCHEMA = {
  type: 'OBJECT',
  properties: {
    analysis: { type: 'STRING', description: '结构化的Markdown分析报告(含价格行情、销售建议、购买建议)' },
    summaryTable: {
      type: 'ARRAY',
      description: '关键数据汇总表格，每行一个 label-value 对',
      items: {
        type: 'OBJECT',
        properties: {
          label: { type: 'STRING', description: '指标名称，如 最低价、均价、价格区间' },
          value: { type: 'STRING', description: '指标值，如 18.0元 (1688)' },
        },
        required: ['label', 'value'],
      },
    },
    prices: {
      type: 'ARRAY',
      items: {
        type: 'OBJECT',
        properties: {
          platform: { type: 'STRING' },
          title: { type: 'STRING' },
          price: { type: 'NUMBER' },
          link: { type: 'STRING' },
        },
        required: ['platform', 'title', 'price', 'link'],
      },
    },
  },
  required: ['analysis', 'prices', 'summaryTable'],
};

// ==================== Main Handler ====================

export default {
  async fetch(request, env, ctx) {
    // --- CORS Setup ---
    const allowedOrigins = (env.CORS_ORIGINS || '')
      .split(',')
      .map((o) => o.trim())
      .filter(Boolean);
    const requestOrigin = request.headers.get('Origin');

    // Fix: require Origin header for browser requests; reject unknown origins
    const isOriginAllowed = requestOrigin
      ? allowedOrigins.includes(requestOrigin)
      : false; // non-browser requests (curl, server) have no Origin — handled by auth

    const corsHeaders = {
      'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type, Authorization',
    };
    if (requestOrigin && isOriginAllowed) {
      corsHeaders['Access-Control-Allow-Origin'] = requestOrigin;
      corsHeaders['Vary'] = 'Origin';
    }

    // Preflight
    if (request.method === 'OPTIONS') {
      if (!requestOrigin || !isOriginAllowed) {
        return new Response('Forbidden', { status: 403 });
      }
      return new Response(null, { status: 204, headers: corsHeaders });
    }

    // Rate limiting
    const clientIp = request.headers.get('CF-Connecting-IP') || 'unknown';
    if (!checkRateLimit(clientIp)) {
      return new Response(JSON.stringify({ error: 'Too many requests' }), {
        status: 429,
        headers: { ...corsHeaders, 'Content-Type': 'application/json', 'Retry-After': '60' },
      });
    }

    const url = new URL(request.url);
    const path = url.pathname;

    // --- Health endpoint (no auth required) ---
    if (path === '/' || path === '/health') {
      return jsonResponse({ status: 'ok' }, corsHeaders);
    }

    // --- Authentication: require Bearer token for all /api/* routes ---
    if (path.startsWith('/api/')) {
      const authHeader = request.headers.get('Authorization');
      const expectedToken = env.API_TOKEN;
      if (!expectedToken) {
        return errorResponse(500, 'Server misconfiguration: API_TOKEN not set', corsHeaders);
      }
      if (!authHeader || !authHeader.startsWith('Bearer ')) {
        return errorResponse(401, 'Authentication required', corsHeaders);
      }
      const providedToken = authHeader.slice(7);
      // Timing-safe comparison
      if (providedToken.length !== expectedToken.length || !timingSafeEqual(providedToken, expectedToken)) {
        return errorResponse(403, 'Invalid token', corsHeaders);
      }
    }

    try {
      // ==================== PURCHASES ====================

      if (path === '/api/purchases' && request.method === 'GET') {
        const { results } = await env.DB.prepare('SELECT * FROM purchases ORDER BY date DESC').all();
        return jsonResponse(results, corsHeaders);
      }

      if (path === '/api/purchases' && request.method === 'POST') {
        const data = await request.json();
        const errors = validatePurchase(data);
        if (errors.length > 0) {
          return errorResponse(400, errors.join('; '), corsHeaders);
        }
        await env.DB.prepare(`
          INSERT INTO purchases (id, date, supplier, tons, pricePerTon, totalAmount, amountWithoutTax, taxAmount, taxRate, invoiceNumber, invoiceStatus)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        `).bind(
          data.id,
          data.date,
          safeString(data.supplier),
          data.tons,
          data.pricePerTon,
          data.totalAmount,
          data.amountWithoutTax ?? 0,
          data.taxAmount ?? 0,
          data.taxRate ?? 13,
          safeString(data.invoiceNumber, 100),
          safeString(data.invoiceStatus, 20)
        ).run();
        return jsonResponse({ success: true, id: data.id }, corsHeaders);
      }

      if (path.startsWith('/api/purchases/') && request.method === 'PUT') {
        const id = extractId(path);
        if (!id) return errorResponse(400, 'Invalid ID', corsHeaders);
        const data = await request.json();
        // Coerce numeric fields and validate
        data.tons = Number(data.tons) || 0;
        data.pricePerTon = Number(data.pricePerTon) || 0;
        data.totalAmount = Number(data.totalAmount) || 0;
        data.amountWithoutTax = Number(data.amountWithoutTax) || 0;
        data.taxAmount = Number(data.taxAmount) || 0;
        data.taxRate = Number(data.taxRate) || 13;
        data.id = id; // use URL id for validation
        const errors = validatePurchase(data);
        if (errors.length > 0) {
          return errorResponse(400, errors.join('; '), corsHeaders);
        }
        await env.DB.prepare(`
          UPDATE purchases SET date=?, supplier=?, tons=?, pricePerTon=?, totalAmount=?,
          amountWithoutTax=?, taxAmount=?, taxRate=?, invoiceNumber=?, invoiceStatus=?
          WHERE id=?
        `).bind(
          data.date,
          safeString(data.supplier),
          data.tons,
          data.pricePerTon,
          data.totalAmount,
          data.amountWithoutTax,
          data.taxAmount,
          data.taxRate,
          safeString(data.invoiceNumber, 100),
          safeString(data.invoiceStatus, 20),
          id
        ).run();
        return jsonResponse({ success: true }, corsHeaders);
      }

      if (path.startsWith('/api/purchases/') && request.method === 'DELETE') {
        const id = extractId(path);
        if (!id) return errorResponse(400, 'Invalid ID', corsHeaders);
        await env.DB.prepare('DELETE FROM purchases WHERE id = ?').bind(id).run();
        return jsonResponse({ success: true }, corsHeaders);
      }

      // ==================== SALES ====================

      if (path === '/api/sales' && request.method === 'GET') {
        const { results } = await env.DB.prepare('SELECT * FROM sales ORDER BY date DESC').all();
        return jsonResponse(results, corsHeaders);
      }

      if (path === '/api/sales' && request.method === 'POST') {
        const data = await request.json();
        const errors = validateSale(data);
        if (errors.length > 0) {
          return errorResponse(400, errors.join('; '), corsHeaders);
        }
        await env.DB.prepare(`
          INSERT INTO sales (id, date, customer, tons, pricePerTon, totalAmount, amountWithoutTax, taxAmount, taxRate, shippingCost, invoiceNumber, invoiceStatus)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        `).bind(
          data.id,
          data.date,
          safeString(data.customer),
          data.tons,
          data.pricePerTon,
          data.totalAmount,
          data.amountWithoutTax ?? 0,
          data.taxAmount ?? 0,
          data.taxRate ?? 13,
          data.shippingCost ?? 0,
          safeString(data.invoiceNumber, 100),
          safeString(data.invoiceStatus, 20)
        ).run();
        return jsonResponse({ success: true, id: data.id }, corsHeaders);
      }

      if (path.startsWith('/api/sales/') && request.method === 'PUT') {
        const id = extractId(path);
        if (!id) return errorResponse(400, 'Invalid ID', corsHeaders);
        const data = await request.json();
        // Coerce numeric fields and validate
        data.tons = Number(data.tons) || 0;
        data.pricePerTon = Number(data.pricePerTon) || 0;
        data.totalAmount = Number(data.totalAmount) || 0;
        data.amountWithoutTax = Number(data.amountWithoutTax) || 0;
        data.taxAmount = Number(data.taxAmount) || 0;
        data.taxRate = Number(data.taxRate) || 13;
        data.shippingCost = Number(data.shippingCost) || 0;
        data.id = id; // use URL id for validation
        const errors = validateSale(data);
        if (errors.length > 0) {
          return errorResponse(400, errors.join('; '), corsHeaders);
        }
        await env.DB.prepare(`
          UPDATE sales SET date=?, customer=?, tons=?, pricePerTon=?, totalAmount=?,
          amountWithoutTax=?, taxAmount=?, taxRate=?, shippingCost=?, invoiceNumber=?, invoiceStatus=?
          WHERE id=?
        `).bind(
          data.date,
          safeString(data.customer),
          data.tons,
          data.pricePerTon,
          data.totalAmount,
          data.amountWithoutTax,
          data.taxAmount,
          data.taxRate,
          data.shippingCost,
          safeString(data.invoiceNumber, 100),
          safeString(data.invoiceStatus, 20),
          id
        ).run();
        return jsonResponse({ success: true }, corsHeaders);
      }

      if (path.startsWith('/api/sales/') && request.method === 'DELETE') {
        const id = extractId(path);
        if (!id) return errorResponse(400, 'Invalid ID', corsHeaders);
        await env.DB.prepare('DELETE FROM sales WHERE id = ?').bind(id).run();
        return jsonResponse({ success: true }, corsHeaders);
      }

      // ==================== SETTINGS ====================

      if (path === '/api/settings' && request.method === 'GET') {
        const { results } = await env.DB.prepare('SELECT key, value FROM settings').all();
        const settings = {};
        for (const row of results) {
          if (!SETTINGS_ALLOWED_KEYS.has(row.key)) continue; // skip unknown keys
          try {
            settings[row.key] = JSON.parse(row.value);
          } catch {
            settings[row.key] = row.value;
          }
        }
        return jsonResponse(settings, corsHeaders);
      }

      if (path === '/api/settings' && request.method === 'PUT') {
        const data = await request.json();
        if (!data || typeof data !== 'object') {
          return errorResponse(400, 'Request body must be a JSON object', corsHeaders);
        }
        const stmts = [];
        for (const [key, value] of Object.entries(data)) {
          if (!SETTINGS_ALLOWED_KEYS.has(key)) continue; // silently skip disallowed keys
          const serialized = JSON.stringify(value);
          if (serialized.length > 10000) continue; // value too large
          stmts.push(
            env.DB.prepare(
              "INSERT OR REPLACE INTO settings (key, value, updated_at) VALUES (?, ?, datetime('now'))"
            ).bind(key, serialized)
          );
        }
        if (stmts.length > 0) {
          await env.DB.batch(stmts);
        }
        return jsonResponse({ success: true }, corsHeaders);
      }

      // ==================== SEARCH PROXY: BRAVE (with cache + retry + logging) ====================

      if (path === '/api/search/brave' && request.method === 'POST') {
        const startTime = Date.now();
        const braveKey = env.BRAVE_API_KEY;
        if (!braveKey) {
          return errorResponse(500, 'Brave API key not configured', corsHeaders);
        }

        const body = await request.json();
        const q = safeString(body.q, 200);
        const count = Math.min(Math.max(parseInt(body.count) || 10, 1), 20);
        const freshness = safeString(body.freshness || '', 20);

        if (!q) {
          return errorResponse(400, 'q: search query is required', corsHeaders);
        }

        const queryHash = await hashQuery(`brave:${q}:${count}`);
        const cacheKey = `search:brave:${queryHash}`;

        try {
          const { data: braveData, cacheHit } = await getCachedOrFetch(env, cacheKey, async () => {
            const params = new URLSearchParams({ q, count: String(count) });
            if (freshness) params.set('freshness', freshness);

            const braveResponse = await fetchWithRetry(
              `https://api.search.brave.com/res/v1/web/search?${params.toString()}`,
              {
                headers: {
                  'Accept': 'application/json',
                  'Accept-Encoding': 'gzip',
                  'X-Subscription-Token': braveKey,
                },
              }
            );

            if (!braveResponse.ok) {
              throw new Error(`Brave API error: ${braveResponse.status}`);
            }
            return braveResponse.json();
          });

          logSearch('brave', q.length, cacheHit, 200, Date.now() - startTime, null);
          return jsonResponse(braveData, { ...corsHeaders, 'X-Cache': cacheHit ? 'HIT' : 'MISS' });
        } catch (err) {
          logSearch('brave', q.length, false, 502, Date.now() - startTime, err.message);
          return errorResponse(502, `Brave search failed: ${err.message}`, corsHeaders);
        }
      }

      // ==================== SEARCH PROXY: TAVILY (with cache + retry + logging) ====================

      if (path === '/api/search/tavily' && request.method === 'POST') {
        const startTime = Date.now();
        const tavilyKey = env.TAVILY_API_KEY;
        if (!tavilyKey) {
          return errorResponse(500, 'Tavily API key not configured', corsHeaders);
        }

        const body = await request.json();
        const query = safeString(body.query, 500);
        const searchDepth = body.search_depth === 'advanced' ? 'advanced' : 'basic';
        const maxResults = Math.min(Math.max(parseInt(body.max_results) || 10, 1), 20);

        if (!query) {
          return errorResponse(400, 'query: search query is required', corsHeaders);
        }

        const queryHash = await hashQuery(`tavily:${query}:${searchDepth}:${maxResults}`);
        const cacheKey = `search:tavily:${queryHash}`;

        try {
          const { data: tavilyData, cacheHit } = await getCachedOrFetch(env, cacheKey, async () => {
            const tavilyResponse = await fetchWithRetry('https://api.tavily.com/search', {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({
                api_key: tavilyKey,
                query,
                search_depth: searchDepth,
                max_results: maxResults,
                include_answer: false,
              }),
            });

            if (!tavilyResponse.ok) {
              throw new Error(`Tavily API error: ${tavilyResponse.status}`);
            }
            return tavilyResponse.json();
          });

          logSearch('tavily', query.length, cacheHit, 200, Date.now() - startTime, null);
          return jsonResponse(tavilyData, { ...corsHeaders, 'X-Cache': cacheHit ? 'HIT' : 'MISS' });
        } catch (err) {
          logSearch('tavily', query.length, false, 502, Date.now() - startTime, err.message);
          return errorResponse(502, `Tavily search failed: ${err.message}`, corsHeaders);
        }
      }

      // ==================== SEARCH PROXY: GEMINI (with cache + retry + logging) ====================

      if (path === '/api/search/gemini' && request.method === 'POST') {
        const startTime = Date.now();
        const geminiKey = env.GEMINI_API_KEY;
        if (!geminiKey) {
          return errorResponse(500, 'Gemini API key not configured', corsHeaders);
        }

        const body = await request.json();
        const query = safeString(body.query, 300);
        if (!query) {
          return errorResponse(400, 'query: search query is required', corsHeaders);
        }

        const queryHash = await hashQuery(`gemini:${query}`);
        const cacheKey = `search:gemini:${queryHash}`;

        try {
          const { data: geminiData, cacheHit } = await getCachedOrFetch(env, cacheKey, async () => {
            const prompt = buildGeminiSearchPrompt(query);

            const { response: geminiResponse, modelUsed } = await callGeminiWithFallback(geminiKey, {
              contents: [{ parts: [{ text: prompt }] }],
              tools: [{ googleSearch: {} }],
            });

            console.log(`Gemini search used model: ${modelUsed}`);
            const result = await geminiResponse.json();

            // Extract text
            const text = result.candidates?.[0]?.content?.parts
              ?.map(p => p.text || '')
              .join('') || '';

            // Extract grounding links
            const grounding = [];
            const chunks = result.candidates?.[0]?.groundingMetadata?.groundingChunks;
            if (chunks) {
              for (const chunk of chunks) {
                if (chunk.web) {
                  grounding.push({
                    title: chunk.web.title || '参考来源',
                    uri: chunk.web.uri,
                  });
                }
              }
            }

            return { text, grounding };
          });

          logSearch('gemini', query.length, cacheHit, 200, Date.now() - startTime, null);
          return jsonResponse(geminiData, { ...corsHeaders, 'X-Cache': cacheHit ? 'HIT' : 'MISS' });
        } catch (err) {
          logSearch('gemini', query.length, false, 502, Date.now() - startTime, err.message);
          return errorResponse(502, `Gemini search failed: ${err.message}`, corsHeaders);
        }
      }

      // ==================== SEARCH PROXY: MERGE (retry + logging, no cache) ====================

      if (path === '/api/search/merge' && request.method === 'POST') {
        const startTime = Date.now();
        const geminiKey = env.GEMINI_API_KEY;
        if (!geminiKey) {
          return errorResponse(500, 'Gemini API key not configured', corsHeaders);
        }

        const body = await request.json();
        const geminiRaw = safeString(body.geminiRaw || '', 50000);
        const braveResults = Array.isArray(body.braveResults) ? body.braveResults : [];
        const tavilyResults = Array.isArray(body.tavilyResults) ? body.tavilyResults : [];

        const braveSummary = braveResults.map((r, i) =>
          `[Brave结果${i + 1}]标题: ${safeString(r.title, 200)}\n内容摘要: ${safeString(r.content, 1000)}\n来源: ${safeString(r.url, 500)}`
        ).join('\n\n');

        const tavilySummary = tavilyResults.map((r, i) =>
          `[Tavily结果${i + 1}]标题: ${safeString(r.title, 200)}\n内容摘要: ${safeString(r.content, 1000)}\n来源: ${safeString(r.url, 500)}`
        ).join('\n\n');

        const prompt = buildMergePrompt(geminiRaw, braveSummary, tavilySummary);
        const queryLen = (geminiRaw + braveSummary + tavilySummary).length;

        try {
          const { response: geminiResponse, modelUsed } = await callGeminiWithFallback(geminiKey, {
            contents: [{ parts: [{ text: prompt }] }],
            generationConfig: {
              responseMimeType: 'application/json',
              responseSchema: MERGE_RESPONSE_SCHEMA,
            },
          });

          console.log(`Merge analysis used model: ${modelUsed}`);
          const result = await geminiResponse.json();
          const text = result.candidates?.[0]?.content?.parts
            ?.map(p => p.text || '')
            .join('') || '{}';

          let parsed;
          try {
            parsed = JSON.parse(text);
          } catch {
            console.error('Failed to parse Gemini merge JSON:', text.slice(0, 200));
            parsed = { analysis: text, prices: [], summaryTable: [] };
          }

          logSearch('merge', queryLen, false, 200, Date.now() - startTime, null);
          return jsonResponse(parsed, corsHeaders);
        } catch (err) {
          logSearch('merge', queryLen, false, 502, Date.now() - startTime, err.message);
          return errorResponse(502, `Merge analysis failed: ${err.message}`, corsHeaders);
        }
      }

      // ==================== SYNC (disabled for safety) ====================

      if (path === '/api/sync') {
        return errorResponse(403, 'Sync endpoint is disabled for security reasons', corsHeaders);
      }

      return new Response('Not Found', { status: 404, headers: corsHeaders });
    } catch (error) {
      // Sanitized error — never expose internals
      console.error('Worker error:', error.message, error.stack);
      return errorResponse(500, 'Internal server error', corsHeaders);
    }
  },
};

// ==================== Utility Functions ====================

function jsonResponse(data, headers) {
  return new Response(JSON.stringify(data), {
    headers: { ...headers, 'Content-Type': 'application/json' },
  });
}

function errorResponse(status, message, corsHeaders) {
  return new Response(JSON.stringify({ error: message }), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

function extractId(path) {
  const segments = path.split('/');
  const id = segments[3];
  if (!id || !isValidId(id)) return null;
  return id;
}

// Timing-safe string comparison (constant-time to prevent timing attacks)
function timingSafeEqual(a, b) {
  if (a.length !== b.length) return false;
  let result = 0;
  for (let i = 0; i < a.length; i++) {
    result |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return result === 0;
}
