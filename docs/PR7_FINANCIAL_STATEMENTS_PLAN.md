# PR-7 资产负债表 / 现金流量表：现状盘点与实现方案

> 状态：**只读盘点文档**（PR-7A）。本文不实现任何报表、不改 schema、不改业务代码。
> 所有「会计准则口径」未定项一律标记 **[需会计确认]**，不在文档中自行发明。
> 证据均给出 `文件:行` 或 `表.列`。盘点时点：main `6867c64` 之后。

---

## A. 当前现状结论

1. **利润表（P&L / 经营损益概览）已实现**：六制度报表引擎 `electron/reports/{cn,us,jp,eu,kr,tw}.js`，经 `reports/index.js` 聚合，产出 `incomeStatement` + `vatSummary`（CN）/ Schedule C（US）等。
2. **资产负债表 = 占位**：`components/FinancePage.tsx:329-340` 为 “coming soon / not enabled yet” 空态（`finance.balanceComingSoonTitle/Desc` + `comingSoonBadge`）。报表引擎**不产出**任何 balance-sheet 数据块。
3. **现金流量表 = 占位**：`components/FinancePage.tsx:342-349` 同为 coming-soon 空态（`finance.cashflowTitle/Desc`）。引擎不产出 cash-flow 数据块。
4. **数据层**：核心交易数据齐全（采购/销售/收支 + 类别），且 **已含实际收付款日期 `payment_date` 与 `paid_amount`**；但**完全缺少**资产负债表与完整现金流量表所需的「账户 / 余额 / 权益 / 负债 / 固定资产 / 折旧台账 / 税款缴纳」数据模型。
5. **结论**：
   - **现金流量表**：可做「经营活动现金流（收付实现制 · 管理口径）」**MVP**（数据已足够），投资/筹资活动暂缺数据。**[需会计确认]** 列报格式（直接法/间接法、分类）。
   - **资产负债表**：**当前数据不足以编制**。强行用「应收+应付+存货」拼一张表会**不平衡**（缺现金、权益、负债、固定资产），违反产品边界（不得把不完整模块当正式报表展示）。须先补数据模型（PR-7D）再做。

---

## B. 资产负债表实现所需数据

完整资产负债表 = 资产 = 负债 + 所有者权益。逐项对照：

| 项目 | 需要的数据 | 现状 |
|------|-----------|------|
| 货币资金（现金/银行） | 现金/银行账户表 + 期初余额 + 收付流水 | ❌ 无账户表、无期初余额 |
| 应收账款 | 未收销售（totalAmount − paid_amount） | ✅ 有（`sales` / `receivables.js`） |
| 存货 | 在库数量 × 加权平均成本 | ✅ 有（`inventory.js` / `products.default_unit_cost`） |
| 预付/其他流动资产 | 预付款记录 | ❌ 无 |
| 固定资产（原值/净值） | 固定资产台账 + 累计折旧 | ❌ 无台账（仅有「折旧」费用类别 + US home-office 字段） |
| 应付账款 | 未付采购（totalAmount − paid_amount） | ✅ 有（`purchases` / `payables.js`） |
| 应交税费 | 应交增值税 / 待缴税款 + 已缴记录 | ⚠️ 可估（`vatSummary.estimatedPayable`），但**无已缴税款台账** |
| 短期/长期借款 | 负债/贷款表 | ❌ 无 |
| 实收资本 / 未分配利润 / 所有者权益 | 权益科目 + 期初 + 本期净利结转 | ❌ 无（仅有**死 i18n key** 实收资本/未分配利润，无数据；见 sololedger-accounting-professionalization 记忆 balanceSheetLockIn） |
| 期初余额（所有科目） | 建账期初数 | ❌ 无 |

→ **资产侧可凑齐：应收、存货；负债侧可凑齐：应付**。其余（现金、固定资产、权益、借款、期初）**全缺** → 无法平衡，**不能成表**。**[需会计确认]** 科目体系与建账口径。

---

## C. 现金流量表实现所需数据

