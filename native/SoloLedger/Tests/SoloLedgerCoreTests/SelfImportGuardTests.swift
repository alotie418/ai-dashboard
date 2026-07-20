import XCTest
@testable import SoloLedgerCore

/// N7.1 (§3.3): the Core self-import guard — canonical (device, inode) identity judgment,
/// three roles × three relationships, hard links folded into `sameIdentity`, the narrow
/// `DirectoryHandle.parentDirectory()` primitive, fail-closed metadata errors, and the
/// coordinator's no-path `invalidSource` mapping. Every test injects an ISOLATED protected
/// identity (temp roots) — the real container is never consulted.
final class SelfImportGuardTests: LedgerTestCase {

    private let fm = FileManager.default

    // MARK: - Harness

    private struct Protected {
        let identity: SelfImportGuard.ProtectedIdentity
        let rootURL: URL
        let activeDBURL: URL
        let attachmentsURL: URL
    }

    /// A protected layout mirroring production nesting: `<root>/sololedger.db` +
    /// `<root>/attachments/docs`. `materialize` controls first-install scenarios.
    private func makeProtected(materializeRoot: Bool = true, materializeDB: Bool = true,
                               materializeAttachments: Bool = true) throws -> Protected {
        let root = try trackedTempDir().appendingPathComponent("DataRoot", isDirectory: true)
        let db = root.appendingPathComponent(AppPaths.databaseFileName)
        let docs = root.appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent("docs", isDirectory: true)
        if materializeRoot { try fm.createDirectory(at: root, withIntermediateDirectories: true) }
        if materializeDB { try Data("active-db".utf8).write(to: db) }
        if materializeAttachments { try fm.createDirectory(at: docs, withIntermediateDirectories: true) }
        return Protected(identity: .init(dataRootURL: root, activeDatabaseURL: db,
                                         activeAttachmentsRootURL: docs),
                         rootURL: root, activeDBURL: db, attachmentsURL: docs)
    }

    /// An independent source tree `<tmp>/Source/sololedger.db` (content copied, new identity).
    private func makeIndependentSource() throws -> URL {
        let src = try trackedTempDir().appendingPathComponent("Source", isDirectory: true)
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try Data("active-db".utf8).write(to: src.appendingPathComponent(AppPaths.databaseFileName))
        return src
    }

    private func check(_ source: MigrationSource, _ p: Protected, maxDepth: Int = 64) throws {
        try SelfImportGuard(identity: p.identity, maxDepth: maxDepth).check(source)
    }

