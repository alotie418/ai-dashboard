# Changelog

本文件记录 SoloLedger（独账）对外可见的重要变更。
格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [语义化版本 SemVer](https://semver.org/lang/zh-CN/)。

> **状态说明**：当前处于 **1.0.0 候选（RC）阶段**——已具备**签名 + 公证**的 Apple Silicon 构建（Developer ID · notarized · stapled）。正式 1.0.0 待 RC 剩余人工验收（见 1.0.0-rc.1 条目末尾）通过后发布。git tag 自 `v1.0.0-rc.1` 起逐版对应。
>
> 变更分类：`新增` / `变更` / `修复` / `移除` / `安全`。

---

## [Unreleased]

（暂无）

---

## [1.0.0-rc.2] — 2026-07-08

**仅包含一项修复**（#357）：Excel 导入日期解析。**RC 版本，非正式 1.0.0**。

### 修复
- **真实 `.xlsx` / `.xls` 导入：Excel 日期单元格不再显示为序列数（46174 等）**。导入解析启用 `cellDates` 并把日期单元格归一化为 `YYYY-MM-DD`（本地年月日分量，无时区偏移）；文本日期、金额/税额/数量解析、整批全或无逻辑均不变；金额为 0 的行仍按设计拦截（报"总金额须大于0"，不再误报日期错误）（#357）。

### 真实文件复测记录（真 Electron + 生产构建 + 真 SQLite）
- 原版 12 行 `.xlsx` / `.xls`：零日期错误，仅 0 金额行被拦截（整批全或无 → 导入按钮禁用，符合设计）；
- 去掉 0 金额行的 11 行 `.xlsx`（销售路径）与 `.xls`（采购路径）：导入成功，数据库实查各 11 条，日期全部 `YYYY-MM-DD`。

---

## [1.0.0-rc.1] — 2026-07-07

首个**签名 + 公证**的候选发布版本（Apple Silicon DMG）。**RC 版本，非正式 1.0.0**。

> ⚠️ **rc.1 已知问题**：导入真实 Excel 文件（`.xlsx`/`.xls`）时，日期单元格会被解析为序列数导致整批校验失败（"日期格式错误"）。已在 **1.0.0-rc.2**（#357）修复——测试者请改用 rc.2。

### 安全
- 运行时升级：Electron 33（已 EOL）→ **Electron 42.6.0** + better-sqlite3 12.11.1（#348）。
- 生产构建启用 **CSP enforce**：构建期注入 meta CSP + `check:csp` 守卫，file:// 真机验收零违规（#349）。
- 主窗口启用 `sandbox: true`（#343）。
- **生产依赖 `npm audit --omit=dev` 清零**：`@google/genai` → 1.52.0，清理 protobufjs（critical）/ ws / minimatch 等传递依赖通告（#350）；`xlsx` 由 npm registry 弃更版 0.18.5 换用 SheetJS 官方发行版 **0.20.3**，修复原型污染与 ReDoS（#352）。
- **macOS 代码签名 + 公证 + staple**：Developer ID Application 签名、Apple notarization successful、公证票据已 staple 至 DMG；安装后 Gatekeeper 直接放行（`spctl accepted / source=Notarized Developer ID`）（#355 + 真机执行验证，记录见 `docs/RELEASE.md` §9）。

### 新增
- 首次启动可**跳过 AI 配置**直接进入应用——AI Key 不再是使用门槛，可随时在「设置 → AI 服务商」添加；无 Key 时 AI 功能入口会给出配置引导（#351）。
- 备份 / 恢复链路新增真 Electron 端到端测试闭环（导出 / 恢复 / 恢复前安全网 / 附件合并 / 失败中止保旧库）（#353）。

### 重要须知（从未签名旧版升级的用户）
> 本版本启用了 macOS 代码签名与公证。由于系统钥匙串的加密密钥与应用签名身份绑定，升级后**此前保存的 AI 服务商 API Key 与电商平台凭证需要重新填写一次**（设置 → AI 服务商 / 电商连接）。
> **你的业务数据不受任何影响**：记账、采购、销售、库存、单据、报表、附件与备份全部原样保留，无需任何迁移操作。
> 若打开 AI 或电商功能时看到「无法解密凭证」类提示，按提示重新录入即可。

### RC 阶段剩余验收（1.0.0 正式版发布前完成）
- [x] 干净机断网 Gatekeeper 冒烟——2026-07-08 同机新用户模拟口径完成（详见 `docs/PRE_RELEASE_CHECKLIST.md` §6）
- [ ] safeStorage 旧 Key 重录流程 QA
- [x] xlsx 真实 `.xlsx` / `.xls` 文件导入冒烟——rc.1 发现日期缺陷，**rc.2（#357）修复并复测通过**
- [ ] WooCommerce 真实店铺 QA

---

## [0.1.0] — 发布前基线
- 本地自用、未签名的 Apple Silicon 构建基线。
- 覆盖本地记账 / 库存 / 发票 / 业务单据 / 财务概览 / AI 助手（BYOK 8 家）/ 电商订单导入 MVP。
- **非对外正式发布版本。**
