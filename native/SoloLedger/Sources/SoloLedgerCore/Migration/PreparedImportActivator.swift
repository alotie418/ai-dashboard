import Foundation
import CryptoKit

// MARK: - 2B-3 C10: create-only activation of a prepared import
//
// Turns a runner-verified `PreparedImport` into the ACTIVE database — create-only, never
// replacing an existing active DB — and binds the active slot to an on-disk, per-slot
// OWNER RECORD (`active-activation.json`, Layout A) so ownership of the active database is
// a recorded fact, never an inference from byte identity (two different imports can produce
// byte-identical prepared DBs).
//
// TRUST MODEL. The prepared DB is read ONLY through `prepared.artifactHandle` (the bound
// inode) — `preparedDatabaseURL` is never a trust input. The candidate and the owner record
// are created and kept as `BoundRegularFile`s (RAII regular-file inode bindings), published
// with same-directory `renameatx_np(RENAME_EXCL)`, and every path-observable step is bracketed
// by point-in-time gates on the bound inodes. Everything here is INTERNAL: no raw fd, no
// DirectoryHandle, no handle type ever crosses out of SoloLedgerCore, and there is no public
// API surface (a future coordinator maps these errors/results to public types).
//
// OWNER RECORD PERMANENCE. `active-activation.json` is published atomically (hidden temp →
// bound write-back verify → file sync → RENAME_EXCL → dir sync) and, once published, is NEVER
// deleted or overwritten by any C10 path — candidate failure, lost races, thrown hooks and
// process crashes all leave it in place ("record present, active absent" is the OFFICIAL
// resumable state, not residue). Removing or replacing it belongs to a future, explicitly
// designed replace/reset/recovery operation.
//
// DURABILITY (best-effort power-loss). File barriers use `fcntl(F_FULLFSYNC)` (fail closed
// for data files); directory-entry barriers use F_FULLFSYNC with a documented
// EINVAL/ENOTSUP → `fsync(dirfd)` fallback. Even F_FULLFSYNC is subject to drive-firmware and
// filesystem behavior, so this is deliberately called BEST-EFFORT power-loss durability —
// never an absolute guarantee, and never "fully atomic". Cross-file consistency (record vs
// active) comes from the resumable state machine, not from any single atomic operation.
// Process-crash safety holds independently of the barriers (RENAME_EXCL is atomic for the
// namespace; a crash leaves either the temp/candidate or the published object, never a
// half-written FINAL record). If the post-publish directory barrier fails, activation throws
// `durabilityNotConfirmed` WITHOUT returning a result: the active DB and record exist and are
// process-crash safe, but the caller must NOT treat activation as complete (and must not open
// LedgerStore); the next activate() run re-enters the reuse path and REDOES the barriers.
//
// REGISTERED RESIDUALS (same-UID, point-in-time — same class as C6–C9): the
// fingerprint→rename and gate→rename adjacent-syscall windows cannot be closed on Darwin
// (detection is post-hoc and fail-closed, not preventive); a byte-identical inode swap of the
// candidate is undetectable by re-hash and functionally equivalent; private (0700) placement
// of the active parent directory is the CALLer's contract, not verified here; there is no
// cross-process lock — concurrent activators are serialized by the two RENAME_EXCL gates
// (record, active), so the worst outcome is a clean conflict/retry, never corruption.

// MARK: - Bound regular file (RAII inode binding)

/// RAII binding of ONE regular-file inode: the fd is opened no-follow, fstat-verified
/// S_IFREG, and its device+inode are captured at bind time. Every read/hash/decode/sync
/// goes through THIS fd — a rename or swap of the NAME cannot redirect them (an fd tracks
/// the inode, not the name). The path is a diagnostics hint only. The fd is owned and
/// closed deterministically on deinit; it is never exposed. NOT Sendable — must not cross
/// concurrency domains.
final class BoundRegularFile {
    let device: Int32
    let inode: UInt64
    private let fd: Int32
    private let pathHint: String   // diagnostics only; never used for I/O after bind

    private init(fd: Int32, device: Int32, inode: UInt64, pathHint: String) {
        self.fd = fd; self.device = device; self.inode = inode; self.pathHint = pathHint
    }
    deinit { close(fd) }

