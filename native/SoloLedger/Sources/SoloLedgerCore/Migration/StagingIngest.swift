import Foundation
import CryptoKit

// MARK: - Streaming file hash

public enum FileHash {
    /// Streaming SHA-256 of a file as lowercase hex. Reads in chunks so a large DB or
    /// attachment never loads fully into memory. Size alone is NEVER treated as content
    /// equality — this is the content hash used when a decision needs true identity.
    public static func sha256Hex(of url: URL, chunkSize: Int = 1 << 20) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Attachment filename validation

public enum AttachmentName {
    /// The FILENAME portion of Electron's REL_RE `attachments/docs/[A-Za-z0-9][A-Za-z0-9._-]*`:
    /// a single path segment, first char alphanumeric, remaining chars in `[A-Za-z0-9._-]`,
    /// no `/`, no `..`. Non-ASCII fails (matching the ASCII regex).
    public static func isValid(_ name: String) -> Bool {
        guard !name.isEmpty, !name.contains("/"), !name.contains("..") else { return false }
        var first = true
        for ch in name.unicodeScalars {
            let isAlnum = (ch >= "A" && ch <= "Z") || (ch >= "a" && ch <= "z") || (ch >= "0" && ch <= "9")
            if first {
                if !isAlnum { return false }
                first = false
            } else if !(isAlnum || ch == "." || ch == "_" || ch == "-") {
                return false
            }
        }
        return true
    }
}

// MARK: - Source stability (concurrent-change detector)

/// A cheap fingerprint of the SOURCE, used ONLY to detect whether the source changed
/// DURING ingest (a live old Electron app still writing). Uses size + mtime — a write
/// bumps mtime — so it is a change-DETECTOR, never a content-equality proof.
struct SourceStabilityManifest: Equatable {
    struct Entry: Equatable { let name: String; let size: Int64; let mtime: TimeInterval }
    var db: Entry?
    var wal: Entry?
    var attachments: [Entry]   // ingest-set only, sorted by name
}

// MARK: - Import manifest (out-of-DB, per-import completion record)

/// The out-of-database, per-import record. Bound to an import ID, the source DB hash, the
/// WAL hash + a combined DB+WAL snapshot identity, an attachment-set hash and per-file
/// results. Deliberately NOT a global `settings` boolean: importing an old backup must
/// never inherit a stale "attachments migrated" flag. `report`/terminal statuses are filled
/// by later apply stages.
public struct ImportManifest: Codable, Equatable {
    public enum Status: String, Codable {
        /// Attachments copied into isolated staging; not yet applied to the active dir.
        case ingested
        /// Attachments applied to the active dir (absent copied, identical skipped, missing
        /// itemized in `report`); this manifest, persisted to ImportManifests, is the
        /// per-import COMPLETION SENTINEL.
        case complete
    }

    /// Outcome of the non-destructive apply stage (present only on a `.complete` manifest).
    public struct AppliedSummary: Codable, Equatable {
        public var copied: [String]
        public var skippedIdentical: [String]
        public var missing: [String]   // in the manifest but absent from staging on disk
        public init(copied: [String], skippedIdentical: [String], missing: [String]) {
            self.copied = copied; self.skippedIdentical = skippedIdentical; self.missing = missing
        }
    }

    public struct FileResult: Codable, Equatable {
        public enum Outcome: String, Codable {
            case ingested, skippedSymlink, skippedDirectory, skippedSpecial, rejectedName
        }
        public var name: String
        public var outcome: Outcome
        public var sha256: String?   // ingested files only
        public var size: Int64?      // ingested files only
    }

