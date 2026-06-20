# PR-7B P1：管理口径资产负债概览 · 详细实施文档（P1-0）

> 状态：**只读实施文档（P1-0）**。本文不实现任何功能、不改 schema/handlers/FinancePage/reports/i18n。
> 依据：`docs/PR7B_ACCOUNTANT_RESPONSE.md`（会计师确认书）§一 实施优先级 P1，及 `docs/PR7B_BALANCE_SHEET_PLAN.md`。
> 适用前提：本工具定位为「经营管理估算」，**非法定报税/审计系统**。盘点时点：main `02881e8`（schema v18）。
> 本文是 P1-1~P1-4 子 PR 的实施依据。

---

## A. P1 范围与定位

P1 = 在不引入复式总账的前提下，做出一张**「管理口径资产负债概览」**（非法定资产负债表）：
- **K-3 分类**：把现有数据归入 资产 / 负债 / 所有者权益 + 流动 / 非流动（一套通用逻辑，标签按制度切换）。
- **K-4 概览 + 差额行**：显式列示「平衡差额／待调整」，**不追求法定严格平衡**，不可隐藏差额；全程免责标注。
- **现金/银行期末结转**：`期末估算 = 期初余额 + Σ本期实收 − Σ本期实付`（只读，不写回）。

**不在 P1**（属 P2/P3，须按确认书口径另做）：固定资产折旧（P2）、留存收益/未分配利润/本年利润结转（P2）、税费抵扣/对冲（P3）、多币种折算（P3）。

**4 个已拍板口径（用户确认）：**
1. **计算落点**：新增独立只读 handler（`cashPosition` / `balanceOverview`）。允许 `require` 复用 `electron/reports` 已导出的纯函数 `computeOperatingCashflow` / `selectReportSource`，但**不修改 `electron/reports/*`**；若复用引入风险，可在新 handler 内本地实现只读 SUM。
2. **现金结转窗口**：跟随 FinancePage 当前年份/期间选择 `[from,to]`，**不做「建账起至今」累计**。
3. **概览落点**：P1-4 可改 FinancePage balance tab，激活为「管理口径资产负债概览」；**P1-0~P1-3 不改 UI**。
4. **借款流动/非流动**：用 `liabilities.maturity_date` 按一年线分；**maturity_date 为空时默认按流动列示**，并在界面说明标注「未填写到期日，暂按流动列示」。

---

## B. K-3 分类最小实现

### B1. 通用分类映射（一套逻辑，六制度通用）

| 数据源 | 归类 | 流动性 | P1 取值口径 |
|---|---|---|---|
| 现金/银行（`accounts`） | 资产 | 流动 | 期末估算（见 §D），按币种 |
| 应收账款（`receivables.totalReceivable`） | 资产 | 流动 | live 未付销售合计 |
| 存货（`inventory.summary`） | 资产 | 流动 | 在库 × 加权平均成本（不含税） |
| 固定资产（`fixed_assets.original_value`） | 资产 | **非流动** | **原值**（折旧属 P2） |
| 应付账款（`payables.totalPayable`） | 负债 | 流动 | live 未付采购合计 |
| 借款/其他负债（`liabilities.opening_balance`） | 负债 | **按 `maturity_date` 一年线分** | maturity ≤1年→流动；>1年→非流动；**空→流动（标注）** |
| 出资/实收资本（`equity.amount`） | 权益 | — | 启用行合计 |
| 期初未分配利润／业主权益调整 | 权益 | — | 配平项（见 §C） |
| 应交税费（估算）、已缴税款（`tax_payments`） | — | — | **P1 不并入任何合计**（税属 P3；已缴税款沿用 7B-1 仅备查） |

> 仅统计**启用行**（`is_active = 1`），沿用 7B-1 口径；多币种**按币种分列、不折算**。

### B2. 标签层：六制度收敛 4 套（会计师 §〇.4）

