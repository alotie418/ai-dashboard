# SoloLedger 原生 SwiftUI 重写迁移计划

> 状态：Phase 1 技术原型规划（草案）
> 目标分支：`feat/swiftui-native-rewrite`
> 原型目录：`native/SoloLedger`
> 编写日期：2026-07-15

本文件是「Electron + better-sqlite3」现有应用向「原生 Swift 6 + SwiftUI」重写的总体迁移计划。所有决策均已确认（settled），本文档负责把它们落到工程可执行的粒度。正文使用中文说明，所有代码、路径、标识符（identifier）保持英文原样。

---

## 1. 概述与目标

### 1.1 现状

SoloLedger 目前是一个**本地优先（local-first）**的 macOS 记账 / 簿记桌面应用：

- 技术栈：Electron + React + `better-sqlite3`
- 分发线：Mac App Store（App Sandbox），Bundle ID `com.alotie418.sololedger`，`category: public.app-category.finance`，`arch: arm64`
- 数据：单一本地 SQLite 文件 `sololedger.db`（位于 Electron userData），无云端后端
- 定位：面向个体经营者、小微企业、跨境卖家的**本地私有专业账本**，不是官方报税 / 审计 / 法定合规系统

### 1.2 为什么重写为原生 SwiftUI

- **更小的体积与内存**：去掉 Chromium 运行时与多辅助进程
- **更强的隐私姿态**：原生版**不含任何 AI / 联网 / OCR / API Key / 付费解锁**功能，可进一步收紧沙箱权限
- **更好的平台一致性**：`NavigationSplitView` / `Table` / `Toolbar` / `Settings` scene / `Commands` / Swift Charts / Dark Mode / 无障碍（accessibility）皆为系统原生
- **更清晰的产品边界**：与 CLAUDE.md 的产品定位一致——本地私有、专业、克制，不虚报财务指标

### 1.3 Phase 1 原型范围（本次交付）

Phase 1 是一个**可运行的技术原型**，用于验证「原生栈能忠实复刻现有本地账本的数据模型与核心 CRUD」，而非功能完整替代品。核心结论优先级：

1. 能以**与 Electron 字节兼容**的方式创建 / 读写 SQLite（schema 对齐到 `user_version=23`）
2. 能完成 transactions 的增删改查 + `summary`（income/expense/net）
3. 能种子化（seed）categories、驱动 settings
4. 能做最小 CSV 往返（导出对齐现有格式 + 新增最小导入）
5. 能构建、可 ad-hoc 签名、可 headless 自检（`--self-test`）

**明确不做**（Phase 1 内不实现，见 §9 分阶段）：报表 / 税务 / COGS / 资产负债 / 现金流 / 发票 / 库存 / 电商连接器 / AI。这既是范围裁剪，也是 CLAUDE.md 的硬性要求——**不得把未实现的会计指标当作正式财务数据展示**。

---

## 2. 安全约束与边界

原型开发**必须**遵守以下硬约束。任何一条被违反都视为交付失败。

### 2.1 不得触碰的现有资产

- **不得修改**现有分支：`chore/mas-resubmit-1.0.1`、`feat/mas-sololedger-ai`，以及任何已签名 / 已公证的发布产物（release artifacts）
- **不得改动**现有 Electron 应用代码、`electron-builder.*.yml`、`build/entitlements.mas.plist`、`build/embedded.provisionprofile`、证书 / Provisioning Profile
- 原生代码**只**存在于独立目录 `native/SoloLedger`，位于独立分支 `feat/swiftui-native-rewrite`
- **不得** push、不得提交 MAS、不得改动任何证书 / 签名配置（本计划仅规划，不执行发布）

### 2.2 功能边界

- 原生版**不含** AI / API Key / OCR / 付费解锁 / 联网特性——这是产品决策，也直接决定了更严格的 entitlements（见 §3.5）
- 生产 Bundle ID **保持不变**：`com.alotie418.sololedger`
- 本地开发原型使用**独立** Bundle ID `com.alotie418.sololedger.dev`，避免与已安装 MAS 应用的沙箱容器 / Keychain / App Group 冲突

### 2.3 最低系统版本

- 现有 Electron 线最低系统版本 = **macOS 12.0**（Monterey），由 Electron 运行时决定（builder 配置未显式覆写 `minimumSystemVersion`）
- 原生版**在用户明确批准下**提升至 **macOS 13.0**（Ventura）——`NavigationSplitView` + Swift Charts 需要 13.0
- 权衡（tradeoff）：**macOS 12（Monterey）用户继续使用现有 Electron 构建**，原生版不向下兼容 12

### 2.4 数据安全（最高优先级）

> 真实账本是用户唯一的财务真相来源（single source of financial truth）。实验性原型**绝不能**冒任何损坏它的风险。

