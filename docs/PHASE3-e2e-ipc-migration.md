# Phase 3 迁移方案：e2e 从 mock-fetch (Web) → mock electronAPI (IPC) 启动

> 状态：**方案文档（planning only）**。本文件只记录方案，不含任何源码/测试改动。
> 推进方式：按 PR-3.1 → PR-3.8 小步拆分，每个 PR 只含相关文件，作者从不自行 merge。
> 适用前提：旧 Web/云端栈（Cloud Run / Cloudflare Worker / D1 / KV / DNS）已退役，产品形态为 Electron 本地桌面版，数据本地 SQLite，IPC 经 `api:request` 路由。

---

## 0. 核心目标与一个关键认知

**核心目标**：把 Playwright e2e 测试的启动桩，从「mock HTTP fetch（Web 形态）」迁移到「mock `window.electronAPI`（IPC 形态）」。迁移完成后，才能安全删除源码中残留的 Web fallback / Web auth gate / LoginPage。

### 为什么不是改成「真实 Electron e2e」

Phase 3 **不是**改成"启动真实 Electron 进程跑 e2e"。Playwright 仍然用 `vite preview`（端口 4173）把打包好的 SPA 当普通网页跑在 Chromium 里。改的只是**注入的 mock 形态**：

- **现在（Web 形态）**：不注入 `window.electronAPI` → `isElectron()` 返回 `false` → App 走 `fetch('/api/...')` / `fetch('/auth/check')` → 被 `page.route('**/api/**')` / `page.route('**/auth/**')` 拦截。
- **目标（IPC 形态）**：用 `addInitScript` 注入 mock `window.electronAPI` → `isElectron()` 返回 `true` → App 走 `electronAPI.invoke('api:request', {method,path,body})`，并**跳过整个 Web auth gate** → 由 mock 的 `invoke` 回数据。

> 「真实 Electron 打包应用 e2e」（启动 electron-builder 产物、走真实主进程/preload/SQLite）仍是路线图独立项，**不在 Phase 3 范围**。Phase 3 只是把测试桩从「HTTP 形状」换成「IPC 形状」，从而解锁删除 Web fallback。
>
> 选择该路线的理由：保留 `vite preview` + Chromium 的低成本、快速、可并行（无需打包 DMG、无需 native rebuild），同时让测试通过的代码路径与桌面运行时一致（IPC 而非 HTTP）。

---

## 1. 当前 e2e 如何依赖 Web mock-fetch

只有**一个** spec：`e2e/locale-matrix.spec.ts`（约 1291 行，43 个 `test()`、14 个 `test.describe`）。两类启动方式并存：

### (A) Web 启动（需要迁移）

通过 `bootCombo()`（`e2e/locale-matrix.spec.ts:122-137`）或主矩阵的内联 `page.route`（`:68-78`）：

```ts
await page.route('**/auth/check', r => r.fulfill({ json: { authenticated: true } }));
await page.route('**/auth/**',   r => r.fulfill({ json: { authenticated: true } }));
await page.route('**/api/**', route => {
  const url = route.request().url();
  if (url.includes('/api/settings'))  return route.fulfill({ json: SETTINGS(acc) });
  if (url.includes('/api/dashboard')) return route.fulfill({ json: DASHBOARD(acc) });
  if (/\/api\/(categories|products|transactions|sales|purchases|receivables|payables|alerts|providers|mileage|documents|reports\/types)/.test(url))
    return route.fulfill({ json: [] });
  return route.fulfill({ json: {} });            // catch-all
});
await page.addInitScript(l => localStorage.setItem('sololedger-lang', l), ui);
await page.goto('/'); await page.waitForSelector('nav');
```

依赖链：App 启动 → `isElectron()===false` → `apiFetch` 走 `fetch` → 命中 route → 渲染 → 断言「禁用词不出现」。**`fetch('/auth/check')` 也是这条链**（`App.tsx:481`），mock 返回 `authenticated:true` 才不会渲染 `LoginPage`。

### (B) IPC 启动（已是迁移模板）

已有约 19 处 `electronAPI` 注入。最完整的是 `injectDocsElectronAPI()`（`:691-768`）和备份 mock（`:233-256`），形如：

