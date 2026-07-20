import XCTest
@testable import SoloLedgerCore

/// Quiescence-gated prepared-DB identity + stored attachment-reference parsing (Phase 2B-1 C1).
/// All fixtures are synthetic temp files — no real database or attachments are touched.
final class PreparedDatabaseIdentityTests: LedgerTestCase {

    private let fm = FileManager.default

    /// A quiescent single-file DELETE-journal database with `rows` rows.
    private func makeQuiescentDB(named name: String = "prepared.db", rows: Int = 1) throws -> URL {
        let url = try trackedTempDir().appendingPathComponent(name)
        do {
            let db = try SQLiteDatabase(path: url.path)
            try db.execute("PRAGMA journal_mode = DELETE")
            try db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")
            for i in 0..<rows { try db.run("INSERT INTO t (v) VALUES (?)", [.text("row-\(i)")]) }
        }
        for suffix in PreparedDatabaseIdentity.sidecarSuffixes {
            XCTAssertFalse(fm.fileExists(atPath: url.path + suffix), "fixture must be quiescent")
        }
        return url
    }

    private func assertThrows(_ url: URL, _ expected: (PreparedDatabaseError) -> Bool,
                              _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try PreparedDatabaseIdentity.compute(at: url), label, file: file, line: line) { e in
            guard let pe = e as? PreparedDatabaseError, expected(pe) else {
                return XCTFail("\(label): got \(e)", file: file, line: line)
            }
        }
    }

    // MARK: - Identity

    func testIdentityStablePrefixedAndMatchesFileHash() throws {
        let url = try makeQuiescentDB()
        let id1 = try PreparedDatabaseIdentity.compute(at: url)
        let id2 = try PreparedDatabaseIdentity.compute(at: url)
        XCTAssertEqual(id1, id2, "identity must be deterministic")
        XCTAssertEqual(id1, "sha256:" + (try FileHash.sha256Hex(of: url)))
    }

    func testDifferentContentDifferentIdentity() throws {
        let a = try PreparedDatabaseIdentity.compute(at: makeQuiescentDB(rows: 1))
        let b = try PreparedDatabaseIdentity.compute(at: makeQuiescentDB(rows: 2))
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Quiescence gate (fail-closed)

    func testMissingDatabaseRejected() throws {
        let url = try trackedTempDir().appendingPathComponent("absent.db")
        assertThrows(url, { if case .databaseMissing = $0 { return true }; return false }, "missing")
    }

    func testDirectoryRejected() throws {
        let url = try trackedTempDir().appendingPathComponent("dir.db", isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        assertThrows(url, { if case .databaseNotRegularFile = $0 { return true }; return false }, "directory")
    }

    func testSymlinkDatabaseRejected() throws {
        let real = try makeQuiescentDB()
        let link = try trackedTempDir().appendingPathComponent("link.db")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        assertThrows(link, { if case .databaseNotRegularFile = $0 { return true }; return false }, "symlink")
    }

    func testAnySidecarPresenceRejected() throws {
        for suffix in PreparedDatabaseIdentity.sidecarSuffixes {
            let url = try makeQuiescentDB()
            try Data("x".utf8).write(to: URL(fileURLWithPath: url.path + suffix))
            assertThrows(url, { if case .notQuiescent = $0 { return true }; return false }, "plain \(suffix)")
        }
        // A symlink NAMED like a sidecar counts as present too (lstat semantics).
        let url = try makeQuiescentDB()
        let target = try makeQuiescentDB(named: "target.db")
        try fm.createSymbolicLink(at: URL(fileURLWithPath: url.path + "-wal"), withDestinationURL: target)
        assertThrows(url, { if case .notQuiescent = $0 { return true }; return false }, "symlink -wal")
    }

    func testWalJournalModeRejectedEvenWithoutSidecars() throws {
        let url = try trackedTempDir().appendingPathComponent("walmode.db")
        do {
            let db = try SQLiteDatabase(path: url.path)
            try db.execute("PRAGMA journal_mode = WAL")
            try db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY)")
            try db.run("INSERT INTO t (id) VALUES (1)")
        }
        // The clean close checkpointed and removed -wal/-shm; drop any leftovers so the
        // header (still WAL) is the ONLY signal — exactly the case the pragma probe closes.
        for suffix in PreparedDatabaseIdentity.sidecarSuffixes {
            try? fm.removeItem(atPath: url.path + suffix)
        }
        assertThrows(url, { if case .wrongJournalMode(let m) = $0 { return m == "wal" }; return false }, "wal header")
    }

    func testGarbageBytesRejected() throws {
        let url = try trackedTempDir().appendingPathComponent("garbage.db")
        try Data("this is not a sqlite database, not even close".utf8).write(to: url)
        assertThrows(url, { if case .unreadable = $0 { return true }; return false }, "garbage")
    }

    // MARK: - Read-only proof

    func testComputeIsReadOnlyAndCreatesNoFiles() throws {
        let url = try makeQuiescentDB(rows: 3)
        let dir = url.deletingLastPathComponent()
        let before = try fm.contentsOfDirectory(atPath: dir.path).sorted()
        let hashBefore = try FileHash.sha256Hex(of: url)

        _ = try PreparedDatabaseIdentity.compute(at: url)

        XCTAssertEqual(try fm.contentsOfDirectory(atPath: dir.path).sorted(), before,
                       "compute must not create journal/WAL/temp files")
        XCTAssertEqual(try FileHash.sha256Hex(of: url), hashBefore, "compute must not modify the database")
    }

    // MARK: - No-follow, regular-file-only hash primitive

    func testRegularFileHashMatchesPlainHash() throws {
        let url = try trackedTempDir().appendingPathComponent("f.bin")
        try Data("hello".utf8).write(to: url)
        XCTAssertEqual(try FileHash.sha256HexOfRegularFile(at: url), try FileHash.sha256Hex(of: url))
    }

    func testNoFollowHashRejectsSymlinkDirectoryAndFifo() throws {
        let dir = try trackedTempDir()
        let real = dir.appendingPathComponent("real.bin")
        try Data("X".utf8).write(to: real)

        let link = dir.appendingPathComponent("link.bin")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        let dangling = dir.appendingPathComponent("dangling.bin")
        try fm.createSymbolicLink(at: dangling, withDestinationURL: dir.appendingPathComponent("absent"))
        let sub = dir.appendingPathComponent("sub", isDirectory: true)
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        let fifo = dir.appendingPathComponent("fifo.bin")
        guard mkfifo(fifo.path, 0o644) == 0 else { throw XCTSkip("mkfifo unavailable") }

        // The FIFO case must return PROMPTLY (O_NONBLOCK) — a hang here is the regression.
        for url in [link, dangling, sub, fifo] {
            XCTAssertThrowsError(try FileHash.sha256HexOfRegularFile(at: url), url.lastPathComponent) { e in
                guard let fe = e as? FileHashError, case .notARegularFile = fe else {
                    return XCTFail("\(url.lastPathComponent): got \(e)")
                }
            }
        }
    }

    func testNoFollowHashMissingFileIsFileMissing() throws {
        let url = try trackedTempDir().appendingPathComponent("absent.bin")
        XCTAssertThrowsError(try FileHash.sha256HexOfRegularFile(at: url)) { e in
            guard let fe = e as? FileHashError, fe.isFileMissing else { return XCTFail("got \(e)") }
        }
    }

    /// The identity hash itself goes through the no-follow primitive AND quiescence is
    /// re-checked after hashing — dedicated regression guard for the ordering.
    func testIdentityUsesNoFollowHash() throws {
        let real = try makeQuiescentDB()
        let link = try trackedTempDir().appendingPathComponent("linked.db")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        assertThrows(link, { if case .databaseNotRegularFile = $0 { return true }; return false }, "symlinked db")
        XCTAssertEqual(try PreparedDatabaseIdentity.compute(at: real),
                       "sha256:" + (try FileHash.sha256HexOfRegularFile(at: real)))
    }

    // MARK: - AttachmentRelPath parsing

    func testRelPathParsesValidReference() {
        XCTAssertEqual(AttachmentRelPath.bareName(of: "attachments/docs/doc-1_a.PDF"), "doc-1_a.PDF")
        XCTAssertEqual(AttachmentRelPath.bareName(of: "attachments/docs/9.png"), "9.png")
    }

    func testRelPathRejectsIllegalReferences() {
        let bad = [
            "/tmp/x.pdf",                          // absolute
            "/attachments/docs/x.pdf",             // absolute with matching tail
            "attachments/docs/../x.pdf",           // traversal
            "attachments/docs/a..b.pdf",           // embedded '..' (matches Electron's extra guard)
            "attachments/docs/",                   // empty name
            "attachments/docs",                    // missing separator
            "attachments/docs//x.pdf",             // extra slash
            "attachments/docs/a/b.pdf",            // nested segment
            "docs/x.pdf",                          // wrong prefix
            "ATTACHMENTS/DOCS/x.pdf",              // case-sensitive prefix
            " attachments/docs/x.pdf",             // leading space
            "attachments/docs/.hidden",            // first char not alphanumeric
            "attachments/docs/-dash.pdf",          // first char not alphanumeric
            "attachments/docs/文件.pdf",            // non-ASCII (REL_RE is ASCII-only)
            "attachments/docs/a b.pdf",            // space in name
            "",                                    // empty
        ]
        for raw in bad {
            XCTAssertNil(AttachmentRelPath.bareName(of: raw), "must reject: '\(raw)'")
        }
    }
}
