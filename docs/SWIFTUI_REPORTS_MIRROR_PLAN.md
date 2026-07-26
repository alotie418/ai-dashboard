# 阶段 1:报表引擎镜像方案(原生 SwiftUI)

> 状态:**方案待批准,尚未动工**。本文档只描述计划,不含任何实现。
> 前提:`electron/reports/*` 属 CLAUDE.md 受保护范围。本阶段的全部镜像 PR **逐字照搬公式、不做任何修正**;一切有意修正走单独 PR、单独标注(约束 2)。
> 分析日期:2026-07-25(main = `7e2f367`)。结论均来自读码 + 实机执行,关键数字已实测。

---

## 0. 摘要与需要你拍板的点

镜像目标是 `electron/reports/` 下的 6 个地区引擎 + 1 个调度器 + 3 个共享助手,约 808 行。

**分批的真正切口不是"损益表 vs 税额块",而是"这个字段是否读取 `settings` 里的值"。** 实测结论:

- 真正由可配置税率驱动的字段**只有两组**:`surchargeRate`(仅中国)与 `incomeTaxRate`(六地区)。
- **增值税/消费税/营业税汇总块全部是无税率的**——它们汇总的是每行记录的 `tax_amount` 列,不套用任何配置税率。
- `vat_rate` 这个设置项**没有任何引擎读取**(`electron/reports/index.js:74` 读入、`:83` 放进上下文,六个引擎无一使用)。它的 13 兜底对报表输出零影响。

由此产生一个**不可回避的不对称**,直接决定分批边界:

> 中国引擎的税前利润**无法**在不知道附加税率的情况下算出。依赖链是
> `profitBeforeTax`(cn.js:38)← `taxSurcharge`(cn.js:33)← `surchargeRate`。
> 而日本/欧盟/韩国/台湾的营业利润不含附加税,可以无税率算出。

所以第 1 批里,**中国只能做到毛利,其余四地区可以做到营业利润**。这是代码结构决定的,不是取舍。

### 需要你确认的三件事(见 §10)

1. 第 1 批中国是否接受"只到毛利"(即中国用户在第 1 批看不到营业利润行)。
2. 美国 Schedule C(1-31 行)算不算"不涉及税估算"——它不套用任何税率,但它是税表映射。我的建议是**单独成批**排在增值税之前、所得税之后。
3. 现有 fixture 太薄,需要**先扩充再写对照测试**(单独一个 PR)。是否同意。

---

## 1. 镜像范围与输出契约

### 1.1 文件清单

| Electron 文件 | 行为 | 本阶段处置 |
| --- | --- | --- |
| `reports/index.js` | 调度器:读设置、选数据源、取行、分发引擎、追加现金流 | 镜像(但**不镜像 legacy 回落分支**,见 §6.1) |
| `reports/_reportSource.js` | 纯函数:选 transactions 还是 legacy | 镜像(原生恒为 transactions,仍保留该字段以便对照) |
| `reports/_expenseSplit.js` | 纯函数:按 `is_cogs` 拆 COGS / 经营费用 | 镜像(第 1 批) |
| `reports/_cashflow.js` | 经营活动现金流(收付实现制) | 镜像(第 2 批) |
| `reports/cn.js` `jp.js` `eu.js` `kr.js` `tw.js` | 五个 VAT 模型引擎 | 分批镜像 |
| `reports/us.js` + `usTaxParams.js` | Schedule C + 自雇税 + 预缴估算 | 分批镜像 |

### 1.2 输出契约(镜像必须逐字对齐的形状)

每个引擎返回 **9 个顶层键**,调度器再追加 **1 个**(`cashflowStatement`,`index.js:90`,永远排最后)。以中国为例,实测键序:

```
locale, period, currency, reportTypes, incomeStatement,
vatSummary, taxInclusiveSummary, monthlyBreakdown, warnings, cashflowStatement
```

**命名并不统一,镜像时不得"顺手统一"**:

