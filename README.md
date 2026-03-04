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
| 📊 **经营数据概览** | 库存余量、采购总额、销售总额、平均成本等核心 KPI，月度趋势图表 |
| 🤖 **AI 数据分析** | Gemini AI 多维度分析（财务/销量/效率），Monte Carlo 模拟，VAR 风险预测 |
| 🗣️ **语音交互** | Gemini TTS 语音播放、实时语音对话（Native Audio），多音色可选 |
| 💰 **财务报表** | 损益表、增值税统计、税费汇总、利润率指标，多标签页切换 |
| 📦 **发票查询** | 进项/销项发票筛选，支持日期、金额、重量、状态等高级过滤 |
| 🛒 **采购管理** | 进项发票管理、采购订单 CRUD、OCR 发票识别、税额自动计算、CSV/Excel 批量导入 |
| 📈 **销售管理** | 销项发票管理、销售订单 CRUD、OCR 发票识别、运费核算、CSV/Excel 批量导入 |
| 🔍 **市场聚合搜索** | 六源并行搜索（Gemini Grounding + Brave + Tavily + 生意社直连 + 国际源 + 电商源），Gemini AI 融合分析，KV 缓存加速 |
| 📉 **价格趋势追踪** | 搜索价格自动入库，历史趋势折线图，涨跌幅统计，支持 7/30/90 天维度 |
| 📥 **CSV/Excel 批量导入** | 文件解析 → 智能列映射 → 数据预览 → 批量提交，支持 .csv/.xlsx/.xls 格式 |
| 💳 **应收应付管理** | 按客户/供应商维度汇总，账龄分析（30/60/90/180天），付款记录，收付款率统计 |
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
    │        │          │          │          │        │
    ▼        ▼          ▼          ▼          ▼        ▼
┌────────┐ ┌─────────┐ ┌─────────┐ ┌──────────────────────────┐
│ Gemini │ │ Gemini  │ │ Gemini  │ │  Cloudflare Worker       │
│ Pro    │ │ Vision  │ │ TTS /   │ │  (jizhang-api)           │
│ 分析   │ │ OCR     │ │ Audio   │ │  ┌─────────────────────┐ │
└────────┘ └─────────┘ └─────────┘ │  │  D1 Database        │ │
                                   │  │  sales / purchases  │ │
                                   │  │  price_history      │ │
                                   │  │  alerts / settings  │ │
                                   │  └─────────────────────┘ │
                                   │  ┌─────────────────────┐ │
                                   │  │ 六源搜索引擎          │ │
                                   │  │ Gemini Grounding     │ │
                                   │  │ Brave + Tavily 代理   │ │
                                   │  │ 生意社直连抓取         │ │
                                   │  │ 国际源 + 电商源        │ │
                                   │  └─────────────────────┘ │
                                   │  ┌─────────────────────┐ │
                                   │  │ KV Cache (30min TTL) │ │
                                   │  └─────────────────────┘ │
                                   │  ┌─────────────────────┐ │
                                   │  │ Cron Trigger (每日)   │ │
                                   │  │ 逾期 + 价格异动检查    │ │
                                   │  └─────────────────────┘ │
                                   └──────────────────────────┘
                                            ↑
                                  Bearer Token + CORS + 限流
