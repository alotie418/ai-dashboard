# PR-7B P2：固定资产折旧（K-5）+ 留存收益结转（K-9）· 实施文档（P2-0）

> 状态：**只读实施文档（P2-0）**。本文不实现任何功能、不改 schema/handlers/UI/i18n/reports。
> 依据：`docs/PR7B_ACCOUNTANT_RESPONSE.md`（会计师确认书）§一 P2，及 `docs/PR7B_P1_PLAN.md`。
> 适用前提：本工具定位为「经营管理估算」，**非法定报税/审计系统**。盘点时点：main `b6311c6`（PR-7B P1 全完成后，schema v18）。
> 本文是 P2-1~P2-4 子 PR 的实施依据。

---

## A. P2 范围与定位

P2 目标（会计师 §一 P2）：**让管理口径资产负债概览更可信**——固定资产显**净值**、权益显**未分配利润**，使 `balanceDifference`（平衡差额／待调整）**收敛**。

**总原则（延续 P1）：read-only preview，不写回。**
- 折旧/结转**只算不写**：不写回 `fixed_assets` 累计折旧、不写回 `equity` 未分配利润、不改历史交易、不生成会计分录。
- **仍不强制平衡、差额行不隐藏**：P2 让差额收敛，但概览仍是管理口径，差额始终显式可见。
- 两项例外**默认都不动**，需用户单独确认才做：① 写回固定资产/权益数据；② 修改 `electron/reports/*`。

**已拍板（用户确认）：**
1. K-5 用 `useful_life_months` 存月数；UI 可按「年」输入转月。
2. K-5 残值先只做 `salvage_rate`，不加 `salvage_value`（避免两套残值口径）。
3. K-5 `depreciation_method` 默认 `straight_line`。
4. K-5 `depreciation_start_policy` 默认 `next_month`。
5. K-5 disposed：preview 中 `status='disposed'` 且有 `disposal_date` 时，**处置次月停止计提**；**P2 不做处置损益、不进 P&L**。
6. P2-4 拆成 P2-4a（留存 preview）+ P2-4b（概览权益两行）。
7. K-9 的 `entity_type`、`opening_retained_earnings`、分红类型 **不在 P2-0 拍死**，作为 **P2-4 前置决策点**（见 §K）。

---

## B. K-5 固定资产直线法折旧字段设计（P2-1）

在 `fixed_assets` 新增以下字段，**全部 nullable · additive · 不回填 · 不改现有列**（`original_value` 等原始登记台账保持原样）：

| 字段 | 类型 | 说明 |
|---|---|---|
| `depreciation_method` | TEXT DEFAULT `'straight_line'` CHECK IN (`'straight_line'`) | P2 **仅直线法**；加速法（双倍余额递减/年数总和）留后续高级选项 |
| `useful_life_months` | INTEGER（nullable） | 预计使用月数；**空 → 按类别/制度默认**。UI 按「年」输入，存月数 = 年 × 12 |
| `salvage_rate` | REAL（nullable） | 残值率（如 0.05）；空 → 类别默认。**不新增 salvage_value**（拍板2） |
| `depreciation_start_policy` | TEXT DEFAULT `'next_month'` CHECK IN (`'next_month'`,`'same_month'`,`'daily'`) | 默认**次月起**（拍板4）；提供三选项 |
| `disposal_date` | TEXT（nullable） | 处置日；`status='disposed'` 时用于「处置次月停止」+ 净值。**处置损益(P&L)不在 P2** |

- 新字段为**用户可逐项覆盖**的折旧参数；为空时 preview 回退到类别/制度默认常量（§C）。
- **不影响原始台账**：迁移仅 ADD COLUMN（幂等、不回填）；preview 在内存计算、**绝不 UPDATE fixed_assets**。

---

## C. 默认年限 / 残值率口径（会计师确认，P2-1 随字段落地为常量）

按**资产类别**的直线法建议默认（会计师确认书 K-5(2)）：

| 资产类别 | 直线法建议年限 | 残值率建议 |
|---|---|---|
| 房屋/建筑物 | 20 年 | 0–5% |
| 机器/生产设备 | 10 年 | 5% |
| 运输工具（车辆） | 4 年 | 5% |
| 电子设备 | 3 年 | 0–5% |
| 器具/家具 | 5 年 | 5% |

