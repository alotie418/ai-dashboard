# Electron 升级只读评估（Electron Upgrade Assessment）

> 状态：**只读评估 / 不升级 / 不改依赖（READ-ONLY ASSESSMENT — NO UPGRADE, NO DEPENDENCY CHANGE）**
> 文档日期：2026-07-04 ｜ 基线：main HEAD `c754af0`（#341·schema v23·working tree clean）
> 本文件仅固化一次「Electron 主版本升级」的只读评估结果，**不改任何代码 / 依赖 / package-lock / 打包配置**。实际升级为后续独立 PR（PR-2），需显式授权。
> 事实核实：外部版本 / EOL / breaking changes / 依赖兼容性均以 2026-07 官方一手来源核对（见文末「主要来源」），并经对抗式复核。
> **实施状态更新（2026-07-07·main `3fc241e`）**：PR-2 第一步已按文中「分阶段回退」路径落地——**#348（2026-07-06）升至 Electron 42.6.0 + better-sqlite3 12.11.1**；生产 CSP enforce 随 #349 落地。E42→E43 再 bump 仍等 better-sqlite3 **12.11.2 上 npm**（截至 2026-07-07 npm latest = 12.11.1，仅 GitHub tag），有界止损决策待定：超期则带 E42 直接进入签名/公证（E42 EOL 2026-10-20）。

---

## 0. 一句话结论（TL;DR）

当前 **Electron 33.4.11 自 2025-04-29 起已 EOL**，至今约 14 个月无 Chromium 安全补丁，对一款「唯一本地账本」定位的财务应用是**硬安全负债，升级非可选**。推荐目标 = **Electron 43**（2026-07 最新稳定版，支持窗口最长、到 2027-01-05）。

本应用主进程 API 表面极小且保守，**Electron 侧 breaking changes 对本应用影响 = 低**。真正的风险与工作量集中在**一个耦合依赖**：`better-sqlite3 11.10.0` 是 raw-V8 原生模块，**无法编译到 Electron 41+**（E41 的 V8 移除了它依赖的 C++ 函数），因此升级 Electron 会**强制把 better-sqlite3 一起升到 12.x**——这是全案唯一的高风险项，因为它是账本存储引擎。`@napi-rs/canvas`/pdf.js/OCR 为绿灯（仅需锁版本 + 打包版验证）；`electron-builder 25.1.8` 可用（可选升 26.x，非阻塞）。

**这不是一次性升级**：Electron 8 周一个主版本、只维护最新 3 个主版本，任何目标都只有约 5.5 个月支持窗口。本应用需要建立**每个周期例行 re-bump** 的维护节奏，而不是「升一次就长期不动」。

---

## 1. Electron 33 现状与安全风险（问题 1）

| 维度 | 事实 | 出处 |
|---|---|---|
| 当前实装 | `electron@33.4.11`（package.json devDep `^33.2.0`；33.4.x 是 E33 终点补丁线） | `package.json` / `node_modules` |
| E33 稳定发布 | 2024-10-15（Chromium 130 / Node 20.18.0 / V8 13.0） | releases.electronjs.org/schedule |
| **E33 EOL** | **2025-04-29**（E36 发布当日被挤出 3-major 支持窗口） | releases.electronjs.org/schedule · endoflife.date |
| 安全状态 | 截至 2026-07 已 EOL 约 **14 个月**，缺失一年以上 Chromium CVE backport / Node 更新 | 同上 |
| 支持策略 | 「最新 3 个稳定主版本」受支持，主版本 8 周一发；每个主版本约 24 周（~5.5 月）支持期 | electronjs.org/docs · electron-timelines |

**结论**：E33 是死分支，对财务应用是硬安全 blocker，升级非可选。这与 `docs/PRE_RELEASE_CHECKLIST.md §2`（🟠「Electron 33 可能已超支持窗口」需核实）一致——现已核实**确已 EOL**。

