# AI 看板 · AI-Powered Business Dashboard

> 基于 Google Gemini AI 驱动的财务与供应链管理系统，集成三引擎市场搜索、语音交互、发票 OCR 识别，支持实时数据分析与智能洞察生成。

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

---

## 功能概览

| 模块 | 功能 |
|------|------|
| 📊 **经营数据概览** | 库存余量、采购总额、销售总额、平均成本等核心 KPI，月度趋势图表 |
| 🤖 **AI 数据分析** | Gemini AI 多维度分析（财务/销量/效率），Monte Carlo 模拟，VAR 风险预测 |
| 🗣️ **语音交互** | Gemini TTS 语音播放、实时语音对话（Native Audio），多音色可选 |
| 💰 **财务报表** | 损益表、增值税统计、税费汇总、利润率指标，多标签页切换 |
| 📦 **发票查询** | 进项/销项发票筛选，支持日期、金额、重量、状态等高级过滤 |
| 🛒 **采购管理** | 进项发票管理、采购订单 CRUD、OCR 发票识别、税额自动计算 |
| 📈 **销售管理** | 销项发票管理、销售订单 CRUD、OCR 发票识别、运费核算 |
| 🔍 **市场聚合搜索** | 三引擎并行搜索（Gemini Grounding + Brave Search + Tavily），AI 融合分析 |
| ⚙️ **系统设置** | 公司信息、税率配置、AI 自动洞察、通知偏好，云端同步 |

---

## 系统架构

```
┌──────────────────────────────────────────────────────────────┐
│                         用户浏览器                             │
│                React 19 + TypeScript + Vite 6                │
│           ┌──────────┬──────────┬──────────────┐             │
│           │ AI 对话   │ OCR 识别  │ 语音 TTS/ASR │             │
└───────────┴────┬─────┴────┬─────┴──────┬───────┘             │
                 │          │            │
    ┌────────────┼──────────┼────────────┼────────┐
    │            │          │            │        │
    ▼            ▼          ▼            ▼        ▼
┌────────┐ ┌─────────┐ ┌─────────┐ ┌──────────────────────────┐
│ Gemini │ │ Gemini  │ │ Gemini  │ │  Cloudflare Worker       │
│ Pro    │ │ Vision  │ │ TTS /   │ │  (jizhang-api)           │
│ 分析   │ │ OCR     │ │ Audio   │ │  ┌─────────────────────┐ │
└────────┘ └─────────┘ └─────────┘ │  │  D1 Database        │ │
                                   │  │  (SQLite)           │ │
                                   │  └─────────────────────┘ │
                                   │  ┌─────────────────────┐ │
                                   │  │ Search Proxy        │ │
                                   │  │ Brave + Tavily      │ │
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
  │
  ├─→ Gemini Pro（结构化 JSON 分析）
  │     ├─→ 财务洞察 / 异常检测 / 行动建议
  │     └─→ TTS 语音播报 / 实时语音对话
  │
  ├─→ Gemini Vision（发票 OCR 识别）
  │     └─→ 提取日期、客户、数量、单价、运费、发票号
  │
  └─→ 三引擎市场搜索
        ├─→ Gemini Search Grounding（直连）
        ├─→ Brave Search API（Worker 代理）
        ├─→ Tavily Search API（Worker 代理）
        └─→ Gemini AI 融合分析 → 汇总报告
```

### 部署架构

```
Google Cloud Run          Cloudflare Edge
┌──────────────┐         ┌────────────────────┐
│ Docker 容器   │  ──→   │ Worker (jizhang-api)│
│ serve + dist │  HTTPS  │ + D1 Database       │
│ Port 8080    │         │ + Brave/Tavily 代理  │
└──────────────┘         └────────────────────┘
```

---

## 目录结构

