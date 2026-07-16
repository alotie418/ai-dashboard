import Foundation

/// What `boot` should do about the active database.
public enum ActiveDatabaseDecision: Equatable {
    case openExisting                                        // active DB already present
    case createFresh                                         // no legacy data → new install, blank DB is fine
    case adopted(backupPath: String, transactionsMigrated: Int) // upgrade succeeded
    case blockedMigrationFailed(String)                      // legacy present but upgrade FAILED — do NOT create a DB
}

/// Safe one-time adoption of an existing Electron database by the native app.
///
/// The original Electron database is **never opened by SQLite and never modified**.
/// Because Electron runs in WAL mode, we first take a snapshot by file-copying the
/// durable WAL set (`.db` + `-wal`) into a staging copy — a pure file read of the
/// original — GUARDED by a before/after stability check so a still-running old app
/// can't hand us a torn snapshot. The `-shm` file is a rebuildable WAL index (shared
/// memory), NOT durable data, so it is deliberately NOT copied; SQLite reconstructs
/// it from the copied `-wal` when the staging copy is opened (copying a stale `-shm`
/// from another process could corrupt reads). All SQLite work happens on the copy:
///
///   1. DISCOVER  — legacy file present? active file absent?
///   2. SNAPSHOT  — stable file-copy of `.db` + `-wal` into a staging file
///   3. NORMALIZE — on the COPY: checkpoint the WAL into the main file, drop to a
///                  clean single-file journal, then PRAGMA quick_check
///   4. VERSION   — refuse a database newer than we support (unknown schema)
///   5. BACKUP    — consistent snapshot of the normalized copy via the SQLite
///                  Backup API → preserved pre-upgrade backup, then verify it
///   6. MIGRATE   — run the migrator on the staging copy and verify integrity
///   7. SWAP      — atomically move the verified copy into the active location
///   8. ROLLBACK  — on any failure, remove partial artifacts; the original and the
///                  backup remain intact. The original is never deleted.
public final class DatabaseUpgrade {

    public struct Paths {
        public var legacySource: URL       // Electron DB — read (file copy) only, never modified
        public var activeDestination: URL  // native active DB — produced by the atomic swap
        public var backupsDirectory: URL
        public var workingDirectory: URL

        public init(legacySource: URL, activeDestination: URL, backupsDirectory: URL, workingDirectory: URL) {
            self.legacySource = legacySource
            self.activeDestination = activeDestination
            self.backupsDirectory = backupsDirectory
            self.workingDirectory = workingDirectory
        }
    }

    /// Test seams to simulate interruption/failure at specific points.
    public struct Hooks {
        public var duringCopy: ((Int) throws -> Void)?   // fires after each snapshot copy attempt (index)
        public var afterBackup: (() throws -> Void)?
        public var beforeSwap: (() throws -> Void)?
        public init(duringCopy: ((Int) throws -> Void)? = nil,
                    afterBackup: (() throws -> Void)? = nil,
                    beforeSwap: (() throws -> Void)? = nil) {
            self.duringCopy = duringCopy
            self.afterBackup = afterBackup
            self.beforeSwap = beforeSwap
        }
    }

    public enum Outcome: Equatable {
        case noLegacyData
        case alreadyUpgraded
        case upgraded(backupPath: String, transactionsMigrated: Int)
    }

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case sourceBusy(String)
        case snapshotFailed(String)
        case integrityFailed(String)
        case unknownVersion(found: Int, supported: Int)
        case backupFailed(String)
        case migrationFailed(String)
        case swapFailed(String)
        case interrupted(String)

