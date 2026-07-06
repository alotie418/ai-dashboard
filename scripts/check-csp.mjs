#!/usr/bin/env node
// CSP guard (feat/csp-enforce): the production bundle must carry EXACTLY the meta CSP
// injected by vite.config.ts's inject-csp-meta plugin (policy rationale: docs/CSP_PLAN.md §3),
// and the SOURCE index.html must carry none (CSP is build-only — a hardcoded meta in the
// dev source would break Vite HMR, which needs inline script/eval/ws://).
//
// Asserts:
//   1. source index.html contains NO CSP meta (always checked, no build needed);
//   2. dist/index.html contains exactly ONE CSP meta;
//   3. its directive set EQUALS the expected set below — no missing directive, and no
//      extra/loosened one (e.g. an accidental 'unsafe-eval' in script-src fails the set match).
// If dist/ is not built yet, mirrors check-offline: warn + soft-pass (source check still runs);
// run `npm run build` first to verify the packaged output too.

import { readFile, stat } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = join(__dirname, '..');

// Must stay in lockstep with CSP_POLICY in vite.config.ts (single source of truth for the
// POLICY is vite.config.ts; this guard pins the expected shape so drift fails loudly).
const EXPECTED_DIRECTIVES = [
  "default-src 'self'",
  "script-src 'self'",
  "style-src 'self' 'unsafe-inline'",
  "img-src 'self' data: blob:",
  "font-src 'self'",
  "connect-src 'self'",
  "worker-src 'self' blob:",
  "object-src 'none'",
  "base-uri 'self'",
  "form-action 'none'",
];

const CSP_META_RE = /<meta[^>]+http-equiv=["']Content-Security-Policy["'][^>]*>/gi;
const CONTENT_RE = /content=["']([^"']*)["']/i;

let failures = 0;
const fail = (msg) => { failures += 1; console.error(`✗ ${msg}`); };
const ok = (msg) => console.log(`✓ ${msg}`);

// ---- 1. source index.html must have NO CSP meta ----
const srcHtml = await readFile(join(ROOT, 'index.html'), 'utf8');
const srcMetas = srcHtml.match(CSP_META_RE) ?? [];
if (srcMetas.length === 0) {
  ok('source index.html carries no CSP meta (build-only injection preserved — dev/HMR safe)');
} else {
  fail(`source index.html contains ${srcMetas.length} CSP meta tag(s) — CSP must be injected at build time only (vite.config.ts inject-csp-meta), never hardcoded in the dev source`);
}

// ---- 2+3. dist/index.html must have exactly one CSP meta with the exact directive set ----
const distIndex = join(ROOT, 'dist', 'index.html');
try {
  await stat(distIndex);
  const distHtml = await readFile(distIndex, 'utf8');
  const metas = distHtml.match(CSP_META_RE) ?? [];
  if (metas.length !== 1) {
    fail(`dist/index.html: expected exactly 1 CSP meta, found ${metas.length} — is the inject-csp-meta plugin wired (vite.config.ts) and the build fresh?`);
  } else {
    ok('dist/index.html carries exactly one CSP meta');
    // Vite's tag injection HTML-escapes attribute values ('/" → &#39;/&quot;). The browser's
    // HTML parser decodes them BEFORE the CSP parser runs, so compare the DECODED policy —
    // exactly what the browser enforces. (&amp; last, so it can't create new entities.)
    const rawContent = metas[0].match(CONTENT_RE)?.[1] ?? '';
    const content = rawContent
      .replace(/&#39;|&apos;/g, "'")
      .replace(/&quot;/g, '"')
      .replace(/&amp;/g, '&');
    const actual = content.split(';').map((d) => d.trim().replace(/\s+/g, ' ')).filter(Boolean);
    const actualSet = new Set(actual);
    const expectedSet = new Set(EXPECTED_DIRECTIVES);
    const missing = EXPECTED_DIRECTIVES.filter((d) => !actualSet.has(d));
    const extra = actual.filter((d) => !expectedSet.has(d));
    if (missing.length === 0 && extra.length === 0) {
      ok(`policy directive set matches exactly (${EXPECTED_DIRECTIVES.length} directives; script-src has no unsafe-eval/unsafe-inline)`);
    } else {
      for (const d of missing) fail(`dist CSP missing directive: "${d}"`);
      for (const d of extra) fail(`dist CSP has unexpected/loosened directive: "${d}" — update EXPECTED_DIRECTIVES here AND docs/CSP_PLAN.md if this is intentional`);
    }
  }
} catch {
  console.log('⚠ dist/index.html not built yet — run `npm run build` first to verify the injected CSP (source check above still ran).');
}

if (failures > 0) {
  console.error(`\ncheck:csp FAILED with ${failures} problem(s).`);
  process.exit(1);
}
console.log('\n✓ check:csp passed');
