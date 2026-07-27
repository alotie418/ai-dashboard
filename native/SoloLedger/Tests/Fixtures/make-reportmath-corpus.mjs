#!/usr/bin/env node
// Differential corpus for ReportMath — the JS side of the mirror's arithmetic.
//
//   node native/SoloLedger/Tests/Fixtures/make-reportmath-corpus.mjs           # write
//   node native/SoloLedger/Tests/Fixtures/make-reportmath-corpus.mjs --verify  # CI gate
//
// WHY THIS EXISTS
//
// `ReportMath.swift` claims to reproduce V8's numeric semantics. Swift cannot run
// JavaScript, so that claim is not something the Swift test suite can check on its
// own — it can only check Swift against something. This file IS that something:
// every operation is evaluated here in a real V8, using the SAME EXPRESSION the
// report engines are written with, and the results are committed. `ReportMathTests`
// replays them.
//
// The rule that follows from this, and it is the whole point: where the Swift
// implementation and this corpus disagree, THE CORPUS IS RIGHT. That includes
// disagreeing with the specification's own prose — ECMA-262's note on `Math.round`
// claims equivalence to `Math.floor(x + 0.5)`, and for the 0.49999999999999994
// family it is simply wrong about what engines do. Change the formula, never the
// recorded truth.
//
// WHY PLAIN `node`, NOT ELECTRON
//
// Unlike `make-report-goldens.mjs`, nothing here touches sqlite or ICU:
// `Math.round`, `Math.max/min`, `||` and `Number()` are runtime-independent V8
// primitives with no locale input, so this runs under the ordinary node that
// `check:all` already has. (`us.js`'s `toLocaleString()`, which is why the goldens
// need a pinned Electron, has no counterpart here.) The runtime is still recorded
// so a drift would be visible in the diff rather than silent.
//
// WHY BITS, NOT NUMBERS
//
// Values are stored as the raw IEEE-754 bit pattern in hex. JSON cannot represent
// `-0` (`JSON.stringify(-0)` is `"0"`), `NaN` or `±Infinity` — and `-0` and `NaN`
// are exactly the values these shims exist to get right. A decimal `repr` rides
// along for human readability; it is documentation, never the ground truth.
import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));
const OUT_DIR = join(HERE, '../SoloLedgerCoreTests/Fixtures/reportmath');
const OUT_FILE = join(OUT_DIR, 'js-numeric-semantics.json');

// --- bit-exact encoding ------------------------------------------------------
const view = new DataView(new ArrayBuffer(8));
const bits = (x) => {
  // NaN payloads are not architecturally guaranteed, and nothing downstream may
  // depend on one, so every NaN is written as the canonical quiet NaN. The Swift
  // side compares NaN to NaN by is-a-NaN, not by pattern, for the same reason.
  if (Number.isNaN(x)) return '7FF8000000000000';
  view.setFloat64(0, x);
  return view.getBigUint64(0).toString(16).toUpperCase().padStart(16, '0');
};
const unbits = (h) => { view.setBigUint64(0, BigInt(`0x${h}`)); return view.getFloat64(0); };
const repr = (v) => (Object.is(v, -0) ? '-0' : String(v));

// One ULP away from x, toward +∞ (`d > 0`) or -∞ (`d < 0`). Used to walk right up
// to a rounding boundary, which is where every disagreement lives.
const ulp = (x, d) => {
  if (!Number.isFinite(x)) return x;
  if (x === 0) return d > 0 ? Number.MIN_VALUE : -Number.MIN_VALUE;
  view.setFloat64(0, x);
  const n = view.getBigUint64(0);
  const up = (x > 0) === (d > 0);
  view.setBigUint64(0, up ? n + 1n : n - 1n);
  return view.getFloat64(0);
};