```

### 数据流

```
用户操作
  │
  ├─→ React State ─→ UI 实时更新
  │
  ├─→ Cloudflare Worker REST API ─→ D1 SQLite（持久化）
  │     ├─→ 采购/销售 CRUD + 批量导入（batch）
  │     ├─→ 应收应付汇总 + 付款记录
  │     ├─→ 预警 CRUD + 已读/忽略
  │     └─→ 价格历史存储 + 趋势查询
  │
  ├─→ Gemini Pro（结构化 JSON 分析）
  │     ├─→ 财务洞察 / 异常检测 / 行动建议
  │     └─→ TTS 语音播报 / 实时语音对话
  │
  ├─→ Gemini Vision（发票 OCR 识别）
  │     └─→ 提取日期、客户、数量、单价、运费、发票号
  │
  ├─→ 六源市场聚合搜索（Phase 1: 并行 60s → Phase 2: 合并 90s）
  │     ├─→ Gemini Search Grounding（Worker 代理）
  │     ├─→ Brave Search API（Worker 代理）
  │     ├─→ Tavily Search API（Worker 代理）
  │     ├─→ 生意社直连抓取（Worker fetch → Gemini 结构化提取）
  │     ├─→ 国际源搜索（Worker 代理）
  │     ├─→ 电商源搜索（Worker 代理）
  │     └─→ Gemini AI 六源融合分析 → 价格汇总报告
  │
  └─→ Cron 定时任务（每日 00:00 UTC）
        ├─→ 逾期付款检查 → 自动生成预警
        └─→ 价格异动检查 → 自动生成预警
