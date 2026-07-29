// 税率类设置项的「值可用吗」判定 —— A-4 的写侧封口(A4-1)。
//
// 背景(实测,见 A-4 只读核验):settings 的写入口不校验值的形状,而报表引擎读的是
// `Number(JSON.parse(value))`。于是「行存在但值不是一个可用的数字」会分成三条命运,
// 没有一条会报错:
//
//   存储原文                     JSON.parse   Number()   结果
//   ─────────────────────────────────────────────────────────────────────────
//   25 / 25.5 / 0 / -5 / 1e3     ok           有限        正常
//   "25" / " 25 " / [25]         ok           有限        静默当成 25
//   "" / " " / null / false / [] ok           0          静默当成 0%
//   true                         ok           1          静默当成 1%
//   "25%" / [1,2] / {} / {…}     ok           NaN        NaN 路径
//   abc / 25%(裸文本) / Infinity  **抛异常**    —          **静默回退到兜底 25 / 12**
//
// 最后一行最危险:`readSetting` 的 catch 吞掉解析异常返回兜底 25,而
// `settingRowExists` 已经答了 true,所以方案 A(PR #419)的闸门照常放行 —— 一个美国
// 账本会重新按中国 25% 报出所得税。实测 `estimatedTax.annualIncomeTax = 1100`,与
// #419 修掉的那个数一模一样。
//
// 这个模块是**唯一的判定处**,写侧(settings.js)与只读盘点(scripts/audit-rate-settings.mjs)
// 共用,免得两个地方各写一份然后慢慢分叉。原生侧的 A4-2 会镜像同一条规则。

/// 受本判定约束的键 —— 只有这四个。
///
/// 刻意不包含 `accounting_locale` / `currency` 之类:它们本来就是 JSON 字符串
/// (`"CN"` / `"CNY"`),用数字判定去衡量它们只会把正常数据判成损坏。
const RATE_KEYS = new Set([
  'vat_rate',
  'surcharge_rate',
  'income_tax_rate',
  'admin_expense_annual',
]);

/// 一个值(**已经是 JS 值**,不是存储原文)能不能当税率用。
///
/// 规则只有两条,刻意窄:
///   1. 有限的 number;
///   2. trim 后非空、且 `Number()` 有限的 string。
///
/// **第 2 条必须保留。** `components/SettingsPage.tsx` 的 `<select>` 至今把
/// `vat_rate` 存成 JSON 字符串 `"13"`,`services/api.ts` 的类型声明写的也是
/// `vat_rate?: string`,原生 `SettingsStore.decodeNumber` 两种编码都收。拒绝字符串
/// 会打断一条已经发货的路径。
///
/// 因此被拒的是:`""`、`" "`、`null`、`true`、`false`、数组、对象、`"25%"`、`NaN`、
/// `Infinity`,以及任何非 JSON 文本(它在存储层根本 parse 不出来,见 classifyStoredRate)。
///
/// 两个边角照单收下,写在这里而不是留给读者去发现:`"0x19"` → 25、`"1e3"` → 1000。
/// 它们确实是 JS 语义下的数字字符串,本轮只判断存储格式,不发明「税率长什么样」的
/// 政策 —— 那是另一个决定。负数同理:`-5` 是合法的 configured。
function rateValueIsUsable(value) {
  if (typeof value === 'number') return Number.isFinite(value);
  if (typeof value === 'string') {
    const trimmed = value.trim();
    return trimmed !== '' && Number.isFinite(Number(trimmed));
  }
  return false;
}

/// 存储原文(SQLite 里 `settings.value` 的那串 TEXT)的分类。
///
/// 比 `rateValueIsUsable` 多一层:先 `JSON.parse`,因为「根本不是合法 JSON」是一条
/// **独立的**、后果最严重的坏路径,而它在 parse 之后就再也看不见了。
///
/// 返回 `{ usable, verdict, effect, value }`:
///   • `verdict` 是稳定标识符,给测试和盘点脚本用;
///   • `effect` 说的是**修正前**的引擎拿这个值会干什么 —— 盘点报告要给人看,
///     「不可用」远不如「它会让你的报表按 25% 算税」有说服力。A4-3 之后引擎
///     已经拒算了,这一列因此是「如果没有那道闸会怎样」的说明。
///   • `value` 是可用时的数值(`Number()` 之后),不可用时为 `null`。它在这里而不是
///     让调用方自己再 parse 一次,是为了让**判定与取值出自同一次解析** —— 两处各
///     parse 一次,就是两套会慢慢分叉的解析器的开始。
function classifyStoredRate(rawText) {
  let parsed;
  try {
    parsed = JSON.parse(rawText);
  } catch {
    // 修正前:readSetting 的 catch 吞掉它 → 返回兜底 → 引擎按 25 / 12 计算。
    return { usable: false, verdict: 'invalidJson', value: null,
             effect: '(A4-3 之前)静默回退到兜底税率(所得税 25 / 附加税 12),报表照常出数' };
  }
  if (typeof parsed === 'number') {
    return Number.isFinite(parsed)
      ? { usable: true, verdict: 'number', value: parsed, effect: '正常' }
      : { usable: false, verdict: 'nonFiniteNumber', value: null, effect: 'NaN / Infinity 路径' };
  }
  if (typeof parsed === 'string') {
    const trimmed = parsed.trim();
    return (trimmed !== '' && Number.isFinite(Number(trimmed)))
      ? { usable: true, verdict: 'numericString', value: Number(trimmed),
          effect: '正常(数字字符串,跨端兼容形状)' }
      : { usable: false, verdict: 'textNotNumeric', value: null,
          effect: '(A4-3 之前)NaN 路径:中国序列化成 null,其余四地区被 `|| 0` 压成 0' };
  }
  return { usable: false, verdict: 'nonScalar', value: null,
           effect: '(A4-3 之前)null/布尔/数组/对象被静默强制成一个数字(0 或 1)' };
}

module.exports = { RATE_KEYS, rateValueIsUsable, classifyStoredRate };
