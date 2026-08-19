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

Q2 的细目（Q2-a 字段映射 / Q2-b 不列税率 / Q2-c 空白规则 / Q2-d 按币种拆单，含 Q2-d-② 币种的持久化）与 Q7-a（文件名与落盘）已分三次裁定完毕，逐条记录见 §9。**本文件自此没有未裁定项，是一份完整的可开工规格。** 唯一的排期依赖是：**D-1 的对账单生成器要等 D-1a（schema v25 加 `currency` 列）合并**。

---

## 2. 逐条确认书

### Q1 · 文档类型半径 = 全 5 照搬

原生支持的 `doc_type` 闭集与 Electron **相等**，恰五个：`quotation` / `sales_order` / `proforma_invoice` / `commercial_invoice` / `statement`。不增、不减、不改名。

* **证据锚**：`electron/handlers/documents.js` 的 `DOC_TYPES`；`electron/db/index.js` 迁移 v11 中 `business_documents.doc_type` 的 `CHECK` 子句；原生 `SchemaMigrator.swift` 同一 v11 级的同名 `CHECK`。三处闭集实测一致。
* **可测断言**：原生的类型闭集常量元素个数 == 5，且逐元素等于上述五个字符串；写入一个不在闭集内的 `doc_type` 必须被拒绝，而不是落库。
* **边界**：Electron 没有「收据」类型，本章也不做；正式税务发票**不是**一种 `doc_type`（它是表头上的四个关联列，见 Q5）。

### Q2 · 对账单生成器改接原生 `transactions`

**这是本章唯一一处对确认书背书的新口径，不是镜像。** Electron 的对账单行来自 `sales` 表；实测原生写入的表是闭集十张（`settings` / `transactions` / `products` / `legacy_migrations` / `inventory_movements` / `inventory_exceptions` / `inventory_balances` / `home_office` / `categories` / `ai_providers`），**`sales` 不在其中**。逐字镜像会得到一个在原生自建账本上永远生成不出任何一行的类型——与资产负债概览章被挂起的形状相同。故改接。

**定位句（须落到产品文案里）**：原生的对账单是**按期间汇总的往来汇总单**，不是逐笔明细发票。它把一段时间内某个客户的收入流水汇总成一张对客户的往来单据；它不描述商品明细，也不是任何一种正式税务文书。

裁定的口径，写成实现轮可以直接照着写断言的形态：

1. **行来源**：`transactions` 中 `type = 'income'` 的行。（`transactions.type` 的 `CHECK` 闭集是 `('income','expense')`，原生 `TransactionType` 枚举同为两例。）
2. **匹配**：`transactions.counterparty` 与单据 `customer_name`，**两侧都先去掉前后空白再精确相等**——不做大小写折叠、不做模糊。
3. **日期范围**：限定在单据自己的期间内，闭区间。（Electron 侧同为闭区间的 ISO 日期字符串比较，见 `generateStatement`；期间由 `business_documents.period_start` / `period_end` 两列承载。）
4. **客户下拉的取值来源**：`transactions.counterparty`，**同样先去掉前后空白**再去重、排序、丢弃空串。
5. **归一只有一处实现**：第 2 条与第 4 条**必须调用同一个归一函数**，不得各写一份。（下拉与筛选若用两套空白规则，同一个名字会既进不了下拉又匹配不上。）
6. **筛选不看币种，因为币种在生成之前就已经把单据拆开了**——见下面的 Q2-d。

#### Q2-a · 逐行字段映射（汇总单形态）

| 明细列 | 取值 |
| --- | --- |
| `description` | `transactions.description`，**可空** |
| `quantity` / `unit` / `unit_price` | **一律留空**（汇总单不描述商品明细；`transactions` 里也没有这三样） |
| `amount` | `COALESCE(amount_net, amount)`——**显式判 `NULL`，不是 falsy 判断**：`amount_net = 0` 必须保留 0，不得回退到 `amount` |
| `tax_amount` | `transactions.tax_amount` |
| `tax_rate` | **不写、不显示**，见 Q2-b |
| `ref_date` | `transactions.date`（Q2-b 的日期列由它渲染） |
| `ref_sales_id` | 来源流水的 `id`（该列的用途本就是「回链到来源记录」，这里换的是来源表不是用途） |

* **空值显示**：金额或税额为空时显示破折号，不显示 0。
* **`COALESCE` 是对 A6 的有意背离，不是疏忽**：§3 登记的 A6 说 Electron 的导入行用 `a || b` 形回退、来源值恰为 0 时会跳过。本条**明确不照搬那个形状**——理由是 A6 是镜像面上的既有形态，而 Q2 是发明面，发明面没有必须复刻缺陷的义务。实测支持：`transactions.amount` 是 `REAL NOT NULL`、`amount_net` 是可空 `REAL`，所以「`NULL` 才回退、`0` 保留」是这两列可以承载的语义。
* **`ref_date` 是被迫的选择不是挑出来的**：明细表 13 列里名字含 `date` 的**只有** `ref_date` 一列，没有第二个日期载体。

#### Q2-b · 不显示税率列

对账单行**只列四样：描述 / 日期 / 税额 / 金额**。不列税率，也不写 `business_document_items.tax_rate`。

* **依据**：`transactions.tax_rate` 是 `REAL`，而**它的量纲在库内没有任何约定**——写入侧只做 `Number(x) || 0`，全仓没有任何消费者对它做过归一，原生编辑器也只收一个裸数字，所以「13」还是「0.13」无从判断。**不把一个没有约定的数字印到交给客户的产物上。**
* **与其它单据类型的差别，登记在案**：其余四种类型沿用六列表（描述 / 数量与单位 / 单价 / 税率 / 税额 / 金额）；对账单是四列的另一套版式。**日期在这里是独立的一列**，而 Electron 是把日期揉进描述串里的（`` `${r.date} ${...}` ``）——这是本条与 Q2-a 一起造成的有意分叉。

#### Q2-c · 空白规则

见上面第 2、4、5 条。**可测断言**：对同时含 `" Acme "` 与 `"Acme"` 两种写法的流水，①客户下拉里 `Acme` 只出现一次；②选中它之后，两种写法的流水**全部**进入结果集；③下拉集合与筛选谓词对这两个字符串的判断**逐个一致**。

* **依据**：Electron 侧两处都 trim（`stmtCustomers` 与 `generateStatement`），本条等价于它的语义。
* **边界**：**不碰流水的写入路径**。原生 `Transaction.normalized()` 只做 `prefix(200)` 截断、不 trim，本条不改它——归一发生在读取与比较时，不发生在入库时。

#### Q2-d · 跨币种：按币种拆多张单

同一客户、同一期间内若存在 **N 个币种**的收入流水，则生成 **N 张对账单**，每张只含单一币种的行。

> **如实记录：这是用户在四个选项中的选择，不是本文件的推荐项。** 另三个选项分别是「只取本位币、其余静默排除」「同前但如实告知被排除的行数与币种」「多币种时拒绝生成」。

这条裁定带三条写死的后果：

**① 编号一次消耗 N 个。** 拆出 N 张单就要连发 N 个 `ST` 编号，`ST` 序号一次前进 N 位。（`nextNumber` 每次只算「当前最大 +1」，没有批量预留，所以 N 张单是 N 次取号；跳号规则见 Q3。）

**② 拆出来的单据必须记得自己的币种。** 处置见紧接着的 Q2-d-② 小节。

**③ 这是 Q2 发明的扩大，张力已经用一个独立轮解决，而不是被压住。** Q8 原本说单据没有币种列、显示币种一律由 `acc_locale` 推导；Q9 原本说不建新表不加列。本条要求单据能表达「我不是本位币」，两边确实冲突——**处置是把加列拆成 D-1a 这个独立的 schema 轮**（见 §6），而不是在实现轮里顺手加、也不是让币种寄生在别的字段上。Q8 与 Q9 的正文已按此各自加了一条例外，措辞见那两节。

#### Q2-d-② · 币种的持久化 = 加一个 `currency` 列（走 D-1a 小轮）

原来的 24 列里没有币种列，13 列的明细表里也没有，所以拆出来的非本位币单据存盘后**没有任何结构化字段记得自己是哪个币种**。**裁定：不再往既有文本字段里塞标记，而是新设 D-1a 小轮给 `business_documents` 加一个可空的 `currency TEXT` 列。**

| 项 | 裁定 |
| --- | --- |
| 落点 | 原生 schema **v25** 级，`ALTER TABLE business_documents ADD COLUMN currency TEXT` |
| 可空 | 是 |
| `NULL` 的含义 | **沿 Q8 按 `acc_locale` 推导**——全部既有单据与全部非对账单类型的行为**一个字都不变** |
| 非 `NULL` 的含义 | 页眉 / UI 徽标 / 金额符号**三处一律按该列渲染**（这是 Q8 那条例外句的生效载体） |
| 首版写入者 | **只有对账单生成器**：Q2-d 拆单时逐张写入该单自己的币种。其余四种类型、以及手工新建的单据，一律不写，保持 `NULL` |
| 格式约束 | **不设 `CHECK`**，照搬 `transactions.currency` 的宽松形态 |