- **结构层（怎么归类/配平）= 一套通用引擎**；**展示层（叫什么名）按制度档位换标签**。
- 4 套标签：**ASBE（中）/ US GAAP（美）/ JGAAP（日）/ IFRS 系（欧 = 韩 = 台 共用）**。
- **复用现有已译好的 i18n**：`finance.balance*`（balanceCash/Receivable/Inventory/Fixed/Payable/Capital/Retained…，6 语言齐）+ `accountingLocaleConfig` 的 `balPaidInCapital/balRetainedEarnings/balLiabEquityHeader/balTotalLiabEquity/...`（per-locale）。**不新造词汇表**；EU/KR/TW 三档核对为 IFRS 术语一致即可。

### B3. 最小边界
P1 只做 资产/负债/权益 + 流动/非流动两档；**不做**更细科目树、不做资本公积/盈余公积细分（属 K-9/P2）。

---

## C. K-4 管理口径资产负债概览

- **页面名称**：**「管理口径资产负债概览」**（各制度对应管理口径标题）；**绝不**叫「（法定）资产负债表 / Balance Sheet」。
- **落点**：FinancePage balance tab（当前 coming-soon，`finance.tabBalance="经营资产概览"`）→ P1-4 激活为管理口径概览。
  - ⚠️ 守卫 `check:report-titles`：`finance.tabBalance` 禁含裸法定名「资产负债表」。「资产负债**概览**」不含「资产负债**表**」三字、且带「管理口径」前缀 → 合规；实现时须复核守卫绿。
- **配平 = 权益**（会计师 §〇.3 / K-4）：`期初权益 = 期初资产 − 期初负债`，差额计入「期初未分配利润／业主权益调整」，建账天然平衡，无需用户凑数。
- **差额行（必须 · 不可隐藏）**：
  - `平衡差额／待调整 = 资产合计 − （负债合计 + 权益合计）`。
  - 显式列示，附来源提示（漏记的收付、估值差、跨期未结转、投资/筹资现金未计入等）。
  - **绝不静默隐藏**；差额 ≠ 0 是管理口径常态，不报错、不强制配平。
- **返回标志**：`statutory: false`、`balanced: false`、`managementBasis: true`（与 7B-1 一致）。

---

## D. 现金/银行 期末结转

### D1. 公式与窗口
- 公式：`现金期末估算（按币种）= Σ accounts.opening_balance(启用) + Σ本期实收 − Σ本期实付`。
- 窗口：**跟随 FinancePage 当前所选年份/期间 `[from,to]`**（拍板点 2），不做「建账起至今」累计。

### D2. 实收/实付口径（复用现成、防双计）
- 按 `payment_date` 落在 `[from,to]`、`payment_status IN ('paid','partial')` 的 `paid_amount` 汇总（与 `computeOperatingCashflow` 同口径）。
- **用 `selectReportSource` 选源**：本期有 transactions → 用 `transactions`（income/expense 的 paid_amount）；否则 fallback `sales`（实收）/`purchases`（实付）。**避免迁移数据与旧表双计。**

### D3. ✅ 计入
- 销售实收（`sales.paid_amount`）、采购实付（`purchases.paid_amount`）、`transactions` 的 income/expense 实收付（经选源）。

### D4. ❌ 暂不计入（避免错算，缺口落入差额行）
- **权益注资 / 借款收款 / 固定资产购建付款**（投资·筹资现金）：`equity`/`liabilities` 是「余额登记」非「现金事件」，现有现金流的投资/筹资本为 null，**无法干净识别为现金流** → 不计入。
- **多币种不折算**（K-10/P3）：现金按币种分别结转。
- 说明：`paid_amount` 为**单字段累计**、`payment_date` 为最后一次 → 跨期分期付款不精确 → 整体标注「估算」。

### D5. 只读 · 不写回
- `accounts.opening_balance` 是用户建账输入，**P1 绝不写回 / 覆盖**；期末值仅在概览中实时计算展示，标注「估算 · 未含投资筹资 · 按币种」。
- **per-account 限制**：现金流未挂到具体账户 → 只能给**汇总期末估算（按币种）**，不做逐账户期末。须明确说明。

---

## E. 免责声明文案要求

