# SoloLedger 国际化数据模型重构计划

> 本文档是 SoloLedger 从「中国 VAT 体系单一产品」演进为「多国会计制度通用账本」的实施规划。
> 目标读者：未来的 me / claude / 协作者。
> 工作量评估：**1-2 个月**净开发时间（不含会计师审计 / 法律合规 / TestFlight 反馈迭代）。

---

## 1. 背景与决策

### 1.1 现状问题

`feat/internationalization` 分支前，SoloLedger v0.1.0 的数据模型与中国增值税深度耦合：

| 维度 | 现状 | 美国 / 欧美 SaaS 现实 |
|---|---|---|
| 实体 | `sales` / `purchases` 两张表 | `transactions` 单表 + `type=income/expense` |
| 度量单位 | `tons` / `pricePerTon`（吨 / 元每吨） | 不存在；按 invoice 项目数量 + unit price |
| 税务模型 | 销项税 − 进项税 = 应纳 VAT；附加 12% | Sales Tax 不可抵扣；Income Tax 按净利计 |
| 报表科目 | 营业收入 / 营业成本 / 营业税金及附加 | Schedule C: Gross Receipts / COGS / Advertising / Car / Insurance / Legal / Office / Rent / Utilities / Meals(50%)... |
| 分类 | 无 categories 概念 | 强类别记账（QuickBooks 主卖点） |

仅靠「换数字」（v0.1.0 的会计预设系统）不能解决——必须重构数据结构。

### 1.2 不做选项

- ❌ **另开 repo 走双产品路线**：单人团队同步成本太高，bug 双修；定位「一人公司」目标客户重叠度 90%，无需双 SKU
- ❌ **完整 GAAP / IFRS 实现**：超出工程范围，需要 CPA 全程参与；竞品 QuickBooks 投入数百人年才达到
- ❌ **保持中国版 + i18n 外壳**：天花板太低，错失全球市场（QuickBooks Self-Employed 仅美国就 100 万付费用户）

### 1.3 选定路径

**重构数据模型**，但**复用 v0.1.0 已建好的基础设施**（Electron / SQLite / IPC / BYOK / i18n / 会计预设）。
新旧数据双轨并存一段时间，提供迁移工具。

---

## 2. 新数据模型设计

### 2.1 ER 图（核心 4 张表）

```
┌─────────────────────┐         ┌─────────────────────┐
│  accounting_locale  │◄────────│  categories         │
│  (settings 表里)    │         │  ─────────────────  │
│  CN/US/JP/EU/KR/TW  │         │  id (uuid)          │
└─────────────────────┘         │  locale (CN/US/...) │
                                │  type (income|exp)  │
                                │  key (slug)         │
                                │  label_zh / en / .. │
                                │  schedule_c_line ?  │
                                │  is_deductible ?    │
                                │  deductible_pct     │
                                │  parent_id ?        │ ── 树状（如 Auto → Mileage / Fuel）
                                │  sort_order         │
                                │  is_system          │ ── 系统类别不可删
                                │  created_at         │
                                └─────────┬───────────┘
                                          │
                                          │ N:1
                                          ▼
                                ┌─────────────────────┐
                                │  transactions       │
                                │  ─────────────────  │
                                │  id (uuid)          │
                                │  type (income|exp)  │
                                │  date               │
                                │  amount (含税 / 总额)│
                                │  amount_net ?       │ ── 不含税额（US 可空）
                                │  tax_amount ?       │ ── 税额（US 可空）
                                │  tax_rate ?         │
                                │  currency           │
                                │  category_id (FK)   │
                                │  counterparty       │ ── 客户 / 供应商 / 雇主
                                │  invoice_no ?       │
                                │  invoice_status     │ ── 已开 / 待开 / N/A
                                │  payment_status     │ ── paid / partial / unpaid
                                │  paid_amount        │
                                │  payment_date ?     │
                                │  due_date ?         │
                                │  description ?      │
                                │  attachment_path ?  │ ── 发票图扫描存储
                                │  source_meta json   │ ── OCR 原始字段保留
                                │  created_at         │
                                │  updated_at         │
                                └─────────────────────┘

┌─────────────────────┐         ┌─────────────────────┐
│  tax_payments       │         │  legacy_migrations  │
│  ─────────────────  │         │  ─────────────────  │
│  id (uuid)          │         │  legacy_table       │ ── 'sales' / 'purchases'
│  type               │         │  legacy_id          │
│  period             │ ── 季度 / 月度  │  new_id (txn id)   │
│  amount             │         │  migrated_at        │
│  due_date           │         └─────────────────────┘
│  paid_date ?        │
│  paid_amount        │
│  notes              │
└─────────────────────┘
```

