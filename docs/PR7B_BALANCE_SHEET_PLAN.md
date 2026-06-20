# PR-7B 资产负债表：现状盘点与会计确认清单

> 状态：**只读盘点文档（PR-7B-0）**。本文不实现任何报表、不改 schema、不改 `electron/reports`、不改 `FinancePage`、不改 i18n、不新增任何计算逻辑。
> 所有「会计准则口径」未定项一律标记 **[需会计确认]**，不在文档中自行发明。
> 证据均给出 `文件:行` 或 `表.列`。盘点时点：main `41ee0cf`（PR-7D 管道层五表全部合并后，schema **v18**）。
> 本文是 PR-7B 后续所有子 PR（7B-1 及以后）的**前置闸门**：分类 / 折旧 / 结转 / 对冲 / 平衡 在拿到会计师确认前不得落地。

---

## A. 结论速览

1. **利润表（P&L / 经营损益概览）已实现**，**现金流量表（经营活动 · 管理口径 MVP）已实现**（PR-7C）。
2. **资产负债表 = 仍为 coming-soon 占位**，报表引擎不产出任何 balanceSheet 块。
3. PR-7D 已补齐**五张政策中性登记台账**（账户+期初 / 负债 / 固定资产 / 权益 / 已缴税款），它们目前**只登记、不计算、不结转、不对冲、不入报表**。
4. 即便有了这五张表，**当前架构仍无法编制一张真正平衡的法定级资产负债表**（无总账/双分录、数据为「期初+本期+估算」混合体、现金无期末滚存、固资无净值、利润无结转）。
5. **可安全先行的只有**：本确认清单文档（7B-0）+「各台账余额汇总快照」（7B-1，严格非 B/S、不分类、不平衡、不计算）。其余（7B-2~7B-6）**全部 [需会计确认]**。

---

## B. 当前 B/S 相关代码入口盘点（证据）

### B1. 前端入口与渲染
- `components/FinancePage.tsx:15` — `type StatementType = 'pl' | 'balance' | 'cashflow'`。
- `components/FinancePage.tsx:269-270` — balance tab 按钮（`finance.tabBalance`）。
- `components/FinancePage.tsx:330-338` — balance tab **当前为 coming-soon 空态**：仅渲染 `finance.balanceComingSoonTitle / balanceComingSoonDesc / comingSoonBadge`，**不渲染任何资产/负债/权益数字**。
- `components/accountingHelpers.ts:169` — tab 注册 `{ id: 'balance', labelKey: 'finance.tabBalance' }`。

### B2. 数据接缝（PR-7B 若接入，从这里走）
- `components/FinancePage.tsx` → `generateReport()`（`services/api.ts:765`）→ IPC `/api/reports/generate` → `electron/reports/index.js` `generate()`。
- `electron/reports/index.js:89-90`：
  ```js
  const result = engine.generate(context);
  return { ...result, cashflowStatement: computeOperatingCashflow(db, { from, to }) };
  ```
- → **PR-7B 的 balanceSheet 块应沿用 PR-7C 的 additive 模式**：`return { ...result, cashflowStatement, balanceSheet: <…> }`，FinancePage balance tab 改渲染 `report.balanceSheet`。**本文不实现此接入。**

### B3. 报表引擎现状
- `electron/reports/{cn,us,jp,eu,kr,tw}.js` 产出 `incomeStatement`（含 `netProfit / grossProfit / salesRevenue / costOfSales …`，见 `cn.js:52-64`）；**引擎不产出任何 balanceSheet 块**。
- `electron/reports/_cashflow.js` — 经营活动现金流（管理口径，PR-7C）；投资/筹资/期初期末现金为 `null`（未配置）。

### B4. 已有 i18n（全部预留 / 当前未渲染 = dead）
- `i18n/locales/*.json` 的 `finance.balance*` 已含**整套 B/S 标签**：`balanceCash / balanceReceivable / balanceInventory / balanceFixed / balancePayable / balanceTax / balanceCapital / balanceRetained / balanceAssets / balanceLiabilities / balanceEquity` + 各 `*Total`（6 语言齐）。
- `components/accountingLocaleConfig.ts` 制度级标签：`balPaidInCapital / balRetainedEarnings / balLiabEquityHeader / balTotalLiabEquity / balEquityHeader / balPayLabel / balRecvLabel / balTaxPayLabel`。
- **核验**：上述详细分类标签**当前零组件引用**（balance tab 仅渲染 coming-soon 三键）→ 词汇表已译好但**完全未渲染**，专等 PR-7B 点亮。**本文不点亮任何。**

