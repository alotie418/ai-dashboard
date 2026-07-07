# macOS 签名 / 公证实施只读方案（Signing & Notarization Plan）

> 状态：**只读方案 / 未接线（READ-ONLY PLAN — NOT WIRED）**
> 文档日期：2026-07-05 ｜ 基线：main HEAD `4637b44`（schema v23·working tree clean）
> 本文件仅固化「macOS 代码签名 + 公证」的实施方案，**不改 `electron-builder.dmg.yml` / `package.json` / `package-lock` / `build/` / 任何代码**。实际接线与执行为后续独立 PR，需 Apple 账号 + 显式授权。
> **前置状态更新（2026-07-07·main `3fc241e`）**：§0 要求的两项前置已落地——**Electron 升级（#348·E42.6.0 + better-sqlite3 12.11.1 过渡）**与**生产 CSP enforce（#349）**；sandbox 亦已加固 true（#343）；Apple 凭证已备。剩余执行门控 = **E43/E42 止损决策**（better-sqlite3 12.11.2 截至 2026-07-07 未上 npm；超期可按 E42 直接公证）。执行顺序：决策 → `build/entitlements.mac.plist` → `dmg.yml` 接线 → 公证 → 干净机断网冒烟；**§0 的 safeStorage 旧 Key 重录风险须以用户须知形式随执行 PR 落地**。本方案其余内容仍有效。

---

## 0. 一句话结论

当前是自洽的「本地自用未签名 DMG」（`identity:null` · `hardenedRuntime:false` · 无 entitlements · 无 notarize）。转签名+公证的**最小方案**成型清晰：electron-builder 25.1.8 **内建** `mac.notarize`（走系统 `notarytool`，公证引擎与最新版逐字节相同），**不需要手写 afterSign 钩子**。

**关键排序：签名/公证是发布线的最后一步**——必须在 **Electron 43 + CSP 都落地后**，对最终、完整的构建**公证一次**；对 EOL 的 E33 或缺 CSP 的构建公证 = 白公证 + 返工。

**现在能做的只有两件**：① 纯文档（本方案，PR-A）；② 并行启动 **Apple Developer 账号注册**（$99/年，真实身份，约 1–2 天审批）。其余全部等 Apple 证书 + Electron 43 + CSP。

**唯一有感的迁移风险 = safeStorage**：未签名→签名换了代码签名身份 → Keychain ACL 变 → 旧的 AI Key / 电商凭证解不开 → **用户需重录**（业务数据 DB 不受影响；当前未对外分发，爆炸半径≈开发者自己的机器）。

---

## 1. 当前状态核对

| 项 | 现状 | 出处 |
|---|---|---|
| 签名 | **无** · `identity: null`（adhoc · `Identifier=Electron` · spctl rejected） | `electron-builder.dmg.yml:38` |
| 硬化运行时 | `hardenedRuntime: false` | `:39` |
| entitlements | **无文件**（`build/` 仅 icon-source.png / icon.icns） | `build/` |
| notarize 接线 | **无**（无 afterSign · 无 mac.notarize） | 全仓 grep |
| `@electron/notarize@^2.5.0` | 装着但**零引用**（内建路径不需直接引用它） | `package.json:86` |
| 架构 | `arch: arm64`（单架构） | `:37` |
| appId / productName | `com.alotie418.sololedger` / `SoloLedger`（签名后**不变**） | `:4-5` |
| 自动更新 | `publish: null`（关闭 · 无 electron-updater） | `:11` |
| 产物 | `release/SoloLedger-0.1.0-arm64.dmg`（未签名 · 148MB） | `release/` |
| 凭证 gitignore | `.env` / `.env.production` / `.env.local` **已 gitignore** | `.gitignore:25-27` |
| electron-builder | 25.1.8 · 内建 `@electron/notarize 2.5.0`→notarytool（引擎与 26.x 同） | [`ELECTRON_UPGRADE_ASSESSMENT.md`](ELECTRON_UPGRADE_ASSESSMENT.md) |

---

## 2. 前置准备（Apple 账号 + 证书 + 凭证）

