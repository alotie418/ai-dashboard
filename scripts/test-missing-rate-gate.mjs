#!/usr/bin/env node
// Missing-income-tax-rate gate —— 方案 A(失败即拒)的守护测试。
// 规则与论证见 docs/SWIFTUI_REPORTS_MIRROR_PLAN.md §9.1 / §6.2。
//
// 被守护的行为:非中国制度下,settings 里没有 income_tax_rate 这一行时,报表引擎
// **不计算、不显示 0**,而是产出 null,交给 UI 渲染「未配置」。修正前它会静默套用
// 中国兜底 25%,于是一个美国账本按 25% 报出所得税 —— 一个完全正常、完全错误的数字。
//
// 本文件锁死四件事:
//
//   A-3(硬约束,也是最重要的一条):判定基于**设置行的缺失**,绝不基于算出的值。
//     测试本体是 §4「缺行」与「行在、值为 25」的对照:两者的算出值在修正前逐字节
//     相同,所以任何靠值反推的实现都必然在这一条上失败。
//
//   A-1:五个非中国引擎在缺行时把所得税、净利、净利率三项(美国是 estimatedTax 的
//     所得税三项 + 依赖它的 warning)产出 null;税率之上的各行(营业利润、毛利、
//     管理费用、自雇税、Schedule C)一个数都不变。
//
//   A-2:中国制度保留兜底(12% 附加税 / 25% 所得税),缺行时输出与「行在、值为 25」
//     完全一致 —— 本次修正对中国账本零影响。
//
//   A-4(已于本仓 A4-3 落地):行存在但值不可用(如 "25%",或根本不是合法 JSON 的
//     裸文本)是第三个状态「需修复」,同样拒算。它与「未配置」在**引擎侧处置相同**
//     (都产出 null),区别在呈现层。本文件下面那条对照因此断言的是「两者同为 null,
//     但都不是 0、也不是兜底」——专项守卫在 scripts/test-malformed-rate-refusal.mjs。
//
// 第 1 部分是纯函数(无 DB,恒执行);第 2 部分驱动调度器打真库 —— better-sqlite3 的
// 原生绑定按 Electron ABI 编时在普通 node 下加载不了,那时优雅 SKIP(CI 会把它重建
// 成 node ABI 后真跑),与 test-migrations.mjs 的惯例一致。

import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const require = createRequire(import.meta.url);
const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const load = (p) => require(join(ROOT, p));

const failures = [];
const ok = (cond, msg) => { if (!cond) failures.push(msg); };
const isNull = (v) => v === null;
const json = (v) => JSON.stringify(v);
// 引擎输出经 JSON 往返后才是它真正交给消费方(以及黄金文件)的形状:NaN 在这一步
// 变成 null。比较必须在这个形状上做,否则 NaN !== NaN 会让对照恒成立。
const wire = (v) => JSON.parse(JSON.stringify(v));

// 五个非中国引擎 + 它们各自的损益块键名(欧盟叫 profitLoss,不得「顺手统一」)。
const NON_CN_VAT = [
  { locale: 'JP', file: 'electron/reports/jp.js', key: 'incomeStatement' },
  { locale: 'EU', file: 'electron/reports/eu.js', key: 'profitLoss' },
  { locale: 'KR', file: 'electron/reports/kr.js', key: 'incomeStatement' },
  { locale: 'TW', file: 'electron/reports/tw.js', key: 'incomeStatement' },
];

// ═══════════════ 第 1 部分:引擎(纯函数,无 DB)═══════════════
//
// 调度器把「设置行缺失」编码为 ctx.incomeTaxRate === null。这里直接喂给引擎。

const ctx = (extra) => ({
  incomeRows: [{ amount: 1130, amount_net: 1000, tax_amount: 130, shippingCost: 0, date: '2026-03-01' }],
  expenseRows: [
    { amount: 226, amount_net: 200, tax_amount: 26, category_id: 'cogs1', date: '2026-03-02' },
    { amount: 113, amount_net: 100, tax_amount: 13, category_id: 'op1', date: '2026-03-03' },
  ],
  categories: [
    { id: 'cogs1', type: 'expense', slug: 'cogs', is_cogs: 1 },
    { id: 'op1', type: 'expense', slug: 'admin', is_cogs: 0 },
  ],
  surchargeRate: 12, adminExpense: 0, currency: 'X',
  year: '2026', from: '2026-01-01', to: '2026-12-31',
  ...extra,
});