### 2.2 categories 表（核心新增）

```sql
CREATE TABLE categories (
  id TEXT PRIMARY KEY,                  -- 'us-expense-meals' / 'cn-income-sales'
  locale TEXT NOT NULL,                 -- 'CN' | 'US' | 'JP' | 'EU' | 'KR' | 'TW'
  type TEXT NOT NULL,                   -- 'income' | 'expense'
  slug TEXT NOT NULL,                   -- 'meals' / 'sales-revenue'
  label_zh_cn TEXT NOT NULL,
  label_zh_tw TEXT,
  label_en TEXT NOT NULL,
  label_ja TEXT,
  label_ko TEXT,
  label_fr TEXT,
  schedule_line TEXT,                   -- 'Schedule C Line 24a' / '损益表-营业收入'
  is_deductible INTEGER DEFAULT 1,      -- 是否可税前扣除
  deductible_pct REAL DEFAULT 100,      -- 扣除比例（如 Meals 50%）
  parent_id TEXT,                       -- 树状层级
  sort_order INTEGER DEFAULT 0,
  is_system INTEGER DEFAULT 1,          -- 系统预置 vs 用户自建
  created_at TEXT DEFAULT (datetime('now')),
  UNIQUE(locale, type, slug)
);

CREATE INDEX idx_categories_locale_type ON categories(locale, type);
```

### 2.3 transactions 表（替代 sales + purchases）

```sql
CREATE TABLE transactions (
  id TEXT PRIMARY KEY,
  type TEXT NOT NULL CHECK (type IN ('income', 'expense')),
  date TEXT NOT NULL,
  amount REAL NOT NULL,                 -- 总额（含税）
  amount_net REAL,                      -- 不含税（仅 VAT 国家有意义）
  tax_amount REAL DEFAULT 0,
  tax_rate REAL DEFAULT 0,
  currency TEXT NOT NULL DEFAULT 'USD',
  category_id TEXT REFERENCES categories(id),
  counterparty TEXT,                    -- 客户名 / 供应商名 / payer
  invoice_no TEXT,
  invoice_status TEXT DEFAULT 'n/a',    -- 'issued' | 'pending' | 'n/a'
  payment_status TEXT DEFAULT 'paid',   -- 'paid' | 'partial' | 'unpaid'
  paid_amount REAL DEFAULT 0,
  payment_date TEXT,
  due_date TEXT,
  description TEXT,
  attachment_path TEXT,                 -- 沙盒下 /Library/.../attachments/{id}.{ext}
  source_meta TEXT,                     -- JSON: OCR 原始字段、导入来源等
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now'))
);

CREATE INDEX idx_txn_date ON transactions(date);
CREATE INDEX idx_txn_type_date ON transactions(type, date);
CREATE INDEX idx_txn_category ON transactions(category_id);
CREATE INDEX idx_txn_payment ON transactions(payment_status);
```

---

## 3. 旧数据迁移规则

### 3.1 sales → transactions

```javascript
{
  id: legacyRow.id,
  type: 'income',
  date: legacyRow.date,
  amount: legacyRow.totalAmount,
  amount_net: legacyRow.amountWithoutTax,
  tax_amount: legacyRow.taxAmount,
  tax_rate: legacyRow.taxRate,
  currency: settings.currency || 'CNY',
  category_id: 'cn-income-sales-bulk',  // 默认归到「散货销售」
  counterparty: legacyRow.customer,
  invoice_no: legacyRow.invoiceNumber,
  invoice_status: legacyRow.invoiceStatus === '已开' ? 'issued' : 'pending',
  payment_status: legacyRow.payment_status,
  paid_amount: legacyRow.paid_amount,
  payment_date: legacyRow.payment_date,
  due_date: legacyRow.due_date,
  description: `${legacyRow.tons}吨 @ ¥${legacyRow.pricePerTon}/吨；运费 ¥${legacyRow.shippingCost}`,
  source_meta: JSON.stringify({
    migrated_from: 'sales',
    tons: legacyRow.tons,
    pricePerTon: legacyRow.pricePerTon,
    shippingCost: legacyRow.shippingCost,
  }),
}
```

### 3.2 purchases → transactions

类似，但 `type: 'expense'`，默认 category `cn-expense-cogs`（营业成本）。

### 3.3 迁移工具

- 设置页加「数据迁移」section（仅在检测到 sales/purchases 仍有数据时显示）
- 一键按钮「迁移到新模型」→ 后端跑事务批量 insert + legacy_migrations 记录映射
- 迁移完成后**保留** sales / purchases 表（只读模式），避免数据丢失风险
- 提供「回滚」按钮（30 天内有效）

