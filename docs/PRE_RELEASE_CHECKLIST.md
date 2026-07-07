# 发布前安全与发布准备清单（Pre-Release Checklist）

> 状态：**盘点记录 / 不启用任何发布功能（NO RELEASE FEATURE ENABLED）**
> 文档日期：2026-06-26 ｜ 基线：main HEAD `98879c4`（🟢×17）
> **状态更新：2026-07-07 ｜ 基线 main `3fc241e`** —— §2 的「Electron 33 已 EOL」「CSP 尚未 enforce」两项 blocker 已解决（#348 / #349）；sandbox 已加固为 true（#343）；新增 §5「2026-07 工程体检执行记录（#350–#353）」。**签名/公证是当前唯一的对外分发硬 blocker。**
> 本文件仅固化一次只读盘点结果与后续计划，**不改变任何产品行为、不改任何代码 / 配置**。

本文档把「发布前安全与发布准备」的只读盘点整理为可追踪清单：已达标项、对外分发 blocker、不属 blocker 的项、后续任务顺序、人工 QA 清单。~~当前**没有**启用签名 / 公证 / auto-update / CSP enforce。~~（2026-07-07：CSP 已 enforce #349；签名 / 公证 / auto-update 仍未启用。）

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
| **对外分发缺签名 + 公证** | 🔴 对外分发硬 blocker | `electron-builder.dmg.yml` `identity:null` / `hardenedRuntime:false` / 无 notarize。只读实施方案已固化于 [`SIGNING_NOTARIZATION_PLAN.md`](SIGNING_NOTARIZATION_PLAN.md)：electron-builder 25.1.8 **内建** `mac.notarize:true`（免 afterSign，凭证走 `APPLE_ID`/`APPLE_APP_SPECIFIC_PASSWORD`/`APPLE_TEAM_ID` 环境变量）+ `hardenedRuntime:true` + 最小 entitlements（`allow-jit`+`allow-unsigned-executable-memory`，`disable-library-validation` 仅 .node 加载失败时补）。**排在 Electron 43 + CSP 之后（发布线最后一步）**；Apple 账号可现在并行注册；safeStorage 换签名后旧 Key 需重录。**当前作为「本地自用未签名 DMG」是自洽的。**（**2026-07-07 更新**：前置已全部就绪——E42 #348 / CSP enforce #349 / sandbox:true #343，Apple 凭证已备；剩余 = E43/E42 止损决策 → `build/entitlements.mac.plist` → `dmg.yml` 接线 → 公证 → 干净机冒烟；**safeStorage 旧 Key 重录的用户须知**须随执行 PR 一并落地。） |
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
3. **签名 / 公证**：只读方案 **✅ 已出**（[`SIGNING_NOTARIZATION_PLAN.md`](SIGNING_NOTARIZATION_PLAN.md)——内建 `mac.notarize:true`+环境变量凭证+最小 entitlements）。**现在是发布线的下一步（唯一硬 blocker）**：前置（E42/CSP/sandbox）已全部就绪、Apple 凭证已备；执行门控 = E43/E42 止损决策。
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

**剩余发布前事项（截至 2026-07-07，均未完成）**：

1. **签名 / 公证（PR-B/PR-C）**——唯一对外分发硬 blocker；待 E43 止损决策后执行（见 §2 / §4）。
2. **better-sqlite3 12.11.2 是否上 npm 待确认**（npm latest 仍 12.11.1）——决定 E43 bump 还是带 E42 直接签名。
3. **版本策略待定（体检 P1-3）**：`version` 仍 0.1.0、CHANGELOG 为骨架、无「检查更新」入口。
4. **xlsx 真实 `.xlsx` / `.xls` 导入人工冒烟**（#352 解析器 0.18.5→0.20.3，见 §6 清单）。
5. **WooCommerce / Shopify 真实店铺人工 QA**（照 [`ECOMMERCE_WOO_REAL_STORE_QA.md`](ECOMMERCE_WOO_REAL_STORE_QA.md)）。

---

## 6. 人工 QA 清单（打包 / 分发验收前必跑）

> 这些项**只能人工**完成（真机 / 真打包 / 真离线）。

- [ ] 打包 DMG：`npm run build:dmg` 产出 `release/SoloLedger-<version>-arm64.dmg`
- [ ] 干净机启动：在未装过本应用的机器上安装并首次启动
- [ ] Gatekeeper 打开流程：未签名 → 右键「打开」过一次 Gatekeeper，确认可进入
- [ ] 断网启动：拔网 / 关 Wi-Fi 后启动，确认核心记账功能完全可用（验离线）
- [ ] 核心页面：看板 / 采购 / 销售 / 库存 / 发票 / 单据 / 财务 / 数据分析 / 设置 / US 税务工具 / 助手页 全部正常渲染
- [ ] AI provider 配置与调用：填入真实 Key → 测试连接 → 助手对话 / 看板简报正常（联网时）
- [ ] PDF OCR：上传 PDF → 本地栅格化 → OCR 回填预览全链路
- [ ] CSV / xlsx 导入导出：导入解析 + 导出下载正常（⚠️ #352 解析器 0.18.5→0.20.3：真实 `.xlsx` 与 `.xls` 文件各导入一次须重点冒烟）
- [ ] 备份与恢复：手动备份导出 bundle（含 DB + attachments）→ 恢复 → 数据 + 附件完整
- [ ] 附件打开：单据附件经 IPC `shell` 打开外部正常
- [ ] DevTools 检查：打包应用如可开 DevTools，确认控制台无安全相关报错（CSP / 混合内容 / 越权 IPC 等）

---

## 7. 边界声明

- 本文件**不启用任何发布功能**（不启用签名 / 公证 / auto-update / CSP enforce），**不改变产品行为**。
- 本 PR 仅新增本文档；未改 `package.json` / `electron-builder.dmg.yml` / Electron `main` · `preload` · renderer / `index.html` / `vite.config.ts` / CSP / AI provider / Key 存储 / 文件处理 / 会计 · 税务 · 报表 · handler · schema · seed · audit。
- 实际发布动作（签名 / 公证 / Electron 升级 / CSP enforce / arch / auto-update）均待后续单独评估 + 实施 + 人工验收。

---

*相关文档：[README](../README.md) ｜ [PRIVACY](../PRIVACY.md) ｜ [Electron 升级评估](ELECTRON_UPGRADE_ASSESSMENT.md) ｜ [签名/公证方案](SIGNING_NOTARIZATION_PLAN.md) ｜ [CSP 计划](CSP_PLAN.md) ｜ [test:locale-ui 工作流](TESTING_LOCALE_UI.md) ｜ [产品路线图](ROADMAP-to-v1.md)。本文件为工程盘点记录，非安全合规认证。*
