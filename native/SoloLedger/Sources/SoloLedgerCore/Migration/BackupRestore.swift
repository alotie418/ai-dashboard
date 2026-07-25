import Foundation

/// The destructive half of user-visible backup/restore: validate an incoming backup bundle and
/// clear the active migration slot so the hardened import chain can rebuild it from the bundle.
///
/// Restore REPLACES the active ledger. The safe orchestration (App layer) is:
///   validate (this, read-only) → snapshot the CURRENT ledger to `Backups/` (`BackupExport`)
///   → close the live store → `clearActiveSlot` (this) → `runImport(.exportBundle)` (the hardened
///   chain rebuilds DB + attachments, closing G1 via its finalizer).
/// This type owns ONLY the read-only validation and the slot reset — it never opens the live store,
/// never copies the DB itself, and never touches `Backups/` (where the pre-restore snapshot lives).
public enum BackupRestore {
    public enum Failure: Error, CustomStringConvertible, Equatable {
        case bundleDatabaseMissing(String)
        case bundleUnreadable(String)
        case bundleIntegrityFailed(String)
        case bundleTooNew(found: Int, supported: Int)

        public var description: String {
            switch self {
            case .bundleDatabaseMissing(let p): return "backup bundle has no database at \(p)"
            case .bundleUnreadable(let m): return "backup bundle database could not be read: \(m)"
            case .bundleIntegrityFailed(let m): return "backup bundle failed its integrity check: \(m)"
            case let .bundleTooNew(f, s): return "backup bundle schema version \(f) is newer than supported \(s)"
            }
        }
    }

    /// Read-only pre-check of a backup bundle BEFORE any destructive reset: `<bundle>/sololedger.db`
    /// must exist, open, pass `quick_check`, and not be newer than the supported schema version.
    /// Runs entirely read-only; the caller's live ledger is untouched, so a failure aborts a restore
    /// with zero damage.
    public static func validateBundle(_ bundleURL: URL) throws {
        let dbURL = bundleURL.appendingPathComponent(AppPaths.databaseFileName)
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            throw Failure.bundleDatabaseMissing(dbURL.path)
        }
        let conn: SQLiteDatabase
        do { conn = try SQLiteDatabase(path: dbURL.path, readOnly: true) }
        catch { throw Failure.bundleUnreadable("\(error)") }
        defer { try? conn.close() }
        do {
            guard try conn.quickCheck() else { throw Failure.bundleIntegrityFailed("quick_check != ok") }
            let version = try conn.userVersion()
            guard version <= SchemaMigrator.schemaVersion else {
                throw Failure.bundleTooNew(found: version, supported: SchemaMigrator.schemaVersion)
            }
        } catch let f as Failure { throw f }
        catch { throw Failure.bundleUnreadable("\(error)") }
    }

    /// Clear the active migration slot so a fresh `.exportBundle` import can rebuild it from scratch.
    /// Removes the active DB (+ rebuildable sidecars), the owner record, all completion sentinels,
    /// the active attachments, and the prepared / work residue. **PRESERVES `Backups/`** (the
    /// caller's pre-restore safety snapshot). Idempotent — a missing item is not an error.
    ///
    /// Only the EXACT `config`-named locations are removed — never a derived parent — so this is
    /// safe under both the production layout (all under one data root) and an isolated test config
    /// (sibling temp dirs). Per-import Staging is already dropped by the finalizer on completion,
    /// so it is not cleared here.
    public static func clearActiveSlot(config: MigrationCoordinator.Config) throws {
        let fm = FileManager.default

        // Active DB + rebuildable sidecars.
        for suffix in ["", "-wal", "-shm"] {
            let p = config.activeDestination.path + suffix
            if fm.fileExists(atPath: p) { try fm.removeItem(atPath: p) }
        }
        // Owner record (lives next to the active DB) + the exact config-named migration dirs.
        let targets = [config.activeDestination.deletingLastPathComponent()
                           .appendingPathComponent(PreparedImportActivator.recordName),
                       config.activeAttachmentsDir,
                       config.manifestsDir,
                       config.workingDirectory,
                       config.preparedRoot]
        for target in targets where fm.fileExists(atPath: target.path) {
            try fm.removeItem(at: target)
        }
    }
}
