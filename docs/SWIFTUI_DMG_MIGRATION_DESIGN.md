# N7 设计分析:DMG(非沙箱)→ MAS(沙箱)用户数据迁移(来源选择 + createFresh 前置门)

> **状态:设计分析(N7),不实现;须经用户确认后才进入实现。**
> 本文档仅做设计与取舍分析,**不包含任何实现代码**(无 Swift 片段、无 diff),全部以文字、表格、状态/时序描述表达。所有涉及"实现时会改动"的内容均标注为**前瞻性、当前不改动**。
>
> 依据:基于对 `main`(`7d7101c`,已含 C12x-A2)生产代码的**只读**核查(启动状态机、open-plan/active-slot 守卫、`runImport` 管线、`MigrationSource`/预检/安全边界、UI/i18n/entitlements、测试与 fixture)。关联:`SWIFTUI_MIGRATION_PLAN.md` §0.2 / §0.3、`SWIFTUI_FEATURE_GAP.md` 第 4 节的 DMG P0。

---

## 修订记录(v2,2026-07-20)

本版依据用户确认的 **10 项设计决策 + 3 个设计阻断**修订(仍 docs-only,不实现)。速览(细节见对应章节):

- **锁定**:状态归 Core(`.requiresSourceChoice` + `.awaitingSourceChoice`,不用 App 预启动门,§推荐方案/§1);「创建新账本」用**独立强类型 intent**(**不用 `confirmed: Bool`**),选源页在开库与既有 onboarding **之前**,成功开库后再进原 onboarding;创建空账本需**二次确认**(明确"不删除旧数据、但本次以空账本开始")(§1)。
- 用户选目录**必走显式 `runImport(.userSelectedDataDir)`**,不混自动候选(§7);取消目录面板 = **停留选源页 no-op**(§6)。
- **App 不复制预检**,错误由 Core 返回强类型结果;将来若确需提前预览,增加 **Core preflight API**(§3.2)。
- **决策 5**:auto 源在 createFresh 前出现则**重裁决优先迁移**;用户显式目录选择**粘滞**;active-slot 变化沿用既有 fail-closed 守卫,**禁止静默切源**(§7,含一条实现前必须钉死的新不变量)。
- **决策 7(自选防护)**:由 **Core 以 device+inode 身份**(非字符串)拒绝 native 私有数据根 / active store 根 / 危险重叠,fail-closed,不向 UI 泄漏路径(§3.3,**新增**)。
- **决策 8(N9 门禁)**:真实 `electron-v23` 全库迁移 + freshly-completed open + completed-after-restart probe;**附件 apply 也是发布前门禁**(可独立 fixture PR,不得无限延期)(§9)。
- **决策 9**:本轮**不实现 ingest 中途取消**,执行期 UI 不显示取消,保持 single-flight(§6)。
- **决策 10**:MAS 签名沙箱手动验证入发布前清单,用**复制的** fixture,覆盖成功/取消/错误目录/完成后重启,**禁用真实用户数据**(§10)。
- **阻断 A(PR 顺序)**:改为 N7.0 门禁 → N7.1 只加类型/状态/协调 API/测试(**不启用生产行为**)→ N7.2 **原子启用** → N7.3 polish;无法可靠隐藏则合并 N7.1+N7.2(§11.1)。
- **阻断 B(值类型传递)**:`MigrationSource: Sendable, Equatable`(全 URL 载荷,编译器合成,**零 `@unchecked`、零手写 `==`**)+ `BootIntent.migrateFromUserDir(MigrationSource)`;Swift 5 模式下编译通过、保持 `Equatable` 可测;**输入侧 Sendable 化仅为部分清理**,返回侧 `BootOutcome` 的完整 Sendable 化留给专门的 Swift 6 硬化 pass(§2.1,**新增**)。
- **阻断 C(回滚表述)**:"静默创建空账本"仅为**开发期临时回滚**,**非发布可接受基线**;DMG 数据不可达仍是**发布前 P0**(§11.2)。

---

## 0. 问题定义与已决约束(先摆在前面)

### 0.1 缺口(Gap)

- `.userSelectedDataDir` 这条 Core 管线**已存在且被测试覆盖**(`MigrationSource.userSelectedDataDir(URL)` → `MigrationCoordinator.runImport(source:)` → ingest→gate→prepare→activate→finalize),但在 App 层**零生产调用方**:`makeProductionRunner` 里 `auto` 被硬编码为 `.masContainer`(`AppModel.swift:274`),没有任何目录选择器,`ProductionBootChainRunner` 只把 `.boot/.acknowledgement/.selection` 映射到 `bootResolve/resolveSelectedImport`,**从不调用 `runImport`**。
- `.masContainer` 只覆盖 **Electron-MAS 同容器**内的旧库(`~/Library/Containers/com.alotie418.sololedger/.../SoloLedger/sololedger.db`)。
- **DMG(非沙箱)Electron 用户的数据在沙箱之外**:`~/Library/Application Support/SoloLedger/sololedger.db`。MAS 沙箱进程无法自动发现该路径,**只能经用户在 Powerbox 里选择目录**才能读取。这正是 `.userSelectedDataDir` 存在的 P0 理由,却尚未接通 UI。
- 当前行为缺陷:当磁盘上无 active DB / 无 owner record / 无 staging 且 `.masContainer` 从磁盘复核仍不可用时,`resolveB1`(`MigrationCoordinator.swift:604`)直接返回 `.openStore(.createFreshExpectedAbsent)`,`adopt` **静默铸造一个空账本**,用户在那一刻**从未被提示"先选择来源"**。

### 0.2 已决约束(不是开放项,设计必须遵守)

1. **单授权窗口(single-grant-window)**:用户选中的目录 URL 只在**一次** `MigrationSource.withAccess` 安全作用域内被消费。
2. **不持久化 security-scoped bookmark**;**不新增** `com.apple.security.files.bookmarks.app-scope`(或任何 bookmark)entitlement。当前 entitlement 已确认为 `app-sandbox` + `files.user-selected.read-write`(Release/Debug 一致),足够,且**不改**。
3. **App 层绝不复制安全判定**:身份 / gate / hardened-open / DirectoryHandle / no-follow / 类型判定**全部归 Core**。App 只透传不可伪造的 `ConfirmedOpenPlan` / `ActiveOpenEvidence`,不重新实现任何检查。
4. **来源选择必须发生在 `createFresh` 之前**;成功开库后再进入既有 onboarding(公司信息)。
5. **导入必须 fail-closed**,**绝不覆盖已存在的 active store**;active-slot 变化沿用既有 fail-closed 守卫,**禁止静默切换来源**。
6. **Phase-2 报表/会计口径不在本次范围**(仅做数据搬运与开库,不触碰任何会计公式/口径,严格遵守 `CLAUDE.md` 会计红线)。
7. **「创建新账本」用独立强类型 `BootIntent`,不用 `confirmed: Bool`**;创建空账本前需**二次确认**,文案明确"不会删除旧数据、但本次将以空账本开始"。
8. **用户选目录后必走显式 `runImport(.userSelectedDataDir)`**,不混入自动候选源语义;取消目录面板视为 no-op,停留选源页。
9. **App 不复制预检逻辑**;错误由 Core 返回强类型结果。若确需"选完即预览",增加 **Core preflight API**(判定仍在 Core),App 只显示强类型结果。
10. **自选防护由 Core 以规范化身份(device+inode)判定**,拒绝 native 私有数据根 / active store 根及其危险重叠,**不做字符串路径比较**,不向 UI 泄漏内部路径。
11. **本轮不实现 ingest 中途取消**;执行期 UI 不提供取消操作,保持 single-flight;中断/重启语义见 §5/§6。

---

## 推荐方案(Recommended Approach)

**核心决策:把"选择来源"实现为一个由 Core 发出的新 `BootOutcome`(`.requiresSourceChoice`)+ 一个新的 `MigrationUIState`(`.awaitingSourceChoice`),而不是 App 层的"预启动门"。**

理由:约束 0.2-3 与 0.2-4 要求"来源是否可用"这条**安全/磁盘判定归 Core**。若做成 App 层预启动门,App 就必须自己知道"auto 源不可用"才能决定是否弹出选择屏,这等于把 probe-first 判定复制进 App,违反已决约束。让 Core 在 `resolveB1` 原本要授权 `createFresh` 的那个唯一分支上**改为发出"需要来源选择"**,App 只负责渲染两个选项并回抛意图,判定始终留在 Core。

