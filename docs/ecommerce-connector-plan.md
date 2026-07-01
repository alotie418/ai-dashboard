# 电商平台接入 · 连接器架构与多平台目录计划

> 状态：**设计文档（只读产出）**。本文件不改 schema、不改运行代码。
> 基线：main `c44bb92` / #330 · schema **v21**（`ecommerce_connections` 已上线）。
> 进度：**#329（本设计文档初版）已合并**；**#330（Shopify 连接设置 MVP）已合并** —— Shopify 连接管理 + safeStorage 加密凭证 + `testConnection` 已落地（仅连接设置，未拉单、未写账本）。
> 本次修订：目标平台扩展为 **11 个**、按**三档**分层、系统设置改为**平台目录**、provider 接口写入 **5 种 authMode**、修正后续代码 PR 范围（Shopify 已完成，下一步只补 WooCommerce）。

---

## 0. 目的与安全底线

为「主流电商平台订单数据接入」建立一套**统一连接器架构 + 多平台目录**，让订单能被安全导入本地账本。

贯穿全程的安全底线（不可协商）：

1. **拉单绝不直接写正式账本**：所有拉取的订单先落 `ecommerce_staged_orders` 暂存区，用户显式确认后才走既有 batch 写入路径进入 `sales/sales_items`。
2. **可预览、可回滚、可幂等**：预览复用现有 CSV 导入的暂存/预览 UX；提交按外部单号幂等去重；每一步都能回滚。
3. **不碰会计红线**：不改 `electron/reports/*`、COGS、税率/税额公式、`_expenseSplit`、库存成本、`categories` 税表映射；平台费/退款/COGS 判定一律留给会计师确认。
4. **本地优先**：连接器出网发生在 Electron 主进程（与现有 AI provider 一致），不引入云后端、不复活 Web 架构。**例外**：部分高门槛平台可能需要最小云端 OAuth/签名组件（见 §7.4），但账本数据始终本地。
5. **禁止让客户输入平台账号密码**：所有连接**只接受平台签发的 token / key-secret / OAuth 授权**。任何平台连接器**都不得**提供「平台登录账号 + 密码」输入，绝不收集、不传输、不存储平台账号密码。这是硬约束。

---

## 1. 现状盘点（订单导入相关）

### 1.1 账本与连接数据结构（schema v21）

| 表 | 版本 | 关键列 |
|---|---|---|
| `sales` | v1/v10/v20 | `id`(TEXT PK)、`date`、`customer`、`totalAmount`/`amountWithoutTax`/`taxAmount`/`taxRate`、`shippingCost`（**仅销售·表头级**）、`invoiceNumber`/`invoiceStatus`、`payment_status`/`paid_amount`/`due_date`/`payment_date`、`product_id`/`product_name_snapshot`/`unit_snapshot`、legacy `tons`/`pricePerTon`。**无 currency 列·无外部单号列** |
| `sales_items` | v20 | `id`(INT PK)、`sale_id`(FK→sales ON DELETE CASCADE)、`line_no`、`product_id`（软引用）、`description`、`unit_snapshot`、`quantity`、`unit_price`、`amount_net`、`tax_rate`、`tax_amount`、`amount_gross` |
| `purchases` / `purchase_items` | v1/v20 | 与销售对称，`purchase_items` 无 shippingCost |
| `transactions` | v5 | 规范化收支流水；**唯一带外部元数据位** `source_meta`(JSON)，带 `currency` |
| `products` | v9 | `id`(TEXT PK)、`name`、`unit`、`default_unit_cost`、`is_service`、`is_active` |
| `categories` | v4/v13 | 科目分类，含 `is_cogs`（**红线相关**） |
| `settings` | v1 | KV JSON + 白名单 `SETTINGS_ALLOWED_KEYS` |
| `ai_providers` | v2 | `provider`(PK)、`api_key_encrypted`（safeStorage 密文 base64）、`model`、`enabled`、`is_default` —— **凭证存储范式** |
| **`ecommerce_connections`** | **v21（#330 已上线）** | `id`(TEXT PK)、`platform`、`label`、`shop_identifier`（非敏感明文）、`credentials_encrypted`（safeStorage 密文）、`store_currency`、`enabled`、`last_test_at`、`last_test_ok`。**仅连接设置，无游标/暂存/拉单列** |
| `legacy_migrations` | v5 | `UNIQUE(legacy_table, legacy_id)` —— **幂等去重范式** |