- 欧盟用 `profitLoss`,中/日/韩/台用 `incomeStatement`;
- 美国没有损益块,而是 `scheduleC` / `selfEmploymentTax` / `estimatedTax`;
- 中国 `incomeStatement.operatingProfit` 这个键里装的其实是**税前利润**的值(cn.js)。

> 附带发现:欧盟的 `profitLoss` 命名已经让 Electron 侧两个下游处理器读到 0
> (`retainedEarnings`、`incomeTaxPosition` 只认 `incomeStatement`)。**这是 Electron 侧既有缺陷,不在本阶段修**,记入 §9。

---

## 2. 分批方案(精确到字段)

### 第 1 批 —— 无税率损益核心(五个 VAT 模型引擎)

**共享助手**:`_expenseSplit`、`_reportSource`、`ReportMath`(见 §8.1)。

**字段**:`salesRevenue`/`revenue`、`costOfSales`、`costOfGoodsSold`、`operatingExpenses`、`grossProfit`、`grossMargin`、`adminExpense`;
中国另加 `shippingFee`(见下方注意),日/欧/韩/台另加 `operatingProfit`。

*为什么是这些*:这是**读取 `settings` 值为零的最大集合**(`adminExpense` 的兜底是 0,与地区无关),因此不需要兜底口径、不需要空态、不需要参数确认提示就能落地。

> **注意(必须原样镜像、不得"修好")**:`transactions` 表**没有 `shippingCost` 列**,
> 所以中国引擎的运费扣减在流水路径下**结构性恒为 0**(cn.js:24)。运费只存在于旧
> `sales` 表。镜像代码必须带注释指向该行,说明这是刻意保留的现状。

### 第 2 批 —— 无税率期间聚合

`taxInclusiveSummary`(五个 VAT 引擎;美国没有)、`monthlyBreakdown`(六地区;美国用含税 `amount`)、以及 `_cashflow` 的经营活动块(含 investing/financing/期初/期末 **必须渲染为"未配置"而非 0** 的契约)。

*为什么单独一批*:同样不读设置,但走的是完全不同的数据路径(原始 `amount` 汇总、`payment_status`/`paid_amount`/`payment_date`、以及数据源切换),且"null 不得显示为 0"这条规则值得单独评审。

### 第 3 批 —— 美国 Schedule C 映射

`scheduleC` 的 1/2/6/7 行、Part II 全部 8-30 行、`line28_totalExpenses`、`line31_netProfit`,以及 `usTaxParams.mealsDeductiblePct`(50% 餐费限额)。

*为什么单独一批*:实测它**完全不受 `incomeTaxRate` 影响**,按你的规则属"非估算";但它与五个 VAT 引擎零共享代码(不用 COGS 拆分、用含税 `amount`、按类别 slug 映射),而且是唯一需要镜像**税法常量**的一批——单独成批能让那个 50% 常量停在评审者眼前,而不是埋在五引擎大 diff 里。

### 第 4 批 —— 流转税汇总块

中国 `vatSummary`、日本 `consumptionTax`、欧盟 `vatReturn`、韩国 `vatSummary`、台湾 `businessTax`。

*为什么在这*:这些块**不读任何税率**(纯汇总已记录的 `tax_amount`),所以没有参数风险;但它们承载**地区专名与免责声明风险**——单独落地可以让辖区文案审查(约束 4)在没有任何公式改动的 PR 里完成。必须排在第 5 批之前,因为中国的附加税要消费本块的 `vatPayable`。

### 第 5 批(最后)—— 估算层

唯一读取税率的一批:中国 `taxSurcharge` → `operatingProfit`(税前利润);六地区的 `incomeTax` / `netProfit` / `netMargin`;美国 `selfEmploymentTax` + `estimatedTax` + `warnings[0]`。

兜底口径、"未配置"空态、一次性参数确认提示(约束 3)**全部随本批落地**——因为这正好是"设置值一变、数字就变"的字段全集,爆炸半径统一。

若本批过大,按数据里已有的接缝再切:**5a** = 中国附加税链(仅中国),**5b** = 六地区所得税 + 美国自雇税/预缴。

