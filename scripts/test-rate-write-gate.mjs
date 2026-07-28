#!/usr/bin/env node
// 税率写侧封口的守护测试 —— A4-1。
//
// 被守护的行为:`PUT /api/settings` 不再接受一个不能当税率用的值。任何一个非法值
// 让**整次请求失败**,一个字节都不写 —— 不跳过、不部分保存、更不改写成 null / 0。
//
// 这个文件里最重要的一条是 §3「原始字节不变」:它证明的不是「保存失败了」,而是
// **一个已经损坏的税率行,在用户只改币种并保存之后,依然是原来那串字节**。
// 修正前那条路径是这样的(逐步实测过):
//
//   存储 '"25%"' → handler get() 交出字符串 "25%" → 表单 Number("25%") 得到 NaN
//   → 保存时四个字段一起发 → JSON.stringify(NaN) 是字面量 `null`
//   → 行变成 'null' → 再读 Number(null) === 0
//
// 也就是说,打开会计设置页、只改币种、按保存,「需修复」就被无声地改成了
// 「所得税 0%」。那是 §6.4 第 3 条明令禁止的静默迁移,而且它发生在生产代码里。
//
// 第 1 部分是纯函数(恒执行);第 2 部分打真库跑真 handler —— better-sqlite3 的原生
// 绑定按 Electron ABI 编时在普通 node 下加载不了,那时优雅 SKIP(CI 会把它重建成
// node ABI 后真跑),与 test-migrations.mjs 的惯例一致。

import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const require = createRequire(import.meta.url);
const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const load = (p) => require(join(ROOT, p));

const failures = [];
const ok = (cond, msg) => { if (!cond) failures.push(msg); };
const json = (v) => JSON.stringify(v);

const { RATE_KEYS, rateValueIsUsable, classifyStoredRate } = load('electron/handlers/_rateValue.js');

// ═══════════ 第 1 部分:判定规则(纯函数)═══════════

// ---- 1.1 可用 ----
for (const v of [25, 25.5, 0, -5, 1e3, 0.1]) {
  ok(rateValueIsUsable(v), `有限 number ${json(v)} 必须可用`);
}
// 数字字符串是**已发货路径的兼容点**,不是宽容:components/SettingsPage.tsx 的
// <select> 至今把 vat_rate 存成 JSON 字符串,services/api.ts 的类型声明也是 string。
for (const v of ['25', '13', ' 25 ', '25.5', '-5', '0']) {
  ok(rateValueIsUsable(v), `数字字符串 ${json(v)} 必须可用(跨端兼容形状)`);
}

// ---- 1.2 需修复 ----
for (const v of ['', '   ', '25%', 'abc', 'Infinity', '1,000']) {
  ok(!rateValueIsUsable(v), `${json(v)} 不是可用税率`);
}
for (const v of [null, undefined, true, false, [], [25], [1, 2], {}, { v: 25 }, NaN, Infinity, -Infinity]) {
  ok(!rateValueIsUsable(v), `${json(v) ?? String(v)} 不是可用税率`);
}

// ---- 1.3 存储原文的三类坏法必须可分辨 ----
// 分开而不是合成一个 boolean,是因为它们的**后果**完全不同,盘点报告要说得出来。
const verdictOf = (raw) => classifyStoredRate(raw).verdict;
ok(verdictOf('25') === 'number', '25 → number');
ok(verdictOf('"13"') === 'numericString', '"13" → numericString');
ok(verdictOf('"25%"') === 'textNotNumeric', '"25%" → textNotNumeric(NaN 路径)');
ok(verdictOf('""') === 'textNotNumeric', '空字符串 → textNotNumeric');
ok(verdictOf('null') === 'nonScalar', 'null → nonScalar');
ok(verdictOf('true') === 'nonScalar', 'true → nonScalar');
ok(verdictOf('[]') === 'nonScalar', '[] → nonScalar');
ok(verdictOf('{}') === 'nonScalar', '{} → nonScalar');
// 最危险的一类:根本不是 JSON。readSetting 的 catch 吞掉异常返回兜底 25,而
// settingRowExists 已经答了 true,于是方案 A 的闸门照常放行 —— 一个美国账本
// 重新按中国 25% 出数(实测 annualIncomeTax = 1100)。
ok(verdictOf('abc') === 'invalidJson', '非 JSON 文本 → invalidJson');
ok(verdictOf('25%') === 'invalidJson', '裸文本 25% → invalidJson(注意与 \'"25%"\' 是两回事)');
ok(verdictOf('') === 'invalidJson', '空文本 → invalidJson');
ok(classifyStoredRate('abc').effect.includes('25'),
  'invalidJson 的说明必须点出它会回退到 25 —— 盘点报告要给人看');

