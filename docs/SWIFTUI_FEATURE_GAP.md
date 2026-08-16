# SoloLedger — Electron → SwiftUI 功能差距表

状态图例：**✅ 已完成** · **🟡 缺少**（需要，尚未做）· **⏸️ 暂缓**（有意推迟）· **🛑 Release 前必须完成**（发布阻塞项）· **❌ 移除**（不再做）

> 敏感会计逻辑（税务 / VAT / COGS / 利润 / 报表 / 资产负债 / 现金流）一律**只镜像 Electron 行为，不重新解释或改写**（CLAUDE.md）。原生版**无 AI、无网络、无 StoreKit**。

## 1. 核心记账

| Electron 功能 | 状态 | 备注 |
| --- | --- | --- |
| 首次引导 Onboarding | ✅ | `OnboardingView`（语言 + 会计制度 + 公司名，无 AI 步骤） |
| 交易 CRUD（income/expense、`transactions` 表） | ✅ | `TransactionListView` + `TransactionEditor`，枚举/校验镜像 `transactions.js` |
| 概览 Dashboard | ✅（Phase 2A 完善） | 收入/支出/净额 + 按月图表；**多币种按币种分组**；无臆造指标 |
| 交易搜索 / 排序 / 日期筛选 | ✅（Phase 2A 新增） | 搜索**往来对象·备注·发票号**（不含类别）；Table 列头排序驱动数据库查询（ORDER BY 先于 LIMIT）；日期预设（全部/本月/本年）；类型筛选 |
| 批量删除（原子 + 完整 Undo） | ✅（Phase 2A 强化，**原阻塞项已解决**） | `deleteBatch` 单事务全成全滚（故障注入测试）；Undo 用 `DeletionSnapshot` 完整恢复**全字段 + created_at/updated_at + legacy_migrations 映射**；工具栏/Delete 键/右键三入口统一确认 |
| 金额与货币显示 | ✅（Phase 2A 完善） | 按币种格式化；**多币种不再显示无说明总数** |
| 会计类别浏览（78 预置） | ✅（只读） | `CategoriesView`，可切会计制度 |
| CSV 导入 / 导出（交易） | ✅ | RFC-4180 + BOM + 注入防护；导入纯追加 |
| Electron → SwiftUI 数据升级 | ✅ | 生产启动路径为 C12 coordinator 链（`AppModel.startChain(.boot)` → `MigrationCoordinator`）；`DatabaseUpgrade` 仅保留为 legacy 恢复分支（`AppModel` 的 legacy `DatabaseUpgrade` 恢复分支），不在启动路径上 |
| 6 语言 UI | ✅ | 六语各 **650 键、键集完全一致**（`Sources/SoloLedger/Resources/*.lproj/Localizable.strings`）；guard 强制「恰好六个 `.lproj`」（`LocalizationWordingGuardTests.swift:861`）、「各语键数相等」（`:870`、`:879-880`）、「无空值」（`:903`）、「值不得等于键」（`:913`）。**绝对键数由另外三条棘轮钉住**（`LegacyConversionCopyTests` / `ProductCopyTests` / `InventoryCopyTests` 各一条 `XCTAssertEqual(table.count, 650)`）——`LocalizationWordingGuardTests` 本身只钉「各语相等」与「每语 > 200」，所以本行的数字必须跟着那三条棘轮走，而不是反过来。缺键仍回退 **zh-Hans**（非 en；`Package.swift:19`、`Localizer.swift:40`）；仍为 `.strings`（无 `.xcstrings`）；键**集合**相等由 `MigrationCopyParityTests` 的 `testFullLocaleKeyUniverseRatchet` 严格比对（六语与 zh-Hans 全集互为子集），等量互换的错键无法漏网 |
| 深色模式 | ✅ | 原生新增（Electron 仅浅色） |
| 类别管理（增删改） | 🟡 | 目前只读浏览 |

## 2. 会计 / 报表（敏感逻辑——只镜像）

