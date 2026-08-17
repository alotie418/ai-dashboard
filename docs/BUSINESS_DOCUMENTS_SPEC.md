# 单据章口径确认书（D-0）

本文件是**原生单据章唯一的口径依据**。它记录用户对测绘九问的裁定，供 D-1…D-6 各轮直接引用；实现轮不得在本文件之外自行确立口径，也不得把本文件里没有的东西当成已裁定。

三条使用规则：

* **只写已裁定项。** 尚未裁定的留在 §8，实现轮遇到它必须停下来要裁定，不得自行择定。
* **每条附证据锚，锚是符号不是行号。** 行号会腐烂；本文件的锚全部是函数名、常量名、类型名或表名，可用 `grep` 直接定位。
* **量化数字只写本轮实测得到的。** 未来轮次的测试数与键数一律标为**预计**，不构成承诺。

测绘报告（2026-08-17 会话，只读零写入）是本文件每条证据的来源。文中「实测」二字均指该轮在 `main = 139d6018` 上跑出的结果。

---

## 1. 裁定摘要

| 问 | 裁定 | 性质 |
| --- | --- | --- |
| Q1 类型半径 | 全 5 照搬 | 镜像 |
| Q2 对账单 | 生成器改接原生 `transactions` | **发明（唯一一处）** |
| Q3 编号 | 全部照搬 | 镜像 |
| Q4 税口径 | 全部照搬 | 镜像 |
| Q5 状态机与联动 | 照搬，零联动 | 镜像 |
| Q6 客户字段 | 自由文本照搬 | 镜像 |
| Q7 输出 | 首版导出自包含 HTML | 收窄（Electron 出 PDF） |
| Q8 币种 | 照搬隐式本位币 | 镜像 |
| Q9 存储 | 甲案：写 v11 既有表；计算迁入 Core，算式逐字复刻 | 镜像 + 归位 |

**除 Q2 外，本章不接受任何发明。** 遇到 Electron 没有的行为，默认答案是「不做」，不是「顺手加上」。

---

## 2. 逐条确认书

### Q1 · 文档类型半径 = 全 5 照搬

原生支持的 `doc_type` 闭集与 Electron **相等**，恰五个：`quotation` / `sales_order` / `proforma_invoice` / `commercial_invoice` / `statement`。不增、不减、不改名。

* **证据锚**：`electron/handlers/documents.js` 的 `DOC_TYPES`；`electron/db/index.js` 迁移 v11 中 `business_documents.doc_type` 的 `CHECK` 子句；原生 `SchemaMigrator.swift` 同一 v11 级的同名 `CHECK`。三处闭集实测一致。
* **可测断言**：原生的类型闭集常量元素个数 == 5，且逐元素等于上述五个字符串；写入一个不在闭集内的 `doc_type` 必须被拒绝，而不是落库。
* **边界**：Electron 没有「收据」类型，本章也不做；正式税务发票**不是**一种 `doc_type`（它是表头上的四个关联列，见 Q5）。

### Q2 · 对账单生成器改接原生 `transactions`

**这是本章唯一一处对确认书背书的新口径，不是镜像。** Electron 的对账单行来自 `sales` 表；实测原生写入的表是闭集十张（`settings` / `transactions` / `products` / `legacy_migrations` / `inventory_movements` / `inventory_exceptions` / `inventory_balances` / `home_office` / `categories` / `ai_providers`），**`sales` 不在其中**。逐字镜像会得到一个在原生自建账本上永远生成不出任何一行的类型——与资产负债概览章被挂起的形状相同。故改接。

裁定的三条口径，写成实现轮可以直接照着写断言的形态：

1. **行来源**：`transactions` 中 `type = 'income'` 的行。（`transactions.type` 的 `CHECK` 闭集是 `('income','expense')`，原生 `TransactionType` 枚举同为两例。）
2. **匹配**：`transactions.counterparty` 与单据 `customer_name` **精确匹配**。（Electron 侧的对应语义是 trim 后的字符串相等，见 `DocumentModal.tsx` 的 `generateStatement`；相等判定不做大小写折叠、不做模糊。）
3. **日期范围**：限定在单据自己的期间内，闭区间。（Electron 侧同为闭区间的 ISO 日期字符串比较，见 `generateStatement`；期间由 `business_documents.period_start` / `period_end` 两列承载。）
4. **客户下拉的取值来源**：`transactions.counterparty` 去重。（Electron 侧的对应物是 `DocumentModal.tsx` 的 `stmtCustomers`，对 `sales.customer` 去重后排序；实测它是全仓**唯一**一处客户去重清单。）

