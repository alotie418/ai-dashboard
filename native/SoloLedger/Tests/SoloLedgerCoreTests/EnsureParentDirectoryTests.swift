import XCTest
@testable import SoloLedgerCore

/// STAGE-0 primitives for the confirmed-createFresh missing-parent fix:
///   • `DirectoryHandle.openNoFollowAny(at:)` — full-path no-follow anchor (O_NOFOLLOW_ANY:
///     the KERNEL rejects a symlink in ANY component, raw errno preserved);
///   • `DirectoryHandle.ensureChildDirectory(named:)` — EEXIST-tolerant, cleanup-free
///     sibling of `makeChildDirectory` (single direct component, 0700 on create, existing
///     real directory bound with metadata untouched, squatters refused with raw errno and
///     never deleted).
/// Plus the two cross-cutting guards: an empty data-root residue is boot-neutral, and the
/// existing-store open path never creates the data root.
///
/// PATH DISCIPLINE (why `td()` realpaths): `FileManager.temporaryDirectory` lives under
/// `/var/folders/…` and `/var` IS a symlink — `openNoFollowAny` would correctly refuse it
/// (ELOOP) and every test would fail for the wrong reason. The test root is therefore
/// realpath'd to `/private/var/…` ONCE, at construction. realpath is a TEST-HARNESS
/// convenience only and must never appear in the production implementation.
final class EnsureParentDirectoryTests: LedgerTestCase {

    private let fm = FileManager.default

    private func td() throws -> URL {
        let d = try trackedTempDir()
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(d.path, &buf) != nil else { return d }
        return URL(fileURLWithPath: String(cString: buf), isDirectory: true)
    }

    /// Exact FileHashError match (case + path-irrelevant errno).
    private func assertFails(_ expected: FileHashError, file: StaticString = #filePath, line: UInt = #line,
                             _ body: () throws -> Void) {
        XCTAssertThrowsError(try body(), file: file, line: line) { e in
            guard let f = e as? FileHashError else { return XCTFail("expected FileHashError, got \(e)", file: file, line: line) }
            switch (f, expected) {
            case (.unreadable(_, let a), .unreadable(_, let b)):
                XCTAssertEqual(a, b, "errno", file: file, line: line)
            case (.destinationUnwritable(_, let a), .destinationUnwritable(_, let b)):
                XCTAssertEqual(a, b, "errno", file: file, line: line)
            default:
                XCTFail("expected \(expected), got \(f)", file: file, line: line)
            }
        }
    }

    // MARK: - openNoFollowAny