---

## 3. PR 拆分清单

| # | PR | 内容 | 验证 |
| --- | --- | --- | --- |
| R0 | `test(native): 扩充 Electron fixture 与报表黄金输出` | 扩充 `electron-v23.db`;新增黄金生成器;提交 18 个黄金 JSON | 生成器两次运行输出一致;现有 581 Core 测试不回归 |
| R1 | `feat(native): ReportMath —— JS 数值语义垫片` | `||` 取净额语义 + `Math.round` 垫片(见 §8.1) | 对照 node 生成的边界值(含 `amount_net = 0`、`r(-0.125)`) |
| R2 | `feat(native): 镜像 _expenseSplit 与无税率损益核心` | 第 1 批 | Tier-1 纯函数对照 |
| R3 | `feat(native): 镜像含税汇总、月度分解与经营现金流` | 第 2 批 | Tier-1 + Tier-2 |
| R4 | `feat(native): 镜像美国 Schedule C 映射` | 第 3 批 | Tier-1 + Tier-2(需 R0 补美国类别行) |
| R5 | `feat(native): 镜像流转税汇总块` + 辖区文案审查 | 第 4 批 | Tier-1 + 六语文案检查 |
| R6 | `feat(native): 报表参数兜底口径与未配置空态` | 约束 3 全部 | 单元测试覆盖"缺行"三态 |
| R7 | `feat(native): 镜像估算层(所得税/附加税/自雇税)` | 第 5 批 | Tier-1 + Tier-2 全矩阵 |
| R8 | `feat(native): 报表 UI 与免责声明` | 呈现层 + 挂载纪律 | 六语 parity + 免责声明挂载测试 |

**每个镜像 PR 内不得夹带任何修正。** 修正项清单见 §9。

---

## 4. 对照测试设计

### 4.1 两档机制(实测可行)

**Tier 1 —— 纯函数黄金(主力)**
直接调 `engine.generate(ctx)`,`ctx` 是普通 JS 对象,**不碰 sqlite、不需要 Electron 二进制**,普通 node 即可运行。这正是仓库现有两个守护脚本(`scripts/test-cogs-split.mjs`、`scripts/test-surcharge-locale.mjs`)的既有模式。第 1-5 批的公式对照全部走这一档。

**Tier 2 —— 调度器黄金(DB 驱动)**
`ELECTRON_RUN_AS_NODE=1 ./node_modules/.bin/electron` 驱动 `index.js` 打真实 fixture。这是覆盖**数据源选择、设置兜底、`WHERE locale = ?` 类别过滤、追加现金流**的唯一途径。

> **已实机验证**:用committed fixture 的副本跑出 6 制度 × 3 年 = 18 个黄金文件,
> 每个 2.3–3.1 KB,合计约 44 KB,两次运行字节一致。

### 4.2 三条必须钉死的环境约束

1. **固定 `LC_ALL=C LANG=C`**。`us.js:112` 用了 `toLocaleString()`,实测 en_US 下输出 `$298.41`、de_DE 下输出 `$298,41`。不固定则黄金随机器漂移。
2. **总是显式传 `year`**,让 `index.js:33` 的 `new Date()` 分支不可达,否则黄金会随年份失效。
3. **语义比较,不做字节比较**。两边都解码后逐字段断言,容差 `eps = 0.011`(半分钱,与现有守护脚本一致)。引擎在多处做 `Math.round(v*100)/100`,只在末尾取整一次的 Swift 实现会在最后一分钱上不同;字节比较还会让 key 顺序变成人质。**另加完整性断言**:黄金里出现过的每个键都必须被访问过,防止漏字段悄悄通过。

### 4.3 必须覆盖的用例(来自实测行为)

两种数据源;未分类支出行(VAT 引擎归经营费用、美国归 line 27a);中国 `vatPayable` 为 0 与大于 0;亏损期(`Math.max(0, …)` 钳位使净利等于营业利润);跨月的部分期间(月度分解仍输出 12 个自然月);日元/韩元账本(仍按 2 位小数取整——**镜像,不修**);`amount_net = 0` 的行(JS `||` 语义会回落到含税额)。