* **「宽松形态」是有实测边界的说法**：本仓的 `currency` 列**没有一个带 `CHECK`**——`transactions.currency` 是 `TEXT NOT NULL DEFAULT 'CNY'`，`accounts` / `liabilities` 上的是裸 `TEXT`。本列在「无 `CHECK`」上照搬全仓通例；在**可空**这一点上同 `accounts.currency` 而**不同于** `transactions.currency`，因为 `NULL` 在这里是一个有意义的取值（= 按 `acc_locale` 推导），不是缺失。
* **另两个选项为什么落选**（两条理由都是本轮实测出来的，不是推测）：
  * **`notes`**——它**在 `EDITABLE` 白名单里（用户可改）且印在产物上**（`notesBlock`）。用户改一次备注就能把标记删掉，标记一没，金额符号按 Q8 回落到 `acc_locale`：一张全是外币的对账单会被**静默换上本位币符号**印给客户。
  * **`source_sales_id`**——技术上够用（不在 `EDITABLE`、不印产物、对账单侧本就恒 `NULL`），但**列名说谎**：一个叫「来源销售记录 id」的列里装着 `USD`，还会原样进 CSV 导出交到会计师手里。

* **证据锚**：`components/DocumentModal.tsx` 的 `generateStatement` / `stmtCustomers` / `salesToRow`；`electron/db/index.js` 迁移 v5 中 `transactions` 的 `type` `CHECK` 与 `counterparty` 列；原生 `Enums.swift` 的 `TransactionType`；原生 `LedgerStore.swift` 的 `INSERT INTO transactions`。
* **可测断言**（D-1/D-2 应各自落成测试）：给定一组含 `income` 与 `expense`、多个 `counterparty`、跨越期间边界的流水，生成器返回的行集恰等于「`income` ∧ `counterparty` 相等 ∧ 日期在闭区间内」的那一组；边界两天必须包含；`expense` 行必须不出现；`counterparty` 不等的行必须不出现。
* **可测断言（Q2-a/b/c 部分）**：`amount_net = 0` 的流水，其明细行金额是 **0** 而不是 `amount`；`amount_net IS NULL` 的流水，其明细行金额是 `amount`；`tax_amount` 为空的行显示破折号而不是 `0`；生成出的明细行的 `tax_rate` **一律为空**。
* **未裁定的残余：无。** Q2-a / Q2-b / Q2-c / Q2-d（含 ②）全部已裁定。**D-1 的对账单部分的开工条件 = D-1a 合并**（见 §6），因为生成器要写的那一列要先存在。

### Q3 · 单据编号 = 全部照搬

| 项 | 裁定 |
| --- | --- |
| 格式 | `<前缀>-<年>-<4 位序号>` |
| 前缀表 | `quotation`→`QT`、`sales_order`→`SO`、`proforma_invoice`→`PI`、`commercial_invoice`→`CI`、`statement`→`ST` |
| 年度 | 按年重置（年份在编号里） |
| 连续性 | **不保证连续**，跳号是正常状态。**只有删除会释放号码**：删掉的行不再占用 `(doc_type, doc_number)`，也不再参与序号最大值的计算。**作废不释放**——作废只把行的 `status` 改成 `void`，行还在，唯一索引仍然约束它，`nextNumber` 也不排除它，所以那个号码既不能被手工重用，也仍然把序号顶上去 |
| 可编辑性 | 自动值只是**建议**，用户可改 |
| 年份来源 | 本地时区的当前年 |
| 唯一性 | 仅 `(doc_type, doc_number)` 唯一——同一编号可在五种类型里各存在一次 |
| 批量取号 | 没有批量预留。**Q2-d 的按币种拆单会一次消耗 N 个 `ST` 号**：N 张单就是 N 次取号，`ST` 序号一次前进 N 位 |

* **证据锚**：`electron/handlers/documents.js` 的 `nextNumber` 与 `NUMBER_PREFIX`；同文件的 `runGuardingNumberConflict`（唯一索引冲突翻成稳定错误码 `DOC_NUMBER_EXISTS`）；`electron/db/index.js` 迁移 v11 的 `idx_docs_type_number` 唯一索引；`components/DocumentModal.tsx` 中用户改号后停止自动跟随的 `numberEditedRef`。
* **可测断言**：空库取号得 `<前缀>-<年>-0001`；建一张 `QT-<年>-0007` 后再取号得 `QT-<年>-0008`；**自定义编号不污染序号最大值**（Electron 侧已有同名断言，实测在 `scripts/test-handlers.mjs` 的 §2B Batch 8 内）；同一 `(类型, 编号)` 第二次写入被拒绝，不同类型同编号可写入；**作废一张单之后，用同一编号新建仍被拒绝，且下一个自动号不回退**；把那张单删除之后，同一编号可以再次写入。
* **证据（作废不释放）**：`nextNumber` 的取数语句只按 `doc_type` 与 `doc_number LIKE` 过滤，**没有 status 条件**；`idx_docs_type_number` 是普通唯一索引、**不带 `WHERE` 子句**（不是部分索引）；`update` 作废时只写 `status`，不动 `doc_number`。三处实测。
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
**编辑**：仅 `draft` 可改字段与明细。**对账单（`statement`）是例外：只可改表头字段，明细只读**——见下面「对账单的编辑语义」。
**删除**：`issued` 不可直接删除（必须先作废）；`draft` 与 `void` 可删除。
**联动**：**签发不落流水、不扣库存、不进任何报表。**

* **证据锚**：`electron/handlers/documents.js` 的 `STATUS_TRANSITIONS`、`DOC_STATUSES`、`update` 中的 `EDITABLE` 白名单、`remove` 中对 `issued` 的拦截（稳定错误码 `DOC_ISSUED_VOID_FIRST`）。
* **边界断言（实现轮必须落成测试）**：
  1. 原生报表引擎对 `business_documents` 与 `business_document_items` **零读**。实测依据：`electron/reports/` 下 `FROM <表>` 的闭集是 `transactions` / `sqlite_master` / `settings` / `sales` / `purchases` / `categories` 六张，单据两表一次不出现（该图案在同一次扫描中命中了六张真表，故不是空图案）。
  2. 原生库存引擎对单据两表零读、零写。
  3. 单据的任何状态流转都不产生 `transactions` 行、不产生库存流水行。

#### Q5-a · 对账单的编辑语义 = 表头可改，明细只读（第七次裁定）

对账单在编辑器里**可以打开、可以改表头字段**（编号 / 日期 / 客户 / 税号 / 地址 / 联系方式 / 有效期 / 备注），
但**明细只呈现、永不回传**：写入 API 收到的编辑请求对 `statement` 一律不携带 `lines`。
**要改明细，只能删掉这张单据重新生成。**

* **为什么收窄而不是照搬**：Electron 的 draft 对账单明细完全可改，重存时走同一套无模式的 `sanitizeItems`。
  原生照搬会同时吃下两个后果，两个都落在交给客户的产物上：
  1. **丢行丢钱**——`sanitizeItems` 把描述为空的行整行丢弃，而 Q2-a 明文允许生成的对账单行描述为空
     （D-1 第一条裁定），于是一笔真实的 income 流水连同它的金额从单据上消失，表头三合计在同一事务里跟着变小；
  2. **`NULL` 税额被压成 0**——`sanitizeItems` 的 `round2` 回退是 `0`，压完之后 Q2-a 的
     「空值显示破折号」永远不可达。
* **两个后果的判据不对称，登记在案**：后果 1 在 Electron 里**可达**（用户手动清空某行描述即触发，见 §3 A12），
  后果 2 在 Electron 里**连规则都不存在**（`business_document_items.tax_amount` 可空，但 `sanitizeItems` 的
  `num()` 回退让 create/update 两条路都写不出 `NULL`）。所以后果 2 **不得引「Electron 就是这么做的」当依据**。
* **依据**：`statement` 属 Q2 的发明面，发明面的编辑语义可以收窄；其余四种类型的编辑一个字不变。
* **可测断言**：对 `statement` 构造的编辑请求，其 `lines` 恒为「不改」；对其余四种类型，`lines` 照常携带。
  **创建**一张对账单只有生成器一条路（编辑器在该形态下不提供保存动作），这是「删掉重新生成」这句话的另一半。

* **正式税务发票关联**：`tax_invoice_issued` / `_number` / `_date` / `_attachment_path` 四列**只记录外部已开具的发票信息**，号码只能手工录入，**永不自动生成**；`void` 单据上该关联为只读。证据锚：`electron/handlers/documents.js` 的 `updateTaxInvoice`（稳定错误码 `DOC_VOID_TAX_INVOICE_READONLY`、`ATTACHMENT_IN_USE`、`INVALID_ATTACHMENT_PATH`）。

### Q6 · 客户字段 = 自由文本照搬

单据的客户是自由文本 `customer_name`，外加三个可选文本 `customer_tax_id` / `customer_address` / `customer_contact`。**本章不建客户主数据表。**

* **证据锚**：`electron/db/index.js` 迁移 v11 的四列；`docs/SWIFTUI_FEATURE_GAP.md` §3「客户 / 供应商」行（🟡，`counterparty` 为自由文本）。
* **登记**：实测 Electron 内并存**三个互不相通的客户自由文本命名空间**——`transactions.counterparty`、`sales.customer` / `purchases.supplier`、`business_documents.customer_name`。原生只写第一个。Q2 的客户下拉因此取 `transactions.counterparty`。
* **不属本章**：客户主数据实体化（原「b-轻」）继续独立推迟，见 §5。

### Q7 · 输出 = 首版导出自包含 HTML

