#!/usr/bin/env node
// Thin wrapper around the UI-audit Playwright smoke harness.
//
//   npm run audit:locale-ui:smoke   → node scripts/audit-locale-ui.mjs --smoke
//   npm run audit:locale-ui         → node scripts/audit-locale-ui.mjs --full
//
// It (1) builds the SPA if dist/ is missing (vite preview serves dist/), (2) runs
// `playwright test --config playwright.audit.config.ts` (the spec writes report.md +
// summary.json + screenshots under artifacts/ui-audit/<ts>/), then (3) reads the
// newest summary.json and prints a merge-advice banner.
//
// Phase 1: --full is a STUB — it runs the same smoke scope and prints a notice. Full
// coverage (all 6 UI langs × 6 accounting locales, all pages, heuristics) is a later PR.
//
// Exit code: advisory by default (0 even with findings, so it stays usable in the
// verification flow and surfaces — not hides — known issues). Pass --strict to exit
// non-zero when merge advice is BLOCK (for future CI gating; not wired into check:all).

import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = join(__dirname, '..');

const args = process.argv.slice(2);
const mode = args.includes('--full') ? 'full' : 'smoke';
const strict = args.includes('--strict');
const noBuild = args.includes('--no-build');
const forceBuild = args.includes('--build');

function run(cmd, cmdArgs, extraEnv = {}) {
  return spawnSync(cmd, cmdArgs, { cwd: ROOT, stdio: 'inherit', env: { ...process.env, ...extraEnv }, shell: false });
}

console.log(`\n=== UI Audit (${mode}) ===`);
if (mode === 'full') {
  console.log('Note: --full is a phase-1 STUB — it runs the smoke scope. Full coverage is a later PR.');
}

// 1. Ensure the SPA is built (vite preview serves dist/).
const distIndex = join(ROOT, 'dist', 'index.html');
if (forceBuild || (!noBuild && !existsSync(distIndex))) {
  console.log('Building SPA (vite build) — dist/ missing or --build given…');
  const b = run('npm', ['run', 'build']);
  if (b.status !== 0) {
    console.error('✗ build failed; aborting audit.');
    process.exit(b.status ?? 2);
  }
} else {
  console.log(`Reusing existing build at dist/ (pass --build to force a rebuild).`);
}

// 2. Run the audit spec.
const pw = run('npx', ['playwright', 'test', '--config', 'playwright.audit.config.ts'], { AUDIT_MODE: mode });
// status is null when the command itself could not run (e.g. npx ENOENT); treat that
// as a hard failure (2), never a silent success — mirrors the build step above.
const pwStatus = pw.status ?? 2;

// 3. Read the newest summary.json and print a merge-advice banner.
const auditRoot = join(ROOT, 'artifacts', 'ui-audit');
function newestSummary() {
  if (!existsSync(auditRoot)) return null;
  const dirs = readdirSync(auditRoot)
    .map((d) => join(auditRoot, d))
    .filter((p) => {
      try { return statSync(p).isDirectory() && existsSync(join(p, 'summary.json')); } catch { return false; }
    })
    .sort();
  if (dirs.length === 0) return null;
  const dir = dirs[dirs.length - 1];
  try { return { dir, summary: JSON.parse(readFileSync(join(dir, 'summary.json'), 'utf8')) }; } catch { return null; }
}

const found = newestSummary();
if (!found) {
  console.error('\n✗ No summary.json produced — the audit spec did not complete. See Playwright output above.');
  process.exit(pwStatus !== 0 ? pwStatus : 2);
}

const { dir, summary } = found;
const c = summary.counts;
console.log('\n==================== UI AUDIT SUMMARY ====================');
console.log(` Mode          : ${summary.mode}`);
console.log(` Pages scanned : ${c.pagesScanned}`);
console.log(` Combos        : ${c.combos}  (${summary.scope.uiLanguages.join('/')} × ${summary.scope.accountingLocales.join('/')})`);
console.log(` Modals        : ${c.modals}`);
console.log(` Findings      : ${c.findings}   (P0=${c.P0} P1=${c.P1} P2=${c.P2} P3=${c.P3})`);
console.log(` Hard fail     : ${c.hardFail}`);
console.log(` Merge advice  : ${summary.mergeAdvice}`);
console.log(` Report        : ${join(dir, 'report.md')}`);
console.log(` Summary JSON  : ${join(dir, 'summary.json')}`);
console.log('=========================================================');
console.log(' Advice: BLOCK = confident P0/P1 present · REVIEW = only P2/P3 · PASS = clean.');
console.log(' Findings are recorded for triage; this PR establishes the framework and does not fix them.');

if (pwStatus !== 0) {
  // Playwright itself failed (infra / a thrown spec) — surface it regardless of advice.
  console.error(`\n✗ Playwright exited ${pwStatus} (spec/infra failure). See output above.`);
  process.exit(pwStatus);
}
if (strict && summary.mergeAdvice === 'BLOCK') {
  console.error('\n✗ --strict: merge advice is BLOCK (confident P0/P1). Exiting non-zero.');
  process.exit(1);
}
process.exit(0);