---

## 5. Fixture:现状、缺口与生成

### 5.1 现状(实测)

committed 的 `native/SoloLedger/Tests/SoloLedgerCoreTests/Fixtures/electron-v23.db` 只有:**7 条流水、全部挂中国类别、`sales`/`purchases` 皆空、仅 1 行 `is_cogs`、无任何美国 slug 类别**。因此美国 Schedule C 除 line 27a 外**结构性不可测**。

### 5.2 R0 要补的最小集合

带 `amount_net` 的 COGS 行;每条打算镜像的 Schedule C 行各一条美国类别流水(尤其 `returns`、`other-income`、`meals` 的 ×0.5 路径、`home-office`);一条部分付款的支出;跨两个月以上的第三年数据;若干 `sales`/`purchases` 行,让 legacy 分支不再全 0。

> **保留不动**:现有 txn-4 的 USD 行。多币种未换算直接相加是真实现状,**必须钉住而不是修掉**。

### 5.3 生成器落位

`native/SoloLedger/Tests/Fixtures/make-report-goldens.mjs`,沿用 `make-electron-fixture.mjs` 的头注释惯例(写明 `ELECTRON_RUN_AS_NODE` 的原因)。输出到 `Tests/SoloLedgerCoreTests/Fixtures/goldens/<LOCALE>-<YEAR>.json`,并在 `Package.swift:48` 的 `resources:` 数组追加 `.copy("Fixtures/goldens")`。

---

## 6. 兜底口径实现方案(约束 3)

### 6.1 先说一个必须写进产品行为的分歧

`_reportSource.js`:某期间**零流水**时,Electron 会**改读旧 `sales`/`purchases` 表**。原生版按 #395 的决定**不读旧表**。因此同一账本同一期间,两边会给出不同数字。

**原生侧的诚实做法(不实现 legacy 分支)**:

1. 输出里显式带上 `source = "transactions"`,便于与 Electron 的同名字段对照;
2. 新增**按期间**统计旧表行数的只读查询(现有 `LegacyLedgerProbe` 是全账本口径,回答不了报表级问题);
3. 该计数大于 0 时,在报表上明确提示"本期另有 N 条旧版记录未计入以下数字",复用 #395 的 `legacy.*` 文案;
4. **永不自动转换**。

### 6.2 兜底三态(按你的约束)

