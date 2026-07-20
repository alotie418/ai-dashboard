# N7 设计分析:DMG(非沙箱)→ MAS(沙箱)用户数据迁移(来源选择 + createFresh 前置门)

> **状态:设计分析(N7),不实现;须经用户确认后才进入实现。**
> 本文档仅做设计与取舍分析,**不包含任何实现代码**(无 Swift 片段、无 diff),全部以文字、表格、状态/时序描述表达。所有涉及"实现时会改动"的内容均标注为**前瞻性、当前不改动**。
>
> 依据:基于对 `main`(`7d7101c`,已含 C12x-A2)生产代码的**只读**核查(启动状态机、open-plan/active-slot 守卫、`runImport` 管线、`MigrationSource`/预检/安全边界、UI/i18n/entitlements、测试与 fixture)。关联:`SWIFTUI_MIGRATION_PLAN.md` §0.2 / §0.3、`SWIFTUI_FEATURE_GAP.md` 第 4 节的 DMG P0。

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
4. **来源选择必须发生在 `createFresh` 之前**。
5. **导入必须 fail-closed**,**绝不覆盖已存在的 active store**。
6. **Phase-2 报表/会计口径不在本次范围**(仅做数据搬运与开库,不触碰任何会计公式/口径,严格遵守 `CLAUDE.md` 会计红线)。

---

## 推荐方案(Recommended Approach)

**核心决策:把"选择来源"实现为一个由 Core 发出的新 `BootOutcome`(`.requiresSourceChoice`)+ 一个新的 `MigrationUIState`(`.awaitingSourceChoice`),而不是 App 层的"预启动门"。**

理由:约束 0.2-3 与 0.2-4 要求"来源是否可用"这条**安全/磁盘判定归 Core**。若做成 App 层预启动门,App 就必须自己知道"auto 源不可用"才能决定是否弹出选择屏,这等于把 probe-first 判定复制进 App,违反已决约束。让 Core 在 `resolveB1` 原本要授权 `createFresh` 的那个唯一分支上**改为发出"需要来源选择"**,App 只负责渲染两个选项并回抛意图,判定始终留在 Core。

### 推荐时序(端到端)

1. **启动**:`boot()` → `startChain(.boot)` → Phase A `bootResolve(autoSourceCandidate: .masContainer)` 全程离主线程复核磁盘。
2. **到达 createFresh 结点**:`resolveB1` 在"无 record / 无 active / 无 staging / 无 sentinel 且 `sourceState(.masContainer)==.unavailable`"分支,**不再**返回 `.openStore(.createFreshExpectedAbsent)`,改为返回**新** `.requiresSourceChoice`。
3. **分类**:`MigrationBootDriver.classifyOutcome` 把 `.requiresSourceChoice` 映射为 `ui(.awaitingSourceChoice)`(**非 openStore**,故绝不构造 store)→ `finish()` 落地,`inFlight=false`。
4. **渲染**:`MigrationPresenter.route` 增加一条 `.chooseSource` 路由,`RootView` 渲染"迁移旧数据 / 创建新账本"两个动作(全部经 `model.t(key)`)。
5. **分支 A —— 创建新账本**:用户点"创建新账本" → 新意图 `.chooseCreateFresh` → `startChain` 复用 `!inFlight` 单飞 → Phase A 走回 `resolveB1` 的**已确认 createFresh** 语义 → `.openStore(.createFreshExpectedAbsent)` → `confirmOpenAuthorization` **从磁盘再次复核全部前置**(active 缺席 / record 缺席 / 无 sentinel/staging / 且 auto 源此刻仍 `.unavailable`)→ `createFreshReservedHardened`(`O_CREAT|O_EXCL|O_NOFOLLOW` 独占预留)。此后维持既有 onboarding(公司信息)流程不变。
6. **分支 B —— 迁移旧数据**:用户点"迁移旧数据" → Powerbox `NSOpenPanel(canChooseDirectories=true)` → 拿到安全作用域 URL → 在**同一个** `withAccess` 授权窗口内构造 `.userSelectedDataDir(url)` → 新意图 `.migrateFromUserDir(source)` → `startChain` → Phase A(离主线程)`coordinator.runImport(source:)` 跑完整 ingest→gate→prepare→activate→finalize。**ingest 把源库+WAL+附件复制进内部 Staging 后,授权窗口即可关闭**,后续所有阶段只吃内部 staging,不再触碰源目录。
7. **开库**:`runImport` 成功返回 `.openStore(.openExistingCompleted(CompletionEvidence))` → `classifyOutcome` → `attemptOpen` → `confirmOpenAuthorization`(再次从磁盘复核 + 捕获 `ActiveOpenEvidence`)→ `openActiveExistingHardened`(NOFOLLOW + HAS_MOVED + 父/叶指纹校验)→ `adopt` 原子发布 store。
8. **失败**:任一阶段 fail-closed;若 active 槽已被占用,explicit-import 上下文返回 `.blocked(.terminal(.importSlotOccupied,{requestedImportID,existingImportID}))`,**绝不覆盖、绝不静默丢弃用户选择**。

