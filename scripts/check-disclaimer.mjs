#!/usr/bin/env node
// Disclaimer guard (PR-E1): financial / tax / AI surfaces must carry a visible
// "this is a management estimate — not a statutory / filing / professional figure"
// disclaimer, and the AI prompts must carry the management-boundary directive.
//
// SoloLedger is a management bookkeeping tool, NOT a statutory-accounting / tax-filing
// product (see the accounting professionalization audit). This guard is a pure-additive
// safety net: it fails if any disclaimer i18n key is missing / empty / untranslated, or
// if any required mount point stops referencing it.
//
// scripts/ is excluded by the other guards, so this file's key strings don't self-match.

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = join(__dirname, '..');

const LOCALES = ['zh-CN', 'zh-TW', 'en', 'ja', 'ko', 'fr'];

// i18n keys (dot-path) that must exist in every locale, be non-empty, and not fall back to en.
const KEYS = [
  'disclaimer.report',
  'disclaimer.tax',
  'disclaimer.ai',
  'disclaimer.usTax',
  'disclaimer.rates',
  'ai.boundaryDirective',
];

// Mount points: each key must be referenced (via t('key')) by these files. AssistantWidget
// is intentionally NOT listed — it renders <ChatPanel/>, which already carries disclaimer.ai.
const MOUNTS = [
  { key: 'disclaimer.report', files: ['components/FinancePage.tsx'] },
  { key: 'disclaimer.tax',    files: ['components/FinancePage.tsx', 'components/VATStatistics.tsx'] },
  { key: 'disclaimer.ai',     files: ['components/AIInsights.tsx', 'components/assistant/ChatPanel.tsx'] },
  { key: 'disclaimer.usTax',  files: ['components/USDashboardCards.tsx', 'components/USTaxToolsPage.tsx'] },
  { key: 'disclaimer.rates',  files: ['components/AccountingSection.tsx'] },
  // AI prompt boundary-directive injection sites (chat / briefing).
  { key: 'ai.boundaryDirective', files: ['components/assistant/useAssistant.ts', 'App.tsx'] },
];

const findings = [];
const get = (obj, path) => path.split('.').reduce((o, k) => (o == null ? undefined : o[k]), obj);

// A. i18n completeness / parity / non-fallback
const data = {};
for (const l of LOCALES) data[l] = JSON.parse(readFileSync(join(ROOT, 'i18n/locales', `${l}.json`), 'utf8'));
for (const key of KEYS) {
  const en = get(data.en, key);
  for (const l of LOCALES) {
    const v = get(data[l], key);
    if (typeof v !== 'string' || !v.trim()) { findings.push(`i18n ${l}: "${key}" missing or empty`); continue; }
    if (l !== 'en' && en && v === en) findings.push(`i18n ${l}: "${key}" not translated (equals en)`);
  }
}

// B + C. mount / injection references
for (const { key, files } of MOUNTS) {
  for (const f of files) {
    let src;
    try { src = readFileSync(join(ROOT, f), 'utf8'); } catch { findings.push(`mount: ${f} not found (for "${key}")`); continue; }
    if (!src.includes(`'${key}'`) && !src.includes(`"${key}"`)) {
      findings.push(`mount: ${f} no longer references "${key}"`);
    }
  }
}

// D. boundary directive must still read like a boundary (not accidentally blanked) in zh + en
const BOUND = { 'zh-CN': ['不得', '咨询'], en: ['Boundary', 'consult'] };
for (const [l, words] of Object.entries(BOUND)) {
  const v = get(data[l], 'ai.boundaryDirective') || '';
  for (const w of words) if (!v.includes(w)) findings.push(`boundary ${l}: ai.boundaryDirective missing expected term "${w}"`);
}

console.log('=== Disclaimer Guard (management-estimate boundary) ===\n');
console.log(`Keys: ${KEYS.length} × ${LOCALES.length} locales; Mount refs: ${MOUNTS.reduce((n, m) => n + m.files.length, 0)}`);
console.log(`Findings: ${findings.length}\n`);

if (findings.length) {
  for (const f of findings) console.error(`  ✗ ${f}`);
  console.error('\n❌ Disclaimer coverage incomplete. Every financial / tax / AI surface must carry its disclaimer, and AI prompts the boundary directive.');
  process.exit(1);
}

console.log('✓ All disclaimer keys present, translated, and mounted; AI boundary directive injected at all prompt sites.');
