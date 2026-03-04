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

// ==================== Direct Price Sources (定向抓取) ====================

const PRICE_SOURCES = {
  '软水盐': [
    { name: '生意社', url: 'https://www.100ppi.com/mprice/plist-1-5732-1.html' },
  ],
  '工业盐': [
    { name: '生意社', url: 'https://www.100ppi.com/mprice/plist-1-1963-1.html' },
  ],
  '甲醇': [
    { name: '生意社', url: 'https://www.100ppi.com/mprice/plist-1-397-1.html' },
  ],
  '乙二醇': [
    { name: '生意社', url: 'https://www.100ppi.com/mprice/plist-1-448-1.html' },
  ],
  '纯碱': [
    { name: '生意社', url: 'https://www.100ppi.com/mprice/plist-1-533-1.html' },
  ],
  '片碱': [
    { name: '生意社', url: 'https://www.100ppi.com/mprice/plist-1-4027-1.html' },
  ],
  '液碱': [
    { name: '生意社', url: 'https://www.100ppi.com/mprice/plist-1-1350-1.html' },
  ],
  '螺纹钢': [
    { name: '生意社', url: 'https://www.100ppi.com/mprice/plist-1-508-1.html' },
  ],
  '铜': [
    { name: '生意社', url: 'https://www.100ppi.com/mprice/plist-1-61-1.html' },
  ],
  '锌': [
    { name: '生意社', url: 'https://www.100ppi.com/mprice/plist-1-64-1.html' },
  ],
};

// ==================== Product Aliases (别名映射) ====================

/** Maps alternate product names to their canonical name in PRICE_SOURCES */
const PRODUCT_ALIASES = {
  '离子交换树脂再生剂': '软水盐',
  '中盐离子交换树脂再生剂': '软水盐',
  '中盐牌离子树脂交换再生剂': '软水盐',
  '中盐软水盐': '软水盐',
  '树脂再生剂': '软水盐',
};

/** Resolve any alias in the query to its canonical product name */
function resolveProductAlias(query) {
  // Exact alias match
  if (PRODUCT_ALIASES[query]) return PRODUCT_ALIASES[query];
  // Bidirectional substring match against aliases
  for (const [alias, canonical] of Object.entries(PRODUCT_ALIASES)) {
    if (query.includes(alias) || alias.includes(query)) {
      return canonical;
    }
  }
  return null;
}

/** Match user query to known price sources (fuzzy: mutual substring match + alias resolution) */
function findPriceSources(query) {
  const matches = [];
  const seen = new Set();

  // 1) Alias resolution — e.g. "离子交换树脂再生剂" → "软水盐"
  const resolved = resolveProductAlias(query);
  if (resolved && PRICE_SOURCES[resolved]) {
    for (const s of PRICE_SOURCES[resolved]) {
      const key = `${resolved}:${s.url}`;
      if (!seen.has(key)) {
        seen.add(key);
        matches.push({ ...s, keyword: resolved });
      }
    }
  }

  // 2) Direct substring match (original logic)
  for (const [keyword, sources] of Object.entries(PRICE_SOURCES)) {
    if (query.includes(keyword) || keyword.includes(query)) {
      for (const s of sources) {
        const key = `${keyword}:${s.url}`;
        if (!seen.has(key)) {
          seen.add(key);
          matches.push({ ...s, keyword });
        }
      }
    }
  }

  return matches;
}

const DIRECT_PRICE_SCHEMA = {
  type: 'OBJECT',
  properties: {
    prices: {
      type: 'ARRAY',
      items: {
        type: 'OBJECT',
        properties: {
          product: { type: 'STRING', description: '产品名称' },
          price: { type: 'NUMBER', description: '价格数值' },
          priceUnit: { type: 'STRING', description: '完整单位如 元/吨、元/kg、元/袋' },
          spec: { type: 'STRING', description: '规格型号' },
          region: { type: 'STRING', description: '报价地区' },
          date: { type: 'STRING', description: '报价日期' },
          source: { type: 'STRING', description: '数据来源网站名称' },
        },
        required: ['product', 'price', 'priceUnit', 'source'],
      },
    },
  },
  required: ['prices'],
};

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
async function callGeminiWithFallback(geminiKey, requestBody, timeoutOverrides = {}) {
  // Primary model: short timeout (fast-fail if unavailable)
  // Fallback model: longer timeout (allow full response time)
  // Callers can override via timeoutOverrides: { primary, fallback }
  const modelConfig = [
    { model: GEMINI_MODEL, timeout: timeoutOverrides.primary ?? 12000 },
    { model: GEMINI_FALLBACK_MODEL, timeout: timeoutOverrides.fallback ?? 55000 },
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
  return `你是一名专业的市场价格调研分析师。请利用搜索功能，对产品"${productQuery}"进行全网实时价格调研。

## 搜索策略
请根据产品品类，自动选择最相关的渠道类型进行搜索：
- **行业垂直网站**：该品类最权威的专业报价/行情平台
- **大宗商品/期货行情**：如有对应期货品种，查询最新期货价格和现货报价
- **B2B 批发平台**：综合及垂直批发渠道的批量采购价
- **零售电商**：主流零售平台的终端销售价
- **跨境平台**：如有出口/进口需求，查询海外平台价格

不要局限于以上分类，请根据"${productQuery}"的实际品类，搜索该领域最权威、最活跃的价格信息源。

## 输出要求
请提供结构清晰的市场分析报告：

### 1. 📊 价格行情
- **最低价**：￥xx（来源平台）
- **最高价**：￥xx（来源平台）
- **主流价格区间**：￥xx - ￥xx
- 如有期货/现货行情，请单独列出

### 2. 💡 销售建议（针对卖家）
- 定价策略、渠道推荐

### 3. 🛍️ 购买建议（针对买家）
- 最佳入手渠道、避坑指南

请务必使用搜索功能获取最新数据，尽量包含具体价格数字和来源平台名称。不要返回 Markdown 代码块标记，直接返回内容。`;
}

// ==================== Search Query Augmentation (Brave / Tavily) ====================

const COMMODITY_HINTS = [
  // 金属
  '钢', '铁', '铜', '铝', '锌', '镍', '锡', '铅', '金', '银',
  // 能源
  '煤', '油', '气', '石油', '天然气', '焦炭', '沥青',
  // 农产品
  '棉', '大豆', '豆粕', '玉米', '小麦', '稻', '糖', '棕榈',
  // 化工 / 建材 / 盐类
  '甲醇', '乙二醇', 'PTA', 'PE', 'PP', 'PVC', '橡胶', '纸浆',
  '水泥', '砂', '木材', '板材', '盐', '纯碱', '片碱', '液碱', '树脂', '再生剂',
  // 大宗通用标记
  '期货', '现货', '大宗', '原材料',
];

/** Build augmented search query with category-aware keywords + dynamic year */
function buildSearchQuery(userQuery, maxLen) {
  const year = new Date().getFullYear();
  const isCommodity = COMMODITY_HINTS.some(h => userQuery.includes(h));

  const keywords = isCommodity
    ? `期货 现货报价 行情走势 ${year}`
    : `最新价格 批发价 零售价 市场行情 ${year}`;

  const combined = `${userQuery} ${keywords}`;
  if (combined.length <= maxLen) return combined;
  // 超长时截断关键词，保留用户原始查询
  const available = maxLen - userQuery.length - 1;
  return available > 0 ? `${userQuery} ${keywords.slice(0, available)}` : userQuery;
}

// ==================== International Search (国际平台搜索) ====================

/** Static translation map for known products — avoids Gemini API call */
const PRODUCT_TRANSLATIONS = {
  '软水盐': 'water softener salt',
  '离子交换树脂再生剂': 'ion exchange resin regenerant salt',
  '工业盐': 'industrial salt',
  '甲醇': 'methanol',
  '乙二醇': 'ethylene glycol',
  '纯碱': 'soda ash',
  '片碱': 'caustic soda flakes',
  '液碱': 'liquid caustic soda',
  '螺纹钢': 'rebar steel',
  '铜': 'copper',
  '锌': 'zinc',
};

/** Translate Chinese query to English. Uses static map first, falls back to Gemini Flash. */
async function translateToEnglish(query, geminiKey) {
  // 1. Exact match in static map
  if (PRODUCT_TRANSLATIONS[query]) {
    return { text: PRODUCT_TRANSLATIONS[query], method: 'static' };
  }

  // 2. Substring match — replace known Chinese product name with English
  for (const [cn, en] of Object.entries(PRODUCT_TRANSLATIONS)) {
    if (query.includes(cn)) {
      const remainder = query.replace(cn, '').trim();
      const translated = remainder ? `${en} ${remainder}` : en;
      return { text: translated, method: 'static_partial' };
    }
  }

  // 3. Fallback: Gemini Flash translation (fast, ~1-2s)
  try {
    const url = `${GEMINI_API_BASE}/${GEMINI_FALLBACK_MODEL}:generateContent?key=${geminiKey}`;
    const res = await fetchWithRetry(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        contents: [{
          parts: [{
            text: `Translate the following Chinese product/commodity name to English for searching on international e-commerce and wholesale platforms. Return ONLY the English translation, nothing else.\n\nProduct: ${query}`,
          }],
        }],
        generationConfig: { maxOutputTokens: 100 },
      }),
    }, 0, 8000);

    if (!res.ok) throw new Error(`Translation API error: ${res.status}`);
    const result = await res.json();
    const translated = result.candidates?.[0]?.content?.parts?.[0]?.text?.trim() || query;
    return { text: translated, method: 'gemini' };
  } catch (err) {
    console.warn('Gemini translation failed, using original query:', err.message);
    return { text: query, method: 'fallback_original' };
  }
}

