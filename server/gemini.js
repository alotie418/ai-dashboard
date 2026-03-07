// Gemini API caller for Cloud Run — no 30s wall-time limit
// Uses raw fetch for full control over timeouts

const GEMINI_MODEL = 'gemini-3.1-pro';
const GEMINI_FALLBACK_MODEL = 'gemini-2.5-flash';
const GEMINI_API_BASE = 'https://generativelanguage.googleapis.com/v1beta/models';
const DEFAULT_TIMEOUT_MS = 60000; // 60s — generous since Cloud Run has no wall-time limit

/**
 * Call Gemini generateContent API with timeout.
 * @returns {{ text: string, modelUsed: string }}
 */
async function callGemini(apiKey, model, requestBody, timeoutMs = DEFAULT_TIMEOUT_MS) {
  const url = `${GEMINI_API_BASE}/${model}:generateContent?key=${apiKey}`;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);

  try {
    const res = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(requestBody),
      signal: controller.signal,
    });
    clearTimeout(timer);

    if (!res.ok) {
      const errText = await res.text();
      throw new Error(`Gemini HTTP ${res.status}: ${errText.slice(0, 300)}`);
    }

    const result = await res.json();
    const text = result.candidates?.[0]?.content?.parts?.map(p => p.text || '').join('') || '';
    return { text, modelUsed: model };
  } catch (err) {
    clearTimeout(timer);
    if (err.name === 'AbortError') {
      throw new Error(`Gemini timeout after ${timeoutMs}ms (model: ${model})`);
    }
    throw err;
  }
}

/**
 * Call Gemini with automatic model fallback.
 * Tries primary model first, falls back to secondary on failure.
 * @returns {{ text: string, modelUsed: string }}
 */
async function callGeminiWithFallback(apiKey, requestBody, customModels = null) {
  const models = customModels || [
    { model: GEMINI_MODEL, timeout: 30000 },      // 30s for primary
    { model: GEMINI_FALLBACK_MODEL, timeout: 60000 }, // 60s for fallback
  ];

  let lastError;
  for (const { model, timeout } of models) {
    try {
      return await callGemini(apiKey, model, requestBody, timeout);
    } catch (err) {
      console.warn(`[Gemini] ${model} failed: ${err.message}, trying next...`);
      lastError = err;
    }
  }
  throw lastError;
}

export {
  callGemini,
  callGeminiWithFallback,
  GEMINI_MODEL,
  GEMINI_FALLBACK_MODEL,
  GEMINI_API_BASE,
  DEFAULT_TIMEOUT_MS,
};