> 注：`docs/ROADMAP-to-v1.md:116` 曾把「bump 到 v33 最新 patch」列为 Nice(S)。那只是 E33 线内打补丁，**不解决 EOL**；本评估针对的是主版本升级。

---

## 2. 版本全景参考表（Electron 33 → 43，问题 7 支撑）

所有 Chromium/Node/V8 字符串取自各版本官方发布博客并逐条核对；ABI = Node `NODE_MODULE_VERSION`。

| Electron | Chromium | Node.js | V8 | Node ABI | 稳定发布 | 状态（2026-07） |
|---|---|---|---|---|---|---|
| 33 | 130.0.6723.44 | 20.18.0 | 13.0 | 115 | 2024-10 | **EOL**（当前实装） |
| 34 | 132.0.6834.83 | 20.18.1 | 13.2 | 115 | 2025-01 | EOL |
| 35 | 134.0.6998.44 | 22.14.0 | 13.5 | **127 ← ABI 变** | 2025-03 | EOL |
| 36 | 136.0.7103.48 | 22.14.0 | 13.6 | 127 | 2025-04 | EOL |
| 37 | 138.0.7204.35 | 22.16.0 | 13.8 | 127 | 2025-06 | EOL |
| 38 | 140.0.7339.41 | 22.18.0 | 14.0 | 127 | 2025-09 | EOL |
| 39 | 142.0.7444.52 | 22.20.0 | 14.2 | 127 | 2025-10 | EOL |
| 40 | 144.0.7559.60 | 24.11.1 | 14.4 | **137 ← ABI 变** | 2026-01 | EOL（6/30） |
| 41 | 146.0.7680.65 | 24.14.0 | 14.6 | 137 | 2026-03 | 支持（EOL 08-25） |
| 42 | 148.0.7778.96 | 24.15.0 | 14.8 | 137 | 2026-05 | 支持（EOL 10-20） |
| **43** | **150.0.7871.46** | **24.17.0** | **15.0** | **137** | **2026-07** | **支持（EOL 2027-01-05）· 最新稳定** |

**Node ABI 硬边界在 E35（20→22）与 E40（22→24）**。但注意：Electron 每个主版本都会 bump 自身 ABI（独立于 Node），所以**原生模块每次主版本升级都必须重编**，不只在 35/40。E44 为 alpha（min macOS 13）、E45 为 nightly，均未稳定，不作目标。

---

## 3. 推荐目标：Electron 43（问题 2）

**推荐 Electron 43，pin 到届时最成熟的 43.x 补丁**（截至 2026-07 仅有 43.0.0）。

### 决策权衡

| 选项 | 优点 | 缺点 | 结论 |
|---|---|---|---|
| **E43（最新稳定）** | 支持窗口最长（到 2027-01-05，~6 月）；到 PR-2 实施+QA 时大概率已有成熟 43.x 补丁 | 目前仅 43.0.0（`.0` 风险）；配套 better-sqlite3 prebuild（12.11.2）刚 GitHub tag、尚未上 npm | **✅ 推荐** |
| E42（次新） | 补丁更成熟（42.6.0）；better-sqlite3 ≥12.11.1 已在 npm | EOL 2026-10-20（~3.5 月），很快要再升 | 备选（若实施时 E43 生态未就绪） |
| E41 | 补丁最成熟（41.10.0） | EOL 2026-08-25（~7 周），近乎落地即 EOL | 不推荐 |

**关键洞察**：Electron 的 3-major/8-周窗口下，「稳一点就选次新」的直觉在这里**反效果**——次新版落地即接近 EOL。稳定优先的正解反而是**取最新稳定版**以换取最长补丁窗口，用「pin 成熟补丁点」来对冲 `.0` 风险，并接受「每周期例行 re-bump」的节奏。

> **待用户确认**：目标 major 的最终敲定放在 PR-2 授权时。若实施窗口内 E43 尚无成熟补丁点、且 better-sqlite3 12.11.2 未上 npm，可回退到 E42 作为过渡。本节为推荐 + 依据，不是已决策项。

