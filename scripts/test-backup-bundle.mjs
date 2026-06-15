#!/usr/bin/env node
// 手动备份 bundle 助手（electron/handlers/_backupBundle.js）测试 —— §2A#3。
// 纯文件逻辑（临时目录 + 假文件），不依赖 electron / better-sqlite3。
//
// 断言：
//   1. writeExportBundle：bundle 含 sololedger.db（内容一致）+ attachments/docs/*（内容一致）+ 计数。
//   2. writeExportBundle 无附件目录 → 只导出 db，attachments=0。
//   3. writeExportBundle 复制中途抛错 → 不留半成品目录、ok:false。
//   4. writeExportBundle 无 db → {ok:false, error:'NO_DB'}。
//   5. resolveImportSource 文件夹 bundle → { dbSrc, attachSrc, isBundle:true }。
//   6. resolveImportSource 文件夹无 sololedger.db → { error:'INVALID_FILE' }。
//   7. resolveImportSource 文件夹 bundle 无附件 → attachSrc:null, isBundle:true。
//   8. resolveImportSource 单 .db 文件 → { dbSrc=srcPath, attachSrc:null, isBundle:false }。
//   9. resolveImportSource 不存在 → { error:'INVALID_FILE' }。
//  10. mergeAttachments 合并进现有 docs：现有文件保留、新文件加入、同名覆盖（只增不删）。
//  11. mergeAttachments 无 attachSrc → { ok:true, merged:0 }。

import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import fs from 'node:fs';
import os from 'node:os';

const require = createRequire(import.meta.url);
const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const { writeExportBundle, resolveImportSource, mergeAttachments } = require(join(ROOT, 'electron/handlers/_backupBundle.js'));

const failures = [];
const ok = (cond, msg) => { if (!cond) failures.push(msg); };

const cleanups = [];
function tmp(prefix = 'sololedger-bundle-test-') {
  const d = fs.mkdtempSync(join(os.tmpdir(), prefix));
  cleanups.push(d);
  return d;
}
function makeUserData(withAttachments = true) {
  const ud = tmp();
  fs.writeFileSync(join(ud, 'sololedger.db'), 'DB-CONTENT-X');
  if (withAttachments) {
    const docs = join(ud, 'attachments', 'docs');
    fs.mkdirSync(docs, { recursive: true });
    fs.writeFileSync(join(docs, 'doc-a.pdf'), 'AAA');
    fs.writeFileSync(join(docs, 'doc-b.pdf'), 'BBB');
  }
  return ud;
}

// ---- 1. export with attachments ----
{
  const ud = makeUserData(true);
  const dest = join(tmp(), 'backup-bundle');
  const res = writeExportBundle({ dbPath: join(ud, 'sololedger.db'), userDataDir: ud, destDir: dest });
  ok(res.ok, `[1] export should succeed, got ${JSON.stringify(res)}`);
  ok(res.attachments === 2, `[1] should count 2 attachments, got ${res.attachments}`);
  ok(fs.readFileSync(join(dest, 'sololedger.db'), 'utf8') === 'DB-CONTENT-X', '[1] db copied with matching content');
  ok(fs.readFileSync(join(dest, 'attachments', 'docs', 'doc-a.pdf'), 'utf8') === 'AAA', '[1] attachment doc-a copied');
  ok(fs.readFileSync(join(dest, 'attachments', 'docs', 'doc-b.pdf'), 'utf8') === 'BBB', '[1] attachment doc-b copied');
}

// ---- 2. export without attachments ----
{
  const ud = makeUserData(false);
  const dest = join(tmp(), 'backup-noattach');
  const res = writeExportBundle({ dbPath: join(ud, 'sololedger.db'), userDataDir: ud, destDir: dest });
  ok(res.ok && res.attachments === 0, `[2] export with no attachments → attachments:0, got ${JSON.stringify(res)}`);
  ok(fs.existsSync(join(dest, 'sololedger.db')), '[2] db still exported');
  ok(!fs.existsSync(join(dest, 'attachments')), '[2] no attachments dir created');
}

// ---- 3. export copy failure → no partial dir left ----
{
  const ud = makeUserData(true);
  const dest = join(tmp(), 'backup-fail');
  const orig = fs.copyFileSync;
  fs.copyFileSync = () => { throw new Error('ENOSPC simulated'); };
  let res;
  try { res = writeExportBundle({ dbPath: join(ud, 'sololedger.db'), userDataDir: ud, destDir: dest }); }
  finally { fs.copyFileSync = orig; }
  ok(!res.ok && res.error, `[3] copy failure → ok:false, got ${JSON.stringify(res)}`);
  ok(!fs.existsSync(dest), '[3] partial bundle dir must be cleaned up');
}

