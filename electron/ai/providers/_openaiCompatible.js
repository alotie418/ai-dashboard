// Shared adapter factory for OpenAI **Chat Completions**-compatible providers
// (DeepSeek now; Qwen / Kimi / GLM later). This is the /v1/chat/completions dialect
// (messages + tools[].function + choices[].message.tool_calls + role:'tool' results) —
// NOT the OpenAI Responses API, which lives separately in openai.js.
//
// fetch-only, no SDK. The decrypted API key arrives only as a function argument
// (injected by index.js); this module never touches safeStorage / the DB.
//
// Each provider = a thin config module that calls createOpenAICompatibleAdapter({...}).
// The returned adapter satisfies the same contract as the other providers:
//   meta + test/chat/analyze/ocr/dataAnalysis + chatWithTools/toToolResultsMsg/toNativeHistory
// so it plugs into index.js (business face) and agent.js (read-only tool loop) unchanged.

const { buildHttpError, wrapNetworkError, parseError } = require('./_error');

function tryParseJson(text) {
  if (!text) return null;
  const cleaned = String(text).replace(/^```(?:json)?\s*/i, '').replace(/```\s*$/i, '').trim();
  try { return JSON.parse(cleaned); } catch {}
  const m = cleaned.match(/\{[\s\S]*\}/);
  if (m) { try { return JSON.parse(m[0]); } catch {} }
  return null;
}

// Renderer Gemini-style messages ({role:'user'|'model', content|parts}) → Chat Completions
// ({role:'user'|'assistant', content}). System is passed separately, never inside history.
function toChatMessages(messages) {
  return (messages || []).map(m => {
    const role = m.role === 'model' ? 'assistant' : (m.role || 'user');
    const content = typeof m.content === 'string'
      ? m.content
      : (m.parts ? m.parts.map(p => p.text || '').join('\n') : '');
    return { role, content };
  }).filter(m => m.content);
}

