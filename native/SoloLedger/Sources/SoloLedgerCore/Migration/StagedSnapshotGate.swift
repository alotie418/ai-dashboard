import Foundation

// MARK: - Staged-snapshot gate errors

public enum StagedSnapshotError: Error, CustomStringConvertible, Equatable {
    case stagingUnreadable(String)
    case manifestUnreadable(String)
    case unsupportedManifestFormat(Int?)
    case notIngested(String)
    case nonCanonicalManifest(String)
    case invalidImportID(String)
    case importIDMismatch(dir: String, manifest: String)
    case rootEntrySetMismatch(String)
    case attachmentTreeMismatch(String)
    case snapshotContentInconsistent(String)
    case attachmentManifestHashMismatch

    public var description: String {
        switch self {
        case .stagingUnreadable(let m): return "Published staging dir is unreadable / not a real directory: \(m)"
        case .manifestUnreadable(let m): return "Staged manifest is unreadable or undecodable: \(m)"
        case .unsupportedManifestFormat(let v): return "Unsupported manifest formatVersion \(v.map(String.init) ?? "nil") — refusing to consume"
        case .notIngested(let m): return "Staged manifest is not in the .ingested state (\(m)) — refusing to consume"
        case .nonCanonicalManifest(let m): return "Staged manifest is not a canonical .ingested manifest: \(m)"
        case .invalidImportID(let s): return "Manifest importID is not a valid ImportID: \(s)"
        case let .importIDMismatch(dir, manifest): return "Staging dir name '\(dir)' does not match the manifest importID '\(manifest)'"
        case .rootEntrySetMismatch(let m): return "Staging root entry set does not match the manifest: \(m)"
        case .attachmentTreeMismatch(let m): return "Staged attachments tree does not match the manifest: \(m)"
        case .snapshotContentInconsistent(let m): return "Staged bytes do not match the manifest: \(m)"
        case .attachmentManifestHashMismatch: return "Recomputed attachmentSetHash does not match the manifest"
        }
    }
}

// MARK: - Gate evidence (reference semantics — keeps the descriptor alive)

/// Evidence that a PUBLISHED staging dir passed the descriptor-rooted staged-snapshot gate.
///
/// REFERENCE TYPE ON PURPOSE: it owns the `DirectoryHandle` whose O_NOFOLLOW|O_DIRECTORY,
/// device+inode-bound fd is the trust anchor for everything downstream. The runner reads the
/// staged DB/WAL THROUGH this same descriptor (never by re-resolving the path), so the fd
/// must stay open for the evidence's whole lifetime. A struct would let a value copy drop the
/// last handle reference the moment it went out of scope; a class makes the lifetime explicit
/// and shared, so the evidence cannot be "half-alive" after the runner takes it.
///
/// The initializer is INTERNAL, so only Core (`StagedSnapshotGate`) can mint evidence — a
/// production caller can never fabricate a gated snapshot, matching the 2B-1 evidence types.
public final class GatedStagedSnapshot {
    public let importID: ImportID
    public let stagingDir: URL
    /// The manifest — trusted ONLY because the gate re-verified every field against disk.
    public let manifest: ImportManifest
    public let hasWAL: Bool
    public let hasAttachments: Bool
    /// The bound staging-root descriptor (O_NOFOLLOW|O_DIRECTORY, dev+inode). Internal so the
    /// App module cannot reach the fd; the runner reads DB/WAL/attachments through it.
    let root: DirectoryHandle

    init(importID: ImportID, stagingDir: URL, manifest: ImportManifest,
         hasWAL: Bool, hasAttachments: Bool, root: DirectoryHandle) {
        self.importID = importID
        self.stagingDir = stagingDir
        self.manifest = manifest
        self.hasWAL = hasWAL
        self.hasAttachments = hasAttachments
        self.root = root
    }
}

// MARK: - The gate