| Electron 功能 | 状态 | 备注 |
| --- | --- | --- |
| 损益表 / P&L | ✅（R2–R8 已镜像） | 六个制度引擎齐全（`Sources/SoloLedgerCore/Reports/` 的 CN/US/JP/EU/KR/TW），逐字镜像 `electron/reports/*`；batch1–5 parity + blind-spot 测试对冻结黄金逐字段比对。入口已激活（`RootView` detail switch 的 `.reports` 分支）。**管理分析口径，非法定财务报表** |
| VAT / GST / 销售税汇总 | ✅ | `CNReportEngine.swift:183` `vatSummary`、`EUReportEngine.swift:93` `vatReturn`、`KRReportEngine.swift:98` `vatSummary`；JP 消费税 / TW 营业税同批镜像。**估算汇总，不是申报数据，不接税控/税局** |
| 所得税 / 附加税估算 | ✅ | 所得税与附加税链已镜像（`CNReportEngine.swift:77-84`），US 自雇税同批。税率缺失或损坏一律**拒算不回退**（`ReportRateSetting.swift:46-88` 的四态契约）。**估算值，预设税率可能随政策调整，须自行核对最新官方税率** |
| 现金流 / 资产负债（PR-7B） | 现金流 ✅ ／ 资产负债 ⏸️（测绘完成后挂起） | 经营活动现金流已镜像 `_cashflow.js`（`Reports/Cashflow.swift`）；投资 / 筹资 / 期初期末与 Electron 一样不可从本数据模型推导，**如实说明而不显示为 0**。`electron/handlers/balanceOverview.js`（246 行，管理口径概览、非法定资产负债表）：**测绘已完成（2026-08-15），该镜像章按用户裁定挂起**。挂起的理由不是镜像技术，而是上游数据面 —— 逐字镜像它在原生账本上只能得到一张**部分填充**的报表，而部分填充比空白更糟。三条实测依据：①它 `require` 六个上游 handler（`cashPosition` / `receivables` / `inventory` / `depreciationPreview` / `retainedEarnings` / `incomeTaxPosition`，781 行），连同本体 **1027 行**，比整个报表镜像章的 930 行还大；②这条链的输入表里有**七张**（`accounts` / `liabilities` / `fixed_assets` / `equity` / `tax_payments` / `sales_items` / `purchase_items`）**原生零写入**——原生唯一碰它们的是 `LegacyLedgerProbe` 的「隐藏记录」计数与 `LegacyConversionPlan` 的明细行计数，**只数行数、不读内容、不参与任何计算或展示**；③**哪些板块会有数、哪些不会，是可以逐行说清的**：现金的**流量半边**（期内实收−实付，`cashPosition` 在本期有 `transactions` 时选它）、未分配利润、所得税**应计**三块会有内容；现金的**期初余额**（`accounts`）、存货（`purchase_items`/`sales_items`）、固定资产、借款、出资行**恒无源**；应收/应付只读 `sales`/`purchases`，原生自己录的流水不落那两张表，故原生建账的账本里为 0（从 Electron 迁入且未转换的账本另当别论）。⇒ **资产侧只剩现金流量、权益侧只剩未分配利润、负债侧近乎空白，`balanceDifference` 会变成一个由「只有部分板块有数」造成的残差，却按设计显示为「待调整项」** —— 那正是 CLAUDE.md 禁止的「把不完整的会计模块显示成正式指标」。Electron 自己的空态文案 `finance.balanceComingSoonDesc` 也写着「录入现金账户、资产、负债或交易数据后，将在此显示」，而那些录入页正是 §3 里 ⏸️ 的那一行。**重开这一章的前提是先做 §3 的五个录入页**，不是先写 Swift。测绘另已择定 oracle 路径（差分语料 `--verify`，循 `Fixtures/reportmath/` 先例落在黄金目录之外，与黄金冻结零交互）。**本行不表示计划中或进行中** |
| COGS / `_expenseSplit` / 库存成本 | COGS ✅ ／ 库存 ✅ **原生新引擎（非镜像）·N 章已收官** | `Reports/ExpenseSplit.swift` 逐行镜像 `_expenseSplit.js`（`:3` 声明镜像、`:16` `isCogsRow`、`:41` `splitExpenses`，均标注对位行号）。**库存不镜像 Electron**：`electron/handlers/inventory.js` 经实测审计确认产出的是「建账以来累计采购净额 ÷ 累计采购数量 × 当前净在库量」，销售不冲减均价（买 10@100 → 卖光 → 再买 10@200，真实剩余成本 2000，该算法给 1500），**不是加权平均法**，故不作为镜像对象。原生按 N0 口径确认书新写移动加权平均引擎，N-PR-1…N-PR-6（#452–#458）已全部合并：schema v24 三表（见 §4）、引擎、六语文案、库存页、期初盘点向导、侧栏入口。**该引擎的出库成本流水不接入任何报表 COGS**——是否接入正式报表属另行裁定的独立事项，在裁定前 `Reports/**` 与库存引擎之间无任何调用出口 |
| 折旧预览 / 里程 / 家庭办公室 | ⏸️ | 特定制度，暂缓 |

## 3. 单据 / 主数据