// --- the operations, spelled EXACTLY as the engines spell them ---------------
//
// Each `js` below is copied from the call site named beside it. They are written
// as expressions rather than refactored helpers on purpose: a "tidied" version
// could be equivalent for the cases we happened to think of and different for the
// ones we did not.
const OPS = {
  // Math.round — every r() helper, plus cn.js:30,33,39,41 and _cashflow.js:26.
  round: { arity: 1, out: 'num', js: (x) => Math.round(x) },
  // cn.js:43 — NOTE: no `|| 0`. NaN passes through and serializes as null.
  round2: { arity: 1, out: 'num', js: (x) => Math.round(x * 100) / 100 },
  // us.js:142, jp.js:14, eu.js:14, kr.js:14, tw.js:14 — the guarded rounder.
  round2OrZero: { arity: 1, out: 'num', nullable: true, js: (v) => Math.round((v || 0) * 100) / 100 },
  // cn.js:30 and cn.js:41 — margins scale by 10000, not by 100 twice.
  percent2: { arity: 1, out: 'num', js: (x) => Math.round(x * 10000) / 100 },

  // `||` — the truthiness family.
  isTruthy: { arity: 1, out: 'bool', nullable: true, js: (v) => Boolean(v) },
  orZero: { arity: 1, out: 'num', nullable: true, js: (v) => v || 0 },
  // `a || b` keeps JS's habit of returning the falsy right-hand side as-is, so the
  // result can itself be null.
  or: { arity: 2, out: 'numOrNull', nullable: true, js: (a, b) => (a || b) },
  // cn.js:19,22 / _expenseSplit.js:24 and the same line in jp/eu/kr/tw.
  netAmount: { arity: 2, out: 'num', nullable: true, js: (a, b) => a || b || 0 },

  // cn.js:32,39 and the VAT/income-tax clamp in every other engine; us.js:70.
  max: { arity: 2, out: 'num', js: (a, b) => Math.max(a, b) },
  min: { arity: 2, out: 'num', js: (a, b) => Math.min(a, b) },
};

// --- fixed-seed PRNG ---------------------------------------------------------
// mulberry32. Deterministic across runtimes (32-bit integer ops and one divide),
// which is what makes regeneration byte-identical. `Math.random()` would make the
// corpus unreproducible and the CI gate meaningless.
function mulberry32(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6D2B79F5) >>> 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// --- the adversarial set -----------------------------------------------------
//
// Random sampling cannot find these. A rounding boundary is one ULP wide, a
// signed zero has measure zero, and the decimal values whose binary form crosses
// a half-cent are a scattered handful. They have to be named.

/// Rounding boundaries: k + 0.5 for many magnitudes, and its two neighbours.
/// 0.49999999999999994 is the k = 0 case and is where floor(x + 0.5) breaks.
const boundaries = () => {
  const out = [];
  for (const k of [0, 1, 2, 3, 4, 12, 100, 4503599627370495, 4503599627370496,
                   4503599627370497, 9007199254740991, 9007199254740992]) {
    for (const sign of [1, -1]) {
      const half = sign * (k + 0.5);
      out.push(half, ulp(half, -1), ulp(half, 1));
    }
  }
  return out;
};

/// Money values whose binary representation lands on the wrong side of a half
/// cent — the quirk the mirror must REPRODUCE. 1.005 * 100 is 100.49999999999999,
/// so round2(1.005) is 1, not 1.01.
const currency = [
  0.005, 0.015, 0.025, 0.035, 0.045, 0.055, 0.065, 0.075, 0.085, 0.095,
  0.105, 0.115, 0.125, 0.135, 0.145, 0.155, 0.165, 0.175, 0.185, 0.195,
  0.615, 1.005, 1.015, 1.025, 1.045, 1.055, 1.335, 2.675, 8.635, 1234.565,
  // The negative half-cent ladder. Math.round breaks ties toward +∞, so these
  // round toward zero where "away from zero" would not. r(-0.125) is the case
  // the mirror plan names by hand.
  -0.005, -0.015, -0.025, -0.035, -0.045, -0.055, -0.065, -0.075, -0.085,
  -0.095, -0.105, -0.115, -0.125, -0.135, -0.145, -0.155, -0.165, -0.175,
  -0.615, -1.005, -1.015, -1.025, -1.335, -2.675, -8.635, -1234.565,
];

