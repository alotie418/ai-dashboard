// Gemini adapter — 用 @google/genai SDK（项目已装）

const { wrapNetworkError, normalizeCode, parseError } = require('./_error');

const LABEL = 'Gemini';

// SDK 抛错时尝试解析为统一格式（带稳定 code，渲染端按 code 映射 i18n）
function normalizeSdkError(err) {
  if (!err) return wrapNetworkError(new Error('Unknown Gemini error'), LABEL);
  const message = err?.message || String(err);
  // SDK 会在 message 里塞 HTTP status，例如 "[GoogleGenerativeAI Error]: 400 INVALID_ARGUMENT ..."
  const statusMatch = message.match(/\b(4\d\d|5\d\d)\b/);
  const status = statusMatch ? parseInt(statusMatch[1], 10) : 0;
  const code = normalizeCode(status, '', message);
  const e = new Error(`${LABEL}${status ? ' ' + status : ''} [${code}] (${message.slice(0, 200)})`);
  e.status = status;
  e.code = code;
  e.providerMessage = message;
  e.providerLabel = LABEL;
  return e;
}

const META = {
  id: 'gemini',
  name: 'Gemini (Google)',
  defaultModel: 'gemini-3.5-flash',
  availableModels: [
    { label: 'Gemini 3.5 Flash', value: 'gemini-3.5-flash' },
  ],
  capabilities: {
    ocr: true,
    tts: true,             // Gemini 唯一支持的 TTS provider
    webGrounding: true,    // Gemini 有 Google Search grounding
  },
};

let _genai = null;
async function loadSDK() {
  if (!_genai) _genai = await import('@google/genai');
  return _genai;
}

async function test(apiKey, model) {
  try {
    const { GoogleGenAI } = await loadSDK();
    const ai = new GoogleGenAI({ apiKey });
    const response = await ai.models.generateContent({
      model: model || META.defaultModel,
      contents: 'reply OK',
    });
    return { ok: !!response.text };
  } catch (e) {
    throw normalizeSdkError(e);
  }
}

async function chat(apiKey, model, { messages, systemInstruction }) {
  try {
    const { GoogleGenAI } = await loadSDK();
    const ai = new GoogleGenAI({ apiKey });
    const response = await ai.models.generateContent({
      model: model || META.defaultModel,
      contents: messages,
      config: {
        tools: [{ googleSearch: {} }],
        systemInstruction: systemInstruction || '',
      },
    });
    const text = response.candidates?.[0]?.content?.parts?.[0]?.text || response.text || '';
    return { text };
  } catch (e) {
    throw normalizeSdkError(e);
  }
}

// ── 工具调用方言（R2b-2b）──
const toGeminiFnDecl = (t) => ({ name: t.name, description: t.description, parameters: t.input_schema });

// 工具模式只放 functionDeclarations、绝不放 googleSearch（二者互斥）；空工具时整个省略 tools（兜底用）。
function buildGeminiConfig(system, tools) {
  const config = { systemInstruction: system || '' };
  if (tools && tools.length) config.tools = [{ functionDeclarations: tools.map(toGeminiFnDecl) }];
  return config;
}

// 渲染端 chatHistory 已是 Gemini contents 形（{role:'user'|'model', parts:[{text}]}）；兜底 assistant→model。
// 后续 functionCall / functionResponse turn 由 agent loop 原样追加，不再过本函数。
function toNativeHistory(messages) {
  return (messages || []).map(m => ({
    role: (m.role === 'model' || m.role === 'assistant') ? 'model' : (m.role || 'user'),
    parts: m.parts ? m.parts : [{ text: typeof m.content === 'string' ? m.content : '' }],
  })).filter(m => m.parts && m.parts.length);
}

// 纯解析：SDK response → 统一 step 形（离线测试直接喂构造的 response，规避 SDK mock）。
function parseGeminiResponse(response) {
  const parts = response?.candidates?.[0]?.content?.parts || [];
  const fnCalls = parts.filter(p => p.functionCall).map(p => p.functionCall);
  if (fnCalls.length) {
    return {
      type: 'tool_calls',
      assistantMsg: { role: 'model', parts },                                  // 单对象 → agent loop wrap 兼容
      calls: fnCalls.map(fc => ({ id: fc.name, name: fc.name, args: fc.args || {} })), // Gemini 无 id → 用 name
    };
  }
  return { type: 'final', text: response?.text || parts.map(p => p.text || '').join('') || '' };
}

async function chatWithTools(apiKey, model, { history, system, tools }) {
  try {
    const { GoogleGenAI } = await loadSDK();
    const ai = new GoogleGenAI({ apiKey });
    const response = await ai.models.generateContent({
      model: model || META.defaultModel,
      contents: history,
      config: buildGeminiConfig(system, tools),
    });
    return parseGeminiResponse(response);
  } catch (e) {
    throw normalizeSdkError(e);
  }
}

