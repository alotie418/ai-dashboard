#!/usr/bin/env node
// Offline provider tool-calling round-trip test (R2b-2a: Anthropic + OpenAI).
//
// Each adapter calls fetch() directly (anthropic via callMessages, openai via callResponses),
// so we stub globalThis.fetch to feed crafted provider responses and capture request bodies —
// no network, no API key. Verifies each adapter's chatWithTools / toToolResultMsg dialect
// translation (parse tool calls → build tool result → final answer) + the empty-tools omission
// that the agent loop's over-rounds fallback relies on. Gemini is added in R2b-2b.

import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);

const anthropic = require('../electron/ai/providers/anthropic.js');
const openai = require('../electron/ai/providers/openai.js');
const gemini = require('../electron/ai/providers/gemini.js'); // pure functions only (SDK loaded lazily, never hit here)
const deepseek = require('../electron/ai/providers/deepseek.js'); // OpenAI Chat-Completions compatible (fetch-only)
const qwen = require('../electron/ai/providers/qwen.js'); // OpenAI Chat-Completions compatible (fetch-only)
const kimi = require('../electron/ai/providers/kimi.js'); // OpenAI Chat-Completions compatible (fetch-only)
const glm = require('../electron/ai/providers/glm.js'); // OpenAI Chat-Completions compatible (fetch-only)
const doubao = require('../electron/ai/providers/doubao.js'); // OpenAI Chat-Completions compatible (fetch-only)
const { pickOcrProvider } = require('../electron/ai/ocrSelect.js'); // PR-3b OCR provider selection (pure)

const failures = [];
function check(name, cond, detail) {
  if (cond) console.log(`  ✓ ${name}`);
  else { console.log(`  ✗ ${name}${detail ? ' — ' + detail : ''}`); failures.push(name); }
}

// Sequenced fetch stub: returns queued responses in order, captures each request JSON body.
let _queue = [];
let _bodies = [];
function setFetch(responses) {
  _queue = [...responses];
  _bodies = [];
  globalThis.fetch = async (_url, opts) => {
    try { _bodies.push(opts && opts.body ? JSON.parse(opts.body) : null); } catch { _bodies.push(null); }
    const json = _queue.shift();
    return { ok: true, status: 200, json: async () => json };
  };
}

const TOOLDEFS = [{ name: 'get_sales', description: 'sales', input_schema: { type: 'object', properties: {} } }];
const seed = (p) => p.toNativeHistory([{ role: 'user', parts: [{ text: '今年销售额?' }] }]);

async function testAnthropic() {
  console.log('Anthropic:');
  const toolResp = { stop_reason: 'tool_use', content: [{ type: 'text', text: 'checking' }, { type: 'tool_use', id: 'tu_1', name: 'get_sales', input: {} }] };
  const finalResp = { stop_reason: 'end_turn', content: [{ type: 'text', text: 'Sales total is 100' }] };

  setFetch([toolResp]);
  const s1 = await anthropic.chatWithTools('k', 'm', { history: seed(anthropic), system: 'sys', tools: TOOLDEFS });
  check('anthropic round1 type=tool_calls', s1.type === 'tool_calls', JSON.stringify(s1));
  check('anthropic round1 call parsed', !!(s1.calls && s1.calls[0] && s1.calls[0].id === 'tu_1' && s1.calls[0].name === 'get_sales'));
  check('anthropic round1 assistantMsg single assistant turn', !!(s1.assistantMsg && s1.assistantMsg.role === 'assistant' && Array.isArray(s1.assistantMsg.content)));
  check('anthropic round1 request carried tools', Array.isArray(_bodies[0].tools) && _bodies[0].tools.length === 1 && _bodies[0].tools[0].name === 'get_sales');

  const tr = anthropic.toToolResultsMsg([{ call: s1.calls[0], result: { rows: [1, 2] } }]);
  check('anthropic toToolResultsMsg single shape', tr.role === 'user' && tr.content.length === 1 && tr.content[0].type === 'tool_result' && tr.content[0].tool_use_id === 'tu_1' && tr.content[0].content === JSON.stringify({ rows: [1, 2] }));
  const trM = anthropic.toToolResultsMsg([{ call: { id: 'tu_1' }, result: { x: 1 } }, { call: { id: 'tu_2' }, result: { y: 2 } }]);
  check('anthropic multi-tool batched into single user turn', trM.role === 'user' && trM.content.length === 2 && trM.content[0].tool_use_id === 'tu_1' && trM.content[1].tool_use_id === 'tu_2');

  setFetch([finalResp]);
  const s2 = await anthropic.chatWithTools('k', 'm', { history: seed(anthropic), system: 'sys', tools: TOOLDEFS });
  check('anthropic round2 type=final + text', s2.type === 'final' && s2.text === 'Sales total is 100', JSON.stringify(s2));

  setFetch([finalResp]);
  await anthropic.chatWithTools('k', 'm', { history: seed(anthropic), system: 'sys', tools: [] });
  check('anthropic empty tools omits tools field', !('tools' in _bodies[0]), JSON.stringify(_bodies[0]));
}

