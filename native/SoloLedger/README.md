# SoloLedger — native SwiftUI rewrite (Phase-1 prototype)

A local-first, private macOS ledger for solo operators, one-person companies, and
freelancers. This directory holds the **native SwiftUI rewrite prototype**; it is
independent of the Electron app in the repo root and does not touch it.

See `../docs/SWIFTUI_MIGRATION_PLAN.md` for the full plan, schema mapping, and
data-compatibility strategy.

## Requirements

- macOS 13.0+ (deployment target)
- Xcode 26.x (the SDK/toolchain). If `xcode-select` points at the Command Line
  Tools, prefix commands with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

## Build & test

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

swift build                 # or: xcodebuild -scheme SoloLedger -destination 'platform=macOS' build
swift test                  # XCTest suite (schema / seed / CRUD / CSV round-trip)

# Headless end-to-end smoke test (no GUI needed):
swift run SoloLedger --self-test

# Assemble a runnable, ad-hoc-signed .app (App Sandbox) and launch it:
bash scripts/build-app.sh
open build/SoloLedger.app
```

## Layout

```
Sources/CSQLite/           system libsqlite3 shim (module map)
Sources/SoloLedgerCore/    data layer (no SwiftUI, fully unit-tested)
  SQLite/                  thin C-API wrapper
  Schema/                  SchemaMigrator (23-version ladder) + CategorySeed (78 rows)
  Models/                  Transaction / Category / enums / summaries
  Store/                   LedgerStore (CRUD/summary) + SettingsStore
  CSV/                     RFC-4180 writer/reader + transactions export/import
  SelfTest/                headless end-to-end check
Sources/SoloLedger/        SwiftUI app (@main, NavigationSplitView, Table, Charts, Settings)
  App/                     entry, model, localizer, commands, file panels
  Views/                   Overview / Transactions / Editor / Categories / Onboarding / Settings
  Resources/*.lproj/       6-language localization slots (zh-Hans + en full; others partial)
Tests/SoloLedgerCoreTests/ XCTest
Packaging/                 Info.plist + App Sandbox entitlements (dev Bundle ID)
scripts/build-app.sh       assemble + ad-hoc sign a runnable .app
```

## Safety / scope

- **Never writes the production database.** The prototype uses its own isolated
  file at `Application Support/SoloLedgerNativePreview/sololedger.db`, never the
  Electron app's `Application Support/SoloLedger/sololedger.db`.
- The schema + migration ladder are a faithful port of `electron/db/index.js`
  (`user_version` reaches 23; all 26 tables created), so a file this app creates is
  schema-compatible with the Electron build.
- **No AI, no API key, no OCR, no network, no paid unlock.** Entitlements are only
  App Sandbox + user-selected file read/write.
- Dev Bundle ID `com.alotie418.sololedger.dev` (production stays
  `com.alotie418.sololedger`).
- Reports, tax, COGS and other accounting-policy logic are deliberately **out of
  Phase-1 scope** — the native app must mirror, never reinvent, that logic.
