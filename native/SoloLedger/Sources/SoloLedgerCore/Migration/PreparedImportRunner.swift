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
    /// A runner-private work area (`.prep-*` / `.verify-*`) — or the workingDirectory path
    /// above it — no longer resolves to the handles bound at creation. Detected by the
    /// two-layer point-in-time gates around every path-trusting (SQLite/identity) step.
    case workAreaSwapped(String)

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
        case .workAreaSwapped(let m): return "A runner-private work area was swapped underneath the runner (failing closed): \(m)"
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
    /// logging / locating ONLY — NEVER a trust input: it is a path and can be redirected by a
    /// component swap at ANY moment. The runner checks, at return time, that the path resolved
    /// to the same inode as `artifactHandle` — a POINT-IN-TIME check only; nothing keeps the
    /// path bound afterwards, so no consumer may treat this URL as verified. Every
    /// security-sensitive read MUST go through `artifactHandle` (the bound inode).
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
    ///
    /// CONTRACT for the future coordinator: it must live inside SoloLedgerCore, or Core must
    /// grow descriptor-bound operations built on this handle for it to call. This property is
    /// `internal` ON PURPOSE — code outside Core (the App module) must NOT respond to that by
    /// falling back to trusting `preparedDatabaseURL`, and the raw fd is deliberately never
    /// exposed.
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
    var afterWorkAttemptCreated: ((URL) throws -> Void)? // .prep created+bound, BEFORE DB copy-in
    var afterCopy: ((URL) throws -> Void)?               // working attempt, after DB(+WAL) copied
    var beforeMigrate: ((SQLiteDatabase) throws -> Void)?
    var beforePublish: ((URL) throws -> Void)?           // final artifact URL, before validate+rename
    var afterPublish: ((URL) throws -> Void)?            // final artifact URL, AFTER the rename (crash sim)
    var afterVerifyDirCreated: ((URL) throws -> Void)?   // .verify created+bound, BEFORE verify copy-in
    var afterVerifyCopy: ((URL) throws -> Void)?         // after verify copy-in, before the VB1 gate
    init(afterWorkAttemptCreated: ((URL) throws -> Void)? = nil,
         afterCopy: ((URL) throws -> Void)? = nil,
         beforeMigrate: ((SQLiteDatabase) throws -> Void)? = nil,
         beforePublish: ((URL) throws -> Void)? = nil,
         afterPublish: ((URL) throws -> Void)? = nil,
         afterVerifyDirCreated: ((URL) throws -> Void)? = nil,
         afterVerifyCopy: ((URL) throws -> Void)? = nil) {
        self.afterWorkAttemptCreated = afterWorkAttemptCreated
        self.afterCopy = afterCopy; self.beforeMigrate = beforeMigrate
        self.beforePublish = beforePublish; self.afterPublish = afterPublish
        self.afterVerifyDirCreated = afterVerifyDirCreated; self.afterVerifyCopy = afterVerifyCopy
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
/// CREATE text need not match the Swift port's). A per-column schema contract is a REGISTERED
/// FOLLOW-UP: it requires a separate read-only analysis over real Electron v23 fixtures and a
/// compatibility matrix before any tightening decision — do not extend the gate ad hoc.
///
/// RESIDUAL (deliberately NOT called "fully" atomic): `renameatx_np` resolves its SOURCE by
/// NAME relative to the bound root, and Darwin offers no rename-by-fd nor a way to re-link a
/// directory by fd (`linkat` cannot hardlink directories), so the `fingerprint(artName) →
/// rename` step has an irreducible window in which a same-UID process could swap `artName`.
/// It is bounded on both sides — an early pre-rename fingerprint abort, and a POINT-IN-TIME
/// post-publish check (`assertPublishedIsArt`) that the published entry resolves to the bound,
/// validated artifact inode, else fail closed. That check detects a swap that has ALREADY
/// happened; it cannot exclude one after it returns (a path lookup cannot be pinned), which is
/// why the artifact is carried forward as a BOUND descriptor and the public URL stays a hint.
/// Cleanup of a failed attempt is keyed on that same bound handle (`removeBoundChildDir`) and
/// unlinks ONLY the runner's own known files — never an enumeration, so an entry the runner
/// did not create is never deleted; if one remains, the rmdir fails and the leftover is reaper
/// residue.
///
/// WORK AREAS (`.prep-*` / `.verify-*`): what IS bound to handles taken at creation is their
/// creation (mkdirat 0700 via the bound work root), the fd→fd copy-in of the DB/WAL, entry
/// enumeration, known-name deletion and cleanup. What is NOT bindable: the SQLite migration,
/// `PreparedDatabaseIdentity.compute` and the verify schema/count probes all consume the area
/// by FULL PATH (SQLite has no openat), so each of those steps is bracketed by TWO-LAYER
/// point-in-time gates (`assertWorkAreaStillBound`: workingDirectory path → bound work root,
/// child name → bound child; either mismatch ⇒ `.workAreaSwapped`). The gates only detect a
/// swap that already happened and was not restored — a root or child swap-and-restore within
/// one SQLite/identity call is undetectable, and an inode replacement at a runner-owned name
/// INSIDE the bound area remains the registered same-UID residual — so the work area is NOT
/// fully descriptor-bound and is deliberately not described as such.
///
/// THREAT-MODEL PRECONDITION (not verified by this code): `run` accepts arbitrary URLs and
/// does NOT check that `preparedRoot` / `workingDirectory` live in a process-private (0700)
/// container — placing them there is the caller's contract; the artifact attempt and the
/// work areas are created 0700 (and `workingDirectory` itself only when this call creates
/// it). Within that precondition, exploiting these gaps requires same-UID code racing
/// between adjacent syscalls — code that could already tamper with the data directly — so
/// the windows are defense-in-depth, not a privilege boundary.
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
        // 0700 applies only when this call CREATES the directory; a pre-existing
        // workingDirectory keeps its permissions (private placement stays a caller contract).
        try fm.createDirectory(at: workingDirectory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])

        // Bind preparedRoot ONCE. Every artifact op below is relative to this fd.
        let root: DirectoryHandle
        do { root = try DirectoryHandle.open(at: preparedRoot) }
        catch { throw PreparedRunFailure.publishFailed("preparedRoot unreadable / not a directory: \(error)") }

        // Bind workingDirectory ONCE. Work areas (.prep-*/.verify-*) are created, filled,
        // enumerated and cleaned relative to this fd; SQLite/identity still consume them by
        // PATH, so those steps are bracketed by two-layer gates (assertWorkAreaStillBound).
        let workRoot: DirectoryHandle
        do { workRoot = try DirectoryHandle.open(at: workingDirectory) }
        catch { throw PreparedRunFailure.snapshotCopyFailed("workingDirectory unreadable / not a directory: \(error)") }

        // FAST PATH / crash-resume.
        if let reused = try Self.reuseIfConsistent(root: root, importName: importName, gated: gated,
                                                   preparedRoot: preparedRoot, workRoot: workRoot,
                                                   workingDirectory: workingDirectory, hooks: hooks) {
            return reused
        }

        // 1. Private working attempt: created AND BOUND via the work-root fd (mkdirat 0700 +
        //    first-observed bind). The URL below is for SQLite/identity/hooks ONLY — every
        //    create/enumerate/unlink goes through the bound handles.
        let prepName = ".prep-\(UUID().uuidString)"
        let attempt: DirectoryHandle
        do { attempt = try workRoot.makeChildDirectory(named: prepName) }
        catch { throw PreparedRunFailure.snapshotCopyFailed("working attempt create: \(error)") }
        let workAttempt = workingDirectory.appendingPathComponent(prepName, isDirectory: true)
        var workDone = false
        // Cleanup keyed on the BOUND handles and limited to the runner's OWN file names —
        // never re-resolving, never enumerating; unknowns are reaper residue.
        defer { if !workDone { workRoot.removeBoundChildDir(attempt, named: prepName, knownEntries: Self.workOwnedEntries(dbName)) } }
        try hooks.afterWorkAttemptCreated?(workAttempt)

        // Copy DB (+WAL) fd→fd: source through the gate descriptor, DESTINATION through the
        // bound attempt descriptor (openat O_CREAT|O_EXCL|O_NOFOLLOW) — a swap of the attempt
        // entry or the workingDirectory path cannot redirect where the bytes land.
        let workDB = workAttempt.appendingPathComponent(dbName)
        do {
            let src = try gated.root.openRegularFile(named: dbName)
            defer { try? src.close() }
            let dbDigest = try attempt.importRegularFile(named: dbName, from: src)
            guard dbDigest.sha256 == gated.manifest.sourceDBSHA256 else {
                throw PreparedRunFailure.snapshotCopyFailed("copied db digest != manifest.sourceDBSHA256")
            }
            if gated.hasWAL {
                let walSrc = try gated.root.openRegularFile(named: dbName + "-wal")
                defer { try? walSrc.close() }
                let walDigest = try attempt.importRegularFile(named: dbName + "-wal", from: walSrc)
                guard walDigest.sha256 == gated.manifest.walSHA256 else {
                    throw PreparedRunFailure.snapshotCopyFailed("copied wal digest != manifest.walSHA256")
                }
            }
        } catch let e as PreparedRunFailure { throw e }
        catch { throw PreparedRunFailure.snapshotCopyFailed("\(error)") }
        try hooks.afterCopy?(workAttempt)

        // B1 — LAST gate before SQLite opens by path: both layers (workingDirectory path →
        // bound workRoot; prepName → bound attempt) must hold, or an impostor DB planted
        // under a swapped name/root would be OPENED AND MIGRATED (modified) by SQLite.
        try Self.assertWorkAreaStillBound(root: workRoot, rootPath: workingDirectory, childName: prepName, child: attempt)
        let migratedCount = try Self.normalizeAndMigrate(preparedDB: workDB, hooks: hooks)
        // B2 — the migration output is only trusted if the area never observably drifted.
        try Self.assertWorkAreaStillBound(root: workRoot, rootPath: workingDirectory, childName: prepName, child: attempt)
        try Self.dropSidecars(in: attempt, dbName: dbName)
        try Self.assertSingleFile(attempt, dbName: dbName)
        // B3/B4 — bracket the path-based identity computation.
        try Self.assertWorkAreaStillBound(root: workRoot, rootPath: workingDirectory, childName: prepName, child: attempt)
        let identity: String
        do { identity = try PreparedDatabaseIdentity.compute(at: workDB) }
        catch { throw PreparedRunFailure.identityFailed("\(error)") }
        try Self.assertWorkAreaStillBound(root: workRoot, rootPath: workingDirectory, childName: prepName, child: attempt)

        // 2. Build the artifact attempt as a CHILD of the bound root (same volume, fd-relative).
        let artName = ".artifact-\(UUID().uuidString)"
        let art: DirectoryHandle
        do { art = try root.makeChildDirectory(named: artName) }
        catch { throw PreparedRunFailure.publishFailed("artifact attempt create: \(error)") }
        var artPublished = false
        // Cleanup keyed on the BOUND `art` handle and limited to the runner's OWN files: never
        // re-resolving `artName` (which could bind a swapped-in replacement) and never
        // enumerating — an entry the runner did not create is never deleted; if one is present
        // the rmdir fails and the attempt is left as reaper residue. See removeBoundChildDir.
        defer { if !artPublished { root.removeBoundChildDir(art, named: artName, knownEntries: [dbName, "provenance.json"]) } }

        do {
            // Source read through the BOUND attempt handle — no path re-resolution.
            let src = try attempt.openRegularFile(named: dbName)
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
                                                  expectedCount: migratedCount, workRoot: workRoot,
                                                  workingDirectory: workingDirectory, hooks: hooks)

        // 4. Re-verify the bindings, then publish via the bound root fd. NOTE: renameatx_np
        //    resolves its SOURCE by NAME (`artName`) relative to root — Darwin has no
        //    rename-by-fd, and a directory cannot be re-linked by fd (linkat), so the
        //    fingerprint→rename step is NOT atomic: a same-UID racer could swap `artName` in
        //    that sub-microsecond gap. The pre-rename fingerprint is an early abort for swaps
        //    that ALREADY happened; the decisive gate on the publish OUTCOME is the
        //    point-in-time POST-rename check below — the published entry must resolve to the
        //    bound, validated artifact inode, else we fail closed. See the type doc for the
        //    registered residual window.
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
            workRoot.removeBoundChildDir(attempt, named: prepName, knownEntries: Self.workOwnedEntries(dbName))
            // Point-in-time post-publish verification (blockers B/D): the published entry MUST
            // — at this instant — be the very inode we built and validated, and the root path
            // MUST still be the bound root; else a source-name swap won the rename window and
            // we fail closed.
            try Self.assertPublishedIsArt(root: root, importName: importName, art: art, preparedRoot: preparedRoot)
            try hooks.afterPublish?(finalURL)                      // crash-simulation window
            // Re-check AFTER the crash-sim window so a swap performed IN that window is
            // detected and fails closed. This does not pin the path — after this check the URL
            // is still only a hint; consumers must use `artifactHandle`.
            try Self.assertPublishedIsArt(root: root, importName: importName, art: art, preparedRoot: preparedRoot)
            return PreparedImport(importID: gated.importID, preparedDatabaseURL: finalURL.appendingPathComponent(dbName),
                                  preparedDBIdentity: validated.preparedDBIdentity, manifest: gated.manifest, gated: gated,
                                  transactionsMigrated: validated.transactionsMigrated, reusedExisting: false, artifactHandle: art)
        }
        // Destination appeared between the fast-path check and the rename (publish race).
        if let reused = try Self.reuseIfConsistent(root: root, importName: importName, gated: gated,
                                                   preparedRoot: preparedRoot, workRoot: workRoot,
                                                   workingDirectory: workingDirectory, hooks: hooks) {
            return reused
        }
        throw PreparedRunFailure.preparedPublishConflict("import-\(gated.importID.rawValue): a different artifact won the publish race")
    }

    // MARK: - Crash-resume (fully descriptor-bound)

    /// nil ⇔ no artifact exists yet. A present artifact is validated ENTIRELY through a bound
    /// descriptor (openat from `root`): provenance, DB identity, transaction count all come from
    /// a copy taken THROUGH that descriptor. Consistent ⇒ reuse; else ⇒ hard conflict.
    static func reuseIfConsistent(root: DirectoryHandle, importName: String, gated: GatedStagedSnapshot,
                                  preparedRoot: URL, workRoot: DirectoryHandle, workingDirectory: URL,
                                  hooks: RunnerHooks) throws -> PreparedImport? {
        guard let fp = try root.fingerprint(named: importName) else { return nil }   // ENOENT ⇒ not published yet
        func conflict(_ m: String) -> PreparedRunFailure { .preparedPublishConflict("import-\(gated.importID.rawValue): \(m)") }
        guard fp.isDirectory else { throw conflict("existing artifact is not a directory") }

        let art: DirectoryHandle
        do { art = try root.subdirectory(named: importName) }   // openat O_NOFOLLOW|O_DIRECTORY, bound
        catch { throw conflict("existing artifact unreadable: \(error)") }

        let validated = try validateArtifact(art, gated: gated, expectedIdentity: nil, expectedCount: nil,
                                             workRoot: workRoot, workingDirectory: workingDirectory, hooks: hooks)
        // Validation ran entirely through `art`'s fd; the PUBLIC URL, however, is rebuilt from
        // the path. Before handing it back, confirm — at this instant — that the root path
        // still binds to `root` AND `importName` still resolves to the very inode we validated,
        // catching a URL that ALREADY points at a different object than `artifactHandle`. The
        // check cannot pin the path afterwards: the URL stays an untrusted hint and
        // security-sensitive reads must use `artifactHandle`.
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
                                 workRoot: DirectoryHandle, workingDirectory: URL,
                                 hooks: RunnerHooks) throws -> ValidatedArtifact {
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

        // Copy the DB OUT fd→fd into a private verify area: created AND BOUND via the
        // work-root fd (mkdirat 0700 + first-observed bind), destination created through the
        // bound verify descriptor (openat O_CREAT|O_EXCL|O_NOFOLLOW). The URL is for the
        // path-based SQLite/identity probes and hooks ONLY.
        let verifyName = ".verify-\(UUID().uuidString)"
        let verify: DirectoryHandle
        do { verify = try workRoot.makeChildDirectory(named: verifyName) }
        catch { throw conflict("verify dir: \(error)") }
        let verifyDir = workingDirectory.appendingPathComponent(verifyName, isDirectory: true)
        defer { workRoot.removeBoundChildDir(verify, named: verifyName, knownEntries: workOwnedEntries(dbName)) }
        try hooks.afterVerifyDirCreated?(verifyDir)
        let verifyDB = verifyDir.appendingPathComponent(dbName)
        do {
            let src = try art.openRegularFile(named: dbName)
            defer { try? src.close() }
            _ = try verify.importRegularFile(named: dbName, from: src)
        } catch { throw conflict("prepared DB copy-for-verification failed (symlink/FIFO/read error): \(error)") }
        try hooks.afterVerifyCopy?(verifyDir)

        // VB1 — LAST gate before the path-based identity probe: both layers must hold, or a
        // planted verify area (even one holding a FULLY VALID DB) would be what gets verified.
        try assertWorkAreaStillBound(root: workRoot, rootPath: workingDirectory, childName: verifyName, child: verify)
        let identity: String
        do { identity = try PreparedDatabaseIdentity.compute(at: verifyDB) }
        catch { throw conflict("prepared DB identity unreadable: \(error)") }
        // VB2 — the identity result is only trusted if the area never observably drifted.
        try assertWorkAreaStillBound(root: workRoot, rootPath: workingDirectory, childName: verifyName, child: verify)
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
        // required so legitimate Electron-authored v23 imports are not false-rejected. A
        // per-column contract is a registered follow-up gated on a separate read-only analysis
        // with real Electron v23 fixtures — do not tighten here. Every check runs on the
        // private verify copy taken no-follow THROUGH the bound artifact fd.
        // VB3 — LAST gate before the path-based schema/count probe opens SQLite.
        try assertWorkAreaStillBound(root: workRoot, rootPath: workingDirectory, childName: verifyName, child: verify)
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
        // VB4 — schema/count results are only trusted if the area never observably drifted
        // (the read-only connection is closed by the do-block's defer before this check).
        try assertWorkAreaStillBound(root: workRoot, rootPath: workingDirectory, childName: verifyName, child: verify)
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

    /// Every entry name the runner (or SQLite acting on its behalf) may create inside a
    /// runner-private work area — the ONLY names cleanup and sidecar-dropping may unlink.
    private static func workOwnedEntries(_ dbName: String) -> [String] {
        [dbName, dbName + "-wal", dbName + "-shm", dbName + "-journal"]
    }

    /// Drop rebuildable SQLite sidecars from the BOUND attempt — fd-relative and
    /// non-recursive by construction (`removeNonDirectoryChild`): a DIRECTORY planted at a
    /// sidecar name fails closed and its contents are structurally untouchable.
    private static func dropSidecars(in attempt: DirectoryHandle, dbName: String) throws {
        for suffix in ["-wal", "-shm", "-journal"] {
            do { try attempt.removeNonDirectoryChild(named: dbName + suffix) }
            catch { throw PreparedRunFailure.notQuiescent("could not drop stale \(suffix): \(error)") }
        }
    }

    /// Entry-set check on the BOUND attempt handle — no path re-open, no re-resolution.
    private static func assertSingleFile(_ attempt: DirectoryHandle, dbName: String) throws {
        let entries = Set(try attempt.entryNames())
        guard entries == [dbName] else {
            throw PreparedRunFailure.notQuiescent("attempt dir is \(entries.sorted()), expected exactly [\(dbName)]")
        }
    }

    /// TWO-LAYER point-in-time gate on a runner-private work area (`.prep-*` / `.verify-*`).
    /// BOTH layers are required because SQLite/identity consume the area by FULL PATH:
    ///  1. the workingDirectory PATH must still resolve (lstat, no-follow) to the bound work
    ///     root (device+inode) — a swap of the WHOLE workingDirectory would otherwise leave
    ///     the child-relative check passing inside the OLD root while `workDB.path` /
    ///     `verifyDB.path` traverse the REPLACEMENT root;
    ///  2. `childName` under the bound work-root fd must still resolve to the bound child
    ///     directory (device+inode).
    /// Either failure throws `.workAreaSwapped`. POINT-IN-TIME only: it detects a swap that
    /// has already happened and was not restored; a swap-and-restore within one SQLite /
    /// identity call is undetectable (registered residual — see the type doc).
    private static func assertWorkAreaStillBound(root: DirectoryHandle, rootPath: URL,
                                                 childName: String, child: DirectoryHandle) throws {
        guard let rfp = try FileFingerprint.capture(at: rootPath), rfp.isDirectory,
              rfp.device == root.device, rfp.inode == root.inode else {
            throw PreparedRunFailure.workAreaSwapped("workingDirectory path no longer resolves to the bound work root")
        }
        guard let cfp = try root.fingerprint(named: childName), cfp.isDirectory,
              cfp.device == child.device, cfp.inode == child.inode else {
            throw PreparedRunFailure.workAreaSwapped("\(childName) no longer resolves to the bound work-area directory")
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

    /// POINT-IN-TIME post-publish / pre-return check: `importName` under the bound `root` must
    /// resolve (device+inode) to the artifact handle we built and validated, AND the root PATH
    /// must still be the bound root. It verifies the publish OUTCOME against the bound handle —
    /// a swap that ALREADY happened (the rename's source-name window, or a tamper inside a test
    /// hook window) fails closed instead of being returned as ours. It does NOT — and on a
    /// path-based filesystem cannot — guarantee the path stays bound after it returns; the URL
    /// remains an untrusted hint and consumers must use `artifactHandle`.
    private static func assertPublishedIsArt(root: DirectoryHandle, importName: String,
                                             art: DirectoryHandle, preparedRoot: URL) throws {
        try assertStillBound(root, path: preparedRoot)
        guard let fp = try root.fingerprint(named: importName), fp.isDirectory,
              fp.device == art.device, fp.inode == art.inode else {
            throw PreparedRunFailure.publishFailed("published artifact entry is not the validated artifact (swapped in the publish window)")
        }
    }
}
