#!/usr/bin/env node
// AI tone guard (PR-E2): SoloLedger's AI is a business-operations / bookkeeping helper,
// NOT a CFO / auditor / tax advisor. The AI persona prompts must never adopt a statutory
// professional role. Fails if a banned role noun appears in the AI persona strings
// (i18n ai.* values + the OCR prompt builder's role map).
//
// Complements check:disclaimer (visible disclaimers + boundary-directive injection).
// NOTE: disclaimers / ai.boundaryDirective may *mention* "accountant / tax professional"
// to advise consulting one — that is allowed; only role *adoption* nouns are banned here.
// scripts/ is excluded by the other guards, so this file's pattern strings don't self-match.

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = join(__dirname, '..');
const LOCALES = ['zh-CN', 'zh-TW', 'en', 'ja', 'ko', 'fr'];

// AI-role overclaims the persona prompts must NOT adopt.
const BANNED = [
  /\bCFO\b/i,
  /首席财务官/, /財務長/,
  /财务审计员/, /財務審計員/, /国际财务审计员/, /國際財務審計員/, /审计员/, /審計員/,
  /財務監査/, /国際財務監査/, /監査員/, /監査人/,
  /감사인/,
  /financial auditor/i, /\bauditor\b/i, /auditeur financier/i,
  /Directeur financier/i,
  /税务顾问/, /稅務顧問/, /tax advisor/i, /财务顾问/, /財務顧問/,
];

const findings = [];
const targets = [];

// Every ai.* string value across all locales.
for (const l of LOCALES) {
  const ai = JSON.parse(readFileSync(join(ROOT, 'i18n/locales', `${l}.json`), 'utf8')).ai || {};
  for (const [k, v] of Object.entries(ai)) {
    if (typeof v === 'string') targets.push({ where: `${l}.json ai.${k}`, text: v });
  }
}
// The live OCR system-prompt role map.
targets.push({
  where: 'electron/ai/ocrPromptBuilder.js',
  text: readFileSync(join(ROOT, 'electron/ai/ocrPromptBuilder.js'), 'utf8'),
});

for (const { where, text } of targets) {
  for (const re of BANNED) {
    const m = text.match(re);
    if (m) findings.push(`${where}: contains banned AI role "${m[0]}"`);
  }
}

// PR-E2b: the accountingLocale aiContext strings (injected into the AI system prompt
// by buildAIFinanceContext) must NOT hardcode tax-rate numbers — the AI should defer to
// the user-configured rate and treat figures as management estimates. The real rates
// used in calculations live in accountingProfiles.ts and are not affected.
const cfg = readFileSync(join(ROOT, 'components/accountingLocaleConfig.ts'), 'utf8');
const RATE = /\d+(?:\.\d+)?\s*%/;
let aiContextCount = 0;
for (const m of cfg.matchAll(/aiContext:\s*'([^']*)'/g)) {
  aiContextCount++;
  const rate = m[1].match(RATE);
  if (rate) findings.push(`accountingLocaleConfig.ts aiContext: hardcoded tax rate "${rate[0]}" — relativize to user-configured rates`);
}

console.log('=== AI Tone Guard (no CFO / auditor / tax-advisor persona; no hardcoded aiContext rates) ===\n');
console.log(`Scanned: ${targets.length} AI persona strings (ai.* × ${LOCALES.length} + ocrPromptBuilder) + ${aiContextCount} aiContext values`);
console.log(`Findings: ${findings.length}\n`);

if (findings.length) {
  for (const f of findings) console.error(`  ✗ ${f}`);
  console.error('\n❌ AI persona must stay a business-operations / bookkeeping helper, not a statutory professional role.');
  process.exit(1);
}

console.log('✓ No CFO / auditor / tax-advisor persona, and no hardcoded tax rates in aiContext.');
