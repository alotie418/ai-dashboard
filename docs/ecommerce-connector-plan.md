# 电商平台接入 · 连接器架构与 MVP 计划

> 状态：**前期设计（只读产出）**。本文件不改 schema、不改运行代码。
> 基线：main `065be65` / #328 · schema **v20**。
> 定位：本文件是后续 PR1（schema）/ PR2（脚手架）落地前的**权威设计与字段定稿依据**。

---

## 0. 目的与安全底线

为「主流电商平台订单数据接入」建立一套**统一连接器架构**，让订单能被安全导入本地账本。

贯穿全程的安全底线（不可协商）：

1. **拉单绝不直接写正式账本**：所有拉取的订单先落 `ecommerce_staged_orders` 暂存区，用户显式确认后才走既有 batch 写入路径进入 `sales/sales_items`。
2. **可预览、可回滚、可幂等**：预览复用现有 CSV 导入的暂存/预览 UX；提交按外部单号幂等去重；每一步都能回滚。
3. **不碰会计红线**：不改 `electron/reports/*`、COGS、税率/税额公式、`_expenseSplit`、库存成本、`categories` 税表映射；平台费/退款/COGS 判定一律留给会计师确认。
4. **本地优先**：连接器出网发生在 Electron 主进程（与现有 AI provider 一致），不引入云后端、不复活 Web 架构。

---

## 1. 现状盘点（订单导入相关）

### 1.1 账本数据结构（schema v20）

| 表 | 版本 | 关键列 |
|---|---|---|
| `sales` | v1/v10/v20 | `id`(TEXT PK)、`date`、`customer`、`totalAmount`/`amountWithoutTax`/`taxAmount`/`taxRate`、`shippingCost`（**仅销售·表头级**）、`invoiceNumber`/`invoiceStatus`、`payment_status`/`paid_amount`/`due_date`/`payment_date`、`product_id`/`product_name_snapshot`/`unit_snapshot`、legacy `tons`/`pricePerTon`。**无 currency 列** |
| `sales_items` | v20 | `id`(INT PK)、`sale_id`(FK→sales ON DELETE CASCADE)、`line_no`、`product_id`（软引用）、`description`、`unit_snapshot`、`quantity`、`unit_price`、`amount_net`、`tax_rate`、`tax_amount`、`amount_gross` |
| `purchases` / `purchase_items` | v1/v20 | 与销售对称，`purchase_items` 无 shippingCost |
| `transactions` | v5 | 规范化收支流水；**唯一带外部元数据位** `source_meta`(JSON)，带 `currency` |
| `products` | v9 | `id`(TEXT PK)、`name`、`unit`、`default_unit_cost`、`is_service`、`is_active` |
| `categories` | v4/v13 | 科目分类，含 `is_cogs`（**红线相关**） |
| `settings` | v1 | KV JSON + 白名单 `SETTINGS_ALLOWED_KEYS` |
| `ai_providers` | v2 | `provider`(PK)、`api_key_encrypted`（safeStorage 密文 base64）、`model`、`enabled`、`is_default` —— **凭证存储范式** |
| `legacy_migrations` | v5 | `UNIQUE(legacy_table, legacy_id)` —— **幂等去重范式** |

**关键不变量**：表头金额 = Σ 明细 `amount_gross`；`shippingCost` 为表头级、不进明细求和。订单落库必须遵守。

### 1.2 现存缺口

1. `sales/purchases/transactions` 均无外部单号/平台来源列，无去重唯一约束（除 PK）。
2. 无客户/供应商主数据表（自由文本）。
3. 无应收/应付实体表（由 `payment_status + paid_amount` 实时派生）。
4. 无 sync/cursor/job/webhook 基础设施（全仓库 grep 无命中）。
5. **`sales/sales_items` 无 currency 列** → 跨境多币种是真实缺口（见 §7 决策）。

### 1.3 可复用基础设施（大量可复用）

