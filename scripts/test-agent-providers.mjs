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

async function main() {
  console.log('\n=== Agent Provider Round-Trip (offline) ===\n');
  await testAnthropic();
  await testOpenAI();
  await testGemini();
  console.log(`\n${failures.length === 0 ? '✓ all passed' : '✗ ' + failures.length + ' failed'}\n`);
  process.exit(failures.length === 0 ? 0 : 1);
}

main().catch((e) => { console.error('crashed:', e); process.exit(2); });