| Electron 功能 | 状态 | 备注 |
| --- | --- | --- |
| 发票 / 报价单 / 商业单据（`business_documents`） | ⏸️ | 暂缓（Phase 3） |
| 产品 / 服务项（`products`） | ✅（阶段 2b） | `ProductsView` + `ProductPageComposition` + `Inventory/ProductCatalog.swift`（逐行镜像 `electron/handlers/products.js`）。侧栏「商品 / 服务项目」可达。**仅主数据**：`default_unit_cost` 只登记，不参与任何计算——它在 Electron 里同时被用作采购行、销售行与单据行的默认单价，语义不唯一，因此**原生库存引擎不迁移、不读取该列**（N-11）；库存计价走 v24 起的原生新引擎，见 §2 与 §4 |
| 库存（原生独有，Electron 无对应页） | ✅（N 章 #452–#458） | `InventoryView` + `InventoryPageComposition` + `InventoryOpeningView` + `Core/Inventory/`（`InventoryLedger` / `InventoryPosting` / `InventoryOpeningPlan`）。侧栏「库存」可达。**按 N0 口径确认书新写的移动加权平均引擎，不镜像 `electron/handlers/inventory.js`**（见 §2）。首版半径 = 手工流水录入 + 期初盘点向导；禁负库存、拒迟到交易、拒混币、整数分存储。**出库成本流水不接入任何报表 COGS**——是否接入属另行裁定的独立事项 |
| 客户 / 供应商 | 🟡 | 目前 `counterparty` 为自由文本 |
| 现金/银行账户、负债、固定资产、权益、税费台账（策略中立） | ⏸️ | 暂缓。**这五个录入页是资产负债概览镜像章的前提**：那条链的输入表原生零写入，没有录入口就没有数据，镜像出来只能部分填充（见 §2 该行） |

## 4. 数据安全 / 迁移（多为 Release 阻塞）