// 本轮所有工具结果合并成「单条」functionResponse user turn（response 必须是对象，数组/标量包一层）。
// role 用 'user'：与现有 contents（user/model）结构一致，且 @google/genai 当前版本以 'user' 携带
// functionResponse（落地按 SDK 版本核对；若该版本要求 'tool'/'function' 再调整并说明原因）。
function toToolResultsMsg(items) {
  return {
    role: 'user',
    parts: items.map(({ call, result }) => ({
      functionResponse: {
        name: call.name,
        response: (result && typeof result === 'object' && !Array.isArray(result)) ? result : { result },
      },
    })),
  };
}

async function analyze(apiKey, model, { data, marketSummary, languageHint, analyzeSystemPrompt }) {
  try {
    const { GoogleGenAI, Type } = await loadSDK();
    const ai = new GoogleGenAI({ apiKey });

    const marketContext = marketSummary
      ? `\n\n${marketSummary}`
      : '';

    const fallbackPrompt = `你是一位专业的商业分析师。请分析以下企业经营数据，给出：
1. summary: 一段简要的经营概况总结
2. topInsights: 3-5条关键洞察（数组）
3. recommendations: 3-5条改进建议（数组）
4. anomalies: 异常指标列表（数组）`;

    const systemInstruction = analyzeSystemPrompt || fallbackPrompt;

    const response = await ai.models.generateContent({
      model: model || META.defaultModel,
      contents: `Analyze this business data and provide insights: ${JSON.stringify(data)}${marketContext}`,
      config: {
        systemInstruction,
        responseMimeType: 'application/json',
        responseSchema: {
          type: Type.OBJECT,
          properties: {
            summary: { type: Type.STRING },
            topInsights: { type: Type.ARRAY, items: { type: Type.STRING } },
            recommendations: { type: Type.ARRAY, items: { type: Type.STRING } },
            anomalies: { type: Type.ARRAY, items: { type: Type.STRING } },
          },
          required: ['summary', 'topInsights', 'recommendations', 'anomalies'],
        },
      },
    });
    return JSON.parse(response.text || '{}');
  } catch (e) {
    throw normalizeSdkError(e);
  }
}

async function ocr(apiKey, model, { base64Data, mimeType, ocrPrompt }) {
  try {
    const { GoogleGenAI } = await loadSDK();
    const ai = new GoogleGenAI({ apiKey });
    const prompt = ocrPrompt || 'Extract invoice data as JSON.';

    const response = await ai.models.generateContent({
      model: model || META.defaultModel,
      contents: [{ parts: [{ text: prompt }, { inlineData: { data: base64Data, mimeType } }] }],
    });
    const text = response.text;
    if (!text) throw parseError(LABEL, 'OCR empty');
    const cleaned = text.replace(/^```(?:json)?\s*\n?/i, '').replace(/\n?```\s*$/i, '').trim();
    return JSON.parse(cleaned);
  } catch (e) {
    throw normalizeSdkError(e);
  }
}

async function tts(apiKey, _model, { text, voiceName }) {
  try {
    const { GoogleGenAI, Modality } = await loadSDK();
    const ai = new GoogleGenAI({ apiKey });
    const response = await ai.models.generateContent({
      model: 'gemini-2.5-flash-preview-tts', // TTS 专用模型
      contents: [{ parts: [{ text }] }],
      config: {
        responseModalities: [Modality.AUDIO],
        speechConfig: { voiceConfig: { prebuiltVoiceConfig: { voiceName: voiceName || 'Aoede' } } },
      },
    });
    const audioData = response.candidates?.[0]?.content?.parts?.[0]?.inlineData?.data;
    return { data: audioData || null };
  } catch (e) {
    throw normalizeSdkError(e);
  }
}

async function dataAnalysis(apiKey, model, { prompt, systemInstruction, responseSchema }) {
  try {
    const { GoogleGenAI } = await loadSDK();
    const ai = new GoogleGenAI({ apiKey });

    const response = await ai.models.generateContent({
      model: model || META.defaultModel,
      contents: prompt,
      config: {
        tools: [{ googleSearch: {} }],
        systemInstruction: systemInstruction || '',
        responseMimeType: 'application/json',
        responseSchema: responseSchema || undefined,
      },
    });

    const text = response.text || '{}';
    const result = JSON.parse(text);

    const chunks = response.candidates?.[0]?.groundingMetadata?.groundingChunks;
    const groundingSources = [];
    if (chunks) {
      for (const chunk of chunks) {
        if (chunk.web) {
          groundingSources.push({ title: chunk.web.title || 'Reference', uri: chunk.web.uri });
        }
      }
    }

    return { ...result, groundingSources };
  } catch (e) {
    throw normalizeSdkError(e);
  }
}

module.exports = { meta: META, test, chat, chatWithTools, toToolResultsMsg, toNativeHistory, parseGeminiResponse, buildGeminiConfig, analyze, ocr, tts, dataAnalysis };