```

### 部署架构

```
Google Cloud Run          Cloudflare Edge
┌──────────────┐         ┌─────────────────────────┐
│ Docker 容器   │  ──→   │ Worker (jizhang-api)     │
│ serve + dist │  HTTPS  │ + D1 Database (5 表)     │
│ Port 8080    │         │ + KV Cache               │
│              │         │ + 六源搜索 + Gemini 双模型 │
│              │         │ + Cron Triggers (每日)    │
└──────────────┘         └─────────────────────────┘
```

---

## 目录结构

```
ai看板/
├── components/                     # UI 组件层（18 个组件）
│   ├── DataAnalysisPage.tsx        # AI 多维分析页（Monte Carlo / VAR）
│   ├── FinancePage.tsx             # 财务报表页（多标签：损益/资产/现金流）
│   ├── InventoryPage.tsx           # 发票查询页（高级过滤）
│   ├── SalesAndOutputPage.tsx      # 销售管理页（CRUD + OCR + 批量导入）
│   ├── PurchaseAndInputPage.tsx    # 采购管理页（CRUD + OCR + 批量导入）
│   ├── MarketSearchPage.tsx        # 六源市场聚合搜索页 + 价格趋势图
│   ├── AccountsPage.tsx            # 应收应付管理页（账龄分析 + 付款记录）
│   ├── AlertCenter.tsx             # 智能预警中心（逾期/价格异动预警）
│   ├── CsvImportModal.tsx          # CSV/Excel 批量导入弹窗（解析→映射→预览→提交）
│   ├── SettingsPage.tsx            # 系统设置页（云端同步）
│   ├── Charts.tsx                  # Recharts 图表（折线/柱状/饼图/组合图）
│   ├── AIInsights.tsx              # AI 洞察卡片展示
│   ├── VATStatistics.tsx           # 增值税统计表
│   ├── FinancialStatementTable.tsx # 损益报表组件
│   ├── TaxInclusiveSummary.tsx     # 税费汇总对账表
│   ├── ProfitMarginIndicators.tsx  # 利润率指标卡（毛利率/净利率）
│   ├── MetricCard.tsx              # KPI 指标卡片
│   └── SnowflakeEffect.tsx         # Canvas 雪花动效
│
├── contexts/                       # React Context 层
│   └── MarketDataContext.tsx       # 市场搜索数据跨组件共享（搜索结果 + 价格趋势）
│
├── services/                       # 业务服务层
│   ├── api.ts                      # Worker API 客户端（字段映射 + 类型转换 + 批量操作）
│   ├── geminiService.ts            # Gemini AI 结构化分析服务
│   ├── ocrService.ts               # 发票 OCR 识别（Gemini Vision）
│   └── apiKey.ts                   # 环境变量 API 密钥管理
│
├── worker/                         # Cloudflare Worker 后端
│   ├── src/index.js                # Worker 入口（REST API + 六源搜索 + Gemini 双模型 + KV 缓存 + Cron）
│   └── wrangler.toml               # Worker 部署配置（D1 + KV + Cron Triggers）
│
├── App.tsx                         # 主应用（路由、布局、语音、全局状态、预警徽标）
├── types.ts                        # TypeScript 类型定义（25+ 接口）
├── constants.ts                    # 初始数据模板 + AI 系统提示词
├── index.tsx                       # React 应用入口
├── index.html                      # HTML 模板
├── index.css                       # Tailwind 全局样式
├── vite-env.d.ts                   # Vite 环境类型声明
├── vite.config.ts                  # Vite 构建配置
├── tsconfig.json                   # TypeScript 配置
├── Dockerfile                      # Docker 多阶段构建（build → serve，自动读取 .env.production）
├── .gcloudignore                   # Cloud Build 上传过滤（确保 .env.production 被包含）
├── deploy.sh                       # Cloud Run 一键部署脚本
├── Procfile                        # 进程启动配置
├── metadata.json                   # 项目元数据
└── package.json                    # 项目依赖与脚本
```

---

## 技术栈

### 前端

| 技术 | 版本 | 用途 |
|------|------|------|
| React | 19.2 | UI 框架 |
| TypeScript | 5.8 | 类型安全 |
| Vite | 6.2 | 构建工具 + 开发服务器 |
| Recharts | 3.7 | 数据可视化（折线/柱状/饼图/组合图/趋势图） |
| React Markdown | 10.1 | AI 回复 Markdown 渲染 |
| remark-gfm | 4.0 | GFM 表格/任务列表支持 |
| PapaParse | 5.5 | CSV 文件解析（批量导入） |
| SheetJS (xlsx) | 0.18 | Excel 文件解析（.xlsx/.xls 批量导入） |

### AI & 多模态能力

| 服务 | 模型 | 用途 |
|------|------|------|
| Gemini Pro | `gemini-2.5-pro-preview` | 财务数据结构化分析、智能对话（前端直连） |
| Gemini Vision | `gemini-2.5-pro-preview` | 发票图片 OCR 识别（前端直连） |
| Gemini TTS | `gemini-2.5-flash-preview-tts` | AI 回复语音播放（5 种音色） |
| Gemini Audio | `gemini-2.5-flash-native-audio` | 实时语音对话 |
| Gemini 市场搜索 | `gemini-3.1-pro-preview` → `gemini-2.5-flash`（fallback） | Worker 端：Search Grounding、直连提取、六源合并分析 |

> 市场搜索采用**双模型降级策略**：主模型 `gemini-3.1-pro-preview`（12s 超时），若失败自动降级到 `gemini-2.5-flash`（55s 超时）。

### 外部搜索 & 数据源

| 服务 | 用途 | 接入方式 |
|------|------|----------|
| Brave Search | 网页搜索引擎 | Worker 代理（密钥存于 Worker Secrets） |
| Tavily Search | 深度研究搜索 | Worker 代理（密钥存于 Worker Secrets） |
| 生意社 (100ppi.com) | 大宗商品权威报价（10 个品种） | Worker fetch 直连 → Gemini 结构化提取 |
| 国际源 | 国际市场价格搜索 | Worker Gemini Search Grounding |
| 电商源 | 电商平台价格搜索 | Worker Gemini Search Grounding |

### 后端 & 基础设施

| 技术 | 用途 |
|------|------|
| Cloudflare Workers | Serverless REST API + 六源搜索引擎 + Cron 定时任务 |
| Cloudflare D1 | SQLite 数据库（5 表：采购/销售/设置/价格历史/预警） |
| Cloudflare KV | 搜索结果缓存（30 分钟 TTL，SHA-256 哈希键） |
| Google Cloud Run | 前端 Docker 容器部署（自动扩缩） |
| Docker | 多阶段构建（node:20-alpine → serve） |
| Cloud Build | CI/CD 镜像构建 |

---

## 快速开始

### 前提条件

- Node.js 20+
- Google Gemini API Key（[获取地址](https://aistudio.google.com/apikey)）
- Cloudflare 账号（后端 Worker + D1 数据库）

### 1. 克隆项目

```bash
git clone https://github.com/alotie418/ai-dashboard.git
cd ai-dashboard
```

### 2. 安装依赖

```bash
npm install
```

### 3. 配置环境变量

```bash
cp .env.example .env.local
# 编辑 .env.local，填入你的 API Keys（详见下方环境变量章节）
```

### 4. 启动开发服务器

```bash
npm run dev
# 访问 http://localhost:3000
```

### 5. 部署后端 Worker

```bash
cd worker
npm install -g wrangler
wrangler login
wrangler d1 create jizhang-db           # 创建 D1 数据库
wrangler secret put API_TOKEN           # 设置认证 Token
wrangler secret put BRAVE_API_KEY       # 设置 Brave 搜索密钥
wrangler secret put TAVILY_API_KEY      # 设置 Tavily 搜索密钥
wrangler secret put GEMINI_API_KEY      # 设置 Gemini API 密钥（六源搜索）
wrangler deploy                         # 部署 Worker
```

---

## 环境变量

### 前端（`.env.local`）

```bash
# ✅ 必填 - Google Gemini API Key（AI 分析 / OCR / TTS / 语音对话）
VITE_API_KEY=your_gemini_api_key

