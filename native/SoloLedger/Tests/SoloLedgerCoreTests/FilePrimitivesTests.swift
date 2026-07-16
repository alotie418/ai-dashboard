import XCTest
@testable import SoloLedgerCore

/// Pure unit tests for the fd-bound, no-follow file primitives (Phase 2B-2 S1):
/// `FileHash.digestOfRegularFile`, `FileHash.copyRegularFileNoFollow`, `FileFingerprint`.
/// All fixtures are synthetic temp files.
final class FilePrimitivesTests: LedgerTestCase {

    private let fm = FileManager.default

    private func makeFile(_ name: String, _ bytes: String, in dir: URL? = nil) throws -> URL {
        let d = try dir ?? trackedTempDir()
        let url = d.appendingPathComponent(name)
        try Data(bytes.utf8).write(to: url)
        return url
    }

    private func assertNotARegularFile(_ block: @autoclosure () throws -> Any,
                                       _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try block(), label, file: file, line: line) { e in
            guard let fe = e as? FileHashError, case .notARegularFile = fe else {
                return XCTFail("\(label): got \(e)", file: file, line: line)
            }
        }
    }

    // MARK: - digestOfRegularFile

    func testDigestMatchesHashAndCountsBytes() throws {
        let url = try makeFile("f.bin", "hello world")
        let d = try FileHash.digestOfRegularFile(at: url)
        XCTAssertEqual(d.sha256, try FileHash.sha256Hex(of: url))
        XCTAssertEqual(d.size, 11)
        XCTAssertEqual(try FileHash.sha256HexOfRegularFile(at: url), d.sha256, "wrapper stays consistent")
    }

    func testDigestRejectsNonRegularAndReportsMissing() throws {
        let dir = try trackedTempDir()
        let real = try makeFile("real.bin", "X", in: dir)
        let link = dir.appendingPathComponent("link.bin")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        let fifo = dir.appendingPathComponent("fifo.bin")
        guard mkfifo(fifo.path, 0o644) == 0 else { throw XCTSkip("mkfifo unavailable") }

        assertNotARegularFile(try FileHash.digestOfRegularFile(at: link), "symlink")
        assertNotARegularFile(try FileHash.digestOfRegularFile(at: dir), "directory")
        assertNotARegularFile(try FileHash.digestOfRegularFile(at: fifo), "fifo (must not hang)")
        XCTAssertThrowsError(try FileHash.digestOfRegularFile(at: dir.appendingPathComponent("absent"))) { e in
            guard let fe = e as? FileHashError, fe.isFileMissing else { return XCTFail("got \(e)") }
        }
    }

    // MARK: - copyRegularFileNoFollow

    func testCopyHappyPathBindsDigestToWrittenBytes() throws {
        let src = try makeFile("src.bin", "payload-123")
        let dst = try trackedTempDir().appendingPathComponent("dst.bin")
        let d = try FileHash.copyRegularFileNoFollow(from: src, to: dst)
        XCTAssertEqual(try Data(contentsOf: dst), Data("payload-123".utf8))
        XCTAssertEqual(d.sha256, try FileHash.sha256Hex(of: dst))
        XCTAssertEqual(d.size, 11)
        // Destination is a real regular file (not a link/clone artifact).
        XCTAssertEqual(try FileFingerprint.capture(at: dst)?.isRegularFile, true)
    }

    func testCopyRejectsNonRegularSources() throws {
        let dir = try trackedTempDir()
        let real = try makeFile("real.bin", "X", in: dir)
        let link = dir.appendingPathComponent("link.bin")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)   // target VALID — still rejected
        let dangling = dir.appendingPathComponent("dangling.bin")
        try fm.createSymbolicLink(at: dangling, withDestinationURL: dir.appendingPathComponent("absent"))
        let fifo = dir.appendingPathComponent("fifo.bin")
        guard mkfifo(fifo.path, 0o644) == 0 else { throw XCTSkip("mkfifo unavailable") }

        for (src, label) in [(link, "symlink"), (dangling, "dangling symlink"), (dir, "directory"), (fifo, "fifo (must not hang)")] {
            let dst = try trackedTempDir().appendingPathComponent("dst.bin")
            assertNotARegularFile(try FileHash.copyRegularFileNoFollow(from: src, to: dst), label)
            XCTAssertNil(try FileFingerprint.capture(at: dst), "\(label): no destination may be created")
        }
        // Missing source is distinguishable (ENOENT) for retry decisions.
        XCTAssertThrowsError(try FileHash.copyRegularFileNoFollow(
            from: dir.appendingPathComponent("absent"), to: dir.appendingPathComponent("d.bin"))) { e in
            guard let fe = e as? FileHashError, fe.isFileMissing else { return XCTFail("got \(e)") }
        }
    }

    func testCopyDestinationIsExclusiveAndNeverFollowsLinks() throws {
        let src = try makeFile("src.bin", "NEW")
        let dir = try trackedTempDir()

        // Existing regular file at dst → refused, byte-for-byte untouched.
        let existing = try makeFile("dst1.bin", "OLD", in: dir)
        XCTAssertThrowsError(try FileHash.copyRegularFileNoFollow(from: src, to: existing)) { e in
            guard let fe = e as? FileHashError, case .destinationUnwritable = fe else { return XCTFail("got \(e)") }
        }
        XCTAssertEqual(try Data(contentsOf: existing), Data("OLD".utf8))

        // Dangling symlink at dst → refused; the link target must NOT be created through it.
        let linkTarget = dir.appendingPathComponent("victim.bin")
        let linkDst = dir.appendingPathComponent("dst2.bin")
        try fm.createSymbolicLink(at: linkDst, withDestinationURL: linkTarget)
        XCTAssertThrowsError(try FileHash.copyRegularFileNoFollow(from: src, to: linkDst)) { e in
            guard let fe = e as? FileHashError, case .destinationUnwritable = fe else { return XCTFail("got \(e)") }
        }
        XCTAssertNil(try FileFingerprint.capture(at: linkTarget), "nothing may be written through the link")

        // Symlink to an EXISTING file at dst → refused, target untouched.
        let victim = try makeFile("victim2.bin", "SAFE", in: dir)
        let linkDst2 = dir.appendingPathComponent("dst3.bin")
        try fm.createSymbolicLink(at: linkDst2, withDestinationURL: victim)
        XCTAssertThrowsError(try FileHash.copyRegularFileNoFollow(from: src, to: linkDst2))
        XCTAssertEqual(try Data(contentsOf: victim), Data("SAFE".utf8))
    }

    // MARK: - FileFingerprint

    func testFingerprintCapturesTypeAndIdentity() throws {
        let dir = try trackedTempDir()
        let file = try makeFile("f.bin", "abc", in: dir)
        let fp = try XCTUnwrap(FileFingerprint.capture(at: file))
        XCTAssertTrue(fp.isRegularFile); XCTAssertFalse(fp.isDirectory)
        XCTAssertEqual(fp.size, 3)
        XCTAssertGreaterThan(fp.inode, 0)

        let dfp = try XCTUnwrap(FileFingerprint.capture(at: dir))
        XCTAssertTrue(dfp.isDirectory)

        let link = dir.appendingPathComponent("l.bin")
        try fm.createSymbolicLink(at: link, withDestinationURL: file)
        let lfp = try XCTUnwrap(FileFingerprint.capture(at: link))
        XCTAssertFalse(lfp.isRegularFile, "lstat semantics: the LINK is fingerprinted, not its target")
        XCTAssertNotEqual(lfp.fileType, fp.fileType)

        XCTAssertNil(try FileFingerprint.capture(at: dir.appendingPathComponent("absent")), "ENOENT → nil")
    }

    /// A metadata error that is NOT ENOENT (here: EACCES via an unsearchable parent) must
    /// throw — never read as "the file does not exist" (which would fail open).
    func testFingerprintFailsClosedOnPermissionError() throws {
        let parent = try trackedTempDir().appendingPathComponent("locked", isDirectory: true)
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let file = parent.appendingPathComponent("f.bin")
        try Data("x".utf8).write(to: file)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: parent.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path) }

        XCTAssertThrowsError(try FileFingerprint.capture(at: file)) { e in
            guard let fe = e as? FileHashError, case .unreadable(_, let code) = fe else {
                return XCTFail("got \(e)")
            }
            XCTAssertNotEqual(code, ENOENT, "EACCES must not masquerade as absence")
        }
    }

    func testFingerprintDetectsContentAppendAndInodeSwap() throws {
        let dir = try trackedTempDir()
        let file = try makeFile("f.bin", "abc", in: dir)
        let fp1 = try XCTUnwrap(FileFingerprint.capture(at: file))

        // Append → size (and mtime) change.
        let h = try FileHandle(forWritingTo: file)
        try h.seekToEnd(); try h.write(contentsOf: Data("d".utf8)); try h.close()
        let fp2 = try XCTUnwrap(FileFingerprint.capture(at: file))
        XCTAssertNotEqual(fp1, fp2)

        // Same-content, same-size REPLACEMENT with the mtime forged back: the inode still
        // betrays it — this is exactly what a size+mtime-only fingerprint missed.
        let mtime = Date(timeIntervalSince1970: TimeInterval(fp2.mtimeSec) + TimeInterval(fp2.mtimeNSec) / 1e9)
        try fm.removeItem(at: file)
        try Data("abcd".utf8).write(to: file)
        try fm.setAttributes([.modificationDate: mtime], ofItemAtPath: file.path)
        let fp3 = try XCTUnwrap(FileFingerprint.capture(at: file))
        XCTAssertEqual(fp3.size, fp2.size)
        XCTAssertNotEqual(fp3, fp2, "inode (and ctime) must expose the swap")
        XCTAssertNotEqual(fp3.inode, fp2.inode)
    }
}
