// DeepSeek (深度求索) adapter — OpenAI Chat-Completions compatible.
// Endpoint: https://api.deepseek.com/chat/completions (Bearer key).
//
// Default model = deepseek-chat (V3), which supports function calling (the read-only
// agent tool loop). deepseek-reasoner (R1) is intentionally NOT offered / not default:
// it does not support tool calling, so it would break the assistant's "已查询" tools.
// (A user could still type a custom model id via the advanced input, at their own risk.)
//
// fetch-only, no SDK; the decrypted key is injected by index.js and never leaves main.

const { createOpenAICompatibleAdapter } = require('./_openaiCompatible');

module.exports = createOpenAICompatibleAdapter({
  id: 'deepseek',
  name: 'DeepSeek (深度求索)',
  baseURL: 'https://api.deepseek.com',
  defaultModel: 'deepseek-chat',
  availableModels: [
    { label: 'DeepSeek Chat (V3)', value: 'deepseek-chat' },
  ],
  capabilities: { ocr: false, tts: false, webGrounding: false },
});
