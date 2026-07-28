// 税率设置项在**表单一侧**的严格解析与提交规则 —— A4-1。
//
// 这个模块存在的理由是一个被实测抓到的漏洞:光有「提交前用 Number.isFinite 过滤」
// 是不够的,因为**载入时的 `Number(...)` 已经把损坏值变成了一个有限数**:
//
//   存储 'null'  → handler get() 交出 null  → Number(null)  === 0   → 提交 0
//   存储 '""'    →                    ""    → Number("")    === 0   → 提交 0
//   存储 'true'  →                    true  → Number(true)  === 1   → 提交 1
//   存储 '[]'    →                    []    → Number([])    === 0   → 提交 0
//   存储 '[25]'  →                    [25]  → Number([25])  === 25  → 提交 25
//
// 于是「只改币种再保存」依然会把损坏的字节改写成 0 / 1 / 25 —— 正是 A4-1 要消灭的
// 那次静默迁移,只是换了一个更隐蔽的入口。真正的修法是**在载入那一步就不许 Number()
// 直接下手**:损坏的值根本不进入表单状态,于是也不可能被提交回去。
//
// 判定规则与服务端 `electron/handlers/_rateValue.js` 的 `rateValueIsUsable` 是同一条,
// 逐形状对照由 `scripts/test-rate-write-gate.mjs` 钉死。两份实现而不是一份,是因为
// 那个文件是 CommonJS 的主进程代码,渲染进程不能引它(会破坏打包与 offline/CSP 闸)。
// 既然必须有两份,就必须有一个测试证明它们说同一件事,而不是靠"我记得改了两处"。

/// 一个税率字段在表单里的值。
///
/// `''` 表示**这个字段现在没有可用的数字** —— 存储值损坏,或者用户把输入框清空了。
/// 刻意不用 `NaN`:它能通过 `typeof === 'number'`,能被塞进受控 input 而 React 会
/// 悄悄渲染成空字符串,还能在任何一次 `isFinite` 漏判里变成一个数。`''` 做不到这些,
/// 它在类型层面就不是数字。
export type RateFieldValue = number | '';

/// 把 `GET /api/settings` 交出来的原始值解析成表单值。
///
/// 可用的只有两种形状,与服务端封口逐字一致:
///   1. 有限的 `number`;
///   2. trim 后非空、且 `Number()` 有限的 `string`。
///
/// 第 2 条是已发货路径的兼容点(`SettingsPage` 的 `<select>` 把 `vat_rate` 存成 JSON
/// 字符串 `"13"`),不是宽容。
///
/// 其余一律 `''`:`null`、布尔、数组、对象、空字符串、`"25%"`、`NaN`、`Infinity`,
/// 以及非法 JSON 文本(handler 的 `get()` 在 `JSON.parse` 抛错时会把**原始文本**
/// 原样交出来,所以这里也会收到 `'abc'` 这种字符串,它同样 trim 后 `Number` 不出数)。
export function parseRateSetting(raw: unknown): RateFieldValue {
  if (typeof raw === 'number') return Number.isFinite(raw) ? raw : '';
  if (typeof raw === 'string') {
    const trimmed = raw.trim();
    if (trimmed === '') return '';
    const n = Number(trimmed);
    return Number.isFinite(n) ? n : '';
  }
  return '';
}

export interface RateFields {
  vatRate: RateFieldValue;
  surchargeRate: RateFieldValue;
  incomeTaxRate: RateFieldValue;
}

/// 三个税率字段的载入结果。
///
/// 与组件分开是为了**能被端到端地测**:守卫把真的存储字节喂给真的
/// `settings.get()`,再喂给这个函数,再喂给 `rateSettingsPayload`,最后喂给真的
/// `settings.save()`,然后去看那三行的原始字节。任何一环偷偷把损坏值变成数字,
/// 那条链就会在最后一步露出来。
///
/// - Parameter vatRateOptions: 当前制度的增值税率选项,用于既有的越界保护。
/// - Parameter vatRateDefault: 越界时回落的制度默认值。
///
/// 越界保护**只作用于已经可用的值**:一个损坏的 `vat_rate` 回落到制度默认值就等于
/// 用默认值覆盖了用户的损坏字节,那还是一次静默修复。损坏就是 `''`,不回落。
///
/// 键**缺失**(`undefined`)与损坏是两回事,这里也不合并:缺失时字段保持调用方给的
/// 初始值(制度预设),那是今天的行为,而「未配置」的空态呈现按拍板归原生 R8。
export function rateFieldsFromSettings(
  settings: Record<string, unknown>,
  current: RateFields,
  vatRateOptions: number[],
  vatRateDefault: number,
): RateFields {
  const next: RateFields = { ...current };

  if (settings.vat_rate !== undefined) {
    const v = parseRateSetting(settings.vat_rate);
    // Default-value protection: a persisted rate outside the current regime's
    // option range (e.g. CN's 13% lingering after switching to US, whose options
    // top out at 10) falls back to the regime default instead of leaking across.
    next.vatRate = v === ''
      ? ''
      : (v < Math.min(...vatRateOptions) || v > Math.max(...vatRateOptions) ? vatRateDefault : v);
  }
  if (settings.surcharge_rate !== undefined) next.surchargeRate = parseRateSetting(settings.surcharge_rate);
  if (settings.income_tax_rate !== undefined) next.incomeTaxRate = parseRateSetting(settings.income_tax_rate);

  return next;
}

/// 一次保存里**允许发出去**的税率键。
///
/// 只有握着可用数字的字段才出现;`''` 的字段整个键不出现,于是那一行的原始字节留在
/// 库里等用户自己替换 —— 修复入口按拍板归原生 R8,这里只负责不再破坏。
///
/// 判定是 `typeof === 'number'` 再加 `isFinite`,两个都要:前者挡住 `''`,后者是与
/// 服务端封口同一条规则的最后一道对齐。
export function rateSettingsPayload(values: RateFields): Record<string, number> {
  const payload: Record<string, number> = {};
  const put = (key: string, v: RateFieldValue) => {
    if (typeof v === 'number' && Number.isFinite(v)) payload[key] = v;
  };
  put('vat_rate', values.vatRate);
  put('surcharge_rate', values.surchargeRate);
  put('income_tax_rate', values.incomeTaxRate);
  return payload;
}
