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
        case .preparedPublishConflict(let m): return "A prepared database for this import already exists with a different identity: \(m)"
        }
    }
}

/// A normalized, migrated, QUIESCENT single-file prepared database + its computed identity.
/// It carries the gate evidence (`gated`) forward so the coordinator can run the
/// descriptor-bound attachment apply against the SAME staging the DB came from. Internal init.
public struct PreparedImport {
    public let importID: ImportID
    /// The published prepared DB (DELETE-journal, no `-wal`/`-shm`/`-journal` sidecars).
    public let preparedDatabaseURL: URL
    /// `"sha256:…"` from PreparedDatabaseIdentity.compute — the ONLY sanctioned identity.
    public let preparedDBIdentity: String
    public let manifest: ImportManifest
    /// The gate evidence: descriptor-bound staging + verified manifest, kept for the later
    /// attachment-apply stage so it never re-reads the staging tree by path.
    public let gated: GatedStagedSnapshot
    public let transactionsMigrated: Int

    init(importID: ImportID, preparedDatabaseURL: URL, preparedDBIdentity: String,
         manifest: ImportManifest, gated: GatedStagedSnapshot, transactionsMigrated: Int) {
        self.importID = importID
        self.preparedDatabaseURL = preparedDatabaseURL
        self.preparedDBIdentity = preparedDBIdentity
        self.manifest = manifest
        self.gated = gated
        self.transactionsMigrated = transactionsMigrated
    }
}

/// Test-only fault seams (internal, no-op by default).
struct RunnerHooks {
    var afterCopy: ((URL) throws -> Void)?              // attempt dir, after DB(+WAL) copied
    var beforeMigrate: ((SQLiteDatabase) throws -> Void)?
    var beforePublish: ((URL) throws -> Void)?         // finalURL, before the atomic move
    init(afterCopy: ((URL) throws -> Void)? = nil,
         beforeMigrate: ((SQLiteDatabase) throws -> Void)? = nil,
         beforePublish: ((URL) throws -> Void)? = nil) {
        self.afterCopy = afterCopy; self.beforeMigrate = beforeMigrate; self.beforePublish = beforePublish
    }
}

// MARK: - The runner

/// Turns a GATED staging snapshot into a normalized, migrated, quiescent prepared database.
///
/// The staged original is NEVER opened by SQLite (sqlite3_open_v2 is path-based and follows
/// symlinks). The DB (and its WAL, iff recorded) are copied THROUGH the gate's descriptor
/// (`GatedStagedSnapshot.root`, O_NOFOLLOW|O_DIRECTORY) into a fresh, process-private attempt
/// dir with O_EXCL destinations, and every downstream SQLite step runs only on that private
/// copy. Deliberately does NOT reuse DatabaseUpgrade's `stableSnapshot`/`copyDurableSet`
/// (path-based `copyItem`/`fileExists`, follows symlinks) — the staging is already a
/// quiescent, digest-bound published snapshot, so the copy is verified against the manifest.
public struct PreparedImportRunner {
    public init() {}

    public func run(_ gated: GatedStagedSnapshot, workingDirectory: URL, preparedRoot: URL) throws -> PreparedImport {
        try run(gated, workingDirectory: workingDirectory, preparedRoot: preparedRoot, hooks: RunnerHooks())
    }

