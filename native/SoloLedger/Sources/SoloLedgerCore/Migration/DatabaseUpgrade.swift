import Foundation

/// Safe one-time adoption of an existing Electron database by the native app.
///
/// The original Electron database is **never opened by SQLite and never modified**.
/// Because Electron runs in WAL mode, we first take a point-in-time snapshot by
/// raw-copying the full WAL set (`.db` + `-wal` + `-shm`) into a staging copy — a
/// pure file read of the original — then do all SQLite work on that copy:
///
///   1. DISCOVER  — legacy file present? active file absent?
///   2. SNAPSHOT  — raw-copy the WAL set into a staging file (original untouched)
///   3. NORMALIZE — on the COPY: checkpoint any WAL into the main file, drop to a
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
        public var afterBackup: (() throws -> Void)?
        public var beforeSwap: (() throws -> Void)?
        public init(afterBackup: (() throws -> Void)? = nil, beforeSwap: (() throws -> Void)? = nil) {
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
        case snapshotFailed(String)
        case integrityFailed(String)
        case unknownVersion(found: Int, supported: Int)
        case backupFailed(String)
        case migrationFailed(String)
        case swapFailed(String)
        case interrupted(String)

        public var description: String {
            switch self {
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

        // 2. SNAPSHOT — raw copy of the full WAL set; the original is never opened by SQLite.
        do {
            try removeDBSet(staging)
            try copyDBSet(from: paths.legacySource, to: staging)
        } catch {
            throw Failure.snapshotFailed("\(error)")
        }

        // 3/4. NORMALIZE + INTEGRITY + VERSION — all on the staging COPY.
        let sourceVersion: Int
        do {
            let db = try SQLiteDatabase(path: staging.path)   // read-write on the copy
            try db.execute("PRAGMA wal_checkpoint(TRUNCATE)") // fold any WAL frames into the main file
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
            try removeDBSet(URL(fileURLWithPath: staging.path), keepMain: true) // drop any stray sidecars
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

    // MARK: - File helpers (WAL set = .db + -wal + -shm)

    private static let sidecars = ["-wal", "-shm"]

    private func copyDBSet(from src: URL, to dst: URL) throws {
        try fm.copyItem(at: src, to: dst)
        for suffix in Self.sidecars {
            let s = URL(fileURLWithPath: src.path + suffix)
            if fm.fileExists(atPath: s.path) {
                try fm.copyItem(at: s, to: URL(fileURLWithPath: dst.path + suffix))
            }
        }
    }

    private func removeDBSet(_ url: URL, keepMain: Bool = false) throws {
        let suffixes = keepMain ? Self.sidecars : ([""] + Self.sidecars)
        for suffix in suffixes {
            let u = URL(fileURLWithPath: url.path + suffix)
            if fm.fileExists(atPath: u.path) { try fm.removeItem(at: u) }
        }
    }
}
