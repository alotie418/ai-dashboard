#!/usr/bin/env node
// Swift warning gate for the native package.
//
// Baseline = 0, by FINGERPRINT rather than by count: every accepted warning is an
// entry in native/SoloLedger/warning-baseline.json matched on file + message
// pattern (never on a line number, so edits above a warning do not invalidate it).
//
// Two directions are enforced, and the second is the one that matters:
//   1. A warning that matches no entry FAILS — new warnings are a signal.
//   2. An entry that matches NOTHING also fails, telling you to remove it. So a
//      warning that disappears (a toolchain fix, a rewrite) can never linger as a
//      permanently-accepted exception, and a compiler upgrade that resolves a
//      false positive surfaces by itself instead of being waited for.
//
// Usage: node scripts/check-swift-warnings.mjs
//   Locally this machine needs DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
//   (xcode-select points at the CLT); CI's macOS image needs nothing.
import { spawnSync } from 'node:child_process';
import { readFileSync, rmSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join, relative } from 'node:path';
import { tmpdir } from 'node:os';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const PKG = join(ROOT, 'native/SoloLedger');
const BASELINE = join(PKG, 'warning-baseline.json');

const baseline = JSON.parse(readFileSync(BASELINE, 'utf8'));
const entries = baseline.entries ?? [];

/// Build and return stdout+stderr combined — swiftc writes diagnostics to stderr.
function build(scratch) {
  const args = ['build', '--package-path', PKG, '--build-tests'];
  if (scratch) args.push('--scratch-path', scratch);
  const r = spawnSync('swift', args, { encoding: 'utf8', maxBuffer: 128 * 1024 * 1024 });
  if (r.error) {
    console.error(`check-swift-warnings: could not run swift (${r.error.message})`);
    process.exit(1);
  }
  const out = `${r.stdout ?? ''}${r.stderr ?? ''}`;
  if (r.status !== 0) {
    console.error(out);
    console.error('check-swift-warnings: swift build failed — fix the build first');
    process.exit(1);
  }
  return out;
}

// ALWAYS build from a throwaway scratch path. An incremental build only
// recompiles what changed, so warnings from untouched files are simply not
// re-emitted — which this gate would read as "the warning is gone" and, thanks to
// the stale-entry check, report as a spurious failure. (That is exactly how this
// line got written: the first version reused the existing build directory and
// declared a live baseline entry stale.) A full build is the only reading that
// does not depend on what happened to be compiled last.
const scratch = join(tmpdir(), `swift-warning-gate-${process.pid}`);
rmSync(scratch, { recursive: true, force: true });
let output;
try {
  output = build(scratch);
} finally {
  rmSync(scratch, { recursive: true, force: true });
}

// /abs/path/File.swift:914:13: warning: message text [#category]
const re = /^(\/[^\s:]+\.swift):(\d+):(\d+): warning: (.+)$/gm;
const found = [];
for (const m of output.matchAll(re)) {
  const file = relative(PKG, m[1]);
  const message = m[4].replace(/\s*\[#[\w-]+\]\s*$/, '').trim();
  if (!found.some((f) => f.file === file && f.message === message)) {
    found.push({ file, line: Number(m[2]), message });
  }
}

const matches = (w, e) => w.file === e.file && w.message.includes(e.messagePattern);
const unexpected = found.filter((w) => !entries.some((e) => matches(w, e)));
const stale = entries.filter((e) => !found.some((w) => matches(w, e)));

let failed = false;
if (unexpected.length) {
  failed = true;
  console.error(`\n✗ ${unexpected.length} warning(s) outside the baseline:`);
  for (const w of unexpected) console.error(`    ${w.file}:${w.line}: ${w.message}`);
  console.error('  Fix them, or — only with evidence that the warning itself is wrong —');
  console.error(`  add an entry to ${relative(ROOT, BASELINE)}.`);
}
if (stale.length) {
  failed = true;
  console.error(`\n✗ ${stale.length} baseline entr(y|ies) matched nothing and must be removed:`);
  for (const e of stale) console.error(`    ${e.id} (${e.file}: ${e.messagePattern})`);
  console.error('  The warning is gone — delete the entry so the baseline stays honest.');
}
if (failed) process.exit(1);

console.log(`✓ swift warnings: ${found.length} found, all covered by ${entries.length} baseline entr` +
            `${entries.length === 1 ? 'y' : 'ies'}`);