---

## 4. 6 国预置类别清单

### 4.1 CN（中国）

**Income**：
- 主营业务收入 (sales-revenue)
- 其他业务收入 (other-revenue)
- 利息收入 (interest-income)

**Expense**：
- 营业成本 / COGS (cogs)
- 销售费用 (selling-expense)
- 管理费用 (admin-expense)
- 财务费用 (financial-expense)
- 营业税金及附加 (tax-surcharge)
- 所得税 (income-tax)

### 4.2 US（美国 Schedule C 对应）

**Income**：
- Gross Receipts (gross-receipts) → Schedule C Line 1
- Returns & Allowances (returns) → Line 2
- Other Income (other-income) → Line 6

**Expense**（共 ~22 类对应 Schedule C Part II）：
- Advertising → Line 8
- Car & Truck Expenses → Line 9
- Commissions & Fees → Line 10
- Contract Labor → Line 11
- Depletion → Line 12
- Depreciation → Line 13
- Employee Benefits → Line 14
- Insurance (other than health) → Line 15
- Interest (mortgage / other) → Line 16a/16b
- Legal & Professional → Line 17
- Office Expense → Line 18
- Pension & Profit-Sharing → Line 19
- Rent (vehicles / machinery / other) → Line 20a/20b
- Repairs & Maintenance → Line 21
- Supplies → Line 22
- Taxes & Licenses → Line 23
- Travel → Line 24a
- Meals (50% deductible) → Line 24b ⚠️ deductible_pct=50
- Utilities → Line 25
- Wages → Line 26
- Other Expenses → Line 27a
- Home Office → Form 8829

### 4.3 JP（日本）

**Income**：
- 売上高 (uriagedaka)
- 営業外収益 (eigyogai-shueki)

**Expense**：
- 売上原価 (uriage-genka)
- 販売費及び一般管理費 (hanbai-ippan)
  - 給料手当
  - 旅費交通費
  - 通信費
  - 水道光熱費
  - 消耗品費
  - 接待交際費
  - 広告宣伝費
  - 地代家賃
  - リース料
  - 租税公課
  - 減価償却費
  - 雑費

### 4.4 EU（通用，以法国/德国为典型）

**Income**：
- Chiffre d'affaires / Umsatz (revenue)
- Produits financiers / Finanzerträge

**Expense**：
- Achats / Wareneinkauf
- Loyer / Miete
- Salaires / Löhne
- Charges sociales / Sozialabgaben
- Frais de déplacement / Reisekosten
- Honoraires / Honorare
- Marketing / Werbung
- Énergie / Energie
- Amortissements / Abschreibungen
- TVA collectée − TVA déductible

### 4.5 KR（韩国）

**Income**：
- 매출 (sales)
- 영업외수익 (non-operating-income)

**Expense**：
- 매출원가 (cogs)
- 판매비와관리비 (sga)
  - 급여 / 복리후생비 / 여비교통비 / 통신비 / 수도광열비 / 소모품비 / 접대비 / 광고선전비 / 임차료 / 감가상각비

### 4.6 TW（台湾）

**Income**：
- 銷售收入 / 其他營業收入

**Expense**：
- 銷貨成本 / 推銷費用 / 管理費用 / 研究發展費用
- 營業稅 / 所得稅

---

## 5. 报表引擎接口设计

### 5.1 抽象接口

```typescript
interface ReportGenerator {
  locale: AccountingLocale;
  generate(period: DateRange, transactions: Transaction[], categories: Category[]): Report;
}

interface Report {
  title: string;
  period: { from: string; to: string };
  sections: ReportSection[];
  totals: { netIncome: number; tax: number; ... };
  warnings: string[];
}
```

### 5.2 各国实现

| Locale | 实现文件 | 主要报表 |
|---|---|---|
| CN | `electron/reports/cn.js` | 损益表（利润表） + 增值税申报草表 |
| US | `electron/reports/us.js` | Schedule C 草表 + Schedule SE 自雇税 + Quarterly Estimated Tax |
| JP | `electron/reports/jp.js` | 損益計算書 + 消費税申告書草表 |
| EU | `electron/reports/eu.js` | Profit & Loss + VAT Return |
| KR | `electron/reports/kr.js` | 손익계산서 + 부가가치세 신고 초안 |
| TW | `electron/reports/tw.js` | 損益表 + 營業稅申報 |

---

## 6. 美国特有功能（独立阶段）

