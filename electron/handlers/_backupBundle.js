// 手动备份 bundle 助手（§2A#3）—— 纯 node fs/path，不依赖 electron，便于离线单测。
//
// 备份是一个文件夹：<bundle>/sololedger.db + <bundle>/attachments/docs/*（与 #152 的启动
// 自动备份同形，故两者可互相恢复）。导出用真复制（非硬链接）——用户会把文件夹挪走 / 换机，
// 硬链接到 userData 一旦原库变动就会失真。导入兼容旧的单 .db 文件（无附件）。
//
// 附件恢复采用「合并（只增不删）」语义：把 bundle 的附件 cpSync 进 userData/attachments/docs，
// 同名覆盖、绝不删除现有文件 → 即使中途失败也不丢数据（最坏是恢复后的库引用到缺失附件，
// UI 已优雅处理）；现有附件始终保留，配合恢复前的 DB 自动备份即构成完整回滚点。

const path = require('node:path');
const fs = require('node:fs');

const DB_NAME = 'sololedger.db';
const ATTACH_REL = path.join('attachments', 'docs');

function countFiles(dir) {
  let n = 0;
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return 0; }
  for (const e of entries) {
    if (e.isDirectory()) n += countFiles(path.join(dir, e.name));
    else if (e.isFile()) n++;
  }
  return n;
}

// 写出导出 bundle：真复制 DB + 附件到 destDir。绝不抛错；失败时清掉半成品目录
// （活动库 / userData 全程只读，不受影响）。调用方（handler）已用 wal_checkpoint 落盘。
function writeExportBundle({ dbPath, userDataDir, destDir } = {}) {
  try {
    if (!dbPath || !fs.existsSync(dbPath)) return { ok: false, error: 'NO_DB' };
    fs.mkdirSync(destDir, { recursive: true });
    fs.copyFileSync(dbPath, path.join(destDir, DB_NAME));
    let attachments = 0;
    const attachSrc = path.join(userDataDir, ATTACH_REL);
    if (fs.existsSync(attachSrc)) {
      const destAttach = path.join(destDir, ATTACH_REL);
      fs.cpSync(attachSrc, destAttach, { recursive: true });
      attachments = countFiles(destAttach);
    }
    return { ok: true, path: destDir, attachments };
  } catch (e) {
    try { fs.rmSync(destDir, { recursive: true, force: true }); } catch { /* ignore */ }
    return { ok: false, error: e?.message || String(e) };
  }
}

// 解析导入来源：文件夹 bundle 还是旧单 .db。
//   文件夹 → { dbSrc: <dir>/sololedger.db, attachSrc: <dir>/attachments/docs|null, isBundle:true }
//   .db 文件 → { dbSrc: srcPath, attachSrc: null, isBundle:false }
//   非法（不存在 / 文件夹里没有 sololedger.db）→ { error:'INVALID_FILE' }
function resolveImportSource(srcPath) {
  let st;
  try { st = fs.statSync(srcPath); } catch { return { error: 'INVALID_FILE' }; }
  if (st.isDirectory()) {
    const dbSrc = path.join(srcPath, DB_NAME);
    if (!fs.existsSync(dbSrc)) return { error: 'INVALID_FILE' };
    const attachSrc = path.join(srcPath, ATTACH_REL);
    return { dbSrc, attachSrc: fs.existsSync(attachSrc) ? attachSrc : null, isBundle: true };
  }
  if (st.isFile()) return { dbSrc: srcPath, attachSrc: null, isBundle: false };
  return { error: 'INVALID_FILE' };
}

// 把 bundle 附件合并进 userData/attachments/docs（只增不删，同名覆盖）。绝不抛错。
function mergeAttachments({ attachSrc, userDataDir } = {}) {
  if (!attachSrc || !fs.existsSync(attachSrc)) return { ok: true, merged: 0 };
  try {
    const dest = path.join(userDataDir, ATTACH_REL);
    fs.mkdirSync(dest, { recursive: true });
    fs.cpSync(attachSrc, dest, { recursive: true });
    return { ok: true, merged: countFiles(attachSrc) };
  } catch (e) {
    return { ok: false, error: e?.message || String(e) };
  }
}

module.exports = { writeExportBundle, resolveImportSource, mergeAttachments, countFiles, DB_NAME, ATTACH_REL };
