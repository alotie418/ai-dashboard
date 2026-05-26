# SoloLedger 独账

一人公司的智能账本与经营管理桌面应用。覆盖采购、销售、库存、财务、发票、应收应付、智能预警等核心场景，所有数据存储在本地，AI 能力由你自带的 API Key 驱动。

[![macOS](https://img.shields.io/badge/macOS-14+-000000?logo=apple)](https://www.apple.com/macos/)
[![Electron 33](https://img.shields.io/badge/Electron-33-47848f?logo=electron)](https://www.electronjs.org)
[![React 19](https://img.shields.io/badge/React-19-61dafb?logo=react)](https://react.dev)
[![TypeScript 5.8](https://img.shields.io/badge/TypeScript-5.8-3178c6?logo=typescript)](https://www.typescriptlang.org)
[![SQLite](https://img.shields.io/badge/SQLite-better--sqlite3-003b57?logo=sqlite)](https://github.com/WiseLibs/better-sqlite3)

---

## BYOK — 自带 API Key，支持多服务商

SoloLedger 不内置任何 AI 后端，所有 AI 能力由你自己的 API Key 驱动。**同时支持三家服务商，可任意组合**：

| Provider | 用途 | 默认 model ID（可改） | 调用端点 | 获取 Key |
|---|---|---|---|---|
| **Claude (Anthropic)** | 分析、对话、发票 OCR | `claude-sonnet-4-6` | `/v1/messages` | [console.anthropic.com](https://console.anthropic.com/settings/keys) |
| **ChatGPT (OpenAI)** | 分析、对话、发票 OCR | `gpt-5.5` | `/v1/responses` | [platform.openai.com](https://platform.openai.com/api-keys) |
| **Gemini (Google)** | 分析、对话、OCR、**TTS 语音**、Web Grounding | `gemini-3.5-flash` | `@google/genai` SDK | [aistudio.google.com](https://aistudio.google.com/app/apikey) |

> **关于 model ID**：上表是 SoloLedger 出厂默认填的字符串，**并不保证一定对应你账号下当前可用的模型**。
> 各家服务商会持续发布、下线、改名模型。如果「测试连接」报 `model_not_found` / `invalid_model` / `HTTP 404`，请：
> 1. 去对应服务商官网查你当前可调用的精确 model ID（通常带日期后缀，如 `claude-sonnet-4-6-20251030`）
> 2. 在 SoloLedger「系统设置 → AI 服务商」里直接修改 model ID（输入框可自由输入任何字符串）
> 3. 点「仅更新模型 ID」（沿用现有 Key），重新测试连接
>
> 也可以填入第三方代理网关的模型 ID（如部分公司内部 OpenAI 兼容网关），只要响应格式与官方一致即可工作。

**关键能力差异：**
- 只有 **Gemini** 支持 TTS 语音合成和 Google Search Web Grounding
- Claude / OpenAI / Gemini 都支持 Vision OCR

**安全保证：**
- API Key 经 Electron `safeStorage` 加密后写入本地 SQLite，渲染端无法读到明文
- AI 请求由你的 Mac 直接发往对应服务商，**SoloLedger 服务器不参与任何转发**
- 删除 Key 后该 Provider 立即停止可用，已生成的业务数据保留

**配置方式：**
- 首次启动会弹出 Onboarding 向导，可一次性配置一个或多个 Provider
- 后续在「系统设置 → AI 服务商」可随时新增、修改、删除 API Key，或切换默认 Provider
- 没有配置 Provider 时，AI 功能会显示「请在设置中配置 API Key」提示，不会直接报错

---

## 功能一览

| 模块 | 说明 |
|------|------|
| 📊 经营看板 | 实时库存、年度采购/销售总额、平均成本、月度趋势——全部从 D1 聚合，零硬编码 |
| 🔍 Agentic RAG | 六源并行搜索 → **Embedding 2 语义去重/排序** → 证据提取 → **MMR 精排** → AI 综合分析 → 评审迭代，最多 3 轮 |
| 🤖 AI 分析 | Gemini 多维分析（财务/销量/效率）、Monte Carlo 模拟、VAR 风险预测 |
| 🗣️ 语音交互 | TTS 播报（5 种音色）+ Native Audio 实时对话 |
| 💰 财务报表 | 损益表、增值税统计、税费汇总、利润率指标 |
| 🧾 发票查询 | 进项/销项发票汇总，支持日期·金额·重量·状态多维过滤 |
| 🛒 采购管理 | CRUD + 发票 OCR + 税额自动计算 + 含税总价自动反算 + CSV/Excel 批量导入 |
| 📈 销售管理 | CRUD + 发票 OCR + 运费核算 + 含税总价自动反算 + 实时库存（10 kg/袋） |
| 📉 价格趋势 | 搜索价格自动入库，趋势折线图，7/30/90 天涨跌统计 |
| 💳 应收应付 | 客户/供应商维度汇总，30/60/90/180 天账龄分析，收付款率 |
| 🔔 智能预警 | 逾期付款 + 价格异动，Cron 每日自动检查，未读计数 |
| ⚙️ 系统设置 | 公司信息、税率、AI 洞察开关、通知偏好，云端同步 |

---

## 架构

```
浏览器 (React 19 + TypeScript + Vite 6)
│
│  前端直连 Gemini
├── gemini-3.1-flash-lite ─ 财务分析 / OCR / 对话
├── gemini-2.5-flash-tts ── 语音播报 (5 音色)
├── gemini-2.5-flash-native-audio ── 实时语音对话
│
▼  同源请求 /api/*
Google Cloud Run (Express, port 8080)
├── 静态前端 (dist/)
├── Agentic RAG Agent 端点 ← Gemini API (同 GCP 内网, 低延迟)
│   ├── /api/agent/plan         规划 (问题分类 + 子查询)
│   ├── /api/agent/rank         语义排序去重 (Embedding 2, fallback 关键词)
│   ├── /api/agent/extract      证据提取
│   ├── /api/agent/synthesize   综合分析 (flash, 120s)
│   └── /api/agent/critique     评审 (flash, 120s)
│
├── 反向代理 /api/* ──────────────► Cloudflare Worker
│                                   ├── D1 SQLite (5 表)
│                                   ├── KV Cache (搜索结果, 30 min TTL)
│                                   ├── 六源搜索引擎
│                                   ├── CRUD (采购/销售/设置/预警)
│                                   └── Cron (每日 00:00 UTC)
```

### 为什么 Agent 端点在 Cloud Run？

Cloudflare Worker 有 **30 秒硬超时**，而 RAG 的 Extract/Synthesize 阶段处理 30-50 条证据时需要 40-120 秒。Cloud Run 与 Gemini API 同属 GCP，内网通信延迟更低，且超时可配置至 300 秒。

---

## Agentic RAG 流水线

```
用户查询
  │
  ▼
Plan ─── 分析问题类型 (price_comparison / market_trend / ...)，生成子查询
  │
  ▼
Search ─ 六源并行搜索 (Gemini Grounding · Brave · Tavily · 生意社 · 国际 · 电商)
  │
  ▼
Rank ─── Embedding 2 语义去重 (cosine > 0.85) + 多因子排序 (语义相关性 · 权威性 · 时效性 · 多样性)
  │
  ▼
Extract ─ 从排序结果中提取结构化证据 → MMR 精排 (λ=0.7, 平衡相关性与多样性)
  │
  ▼
Synthesize ─ AI 综合分析: 价格卡片 + 共识 + 矛盾 + 深度报告
  │
  ▼
Critique ─── 评审: 信息充分 → 完成 / 不足 → 生成补充查询 → 回到 Search
  │
  └──── 最多 3 轮迭代，证据池上限 50 条
```

### 关键参数

| 参数 | 值 | 说明 |
|------|----|------|
| 最大迭代 | 3 轮 | 每轮新增搜索→提取→综合→评审 |
| 证据池上限 | 50 条 | 超出时截断，保留高置信度证据 |
| Embedding 维度 | 256 (MRL) | `gemini-embedding-2-preview`，Matryoshka 降维 |
| 语义去重阈值 | cosine > 0.85 | 余弦相似度超阈值视为重复 |
| MMR λ | 0.7 | 70% 相关性 + 30% 多样性 |
| 前端阶段超时 | 30-180s | Plan 30s / Rank 30s / Synthesize 180s / Critique 60s |
| 服务端模型超时 | 120s | Synthesize/Critique 使用 `gemini-2.5-flash` |
| 搜索缓存 | 30 min | KV 存储，SHA-256(source:query) 为键 |

---

## AI 模型

| 用途 | 模型 | 位置 | 备注 |
|------|------|------|------|
| 财务分析 / 对话 / OCR | `gemini-3.1-flash-lite-preview` | 前端直连 | 结构化 JSON |
| 语音播报 TTS | `gemini-2.5-flash-preview-tts` | 前端直连 | 5 种音色 |
| 实时语音对话 | `gemini-2.5-flash-native-audio-preview` | 前端直连 | 流式麦克风 |
| RAG Plan / Extract | `gemini-3-flash-preview` → `gemini-2.5-flash` | Cloud Run | 双模型降级 |
| RAG Rank + Extract 精排 | `gemini-embedding-2-preview` | Cloud Run | 256 维 MRL，语义去重 + MMR |
| RAG Synthesize / Critique | `gemini-3-flash-preview` | Cloud Run | 单模型，120s 超时 |
| 六源搜索 (Worker) | `gemini-3.1-flash-lite` → `gemini-2.5-flash` | Worker | 双模型降级 |

---

## 快速开始

### 前提

- Node.js ≥ 20
- Gemini API Key — [申请](https://aistudio.google.com/apikey)
- Cloudflare 账号（Workers + D1 + KV）
- Google Cloud 账号（Cloud Run）

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

### 部署前端 + RAG (Cloud Run)

```bash
# 方式一：一键部署脚本
chmod +x deploy.sh && ./deploy.sh

# 方式二：gcloud CLI
gcloud run deploy ai-dashboard \
  --source . \
  --region us-central1 \
  --allow-unauthenticated \
  --timeout=300 \
  --set-env-vars "GEMINI_API_KEY=xxx,WORKER_API_URL=https://your-worker.workers.dev,API_TOKEN=xxx"

# 方式三：Docker 本地
docker build -t ai-dashboard .
docker run -p 8080:8080 \
  -e GEMINI_API_KEY=xxx \
  -e WORKER_API_URL=https://your-worker.workers.dev \
  -e API_TOKEN=xxx \
  ai-dashboard
```

---

## 环境变量

### 前端 `.env.local`

| 变量 | 必填 | 说明 |
|------|:----:|------|
| `VITE_API_KEY` | ✅ | Gemini API Key（前端直连用） |
| `VITE_API_BASE_URL` | ✅ | Worker 地址（开发模式用） |
| `VITE_API_TOKEN` | ✅ | Bearer Token（与 Worker 一致） |

### Cloud Run 环境变量

| 变量 | 说明 |
|------|------|
| `GEMINI_API_KEY` | Gemini 密钥（Agent 端点调用用） |
| `WORKER_API_URL` | Worker 地址（反向代理目标） |
| `API_TOKEN` | Bearer Token（与 Worker 一致） |

### Worker Secrets

| Secret | 说明 |
|--------|------|
| `API_TOKEN` | Bearer Token |
| `GEMINI_API_KEY` | Gemini 密钥 |
| `BRAVE_API_KEY` | Brave Search 密钥 |
| `TAVILY_API_KEY` | Tavily Search 密钥 |

---

## API 端点

所有 `/api/*` 需 `Authorization: Bearer <TOKEN>`。Worker 端限流 120 次/IP/60 s。

### Agent 端点 (Cloud Run 本地处理)

| 方法 | 路径 | 说明 |
|------|------|------|
| POST | `/api/agent/plan` | 查询规划：问题类型 + 子查询 |
| POST | `/api/agent/rank` | 语义排序去重（Embedding 2 + fallback 关键词） |
| POST | `/api/agent/extract` | 证据提取 |
| POST | `/api/agent/synthesize` | 综合分析（价格卡片 + 报告） |
| POST | `/api/agent/critique` | 质量评审 + 迭代决策 |

### 业务 CRUD (代理至 Worker)

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/api/dashboard?year=2026` | 全量聚合：库存、月度趋势、损益表、增值税 |
| GET/POST/PUT/DELETE | `/api/purchases[/:id]` | 采购 CRUD |
| POST | `/api/purchases/batch` | 采购批量导入（≤ 500） |
| GET/POST/PUT/DELETE | `/api/sales[/:id]` | 销售 CRUD |
| POST | `/api/sales/batch` | 销售批量导入 |
| GET | `/api/receivables/summary` | 应收汇总 + 账龄 |
| GET | `/api/payables/summary` | 应付汇总 + 账龄 |

### 六源搜索 (代理至 Worker)

| 方法 | 路径 | 说明 |
|------|------|------|
| POST | `/api/search/gemini` | Gemini Grounding |
| POST | `/api/search/brave` | Brave 代理 |
| POST | `/api/search/tavily` | Tavily 代理 |
| POST | `/api/search/direct` | 生意社直连 → Gemini 提取 |
| POST | `/api/search/international` | 国际源 |
| POST | `/api/search/ecommerce` | 电商源 |

> 搜索结果缓存在 KV，TTL 30 min，键 = SHA-256(source:query)。

### 其他 (代理至 Worker)

| 方法 | 路径 | 说明 |
|------|------|------|
| GET/PUT | `/api/settings` | 应用设置 |
| POST | `/api/price-history` | 保存搜索价格 |
| GET | `/api/price-history?query=&days=30` | 趋势查询 |
| GET | `/api/alerts` | 预警列表 |
| GET | `/api/alerts/count` | 未读数 |
| PUT | `/api/alerts/read-all` | 全部已读 |
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

## 目录结构

```
├── App.tsx                      # 主应用（路由/布局/语音/全局状态）
├── types.ts                     # TypeScript 类型（25+ 接口）
├── constants.ts                 # 初始数据模板 + AI 提示词
├── server.js                    # Cloud Run 入口 (Express)
├── Dockerfile                   # 多阶段构建 (build → serve)
├── deploy.sh                    # Cloud Run 一键部署
├── components/
│   ├── DataAnalysisPage.tsx     # AI 多维分析 + Monte Carlo + VAR
│   ├── MarketSearchPage.tsx     # Agentic RAG UI + 价格趋势图
│   ├── PurchaseAndInputPage.tsx # 采购管理
│   ├── SalesAndOutputPage.tsx   # 销售管理
│   ├── FinancePage.tsx          # 财务报表
│   ├── InventoryPage.tsx        # 发票查询
│   ├── AccountsPage.tsx         # 应收应付
│   ├── AlertCenter.tsx          # 预警中心
│   ├── CsvImportModal.tsx       # CSV/Excel 批量导入
│   └── SettingsPage.tsx         # 系统设置
├── hooks/
│   └── useAgenticSearch.ts      # RAG 流水线编排 (Plan→Search→Rank→Extract→Synthesize→Critique)
├── services/
│   ├── api.ts                   # API 客户端 (CRUD + Search + Agent)
│   ├── geminiService.ts         # Gemini AI 分析 (前端直连)
│   └── ocrService.ts            # 发票 OCR
├── contexts/
│   └── MarketDataContext.tsx     # 市场数据跨组件共享
├── server/                      # Cloud Run Agent 后端
│   ├── gemini.js                # Gemini API 调用 + 双模型降级
│   ├── embedding.js             # Gemini Embedding 2 (批量 embed + cosine + MMR)
│   ├── prompts.js               # RAG 提示词构建器
│   ├── schemas.js               # 响应 Schema 校验
│   └── ranking.js               # 语义排序 + 多因子排序 (fallback 关键词)
└── worker/
    ├── src/index.js             # Cloudflare Worker (CRUD + 搜索 + Cron)
    └── wrangler.toml            # D1 + KV + Cron 配置
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
npm run build     # 生产构建 → dist/
npm run preview   # 本地预览
npm start         # Cloud Run 生产启动（Express, 端口 8080）
```

---

## License

MIT © 2025–2026 alotie418