* **首版形态**：导出一份**自包含 HTML 文件**（样式内联、无外部资源、用户文本全量转义），经 Powerbox 存盘。
* **模板语义镜像 Electron**：抬头（公司名 + 可选税号/地址/负责人）、单据 meta 行（编号 / 日期 / 可选有效期 / 对账期间）、客户块、明细表（描述 / 数量与单位 / 单价 / 税率 / 税额 / 金额六列）、合计三行（小计 / 税额 / 总计）、备注块、页脚。
* **对账单是唯一的模板变体（第九次裁定）**：它的明细表出**四列**——描述 / 日期 / 税额 / 金额——**不出税率**，且**日期是独立的一列**，取自 `business_document_items.ref_date`。这与 Q2-b 在屏幕侧定的是同一条口径：Electron 把日期揉进描述串（`salesToRow` 的前缀 `` `${r.date} ${...}` ``），原生把它拿掉了，所以在产物里照抄六列会把日期整个丢掉。**其余四种类型仍是六列。** 实测：Electron 对一张原生形状的对账单出的是六列、其中三列全空、日期在描述格里。
* **抬头在原生只出公司名**：`SettingsStore` 只有 `company_name`，没有 Electron 的 `company_info` 三字段，`.cmeta` 那一行恒空——登记为 **B5**，不为它加设置项。
* **页眉的币种行（第九次裁定）**：`business_documents.currency` 非 `NULL` 时，产物页眉多出一行「币种: <代码>」（`documents.print.currency`）；为 `NULL` 时**该行不出现**，产物在这一处与 Electron 逐字节相同。这是 Q8 例外在产物面的第四处延伸，见 Q8。
* **页脚免责声明必须在产物内**，不是只在界面上；后续轮把「产物里必然含免责声明」写成守门断言。
* **系统打印**（`NSPrintOperation` 路线）登记为**后续轮候选**：它需要动 2c-7 已经钉死的 entitlements 闭集，属另行裁定。
* **`WKWebView` 路线否决**：与 #483 钉住的「无网络」能力守门冲突。

* **证据锚**：`components/documentPdf.ts` 的 `buildDocumentHtml` / `escapeHtml` / `cjkFonts` 与 `DocumentPdfLabels.disclaimer`；`electron/handlers/index.js` 的 `app:exportReportPdf`（Electron 用隐藏 `BrowserWindow` + `printToPDF` 出 PDF，原生无此栈）；`native/SoloLedger/Tests/SoloLedgerCoreTests/CapabilityImportGuardTests.swift`（能力闭集守门）。
* **收窄说明**：Electron 一键出 PDF，原生首版出 HTML。**这是一处功能收窄，文案必须说清**，不得让用户以为拿到的是 PDF。

#### Q7-a · 文件名与落盘位置

* **文件名** = `<doc_number>.html`，其中 `doc_number` 里对文件系统非法的字符要先转义。
* **转义函数（第九次裁定）= 照抄 Electron 的那一个**：`docNumber.replace(/[\\/:*?"<>|\s]+/g, '_')`（连续的非法字符与空白折成一个下划线），结果为空串时**回落到单据 `id`**。与 Electron 的两处差别都由 Q7-a 正文定过、不再重复：**不带 `SoloLedger-` 前缀**，扩展名是 `.html` 而不是 `.pdf`。
* **落盘位置** = Powerbox 用户自选，**没有默认目录**，也不自建目录。
* **登记的已知形态（文件名不保证唯一）**：编号的唯一性是 `(doc_type, doc_number)` 上的，**不是 `doc_number` 单列上的**——实测既有守门就断言着同一个 `DUP-1` 可以在 `quotation` 与 `sales_order` 上各存在一次。所以两张不同类型、同编号的单据导出到同一个目录会得到同一个文件名。**这不是静默覆盖**：落盘走 Powerbox 存盘面板，重名由系统面板提示用户；但「文件名唯一」这句话不成立，故在此登记而不是当成保证。

#### Q7-b · 验收线（第九次裁定）

Q9 的验收线是「同输入下结果与 Electron 逐字节相等」。产物面上它有一个**能成立的定义域**，因为下面每一条
登记的分叉都会让某一类样本永远不可能相等；把边界写下来，比让一条永远为真不了的断言挂在那里诚实。

* **逐字节相等的定义域** = **非对账单** + `currency IS NULL` + **CN 制度** + **注入固定的 `generatedAt`**。
  这个交集里的产物必须与 `components/documentPdf.ts` 的 `buildDocumentHtml` 输出**逐字节相等**。
* **黄金**：六语各一份，由 node 经 `scripts/_ts-resolver.mjs` 直接 import 真模板生成，**提交进仓**。
  放**独立目录、配独立的再生成校验**；**不得进冻结的报表黄金目录**，其变更**不得**使用行首
  `Allowed-Golden-Changes` 通道。
* **定义域之外**：R1–R6 每一处分叉**各钉一条只钉它的测试**（D-3 判例 47：规格里凡写着「有意分叉」的地方，
  都要有一条只钉那处分叉的测试，否则实现可以悄悄把它改回去）。

### Q8 · 币种 = 照搬隐式本位币

单据**没有币种列**。显示币种由单据创建时冻结的 `acc_locale` 推导；`JPY` / `KRW` 显示 0 位小数，其余 2 位。不可选、不可改、不做换算、不做合计跨币种。

* **证据锚**：`electron/db/index.js` 迁移 v11（`business_documents` 无 currency 列，有 `acc_locale`）；`components/accountingHelpers.ts` 的 `formatMoney`；`electron/handlers/documents.js` 的 `resolveAccLocale`（创建时解析、`update` 忽略）。
* **可测断言**：同一张单据在设置切换会计制度后，显示币种不变——因为读的是行上冻结的 `acc_locale`，不是当前设置。
* **第四处延伸（第九次裁定，载体 = 导出产物）**：`currency` 非 `NULL` 时，**导出产物的页眉也出一行「币种: <代码>」**（`documents.print.currency`）。出的是**代码不是符号**，与下面那条例外在金额符号一侧的做法同源——本仓没有 code→symbol 表，`ReportFormat` 早已写明不借 OS 的。`currency` 为 `NULL` 时该行不出现。
* **一处显式例外（Q2-d 造成，载体已定）**：**`business_documents.currency` 非 `NULL` 时，页眉、UI 徽标与金额符号三处一律按该列渲染，不按 `acc_locale` 推导。** `currency` 为 `NULL` 时本条正文原样成立。该列由 D-1a 加入（Q2-d-②），首版只有对账单生成器写它，所以其余四种类型与全部既有单据都落在 `NULL` 分支上、行为不变。

### Q9 · 存储 = 甲案（写 v11 既有表），计算迁入 Core 但逐字复刻

* **不建新表、不加列，唯一例外 = D-1a 的 `currency` 列。** 原生写 `SchemaMigrator` v11 级已经建好的 `business_documents` 与 `business_document_items`；金额列保持 `REAL`，`tax_rate` 保持 `TEXT`；除了 Q2-d-② 裁定的那一个可空 `currency TEXT`（v25，见 §6 的 D-1a），不再加任何列，也不建任何新表。
* **这条例外的依据与影响面**（三条都是实测，不是推断）：
  1. **Electron 侧的读写不受影响。** `electron/handlers/documents.js` 对 `business_documents` 的读全部走显式列清单 `HEADER_COLUMNS`，写走显式列名的 `INSERT`，`UPDATE` 逐字段拼 `SET`——**该文件里 `SELECT * FROM business_documents` 出现 0 次**（而 `SELECT * FROM` 在 `electron/` 全树有 20 处，所以这个 0 是有判别力的）。多一列它看不见，也不会写坏。
  2. **有一处输出形状会变，如实登记：CSV 导出。** `electron/handlers/_csvExport.js` 的 `tableToCsv` 用 `PRAGMA table_info` 取列、`SELECT *` 取行（它的注释自述「列序与 schema 一致」），所以 Electron 打开一个 v25 账本再导出 `documents` 表时，CSV **会多出一列 `currency`**。这不是破坏，是它设计上就跟随 schema；但「导出列不变」这句话不成立，故写在这里。
  3. **单向性仍然是约定不是强制，v25 不改变这一点。** `SchemaMigrator` 的文件头自述：一个 v24 账本不会被 Electron 拒绝，它的 `runMigrations` 循环跑零次、照常读写 v23 的表；单向性「是一条约定，不是一种强制」，声明在 `docs/SWIFTUI_FEATURE_GAP.md` §4。v25 落在同一条 `nativeOnlyVersions` 序列上，性质一样。
* **计算位置从界面迁到 Core。** Electron 的行金额与行税额由前端算、后端只求和；原生把算式放进 Core，**但算式与舍入链逐字复刻 Electron 前端**。
* **验收 = 同输入下结果与 Electron 逐字节相等。**

* **证据锚**：原生 `SchemaMigrator.swift` 的 v11 级（与 `electron/db/index.js` 同级 DDL 实测同构：同列、同 `CHECK`、同索引、同外键）；`electron/handlers/documents.js` 的 `sumTotals`（注释自述「只求和、不重算行金额」）；`components/DocumentModal.tsx` 的 `computed`。
* **两条必须写进设计的分域声明**：
  1. **单据金额域与 N 章库存的整数分域不互通。** 单据用 `Double` + `REAL`，库存用整数分；两者之间没有任何数值流动，也不允许有。
  2. **零报表耦合由 Q5 的边界断言保证**，不是靠约定。

---

## 3. 镜像保真登记

以下**七条**是 Electron 的**已知形态**，本章照搬，但在此登记，以免将来被当成原生引入的缺陷。

