import AppKit
import UniformTypeIdentifiers
import SoloLedgerCore

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

    /// N7.2 (§3.1): the ONE directory picker — the migration-source data-folder chooser.
    /// Extracted so tests can assert the exact panel configuration (single DIRECTORY,
    /// never files, never multi-select) without running a modal panel.
    static func makeMigrationSourceDirectoryPanel(message: String) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = message
        return panel
    }

    #if DEBUG
    /// TEST-ONLY (DEBUG) panel-runner seam: hosted unit tests inject a deterministic
    /// response so `chooseMigrationSourceViaPanel` never blocks on a modal panel. The
    /// production entry STILL builds the real single-directory panel (handed to the
    /// override so tests can assert its configuration) and STILL consumes the result
    /// through `handleMigrationSourcePanelResult` — the override replaces ONLY the
    /// blocking `runModal()` call, never the preflight-free flow or the security-scope
    /// lifecycle. Compiled out of Release; nil outside tests.
    static var migrationSourcePanelRunnerOverride:
        ((NSOpenPanel) -> (response: NSApplication.ModalResponse, url: URL?))?
    #endif

    /// Source-choice "migrate old data": run the Powerbox directory picker for the previous
    /// (e.g. DMG-build) SoloLedger data folder. The security scope on the returned URL is
    /// consumed later inside the single `MigrationSource.withAccess` grant window (Core);
    /// the App neither preflights nor re-checks the selection.
    func chooseMigrationSourceViaPanel() {
        let panel = Self.makeMigrationSourceDirectoryPanel(message: t("migration.chooseSource.picker.prompt"))
        #if DEBUG
        if let run = Self.migrationSourcePanelRunnerOverride {
            let r = run(panel)
            handleMigrationSourcePanelResult(r.response, url: r.url)
            return
        }
        #endif
        handleMigrationSourcePanelResult(panel.runModal(), url: panel.url)
    }

    /// N7.2 (§6): consume the panel result. Only an explicit OK with a URL emits the
    /// strong-typed `.migrateFromUserDir(.userSelectedDataDir(url))` intent — 1:1, never
    /// mixed with the auto candidate, never collapsed to a plain boot. Cancel (or a missing
    /// URL) is a PURE no-op: no intent fires and the app stays on the source-choice screen.
    func handleMigrationSourcePanelResult(_ response: NSApplication.ModalResponse, url: URL?) {
        guard response == .OK, let url else { return }
        migrateFromUserDir(source: .userSelectedDataDir(url))
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

    // MARK: - Backup export (Settings → Data)

    /// Suggested bundle name for the backup save panel — timestamped so exports never collide.
    /// ASCII / filesystem-safe and deliberately NOT localized (it is a filename, not UI chrome).
    static func defaultBackupBundleName(now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return "SoloLedger-Backup-\(f.string(from: now))"
    }

    /// Settings → Data → "Export backup…": choose a destination, then write a restorable backup
    /// bundle (`sololedger.db` + `attachments/docs/`) there through the Powerbox save grant.
    func exportBackupViaPanel() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Self.defaultBackupBundleName()
        panel.canCreateDirectories = true
        panel.title = t("settings.backup.export")
        if panel.runModal() == .OK, let url = panel.url {
            exportBackup(to: url)
        }
    }

    /// Write the backup bundle at the chosen destination. The consistent DB snapshot + attachment
    /// copy are done by Core (`BackupExport.writeBundle`); the live active store is never touched.
    /// On any failure only a localized action error surfaces.
    func exportBackup(to destinationDir: URL) {
        guard let store else { return }
        let scoped = destinationDir.startAccessingSecurityScopedResource()
        defer { if scoped { destinationDir.stopAccessingSecurityScopedResource() } }
        do {
            let attachments = try AppPaths.nativeAttachmentsDirectory()
            try BackupExport.writeBundle(database: store.db, attachmentsDir: attachments, to: destinationDir)
        } catch {
            actionError = t("settings.backup.exportFailed")
        }
    }
}
