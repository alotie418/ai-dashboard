// 守卫：PR-7B P1-1 分类/标签映射常量（components/accountingClassification.ts）。
//
// 纯 Node（Node 22.18+/25 原生 strip-types 直接 import .ts）：不起 Electron、不碰 better-sqlite3、
// 不碰浏览器 → 任何 ABI 下都真跑。只做「分类元数据」静态校验 + 「绝无金额/合计/计算」红线断言，
// 不验证任何运行时行为（P1-1 此刻无消费方）。
import { BALANCE_CLASSIFICATION, LABEL_SET_BY_LOCALE } from '../components/accountingClassification.ts';

const failures = [];
const ok = (cond, msg) => { if (!cond) failures.push(msg); };

const SECTIONS = new Set(['asset', 'liability', 'equity']);
const LIQUIDITY = new Set(['current', 'non_current', 'by_maturity', 'none']);
const LABEL_SETS = new Set(['ASBE', 'US_GAAP', 'JGAAP', 'IFRS']);
const EXPECTED_SOURCES = ['cash', 'receivables', 'inventory', 'fixedAssets', 'payables', 'taxPayable', 'borrowings', 'equity'];
// 禁止出现的「金额/合计/计算」键（小写匹配）。includeInTotals 是声明性 flag，豁免。
const FORBIDDEN_KEYS = ['total', 'assetstotal', 'liabilitiestotal', 'equitytotal', 'totals', 'balance', 'difference', 'depreciation', 'retainedearnings', 'amount', 'sum', 'subtotal'];
const ALLOWED_FLAG = 'includeintotals';

// ── 1. 8 个数据源齐全、无多余 ──
for (const k of EXPECTED_SOURCES) ok(k in BALANCE_CLASSIFICATION, `[1] missing source '${k}'`);
ok(Object.keys(BALANCE_CLASSIFICATION).length === EXPECTED_SOURCES.length,
  `[1] unexpected source set: ${Object.keys(BALANCE_CLASSIFICATION).join(',')}`);

// ── 2. 每个源都有合法 section / liquidity / labelKey / includeInTotals ──
for (const [k, e] of Object.entries(BALANCE_CLASSIFICATION)) {
  ok(SECTIONS.has(e.section), `[2] ${k}.section invalid: ${e.section}`);
  ok(LIQUIDITY.has(e.liquidity), `[2] ${k}.liquidity invalid: ${e.liquidity}`);
  ok(typeof e.labelKey === 'string' && e.labelKey.length > 0, `[2] ${k}.labelKey must be non-empty string`);
  ok(typeof e.includeInTotals === 'boolean', `[2] ${k}.includeInTotals must be boolean`);
}

// ── 3. 关键归类 + 拍板点 ──
ok(BALANCE_CLASSIFICATION.cash.section === 'asset' && BALANCE_CLASSIFICATION.cash.liquidity === 'current', '[3] cash = asset/current');
ok(BALANCE_CLASSIFICATION.receivables.section === 'asset' && BALANCE_CLASSIFICATION.receivables.liquidity === 'current', '[3] receivables = asset/current');
ok(BALANCE_CLASSIFICATION.inventory.section === 'asset' && BALANCE_CLASSIFICATION.inventory.liquidity === 'current', '[3] inventory = asset/current');
ok(BALANCE_CLASSIFICATION.fixedAssets.section === 'asset' && BALANCE_CLASSIFICATION.fixedAssets.liquidity === 'non_current', '[3] fixedAssets = asset/non_current');
ok(BALANCE_CLASSIFICATION.payables.section === 'liability' && BALANCE_CLASSIFICATION.payables.liquidity === 'current', '[3] payables = liability/current');
ok(BALANCE_CLASSIFICATION.equity.section === 'equity', '[3] equity = equity');
// 拍板4: taxPayable 进常量但不参与合计
ok(BALANCE_CLASSIFICATION.taxPayable.section === 'liability' && BALANCE_CLASSIFICATION.taxPayable.includeInTotals === false,
  '[3] taxPayable = liability + includeInTotals:false (拍板4)');
// 拍板1/4: borrowings 按到期日分、空到期日默认流动、带说明
ok(BALANCE_CLASSIFICATION.borrowings.section === 'liability' && BALANCE_CLASSIFICATION.borrowings.liquidity === 'by_maturity',
  '[3] borrowings = liability/by_maturity');
ok(BALANCE_CLASSIFICATION.borrowings.defaultLiquidity === 'current', '[3] borrowings.defaultLiquidity = current (空到期日按流动)');
ok(typeof BALANCE_CLASSIFICATION.borrowings.note === 'string' && BALANCE_CLASSIFICATION.borrowings.note.length > 0, '[3] borrowings has a note');
// 拍板3: 借款行标签 deferred 到 P1-4（占位）
ok(BALANCE_CLASSIFICATION.borrowings.labelKey === '(deferred:P1-4)', '[3] borrowings.labelKey deferred to P1-4 (no new i18n in P1-1)');

// ── 4. 六制度 → 四套标签集（EU/KR/TW 同归 IFRS）──
for (const loc of ['CN', 'US', 'JP', 'EU', 'KR', 'TW']) ok(loc in LABEL_SET_BY_LOCALE, `[4] missing locale '${loc}'`);
ok(LABEL_SET_BY_LOCALE.CN === 'ASBE', '[4] CN → ASBE');
ok(LABEL_SET_BY_LOCALE.US === 'US_GAAP', '[4] US → US_GAAP');
ok(LABEL_SET_BY_LOCALE.JP === 'JGAAP', '[4] JP → JGAAP');
ok(LABEL_SET_BY_LOCALE.EU === 'IFRS' && LABEL_SET_BY_LOCALE.KR === 'IFRS' && LABEL_SET_BY_LOCALE.TW === 'IFRS', '[4] EU/KR/TW → IFRS');
for (const [loc, v] of Object.entries(LABEL_SET_BY_LOCALE)) ok(LABEL_SETS.has(v), `[4] ${loc} → invalid labelSet ${v}`);

// ── 5. 红线：绝无金额 / 合计 / 计算输出 ──
//   (a) 任何 leaf 值都不得是 number（P1-1 无金额）；
//   (b) 禁止「计算/合计」键名（includeInTotals 豁免）；
//   (c) 不导出任何函数（P1-1 无计算）。
function walk(obj, path) {
  for (const [k, v] of Object.entries(obj)) {
    const lk = k.toLowerCase();
    if (lk !== ALLOWED_FLAG) ok(!FORBIDDEN_KEYS.includes(lk), `[5] forbidden compute/amount key '${path}.${k}'`);
    ok(typeof v !== 'number', `[5] numeric value at '${path}.${k}' (P1-1 无金额)`);
    ok(typeof v !== 'function', `[5] function at '${path}.${k}' (P1-1 无计算)`);
    if (v && typeof v === 'object') walk(v, `${path}.${k}`);
  }
}
walk(BALANCE_CLASSIFICATION, 'BALANCE_CLASSIFICATION');
walk(LABEL_SET_BY_LOCALE, 'LABEL_SET_BY_LOCALE');

if (failures.length) {
  console.error(`✗ balance-classify: ${failures.length} assertion(s) failed:`);
  for (const f of failures) console.error('  - ' + f);
  process.exit(1);
}
console.log(`✓ balance-classify: ${EXPECTED_SOURCES.length} sources classified (section/liquidity) · 6 locales → 4 label sets (EU/KR/TW=IFRS) · taxPayable excluded from totals · borrowings by_maturity(default current) · NO amount/total/difference/compute output`);
