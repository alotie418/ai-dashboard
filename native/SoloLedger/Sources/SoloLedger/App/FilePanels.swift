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

/// Picking, opening and discarding the app's own copy of a formal tax invoice.
///
/// **D-6 connects three of the five deleting seams here** — re-pick, remove and cancel — and the
/// other two (replace-or-clear on save, delete-the-document) sit on `AppModel`'s write paths, where
/// the store hands back the orphan. D-4 shipped with none of them: it copied IN and never out, and
/// the registered cost was a silent leak under `attachments/docs/`.
///
/// The order this was allowed to happen in is the whole point. The spec's §3 upgrade clause turns the
/// three registered check-then-act windows into must-fix items the moment ANY path really unlinks a
/// file there, so the storage-atomicity round had to land the conditional writes and the safe-delete
/// primitive FIRST. It did. Then the thirteenth ruling answered the two independent gates that
/// primitive's own residuals demanded — neither of which answered the other:
///
///  1. **Race E** — once the file is unlinked the relative name is free, and a stale or
///     non-cooperating writer can claim it again. Ruled: coordination among cooperating writers with
///     no schema change, and the external-writer residue is ACCEPTED rather than removed.
///  2. **The `fstatat`→`unlinkat` gap** inside `unlinkIfStillBound` — a same-UID swap landing between
///     those two adjacent syscalls has its replacement unlinked, and Darwin offers no
///     unlink-by-inode to close it. Ruled: accepted and registered, with no rename-then-unlink
///     variant and no claim of exclusive ownership over the directory.
///
/// Both rulings carry automatic upgrade clauses; see `docs/BUSINESS_DOCUMENTS_SPEC.md` §5. Race E is
/// NOT closed and this file must never say it is.
///
/// **Race E's first two promises live in this file**, and they are the reason the seams below are
/// safe to connect at all: ``taxInvoiceAttachmentName(documentID:extension:)`` mints a FRESH name on
/// every pick and never re-uses a freed one, and `copyItem(at:to:)` refuses an existing destination
/// rather than overwriting it. The third — never re-storing a path the draft has lost — is what
/// every seam below observes by clearing the reference before, or in the same step as, asking for
/// the copy to go.
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
    ///
    /// **Seam 1 of 5 — re-pick.** The copy the draft was holding is asked to go only AFTER the new
    /// one has been made and the draft points at it. The other order loses the old copy whenever
    /// `copyItem` throws: the catch below leaves `attachmentPath` untouched, so the draft would go on
    /// naming a file that no longer exists. There is nowhere to put an intermediate copy either —
    /// `TaxInvoiceDraft` has ONE path field and `attach(path:fileName:)` overwrites it — so a chain
    /// of picks has to be cleaned up in place, at each step.
    ///
    /// Whether the previous path is really disposable is not decided here. It is handed to the
    /// primitive, which scans BOTH authoritative reference columns inside a write lock: a path the
    /// database still holds comes back `stillReferenced` and the file stays. That is what keeps this
    /// seam from deleting the copy the saved association points at.
    func applyPickedTaxInvoiceAttachment(at url: URL) {
        guard var draft = taxInvoiceDraft else { return }
        let previous = draft.attachmentPath
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
            // No-overwrite, and race E's second promise: `copyItem` throws rather than replacing an
            // existing entry, so a freed name that somebody else has re-claimed is never silently
            // written over.
            try FileManager.default.copyItem(at: url, to: directory.appendingPathComponent(name))
            draft.attach(path: AppPaths.attachmentsRelativeRoot + "/" + name,
                         fileName: url.lastPathComponent)
            discardOrphanedAttachmentCopy(previous)
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

    /// Drop the reference, and ask for the copy that just lost its owner.
    ///
    /// **Seam 2 of 5 — remove.** The draft lets go first, so nothing here can re-store a path the
    /// draft no longer owns (race E's third promise), and the primitive is then asked about it. If
    /// the database still holds that path — the association was saved earlier and the user is only
    /// clearing it on screen — the answer is `stillReferenced` and the file is left exactly where it
    /// is. The row is not rewritten by this action, so the reference is still live.
    func removeTaxInvoiceAttachment() {
        guard var draft = taxInvoiceDraft else { return }
        let previous = draft.attachmentPath
        draft.detach()
        taxInvoiceDraft = draft
        discardOrphanedAttachmentCopy(previous)
    }

    /// Ask for one copy that nothing should point at any more. **Best-effort and silent.**
    ///
    /// The single entry point all five of D-6's seams go through — the fourth promise race E's ruling
    /// asks for, and the reason there is no second deletion path to keep in step with this one.
    ///
    /// Three things it deliberately does not do. It **never decides** whether the copy is disposable:
    /// the primitive scans both authoritative reference columns under a write lock and refuses a path
    /// the ledger still names. It **never runs inside a transaction**: the primitive opens its own
    /// `BEGIN IMMEDIATE`, SQLite cannot nest, and a nested call would fail closed and silently keep
    /// the file — so every caller here is outside one, the two store-driven seams by waiting for the
    /// commit. And it **never reports**: the entry point returns nothing, there is no new error case,
    /// no new key and no new sentence on screen, and a cleanup that could not happen must not turn a
    /// database write that DID happen into a failure.
    ///
    /// The directory is the App's own live attachments location — the same accessor the pick path
    /// copies into, so a deletion can only ever be aimed at the directory the copies are actually in.
    /// Core is not allowed to reach for it: `AppPaths.nativeAttachmentsDirectory()` CREATES what it
    /// names, and a deletion attempt that materialises a folder is not a deletion attempt.
    func discardOrphanedAttachmentCopy(_ storedPath: String?) {
        guard let storedPath, !storedPath.isEmpty, let store else { return }
        guard let directory = try? AppPaths.nativeAttachmentsDirectory() else { return }
        AttachmentDeletion.deleteIfUnreferenced(storedPath, in: directory, using: store.db)
    }

    /// `<sanitised document id>-<base36 stamp><four base36 characters>.<ext>`, the shape
    /// `app:pickDocAttachment` builds.
    ///
    /// **Race E's first promise.** The stamp is the current millisecond and the four characters are
    /// random, so a pick mints a name of its own rather than re-using one a deletion has just freed.
    /// Nothing in this app looks a freed name back up.
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
