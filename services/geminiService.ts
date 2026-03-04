
import { GoogleGenAI, Type } from "@google/genai";
import { AI_SYSTEM_INSTRUCTION } from "../constants";
import { BusinessData, AIAnalysis } from "../types";
import { getApiKey } from "./apiKey";

export const fetchAIAnalysis = async (data: BusinessData, marketSummary?: string): Promise<AIAnalysis> => {
  const ai = new GoogleGenAI({ apiKey: getApiKey() });

  const marketContext = marketSummary
    ? `\n\n## 最新市场搜索数据\n${marketSummary}\n请将市场价格信息纳入分析，在建议中结合市场行情给出采购/销售策略。`
    : '';

  try {
    const response = await ai.models.generateContent({
      model: "gemini-3.1-flash-Lite-preview",
      contents: `Analyze this business data and provide insights: ${JSON.stringify(data)}${marketContext}`,
      config: {
        systemInstruction: AI_SYSTEM_INSTRUCTION,
        responseMimeType: "application/json",
        responseSchema: {
          type: Type.OBJECT,
          properties: {
            summary: { type: Type.STRING },
            topInsights: { type: Type.ARRAY, items: { type: Type.STRING } },
            recommendations: { type: Type.ARRAY, items: { type: Type.STRING } },
            anomalies: { type: Type.ARRAY, items: { type: Type.STRING } },
          },
          required: ["summary", "topInsights", "recommendations", "anomalies"],
        },
      },
    });

    let result: any;
    try {
      result = JSON.parse(response.text || '{}');
    } catch {
      throw new Error('AI 返回了无效的 JSON 格式');
    }

    // Validate required fields
    if (!result.summary || !Array.isArray(result.topInsights) || !Array.isArray(result.recommendations) || !Array.isArray(result.anomalies)) {
      throw new Error('AI 返回的数据格式不完整');
    }

    return result as AIAnalysis;
  } catch (error) {
    console.error("Failed to fetch AI analysis:", error);
    throw error;
  }
};