| 编号 | 形态 | 证据锚 | 处置 |
| --- | --- | --- | --- |
| A5 | **锁定行**：由销售/流水导入的明细行复制其来源的已存金额，**不重算**；用户一旦改动数量、单价或税率，该行解锁并转为重算 | `components/DocumentModal.tsx` 的 `ItemRow.locked` 与 `setRow` 的解锁条件 | 照搬。同一张单内可并存「复制来的数」与「算出来的数」，两者舍入来源不同 |
| A6 | **`\|\|` 回退对 0 会跳过**：导入行的单价与金额都走 `a \|\| b` 形的回退链，来源值恰为 0 时会落到后一个候选 | `components/DocumentModal.tsx` 的 `salesToRow` | 照搬。与 F 章「零值/非有限值被静默改写」同族，登记在案 |
| A8 | **表头合计只随明细重算**：`update` 仅当请求带了 `items` 时才重算 `subtotal`/`tax_amount`/`total`；只改表头字段时三个合计保持旧值 | `electron/handlers/documents.js` 的 `update` | 照搬**存储语义**，但见下面的设计约束 |
| A9 | **`update` 的状态读在事务之外**：先无事务地读出 `status`，在 JS 里判完草稿规则与状态机，随后才开事务写。读与写之间存在窗口 | `electron/handlers/documents.js` 的 `update`：`const existing = db.prepare('SELECT id, status …').get(id)` 在函数顶部，`db.transaction(…)` 只包住 `UPDATE`／明细重写 | 照搬。见下面的**并发窗口三条**与升级条款 |
| A10 | **`remove` 全程无事务**：读 `status` 与附件路径 → 判 `issued` → `DELETE` → best-effort 删附件，四步各自独立 | 同文件 `remove`：整个函数内**没有** `db.transaction` | 照搬。见下面的**并发窗口三条**与升级条款 |
| A11 | **`updateTaxInvoice` 全程无事务**：读 `status` 与既有路径 → 判 `void` → 查附件是否被别的单据占用 → `UPDATE` → best-effort 删旧副本，五步各自独立 | 同文件 `updateTaxInvoice`：整个函数内**没有** `db.transaction`；占用查询是独立的 `SELECT 1 … AND id != ?` | 照搬。见下面的**并发窗口三条**与升级条款 |
| A12 | **手工清空一行的描述会静默丢掉这一行连同它的金额**：编辑器提交前先 `.filter(r => r.description.trim())`，服务端 `sanitizeItems` 再滤一次，表头三合计按剩余行重算。全程无提示、无确认、无「已丢弃 N 行」 | `components/DocumentModal.tsx` 的 `handleSubmit`；`electron/handlers/documents.js` 的 `sanitizeItems` | 照搬。**这是既有形态，与 Q5-a 无关**：Q5-a 挡住的是「生成的对账单行天然带空描述」那一子情形，本条是用户自己清空的那一条，两侧都可达。要让原生不复刻它，是另一个独立裁定 |

**设计约束（对 D-1 / D-2 有约束力）**：原生 API **不得开放 A8 的「改了明细却不传 items」路径**。Electron 的前端不会这么调，但它的 handler 允许；原生的写入口必须做到「明细与合计要么一起变、要么都不变」，使 A8 描述的陈旧合计在原生侧**不可达**。这是照搬存储形态、不照搬可达性。

### 并发窗口三条（A9 / A10 / A11）的登记依据与升级条款

A9–A11 是同一个形态的三处实例：**check-then-act**——先读状态（或读「附件没被占用」），在宿主语言里判断，再写。两次操作之间没有任何东西阻止**另一个连接**把被判断的那个事实改掉。三条各自的最坏后果是：草稿规则被绕过（读到 `draft`，另一连接签发，本连接仍写字段）、刚签发的单据被删除、刚作废的单据仍被改发票关联、以及同一个附件被两张单据同时声明。

登记而不是当场修，依据是三条实测：

1. **Electron 同形，逐字段对得上。** 三处窗口不是原生引入的：`update` 的状态读在事务外（better-sqlite3 的 `db.transaction` 默认发的是 DEFERRED `BEGIN`，且它只包住写）；`remove` 与 `updateTaxInvoice` **零事务**。Q9 的验收线是「同输入下结果与 Electron 逐字节相等」，原生在这三处是忠实照搬。
2. **原生当前实害不可达，且这是量出来的不是推出来的。** 前提有三条：①App 是单进程、单 `LedgerStore` 连接，写入经主 actor 串行化；②`Sources/SoloLedgerCore/Documents/` 下文件系统调用数 **0**（同一图案在 `SelfTest` / `Support` / `BackupRestore` / `AttachmentApply` 会命中，所以这个 0 是测量不是空图案）；③`deleteBusinessDocument` / `updateTaxInvoice` 回传的孤儿附件路径，在 App 目标里消费者数 **0**。合起来：A11 最响的那个后果——「删掉另一张单据还在引用的文件」——在原生**没有任何东西会去删**。
3. **修法只有两条路，都越界。** 加数据库级唯一约束 = 改 schema，Q9 明禁「不建新表、不加列」（唯一例外是 D-1a 的 `currency` 列）；改成条件 `UPDATE … WHERE status = ?` + 校验受影响行数、或 `BEGIN IMMEDIATE`，则是**有意偏离镜像**，§1 明禁。两者都必须走用户裁定，而不是实现轮自行择定。

> **升级条款（自动生效，不需要再裁定一次）**：一旦引入下列任一路径，本登记**自动从「已知形态」升级为「必修项」，且必须先修后接**——
>
> * **多连接并发写**：任何让第二个连接（第二个进程、第二个 `LedgerStore`、后台写入队列、与旧 Electron 同时写同一账本的支持路径）能写这两张表的改动；
> * **附件删除**：任何真的会删掉 `attachments/docs/` 下文件的代码路径，无论它消费的是本章回传的孤儿路径，还是自己算出来的。
>
> 「先修后接」的意思是：修复（条件写 + 受影响行数校验，见 §5 的候选轮）必须先落地并通过反向证明，那条新路径才允许接上去。触发时**不需要重新裁定要不要修**，只需要裁定怎么修。

### D-4 的一处有意不镜像：附件副本只进不出（第七次裁定）

Electron 的关联面板有**三条真正会删文件的路径**：`app:discardDocAttachment`（重选 / 移除未保存副本 / 取消时清理，
经 `attachments.js` 的 `safeDeleteAttachment` → `fs.rmSync`）、`updateTaxInvoice` 替换关联后删旧副本、
`remove` 删单据后删附件。

**裁定：D-4 只做「选文件 / 打开 / 保存关联」，一条删除路径都不接。** 重选、移除、取消一律只改状态，
不动磁盘；`updateTaxInvoice` 与 `deleteBusinessDocument` 回传的孤儿路径在 App 侧被显式丢弃。

* **代价，如实登记**：`attachments/docs/` 下会留下无人引用的副本。这是一处**静默磁盘泄漏**，不是遗漏。
* **为什么不能顺手做掉**：上面的「升级条款」把「任何真的会删掉 `attachments/docs/` 下文件的代码路径」
  写成了 A9–A11 的自动触发器。接上删除 = 触发条款 = 三处 check-then-act **必须先修后接**。
  而 `discardDocAttachment` 自己就是 A11 的形状（先 `SELECT 1 … LIMIT 1` 查引用，再删），
  逐字镜像等于把条款要防的那条竞态原样搬进来。
* **排期（同一次裁定）**：**存储原子化轮插在 D-5 之后、D-6 之前**（范围见 §5）；
  **D-6 激活时接上删除接缝**。在原子化轮落地之前，任何轮次都不得接删除。
* **接缝是单点的**：App 侧消费那两个回传值的地方各恰一处，都在页面模型里，都只是把值丢掉。

### B 系列：原生这一侧的有意差异（第八 / 第九次裁定）

上面那张表是 **A 系列**，它的表头写的是「Electron 的**已知形态**，本章照搬」。下面这些**不是那种东西**：
它们是原生这一侧与 Electron 之间的**有意差异**，方向相反——照搬的是别人的形态，这里记的是「本仓给不出
同一个东西」或「本仓有意给了另一个形状」。两者不该共用一个编号命名空间，故另编 **B 系列**。

**B1 / B2（第八次裁定，D-4）的共同性质：都到不了账本。** 输入侧由 `DocumentPageComposition.numberInput`
净化字符，提交侧由 `DocumentPageComposition.NumberConstraint.accepts` 按 HTML 的 valid floating-point
number 文法再判一次，两道都过不去。差异只存在于「字段正在被编辑」这一段时间里。

**B3–B7（第九次裁定，D-5）都在产物面上**，其中 B4 是 D-3/D-4 就已发生、此前一直没登记的那一处。
按 Q7-b，它们每一条都要有一条**只钉它自己**的测试；逐字节相等的定义域也是因为它们才需要写下来。

