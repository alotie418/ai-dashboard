// Guard: Excel date-cell import normalization (QA-4 fix, fix/excel-import-date-cells).
//
// Bug being guarded: XLSX.read without cellDates left real date cells as Excel serial
// numbers (46174), String(46174) fails the /^\d{4}-\d{2}-\d{2}$/ date validation at
// CsvImportModal validateLegacy → every dated row of a real .xlsx/.xls failed to import.
//
// Method: generate REAL workbooks in-memory with the app's own SheetJS build, replay the
// component's EXACT parse sequence (XLSX.read {type:'array', cellDates:true} →
// sheet_to_json {header:1} → excelCellToYMD per cell), and assert behavior. The component
// functions (excelCellToYMD / validateLegacy) are EXTRACTED FROM CsvImportModal.tsx
// SOURCE and compiled with esbuild (a .tsx with JSX cannot be imported under node), so
// the test always exercises the shipped implementation — rename/move breaks it loudly.
// Zero external/network deps: xlsx + esbuild both come from node_modules.

import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const XLSX = require('xlsx');
const esbuild = require('esbuild');

let failures = 0;
const ok = (cond, msg) => { if (cond) console.log(`  ✓ ${msg}`); else { failures++; console.error(`  ✗ ${msg}`); } };

// ── 1. Extract the real functions from the component source ─────────────────────────
const SRC_PATH = new URL('../components/CsvImportModal.tsx', import.meta.url);
const src = readFileSync(SRC_PATH, 'utf8');

function extractFn(name) {
  const start = src.indexOf(`function ${name}`);
  if (start < 0) { console.error(`✗ cannot find "function ${name}" in CsvImportModal.tsx — was it renamed/moved?`); process.exit(1); }
  let i = src.indexOf('{', start);
  let depth = 0;
  for (; i < src.length; i++) {
    if (src[i] === '{') depth++;
    else if (src[i] === '}') { depth--; if (depth === 0) { i++; break; } }
  }
  return src.slice(start, i);
}

const tsSnippet = `${extractFn('excelCellToYMD')}\n${extractFn('validateLegacy')}\nreturn { excelCellToYMD, validateLegacy };`;
const jsSnippet = esbuild.transformSync(tsSnippet, { loader: 'ts' }).code;
// Security note (deliberate, NOT an injection surface): the string handed to new Function
// is exclusively this repo's own version-controlled source (CsvImportModal.tsx) — the same
// trust domain as this script itself; anyone able to alter that source can already alter
// any npm script node executes. No user/external/network input ever reaches this eval.
// This is the test's core mechanism: execute the SHIPPED implementation (a .tsx with JSX
// cannot be imported under node), instead of a drifting copy of it.
// validateLegacy references the module-level `tr(t, key)` i18n shim — stub it to echo keys.
const { excelCellToYMD, validateLegacy } = new Function('tr', jsSnippet)((_t, k) => k);
const tStub = (k) => k;

// ── 2. Build a real workbook (date cell + text date + amounts), write → read back ────
const AOA = [
  ['日期', '客户', '数量', '金额'],
  [new Date(2026, 5, 1), '上海测试贸易有限公司', 24, 957.6],   // real date cell
  ['2026-07-05', '文本日期客户', 1, 0],                        // text date + zero amount
  ['not-a-date', '非法日期客户', 2, 100],                       // invalid date text
];

function roundTrip(bookType) {
  const wb = XLSX.utils.book_new();
  XLSX.utils.book_append_sheet(wb, XLSX.utils.aoa_to_sheet(AOA, { cellDates: true }), 'S');
  const buf = XLSX.write(wb, { type: 'buffer', bookType });
  const data = new Uint8Array(buf);
  // EXACT component sequence (CsvImportModal.processFile isExcel branch):
  const workbook = XLSX.read(data, { type: 'array', cellDates: true });
  const sheet = workbook.Sheets[workbook.SheetNames[0]];
  const json = XLSX.utils.sheet_to_json(sheet, { header: 1 });
  const hdrs = json[0].map(String);
  return json.slice(1).map((row) => {
    const obj = {};
    hdrs.forEach((h, i) => { obj[h] = excelCellToYMD(row[i] ?? ''); });
    return obj;
  });
}