// ---- 1.1 非中国 VAT 引擎:null 税率 → 三项 null,其余不动 ----
for (const eng of NON_CN_VAT) {
  const mod = load(eng.file);
  const missing = mod.generate(ctx({ incomeTaxRate: null }))[eng.key];
  const priced = mod.generate(ctx({ incomeTaxRate: 25 }))[eng.key];

  ok(isNull(missing.incomeTax), `${eng.locale}: 缺行 → incomeTax 必须是 null,得到 ${json(missing.incomeTax)}`);
  ok(isNull(missing.netProfit), `${eng.locale}: 缺行 → netProfit 必须是 null,得到 ${json(missing.netProfit)}`);
  ok(isNull(missing.netMargin), `${eng.locale}: 缺行 → netMargin 必须是 null,得到 ${json(missing.netMargin)}`);

  // 「不显示 0」—— null 与 0 是两回事,这一条防的是把 null 当 0 用(JS 里 null/100 === 0)。
  ok(missing.incomeTax !== 0 && missing.netProfit !== 0 && missing.netMargin !== 0,
    `${eng.locale}: 缺行的三项不得是 0(0 是「税率真的是 0%」的答案)`);

  // 税率之上的每一行都必须逐字不变。
  for (const k of ['salesRevenue', 'revenue', 'costOfSales', 'costOfGoodsSold', 'operatingExpenses',
                   'grossProfit', 'grossMargin', 'adminExpense', 'operatingProfit']) {
    if (!(k in priced)) continue;
    ok(json(missing[k]) === json(priced[k]),
      `${eng.locale}: ${k} 不读税率,必须不变 —— 有率 ${json(priced[k])} vs 缺行 ${json(missing[k])}`);
  }
  // 键集与顺序不变:这是镜像契约,缺行不得让字段消失或改名。
  ok(json(Object.keys(missing)) === json(Object.keys(priced)),
    `${eng.locale}: 缺行不得改变损益块的键集/键序`);

  // 显式 0% 是一个真实的、不同的答案。
  const zero = mod.generate(ctx({ incomeTaxRate: 0 }))[eng.key];
  ok(zero.incomeTax === 0 && typeof zero.netProfit === 'number',
    `${eng.locale}: 显式 0% → incomeTax 0 且 netProfit 是数字,得到 ${json(zero.incomeTax)}/${json(zero.netProfit)}`);
  ok(json(zero) !== json(missing), `${eng.locale}: 显式 0% 与缺行的输出必须不同`);
}