### 推荐时序(端到端)

1. **启动**:`boot()` → `startChain(.boot)` → Phase A `bootResolve(autoSourceCandidate: .masContainer)` 全程离主线程复核磁盘。
2. **到达 createFresh 结点**:`resolveB1` 在"无 record / 无 active / 无 staging / 无 sentinel 且 `sourceState(.masContainer)==.unavailable`"分支,**不再**返回 `.openStore(.createFreshExpectedAbsent)`,改为返回**新** `.requiresSourceChoice`。
3. **分类**:`MigrationBootDriver.classifyOutcome` 把 `.requiresSourceChoice` 映射为 `ui(.awaitingSourceChoice)`(**非 openStore**,故绝不构造 store)→ `finish()` 落地,`inFlight=false`。
4. **渲染**:`MigrationPresenter.route` 增加一条 `.chooseSource` 路由,`RootView` 渲染"迁移旧数据 / 创建新账本"两个动作(全部经 `model.t(key)`)。
5. **分支 A —— 创建新账本**:用户点"创建新账本" → **先弹二次确认**("不会删除任何旧数据,但本次将以空账本开始") → 确认后发**独立强类型意图** `.confirmCreateFresh`(**不用 `confirmed: Bool`**)→ `startChain` 复用 `!inFlight` 单飞 → Phase A 走回 `resolveB1` 的**已确认 createFresh** 语义 → `.openStore(.createFreshExpectedAbsent)` → `confirmOpenAuthorization` **从磁盘再次复核全部前置**(active 缺席 / record 缺席 / 无 sentinel/staging / 且 auto 源此刻仍 `.unavailable`;任一变化 → `.reResolve`)→ `createFreshReservedHardened`(`O_CREAT|O_EXCL|O_NOFOLLOW` 独占预留)。**成功开库后**才进入既有 onboarding(公司信息)流程,顺序不变。
6. **分支 B —— 迁移旧数据**:用户点"迁移旧数据" → Powerbox `NSOpenPanel(canChooseDirectories=true, canChooseFiles=false)` → 拿到安全作用域 URL → 在**同一个** `withAccess` 授权窗口内构造 `.userSelectedDataDir(url)` → **独立强类型意图** `.migrateFromUserDir(MigrationSource)`(见 §2.1 值类型传递)→ `startChain` → Phase A(离主线程)`coordinator.runImport(source:)` 跑 **Core 自选防护(§3.3)→** 完整 ingest→gate→prepare→activate→finalize。**ingest 把源库+WAL+附件复制进内部 Staging 后,授权窗口即可关闭**,后续所有阶段只吃内部 staging,不再触碰源目录。此意图**粘滞**:其 reResolve 必须保留所选 `MigrationSource`,**不得塌回 `.boot`**(否则会被重裁决回 auto 源,见 §7 不变量)。
7. **开库**:`runImport` 成功返回 `.openStore(.openExistingCompleted(CompletionEvidence))` → `classifyOutcome` → `attemptOpen` → `confirmOpenAuthorization`(再次从磁盘复核 + 捕获 `ActiveOpenEvidence`)→ `openActiveExistingHardened`(NOFOLLOW + HAS_MOVED + 父/叶指纹校验)→ `adopt` 原子发布 store。
8. **失败**:任一阶段 fail-closed;若 active 槽已被占用,explicit-import 上下文返回 `.blocked(.terminal(.importSlotOccupied,{requestedImportID,existingImportID}))`,**绝不覆盖、绝不静默丢弃用户选择**。

这条路径把新增复杂度收敛到:**1 个新 `BootOutcome`(`.requiresSourceChoice`)+ 1 个新 `MigrationUIState`(`.awaitingSourceChoice`)+ 2 个新强类型 `BootIntent`(`.confirmCreateFresh` / `.migrateFromUserDir(MigrationSource)`)+ 1 个目录选择器 + 1 个 Core 自选防护(§3.3)+ 1 组 `migration.chooseSource.*` 文案**,其余全部复用既有 probe-first 判定与 hardened open。

---

## 1. createFresh 之前的「迁移旧数据 / 创建新账本」来源选择状态

### 1.1 新决策点在启动状态机中的位置

唯一的 `createFresh` 授权源头在 `resolveB1`(`MigrationCoordinator.swift:583-614`)的 case 0:无 record、无 active(no-follow)、无 sentinel、无 staging、`publishedImportIDs.count==0`,再看 `sourceState(auto)`:
- `.available` → `fullChain`(自动导入)
- `.unstable` → retriable interference
- `.unavailable` → **今天**:`.openStore(.createFreshExpectedAbsent)`(静默铸空)

**新决策点**就插在最后这一分支:`.unavailable` 时改为发出 `.requiresSourceChoice`。这不改动前两个分支(auto 源可用仍优先自动导入,不稳定仍 retriable),只把"本会静默铸空"的时机变成"请用户选择来源"。

### 1.2 与现有 BootIntent / MigrationUIState 的关系

- **新增 `MigrationUIState.awaitingSourceChoice`**:与 `.awaitingImportSelection` / `.retriable` / `.terminal` **同类**(`store==nil && ready==false`),等待期间**绝不发布 store、绝不置 `ready=true`**(遵守 `MigrationUIState.swift:20-23` 不变量)。落地方式与 `.awaitingImportSelection` 完全一致:chain 经 `finish()` 收尾(`inFlight=false`),用户后续选择再经 `startChain` 的 `guard !inFlight` 重新入链。
- **新增 `BootOutcome.requiresSourceChoice`**:与 `.requiresImportSelection` 平行,是一个**非 openStore** 的 outcome,故 `classifyOutcome` 只能把它导向 `ui(.awaitingSourceChoice)`,永远到不了 `attemptOpen`,天然满足"选择态绝不构造 store"(受 `testBlockedAndSelectionNeverConstructStore` 同类守卫保护)。
- **新增两个独立强类型 `BootIntent`**:`.confirmCreateFresh`(二次确认后创建新账本)与 `.migrateFromUserDir(MigrationSource)`(携带用户选定来源)。**不使用 `confirmed: Bool` 之类布尔旗标**——用专用意图保持 `BootIntent` 的 `Equatable` 语义清晰、可断言(现有 `FakeRunner.receivedIntents` 的 `XCTAssertEqual` 断言依赖它;见 §2.1)。二者都像现有意图一样:先 `guard store == nil`,受单飞门控,进入 `.running(.resolving)`。
- **穷尽 switch 的连带更新(编译器强制)**:`MigrationPresenter.routeInput` / `route` / `stateTag` / `block(from:)`,以及 `MigrationBootDriver` 的 `classify/classifyOutcome`——新增状态会让 build 失败直到每处补齐,这是刻意的安全网。

---

## 2. AppModel / BootChainRunner / MigrationCoordinator 职责分工

| 组件 | 本次新增/变化后的职责 | 明确的边界 |
|---|---|---|
| **AppModel**(`Sources/SoloLedger/App/AppModel.swift`) | @MainActor 编排:新增意图入口 `confirmCreateFresh()`(二次确认后)/ `migrateFromUserDir(source:)` / `cancelSourceChoice()`;把新意图接入 `startChain`(复用 `inFlight`、`bootGeneration`、两阶段 `runChain`、`adopt`、`finish`);在 `makeProductionRunner` 里把新意图映射到 coordinator 入口(`.migrateFromUserDir` → `runImport(source:)`,见 §2.1)。 | **绝不复制安全判定/预检**:只透传不可伪造的 plan/evidence 与用户选定的 `MigrationSource`;唯一开库点 `openStoreForPlan` 仅**分派** `.createFresh`/`.existing` 到 Core 的 hardened opener,不重实现任何检查(受生产接线守卫测试保护 `AppModel.swift:288-292`)。 |
| **BootChainRunner + ProductionBootChainRunner**(`BootChainRunner.swift`) | 定义线程契约的接缝:新增 `BootIntent` case;Phase A `resolveOutcome` 经 `Task.detached` 把 `runImport`(含安全作用域内的重 ingest)推离主线程,只回传值类型 `BootOutcome`;Phase B `attempt` 保持 @MainActor 同步。 | 只搬运意图与值类型,**从不返回 LedgerStore**;`.migrateFromUserDir` 的重活必须在 Phase A 离主线程(受 `testProductionPhaseARunsOffTheMainActor` 钉住)。 |
| **MigrationBootDriver**(`MigrationBootDriver.swift`) | 纯同步定序器:`classifyOutcome` 新增 `.requiresSourceChoice → ui(.awaitingSourceChoice)`;`attemptOpen` 的 authorization×plan 交叉核对保持不变。 | 不构造 store、不重试、不碰 coordinator 内部;只有 `.openStore` 能到达 `attemptOpen`。 |
| **MigrationCoordinator**(`MigrationCoordinator.swift`) | probe-first 从磁盘裁决:`resolveB1` 的 `.unavailable` 分支改发 `.requiresSourceChoice`;新增"已确认 createFresh"入口语义;`runImport(source:)` 接入 `.migrateFromUserDir`,并在 ingest 头部先跑 **Core 自选防护(§3.3)**;`confirmOpenAuthorization` **不变**(继续从磁盘复核 createFresh/existing/completed)。 | **拥有全部身份/gate/hardened-open/自选防护判定的裁决**;**从不构造 LedgerStore**(C12a 契约);每次调用都从磁盘重新推导,绝不信任缓存。 |

