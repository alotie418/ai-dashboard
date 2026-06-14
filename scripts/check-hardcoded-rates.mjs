#!/usr/bin/env node
// Hardcoded-rate guard (PR-T2): App.tsx must NOT do client-side tax-rate math.
// Income tax / surcharge / profit / margins come from the backend's locale-aware
// financial statement (electron/reports/* or worker); the single source of truth
// for rates is accountingProfiles.ts + the per-locale settings. App.tsx previously
// hardcoded a 12% surcharge (× 0.12) and a 25% income tax (× 0.25) regardless of
// accountingLocale — this guard prevents that from creeping back in.
//
// Scope (scanned): App.tsx only. Out of scope: worker/src/index.js keeps its
// hardcoded 12% / 25% by design this round (web-only path, documented TODO +
// ACCOUNTING-AUDIT.md R4); accountingProfiles.ts is the legitimate home of rates.

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = join(__dirname, '..');
const TARGET = 'App.tsx';

// Strip /* */ block comments (preserve newlines) then // line comments per line,
// so a rate mentioned in a comment never trips the guard (no self-poisoning).
function stripComments(src) {
  const noBlock = src.replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, ' '));
  return noBlock.split('\n').map((line) => {
    const i = line.indexOf('//');
    return i >= 0 ? line.slice(0, i) : line;
  });
}

// A decimal used as a multiplier (× 0.NN or 0.NN ×), or the specific tax-rate
// literals 0.12 / 0.25 anywhere (catches e.g. `const rate = 0.25; profit * rate`).
const RATE_PATTERNS = [
  { re: /\*\s*0\.\d+/, why: 'multiplication by a decimal rate (* 0.NN)' },
  { re: /\b0\.\d+\s*\*/, why: 'decimal rate used as a multiplier (0.NN *)' },
  { re: /\b0\.(12|25)\b/, why: 'hardcoded tax-rate literal (0.12 surcharge / 0.25 income tax)' },
];

const findings = [];
const lines = stripComments(readFileSync(join(ROOT, TARGET), 'utf8'));
lines.forEach((line, idx) => {
  for (const { re, why } of RATE_PATTERNS) {
    const m = line.match(re);
    if (m) { findings.push(`${TARGET}:${idx + 1}: "${m[0].trim()}" — ${why}`); break; }
  }
});

console.log('\n=== Hardcoded Tax-Rate Guard (PR-T2) ===\n');
console.log(`Scanned: ${TARGET} (comments stripped)`);
console.log(`Findings: ${findings.length}\n`);
if (findings.length) {
  for (const f of findings) console.error('  ✗ ' + f);
  console.error('\nApp.tsx must trust the backend financial statement, not re-derive tax');
  console.error('rates on the client. Move any rate to accountingProfiles.ts / settings.\n');
  process.exit(1);
}
console.log('✓ No client-side hardcoded tax-rate math in App.tsx.\n');