| 编号 | 形态 | 证据锚 | 处置 |
| --- | --- | --- | --- |
| B1 | **粘贴 `1a2`**：浏览器把字段清空，原生留下 `12`。两边都提交不了 `1a2`。逐字（英文原文即证据锚本身）：*PASTING `1a2` clears the field in a browser and leaves `12` here. Both are unsubmittable-as-`1a2`, which is the property that matters.* | `native/SoloLedger/Sources/SoloLedger/App/DocumentPageComposition.swift` 的 `numberInput(_:)` 文档注释，「**Two registered differences**」第一条 | **登记级，不改。** 要抹平它得让原生的字符净化在遇到一个非法字符时清空整个字段，那会连带把「半打的值」一起清掉——见 B2 的同一处注释 |
| B2 | **半打的 `1.`**：对面是 `badInput`，绑定态因此变成 `''`，**它的合计把那一行读成 0**，而字段仍显示 `1.`；原生文本留 `1.`，合计按 `parseFloat` 读成 1。两边都拒绝提交，两个合计只在字段没打完时不同。逐字（英文原文即证据锚本身）：*A half-typed `1.` is `badInput` over there, which makes the bound state `''` — so its running total reads that line as 0 while the field still shows `1.`. Here the text stays `1.` and the total reads it as 1, through the same `parseFloat` D-1 pinned. Both refuse the submit (see ``NumberConstraint/accepts(_:)``); the two totals disagree only while the field is unfinished.* | 同一处注释第二条；提交侧的判据在同文件 `NumberConstraint.accepts(_:)` | **登记级，不改。** 要抹平它得让原生合计对「不是合法浮点字面量」的文本读 0，那是改 D-1 钉住的编辑期读数口径（`DocumentMath.editorNumber` 是 `parseFloat`，两侧同一个函数），属另一个裁定，不在本章已裁定的范围内 |
| B3 | **产物的税相关标签不随会计制度变**：Electron 的产物按 `getTaxLabel(acc_locale, uiLang, …)` 取 `formTaxRate` / `headerTaxAmount` / `headerTotalWithTax`（非 CN 制度下是「Sales Tax Rate」「消費税率」这类制度自己的说法）；原生产物沿用屏幕已在用的固定键 `documents.item.taxRate` / `documents.item.taxAmount` / `documents.total.*` | `components/accountingLocaleConfig.ts` 的 `formTaxRate` / `headerTaxAmount` / `headerTotalWithTax` 三个概念；原生 `AccountingProfile` 只有 `taxLabel` 与 `surchargeLabel` | **登记，不改。** 把那张概念表搬进原生等于动 accounting profiles，`CLAUDE.md` 把它列为需要显式批准的红线；而只补三个概念同样是 profile 改动。**零制度化标签概念进原生**是第九次裁定的原话 |
| B4 | **屏幕侧同一处分叉，D-3/D-4 就已发生**：单据编辑器的税率列表头，Electron 是 `taxLabel('formTaxRate')`，原生是六语恒为「税率」的 `documents.item.taxRate`；税额与总计表头同理（Electron 非 CN 走 `headerTaxAmount` / `headerTotalWithTax`） | `components/DocumentModal.tsx` 的 `taxLabel('formTaxRate')` 与 `taxAmountLabel`；原生 `DocumentPageComposition` 的 `taxRateKey` / `taxAmountKey` | **补登记，不改。** 这一条**不是 D-5 造成的**——它在 D-3 写文案、D-4 画表时就已经这样，只是此前规格里零登记（`formTaxRate` / `taxLabel` 在本文件中此前零命中）。产物与屏幕保持同一套标签，是 B3 成立的前提 |
| B5 | **抬头只出公司名**：Electron 的产物抬头出 `company_info` 的名称 + 税号 / 地址 / 负责人三个可选小字；原生只出 `company_name`，其余传空，`.cmeta` 那一行恒不出现 | `components/documentPdf.ts` 的 `companyMeta`；原生 `SettingsStore.Key` 只有 `companyName`，无 `company_info` | **登记，不改。** 为产物加三个设置项是本章之外的事 |
| B6 | **生成时间的格式**：Electron 是 `new Date().toLocaleString(uiLang)`（宿主 ICU 的本地化串，随语言与地区变，没有固定格式契约）；原生固定为 **ISO-8601 UTC**，且 `now` 可注入 | `components/DocumentsPage.tsx` 的 `generatedAt: new Date().toLocaleString(uiLang)` | **登记，不改。** 逐字端口一个没有稳定契约的格式，钉不住也测不动；可注入的 `now` 正是 Q7-b 逐字节定义域能成立的前提 |
| B7 | **产物里的语言码是 Electron 的**：`<html lang>` 与 CJK 字体族的挑选键出 `zh-CN` / `zh-TW`，不是原生自己的 `zh-Hans` / `zh-Hant`；其余四语两侧同码 | `components/documentPdf.ts` 的 `cjkFonts(lang)` 与 `<html lang="${e(L.lang)}">`；原生语言码见 `Localizer.swift` | **有意映射，登记。** 出原生码会同时改掉字体回落与产物字节；映射只此一处、只在产物边界上发生 |

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
| **存储原子化**（下详） | 与 Electron 同形的已知形态，登记在 §3 A9–A11；修它必然越过 Q9 或 §1，属独立候选轮 |
| 除 Q2 外的一切发明 | §1 已声明 |

**候选轮：存储原子化（排期已定：D-5 之后、D-6 之前——第七次裁定）**

范围两件事，绑在一起是因为它们是同一类问题（判据写在宿主语言里而不是写在写语句里）：

1. **三处 check-then-act 收口**（§3 A9 / A10 / A11）：`update` / `deleteBusinessDocument` / `updateTaxInvoice` 改成把被判断的事实写进谓词的**条件写**（`… WHERE id = ? AND status = ?`）并**校验受影响行数**，行数为 0 时给出与今天同一个稳定错误码。**不改 schema**——这是与「加唯一约束」那条路的分野。附件归属那一处同理：把「没被别人占用」并进写语句的谓词。
2. **`ProductCatalog.mapWriteFailure` 的 `(code 19)` 谓词修正**：D-2 实测坐实它在出货连接上一条也匹配不到——`activeExistingNoFollow` 带 `SQLITE_OPEN_EXRESCODE`，同一条唯一索引冲突报的是 `(code 2067)`（PK/NOT NULL/FK/CHECK 分别 1555/1299/787/275，**主码全是 19**）。改法与 D-2 的 `mappingConstraintToNumberExists` 同形：判主结果码。属库存页，D-2 不越界修，只留证据。

3. **附件的安全删除**：把 D-4 登记的那条泄漏收掉——重选 / 移除 / 替换 / 删单据时真的删掉不再被引用的副本，
   并把「没被别人占用」并进写语句的谓词（与第 1 件同形）。这一件是本轮**排期被提前**的直接原因：
   D-6 要接删除接缝，而接删除会触发 §3 的升级条款。

三件都要走反向证明；第 1 件与第 3 件还要各配一个「只有它能杀掉」的用例（条件写被改回无条件写、
受影响行数校验被删、占用查询与删除之间的窗口）。

---

## 6. 拆轮表

各轮的**新增测试数与键数是预计，不是承诺**。

| 轮 | 范围 | 验收线 | 预计新增 | 棘轮 / 登记联动 |
| --- | --- | --- | --- | --- |
| **D-0**（本轮） | 把九条裁定落成本文件 | 纯新增一个 `.md`；非 `.md` 变更 0；测试数、键数、黄金全不变 | 0 测试 0 键 | 无 |
| **D-1a schema v25**（排在 D-1 前） | Q2-d-② 的加列轮：`ALTER TABLE business_documents ADD COLUMN currency TEXT`（可空、无 `CHECK`）+ schema 守门 + 确认 `PreMigrationSnapshot` 既有机制覆盖这根新横档。**只加列，不写它**——写入者是 D-1 的对账单生成器 | 沿 N-PR-1（v24）先例：①`sharedLadderVersion` 仍是 **23** 不动，`nativeOnlyVersions` 由 `[24]` 变 `[24, 25]`、`schemaVersion` 由 24 变 **25**，`SchemaVersionParityTests` 的五条断言全部跟着更新（它同时钉「等于字面清单」与「等于连续区间」两件事）；②守门按 `InventorySchemaTests` 的分段写法落（该文件 11 条分 **G/H/L 三段**：G 段管横档行为——到达/幂等/回滚往返/head 必需/prepared-import 闸；H 段管列语义；L 段管就地升级先快照再迁移且快照可还原）；③本轮的 H 段只需钉「列存在、可空、无 `CHECK`」，L 段直接复用 v24 已建立的快照机制并**实测确认它覆盖 v25**，不新建机制 | +10~20 Core | 不涉 pbxproj（Core 包）。**Electron 侧 CSV 导出会多一列，见 Q9 影响面第 2 条** |
| **D-1 存储层** | 按 Q9 甲案读写 v11 既有表；按 Q4 把算式迁入 Core 并逐字复刻。**对账单生成器（Q2）的开工条件 = D-1a 已合并**——生成器要写的 `currency` 列必须先存在；在那之前不得先写一个「日后再补币种」的版本 | 建/读/写往返；舍入链与 Electron 逐字节相等（对抗输入含「先舍后乘 ≠ 先乘后舍」的用例）；Q5 边界断言之 1、2 | +25~40 Core | 不涉 pbxproj（Core 包） |
| **D-2 编号与状态机** | Q3 编号；Q5 状态机、编辑白名单、删除规则；A8 设计约束落地 | 状态机闭集反例全覆盖；编号三条反例（跨年 / 删除后重用 / 自定义不污染最大值）；「改行不传 items」路径在原生不可达 | +20~30 Core | 不涉 pbxproj |
| **D-3 六语文案** | `documents.*` 的原生等价键族，含 D-4 关联面板所需的键 | 六语键数同步 650 → 650+N；`LocalizationWordingGuardTests` **零新增 sanctioned**；禁词实跑 | +50~87 键 × 6（预计） | **棘轮实为四处、跨两个目标**：`InventoryCopyTests` 的 650（Core）**与它同一个测试里的 `nav.* == 7`**、`LegacyConversionCopyTests` 的 650（App）、`ProductCopyTests` 的 650（App）。第四处只在本轮加 `nav.documents` 时才红，与 N-PR-3 加 `nav.inventory` 同形；本行原写「三处」，由第六次裁定订正。**若新增 App 目标测试文件，须手工登记 pbxproj，恰 4 行/文件** |
| **D-4 视图** | 列表页 + 编辑器 + 明细行 + **正式发票关联面板**（对应 Electron 的 `TaxInvoiceModal.tsx`，含附件控件，**但不含任何删除路径**——见 §3 该节）；对账单的编辑语义按 Q5-a 收窄 | 新建 `DocumentsView` 与其 composition；`documents.*` 的休眠守门从「零命中」翻成「恰由 composition 命名」的闭集；`documents.export.*` / `documents.print.*` 九键**继续断言零命中**（属 D-5） | +30~50 App | **本轮不动侧栏**（第七次裁定把它移入 D-6）。App 目标新文件须登记 pbxproj，恰 4 行/文件 |
| **D-5 输出** | Q7 的自包含 HTML 导出 + Powerbox 存盘 | 产物里必然含免责声明（守门断言）；模板对用户文本全量转义（含注入形对抗用例） | +10~25 | 不动 entitlements 闭集（那是后续轮候选） |
| **存储原子化**（非 D-x 序列，排在此处） | §5 的候选轮三件：三处条件写 + 受影响行数校验、`ProductCatalog` 的 `(code 19)` 谓词、**附件的安全删除** | 三件各配「只有它能杀掉」的用例；不改 schema | 未估 | **必须早于 D-6**：D-6 要接的删除接缝会触发 §3 的升级条款 |
| **D-6 激活** | 侧栏可达 + 接上附件删除接缝 + 收尾 | 侧栏入口可达；**`SidebarSection`（`AppModel.swift`）新增一例、`RootView` 加分支、`InventoryView` 的「不是本页的五个分区」注释与 `AppModel` 的「六个分区之一」注释同轮改**（第七次裁定自 D-4 移入；实测届时另有 8 处 `SidebarSection.allCases` 有序断言与 `DocumentCopyTests` 的 `SidebarSectionProbe` 两条要同批翻转，开工前须重跑扫描）；`LegacyLedgerProbe` 的 `otherRecordTables` 移除 `business_documents` 与 `business_document_items` 两项；`legacy.other.message` 六语改写（现文说「本 App 目前只显示流水」，激活后变假）；`docs/SWIFTUI_FEATURE_GAP.md` §3 该行改状态 | +10~20 | `products` 已有同形先例，其理由写在 `AppModel.swift` 对 `otherRecordTables` 的注释里 |