    func run(_ gated: GatedStagedSnapshot, workingDirectory: URL, preparedRoot: URL,
             hooks: RunnerHooks) throws -> PreparedImport {
        let fm = FileManager.default
        let dbName = AppPaths.databaseFileName

        // 1. Fresh, process-private attempt dir (brand-new — never silently reuses a planted one).
        try fm.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let attempt = workingDirectory.appendingPathComponent(".prep-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: attempt, withIntermediateDirectories: false)
        var attemptConsumed = false
        defer { if !attemptConsumed { try? fm.removeItem(at: attempt) } }   // clean on any failure

        // 2. Copy DB (+ optional WAL) THROUGH the gate's descriptor into the attempt, verifying
        //    each copied digest against the manifest.
        let preparedDB = attempt.appendingPathComponent(dbName)
        do {
            let dbDigest = try gated.root.copyRegularFile(named: dbName, to: preparedDB)
            guard dbDigest.sha256 == gated.manifest.sourceDBSHA256 else {
                throw PreparedRunFailure.snapshotCopyFailed("copied db digest != manifest.sourceDBSHA256")
            }
            if gated.hasWAL {
                let walDst = URL(fileURLWithPath: preparedDB.path + "-wal")
                let walDigest = try gated.root.copyRegularFile(named: dbName + "-wal", to: walDst)
                guard walDigest.sha256 == gated.manifest.walSHA256 else {
                    throw PreparedRunFailure.snapshotCopyFailed("copied wal digest != manifest.walSHA256")
                }
            }
        } catch let e as PreparedRunFailure { throw e }
        catch { throw PreparedRunFailure.snapshotCopyFailed("\(error)") }
        try hooks.afterCopy?(attempt)

        // 3. Normalize + migrate on the COPY (read-write-EXISTING: never CREATE, so a vanished
        //    copy fails closed instead of fabricating an empty DB).
        let migratedCount = try Self.normalizeAndMigrate(preparedDB: preparedDB, hooks: hooks)

        // 3b. Drop the rebuildable WAL sidecars SQLite may leave after the WAL→DELETE
        //     conversion (-shm in particular persists on macOS). Once journal_mode is DELETE
        //     and every connection is closed they are stale garbage; removing them mirrors
        //     DatabaseUpgrade's removeDBSet(keepMain:true) and is required so the identity is
        //     computed on a single quiescent file. Fail-closed if a removal fails.
        for suffix in ["-wal", "-shm", "-journal"] {
            let side = URL(fileURLWithPath: preparedDB.path + suffix)
            if fm.fileExists(atPath: side.path) {
                do { try fm.removeItem(at: side) }
                catch { throw PreparedRunFailure.notQuiescent("could not drop stale \(suffix): \(error)") }
            }
        }

        // 4. Single-file assertion through a bound descriptor: exactly {db}, no sidecars.
        let attemptHandle: DirectoryHandle
        do { attemptHandle = try DirectoryHandle.open(at: attempt) }
        catch { throw PreparedRunFailure.notQuiescent("attempt dir unreadable: \(error)") }
        let entries = Set(try attemptHandle.entryNames())
        guard entries == [dbName] else {
            throw PreparedRunFailure.notQuiescent("attempt dir is \(entries.sorted()), expected exactly [\(dbName)]")
        }

        // 5. Identity — AFTER every connection is closed and all sidecars are gone. compute
        //    re-asserts quiescence (no -wal/-shm/-journal, journal_mode==delete, no-follow hash).
        let identity: String
        do { identity = try PreparedDatabaseIdentity.compute(at: preparedDB) }
        catch { throw PreparedRunFailure.identityFailed("\(error)") }

        // 6. Publish atomically; idempotent same-identity reuse; NEVER overwrite a different one.
        try fm.createDirectory(at: preparedRoot, withIntermediateDirectories: true)
        let finalURL = preparedRoot.appendingPathComponent("import-\(gated.importID.rawValue).db")
        try hooks.beforePublish?(finalURL)
        let publishedURL = try Self.publish(preparedDB, to: finalURL, identity: identity, importID: gated.importID)
        attemptConsumed = true
        try? fm.removeItem(at: attempt)

        return PreparedImport(importID: gated.importID, preparedDatabaseURL: publishedURL,
                              preparedDBIdentity: identity, manifest: gated.manifest,
                              gated: gated, transactionsMigrated: migratedCount)
    }

    // MARK: - Normalize + migrate (on the private copy only)

    /// Ordered, fail-closed: wal_checkpoint(TRUNCATE) → journal_mode=DELETE → quick_check →
    /// read+gate user_version → migrate → integrity_check → foreign_key_check → required
    /// tables → user_version==head. Every connection is explicitly closed before returning,
    /// so the caller can compute the file identity on a provably-released database.
    private static func normalizeAndMigrate(preparedDB: URL, hooks: RunnerHooks) throws -> Int {
        let db: SQLiteDatabase
        do { db = try SQLiteDatabase(path: preparedDB.path, mode: .readWriteExisting) }
        catch { throw PreparedRunFailure.integrityFailed("cannot open working copy: \(error)") }

        var closed = false
        func close() throws { if !closed { try db.close(); closed = true } }
        defer { if !closed { try? db.close() } }

        do {
            // Fold committed WAL frames into the main file, then leave WAL mode so on close
            // the -wal/-shm are removed and the header becomes rollback-journal — exactly what
            // PreparedDatabaseIdentity.compute later requires.
            try db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            try db.execute("PRAGMA journal_mode = DELETE")
            guard try db.quickCheck() else { throw PreparedRunFailure.integrityFailed("quick_check != ok") }

            // Version gate AFTER checkpoint, on the now single-file image. Reject negatives
            // (corrupt/tampered) and anything newer than head — never index the ladder out of range.
            let v = try db.userVersion()
            guard v >= 0, v <= SchemaMigrator.schemaVersion else {
                throw PreparedRunFailure.unsupportedUserVersion(found: v)
            }

            try hooks.beforeMigrate?(db)
            try db.execute("PRAGMA foreign_keys = ON")
            do { try SchemaMigrator.migrate(db) }
            catch let e as SchemaMigrator.MigrationError {
                if case .newerThanSupported(let f, _) = e { throw PreparedRunFailure.unsupportedUserVersion(found: f) }
                if case .corruptVersion(let f) = e { throw PreparedRunFailure.unsupportedUserVersion(found: f) }
                throw PreparedRunFailure.migrationFailed("\(e)")
            }

            // Must have reached HEAD — do not trust the loop, assert it.
            let head = try db.userVersion()
            guard head == SchemaMigrator.schemaVersion else {
                throw PreparedRunFailure.migrationFailed("user_version is \(head) after migrate, expected \(SchemaMigrator.schemaVersion)")
            }
            guard try db.integrityCheck() else { throw PreparedRunFailure.integrityFailed("integrity_check != ok after migrate") }

            // Foreign-key integrity: PRAGMA foreign_key_check returns one row per violation.
            let fkRows = try db.query("PRAGMA foreign_key_check")
            guard fkRows.isEmpty else {
                throw PreparedRunFailure.foreignKeyViolations("\(fkRows.count) violation row(s)")
            }

            // FULL required-table completeness — the central 26-table list, not a 3-table subset.
            let present = Set(try db.query("SELECT name FROM sqlite_master WHERE type = 'table'").compactMap { $0.string("name") })
            let missing = SchemaMigrator.requiredTables.filter { !present.contains($0) }
            guard missing.isEmpty else { throw PreparedRunFailure.schemaIncomplete(missing.sorted().joined(separator: ", ")) }

            let count = try db.query("SELECT COUNT(*) AS c FROM transactions").first?.int("c") ?? 0
            try close()   // explicit, deterministic — identity is computed only after this
            return count
        } catch let e as PreparedRunFailure {
            try? close(); throw e
        } catch {
            try? close(); throw PreparedRunFailure.migrationFailed("\(error)")
        }
    }

    // MARK: - Atomic publish (idempotent, never-overwrite)

    private static func publish(_ preparedDB: URL, to finalURL: URL,
                                identity: String, importID: ImportID) throws -> URL {
        let fm = FileManager.default
        do {
            // Exclusive rename: THROWS if the destination already exists (never overwrites).
            try fm.moveItem(at: preparedDB, to: finalURL)
            return finalURL
        } catch {
            // A prepared DB for this importID already exists. NEVER overwrite: reuse iff its
            // identity is byte-identical, else refuse.
            guard (try? FileFingerprint.capture(at: finalURL)) ?? nil != nil else { throw error }
            let existing = try? PreparedDatabaseIdentity.compute(at: finalURL)
            if existing == identity { return finalURL }   // idempotent reuse
            throw PreparedRunFailure.preparedPublishConflict(
                "import-\(importID.rawValue): existing \(existing ?? "unreadable") != \(identity)")
        }
    }
}