    public var importID: String
    public var sourceKind: String
    public var createdAt: String
    public var sourceDBSHA256: String
    /// Streaming SHA-256 of the WAL, or `nil` when the source has no WAL (explicitly absent,
    /// not an empty string).
    public var walSHA256: String?
    /// Stable identity of the DB (+ WAL) as a combined snapshot: two ingests with the same
    /// main DB but a different WAL produce DIFFERENT identities.
    public var snapshotIdentitySHA256: String
    /// Stable hash over the sorted set of ingested (name, sha256) — the attachment payload identity.
    public var attachmentManifestSHA256: String
    public var files: [FileResult]
    public var status: Status
    public var report: String?
    /// Apply-stage outcome; nil until the attachment apply completes.
    public var applied: AppliedSummary? = nil
    /// Everything that could not be cleanly migrated (missing / skipped / dangling); a
    /// `.complete` sentinel with a non-empty `unresolved` also carries `acknowledgedReportHash`.
    public var unresolved: UnresolvedReport? = nil
    /// The unresolved-report hash the user acknowledged when completing with open items.
    public var acknowledgedReportHash: String? = nil
    /// True on a `.complete` sentinel iff the DB reference audit was actually run before
    /// finalizing — so a reader can tell an audited-clean import from a never-audited one.
    public var referenceAuditPerformed: Bool? = nil

    public var ingestedCount: Int { files.filter { $0.outcome == .ingested }.count }
    public var skippedCount: Int { files.filter { $0.outcome != .ingested }.count }

