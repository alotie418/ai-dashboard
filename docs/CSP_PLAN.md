# CSP 安全策略计划（Content-Security-Policy）

> 状态：**计划草案 / 当前未启用（NOT ENABLED, NOT ENFORCED）**
> 文档日期：2026-06-26 ｜ 基线：main HEAD `bc05230`（🟢×15）
> 本文件仅记录只读分析与未来计划，**不改变任何运行时行为**。本仓当前**没有** CSP。

本文档固化一次针对 SoloLedger（Electron + Vite 本地桌面应用）的 CSP 只读分析结果，给出推荐策略草案、每条 directive 的代码依据、当前不能直接启用的原因，以及未来 PR-2 的实施与验证计划。

---

## 1. 目的与范围

- **目的**：为渲染进程文档增加一层纵深防御（限制脚本/样式/网络/worker 来源），降低「假设性注入 / 被污染依赖」可造成的影响面。
- **本文件不做**：不启用 CSP、不加 `<meta>`、不改 `index.html` / `vite.config.ts` / Electron main / preload / renderer、不加 `check:csp` 守卫、不做人工预览。
- **实施分两步**：本 PR-1 = 仅本计划文档；PR-2（将来，需显式解禁 enforce）= 生产构建注入 meta CSP + `check:csp` 守卫 + 全量验证 + 人工 QA。

---

## 2. 当前状态（已对照代码核实）

| 维度 | 事实 | 出处 |
|---|---|---|
| BrowserWindow | `contextIsolation:true`·`nodeIntegration:false`·`sandbox:false`·无 `webSecurity` 覆盖（默认 true） | `electron/main.js` |
| 加载方式 | 生产 `loadFile(dist/index.html)` = **file://**；dev `loadURL('http://localhost:3000')`（Vite HMR） | `electron/main.js` |
| 现有 CSP | **无**（无 meta、无 `onHeadersReceived`、无自定义协议、无 session 头注入） | 全仓 |
| 内联 `<script>` | **无**（仅外链 module script，dist 为 `./assets/index-*.js` crossorigin） | `index.html` / `dist/index.html` |
| 内联 `<style>` | **有**（`index.html` 手写 body/scrollbar 基础样式，随 dist 带出） | `index.html` |
| favicon | `data:image/svg+xml`（emoji SVG） | `index.html` |
| eval / new Function / wasm（源码） | **零** | 源码扫描 |
| pdf.js | 动态 import；worker = Vite `?url` 自托管 `.mjs`；`getDocument({data})` 传 ArrayBuffer（不联网） | `services/pdfRaster.ts` |
| OCR/单据图像预览 | 无 `<img>` 内联渲染（预览展示字段；附件经 IPC `shell` 打开） | 组件扫描 |
| blob: | `URL.createObjectURL` 仅用于导出下载锚（CSV/数据） | `DataAnalysisPage` / `CsvImportModal` |
| **AI 请求位置** | **在 main 进程发起**（Node fetch + `@google/genai` SDK）；renderer 全走 IPC（`check:no-web-fetch` 守卫钉死源码无 web fetch） | `electron/ai/*` + 守卫 |

---

## 3. 推荐 CSP 策略草案（**当前不启用 / 不 enforce**）

> 仅作为 PR-2 的设计目标记录。**本 PR 不写入任何文件、不注入 meta。**

```
default-src 'self';
script-src 'self';
style-src 'self' 'unsafe-inline';
img-src 'self' data: blob:;
font-src 'self';
connect-src 'self';
worker-src 'self' blob:;
object-src 'none';
base-uri 'self';
form-action 'none';
```

### 每条 directive 的依据

