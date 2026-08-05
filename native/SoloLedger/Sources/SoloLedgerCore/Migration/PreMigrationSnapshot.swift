import Foundation

/// The rollback point taken immediately before an IN-PLACE schema migration of the LIVE active
/// ledger — and the reason the ladder may grow a new rung at all.
///
/// ## Why this exists
///
/// Until now the native migrator only ever ran in two situations, neither of which could lose
/// anything: a brand-new empty ledger (`createFreshReservedHardened`), and the first adoption of
/// an Electron database (`PreparedImportRunner`, which migrates a PRIVATE COPY and leaves the
/// original untouched). "An existing native ledger that already holds the user's data, plus a new
/// migration rung" had simply never happened. The first rung that does it would migrate the live
/// file with no rollback point anywhere — `LedgerStore.init(adopting:)` goes straight from
/// `applyPragmas()` to `SchemaMigrator.migrate(db)`.
///
/// Electron has had the equivalent protection since v1 (`electron/db/index.js:63-68` forces an
/// `autoBackup` whenever `user_version < MIGRATIONS.length`). The native app had no equivalent.
///
/// ## The two properties everything else serves
///
/// **Fail-closed.** If the snapshot cannot be written, or cannot be read back and verified, the
/// migration does NOT run and the open fails. This deliberately does NOT follow Electron, whose
/// `autoBackup` failure is logged and the migration proceeds anyway. The whole point of the
/// snapshot is to be there when the migration goes wrong; a migration that ran because the
/// snapshot failed is the one case where the protection is most needed and least present.
///
/// **A live backup, not a file copy.** The source is the connection the hardened open already
/// verified, and the copy goes through the SQLite Online-Backup API. A raw file copy of a live
/// WAL database silently drops committed-but-un-checkpointed frames — the same reason
/// ``BackupExport`` states for using the Backup API rather than `copyItem`.
///
/// ## What it deliberately does NOT do
///
/// It never resolves a path of its own. `backupsDirectory` and `attachmentsDirectory` are
/// parameters for the reason `LegacyConversionRunner` records for its own two: a Core routine that
/// called `AppPaths.backupsDirectory()` would reach live user data from any unsandboxed harness.
public struct PreMigrationSnapshotPlan: Equatable, Sendable {
    /// Where snapshots live. Derived by the App; may not exist yet — it is created only if a
    /// snapshot is actually taken, so a boot that needs none mints no empty directory.
    public var backupsDirectory: URL
    /// The active attachments root, copied into the bundle so a restored snapshot's
    /// `attachment_path` values still resolve.
    public var attachmentsDirectory: URL
    /// Supplied by the App rather than read from the clock here, so a test pins the name.
    public var timestamp: String
    /// How many pre-migration snapshots to keep. Older ones are pruned AFTER a successful write.
    public var retention: Int

    public init(backupsDirectory: URL, attachmentsDirectory: URL, timestamp: String, retention: Int) {
        self.backupsDirectory = backupsDirectory
        self.attachmentsDirectory = attachmentsDirectory
        self.timestamp = timestamp
        self.retention = retention
    }
}

/// Why a pre-migration snapshot was refused.
///
/// **Both cases are payload-free, and that is the point** — the same ruling `ProductCatalogError`
/// records. A snapshot failure is reported to the user through localized copy; with no associated
/// values there is no path, no `strerror` and no SQLite message for a presentation layer to print
/// even by accident.
public enum PreMigrationSnapshotError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The bundle could not be written. Disk-full lands here, and is the likely real-world cause.
    case writeFailed
    /// The bundle was written but did not read back as a healthy copy of the source.
    case verificationFailed

    public var description: String {
        switch self {
        case .writeFailed:        return "writeFailed"
        case .verificationFailed: return "verificationFailed"
        }
    }
}

public enum PreMigrationSnapshot {

    /// Directory-name prefix. A snapshot is identified as ours by this prefix alone, so pruning
    /// can never touch `pre-restore-*` (the restore safety net) or a user's own export.
    static let namePrefix = "pre-migrate-"