/// The spec-divergence points reached through a REAL money value. `round2` and
/// `percent2` scale before rounding, so an ordinary-looking amount can land the
/// intermediate exactly on 0.49999999999999994, on a tie, or on 2^52+1. These are
/// the cases that make the divergence reachable from a ledger rather than only
/// from a hand-picked constant, and no random draw finds them.
const scaledPreimages = [
  0.004999999999999999,   // * 100 === 0.49999999999999994 exactly
  -0.004999999999999999,  // and its negative, which lands on -0
  0.00005, -0.00005,      // * 10000 === ±0.5, the exact tie
  0.000049999999999999996,
  45035996273704.97,      // * 100 === 4503599627370497 (2^52 + 1)
  90071992547409.91,      // * 100 === 9007199254740991 (2^53 - 1)
  900719925474.0991,      // * 10000 === 2^53 - 1
  -1e-9, -0.0001, -0.004, // negative sub-cent values that must survive as -0
  // Overflow and underflow THROUGH the scaling: round2 overflows at *100,
  // percent2 100x sooner at *10000, and the denormal end underflows to ±0.
  1e307, -1e307, 1e306, 1e304, 2e304, 1.5e301, 1e21,
  1.7976931348623157e304, 1.7976931348623159e304,
  5e-324, -4.9e-324, 1 / 5e-324,
  9.5e18, -9.3e18,
  // The whole [-0.5, 0) band answers -0, not just the famous single point.
  -0.49999999999999994, -0.4999999999999999, -5e-324,
];

/// Signed zero, NaN, the infinities, and the representational extremes.
const extremes = [
  0, -0, NaN, Infinity, -Infinity,
  Number.MIN_VALUE, -Number.MIN_VALUE, Number.EPSILON, -Number.EPSILON,
  Number.MAX_VALUE, -Number.MAX_VALUE,
  Number.MAX_SAFE_INTEGER, -Number.MAX_SAFE_INTEGER,
  Number.MAX_SAFE_INTEGER + 2, 2 ** 52, 2 ** 53, -(2 ** 52), 1e21, -1e21,
  // Finite, but * 100 overflows to Infinity — and * 10000 overflows 100x sooner,
  // which is where round2 and percent2 stop agreeing.
  Number.MAX_VALUE / 50, Number.MAX_VALUE / 5000, 1e306, 1e305,
  // Denormal round-trips: * 100 then / 100 need not return the input.
  Number.MIN_VALUE * 100, 5e-324, 1e-320,
  // Ordinary money, so a wholesale error is caught by something legible too.
  0, 1, -1, 0.5, -0.5, 100, 12233.96, -4264.15, 3773.58,
];

/// Every falsy value the `||` family must treat as falsy, plus near-misses that
/// must stay truthy. `null` stands for SQL NULL / JS null / undefined alike — all
/// three arrive in Swift as `nil`.
const falsy = [0, -0, NaN, null];
const truthy = [1, -1, 0.01, -0.01, Number.MIN_VALUE, Infinity, -Infinity, 1e21];