**制度差异（属制度，按 accountingLocale 预置默认，用户可逐项改）：**
- **中国**：上述年限对应《企业所得税法实施条例》第 60 条；残值率企业合理确定（惯例 5%）。
- **美国**：账面按经济年限估计（电子 3–5 年、车辆 5 年、设备 7 年、商用房 39 年）；税务另有 MACRS。
- **日本**：法定耐用年数表，2007 年后折旧至残存簿価 1 円（残值率近似 0）。
- **IFRS 系（欧/韩/台）**：按预计可使用年限自行估计，无法定强制表（台湾税务另有耐用年数表）。

> 落地方式：`components/depreciationDefaults.ts` 常量（类别 × 制度 → 默认年限/残值率）+ `scripts/check-deprec-defaults.mjs` 守卫（仿 P1-1 `accountingClassification` + `check-balance-classify`）。preview 在字段为空时回退此默认。法定/税务年限以当地税法为准，工具允许覆盖。
> 最小版（会计师 K-5 简化建议）：直线法 + 单类别默认年限 + 按月 + 残值率统一 5%（或 0）。

---

## D. 折旧起算规则

- 默认 `next_month`：**购置投入使用月份的次月开始**，每月计提。
- `same_month`：当月开始。
- `daily`：按天（高级选项）。
- **处置次月停止**：`status='disposed'` 且有 `disposal_date` → 计提到处置月、**次月停止**（拍板5）。

---

## E. disposed 处理规则（P2 范围内）

- preview 中 `status='disposed'` 且有 `disposal_date`：**处置次月停止计提**；该资产**净值不计入固定资产净值合计**（视作已处置）。
- **处置损益（处置收入 − 账面净值 − 相关税费 → 当期损益）= 不在 P2**（碰 P&L/reports，需单独确认后置）。

---

## F. 折旧 preview 公式（P2-2，只读）

```
可折旧额      = original_value × (1 − salvage_rate)
月折旧        = 可折旧额 / useful_life_months
起算月        = acquisition_date 按 depreciation_start_policy 调整（next_month=次月）
计提月数      = clamp(起算月 → asOf 的整月数, 0, useful_life_months)
累计折旧      = min(计提月数 × 月折旧, 可折旧额)        // 不超过可折旧额
净值          = original_value − 累计折旧               // 不低于残值
```
- `asOf` = 概览基准日（= period.to，与 P1-3 一致）。
- 字段为空 → 用 §C 类别/制度默认。
- disposed（有 disposal_date）→ 计提到处置月、净值不计入合计。
- **只读**：`GET /api/depreciation-preview?asOf=` 返回每资产 `{ original, accumulated, netValue }` + 按币种汇总 + `estimate:true`；**绝不写回** `fixed_assets`。

---

## G. K-5 子 PR 拆分

| 子 PR | 目标 | 可做 | 禁止 | 涉及文件 | 风险 | 人工预览 |
|---|---|---|---|---|---|---|
| **P2-1** 折旧字段 + 默认常量 | `fixed_assets` 加 5 nullable 字段 + 默认常量 + 守卫 + UI 录入 | 迁移 vN（additive·幂等·不回填）/ handler 收返字段 / `depreciationDefaults.ts` + 守卫 / FixedAssetsSection 表单 + i18n | 任何折旧**计算**、写回、改原值/现有列、碰 reports/概览 | `db/index.js`、`fixedAssets.js`、`FixedAssetsSection.tsx`、`depreciationDefaults.ts`、`check-deprec-defaults.mjs`、`package.json`、`i18n/*`、`test-migrations.mjs`、`test-handlers.mjs` | 🟡 低-中 | 建议 |
| **P2-2** 折旧 preview | `GET /api/depreciation-preview` 算净值/累计折旧 | 新只读 handler + 路由 + api 类型 + 测试；空字段回退默认；disposed 处理 | 写回 fixed_assets、处置损益进 P&L、改 reports/概览 | `depreciationPreview.js`、`router.js`、`services/api.ts`、`test-handlers.mjs` | 🟡 中 | 可选 |
| **P2-3** 概览接净值 | balanceOverview 的 fixedAssets 行用**净值**（复用 P2-2） | 改 `balanceOverview.js`（取净值）/ FinancePage 显示 / 测试 / e2e / i18n(可选「累计折旧」) | 写回、强制平衡、隐藏差额、改 reports | `balanceOverview.js`、`FinancePage.tsx`、`i18n/*`(可选)、`test-handlers.mjs`、`e2e/*` | 🟠 中-高 | **是** |

