#!/usr/bin/env node
// US SE-tax constant guard (PR-T3): electron/reports/us.js must NOT inline
// year-specific Self-Employment-tax magic numbers. They live only in
// electron/reports/usTaxParams.js (year-keyed, easy to update yearly). This
// prevents a stale single-year hardcode (e.g. the 2024 $168,600 cap) from
// reappearing in the engine. Boundary: these are SoloLedger management
// estimates, not tax-filing advice.
//
// Comments are stripped before scanning so a number mentioned in a comment
// (here or in us.js) never trips the guard (no self-poisoning).

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = join(__dirname, '..');

function stripComments(src) {
  const noBlock = src.replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, ' '));
  return noBlock.split('\n').map((line) => {
    const i = line.indexOf('//');
    return i >= 0 ? line.slice(0, i) : line;
  });
}

// SE-tax magic numbers that must only live in usTaxParams.js.
const FORBIDDEN = ['168600', '176100', '184500', '0.9235', '0.124', '0.029', '0.009', '200000'];

const findings = [];
const lines = stripComments(readFileSync(join(ROOT, 'electron/reports/us.js'), 'utf8'));
lines.forEach((line, idx) => {
  for (const lit of FORBIDDEN) {
    // Numeric boundary so e.g. 0.124 doesn't match inside 0.1245.
    const re = new RegExp(`(?<![\\d.])${lit.replace('.', '\\.')}(?![\\d])`);
    if (re.test(line)) {
      findings.push(`electron/reports/us.js:${idx + 1}: "${lit}" — SE-tax constant must live in usTaxParams.js`);
      break;
    }
  }
});

// Sanity: usTaxParams.js exports resolveSeTaxParams and keys >=2 years.
const params = readFileSync(join(ROOT, 'electron/reports/usTaxParams.js'), 'utf8');
if (!/resolveSeTaxParams/.test(params)) findings.push('usTaxParams.js: missing resolveSeTaxParams export');
const yearKeys = (params.match(/\b20\d{2}:/g) || []).length;
if (yearKeys < 2) findings.push(`usTaxParams.js: expected >=2 year-keyed entries, found ${yearKeys}`);

console.log('\n=== US SE-tax Constant Guard (PR-T3) ===\n');
console.log('Scanned: electron/reports/us.js (comments stripped) + usTaxParams.js');
console.log(`Findings: ${findings.length}\n`);
if (findings.length) {
  for (const f of findings) console.error('  ✗ ' + f);
  console.error('\nMove year-specific SE-tax constants into electron/reports/usTaxParams.js.\n');
  process.exit(1);
}
console.log('✓ No inline SE-tax constants in us.js; usTaxParams.js is year-keyed.\n');