# ✅ 必填 - Cloudflare Worker API 地址
VITE_API_BASE_URL=https://your-worker.your-subdomain.workers.dev

# ✅ 必填 - Worker API 认证 Token（需与 Worker Secret 一致）
VITE_API_TOKEN=your_api_token

# 可选 - Tavily 市场搜索（前端直连备用，推荐通过 Worker 代理）
VITE_TAVILY_API_KEY=your_tavily_api_key

# 可选 - Google 自定义搜索（市场搜索备用方案）
VITE_GOOGLE_SEARCH_API_KEY=your_google_search_api_key
VITE_GOOGLE_SEARCH_CX=your_search_engine_id
```

> `.env.local` 和 `.env` 均已加入 `.gitignore`，不会被提交到代码仓库。

### Worker Secrets（通过 `wrangler secret put` 设置）

| Secret | 用途 |
|--------|------|
| `API_TOKEN` | Bearer Token 认证（前后端共享） |
| `BRAVE_API_KEY` | Brave Search API 密钥（搜索代理） |
| `TAVILY_API_KEY` | Tavily Search API 密钥（搜索代理） |
| `GEMINI_API_KEY` | Gemini API 密钥（六源搜索 + Cron 预警检查） |

### Worker 环境变量（`wrangler.toml`）

| 变量 | 用途 |
|------|------|
| `CORS_ORIGINS` | 允许的跨域来源（逗号分隔） |

---

## 部署

### 方式一：Google Cloud Run（推荐）

```bash
chmod +x deploy.sh
./deploy.sh
```

脚本会交互式引导完成：
1. 输入 GCP 项目 ID、服务名、区域
2. 从 `.env.local` 读取或手动输入 API Keys
3. 生成 `cloudbuild.yaml` 并提交 Cloud Build
4. 自动部署到 Cloud Run（公开访问、自动扩缩）

### 方式二：Docker 本地运行

```bash
# 1. 创建 .env.production（构建时自动读取）
cp .env.example .env.production
# 编辑 .env.production，填入 VITE_API_BASE_URL 和 VITE_API_TOKEN