- 概览页必须同时呈现：
  1. 复用既有 `disclaimer.report`（「本视图为经营管理估算…并非法定财务报表…」）。
  2. 概览专属一句：**「本概览为管理口径，未做法定严格平衡；下方『平衡差额／待调整』为待调整项，非真实差错即可忽略。」**（6 语言）。
- 现金行附标注：「期末为估算，未含投资/筹资现金，按币种分列」。
- 借款行（maturity 空时）附标注：「未填写到期日，暂按流动列示」。

---

## F. P1 子 PR 拆分（推荐顺序）

> 计算落点：新增独立只读 handler，不修改 `electron/reports/*`（可 `require` 复用其导出纯函数）。

| 子 PR | 目标 | 可做 | 禁止 | 涉及文件 | 验证 | 风险 |
|---|---|---|---|---|---|---|
| **P1-0**（本文档） | P1 技术规格 | 仅 docs | 任何代码 | `docs/PR7B_P1_PLAN.md` | `check:all` | 🟢 极低 |
| **P1-1** 分类/标签常量 | 数据源→{section,liquidity} 通用映射 + 4 套标签键（复用现有 i18n） | 纯常量 + 守卫断言 | rollup/计算/UI/改 reports | `electron/handlers/_balanceClassify.js`、`scripts/check-*.mjs` | `check:all`+`typecheck` | 🟡 低 |
| **P1-2** 现金期末结转 preview | 只读 `GET /api/cash-position`：按币种 期末=期初+实收−实付 | 复用 computeOperatingCashflow/selectReportSource；返回 estimate | 写回任何表/含投资筹资/折算/改 reports/改历史 | `cashPosition.js`、`router.js`、`services/api.ts`、`test-handlers.mjs` | `check:all`(含 handlers)+`typecheck`+`build` | 🟡 低-中 |
| **P1-3** 概览聚合+差额 | 只读 `GET /api/balance-overview`：分类归集 + 各小计 + 差额=资产−(负债+权益) + 标志 | P1-1 分类 + 借款按 maturity 分流 | 折旧/利润结转/税额对冲/折算/强制平衡/改 reports/改历史 | `balanceOverview.js`、`router.js`、`services/api.ts`、`test-handlers.mjs` | 同上 | 🟠 中 |
| **P1-4** 概览 UI + 差额行 + 免责 | FinancePage balance tab 激活为「管理口径资产负债概览」 | 改 FinancePage balance tab、accountingHelpers tab 标题、i18n（概览标题/差额行/免责句/标注） | 叫法定报表名/强制平衡/隐藏差额/折旧/结转/对冲/折算/改 reports | `FinancePage.tsx`、`accountingHelpers.ts`、`i18n/locales/*.json` | `check:all`+`typecheck`+`build`+`test:locale-ui` | 🟠 中（人工验收） |

**推荐顺序**：`P1-0` → `P1-1` → `P1-2` → `P1-3` → `P1-4`。

---

## G. 明确禁止范围（P1 全程）

- ❌ 不做正式法定资产负债表；❌ 不要求严格平衡；❌ **不隐藏差额行**；
- ❌ 不做固定资产折旧（P2）；❌ 不做留存收益/未分配利润/本年利润结转（P2，P1 仅用「期初权益=资产−负债」配平，不滚动本期利润）；
- ❌ 不做税费抵扣/对冲（P3）；❌ 不做多币种折算（按币种分列，P3）；
- ❌ 不做复式总账；❌ **不修改历史交易数据**（现金结转纯只读、不写回 accounts/sales/purchases/transactions）；
- ❌ 不修改 `electron/reports/*`（仅 `require` 复用其导出纯函数）。

---

## H. 人工/会计验收点（P1 落地后）

- 用一组已知数据核对「资产合计 / 负债合计 / 权益合计 / 平衡差额」四数与手算一致。
- 6 语言 × 各制度档位下概览渲染、标签正确、**页面不声称平衡、差额行可见、免责醒目**。
- 现金期末估算 = 期初 + 实收 − 实付（按币种）人工对账。
- 借款按 maturity 一年线分流（含 maturity 空→流动+标注）正确。
