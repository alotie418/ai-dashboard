#!/usr/bin/env node
// Static i18n key resolution guard.
//
// Heuristic: extract every STATIC t('namespace.key') call from the frontend
// source and assert the key resolves (present + non-empty) in the fallback
// locale (zh-CN). A t() call is correct in source but renders the RAW KEY in
// the UI when the key is missing from every locale file — exactly how
// accounts.modal*, accounts.aging* and analysis.loading* leaked (the existing
// check-raw-key-leaks.mjs only pins a narrow invoices.* whitelist, so a generic
// gap stayed invisible). This generalises that cross-check to ALL static t()
// keys.
//
// Why only zh-CN: i18n/index.ts sets fallbackLng: 'zh-CN'. A key present in
// zh-CN but missing in en/ja/ko/fr/zh-TW only falls back to Chinese (a locale
// parity concern, guarded elsewhere). A RAW KEY LEAK happens only when the key
// is missing from the fallback too — so asserting presence in zh-CN is exactly
// the raw-key-leak preventer.
//
// Known limits (by design): only static single/double-quoted literals are
// checked. Dynamic keys (template literals `t(`a.${x}`)`, variables, or string
// concatenation t('a.'+x)) are skipped — the codebase builds dynamic keys with
// backtick templates, which never leak a single fixed raw key. t() calls that
// pass a defaultValue are also skipped (a missing key renders the default, not
// the raw key).

import { readFileSync, readdirSync, statSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join, relative } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = join(__dirname, '..');

// Frontend source where react-i18next t() is used.
const SCAN_DIRS = ['components'];
const SCAN_FILES = ['App.tsx', 'index.tsx'];
const EXTS = ['.ts', '.tsx'];

const FALLBACK_LOCALE = 'zh-CN';

// Match a static t('ns.key') / t("ns.key") call (key must contain at least one
// dot). Negative lookbehind avoids matching fmt(, art(, obj.t(, etc.
const T_CALL = /(?<![\w.])t\(\s*(['"])([A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+)\1/g;

// ── Build the set of resolvable keys from the fallback locale ──
function flatten(obj, prefix, out) {
  for (const k of Object.keys(obj)) {
    const v = obj[k];
    const path = prefix ? `${prefix}.${k}` : k;
    if (v && typeof v === 'object' && !Array.isArray(v)) {
      flatten(v, path, out);
    } else {
      out.set(path, v);
    }
  }
}

const fallbackDict = JSON.parse(
  readFileSync(join(ROOT, 'i18n/locales', `${FALLBACK_LOCALE}.json`), 'utf8'),
);
const resolvable = new Map();
flatten(fallbackDict, '', resolvable);

function resolves(key) {
  if (!resolvable.has(key)) return false;
  const v = resolvable.get(key);
  return typeof v === 'string' && v.trim() !== '';
}

// ── Collect frontend source files ──
function walk(dir) {
  let files = [];
  for (const ent of readdirSync(dir, { withFileTypes: true })) {
    if (ent.name.startsWith('.') || ent.name === 'node_modules' || ent.name === 'dist') continue;
    const p = join(dir, ent.name);
    if (ent.isDirectory()) files = files.concat(walk(p));
    else if (EXTS.some(e => ent.name.endsWith(e))) files.push(p);
  }
  return files;
}

const sourceFiles = [];
for (const d of SCAN_DIRS) {
  const full = join(ROOT, d);
  try { if (statSync(full).isDirectory()) sourceFiles.push(...walk(full)); } catch { /* skip */ }
}
for (const f of SCAN_FILES) {
  const full = join(ROOT, f);
  try { if (statSync(full).isFile()) sourceFiles.push(full); } catch { /* skip */ }
}

// ── Scan ──
const missing = []; // { key, file, line }
for (const file of sourceFiles) {
  const rel = relative(ROOT, file);
  const lines = readFileSync(file, 'utf8').split('\n');
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (!line) continue;
    const trimmed = line.trimStart();
    if (trimmed.startsWith('//') || trimmed.startsWith('*')) continue; // comment line
    T_CALL.lastIndex = 0;
    let m;
    while ((m = T_CALL.exec(line)) !== null) {
      const key = m[2];
      // Skip when this t() call supplies a defaultValue (missing key renders the default).
      const rest = line.slice(m.index, m.index + 200);
      if (rest.includes('defaultValue')) continue;
      if (!resolves(key)) missing.push({ key, file: rel, line: i + 1 });
    }
  }
}

console.log('\n=== i18n Static Key Resolution Guard ===\n');
console.log(`Fallback locale : ${FALLBACK_LOCALE}.json (${resolvable.size} leaf keys)`);
console.log(`Scanned         : ${SCAN_DIRS.join(', ')}, ${SCAN_FILES.join(', ')} (${sourceFiles.length} files)`);
console.log(`Missing keys    : ${missing.length}\n`);

if (missing.length === 0) {
  console.log(`✓ Every static t('...') key resolves in ${FALLBACK_LOCALE}.json — no raw-key leaks.`);
  process.exit(0);
}

// Group by key (a key may be referenced from several sites).
const byKey = new Map();
for (const it of missing) {
  if (!byKey.has(it.key)) byKey.set(it.key, []);
  byKey.get(it.key).push(`${it.file}:${it.line}`);
}
console.log(`✗ ${byKey.size} key(s) referenced via t() but missing/empty in ${FALLBACK_LOCALE}.json (would render the raw key in the UI):\n`);
for (const [key, locs] of [...byKey].sort()) {
  console.log(`  ${key}`);
  console.log(`      <- ${locs.join(', ')}`);
}
console.log('');
process.exit(1);
