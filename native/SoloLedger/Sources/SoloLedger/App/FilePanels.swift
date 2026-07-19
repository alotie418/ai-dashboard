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

    /// Recovery: pick a backup / export SoloLedger database (`.db`) to adopt.
    func restoreFromBackupViaPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "db") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = t("recovery.restore")
        if panel.runModal() == .OK, let url = panel.url {
            restore(fromBackupAt: url)
        }
    }

    /// Export a privacy-bounded diagnostics report to a USER-CHOSEN file. Only structured,
    /// allowlisted fields are written (see `MigrationPresenter.diagnosticsText`) — NEVER
    /// transactions, attachment contents, database contents, or an `Error.description`; all
    /// paths are home-directory redacted. A write failure surfaces only a localized action
    /// error and leaves the ledger state untouched.
    func exportDiagnosticsViaPanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = t("migration.diagnostics.filename")
        panel.title = t("migration.diagnostics.title")
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = MigrationPresenter.diagnosticsText(
            state: migrationUIState,
            schemaVersion: schemaVersionText,
            databasePath: databasePath,
            appVersion: Self.appVersionString,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            homeDirectory: NSHomeDirectory())
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            actionError = t("migration.diagnostics.writeFailed")
        }
    }

    private static var appVersionString: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }
}
