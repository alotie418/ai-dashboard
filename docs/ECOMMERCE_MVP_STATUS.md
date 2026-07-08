# 电商订单接入 · MVP 状态与能力清单

> 状态：**收尾状态文档（只读产出）**。本文件不改 schema、不改运行代码。
> 基线：main `e83ca5d` / #339 · schema **v23**。
> 定位口径：本模块是**订单数据导入 → 暂存 → 预览 → 入账辅助**的工具，属**经营管理 / 记账辅助**范畴。
> 它**不是**自动税务合规、自动会计合规、自动报税，也**不是**完整电商 ERP。平台费用 / 退款 / 税额冲回等涉及会计政策的处理**一律留待会计师确认**（见 [EC6 会计决策问题单](./ECOMMERCE_EC6_ACCOUNTANT_QUESTIONS.md)）。

---

## 1. 定位与产品边界

- 本模块把电商平台的**订单数据**导入本地账本，作为**记账与经营分析的输入**。
- 所有拉取的订单先落**暂存区**（`ecommerce_staged_orders`），用户**显式确认**后才写入 `sales / sales_items`。
- 写入的金额是**平台报告的原样数值**（逐行 净额 / 税额 / 含税额），本模块**不自行计算税收政策**、不发明会计科目判定。
- 运费 / 平台费用 / 退款**不进入账本**（见 §5）。
- 与 `CLAUDE.md` 的产品边界一致：**不得**把本模块的输出呈现为官方申报、审计就绪报表或法定合规结果。

---

## 2. 能力清单（截至 #339）

| 领域 | 能力 | 落地 PR |
|---|---|---|
| **连接管理** | Shopify（`manual_token`，锁定 `*.myshopify.com`）/ WooCommerce（`key_secret`，仅 HTTPS，拒 `http://` 与无点号 localhost）；添加 / 测试连接 / 启停 / 编辑 / 删除 | #330 · #332 |
| **凭证安全** | `safeStorage` 加密入库，渲染进程**永不**接触明文或密文；测试连接走**最小只读端点**（Woo `system_status`，不触订单）；出网仅在主进程 | #330 · #332 |
| **平台目录** | 11 平台三档展示（🟢 可自助 / 🟠 需授权 / 🔴 后置）；非可连平台白名单拒绝 `save`/`test`；**禁止任何「账号+密码」输入** | #331 · #332 |
| **拉单暂存** | 手动拉单（每次上限 20 页，超限 `partial` 续拉）；`(connection, external_order_id)` upsert 幂等；水位仅成功推进；每次一行 `ecommerce_sync_log` | #333 |
| **PII 最小化** | 买家姓名 / 邮箱 / 电话 / 地址**永不落库**；原始 payload 不持久化（`raw_excerpt_json` 恒 NULL）；同步日志 / 错误对凭证脱敏 | #333 |
| **预览** | 暂存订单模态：行明细 + 运费 / 税 / 费用 / 退款（**仅信息展示**）；商品按**名称精确**匹配（不使用 SKU），同名歧义标注 | #334 |
| **提交入账** | 两遍式**全或无**（Pass 1 全校验零写入 / Pass 2 单事务）；表头金额 = Σ 明细含税额；四层幂等；整单对账守卫；每单回执含差额分解 | #335 · #336 |
| **孤儿解锁重提** | 删除已入账 sale 后，暂存单可**显式解锁**回到 `staged` 重提；双重存在性检查防重复入账 | #339 |
| **本地自动化测试** | 见 §7 | #333–#339 |

---

## 3. Schema 现状（additive，均不改会计含义列）

| 版本 | PR | 内容 |
|---|---|---|
| **v21** | #330 | `ecommerce_connections`（`id` / `platform` / `label` / `shop_identifier` / `credentials_encrypted` / `store_currency` / `enabled` / `last_test_at` / `last_test_ok`） |
| **v22** | #333 | `ecommerce_connections` 加 3 同步列（`last_cursor` / `last_synced_at` / `last_order_updated_at`）；新表 `ecommerce_staged_orders`（暂存/预览，`stage_status` 默认 `staged`，唯一索引 `(connection_id, external_order_id)`）；新表 `ecommerce_sync_log`。**`sales / sales_items` 此时未被改动。** |
| **v23** | #335 | `sales` 加 3 溯源列 `external_order_id` / `platform_source` / `ecommerce_connection_id`（TEXT，普通列，无 FK）+ 连接级**部分唯一索引** `idx_sales_ec_conn_order` on `(ecommerce_connection_id, external_order_id)`（仅两列非 NULL 时生效，手工 / CSV 记录全 NULL 不受影响）。**`sales_items` 永不加溯源列。** |

