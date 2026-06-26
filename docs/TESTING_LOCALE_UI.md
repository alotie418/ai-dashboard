# test:locale-ui —— 结构、耗时、运行纪律与优化路线

> 文档日期：2026-06-26 ｜ 基线：main HEAD `17b1705`（🟢×16）
> 本文件为只读分析记录与运行指引，**不改变任何测试行为**。当前 `test:locale-ui` 结构未变。

固化一次针对 `test:locale-ui`（Playwright 多语言/多会计口径界面验收）的只读分析：当前结构、耗时来源、「卡住」假象的真因、推荐运行纪律，以及后续优化路线（PR-2 / PR-3，**均暂未实施**）。

---

## 1. 当前结构

- **脚本**：`test:locale-ui` = `npm run build && playwright test`（`package.json`）。
- **矩阵**：`UI_LANGUAGES`(6: zh-CN/zh-TW/en/ja/ko/fr) × `ACCOUNTING_LOCALES`(6: CN/US/JP/EU/KR/TW) = **36 combos**。
- **运行时测试数**：spec 内约 80 个 `test()/describe` 声明，矩阵块 `for acc for ui` 展开 → 运行时 **304 tests**（当前安全网基线）。
- **并行度**：`workers: 1` + `fullyParallel: false`（**串行**）。
- **⚠️ workers:1 的硬约束**：`e2e/locale-matrix.spec.ts` 用**模块级 `failures[]` 数组**累计，在 `test.afterAll` 写 `test-results/locale-matrix/summary.json` 并打印 `[locale-ui] N/36 combinations passed`。Playwright 的 worker 是**独立进程**、模块级状态不跨进程共享 → **多 worker 会打散该聚合**。这是当前必须 `workers:1` 的根本原因。
- **webServer**：`vite preview --port 4173 --strictPort --host 127.0.0.1`，`reuseExistingServer: true`，启动 timeout 120s。
- **reporter**：`list`（逐条打印 `✓ <n> <title>`，本身就是进度输出）。
- **超时**：仅 per-test 60s + webServer 120s；**无 `globalTimeout`**（无全局硬上限）。

---

## 2. 耗时来源（约 5.2 分钟）

- **主因 = 304 次串行的「新 BrowserContext → 页面 boot」**。Playwright 默认**每个 test 一个隔离 context**（冷缓存）。均摊 ≈ 5.2m / 304 ≈ **~1.03s/test**——单 test 不慢，慢在 **304 个全隔离 boot 串行累加**。
- **每 test boot 路径**（`e2e/helpers/electronMock.ts`）：新 context → `bootComboIPC` = `installElectronMock`（`addInitScript` 注入 mock `window.electronAPI`） + `gotoApp`（`addInitScript` 写 localStorage 语言 + `page.goto('/', { waitUntil: 'domcontentloaded' })` + `waitForSelector('nav', 20s)`）。
- **矩阵块额外成本**：部分块带 `waitForTimeout(500)` 固定睡眠 + 全页 `screenshot({ fullPage: true })`（对可滚动看板较贵）。
- **build 约 2.25s，不是瓶颈**（占总耗时 < 1%）。

### 为什么 route-level lazy loading 后变慢（约 2.4m → 5.2m）

- route-level lazy（`App.tsx` 各 Page 改 `React.lazy` + Suspense）后，页面 chunk 按路由拆分。
- Playwright **每 test 一个隔离 context = 冷缓存**；每个导航到某页的 test 都要**重新 fetch 该页的 lazy chunk**（之前是单一大 index chunk，一次到位）。
- 304 个隔离 context × 冷缓存 chunk 重取 ≈ 每 test +~0.55s → +约 2.8m。
- **这是纯测试基建成本，不是生产退化**：生产首屏 boot 反而更快（parse 565KB 而非 1683KB，初始内存更低）。

---

## 3. 「卡住」的真因（观测假象，非真卡死）

历史多次「test:locale-ui 卡住 / 跑了 57 分钟」复盘结论：**不是测试卡死，是输出被管道/后台吞掉**。

- `npm run test:locale-ui 2>&1 | tail -N`：`tail` 在**运行期不产出**（只在 EOF 才吐最后 N 行）；若再被转入后台，输出文件为空 → 看上去「无任何进度、像卡住」。
- `tee` / `grep` / `sed` 同理会缓冲或截断流式输出，掩盖 `list` reporter 的逐条进度。
- 真相：测试一直在正常逐条跑（`list` reporter 本应实时打印 `✓ <n>`），只是**输出层被截断**。

---

## 4. 推荐运行纪律（重要）