async function testOpenAI() {
  console.log('OpenAI:');
  const toolResp = { output: [{ type: 'reasoning', id: 'rs_1' }, { type: 'function_call', id: 'fc_1', call_id: 'call_1', name: 'get_sales', arguments: '{}' }] };
  const finalResp = { output_text: 'Sales total is 100', output: [{ type: 'message', role: 'assistant', content: [{ type: 'output_text', text: 'Sales total is 100' }] }] };

  setFetch([toolResp]);
  const s1 = await openai.chatWithTools('k', 'm', { history: seed(openai), system: 'sys', tools: TOOLDEFS });
  check('openai round1 type=tool_calls', s1.type === 'tool_calls', JSON.stringify(s1));
  check('openai round1 call parsed (call_id + args object)', !!(s1.calls && s1.calls[0] && s1.calls[0].id === 'call_1' && s1.calls[0].name === 'get_sales' && typeof s1.calls[0].args === 'object'));
  check('openai round1 assistantMsg = function_call items only (reasoning dropped)', Array.isArray(s1.assistantMsg) && s1.assistantMsg.length === 1 && s1.assistantMsg[0].type === 'function_call');
  check('openai round1 request carried flat function tools', Array.isArray(_bodies[0].tools) && _bodies[0].tools[0].type === 'function' && _bodies[0].tools[0].name === 'get_sales');

  const tr = openai.toToolResultsMsg([{ call: s1.calls[0], result: { rows: [1, 2] } }]);
  check('openai toToolResultsMsg single shape', Array.isArray(tr) && tr.length === 1 && tr[0].type === 'function_call_output' && tr[0].call_id === 'call_1' && tr[0].output === JSON.stringify({ rows: [1, 2] }));
  const trM = openai.toToolResultsMsg([{ call: { id: 'c1' }, result: {} }, { call: { id: 'c2' }, result: {} }]);
  check('openai multi-tool = array of 2 function_call_output', Array.isArray(trM) && trM.length === 2 && trM[0].call_id === 'c1' && trM[1].call_id === 'c2');

  setFetch([finalResp]);
  const s2 = await openai.chatWithTools('k', 'm', { history: seed(openai), system: 'sys', tools: TOOLDEFS });
  check('openai round2 type=final + text', s2.type === 'final' && s2.text === 'Sales total is 100', JSON.stringify(s2));

  setFetch([finalResp]);
  await openai.chatWithTools('k', 'm', { history: seed(openai), system: 'sys', tools: [] });
  check('openai empty tools omits tools field', !('tools' in _bodies[0]), JSON.stringify(_bodies[0]));
}

// DeepSeek = OpenAI **Chat Completions** dialect (via the shared _openaiCompatible factory):
// tools[].function, choices[0].message.tool_calls (arguments JSON-string), role:'tool' results.
// Distinct from OpenAI's Responses API above. Stub fetch with crafted chat-completions JSON.
async function testDeepSeek() {
  console.log('DeepSeek (Chat Completions):');
  // META smoke (registry parity is covered by check:providers; here we lock the adapter shape)
  check('deepseek meta id + default model', deepseek.meta.id === 'deepseek' && deepseek.meta.defaultModel === 'deepseek-v4-pro');
  check('deepseek default model in availableModels', deepseek.meta.availableModels.some(m => m.value === 'deepseek-v4-pro'));
  check('deepseek whitelist has v4-pro / v4-flash / chat(compat)',
    ['deepseek-v4-pro', 'deepseek-v4-flash', 'deepseek-chat'].every(v => deepseek.meta.availableModels.some(m => m.value === v)));
  check('deepseek capabilities text-only (no tts/ocr/webGrounding)',
    deepseek.meta.capabilities.tts === false && deepseek.meta.capabilities.ocr === false && deepseek.meta.capabilities.webGrounding === false);

  const toolResp = { choices: [{ message: { role: 'assistant', content: null, tool_calls: [{ id: 'call_1', type: 'function', function: { name: 'get_sales', arguments: '{}' } }] } }] };
  const finalResp = { choices: [{ message: { role: 'assistant', content: 'Sales total is 100' } }] };

  setFetch([toolResp]);
  const s1 = await deepseek.chatWithTools('k', 'm', { history: seed(deepseek), system: 'sys', tools: TOOLDEFS });
  check('deepseek round1 type=tool_calls', s1.type === 'tool_calls', JSON.stringify(s1));
  check('deepseek round1 call parsed (id + name + args object)', !!(s1.calls && s1.calls[0] && s1.calls[0].id === 'call_1' && s1.calls[0].name === 'get_sales' && typeof s1.calls[0].args === 'object'));
  check('deepseek round1 assistantMsg single assistant turn w/ tool_calls', !!(s1.assistantMsg && s1.assistantMsg.role === 'assistant' && Array.isArray(s1.assistantMsg.tool_calls) && s1.assistantMsg.tool_calls.length === 1));
  check('deepseek round1 request carried nested function tools + tool_choice', Array.isArray(_bodies[0].tools) && _bodies[0].tools[0].type === 'function' && _bodies[0].tools[0].function.name === 'get_sales' && _bodies[0].tool_choice === 'auto');
  check('deepseek round1 system prepended as first message', _bodies[0].messages[0].role === 'system' && _bodies[0].messages[0].content === 'sys');

  const tr = deepseek.toToolResultsMsg([{ call: s1.calls[0], result: { rows: [1, 2] } }]);
  check('deepseek toToolResultsMsg single shape', Array.isArray(tr) && tr.length === 1 && tr[0].role === 'tool' && tr[0].tool_call_id === 'call_1' && tr[0].content === JSON.stringify({ rows: [1, 2] }));
  const trM = deepseek.toToolResultsMsg([{ call: { id: 'c1' }, result: {} }, { call: { id: 'c2' }, result: {} }]);
  check('deepseek multi-tool = array of 2 role:tool messages', Array.isArray(trM) && trM.length === 2 && trM[0].tool_call_id === 'c1' && trM[1].tool_call_id === 'c2');

  setFetch([finalResp]);
  const s2 = await deepseek.chatWithTools('k', 'm', { history: seed(deepseek), system: 'sys', tools: TOOLDEFS });
  check('deepseek round2 type=final + text', s2.type === 'final' && s2.text === 'Sales total is 100', JSON.stringify(s2));

  setFetch([finalResp]);
  await deepseek.chatWithTools('k', 'm', { history: seed(deepseek), system: 'sys', tools: [] });
  check('deepseek empty tools omits tools field', !('tools' in _bodies[0]), JSON.stringify(_bodies[0]));
}