- 原型只读写**自己沙箱内**的数据库文件：`Application Support/com.alotie418.sololedger.dev/sololedger.db`
- 原型**绝不**读写生产 `sololedger.db`
- 「只读检视 / 导入已有 SoloLedger DB」路径**推迟**到后续阶段（Phase 2），且首次落地时**只读**
- **STOP 规则**：若某天无法安全保证 SQLite 兼容（见 §5.7），原型退化为**只读**模式，绝不写入任何可能被 Electron 打开的真实账本文件

---

## 3. 技术栈与架构决策

### 3.1 语言 / UI 栈

| 维度 | 选择 |
| --- | --- |
| 语言 | Swift 6 |
| UI 框架 | SwiftUI |
| 导航 | `NavigationSplitView`（侧栏 + 内容 + 详情） |
| 列表 | 原生 `Table` |
| 交互 | `Toolbar` / `Sheet` / `Settings` scene / `Commands`（菜单栏命令） |
| 图表 | Swift Charts（Phase 2 深化，Phase 1 仅占位） |
| 测试 | XCTest |
| 运行时约束 | App Sandbox、Dark Mode、accessibility |

### 3.2 SwiftPM 三 target 布局

Phase 1 用 **Swift Package Manager（`Package.swift`）**，三个 target：

| Target | 类型 | 职责 |
| --- | --- | --- |
| `SoloLedgerCore` | library | 数据层 / 模型 / CSV / 迁移（migrations）/ 种子（seed）/ 自检（self-test）逻辑 |
| `SoloLedger` | executable（`@main` SwiftUI app） | SwiftUI 视图、场景（scene）、命令 |
| `SoloLedgerCoreTests` | XCTest | Core 层单元测试 + guard 测试 |

把纯逻辑放进 `SoloLedgerCore` 是关键：它**不依赖 SwiftUI**，因此可在 CI headless 环境跑 XCTest，也可被 `--self-test` 复用。

目录树（建议）：

```
native/SoloLedger/
├── Package.swift
├── Sources/
│   ├── SoloLedgerCore/
│   │   ├── DB/
│   │   │   ├── SQLiteConnection.swift      // libsqlite3 薄封装
│   │   │   ├── SchemaMigrator.swift        // 复刻 v1..v23 迁移阶梯
│   │   │   └── PRAGMA.swift                // WAL / foreign_keys / synchronous / busy_timeout
│   │   ├── Models/
│   │   │   ├── Transaction.swift
│   │   │   ├── Category.swift
│   │   │   └── Setting.swift
│   │   ├── Repositories/
│   │   │   ├── TransactionRepository.swift // CRUD + list + summary
│   │   │   ├── CategoryRepository.swift
│   │   │   └── SettingsRepository.swift
│   │   ├── Seed/
│   │   │   └── CategorySeeds.swift         // 78 行 6 会计 locale
│   │   ├── CSV/
│   │   │   ├── CSVExporter.swift           // RFC-4180 + 公式注入防护 + CRLF + BOM
│   │   │   └── CSVImporter.swift           // 最小往返导入
│   │   └── SelfTest/
│   │       └── SelfTest.swift              // headless --self-test
│   └── SoloLedger/
│       ├── App.swift                       // @main
│       ├── RootView.swift                  // NavigationSplitView
│       ├── Views/
│       │   ├── OnboardingView.swift
│       │   ├── OverviewView.swift
│       │   ├── TransactionListView.swift
│       │   ├── TransactionEditor.swift     // Sheet
│       │   └── SettingsView.swift
│       └── Resources/
│           ├── zh-Hans.lproj/Localizable.strings   // = zh-CN（单一真相源）
│           ├── zh-Hant.lproj/Localizable.strings   // = zh-TW（占位）
│           ├── en.lproj/Localizable.strings
│           ├── ja.lproj/Localizable.strings         // 占位
│           ├── ko.lproj/Localizable.strings         // 占位
│           └── fr.lproj/Localizable.strings         // 占位
└── Tests/
    └── SoloLedgerCoreTests/
        ├── SchemaParityTests.swift
        ├── TransactionCRUDTests.swift
        ├── CSVRoundTripTests.swift
        └── LocaleMatrixTests.swift
```

### 3.3 数据层：系统 libsqlite3 vs GRDB

Phase 1 采用**系统 libsqlite3 的薄封装**（`import SQLite3`），零外部依赖。GRDB **已评估并推荐用于生产**，但推迟；它将坐落在同一个 SQLite 文件之上。