// ---- 1.2 美国:所得税三项 null + warning 撤掉;自雇税与 Schedule C 一个数不变 ----
{
  const us = load('electron/reports/us.js');
  const usCtx = (rate) => ({
    incomeRows: [{ amount: 50000, date: '2026-03-01' }],
    expenseRows: [{ amount: 8000, category_id: 'c-office', date: '2026-03-02' }],
    categories: [{ id: 'c-office', type: 'expense', slug: 'office' }],
    incomeTaxRate: rate, currency: 'USD', year: '2026', from: '2026-01-01', to: '2026-12-31',
  });
  const missing = us.generate(usCtx(null));
  const priced = us.generate(usCtx(21));

  ok(isNull(missing.estimatedTax.annualIncomeTax),
    `US: 缺行 → estimatedTax.annualIncomeTax 必须是 null,得到 ${json(missing.estimatedTax.annualIncomeTax)}`);
  ok(isNull(missing.estimatedTax.totalAnnual),
    `US: 缺行 → totalAnnual 必须是 null,得到 ${json(missing.estimatedTax.totalAnnual)}`);
  ok(isNull(missing.estimatedTax.quarterlyPayment),
    `US: 缺行 → quarterlyPayment 必须是 null,得到 ${json(missing.estimatedTax.quarterlyPayment)}`);

  // 自雇税不读所得税率 —— 整块逐字节不变,dueDates 与 annualSETax 同理。
  ok(json(missing.selfEmploymentTax) === json(priced.selfEmploymentTax),
    'US: selfEmploymentTax 不读所得税率,整块必须不变');
  ok(json(missing.scheduleC) === json(priced.scheduleC), 'US: scheduleC 必须不变');
  ok(json(missing.estimatedTax.annualSETax) === json(priced.estimatedTax.annualSETax),
    'US: annualSETax 必须不变');
  ok(json(missing.estimatedTax.dueDates) === json(priced.estimatedTax.dueDates),
    'US: dueDates 是日历日期,必须不变');
  ok(json(Object.keys(missing.estimatedTax)) === json(Object.keys(priced.estimatedTax)),
    'US: 缺行不得改变 estimatedTax 的键集/键序');

  // 报不出的数就不报 —— 而不是拼出 "$null"。
  const quarterly = (w) => w.filter((s) => /quarterly tax payment/i.test(s));
  ok(quarterly(missing.warnings).length === 0,
    `US: 缺行 → 不得发出季度预缴提示,得到 ${json(missing.warnings)}`);
  ok(!json(missing.warnings).includes('null'), 'US: warning 里不得出现 "null" 字样');
  ok(quarterly(priced.warnings).length === 1,
    `US: 有率 → 季度预缴提示照常发出(阳性对照),得到 ${json(priced.warnings)}`);

  // 显式 0% 仍是一个真实答案:所得税 0,但合计里还有自雇税,提示照发。
  const zero = us.generate(usCtx(0));
  ok(zero.estimatedTax.annualIncomeTax === 0 && typeof zero.estimatedTax.quarterlyPayment === 'number',
    `US: 显式 0% → annualIncomeTax 0 且 quarterlyPayment 是数字,得到 ${json(zero.estimatedTax)}`);
  ok(quarterly(zero.warnings).length === 1, 'US: 显式 0% 仍有自雇税要预缴,提示必须照发');
}

// ---- 1.3 只认 null,不认 undefined ----
// undefined 表示调用方根本没给这个参数(既有的 NaN 路径),与「设置行缺失」是两回事,
// 本次一个字节都不改。这条同时防止方案 A 被悄悄扩大成「凡是取不到率就 null」。
{
  const jp = load('electron/reports/jp.js').generate(ctx({}))[`incomeStatement`];
  ok(jp.incomeTax === 0, `JP: incomeTaxRate 未给(undefined)时仍走既有 NaN 路径 → 0,得到 ${json(jp.incomeTax)}`);
  const cn = wire(load('electron/reports/cn.js').generate(ctx({})).incomeStatement);
  ok(isNull(cn.incomeTax), `CN: incomeTaxRate 未给(undefined)时仍走既有 NaN 路径 → null,得到 ${json(cn.incomeTax)}`);
}

// ---- 1.4 中国引擎:方案 A 不碰它 ----
{
  const cn = load('electron/reports/cn.js');
  const a = cn.generate(ctx({ incomeTaxRate: 25 })).incomeStatement;
  ok(typeof a.incomeTax === 'number' && a.incomeTax > 0 && typeof a.netProfit === 'number',
    `CN: 25% → incomeTax/netProfit 仍是数字,得到 ${json(a.incomeTax)}/${json(a.netProfit)}`);
  ok(typeof a.taxSurcharge === 'number', 'CN: taxSurcharge 仍是数字');
}

// ═══════════════ 第 2 部分:调度器打真库 —— A-3 的测试本体 ═══════════════

let Database;
try {
  Database = require('better-sqlite3');
  // 原生绑定惰性加载:require 不触发 dlopen,首次 new Database() 才会。
  new Database(':memory:').close();
} catch (e) {
  console.log('\n⚠ 第 2 部分 SKIPPED: better-sqlite3 在当前 node 下加载不了(按 Electron ABI 编)。');
  console.log('  CI 会把它重建成 node ABI 后真跑。原因:', e?.message?.split('\n')[0] || e);
  report();
}

