import Foundation
import CryptoKit

// MARK: - Streaming file hash

public enum FileHashError: Error, CustomStringConvertible, Equatable {
    /// The path names something other than a regular file — a symlink (O_NOFOLLOW),
    /// directory, FIFO or other special file. Refusing to hash it.
    case notARegularFile(String)
    /// The path names something other than a real directory — a symlinked directory
    /// (O_NOFOLLOW|O_DIRECTORY), a file, or a special entry.
    case notADirectory(String)
    case unreadable(path: String, errno: Int32)
    /// The copy destination could not be created EXCLUSIVELY (it already exists — even as
    /// a dangling symlink — or the create failed). The primitive never overwrites and
    /// never follows a link at the destination.
    case destinationUnwritable(path: String, errno: Int32)

    public var description: String {
        switch self {
        case .notARegularFile(let p): return "Not a regular file (symlink/directory/special): \(p)"
        case .notADirectory(let p): return "Not a real directory (symlink/file/special): \(p)"
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
    public var isSymbolicLink: Bool { fileType == UInt16(S_IFLNK) }

    init(stat st: stat) {
        self.init(fileType: UInt16(st.st_mode) & UInt16(S_IFMT),
                  device: Int32(st.st_dev), inode: UInt64(st.st_ino),
                  size: Int64(st.st_size),
                  mtimeSec: Int64(st.st_mtimespec.tv_sec), mtimeNSec: Int64(st.st_mtimespec.tv_nsec),
                  ctimeSec: Int64(st.st_ctimespec.tv_sec), ctimeNSec: Int64(st.st_ctimespec.tv_nsec))
    }

    init(fileType: UInt16, device: Int32, inode: UInt64, size: Int64,
         mtimeSec: Int64, mtimeNSec: Int64, ctimeSec: Int64, ctimeNSec: Int64) {
        self.fileType = fileType; self.device = device; self.inode = inode; self.size = size
        self.mtimeSec = mtimeSec; self.mtimeNSec = mtimeNSec
        self.ctimeSec = ctimeSec; self.ctimeNSec = ctimeNSec
    }

    /// nil ⇔ the path is definitively absent (ENOENT). Never follows symlinks — a symlink
    /// fingerprints as the link itself (fileType S_IFLNK).
    public static func capture(at url: URL) throws -> FileFingerprint? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else {
            let e = errno
            if e == ENOENT { return nil }
            throw FileHashError.unreadable(path: url.path, errno: e)
        }
        return FileFingerprint(stat: st)
    }
}

// MARK: - Descriptor-bound directory

/// A directory opened O_NOFOLLOW|O_DIRECTORY (a symlinked directory fails with ELOOP,
/// anything else with ENOTDIR), verified and identity-bound (device+inode) on the OPEN
/// descriptor. Every member operation runs RELATIVE TO THIS DESCRIPTOR
/// (openat/fstatat/unlinkat), so once bound, no path component substitution — the
/// directory itself, a parent, or an entry — can redirect reads, writes or checks.
final class DirectoryHandle {
    let fd: Int32
    let device: Int32
    let inode: UInt64
    private let pathHint: String   // diagnostics only; never used for I/O after open

    private init(fd: Int32, device: Int32, inode: UInt64, pathHint: String) {
        self.fd = fd; self.device = device; self.inode = inode; self.pathHint = pathHint
    }
    deinit { close(fd) }