| 维度 | 系统 SQLite3（`import SQLite3`） | GRDB.swift |
| --- | --- | --- |
| 外部依赖 | 无（系统自带） | SwiftPM 外部依赖 |
| 离线构建 | 可（完全离线） | 需拉取包（首次需网络） |
| 人体工学（ergonomics） | 低（手写 C API、手动 bind/step/finalize） | 高（Record 类型、类型安全查询、Codable） |
| 观察（observation） | 无（需自建） | 有（`ValueObservation` / 与 SwiftUI 集成） |
| 迁移支持 | 手写（本计划自建 `SchemaMigrator`） | 内建 `DatabaseMigrator` |
| App Sandbox 友好 | 是 | 是 |
| SQL 精确控制 | 完全（逐字写 DDL，利于 schema 兼容） | 高（也可裸 SQL） |
| 风险 | 样板代码多、易错 | 引入依赖、需锁版本、学习成本 |

**结论**：Phase 1 用系统 SQLite3——**零依赖、可离线构建、沙箱友好、对 SQL 有逐字节控制**，最利于「与 Electron schema 精确对齐」的首要目标。生产阶段（Phase 2+）**推荐迁移到 GRDB**（人体工学、迁移、Record、observation），且因两者共享同一 SQLite 文件，迁移风险可控。

### 3.4 构建系统

- 用 `xcodebuild` / `swift` 针对 **Xcode 26.6** 构建
- 因 `xcode-select` 指向 CommandLineTools，需显式设置 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
- 产出一个可运行的 `.app`，**ad-hoc 代码签名**并附带 entitlements，用于本地冒烟测试（smoke test）

```bash
# 构建 Core + 跑测试
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path native/SoloLedger

# 构建可执行 app（release）
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift build -c release --package-path native/SoloLedger

# 组装 .app bundle 后 ad-hoc 签名（示意）
codesign --force --sign - \
  --entitlements native/SoloLedger/dev.entitlements \
  --identifier com.alotie418.sololedger.dev \
  path/to/SoloLedger.app
```

> **生产打包缺口（重要）**：SwiftPM 可执行体**不能**直接提交 MAS。MAS 提交最终需要一个真正的 **Xcode app target（`.xcodeproj` / `.xcworkspace`）**。这一步作为后续打包任务（Phase 4）单列，不在 Phase 1 范围内。

### 3.5 Entitlements（比 Electron 更严格）

原生版声明的 entitlements：

```xml
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.files.user-selected.read-write</key><true/>
```

**故意省略**：

- `com.apple.security.network.client`——原生版**无任何联网 / AI / OCR / API Key** 特性，无需出网
- `com.apple.security.application-groups`——那是 Electron 沙箱内 Chromium Helper 进程 Mach IPC 协作所需，原生单进程不需要

对比现有 `build/entitlements.mas.plist`（Electron MAS 线）仍携带 `network.client` 与 `application-groups`。原生版**更严格、更私有**，这与「本地私有专业账本」定位一致。

### 3.6 部署目标理由（重申）

macOS 13.0（Ventura）。`NavigationSplitView` + Swift Charts 需要 13.0；用户已明确批准提升。代价是放弃 macOS 12 覆盖（Monterey 用户留在 Electron 线）。

---

## 4. 现有数据库与迁移分析（只读分析）

以下均来自 `electron/db/index.js` 的只读分析，是原型必须**忠实复刻**的权威事实。

### 4.1 版本机制

- 用 SQLite `PRAGMA user_version` 记录 schema 版本，**没有** migrations 表
- `MIGRATIONS` 是一个 JS 数组，`SCHEMA_VERSION = MIGRATIONS.length = 23`（v1..v23）
- 运行器逐个在**独立事务**里应用迁移并 bump `user_version`；每个迁移都是**幂等（idempotent）**的
- 运行时 PRAGMA：`journal_mode=WAL`、`foreign_keys=ON`、`synchronous=FULL`、`busy_timeout=5000`
- 引擎：better-sqlite3；DB 文件：Electron userData 下的 `sololedger.db`（demo 模式：`userData/demo/`）

### 4.2 26 张表总览

全库 **26 张表**，**无触发器（trigger）、无视图（view）**。仅 1 个生成列：`mileage_logs.deduction = GENERATED ALWAYS AS (miles*rate_per_mile*(1+round_trip)) STORED`。