关键分工原则:**"是否可 createFresh / 源是否可用 / 是否已有 active"是 Core 的磁盘判定;App 只知道"Core 让我渲染选择屏"和"用户点了哪个按钮"。**

### 2.1 值类型传递方案(阻断 B —— 可编译、可测,零 `@unchecked`)

问题:把用户选中的目录送进 Phase A 的 `Task.detached` 并抵达 `MigrationCoordinator.runImport(source:)`,涉及跨 `@Sendable` 边界传值。当前 `resolveWork` 声明为 `@Sendable (BootIntent) -> BootOutcome`(`BootChainRunner.swift:40`),`Task.detached { work(intent) }` 隐式捕获 `intent`(`:51-54`)。因此**不能不加论证就把 `MigrationSource` 塞进 `BootIntent`,也禁止用 `@unchecked Sendable` 蒙混**。

**核查结论(已只读核实并经对抗验证):**

- `BootIntent` 目前是 `enum BootIntent: Equatable`(仅 Equatable、非 Sendable,`BootChainRunner.swift:18`),其 `Equatable` 是**编译器合成**(payload `Acknowledgement`/`String` 均 Equatable)。`FakeRunner.receivedIntents` 的 `XCTAssertEqual`(`AppModelBootTests.swift:163/321/332/340`)依赖它——**任何新 case 的 payload 必须 Equatable**。
- `MigrationSource` 目前**无任何 conformance**(`MigrationSource.swift:18`),四个 case 载荷全是 `URL` 或无载荷(`.masContainer` / `.userSelectedDataDir(URL)` / `.exportBundle(URL)` / `.legacySingleDB(URL)`);`URL` 同时是 **`Sendable` 且 `Equatable`**;`withAccess`/`databaseURL()` 等都是**方法**(不持有闭包/句柄/store)。
- 包处于 **Swift 5 语言模式**(`Package.swift` tools 5.9、`project.yml` `SWIFT_VERSION: 5.0`,无 `StrictConcurrency`)。故跨 `@Sendable` 的 Sendable 违规**当前仅是 warning**;`makeProductionRunner` 今天已经把 `let auto: MigrationSource = .masContainer`(`AppModel.swift:274`)捕获进 `@Sendable` 闭包并能编译。

**推荐方案(Option i):**

1. 给 `MigrationSource` 加 `: Sendable, Equatable`——因每个载荷都是 `URL`,`==` 与 `Sendable` **均由编译器合成,零手写、零 `@unchecked`**。
2. 给 `BootIntent` 加 `case migrateFromUserDir(MigrationSource)`——`MigrationSource` 现在 Equatable,`BootIntent` 的合成 `Equatable` 保持成立,现有及新增 `receivedIntents` 断言(可写 `[.migrateFromUserDir(.userSelectedDataDir(url))]`)均可编译可断言。
3. `resolveWork` 的 switch 增一臂:`.migrateFromUserDir(let source) → coordinator.runImport(source: source)`——1:1 交给既有公共入口(`MigrationCoordinator.swift:277`,`acknowledgement` 有默认值),**不重建任何东西**。

**否决 Option ii(`BootIntent.migrateFromUserDir(URL)` + Core 侧重建 source)**:裸 `URL` 无法区分 `.userSelectedDataDir` / `.exportBundle` / `.legacySingleDB`(三者都用户可选、都过 `runImport`),会迫使 `resolveWork` 硬编码一种 kind 并复制 `MigrationSource` 已拥有的 kind 分类,割裂"source 是唯一归一点"的设计。**否决 Option iii(App 侧再造一个平行 DTO 枚举)**:与 `MigrationSource` 冗余、需双份维护,而后者本就免费合成两种 conformance。

**重要范围声明(经对抗验证纠正):** 给输入侧(`MigrationSource`/`BootIntent`/可选连带 `Acknowledgement`)加 `Sendable` **只是部分清理**,能消掉 `auto`/`intent` 捕获的既有 warning;但它**不能**使整条 detached 边界"warning-clean"——**返回侧** `BootOutcome` 及其载荷(`StoreOpenAuthorization`/`AcknowledgementRequest`/`MigrationResidual`/`RecoverableImport`/`MigrationBlock`/`UnresolvedReport`)也跨同一 detached 边界且**仍非 Sendable**。**完整 Sendable 化(含 `BootOutcome` 全套)是一次独立的 Swift 6 硬化 pass(见 `Package.swift:8` 记载),不属于 N7,禁止顺手夹带。** N7 只做能解锁本功能的最小输入侧改动。

---

## 3. userSelectedDataDir 目录 picker 与只读预检

### 3.1 目录选择器(Powerbox NSOpenPanel)

- 现有 `FilePanels.swift` 的 CSV 导入 / 备份恢复都是 `NSOpenPanel` 且 `canChooseDirectories=false`;**本次唯一增量**是新增一个目录选择器:`canChooseDirectories=true`、`canChooseFiles=false`、`allowsMultipleSelection=false`、不设 `allowedContentTypes`(选文件夹)。
- 返回的目录 URL 由 Powerbox 加了安全作用域,授权由既有 `com.apple.security.files.user-selected.read-write` 提供(已确认),**无需任何 bookmark**。
- 该 URL 只在**一次** `MigrationSource.userSelectedDataDir(url).withAccess { … }` 内被消费(见第 4 节)。

### 3.2 只读预检——判定归 Core

预检目的是**给用户友好的即时反馈**(例如"所选文件夹里没有账本数据"),**但真正的类型/no-follow/身份判定不在 App、也不在 `MigrationSource`**:

- `MigrationSource` 是**纯路径掮客**:`.userSelectedDataDir(dir)` 的库路径 = `dir/sololedger.db`(`AppPaths.databaseFileName`),可携带 `-wal`;它**不做任何存在性/类型/no-follow 校验**(注释明示"Existence is checked by the caller")。
- "文件夹里是否含 `sololedger.db`""是否是常规文件""no-follow""WAL 是否也是常规文件"这些判定全部在下游 Core:
  - `FileFingerprint.capture`(`lstat`/no-follow;只有 ENOENT 读作缺席,其余错误一律 fail-closed 抛出)——软链的 `sololedger.db` 会 fingerprint 成 `S_IFLNK` 而 `isRegularFile` 失败。
  - `DirectoryHandle`(`openat O_NOFOLLOW|O_DIRECTORY`,device+inode 绑定,成员操作全部相对 fd)。
  - `FileHash.copyRegularFileNoFollow`(`O_RDONLY|O_NOFOLLOW|O_NONBLOCK`,在打开的 fd 上 `fstat` 验 `S_IFREG` 再从同一 fd 流式读)。
  - 真正的早期门在 `StagingIngest.ingest`:缺库→`sourceDatabaseMissing`,非常规文件→`sourceNotRegularFile`(注释标注这些是"UX,不是安全边界")。
- **已决(决策 6):App 不做预检探测。** 直接把选中目录交给 `runImport`,由 Core 的 ingest 早期门(`sourceDatabaseMissing` / `sourceNotRegularFile` / 自选防护 §3.3)返回**强类型结果**,再经 `MigrationPresenter` 映射成本地化文案(见第 8 节)。**App 不复制任何判定**——不再考虑 App 侧薄探测。**将来若确需"选完即预览是否含账本数据"的体验**,则**在 Core 增加一个只读 `preflight(source:) -> 强类型结果` API**(判定仍在 Core,App 只显示强类型结果),作为独立后续项、非本轮范围。