    /// Bind an EXISTING direct child regular file of `parent` (openat O_RDONLY|O_NOFOLLOW|
    /// O_NONBLOCK, fstat S_IFREG on the OPEN fd). Never re-trusts a URL. A symlink at the
    /// name fails ELOOP; a directory/special file fails notARegularFile.
    static func open(in parent: DirectoryHandle, named name: String) throws -> BoundRegularFile {
        let f = openat(parent.fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard f >= 0 else {
            let e = errno
            if e == ELOOP { throw FileHashError.notARegularFile(name + " (symlink)") }
            throw FileHashError.unreadable(path: name, errno: e)
        }
        return try adopt(fd: f, pathHint: name)
    }

    /// Create a direct child EXCLUSIVELY (openat O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW, 0600),
    /// write `contents` through the SAME fd, and return the still-open binding — the handle
    /// never goes through a close-and-reopen-by-name cycle, so it is bound to the inode this
    /// call created (no first-observed-inode gap). A failed write unlinks only this call's
    /// own creation (and only while the name still resolves to it).
    static func create(in parent: DirectoryHandle, named name: String, contents: Data) throws -> BoundRegularFile {
        let handle = try createEmpty(in: parent, named: name)
        do { try handle.writeChunk(contents) }
        catch { handle.unlinkIfStillBound(named: name, in: parent); throw error }
        return handle
    }

    /// Stream `source` into an exclusively-created direct child through the created fd
    /// (same no-reopen guarantee as `create`), returning the binding AND the digest of
    /// exactly the bytes written.
    static func importing(from source: FileHandle, into parent: DirectoryHandle, named name: String,
                          chunkSize: Int = 1 << 20) throws -> (file: BoundRegularFile, digest: RegularFileDigest) {
        let handle = try createEmpty(in: parent, named: name)
        do {
            let digest = try FileHash.streamDigest(from: source, chunkSize: chunkSize) { try handle.writeChunk($0) }
            return (handle, digest)
        } catch {
            handle.unlinkIfStillBound(named: name, in: parent)
            throw error
        }
    }

    private static func createEmpty(in parent: DirectoryHandle, named name: String) throws -> BoundRegularFile {
        let f = openat(parent.fd, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard f >= 0 else { throw FileHashError.destinationUnwritable(path: name, errno: errno) }
        return try adopt(fd: f, pathHint: name)
    }

    private static func adopt(fd f: Int32, pathHint: String) throws -> BoundRegularFile {
        var st = stat()
        guard fstat(f, &st) == 0 else { let e = errno; close(f); throw FileHashError.unreadable(path: pathHint, errno: e) }
        guard (st.st_mode & S_IFMT) == S_IFREG else { close(f); throw FileHashError.notARegularFile(pathHint) }
        _ = fcntl(f, F_SETFL, 0)   // drop O_NONBLOCK where set; regular-file I/O ignores it anyway
        return BoundRegularFile(fd: f, device: Int32(st.st_dev), inode: UInt64(st.st_ino), pathHint: pathHint)
    }

    /// Owner-record hard size ceiling. The record is a tiny fixed-shape JSON; a larger file
    /// at that name is malformed/hostile and must never be slurped unbounded.
    static let maxRecordBytes = 64 * 1024

    /// Whole-file read through the bound fd (never by name), capped at `maxBytes`. The ceiling
    /// is enforced CONTINUOUSLY during the read (a growing/streamed file cannot bypass it), and
    /// exceeding it is fail-closed, never a truncated success.
    func readAll(maxBytes: Int = BoundRegularFile.maxRecordBytes) throws -> Data {
        guard lseek(fd, 0, SEEK_SET) == 0 else { throw FileHashError.unreadable(path: pathHint, errno: errno) }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let n = read(fd, &buf, buf.count)
            if n == 0 { break }
            if n < 0 {
                let e = errno
                if e == EINTR { continue }
                throw FileHashError.unreadable(path: pathHint, errno: e)
            }
            guard out.count + n <= maxBytes else {
                throw FileHashError.unreadable(path: pathHint + " (exceeds \(maxBytes)-byte cap)", errno: EFBIG)
            }
            out.append(contentsOf: buf[0..<n])
        }
        return out
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: try readAll())
    }

    /// Streaming SHA-256 (lowercase hex) of the CURRENT bytes, read through the bound fd —
    /// a name swap cannot redirect this; only writes to this very inode change it.
    func rehashSHA256() throws -> String {
        guard lseek(fd, 0, SEEK_SET) == 0 else { throw FileHashError.unreadable(path: pathHint, errno: errno) }
        var hasher = SHA256()
        var buf = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let n = read(fd, &buf, buf.count)
            if n == 0 { break }
            if n < 0 {
                let e = errno
                if e == EINTR { continue }
                throw FileHashError.unreadable(path: pathHint, errno: e)
            }
            hasher.update(data: Data(bytes: buf, count: n))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// POINT-IN-TIME: does `name` under `parent` currently resolve (no-follow) to THIS
    /// bound inode as a regular file? Metadata errors propagate (callers fail closed).
    func matchesChild(named name: String, in parent: DirectoryHandle) throws -> Bool {
        guard let fp = try parent.fingerprint(named: name) else { return false }
        return fp.isRegularFile && fp.device == device && fp.inode == inode
    }

    /// File-data barrier: `fcntl(F_FULLFSYNC)` on the bound fd, EINTR retried. Data files
    /// get NO fallback — silently degrading the data barrier would fake durability — so any
    /// other errno fails closed (the activator classifies retriability).
    func syncToDisk() throws {
        while true {
            if fcntl(fd, F_FULLFSYNC) == 0 { return }
            let e = errno
            if e == EINTR { continue }
            throw FileHashError.unreadable(path: pathHint + " (F_FULLFSYNC)", errno: e)
        }
    }

    /// Best-effort cleanup of OUR OWN creation: unlink `name` ONLY while it still resolves
    /// to this bound inode as a regular file. A swapped/replaced/foreign entry is left
    /// untouched; never recursive.
    func unlinkIfStillBound(named name: String, in parent: DirectoryHandle) {
        guard let fp = try? parent.fingerprint(named: name), fp.isRegularFile,
              fp.device == device, fp.inode == inode else { return }
        _ = unlinkat(parent.fd, name, 0)
    }

    fileprivate func writeChunk(_ data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var off = 0
            while off < raw.count {
                let n = write(fd, base.advanced(by: off), raw.count - off)
                if n < 0 {
                    let e = errno
                    if e == EINTR { continue }
                    throw FileHashError.destinationUnwritable(path: pathHint, errno: e)
                }
                // A 0-byte write with bytes remaining is anomalous — fail closed rather than spin.
                if n == 0 { throw FileHashError.destinationUnwritable(path: pathHint + " (write returned 0)", errno: EIO) }
                off += n
            }
        }
    }
}

// MARK: - Directory-entry durability barrier

/// Which sync method the directory-entry barrier actually used (reported by tests so the
/// target-platform behavior is observable, not assumed).
enum DirSyncMethod: Equatable { case fullFsync, fsyncFallback }

