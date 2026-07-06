# Changelog

本文件记录 SoloLedger（独账）对外可见的重要变更。
格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [语义化版本 SemVer](https://semver.org/lang/zh-CN/)。

> **状态说明**：应用当前处于**发布前（pre-release）**阶段——仅有本地自用、未签名/未公证的构建，尚未对外正式发布，故暂无 git tag。首个对外发布版将从这里开始逐版记录（届时打对应 tag）。
>
> 变更分类：`新增` / `变更` / `修复` / `移除` / `安全`。

---

## [Unreleased]

### 发布准备（进行中，尚未发布）
- 主窗口启用 `sandbox: true`（渲染进程纵深防御）。
- 新增专有 `LICENSE`（保留所有权利）。
- 文档：Electron 升级评估、CSP enforce 计划、macOS 签名/公证方案、电商 MVP 状态与 README 补全。

### 路线图（尚未开始 / 待授权）
- Electron 升级至 43 + `better-sqlite3` 12.x（耦合升级）。
- CSP enforce；代码签名 + 公证（对外分发前）。
- 详见 [`docs/PRE_RELEASE_CHECKLIST.md`](docs/PRE_RELEASE_CHECKLIST.md)。

---

## [0.1.0] — 发布前基线
- 本地自用、未签名的 Apple Silicon 构建基线。
- 覆盖本地记账 / 库存 / 发票 / 业务单据 / 财务概览 / AI 助手（BYOK 8 家）/ 电商订单导入 MVP。
- **非对外正式发布版本。**
