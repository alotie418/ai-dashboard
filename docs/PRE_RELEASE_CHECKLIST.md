# 发布前安全与发布准备清单（Pre-Release Checklist）

> 状态：**盘点记录 / 不启用任何发布功能（NO RELEASE FEATURE ENABLED）**
> 文档日期：2026-06-26 ｜ 基线：main HEAD `98879c4`（🟢×17）
> **状态更新：2026-07-07 ｜ 基线 main `3fc241e`** —— §2 的「Electron 33 已 EOL」「CSP 尚未 enforce」两项 blocker 已解决（#348 / #349）；sandbox 已加固为 true（#343）；新增 §5「2026-07 工程体检执行记录（#350–#353）」。
> **状态更新 2（PR-C 后）**：**签名/公证已完成**（#355 + PR-C 真机执行成功，见 §2 表与 [`RELEASE.md`](RELEASE.md) §9）——**对外分发已无硬 blocker**。
> **状态更新 3（2026-07-08·RC QA 进行中）**：`v1.0.0-rc.1` 已发 GitHub Pre-release；RC 人工 QA **1/2/3 项通过**（断网 Gatekeeper 首启·首启跳过 AI·断网基础功能），**QA-4 Excel 导入曾失败 → #357 修复并真机复测通过**；当前版本 **1.0.0-rc.2 准备中**（把 #357 交付到可下载构建，需重跑签名/公证）。正式 1.0.0 门槛 = §5 第 5/6 条（Woo 真店 + safeStorage 重录）。
> **状态更新 4（2026-07-08·1.0.0 正式版准备）**：`v1.0.0-rc.2` 已发 Pre-release；**QA-6 safeStorage 通过**（rc.2 覆盖安装实测·(a) 分支：钥匙串授权后旧 AI Key 直接可用·零崩溃/白屏/原始报错·业务数据完好·电商旧凭证路径 N/A 无旧数据可测）；**Woo 真店 QA 按决策 B 降级为「Beta / 发布后验证项」**（不作本地财务核心 blocker，README / CHANGELOG / ECOMMERCE_MVP_STATUS §8 已同步标注）。**本地财务核心的 1.0.0 发布门槛已全部闭合**，版本 **1.0.0 正式版准备中**。
> 本文件仅固化一次只读盘点结果与后续计划，**不改变任何产品行为、不改任何代码 / 配置**。

本文档把「发布前安全与发布准备」的只读盘点整理为可追踪清单：已达标项、对外分发 blocker、不属 blocker 的项、后续任务顺序、人工 QA 清单。~~当前**没有**启用签名 / 公证 / auto-update / CSP enforce。~~（2026-07-07：CSP 已 enforce #349；**签名 + 公证已启用并真机验证**（#355 + PR-C）；auto-update 仍未做——local-first 有意决策。）

---

## 1. 当前已达标项（无需改动）

### 1.1 Electron 运行时安全（`electron/main.js`）
- [x] `contextIsolation: true`
- [x] `nodeIntegration: false`
- [x] `webSecurity` 未覆盖 → 默认开启
- [x] `allowRunningInsecureContent` 未设 → 默认 false
- [x] 无 `@electron/remote` / 未启用 remote module
- [x] 外链：`setWindowOpenHandler → { action: 'deny' }` + 仅 https 走 `shell.openExternal`
- [x] `will-navigate`：拦截非「应用内」（dev `http://localhost:3000` / prod `file://`）整页跳转，https 外链转系统浏览器
- [x] DevTools 仅在 `isDev`（`!app.isPackaged`）打开，生产不开
- [x] 单实例锁（`requestSingleInstanceLock`）防第二实例并发写 SQLite

### 1.2 preload 暴露面（`electron/preload.js`）
- [x] `contextBridge.exposeInMainWorld('electronAPI', { invoke, platform, isElectron })` —— 暴露面极小
- [x] 真正的 channel 白名单在 **main 侧 router** 强制（preload 仅转发 `invoke`）

### 1.3 网络 / 隐私
- [x] `check:offline` Findings 0 —— 运行时无 CDN / 远程资源，完全离线自托管
- [x] 无 telemetry / analytics / crashReporter / autoUpdater / phone-home / 磁盘日志
- [x] AI 请求在 **main 进程** 发起（BYOK，用户主动触发），不经任何自家服务器
- [x] 外链仅 https 转系统浏览器；favicon 为内联 data: SVG（不联网）

