# SoloLedger macOS 发布 Runbook（签名 / 公证 / 验证 / 冒烟）

> 状态：**PR-B 接线（#355）+ PR-C 真实签名 / 公证 / staple 已执行成功（2026-07-07，实测记录见 §9）。**
> 剩余人工验收（1.0.0 正式版门槛）：干净机断网 Gatekeeper 冒烟（§5）、safeStorage 重录 QA、xlsx 真实文件导入冒烟。
> 方案依据：[`SIGNING_NOTARIZATION_PLAN.md`](SIGNING_NOTARIZATION_PLAN.md)（目标配置 §3 / 凭证 §4-§5 / safeStorage §6 / 验证 §10）。
> 铁律：**任何证书、密码、Team ID、API Key 不入库、不写进本文件、不出现在任何日志/汇报里。**

---

## 1. 一次性准备（人工，PR-C 前完成）

1. **Apple Developer Program** 账号（$99/年，审批约 1–2 天）。
2. **Developer ID Application 证书**（⚠️ 不是 Mac App Store 证书——DMG 直分发走 Developer ID）：
   Xcode → Settings → Accounts → Manage Certificates → 「Developer ID Application」，或开发者门户生成后导入。
   证书（含私钥）放进本机 **login 钥匙串**即可——electron-builder 构建时自动探测，无需任何配置项。
3. **App 专用密码**：appleid.apple.com → 登录与安全 → App 专用密码 → 生成（不是 Apple ID 主密码）。
4. **Team ID**：开发者门户「Membership」页，10 位字符。

## 2. 环境变量（只列名称，值自行注入，绝不入库）

构建前在**当前 shell** 导出以下三个变量（或放入 gitignored 的本地文件自行 source）：

```bash
export APPLE_ID="<Apple ID 邮箱>"
export APPLE_APP_SPECIFIC_PASSWORD="<app 专用密码>"
export APPLE_TEAM_ID="<10 位 Team ID>"
```

- 配置文件（`electron-builder.dmg.yml`）里只有 `notarize: true`，不含任何账号 / 团队标识。
- `.gitignore` 已兜底 `*.p12` / `*.p8` / `.env*`。
- CI 路线（未来）：`CSC_LINK` + `CSC_KEY_PASSWORD` 或 ASC API Key，全走 CI encrypted secrets——本机手动发布不需要。

## 3. 构建

```bash
npm run build:dmg
# 产物：release/SoloLedger-<version>-arm64.dmg
```

- **凭证在场**（钥匙串有 Developer ID 证书 + §2 三变量）：产出签名 + 公证 + staple 的分发级 DMG（electron-builder 内建 notarytool 流程，无 afterSign 钩子）。
- **无凭证降级**：机器上探测不到 Developer ID 证书 → 跳过签名与公证，产出未签名 DMG（本地开发照旧）。
- **只有证书、没有三变量**：签名会执行、公证一步会失败——本地想跳过签名快速出包时用：
  ```bash
  CSC_IDENTITY_AUTO_DISCOVERY=false npm run build:dmg
  ```
- ⚠️ **签名构建必须在非 iCloud 同步路径执行**（已实测踩坑）：若仓库位于 iCloud Drive 同步目录
  （如 `~/Documents`），文件提供者会给 `release/` 里新写入的 .app 盖 `FinderInfo` 扩展属性，
  codesign 报 `resource fork, Finder information, or similar detritus not allowed`。
  发布构建请把仓库克隆/拷贝到非同步路径（如 `~/dev/` 或 `/tmp`）后执行；日常未签名构建
  （无证书机器或加 `CSC_IDENTITY_AUTO_DISCOVERY=false`）不受影响。

## 4. 签名 / 公证验证命令（构建完成后逐条跑）

```bash
codesign -dv --verbose=4 release/mac-arm64/SoloLedger.app
#   期望：Authority=Developer ID Application: <Name> (<TEAMID>)；flags 含 runtime（硬化）

codesign --verify --deep --strict --verbose=2 release/mac-arm64/SoloLedger.app
#   期望：valid on disk / satisfies its Designated Requirement

spctl -a -vvv -t exec release/mac-arm64/SoloLedger.app
#   期望：accepted；source=Notarized Developer ID

xcrun stapler validate release/mac-arm64/SoloLedger.app
xcrun stapler validate "release/SoloLedger-<version>-arm64.dmg"
#   期望：The validate action worked!
```

## 5. 干净机断网 Gatekeeper 冒烟清单（最终门槛，只能人工）

