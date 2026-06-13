#!/usr/bin/env node
// Locale-aware provider display names (components/providerDisplay.ts). Run with
// `node scripts/test-provider-names.mjs` — Node (v23.6+) strips TS types natively when a .ts module is
// imported directly. Locks: en/ja/ko/fr carry NO Chinese/CJK residue; zh-CN/zh-TW keep the Chinese
// brand names (incl. the simplified vs traditional difference for qwen/glm).

import { getProviderDisplayName } from '../components/providerDisplay.ts';

const failures = [];
const check = (name, cond) => { if (cond) console.log(`  ✓ ${name}`); else { console.log(`  ✗ ${name}`); failures.push(name); } };
// CJK ideographs + kana + hangul — non-Chinese UI brand names must contain none of these.
const CJK = /[㐀-鿿぀-ヿ가-힯]/;

const IDS = ['anthropic', 'openai', 'gemini', 'deepseek', 'qwen', 'kimi', 'glm', 'doubao'];
const INTL_LANGS = ['en', 'ja', 'ko', 'fr'];
const EN = {
  anthropic: 'Claude · Anthropic', openai: 'ChatGPT · OpenAI', gemini: 'Gemini · Google',
  deepseek: 'DeepSeek', qwen: 'Qwen · Alibaba Cloud', kimi: 'Kimi · Moonshot AI',
  glm: 'GLM · Zhipu AI', doubao: 'Doubao · Volcano Engine',
};

console.log('\n=== Provider display names (i18n-aware) ===\n');

console.log('en/ja/ko/fr → no CJK residue + same English brand across the four:');
for (const id of IDS) {
  for (const lang of INTL_LANGS) {
    const n = getProviderDisplayName(id, lang);
    check(`${id} @ ${lang}: no CJK ("${n}")`, !!n && !CJK.test(n));
    check(`${id} @ ${lang}: == English brand`, n === EN[id]);
  }
}

console.log('zh-CN keeps the simplified Chinese brand:');
check('deepseek zh-CN', getProviderDisplayName('deepseek', 'zh-CN') === 'DeepSeek · 深度求索');
check('qwen zh-CN', getProviderDisplayName('qwen', 'zh-CN') === '通义千问 · 阿里云');
check('kimi zh-CN', getProviderDisplayName('kimi', 'zh-CN') === 'Kimi · 月之暗面');
check('glm zh-CN', getProviderDisplayName('glm', 'zh-CN') === 'GLM · 智谱 AI');
check('doubao zh-CN', getProviderDisplayName('doubao', 'zh-CN') === '豆包 · 火山方舟');
check('anthropic zh-CN unchanged', getProviderDisplayName('anthropic', 'zh-CN') === 'Claude · Anthropic');

console.log('zh-TW traditional where it differs (qwen/glm):');
check('qwen zh-TW', getProviderDisplayName('qwen', 'zh-TW') === '通義千問 · 阿里雲');
check('glm zh-TW', getProviderDisplayName('glm', 'zh-TW') === 'GLM · 智譜 AI');
check('deepseek zh-TW same as CN', getProviderDisplayName('deepseek', 'zh-TW') === 'DeepSeek · 深度求索');

console.log(`\n${failures.length === 0 ? '✓ all passed' : '✗ ' + failures.length + ' failed'}\n`);
process.exit(failures.length === 0 ? 0 : 1);
