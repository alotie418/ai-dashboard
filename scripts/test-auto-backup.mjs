#!/usr/bin/env node
// 启动滚动快照（electron/db/autoBackup.js）测试 —— §2A 数据安全。
// 纯文件逻辑（临时目录 + 假文件 + utimesSync 显式设 mtime，不受文件系统时间精度影响）；
// 不实例化 better-sqlite3——该原生模块按 Electron ABI 编出，plain node 加载不了（与
// test-recategorize.mjs 同约定）。故 checkpoint 用 spy 断言「调用 + 顺序 + 吞错」，
// 而「checkpoint 真把 -wal 落盘、单 .db 拷贝含最新提交」属 SQLite 自身行为，其真实往返
// 验证留给 §2B 的真 Electron e2e（需 Electron 上下文）。
//
// 断言：
//   1. force → 生成 auto-* 目录，内含 sololedger.db（内容一致）。
//   2. 附件目录存在时一并入备份（硬链接，内容一致）。
//   3. 去重：非强制 + DB 未变（mtime < 最近备份）→ skip，不新增目录。
//   4. DB 变化（mtime 变新）→ 非强制也照备。
//   5. prune 隔离：超额预置后，恰好保留最新 max 份。
//   6. 无 DB 文件 → skip(no-db)，不创建任何东西。
//   7. 隔离：恢复前安全网扁平文件不被裁剪。
//   8. 失败原子性：复制中途抛错 → 不留半成品 auto-*，也不留 .tmp-auto-*。
//   9. checkpoint：传入 db 句柄时在「快照目录创建之前」先调 wal_checkpoint(TRUNCATE)；
//      pragma 抛错被吞，仍备成。
//  10. 去重边界：DB mtime == 最近备份 mtime → 偏向备份（< 而非 <=）。
//  11. stale temp：上次崩溃遗留的 .tmp-auto-* 在下次备份时被清掉。

import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import fs from 'node:fs';
import os from 'node:os';

const require = createRequire(import.meta.url);
const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const { autoBackup, listAutoBackups, prune, PREFIX, TMP_PREFIX } = require(join(ROOT, 'electron/db/autoBackup.js'));

const failures = [];
const ok = (cond, msg) => { if (!cond) failures.push(msg); };

const cleanups = [];
function freshUserData() {
  const dir = fs.mkdtempSync(join(os.tmpdir(), 'sololedger-backup-test-'));
  cleanups.push(dir);
  return dir;
}
function writeDb(userData, bytes = 'SQLite format 3 fake-db-content') {
  const p = join(userData, 'sololedger.db');
  fs.writeFileSync(p, bytes);
  return p;
}
function setMtime(p, msFromNow) {
  const t = new Date(Date.now() + msFromNow);
  fs.utimesSync(p, t, t);
}

// ---- 1 + 2. force 备份生成目录 + 附件入备份 ----
{
  const userData = freshUserData();
  const dbPath = writeDb(userData, 'DB-CONTENT-A');
  const attachDir = join(userData, 'attachments', 'docs');
  fs.mkdirSync(attachDir, { recursive: true });
  fs.writeFileSync(join(attachDir, 'doc-x.pdf'), 'PDFDATA');

  const res = autoBackup({ db: null, dbPath, force: true, max: 10 });
  ok(res.ok, `[1] force backup should succeed, got ${JSON.stringify(res)}`);
  const backups = listAutoBackups(join(userData, 'backups'));
  ok(backups.length === 1, `[1] expected 1 auto-* dir, got ${backups.length}`);
  if (backups.length === 1) {
    const dbCopy = join(backups[0], 'sololedger.db');
    ok(fs.existsSync(dbCopy), '[1] backup must contain sololedger.db');
    ok(fs.readFileSync(dbCopy, 'utf8') === 'DB-CONTENT-A', '[1] db copy content must match source');
    const attachCopy = join(backups[0], 'attachments', 'docs', 'doc-x.pdf');
    ok(fs.existsSync(attachCopy), '[2] attachment must be in backup');
    ok(fs.readFileSync(attachCopy, 'utf8') === 'PDFDATA', '[2] attachment content must match');
  }
}

