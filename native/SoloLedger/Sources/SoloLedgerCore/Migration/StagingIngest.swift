import Foundation
import CryptoKit

// MARK: - Streaming file hash

public enum FileHashError: Error, CustomStringConvertible, Equatable {
    /// The path names something other than a regular file — a symlink (O_NOFOLLOW),
    /// directory, FIFO or other special file. Refusing to hash it.
    case notARegularFile(String)
    case unreadable(path: String, errno: Int32)
    /// The copy destination could not be created EXCLUSIVELY (it already exists — even as
    /// a dangling symlink — or the create failed). The primitive never overwrites and
    /// never follows a link at the destination.
    case destinationUnwritable(path: String, errno: Int32)

    public var description: String {
        switch self {
        case .notARegularFile(let p): return "Not a regular file (symlink/directory/special): \(p)"
        case .unreadable(let p, let e): return "Cannot read file for hashing: \(p) (errno \(e))"
        case .destinationUnwritable(let p, let e): return "Cannot exclusively create copy destination: \(p) (errno \(e))"
        }
    }
    /// True only for a definitively ABSENT path (ENOENT) — every other failure must stay
    /// fail-closed at the caller.
    public var isFileMissing: Bool {
        if case .unreadable(_, let e) = self { return e == ENOENT }
        return false
    }
}

/// Size + SHA-256 obtained from ONE verified file descriptor: `size` counts exactly the
/// bytes that were hashed, so the two can never describe different content.
public struct RegularFileDigest: Equatable {
    public let sha256: String
    public let size: Int64
}

/// lstat-based, no-follow fingerprint used for BOTH change detection and type gating.
/// Binds file type + device + inode + size + nanosecond mtime/ctime, so a same-size/
/// same-mtime replacement (new inode), a type swap, or a cross-device substitution can
/// no longer masquerade as "unchanged". ONLY ENOENT reads as "absent" (nil); every other
/// metadata failure throws — never silently treated as absence or stability.
public struct FileFingerprint: Equatable {
    public let fileType: UInt16   // S_IFMT bits of st_mode
    public let device: Int32
    public let inode: UInt64
    public let size: Int64
    public let mtimeSec: Int64
    public let mtimeNSec: Int64
    public let ctimeSec: Int64
    public let ctimeNSec: Int64

    public var isRegularFile: Bool { fileType == UInt16(S_IFREG) }
    public var isDirectory: Bool { fileType == UInt16(S_IFDIR) }

    /// nil ⇔ the path is definitively absent (ENOENT). Never follows symlinks — a symlink
    /// fingerprints as the link itself (fileType S_IFLNK).
    public static func capture(at url: URL) throws -> FileFingerprint? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else {
            let e = errno
            if e == ENOENT { return nil }
            throw FileHashError.unreadable(path: url.path, errno: e)
        }
        return FileFingerprint(fileType: UInt16(st.st_mode) & UInt16(S_IFMT),
                               device: Int32(st.st_dev), inode: UInt64(st.st_ino),
                               size: Int64(st.st_size),
                               mtimeSec: Int64(st.st_mtimespec.tv_sec), mtimeNSec: Int64(st.st_mtimespec.tv_nsec),
                               ctimeSec: Int64(st.st_ctimespec.tv_sec), ctimeNSec: Int64(st.st_ctimespec.tv_nsec))
    }
}

