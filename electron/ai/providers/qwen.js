// Qwen (通义千问) adapter — OpenAI Chat-Completions compatible (Alibaba Cloud DashScope / Bailian).
// Endpoint: https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions (Bearer key).
// NOTE: the baseURL KEEPS the /compatible-mode/v1 path segment — the factory only appends
// /chat/completions — unlike DeepSeek's root baseURL. International users would swap the host for
// dashscope-intl.aliyuncs.com (keys are region-scoped and not interchangeable); we default to the
// mainland (.cn) endpoint since SoloLedger targets domestic users.
//
// Default model = qwen-plus. The whitelist deliberately lists only "hybrid-thinking, thinking-OFF
// by default" models (qwen-plus / qwen-max / qwen-flash / qwen-turbo) so the non-streaming factory
// + read-only agent "已查询" loop works out of the box: Qwen's pure-reasoning (qwq / *-thinking) and
// omni models force stream=true and would error on a non-streaming call, so they are excluded; vl /
// coder are excluded as out-of-scope (text chat only). (Model IDs verified against the official
// Alibaba Cloud Model Studio docs — OpenAI compatibility / function calling / models list.)
//
// fetch-only, no SDK; the decrypted key is injected by index.js and never leaves main.

const { createOpenAICompatibleAdapter } = require('./_openaiCompatible');

module.exports = createOpenAICompatibleAdapter({
  id: 'qwen',
  name: 'Qwen (通义千问)',
  baseURL: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
  defaultModel: 'qwen-plus',
  availableModels: [
    { label: 'Qwen Plus', value: 'qwen-plus' },
    { label: 'Qwen Max', value: 'qwen-max' },
    { label: 'Qwen Flash', value: 'qwen-flash' },
    { label: 'Qwen Turbo (兼容旧版)', value: 'qwen-turbo' },
  ],
  capabilities: { ocr: false, tts: false, webGrounding: false },
});
