# AI 看板 · AI-Powered Business Dashboard

> 基于 Google Gemini AI 驱动的财务与供应链管理系统，集成六源市场聚合搜索、语音交互、发票 OCR 识别、CSV/Excel 批量导入、应收应付管理、智能预警中心，支持实时数据分析与智能洞察生成。

[![React](https://img.shields.io/badge/React-19-blue?logo=react)](https://react.dev)
[![TypeScript](https://img.shields.io/badge/TypeScript-5.8-blue?logo=typescript)](https://www.typescriptlang.org)
[![Vite](https://img.shields.io/badge/Vite-6-purple?logo=vite)](https://vite.dev)
[![Google Gemini](https://img.shields.io/badge/Gemini_AI-Multi--Modal-orange?logo=google)](https://ai.google.dev)
[![Cloudflare Workers](https://img.shields.io/badge/Cloudflare-Workers_+_D1-orange?logo=cloudflare)](https://workers.cloudflare.com)
[![Cloud Run](https://img.shields.io/badge/Google-Cloud%20Run-blue?logo=googlecloud)](https://cloud.google.com/run)

---

## 目录

- [功能概览](#功能概览)
- [系统架构](#系统架构)
- [目录结构](#目录结构)
- [技术栈](#技术栈)
- [快速开始](#快速开始)
- [环境变量](#环境变量)
- [部署](#部署)
- [API 文档](#api-文档)
- [核心数据模型](#核心数据模型)
- [定时任务](#定时任务)

---

## 功能概览

| 模块 | 功能 |
|------|------|
| 📊 **经营数据概览** | 实时库存余量、年度采购/销售总额、平均成本等核心 KPI，月度趋势图表，数据实时从 D1 数据库聚合 |
| 🤖 **AI 数据分析** | Gemini AI 多维度分析（财务/销量/效率），Monte Carlo 模拟，VAR 风险预测 |
| 🗣️ **语音交互** | Gemini TTS 语音播放、实时语音对话（Native Audio），多音色可选 |
| 💰 **财务报表** | 损益表、增值税统计、税费汇总、利润率指标，多标签页切换 |
| 📦 **发票查询** | 进项/销项发票实时汇总（从数据库动态读取），支持日期、金额、重量、状态等高级过滤 |
| 🛒 **采购管理** | 进项发票管理、采购订单 CRUD、OCR 发票识别、税额自动计算、CSV/Excel 批量导入 |
| 📈 **销售管理** | 销项发票管理、销售订单 CRUD、OCR 发票识别、运费核算、实时库存显示、CSV/Excel 批量导入 |
| 🔍 **市场聚合搜索** | 六源并行搜索（Gemini Grounding + Brave + Tavily + 生意社直连 + 国际源 + 电商源），Gemini AI 融合分析，KV 缓存加速 |
| 📉 **价格趋势追踪** | 搜索价格自动入库，历史趋势折线图，涨跌幅统计，支持 7/30/90 天维度 |
| 📥 **CSV/Excel 批量导入** | 文件解析 → 智能列映射 → 数据预览 → 批量提交，支持 .csv/.xlsx/.xls 格式 |
| 💳 **应收应付管理** | 按客户/供应商维度汇总，账龄分析（30/60/90/180 天），付款记录，收付款率统计 |
| 🔔 **智能预警中心** | 逾期付款预警、价格异动预警，Cron 每日自动检查，未读计数实时提示 |
| ⚙️ **系统设置** | 公司信息、税率配置、AI 自动洞察、通知偏好，云端同步 |

---

## 系统架构

```
┌──────────────────────────────────────────────────────────────┐
│                         用户浏览器                             │
│                React 19 + TypeScript + Vite 6                │
│       ┌──────────┬──────────┬──────────┬──────────┐          │
│       │ AI 对话   │ OCR 识别  │ 语音 TTS  │ 预警中心  │          │
└───────┴────┬─────┴────┬─────┴────┬─────┴────┬─────┘          │
             │          │          │          │
    ┌────────┼──────────┼──────────┼──────────┼────────┐
    │        ▼          ▼          ▼          ▼        │
    │  ┌──────────┐ ┌────────┐ ┌────────┐             │
    │  │ Gemini   │ │Gemini  │ │Gemini  │             │
    │  │Flash Lite│ │Vision  │ │TTS /   │             │
    │  │ 分析/对话 │ │ OCR    │ │Audio   │             │
    │  └──────────┘ └────────┘ └────────┘             │
    │                                                  │
    │              ┌──────────────────────────────┐   │
    │              │   Cloudflare Worker           │   │
    │              │   (jizhang-api)               │   │
    │              │  ┌────────────────────────┐  │   │
    │              │  │  D1 Database           │  │   │
    │              │  │  purchases / sales     │  │   │
    │              │  │  price_history         │  │   │
    │              │  │  alerts / settings     │  │   │
    │              │  └────────────────────────┘  │   │
    │              │  ┌────────────────────────┐  │   │
    │              │  │ 六源搜索引擎             │  │   │
    │              │  │ Gemini Grounding        │  │   │
    │              │  │ Brave + Tavily 代理      │  │   │
    │              │  │ 生意社直连抓取            │  │   │
    │              │  │ 国际源 + 电商源           │  │   │
    │              │  └────────────────────────┘  │   │
    │              │  ┌────────────────────────┐  │   │
    │              │  │ KV Cache (30min TTL)   │  │   │
    │              │  └────────────────────────┘  │   │
    │              │  ┌────────────────────────┐  │   │
    │              │  │ Cron (每日 00:00 UTC)   │  │   │
    │              │  │ 逾期 + 价格异动检查       │  │   │
    │              │  └────────────────────────┘  │   │
    │              └──────────────────────────────┘   │
    │                  Bearer Token + CORS + 限流       │
    └──────────────────────────────────────────────────┘
```

### 数据流

```
用户操作
  │
  ├─→ React State ─→ UI 实时更新
  │
  ├─→ Cloudflare Worker REST API ─→ D1 SQLite（持久化）
  │     ├─→ /api/dashboard   聚合查询（库存/月度/财务报表/增值税）
  │     ├─→ 采购/销售 CRUD + 批量导入（batch）
  │     ├─→ 应收应付汇总 + 付款记录
  │     ├─→ 预警 CRUD + 已读/忽略
  │     └─→ 价格历史存储 + 趋势查询
  │
  ├─→ Gemini Flash Lite（前端直连，结构化 JSON）
  │     ├─→ 财务洞察 / 异常检测 / 行动建议
  │     ├─→ 发票 OCR 识别（图片 → 结构化字段）
  │     └─→ TTS 语音播报 / 实时语音对话
  │
  ├─→ 六源市场聚合搜索（Worker 代理，Phase 1: 并行 60s → Phase 2: 合并 90s）
  │     ├─→ Gemini Search Grounding
  │     ├─→ Brave Search / Tavily Search（Worker 代理）
  │     ├─→ 生意社直连抓取（Gemini 结构化提取）
  │     ├─→ 国际源 + 电商源（Gemini Search Grounding）
  │     └─→ Gemini Flash Lite 六源融合分析 → 价格汇总报告
  │
  └─→ Cron 定时任务（每日 00:00 UTC）
        ├─→ 逾期付款检查 → 自动生成预警
        └─→ 价格异动检查 → 自动生成预警
```

### 部署架构

```
Google Cloud Run              Cloudflare Edge
┌───────────────────┐        ┌──────────────────────────┐
│ Docker 容器        │ HTTPS  │ Worker (jizhang-api)     │
│ node:20-alpine    │ ──────▶│ + D1 Database (5 表)     │
│ serve dist/       │        │ + KV Cache               │
│ Port 8080         │        │ + 六源搜索 + Gemini 双模型 │
└───────────────────┘        │ + Cron Triggers (每日)    │
                             └──────────────────────────┘
```

---

## 目录结构

```
ai看板/
├── components/
│   ├── DataAnalysisPage.tsx        # AI 多维分析（Monte Carlo / VAR）
│   ├── FinancePage.tsx             # 财务报表（损益/增值税/税费汇总）
│   ├── InventoryPage.tsx           # 发票查询（动态加载，高级过滤）
│   ├── SalesAndOutputPage.tsx      # 销售管理（CRUD + OCR + 批量导入 + 实时库存）
│   ├── PurchaseAndInputPage.tsx    # 采购管理（CRUD + OCR + 批量导入）
│   ├── MarketSearchPage.tsx        # 六源市场聚合搜索 + 价格趋势图
│   ├── AccountsPage.tsx            # 应收应付（账龄分析 + 付款记录）
│   ├── AlertCenter.tsx             # 智能预警中心
│   ├── CsvImportModal.tsx          # CSV/Excel 批量导入弹窗
│   ├── SettingsPage.tsx            # 系统设置（云端同步）
│   ├── Charts.tsx                  # Recharts 图表封装
│   ├── AIInsights.tsx              # AI 洞察卡片
│   ├── VATStatistics.tsx           # 增值税统计表
│   ├── FinancialStatementTable.tsx # 损益报表
│   ├── TaxInclusiveSummary.tsx     # 税费汇总对账表
│   ├── ProfitMarginIndicators.tsx  # 利润率指标卡
│   ├── MetricCard.tsx              # KPI 指标卡片
│   └── SnowflakeEffect.tsx         # Canvas 雪花动效
│
├── contexts/
│   └── MarketDataContext.tsx       # 市场搜索数据跨组件共享
│
├── services/
│   ├── api.ts                      # Worker API 客户端（字段映射 + 批量操作）
│   ├── geminiService.ts            # Gemini AI 结构化分析
│   ├── ocrService.ts               # 发票 OCR（Gemini Vision）
│   └── apiKey.ts                   # 环境变量密钥管理
│
├── worker/
│   ├── src/index.js                # Worker 入口（REST API + 聚合查询 + 六源搜索 + Cron）
│   └── wrangler.toml               # 部署配置（D1 + KV + Cron）
│
├── App.tsx                         # 主应用（路由、布局、语音、全局状态）
├── types.ts                        # TypeScript 类型定义（25+ 接口）
├── constants.ts                    # 初始数据模板 + AI 系统提示词
├── index.tsx                       # React 入口
├── Dockerfile                      # 多阶段构建（build → serve）
├── .gcloudignore                   # Cloud Build 上传过滤
├── deploy.sh                       # Cloud Run 一键部署脚本
└── package.json                    # 依赖与脚本
```

---

## 技术栈

### 前端

| 技术 | 版本 | 用途 |
|------|------|------|
| React | 19.2 | UI 框架 |
| TypeScript | 5.8 | 类型安全 |
| Vite | 6.2 | 构建工具 + 开发服务器 |
| Recharts | 3.7 | 数据可视化 |
| React Markdown | 10.1 | AI 回复渲染 |
| PapaParse | 5.5 | CSV 解析 |
| SheetJS (xlsx) | 0.18 | Excel 解析 |

### AI 模型

| 用途 | 模型 | 说明 |
|------|------|------|
| 财务分析 / 对话 / OCR | `gemini-3.1-flash-Lite-preview` | 前端直连，结构化 JSON 输出 |
| 语音播报（TTS） | `gemini-2.5-flash-preview-tts` | 5 种音色可选 |
| 实时语音对话 | `gemini-2.5-flash-native-audio-preview-12-2025` | 流式麦克风交互 |
| 市场搜索主模型 | `gemini-3.1-flash-Lite-preview`（12s 超时） | Worker 端六源搜索与融合分析 |
| 市场搜索降级模型 | `gemini-2.5-flash`（55s 超时） | 主模型失败时自动切换 |

### 后端 & 基础设施

| 技术 | 用途 |
|------|------|
| Cloudflare Workers | Serverless REST API + 六源搜索 + Cron 定时任务 |
| Cloudflare D1 | SQLite 数据库（5 张表） |
| Cloudflare KV | 搜索结果缓存（30 分钟 TTL） |
| Google Cloud Run | 前端容器部署（自动扩缩） |
| Docker | 多阶段镜像构建 |
| Cloud Build | CI/CD 镜像构建管道 |

### 外部搜索源

| 来源 | 接入方式 |
|------|----------|
| Brave Search | Worker 代理（密钥存 Secrets） |
| Tavily Search | Worker 代理（密钥存 Secrets） |
| 生意社 (100ppi.com) | Worker 直连抓取 → Gemini 提取 |
| 国际源 / 电商源 | Gemini Search Grounding |

---

## 快速开始

### 前提条件

- Node.js 20+
- Google Gemini API Key（[获取地址](https://aistudio.google.com/apikey)）
- Cloudflare 账号（Worker + D1 + KV）

### 1. 克隆 & 安装

```bash
git clone https://github.com/alotie418/ai-dashboard.git
cd ai-dashboard
npm install
```

### 2. 配置环境变量

```bash
cp .env.example .env.local
# 编辑 .env.local，填入 API Keys（见下方环境变量章节）
```

### 3. 启动开发服务器

```bash
npm run dev
# 访问 http://localhost:3000
```

### 4. 部署后端 Worker

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

---

## 环境变量

### 前端 `.env.local`

| 变量 | 必填 | 说明 |
|------|------|------|
| `VITE_API_KEY` | ✅ | Google Gemini API Key（AI 分析 / OCR / TTS / 语音） |
| `VITE_API_BASE_URL` | ✅ | Cloudflare Worker 地址，例如 `https://jizhang-api.xxx.workers.dev` |
| `VITE_API_TOKEN` | ✅ | Worker Bearer Token（与 Worker Secret 一致） |
| `VITE_TAVILY_API_KEY` | 可选 | Tavily 前端直连备用（推荐使用 Worker 代理） |

> `.env.local` 已加入 `.gitignore`，不会提交到仓库。

### Worker Secrets（`wrangler secret put`）

| Secret | 说明 |
|--------|------|
| `API_TOKEN` | Bearer Token 认证（前后端共享） |
| `GEMINI_API_KEY` | Gemini API 密钥（六源搜索 + Cron） |
| `BRAVE_API_KEY` | Brave Search API 密钥 |
| `TAVILY_API_KEY` | Tavily Search API 密钥 |

### Worker 环境变量（`wrangler.toml`）

| 变量 | 说明 |
|------|------|
| `CORS_ORIGINS` | 允许的跨域来源（逗号分隔） |

---

## 部署

### 方式一：Google Cloud Run（推荐）

```bash
chmod +x deploy.sh && ./deploy.sh
```

脚本自动完成：从 `.env.local` 读取密钥 → 生成 `cloudbuild.yaml` → 提交 Cloud Build → 部署 Cloud Run。

### 方式二：Docker 本地运行

```bash
cp .env.example .env.production
# 填入 VITE_API_BASE_URL / VITE_API_TOKEN / VITE_API_KEY

docker build -t ai-dashboard .
docker run -p 8080:8080 ai-dashboard
```

> Dockerfile 在构建时自动将 `.env.production` 复制为 `.env.local`，Vite 据此注入环境变量。

### 方式三：静态部署

```bash
npm run build
# 将 dist/ 部署到 Vercel、Netlify、Cloudflare Pages 等
```

---

## API 文档

所有 `/api/*` 请求需携带认证头：

```
Authorization: Bearer <API_TOKEN>
```

### 经营看板聚合

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/api/dashboard` | 全量聚合（参数: `year`）。返回：库存余量、月度趋势、财务报表、增值税统计 |

### 采购 & 销售

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/api/purchases` | 获取所有采购记录 |
| POST | `/api/purchases` | 新增采购记录 |
| PUT | `/api/purchases/:id` | 更新采购记录 |
| DELETE | `/api/purchases/:id` | 删除采购记录 |
| POST | `/api/purchases/batch` | 批量新增（最多 500 条） |
| PUT | `/api/purchases/:id/payment` | 记录付款 |
| GET | `/api/sales` | 获取所有销售记录 |
| POST | `/api/sales` | 新增销售记录 |
| PUT | `/api/sales/:id` | 更新销售记录 |
| DELETE | `/api/sales/:id` | 删除销售记录 |
| POST | `/api/sales/batch` | 批量新增（最多 500 条） |
| PUT | `/api/sales/:id/payment` | 记录收款 |

### 应收应付

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/api/receivables/summary` | 应收汇总（账龄 + Top 客户 + 收款率） |
| GET | `/api/payables/summary` | 应付汇总（账龄 + Top 供应商 + 付款率） |

### 价格历史

| 方法 | 路径 | 说明 |
|------|------|------|
| POST | `/api/price-history` | 保存搜索价格（搜索时自动触发） |
| GET | `/api/price-history` | 查询趋势（参数: `query`, `days`） |

### 智能预警

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/api/alerts` | 获取预警列表（参数: `unread_only`） |
| GET | `/api/alerts/count` | 未读数量 |
| PUT | `/api/alerts/:id/read` | 标记已读 |
| PUT | `/api/alerts/read-all` | 全部已读 |
| DELETE | `/api/alerts/:id` | 忽略/删除 |

### 市场聚合搜索

| 方法 | 路径 | 说明 |
|------|------|------|
| POST | `/api/search/gemini` | Gemini Search Grounding |
| POST | `/api/search/brave` | Brave Search 代理 |
| POST | `/api/search/tavily` | Tavily Search 代理 |
| POST | `/api/search/direct` | 生意社直连抓取 → Gemini 提取 |
| POST | `/api/search/international` | 国际源 Grounding |
| POST | `/api/search/ecommerce` | 电商源 Grounding |
| POST | `/api/search/merge` | 六源融合分析（Gemini 双模型降级） |

> 搜索端点（merge 除外）均有 KV 缓存，TTL 30 分钟，键为 SHA-256 哈希。

### 设置 & 健康

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/api/settings` | 获取应用设置 |
| PUT | `/api/settings` | 更新设置（单值 ≤ 10KB） |
| GET | `/health` | 健康检查，返回 `{status:"ok"}` |

### 安全机制

| 机制 | 说明 |
|------|------|
| Bearer Token | 所有 `/api/*` 路由认证，timing-safe 比较 |
| CORS 白名单 | 非法 Origin 的 OPTIONS 返回 403 |
| 限流 | 每 IP 每 60s 最多 120 次请求 |
| 输入验证 | ID 格式、日期格式、数值范围校验 |

---

## 核心数据模型

### D1 数据库（5 张表）

```sql
-- 采购记录
CREATE TABLE purchases (
  id TEXT PRIMARY KEY,
  date TEXT, supplier TEXT,
  tons REAL, pricePerTon REAL, totalAmount REAL,
  amountWithoutTax REAL, taxAmount REAL, taxRate REAL,
  invoiceNumber TEXT, invoiceStatus TEXT DEFAULT '已收',
  payment_status TEXT DEFAULT 'paid',  -- paid / partial / unpaid
  paid_amount REAL DEFAULT 0,
  due_date TEXT, payment_date TEXT,
  created_at TEXT DEFAULT (datetime('now'))
);

-- 销售记录
CREATE TABLE sales (
  id TEXT PRIMARY KEY,
  date TEXT, customer TEXT,
  tons REAL, pricePerTon REAL, totalAmount REAL,
  amountWithoutTax REAL, taxAmount REAL, taxRate REAL,
  shippingCost REAL DEFAULT 0,
  invoiceNumber TEXT, invoiceStatus TEXT DEFAULT '待开',
  payment_status TEXT DEFAULT 'paid',  -- paid / partial / unpaid
  paid_amount REAL DEFAULT 0,
  due_date TEXT, payment_date TEXT,
  created_at TEXT DEFAULT (datetime('now'))
);

-- 应用设置
CREATE TABLE settings (
  key TEXT PRIMARY KEY,
  value TEXT,
  updated_at TEXT DEFAULT (datetime('now'))
);

-- 价格历史
CREATE TABLE price_history (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  query TEXT, query_normalized TEXT, search_date TEXT,
  min_price REAL, max_price REAL, avg_price REAL,
  price_count INTEGER, price_unit TEXT, source_breakdown TEXT,
  updated_at TEXT DEFAULT (datetime('now')),
  UNIQUE(query_normalized, search_date)
);

-- 智能预警
CREATE TABLE alerts (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  type TEXT,            -- overdue_payment / price_change
  title TEXT, message TEXT,
  severity TEXT,        -- info / warning / critical
  is_read INTEGER DEFAULT 0,
  is_dismissed INTEGER DEFAULT 0,
  related_id TEXT,
  created_at TEXT DEFAULT (datetime('now'))
);
```

### 关键 TypeScript 类型

```typescript
// 经营看板聚合数据（实时从 /api/dashboard 加载）
interface BusinessData {
  metrics: Metric[]
  rawMetrics?: {
    inventoryTons: number       // 实时库存 = 总采购 - 总销售
    purchaseTotalTons: number
    salesTotalTons: number
  }
  monthlyPerformance: ChartData[]
  financialStatement: FinancialStatementData
  vatStatistics: VATData
  taxInclusiveSummary: TaxInclusiveSummaryData
}

// AI 分析结果
interface AIAnalysis {
  summary: string
  topInsights: string[]
  recommendations: string[]
  anomalies: string[]
}

// 应收/应付汇总
interface AccountsSummary {
  totalReceivable: number
  totalOverdue: number
  agingBuckets: { current, days30, days60, days90, days180plus }
  topCustomers: Array<{ name, total, paid, outstanding }>
  collectionRate: number
}

// 预警
interface Alert {
  id: number
  type: 'overdue_payment' | 'price_change'
  severity: 'info' | 'warning' | 'critical'
  is_read: boolean
  created_at: string
}
```

---

## 定时任务

Worker 配置 Cron Trigger，每日 UTC 00:00 自动执行：

| 检查项 | 逻辑 | 预警级别 |
|--------|------|----------|
| 逾期付款 | `payment_status != 'paid'` 且 `due_date < today` | warning / critical |
| 价格异动 | 最近 7 天价格涨跌超阈值 | info / warning |

```toml
# worker/wrangler.toml
[triggers]
crons = ["0 0 * * *"]
```

---

## Scripts

```bash
npm run dev       # 启动开发服务器（端口 3000）
npm run build     # 生产构建（TypeScript 编译 + Vite）
npm run preview   # 本地预览生产构建
npm run start     # 生产启动（serve dist/，端口 8080）
```

---

## License

MIT © 2025-2026 alotie418