// ---- 3. 去重：DB 未变 → skip ----
{
  const userData = freshUserData();
  const dbPath = writeDb(userData);
  ok(autoBackup({ db: null, dbPath, force: true, max: 10 }).ok, '[3] first backup should succeed');
  setMtime(dbPath, -10_000); // DB 早于刚生成的备份目录 → 视为未变
  const second = autoBackup({ db: null, dbPath, force: false, max: 10 });
  ok(second.skipped && second.reason === 'unchanged', `[3] unchanged should skip, got ${JSON.stringify(second)}`);
  ok(listAutoBackups(join(userData, 'backups')).length === 1, '[3] no new dir when unchanged');
}

// ---- 4. DB 变化 → 非强制也备 ----
{
  const userData = freshUserData();
  const dbPath = writeDb(userData);
  autoBackup({ db: null, dbPath, force: true, max: 10 });
  setMtime(dbPath, +60_000); // DB 晚于备份 → 有变化
  const res = autoBackup({ db: null, dbPath, force: false, max: 10 });
  ok(res.ok, `[4] changed db should back up, got ${JSON.stringify(res)}`);
  ok(listAutoBackups(join(userData, 'backups')).length === 2, '[4] should now have 2 dirs');
}

// ---- 5. prune 隔离：超额 → 恰好保留最新 max 份 ----
{
  const userData = freshUserData();
  const backupsDir = join(userData, 'backups');
  fs.mkdirSync(backupsDir, { recursive: true });
  const names = [];
  for (let i = 0; i < 5; i++) {
    const name = `${PREFIX}seed-${i}`;
    fs.mkdirSync(join(backupsDir, name));
    setMtime(join(backupsDir, name), i * 1000); // i 越大越新
    names.push(name);
  }
  prune(backupsDir, 3);
  const survivors = listAutoBackups(backupsDir).map((p) => p.split('/').pop()).sort();
  ok(survivors.length === 3, `[5] prune should keep exactly 3, got ${survivors.length}`);
  ok(JSON.stringify(survivors) === JSON.stringify(['auto-seed-2', 'auto-seed-3', 'auto-seed-4']),
    `[5] prune must keep the 3 NEWEST, kept ${JSON.stringify(survivors)}`);
}

// ---- 6. 无 DB → skip(no-db) ----
{
  const userData = freshUserData();
  const res = autoBackup({ db: null, dbPath: join(userData, 'sololedger.db'), force: true, max: 10 });
  ok(res.skipped && res.reason === 'no-db', `[6] missing db should skip(no-db), got ${JSON.stringify(res)}`);
  ok(!fs.existsSync(join(userData, 'backups')), '[6] no backups dir should be created');
}

// ---- 7. 隔离：恢复前安全网扁平文件不被裁剪 ----
{
  const userData = freshUserData();
  const dbPath = writeDb(userData);
  const backupsDir = join(userData, 'backups');
  fs.mkdirSync(backupsDir, { recursive: true });
  const safetyNet = join(backupsDir, 'sololedger-autobackup-before-restore-2026-01-01.db');
  fs.writeFileSync(safetyNet, 'SAFETY');
  for (let i = 0; i < 5; i++) autoBackup({ db: null, dbPath, force: true, max: 2 });
  ok(fs.existsSync(safetyNet), '[7] restore safety-net flat file must survive pruning');
  ok(listAutoBackups(backupsDir).length === 2, '[7] auto-* dirs still pruned to max alongside it');
}

