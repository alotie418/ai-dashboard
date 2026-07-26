#!/usr/bin/env node
// Golden-change allowlist. Runs inside the existing "Report goldens reproducible"
// job, right after the reproducibility diff — see docs/SWIFTUI_REPORTS_MIRROR_PLAN.md §3.2.
//
// The goldens are the ground truth the native report mirror is measured against, so a
// mirroring PR must not move them: if the Swift output disagrees, the Swift output is
// what is wrong. Only a deliberate, separately-labelled correction may change them, and
// only the series it declares up front.
//
// DECLARATION — a commit trailer in the PR:
//
//     Allowed-Golden-Changes: unset-*
//
// A trailer was chosen over a committed list file or the PR body because it travels with
// the commit SHA (so it is covered by "authorization is void if the head SHA moved"),
// it is visible in review, and it leaves nothing behind on main — the list is empty
// there structurally, not by a guard that has to clean up.
//
// SEMANTICS (pinned by scripts/test-golden-changes.mjs):
//   1. Trailers from every commit in the range are UNIONED.
//   2. A declaration is an UPPER BOUND, not an obligation — declaring a series and
//      changing nothing passes; changing anything outside the declared set fails.
//   3. No trailer = empty set = no golden may change. This is the default, and the
//      normal state of a mirroring PR.
//
// Patterns are matched against the golden's basename without .json, with `*` meaning
// "any run of characters" and nothing else — no regex, no path traversal. `*` alone
// therefore allows every golden, which is what the PR that first created them used.
import { execFileSync } from 'node:child_process';
import { realpathSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

export const TRAILER = 'Allowed-Golden-Changes';
export const GOLDENS_DIR = 'native/SoloLedger/Tests/SoloLedgerCoreTests/Fixtures/reports/goldens';

/// Every pattern declared by the trailers in `commitMessages`, unioned. Values may be
/// comma- or whitespace-separated; an empty declaration contributes nothing.
export function declaredPatterns(commitMessages) {
  const out = new Set();
  const re = new RegExp(`^\\s*${TRAILER}\\s*:\\s*(.+)$`, 'gim');
  for (const message of commitMessages) {
    for (const m of message.matchAll(re)) {
      for (const token of m[1].split(/[,\s]+/)) {
        const t = token.trim();
        if (t) out.add(t);
      }
    }
  }
  return out;
}

/// Glob with a single wildcard character, anchored at both ends. Deliberately not a
/// regex: a declaration is read by humans in review and must not be able to mean more
/// than it looks like it means.
export function matchesPattern(name, pattern) {
  // Split on the wildcard FIRST, then escape each literal piece — no sentinel
  // character is involved, so no pattern can collide with one.
  const escape = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  return new RegExp(`^${pattern.split('*').map(escape).join('.*')}$`).test(name);
}

/// The golden names a change set touches — basenames, no directory, no .json.
export function goldenNames(changedPaths) {
  return changedPaths
    .filter((p) => p.startsWith(`${GOLDENS_DIR}/`) && p.endsWith('.json'))
    .map((p) => p.slice(GOLDENS_DIR.length + 1, -'.json'.length));
}

/// The verdict, as pure data so the semantics can be tested without git.
export function evaluate({ changedPaths, commitMessages }) {
  const patterns = [...declaredPatterns(commitMessages)];
  const touched = goldenNames(changedPaths);
  const undeclared = touched.filter((n) => !patterns.some((p) => matchesPattern(n, p)));
  return { patterns, touched, undeclared, ok: undeclared.length === 0 };
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------
const isMain = process.argv[1] &&
  realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url));
if (isMain) {
  const git = (args) => execFileSync('git', args, { encoding: 'utf8' }).trim();

  // The base to compare against. On a PR, GitHub gives us the target branch; locally,
  // origin/main is the sane default.
  const baseRef = process.env.GOLDEN_BASE_REF || 'origin/main';
  let range;
  try {
    const mergeBase = git(['merge-base', baseRef, 'HEAD']);
    range = `${mergeBase}..HEAD`;
  } catch {
    console.error(`check-golden-changes: cannot resolve a merge base with ${baseRef}.`);
    console.error('  The job needs the base branch fetched (checkout with fetch-depth: 0).');
    process.exit(1);
  }

  const changedPaths = git(['diff', '--name-only', range]).split('\n').filter(Boolean);
  // NUL-separated: commit messages contain blank lines, so nothing else is a safe
  // record separator.
  const commitMessages = git(['log', '--format=%B%x00', range])
    .split(String.fromCharCode(0)).filter((s) => s.trim());
  const { patterns, touched, undeclared, ok } = evaluate({ changedPaths, commitMessages });

  if (!touched.length) {
    console.log('✓ golden changes: none');
    process.exit(0);
  }
  if (ok) {
    console.log(`✓ golden changes: ${touched.length} file(s), all within the declared set ` +
                `[${patterns.join(', ')}]`);
    process.exit(0);
  }

  console.error(`\n✗ ${undeclared.length} golden(s) changed without being declared:`);
  for (const n of undeclared.sort()) console.error(`    ${n}`);
  console.error(patterns.length
    ? `\n  Declared: [${patterns.join(', ')}]`
    : '\n  Declared: nothing — no trailer found in this PR.');
  console.error(`\n  The goldens are the ground truth the report mirror is measured against.`);
  console.error('  A mirroring PR must not move them: if the Swift output disagrees, the');
  console.error('  Swift output is what is wrong.');
  console.error('\n  If this change is a deliberate, separately-labelled correction, declare');
  console.error('  the series it may touch with a commit trailer, e.g.');
  console.error(`\n      ${TRAILER}: unset-*\n`);
  process.exit(1);
}
