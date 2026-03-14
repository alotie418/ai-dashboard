
import { AIAnalysis, BusinessData } from "../types";

export const fetchAIAnalysis = async (data: BusinessData, marketSummary?: string): Promise<AIAnalysis> => {
  const response = await fetch('/api/ai/analyze', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    credentials: 'same-origin',
    body: JSON.stringify({ data, marketSummary }),
  });

  if (!response.ok) {
    const err = await response.json().catch(() => ({ error: 'Unknown error' }));
    throw new Error(err.error || `AI analysis failed (${response.status})`);
  }

  const result = await response.json();

  if (!result.summary || !Array.isArray(result.topInsights) || !Array.isArray(result.recommendations) || !Array.isArray(result.anomalies)) {
    throw new Error('AI 返回的数据格式不完整');
  }

  return result as AIAnalysis;
};