---

## 7. 本轮实测数字（可复算）

| 项 | 值 | 复算方式 |
| --- | --- | --- |
| `doc_type` 闭集 | 5 | `DOC_TYPES` 与两侧 `CHECK` 子句 |
| `status` 闭集 | 3 | `DOC_STATUSES` 与 `CHECK` 子句 |
| 路由 | 7 | `electron/handlers/router.js` 中 `/api/documents` 前缀的条目 |
| `documents.*` 键 | 87 × 6 = 522 | 六个 `i18n/locales/*.json` 的 `documents` 对象键数 |
| 禁词命中 | 0 | 两张词表 × 522 条，图案先经已知目标自证 |
| Electron 侧断言 | 63 | `scripts/test-handlers.mjs` 的 §2B Batch 8 段内 `ok(` 50 + `expectThrow(` 13；另可用该段每条断言都带的 `[doc]` 标记复算，全仓恰 63 次 |
| 真 Electron e2e 用例 | 5 | `e2e-electron/documents-attachment-fs.spec.ts` |
| 镜像面 | ≈1813 行 | handler 322 + 前端 1491（`DocumentsPage` 356 + `DocumentModal` 501 + `documentPdf` 160 + `TaxInvoiceModal` 256 + `invoiceStatusDisplay` 42 + `services/api.ts` 单据段 176） |
| 原生写入的表 | 10 张 | `native/SoloLedger/Sources` 下全部 `INSERT` 语句，含唯一一处插值写（它只服务 `transactions` 与 `legacy_migrations`） |

---

## 8. 未裁定项

**无。** 测绘九问、Q2 的四条细目（Q2-a / Q2-b / Q2-c / Q2-d 含 ②）、以及 Q7-a，全部已裁定并写在 §2；逐次记录见 §9。**本文件自此是一份完整的可开工规格。**

开工次序上仍有一处硬依赖，它不是未裁定项而是排期：**D-1 的对账单生成器要等 D-1a 合并**，因为它要写的 `currency` 列由 D-1a 加入。D-1 的其余部分（Q4 算式、Q9 存储）不受这条依赖约束。

后续轮若遇到本文件没写的口径，正确动作仍是**停下来要裁定**，不是自行择定（见 §9 开头）。

## 9. 修订

本文件只在用户新裁定时修订，且必须同时写清「哪一条从什么改成什么、依据是什么」。实现轮**不得**因为实现困难而反向修改本文件——那种情况的正确动作是停下来要新裁定。

### 2026-08-17 · 第二次裁定（§8 四项 + Q7-a）

| 条目 | 从什么 | 改成什么 | 依据 |
| --- | --- | --- | --- |
| **Q2-a** 字段映射 | §8「未裁定，阻塞 D-1」 | 移入 §2 Q2 正文的「汇总单形态」表：描述取 `description`（可空）；数量/单位/单价一律留空；金额 `COALESCE(amount_net, amount)`；税额取 `tax_amount`；空值显示破折号 | 用户裁定。另附两条本轮实测：`amount REAL NOT NULL` 与 `amount_net REAL`（可空）使「判 `NULL` 而非 falsy、`0` 保留」成为这两列能承载的语义；明细表 13 列里只有 `ref_date` 一个日期载体，故日期列的载体是**被迫**的不是挑的 |
| **Q2-b** `tax_rate` 量纲 | §8「未裁定，阻塞 D-1」 | 移入 §2：对账单只列描述/日期/金额/税额四列，**不列税率也不写 `tax_rate`** | 用户裁定，理由是「量纲无库内约定就不把它印上客户面产物」。本轮实测支持：写入侧只做 `Number(x) \|\| 0`，全仓无消费者对该列归一 |
| **Q2-c** 空白规则 | §8「未裁定，阻塞 D-1」 | 移入 §2 第 2/4/5 条：下拉与筛选**都 trim 后再精确相等**，且**共用同一个归一函数**；显式声明**不碰流水写入路径** | 用户裁定，等价于 Electron 语义（`stmtCustomers` 与 `generateStatement` 两处均 trim）。原生 `Transaction.normalized()` 只 `prefix(200)` 不 trim，故归一放在读取比较侧 |
| **Q2-d** 跨币种 | §8「未裁定，阻塞 D-1」，四选一 | 移入 §2：**按币种拆多张单**，N 个币种 ⇒ N 张单。并写死三条后果：①编号一次消耗 N 个（已交叉写进 Q3 的「批量取号」行）；②持久化缺口**未闭合**，降级为 §8 的 Q2-d-②；③与 Q8/Q9「不加列」的张力如实登记，将来加币种列必须走独立 schema 轮 | 用户裁定。**如实记录：这是四个选项中用户的选择，不是本文件的推荐项**，另三项已在 §2 该节列出 |
| **Q2-d-②** 币种标记载体 | （本次新产生） | **仍未裁定，停在 §8**，D-1 的对账单闸门因此**保持关闭** | 本轮把 24 列逐列普查（谓词自证：`doc.customerName` 判「印在产物上」为真、`doc.createdAt` 为假），结论是没有既能承载标记又满足「页眉/徽标/金额符号都从它渲染」的字段：裁定原文点名的 `notes` **用户可改且印在产物上**，标记被删就会让外币单据静默换回本位币符号——正是后果③要防的；唯一技术上可用的 `source_sales_id` 语义说谎且进 CSV。三选一已列在 §8 |
| **Q7-a** 文件名与落盘 | §8「未裁定」 | 移入 §2 Q7：文件名 `<doc_number>.html`（非法字符转义），落盘走 Powerbox 用户自选、无默认目录 | 用户裁定。**另登记一条实测订正**：裁定理由里说「唯一性由 `(doc_type, doc_number)` 索引背书」——该索引保证的是**这一对**唯一，不是 `doc_number` 单列唯一（既有守门就断言同一个 `DUP-1` 可在 `quotation` 与 `sales_order` 各存在一次），所以同编号不同类型会撞同名文件。落盘由 Powerbox 面板提示重名，不是静默覆盖，故登记为已知形态而非另开裁定 |
| **Q8** 币种推导 | 「显示币种一律由 `acc_locale` 推导」 | 加**一处显式例外**：带币种标记的非本位币对账单，金额符号/页眉/徽标按标记渲染。例外**待 Q2-d-② 定了载体才生效** | Q2-d 的后果③要求，写在 Q8 节以免两处互相矛盾 |

### 2026-08-17 · 第四次裁定（§7 数字订正）

| 条目 | 从什么 | 改成什么 | 依据 |
| --- | --- | --- | --- |
| **§7** Electron 侧断言 | 259 | **63**，并把复算方式写成两种独立构造：段内 `ok(` 50 + `expectThrow(` 13，以及该段每条断言都带的 `[doc]` 标记全仓恰 63 次 | 用户裁定。依据是 D-1（PR #488）的实测：**259 是从 Batch 8 标题一路数到文件末尾**的结果，把其后 11 个无关段落（现金流、providers、EC27 等）全扫了进去，所以它不是「段内」计数。两种构造互证得 63；`scripts/test-handlers.mjs` 自 `139d6018` 起一字未改，故这是**记录错误而非漂移**。本行不改变任何口径，只改一个可复算的数字 |

**这条订正不解锁也不阻塞任何轮次。** D-1 的语义对照本就按真实的 63 条做：其中 26 条在 D-1 范围内（create 校验 5 / create 成功 8 / get-list 7 / 明细与合计 6），其余 37 条属 D-2（`next-number` 6 / `DOC_NUMBER_EXISTS` 3 / `update` 与状态机 11 / 税务发票关联 9 / `remove` 8）。

### 2026-08-17 · 第三次裁定（Q2-d-②）