| 能力 | 现有实现 | 复用方式 |
|---|---|---|
| Provider 注册表 | `electron/ai/index.js` 的 `PROVIDERS` 对象 + 适配器工厂 | 克隆为 `ECOMMERCE_PROVIDERS` + **通用 provider 接口** |
| 凭证加密 | `electron.safeStorage`（`encryptKey/decryptKey`→base64→SQLite），明文只在内存、永不回渲染进程 | **直接复用**，新表存密文 |
| 设置存储 | `settings` KV + 白名单 | 存非敏感连接配置 |
| IPC / 路由 | `api:request {method,path,body}` + `router.js dispatch()` | 新增 `electron/handlers/ecommerce.js` 挂路由 |
| 批量写入 | `batch.js` 两遍式（先全校验零写入→单事务全写）+ 全或无 + `_lineItems`(normalizeItems/sumHeaderTotals/replaceItems) | **提交阶段复用**，加去重 |
| 暂存/预览 UX | `CsvImportModal`（上传→映射→预览→结果）+ `resolveProduct` 保守匹配 + 全或无禁用按钮 | **克隆为订单预览模态** |
| 主进程出网 | AI provider 已用主进程 `fetch()` 调 HTTPS；渲染进程无网络权限（contextIsolation） | 电商 API 调用同样放主进程 |
| 后台同步/游标 | ❌ 无 | **需新建**（MVP 仅手动拉单，不做后台调度） |

**守卫无阻**：`check:no-web-fetch` 只禁前端 `fetch('/api'|'/auth')` 与 Web 回退残留；`check:offline` 只禁资产 CDN，并明确「运行时 API 端点属网络调用、不在禁止之列」。→ 主进程调电商 API 与现有 AI 出网完全同构。

---

## 2. 订单导入落点

| 目标 | 落点 | 说明 / 风险 |
|---|---|---|
| sales（表头） | ✅ 一订单 = 一 `sales` | `date`=下单日、`customer`=买家（脱敏，见 §9）、`shippingCost`=运费行合计（表头级）、`payment_status`←平台支付态、`invoiceNumber`=订单号或空 |
| sales_items | ✅ 一订单行 = 一 `sales_items` | 复用现有明细口径，表头 = Σ明细 |
| products | ✅ 按 SKU→`product_id`，其次精确名匹配 | 复用 `resolveProduct` 保守策略：命中 / 未命中（description-only 不计库存）/ 同名歧义（阻断，人工选） |
| transactions | ⚠️ **MVP 不双写** | 系统存在 sales↔transactions 双模型；订单进多明细 `sales` 模型即可，**勿同时写 transactions 造成重复** |
| receivables | ✅ 无需写表，实时派生 | 平台「已付未结算」是否算应收 = 政策决定，需确认 |
| platform fees | 🔴 **不自动入账** | 现无平台费模型；opex vs COGS 属会计红线，MVP 仅暂存展示 |
| refunds / cancellations | 🔴 **不自动冲账** | 收入/税额冲回涉会计政策；MVP 仅暂存为信息，未导入订单的取消直接跳过 |

---

## 3. 统一连接器架构（provider adapter 抽象）

> **修正**：不采用「纯 REST 工厂」命名。抽象核心是**通用 provider 接口**，允许 **GraphQL / REST 两类传输实现**。Shopify 用 GraphQL adapter，WooCommerce 用 REST adapter。

```
electron/ecommerce/
  index.js                       # 连接注册表 + 管理(list/save/remove/test/pull)   ← 克隆 ai/index.js
  providers/
    _providerInterface.js        # 【通用 provider 接口 / 契约定义】所有连接器实现它
    _graphqlTransport.js         # GraphQL 传输助手(查询/翻页/限流)  ← Shopify 用
    _restTransport.js            # REST 传输助手(GET/翻页/限流)      ← WooCommerce 用
    shopify.js                   # GraphQL adapter（实现通用接口）
    woocommerce.js               # REST adapter（实现通用接口）
electron/handlers/ecommerce.js   # IPC 路由: connections.*, orders.pull, orders.staged.list, orders.commit
```

**通用 provider 接口（每个连接器必须实现，传输方式无关）**：