这条路径把新增复杂度收敛到:**1 个新 `BootOutcome` + 1 个新 `MigrationUIState` + 2 个新 `BootIntent` + 1 个目录选择器 + 1 组 `migration.chooseSource.*` 文案**,其余全部复用既有 probe-first 判定与 hardened open。

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
- **新增两个 `BootIntent`(`Equatable`)**:`.chooseCreateFresh`(确认创建新账本)与 `.migrateFromUserDir(MigrationSource)`(携带用户选定来源)。二者都像现有意图一样:先 `guard store == nil`,受单飞门控,进入 `.running(.resolving)`。
- **穷尽 switch 的连带更新(编译器强制)**:`MigrationPresenter.routeInput` / `route` / `stateTag` / `block(from:)`,以及 `MigrationBootDriver` 的 `classify/classifyOutcome`——新增状态会让 build 失败直到每处补齐,这是刻意的安全网。

---

## 2. AppModel / BootChainRunner / MigrationCoordinator 职责分工

| 组件 | 本次新增/变化后的职责 | 明确的边界 |
|---|---|---|
| **AppModel**(`Sources/SoloLedger/App/AppModel.swift`) | @MainActor 编排:新增意图入口 `chooseCreateFresh()` / `migrateFromUserDir(source:)` / `cancelSourceChoice()`;把新意图接入 `startChain`(复用 `inFlight`、`bootGeneration`、两阶段 `runChain`、`adopt`、`finish`);在 `makeProductionRunner` 里把新意图映射到 coordinator 入口。 | **绝不复制安全判定**:只透传不可伪造的 plan/evidence;唯一开库点 `openStoreForPlan` 仅**分派** `.createFresh`/`.existing` 到 Core 的 hardened opener,不重实现任何检查(受生产接线守卫测试保护 `AppModel.swift:288-292`)。 |
| **BootChainRunner + ProductionBootChainRunner**(`BootChainRunner.swift`) | 定义线程契约的接缝:新增 `BootIntent` case;Phase A `resolveOutcome` 经 `Task.detached` 把 `runImport`(含安全作用域内的重 ingest)推离主线程,只回传值类型 `BootOutcome`;Phase B `attempt` 保持 @MainActor 同步。 | 只搬运意图与值类型,**从不返回 LedgerStore**;`.migrateFromUserDir` 的重活必须在 Phase A 离主线程(受 `testProductionPhaseARunsOffTheMainActor` 钉住)。 |
| **MigrationBootDriver**(`MigrationBootDriver.swift`) | 纯同步定序器:`classifyOutcome` 新增 `.requiresSourceChoice → ui(.awaitingSourceChoice)`;`attemptOpen` 的 authorization×plan 交叉核对保持不变。 | 不构造 store、不重试、不碰 coordinator 内部;只有 `.openStore` 能到达 `attemptOpen`。 |
| **MigrationCoordinator**(`MigrationCoordinator.swift`) | probe-first 从磁盘裁决:`resolveB1` 的 `.unavailable` 分支改发 `.requiresSourceChoice`;新增"已确认 createFresh"入口语义;`runImport(source:)` 接入 `.migrateFromUserDir`;`confirmOpenAuthorization` **不变**(继续从磁盘复核 createFresh/existing/completed)。 | **拥有全部身份/gate/hardened-open 判定的裁决**;**从不构造 LedgerStore**(C12a 契约);每次调用都从磁盘重新推导,绝不信任缓存。 |

