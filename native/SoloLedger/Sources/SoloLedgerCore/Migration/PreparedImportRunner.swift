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
/// on the SNAPSHOT identity + the recorded prepared identity + the actual transaction count,
/// not on prepared-byte equality. Its own `formatVersion` is independent of
/// `ImportManifest.currentFormatVersion`.
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

/// Result of a full descriptor-rooted artifact validation.
struct ValidatedArtifact {
    let preparedDBIdentity: String     // recomputed from a copy taken THROUGH the artifact fd
    let transactionsMigrated: Int      // counted from that same copy
    let provenance: PreparedProvenance
}

/// A normalized, migrated, QUIESCENT single-file prepared database + its computed identity,
/// published as an atomic artifact directory. Carries the gate evidence AND the bound artifact
/// descriptor forward so the coordinator can act on the SAME verified objects. Internal init.
public struct PreparedImport {
    public let importID: ImportID
    /// LOCATION HINT for the prepared DB inside the published artifact
    /// (`preparedRoot/import-<id>/sololedger.db`), DELETE-journal, no sidecars. For display /
    /// logging / locating ONLY — NEVER a trust input: it is a path and could be redirected by a
    /// component swap. Every security-sensitive read MUST go through `artifactHandle` (the
    /// bound inode). The runner only returns this URL after confirming it still resolves to the
    /// same inode as `artifactHandle`.
    public let preparedDatabaseURL: URL
    public let preparedDBIdentity: String
    public let manifest: ImportManifest
    public let gated: GatedStagedSnapshot
    public let transactionsMigrated: Int
    /// True when this run RESUMED an already-published artifact rather than migrating afresh.
    public let reusedExisting: Bool
    /// The bound (O_NOFOLLOW|O_DIRECTORY, dev+inode) descriptor for the published artifact dir.
    /// Survives the publish rename (an fd tracks the inode, not the name), so the coordinator
    /// can read the prepared DB / provenance through it without re-resolving the path.
    let artifactHandle: DirectoryHandle

    init(importID: ImportID, preparedDatabaseURL: URL, preparedDBIdentity: String,
         manifest: ImportManifest, gated: GatedStagedSnapshot, transactionsMigrated: Int,
         reusedExisting: Bool, artifactHandle: DirectoryHandle) {
        self.importID = importID
        self.preparedDatabaseURL = preparedDatabaseURL
        self.preparedDBIdentity = preparedDBIdentity
        self.manifest = manifest
        self.gated = gated
        self.transactionsMigrated = transactionsMigrated
        self.reusedExisting = reusedExisting
        self.artifactHandle = artifactHandle
    }
}

/// Test-only fault seams (internal, no-op by default).
struct RunnerHooks {
    var afterCopy: ((URL) throws -> Void)?               // working attempt, after DB(+WAL) copied
    var beforeMigrate: ((SQLiteDatabase) throws -> Void)?
    var beforePublish: ((URL) throws -> Void)?           // final artifact URL, before validate+rename
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
/// published as an ATOMIC ARTIFACT DIRECTORY (`preparedRoot/import-<id>/` = exactly
/// `sololedger.db` + `provenance.json`).
///
/// The `preparedRoot` is bound to ONE descriptor at the start of `run`, and every artifact
/// operation — create, write, validate, clean, and the exclusive `renameatx_np(RENAME_EXCL)`
/// publish — is relative to THAT fd, so a swap of the `preparedRoot` path cannot redirect the
/// publish. The staged original is never opened by SQLite; the DB (+ WAL) are copied through
/// the gate's descriptor into a private working copy, migrated there, then copied through the
/// bound descriptors into the artifact. The final integrity gate runs AFTER the adversary
/// `beforePublish` window and re-verifies everything through the bound artifact descriptor —
/// including a SCHEMA GATE (user_version == head, every `SchemaMigrator.requiredTables` NAME
/// present, integrity_check ok, foreign_key_check empty) checked against the `SchemaMigrator`
/// constants, which attacker-writable provenance cannot forge. The gate proves table-NAME
/// presence, NOT full per-column DDL: a same-UID racer could substitute a DB with the right
/// table names but wrong columns — that is left in the registered same-UID residual below
/// (verifying byte-exact DDL would false-reject legitimate Electron-authored v23 imports, whose
/// CREATE text need not match the Swift port's).
///
/// RESIDUAL (deliberately NOT called "fully" atomic): `renameatx_np` resolves its SOURCE by
/// NAME relative to the bound root, and Darwin offers no rename-by-fd nor a way to re-link a
/// directory by fd (`linkat` cannot hardlink directories), so the `fingerprint(artName) →
/// rename` step has an irreducible window in which a same-UID process could swap `artName`.
/// It is bounded on both sides — an early pre-rename fingerprint abort, and an AUTHORITATIVE
/// post-publish check (`assertPublishedIsArt`) that the published entry resolves to the bound,
/// validated artifact inode, else fail closed — and the artifact is carried forward as a BOUND
/// descriptor so a coordinator never re-trusts the path. Cleanup of a failed attempt is keyed
/// on that same bound handle (`removeBoundChildDir`), never on the re-resolved name, so a
/// planted same-named replacement is never enumerated or deleted. Exploiting the rename gap
/// requires code running as the SAME user inside the process-private 0700 container racing
/// between two adjacent syscalls; such an attacker can already tamper with the data directly,
/// so this window is defense-in-depth, not a privilege boundary.
public struct PreparedImportRunner {
    public init() {}