| 活动 | 需要的数据 | 现状 |
|------|-----------|------|
| 经营活动现金流入 | 销售实际收款（按 `payment_date`、`paid_amount`） + income 类 transactions 实收 | ✅ 有（`sales.payment_date/paid_amount`、`transactions.payment_date/type='income'`） |
| 经营活动现金流出 | 采购实际付款 + expense 类 transactions 实付 | ✅ 有（`purchases.payment_date/paid_amount`、`transactions` expense） |
| 投资活动（购建/处置固定资产） | 固定资产台账 | ❌ 无 |
| 筹资活动（借款/还款/注资/分红） | 负债/权益表 | ❌ 无 |
| 期初/期末现金 | 现金账户期初余额 | ❌ 无 |
| 间接法调整（净利→经营现金流） | 折旧、营运资本变动等 | ⚠️ 部分（净利有；折旧台账无） |

→ **经营活动现金流（直接法、收付实现制）可由 `payment_date` + `paid_amount` 直接汇总** → 可做 MVP（管理口径）。投资/筹资/期初期末现金缺数据。**[需会计确认]** 直接法 vs 间接法、活动分类、是否要求期初期末勾稽。

---

## D. 当前项目已有字段（证据：`electron/db/index.js`）

**purchases**（`:68-85`）：`date, supplier, tons, pricePerTon, totalAmount, amountWithoutTax, taxAmount, taxRate, invoiceNumber, invoiceStatus, payment_status, paid_amount, due_date, payment_date, created_at, product_id, *_snapshot`

**sales**（`:86-104`）：同上 + `shippingCost`、`customer`

**transactions**（收支记录，`:224-247`）：`type(income/expense), date, amount, amount_net, tax_amount, tax_rate, currency, category_id, counterparty, invoice_no, invoice_status, payment_status, paid_amount, payment_date, due_date, description, attachment_path, source_meta`

**categories**（`:169-188` + v13 `:464-467`）：`locale, type, slug, schedule_line, is_deductible, deductible_pct, is_cogs, parent_id, labels(6语言)`

**products**（`:342-352`）：`name, unit, default_unit_cost, is_service, is_active`

**home_office**（`:282-` 含 `annual_depreciation, annual_rent, annual_utilities, annual_insurance`）、**mileage_logs**（里程抵扣）—— 仅服务 US 税务抵扣，**非通用固定资产/折旧台账**。

**settings**（`:105-109`）：key/value（accounting_locale、税率、company_info、product_unit 等）——**可承载未来「账户/期初余额」配置但当前无相关键**。

**报表引擎可见数据**（`reports/index.js:37-69`）：本期 `transactions`（优先）或 `sales/purchases`（fallback）映射的 income/expense 行 + `categories` + settings 税率参数。

→ **够算：利润表 ✅、应收应付账龄 ✅、库存成本 ✅。**

---

## E. 当前项目缺失字段（编制完整两表的硬缺口）

| 缺失 | 影响报表 | 备注 |
|------|---------|------|
| 现金/银行账户表 | 资产负债表 + 现金流期初期末 | 无任何账户实体 |
| 期初余额（各科目） | 两表 | 无建账期初 |
| 所有者权益 / 实收资本 / 未分配利润（数据） | 资产负债表 | 仅死 i18n key |
| 短期/长期借款、其他负债 | 资产负债表 + 筹资现金流 | 无 |
| 固定资产台账（原值/净值） | 资产负债表 + 投资现金流 | 无（仅折旧费用类别） |
| 折旧计提台账（按资产、按期） | 资产负债表 + 间接法现金流 | 无通用折旧引擎 |
| 已缴税款台账 | 应交税费余额 | 仅有应交估算，无缴纳记录 |
| 预付/预收、其他往来 | 资产负债表 | 无 |

**核验命令证据**：`grep -rniE "fixed_asset|bank_account|owner_equity|opening_balance|liabilit|loan|balance_sheet" electron/` → 仅命中 home-office 的 `annual_depreciation` 与折旧**费用类别**，**无资产/账户/权益/负债/期初表**。

---

## F. 可以先实现的最小可用版本（MVP）

