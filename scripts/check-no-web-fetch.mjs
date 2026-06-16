#!/usr/bin/env node
// check:no-web-fetch — desktop-only boot guard.
//
// Two scopes, both asserting the app has NO Web HTTP/auth path anymore:
//
//   1. e2e/  — the Playwright suite must boot exclusively through the IPC
//      electronAPI mock (e2e/helpers/electronMock.ts: bootComboIPC /
//      installElectronMock + gotoApp). It must not intercept /api or /auth via
//      page.route, must not fetch() those paths directly, and must not reference
//      the removed Web-boot helpers (bootCombo / bootFinance).
//
//   2. source — App.tsx + services/ + components/ must not contain the removed
//      Web fallback: no `fetch('/api…')` / `fetch('/auth…')`, no `/auth/` REST
//      paths, no `API_BASE` constant, no `LoginPage` references. Every request
//      goes through `electronAPI.invoke('api:request', …)` (PR-3.8 removed the
//      Web auth gate, LoginPage, and the services/* fetch fallbacks). Note the
//      desktop capability helpers `isElectron()` / `isDesktop()` / `electronInvoke`
//      stay — they gate desktop-only IPC features, they are NOT a Web fallback.
//
// Line/block comments are stripped before matching so prose that merely mentions
// these patterns does not trip the guard.

import fs from 'node:fs';
import path from 'node:path';

const ROOT = process.cwd();
const E2E_DIR = path.join(ROOT, 'e2e');
// Source roots scanned for Web-fallback residue. App.tsx is a single root file;
// services/ and components/ are the only dirs that ever held a fetch() path.
const SRC_FILE_ROOTS = [path.join(ROOT, 'App.tsx')];
const SRC_DIR_ROOTS = [path.join(ROOT, 'services'), path.join(ROOT, 'components')];

function listFiles(dir) {
  const out = [];
  if (!fs.existsSync(dir)) return out;
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
// this guard: source/e2e has no // or /* sequences hidden inside string literals.
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

// e2e-boot residue: page.route web mocks, direct web fetch, removed Web-boot helpers.
const E2E_RULES = [
  { name: 'page.route web mock', re: /page\.route\(\s*['"`][^'"`]*\/(api|auth)\b/ },
  { name: 'direct web fetch', re: /fetch\(\s*['"`]\/(api|auth)\b/ },
  { name: 'removed Web-boot helper', re: /\b(bootCombo|bootFinance)\s*\(/ },
];

// Source-side Web-fallback residue (removed in PR-3.8). The bare `fetch('/api…')`
// rule does NOT match `apiFetch('/api/…')` (capital F is case-sensitive), so the
// many `apiFetch('/api/sales')`-style IPC calls are not flagged.
const SRC_RULES = [
  { name: 'source web fetch', re: /fetch\(\s*['"`]\/(api|auth)\b/ },
  { name: 'web /auth/ path', re: /['"`]\/auth\// },
  { name: 'removed API_BASE residue', re: /\bAPI_BASE\b/ },
  { name: 'removed LoginPage residue', re: /\bLoginPage\b/ },
];

function scan(files, rules) {
  const findings = [];
  for (const file of files) {
    const lines = fs.readFileSync(file, 'utf8').split('\n');
    const strip = makeStripper();
    lines.forEach((raw, idx) => {
      const code = strip(raw);
      for (const rule of rules) {
        if (rule.re.test(code)) {
          findings.push({ file: path.relative(ROOT, file), line: idx + 1, rule: rule.name, text: raw.trim() });
        }
      }
    });
  }
  return findings;
}

if (!fs.existsSync(E2E_DIR)) {
  console.error(`check:no-web-fetch — e2e/ not found at ${E2E_DIR}`);
  process.exit(1);
}

const srcFiles = [
  ...SRC_FILE_ROOTS.filter((f) => fs.existsSync(f)),
  ...SRC_DIR_ROOTS.flatMap(listFiles),
];

const e2eFindings = scan(listFiles(E2E_DIR), E2E_RULES);
const srcFindings = scan(srcFiles, SRC_RULES);
const findings = [...e2eFindings, ...srcFindings];

console.log('=== check:no-web-fetch (desktop-only boot guard) ===');
if (findings.length === 0) {
  console.log('✓ e2e boots exclusively through the IPC electronAPI mock.');
  console.log('✓ source (App.tsx / services / components) has no Web fetch/auth/API_BASE/LoginPage residue.');
  process.exit(0);
}
for (const f of findings) console.error(`  ${f.file}:${f.line} [${f.rule}] ${f.text}`);
console.error(`\n✗ ${findings.length} Web-boot/fallback residue(s) found.`);
console.error('  e2e: boot via e2e/helpers/electronMock.ts (bootComboIPC / installElectronMock + gotoApp).');
console.error('  source: route every request through electronAPI.invoke(\'api:request\', …); no fetch()/auth path.');
process.exit(1);