// --- Number(v) ---------------------------------------------------------------
//
// A separate table because its input is a JSON value, not a double. This is the
// call site at index.js:74-78, and therefore the origin of the engines' NaN path:
// the string "25%" in a settings row is what produces the five null fields in
// malformed-CN-2025.json.
//
// Encoded structurally rather than as JSON text so the Swift side decodes into
// ReportMath.JSValue without a JSON parser of its own in the way.
const jsNum = (x) => ({ t: 'num', bits: bits(x) });
const NUMBER_CASES = [
  { t: 'undefined' }, { t: 'null' },
  { t: 'bool', v: true }, { t: 'bool', v: false },
  // Numeric JSValues carry BITS for the same reason every other value here does:
  // JSON.stringify(-0) is "0", so a plain `v: -0` would be re-read as +0 and the
  // case would silently test nothing. (--verify caught exactly that.)
  ...[0, -0, 25, NaN, Infinity, -Infinity, 12.5].map(jsNum),
  // The real-world malformed rows. The repo's own e2e fixtures write this shape.
  ...['25%', '12%', '13%', '0.13', '13'].map((v) => ({ t: 'str', v })),
  // Empty and whitespace-only are +0, which is the most surprising row in the
  // table and the reason Number() cannot be replaced by Double(String).
  // EVERY member of StrWhiteSpace, alone (→ +0) and as a prefix (→ trimmed).
  // Enumerated exhaustively rather than sampled: the shim carries its own
  // hand-written copy of this set, and a corpus that exercises only some members
  // cannot tell a complete set from one missing an entry. (An adversarial review
  // deleted U+2001 from the shim and the whole suite stayed green — this list is
  // the fix.) ECMA-262 StrWhiteSpace = WhiteSpace (TAB VT FF ZWNBSP + Zs) +
  // LineTerminator (LF CR LS PS). Escaped, never literal: an invisible character
  // in source is unreviewable and editors normalize it away.
  ...[
    '\u{9}', '\u{a}', '\u{b}', '\u{c}', '\u{d}', '\u{20}', '\u{a0}', '\u{1680}',
    '\u{2000}', '\u{2001}', '\u{2002}', '\u{2003}', '\u{2004}', '\u{2005}',
    '\u{2006}', '\u{2007}', '\u{2008}', '\u{2009}', '\u{200a}', '\u{2028}',
    '\u{2029}', '\u{202f}', '\u{205f}', '\u{3000}', '\u{feff}',
  ].flatMap((w) => [{ t: 'str', v: w }, { t: 'str', v: `${w}12` }, { t: 'str', v: `12${w}` }]),
  ...['', ' ', '   ', '\t\n\r'].map((v) => ({ t: 'str', v })),
  // Negative controls: scalars that LOOK blank and are NOT in StrWhiteSpace, so
  // they must stay NaN. A shim that trimmed by "looks blank" — or by
  // CharacterSet.whitespacesAndNewlines, whose membership is an ICU decision that
  // can move between OS versions — passes every case above and fails these.
  ...['\u{85}', '\u{200b}', '\u{ad}', '\u{180e}', '\u{2060}', '\u{b7}']
    .flatMap((c) => [{ t: 'str', v: c }, { t: 'str', v: `${c}12` }]),
  // Radix literals: JS takes 0b/0o and rejects hex FLOATS; Swift is the reverse.
  // Single-digit radix literals FIRST: they are the shortest string the radix
  // path accepts, so they pin the length gate that decides whether "0x1" is a
  // radix literal at all. Without one, an off-by-one there is invisible.
  ...['0x1', '0xF', '0b1', '0o7', '0x0', '0b0',
    '0x10', '0X10', '0xff', '0xFF', '0o17', '0O17', '0b101', '0B101',
    '0x1p4', '0x', '0b', '0o', '0b2', '0o8', '0xg', '-0x10', '+0x10',
    '0x1fffffffffffff', '0x20000000000000', '0x20000000000001',
    '0x20000000000003', '0xFFFFFFFFFFFFFFFFFFFFFFFF', '0x1p1024', ' 0x10 ',
    // Past 2^53 the digits must be rounded ONCE from the exact mathematical
    // value. The natural `v = v * radix + digit` accumulation rounds at EVERY
    // digit instead, and these six literals are where the two answers differ by
    // one ULP — found by searching, because nothing about them looks special.
    // Unreachable from a settings row, and kept anyway: an exact implementation
    // is easier to justify than a nearly-right one, and without a case that
    // separates them the exactness is untested decoration.
    // Unicode digit LOOKALIKES. Swift's Character.hexDigitValue is Unicode-aware
    // (U+FF10 answers 0, U+FF21 answers 10) and Character.isNumber accepts
    // Arabic-Indic, Devanagari, circled and superscript forms — JS's grammar is
    // ASCII-only and answers NaN for every one of them. A shim that forgets the
    // isASCII guard invents a value where V8 refuses one.
    '0x\u{ff10}', '0x\u{ff21}\u{ff21}', '0b\u{ff11}', '0o\u{ff17}',
    '\u{ff15}', '\u{0665}', '\u{096b}', '\u{2460}', '\u{00b2}', '1\u{ff10}',
    '0x3636b7babec5b1947', '0x5c6f0c5a1a6432c48f5f56',
    '0x67fa7a88bb4402d7501fc9fcbdfaa2c5a', '0o6062270646076661556',
    '0o16301136137200727626153225', '0o753443175063242635066544277032',
    '0xfffffffffffffffffffffffffffff'].map((v) => ({ t: 'str', v })),
  // Decimal grammar edges.
  ...['5.', '.5', '+.5', '-.5', '+3', '-3', '00.5', '017', '1.', '.', '-.', '+',
    '-', '1e3', '1E3', '1e+3', '1e-3', '1e', '1e+', '.e3', '1_000', '1,000',
    '12 34', '1.2.3', 'Infinity', '+Infinity', '-Infinity', 'infinity',
    'INFINITY', 'NaN', 'nan', 'null', 'true', '1e400', '-1e400', '1e-400',
    '0.49999999999999994', '4503599627370495.5',
    // Decimal digit strings past 2^53, and the underflow-to-signed-zero end.
    '9007199254740993', '-1e-400', '1e-400', 'inf', 'INFINITY', '+Infinity',
    '123456789012345678901234567890'].map((v) => ({ t: 'str', v })),
  // Arrays coerce through join(","), recursively; objects are always NaN.
  { t: 'arr', v: [] }, { t: 'arr', v: [jsNum(5)] },
  { t: 'arr', v: [jsNum(1), jsNum(2)] },
  { t: 'arr', v: [{ t: 'null' }] }, { t: 'arr', v: [{ t: 'undefined' }] },
  { t: 'arr', v: [{ t: 'arr', v: [jsNum(3)] }] },
  { t: 'arr', v: [{ t: 'str', v: ' 7 ' }] }, { t: 'arr', v: [{ t: 'bool', v: true }] },
  { t: 'arr', v: [jsNum(-0)] }, { t: 'arr', v: [jsNum(1e21)] },
  { t: 'arr', v: [jsNum(NaN)] }, { t: 'arr', v: [jsNum(Infinity)] },
  { t: 'arr', v: [{ t: 'obj' }] }, { t: 'obj' },
  { t: 'arr', v: [{ t: 'str', v: ' ' }] },   // join gives " " → trims → 0
  { t: 'arr', v: [{ t: 'str', v: '' }] },
];

