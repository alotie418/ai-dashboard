// DeepSeek (深度求索) adapter — OpenAI Chat-Completions compatible.
// Endpoint: https://api.deepseek.com/chat/completions (Bearer key).
//
// Default model = deepseek-v4-pro (V4 Pro), which supports the OpenAI ChatCompletions
// interface + tool calls (the read-only agent "已查询" loop). deepseek-v4-flash is the
// faster/cheaper variant. deepseek-chat is kept as a compatibility option — it is
// DEPRECATED (2026/07/24) and now aliases the non-thinking mode of deepseek-v4-flash.
// (Model IDs verified against the official DeepSeek docs — Models & Pricing / V4 release.)
// Note: V4 has Thinking/Non-Thinking dual modes; we send no mode param, so the model
// default applies — tool-calling under that default is a real-key verification item.
//
// fetch-only, no SDK; the decrypted key is injected by index.js and never leaves main.

const { createOpenAICompatibleAdapter } = require('./_openaiCompatible');

module.exports = createOpenAICompatibleAdapter({
  id: 'deepseek',
  name: 'DeepSeek (深度求索)',
  baseURL: 'https://api.deepseek.com',
  defaultModel: 'deepseek-v4-pro',
  availableModels: [
    { label: 'DeepSeek V4 Pro', value: 'deepseek-v4-pro' },
    { label: 'DeepSeek V4 Flash', value: 'deepseek-v4-flash' },
    { label: 'DeepSeek Chat (兼容旧版，将弃用 2026-07)', value: 'deepseek-chat' },
  ],
  capabilities: { ocr: false, tts: false, webGrounding: false },
});