// ---- 4. export no db ----
{
  const dest = join(tmp(), 'backup-nodb');
  const res = writeExportBundle({ dbPath: join(tmp(), 'missing.db'), userDataDir: tmp(), destDir: dest });
  ok(!res.ok && res.error === 'NO_DB', `[4] missing db → NO_DB, got ${JSON.stringify(res)}`);
}

// ---- 5. resolve folder bundle (with attachments) ----
{
  const ud = makeUserData(true);
  const r = resolveImportSource(ud);
  ok(r.isBundle === true && !r.error, `[5] folder bundle → isBundle, got ${JSON.stringify(r)}`);
  ok(r.dbSrc === join(ud, 'sololedger.db'), '[5] dbSrc points at bundle db');
  ok(r.attachSrc === join(ud, 'attachments', 'docs'), '[5] attachSrc points at bundle attachments');
}

// ---- 6. resolve folder without sololedger.db ----
{
  const empty = tmp();
  const r = resolveImportSource(empty);
  ok(r.error === 'INVALID_FILE', `[6] folder w/o db → INVALID_FILE, got ${JSON.stringify(r)}`);
}

// ---- 7. resolve folder bundle without attachments ----
{
  const ud = makeUserData(false);
  const r = resolveImportSource(ud);
  ok(r.isBundle === true && r.attachSrc === null, `[7] bundle w/o attachments → attachSrc:null, got ${JSON.stringify(r)}`);
}

// ---- 8. resolve plain .db file (legacy) ----
{
  const f = join(tmp(), 'legacy.db');
  fs.writeFileSync(f, 'SQLITE');
  const r = resolveImportSource(f);
  ok(r.isBundle === false && r.dbSrc === f && r.attachSrc === null, `[8] plain .db → legacy, got ${JSON.stringify(r)}`);
}

// ---- 9. resolve nonexistent ----
{
  const r = resolveImportSource(join(tmp(), 'nope'));
  ok(r.error === 'INVALID_FILE', `[9] nonexistent → INVALID_FILE, got ${JSON.stringify(r)}`);
}

// ---- 10. mergeAttachments: additive (keep existing, add new, overwrite same-named) ----
{
  const ud = tmp();
  const dest = join(ud, 'attachments', 'docs');
  fs.mkdirSync(dest, { recursive: true });
  fs.writeFileSync(join(dest, 'existing.pdf'), 'KEEP');   // pre-existing, must survive
  fs.writeFileSync(join(dest, 'doc-a.pdf'), 'OLD');       // will be overwritten by bundle's

  const bundle = tmp();
  const bAttach = join(bundle, 'attachments', 'docs');
  fs.mkdirSync(bAttach, { recursive: true });
  fs.writeFileSync(join(bAttach, 'doc-a.pdf'), 'NEW');    // overwrites
  fs.writeFileSync(join(bAttach, 'doc-c.pdf'), 'CCC');    // added

  const m = mergeAttachments({ attachSrc: bAttach, userDataDir: ud });
  ok(m.ok, `[10] merge should succeed, got ${JSON.stringify(m)}`);
  ok(fs.readFileSync(join(dest, 'existing.pdf'), 'utf8') === 'KEEP', '[10] pre-existing attachment must survive (never delete)');
  ok(fs.readFileSync(join(dest, 'doc-a.pdf'), 'utf8') === 'NEW', '[10] same-named overwritten by bundle');
  ok(fs.readFileSync(join(dest, 'doc-c.pdf'), 'utf8') === 'CCC', '[10] new attachment added');
  ok(m.merged === 2, `[10] merged count = bundle file count (2), got ${m.merged}`);
}

// ---- 11. mergeAttachments: no attachSrc ----
{
  const m = mergeAttachments({ attachSrc: null, userDataDir: tmp() });
  ok(m.ok && m.merged === 0, `[11] no attachSrc → {ok:true,merged:0}, got ${JSON.stringify(m)}`);
}

for (const d of cleanups) { try { fs.rmSync(d, { recursive: true, force: true }); } catch { /* ignore */ } }

if (failures.length) {
  console.error(`✗ backup-bundle: ${failures.length} assertion(s) failed:`);
  for (const f of failures) console.error('  - ' + f);
  process.exit(1);
}
console.log('✓ backup-bundle: all 11 checks passed (export DB+attachments + legacy/.db & folder resolve + additive attachment merge)');