```
ai看板/
├── components/                     # UI 组件层（15 个组件）
│   ├── DataAnalysisPage.tsx        # AI 多维分析页（Monte Carlo / VAR）
│   ├── FinancePage.tsx             # 财务报表页（多标签：损益/资产/现金流）
│   ├── InventoryPage.tsx           # 发票查询页（高级过滤）
│   ├── SalesAndOutputPage.tsx      # 销售管理页（CRUD + OCR）
│   ├── PurchaseAndInputPage.tsx    # 采购管理页（CRUD + OCR）
│   ├── MarketSearchPage.tsx        # 三引擎市场聚合搜索页
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
├── services/                       # 业务服务层
│   ├── api.ts                      # Worker API 客户端（字段映射 + 类型转换）
│   ├── geminiService.ts            # Gemini AI 结构化分析服务
│   ├── ocrService.ts               # 发票 OCR 识别（Gemini Vision）
│   └── apiKey.ts                   # 环境变量 API 密钥管理
│
├── worker/                         # Cloudflare Worker 后端
│   ├── src/index.js                # Worker 入口（REST API + 搜索代理 + 安全层）
│   └── wrangler.toml               # Worker 部署配置（D1 绑定 + CORS）
│
├── App.tsx                         # 主应用（路由、布局、语音、全局状态）
├── types.ts                        # TypeScript 类型定义（20+ 接口）
├── constants.ts                    # 初始数据模板 + AI 系统提示词
├── index.tsx                       # React 应用入口
├── index.html                      # HTML 模板
├── index.css                       # Tailwind 全局样式
├── vite-env.d.ts                   # Vite 环境类型声明
├── vite.config.ts                  # Vite 构建配置
├── tsconfig.json                   # TypeScript 配置
├── Dockerfile                      # Docker 多阶段构建（build → serve）
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
| Recharts | 3.7 | 数据可视化（折线/柱状/饼图/组合图） |
| React Markdown | 10.1 | AI 回复 Markdown 渲染 |
| remark-gfm | 4.0 | GFM 表格/任务列表支持 |

### AI & 多模态能力

| 服务 | 模型 | 用途 |
|------|------|------|
| Gemini Pro | `gemini-2.5-pro-preview` | 财务数据结构化分析、智能对话 |
| Gemini Vision | `gemini-2.5-pro-preview` | 发票图片 OCR 识别 |
| Gemini TTS | `gemini-2.5-flash-preview-tts` | AI 回复语音播放（5 种音色） |
| Gemini Audio | `gemini-2.5-flash-native-audio` | 实时语音对话 |
| Gemini Grounding | Search Grounding | 市场行情搜索（引擎 1） |

### 外部搜索 API

| 服务 | 用途 | 接入方式 |
|------|------|----------|
| Brave Search | 网页搜索引擎 | Worker 代理（密钥存于 Worker Secrets） |
| Tavily Search | 深度研究搜索 | Worker 代理（密钥存于 Worker Secrets） |

### 后端 & 基础设施

| 技术 | 用途 |
|------|------|
| Cloudflare Workers | Serverless REST API + 搜索代理 |
| Cloudflare D1 | SQLite 数据库（采购/销售/设置持久化） |
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
docker build \
  --build-arg VITE_API_KEY=your_key \
  --build-arg VITE_API_BASE_URL=your_url \
  --build-arg VITE_API_TOKEN=your_token \
  -t ai-dashboard .

docker run -p 8080:8080 ai-dashboard
```

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

### 设置

```
GET    /api/settings            获取所有应用设置（JSON 对象）
PUT    /api/settings            更新设置（单值 ≤ 10KB，跳过未知键）
```

### 搜索代理

```
POST   /api/search/brave        Brave Search 代理（Body: {q, count, freshness}）
POST   /api/search/tavily       Tavily Search 代理（Body: {query, search_depth, max_results}）
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

```typescript
// 业务聚合数据
interface BusinessData {
  metrics: Metric[]                           // KPI 指标卡
  monthlyPerformance: ChartData[]             // 月度趋势数据
  categoryDistribution: CategoryData[]        // 分类分布
  financialStatement: FinancialStatementData  // 损益表
  vatStatistics: VATData                      // 增值税统计
  taxInclusiveSummary: TaxInclusiveSummaryData // 税费汇总
  recentOrders: Order[]                       // 近期订单
}

// AI 分析结果
interface AIAnalysis {
  summary: string            // 执行摘要
  topInsights: string[]      // 核心洞察（3-5 条）
  recommendations: string[]  // 行动建议
  anomalies: string[]        // 异常检测
}

// 三引擎搜索结果
interface MarketSearchResponse {
  analysis: string           // AI 融合分析报告
  prices: MarketPriceResult[] // 各平台价格数据
  summaryTable: object[]     // 汇总对比表
}

// D1 数据库表
// purchases: id, date, supplier, tons, pricePerTon, totalAmount,
//            amountWithoutTax, taxAmount, taxRate, invoiceNumber,
//            invoiceStatus, created_at
// sales:     id, date, customer, tons, pricePerTon, totalAmount,
//            amountWithoutTax, taxAmount, taxRate, shippingCost,
//            invoiceNumber, invoiceStatus, created_at
// settings:  key, value (JSON string), updated_at
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

MIT © 2025 alotie418
