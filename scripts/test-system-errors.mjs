// 守卫：§2A PR-2a 前端系统错误解析工具（services/systemErrors.ts）。
//
// 锁定 parseSystemErrorCode / getSystemErrorText 的映射：从前端 Error.message 的
// "AI_ERR:<code>" 前缀（含下划线扩展码）或 err.code 提取 SQLite/fs 码并归一化为
// diskFull / diskIo / readonly；AI 码 / 业务码 / 未知 → null。
// 纯 Node（Node 22.18+/25 原生 strip-types 直接 import .ts）：不起 Electron、不碰
// better-sqlite3、不碰浏览器 → 任何 ABI 下都真跑。只验解析逻辑，不改任何运行时行为。

import { parseSystemErrorCode, getSystemErrorText } from '../services/systemErrors.ts';

const failures = [];
let total = 0;
const eq = (input, expected, label) => {
  total++;
  const got = parseSystemErrorCode(input);
  if (got !== expected) failures.push(`parse ${label}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(got)}`);
};
const identityT = (key) => key; // 假 t：直接回显 key，便于断言 getSystemErrorText 返回的 i18n key
const te = (input, expected, label) => {
  total++;
  const got = getSystemErrorText(input, identityT);
  if (got !== expected) failures.push(`text ${label}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(got)}`);
};

// ── message 形态（CRUD 经 api:request 主路径）──
eq({ message: 'AI_ERR:SQLITE_FULL · HTTP 0 (database or disk is full)' }, 'diskFull', 'AI_ERR:SQLITE_FULL');
eq({ message: 'AI_ERR:SQLITE_IOERR (disk I/O error)' }, 'diskIo', 'AI_ERR:SQLITE_IOERR');
eq({ message: 'AI_ERR:SQLITE_IOERR_WRITE (disk I/O error on write)' }, 'diskIo', 'AI_ERR:SQLITE_IOERR_WRITE (extended, not truncated)');
eq({ message: 'AI_ERR:SQLITE_READONLY (attempt to write a readonly database)' }, 'readonly', 'AI_ERR:SQLITE_READONLY');
eq({ message: 'AI_ERR:SQLITE_READONLY_RECOVERY (...)' }, 'readonly', 'AI_ERR:SQLITE_READONLY_RECOVERY (extended)');
eq({ message: 'AI_ERR:ENOSPC (no space left on device)' }, 'diskFull', 'AI_ERR:ENOSPC');
eq({ message: 'AI_ERR:EROFS (read-only file system)' }, 'readonly', 'AI_ERR:EROFS');
eq({ message: 'AI_ERR:EIO (input/output error)' }, 'diskIo', 'AI_ERR:EIO');

// ── err.code 形态（含 PR-1 输出码 DISK_*）──
eq({ code: 'SQLITE_FULL' }, 'diskFull', 'err.code=SQLITE_FULL');
eq({ code: 'DISK_FULL' }, 'diskFull', 'err.code=DISK_FULL (PR-1 output code)');
eq({ code: 'DISK_IO' }, 'diskIo', 'err.code=DISK_IO');
eq({ code: 'EACCES' }, 'readonly', 'err.code=EACCES');
eq({ code: 'EDQUOT' }, 'diskFull', 'err.code=EDQUOT');

// ── 不分类 → null（走原有通用提示）──
eq(new Error('boom'), null, 'plain Error (no code/AI_ERR)');
eq({ message: 'AI_ERR:auth · HTTP 401 (invalid api key)' }, null, 'AI_ERR:auth (lowercase → not matched)');
eq({ message: 'AI_ERR:timeout (request timeout)' }, null, 'AI_ERR:timeout');
eq({ message: 'AI_ERR:unknown (request failed)' }, null, 'AI_ERR:unknown');
eq({ message: 'AI_ERR:SQLITE_BUSY (database is locked)' }, null, 'AI_ERR:SQLITE_BUSY (retryable, not classified)');
eq({ message: 'AI_ERR:SQLITE_CONSTRAINT (...)' }, null, 'AI_ERR:SQLITE_CONSTRAINT (business)');
eq({ message: 'some random failure with no tag' }, null, 'message without AI_ERR tag');
eq('AI_ERR:SQLITE_FULL (...)', 'diskFull', 'bare string with AI_ERR tag → classified (mirrors aiErrors string handling)');
eq('just a plain error string', null, 'bare string without AI_ERR tag → null');
eq({}, null, 'empty object');
eq(null, null, 'null');
eq(undefined, null, 'undefined');

// ── getSystemErrorText：命中→i18n key，未命中→null ──
te({ message: 'AI_ERR:SQLITE_FULL (...)' }, 'systemError.diskFull', 'text SQLITE_FULL → systemError.diskFull');
te({ message: 'AI_ERR:SQLITE_IOERR (...)' }, 'systemError.diskIo', 'text SQLITE_IOERR → systemError.diskIo');
te({ message: 'AI_ERR:SQLITE_READONLY (...)' }, 'systemError.readonly', 'text SQLITE_READONLY → systemError.readonly');
te({ code: 'DISK_FULL' }, 'systemError.diskFull', 'text err.code=DISK_FULL → systemError.diskFull');
te(new Error('x'), null, 'text plain Error → null');
te(null, null, 'text null → null');

if (failures.length) {
  console.error(`✗ system-errors: ${failures.length}/${total} case(s) failed`);
  for (const f of failures) console.error('  -', f);
  process.exit(1);
}
console.log(`✓ system-errors: all ${total} cases passed (parse AI_ERR:<code> + err.code → diskFull/diskIo/readonly; SQLITE_IOERR_*/READONLY_* full-code match; AI codes/BUSY/CONSTRAINT/unknown/null → null; getSystemErrorText → systemError.* | null)`);
