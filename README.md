# AI 看板 · AI-Powered Business Dashboard

> 基于 Google Gemini AI 驱动的财务与供应链管理系统，支持实时数据分析、增值税统计、市场行情查询和智能洞察生成。

[![React](https://img.shields.io/badge/React-19-blue?logo=react)](https://react.dev)
[![TypeScript](https://img.shields.io/badge/TypeScript-5.8-blue?logo=typescript)](https://www.typescriptlang.org)
[![Vite](https://img.shields.io/badge/Vite-6-purple?logo=vite)](https://vite.dev)
[![Google Gemini](https://img.shields.io/badge/Gemini-AI-orange?logo=google)](https://ai.google.dev)
[![Cloudflare Workers](https://img.shields.io/badge/Cloudflare-Workers-orange?logo=cloudflare)](https://workers.cloudflare.com)
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

---

## 功能概览

| 模块 | 功能 |
|------|------|
| 📊 **数据看板** | 销售额、采购额、库存量、利润率等核心 KPI 一览 |
| 🤖 **AI 分析** | Gemini AI 自动生成业务洞察、异常检测、行动建议 |
| 💰 **财务管理** | 损益表、增值税统计、税费汇总、利润率指标 |
| 📦 **库存管理** | 实时库存余量跟踪，低库存预警 |
| 🛒 **采购管理** | 进项发票管理、采购订单记录、税额自动计算 |
| 📈 **销售管理** | 销项发票管理、销售订单记录、客户分析 |
| 🔍 **市场搜索** | 通过 Tavily API 查询商品实时市场行情与价格 |
| ⚙️ **系统设置** | 公司信息、税率配置、AI 模型偏好、通知设置 |

---

## 系统架构

```
┌─────────────────────────────────────────────────────────┐
│                      用户浏览器                           │
│              React 19 + TypeScript + Vite                │
└──────────────────────┬──────────────────────────────────┘
                       │
          ┌────────────┼────────────┐
          │            │            │
          ▼            ▼            ▼
┌─────────────┐ ┌──────────────┐ ┌──────────────────────┐
│  Google     │ │  Tavily API  │ │  Cloudflare Worker   │
│  Gemini AI  │ │  市场搜索    │ │  REST API 后端        │
│  (分析/对话) │ │             │ │  ┌────────────────┐   │
└─────────────┘ └──────────────┘ │  │  D1 Database   │   │
                                 │  │  (SQLite)      │   │
                                 │  └────────────────┘   │
                                 └──────────────────────┘
                                          ↑
                               Bearer Token 认证

部署平台：Google Cloud Run（前端容器）
```

### 数据流向

```
用户操作
  │
  ├─→ 本地状态更新（React State）
  │
  ├─→ Cloudflare Worker API（持久化）
  │     └─→ D1 Database（SQLite）
  │
  ├─→ Google Gemini API（AI 分析）
  │     └─→ 结构化 JSON 洞察结果
  │
  └─→ Tavily API（市场数据）
        └─→ 实时商品行情
```

---

## 目录结构

```
ai看板/
├── components/                  # UI 组件层
│   ├── DataAnalysisPage.tsx     # AI 数据分析页
│   ├── FinancePage.tsx          # 财务综合页
│   ├── InventoryPage.tsx        # 库存管理页
│   ├── SalesAndOutputPage.tsx   # 销售管理页
│   ├── PurchaseAndInputPage.tsx # 采购管理页
│   ├── MarketSearchPage.tsx     # 市场搜索页
│   ├── SettingsPage.tsx         # 系统设置页
│   ├── Charts.tsx               # 图表组件（折线/柱状/饼图）
│   ├── AIInsights.tsx           # AI 洞察展示
│   ├── VATStatistics.tsx        # 增值税统计表
│   ├── FinancialStatementTable.tsx # 损益报表
│   ├── TaxInclusiveSummary.tsx  # 税费汇总表
│   ├── ProfitMarginIndicators.tsx  # 利润率指标卡
│   └── MetricCard.tsx           # KPI 指标卡
│
├── services/                    # 业务服务层
│   ├── api.ts                   # Cloudflare Worker API 客户端
│   ├── geminiService.ts         # Google Gemini AI 集成
│   ├── ocrService.ts            # 发票 OCR 识别
│   └── apiKey.ts                # API 密钥管理
│
├── worker/                      # Cloudflare Worker 后端
│   ├── src/index.js             # Worker 入口（完整 REST API）
│   └── wrangler.toml            # Cloudflare 部署配置
│
├── App.tsx                      # 主应用（路由、布局、全局状态）
├── types.ts                     # TypeScript 类型定义
├── constants.ts                 # 常量、AI 系统提示词
├── index.tsx                    # React 应用入口
├── index.html                   # HTML 模板
├── index.css                    # 全局样式
├── vite.config.ts               # Vite 构建配置
├── tsconfig.json                # TypeScript 配置
├── Dockerfile                   # Docker 多阶段构建
├── deploy.sh                    # Google Cloud Run 一键部署脚本
└── package.json                 # 项目依赖
```

---

## 技术栈

### 前端
| 技术 | 版本 | 用途 |
|------|------|------|
| React | 19 | UI 框架 |
| TypeScript | 5.8 | 类型安全 |
| Vite | 6 | 构建工具 |
| Recharts | 3.7 | 数据可视化图表 |
| React Markdown | 10 | Markdown 渲染 |

### AI & 外部服务
| 服务 | 用途 |
|------|------|
| Google Gemini (`gemini-3-pro-preview`) | 财务数据分析、智能对话 |
| Google Gemini TTS (`gemini-2.5-flash-preview-tts`) | AI 回复语音播放 |
| Google Gemini Audio (`gemini-2.5-flash-native-audio`) | 实时语音对话 |
| Tavily API | 市场行情搜索 |

### 后端 & 基础设施
| 技术 | 用途 |
|------|------|
| Cloudflare Workers | Serverless API 后端 |
| Cloudflare D1 | SQLite 数据库（持久化） |
| Google Cloud Run | 前端容器化部署 |
| Docker | 多阶段构建镜像 |

---

## 快速开始

### 前提条件
- Node.js 20+
- Google Gemini API Key（[获取地址](https://aistudio.google.com/apikey)）

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
# 编辑 .env.local，填入你的 API Keys
```

### 4. 启动开发服务器

```bash
npm run dev
# 访问 http://localhost:5173
```

---

## 环境变量

在项目根目录创建 `.env.local` 文件：

```bash
# ✅ 必填 - Google Gemini API Key
VITE_API_KEY=your_gemini_api_key

# ✅ 必填 - 后端 Cloudflare Worker 地址
VITE_API_BASE_URL=https://your-worker.your-subdomain.workers.dev

# ✅ 必填 - Worker API 认证 Token
VITE_API_TOKEN=your_api_token

# 可选 - Tavily 市场搜索（不填则市场搜索功能不可用）
VITE_TAVILY_API_KEY=your_tavily_api_key

# 可选 - Google 自定义搜索（市场搜索的备用方案）
VITE_GOOGLE_SEARCH_API_KEY=your_google_search_api_key
VITE_GOOGLE_SEARCH_CX=your_search_engine_id
```

> ⚠️ `.env.local` 已加入 `.gitignore`，不会被提交到代码仓库。

---

## 部署

### 方式一：Google Cloud Run（推荐）

```bash
chmod +x deploy.sh
./deploy.sh
```

脚本会自动完成：
1. 读取 `.env.local` 中的 API Keys
2. 通过 Cloud Build 构建 Docker 镜像
3. 推送镜像到 Google Container Registry
4. 部署到 Cloud Run（自动扩缩容）

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

### 后端 Worker 部署

```bash
cd worker
npm install -g wrangler
wrangler deploy
```

---

## API 文档

后端由 Cloudflare Worker 提供，所有请求需携带认证头：

```
Authorization: Bearer <VITE_API_TOKEN>
```

### 销售记录

```
GET    /api/sales           获取所有销售记录
POST   /api/sales           创建销售记录
PUT    /api/sales/:id       更新销售记录
DELETE /api/sales/:id       删除销售记录
```

### 采购记录

```
GET    /api/purchases       获取所有采购记录
POST   /api/purchases       创建采购记录
PUT    /api/purchases/:id   更新采购记录
DELETE /api/purchases/:id   删除采购记录
```

### 设置

```
GET    /api/settings        获取应用设置
PUT    /api/settings        更新应用设置
```

### 健康检查

```
GET    /health              返回服务状态
```

---

## 核心数据模型

```typescript
// 业务数据
BusinessData {
  metrics: Metric[]                    // KPI 指标
  financialStatement: FinancialStatementData  // 损益表
  vatData: VATData                     // 增值税统计
  taxSummary: TaxInclusiveSummaryData  // 税费汇总
  monthlyData: ChartData[]             // 月度趋势
}

// AI 分析结果
AIAnalysis {
  summary: string          // 执行摘要
  topInsights: string[]    // 核心洞察
  recommendations: string[] // 行动建议
  anomalies: string[]      // 异常检测
}
```

---

## License

MIT © 2025 alotie418
