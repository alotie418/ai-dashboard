#!/usr/bin/env node
// Theme guard (PR-C): the legacy orange-red brand palette must stay fully
// migrated to the deep-tech-blue `primary` token / THEME constants. Fails if any
// of the old orange values reappear in app source.
//
// Only the specific orange hexes/rgba are banned — semantic colors
// (emerald #10b981 / amber #f59e0b / violet #8b5cf6 / blue #3b82f6 / rose) and
// the warm neutral palette (#191918 / #e0ddd5 / #f9f9f8 …) are intentionally
// NOT touched, so this guard never fires on them.
//
// scripts/ is excluded so this file's own pattern strings don't self-match.

import { readdir, readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join, relative } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = join(__dirname, '..');

const SKIP_DIRS = new Set([
  'node_modules', 'dist', 'release', 'test-results', 'build', 'scripts', 'e2e', '.git', '.claude',
]);
const EXTS = ['.ts', '.tsx', '.css', '.html'];

// The migrated orange-red family — must have zero residue.
const BANNED = [
  { name: 'orange primary #d97757', re: /#d97757/i },
  { name: 'orange hover #c56a4a', re: /#c56a4a/i },
  { name: 'orange hover #c4694d', re: /#c4694d/i },
  { name: 'orange hover #c56646', re: /#c56646/i },
  { name: 'orange light #e8956e', re: /#e8956e/i },
  { name: 'orange glow rgba(217,119,87,*)', re: /rgba\(\s*217\s*,\s*119\s*,\s*87/i },
];

const findings = [];

async function* walk(dir) {
  for (const ent of await readdir(dir, { withFileTypes: true })) {
    if (ent.name.startsWith('.') || SKIP_DIRS.has(ent.name)) continue;
    const p = join(dir, ent.name);
    if (ent.isDirectory()) yield* walk(p);
    else if (EXTS.some(e => ent.name.endsWith(e))) yield p;
  }
}

async function scanFile(filepath) {
  const rel = relative(ROOT, filepath);
  const lines = (await readFile(filepath, 'utf8')).split('\n');
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (!line) continue;
    for (const rule of BANNED) {
      if (rule.re.test(line)) {
        findings.push({ file: rel, line: i + 1, type: rule.name, snippet: line.trim().slice(0, 120) });
      }
    }
  }
}

async function main() {
  let scanned = 0;
  for await (const f of walk(ROOT)) { await scanFile(f); scanned++; }

  console.log(`\n=== Theme Guard (no legacy orange) ===\n`);
  console.log(`Scanned: ${scanned} files (.ts/.tsx/.css/.html)`);
  console.log(`Findings: ${findings.length}\n`);

  if (findings.length === 0) {
    console.log('✓ No legacy orange (#d97757 / #c56a4a / #c4694d / #c56646 / #e8956e / rgba(217,119,87)) remains.');
    process.exit(0);
  }

  const byFile = {};
  for (const f of findings) (byFile[f.file] ||= []).push(f);
  for (const [file, items] of Object.entries(byFile)) {
    console.log(`--- ${file} ---`);
    for (const it of items) {
      console.log(`  L${it.line} [${it.type}]`);
      console.log(`    ${it.snippet}`);
    }
  }
  console.log(`\n✗ ${findings.length} legacy-orange residue(s) — migrate to the primary token / THEME constants.`);
  process.exit(1);
}

main().catch(e => { console.error('Theme guard crashed:', e); process.exit(2); });