---

## H. K-9 留存收益 / 未分配利润公式

```
期末未分配利润 = 期初未分配利润 + 本期净利润 − 本期分红/利润分配 (− 提取盈余公积，仅中国/法定准备金制度；P2 暂不做)
```
- **本期净利润来源**：复用现有 P&L 的 `incomeStatement.netProfit`（read-only 调用/require 报表，**不改 `electron/reports/*`**）。
- **结转时点**：管理上**月度累计展示** + **年度结转**；P2 仅**显示本年累计利润 + 期末未分配利润估算**，**不自动年结、不写回 equity、不改历史**。

---

## I. 公司 vs 个体/独资差异

| 主体 | 权益两行 | 支取/分红 | 准备金 |
|---|---|---|---|
| **公司** | 实收资本 + 未分配利润 | 分红减未分配利润 | 资本公积/盈余公积仅高级选项，**P2 不做** |
| **个体/独资** | 业主资本 + 未分配利润 | **业主支取**（`equity_type='owner_draw'`）**直接冲减业主资本**，不走分红 | 彻底隐藏准备金 |

- **默认两行权益**：出资 + 未分配利润；细分（资本公积/盈余公积）P2 不做。
- 区分主体需 `entity_type`（company/individual）—— 见 §K 前置决策点。

---

## J. K-9 子 PR 拆分

| 子 PR | 目标 | 可做 | 禁止 | 涉及文件 | 风险 | 人工预览 |
|---|---|---|---|---|---|---|
| **P2-4a** 留存 preview | `GET /api/retained-earnings-preview?year`：期初 + 本期净利 − 分红 | 新只读 handler（复用报表 netProfit + 读 settings 期初/entity_type + equity 台账）；api 类型；测试；新增 settings 键（key/value，无 migration） | 写回 equity、自动年结、改历史、盈余公积细分、改 reports | `retainedEarningsPreview.js`、`router.js`、`services/api.ts`、`settings.js`(白名单)、`test-handlers.mjs` | 🔴 高 | 可选 |
| **P2-4b** 概览权益两行 | balanceOverview 权益拆**两行**（出资 + 未分配利润，复用 P2-4a） | 改 `balanceOverview.js`（equity 两行）/ FinancePage 渲染 / i18n（复用 balanceCapital/balanceRetained，已有）/ 测试 / e2e | 写回、强制平衡、隐藏差额、准备金细分、改 reports | `balanceOverview.js`、`FinancePage.tsx`、`test-handlers.mjs`、`e2e/*` | 🔴 高 | **是** |

---

## K. K-9 前置决策点（P2-4 启动前需用户拍板）

1. **`entity_type`（公司/个体）存储与默认**：建议新增 settings 键 `entity_type ∈ {company, individual}`，默认值待定。
2. **`opening_retained_earnings`（期初未分配利润）存储**：建议新增 settings 键（建账录入单一数值，最简，不改 schema）；备选：扩 `equity_type` 加 `retained_opening`。
3. **分红 / 利润分配类型**：P2 暂用 `equity_type='owner_draw'`/`adjustment` 近似；是否新增 `dividend` 类型 → 后置细分。

> 以上在 P2-4a/4b 启动前确认即可；不阻塞 P2-1/2/3。

---

## L. 明确禁止范围（P2 全程）

不做法定资产负债表、不做严格平衡、**不隐藏平衡差额**、不做税费抵扣/对冲、不做多币种折算、不做复式总账、不修改历史交易、不自动生成会计分录、**不自动写回固定资产/权益数据（除非单独确认）**、**不修改 `electron/reports/*`（除非后续单独确认）**。

---

## M. 推荐顺序

`P2-0`（本文）→ `P2-1`（折旧字段）→ `P2-2`（折旧 preview）→ `P2-3`（概览接净值）→ **拿 §K 决策** → `P2-4a`（留存 preview）→ `P2-4b`（权益两行）。

每子 PR 仍按既定节奏：先方案/直接实现按用户指令；P2-3、P2-4b 需人工预览验收（改变概览展示数字）。
