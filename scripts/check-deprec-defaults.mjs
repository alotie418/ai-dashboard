// 守卫：PR-7B P2-1 折旧默认常量（components/depreciationDefaults.ts）。
//
// 纯 Node（strip-types 直接 import .ts）：不起 Electron、不碰 better-sqlite3、不碰浏览器 →
// 任何 ABI 下都真跑。只校验「类别默认」静态完整性 + 「绝无折旧计算」红线，不验证运行时行为。
import { DEPRECIATION_DEFAULTS } from '../components/depreciationDefaults.ts';

const failures = [];
const ok = (cond, msg) => { if (!cond) failures.push(msg); };

const EXPECTED = ['building', 'machinery', 'vehicle', 'electronics', 'furniture', 'DEFAULT_FALLBACK'];
// 禁止出现的「折旧计算 / 金额」键（残值率/年限是默认参数，不是计算输出）。
const FORBIDDEN_KEYS = ['accumulated', 'netvalue', 'netbookvalue', 'depreciation', 'monthly', 'compute', 'amount', 'total', 'difference'];

// ── 1. 5 类别 + DEFAULT_FALLBACK 齐全、无多余 ──
for (const k of EXPECTED) ok(k in DEPRECIATION_DEFAULTS, `[1] missing category '${k}'`);
ok(Object.keys(DEPRECIATION_DEFAULTS).length === EXPECTED.length,
  `[1] unexpected category set: ${Object.keys(DEPRECIATION_DEFAULTS).join(',')}`);

// ── 2. 每类别 usefulLifeYears>0 + salvageRate∈[0,1) + 仅这两个字段 ──
for (const [k, v] of Object.entries(DEPRECIATION_DEFAULTS)) {
  ok(typeof v.usefulLifeYears === 'number' && v.usefulLifeYears > 0, `[2] ${k}.usefulLifeYears must be a positive number`);
  ok(typeof v.salvageRate === 'number' && v.salvageRate >= 0 && v.salvageRate < 1, `[2] ${k}.salvageRate must be in [0,1)`);
  ok(Object.keys(v).every((kk) => kk === 'usefulLifeYears' || kk === 'salvageRate'), `[2] ${k} has unexpected field(s): ${Object.keys(v).join(',')}`);
}

// ── 3. 红线：无折旧计算函数 / 无计算键 ──
function walk(obj, path) {
  for (const [k, v] of Object.entries(obj)) {
    ok(!FORBIDDEN_KEYS.includes(k.toLowerCase()), `[3] forbidden compute/amount key '${path}.${k}'`);
    ok(typeof v !== 'function', `[3] function at '${path}.${k}' (P2-1 无折旧计算)`);
    if (v && typeof v === 'object') walk(v, `${path}.${k}`);
  }
}
walk(DEPRECIATION_DEFAULTS, 'DEPRECIATION_DEFAULTS');

if (failures.length) {
  console.error(`✗ deprec-defaults: ${failures.length} assertion(s) failed:`);
  for (const f of failures) console.error('  - ' + f);
  process.exit(1);
}
console.log(`✓ deprec-defaults: ${EXPECTED.length} category defaults (usefulLifeYears + salvageRate, salvage 0.05) · NO depreciation compute / accumulated / net-value / function`);
