// §2A 数据安全 — SQLite / fs 写失败错误分类器（PR-0）
//
// 纯函数、零依赖（不 require electron / better-sqlite3 / fs；只读 err.code 字符串）。
// 把磁盘满 / IO 异常 / 只读·权限 三类系统级写失败归一化为稳定类别，供后续 PR
// （PR-1 备份·附件 catch、PR-2 api:request 包装器）贴码、前端配可操作 i18n。
//
// 设计约束：
//   - 不抛错、不改入参；对**未知错误一律返回 null**，让调用方走原有通用提示路径，
//     保证「现有行为不回退」——本文件被引入但未接线时，全项目行为零变化。
//   - 只认确定无歧义的码：业务约束错误（SQLITE_CONSTRAINT，已由 documents.js 处理成
//     DOC_NUMBER_EXISTS）与可重试的 SQLITE_BUSY（已由 busy_timeout + 单实例锁缓解）
//     **不在此分类**，返回 null。
//
// 返回值枚举（camelCase = 未来 i18n leaf）：
//   'diskFull' | 'diskIo' | 'readonly' | null

'use strict';

/**
 * 归一化 SQLite / fs 写失败错误码。
 * @param {*} err 任意被 catch 的值（Error / SqliteError / fs errno error / 任意）。
 * @returns {'diskFull'|'diskIo'|'readonly'|null}
 */
function classifyFsDbError(err) {
  const code = err && typeof err.code === 'string' ? err.code : null;
  if (!code) return null;

  // 磁盘空间 / 配额耗尽：SQLite 报满，或 fs 的 ENOSPC / EDQUOT。
  if (code === 'SQLITE_FULL' || code === 'ENOSPC' || code === 'EDQUOT') return 'diskFull';

  // 只读 / 权限：库或卷不可写。SQLITE_READONLY 及其扩展码（SQLITE_READONLY_*）、
  // fs 的 EROFS（只读文件系统）/ EACCES（权限不足）。
  if (code === 'SQLITE_READONLY' || code.startsWith('SQLITE_READONLY_') ||
      code === 'EROFS' || code === 'EACCES') {
    return 'readonly';
  }

  // 磁盘 IO 异常：SQLITE_IOERR 及其扩展码（SQLITE_IOERR_WRITE / _FSYNC / _READ …）。
  if (code === 'SQLITE_IOERR' || code.startsWith('SQLITE_IOERR_')) return 'diskIo';

  // 其它（含 SQLITE_CONSTRAINT / SQLITE_BUSY / 业务错误 / 无 code）→ 不分类。
  return null;
}

module.exports = { classifyFsDbError };