1. **Apple Developer Program**：$99/年，个人或组织（组织需 D-U-N-S）。审批约 1–2 天。**这是唯一现在就能并行启动的实体动作。**
2. **Developer ID Application 证书**（注意：是 Developer ID，**不是** Mac App Store 证书——DMG 直分发走 Developer ID）：Xcode 或开发者门户生成 → 导出 `.p12`（含私钥）。
3. **公证凭证二选一**：
   - **App-specific password**（简单/本机）：appleid.apple.com 生成（非 Apple ID 主密码）。配 `APPLE_ID` + `APPLE_APP_SPECIFIC_PASSWORD` + `APPLE_TEAM_ID`。
   - **App Store Connect API Key**（推荐 CI）：`.p8` + Key ID + Issuer ID。不绑个人密码、更适合自动化。
4. **Team ID**：开发者门户「Membership」可查（10 位）。

---

## 3. 目标配置（electron-builder.dmg.yml 改动 + entitlements）

> 以下为**目标态参考**，本方案不写入任何文件。

### 3.1 `electron-builder.dmg.yml`（mac 节改动）

```yaml
mac:
  category: public.app-category.finance
  icon: build/icon.icns
  target:
    - target: dmg
      arch: arm64                       # 保持单架构（见 §7）
  # identity: null 删除 → electron-builder 从钥匙串/CSC 自动探测 Developer ID
  # 或显式：identity: "Developer ID Application: <Name> (<TEAMID>)"
  hardenedRuntime: true                 # 公证硬前提
  gatekeeperAssess: false               # 构建期跳过本地 spctl 评估（公证前必失败）
  entitlements: build/entitlements.mac.plist
  entitlementsInherit: build/entitlements.mac.plist
  notarize: true                        # 见 §3.3 —— 只写 true，凭证全走环境变量
```

electron-builder 自动：签名 .app（含解包的 `.node`）→ notarytool 公证 → staple .app → 打 DMG。**无需手写 afterSign。** 死依赖 `@electron/notarize` 可删可留（app-builder-lib 自带副本）。

### 3.2 `build/entitlements.mac.plist`（新建 · 最小集）

**最小集只写两项**（V8 JIT 所需）：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.cs.allow-jit</key><true/>
  <key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