/// Directory-entry barrier: F_FULLFSYNC on the bound directory fd (EINTR retried). On
/// EINVAL/ENOTSUP — filesystems that reject F_FULLFSYNC on directory fds — falls back to
/// plain `fsync(dirfd)`, which is WEAKER (no drive-cache flush); either way the result is
/// only ever described as best-effort power-loss durability. Any other failure (including a
/// failing fallback) throws — never misreported as success.
@discardableResult
func fsyncDirectoryEntry(_ parent: DirectoryHandle, pathHint: String) throws -> DirSyncMethod {
    while true {
        if fcntl(parent.fd, F_FULLFSYNC) == 0 { return .fullFsync }
        let e = errno
        if e == EINTR { continue }
        if e == EINVAL || e == ENOTSUP {
            while true {
                if fsync(parent.fd) == 0 { return .fsyncFallback }
                let e2 = errno
                if e2 == EINTR { continue }
                throw FileHashError.unreadable(path: pathHint + " (dir fsync fallback)", errno: e2)
            }
        }
        throw FileHashError.unreadable(path: pathHint + " (dir F_FULLFSYNC)", errno: e)
    }
}

// MARK: - Owner record

/// The persistent, per-active-slot OWNERSHIP record (Layout A: a single
/// `active-activation.json` beside the active DB). Binds the active database to the exact
/// import that produced it — importID plus every content identity — because byte identity
/// alone cannot prove ownership. All fields derive deterministically from the
/// `PreparedImport`; there is deliberately no timestamp (it would break the full-field
/// idempotent resume comparison and decides nothing).
struct ActivationRecord: Codable, Equatable {
    static let currentFormatVersion = 1
    var formatVersion: Int
    var importID: String
    var snapshotIdentitySHA256: String
    var attachmentManifestSHA256: String
    var sourceDBSHA256: String
    var walSHA256: String?
    var preparedDBIdentity: String
    var transactionsMigrated: Int

    init(binding prepared: PreparedImport) {
        self.formatVersion = Self.currentFormatVersion
        self.importID = prepared.importID.rawValue
        self.snapshotIdentitySHA256 = prepared.manifest.snapshotIdentitySHA256
        self.attachmentManifestSHA256 = prepared.manifest.attachmentManifestSHA256
        self.sourceDBSHA256 = prepared.manifest.sourceDBSHA256
        self.walSHA256 = prepared.manifest.walSHA256
        self.preparedDBIdentity = prepared.preparedDBIdentity
        self.transactionsMigrated = prepared.transactionsMigrated
    }
}

// MARK: - Sync points, hooks, errors

/// The durability barriers in publication order. `recordFile`/`recordDirEntry` also replay
/// on every resume that adopts an existing record; `activeFile` runs only on the reuse path
/// (the fresh path's candidate sync covers the same bytes pre-rename).
enum ActivationSyncPoint: String, Equatable { case recordFile, recordDirEntry, candidateFile, activeFile, activeDirEntry }

/// Test-only fault seams (internal, no-op by default). `onSync` fires BEFORE the real sync
/// syscall of each barrier; it may throw (deterministic sync-failure injection) or tamper
/// with the disk — which is exactly why every security-critical barrier is followed by a
/// re-verification gate on the bound inodes.
struct ActivationHooks {
    var afterOwnerRecordPublished: ((URL) throws -> Void)?   // fresh record published+synced
    var afterCandidateMaterialized: ((URL) throws -> Void)?  // candidate written, before C1 gate
    var afterActivateRename: ((URL) throws -> Void)?          // active published+synced (crash sim)
    var onSync: ((ActivationSyncPoint) throws -> Void)?
    /// Fires INSIDE the final identity gate, between the post-publish re-hash and the after-hash
    /// envelope re-check — lets a test tamper AFTER the hash to prove the after-hash gate (not
    /// just the before-hash one) catches a name swap / sidecar / owner-record change.
    var afterFinalActiveHash: ((URL) throws -> Void)?
    init(afterOwnerRecordPublished: ((URL) throws -> Void)? = nil,
         afterCandidateMaterialized: ((URL) throws -> Void)? = nil,
         afterActivateRename: ((URL) throws -> Void)? = nil,
         onSync: ((ActivationSyncPoint) throws -> Void)? = nil,
         afterFinalActiveHash: ((URL) throws -> Void)? = nil) {
        self.afterOwnerRecordPublished = afterOwnerRecordPublished
        self.afterCandidateMaterialized = afterCandidateMaterialized
        self.afterActivateRename = afterActivateRename
        self.onSync = onSync
        self.afterFinalActiveHash = afterFinalActiveHash
    }
}

