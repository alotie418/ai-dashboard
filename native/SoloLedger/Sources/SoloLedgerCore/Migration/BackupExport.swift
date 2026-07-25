import Foundation

/// Writes a restorable backup BUNDLE in the exact layout `MigrationSource.exportBundle`
/// consumes — `<dir>/sololedger.db` plus `<dir>/attachments/docs/<name>` — so a bundle this
/// produces can be restored through the hardened import chain.
///
/// The database is a consistent SQLite Online-Backup snapshot of the LIVE connection (it
/// captures un-checkpointed WAL frames that a raw file copy of a live WAL database cannot),
/// then normalized to a quiescent single-file `journal_mode=delete` DB (no `-wal`/`-shm`) —
/// matching the "already checkpointed → NO wal" contract of an export bundle. Attachments are
/// copied verbatim (add-only into a fresh docs dir). This is a USER-INITIATED export to a
/// Powerbox-granted destination; it never touches the live active store.
public enum BackupExport {
    public enum Failure: Error, CustomStringConvertible {
        case destinationExists(String)
        public var description: String {
            switch self {
            case .destinationExists(let p): return "Backup destination already exists: \(p)"
            }
        }
    }

    /// Write a backup bundle at `destinationDir` (must NOT already exist — never overwrites).
    /// `attachmentsDir` is the active attachments root; if it is absent or empty, an empty
    /// `attachments/docs` is still created so the bundle layout is always complete.
    public static func writeBundle(database: SQLiteDatabase,
                                   attachmentsDir: URL,
                                   to destinationDir: URL) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destinationDir.path) else {
            throw Failure.destinationExists(destinationDir.path)
        }
        try fm.createDirectory(at: destinationDir, withIntermediateDirectories: true)

        // 1) Database — consistent Online-Backup snapshot, then normalize to a quiescent
        //    single-file delete-journal DB (no `-wal`), matching the export-bundle contract.
        let dbURL = destinationDir.appendingPathComponent(AppPaths.databaseFileName)
        try database.backup(toPath: dbURL.path)
        let snapshot = try SQLiteDatabase(path: dbURL.path, mode: .readWriteCreate)
        try snapshot.execute("PRAGMA journal_mode = DELETE")   // implicit checkpoint off any WAL header
        try snapshot.close()
        // Reopening a WAL-header snapshot creates transient `-wal`/`-shm`; they are stale after the
        // delete-mode switch. Remove them so the bundle is a clean single file (same discipline as
        // the migration path's checkpoint-then-drop-sidecars).
        for suffix in ["-wal", "-shm", "-journal"] {
            try? fm.removeItem(atPath: dbURL.path + suffix)
        }

        // 2) Attachments — mirror `<dest>/attachments/docs/<name>` verbatim (regular files only).
        let docs = destinationDir.appendingPathComponent("attachments", isDirectory: true)
                                 .appendingPathComponent("docs", isDirectory: true)
        try fm.createDirectory(at: docs, withIntermediateDirectories: true)
        guard fm.fileExists(atPath: attachmentsDir.path) else { return }
        for name in try fm.contentsOfDirectory(atPath: attachmentsDir.path).sorted() {
            let src = attachmentsDir.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: src.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            try fm.copyItem(at: src, to: docs.appendingPathComponent(name))
        }
    }
}