```ts
await page.addInitScript(({ settings, dashboard }) => {
  const lists = /\/api\/(categories|products|transactions|sales|purchases|receivables|payables|alerts|providers|mileage|documents|reports\/types)/;
  (window as any).electronAPI = {
    isElectron: true,
    platform: 'darwin',
    invoke: (channel: string, payload: any) => {
      if (channel === 'providers:hasAny') return Promise.resolve(true);
      if (channel === 'providers:list')   return Promise.resolve([]);
      if (channel === 'api:request') {
        const p = (payload && payload.path) || '';
        if (p.includes('/api/settings'))  return Promise.resolve(settings);
        if (p.includes('/api/dashboard')) return Promise.resolve(dashboard);
        if (lists.test(p)) return Promise.resolve([]);
        return Promise.resolve({});
      }
      return Promise.resolve({});
    },
  };
}, { settings: SETTINGS('CN'), dashboard: DASHBOARD('CN') });
```

### 矩阵与规模

- `UI_LANGUAGES = ['zh-CN','zh-TW','en','ja','ko','fr']`（6）
- `ACCOUNTING_LOCALES = ['CN','US','JP','EU','KR','TW']`（6）

**规模实测**（按嵌套循环展开）：约 **~245 个测试实例**，其中：

- **~204 个走 Web 启动**（bootCombo / 内联 route）—— **这些是迁移目标**，约等于"~190"的口径。
- **~42 个已注入 mock electronAPI**（备份/OCR/BYOK/全部 documents 模态与税票测试）—— 已是 IPC 形态，作模板复用。

> 权威数字以 `npx playwright test --list` 为准；describe 嵌套会让总数在 ~230–245 间浮动。历史 `test:locale-ui` 计数在 226/228/236 间演进过，属正常。

---

## 2. 需要迁移的测试文件与 describe 分组

只有一个文件：**`e2e/locale-matrix.spec.ts`**。内部按 describe 分组迁移，下列分组当前走 Web 启动、需逐组改用 IPC helper：

| 分组 | 行号（约） | 规模 | 额外 route 依赖 |
|---|---|---|---|
| 主仪表盘矩阵（内联 route） | 64-117 | 36 | 无 |
| settings → products/services | 139-165 | 36 | 无（bootCombo） |
| purchase 弹窗 product picker | 171-192 | 6 | 无 |
| data backup 渲染（无 IPC） | 198-220 | 36 | 无 |
| finance → export PDF / coming-soon | 397-416 | 3+1 | 无 |
| AI 助手页矩阵 | 494-516 | 36 | 无 |
| AI 助手 tool-trace | 524-561 | 6 | `/api/ai/agent-chat` |
| AI 助手对话持久化 | 569-618 | 1 | `/api/conversations*` |
| AI 助手对话历史 | 625-684 | 1 | `/api/conversations*` |
| business documents 页矩阵 | 466-489 | 36 | 无 |
| PR-T2 财报可信度 | 1118-1162 | 3 | 无 |
| PR-T5-2B-2 categories is_cogs | 1213-1279 | 3 | `/api/categories` 状态 |

**不需迁移（已 IPC）**：data-backup-happy、OCR 预览、BYOK 名称、finance-PDF-IPC、全部 documents 模态/税票（`injectDocsElectronAPI`）。这些在 PR-3.5/3.7 顺手收敛到共享 helper，但不改变其测试语义。

> 行号为参照锚点，随后续 PR 改动会漂移；以 describe 标题与 `test()` 名称为准。

---

## 3. 需要新增的 helper

当前 `e2e/` 目录无任何 helper/fixture，全部 mock 内联在 spec 里。抽出**共享 helper 模块**，把散落的 mock 收敛成单一表面。

### 3.1 `e2e/helpers/fixtures.ts`

从 spec 抽出 `SETTINGS(acc)` / `DASHBOARD(acc)` 两个纯函数（locale-agnostic JSON 工厂），供 Web 旧路径（迁移期间）与 IPC 新路径共用同一份 mock 数据，确保渲染 DOM 逐字节一致。

### 3.2 `e2e/helpers/electronMock.ts`（方案草图，本次不落地）