| 表 | 引入版本 | 用途 | Phase 1？ |
| --- | --- | --- | --- |
| `purchases` | v1 | 旧「采购」表（吨/单价/含税），只读迁移源 | 否（参考） |
| `sales` | v1 | 旧「销售」表，只读迁移源 | 否（参考） |
| `settings` | v1 | 键值设置（value 为 JSON 编码） | **是** |
| `price_history` | v1 | 价格查询历史（prices 为 JSON） | 否 |
| `alerts` | v1 | 提醒 | 否 |
| `ai_providers` | v2 | AI provider BYOK（api_key_encrypted，密文，不可移植） | 否（原生移除 AI） |
| `categories` | v4（+is_cogs v13） | 会计类别（6 会计 locale 种子） | **是** |
| `transactions` | v5 | 核心收支流水（income/expense 单表） | **是** |
| `legacy_migrations` | v5 | sales/purchases → transactions 映射 | 否（参考） |
| `mileage_logs` | v6 | 里程记录（含生成列 deduction） | 否 |
| `home_office` | v6 | 家庭办公室设置（单行 id=1） | 否 |
| `products` | v9 | 商品 / 服务主数据 | 否（Phase 2） |
| `business_documents` | v11 | 报价单/销售单/形式发票/商业发票/对账单头 | 否（Phase 3） |
| `business_document_items` | v11 | 单据行项（`tax_rate` 为 TEXT，故意不一致） | 否（Phase 3） |
| `assistant_conversations` | v12 | AI 对话历史 | 否（原生移除 AI） |
| `assistant_messages` | v12 | AI 消息历史 | 否（原生移除 AI） |
| `accounts` | v14 | 现金/银行账户（策略中立，不入表） | 否 |
| `liabilities` | v15 | 负债/借款台账（策略中立） | 否 |
| `fixed_assets` | v16（+折旧参数 v19） | 固定资产登记（策略中立，不折旧） | 否 |
| `equity` | v17 | 权益/资本台账（策略中立） | 否 |
| `tax_payments` | v18 | 已缴税款台账（历史记录，策略中立） | 否 |
| `purchase_items` | v20 | 采购行项（schema only，无行为） | 否 |
| `sales_items` | v20 | 销售行项（schema only，无行为） | 否 |
| `ecommerce_connections` | v21 | 电商连接（credentials_encrypted，密文） | 否（Phase 2+） |
| `ecommerce_staged_orders` | v22 | 电商拉单暂存（预览，不入账） | 否 |
| `ecommerce_sync_log` | v22 | 电商同步日志 | 否 |

> 说明：v23 不新增表，只给 `sales` 加 3 个电商溯源列 + 一个 partial unique index。

### 4.3 Phase 1 三张表的逐字 DDL

以下 DDL 是原生 `SchemaMigrator` 必须**逐字复刻**的目标（含索引、CHECK、默认值、FK）。

**transactions（v5）**

```sql
CREATE TABLE IF NOT EXISTS transactions (
  id TEXT PRIMARY KEY,
  type TEXT NOT NULL CHECK (type IN ('income', 'expense')),
  date TEXT NOT NULL,
  amount REAL NOT NULL,
  amount_net REAL,
  tax_amount REAL DEFAULT 0,
  tax_rate REAL DEFAULT 0,
  currency TEXT NOT NULL DEFAULT 'CNY',
  category_id TEXT,
  counterparty TEXT,
  invoice_no TEXT,
  invoice_status TEXT DEFAULT 'n/a',
  payment_status TEXT DEFAULT 'paid',
  paid_amount REAL DEFAULT 0,
  payment_date TEXT,
  due_date TEXT,
  description TEXT,
  attachment_path TEXT,
  source_meta TEXT,
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now')),
  FOREIGN KEY (category_id) REFERENCES categories(id)
);
CREATE INDEX IF NOT EXISTS idx_txn_date ON transactions(date);
CREATE INDEX IF NOT EXISTS idx_txn_type_date ON transactions(type, date);
CREATE INDEX IF NOT EXISTS idx_txn_category ON transactions(category_id);
CREATE INDEX IF NOT EXISTS idx_txn_payment ON transactions(payment_status);
```

**categories（v4，+ is_cogs v13）**

```sql
CREATE TABLE IF NOT EXISTS categories (
  id TEXT PRIMARY KEY,
  locale TEXT NOT NULL,
  type TEXT NOT NULL CHECK (type IN ('income', 'expense')),
  slug TEXT NOT NULL,
  label_zh_cn TEXT NOT NULL,
  label_zh_tw TEXT,
  label_en TEXT NOT NULL,
  label_ja TEXT,
  label_ko TEXT,
  label_fr TEXT,
  schedule_line TEXT,
  is_deductible INTEGER DEFAULT 1,
  deductible_pct REAL DEFAULT 100,
  parent_id TEXT,
  sort_order INTEGER DEFAULT 0,
  is_system INTEGER DEFAULT 1,
  created_at TEXT DEFAULT (datetime('now')),
  UNIQUE(locale, type, slug)
);
CREATE INDEX IF NOT EXISTS idx_categories_locale_type ON categories(locale, type);
-- v13:
ALTER TABLE categories ADD COLUMN is_cogs INTEGER DEFAULT 0;
UPDATE categories SET is_cogs = 1 WHERE slug = 'cogs' OR (locale = 'EU' AND slug = 'purchases');
```

- 种子 **78 行**，跨 6 个会计 locale：CN(9) / US(22) / JP(14) / KR(13) / EU(12) / TW(8)
- id 约定：`{locale}-{type}-{slug}`（如 `cn-income-sales`、`us-expense-meals`）