```
interface EcommerceProvider {
  meta: { id, name, transport: 'graphql' | 'rest', authKind: 'token' | 'keySecret' | 'oauth', capabilities }
  testConnection(creds): Promise<{ ok, storeInfo? , error? }>
  pullOrders(creds, { since, cursor, pageSize }): Promise<{ orders: RawOrder[], nextCursor, rateLimit }>
  normalizeOrder(raw): NormalizedOrder   // 平台差异只在此收敛：表头 + items[] + fees + refunds
}
```

- **Shopify**：`transport: 'graphql'`，`authKind: 'token'`（单店 custom app token）。通过 `_graphqlTransport` 发 GraphQL 查询。
- **WooCommerce**：`transport: 'rest'`，`authKind: 'keySecret'`（consumer key/secret）。通过 `_restTransport` 发 REST 请求。
- **新增平台** = 新增一个实现该接口的 provider 文件 + 注册进 `ECOMMERCE_PROVIDERS`（与现有 AI provider 完全同构）。

**九要素落地**：

| 要素 | 方案 |
|---|---|
| provider registry | `ECOMMERCE_PROVIDERS` 对象 + 通用接口 |
| credential storage | 复用 safeStorage；新表 `ecommerce_connections` 存 `credentials_encrypted` |
| OAuth / API key flow | **MVP 走单店 token/key**，避开 Electron 内 OAuth 回调服务器的复杂度；完整 OAuth 授权码流程后置 |
| order pull | 主进程 fetch，按 `updated_at` 增量、游标翻页 |
| pagination / rate limit | 尊重平台限流（退避重试）；**具体参数需查官方文档确认** |
| cursor sync | `ecommerce_connections` 存 `last_cursor` / `last_synced_at` / `last_order_updated_at` |
| idempotency | `sales` 加 `external_order_id`+`platform_source` + 唯一约束；提交前查重（借鉴 `legacy_migrations`） |
| preview / staging | `ecommerce_staged_orders`（raw + normalized + 匹配态 + 去重态）；拉单只写暂存 |
| error log | `ecommerce_sync_log`（拉单运行 + 错误 JSON），UI 可见 |

**数据流**：`拉单 → ecommerce_staged_orders → 预览/商品解析/去重 → 用户确认 → batch 写 sales/sales_items(external_order_id 幂等)`。费用/退款 MVP 仅暂存只读展示。

---

## 4. 平台接入难度对比

> 下表为架构层判断；各平台**精确鉴权流程、端点、字段名、限流、资质门槛均需查官方文档确认**，本文件不臆造字段。

| 平台 | 鉴权模型 | 单商户接入难度 | 订单权限门槛 | 备注 |
|---|---|---|---|---|
| **Shopify** | 单店 custom app **Admin API token**（免 OAuth 服务器）；公开 App 走 OAuth2 | 🟢 低 | 低（自有店铺自授权） | **首选 GraphQL Admin API**（REST Admin API 已 legacy）；订单对象含 line items / shipping / refunds / transactions |
| **WooCommerce** | REST **consumer key/secret**（HTTPS） | 🟢 低 | 低（自托管自控） | 官方文档说明 REST API 使用「generated consumer key/secret」；依赖商户已启用 REST API |
| 淘宝/天猫(TOP) | app key/secret + 签名(MD5/HMAC) | 🔴 高 | 高：交易类 API 需商家授权 + 常需服务商/ISV 资质 | 桌面端持 app secret 有安全顾虑；**需查官方文档** |
| 京东(宙斯) | app key/secret + 签名 | 🔴 高 | 高：订单 API 需 ISV 资质 | 面向云端 ISV 设计；**需查官方文档** |
| 拼多多 | app key/secret + 签名 | 🔴 高 | 高：订单类需权限申请 | **需查官方文档** |
| 抖店 | app 注册 + OAuth + 签名 | 🟠 中高 | 中高：订单权限需申请 | **需查官方文档** |
| 小红书 | 千帆/专业号开放平台 | 🔴 高/不确定 | 电商订单 API 开放度仍在演进 | **需查官方文档确认可用性** |

