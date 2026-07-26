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
| Electron → SwiftUI 数据升级 | ✅ | `DatabaseUpgrade`（备份/完整性/原子切换/回滚/阻塞恢复） |
| 6 语言 UI | 🟡（架构就绪） | zh-Hans + en 完整（各 199 键）；zh-Hant/ja/ko/fr 各缺同一批 **24 键**（`settings.*` 14 + `recovery.*` 10），缺失时回退 **zh-Hans**（非 en）；仍为 `.strings`（无 `.xcstrings`）。locale guard 现只强制 `migration.*` 全 6 语齐 |
| 深色模式 | ✅ | 原生新增（Electron 仅浅色） |
| 类别管理（增删改） | 🟡 | 目前只读浏览 |

## 2. 会计 / 报表（敏感逻辑——只镜像）

| Electron 功能 | 状态 | 备注 |
| --- | --- | --- |
| 损益表 / P&L | 🟡 | 需按 `electron/reports/*` 精确镜像；未做 |
| VAT / GST / 销售税汇总 | 🟡 | 敏感，镜像；未做 |
| 所得税 / 附加税估算 | 🟡 | 敏感，镜像；未做 |
| 现金流 / 资产负债（PR-7B） | 🟡 | 敏感，镜像；未做 |
| COGS / `_expenseSplit` / 库存成本 | 🟡 | 敏感，镜像；未做 |
| 折旧预览 / 里程 / 家庭办公室 | ⏸️ | 特定制度，暂缓 |

## 3. 单据 / 主数据

| Electron 功能 | 状态 | 备注 |
| --- | --- | --- |
| 发票 / 报价单 / 商业单据（`business_documents`） | ⏸️ | 暂缓（Phase 3） |
| 产品 / 服务项（`products`） | ⏸️ | 暂缓 |
| 客户 / 供应商 | 🟡 | 目前 `counterparty` 为自由文本 |
| 现金/银行账户、负债、固定资产、权益、税费台账（策略中立） | ⏸️ | 暂缓 |

## 4. 数据安全 / 迁移（多为 Release 阻塞）

| 功能 | 状态 | 备注 |
| --- | --- | --- |
| 用户可见备份 / 恢复 UI | 🟡 | 升级已自动备份；面向用户的备份/恢复入口未做 |
| **附件文件迁移**（`attachment_path` 指向的本地文件 + 备份 bundle 的 `attachments/`） | ✅ 主迁移路径 ／ 🟡 restore 恢复路径 | 主/自动 `.masContainer` + 用户选目录导入链**已迁附件**（`AttachmentApply` → `PreparedImportFinalizer`：逐字保留 `attachment_path`、SHA-256 校验、add-only 不覆盖）；Core 链测试 + **App 层端到端**（`ElectronFixtureProductionOpenTests`，本次新增）均覆盖。原"只迁 DB 不迁附件"实为已停用的 `DatabaseUpgrade`（非生产启动路径）。**仅 restore-from-backup 恢复路径尚不迁附件（G1，单列残留，非本次范围）** |
| **legacy `sales`/`purchases` 数据的可见性** | ✅（诚实提示已上线） | 只读探针 `LegacyLedgerProbe` 用与 Electron 转换器相同的反连接（`LEFT JOIN legacy_migrations … WHERE m.id IS NULL`）统计未转换行，空态改为如实告知"账本有 N 条旧版销售/采购记录、数据完好、本 App 尚未提供转换"。**零写入**。同时覆盖其他原生不读的记录表（发票/产品/固定资产等），并据此关闭"看似空账本"时的 DEBUG 演示数据入口 |
| **legacy `sales`/`purchases` → `transactions` 转换器** | 🛑 **需会计确认后再做**（非 Release 阻塞，已降级） | 逐字移植 `electron/handlers/migrations.js` 会**实质改变已有期间的报表呈现**：报表引擎按期间在 transactions/legacy 间二选一，转换后 CN 运费归 0、COGS/毛利拆分翻转、US 采购全部落到 Schedule C line 8（美国类别无 `cogs` slug）。另有三处口径需确认，用户已定调为**保守修正**：①旧表 `payment_status` 为空时保留列默认 `unpaid`（不照抄 Electron 写死 `paid`）②默认收/支类别改为转换前由用户显式选择（Electron API 本就支持 `defaultIncomeCategoryId`/`defaultExpenseCategoryId`）③多行明细（`sales_items`/`purchase_items`）塌缩为单条流水的损失必须在转换前明示。移植时还须修掉 Electron 侧的已知缺陷：先写映射再写流水（避免孤儿行导致重复迁移）、rollback 分批删除（>32766 行会触发 SQLite 变量上限）、转换前自动备份 |
| **旧进程检测硬化** | ✅（沙箱内正解已达成） | 生产 ingest 用**强指纹稳定性**检测（前后指纹 + 3 次尝试，`StagingIngest`）——旧版仍在写则拒，映射为**可重试态** `.retriable(.sourceBusy)`（`MigrationCoordinator.swift:1104`）并显示引导消息 `migration.msg.sourceBusy`（"请退出旧版 SoloLedger 后重试"，6 语齐全）+ Retry 动作。**App Sandbox 内无法枚举进程 / 取跨进程锁**，指纹 + 引导退出即该环境下的正解。原 🛑 标记已过时 |
| **Release 数据路径验证** | 🛑 **Release 前必须** | `SoloLedgerNative`（Release）已加路径隔离单测；需在**真实 Release 沙箱**端到端验证 |
| **DMG（非沙箱）用户数据迁移入口** | ✅（N7.2 已闭合） | 源选择入口已全链路接线并测试：coordinator `.requiresSourceChoice`（`MigrationCoordinator.swift:668`）→ `.awaitingSourceChoice` → RootView `.chooseSource`（`RootView.swift:76`）→ 目录面板（`FilePanels.swift:58`）→ `.migrateFromUserDir(.userSelectedDataDir)`（`AppModel.swift:189,339`）。single-grant-window、无 bookmark entitlement（`MigrationSource.withAccess`）。测试：`DormantSourceChoiceBootTests`、`ElectronFixtureProductionOpenTests`。**原 🛑 P0 标记已过时** |
| 加密列（`ai_providers`/`ecommerce_connections`，safeStorage 密文） | ❌ | 跨应用不可移植；原生无 AI/电商，不迁移 |