---

## 4. 本应用 API 表面 × Breaking Changes 影响（问题 3）

### 4.1 本应用实际用到的 Electron API（从代码枚举，非泛泛而谈）

主进程仅用以下核心、长期稳定的 API（`electron/` 全量 grep）：

- `app`：`getPath('userData'|'documents')`、`isPackaged`、`on`、`quit`、`whenReady`、`requestSingleInstanceLock`、`relaunch`、`exit`
- `BrowserWindow`：构造、`getAllWindows`；**离屏窗口 + `webContents.printToPDF`**（财务报表 PDF 导出）
- `ipcMain.handle`（28 个 handler）、`ipcRenderer.invoke`（仅 preload）、`contextBridge.exposeInMainWorld`（仅 preload）
- `dialog.showSaveDialog` / `showOpenDialog`
- `shell.openExternal` / `openPath`
- `safeStorage`（AI Key + 电商凭证加解密）
- `webContents`：`setWindowOpenHandler`、`on('will-navigate')`、`openDevTools`（仅 dev）

**无** 自定义 `protocol` 注册、`session` 定制、`Menu`、`nativeTheme`、`utilityProcess`、`net` 模块、`autoUpdater`、`crashReporter`、渲染端 clipboard、Notification。这是个极保守的表面 → breaking-change 暴露面天然低。

### 4.2 E34–E43 breaking changes 对本应用的影响映射

**核对结论：本应用用到的 API 在 E34–E43 无一出现在任何 breaking-change / removed / deprecated 条目中。** 默认 `sandbox`（E20 起 true）与 `contextIsolation`（E12 起 true）在 E34–E44 均未变；无 ASAR-integrity/fuse 破坏性变更。

需知会但**对本应用不生效或仅需留意**的条目：

| 版本 | 变更 | 对本应用 | 
|---|---|---|
| E35 | ESM「Cannot find package」从 asar 默认导入失败（E35.0.2 已修） | **不适用**：本应用是 CommonJS（`electron/package.json {"type":"commonjs"}`） |
| E36 | `NativeImage.getBitmap()` 弃用；GTK4 默认（GNOME） | 不适用：不用 NativeImage；GTK 仅 Linux |
| E37 | `ProtocolResponse.session=null` 移除 | 不适用：不定制 protocol response |
| E39 | `window.open` 弹窗默认可缩放（经 `setWindowOpenHandler` 覆盖） | **不适用**：本应用 `setWindowOpenHandler` 一律 `{action:'deny'}` |
| E40 | 渲染端 clipboard 弃用（迁 preload+contextBridge） | 不适用：渲染端不用 clipboard |
| E42 | **macOS 通知改用 UNNotification，要求 App 已签名**（未签名发 `failed` 事件） | 不适用：本应用不用 Notification。**但签名线落地后若将来加通知需已签名** |
| E42 | `electron` npm 包不再 postinstall 下载二进制（改按需/`install-electron`） | **留意 CI/装依赖**：假设 postinstall 下载的脚本需调整 |
| E43 | `dialog` 无 `defaultPath` 时默认落 Downloads | **不生效**：本应用所有 save/open 都显式传 `app.getPath('documents')`；仍建议 QA 核对 |
| E43 | `NativeImage.toBitmap()` 默认归一化到 sRGB | 不适用：不用 NativeImage bitmap |

**主进程 API 表面整体影响 = 低。** 唯二需在意的是 §5 的 better-sqlite3 耦合 与 §8 的 Chromium 渲染/`printToPDF` 回归验证。

---

## 5. better-sqlite3 11.10.0 兼容性 —— 耦合升级（最高风险，问题 4）

**这是全案唯一高风险项，因为它是账本 SQLite 存储引擎。**

### 5.1 事实

