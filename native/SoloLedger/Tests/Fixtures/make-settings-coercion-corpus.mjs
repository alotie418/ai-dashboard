#!/usr/bin/env node
// Records what ELECTRON does to a `settings` value on the way into a report, so the Swift
// mirror can be checked against measured behaviour instead of against a belief about it.
//
//   write:  ELECTRON_RUN_AS_NODE=1 ./node_modules/.bin/electron \
//             native/SoloLedger/Tests/Fixtures/make-settings-coercion-corpus.mjs
//   gate:   npm run check:settings-coercion       (adds --verify)
//
// ## WHY THE LOCKED ELECTRON AND NOT PLAIN `node`
//
// The two runtimes in this repo do NOT share a V8:
//
//     node      v24.18.0   V8 13.6.233.17-node.50
//     electron  42.6.0     V8 14.8.178.38-electron.0
//
// Every measurement here is a claim about what the SHIPPING PRODUCT does. Plain `node`
// can only demonstrate an ECMAScript implementation's result; it cannot stand in for the
// V8 the product actually runs. The samples happen to agree today — measured, all of
// them — but agreement is an observation, not a contract, and a corpus recorded under
// the wrong binary would be named after a runtime it never touched.
//
// No `LC_ALL`/`LANG`/`TZ` pinning: unlike the goldens and the toLocaleString corpus, this
// records `JSON.parse` + `Number()`, whose grammars are fixed by ECMA-404/262 and take no
// locale input. Nothing here reaches ICU.
//
// ## WHY BIT PATTERNS AND NOT DECIMAL
//
// The sharpest known divergence between the two parsers is FOUR ULPs on a value both of
// them accept:
//
//     "1.12345678912345678e144"   V8 5DD70848B44D7BBA   Foundation 5DD70848B44D7BB6
//
// Decimal `repr` prints those as two similar-looking strings. Bits do not. `repr` is
// carried for human readers and is documentation, never ground truth.

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join, relative } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));
// …/native/SoloLedger/Tests/Fixtures → the repository root (four levels up).
const ROOT = join(HERE, '../../../..');
const OUT_DIR = join(HERE, '../SoloLedgerCoreTests/Fixtures/reportmath');
const OUT_FILE = join(OUT_DIR, 'js-settings-coercion.json');
const VERIFY = process.argv.includes('--verify');

// ── Root of trust ────────────────────────────────────────────────────────────────────
// Steps 2 and 3 below both re-run THIS FILE's expressions, so on their own they answer
// "is the corpus what this generator produces", never "is this generator what the
// DISPATCHER does". These anchors assert the mirrored call sites still read as recorded.
const ENGINE_ANCHORS = [
  { file: 'electron/reports/index.js', literal: 'return row ? JSON.parse(row.value) : fallback;' },
  { file: 'electron/reports/index.js', literal: "Number(readSetting(db, 'vat_rate', 13))" },
  { file: 'electron/reports/index.js', literal: "Number(readSetting(db, 'admin_expense_annual', 0))" },
];

// `readSetting` — index.js:16-21, including the catch that swallows a parse failure.
const readSetting = (raw, fallback) => {
  if (raw === null) return fallback;
  try { return JSON.parse(raw); } catch { return fallback; }
};

// Every shape a `settings.value` can hold that the mirror has to agree about. `null` means
// "no row at all", which is a different input from the four-character text `null`.
const CORPUS = [
  ['rowAbsent', null],
  ['zero', '0'], ['positive', '5000'], ['negative', '-5000'],
  ['numericString', '"5000"'], ['paddedNumericString', '" 5000 "'],
  ['emptyString', '""'], ['blankString', '"   "'],
  ['jsonNull', 'null'], ['jsonTrue', 'true'], ['jsonFalse', 'false'],
  ['emptyArray', '[]'], ['singletonArray', '[5000]'], ['pairArray', '[1,2]'],
  ['emptyObject', '{}'], ['object', '{"v":5000}'],
  ['unitSuffixString', '"5000元"'],
  ['bareUnitSuffix', '5000元'], ['bareLetters', 'abc'], ['emptyText', ''],
  ['positiveOverflow', '1e999'], ['negativeOverflow', '-1e999'], ['maxFinite', '1e308'],
  ['bareInfinity', 'Infinity'], ['bareNaN', 'NaN'],
  ['bomPrefixedNumber', '﻿5000'], ['bomInsideString', '"﻿5000"'],
  ['hexString', '"0x1388"'],
  ['beyondTwoFiftyThree', '9007199254740993'],
  ['seventeenDigitsHighExponent', '1.12345678912345678e145'],
  ['seventeenDigitsInRange', '1.12345678912345678e144'],
  ['smallestSubnormal', '4.9e-324'], ['subnormal', '1e-320'],
];

const FALLBACKS = { vat_rate: 13, admin_expense_annual: 0 };

const bits = (v) => {
  if (!Number.isFinite(v)) {
    if (Number.isNaN(v)) return '7FF8000000000000';            // canonical NaN
    return v > 0 ? '7FF0000000000000' : 'FFF0000000000000';
  }
  const b = Buffer.alloc(8);
  b.writeDoubleBE(Object.is(v, -0) ? -0 : v);
  return b.toString('hex').toUpperCase();
};