### B5. 相关守卫（PR-7B 各子 PR 必须延续）
- `scripts/check-report-titles.mjs`：`finance.tabBalance` **不得**用裸法定名（资产负债表 / Balance Sheet …）；`finance.balanceTaxPayable / balanceTax` **必须**带估算标记（估算 / Estimated / 推定 / 추정 / estimé）。当前 `tabBalance = "经营资产概览"`、`balanceTax = "估算应付税款"` 均合规。
- `scripts/check-hardcoded-rates.mjs` / `check-tax-labels.mjs` / `check-ai-tone.mjs` / `check-us-tax-params.mjs`：禁硬编码税率、禁越界税务措辞。

---

## C. 7D 五张管道表的数据来源说明（B/S 可消费数据）

| 表（迁移版本） | 关键列 | B/S 中的潜在用途 | 现状 |
|---|---|---|---|
| `accounts`（v14, 7D-1） | `opening_balance` / `type(cash\|bank)` | 货币资金 | ⚠️ **仅期初余额，无期末滚存**（无流水联动、无双分录） |
| `liabilities`（v15, 7D-2） | `opening_balance` / `liability_type` / `interest_rate`（备查） | 借款 / 其他负债 | ⚠️ 仅期初；利率仅备查不计算 |
| `fixed_assets`（v16, 7D-3） | `original_value` / `status` | 固定资产 | ⚠️ **仅原值，无折旧 / 无净值**（无折旧字段） |
| `equity`（v17, 7D-4） | `amount` / `equity_type` | 实收资本 / 权益变动 | ⚠️ 求和口径需定；无结转 |
| `tax_payments`（v18, 7D-5） | `amount` / `tax_type` / 期间 | 已缴税款（信息） | ⚠️ 与「应交」对冲属政策；见 §E |

**非 7D、但 B/S 需要的既有 live 数据源：**
- 应收账款：`electron/handlers/receivables.js` `receivablesSummary().totalReceivable`（未付销售，**真实**）。
- 应付账款：`electron/handlers/receivables.js` `payablesSummary().totalPayable`（未付采购，**真实**）。
- 存货：`electron/handlers/inventory.js` `summary()`（在库 × 加权平均成本，不含税，**真实**）。
- 本期净利：`incomeStatement.netProfit`（报表引擎，**真实**，但跨期结转 → §E）。

---

## D. 哪些数据目前只能作为「管理口径快照」（不能成正式 B/S 行）

| 数据 | 为什么只能做快照 |
|---|---|
| `accounts.opening_balance` | 只有期初，缺「期初 + 本期收付 = 期末」滚存；现金期末不可靠 |
| `liabilities.opening_balance` | 只有期初，缺还款滚存 |
| `fixed_assets.original_value` | 只有原值，缺累计折旧 → 不是净值（账面价值） |
| `equity.amount` | 事项求和，缺与留存收益/本年利润的合并口径 |
| `tax_payments.amount` | 已缴流水，缺与「应交估算」的对冲口径 |
| `incomeStatement.netProfit` | 本期利润，缺跨期结转到未分配利润 |

→ 这些可以**透明罗列为各台账/各往来的真实数字**（管理参考），但**不能**直接拼成「资产 / 负债 / 权益」并声称平衡。

---

## E. 必须会计师确认的项目（AI 不得自决） [需会计确认]

| 编号 | 确认项 | 影响 |
|---|---|---|
| K-3 | 资产 / 负债 / 权益**分类体系**（六制度各自）+ 各表→科目/报表行**映射** + 流动/非流动切分 | 7B-2 |
| K-4 | 建账**期初余额勾稽**规则；资产负债表**平衡校验口径**（差额=0 才成表？还是显式列差额？） | 7B-2 / 7B-6 |
| K-5 | 固定资产**折旧方法 / 年限 / 残值率**（直线/加速；六制度差异） | 7B-3 |
| K-6 | **应交 / 已交税费对冲**与列示（`tax_payments` 是否、如何入表；与 `estimatedPayable` 的关系） | 7B-5 |
| K-9 | 留存收益 / 未分配利润 / **本年利润结转**（净利跨期、期初留存、分红处理） | 7B-4 |
| K-10 | 多币种折算口径（如适用） | 全部 |