**settings（v1）**

```sql
CREATE TABLE IF NOT EXISTS settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,          -- JSON 编码，即使是裸字符串也编码为 "CN"
  updated_at TEXT DEFAULT (datetime('now'))
);
```

### 4.4 存储约定（必须逐字节复刻）

| 维度 | 约定 |
| --- | --- |
| 金额 | `REAL`（Double），**不是**整数分（cents） |
| 日期 | `TEXT`；用户日期 `'YYYY-MM-DD'`；自动时间戳默认 `(datetime('now'))` → `'YYYY-MM-DD HH:MM:SS'`（UTC） |
| 货币 | `TEXT` ISO 码；`transactions.currency NOT NULL DEFAULT 'CNY'` |
| 布尔 | `INTEGER` 0/1 |
| 主键 | 业务表（transactions/categories 等）为**应用生成的 TEXT 字符串**；部分子表 / 日志表为 `INTEGER AUTOINCREMENT` |
| JSON-in-column | `settings.value`、`transactions.source_meta`、`price_history.prices` 等 |
| 加密列 | `ai_providers.api_key_encrypted`、`ecommerce_connections.credentials_encrypted`——**密文，非可移植明文** |

### 4.5 陷阱（gotchas）

- **生成列**：`mileage_logs.deduction` 是 `GENERATED ALWAYS AS (miles*rate_per_mile*(1+round_trip)) STORED`——若 Phase 2 复刻此表，写入时**不能**给 `deduction` 赋值。系统 SQLite3 需支持生成列（SQLite ≥ 3.31）；macOS 13 自带满足。
- **故意的类型不一致**：`business_document_items.tax_rate` 是 **TEXT**（不是 REAL）。这是现有代码的既定事实，复刻时**照抄**，不要「顺手修正」为 REAL——否则 schema 漂移。
- **settings.value 恒为 JSON**：即使存单个字符串 `CN` 也要写成 `"CN"`（带引号）。原生读写 settings 必须 JSON 编解码，否则 Electron 读到会出错。

---

## 5. 数据兼容策略

### 5.1 目标

原生 `SchemaMigrator` 复刻 v1..v23 阶梯，最终把 `user_version` 设为 **23**，使得**原型创建的文件理论上可被 Electron 打开**（前向兼容验证用）。但见 §5.3——原型**不写**生产文件。

### 5.2 迁移阶梯复刻

```swift
// 伪代码：与 electron/db/index.js runMigrations 语义一致
func migrate(_ db: SQLiteConnection) {
    let current = db.userVersion()          // PRAGMA user_version
    for v in current..<Self.migrations.count {
        db.transaction {
            Self.migrations[v](db)          // 每个迁移幂等
            db.setUserVersion(v + 1)        // PRAGMA user_version = v+1
        }
    }
}
```

- 每个迁移在**独立事务**里跑，跑完 bump `user_version`（逐一 +1），与现有实现一致
- 迁移体幂等（`CREATE TABLE IF NOT EXISTS` / `PRAGMA table_info` 守卫）
- 运行时 PRAGMA 对齐：`journal_mode=WAL`、`foreign_keys=ON`、`synchronous=FULL`、`busy_timeout=5000`

> Phase 1 只需 Phase-1 三张表在功能上可用，但**为了 `user_version=23` 与前向兼容**，其余表的 DDL 也应照抄进阶梯（它们都是纯 additive、无行为），这样原型建的库 schema 与 Electron 完全一致。

### 5.3 为什么用独立 DB 文件

- Electron 生产文件（userData = productName 目录）：`~/Library/Application Support/SoloLedger/sololedger.db`
- 原生原型文件（`AppPaths`，folder 名 **`SoloLedgerNativePreview`**，刻意区别于 Electron 的 `SoloLedger`）：
  - 未沙箱（dev `swift run`）：`~/Library/Application Support/SoloLedgerNativePreview/sololedger.db`
  - 沙箱运行（dev Bundle ID `com.alotie418.sololedger.dev`）：容器内 `~/Library/Containers/com.alotie418.sololedger.dev/Data/Library/Application Support/SoloLedgerNativePreview/sololedger.db`
- 两种情形都与生产文件物理隔离。原型**绝不**打开生产文件——即便 schema 完全兼容，实验代码也不碰用户唯一账本。测试 / self-test 只用临时目录。

### 5.4 category 种子移植

把 `electron/db/seedCategories.js` 的 **78 行** SEEDS 移植为 `CategorySeeds.swift`：

- 保持 id 约定 `{locale}-{type}-{slug}` 与 `UNIQUE(locale,type,slug)`
- 保留 `label_zh_cn`(NOT NULL) / `label_en`(NOT NULL) 以及 zh_tw/ja/ko/fr、`schedule_line`、`deductible_pct`（如 US meals=50）、`sort_order`
- 用 `INSERT OR IGNORE` 幂等插入；v13 回填 `is_cogs`