| 功能 | 状态 | 备注 |
| --- | --- | --- |
| 用户可见备份 / 恢复 UI | ✅ | 「设置 → 数据」已上线：导出备份（`SettingsView.swift:227`）与从备份恢复（`:234`，破坏性操作、二次确认、legacy 转换进行中禁用 ← `AppModel.restoreBackupViaPanel` 的 legacy-conversion 守卫）。恢复顺序为「只读校验 → 先把当前账本快照进 `Backups/` → 关库 → `clearActiveSlot`（`BackupRestore.swift:61`）→ 经 hardened 导入链重建」 |
| **附件文件迁移**（`attachment_path` 指向的本地文件 + 备份 bundle 的 `attachments/`） | ✅（G1 已闭合） | 主/自动 `.masContainer` + 用户选目录导入链**已迁附件**（`AttachmentApply` → `PreparedImportFinalizer`：逐字保留 `attachment_path`、SHA-256 校验、add-only 不覆盖）；Core 链测试 + **App 层端到端**（`ElectronFixtureProductionOpenTests`）均覆盖。原"只迁 DB 不迁附件"实为已停用的 `DatabaseUpgrade`（非生产启动路径）。**restore-from-backup 恢复路径同样重建附件**——它复用同一条 hardened 导入链的 finalizer（`BackupRestore` 的头部注释、`AppModel` 的恢复入口），由 `BackupRestoreTests.swift:132` `testClearThenReimportRebuildsLedgerAndAttachmentsReplacingPrevious` 端到端断言。**G1 已关闭**。**2c-8 补上了 Release 侧的实测**（此前覆盖全在 Debug）：在真实 Release 沙箱的一次性容器里，源侧放一个有文件的 `attachment_path` 和一个指向不存在文件的 `attachment_path`，迁移后有文件的那个按 sha256 逐字节等同地落进活动 `attachments/docs/`、两行的 `attachment_path` 字符串**逐字保留**，缺文件的那个不阻塞迁移而是走 `.requiresAcknowledgement`——屏幕如实列出「missing-2c8.pdf / 引用的文件未找到」，确认后 manifest 记 `status: complete`、`referenceAuditPerformed: true`、`unresolved.items[].kind = danglingReference`，源侧两个文件的 sha256 前后不变 |
| **legacy `sales`/`purchases` 数据的可见性** | ✅（诚实提示 + 转换入口已上线） | 只读探针 `LegacyLedgerProbe` 用与 Electron 转换器相同的反连接（`LEFT JOIN legacy_migrations … WHERE m.id IS NULL`，`LegacyLedgerProbe.legacyLedgerSummary`）统计未转换行，并另计 12 张原生不读的记录表（发票 / 产品 / 固定资产等，`:54-58`、`:93`），因此这类账本不再被显示成空账本。**探针零写入**。提示分两支且互斥（`LegacyConversionComposition.swift:52-60`）：有未转换的销售 / 采购记录时，该提示同时是转换向导的入口（2a-4，见下一行；向导在用户确认前不写入）；只有其他类型记录时，如实说明本 App 目前只显示「流水」，**不提供也不承诺转换**。`holdsHiddenRecords`（`:43`）另用于在"看似空账本"时关闭 DEBUG 演示数据入口（`AppModel.reloadAll`） |
| **legacy `sales`/`purchases` → `transactions` 转换器** | ✅（2a-1…2a-4 已上线，含三轮定向硬化） | 预检分级器 + 单事务执行引擎 + 六语向导（`Conversion/LegacyConversionPlan.swift`、`Conversion/LegacyConversionRunner.swift`、`Views/LegacyConversionView.swift`）；入口挂在 legacy 提示上（`Components.swift` 的 legacy 提示 → `AppModel.beginLegacyConversion()`）。三处口径按**保守修正**落地：①空 / 缺失 `payment_status` 写为 `unpaid`（沿用旧列自身的 DEFAULT，不照抄 Electron 的乐观 `paid`，`LegacyConversionRunner.swift:545-549`）②默认收/支类别由用户在向导中显式选择（`LegacyConversionView.swift:396-402`）③明细塌缩、报表按年度二选一的口径切换等 **9 条后果在转换前逐条明示**（`zh-Hans.lproj/Localizable.strings:543-551`）。Electron 侧已知缺陷已消除：全部写入在单个事务内、无 per-row `catch`；计划在写事务内重算比对，不一致即 `ledgerChanged`；转换前强制生成 `pre-convert-<ts>` 备份，备份写不出或读不回则不开始（`AppModel.beginLegacyConversion` 的备份前置，实现在同文件的 `runPreConversionBackup`）。**旧行零删改**（转换器对 `sales`/`purchases` 无任何 DELETE/UPDATE）；转换进行中禁止从备份恢复（`AppModel` 的恢复入口守卫）。**转换会改变已有期间的报表呈现，这一点在确认页事先说明** |
| **旧进程检测硬化** | ✅（沙箱内正解已达成） | 生产 ingest 用**强指纹稳定性**检测（前后指纹 + 3 次尝试，`StagingIngest`）——旧版仍在写则拒，映射为**可重试态** `.retriable(.sourceBusy)`（`MigrationCoordinator.swift:1104`）并显示引导消息 `migration.msg.sourceBusy`（"请退出旧版 SoloLedger 后重试"，6 语齐全）+ Retry 动作。**App Sandbox 内无法枚举进程 / 取跨进程锁**，指纹 + 引导退出即该环境下的正解。原 🛑 标记已过时 |
| **Release 数据路径验证** | ✅（2c-8 已在真实 Release 沙箱端到端验证，2026-08-15） | 验证构造：真实 `-configuration Release` 产物 → `cp -R` 到 `/private/tmp` → 换 `CFBundleIdentifier` 为一次性 id → `codesign --force --sign -` 配 **Release entitlements**（`app-sandbox` + `files.user-selected.read-write`，无 `get-task-allow`）→ macOS 铸全新空容器。**`#if DEBUG` 未改**，所以数据夹名走的是 Release 的 `SoloLedgerNative`——这是既验 Release 路径、又完全不碰生产容器的唯一办法。八条实证：①**数据路径**——「设置 → 数据」自报 `<容器>/Data/Library/Application Support/SoloLedgerNative/sololedger.db`，Release 二进制里 `SoloLedgerNativePreview` 字面量 **0** 命中；②**纯探针启动零副作用**——无可用来源时落在源选择屏，容器内连数据根都不存在（`Config.standard()` 的纯路径推导名副其实），`attachments/docs` / `ImportManifests` / `ImportWork` / `PreparedImports` / `Staging` 一个不铸；③**`.masContainer` 就地升级端到端**——把 `electron-v23.db` fixture 植入容器内 Electron 路径后启动，7 笔交易 + 78 条类别逐字段等同、`user_version = 24`、库存三表齐、`native_inventory_active="24"`，源库 sha256 三次测量不变；④**迁移前快照**见本节「迁移前快照与两条恢复语义」行；⑤**fail-closed**——源缺失 → 源选择屏；源损坏 → 终态 `code: sourceCorrupt` / `param.reason: integrityFailed`，活动库根本没建；⑥**自导入守卫是生产身份**——把 app 自己的 `SoloLedgerNative` 数据根当迁移来源选中，得终态 `code: invalidSource` / `param.reason: sourceIsActiveData`（Debug 构型护的是 `…Preview`，同一操作只会得到「源库缺失」，两者可区分即证明守的是生产身份）；⑦**真 Powerbox**——`FilePanels` 的 `#if DEBUG` 面板覆写符号在 Release 二进制 0 命中，导出备份 / 导出 CSV / 导出诊断三个保存面板 + 迁移源目录 / 恢复备份两个打开面板全部弹真面板（`openAndSavePanelService` 新进程），沙箱进程在**容器外**建目录写多文件；⑧**备份 → 恢复往返**（`MAS_SUBMISSION.md` §1 记的那条迁移路线）走通，恢复前自动写 `Backups/pre-restore-<ts>`，重建后交易与原 fixture 逐字段等同。**三条未验，如实登记**：真实分发签名（Apple Distribution + MAS profile）下的同一条链——那必然落进生产容器，本轮按纪律不做，故只验代码路径不验签名身份；归档 / 导出 / 上传（属另行授权的一步）；Release 产物实测仍是 `x86_64 arm64` 双 slice，与 D4 的 arm64-only 有落差（2c-6 已登记，留给归档 / 导出轮钉） |
| **DMG（非沙箱）用户数据迁移入口** | ✅（N7.2 已闭合） | 源选择入口已全链路接线并测试：coordinator `.requiresSourceChoice`（`MigrationCoordinator.swift:668`）→ `.awaitingSourceChoice` → RootView `.chooseSource`（`RootView.swift:97`）→ 目录面板（`FilePanels.swift:59`）→ `.migrateFromUserDir(.userSelectedDataDir)`（`AppModel` 的 boot-chain 编排与 intent 映射）。single-grant-window、无 bookmark entitlement（`MigrationSource.withAccess`）。测试：`DormantSourceChoiceBootTests`、`ElectronFixtureProductionOpenTests`。**原 🛑 P0 标记已过时** |
| **schema v24 单向性**（原生梯子首次高于 Electron） | ⚠️ **约定，非技术强制** | v24 是原生独有的一级（库存三表），Electron 侧没有对应实现。**三条实测事实，逐条如实说明**：①**Electron 照常打开 v24 账本、照常读写 v23 表**——`electron/db/index.js:860-869` 的 `for (let v = 24; v < 23; v++)` 零次迭代、不抛错，`:63` 的 `pendingMigration` 为 false（该账本连 Electron 自己的迁移前自动备份都不会触发）；不存在「Electron 打不开」这条路径。②因此**在 Electron 里录一笔采购，原生库存引擎不知道**——原生引擎只读自己的流水表——**两套库存事实源会静默分叉**，这正是新引擎要消灭的东西。③**唯一真正会拒绝的是备份恢复路径**：`electron/handlers/index.js:232` 的 `uv > SCHEMA_VERSION → 'NEWER_VERSION'`，六语文案已存在（`settings.dataBackup.newerVersion`）。⇒ **升级到 v24 后请不要再用 Electron 打开同一个账本。** 迁移时向 `settings` 写一行证据 `native_inventory_active`（JSON `"24"`），供将来 Electron 侧加读取即可提示——**注意今天的 Electron 读不到它**：`handlers/settings.js` 的 `SETTINGS_ALLOWED_KEYS` 白名单会把它过滤掉，所以这是给未来留的钩子，不是现在就有的提示。Electron 侧启动提示 PR 属独立事项，需单独授权（会改 `electron/**`） |
| **迁移前快照与两条恢复语义**（就地升级的回滚点） | ✅（N-PR-0b / #451） | 已有原生 active 账本在就地迁移前会写一份经校验的 `pre-migrate-v<from>-<ts>` bundle，写不出或读不回则**不迁移、开库失败**（fail-closed，`PreMigrationSnapshot.swift`）。v23→v24 升级因此自动获得回滚点（`InventorySchemaTests` L1 端到端验证）。两条容易读反的语义：①**快照恢复的是「升级前的数据」，不是「升级前的 schema」**——bundle 里的库是 v23，但恢复链重开时梯子会再跑一遍，结果仍是 v24；想回到 v23 需要的是 schema 回滚（`DROP` 三表 + `PRAGMA user_version = 23`），不是恢复快照。②**这份 v23 快照拿去 Electron 恢复是会被放行的**（`uv = 23 ≤ SCHEMA_VERSION = 23`，不触发 `NEWER_VERSION`）——它是升级前的库，Electron 读它完全正常；被拒的是 v24 备份。**2c-8 在真实 Release 沙箱里实测了这条路径，同时纠正了一个容易读反的预期**：**从 Electron 首次迁移不会产生这份快照，而且这是对的**——v23→v24 的梯子跑在 prepared 副本上，活动账本那时还不存在，没有任何东西需要回滚点，回滚点就是原封未动的 Electron 源库（实测：首次迁移后 `Backups/` 根本不存在，而 prepared 副本的 `user_version` 已是 24）。真正的就地升级要跨两个 app 版本才复现得出来：先用 v23 期的历史构建（`6c272e5`，`SchemaMigrator.schemaVersion = 23`）造出 v23 活动账本，再把同一个一次性 id 换成 main 构建启动，才拿到 `Backups/pre-migrate-v23-<ts>`——其中的库 `integrity_check` / `quick_check` 双通过、`user_version = 23`、**无**库存三表、交易与升级前逐字段等同；升级后的活动库交易同样逐字段等同，只多出 `native_inventory_active="24"` 一行 settings |
| 加密列（`ai_providers`/`ecommerce_connections`，safeStorage 密文） | ❌ | 跨应用不可移植；原生无 AI/电商，不迁移 |

