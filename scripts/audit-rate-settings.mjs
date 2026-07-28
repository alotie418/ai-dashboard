#!/usr/bin/env node
// 税率设置项的**只读**盘点 —— A-4 §6.4 第 1 条(统计存量),A4-1 的盘点半边。
//
//   node scripts/audit-rate-settings.mjs [ledger.db ...]
//
// 不传路径时盘点两个 App 的默认账本位置。**只读,从不修改任何一个字节**:
// 数据库以 SQLite 的只读模式打开,脚本里没有一条 INSERT / UPDATE / DELETE。
// 迁移不在这里 —— §6.4 第 3 条要求存量走用户确认的修复流程,零静默迁移,
// 那个入口按拍板归原生 R8。这个脚本只回答「有多少、分别是哪一类、今天会怎么算」。
//
// 判定与写侧封口共用 electron/handlers/_rateValue.js 的同一份规则,不另写一份。
//
// 退出码:0 = 没有需修复的行;1 = 发现需修复的行(可直接用在 CI 或人工巡检里)。
// 「行缺失」不在本脚本的视野内,那是另一个状态(未配置),由行的存在与否判定,
// 而 A-3 禁止从值反推 —— 一个查不到的行在这里就是查不到,不是坏行。
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { existsSync } from 'node:fs';
import { homedir } from 'node:os';

const require = createRequire(import.meta.url);
const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const { RATE_KEYS, classifyStoredRate } = require(join(ROOT, 'electron/handlers/_rateValue.js'));

let Database;
try {
  Database = require(join(ROOT, 'node_modules/better-sqlite3'));
  new Database(':memory:').close();
} catch (e) {
  console.log('⚠ audit-rate-settings SKIPPED: better-sqlite3 在当前 node 下加载不了。');
  console.log('  原因:', e?.message?.split('\n')[0] || e);
  process.exit(0);
}

const DEFAULT_LEDGERS = [
  join(homedir(), 'Library/Application Support/SoloLedger/sololedger.db'),
  join(homedir(), 'Library/Application Support/SoloLedgerNativePreview/sololedger.db'),
];

const targets = process.argv.slice(2);
const ledgers = (targets.length > 0 ? targets : DEFAULT_LEDGERS).filter((p) => {
  if (existsSync(p)) return true;
  if (targets.length > 0) console.error(`  ✗ 找不到:${p}`);
  return false;
});

if (ledgers.length === 0) {
  console.log('\n=== 税率设置项盘点(只读)===\n');
  console.log('没有可盘点的账本。传入路径:node scripts/audit-rate-settings.mjs <ledger.db>\n');
  process.exit(0);
}

const keyList = [...RATE_KEYS].map((k) => `'${k}'`).join(',');
let damagedTotal = 0;
let scanned = 0;

console.log('\n=== 税率设置项盘点(只读)===\n');

for (const path of ledgers) {
  let db;
  try {
    // readonly:即便脚本写错了也写不进去。fileMustExist 让路径错误立刻可见。
    db = new Database(path, { readonly: true, fileMustExist: true });
  } catch (e) {
    console.log(`  ${path}\n    ✗ 打不开(WAL 账本需要一并复制 -wal/-shm):${e?.message?.split('\n')[0]}`);
    continue;
  }
  scanned++;
  let rows = [];
  try {
    rows = db.prepare(`SELECT key, value FROM settings WHERE key IN (${keyList}) ORDER BY key`).all();
  } catch {
    console.log(`  ${path}\n    (没有 settings 表)`);
    db.close();
    continue;
  }
  db.close();

  console.log(`  ${path}`);
  if (rows.length === 0) { console.log('    没有任何税率行(全部「未配置」)\n'); continue; }
  for (const row of rows) {
    const c = classifyStoredRate(row.value);
    if (!c.usable) damagedTotal++;
    const mark = c.usable ? '✓' : '✗';
    console.log(`    ${mark} ${row.key.padEnd(22)} ${JSON.stringify(row.value).padEnd(14)} ${c.verdict}`);
    if (!c.usable) console.log(`      → ${c.effect}`);
  }
  const missing = [...RATE_KEYS].filter((k) => !rows.some((r) => r.key === k));
  if (missing.length > 0) console.log(`    （行缺失,不属于本盘点:${missing.join(', ')}）`);
  console.log('');
}

console.log('────────');
console.log(`盘点账本 ${scanned} 个,需修复的税率行 ${damagedTotal} 个。`);
if (damagedTotal > 0) {
  console.log('\n这些行不会让报表报错,它们会让报表**照常出数**——只是数不对。');
  console.log('修复入口按拍板归原生 R8(用户确认、零静默迁移);本脚本不改任何数据。\n');
  process.exit(1);
}
console.log('没有发现需修复的税率行。\n');
