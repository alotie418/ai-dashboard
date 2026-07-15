import SwiftUI

/// Native menu-bar commands. Wires ⌘N / ⌘E / ⇧⌘I to the ledger actions and adds
/// a Help link, so the app is keyboard-drivable per the UI requirements.
struct AppCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(model.t("cmd.newTransaction")) { model.newTransaction() }
                .keyboardShortcut("n", modifiers: .command)
        }
        CommandGroup(after: .importExport) {
            Button(model.t("cmd.importCSV")) { model.importCSVViaPanel() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Button(model.t("cmd.exportCSV")) { model.exportCSVViaPanel() }
                .keyboardShortcut("e", modifiers: .command)
        }
        CommandGroup(after: .toolbar) {
            Picker(model.t("nav.section"), selection: $model.section) {
                ForEach(SidebarSection.allCases) { s in
                    Text(model.t(s.titleKey)).tag(s)
                }
            }
        }
    }
}