## 5. 打包 / 发布（Phase 4）

| 功能 | 状态 | 备注 |
| --- | --- | --- |
| 真正的 Xcode 工程 | ✅ | `native/SoloLedger/App/SoloLedger.xcodeproj`（Phase 1.5）。CI 已有独立 job「Native SwiftUI app (xcodebuild + unit tests)」（`.github/workflows/ci.yml` 的 `native-app`），三步：Debug 编译（step「Build the real SwiftUI app」）+ Debug App-hosted 单测（step「App-hosted unit tests (SoloLedgerUnitTests only)」，仅 `SoloLedgerUnitTests`，显式排除 UITests）+ **Release 构型编译门**（2c-6，step「Release-configuration compile gate (build only, unsigned)」，带 `CODE_SIGNING_ALLOWED=NO`，**只 build**——不 test、不 archive、不启动，因为 Release 带的是生产 bundle id）。守门 `ReleaseCompileGateGuardTests`。指针按 step 名给出而非行号：改 workflow 不会让本行失效 |
| **MAS 签名**（Apple/Mac App Distribution + Mac Installer Distribution + MAS provisioning profile） | 🛑 **Release 前必须** | **缺的不是证书**（2026-08-10 实测：Apple Distribution 与 3rd Party Mac Developer Installer 两张证书均在钥匙串，MAS provisioning profile 在 `build/embedded.provisionprofile`，三者同于 2027-07-15 到期）。**工程侧配置已于 2c-4 / 2c-5 接线完毕**：①归档构型——共享 scheme 的 `ArchiveAction` 原为 Debug（照现成命令归档会打出 `.dev` bundle id + 带 `get-task-allow` 的包、必被拒收），2c-4 改为 Release，`SchemeConfigurationGuardTests` 同时把 `TestAction` / `LaunchAction` 钉在 Debug（Release 会让运行与 app-hosted 测试落进生产容器）；②Release 签名——2c-5 写入 `CODE_SIGN_IDENTITY = "Apple Distribution"`、`CODE_SIGN_STYLE = Manual`、`PROVISIONING_PROFILE_SPECIFIER = "SoloLedger MAS 1.0.1"`（**只落 App 目标 Release**，工程级仍 `"-"`，故测试目标不需要证书），并入库 `App/ExportOptions.plist` 模板与 `scripts/archive-mas.sh`；**Team ID 不入库**，由脚本从 `SOLOLEDGER_TEAM_ID` 注入，`SigningConfigurationGuardTests` 钉住「`DEVELOPMENT_TEAM` 不落 pbxproj」与「任何被跟踪文件不得携带 Team-ID 形态的 token」；③编译覆盖——2c-6 起 `native-app` job 每个 PR 都编译一次 Release 构型（未签名、只 build），此前 Release 从未被任何检查编译过，只在归档上传那一刻才会暴露只在 Release 下才报的编译错误；④entitlements——2c-7 把两个 `.entitlements` 钉成**沙箱 entitlement 姿态的闭集**（Release 恰 `app-sandbox` + `files.user-selected.read-write` 两键、Debug 恰 Release + `get-task-allow`、共同键值相等），并钉住 pbxproj 两处 `CODE_SIGN_ENTITLEMENTS` 接线、文件存在、以及**拒绝条件化覆盖键**（`CODE_SIGN_ENTITLEMENTS[sdk=…]` 会被 Xcode 优先采用、把无条件键架空——实测该形状在场时守门曾 17/17 全绿，故补此条）；守门 `EntitlementsClosedSetGuardTests`，此前只有一句人工 grep 记录。**这份闭集证明到哪为止**：「无网络」被它锚住（沙箱下出网必须 `com.apple.security.network.client`，缺键则代码怎么写都出不去），**D7 出口合规只引这半边**；「无 AI／无 OCR／无 StoreKit」**不被它证明**——本地模型、on-device Vision、StoreKit 都不需要额外 entitlement，其 oracle 是源码本身（实测原生源码只 import AppKit / CSQLite / Charts / CryptoKit / Foundation / OSLog / SoloLedgerCore / SwiftUI / UniformTypeIdentifiers，`URLSession`／`Network`／`Vision`／`CoreML`／`StoreKit` 零命中，但**仓内无任何检查钉住这一点**，登记未做）。**尚未实跑过任何归档 / 导出**（需证书与 profile，属另行授权的一步；CI 不归档也不签名）。**MAS 不需 notarization**（Developer ID + notarization 属店外通道） |
| App Store Connect 元数据 / 截图 / 审核 | 🛑 **Release 前必须** | ASC App 记录已存在，1.0 于 2026-07-09 提交并被拒（五条 Guideline），此后未重提。**元数据 / 截图 / 隐私标签 / 出口合规 / 年龄分级在 1.0 提审时曾达可提交状态**（推论，非实查：未达则提交不会进入审核）；**它们在 ASC 的现状、以及原生重提所需的更新，本轮均未逐项实查**——描述 / 副标题 / 关键词 / 截图 / 隐私标签的口径都随「无 AI、无网络」而变，重提前须逐项核对，且只有维护者查得到。清单与两个核对维度见 [`MAS_SUBMISSION.md`](MAS_SUBMISSION.md) §4 |

