# CLAUDE.md

本文件固定项目定位与 Claude Code 在本仓库的工作边界。每个新会话开始前请先读完本文件，并在整个会话中遵守这里的约束。

---

## 1. 项目定位

- **本地 Electron 会计 / 经营管理桌面应用**：数据全部存放在用户本机，无云端后端依赖。
- 面向**小微企业、个体经营者、跨境卖家**。
- 核心能力：**本地记账、采购、销售、库存、发票、经营看板、辅助报表**。
- 多会计制度（accountingLocale：CN / US / JP / EU / KR / TW）× 多 UI 语言（zh-CN / zh-TW / en / ja / ko / fr）双轴解耦：会计口径只决定「用什么财务逻辑」，UI 语言只决定「用什么语言显示」，二者互不推导。
- AI 助手为 BYOK（自带 Key）多 provider，仅做**只读查账 / 票据 OCR / 经营分析辅助**，不替代会计判断。

## 2. 产品边界（这不是什么）

- **不是官方报税系统。**
- **不是审计级财务系统。**
- 报表为**经营管理口径的估算**，不是法定财务报表；**复杂会计 / 税务口径必须由用户或会计师人工确认**。
- AI 的回答、看板指标、辅助报表都用于经营管理参考，不构成报税、申报或合规依据。

## 3. 架构概要

- **本地优先**：Electron 主进程 + `better-sqlite3`（SQLite），凭据用系统 safeStorage，附件 / 备份均在本机。
- **前端**：React + Vite + Tailwind（`App.tsx` / `components/*` / `services/*` / `i18n/*`）。
- **后端**：`electron/handlers/*`，前端经 IPC（`api:request`）调用，**桌面唯一入口，无 Web fetch 兜底**。
- **报表引擎**：`electron/reports/*`；会计制度配置：`components/accountingProfiles.ts` / `accountingLocaleConfig.ts`。
- 旧 Web / 云端栈（Cloud Run / Cloudflare Worker / D1）已退役，历史代码归档在 `archive/web-legacy`（保留，勿删）。

## 4. 电商集成方向（后期）

- 后期可接入电商平台 API，但定位是**订单、费用、库存、结算等数据的导入 / 同步助手**。
- **不是自动税务合规引擎**：平台数据进来后仍按本地经营管理口径处理，税务 / 合规结论需人工确认。

## 5. 高风险禁区（点名才动）

以下涉及金额正确性与会计口径，**未经用户明确要求，任何任务都不得修改**；尤其禁止在文案 / 展示 / i18n PR 内顺手改动：

- 报表公式、税率、COGS（销售成本）口径
- inventory 成本计算（加权平均等）
- `accountingProfiles` / 会计制度配置
- `electron/reports/*` 报表引擎
- schema / migrations

这些改动需要会计师或用户明确确认；展示层 / 空状态 / 文案问题与会计口径问题必须严格区分。

## 6. 工作方式与 PR 流程

- **每个任务先只读分析**：先定位、确认范围，再动手。
- **小 PR 推进**：一任务一分支一 PR，只包含相关文件。
- **默认不 commit**；除非用户明确要求，先给改动 + 最小验证。
- **未经明确要求不要 merge**：合并由用户执行；合并后再做本地收尾（`git fetch --prune` → 快进 main → 删本地分支，`archive/web-legacy` 不删）。
- **git 远端操作仅在授权后执行，且不输出任何凭证 / Key。**
- 用户要求「审计 / 只读」时：只读不改代码、不 commit、出报告即停。

## 7. 验证命令

提交前按需运行（涉及哪类改动就跑哪些）：

- `npm run typecheck` — TypeScript 类型检查（`.ts` / `.tsx`）。
- `npm run check:all` — 守卫聚合（locale 矩阵、原始 key 泄漏、provider、报表标题、税率硬编码、磁盘错误等多项）。
- `npm run build` — Vite 生产构建。
- `npm run test:locale-ui` — `build` + Playwright e2e（注入 mock electronAPI 走 IPC）。
- `npm run check:handlers` — handler 往返测试。本机 `better-sqlite3` 为 Electron ABI 时会 **SKIP**（CI 会 rebuild 为 node ABI 真跑）；本机要真验证需 `npm rebuild better-sqlite3` → 跑 → `npm run electron:rebuild` 还原。

CI 仅跑 checks / e2e / typecheck；真 Electron e2e 为手动触发（`workflow_dispatch`）。