        public var description: String {
            switch self {
            case .sourceBusy(let m): return "legacy database is still changing: \(m)"
            case .snapshotFailed(let m): return "could not snapshot the legacy database: \(m)"
            case .integrityFailed(let m): return "legacy database failed integrity check: \(m)"
            case let .unknownVersion(f, s): return "legacy database schema version \(f) is newer than supported \(s)"
            case .backupFailed(let m): return "consistent backup failed: \(m)"
            case .migrationFailed(let m): return "migration of the working copy failed: \(m)"
            case .swapFailed(let m): return "atomic swap failed: \(m)"
            case .interrupted(let m): return "upgrade interrupted: \(m)"
            }
        }
    }

    private let paths: Paths
    private let hooks: Hooks
    private let timestamp: String
    private let fm = FileManager.default

    // `-wal` carries durable, un-checkpointed committed data → must be copied.
    // `-shm` is a per-process shared-memory WAL index → rebuildable, never copied.
    private static let durableSidecars = ["-wal"]
    private static let allSidecars = ["-wal", "-shm"]

    public init(paths: Paths, hooks: Hooks = Hooks(), timestamp: String) {
        self.paths = paths
        self.hooks = hooks
        self.timestamp = timestamp
    }

    /// Convenience wiring against `AppPaths` for the running app.
    public static func standard(timestamp: String) throws -> DatabaseUpgrade {
        let paths = Paths(
            legacySource: try AppPaths.electronLegacyDatabaseURL(),
            activeDestination: try AppPaths.databaseURL(),
            backupsDirectory: try AppPaths.backupsDirectory(),
            workingDirectory: try AppPaths.upgradeWorkingDirectory()
        )
        return DatabaseUpgrade(paths: paths, timestamp: timestamp)
    }

    /// The decision `boot` should act on. Guarantees an empty active DB is NEVER
    /// created to paper over a migration failure: if legacy data exists but the
    /// upgrade fails, the result is `.blockedMigrationFailed` and no active DB is
    /// created — the next launch discovers the (still-absent) active DB and retries.
    public func prepareActiveDatabase() -> ActiveDatabaseDecision {
        if fm.fileExists(atPath: paths.activeDestination.path) { return .openExisting }
        do {
            switch try run() {
            case .noLegacyData: return .createFresh
            case .alreadyUpgraded: return .openExisting
            case let .upgraded(backup, migrated): return .adopted(backupPath: backup, transactionsMigrated: migrated)
            }
        } catch {
            return .blockedMigrationFailed("\(error)")
        }
    }

    @discardableResult
    public func run() throws -> Outcome {
        // 1. DISCOVER
        guard fm.fileExists(atPath: paths.legacySource.path) else { return .noLegacyData }
        if fm.fileExists(atPath: paths.activeDestination.path) { return .alreadyUpgraded }

        try fm.createDirectory(at: paths.backupsDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: paths.workingDirectory, withIntermediateDirectories: true)

        let staging = paths.workingDirectory.appendingPathComponent("sololedger-staging-\(timestamp).db")
        let backup = paths.backupsDirectory.appendingPathComponent("sololedger-preupgrade-\(timestamp).db")
        func rollback() { try? removeDBSet(staging) }

        // 2. SNAPSHOT — stable file-copy of .db + -wal (never the rebuildable -shm).
        do {
            try stableSnapshot(from: paths.legacySource, to: staging)
        } catch let f as Failure { throw f }
        catch { throw Failure.snapshotFailed("\(error)") }

        // 3/4. NORMALIZE + INTEGRITY + VERSION — all on the staging COPY.
        let sourceVersion: Int
        do {
            let db = try SQLiteDatabase(path: staging.path)   // read-write on the copy
            try db.execute("PRAGMA wal_checkpoint(TRUNCATE)") // fold the copied WAL frames into the main file
            try db.execute("PRAGMA journal_mode = DELETE")    // normalize to a clean single file
            guard try db.quickCheck() else { throw Failure.integrityFailed("PRAGMA quick_check != ok") }
            sourceVersion = try db.userVersion()
        } catch let f as Failure { rollback(); throw f }
        catch { rollback(); throw Failure.integrityFailed("\(error)") }

        if sourceVersion > SchemaMigrator.schemaVersion {
            rollback()
            throw Failure.unknownVersion(found: sourceVersion, supported: SchemaMigrator.schemaVersion)
        }

        // 5. CONSISTENT BACKUP (SQLite Backup API) of the normalized copy + verify it.
        do {
            let src = try SQLiteDatabase(path: staging.path, readOnly: true) // DELETE mode → read-only OK
            try src.backup(toPath: backup.path)
            let verify = try SQLiteDatabase(path: backup.path, readOnly: true)
            guard try verify.quickCheck() else { throw Failure.backupFailed("backup failed its integrity check") }
        } catch let f as Failure { rollback(); try? removeDBSet(backup); throw f }
        catch { rollback(); try? removeDBSet(backup); throw Failure.backupFailed("\(error)") }

        do { try hooks.afterBackup?() } catch { rollback(); throw Failure.interrupted("after backup: \(error)") }

        // 6. MIGRATE + VERIFY the staging copy (the working copy).
        var migratedCount = 0
        do {
            let db = try SQLiteDatabase(path: staging.path)
            try db.execute("PRAGMA foreign_keys = ON")
            try SchemaMigrator.migrate(db)                    // no-op at v23; upgrades if < 23
            guard try db.integrityCheck() else { throw Failure.migrationFailed("integrity_check != ok after migrate") }
            let tables = try db.query("SELECT name FROM sqlite_master WHERE type='table'").compactMap { $0.string("name") }
            for required in ["transactions", "categories", "settings"] where !tables.contains(required) {
                throw Failure.migrationFailed("missing required table '\(required)' after migrate")
            }
            migratedCount = try db.query("SELECT COUNT(*) AS c FROM transactions").first?.int("c") ?? 0
        } catch let f as Failure { rollback(); throw f }
        catch { rollback(); throw Failure.migrationFailed("\(error)") }

        // Simulated interruption right before the swap → clean rollback.
        do { try hooks.beforeSwap?() } catch { rollback(); throw Failure.interrupted("before swap: \(error)") }

        // 7. ATOMIC SWAP — move the verified single-file copy into the active destination.
        do {
            try removeDBSet(staging, keepMain: true) // drop any stray sidecars, keep the file we move
            try fm.createDirectory(at: paths.activeDestination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: paths.activeDestination.path) {
                _ = try fm.replaceItemAt(paths.activeDestination, withItemAt: staging)
            } else {
                try fm.moveItem(at: staging, to: paths.activeDestination)
            }
        } catch {
            rollback()   // original + backup remain intact
            throw Failure.swapFailed("\(error)")
        }

        // 8. Original never modified/deleted.
        return .upgraded(backupPath: backup.path, transactionsMigrated: migratedCount)
    }

    // MARK: - Stable snapshot (guards against copying a live, changing source)

    /// File-copy `.db` + `-wal` into `dst`, verifying the source did not change during
    /// the copy (fingerprint before vs after). Retries a few times, then gives up with
    /// `.sourceBusy` so the caller can prompt the user to quit the old app. Only after a
    /// stable copy is this a true point-in-time snapshot.
    private func stableSnapshot(from src: URL, to dst: URL, attempts: Int = 3) throws {
        for attempt in 1...attempts {
            let before = fingerprint(src)
            try removeDBSet(dst)
            try copyDurableSet(from: src, to: dst)
            try hooks.duringCopy?(attempt)        // test seam to perturb the source
            let after = fingerprint(src)
            if before == after { return }         // stable → good snapshot
            try? removeDBSet(dst)
        }
        throw Failure.sourceBusy("legacy database kept changing during copy — please quit the old app and retry")
    }

    /// Size + modification-time of the `.db` and its sidecars — cheap change detector.
    private func fingerprint(_ url: URL) -> [String: String] {
        var fp: [String: String] = [:]
        for suffix in [""] + Self.allSidecars {
            let path = url.path + suffix
            if let attrs = try? fm.attributesOfItem(atPath: path) {
                let size = (attrs[.size] as? NSNumber)?.intValue ?? -1
                let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                fp[suffix] = "\(size):\(mtime)"
            } else {
                fp[suffix] = "absent"
            }
        }
        return fp
    }

    // MARK: - File helpers

    private func copyDurableSet(from src: URL, to dst: URL) throws {
        try fm.copyItem(at: src, to: dst)                 // main .db
        for suffix in Self.durableSidecars {              // -wal only (NOT the rebuildable -shm)
            let s = URL(fileURLWithPath: src.path + suffix)
            if fm.fileExists(atPath: s.path) {
                try fm.copyItem(at: s, to: URL(fileURLWithPath: dst.path + suffix))
            }
        }
    }

    private func removeDBSet(_ url: URL, keepMain: Bool = false) throws {
        let suffixes = keepMain ? Self.allSidecars : ([""] + Self.allSidecars)
        for suffix in suffixes {
            let u = URL(fileURLWithPath: url.path + suffix)
            if fm.fileExists(atPath: u.path) { try fm.removeItem(at: u) }
        }
    }
}