// ---- 8. 失败原子性：复制中途抛错 → 不留半成品 ----
{
  const userData = freshUserData();
  const dbPath = writeDb(userData);
  const orig = fs.copyFileSync;
  fs.copyFileSync = () => { throw new Error('ENOSPC simulated'); };
  let res;
  try { res = autoBackup({ db: null, dbPath, force: true, max: 10 }); }
  finally { fs.copyFileSync = orig; }
  ok(!res.ok && res.error, `[8] copy failure should return {ok:false,error}, got ${JSON.stringify(res)}`);
  const backupsDir = join(userData, 'backups');
  ok(listAutoBackups(backupsDir).length === 0, '[8] NO auto-* dir may be left after a failed copy');
  const leftoverTmp = fs.readdirSync(backupsDir).filter((n) => n.startsWith(TMP_PREFIX));
  ok(leftoverTmp.length === 0, `[8] NO .tmp-auto-* may be left, found ${JSON.stringify(leftoverTmp)}`);
}

// ---- 9. checkpoint 在快照创建前被调用 + pragma 抛错被吞 ----
{
  const userData = freshUserData();
  const dbPath = writeDb(userData);
  const backupsDir = join(userData, 'backups');
  const calls = [];
  // 记录调用时快照是否已存在 —— 证明 checkpoint 先于快照目录创建（一致性所需的顺序）。
  const spyDb = { pragma: (arg) => calls.push({ arg, snapshotsAtCall: listAutoBackups(backupsDir).length }) };
  const res = autoBackup({ db: spyDb, dbPath, force: true, max: 10 });
  ok(res.ok, '[9] backup with db handle should succeed');
  ok(calls[0]?.arg === 'wal_checkpoint(TRUNCATE)', `[9] must checkpoint first, calls=${JSON.stringify(calls)}`);
  ok(calls[0]?.snapshotsAtCall === 0, '[9] checkpoint must run BEFORE the snapshot dir is created');

  const userData2 = freshUserData();
  const dbPath2 = writeDb(userData2);
  const throwingDb = { pragma: () => { throw new Error('db locked'); } };
  const res2 = autoBackup({ db: throwingDb, dbPath: dbPath2, force: true, max: 10 });
  ok(res2.ok, `[9] throwing checkpoint must be swallowed and still back up, got ${JSON.stringify(res2)}`);
}

// ---- 10. 去重边界：DB mtime == 最近备份 mtime → 偏向备份 ----
{
  const userData = freshUserData();
  const dbPath = writeDb(userData);
  autoBackup({ db: null, dbPath, force: true, max: 10 });
  const backupDir = listAutoBackups(join(userData, 'backups'))[0];
  const t = new Date(Date.now() - 5000);
  fs.utimesSync(dbPath, t, t);
  fs.utimesSync(backupDir, t, t); // 精确相等
  const res = autoBackup({ db: null, dbPath, force: false, max: 10 });
  ok(res.ok, `[10] at mtime equality, should back up (< not <=), got ${JSON.stringify(res)}`);
  ok(listAutoBackups(join(userData, 'backups')).length === 2, '[10] equality should yield a 2nd backup');
}

// ---- 11. stale temp：遗留 .tmp-auto-* 下次备份时被清掉 ----
{
  const userData = freshUserData();
  const dbPath = writeDb(userData);
  const backupsDir = join(userData, 'backups');
  fs.mkdirSync(backupsDir, { recursive: true });
  const staleTmp = join(backupsDir, `${TMP_PREFIX}crashed-run`);
  fs.mkdirSync(staleTmp);
  fs.writeFileSync(join(staleTmp, 'sololedger.db'), 'HALF');
  const res = autoBackup({ db: null, dbPath, force: true, max: 10 });
  ok(res.ok, '[11] backup should succeed');
  ok(!fs.existsSync(staleTmp), '[11] stale .tmp-auto-* must be cleaned');
  ok(listAutoBackups(backupsDir).length === 1, '[11] exactly one valid auto-* after run');
}

// ---- 清理临时目录 ----
for (const dir of cleanups) {
  try { fs.rmSync(dir, { recursive: true, force: true }); } catch { /* ignore */ }
}

if (failures.length) {
  console.error(`✗ auto-backup: ${failures.length} assertion(s) failed:`);
  for (const f of failures) console.error('  - ' + f);
  process.exit(1);
}
console.log('✓ auto-backup: all 11 cases passed (atomic snapshot + checkpoint ordering + hardlink attachments + dedup + retention + failure-safety + isolation)');