/// Rebuild the real JS value from the structural encoding above.
const materialize = (e) => {
  switch (e.t) {
    case 'undefined': return undefined;
    case 'null': return null;
    case 'bool': return e.v;
    case 'num': return unbits(e.bits);
    case 'str': return e.v;
    case 'arr': return e.v.map(materialize);
    case 'obj': return {};
    default: throw new Error(`unknown encoded tag ${e.t}`);
  }
};

// --- random sampling ---------------------------------------------------------
//
// The adversarial set covers what we KNEW to look for. The random draw is what
// catches an implementation that is wrong across a whole region nobody named —
// a sign error on large negatives, a scaling mistake past 2^32. Fixed seed, so
// the sample is part of the committed artefact rather than a fresh gamble.
const SEED = 0x5010ED6E; // "SOLOLEDGE", leetspoken — any constant would do, fixed is the point
function randomValues(rand, n) {
  const out = [];
  for (let i = 0; i < n; i++) {
    const kind = i % 5;
    if (kind === 0) {
      // Money with two decimals, the overwhelmingly common real input.
      out.push(Math.round((rand() * 2 - 1) * 1e6) / 100);
    } else if (kind === 1) {
      // Full-precision magnitudes across the money range.
      out.push((rand() * 2 - 1) * 10 ** Math.floor(rand() * 9));
    } else if (kind === 2) {
      // Deliberately parked ON a half boundary at a random magnitude, then nudged
      // one ULP either way — the only region where the rounders disagree.
      const k = Math.floor((rand() * 2 - 1) * 1e6);
      out.push([k + 0.5, ulp(k + 0.5, -1), ulp(k + 0.5, 1)][Math.floor(rand() * 3)]);
    } else if (kind === 3) {
      // Values whose *100 or *10000 crosses a boundary, i.e. sub-cent inputs.
      out.push((rand() * 2 - 1) / 10 ** (1 + Math.floor(rand() * 5)));
    } else {
      // Raw bit patterns, finite only (the infinities and NaN are named above, so
      // this draw stays about ordinary magnitudes rather than re-rolling them).
      let x;
      do {
        view.setBigUint64(0, (BigInt(Math.floor(rand() * 2 ** 32)) << 32n) |
                             BigInt(Math.floor(rand() * 2 ** 32)));
        x = view.getFloat64(0);
      } while (!Number.isFinite(x));
      out.push(x);
    }
  }
  return out;
}