// Qwen = OpenAI **Chat Completions** dialect (via the shared _openaiCompatible factory), same wire
// shape as DeepSeek. baseURL keeps the /compatible-mode/v1 path; whitelist is thinking-OFF models so
// the non-streaming factory works without an enable_thinking param. Stub fetch with chat-completions JSON.
async function testQwen() {
  console.log('Qwen (Chat Completions):');
  // META smoke (registry parity is covered by check:providers; here we lock the adapter shape)
  check('qwen meta id + default model', qwen.meta.id === 'qwen' && qwen.meta.defaultModel === 'qwen-plus');
  check('qwen default model in availableModels', qwen.meta.availableModels.some(m => m.value === 'qwen-plus'));
  check('qwen whitelist has plus / max / flash / turbo(compat)',
    ['qwen-plus', 'qwen-max', 'qwen-flash', 'qwen-turbo'].every(v => qwen.meta.availableModels.some(m => m.value === v)));
  check('qwen capabilities: ocr=true (vision OCR) but no tts/webGrounding',
    qwen.meta.capabilities.tts === false && qwen.meta.capabilities.ocr === true && qwen.meta.capabilities.webGrounding === false);

  const toolResp = { choices: [{ message: { role: 'assistant', content: null, tool_calls: [{ id: 'call_1', type: 'function', function: { name: 'get_sales', arguments: '{}' } }] } }] };
  const finalResp = { choices: [{ message: { role: 'assistant', content: 'Sales total is 100' } }] };

  setFetch([toolResp]);
  const s1 = await qwen.chatWithTools('k', 'm', { history: seed(qwen), system: 'sys', tools: TOOLDEFS });
  check('qwen round1 type=tool_calls', s1.type === 'tool_calls', JSON.stringify(s1));
  check('qwen round1 call parsed (id + name + args object)', !!(s1.calls && s1.calls[0] && s1.calls[0].id === 'call_1' && s1.calls[0].name === 'get_sales' && typeof s1.calls[0].args === 'object'));
  check('qwen round1 assistantMsg single assistant turn w/ tool_calls', !!(s1.assistantMsg && s1.assistantMsg.role === 'assistant' && Array.isArray(s1.assistantMsg.tool_calls) && s1.assistantMsg.tool_calls.length === 1));
  check('qwen round1 request carried nested function tools + tool_choice', Array.isArray(_bodies[0].tools) && _bodies[0].tools[0].type === 'function' && _bodies[0].tools[0].function.name === 'get_sales' && _bodies[0].tool_choice === 'auto');
  check('qwen body has no reasoning_effort (extraBody not leaked to other providers)', !('reasoning_effort' in _bodies[0]));
  check('qwen round1 system prepended as first message', _bodies[0].messages[0].role === 'system' && _bodies[0].messages[0].content === 'sys');

  const tr = qwen.toToolResultsMsg([{ call: s1.calls[0], result: { rows: [1, 2] } }]);
  check('qwen toToolResultsMsg single shape', Array.isArray(tr) && tr.length === 1 && tr[0].role === 'tool' && tr[0].tool_call_id === 'call_1' && tr[0].content === JSON.stringify({ rows: [1, 2] }));
  const trM = qwen.toToolResultsMsg([{ call: { id: 'c1' }, result: {} }, { call: { id: 'c2' }, result: {} }]);
  check('qwen multi-tool = array of 2 role:tool messages', Array.isArray(trM) && trM.length === 2 && trM[0].tool_call_id === 'c1' && trM[1].tool_call_id === 'c2');

  setFetch([finalResp]);
  const s2 = await qwen.chatWithTools('k', 'm', { history: seed(qwen), system: 'sys', tools: TOOLDEFS });
  check('qwen round2 type=final + text', s2.type === 'final' && s2.text === 'Sales total is 100', JSON.stringify(s2));

  setFetch([finalResp]);
  await qwen.chatWithTools('k', 'm', { history: seed(qwen), system: 'sys', tools: [] });
  check('qwen empty tools omits tools field', !('tools' in _bodies[0]), JSON.stringify(_bodies[0]));
}