```ts
import type { Page } from '@playwright/test';
import { SETTINGS, DASHBOARD } from './fixtures';

type InvokeOverride = (channel: string, payload: any) => Promise<any> | undefined;

// 注入 mock window.electronAPI，复刻真实 preload 表面：{ invoke, platform, isElectron }
export async function installElectronMock(page: Page, opts: {
  acc?: string;                  // 'CN'|'US'|... → 决定 SETTINGS/DASHBOARD
  hasProvider?: boolean;         // providers:hasAny（默认 true，避免 OnboardingWizard 抢渲染）
  providers?: any[];             // providers:list
  override?: InvokeOverride;     // 每测试自定义路由（agent-chat / conversations / 状态化）
  appChannels?: Record<string, any>;  // app:exportDb / app:exportReportPdf 等定值
}) {
  // addInitScript：构造 window.electronAPI.invoke —— 先查 override，再走默认
  //   api:request → settings/dashboard/lists/{}
  //   providers:hasAny → hasProvider（默认 true）
  //   providers:list → providers（默认 []）
  //   app:* → appChannels 对应定值
}

// bootCombo 的 IPC 等价物：装 mock → 设语言 → goto → 等 nav
export async function bootComboIPC(page: Page, ui: string, acc: string, opts?: any) {
  await installElectronMock(page, { acc, ...opts });
  await page.addInitScript(l => { try { localStorage.setItem('sololedger-lang', l as string); } catch {} }, ui);
  await page.goto('/', { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('nav', { timeout: 20_000 });
}
```

**要点**：

- **`invoke` 表面只暴露 `{ invoke, platform, isElectron }`**，对齐真实 `electron/preload.js:10-15`。**去掉旧 mock 里的 `buildTarget`**（已从 preload 删除，现是死字段，新 helper 不应复活它）。
- **`api:request` 路由复刻 bootCombo 的 `/api/**` 分支**，返回**同一份 `SETTINGS(acc)/DASHBOARD(acc)`** → 渲染 DOM 与 Web 模式逐字节一致 → 禁用词断言不变。
- **`providers:hasAny → true` 必须有**，否则 `App.tsx:474-479` 的 onboarding 检查会渲染 `OnboardingWizard` 而非 `AppContent`，整批矩阵断言崩。
- `override(channel, payload)` 钩子吸收每测试的 `agent-chat` / `conversations` / 状态化逻辑（把现有 per-test `page.route` 折进来）。
- 把 `injectDocsElectronAPI` 重构为 `installElectronMock(..., { override })`，让全测试只剩**一个** mock 实现。

### 3.3 `e2e/types.d.ts`（可选）

声明 `declare global { interface Window { electronAPI: { invoke(channel: string, payload?: any): Promise<any>; platform: string; isElectron: boolean } } }`。当前源码与测试全是 `(window as any).electronAPI`，无类型声明；补上后可减少 `as any`，并让 PR-3.8 的删除有类型保护（配合 `tsc --noEmit`）。

---

## 4. PR 拆分（PR-3.1 → PR-3.8）

**策略：渐进 + 先导。** `bootCombo`（Web）与 `bootComboIPC`（IPC）并存，逐 describe 切换；全部切完再删 `bootCombo`，**最后才删 Web fallback**。每个 PR 跑完整 `test:locale-ui` 保持矩阵常绿。

| PR | 目标 |
|---|---|
| **3.1 helper 地基 + 先导** | 新增 `electronMock.ts` + `fixtures.ts`（抽出 SETTINGS/DASHBOARD）；只迁**主仪表盘矩阵**（36）作先导，验证 auth-skip + providers:hasAny + 禁用词全过 |
| **3.2 settings/purchase/backup-render** | 迁 products(36) + purchase(6) + backup-render(36) |
| **3.3 finance** | 迁 finance export / coming-soon(4) |
| **3.4 AI 助手** | 迁 AI 页矩阵(36) + tool-trace(6) + 对话持久化/历史(2)，把 `agent-chat` / `conversations` 折进 `override` |
| **3.5 business documents 页矩阵** | 迁 docs 页(36)；顺手把 `injectDocsElectronAPI` 重构到共享 helper |
| **3.6 T2 + T5** | 迁 T2 财报(3) + T5 categories(3) |
| **3.7 收敛 + 守卫** | 删除 `bootCombo` 及所有残留 `page.route('**/api/**' \| '**/auth/**')`；新增 `check:no-web-fetch` 守卫；此刻起 **零** e2e 依赖 Web fetch |
| **3.8 删 Web fallback（收尾）** | 删 App.tsx auth gate + LoginPage + 三个 service 与 DataAnalysisPage 的 fetch 分支 |