    private static func adopt(fd: Int32, pathHint: String) throws -> DirectoryHandle {
        var st = stat()
        guard fstat(fd, &st) == 0 else {
            let e = errno; close(fd)
            throw FileHashError.unreadable(path: pathHint, errno: e)
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR else {
            close(fd)
            throw FileHashError.notADirectory(pathHint)
        }
        return DirectoryHandle(fd: fd, device: Int32(st.st_dev), inode: UInt64(st.st_ino), pathHint: pathHint)
    }

    static func open(at url: URL) throws -> DirectoryHandle {
        let fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else {
            let e = errno
            if e == ELOOP || e == ENOTDIR { throw FileHashError.notADirectory(url.path) }
            throw FileHashError.unreadable(path: url.path, errno: e)
        }
        return try adopt(fd: fd, pathHint: url.path)
    }

    /// Open a DIRECT child directory of this descriptor, no-follow.
    func subdirectory(named name: String) throws -> DirectoryHandle {
        let hint = pathHint + "/" + name
        let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard child >= 0 else {
            let e = errno
            if e == ELOOP || e == ENOTDIR { throw FileHashError.notADirectory(hint) }
            throw FileHashError.unreadable(path: hint, errno: e)
        }
        return try Self.adopt(fd: child, pathHint: hint)
    }

    /// N7.1 (§3.3): open THIS descriptor's PARENT directory. A deliberately NARROW wrapper —
    /// the `".."` name is FIXED here and never caller-supplied, so parent traversal is an
    /// explicit primitive rather than a path string smuggled through the child API above
    /// (whose documented semantics are "direct child"). `".."` is a real directory entry
    /// (never a symlink), so O_NOFOLLOW never rejects it; the opened fd goes through the same
    /// `fstat`/`adopt` identity binding as every other handle. At the filesystem root the
    /// parent is the root itself — callers walking upward MUST terminate on that
    /// (device, inode) fixpoint plus a fixed maximum depth (see `SelfImportGuard`).
    func parentDirectory() throws -> DirectoryHandle {
        let hint = pathHint + "/.."
        let parent = openat(fd, "..", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else {
            let e = errno
            if e == ELOOP || e == ENOTDIR { throw FileHashError.notADirectory(hint) }
            throw FileHashError.unreadable(path: hint, errno: e)
        }
        return try Self.adopt(fd: parent, pathHint: hint)
    }

    /// The kernel's CURRENT canonical path for this open descriptor (`fcntl(F_GETPATH)`).
    /// fd-based: it needs no path authority and resolves no caller-supplied strings, so a
    /// sandboxed process may call it on any handle it legitimately holds (a Powerbox grant
    /// included). The result only ever NOMINATES containment candidates (`SelfImportGuard`);
    /// every verdict is re-proven by descriptor (device, inode) identity, never by this
    /// string.
    func canonicalPath() throws -> String {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buf) != -1 else {
            throw FileHashError.unreadable(path: pathHint, errno: errno)
        }
        return String(cString: buf)
    }

    /// One step of a directory read. `readdir` distinguishes end-of-directory from an
    /// error ONLY through errno: on EOF it returns NULL and leaves errno unchanged; on an
    /// error (EIO, EBADF, …) it returns NULL and sets errno. Conflating the two would let
    /// a truncated listing pass as complete.
    enum DirStep: Equatable { case entry(String); case end; case failure(Int32) }

    /// Fail-closed accumulation of a directory read. A `.failure` — NULL with a non-zero
    /// errno — THROWS rather than being treated as EOF, so a partial listing (even one
    /// that happens to equal the expected whitelist) can never be mistaken for the whole
    /// directory. Split out from the syscall loop so the errno discipline is unit-testable
    /// without having to provoke a real EIO.
    static func collectEntries(pathHint: String, next: () -> DirStep) throws -> [String] {
        var names: [String] = []
        loop: while true {
            switch next() {
            case .entry(let name):
                if name != "." && name != ".." { names.append(name) }
            case .end:
                break loop
            case .failure(let e):
                throw FileHashError.unreadable(path: pathHint, errno: e)
            }
        }
        return names.sorted()
    }

    /// One PRODUCTION directory-read step, translating a `readdir` outcome into a
    /// `DirStep`. errno is cleared before the call because `readdir` only SETS errno on an
    /// error and may clobber it on a valid entry, so a single pre-loop reset is
    /// insufficient — it must be cleared before EACH call. A NULL return with errno == 0
    /// is genuine end-of-directory; NULL with errno != 0 is a real error and must NOT be
    /// mistaken for EOF. Internal so this exact syscall→DirStep translation (not merely
    /// the pure accumulator) is unit-testable against a forced `readdir` failure.
    static func nextDirStep(_ dirp: UnsafeMutablePointer<DIR>) -> DirStep {
        errno = 0
        guard let ent = readdir(dirp) else {
            let e = errno
            return e == 0 ? .end : .failure(e)
        }
        let name = withUnsafeBytes(of: ent.pointee.d_name) { raw in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        return .entry(name)
    }

    /// All entry names (sorted, excluding "." / "..") read through the descriptor.
    /// A read error mid-enumeration is fail-closed (throws), never a short EOF.
    func entryNames() throws -> [String] {
        let dupFD = dup(fd)
        guard dupFD >= 0 else { throw FileHashError.unreadable(path: pathHint, errno: errno) }
        guard let dirp = fdopendir(dupFD) else {
            let e = errno; close(dupFD)
            throw FileHashError.unreadable(path: pathHint, errno: e)
        }
        defer { closedir(dirp) }
        rewinddir(dirp)
        return try Self.collectEntries(pathHint: pathHint) { Self.nextDirStep(dirp) }
    }

    /// lstat-equivalent of a DIRECT child via fstatat(AT_SYMLINK_NOFOLLOW).
    /// nil ⇔ ENOENT; other metadata errors throw.
    func fingerprint(named name: String) throws -> FileFingerprint? {
        var st = stat()
        guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
            let e = errno
            if e == ENOENT { return nil }
            throw FileHashError.unreadable(path: pathHint + "/" + name, errno: e)
        }
        return FileFingerprint(stat: st)
    }

    /// Open a DIRECT child as a verified regular file (openat, no-follow, non-blocking).
    func openRegularFile(named name: String) throws -> FileHandle {
        let hint = pathHint + "/" + name
        let f = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard f >= 0 else {
            let e = errno
            if e == ELOOP { throw FileHashError.notARegularFile(hint) }
            throw FileHashError.unreadable(path: hint, errno: e)
        }
        return try FileHash.verifyRegularAndWrap(fd: f, path: hint)
    }

    func digestOfRegularFile(named name: String) throws -> RegularFileDigest {
        let handle = try openRegularFile(named: name)
        defer { try? handle.close() }
        return try FileHash.streamDigest(from: handle, chunkSize: 1 << 20) { _ in }
    }

    /// Copy a DIRECT child regular file THROUGH this descriptor (openat, no-follow,
    /// S_IFREG-verified on the open fd) into an exclusively-created destination
    /// (O_CREAT|O_EXCL|O_NOFOLLOW). Because the source is resolved relative to this bound
    /// directory fd, no swap of the directory or a parent component can redirect the read;
    /// the returned digest describes exactly the bytes written. A failed copy unlinks its
    /// partial destination.
    func copyRegularFile(named name: String, to dst: URL, chunkSize: Int = 1 << 20) throws -> RegularFileDigest {
        let source = try openRegularFile(named: name)
        defer { try? source.close() }
        let dfd = Darwin.open(dst.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard dfd >= 0 else { throw FileHashError.destinationUnwritable(path: dst.path, errno: errno) }
        let sink = FileHandle(fileDescriptor: dfd, closeOnDealloc: true)
        var complete = false
        defer {
            try? sink.close()
            if !complete { unlink(dst.path) }
        }
        let digest = try FileHash.streamDigest(from: source, chunkSize: chunkSize) { chunk in
            try sink.write(contentsOf: chunk)
        }
        try sink.close()
        complete = true
        return digest
    }

    func readRegularFile(named name: String) throws -> Data {
        let handle = try openRegularFile(named: name)
        defer { try? handle.close() }
        return try handle.readToEnd() ?? Data()
    }

    /// Create a DIRECT child EXCLUSIVELY (O_CREAT|O_EXCL|O_NOFOLLOW): an existing entry —
    /// regular file, symlink, even a DANGLING symlink — fails with EEXIST, so a
    /// pre-planted link is never followed and its target never written. On any failure
    /// only the file created by THIS call is unlinked (via the descriptor).
    func createRegularFileExclusively(named name: String, contents: Data, mode: mode_t = 0o600) throws {
        let hint = pathHint + "/" + name
        let f = openat(fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode)
        guard f >= 0 else { throw FileHashError.destinationUnwritable(path: hint, errno: errno) }
        let handle = FileHandle(fileDescriptor: f, closeOnDealloc: true)
        var complete = false
        defer {
            try? handle.close()
            if !complete { unlinkat(fd, name, 0) }
        }
        try handle.write(contentsOf: contents)
        try handle.close()
        complete = true
    }

    /// Create a DIRECT child directory (mkdirat, 0700) and return a bound handle to ONE
    /// consistent object at that name — so an entire artifact can be assembled and published
    /// relative to ONE root fd, immune to a swap of the root path.
    ///
    /// `mkdirat` + openat-by-name is NOT atomic on Darwin (there is no mkdirat that returns an
    /// fd). We fingerprint `name` immediately after mkdirat and require every later step — the
    /// bind and the bind-failure cleanup — to match that fingerprint, so they all act on the
    /// SAME object. HONEST LIMIT: that fingerprint is the FIRST OBSERVED inode at the name,
    /// not proof it is the inode mkdirat created — a same-UID racer swapping inside the
    /// mkdirat→fstatat sub-gap would be observed (and consistently bound and cleaned) as if it
    /// were ours. That sub-gap is a registered same-UID residual (see PreparedImportRunner);
    /// its consequence is bounded downstream by O_EXCL creates and the full pre-publish
    /// validation of the artifact contents.
    func makeChildDirectory(named name: String) throws -> DirectoryHandle {
        guard mkdirat(fd, name, 0o700) == 0 else {
            throw FileHashError.destinationUnwritable(path: pathHint + "/" + name, errno: errno)
        }
        // First OBSERVED identity at the name (see doc — not proof mkdirat created it). If it
        // already vanished / was retyped, it is not ours to clean — leave it and fail closed.
        guard let created = try? fingerprint(named: name), created.isDirectory else {
            throw FileHashError.destinationUnwritable(path: pathHint + "/" + name, errno: ENOENT)
        }
        let child: DirectoryHandle
        do {
            child = try subdirectory(named: name)
        } catch {
            // Bind failed after mkdirat succeeded — remove ONLY the first-observed object, i.e.
            // only when `name` STILL resolves (device+inode) to it; a later substitution
            // (foreign dir, symlink, file) is left untouched.
            if let now = try? fingerprint(named: name), now.isDirectory,
               now.device == created.device, now.inode == created.inode {
                _ = unlinkat(fd, name, AT_REMOVEDIR)
            }
            throw error
        }
        guard child.device == created.device, child.inode == created.inode else {
            // The bound handle does NOT match the first-observed fingerprint — swapped in the
            // fstatat→openat gap. Do not touch `name` (not observably ours); fail closed.
            // `child` closes on deinit.
            throw FileHashError.destinationUnwritable(path: pathHint + "/" + name, errno: EEXIST)
        }
        return child
    }

    /// Stream a regular file INTO this directory as `dstName`, created exclusively
    /// (openat O_CREAT|O_EXCL|O_NOFOLLOW). Returns the digest of the bytes written; a
    /// failure unlinks the partial destination via the descriptor.
    func importRegularFile(named dstName: String, from source: FileHandle, chunkSize: Int = 1 << 20) throws -> RegularFileDigest {
        let dfd = openat(fd, dstName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard dfd >= 0 else { throw FileHashError.destinationUnwritable(path: pathHint + "/" + dstName, errno: errno) }
        let sink = FileHandle(fileDescriptor: dfd, closeOnDealloc: true)
        var complete = false
        defer { try? sink.close(); if !complete { unlinkat(fd, dstName, 0) } }
        let d = try FileHash.streamDigest(from: source, chunkSize: chunkSize) { try sink.write(contentsOf: $0) }
        try sink.close()
        complete = true
        return d
    }

    /// Exclusive, SAME-DIRECTORY rename of a child (`renameatx_np(RENAME_EXCL)`, both names
    /// resolved relative to THIS fd). Atomic, same-volume, never overwrites. Returns false
    /// iff the destination already exists.
    func renameChildExclusively(from: String, to: String) throws -> Bool {
        let RENAME_EXCL_FLAG: UInt32 = 0x0004   // <sys/stdio.h> RENAME_EXCL
        let rc = from.withCString { f in to.withCString { t in renameatx_np(fd, f, fd, t, RENAME_EXCL_FLAG) } }
        if rc == 0 { return true }
        let e = errno
        if e == EEXIST || e == ENOTEMPTY { return false }
        throw FileHashError.destinationUnwritable(path: pathHint + "/" + to, errno: e)
    }

    /// Remove a DIRECT child that must NOT be a directory. `unlinkat(flag 0)` removes a
    /// regular file, a symlink (the LINK itself — never followed, target untouched) or a
    /// special file; it CANNOT remove a directory, so this primitive can never recurse into
    /// anything. ENOENT (absent, also mid-call) is a no-op; a DIRECTORY at the name throws
    /// fail-closed — a planted directory's contents are structurally untouchable here.
    func removeNonDirectoryChild(named name: String) throws {
        guard let fp = try fingerprint(named: name) else { return }          // ENOENT ⇒ absent
        guard !fp.isDirectory else { throw FileHashError.notARegularFile(pathHint + "/" + name) }
        guard unlinkat(fd, name, 0) == 0 else {
            let e = errno
            if e == ENOENT { return }
            throw FileHashError.unreadable(path: pathHint + "/" + name, errno: e)
        }
    }

    /// Best-effort cleanup of an attempt directory we CREATED and still hold a BOUND handle
    /// to (`child`). The vulnerability this avoids: re-resolving `name` (openat/subdirectory)
    /// could bind a DIFFERENT object — an attacker who moved our real attempt away and planted
    /// a same-named replacement — and then delete the REPLACEMENT's contents.
    ///
    /// Deliberately scope-limited on BOTH axes: unlinks go strictly THROUGH the bound `child`
    /// fd (never via the name), and ONLY the caller's own `knownEntries` are unlinked — the
    /// directory is NEVER enumerated, so an entry this caller did not create is never deleted,
    /// whatever it is. The directory ENTRY is then removed from THIS directory only if `name`
    /// STILL resolves (device+inode) to that same bound `child`; if unknown entries remain the
    /// AT_REMOVEDIR simply fails (ENOTEMPTY) and the leftover is reaper residue, and if `name`
    /// points at a different object it is LEFT untouched. The dir-type check keeps AT_REMOVEDIR
    /// from following a substituted symlink. Irreducible residual: `unlinkat(AT_REMOVEDIR)`
    /// re-resolves `name` independently of the fingerprint, so in the fingerprint→rmdir gap a
    /// same-UID racer could rename ANY empty dir onto `name` and have it removed (an empty dir
    /// only — never data). Same-UID threat model throughout; the private placement of the
    /// parent directory is a CALLER precondition (see PreparedImportRunner), not something this
    /// code verifies.
    func removeBoundChildDir(_ child: DirectoryHandle, named name: String, knownEntries: [String]) {
        for entry in knownEntries { unlinkat(child.fd, entry, 0) }   // ENOENT fine (not yet created)
        guard let fp = try? fingerprint(named: name), fp.isDirectory,
              fp.device == child.device, fp.inode == child.inode else { return }
        _ = unlinkat(fd, name, AT_REMOVEDIR)   // AT_REMOVEDIR == 0x0080; ENOTEMPTY ⇒ reaper residue
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
    /// Internal so trust-boundary code can READ (not just hash) through a verified fd.
    static func openVerifiedRegularFile(_ url: URL) throws -> FileHandle {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            let e = errno
            if e == ELOOP { throw FileHashError.notARegularFile(url.path) }   // symlink under O_NOFOLLOW
            throw FileHashError.unreadable(path: url.path, errno: e)
        }
        return try verifyRegularAndWrap(fd: fd, path: url.path)
    }

    /// Verify an ALREADY-OPEN descriptor (fstat: S_IFREG only) and wrap it. Takes
    /// ownership: the fd is closed on failure, or by the returned handle.
    static func verifyRegularAndWrap(fd: Int32, path: String) throws -> FileHandle {
        var st = stat()
        guard fstat(fd, &st) == 0 else {
            let e = errno; close(fd)
            throw FileHashError.unreadable(path: path, errno: e)
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            throw FileHashError.notARegularFile(path)
        }
        _ = fcntl(fd, F_SETFL, 0)   // drop O_NONBLOCK; regular-file reads ignore it anyway
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    static func streamDigest(from handle: FileHandle, chunkSize: Int,
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

    /// Stable combined identity of the DB (+ WAL) as ONE snapshot: two ingests with the
    /// same main DB but a different WAL produce DIFFERENT identities, and a `nil` WAL
    /// (no sidecar) differs from a present-but-empty WAL. NUL-separated with an explicit
    /// `wal:` marker so the two fields cannot be smuggled into each other. Shared by ingest
    /// (to STORE `snapshotIdentitySHA256`) and the read side (the staged-snapshot gate, to
    /// RE-VERIFY it fail-closed) so they can never drift.
    public static func snapshotIdentity(dbSHA: String, walSHA: String?) -> String {
        let s = "db:\(dbSHA)\u{0}wal:\(walSHA ?? "")"
        return SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
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
    /// N7.1 (§3.3): the selected source IS (or dangerously overlaps) this app's own
    /// protected data — rejected fail-closed by `SelfImportGuard` on canonical
    /// (device, inode) identity, never on path strings. Deliberately UNLIKE its siblings,
    /// the payload and description carry ONLY the stable role/relationship labels and
    /// NEVER a path (the coordinator maps it to the generic `invalidSource` block).
    case sourceIsActiveData(role: SelfImportRole, relationship: SelfImportRelationship)

    public var description: String {
        switch self {
        case .sourceDatabaseMissing(let p): return "Source database not found: \(p)"
        case .sourceNotRegularFile(let p): return "Source entry is not a regular file (symlink/directory/special) — refusing to ingest: \(p)"
        case .attachmentsRootNotADirectory(let p): return "Source attachments folder is not a real directory — refusing to ingest: \(p)"
        case .sourceBusy(let n): return "Source kept changing across \(n) attempts — quit the old SoloLedger (Electron) app and retry."
        case .importIDAlreadyExists(let id): return "An import with ID \(id) is already staged — reject or resume it, do not overwrite."
        case .stagedContentInconsistent(let what): return "Staged copy failed its consistency re-check (\(what)) — the attempt was discarded; retry the import."
        case let .cleanupFailed(path, underlying, original): return "Failed to clean up attempt \(path) after error [\(original)]: \(underlying)"
        case let .sourceIsActiveData(role, relationship):
            // Labels ONLY — never a path (see the case doc).
            return "Selected source overlaps this app's own data (role: \(role.rawValue), relationship: \(relationship.rawValue)) — refusing to self-import."
        }
    }
}

// MARK: - Self-import guard (N7.1, design §3.3)

/// WHICH protected object a rejected self-import hit. Converged to exactly three values
/// (design decision 4) — overlap SHAPE lives in `SelfImportRelationship`, never here.
public enum SelfImportRole: String, Sendable, Equatable {
    case nativeDataRoot, activeDatabase, activeAttachments
}

/// HOW the source overlaps the protected object. Deliberately THREE values: with only
/// canonical (device, inode) identity there is NO way to distinguish "the original
/// directory entry" from "a hard link to the same inode" — they are the same filesystem
/// object, and `st_nlink` only proves multiple links exist, not which alias was selected.
/// `sameIdentity` therefore covers same-directory identity, same-database-file identity AND
/// hard links to the active DB; no separate `hardLink` case is claimed (design §3.3).
public enum SelfImportRelationship: String, Sendable, Equatable {
    case sameIdentity, sourceAncestorOfProtected, sourceDescendantOfProtected
}

/// Fail-closed pre-check (§3.3): rejects importing this app's OWN data root / active store /
/// their dangerous overlaps. Every VERDICT rests on canonical (device, inode) identity —
/// never on a path string alone (firmlinks / mounts alias prefixes; a REAL cross-volume
/// copy with a different identity must stay importable). Containment (ancestor/descendant)
/// is decided sandbox-compatibly: no upward `openat(fd, "..")` walk exists — a sandboxed
/// process holding only the Powerbox grant for the source CANNOT open the source's parents
/// and must not need to. Instead the kernel's canonical path of each LIVE descriptor
/// (`DirectoryHandle.canonicalPath()`, fd-based) NOMINATES containment candidates by
/// component-boundary prefix, and each candidate is PROVEN by a bounded, no-follow,
/// componentwise descent from the OUTER descriptor whose final (device, inode) must match.
/// Descents only ever go DOWN — from the source (inside its own grant) or from a protected
/// handle (inside the container) — so no operation needs authority the process doesn't
/// already hold. It is a UX gate layered in front of the pipeline, not the write-safety
/// boundary — that stays with the activator's `O_EXCL` reservation and the hardened opens.
/// Any open/stat metadata error — a sandbox/permission denial included — is fail-closed
/// (the import is refused), never read as "no overlap".
struct SelfImportGuard {

    /// The identities this guard protects. Injectable (coordinator-config-derived in
    /// production, isolated temp roots in tests) — mirroring the coordinator's existing
    /// dependency seams so no test ever touches the real container.
    struct ProtectedIdentity {
        var dataRootURL: URL
        var activeDatabaseURL: URL
        var activeAttachmentsRootURL: URL

        /// PURE path derivation of the production identity (creates nothing on disk).
        static func standard() throws -> ProtectedIdentity {
            let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                                   in: .userDomainMask, appropriateFor: nil, create: false)
                .appendingPathComponent(AppPaths.nativeDataFolderName, isDirectory: true)
            return ProtectedIdentity(
                dataRootURL: base,
                activeDatabaseURL: base.appendingPathComponent(AppPaths.databaseFileName),
                activeAttachmentsRootURL: base.appendingPathComponent("attachments", isDirectory: true)
                    .appendingPathComponent("docs", isDirectory: true))
        }
    }

    /// Canonical filesystem identity — the ONLY thing ever compared.
    struct Ident: Equatable {
        let device: Int32
        let inode: UInt64
        init(_ h: DirectoryHandle) { device = h.device; inode = h.inode }
        init(_ fp: FileFingerprint) { device = fp.device; inode = fp.inode }
    }

    /// Ancestry judgments that exceed the fixed bound — or whose nominated containment
    /// cannot be re-proven by descriptor identity — are refused fail-closed (never treated
    /// as "no overlap"). Carries no path.
    struct AncestryUnverifiable: Error, CustomStringConvertible {
        let depth: Int
        var description: String { "Self-import guard could not verify directory ancestry within \(depth) hops — refusing to ingest." }
    }

    var identity: ProtectedIdentity
    /// Fixed bound (§3.3) on every ancestry judgment: a canonical location deeper than this,
    /// or a containment descent longer than this, is refused fail-closed rather than trusted.
    var maxDepth: Int = 64

    /// Throws `IngestError.sourceIsActiveData` on any protected overlap; returns silently
    /// when the source is independent. An ABSENT source (ENOENT) is not an overlap — the
    /// existing early gates (`sourceDatabaseMissing`, …) own that verdict; every OTHER
    /// metadata failure propagates fail-closed.
    func check(_ source: MigrationSource) throws {
        let dbURL = try source.databaseURL()
        let sourceDirURL = dbURL.deletingLastPathComponent()

        // Protected side, resolved once. A missing data/attachments root reads as "nothing to
        // protect" for equality/descendant (first-install allowance, §3.3); a missing active
        // DB likewise. Any non-ENOENT failure here is fail-closed.
        let rootHandle = try Self.openIfExists(identity.dataRootURL)
        let attachmentsHandle = try Self.openIfExists(identity.activeAttachmentsRootURL)
        let activeDBIdent = try FileFingerprint.capture(at: identity.activeDatabaseURL).map(Ident.init)

        // Source side. A symlinked source directory fails `DirectoryHandle.open` with
        // `notADirectory` (O_NOFOLLOW) and propagates — fail-closed, deliberately (§3.3).
        let sourceDir = try Self.openIfExists(sourceDirURL)
        let sourceDBIdent = try FileFingerprint.capture(at: dbURL).map(Ident.init)

        // Same database-file identity — covers the user picking the active DB itself AND any
        // hard link to it (indistinguishable by identity; both are `sameIdentity`).
        if case .legacySingleDB = source {
            if let db = sourceDBIdent, let active = activeDBIdent, db == active {
                throw IngestError.sourceIsActiveData(role: .activeDatabase, relationship: .sameIdentity)
            }
            // A standalone file cannot CONTAIN a directory; only its containment matters.
            if let parent = sourceDir {
                try rejectParentContainment(parent, root: rootHandle, attachments: attachmentsHandle)
            }
            return
        }

        guard let sourceDir else { return }   // absent source dir → the early gates decide
        let sourceIdent = Ident(sourceDir)

        if let root = rootHandle, sourceIdent == Ident(root) {
            throw IngestError.sourceIsActiveData(role: .nativeDataRoot, relationship: .sameIdentity)
        }
        if let att = attachmentsHandle, sourceIdent == Ident(att) {
            throw IngestError.sourceIsActiveData(role: .activeAttachments, relationship: .sameIdentity)
        }
        if let db = sourceDBIdent, let active = activeDBIdent, db == active {
            throw IngestError.sourceIsActiveData(role: .activeDatabase, relationship: .sameIdentity)
        }

        let src = try Located(sourceDir, bound: maxDepth)
        let att = try attachmentsHandle.map { try Located($0, bound: maxDepth) }
        let root = try rootHandle.map { try Located($0, bound: maxDepth) }

        // Source INSIDE a protected object. Attachments sit INSIDE the data root, so the
        // deeper protected object is tested first — report it, not the outer root.
        if let a = att, try verifiedStrictDescent(outer: a, to: src) {
            throw IngestError.sourceIsActiveData(role: .activeAttachments, relationship: .sourceDescendantOfProtected)
        }
        if let r = root, try verifiedStrictDescent(outer: r, to: src) {
            throw IngestError.sourceIsActiveData(role: .nativeDataRoot, relationship: .sourceDescendantOfProtected)
        }

        // Source CONTAINS a protected object: the data root (or, when it does not exist yet,
        // its deepest EXISTING ancestor — a first-install data root's future parents exist
        // and must still be refusable, §3.3), then the attachments root. The mount-point
        // branch covers the one containment shape canonical prefixes cannot see (§ the
        // `containsMountPoint` doc).
        if let r = root {
            if try verifiedStrictDescent(outer: src, to: r) || containsMountPoint(of: r.handle, source: src) {
                throw IngestError.sourceIsActiveData(role: .nativeDataRoot, relationship: .sourceAncestorOfProtected)
            }
        } else if let nearestHandle = try Self.openDeepestExistingAncestor(of: identity.dataRootURL) {
            let nearest = try Located(nearestHandle, bound: maxDepth)
            if try src.ident == nearest.ident || verifiedStrictDescent(outer: src, to: nearest) {
                throw IngestError.sourceIsActiveData(role: .nativeDataRoot, relationship: .sourceAncestorOfProtected)
            }
        }
        if let a = att {
            if try verifiedStrictDescent(outer: src, to: a) || containsMountPoint(of: a.handle, source: src) {
                throw IngestError.sourceIsActiveData(role: .activeAttachments, relationship: .sourceAncestorOfProtected)
            }
        }
    }

    // MARK: internals

    /// A live directory descriptor together with its kernel-canonical path components,
    /// bounded at construction (fail-closed beyond the bound).
    private struct Located {
        let handle: DirectoryHandle
        let ident: Ident
        let components: [String]

        init(_ handle: DirectoryHandle, bound maxDepth: Int) throws {
            self.handle = handle
            self.ident = Ident(handle)
            let comps = Located.split(try handle.canonicalPath())
            guard comps.count <= maxDepth else { throw AncestryUnverifiable(depth: maxDepth) }
            self.components = comps
        }

        static func split(_ path: String) -> [String] { path.split(separator: "/").map(String.init) }
    }

    /// TRUE iff `inner` sits STRICTLY inside `outer`. The canonical-component prefix only
    /// NOMINATES the candidate; the verdict is a bounded, no-follow, componentwise descent
    /// from `outer`'s own descriptor whose final (device, inode) must equal `inner`'s. The
    /// descent never leaves `outer`'s subtree, so a Powerbox-granted outer needs nothing
    /// beyond its grant and a container-side outer never leaves the container. A nominated
    /// descent that cannot complete — racing rename, permission denial — or that lands on a
    /// different identity is fail-closed, never "independent".
    private func verifiedStrictDescent(outer: Located, to inner: Located) throws -> Bool {
        guard inner.components.count > outer.components.count,
              inner.components.starts(with: outer.components) else { return false }
        let relative = inner.components.dropFirst(outer.components.count)
        guard relative.count <= maxDepth else { throw AncestryUnverifiable(depth: maxDepth) }
        var cursor = outer.handle
        for name in relative { cursor = try cursor.subdirectory(named: name) }
        guard Ident(cursor) == inner.ident else { throw AncestryUnverifiable(depth: maxDepth) }
        return true
    }

    /// Firmlink / mount alias coverage: canonical spellings break EXACTLY at a volume
    /// junction (macOS spells the data volume "/System/Volumes/Data" while everything ON it
    /// is spelled from "/"), so a source that IS — or textually contains — the mount point
    /// of the protected object's volume contains the protected object physically with no
    /// shared canonical prefix. `fstatfs` (fd-based, public API) names that mount point; the
    /// verdict still ends in descriptor evidence: the descended-to directory must be that
    /// very volume root (same fsid AND canonical path equal to the mount point).
    private func containsMountPoint(of protected: DirectoryHandle, source: Located) throws -> Bool {
        var pfs = statfs()
        guard fstatfs(protected.fd, &pfs) == 0 else { throw AncestryUnverifiable(depth: maxDepth) }
        let mnt = Located.split(Self.mountPath(of: &pfs))
        guard mnt.count <= maxDepth else { throw AncestryUnverifiable(depth: maxDepth) }
        guard mnt.count >= source.components.count,
              mnt.starts(with: source.components) else { return false }
        var cursor = source.handle
        for name in mnt.dropFirst(source.components.count) {
            cursor = try cursor.subdirectory(named: name)
        }
        var cfs = statfs()
        guard fstatfs(cursor.fd, &cfs) == 0 else { throw AncestryUnverifiable(depth: maxDepth) }
        guard cfs.f_fsid.val.0 == pfs.f_fsid.val.0, cfs.f_fsid.val.1 == pfs.f_fsid.val.1 else { return false }
        return Located.split(try cursor.canonicalPath()) == mnt
    }

    private static func mountPath(of fs: inout statfs) -> String {
        withUnsafeBytes(of: &fs.f_mntonname) { raw in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
    }

    /// legacySingleDB containment: the DB's parent directory BEING root/attachments or
    /// sitting INSIDE either. Attachments (the deeper object on the nested layout) reports
    /// first — identical report order to the N7.1 upward walk this replaces, and identical
    /// labels: both shapes are `sourceDescendantOfProtected`.
    private func rejectParentContainment(_ parent: DirectoryHandle,
                                         root: DirectoryHandle?, attachments: DirectoryHandle?) throws {
        guard root != nil || attachments != nil else { return }
        let parentIdent = Ident(parent)
        if let att = attachments, parentIdent == Ident(att) {
            throw IngestError.sourceIsActiveData(role: .activeAttachments, relationship: .sourceDescendantOfProtected)
        }
        if let r = root, parentIdent == Ident(r) {
            throw IngestError.sourceIsActiveData(role: .nativeDataRoot, relationship: .sourceDescendantOfProtected)
        }
        let par = try Located(parent, bound: maxDepth)
        if let att = try attachments.map({ try Located($0, bound: maxDepth) }),
           try verifiedStrictDescent(outer: att, to: par) {
            throw IngestError.sourceIsActiveData(role: .activeAttachments, relationship: .sourceDescendantOfProtected)
        }
        if let r = try root.map({ try Located($0, bound: maxDepth) }),
           try verifiedStrictDescent(outer: r, to: par) {
            throw IngestError.sourceIsActiveData(role: .nativeDataRoot, relationship: .sourceDescendantOfProtected)
        }
    }

    /// nil ⇔ the directory is definitively absent (ENOENT); a symlink or non-directory
    /// throws `notADirectory` (fail-closed); every other error propagates.
    private static func openIfExists(_ url: URL) throws -> DirectoryHandle? {
        do { return try DirectoryHandle.open(at: url) }
        catch let e as FileHashError where e.isFileMissing { return nil }
    }

    /// The deepest EXISTING ancestor of `url` (nil only if even "/" cannot be opened, which
    /// propagates as an error instead). Trusted-path input only (our own derived layout).
    private static func openDeepestExistingAncestor(of url: URL) throws -> DirectoryHandle? {
        var current = url.deletingLastPathComponent()
        while true {
            if let handle = try openIfExists(current) { return handle }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return try openIfExists(current) }
            current = parent
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

enum IngestStep {
    case afterDatabaseCopy, duringAttachmentCopy, beforeManifestWrite
    /// Fires BEFORE the final validation gate — the adversary window the gate must catch.
    case beforePublish
    /// Fires AFTER the final validation gate and BEFORE the entry re-check + rename —
    /// the (documented) residual window.
    case afterValidation
}

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

    /// Internal entry point with an attempt bound + fault seams (test-only). `protecting`
    /// is the self-import guard's identity seam: nil derives the standard production
    /// identity (pure path derivation); the coordinator injects its config-derived identity;
    /// tests inject isolated temp roots.
    @discardableResult
    func ingest(_ source: MigrationSource, importID: ImportID, timestamp: String,
                maxAttempts: Int, hooks: IngestHooks,
                protecting: SelfImportGuard.ProtectedIdentity? = nil) throws -> IngestResult {
        let dbURL = try source.databaseURL()
        let finalDir = try AppPaths.stagedImportDirectory(importID: importID)
        // lstat semantics: ANY entry at the final path — including a dangling symlink —
        // means this importID is taken; we must never rename onto it.
        if try FileFingerprint.capture(at: finalDir) != nil {
            throw IngestError.importIDAlreadyExists(importID.rawValue)
        }
        return try source.withAccess {
            // N7.1 (§3.3): the self-import guard runs FIRST — inside the access grant, before
            // any gate or copy — and rejects a source that IS this app's own protected data.
            try SelfImportGuard(identity: protecting ?? .standard()).check(source)
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

        // FINAL pre-publish gate — descriptor-rooted re-verification of the ENTIRE
        // attempt tree (see validateAttemptForPublish). Returns the bound handle.
        try hooks.onStep?(.beforePublish)
        let bound = try validateAttemptForPublish(attemptDir: attemptDir, expected: manifest, staged: staged)

        try hooks.onStep?(.afterValidation)

        try withExtendedLifetime(bound) {
            // The path entry must STILL be the very directory we validated — same device
            // and inode, a real directory, not a symlink or a substituted tree. Accepted
            // residual (documented): this re-check → rename window cannot be fd-bound
            // (rename is path-based); attempt dirs are process-private inside the native
            // container, so nothing legitimate writes there between the two calls.
            guard let entry = try FileFingerprint.capture(at: attemptDir),
                  entry.isDirectory, entry.device == bound.device, entry.inode == bound.inode else {
                throw IngestError.stagedContentInconsistent("attempt dir entry changed after validation")
            }

            // Atomic publish: rename the completed attempt onto the per-import dir (same
            // volume). moveItem THROWS if the destination exists — a concurrent ingest
            // that published this importID inside our window wins; ITS directory is never
            // touched (the caller cleans only OUR attempt) and the loss surfaces as the
            // same importIDAlreadyExists the up-front check uses. lstat semantics: even a
            // dangling symlink at the destination counts as "exists".
            do {
                try FileManager.default.moveItem(at: attemptDir, to: finalDir)
            } catch {
                if (try? FileFingerprint.capture(at: finalDir)) ?? nil != nil {
                    throw IngestError.importIDAlreadyExists(importID.rawValue)
                }
                throw error
            }
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

    /// FINAL pre-publish integrity gate, DESCRIPTOR-ROOTED: the attempt directory is
    /// opened O_NOFOLLOW|O_DIRECTORY and identity-bound (device+inode); every check and
    /// every read below runs relative to that descriptor (openat / fstatat
    /// AT_SYMLINK_NOFOLLOW), so swapping the attempt dir, `attachments`, `docs` or any
    /// entry for a symlink — even one pointing at byte-identical content — fails, and no
    /// path re-resolution can redirect a read. Verifies:
    ///  - the attempt root's entry set is EXACTLY {manifest.json, sololedger.db,
    ///    [sololedger.db-wal], [attachments]} — no extras (-shm, -journal, junk), and
    ///    each entry is the right type;
    ///  - manifest.json (read through the descriptor) decodes FIELD-FOR-FIELD equal to
    ///    the built manifest;
    ///  - the staged DB / WAL digests equal both the verified copy digests and the
    ///    manifest records (a FIFO/symlink/directory swap fails immediately, no hang);
    ///  - `attachments` contains EXACTLY the real directory `docs`, whose entry set is
    ///    EXACTLY the manifest's `.ingested` names (no extra attachments, no entities
    ///    for skipped names), each a regular file with the exact sha256 AND size.
    /// ANY violation throws `stagedContentInconsistent`; the attempt is discarded and
    /// nothing is published. Returns the bound handle so the caller can confirm, right
    /// before the rename, that the path entry is STILL this very directory.
    private static func validateAttemptForPublish(attemptDir: URL, expected: ImportManifest,
                                                  staged: StagedLayout) throws -> DirectoryHandle {
        func fail(_ what: String) -> IngestError { .stagedContentInconsistent(what) }

        let root: DirectoryHandle
        do { root = try DirectoryHandle.open(at: attemptDir) }
        catch { throw fail("attempt dir: \(error)") }

        // 1. Exact root entry set + types.
        let dbName = AppPaths.databaseFileName
        let walName = dbName + "-wal"
        var expectedRoot: Set<String> = ["manifest.json", dbName]
        if expected.walSHA256 != nil { expectedRoot.insert(walName) }
        if staged.hasAttachments { expectedRoot.insert("attachments") }
        let rootEntries = Set(try root.entryNames())
        guard rootEntries == expectedRoot else {
            throw fail("attempt root is \(rootEntries.sorted()) but must be exactly \(expectedRoot.sorted())")
        }
        for name in expectedRoot {
            guard let fp = try root.fingerprint(named: name) else { throw fail("\(name) vanished") }
            let wantDir = (name == "attachments")
            guard wantDir ? fp.isDirectory : fp.isRegularFile else { throw fail("\(name) has the wrong type") }
        }

        // 2. Manifest: read through the descriptor, decoded object must equal ours.
        let manifestData: Data
        do { manifestData = try root.readRegularFile(named: "manifest.json") }
        catch { throw fail("manifest: \(error)") }
        guard let decoded = try? JSONDecoder().decode(ImportManifest.self, from: manifestData),
              decoded == expected else {
            throw fail("manifest on disk does not match the built manifest")
        }

        // 3. DB + WAL digests through the descriptor.
        func verifiedDigest(_ dir: DirectoryHandle, _ name: String) throws -> RegularFileDigest {
            do { return try dir.digestOfRegularFile(named: name) }
            catch { throw fail("\(name): \(error)") }
        }
        let dbDigest = try verifiedDigest(root, dbName)
        guard dbDigest == staged.dbCopyDigest, dbDigest.sha256 == expected.sourceDBSHA256 else {
            throw fail("db")
        }
        if let walSHA = expected.walSHA256 {
            let walDigest = try verifiedDigest(root, walName)
            guard walDigest == staged.walCopyDigest, walDigest.sha256 == walSHA else { throw fail("wal") }
        }

        // 4. Attachment tree: attachments → docs, both REAL directories reached via
        //    openat; docs' entry set must equal the ingested name set exactly.
        let ingested = expected.files.filter { $0.outcome == .ingested }
        if staged.hasAttachments {
            let attachments: DirectoryHandle
            let docs: DirectoryHandle
            do {
                attachments = try root.subdirectory(named: "attachments")
                guard try attachments.entryNames() == ["docs"] else {
                    throw fail("attachments dir must contain exactly 'docs'")
                }
                docs = try attachments.subdirectory(named: "docs")
            } catch let e as IngestError { throw e }
            catch { throw fail("attachment tree: \(error)") }

            let docsEntries = Set(try docs.entryNames())
            let expectedDocs = Set(ingested.map { $0.name })
            guard docsEntries == expectedDocs else {
                throw fail("docs is \(docsEntries.sorted()) but must be exactly \(expectedDocs.sorted())")
            }
            for f in ingested {
                let d = try verifiedDigest(docs, f.name)
                guard d.sha256 == f.sha256, d.size == f.size else { throw fail(f.name) }
            }
        } else {
            guard ingested.isEmpty else { throw fail("ingested files recorded but no attachments dir staged") }
        }

        return root
    }

    private static func cleanupIfPresent(_ dir: URL, hooks: IngestHooks, original: Error) throws {
        // lstat semantics: a DANGLING attempt symlink must be cleaned too (fileExists
        // would follow it, report false and leak the entry). A metadata error reads as
        // "present" so we still attempt the removal rather than silently skipping.
        let present: Bool
        do { present = try FileFingerprint.capture(at: dir) != nil } catch { present = true }
        guard present else { return }
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

    struct ClassifiedAttachment {
        let url: URL
        let name: String
        let outcome: ImportManifest.FileResult.Outcome
        var isIngested: Bool { outcome == .ingested }
    }

    /// Classify the TOP-LEVEL entries of an attachments root (never recursive), through the
    /// SAME descriptor-rooted, errno-checked machinery the publish gate uses — NEVER
    /// `FileManager.contentsOfDirectory`, whose readdir loop stops at NULL without
    /// inspecting errno and can hand back a TRUNCATED-but-self-consistent listing on a
    /// mid-read error (which would silently shrink the imported attachment set). Root gate:
    /// ENOENT ⇒ "no attachments"; a symlinked or non-directory root ⇒
    /// attachmentsRootNotADirectory; any other open error is fail-closed. Sorted by name.
    private static func enumerateAttachments(root: URL) throws -> [ClassifiedAttachment] {
        let dir: DirectoryHandle
        do {
            dir = try DirectoryHandle.open(at: root)   // O_NOFOLLOW|O_DIRECTORY, identity-bound
        } catch let e as FileHashError {
            if e.isFileMissing { return [] }                                     // ENOENT ⇒ no attachments
            if case .notADirectory = e { throw IngestError.attachmentsRootNotADirectory(root.path) }
            throw e                                                              // any other error ⇒ fail-closed
        }
        return try classifyAttachments(in: dir, root: root)
    }

    /// Classify the entries of an ALREADY-OPENED attachments directory through its
    /// descriptor: `entryNames()` is errno-checked (a mid-enumeration read error THROWS
    /// rather than truncating), and each member's type is read by
    /// `fstatat(AT_SYMLINK_NOFOLLOW)` on the SAME fd (no path re-resolution, no symlink
    /// following). Classification order is preserved verbatim — symlink → directory →
    /// regular (name-validated: valid ⇒ ingested, else rejectedName) → special. A member
    /// that vanished between listing and stat (ENOENT) is fail-closed as a source change
    /// (SourceVanished), never silently dropped. Internal so the fail-closed-on-read-error
    /// behavior is directly unit-testable.
    static func classifyAttachments(in dir: DirectoryHandle, root: URL) throws -> [ClassifiedAttachment] {
        var out: [ClassifiedAttachment] = []
        for name in try dir.entryNames() {                                       // fail-closed on read error
            guard let fp = try dir.fingerprint(named: name) else {               // fail-closed on non-ENOENT
                throw SourceVanished(path: root.appendingPathComponent(name).path)
            }
            let outcome: ImportManifest.FileResult.Outcome
            if fp.isSymbolicLink {
                outcome = .skippedSymlink
            } else if fp.isDirectory {
                outcome = .skippedDirectory
            } else if fp.isRegularFile {
                outcome = AttachmentName.isValid(name) ? .ingested : .rejectedName
            } else {
                outcome = .skippedSpecial
            }
            out.append(ClassifiedAttachment(url: root.appendingPathComponent(name), name: name, outcome: outcome))
        }
        return out.sorted { $0.name < $1.name }   // entryNames() already sorts; keep the guarantee explicit
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
                              snapshotIdentitySHA256: ImportManifest.snapshotIdentity(dbSHA: dbHash, walSHA: walHash),
                              attachmentManifestSHA256: ImportManifest.attachmentSetHash(files),
                              files: files, status: .ingested, report: nil)
    }

    /// Write manifest.json through the VERIFIED attempt-directory descriptor, exclusively
    /// and no-follow: a pre-planted entry at that name — regular file, symlink, even a
    /// DANGLING symlink — fails with EEXIST before a single byte is written, so a planted
    /// link's target can never be touched. Failure unlinks only the file this call created.
    private static func writeManifest(_ manifest: ImportManifest, to dir: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(manifest)
        let root = try DirectoryHandle.open(at: dir)
        try root.createRegularFileExclusively(named: "manifest.json", contents: data, mode: 0o600)
    }
}
