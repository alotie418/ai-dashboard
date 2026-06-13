#!/usr/bin/env node
// Provider registry parity guard.
//
// A provider is registered across one JS source of truth (electron/ai PROVIDERS) and
// several TS ones (AIProviderId union + the frontend model maps + the two PROVIDER_DOCS).
// tsc enforces parity AMONG the TS Record<AIProviderId,...> maps, but it cannot see the
// backend JS registry. This guard locks all of them to the SAME provider id set, and
// checks each provider's default model is in its whitelist (backend META + frontend).
//
// Adding a provider half-way (e.g. backend adapter but forgot the frontend whitelist, so
// ProvidersSection crashes on KNOWN_MODELS[id].map) fails here instead of at runtime.

import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const require = createRequire(import.meta.url);
const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = join(__dirname, '..');

const findings = [];
const read = (rel) => readFileSync(join(ROOT, rel), 'utf8');
const sortedEq = (a, b) => a.length === b.length && [...a].sort().join(',') === [...b].sort().join(',');

// ── Backend: electron/ai/index.js  const PROVIDERS = { a, b, c }; ──
function backendIds() {
  const src = read('electron/ai/index.js');
  const m = src.match(/const PROVIDERS\s*=\s*\{([\s\S]*?)\}/);
  if (!m) { findings.push('cannot parse PROVIDERS in electron/ai/index.js'); return []; }
  return [...m[1].matchAll(/^\s*([a-zA-Z0-9_]+)\s*,?\s*$/gm)].map(x => x[1]);
}

// ── types.ts  export type AIProviderId = 'a' | 'b' | 'c'; ──
function providerIdUnion() {
  const src = read('types.ts');
  const m = src.match(/export type AIProviderId\s*=\s*([^;]+);/);
  if (!m) { findings.push('cannot parse AIProviderId in types.ts'); return []; }
  return [...m[1].matchAll(/'([^']+)'/g)].map(x => x[1]);
}

// Keys of a `<name>: Record<AIProviderId, ...> = { key: <delim> ... }` block in a TS file.
function recordKeys(rel, name, valueDelim) {
  const src = read(rel);
  const start = src.indexOf(name);
  if (start === -1) { findings.push(`cannot find ${name} in ${rel}`); return []; }
  // take from the opening brace after the name to a balanced-ish closing — coarse but enough:
  const open = src.indexOf('{', start);
  const block = src.slice(open);
  const re = new RegExp(`^\\s*([a-zA-Z0-9_]+):\\s*${valueDelim}`, 'gm');
  const keys = [];
  for (const m of block.matchAll(re)) {
    keys.push(m[1]);
    // stop at the first top-level closer line `};` to avoid bleeding into later code
  }
  // restrict to the first block: cut at the first `\n};`
  const endRel = block.indexOf('\n};');
  if (endRel !== -1) {
    const firstBlock = block.slice(0, endRel);
    return [...firstBlock.matchAll(re)].map(m => m[1]);
  }
  return keys;
}

// KNOWN_MODELS per-provider model values (value: '...').
function knownModelsMap() {
  const src = read('components/aiProviderModels.ts');
  const open = src.indexOf('KNOWN_MODELS');
  const block = src.slice(src.indexOf('{', open));
  const end = block.indexOf('\n};');
  const body = end !== -1 ? block.slice(0, end) : block;
  const map = {};
  for (const m of body.matchAll(/([a-zA-Z0-9_]+):\s*\[([\s\S]*?)\]/g)) {
    map[m[1]] = [...m[2].matchAll(/value:\s*'([^']+)'/g)].map(x => x[1]);
  }
  return map;
}
function defaultModelMap() {
  const src = read('components/aiProviderModels.ts');
  const open = src.indexOf('DEFAULT_MODEL');
  const block = src.slice(src.indexOf('{', open));
  const end = block.indexOf('\n};');
  const body = end !== -1 ? block.slice(0, end) : block;
  const map = {};
  for (const m of body.matchAll(/([a-zA-Z0-9_]+):\s*'([^']+)'/g)) map[m[1]] = m[2];
  return map;
}

