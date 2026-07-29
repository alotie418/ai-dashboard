#!/usr/bin/env node
// Differential corpus for `Number.prototype.toLocaleString()` — the ONE piece of
// `electron/reports/*` semantics that depends on ICU.
//
//   LC_ALL=C LANG=C TZ=UTC ELECTRON_RUN_AS_NODE=1 ./node_modules/.bin/electron \
//     native/SoloLedger/Tests/Fixtures/make-tolocalestring-corpus.mjs            # write
//   …same prefix… make-tolocalestring-corpus.mjs --verify                        # CI gate
//
// WHY A SECOND GENERATOR
//
// `make-reportmath-corpus.mjs` runs under plain `node`, and its header says why:
// "nothing here touches sqlite or ICU… `us.js`'s toLocaleString(), which is why the
// goldens need a pinned Electron, has no counterpart here." R7 gives it a
// counterpart, so putting these vectors in that file would falsify its own stated
// premise and make a locale-dependent result look runtime-independent.
//
// This file therefore runs under the SAME pinned environment as the goldens
// (`make-report-goldens.mjs`): `LC_ALL=C LANG=C TZ=UTC` and the Electron binary
// locked by package.json. Measured, and the reason the pin exists: `us.js:120`
// formats `$298.41` under en_US and `$298,41` under de_DE.
//
// WHAT IS BEING PINNED
//
// `us.js:120` builds a user-visible warning as
//   `Estimated quarterly tax payment: $${quarterlyPayment.toLocaleString()}`
// with NO options argument, so the format is the runtime's default for the resolved
// locale: grouping separators on, 0–3 fraction digits, half-expand rounding at the
// third decimal. That is where the golden's `$3,647.6` comes from — the missing
// trailing zero recorded as Appendix A3. It is mirrored, not repaired.
//
// WHY BITS, NOT NUMBERS
//
// Same reason as the ReportMath corpus: JSON cannot represent `-0`, `NaN` or
// `±Infinity`, and all three are reachable here (`-0` from a rounded negative zero,
// `Infinity` from a rate large enough to overflow the product). The decimal `repr`
// is documentation; the bits are the input.
import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));
const OUT_DIR = join(HERE, '../SoloLedgerCoreTests/Fixtures/reportmath');
const OUT_FILE = join(OUT_DIR, 'js-tolocalestring.json');

// --- environment gate -------------------------------------------------------
// Identical to make-report-goldens.mjs. Without it the corpus would silently
// record whatever locale the machine happens to have.
const REQUIRED_ENV = { LC_ALL: 'C', LANG: 'C', TZ: 'UTC' };
for (const [k, want] of Object.entries(REQUIRED_ENV)) {
  if (process.env[k] !== want) {
    console.error(`toLocaleString corpus requires ${k}=${want} (got ${JSON.stringify(process.env[k])}).`);
    console.error('run: LC_ALL=C LANG=C TZ=UTC ELECTRON_RUN_AS_NODE=1 ./node_modules/.bin/electron ' +
                  'native/SoloLedger/Tests/Fixtures/make-tolocalestring-corpus.mjs');
    process.exit(2);
  }
}
const resolvedLocale = new Intl.NumberFormat().resolvedOptions().locale;
if (resolvedLocale !== 'en-US') {
  console.error(`resolved Intl locale is ${resolvedLocale}, expected en-US — the goldens pin the same thing.`);
  process.exit(2);
}

const bits = (x) => {
  const b = Buffer.alloc(8);
  b.writeDoubleBE(x, 0);
  return '0x' + b.toString('hex');
};

