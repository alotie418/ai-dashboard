// 启动时（迁移前）滚动快照 —— §2A 数据安全：保护「唯一账本」。
//   迁移写错数据、日常误删、磁盘故障前都留有回滚点；不是「恢复前安全网」（那条在
//   app:importDb 里，写扁平 sololedger-autobackup-before-restore-*.db），两者互不干扰。
//
// 布局：userData/backups/auto-<ISO 时间戳>-<随机>/{ sololedger.db, attachments/docs/* }
//   每份快照是一个目录，DB 与其附件配对存放，便于一起保留 / 一起淘汰。保留最近 N 份。
//
// 原子性：先写入临时目录 .tmp-auto-*，DB + 附件全部就位后才同目录 rename 成 auto-*
//   （同卷 rename 原子）。任何一步失败 / 进程崩溃，残留的只会是 .tmp-auto-*（永不被
//   listAutoBackups/prune/dedup 看见，下次启动 cleanStaleTemp 清掉），绝不会出现半成品的
//   auto-* 被当成有效快照（沿用 app:importDb 恢复路径「copy→rename 防半成品」的先例）。
//
// 一致性：复制前先 wal_checkpoint(TRUNCATE) 把 WAL 落盘到主库，单 .db 即完整快照
//   （沿用 app:exportDb 的成熟做法）。db 句柄可缺省（缺省仅跳过 checkpoint，不报错）。
//
// 附件：硬链接而非整树复制 —— 附件一旦存盘即不可变（唯一文件名、只增删不改写），
//   同卷硬链接零拷贝、零额外磁盘，避免大附件目录拖慢启动 / N 份快照占 N× 磁盘；
//   跨卷或不支持时退化为整文件复制。删除某份快照只解链接，数据由其余链接（含活动库）保留。
//
// 纯 node fs/path，不 require('electron')：所有目标路径从传入的 dbPath 同目录派生
//   （getDbPath() 返回 userData/sololedger.db，故 dirname = userData），便于离线单测。

const path = require('node:path');
const fs = require('node:fs');

const PREFIX = 'auto-';
const TMP_PREFIX = '.tmp-auto-'; // 半成品临时目录前缀；故意不以 auto- 开头，对快照逻辑不可见
const DEFAULT_MAX = 10;

function stamp() {
  // 文件系统安全的时间戳；随机后缀防同毫秒两次备份目录名碰撞（正常每次启动只备一次）。
  const iso = new Date().toISOString().replace(/[:.]/g, '-');
  return `${iso}-${Math.random().toString(36).slice(2, 6)}`;
}

function safeMtime(p) {
  try { return fs.statSync(p).mtimeMs; } catch { return 0; }
}

// .db 及其 -wal 旁文件里最新的修改时间。WAL 模式下新写入先落 -wal，主库 mtime 不变，
// 故要取两者较大值才能判断「自上次备份以来内容是否变过」。
function dbContentMtime(dbPath) {
  let m = 0;
  for (const f of [dbPath, `${dbPath}-wal`]) {
    const t = safeMtime(f);
    if (t > m) m = t;
  }
  return m;
}

function listAutoBackups(backupsDir) {
  try {
    return fs.readdirSync(backupsDir, { withFileTypes: true })
      .filter((e) => e.isDirectory() && e.name.startsWith(PREFIX))
      .map((e) => path.join(backupsDir, e.name));
  } catch {
    return []; // 目录还不存在
  }
}

function newestBackupMtime(backupsDir) {
  let newest = null;
  for (const dir of listAutoBackups(backupsDir)) {
    const m = safeMtime(dir);
    if (newest == null || m > newest) newest = m;
  }
  return newest;
}

// 保留最近 max 份 auto-* 快照，其余删除（按 mtime 新→旧排序后裁掉超额）。
function prune(backupsDir, max) {
  const dirs = listAutoBackups(backupsDir)
    .map((dir) => ({ dir, m: safeMtime(dir) }))
    .sort((a, b) => b.m - a.m);
  for (const { dir } of dirs.slice(Math.max(0, max))) {
    try { fs.rmSync(dir, { recursive: true, force: true }); } catch { /* best effort */ }
  }
}