// Kimi = OpenAI **Chat Completions** dialect (via the shared _openaiCompatible factory), same wire
// shape as DeepSeek/Qwen. baseURL keeps the /v1 path; default kimi-k2.6. Stub fetch with chat-
// completions JSON. (Kimi rejects tool_choice:'required'; the factory uses 'auto', asserted below.)
async function testKimi() {
  console.log('Kimi (Chat Completions):');
  // META smoke (registry parity is covered by check:providers; here we lock the adapter shape)
  check('kimi meta id + default model', kimi.meta.id === 'kimi' && kimi.meta.defaultModel === 'kimi-k2.6');
  check('kimi default model in availableModels', kimi.meta.availableModels.some(m => m.value === 'kimi-k2.6'));
  check('kimi whitelist has k2.6 / k2.5 / v1-128k / v1-32k(compat)',
    ['kimi-k2.6', 'kimi-k2.5', 'moonshot-v1-128k', 'moonshot-v1-32k'].every(v => kimi.meta.availableModels.some(m => m.value === v)));
  check('kimi capabilities: ocr=true (vision) + visionModel set, no tts/webGrounding',
    kimi.meta.capabilities.tts === false && kimi.meta.capabilities.ocr === true && kimi.meta.capabilities.webGrounding === false && kimi.meta.visionModel === 'moonshot-v1-32k-vision-preview');

  const toolResp = { choices: [{ message: { role: 'assistant', content: null, tool_calls: [{ id: 'call_1', type: 'function', function: { name: 'get_sales', arguments: '{}' } }] } }] };
  const finalResp = { choices: [{ message: { role: 'assistant', content: 'Sales total is 100' } }] };

  setFetch([toolResp]);
  const s1 = await kimi.chatWithTools('k', 'm', { history: seed(kimi), system: 'sys', tools: TOOLDEFS });
  check('kimi round1 type=tool_calls', s1.type === 'tool_calls', JSON.stringify(s1));
  check('kimi round1 call parsed (id + name + args object)', !!(s1.calls && s1.calls[0] && s1.calls[0].id === 'call_1' && s1.calls[0].name === 'get_sales' && typeof s1.calls[0].args === 'object'));
  check('kimi round1 assistantMsg single assistant turn w/ tool_calls', !!(s1.assistantMsg && s1.assistantMsg.role === 'assistant' && Array.isArray(s1.assistantMsg.tool_calls) && s1.assistantMsg.tool_calls.length === 1));
  check('kimi round1 request carried nested function tools + tool_choice=auto (not required)', Array.isArray(_bodies[0].tools) && _bodies[0].tools[0].type === 'function' && _bodies[0].tools[0].function.name === 'get_sales' && _bodies[0].tool_choice === 'auto');
  check('kimi round1 system prepended as first message', _bodies[0].messages[0].role === 'system' && _bodies[0].messages[0].content === 'sys');

  const tr = kimi.toToolResultsMsg([{ call: s1.calls[0], result: { rows: [1, 2] } }]);
  check('kimi toToolResultsMsg single shape', Array.isArray(tr) && tr.length === 1 && tr[0].role === 'tool' && tr[0].tool_call_id === 'call_1' && tr[0].content === JSON.stringify({ rows: [1, 2] }));
  const trM = kimi.toToolResultsMsg([{ call: { id: 'c1' }, result: {} }, { call: { id: 'c2' }, result: {} }]);
  check('kimi multi-tool = array of 2 role:tool messages', Array.isArray(trM) && trM.length === 2 && trM[0].tool_call_id === 'c1' && trM[1].tool_call_id === 'c2');

  setFetch([finalResp]);
  const s2 = await kimi.chatWithTools('k', 'm', { history: seed(kimi), system: 'sys', tools: TOOLDEFS });
  check('kimi round2 type=final + text', s2.type === 'final' && s2.text === 'Sales total is 100', JSON.stringify(s2));

  setFetch([finalResp]);
  await kimi.chatWithTools('k', 'm', { history: seed(kimi), system: 'sys', tools: [] });
  check('kimi empty tools omits tools field', !('tools' in _bodies[0]), JSON.stringify(_bodies[0]));
}