> 说明:`MigrationSource.userSelectedDataDir` 本身是纯路径掮客,不校验目录真实性、也不防自我导入——这些**由 §3.3 的 Core 自选防护 + 下游 `DirectoryHandle`/`FileFingerprint` 类型门**兜底。

### 3.3 自选防护(决策 7 —— Core 以 device+inode 身份拒绝,不比较字符串)

**目标**:拒绝用户选中本 App 自己的私有数据根 / active store 根 / 其危险重叠(祖先/后代/硬链到 active DB),**且绝不向 UI 泄漏内部路径**。

**为什么不用字符串路径比较**:APFS firmlink / 同步 mount / `synthetic.conf` 会让同一 inode 出现在两个路径前缀下,字符串比较会漏判;反之用户把数据**复制**到另一卷再选中那个副本(不同 device+inode)是**合法独立来源**,字符串前缀又会误杀。规范化身份(device+inode)两头都对。

**Core 已具备全部原语**(无需新增底层能力):`DirectoryHandle`(`openat O_NOFOLLOW|O_DIRECTORY`,`fstat` 绑定 `device`/`inode`;`subdirectory(named: "..")` 可沿真实父目录逐跳上行,`".."` 非符号链故 O_NOFOLLOW 不拒)、`FileFingerprint.capture`(no-follow 取 `device`/`inode`/类型,ENOENT 读作缺席、其余错误 fail-closed 抛出)、`AppPaths.dataDirectory()`(native 私有数据根,active DB / attachments / Staging / ImportManifests 全部嵌套其内)。

**设计(全部在 Core,一处 chokepoint)**:在 `StagingIngest.ingest` 进入 `source.withAccess { … }` 后、任何 gate/复制**之前**,新增 `SelfImportGuard` 预检:

1. 解析受保护身份一次:把 native 数据根(`AppPaths.dataDirectory()`,或等价的 `activeDestination` 的父目录)开成 `DirectoryHandle` → `(devRoot,inoRoot)`;若 active DB 存在,`FileFingerprint` 取其 `(devDB,inoDB)`。
2. 解析来源:`userSelectedDataDir`/`exportBundle` 把所选目录开成 `DirectoryHandle` → `(devSrc,inoSrc)`;`legacySingleDB` 对所选**文件**取指纹 → `(devSrcFile,inoSrcFile)`。
3. **按身份拒绝**(非字符串):
   - **相等**:`(devSrc,inoSrc)==(devRoot,inoRoot)` ⇒ role `.nativeDataRoot`。
   - **文件同一**:`legacySingleDB`(或源目录内的 DB)`(device,inode)==(devDB,inoDB)` ⇒ role `.sameAsActiveDatabaseFile`——捕获**硬链到 active DB**(目录/字符串检查抓不到)。
   - **后代**:从源 handle 经 `".."` 逐跳上行,每跳比对 `(devRoot,inoRoot)`;命中 ⇒ `.descendantOfActive`(如用户选了 `<dataRoot>/Staging/...`)。
   - **祖先**:从数据根 handle 上行比对 `(devSrc,inoSrc)`;命中 ⇒ `.ancestorOfActive`(如用户选了 Application Support)。
   - 上行以 **`(device,inode)` 不动点**(`"/"` 的 `".."` 返回自身)**加固定 maxDepth**(如 64)双重终止;**不能靠 device 变化终止**(firmlink/mount 会中途换 device)。任何 open/stat 元数据错误一律 **fail-closed 视为拒绝**(绝不当"无重叠")。
4. **强类型错误、零路径泄漏**:新增 `IngestError.sourceIsActiveData(role: SelfImportRole)`,其 `description` **只输出 role 标签、绝不含路径**(刻意区别于 `sourceDatabaseMissing` 等带路径的兄弟 case);`MigrationCoordinator.map` 把它映射为 `.terminal(.invalidSource, {reason, role})`,App 只显示既有通用键 `migration.msg.invalidSource`,**role/reason 均无路径**。

**边界与澄清**:
- 该守卫是**fail-closed 预检 / UX 门**,**不是**写-覆盖-active 的安全边界——后者仍由 activator 的 `O_EXCL` 独占预留 + `ActiveOpenEvidence` 身份保证;守卫的 check→copy TOCTOU 只会退化到那些下游门,**不会**导致数据丢失。
- 符号链叶子会先被 `DirectoryHandle.open`(O_NOFOLLOW)以 `notADirectory` 拒(仍 fail-closed,只是 error 不同);`NSOpenPanel` 通常回传解析后的真实路径。
- **跨卷真实副本(不同 device+inode)必须放行**——这正是身份优于字符串的行为收益,需专门测试。
- 首装时数据根尚不存在:根缺席时相等/后代判定按"无可保护"放行,祖先上行(Application Support 存在)仍适用;**勿把根 ENOENT 当硬失败**而误挡首次合法导入。
- 守卫需可注入受保护根/active-DB 身份(仿既有 coordinator override),让单测把"active"指向隔离临时根、逐一断言各 role,而不碰真实容器。

---

## 4. single-grant-window 生命周期

| 阶段 | 授权窗口状态 | 期间行为 |
|---|---|---|
| 用户在 `NSOpenPanel` 选中目录 | Powerbox 授予该 URL 安全作用域 | 拿到 URL,尚未 `startAccessing` |
| 进入 Phase A `runImport` 的 ingest | **打开**:`MigrationSource.userSelectedDataDir(url).withAccess` → `url.startAccessingSecurityScopedResource()` | 在这**唯一**窗口内:`StagingIngest` 把源 `sololedger.db`(+仅当源有 WAL 时的 `-wal`)+ 有效附件复制进私有 `.attempt-*` 目录,前后各做一次源稳定性指纹复核,再原子 `moveItem` 发布到内部 `Staging/import-<id>` |
| ingest 发布完成(内部 staging 落盘) | **可以关闭**:`withAccess` 闭包返回 → `stopAccessingSecurityScopedResource()` | 此后 gate/prepare/activate/finalize/open **只吃内部 staging,绝不再触碰源目录** |
| 后续所有阶段与开库 | **已关闭**,不再需要源授权 | 完全在 `<AppSupport>/<nativeDataFolder>` 内部工作 |

要点:
- **授权窗口的起止 = ingest 的起止**;一旦内部 staging 发布,源目录授权即释放。
- **不持久化 bookmark、不新增 entitlement**——完全符合 `MigrationSource.swift:13-17,79-89` 记录的刻意设计。
- 跨启动**不保留任何对源的访问权**:若 ingest 未完成就崩溃(窗口内),重启后授权已失效,必须重新选目录(见第 5 节)。

---

## 5. staging 发布前/后的崩溃与恢复语义

管线有多层原子 `RENAME_EXCL` / 同卷 `moveItem` 发布点(均**永不覆盖**),对"源是否还需要"这个问题,**关键边界是 ingest 的 staging 发布点**:

| 崩溃发生时刻 | 磁盘残留 | 恢复语义 |
|---|---|---|
| **ingest 发布之前**(仍在 `.attempt-*`,尚未 `moveItem` 到 `Staging/import-<id>`) | 只有 `.attempt-*` reaper 残渣,无内部 staging、无 owner record | **必须重新选目录**:授权窗口已随崩溃关闭,内部无自足副本,源仍是唯一数据。重启 → `resolveB1` 仍判定 createFresh-would-fire → 再次进入 `.awaitingSourceChoice` |
| **ingest 发布之后、owner record 之前** | 内部 `Staging/import-<id>` 已是自足快照(manifest+db[+wal][+attachments]) | **自动从内部 staging 恢复**:重启走 `.boot`,`scanStaging` 见 `publishedImportIDs.count==1` → `recoverPublishedStaging` 自动续跑,**不再需要源、无需重新选目录** |
| **owner record 发布之后**(`active-activation.json` 已存在) | owner record 为**不可回退状态**("record present, active absent" 是官方可续状态) | 每次 `bootResolve` 见 record → `resolveWithRecord` 续跑**那个确切 importID** 直到 sentinel 完成;完成后开库(WAL-safe) |
| **完成 sentinel 发布之后**(`ImportManifests/<id>.json`) | 完成事实已持久化 | probe 返回 `.completed/.cleanupPending`,可安全开库;若此时 active DB 缺失 → 终态 `activeMissingAfterCompletion`,**绝不重新铸空** |