    private func assertRejected(_ source: MigrationSource, _ p: Protected,
                                role: SelfImportRole, relationship: SelfImportRelationship,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try check(source, p), file: file, line: line) { error in
            guard case IngestError.sourceIsActiveData(let r, let rel) = error else {
                return XCTFail("expected sourceIsActiveData, got \(error)", file: file, line: line)
            }
            XCTAssertEqual(r, role, file: file, line: line)
            XCTAssertEqual(rel, relationship, file: file, line: line)
        }
    }

    // MARK: - sameIdentity (directory / database / hard link)

    func testSourceDirEqualsDataRootIsSameIdentity() throws {
        let p = try makeProtected()
        assertRejected(.userSelectedDataDir(p.rootURL), p,
                       role: .nativeDataRoot, relationship: .sameIdentity)
    }

    func testSourceDirEqualsAttachmentsRootIsSameIdentity() throws {
        let p = try makeProtected()
        assertRejected(.userSelectedDataDir(p.attachmentsURL), p,
                       role: .activeAttachments, relationship: .sameIdentity)
    }

    func testHardLinkToActiveDatabaseIsSameIdentity() throws {
        // The pinned claim (§3.3): a hard link is IDENTITY-EQUAL to the active DB — the guard
        // cannot (and does not claim to) distinguish the original entry from the link, so it
        // must land in `sameIdentity`, never a separate hard-link diagnosis.
        let p = try makeProtected()
        let src = try trackedTempDir().appendingPathComponent("Elsewhere", isDirectory: true)
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try fm.linkItem(at: p.activeDBURL, to: src.appendingPathComponent(AppPaths.databaseFileName))
        assertRejected(.userSelectedDataDir(src), p,
                       role: .activeDatabase, relationship: .sameIdentity)
    }

    func testLegacySingleDBSelectingActiveDatabaseIsSameIdentity() throws {
        let p = try makeProtected()
        assertRejected(.legacySingleDB(p.activeDBURL), p,
                       role: .activeDatabase, relationship: .sameIdentity)
    }

    func testLegacySingleDBHardLinkIsSameIdentity() throws {
        let p = try makeProtected()
        let alias = try trackedTempDir().appendingPathComponent("alias.db")
        try fm.linkItem(at: p.activeDBURL, to: alias)
        assertRejected(.legacySingleDB(alias), p,
                       role: .activeDatabase, relationship: .sameIdentity)
    }

    // MARK: - Descendant / ancestor (both directions)

    func testSourceInsideDataRootIsDescendant() throws {
        let p = try makeProtected()
        let inside = p.rootURL.appendingPathComponent("Staging", isDirectory: true)
            .appendingPathComponent("import-x", isDirectory: true)
        try fm.createDirectory(at: inside, withIntermediateDirectories: true)
        assertRejected(.userSelectedDataDir(inside), p,
                       role: .nativeDataRoot, relationship: .sourceDescendantOfProtected)
    }

    func testSourceInsideAttachmentsReportsNearestProtectedObject() throws {
        let p = try makeProtected()
        let inside = p.attachmentsURL.appendingPathComponent("sub", isDirectory: true)
        try fm.createDirectory(at: inside, withIntermediateDirectories: true)
        assertRejected(.userSelectedDataDir(inside), p,
                       role: .activeAttachments, relationship: .sourceDescendantOfProtected)
    }

    func testLegacySingleDBInsideDataRootIsDescendant() throws {
        let p = try makeProtected()
        let stray = p.rootURL.appendingPathComponent("stray.db")
        try Data("stray".utf8).write(to: stray)
        assertRejected(.legacySingleDB(stray), p,
                       role: .nativeDataRoot, relationship: .sourceDescendantOfProtected)
    }

    func testSourceContainingDataRootIsAncestor() throws {
        let p = try makeProtected()
        // The tracked temp dir CONTAINS DataRoot — selecting it is a containment overlap.
        assertRejected(.userSelectedDataDir(p.rootURL.deletingLastPathComponent()), p,
                       role: .nativeDataRoot, relationship: .sourceAncestorOfProtected)
    }

    func testSourceContainingOnlyAttachmentsIsAttachmentsAncestor() throws {
        // Split layout (attachments NOT nested under the data root): a source containing the
        // attachments root but not the data root must still be refused, with the right role.
        let root = try trackedTempDir().appendingPathComponent("DataRoot", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let attParent = try trackedTempDir()
        let docs = attParent.appendingPathComponent("active-docs", isDirectory: true)
        try fm.createDirectory(at: docs, withIntermediateDirectories: true)
        let p = Protected(identity: .init(dataRootURL: root,
                                          activeDatabaseURL: root.appendingPathComponent(AppPaths.databaseFileName),
                                          activeAttachmentsRootURL: docs),
                          rootURL: root, activeDBURL: root.appendingPathComponent(AppPaths.databaseFileName),
                          attachmentsURL: docs)
        assertRejected(.userSelectedDataDir(attParent), p,
                       role: .activeAttachments, relationship: .sourceAncestorOfProtected)
    }

    // MARK: - Legitimate sources stay importable

    func testIndependentCopyWithIdenticalContentPasses() throws {
        // Identity beats strings AND content: a real copy (different device+inode) of the very
        // same bytes is a legitimate independent source and MUST pass (§3.3).
        let p = try makeProtected()
        XCTAssertNoThrow(try check(.userSelectedDataDir(makeIndependentSource()), p))
    }

    func testFirstInstallMissingRootAllowsIndependentSource() throws {
        let p = try makeProtected(materializeRoot: false, materializeDB: false,
                                  materializeAttachments: false)
        XCTAssertNoThrow(try check(.userSelectedDataDir(makeIndependentSource()), p))
    }

    func testFirstInstallMissingRootStillRefusesAncestorOfFutureRoot() throws {
        // Root does not exist yet, but its would-be parent DOES — selecting that parent must
        // still be refused via the deepest-existing-ancestor walk (§3.3 first-install rule).
        let p = try makeProtected(materializeRoot: false, materializeDB: false,
                                  materializeAttachments: false)
        assertRejected(.userSelectedDataDir(p.rootURL.deletingLastPathComponent()), p,
                       role: .nativeDataRoot, relationship: .sourceAncestorOfProtected)
    }

    // MARK: - Fail-closed metadata behavior

    func testAbsentSourceDirPassesGuardForLaterGates() throws {
        // ENOENT is NOT an overlap: the guard yields to the existing early gates
        // (`sourceDatabaseMissing`) instead of misclassifying a missing source.
        let p = try makeProtected()
        let ghost = try trackedTempDir().appendingPathComponent("ghost", isDirectory: true)
        XCTAssertNoThrow(try check(.userSelectedDataDir(ghost), p))
    }

    func testSymlinkedSourceDirFailsClosed() throws {
        let p = try makeProtected()
        let real = try makeIndependentSource()
        let link = try trackedTempDir().appendingPathComponent("link", isDirectory: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertThrowsError(try check(.userSelectedDataDir(link), p)) { error in
            guard case FileHashError.notADirectory = error else {
                return XCTFail("symlinked source dir must fail closed as notADirectory, got \(error)")
            }
        }
    }

    func testUnreadableSourceDirFailsClosed() throws {
        let p = try makeProtected()
        let src = try makeIndependentSource()
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: src.path)
        XCTAssertThrowsError(try check(.userSelectedDataDir(src), p)) { error in
            guard case FileHashError.unreadable = error else {
                return XCTFail("permission failure must fail closed as unreadable, got \(error)")
            }
        }
    }

    func testWalkDepthExhaustionFailsClosed() throws {
        let p = try makeProtected()
        let deep = try makeIndependentSource()
            .appendingPathComponent("a", isDirectory: true)
            .appendingPathComponent("b", isDirectory: true)
        try fm.createDirectory(at: deep, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: deep.appendingPathComponent(AppPaths.databaseFileName))
        XCTAssertThrowsError(try check(.userSelectedDataDir(deep), p, maxDepth: 1)) { error in
            guard let e = error as? SelfImportGuard.AncestryUnverifiable else {
                return XCTFail("depth exhaustion must fail closed, got \(error)")
            }
            XCTAssertFalse(e.description.contains("/"), "unverifiable error must carry no path")
        }
    }

    // MARK: - parentDirectory(): identity binding, fixpoint

    func testParentDirectoryBindsRealParentIdentity() throws {
        let parent = try trackedTempDir()
        let child = parent.appendingPathComponent("child", isDirectory: true)
        try fm.createDirectory(at: child, withIntermediateDirectories: true)
        let childHandle = try DirectoryHandle.open(at: child)
        let viaChild = try childHandle.parentDirectory()
        let direct = try DirectoryHandle.open(at: parent)
        XCTAssertEqual(viaChild.device, direct.device)
        XCTAssertEqual(viaChild.inode, direct.inode)
    }

    func testParentDirectoryAtFilesystemRootIsFixpoint() throws {
        let root = try DirectoryHandle.open(at: URL(fileURLWithPath: "/"))
        let parent = try root.parentDirectory()
        XCTAssertEqual(parent.device, root.device)
        XCTAssertEqual(parent.inode, root.inode, "the root's parent must be the root itself")
    }

    // MARK: - No-path discipline

    func testSelfImportErrorDescriptionContainsNoPath() throws {
        let p = try makeProtected()
        do {
            try check(.userSelectedDataDir(p.rootURL), p)
            XCTFail("must reject")
        } catch {
            let text = String(describing: error)
            XCTAssertFalse(text.contains("/"), "sourceIsActiveData must never carry a path: \(text)")
            XCTAssertTrue(text.contains("nativeDataRoot"))
            XCTAssertTrue(text.contains("sameIdentity"))
        }
    }

    // MARK: - Coordinator mapping (terminal invalidSource, labels only)

    func testCoordinatorMapsSelfImportToTerminalInvalidSourceWithoutPaths() throws {
        func dir(_ name: String) throws -> URL {
            let d = try trackedTempDir().appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
            return d
        }
        let config = MigrationCoordinator.Config(
            activeDestination: try dir("ActiveSlot").appendingPathComponent(AppPaths.databaseFileName),
            activeAttachmentsDir: try dir("active-docs"),
            manifestsDir: try dir("ImportManifests"),
            workingDirectory: try dir("Work"),
            preparedRoot: try dir("PreparedImports"))
        let staging = try dir("Staging")
        let identity = SelfImportGuard.ProtectedIdentity(
            dataRootURL: config.activeDestination.deletingLastPathComponent(),
            activeDatabaseURL: config.activeDestination,
            activeAttachmentsRootURL: config.activeAttachmentsDir)
        // Mirror the production runIngest wiring: real ingest, the coordinator's OWN identity.
        let coordinator = MigrationCoordinator(config: config, stagingRootOverride: staging,
                                               ingestOverride: { source, id in
            try StagingIngest().ingest(source, importID: id, timestamp: "t",
                                       maxAttempts: 3, hooks: IngestHooks(), protecting: identity)
        })
        let selfSource = MigrationSource.userSelectedDataDir(config.activeDestination.deletingLastPathComponent())
        guard case .blocked(let block) = coordinator.runImport(source: selfSource) else {
            return XCTFail("self-import must be blocked")
        }
        XCTAssertEqual(block.code, .invalidSource)
        XCTAssertEqual(block.classification, .terminal)
        XCTAssertEqual(block.params["reason"], "sourceIsActiveData")
        XCTAssertEqual(block.params["role"], "nativeDataRoot")
        XCTAssertEqual(block.params["relationship"], "sameIdentity")
        for (key, value) in block.params {
            XCTAssertFalse(value.contains("/"), "param \(key) must not carry a path: \(value)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.activeDestination.path),
                       "a rejected self-import must not create anything in the active slot")
    }
}
