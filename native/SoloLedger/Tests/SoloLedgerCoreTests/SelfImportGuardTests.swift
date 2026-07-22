import XCTest
@testable import SoloLedgerCore

/// N7.1 (§3.3): the Core self-import guard — canonical (device, inode) identity judgment,
/// the narrow `DirectoryHandle.parentDirectory()` primitive, fail-closed metadata errors,
/// and the coordinator's no-path `invalidSource` mapping. Coverage is the REACHABLE
/// role × relationship combinations (not the full 3×3 matrix): `nativeDataRoot` and
/// `activeAttachments` each pin sameIdentity / sourceAncestorOfProtected /
/// sourceDescendantOfProtected; `activeDatabase` pins sameIdentity (including hard links —
/// a lone file cannot be an ancestor, and "descendant of a file" does not exist). Every
/// test injects an ISOLATED protected identity (temp roots) — the real container is never
/// consulted.
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

    // MARK: - Capability boundary (N7.2 sandbox fix)
    //
    // A sandboxed process holding a Powerbox grant can open the granted directory and its
    // DESCENDANTS but nothing above it. The POSIX equivalent — a parent directory with
    // execute-only permissions (0o311: traversable, not readable/openable) — makes the old
    // upward `openat(fd, "..")` walk fail with EACCES exactly like the seatbelt denial did
    // in a real sandbox, so these tests pin the sandbox contract WITHOUT needing a sandbox:
    // the guard must never require authority above the source, protected-side judgments
    // must never require authority above the protected root, and a permission failure
    // inside a nominated verification must stay fail-closed.

    /// Restores permissions in teardown so the tracked temp tree can be reaped.
    private func restrict(_ url: URL, to mode: Int16) throws {
        try fm.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: url.path)
        addTeardownBlock { [fm] in
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    func testIndependentSourcePassesWithUnreadableParent() throws {
        // THE sandbox regression pin: an independent source whose PARENT cannot be opened
        // (only traversed) must pass the guard — the old upward walk failed here with
        // EACCES and surfaced as a bogus retriable "I/O problem".
        let p = try makeProtected()
        let boundary = try trackedTempDir().appendingPathComponent("boundary", isDirectory: true)
        let src = boundary.appendingPathComponent("Source", isDirectory: true)
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try Data("independent-db".utf8).write(to: src.appendingPathComponent(AppPaths.databaseFileName))
        try restrict(boundary, to: 0o311)
        XCTAssertNoThrow(try check(.userSelectedDataDir(src), p))
    }

    func testEmptySourceWithUnreadableParentReachesSourceDatabaseMissing() throws {
        // Invariant: after the guard confirms independence, an EMPTY directory must land in
        // `sourceDatabaseMissing` (→ terminal invalidSource), not in a wrapped I/O error.
        let p = try makeProtected()
        let boundary = try trackedTempDir().appendingPathComponent("boundary", isDirectory: true)
        let src = boundary.appendingPathComponent("Empty", isDirectory: true)
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try restrict(boundary, to: 0o311)
        let id = ImportID("test-\(UUID().uuidString)")!
        XCTAssertThrowsError(try StagingIngest().ingest(
            .userSelectedDataDir(src), importID: id, timestamp: "t",
            maxAttempts: 3, hooks: IngestHooks(), protecting: p.identity)) { error in
            guard case IngestError.sourceDatabaseMissing = error else {
                return XCTFail("empty independent dir must be sourceDatabaseMissing, got \(error)")
            }
        }
    }

    func testProtectedRootWithUnreadableParentStillRejectsDescendant() throws {
        // Protected-side symmetry: judging "source is INSIDE the data root" must need no
        // authority above the data root itself.
        let boundary = try trackedTempDir().appendingPathComponent("boundary", isDirectory: true)
        let root = boundary.appendingPathComponent("DataRoot", isDirectory: true)
        let inside = root.appendingPathComponent("Staging", isDirectory: true)
            .appendingPathComponent("import-x", isDirectory: true)
        try fm.createDirectory(at: inside, withIntermediateDirectories: true)
        let p = Protected(identity: .init(dataRootURL: root,
                                          activeDatabaseURL: root.appendingPathComponent(AppPaths.databaseFileName),
                                          activeAttachmentsRootURL: root.appendingPathComponent("attachments", isDirectory: true)
                                              .appendingPathComponent("docs", isDirectory: true)),
                          rootURL: root,
                          activeDBURL: root.appendingPathComponent(AppPaths.databaseFileName),
                          attachmentsURL: root.appendingPathComponent("attachments", isDirectory: true)
                              .appendingPathComponent("docs", isDirectory: true))
        try restrict(boundary, to: 0o311)
        assertRejected(.userSelectedDataDir(inside), p,
                       role: .nativeDataRoot, relationship: .sourceDescendantOfProtected)
    }

    func testSourceContainingProtectedRejectedWithUnreadableGrandparent() throws {
        // Ancestor direction under the boundary: a source CONTAINING the data root is still
        // refused even when the source's own parent is unreadable.
        let boundary = try trackedTempDir().appendingPathComponent("boundary", isDirectory: true)
        let outer = boundary.appendingPathComponent("outer", isDirectory: true)
        let root = outer.appendingPathComponent("DataRoot", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let p = Protected(identity: .init(dataRootURL: root,
                                          activeDatabaseURL: root.appendingPathComponent(AppPaths.databaseFileName),
                                          activeAttachmentsRootURL: root.appendingPathComponent("attachments", isDirectory: true)
                                              .appendingPathComponent("docs", isDirectory: true)),
                          rootURL: root,
                          activeDBURL: root.appendingPathComponent(AppPaths.databaseFileName),
                          attachmentsURL: root.appendingPathComponent("attachments", isDirectory: true)
                              .appendingPathComponent("docs", isDirectory: true))
        try restrict(boundary, to: 0o311)
        assertRejected(.userSelectedDataDir(outer), p,
                       role: .nativeDataRoot, relationship: .sourceAncestorOfProtected)
    }

    func testPermissionDeniedMidVerificationFailsClosed() throws {
        // A NOMINATED containment whose verification descent hits a permission denial must
        // fail closed — EACCES/EPERM is never read as "no overlap" (and never as overlap
        // either: the import is refused with an error, not silently classified).
        let top = try trackedTempDir().appendingPathComponent("top", isDirectory: true)
        let mid = top.appendingPathComponent("mid", isDirectory: true)
        let root = mid.appendingPathComponent("DataRoot", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let p = Protected(identity: .init(dataRootURL: root,
                                          activeDatabaseURL: root.appendingPathComponent(AppPaths.databaseFileName),
                                          activeAttachmentsRootURL: root.appendingPathComponent("attachments", isDirectory: true)
                                              .appendingPathComponent("docs", isDirectory: true)),
                          rootURL: root,
                          activeDBURL: root.appendingPathComponent(AppPaths.databaseFileName),
                          attachmentsURL: root.appendingPathComponent("attachments", isDirectory: true)
                              .appendingPathComponent("docs", isDirectory: true))
        try restrict(mid, to: 0o111)   // traversable, but not openable for reading
        XCTAssertThrowsError(try check(.userSelectedDataDir(top), p)) { error in
            guard case FileHashError.unreadable = error else {
                return XCTFail("denied verification descent must fail closed as unreadable, got \(error)")
            }
        }
    }

    func testDataVolumeMountPointSourceRefusedAsAncestor() throws {
        // Firmlink/mount-junction coverage: "/System/Volumes/Data" physically contains the
        // protected root (which canonicalizes under "/") with no shared string prefix. The
        // mount-point branch must still refuse it — the one containment shape the canonical
        // prefix cannot see.
        let p = try makeProtected()
        var fs = statfs()
        guard statfs(p.rootURL.path, &fs) == 0 else { return XCTFail("statfs failed") }
        let mnt = withUnsafeBytes(of: &fs.f_mntonname) { raw in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        try XCTSkipUnless(mnt == "/System/Volumes/Data",
                          "temp tree is not on the standard data volume (mount: \(mnt))")
        assertRejected(.userSelectedDataDir(URL(fileURLWithPath: mnt, isDirectory: true)), p,
                       role: .nativeDataRoot, relationship: .sourceAncestorOfProtected)
    }

    // MARK: - Firmlink / data-volume alias containment (P1 follow-up, PR #374)
    //
    // A source may be SELECTED through the physical `/System/Volumes/Data/...` spelling of a
    // path whose primary (firmlink-normalized) name is `/Users/...` or `/private/var/...`.
    // The concern: such an alias defeats the canonical-prefix containment check and lets a
    // protected ancestor/descendant slip through as "independent". These tests reproduce the
    // exact selection through the alias spelling and assert the verdict — proving whether the
    // guard's identity resolution already collapses the alias (fcntl(F_GETPATH) is
    // firmlink-normalizing) or a dedicated alias step is required.

    /// The `/System/Volumes/Data`-prefixed physical spelling of `url`, but ONLY when it
    /// resolves to the very same filesystem object here (else nil → the caller skips: the
    /// machine isn't the standard split-volume layout). The path is realpath-canonicalized
    /// first (`/var/…` → `/private/var/…`) so the alias is anchored on a real firmlink root.
    private func dataVolumeAlias(of url: URL) -> URL? {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(url.path, &buf) != nil else { return nil }
        let canonical = String(cString: buf)
        let alias = URL(fileURLWithPath: "/System/Volumes/Data" + canonical, isDirectory: true)
        func rid(_ u: URL) -> (NSCopying & NSSecureCoding & NSObjectProtocol)? {
            (try? u.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier
        }
        guard let a = rid(alias), let o = rid(url), a.isEqual(o) else { return nil }
        // The alias must be a genuinely different STRING (else the test is vacuous).
        guard alias.path != canonical, alias.path.hasPrefix("/System/Volumes/Data/") else { return nil }
        return alias
    }

    func testDescendantSelectedViaDataVolumeAliasIsRejected() throws {
        let p = try makeProtected()
        let inside = p.rootURL.appendingPathComponent("Staging", isDirectory: true)
            .appendingPathComponent("import-x", isDirectory: true)
        try fm.createDirectory(at: inside, withIntermediateDirectories: true)
        guard let alias = dataVolumeAlias(of: inside) else {
            throw XCTSkip("temp tree not reachable via /System/Volumes/Data alias")
        }
        assertRejected(.userSelectedDataDir(alias), p,
                       role: .nativeDataRoot, relationship: .sourceDescendantOfProtected)
    }

    func testAliasAncestorBelowMountContainingProtectedIsRejected() throws {
        // The tracked temp dir CONTAINS DataRoot; selecting it through the below-mount alias
        // spelling must still be refused as an ancestor overlap.
        let p = try makeProtected()
        guard let alias = dataVolumeAlias(of: p.rootURL.deletingLastPathComponent()) else {
            throw XCTSkip("temp tree not reachable via /System/Volumes/Data alias")
        }
        assertRejected(.userSelectedDataDir(alias), p,
                       role: .nativeDataRoot, relationship: .sourceAncestorOfProtected)
    }

    func testIndependentSameVolumeSourceViaAliasStillPasses() throws {
        // Same filesystem (identical fsid) is NOT sufficient to refuse: a genuinely
        // independent source, even selected through the data-volume alias, must import.
        let p = try makeProtected()
        let src = try makeIndependentSource()
        guard let alias = dataVolumeAlias(of: src) else {
            throw XCTSkip("temp tree not reachable via /System/Volumes/Data alias")
        }
        XCTAssertNoThrow(try check(.userSelectedDataDir(alias), p))
    }

    /// The mount junction is the ONE spelling F_GETPATH does NOT normalize away
    /// (`/System/Volumes/Data`, and its parents `/System/Volumes`, `/System`, `/`, live on
    /// the system volume and keep their literal path), so an ancestor selected there has a
    /// canonical path that shares no firmlink-normalized prefix with the protected root.
    /// These pin that `containsMountPoint` refuses every above-junction ancestor, not just
    /// the mount point itself.
    private func assertAboveMountAncestorRefused(_ path: String) throws {
        let p = try makeProtected()
        var fs = statfs()
        guard statfs(p.rootURL.path, &fs) == 0 else { return XCTFail("statfs failed") }
        let mnt = withUnsafeBytes(of: &fs.f_mntonname) { raw in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        try XCTSkipUnless(mnt == "/System/Volumes/Data",
                          "temp tree is not on the standard data volume (mount: \(mnt))")
        assertRejected(.userSelectedDataDir(URL(fileURLWithPath: path, isDirectory: true)), p,
                       role: .nativeDataRoot, relationship: .sourceAncestorOfProtected)
    }

    func testDataVolumeParentDirRefusedAsAncestor() throws {
        try assertAboveMountAncestorRefused("/System/Volumes")
    }

    func testSystemDirAboveMountRefusedAsAncestor() throws {
        try assertAboveMountAncestorRefused("/System")
    }
}
