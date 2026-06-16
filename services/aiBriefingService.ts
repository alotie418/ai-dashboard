// AI 简报服务（经营看板右侧）— 走 Electron IPC（api:request）统一通道
// 多 provider（Anthropic/OpenAI/Gemini）经 /api/ai/analyze 由主进程按默认 provider 分发。

import { AIAnalysis, BusinessData } from "../types";

async function aiApiFetch<T>(path: string, body: any): Promise<T> {
  const electronAPI = (window as any).electronAPI;
  return electronAPI.invoke('api:request', {
    method: 'POST',
    path,
    body,
  });
}

export const fetchAIAnalysis = async (data: BusinessData, marketSummary?: string, languageHint?: string, analyzeSystemPrompt?: string): Promise<AIAnalysis> => {
  const result = await aiApiFetch<any>('/api/ai/analyze', { data, marketSummary, languageHint, analyzeSystemPrompt });

  if (!result.summary || !Array.isArray(result.topInsights) || !Array.isArray(result.recommendations) || !Array.isArray(result.anomalies)) {
    throw new Error('AI 返回的数据格式不完整');
  }

  return result as AIAnalysis;
};