> **备选（更快但爆炸半径大）**：直接把 `bootCombo` **函数体**从 `page.route` 改成注入 electronAPI，一次性翻 ~150 个 caller。diff 小，但一处错则大批同样失败。鉴于「小 PR / 矩阵敏感 / 作者从不自行 merge」的工作约定，**推荐渐进**。

---

## 5. 每个 PR 的目标 / 范围 / 风险 / 验收

### PR-3.1 helper 地基 + 主矩阵先导

- **范围**：新增 `e2e/helpers/electronMock.ts`、`e2e/helpers/fixtures.ts`；改 `locale-matrix.spec.ts:64-117` 用 `bootComboIPC`。**不碰** App/services。
- **风险**：①漏 `providers:hasAny → true` → OnboardingWizard 抢渲染；②`api:request` 路由覆盖不全 → dashboard 不渲染 → 禁用词假绿/假红；③mock 数据须与 Web 版逐字节一致。
- **验收**：`npm run build` → `npx playwright test -g "ui="`（仅主矩阵）→ `npm run test:locale-ui` 全绿。

### PR-3.2 ～ 3.6（每组同模板）

- **范围**：仅改对应 describe 的启动调用 `bootCombo` → `bootComboIPC`（+ 3.4/3.6 的 `override`）。**只动** `locale-matrix.spec.ts`（3.5 额外重构 helper 内 `injectDocsElectronAPI`）。
- **风险**：per-test 自定义 route（agent-chat / conversations / categories 状态）必须等价折入 `override`，否则该测试断言变化。
- **验收**：`npx playwright test -g "<该组>"` → 全量 `npm run test:locale-ui` → `npm run check:locale-matrix`、`npm run check:raw-keys`（应不受影响，跑一遍确认）。

### PR-3.7 收敛 + 守卫

- **范围**：删 `bootCombo`、删全部残留 `page.route('**/api/**' | '**/auth/**')`；`injectDocsElectronAPI` 并入共享 helper；新增 `scripts/check-no-web-fetch.mjs` + `check:no-web-fetch`（grep `fetch('/api`、`fetch('/auth`、`LoginPage` 残留；**注释里禁写主机/路径字面量防自噬**，沿用现有守卫习惯）。
- **风险**：仍有测试漏注入 mock 会在此暴露（好事，响亮失败）。
- **验收**：`grep -rn "page.route" e2e/` 仅剩允许项（理想为 0）；`npm run test:locale-ui` 全绿；`npm run check:no-web-fetch` 此时应**仍报** App/services 的 fetch —— 那是留给 PR-3.8 的删除目标。

### PR-3.8 删 Web fallback（收尾）

- **范围**：见第 6 节清单。新增类型检查 `npx tsc --noEmit`（`vite build` 走 esbuild 不做全量类型检查，删代码易漏类型断裂）。
- **风险**：①若任一测试未注入 mock，App 无数据通道会**直接抛**（响亮失败，可接受）；②App.tsx auth 逻辑简化后须保证 OnboardingWizard 路径仍通；③`tsc` 可能暴露删除引发的类型错误。
- **验收**：`npm run build` + `npx tsc --noEmit` + `npm run check:all` + `npm run test:locale-ui` 全绿；`npm run check:no-web-fetch` 此时**转绿**（零 web fetch）。

---

## 6. 迁移完成后可删除的 Web fallback / auth gate / LoginPage

> ⚠️ **删除动作只能放到 PR-3.8，且必须在 PR-3.7 用 grep + `check:no-web-fetch` 证明「e2e 已零 Web fetch 依赖」之后才能做。** 任何一组测试尚未迁完，对应 fetch 分支不得删。详见第 11 节硬约束。

1. **`App.tsx`** — `AuthWrapper`（`:464-518`）的 Web 分支：`fetch('/auth/check')`（`:481`）、`authState` 三态简化为始终 authenticated、`<LoginPage>` 渲染（`:499`）+ import（`:27`）；登出按钮 `{!isElectronEnv && ...}` + `fetch('/auth/logout')`（`:375-387`）。onboarding 检查（`providers:hasAny`）改为无条件执行。
2. **`components/LoginPage.tsx`** — 整文件删除（`fetch('/auth/login')`，仅 Web 登录，桌面永不渲染）。
3. **`services/api.ts`** — `apiFetch` 的 Web fetch 分支（`:825-862`）；`isElectron()` 双路降级为单一 IPC（`electronInvoke` 的防御性 throw 可保留）。
4. **`services/aiBriefingService.ts`** — Web fetch 分支（`:21-32`）。
5. **`services/ocrService.ts`** — `analyzeInvoice` 的 Web fetch 分支（`:133-144`）。
6. **`components/DataAnalysisPage.tsx`** — `runAnalysis` 的 Web fetch 分支（`:336-366`）。
7. 新增 `check:no-web-fetch` 守卫防回归（并入 `check:all`）。

