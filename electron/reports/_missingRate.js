// 「这个税率不能拿来算」的编码与判定 —— 方案 A(失败即拒)+ A-4(需修复)。
// 详见 docs/SWIFTUI_REPORTS_MIRROR_PLAN.md §9.1(四条规则)与 §6.2 / §6.4。
//
// 唯一的生产者是调度器 electron/reports/index.js 的 resolveRate,它在**两种**情形下
// 把税率置为 **null**:
//
//   1. 「未配置」—— 非中国制度且设置行缺失(方案 A,PR #419);
//   2. 「需修复」—— 行存在但存储文本不是一个可用的数字(A-4,本次)。
//
// 引擎对两者的处置相同:都不计算。它们的**区别在呈现层**——一个该说「去配置」,
// 一个该说「修复损坏值」——而报表 JSON 里两者都是 null。区分留在各自 App 的设置
// 读取层(原生侧是 ReportRateSetting 的四个 case),由 R8 分别呈现。
//
// null 在这里是一个有意义的值 ——「我们不知道这个税率」,不是 0。引擎必须显式分支:
// JS 里 `null / 100 === 0`,漏判就会把「不知道」静默算成「0%」,那是本次要消灭的
// 那类谎的另一个版本。
//
// **只认 null,不认 undefined。** undefined 表示调用方(纯函数守护脚本、直接调
// engine.generate 的测试)根本没给这个参数,那走的是既有的 NaN 路径,与「调度器判定
// 为不可用」是两回事,一个字节都不改。
function rateIsMissing(rate) { return rate === null; }

module.exports = { rateIsMissing };
