// OpenAI adapter — 走 Responses API（推荐用于 GPT-5+ 系列）
// 端点：https://platform.openai.com/docs/api-reference/responses
//
// 关键差异 vs Chat Completions：
//   - 端点：POST /v1/responses（不再用 /v1/chat/completions）
//   - 入参：input（字符串/数组）+ instructions 替代 messages+system
//   - JSON 输出：text.format.type = 'json_object' | 'json_schema'
//   - Vision：content type 用 'input_text' / 'input_image' (image_url 直接传 data URI)
//   - 出参：output[] 数组，便捷字段 output_text；REST 端可能不一定带 output_text，需 fallback 解析

const { buildHttpError, wrapNetworkError } = require('./_error');

const API_BASE = 'https://api.openai.com/v1/responses';
const LABEL = 'OpenAI';

const META = {
  id: 'openai',
  name: 'ChatGPT (OpenAI)',
  defaultModel: 'gpt-5.5',
  availableModels: [
    { label: 'ChatGPT 5.5', value: 'gpt-5.5' },
  ],
  capabilities: {
    ocr: true,
    tts: false, // OpenAI 有独立 audio/speech 端点，暂不接入
    webGrounding: false,
  },
};

async function callResponses(apiKey, body) {
  let res;
  try {
    res = await fetch(API_BASE, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${apiKey}`,
      },
      body: JSON.stringify(body),
    });
  } catch (e) {
    throw wrapNetworkError(e, LABEL);
  }
  if (!res.ok) throw await buildHttpError(res, LABEL);
  return res.json();
}

// Responses API 的便捷字段是 output_text；REST 接口未必返回，所以加 fallback
function extractText(response) {
  if (response?.output_text) return String(response.output_text).trim();
  const items = response?.output || [];
  const msg = items.find(o => o.type === 'message' && o.role !== 'system');
  if (!msg) return '';
  const parts = msg.content || [];
  return parts
    .filter(c => c.type === 'output_text' || c.type === 'text')
    .map(c => c.text || '')
    .join('')
    .trim();
}

function tryParseJson(text) {
  if (!text) return null;
  const cleaned = text.replace(/^```(?:json)?\s*/i, '').replace(/```\s*$/i, '').trim();
  try { return JSON.parse(cleaned); } catch {}
  const m = cleaned.match(/\{[\s\S]*\}/);
  if (m) { try { return JSON.parse(m[0]); } catch {} }
  return null;
}

// 兼容入参：旧的 Gemini 风格 messages → Responses API input 结构
function toInputMessages(messages) {
  return (messages || []).map(m => {
    const role = m.role === 'model' ? 'assistant' : (m.role || 'user');
    const textContent = typeof m.content === 'string'
      ? m.content
      : (m.parts ? m.parts.map(p => p.text || '').join('\n') : '');
    return {
      role,
      content: [{ type: role === 'assistant' ? 'output_text' : 'input_text', text: textContent }],
    };
  }).filter(m => m.content[0].text);
}

async function test(apiKey, model) {
  const json = await callResponses(apiKey, {
    model: model || META.defaultModel,
    input: 'reply OK',
    max_output_tokens: 16,
  });
  return { ok: !!extractText(json) };
}

async function chat(apiKey, model, { messages, systemInstruction }) {
  const input = toInputMessages(messages);
  const json = await callResponses(apiKey, {
    model: model || META.defaultModel,
    instructions: systemInstruction || undefined,
    input: input.length > 0 ? input : 'Hello',
  });
  return { text: extractText(json) };
}

async function analyze(apiKey, model, { data, marketSummary, languageHint }) {
  const marketContext = marketSummary ? `\n\n## 最新市场搜索数据\n${marketSummary}` : '';
  const sys = `你是一位专业的商业分析师。请分析企业经营数据并按 JSON 输出：
{
  "summary": "一段简要的经营概况总结",
  "topInsights": ["3-5条关键洞察"],
  "recommendations": ["3-5条改进建议"],
  "anomalies": ["异常指标列表"]
}`;
  const json = await callResponses(apiKey, {
    model: model || META.defaultModel,
    instructions: sys + (languageHint ? `\n\n${languageHint}` : ''),
    input: `Analyze this business data: ${JSON.stringify(data)}${marketContext}`,
    text: { format: { type: 'json_object' } },
  });
  const text = extractText(json);
  const parsed = tryParseJson(text);
  if (!parsed) throw new Error('OpenAI 返回 JSON 解析失败');
  return parsed;
}

async function ocr(apiKey, model, { base64Data, mimeType }) {
  const prompt = `你是一位专业的财务审计员。请从这张发票图片中提取信息，按 JSON 格式输出：
{
  "date": "开票日期 YYYY-MM-DD",
  "customer": "客户名称/购方名称",
  "quantity": "货物总数量及单位",
  "price": 合计不含税金额数字,
  "shipping": 运费数字,
  "invoiceNo": "发票号码",
  "totalWithTax": 价税合计数字,
  "unitPriceWithoutTax": 不含税单价数字,
  "taxAmount": 合计税额数字
}
数字字段必须是数字而非字符串，没有则填 0。`;
  const json = await callResponses(apiKey, {
    model: model || META.defaultModel,
    input: [{
      role: 'user',
      content: [
        { type: 'input_text', text: prompt },
        { type: 'input_image', image_url: `data:${mimeType};base64,${base64Data}` },
      ],
    }],
    text: { format: { type: 'json_object' } },
  });
  const text = extractText(json);
  const parsed = tryParseJson(text);
  if (!parsed) throw new Error('OpenAI OCR 返回解析失败');
  return parsed;
}

async function tts() {
  throw new Error('OpenAI Provider 暂未启用 TTS，请切换到 Gemini 使用语音功能');
}

async function dataAnalysis(apiKey, model, { prompt, systemInstruction }) {
  const json = await callResponses(apiKey, {
    model: model || META.defaultModel,
    instructions: systemInstruction || undefined,
    input: `${prompt}\n\n请严格按 JSON 格式输出。`,
    text: { format: { type: 'json_object' } },
  });
  const text = extractText(json);
  const parsed = tryParseJson(text);
  if (!parsed) throw new Error('OpenAI dataAnalysis 解析失败');
  return { ...parsed, groundingSources: [] };
}

module.exports = { meta: META, test, chat, analyze, ocr, tts, dataAnalysis };
