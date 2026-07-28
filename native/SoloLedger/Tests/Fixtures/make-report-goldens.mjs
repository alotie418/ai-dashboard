#!/usr/bin/env node
// Generate GOLDEN report outputs by running the REAL Electron report engines
// (electron/reports/index.js) against the committed report fixture. The Swift
// mirror is asserted field-by-field against these files, so they are the
// definition of "verbatim" for the phase-1 mirroring PRs.
//
// Run it exactly like this — the environment is part of the contract:
//   LC_ALL=C LANG=C TZ=UTC ELECTRON_RUN_AS_NODE=1 ./node_modules/.bin/electron \
//     native/SoloLedger/Tests/Fixtures/make-report-goldens.mjs
//
// WHY the environment is pinned:
//   LC_ALL/LANG — electron/reports/us.js formats a string with toLocaleString(),
//                 which emits "$298.41" under en_US but "$298,41" under de_DE.
//   TZ          — keeps any date handling machine-independent.
//   explicit year/from/to — never let index.js fall back to `new Date()`, or the
//                 goldens would rot at the next new year.
// The resolved runtime is recorded in GOLDEN_ENV.json so a drift is visible in
// the diff rather than silently changing every number.
//
// REGENERATION IS EXPECTED TO BE BYTE-IDENTICAL. CI re-runs this and diffs; a
// non-empty diff means either the engines changed (which a mirroring PR must not
// do) or the environment was not pinned.
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { existsSync, rmSync, mkdirSync, writeFileSync, copyFileSync, readdirSync, readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';

const require = createRequire(import.meta.url);
const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '../../../..');
const FIXTURE_DIR = join(HERE, '../SoloLedgerCoreTests/Fixtures/reports');
const BASE_DB = join(FIXTURE_DIR, 'reports-base.db');
const OUT_DIR = join(FIXTURE_DIR, 'goldens');

// --- environment gate -------------------------------------------------------
const REQUIRED_ENV = { LC_ALL: 'C', LANG: 'C', TZ: 'UTC' };
for (const [k, want] of Object.entries(REQUIRED_ENV)) {
  if (process.env[k] !== want) {
    console.error(`golden generation requires ${k}=${want} (got ${JSON.stringify(process.env[k])}).`);
    console.error('run: LC_ALL=C LANG=C TZ=UTC ELECTRON_RUN_AS_NODE=1 ./node_modules/.bin/electron ' +
                  'native/SoloLedger/Tests/Fixtures/make-report-goldens.mjs');
    process.exit(2);
  }
}

let Database;
try {
  Database = require('better-sqlite3');
  new Database(':memory:').close();
} catch (e) {
  console.error('better-sqlite3 unloadable under this node:', e?.message?.split('\n')[0]);
  console.error('run with: ELECTRON_RUN_AS_NODE=1 ./node_modules/.bin/electron <this file>');
  process.exit(2);
}
if (!existsSync(BASE_DB)) {
  console.error(`missing fixture ${BASE_DB} — build it first with make-report-fixture.mjs`);
  process.exit(2);
}

const reportEngine = require(join(ROOT, 'electron/reports/index.js'));

// SQLite's own version matters: the engines run SQL aggregates, and a different
// library build could in principle order or round differently.
const sqliteVersion = (() => {
  const probe = new Database(':memory:');
  const v = probe.prepare('SELECT sqlite_version() AS v').get().v;
  probe.close();
  return v;
})();

// --- rate variants ----------------------------------------------------------
// Derived from the ONE committed fixture so the pair differs ONLY in whether the
// rate rows exist. The Swift tests apply the SAME mutations, so a variant can
// never drift between the two sides.
//
// This pair IS the test body for the hard constraint "not configured is decided
// by the ABSENCE of the settings row, never by the computed value": `unset` must
// read as not-configured, `zero` must compute a genuine 0.
const RATE_KEYS = ['vat_rate', 'surcharge_rate', 'income_tax_rate', 'admin_expense_annual'];
const RATE_VARIANTS = {
  base: null,                                                   // fixture as committed
  unset: (db) => db.prepare(
    `DELETE FROM settings WHERE key IN (${RATE_KEYS.map(() => '?').join(',')})`).run(...RATE_KEYS),
  zero: (db) => {
    const put = db.prepare(`INSERT INTO settings (key, value, updated_at) VALUES (?, ?, datetime('now'))
      ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=datetime('now')`);
    for (const k of RATE_KEYS) put.run(k, JSON.stringify(0));
  },
  // A stored value that is PRESENT but not usable — VALID JSON, unusable content.
  // The stored bytes are `"12%"` / `"25%"`, i.e. JSON strings. Before A4-3 this was
  // the NaN path: index.js coerced with a bare `Number()`, cn.js's rounder has no
  // `|| 0` guard so five CN fields serialised as JSON null, and the other four
  // engines' guarded rounders flattened the NaN to a confident 0. Since A4-3 the
  // dispatcher refuses outright, so every engine emits null for the rate-driven
  // fields — same bytes for China, different bytes for the rest.
  malformed: (db) => {
    const put = db.prepare(`INSERT INTO settings (key, value, updated_at) VALUES (?, ?, datetime('now'))
      ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=datetime('now')`);
    put.run('surcharge_rate', JSON.stringify('12%'));
    put.run('income_tax_rate', JSON.stringify('25%'));
  },
  // The OTHER unusable shape, and the one no variant covered until A4-3: stored text
  // that is not JSON AT ALL. Note the missing JSON.stringify — the bytes are a bare
  // `25%`, not `"25%"`.
  //
  // This is a separate defect with a separate mechanism, and it was the more dangerous
  // of the two. `JSON.parse` throws, `readSetting`'s catch swallows it and returns the
  // FALLBACK, and `settingRowExists` has already answered true — so scheme A's gate
  // opened and a US ledger was priced at China's 25%. Measured before A4-3:
  // `estimatedTax.annualIncomeTax` = 1100, byte-identical to the pre-#419 missing-row
  // bug. This variant exists so that hole can never reopen without a golden moving.
  'malformed-raw': (db) => {
    const put = db.prepare(`INSERT INTO settings (key, value, updated_at) VALUES (?, ?, datetime('now'))
      ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=datetime('now')`);
    put.run('surcharge_rate', '12%');
    put.run('income_tax_rate', '25%');
  },
};

