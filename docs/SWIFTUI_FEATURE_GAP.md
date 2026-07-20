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
| 6 语言 UI | 🟡（架构就绪） | zh-Hans + en 完整；zh-Hant/ja/ko/fr 部分槽位 |
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
| **附件文件迁移**（`attachment_path` 指向的本地文件 + 备份 bundle 的 `attachments/`） | 🛑 **Release 前必须** | 数据升级目前只迁 DB，不迁附件 |
| **legacy `sales`/`purchases` → `transactions` 二次数据迁移** | 🛑 **Release 前必须** | Electron 侧的旧表转换未在原生侧复现（只读保留） |
| **旧进程检测硬化** | 🛑 **Release 前必须** | 现仅靠文件指纹变化；沙箱内无法枚举进程/取锁——需更强握手或"请退出旧版"引导 |
| **Release 数据路径验证** | 🛑 **Release 前必须** | `SoloLedgerNative`（Release）已加路径隔离单测；需在**真实 Release 沙箱**端到端验证 |
| **DMG（非沙箱）用户数据迁移入口** | 🛑 **Release 前必须（P0）** | `.masContainer` 只覆盖 Electron-MAS 容器；DMG 数据在容器外的 `~/Library/Application Support/SoloLedger/`，MAS 沙箱无授权够不到。`.userSelectedDataDir` 管道齐备但无目录选择入口。须在 createFresh **之前**加 single-grant-window 授权（不加 bookmark entitlement）；设计先行经确认（N7）。见 `SWIFTUI_MIGRATION_PLAN.md` §0.2 / §0.3 |
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

1. 🛑 附件文件迁移（DB 之外的 `attachments/`）。
2. 🛑 legacy `sales`/`purchases` → `transactions` 二次数据迁移。
3. 🛑 旧进程检测硬化（超出文件指纹）。
4. 🛑 真实 Release 沙箱下的数据路径 / 升级端到端验证。
5. 🛑 **DMG（非沙箱）用户数据迁移入口**：MAS 沙箱当前够不到 DMG 数据目录（容器外的 `~/Library/Application Support/SoloLedger/`）；须在 createFresh 前加 single-grant-window 目录授权（不加 bookmark entitlement）。设计先行经确认（N7）。
6. 🛑 用户可见的备份 / 恢复 UI。
7. 🛑 完整 6 语言 + `.xcstrings` parity。
8. 🛑 MAS 签名 / 打包 / App Store Connect（Phase 4）。
9. 🟡（发布前应补）损益/税务/VAT 等敏感报表——**镜像** Electron，不重造。

> 本表随每个阶段更新。**截至 2026-07-20 已落地至 2B-3 / C12x-A2**：生产启动链（C12a / C12b）+ 恢复 UI + 两条 active-store hardened open（C12x-A1 existing / A2 createFresh）。当前发布前 P0 见第 4 节「DMG（非沙箱）用户数据迁移入口」及 `SWIFTUI_MIGRATION_PLAN.md` §0。