> 后端 `/auth/login | check | logout` 路由早已随旧 Web/云栈退役，桌面包从不含，无需再动。
> 行号为参照锚点，会随历史漂移；删除时以符号/分支语义为准并重新定位。

---

## 7. 暂时不能删 / 本阶段不动的

- **`vite preview` 作为 e2e server**（`playwright.config.ts`）—— 仍在浏览器跑 SPA，只是换注入桩；**不切真实 Electron**。
- **真实 Electron 打包应用 e2e** —— 路线图独立项，非 Phase 3。
- **`window.electronAPI` 检测 / `platform`（darwin 拖拽区 `App.tsx:343-354`）** —— 与 Web 无关，保留。删除后 `isElectronEnv` 在 App 内恒为真，是否进一步简化为「直接渲染 / 用 platform 判 darwin」属 PR-3.8 内的判断点，不强制。
- **IPC router / handlers（`electron/handlers/index.js`、`router.js`）、`OnboardingWizard`、`PENDING_ROUTES` 占位** —— 真实桌面逻辑，保留。
- **i18n locale 文件、`check:locale-matrix` / `check:raw-keys` 静态守卫** —— 不动（动了会改变矩阵基线）。
- **公式 / UI 文案 / locale / provider / LICENSE / coming-soon** —— 按工作约定，工程 PR 不碰（点名才动）。

---

## 8. 如何避免影响 6 语言 × 6 会计制度矩阵

1. **mock 数据逐字节复用**：IPC mock 的 `api:request` 直接返回现有 `SETTINGS(acc)/DASHBOARD(acc)` → 渲染 DOM 与 Web 模式完全一致 → 禁用词 / 简繁字符断言不变。
2. **`providers:hasAny → true`**：避免 OnboardingWizard 抢占 `AppContent` 渲染。
3. **保留 `localStorage 'sololedger-lang'` 注入**（与 Web/IPC 无关，控制 uiLanguage）。
4. **保留 `waitForSelector('nav')`** 同步点。
5. **不改 i18n 文件**：`check:locale-matrix` / `check:raw-keys` 是纯静态分析，**不依赖 e2e 启动方式**，迁移不影响它们。
6. **每 PR 跑全量** `test:locale-ui`（36 主矩阵 + 各 6×6 分组全覆盖 6 语言 × 6 制度）。
7. 截图仅作 artifact 落盘、**不做基线比对**，视觉差不会致测试失败。

---

## 9. 最终检查命令

```bash
npm run build                  # vite build 通过（IPC-only 后无残留 import 断裂）
npx tsc --noEmit               # 建议补：捕获删除引发的类型断裂（vite build 不做全量类型检查）
npm run check:locale-matrix    # 6×6 i18n 静态守卫（应不受影响）
npm run check:raw-keys         # 裸 i18n key 泄漏守卫（应不受影响）
npm run test:locale-ui         # = build + playwright，全部 IPC 启动后全绿
npm run check:no-web-fetch     # 新增守卫：零 fetch('/api|/auth) 与 LoginPage 残留（PR-3.8 后转绿）
npm run check:all              # 全部守卫聚合，收尾 PR 全跑一遍
```

> 本机注意：跑涉及 better-sqlite3 的测试前需 `npm rebuild better-sqlite3`，跑完 `npm run electron:rebuild` 还原 ABI（CI 上是 rebuild node ABI 真跑）。

---

## 10. 关键不变量（迁移期间必须恒真）

1. mock 返回的数据 = Web 版 `SETTINGS(acc)/DASHBOARD(acc)`（逐字节一致）。
2. `window.electronAPI` 在 React 求值 `isElectron()` 之前已注入（`addInitScript` 保证先于页面脚本执行）。
3. `providers:hasAny → true`，否则 onboarding 抢渲染。
4. `localStorage['sololedger-lang']` 注入保留，控制 uiLanguage。
5. mock 表面 = `{ invoke, platform, isElectron }`，与真实 preload 一致（不含 `buildTarget`）。
6. 每个 PR 后全量 `test:locale-ui` 绿；`check:locale-matrix` / `check:raw-keys` 绿。

