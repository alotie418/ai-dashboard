# PR-7B P3：税费模块（K-6）+ 多币种折算（K-10）· 实施文档（P3-0）

> 状态：**只读实施文档（P3-0）**。本文不实现任何功能、不改 schema/handlers/UI/i18n/reports。
> 依据：`docs/PR7B_ACCOUNTANT_RESPONSE.md`（会计师确认书）§K-6 / §K-10 / §一 P3，及 P1/P2 已落地能力。
> 适用前提：本工具定位为「经营管理估算」，**非法定报税/审计/正式税务计算系统**。盘点时点：main `f3ccf83`（P1+P2+收尾补丁全完成，schema v19）。
> 本文是 P3-1 / P3-3 / P3-4 子 PR 的实施依据；P3-2（多币种参考折算策略）已**并入本文 §F**，不单开 PR。

---

## A. P3 范围与定位

P3 目标（会计师 §一 P3）：在**已完成的管理口径资产负债概览**（P1+P2）之上，**保守地**补两块：
- **K-6 税费**：让「应交税费 / 已缴税款」在管理口径下更可信——**仅所得税**做同税种同期间对冲 preview；VAT/销售税默认备查。
- **K-10 多币种**：默认仍按币种分列、不折算；仅提供「按用户汇率折算的**参考合计**」preview。

**会计师明确定调（务必遵守）：**
> P3 对小微/个体**低优先**；税费六制度差异最大、最易做错；多币种折算对小微基本用不到。**宁可保守**——所得税可干净对冲，**增值税默认备查不并入合计**，多币种**默认不折算**。完整 VAT 精算、汇兑损益、税务申报对小微「价值低、出错风险高」。

**总原则（延续 P1/P2）：read-only preview，不写回、不生成分录、不改 `electron/reports/*`、不强制平衡、差额行不隐藏、免责不移除。**

**本文已拍板（用户确认）：**
1. 先做 P3-0 文档（本文），不写业务代码。
2. P3-2 多币种参考折算策略**并入本文**（§F），不单独开 PR。
3. P3-1 方向 = **所得税同税种同期间对冲只读 preview**（非仅 taxPayments 备查说明）。
4. P3-3 参考折算先做 **handler-only preview**，不接 UI。
5. 参考汇率存储**仅在本文定策略**（§F.4），P3-0 不实现 settings/UI。
6. VAT / 销售税**默认继续备查、不进入合计**。
7. 完整 VAT 销项−进项模块、汇兑损益分录、真实税务申报**全部后置**，不在 P3。

---

## B. 现状盘点（P3 起点）

| 项 | 现状（main f3ccf83） |
|---|---|
| `tax_payments` 台账（v18） | 列含 `tax_type`(vat/income_tax/surcharge/payroll_tax/sales_tax/other CHECK)·`amount`·`currency`·`payment_date`·**`period_start`/`period_end`**·authority·reference_no。仅登记、零计算、**默认备查** |
| reports 税额来源 | `incomeStatement.incomeTax`（应计所得税估算·CN/JP/EU/KR/TW）；`vatSummary.estimatedPayable`（销项−进项，从交易税列算）；US `scheduleC`+`estimatedTax.annualIncomeTax`(+SE tax)；销售税无引擎计算 |
| `balanceOverview` 税处理 | 税（应交估算/已缴税款）**完全不进任何 section/totals**，仅 `excludedNotes` 备查；当前不 emit 任何税款行 |
| 多币种 | cashPosition / balanceOverview / ledgerSummary 全部 **byCurrency 分列、不折算、不跨币种合计**；retainedEarnings 单一本位币 |
| 本位币/汇率 | `currency` 设置（默认 CNY）= 事实上的**功能货币/本位币**。**无独立 base_currency 键、无 exchange_rate 表、无任何汇率存储** |

---

## C. K-6 税费模块保守口径

### C.1 税费可对冲 / 备查矩阵（会计师 K-6）

| 税种 | P3 处理 | 理由 |
|---|---|---|
| **所得税 income_tax** | **可做同税种同期间对冲 preview**（P3-1/P3-4） | 应计=应纳税所得×率、可干净对冲（应计−已缴=应交/预缴） |
| **增值税 vat**（CN/EU/KR/TW）/ **消費税**（JP） | **默认备查，不并入合计** | VAT 应交=销项−进项，非「收入×率」；真实抵扣需单独采集进项税额（独立模块） |
| **销售税 sales_tax**（US） | **默认备查**；纯负债，**严禁套 VAT 进项逻辑** | 代收代缴、无进项抵扣、不进损益（见 §E） |
| **附加税 surcharge** | 默认备查 | 以 VAT/消费税额为基数，依赖 VAT 模块 |
| **payroll_tax / other** | 默认备查 | 口径分散，P3 不做对冲 |