// ---- 1.4 受约束的键就是那四个 ----
for (const k of ['vat_rate', 'surcharge_rate', 'income_tax_rate', 'admin_expense_annual']) {
  ok(RATE_KEYS.has(k), `${k} 必须在税率键集合内`);
}
for (const k of ['accounting_locale', 'currency', 'company_info', 'fx_reference_rates',
                 'opening_retained_earnings', 'entity_type']) {
  ok(!RATE_KEYS.has(k), `${k} 不得被数字判定约束(它本来就不是税率)`);
}

// ---- 1.5 表单侧:决定「哪些税率键会被发出去」的那条规则 ----
// 这一条与 §2.3 是一对:§2.3 证明「载荷里没有那个键 → 字节不变」,这一条证明
// 「税率损坏时载荷里确实没有那个键」。少了任何一半,「只改币种、坏字节不变」
// 这句话就只被证明了一半。
{
  const { rateSettingsPayload } = await import(join(ROOT, 'components/rateSettingsPayload.ts'));

  const all = rateSettingsPayload({ vatRate: 13, surchargeRate: 12, incomeTaxRate: 25 });
  ok(json(all) === json({ vat_rate: 13, surcharge_rate: 12, income_tax_rate: 25 }),
    `三个都可用时三个都发,得到 ${json(all)}`);

  // 损坏的税率在表单里读成 NaN(Number("25%")),必须整个键消失 —— 不是发 null、
  // 不是发 0、不是发上一次的值。
  const damaged = rateSettingsPayload({ vatRate: 13, surchargeRate: 12, incomeTaxRate: NaN });
  ok(!('income_tax_rate' in damaged),
    `所得税率损坏时,income_tax_rate 这个键必须根本不出现,得到 ${json(damaged)}`);
  ok(json(damaged) === json({ vat_rate: 13, surcharge_rate: 12 }), '其余两个照常发');

  const allDamaged = rateSettingsPayload({ vatRate: NaN, surchargeRate: NaN, incomeTaxRate: NaN });
  ok(json(allDamaged) === '{}', `三个都损坏时载荷里一个税率键都没有,得到 ${json(allDamaged)}`);

  // 0 是一个真实税率,不得被 falsy 判断误伤。
  const zeros = rateSettingsPayload({ vatRate: 0, surchargeRate: 0, incomeTaxRate: 0 });
  ok(json(zeros) === json({ vat_rate: 0, surcharge_rate: 0, income_tax_rate: 0 }),
    `显式 0% 必须照常发出,得到 ${json(zeros)}`);

  // 表单放行的值,服务端必须也放行 —— 两侧用同一条判定,不得各说各话。
  for (const v of [0, 13, 25.5, -5, 1e3]) {
    const p = rateSettingsPayload({ vatRate: v, surchargeRate: v, incomeTaxRate: v });
    ok('vat_rate' in p && rateValueIsUsable(p.vat_rate),
      `表单放行的 ${v} 服务端也必须放行(两侧判定必须一致)`);
  }
  for (const v of [NaN, Infinity, -Infinity]) {
    const p = rateSettingsPayload({ vatRate: v, surchargeRate: v, incomeTaxRate: v });
    ok(json(p) === '{}', `${v} 表单侧就该拦下,不该走到服务端`);
  }
}

