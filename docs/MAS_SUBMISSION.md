# Mac App Store 上架 Runbook（MAS 线）

> 状态：**MAS-1 构建骨架已接线（entitlements ×2 + `electron-builder.mas.yml` + `build:mas`）；未创建 App Store Connect App、未上传、未提审。**
> 定位：**GitHub / Developer ID 直分发是正式主线**（runbook 见 [`RELEASE.md`](RELEASE.md)）；MAS 是独立上架线，两条线的配置与证书完全隔离、互不影响。
> 铁律：任何证书、密码、Team ID、provisioning profile 不入库、不出现在日志/汇报里。

---

## 1. 与 GitHub 版的关键差异（务必写进商店描述/FAQ）

- **数据容器不互通**：MAS 版运行在 App Sandbox 容器（`~/Library/Containers/com.alotie418.sololedger/`），与 GitHub 版的 `~/Library/Application Support/SoloLedger/` **完全隔离**——装 MAS 版不会看到 GitHub 版的既有数据。
- **迁移路径 = 现成的备份 bundle 流程**：GitHub 版「设置 → 导出备份」（DB + 附件文件夹）→ MAS 版「设置 → 恢复备份」选同一文件夹。两版功能一致，恢复流程经 #353 e2e 与 RC QA 验证。
- MAS 版无自动更新问题（App Store 托管更新）；`crashReporter`/`autoUpdater` 在 Electron MAS 构建变体中本就禁用（本应用两者皆未使用）。

## 2. 凭证与配置前置（人工，一次性）

1. **两张新证书**（都不是现有 Developer ID 证书）导入 login 钥匙串：
   - **Apple Distribution**（签 .app）
   - **Mac Installer Distribution**（签 .pkg）
2. 开发者门户：App ID `com.alotie418.sololedger` 注册 + 勾选 **App Sandbox** 能力 → 生成 **Mac App Store provisioning profile** → 下载放到 `build/embedded.provisionprofile`（**勿提交入库**）。
3. `build/entitlements.mas.plist`：把 `application-groups` 里的 `TEAM_ID` 占位符替换为真实 10 位 Team ID（Membership 页可查；Electron MAS 模板必需项——沙箱内 Helper 进程 Mach IPC 需要同组）。
4. `keychain-access-groups` **故意未配置**：safeStorage 在沙箱内走默认 Keychain；仅当 §5 QA 实测出 Keychain 问题再补。

## 3. 构建与上传

```bash
npm run build:mas
# 产物：release/ 下的 .pkg（Apple Distribution 签名 .app + Installer 签名 .pkg）
```

- ⚠️ 与 Developer ID 线相同的坑：**必须在非 iCloud 同步路径的 checkout 构建**（FinderInfo xattr 拒签，见 RELEASE.md §7）。
- 上传：**Transporter.app**（Mac App Store 免费下载）拖入 .pkg → 交付到 App Store Connect（`altool` 已退役；本仓库不做自动上传）。
- Info.plist 的 `ElectronTeamID` 由 electron-builder 从签名身份自动注入；若首次上传报缺失，在 `mas.extendInfo` 补。
- 首次上传如报 ITMS 用途声明缺失（Electron 框架引用 AVFoundation 等 API 所致），按报错在 `mas.extendInfo` 精确补对应 `NS*UsageDescription`，不预猜全集。

## 4. App Store Connect 准备清单

- [ ] ASC 新建 App（名称 SoloLedger · 类别 Finance · Bundle ID 关联）
- [ ] 隐私政策 **URL**（`PRIVACY.md`/`PRIVACY.en.md` 内容托管为可公开访问页面）+ 支持 URL
- [ ] App 隐私标签问卷（如实：不收集数据 · 全本地存储 · BYOK 出网是用户主动配置第三方服务）
- [ ] 出口合规（仅标准 HTTPS 加密 → 豁免声明）
- [ ] 截图（≥1 张，1280×800 / 2560×1600 等规格）+ 描述/副标题/关键词（**电商 Beta 口径与 README 一致，不夸大**）
- [ ] 年龄分级问卷 + 定价（免费/付费属产品决策）/ 地区
- [ ] TestFlight 内测组（强烈建议先 TestFlight 再提审）

## 5. MAS 沙箱 QA 必测清单（TestFlight 或 mas-dev 本地构建）

> 本地调试构建：临时把 `electron-builder.mas.yml` 的 target 改 `mas-dev` + `mas.type: development` + Apple Development 证书 + development profile（改动勿提交）。

- [ ] **文件流全链路（Powerbox）**：备份导出（⚠️ 重点：save 对话框选路径后**建文件夹写多个子文件**）→ 恢复（选文件夹/旧 .db）→ CSV 导出 → PDF 导出 → 附件挑选/打开 → Excel/CSV 导入（`/Users/Shared/sololedger-import-qa*` 四文件可复用）
- [ ] **network.client**：AI provider 测试连接 + （如有店铺）电商测试连接/拉单
- [ ] **safeStorage**：沙箱容器内首次保存 AI Key → 退出重开可解密；无 Keychain 弹窗异常
- [ ] 断网启动 + 核心记账流程（容器内 SQLite 读写、启动自动快照）
- [ ] OCR：挑选 PDF/图片 → 本地栅格化 → 回填（@napi-rs/canvas 在沙箱内加载）
- [ ] 演示模式确认**不可进入**（gate 含 `!app.isPackaged`，MAS 构建为 packaged——预期不可用）

## 6. 边界

- 本文件与 MAS-1 配置**不改动** Developer ID 线（`electron-builder.dmg.yml` / `build/entitlements.mac.plist` / RELEASE.md 流程零变化）。
- 未创建 ASC App、未上传、未提审；何时推进由维护者决策。
