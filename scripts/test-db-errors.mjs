// 守卫：§2A SQLite / fs 写失败错误分类器（PR-0）。
//
// 锁定 electron/handlers/_dbError.js 的 classifyFsDbError 纯函数映射。
// 纯 Node：不起 Electron、不碰 better-sqlite3（无原生绑定）、不碰浏览器 → 任何 ABI 下都真跑。
// 目的：把「磁盘满 / IO 异常 / 只读·权限」三类系统错误归类固化，并确保**未知错误返回 null**
// （即「现有通用提示路径不回退」的契约）。本守卫只验分类逻辑，不改任何运行时行为。

import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const require = createRequire(import.meta.url);
const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const { classifyFsDbError, diskErrorCode } = require(join(ROOT, 'electron/handlers/_dbError.js'));

const failures = [];
let total = 0;
const eq = (input, expected, label) => {
  total++;
  const got = classifyFsDbError(input);
  if (got !== expected) failures.push(`classify ${label}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(got)}`);
};
const ce = (input, expected, label) => {
  total++;
  const got = diskErrorCode(input);
  if (got !== expected) failures.push(`diskErrorCode ${label}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(got)}`);
};

// ── 磁盘满 / 配额 → 'diskFull' ──
eq({ code: 'SQLITE_FULL' }, 'diskFull', 'SQLITE_FULL');
eq({ code: 'ENOSPC' }, 'diskFull', 'ENOSPC');
eq({ code: 'EDQUOT' }, 'diskFull', 'EDQUOT');

// ── 磁盘 IO 异常（含扩展码）→ 'diskIo' ──
eq({ code: 'SQLITE_IOERR' }, 'diskIo', 'SQLITE_IOERR');
eq({ code: 'SQLITE_IOERR_WRITE' }, 'diskIo', 'SQLITE_IOERR_WRITE');
eq({ code: 'SQLITE_IOERR_FSYNC' }, 'diskIo', 'SQLITE_IOERR_FSYNC (extended)');

// ── 只读 / 权限（含扩展码）→ 'readonly' ──
eq({ code: 'SQLITE_READONLY' }, 'readonly', 'SQLITE_READONLY');
eq({ code: 'SQLITE_READONLY_RECOVERY' }, 'readonly', 'SQLITE_READONLY_RECOVERY (extended)');
eq({ code: 'EROFS' }, 'readonly', 'EROFS');
eq({ code: 'EACCES' }, 'readonly', 'EACCES');

// ── 不分类（走原有通用路径）→ null ──
eq(new Error('boom'), null, 'plain Error (no code)');
eq({ code: 'SQLITE_CONSTRAINT' }, null, 'SQLITE_CONSTRAINT (business — handled elsewhere)');
eq({ code: 'SQLITE_BUSY' }, null, 'SQLITE_BUSY (retryable — busy_timeout/single-instance)');
eq({ code: 'ENOENT' }, null, 'ENOENT (unrelated fs errno)');
eq({ code: 'SQLITE' }, null, 'SQLITE (prefix only, not a real disk/io code)');
eq({}, null, 'empty object (no code)');
eq({ code: 123 }, null, 'non-string code');
eq('SQLITE_FULL', null, 'string input (no .code property)');
eq(null, null, 'null');
eq(undefined, null, 'undefined');

// ── diskErrorCode: 类别 → 稳定错误码（命中→DISK_*；未命中→null，handler 回退原码）──
ce({ code: 'SQLITE_FULL' }, 'DISK_FULL', 'SQLITE_FULL → DISK_FULL');
ce({ code: 'ENOSPC' }, 'DISK_FULL', 'ENOSPC → DISK_FULL');
ce({ code: 'SQLITE_IOERR_WRITE' }, 'DISK_IO', 'SQLITE_IOERR_WRITE → DISK_IO');
ce({ code: 'SQLITE_READONLY' }, 'READONLY', 'SQLITE_READONLY → READONLY');
ce({ code: 'EROFS' }, 'READONLY', 'EROFS → READONLY');
ce({ code: 'EACCES' }, 'READONLY', 'EACCES → READONLY');
ce({ code: 'COPY_FAILED' }, null, 'COPY_FAILED → null (handler keeps its own code)');
ce(new Error('boom'), null, 'plain Error → null');
ce(null, null, 'null → null');

if (failures.length) {
  console.error(`✗ db-errors: ${failures.length}/${total} case(s) failed`);
  for (const f of failures) console.error('  -', f);
  process.exit(1);
}
console.log(`✓ db-errors: all ${total} cases passed (classifyFsDbError + diskErrorCode: SQLite FULL/IOERR*/READONLY* + fs ENOSPC/EDQUOT/EROFS/EACCES → diskFull/diskIo/readonly → DISK_FULL/DISK_IO/READONLY; CONSTRAINT/BUSY/unknown/null → null)`);