* **证据锚**：`components/DocumentModal.tsx` 的 `generateStatement` / `stmtCustomers` / `salesToRow`；`electron/db/index.js` 迁移 v5 中 `transactions` 的 `type` `CHECK` 与 `counterparty` 列；原生 `Enums.swift` 的 `TransactionType`；原生 `LedgerStore.swift` 的 `INSERT INTO transactions`。
* **可测断言**（D-1/D-2 应各自落成测试）：给定一组含 `income` 与 `expense`、多个 `counterparty`、跨越期间边界的流水，生成器返回的行集恰等于「`income` ∧ `counterparty` 相等 ∧ 日期在闭区间内」的那一组；边界两天必须包含；`expense` 行必须不出现；`counterparty` 不等的行必须不出现。
* **未裁定的残余**：**逐行字段怎么映射尚未裁定**，见 §8 的 Q2-a。没有它，D-1 无法开工。

### Q3 · 单据编号 = 全部照搬

| 项 | 裁定 |
| --- | --- |
| 格式 | `<前缀>-<年>-<4 位序号>` |
| 前缀表 | `quotation`→`QT`、`sales_order`→`SO`、`proforma_invoice`→`PI`、`commercial_invoice`→`CI`、`statement`→`ST` |
| 年度 | 按年重置（年份在编号里） |
| 连续性 | **不保证连续**：删除或作废后号码被释放，可被重用；跳号是正常状态 |
| 可编辑性 | 自动值只是**建议**，用户可改 |
| 年份来源 | 本地时区的当前年 |
| 唯一性 | 仅 `(doc_type, doc_number)` 唯一——同一编号可在五种类型里各存在一次 |

* **证据锚**：`electron/handlers/documents.js` 的 `nextNumber` 与 `NUMBER_PREFIX`；同文件的 `runGuardingNumberConflict`（唯一索引冲突翻成稳定错误码 `DOC_NUMBER_EXISTS`）；`electron/db/index.js` 迁移 v11 的 `idx_docs_type_number` 唯一索引；`components/DocumentModal.tsx` 中用户改号后停止自动跟随的 `numberEditedRef`。
* **可测断言**：空库取号得 `<前缀>-<年>-0001`；建一张 `QT-<年>-0007` 后再取号得 `QT-<年>-0008`；**自定义编号不污染序号最大值**（Electron 侧已有同名断言，实测在 `scripts/test-handlers.mjs` 的 §2B Batch 8 内）；同一 `(类型, 编号)` 第二次写入被拒绝，不同类型同编号可写入。
* **登记**：「本地时区」是一个真实的口径选择，跨年当天在不同时区会得到不同前缀。照搬即接受。

### Q4 · 税口径 = 全部照搬

* **单价是不含税价**。（`services/api.ts` 中 `BusinessDocumentItem.unitPrice` 的字段注释即写「不含税单价」。）
* **行税额** = `round2(round2(数量 × 单价) × 税率 / 100)`——先把行金额舍到分，再乘税率，再舍一次。
* **合计** = 不含税小计 + 税额；小计与税额都是**行值求和**，不重算。
* **税率存文本**，`"13%"` 形；读回时去掉 `%` 再 `parseFloat`。空值存 `NULL`。
* **没有含税录入模式，没有折扣字段。**

* **证据锚**：`components/DocumentModal.tsx` 的 `computed`（其中的本地 `round2` 是该文件自己的常量，不是 `accountingHelpers` 的导出）；`electron/handlers/documents.js` 的 `sumTotals` 与 `round2`；`electron/db/index.js` 迁移 v11 中 `business_document_items.tax_rate TEXT`。
* **可测断言**：舍入次序可被单测钉死——存在输入使「先舍后乘」与「先乘后舍」结果不同，取前者；合计等于行值之和而非由数量单价重算。
* **边界**：本章不引入含税模式、不引入折扣、不引入运费或预付尾款。