// --- build -------------------------------------------------------------------
const rand = mulberry32(SEED);
const cases = [];
const push = (op, args, tag) => {
  const spec = OPS[op];
  const out = spec.js(...args);
  const enc = spec.out === 'bool' ? out
    : (out === null || out === undefined) ? null : bits(out);
  cases.push([
    op,
    args.map((a) => (a === null || a === undefined ? null : bits(a))),
    enc,
    tag,
    `${op}(${args.map((a) => (a === null || a === undefined ? 'null' : repr(a))).join(', ')}) = ` +
      (spec.out === 'bool' ? String(out) : (out === null || out === undefined ? 'null' : repr(out))),
  ]);
};

const UNARY_NUMERIC = ['round', 'round2', 'round2OrZero', 'percent2'];
const UNARY_TRUTHY = ['isTruthy', 'orZero', 'round2OrZero'];
const BINARY_CLAMP = ['max', 'min'];
const BINARY_TRUTHY = ['or', 'netAmount'];

// Adversarial — unary numeric.
for (const op of UNARY_NUMERIC) {
  for (const x of boundaries()) push(op, [x], 'boundary');
  for (const x of currency) push(op, [x], 'currency');
  for (const x of extremes) push(op, [x], 'extreme');
  for (const x of scaledPreimages) push(op, [x], 'preimage');
}
// Adversarial — truthiness. Every falsy value against every op that inspects one.
for (const op of UNARY_TRUTHY) {
  for (const x of [...falsy, ...truthy]) push(op, [x], 'truthiness');
}
for (const op of BINARY_TRUTHY) {
  for (const a of [...falsy, ...truthy]) for (const b of [...falsy, ...truthy]) {
    push(op, [a, b], 'truthiness');
  }
}
// Adversarial — clamps. The full signed-zero / NaN cross product, in BOTH argument
// orders, because Swift.min is order-dependent with NaN and Swift.max is not.
for (const op of BINARY_CLAMP) {
  const pool = [0, -0, NaN, Infinity, -Infinity, 1, -1, 0.5, -0.5,
    Number.MAX_VALUE, Number.MIN_VALUE, 176100, 4063.4];
  for (const a of pool) for (const b of pool) push(op, [a, b], 'clamp');
  // The literal us.js:70 shape and the cn.js:32,39 shape.
  for (const x of [...currency, ...extremes]) {
    push(op, [0, x], 'callsite');
    push(op, [x, 176100], 'callsite');
  }
}