### F1. 现金流量表 MVP（推荐 · 可独立落地）
- **口径**：经营活动现金流，**直接法 + 收付实现制**，数据来自 `payment_date` 落在期间内的实收/实付（`sales`/`purchases`/`transactions` 的 `paid_amount`）。
- **展示**：仅「经营活动」分节；投资/筹资分节显示「未配置 / 不适用」中性空态，**不伪造**。
- **定位**：明确标注「**管理口径 · 估算 · 非法定现金流量表**」（复用现有免责声明体系 `disclaimer.report`）。
- **不做**：期初/期末现金勾稽（缺账户余额）、间接法。
- **[需会计确认]**：直接法分类、是否允许「仅经营活动」对外呈现。

### F2. 资产负债表 MVP（**不推荐贸然做**）
- 仅「应收 + 应付 + 存货」三项可填，**资产≠负债+权益**必然不平衡 → 作为「资产负债表」展示会误导。
- **替代**：保持现 coming-soon；或先做 PR-7D 补数据模型后再做完整表。
- 若坚持要给用户「部分快照」，只能叫「**部分往来与存货管理快照**」且明确**非资产负债表**、不声称平衡。**[需会计确认]**。

---

## G. 不能贸然实现的部分

1. **完整资产负债表**：缺现金/权益/负债/固定资产/期初 → 无法平衡，**禁止**当正式报表展示。
2. **间接法现金流量表**：缺折旧台账与营运资本明细。
3. **投资 / 筹资活动现金流**：缺固定资产与负债/权益交易。
4. **期初期末现金勾稽**：缺现金账户期初余额。
5. **任何"应交/已缴税费"作为负债余额**：仅有应交估算，无缴纳台账，会重复/错配。
6. 以上任何一项的**准则口径映射**（CN 企业会计准则 / US GAAP Sch C 之外的 B/S / JP 決算書 / EU / KR / TW）= **[需会计确认]**，不得自行发明。

---

## H. CN / US / JP / EU / KR / TW 口径风险

| 制度 | 利润表 | 现金流 MVP（经营/直接法） | 资产负债表 |
|------|--------|--------------------------|-----------|
| CN | ✅ 已实现 | ⚠️ 数据够，**[需会计确认]** 企业会计准则现金流量表格式 | ❌ 缺数据模型；科目体系 **[需会计确认]** |
| US | ✅ Schedule C | ⚠️ Schedule C 是**收付实现制利润表**，本身不含 B/S；现金流非个人 Sch C 必需 **[需会计确认]** | ❌ 个人独资通常无正式 B/S；**[需会计确认]** 是否需要 |
| JP | ✅ 損益 | ⚠️ **[需会计确认]** 決算書/キャッシュ・フロー計算書格式 | ❌ 貸借対照表科目 **[需会计确认]** |
| EU | ✅ | ⚠️ 各成员国差异大 **[需会计确认]** | ❌ **[需会计确认]** |
| KR | ✅ | ⚠️ **[需会计确认]** | ❌ 재무상태표 **[需会计确认]** |
| TW | ✅ | ⚠️ **[需会计确认]** | ❌ 資產負債表 **[需会计确认]** |
| 共性 | — | 仅经营活动可由现有数据支撑；其余全缺 | 六制度均缺账户/权益/负债/固定资产数据，**无一可直接成表** |

> 关键：**当前字段不足以为任何一个制度编制完整、合规的资产负债表**；现金流仅能做「经营活动管理口径」MVP。所有对外合规呈现均 **[需会计确认]**。

---

## I. 推荐 PR 拆分

| PR | 目标 | 前置依赖 | 风险 |
|----|------|---------|------|
| **PR-7B 资产负债表 MVP** | **暂缓** —— 数据不足，须等 PR-7D。若要先出「往来+存货快照」必须改名、不声称平衡 | PR-7D | 高（误导风险，**[需会计确认]**） |
| **PR-7C 现金流量表 MVP** | 经营活动现金流（直接法·收付实现制·管理口径），投资/筹资留空态 | 无（数据已足） | 中（口径 **[需会计确认]**，但数据真实、可免责标注） |
| **PR-7D 数据字段补齐** | 新增 现金/银行账户、期初余额、固定资产台账+折旧、负债/借款、权益科目、已缴税款台账（schema migration + handler + UI） | 会计确认科目体系 | 高（schema/迁移/会计口径，**[需会计确认]**，大工程） |
| **PR-7E 测试与验收** | 报表引擎单测 + e2e + 人工对账验收 | PR-7C/7D | 中 |