const LOCALES = ['CN', 'US', 'JP', 'EU', 'KR', 'TW'];

// Periods. 2024 holds ONLY legacy sales/purchases rows, 2025/2026 hold only
// transactions — so the 2024 vs 2025 pair pins the per-period source selection.
const PERIODS = [
  { id: '2024', year: '2024', from: '2024-01-01', to: '2024-12-31' },   // legacy branch
  { id: '2025', year: '2025', from: '2025-01-01', to: '2025-12-31' },   // transactions branch
  { id: '2026', year: '2026', from: '2026-01-01', to: '2026-12-31' },   // US Schedule C data
  { id: '2025Q2', year: '2025', from: '2025-04-01', to: '2025-06-30' }, // quarter granularity
  { id: '2025-06', year: '2025', from: '2025-06-01', to: '2025-06-30' },// month granularity
  // Spans the source boundary: legacy rows from 2024-H2 AND transactions from
  // 2025-H1 fall inside it, so the period has >=1 transaction and reports ONLY
  // the transactions — the 2024 legacy rows inside the same window are dropped.
  { id: '2024H2-2025H1', year: '2025', from: '2024-07-01', to: '2025-06-30' },
];
// The directed rate pair only needs a period that actually produces a tax line.
const VARIANT_PERIODS = {
  base: PERIODS, unset: [PERIODS[1]], zero: [PERIODS[1]], malformed: [PERIODS[1]],
  'malformed-raw': [PERIODS[1]],
};

// --- generate ---------------------------------------------------------------
if (existsSync(OUT_DIR)) for (const f of readdirSync(OUT_DIR)) rmSync(join(OUT_DIR, f));
mkdirSync(OUT_DIR, { recursive: true });

const tmpDir = join(FIXTURE_DIR, '.tmp-goldens');
mkdirSync(tmpDir, { recursive: true });

let written = 0;
for (const [variant, mutate] of Object.entries(RATE_VARIANTS)) {
  const dbPath = join(tmpDir, `${variant}.db`);
  for (const f of [dbPath, dbPath + '-wal', dbPath + '-shm']) if (existsSync(f)) rmSync(f);
  copyFileSync(BASE_DB, dbPath);
  const db = new Database(dbPath);
  if (mutate) mutate(db);

  for (const locale of LOCALES) {
    for (const period of VARIANT_PERIODS[variant]) {
      const result = reportEngine.generate(db, {
        locale, year: period.year, from: period.from, to: period.to,
      });
      const name = `${variant}-${locale}-${period.id}.json`;
      writeFileSync(join(OUT_DIR, name), JSON.stringify(result, null, 2) + '\n', 'utf8');
      written++;
    }
  }
  db.close();
  for (const f of [dbPath, dbPath + '-wal', dbPath + '-shm']) if (existsSync(f)) rmSync(f);
}
rmSync(tmpDir, { recursive: true, force: true });

// --- environment record -----------------------------------------------------
writeFileSync(join(OUT_DIR, 'GOLDEN_ENV.json'), JSON.stringify({
  note: 'Regenerating with a different runtime may change the goldens. CI re-runs ' +
        'the generator and byte-diffs the output; a non-empty diff is a failure.',
  generator: 'native/SoloLedger/Tests/Fixtures/make-report-goldens.mjs',
  // Content hash, not just a path: the goldens are only meaningful for THIS
  // fixture, so a rebuilt or edited database has to be visible in the diff.
  fixture: {
    path: 'native/SoloLedger/Tests/SoloLedgerCoreTests/Fixtures/reports/reports-base.db',
    sha256: createHash('sha256').update(readFileSync(BASE_DB)).digest('hex'),
  },
  electron: process.versions.electron ?? null,
  node: process.versions.node,
  icu: process.versions.icu ?? null,
  betterSqlite3: require(join(ROOT, 'node_modules/better-sqlite3/package.json')).version,
  sqlite: sqliteVersion,
  resolvedIntlLocale: new Intl.NumberFormat().resolvedOptions().locale,
  env: REQUIRED_ENV,
  rateKeys: RATE_KEYS,
  variants: {
    base: 'the fixture as committed — every rate row present',
    unset: `DELETE FROM settings WHERE key IN (${RATE_KEYS.join(', ')})`,
    zero: 'every rate key set to the JSON number 0',
    malformed: "surcharge_rate and income_tax_rate set to the JSON strings '12%' / '25%'",
    'malformed-raw': "surcharge_rate and income_tax_rate set to the RAW text 12% / 25% — " +
      'not valid JSON at all, so JSON.parse throws and readSetting used to return the fallback',
  },
  locales: LOCALES,
  periods: PERIODS,
  variantPeriods: Object.fromEntries(
    Object.entries(VARIANT_PERIODS).map(([k, v]) => [k, v.map((p) => p.id)])),
}, null, 2) + '\n', 'utf8');

console.log(`goldens written: ${written} files + GOLDEN_ENV.json → ${OUT_DIR}`);
console.log(`  runtime: electron=${process.versions.electron ?? 'n/a'} node=${process.versions.node} ` +
            `intl=${new Intl.NumberFormat().resolvedOptions().locale}`);
