# SoloLedger 1.0.1 — Mac App Store 重新提审说明（无 AI 版）

本文件汇总本次（1.0.1）重新提审所需的 App Store Connect 手动操作、给 App Review 的英文回复，
以及本地签名打包前你需要准备的凭据。分支：`chore/mas-resubmit-1.0.1`。

> 本构建刻意**不含**任何外部 AI / API-Key 功能（BYOK 已从 MAS 移除）。服务端代理版 AI 规划见
> `feat/mas-sololedger-ai` 分支的 `docs/AI_PROXY_PLAN.md`，留待 1.1。

---

## App Store Connect 手动操作清单

1. **副标题（Subtitle）** → 改为 `Private Bookkeeping`（避免 Guideline 5.2.5 的 “Mac” 商标用法）。
2. **Support URL** → 先把 `docs/support/index.html` 部署到公开支持站
   `https://alotie418.github.io/sololedger-legal/support/`（部署前把页面内的
   `[在这里填写你的公开支持邮箱]` 占位符替换为真实、可长期监看的支持邮箱），再在 ASC 把
   Support URL 指向该地址（不要再指向源码仓库 README）。
3. **构建号** → 上传本地 `npm run build:mas` 产物后，为该版本选择 **Build 1.0.1**。
   Marketing Version 保持 `1.0`（`electron-builder.mas.yml` 里 `buildVersion: "1.0.1"`，
   `package.json` version 仍 `1.0.0`）。
4. **App Review Information** → 备注见下方英文回复；无需提供测试账号或 API Key。
5. **App Privacy** → 本无 AI 版不再向第三方发送账本数据；如既往标注为本地存储、不收集用于追踪的数据
   （若之前的标签基于 BYOK/AI 描述，请据实回退）。

---

## 给 App Review 的英文回复（可直接粘贴）

Hello,

Thank you for the review. This build (1.0.1) addresses all five items:

**Guideline 5.2.5** — The subtitle no longer uses "Mac"; it is now "Private Bookkeeping".

**Guideline 1.5** — The Support URL now points to a dedicated support page (not a
source-code README): https://alotie418.github.io/sololedger-legal/support/ — with an
overview, a contact email, FAQs, a Privacy Notice link, and a way to report issues.

**Guideline 3.1.1** — This build no longer contains any external-API-key functionality.
The AI provider / API-key settings, the AI assistant, the AI dashboard briefing, and the
invoice OCR feature have all been removed — both the user-facing entry points and the
underlying code (the AI modules are excluded from the app package and their routes are not
registered; the bundle contains no third-party model-provider integrations). There is no
way to enter, store, or use an external API key, and no functionality is unlocked by one.

**Guideline 2.1(a)** — No feature in this build depends on an external API key. All of the
bookkeeping features included in this build can be reviewed with no account, no API key,
and no external purchase of any kind. The core ledger data is stored locally on the device.

**Guideline 4** — We added an application menu item, Window > SoloLedger (Command-0), that
reopens the main window; clicking the app's Dock icon reopens it as well. Closing and
reopening the window never loses saved data.

Thank you.

---

## 本地签名打包前置（你需要准备）

签名版 `npm run build:mas` 需要以下凭据（当前环境缺失，未运行签名构建）：

| 前置 | 说明 |
|---|---|
| **Apple Distribution** 证书 | 用于签名 `.app`；安装进登录钥匙串 |
| **Mac Installer Distribution** 证书 | 用于签名 `.pkg`；安装进登录钥匙串 |
| `build/embedded.provisionprofile` | App ID `com.alotie418.sololedger` 的 Mac App Store provisioning profile，放到该仓库相对路径（不提交入库） |
| Team ID `6Z4W7D8JSU` | 已写入 `build/entitlements.mas.plist`，无需处理 |

准备好后运行：

```bash
npm run build:mas
```

完整流程见 `docs/MAS_SUBMISSION.md`。

### 已完成的免签名验证（供参考）

- `typecheck` 通过；默认 + MAS 构建成功；`check:all` 379/379。
- 真机 Electron（MAS 模式）：Window 菜单含 “SoloLedger”（⌘0）重开项；关窗后 Dock 与菜单项均可重开。
- 真机 4 屏（欢迎 / 语言 / 主界面 / 设置）无任何可见 AI 文案。
- 免签名 `--dir` 打包的 `app.asar`：无 `electron/ai/**`、无 `handlers/ai.js` / `conversations.js`、
  无厂商 logo/名文件；核心记账文件齐全。

> 你安装好证书与 profile 后，我可再运行正式 `npm run build:mas`，复核签名、entitlements、profile、
> 安装包内容与产物路径。