- **`test:locale-ui` 单独前台运行**，让 `list` reporter 实时打印逐条进度。
- **不接 `| tail` / `| tee` / `| grep` / `| sed`** 等任何管道截断。大输出由 harness 的 persisted-output 自动落盘，可事后读取，无需手工 tail。
- **不要后台运行** `test:locale-ui`（后台 + 截断双重叠加就是「卡住」假象的来源）。
- **若超过约 10 分钟没有任何新输出**：停止，汇报**最后可见输出**与最后完成的测试序号，再排查（而不是继续盲等）。常见排查点：端口 4173（`--strictPort`）/ 3000 是否被旧进程占用、是否有残留 `vite preview` / chromium 进程。
- **换基线或重建 dist 后**：确认 4173 上是否还挂着**上一次的 `vite preview`**（`reuseExistingServer: true` 会复用旧服务器）。若疑似服旧 dist，先停掉旧 4173 preview 再跑。

---

## 5. 优化路线（均暂未实施）

> 本文件不实施任何优化；以下为后续 PR 的计划与风险定级。边界：**默认 `test:locale-ui` 的 304 全量覆盖永不降低**（除非另加 quick 命令且 full 保留）。

### PR-2（低风险·additive·需一次验证跑）
- `playwright.config.ts` 加 **`globalTimeout`**（如 15min·远高于实测 5.2m）作全局硬上限 → 真 hang 时明确失败而非无限等。
- `package.json` 加 **`test:locale-ui:quick`**（`--grep` 代表性子集供本地迭代·可复用 dist 跳 build）+（可选）`test:locale-ui:full` 别名指向当前默认。
- **不动**默认 `test:locale-ui`、不动 spec、不动 `workers` / `fullyParallel`。
- 验证：`typecheck` + `check:all` + 跑一次完整 `test:locale-ui` 确认仍 **304 passed**（globalTimeout 不误伤）+ 跑 `:quick` 确认子集可跑。

### PR-3（暂缓·需专门排期 + 充分 flake 验证）
- **`workers > 1` 并行**：奖励最大（近线性 ×核数），但需**重构 summary 聚合**——各 worker 写 partial 文件，再用 `globalTeardown` 合并出 `summary.json` 与 `N/36` 计数；并可能**放大已知时序 flake**（config 已注 recategorize/select 默认值时序、assistant 会话历史侧栏加载时序等）。
- 直接威胁 **304 安全网的确定性**，必须带反复多轮稳定性验证，**不在最小安全范围**。

### context 复用（暂缓·高风险）
- 复用 BrowserContext 可让浏览器缓存暖起来、消掉 route-lazy 的冷缓存重取开销（真能砍 wall-clock）。
- 但 `addInitScript` 会**叠加**（每 test 再注入一次 mock）+ localStorage / 应用状态**跨 test 串味** → 破坏隔离 → flake / 假绿。**威胁安全网，暂缓。**

---

## 6. 对 304 安全网的影响一览

| 优化 | 是否影响 304 安全网 |
|---|---|
| 本文档 / 运行纪律 | 否 |
| `globalTimeout`（高于实测的硬上限·PR-2） | 否（仅真 hang 时兜底） |
| `test:locale-ui:quick`（additive·full 保留·PR-2） | 否 |
| `workers > 1` + summary 重构（PR-3） | **是·可能**（隔离/聚合契约）→ 暂缓 |
| context 复用 | **是·可能**（init script 叠加 + 状态串味）→ 暂缓 |

---

## 7. 风险与回滚

### 风险
1. **context 复用 / 并行** → 隔离破坏、flake、假绿（威胁安全网·已暂缓）。
2. **`globalTimeout` 设太低** → 误伤慢机 / CI；缓解：设在实测 5.2m 的宽裕倍数（如 15min）。
3. **quick 子集选取不当** → 漏覆盖；缓解：full 仍是默认门禁，quick 仅迭代用。
4. **`reuseExistingServer` 服旧 dist** → 换基线/重建后偶发；缓解：见 §4 运行纪律（先停旧 4173 preview）。

### 回滚
- **本 PR-1 = 纯文档**：回滚 = 删除本文件 / `revert` 整个 PR。
- PR-2（未来）= `playwright.config.ts` 的 `globalTimeout` + `package.json` 两行脚本：回滚 = 还原这两处，**一行级、即时、零产品 / 零数据影响**。
- PR-3（未来）= 若实施则整 PR `revert`。

---

*相关文档：[README](../README.md) ｜ [CSP 计划](CSP_PLAN.md) ｜ [产品路线图](ROADMAP-to-v1.md)。本文件为工程分析与运行指引记录。*
