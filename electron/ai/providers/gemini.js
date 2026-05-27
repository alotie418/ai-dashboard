// Gemini adapter — 用 @google/genai SDK（项目已装）

const { wrapNetworkError } = require('./_error');

const LABEL = 'Gemini';

// SDK 抛错时尝试解析为统一格式
function normalizeSdkError(err) {
  if (!err) return wrapNetworkError(new Error('Unknown Gemini error'), LABEL);
  const message = err?.message || String(err);
  // SDK 会在 message 里塞 HTTP status，例如 "[GoogleGenerativeAI Error]: 400 INVALID_ARGUMENT ..."
  const statusMatch = message.match(/\b(4\d\d|5\d\d)\b/);
  const status = statusMatch ? parseInt(statusMatch[1], 10) : 0;
  const lower = message.toLowerCase();
  let friendly = '';
  if (status === 401 || /api[_ ]?key.*invalid|unauthorized/.test(lower)) {
    friendly = 'API Key 无效或已过期';
  } else if (status === 403 || /permission|forbidden/.test(lower)) {
    friendly = '没有访问该模型的权限，可能需要开通 Google AI Studio 或加入白名单';
  } else if (status === 429 || /quota|rate.?limit|exceeded/.test(lower)) {
    friendly = '请求超限或额度耗尽';
  } else if (status === 404 || /model.*not.*found|not.*supported/.test(lower)) {
    friendly = '模型 ID 不存在或不可用，请在设置页改成可用 ID';
  } else if (status >= 500) {
    friendly = '服务商接口异常，请稍后重试';
  }
  const e = new Error(`${LABEL}${status ? ' ' + status : ''}${friendly ? ' — ' + friendly : ''} (${message.slice(0, 200)})`);
  e.status = status;
  e.code = statusMatch ? `http_${status}` : 'gemini_error';
  e.providerMessage = message;
  e.friendly = friendly;
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
    if (!text) throw new Error('Gemini OCR 返回为空');
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

module.exports = { meta: META, test, chat, analyze, ocr, tts, dataAnalysis };
