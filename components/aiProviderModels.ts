// AI Provider 模型白名单 — 前端权威数据源
//
// 为什么前端要再列一份（而不是只用主进程 META）：
//   1. 主进程 require() 有缓存，改 META 后必须完全重启 Electron 才能生效，
//      但开发期 Vite HMR 不会重启 main 进程，容易看到陈旧数据
//   2. 任何时候 UI chip 显示的都必须是这个白名单，与主进程的 IPC 响应解耦
//   3. 主进程 META 仍然存在（电话 API 调用走它），但 UI 列表不被其污染
//
// 维护规则：新增/替换模型时同步两处 —— 本文件 + electron/ai/providers/*.js
// 旧 model ID 仅出现在 electron/ai/index.js 的 MODEL_MIGRATION_MAP

import type { AIProviderId, ModelOption } from '../types';

export const KNOWN_MODELS: Record<AIProviderId, ModelOption[]> = {
  anthropic: [
    { label: 'Claude Sonnet 4.6', value: 'claude-sonnet-4-6' },
    { label: 'Claude Opus 4.7', value: 'claude-opus-4-7' },
  ],
  openai: [
    { label: 'ChatGPT 5.5', value: 'gpt-5.5' },
  ],
  gemini: [
    { label: 'Gemini 3.5 Flash', value: 'gemini-3.5-flash' },
  ],
  deepseek: [
    { label: 'DeepSeek V4 Pro', value: 'deepseek-v4-pro' },
    { label: 'DeepSeek V4 Flash', value: 'deepseek-v4-flash' },
    { label: 'DeepSeek Chat (兼容旧版，将弃用 2026-07)', value: 'deepseek-chat' },
  ],
  qwen: [
    { label: 'Qwen Plus', value: 'qwen-plus' },
    { label: 'Qwen Max', value: 'qwen-max' },
    { label: 'Qwen Flash', value: 'qwen-flash' },
    { label: 'Qwen Turbo (兼容旧版)', value: 'qwen-turbo' },
  ],
  kimi: [
    { label: 'Kimi K2.6', value: 'kimi-k2.6' },
    { label: 'Kimi K2.5', value: 'kimi-k2.5' },
    { label: 'Moonshot v1 128K', value: 'moonshot-v1-128k' },
    { label: 'Moonshot v1 32K (兼容旧版)', value: 'moonshot-v1-32k' },
  ],
};

export const DEFAULT_MODEL: Record<AIProviderId, string> = {
  anthropic: 'claude-sonnet-4-6',
  openai: 'gpt-5.5',
  gemini: 'gemini-3.5-flash',
  deepseek: 'deepseek-v4-pro',
  qwen: 'qwen-plus',
  kimi: 'kimi-k2.6',
};

// 给定 provider + model value，返回 ModelOption；找不到说明是用户自定义 ID
export function findModelOption(provider: AIProviderId, value: string): ModelOption | null {
  return KNOWN_MODELS[provider]?.find(m => m.value === value) || null;
}

// 给定 provider + model value，返回展示用 label（自定义时附带"自定义"标记）
export function modelLabelFor(provider: AIProviderId, value: string): string {
  const matched = findModelOption(provider, value);
  return matched ? matched.label : `${value || '(未选)'} · 自定义`;
}

// 旧 model ID → 新 model ID，与 electron/ai/index.js 的 MODEL_MIGRATION_MAP 保持同步
// 前端用于"启动后兜底迁移"：即使主进程没重启来不及跑 migrateOldModels，前端也能纠正
export const FRONTEND_MIGRATION_MAP: Record<string, string> = {
  // Gemini
  'gemini-2.0-flash': 'gemini-3.5-flash',
  'gemini-1.5-flash': 'gemini-3.5-flash',
  'gemini-1.5-pro': 'gemini-3.5-flash',
  // Anthropic
  'claude-3-5-sonnet-latest': 'claude-sonnet-4-6',
  'claude-sonnet-4-5': 'claude-sonnet-4-6',
  'claude-opus-4-5': 'claude-opus-4-7',
  'claude-haiku-4-5': 'claude-sonnet-4-6',
  // OpenAI
  'gpt-4o': 'gpt-5.5',
  'gpt-4o-mini': 'gpt-5.5',
  'gpt-4.1': 'gpt-5.5',
  'gpt-4.1-mini': 'gpt-5.5',
};

export function shouldAutoMigrate(modelId: string): string | null {
  return FRONTEND_MIGRATION_MAP[modelId] || null;
}
