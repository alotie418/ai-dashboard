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
            appVersion: AppBundleInfo.versionText(),
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            homeDirectory: NSHomeDirectory())
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            actionError = t("migration.diagnostics.writeFailed")
        }
    }

    // MARK: - The documents page's artefact (Q7)

    /// What a save-panel run came to. `cancelled` is not a failure and must not be reported as one:
    /// the other app is silent on a cancelled save too.
    enum DocumentSaveResult: Equatable {
        case written(path: String)
        case cancelled
        case failed
    }

    /// Write one document's HTML through the Powerbox save grant.
    ///
    /// Both strings arrive already resolved. This file may not name a `documents.*` key — DC9 holds
    /// that whole namespace to the page's composition and to no other file — so the caller resolves
    /// and hands over text.
    ///
    /// `panelMessage` is where Q7's narrowing gets said: the other app's button produces a PDF and
    /// this one produces HTML, and the user reads that while choosing the destination rather than
    /// discovering it afterwards.
    func saveDocumentHTMLViaPanel(html: String,
                                  suggestedName: String,
                                  panelMessage: String) -> DocumentSaveResult {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = suggestedName
        panel.message = panelMessage
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return .cancelled }
        do {
            try html.write(to: url, atomically: true, encoding: .utf8)
            return .written(path: url.path)
        } catch {
            return .failed
        }
    }

    // MARK: - Backup export (Settings → Data)

    /// Timestamp for backup file/dir names — ASCII, filesystem-safe, POSIX-stable.
    static func fileTimestamp(now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: now)
    }

    /// Suggested bundle name for the backup save panel — timestamped so exports never collide.
    /// ASCII / filesystem-safe and deliberately NOT localized (it is a filename, not UI chrome).
    static func defaultBackupBundleName(now: Date = Date()) -> String {
        "SoloLedger-Backup-\(fileTimestamp(now: now))"
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

    /// Settings → Data → "Restore from backup…": pick a backup BUNDLE folder, then replace the
    /// current ledger with it (`restoreFromBackup` in AppModel). The destructive confirmation is
    /// view-local (SettingsView) and runs BEFORE this — the panel appears only after the user confirms.
    func restoreFromBackupBundleViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.title = t("settings.restore")
        panel.message = t("settings.restore.pickPrompt")
        if panel.runModal() == .OK, let url = panel.url {
            restoreFromBackup(bundleURL: url)
        }
    }
}

// MARK: - Document attachments (D-4)

/// Picking and opening the app's own copy of a formal tax invoice.
///
/// **Nothing here deletes a file** — ruling ③ of 2026-08-18. `documents.js` discards an unsaved copy
/// on re-pick and on cancel, and its handler removes the previous copy when the association is
/// replaced; both of those are paths that really unlink something under `attachments/docs/`, and
/// the spec's §3 upgrade clause turns the three registered check-then-act windows into must-fix
/// items the moment one exists. So this round copies IN and never out: a replaced or dropped
/// attachment leaves its copy behind. That leak is registered in the spec rather than hidden, and
/// the storage-atomicity round is where the deleting seam gets connected.
extension AppModel {

    /// `MAX_BYTES` from `electron/handlers/index.js`: twenty mebibytes, and the comparison is a
    /// STRICT greater-than there, so a file of exactly this size is accepted.
    static let taxInvoiceAttachmentMaxBytes = 20 * 1024 * 1024

    /// `ALLOWED_EXTS`, compared case-insensitively as `path.extname(...).toLowerCase()` does.
    static let taxInvoiceAttachmentExtensions = ["pdf", "jpg", "jpeg", "png"]

    /// Choose a file, copy it into the attachments directory, and point the draft at the copy.
    ///
    /// The order of the two refusals is the handler's: the extension is checked before the size, so
    /// an oversized `.txt` is reported as the wrong type rather than as too large.
    func pickTaxInvoiceAttachment() {
        guard taxInvoiceDraft != nil else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.pdf, .jpeg, .png]
        panel.title = t(DocumentPageComposition.attachmentPanelTitleKey)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        applyPickedTaxInvoiceAttachment(at: url)
    }

    /// The part of the pick that does not need a panel, so a test can drive it with a real file.
    func applyPickedTaxInvoiceAttachment(at url: URL) {
        guard var draft = taxInvoiceDraft else { return }
        let ext = url.pathExtension.lowercased()
        guard Self.taxInvoiceAttachmentExtensions.contains(ext) else {
            draft.attachmentOutcome = .invalidType
            taxInvoiceDraft = draft
            return
        }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else {
                draft.attachmentOutcome = .invalidType
                taxInvoiceDraft = draft
                return
            }
            guard (values.fileSize ?? 0) <= Self.taxInvoiceAttachmentMaxBytes else {
                draft.attachmentOutcome = .tooLarge
                taxInvoiceDraft = draft
                return
            }
            let name = Self.taxInvoiceAttachmentName(documentID: draft.document.id, extension: ext)
            let directory = try AppPaths.nativeAttachmentsDirectory()
            try FileManager.default.copyItem(at: url, to: directory.appendingPathComponent(name))
            draft.attach(path: AppPaths.attachmentsRelativeRoot + "/" + name,
                         fileName: url.lastPathComponent)
        } catch {
            draft.attachmentOutcome = .failed
        }
        taxInvoiceDraft = draft
    }

    /// Hand the copy to the system. A reference whose file is gone says so instead of failing
    /// silently — the other app reports the same case as its own gentler notice rather than as an
    /// error.
    func openTaxInvoiceAttachment() {
        guard var draft = taxInvoiceDraft, let relative = draft.attachmentPath else { return }
        guard let name = AttachmentRelPath.bareName(of: relative) else {
            draft.attachmentOutcome = .invalidPath
            taxInvoiceDraft = draft
            return
        }
        do {
            let url = try AppPaths.nativeAttachmentsDirectory().appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                draft.attachmentOutcome = .missing
                taxInvoiceDraft = draft
                return
            }
            if !NSWorkspace.shared.open(url) {
                draft.attachmentOutcome = .failed
            } else {
                draft.attachmentOutcome = .none
            }
        } catch {
            draft.attachmentOutcome = .failed
        }
        taxInvoiceDraft = draft
    }

    /// Drop the reference. **The copy is not removed** — see this extension's own note.
    func removeTaxInvoiceAttachment() {
        guard var draft = taxInvoiceDraft else { return }
        draft.detach()
        taxInvoiceDraft = draft
    }

    /// `<sanitised document id>-<base36 stamp><four base36 characters>.<ext>`, the shape
    /// `app:pickDocAttachment` builds.
    ///
    /// The sanitising is the handler's: keep only `A-Za-z0-9_-`, drop leading `_` and `-`, cut to
    /// forty, and fall back to `doc` when nothing survives. That is what makes the result satisfy
    /// the whitelist `AttachmentRelPath` enforces, whose first character must be alphanumeric.
    static func taxInvoiceAttachmentName(documentID: String, extension ext: String) -> String {
        var kept = documentID.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
        while let first = kept.first, first == "_" || first == "-" { kept.removeFirst() }
        if kept.count > 40 { kept = String(kept.prefix(40)) }
        let stem = kept.isEmpty ? "doc" : kept
        let stamp = String(UInt64(Date().timeIntervalSince1970 * 1000), radix: 36)
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        let suffix = String((0..<4).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
        return "\(stem)-\(stamp)\(suffix).\(ext)"
    }
}
