import Foundation

// MARK: - Runner errors / result

public enum PreparedRunFailure: Error, CustomStringConvertible, Equatable {
    case snapshotCopyFailed(String)
    case unsupportedUserVersion(found: Int)
    case integrityFailed(String)
    case foreignKeyViolations(String)
    case migrationFailed(String)
    case schemaIncomplete(String)
    case notQuiescent(String)
    case identityFailed(String)
    case publishFailed(String)
    case preparedPublishConflict(String)

    public var description: String {
        switch self {
        case .snapshotCopyFailed(let m): return "Copying the staged snapshot into the working copy failed: \(m)"
        case .unsupportedUserVersion(let v): return "Prepared database user_version \(v) is unsupported (must be 0…\(SchemaMigrator.schemaVersion))"
        case .integrityFailed(let m): return "Prepared database failed its integrity check: \(m)"
        case .foreignKeyViolations(let m): return "Prepared database has foreign-key violations: \(m)"
        case .migrationFailed(let m): return "Migration of the working copy failed: \(m)"
        case .schemaIncomplete(let m): return "Prepared database is missing required tables: \(m)"
        case .notQuiescent(let m): return "Prepared database working copy is not a single quiescent file: \(m)"
        case .identityFailed(let m): return "Computing the prepared database identity failed: \(m)"
        case .publishFailed(let m): return "Publishing the prepared artifact failed: \(m)"
        case .preparedPublishConflict(let m): return "A prepared artifact for this import already exists but does not match this snapshot: \(m)"
        }
    }
}

/// The runner's own metadata written beside the prepared DB, binding this snapshot to the
/// prepared product so a crash-interrupted import can be RESUMED (idempotently reused) on the
/// next run without re-deriving byte-identical output. Migration writes `datetime('now')` into
/// seed rows, so the prepared DB is NOT byte-deterministic across runs — reuse therefore binds
/// on the SNAPSHOT identity + the recorded prepared identity, not on prepared-byte equality.
///
/// Its own `formatVersion` is independent of `ImportManifest.currentFormatVersion` (this is
/// runner metadata, not the ingest manifest).
struct PreparedProvenance: Codable, Equatable {
    static let currentFormatVersion = 1
    var formatVersion: Int
    var importID: String
    var snapshotIdentitySHA256: String
    var attachmentManifestSHA256: String
    var sourceDBSHA256: String
    var walSHA256: String?
    var preparedDBIdentity: String
    var transactionsMigrated: Int
}

/// A normalized, migrated, QUIESCENT single-file prepared database + its computed identity.
/// It carries the gate evidence (`gated`) forward so the coordinator can run the
/// descriptor-bound attachment apply against the SAME staging the DB came from. Internal init.
public struct PreparedImport {
    public let importID: ImportID
    /// The published prepared DB, INSIDE the atomic artifact dir
    /// (`preparedRoot/import-<id>/sololedger.db`). DELETE-journal, no sidecars.
    public let preparedDatabaseURL: URL
    /// `"sha256:…"` from PreparedDatabaseIdentity.compute — the ONLY sanctioned identity.
    public let preparedDBIdentity: String
    public let manifest: ImportManifest
    public let gated: GatedStagedSnapshot
    public let transactionsMigrated: Int
    /// True when this run RESUMED an already-published artifact rather than migrating afresh.
    public let reusedExisting: Bool

    init(importID: ImportID, preparedDatabaseURL: URL, preparedDBIdentity: String,
         manifest: ImportManifest, gated: GatedStagedSnapshot, transactionsMigrated: Int,
         reusedExisting: Bool) {
        self.importID = importID
        self.preparedDatabaseURL = preparedDatabaseURL
        self.preparedDBIdentity = preparedDBIdentity
        self.manifest = manifest
        self.gated = gated
        self.transactionsMigrated = transactionsMigrated
        self.reusedExisting = reusedExisting
    }
}

