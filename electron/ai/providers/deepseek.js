// DeepSeek (深度求索) adapter — OpenAI Chat-Completions compatible.
// Endpoint: https://api.deepseek.com/chat/completions (Bearer key).
//
// Default model = deepseek-chat — the only DeepSeek model confirmed reachable in real-key QA
// (deepseek-v4-pro / deepseek-v4-flash failed to connect on the tested account, 2026-06). It supports
// the OpenAI ChatCompletions interface + tool calls (the read-only agent "已查询" loop). It is the
// compatibility option (labeled deprecating 2026/07/24, aliases deepseek-v4-flash non-thinking) but is
// the working out-of-box default for now; V4 Pro/Flash stay selectable for accounts that have them.
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
  defaultModel: 'deepseek-chat',
  availableModels: [
    { label: 'DeepSeek V4 Pro', value: 'deepseek-v4-pro' },
    { label: 'DeepSeek V4 Flash', value: 'deepseek-v4-flash' },
    { label: 'DeepSeek Chat (兼容旧版，将弃用 2026-07)', value: 'deepseek-chat' },
  ],
  capabilities: { ocr: false, tts: false, webGrounding: false },
});