// Random.
// Enough to catch an implementation that is wrong across a whole region; not so
// many that the committed artefact becomes mostly noise. The adversarial set above
// is what actually discriminates — this is regression ballast.
const RANDOM_PER_OP = 250;
for (const op of UNARY_NUMERIC) {
  for (const x of randomValues(rand, RANDOM_PER_OP)) push(op, [x], 'random');
}
for (const op of BINARY_CLAMP) {
  const xs = randomValues(rand, RANDOM_PER_OP);
  const ys = randomValues(rand, RANDOM_PER_OP);
  for (let i = 0; i < RANDOM_PER_OP; i++) push(op, [xs[i], ys[i]], 'random');
}
for (const op of BINARY_TRUTHY) {
  const xs = randomValues(rand, RANDOM_PER_OP);
  const ys = randomValues(rand, RANDOM_PER_OP);
  for (let i = 0; i < RANDOM_PER_OP; i++) {
    // Sprinkle nulls and zeros in, or the truthy path would be all that is tested.
    const a = i % 7 === 0 ? null : (i % 11 === 0 ? 0 : xs[i]);
    const b = i % 5 === 0 ? null : ys[i];
    push(op, [a, b], 'random');
  }
}
for (const op of ['isTruthy', 'orZero']) {
  const xs = randomValues(rand, RANDOM_PER_OP);
  for (let i = 0; i < RANDOM_PER_OP; i++) push(op, [i % 9 === 0 ? null : xs[i]], 'random');
}

// Number(v).
const numberCases = NUMBER_CASES.map((e) => {
  const out = Number(materialize(e));
  return [e, bits(out), repr(out)];
});

// --- serialize ---------------------------------------------------------------
// One case per line. A 4000-entry corpus pretty-printed the ordinary way is
// 24000 lines of noise; on one line each, a regeneration diff is readable.
const serialize = () => {
  const header = {
    note: 'Ground truth for ReportMath.swift, produced by executing each operation in V8. ' +
      'Where Swift and this file disagree, THIS FILE IS RIGHT — including where it ' +
      'disagrees with the ECMA-262 note on Math.round. Regenerate with ' +
      'make-reportmath-corpus.mjs; --verify is wired into `npm run check:all`.',
    generator: 'native/SoloLedger/Tests/Fixtures/make-reportmath-corpus.mjs',
    encoding: {
      value: 'IEEE-754 binary64 as 16 uppercase hex digits, big-endian. JSON cannot ' +
        'carry -0, NaN or Infinity, which are the values these shims exist to get right.',
      nan: 'Every NaN is written as the canonical 7FF8000000000000; payloads are not ' +
        'architecturally guaranteed, so the Swift side compares NaN by is-a-NaN.',
      nullValue: 'JSON null in an argument means JS null/undefined and SQL NULL alike — ' +
        'all three reach Swift as nil.',
      case: '[op, args[], result, tag, repr] — repr is documentation, never ground truth.',
    },
    // Provenance only, and DELIBERATELY excluded from the --verify byte
    // comparison: CI runs a different node major than most dev machines, and
    // failing on that would be a version check wearing a correctness check's
    // clothes. What actually guards against a V8 that behaves differently is
    // step 2 of --verify, which re-executes every committed case and names the
    // operation and input that moved. That check is stronger AND
    // runtime-independent, so the version here is a record, not a gate.
    generatedWith: { node: process.versions.node, v8: process.versions.v8 },
    seed: `0x${SEED.toString(16).toUpperCase()}`,
    ops: Object.fromEntries(Object.entries(OPS).map(([k, v]) =>
      [k, { arity: v.arity, result: v.out, js: v.js.toString() }])),
    counts: {
      total: cases.length,
      byOp: Object.fromEntries(Object.keys(OPS).map((op) =>
        [op, cases.filter((c) => c[0] === op).length])),
      byTag: Object.fromEntries([...new Set(cases.map((c) => c[3]))].map((t) =>
        [t, cases.filter((c) => c[3] === t).length])),
      number: numberCases.length,
    },
  };
  const lines = [];
  lines.push('{');
  lines.push(`  "header": ${JSON.stringify(header, null, 2).split('\n').join('\n  ')},`);
  lines.push('  "cases": [');
  lines.push(cases.map((c) => `    ${JSON.stringify(c)}`).join(',\n'));
  lines.push('  ],');
  lines.push('  "numberCases": [');
  lines.push(numberCases.map((c) => `    ${JSON.stringify(c)}`).join(',\n'));
  lines.push('  ]');
  lines.push('}');
  return `${lines.join('\n')}\n`;
};