**国内平台共性障碍**：面向云端 ISV 的签名鉴权 + 资质审核 + 订单 scope 授权；桌面本地 App 保存 app secret 与本地优先架构存在安全张力（属后置设计点）。

---

## 5. MVP 决策（已固定）

| 项 | 决策 |
|---|---|
| 第一平台 | **Shopify** |
| Shopify API | **GraphQL Admin API**（REST Admin API 已 legacy，不作主方案） |
| 鉴权 | **单店 custom app token** |
| 同步方式 | **手动拉单**（「立即拉单」按钮），不做后台调度 |
| 数据落点 | 先落 **`ecommerce_staged_orders` 暂存**，**不直写 `sales`** |
| 提交 | **用户确认后**才 batch 写 `sales/sales_items` |
| 费用 / 退款 | **MVP 仅暂存展示，不自动入账** |
| 多币种 | **MVP 先限制单店铺币种，不先给 `sales` 加 currency** |

**第二连接器**：WooCommerce（REST consumer key/secret 模型保留），用于验证 provider 接口对 GraphQL / REST 两类传输的泛化性。

**待你 / 会计师确认的开放问题**（不阻塞 MVP 拉单/暂存/预览，仅阻塞入账相关的后置 PR）：
- 订单目标模型 = `sales/sales_items`（推荐）还是 `transactions`？
- 平台费用 = 经营费用 vs COGS？（会计红线）
- 退款/取消的收入与税额冲回政策？（会计红线）
- 平台「已付未结算」是否确认为应收？结算/回款时点？

---

## 6. 拟定字段与约束（供 PR1 定稿）

> **修正**：schema additive migration 落地（PR1）**前**，先在此明确字段与唯一约束。以下为**定稿草案**；实际列到平台字段的映射需在实现时按官方文档核对。均为**纯新增（additive）**，不改任何会计含义列。

### 6.1 `sales` 新增列（幂等）

```
ALTER TABLE sales ADD COLUMN external_order_id TEXT;   -- 平台订单号(可空; 手动/CSV 记录为 NULL)
ALTER TABLE sales ADD COLUMN platform_source   TEXT;   -- 'shopify' | 'woocommerce' | ...(可空)

-- 幂等唯一约束: 用「部分唯一索引」避免与手动/CSV 的 NULL 记录冲突
CREATE UNIQUE INDEX idx_sales_ext_order
  ON sales(platform_source, external_order_id)
  WHERE external_order_id IS NOT NULL AND platform_source IS NOT NULL;
```
> 说明：SQLite 中多个 NULL 在 UNIQUE 下互不相等，但仍用部分唯一索引显式表达「仅对平台订单去重」，语义更清晰。

### 6.2 新表 `ecommerce_connections`（连接 + 凭证 + 游标）

```
CREATE TABLE ecommerce_connections (
  id                    TEXT PRIMARY KEY,
  platform              TEXT NOT NULL,          -- 'shopify' | 'woocommerce' | ...
  label                 TEXT,                   -- 用户可读店铺名
  shop_identifier       TEXT,                   -- 非敏感: myshop.myshopify.com / 站点URL
  credentials_encrypted TEXT NOT NULL,          -- safeStorage 密文(base64), JSON: {token} 或 {key,secret}
  store_currency        TEXT,                   -- MVP 单店铺币种
  enabled               INTEGER DEFAULT 1,
  last_cursor           TEXT,                   -- 增量游标
  last_synced_at        TEXT,
  last_order_updated_at TEXT,
  created_at            TEXT DEFAULT (datetime('now')),
  updated_at            TEXT DEFAULT (datetime('now'))
);
```

### 6.3 新表 `ecommerce_staged_orders`（暂存/预览）