**推荐顺序**：先 **PR-7C**（唯一现在可安全交付、数据真实），再 **PR-7D**（补数据模型，需会计师），最后 **PR-7B**（完整资产负债表，依赖 7D）→ **PR-7E**（验收）。

---

## J. 各后续 PR 的范围 / 禁止 / 验证 / 人工验收

### PR-7C 现金流量表 MVP（经营活动 · 直接法）
- **修改范围**：`electron/reports/*`（新增 cashflow 数据块：按 `payment_date` 汇总实收实付）、`reports/index.js`（ctx 加 cash 行）、`components/FinancePage.tsx`（cashflow tab 渲染真实数据，保留免责）、i18n（现金流相关 key）、`scripts/`（新增 `check:cashflow` 或扩 `test-report-*`）。
- **禁止修改**：schema/migrations、采购/销售/库存/税额/利润计算、resolveReportSource 的 P&L 路径、Electron/IPC、AI/OCR、打包；**不得**新增「投资/筹资」假数据。
- **验证**：`npm run check:all && npm run typecheck && npm run build && npm run test:locale-ui`（+ 新增 cashflow 单测）。
- **人工验收**：是 —— 6 语言×相关制度下现金流 tab 截图；用一组已知收付款记录人工核对「经营净现金流 = Σ实收 − Σ实付」。**[需会计确认]** 列报。

### PR-7D 数据字段补齐（schema）
- **修改范围**：`electron/db/index.js`（新增账户/期初/固定资产/折旧/负债/权益/税款台账表 + migration）、对应 handlers、设置/建账 UI、i18n。
- **禁止修改**：现有利润表/账龄/库存计算口径；既有表的会计语义列；不得在无会计确认下写死任何准则科目。
- **验证**：`npm run check:migrations && npm run check:handlers && npm run check:all && npm run typecheck && npm run build`（迁移幂等 + 往返测试）。
- **人工验收**：是 —— 建账期初录入流程；迁移幂等（旧库升级不丢数据）。**[需会计确认]** 全部科目体系。

### PR-7B 资产负债表（完整，依赖 7D）
- **修改范围**：`electron/reports/*` 新增 balanceSheet 数据块、`FinancePage.tsx` balance tab、i18n。
- **禁止修改**：schema（应在 7D 完成）、P&L/现金流计算；**不得**展示不平衡的表。
- **验证**：同上 + 平衡校验断言（资产 = 负债 + 权益，差额=0 才渲染，否则报错/空态）。
- **人工验收**：是 —— 平衡性、6 制度科目映射。**[需会计确认]** 全程。

### PR-7E 测试与验收
- **修改范围**：仅 `scripts/`、`e2e/`、docs。
- **禁止修改**：业务/报表计算。
- **验证**：全量 `check:all` + `test:locale-ui` + `test:electron`。
- **人工验收**：是 —— 端到端对账。

---

## K. 必须由会计师确认的点（清单）

1. CN 企业会计准则 **现金流量表** 标准格式（直接法/间接法、活动分类）。
2. 「经营活动现金流（管理口径）」能否对外呈现，及其免责措辞边界。
3. **资产负债表科目体系**（六制度各自）：货币资金、应收、存货、固定资产、应付、应交税费、借款、实收资本、未分配利润……
4. **建账期初余额** 的录入与勾稽规则。
5. **固定资产/折旧** 的计提方法（直线/加速）、残值、年限（各制度差异）。
6. **应交/已缴税费** 在资产负债表的列示与现金流的分类。
7. US：个人独资是否需要正式 B/S 与现金流量表（通常仅 Schedule C）。
8. JP/EU/KR/TW：決算書 / 재무상태표 / 資產負債表 的法定格式与科目。
9. 净利 → 未分配利润 的**跨期结转**规则。
10. 多币种（`transactions.currency`）在两表中的折算口径（如适用）。

> 在以上各项获得会计确认前，PR-7B / PR-7D 不应落地；PR-7C 可在「管理口径 + 免责声明 + 仅经营活动」前提下先行，但其法定列报仍待第 1/2 项确认。
