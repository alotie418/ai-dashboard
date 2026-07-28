// 「所得税率设置行缺失」的编码与判定 —— 方案 A(失败即拒)。
// 详见 docs/SWIFTUI_REPORTS_MIRROR_PLAN.md §9.1(四条规则)与 §6.2(为什么只能判行)。
//
// 唯一的生产者是调度器 electron/reports/index.js:非中国制度下 settings 里没有
// income_tax_rate 这一行时,它把 ctx.incomeTaxRate 置为 **null**。
//
// null 在这里是一个有意义的值 ——「我们不知道这个税率」,不是 0。引擎必须显式分支:
// JS 里 `null / 100 === 0`,漏判就会把「不知道」静默算成「0%」,那是本次要消灭的
// 那类谎的另一个版本。
//
// **只认 null,不认 undefined。** undefined 表示调用方(纯函数守护脚本、直接调
// engine.generate 的测试)根本没给这个参数,那走的是既有的 NaN 路径,与设置行缺失
// 是两回事,不在方案 A 的处置范围内,本次一个字节都不改。
//
// malformed(行存在但值不可解析,如 "25%")同样不走这里:它是第三个可区分的状态
// 「需修复」(A-4),留给单独 PR。
function rateIsMissing(rate) { return rate === null; }

module.exports = { rateIsMissing };