设计含义:
- **单授权窗口 + 崩溃恢复的分界正是 ingest 发布点**。用户只在 ingest 未发布时才需要"重新选目录";一旦内部 staging 落盘,系统自愈,与源解耦。
- 每个发布都是同目录 `renameatx_np(RENAME_EXCL)` 或同卷 `moveItem`,**永不覆盖**,崩溃只会留下临时件或已发布件,绝无撕裂写。

---

## 6. single-flight / 重复点击 / 取消 / App 重启

- **单飞**:`startChain` 首行 `guard !inFlight else { return }`(硬布尔)。第二次点击"迁移/创建"在链进行中被直接丢弃,不改状态、不 bump generation(复用 `testHardSingleFlightIgnoresSecondClick` 同类保证)。
- **generation 防陈旧**:三个主线程续点(Phase A 恢复后、`adopt` 首、`finish` 首)各 `guard gen == bootGeneration`;被取代的链**什么都不拥有**,提前返回不碰 `inFlight`/state。新意图链同样必须在每个续点复核。
- **到达选择态的收尾**:`.awaitingSourceChoice` 经 `finish()` 落地 → `inFlight=false`,用户随后的按钮/选目录再经 `startChain` 干净入链——与 `awaitingImportSelection` 的模式一致。
- **取消语义**:
  - **取消目录选择器**(`NSOpenPanel` 返回非 `.OK`):**不触发任何意图**,直接回到 `.awaitingSourceChoice` 选择屏(此时 `inFlight` 本就为 false),纯 no-op。这是最干净的取消。
  - **`cancelSourceChoice()`(若提供"返回/放弃"入口)**:镜像 `cancelImportSelection`——**仅当** `migrationUIState == .awaitingSourceChoice` 时才动作,其它状态一律 no-op(受同类守卫测试保护)。它**绝不开库、绝不创建、绝不自动选源**。**已决(决策 4):安全静止态 = 停留在选择屏**(选择屏本身即可静止的 `store==nil` 态),**不落终态、不推向静默 createFresh**。
  - **取消进行中的 ingest —— 已决(决策 9):本轮不实现。** 执行期 UI **不提供取消操作**;`currentBootTask` 保留但从不 `.cancel()`,取代只靠 `bootGeneration`;`startChain` 被 `!inFlight` 门控且 `inFlight` 只在 `finish` 清零,链进行中无法叠加第二条。UX 上**可显示进度但不承诺"取消"**。主动中止大 ingest 是明确的后续独立项,不在 N7 范围。
- **App 重启续跑**:按第 5 节——ingest 发布前重启回到选择屏;发布后自动续跑;owner record 后续跑确切 importID;完成后开库。**重启不依赖任何持久化授权**,因为内部 staging 已自足。

---

## 7. 已存在 active store 时必须 fail-closed、绝不覆盖

新来源选择流叠加在既有多层 fail-closed 守卫之上,**不削弱**任何一层:

1. **createFresh 只有唯一授权点**(`resolveB1` active-absent 分支),且 `confirmOpenAuthorization` 在开库前从磁盘**再次**复核:active 缺席 ∧ record 缺席 ∧ 无 canonical/invalid sentinel ∧ 无 published/suspicious staging ∧ auto 源此刻仍 `.unavailable`;任一改变 → `.reResolve`,**绝不构造 store、绝不在该路径创建空文件**。用户点"创建新账本"**不能绕过**这道门:若期间冒出 active/record/源变可用,一律 reResolve。
2. **已存在 active 必被开、绝不 createFresh**:有 owner record → probe-first 走 `resolveWithRecord`(到不了 createFresh);无 record 但 active no-follow 解析为常规文件 → `.openStore(.openExistingPlain)`(B2)。
3. **authorization×plan 精确交叉核对**(`MigrationBootDriver.attemptOpen:85-95):只允许 `(.createFreshExpectedAbsent,.createFresh)`/`(.openExistingPlain,.existing)`/`(.openExistingCompleted,.existing)`,任何错配 → 终态 `internalError(planAuthorizationMismatch)`,**绝不开库**。`ConfirmedOpenPlan.existing` 携带**强制的、不可伪造的** `ActiveOpenEvidence`,existing-open 永不能被降级成 createFresh。
4. **store 层最后一刻不可覆盖**:`createFreshReservedHardened` 用 `openat(O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW)` 独占预留,任何既存条目(常规文件/软链/悬空软链/目录)→ `EEXIST` → `freshCollision`;`freshCollision` 映射为 `retriable(.interference)` 且**刻意永不自动 reResolve**(否则可能把占位者当 `openExistingPlain` 重新收养)。
5. **existing/completed 开库无 CREATE**:`SQLITE_OPEN_READWRITE|SQLITE_OPEN_NOFOLLOW`(无 `SQLITE_OPEN_CREATE`),路径消失就开库失败而非铸空。
6. **导入发布 create-only**:`PreparedImportActivator` 预发布检查 active 槽占用,`RENAME_EXCL` 同目录发布**永不覆盖**;**迁移旧数据**若发现 active 槽已被别的 import 占用(explicit-import 上下文)→ 终态 `.importSlotOccupied`,携带 `requestedImportID` 与 `existingImportID`,**用户选择既不被静默改判也不被丢弃**;当前没有内建的 replace/reset 操作(那是未来显式设计的操作)。

**结论:选择"迁移旧数据"在任何时刻遇到已存在 active,都会 fail-closed 到 `importSlotOccupied` 终态,绝不覆盖。** 与 open-plan/active-slot 守卫的协作是"叠加",不是"替换"。

### 7.1 决策 5 —— 重裁决优先迁移、显式选择粘滞、禁止静默切源(不变量)

这三条**大部分已从既有代码自然得到**,应作为**不变量**写死,而非新行为:

- **auto 源在 createFresh 前出现 → 重裁决并优先迁移**:`sourceState(auto)` **从磁盘、从不缓存**地在三处复核(`resolveB1`、`confirmOpenAuthorization(.createFreshExpectedAbsent)`、`resumeChain`)。"优先迁移"就是 `resolveB1` 里 `.available → fullChain`(自动导入)**排在** `.unavailable → createFresh` **之前**;且 createFresh 授权**可在最后一刻被撤销**——`confirmOpenAuthorization` 若发现 auto 此刻 `.available` 就返回 `.reResolve`,重跑后走 fullChain。createFresh 是**唯一**对 auto 源敏感的授权;existing-open 的两个 confirm 分支根本不看 `sourceState`。
- **用户显式目录选择粘滞**:显式路径(`runImport` 用 `.explicitImport`、`recoverPublishedStaging` 用 `.selectedRecovery`)一律携带 **`autoSourceCandidate: nil`**,故其 `resumeChain`/重裁决分支**结构上不可达**——显式来源**永不会被重裁决回 auto 源**;槽冲突以 `.terminal(.importSlotOccupied)` **显式浮现**(带 `requestedImportID`/`existingImportID`),用户选择**既不静默改判也不丢弃**。
- **⚠️ 实现前必须钉死的不变量(当前 App 有真实缺口)**:App 侧 `reResolve` 现在把意图**塌回 `.boot`**(`AppModel.swift:218`),而 `.boot` 会**重新注入 auto 候选**。若把显式目录导入接成会走 reResolve 的普通意图,用户选择可能在"pre-record 窗口"被重裁决回 auto MAS 源 —— **一次静默切源**。因此实现时**必须**二选一并加守卫测试:(a) `.migrateFromUserDir` 的 reResolve **保留所选 `MigrationSource`,绝不塌回 `.boot`**;或 (b) 形式化证明显式导入在任何 reResolve 可达前**已发布 record/active/staging**,从而 probe-first 的 record-dominance 阻止 auto 重裁决。默认取 (a)。相应地,建议 `confirm` **仅对 createFresh 派生的授权**接收 auto 候选,而非像今天这样无条件传 `auto`。

---

## 8. 错误状态、用户文案与六语言范围

- **全部经 `MigrationPresenter` 的稳定 key**:`RootView` 只渲染 `model.t(key)`,从不显示原始文本/枚举/路径/错误串——**无路径/错误文本泄漏**是硬要求。
- **文案落在 `migration.*` 命名空间**:该命名空间已有**全 6 语言 parity(每语 64 key)**,由 `MigrationCopyParityTests` 强制。通用命名空间只有 zh-Hans+en 完整、其余 4 语靠回退,**不能**把新屏文案放在通用空间(否则 4 语静默回退且无测试兜底)。
- **新增 key(设计级清单,建议保持无占位符以简化 parity)**,置于 `migration.chooseSource.*`:
  - `migration.chooseSource.title`(标题:发现你可能有旧账本数据)
  - `migration.chooseSource.body`(说明:可迁移旧数据或创建新账本)
  - `migration.chooseSource.migrate.button`(迁移旧数据)
  - `migration.chooseSource.migrate.hint`(从 DMG/旧版数据文件夹导入)
  - `migration.chooseSource.createNew.button`(创建新账本)
  - `migration.chooseSource.createNew.hint`(从空白开始)
  - `migration.chooseSource.picker.prompt`(选择目录面板的提示/message)
  - `migration.chooseSource.picker.noData`(所选文件夹未找到账本数据——**通用措辞,不回显路径**)
  - `migration.chooseSource.importing`(导入进行中——如需进度提示)
- **错误一律 Core 强类型(决策 6),复用既有键**:自选防护(§3.3)映射为 `.terminal(.invalidSource, {reason, role})` → 既有键 `migration.msg.invalidSource`(**无需新 key、role/reason 无路径**);`sourceDatabaseMissing`/`sourceNotRegularFile`/`importSlotOccupied` 等亦为既有 `migration.*` 键。App **不构造任何错误文案**,只 `model.t(Core 给的 key)`。
- **占位符纪律**:上述新 key 若引入 `{count}`/`{importID}` 之类 token,必须在 `testExpectedPlaceholderKeysOnly` 里钉住;**推荐这些 key 全部无占位符**,避免额外 parity 负担。`importSlotOccupied` 等既有块文案已在 `migration.*` 内,复用即可(其 `{importID}` 已被现有 parity 覆盖)。
- **六语言 parity 纪律**:新 key 必须**同时**加进 6 个 `.lproj/Localizable.strings`(zh-Hans/zh-Hant/en/ja/ko/fr)**并**注册进 `MigrationCopyParityTests.allMigrationKeys()`,否则 parity 测试红 / 4 语静默回退。
- **穷尽路由更新**:新增 `MigrationRoute.chooseSource` + `MigrationPresenter.routeInput/route` + `RootView.render` + DEBUG `--migration-ui-preview` 预览,全部无 default,编译器强制补齐。

---

## 9. N9 真实 electron-v23.db 全链路测试作为实现前门禁

**N9 是实现前门禁:必须先落地并变绿,才允许接 picker/runImport 生产接线。** UI 只能暴露一条已被证明的链。

- **现状缺口**:已有真实 Electron 引擎产出的 `electron-v23.db`(`user_version=23`,78 分类,7 笔覆盖全枚举的交易,4 设置,全部 `attachment_path=null`),但**没有任何测试**把它跑通"`.userSelectedDataDir` → ingest → gate → prepare → activate → finalize → confirm → hardened open → 断言真实交易/设置/分类"。现有全链路测试都源自**空 v0 合成库**(`makeSQLiteDB`,0 交易),且开库用**朴素 `LedgerStore.init`** 而非生产 `confirmOpenAuthorization → openStoreForPlan → openActiveExistingHardened` 分派。
- **N9 必须覆盖的全链路(以真实 fixture 为源)**:
  1. 用 `electronFixtureCopy()` 把真实库放进一个临时 `.userSelectedDataDir` 源树;
  2. `coordinator.runImport(source: .userSelectedDataDir(dir))` 跑完整 ingest→gate→prepare→activate→finalize;
  3. **尊重 finalize-before-open 次序**:finalize(apply→audit→complete)在 quiescent DB 上完成后,才由 App 侧开库(开库切 WAL 会破坏 quiescence 门);
  4. 经 `confirmOpenAuthorization` → `openActiveExistingHardened` 开库(**不用**朴素 init);
  5. 断言(具体数值,强于现有 CN-子集检查):**7 笔交易(4 income + 3 expense)、income=4600.75 / expense=1750.74 / net=2850.01、4 设置(accounting_locale/currency/company_name/ui_language)、78 分类精确计数、全枚举(income/expense;paid/partial/unpaid;issued/pending/na)未损**。
- **N9 必须覆盖的三个场景(决策 8)**:
  1. **完整全库迁移**(上述链 + 数值断言);
  2. **freshly-completed open**:finalize 返回 `.completed` 后**立即**经 confirm + hardened open,尊重 finalize-before-open quiescence 契约;
  3. **completed-after-restart probe**:对同一磁盘 config **重建第二个 coordinator**,重跑 `bootResolve` 使 WAL-safe probe 返回 `.openExistingCompleted`,再开库复断言。
- **两个变体**:**Core-target**(`SoloLedgerCoreTests`,`swift test`)直接调 `openActiveExistingHardened`;**App-hosted**(`SoloLedgerUnitTests`)驱动真实 `AppModel.openStoreForPlan` 生产分派。
- **附件 apply 也是发布前门禁(决策 8,不得无限延期)**:committed fixture 全 `attachment_path=null` 且 `business_documents` 0 行,**finalize 的 apply-copy → 引用审计-resolve → complete 时 sha256 复验 → sentinel 路径当前零端到端覆盖**——而生产 `.masContainer` 首迁**必然**带真实附件与引用,正是该门禁要防的场景。须增补一个**含附件的 fixture 变体**(≥1 条非空 `transactions.attachment_path='attachments/docs/<name>'` + 匹配的真实文件;理想再加 1 条 `business_documents.tax_invoice_attachment_path`;并含 1 条**悬空引用**驱动 requiresAcknowledgement→acknowledge→收敛),由生成器 `make-electron-fixture.mjs`(或姊妹脚本)产出以保证 manifest 哈希自洽。**可作为独立 fixture-test PR,但必须在 N7 发布前成为门禁,不得无限推迟。**
- **MAS 沙箱安全作用域**:`withAccess/startAccessingSecurityScopedResource` 在无头 Core/Unit 测试里是 no-op,**无法 headless 证明**;需真实签名沙箱运行(见第 10 节手动门)。

---

## 10. Unit / UI / Core / MAS 沙箱验证矩阵

| 层 | 目标 | 运行方式 | 关注点 |
|---|---|---|---|
| **Core**(`SoloLedgerCoreTests`) | 真实 fixture 全链路 + hardened open 数据存活(N9 Core 变体);`resolveB1` 改发 `.requiresSourceChoice` 的裁决;`runImport` explicit-import 冲突(`importSlotOccupied`)端到端 | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` | probe-first、fail-closed、freshCollision、RENAME_EXCL 不覆盖 |
| **Unit(App-hosted)**(`SoloLedgerUnitTests`,`@testable import SoloLedger`) | 新意图/新状态的启动机守卫:单飞丢第二击、取消 no-op(状态外)、`.awaitingSourceChoice` 绝不构造 store、Phase A 离主线程、generation 陈旧不发布;N9 App-hosted 变体(真实 `openStoreForPlan`);`MigrationCopyParityTests` 注册新 key | `xcodebuild -project App/SoloLedger.xcodeproj -scheme SoloLedger test`(同 `DEVELOPER_DIR`) | 用 FAKE scripted runner 覆盖状态机;真实 fixture 覆盖开库分派 |
| **UI**(`SoloLedgerUITests`) | 新 `.chooseSource` 路由的表层/路由安全:经 `--migration-ui-preview` 合成态渲染两个动作、文案经 key、无原始枚举/路径泄漏 | 同上 xcodebuild scheme | 结构性(无真实 DB),保证 render switch 穷尽且不泄漏 |
| **i18n parity** | `migration.chooseSource.*` 6 语齐全、无 raw-key 泄漏、占位符集与 en 一致 | `MigrationCopyParityTests`(Unit 目标内) | 新 key 必须进 `allMigrationKeys()` |
| **MAS 沙箱(手动,决策 10)** | 真实签名沙箱构建 → 用一份**复制的测试 fixture 数据文件夹**(**禁用真实用户数据**)→ 覆盖:**成功迁移**、**取消**、**错误目录/自选防护拒绝**、**完成后重启续跑**;确认 Powerbox 安全作用域读成功、无路径泄漏 | 手动:签名/构建 → 运行 → 选**复制的** fixture 目录 → 逐场景断言 | **无法 headless 自动化**;**正式列入发布前清单**;绝不拿真实用户账本试验 |

> 说明:`swift test` 需 `DEVELOPER_DIR` 指向完整 Xcode(XCTest 只随完整 Xcode 分发),与 MEMORY 记录一致。

---

## 11. 分阶段实施 PR 拆分、回滚条件、未决问题(实施纪律)

### 11.1 PR 拆分(小而聚焦,遵守 `CLAUDE.md` PR 纪律)

**修订说明(阻断 A):** 原拆分把"翻转 `resolveB1`"放在 N7.1、而 picker 要等 N7.2 才有,会产生一个**能到选源页却无法真正迁移**的不可用中间提交。改为:**先加能力但不启用生产行为,待整条闭环就绪后再原子启用。**

| PR | 范围 | 生产行为 | 门禁/依赖 |
|---|---|---|---|
| **N7.0(门禁)** | N9 真实 fixture 全链路测试(Core + App-hosted 变体):完整迁移 + freshly-completed open + completed-after-restart(§9)。**无生产行为变化。** | **不变** | 必须先绿;未绿不得进入后续 PR |
| **N7.1(仅加类型/状态/协调 API + 测试,不启用)** | 新增 `BootOutcome.requiresSourceChoice`、`MigrationUIState.awaitingSourceChoice`、两个强类型 `BootIntent`、`MigrationSource: Sendable,Equatable`(§2.1)、Core 自选防护(§3.3)、`runImport(.migrateFromUserDir)` 接线与 `classifyOutcome` 映射、穷尽 switch 补齐;**但 `resolveB1` 仍走旧 `.createFreshExpectedAbsent`,不发 `.requiresSourceChoice`**;新能力仅被**测试**驱动。 | **不变**(生产仍旧行为) | 依赖 N7.0;此 PR **不翻转首启** |
| **N7.2(原子启用闭环)** | 当选源 UI、目录 picker + 安全作用域、Core 错误映射、`migration.chooseSource.*` **六语文案**、以及 Core+Unit+UI 测试**全部就绪**后,**在同一 PR 内**把 `resolveB1` `.unavailable` 改发 `.requiresSourceChoice`,**原子启用**整条来源选择 + 迁移 + createFresh-二次确认闭环。 | **翻转点**:首启从"静默铸空"改为"选源页" | 依赖 N7.1 |
| **N7.3(非阻断 UI polish)** | 视觉/文案打磨、DEBUG 预览增强、可选进度提示等,不改行为。 | 不变 | 依赖 N7.2 |

> **若无法可靠隐藏未完成能力**(例如某处 switch 一旦补齐就会让部分入口对用户可见),则**把 N7.1 与 N7.2 合并为一个最小可用闭环 PR**——宁可一个稍大但**始终可用**的 PR,也不留不可用中间提交。

### 11.2 回滚条件

- **N9 未绿(含附件门禁)** → 停,绝不接 picker(硬门)。
- **启用后(N7.2)首启 UX 有问题 / 穷尽 switch 或 parity 意外红** → 回退 N7.2 的启用(`resolveB1` 改回旧分支)。
  - ⚠️ **回滚基线澄清(阻断 C)**:回退后落回的"**静默创建空账本**"只能作为**开发期临时回滚**,**不是发布可接受的基线**——它正是本设计要消除的行为。**DMG 用户数据不可达仍是发布前 P0**;临时回滚后必须继续推进闭环,不得以"能静默铸空"当作已解决。
- **N7.2 后 MAS 沙箱手动门失败(安全作用域未授予/读失败)** → 回退接线,保留 Core 能力(`runImport` 仍仅被测试驱动),排查后重启用。
- 每个 PR 独立可回退;`confirmOpenAuthorization`/entitlements **不改**,天然不进回滚面(`MigrationSource` 仅新增 conformance,见 §2.1)。

### 11.3 本节内的未决(完整清单见文末)

- `.confirmCreateFresh` 到底映射到哪种 coordinator 入口形态(新入口 vs 给 `bootResolve` 加"已确认"语义参数)——两者都仍经 `confirmOpenAuthorization` 从磁盘复核,不绕门。
- N7.1/N7.2 是否能可靠隐藏未完成能力,还是需合并为一个 PR。

---

## 备选方案(Alternatives)

### 备选 A:App 层"预启动门"(App 在 `startChain` 之前决定是否弹选择屏)
- **优点**:不改 coordinator/`BootOutcome`/`MigrationUIState`,穷尽 switch 不动。
- **缺点/否决理由**:App 必须自己知道"auto 源不可用 + 磁盘干净"才能决定弹屏,这等于把 probe-first 磁盘判定复制进 App,**直接违反已决约束 0.2-3(App 绝不复制安全判定)与 probe-first 单一裁决源**。判定会分叉到两处、易漂移。**否决。**

### 备选 B:持久化 security-scoped bookmark,支持跨启动重试/续访问源
- **优点**:ingest 崩溃后可不重新选目录直接重试源。
- **缺点/否决理由**:**违反已决约束 0.2-1/0.2-2(单授权窗口、不持久化 bookmark、不新增 bookmarks.app-scope entitlement)**,扩大沙箱攻击面。且第 5 节已证明:ingest 发布后系统自愈、与源解耦,bookmark 收益仅限"ingest 未发布即崩溃"这一窄窗,不值当。**否决。**

### 备选 C:把 DMG 数据目录做成自动候选(在 `.masContainer` 之外硬编码 `~/Library/Application Support/SoloLedger` 为 auto 源)
- **优点**:无需用户选目录,首启自动发现。
- **缺点/否决理由**:MAS 沙箱下该路径**被重定向进容器**,拿不到真实 DMG 的沙箱外位置;真实 DMG 数据**只能经 Powerbox 用户选择**触达。不经用户选择去探测容器外路径在沙箱下**不可能**,且是隐私/同意回退。**否决**(这正是 `.userSelectedDataDir` 必须存在的原因)。

### 备选 D(子选项):"创建新账本"用 `confirmed: Bool` 旗标 / 复用 `.acknowledgement` 而非独立强类型意图
- **优点**:少一个 `BootIntent` case。
- **已否决(决策 2)**:`confirmed: Bool` 或复用 `.acknowledgement(Acknowledgement)`(其语义面向"确认某报告")会让意图语义含混、`Equatable` 断言变模糊。**已定:用独立强类型 `.confirmCreateFresh` 意图**,保持 `receivedIntents` 断言清晰。

---

## 风险与缓解(Risk & Mitigation)

| # | 风险 | 影响 | 缓解 |
|---|---|---|---|
| R1 | confirm→SQLite-open 之间的相邻-syscall TOCTOU 残窗(源/槽被换) | 理论上可被换 inode/软链 | 已 acknowledged 非可关闭残窗;由 hardened open 的 NOFOLLOW + HAS_MOVED + 父(dev,ino) + 叶指纹在任何 SQL 前再校验兜底;失败即确定性关闭、不跑任何 SQL |
| R2 | 用户选中错误/外来文件夹(他 App 数据、非账本目录) | 迁移失败或误读 | Core `FileFingerprint`/`DirectoryHandle`/`FileHash` 类型+no-follow 判定 + `sourceDatabaseMissing`/`sourceNotRegularFile` 早期门 → 经 presenter 映射为**通用**本地化错误(不回显路径) |
| R3 | 用户选中本 App 自己的数据目录 / active store 根 / 危险重叠(自我导入) | 潜在自引用/损坏 | **已定(决策 7):Core 以 device+inode 身份 fail-closed 拒绝**(相等/文件同一/祖先/后代),不做字符串比较,映射通用 `invalidSource`、不泄漏路径(§3.3);跨卷真实副本仍放行 |
| R4 | 大目录 ingest 无法主动取消 | 用户"放弃"后仍跑完 | **已定(决策 9):本轮不实现取消**;UI 执行期不提供取消、只显进度不承诺"取消";进行中链被单飞门挡住无法叠加;主动中止是后续独立项 |
| R5 | ingest 发布前崩溃 + 授权窗口关闭 | 需重新选目录 | 已文档化:回到 `.awaitingSourceChoice` 选择屏重选;发布后则自愈(第 5 节) |
| R6 | 迁移遇已存在 active 槽 | 不得覆盖 | explicit-import fail-closed 到 `importSlotOccupied`(携双 ID),`RENAME_EXCL` 永不覆盖(第 7 节) |
| R7 | i18n parity 回退 / raw-key 泄漏 | 4 语静默回退 | 新 key 进全 6 `.lproj` + `allMigrationKeys()`;`MigrationCopyParityTests` 强制 |
| R8 | 穷尽 switch 漏更新 | 编译失败 | 实为**安全网**(无 default,build 强制补齐),风险低 |
| R9 | MAS 沙箱 entitlement/安全作用域行为无 headless 覆盖 | 真机才暴露 | entitlement 已确认足够(user-selected.read-write);**必须**手动签名沙箱门(第 10 节) |
| R10 | 首启行为从"静默铸空"翻转为"选择屏" | 既有首启 UX 变化 | 有意为之且更正确;由 N7.2 **原子启用**,可独立回退(但回退落回的"静默铸空"**仅开发期临时基线、非发布可接受**,DMG 不可达仍是 P0 —— 阻断 C);不触碰既有 onboarding 步骤 |
| R11 | fixture 无附件,finalize 附件-apply 端到端零覆盖 | 生产首迁才首次跑附件 apply/audit/sha256 复验 | **已定(决策 8):附件-apply 是发布前门禁**——增补含附件+悬空引用的 fixture 变体驱动全链路(§9);可独立 PR 但不得无限延期 |
| R12 | 显式目录导入的 reResolve 塌回 `.boot` 可能被重裁决回 auto 源(静默切源) | 违反"显式选择粘滞" | **实现前必钉死不变量(§7.1)**:`.migrateFromUserDir` 的 reResolve 保留 `MigrationSource` 不塌回 `.boot`,并加守卫测试;`confirm` 仅对 createFresh 派生授权接收 auto 候选 |

---

## 文件影响清单(前瞻性 —— 实现时才会改动,当前一律不改)

> **以下全部为"实现阶段将会改动"的预测清单,本设计阶段不做任何改动。** 路径均为仓库相对 `native/SoloLedger/…`。

| 路径 | 变更类型 | 说明(前瞻) |
|---|---|---|
| `Sources/SoloLedgerCore/Migration/MigrationCoordinator.swift` | 修改 | `resolveB1` `.unavailable` 分支改发 `.requiresSourceChoice`(**N7.2 才启用**);新增 `.confirmCreateFresh` 入口语义;`runImport` 接 `.migrateFromUserDir`;`map` 增 `sourceIsActiveData→invalidSource`。`confirmOpenAuthorization` **不改**;建议 `confirm` 仅对 createFresh 授权收 auto 候选(§7.1) |
| `Sources/SoloLedgerCore/Migration/StagingIngest.swift` | 修改 | 新增 Core 自选防护 `SelfImportGuard`(ingest 头部,§3.3)+ `IngestError.sourceIsActiveData(role:)`(description 仅 role、无路径) |
| `Sources/SoloLedgerCore/Migration/MigrationSource.swift` | 修改(仅加 conformance) | **加 `: Sendable, Equatable`**(全 URL 载荷,编译器合成,零 `@unchecked`/零手写 `==`,§2.1);行为不变 |
| `Sources/SoloLedgerCore/Migration/MigrationUIState.swift` | 修改 | 新增 `.awaitingSourceChoice`(store==nil、ready==false)及不变量注释 |
| `Sources/SoloLedger/App/BootChainRunner.swift` | 修改 | 新增 `BootIntent.confirmCreateFresh` / `.migrateFromUserDir(MigrationSource)`(保持 Equatable);Phase A 映射;`.migrateFromUserDir` 的 reResolve 保留 source 不塌回 `.boot`(§7.1) |
| `Sources/SoloLedger/App/AppModel.swift` | 修改 | 新增意图入口 `confirmCreateFresh()`/`migrateFromUserDir(source:)`/`cancelSourceChoice()`;`makeProductionRunner` 新意图→coordinator 映射(`.migrateFromUserDir→runImport`);复用 `inFlight`/`bootGeneration`/`adopt`/`finish` |
| `Sources/SoloLedgerCore/Migration/MigrationBootDriver.swift` | 修改 | `classifyOutcome` 新增 `.requiresSourceChoice → ui(.awaitingSourceChoice)` |
| `Sources/SoloLedger/App/MigrationPresenter.swift` | 修改 | `routeInput/route/stateTag/block` 穷尽补 `.chooseSource`;新增 `migration.chooseSource.*` key 映射(`invalidSource` 复用) |
| `Sources/SoloLedger/Views/RootView.swift` | 修改 | 新增选择屏视图 + 二次确认 + `render` 分支 + DEBUG `--migration-ui-preview` 预览态 |
| `Sources/SoloLedger/App/FilePanels.swift` | 修改 | 新增目录选择器(`canChooseDirectories=true`, `canChooseFiles=false`);唯一 picker 增量 |
| `Sources/SoloLedger/Resources/{zh-Hans,zh-Hant,en,ja,ko,fr}.lproj/Localizable.strings` | 修改(×6) | 新增 `migration.chooseSource.*`(建议无占位符) |
| `App/Tests/SoloLedgerUnitTests/MigrationCopyParityTests.swift` | 修改 | `allMigrationKeys()` 注册新 key |
| `App/Tests/SoloLedgerUnitTests/AppModelBootTests.swift` | 修改 | 新意图/新状态守卫(单飞、取消 no-op、选择态不构造 store、Phase A 离主、generation 陈旧不发布) |
| `Tests/SoloLedgerCoreTests/`(新文件) | 新增 | N9 Core 变体:真实 `electron-v23.db` 全链路 + `openActiveExistingHardened` 数据存活断言 |
| `App/Tests/SoloLedgerUnitTests/`(新文件) | 新增 | N9 App-hosted 变体:真实 `AppModel.openStoreForPlan` 生产分派断言 |
| `App/Tests/SoloLedgerUITests/MigrationRecoveryUITests.swift` 或新文件 | 修改/新增 | `.chooseSource` 路由表层/无泄漏 UITests |
| `App/Support/SoloLedger.entitlements` / `SoloLedger-Debug.entitlements` | **不改** | 已确认 `user-selected.read-write` 足够;**明确不新增 bookmarks.app-scope** |
| `App/project.yml` | **不改** | entitlement 接线不变 |

---

## 未决问题(待用户确认)

> 说明:v2 已把原 10 项未决中被本轮决策关闭的(状态归属、取消语义、自选防护是否要做、ingest 取消、MAS 手动门、App 预检、附件门禁是否纳入、intent 用不用 confirmed:Bool)全部**关闭并写入相应章节**。以下是**仍然开放、需你拍板才能进实现细节**的剩余项:

1. **`.confirmCreateFresh` 的 coordinator 入口形态**:用一个全新的"已确认 createFresh"入口,还是给 `bootResolve` 加一个"已确认"语义参数?二者都仍经 `confirmOpenAuthorization` 从磁盘复核、不绕门(§11.3)。
2. **选源页与既有 onboarding 的确切关系**:已定"选源页先于开库、成功开库后进原 onboarding";需确认选源页是否**完全独立于** onboarding 首屏(而非替代它),以及"创建新账本"二次确认的确切文案口径。
3. **`.migrateFromUserDir` 的 reResolve 落地方式(§7.1 不变量)**:取 (a) reResolve 保留 `MigrationSource` 不塌回 `.boot`,还是 (b) 形式化证明显式导入在任何 reResolve 可达前已发布 record/active/staging(默认 a)。是否同时把 `confirm` 改成仅对 createFresh 授权接收 auto 候选?
4. **SelfImportRole 粒度**:App 只显示一个通用 `invalidSource`,role 仅用于路径无关的诊断——是否需要区分 `nativeDataRoot`/`activeStoreDir`/`activeAttachmentsDir`/`sameAsActiveDatabaseFile`/`ancestor`/`descendant`,还是收敛为更少的几个?
5. **N9 附件 fixture 的落地形态**:含附件的变体 `.db` 是**提交进仓库**还是**测试时按需生成**;是否顺带 seed 一条 `business_documents` 行以覆盖 `tax_invoice_attachment_path`(该表当前 0 行)。
6. **N7.1/N7.2 拆分 vs 合并**:能否可靠隐藏 N7.1 的未完成能力(不让任何半成品入口对用户可见);若不能,则按 §11.1 合并为一个最小可用闭环 PR。
7. **completed-after-restart 断言深度**:是否额外断言 `confirmOpenAuthorization` 的 completed-probe 重跑返回 `.proceed(.existing(evidence))`(belt-and-suspenders),还是依赖 `attemptOpen` 内部完成。