/// Activation failure vocabulary (INTERNAL — a future coordinator maps these to public
/// outcomes). Retriability classes:
///  - RETRIABLE (fail-closed, safe to re-run activate): activeParentUnreadable,
///    activationRecordReadFailed, recordPublishFailed, recordWritebackMismatch,
///    recordNameSwapped, recordPublishedMismatch, recordUnboundDuringActivation,
///    candidateMaterializeFailed, candidateRehashMismatch, candidateNameSwapped,
///    publishRaceLost, publishedActiveMismatch, activePublishFailed, sidecarAppeared,
///    durabilitySyncFailed, durabilityNotConfirmed (re-run completes the barriers via the
///    reuse path).
///  - TERMINAL (needs a human / a future replace/reset operation; the slot and its record
///    are never touched): activeSlotOccupied, activationRecordConflict,
///    activationRecordMalformed, activeIdentityMismatch. `invalidActiveDestination` is also
///    TERMINAL but is a caller/programming error (wrong destination path), not a disk-state
///    conflict.
enum ActivationError: Error, Equatable, CustomStringConvertible {
    case invalidActiveDestination(String)
    case activeParentUnreadable(String)
    case activeSlotOccupied(String)
    case activePublishFailed(String)
    case activationRecordConflict(String)
    case activationRecordReadFailed(String)
    case activationRecordMalformed(String)
    case recordPublishFailed(String)
    case recordWritebackMismatch(String)
    case recordNameSwapped(String)
    case recordPublishedMismatch(String)
    case recordUnboundDuringActivation(String)
    case candidateMaterializeFailed(String)
    case candidateRehashMismatch(String)
    case candidateNameSwapped(String)
    case publishRaceLost(String)
    case publishedActiveMismatch(String)
    case sidecarAppeared(String)
    case activeIdentityMismatch(expected: String, actual: String)
    case durabilitySyncFailed(ActivationSyncPoint, String)
    case durabilityNotConfirmed(String)

    var description: String {
        switch self {
        case .invalidActiveDestination(let m): return "Invalid active destination (must be a direct child named \(AppPaths.databaseFileName)): \(m)"
        case .activeParentUnreadable(let m): return "Active parent directory is unreadable / not a directory: \(m)"
        case .activeSlotOccupied(let m): return "The active slot is occupied (create-only refuses to touch it): \(m)"
        case .activePublishFailed(let m): return "Publishing the active database failed: \(m)"
        case .activationRecordConflict(let m): return "The active slot is owned by a different import (owner record mismatch): \(m)"
        case .activationRecordReadFailed(let m): return "Owner record could not be read (transient — retry): \(m)"
        case .activationRecordMalformed(let m): return "Owner record is malformed/unsupported (terminal — needs recovery): \(m)"
        case .recordPublishFailed(let m): return "Owner record publication failed: \(m)"
        case .recordWritebackMismatch(let m): return "Owner record bound read-back does not match the expected record: \(m)"
        case .recordNameSwapped(let m): return "Owner record temp entry no longer resolves to the bound inode: \(m)"
        case .recordPublishedMismatch(let m): return "Published owner record name does not resolve to the bound inode: \(m)"
        case .recordUnboundDuringActivation(let m): return "Owner record was swapped/changed during activation (failing closed): \(m)"
        case .candidateMaterializeFailed(let m): return "Active candidate could not be materialized from the prepared artifact: \(m)"
        case .candidateRehashMismatch(let m): return "Active candidate bytes changed after materialization (bound re-hash mismatch): \(m)"
        case .candidateNameSwapped(let m): return "Active candidate entry no longer resolves to the bound inode: \(m)"
        case .publishRaceLost(let m): return "Another activation won the active slot (retry to adopt/reuse): \(m)"
        case .publishedActiveMismatch(let m): return "The active name does not resolve to the published candidate inode: \(m)"
        case .sidecarAppeared(let m): return "A database sidecar appeared in the active slot (activation incomplete — do not open the store): \(m)"
        case let .activeIdentityMismatch(expected, actual): return "Active database identity \(actual) does not match the owner record \(expected)"
        case let .durabilitySyncFailed(point, m): return "Durability barrier failed at \(point.rawValue) (retry): \(m)"
        case .durabilityNotConfirmed(let m): return "Active is published and process-crash safe, but the post-publish directory barrier failed — activation NOT complete, do not open the store; re-run to redo the barriers: \(m)"
        }
    }
}

// MARK: - Activated database (result evidence)

/// Evidence that the active slot holds THIS import's database. While this value is alive,
/// C11 (finalize) gets: (a) `activeFile` — a bound fd to the very inode published as the
/// active DB, usable for point-in-time inode checks (`matchesChild`) and bound re-hashing;
/// (b) `activeParent` — the bound parent directory for fd-relative gates; (c)
/// `boundOwnerRecord` — the bound owner record for ownership re-verification. RESIDUAL
/// carried forward to C11: SQLite itself opens the active DB BY PATH (no openat), so C11's
/// apply/audit remain path-based with these handles as point-in-time brackets — never a full
/// descriptor closure. `activeDatabaseURL` is a location hint ONLY (same contract as
/// `PreparedImport.preparedDatabaseURL`), and all fds die with this value (deinit) — after a
/// crash, ownership is re-derived from the on-disk record, never from remembered handles.
struct ActivatedDatabase {
    let importID: ImportID
    let activeDatabaseURL: URL
    let preparedDBIdentity: String
    let transactionsMigrated: Int
    /// True when a matching owner record AND a matching active DB already existed — the
    /// reuse path re-ran the durability barriers and every gate before returning.
    let reusedExisting: Bool
    let activeParent: DirectoryHandle
    let activeFile: BoundRegularFile
    let boundOwnerRecord: BoundRegularFile

    init(importID: ImportID, activeDatabaseURL: URL, preparedDBIdentity: String,
         transactionsMigrated: Int, reusedExisting: Bool,
         activeParent: DirectoryHandle, activeFile: BoundRegularFile, boundOwnerRecord: BoundRegularFile) {
        self.importID = importID
        self.activeDatabaseURL = activeDatabaseURL
        self.preparedDBIdentity = preparedDBIdentity
        self.transactionsMigrated = transactionsMigrated
        self.reusedExisting = reusedExisting
        self.activeParent = activeParent
        self.activeFile = activeFile
        self.boundOwnerRecord = boundOwnerRecord
    }
}

// MARK: - The activator

struct PreparedImportActivator {
    static let recordName = "active-activation.json"
    static let recordTempPrefix = ".active-record-candidate-"
    static let candidatePrefix = ".active-candidate-"
    static let sidecarSuffixes = ["-wal", "-shm", "-journal"]

