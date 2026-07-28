#!/usr/bin/env node
// 「行在、值不可用 → 拒算」的守护测试 —— A4-3。
//
// 被守护的行为:报表引擎读到一个**存在但不可用**的税率行时,不计算、产出 null ——
// 既不压成 0,也不回退到中国兜底 25 / 12。
//
// 这个文件里的每一条都对应一种**具体的回归**,而不是一个笼统的「还能跑」:
//
//   §1  非法 JSON 再次回退 25 / 12   —— 最危险的一族,方案 A 的洞
//   §2  "25%" 被压成 0              —— 四个非中国引擎 `|| 0` 守卫的老路径
//   §3  needsRepair 被当成 notConfigured —— 两个状态在引擎侧同为拒算,但判定入口不得合并
//   §4  中国缺行兜底被破坏           —— A-2,本次绝不能波及
//   §5  显式 0% / 数字字符串兼容被破坏 —— 拒算不得误伤正常输入
//
// 判定逻辑不在这里,在 electron/handlers/_rateValue.js(A4-1 建立、A4-3 复用的唯一
// 判定处)。这个文件测的是**报表引擎的出数**,即那条规则接上引擎之后的实际后果。
//
// better-sqlite3 的原生绑定按 Electron ABI 编时在普通 node 下加载不了,那时优雅 SKIP
// (CI 会把它重建成 node ABI 后真跑),与 test-migrations.mjs 的惯例一致。