function main() {
  const backend = backendIds();
  const union = providerIdUnion();
  const knownKeys = recordKeys('components/aiProviderModels.ts', 'KNOWN_MODELS', '\\[');
  const defaultKeys = recordKeys('components/aiProviderModels.ts', 'DEFAULT_MODEL', "'");
  const docsKeys = recordKeys('components/ProvidersSection.tsx', 'PROVIDER_DOCS', '\\{');
  const onbKeys = recordKeys('components/OnboardingWizard.tsx', 'PROVIDER_DOCS', '\\{');

  const sets = {
    'backend PROVIDERS (index.js)': backend,
    'AIProviderId union (types.ts)': union,
    'KNOWN_MODELS (aiProviderModels.ts)': knownKeys,
    'DEFAULT_MODEL (aiProviderModels.ts)': defaultKeys,
    'PROVIDER_DOCS (ProvidersSection.tsx)': docsKeys,
    'PROVIDER_DOCS (OnboardingWizard.tsx)': onbKeys,
  };

  const ref = backend;
  for (const [label, ids] of Object.entries(sets)) {
    if (!sortedEq(ids, ref)) {
      findings.push(`provider set mismatch — ${label} = [${[...ids].sort()}] ≠ backend [${[...ref].sort()}]`);
    }
  }

  // Each provider's default model must be in its frontend whitelist + match the backend META.
  const known = knownModelsMap();
  const defaults = defaultModelMap();
  for (const id of ref) {
    const wl = known[id] || [];
    const def = defaults[id];
    if (def && wl.length && !wl.includes(def)) {
      findings.push(`${id}: DEFAULT_MODEL '${def}' not in KNOWN_MODELS [${wl}]`);
    }
    // Backend META cross-check (best-effort; provider modules are import-safe — no electron/db at load).
    try {
      const meta = require(`../electron/ai/providers/${id}.js`).meta;
      if (!meta || meta.id !== id) findings.push(`${id}: backend adapter meta.id mismatch (got '${meta && meta.id}')`);
      const backendVals = (meta?.availableModels || []).map(m => m.value);
      if (meta?.defaultModel && backendVals.length && !backendVals.includes(meta.defaultModel)) {
        findings.push(`${id}: backend defaultModel '${meta.defaultModel}' not in backend availableModels [${backendVals}]`);
      }
      if (wl.length && backendVals.length && !sortedEq(wl, backendVals)) {
        findings.push(`${id}: frontend KNOWN_MODELS [${[...wl].sort()}] ≠ backend availableModels [${[...backendVals].sort()}]`);
      }
      // PR-3b vision invariant: a Chat-Completions (factory) provider may declare OCR ONLY with a
      // visionModel, and a visionModel implies capabilities.ocr=true. Keeps Qwen (qwen-vl-max → ocr:true)
      // and DeepSeek/Kimi/GLM (no visionModel → ocr:false) coherent, and catches "ocr:true but no model".
      const usesFactory = /createOpenAICompatibleAdapter/.test(read(`electron/ai/providers/${id}.js`));
      if (usesFactory) {
        const hasVision = typeof meta?.visionModel === 'string' && meta.visionModel.length > 0;
        const ocrOn = !!(meta?.capabilities && meta.capabilities.ocr === true);
        if (hasVision !== ocrOn) {
          findings.push(`${id}: factory OCR invariant — visionModel=${meta?.visionModel || 'none'} vs capabilities.ocr=${ocrOn} (must both be set or both unset)`);
        }
      }
    } catch (e) {
      findings.push(`${id}: cannot require backend adapter electron/ai/providers/${id}.js (${e.message})`);
    }
  }

  console.log(`\n=== Provider Registry Parity ===\n`);
  console.log(`Providers (backend): ${[...ref].sort().join(', ')}`);
  console.log(`Findings: ${findings.length}\n`);
  if (findings.length === 0) {
    console.log('✓ Backend PROVIDERS, AIProviderId, model maps and PROVIDER_DOCS are all in sync.');
    process.exit(0);
  }
  for (const f of findings) console.log(`  ✗ ${f}`);
  console.log(`\n✗ ${findings.length} provider-registry parity issue(s).`);
  process.exit(1);
}

main();