    init() {}

    /// Create-only activation. See the file header for the full contract. `hooks` is a
    /// test-only fault seam.
    func activate(_ prepared: PreparedImport, activeDestination: URL,
                  hooks: ActivationHooks = ActivationHooks()) throws -> ActivatedDatabase {
        let parentURL = activeDestination.deletingLastPathComponent()
        let activeName = activeDestination.lastPathComponent
        // The active DB must be a DIRECT child named exactly sololedger.db — reject "."/".."/
        // empty / a name that does not round-trip as a direct child (defense in depth; the
        // caller supplies this path).
        guard activeName == AppPaths.databaseFileName,
              parentURL.appendingPathComponent(activeName).standardizedFileURL == activeDestination.standardizedFileURL else {
            throw ActivationError.invalidActiveDestination(activeDestination.path)
        }
        guard prepared.preparedDBIdentity.hasPrefix("sha256:") else {
            throw ActivationError.candidateMaterializeFailed("unexpected preparedDBIdentity format")
        }
        let identityHex = String(prepared.preparedDBIdentity.dropFirst("sha256:".count))
        let expected = ActivationRecord(binding: prepared)

        let parent: DirectoryHandle
        do { parent = try DirectoryHandle.open(at: parentURL) }
        catch { throw ActivationError.activeParentUnreadable("\(error)") }

        // ---- Owner record: probe → adopt (with barrier replay) or publish (two-phase) ----
        let recFP: FileFingerprint?
        do { recFP = try parent.fingerprint(named: Self.recordName) }
        catch { throw ActivationError.activationRecordReadFailed("record fingerprint: \(error)") }

        let boundRec: BoundRegularFile
        if let fp = recFP {
            guard fp.isRegularFile else {
                throw ActivationError.activationRecordMalformed("owner record entry is not a regular file")
            }
            boundRec = try Self.adoptExistingRecord(in: parent, parentURL: parentURL, expected: expected, hooks: hooks)
        } else {
            // State 5: an active DB with NO owner record. Ownership must never be inferred
            // from byte identity — fail closed and leave everything untouched.
            if try Self.slotFingerprint(named: activeName, in: parent) != nil {
                throw ActivationError.activationRecordConflict(
                    "an active database exists without an owner record — ownership cannot be inferred from bytes")
            }
            // Fresh: create-only gate ① BEFORE creating anything (main + all sidecars absent).
            try Self.assertSlotEmpty(activeName: activeName, in: parent, includeMain: true)
            boundRec = try Self.publishOwnerRecord(in: parent, parentURL: parentURL, expected: expected, hooks: hooks)
            try hooks.afterOwnerRecordPublished?(parentURL.appendingPathComponent(Self.recordName))
        }

        // ---- Active slot: reuse (state 3) or materialize+publish (states 1/2) ----
        if try Self.slotFingerprint(named: activeName, in: parent) != nil {
            return try Self.reuseExistingActive(prepared: prepared, parent: parent, parentURL: parentURL,
                                                activeName: activeName, activeDestination: activeDestination,
                                                boundRec: boundRec, expected: expected,
                                                identityHex: identityHex, hooks: hooks)
        }
        try Self.assertSlotEmpty(activeName: activeName, in: parent, includeMain: true)
        return try Self.materializeAndPublish(prepared: prepared, parent: parent, parentURL: parentURL,
                                              activeName: activeName, activeDestination: activeDestination,
                                              boundRec: boundRec, expected: expected,
                                              identityHex: identityHex, hooks: hooks)
    }

    // MARK: Owner record

    /// Adopt an EXISTING final owner record: bind it (openat, no-follow — never
    /// Data(contentsOf:)), decode from the bound fd, compare FULL-FIELD against `expected`,
    /// then REPLAY the record durability barrier (file + dir entry) with post-sync
    /// re-verification — so a barrier that failed in an earlier run is actually repaired
    /// before anything else proceeds.
    private static func adoptExistingRecord(in parent: DirectoryHandle, parentURL: URL,
                                            expected: ActivationRecord, hooks: ActivationHooks) throws -> BoundRegularFile {
        let rec: BoundRegularFile
        do { rec = try BoundRegularFile.open(in: parent, named: recordName) }
        catch let e as FileHashError {
            if case .notARegularFile = e { throw ActivationError.activationRecordMalformed("\(e)") }
            throw ActivationError.activationRecordReadFailed("\(e)")
        }
        catch { throw ActivationError.activationRecordReadFailed("\(error)") }

        let existing = try decodeRecord(rec)
        guard existing == expected else {
            throw ActivationError.activationRecordConflict("existing owner record belongs to a different import/identity")
        }
        try sync(.recordFile, hooks: hooks) { try rec.syncToDisk() }
        try assertRecordStillBound(rec, expected: expected, named: recordName, in: parent)
        try sync(.recordDirEntry, hooks: hooks) { try fsyncDirectoryEntry(parent, pathHint: parentURL.path) }
        try assertRecordStillBound(rec, expected: expected, named: recordName, in: parent)
        return rec
    }

    /// Two-phase atomic publication of a FRESH owner record: hidden temp (bound create, no
    /// reopen) → bound write-back verify → file barrier (+ post-sync re-verify: the onSync
    /// hook may tamper) → same-directory RENAME_EXCL → published-name inode check → dir
    /// barrier (+ re-verify). A crash before the rename leaves only the hidden temp (reaper
    /// residue) — never a half-written FINAL record. Losing the rename race adopts the
    /// winner's record instead (matching ⇒ proceed, else conflict).
    private static func publishOwnerRecord(in parent: DirectoryHandle, parentURL: URL,
                                           expected: ActivationRecord, hooks: ActivationHooks) throws -> BoundRegularFile {
        let payload: Data
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            payload = try enc.encode(expected)
        } catch { throw ActivationError.recordPublishFailed("record encode: \(error)") }