| Directive | 取值 | 依据（基于代码事实） |
|---|---|---|
| `default-src` | `'self'` | 兜底最小化；其余 directive 显式放开必需项。 |
| `script-src` | `'self'` | **无内联 `<script>`**；脚本均外链 `./assets/*.js`。源码零 `eval`/`new Function`。pdf.js 默认 `isEvalSupported` 会试 `new Function`，但 CSP 拦截时**自动 try/catch 降级**（不硬失败）→ **不需 `'unsafe-eval'`**（⚠️ 需 PR-2 手动 OCR 验证降级确实 OK）。 |
| `style-src` | `'self' 'unsafe-inline'` | `index.html` 有手写内联 `<style>`；且 React / recharts 大量使用 `style=""` 内联属性 → **`'unsafe-inline'` 实际必须**（外链 CSS 由 `'self'` 覆盖）。 |
| `img-src` | `'self' data: blob:` | favicon 为 `data:image/svg+xml`（需 `data:`）；`blob:` 为防御性预留（导出/未来图像预览）。 |
| `font-src` | `'self'` | Inter / Font Awesome 字体（woff2/ttf）构建期自托管，无 CDN、无 data: 字体。 |
| `connect-src` | `'self'` | **renderer 不直发网络请求**（全走 IPC）；懒加载 chunk / pdf worker 等本地取用归 `'self'`。**不含 provider 域名**（见 §4）。 |
| `worker-src` | `'self' blob:` | pdf.js worker 为自托管 `.mjs`（`'self'`）；pdf.js 在部分场景以 blob 方式实例化 worker → 含 `blob:` 兜底。 |
| `object-src` | `'none'` | 无 `<object>`/`<embed>`/Flash。 |
| `base-uri` | `'self'` | 防 `<base>` 标签劫持相对路径。 |
| `form-action` | `'none'` | 应用无原生表单提交（React 受控组件 + IPC）。 |

---

## 4. 为什么 provider host **不**放进 `connect-src`

- **AI 请求在 main 进程发起**：渲染端通过 `electronInvoke`(IPC) 调用，main 进程用 Node `fetch` / `@google/genai` SDK 直发各 provider；`check:no-web-fetch` 守卫已钉死源码侧无 `fetch(/api|/auth)`。
- **meta CSP 是文档级、只约束 renderer**，**管不到 main 进程的网络请求**。
- 因此 8 家 provider 域名（anthropic / openai / googleapis / deepseek / dashscope / moonshot / bigmodel / volces 等）**无需**出现在 `connect-src`，renderer `connect-src 'self'` 即足够。
- 这是该架构下 CSP「既简单又安全」的根本原因：**最敏感的外发网络在 CSP 作用域之外，但同时也意味着 CSP 不是用来管 AI 外发的——AI 外发的边界由 [`PRIVACY.md`](../PRIVACY.md) 描述，不由本 CSP 负责。**

---

## 5. 为什么不能硬写进 `index.html`

- `npm run dev` 使用 Vite HMR：依赖内联脚本 / `eval` / `ws://` 连接。**静态写死严格 meta 会直接破坏 dev**。
- `npm run test:locale-ui` 用 `vite preview` 服务 dist（生产产物）→ CSP 会在此生效，需确保 e2e mock 注入方式不被 CSP 拦。
- 结论：**CSP 必须仅在生产构建注入**（PR-2 用 Vite `transformIndexHtml` 插件 build 期加 meta），**不能**直接写进 `index.html` 源文件。

---

## 6. file:// + meta CSP 的限制

- file:// 文档无 HTTP 响应头 → **只能用 `<meta http-equiv="Content-Security-Policy">` 注入**。
- meta 形式**不支持**：`report-only`（仅 HTTP 头形式）、`frame-ancestors`、`report-uri` / `report-to`、`sandbox` —— 这些写进 meta 会被忽略。
- 影响评估：本应用无 iframe，`frame-ancestors` 缺失影响小；无上报端点，`report-uri` 不可用 → 见 §7 的替代反馈方式。

---

## 7. report-only 不可用时的替代反馈方式

由于 file:// + meta 无法 report-only，PR-2 采用以下「等价 report-only」的反馈手段（择一/组合）：
1. **手动验证 + `securitypolicyviolation` 事件日志**（推荐）：enforce 上线前临时挂 `document.addEventListener('securitypolicyviolation', e => console.warn(...))`，逐功能跑一遍看 DevTools 控制台违规。
2. DevTools 控制台本身会自动打印 CSP 违规——人工 QA 时直接观察。
3.（重型·不在计划内）切自定义 `app://` 协议 + `protocol.handle` 返回带 `Content-Security-Policy-Report-Only` 头的 Response —— 属架构改动，**不采用**。

---

## 8. 未来 PR-2 计划（需显式解禁 enforce 后才做）