迁移守卫：`test-migrations.mjs` block 13（v21）/ block 14（v22，含「v22 时点 sales 尚无溯源列」红线断言）/ block 15（v23）。

---

## 4. 提交拒因码与守卫（写入 `sales` 前的机器可读校验）

提交阶段 19 个稳定拒因码（`commit.js`）：`not_found` · `already_committed` · `not_staged` · `bad_normalized` · `duplicate_external_order` · `status_not_committable` · `has_refunds` · `store_currency_missing` · `currency_missing` · `currency_mismatch` · `date_missing` · `empty_items` · `quantity_invalid` · `amount_missing` · `amount_inconsistent` · `totals_missing` · `total_mismatch` · `ambiguous_product` · `write_failed`。

解锁重提 2 个拒因码（`index.js` `unlockStaged`）：`not_committed` · `sale_still_exists`（`not_found` 复用）。全部有 6 语言 i18n 映射，未知码回退通用失败文案。

关键守卫行为（**均为已实现的保守拦截，非会计政策发明**）：

- **状态白名单 → 收款状态映射**：Shopify `PAID→paid` / `PENDING`、`AUTHORIZED→unpaid`；WooCommerce `completed`、`processing→paid` / `pending`、`on-hold→unpaid`。**其余状态（退款 / 取消 / 部分付款 / 作废等）一律拒绝**（`status_not_committable`）——不猜实付额、不冲退款。
- **含退款订单整单拒**（`has_refunds`）——退款过账策略属 EC6。
- **运费不入账**：`shippingCost` 恒 0（买家付运费 ≠ 卖家运费成本字段）。
- **店铺币种必须先设置**且与订单币种一致，否则拒（`store_currency_missing` / `currency_missing` / `currency_mismatch`）——不猜币种、无多币种折算。
- **整单对账守卫**（`total_mismatch`）：会过账的（Σ 行含税）+ 刻意不过账的（运费 + 运费税）必须约等于平台报告的买家实付总额，否则保守拒绝——把**税含价店铺**（Shopify `taxesIncluded` / Woo `prices_include_tax`，此时行含税额会高估实收）与未拉取的费用挡在账本外，而非过账虚高收入。
- **税率不兜底**：混合 / 缺失的行税率 → 表头 `taxRate` 记 NULL，绝不回退历史默认值。
- **匹配行计派生库存**：名称精确命中活跃商品的行写入 `product_id`（进入既有派生库存读路径）；仅描述行 `product_id` 保持 NULL、不动库存。

---

## 5. 明确不支持 / 暂缓项

1. **平台费用 / 退款不入账**——需会计师确认后由 EC6 处理；含任何退款的订单当前整单拒（`has_refunds`）。
2. **运费不入账**（买家付运费 ≠ 卖家运费成本字段）。
3. **税含价店铺保守拦截**：Shopify `taxesIncluded` / WooCommerce `prices_include_tax` 触发 `total_mismatch` 拒绝，而非错误入账；真正支持需后续拉取含税标志的 provider 改动。
4. **第三方插件 / 平台版本 payload 变异**风险未在真实环境实证（见 §8）。
5. **store_currency 需人工确认**：测试连接不返回币种，未设置即拒。
6. **部分付款**（Shopify `PARTIALLY_PAID` 等）拒——需平台 transactions API 才能知实付额，不猜。
7. **跨币种**：订单币种 ≠ 店铺币种即拒，无多币种折算。
8. **SKU 不参与匹配**（仅名称精确）；同名歧义整单拒。
9. **仅 Shopify manual token + WooCommerce key/secret 两条一档路径**；OAuth / 签名开放平台（9 个高门槛平台）仅目录展示，云端托管属重大架构决策，后置（见 connector-plan §8.4）。
10. **`modified_after` 仅作降量提示**，增量正确性靠暂存 upsert 幂等而非精确服务端过滤。
11. **单次提交上限 100 单**；解锁重提仅单行操作，无批量。
12. **无后台调度 / webhook**：仅手动拉单。

---

## 6. 已知边界（设计使然）

- **删连接重加可重提历史单**：连接级 `(ecommerce_connection_id, external_order_id)` 幂等的固有语义——删除连接后重新添加，历史订单可被重新拉取并再次提交。属已知固有边界。
- **删已入账 sale → 暂存单锁死**：已由 #339 解决——孤儿单可显式解锁重提（双重存在性检查防重复入账）。