| 条目 | 从什么 | 改成什么 | 依据 |
| --- | --- | --- | --- |
| **Q2-d-②** 币种载体 | §8「未裁定，三选一（`source_sales_id` 重载 / `notes` 加缺失兜底 / 升级为 schema 轮）」，闸住 D-1 的对账单部分 | 取 **(c)**：新设 **D-1a** 小轮，原生 schema **v25** 给 `business_documents` 加**可空 `currency TEXT`**、**不设 `CHECK`**。`NULL` = 沿 Q8 按 `acc_locale` 推导（既有单据与非对账单类型行为一个字不变）；非 `NULL` = 页眉/徽标/金额符号三处按该列渲染。**首版写入者只有对账单生成器** | 用户裁定。落选两项的理由**是本轮实测**不是推测：`notes` 在 `EDITABLE` 白名单里且印在产物上（`notesBlock`），标记可被用户删掉、删掉后金额符号会静默回落本位币；`source_sales_id` 技术上够用但列名说谎，且原样进 CSV |
| **§8** | 「未裁定项：Q2-d-②」 | **清空**——无未裁定项，本文件成为完整可开工规格；只保留一条排期依赖（D-1 的对账单部分等 D-1a 合并） | 上一行的直接后果 |
| **Q8** 例外句 | 「例外**待 Q2-d-② 定了载体**才生效」 | 解除等待，直接指向 `business_documents.currency`：非 `NULL` 时三处按该列渲染，`NULL` 时正文原样成立 | 载体已定 |
| **Q9** 存储 | 「**不建新表、不加列**」 | 「不建新表、不加列，**唯一例外 = D-1a 的 `currency` 列**」，并补三条实测影响面 | 用户裁定。三条影响面：①Electron 的 `documents.js` 读走 `HEADER_COLUMNS`、写走显式列名，该文件里 `SELECT * FROM business_documents` **出现 0 次**（而 `SELECT * FROM` 在 `electron/` 全树有 20 处，故这个 0 有判别力）⇒ 读写不受影响；②**有一处输出形状会变**：`_csvExport.js` 的 `tableToCsv` 用 `PRAGMA table_info` + `SELECT *`，Electron 打开 v25 账本导出 `documents` 会**多一列 `currency`**，如实登记；③单向性仍是**约定不是强制**（`SchemaMigrator` 文件头自述 v24 账本不被 Electron 拒绝、其迁移循环跑零次），v25 落在同一条 `nativeOnlyVersions` 序列上，性质不变 |
| **§6 拆轮表** | D-1 是第一个实现轮 | **插入 D-1a 行、排在 D-1 前**；D-1 的对账单闸门解除条件改为「D-1a 已合并」 | 用户裁定。D-1a 的验收线按 N-PR-1（v24）先例落，三条都经本轮实测确认：①`sharedLadderVersion` 仍 **23** 不动、`nativeOnlyVersions` 由 `[24]` 变 `[24, 25]`、`schemaVersion` 由 24 变 **25**，`SchemaVersionParityTests` 的五条断言跟着更新（它同时钉「等于字面清单」与「等于连续区间」两件事）；②守门分段照 `InventorySchemaTests` 的 **G/H/L 三段共 11 条** 写法；③`PreMigrationSnapshot` 是 v24 就为「就地升级活账本」建的既有机制，本轮**只需实测确认它覆盖 v25**，不新建机制 |

### 2026-08-17 · 第五次裁定（三处并发窗口 → 维持镜像并登记）

D-2（PR #489）开出后，晚到的评审 bot 提了两条 check-then-act 跨连接竞态：附件归属查询与 `UPDATE`
之间的窗口（P1），以及状态读与生命周期写之间的窗口（P2，`update` / `remove` / `updateTaxInvoice`
三处同形）。执行会话判定「属实但修法必然越过 Q9 或 §1」，**停下要裁定而不是自行处置**。

| 条目 | 从什么 | 改成什么 | 依据 |
| --- | --- | --- | --- |
| **§3** 镜像保真登记 | 三条（A5 / A6 / A8） | **六条**：新增 **A9**（`update` 的状态读在事务外）、**A10**（`remove` 全程无事务）、**A11**（`updateTaxInvoice` 全程无事务），并新增「并发窗口三条的登记依据与升级条款」一节 | 用户裁定 **(a) 维持镜像**，照 A5 / A6 / A8 先例登记。三条依据均为实测：①Electron 侧窗口逐字段同形（`db.transaction` 只包住写且默认 DEFERRED；另两处零事务）；②原生实害当前不可达（单进程单 `LedgerStore`、`Documents/` 文件系统调用数 **0**〔该图案在 `SelfTest`/`Support`/`BackupRestore`/`AttachmentApply` 会命中，故非空图案〕、孤儿路径消费者数 **0**）；③修法二选一都越界（加唯一约束＝改 schema，Q9 禁；条件写／`BEGIN IMMEDIATE`＝有意偏离镜像，§1 禁） |
| **§3** 升级条款 | （本次新产生） | 写死**自动升级**：一旦引入①多连接并发写路径或②真会删附件文件的路径，A9–A11 **自动从「已知形态」升级为必修项，且先修后接**；触发时不需要重新裁定「要不要修」，只需裁定「怎么修」 | 用户裁定。把「现在不可达」这个前提的**失效条件**写死，而不是留给将来的轮次自己判断 |
| **§5** 不在本章 | 六项 | **七项**：新增「存储原子化」行，并在其后补一节候选轮范围——三处条件写 + 受影响行数校验（不改 schema），外加 `ProductCatalog.mapWriteFailure` 的 `(code 19)` 谓词修正 | 用户裁定：登记为**独立候选轮，排期由用户将来定**。`(code 19)` 与它绑在一起，是因为两者同属「判据写在宿主语言里而不是写进写语句／结果码里」 |
| **§9** 第三次裁定标题 | 「第三次（**末次**）裁定」 | 「第三次裁定」 | 「末次」在第四次裁定落笔时就已失效，本次连同订正；本行不改任何口径 |

**本次修订不解锁也不阻塞任何轮次**，也不改变 D-2 的代码：PR #489 的实现保持与 Electron 同形。

### 2026-08-18 · 第六次裁定（拆轮表补 D-4 关联面板；棘轮订正为四处）

D-3 的键族测绘（只读）发现两处拆轮表说漏了的事实，均已实测：**Electron 的 `TaxInvoiceModal.tsx`
在原生侧没有任何轮次认领**——§6 的 D-4 只写「列表页 + 编辑器 + 明细行」，而那是 Electron 里与
`DocumentModal.tsx` 并列的另一个组件，它的 16 个键（关联面标签 + 附件控件）因此谁都不画；以及
**六语键数棘轮实为四处而不是三处**。

| 条目 | 从什么 | 改成什么 | 依据 |
| --- | --- | --- | --- |
| **§6 · D-4** | 「列表页 + 编辑器 + 明细行」 | 「列表页 + 编辑器 + 明细行 **+ 正式发票关联面板**（对应 `TaxInvoiceModal.tsx`，含附件控件）」 | 用户裁定。拆轮表漏认领了 Electron 的第二个组件；D-4 收编而不是另开一轮。**直接后果**：那 16 个键回到 D-3 本轮写入、消费轮次标 D-4，不再延后 |
| **§6 · D-3** | 「三处 650 棘轮跨两个目标」 | 「**四处**」——同一个 `testIC2` 里还有一条 `nav.* == 7` 的前缀谓词，加 `nav.documents` 时同样会红 | D-3 全仓重扫实测：只改 `.strings` 后 Core 恰 12 条失败（650 × 6 + `nav.*` × 6）、App 恰 12 条（两处 650 × 6），四个断言点之外一条不多。与 N-PR-3 加 `nav.inventory` 同形 |

**本次修订不改任何口径，也不改代码**：它补的是拆轮表漏记的归属与一个漏数的守门点。

### 2026-08-18 · 第七次裁定（D-4 开工三问：对账单编辑 / 侧栏归属 / 附件删除）

D-4 开工前置的测绘（只读）提出三个超出确认书的判断点，执行会话停下来要裁定，用户逐条裁定如下。
本次修订**不改任何已裁定口径的方向**，它把一处收窄写进 Q5、把一处归属订正回 D-6、把一处排期写死。