### 1.4 数据 / Key
- [x] AI provider Key：`safeStorage` 加密 → base64 → `ai_providers.api_key_encrypted`，**仅 main 进程解密**、不回传渲染端
- [x] 业务数据本地 SQLite（`userData/sololedger.db`），无云账户 / 无服务器存储
- [x] 备份 / 隐私说明（README「数据与隐私」节 + `PRIVACY.md` / `PRIVACY.en.md`）与实现一致：手动备份 bundle = DB + `attachments/docs`；覆盖性操作前在 `userData/backups` 自动备份

---

## 2. 当前发布前 blocker

| Blocker | 级别 | 说明 |
|---|---|---|
| ~~对外分发缺签名 + 公证~~ | ✅ **已解决（#355 + PR-C·2026-07-07）** | `electron-builder.dmg.yml` `identity:null` / `hardenedRuntime:false` / 无 notarize。只读实施方案已固化于 [`SIGNING_NOTARIZATION_PLAN.md`](SIGNING_NOTARIZATION_PLAN.md)：electron-builder 25.1.8 **内建** `mac.notarize:true`（免 afterSign，凭证走 `APPLE_ID`/`APPLE_APP_SPECIFIC_PASSWORD`/`APPLE_TEAM_ID` 环境变量）+ `hardenedRuntime:true` + 最小 entitlements（`allow-jit`+`allow-unsigned-executable-memory`，`disable-library-validation` 仅 .node 加载失败时补）。**排在 Electron 43 + CSP 之后（发布线最后一步）**；Apple 账号可现在并行注册；safeStorage 换签名后旧 Key 需重录。**当前作为「本地自用未签名 DMG」是自洽的。**（**PR-C 执行成功·2026-07-07**：PR-B #355 接线后真机执行——App Developer ID 签名 ✓ · Apple notarization successful · DMG notarytool **Accepted** · `stapler validate` 通过 · 安装到 /Applications 后 `spctl accepted (source=Notarized Developer ID)` + `codesign` valid + 正常打开；最小 entitlements 两项够用，**无需** disable-library-validation；safeStorage 重录用户须知已入 CHANGELOG。已知非阻塞：DMG 自身 `spctl --type open/install` 显示 rejected/no usable signature——DMG 本体未单独 codesign，但公证票据已 staple 且 DMG 内与安装后 App 均过 Gatekeeper。实测记录见 [`RELEASE.md`](RELEASE.md) §9。） |
| ~~Electron 33 已 EOL~~ | ✅ **已解决（#348·2026-07-06）** | 已升 **Electron 42.6.0 + better-sqlite3 12.11.1**（按 [`ELECTRON_UPGRADE_ASSESSMENT.md`](ELECTRON_UPGRADE_ASSESSMENT.md) 的「分阶段回退」过渡路径）。E42 EOL 2026-10-20。**E42→E43 再 bump 等 better-sqlite3 12.11.2 上 npm**（截至 2026-07-07 npm latest 仍为 12.11.1，仅 GitHub tag）——有界止损决策待定：超期则带 E42 直接进入签名/公证。 |
| **arm64-only** | 🟡 分发覆盖决策 | `mac.target.arch: arm64`。Intel 用户无包；`universal` 或 Intel 属分发决策。 |
| ~~CSP 尚未 enforce~~ | ✅ **已解决（#349·2026-07-06）** | 生产构建注入 meta CSP（仅 build·Vite `transformIndexHtml`）+ `check:csp` 守卫入 `check:all`；file://+CSP 真机验收零违规。方案与逐条依据见 [`CSP_PLAN.md`](CSP_PLAN.md)。 |
| **干净机断网 DMG 冒烟未验收** | 🟠 需人工 | Gatekeeper 右键打开 + 离线启动 + 核心流程，只能人工验证（见 §6）。 |

---

## 3. 不属于 blocker 的项目

- ~~**`sandbox: false`**~~ ✅ **已加固（#343·2026-07-05）**：主窗口已开启 `sandbox: true`（preload 仅用 contextBridge / ipcRenderer / process.platform，均为 sandbox 可用能力，无需改造）。
- **preload generic `invoke`**：preload 层不做 channel allow-list；**main 侧 router 才是真正的 channel 白名单 / 安全闸门**。属可选加固，**非 blocker**。
- **auto-update 未做**：`electron-updater` 未安装、`publish:null` 显式关闭。这是 **local-first 产品决策**，不是 blocker；是否做需产品定夺。

---

## 4. 推荐后续任务顺序

> 每项开做前各自先只读评估 / 细化，再按低风险小 PR 实施。涉及人工的项见 §6。