> 在以上各项获得会计确认前，对应子 PR 不得落地。

---

## F. 当前不能做「正式资产负债表」和「平衡校验」的原因（架构层）

1. **无总账 / 双分录（GL / double-entry）**：现有数据是「期初余额（accounts/liabilities）+ 本期 live 流水（AR/AP/存货/净利）+ 估算（税）+ 未结转求和（equity）」的**混合体**，不存在复式记账的借贷自洽。
2. **现金无期末滚存**：`accounts` 只有期初余额；虽有 PR-7C 经营活动现金流，但投资/筹资/期初期末现金为 `null`，无「期初 + 净现金流 = 期末」的勾稽链路 → 货币资金期末不可靠。
3. **固定资产无净值**：只有原值，无折旧台账（折旧 = 政策 = K-5）。
4. **权益无结转**：净利未结转到未分配利润（结转 = 政策 = K-9）。
5. **税款无对冲**：已缴（tax_payments）与应交（估算）未对冲（对冲 = 政策 = K-6）。

→ 结论：**资产 = 负债 + 权益 几乎必然不平衡**。强行配平 = 发明会计政策 + 误导用户，违反 CLAUDE.md 产品边界（不得把不完整模块当正式报表）。一张真正平衡的法定级 B/S 需要「双分录基础 + 现金期末滚存 + 会计师确认」的更大工程，**远超 PR-7B 范围**。

---

## G. PR-7B 后续子 PR 拆分建议（风险从低到高）

| 子 PR | 目标 | 可做 / 禁止 | 前置 | 风险 |
|---|---|---|---|---|
| **7B-0**（本文档） | 现状盘点 + 会计确认清单 | 仅 docs；不碰代码 | 无 | 🟢 极低 |
| **7B-1** 各台账余额汇总快照 | 只读聚合各台账/往来真实数字，**按来源台账**罗列，强免责，明确「非 B/S · 未平衡 · 管理口径」 | 可：additive 只读 SUM（仿 `_cashflow.js`）+ FinancePage 渲染 + 快照专用 i18n。禁：分类为资产/负债/权益、A=L+E 总计、折旧/结转/对冲/平衡、点亮 `finance.balance*` 分类标签、tax_payments 与估算对冲、改既有 reports 公式 | 无（会计确认前可做） | 🟡 低-中 |
| **7B-2** 资产/负债/权益基础分类聚合 | 按 confirmed 分类归三栏 + 小计；不平衡断言 | 需 confirmed 分类映射 | **K-3** | 🟠 中-高 |
| **7B-3** 固定资产折旧 / 净值 | 累计折旧 + 净值（需先给 7D-3 加折旧字段/台账 schema） | 需 confirmed 方法/年限/残值 | **K-5** | 🔴 高 |
| **7B-4** 留存收益 / 未分配利润结转 | 净利→未分配利润跨期结转 | 需 confirmed 结转规则 | **K-9** | 🔴 高 |
| **7B-5** 应交/已交税费对冲 | tax_payments 与估算对冲 + 列示 | 需 confirmed 对冲口径 | **K-6** | 🔴 高 |
| **7B-6** 完整 B/S + 平衡校验 | 组装完整表 + 平衡断言（差额=0 才渲染） | 需全部上项 + 现金期末滚存（架构缺口） | **K-3/4** + GL 基础 | 🔴 最高 |

**推荐顺序**：`7B-0`（本文）→ `7B-1`（快照，会计确认前可做）→ 拿会计确认 → `7B-2 → 7B-3 → 7B-4 → 7B-5 → 7B-6`。

**架构层建议**：PR-7B **不以「平衡的法定 B/S」为目标**，落在「经营状况数据快照 / 管理口径资产负债概览」——透明展示真实数字 + 强免责 + 不声称平衡；法定级 B/S 留待（双分录基础 + 会计师）的更大工程。与 CLAUDE.md 产品边界一致。

---

## H. tax_payments 在 B/S 中的处理（单列说明）

- **7B-1（快照）**：可作**独立信息行**展示「已缴税款合计」，**不与** `estimatedPayable` 净额/对冲。
- **7B-5（对冲）**：已缴抵应交、税款余额列示 = **K-6 [需会计确认]**，确认前不做。
- 任何「已缴抵应交」的净额展示在 K-6 确认前一律视为越界。