### 5.5 枚举 / 校验一致性

镜像 `electron/handlers/transactions.js`：

| 项 | 值 |
| --- | --- |
| `VALID_TYPES` | `income` / `expense` |
| `VALID_INVOICE_STATUS` | `issued` / `pending` / `n/a` |
| `VALID_PAYMENT_STATUS` | `paid` / `partial` / `unpaid` |

`validate()`：id 必填；type ∈ VALID_TYPES；date 必填；amount 必须是有限数（finite）；invoice_status/payment_status 若存在须在枚举内。
`normalize()` 默认：currency `CNY`（≤8 字符）；category_id 可空；counterparty ≤200；invoice_no ≤100；invoice_status `n/a`；payment_status `paid`；paid_amount 0；description ≤1000；source_meta 为 JSON 字符串。
`list()`：过滤 type/from/to（日期区间）/category_id/limit（默认 500，最大 5000），`ORDER BY date DESC, created_at DESC`。
`summary()`：income 与 expense 的 `SUM(amount)`，`net = income - expense`。**这是唯一可信的概览指标**——不得臆造资产负债 / 现金流 / 比率卡片（CLAUDE.md 禁止展示未实现的财务指标）。

按 locale 的默认货币（新建 transaction 时）：US→USD、JP→JPY、EU→EUR、KR→KRW、TW→TWD，其余→CNY。`accounting_locale`（settings 键，默认 `'CN'`）是与 UI 语言**分离**的独立轴，用于选哪套 categories。

### 5.6 日期 / 金额 / 货币字节兼容

- 金额用 Swift `Double`，以 REAL 绑定（`sqlite3_bind_double`）——与 better-sqlite3 一致
- 日期用 `TEXT`：用户日期 `YYYY-MM-DD`；自动时间戳用 `datetime('now')`（UTC，由 SQLite 生成，不在 Swift 侧格式化，避免时区漂移）
- 货币用 ISO `TEXT`，默认 `CNY`

### 5.7 schema 漂移风险与 STOP 规则

- 风险：若原生写入的列类型 / 默认值 / 生成列 / JSON 编码与 Electron 不一致，会导致 Electron 读到坏数据 → schema drift
- 缓解：§10 的 **schema parity guard 测试**逐字段比对 `PRAGMA table_info` + 索引 + `user_version`
- **STOP 规则**：若某天无法安全保证 SQLite 兼容，原型**退化为只读**——只解析 / 展示，绝不写入任何可能被 Electron 打开的文件。宁可功能缩水，不可损坏账本。

---

## 6. 功能映射表（Electron → SwiftUI）

| Electron 页面 / 功能 | SwiftUI 视图 | Phase 1？ | 备注 |
| --- | --- | --- | --- |
| Onboarding（`OnboardingWizard`） | `OnboardingView` | **是** | 首启选 UI 语言 + accounting locale + 公司信息 |
| Dashboard / overview | `OverviewView` | **是** | 仅 income/expense/net（summary），无臆造卡片 |
| Transactions（income/expense） | `TransactionListView` + `TransactionEditor`（Sheet） | **是** | CRUD + 过滤 + 排序 |
| 旧 Sales / Purchases 页 | 折叠进 `TransactionListView` | **是**（读） | 旧表只读迁移源；Phase 1 不写 |
| Reports / 分析 | 推迟 | 否 | Phase 2；含 Swift Charts 深化 |
| Invoices / quotations / business_documents | 推迟 | 否 | Phase 3 |
| Products / inventory | 推迟 | 否 | Phase 2 |
| Accounts / liabilities / fixed_assets / equity / tax_payments | 推迟 | 否 | 策略中立台账 |
| AI assistant | **移除** | 否 | 原生不含 AI |
| E-commerce connectors | 推迟 | 否 | Phase 2+ |
| Settings（17 节 hub） | `SettingsView`（子集） | **是（子集）** | 见下 |
| 侧栏 footer（语言 + demo 指示） | Sidebar footer | **是** | |

**Settings Phase-1 子集**：外观 / Dark Mode、UI 语言、accounting locale + 派生货币、公司信息、数据 / DB 位置 + CSV、关于（about）。其余 11 节推迟。

---

## 7. 本地化架构

### 7.1 六语言计划

单一真相源 = **zh-CN**（映射到 Apple `zh-Hans`）。`Package.swift` 设 `defaultLocalization: "zh-Hans"`。