### C.2 tax_payments 备查原则

- **默认**：`tax_payments` 各税种**独立备查**、**不参与任何合计**（延续 ledgerSummary `taxPaidMemo` 与 balanceOverview excludedNotes 现状）。
- **唯一例外**：`tax_type='income_tax'` 在 P3-4 接入概览时参与对冲（见 C.3）。
- **不做**：不把 tax_payments 自动冲减「应交税费估算」——**除非同税种同期间且作为 preview**（会计师 K-6(1)）。

### C.3 所得税同税种同期间对冲 preview 口径（P3-1）

```
期末应交所得税(估算) = 本期应计所得税 − 本期已缴所得税
```
- **本期应计**：只读复用 reports `incomeStatement.incomeTax`（CN/JP/EU/KR/TW）；**US 取 `estimatedTax.annualIncomeTax`**（locale 特判）。**仅 require、不改 reports**。
- **本期已缴**：`Σ tax_payments WHERE tax_type='income_tax' AND 期间重叠 AND currency=本位币`。
  - **「同期间」匹配**：优先用 `period_start`/`period_end` 与报表期间 `[from,to]` **重叠**（该笔缴款是「为本期」缴）；二者皆空时回退 `payment_date ∈ [from,to]`。
  - **本位币**：仅本位币已缴参与对冲；非本位币已缴**排除并入 excludedNotes**（不折算，K-10）。
- **结果列示**（会计师 K-6(3)）：
  - 净**欠缴**（应计 > 已缴 → netPayable > 0）：流动**负债**「应交税费（所得税·估算）」。
  - 净**多缴/预缴**（已缴 > 应计 → netPayable < 0）：流动**资产**「预缴税款」。
- **只读**：`GET /api/income-tax-position` 返回 `{ accrued, paid, netPayable, baseCurrency, period, estimate:true, limitations, excludedNotes }`；**不写回、不接概览（P3-4 才接）、不生成分录**。

### C.4 VAT 默认不并入合计、不做完整销项−进项

- P3 **不做** B/S 层的 VAT 销项−进项整合。`vatSummary.estimatedPayable` 仅在损益/报表页作既有展示，**不进概览合计**。
- 小微（中国小规模纳税人按征收率、或起征点以下免税）若要 VAT 估算：可显示 `VAT ≈ 含税销售 ÷ (1+征收率) × 征收率`，**但须标「简化估算」、默认不并入合计**——此为**后续独立选项**，不在 P3 默认路径。
- 真实 VAT（一般纳税人销项−进项、留抵）= **独立 VAT 模块，后置**，需单独采集采购进项税额。

---

## D. （见 C）

> 章节占位已并入 C；保持编号连续。

---

## E. US 销售税 与 VAT 分流风险（会计师 K-6(4)·点名「最易踩的坑」）

- **中国/欧盟/韩国/台湾**：增值税/营业税（销项−进项，有进项抵扣）。
- **日本**：消費税（同 VAT 机制，有进项抵扣）。
- **美国**：销售税 sales tax —— **仅代收代缴、无进项抵扣机制、纯负债、不进损益**。
- **铁律**：税费 preview 必须**按 `accounting_locale` 分流**；**US 不可套用 VAT 的进项/销项逻辑**。
  - P3-1 所得税 preview 对 US 取 `estimatedTax.annualIncomeTax`（locale 特判，已在 §C.3）。
  - 销售税在 P3 **仅备查**；未来若做销售税负债，须按「纯代收负债」建模，**不进损益、无进项**。

---

## F. K-10 多币种折算（保守默认 = 方案④）

### F.1 默认：按币种分列、不折算

- cashPosition / balanceOverview / retainedEarnings / ledgerSummary **维持 byCurrency 分列、不折算、不跨币种合计**。P3 **不改这一默认**。

### F.2 currency 设置 = 本位币（功能货币）的当前口径

- 现有 `currency` 设置（默认 CNY）即**记账本位币/功能货币**。
- 会计师 K-10(1)：本位币=经营主要经济环境货币，小微默认本国货币。
- P3 **不新增 base_currency 键**；文档明确 `currency` 承担本位币语义即可。

### F.3 哪些可折算 / 不可折算（会计师 K-10(2)·仅作口径记录，P3 不逐项实现）

| 项目类型 | 适用汇率 | 差额去向 |
|---|---|---|
| 货币性（现金/应收/应付/借款/应交税费） | 期末即期汇率 | 汇兑损益 → 当期损益 |
| 非货币性（存货/固定资产） | 历史汇率（不重估） | 无差额 |
| 权益（出资/实收资本） | 历史汇率（不重估） | 无差额 |
| 收入/费用 | 平均汇率 | 含于当期损益 |