// GLM = OpenAI **Chat Completions** dialect (via the shared _openaiCompatible factory), same wire
// shape as DeepSeek/Qwen/Kimi. baseURL keeps the /api/paas/v4 path (not a bare /v1); default
// glm-4.6. Stub fetch with chat-completions JSON.
async function testGLM() {
  console.log('GLM (Chat Completions):');
  // META smoke (registry parity is covered by check:providers; here we lock the adapter shape)
  check('glm meta id + default model', glm.meta.id === 'glm' && glm.meta.defaultModel === 'glm-4.6');
  check('glm default model in availableModels', glm.meta.availableModels.some(m => m.value === 'glm-4.6'));
  check('glm whitelist has 4.6 / 5.1 / 4.5-air / 4.7-flash',
    ['glm-4.6', 'glm-5.1', 'glm-4.5-air', 'glm-4.7-flash'].every(v => glm.meta.availableModels.some(m => m.value === v)));
  check('glm capabilities: ocr=true (vision) + visionModel=glm-4.6v, no tts/webGrounding',
    glm.meta.capabilities.tts === false && glm.meta.capabilities.ocr === true && glm.meta.capabilities.webGrounding === false && glm.meta.visionModel === 'glm-4.6v');

  const toolResp = { choices: [{ message: { role: 'assistant', content: null, tool_calls: [{ id: 'call_1', type: 'function', function: { name: 'get_sales', arguments: '{}' } }] } }] };
  const finalResp = { choices: [{ message: { role: 'assistant', content: 'Sales total is 100' } }] };

  setFetch([toolResp]);
  const s1 = await glm.chatWithTools('k', 'm', { history: seed(glm), system: 'sys', tools: TOOLDEFS });
  check('glm round1 type=tool_calls', s1.type === 'tool_calls', JSON.stringify(s1));
  check('glm round1 call parsed (id + name + args object)', !!(s1.calls && s1.calls[0] && s1.calls[0].id === 'call_1' && s1.calls[0].name === 'get_sales' && typeof s1.calls[0].args === 'object'));
  check('glm round1 assistantMsg single assistant turn w/ tool_calls', !!(s1.assistantMsg && s1.assistantMsg.role === 'assistant' && Array.isArray(s1.assistantMsg.tool_calls) && s1.assistantMsg.tool_calls.length === 1));
  check('glm round1 request carried nested function tools + tool_choice', Array.isArray(_bodies[0].tools) && _bodies[0].tools[0].type === 'function' && _bodies[0].tools[0].function.name === 'get_sales' && _bodies[0].tool_choice === 'auto');
  check('glm round1 system prepended as first message', _bodies[0].messages[0].role === 'system' && _bodies[0].messages[0].content === 'sys');

  const tr = glm.toToolResultsMsg([{ call: s1.calls[0], result: { rows: [1, 2] } }]);
  check('glm toToolResultsMsg single shape', Array.isArray(tr) && tr.length === 1 && tr[0].role === 'tool' && tr[0].tool_call_id === 'call_1' && tr[0].content === JSON.stringify({ rows: [1, 2] }));
  const trM = glm.toToolResultsMsg([{ call: { id: 'c1' }, result: {} }, { call: { id: 'c2' }, result: {} }]);
  check('glm multi-tool = array of 2 role:tool messages', Array.isArray(trM) && trM.length === 2 && trM[0].tool_call_id === 'c1' && trM[1].tool_call_id === 'c2');

  setFetch([finalResp]);
  const s2 = await glm.chatWithTools('k', 'm', { history: seed(glm), system: 'sys', tools: TOOLDEFS });
  check('glm round2 type=final + text', s2.type === 'final' && s2.text === 'Sales total is 100', JSON.stringify(s2));

  setFetch([finalResp]);
  await glm.chatWithTools('k', 'm', { history: seed(glm), system: 'sys', tools: [] });
  check('glm empty tools omits tools field', !('tools' in _bodies[0]), JSON.stringify(_bodies[0]));
}

// PR-3b: Qwen vision OCR over the SAME Chat Completions endpoint (image_url content block, base64
// data URL). The vision model is always visionModel (qwen-vl-max), NOT the passed chat model. A
// text-only factory provider (DeepSeek, no visionModel) must still refuse OCR with a stable code.
async function testQwenVisionOCR() {
  console.log('Qwen Vision OCR (Chat Completions image_url):');
  check('qwen capabilities.ocr=true + visionModel=qwen-vl-max',
    qwen.meta.capabilities.ocr === true && qwen.meta.visionModel === 'qwen-vl-max');
  const ocrResp = { choices: [{ message: { role: 'assistant', content: '{"isInvoiceLike":true,"sellerName":"ACME","grossAmount":1130}' } }] };
  setFetch([ocrResp]);
  const out = await qwen.ocr('k', 'qwen-plus', { base64Data: 'AAAA', mimeType: 'image/png', ocrPrompt: 'extract invoice' });
  check('qwen ocr returns parsed JSON', !!(out && out.isInvoiceLike === true && out.sellerName === 'ACME'));
  const body = _bodies[0];
  check('qwen ocr uses visionModel (not the passed chat model)', body.model === 'qwen-vl-max');
  const content = body.messages[0].content;
  check('qwen ocr request carries text + image_url(base64 data URL) blocks',
    Array.isArray(content)
    && content.some(c => c.type === 'text' && c.text === 'extract invoice')
    && content.some(c => c.type === 'image_url' && c.image_url && c.image_url.url === 'data:image/png;base64,AAAA'));
  let code = null;
  try { await deepseek.ocr('k', 'm', { base64Data: 'x', mimeType: 'image/png', ocrPrompt: 'p' }); }
  catch (e) { code = e.code; }
  check('deepseek ocr still throws badRequest (text provider unaffected)', code === 'badRequest');
}