| App 语言 | Apple locale | Phase 1 |
| --- | --- | --- |
| 简体中文（zh-CN） | `zh-Hans`（源） | **完整翻译** |
| English | `en` | **完整翻译** |
| 繁體中文（zh-TW） | `zh-Hant` | 声明槽位（占位） |
| 日本語 | `ja` | 声明槽位（占位） |
| 한국어 | `ko` | 声明槽位（占位） |
| Français | `fr` | 声明槽位（占位） |

Phase 1 **完整翻译 zh-Hans + en**；架构上**声明全部 6 语言**（`.lproj/Localizable.strings` 槽位），其余 4 种后续填。

### 7.2 现在 `.lproj/strings` → 后续 `.xcstrings`

- Phase 1：传统 `<lang>.lproj/Localizable.strings`
- 生产推荐：迁移到单一 `Localizable.xcstrings` String Catalog，以 zh-Hans 为源
- **构建期一致性检查（parity check）**：与 JS 仓库 `i18n/locales/*.json` 比对——约 **1516 键/语言**、嵌套（nested）、`{{var}}` 插值、**无复数（no pluralization）**。已确认现仓库 6 个 locale 文件均为 1516 键。

### 7.3 两个正交轴

必须区分：

- **UI 语言轴**：界面显示语言（zh-CN/zh-TW/en/ja/ko/fr），持久化键类比现有 `sololedger-lang`
- **accounting locale 轴**：`accounting_locale`（settings，默认 `CN`），决定用哪套 categories 与派生货币（CN/US/JP/KR/EU/TW）

二者**独立**：一个说日语的用户完全可以用 US（Schedule C）会计 locale。原生 UI 必须保留这个区分，不能把语言和会计制度绑死。

---

## 8. 风险登记（Risk Register）

| 风险 | 严重度 | 可能性 | 缓解 |
| --- | --- | --- | --- |
| Schema 漂移（列类型/默认值/JSON 编码不一致） | 高 | 中 | §10 schema parity guard 逐字段比对 `PRAGMA table_info` + 索引 + `user_version`；STOP 规则退化只读 |
| 金额浮点舍入（Double/REAL 与 JS Number 差异） | 中 | 中 | 统一 `Double`↔REAL 绑定；展示层格式化，不改存储值；guard 测试比对求和结果 |
| SwiftPM → MAS app-target 缺口 | 高 | 高（确定存在） | 明确 Phase 4 单列 Xcode app target 打包任务；Phase 1 只做 ad-hoc 本地冒烟 |
| String Catalog 一致性（1516 键漂移） | 中 | 中 | 构建期 parity check 对齐 JS `i18n/locales/*.json`；缺键 / 多键报错 |
| 沙箱容器路径假设（dev vs prod 容器） | 中 | 低 | 用 `com.alotie418.sololedger.dev` 隔离；只走 `Application Support/<dev-bundle-id>/` |
| **会计敏感性**：原生**镜像**而非**重造**税务/COGS/报表逻辑 | 高 | 中 | Phase 1 **故意排除**报表/税务/COGS（CLAUDE.md 要求）；任何会计公式须会计师确认后才实现 |
| 生成列 / TEXT tax_rate 等既定不一致被「顺手修正」 | 中 | 中 | §4.5 明确「照抄不修正」；guard 测试锁定 |
| 误触生产账本 | 高 | 低 | §2.4 硬约束：只读写 dev 沙箱文件；绝不打开生产 `sololedger.db` |

> 关于会计敏感性的红线：原生版**不得发明会计政策**。CLAUDE.md 明列不可擅改的清单（`electron/reports/*`、税率默认值、所得税 / VAT / GST / 销售税公式、COGS、`_expenseSplit`、库存成本、加权平均成本、资产负债 / 现金流公式等）。Phase 1 通过**不实现报表**来规避这类风险；后续实现时须先只读分析并经会计师 / 用户确认。

---

## 9. 分阶段计划

会计公式在被会计师确认前**始终**排除在范围外。

### Phase 1 — 技术原型（本次，`native/SoloLedger`）

10 项交付物：

1. `Package.swift` 三 target 布局（Core / app / tests）可构建
2. `SQLiteConnection`：系统 libsqlite3 薄封装 + 运行时 PRAGMA（WAL/FK/synchronous/busy_timeout）
3. `SchemaMigrator`：复刻 v1..v23 阶梯，`user_version=23`，逐字段与 Electron 对齐
4. `CategorySeeds`：78 行 6 会计 locale 种子，幂等插入 + v13 `is_cogs` 回填
5. Settings 读写（JSON 编码 value；`accounting_locale` 默认 `CN`）
6. Transaction CRUD + `list`（过滤/排序/limit）+ `summary`（income/expense/net），镜像枚举与校验
7. CSV：导出对齐现有格式（RFC-4180 / 公式注入防护 / CRLF / 尾随 CRLF / UTF-8 / 可选 BOM）+ **净新增**最小往返导入
8. SwiftUI 外壳：`NavigationSplitView` + Onboarding/Overview/TransactionList/TransactionEditor(Sheet)/Settings(子集) + 侧栏 footer
9. i18n：zh-Hans（源）+ en 完整；6 语言 `.lproj` 槽位声明
10. 可运行 `.app`（ad-hoc 签名 + dev entitlements）+ headless `--self-test` + XCTest guard 测试

