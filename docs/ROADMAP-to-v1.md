# SoloLedger — 距离「成品」(v1.0) 的差距路线图

> 来源:2026-06-15 全项目只读审计(8 个并行 agent 覆盖 构建/分发、双架构、测试/CI、会计口径、AI·OCR、数据安全、安全、文档·i18n·UX)。
> 性质:**只读审计的产出清单**,本文件本身不改任何代码。每项给出 严重度 / 证据(file:line) / 动作 / 工作量(S/M/L)。
> 用法:把每个 `- [ ]` 当 tracker 勾。**永不在工程 PR 内擅自改税务口径公式**(见 Track A)。
>
> **状态更新（2026-07-07·main `3fc241e`）**:本文件是 2026-06-15 时点的审计快照,原文与勾选框保留不动;此后大量条目已落地,**活跃发布状态以 [`PRE_RELEASE_CHECKLIST.md`](PRE_RELEASE_CHECKLIST.md) 为准**。已核实完成的主要簇:
> - **§2A 数据安全——全部落地**:启动滚动快照(保留 N 份+迁移前强制)、备份默认落「文稿」目录、附件随 bundle 备份/恢复、单实例锁、`synchronous=FULL`+`busy_timeout`、磁盘错误码映射(diskErrorCode)、per-table CSV 导出。
> - **§2B 测试/CI——大部落地**:GitHub Actions CI(`.github/workflows/ci.yml`)、handler round-trip(`test-handlers.mjs`)、迁移守卫(`test-migrations.mjs`)、`typecheck` 门禁、真 Electron e2e 26 条(附件 IPC/附件 fs/**备份恢复闭环 #353**)。未做:vitest 框架迁移、husky。
> - **§4 Track B——全部落地**:web 栈已于 2026-06-16 删除归档(`archive/web-legacy` 分支)、云资源退役、`services/api.ts` 已 IPC-only 且有 `check:no-web-fetch` 守卫、`worker/src/index.js` 第二套会计引擎**已随 worker/ 删除**。
> - **§1 分发门槛——基本落地（2026-07-07 更新）**:LICENSE(#346)、copyright/死 `BUILD_TARGET` 清理(#347)、`publish:null` 关闭误导性更新 feed、`asarUnpack @napi-rs/canvas` 已入 `dmg.yml`、`build:mas` 已删;**签名/公证已完成**(#355 接线 + PR-C 真机执行成功·Notarized Developer ID·实测记录见 [`RELEASE.md`](RELEASE.md) §9);**版本纪律进行中**(当前 **1.0.0-rc.2 准备中**——rc.1 已发 Pre-release,RC QA 发现的 **Excel 导入日期 blocker 已由 #357 修复并真机复测通过**,rc.2 负责把修复交付到可下载构建;正式 1.0.0 前剩余 QA:Woo 真店、safeStorage 重录)。未做:universal/Intel 决策、auto-update(local-first 有意不做)。
> - **仍未完成**:§2C 8 家 provider 真实 Key 验收、Track A 会计师确认(B1–B5)、§5 打磨项若干。
> - 2026-07 增量:依赖安全 #350(genai 1.52)、onboarding 免 AI Key 准入 #351、xlsx→SheetJS CDN 0.20.3 #352(**生产 `npm audit --omit=dev` = 0**)。

---

## 0. 总体结论

代码本身已接近 v1.0:架构干净、IPC 是白名单不是透传、SQL 全参数化、`safeStorage` 密钥处理正确、i18n 六语言零漂移(1083 keys × 6,0 缺失)、报表口径(T 系列后)有净利不变量测试锁定、AI 工具调用被守卫钉死为只读。

**真正的差距不在「写得好不好」,而在两件事**:
1. **能不能交付给别人用**(分发:签名/公证/universal/自动更新/README 诚实度/LICENSE)。
2. **能不能被信任为唯一账本**(数据安全/迁移测试/CI/真实 Key 验收/会计师签字)。

> 仓库里最弱的产物是 **README**(描述的是旧的 web/语音/3-provider 产品),不是代码。

### "成品"的两层定义
- **L1 自用成品**:你自己/小范围手动分发。→ 必过 §2(信任为唯一账本)+ §4 关键打磨;§1 分发门槛可大幅降级。
- **L2 可分发成品**:给陌生用户。→ 还要过 §1(签名/公证/universal)。

---

## 1. 🚫 分发门槛(L2 才必须;`electron-builder.dmg.yml` 注释自承"本地自用未签名")

- [ ] **代码签名(Developer ID)** — Blocker — `electron-builder.dmg.yml:30` `identity:null`;`codesign` 显示 adhoc、`Identifier=Electron`;`spctl` rejected — 动作:Apple Developer 账号($99/年)→ Developer ID Application 证书 → `CSC_LINK`/`CSC_KEY_PASSWORD` — **M**
- [ ] **公证 + stapler + hardened runtime** — Blocker — `dmg.yml:1,31`(注释"不公证"、`hardenedRuntime:false`);装了 `@electron/notarize@^2.5.0` 但**全代码零引用**(死依赖) — 动作:`afterSign` 接 `@electron/notarize`(`APPLE_ID`/`APPLE_APP_SPECIFIC_PASSWORD`/`APPLE_TEAM_ID`)+ `xcrun stapler staple` + `hardenedRuntime:true` — **M**
- [ ] **entitlements.mac.plist** — Blocker(与公证耦合) — 仓库无 entitlements 文件 — 动作:建 `build/entitlements.mac.plist`(allow-jit / allow-unsigned-executable-memory / disable-library-validation 给解包的 .node)并在配置引用 — **S–M**
- [ ] **universal / Intel 构建** — Important — `dmg.yml:29` `arch:arm64`,release 仅 arm64 dmg — 动作:`arch:universal`(注意 `better-sqlite3` 与 `@napi-rs/canvas` 双架构原生二进制都要在) — **M**
- [ ] **`build:mas` 是坏的** — Important(死 script) — `package.json:40` 引用不存在的 `electron-builder.mas.yml`,无 MAS entitlements/provisioning — 动作:**直接删** `build:mas` + `BUILD_TARGET=mas` 管线(MAS 沙箱与解包 native 冲突,非短期目标) — **S**(删)/L(真做)
- [ ] **自动更新半接线** — Important — 生成 `release/latest-mac.yml` + 打包内 `app-update.yml`(含内部 repo slug),但 `electron-updater` **未安装、零引用**;配置无 `publish:` — 动作:要么接通 `electron-updater`+真 `publish:`,要么 `mac.publish:null` 关掉误导性 feed(v1.0 手动分发推荐后者) — **S**(关)/M-L(接通)
- [ ] **显式 asarUnpack `@napi-rs/canvas`** — Important — `dmg.yml:21-22` 只解包 better-sqlite3;`@napi-rs/canvas`(经 pdfjs-dist)目前靠 electron-builder 自动探测解包,脆弱 — 动作:加 `**/node_modules/@napi-rs/**` 并注释原因 — **S**
- [ ] **发布流程 / 版本纪律 / CHANGELOG** — Important — 版本卡 `0.1.0`、无 git tag、无 CHANGELOG、`release/` gitignore;`latest-mac.yml` 的 releaseDate 永远停在旧值 — 动作:每次发布打 tag + CHANGELOG + `docs/RELEASE.md` — **M**
- [ ] **`copyright` 用法人而非产品名**(cosmetic) — Nice — `dmg.yml:6` — **S**

---

## 2. 🔴 信任为唯一账本(L1/L2 都必过)

### 2A. 数据安全(不可逆丢失风险 —— 最高优先)
- [ ] **没有任何自动备份** — Blocker — 只有手动 `app:exportDb`(`DataBackupSection.tsx`),无 setInterval/启动/退出备份 — 动作:**启动时(在 `runMigrations` 之前)** 自动滚动备份到 `userData/backups/`,保留最近 N 份 — **M**
- [ ] **备份默认路径是裸文件名** — Important — `electron/handlers/index.js:72` `defaultPath:'sololedger-backup-...db'` 无目录前缀 → 落到 CWD/bundle 旁,重装即丢 — 动作:前缀 `app.getPath('documents')` — **S**
- [ ] **附件不进备份/恢复** — Important — 备份只 copy `sololedger.db`(`index.js:77`),`userData/attachments/docs/*` 不复制;恢复后 `tax_invoice_attachment_path`/`attachment_path` 全悬空,UI 不警告 — 动作:备份打成 zip/文件夹(DB+attachments)一起恢复,或至少 UI 明确警告 — **M**
- [ ] **无单实例锁** — Important — 无 `app.requestSingleInstanceLock()`(`main.js:46-67`);双开同一 WAL DB → `SQLITE_BUSY`/恢复时 rename 可能损坏另一连接 — 动作:加锁,非主实例聚焦已有窗口并退出 — **S**
- [ ] **`synchronous=NORMAL` + 无 `busy_timeout`** — Important — 仅设 `journal_mode=WAL`+`foreign_keys=ON`(`db/index.js:29-30`);断电可能丢最后一笔已提交事务 — 动作:`pragma('synchronous=FULL')` + `pragma('busy_timeout=5000')`(单用户、写量小,持久性 > 速度) — **S**
- [ ] **迁移前不快照** — Important — `runMigrations` 启动无条件跑(`db/index.js:32`),迁移是事务化+版本化(已好),但"成功但写错数据"无回滚点 — 动作:与"启动前自动备份"合并解决 — **S**(在 2A#1 之后)
- [ ] **自动备份累积无清理** — Nice — restore 前自动备份永不清(`index.js:136-140`) — 动作:保留最近 N — **S**
- [ ] **磁盘满/写失败无专门提示** — Important — 普通写无 try/catch,`SQLITE_FULL` 冒泡成通用 `AI_ERR:unknown`(会回滚不损坏,仅提示差) — 动作:把 `SQLITE_FULL`/`SQLITE_IOERR` 映射为可操作错误 — **S**
- [ ] **无结构化数据导出(CSV/Excel)** — Important — 能导入(`batch.js`/`CsvImportModal`)却不能导出原始交易;唯一整库出口是二进制 `.db` — 动作:per-table CSV/Excel 导出(交易/采购/销售/单据),供会计师交接与迁出 — **M**

> ✅ 已做得好(勿动):WAL+FK on、迁移事务化+`user_version` 版本化+幂等、备份前 `wal_checkpoint(TRUNCATE)`、恢复有 header/`quick_check`/版本上限校验+覆盖前自动备份+原子 rename、附件路径白名单防穿越、seed 幂等(`INSERT OR IGNORE`)。

### 2B. 测试与 CI(持久化层零自动化验证)
- [ ] **完全没有 CI** — Blocker — 无 `.github/`;20+ `check:*` 守卫全靠人工跑 — 动作:`.github/workflows/ci.yml`(macos-latest 跑 `npm ci`+`electron-rebuild`+全部 check + `test:locale-ui`) — **M**
- [ ] **IPC handler / DB schema / 12 个迁移 = 零执行测试** — Blocker — 测试只覆盖 `reports/*`、`_metrics`、`_recategorize`、`ai/*`;`router.js`/`purchases`/`sales`/`inventory`/`payment`/`receivables`/`dashboard`/`transactions`/`documents`/`batch`/`migrations`/`db/index.js` 从不被执行 — 动作:用 `new Database(':memory:')`+真迁移写 handler round-trip 测试 — **L**
- [ ] **迁移专项测试** — Blocker(数据丢失炸弹) — `migrations.js` 12 版无测试 — 动作:从旧 schema 跑到 head,断言每版幂等+保 row 数 — **M**
- [ ] **无测试框架 / 无 `npm test` / 无 `tsc --noEmit`/lint 门禁** — Important — `package.json` 无 jest/vitest/test/lint/typecheck;现有"单测"是手写 `.mjs`+`process.exit(1)` — 动作:引 vitest,迁移现有 ~7 个 .mjs,补 `typecheck`/`eslint` 并入 CI — **M**
- [ ] **e2e 从不跑真 Electron** — Important — `playwright.config.ts:18` 驱动 `vite preview` chromium、API 全 mock,`window.electronAPI` 是 stub — 动作:加 `_electron.launch({args:['.']})` 小套件(启动/一次真 IPC 落账/备份恢复) — **M**
- [ ] **AI 工具调用仅 adapter 层测,无活循环 e2e** — Important — `test-agent-providers.mjs` 好但只测 stub+over-rounds break — 动作:fake adapter+真 tools+`:memory:` DB 驱动 `runAgentLoop`,断言只读+读到真聚合 — **M**
- [ ] **守卫是 grep 级、可能与运行时脱节** — Nice — `check-disclaimer.mjs` 只查字符串出现、不查真渲染 — 动作:e2e 断言免责声明/税标签真的可见 — **S–M**
- [ ] **无 pre-commit / husky** — Nice — 动作:husky+lint-staged 跑秒级守卫 — **S**

### 2C. AI 8 家 provider 零真实 Key 验收(BYOK 核心卖点)
- [ ] **8 家 provider 从未碰真实 API** — Blocker(运营) — 所有测试 stub `fetch`;国产五家错误体未必符合 `_error.js` 假设的 OpenAI 信封 — 动作:真实 Key 矩阵(连接/对话/多轮工具调用查账/OCR/强制错误路径),捕获国产真实 error-body JSON 形状核对 `_error.js` `pickField` — **L**(需拿 8 把真 Key,部分要实名+开模型)
- [ ] **默认 model ID 可能 404** — Important — `gpt-5.5`(openai.js:19)、`gemini-3.5-flash`(gemini.js:26)、`claude-opus-4-7`(anthropic.js)、`deepseek-v4-pro`、`kimi-k2.6`、`glm-5.1`、`doubao-seed-2-0-pro-260215` 多个领先于公开发布;有兜底(自由文本改 ID + `MODEL_MIGRATION_MAP`)但新装首聊可能直接失败 — 动作:逐个对真 API 核对默认 ID;`modelNotFound` 时把"高级 model ID 输入框"内联弹出更可发现 — **S**+**S**
- [ ] **AI 调用不可真正取消** — Important — renderer 90s `Promise.race` 放弃,但 main 进程 `fetch` 无 `AbortSignal`(`electron/ai/*` 无 AbortController),仍在跑+计费;`runAgentLoop` 只能在轮次间停 — 动作:从 IPC handler 把 `AbortController` 串进各 adapter `fetch` + Gemini SDK `abortSignal` + 每轮 abort 检查 — **M**

---

## 3. 🧮 Track A — 需会计师确认(并行轨道,**永不在工程 PR 内动公式**)

> 会计 agent 结论:在「经营管理估算工具」定位 + 全面免责声明下**站得住**;第一次审计的 COGS=全部费用大坑已被 T 系列修复且净利不变量有测试锁。以下是精度判断,需签字"扁平估算可接受",不是改代码。

- [ ] **B1 所得税单一税率** `max(0,利润)×率`,忽略累进/小微(CN 小微、US 个人税阶/QBI、KR 累进) — `cn.js:39`/`jp.js:28`/`kr.js:27`/`eu.js:27`/`tw.js:27`/`us.js:76,102` — 对低利润单人公司可能偏差大,**最大精度缺口**
- [ ] **B2 CN 附加 12%** 城建按市区假设(`accountingProfiles.ts:35`);非 CN=0 — 可配但默认防御性需签字
- [ ] **B3 VAT/消費税/부가가치세/營業稅 简化** `max(0,output−input)`,留抵被 clamp 到 0 丢失、无非抵扣项/简易计税(簡易課税·간이과세) — `cn.js:32` 等
- [ ] **B4 US 用 21% 公司税率算 Schedule C 个人**、无 QBI(§199A)/州税/标准扣除(SE-tax 本身已做好,年表 2024/25/26) — `us.js:76`、`accountingProfiles.ts:49`
- [ ] **B5 US `grossReceipts` 用含税 `amount`** 而非 net(US 无 VAT,影响小) — `us.js:15`
- [ ] **EU 是通用平均**(VAT 20%/所得税 25%),无国别子路由
- 👉 README/免责声明应把以上 7 点对用户**明确写出**。

---

## 4. 📦 Track B — 清理双架构 / 死代码 / 泄露(一揽子,Important)

> 仓库是"两个头":2026-02 起家 web(Cloud Run + Cloudflare Worker/D1),2026-05 fork 成 Electron;之后所有会计开发都在桌面侧。DMG **不含** web 栈(`electron-builder.dmg.yml:14-18`),但 web 栈是分叉/泄露负债。

- [ ] **删除/归档整个 web 栈** — Important — `server.js`、`server/`、`worker/`、`Dockerfile`、`Procfile`、`.gcloudignore`、`deploy.sh`、`wrangler.toml`(可移 `archive/web-legacy` 分支保历史) — **S**(删)/M(文档化)
- [ ] **`worker/src/index.js` 是第二套会计引擎** — Blocker(口径可信度) — `:2515` 硬编码 12%、`:2526` 25%、CN-only 无 locale 路由、tonnage 模型;同名产品两个"净利润"答案(`TODO(PR-T2)` 自承) — 动作:**删,不要修**(修=把 6 个 locale 移植进不用的文件) — **S**(删)/L(统一)
- [ ] **`wrangler.toml` 提交了生产基础设施 ID** — Blocker(泄露) — `:6` Cloud Run/域名源、`:15` D1 `database_id`、`:19` KV namespace id — 动作:随 web 栈删除;若 Cloudflare 资源已退役,服务端也拆 — **S**
- [ ] **`server.js` AI 路径绕开全部免责声明** — Important — `server.js:224-228` 硬编码"专业商业分析师"prompt、`:350-354` 吨/¥ CN-only、无 `boundaryDirective`;`check:disclaimer` 不覆盖 server.js — 动作:随 web 栈删除(若留则注入 boundary) — **S**
- [ ] **`start: node server.js` 默认指向死服务器** + `express`/`helmet`/`express-session`/`http-proxy-middleware`/`bcryptjs` 仅为死 server 存在 — Important — `package.json:15,47-54` — 动作:repoint/删 `start`,剥离依赖 — **S**
- [ ] **`services/api.ts` 双传输** — Important — `:794-845` IPC + web `fetch` 双分支、`/api 404 fallback` — 动作:收敛为 IPC-only — **M**

---

## 5. 🟠 v1.0 打磨项(不阻断运行,但"成品感"需要)

- [ ] **README 系统性过期 = 实际 Blocker** — `docs #1` — 错称 3 provider(实 8)、语音 TTS(已全删)、D1/Cloud Run 架构、Agentic RAG 六源搜索(对应 `MarketSearchPage`/`useAgenticSearch`/`geminiService` 等文件**全不存在**)、10kg/袋吨数模型、`gpt-5.5`/`gemini-*-preview` 默认、目录结构/Scripts 全错、"MIT license"无 LICENSE 文件 — 动作:**重写**为本地/8-provider/无语音/无云的真实产品 — **M**(整个仓库最该先修的单点)
- [ ] **资产负债表/现金流量表是 "coming soon" 空壳** — Important — `FinancePage.tsx:322-343`,`en.json:817-829` — 动作:实现 或 v1.0 先隐藏 tab — **L**(实现)/S(隐藏)
- [ ] **无 LICENSE** — Important — `ls LICENSE*` 无 — 动作:加 MIT(与 README 一致) — **S**
- [ ] **无隐私声明/EULA** — Important — 无 PRIVACY/EULA、UI 无隐私文案 — 动作:加 `PRIVACY.md`(本地存储/safeStorage 加密/直连 provider 不经服务器)+ 可选 in-app 法律页 — **S**
- [ ] **无 CSP** — Important(纵深防御) — `index.html`/`dist/index.html` 无 CSP,`main.js:36` 无 `onHeadersReceived` 注入 — 动作:`default-src 'self'`,`connect-src` 仅限配置的 provider host,`img-src 'self' data:` — **M**
- [ ] **`xlsx@^0.18.5` 高危漏洞随包发布** — Important — `package.json:66`,`CsvImportModal.tsx:112` 动态 import 解析用户上传 — 原型污染+ReDoS、**npm 无修复版** — 动作:换 SheetJS 官方 CDN 补丁线/迁移到维护中的库/解析前 freeze `Object.prototype` — **M**
- [ ] **`shell.openExternal` 仅 `startsWith('http')`** — Important — `main.js:40-43`;AI markdown/grounding 可造任意 https URL — 动作:`new URL()` 解析,仅允许 `http:`/`https:` 精确匹配 — **S**
- [ ] **无 `will-navigate` 守卫** — Nice — `main.js` 仅 `setWindowOpenHandler` — 动作:加 `will-navigate` preventDefault 非本源 — **S**
- [ ] **OCR 只读 PDF 第一页且不告知** — Important — `pdfRaster.ts:16` `getPage(1)`;2 页发票静默丢 — 动作:读 `numPages`,>1 时多页 OCR 合并 或 至少提示 — **M**(提示 S)
- [ ] **OCR 无低置信/缺字段提示** — Nice — `ocrService.ts:159-194` 缺字段静默补 0、taxRate 由可能误读的金额派生(已有 preview→confirm 兜底) — 动作:preview 里高亮 0/'' 字段 — **S**
- [ ] **Dashboard 无首屏空状态** — Important — 新用户显示一堆 $0 而非引导 — 动作:加"还没数据—导入或新增第一笔"空态 — **S**
- [ ] **可访问性薄弱** — Important — 全仓 ~4 个 `aria-*`,几无键盘导航/focus trap/Escape 关弹窗/icon 按钮 aria-label — 动作:弹窗 Escape+focus 管理、icon 按钮 aria-label — **M**
- [ ] **无暗色模式** — Nice — 零 `dark:`/`prefers-color-scheme` — **L**
- [ ] **无 in-app 用户指南/tooltip 系统** — Nice — `docs/` 仅 `INTERNATIONALIZATION_PLAN.md`(内部);靠 45+ info-circle 旁注 — 动作:简短用户指南/Help 页 — **M**
- [ ] **ja/ko/fr 长文案需人工抽查**(机器只能验 key parity,验不了"是否真翻译") — Nice — **S**
- [ ] **`.env.local` 未进 `.gitignore`** — Nice(目前未 tracked) — 动作:加进 `.gitignore` — **S**
- [ ] **bump Electron 到 v33 最新 patch**(ASAR Integrity/AppleScript 注入 advisory,当前 33.4.11) — Nice — **S**
- [ ] **DataAnalysisPage forecast 是占位模型** — Nice(内部 TODO,有免责覆盖) — `DataAnalysisPage.tsx:99,162,198` — 动作:v1.0 留,排期真预测引擎 — **L**(future)
- [ ] **`providerMessage` 截断可能含密钥片段** — Nice — `_error.js:62` — 动作:对 `sk-`/`Bearer` 做 redaction — **S**
- [ ] **`BUILD_TARGET` env 在打包运行时不生效**(靠 `process.mas` 兜底,无害但误导) — Nice — `main.js:9`/`preload.js:14` — **S**

---

## 6. ⚡ 快速见效(S 工作量,几小时清一批)

单实例锁 · `synchronous=FULL`+`busy_timeout` · 备份默认路径→`~/Documents` · 删 `build:mas` · 关误导性自动更新 feed · `openExternal` https 白名单 + `will-navigate` · `.env.local` 进 `.gitignore` · 加 `LICENSE` + `PRIVACY.md` · 隐藏两个 coming-soon tab · 加 `tsc --noEmit`/`test` 聚合 script · `providerMessage` redaction · 显式 asarUnpack canvas。

---

## 7. 建议执行顺序

1. **README 重写 + 删/归档 web 死栈**(澄清产品边界 + 去基础设施泄露)— 成本低、止血快。
2. **数据安全一揽子**(启动前自动备份 + 单实例锁 + `synchronous=FULL` + 备份路径 + 附件入备份)— 保护唯一账本。
3. **真实 Key 验收 8 家 provider** + 核对默认 model ID。
4. **CI + 持久化层/迁移测试 + 真 Electron e2e** + `tsc`/lint 门禁。
5. **会计师确认口径**(Track A,并行,不阻塞工程)。
6. **分发:签名/公证/universal/自动更新**(决定要不要对外发后再做)。
7. **打磨:**两张报表、LICENSE/隐私、CSP/xlsx、可访问性、空状态、CSV 导出。

---

## 附:审计维度 → 关键证据索引

| 维度 | 关键文件 |
|---|---|
| 构建/分发 | `electron-builder.dmg.yml`、`package.json:39-41`、`build/`、`release/` |
| 双架构/死代码 | `worker/src/index.js:2508-2528`、`worker/wrangler.toml:6,15,19`、`server.js:37,224-228,534`、`services/api.ts:794-845`、`electron/reports/index.js:74-82` |
| 测试/CI | `scripts/*.mjs`、`e2e/locale-matrix.spec.ts`、`playwright.config.ts`、(无 `.github/`) |
| 会计口径 | `electron/reports/{index,cn,us,jp,kr,eu,tw,_expenseSplit,usTaxParams,_reportSource}.js`、`accountingProfiles.ts`、`scripts/test-cogs-split.mjs` |
| AI/OCR | `electron/ai/{index,agent,tools}.js`、`electron/ai/providers/*`、`services/{ocrService,pdfRaster,aiErrors}.ts` |
| 数据安全 | `electron/db/index.js:29-30,451-464`、`electron/handlers/index.js:69-162`、`attachments.js:11-31` |
| 安全 | `electron/main.js:24-43`、`electron/preload.js:10-16`、`electron/handlers/router.js`、`npm audit` |
| 文档/i18n/UX | `README.md`、`i18n/locales/*.json`、`components/FinancePage.tsx:322-343`、`OnboardingWizard.tsx` |

> 三个本地交接文档 `ACCOUNTING-AUDIT.md` / `GEMINI-ACCEPTANCE-CHECKLIST.md` / `HANDOFF.md` 仍**未入库**。