**关键不变量**：表头金额 = Σ 明细 `amount_gross`；`shippingCost` 为表头级、不进明细求和。订单落库必须遵守。

### 1.2 现存缺口

1. `sales/purchases/transactions` 均无外部单号/平台来源列，无去重唯一约束（除 PK）。
2. 无客户/供应商主数据表（自由文本）。
3. 无应收/应付实体表（由 `payment_status + paid_amount` 实时派生）。
4. 无 sync/cursor/job/webhook 基础设施（`ecommerce_connections` 也未含游标列 —— 拉单 PR 再加）。
5. **`sales/sales_items` 无 currency 列** → 跨境多币种是真实缺口（见 §6 决策）。

### 1.3 可复用基础设施（大量可复用）

| 能力 | 现有实现 | 复用方式 |
|---|---|---|
| Provider 注册表 | `electron/ai/index.js` 的 `PROVIDERS` 对象 + 适配器工厂 | 已克隆为 `electron/ecommerce/index.js` 的 `ECOMMERCE_PROVIDERS` + **通用 provider 接口**（#330 落地） |
| 凭证加密 | `electron.safeStorage`（encrypt→base64→SQLite），明文只在内存、永不回渲染进程 | **已复用**：`ecommerce_connections.credentials_encrypted`（#330） |
| 设置存储 | `settings` KV + 白名单 | 存非敏感连接配置 |
| IPC / 路由 | `api:request {method,path,body}` + `router.js dispatch()`；provider 走 `providers:*` 直通 IPC | 已加 `ecommerce:*` 直通 IPC（#330） |
| 批量写入 | `batch.js` 两遍式（先全校验零写入→单事务全写）+ 全或无 + `_lineItems` | **提交阶段复用**，加去重 |
| 暂存/预览 UX | `CsvImportModal`（上传→映射→预览→结果）+ `resolveProduct` 保守匹配 + 全或无禁用按钮 | **克隆为订单预览模态** |
| 主进程出网 | AI provider 已用主进程 `fetch()` 调 HTTPS；渲染进程无网络权限（contextIsolation） | 电商 API 调用同样放主进程（Shopify 已这么做） |
| 后台同步/游标 | ❌ 无 | **需新建**（MVP 仅手动拉单，不做后台调度） |

**守卫无阻**：`check:no-web-fetch` 只禁前端 `fetch('/api'|'/auth')` 与 Web 回退残留；`check:offline` 只禁资产 CDN，并明确「运行时 API 端点属网络调用、不在禁止之列」。→ 主进程调电商 API 与现有 AI 出网完全同构。

---

## 2. 订单导入落点

| 目标 | 落点 | 说明 / 风险 |
|---|---|---|
| sales（表头） | ✅ 一订单 = 一 `sales` | `date`=下单日、`customer`=买家（脱敏，见 §8.2）、`shippingCost`=运费行合计（表头级）、`payment_status`←平台支付态、`invoiceNumber`=订单号或空 |
| sales_items | ✅ 一订单行 = 一 `sales_items` | 复用现有明细口径，表头 = Σ明细 |
| products | ✅ 按 SKU→`product_id`，其次精确名匹配 | 复用 `resolveProduct` 保守策略：命中 / 未命中（description-only 不计库存）/ 同名歧义（阻断，人工选） |
| transactions | ⚠️ **MVP 不双写** | 系统存在 sales↔transactions 双模型；订单进多明细 `sales` 模型即可，**勿同时写 transactions 造成重复** |
| receivables | ✅ 无需写表，实时派生 | 平台「已付未结算」是否算应收 = 政策决定，需确认 |
| platform fees | 🔴 **不自动入账** | 现无平台费模型；opex vs COGS 属会计红线，MVP 仅暂存展示 |
| refunds / cancellations | 🔴 **不自动冲账** | 收入/税额冲回涉会计政策；MVP 仅暂存为信息，未导入订单的取消直接跳过 |

---

## 3. 统一连接器架构（provider 接口 + 5 种 authMode）