// The vectors. Chosen from what `quarterlyPayment` can actually be — it is
// `r(totalAnnual / 4)`, so a two-decimal double of any sign and magnitude — plus
// the format boundaries the golden set never reaches.
// The eight values below marked (min) are a REQUIRED minimum coverage set, agreed
// when this generator was commissioned: integer, grouping, two decimals, one decimal,
// several groups, rounding at the 4th decimal, negative-with-grouping, and zero.
// Removing one narrows the contract, so they are labelled rather than left to be
// inferred from a list.
const VALUES = [
  // The one value a committed golden pins (base-US-2026). Note the LOST trailing
  // zero: 3647.60 formats as "3,647.6". Appendix A3, mirrored not repaired.
  3647.6,                                    // (min) grouping + dropped trailing zero
  // The other four warning strings in the golden set.
  375.43, 430.43, 155.43, 166.43,
  // Grouping boundaries — one separator appears at 1000, a second at 1e6.
  999, 999.99, 1000 /* (min) */, 1000.5, 9999.99, 10000, 100000, 999999.99, 1000000, 1234567.891,
  // Fraction-digit boundaries. The default maximumFractionDigits is 3, so the
  // fourth decimal is ROUNDED AWAY, not truncated — a Swift shim that truncates
  // passes every golden and fails here.
  0.5 /* (min) */, 0.25, 0.125, 1.2345 /* (min) */, 1.2344, 2.0005, 1.0001, 0.0004, 0.0005,
  // Trailing zeros are dropped, which is the whole Appendix A3 quirk.
  1.5, 1.50, 2.10, 100.0, 100.10,
  // Signs and zero. `-0` formats as "-0" in V8, which no golden reaches.
  0 /* (min) */, -0, -1, -1000.5, -2500.5 /* (min) */, -3647.6, -0.5,
  // Integers large enough to exercise several separators.
  1e9, 1234567890, 987654321.123,   // 1234567.891 (min) is in the grouping row above
  // Non-finite. Reachable: a rate large enough to overflow the product makes
  // `quarterlyPayment` Infinity, and the warning is still emitted from it.
  Infinity, -Infinity, NaN,
  // Very small and very large finite magnitudes — the default formatter switches
  // notation nowhere in this range, and pinning that is the point.
  1e-7, 1e20, 1e21, 1.7976931348623157e308,
];

const vectors = VALUES.map((v) => ({
  bits: bits(v),
  repr: Object.is(v, -0) ? '-0' : String(v),
  // The EXACT expression `us.js:120` uses: no arguments, no options.
  formatted: v.toLocaleString(),
}));

// A live anchor: the expression really is argument-less in the engine. If someone
// adds options to us.js, this corpus stops describing it and says so.
const usSource = readFileSync(join(HERE, '../../../../electron/reports/us.js'), 'utf8');
if (!usSource.includes('quarterlyPayment.toLocaleString()')) {
  console.error('✗ us.js no longer calls `quarterlyPayment.toLocaleString()` with no arguments —');
  console.error('  this corpus describes an expression that has changed. Re-read us.js before regenerating.');
  process.exit(1);
}

const payload = {
  note: 'Number.prototype.toLocaleString() with NO arguments, as electron/reports/us.js:120 calls it. ' +
        'Values are IEEE-754 bits; `repr` is documentation. Where Swift and this corpus disagree, ' +
        'THE CORPUS IS RIGHT.',
  generator: 'native/SoloLedger/Tests/Fixtures/make-tolocalestring-corpus.mjs',
  expression: 'value.toLocaleString()',
  env: REQUIRED_ENV,
  resolvedIntlLocale: resolvedLocale,
  electron: process.versions.electron ?? null,
  node: process.versions.node,
  icu: process.versions.icu ?? null,
  vectors,
};
const serialized = JSON.stringify(payload, null, 2) + '\n';

if (process.argv.includes('--verify')) {
  if (!existsSync(OUT_FILE)) {
    console.error(`✗ toLocaleString corpus missing: ${OUT_FILE}`);
    process.exit(1);
  }
  if (readFileSync(OUT_FILE, 'utf8') !== serialized) {
    console.error('✗ toLocaleString corpus is stale or was hand-edited — regenerate it with the pinned');
    console.error('  environment. A difference here means the recorded ICU behaviour no longer matches');
    console.error('  this runtime, which is exactly what the pin exists to make visible.');
    process.exit(1);
  }
  console.log(`✓ toLocaleString corpus: ${vectors.length} vectors, byte-identical ` +
              `(icu=${process.versions.icu} locale=${resolvedLocale})`);
  process.exit(0);
}

mkdirSync(OUT_DIR, { recursive: true });
writeFileSync(OUT_FILE, serialized, 'utf8');
console.log(`toLocaleString corpus written: ${vectors.length} vectors → ${OUT_FILE}`);
console.log(`  runtime: electron=${process.versions.electron ?? 'n/a'} icu=${process.versions.icu} locale=${resolvedLocale}`);
