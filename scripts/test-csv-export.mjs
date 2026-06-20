#!/usr/bin/env node
// CSV 结构化导出（electron/handlers/_csvExport.js）测试 —— §2A。
// Part 1（始终跑，纯逻辑）：csvCell / rowsToCsv 的 RFC4180 转义 + 防公式注入 + 数字/空 + CRLF。
// Part 2（需 better-sqlite3，Electron ABI 下跳过、CI node ABI 真跑）：tableToCsv 查表→CSV、
//        白名单校验、空表只出表头、端到端注入防护。

import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const require = createRequire(import.meta.url);
const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const { csvCell, rowsToCsv, tableToCsv, EXPORTABLE_TABLES } = require(join(ROOT, 'electron/handlers/_csvExport.js'));

const failures = [];
const ok = (cond, msg) => { if (!cond) failures.push(msg); };

// ───────────── Part 1: 纯转义（始终跑）─────────────
ok(csvCell(1234) === '1234', '[cell] number → raw');
ok(csvCell(-300) === '-300', '[cell] negative number → raw (no quote/prefix)');
ok(csvCell(0) === '0', '[cell] zero → "0"');
ok(csvCell(null) === '', '[cell] null → empty');
ok(csvCell(undefined) === '', '[cell] undefined → empty');
ok(csvCell(NaN) === '', '[cell] NaN → empty');
ok(csvCell('Acme') === 'Acme', '[cell] plain string → as-is');
ok(csvCell('a,b') === '"a,b"', '[cell] comma → quoted');
ok(csvCell('he said "hi"') === '"he said ""hi"""', '[cell] quotes → quoted + doubled');
ok(csvCell('line1\nline2') === '"line1\nline2"', '[cell] newline → quoted');
// 公式注入防护：= + @ TAB CR 开头的文本前缀 '
ok(csvCell('=1+1') === "'=1+1", '[cell] =formula → prefixed quote');
ok(csvCell('+1') === "'+1", '[cell] +formula → prefixed');
ok(csvCell('@x') === "'@x", '[cell] @formula → prefixed');
ok(csvCell('\tx') === "'\tx", '[cell] TAB-lead → prefixed');
// = 开头且含逗号：先前缀 ' 再整体加引号
ok(csvCell('=A,B') === '"\'=A,B"', `[cell] =formula+comma → prefixed then quoted, got ${JSON.stringify(csvCell('=A,B'))}`);
// 文本以 - 开头也前缀（OWASP）；数字 -300 走 number 分支不受影响（见上）
ok(csvCell('-2+3') === "'-2+3", '[cell] leading - text → prefixed (OWASP)');
ok(csvCell(-300) === '-300', '[cell] negative NUMBER unaffected (number branch, no prefix)');

{
  const csv = rowsToCsv([{ a: 1, b: 'x,y' }, { a: 2, b: 'z' }], ['a', 'b']);
  ok(csv === 'a,b\r\n1,"x,y"\r\n2,z\r\n', `[rows] header+rows+CRLF, got ${JSON.stringify(csv)}`);
}
{
  const csv = rowsToCsv([], ['id', 'name']);
  ok(csv === 'id,name\r\n', '[rows] empty rows → header-only line');
}