抽象核心是**通用、传输无关的 provider 接口**（非「纯 REST 工厂」），允许 GraphQL / REST 等多种传输实现。#330 已落地接口 + Shopify GraphQL adapter。

```
electron/ecommerce/
  index.js                       # 连接注册表 + 管理(list/save/test/setEnabled/remove)  ← 已落地(#330)
  providers/
    _providerInterface.js        # 【通用 provider 接口 / 契约定义 + 运行时校验】  ← 已落地(#330)
    shopify.js                   # GraphQL adapter · authMode=manual_token · 仅 testConnection  ← 已落地(#330)
    woocommerce.js               # REST adapter · authMode=key_secret                          ← PR-EC2
    _graphqlTransport.js / _restTransport.js   # 可选传输助手（多连接器共用时再抽）
electron/handlers/index.js       # 已注册 ecommerce:* IPC（providers/list/save/test/setEnabled/remove）
```

### 3.1 provider 接口 authMode（5 种，写入 meta）

`provider.meta.authMode` 声明该平台的鉴权类型，UI 与连接管理据此分流表单与流程：

| authMode | 含义 | 客户需提供 | 典型平台 | 纯桌面本地可完成？ |
|---|---|---|---|---|
| `manual_token` | 用户在平台后台自行生成的长期访问令牌，直接粘贴 | 店铺域名 + Admin token | **Shopify**（单店 custom app） | ✅ 是 |
| `key_secret` | 一对 consumer key + secret，HTTPS 签名/基础认证 | 站点 URL + key + secret | **WooCommerce** | ✅ 是 |
| `oauth2` | 标准 OAuth 2.0 授权码流程，需回调地址 + 授权页 | 点击「授权」跳转平台同意页 | Amazon(SP-API·LWA)、TikTok Shop、TEMU、SHEIN（**待确认**） | ⚠️ 可能需云端回调（§7.4） |
| `signed_openapi` | app key/secret + 按平台算法对每个请求签名（MD5/HMAC/SHA） | 商家授权（服务商代调） | 淘宝天猫(TOP)、京东(宙斯)、拼多多、抖店（**待确认**） | ⚠️ app secret 托管问题（§7.4） |
| `partner_authorization` | 需成为平台服务商/ISV/合作伙伴、应用过审 + 商家授权后才有订单调用权 | 平台侧资质 + 商家授权链路 | 多数国内平台 + 部分海外 marketplace 的订单 scope | ⚠️ 通常需云端组件（§7.4） |

> 单一平台可能**组合多种** authMode（如国内平台常是 `signed_openapi` + `partner_authorization`）。上表映射为**架构层预判，均需按各平台官方文档确认**（见 §10），本文件不臆造字段/算法。

### 3.2 接口契约（含未来拉单方法，MVP 不实现）

```
interface EcommerceProvider {
  meta: {
    id, name,
    transport: 'graphql' | 'rest' | ...,
    authMode: 'manual_token' | 'key_secret' | 'oauth2' | 'signed_openapi' | 'partner_authorization'
             | Array<上述值>,          // 组合鉴权
    status: 'available' | 'needs_authorization' | 'planned',   // 平台目录状态（§5）
    shopField, credentialFields, docsUrl
  }
  testConnection(creds): Promise<{ ok, storeInfo?, code?, providerMessage? }>   // 已实现(Shopify)
  // ↓ 未来阶段，MVP/PR-EC2 均不实现：
  pullOrders?(creds, { since, cursor, pageSize }): Promise<{ orders, nextCursor, rateLimit }>
  normalizeOrder?(raw): NormalizedOrder   // 平台差异只在此收敛：表头 + items[] + fees + refunds
}
```

- **新增可自助平台** = 新增一个实现该接口的 provider 文件 + 注册进 `ECOMMERCE_PROVIDERS`（WooCommerce 即走此路）。
- **高门槛平台** = 目录里先占位（`status: 'planned' | 'needs_authorization'`）、**不实现 API、不建连接器、不写 schema 特化字段**，等云端 OAuth/签名方案（§7.4）与官方文档确认后另开 PR。

---

## 4. 目标平台目录（11 平台 · 三档）

> 下表为**架构层判断**；各平台**精确鉴权流程、端点、字段名、限流、资质门槛均需查官方文档确认**（§10），本文件不臆造字段。

