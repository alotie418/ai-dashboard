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
  SoloLedger.xcodeproj           the Xcode project, and the source of truth for the App target
  Support/                       Info.plist, Debug/Release entitlements, Assets.xcassets (AppIcon, AccentColor)
  Tests/SoloLedgerUnitTests/     Xcode unit tests (public Core API)
  Tests/SoloLedgerUITests/       Xcode UI launch test
```

## Requirements

- macOS 13.0+ (deployment target)
- Xcode 26.x. If `xcode-select` points at the Command Line Tools, prefix commands
  with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- No project generator. There is no XcodeGen spec in this repo (the historical
  `App/project.yml` was deleted in 2c-2); `project.pbxproj` is the source of truth and is
  edited by hand — see "Adding a file to an App target" below. The committed `.xcodeproj`
  opens and builds directly, and CI builds from it.

## Build, test, run (Xcode project)

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd App

# Open in Xcode and press Run (⌘R):
open SoloLedger.xcodeproj

# Or from the command line — build / test (Debug):
xcodebuild -project SoloLedger.xcodeproj -scheme SoloLedger -configuration Debug -destination 'platform=macOS' build
xcodebuild test    -project SoloLedger.xcodeproj -scheme SoloLedger -configuration Debug -destination 'platform=macOS'

# Archive. The scheme's ArchiveAction is Release, so this needs no -configuration:
xcodebuild archive -project SoloLedger.xcodeproj -scheme SoloLedger -destination 'generic/platform=macOS' -archivePath build/SoloLedger.xcarchive

```

**Run and test stay on Debug on purpose.** Release carries the production bundle id
`com.alotie418.sololedger`, so a sandboxed process built from it resolves `Application Support`
into `~/Library/Containers/com.alotie418.sololedger` — the real container, shared with the
Electron MAS line. Debug's `.dev` id lands in an isolated preview container. Do not "simplify"
by passing `-configuration Release` to `xcodebuild test`: that points the app-hosted tests at
live user data. `Tests/SoloLedgerCoreTests/SchemeConfigurationGuardTests.swift` pins both sides.

The archive is **not submittable yet**: Release still signs ad-hoc (`CODE_SIGN_IDENTITY = "-"`,
no team, no provisioning profile) and there is no `ExportOptions.plist`. Production signing and
the export step are a separate round.

### Adding a file to an App target

`project.pbxproj` is the source of truth, and it is edited BY HAND. Do not introduce a
generator: the repo used to carry an XcodeGen spec, and running `xcodegen generate` would
have rewritten the project from it and silently dropped those hand edits — measured, on a
tree with no source changes at all, xcodegen 2.45.4 still reissued object IDs for four
already-committed files. The spec was deleted in 2c-2 precisely because a file that looks
like the source of truth but is read by nothing is worse than no file at all.

Each new **`.swift`** file needs exactly four lines: a `PBXBuildFile`, a
`PBXFileReference`, an entry in its group's `children`, and an entry in the target's
`PBXSourcesBuildPhase.files`. The two list entries sort case-insensitively by file name;
the two object entries sort by their 24-hex id, which you mint yourself and grep to
confirm is unused. (Other file kinds are NOT four lines — a seventh `.lproj`, for example,
joins the existing `PBXVariantGroup` and `knownRegions` and adds no `PBXBuildFile` of its
own. The guard below covers `.swift` only.)

Get it wrong and **nothing reports it**: a file missing from `project.pbxproj` does not
fail the build, it is simply never compiled. For a test file that shows up as a test count
that did not go up, with no error anywhere. That silence is what
`Tests/SoloLedgerCoreTests/AppTargetRegistrationGuardTests.swift` exists to break — it
compares the disk against `project.pbxproj` in both directions, per target, and checks the
project against itself (group children ↔ Sources phases, and all four lines per file). It
runs in `swift test`, inside the required `Guards + migrations + build` check.

- **Debug** builds as Bundle ID `com.alotie418.sololedger.dev`; **Release** as
  `com.alotie418.sololedger`. Only Debug is built for now — no production signing.
- The built app supports two headless smoke flags (used by CI / regression guards):
  `SoloLedger.app/Contents/MacOS/SoloLedger --self-test` (data-layer end-to-end) and
  `--check-resources` (packaged localization loads).

## Core (SwiftPM) directly

```bash
swift build     # builds SoloLedgerCore
swift test      # SoloLedgerCore 的 XCTest 套件：schema / seed / CRUD / CSV round-trip /
                # 报表镜像 parity / 库存引擎性质测试
```

## Safety / scope

- **Never writes the production database.** Uses an isolated file at
  `Application Support/SoloLedgerNativePreview/sololedger.db` (or the sandbox
  container), never the Electron app's `Application Support/SoloLedger/sololedger.db`.
- Schema + migrations are a faithful port of `electron/db/index.js` up to `user_version`
  23, so a file this app creates is schema-compatible with the Electron app. From v24 the
  ladder is native-only (the three inventory tables): the Electron app still opens such a
  file and still reads and writes its v23 tables, so the two inventory fact sources would
  diverge silently — see `docs/SWIFTUI_FEATURE_GAP.md` for the three measured facts.
- **No AI, no API key, no OCR, no network, no StoreKit, no paid unlock.** Entitlements
  are only App Sandbox + user-selected file read/write (Debug also has get-task-allow
  for the debugger / UI-test runner).
- Reports, tax, COGS, and other accounting-policy logic are deliberately **out of
  scope** — the native app must mirror, never reinvent, that logic.
