// Kimi (月之暗面 Moonshot AI) adapter — OpenAI Chat-Completions compatible.
// Endpoint: https://api.moonshot.cn/v1/chat/completions (Bearer key). The baseURL keeps the /v1
// segment (the factory only appends /chat/completions). International users on platform.moonshot.ai
// would swap the host to https://api.moonshot.ai/v1 — mainland (.cn) and intl (.ai) keys are NOT
// interchangeable (a .cn key against the .ai host returns 401); we default to the mainland (.cn)
// endpoint since SoloLedger targets domestic users.
//
// Default model = kimi-k2.6 (current flagship general model, supports tool calling). The legacy
// kimi-k2 snapshots (0711 / 0905 / turbo / thinking) and kimi-latest were retired 2026-05-25, so
// the default is the current k2.6. Whitelist keeps k2.6 / k2.5 plus the moonshot-v1 long-context
// line for compatibility; kimi-k2.7-code (coding, thinking forced-on) is excluded as out-of-scope.
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
  defaultModel: 'kimi-k2.6',
  availableModels: [
    { label: 'Kimi K2.6', value: 'kimi-k2.6' },
    { label: 'Kimi K2.5', value: 'kimi-k2.5' },
    { label: 'Moonshot v1 128K', value: 'moonshot-v1-128k' },
    { label: 'Moonshot v1 32K (兼容旧版)', value: 'moonshot-v1-32k' },
  ],
  capabilities: { ocr: false, tts: false, webGrounding: false },
});