### Q5 · 状态机与联动 = 照搬，零联动

**状态机**：`draft → issued | void`；`issued → void`；`void` 是终态。
**编辑**：仅 `draft` 可改字段与明细。
**删除**：`issued` 不可直接删除（必须先作废）；`draft` 与 `void` 可删除。
**联动**：**签发不落流水、不扣库存、不进任何报表。**

* **证据锚**：`electron/handlers/documents.js` 的 `STATUS_TRANSITIONS`、`DOC_STATUSES`、`update` 中的 `EDITABLE` 白名单、`remove` 中对 `issued` 的拦截（稳定错误码 `DOC_ISSUED_VOID_FIRST`）。
* **边界断言（实现轮必须落成测试）**：
  1. 原生报表引擎对 `business_documents` 与 `business_document_items` **零读**。实测依据：`electron/reports/` 下 `FROM <表>` 的闭集是 `transactions` / `sqlite_master` / `settings` / `sales` / `purchases` / `categories` 六张，单据两表一次不出现（该图案在同一次扫描中命中了六张真表，故不是空图案）。
  2. 原生库存引擎对单据两表零读、零写。
  3. 单据的任何状态流转都不产生 `transactions` 行、不产生库存流水行。
* **正式税务发票关联**：`tax_invoice_issued` / `_number` / `_date` / `_attachment_path` 四列**只记录外部已开具的发票信息**，号码只能手工录入，**永不自动生成**；`void` 单据上该关联为只读。证据锚：`electron/handlers/documents.js` 的 `updateTaxInvoice`（稳定错误码 `DOC_VOID_TAX_INVOICE_READONLY`、`ATTACHMENT_IN_USE`、`INVALID_ATTACHMENT_PATH`）。

### Q6 · 客户字段 = 自由文本照搬

单据的客户是自由文本 `customer_name`，外加三个可选文本 `customer_tax_id` / `customer_address` / `customer_contact`。**本章不建客户主数据表。**

* **证据锚**：`electron/db/index.js` 迁移 v11 的四列；`docs/SWIFTUI_FEATURE_GAP.md` §3「客户 / 供应商」行（🟡，`counterparty` 为自由文本）。
* **登记**：实测 Electron 内并存**三个互不相通的客户自由文本命名空间**——`transactions.counterparty`、`sales.customer` / `purchases.supplier`、`business_documents.customer_name`。原生只写第一个。Q2 的客户下拉因此取 `transactions.counterparty`。
* **不属本章**：客户主数据实体化（原「b-轻」）继续独立推迟，见 §5。

### Q7 · 输出 = 首版导出自包含 HTML

* **首版形态**：导出一份**自包含 HTML 文件**（样式内联、无外部资源、用户文本全量转义），经 Powerbox 存盘。
* **模板语义镜像 Electron**：抬头（公司名 + 可选税号/地址/负责人）、单据 meta 行（编号 / 日期 / 可选有效期 / 对账期间）、客户块、明细表（描述 / 数量与单位 / 单价 / 税率 / 税额 / 金额六列）、合计三行（小计 / 税额 / 总计）、备注块、页脚。
* **页脚免责声明必须在产物内**，不是只在界面上；后续轮把「产物里必然含免责声明」写成守门断言。
* **系统打印**（`NSPrintOperation` 路线）登记为**后续轮候选**：它需要动 2c-7 已经钉死的 entitlements 闭集，属另行裁定。
* **`WKWebView` 路线否决**：与 #483 钉住的「无网络」能力守门冲突。

* **证据锚**：`components/documentPdf.ts` 的 `buildDocumentHtml` / `escapeHtml` / `cjkFonts` 与 `DocumentPdfLabels.disclaimer`；`electron/handlers/index.js` 的 `app:exportReportPdf`（Electron 用隐藏 `BrowserWindow` + `printToPDF` 出 PDF，原生无此栈）；`native/SoloLedger/Tests/SoloLedgerCoreTests/CapabilityImportGuardTests.swift`（能力闭集守门）。
* **收窄说明**：Electron 一键出 PDF，原生首版出 HTML。**这是一处功能收窄，文案必须说清**，不得让用户以为拿到的是 PDF。