### 第一批 · 可自助接入（🟢 低门槛，用户自行在平台后台生成凭证）

| 平台 | authMode | 传输 | 状态 | 备注 |
|---|---|---|---|---|
| **Shopify** | `manual_token` | GraphQL Admin API | ✅ **已上线(#330)** | 单店 custom app token；REST Admin API 已 legacy，用 GraphQL |
| **WooCommerce** | `key_secret` | REST | 🔜 **PR-EC2（下一步）** | 官方 REST API 用 generated consumer key/secret；依赖商户已启用 REST API |

### 第二批 · 需平台应用 / OAuth / 授权审核（🟠 中高门槛）

| 平台 | authMode（拟·待确认） | 状态 | 备注 |
|---|---|---|---|
| **Amazon** | `oauth2`(SP-API·LWA) + `partner_authorization` | `needs_authorization` | 需注册开发者 + SP-API 应用；订单 scope 需授权；**需查官方文档** |
| **TikTok Shop** | `oauth2` + `partner_authorization` | `needs_authorization` | 需 TikTok Shop Partner/开放平台应用与授权；**需查官方文档** |
| **TEMU** | `oauth2` / `partner_authorization` | `needs_authorization` | 开放平台/合作方接入；**需查官方文档确认可用性** |
| **SHEIN** | `oauth2` / `partner_authorization` | `needs_authorization` | 开放平台/合作方接入；**需查官方文档确认可用性** |

### 第三批 · 后置（🔴 高门槛，多为面向云端 ISV 的签名开放平台）

| 平台 | authMode（拟·待确认） | 状态 | 备注 |
|---|---|---|---|
| **拼多多** | `signed_openapi` + `partner_authorization` | `planned` | 开放平台签名 + 订单类权限申请；**需查官方文档** |
| **淘宝 / 天猫 (TOP)** | `signed_openapi` + `partner_authorization` | `planned` | app key/secret + 签名；交易类 API 常需服务商/ISV 资质；**需查官方文档** |
| **京东 (宙斯)** | `signed_openapi` + `partner_authorization` | `planned` | 面向云端 ISV；订单 API 需资质；**需查官方文档** |
| **抖店** | `signed_openapi` + `oauth2` + `partner_authorization` | `planned` | app 注册 + 授权 + 签名；订单权限需申请；**需查官方文档** |
| **小红书** | `partner_authorization`（开放度演进中） | `planned` | 千帆/专业号开放平台；电商订单 API 开放度仍在演进；**需查官方文档确认可用性** |

**第二/三档共性障碍**：面向云端 ISV 的签名鉴权 / OAuth 回调 + 资质审核 + 订单 scope 授权；桌面本地 App 保存 app secret 与本地优先架构存在张力（见 §7.4，属后置设计点）。

---

## 5. 系统设置：平台目录 UI 设计

设置页「电商平台接入」是一个**平台目录（catalog）**，**不是所有平台都能立即连接**。

- **目录列出全部 11 个平台**，每平台一张卡，卡上带**状态徽标**（来自 `provider.meta.status`）：
  - `available`（可连接）—— 一档：显示「添加连接」按钮，可立即录入凭证并测试（**Shopify 已上线**；**WooCommerce 待 PR-EC2**）。
  - `needs_authorization`（需授权 · 即将支持）—— 二档：卡片展示，但**连接按钮禁用/置灰**，注明「需平台应用 / OAuth / 审核」，附官方接入文档链接。
  - `planned`（规划中）—— 三档：仅占位展示 + 「后置」说明，不提供任何输入。
- **目录数据来自 provider registry**（`ecommerce:providers` 返回每平台 meta，含 `status` 与 `authMode`）。**未实现连接器的平台只有目录占位元数据**，不提供 API、不建连接器、不写 schema 特化字段。
- **表单按 authMode 分流**（仅对 `available` 平台开放）：
  - `manual_token` → 域名 + token（Shopify 现状）。
  - `key_secret` → 站点 URL + consumer key + consumer secret（WooCommerce，PR-EC2）。
  - `oauth2` / `signed_openapi` / `partner_authorization` → **本阶段不出表单**（置灰 + 说明），待 §7.4 云端方案确认。
- **绝不出现「平台账号 + 密码」输入**（§0 硬约束）；表单只接受平台签发的 token/key-secret 或跳转 OAuth 授权。
- 已保存连接沿用 #330 现状：状态徽标（启用/禁用）、最近测试时间、测试/启停/删除、safeStorage 换机需重录提示（§7.1）。

---

## 6. 路线决策（Shopify 已完成，下一步 WooCommerce）

| 项 | 决策 |
|---|---|
| 已完成 | **Shopify 连接设置**（#330）：`manual_token` · GraphQL Admin API · safeStorage 加密 · `testConnection` · 设置页可添加/测试/启停/删除 |
| 下一步代码 | **PR-EC2 = WooCommerce 连接器（`key_secret`）+ 设置页改平台目录（11 平台状态徽标）+ provider 接口泛化到 5 种 authMode** |
| 其余 9 平台 | **仅目录/UI 状态预留**（`needs_authorization` / `planned`）：**不实现 API、不建连接器、不写 schema 特化字段** |
| 同步方式 | **手动拉单**（后续拉单 PR），不做后台调度 |
| 数据落点 | 拉单先落 `ecommerce_staged_orders` 暂存，**不直写 `sales`** |
| 提交 | **用户确认后**才 batch 写 `sales/sales_items` |
| 费用 / 退款 | **仅暂存展示，不自动入账**（需会计师） |
| 多币种 | **先限单店铺币种**，暂不给 `sales` 加 currency |

**待你 / 会计师确认的开放问题**（不阻塞连接设置/目录，只阻塞入账相关的后置 PR）：
- 订单目标模型 = `sales/sales_items`（推荐）还是 `transactions`？
- 平台费用 = 经营费用 vs COGS？（会计红线）
- 退款/取消的收入与税额冲回政策？（会计红线）
- 平台「已付未结算」是否确认为应收？结算/回款时点？

---

## 7. 拟定 schema 字段与约束（拉单 PR 前定稿）

> `ecommerce_connections` 已在 **v21（#330）** 上线（仅连接设置列，见 §1.1）。以下为**拉单/提交阶段**才需要的**新增草案**，均为 additive、不改会计含义列；**落地前需最终确认**。

### 7.1 `ecommerce_connections` 增量（拉单 PR 再加游标列）

```
-- 拉单 PR 才加，本 PR 与 PR-EC2 均不加：
ALTER TABLE ecommerce_connections ADD COLUMN last_cursor           TEXT;
ALTER TABLE ecommerce_connections ADD COLUMN last_synced_at        TEXT;
ALTER TABLE ecommerce_connections ADD COLUMN last_order_updated_at TEXT;
```

### 7.2 `sales` 新增列（幂等，拉单/提交 PR）

```
ALTER TABLE sales ADD COLUMN external_order_id TEXT;   -- 平台订单号(可空; 手动/CSV 记录为 NULL)
ALTER TABLE sales ADD COLUMN platform_source   TEXT;   -- 'shopify' | 'woocommerce' | ...(可空)

-- 幂等唯一约束: 用「部分唯一索引」避免与手动/CSV 的 NULL 记录冲突
CREATE UNIQUE INDEX idx_sales_ext_order
  ON sales(platform_source, external_order_id)
  WHERE external_order_id IS NOT NULL AND platform_source IS NOT NULL;
```

### 7.3 新表 `ecommerce_staged_orders`（暂存/预览，拉单 PR）

```
CREATE TABLE ecommerce_staged_orders (
  id                INTEGER PRIMARY KEY AUTOINCREMENT,
  connection_id     TEXT NOT NULL,              -- FK → ecommerce_connections(id)
  platform          TEXT NOT NULL,
  external_order_id TEXT NOT NULL,
  order_updated_at  TEXT,
  normalized_json   TEXT,                       -- 规范化预览: 表头 + items[](已做 PII 最小化, 见 §8.2)
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

### 7.4 新表 `ecommerce_sync_log`（拉单/错误日志，拉单 PR）

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

> **PR-EC2（WooCommerce + 平台目录 + authMode 泛化）不新增任何 schema**——它只复用现有 `ecommerce_connections`（v21）。上述字段在**拉单/提交 PR** 才落地并加迁移/handler 测试。

---

## 8. 关键风险与政策

### 8.1 凭证备份/迁移风险（safeStorage）

**事实依据**：现有备份 bundle（`electron/handlers/_backupBundle.js`）是对 `sololedger.db` 的**整库文件复制**。这意味着：

- 备份会**连带复制** `ai_providers.api_key_encrypted` 与 `ecommerce_connections.credentials_encrypted`。
- `electron.safeStorage` 密文是**机器 / OS 用户绑定**的（macOS Keychain、Windows DPAPI、Linux Secret Service）。
- 后果：把备份恢复到**另一台机器 / 另一 OS 用户**时，`safeStorage.decryptString` 会**失败**，凭证静默不可用。

**约束（连接器实现必须遵守）**：
- **绝不存明文**；凭证只以 safeStorage 密文入库。
- **不做「密文可跨机恢复」的误导性承诺**：文档/UI 需说明「凭证与本机绑定，换机恢复后需重新录入」（#330 UI 已含此提示）。
- 跨机/跨用户恢复后，连接进入「需重新授权」状态，UI 引导用户重新录入 token/key。
- 评估选项（后续 PR 决定）：导出时**剥离**凭证列，或恢复时检测 safeStorage 解密失败并显式提示重新录入。**不得默认给用户「恢复即可用」的假象。**

### 8.2 PII 最小化

- 买家 **姓名/邮箱/电话/地址默认脱敏**（如姓名保留姓氏 + 掩码，其余仅在用户显式开启时存储）。
- 暂存表 `normalized_json` **只保留记账必要字段**；默认**不持久化平台原始全量 payload**；`raw_excerpt_json` 若保留也须先做 PII 剥离。
- 账本 `sales.customer` 建议存**脱敏后买家标识**或订单号，而非完整个人信息。
- marketplace 各自的买家数据使用/留存条款需在接入具体平台时确认（**后续需查官方文档/政策确认**）。

### 8.3 会计红线（**不得触碰**）

- `electron/reports/*`（cn/us/jp/kr/eu/tw、`_cashflow`、`_expenseSplit`、`_reportSource`、`usTaxParams`）
- COGS 逻辑、库存加权平均/成本（`inventory.js` 聚合）、VAT/所得税公式、`categories` seed 与税表映射
- **不自动把平台费判为 COGS**；**不自动冲回退款/税额**
- **不改** 表头=Σ明细 不变量与 `_lineItems` 数学
- **拉单不直写账本**（只落暂存）

### 8.4 高门槛平台的云端 OAuth / app secret 托管（重大架构决策 · 后置）

一档（`manual_token` / `key_secret`）**纯桌面本地即可完成**：用户在平台后台生成凭证 → 本地 safeStorage 加密 → 主进程直连平台 API，**无需任何云端**。

二/三档（`oauth2` / `signed_openapi` / `partner_authorization`）**不能默认纯桌面本地完成**：

- **OAuth2 回调**：授权码流程需要一个**固定公网回调地址（redirect URI）**，桌面 App 无固定公网入口，可能需要**云端 OAuth callback 中转**（接住授权码 → 换 token → 回传桌面端）。
- **app secret 保管**：平台 App 的 `app secret` 通常要求保密；桌面端本地保存 app secret 可被逆向提取，平台合规上常要求 secret **只存服务端** → 可能需要**云端签名代理 / app secret 托管**（桌面端发未签名请求 → 云端签名转发）。
- **结论**：高门槛平台是否引入一个**最小云端组件**（仅做 OAuth 回调 + 签名代理）需**单独设计并经你确认**——这与「本地优先」存在张力，属重大架构决策，**后置**。
- **红线**：即便引入云端 OAuth/签名组件，**账本数据仍全部本地**，云端只承担授权中转/请求签名，**不存业务数据、不存明文账本、不做记账**。

---

## 9. PR 拆分（修正后）

| PR | 内容 | 状态 / 风险 |
|---|---|---|
| **设计文档 #329** | 本文件初版（连接器架构 + Shopify MVP 计划） | ✅ **MERGED**（main `ed98aed`） |
| **本次文档修订** | 11 平台目录 + 三档 + 5 种 authMode + 平台目录 UI 设计 + 范围修正 | 📄 **当前 PR（仅本文档，无代码）** |
| **PR-EC1 · Shopify 连接设置 #330** | schema v21 `ecommerce_connections` + 通用 provider 接口 + Shopify `manual_token` `testConnection` + 设置页 | ✅ **MERGED**（main `c44bb92`） |
| **PR-EC2 · WooCommerce + 平台目录 + authMode 泛化（下一步代码）** | WooCommerce 连接器（`key_secret`）+ 设置页改**平台目录**（11 平台状态徽标）+ provider 接口 meta 加 **5 种 authMode + status**；**其余 9 平台仅目录占位**，不实现 API、不写 schema 特化字段。**不新增 schema**（复用 v21） | 中 · 需批准 |
| **PR-EC3 · 拉单 → 暂存** | 加 §7 schema（sales 幂等列 + staged_orders + sync_log + connections 游标列）+ 手动拉单 + 分页/限流/游标 + 同步日志，**对账本只读** | 中 · 需批准 |
| **PR-EC4 · 预览 UI** | 克隆 `CsvImportModal` + 商品解析 + 去重展示（**仍不提交**） | 低 · 需批准 |
| **PR-EC5 · 暂存 → 提交** | batch 写 `sales/sales_items` + 幂等去重 + 全或无 —— **首次真正写账本** | 高 · 需批准，最高谨慎 |
| **PR-EC6（后置 · 需会计师）** | 平台费 / 退款 / 结算入账 —— 政策决策 | 高 · 暂缓 |
| **二/三档平台接入（各自独立 PR）** | Amazon/TikTok/TEMU/SHEIN + 国内平台；多数需先解决 §8.4 云端 OAuth/签名 + 官方文档确认 | 高 · 后置 |

---

## 10. 验证与人工 QA

### 10.1 验证命令

- UI/i18n（PR-EC2/4）：`npm run check:all` · `npm run typecheck` · `npm run build` · `npm run test:locale-ui`
- schema/handler（PR-EC3/5）：`npm run check:migrations` · `npm run check:handlers` · `npm run check:all` · `npm run typecheck` · `npm run build`
  - 本机 better-sqlite3 ABI 会 SKIP handlers/migrations → 用既有流程真跑：`npm rebuild better-sqlite3` → `npm run check:handlers`/`check:migrations` → `npm run electron:rebuild`
- 真 IPC/凭证/出网（PR-EC2/3/5）：`npm run test:electron`

### 10.2 人工 QA

- **PR-EC2（WooCommerce + 目录）**：目录显示 11 平台正确分档/状态；一档可添加连接、二三档置灰不可连；WooCommerce 用 key/secret 测试连接（错误→友好报错不泄密，正确→显示站点信息）；**确认无任何「账号+密码」输入**；账本零变化。
- **拉单/提交 PR** 沿用（Shopify 开发店铺 + token）：拉样例订单→暂存出现、账本零变化；预览多明细/商品匹配；幂等重复拉/提交不重复；提交后表头=Σ明细；换机恢复提示重录；PII 脱敏；断网退避重试。

---

## 11. 官方文档待确认清单（不臆造字段）

- **Shopify GraphQL Admin API**：订单查询字段、line items / shipping / refunds / transactions 结构、custom app token 权限 scope、游标翻页与限流、季度 API 版本（`SHOPIFY_API_VERSION` 常量需每季度维护）。
- **WooCommerce REST API**：consumer key/secret 生成与鉴权、orders 端点字段、翻页参数（官方说明 REST API 使用 generated consumer key/secret）。
- **Amazon SP-API**：LWA/OAuth2 授权、开发者/应用注册、Orders API scope、限流；回调与 app secret 托管要求（§8.4）。
- **TikTok Shop / TEMU / SHEIN 开放平台**：应用注册与授权流程、订单 API 可用性与 scope、OAuth 回调、限流 —— **逐一按官方文档确认可用性**。
- **国内平台**（拼多多 / 淘宝天猫 TOP / 京东宙斯 / 抖店 / 小红书）：签名算法、订单 scope、ISV/服务商资质要求、桌面端持 app secret 的合规性与云端托管必要性（§8.4）—— **逐一按官方文档确认**。
- 各平台**买家 PII 使用/留存条款** —— 按平台政策确认。
- 各平台 **authMode 组合**（§3.1 映射为预判）—— 以官方文档为准。