- `better-sqlite3` 是 **raw-V8 / node-gyp 原生模块（非 N-API / node-addon-api）**。其编译产物 ABI 锁定，**每个 Electron 主版本都必须重编**；更严重的是，**C++ 源码本身会在 V8 移除 API 时无法编译**。
  - 依据：v11.10.0 `package.json` 生产依赖仅 `bindings`/`prebuild-install`，无 node-addon-api；12.x changelog 反复直接 patch V8 C++ API（`Holder()`→`HolderV2()` 等）。
- **11.10.0 的 prebuild 上限到 Electron 36，且无 Node-24 prebuild**（Node 24 是 v12.0.0 才进构建矩阵）。
- **11.10.0 可源码重编到 E34–E40，但无法编译到 E41+**：Electron 41 的 V8 14.6 移除了 `PropertyCallbackInfo` 的 `Holder()`/`This()`，击穿所有 `better-sqlite3 < 12.8.0`。
- **各支持版最低要求**：E41 需 **≥12.8.0**；E42 需 **≥12.11.1**（尤其 Windows）；E43 prebuild 需 **12.11.2**（12.11.1 或可对 E43 的 V8 15.0 源码重编，但无预编译二进制）。
- **版本现状**：npm `latest` = **12.11.1**；**12.11.2** 已在 GitHub tag（2026-07-03，含 E43 prebuild），**尚未发布到 npm**。
- 本仓 `package.json` 钉 `better-sqlite3@^11.5.0`（实装 11.10.0）——**只在已 EOL 的 Electron ≤40 上安全，对任何当前受支持的 Electron 会硬失败**。

### 5.2 结论与升级映射

**升级 Electron 到任一受支持主版本（41/42/43）= 强制把 better-sqlite3 升到 12.x。** 这是耦合 bump，PR-2 必须两者同时改。

- 好消息：**11.x → 12.x 是主版本号跳跃，但 API 风险低**——v12.0.0 唯一的破坏性变更是「移除 EOL 运行时（Node 18、Electron 26/27/28）」，**不动 query/statement API**。本应用的 SQL 调用面不受影响。
- 目标配对：**E43 → better-sqlite3 12.11.2+**（等其上 npm，或先源码重编 12.11.1）。
- **避开的非可用版本**：12.7.0、12.7.1、12.9.1、12.11.0（官方标记 NOT VIABLE）。
- 本机测试的 ABI 之舞不变（记忆已录）：`npm rebuild better-sqlite3` → 跑 node-ABI 守卫 → `npm run electron:rebuild` 还原。

---

## 6. @napi-rs/canvas / pdf.js / OCR 兼容性 —— 绿灯（问题 5）

**结论：升级 Electron 到 41/42/43 无需重编 @napi-rs/canvas，也不破坏 pdf.js。当作「锁版本 + 打包版验证」任务，不是 ABI 任务。**

- `@napi-rs/canvas`（经 `pdfjs-dist 4.10.38` 间接依赖，供 PDF 栅格化喂 OCR）是 **N-API（napi5）**，发布**每平台预编译二进制**（本机 `canvas-darwin-arm64`），无 node-gyp/postinstall。N-API ABI 稳定保证 → **同一 .node 跨 E34–E43 免重编**。（对比：Automattic 的 `node-canvas` 才是 NODE_MODULE_VERSION 型、需 electron-rebuild——本应用用的不是它。）
- **V8 memory cage**（E21+ 禁止外部内存 ArrayBuffer）这个唯一 ABI 相邻隐患，**napi-rs 框架层早已处理**（2023 年 buffer-copy fallback）；@napi-rs/canvas 基于 napi 3.1，运行期自动兜底，非 ABI 破坏。
- `pdfjs-dist 4.10.38` **不被更新的 Chromium（146/148/150）破坏**：其 `eval`/`new Function` 路径由 **CSP（`isEvalSupported`）** 决定，与 Chromium 主版本无关；Chromium 146–150 仍支持这些原语。CVE-2024-4367 早于 4.10.38（安全侧）。
- **唯一要守的坑**：`pdfjs-dist` × `@napi-rs/canvas` 版本配对在**打包/bundle**下的模块身份问题（canvas #994：webpack/Electron 打包版 `drawImage` 抛「Value is none of these types…」），**与 Electron 主版本无关**。→ 保持已知可用配对、dedupe 到单一 canvas 副本、**在打包版（非仅 dev）验证 PDF 栅格化/OCR**。

