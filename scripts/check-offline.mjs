#!/usr/bin/env node
// Offline guard (PR-D): the packaged desktop app must be fully self-contained — zero
// runtime CDN dependencies — so the DMG renders correctly with no network. Fails if any
// banned asset-CDN host appears in the HTML entry, app source, or the built dist/index.html.
//
// Tailwind / Font Awesome / github-markdown-css / Inter are bundled at build time
// (tailwind.config.ts + index.tsx CSS imports); react / react-dom / recharts are bundled
// by Vite. Keep it that way — re-adding a <script>/<link> to a CDN breaks offline use.
//
// NOTE: runtime *API* endpoints (e.g. generativelanguage.googleapis.com, the Cloudflare
// Worker) are network calls, not asset CDNs, and are intentionally NOT banned here.
//
// scripts/ is excluded so this file's own pattern strings don't self-match; app code must
// therefore never write these hostnames literally in comments (describe them in prose).

import { readdir, readFile, stat } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join, relative } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = join(__dirname, '..');

const SKIP_DIRS = new Set([
  'node_modules', 'dist', 'release', 'test-results', 'build', 'scripts', 'e2e', '.git', '.claude',
]);
const EXTS = ['.ts', '.tsx', '.css', '.html', '.js'];

// Asset CDNs that must never be loaded at runtime (the migrated dependencies).
const BANNED = [
  { name: 'Tailwind Play CDN', re: /cdn\.tailwindcss\.com/i },
  { name: 'cdnjs (Font Awesome / markdown-css)', re: /cdnjs\.cloudflare\.com/i },
  { name: 'esm.sh module CDN', re: /esm\.sh/i },
  { name: 'Google Fonts CSS', re: /fonts\.googleapis\.com/i },
  { name: 'Google Fonts files', re: /fonts\.gstatic\.com/i },
  { name: 'jsDelivr CDN', re: /cdn\.jsdelivr\.net/i },
  { name: 'unpkg CDN', re: /unpkg\.com/i },
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

async function scanFile(filepath, label) {
  const rel = label || relative(ROOT, filepath);
  let text;
  try { text = await readFile(filepath, 'utf8'); } catch { return; }
  const lines = text.split('\n');
  for (let i = 0; i < lines.length; i++) {
    for (const b of BANNED) {
      if (b.re.test(lines[i])) {
        findings.push({ file: rel, line: i + 1, name: b.name, text: lines[i].trim().slice(0, 120) });
      }
    }
  }
}

console.log('=== Offline Guard (no runtime CDN) ===\n');

let scanned = 0;
for await (const f of walk(ROOT)) { await scanFile(f); scanned++; }

// Also scan the built entry HTML directly — the real offline proof — if present.
const distIndex = join(ROOT, 'dist', 'index.html');
try {
  await stat(distIndex);
  await scanFile(distIndex, 'dist/index.html');
  scanned++;
  console.log('Included built dist/index.html in scan.');
} catch {
  console.log('(dist/index.html not built yet — run `npm run build` first to verify the packaged output too.)');
}

console.log(`Scanned: ${scanned} files`);
console.log(`Findings: ${findings.length}\n`);

if (findings.length) {
  for (const f of findings) {
    console.error(`  ✗ ${f.file}:${f.line} — ${f.name}\n      ${f.text}`);
  }
  console.error('\n❌ Runtime CDN reference(s) found. The packaged app would break offline.');
  console.error('   Bundle the dependency at build time instead of loading it from a CDN.');
  process.exit(1);
}

console.log('✓ No runtime CDN references — the app is fully self-contained and works offline.');
