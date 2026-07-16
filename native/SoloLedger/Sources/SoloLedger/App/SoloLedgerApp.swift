import SwiftUI
import SoloLedgerCore

@main
struct SoloLedgerApp: App {
    @StateObject private var model = AppModel()

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
        .windowToolbarStyle(.unified)
        .commands { AppCommands(model: model) }

        Settings {
            SettingsView()
                .environmentObject(model)
                .preferredColorScheme(model.appearance.colorScheme)
                .environment(\.locale, Locale(identifier: model.language))
                .frame(width: 480, height: 420)
        }
    }
}
