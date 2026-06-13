// GLM (智谱 Zhipu AI / BigModel) adapter — OpenAI Chat-Completions compatible.
// Endpoint: https://open.bigmodel.cn/api/paas/v4/chat/completions (Bearer key). NOTE the baseURL is
// the /api/paas/v4 path (NOT a bare /v1) — the factory only appends /chat/completions. The v4
// endpoint takes the raw API key as a Bearer token directly (no JWT signing needed). International
// users on Z.ai would swap the host to https://api.z.ai/api/paas/v4 (separate accounts/keys, not
// interchangeable); we default to the mainland BigModel endpoint. Do NOT point at the Coding-Plan
// endpoint /api/coding/paas/v4 (subscription-only) — the general API key only works on /api/paas/v4.
//
// Default model = glm-4.6 (mature flagship general model, supports tool calling). Whitelist adds
// glm-5.1 (newest flagship), glm-4.5-air (lightweight), glm-4.7-flash (free tier). Pure-reasoning
// glm-z1 (retired) and the glm-4.xv vision line are excluded as out-of-scope.
// (Model IDs verified against the official BigModel / Z.ai docs.)
//
// Note: the shared factory sends no `temperature`, so GLM's open-interval (0,1) temperature
// constraint does not apply. GLM API keys are an "id.secret" two-part string.
//
// fetch-only, no SDK; the decrypted key is injected by index.js and never leaves main.

const { createOpenAICompatibleAdapter } = require('./_openaiCompatible');

module.exports = createOpenAICompatibleAdapter({
  id: 'glm',
  name: 'GLM (智谱)',
  baseURL: 'https://open.bigmodel.cn/api/paas/v4',
  defaultModel: 'glm-4.6',
  availableModels: [
    { label: 'GLM-4.6', value: 'glm-4.6' },
    { label: 'GLM-5.1', value: 'glm-5.1' },
    { label: 'GLM-4.5-Air', value: 'glm-4.5-air' },
    { label: 'GLM-4.7-Flash (免费)', value: 'glm-4.7-flash' },
  ],
  capabilities: { ocr: false, tts: false, webGrounding: false },
});