/// Test-only fault seams (internal, no-op by default).
struct RunnerHooks {
    var afterCopy: ((URL) throws -> Void)?               // working attempt, after DB(+WAL) copied
    var beforeMigrate: ((SQLiteDatabase) throws -> Void)?
    var beforePublish: ((URL) throws -> Void)?           // final artifact URL, before the atomic rename
    var afterPublish: ((URL) throws -> Void)?            // final artifact URL, AFTER the rename (crash sim)
    init(afterCopy: ((URL) throws -> Void)? = nil,
         beforeMigrate: ((SQLiteDatabase) throws -> Void)? = nil,
         beforePublish: ((URL) throws -> Void)? = nil,
         afterPublish: ((URL) throws -> Void)? = nil) {
        self.afterCopy = afterCopy; self.beforeMigrate = beforeMigrate
        self.beforePublish = beforePublish; self.afterPublish = afterPublish
    }
}

// MARK: - The runner

/// Turns a GATED staging snapshot into a normalized, migrated, quiescent prepared database,
/// published as an ATOMIC ARTIFACT DIRECTORY (`preparedRoot/import-<id>/` containing exactly
/// `sololedger.db` + `provenance.json`).
///
/// The staged original is NEVER opened by SQLite. The DB (+ WAL) are copied THROUGH the gate's
/// descriptor into a fresh, process-private attempt, migrated on that private copy, then the
/// closed prepared DB is copied (no-follow, digest-re-verified) into an artifact attempt built
/// INSIDE `preparedRoot` (same volume as the final location) and published via an exclusive,
/// same-directory `renameatx_np(RENAME_EXCL)` — a true atomic rename that never overwrites a
/// winner and never degrades to a cross-volume copy. A crash after publish is recoverable: the
/// next run finds the artifact, re-validates it descriptor-rooted against this snapshot, and
/// reuses it idempotently.
public struct PreparedImportRunner {
    public init() {}

    public func run(_ gated: GatedStagedSnapshot, workingDirectory: URL, preparedRoot: URL) throws -> PreparedImport {
        try run(gated, workingDirectory: workingDirectory, preparedRoot: preparedRoot, hooks: RunnerHooks())
    }