// ───────────── PR-6 §N (N2): CSV export must NOT be able to dump credential/secret tables ─────────────
// tableToCsv looks up EXPORTABLE_TABLES BEFORE touching the db, so a non-whitelisted key throws
// INVALID_TABLE even with a null db — the ai_providers table (holds api_key_encrypted) is unreachable.
{
  let threwAi = null;
  try { tableToCsv(null, 'ai_providers'); } catch (e) { threwAi = e?.message; }
  ok(threwAi === 'INVALID_TABLE', `[N2] ai_providers (api_key_encrypted) not CSV-exportable → INVALID_TABLE, got ${threwAi}`);

  let threwSettings = null;
  try { tableToCsv(null, 'settings'); } catch (e) { threwSettings = e?.message; }
  ok(threwSettings === 'INVALID_TABLE', `[N2] settings not CSV-exportable → INVALID_TABLE, got ${threwSettings}`);

  const keys = Object.keys(EXPORTABLE_TABLES);
  ok(!keys.includes('ai_providers'), '[N2] EXPORTABLE_TABLES excludes ai_providers');
  ok(!keys.includes('settings'), '[N2] EXPORTABLE_TABLES excludes settings');
  // The whitelist must only map to KNOWN non-credential business tables — guards against a future
  // accidental addition of a secrets-bearing table (ai_providers / settings / any *key*) to the
  // export surface. (documents → business_documents is a normal business-doc table, no secrets.)
  const ALLOWED_REAL_TABLES = new Set(['transactions', 'purchases', 'sales', 'business_documents']);
  const realTables = keys.map((k) => EXPORTABLE_TABLES[k].table);
  ok(realTables.every((t) => ALLOWED_REAL_TABLES.has(t)), `[N2] every exportable table is a known non-credential business table, got [${realTables.join(',')}]`);
  ok(!realTables.some((t) => /provider|key|secret|setting|credential|token/i.test(t)), `[N2] no exportable table name looks credential-bearing, got [${realTables.join(',')}]`);
}

// ───────────── Part 2: tableToCsv on a real :memory: DB（可用时）─────────────
let Database;
try {
  Database = require('better-sqlite3');
  new Database(':memory:').close();
} catch {
  console.log('⚠ test-csv-export: Part 2 (DB) skipped — better-sqlite3 unloadable under this node (Electron ABI). Pure CSV logic above ran.');
  if (failures.length) { reportFail(); }
  console.log('✓ csv-export: Part 1 (escaping + injection guard) passed; Part 2 runs in CI.');
  process.exit(0);
}

const { runMigrations } = require(join(ROOT, 'electron/db/index.js'));
{
  const db = new Database(':memory:');
  db.pragma('foreign_keys = ON');
  runMigrations(db);

  // bad table → INVALID_TABLE
  let threw = null;
  try { tableToCsv(db, 'sqlite_master'); } catch (e) { threw = e?.message; }
  ok(threw === 'INVALID_TABLE', `[table] non-whitelisted → INVALID_TABLE, got ${threw}`);

  // empty table → header only (uses PRAGMA columns so header exists even with 0 rows)
  const empty = tableToCsv(db, 'sales');
  ok(empty.rows === 0, '[table] empty sales → 0 rows');
  ok(empty.csv.startsWith('id,date,customer,'), `[table] empty table still emits header, got ${empty.csv.slice(0, 30)}`);
  ok(empty.csv.trim().split('\r\n').length === 1, '[table] empty → header line only');

  // transactions with an injection-y counterparty → end-to-end guard
  db.prepare('INSERT INTO transactions (id, type, date, amount, counterparty) VALUES (?, ?, ?, ?, ?)')
    .run('t1', 'income', '2026-06-01', 1000, '=HYPERLINK("evil")');
  const out = tableToCsv(db, 'transactions');
  ok(out.rows === 1, `[table] transactions → 1 row, got ${out.rows}`);
  ok(out.csv.split('\r\n')[0].startsWith('id,type,date,amount'), '[table] header from schema columns');
  ok(out.csv.includes("'=HYPERLINK"), `[table] injection counterparty prefixed with ' end-to-end, got ${out.csv.includes("'=HYPERLINK")}`);
  db.close();
}

function reportFail() {
  console.error(`✗ csv-export: ${failures.length} assertion(s) failed:`);
  for (const f of failures) console.error('  - ' + f);
  process.exit(1);
}

if (failures.length) reportFail();
console.log('✓ csv-export: all checks passed (RFC4180 escaping + formula-injection guard + tableToCsv whitelist/empty/end-to-end)');