---

## 11. 硬约束（务必遵守）

- **删除即终点**：删除 Web fallback / `LoginPage` / `App.tsx` auth gate 只能在 **PR-3.8**。
- **删除前置条件**：必须先在 **PR-3.7** 用 `grep -rn "page.route" e2e/` + `check:no-web-fetch` 证明「所有 e2e 已注入 mock electronAPI、零 Web fetch 依赖」。未达成则不得进入 PR-3.8。
- **一任务一分支一 PR**，只含相关文件；作者**从不自行 merge**（merge 由用户完成）。
- 工程 PR **不动**公式 / UI 文案 / locale / provider / LICENSE / coming-soon（点名才动）。
- 本阶段**不切真实 Electron e2e**，不改 `playwright.config.ts` 的 `vite preview` 服务方式。
- 默认先给 diff + 最小验证，**默认不 commit、不 push**。

---

## 12. 推进检查清单（勾选式）

- [ ] PR-3.1 helper 地基 + 主矩阵先导（`electronMock.ts` / `fixtures.ts`）
- [ ] PR-3.2 settings / purchase / backup-render
- [ ] PR-3.3 finance
- [ ] PR-3.4 AI 助手（含 agent-chat / conversations override）
- [ ] PR-3.5 business documents 页矩阵（+ 收敛 `injectDocsElectronAPI`）
- [ ] PR-3.6 T2 + T5
- [ ] PR-3.7 收敛：删 `bootCombo` + 残留 page.route + 新增 `check:no-web-fetch`
- [ ] PR-3.7 验证：`grep page.route e2e/` 仅剩允许项、`test:locale-ui` 绿
- [ ] PR-3.8 删 Web fallback / auth gate / LoginPage（前置条件已满足后）
- [ ] PR-3.8 最终：`build` + `tsc --noEmit` + `check:all` + `test:locale-ui` 全绿、`check:no-web-fetch` 转绿

---

## 13. 执行记录（2026-06-16 夜间自动推进，未 commit / 未 push）