    func run(_ gated: GatedStagedSnapshot, workingDirectory: URL, preparedRoot: URL,
             hooks: RunnerHooks) throws -> PreparedImport {
        let fm = FileManager.default
        let dbName = AppPaths.databaseFileName
        try fm.createDirectory(at: preparedRoot, withIntermediateDirectories: true)
        let finalArtifact = preparedRoot.appendingPathComponent("import-\(gated.importID.rawValue)", isDirectory: true)

        // FAST PATH / crash-resume: an artifact already published → reuse iff fully consistent
        // with THIS snapshot, else hard conflict (never touch the winner).
        if let reused = try Self.reuseIfConsistent(finalArtifact, gated: gated) { return reused }

        // 1. Fresh, process-private working attempt (brand-new — never reuses a planted one).
        try fm.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let workAttempt = workingDirectory.appendingPathComponent(".prep-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: workAttempt, withIntermediateDirectories: false)
        var workDone = false
        defer { if !workDone { try? fm.removeItem(at: workAttempt) } }

        // 2. Copy DB (+ optional WAL) THROUGH the gate descriptor, verifying digests.
        let workDB = workAttempt.appendingPathComponent(dbName)
        do {
            let dbDigest = try gated.root.copyRegularFile(named: dbName, to: workDB)
            guard dbDigest.sha256 == gated.manifest.sourceDBSHA256 else {
                throw PreparedRunFailure.snapshotCopyFailed("copied db digest != manifest.sourceDBSHA256")
            }
            if gated.hasWAL {
                let walDigest = try gated.root.copyRegularFile(named: dbName + "-wal", to: URL(fileURLWithPath: workDB.path + "-wal"))
                guard walDigest.sha256 == gated.manifest.walSHA256 else {
                    throw PreparedRunFailure.snapshotCopyFailed("copied wal digest != manifest.walSHA256")
                }
            }
        } catch let e as PreparedRunFailure { throw e }
        catch { throw PreparedRunFailure.snapshotCopyFailed("\(error)") }
        try hooks.afterCopy?(workAttempt)

        // 3. Normalize + migrate on the COPY (read-write-EXISTING: never CREATE).
        let migratedCount = try Self.normalizeAndMigrate(preparedDB: workDB, hooks: hooks)

        // 3b. Drop rebuildable WAL sidecars SQLite may leave after WAL→DELETE; require single file.
        try Self.dropSidecars(besides: workDB)
        try Self.assertSingleFile(workAttempt, dbName: dbName)

        // 4. Identity — after every connection is closed and all sidecars are gone.
        let identity: String
        do { identity = try PreparedDatabaseIdentity.compute(at: workDB) }
        catch { throw PreparedRunFailure.identityFailed("\(error)") }

        // 5. Build the artifact ATTEMPT inside preparedRoot (SAME VOLUME as the final): copy the
        //    closed prepared DB in (no-follow, digest+identity re-verified) + provenance.
        let artAttempt = preparedRoot.appendingPathComponent(".artifact-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: artAttempt, withIntermediateDirectories: false)
        var artDone = false
        defer { if !artDone { try? fm.removeItem(at: artAttempt) } }

        let artDB = artAttempt.appendingPathComponent(dbName)
        do {
            let src = try DirectoryHandle.open(at: workAttempt)
            _ = try src.copyRegularFile(named: dbName, to: artDB)   // no-follow, fd-bound; byte-identity re-checked below
        } catch { throw PreparedRunFailure.snapshotCopyFailed("artifact db copy: \(error)") }
        let artIdentity: String
        do { artIdentity = try PreparedDatabaseIdentity.compute(at: artDB) }
        catch { throw PreparedRunFailure.identityFailed("artifact: \(error)") }
        guard artIdentity == identity else {
            throw PreparedRunFailure.snapshotCopyFailed("artifact db identity != working copy identity")
        }
        let provenance = PreparedProvenance(
            formatVersion: PreparedProvenance.currentFormatVersion, importID: gated.importID.rawValue,
            snapshotIdentitySHA256: gated.manifest.snapshotIdentitySHA256,
            attachmentManifestSHA256: gated.manifest.attachmentManifestSHA256,
            sourceDBSHA256: gated.manifest.sourceDBSHA256, walSHA256: gated.manifest.walSHA256,
            preparedDBIdentity: identity, transactionsMigrated: migratedCount)
        do {
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try DirectoryHandle.open(at: artAttempt).createRegularFileExclusively(named: "provenance.json", contents: try enc.encode(provenance))
        } catch { throw PreparedRunFailure.publishFailed("provenance write: \(error)") }
        try Self.assertArtifactEntrySet(artAttempt, dbName: dbName)

        // 6. Atomic, exclusive, SAME-DIRECTORY publish: renameatx_np(RENAME_EXCL). Never
        //    overwrites, never a cross-volume copy (both entries live in preparedRoot).
        try hooks.beforePublish?(finalArtifact)
        let published = try Self.exclusiveRename(inDir: preparedRoot,
                                                 from: artAttempt.lastPathComponent,
                                                 to: finalArtifact.lastPathComponent)
        if published {
            artDone = true; workDone = true
            try? fm.removeItem(at: workAttempt)
            try hooks.afterPublish?(finalArtifact)   // crash-simulation window
            return PreparedImport(importID: gated.importID, preparedDatabaseURL: finalArtifact.appendingPathComponent(dbName),
                                  preparedDBIdentity: identity, manifest: gated.manifest, gated: gated,
                                  transactionsMigrated: migratedCount, reusedExisting: false)
        }
        // The destination appeared between the fast-path check and the rename (publish race).
        // Reuse iff the winner is consistent with THIS snapshot, else conflict — never overwrite.
        if let reused = try Self.reuseIfConsistent(finalArtifact, gated: gated) { return reused }
        throw PreparedRunFailure.preparedPublishConflict("import-\(gated.importID.rawValue): a different artifact won the publish race")
    }

    // MARK: - Crash-resume: validate + reuse an existing artifact

    /// nil ⇔ no artifact exists yet (proceed to migrate). A present artifact is validated
    /// DESCRIPTOR-ROOTED against `gated`; consistent ⇒ reuse (returns the PreparedImport),
    /// anything else ⇒ hard conflict (throws, never touches the artifact).
    static func reuseIfConsistent(_ artifact: URL, gated: GatedStagedSnapshot) throws -> PreparedImport? {
        let root: DirectoryHandle
        do { root = try DirectoryHandle.open(at: artifact) }
        catch let e as FileHashError where e.isFileMissing { return nil }
        catch { throw PreparedRunFailure.preparedPublishConflict("existing artifact unreadable / not a directory: \(error)") }

        func conflict(_ m: String) -> PreparedRunFailure { .preparedPublishConflict("import-\(gated.importID.rawValue): \(m)") }
        let dbName = AppPaths.databaseFileName

        // Exact entry set + per-entry type, through the bound descriptor.
        guard let entries = try? root.entryNames(), Set(entries) == [dbName, "provenance.json"] else {
            throw conflict("artifact entry set is not exactly {\(dbName), provenance.json}")
        }
        guard let dbFP = try? root.fingerprint(named: dbName), dbFP.isRegularFile,
              let pFP = try? root.fingerprint(named: "provenance.json"), pFP.isRegularFile else {
            throw conflict("artifact entries are not both regular files")
        }

        // Provenance, read THROUGH the descriptor, decoded and bound to THIS snapshot.
        guard let data = try? root.readRegularFile(named: "provenance.json"),
              let prov = try? JSONDecoder().decode(PreparedProvenance.self, from: data) else {
            throw conflict("provenance.json is missing / undecodable")
        }
        let m = gated.manifest
        guard prov.formatVersion == PreparedProvenance.currentFormatVersion,
              prov.importID == gated.importID.rawValue,
              prov.snapshotIdentitySHA256 == m.snapshotIdentitySHA256,
              prov.attachmentManifestSHA256 == m.attachmentManifestSHA256,
              prov.sourceDBSHA256 == m.sourceDBSHA256,
              prov.walSHA256 == m.walSHA256 else {
            throw conflict("provenance does not match this snapshot")
        }

        // Recompute the existing prepared DB's identity — it must equal what provenance records
        // (the artifact's own DB was not swapped/corrupted after publish).
        let dbURL = artifact.appendingPathComponent(dbName)
        let current: String
        do { current = try PreparedDatabaseIdentity.compute(at: dbURL) }
        catch { throw conflict("existing prepared DB identity unreadable: \(error)") }
        guard current == prov.preparedDBIdentity else {
            throw conflict("existing prepared DB identity \(current) != provenance \(prov.preparedDBIdentity)")
        }

        return PreparedImport(importID: gated.importID, preparedDatabaseURL: dbURL,
                              preparedDBIdentity: prov.preparedDBIdentity, manifest: m, gated: gated,
                              transactionsMigrated: prov.transactionsMigrated, reusedExisting: true)
    }

    // MARK: - Normalize + migrate (on the private copy only)

    private static func normalizeAndMigrate(preparedDB: URL, hooks: RunnerHooks) throws -> Int {
        let db: SQLiteDatabase
        do { db = try SQLiteDatabase(path: preparedDB.path, mode: .readWriteExisting) }
        catch { throw PreparedRunFailure.integrityFailed("cannot open working copy: \(error)") }

        var closed = false
        func close() throws { if !closed { try db.close(); closed = true } }
        defer { if !closed { try? db.close() } }

        do {
            try db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            try db.execute("PRAGMA journal_mode = DELETE")
            guard try db.quickCheck() else { throw PreparedRunFailure.integrityFailed("quick_check != ok") }

            let v = try db.userVersion()
            guard v >= 0, v <= SchemaMigrator.schemaVersion else { throw PreparedRunFailure.unsupportedUserVersion(found: v) }

            try hooks.beforeMigrate?(db)
            try db.execute("PRAGMA foreign_keys = ON")
            do { try SchemaMigrator.migrate(db) }
            catch let e as SchemaMigrator.MigrationError {
                if case .newerThanSupported(let f, _) = e { throw PreparedRunFailure.unsupportedUserVersion(found: f) }
                if case .corruptVersion(let f) = e { throw PreparedRunFailure.unsupportedUserVersion(found: f) }
                throw PreparedRunFailure.migrationFailed("\(e)")
            }
            let head = try db.userVersion()
            guard head == SchemaMigrator.schemaVersion else {
                throw PreparedRunFailure.migrationFailed("user_version is \(head) after migrate, expected \(SchemaMigrator.schemaVersion)")
            }
            guard try db.integrityCheck() else { throw PreparedRunFailure.integrityFailed("integrity_check != ok after migrate") }
            let fkRows = try db.query("PRAGMA foreign_key_check")
            guard fkRows.isEmpty else { throw PreparedRunFailure.foreignKeyViolations("\(fkRows.count) violation row(s)") }

            let present = Set(try db.query("SELECT name FROM sqlite_master WHERE type = 'table'").compactMap { $0.string("name") })
            let missing = SchemaMigrator.requiredTables.filter { !present.contains($0) }
            guard missing.isEmpty else { throw PreparedRunFailure.schemaIncomplete(missing.sorted().joined(separator: ", ")) }

            let count = try db.query("SELECT COUNT(*) AS c FROM transactions").first?.int("c") ?? 0
            try close()
            return count
        } catch let e as PreparedRunFailure {
            try? close(); throw e
        } catch {
            try? close(); throw PreparedRunFailure.migrationFailed("\(error)")
        }
    }

    // MARK: - Filesystem helpers

    private static func dropSidecars(besides db: URL) throws {
        let fm = FileManager.default
        for suffix in ["-wal", "-shm", "-journal"] {
            let side = URL(fileURLWithPath: db.path + suffix)
            if fm.fileExists(atPath: side.path) {
                do { try fm.removeItem(at: side) }
                catch { throw PreparedRunFailure.notQuiescent("could not drop stale \(suffix): \(error)") }
            }
        }
    }

    private static func assertSingleFile(_ dir: URL, dbName: String) throws {
        let h: DirectoryHandle
        do { h = try DirectoryHandle.open(at: dir) }
        catch { throw PreparedRunFailure.notQuiescent("attempt dir unreadable: \(error)") }
        let entries = Set(try h.entryNames())
        guard entries == [dbName] else {
            throw PreparedRunFailure.notQuiescent("attempt dir is \(entries.sorted()), expected exactly [\(dbName)]")
        }
    }

    private static func assertArtifactEntrySet(_ dir: URL, dbName: String) throws {
        let h = try DirectoryHandle.open(at: dir)
        let entries = Set(try h.entryNames())
        guard entries == [dbName, "provenance.json"] else {
            throw PreparedRunFailure.publishFailed("artifact attempt is \(entries.sorted()), expected exactly [\(dbName), provenance.json]")
        }
    }

    /// Atomic, exclusive, same-directory rename via `renameatx_np(RENAME_EXCL)`. Both names are
    /// resolved relative to the SAME `preparedRoot` descriptor, so the rename is guaranteed
    /// same-volume and atomic; RENAME_EXCL means it NEVER overwrites an existing destination.
    /// Returns false iff the destination already exists (EEXIST/ENOTEMPTY).
    private static func exclusiveRename(inDir dir: URL, from: String, to: String) throws -> Bool {
        let d = try DirectoryHandle.open(at: dir)
        let RENAME_EXCL_FLAG: UInt32 = 0x0004   // <sys/stdio.h> RENAME_EXCL
        let rc = from.withCString { f in to.withCString { t in
            renameatx_np(d.fd, f, d.fd, t, RENAME_EXCL_FLAG)
        } }
        if rc == 0 { return true }
        let e = errno
        if e == EEXIST || e == ENOTEMPTY { return false }
        throw PreparedRunFailure.publishFailed("renameatx_np(RENAME_EXCL) failed: errno \(e)")
    }
}