| 条目 | 从什么 | 改成什么 | 依据 |
| --- | --- | --- | --- |
| **Q5 编辑** | 「仅 `draft` 可改字段与明细」，对账单无例外 | 新增 **Q5-a**：对账单**表头可改、明细只读**，编辑请求对 `statement` 恒不携带 `lines`；改明细的路径 = 删掉重新生成；**创建**对账单只有生成器一条路 | 用户裁定（选项 B）。`statement` 属 Q2 发明面，发明面的编辑语义可收窄；两个后果（丢行丢钱 / `NULL` 税额压 0）同时挡住，Core 零改动，A8 的「行与总额同进同退」不变。**第二个后果是本轮新测出来的**，原登记只写了第一个 |
| **§3** 镜像保真登记 | 六条（A5/A6/A8/A9/A10/A11） | **七条**：新增 **A12**（用户手工清空一行描述 → 静默丢行丢钱，两侧都可达） | 用户知会「照搬并登记，不改」。它与 Q5-a 不是同一件事：Q5-a 挡的是生成行天然带空描述那一子情形 |
| **§3** 附件 | （本次新产生） | 新增「D-4 的一处有意不镜像：附件副本只进不出」一节：D-4 只做选文件 / 打开 / 保存关联，**零删除路径**；孤儿副本磁盘泄漏如实登记；写死**「原子化轮落地前不得接删除」** | 用户裁定 (b)。Electron 的三条删除路径任一都会触发本节上方的升级条款，而 `discardDocAttachment` 本身就是 A11 的形状 |
| **§5 / §6** 存储原子化轮 | 「排期由用户定」，范围两件 | 排期**写死在 D-5 之后、D-6 之前**；范围**三件**（新增「附件的安全删除」） | 用户裁定。D-6 要接删除接缝，接删除即触发升级条款，所以原子化必须早于 D-6 |
| **§6 · D-4** | 「新分区是第 7 个……`SidebarSection` 新增一例；两处分区计数注释同轮改」 | 移出 D-4：本轮**不动侧栏**。D-4 行改写为休眠守门的翻转与九个 D-5 键的零命中 | 用户裁定（维持 D-6）。三条依据：①D-3 已合并的代码注释两处明写 `nav.documents` 与侧栏分区属 D-6（`DocumentCopyTests.swift` 文件头与 DC9 内）；②N-PR-4/N-PR-6 先例——库存页的 `SidebarSection` case 是在**激活轮**加的，`InventoryPageComposition.swift` 的注释即此；③`RootView` 的 detail switch 穷尽无 `default`，加 case 即必须加分支、页面当场可达，那样 D-6 的「侧栏入口可达」就没有内容 |
| **§6 · D-6** | 「侧栏可达 + 收尾」 | 收编自 D-4 的侧栏三件（enum case / `RootView` 分支 / 两处计数注释）+ **接上附件删除接缝**；并登记「届时另有 8 处 `SidebarSection.allCases` 有序断言与 `SidebarSectionProbe` 两条要同批翻转，开工前须重跑扫描」 | 同上。处数是 D-4 开工前置实测的，按 N-PR-6 判例「记忆里的处数只当线索」，D-6 仍须重跑 |

**本次修订不改代码之外的任何口径**：Q1–Q4、Q6–Q9 与 Q2 的四条细目一个字未动。

### 2026-08-19 · 第八次裁定（D-4 复核返工的两处编辑期差异 → 登记级）

D-4 的复核返工（PR #491，merge `66ed9fef`）在实现「三个数字域按控件自己的属性判」时，实测出两处
**编辑期**差异：两边都拒绝把它们写进账本，但字段还没打完时屏幕上的合计不同。用户在合并授权的同一条
消息里**追认它们为登记级**，并把 §3 的登记行排期到 **D-5 的首个 commit**——即本次修订。

| 条目 | 从什么 | 改成什么 | 依据 |
| --- | --- | --- | --- |
| **§3** | 只有 A 系列七条 | 新增一节「D-4 的两处编辑期差异（第八次裁定：登记级）」与 **B1 / B2** 两行 | 用户追认。两条都到不了账本，差异只在字段被编辑的那一段时间里 |
| **编号** | （本次新产生） | 另编 **B 系列**而不是接着 A12 写 A13/A14 | A 系列表头自己写的是「Electron 的已知形态，本章照搬」，这两条不是那种东西——方向相反。混进同一命名空间会让那句表头对它自己的两行为假 |
| **措辞** | （本次新产生） | 两行的形态列**逐字带上代码注释里的英文原句** | 用户指令「措辞照抄注释不重写」。那两句是 D-4 返工实测出来的，不是推的；逐字带上，任何时候都能与注释按字节对回去 |

**本次修订不改任何已裁定口径**：Q1–Q9 与 Q2 的四条细目、§5 / §6 拆轮表一个字未动。
D-5 的输出本体（Q7 自包含 HTML + Powerbox）**不在**本次修订内——它的测绘还没做完，还没有任何东西可裁。

### 2026-08-19 · 第九次裁定（D-5 开工测绘的九点 + B 系列编号追认）

D-5 开工前置的只读测绘（Q7 自包含 HTML + Powerbox）提出九个超出确认书的判断点，执行会话停下来要裁定，
用户逐条裁定如下。**本次修订不改任何已裁定口径的方向**：它把一处模板变体写进 Q7、把一处例外延伸写进 Q8、
把验收线的定义域写成 Q7-b，其余五处全部落成 §3 的 B 系列登记行。

| 条目 | 从什么 | 改成什么 | 依据 |
| --- | --- | --- | --- |
| **B 系列编号** | 第八次裁定时由执行会话自行择定 | **追认** | 用户追认。A 系列表头自称「Electron 的已知形态，本章照搬」，B 系列的东西方向相反，混进同一命名空间会让那句表头对它自己的行为假 |
| **Q7 模板** | 「明细表（描述 / 数量与单位 / 单价 / 税率 / 税额 / 金额六列）」，无类型分支 | 新增**对账单变体**：四列（描述 / 日期 / 金额 / 税额），不出税率，**日期独立成列**取 `ref_date`；其余四型仍六列 | 用户裁定。Q2-b 在屏幕侧已经把日期从描述串里拿掉，产物若照抄六列会把日期整个丢掉——实测：Electron 对一张原生形状的对账单出六列、三列全空、日期在描述格里 |
| **Q7-a 文件名** | 「非法字符要先转义」，未指定转义函数 | **照抄 Electron 正则** `replace(/[\\/:*?"<>|\s]+/g,'_')`，空串回落 `id`，**不带前缀** | 用户裁定。转义规则照抄，前缀与扩展名按 Q7-a 正文既有的收窄 |
| **Q7-b 验收线** | Q9 只写「同输入下结果与 Electron 逐字节相等」，产物面无定义域 | **非对账单 + `currency IS NULL` + CN 制度 + 注入固定 `generatedAt` → 逐字节相等**；黄金六语各一份、node 经 `_ts-resolver` 生成并提交、独立目录 + 独立再生成校验、**不进冻结的报表黄金目录**、**不得出现行首 `Allowed-Golden-Changes`**；定义域之外每处分叉各钉一条只钉它的测试 | 用户裁定。B3–B7 每一条都会让某一类样本永远不可能逐字节相等，把边界写下来比挂一条永远为真不了的断言诚实 |
| **Q8 例外** | 三处载体（页眉 / UI 徽标 / 金额符号） | 加**第四处延伸**：产物页眉在 `currency` 非 `NULL` 时出一行「币种: <代码>」，`NULL` 时零行 | 用户裁定。`documents.print.currency` 是 D-3 已写入的键，本轮给它定了落点；出代码不出符号，与 Q8 在金额符号一侧同源（本仓无 code→symbol 表） |
| **§3 · B3** | （本次新产生） | 产物的税相关标签沿用屏幕固定键，**零制度化标签概念进原生** | 用户裁定。搬概念表 = 动 accounting profiles，`CLAUDE.md` 的红线 |
| **§3 · B4** | （既有分叉，此前零登记） | 屏幕侧同一处分叉**补登记** | 用户裁定。它在 D-3/D-4 就已发生，是 B3 成立的前提 |
| **§3 · B5** | （本次新产生） | 抬头只出 `company_name`，其余传空；**不加设置项** | 用户裁定 |
| **§3 · B6** | （本次新产生） | `generatedAt` 固定 ISO-8601 UTC，`now` 可注入 | 用户裁定。`toLocaleString` 没有稳定格式契约，钉不住；可注入是 Q7-b 定义域的前提 |
| **§3 · B7** | （本次新产生） | 产物的 `<html lang>` 与 CJK 字体键出 Electron 码（`zh-Hans`→`zh-CN`、`zh-Hant`→`zh-TW`） | 用户裁定。出原生码会同时改掉字体回落与产物字节 |

**本次修订不改代码之外的任何口径**：Q1–Q6、Q9 与 Q2 的四条细目、§5 / §6 拆轮表一个字未动。
`documents.print.*` 五键**不是打印动作**而是产物自带的标签（.strings 注释原文），测绘据此确认
「原生的打印对应物是什么」这一超规格判断**在本轮不产生**——系统打印（`NSPrintOperation`）仍按 Q7 正文
登记为后续轮候选。

### 2026-08-19 · 第十次裁定（四列的画序以已合并的屏幕为准）

D-5 的实现按已合并的屏幕（`DM21`）画「描述 / 日期 / **税额 / 金额**」，而 Q2-b 与第九次裁定写进 Q7 的
那两句枚举都写着「金额 / 税额」。执行会话在实现时就看出这处不一致，却只写进代码注释、没有主动报告，
由复核（PR #492 的 bot 意见）抓出。用户裁定：**以屏幕为准，改规格的那两句枚举。**

| 条目 | 从什么 | 改成什么 | 依据 |
| --- | --- | --- | --- |
| **Q2-b** | 「只列四样：描述 / 日期 / 金额 / 税额」 | 「只列四样：描述 / 日期 / **税额 / 金额**」 | 用户裁定。**金额殿后与两侧全部表格同序**：六列表的表尾就是 税额 → 金额，Electron 与原生皆然；四列表若反过来，同一个页面上两张表的最后两列会互调 |
| **Q7 · 对账单变体** | 同上的枚举 | 同上 | 同一条口径的另一处书写，一并订正 |
| **代码** | （无） | **零改动**：屏幕（`DM21` 的有序等式）与产物（`DocumentHTML.statementHead`）本来就是这个顺序 | 本次裁定订正的是规格的书写，不是实现 |

**§9 的历史行不改。** 第三次裁定（Q2-b 移入 §2）与第九次裁定（Q7 加变体）两处表格里引用的旧枚举
按其性质保留：它们记录的是当时写下的东西，改掉就不再是修订记录了。判断当前口径请看 §2 正文。

**本次修订不改任何其它口径**：Q1 / Q3–Q9、§3 的 A 与 B 两系列、§5 / §6 拆轮表一个字未动。