- [ ] DMG 拷贝到一台**从未安装过本应用**的 Mac
- [ ] **断网**（拔网线 / 关 Wi-Fi）
- [ ] 打开 DMG → 拖入「应用程序」→ 双击启动
- [ ] 期望：**无「无法验证开发者」拦截、无 Gatekeeper 提示、离线直接打开**（staple = 公证票据随包，离线可验）
- [ ] 核心记账流程冒烟：新建销售/采购 → 看板 → 报表 → 备份导出/恢复
- [ ] safeStorage 重录流程（见 §6）：进「设置 → AI 服务商」重新填 Key → 测试连接通过；电商连接同理
- [ ] 解密失败提示是**可操作的重录引导**而非崩溃

## 6. safeStorage 旧 Key 重录 —— 用户须知模板（随首个签名版发布说明原样使用）

> **重要：从未签名旧版升级的用户请注意**
> 本版本启用了 macOS 代码签名与公证。由于系统钥匙串的加密密钥与应用签名身份绑定，升级后**此前保存的 AI 服务商 API Key 与电商平台凭证需要重新填写一次**（设置 → AI 服务商 / 电商连接）。
> **你的业务数据不受任何影响**：记账、采购、销售、库存、单据、报表、附件与备份全部原样保留，无需任何迁移操作。
> 若打开 AI 或电商功能时看到「无法解密凭证」类提示，按提示重新录入即可。

## 7. 故障排查

| 症状 | 处置 |
|---|---|
| 签名报 `resource fork, Finder information, or similar detritus not allowed`（已实测） | 仓库/输出目录在 iCloud 同步路径内被盖 `FinderInfo` xattr。**换非 iCloud 路径构建**（见 §3）；`xattr -cr` 只能治标——打包期间文件提供者会持续补盖 |
| 签名版启动时原生模块加载失败（报错含 `library load disallowed by system policy` / `code signature invalid`） | 在 `build/entitlements.mac.plist` 追加 `com.apple.security.cs.disable-library-validation`（单独一行 PR，见 plist 内注释与方案 §3.2） |
| 公证失败：缺凭证 | 确认 §2 三个环境变量已在当前 shell 导出（`echo ${APPLE_ID:+set}` 只验证是否已设，勿打印值） |
| 本地只想快速出未签名包 | `CSC_IDENTITY_AUTO_DISCOVERY=false npm run build:dmg` |
| 公证被 Apple 拒绝 | `xcrun notarytool log <submission-id>` 查原因（常见：二进制未签名/未硬化——检查 asarUnpack 的 .node 是否被一并签名） |

## 8. 发布收尾（PR-C 完成后）

- [x] bump `version`（**1.0.0-rc.1**）+ 填 `CHANGELOG.md`（含 §6 用户须知）——发布收尾 PR；git tag `v1.0.0-rc.1` 于该 PR merge 后由维护者打
- [ ] 只分发签名版；旧的未签名 DMG 不再外发
- [x] 更新 `PRE_RELEASE_CHECKLIST.md` §2/§4/§6 状态——发布收尾 PR

## 9. PR-C 实测记录（2026-07-07 · 真机执行）

- 执行环境：**非 iCloud 路径 clean checkout**（§3 的路径要求已实践确认——iCloud 同步目录内签名必败，见 §7）。
- `npm run build:dmg`：成功（签名 + 公证全链路一次通过）。
- SoloLedger.app：Developer ID 签名成功；Apple **notarization successful**。
- DMG：单独 `notarytool submit` → **Accepted**；`xcrun stapler validate`（DMG）→ 通过。
- `hdiutil attach` 成功；**DMG 内 App 与安装到 /Applications 后的 App 均**：
  - `spctl -a -t exec` → **accepted / source=Notarized Developer ID**
  - `codesign --verify` → valid on disk / satisfies its Designated Requirement
  - `open /Applications/SoloLedger.app` → 正常打开
- **最小 entitlements（两项）已足够**：better-sqlite3 / @napi-rs/canvas 在 hardened runtime 下加载正常，`disable-library-validation` 确认无需添加。
- 已知非阻塞现象：DMG 自身 `spctl --type open/install` 显示 rejected / no usable signature——DMG 本体未单独 codesign 所致；因 DMG notarytool **Accepted** + stapler validate 通过、且 DMG 内与安装后 App 均过 Gatekeeper，**判定不阻塞发布**。如需消除该观感，可后续评估对 DMG 本体签名（可选优化）。
- 尚未完成（1.0.0 正式版门槛）：§5 干净机断网冒烟、safeStorage 重录 QA、xlsx 真实文件导入冒烟。