1. **Electron 升级**：✅ **已实施（#348·E42 过渡，2026-07-06）**；E43 再 bump 待 better-sqlite3 12.11.2 上 npm 的止损决策（见 §2 表）。
2. **CSP PR-2**：✅ **已实施（#349·2026-07-06）**——生产构建注入 meta CSP + `check:csp` 守卫 + file:// 真机验收零违规。
3. **签名 / 公证**：✅ **已完成**——PR-B 接线（#355）+ PR-C 真机执行成功（2026-07-07：notarization successful / stapler validate 通过 / 安装后 spctl accepted）。实测记录见 [`RELEASE.md`](RELEASE.md) §9。
4. **arch universal / Intel 决策**：是否构建 universal 或 Intel 包。产品决策。
5. **是否做 auto-update 决策**：local-first 可不做；若做需先具备签名 + 发布通道。产品决策。
6. **干净机断网 DMG 人工冒烟**（见 §6）。

---

## 5. 2026-07 工程体检执行记录（2026-07-07 增补）

2026-07-06 全项目只读体检产出 P0–P3 清单后，以下工程项已合并至 main（基线 `3fc241e`）：

| PR | 内容 | 验证结果 |
|---|---|---|
| #350 | `@google/genai` 1.40.0→1.52.0，清理生产依赖链 protobufjs(critical) / ws / minimatch / brace-expansion 漏洞通告 | `check:agent-providers` / `check:providers` / `check:ai-errors` 全过；生产 audit 6→1 |
| #351 | Onboarding 无 AI Key 可跳过——AI Key 不再阻塞首启；完成/跳过持久化为 localStorage `sololedger-onboarding-done`；无 Key 时 AI 入口沿用既有 `aiError.noProvider` 引导 | `test:locale-ui` 311 passed（36/36 组合零回归 + 新增 3 条） |
| #352 | `xlsx` 0.18.5（npm registry 已弃更）→ SheetJS 官方 CDN tarball **0.20.3**；业务代码零改动、`.xls` 支持保留、0 传递依赖 | **`npm audit --omit=dev` = 0 vulnerabilities**；`check:all` / build / `test:locale-ui` 全过；CI `npm ci` 可达 cdn.sheetjs.com 已实证（#352/#353 CI 均 success） |
| #353 | 备份/恢复 IPC 闭环 e2e（`e2e-electron/backup-restore-ipc.spec.ts` 8 条：导出前 checkpoint 实证 / round-trip / 恢复前安全网 / 旧 wal-shm 清理 / 附件只增不删合并 / 恢复后真 api:request 可读 / 启动 autoBackup wiring） | `test:electron` 26 passed；未发现产品 bug |

**#352 遗留的已知代价（非 blocker，需持续注意）**：`npm ci` 安装期需可达 `cdn.sheetjs.com`（lockfile integrity 锁内容、不锁可用性）；URL 依赖对 Dependabot / Renovate 不可见，SheetJS 后续版本需人工跟进。

**剩余发布前事项（更新于 2026-07-07·PR-C 执行后）**：

1. ~~签名 / 公证（PR-B/PR-C）~~ ✅ **已完成**：PR-B #355 接线 + PR-C 真机执行成功（2026-07-07），见 §2 表与 [`RELEASE.md`](RELEASE.md) §9。
2. ~~E43 / better-sqlite3 12.11.2 决策~~ ✅ **决策已定（2026-07-07）**：不等 12.11.2 上 npm，按 **E42 直接发布**；E43 留作发布后例行 re-bump。
3. **版本策略**：✅ 版本纪律已建立（rc.1 → **rc.2** 滚动，CHANGELOG 逐版记录 + tag 对应）；「检查更新」入口**暂缓**——发布渠道事实上已定 GitHub Releases，链接入口留 1.0.0 后小 PR。
4. ~~xlsx 真实 `.xlsx` / `.xls` 导入人工冒烟~~ ✅ **已完成（rc.2 / #357 后）**：RC QA 首测发现日期单元格序列数缺陷（rc.1 阻塞）→ #357 修复 → 真机真实文件复测通过（销售×.xlsx + 采购×.xls，DB 实查各 11 条；0 金额行按设计拦截）。
5. **WooCommerce / Shopify 真实店铺人工 QA**：**决策 B（2026-07-08）——降级为「Beta / 发布后验证项」**，不作 1.0.0 blocker（不标通过也不标失败）；模块以 Beta 标注随 1.0.0 发布，待真实店铺可用后照 [`ECOMMERCE_WOO_REAL_STORE_QA.md`](ECOMMERCE_WOO_REAL_STORE_QA.md) 逐项回填。
6. **干净机断网 Gatekeeper 冒烟**：✅ **已完成（2026-07-08·同机模拟口径）**——单机策略：同一台 Mac 新建标准用户 SoloLedgerQA，浏览器下载 rc.1 DMG（带 quarantine）→ 断网 → 装入 `~/Applications` → 直接打开无任何 Gatekeeper 拦截；残余差距：同机共享系统级 Gatekeeper 缓存，非真·第二台干净机。**safeStorage 重录 QA（QA-6）：✅ 已完成（2026-07-08·开发用户·rc.2 覆盖安装）**——S1 覆盖安装无 Gatekeeper 提示 ✓ / S2 AI 旧 Key 解密走 **(a) 分支**（钥匙串授权后直接可用）✓ / S3 电商旧凭证 **N/A**（从未保存过电商凭证、无旧数据；底层机制与 AI Key 同源同钥匙串条目，已由 S2 覆盖；真实电商凭证功能验证并入第 5 条 Woo 项）/ S4 退出重开凭证持久 ✓ / S5 业务数据完好 ✓；零崩溃 / 白屏 / 无限转圈 / 原始英文报错。