for (const bookType of ['xlsx', 'xls']) {
  console.log(`— bookType=${bookType} —`);
  let rows;
  try {
    rows = roundTrip(bookType);
  } catch (e) {
    ok(false, `${bookType} round-trip threw: ${e?.message}`);
    continue;
  }
  ok(rows[0]['日期'] === '2026-06-01', `[${bookType}] real date cell → '2026-06-01' (got ${JSON.stringify(rows[0]['日期'])})`);
  ok(rows[1]['日期'] === '2026-07-05', `[${bookType}] text date stays untouched`);
  ok(rows[2]['日期'] === 'not-a-date', `[${bookType}] invalid date text passes through (validation rejects it later)`);
  ok(rows[0]['数量'] === 24 && rows[0]['金额'] === 957.6, `[${bookType}] numeric qty/amount cells stay raw numbers`);
  ok(rows[1]['金额'] === 0, `[${bookType}] zero amount stays numeric 0`);
}

// ── 3. Old behavior premise: WITHOUT cellDates the date cell is a serial number ──────
{
  const wb = XLSX.utils.book_new();
  XLSX.utils.book_append_sheet(wb, XLSX.utils.aoa_to_sheet(AOA, { cellDates: true }), 'S');
  const data = new Uint8Array(XLSX.write(wb, { type: 'buffer', bookType: 'xlsx' }));
  const sheet0 = XLSX.read(data, { type: 'array' }).Sheets.S; // ← old options (the bug)
  const v = XLSX.utils.sheet_to_json(sheet0, { header: 1 })[1][0];
  ok(typeof v === 'number' && !/^\d{4}-\d{2}-\d{2}$/.test(String(v)),
    `bug premise documented: without cellDates the date cell is a serial number (${v}) that fails the date regex`);
}

// ── 4. excelCellToYMD unit edges ─────────────────────────────────────────────────────
ok(excelCellToYMD('2026-07-05') === '2026-07-05', 'unit: YYYY-MM-DD string unchanged');
ok(excelCellToYMD(46174) === 46174, 'unit: bare number passes through (still rejected by validation — no silent serial guessing)');
ok(excelCellToYMD('') === '', 'unit: empty string unchanged');
const invalid = new Date('garbage');
ok(excelCellToYMD(invalid) === invalid, 'unit: Invalid Date passes through untouched');
const d31 = excelCellToYMD(new Date(2026, 11, 31));
ok(d31 === '2026-12-31', `unit: local-date components used (Dec 31 stays Dec 31, no toISOString UTC shift), got ${d31}`);

// ── 5. validateLegacy behavior with normalized rows (real validator source) ──────────
{
  const good = validateLegacy({ date: '2026-06-01', customer: '上海测试', totalAmount: 100 }, 'sales', tStub);
  ok(good.length === 0, `validate: normalized date + positive amount → no errors (got ${JSON.stringify(good)})`);
  const serial = validateLegacy({ date: 46174, customer: 'x', totalAmount: 100 }, 'sales', tStub);
  ok(serial.includes('csvImport.errDateFormat'), 'validate: raw serial date still rejected as errDateFormat');
  const zero = validateLegacy({ date: '2026-07-05', customer: '文本日期客户', totalAmount: 0 }, 'sales', tStub);
  ok(zero.includes('csvImport.errAmountPositive') && !zero.includes('csvImport.errDateFormat'),
    `validate: zero-amount row fails on AMOUNT (not date), got ${JSON.stringify(zero)}`);
  const bad = validateLegacy({ date: 'not-a-date', customer: 'x', totalAmount: 100 }, 'sales', tStub);
  ok(bad.includes('csvImport.errDateFormat'), 'validate: invalid date text still rejected as errDateFormat');
}

if (failures > 0) { console.error(`✗ test-xlsx-import-dates: ${failures} assertion(s) failed`); process.exit(1); }
console.log('✓ xlsx-import-dates: all cases passed');