# 2. 构建并运行
docker build -t ai-dashboard .
docker run -p 8080:8080 ai-dashboard
```

> 构建时 Dockerfile 会自动将 `.env.production` 复制为 `.env.local`，Vite 据此注入环境变量。

### 方式三：静态部署

```bash
npm run build
# 将 dist/ 目录部署到任意静态托管平台（Vercel、Netlify、Cloudflare Pages 等）
```

---

## API 文档

后端由 Cloudflare Worker (`jizhang-api`) 提供，所有 `/api/*` 请求需携带认证头：

```
Authorization: Bearer <API_TOKEN>
```

### 采购记录

```
GET    /api/purchases           获取所有采购记录（按日期降序）
POST   /api/purchases           创建采购记录（含字段验证与类型校验）
PUT    /api/purchases/:id       更新采购记录（数值字段自动 coerce）
DELETE /api/purchases/:id       删除采购记录
```

### 销售记录

```
GET    /api/sales               获取所有销售记录（按日期降序）
POST   /api/sales               创建销售记录（含字段验证与类型校验）
PUT    /api/sales/:id           更新销售记录（数值字段自动 coerce）
DELETE /api/sales/:id           删除销售记录
```

### 批量导入

```
POST   /api/sales/batch         批量创建销售记录（最多 500 条/次）
POST   /api/purchases/batch     批量创建采购记录（最多 500 条/次）
```

### 应收应付

```
PUT    /api/sales/:id/payment      记录销售付款（自动更新 payment_status）
PUT    /api/purchases/:id/payment  记录采购付款（自动更新 payment_status）
GET    /api/receivables/summary    应收账款汇总（账龄分析 + Top 客户 + 收款率）
GET    /api/payables/summary       应付账款汇总（账龄分析 + Top 供应商 + 付款率）
```

### 价格趋势

```
POST   /api/price-history       保存搜索价格数据（搜索时自动调用）
GET    /api/price-history       查询价格趋势（参数: query, days）
```

### 智能预警

```
GET    /api/alerts              获取预警列表（参数: unread_only）
GET    /api/alerts/count        获取未读预警数量
PUT    /api/alerts/:id/read     标记预警为已读
PUT    /api/alerts/read-all     标记所有预警为已读
DELETE /api/alerts/:id          忽略/删除预警
```

### 市场聚合搜索（六源 + 合并）

```
POST   /api/search/gemini       Gemini Search Grounding（Body: {query}）
POST   /api/search/brave        Brave Search 代理（Body: {q, count, freshness}）
POST   /api/search/tavily       Tavily Search 代理（Body: {query, search_depth, max_results}）
POST   /api/search/direct       生意社直连抓取（Body: {query}）→ 匹配品种 → Gemini 提取
POST   /api/search/international 国际源搜索（Body: {query}）→ Gemini Search Grounding
POST   /api/search/ecommerce    电商源搜索（Body: {query}）→ Gemini Search Grounding
POST   /api/search/merge        六源融合分析（Body: {query, geminiData, braveData, tavilyData, directResults, internationalData, ecommerceData}）
```

> 所有搜索端点均有 **KV 缓存**（30 分钟 TTL，SHA-256 哈希键），merge 端点除外。

### 设置

```
GET    /api/settings            获取所有应用设置（JSON 对象）
PUT    /api/settings            更新设置（单值 ≤ 10KB，跳过未知键）
```

### 健康检查

```
GET    /                        返回 {status: "ok"}
GET    /health                  返回 {status: "ok"}
```

### 安全机制

| 机制 | 说明 |
|------|------|
| Bearer Token | 所有 `/api/*` 路由需认证，timing-safe 比较 |
| CORS | 白名单模式，非法 Origin 的 OPTIONS 返回 403 |
| 限流 | 每 IP 每 60 秒最多 120 次请求 |
| 输入验证 | ID 格式、日期格式、数值范围校验 |

---

## 核心数据模型

### D1 数据库表

```sql
-- 采购记录（含付款状态）
CREATE TABLE purchases (
  id TEXT PRIMARY KEY,
  date TEXT,
  supplier TEXT,
  tons REAL,
  pricePerTon REAL,
  totalAmount REAL,
  amountWithoutTax REAL,
  taxAmount REAL,
  taxRate REAL,
  invoiceNumber TEXT,
  invoiceStatus TEXT DEFAULT '已收',
  payment_status TEXT DEFAULT 'paid',     -- paid / partial / unpaid
  paid_amount REAL DEFAULT 0,
  due_date TEXT,
  payment_date TEXT,
  created_at TEXT DEFAULT (datetime('now'))
);

-- 销售记录（含付款状态）
CREATE TABLE sales (
  id TEXT PRIMARY KEY,
  date TEXT,
  customer TEXT,
  tons REAL,
  pricePerTon REAL,
  totalAmount REAL,
  amountWithoutTax REAL,
  taxAmount REAL,
  taxRate REAL,
  shippingCost REAL DEFAULT 0,
  invoiceNumber TEXT,
  invoiceStatus TEXT DEFAULT '待开',
  payment_status TEXT DEFAULT 'paid',     -- paid / partial / unpaid
  paid_amount REAL DEFAULT 0,
  due_date TEXT,
  payment_date TEXT,
  created_at TEXT DEFAULT (datetime('now'))
);

-- 应用设置
CREATE TABLE settings (
  key TEXT PRIMARY KEY,
  value TEXT,
  updated_at TEXT DEFAULT (datetime('now'))
);

-- 价格历史（趋势追踪）
CREATE TABLE price_history (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  query TEXT,
  query_normalized TEXT,
  search_date TEXT,
  min_price REAL,
  max_price REAL,
  avg_price REAL,
  price_count INTEGER,
  price_unit TEXT,
  source_breakdown TEXT,
  updated_at TEXT DEFAULT (datetime('now')),
  UNIQUE(query_normalized, search_date)
);

-- 智能预警
CREATE TABLE alerts (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  type TEXT,            -- overdue_payment / price_change
  title TEXT,
  message TEXT,
  severity TEXT,        -- info / warning / critical
  is_read INTEGER DEFAULT 0,
  is_dismissed INTEGER DEFAULT 0,
  related_id TEXT,
  created_at TEXT DEFAULT (datetime('now'))
);
```

### TypeScript 类型

```typescript
// 业务聚合数据
interface BusinessData {
  metrics: Metric[]
  monthlyPerformance: ChartData[]
  categoryDistribution: CategoryData[]
  financialStatement: FinancialStatementData
  vatStatistics: VATData
  taxInclusiveSummary: TaxInclusiveSummaryData
  recentOrders: Order[]
}

// AI 分析结果
interface AIAnalysis {
  summary: string
  topInsights: string[]
  recommendations: string[]
  anomalies: string[]
}

// 六源搜索结果
interface MarketSearchResponse {
  analysis: string
  prices: MarketPriceResult[]
  summaryTable: object[]
}

// 应收/应付汇总
interface AccountsSummary {
  totalReceivable / totalPayable: number
  totalOverdue: number
  agingBuckets: { current, days30, days60, days90, days180plus }
  topCustomers / topSuppliers: Array<{ name, total, paid, outstanding }>
  collectionRate / paymentRate: number
}

// 价格趋势数据
interface PriceHistory {
  query: string
  search_date: string
  min_price: number
  max_price: number
  avg_price: number
  price_unit: string
}

// 预警
interface Alert {
  id: number
  type: 'overdue_payment' | 'price_change'
  title: string
  message: string
  severity: 'info' | 'warning' | 'critical'
  is_read: boolean
  is_dismissed: boolean
  created_at: string
}
```

---

## 定时任务

Worker 配置了 Cron Trigger，每日 UTC 00:00 自动执行：

| 检查项 | 逻辑 | 预警级别 |
|--------|------|----------|
| 逾期付款 | 扫描 sales/purchases 表中 `payment_status != 'paid'` 且 `due_date < today` 的记录 | warning / critical |
| 价格异动 | 对比 price_history 表中最近 7 天的价格变化，涨跌超阈值生成预警 | info / warning |

配置位于 `worker/wrangler.toml`：

```toml
[triggers]
crons = ["0 0 * * *"]
```

---

## 语音能力

| 功能 | 模型 | 说明 |
|------|------|------|
| AI 语音播报 | `gemini-2.5-flash-preview-tts` | 分析结果自动转语音，可选音色：Aoede / Puck / Charon / Kore / Fenrir |
| 实时语音对话 | `gemini-2.5-flash-native-audio` | 麦克风输入 → AI 语音回复，流式交互 |

---

## Scripts

```bash
npm run dev       # 启动 Vite 开发服务器（端口 3000）
npm run build     # TypeScript 编译 + Vite 生产构建
npm run preview   # 本地预览生产构建
npm run start     # serve 静态文件（生产环境，端口 8080）
```

---

## License

MIT © 2025-2026 alotie418