### 6.1 Schedule SE 自雇税

```
Self-Employment Tax = Net Earnings × 15.3%
  - Social Security: 12.4% (cap at $168,600 in 2024)
  - Medicare: 2.9% (no cap)
  - Additional Medicare 0.9% if income > $200K single / $250K married
```

### 6.2 Quarterly Estimated Tax

```
触发条件：年纳税额预计 > $1,000
Q1: 4/15 / Q2: 6/15 / Q3: 9/15 / Q4: 1/15(次年)
计算：(预计年税额 / 4) 或安全港规则
```

### 6.3 Mileage Tracking

- IRS standard mileage rate: $0.67/mile (2024 business)
- 单独表 `mileage_logs (id, date, start_location, end_location, miles, purpose)`
- 自动按 IRS rate 转 expense → category=Car & Truck

### 6.4 Home Office

- Simplified method: $5/sqft × area (max 300 sqft)
- Actual method: 按比例 utilities/rent/depreciation

---

## 7. 实施阶段拆分

| 阶段 | 工作量 | 内容 | 当前会话 |
|---|---|---|---|
| **A** | 半天 | 本文档：完整设计 + ER 图 + 迁移规则 + 6 国类别清单 | ✅ 本次完成 |
| **B** | 1-2 天 | DB v4 migration 建 categories 表 + 6 国种子数据；handler + IPC + service + 设置页 CategoriesSection.tsx | ✅ 本次完成 |
| **C** | 1 周 | DB v5 建 transactions 表；handler 整套 CRUD；migration 工具把 sales/purchases 转过去；TransactionsPage 替代 Sales/Purchase 页面 | ❌ 单独会话 |
| **D** | 1-2 周 | electron/reports/ 6 国报表引擎；每国一套模板；FinancePage 按 locale 渲染 | ❌ 单独会话 |
| **E** | 1 周 | 类别 ↔ 报表行映射；Schedule C 自动生成；EU VAT Return 等 | ❌ 单独会话 |
| **F** | 1-2 周 | 美国 Schedule SE + Quarterly Estimated Tax + Mileage + Home Office | ❌ 单独会话 |
| **G** | 3-5 天 | 业务隐喻全量替换：去 tons / pricePerTon / 化工散货 mock 数据 / Bulk Salt 字面量 | ❌ 单独会话 |
| **H** | ?? | 法律 / 会计师审计；EULA 免责条款；E&O 保险评估 | 不在工程范围 |

**总计**：5-7 周净开发 + H 阶段（法律 / 财务合规）依赖外部资源

---

## 8. 风险清单

| 风险 | 等级 | 缓解 |
|---|---|---|
| 旧数据迁移丢失 | 高 | 保留旧表只读；提供 30 天回滚 |
| 法律责任（误报税） | 极高 | EULA 明确免责；外聘 CPA 校验各国规则；考虑 E&O 保险 |
| 类别覆盖不全 | 中 | 用户可建自定义类别；预置只覆盖 80% 场景 |
| 报表生成 bug | 高 | 单元测试覆盖 + 与官方表单 sample 对照 |
| MAS 审核拒（金融类应用） | 中 | 上架描述明确「记账工具非报税软件」；不主动声称合规 |
| Sales Tax nexus 复杂性 | 高 | 美国 v1 仅支持单 nexus；多州扩展放 v2 |
| 双轨数据维护成本 | 中 | C 阶段后给 6 个月缓冲期，强制迁移；老用户引导 |

---

## 9. 何时停下来咨询人类

以下任一情况发生时，停止编码，让用户决策：

- 任何 jurisdiction 的具体税率 / 起征点 / 申报截止日（不能猜，要查官方）
- 类别如何映射到 Schedule C / 損益表的某一 line（涉及税务判断）
- Sales Tax / VAT 计算细节（B2B 反向征收 / 跨境免税 / 数字服务税等）
- EULA / 免责条款的文字表达
- 报表样式是否要与官方表单视觉一致

---

## 10. 当前会话产出（A+B）

### A 阶段
✅ 本文档 `docs/INTERNATIONALIZATION_PLAN.md`

### B 阶段
✅ DB v4 migration 建 categories 表
✅ 6 国种子数据（CN/US/JP/EU/KR/TW 全部默认类别）
✅ electron/handlers/categories.js
✅ IPC 路由（`/api/categories` GET/POST/PUT/DELETE）
✅ services/api.ts 加 categories 工具函数
✅ components/CategoriesSection.tsx 设置页 UI
✅ 接入 SettingsPage 左侧 nav
✅ 6 种语言 locale 加 categories 相关 keys