function createOpenAICompatibleAdapter(cfg) {
  const {
    id,
    name,
    baseURL,
    defaultModel,
    availableModels = [],
    capabilities = { ocr: false, tts: false, webGrounding: false },
    visionModel = null,   // set → ocr() does vision OCR via this model; null → ocr() throws badRequest (text-only)
    extraBody = {},       // provider-specific body fields merged into EVERY request (e.g. Doubao Seed 2.0
                          // reasoning_effort:'minimal'). Default {} → other providers byte-unchanged.
  } = cfg;

  const LABEL = name || id;
  const ENDPOINT = `${String(baseURL).replace(/\/+$/, '')}/chat/completions`;
  const META = { id, name, defaultModel, availableModels, capabilities, visionModel };

  async function callChat(apiKey, body) {
    // extraBody first so the call's explicit fields (model/messages/tools/…) always win.
    const finalBody = { ...extraBody, ...body };
    let res;
    try {
      res = await fetch(ENDPOINT, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${apiKey}` },
        body: JSON.stringify(finalBody),
      });
    } catch (e) {
      throw wrapNetworkError(e, LABEL);
    }
    if (!res.ok) throw await buildHttpError(res, LABEL);
    return res.json();
  }

  const firstMessage = (json) => json?.choices?.[0]?.message || null;
  function extractText(json) {
    const msg = firstMessage(json);
    return msg && typeof msg.content === 'string' ? msg.content.trim() : '';
  }

  async function test(apiKey, model) {
    const json = await callChat(apiKey, {
      model: model || defaultModel,
      messages: [{ role: 'user', content: 'reply OK' }],
      max_tokens: 16,
    });
    return { ok: !!extractText(json) };
  }

  async function chat(apiKey, model, { messages, systemInstruction }) {
    const msgs = [];
    if (systemInstruction) msgs.push({ role: 'system', content: systemInstruction });
    msgs.push(...toChatMessages(messages));
    if (!msgs.some(m => m.role !== 'system')) msgs.push({ role: 'user', content: 'Hello' });
    const json = await callChat(apiKey, { model: model || defaultModel, messages: msgs });
    return { text: extractText(json) };
  }

  // ── tool-calling dialect (Chat Completions) ──
  // tools: [{type:'function', function:{name, description, parameters}}]; the model returns
  // choices[0].message.tool_calls (each {id, function:{name, arguments:JSON-string}}); results
  // go back as role:'tool' messages keyed by tool_call_id. Stateless: every round resends the
  // full messages (= system + agent-loop-accumulated history).
  const toToolDef = (t) => ({ type: 'function', function: { name: t.name, description: t.description, parameters: t.input_schema } });

  // First turn only: convert renderer messages to native history. Later turns' assistant
  // (with tool_calls) / tool messages are appended by the agent loop, not re-run through this.
  function toNativeHistory(messages) {
    return toChatMessages(messages);
  }

  async function chatWithTools(apiKey, model, { history, system, tools }) {
    const msgs = [];
    if (system) msgs.push({ role: 'system', content: system });
    msgs.push(...((history && history.length) ? history : [{ role: 'user', content: 'Hello' }]));
    const body = {
      model: model || defaultModel,
      messages: msgs,
      ...(tools && tools.length ? { tools: tools.map(toToolDef), tool_choice: 'auto' } : {}),
    };
    const json = await callChat(apiKey, body);
    const msg = firstMessage(json) || {};
    const toolCalls = Array.isArray(msg.tool_calls) ? msg.tool_calls : [];
    if (toolCalls.length) {
      return {
        type: 'tool_calls',
        // Single assistant message carrying tool_calls — the agent loop spreads single→[single].
        assistantMsg: { role: 'assistant', content: msg.content ?? null, tool_calls: toolCalls },
        calls: toolCalls.map(tc => ({ id: tc.id, name: tc.function?.name, args: tryParseJson(tc.function?.arguments) || {} })),
      };
    }
    return { type: 'final', text: extractText(json) };
  }

  // Each tool result becomes its own role:'tool' message (array → agent loop spreads into history).
  const toToolResultsMsg = (items) => items.map(({ call, result }) => ({
    role: 'tool',
    tool_call_id: call.id,
    content: JSON.stringify(result),
  }));

  async function analyze(apiKey, model, { data, marketSummary, analyzeSystemPrompt }) {
    const marketContext = marketSummary ? `\n\n${marketSummary}` : '';
    const fallbackSys = `你是一位专业的商业分析师。请分析企业经营数据并按 JSON 输出：
{
  "summary": "一段简要的经营概况总结",
  "topInsights": ["3-5条关键洞察"],
  "recommendations": ["3-5条改进建议"],
  "anomalies": ["异常指标列表"]
}`;
    const sys = analyzeSystemPrompt || fallbackSys;
    const json = await callChat(apiKey, {
      model: model || defaultModel,
      messages: [
        { role: 'system', content: sys },
        { role: 'user', content: `Analyze this business data: ${JSON.stringify(data)}${marketContext}` },
      ],
      response_format: { type: 'json_object' },
    });
    const parsed = tryParseJson(extractText(json));
    if (!parsed) throw parseError(LABEL, 'chat JSON');
    return parsed;
  }

  // OCR / vision. Text-only providers (no visionModel configured) keep the PR-1 behavior: throw a
  // stable-coded badRequest so the renderer shows a friendly aiError and the UI never advertises OCR
  // (capabilities.ocr stays false). Providers that pass a `visionModel` (e.g. Qwen qwen-vl-max) do
  // real OCR over the SAME Chat Completions endpoint with an image_url content block (base64 data
  // URL). The vision model is ALWAYS `visionModel` — never the chat `model` arg. No response_format
  // is forced (some vision models reject json_object); the ocrPrompt + tryParseJson handle the JSON.
  async function ocr(apiKey, _model, { base64Data, mimeType, ocrPrompt } = {}) {
    if (!visionModel) {
      const e = new Error(`${LABEL} OCR not supported [badRequest]`);
      e.code = 'badRequest';
      e.providerLabel = LABEL;
      throw e;
    }
    const dataUrl = `data:${mimeType || 'image/png'};base64,${base64Data || ''}`;
    const json = await callChat(apiKey, {
      model: visionModel,
      messages: [{
        role: 'user',
        content: [
          { type: 'text', text: ocrPrompt || 'Extract invoice data as JSON.' },
          { type: 'image_url', image_url: { url: dataUrl } },
        ],
      }],
    });
    const parsed = tryParseJson(extractText(json));
    if (!parsed) throw parseError(LABEL, 'OCR');
    return parsed;
  }

  async function dataAnalysis(apiKey, model, { prompt, systemInstruction }) {
    const msgs = [];
    if (systemInstruction) msgs.push({ role: 'system', content: systemInstruction });
    msgs.push({ role: 'user', content: `${prompt}\n\n请严格按 JSON 格式输出。` });
    const json = await callChat(apiKey, {
      model: model || defaultModel,
      messages: msgs,
      response_format: { type: 'json_object' },
    });
    const parsed = tryParseJson(extractText(json));
    if (!parsed) throw parseError(LABEL, 'dataAnalysis');
    return { ...parsed, groundingSources: [] };
  }

  return { meta: META, test, chat, chatWithTools, toToolResultsMsg, toNativeHistory, analyze, ocr, dataAnalysis };
}

module.exports = { createOpenAICompatibleAdapter };