## 6. 已移除 / 不做

| 功能 | 状态 | 备注 |
| --- | --- | --- |
| AI 助手 / BYOK / Provider | ❌ | 原生版永久不含 AI |
| 电商平台连接器（Shopify 等） | ⏸️ / ❌ | 无网络；暂不做 |
| 网络客户端 / OCR / StoreKit | ❌ | 不引入 |

---

## Release 前阻塞项清单（汇总）

1. ✅ 附件文件迁移（DB 之外的 `attachments/`）——主/自动 `.masContainer`、用户选目录、**以及 restore-from-backup** 三条链均迁附件（`BackupRestore.swift:7-9`），Core + **App 层端到端**测试均覆盖（`BackupRestoreTests.swift:132`）。**G1 已闭合**。
2. ✅ legacy `sales`/`purchases`：只读探针 + 诚实提示已上线（零写入），**转换器（2a-1…2a-4）亦已上线**。三处口径均按保守修正实现，报表口径切换等 9 条后果在转换前逐条明示（zh-Hans `legacy.convert.consequence.*` 的九条后果句），转换前强制生成可读备份，旧行零删改（见 §4 该行）。
3. ✅ 旧进程检测硬化：强指纹稳定性检测（前后指纹 + 3 次尝试）+ 可重试引导态"请退出旧版并重试"（`migration.msg.sourceBusy`，6 语）；App Sandbox 内进程枚举 / 取锁不可行，此为该环境下的正解。原 🛑 已过时。
4. ✅ 真实 Release 沙箱下的数据路径 / 升级端到端验证——2c-8（2026-08-15）在一次性 bundle id + Release entitlements ad-hoc 签名铸出的全新空容器里跑完矩阵：数据根落 `SoloLedgerNative`、纯探针启动零副作用、`.masContainer` 就地升级 v23→v24 数据逐字段完好、跨版本就地升级得到 `Backups/pre-migrate-v23-<ts>` 回滚点、附件迁移与 dangling 确认路径、源缺失 / 源损坏两条 fail-closed、自导入守卫的生产身份、真 Powerbox 五个面板、备份 → 恢复往返。**未验的三条（真实分发签名下的同一条链、归档 / 导出 / 上传、arm64-only 落差）见 §4 该行**，均不属本条阻塞项的定义范围。
5. ✅ **DMG（非沙箱）用户数据迁移入口**：N7.2 源选择入口已全链路接线（RootView → FilePanels → AppModel → coordinator `.requiresSourceChoice` / `.migrateFromUserDir` / `.userSelectedDataDir`）、single-grant-window 无 bookmark，Core + App-hosted 测试覆盖。**原 P0 已闭合**。
6. ✅ 用户可见的备份 / 恢复 UI——「设置 → 数据」的导出备份与从备份恢复已上线（`SettingsView` 的「设置 → 数据」按钮），恢复前先快照当前账本，legacy 转换进行中一律拒绝（`AppModel` 的恢复入口守卫）。
7. ✅ 完整 6 语言——六语各 650 键、键集完全一致，guard 强制恰好六个 `.lproj` 且各语键数相等（`LocalizationWordingGuardTests` 的 `testDiscoveredLocalesAreExactlyTheSixShippedLanguages` 与键数相等断言）。`.xcstrings` parity 仍推迟（`.strings` 对 MAS 可用，非阻塞）。键集合相等另由 `MigrationCopyParityTests.testFullLocaleKeyUniverseRatchet` 严格比对。
8. 🛑 MAS 签名 / 打包 / App Store Connect（Phase 4）。
9. ✅ 损益 / VAT / 所得税 / 现金流 / COGS 等敏感报表——已逐字**镜像** `electron/reports/*` 上线，入口已激活（`RootView` detail switch 的 `.reports` 分支）。**残留 ⏸️**：`electron/handlers/balanceOverview.js`（资产负债概览，246 行）**测绘已完成（2026-08-15），镜像章按用户裁定挂起**——阻塞在上游数据面而非镜像技术（连上游六个 handler 共 1027 行，其输入表有七张原生零写入，镜像出来只能部分填充；详见 §2 该行），**重开前提是先做 §3 的五个录入页**。`electron/handlers/inventory.js`（库存成本，89 行）**不是残留**——按 §2 的实测审计它不是加权平均法，已裁定不作为镜像对象，原生另写新引擎（N 章已收官）。