1. **Vite 生产构建注入 meta CSP**：`transformIndexHtml` 插件，仅 `apply: 'build'`（dev 不注入，保 HMR）；策略取 §3 草案。
2. **新增 `check:csp` 守卫**：扫 `dist/index.html` 断言含预期 CSP meta 与各 directive（与 `check:offline` 同类·纯 Node·入 `check:all`）。
3. **全量验证**：见 §10 验证命令。
4. **人工 QA**：见 §9 清单。
5. **回滚预案**：见 §11。

> 注：`check:csp` **不宜单独先行**——守卫一个尚不存在的 meta 只能空过或误失败，必须与 meta 同 PR（PR-2）。

---

## 9. PR-2 人工 QA 清单（enforce 前必跑，盯 DevTools 控制台 CSP 违规）

- [ ] 各核心页面渲染正常（看板 / 采购 / 销售 / 库存 / 发票 / 单据 / 财务 / 数据分析 / 设置 / US 税务工具 / 助手页）
- [ ] **图表**（recharts）正常显示（验 `style-src 'unsafe-inline'`）
- [ ] **markdown** 渲染正常（AI 回复 / 简报）
- [ ] **PDF OCR**（最高风险）：上传 PDF → 栅格化 → OCR 全链路（验 worker-src + pdf.js eval 降级）
- [ ] **CSV / xlsx 导入**（CsvImportModal）正常
- [ ] **CSV / 数据导出**（blob 下载锚）正常（DataAnalysis / CSV 导出）
- [ ] **AI 助手对话 / 看板经营简报**正常（确认 IPC 路径不受 renderer CSP 影响）
- [ ] **单据附件打开**（IPC `shell` 打开外部）正常
- [ ] favicon 正常显示（验 `img-src data:`）
- [ ] 字体（Inter / Font Awesome）正常（验 `font-src 'self'`）
- [ ] 全程 **DevTools 控制台无 `securitypolicyviolation`**（或仅剩已知可接受项）
- [ ] `npm run dev` HMR 不受影响（确认 CSP 仅生产注入）

---

## 10. PR-2 验证命令

```
npm run build
npm run check:offline
npm run check:all          # 含将来的 check:csp
npm run typecheck
npm run test:locale-ui     # vite preview 下 e2e（确认 CSP 不破坏 mock 注入）
npm run audit:locale-ui:smoke
npm run audit:locale-ui:candidates
npm run test:electron      # 真 main 进程
# + 人工预览（§9 清单）
```

---

## 11. 主要风险与回滚方式

### 风险
1. **pdf.js eval 降级未生效** → OCR 异常（`script-src` 无 `'unsafe-eval'`）。**最高风险**，靠 §9 手动 OCR 验证兜底。
2. **图表/内联样式被拦**（漏 `style-src 'unsafe-inline'`）。
3. **favicon / 懒 chunk / worker 被拦**（漏 `data:` / `blob:` / `'self'`）。
4. **静态写 meta 破坏 dev HMR + `test:locale-ui` 的 vite preview + e2e mock 注入** → 必须构建期注入、仅生产。
5. **过严策略只在某条用户路径触发** → 晚发现。靠 §9 全功能 pass + `securitypolicyviolation` 日志降低。

### 回滚
- CSP = 生产 `dist/index.html` 一行 `<meta>`（由一个 Vite 插件开关控制）。
- **回滚 = 移除该 meta / 关闭插件 / `revert` 整个 PR-2**：**一行级、即时生效、零数据影响**——这是 meta CSP 的核心安全属性。

---

## 12. 与发布前安全专项的关系

- 本 PR-1（计划文档）**零风险**，先沉淀分析、避免遗忘。
- PR-2（meta enforce + `check:csp`）建议**排进发布前安全专项**（与「签名 / 公证」同批）：CSP 是分发前更该补的纵深防御；实现成本低（一行 meta + 插件）但需一次集中的人工 QA pass。
- **不建议在未做人工 QA 窗口时直接上 enforce。**

---

*相关文档：[README](../README.md) ｜ [PRIVACY](../PRIVACY.md) ｜ [产品路线图](ROADMAP-to-v1.md)。本文件为工程计划记录，非安全合规认证。*
