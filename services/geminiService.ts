
import { GoogleGenAI, Type } from "@google/genai";
import { AI_SYSTEM_INSTRUCTION } from "../constants";
import { BusinessData, AIAnalysis } from "../types";
import { getApiKey } from "./apiKey";

export const fetchAIAnalysis = async (data: BusinessData): Promise<AIAnalysis> => {
  const ai = new GoogleGenAI({ apiKey: getApiKey() });
  
  try {
    const response = await ai.models.generateContent({
      model: "gemini-3-pro-preview",
      contents: `Analyze this business data and provide insights: ${JSON.stringify(data)}`,
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
