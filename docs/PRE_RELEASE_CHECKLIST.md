# 发布前安全与发布准备清单（Pre-Release Checklist）

> 状态：**盘点记录 / 不启用任何发布功能（NO RELEASE FEATURE ENABLED）**
> 文档日期：2026-06-26 ｜ 基线：main HEAD `98879c4`（🟢×17）
> 本文件仅固化一次只读盘点结果与后续计划，**不改变任何产品行为、不改任何代码 / 配置**。

本文档把「发布前安全与发布准备」的只读盘点整理为可追踪清单：已达标项、对外分发 blocker、不属 blocker 的项、后续任务顺序、人工 QA 清单。当前**没有**启用签名 / 公证 / auto-update / CSP enforce。

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
| **对外分发缺签名 + 公证** | 🔴 对外分发硬 blocker | `electron-builder.dmg.yml` `identity:null` / `hardenedRuntime:false` / 无 notarize 钩子（`@electron/notarize` 已装但零引用）。对外分发前必须补：Apple 账号($99/yr) + CSC/APPLE_ID secrets + afterSign notarize + `hardenedRuntime:true` + entitlements。**当前作为「本地自用未签名 DMG」是自洽的。** |
| **Electron 33 已 EOL（已核实）** | 🔴 安全 | 实装 33.4.11。**已核实 E33 EOL 2025-04-29**，至今约 14 个月无 Chromium 安全 backport → 升级非可选。只读评估已固化于 [`ELECTRON_UPGRADE_ASSESSMENT.md`](ELECTRON_UPGRADE_ASSESSMENT.md)：推荐目标 **Electron 43**；关键风险 = `better-sqlite3 11.10.0`（raw-V8，E41+ 无法编译）**强制耦合升到 12.x**；`@napi-rs/canvas`/pdf.js 绿灯；`electron-builder 25.1.8` 可用（可选升 26.x）。实施为 PR-2，需授权。 |
| **arm64-only** | 🟡 分发覆盖决策 | `mac.target.arch: arm64`。Intel 用户无包；`universal` 或 Intel 属分发决策。 |
| **CSP 尚未 enforce** | 🟡 纵深防御 | 已有 `docs/CSP_PLAN.md`（NOT ENABLED）。优先级**低于**签名与 Electron 升级。 |
| **干净机断网 DMG 冒烟未验收** | 🟠 需人工 | Gatekeeper 右键打开 + 离线启动 + 核心流程，只能人工验证（见 §5）。 |

---

## 3. 不属于 blocker 的项目

- **`sandbox: false`**：原因是 preload 当前使用 `require('electron')`。`sandbox:true` 更强，但需 preload 改造（改用 sandbox-safe 入口）。属可选加固，**非 blocker**。
- **preload generic `invoke`**：preload 层不做 channel allow-list；**main 侧 router 才是真正的 channel 白名单 / 安全闸门**。属可选加固，**非 blocker**。
- **auto-update 未做**：`electron-updater` 未安装、`publish:null` 显式关闭。这是 **local-first 产品决策**，不是 blocker；是否做需产品定夺。

---

## 4. 推荐后续任务顺序

> 每项开做前各自先只读评估 / 细化，再按低风险小 PR 实施。涉及人工的项见 §5。

1. **Electron 升级**：只读评估 **✅ 已出**（[`ELECTRON_UPGRADE_ASSESSMENT.md`](ELECTRON_UPGRADE_ASSESSMENT.md)——E33 确已 EOL，推荐 E43，better-sqlite3 强制耦合升 12.x）；再单开升级实施 PR-2（中风险·需 `test:electron` + 人工启动验收）。**安全价值最高**。
2. **CSP PR-2**（按 `docs/CSP_PLAN.md`）：生产构建注入 meta CSP（仅 build·Vite `transformIndexHtml`）+ 新增 `check:csp` 守卫 + 人工 QA。中风险·需人工预览。
3. **签名 / 公证**：需 Apple 账号 + CSC/APPLE_ID secrets；afterSign notarize 钩子 + `hardenedRuntime:true` + entitlements + `identity`。决策门控。
4. **arch universal / Intel 决策**：是否构建 universal 或 Intel 包。产品决策。
5. **是否做 auto-update 决策**：local-first 可不做；若做需先具备签名 + 发布通道。产品决策。
6. **干净机断网 DMG 人工冒烟**（见 §5）。

---

## 5. 人工 QA 清单（打包 / 分发验收前必跑）

> 这些项**只能人工**完成（真机 / 真打包 / 真离线）。

- [ ] 打包 DMG：`npm run build:dmg` 产出 `release/SoloLedger-<version>-arm64.dmg`
- [ ] 干净机启动：在未装过本应用的机器上安装并首次启动
- [ ] Gatekeeper 打开流程：未签名 → 右键「打开」过一次 Gatekeeper，确认可进入
- [ ] 断网启动：拔网 / 关 Wi-Fi 后启动，确认核心记账功能完全可用（验离线）
- [ ] 核心页面：看板 / 采购 / 销售 / 库存 / 发票 / 单据 / 财务 / 数据分析 / 设置 / US 税务工具 / 助手页 全部正常渲染
- [ ] AI provider 配置与调用：填入真实 Key → 测试连接 → 助手对话 / 看板简报正常（联网时）
- [ ] PDF OCR：上传 PDF → 本地栅格化 → OCR 回填预览全链路
- [ ] CSV / xlsx 导入导出：导入解析 + 导出下载正常
- [ ] 备份与恢复：手动备份导出 bundle（含 DB + attachments）→ 恢复 → 数据 + 附件完整
- [ ] 附件打开：单据附件经 IPC `shell` 打开外部正常
- [ ] DevTools 检查：打包应用如可开 DevTools，确认控制台无安全相关报错（CSP / 混合内容 / 越权 IPC 等）

---

## 6. 边界声明

- 本文件**不启用任何发布功能**（不启用签名 / 公证 / auto-update / CSP enforce），**不改变产品行为**。
- 本 PR 仅新增本文档；未改 `package.json` / `electron-builder.dmg.yml` / Electron `main` · `preload` · renderer / `index.html` / `vite.config.ts` / CSP / AI provider / Key 存储 / 文件处理 / 会计 · 税务 · 报表 · handler · schema · seed · audit。
- 实际发布动作（签名 / 公证 / Electron 升级 / CSP enforce / arch / auto-update）均待后续单独评估 + 实施 + 人工验收。

---

*相关文档：[README](../README.md) ｜ [PRIVACY](../PRIVACY.md) ｜ [Electron 升级评估](ELECTRON_UPGRADE_ASSESSMENT.md) ｜ [CSP 计划](CSP_PLAN.md) ｜ [test:locale-ui 工作流](TESTING_LOCALE_UI.md) ｜ [产品路线图](ROADMAP-to-v1.md)。本文件为工程盘点记录，非安全合规认证。*