function build() {
  const cases = [];
  for (const [name, raw] of CORPUS) {
    let parseThrew = false;
    if (raw !== null) { try { JSON.parse(raw); } catch { parseThrew = true; } }
    const perKey = {};
    for (const [key, fallback] of Object.entries(FALLBACKS)) {
      const applied = Number(readSetting(raw, fallback));
      perKey[key] = {
        bits: bits(applied),
        repr: Object.is(applied, -0) ? '-0' : String(applied),  // documentation only
      };
    }
    cases.push({ name, storedText: raw, parseThrew, applied: perKey });
  }
  return {
    note: 'Recorded from the repo-locked Electron runtime. Regenerated and byte-compared in CI. '
        + '`repr` is documentation; `bits` is the ground truth.',
    generator: 'native/SoloLedger/Tests/Fixtures/make-settings-coercion-corpus.mjs',
    source: 'electron/reports/index.js readSetting + Number(), fallbacks per key',
    runtime: 'electron',
    fallbacks: FALLBACKS,
    cases,
  };
}

function fail(msg) { console.error(`\n❌ ${msg}`); process.exit(1); }

if (!process.versions.electron) {
  fail('this corpus records ELECTRON behaviour and must run under the repo-locked Electron:\n'
     + '   ELECTRON_RUN_AS_NODE=1 ./node_modules/.bin/electron '
     + 'native/SoloLedger/Tests/Fixtures/make-settings-coercion-corpus.mjs [--verify]\n'
     + `   (running under plain node ${process.version} would record a different V8: `
     + `${process.versions.v8})`);
}

const text = JSON.stringify(build(), null, 2) + '\n';
const rel = relative(ROOT, OUT_FILE);

if (!VERIFY) {
  mkdirSync(OUT_DIR, { recursive: true });
  writeFileSync(OUT_FILE, text);
  console.log(`✓ wrote ${rel} (${CORPUS.length} cases × ${Object.keys(FALLBACKS).length} keys)`);
  console.log(`  electron=${process.versions.electron} v8=${process.versions.v8}`);
  process.exit(0);
}

// ── 1. Anchors: is this generator still mirroring what the dispatcher does ────────────
for (const { file, literal } of ENGINE_ANCHORS) {
  let src;
  try { src = readFileSync(join(ROOT, file), 'utf8'); }
  catch { fail(`anchor file ${file} is unreadable`); }
  if (!src.includes(literal)) {
    fail(`anchor missing in ${file}:\n     ${literal}\n   The dispatcher changed; this corpus `
       + 'records something it no longer does. Re-derive before regenerating.');
  }
}

// ── 2. Byte compare, decided by git ──────────────────────────────────────────────────
// Read the committed bytes BEFORE rewriting: rewriting destroys the evidence of a hand
// edit. Then let git — not this script comparing a string to itself — judge the drift.
let committed = null;
try { committed = readFileSync(OUT_FILE, 'utf8'); } catch { fail(`${rel} is missing`); }
const onDiskDrifted = committed !== text;
mkdirSync(OUT_DIR, { recursive: true });
writeFileSync(OUT_FILE, text);
const git = spawnSync('git', ['diff', '--exit-code', '--stat', '--', rel], { cwd: ROOT });
const committedDrifted = git.status !== 0;
if (onDiskDrifted || committedDrifted) {
  fail(`${rel} is not reproducible under the locked Electron.\n`
     + `   on-disk differs from freshly generated: ${onDiskDrifted}\n`
     + `   git reports the committed file changed: ${committedDrifted}\n`
     + '   Either the corpus was hand-edited, or the runtime changed. Regenerate with:\n'
     + '   ELECTRON_RUN_AS_NODE=1 ./node_modules/.bin/electron '
     + 'native/SoloLedger/Tests/Fixtures/make-settings-coercion-corpus.mjs');
}

// ── 3. Re-run every committed case in the live runtime ───────────────────────────────
// Strictly redundant with step 2; kept because the failure message is the useful one.
const parsed = JSON.parse(committed);
for (const c of parsed.cases) {
  for (const [key, fallback] of Object.entries(parsed.fallbacks)) {
    const got = bits(Number(readSetting(c.storedText, fallback)));
    if (got !== c.applied[key].bits) {
      fail(`case "${c.name}" key ${key}: committed ${c.applied[key].bits}, live runtime ${got}`);
    }
  }
}

console.log('=== settings-coercion corpus (Electron oracle) ===\n');
console.log(`electron=${process.versions.electron}  node=${process.versions.node}  v8=${process.versions.v8}`);
console.log(`anchors: ${ENGINE_ANCHORS.length} verified in electron/reports/index.js`);
console.log(`cases: ${parsed.cases.length} × ${Object.keys(parsed.fallbacks).length} keys, `
          + 'byte-identical and re-executed');
console.log(`\n✓ ${rel} reproduces exactly under the locked Electron runtime.`);