// 清理上次崩溃 / 失败遗留的半成品临时目录（绝不会是有效快照）。
function cleanStaleTemp(backupsDir) {
  let entries;
  try { entries = fs.readdirSync(backupsDir, { withFileTypes: true }); } catch { return; }
  for (const e of entries) {
    if (e.isDirectory() && e.name.startsWith(TMP_PREFIX)) {
      try { fs.rmSync(path.join(backupsDir, e.name), { recursive: true, force: true }); } catch { /* ignore */ }
    }
  }
}

// 附件入备份：逐文件硬链接，失败（跨卷 EXDEV / 不支持 EMLINK·EPERM）退化为整文件复制。
// attachments/docs 现为单层文件，但仍递归以防未来嵌套；跳过符号链接 / 特殊文件。
function linkOrCopyTree(srcDir, destDir) {
  fs.mkdirSync(destDir, { recursive: true });
  for (const e of fs.readdirSync(srcDir, { withFileTypes: true })) {
    const s = path.join(srcDir, e.name);
    const d = path.join(destDir, e.name);
    if (e.isDirectory()) { linkOrCopyTree(s, d); continue; }
    if (!e.isFile()) continue;
    try { fs.linkSync(s, d); } catch { fs.copyFileSync(s, d); }
  }
}

// 执行一次自动备份。返回 { ok, skipped?, reason?, path?, error? }；绝不抛错——
// 启动流程不允许被备份失败阻断（最坏情况是这次没备成，下次再备）。
function autoBackup({ db, dbPath, force = false, max = DEFAULT_MAX } = {}) {
  try {
    if (!dbPath || !fs.existsSync(dbPath)) {
      return { ok: false, skipped: true, reason: 'no-db' }; // 新装首启：无数据可备
    }
    const userData = path.dirname(dbPath);
    const backupsDir = path.join(userData, 'backups');
    fs.mkdirSync(backupsDir, { recursive: true });
    cleanStaleTemp(backupsDir);

    // 去重（best-effort）：非强制 且 自上次备份以来 DB 未变 → 跳过，避免反复开关应用刷出一堆
    // 相同快照、把有意义的历史挤出保留窗口。用 < 不用 <=：时间戳相等时偏向「备一份」（更安全）。
    // 注意：这是基于 mtime 的启发式，系统时钟回拨等极端情况可能误判为「未变」而漏备一次——
    // 但关键的「迁移前快照」由调用方传 force 绕过去重，其正确性不依赖本启发式。
    if (!force) {
      const newest = newestBackupMtime(backupsDir);
      if (newest != null && dbContentMtime(dbPath) < newest) {
        return { ok: false, skipped: true, reason: 'unchanged' };
      }
    }

    try { db?.pragma?.('wal_checkpoint(TRUNCATE)'); } catch { /* best effort：失败时下面仍拷主库 */ }

    // 先写临时目录，全部就位后原子 rename → 永不留半成品 auto-*。
    const tmp = path.join(backupsDir, `${TMP_PREFIX}${stamp()}`);
    const dest = path.join(backupsDir, `${PREFIX}${stamp()}`);
    try {
      fs.mkdirSync(tmp, { recursive: true });
      fs.copyFileSync(dbPath, path.join(tmp, 'sololedger.db'));
      const attachSrc = path.join(userData, 'attachments', 'docs');
      if (fs.existsSync(attachSrc)) {
        linkOrCopyTree(attachSrc, path.join(tmp, 'attachments', 'docs'));
      }
      fs.renameSync(tmp, dest); // 同卷 rename 原子：要么完整 auto-* 出现，要么什么都没有
    } catch (e) {
      try { fs.rmSync(tmp, { recursive: true, force: true }); } catch { /* ignore */ }
      throw e;
    }

    prune(backupsDir, max);
    return { ok: true, path: dest };
  } catch (e) {
    return { ok: false, error: e?.message || String(e) };
  }
}

module.exports = { autoBackup, dbContentMtime, listAutoBackups, prune, cleanStaleTemp, PREFIX, TMP_PREFIX, DEFAULT_MAX };