---

## 6. 人工 QA 清单（打包 / 分发验收前必跑）

> 这些项**只能人工**完成（真机 / 真打包 / 真离线）。

- [x] 打包 DMG：`npm run build:dmg` 产出签名+公证+staple 的 DMG（PR-C·2026-07-07，非 iCloud 路径 checkout）
- [x] 干净机启动：✅ 2026-07-08 同机模拟口径——新建标准用户 SoloLedgerQA、浏览器下载 DMG（带 quarantine）、装入 `~/Applications` 首启成功；首启跳过 AI 配置进入主界面、重开不再弹向导（QA-1/QA-2）。残余差距：非第二台真机（共享系统级 Gatekeeper 缓存）
- [x] Gatekeeper 打开流程：签名+公证版直接双击打开，无「无法验证开发者/已损坏」拦截（开发用户 2026-07-07 + QA 用户断网 2026-07-08 双确认）
- [x] 断网启动：✅ QA 用户断网安装+启动+基础记账页面可用；无 Key 时 AI 入口为本地化配置引导，无白屏/崩溃（QA-1/QA-3·2026-07-08）
- [ ] 核心页面：看板 / 采购 / 销售 / 库存 / 发票 / 单据 / 财务 / 数据分析 / 设置 / US 税务工具 / 助手页 全部正常渲染（QA-3 已覆盖断网下基础页面；**全页面矩阵逐页人工过一遍仍待**）
- [ ] AI provider 配置与调用：填入真实 Key → 测试连接 → 助手对话 / 看板简报正常（联网时）
- [ ] PDF OCR：上传 PDF → 本地栅格化 → OCR 回填预览全链路
- [x] CSV / xlsx **导入**：✅ 真实 `.xlsx`（销售）与 `.xls`（采购）复测通过（**rc.2 / #357 后**·真 Electron+生产构建+真 SQLite·DB 实查各 11 条·0 金额行按设计拦截·零日期错误）。⚠️ 曾在 rc.1 阻塞（日期序列数缺陷）。**导出下载的人工验证仍待**（`check:csv-export` 自动化已覆盖导出逻辑）
- [ ] 备份与恢复：手动备份导出 bundle（含 DB + attachments）→ 恢复 → 数据 + 附件完整（**#353 真 Electron e2e 已全链路自动化覆盖·人工复验可选**，不作 1.0.0 硬门槛）
- [ ] 附件打开：单据附件经 IPC `shell` 打开外部正常
- [ ] DevTools 检查：打包应用如可开 DevTools，确认控制台无安全相关报错（CSP / 混合内容 / 越权 IPC 等）

---

## 7. 边界声明

- 本文件**不启用任何发布功能**（不启用签名 / 公证 / auto-update / CSP enforce），**不改变产品行为**。
- 本 PR 仅新增本文档；未改 `package.json` / `electron-builder.dmg.yml` / Electron `main` · `preload` · renderer / `index.html` / `vite.config.ts` / CSP / AI provider / Key 存储 / 文件处理 / 会计 · 税务 · 报表 · handler · schema · seed · audit。
- 实际发布动作（签名 / 公证 / Electron 升级 / CSP enforce / arch / auto-update）均待后续单独评估 + 实施 + 人工验收。

---

*相关文档：[README](../README.md) ｜ [PRIVACY](../PRIVACY.md) ｜ [Electron 升级评估](ELECTRON_UPGRADE_ASSESSMENT.md) ｜ [签名/公证方案](SIGNING_NOTARIZATION_PLAN.md) ｜ [CSP 计划](CSP_PLAN.md) ｜ [test:locale-ui 工作流](TESTING_LOCALE_UI.md) ｜ [产品路线图](ROADMAP-to-v1.md)。本文件为工程盘点记录，非安全合规认证。*