---

## 7. 测试覆盖索引（全部并入 `npm run check:all`）

| 套件 | 覆盖 |
|---|---|
| `scripts/test-handlers.mjs` `EC1–EC26` | 连接管理（EC1–EC9）· 拉单→暂存（EC10–EC14）· 暂存→提交（EC15–EC24）· WooCommerce 端到端（EC25：原始 JSON→生产 `normalizeOrder`→真实 `pull`→`commit`）· 解锁重提（EC26：删 sale→孤儿→解锁→重提，含 `sale_still_exists` / `not_committed` / `not_found` / 不写 sync_log 不动水位 / 解锁后 re-pull 刷新） |
| `scripts/test-ecommerce-provider-http.mjs` | 真实 WooCommerce `testConnection` / `pullOrdersPage` 全 HTTP 分支（状态码→拒因、Basic auth、只读端点、`http://` 网络前拦截、无凭证泄露、`X-WP-TotalPages` 分页+回退、`modified_after`、429 退避+throttled）——stub `globalThis.fetch`，29 断言 |
| `scripts/test-migrations.mjs` block 13/14/15 | v21 / v22 / v23 schema 结构与红线断言 |
| `scripts/test-ecommerce-match.mjs` | 商品匹配前端 `.ts` 与主进程 `.js` parity |

> 这些是**本地自动化**覆盖（mock adapter / stub fetch / `:memory:` DB / 纯函数），不触真实网络、不写真实凭证、不改真实账本。

---

## 8. 未经真实店铺实证的项（统一标注）

> **决策 B（2026-07-08）**：真实店铺 QA **降级为发布后验证项**——本模块以 **Beta** 标注随 **1.0.0** 正式版发布（README / CHANGELOG 已同步标注），**不作为本地财务核心的发布 blocker**。本节清单在真实店铺可用后逐项回填。

以下能力**本地自动化已覆盖，仍待真实店铺实证**（详见 [WooCommerce 真实店铺 QA 清单](./ECOMMERCE_WOO_REAL_STORE_QA.md)）：

1. 真实 TLS / 证书链 / HTTP→HTTPS 重定向下的连接行为
2. 只读权限 ck/cs 访问 `system_status` 的真实 401/403 语义
3. Woo 版本 / HPOS / 税含价店 / 第三方插件的 payload 变异
4. `X-WP-TotalPages` 在真实站 / CDN / 缓存层的存在性
5. `modified_after` 的服务端真实过滤行为
6. 真实 429 限流与退避节奏
7. 量级性能（20 页 × 50 单真实拉取）
8. `store_currency` 人工设置与真实店铺币种对齐的 UX 闭环

Shopify 侧的真实店铺联调同样属后续人工 QA 项（本地自动化覆盖，仍待真实店铺实证）。

---

## 9. 相关文档

- [电商连接器架构与多平台目录计划](./ecommerce-connector-plan.md) —— 架构、平台目录、schema 演进、PR 拆分
- [WooCommerce 真实店铺 QA 准备与验收清单](./ECOMMERCE_WOO_REAL_STORE_QA.md)
- [EC6 平台费 / 退款入账 · 会计决策问题单](./ECOMMERCE_EC6_ACCOUNTANT_QUESTIONS.md)

---

## 附：电商线 PR 变更历史

| PR | 主线 | schema | 内容 |
|---|---|---|---|
| #329 / #331 | 设计文档 | — | 连接器架构 + 11 平台目录 + 5 authMode |
| #330 | PR-EC1 | v21 | Shopify 连接设置（`manual_token`）+ safeStorage |
| #332 | PR-EC2 | v21 | WooCommerce 连接器（`key_secret`）+ 平台目录 UI |
| #333 | PR-EC3 | v22 | 拉单 → 暂存（纯后端，不写账本） |
| #334 | PR-EC4 | v22 | 暂存订单预览 UI（只读） |
| #335 | PR-EC5a | v23 | 暂存 → 提交 `sales/sales_items`（首次写账本，纯后端） |
| #336 | PR-EC5b | v23 | 提交入账 UI |
| #337 | — | v23 | 电商 i18n 占位符修复 |
| #338 | — | v23 | WooCommerce 本地 QA 测试补覆盖（provider HTTP 套件 + EC25） |
| #339 | PR-EC5c | v23 | 孤儿单解锁重提 |
