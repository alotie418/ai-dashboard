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

/// Keeps the app alive when its only window closes.
///
/// `Window` (unlike `WindowGroup`) terminates the process when its single window goes away —
/// measured, not assumed: with the delegate removed, ⌘W ended the process with no crash report
/// and the ledger committed. That IS one of the two shapes App Review accepts ("a single-window
/// app may save and quit on close"), but it is not the shape decided for this app: the decision
/// is that the window is reopenable from the Window menu, which requires something to still be
/// running to reopen it. Returning `false` here is what makes ⌘0 mean anything.
final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct SoloLedgerApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var lifecycle

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

    /// The main window's scene id. `AppCommands` reopens THIS id; `Window` (not `WindowGroup`)
    /// makes "there is at most one of it" a property of the scene type rather than something
    /// the command has to be careful about.
    static let mainWindowID = "main"

    var body: some Scene {
        // `Window`, not `WindowGroup` — G4.
        //
        // The App Review rejection this closes (Guideline 4 on the Electron 1.0) is: close the
        // main window and no menu item brings it back. Measured on the native build before this
        // change: ⌘W left the app running with the whole Window menu greyed out, the window-list
        // entry gone, and File's "New Window" absent — `CommandGroup(replacing: .newItem)` had
        // taken that slot for "new transaction". Only the Dock icon could recover, and the Dock
        // is not a menu item.
        //
        // Why the scene TYPE changes rather than just adding a command: `openWindow(id:)`
        // against a `WindowGroup` OPENS ANOTHER WINDOW — it is a group, more members are the
        // point. A reopen command built on it would satisfy Apple and then hand the user two
        // main windows on the second press, each with its own editor sheet over the same
        // ledger. `Window` is single-instance by construction, so `openWindow(id:)` means
        // "front it, or bring it back if it was closed" and cannot mean anything else. The
        // single-window rule is then structural, not a thing a future edit can forget.
        //
        // The title is the literal, not `model.t("app.name")`: a scene's title is fixed at
        // scene-construction time and cannot follow `model.language`. It costs nothing here —
        // `app.name` is the string "SoloLedger" in all six languages (asserted in
        // ``WindowReopenCommandGuardTests``), so the literal and the lookup are the same text
        // everywhere. The MENU ITEM, which is rebuilt on every language change, does use the
        // lookup. Either way the title bar is normally overridden by each detail view's
        // `.navigationTitle`.
        Window("SoloLedger", id: Self.mainWindowID) {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 940, minHeight: 580)
                .preferredColorScheme(model.appearance.colorScheme)
                .environment(\.locale, Locale(identifier: model.language))
                .task { model.boot() }
                // The command layer needs to know whether the main window exists; nothing else
                // can tell it. Set here rather than by polling `NSApp.windows` because the
                // commands' `.disabled(…)` has to REDRAW when it changes, and only a published
                // property does that.
                .onAppear { model.mainWindowIsOpen = true }
                .onDisappear { model.mainWindowIsOpen = false }
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
