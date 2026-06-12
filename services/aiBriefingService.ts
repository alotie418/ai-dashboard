// AI 简报服务（经营看板右侧）— 走 apiFetch 统一通道（桌面版 IPC / Web 版 HTTP）
// 多 provider（Anthropic/OpenAI/Gemini）经 /api/ai/analyze 由主进程按默认 provider 分发。

import { AIAnalysis, BusinessData } from "../types";

const API_BASE = '';

function isElectron(): boolean {
  return typeof window !== 'undefined' && !!(window as any).electronAPI?.isElectron;
}

async function aiApiFetch<T>(path: string, body: any): Promise<T> {
  if (isElectron()) {
    const electronAPI = (window as any).electronAPI;
    return electronAPI.invoke('api:request', {
      method: 'POST',
      path,
      body,
    });
  }
  // Web 版 fallback
  const response = await fetch(`${API_BASE}${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    credentials: 'same-origin',
    body: JSON.stringify(body),
  });
  if (!response.ok) {
    const err = await response.json().catch(() => ({ error: 'Unknown error' }));
    throw new Error(err.error || `AI request failed (${response.status})`);
  }
  return response.json();
}

export const fetchAIAnalysis = async (data: BusinessData, marketSummary?: string, languageHint?: string, analyzeSystemPrompt?: string): Promise<AIAnalysis> => {
  const result = await aiApiFetch<any>('/api/ai/analyze', { data, marketSummary, languageHint, analyzeSystemPrompt });

  if (!result.summary || !Array.isArray(result.topInsights) || !Array.isArray(result.recommendations) || !Array.isArray(result.anomalies)) {
    throw new Error('AI 返回的数据格式不完整');
  }

  return result as AIAnalysis;
};