关键分工原则:**"是否可 createFresh / 源是否可用 / 是否已有 active"是 Core 的磁盘判定;App 只知道"Core 让我渲染选择屏"和"用户点了哪个按钮"。**

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
- **设计取舍**:App 层可做一个**极薄的只读探测**用于文案分流(例如"该文件夹看起来不含账本数据"),但该探测**只能产出 UI 提示,不得作为开库依据**;所有能真正阻止/放行的判定必须在 `runImport` 内由 Core 重做。为避免 App 复制安全判定,推荐**首选方案是:App 不做预探测,直接把选中目录交给 `runImport`,由 Core 的 ingest 早期门返回类型化错误,再经 `MigrationPresenter` 映射成本地化文案**(见第 8 节)。若产品需要"选完立刻提示无数据"的体验,则把该薄探测限定为"仅影响文案、绝不影响授权",并在实现前明确列为待确认项(见未决问题)。

> 注:`MigrationSource.userSelectedDataDir` **本身不 no-follow 校验所选目录是否真目录,也不防止用户选中本 App 自己的数据目录(自我导入)**。这与"Core 拥有判定"的设计一致(下游 `DirectoryHandle`/`FileFingerprint` 会兜住类型),但**没有显式的自选防护**。是否加自选守卫见风险表与未决问题。

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
  - **`cancelSourceChoice()`(若提供"返回/放弃"入口)**:镜像 `cancelImportSelection`——**仅当** `migrationUIState == .awaitingSourceChoice` 时才动作,其它状态一律 no-op(受同类守卫测试保护)。它**绝不开库、绝不创建、绝不自动选源**。其安全静止态是"停留在选择屏"或落 `.terminal(userCancelled)`——**推荐停留在选择屏**(因为选择屏本身就是可静止的 `store==nil` 态),避免把用户推向静默 createFresh。是否需要一个"退出到终态并显式重试"的语义,列为未决问题。
  - **取消进行中的 ingest**:目前**没有 Task 主动取消**(`currentBootTask` 保留但从不 `.cancel()`,取代只靠 `bootGeneration`)。因为 `startChain` 被 `!inFlight` 门控且 `inFlight` 只在 `finish` 清零,链进行中无法启动第二条,所以 generation 守卫是纵深防御。**"用户中途放弃一个大目录导入"没有主动中止机制**——列为未决问题/超范围(见风险表)。
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
- **占位符纪律**:上述 key 若引入 `{count}`/`{importID}` 之类 token,必须在 `testExpectedPlaceholderKeysOnly` 里钉住;**推荐这些 key 全部无占位符**,避免额外 parity 负担。`importSlotOccupied` 等既有块文案已在 `migration.*` 内,复用即可(其 `{importID}` 已被现有 parity 覆盖)。
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
  5. 断言:7 笔交易存活、income/expense/net 汇总正确、4 设置(accounting_locale/currency/company_name/ui_language)、78 分类关联存活、全枚举(income/expense;paid/partial/unpaid;issued/pending/na)未损。
- **两个变体**:
  - **Core-target**(`SoloLedgerCoreTests`,`swift test`):直接调 `openActiveExistingHardened`,验证链 + 数据存活。
  - **App-hosted**(`SoloLedgerUnitTests`,`@testable import SoloLedger`):驱动真实 `AppModel.openStoreForPlan` 生产分派,覆盖那段确切接线。
- **附件覆盖**:committed fixture 全为 `attachment_path=null`,**无法**驱动 finalize 的附件-apply。若门禁要求附件覆盖,需增补一个"源树含 `docs/` 附件且被某交易引用"的 fixture 变体——是否纳入 N9 列为未决问题。
- **MAS 沙箱安全作用域**:`withAccess/startAccessingSecurityScopedResource`(files.user-selected.read-write)在无头 Core/Unit 测试里是 no-op,**无法headless 证明**;需真实签名沙箱运行(见第 10 节手动门)。

---

## 10. Unit / UI / Core / MAS 沙箱验证矩阵