| 情形 | 行为 |
| --- | --- |
| 中国制度 | **保留兜底,与 Electron 完全一致**(附加税 12、所得税 25) |
| 非中国制度 + 参数行存在 | 用存储值计算 |
| 非中国制度 + 参数行缺失 | **不计算、不显示 0**,渲染"未配置"空态 + 引导至设置页(复用 #394 的分口径预设) |

**判定必须基于设置行的"缺失",绝不能基于算出来的值。** 实测:缺率时中国引擎产出 **NaN**(cn.js 的取整函数缺 `|| 0` 保护),而日/欧/韩/台/美产出**看起来正常的 0**。基于值的判断会把真实的 0% 税率误判为未配置。

### 6.3 存量账本

零静默写入(#394 的级联已保证只在**真的切换制度**时才写)。首次打开报表给**一次性参数确认提示**,让用户确认或跳转设置页;跳过不写任何值。

> 小规模纳税人适用税率问题**单独记录、不阻塞本阶段**(见 §9)。

---

## 7. 呈现与文案(约束 4)

### 7.1 可原样复用的 Electron 文案

5 个 `disclaimer.*` 键 + 约 8 个 `finance.*` 现金流/余额字符串 + `common.dataSourceNote`,**六语齐全且全部辖区中立**,可逐字复用。`scripts/check-disclaimer.mjs` 是硬性 CI 闸门(要求键存在、非空、各非英语语言与英语不同、且被固定的挂载文件引用)。

**挂载纪律要一并镜像**:`disclaimer.report` 挂页面级(每个报表页签都显示);`disclaimer.tax` 紧挨任何估算税额;`disclaimer.usTax` 只出现在美国自雇税/预缴处。建议把挂载检查移植成 Swift 测试。

**不要复用** `finance.cashflowDesc` / `balanceComingSoonDesc` 做"未配置"——它们写的是"添加记录后显示",而这里的阻塞原因是**缺少税率**而非缺少数据。需要为引导语新写一条短文案。

### 7.2 辖区错配审计结果(需在 R5/R6 修掉)

- **`ja.lproj` 的 `settings.surchargeRate` = "附加税率" 是未翻译的中文**——这是我在 #394 里为了避开与"付加価値税"混淆而选的写法,现确认对日文界面不合适。
- 更彻底的做法:**日/欧/韩/台的附加税率字段直接隐藏**。这四个地区的预设附加税率是 0,且引擎**可证明地不读取它**(`scripts/test-surcharge-locale.mjs` 已锁死该行为),隐藏它零损失。
- Electron 侧 `FinancePage.tsx:641-642` 在无报表时会把中国专属的"税金及附加"行泄漏到其他制度——**不要把这个门控逻辑镜像过来**(Electron 侧的修复另开 PR,见 §9)。

---

## 8. 前置工作

### 8.1 `ReportMath`(R1,必须先于任何引擎)

镜像若不复刻这两条 JS 语义,"逐字镜像"这句话就不成立:

1. **`||` 的取净额语义**:`r.amount_net || r.amount` 在 `amount_net` 为 **0** 时会回落到含税额(JS 把 0 当假值)。Swift 的 `??` 会保留 0,产生分歧。
2. **`Math.round` 语义**:JS 的 `Math.round(-0.125 * 100)/100` 与 Swift `rounded()` 的半数进位方向不同,需要 `floor(v*100 + 0.5)/100` 垫片。

两者各配 node 生成的边界值单测。

### 8.2 取数不得复用 `listTransactions`

它有 **5000 行静默上限**(`LedgerStore.swift`),超过就无声截断——用在报表上会在大账本上产生**安静的错误报表**。需要为报表新增一个按期间、无上限的取数接口。

---

## 9. 明确不在本阶段做的事(各自单独 PR、单独标注)

| 项 | 性质 | 建议处置 |
| --- | --- | --- |
| `index.js:74-78` 跨制度兜底(所得税 25 **与 currency 'CNY'**) | 会计政策(CLAUDE.md 类别 4) | **本阶段仅写迁移说明**。分析结论:现存 Electron 用户群体实际不可达(所有写 `accounting_locale` 的路径都在同一事务里写三个税率),改动受保护文件收益为零。原生侧用 §6.2 的"未配置"空态自行规避 |
| 欧盟 `profitLoss` 命名导致两个下游处理器读到 0 | Electron 侧既有缺陷 | 单独 PR,需确认 |
| `us.js` 把自定义 slug 支出排除在 line 28 之外 | 会计分类 | 单独 PR,需会计确认 |
| `cn.js` 缺率时产出 NaN(其余引擎产出 0) | 会改变输出 | **建议不改**,由原生侧拒绝渲染来兜住 |
| 小规模纳税人适用税率 | 税务政策 | 单独记录,不阻塞 |
| 类别在切换记账制度后被"孤立" | 两侧同源缺陷 | 本阶段**原样镜像**;若要处理,最低诚实标准是给出警告而非自动重挂 |

---

## 10. 请你确认

1. **中国第 1 批只到毛利**(税前利润因依赖附加税率必须排到第 5 批)——可以吗?
2. **美国 Schedule C 单独成第 3 批**(不套用税率、但属税表映射)——同意这个归类吗?
3. **R0 先扩充 fixture 再写对照测试**——同意吗?
4. §9 里"Electron 跨制度兜底只写迁移说明、不改代码"——认可吗?若你想要独立修复,我会按分析建议附一个 `scripts/check-report-fallbacks.mjs` 守护,确保兜底表与 `accountingProfiles.ts` 预设永远一致。

确认后我从 **R0** 开工。