> 与 `docs/CSP_PLAN.md` 呼应：CSP enforce（PR-3）时 pdf.js 的 eval 降级验证仍是最高风险人工项；本升级不改变该判断。

---

## 7. electron-builder 25.1.8 是否需同步升级（问题 6）

**结论：25.1.8 可打包/签名/公证现代 Electron，非阻塞项；建议（可选）升到 pin 死的 26.x，跳过 v27-alpha。**

- **与 Electron 版本解耦**：维护者明确「major 无需匹配」；25.1.8 可打包 E34–E43。
- **公证引擎与当前版逐字节相同**：25.1.8 与 26.15.6 都依赖 `@electron/notarize@2.5.0`（走系统 `notarytool`；旧 `altool` 已于 2023-11-01 停用）。**Sequoia+ 的公证来自系统 notarytool，不是升级 electron-builder 的理由**。
- **真正的升级驱动 = 原生重编工具链**：25.1.8 → `@electron/rebuild 3.6.1`（`node-abi ^3.45.0`，caret 解析到 3.94.0，覆盖较新 major）；26.x → `@electron/rebuild v4`（`node-abi v4`）。针对全新 Electron major，需 node-abi 表足够新（刷新 node-abi 或 bump builder），否则 `Could not detect abi`。
- **版本现状**：最新稳定 **26.15.6**（2026-06-26）。dist-tag 有坑——`latest` 停在 26.15.3、更新的在 `v26` tag 下（`npm i electron-builder` 会抓到 26.15.3 而非 26.15.6）。`next` = 27.0.0-alpha（native ESM、Node ≥22.12，**未稳定，勿用**）。
- **建议**：PR-2 可顺带把 `electron-builder` pin 到显式 **26.15.6**（拿到维护中的 rebuild 工具链 + 累积修复），**但这不是 Electron 升级的前置**；也可保持 25.1.8 先跑通。避开 27.0.0-alpha。

---

## 8. Node / Chromium 行为变化风险（问题 7）

- **Node 20 → 24（跨两个 ABI 边界：E35、E40）**：对本应用是重编问题（§5），非 JS API 问题——主进程只用 `fs`/`path`/`require` 与 Electron API，无依赖特定 Node 主版本行为的代码。Node 24 语义对本应用无已知破坏。
- **Chromium 130 → 150（渲染端 20 个大版本）**：渲染端是自托管 React SPA（`file://` + `check:offline` 钉死无 CDN）。风险面 = 渲染回归，需人工过一遍核心页面 + 图表（recharts）+ markdown。
- **`webContents.printToPDF`（离屏 BrowserWindow）**：跨 Chromium 大跨度升级，PDF 报表的分页/背景/字体渲染需专门回归（本应用离屏渲染 HTML → printToPDF → 存盘）。**列为重点 QA 项**。
- **`dialog` 默认目录（E43）/ 通知签名要求（E42）**：见 §4.2，本应用当前均不触发，但 QA 核对。
- **ASAR-integrity 相关 CVE**（如 CVE-2025-55305，E38.0.0-beta.6 / 35.7.5 等已修）：是**留在受支持补丁线**的又一理由，属安全加固而非 breaking change。E43 已包含这些修复。

---

## 9. 升级实施步骤（问题 8，PR-2，需授权）

> 一分支一 PR，只含升级相关文件。**本 doc 不执行以下任何一步。**

