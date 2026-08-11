import SwiftUI
import SoloLedgerCore

/// App identity read from the SHIPPED `Info.plist`, never from a literal.
///
/// The About tab used to print `"1.0.0 (prototype)"` and `"macOS 13.0+"` as string literals,
/// so raising `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` / the deployment target changed
/// the package while the app kept telling the user the old numbers — and kept calling a
/// shipped build a prototype. All three values are `$(…)` substitutions in
/// `App/Support/Info.plist`, so reading them here means the screen follows the build settings
/// with no edit in this file.
///
/// `lookup` is injectable for one reason: without it a test could only compare
/// `Bundle.main`-derived output against `Bundle.main`, which is a tautology and would pass
/// just as well over a hardcoded string. Feeding a dictionary the code cannot know is what
/// actually proves the value came from the dictionary.
enum AppBundleInfo {
    /// Shown in place of a value the bundle does not carry. Never reached in a real build —
    /// all three keys are present in the shipped `Info.plist` — so it exists to avoid
    /// inventing a version number, not to be read.
    static let unknown = "?"

    static func infoValue(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }

    /// `<marketing> (<build>)` — the marketing version, plus the build number that identifies
    /// the upload. Deliberately not spelled with real numbers: this comment carried a concrete
    /// pair from the day it was written, and that pair was already wrong (the project declared
    /// something else). The numbers live in `project.pbxproj` and are pinned by
    /// `AppVersionGuardTests`; a copy here could only rot.
    static func versionText(_ lookup: (String) -> String? = infoValue) -> String {
        let short = lookup("CFBundleShortVersionString") ?? unknown
        let build = lookup("CFBundleVersion") ?? unknown
        return "\(short) (\(build))"
    }

    /// `macOS 13.0+` — `LSMinimumSystemVersion` is `$(MACOSX_DEPLOYMENT_TARGET)`, so a change
    /// of deployment target reaches the screen on its own.
    static func minimumSystemText(_ lookup: (String) -> String? = infoValue) -> String {
        guard let version = lookup("LSMinimumSystemVersion"), !version.isEmpty else {
            return unknown
        }
        return "macOS \(version)+"
    }
}

@main
struct SoloLedgerApp: App {
    @StateObject private var model = AppModel()

    @MainActor
    init() {
        // Headless smoke test: run the data-layer end-to-end and exit, without
        // opening the GUI or the preview DB. Used by scripts/tests in CI.
        if CommandLine.arguments.contains("--self-test") {
            let report = SelfTest.run()
            print(report.text)
            exit(report.passed ? 0 : 1)
        }
        // Headless check that the packaged localization resources load (guards
        // the Bundle.module launch-crash regression).
        if CommandLine.arguments.contains("--check-resources") {
            let report = ResourceCheck.run()
            print(report.text)
            exit(report.passed ? 0 : 1)
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 940, minHeight: 580)
                .preferredColorScheme(model.appearance.colorScheme)
                .environment(\.locale, Locale(identifier: model.language))
                .task { model.boot() }
        }
        .defaultSize(width: 1120, height: 740)
        .windowToolbarStyle(.unified)
        .commands { AppCommands(model: model) }

        Settings {
            SettingsView()
                .environmentObject(model)
                .preferredColorScheme(model.appearance.colorScheme)
                .environment(\.locale, Locale(identifier: model.language))
                .frame(width: 480, height: 560)
        }
    }
}
