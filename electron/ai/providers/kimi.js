// Kimi (月之暗面 Moonshot AI) adapter — OpenAI Chat-Completions compatible.
// Endpoint: https://api.moonshot.cn/v1/chat/completions (Bearer key). The baseURL keeps the /v1
// segment (the factory only appends /chat/completions). International users on platform.moonshot.ai
// would swap the host to https://api.moonshot.ai/v1 — mainland (.cn) and intl (.ai) keys are NOT
// interchangeable (a .cn key against the .ai host returns 401); we default to the mainland (.cn)
// endpoint since SoloLedger targets domestic users.
//
// Default model = moonshot-v1-128k — the Kimi models confirmed reachable in real-key QA were the
// moonshot-v1 long-context line (kimi-k2.6 / k2.5 failed to connect on the tested account, 2026-06);
// 128k is chosen over 32k for the larger context. The whitelist still keeps k2.6 / k2.5 (selectable
// for accounts that have them) plus moonshot-v1-128k / 32k; kimi-k2.7-code is excluded as out-of-scope.
// (The legacy kimi-k2 snapshots 0711 / 0905 / turbo / thinking and kimi-latest were retired 2026-05-25.)
// (Model IDs verified against the official Moonshot / Kimi docs.)
//
// NOTE: Kimi does NOT support tool_choice:'required' (only 'none'/'auto'/null) — the factory uses
// 'auto', so there is no conflict.
//
// fetch-only, no SDK; the decrypted key is injected by index.js and never leaves main.

const { createOpenAICompatibleAdapter } = require('./_openaiCompatible');

module.exports = createOpenAICompatibleAdapter({
  id: 'kimi',
  name: 'Kimi (月之暗面)',
  baseURL: 'https://api.moonshot.cn/v1',
  defaultModel: 'moonshot-v1-128k',
  availableModels: [
    { label: 'Kimi K2.6', value: 'kimi-k2.6' },
    { label: 'Kimi K2.5', value: 'kimi-k2.5' },
    { label: 'Moonshot v1 128K', value: 'moonshot-v1-128k' },
    { label: 'Moonshot v1 32K (兼容旧版)', value: 'moonshot-v1-32k' },
  ],
  capabilities: { ocr: true, tts: false, webGrounding: false },
  // Vision OCR model (PR-3d) — developer constant; OCR always uses this regardless of the chat model.
  // moonshot-v1-32k-vision-preview is a NON-thinking vision model, so no extraBody is needed. It takes
  // an image_url content block (base64 data URL — Kimi accepts base64 only, which suits local images),
  // and the content stays an ARRAY (the factory builds it that way). Verified against Moonshot/Kimi docs.
  visionModel: 'moonshot-v1-32k-vision-preview',
});