    public func run(_ gated: GatedStagedSnapshot, workingDirectory: URL, preparedRoot: URL) throws -> PreparedImport {
        try run(gated, workingDirectory: workingDirectory, preparedRoot: preparedRoot, hooks: RunnerHooks())
    }

    func run(_ gated: GatedStagedSnapshot, workingDirectory: URL, preparedRoot: URL,
             hooks: RunnerHooks) throws -> PreparedImport {
        let fm = FileManager.default
        let dbName = AppPaths.databaseFileName
        let importName = "import-\(gated.importID.rawValue)"
        try fm.createDirectory(at: preparedRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: workingDirectory, withIntermediateDirectories: true)

        // Bind preparedRoot ONCE. Every artifact op below is relative to this fd.
        let root: DirectoryHandle
        do { root = try DirectoryHandle.open(at: preparedRoot) }
        catch { throw PreparedRunFailure.publishFailed("preparedRoot unreadable / not a directory: \(error)") }

        // FAST PATH / crash-resume.
        if let reused = try Self.reuseIfConsistent(root: root, importName: importName, gated: gated,
                                                   preparedRoot: preparedRoot, workingDirectory: workingDirectory) {
            return reused
        }

        // 1. Private working attempt: copy DB(+WAL) through the gate descriptor, migrate.
        let workAttempt = workingDirectory.appendingPathComponent(".prep-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: workAttempt, withIntermediateDirectories: false)
        var workDone = false
        defer { if !workDone { try? fm.removeItem(at: workAttempt) } }

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

        let migratedCount = try Self.normalizeAndMigrate(preparedDB: workDB, hooks: hooks)
        try Self.dropSidecars(besides: workDB)
        try Self.assertSingleFile(workAttempt, dbName: dbName)
        let identity: String
        do { identity = try PreparedDatabaseIdentity.compute(at: workDB) }
        catch { throw PreparedRunFailure.identityFailed("\(error)") }

        // 2. Build the artifact attempt as a CHILD of the bound root (same volume, fd-relative).
        let artName = ".artifact-\(UUID().uuidString)"
        let art: DirectoryHandle
        do { art = try root.makeChildDirectory(named: artName) }
        catch { throw PreparedRunFailure.publishFailed("artifact attempt create: \(error)") }
        var artPublished = false
        // Cleanup keyed on the BOUND `art` handle, never re-resolving `artName` (which could
        // bind a swapped-in replacement). See DirectoryHandle.removeBoundChildDir.
        defer { if !artPublished { root.removeBoundChildDir(art, named: artName) } }

        do {
            let workHandle = try DirectoryHandle.open(at: workAttempt)
            let src = try workHandle.openRegularFile(named: dbName)
            defer { try? src.close() }
            _ = try art.importRegularFile(named: dbName, from: src)
        } catch { throw PreparedRunFailure.publishFailed("artifact db import: \(error)") }

        let provenance = PreparedProvenance(
            formatVersion: PreparedProvenance.currentFormatVersion, importID: gated.importID.rawValue,
            snapshotIdentitySHA256: gated.manifest.snapshotIdentitySHA256,
            attachmentManifestSHA256: gated.manifest.attachmentManifestSHA256,
            sourceDBSHA256: gated.manifest.sourceDBSHA256, walSHA256: gated.manifest.walSHA256,
            preparedDBIdentity: identity, transactionsMigrated: migratedCount)
        do {
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try art.createRegularFileExclusively(named: "provenance.json", contents: try enc.encode(provenance))
        } catch { throw PreparedRunFailure.publishFailed("provenance write: \(error)") }

        // 3. Adversary window, THEN the FINAL integrity gate (descriptor-rooted re-verify of the
        //    artifact we are about to publish — entry set, types, provenance, DB identity, count).
        let finalURL = preparedRoot.appendingPathComponent(importName, isDirectory: true)
        try hooks.beforePublish?(finalURL)
        let validated = try Self.validateArtifact(art, gated: gated, expectedIdentity: identity,
                                                  expectedCount: migratedCount, workingDirectory: workingDirectory)

        // 4. Re-verify the bindings, then publish via the bound root fd. NOTE: renameatx_np
        //    resolves its SOURCE by NAME (`artName`) relative to root — Darwin has no
        //    rename-by-fd, and a directory cannot be re-linked by fd (linkat), so the
        //    fingerprint→rename step is NOT atomic: a same-UID racer could swap `artName` in
        //    that sub-microsecond gap. The pre-rename fingerprint is an early abort for swaps
        //    that ALREADY happened; the AUTHORITATIVE guard is the POST-rename check below —
        //    the published entry must resolve to the bound, validated artifact inode, else we
        //    fail closed. See the type doc for the registered residual window.
        try Self.assertStillBound(root, path: preparedRoot)
        guard let artFP = try root.fingerprint(named: artName), artFP.isDirectory,
              artFP.device == art.device, artFP.inode == art.inode else {
            throw PreparedRunFailure.publishFailed("artifact attempt entry changed before publish")
        }
        let published: Bool
        do { published = try root.renameChildExclusively(from: artName, to: importName) }
        catch { throw PreparedRunFailure.publishFailed("exclusive rename: \(error)") }

        if published {
            artPublished = true; workDone = true
            try? fm.removeItem(at: workAttempt)
            // Authoritative post-publish verification (blockers B/D): the published entry MUST
            // be the very inode we built and validated, and the root path MUST still be the
            // bound root — else a source-name swap won the rename window; fail closed.
            try Self.assertPublishedIsArt(root: root, importName: importName, art: art, preparedRoot: preparedRoot)
            try hooks.afterPublish?(finalURL)                      // crash-simulation window
            // Re-verify AFTER the crash-sim window too, so a swap there can never let us return
            // a PreparedImport whose public URL points at a different object than `art`.
            try Self.assertPublishedIsArt(root: root, importName: importName, art: art, preparedRoot: preparedRoot)
            return PreparedImport(importID: gated.importID, preparedDatabaseURL: finalURL.appendingPathComponent(dbName),
                                  preparedDBIdentity: validated.preparedDBIdentity, manifest: gated.manifest, gated: gated,
                                  transactionsMigrated: validated.transactionsMigrated, reusedExisting: false, artifactHandle: art)
        }
        // Destination appeared between the fast-path check and the rename (publish race).
        if let reused = try Self.reuseIfConsistent(root: root, importName: importName, gated: gated,
                                                   preparedRoot: preparedRoot, workingDirectory: workingDirectory) {
            return reused
        }
        throw PreparedRunFailure.preparedPublishConflict("import-\(gated.importID.rawValue): a different artifact won the publish race")
    }

    // MARK: - Crash-resume (fully descriptor-bound)

    /// nil ⇔ no artifact exists yet. A present artifact is validated ENTIRELY through a bound
    /// descriptor (openat from `root`): provenance, DB identity, transaction count all come from
    /// a copy taken THROUGH that descriptor. Consistent ⇒ reuse; else ⇒ hard conflict.
    static func reuseIfConsistent(root: DirectoryHandle, importName: String, gated: GatedStagedSnapshot,
                                  preparedRoot: URL, workingDirectory: URL) throws -> PreparedImport? {
        guard let fp = try root.fingerprint(named: importName) else { return nil }   // ENOENT ⇒ not published yet
        func conflict(_ m: String) -> PreparedRunFailure { .preparedPublishConflict("import-\(gated.importID.rawValue): \(m)") }
        guard fp.isDirectory else { throw conflict("existing artifact is not a directory") }

        let art: DirectoryHandle
        do { art = try root.subdirectory(named: importName) }   // openat O_NOFOLLOW|O_DIRECTORY, bound
        catch { throw conflict("existing artifact unreadable: \(error)") }

        let validated = try validateArtifact(art, gated: gated, expectedIdentity: nil, expectedCount: nil,
                                             workingDirectory: workingDirectory)
        // Validation ran entirely through `art`'s fd; the PUBLIC URL, however, is rebuilt from
        // the path. Before handing it back, confirm the root path still binds to `root` AND
        // `importName` still resolves to the very inode we validated — so the returned URL
        // cannot point at object B while `artifactHandle` is object A. (Security-sensitive
        // reads must still use `artifactHandle`; the URL is a location hint only.)
        try assertPublishedIsArt(root: root, importName: importName, art: art, preparedRoot: preparedRoot)
        let dbURL = preparedRoot.appendingPathComponent(importName, isDirectory: true).appendingPathComponent(AppPaths.databaseFileName)
        return PreparedImport(importID: gated.importID, preparedDatabaseURL: dbURL,
                              preparedDBIdentity: validated.preparedDBIdentity, manifest: gated.manifest, gated: gated,
                              transactionsMigrated: validated.transactionsMigrated, reusedExisting: true, artifactHandle: art)
    }

    /// Descriptor-rooted validation of an artifact directory (`art`): exact entry set + types,
    /// provenance fields bound to `gated`, and — since SQLite is path-based — the DB is copied
    /// THROUGH `art` (no-follow) into a private verify dir where its identity and transaction
    /// count are computed. Everything is bound to `art`'s fd; nothing re-resolves the artifact
    /// path. `expected*` are supplied on the publish side (must also equal the freshly-migrated
    /// values). Any mismatch throws `preparedPublishConflict`.
    static func validateArtifact(_ art: DirectoryHandle, gated: GatedStagedSnapshot,
                                 expectedIdentity: String?, expectedCount: Int?,
                                 workingDirectory: URL) throws -> ValidatedArtifact {
        func conflict(_ m: String) -> PreparedRunFailure { .preparedPublishConflict("import-\(gated.importID.rawValue): \(m)") }
        let dbName = AppPaths.databaseFileName

        guard let entries = try? art.entryNames(), Set(entries) == [dbName, "provenance.json"] else {
            throw conflict("artifact entry set is not exactly {\(dbName), provenance.json}")
        }
        guard let dbFP = try? art.fingerprint(named: dbName), dbFP.isRegularFile,
              let pFP = try? art.fingerprint(named: "provenance.json"), pFP.isRegularFile else {
            throw conflict("artifact entries are not both regular files")
        }
        guard let pdata = try? art.readRegularFile(named: "provenance.json"),
              let prov = try? JSONDecoder().decode(PreparedProvenance.self, from: pdata) else {
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

        // Copy the DB OUT through the bound descriptor (no-follow) into a private verify dir.
        let verifyDir = workingDirectory.appendingPathComponent(".verify-\(UUID().uuidString)", isDirectory: true)
        do { try FileManager.default.createDirectory(at: verifyDir, withIntermediateDirectories: false) }
        catch { throw conflict("verify dir: \(error)") }
        defer { try? FileManager.default.removeItem(at: verifyDir) }
        let verifyDB = verifyDir.appendingPathComponent(dbName)
        do { _ = try art.copyRegularFile(named: dbName, to: verifyDB) }
        catch { throw conflict("prepared DB copy-for-verification failed (symlink/FIFO/read error): \(error)") }

        let identity: String
        do { identity = try PreparedDatabaseIdentity.compute(at: verifyDB) }
        catch { throw conflict("prepared DB identity unreadable: \(error)") }
        guard identity == prov.preparedDBIdentity else { throw conflict("prepared DB identity != provenance") }
        if let e = expectedIdentity, identity != e { throw conflict("prepared DB identity != freshly-migrated identity") }

        // SCHEMA GATE — verified against the SchemaMigrator constants (an EXTERNAL invariant),
        // NOT against attacker-writable provenance. A coordinated tamper that swaps in a
        // valid-but-wrong-schema DB and rewrites provenance identity + count to match it still
        // fails these head-schema invariants: user_version == head, every requiredTables NAME
        // present, integrity_check ok, foreign_key_check empty. (Quiescence / DELETE journal
        // mode is already enforced by PreparedDatabaseIdentity.compute above.) This proves table
        // PRESENCE, not per-column DDL — a right-names/wrong-columns substitution is the
        // registered same-UID residual (see the type doc); byte-exact DDL is deliberately NOT
        // required so legitimate Electron-authored v23 imports are not false-rejected. Every
        // check runs on the private verify copy taken no-follow THROUGH the bound artifact fd.
        let count: Int
        do {
            let db = try SQLiteDatabase(path: verifyDB.path, mode: .readOnly)
            defer { try? db.close() }
            let uv = try db.userVersion()
            guard uv == SchemaMigrator.schemaVersion else {
                throw conflict("prepared DB user_version \(uv) != head \(SchemaMigrator.schemaVersion)")
            }
            guard try db.integrityCheck() else { throw conflict("prepared DB failed integrity_check") }
            let fkRows = try db.query("PRAGMA foreign_key_check")
            guard fkRows.isEmpty else { throw conflict("prepared DB has \(fkRows.count) foreign-key violation row(s)") }
            let present = Set(try db.query("SELECT name FROM sqlite_master WHERE type = 'table'").compactMap { $0.string("name") })
            let missing = SchemaMigrator.requiredTables.filter { !present.contains($0) }
            guard missing.isEmpty else { throw conflict("prepared DB missing required tables: \(missing.sorted().joined(separator: ", "))") }
            count = try db.query("SELECT COUNT(*) AS c FROM transactions").first?.int("c") ?? -1
        } catch let e as PreparedRunFailure { throw e }
        catch { throw conflict("prepared DB schema/verify unreadable: \(error)") }
        guard count == prov.transactionsMigrated else {
            throw conflict("actual transaction count \(count) != provenance \(prov.transactionsMigrated)")
        }
        if let e = expectedCount, count != e { throw conflict("transaction count != freshly-migrated count") }

        return ValidatedArtifact(preparedDBIdentity: identity, transactionsMigrated: count, provenance: prov)
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

    /// The `preparedRoot` PATH must still refer to the very directory `root` is bound to — same
    /// device+inode, a real directory (not a symlink or a substituted tree). Guards against a
    /// root-path swap between binding and publish.
    private static func assertStillBound(_ root: DirectoryHandle, path: URL) throws {
        guard let fp = try FileFingerprint.capture(at: path), fp.isDirectory,
              fp.device == root.device, fp.inode == root.inode else {
            throw PreparedRunFailure.publishFailed("preparedRoot path no longer refers to the bound directory (swapped)")
        }
    }

    /// Authoritative post-publish / pre-return check: `importName` under the bound `root` MUST
    /// resolve (device+inode) to the artifact handle we built and validated, AND the root PATH
    /// must still be the bound root. This is what closes out the publish rename's non-atomic
    /// source-name window and any post-publish swap: it verifies the ACTUAL OUTCOME against the
    /// bound handle rather than re-checking a name before an action, so a swapped-in impostor
    /// (or a redirected root path) fails closed instead of being returned as ours.
    private static func assertPublishedIsArt(root: DirectoryHandle, importName: String,
                                             art: DirectoryHandle, preparedRoot: URL) throws {
        try assertStillBound(root, path: preparedRoot)
        guard let fp = try root.fingerprint(named: importName), fp.isDirectory,
              fp.device == art.device, fp.inode == art.inode else {
            throw PreparedRunFailure.publishFailed("published artifact entry is not the validated artifact (swapped in the publish window)")
        }
    }
}