| 层 | 目标 | 运行方式 | 关注点 |
|---|---|---|---|
| **Core**(`SoloLedgerCoreTests`) | 真实 fixture 全链路 + hardened open 数据存活(N9 Core 变体);`resolveB1` 改发 `.requiresSourceChoice` 的裁决;`runImport` explicit-import 冲突(`importSlotOccupied`)端到端 | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` | probe-first、fail-closed、freshCollision、RENAME_EXCL 不覆盖 |
| **Unit(App-hosted)**(`SoloLedgerUnitTests`,`@testable import SoloLedger`) | 新意图/新状态的启动机守卫:单飞丢第二击、取消 no-op(状态外)、`.awaitingSourceChoice` 绝不构造 store、Phase A 离主线程、generation 陈旧不发布;N9 App-hosted 变体(真实 `openStoreForPlan`);`MigrationCopyParityTests` 注册新 key | `xcodebuild -project App/SoloLedger.xcodeproj -scheme SoloLedger test`(同 `DEVELOPER_DIR`) | 用 FAKE scripted runner 覆盖状态机;真实 fixture 覆盖开库分派 |
| **UI**(`SoloLedgerUITests`) | 新 `.chooseSource` 路由的表层/路由安全:经 `--migration-ui-preview` 合成态渲染两个动作、文案经 key、无原始枚举/路径泄漏 | 同上 xcodebuild scheme | 结构性(无真实 DB),保证 render switch 穷尽且不泄漏 |
| **i18n parity** | `migration.chooseSource.*` 6 语齐全、无 raw-key 泄漏、占位符集与 en 一致 | `MigrationCopyParityTests`(Unit 目标内) | 新 key 必须进 `allMigrationKeys()` |
| **MAS 沙箱(手动)** | 真实签名沙箱构建 → 选一个 DMG-Electron 数据文件夹 → 确认 Powerbox 安全作用域读成功 → 完成迁移并开库 | 手动:签名/构建 → 运行 → 选目录 → 断言迁移成功 | **无法 headless 自动化**;必须作为发布前手动门列入清单 |

> 说明:`swift test` 需 `DEVELOPER_DIR` 指向完整 Xcode(XCTest 只随完整 Xcode 分发),与 MEMORY 记录一致。

---

## 11. 分阶段实施 PR 拆分、回滚条件、未决问题(实施纪律)

### 11.1 PR 拆分(小而聚焦,遵守 `CLAUDE.md` PR 纪律)

| PR | 范围 | 门禁/依赖 |
|---|---|---|
| **N7.0(门禁)** | N9 真实 fixture 全链路测试(Core + App-hosted 变体),含 finalize-before-open 与生产开库分派断言。**无任何生产行为变化。** | 必须先绿;未绿不得进入后续 PR |
| **N7.1(Core 裁决 + 状态词汇)** | 新 `BootOutcome.requiresSourceChoice`;`resolveB1` `.unavailable` 分支改发之;新 `MigrationUIState.awaitingSourceChoice`;新 `BootIntent.chooseCreateFresh`/`.migrateFromUserDir`;`ProductionBootChainRunner` 把新意图映射到 coordinator(`runImport` / 已确认 createFresh 入口);全部穷尽 switch 补齐;`MigrationBootDriver.classifyOutcome` 补映射;App 渲染一个**可用但简朴**的选择屏(避免死态/静默铸空)。Core+Unit 守卫测试。 | 依赖 N7.0;此 PR 是"首启行为翻转"点 |
| **N7.2(目录选择器 + 安全作用域)** | `FilePanels` 新增 `canChooseDirectories=true` 目录选择器;在单一 `withAccess` 窗口内构造 `.userSelectedDataDir`;只读预检 UX(通用措辞,判定交 Core);接入 `.migrateFromUserDir`。 | 依赖 N7.1 |
| **N7.3(i18n + presenter + UI 收尾)** | `migration.chooseSource.*` 全 6 语 + 注册 `allMigrationKeys()`;`MigrationPresenter` 路由/key;`RootView` 正式选择屏 + DEBUG 预览;UITests。 | 依赖 N7.1/N7.2 |

### 11.2 回滚条件

- **N9 未绿** → 停,绝不接 picker(硬门)。
- **N7.1 后首启 UX 有问题 / 穷尽 switch 或 parity 意外红** → 回退 N7.1(回退即恢复 N7 前的"静默铸空"旧行为,是可接受的安全回退基线)。
- **N7.2 后 MAS 沙箱手动门失败(安全作用域未授予/读失败)** → 回退 N7.2 接线,保留 Core 能力(`runImport` 仍仅被测试驱动)。
- 每个 PR 独立可回退;`MigrationSource`/entitlements/`confirmOpenAuthorization` **不改**,天然不进回滚面。

### 11.3 本节内的未决(完整清单见文末)

- "创建新账本"确认的确切 coordinator 入口形态(新入口 vs 给 `bootResolve` 加"已确认"参数)。
- 取消选择的静止态(停留选择屏 vs 终态显式重试)。
- 是否需要自选防护(拒绝选中本 App 自己的数据目录)。

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

### 备选 D(子选项):"创建新账本"复用现有 `.acknowledgement` 机制而非新增 `.chooseCreateFresh` 意图
- **优点**:少一个 `BootIntent` case。
- **缺点/权衡**:`.acknowledgement(Acknowledgement)` 语义面向"确认某报告",复用会让意图语义含混、测试断言变模糊。推荐仍用**专用意图**以保持 `Equatable` 意图的可断言性;此子选项作为可讨论项保留,不作首选。

---

## 风险与缓解(Risk & Mitigation)

| # | 风险 | 影响 | 缓解 |
|---|---|---|---|
| R1 | confirm→SQLite-open 之间的相邻-syscall TOCTOU 残窗(源/槽被换) | 理论上可被换 inode/软链 | 已 acknowledged 非可关闭残窗;由 hardened open 的 NOFOLLOW + HAS_MOVED + 父(dev,ino) + 叶指纹在任何 SQL 前再校验兜底;失败即确定性关闭、不跑任何 SQL |
| R2 | 用户选中错误/外来文件夹(他 App 数据、非账本目录) | 迁移失败或误读 | Core `FileFingerprint`/`DirectoryHandle`/`FileHash` 类型+no-follow 判定 + `sourceDatabaseMissing`/`sourceNotRegularFile` 早期门 → 经 presenter 映射为**通用**本地化错误(不回显路径) |
| R3 | 用户选中本 App 自己的数据目录(自我导入) | 潜在自引用/损坏 | 当前**无显式自选守卫**;建议新增(比对解析后的规范目录 == native 数据目录则拒绝)——列为未决问题 |
| R4 | 大目录 ingest 无法主动取消 | 用户"放弃"后仍跑完 | 目前只有 `bootGeneration` 取代、无 `Task.cancel`;进行中链被单飞门挡住无法叠加;主动中止大 ingest 列为未决/超范围;UX 上提供进度提示但不承诺"取消" |
| R5 | ingest 发布前崩溃 + 授权窗口关闭 | 需重新选目录 | 已文档化:回到 `.awaitingSourceChoice` 选择屏重选;发布后则自愈(第 5 节) |
| R6 | 迁移遇已存在 active 槽 | 不得覆盖 | explicit-import fail-closed 到 `importSlotOccupied`(携双 ID),`RENAME_EXCL` 永不覆盖(第 7 节) |
| R7 | i18n parity 回退 / raw-key 泄漏 | 4 语静默回退 | 新 key 进全 6 `.lproj` + `allMigrationKeys()`;`MigrationCopyParityTests` 强制 |
| R8 | 穷尽 switch 漏更新 | 编译失败 | 实为**安全网**(无 default,build 强制补齐),风险低 |
| R9 | MAS 沙箱 entitlement/安全作用域行为无 headless 覆盖 | 真机才暴露 | entitlement 已确认足够(user-selected.read-write);**必须**手动签名沙箱门(第 10 节) |
| R10 | 首启行为从"静默铸空"翻转为"选择屏" | 既有首启 UX 变化 | 有意为之且更正确;N7.1 单独 PR 可独立回退恢复旧行为;不触碰既有 onboarding 公司信息步骤 |
| R11 | fixture 无附件,finalize 附件-apply 未覆盖 | 附件路径盲区 | N9 用无附件 fixture 覆盖主链;附件覆盖需增补 fixture 变体,列为未决 |

---

## 文件影响清单(前瞻性 —— 实现时才会改动,当前一律不改)

> **以下全部为"实现阶段将会改动"的预测清单,本设计阶段不做任何改动。** 路径均为仓库相对 `native/SoloLedger/…`。

| 路径 | 变更类型 | 说明(前瞻) |
|---|---|---|
| `Sources/SoloLedgerCore/Migration/MigrationCoordinator.swift` | 修改 | `resolveB1` `.unavailable` 分支改发 `.requiresSourceChoice`;新增"已确认 createFresh"入口语义;`runImport` 接 `.migrateFromUserDir`。`confirmOpenAuthorization` **不改**(复用) |
| `Sources/SoloLedgerCore/Migration/MigrationUIState.swift` | 修改 | 新增 `.awaitingSourceChoice`(store==nil、ready==false)及不变量注释 |
| `Sources/SoloLedger/App/BootChainRunner.swift` | 修改 | 新增 `BootIntent.chooseCreateFresh` / `.migrateFromUserDir(MigrationSource)`(Equatable);Phase A 映射 |
| `Sources/SoloLedger/App/AppModel.swift` | 修改 | 新增意图入口 `chooseCreateFresh()`/`migrateFromUserDir(source:)`/`cancelSourceChoice()`;`makeProductionRunner` 新意图→coordinator 映射;复用 `inFlight`/`bootGeneration`/`adopt`/`finish` |
| `Sources/SoloLedgerCore/Migration/MigrationBootDriver.swift` | 修改 | `classifyOutcome` 新增 `.requiresSourceChoice → ui(.awaitingSourceChoice)` |
| `Sources/SoloLedger/App/MigrationPresenter.swift` | 修改 | `routeInput/route/stateTag/block` 穷尽补 `.chooseSource`;新增 `migration.chooseSource.*` key 映射 |
| `Sources/SoloLedger/Views/RootView.swift` | 修改 | 新增选择屏视图 + `render` 分支 + DEBUG `--migration-ui-preview` 预览态 |
| `Sources/SoloLedger/App/FilePanels.swift` | 修改 | 新增目录选择器(`canChooseDirectories=true`, `canChooseFiles=false`);唯一 picker 增量 |
| `Sources/SoloLedgerCore/Migration/MigrationSource.swift` | **不改(复用)** | 已支持 `.userSelectedDataDir` + 单授权窗口 `withAccess`;明确不动 |
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

1. **状态归属确认**:是否采用推荐方案——"选择来源"作为 Core 发出的新 `BootOutcome.requiresSourceChoice` + 新 `MigrationUIState.awaitingSourceChoice`(需改 coordinator 与穷尽 switch),而非 App 层预启动门?(推荐前者;后者违反 App 不复制安全判定。)
2. **"创建新账本"确认的入口形态**:用专用新意图 `.chooseCreateFresh` 映射到一个"已确认 createFresh"的 coordinator 入口,还是给 `bootResolve` 加一个"已确认"参数?(两者都仍经 `confirmOpenAuthorization` 从磁盘复核,不绕门。)另需确认:选择屏与既有 onboarding(公司信息)流程的先后关系——选择屏**先于**开库、onboarding 在开库后不变?还是替代 onboarding 首屏?
3. **迁移意图映射到哪个 coordinator 语义**:`.migrateFromUserDir` 走 `runImport(source:)`(explicit-import 上下文,槽冲突显式 `importSlotOccupied`),这是推荐;是否有场景需要走"换 autoSourceCandidate 的 bootResolve"(auto 裁决)?二者冲突语义不同。
4. **取消语义**:取消来源选择的安全静止态——停留在选择屏(推荐,纯 no-op),还是落 `.terminal(userCancelled)` 要求显式重试?"create fresh"是否需要二次确认?
5. **auto 源在选择过程中变可用**:用户已选源,但期间 `.masContainer` 变可用——应 reResolve 回自动导入路径,还是坚持用户显式选择?(`confirmOpenAuthorization` 目前只在 createFresh 分支复核 auto 源;这里是 import 分支的产品语义决策。)
6. **只读预检范围**:是否需要 App 侧薄探测"选中文件夹是否含账本数据"以即时分流文案(仅影响文案、绝不影响授权),还是直接交给 Core ingest 早期门返回类型化错误(推荐,零 App 判定)?
7. **自选防护**:是否新增守卫,拒绝用户选中本 App 自己的 `SoloLedgerNative(Preview)` 数据目录(防自我导入)?
8. **N9 门禁范围**:是否要求 N9 现在就覆盖附件-apply(需增补"含 `docs/` 附件且被交易引用"的 fixture 变体),还是本次 N9 以无附件 fixture 为准、附件覆盖后置?N9 是否需**同时**断言 `.openExistingCompleted` 的"新导入刚完成"路径与"完成后重启 probe"路径?
9. **进行中 ingest 的主动取消**:是否本次范围内引入 Task 取消以支持"放弃大目录导入",还是维持仅 `bootGeneration` 取代并在 UI 上不承诺取消(推荐后者,超范围)?
10. **MAS 沙箱手动门**:是否将"真实签名沙箱构建 → 选 DMG-Electron 数据目录 → 确认安全作用域读 → 迁移开库成功"正式列入发布前手动验证清单(因其无法 headless 自动化)?