// PR-3b: OCR provider selection (pure). Default-if-OCR-capable, else priority fallback, else null.
function testOcrProviderSelection() {
  console.log('OCR provider selection (pickOcrProvider):');
  check('default OCR-capable → default', pickOcrProvider([
    { provider: 'deepseek', isDefault: false, ocrCapable: false },
    { provider: 'qwen', isDefault: true, ocrCapable: true },
  ]) === 'qwen');
  check('default NOT OCR-capable → priority fallback (qwen before gemini)', pickOcrProvider([
    { provider: 'deepseek', isDefault: true, ocrCapable: false },
    { provider: 'gemini', isDefault: false, ocrCapable: true },
    { provider: 'qwen', isDefault: false, ocrCapable: true },
  ]) === 'qwen');
  check('fallback: doubao before gemini in priority', pickOcrProvider([
    { provider: 'deepseek', isDefault: true, ocrCapable: false },
    { provider: 'gemini', isDefault: false, ocrCapable: true },
    { provider: 'doubao', isDefault: false, ocrCapable: true },
  ]) === 'doubao');
  check('fallback: glm before kimi in priority', pickOcrProvider([
    { provider: 'deepseek', isDefault: true, ocrCapable: false },
    { provider: 'kimi', isDefault: false, ocrCapable: true },
    { provider: 'glm', isDefault: false, ocrCapable: true },
  ]) === 'glm');
  check('no OCR-capable provider → null', pickOcrProvider([
    { provider: 'deepseek', isDefault: true, ocrCapable: false },
    { provider: 'kimi', isDefault: false, ocrCapable: false },
  ]) === null);
  check('no providers → null', pickOcrProvider([]) === null);
}

// Doubao = OpenAI **Chat Completions** dialect (via the shared _openaiCompatible factory; Volcengine
// Ark, baseURL keeps the /api/v3 path). Text tool-calling + a vision OCR round-trip (capabilities.ocr
// =true, visionModel=doubao-seed-1-6-vision). Same wire shape as DeepSeek/Qwen/Kimi/GLM.
async function testDoubao() {
  console.log('Doubao (Chat Completions):');
  check('doubao meta id + default model (Seed 2.0 Pro)', doubao.meta.id === 'doubao' && doubao.meta.defaultModel === 'doubao-seed-2-0-pro-260215');
  check('doubao default model in availableModels', doubao.meta.availableModels.some(m => m.value === 'doubao-seed-2-0-pro-260215'));
  check('doubao whitelist is Seed 2.0 pro / lite / mini',
    ['doubao-seed-2-0-pro-260215', 'doubao-seed-2-0-lite-260428', 'doubao-seed-2-0-mini-260428'].every(v => doubao.meta.availableModels.some(m => m.value === v)));
  check('doubao capabilities: ocr=true (vision) + visionModel=Seed 2.0 Pro, no tts/webGrounding',
    doubao.meta.capabilities.tts === false && doubao.meta.capabilities.ocr === true && doubao.meta.capabilities.webGrounding === false && doubao.meta.visionModel === 'doubao-seed-2-0-pro-260215');

  const toolResp = { choices: [{ message: { role: 'assistant', content: null, tool_calls: [{ id: 'call_1', type: 'function', function: { name: 'get_sales', arguments: '{}' } }] } }] };
  const finalResp = { choices: [{ message: { role: 'assistant', content: 'Sales total is 100' } }] };

  setFetch([toolResp]);
  const s1 = await doubao.chatWithTools('k', 'm', { history: seed(doubao), system: 'sys', tools: TOOLDEFS });
  check('doubao round1 type=tool_calls', s1.type === 'tool_calls', JSON.stringify(s1));
  check('doubao round1 call parsed (id + name + args object)', !!(s1.calls && s1.calls[0] && s1.calls[0].id === 'call_1' && s1.calls[0].name === 'get_sales' && typeof s1.calls[0].args === 'object'));
  check('doubao round1 assistantMsg single assistant turn w/ tool_calls', !!(s1.assistantMsg && s1.assistantMsg.role === 'assistant' && Array.isArray(s1.assistantMsg.tool_calls) && s1.assistantMsg.tool_calls.length === 1));
  check('doubao round1 request carried nested function tools + tool_choice', Array.isArray(_bodies[0].tools) && _bodies[0].tools[0].type === 'function' && _bodies[0].tools[0].function.name === 'get_sales' && _bodies[0].tool_choice === 'auto');
  check('doubao request carries extraBody reasoning_effort=minimal (Seed 2.0 thinking off)', _bodies[0].reasoning_effort === 'minimal');
  check('doubao round1 system prepended as first message', _bodies[0].messages[0].role === 'system' && _bodies[0].messages[0].content === 'sys');

  const tr = doubao.toToolResultsMsg([{ call: s1.calls[0], result: { rows: [1, 2] } }]);
  check('doubao toToolResultsMsg single shape', Array.isArray(tr) && tr.length === 1 && tr[0].role === 'tool' && tr[0].tool_call_id === 'call_1' && tr[0].content === JSON.stringify({ rows: [1, 2] }));
  const trM = doubao.toToolResultsMsg([{ call: { id: 'c1' }, result: {} }, { call: { id: 'c2' }, result: {} }]);
  check('doubao multi-tool = array of 2 role:tool messages', Array.isArray(trM) && trM.length === 2 && trM[0].tool_call_id === 'c1' && trM[1].tool_call_id === 'c2');

  setFetch([finalResp]);
  const s2 = await doubao.chatWithTools('k', 'm', { history: seed(doubao), system: 'sys', tools: TOOLDEFS });
  check('doubao round2 type=final + text', s2.type === 'final' && s2.text === 'Sales total is 100', JSON.stringify(s2));

  setFetch([finalResp]);
  await doubao.chatWithTools('k', 'm', { history: seed(doubao), system: 'sys', tools: [] });
  check('doubao empty tools omits tools field', !('tools' in _bodies[0]), JSON.stringify(_bodies[0]));
}

