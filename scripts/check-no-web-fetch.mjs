#!/usr/bin/env node
// check:no-web-fetch — Phase 3 (PR-3.7) e2e IPC-boot guard.
//
// Asserts the Playwright e2e suite no longer boots through mocked Web fetch/auth: it
// must not intercept /api or /auth via page.route, must not call fetch() to those
// paths directly, and must not reference the removed Web-boot helpers. Every e2e
// test boots through the IPC electronAPI mock (e2e/helpers/electronMock.ts:
// bootComboIPC / installElectronMock + gotoApp), so the app exercises the same
// desktop IPC path it uses in production.
//
// SCOPE: this guard only scans e2e/. The source-side Web fallback (App.tsx auth gate,
// services/* fetch branches, components/LoginPage.tsx, DataAnalysisPage web fetch) is
// intentionally NOT scanned — its removal is a separate PR-3.8 step.
//
// Line comments are stripped before matching so prose that merely mentions these
// patterns (e.g. "replaces the legacy page.route recording") does not trip the guard.

import fs from 'node:fs';
import path from 'node:path';

const E2E_DIR = path.join(process.cwd(), 'e2e');

function listFiles(dir) {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) out.push(...listFiles(full));
    else if (/\.(ts|tsx|mts|js|mjs)$/.test(entry.name)) out.push(full);
  }
  return out;
}

// Strip // line comments and /* */ block comments (incl. multi-line and JSDoc) so
// explanatory prose that merely mentions these patterns is ignored. Stateful across
// lines (tracks open block comments) while preserving line numbers. Good enough for
// this guard: e2e source has no // or /* sequences hidden inside string literals.
function makeStripper() {
  let inBlock = false;
  return (line) => {
    let out = '';
    let i = 0;
    while (i < line.length) {
      if (inBlock) {
        const end = line.indexOf('*/', i);
        if (end === -1) { i = line.length; } else { i = end + 2; inBlock = false; }
      } else if (line[i] === '/' && line[i + 1] === '/') {
        break; // rest of line is a line comment
      } else if (line[i] === '/' && line[i + 1] === '*') {
        inBlock = true; i += 2;
      } else {
        out += line[i]; i += 1;
      }
    }
    return out;
  };
}

const RULES = [
  { name: 'page.route web mock', re: /page\.route\(\s*['"`][^'"`]*\/(api|auth)\b/ },
  { name: 'direct web fetch', re: /fetch\(\s*['"`]\/(api|auth)\b/ },
  { name: 'removed Web-boot helper', re: /\b(bootCombo|bootFinance)\s*\(/ },
];

if (!fs.existsSync(E2E_DIR)) {
  console.error(`check:no-web-fetch — e2e/ not found at ${E2E_DIR}`);
  process.exit(1);
}

const findings = [];
for (const file of listFiles(E2E_DIR)) {
  const lines = fs.readFileSync(file, 'utf8').split('\n');
  const strip = makeStripper();
  lines.forEach((raw, idx) => {
    const code = strip(raw);
    for (const rule of RULES) {
      if (rule.re.test(code)) {
        findings.push({ file: path.relative(process.cwd(), file), line: idx + 1, rule: rule.name, text: raw.trim() });
      }
    }
  });
}

console.log('=== check:no-web-fetch (e2e IPC-boot guard) ===');
if (findings.length === 0) {
  console.log('✓ e2e boots exclusively through the IPC electronAPI mock — no Web fetch/auth mocking found.');
  process.exit(0);
}
for (const f of findings) console.error(`  ${f.file}:${f.line} [${f.rule}] ${f.text}`);
console.error(`\n✗ ${findings.length} Web-boot residue(s) found in e2e.`);
console.error('  Boot via e2e/helpers/electronMock.ts (bootComboIPC / installElectronMock + gotoApp) instead.');
process.exit(1);