public enum FileHash {
    /// Streaming SHA-256 of a file as lowercase hex. Reads in chunks so a large DB or
    /// attachment never loads fully into memory. Size alone is NEVER treated as content
    /// equality — this is the content hash used when a decision needs true identity.
    public static func sha256Hex(of url: URL, chunkSize: Int = 1 << 20) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try streamDigest(from: handle, chunkSize: chunkSize) { _ in }.sha256
    }

    /// No-follow, REGULAR-FILE-ONLY streaming hash — the primitive every trust decision
    /// about an on-disk attachment/database must use. See `digestOfRegularFile`.
    public static func sha256HexOfRegularFile(at url: URL, chunkSize: Int = 1 << 20) throws -> String {
        try digestOfRegularFile(at: url, chunkSize: chunkSize).sha256
    }

    /// No-follow, fd-bound digest: opens with O_NOFOLLOW|O_NONBLOCK (a symlink fails with
    /// ELOOP instead of being followed; a FIFO opens without blocking instead of hanging),
    /// fstat's the OPENED descriptor and rejects anything but S_IFREG, then hashes from
    /// that same descriptor — the type that was checked, the bytes that are hashed and
    /// the size that is reported can never belong to different filesystem objects.
    public static func digestOfRegularFile(at url: URL, chunkSize: Int = 1 << 20) throws -> RegularFileDigest {
        let handle = try openVerifiedRegularFile(url)
        defer { try? handle.close() }
        return try streamDigest(from: handle, chunkSize: chunkSize) { _ in }
    }

    /// No-follow, fd-bound COPY of a regular file. The source is opened
    /// O_NOFOLLOW|O_NONBLOCK and fstat-verified S_IFREG on the OPEN descriptor; the
    /// destination is created O_CREAT|O_EXCL|O_NOFOLLOW — exclusively, never overwriting
    /// and never following a pre-planted link (even a dangling one). Bytes stream from
    /// the verified source fd, and the returned digest (sha256 + size) describes EXACTLY
    /// the bytes written. On any failure the partial destination is removed — a failed
    /// copy never leaves content behind.
    public static func copyRegularFileNoFollow(from src: URL, to dst: URL,
                                               chunkSize: Int = 1 << 20) throws -> RegularFileDigest {
        let source = try openVerifiedRegularFile(src)
        defer { try? source.close() }

        let dfd = open(dst.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
        guard dfd >= 0 else { throw FileHashError.destinationUnwritable(path: dst.path, errno: errno) }
        let sink = FileHandle(fileDescriptor: dfd, closeOnDealloc: true)
        var complete = false
        defer {
            try? sink.close()
            if !complete { unlink(dst.path) }   // never leave a partial copy behind
        }

        let digest = try streamDigest(from: source, chunkSize: chunkSize) { chunk in
            try sink.write(contentsOf: chunk)
        }
        try sink.close()
        complete = true
        return digest
    }

    /// Open + verify: O_NOFOLLOW|O_NONBLOCK, fstat on the open fd, S_IFREG only.
    private static func openVerifiedRegularFile(_ url: URL) throws -> FileHandle {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            let e = errno
            if e == ELOOP { throw FileHashError.notARegularFile(url.path) }   // symlink under O_NOFOLLOW
            throw FileHashError.unreadable(path: url.path, errno: e)
        }
        var st = stat()
        guard fstat(fd, &st) == 0 else {
            let e = errno; close(fd)
            throw FileHashError.unreadable(path: url.path, errno: e)
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            throw FileHashError.notARegularFile(url.path)
        }
        _ = fcntl(fd, F_SETFL, 0)   // drop O_NONBLOCK; regular-file reads ignore it anyway
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    private static func streamDigest(from handle: FileHandle, chunkSize: Int,
                                     onChunk: (Data) throws -> Void) throws -> RegularFileDigest {
        var hasher = SHA256()
        var total: Int64 = 0
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
            total += Int64(chunk.count)
            try onChunk(chunk)
        }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return RegularFileDigest(sha256: hex, size: total)
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

// MARK: - Stored attachment reference parsing

/// Parses a STORED attachment reference — the verbatim `attachments/docs/<name>` relative
/// string Electron writes to `transactions.attachment_path` and
/// `business_documents.tax_invoice_attachment_path` (its `REL_RE` whitelist) — into the bare
/// filename. Fail-closed: anything that is not EXACTLY the fixed prefix followed by ONE
/// `AttachmentName`-valid segment (absolute paths, traversal, extra slashes, empty or illegal
/// names, non-ASCII) yields nil. Parsing never touches the filesystem.
public enum AttachmentRelPath {
    /// The only legal prefix, derived from the shared layout constant so the parser and the
    /// on-disk mirror can never drift.
    public static let requiredPrefix = AppPaths.attachmentsRelativeRoot + "/"

    /// The bare filename iff `raw` is exactly `attachments/docs/<valid name>`, else nil.
    public static func bareName(of raw: String) -> String? {
        guard raw.hasPrefix(requiredPrefix) else { return nil }
        let name = String(raw.dropFirst(requiredPrefix.count))
        guard AttachmentName.isValid(name) else { return nil }
        return name
    }
}

// MARK: - Source stability (concurrent-change detector)

/// A fingerprint of the SOURCE, used ONLY to detect whether the source changed DURING
/// ingest (a live old Electron app still writing). Built on `FileFingerprint` (type +
/// device + inode + size + ns mtime/ctime, lstat, metadata errors fail-closed), so a
/// same-size/same-mtime replacement or a type swap trips it too. Still a change-DETECTOR,
/// never a content-equality proof — the staged bytes' identity comes from the manifest
/// digests, and pair-level semantics from the later snapshot verification.
struct SourceStabilityManifest: Equatable {
    var db: FileFingerprint?
    var wal: FileFingerprint?
    var attachments: [String: FileFingerprint]   // ingest-set only, keyed by name
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

    /// Explicit on-disk format version. The current writer stamps `currentFormatVersion`;
    /// a manifest whose version is missing (old format), older, or newer/unknown is
    /// REJECTED fail-closed rather than best-effort parsed. Decoded as optional so a
    /// missing key surfaces as an explicit unsupported-version rejection, not a decode
    /// error.
    ///
    /// v1 → v2: `UnresolvedReport.Item.Kind` gained `invalidReference` (malformed DB
    /// attachment-reference values recorded by the reference audit), so a v2 sentinel can
    /// carry items a v1 reader cannot represent. Pre-release contract: v1 manifests are
    /// rejected (staging must be re-ingested); no best-effort upgrade path is offered.
    public static let currentFormatVersion = 2
    public var formatVersion: Int? = nil

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
    /// The prepared/active DB this import was applied+audited against (recorded on a
    /// `.complete` sentinel; part of the full identity that guards idempotent re-completion).
    public var preparedDBIdentity: String? = nil

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
    /// A source DB/WAL/attachment that must be a regular file is a symlink, directory,
    /// FIFO or other special file. Never followed, never copied.
    case sourceNotRegularFile(String)
    /// The attachments root exists but is not a real (non-symlink) directory.
    case attachmentsRootNotADirectory(String)
    /// The source kept changing across attempts — the old Electron app is likely still
    /// running and writing. The user must quit it and retry.
    case sourceBusy(attempts: Int)
    /// The per-import staging dir already exists. The caller must decide (reject or resume);
    /// ingest never silently clears/mixes it.
    case importIDAlreadyExists(String)
    /// A staged file's re-verified digest does not match the digest of the bytes written
    /// at copy time, or the staged DB/WAL on disk does not match what the manifest is
    /// about to record. The attempt is untrustworthy and is discarded.
    case stagedContentInconsistent(String)
    /// A failing attempt could not be cleaned up. Surfaced (never swallowed) so a wedged
    /// staging dir is visible rather than silently leaked.
    case cleanupFailed(path: String, underlying: String, original: String)

    public var description: String {
        switch self {
        case .sourceDatabaseMissing(let p): return "Source database not found: \(p)"
        case .sourceNotRegularFile(let p): return "Source entry is not a regular file (symlink/directory/special) — refusing to ingest: \(p)"
        case .attachmentsRootNotADirectory(let p): return "Source attachments folder is not a real directory — refusing to ingest: \(p)"
        case .sourceBusy(let n): return "Source kept changing across \(n) attempts — quit the old SoloLedger (Electron) app and retry."
        case .importIDAlreadyExists(let id): return "An import with ID \(id) is already staged — reject or resume it, do not overwrite."
        case .stagedContentInconsistent(let what): return "Staged copy failed its consistency re-check (\(what)) — the attempt was discarded; retry the import."
        case let .cleanupFailed(path, underlying, original): return "Failed to clean up attempt \(path) after error [\(original)]: \(underlying)"
        }
    }
}

/// Internal marker: an entry that was fingerprinted/classified as present had definitively
/// vanished (ENOENT) by copy time — the source is changing underneath us. Mapped to the
/// same retry path as a stability mismatch, NEVER to "skip it silently".
struct SourceVanished: Error { let path: String }

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
            // Early, clear gates (lstat, no-follow). The copy primitive re-enforces both
            // on the open fd at copy time, so these are UX, not the security boundary.
            guard let dbFP = try FileFingerprint.capture(at: dbURL) else {
                throw IngestError.sourceDatabaseMissing(dbURL.path)
            }
            guard dbFP.isRegularFile else { throw IngestError.sourceNotRegularFile(dbURL.path) }
            if let w = try source.walURL(), let walFP = try FileFingerprint.capture(at: w) {
                guard walFP.isRegularFile else { throw IngestError.sourceNotRegularFile(w.path) }
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
        let staged: StagedLayout
        do {
            staged = try copyInto(attemptDir, source: source, dbURL: dbURL, hooks: hooks)
        } catch is SourceVanished {
            // Fingerprinted/classified as present, ENOENT by copy time: the source is
            // changing — same treatment as a stability mismatch.
            try removeAttempt(attemptDir, hooks: hooks)
            return .retry
        }
        try hooks.onRecheck?(attempt)
        let after = try stability(source)
        if before != after {
            try removeAttempt(attemptDir, hooks: hooks)   // hard-clean the changed attempt
            return .retry
        }

        let manifest = try buildManifest(importID: importID, source: source, timestamp: timestamp, staged: staged)
        try hooks.onStep?(.beforeManifestWrite)
        try writeManifest(manifest, to: attemptDir)

        // Atomic publish: rename the completed attempt onto the per-import dir (same
        // volume). moveItem THROWS if the destination exists — a concurrent ingest that
        // published this importID inside our window wins; ITS directory is never touched
        // (the caller cleans only OUR attempt) and the loss surfaces as the same
        // importIDAlreadyExists the up-front check uses.
        do {
            try FileManager.default.moveItem(at: attemptDir, to: finalDir)
        } catch {
            if FileManager.default.fileExists(atPath: finalDir.path) {
                throw IngestError.importIDAlreadyExists(importID.rawValue)
            }
            throw error
        }

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
    /// Root gate: ENOENT means "no attachments"; anything present must be a REAL
    /// (non-symlink) directory — a symlinked or non-directory root is rejected, and any
    /// other metadata error stays fail-closed (FileFingerprint.capture throws).
    private static func enumerateAttachments(root: URL) throws -> [ClassifiedAttachment] {
        let fm = FileManager.default
        guard let rootFP = try FileFingerprint.capture(at: root) else { return [] }
        guard rootFP.isDirectory else { throw IngestError.attachmentsRootNotADirectory(root.path) }
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

    /// Fail-closed fingerprinting: ONLY ENOENT reads as absence (the entry simply doesn't
    /// appear, so a presence flip still trips the before/after comparison); any other
    /// metadata error throws instead of masquerading as "stable" or "no WAL".
    private static func stability(_ source: MigrationSource) throws -> SourceStabilityManifest {
        let db = try FileFingerprint.capture(at: try source.databaseURL())
        var wal: FileFingerprint?
        if let w = try source.walURL() { wal = try FileFingerprint.capture(at: w) }
        var atts: [String: FileFingerprint] = [:]
        if let root = try source.attachmentsRootURL() {
            for c in try enumerateAttachments(root: root) where c.isIngested {
                if let fp = try FileFingerprint.capture(at: c.url) { atts[c.name] = fp }
            }
        }
        return SourceStabilityManifest(db: db, wal: wal, attachments: atts)
    }

    private struct StagedLayout {
        let dbURL: URL
        let walURL: URL?
        let attachmentsDir: URL?
        let fileResults: [ImportManifest.FileResult]   // sha/size filled later
        /// Digests of EXACTLY the bytes written at copy time (from the verified source
        /// fds) — buildManifest re-digests the staged files and requires equality.
        let dbCopyDigest: RegularFileDigest
        let walCopyDigest: RegularFileDigest?
        let attachmentCopyDigests: [String: RegularFileDigest]
        var hasWAL: Bool { walURL != nil }
        var hasAttachments: Bool { attachmentsDir != nil }
    }

    /// Fd-bound no-follow copy with ingest error mapping: a non-regular source (symlink —
    /// even to valid content — directory, FIFO) is `sourceNotRegularFile` IMMEDIATELY at
    /// copy time, never discovered later at the hash stage; a source that definitively
    /// vanished (ENOENT) after being classified is `SourceVanished` (→ retry); everything
    /// else stays fail-closed as-is.
    private static func copyGate(from src: URL, to dst: URL) throws -> RegularFileDigest {
        do {
            return try FileHash.copyRegularFileNoFollow(from: src, to: dst)
        } catch let e as FileHashError {
            if case .notARegularFile = e { throw IngestError.sourceNotRegularFile(src.path) }
            if e.isFileMissing { throw SourceVanished(path: src.path) }
            throw e
        }
    }

    private static func copyInto(_ dir: URL, source: MigrationSource, dbURL: URL, hooks: IngestHooks) throws -> StagedLayout {
        let fm = FileManager.default   // `dir` is a fresh, empty attempt dir — no clearing needed.

        let stagedDB = dir.appendingPathComponent(AppPaths.databaseFileName)
        let dbDigest = try copyGate(from: dbURL, to: stagedDB)
        try hooks.onStep?(.afterDatabaseCopy)

        var stagedWAL: URL?
        var walDigest: RegularFileDigest?
        if let w = try source.walURL(), try FileFingerprint.capture(at: w) != nil {
            let dst = URL(fileURLWithPath: stagedDB.path + "-wal")
            walDigest = try copyGate(from: w, to: dst)
            stagedWAL = dst
        }

        var stagedAttachDir: URL?
        var results: [ImportManifest.FileResult] = []
        var attachmentDigests: [String: RegularFileDigest] = [:]
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
                        attachmentDigests[c.name] = try copyGate(from: c.url, to: dstRoot.appendingPathComponent(c.name))
                    }
                    results.append(.init(name: c.name, outcome: c.outcome, sha256: nil, size: nil))
                }
            }
        }
        return StagedLayout(dbURL: stagedDB, walURL: stagedWAL, attachmentsDir: stagedAttachDir,
                            fileResults: results, dbCopyDigest: dbDigest, walCopyDigest: walDigest,
                            attachmentCopyDigests: attachmentDigests)
    }

    // MARK: - Manifest

    private static func buildManifest(importID: ImportID, source: MigrationSource,
                                      timestamp: String, staged: StagedLayout) throws -> ImportManifest {
        // Every manifest hash/size comes from the no-follow fd primitive over the STAGED
        // file, and must equal the digest of the bytes written at copy time — a staged
        // entry that changed, was swapped, or is no longer a regular file fails here.
        func verifiedDigest(_ url: URL, copyDigest: RegularFileDigest?, what: String) throws -> RegularFileDigest {
            let d = try FileHash.digestOfRegularFile(at: url)
            guard d == copyDigest else { throw IngestError.stagedContentInconsistent(what) }
            return d
        }
        let dbDigest = try verifiedDigest(staged.dbURL, copyDigest: staged.dbCopyDigest, what: "db")
        let walDigest = try staged.walURL.map { try verifiedDigest($0, copyDigest: staged.walCopyDigest, what: "wal") }

        var files: [ImportManifest.FileResult] = []
        for r in staged.fileResults {
            if r.outcome == .ingested, let attachDir = staged.attachmentsDir {
                let f = attachDir.appendingPathComponent(r.name)
                let d = try verifiedDigest(f, copyDigest: staged.attachmentCopyDigests[r.name], what: r.name)
                files.append(.init(name: r.name, outcome: .ingested, sha256: d.sha256, size: d.size))
            } else {
                files.append(r)
            }
        }
        files.sort { $0.name < $1.name }

        // Existence-vs-record: what the manifest is about to claim must match the disk —
        // the staged DB is a regular file, and a `-wal` exists IFF walSHA256 is recorded.
        guard (try FileFingerprint.capture(at: staged.dbURL))?.isRegularFile == true else {
            throw IngestError.stagedContentInconsistent("db missing before manifest write")
        }
        let walOnDisk = try FileFingerprint.capture(at: URL(fileURLWithPath: staged.dbURL.path + "-wal"))
        guard (walOnDisk != nil) == (walDigest != nil) else {
            throw IngestError.stagedContentInconsistent("wal presence does not match record")
        }
        let dbHash = dbDigest.sha256
        let walHash = walDigest?.sha256

        return ImportManifest(formatVersion: ImportManifest.currentFormatVersion,
                              importID: importID.rawValue, sourceKind: source.kind, createdAt: timestamp,
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