if (Database) {
  const { runMigrations } = load('electron/db/index.js');
  const reportEngine = load('electron/reports/index.js');

  const RATE_KEY = 'income_tax_rate';
  const PERIOD = { year: '2026', from: '2026-01-01', to: '2026-12-31' };

  // 一个自带利润的账本。每个用例都从同一个种子出发,唯一的差别是 settings 里
  // income_tax_rate 这一行的状态 —— 缺失 / =0 / =25 / ="25%"。
  const ledger = (rateState) => {
    const db = new Database(':memory:');
    runMigrations(db);
    const put = db.prepare(`INSERT INTO settings (key, value, updated_at) VALUES (?, ?, datetime('now'))
      ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=datetime('now')`);
    put.run('currency', JSON.stringify('USD'));
    put.run('surcharge_rate', JSON.stringify(12));
    put.run('admin_expense_annual', JSON.stringify(0));
    db.prepare('DELETE FROM settings WHERE key = ?').run(RATE_KEY);
    if (rateState !== 'absent') put.run(RATE_KEY, JSON.stringify(rateState));

    // 带 tax_amount:中国附加税吃的是 vatPayable(销项 − 进项),没有税额就恒为 0,
    // A-2 的「附加税兜底仍然生效」那一条会变成空断言。
    const ins = db.prepare(`INSERT INTO transactions (id, type, date, amount, amount_net, tax_amount, currency)
                            VALUES (?,?,?,?,?,?,?)`);
    ins.run('t-i1', 'income', '2026-03-01', 11300, 10000, 1300, 'USD');
    ins.run('t-e1', 'expense', '2026-03-02', 2260, 2000, 260, 'USD');
    return db;
  };

  const run = (db, locale) => wire(reportEngine.generate(db, { locale, ...PERIOD }));
  const statement = (rep) => rep.incomeStatement || rep.profitLoss;

  const rowIsAbsent = (db) => !db.prepare('SELECT 1 FROM settings WHERE key = ?').get(RATE_KEY);
  {
    // 前提自检:种子确实制造了「行缺失」与「行存在」两种状态,否则整节形同虚设。
    const a = ledger('absent'); const p = ledger(25);
    ok(rowIsAbsent(a), '前提:absent 账本里 income_tax_rate 行必须真的不存在');
    ok(!rowIsAbsent(p), '前提:25 账本里 income_tax_rate 行必须存在');
    a.close(); p.close();
  }

  for (const { locale, key } of [...NON_CN_VAT, { locale: 'US', key: null }]) {
    const dbA = ledger('absent');
    const db0 = ledger(0);
    const db25 = ledger(25);
    const bad = ledger('25%');
    const [absent, zero, priced, malformed] =
      [dbA, db0, db25, bad].map((d) => run(d, locale));
    [dbA, db0, db25, bad].forEach((d) => d.close());

    const pick = (rep) => locale === 'US'
      ? { tax: rep.estimatedTax.annualIncomeTax, net: rep.estimatedTax.totalAnnual,
          margin: rep.estimatedTax.quarterlyPayment }
      : { tax: statement(rep)[key === null ? 'incomeTax' : 'incomeTax'],
          net: statement(rep).netProfit, margin: statement(rep).netMargin };

    const a = pick(absent);
    const z = pick(zero);
    const p = pick(priced);

    // A-1:缺行 → 三项 null。
    ok(isNull(a.tax) && isNull(a.net) && isNull(a.margin),
      `[db] ${locale}: 设置行缺失 → 三项必须是 null,得到 ${json(a)}`);

    // A-3 的测试本体 ——「缺行」与「行在、值为 25」。修正前这两者的输出逐字节相同
    // (缺行套用了中国兜底 25),所以任何靠算出的值反推「未配置」的实现都必然在
    // 这一条上失败。它是这个文件里最重要的一条断言。
    ok(json(absent) !== json(priced),
      `[db] ${locale}: 「缺行」与「行在=25」的输出必须不同 —— 相同即意味着判定是靠值反推的`);
    ok(typeof p.tax === 'number' && p.tax !== null,
      `[db] ${locale}: 行在=25 → 必须照常计算,得到 ${json(p.tax)}`);

    // 显式 0% 是真实的 0,不是「未配置」。
    ok(z.tax === 0 && typeof z.net === 'number',
      `[db] ${locale}: 行在=0 → 真实的 0(不是 null),得到 ${json(z)}`);
    ok(json(zero) !== json(absent), `[db] ${locale}: 显式 0% 与缺行的输出必须不同`);

    // A-4(A4-3 落地):行在、值不可用 → 同样拒算。
    //
    // 这条断言此前写的是「仍降为 0」—— 那是 #419 当时的真实行为,也是 A4-3 要消灭的
    // 东西:一个损坏的税率被压成 0,与「用户主动配了 0%」完全不可分。改成新契约,
    // 而不是放宽。
    const m = pick(malformed);
    ok(m.tax === null,
      `[db] ${locale}: malformed("25%") 必须拒算 → null,得到 ${json(m.tax)}`);
    ok(m.tax !== 0,
      `[db] ${locale}: 尤其不得被压成 0 —— 那与显式 0% 不可分`);
    // 而「未配置」与「需修复」在报表 JSON 里都是 null,这是有意的:引擎侧处置相同,
    // 区分留在设置读取层(原生 ReportRateSetting 的四态),由 R8 分别呈现。
    ok(json(pick(absent).tax) === json(m.tax),
      `[db] ${locale}: 未配置与需修复在报表输出里同为 null(区分不在这一层)`);

    // 税率之上的部分一个数都不变。
    if (locale === 'US') {
      ok(json(absent.scheduleC) === json(priced.scheduleC), `[db] US: scheduleC 必须不变`);
      ok(json(absent.selfEmploymentTax) === json(priced.selfEmploymentTax),
        `[db] US: selfEmploymentTax 必须不变`);
    } else {
      for (const k of ['salesRevenue', 'revenue', 'grossProfit', 'operatingProfit', 'adminExpense']) {
        if (!(k in statement(priced))) continue;
        ok(json(statement(absent)[k]) === json(statement(priced)[k]),
          `[db] ${locale}: ${k} 不读税率,必须不变`);
      }
    }
  }

  // A-2:中国制度保留兜底 —— 缺行与「行在=25」输出完全一致,本次修正对中国账本零影响。
  {
    const dbA = ledger('absent');
    const db25 = ledger(25);
    const absent = run(dbA, 'CN');
    const priced = run(db25, 'CN');
    dbA.close(); db25.close();
    ok(json(absent) === json(priced),
      'CN: 保留兜底(A-2)—— 缺行的输出必须与「行在=25」完全一致,本次修正不得碰中国账本');
    ok(typeof absent.incomeStatement.incomeTax === 'number' && absent.incomeStatement.incomeTax > 0,
      `CN: 缺行仍按 25% 兜底算出所得税,得到 ${json(absent.incomeStatement.incomeTax)}`);
    ok(typeof absent.incomeStatement.taxSurcharge === 'number' && absent.incomeStatement.taxSurcharge > 0,
      `CN: 缺行仍按 12% 兜底算出附加税,得到 ${json(absent.incomeStatement.taxSurcharge)}`);
  }
}

report();

function report() {
  console.log('\n=== Missing income-tax-rate gate (方案 A) ===\n');
  console.log('缺行 → null(非中国)· 显式 0% → 真实 0 · 值不可用 → 拒算 · 中国兜底不变');
  console.log(`Failures: ${failures.length}\n`);
  if (failures.length) {
    for (const f of failures) console.error('  ✗ ' + f);
    console.error('');
    process.exit(1);
  }
  console.log('✓ 「未配置」由设置行的缺失判定,不由算出的值反推;中国兜底未被波及。\n');
  process.exit(0);
}