### Q8 · 币种 = 照搬隐式本位币

单据**没有币种列**。显示币种由单据创建时冻结的 `acc_locale` 推导；`JPY` / `KRW` 显示 0 位小数，其余 2 位。不可选、不可改、不做换算、不做合计跨币种。

* **证据锚**：`electron/db/index.js` 迁移 v11（`business_documents` 无 currency 列，有 `acc_locale`）；`components/accountingHelpers.ts` 的 `formatMoney`；`electron/handlers/documents.js` 的 `resolveAccLocale`（创建时解析、`update` 忽略）。
* **可测断言**：同一张单据在设置切换会计制度后，显示币种不变——因为读的是行上冻结的 `acc_locale`，不是当前设置。

### Q9 · 存储 = 甲案（写 v11 既有表），计算迁入 Core 但逐字复刻

* **不建新表、不加列。** 原生写 `SchemaMigrator` v11 级已经建好的 `business_documents` 与 `business_document_items`；金额列保持 `REAL`，`tax_rate` 保持 `TEXT`。
* **计算位置从界面迁到 Core。** Electron 的行金额与行税额由前端算、后端只求和；原生把算式放进 Core，**但算式与舍入链逐字复刻 Electron 前端**。
* **验收 = 同输入下结果与 Electron 逐字节相等。**

* **证据锚**：原生 `SchemaMigrator.swift` 的 v11 级（与 `electron/db/index.js` 同级 DDL 实测同构：同列、同 `CHECK`、同索引、同外键）；`electron/handlers/documents.js` 的 `sumTotals`（注释自述「只求和、不重算行金额」）；`components/DocumentModal.tsx` 的 `computed`。
* **两条必须写进设计的分域声明**：
  1. **单据金额域与 N 章库存的整数分域不互通。** 单据用 `Double` + `REAL`，库存用整数分；两者之间没有任何数值流动，也不允许有。
  2. **零报表耦合由 Q5 的边界断言保证**，不是靠约定。

---

## 3. 镜像保真登记

以下三条是 Electron 的**已知形态**，本章照搬，但在此登记，以免将来被当成原生引入的缺陷。

| 编号 | 形态 | 证据锚 | 处置 |
| --- | --- | --- | --- |
| A5 | **锁定行**：由销售/流水导入的明细行复制其来源的已存金额，**不重算**；用户一旦改动数量、单价或税率，该行解锁并转为重算 | `components/DocumentModal.tsx` 的 `ItemRow.locked` 与 `setRow` 的解锁条件 | 照搬。同一张单内可并存「复制来的数」与「算出来的数」，两者舍入来源不同 |
| A6 | **`\|\|` 回退对 0 会跳过**：导入行的单价与金额都走 `a \|\| b` 形的回退链，来源值恰为 0 时会落到后一个候选 | `components/DocumentModal.tsx` 的 `salesToRow` | 照搬。与 F 章「零值/非有限值被静默改写」同族，登记在案 |
| A8 | **表头合计只随明细重算**：`update` 仅当请求带了 `items` 时才重算 `subtotal`/`tax_amount`/`total`；只改表头字段时三个合计保持旧值 | `electron/handlers/documents.js` 的 `update` | 照搬**存储语义**，但见下面的设计约束 |

**设计约束（对 D-1 / D-2 有约束力）**：原生 API **不得开放 A8 的「改了明细却不传 items」路径**。Electron 的前端不会这么调，但它的 handler 允许；原生的写入口必须做到「明细与合计要么一起变、要么都不变」，使 A8 描述的陈旧合计在原生侧**不可达**。这是照搬存储形态、不照搬可达性。

---

## 4. 产品边界与措辞

单据是本 App 里**唯一一类会离开本机、交到客户手上**的产物。因此产品边界不只落在界面上，也必须落在产物里。

Electron 现状在三处一致地表达了同一条边界，原生照此写：