async function testDoubaoVisionOCR() {
  console.log('Doubao Vision OCR (Chat Completions image_url):');
  const ocrResp = { choices: [{ message: { role: 'assistant', content: '{"isInvoiceLike":true,"sellerName":"BEAN","grossAmount":520}' } }] };
  setFetch([ocrResp]);
  const out = await doubao.ocr('k', 'doubao-seed-2-0-lite-260428', { base64Data: 'BBBB', mimeType: 'image/jpeg', ocrPrompt: 'extract invoice' });
  check('doubao ocr returns parsed JSON', !!(out && out.isInvoiceLike === true && out.sellerName === 'BEAN'));
  const body = _bodies[0];
  check('doubao ocr uses visionModel (not the passed chat model)', body.model === 'doubao-seed-2-0-pro-260215');
  check('doubao ocr request carries extraBody reasoning_effort=minimal', body.reasoning_effort === 'minimal');
  const content = body.messages[0].content;
  check('doubao ocr request carries text + image_url(base64 data URL) blocks',
    Array.isArray(content)
    && content.some(c => c.type === 'text' && c.text === 'extract invoice')
    && content.some(c => c.type === 'image_url' && c.image_url && c.image_url.url === 'data:image/jpeg;base64,BBBB'));
}

// PR-3d: GLM vision OCR — glm-4.6v (thinking off by default, so NO extraBody; the request must NOT
// carry reasoning_effort/thinking). Same image_url base64 path as Qwen/Doubao.
async function testGLMVisionOCR() {
  console.log('GLM Vision OCR (Chat Completions image_url):');
  const ocrResp = { choices: [{ message: { role: 'assistant', content: '{"isInvoiceLike":true,"sellerName":"ZHIPU","grossAmount":888}' } }] };
  setFetch([ocrResp]);
  const out = await glm.ocr('k', 'glm-4.6', { base64Data: 'CCCC', mimeType: 'image/png', ocrPrompt: 'extract invoice' });
  check('glm ocr returns parsed JSON', !!(out && out.isInvoiceLike === true && out.sellerName === 'ZHIPU'));
  const body = _bodies[0];
  check('glm ocr uses visionModel (not the passed chat model)', body.model === 'glm-4.6v');
  const content = body.messages[0].content;
  check('glm ocr request carries text + image_url(base64 data URL) blocks',
    Array.isArray(content)
    && content.some(c => c.type === 'text' && c.text === 'extract invoice')
    && content.some(c => c.type === 'image_url' && c.image_url && c.image_url.url === 'data:image/png;base64,CCCC'));
  check('glm ocr request has no extraBody leakage (no reasoning_effort/thinking)', !('reasoning_effort' in body) && !('thinking' in body));
}

// PR-3d: Kimi vision OCR — moonshot-v1-32k-vision-preview (non-thinking). content MUST stay an array.
async function testKimiVisionOCR() {
  console.log('Kimi Vision OCR (Chat Completions image_url):');
  const ocrResp = { choices: [{ message: { role: 'assistant', content: '{"isInvoiceLike":true,"sellerName":"MOONSHOT","grossAmount":777}' } }] };
  setFetch([ocrResp]);
  const out = await kimi.ocr('k', 'kimi-k2.6', { base64Data: 'DDDD', mimeType: 'image/webp', ocrPrompt: 'extract invoice' });
  check('kimi ocr returns parsed JSON', !!(out && out.isInvoiceLike === true && out.sellerName === 'MOONSHOT'));
  const body = _bodies[0];
  check('kimi ocr uses visionModel (not the passed chat model)', body.model === 'moonshot-v1-32k-vision-preview');
  const content = body.messages[0].content;
  check('kimi ocr request carries text + image_url(base64) blocks, content is ARRAY (not stringified)',
    Array.isArray(content)
    && content.some(c => c.type === 'text' && c.text === 'extract invoice')
    && content.some(c => c.type === 'image_url' && c.image_url && c.image_url.url === 'data:image/webp;base64,DDDD'));
}

