import type { AIProviderId } from '../types';

// Locale-aware DISPLAY name for AI providers (BYOK cards + onboarding). Brand names are constants
// (not translatable copy), so they live here instead of the locale JSON. Rule by UI language:
//   zh-CN → 简体中文 brand；zh-TW → 繁体中文 brand；every other UI lang (en / ja / ko / fr) → the
//   English brand name (so non-Chinese UIs never show Chinese residue). Separator is the existing
//   " · " style. Display-only: this never touches provider id / model id / PROVIDER_DOCS config.
const NAMES: Record<AIProviderId, { 'zh-CN': string; 'zh-TW': string; intl: string }> = {
  anthropic: { 'zh-CN': 'Claude · Anthropic', 'zh-TW': 'Claude · Anthropic', intl: 'Claude · Anthropic' },
  openai:    { 'zh-CN': 'ChatGPT · OpenAI',   'zh-TW': 'ChatGPT · OpenAI',   intl: 'ChatGPT · OpenAI' },
  gemini:    { 'zh-CN': 'Gemini · Google',    'zh-TW': 'Gemini · Google',    intl: 'Gemini · Google' },
  deepseek:  { 'zh-CN': 'DeepSeek · 深度求索', 'zh-TW': 'DeepSeek · 深度求索', intl: 'DeepSeek' },
  qwen:      { 'zh-CN': '通义千问 · 阿里云',    'zh-TW': '通義千問 · 阿里雲',    intl: 'Qwen · Alibaba Cloud' },
  kimi:      { 'zh-CN': 'Kimi · 月之暗面',     'zh-TW': 'Kimi · 月之暗面',     intl: 'Kimi · Moonshot AI' },
  glm:       { 'zh-CN': 'GLM · 智谱 AI',      'zh-TW': 'GLM · 智譜 AI',      intl: 'GLM · Zhipu AI' },
  doubao:    { 'zh-CN': '豆包 · 火山方舟',     'zh-TW': '豆包 · 火山方舟',     intl: 'Doubao · Volcano Engine' },
};

export function getProviderDisplayName(id: AIProviderId, uiLang: string): string {
  const n = NAMES[id];
  if (!n) return id;
  if (uiLang === 'zh-TW') return n['zh-TW'];
  if (uiLang.startsWith('zh')) return n['zh-CN']; // zh-CN / zh / zh-Hans → simplified
  return n.intl;                                  // en / ja / ko / fr → English brand (no Chinese residue)
}
