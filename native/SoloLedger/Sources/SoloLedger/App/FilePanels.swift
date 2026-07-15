import AppKit
import UniformTypeIdentifiers

/// System open/save panels for CSV. In an App-Sandbox build these are the
/// Powerbox-brokered pickers that the `user-selected.read-write` entitlement
/// authorizes — the only file access the native app needs.
extension AppModel {
    func exportCSVViaPanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "transactions.csv"
        panel.canCreateDirectories = true
        panel.title = t("cmd.exportCSV")
        if panel.runModal() == .OK, let url = panel.url {
            exportCSV(to: url)
        }
    }

    func importCSVViaPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = t("cmd.importCSV")
        if panel.runModal() == .OK, let url = panel.url {
            importCSV(from: url)
        }
    }
}