// Gemini uses the @google/genai SDK (not fetch), so we test its PURE functions directly with
// crafted response objects — no SDK mock, no network, no key.
async function testGemini() {
  console.log('Gemini:');
  // buildGeminiConfig: tool mode carries functionDeclarations and NO googleSearch; empty tools omits tools
  const cfgTools = gemini.buildGeminiConfig('sys', TOOLDEFS);
  check('gemini config = functionDeclarations, no googleSearch',
    Array.isArray(cfgTools.tools) && cfgTools.tools[0].functionDeclarations.length === 1 && cfgTools.tools[0].functionDeclarations[0].name === 'get_sales' && !JSON.stringify(cfgTools).includes('googleSearch'));
  const cfgEmpty = gemini.buildGeminiConfig('sys', []);
  check('gemini empty tools omits tools field', !('tools' in cfgEmpty));

  // parseGeminiResponse: tool-call round / final round
  const s1 = gemini.parseGeminiResponse({ candidates: [{ content: { parts: [{ text: 'checking' }, { functionCall: { name: 'get_sales', args: {} } }] } }] });
  check('gemini parse round1 type=tool_calls', s1.type === 'tool_calls', JSON.stringify(s1));
  check('gemini parse round1 call (id=name, args object)', !!(s1.calls && s1.calls[0] && s1.calls[0].id === 'get_sales' && s1.calls[0].name === 'get_sales' && typeof s1.calls[0].args === 'object'));
  check('gemini parse round1 assistantMsg role=model', !!(s1.assistantMsg && s1.assistantMsg.role === 'model' && Array.isArray(s1.assistantMsg.parts)));
  const s2 = gemini.parseGeminiResponse({ text: 'Sales total is 100' });
  check('gemini parse round2 type=final + text', s2.type === 'final' && s2.text === 'Sales total is 100', JSON.stringify(s2));

  // toToolResultsMsg: single / array-result wrapping / multi-tool batched into one turn
  const tr = gemini.toToolResultsMsg([{ call: { name: 'get_sales' }, result: { rows: [1, 2] } }]);
  check('gemini toToolResultsMsg single shape', tr.role === 'user' && tr.parts.length === 1 && tr.parts[0].functionResponse.name === 'get_sales' && Array.isArray(tr.parts[0].functionResponse.response.rows));
  const trArr = gemini.toToolResultsMsg([{ call: { name: 'get_sales' }, result: [1, 2] }]);
  check('gemini array result wrapped in object', !!(trArr.parts[0].functionResponse.response && Array.isArray(trArr.parts[0].functionResponse.response.result)));
  const trM = gemini.toToolResultsMsg([{ call: { name: 'a' }, result: {} }, { call: { name: 'b' }, result: {} }]);
  check('gemini multi-tool batched into single user turn', trM.role === 'user' && trM.parts.length === 2 && trM.parts[0].functionResponse.name === 'a' && trM.parts[1].functionResponse.name === 'b');
}

// R4b: token budget backstop. A fake (provider-agnostic) adapter returns tool_calls when tools
// are present and a final when they are not (the over-round / over-budget fallback path). With a
// tiny maxTokens and a large history, the loop must break at the TOP (before any chatWithTools
// with tools) → fall to the tools:[] fallback → final, with NO tool rounds executed (empty trace).
// Locks "budget reached → reuse the existing fallback to answer, never an error".
async function testAgentBudget() {
  console.log('Agent token budget (R4b):');
  const { runAgentLoop } = require('../electron/ai/agent.js');
  const fakeAdapter = {
    chatWithTools: async (_k, _m, { tools }) => (
      (!tools || tools.length === 0)
        ? { type: 'final', text: 'fallback final' }
        : { type: 'tool_calls', assistantMsg: { role: 'assistant', content: [] }, calls: [{ name: 'get_sales', args: {} }] }
    ),
    toToolResultsMsg: () => ({ role: 'user', content: [] }),
  };
  const big = [{ role: 'user', content: 'x'.repeat(5000) }];
  const res = await runAgentLoop({ adapter: fakeAdapter, apiKey: 'k', model: 'm', history: big, system: 'sys', maxTokens: 100 });
  check('agent token budget → breaks to fallback final (no tool rounds)',
    res.text === 'fallback final' && Array.isArray(res.toolTrace) && res.toolTrace.length === 0, JSON.stringify(res));
}

async function main() {
  console.log('\n=== Agent Provider Round-Trip (offline) ===\n');
  await testAnthropic();
  await testOpenAI();
  await testDeepSeek();
  await testQwen();
  await testKimi();
  await testGLM();
  await testDoubao();
  await testQwenVisionOCR();
  await testDoubaoVisionOCR();
  await testGLMVisionOCR();
  await testKimiVisionOCR();
  testOcrProviderSelection();
  await testGemini();
  await testAgentBudget();
  console.log(`\n${failures.length === 0 ? '✓ all passed' : '✗ ' + failures.length + ' failed'}\n`);
  process.exit(failures.length === 0 ? 0 : 1);
}

main().catch((e) => { console.error('crashed:', e); process.exit(2); });