1. **确认目标 major**（默认 E43；实施窗口内若生态未就绪则 E42 过渡）。
2. **同步改 `package.json`**：`electron` → 目标 major 最新补丁；`better-sqlite3` `^11.5.0` → **`^12.11.2`**（或届时 npm 上的可用 12.x，避开非可用版）；（可选）`electron-builder` → `26.15.6`。
3. **`npm install`** 刷新 lockfile（引入 Node-24-ABI 的 better-sqlite3 12.x prebuild）。
4. **`npm run electron:rebuild`**：把 better-sqlite3 按目标 Electron ABI 重编。
5. **锁定 pdf.js × canvas 配对**：确认 `pdfjs-dist` 与 `@napi-rs/canvas` 为已知可用配对、dedupe 单副本（`npm ls @napi-rs/canvas`）。
6. **跑全量验证**（见 §11）；node-ABI 守卫按记忆的 rebuild 流程本机跑。
7. **打包冒烟**：`npm run build:dmg` 产出 DMG，人工过 §11 清单（尤其 SQLite 读写、PDF 报表、OCR）。
8. **提交 + 开 PR，不 merge**；报告分支/commit/PR/改动文件/验证结果。

> 顺序提示（与 `PRE_RELEASE_CHECKLIST.md §4` 一致）：**Electron 升级应排在签名/公证之前**——只对最终运行时公证一次，避免返工。

---

## 10. 回滚方案（问题 9）

- **升级完全收敛在依赖 + lockfile 层**，无源码改动（§4 证明本应用代码无需改）。
- **回滚 = `git revert` 整个 PR-2**（还原 `package.json` + `package-lock.json`）→ `npm install` → `npm run electron:rebuild`。一次性、干净、零数据影响。
- **数据安全**：升级不动 schema（仍 v23）、不动迁移、不动 `userData` 布局。better-sqlite3 12.x 读旧库无格式变化（SQLite 文件格式与驱动大版本无关）。**但仍按流程**：升级前依赖本应用启动前自动备份（`userData/backups`）+ 人工导一次备份 bundle 兜底。
- **分阶段回退**：若 E43 生态未就绪，先落 **E42 + better-sqlite3 12.11.1**（均已在 npm），后续再 bump 到 E43——两步都可独立 revert。

---

## 11. 验证命令 + 人工 QA checklist（问题 10）

### 11.1 自动化验证（PR-2 全量）

```
npm run check:all          # 全部守卫（含 offline / i18n / handlers / migrations 等）
npm run typecheck          # tsc --noEmit
npm run build              # vite 生产构建
npm run test:locale-ui     # 页面级 e2e（vite preview）
npm run test:electron      # 真 main 进程 + 真 better-sqlite3（先 electron:rebuild）
```

> 本机 node-ABI 守卫（check:handlers / check:migrations / check:csv-export Part2）按记忆流程：`npm rebuild better-sqlite3` → 跑 → `npm run electron:rebuild` 还原。CI（若已接）在 Electron ABI 下真跑。

### 11.2 人工 QA（打包版必跑，重点验升级敏感面）

- [ ] `npm run build:dmg` 产出 DMG，干净机安装 + Gatekeeper 打开 + 断网启动
- [ ] **SQLite 读写往返**（better-sqlite3 12.x 重编后）：新增/编辑/删除一笔采购+销售，重启后数据在
- [ ] **迁移**：对旧库（schema <v23）启动 → 迁移到 v23 正常、行数不丢
- [ ] **备份 / 恢复**：手动备份 bundle（DB + attachments）→ 恢复 → 数据 + 附件完整
- [ ] **财务报表 PDF 导出**（`printToPDF` 离屏渲染，跨 Chromium 大跨度）：分页/背景/字体正确
- [ ] **PDF OCR 全链路**（`@napi-rs/canvas` 栅格化，**在打包版验，非仅 dev**）：上传 PDF → 栅格化 → OCR 回填预览
- [ ] **CSV / xlsx 导入导出**、**单据附件经 `shell` 打开**
- [ ] **核心页面渲染**（Chromium 130→150）：看板 / 采购 / 销售 / 库存 / 发票 / 单据 / 财务 / 数据分析 / 设置 / US 税务工具 / 助手页 + 图表(recharts) + markdown
- [ ] **safeStorage**：AI Key / 电商凭证 加解密往返正常
- [ ] **`dialog` 默认目录**核对（E43 行为）；**单实例锁**双开验证
- [ ] DevTools 控制台无安全/渲染报错

