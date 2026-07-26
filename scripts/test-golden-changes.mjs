#!/usr/bin/env node
// Pins the three semantics of the golden-change allowlist
// (docs/SWIFTUI_REPORTS_MIRROR_PLAN.md §3.2). Pure — no git, no filesystem.
//
// Run: node scripts/test-golden-changes.mjs
import { evaluate, declaredPatterns, matchesPattern, goldenNames, TRAILER, GOLDENS_DIR }
  from './check-golden-changes.mjs';

let failures = 0;
function check(name, actual, expected) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a === e) return;
  failures++;
  console.error(`✗ ${name}\n    expected ${e}\n    actual   ${a}`);
}
const golden = (n) => `${GOLDENS_DIR}/${n}.json`;
const trailer = (v) => `some subject\n\nbody text\n\n${TRAILER}: ${v}\n`;

// --- semantic 3: no trailer = empty set = nothing may change -----------------
// Listed first because it is the DEFAULT, and the normal state of a mirroring PR.
check('no trailer, no golden touched → ok',
  evaluate({ changedPaths: ['src/x.swift'], commitMessages: ['plain commit'] }).ok, true);

check('no trailer, a golden touched → fails',
  evaluate({ changedPaths: [golden('unset-US-2025')], commitMessages: ['plain commit'] }).ok, false);

check('no trailer, the undeclared list names the golden',
  evaluate({ changedPaths: [golden('unset-US-2025')], commitMessages: ['plain'] }).undeclared,
  ['unset-US-2025']);

// A trailer-shaped string that is NOT a trailer must not count.
check('a mention of the trailer name in prose does not declare anything',
  evaluate({ changedPaths: [golden('unset-US-2025')],
             commitMessages: ['we should add an Allowed-Golden-Changes trailer later'] }).ok, false);

// --- semantic 1: trailers from every commit are unioned ----------------------
check('two commits, two trailers → union covers both',
  evaluate({
    changedPaths: [golden('unset-US-2025'), golden('malformed-CN-2025')],
    commitMessages: [trailer('unset-*'), trailer('malformed-*')],
  }).ok, true);

check('union: a third golden outside both still fails',
  evaluate({
    changedPaths: [golden('unset-US-2025'), golden('base-CN-2025')],
    commitMessages: [trailer('unset-*'), trailer('malformed-*')],
  }).undeclared, ['base-CN-2025']);

check('one trailer may list several patterns, comma or space separated',
  [...declaredPatterns([trailer('unset-*, malformed-*  zero-CN-2025')])].sort(),
  ['malformed-*', 'unset-*', 'zero-CN-2025']);

// --- semantic 2: a declaration is an upper bound, not an obligation ----------
check('declaring a series and changing nothing → ok',
  evaluate({ changedPaths: ['docs/plan.md'], commitMessages: [trailer('unset-*')] }).ok, true);

check('declaring a series and changing only part of it → ok',
  evaluate({ changedPaths: [golden('unset-US-2025')], commitMessages: [trailer('unset-*')] }).ok, true);

check('declaring one series while changing another → fails',
  evaluate({ changedPaths: [golden('base-CN-2025')], commitMessages: [trailer('unset-*')] }).ok, false);

// --- pattern matching -------------------------------------------------------
check('* matches a run of characters', matchesPattern('unset-US-2025', 'unset-*'), true);
check('anchored at the front', matchesPattern('xunset-US-2025', 'unset-*'), false);
check('anchored at the end', matchesPattern('unset-US-2025-extra', 'unset-US-2025'), false);
check('bare * allows everything', matchesPattern('anything-at-all', '*'), true);
check('a wildcard in the middle works', matchesPattern('unset-US-2025', 'unset-*-2025'), true);
check('several wildcards work', matchesPattern('unset-US-2025', '*-US-*'), true);

// A declaration must not be able to mean more than it looks like it means.
check('regex metacharacters are literal, not regex',
  matchesPattern('unset-US-2025', 'unset.US.2025'), false);
check('a dot is a literal dot', matchesPattern('aXb', 'a.b'), false);
check('brackets are literal', matchesPattern('a', '[ab]'), false);

// --- path handling ----------------------------------------------------------
check('only files under the goldens dir count',
  goldenNames([golden('base-CN-2025'), 'other/dir/base-CN-2025.json', 'README.md']),
  ['base-CN-2025']);

check('non-json files under the goldens dir are ignored',
  goldenNames([`${GOLDENS_DIR}/notes.txt`]), []);

// GOLDEN_ENV.json lives beside the goldens and describes them, so it is subject to
// the same rule — changing it silently would let a fixture or runtime swap through.
check('GOLDEN_ENV.json is treated as a golden',
  evaluate({ changedPaths: [golden('GOLDEN_ENV')], commitMessages: ['plain'] }).undeclared,
  ['GOLDEN_ENV']);

if (failures) {
  console.error(`\n${failures} golden-allowlist semantic(s) broken`);
  process.exit(1);
}
console.log('✓ golden-change allowlist: all semantics hold');