## 5. 打包 / 发布（Phase 4）

| 功能 | 状态 | 备注 |
| --- | --- | --- |
| 真正的 Xcode 工程 | ✅ | `App/SoloLedger.xcodeproj`（Phase 1.5） |
| **MAS 签名**（Apple/Mac App Distribution + Mac Installer Distribution + MAS provisioning profile） | 🛑 **Release 前必须** | 目前仅 Debug ad-hoc；无生产证书。**MAS 不需 notarization**（Developer ID + notarization 属店外通道） |
| App Store Connect 元数据 / 截图 / 审核 | 🛑 **Release 前必须** | 未做 |

## 6. 已移除 / 不做

| 功能 | 状态 | 备注 |
| --- | --- | --- |
| AI 助手 / BYOK / Provider | ❌ | 原生版永久不含 AI |
| 电商平台连接器（Shopify 等） | ⏸️ / ❌ | 无网络；暂不做 |
| 网络客户端 / OCR / StoreKit | ❌ | 不引入 |

---

## Release 前阻塞项清单（汇总）

1. ✅ 附件文件迁移（DB 之外的 `attachments/`）——主/自动 `.masContainer` + 用户选目录导入链已实现，Core + **App 层端到端**测试均覆盖；**仅 restore-from-backup 恢复路径尚不迁附件（G1，单列残留，非本次 PR 范围）**。
2. ✅ legacy `sales`/`purchases` 数据不再被呈现为"空账本"——只读探针 + 诚实提示已上线（零写入）。**转换器本身降级为非 Release 阻塞**：它会改变已有期间的报表呈现，且有三处口径待会计确认（见 §4 该行）。
3. ✅ 旧进程检测硬化：强指纹稳定性检测（前后指纹 + 3 次尝试）+ 可重试引导态"请退出旧版并重试"（`migration.msg.sourceBusy`，6 语）；App Sandbox 内进程枚举 / 取锁不可行，此为该环境下的正解。原 🛑 已过时。
4. 🛑 真实 Release 沙箱下的数据路径 / 升级端到端验证。
5. ✅ **DMG（非沙箱）用户数据迁移入口**：N7.2 源选择入口已全链路接线（RootView → FilePanels → AppModel → coordinator `.requiresSourceChoice` / `.migrateFromUserDir` / `.userSelectedDataDir`）、single-grant-window 无 bookmark，Core + App-hosted 测试覆盖。**原 P0 已闭合**。
6. 🛑 用户可见的备份 / 恢复 UI。
7. 🛑 完整 6 语言（zh-Hant/ja/ko/fr 各缺 24 键 `settings.*`+`recovery.*`，缺失回退 zh-Hans）。`.xcstrings` parity 推迟（`.strings` 对 MAS 可用，非阻塞）。
8. 🛑 MAS 签名 / 打包 / App Store Connect（Phase 4）。
9. 🟡（发布前应补）损益/税务/VAT 等敏感报表——**镜像** Electron，不重造。

> 本表随每个阶段更新。**截至 2026-07-25**：生产启动链（C12a / C12b）+ 两条 active-store hardened open（C12x-A1 existing / A2 createFresh）+ **DMG 源选择入口（N7.2，原 P0 已闭合）** + **附件文件迁移（主/自动 + 用户选目录，含 App 层端到端）** 均已落地。**当前推进目标：MAS 可提交，只清发布阻塞项；报表引擎（P&L/VAT/所得税/现金流/COGS，808 行敏感逻辑）本轮推迟——须逐字镜像 `electron/reports/*` + 专业复核，单独一条线做，不阻塞发布主线。**