---

## 12. 依赖版本决策矩阵（汇总）

| 依赖 | 当前 | 目标（随 E43） | 是否强制 | 风险 |
|---|---|---|---|---|
| `electron` | 33.4.11（EOL） | **43.x**（最成熟补丁点） | 是（安全） | 中（重编 + 渲染回归 + printToPDF） |
| `better-sqlite3` | 11.10.0（raw-V8，E41+ 无法编译） | **12.11.2+** | **是（耦合，硬失败）** | **高（账本存储引擎）**，但 API 风险低 |
| `@napi-rs/canvas` | 现装（N-API，ABI 稳定） | 免重编；仅锁配对 | 否 | 低（仅打包版模块身份验证） |
| `pdfjs-dist` | 4.10.38 | 保持；与 canvas 锁配对 | 否 | 低（CSP/worker 配对，非 Chromium） |
| `electron-builder` | 25.1.8（可用） | 可选 26.15.6（pin） | 否 | 低（公证引擎不变；升级为维护中 rebuild 工具链） |

---

## 13. 边界声明

- 本文件**只做只读评估**：不升级 Electron、不改任何依赖 / `package.json` / `package-lock.json`、不改 `electron-builder.dmg.yml` / CSP / sandbox / 签名 / 公证配置、不跑 `npm install`。
- 本 PR **仅新增本文档**（`docs/ELECTRON_UPGRADE_ASSESSMENT.md`）+ 在 `docs/PRE_RELEASE_CHECKLIST.md` 加交叉指针。**未改任何代码、依赖、配置、schema、会计/税务/报表逻辑。**
- 纯文档 PR，未跑测试链（无运行时可验证面）。
- 实际升级（Electron + better-sqlite3 耦合 bump、electron-builder、打包/QA）为后续独立 PR-2，需显式授权 + 中风险人工验收。

---

*相关文档：[发布前清单](PRE_RELEASE_CHECKLIST.md) ｜ [CSP 计划](CSP_PLAN.md) ｜ [产品路线图](ROADMAP-to-v1.md)。本文件为工程评估记录，非安全合规认证。*

## 附：主要来源（2026-07 一手核对，经对抗式复核）

- Electron 发布/EOL：`releases.electronjs.org/schedule`、`endoflife.date/electron`、`electronjs.org/docs/latest/tutorial/electron-timelines`
- 各版本 Chromium/Node/V8：`electronjs.org/blog/electron-33-0` … `electron-43-0`；Node ABI：`nodejs/node/doc/abi_version_registry.json`
- Breaking changes：`github.com/electron/electron/blob/main/docs/breaking-changes.md`
- better-sqlite3：`github.com/WiseLibs/better-sqlite3` releases（v11.10.0 / v12.0.0 / v12.7.0 / v12.8.0 / v12.10.1 / v12.11.1 / v12.11.2）、`npmjs.com/package/better-sqlite3`
- @napi-rs/canvas：`github.com/Brooooooklyn/canvas`（Cargo.toml / issues #994 #1073 / PR #1284）、`nodejs.org/api/n-api.html`、`github.com/napi-rs/napi-rs/pull/1445`
- pdf.js：`github.com/mozilla/pdf.js`（issues #19688 #16111）、CVE-2024-4367（fixed v4.2.67）
- electron-builder：`registry.npmjs.org/electron-builder` / `app-builder-lib`、`github.com/electron-userland/electron-builder`（issue #7704 #8939）、`@electron/notarize@2.5.0`
