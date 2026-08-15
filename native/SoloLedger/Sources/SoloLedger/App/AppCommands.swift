import SwiftUI

/// Native menu-bar commands. Wires ⌘N / ⌘E / ⇧⌘I to the ledger actions and adds
/// a Help link, so the app is keyboard-drivable per the UI requirements.
///
/// ## G4 — what happens when there is no main window
///
/// Every command below acts on the main window, or reports its result into it. Before this
/// round they all stayed **enabled** after the window was closed, and pressing them did
/// nothing anyone could see:
///
/// * "new transaction" flipped `showingEditor`, whose sheet is attached to `RootView` — so the
///   press was not lost, it was QUEUED. Two presses with no window, then a Dock-icon reopen,
///   and the window came back with a modal editor already attached and its close button
///   disabled. That is a worse failure than the missing menu item it hid behind: the app looks
///   hung. (Reproduced by the G4 verification round; re-run there after this change.)
/// * the navigation picker moved `model.section`, repainting a view that was not on screen;
/// * import / export DID run — they own a Powerbox panel — but their outcome (`actionError`,
///   the refreshed list) surfaces only in `RootView`, so a failed import reported nothing.
///
/// So the rule here is uniform and checkable: **a command that needs the main window is
/// disabled while the main window is closed**, and the one command that is enabled precisely
/// then is the one that brings it back. No item is ever lit up and inert.
///
/// The alternative — "reopen the window, then run the command" — was rejected for these:
/// ⌘N would then mean "open a window AND put a modal over it", which is the exact shape that
/// made the queued-sheet bug feel like a hang.
struct AppCommands: Commands {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(model.t("cmd.newTransaction")) { model.newTransaction() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(!model.mainWindowIsOpen)
        }
        CommandGroup(after: .importExport) {
            Button(model.t("cmd.importCSV")) { model.importCSVViaPanel() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(!model.mainWindowIsOpen)
            Button(model.t("cmd.exportCSV")) { model.exportCSVViaPanel() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(!model.mainWindowIsOpen)
        }
        CommandGroup(after: .toolbar) {
            Picker(model.t("nav.section"), selection: $model.section) {
                ForEach(SidebarSection.allCases) { s in
                    Text(model.t(s.titleKey)).tag(s)
                }
            }
            .disabled(!model.mainWindowIsOpen)
        }
        // G4 — the item the rejection was about. Placed in the Window menu, where the reviewer
        // (and the user) looks for it, and titled with the app's own name, which is the same
        // shape the Electron 1.0.1 remediation answered with ("Window > SoloLedger, ⌘0").
        //
        // `openWindow(id:)` against the `Window` scene fronts the existing window or brings the
        // closed one back — it cannot produce a second one (see `SoloLedgerApp`). Deliberately
        // NOT disabled while the window is open: "bring to front" is the standard behaviour of
        // a Window-menu entry, and an item that greys out as soon as it worked reads as broken.
        CommandGroup(after: .windowList) {
            Button(model.t("app.name")) { openWindow(id: SoloLedgerApp.mainWindowID) }
                .keyboardShortcut("0", modifiers: .command)
        }
    }
}