/** Build English search query for international e-commerce platforms */
function buildInternationalQuery(englishQuery, maxLen = 200) {
  const year = new Date().getFullYear();
  const keywords = `wholesale price buy bulk ${year}`;
  const combined = `${englishQuery} ${keywords}`;
  if (combined.length <= maxLen) return combined;
  const available = maxLen - englishQuery.length - 1;
  return available > 0 ? `${englishQuery} ${keywords.slice(0, available)}` : englishQuery;
}

// ==================== Gemini Merge Prompt (server-side, tamper-proof) ====================

function buildMergePrompt(geminiRaw, braveSummary, tavilySummary, directSummary, internationalSummary, ecommerceSummary) {
  const directSection = directSummary
    ? `\n## 数据源 4: 行业权威网站直连数据 [精度最高，应优先采信]
${directSummary}\n`
    : '';

  const internationalSection = internationalSummary
    ? `\n## 数据源 5: 国际平台搜索 (Alibaba/Temu/SHEIN 等跨境电商)
${internationalSummary}\n`
    : '';

  const ecommerceSection = ecommerceSummary
    ? `\n## 数据源 6: 电商平台定向搜索 (淘宝/天猫/京东/拼多多/1688/抖音/美团/快手)
${ecommerceSummary}\n`
    : '';

  return `你是一名专业的市场销售调研员。我通过多个渠道查找了产品的市场价格信息，请你整合分析这些数据。
${directSection ? '\n**重要：数据源4是从行业权威网站（如生意社、卓创资讯）直接抓取的结构化报价数据，精度最高，在分析时应优先采信。**\n' : ''}
## 搜索引擎 1: Google Search(Gemini Grounding) 返回结果
    涵盖领域：根据产品品类自动搜索的全网渠道，包括行业垂直网站、大宗商品行情、B2B批发、零售电商、跨境平台等。
${geminiRaw}

## 搜索引擎 2: Brave Search 返回结果
${braveSummary || '（无结果）'}

## 搜索引擎 3: Tavily 搜索引擎返回结果
${tavilySummary || '（无结果）'}
${directSection}${internationalSection}${ecommerceSection}
请完成以下任务：
1. ** 合并去重 **：将所有数据源的价格数据合并，去掉明显重复的条目。
   **重要：必须保留每条价格的原始计量单位**（如"元/kg"、"元/吨"、"元/袋"、"元/台"、"USD/ton"等）。
   如果原始数据只有裸数字没有单位，请根据上下文推断最可能的单位。
   不同单位的价格不要直接比较。每条 price 必须填写 priceUnit 字段。
   国际平台价格请保留原始货币单位（如 USD、EUR）。
2. ** summaryTable 汇总表格 **：生成一个关键数据汇总表，每行包含 label 和 value。包含：
   - "最低价" → 最低价格及平台（注明单位，如 "0.55 元/kg (生意社)"）
   - "最高价" → 最高价格及平台（注明单位）
   - "价格区间" → 如 "0.55 - 1.80 元/kg" 或 "30 - 50 元/袋"
   - "市场均价" → 如 "0.85 元/kg"
${internationalSection ? '   - "国际参考价" → 如有国际平台数据，单独列出国际价格参考（含原始货币）\n' : ''}   - "推荐对标平台" → 综合竞争最激烈的平台
   - "平台覆盖" → 列出已找到数据的电商平台名称，如 "京东, 1688, 淘宝, 拼多多"
   - "数据来源数量" → 如 "Google: 5条, Brave: 3条, Tavily: 4条, 直连: 3条${internationalSection ? ', 国际: 5条' : ''}${ecommerceSection ? ', 电商: N条' : ''}"
   如有其他有价值的统计数据也请加入。所有价格相关数值必须注明单位。
   **summaryTable 格式要求**：
   - label 尽量简短（≤10个汉字），限定词用括号标注，如 "均价(批发)"、"区间(10kg)"
   - value 格式: "数值 单位 (来源)"，来源仅写平台名，不写地区，如 "0.67 元/kg (生意社)"
   - 不同规格的价格区间分别列出，不要在 label 中放太长的说明
3. ** analysis 综合分析报告 **：请生成一份结构清晰的 Markdown 格式分析报告，必须包含以下章节：
   - ### 📊 价格行情：简述主流价格区间和市场均价。
   - ### 🛒 电商平台对比：对比各大电商平台（淘宝/京东/拼多多/天猫/1688等）的报价差异和特点。
${internationalSection ? '   - ### 🌐 国际市场参考：对比国内外价差，分析跨境采购/销售机会。\n' : ''}   - ### 💡 销售建议 (卖家)：定价策略、渠道选择、竞争对手分析。
   - ### 🛍️ 购买建议 (买家)：最佳入手渠道、避坑指南、促销建议。
   请使用列表和加粗增强可读性。禁止使用三个星号 (***)，仅使用两个星号 (**)。不要返回 Markdown代码块标记，直接返回内容。
4. ** 输出格式 **：按指定 JSON Schema 返回，prices 数组中每条记录的 platform 字段请在平台名后标注数据来源（如 "京东 [Google]"、"Amazon [Brave]"、"1688 [Tavily]"、"生意社 [直连]"、"Alibaba.com [国际]" 或 "淘宝 [电商]"）。
5. ** platformCategory 分类 **：每条 price 必须标注 platformCategory 字段，取值为以下之一：
   - **"B2C"** — 淘宝、天猫、京东、拼多多、抖音商城、美团、快手、苏宁等零售电商平台
   - **"B2B"** — 1688、阿里巴巴、慧聪网等 B2B 批发/供应链平台
   - **"industry"** — 生意社、卓创资讯、我的钢铁网、百川盈孚等行业垂直数据平台
   - **"international"** — Amazon、Alibaba.com、Temu、SHEIN、Made-in-China 等跨境平台
   根据来源 URL 和平台名称判断分类。如无法判断，默认为 "B2C"。
6. ** link 字段规则（极其重要）**：每条 price 的 link 必须是从上面数据源中直接复制的真实 URL。
   每条搜索结果都有"来源: https://..."格式的URL，请将该URL原样复制作为link值。
   **绝对禁止**：编造URL、使用搜索引擎跳转URL、使用占位符URL、使用平台首页URL。
   正确示例: "https://item.jd.com/10089395873511.html"
   错误示例: "https://www.jd.com"、"https://search.jd.com/..."、""
   如果某条数据确实没有可用的真实URL，link 设为空字符串 ""。

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
          priceUnit: { type: 'STRING', description: '价格单位，如 "元/kg"、"元/吨"、"元/袋"、"元/台"、"元"' },
          link: { type: 'STRING', description: '必须使用数据源中提供的真实完整URL（以http://或https://开头）。直接复制"来源:"后面的URL，禁止编造、猜测或使用占位链接。如果没有可用URL，填写空字符串""' },
          platformCategory: { type: 'STRING', description: '平台分类: B2C(零售电商), B2B(批发), industry(行业数据), international(跨境)' },
        },
        required: ['platform', 'title', 'price', 'priceUnit', 'link', 'platformCategory'],
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
        const rawQ = safeString(body.q, 200);
        const count = Math.min(Math.max(parseInt(body.count) || 10, 1), 20);
        const freshness = safeString(body.freshness || '', 20);

        if (!rawQ) {
          return errorResponse(400, 'q: search query is required', corsHeaders);
        }

        const q = buildSearchQuery(rawQ, 200);
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

          logSearch('brave', rawQ.length, cacheHit, 200, Date.now() - startTime, null);
          return jsonResponse(braveData, { ...corsHeaders, 'X-Cache': cacheHit ? 'HIT' : 'MISS' });
        } catch (err) {
          logSearch('brave', rawQ.length, false, 502, Date.now() - startTime, err.message);
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
        const rawQuery = safeString(body.query, 500);
        const searchDepth = body.search_depth === 'advanced' ? 'advanced' : 'basic';
        const maxResults = Math.min(Math.max(parseInt(body.max_results) || 10, 1), 20);

        if (!rawQuery) {
          return errorResponse(400, 'query: search query is required', corsHeaders);
        }

        const query = buildSearchQuery(rawQuery, 500);
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

          logSearch('tavily', rawQuery.length, cacheHit, 200, Date.now() - startTime, null);
          return jsonResponse(tavilyData, { ...corsHeaders, 'X-Cache': cacheHit ? 'HIT' : 'MISS' });
        } catch (err) {
          logSearch('tavily', rawQuery.length, false, 502, Date.now() - startTime, err.message);
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

      // ==================== SEARCH PROXY: DIRECT SCRAPING (定向抓取) ====================

      if (path === '/api/search/direct' && request.method === 'POST') {
        const startTime = Date.now();
        const geminiKey = env.GEMINI_API_KEY;
        if (!geminiKey) {
          return errorResponse(500, 'Gemini API key not configured', corsHeaders);
        }

        const body = await request.json();
        const rawQuery = safeString(body.query, 200);
        if (!rawQuery) {
          return errorResponse(400, 'query: search query is required', corsHeaders);
        }

        // Match query to known price sources
        const sources = findPriceSources(rawQuery);
        if (sources.length === 0) {
          logSearch('direct', rawQuery.length, false, 200, Date.now() - startTime, 'no_match');
          return jsonResponse({ prices: [], matched: false, sources: [] }, corsHeaders);
        }

        const queryHash = await hashQuery(`direct:${rawQuery}`);
        const cacheKey = `search:direct:${queryHash}`;

        try {
          const { data: directData, cacheHit } = await getCachedOrFetch(env, cacheKey, async () => {
            const tavilyKey = env.TAVILY_API_KEY;
            if (!tavilyKey) throw new Error('Tavily API key not configured (needed for page extraction)');

            // Use Tavily Extract API to fetch pages (handles JS rendering & anti-bot)
            const urls = sources.map(s => s.url);
            const extractRes = await fetchWithRetry('https://api.tavily.com/extract', {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({
                api_key: tavilyKey,
                urls,
              }),
            }, 1, 20000);

            if (!extractRes.ok) {
              throw new Error(`Tavily Extract API error: ${extractRes.status}`);
            }

            const extractData = await extractRes.json();
            // Map extracted results back to sources by URL, extract price-relevant section
            const pages = (extractData.results || [])
              .map((result) => {
                const matchedSrc = sources.find(s => s.url === result.url) || sources[0];
                const fullContent = result.raw_content || result.content || '';
                // Find price table section — look for header row or price keywords
                const priceStart = fullContent.indexOf('最新报价');
                const tableStart = priceStart >= 0 ? priceStart : fullContent.indexOf('| 商品名称');
                const relevantContent = tableStart >= 0
                  ? fullContent.slice(Math.max(0, tableStart - 200), tableStart + 20000)
                  : fullContent.slice(0, 20000);
                return {
                  name: matchedSrc?.name || '未知',
                  keyword: matchedSrc?.keyword || '',
                  url: result.url,
                  html: relevantContent,
                };
              })
              .filter(p => p.html.length > 100);

            if (pages.length === 0) {
              throw new Error('All direct source fetches failed');
            }

            // Build Gemini extraction prompt
            const pagesText = pages.map((p, i) =>
              `--- 数据源 ${i + 1}: ${p.name} (${p.keyword}) ---\nURL: ${p.url}\n${p.html}`
            ).join('\n\n');

            const extractPrompt = `你是大宗商品价格数据提取专家。以下是从权威行业网站直接抓取的 HTML 页面内容。
请从中提取所有能找到的产品报价信息。

${pagesText}

提取要求：
1. 从表格或列表中提取每条报价，包括：产品名称、价格、单位、规格、地区、日期
2. 价格单位必须完整保留（如"元/吨"、"元/kg"、"元/袋"），不要丢弃
3. 如果页面包含多条不同规格/地区的报价，全部提取
4. source 字段填写数据来源网站名称（如"生意社"）
5. 只提取实际的价格数据，不要编造或推测`;

            const { response: geminiResponse, modelUsed } = await callGeminiWithFallback(geminiKey, {
              contents: [{ parts: [{ text: extractPrompt }] }],
              generationConfig: {
                responseMimeType: 'application/json',
                responseSchema: DIRECT_PRICE_SCHEMA,
              },
            }, { primary: 12000, fallback: 55000 });

            console.log(`Direct scrape extraction used model: ${modelUsed}`);
            const result = await geminiResponse.json();
            const text = result.candidates?.[0]?.content?.parts
              ?.map(p => p.text || '')
              .join('') || '{}';

            let parsed;
            try {
              parsed = JSON.parse(text);
            } catch {
              console.error('Failed to parse direct scrape JSON:', text.slice(0, 200));
              parsed = { prices: [] };
            }

            return {
              prices: parsed.prices || [],
              matched: true,
              sources: pages.map(p => ({ name: p.name, keyword: p.keyword, url: p.url })),
            };
          });

          logSearch('direct', rawQuery.length, cacheHit, 200, Date.now() - startTime, null);
          return jsonResponse(directData, { ...corsHeaders, 'X-Cache': cacheHit ? 'HIT' : 'MISS' });
        } catch (err) {
          logSearch('direct', rawQuery.length, false, 502, Date.now() - startTime, err.message);
          return errorResponse(502, `Direct scrape failed: ${err.message}`, corsHeaders);
        }
      }

      // ==================== SEARCH PROXY: INTERNATIONAL (跨境平台搜索) ====================

      if (path === '/api/search/international' && request.method === 'POST') {
        const startTime = Date.now();
        const geminiKey = env.GEMINI_API_KEY;
        const braveKey = env.BRAVE_API_KEY;
        if (!braveKey) {
          return errorResponse(500, 'Brave API key not configured', corsHeaders);
        }
        if (!geminiKey) {
          return errorResponse(500, 'Gemini API key not configured', corsHeaders);
        }

        const body = await request.json();
        const rawQuery = safeString(body.query, 200);
        if (!rawQuery) {
          return errorResponse(400, 'query: search query is required', corsHeaders);
        }

        const queryHash = await hashQuery(`international:${rawQuery}`);
        const cacheKey = `search:international:${queryHash}`;

        try {
          const { data: intlData, cacheHit } = await getCachedOrFetch(env, cacheKey, async () => {
            // Step 1: Translate query to English
            const { text: englishQuery, method: translationMethod } = await translateToEnglish(rawQuery, geminiKey);
            console.log(`International search: "${rawQuery}" → "${englishQuery}" (method: ${translationMethod})`);

            // Step 2: Search Brave with English query + international market keywords
            const searchQuery = buildInternationalQuery(englishQuery);
            const params = new URLSearchParams({
              q: searchQuery,
              count: '15',
            });

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

            const braveData = await braveResponse.json();
            const webResults = (braveData.web?.results || []).map(r => ({
              title: r.title || '',
              url: r.url || '',
              description: r.description || '',
            }));

            return {
              results: webResults,
              translatedQuery: englishQuery,
              translationMethod,
              originalQuery: rawQuery,
            };
          });

          logSearch('international', rawQuery.length, cacheHit, 200, Date.now() - startTime, null);
          return jsonResponse(intlData, { ...corsHeaders, 'X-Cache': cacheHit ? 'HIT' : 'MISS' });
        } catch (err) {
          logSearch('international', rawQuery.length, false, 502, Date.now() - startTime, err.message);
          return errorResponse(502, `International search failed: ${err.message}`, corsHeaders);
        }
      }

      // ==================== SEARCH PROXY: E-COMMERCE (电商平台定向搜索) ====================

      if (path === '/api/search/ecommerce' && request.method === 'POST') {
        const startTime = Date.now();
        const braveKey = env.BRAVE_API_KEY;
        if (!braveKey) {
          return errorResponse(500, 'Brave API key not configured', corsHeaders);
        }

        const body = await request.json();
        const rawQuery = safeString(body.query, 200);
        if (!rawQuery) {
          return errorResponse(400, 'query: search query is required', corsHeaders);
        }

        const queryHash = await hashQuery(`ecommerce:${rawQuery}`);
        const cacheKey = `search:ecommerce:${queryHash}`;

        try {
          const { data: ecomData, cacheHit } = await getCachedOrFetch(env, cacheKey, async () => {
            // 3 parallel Brave searches with platform-targeted queries
            const searches = [
              {
                category: 'B2C',
                query: `${rawQuery} 价格 购买 淘宝 天猫 京东 拼多多`,
                label: 'B2C零售',
              },
              {
                category: 'B2B',
                query: `${rawQuery} 批发价 供应 1688 阿里巴巴 厂家直销`,
                label: 'B2B批发',
              },
              {
                category: 'shortVideo',
                query: `${rawQuery} 价格 抖音商城 美团 快手`,
                label: '短视频/本地',
              },
            ];

            const results = await Promise.allSettled(
              searches.map(async (s) => {
                const params = new URLSearchParams({
                  q: s.query.slice(0, 200),
                  count: '10',
                });
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
                const data = await braveResponse.json();
                const webResults = (data.web?.results || []).map(r => ({
                  title: r.title || '',
                  url: r.url || '',
                  description: r.description || '',
                  category: s.category,
                  categoryLabel: s.label,
                }));
                return { category: s.category, label: s.label, results: webResults };
              })
            );

            const categories = [];
            for (const r of results) {
              if (r.status === 'fulfilled') {
                categories.push(r.value);
              }
            }
            return { categories, query: rawQuery };
          });

          logSearch('ecommerce', rawQuery.length, cacheHit, 200, Date.now() - startTime, null);
          return jsonResponse(ecomData, { ...corsHeaders, 'X-Cache': cacheHit ? 'HIT' : 'MISS' });
        } catch (err) {
          logSearch('ecommerce', rawQuery.length, false, 502, Date.now() - startTime, err.message);
          return errorResponse(502, `E-commerce search failed: ${err.message}`, corsHeaders);
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
        const directResults = Array.isArray(body.directResults) ? body.directResults : [];
        const internationalResults = Array.isArray(body.internationalResults) ? body.internationalResults : [];
        const ecommerceResults = Array.isArray(body.ecommerceResults) ? body.ecommerceResults : [];

        const braveSummary = braveResults.map((r, i) =>
          `[Brave结果${i + 1}]标题: ${safeString(r.title, 200)}\n内容摘要: ${safeString(r.content, 1000)}\n来源: ${safeString(r.url, 500)}`
        ).join('\n\n');

        const tavilySummary = tavilyResults.map((r, i) =>
          `[Tavily结果${i + 1}]标题: ${safeString(r.title, 200)}\n内容摘要: ${safeString(r.content, 1000)}\n来源: ${safeString(r.url, 500)}`
        ).join('\n\n');

        const directSummary = directResults.length > 0
          ? directResults.map((r, i) =>
              `[直连数据${i + 1}] 产品: ${safeString(r.product, 200)} | 价格: ${r.price} ${safeString(r.priceUnit, 50)} | 规格: ${safeString(r.spec || '', 200)} | 地区: ${safeString(r.region || '', 100)} | 日期: ${safeString(r.date || '', 20)} | 来源: ${safeString(r.source, 100)}`
            ).join('\n')
          : '';

        const internationalSummary = internationalResults.length > 0
          ? internationalResults.map((r, i) =>
              `[国际平台${i + 1}] 标题: ${safeString(r.title, 300)}\n描述: ${safeString(r.description, 1000)}\n来源: ${safeString(r.url, 500)}`
            ).join('\n\n')
          : '';

        const ecommerceSummary = ecommerceResults.length > 0
          ? ecommerceResults.map((cat) =>
              `[电商-${safeString(cat.label || cat.category, 50)}]\n` +
              (Array.isArray(cat.results) ? cat.results : []).map((r, j) =>
                `  结果${j + 1}: ${safeString(r.title, 200)}\n  描述: ${safeString(r.description, 500)}\n  来源: ${safeString(r.url, 500)}`
              ).join('\n')
            ).join('\n\n')
          : '';

        const prompt = buildMergePrompt(geminiRaw, braveSummary, tavilySummary, directSummary, internationalSummary, ecommerceSummary);
        const queryLen = (geminiRaw + braveSummary + tavilySummary + directSummary + internationalSummary + ecommerceSummary).length;

        try {
          const { response: geminiResponse, modelUsed } = await callGeminiWithFallback(geminiKey, {
            contents: [{ parts: [{ text: prompt }] }],
            generationConfig: {
              responseMimeType: 'application/json',
              responseSchema: MERGE_RESPONSE_SCHEMA,
            },
          }, { primary: 12000, fallback: 75000 }); // Merge needs more time: large prompt + structured JSON output

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

          // 后处理 Step 1：验证 URL 格式，清除无效链接
          if (Array.isArray(parsed.prices)) {
            parsed.prices = parsed.prices.map(p => {
              if (p.link && typeof p.link === 'string') {
                const link = p.link.trim();
                if (link.startsWith('http://') || link.startsWith('https://')) {
                  p.link = link;
                } else {
                  p.link = '';
                }
              } else {
                p.link = '';
              }
              return p;
            });
          }

          // 后处理 Step 2：对缺失 link 的条目，通过标题相似度匹配回源 URL
          postProcessMergeLinks(parsed, braveResults, tavilyResults, internationalResults, ecommerceResults);

          logSearch('merge', queryLen, false, 200, Date.now() - startTime, null);
          return jsonResponse(parsed, corsHeaders);
        } catch (err) {
          logSearch('merge', queryLen, false, 502, Date.now() - startTime, err.message);
          return errorResponse(502, `Merge analysis failed: ${err.message}`, corsHeaders);
        }
      }

      // ==================== BATCH IMPORT: SALES ====================

      if (path === '/api/sales/batch' && request.method === 'POST') {
        const body = await request.json();
        const records = Array.isArray(body.records) ? body.records : [];
        if (records.length === 0) return errorResponse(400, 'records array is required and must not be empty', corsHeaders);
        if (records.length > 500) return errorResponse(400, 'Maximum 500 records per batch', corsHeaders);

        const results = { success: 0, failed: 0, errors: [] };
        const validStmts = [];

        for (let i = 0; i < records.length; i++) {
          const data = records[i];
          data.tons = Number(data.tons) || 0;
          data.pricePerTon = Number(data.pricePerTon) || 0;
          data.totalAmount = Number(data.totalAmount) || 0;
          data.amountWithoutTax = Number(data.amountWithoutTax) || 0;
          data.taxAmount = Number(data.taxAmount) || 0;
          data.taxRate = Number(data.taxRate) || 13;
          data.shippingCost = Number(data.shippingCost) || 0;
          if (!data.id) data.id = `sale-batch-${Date.now()}-${i}`;

          const errors = validateSale(data);
          if (errors.length > 0) {
            results.failed++;
            results.errors.push({ row: i + 1, errors });
            continue;
          }

          validStmts.push(
            env.DB.prepare(`INSERT INTO sales (id, date, customer, tons, pricePerTon, totalAmount, amountWithoutTax, taxAmount, taxRate, shippingCost, invoiceNumber, invoiceStatus, payment_status, paid_amount, due_date)
              VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
              .bind(data.id, data.date, safeString(data.customer), data.tons, data.pricePerTon, data.totalAmount, data.amountWithoutTax, data.taxAmount, data.taxRate, data.shippingCost, safeString(data.invoiceNumber || '', 100), safeString(data.invoiceStatus || '待开', 20), data.payment_status || 'paid', data.paid_amount ?? data.totalAmount, data.due_date || null)
          );
        }

        if (validStmts.length > 0) {
          await env.DB.batch(validStmts);
          results.success = validStmts.length;
        }
        return jsonResponse(results, corsHeaders);
      }

      // ==================== BATCH IMPORT: PURCHASES ====================

      if (path === '/api/purchases/batch' && request.method === 'POST') {
        const body = await request.json();
        const records = Array.isArray(body.records) ? body.records : [];
        if (records.length === 0) return errorResponse(400, 'records array is required and must not be empty', corsHeaders);
        if (records.length > 500) return errorResponse(400, 'Maximum 500 records per batch', corsHeaders);

        const results = { success: 0, failed: 0, errors: [] };
        const validStmts = [];

        for (let i = 0; i < records.length; i++) {
          const data = records[i];
          data.tons = Number(data.tons) || 0;
          data.pricePerTon = Number(data.pricePerTon) || 0;
          data.totalAmount = Number(data.totalAmount) || 0;
          data.amountWithoutTax = Number(data.amountWithoutTax) || 0;
          data.taxAmount = Number(data.taxAmount) || 0;
          data.taxRate = Number(data.taxRate) || 13;
          if (!data.id) data.id = `purchase-batch-${Date.now()}-${i}`;

          const errors = validatePurchase(data);
          if (errors.length > 0) {
            results.failed++;
            results.errors.push({ row: i + 1, errors });
            continue;
          }

          validStmts.push(
            env.DB.prepare(`INSERT INTO purchases (id, date, supplier, tons, pricePerTon, totalAmount, amountWithoutTax, taxAmount, taxRate, invoiceNumber, invoiceStatus, payment_status, paid_amount, due_date)
              VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
              .bind(data.id, data.date, safeString(data.supplier), data.tons, data.pricePerTon, data.totalAmount, data.amountWithoutTax, data.taxAmount, data.taxRate, safeString(data.invoiceNumber || '', 100), safeString(data.invoiceStatus || '已收', 20), data.payment_status || 'paid', data.paid_amount ?? data.totalAmount, data.due_date || null)
          );
        }

        if (validStmts.length > 0) {
          await env.DB.batch(validStmts);
          results.success = validStmts.length;
        }
        return jsonResponse(results, corsHeaders);
      }

      // ==================== PRICE HISTORY ====================

      if (path === '/api/price-history' && request.method === 'POST') {
        const body = await request.json();
        const query = safeString(body.query, 200);
        const queryNormalized = query.toLowerCase().replace(/\s+/g, '');
        const searchDate = body.search_date || new Date().toISOString().split('T')[0];
        const prices = Array.isArray(body.prices) ? body.prices : [];

        if (!query || prices.length === 0) {
          return errorResponse(400, 'query and prices array are required', corsHeaders);
        }

        // Filter valid numeric prices
        const validPrices = prices.filter(p => typeof p.price === 'number' && p.price > 0);
        if (validPrices.length === 0) {
          return jsonResponse({ success: true, skipped: true }, corsHeaders);
        }

        const priceValues = validPrices.map(p => p.price);
        const minPrice = Math.min(...priceValues);
        const maxPrice = Math.max(...priceValues);
        const avgPrice = Math.round((priceValues.reduce((a, b) => a + b, 0) / priceValues.length) * 100) / 100;
        const priceUnit = validPrices[0]?.priceUnit || '元';

        // Source breakdown
        const breakdown = {};
        for (const p of validPrices) {
          const cat = p.platformCategory || 'unknown';
          breakdown[cat] = (breakdown[cat] || 0) + 1;
        }

        await env.DB.prepare(`INSERT OR REPLACE INTO price_history (query, query_normalized, search_date, min_price, max_price, avg_price, price_count, price_unit, source_breakdown, updated_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, datetime('now'))`)
          .bind(query, queryNormalized, searchDate, minPrice, maxPrice, avgPrice, validPrices.length, priceUnit, JSON.stringify(breakdown))
          .run();

        return jsonResponse({ success: true, data: { minPrice, maxPrice, avgPrice, count: validPrices.length } }, corsHeaders);
      }

      if (path === '/api/price-history' && request.method === 'GET') {
        const query = url.searchParams.get('query') || '';
        const days = Math.min(parseInt(url.searchParams.get('days')) || 30, 365);
        const queryNormalized = query.toLowerCase().replace(/\s+/g, '');

        if (!queryNormalized) {
          return errorResponse(400, 'query parameter is required', corsHeaders);
        }

        const { results } = await env.DB.prepare(`SELECT * FROM price_history WHERE query_normalized = ? AND search_date >= date('now', '-' || ? || ' days') ORDER BY search_date ASC`)
          .bind(queryNormalized, days)
          .all();

        return jsonResponse({ query, days, history: results }, corsHeaders);
      }

      // ==================== PAYMENT TRACKING (应收应付) ====================

      // Record payment for a sale
      if (path.match(/^\/api\/sales\/[^/]+\/payment$/) && request.method === 'PUT') {
        const id = extractId(path);
        if (!id) return errorResponse(400, 'Invalid ID', corsHeaders);

        const body = await request.json();
        const paidAmount = Number(body.paid_amount);
        if (!isFiniteNumber(paidAmount) || paidAmount < 0) {
          return errorResponse(400, 'paid_amount must be a non-negative number', corsHeaders);
        }

        // Get total amount to determine status
        const { results } = await env.DB.prepare('SELECT totalAmount FROM sales WHERE id = ?').bind(id).all();
        if (results.length === 0) return errorResponse(404, 'Sale not found', corsHeaders);

        const totalAmount = results[0].totalAmount;
        let paymentStatus = 'unpaid';
        if (paidAmount >= totalAmount) paymentStatus = 'paid';
        else if (paidAmount > 0) paymentStatus = 'partial';

        await env.DB.prepare(`UPDATE sales SET paid_amount = ?, payment_status = ?, payment_date = ? WHERE id = ?`)
          .bind(paidAmount, paymentStatus, body.payment_date || new Date().toISOString().split('T')[0], id)
          .run();

        return jsonResponse({ success: true, payment_status: paymentStatus }, corsHeaders);
      }

      // Record payment for a purchase
      if (path.match(/^\/api\/purchases\/[^/]+\/payment$/) && request.method === 'PUT') {
        const id = extractId(path);
        if (!id) return errorResponse(400, 'Invalid ID', corsHeaders);

        const body = await request.json();
        const paidAmount = Number(body.paid_amount);
        if (!isFiniteNumber(paidAmount) || paidAmount < 0) {
          return errorResponse(400, 'paid_amount must be a non-negative number', corsHeaders);
        }

        const { results } = await env.DB.prepare('SELECT totalAmount FROM purchases WHERE id = ?').bind(id).all();
        if (results.length === 0) return errorResponse(404, 'Purchase not found', corsHeaders);

        const totalAmount = results[0].totalAmount;
        let paymentStatus = 'unpaid';
        if (paidAmount >= totalAmount) paymentStatus = 'paid';
        else if (paidAmount > 0) paymentStatus = 'partial';

        await env.DB.prepare(`UPDATE purchases SET paid_amount = ?, payment_status = ?, payment_date = ? WHERE id = ?`)
          .bind(paidAmount, paymentStatus, body.payment_date || new Date().toISOString().split('T')[0], id)
          .run();

        return jsonResponse({ success: true, payment_status: paymentStatus }, corsHeaders);
      }

      // Receivables summary (应收汇总)
      if (path === '/api/receivables/summary' && request.method === 'GET') {
        const { results: allSales } = await env.DB.prepare(
          `SELECT id, date, customer, totalAmount, paid_amount, payment_status, due_date, payment_date FROM sales WHERE payment_status != 'paid' OR due_date IS NOT NULL ORDER BY due_date ASC`
        ).all();

        const today = new Date().toISOString().split('T')[0];
        let totalReceivable = 0;
        let totalOverdue = 0;
        const agingBuckets = { '0-30': 0, '31-60': 0, '61-90': 0, '90+': 0 };
        const customerRanking = {};

        for (const s of allSales) {
          const unpaid = (s.totalAmount || 0) - (s.paid_amount || 0);
          if (unpaid <= 0) continue;
          totalReceivable += unpaid;

          const customer = s.customer || '未知';
          customerRanking[customer] = (customerRanking[customer] || 0) + unpaid;

          if (s.due_date && s.due_date < today) {
            totalOverdue += unpaid;
            const daysDiff = Math.floor((new Date(today) - new Date(s.due_date)) / 86400000);
            if (daysDiff <= 30) agingBuckets['0-30'] += unpaid;
            else if (daysDiff <= 60) agingBuckets['31-60'] += unpaid;
            else if (daysDiff <= 90) agingBuckets['61-90'] += unpaid;
            else agingBuckets['90+'] += unpaid;
          }
        }

        const topCustomers = Object.entries(customerRanking)
          .sort((a, b) => b[1] - a[1])
          .slice(0, 10)
          .map(([name, amount]) => ({ name, amount }));

        const { results: totalPaidRes } = await env.DB.prepare(
          `SELECT COALESCE(SUM(paid_amount), 0) as total FROM sales`
        ).all();
        const { results: totalSalesRes } = await env.DB.prepare(
          `SELECT COALESCE(SUM(totalAmount), 0) as total FROM sales`
        ).all();
        const collectionRate = totalSalesRes[0].total > 0
          ? Math.round((totalPaidRes[0].total / totalSalesRes[0].total) * 10000) / 100
          : 100;

        return jsonResponse({
          totalReceivable, totalOverdue, agingBuckets, topCustomers, collectionRate,
          details: allSales.filter(s => (s.totalAmount || 0) - (s.paid_amount || 0) > 0),
        }, corsHeaders);
      }

      // Payables summary (应付汇总)
      if (path === '/api/payables/summary' && request.method === 'GET') {
        const { results: allPurchases } = await env.DB.prepare(
          `SELECT id, date, supplier, totalAmount, paid_amount, payment_status, due_date, payment_date FROM purchases WHERE payment_status != 'paid' OR due_date IS NOT NULL ORDER BY due_date ASC`
        ).all();

        const today = new Date().toISOString().split('T')[0];
        let totalPayable = 0;
        let totalOverdue = 0;
        const agingBuckets = { '0-30': 0, '31-60': 0, '61-90': 0, '90+': 0 };
        const supplierRanking = {};

        for (const p of allPurchases) {
          const unpaid = (p.totalAmount || 0) - (p.paid_amount || 0);
          if (unpaid <= 0) continue;
          totalPayable += unpaid;

          const supplier = p.supplier || '未知';
          supplierRanking[supplier] = (supplierRanking[supplier] || 0) + unpaid;

          if (p.due_date && p.due_date < today) {
            totalOverdue += unpaid;
            const daysDiff = Math.floor((new Date(today) - new Date(p.due_date)) / 86400000);
            if (daysDiff <= 30) agingBuckets['0-30'] += unpaid;
            else if (daysDiff <= 60) agingBuckets['31-60'] += unpaid;
            else if (daysDiff <= 90) agingBuckets['61-90'] += unpaid;
            else agingBuckets['90+'] += unpaid;
          }
        }

        const topSuppliers = Object.entries(supplierRanking)
          .sort((a, b) => b[1] - a[1])
          .slice(0, 10)
          .map(([name, amount]) => ({ name, amount }));

        const { results: totalPaidRes } = await env.DB.prepare(
          `SELECT COALESCE(SUM(paid_amount), 0) as total FROM purchases`
        ).all();
        const { results: totalPurchRes } = await env.DB.prepare(
          `SELECT COALESCE(SUM(totalAmount), 0) as total FROM purchases`
        ).all();
        const paymentRate = totalPurchRes[0].total > 0
          ? Math.round((totalPaidRes[0].total / totalPurchRes[0].total) * 10000) / 100
          : 100;

        return jsonResponse({
          totalPayable, totalOverdue, agingBuckets, topSuppliers, paymentRate,
          details: allPurchases.filter(p => (p.totalAmount || 0) - (p.paid_amount || 0) > 0),
        }, corsHeaders);
      }

      // ==================== ALERTS (智能预警) ====================

      if (path === '/api/alerts' && request.method === 'GET') {
        const unreadOnly = url.searchParams.get('unread_only') === 'true';
        const limit = Math.min(parseInt(url.searchParams.get('limit')) || 20, 100);

        let query = 'SELECT * FROM alerts WHERE is_dismissed = 0';
        if (unreadOnly) query += ' AND is_read = 0';
        query += ' ORDER BY created_at DESC LIMIT ?';

        const { results } = await env.DB.prepare(query).bind(limit).all();
        return jsonResponse(results, corsHeaders);
      }

      if (path === '/api/alerts/count' && request.method === 'GET') {
        const { results } = await env.DB.prepare(
          'SELECT COUNT(*) as count FROM alerts WHERE is_read = 0 AND is_dismissed = 0'
        ).all();
        return jsonResponse({ count: results[0].count }, corsHeaders);
      }

      if (path.match(/^\/api\/alerts\/\d+\/read$/) && request.method === 'PUT') {
        const alertId = extractId(path);
        if (!alertId) return errorResponse(400, 'Invalid ID', corsHeaders);
        await env.DB.prepare('UPDATE alerts SET is_read = 1 WHERE id = ?').bind(alertId).run();
        return jsonResponse({ success: true }, corsHeaders);
      }

      if (path === '/api/alerts/read-all' && request.method === 'PUT') {
        await env.DB.prepare('UPDATE alerts SET is_read = 1 WHERE is_read = 0').run();
        return jsonResponse({ success: true }, corsHeaders);
      }

      if (path.match(/^\/api\/alerts\/\d+$/) && request.method === 'DELETE') {
        const alertId = extractId(path);
        if (!alertId) return errorResponse(400, 'Invalid ID', corsHeaders);
        await env.DB.prepare('UPDATE alerts SET is_dismissed = 1 WHERE id = ?').bind(alertId).run();
        return jsonResponse({ success: true }, corsHeaders);
      }

      // ==================== DASHBOARD (aggregated metrics) ====================

      if (path === '/api/dashboard' && request.method === 'GET') {
        const year = url.searchParams.get('year') || new Date().getFullYear().toString();
        const dateStart = `${year}-01-01`;
        const dateEnd = `${year}-12-31`;

        // --- Aggregated purchase totals ---
        const { results: [purchaseAgg] } = await env.DB.prepare(`
          SELECT
            COALESCE(SUM(tons), 0) as totalTons,
            COALESCE(SUM(totalAmount), 0) as totalAmount,
            COALESCE(SUM(amountWithoutTax), 0) as totalAmountWithoutTax,
            COALESCE(SUM(taxAmount), 0) as totalTaxAmount,
            COUNT(*) as recordCount
          FROM purchases WHERE date >= ? AND date <= ?
        `).bind(dateStart, dateEnd).all();

        // --- Aggregated sales totals ---
        const { results: [salesAgg] } = await env.DB.prepare(`
          SELECT
            COALESCE(SUM(tons), 0) as totalTons,
            COALESCE(SUM(totalAmount), 0) as totalAmount,
            COALESCE(SUM(amountWithoutTax), 0) as totalAmountWithoutTax,
            COALESCE(SUM(taxAmount), 0) as totalTaxAmount,
            COALESCE(SUM(shippingCost), 0) as totalShipping,
            COUNT(*) as recordCount
          FROM sales WHERE date >= ? AND date <= ?
        `).bind(dateStart, dateEnd).all();

        // --- Average cost per ton (purchase) ---
        const avgCostPerTon = purchaseAgg.totalTons > 0
          ? Math.round(purchaseAgg.totalAmountWithoutTax / purchaseAgg.totalTons * 100) / 100
          : 0;

        // --- Inventory balance (all time: total purchased - total sold) ---
        const { results: [invAll] } = await env.DB.prepare(`
          SELECT
            COALESCE((SELECT SUM(tons) FROM purchases), 0) -
            COALESCE((SELECT SUM(tons) FROM sales), 0) as inventoryTons
        `).all();

        // --- Monthly breakdown ---
        const { results: monthlyPurchases } = await env.DB.prepare(`
          SELECT
            CAST(strftime('%m', date) AS INTEGER) as month,
            COALESCE(SUM(tons), 0) as purchaseTons,
            COALESCE(SUM(totalAmount), 0) as purchaseAmount,
            COALESCE(SUM(amountWithoutTax), 0) as purchaseAmountNoTax,
            COALESCE(SUM(taxAmount), 0) as purchaseTax
          FROM purchases WHERE date >= ? AND date <= ?
          GROUP BY strftime('%m', date)
        `).bind(dateStart, dateEnd).all();

        const { results: monthlySales } = await env.DB.prepare(`
          SELECT
            CAST(strftime('%m', date) AS INTEGER) as month,
            COALESCE(SUM(tons), 0) as salesTons,
            COALESCE(SUM(totalAmount), 0) as salesAmount,
            COALESCE(SUM(amountWithoutTax), 0) as salesAmountNoTax,
            COALESCE(SUM(taxAmount), 0) as salesTax,
            COALESCE(SUM(shippingCost), 0) as salesShipping
          FROM sales WHERE date >= ? AND date <= ?
          GROUP BY strftime('%m', date)
        `).bind(dateStart, dateEnd).all();

        // Build monthly map
        const monthNames = ['1月','2月','3月','4月','5月','6月','7月','8月','9月','10月','11月','12月'];
        const pMap = {};
        for (const r of monthlyPurchases) pMap[r.month] = r;
        const sMap = {};
        for (const r of monthlySales) sMap[r.month] = r;

        const monthlyPerformance = [];
        for (let m = 1; m <= 12; m++) {
          const p = pMap[m] || {};
          const s = sMap[m] || {};
          const revenue = s.salesAmountNoTax || 0;
          const cost = p.purchaseAmountNoTax || 0;
          const shipping = s.salesShipping || 0;
          const grossProfit = revenue - cost;
          monthlyPerformance.push({
            name: monthNames[m - 1],
            revenue,
            cost,
            profit: grossProfit,
            purchaseTons: p.purchaseTons || 0,
            salesTons: s.salesTons || 0,
            netProfit: grossProfit - shipping,
            yoy: 0,
            mom: 0,
            deflator: 0,
          });
        }

        // --- Financial statement (不含税口径) ---
        const salesRevenue = salesAgg.totalAmountWithoutTax || 0;
        const costOfSales = purchaseAgg.totalAmountWithoutTax || 0;
        const grossProfit = salesRevenue - costOfSales;
        const grossMargin = salesRevenue > 0 ? Math.round(grossProfit / salesRevenue * 10000) / 100 : 0;
        const shippingFee = salesAgg.totalShipping || 0;
        const taxSurcharge = 0; // Placeholder: computed from VAT
        const adminExpense = 0;
        const incomeTax = 0;
        const netProfit = grossProfit - taxSurcharge - shippingFee - adminExpense - incomeTax;
        const netMargin = salesRevenue > 0 ? Math.round(netProfit / salesRevenue * 10000) / 100 : 0;

        // --- VAT statistics ---
        const cumulativeInput = purchaseAgg.totalTaxAmount || 0;
        const cumulativeOutput = salesAgg.totalTaxAmount || 0;
        const estimatedPayable = cumulativeOutput - cumulativeInput;

        // --- Tax inclusive summary ---
        const purchaseTotal = purchaseAgg.totalAmount || 0;
        const salesTotal = salesAgg.totalAmount || 0;

        return jsonResponse({
          metrics: {
            inventoryTons: Math.round((invAll.inventoryTons || 0) * 100) / 100,
            purchaseTotalTons: Math.round((purchaseAgg.totalTons || 0) * 100) / 100,
            purchaseTotalAmount: Math.round((purchaseAgg.totalAmount || 0) * 100) / 100,
            salesTotalTons: Math.round((salesAgg.totalTons || 0) * 100) / 100,
            salesTotalAmount: Math.round((salesAgg.totalAmount || 0) * 100) / 100,
            avgCostPerTon,
          },
          monthlyPerformance,
          financialStatement: {
            salesRevenue: Math.round(salesRevenue * 100) / 100,
            costOfSales: Math.round(costOfSales * 100) / 100,
            taxSurcharge,
            shippingFee: Math.round(shippingFee * 100) / 100,
            adminExpense,
            incomeTax,
            grossProfit: Math.round(grossProfit * 100) / 100,
            grossMargin,
            netProfit: Math.round(netProfit * 100) / 100,
            netMargin,
          },
          vatStatistics: {
            cumulativeInput: Math.round(cumulativeInput * 100) / 100,
            cumulativeOutput: Math.round(cumulativeOutput * 100) / 100,
            certifiedInput: Math.round(cumulativeInput * 100) / 100,
            invoicedOutput: Math.round(cumulativeOutput * 100) / 100,
            estimatedPayable: Math.round(estimatedPayable * 100) / 100,
          },
          taxInclusiveSummary: {
            purchaseTotal: Math.round(purchaseTotal * 100) / 100,
            salesTotal: Math.round(salesTotal * 100) / 100,
            difference: Math.round((salesTotal - purchaseTotal) * 100) / 100,
          },
        }, corsHeaders);
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

  // ==================== Scheduled Handler (Cron: daily alert check) ====================
  async scheduled(event, env, ctx) {
    console.log('Cron trigger: running daily alert checks');
    const today = new Date().toISOString().split('T')[0];

    // Helper: insert alert only if no duplicate in last 24h
    async function insertAlertIfNew(type, severity, title, message, data = '{}') {
      const { results } = await env.DB.prepare(
        `SELECT id FROM alerts WHERE type = ? AND title = ? AND created_at > datetime('now', '-1 day') LIMIT 1`
      ).bind(type, title).all();
      if (results.length > 0) return; // duplicate within 24h
      await env.DB.prepare(
        `INSERT INTO alerts (type, severity, title, message, data) VALUES (?, ?, ?, ?, ?)`
      ).bind(type, severity, title, message, data).run();
    }

    try {
      // 1. Inventory zero check: items where purchase total <= sales total
      const { results: inventoryCheck } = await env.DB.prepare(`
        SELECT p.product, COALESCE(SUM(p.tons), 0) as purchased, COALESCE(s.sold, 0) as sold
        FROM (SELECT supplier as product, SUM(tons) as tons FROM purchases GROUP BY supplier) p
        LEFT JOIN (SELECT customer as product, SUM(tons) as sold FROM sales GROUP BY customer) s ON p.product = s.product
        HAVING purchased - sold <= 0
      `).all();

      for (const item of inventoryCheck) {
        await insertAlertIfNew('inventory_zero', 'critical',
          `库存归零：${item.product}`,
          `${item.product} 的库存已归零或为负，采购 ${item.purchased} 吨，已售 ${item.sold} 吨`,
          JSON.stringify(item));
      }

      // 2. Overdue receivables check
      const { results: overdueReceivables } = await env.DB.prepare(
        `SELECT id, customer, totalAmount, paid_amount, due_date FROM sales WHERE due_date < ? AND payment_status != 'paid'`
      ).bind(today).all();

      for (const r of overdueReceivables) {
        const unpaid = (r.totalAmount || 0) - (r.paid_amount || 0);
        await insertAlertIfNew('receivable_overdue', 'warning',
          `应收逾期：${r.customer}`,
          `客户 ${r.customer} 有 ¥${unpaid.toFixed(2)} 应收款已逾期（到期日: ${r.due_date}）`,
          JSON.stringify(r));
      }

      // 3. Payables due within 7 days
      const { results: upcomingPayables } = await env.DB.prepare(
        `SELECT id, supplier, totalAmount, paid_amount, due_date FROM purchases WHERE due_date BETWEEN ? AND date(?, '+7 days') AND payment_status != 'paid'`
      ).bind(today, today).all();

      for (const p of upcomingPayables) {
        const unpaid = (p.totalAmount || 0) - (p.paid_amount || 0);
        await insertAlertIfNew('payable_upcoming', 'info',
          `应付即将到期：${p.supplier}`,
          `供应商 ${p.supplier} 有 ¥${unpaid.toFixed(2)} 应付款将于 ${p.due_date} 到期`,
          JSON.stringify(p));
      }

      // 4. Price volatility check: >15% change in 7 days
      const { results: priceChecks } = await env.DB.prepare(`
        SELECT a.query, a.avg_price as current_avg, b.avg_price as prev_avg
        FROM price_history a
        JOIN price_history b ON a.query_normalized = b.query_normalized
        WHERE a.search_date = (SELECT MAX(search_date) FROM price_history WHERE query_normalized = a.query_normalized)
        AND b.search_date = (SELECT MIN(search_date) FROM price_history WHERE query_normalized = a.query_normalized AND search_date >= date('now', '-7 days'))
        AND a.search_date != b.search_date
      `).all();

      for (const pc of priceChecks) {
        if (pc.prev_avg > 0) {
          const changePercent = Math.round(((pc.current_avg - pc.prev_avg) / pc.prev_avg) * 10000) / 100;
          if (Math.abs(changePercent) >= 15) {
            const direction = changePercent > 0 ? '上涨' : '下跌';
            await insertAlertIfNew('price_volatility', 'warning',
              `价格波动：${pc.query}`,
              `${pc.query} 近7天价格${direction} ${Math.abs(changePercent)}%（${pc.prev_avg} → ${pc.current_avg}）`,
              JSON.stringify(pc));
          }
        }
      }

      console.log('Cron completed: alert checks done');
    } catch (err) {
      console.error('Cron error:', err.message, err.stack);
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

// ==================== URL 标题匹配工具函数 ====================

/** 从所有数据源中提取 {title, url} 平铺数组 */
function buildUrlLookup(braveResults, tavilyResults, internationalResults, ecommerceResults) {
  const lookup = [];
  for (const r of braveResults) {
    if (r.url && r.title) lookup.push({ title: r.title, url: r.url });
  }
  for (const r of tavilyResults) {
    if (r.url && r.title) lookup.push({ title: r.title, url: r.url });
  }
  for (const r of internationalResults) {
    if (r.url && r.title) lookup.push({ title: r.title, url: r.url });
  }
  for (const cat of ecommerceResults) {
    const results = Array.isArray(cat.results) ? cat.results : [];
    for (const r of results) {
      if (r.url && r.title) lookup.push({ title: r.title, url: r.url });
    }
  }
  return lookup;
}

/** 归一化字符串：小写 + 去空格 + 去括号引号 + 去标点 */
function normalizeForMatch(str) {
  if (!str) return '';
  return str
    .toLowerCase()
    .replace(/[\s\u3000]+/g, '')
    .replace(/[【】\[\]()（）""''「」『』《》<>]/g, '')
    .replace(/[,，.。!！?？;；:：、·\-—_]/g, '');
}

/** 提取有意义的 token：CJK 双字词 + ASCII 单词 */
function extractTokens(str) {
  if (!str) return [];
  const tokens = [];
  const asciiWords = str.match(/[a-zA-Z0-9]{2,}/g);
  if (asciiWords) {
    for (const w of asciiWords) tokens.push(w.toLowerCase());
  }
  const cjkChars = str.match(/[\u4e00-\u9fff\u3400-\u4dbf]/g);
  if (cjkChars && cjkChars.length >= 2) {
    for (let i = 0; i < cjkChars.length - 1; i++) {
      tokens.push(cjkChars[i] + cjkChars[i + 1]);
    }
  }
  return tokens;
}

/**
 * 4 层标题匹配策略，返回最佳匹配的 URL
 * 1. 精确匹配  2. 子串包含(≥6字符)  3. 前缀匹配(8字符)  4. Token重叠(≥60%)
 */
function matchTitleToUrl(priceTitle, urlLookup) {
  if (!priceTitle || urlLookup.length === 0) return '';
  const normalizedPrice = normalizeForMatch(priceTitle);
  if (normalizedPrice.length < 2) return '';

  const normalizedLookup = urlLookup.map(item => ({
    ...item,
    normalized: normalizeForMatch(item.title),
  }));

  // Tier 1: 精确匹配
  for (const item of normalizedLookup) {
    if (item.normalized === normalizedPrice) return item.url;
  }

  // Tier 2: 子串包含
  let bestSubMatch = null;
  let bestSubLen = 0;
  for (const item of normalizedLookup) {
    if (item.normalized.length < 4) continue;
    if (normalizedPrice.includes(item.normalized) || item.normalized.includes(normalizedPrice)) {
      const overlapLen = Math.min(normalizedPrice.length, item.normalized.length);
      if (overlapLen > bestSubLen) {
        bestSubLen = overlapLen;
        bestSubMatch = item.url;
      }
    }
  }
  if (bestSubMatch && bestSubLen >= 6) return bestSubMatch;

  // Tier 3: 前缀匹配 (8字符)
  if (normalizedPrice.length >= 8) {
    const prefix = normalizedPrice.slice(0, 8);
    for (const item of normalizedLookup) {
      if (item.normalized.length >= 8 && item.normalized.startsWith(prefix)) return item.url;
    }
  }

  // Tier 4: Token 重叠 (≥60%)
  const priceTokens = extractTokens(priceTitle);
  if (priceTokens.length >= 2) {
    let bestRatio = 0;
    let bestUrl = '';
    for (const item of urlLookup) {
      const srcTokens = extractTokens(item.title);
      if (srcTokens.length < 2) continue;
      const priceSet = new Set(priceTokens);
      let common = 0;
      for (const t of srcTokens) { if (priceSet.has(t)) common++; }
      const ratio = common / Math.min(priceTokens.length, srcTokens.length);
      if (ratio > bestRatio) { bestRatio = ratio; bestUrl = item.url; }
    }
    if (bestRatio >= 0.6) return bestUrl;
  }

  return '';
}

/** 后处理：对缺失 link 的 price 条目，通过标题相似度匹配回源 URL */
function postProcessMergeLinks(parsed, braveResults, tavilyResults, internationalResults, ecommerceResults) {
  if (!Array.isArray(parsed.prices) || parsed.prices.length === 0) return;
  const urlLookup = buildUrlLookup(braveResults, tavilyResults, internationalResults, ecommerceResults);
  if (urlLookup.length === 0) return;

  let matchedCount = 0;
  for (const price of parsed.prices) {
    if (price.link && price.link.startsWith('http')) continue;
    const matchedUrl = matchTitleToUrl(price.title, urlLookup);
    if (matchedUrl) {
      price.link = matchedUrl;
      matchedCount++;
    }
  }
  if (matchedCount > 0) {
    console.log(`Post-processing: matched ${matchedCount} missing URLs by title similarity`);
  }
}
