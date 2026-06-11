// 业务单据附件路径安全助手（Phase D）
// 附件统一存放在 userData/attachments/docs/，数据库只存相对 userData 的路径
// （如 attachments/docs/doc-xxx-abc.pdf），userData 迁移后仍可解析。
// 安全双保险：白名单正则（仅限该目录下单层文件名、合法字符）+ resolve 后的
// 目录包含校验——渲染端可触达的打开/删除通道在构造上无法越出该目录。
// require('electron') 懒加载，保持本模块在任何主进程上下文可被加载。

const path = require('node:path');
const fs = require('node:fs');

const REL_RE = /^attachments\/docs\/[A-Za-z0-9][A-Za-z0-9._-]*$/;

function isValidAttachmentRelPath(rel) {
  return typeof rel === 'string' && REL_RE.test(rel) && !rel.includes('..');
}

function getDocsAttachmentsRoot() {
  const { app } = require('electron');
  return path.join(app.getPath('userData'), 'attachments', 'docs');
}

// 相对路径 → 绝对路径；非法/越界返回 null
function resolveAttachment(rel) {
  if (!isValidAttachmentRelPath(rel)) return null;
  const { app } = require('electron');
  const userData = app.getPath('userData');
  const abs = path.resolve(userData, rel);
  const root = path.resolve(userData, 'attachments', 'docs');
  if (!abs.startsWith(root + path.sep)) return null;
  return abs;
}

// best-effort 删除应用内附件副本（替换/清除/删单据时的自清洁；失败静默）
function safeDeleteAttachment(rel) {
  const abs = resolveAttachment(rel);
  if (!abs) return false;
  try { fs.rmSync(abs, { force: true }); return true; } catch { return false; }
}

module.exports = { isValidAttachmentRelPath, resolveAttachment, safeDeleteAttachment, getDocsAttachmentsRoot };
