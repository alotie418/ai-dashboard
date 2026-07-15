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
        .executable(name: "SoloLedger", targets: ["SoloLedger"]),
        .library(name: "SoloLedgerCore", targets: ["SoloLedgerCore"]),
    ],
    targets: [
        // Thin binding to the platform's libsqlite3 (no external package).
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),

        // Pure-logic core: SQLite wrapper, schema migrator, category seed,
        // ledger store, CSV, models, headless self-test. No SwiftUI here so it
        // is fully unit-testable by XCTest.
        .target(
            name: "SoloLedgerCore",
            dependencies: ["CSQLite"]
        ),

        // The SwiftUI app shell (@main). Imports SoloLedgerCore.
        .executableTarget(
            name: "SoloLedger",
            dependencies: ["SoloLedgerCore"],
            resources: [
                .process("Resources") // .lproj localization slots for all six languages
            ]
        ),

        // XCTest suite over the core logic.
        .testTarget(
            name: "SoloLedgerCoreTests",
            dependencies: ["SoloLedgerCore"]
        ),
    ]
)