1. **产物页脚**：本单据为内部业务单据，并非正式税务发票。（`components/documentPdf.ts` 的 `DocumentPdfLabels.disclaimer`，模板层不可省。）
2. **功能说明**：本功能只记录外部已开具的正式发票信息，不提供任何开具功能。（`documents.taxInvoiceCompliance`。）
3. **编号提示**：内部编号，可修改；外部发票号码只能手工录入，永不自动生成。（`documents.formNumberHint` 与 `documents.taxInvoiceNumberHint`。）

**措辞纪律**（实测支持）：把 Electron 现有的 `documents.*` 文案共 **87 键 × 6 语言 = 522 条**逐条过 `LocalizationWordingGuardTests` 的两张词表（`filingWords` 22 条、`statutoryStatementNames` 21 条），**命中 0**。扫描前先用已知目标验过图案（词表内的已知词命中、对照句不命中），因此这个 0 不是空图案的产物。

由此得到两条给文案轮的结论：

* 照搬 Electron 的措辞**不会**引入新的 sanctioned 条目，`sanctionedUses` 的 40 条不需要增补。
* 日文与韩文**不走「発票」这条线**（用「税務書類」「세무 증빙」），中文每一处「发票」都带否认句。原生文案沿用这个风格。

---

## 5. 不在本章

以下各项**明确不属于单据章**，实现轮遇到时不得顺手做掉：

| 项 | 为什么不在 |
| --- | --- |
| `invoices.*`（Electron 的 55 键族） | 它是建立在 `transactions` 之上的**另一个视图**（进项/销项发票管理），Electron 里**没有** `invoices` 表。命名近似，勿并入 |
| 客户主数据实体化（原「b-轻」） | Q6 已裁定本章用自由文本；主数据独立推迟 |
| 单据与会计、库存的联动 | Q5 已裁定零联动 |
| 系统打印与其 entitlements 变更 | Q7 已把它登记为后续轮候选 |
| 多币种 | Q8 已裁定隐式本位币 |
| 除 Q2 外的一切发明 | §1 已声明 |

---

## 6. 拆轮表

各轮的**新增测试数与键数是预计，不是承诺**。

| 轮 | 范围 | 验收线 | 预计新增 | 棘轮 / 登记联动 |
| --- | --- | --- | --- | --- |
| **D-0**（本轮） | 把九条裁定落成本文件 | 纯新增一个 `.md`；非 `.md` 变更 0；测试数、键数、黄金全不变 | 0 测试 0 键 | 无 |
| **D-1 存储层** | 按 Q9 甲案读写 v11 既有表；按 Q4 把算式迁入 Core 并逐字复刻 | 建/读/写往返；舍入链与 Electron 逐字节相等（对抗输入含「先舍后乘 ≠ 先乘后舍」的用例）；Q5 边界断言之 1、2 | +25~40 Core | 不涉 pbxproj（Core 包） |
| **D-2 编号与状态机** | Q3 编号；Q5 状态机、编辑白名单、删除规则；A8 设计约束落地 | 状态机闭集反例全覆盖；编号三条反例（跨年 / 删除后重用 / 自定义不污染最大值）；「改行不传 items」路径在原生不可达 | +20~30 Core | 不涉 pbxproj |
| **D-3 六语文案** | `documents.*` 的原生等价键族 | 六语键数同步 650 → 650+N；`LocalizationWordingGuardTests` **零新增 sanctioned**；禁词实跑 | +50~87 键 × 6（预计） | **三处 650 棘轮跨两个目标**：`InventoryCopyTests`（Core）、`LegacyConversionCopyTests`（App）、`ProductCopyTests`（App）。**若新增 App 目标测试文件，须手工登记 pbxproj，恰 4 行/文件** |
| **D-4 视图** | 列表页 + 编辑器 + 明细行 | 新建 `DocumentsView` 与其 composition；**新分区是第 7 个**，须同步撞到的闭集守门与两处分区计数注释 | +30~50 App | `SidebarSection`（`AppModel.swift`）新增一例；`InventoryView` 的「不是本页的五个分区」注释与 `AppModel` 的「六个分区之一」注释同轮改。App 目标新文件须登记 pbxproj |
| **D-5 输出** | Q7 的自包含 HTML 导出 + Powerbox 存盘 | 产物里必然含免责声明（守门断言）；模板对用户文本全量转义（含注入形对抗用例） | +10~25 | 不动 entitlements 闭集（那是后续轮候选） |
| **D-6 激活** | 侧栏可达 + 收尾 | 侧栏入口可达；`LegacyLedgerProbe` 的 `otherRecordTables` 移除 `business_documents` 与 `business_document_items` 两项；`legacy.other.message` 六语改写（现文说「本 App 目前只显示流水」，激活后变假）；`docs/SWIFTUI_FEATURE_GAP.md` §3 该行改状态 | +10~20 | `products` 已有同形先例，其理由写在 `AppModel.swift` 对 `otherRecordTables` 的注释里 |