/// Consume-time, descriptor-rooted validator for a PUBLISHED staging dir (`Staging/import-<id>`).
/// It is the read-side mirror of `StagingIngest.validateAttemptForPublish` — but with NO
/// in-memory layout to trust: the on-disk `manifest.json` is the SOLE anchor, so every field
/// must be self-consistent AND bound to disk.
///
/// It validates ONLY the manifest and the filesystem. It NEVER opens the staged SQLite
/// database (no PRAGMA, no user_version — schema/version gating belongs to the runner, which
/// works on a private COPY). Every read is through a bound `DirectoryHandle`
/// (openat/fstatat/errno-checked), so no path re-resolution can redirect it and a directory
/// read error fails closed rather than truncating.
public struct StagedSnapshotGate {
    public init() {}

    /// Convenience: gate the staging dir a fresh ingest just published.
    public func gate(_ ingest: IngestResult) throws -> GatedStagedSnapshot {
        try gate(stagingDir: ingest.stagingDir)
    }

    public func gate(stagingDir: URL) throws -> GatedStagedSnapshot {
        // 1. Bind the staging dir: O_NOFOLLOW|O_DIRECTORY, device+inode. A symlinked or
        //    non-directory staging path is rejected here.
        let root: DirectoryHandle
        do { root = try DirectoryHandle.open(at: stagingDir) }
        catch { throw StagedSnapshotError.stagingUnreadable("\(stagingDir.lastPathComponent): \(error)") }

        // 2. Read manifest.json THROUGH the descriptor (no symlink follow, no re-resolution).
        let manifest: ImportManifest
        do {
            let data = try root.readRegularFile(named: "manifest.json")
            manifest = try JSONDecoder().decode(ImportManifest.self, from: data)
        } catch { throw StagedSnapshotError.manifestUnreadable("\(error)") }

        // 3. Manifest self-consistency (NO SQLite open, NO user_version check).
        guard manifest.formatVersion == ImportManifest.currentFormatVersion else {
            throw StagedSnapshotError.unsupportedManifestFormat(manifest.formatVersion)
        }
        guard manifest.status == .ingested else {
            throw StagedSnapshotError.notIngested("status is '\(manifest.status.rawValue)', expected 'ingested'")
        }
        try Self.requireCanonicalIngested(manifest)

        guard let importID = ImportID(manifest.importID) else {
            throw StagedSnapshotError.invalidImportID(manifest.importID)
        }
        // Bind the on-disk directory NAME to the import: Staging/import-<id>.
        let dirName = stagingDir.lastPathComponent
        let expectedDirName = "import-" + importID.rawValue
        guard dirName == expectedDirName else {
            throw StagedSnapshotError.importIDMismatch(dir: dirName, manifest: expectedDirName)
        }
        // attachmentSetHash covers the WHOLE file set (ingested AND skipped), so a dropped or
        // renamed skipped entry trips it.
        guard ImportManifest.attachmentSetHash(manifest.files) == manifest.attachmentManifestSHA256 else {
            throw StagedSnapshotError.attachmentManifestHashMismatch
        }
        // snapshotIdentity binds the DB + WAL as one snapshot (shared helper, 2B-3 C1).
        guard ImportManifest.snapshotIdentity(dbSHA: manifest.sourceDBSHA256, walSHA: manifest.walSHA256)
                == manifest.snapshotIdentitySHA256 else {
            throw StagedSnapshotError.snapshotContentInconsistent("recomputed snapshotIdentity != manifest")
        }

        // 4. Exact root entry set + per-entry type, derived from the manifest.
        let dbName = AppPaths.databaseFileName
        let walName = dbName + "-wal"
        let ingested = manifest.files.filter { $0.outcome == .ingested }
        let hasWAL = manifest.walSHA256 != nil
        let hasAttachments = !ingested.isEmpty
        var expectedRoot: Set<String> = ["manifest.json", dbName]
        if hasWAL { expectedRoot.insert(walName) }
        if hasAttachments { expectedRoot.insert("attachments") }
        let rootEntries = Set(try root.entryNames())   // errno-checked; throws on read error
        guard rootEntries == expectedRoot else {
            throw StagedSnapshotError.rootEntrySetMismatch(
                "root is \(rootEntries.sorted()) but must be exactly \(expectedRoot.sorted())")
        }
        for name in expectedRoot {
            guard let fp = try root.fingerprint(named: name) else {
                throw StagedSnapshotError.rootEntrySetMismatch("\(name) vanished")
            }
            let wantDir = (name == "attachments")
            guard wantDir ? fp.isDirectory : fp.isRegularFile else {
                throw StagedSnapshotError.rootEntrySetMismatch("\(name) has the wrong type")
            }
        }

        // 5. DB + optional WAL digests THROUGH the descriptor == manifest.
        func digest(_ dir: DirectoryHandle, _ name: String, _ label: String) throws -> RegularFileDigest {
            do { return try dir.digestOfRegularFile(named: name) }
            catch { throw StagedSnapshotError.snapshotContentInconsistent("\(label): \(error)") }
        }
        let dbDigest = try digest(root, dbName, "db")
        guard dbDigest.sha256 == manifest.sourceDBSHA256 else {
            throw StagedSnapshotError.snapshotContentInconsistent("db sha256 != manifest.sourceDBSHA256")
        }
        if let walSHA = manifest.walSHA256 {
            let walDigest = try digest(root, walName, "wal")
            guard walDigest.sha256 == walSHA else {
                throw StagedSnapshotError.snapshotContentInconsistent("wal sha256 != manifest.walSHA256")
            }
        }

        // 6. Attachment subtree: attachments → docs (both real dirs via openat), docs' entry
        //    set EXACTLY the ingested names, each a regular file with the manifest digest+size.
        if hasAttachments {
            let attachments: DirectoryHandle
            let docs: DirectoryHandle
            do {
                attachments = try root.subdirectory(named: "attachments")
                guard try attachments.entryNames() == ["docs"] else {
                    throw StagedSnapshotError.attachmentTreeMismatch("attachments dir must contain exactly 'docs'")
                }
                docs = try attachments.subdirectory(named: "docs")
            } catch let e as StagedSnapshotError { throw e }
            catch { throw StagedSnapshotError.attachmentTreeMismatch("\(error)") }

            let docsEntries = Set(try docs.entryNames())
            let expectedDocs = Set(ingested.map { $0.name })
            guard docsEntries == expectedDocs else {
                throw StagedSnapshotError.attachmentTreeMismatch(
                    "docs is \(docsEntries.sorted()) but must be exactly \(expectedDocs.sorted())")
            }
            for f in ingested {
                let d = try digest(docs, f.name, "attachment \(f.name)")
                guard d.sha256 == f.sha256, d.size == f.size else {
                    throw StagedSnapshotError.snapshotContentInconsistent("attachment \(f.name) digest/size != manifest")
                }
            }
        }

        return GatedStagedSnapshot(importID: importID, stagingDir: stagingDir, manifest: manifest,
                                   hasWAL: hasWAL, hasAttachments: hasAttachments, root: root)
    }