> **P3 不做逐项分汇率**（那属「轻量折算」，连带汇兑损益，**后置**）。P3 只做整体「参考折算」（§F.4）。

### F.4 参考折算 preview 策略（P3-3·handler-only）

- **做法**：把 byCurrency 各币种**合计**按**用户提供的参考汇率**整体折成本位币，给一个「**参考合计**」，**显著标注「仅供参考·非折算入账」**。
- **只读铁律**：**保持 byCurrency 分列不变、不写回、不生成汇兑损益、不改 reports、不逐项分汇率**。
- **参考汇率存储（策略，P3-0 不实现）**：
  - 未来用 **settings 键**（如 `fx_reference_rates`，JSON `{ "USD": 7.2, "JPY": 0.05, ... }` 相对本位币），**无 migration、不新建表**。
  - 缺某币种汇率 → 该币种**跳过折算 + 参考合计备注**「未提供汇率，未折算」。
  - 本位币自身汇率视为 1。
- **P3-3 范围**：先 `GET /api/fx-reference-conversion`（或扩 balanceOverview 返回一个**可选参考合计块**）+ api 类型 + test-handlers；**不接 UI**（拍板 4）。参考汇率录入 UI、概览展示 = 更后续，单独评估。

### F.5 汇兑损益必须后置

- 汇兑损益入当期损益（财务费用），**碰 P&L / reports / 会计分录** → **完全在 P3 之外**，需单独确认后另立模块。
- 单主体小微基本用不到 OCI（外币报表折算差额）路径。

---

## G. 子 PR 拆分（风险低→高）

| 子 PR | 目标 | 类型 | 风险 | 人工预览 |
|---|---|---|---|---|
| **P3-0**（本文） | P3 总实施文档（K-6 + K-10 + 拆分 + 禁止范围；P3-2 已并入） | docs-only | 🟢 | 否 |
| **P3-1** | 所得税同税种同期间对冲只读 preview（`GET /api/income-tax-position`）；VAT/销售税维持备查 | handler-only | 🟡 | 可选（无 UI） |
| **P3-3** | 参考折算只读 preview（`GET /api/fx-reference-conversion`，用户汇率·仅供参考·不写回·无汇兑损益） | handler-only | 🟡 | 否（不接 UI） |
| **P3-4** | 所得税对冲接入 balanceOverview（仅 income_tax·净额→流动负债「应交税费」/流动资产「预缴税款」）；VAT/销售税仍 excludedNotes 备查 | overview + UI | 🟠 | **是** |

> 推荐顺序：`P3-0` → `P3-1` → `P3-3` → `P3-4`。每子 PR 一关注点、先给 diff + 验证、默认不 commit、永不 merge（由用户决定）。

### 各子 PR 涉及文件（预估）
- **P3-1**：`electron/handlers/incomeTaxPosition.js`(新)、`router.js`、`services/api.ts`、`scripts/test-handlers.mjs`。
- **P3-3**：`electron/handlers/fxReference.js`(新)、`router.js`、`settings.js`(白名单 +`fx_reference_rates`)、`services/api.ts`、`scripts/test-handlers.mjs`。
- **P3-4**：`electron/handlers/balanceOverview.js`、`components/FinancePage.tsx`、`services/api.ts`、`i18n/locales/*.json`(×6)、`scripts/test-handlers.mjs`、`e2e/locale-matrix.spec.ts`。

---

## H. 明确禁止范围（P3 全程）

不做法定申报 · 不做正式税务计算 · 不做真实 VAT 进项抵扣 · **不把 tax_payments 自动冲减应交税费（除非同税种同期间且作为 preview）** · 不生成税费分录 · 不生成汇兑损益分录 · 不改历史交易 · **不改 `electron/reports/*`** · 不做多币种强制折算 · 不隐藏管理口径免责声明 · 不移除平衡差额 / 待调整 · 不做完整 VAT 销项−进项模块（后置）· 不做汇兑损益（后置）· 不在 P3-0 实现任何 settings/UI（仅定策略）。

---

## I. 待用户拍板点（P3-1 启动前）

1. **所得税「同期间」匹配口径**：优先 `period_start/period_end` 重叠、回退 `payment_date`（§C.3）——是否认可。
2. **P3-1 是否独立 handler 不接概览**（P3-4 才接）——延续 P1/P2「后端先行」节奏。
3. **参考汇率存储**：P3-3 启动时用 settings `fx_reference_rates`（无 migration）——是否认可，或暂不做 fx。
4. **P3-4 是否做**（所得税接入概览改显示数字、需人工预览）——或仅停在 P3-1 preview。

> 以上在对应子 PR 启动前确认即可；不阻塞 P3-0。
