# SoloLedger — native SwiftUI rewrite

A local-first, private macOS ledger for solo operators, one-person companies, and
freelancers. Independent of the Electron app in the repo root; it does not touch it.

See `../docs/SWIFTUI_MIGRATION_PLAN.md` for the full plan, schema mapping, and
data-compatibility strategy.

## Structure (Phase 1.5)

The **data layer** is a SwiftPM package; the **app** is a real Xcode project that
links the package's `SoloLedgerCore` library locally (no source copy) and compiles
the SwiftUI sources in `Sources/SoloLedger/`.

```
Package.swift                    SwiftPM package: SoloLedgerCore library + tests
Sources/CSQLite/                 system libsqlite3 shim (module map)
Sources/SoloLedgerCore/          data layer (SQLite, migrations, seed, store, CSV, self-test) — no SwiftUI
Sources/SoloLedger/              SwiftUI app code (compiled by the Xcode app target)
Tests/SoloLedgerCoreTests/       XCTest for the Core (run via `swift test`)
App/
  project.yml                    XcodeGen spec (regenerates the project)
  SoloLedger.xcodeproj           the Xcode project (App + Unit-Test + UI-Test targets)
  Support/                       Info.plist, Debug/Release entitlements, Assets.xcassets (AppIcon, AccentColor)
  Tests/SoloLedgerUnitTests/     Xcode unit tests (public Core API)
  Tests/SoloLedgerUITests/       Xcode UI launch test
```

## Requirements

- macOS 13.0+ (deployment target)
- Xcode 26.x. If `xcode-select` points at the Command Line Tools, prefix commands
  with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- To regenerate the project: `xcodegen` (`brew install xcodegen`). The committed
  `.xcodeproj` opens directly — xcodegen is only needed to regenerate from `project.yml`.

## Build, test, run (Xcode project)

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd App

# Open in Xcode and press Run (⌘R):
open SoloLedger.xcodeproj

# Or from the command line — build / test / archive (Debug):
xcodebuild -project SoloLedger.xcodeproj -scheme SoloLedger -configuration Debug -destination 'platform=macOS' build
xcodebuild test    -project SoloLedger.xcodeproj -scheme SoloLedger -configuration Debug -destination 'platform=macOS'
xcodebuild archive -project SoloLedger.xcodeproj -scheme SoloLedger -configuration Debug -destination 'generic/platform=macOS' -archivePath build/SoloLedger-Debug.xcarchive

# Regenerate the project after editing project.yml:
xcodegen generate
```

- **Debug** builds as Bundle ID `com.alotie418.sololedger.dev`; **Release** as
  `com.alotie418.sololedger`. Only Debug is built for now — no production signing.
- The built app supports two headless smoke flags (used by CI / regression guards):
  `SoloLedger.app/Contents/MacOS/SoloLedger --self-test` (data-layer end-to-end) and
  `--check-resources` (packaged localization loads).

## Core (SwiftPM) directly

```bash
swift build     # builds SoloLedgerCore
swift test      # 31 XCTest: schema / seed / CRUD / CSV round-trip
```

## Safety / scope

- **Never writes the production database.** Uses an isolated file at
  `Application Support/SoloLedgerNativePreview/sololedger.db` (or the sandbox
  container), never the Electron app's `Application Support/SoloLedger/sololedger.db`.
- Schema + migrations are a faithful port of `electron/db/index.js` (`user_version`
  reaches 23, all 26 tables), so a file this app creates is schema-compatible.
- **No AI, no API key, no OCR, no network, no StoreKit, no paid unlock.** Entitlements
  are only App Sandbox + user-selected file read/write (Debug also has get-task-allow
  for the debugger / UI-test runner).
- Reports, tax, COGS, and other accounting-policy logic are deliberately **out of
  scope** — the native app must mirror, never reinvent, that logic.
