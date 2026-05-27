// Anthropic Claude adapter — 直接走 REST API，不引入 SDK
// 端点：https://docs.anthropic.com/en/api/messages

const { buildHttpError, wrapNetworkError } = require('./_error');

const API_BASE = 'https://api.anthropic.com/v1/messages';
const API_VERSION = '2023-06-01';
const LABEL = 'Anthropic';

const META = {
  id: 'anthropic',
  name: 'Claude (Anthropic)',
  defaultModel: 'claude-sonnet-4-6',
  availableModels: [
    { label: 'Claude Sonnet 4.6', value: 'claude-sonnet-4-6' },
    { label: 'Claude Opus 4.7', value: 'claude-opus-4-7' },
  ],
  capabilities: {
    ocr: true,         // 通过 messages API 的 image content
    tts: false,        // Anthropic 无 TTS
    webGrounding: false, // 不接入 web search tool（避免额外配额开销）
  },
};

async function callMessages(apiKey, body) {
  let res;
  try {
    res = await fetch(API_BASE, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': apiKey,
        'anthropic-version': API_VERSION,
      },
      body: JSON.stringify(body),
    });
  } catch (e) {
    throw wrapNetworkError(e, LABEL);
  }
  if (!res.ok) throw await buildHttpError(res, LABEL);
  return res.json();
}

function extractText(response) {
  const blocks = response?.content || [];
  return blocks.filter(b => b.type === 'text').map(b => b.text).join('').trim();
}

function tryParseJson(text) {
  if (!text) return null;
  // 去掉 ```json 包裹
  const cleaned = text.replace(/^```(?:json)?\s*/i, '').replace(/```\s*$/i, '').trim();
  try { return JSON.parse(cleaned); } catch {}
  // fallback：抠最外层大括号
  const m = cleaned.match(/\{[\s\S]*\}/);
  if (m) { try { return JSON.parse(m[0]); } catch {} }
  return null;
}

async function test(apiKey, model) {
  const json = await callMessages(apiKey, {
    model: model || META.defaultModel,
    max_tokens: 16,
    messages: [{ role: 'user', content: 'reply OK' }],
  });
  return { ok: !!extractText(json) };
}

async function chat(apiKey, model, { messages, systemInstruction }) {
  // 入参兼容 Gemini 格式：messages: [{ role, parts: [{ text }] }]
  const normalized = (messages || []).map(m => ({
    role: m.role === 'model' ? 'assistant' : (m.role || 'user'),
    content: typeof m.content === 'string' ? m.content
      : (m.parts ? m.parts.map(p => p.text).join('\n') : ''),
  })).filter(m => m.content);

  const json = await callMessages(apiKey, {
    model: model || META.defaultModel,
    max_tokens: 4096,
    system: systemInstruction || undefined,
    messages: normalized,
  });
  return { text: extractText(json) };
}

async function analyze(apiKey, model, { data, marketSummary, languageHint, analyzeSystemPrompt }) {
  const marketContext = marketSummary ? `\n\n${marketSummary}` : '';
  const fallbackSys = `你是一位专业的商业分析师。请分析以下企业经营数据，**严格按 JSON 格式返回**（不要 markdown 代码块）：
{
  "summary": "一段简要的经营概况总结",
  "topInsights": ["3-5条关键洞察"],
  "recommendations": ["3-5条改进建议"],
  "anomalies": ["异常指标列表"]
}`;
  const sys = analyzeSystemPrompt || fallbackSys;
  const json = await callMessages(apiKey, {
    model: model || META.defaultModel,
    max_tokens: 4096,
    system: sys,
    messages: [{ role: 'user', content: `Analyze this business data: ${JSON.stringify(data)}${marketContext}` }],
  });
  const text = extractText(json);
  const parsed = tryParseJson(text);
  if (!parsed) throw new Error('Claude 返回 JSON 解析失败');
  return parsed;
}

async function ocr(apiKey, model, { base64Data, mimeType, ocrPrompt }) {
  const prompt = ocrPrompt || 'Extract invoice data as JSON.';
  const json = await callMessages(apiKey, {
    model: model || META.defaultModel,
    max_tokens: 2048,
    messages: [{
      role: 'user',
      content: [
        { type: 'image', source: { type: 'base64', media_type: mimeType, data: base64Data } },
        { type: 'text', text: prompt },
      ],
    }],
  });
  const text = extractText(json);
  const parsed = tryParseJson(text);
  if (!parsed) throw new Error('Claude OCR 返回解析失败');
  return parsed;
}

async function tts() {
  throw new Error('Claude 不支持 TTS，请切换到 Gemini 使用语音功能');
}

async function dataAnalysis(apiKey, model, { prompt, systemInstruction }) {
  const json = await callMessages(apiKey, {
    model: model || META.defaultModel,
    max_tokens: 4096,
    system: systemInstruction || '',
    messages: [{ role: 'user', content: `${prompt}\n\n请严格按 JSON 格式输出，不要 markdown 代码块。` }],
  });
  const text = extractText(json);
  const parsed = tryParseJson(text);
  if (!parsed) throw new Error('Claude dataAnalysis 返回解析失败');
  return { ...parsed, groundingSources: [] }; // Claude 当前不接入 web grounding
}

module.exports = { meta: META, test, chat, analyze, ocr, tts, dataAnalysis };