---

## 7. 本轮实测数字（可复算）

| 项 | 值 | 复算方式 |
| --- | --- | --- |
| `doc_type` 闭集 | 5 | `DOC_TYPES` 与两侧 `CHECK` 子句 |
| `status` 闭集 | 3 | `DOC_STATUSES` 与 `CHECK` 子句 |
| 路由 | 7 | `electron/handlers/router.js` 中 `/api/documents` 前缀的条目 |
| `documents.*` 键 | 87 × 6 = 522 | 六个 `i18n/locales/*.json` 的 `documents` 对象键数 |
| 禁词命中 | 0 | 两张词表 × 522 条，图案先经已知目标自证 |
| Electron 侧断言 | 259 | `scripts/test-handlers.mjs` 的 §2B Batch 8 段内 `ok(` 与 `expectThrow(` 计数 |
| 真 Electron e2e 用例 | 5 | `e2e-electron/documents-attachment-fs.spec.ts` |
| 镜像面 | ≈1813 行 | handler 322 + 前端 1491（`DocumentsPage` 356 + `DocumentModal` 501 + `documentPdf` 160 + `TaxInvoiceModal` 256 + `invoiceStatusDisplay` 42 + `services/api.ts` 单据段 176） |
| 原生写入的表 | 10 张 | `native/SoloLedger/Sources` 下全部 `INSERT` 语句，含唯一一处插值写（它只服务 `transactions` 与 `legacy_migrations`） |

---

## 8. 未裁定，实现轮遇到必须停下来

### Q2-a · 对账单逐行字段映射（**阻塞 D-1**）

Q2 裁定了行来源、匹配条件、日期范围与客户下拉来源，**没有裁定一行流水如何变成一行明细**。Electron 侧的对应物是 `DocumentModal.tsx` 的 `salesToRow`，它从 `sales` 取 `productName` / `quantity` / `unit` / `unitPriceWithoutTax` / `amountWithoutTax` / `taxAmount` / `taxRate`。`transactions` **没有**其中的数量、单位、商品名与单价，只有 `date` / `amount` / `amount_net` / `tax_amount` / `tax_rate` / `counterparty` / `invoice_no` / `description`。

因此至少三件事需要裁定：明细行的**描述**由哪几个字段拼；**数量、单位、单价**留空还是另有取法；**锁定行的金额**取 `amount_net`（与 Q4 的不含税口径一致，但该列可空）还是 `amount`。

### Q2-b · `transactions.tax_rate` 的量纲（**阻塞 D-1**）

实测该列是 `REAL`，写入侧只做 `Number(x) || 0`，**全仓没有任何消费者对它做过归一**（报表读的是 `sales.taxRate` 别名后的同名字段，不是这一列）；原生编辑器也只收一个裸数字。所以「13」还是「0.13」在库里没有约定。而 Q4 的算式吃的是**百分数**（`税率 / 100`），单据的 `tax_rate` 又是 `"13%"` 形的文本。两者之间怎么换算需要裁定。

### Q7-a · 导出文件名与落盘位置

Q7 裁定了产物形态与免责声明，未裁定文件名规则与默认目录。

---

## 9. 修订

本文件只在用户新裁定时修订，且必须同时写清「哪一条从什么改成什么、依据是什么」。实现轮**不得**因为实现困难而反向修改本文件——那种情况的正确动作是停下来要新裁定。