import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { existsSync, copyFileSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';

const require = createRequire(import.meta.url);
const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');

const failures = [];
const ok = (cond, msg) => { if (!cond) failures.push(msg); };
const json = (v) => JSON.stringify(v);

let Database;
try {
  Database = require('better-sqlite3');
  new Database(':memory:').close();
} catch (e) {
  console.log('\n⚠ test-malformed-rate-refusal SKIPPED: better-sqlite3 在当前 node 下加载不了。');
  console.log('  CI 会把它重建成 node ABI 后真跑。原因:', e?.message?.split('\n')[0] || e);
  process.exit(0);
}

const FIXTURE = join(ROOT, 'native/SoloLedger/Tests/SoloLedgerCoreTests/Fixtures/reports/reports-base.db');
if (!existsSync(FIXTURE)) {
  console.error(`missing fixture ${FIXTURE}`);
  process.exit(2);
}
const engine = require(join(ROOT, 'electron/reports/index.js'));

const tmp = mkdtempSync(join(tmpdir(), 'a43-'));
const PERIOD = { year: '2025', from: '2025-01-01', to: '2025-12-31' };
const LOCALES = ['CN', 'US', 'JP', 'EU', 'KR', 'TW'];
const NON_CN = ['US', 'JP', 'EU', 'KR', 'TW'];
let seq = 0;

// 一个账本 + 一次报表。rates 里的值是**存储原文**(不是 JS 值),null 表示删除该行。
function report(locale, rates) {
  const p = join(tmp, `l${seq++}.db`);
  copyFileSync(FIXTURE, p);
  const db = new Database(p);
  const put = db.prepare(`INSERT INTO settings (key, value, updated_at) VALUES (?, ?, datetime('now'))
    ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=datetime('now')`);
  for (const [key, raw] of Object.entries(rates)) {
    if (raw === null) db.prepare('DELETE FROM settings WHERE key = ?').run(key);
    else put.run(key, raw);
  }
  // JSON 往返 = 消费方(与黄金)真正看到的形状:NaN 在这一步才变成 null。
  const out = JSON.parse(JSON.stringify(engine.generate(db, { locale, ...PERIOD })));
  db.close();
  rmSync(p, { force: true });
  return out;
}

// 各制度「所得税」那一项在输出里的取值。美国的形状不同(没有损益块)。
const pricedIncomeTax = (rep, locale) => locale === 'US'
  ? rep.estimatedTax.annualIncomeTax
  : (rep.incomeStatement || rep.profitLoss).incomeTax;

const BAD_JSON_TEXT = ['abc', '25%', '', 'Infinity', 'NaN', '{oops'];
const BAD_JSON_VALUES = ['"25%"', '""', '"   "', 'null', 'true', 'false', '[]', '[25]', '{}', '{"v":25}'];

// ═══ §1 非法 JSON 绝不回退到 25 / 12 ═══
//
// 修正前:JSON.parse 抛 → readSetting 的 catch 返回兜底 → settingRowExists 已答 true
// → 方案 A 的闸门放行 → 美国账本 annualIncomeTax = 1100(实测),正是 #419 修掉的
// 那个数换了一扇门进来。这一节是本文件存在的首要理由。
for (const raw of BAD_JSON_TEXT) {
  for (const locale of LOCALES) {
    const rep = report(locale, { income_tax_rate: raw, surcharge_rate: raw });
    const tax = pricedIncomeTax(rep, locale);
    ok(tax === null,
      `[§1] ${locale}: 存储原文 ${json(raw)} 不是合法 JSON,必须拒算(得到 ${json(tax)})`);
    if (locale === 'US') {
      ok(rep.estimatedTax.totalAnnual === null && rep.estimatedTax.quarterlyPayment === null,
        `[§1] US: 合计与季度预缴也必须是 null,得到 ${json(rep.estimatedTax)}`);
      ok(!json(rep.warnings).includes('quarterly'),
        `[§1] US: 报不出的季度预缴不得发提示,得到 ${json(rep.warnings)}`);
    }
    if (locale === 'CN') {
      ok(rep.incomeStatement.taxSurcharge === null,
        `[§1] CN: 附加税也必须拒算,绝不回退到 12%(得到 ${json(rep.incomeStatement.taxSurcharge)})`);
    }
  }
}
// 阳性对照:同一个位置,合法值必须照常出数 —— 否则上面全是空断言。
{
  const us = report('US', { income_tax_rate: '20' });
  ok(us.estimatedTax.annualIncomeTax === 880,
    `[§1 对照] US 存 20 时必须照常算出 880,得到 ${json(us.estimatedTax.annualIncomeTax)}`);
}

// ═══ §2 "25%" 不得被压成 0 ═══
//
// 四个非中国引擎的 r 是 `Math.round((v || 0) * 100) / 100`,NaN 是 falsy,所以修正前
// 一个损坏的税率会变成一个笃定的 0 —— 与「用户主动配了 0%」完全不可分。
for (const raw of BAD_JSON_VALUES) {
  for (const locale of LOCALES) {
    const rep = report(locale, { income_tax_rate: raw, surcharge_rate: raw });
    const tax = pricedIncomeTax(rep, locale);
    ok(tax !== 0, `[§2] ${locale}: 存储 ${json(raw)} 不得被压成 0`);
    ok(tax === null, `[§2] ${locale}: 存储 ${json(raw)} 必须是 null,得到 ${json(tax)}`);
  }
}
// 而且损坏与显式 0% 的**整份输出**必须不同 —— 这是 §2 的本体:
// 修正前 malformed-US-2025 与 zero-US-2025 逐字节相同,连 warning 都一样。
for (const locale of LOCALES) {
  const broken = report(locale, { income_tax_rate: '"25%"', surcharge_rate: '"12%"', admin_expense_annual: '0' });
  const zero = report(locale, { income_tax_rate: '0', surcharge_rate: '0', admin_expense_annual: '0' });
  ok(json(broken) !== json(zero),
    `[§2] ${locale}: 损坏的税率与显式 0% 的输出必须不同 —— 相同就意味着无法区分`);
}

// ═══ §3 needsRepair 与 notConfigured 在判定入口不得合并 ═══
//
// 引擎侧两者都拒算(所以报表 JSON 里都是 null,这是有意的);但**判定**必须能分开,
// 否则 R8 无法分别呈现「去配置」与「修复损坏值」。这里断言那条唯一判定的输出。
{
  const { classifyStoredRate } = require(join(ROOT, 'electron/handlers/_rateValue.js'));
  for (const raw of [...BAD_JSON_TEXT, ...BAD_JSON_VALUES]) {
    const c = classifyStoredRate(raw);
    ok(c.usable === false, `[§3] ${json(raw)} 必须判为不可用`);
    ok(c.value === null, `[§3] ${json(raw)} 不可用时不得带出一个数值`);
    ok(typeof c.verdict === 'string' && c.verdict !== '',
      `[§3] ${json(raw)} 必须给出一个可分辨的 verdict,而不是一个笼统的布尔`);
  }
  // 「行不存在」根本进不了这个函数 —— 它是另一个问题(行在不在),由调度器先问。
  // 这条断言防的是有人把两者合并成一个「取不到值就算了」的判定。
  const nonCN = report('US', { income_tax_rate: null });
  const repair = report('US', { income_tax_rate: '"25%"' });
  ok(nonCN.estimatedTax.annualIncomeTax === null && repair.estimatedTax.annualIncomeTax === null,
    '[§3] 引擎侧两者同为拒算(报表里都是 null)');
  ok(classifyStoredRate('"25%"').verdict === 'textNotNumeric',
    '[§3] 而判定侧「需修复」有自己的名字,可被 R8 区分');
}

// ═══ §4 中国缺行兜底不得被破坏(A-2)═══
{
  const absent = report('CN', { income_tax_rate: null, surcharge_rate: null, admin_expense_annual: null });
  const is = absent.incomeStatement;
  ok(is.incomeTax === 1042.95,
    `[§4] CN 缺行仍按 25% 兜底算所得税,期望 1042.95,得到 ${json(is.incomeTax)}`);
  ok(is.taxSurcharge === 24.45,
    `[§4] CN 缺行仍按 12% 兜底算附加税,期望 24.45,得到 ${json(is.taxSurcharge)}`);
  ok(is.netProfit !== null && is.netMargin !== null,
    '[§4] CN 缺行必须照常算出净利与净利率');
  // 非中国的同一状态必须相反 —— 否则「中国兜底」这条就成了「大家都兜底」。
  for (const locale of NON_CN) {
    const rep = report(locale, { income_tax_rate: null, surcharge_rate: null, admin_expense_annual: null });
    ok(pricedIncomeTax(rep, locale) === null, `[§4] ${locale} 缺行必须拒算,不得跟着中国兜底`);
  }
}

// ═══ §5 正常输入不得被误伤 ═══
{
  // 显式 0% 是一个真实答案。
  for (const locale of LOCALES) {
    const rep = report(locale, { income_tax_rate: '0', surcharge_rate: '0', admin_expense_annual: '0' });
    ok(pricedIncomeTax(rep, locale) === 0,
      `[§5] ${locale}: 显式 0% 必须算出真实的 0,得到 ${json(pricedIncomeTax(rep, locale))}`);
  }
  // 数字字符串是已发货路径的兼容形状(SettingsPage 的 <select> 就这么存 vat_rate)。
  for (const raw of ['"20"', '" 20 "']) {
    const rep = report('US', { income_tax_rate: raw });
    ok(rep.estimatedTax.annualIncomeTax === 880,
      `[§5] US: 数字字符串 ${json(raw)} 必须与数字 20 等价(880),得到 ${json(rep.estimatedTax.annualIncomeTax)}`);
  }
  // 而普通数字的结果一个字节都不能变 —— 本次改的是判定入口,不是任何公式。
  for (const locale of LOCALES) {
    const rep = report(locale, {});                       // fixture 原样:20 / 10
    const tax = pricedIncomeTax(rep, locale);
    ok(typeof tax === 'number' && Number.isFinite(tax),
      `[§5] ${locale}: 基线账本必须照常出数,得到 ${json(tax)}`);
  }
  const cnBase = report('CN', {});
  ok(cnBase.incomeStatement.taxSurcharge === 20.38,
    `[§5] CN 基线附加税仍是 20.38(公式与舍入顺序未变),得到 ${json(cnBase.incomeStatement.taxSurcharge)}`);
}

rmSync(tmp, { recursive: true, force: true });

console.log('\n=== 不可用税率的拒算(A4-3)===\n');
console.log('非法 JSON 不回退 · "25%" 不压成 0 · 需修复可分辨 · 中国兜底不变 · 正常输入不受伤');
console.log(`Failures: ${failures.length}\n`);
if (failures.length) {
  for (const f of failures) console.error('  ✗ ' + f);
  console.error('');
  process.exit(1);
}
console.log('✓ 行在、值不可用 → 不计算、产出 null;缺行与正常输入的行为一个字节没动。\n');
