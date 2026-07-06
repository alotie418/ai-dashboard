# SoloLedger 独账

面向**一人公司 / 个体经营者**的本地优先(local-first)桌面记账与经营管理应用。覆盖采购、销售、库存、发票、业务单据、应收应付、经营损益与数据分析等场景——**所有数据存在你自己的 Mac 上**,AI 能力由你**自带的 API Key(BYOK)**驱动,不经过任何 SoloLedger 服务器。

[![macOS](https://img.shields.io/badge/macOS-12+-000000?logo=apple)](https://www.apple.com/macos/)
[![Electron 42](https://img.shields.io/badge/Electron-42-47848f?logo=electron)](https://www.electronjs.org)
[![React 19](https://img.shields.io/badge/React-19-61dafb?logo=react)](https://react.dev)
[![TypeScript 5.8](https://img.shields.io/badge/TypeScript-5.8-3178c6?logo=typescript)](https://www.typescriptlang.org)
[![better-sqlite3](https://img.shields.io/badge/SQLite-better--sqlite3-003b57?logo=sqlite)](https://github.com/WiseLibs/better-sqlite3)

---

## ⚠️ 重要声明 —— 产品边界

SoloLedger 是一个**经营管理估算工具**,帮助小微经营者把日常采购/销售/费用整理成易读的经营视图与**估算**性质的税务参考。

> **它不是法定会计软件,不出具法定财务报表,不做自动报税,不能替代会计师 / 税务师。**
> 报表与税额均为**按你录入数据的管理估算**,口径经过简化(例如所得税按单一税率估算、增值税附加按默认假设)。正式申报、审计与合规请以专业会计师 / 税务机关口径为准。

应用内每个报表、税务与 AI 输出界面都会显示对应的免责声明。会计口径的进一步精确化属于待会计师确认事项,详见 [`docs/ROADMAP-to-v1.md`](docs/ROADMAP-to-v1.md)。

---

## 功能一览

| 模块 | 说明 |
|------|------|
| 📊 经营看板 | 年度采购/销售、库存、毛利、月度趋势等关键指标,与利润表同源聚合 |
| 🤖 AI 助手 | 对话式助手,可**只读**调用账本工具查账(汇总/列表/明细),不会修改任何数据 |
| 🛒 采购与进项 | 采购 CRUD + 发票 OCR + 税额自动计算 + 含税总价自动反算 + CSV/Excel 批量导入 |
| 📈 销售与销项 | 销售 CRUD + 发票 OCR + 运费核算 + 含税总价自动反算 + 实时库存 |
| 🛍️ 电商订单导入 | Shopify / WooCommerce 订单拉取 → 暂存 → 预览 → 提交入账辅助(写入销售);孤儿单解锁重提;隔离演示模式。**记账辅助,非税务合规/ERP**,详见下文 |
| 🧾 发票查询 | 进项/销项发票汇总,按日期·金额·状态多维过滤 |
| 📄 业务单据 | 报价/订单等业务单据生成,支持 PDF 导出与附件 |
| 📉 数据分析 | 多维经营分析与趋势预测(预测为简化估算模型,仅供管理参考) |
| 💳 应收应付 | 客户/供应商维度汇总,账龄分析,收付款率 |
| 💰 财务报表 | 经营损益概览(利润表 / Schedule C 口径);管理口径资产负债概览已提供(只读·非法定),现金流概览开发中 |
| 🧮 收支记录 | 全量交易流水,支持成本类型(COGS/经营费用)与批量重分类 |
| 🇺🇸 美国税务工具 | Schedule C、自雇税(SE-tax,按年表)、里程与家庭办公室扣除估算 |
| ⚙️ 系统设置 | 公司信息、记账口径、税率、分类管理、AI 服务商、数据备份/恢复 |

> 早期版本中的「语音播报 / Native Audio 实时对话」「Agentic RAG 联网搜索 / 价格趋势」「Web Grounding」已在桌面版中移除,本说明不再包含相关内容。

---

## 多记账口径 × 多界面语言

「**记账口径(accountingLocale)**」与「**界面语言(uiLanguage)**」相互独立,可自由组合:

- **6 套记账口径**:🇨🇳 中国(增值税)· 🇺🇸 美国(Schedule C / 自雇税)· 🇯🇵 日本(消費税)· 🇰🇷 韩国(부가가치세)· 🇪🇺 欧盟(VAT)· 🇹🇼 台湾(營業稅)。每套有独立的报表引擎与税额估算逻辑。
- **6 种界面语言**:简体中文 · 繁體中文 · English · 日本語 · 한국어 · Français。

切换记账口径会切换报表/税务的计算口径与术语;切换界面语言只改 UI 文案。两者在「系统设置」中分别配置。

---

## BYOK —— 自带 API Key,支持 8 家服务商

SoloLedger **不内置任何 AI 后端**。在「系统设置 → AI 服务商」或首次启动的引导向导中填入你自己的 Key 即可,支持任意组合、随时切换默认服务商。

| 服务商 | 默认 model ID(可改) | 发票 OCR | 调用方式 |
|---|---|:---:|---|
| **Claude (Anthropic)** | `claude-sonnet-4-6` | ✅ | `/v1/messages` |
| **ChatGPT (OpenAI)** | `gpt-5.5` | ✅ | `/v1/responses` |
| **Gemini (Google)** | `gemini-3.5-flash` | ✅ | `@google/genai` SDK |
| **DeepSeek 深度求索** | `deepseek-chat` | — | OpenAI 兼容 Chat Completions |
| **Qwen 通义千问** | `qwen-plus` | ✅ | OpenAI 兼容 Chat Completions |
| **Kimi (Moonshot)** | `moonshot-v1-128k` | ✅ | OpenAI 兼容 Chat Completions |
| **GLM 智谱** | `glm-4.6` | ✅ | OpenAI 兼容(`/api/paas/v4`) |
| **Doubao 豆包(火山方舟)** | `doubao-seed-2-0-pro-260215` | ✅ | 火山方舟 Ark(`/api/v3`) |

- **发票 OCR**:除 DeepSeek 外的 7 家均支持视觉 OCR;若当前默认服务商不支持 OCR,会**自动回退**到一个支持 OCR 的已配置服务商。OCR 结果先进入预览,**经你确认后才回填表单**,不会自动入账。
- **AI 助手工具调用**:助手只能调用**只读**查账工具,无法新增/修改/删除任何账目。

> **关于 model ID(请务必阅读)**:上表是出厂默认字符串,**不保证对应你账号下当前可用的模型**。各家会持续发布、下线、改名模型。若「测试连接」报 `model_not_found` / `invalid_model` / `HTTP 404`:
> 1. 去对应服务商官网查你当前可调用的精确 model ID(通常带日期后缀);
> 2. 在「系统设置 → AI 服务商」里直接改 model ID(可自由输入任意字符串);
> 3. 点「仅更新模型 ID」(沿用现有 Key),重新测试连接。
>
> 也可填入第三方 OpenAI 兼容网关的 model ID,只要响应格式与官方一致即可工作。

---

## 🛍️ 电商订单导入(MVP)

把电商平台的**订单数据**导入本地账本,作为**记账与经营分析的输入**,定位为**记账辅助 / 经营管理**工具。

- **已接线平台**:Shopify(`manual_token`,锁定 `*.myshopify.com`)· WooCommerce(`key_secret`,仅 HTTPS)。其余平台目前**仅在平台目录中分档展示 / 规划中,尚未接线**。
- **闭环能力**:连接管理(添加 / 测试 / 启停 / 编辑 / 删除)→ 手动拉单暂存(`(connection, external_order_id)` 幂等)→ 预览(行明细 + 运费 / 税 / 费用 / 退款**仅信息展示**,商品按**名称精确匹配**)→ 提交入账辅助(两遍式**全或无**,写入 `sales` / `sales_items`,整单对账守卫)→ 孤儿单解锁重提 → **隔离演示模式**(`npm run electron:demo`,数据隔离到 `userData/demo/`,纯内存零网络)。
- **安全与隐私**:平台凭证经 `safeStorage` 加密入库,渲染进程**永不**接触明文 / 密文,出网仅在主进程;买家姓名 / 邮箱 / 电话 / 地址**永不落库**,原始 payload 不持久化(PII 最小化)。
- **产品边界**:本模块**不是**自动税务合规、自动会计合规,也**不是**完整电商 ERP。写入金额为**平台报告的原样数值**,不自行判定税收政策或会计科目;**运费 / 平台费用 / 退款暂不进入账本**,涉及会计政策的处理(EC6)留待会计师确认。能力权威清单见 [`docs/ECOMMERCE_MVP_STATUS.md`](docs/ECOMMERCE_MVP_STATUS.md)。

---

## 数据与隐私

- **本地优先**:全部业务数据存于本地 SQLite(`better-sqlite3`,位于应用的 `userData` 目录),无云端账户、无服务器存储,核心记账功能可完全离线使用。
- **API Key 加密**:Key 经操作系统 `safeStorage`(macOS Keychain)加密后写入本地数据库,渲染端拿不到明文;删除 Key 后对应服务商立即停用,已录入业务数据保留。这是本机本地加密,**非端到端加密**。
- **请求直连**:AI 请求由你的电脑**直接发往你选择的服务商**,不经过任何 SoloLedger 服务器。使用 AI 助手时会发送你的提问及助手查询到的账本数据(可能含账目明细);看板 AI 简报发送经营汇总数据;OCR 发送单据图像。「数据分析」页指标在本地计算,不调用 AI。各服务商的数据留存与训练做法由其自身政策决定,请自行查阅。
- **本地文件处理**:CSV/Excel 导入导出、PDF 栅格化均在本地完成;但若用 PDF/图像做 OCR,栅格化后的图像会发送给服务商。
- **无遥测/后台回传**:除你打开外部链接或主动使用 AI 功能外,当前版本不内置后台联网、遥测、崩溃上报、自动更新或 phone-home 行为,也不向磁盘写日志。
- **备份与恢复**:手动备份导出为文件夹 bundle(含数据库 + 发票附件 `attachments/docs`);覆盖性操作前在本机 `userData/backups` 生成自动备份(校验 + 原子替换);恢复时附件按「只增不删」合并。备份均为本地文件,请自行妥善保管。

> 完整隐私说明见 [`PRIVACY.md`](PRIVACY.md)。

---

## 技术栈

- **桌面**:Electron 42(主进程 `electron/`,IPC 白名单 + `contextIsolation`)
- **前端**:React 19 + TypeScript 5.8 + Vite + Tailwind(构建期打包,离线自托管全部静态资源)
- **存储**:`better-sqlite3`(同步、事务化、WAL),迁移按 `PRAGMA user_version` 版本化
- **AI**:`@google/genai`(Gemini SDK)+ 各家 REST;统一适配层 `electron/ai/providers/*`
- **其它**:`pdfjs-dist`(OCR 前 PDF 首页栅格化)· `papaparse` + `xlsx`(CSV/Excel 导入)· `recharts`(图表)· `react-markdown` + `remark-gfm` + `rehype-sanitize`(AI Markdown 渲染)· `i18next` / `react-i18next`(国际化)

---

## 快速开始

> 仅支持 macOS(Apple Silicon)。需要 Node.js 20+。

```bash
git clone https://github.com/alotie418/ai-dashboard.git
cd ai-dashboard
npm install                 # postinstall 会为 Electron 重建 better-sqlite3 原生模块

# 开发(Vite + Electron 一起起,Vite 跑在 :3000)
npm run electron:dev

# 若原生模块版本不匹配,手动重建后再起
npm run electron:rebuild
```

### 打包 DMG

```bash
npm run build:dmg
# 产物:release/SoloLedger-<version>-arm64.dmg
```

> 当前 DMG 为**本地自用、未签名/未公证**的 Apple Silicon 构建,首次启动需在「访达」中右键 →「打开」过一次 Gatekeeper。代码签名、公证、universal/Intel 构建与自动更新属路线图项(见 [`docs/ROADMAP-to-v1.md`](docs/ROADMAP-to-v1.md))。

---

## 质量守卫与测试

仓库内置 20+ 个 `check:*` 守卫脚本(报表口径不变量、COGS 拆分、税额标签、免责声明挂载、AI 语气、服务商 registry 一致性、离线资源、国际化 key 矩阵等)与基于 Playwright 的界面验收 `test:locale-ui`。常用:

```bash
npm run check:cogs-split      # 报表 COGS/经营费用拆分 + 净利不变量
npm run check:report-source   # 看板与 P&L 同源的报表来源选择
npm run check:metrics         # mom/yoy/deflator 等指标计算
npm run check:providers       # 8 家服务商 registry 一致性
npm run check:disclaimer      # 免责声明挂载点 + i18n 齐备
npm run test:locale-ui        # vite build + Playwright 六语言界面验收
```

> 现状:以上守卫、数据库迁移测试、构建与 Playwright 界面 e2e 已纳入 CI(`.github/workflows/ci.yml`,每次 push/PR 自动运行);仍待补的是**真 Electron(打包应用)端到端测试**——CI 中 e2e 由 Playwright 驱动 vite preview、`electronAPI` 被 mock,不启动 Electron 运行时。

---

## 目录结构(桌面版核心)

```
├── App.tsx                  # 主应用:路由 / 布局 / 全局状态
├── components/              # 页面与 UI 组件(看板、采购、销售、财务、设置、助手…)
├── services/                # 前端服务层(api.ts IPC 客户端、ocrService、aiBriefingService…)
├── i18n/locales/*.json      # 6 种界面语言文案
├── hooks/  contexts/        # React hooks 与上下文
├── electron/
│   ├── main.js  preload.js  # 主进程入口 / 预加载桥
│   ├── handlers/            # IPC 业务处理(采购/销售/库存/单据/交易/报表/设置…)
│   ├── reports/             # 6 套记账口径报表引擎(cn/us/jp/kr/eu/tw + 拆分/税表)
│   ├── ai/                  # AI 统一接口 + 8 家 provider 适配 + 工具调用 + OCR
│   ├── ecommerce/           # 电商连接/拉单/暂存/提交入账 + provider 适配(Shopify/Woo/demo)
│   └── db/                  # SQLite schema、迁移、分类种子
├── scripts/                 # check:* 守卫脚本
├── e2e/                     # Playwright 界面验收
└── docs/                    # ROADMAP-to-v1.md / ECOMMERCE_MVP_STATUS.md / PRE_RELEASE_CHECKLIST.md 等
```

> 早期 Web 版遗留代码(`server.js` / `server/` / `worker/`,即 Express + Cloudflare Worker/D1)已于 #154 从仓库删除,历史保留在 `archive/web-legacy` 分支;桌面包从不包含该 Web 栈。

---

## 许可证

**专有软件,保留所有权利**(© 2026 alotie418. All rights reserved.)。未经版权持有人明确的事先书面许可,不得复制、修改、分发或用于商业用途。未来是否以开源协议发布尚未确定。完整条款见 [`LICENSE`](LICENSE)。