    func testOpenNoFollowAnyBindsRealNestedDirectory() throws {
        let base = try td()
        let nested = base.appendingPathComponent("a", isDirectory: true).appendingPathComponent("b", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        let h = try DirectoryHandle.openNoFollowAny(at: nested)
        var st = stat()
        XCTAssertEqual(lstat(nested.path, &st), 0)
        XCTAssertEqual(h.device, Int32(st.st_dev))
        XCTAssertEqual(h.inode, UInt64(st.st_ino))
    }

    /// The raw kernel ELOOP for an ANCESTOR symlink must surface unchanged — deliberately NOT
    /// the errno-dropping `notADirectory` collapse of `open(at:)`. Kills "anchor by plain
    /// path open / O_NOFOLLOW": that mutant binds straight through the ancestor link.
    func testOpenNoFollowAnyAncestorSymlinkRawELOOPPreserved() throws {
        let base = try td()
        let real = base.appendingPathComponent("real", isDirectory: true)
        let sub = real.appendingPathComponent("sub", isDirectory: true)
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        let link = base.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        assertFails(.unreadable(path: "", errno: ELOOP)) {
            _ = try DirectoryHandle.openNoFollowAny(at: link.appendingPathComponent("sub", isDirectory: true))
        }
    }

    func testOpenNoFollowAnyNonFileURLFailsEINVALWithoutFilesystemAccess() throws {
        assertFails(.unreadable(path: "", errno: EINVAL)) {
            _ = try DirectoryHandle.openNoFollowAny(at: URL(string: "https://example.invalid/x")!)
        }
    }

    /// A RELATIVE file URL (`file:relative` — isFileURL true, path without a leading "/")
    /// must be refused by the input-contract guard BEFORE any filesystem access; the
    /// non-file-URL test above cannot stand in for this case.
    func testOpenNoFollowAnyRelativeFileURLFailsEINVALWithoutFilesystemAccess() throws {
        let url = URL(string: "file:relative")!
        XCTAssertTrue(url.isFileURL, "precondition: this IS a file URL, just not absolute")
        XCTAssertFalse(url.path.hasPrefix("/"), "precondition: the path is relative")
        assertFails(.unreadable(path: "", errno: EINVAL)) {
            _ = try DirectoryHandle.openNoFollowAny(at: url)
        }
    }

    func testOpenNoFollowAnyMissingENOENTAndFileENOTDIRRawErrnos() throws {
        let base = try td()
        assertFails(.unreadable(path: "", errno: ENOENT)) {
            _ = try DirectoryHandle.openNoFollowAny(at: base.appendingPathComponent("absent", isDirectory: true))
        }
        let file = base.appendingPathComponent("plain")
        try Data("x".utf8).write(to: file)
        assertFails(.unreadable(path: "", errno: ENOTDIR)) {
            _ = try DirectoryHandle.openNoFollowAny(at: file)
        }
    }

    // MARK: - ensureChildDirectory: create / existing / invalid names

    func testEnsureCreatesDirectory0700AndBindsIt() throws {
        let base = try td()
        let root = try DirectoryHandle.openNoFollowAny(at: base)
        let child = try root.ensureChildDirectory(named: "fresh")
        var st = stat()
        XCTAssertEqual(lstat(base.appendingPathComponent("fresh").path, &st), 0)
        XCTAssertEqual(st.st_mode & S_IFMT, mode_t(S_IFDIR))
        XCTAssertEqual(st.st_mode & 0o777, 0o700)
        XCTAssertEqual(child.device, Int32(st.st_dev))
        XCTAssertEqual(child.inode, UInt64(st.st_ino))
    }

    /// EEXIST success path: an existing REAL directory is bound with its metadata —
    /// permissions, inode, mtime — byte-for-byte untouched (no chmod, no utimes).
    func testEnsureExistingDirectoryBoundAndMetadataUntouched() throws {
        let base = try td()
        let dir = base.appendingPathComponent("existing", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: false)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        var before = stat()
        XCTAssertEqual(lstat(dir.path, &before), 0)
        let root = try DirectoryHandle.openNoFollowAny(at: base)
        let child = try root.ensureChildDirectory(named: "existing")
        var after = stat()
        XCTAssertEqual(lstat(dir.path, &after), 0)
        XCTAssertEqual(after.st_mode, before.st_mode, "mode untouched (still 0755)")
        XCTAssertEqual(after.st_ino, before.st_ino, "same inode — bound, not recreated")
        XCTAssertEqual(after.st_mtimespec.tv_sec, before.st_mtimespec.tv_sec)
        XCTAssertEqual(after.st_mtimespec.tv_nsec, before.st_mtimespec.tv_nsec)
        XCTAssertEqual(child.inode, UInt64(before.st_ino))
    }

    func testEnsureInvalidNamesFailClosedEINVALTouchingNothing() throws {
        let base = try td()
        let root = try DirectoryHandle.openNoFollowAny(at: base)
        for bad in ["", ".", "..", "a/b"] {
            assertFails(.destinationUnwritable(path: "", errno: EINVAL)) {
                _ = try root.ensureChildDirectory(named: bad)
            }
        }
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: base.path), [], "no filesystem effect for any invalid name")
    }

    /// An EMBEDDED NUL must be refused BEFORE any syscall: Darwin's C-string bridging
    /// truncates at the NUL, so an unvalidated "prefix\0suffix" would silently
    /// mkdir "prefix" (directly verified on current Darwin during review).
    func testEnsureEmbeddedNULFailsClosedEINVALNothingCreated() throws {
        let base = try td()
        let root = try DirectoryHandle.openNoFollowAny(at: base)
        assertFails(.destinationUnwritable(path: "", errno: EINVAL)) {
            _ = try root.ensureChildDirectory(named: "prefix\0suffix")
        }
        XCTAssertFalse(fm.fileExists(atPath: base.appendingPathComponent("prefix").path),
                       "the truncated prefix must NOT be created")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: base.path), [], "no entry of any name may appear")
    }

    // MARK: - ensureChildDirectory: squatters (refused with raw errno, never deleted)

    func testEnsureFileSquatterENOTDIRAndUntouched() throws {
        let base = try td()
        let squat = base.appendingPathComponent("name")
        let bytes = Data("keep me".utf8)
        try bytes.write(to: squat)
        let root = try DirectoryHandle.openNoFollowAny(at: base)
        assertFails(.destinationUnwritable(path: "", errno: ENOTDIR)) {
            _ = try root.ensureChildDirectory(named: "name")
        }
        XCTAssertEqual(try Data(contentsOf: squat), bytes)
    }

    func testEnsureSymlinkSquatterELOOPLinkAndTargetUntouched() throws {
        let base = try td()
        let decoy = base.appendingPathComponent("decoy", isDirectory: true)
        try fm.createDirectory(at: decoy, withIntermediateDirectories: false)
        try fm.createSymbolicLink(at: base.appendingPathComponent("name"), withDestinationURL: decoy)
        let root = try DirectoryHandle.openNoFollowAny(at: base)
        assertFails(.destinationUnwritable(path: "", errno: ELOOP)) {
            _ = try root.ensureChildDirectory(named: "name")
        }
        var st = stat()
        XCTAssertEqual(lstat(base.appendingPathComponent("name").path, &st), 0)
        XCTAssertEqual(st.st_mode & S_IFMT, mode_t(S_IFLNK), "the squatting link is left in place, never resolved")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: decoy.path), [], "the link target gains nothing")
    }

    // MARK: - ensureChildDirectory: window seams (mkdirat→fstatat and fstatat→openat gaps)

    /// mkdirat succeeded, then the entry VANISHED before the first fstatat (ENOENT): fail
    /// closed with the raw errno and delete nothing — a successor entry is not ours.
    func testEnsureWindowVanishAfterCreateENOENTNothingDeleted() throws {
        let base = try td()
        let root = try DirectoryHandle.openNoFollowAny(at: base)
        assertFails(.destinationUnwritable(path: "", errno: ENOENT)) {
            _ = try root.ensureChildDirectory(named: "gone", afterCreateBeforeFirstStat: {
                try self.fm.removeItem(at: base.appendingPathComponent("gone"))
            })
        }
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: base.path), [])
    }

    /// mkdirat succeeded, then OUR directory was swapped for a FILE in the same sub-gap:
    /// the bind refuses (raw ENOTDIR) and the swapped-in object is not deleted.
    func testEnsureWindowSwapToFileAfterCreateENOTDIRSwapUntouched() throws {
        let base = try td()
        let name = base.appendingPathComponent("swapped")
        let bytes = Data("foreign".utf8)
        let root = try DirectoryHandle.openNoFollowAny(at: base)
        assertFails(.destinationUnwritable(path: "", errno: ENOTDIR)) {
            _ = try root.ensureChildDirectory(named: "swapped", afterCreateBeforeFirstStat: {
                try self.fm.removeItem(at: name)
                try bytes.write(to: name)
            })
        }
        XCTAssertEqual(try Data(contentsOf: name), bytes, "the swapped-in file survives untouched")
    }

    /// fstatat→openat gap swap for a SYMLINK: the fd-rooted no-follow bind refuses with the
    /// raw kernel ELOOP and writes nothing through the link. Kills "drop the re-bind /
    /// re-open by path": a path-based mutant collapses this into an errno-less error (or
    /// follows the link), failing the exact-case assertion here.
    func testEnsureWindowSwapToSymlinkBeforeBindELOOPTargetUntouched() throws {
        let base = try td()
        let name = base.appendingPathComponent("swapped")
        let decoy = base.appendingPathComponent("decoy", isDirectory: true)
        try fm.createDirectory(at: decoy, withIntermediateDirectories: false)
        let root = try DirectoryHandle.openNoFollowAny(at: base)
        assertFails(.destinationUnwritable(path: "", errno: ELOOP)) {
            _ = try root.ensureChildDirectory(named: "swapped", afterFirstStatBeforeBind: {
                try self.fm.removeItem(at: name)
                try self.fm.createSymbolicLink(at: name, withDestinationURL: decoy)
            })
        }
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: decoy.path), [], "zero writes through the link")
        var st = stat()
        XCTAssertEqual(lstat(name.path, &st), 0)
        XCTAssertEqual(st.st_mode & S_IFMT, mode_t(S_IFLNK), "the swapped-in link is not deleted")
    }

    /// fstatat→openat gap swap of OUR directory for a FOREIGN directory: identity mismatch
    /// fails closed (EEXIST, mirroring makeChildDirectory) and the foreign directory —
    /// possibly a live concurrent creator's — is NOT deleted.
    func testEnsureWindowSwapToForeignDirIdentityMismatchEEXISTNotDeleted() throws {
        let base = try td()
        let name = base.appendingPathComponent("swapped", isDirectory: true)
        let root = try DirectoryHandle.openNoFollowAny(at: base)
        assertFails(.destinationUnwritable(path: "", errno: EEXIST)) {
            _ = try root.ensureChildDirectory(named: "swapped", afterFirstStatBeforeBind: {
                try self.fm.removeItem(at: name)
                try self.fm.createDirectory(at: name, withIntermediateDirectories: false)   // different inode
            })
        }
        var st = stat()
        XCTAssertEqual(lstat(name.path, &st), 0, "the foreign directory MUST survive")
        XCTAssertEqual(st.st_mode & S_IFMT, mode_t(S_IFDIR))
    }

    // MARK: - cross-cutting guards

    /// An EMPTY data-root residue (the keep-on-failure contract's only observable trace) is
    /// boot-neutral: the coordinator resolves a residue container and a pristine container
    /// to the IDENTICAL outcome, creating nothing in either.
    func testEmptyDataRootResidueIsBootNeutral() throws {
        func coordinator(root: URL) -> (MigrationCoordinator, URL) {
            let base = root.appendingPathComponent(AppPaths.nativeDataFolderName, isDirectory: true)
            let config = MigrationCoordinator.Config(
                activeDestination: base.appendingPathComponent("sololedger.db"),
                activeAttachmentsDir: base.appendingPathComponent("attachments", isDirectory: true)
                    .appendingPathComponent("docs", isDirectory: true),
                manifestsDir: base.appendingPathComponent("ImportManifests", isDirectory: true),
                workingDirectory: base.appendingPathComponent("ImportWork", isDirectory: true),
                preparedRoot: base.appendingPathComponent("PreparedImports", isDirectory: true))
            return (MigrationCoordinator(config: config,
                                         stagingRootOverride: base.appendingPathComponent("Staging", isDirectory: true)),
                    base)
        }
        let residueRoot = try td()
        let pristineRoot = try td()
        let (withResidue, residueBase) = coordinator(root: residueRoot)
        let (pristine, pristineBase) = coordinator(root: pristineRoot)
        try fm.createDirectory(at: residueBase, withIntermediateDirectories: false)   // the residue: empty data root

        XCTAssertEqual(withResidue.bootResolve(autoSourceCandidate: nil), .requiresSourceChoice)
        XCTAssertEqual(pristine.bootResolve(autoSourceCandidate: nil), .requiresSourceChoice)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: residueBase.path), [], "resolution creates nothing")
        XCTAssertFalse(fm.fileExists(atPath: pristineBase.path), "resolution creates nothing")
    }

    /// The EXISTING-store open path is untouched by STAGE 0: a missing parent still fails
    /// and never creates the data root (migration and open-existing behavior unchanged).
    func testOpenActiveExistingMissingParentCreatesNothing() throws {
        let base = try td()
        let parent = base.appendingPathComponent(AppPaths.nativeDataFolderName, isDirectory: true)
        let url = parent.appendingPathComponent("sololedger.db")
        let leaf = FileFingerprint(fileType: UInt16(S_IFREG), device: 1, inode: 1, size: 1,
                                   mtimeSec: 0, mtimeNSec: 0, ctimeSec: 0, ctimeNSec: 0)
        let evidence = ActiveOpenEvidence(parentDevice: 1, parentInode: 1, leaf: leaf)
        XCTAssertThrowsError(try LedgerStore.openActiveExistingHardened(databaseURL: url, expect: evidence))
        XCTAssertFalse(fm.fileExists(atPath: parent.path), "the existing-open path must never create the data root")
    }
}