    /// Stable hash over the WHOLE attachment manifest — every entry (ingested AND skipped/
    /// rejected), sorted, encoding (name, outcome, sha256). Covering the skip set too makes
    /// it tamper-evident: a dropped/renamed skipped entry (which would otherwise silently
    /// shrink the unresolved report and bypass the acknowledgement gate) trips a mismatch.
    /// Shared by ingest (to STORE it) and apply (to RE-VERIFY it fail-closed) so they can
    /// never drift.
    public static func attachmentSetHash(_ files: [FileResult]) -> String {
        let lines = files
            .sorted { ($0.name, $0.outcome.rawValue) < ($1.name, $1.outcome.rawValue) }
            .map { "\($0.name)\u{0}\($0.outcome.rawValue)\u{0}\($0.sha256 ?? "")" }
            .joined(separator: "\n")
        return SHA256.hash(data: Data(lines.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Ingest

public enum IngestError: Error, CustomStringConvertible {
    case sourceDatabaseMissing(String)
    /// The source kept changing across attempts — the old Electron app is likely still
    /// running and writing. The user must quit it and retry.
    case sourceBusy(attempts: Int)
    /// The per-import staging dir already exists. The caller must decide (reject or resume);
    /// ingest never silently clears/mixes it.
    case importIDAlreadyExists(String)
    /// A failing attempt could not be cleaned up. Surfaced (never swallowed) so a wedged
    /// staging dir is visible rather than silently leaked.
    case cleanupFailed(path: String, underlying: String, original: String)

    public var description: String {
        switch self {
        case .sourceDatabaseMissing(let p): return "Source database not found: \(p)"
        case .sourceBusy(let n): return "Source kept changing across \(n) attempts — quit the old SoloLedger (Electron) app and retry."
        case .importIDAlreadyExists(let id): return "An import with ID \(id) is already staged — reject or resume it, do not overwrite."
        case let .cleanupFailed(path, underlying, original): return "Failed to clean up attempt \(path) after error [\(original)]: \(underlying)"
        }
    }
}

public struct IngestResult {
    public let importID: ImportID
    public let stagingDir: URL
    public let stagedDatabaseURL: URL
    public let stagedWALURL: URL?
    public let stagedAttachmentsDir: URL?
    public let manifest: ImportManifest
}

/// Test-only fault seams (all `internal`, defaulting to no-op). The public `ingest` never
/// exposes them; only the `@testable` test target can inject failures / concurrent changes.
struct IngestHooks {
    /// Fires after the copy, before the after-fingerprint — a test mutates the source here
    /// to exercise the concurrent-change retry / `.sourceBusy` path.
    var onRecheck: ((Int) throws -> Void)?
    /// Fires at a named copy step so a test can inject a mid-copy failure.
    var onStep: ((IngestStep) throws -> Void)?
    /// Overrides attempt cleanup so a test can inject a cleanup failure.
    var cleanup: ((URL) throws -> Void)?
    init(onRecheck: ((Int) throws -> Void)? = nil,
         onStep: ((IngestStep) throws -> Void)? = nil,
         cleanup: ((URL) throws -> Void)? = nil) {
        self.onRecheck = onRecheck; self.onStep = onStep; self.cleanup = cleanup
    }
}

enum IngestStep { case afterDatabaseCopy, duringAttachmentCopy, beforeManifestWrite }

/// Copies a `MigrationSource` into an isolated, native-owned staging directory, verifying
/// the source did not change during the copy. FAILURE-ATOMIC: each attempt writes to its
/// own fresh temp dir; on any failure that temp dir is hard-removed (a cleanup failure is
/// surfaced, never swallowed with `try?`); only a fully-written attempt (incl. its manifest)
/// is atomically PUBLISHED (renamed) to the per-import staging dir. After it returns, NOTHING
/// touches the original source again — all later verify/swap/retry work reads from staging.
public struct StagingIngest {
    public init() {}

    /// Ingest `source` into `AppPaths.stagedImportDirectory(importID:)`. Copies the DB (and
    /// its `-wal` only when the source legitimately has one), then every REL_RE-conforming
    /// REGULAR attachment file; symlinks, special files, nested directories and
    /// illegally-named entries are SKIPPED and recorded, never ingested. Re-fingerprints the
    /// source before/after and retries on change, throwing `.sourceBusy` when exhausted.
    /// Throws `.importIDAlreadyExists` if the per-import staging dir already exists.
    @discardableResult
    public func ingest(_ source: MigrationSource,
                       importID: ImportID = .generate(),
                       timestamp: String = DateFormat.timestamp()) throws -> IngestResult {
        try ingest(source, importID: importID, timestamp: timestamp, maxAttempts: 3, hooks: IngestHooks())
    }

    /// Internal entry point with an attempt bound + fault seams (test-only).
    @discardableResult
    func ingest(_ source: MigrationSource, importID: ImportID, timestamp: String,
                maxAttempts: Int, hooks: IngestHooks) throws -> IngestResult {
        let dbURL = try source.databaseURL()
        let finalDir = try AppPaths.stagedImportDirectory(importID: importID)
        if FileManager.default.fileExists(atPath: finalDir.path) {
            throw IngestError.importIDAlreadyExists(importID.rawValue)
        }
        return try source.withAccess {
            guard FileManager.default.fileExists(atPath: dbURL.path) else {
                throw IngestError.sourceDatabaseMissing(dbURL.path)
            }
            var attempt = 0
            while true {
                attempt += 1
                let attemptDir = try AppPaths.freshStagingAttemptDirectory()

                let outcome: AttemptOutcome
                do {
                    outcome = try Self.performAttempt(source: source, dbURL: dbURL, importID: importID,
                                                      timestamp: timestamp, attemptDir: attemptDir,
                                                      finalDir: finalDir, attempt: attempt, hooks: hooks)
                } catch {
                    // Any failure (copy / hash / manifest / publish): hard-clean this attempt,
                    // surfacing a cleanup failure. Never leaves a partial attempt behind.
                    try Self.cleanupIfPresent(attemptDir, hooks: hooks, original: error)
                    throw error
                }

                switch outcome {
                case .published(let result):
                    return result
                case .retry:
                    // performAttempt already removed the (unpublished) attempt dir.
                    if attempt >= maxAttempts { throw IngestError.sourceBusy(attempts: attempt) }
                    continue
                }
            }
        }
    }

    // MARK: - Attempt

    private enum AttemptOutcome { case published(IngestResult); case retry }

    private static func performAttempt(source: MigrationSource, dbURL: URL, importID: ImportID,
                                       timestamp: String, attemptDir: URL, finalDir: URL,
                                       attempt: Int, hooks: IngestHooks) throws -> AttemptOutcome {
        let before = try stability(source)
        let staged = try copyInto(attemptDir, source: source, dbURL: dbURL, hooks: hooks)
        try hooks.onRecheck?(attempt)
        let after = try stability(source)
        if before != after {
            try removeAttempt(attemptDir, hooks: hooks)   // hard-clean the changed attempt
            return .retry
        }

        let manifest = try buildManifest(importID: importID, source: source, timestamp: timestamp, staged: staged)
        try hooks.onStep?(.beforeManifestWrite)
        try writeManifest(manifest, to: attemptDir)

        // Atomic publish: rename the completed attempt onto the per-import dir (same volume).
        try FileManager.default.moveItem(at: attemptDir, to: finalDir)

        let stagedDB = finalDir.appendingPathComponent(AppPaths.databaseFileName)
        return .published(IngestResult(
            importID: importID,
            stagingDir: finalDir,
            stagedDatabaseURL: stagedDB,
            stagedWALURL: staged.hasWAL ? URL(fileURLWithPath: stagedDB.path + "-wal") : nil,
            stagedAttachmentsDir: staged.hasAttachments
                ? finalDir.appendingPathComponent("attachments", isDirectory: true).appendingPathComponent("docs", isDirectory: true)
                : nil,
            manifest: manifest))
    }

    private static func cleanupIfPresent(_ dir: URL, hooks: IngestHooks, original: Error) throws {
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        do {
            try removeAttempt(dir, hooks: hooks)
        } catch {
            throw IngestError.cleanupFailed(path: dir.path, underlying: "\(error)", original: "\(original)")
        }
    }

    /// Remove an attempt dir. NOT `try?` — a cleanup failure is surfaced by the caller.
    private static func removeAttempt(_ dir: URL, hooks: IngestHooks) throws {
        if let override = hooks.cleanup { try override(dir); return }
        try FileManager.default.removeItem(at: dir)
    }

    // MARK: - Classification / copy

    private struct ClassifiedAttachment {
        let url: URL
        let name: String
        let outcome: ImportManifest.FileResult.Outcome
        var isIngested: Bool { outcome == .ingested }
    }

    /// Classify the TOP-LEVEL entries of an attachments root (never recursive). Order:
    /// symlink (lstat, not followed) → directory → regular file (name-validated) → special.
    private static func enumerateAttachments(root: URL) throws -> [ClassifiedAttachment] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { return [] }
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]
        let entries = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: keys, options: [])
        var out: [ClassifiedAttachment] = []
        for url in entries {
            let name = url.lastPathComponent
            let v = try url.resourceValues(forKeys: Set(keys))
            let outcome: ImportManifest.FileResult.Outcome
            if v.isSymbolicLink == true {
                outcome = .skippedSymlink
            } else if v.isDirectory == true {
                outcome = .skippedDirectory
            } else if v.isRegularFile == true {
                outcome = AttachmentName.isValid(name) ? .ingested : .rejectedName
            } else {
                outcome = .skippedSpecial
            }
            out.append(ClassifiedAttachment(url: url, name: name, outcome: outcome))
        }
        return out.sorted { $0.name < $1.name }
    }

    private static func stability(_ source: MigrationSource) throws -> SourceStabilityManifest {
        let fm = FileManager.default
        func entry(_ url: URL, name: String) -> SourceStabilityManifest.Entry? {
            guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { return nil }
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? -1
            let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
            return .init(name: name, size: size, mtime: mtime)
        }
        let db = entry(try source.databaseURL(), name: "db")
        var wal: SourceStabilityManifest.Entry?
        if let w = try source.walURL(), fm.fileExists(atPath: w.path) { wal = entry(w, name: "wal") }
        var atts: [SourceStabilityManifest.Entry] = []
        if let root = try source.attachmentsRootURL() {
            for c in try enumerateAttachments(root: root) where c.isIngested {
                if let e = entry(c.url, name: c.name) { atts.append(e) }
            }
        }
        return SourceStabilityManifest(db: db, wal: wal, attachments: atts.sorted { $0.name < $1.name })
    }

    private struct StagedLayout {
        let dbURL: URL
        let walURL: URL?
        let attachmentsDir: URL?
        let fileResults: [ImportManifest.FileResult]   // sha/size filled later
        var hasWAL: Bool { walURL != nil }
        var hasAttachments: Bool { attachmentsDir != nil }
    }

    private static func copyInto(_ dir: URL, source: MigrationSource, dbURL: URL, hooks: IngestHooks) throws -> StagedLayout {
        let fm = FileManager.default   // `dir` is a fresh, empty attempt dir — no clearing needed.

        let stagedDB = dir.appendingPathComponent(AppPaths.databaseFileName)
        try fm.copyItem(at: dbURL, to: stagedDB)
        try hooks.onStep?(.afterDatabaseCopy)

        var stagedWAL: URL?
        if let w = try source.walURL(), fm.fileExists(atPath: w.path) {
            let dst = URL(fileURLWithPath: stagedDB.path + "-wal")
            try fm.copyItem(at: w, to: dst)
            stagedWAL = dst
        }

        var stagedAttachDir: URL?
        var results: [ImportManifest.FileResult] = []
        if let root = try source.attachmentsRootURL() {
            let classified = try enumerateAttachments(root: root)
            if !classified.isEmpty {
                let dstRoot = dir.appendingPathComponent("attachments", isDirectory: true)
                    .appendingPathComponent("docs", isDirectory: true)
                try fm.createDirectory(at: dstRoot, withIntermediateDirectories: true)
                stagedAttachDir = dstRoot
                for c in classified {
                    if c.isIngested {
                        try hooks.onStep?(.duringAttachmentCopy)
                        try fm.copyItem(at: c.url, to: dstRoot.appendingPathComponent(c.name))
                    }
                    results.append(.init(name: c.name, outcome: c.outcome, sha256: nil, size: nil))
                }
            }
        }
        return StagedLayout(dbURL: stagedDB, walURL: stagedWAL, attachmentsDir: stagedAttachDir, fileResults: results)
    }

    // MARK: - Manifest

    private static func buildManifest(importID: ImportID, source: MigrationSource,
                                      timestamp: String, staged: StagedLayout) throws -> ImportManifest {
        let dbHash = try FileHash.sha256Hex(of: staged.dbURL)
        let walHash = try staged.walURL.map { try FileHash.sha256Hex(of: $0) }

        var files: [ImportManifest.FileResult] = []
        for r in staged.fileResults {
            if r.outcome == .ingested, let attachDir = staged.attachmentsDir {
                let f = attachDir.appendingPathComponent(r.name)
                let sha = try FileHash.sha256Hex(of: f)
                let size = (try? FileManager.default.attributesOfItem(atPath: f.path))
                    .flatMap { ($0[.size] as? NSNumber)?.int64Value }
                files.append(.init(name: r.name, outcome: .ingested, sha256: sha, size: size))
            } else {
                files.append(r)
            }
        }
        files.sort { $0.name < $1.name }

        return ImportManifest(importID: importID.rawValue, sourceKind: source.kind, createdAt: timestamp,
                              sourceDBSHA256: dbHash, walSHA256: walHash,
                              snapshotIdentitySHA256: snapshotIdentity(dbSHA: dbHash, walSHA: walHash),
                              attachmentManifestSHA256: ImportManifest.attachmentSetHash(files),
                              files: files, status: .ingested, report: nil)
    }

    /// Stable combined identity of DB (+ WAL). Different WAL ⇒ different identity even for the
    /// same main DB.
    private static func snapshotIdentity(dbSHA: String, walSHA: String?) -> String {
        let s = "db:\(dbSHA)\u{0}wal:\(walSHA ?? "")"
        return SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func writeManifest(_ manifest: ImportManifest, to dir: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
    }
}