```
CREATE TABLE ecommerce_staged_orders (
  id                INTEGER PRIMARY KEY AUTOINCREMENT,
  connection_id     TEXT NOT NULL,              -- FK → ecommerce_connections(id)
  platform          TEXT NOT NULL,
  external_order_id TEXT NOT NULL,
  order_updated_at  TEXT,
  normalized_json   TEXT,                       -- 规范化预览: 表头 + items[](已做 PII 最小化, 见 §9)
  raw_excerpt_json  TEXT,                       -- 可选: PII 剥离后的原始片段, 默认不存全量 raw
  match_status      TEXT,                       -- 'matched' | 'partial' | 'unmatched' | 'ambiguous'
  dedup_status      TEXT,                       -- 'new' | 'duplicate' | 'committed'
  status            TEXT DEFAULT 'staged',      -- 'staged' | 'committed' | 'skipped' | 'error'
  committed_sale_id TEXT,                        -- 提交后回填 sales.id
  error             TEXT,
  created_at        TEXT DEFAULT (datetime('now')),
  updated_at        TEXT DEFAULT (datetime('now'))
);

CREATE UNIQUE INDEX idx_staged_conn_order
  ON ecommerce_staged_orders(connection_id, external_order_id);   -- 同连接同单不重复暂存
```

### 6.4 新表 `ecommerce_sync_log`（拉单/错误日志）

```
CREATE TABLE ecommerce_sync_log (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  connection_id TEXT,
  run_at        TEXT,
  pulled        INTEGER DEFAULT 0,
  staged        INTEGER DEFAULT 0,
  duplicates    INTEGER DEFAULT 0,
  errors        INTEGER DEFAULT 0,
  cursor_before TEXT,
  cursor_after  TEXT,
  error_json    TEXT,
  created_at    TEXT DEFAULT (datetime('now'))
);
```

> 目标 schema 版本：**v21（additive）**。迁移应在 `test-migrations` / `test-handlers` 增加对应场景。**PR1 前需最终确认以上字段。**

---

## 7. 关键风险与政策

### 7.1 凭证备份/迁移风险（safeStorage）

**事实依据**：现有备份 bundle（`electron/handlers/_backupBundle.js`）是对 `sololedger.db` 的**整库文件复制**。这意味着：

- 备份会**连带复制** `ai_providers.api_key_encrypted`；未来也会**连带复制** `ecommerce_connections.credentials_encrypted`。
- `electron.safeStorage` 密文是**机器 / OS 用户绑定**的（macOS Keychain、Windows DPAPI、Linux Secret Service）。
- 后果：把备份恢复到**另一台机器 / 另一 OS 用户**时，`safeStorage.decryptString` 会**失败**，凭证静默不可用。

**约束（连接器实现必须遵守）**：
- **绝不存明文**；凭证只以 safeStorage 密文入库。
- **不做「密文可跨机恢复」的误导性承诺**：文档/UI 需说明「凭证与本机绑定，换机恢复后需重新录入」。
- 跨机/跨用户恢复后，连接进入「需重新授权」状态，UI 引导用户重新录入 token/key。
- 评估选项（后续 PR 决定）：导出时**剥离**凭证列，或恢复时检测 safeStorage 解密失败并显式提示重新录入。**不得默认给用户「恢复即可用」的假象。**

### 7.2 PII 最小化

- 买家 **姓名/邮箱/电话/地址默认脱敏**（如姓名保留姓氏 + 掩码，其余仅在用户显式开启时存储）。
- 暂存表 `normalized_json` **只保留记账必要字段**；默认**不持久化平台原始全量 payload**；`raw_excerpt_json` 若保留也须先做 PII 剥离。
- 账本 `sales.customer` 建议存**脱敏后买家标识**或订单号，而非完整个人信息。
- marketplace 各自的买家数据使用/留存条款需在接入具体平台时确认（**后续需查官方文档/政策确认**）。

### 7.3 会计红线（**不得触碰**）

- `electron/reports/*`（cn/us/jp/kr/eu/tw、`_cashflow`、`_expenseSplit`、`_reportSource`、`usTaxParams`）
- COGS 逻辑、库存加权平均/成本（`inventory.js` 聚合）、VAT/所得税公式、`categories` seed 与税表映射
- **不自动把平台费判为 COGS**；**不自动冲回退款/税额**
- **不改** 表头=Σ明细 不变量与 `_lineItems` 数学
- **拉单不直写账本**（只落暂存）；**不引入云后端 / 不复活 Web 架构**