    /// A canonical `.ingested` manifest carries NO terminal (apply/complete-stage) fields, and
    /// each file entry matches its outcome: an ingested file has sha256+size, a skipped file
    /// carries NO payload. Whole-manifest name dedup mirrors ingest's own tamper check.
    static func requireCanonicalIngested(_ m: ImportManifest) throws {
        func bad(_ s: String) -> StagedSnapshotError { .nonCanonicalManifest(s) }
        if m.report != nil { throw bad("report must be nil on an .ingested manifest") }
        if m.applied != nil { throw bad("applied must be nil on an .ingested manifest") }
        if m.unresolved != nil { throw bad("unresolved must be nil on an .ingested manifest") }
        if m.acknowledgedReportHash != nil { throw bad("acknowledgedReportHash must be nil on an .ingested manifest") }
        if m.referenceAuditPerformed != nil { throw bad("referenceAuditPerformed must be nil on an .ingested manifest") }
        if m.preparedDBIdentity != nil { throw bad("preparedDBIdentity must be nil on an .ingested manifest") }

        var seen = Set<String>()
        for f in m.files {
            guard seen.insert(f.name).inserted else { throw bad("duplicate file name in manifest: \(f.name)") }
            if f.outcome == .ingested {
                guard AttachmentName.isValid(f.name) else { throw bad("ingested name fails the whitelist: \(f.name)") }
                guard f.sha256 != nil, f.size != nil else { throw bad("ingested file '\(f.name)' is missing sha256/size") }
            } else {
                guard f.sha256 == nil, f.size == nil else { throw bad("skipped file '\(f.name)' must not carry a payload (sha256/size)") }
            }
        }
    }
}