    /// Take and verify a snapshot of `database`, then prune older ones. Returns the bundle URL.
    ///
    /// The caller must have decided that a migration is pending; this routine does not read
    /// `user_version` to make that decision for it (see `LedgerStore.openActiveExistingHardened`,
    /// which owns the decision so the guard sits next to the migrate it protects).
    ///
    /// - Parameter fromVersion: the CURRENT `user_version`, used only in the directory name.
    @discardableResult
    static func take(database: SQLiteDatabase, fromVersion: Int,
                     plan: PreMigrationSnapshotPlan,
                     hooks: Hooks = Hooks()) throws -> URL {
        let destination = try uniqueDestination(in: plan.backupsDirectory,
                                                fromVersion: fromVersion, timestamp: plan.timestamp)
        do {
            try FileManager.default.createDirectory(at: plan.backupsDirectory, withIntermediateDirectories: true)
            try hooks.beforeWrite?()
            try BackupExport.writeBundle(database: database,
                                         attachmentsDir: plan.attachmentsDirectory,
                                         to: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)   // never leave a half-written bundle
            throw PreMigrationSnapshotError.writeFailed
        }

        do { try hooks.afterWrite?() } catch { removeQuietly(destination); throw PreMigrationSnapshotError.verificationFailed }

        // VERIFY — the bundle must read back as a healthy database at the version we snapshotted.
        // A bundle that fails this is REMOVED: an unverified snapshot on disk is worse than none,
        // because the next failure would be met with a backup nobody knows is bad.
        do {
            let dbURL = destination.appendingPathComponent(AppPaths.databaseFileName)
            let verify = try SQLiteDatabase(path: dbURL.path, readOnly: true)
            defer { try? verify.close() }
            guard try verify.quickCheck() else { throw PreMigrationSnapshotError.verificationFailed }
            guard try verify.userVersion() == fromVersion else { throw PreMigrationSnapshotError.verificationFailed }
        } catch {
            removeQuietly(destination)
            throw PreMigrationSnapshotError.verificationFailed
        }

        // PRUNE — AFTER a verified write, never before. Pruning first would, on a write failure,
        // cost the user both the old snapshots and the new one. This is also the ONE step whose
        // failure does NOT block the open: an undeletable stale directory says nothing about
        // whether THIS boot has a rollback point, and failing here would lock the app out of a
        // ledger it just successfully protected.
        prune(in: plan.backupsDirectory, keeping: plan.retention)
        return destination
    }

    /// Test seams. Nil in production — `take` is called with the default instance.
    struct Hooks {
        /// Fires after the backups directory exists and BEFORE the bundle is written.
        var beforeWrite: (() throws -> Void)?
        /// Fires after a successful write and BEFORE verification — the window a corrupted or
        /// truncated bundle has to appear in.
        var afterWrite: (() throws -> Void)?
        init(beforeWrite: (() throws -> Void)? = nil, afterWrite: (() throws -> Void)? = nil) {
            self.beforeWrite = beforeWrite
            self.afterWrite = afterWrite
        }
    }

    // MARK: - Naming

    /// `pre-migrate-v<from>-<timestamp>`, with `-2`, `-3`… appended if that name is taken.
    ///
    /// The suffix is not cosmetic. `BackupExport.writeBundle` REFUSES an existing destination, and
    /// the App's timestamp has one-second resolution, so a migration that fails and is retried
    /// within the same second would otherwise turn a recoverable situation into an app that cannot
    /// open at all.
    static func uniqueDestination(in directory: URL, fromVersion: Int, timestamp: String) throws -> URL {
        let base = "\(namePrefix)v\(fromVersion)-\(timestamp)"
        let fm = FileManager.default
        var candidate = directory.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)-\(n)", isDirectory: true)
            n += 1
            if n > 1000 { throw PreMigrationSnapshotError.writeFailed }   // pathological; fail closed
        }
        return candidate
    }

    // MARK: - Retention

    /// Keep the newest `keeping` snapshots, remove the rest. Best-effort by contract.
    ///
    /// Ordering is by NAME, which is chronological because the timestamp is fixed-width
    /// `yyyy-MM-dd-HHmmss`; a same-second `-2` sorts after its base, which is also the order they
    /// were written in. Only entries carrying ``namePrefix`` are considered, so `pre-restore-*`
    /// and user exports living in the same directory are never candidates.
    static func prune(in directory: URL, keeping: Int) {
        guard keeping >= 0 else { return }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        let ours = names.filter { $0.hasPrefix(namePrefix) }.sorted()
        guard ours.count > keeping else { return }
        for name in ours.prefix(ours.count - keeping) {
            try? fm.removeItem(at: directory.appendingPathComponent(name, isDirectory: true))
        }
    }

    private static func removeQuietly(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