---

## 8. PR 拆分

| PR | 内容 | 风险 | 备注 |
|---|---|---|---|
| **PR0** | **仅** `docs/ecommerce-connector-plan.md`（本文件），**无代码** | 无 | 当前 PR |
| **PR1** | schema **v21 additive** 迁移（§6 四项：sales 两列 + 唯一约束 + 三张新表）+ 迁移/handler 测试。**落地前以本文件 §6 字段定稿为准** | 中 | 需批准 |
| **PR2** | connector 脚手架：**通用 provider 接口**（`_providerInterface`）+ GraphQL/REST 传输助手 + Shopify GraphQL adapter（先只 `testConnection`）+ 凭证复用 + IPC 路由 + 设置页连接 UI。**暂不拉单**。含 provider 守卫测试 | 中 | 需批准；**脚手架必须含通用接口，不只是 REST 工厂** |
| **PR3** | 拉单 → 暂存（分页/限流/游标/同步日志），**对账本只读** | 中 | 需批准 |
| **PR4** | 预览 UI（克隆 CsvImportModal）+ 商品解析 + 去重展示（**仍不提交**） | 低 | 需批准 |
| **PR5** | 暂存 → 提交 `sales/sales_items`（batch + 幂等去重 + 全或无）—— **首次真正写账本** | 高 | 需批准，最高谨慎 |
| **PR6（后置）** | 平台费/退款/结算入账 —— **政策决策，需会计师** | 高 | 暂缓 |

---

## 9. 验证与人工 QA

### 9.1 验证命令

- UI/i18n（PR2/4）：`npm run check:all` · `npm run typecheck` · `npm run build` · `npm run test:locale-ui`
- schema/handler（PR1/3/5）：`npm run check:migrations` · `npm run check:handlers` · `npm run check:all` · `npm run typecheck` · `npm run build`
  - 本机 better-sqlite3 ABI 会 SKIP handlers/migrations → 用既有流程真跑：`npm rebuild better-sqlite3` → `npm run check:handlers` → `npm run electron:rebuild`
- 真 IPC/凭证/出网（PR2/3/5）：`npm run test:electron`

### 9.2 人工 QA（Shopify 开发店铺 + custom app token）

1. 测试连接：错误 token 报友好错误、不泄密。
2. 拉样例订单 → 暂存表出现、账本**零变化**。
3. 预览：多明细正确、SKU→商品匹配、同名歧义可人工选、未匹配走 description-only。
4. **幂等**：重复拉单/重复提交，唯一约束拦截，无重复入账。
5. 提交后校验 `sales` 表头 = Σ`sales_items`、`shippingCost` 表头级不进明细。
6. **安全**：凭证密文只在 `ecommerce_connections`，明文永不回渲染进程/日志。
7. **备份/换机**：验证 §7.1——换机恢复后连接提示重新录入，不出现「恢复即可用」假象。
8. **PII**：验证 §7.2——买家敏感字段默认脱敏，暂存不持久化全量原始 payload。
9. 断网/限流：退避重试正常，同步日志记录错误。

---

## 10. 官方文档待确认清单（不臆造字段）

- **Shopify GraphQL Admin API**：订单查询字段、line items / shipping / refunds / transactions 结构、custom app token 权限 scope、游标翻页与限流（cost-based）——**必须按官方 GraphQL 文档确认**。
- **WooCommerce REST API**：consumer key/secret 生成与鉴权、orders 端点字段、翻页参数——按官方文档确认（官方说明 REST API 使用 generated consumer key/secret）。
- 国内平台（淘宝/京东/拼多多/抖店/小红书）：签名算法、订单 scope、ISV/服务商资质要求、桌面端持 secret 的合规性——**逐一按官方文档确认**。
- 各平台买家 PII 使用/留存条款——按平台政策确认。
