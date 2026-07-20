// swift-tools-version: 5.9
// SoloLedger — native SwiftUI rewrite, Phase-1 technical prototype.
//
// Tools version 5.9 (Swift 5 language mode) is deliberate for the prototype: it
// avoids Swift 6 strict-concurrency friction while still targeting macOS 13 and
// using every requested SDK feature (SwiftUI, NavigationSplitView, Swift Charts,
// Table, Settings scene, Commands). Adopting Swift 6 concurrency is a later
// hardening pass — see docs/SWIFTUI_MIGRATION_PLAN.md.
//
// Data layer uses the SYSTEM libsqlite3 via the CSQLite system-library target:
// zero external dependencies, builds fully offline, App-Sandbox friendly, and
// gives exact SQL control so the schema stays byte-compatible with the existing
// Electron/better-sqlite3 database. GRDB is evaluated & recommended for
// production (see the plan doc) but intentionally not a prototype dependency.
import PackageDescription

let package = Package(
    name: "SoloLedger",
    defaultLocalization: "zh-Hans", // source of truth mirrors the JS app's zh-CN
    platforms: [
        .macOS(.v13) // NavigationSplitView + Swift Charts require macOS 13 (approved uplift from Electron's 12.0)
    ],
    products: [
        // The Xcode app project (App/SoloLedger.xcodeproj) links this library as a
        // LOCAL package product. The SwiftUI app itself is built by Xcode, not SPM,
        // so this package intentionally exposes NO executable product — that also
        // avoids a name collision with the Xcode "SoloLedger" app target during
        // UI-test host resolution.
        .library(name: "SoloLedgerCore", targets: ["SoloLedgerCore"]),
    ],
    targets: [
        // Thin binding to the platform's libsqlite3 (no external package).
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),

        // Pure-logic core: SQLite wrapper, schema migrator, category seed,
        // ledger store, CSV, models, headless self-test. No SwiftUI here so it
        // is fully unit-testable by XCTest and linkable by the Xcode app.
        .target(
            name: "SoloLedgerCore",
            dependencies: ["CSQLite"]
        ),

        // XCTest suite over the core logic. Bundles the Electron v23 fixture
        // (built by the real Electron migration code — see Tests/Fixtures/).
        .testTarget(
            name: "SoloLedgerCoreTests",
            dependencies: ["SoloLedgerCore"],
            resources: [.copy("Fixtures/electron-v23.db")]
        ),
    ]
)
// The SwiftUI app sources live in Sources/SoloLedger/ and are compiled by the
// Xcode app target (App/SoloLedger.xcodeproj), which references them without
// copying. SwiftPM ignores that directory since no package target claims it.