// ═══════════ 第 2 部分:真 handler + 真库 ═══════════

let Database;
try {
  Database = require('better-sqlite3');
  new Database(':memory:').close();
} catch (e) {
  console.log('\n⚠ 第 2 部分 SKIPPED: better-sqlite3 在当前 node 下加载不了(按 Electron ABI 编)。');
  console.log('  CI 会把它重建成 node ABI 后真跑。原因:', e?.message?.split('\n')[0] || e);
  report();
}

if (Database) {
  const { runMigrations } = load('electron/db/index.js');

  // handler 走 require('../db') 取库。这里把那个模块的导出换成一个指向内存库的
  // getDb,与 test-handlers.mjs 的做法一致 —— 不碰任何真实账本。
  const dbModulePath = require.resolve(join(ROOT, 'electron/db/index.js'));
  let current = null;
  const dbModule = require(dbModulePath);
  dbModule.getDb = () => current;
  const settings = load('electron/handlers/settings.js');

  const fresh = () => {
    current = new Database(':memory:');
    runMigrations(current);
    return current;
  };
  const rawOf = (key) => {
    const row = current.prepare('SELECT value FROM settings WHERE key = ?').get(key);
    return row ? row.value : undefined;
  };
  const put = (key, raw) => current.prepare(
    `INSERT INTO settings (key, value, updated_at) VALUES (?, ?, datetime('now'))
     ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=datetime('now')`).run(key, raw);
  const save = async (body) => settings.save({ body });
  const rejects = async (body) => {
    try { await save(body); return null; } catch (e) { return e; }
  };

  // ---- 2.1 合法值照常保存 ----
  {
    fresh();
    await save({ income_tax_rate: 21, surcharge_rate: 0, vat_rate: '13', admin_expense_annual: 12000 });
    ok(rawOf('income_tax_rate') === '21', `数字照常存,得到 ${rawOf('income_tax_rate')}`);
    ok(rawOf('vat_rate') === '"13"', `数字字符串照常存(已发货形状),得到 ${rawOf('vat_rate')}`);
    ok(rawOf('admin_expense_annual') === '12000', 'admin_expense_annual 照常存');
  }

  // ---- 2.2 非法值 → 整次请求失败,而且一个字节都没写 ----
  for (const bad of [NaN, null, '25%', '', true, [], {}, 'abc']) {
    fresh();
    await save({ currency: 'USD' });                       // 先放一个已知的良好状态
    const before = rawOf('currency');
    const err = await rejects({ currency: 'CNY', company_info: { name: 'x' }, income_tax_rate: bad });
    ok(err instanceof Error, `income_tax_rate=${json(bad) ?? String(bad)} 必须抛错`);
    ok(/income_tax_rate/.test(err?.message || ''), '错误信息必须点名是哪个键');
    ok(/Nothing was saved/.test(err?.message || ''), '错误信息必须说清一个字节都没写');
    // 同一次请求里的**合法**键也不得落盘 —— 这是「不部分保存」的本体。
    ok(rawOf('currency') === before,
      `currency 不得被部分保存:期望 ${before},得到 ${rawOf('currency')}`);
    ok(rawOf('company_info') === undefined, 'company_info 不得被部分保存');
    ok(rawOf('income_tax_rate') === undefined, '非法税率当然不得落盘');
  }

  // ---- 2.3 **原始字节不变**(本文件的中心)----
  // 一个已经损坏的税率行 + 一次只改币种的保存 → 那串字节必须逐字节不动。
  for (const damaged of ['"25%"', 'null', '""', 'true', '[]', 'abc', '{}']) {
    fresh();
    put('income_tax_rate', damaged);
    put('surcharge_rate', damaged);
    await save({ currency: 'JPY' });                        // 表单只发它握有可用值的键
    ok(rawOf('income_tax_rate') === damaged,
      `只改币种时,损坏的 income_tax_rate 必须逐字节不变:期望 ${damaged},得到 ${rawOf('income_tax_rate')}`);
    ok(rawOf('surcharge_rate') === damaged,
      `只改币种时,损坏的 surcharge_rate 必须逐字节不变:期望 ${damaged},得到 ${rawOf('surcharge_rate')}`);
    ok(rawOf('currency') === '"JPY"', '而币种本身要保存成功');
  }

  // ---- 2.4 修正前那条静默迁移链,现在必须被挡住 ----
  // 表单若仍然把 NaN 发过来(旧行为),handler 这一层也不能让它变成 `null`。
  {
    fresh();
    put('income_tax_rate', '"25%"');
    const err = await rejects({ currency: 'CNY', income_tax_rate: NaN });
    ok(err instanceof Error, 'NaN 必须被拒,而不是 JSON.stringify 成 null');
    ok(rawOf('income_tax_rate') === '"25%"',
      `拒绝之后原始字节仍是 '"25%"',得到 ${rawOf('income_tax_rate')}`);
    // 反证这条链的终点确实是 0%:如果当年那个 null 落了盘,读出来就是 0。
    ok(Number(JSON.parse('null')) === 0,
      '（记录:null 读回来是 0 —— 这就是被挡住的那个终点）');
  }

  // ---- 2.5 非税率键不受影响 ----
  {
    fresh();
    await save({ accounting_locale: 'US', currency: 'USD', entity_type: 'company',
                 company_info: { name: 'ACME' }, fx_reference_rates: { USD: 7.2 } });
    ok(rawOf('accounting_locale') === '"US"', 'accounting_locale 是字符串,照常保存');
    ok(rawOf('entity_type') === '"company"', 'entity_type 照常保存');
    ok(rawOf('company_info') === '{"name":"ACME"}', 'company_info 是对象,照常保存');
    ok(rawOf('fx_reference_rates') === '{"USD":7.2}', 'fx_reference_rates 是对象,照常保存');
  }

  // ---- 2.6 制度切换(applyProfile 的载荷)照常工作 ----
  // 六个预设的税率都是数字字面量,封口不得挡住任何一个。
  {
    const profiles = [
      { accounting_locale: 'CN', vat_rate: 13, surcharge_rate: 12, income_tax_rate: 25, currency: 'CNY' },
      { accounting_locale: 'US', vat_rate: 0, surcharge_rate: 0, income_tax_rate: 21, currency: 'USD' },
      { accounting_locale: 'JP', vat_rate: 10, surcharge_rate: 0, income_tax_rate: 23.2, currency: 'JPY' },
      { accounting_locale: 'EU', vat_rate: 20, surcharge_rate: 0, income_tax_rate: 25, currency: 'EUR' },
      { accounting_locale: 'KR', vat_rate: 10, surcharge_rate: 0, income_tax_rate: 22, currency: 'KRW' },
      { accounting_locale: 'TW', vat_rate: 5, surcharge_rate: 0, income_tax_rate: 20, currency: 'TWD' },
    ];
    for (const p of profiles) {
      fresh();
      const err = await rejects(p);
      ok(err === null, `${p.accounting_locale} 预设必须能保存,却抛了:${err?.message}`);
      ok(rawOf('income_tax_rate') === String(p.income_tax_rate),
        `${p.accounting_locale} 的所得税率落盘为 ${p.income_tax_rate}`);
    }
  }
}

report();

function report() {
  console.log('\n=== 税率写侧封口(A4-1)===\n');
  console.log('非法值 → 整次失败·不跳过·不部分保存·不改写成 null/0 · 数字字符串仍兼容');
  console.log(`Failures: ${failures.length}\n`);
  if (failures.length) {
    for (const f of failures) console.error('  ✗ ' + f);
    console.error('');
    process.exit(1);
  }
  console.log('✓ 损坏的税率行在无关字段保存时逐字节不变;写入口不再制造新的坏行。\n');
  process.exit(0);
}
