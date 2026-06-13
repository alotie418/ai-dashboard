// Doubao (豆包, ByteDance) adapter — OpenAI Chat-Completions compatible (Volcengine Ark / 火山方舟).
// Endpoint: https://ark.cn-beijing.volces.com/api/v3/chat/completions (Bearer key). NOTE the baseURL
// path is /api/v3 (NOT /v1) — the factory only appends /chat/completions, so this works as-is. The
// model field takes the Model ID (model NAME) directly, e.g. doubao-seed-2-0-pro-260215 — no manual
// inference-endpoint (ep-xxxx) is required (Ark auto-associates a preset endpoint). The user must
// first real-name-verify + ACTIVATE the model in the Ark console; keys are plain Bearer tokens.
//
// Default + whitelist = Doubao-Seed-2.0 (current flagship): pro / lite / mini. Seed 2.0 fully supports
// the OpenAI Chat-Completions endpoint + standard tool_calls (Responses API is optional, only for
// Ark's built-in tools, which we don't use). Seed 2.0 is multimodal, so the SAME pro id doubles as
// the vision OCR model (image_url + base64 data URL).
//
// ⚠️ Seed 2.0 THINKS BY DEFAULT (returns reasoning_content + latency). The Seed-2.0 switch is
// `reasoning_effort` (NOT seed-1.6's `thinking` object): "minimal" = thinking off, answer directly.
// We send it on EVERY request via the factory's extraBody, so chat / tool-calling / OCR stay fast.
// Because reasoning_effort is Seed-2.0-only, the whitelist + visionModel are ALL Seed 2.0 (mixing in
// seed-1.6, which doesn't accept reasoning_effort, would be inconsistent). Pure params like
// temperature/top_p are ignored by Seed 2.0 (the factory doesn't send them anyway).
// (Model IDs verified against the Volcengine Ark docs; date suffixes rotate fast — confirm the exact
// current id in the Ark console before relying on a specific version.)
//
// fetch-only, no SDK; the decrypted key is injected by index.js and never leaves main.

const { createOpenAICompatibleAdapter } = require('./_openaiCompatible');

module.exports = createOpenAICompatibleAdapter({
  id: 'doubao',
  name: 'Doubao (豆包)',
  baseURL: 'https://ark.cn-beijing.volces.com/api/v3',
  defaultModel: 'doubao-seed-2-0-pro-260215',
  availableModels: [
    { label: 'Doubao Seed 2.0 Pro', value: 'doubao-seed-2-0-pro-260215' },
    { label: 'Doubao Seed 2.0 Lite', value: 'doubao-seed-2-0-lite-260428' },
    { label: 'Doubao Seed 2.0 Mini', value: 'doubao-seed-2-0-mini-260428' },
  ],
  capabilities: { ocr: true, tts: false, webGrounding: false },
  visionModel: 'doubao-seed-2-0-pro-260215',
  // Seed 2.0 thinks by default; disable it on every call so chat/tools/OCR are fast (no reasoning_content).
  extraBody: { reasoning_effort: 'minimal' },
});