**估算**：约 2–3 周（1 人）。

### Phase 2 — 只读真实库导入 + 报表/图表深化 + 商品/客户

- **只读**检视 / 导入已有 SoloLedger DB（先只读，绝不写生产文件）
- Reports / 分析视图 + Swift Charts 深化（**镜像**现有报表口径，不重造公式，需会计师确认）
- products / customers 主数据
- 评估切换到 **GRDB**

**估算**：约 4–6 周。

### Phase 3 — 发票/单据 + 备份恢复对齐

- business_documents / business_document_items（含 TEXT tax_rate 既定不一致）
- 备份 / 恢复对齐（Electron 有滚动快照 + `user_version` 兼容校验）

**估算**：约 3–5 周。

### Phase 4 — 完整 6 语言 + `.xcstrings` + MAS 打包

- 补齐 zh-TW/ja/ko/fr；迁移到 `Localizable.xcstrings` String Catalog + 构建期 parity check
- **新建真正的 Xcode app target（`.xcodeproj`/`.xcworkspace`）**：签名 / 公证（notarization）/ MAS 提交
- 此阶段才涉及证书 / Provisioning / 发布——需用户明确批准

**估算**：约 3–4 周。

---

## 10. 验证与测试策略

### 10.1 构建 / 测试命令

```bash
# 单元 + guard 测试（headless，CI 友好）
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path native/SoloLedger

# release 构建
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift build -c release --package-path native/SoloLedger

# headless 自检（建库 → 迁移 → 种子 → CRUD → summary → CSV 往返 → 校验 user_version）
.build/release/SoloLedger --self-test
```

### 10.2 Guard 测试（镜像 JS 仓库的安全主题）

| 测试 | 目标 |
| --- | --- |
| `SchemaParityTests` | 建库后逐字段比对 `PRAGMA table_info` + 索引 + `user_version=23`，防 schema 漂移 |
| `TransactionCRUDTests` | 枚举 / 校验 / 默认值 / list 排序 / summary 数值与 Electron 语义一致 |
| `CSVRoundTripTests` | 导出→导入→再导出字节稳定；RFC-4180 转义 / 公式注入防护 / CRLF / BOM |
| `LocaleMatrixTests` | 6 语言矩阵不回退；无 raw i18n key 泄漏；键集与 JS `i18n/locales/*.json`（1516 键）对齐 |
| （通用）enum leak 守卫 | UI 不展示 raw 枚举（如 `UNPAID`/`PAID`/`PARTIAL`）或技术错误串 |

### 10.3 与 CLAUDE.md 测试原则的对应

- Locale 矩阵不回退 → `LocaleMatrixTests`
- Raw i18n key 不泄漏 → `LocaleMatrixTests`
- 类型检查通过 → `swift build` 严格模式（Swift 6 并发检查）
- Handler 往返保护本地 SQLite 路由 → `TransactionCRUDTests`（Repository 层往返）
- 错误信息可操作且本地化 → editor / import 校验错误走本地化文案
- UI 不显示 raw 后端枚举 / 技术错误串 → enum leak 守卫

### 10.4 self-test 流程

`--self-test` 在临时目录建库，串起：建库 → 迁移到 v23 → 校验 `user_version=23` → 种子 78 类别 → 写 settings → transaction 创建/更新/查询/删除 → summary 断言 → CSV 导出+导入往返断言 → 退出码 0/非 0。CI 可直接调用，无需 GUI。

---

## 附：关键路径速查

| 项 | 值 |
| --- | --- |
| 目标分支 | `feat/swiftui-native-rewrite` |
| 原型目录 | `native/SoloLedger` |
| 生产 Bundle ID | `com.alotie418.sololedger`（不变） |
| 开发 Bundle ID | `com.alotie418.sololedger.dev` |
| 原型 DB | `Application Support/com.alotie418.sololedger.dev/sololedger.db` |
| 部署目标 | macOS 13.0（Ventura） |
| Xcode | 26.6（`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`） |
| schema 版本 | `user_version = 23`（v1..v23） |
| 类别种子 | 78 行 / 6 会计 locale（CN9/US22/JP14/KR13/EU12/TW8） |
| i18n 源 | zh-CN → `zh-Hans`；1516 键/语言 |
| 现有参考 | `electron/db/index.js`、`electron/handlers/transactions.js`、`electron/db/seedCategories.js`、`electron/handlers/_csvExport.js`、`build/entitlements.mas.plist`、`i18n/index.ts` |
```