> 本表随每个阶段更新。**截至 2026-08-07**：生产启动链（C12a / C12b）+ 两条 active-store hardened open（C12x-A1 existing / A2 createFresh）+ DMG 源选择入口（N7.2）+ 附件文件迁移（三条链，G1 已闭合）均已落地；**报表引擎已全线镜像并激活入口**（逐字镜像 `electron/reports/*` 共 **930 行**敏感逻辑，非早前记载的 808 行）；**legacy `sales`/`purchases` 转换器（2a-1…2a-4）已上线**；**用户可见备份 / 恢复 UI 已上线**；六语文案已达成 650 键 parity；**原生库存引擎与库存页已上线（N 章 #452–#458 收官，侧栏入口已激活）**。**剩余发布阻塞项收敛为两条：#4 真实 Release 沙箱下的数据路径 / 升级端到端验证，#8 MAS 签名 / 打包 / App Store Connect。** 报表与转换器输出一律为管理分析口径的估算，不是法定财务报表，也不构成申报依据。
>
> **2026-08-16 定点订正**（只订正下列各项，本段其余论断未重新核验，故 08-07 的日期保留）：`electron/handlers/balanceOverview.js` 的状态由「尚未镜像」改为「**测绘已完成（2026-08-15），镜像章按用户裁定挂起**」，§2 的状态标记由 🟡 改为 ⏸️，§3 的五个录入页行补上「是该章前提」的交叉引用。**这不是把一件待办改成另一件待办**：挂起的依据是测绘实测的上游数据面（输入表七张原生零写入，镜像出来只能部分填充、且残差会被显示成「待调整项」），不是排期。上句「剩余发布阻塞项……」不受影响——该章从来不在发布阻塞清单里。
>
> **2026-08-15 定点订正**（只订正下列各项，本段其余论断未重新核验，故 08-07 的日期保留）：**第 4 条阻塞项已由 2c-8 关闭**，故上句「收敛为两条」应读作**只剩 #8 MAS 签名 / 打包 / App Store Connect**；§4 的「Release 数据路径验证」「附件文件迁移」「迁移前快照与两条恢复语义」三行按实测结果改写。本轮只做验证与入档，**不改任何非文档文件**；矩阵里发现的三条未验事项（真实分发签名下的同一条链、归档 / 导出 / 上传、Release 产物仍是双 slice 与 D4 arm64-only 的落差）如实登记在 §4 该行，不在本轮修。
>
> **2026-08-10 定点订正**（只订正下列三项，本段其余论断未重新核验，故 08-07 的日期保留）：六语键数由 645 改为实测的 **650**（三处，本表 §1、本清单第 7 条与本段各一）；§5「MAS 签名」一行原写「无生产证书」，与实测相反，已改写为「证书与 profile 均在位，缺的是工程配置」；§5「App Store Connect」一行原写「未做」，已按 ASC 实查补上「记录已存在、1.0 被拒、未重提」。