> 边界：仅改 `e2e/locale-matrix.spec.ts` + 新增 `e2e/helpers/{fixtures,electronMock}.ts` + 本节记录；
> 零改 App.tsx / services/* / components/* / electron/* / package.json / i18n / schema；零删除 Web fallback。

**已落地（IPC-boot 迁移，全部验证通过）：**

- **PR-3.1** ✅ 新增 `e2e/helpers/fixtures.ts`（SETTINGS/DASHBOARD，从 spec 抽出，逐字节一致）+ `e2e/helpers/electronMock.ts`（`installElectronMock` + `bootComboIPC`，数据驱动 `apiResponses`，mock 表面 = `{invoke,platform,isElectron}` 无 `buildTarget`）；主仪表盘矩阵（36）→ `bootComboIPC`。基线 36/36，迁移后 36/36，全量 236/236。
- **PR-3.2** ✅ settings→products（36）+ purchase-picker（6）→ `bootComboIPC`。data-backup-tab **未迁**（见下）。组内 42/42，全量 236/236。
- **PR-3.3** ✅ finance balance/cashflow coming-soon（1）→ `bootComboIPC`（经 `apiResponses` 注入 `/api/reports/generate`）。export-pdf-button **未迁**（见下）。组 1/1，全量 236/236。
- **PR-3.4** ✅ assistant-page 矩阵（36）+ agent-trace（6）→ `bootComboIPC`（agent-chat 经 `apiResponses` 注入）。conversation persist/history **未迁**（见下）。组 42/42，全量 236/236。
- **PR-3.5** ◻︎ 仅注释：business-documents-page 渲染矩阵 **未迁**（见下）；`injectDocsElectronAPI` 重构 **推迟**（已 IPC 的通过测试做纯重构、零覆盖收益、状态化 CRUD + app:* 风险）。无功能改动。
- **PR-3.6** ✅ T2 财报（3，`bootDashboardWithFS` 体改 `bootComboIPC`，自定义 dashboard.financialStatement）。T5 recategorize **未迁**（见下）。组 3/3，全量 236/236。

**故意未迁（需后续决策，今晚不动）：**

- **桌面降级断言型**（断言「无 electronAPI → desktop-only 提示」，注入 mock 后该断言必然失败 → 属产品决策）：`data-backup-tab`、`finance export-pdf-button`、`business-documents-page` 渲染矩阵。
- **Node 侧录用调用型**（page.route 处理器在 Node 侧记录 payload 并断言；迁 IPC 须把录用搬进浏览器 mock + `page.evaluate` 回读）：`conversation persistence`、`conversation history`、`T5 recategorize`。其中 T5 与 conversation-sidebar 是两条已知本机时序 flake，留待单独处理以保归因清晰。

**最终验证（全绿）：** `npm run build` ✓ · `npm run check:locale-matrix` 379/379 ✓ · `npm run check:raw-keys` 0 findings ✓ · `npm run test:locale-ui` 236/236 ✓（每个 PR 后均跑过组内 + 全量）。

---

## 14. 执行记录 · PR-3.7（2026-06-16 续，未 commit / 未 push / 未 merge）

> 用户决策：① 桌面降级三组改为 IPC-only、验证真实桌面 UI（放弃 no-electronAPI 断言）；
> ② Node 侧录用三组批准浏览器侧 `recordCalls` 重构；③ 收敛 page.route/bootCombo/bootFinance/bootRecat
> + 新增 `check:no-web-fetch`；④ 严禁 PR-3.8（不删 App.tsx auth gate / LoginPage / services 与
> DataAnalysisPage 的 Web fallback）。边界内允许改 `e2e/*` + `package.json`（仅加守卫脚本）+ 本记录。

**helper 扩展**（`e2e/helpers/electronMock.ts`，向后兼容）：`apiResponses` 增 `method`/`bodyMatch`/`reject`/正则匹配；新增 `appChannels`（app:* 通道）、`recordCalls`（写 `window.__calls`，`page.evaluate` 回读）、`gotoApp`（只导航、不注入，给自带 mock 的测试用）。扩展后全量 236/236 不回归。

**6 组迁移（全部 IPC-only，验证通过）：**

- **桌面降级三组**（断言改为真实桌面 UI）：
  - `data-backup-tab`（36）→ 验证标题 + 启用的 备份/恢复 按钮 + 无 desktop-only 提示。
  - `finance export-pdf-button`（3）→ 点击导出走 `app:exportReportPdf` IPC、显示保存路径（原断 desktop-only）。
  - `business-documents-page`（36）→ 验证标题 + 空列表态 + 启用的新建按钮 + 无 desktop-only 提示。
  组合验证 75/75。
- **Node 侧录用三组**（改 `recordCalls` + `page.evaluate` 断言）：
  - `conversation persistence`（1）/ `conversation history`（1）→ create/append/rename/delete 经 `window.__calls` 断言。
  - `T5 recategorize`（4，含 commitFails 经 `reject` 模拟 + dryRun 经 `bodyMatch` 分支）。
  组合验证 6/6（含历史 flake 的 conversation-sidebar 与 recategorize 本轮均通过）。

**收敛**：删除未用的 `bootCombo` / `bootFinance` 助手定义；自带 electronAPI 的测试（data-backup-happy / OCR / BYOK / export-pdf-success / 全部 documents 模态）改用 `gotoApp` 导航。e2e 内 **零** `page.route('**/api'|'**/auth')`、零 `bootCombo(` / `bootFinance(` 代码引用。

**新守卫**：`scripts/check-no-web-fetch.mjs` + `package.json` 增 `check:no-web-fetch`（并入 `check:all`）。扫 `e2e/` 禁 `page.route(.../api|auth)`、`fetch('/api|/auth)`、已删助手调用；剥离 `//` 与 `/* */` 注释防自噬。

**最终验证（全绿）：** `npm run build` ✓ · `npm run check:locale-matrix` 379/379 ✓ · `npm run check:raw-keys` 0 ✓ · `npm run check:no-web-fetch` ✓ · `npm run test:locale-ui` 236/236 ✓。

**未动**（PR-3.8 前置仍未满足→不删）：`App.tsx` auth gate（`/auth/check`+`/auth/logout` 仍在）、`components/LoginPage.tsx`、`services/{api,aiBriefingService,ocrService}.ts` 的 Web fetch 分支、`components/DataAnalysisPage.tsx` 的 Web fetch 分支、`electron/*`、schema、i18n、会计/税务/金额逻辑。**e2e 现已零 Web fetch/auth 依赖 → PR-3.8（删源码 Web fallback）前置条件已满足，但按指令今晚不执行。**
