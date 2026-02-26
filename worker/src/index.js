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

      // ==================== SEARCH PROXY ====================

      if (path === '/api/search/brave' && request.method === 'POST') {
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

        const params = new URLSearchParams({ q, count: String(count) });
        if (freshness) params.set('freshness', freshness);

        const braveResponse = await fetch(
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
          console.error('Brave API error:', braveResponse.status);
          return errorResponse(braveResponse.status, `Brave API error: ${braveResponse.status}`, corsHeaders);
        }

        const braveData = await braveResponse.json();
        return jsonResponse(braveData, corsHeaders);
      }

      if (path === '/api/search/tavily' && request.method === 'POST') {
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

        const tavilyResponse = await fetch('https://api.tavily.com/search', {
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
          console.error('Tavily API error:', tavilyResponse.status);
          return errorResponse(tavilyResponse.status, `Tavily API error: ${tavilyResponse.status}`, corsHeaders);
        }

        const tavilyData = await tavilyResponse.json();
        return jsonResponse(tavilyData, corsHeaders);
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

function jsonResponse(data, corsHeaders) {
  return new Response(JSON.stringify(data), {
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
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
