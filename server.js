// Cloud Run Express server — serves static frontend + RAG agent endpoints
// Non-agent API calls are proxied to Cloudflare Worker

import express from 'express';
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
import { rankAndDedup } from './server/ranking.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const app = express();
const PORT = process.env.PORT || 8080;
const GEMINI_API_KEY = process.env.GEMINI_API_KEY;
const WORKER_API_URL = process.env.WORKER_API_URL || 'https://api.randomabc987.icu';
const API_TOKEN = process.env.API_TOKEN;

// ==================== Middleware ====================

app.use(express.json({ limit: '2mb' }));

// Request logging
app.use((req, res, next) => {
  if (req.path.startsWith('/api/')) {
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

// ==================== Auth (for /api/* routes) ====================

function timingSafeEqual(a, b) {
  if (a.length !== b.length) return false;
  let result = 0;
  for (let i = 0; i < a.length; i++) {
    result |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return result === 0;
}

function authMiddleware(req, res, next) {
  if (!API_TOKEN) {
    return res.status(500).json({ error: 'Server misconfiguration: API_TOKEN not set' });
  }
  const authHeader = req.headers.authorization;
  if (!authHeader || !authHeader.startsWith('Bearer ')) {
    return res.status(401).json({ error: 'Authentication required' });
  }
  const token = authHeader.slice(7);
  if (!timingSafeEqual(token, API_TOKEN)) {
    return res.status(403).json({ error: 'Invalid token' });
  }
  next();
}

// ==================== Health ====================

app.get('/health', (req, res) => res.json({ status: 'ok', server: 'cloud-run' }));

// ==================== Agent Endpoints ====================

// Apply auth to all /api/* routes
app.use('/api', authMiddleware);

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

// --- Rank Agent (pure JS, no Gemini) ---
app.post('/api/agent/rank', async (req, res) => {
  const start = Date.now();
  try {
    const { query, results } = req.body;
    if (!query || !results) return res.status(400).json({ error: 'Missing query or results' });

    const result = rankAndDedup(query, results);
    console.log(`[Rank] ${Date.now() - start}ms, before=${result.dedup_stats.before}, after=${result.dedup_stats.after}`);
    res.json(result);
  } catch (err) {
    console.error(`[Rank] Error (${Date.now() - start}ms):`, err.message);
    res.status(500).json({ error: err.message });
  }
});

// --- Extract Agent ---
app.post('/api/agent/extract', async (req, res) => {
  const start = Date.now();
  try {
    const { query, search_results } = req.body;
    if (!query || !search_results) return res.status(400).json({ error: 'Missing query or search_results' });
    if (!GEMINI_API_KEY) return res.status(500).json({ error: 'GEMINI_API_KEY not configured' });

    const prompt = buildExtractPrompt(query, search_results);
    // Extract uses free-text output (no responseSchema) for speed + validateExtractResponse for safety
    const { text, modelUsed } = await callGeminiWithFallback(GEMINI_API_KEY, {
      contents: [{ parts: [{ text: prompt }] }],
      generationConfig: { responseMimeType: 'application/json' },
    });

    const parsed = parseGeminiJSON(text);
    const validated = validateExtractResponse(parsed);

    console.log(`[Extract] ${Date.now() - start}ms, model=${modelUsed}, evidence=${validated.evidence.length}`);
    res.json(validated);
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
    // Synthesize handles large evidence pools (30+ items) — use flash directly
    // Avoids wasting 60s on pro timeout before fallback; flash is faster for large prompts
    const { text, modelUsed } = await callGeminiWithFallback(GEMINI_API_KEY, {
      contents: [{ parts: [{ text: prompt }] }],
      generationConfig: {
        responseMimeType: 'application/json',
        responseSchema: SYNTHESIS_RESPONSE_SCHEMA,
      },
    }, [
      { model: 'gemini-2.5-flash', timeout: 120000 },
    ]);

    const parsed = parseGeminiJSON(text);
    if (!parsed) {
      return res.status(502).json({ error: 'Failed to parse synthesis response', raw: text.slice(0, 500) });
    }

    // Post-process: validate URLs in prices (prevent fabricated links)
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
    // Critique also handles large evidence pools — use flash directly
    const { text, modelUsed } = await callGeminiWithFallback(GEMINI_API_KEY, {
      contents: [{ parts: [{ text: prompt }] }],
      generationConfig: {
        responseMimeType: 'application/json',
        responseSchema: CRITIQUE_RESPONSE_SCHEMA,
      },
    }, [
      { model: 'gemini-2.5-flash', timeout: 120000 },
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

// Note: app.use('/api', ...) strips the /api prefix from req.url.
// We must restore it via pathRewrite so the Worker receives the full path.
app.use('/api', createProxyMiddleware({
  target: WORKER_API_URL,
  changeOrigin: true,
  pathRewrite: (path) => `/api${path}`,
  on: {
    proxyReq: (proxyReq, req) => {
      // Re-stream the body (express.json() already consumed the raw stream)
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

// Hashed assets (JS/CSS) can be cached long-term; HTML must never be cached
// so that new deployments take effect immediately without hard refresh
app.use(express.static(join(__dirname, 'dist'), {
  maxAge: '1d',       // JS/CSS with content-hash in filename → cache 1 day
  immutable: true,    // hashed files never change
  index: false,       // don't auto-serve index.html (SPA fallback below handles it)
}));

// SPA fallback — serve index.html with no-cache headers
app.get('*', (req, res) => {
  res.setHeader('Cache-Control', 'no-cache, no-store, must-revalidate');
  res.setHeader('Pragma', 'no-cache');
  res.setHeader('Expires', '0');
  res.sendFile(join(__dirname, 'dist', 'index.html'));
});

// ==================== Start Server ====================

app.listen(PORT, '0.0.0.0', () => {
  console.log(`Cloud Run server listening on port ${PORT}`);
  console.log(`Worker proxy target: ${WORKER_API_URL}`);
  console.log(`Gemini API key: ${GEMINI_API_KEY ? 'configured' : 'MISSING'}`);
  console.log(`API token: ${API_TOKEN ? 'configured' : 'MISSING'}`);
});