</dict>
</plist>
```

**`com.apple.security.cs.disable-library-validation` = 条件 fallback，先不写**：
- electron-builder 用同一 Developer ID 证书签名 asarUnpack 的原生 `.node`（`better-sqlite3` / `@napi-rs/canvas`），通常无需放开库校验。
- **仅当**签名版启动时加载这些 `.node` 失败（典型报错含 `library load disallowed by system policy` / `code signature invalid`）**才追加**该项：
  ```xml
  <key>com.apple.security.cs.disable-library-validation</key><true/>
  ```
- 不含摄像头/麦克风/网络服务器等权限（本应用不用）。

> 注：electron-builder 有内建默认硬化 entitlements，即使不提供自定义 plist 也能跑通；显式提供只为可复现/可审 + 收紧到最小集。

### 3.3 notarize 凭证走环境变量（不在配置里硬写）

配置文件里**只写 `notarize: true`**，**不硬写 `teamId`**。公证凭证全部通过环境变量注入，electron-builder 自动读取：

```
APPLE_ID="<你的 Apple ID 邮箱>"
APPLE_APP_SPECIFIC_PASSWORD="<app 专用密码>"
APPLE_TEAM_ID="<10 位 Team ID>"
```

这样 `electron-builder.dmg.yml` 里不含任何账号/团队标识，凭证与配置解耦、也不进版本库。

---

## 4. 凭证注入方式（本机钥匙串 vs CSC_LINK）

| 场景 | 签名凭证 | 公证凭证 |
|---|---|---|
| **本机手动**（单人推荐） | Developer ID 证书导入 login 钥匙串 → electron-builder **自动探测**（删 `identity:null` 即可） | `APPLE_ID` + `APPLE_APP_SPECIFIC_PASSWORD` + `APPLE_TEAM_ID` 环境变量（shell export 或 gitignored `.env.local` 源入） |
| **CI**（未来） | `CSC_LINK`=`.p12` 的 base64/路径 + `CSC_KEY_PASSWORD`，导入临时钥匙串 | API Key（`.p8`）或同上三变量，全走 CI secrets |

本机路线最简：证书进钥匙串 + 三个环境变量，`npm run build:dmg` 即出签名+公证 DMG。

---

## 5. Secrets 不入库原则

- **绝不提交**：`.p12` / `.p8` 证书、`CSC_KEY_PASSWORD`、`APPLE_ID`、`APPLE_APP_SPECIFIC_PASSWORD`、`APPLE_TEAM_ID`、API Key。
- 本机：证书放钥匙串（不落仓库目录）；环境变量放 gitignored `.env.local`（已 ignore）或 shell profile。**建议 `.gitignore` 补 `*.p12` / `*.p8` 兜底**（防误放仓库目录）。
- CI：全部走 GitHub Actions encrypted secrets。
- 汇报纪律：任何汇报里**不回显凭证**。

---

## 6. safeStorage 签名切换 → 旧凭证需重录（用户提示）

**机制**：macOS safeStorage 的加密密钥存 Keychain，其 ACL 绑代码签名身份。未签名（adhoc）→ Developer ID 签名 = 身份变 → 旧 Keychain 条目对新签名不可访问 → `ai_providers.api_key_encrypted` / 电商 `credentials_encrypted` **解不开**（代码会抛「safeStorage 无法解密」）。

**影响面**：
- ✅ **业务数据 DB / 附件 / 备份不受影响**（appId/productName 不变 → `userData` 路径不变）。
- ⚠️ **AI Key + 电商凭证需在「系统设置」重录一次**（沿用现有「删 Key→重录」路径）。
- 爆炸半径极小：应用尚未对外分发，受影响的≈开发者自己装过未签名版的机器；新装用户无感。

**待办（必做）**：
1. 首个签名版**发布说明**明确写：「升级后需重新填入 AI Key 与电商凭证，业务数据（记账/库存/单据/备份）不受影响。」
2. QA 核对解密失败时 UI 是**可操作的重录提示**而非崩溃（现有 `isEncryptionAvailable` / throw 路径应已 graceful，需真机确认）。

---

## 7. arm64-only 是否保持

**建议 v1 保持 arm64-only。** universal 需要 x64 的 `better-sqlite3` + `@napi-rs/canvas` 双架构原生二进制（本机现仅装 arm64），electron-builder lipo 合并易踩坑。Intel 覆盖属独立分发决策，可后续单出 x64 DMG。签名/公证流程对 arm64/universal 一致，不受此决策影响。

---

## 8. 未签名 → 签名 DMG 迁移风险

| 风险 | 说明 | 处置 |
|---|---|---|
| **safeStorage 重录**（主要） | 见 §6 | 发布说明 + QA 解密失败 UX |
| 版本纪律 | `release/` 现有 0.1.0 未签名 DMG；签名版应 bump 版本、勿新旧混发 | 打 tag + 只发签名版 |
| 首启行为变好 | 未签名需右键→打开；签名+公证+staple **联网/断网都直接打开**，无 Gatekeeper 拦截 | 改善，非风险 |
| 无自动更新 | `publish:null`，用户手动替换 .app；签名不改变这点（替换时触发 §6 重录） | 发布说明写清 |
| userData 兼容 | appId/productName 不变 → DB/备份/附件全兼容，无数据迁移 | 无需动作 |

---

## 9. 最小 PR 拆分

| PR | 内容 | 何时 | 风险 |
|---|---|---|---|
| **PR-A 纯文档** | 本文档 + `PRE_RELEASE_CHECKLIST` 指针 | **现在可做（= 本 PR）** | 零 |
| **PR-B 配置接线** | `electron-builder.dmg.yml`（删 `identity:null` · `hardenedRuntime:true` · `notarize:true` · entitlements 引用）+ 新建 `build/entitlements.mac.plist`（最小两项）+（可选）`.gitignore` 补 `*.p12`/`*.p8` +（可选）删死依赖 @electron/notarize | **Apple 证书就绪 + 在 E43+CSP 构建上** | 中（配置惰性，靠 secrets 激活） |
| **PR-C 执行验证**（多为人工/CI runbook，非代码 PR） | 设 env secrets → `build:dmg` → codesign/spctl/stapler 验证 → 干净机断网 Gatekeeper 冒烟 → 打 tag 发布 | **PR-B 之后，最终构建上** | 中（真机验收） |

> PR-C 可沉淀为 `docs/RELEASE.md` runbook。PR-B 的**配置**虽与 Electron 版本无关（可早写），但**首个真公证的构建必须是最终版**（E43+CSP），故 PR-B/C 一起在最后做，只公证一次。

---

## 10. 验证命令

```bash
# 签名+公证 build:dmg 之后：
codesign -dv --verbose=4 release/mac-arm64/SoloLedger.app
#   期望：Authority=Developer ID Application: <Name> (<TEAMID>)；flags=runtime(硬化)
codesign --verify --deep --strict --verbose=2 release/mac-arm64/SoloLedger.app
spctl -a -vvv -t exec release/mac-arm64/SoloLedger.app
#   期望：accepted；source=Notarized Developer ID
xcrun stapler validate release/mac-arm64/SoloLedger.app
xcrun stapler validate release/SoloLedger-<version>-arm64.dmg
#   期望：The validate action worked!
```

**干净机断网 Gatekeeper 冒烟**（最终门槛）：把 DMG 拷到**从未装过本应用**的 Mac → **断网** → 打开 DMG → 拖入「应用程序」→ 启动。**期望：无「无法验证开发者」拦截、无 Gatekeeper 提示、离线直接打开**（staple = 公证票据随包，离线可验）。再跑一遍核心记账 + safeStorage 重录流程。

---

## 11. 现在能做 / 必须等

| 事项 | 时点 | 原因 |
|---|---|---|
| PR-A 纯文档方案 | **✅ 现在（本 PR）** | 零依赖 |
| 启动 Apple Developer 注册 | **✅ 现在（并行）** | 实体动作，约 1–2 天，不依赖代码 |
| 生成 Developer ID 证书 / app-specific password / Team ID | **等 Apple 账号后** | 前置凭证 |
| PR-B 配置接线 | **等 Apple 证书 + Electron 43 + CSP** | 配置虽 Electron-无关，但首个真公证构建须是最终版 |
| PR-C 执行签名/公证/验证 | **PR-B 之后（最后一步）** | 只对最终、完整构建公证一次，避免返工 |

**为何签名是最后一步**：公证是对最终二进制做一次。E33（EOL）或缺 CSP 的构建先公证、E43+CSP 后再公证 = 白公证。顺序钉死：**Electron 43 → CSP → 签名/公证**（与 [`PRE_RELEASE_CHECKLIST.md`](PRE_RELEASE_CHECKLIST.md) §4 一致）。

---

## 12. 建议与 blocker 判断

- **是否建议做**：**是**——对外分发（L2）的硬门槛；未签名/未公证在现代 macOS 上对陌生用户几乎不可用。
- **是否 blocker**：**对外分发（L2）= 🔴 硬 blocker；本地自用（L1）= 非 blocker**（当前未签名 DMG 自洽）。
- **决策门控 = Apple Developer 账号（$99/年 + 真实身份）**——唯一需现在决定并启动的实体前提，其余全部技术就绪等它。
- **排期**：纯文档（PR-A）+ Apple 注册现在并行；签名/公证执行（PR-B/C）排在 Electron 43 + CSP 之后，作为发布线**最后一步**。

---

## 13. 边界声明

- 本文件**只做只读方案**：不改 `electron-builder.dmg.yml` / `package.json` / `package-lock.json` / `build/` / entitlements / 任何代码 / 签名 / 公证配置。
- 本 PR **仅新增本文档** + 在 `docs/PRE_RELEASE_CHECKLIST.md` 加交叉指针。
- 纯文档 PR，未跑测试链（无运行时可验证面）。
- 实际接线（PR-B）与执行（PR-C）为后续独立 PR，需 Apple 账号 + Electron 43 + CSP 就绪 + 显式授权 + 真机验收。

---

*相关文档：[发布前清单](PRE_RELEASE_CHECKLIST.md) ｜ [Electron 升级评估](ELECTRON_UPGRADE_ASSESSMENT.md) ｜ [CSP 计划](CSP_PLAN.md) ｜ [产品路线图](ROADMAP-to-v1.md)。本文件为工程方案记录，非安全合规认证。*