        let tempName = recordTempPrefix + UUID().uuidString.lowercased() + ".json"
        let rec: BoundRegularFile
        do { rec = try BoundRegularFile.create(in: parent, named: tempName, contents: payload) }
        catch { throw ActivationError.recordPublishFailed("record temp create: \(error)") }
        var published = false
        // Cleanup may touch ONLY the unpublished temp, and only while the name still
        // resolves to our bound inode. The FINAL record is never deleted by any path.
        defer { if !published { rec.unlinkIfStillBound(named: tempName, in: parent) } }

        guard (try? rec.decode(ActivationRecord.self)) == expected else {
            throw ActivationError.recordWritebackMismatch("bound read-back != expected record")
        }
        try sync(.recordFile, hooks: hooks) { try rec.syncToDisk() }
        // Post-sync re-verify (the onSync hook may have tampered via the path — same inode).
        guard (try? rec.matchesChild(named: tempName, in: parent)) == true else {
            throw ActivationError.recordNameSwapped(tempName)
        }
        guard (try? rec.decode(ActivationRecord.self)) == expected else {
            throw ActivationError.recordWritebackMismatch("record content changed after the file barrier")
        }

        let ok: Bool
        do { ok = try parent.renameChildExclusively(from: tempName, to: recordName) }
        catch { throw ActivationError.recordPublishFailed("record rename: \(error)") }
        guard ok else {
            // Lost the record race — another executor published first. Our temp is cleaned
            // by the defer; adopt the winner's record (full-field compare inside).
            return try adoptExistingRecord(in: parent, parentURL: parentURL, expected: expected, hooks: hooks)
        }
        published = true
        guard (try? rec.matchesChild(named: recordName, in: parent)) == true else {
            throw ActivationError.recordPublishedMismatch(recordName)
        }
        try sync(.recordDirEntry, hooks: hooks) { try fsyncDirectoryEntry(parent, pathHint: parentURL.path) }
        try assertRecordStillBound(rec, expected: expected, named: recordName, in: parent)
        return rec
    }

    private static func decodeRecord(_ rec: BoundRegularFile) throws -> ActivationRecord {
        let data: Data
        do { data = try rec.readAll() }
        catch let e as FileHashError {
            // Exceeding the size cap is a MALFORMED/hostile record (terminal), not a transient
            // read error — retrying would not help.
            if case .unreadable(_, let errno) = e, errno == EFBIG {
                throw ActivationError.activationRecordMalformed("owner record exceeds the \(BoundRegularFile.maxRecordBytes)-byte cap")
            }
            throw ActivationError.activationRecordReadFailed("\(e)")
        }
        catch { throw ActivationError.activationRecordReadFailed("\(error)") }
        let decoded: ActivationRecord
        do { decoded = try JSONDecoder().decode(ActivationRecord.self, from: data) }
        catch { throw ActivationError.activationRecordMalformed("undecodable owner record: \(error)") }
        guard decoded.formatVersion == ActivationRecord.currentFormatVersion else {
            throw ActivationError.activationRecordMalformed("unsupported owner-record formatVersion \(decoded.formatVersion)")
        }
        return decoded
    }

    // MARK: Candidate → active (states 1/2)

    private static func materializeAndPublish(prepared: PreparedImport, parent: DirectoryHandle, parentURL: URL,
                                              activeName: String, activeDestination: URL,
                                              boundRec: BoundRegularFile, expected: ActivationRecord,
                                              identityHex: String, hooks: ActivationHooks) throws -> ActivatedDatabase {
        // fd→fd: source through the BOUND artifact handle (never the URL), destination
        // through the created candidate fd (no close-and-reopen).
        let candName = candidatePrefix + UUID().uuidString.lowercased() + ".db"
        let src: FileHandle
        do { src = try prepared.artifactHandle.openRegularFile(named: AppPaths.databaseFileName) }
        catch { throw ActivationError.candidateMaterializeFailed("artifact open: \(error)") }
        defer { try? src.close() }

        let cand: BoundRegularFile
        let digest: RegularFileDigest
        do { (cand, digest) = try BoundRegularFile.importing(from: src, into: parent, named: candName) }
        catch { throw ActivationError.candidateMaterializeFailed("candidate import: \(error)") }
        var candPublished = false
        defer { if !candPublished { cand.unlinkIfStillBound(named: candName, in: parent) } }

        guard digest.sha256 == identityHex else {
            throw ActivationError.candidateMaterializeFailed("candidate digest != preparedDBIdentity")
        }
        try hooks.afterCandidateMaterialized?(parentURL.appendingPathComponent(candName))

        // C1 gate (post-hook): bound re-hash + name binding + owner record still ours.
        guard try cand.rehashSHA256() == identityHex else {
            throw ActivationError.candidateRehashMismatch("after the materialize hook")
        }
        guard (try? cand.matchesChild(named: candName, in: parent)) == true else {
            throw ActivationError.candidateNameSwapped(candName)
        }
        try assertRecordStillBound(boundRec, expected: expected, named: recordName, in: parent)

        try sync(.candidateFile, hooks: hooks) { try cand.syncToDisk() }
        // C2 gate (post-sync — the onSync hook may have tampered): re-hash, name binding,
        // owner record, and the create-only slot gate, all again, right before the rename.
        guard try cand.rehashSHA256() == identityHex else {
            throw ActivationError.candidateRehashMismatch("after the candidate file barrier")
        }
        guard (try? cand.matchesChild(named: candName, in: parent)) == true else {
            throw ActivationError.candidateNameSwapped(candName)
        }
        try assertRecordStillBound(boundRec, expected: expected, named: recordName, in: parent)
        if try slotFingerprint(named: activeName, in: parent) != nil {
            throw ActivationError.publishRaceLost("an active database appeared before publish")
        }
        for s in sidecarSuffixes where try slotFingerprint(named: activeName + s, in: parent) != nil {
            throw ActivationError.activeSlotOccupied(activeName + s)
        }

        // Atomic create-only publish: same-directory RENAME_EXCL, never overwrites.
        let ok: Bool
        do { ok = try parent.renameChildExclusively(from: candName, to: activeName) }
        catch { throw ActivationError.activePublishFailed("active rename: \(error)") }
        guard ok else { throw ActivationError.publishRaceLost("an active database appeared during publish") }
        candPublished = true

        // Post-rename gate: the active name must resolve to OUR candidate inode, no sidecar,
        // owner record still ours.
        guard (try? cand.matchesChild(named: activeName, in: parent)) == true else {
            throw ActivationError.publishedActiveMismatch("immediately after publish")
        }
        try assertNoSidecars(activeName: activeName, in: parent)
        try assertRecordStillBound(boundRec, expected: expected, named: recordName, in: parent)

        try sync(.activeDirEntry, hooks: hooks) { try fsyncDirectoryEntry(parent, pathHint: parentURL.path) }
        guard (try? cand.matchesChild(named: activeName, in: parent)) == true else {
            throw ActivationError.publishedActiveMismatch("after the directory barrier")
        }
        try assertNoSidecars(activeName: activeName, in: parent)
        try assertRecordStillBound(boundRec, expected: expected, named: recordName, in: parent)

        try hooks.afterActivateRename?(activeDestination)
        // FINAL identity gate — AFTER the dir barrier AND the afterActivateRename hook, before
        // return: the published active must (still) be the bound inode, sidecar-free, owner
        // record intact, AND its bytes re-hash to preparedDBIdentity (a post-publish tamper of
        // the very inode is caught here, not just a pre-hash name swap).
        try Self.assertActiveStillBoundAndIdentical(
            active: cand, activeName: activeName, identityHex: identityHex,
            ownerRecord: boundRec, expected: expected, in: parent,
            afterHash: hooks.afterFinalActiveHash.map { hook in { try hook(activeDestination) } })

        return ActivatedDatabase(importID: prepared.importID, activeDatabaseURL: activeDestination,
                                 preparedDBIdentity: prepared.preparedDBIdentity,
                                 transactionsMigrated: prepared.transactionsMigrated,
                                 reusedExisting: false, activeParent: parent,
                                 activeFile: cand, boundOwnerRecord: boundRec)
    }

    // MARK: Reuse (state 3)

    /// A matching owner record AND an existing active DB: bind the active file, verify
    /// identity from the bound fd, REPLAY the active durability barriers (file + dir entry)
    /// with post-sync gates, and only return `reusedExisting: true` after a full final gate.
    /// This is also the REPAIR path after `durabilityNotConfirmed`.
    private static func reuseExistingActive(prepared: PreparedImport, parent: DirectoryHandle, parentURL: URL,
                                            activeName: String, activeDestination: URL,
                                            boundRec: BoundRegularFile, expected: ActivationRecord,
                                            identityHex: String, hooks: ActivationHooks) throws -> ActivatedDatabase {
        let active: BoundRegularFile
        do { active = try BoundRegularFile.open(in: parent, named: activeName) }
        catch let e as FileHashError {
            if case .notARegularFile = e { throw ActivationError.activeSlotOccupied("\(activeName): \(e)") }
            if e.isFileMissing { throw ActivationError.publishRaceLost("active vanished — retry") }
            throw ActivationError.activeSlotOccupied("\(activeName): \(e)")
        }
        catch { throw ActivationError.activeSlotOccupied("\(activeName): \(error)") }

        try assertNoSidecars(activeName: activeName, in: parent)
        try assertRecordStillBound(boundRec, expected: expected, named: recordName, in: parent)
        let hash = try active.rehashSHA256()
        guard "sha256:" + hash == expected.preparedDBIdentity else {
            throw ActivationError.activeIdentityMismatch(expected: expected.preparedDBIdentity, actual: "sha256:" + hash)
        }

        try sync(.activeFile, hooks: hooks) { try active.syncToDisk() }
        guard (try? active.matchesChild(named: activeName, in: parent)) == true else {
            throw ActivationError.publishedActiveMismatch("after the active file barrier")
        }
        try assertRecordStillBound(boundRec, expected: expected, named: recordName, in: parent)

        try sync(.activeDirEntry, hooks: hooks) { try fsyncDirectoryEntry(parent, pathHint: parentURL.path) }
        // FINAL identity gate (same bracketed helper as fresh): envelope → bound re-hash ==
        // preparedDBIdentity → envelope, after the activeDirEntry barrier, before return.
        try Self.assertActiveStillBoundAndIdentical(
            active: active, activeName: activeName, identityHex: identityHex,
            ownerRecord: boundRec, expected: expected, in: parent,
            afterHash: hooks.afterFinalActiveHash.map { hook in { try hook(activeDestination) } })

        return ActivatedDatabase(importID: prepared.importID, activeDatabaseURL: activeDestination,
                                 preparedDBIdentity: prepared.preparedDBIdentity,
                                 transactionsMigrated: prepared.transactionsMigrated,
                                 reusedExisting: true, activeParent: parent,
                                 activeFile: active, boundOwnerRecord: boundRec)
    }

    // MARK: Gates & helpers

    /// The published active DB's WHOLE ENVELOPE is still ours: the active name resolves to the
    /// bound active inode, none of the three sidecars exist, and the owner record is still
    /// bound + content-matching.
    private static func assertActiveEnvelope(active: BoundRegularFile, activeName: String,
                                             ownerRecord: BoundRegularFile, expected: ActivationRecord,
                                             in parent: DirectoryHandle) throws {
        guard (try? active.matchesChild(named: activeName, in: parent)) == true else {
            throw ActivationError.publishedActiveMismatch("active name no longer resolves to the published inode")
        }
        try assertNoSidecars(activeName: activeName, in: parent)
        try assertRecordStillBound(ownerRecord, expected: expected, named: recordName, in: parent)
    }

    /// FINAL identity gate on the published active DB. Hashing is NOT an adjacent-syscall
    /// window, so it is bracketed by envelopes (active name → bound inode, no sidecar, owner
    /// record bound + matching).
    ///
    /// PRODUCTION (`afterHash == nil`): envelope → bound re-hash == identityHex → envelope.
    /// Exactly one hash — no added cost on the default path.
    ///
    /// TEST SEAM (`afterHash != nil`, the internal `afterFinalActiveHash` hook, which may
    /// tamper the SAME active inode's bytes as well as the name/sidecar/record):
    /// envelope → hash1 → hook → envelope → hash2 → envelope. The post-hook envelope catches a
    /// name/sidecar/owner-record change; the post-hook SECOND hash catches a same-inode byte
    /// rewrite; hash2 is itself bracketed by envelopes before and after.
    private static func assertActiveStillBoundAndIdentical(
        active: BoundRegularFile, activeName: String, identityHex: String,
        ownerRecord: BoundRegularFile, expected: ActivationRecord, in parent: DirectoryHandle,
        afterHash: (() throws -> Void)? = nil) throws {
        func envelope() throws {
            try assertActiveEnvelope(active: active, activeName: activeName, ownerRecord: ownerRecord, expected: expected, in: parent)
        }
        func hash() throws {
            guard try active.rehashSHA256() == identityHex else {
                throw ActivationError.activeIdentityMismatch(expected: "sha256:" + identityHex, actual: "sha256:(changed)")
            }
        }
        try envelope()
        try hash()
        guard let afterHash else { try envelope(); return }   // production: one hash, bracketed
        try afterHash()
        try envelope()   // catches a post-hook name/sidecar/owner-record change
        try hash()       // catches a post-hook same-inode byte rewrite
        try envelope()   // hash2 bracketed after
    }

    /// The owner record must STILL be ours: the final name resolves to the bound inode AND
    /// the bound fd decodes to exactly the expected record. Point-in-time (registered
    /// residual): it detects a swap/change that already happened, it cannot pin the name.
    private static func assertRecordStillBound(_ rec: BoundRegularFile, expected: ActivationRecord,
                                               named name: String, in parent: DirectoryHandle) throws {
        guard (try? rec.matchesChild(named: name, in: parent)) == true else {
            throw ActivationError.recordUnboundDuringActivation("'\(name)' no longer resolves to the bound owner record")
        }
        guard (try? rec.decode(ActivationRecord.self)) == expected else {
            throw ActivationError.recordUnboundDuringActivation("owner record content changed")
        }
    }

    /// lstat-level slot probe: nil ⇔ definitively absent (ENOENT); ANY metadata error is
    /// fail-closed as occupied (constraint: regular/symlink/directory/metadata error all
    /// fail closed, and nothing not created by this run is ever deleted).
    private static func slotFingerprint(named name: String, in parent: DirectoryHandle) throws -> FileFingerprint? {
        do { return try parent.fingerprint(named: name) }
        catch { throw ActivationError.activeSlotOccupied("\(name): metadata error (failing closed): \(error)") }
    }

    private static func assertSlotEmpty(activeName: String, in parent: DirectoryHandle, includeMain: Bool) throws {
        if includeMain, try slotFingerprint(named: activeName, in: parent) != nil {
            throw ActivationError.activeSlotOccupied(activeName)
        }
        for s in sidecarSuffixes where try slotFingerprint(named: activeName + s, in: parent) != nil {
            throw ActivationError.activeSlotOccupied(activeName + s)
        }
    }

    private static func assertNoSidecars(activeName: String, in parent: DirectoryHandle) throws {
        for s in sidecarSuffixes {
            let name = activeName + s
            let fp: FileFingerprint?
            do { fp = try parent.fingerprint(named: name) }
            catch { throw ActivationError.sidecarAppeared("\(name): metadata error (failing closed): \(error)") }
            if fp != nil { throw ActivationError.sidecarAppeared(name) }
        }
    }

    /// Run one durability barrier: the test seam fires FIRST (it may throw to inject a
    /// failure, or tamper — post-sync gates re-verify), then the real barrier. A failure at
    /// `activeDirEntry` maps to `durabilityNotConfirmed` (the active is published and
    /// process-crash safe but activation is NOT complete); every other point maps to the
    /// retriable `durabilitySyncFailed`.
    private static func sync(_ point: ActivationSyncPoint, hooks: ActivationHooks,
                             _ body: () throws -> Void) throws {
        do {
            try hooks.onSync?(point)
            try body()
        } catch {
            if point == .activeDirEntry { throw ActivationError.durabilityNotConfirmed("\(point.rawValue): \(error)") }
            throw ActivationError.durabilitySyncFailed(point, "\(error)")
        }
    }
}
