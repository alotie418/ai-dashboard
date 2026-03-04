# AI 看板 — 智能经营管理系统

基于 Google Gemini 驱动的全链路经营管理平台。覆盖采购、销售、库存、财务、发票、应收应付、市场行情、智能预警八大核心场景，支持语音交互、发票 OCR、CSV/Excel 批量导入和六源市场聚合搜索。

[![React 19](https://img.shields.io/badge/React-19-61dafb?logo=react)](https://react.dev)
[![TypeScript 5.8](https://img.shields.io/badge/TypeScript-5.8-3178c6?logo=typescript)](https://www.typescriptlang.org)
[![Vite 6](https://img.shields.io/badge/Vite-6-646cff?logo=vite)](https://vite.dev)
[![Gemini AI](https://img.shields.io/badge/Gemini-Multi--Modal-f29900?logo=google)](https://ai.google.dev)
[![Cloudflare Workers](https://img.shields.io/badge/Cloudflare-Workers_+_D1-f38020?logo=cloudflare)](https://workers.cloudflare.com)
[![Cloud Run](https://img.shields.io/badge/Google-Cloud_Run-4285f4?logo=googlecloud)](https://cloud.google.com/run)

---

## 功能一览

| 模块 | 说明 |
|------|------|
| 📊 经营看板 | 实时库存、年度采购/销售总额、平均成本、月度趋势——全部从 D1 聚合，零硬编码 |
| 🤖 AI 分析 | Gemini 多维分析（财务/销量/效率）、Monte Carlo 模拟、VAR 风险预测 |
| 🗣️ 语音交互 | TTS 播报（5 种音色）+ Native Audio 实时对话 |
| 💰 财务报表 | 损益表、增值税统计、税费汇总、利润率指标 |
| 🧾 发票查询 | 进项/销项发票汇总，支持日期·金额·重量·状态多维过滤 |
| 🛒 采购管理 | CRUD + 发票 OCR + 税额自动计算 + CSV/Excel 批量导入 |
| 📈 销售管理 | CRUD + 发票 OCR + 运费核算 + 实时库存（10 kg/袋） |
| 🔍 市场聚合搜索 | 六源并行（Gemini Grounding · Brave · Tavily · 生意社 · 国际 · 电商）+ AI 融合分析 + KV 缓存 |
| 📉 价格趋势 | 搜索价格自动入库，趋势折线图，7/30/90 天涨跌统计 |
| 💳 应收应付 | 客户/供应商维度汇总，30/60/90/180 天账龄分析，收付款率 |
| 🔔 智能预警 | 逾期付款 + 价格异动，Cron 每日自动检查，未读计数 |
| ⚙️ 系统设置 | 公司信息、税率、AI 洞察开关、通知偏好，云端同步 |

---

## 架构

```
浏览器 (React 19 + TS + Vite 6)
├── Gemini flash-lite ─ 财务分析 / OCR / 对话
├── Gemini TTS ─────── 语音播报 (5 音色)
├── Gemini Native Audio 实时语音对话
│
▼  HTTPS + Bearer Token
Cloudflare Worker (jizhang-api)
├── D1 SQLite (purchases · sales · price_history · alerts · settings)
├── KV Cache (搜索结果, 30 min TTL)
├── 六源搜索引擎 (Gemini Grounding / Brave / Tavily / 生意社 / 国际 / 电商)
├── Gemini 双模型降级 (lite 12s → flash 55s)
└── Cron Trigger (每日 00:00 UTC)

前端部署: Google Cloud Run (Docker, port 8080)
```

---

## AI 模型

| 用途 | 模型 | 备注 |
|------|------|------|
| 财务分析 / 对话 / OCR | `gemini-3.1-flash-lite-preview` | 前端直连，结构化 JSON |
| 语音播报 TTS | `gemini-2.5-flash-preview-tts` | 5 种音色 |
| 实时语音对话 | `gemini-2.5-flash-native-audio-preview-12-2025` | 流式麦克风 |
| 市场搜索（主） | `gemini-3.1-flash-lite-preview` | Worker 端，12 s 超时 |
| 市场搜索（降级） | `gemini-2.5-flash` | 主模型超时后自动切换，55 s |

---

## 快速开始

### 前提

- Node.js ≥ 20
- Gemini API Key — [申请](https://aistudio.google.com/apikey)
- Cloudflare 账号（Workers + D1 + KV）

### 安装 & 开发

```bash
git clone https://github.com/alotie418/ai-dashboard.git
cd ai-dashboard
npm install

cp .env.example .env.local   # 填写下方环境变量
npm run dev                   # http://localhost:3000
```

### 部署 Worker

```bash
cd worker
npx wrangler login
npx wrangler d1 create jizhang-db
npx wrangler secret put API_TOKEN
npx wrangler secret put GEMINI_API_KEY
npx wrangler secret put BRAVE_API_KEY
npx wrangler secret put TAVILY_API_KEY
npx wrangler deploy
```

### 部署前端

```bash
# 方式一：Cloud Run（推荐）
chmod +x deploy.sh && ./deploy.sh

# 方式二：Docker
docker build -t ai-dashboard . && docker run -p 8080:8080 ai-dashboard

# 方式三：静态
npm run build   # dist/ → Vercel / Netlify / Cloudflare Pages
```

---

## 环境变量

### 前端 `.env.local`

| 变量 | 必填 | 说明 |
|------|:----:|------|
| `VITE_API_KEY` | ✅ | Gemini API Key |
| `VITE_API_BASE_URL` | ✅ | Worker 地址 `https://jizhang-api.xxx.workers.dev` |
| `VITE_API_TOKEN` | ✅ | Bearer Token（与 Worker 一致） |
| `VITE_TAVILY_API_KEY` | — | Tavily 前端备用（推荐走 Worker 代理） |

### Worker Secrets

| Secret | 说明 |
|--------|------|
| `API_TOKEN` | Bearer Token |
| `GEMINI_API_KEY` | Gemini 密钥 |
| `BRAVE_API_KEY` | Brave Search 密钥 |
| `TAVILY_API_KEY` | Tavily Search 密钥 |

---

## API 端点

所有 `/api/*` 需 `Authorization: Bearer <TOKEN>`。限流 120 次/IP/60 s。

### 经营看板

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/api/dashboard?year=2026` | 全量聚合：库存、月度趋势、损益表、增值税 |

### 采购 & 销售

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/api/purchases` | 列表 |
| POST | `/api/purchases` | 新增 |
| PUT | `/api/purchases/:id` | 更新 |
| DELETE | `/api/purchases/:id` | 删除 |
| POST | `/api/purchases/batch` | 批量（≤ 500） |
| PUT | `/api/purchases/:id/payment` | 记录付款 |
| GET / POST / PUT / DELETE | `/api/sales/...` | 同上 |

### 应收应付

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/api/receivables/summary` | 应收汇总 + 账龄 + Top 客户 |
| GET | `/api/payables/summary` | 应付汇总 + 账龄 + Top 供应商 |

### 价格历史

| 方法 | 路径 | 说明 |
|------|------|------|
| POST | `/api/price-history` | 保存搜索价格 |
| GET | `/api/price-history?query=&days=30` | 趋势查询 |

### 预警

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/api/alerts` | 列表 |
| GET | `/api/alerts/count` | 未读数 |
| PUT | `/api/alerts/:id/read` | 标记已读 |
| PUT | `/api/alerts/read-all` | 全部已读 |
| DELETE | `/api/alerts/:id` | 删除 |

### 六源搜索

| 方法 | 路径 | 说明 |
|------|------|------|
| POST | `/api/search/gemini` | Gemini Grounding |
| POST | `/api/search/brave` | Brave 代理 |
| POST | `/api/search/tavily` | Tavily 代理 |
| POST | `/api/search/direct` | 生意社直连 → Gemini 提取 |
| POST | `/api/search/international` | 国际源 |
| POST | `/api/search/ecommerce` | 电商源 |
| POST | `/api/search/merge` | 六源融合分析（双模型降级） |

> 搜索结果（merge 除外）缓存在 KV，TTL 30 min，键 = SHA-256(source:query)。

### 其他

| 方法 | 路径 | 说明 |
|------|------|------|
| GET / PUT | `/api/settings` | 应用设置 |
| GET | `/health` | 健康检查 |

---

## 数据库

D1 SQLite，5 张表：

```sql
purchases (id, date, supplier, tons, pricePerTon, totalAmount,
           amountWithoutTax, taxAmount, taxRate,
           invoiceNumber, invoiceStatus,
           payment_status, paid_amount, due_date, payment_date, created_at)

sales     (同 purchases + shippingCost, customer 替代 supplier)

settings  (key, value, updated_at)

price_history (id, query, query_normalized, search_date,
              min_price, max_price, avg_price, price_count, price_unit,
              source_breakdown, updated_at)  -- UNIQUE(query_normalized, search_date)

alerts    (id, type, title, message, severity, is_read, is_dismissed,
           related_id, created_at)
```

---

## 核心类型

```typescript
interface BusinessData {
  metrics: Metric[]
  rawMetrics?: {               // /api/dashboard 返回的原始数值
    inventoryTons: number      // 实时库存 = 采购总量 − 销售总量
    purchaseTotalTons: number
    salesTotalTons: number
  }
  monthlyPerformance: ChartData[]
  financialStatement: FinancialStatementData
  vatStatistics: VATData
  taxInclusiveSummary: TaxInclusiveSummaryData
}

interface Alert {
  id: number
  type: 'overdue_payment' | 'price_change'
  severity: 'critical' | 'warning' | 'info'
  is_read: number
  created_at: string
}
```

---

## 目录结构

```
├── App.tsx                      # 主应用（路由/布局/语音/全局状态）
├── types.ts                     # TypeScript 类型（25+ 接口）
├── constants.ts                 # 初始数据模板 + AI 提示词
├── components/
│   ├── DataAnalysisPage.tsx     # AI 多维分析
│   ├── FinancePage.tsx          # 财务报表
│   ├── InventoryPage.tsx        # 发票查询
│   ├── SalesAndOutputPage.tsx   # 销售管理
│   ├── PurchaseAndInputPage.tsx # 采购管理
│   ├── MarketSearchPage.tsx     # 六源市场搜索 + 趋势图
│   ├── AccountsPage.tsx         # 应收应付
│   ├── AlertCenter.tsx          # 预警中心
│   ├── CsvImportModal.tsx       # 批量导入弹窗
│   └── SettingsPage.tsx         # 系统设置
├── services/
│   ├── api.ts                   # Worker API 客户端
│   ├── geminiService.ts         # Gemini AI 分析
│   └── ocrService.ts            # 发票 OCR
├── contexts/
│   └── MarketDataContext.tsx     # 市场数据跨组件共享
├── worker/
│   ├── src/index.js             # Worker 入口（API + 搜索 + Cron）
│   └── wrangler.toml            # D1 + KV + Cron 配置
├── Dockerfile                   # 多阶段构建
├── deploy.sh                    # Cloud Run 一键部署
└── package.json
```

---

## Cron 定时任务

每日 UTC 00:00 执行（`wrangler.toml` → `crons = ["0 0 * * *"]`）：

| 检查项 | 触发条件 | 预警级别 |
|--------|----------|----------|
| 逾期付款 | `payment_status ≠ paid` 且 `due_date < today` | warning / critical |
| 价格异动 | 近 7 天价格涨跌超阈值 | info / warning |

---

## Scripts

```bash
npm run dev       # 开发（端口 3000）
npm run build     # 生产构建
npm run preview   # 本地预览
npm run start     # 生产启动（serve dist/，端口 8080）
```

---

## License

MIT © 2025–2026 alotie418
