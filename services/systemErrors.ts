// §2A PR-2a — 前端共享系统错误（磁盘满 / IO 异常 / 只读·权限）解析 + 文案工具。
//
// 后端 api:request 包装器（electron/handlers/index.js）把 SqliteError / fs 错误码以
// "AI_ERR:<code>" 前缀塞进 Error.message（Electron IPC 不传 Error 自定义字段）。CRUD 写
// 失败到前端是一个普通 Error，message 形如 "AI_ERR:SQLITE_FULL · ... (database or disk is full)"，
// 且 err.code 在前端为 undefined。这里从 err.code 或 err.message 提取该码并归一化为稳定类别，
// 供页面 catch 在显示通用「保存失败」前先判磁盘错 → 给可操作提示（systemError.*，PR-2b 接线）。
//
// 镜像 electron/handlers/_dbError.js 的分类（CJS 在主进程侧、前端无法直接 import），并额外
// 兼容 fs 的 EIO 与 PR-1 的输出码（DISK_FULL/DISK_IO/READONLY）。纯函数、零依赖、零副作用；
// 未知错误一律返回 null（调用方回退原有提示，行为不变）。本文件 PR-2a 不被任何页面引用。

export type SystemErrorKind = 'diskFull' | 'diskIo' | 'readonly';

// 从 message 的 "AI_ERR:<code>" 前缀抓【完整】码：[A-Z] 起始 + 允许下划线/数字，
// 这样 SQLITE_FULL / SQLITE_IOERR_WRITE 不会被截成 SQLITE；同时大写起始天然排除
// AI 错误码（auth/timeout/unknown/noProvider… 均小写或驼峰起始）。
const AI_ERR_RE = /AI_ERR:([A-Z][A-Z0-9_]*)/;

/** 把单个错误码字符串归一化为系统错误类别（未知→null）。 */
function classifyCode(code: string | null | undefined): SystemErrorKind | null {
  if (!code || typeof code !== 'string') return null;

  // 磁盘空间 / 配额耗尽。
  if (code === 'SQLITE_FULL' || code === 'ENOSPC' || code === 'EDQUOT' || code === 'DISK_FULL') {
    return 'diskFull';
  }
  // 只读 / 权限：库或卷不可写（含 SQLITE_READONLY 扩展码 + fs EROFS/EACCES + PR-1 输出码）。
  if (code === 'SQLITE_READONLY' || code.startsWith('SQLITE_READONLY_') ||
      code === 'EROFS' || code === 'EACCES' || code === 'READONLY') {
    return 'readonly';
  }
  // 磁盘 IO 异常（含 SQLITE_IOERR 扩展码 + fs EIO + PR-1 输出码）。
  if (code === 'SQLITE_IOERR' || code.startsWith('SQLITE_IOERR_') || code === 'EIO' || code === 'DISK_IO') {
    return 'diskIo';
  }
  // 其它（SQLITE_CONSTRAINT / SQLITE_BUSY / AI 码 / 无码）→ 不分类。
  return null;
}

/**
 * 从被 catch 的错误提取系统错误类别。
 * 先认 err.code（app:* 结果码或未来可能带的字段），再从 err.message 的 "AI_ERR:<code>"
 * 前缀解析（CRUD 经 api:request 的主路径）。未命中返回 null。
 */
export function parseSystemErrorCode(err: unknown): SystemErrorKind | null {
  if (err == null) return null;
  const e = err as { code?: unknown; message?: unknown };

  if (typeof e.code === 'string') {
    const byCode = classifyCode(e.code);
    if (byCode) return byCode;
  }

  const msg = typeof e.message === 'string' ? e.message : (typeof err === 'string' ? err : '');
  const m = msg.match(AI_ERR_RE);
  if (m) return classifyCode(m[1]);
  return null;
}

/**
 * 命中磁盘满 / IO / 只读错误时返回可操作的本地化文案，否则返回 null
 * （调用方回退到自身原有的通用错误提示，确保行为不变）。
 * @param err 被 catch 的错误（Error / 任意）
 * @param t   i18n 翻译函数
 */
export function getSystemErrorText(err: unknown, t: (key: string) => string): string | null {
  const kind = parseSystemErrorCode(err);
  return kind ? t(`systemError.${kind}`) : null;
}