const text = serialize();

if (process.argv.includes('--verify')) {
  if (!existsSync(OUT_FILE)) {
    console.error(`✗ reportmath corpus missing: ${OUT_FILE}`);
    console.error('  regenerate: node native/SoloLedger/Tests/Fixtures/make-reportmath-corpus.mjs');
    process.exit(1);
  }
  const committed = readFileSync(OUT_FILE, 'utf8');

  // 1. Regeneration must be byte-identical MODULO the provenance line — see the
  //    `generatedWith` comment above. Catches an edited corpus, a changed seed,
  //    a dropped case, and a generator changed without regenerating.
  const stripProvenance = (s) =>
    s.replace(/"generatedWith": \{[^}]*\}/, '"generatedWith": {}');
  if (stripProvenance(committed) !== stripProvenance(text)) {
    console.error('✗ reportmath corpus does not match what the generator produces.');
    console.error('  Either the corpus was hand-edited, or the generator changed without');
    console.error('  regenerating. Run the generator and commit the result:');
    console.error('    node native/SoloLedger/Tests/Fixtures/make-reportmath-corpus.mjs');
    process.exit(1);
  }
  const wasBuiltBy = JSON.parse(committed).header.generatedWith;
  if (wasBuiltBy.v8 !== process.versions.v8) {
    console.log(`  note: corpus was generated under v8=${wasBuiltBy.v8}, verifying under ` +
                `v8=${process.versions.v8} — every case is re-executed below.`);
  }

  // 2. Re-evaluate every COMMITTED case against live JS. Strictly redundant with
  //    the byte diff, and kept because the failure message is the useful one: it
  //    names the operation and the input rather than saying "a file differs".
  const parsed = JSON.parse(committed);
  let checked = 0;
  for (const [op, args, expected] of parsed.cases) {
    const spec = OPS[op];
    const actual = spec.js(...args.map((a) => (a === null ? null : unbits(a))));
    const enc = spec.out === 'bool' ? actual
      : (actual === null || actual === undefined) ? null : bits(actual);
    if (JSON.stringify(enc) !== JSON.stringify(expected)) {
      console.error(`✗ ${op}(${args.join(', ')}): corpus says ${expected}, this V8 says ${enc}`);
      process.exit(1);
    }
    checked++;
  }
  for (const [encoded, expected] of parsed.numberCases) {
    const actual = bits(Number(materialize(encoded)));
    if (actual !== expected) {
      console.error(`✗ Number(${JSON.stringify(encoded)}): corpus says ${expected}, this V8 says ${actual}`);
      process.exit(1);
    }
    checked++;
  }
  console.log(`✓ reportmath corpus reproducible: ${checked} cases re-evaluated in V8 ` +
              `(node=${process.versions.node} v8=${process.versions.v8})`);
  process.exit(0);
}

mkdirSync(OUT_DIR, { recursive: true });
writeFileSync(OUT_FILE, text, 'utf8');
console.log(`reportmath corpus: ${cases.length} cases + ${numberCases.length} Number() cases → ${OUT_FILE}`);
console.log(`  runtime: node=${process.versions.node} v8=${process.versions.v8}`);
