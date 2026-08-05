import XCTest
import CryptoKit
@testable import SoloLedgerCore

/// N-PR-0b: the rollback point taken immediately before an in-place migration of the LIVE active
/// ledger.
///
/// The suite is organised by the property each group protects, not by function:
///
///  * **S** — a pending migration produces a verified snapshot, and one that is NOT pending
///    produces nothing at all.
///  * **F** — every way the snapshot can fail leaves the ledger unmigrated and BYTE-IDENTICAL.
///    F2/F3 hash the active file before and after, because "we did not migrate" is a claim about
///    bytes and nothing weaker proves it.
///  * **R** — the snapshot is restorable through the SHIPPING restore chain. R4 pins the reason
///    the bundle format was chosen: a bare `.db` is a backup nothing can restore.
///  * **I** — idempotence and retention.
///  * **M** — the mutation points, each named so a reviewer can check the list against the code.
final class PreMigrationSnapshotTests: LedgerTestCase {

    private let fm = FileManager.default

    // MARK: - Fixtures

    private enum Fail: Error { case captureFailed }

    /// A SYMLINK-FREE temp dir. `FileManager.temporaryDirectory` lives under `/var/folders/…` and
    /// `/var` is a symlink to `/private/var`; the whole-path `SQLITE_OPEN_NOFOLLOW` in the hardened
    /// open would reject EVERY open there. The real active-store path is symlink-free, so these
    /// tests canonicalize via realpath(3) to match production — same helper `HardenedActiveOpenTests`
    /// uses, for the same reason.
    private func td() throws -> URL {
        let d = try trackedTempDir()
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(d.path, &buf) != nil else { return d }
        return URL(fileURLWithPath: String(cString: buf), isDirectory: true)
    }

    /// An active ledger at head, with one transaction so a restored copy has something to compare.
    /// Checkpointed and closed with no residual sidecars, so it is at rest exactly like production.
    private func makeActiveLedger(named name: String = "active.db") throws -> URL {
        let url = try td().appendingPathComponent(name)
        let store = try LedgerStore(databaseURL: url)
        try store.create(Transaction(id: "t-snapshot", type: .income, date: "2026-08-01",
                                     amount: 123.45, currency: "CNY"))
        try store.db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        try store.db.close()
        try? fm.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))
        try? fm.removeItem(at: URL(fileURLWithPath: url.path + "-shm"))
        return url
    }

    /// Rewind `user_version` so the next open sees a pending migration. The SCHEMA stays at head;
    /// the rung that re-runs is idempotent (`ALTER TABLE` behind a column check, `CREATE … IF NOT
    /// EXISTS`), which is exactly what makes this a faithful stand-in for a real pending rung.
    private func rewindVersion(_ url: URL, to version: Int) throws {
        let db = try SQLiteDatabase(path: url.path, mode: .readWriteExisting)
        try db.setUserVersion(version)
        try db.close()
    }

    private func evidence(for url: URL) throws -> ActiveOpenEvidence {
        guard case .captured(let ev) = MigrationCoordinator.captureActiveEvidence(activeDestination: url) else {
            throw Fail.captureFailed
        }
        return ev
    }

    private func plan(backups: URL, attachments: URL, timestamp: String = "2026-08-05-101112",
                      retention: Int = 3) -> PreMigrationSnapshotPlan {
        PreMigrationSnapshotPlan(backupsDirectory: backups, attachmentsDirectory: attachments,
                                 timestamp: timestamp, retention: retention)
    }

    private func snapshotDirs(in backups: URL) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: backups.path)) ?? [])
            .filter { $0.hasPrefix(PreMigrationSnapshot.namePrefix) }.sorted()
    }

    private func sha256(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Open through the SHIPPING hardened entry with a snapshot plan.
    @discardableResult
    private func open(_ url: URL, snapshot: PreMigrationSnapshotPlan?,
                      hooks: PreMigrationSnapshot.Hooks = .init()) throws -> LedgerStore {
        try LedgerStore.openActiveExistingHardened(databaseURL: url, expect: try evidence(for: url),
                                                   snapshot: snapshot, snapshotHooks: hooks,
                                                   hooks: LedgerStore.HardenedOpenHooks())
    }

    // MARK: - S · the snapshot happens when, and only when, a migration is pending

    func testS1APendingMigrationProducesASnapshotAndThenMigrates() throws {
        let active = try makeActiveLedger()
        try rewindVersion(active, to: SchemaMigrator.schemaVersion - 1)
        let backups = try td().appendingPathComponent("Backups", isDirectory: true)
        let attachments = try td().appendingPathComponent("docs", isDirectory: true)

        let store = try open(active, snapshot: plan(backups: backups, attachments: attachments))
        defer { try? store.db.close() }

        XCTAssertEqual(try store.schemaVersion(), SchemaMigrator.schemaVersion,
                       "the migration must still run after the snapshot")
        let dirs = snapshotDirs(in: backups)
        XCTAssertEqual(dirs.count, 1, "exactly one snapshot")
        XCTAssertEqual(dirs.first, "pre-migrate-v\(SchemaMigrator.schemaVersion - 1)-2026-08-05-101112",
                       "the name carries the version it was taken FROM and the supplied timestamp")
    }

    func testS2ALedgerAlreadyAtHeadIsNotSnapshotted() throws {
        let active = try makeActiveLedger()
        let backups = try td().appendingPathComponent("Backups", isDirectory: true)
        let attachments = try td().appendingPathComponent("docs", isDirectory: true)

        let store = try open(active, snapshot: plan(backups: backups, attachments: attachments))
        defer { try? store.db.close() }

        XCTAssertEqual(snapshotDirs(in: backups), [], "no pending migration → no snapshot")
        XCTAssertFalse(fm.fileExists(atPath: backups.path),
                       "and the backups directory is not even created — a boot that needs no snapshot leaves no trace")
    }

    func testS3TheSnapshotHoldsThePreMigrationStateNotThePostMigrationOne() throws {
        let active = try makeActiveLedger()
        let from = SchemaMigrator.schemaVersion - 1
        try rewindVersion(active, to: from)
        let backups = try td().appendingPathComponent("Backups", isDirectory: true)
        let attachments = try td().appendingPathComponent("docs", isDirectory: true)

        let store = try open(active, snapshot: plan(backups: backups, attachments: attachments))
        try store.db.close()

        let bundle = backups.appendingPathComponent(snapshotDirs(in: backups)[0], isDirectory: true)
        let snapDB = try SQLiteDatabase(path: bundle.appendingPathComponent(AppPaths.databaseFileName).path,
                                        readOnly: true)
        defer { try? snapDB.close() }
        XCTAssertEqual(try snapDB.userVersion(), from, "the snapshot is the state BEFORE the migration")
        XCTAssertEqual(try snapDB.query("SELECT COUNT(*) AS c FROM transactions").first?.int("c"), 1,
                       "and it carries the data")
    }

    func testS4AttachmentsTravelWithTheSnapshot() throws {
        let active = try makeActiveLedger()
        try rewindVersion(active, to: SchemaMigrator.schemaVersion - 1)
        let backups = try td().appendingPathComponent("Backups", isDirectory: true)
        let attachments = try td().appendingPathComponent("docs", isDirectory: true)
        try fm.createDirectory(at: attachments, withIntermediateDirectories: true)
        try Data("receipt".utf8).write(to: attachments.appendingPathComponent("a.pdf"))

        let store = try open(active, snapshot: plan(backups: backups, attachments: attachments))
        try store.db.close()

        let bundle = backups.appendingPathComponent(snapshotDirs(in: backups)[0], isDirectory: true)
        let copied = bundle.appendingPathComponent("attachments", isDirectory: true)
                           .appendingPathComponent("docs", isDirectory: true)
                           .appendingPathComponent("a.pdf")
        XCTAssertEqual(try? Data(contentsOf: copied), Data("receipt".utf8),
                       "a snapshot whose attachments are missing restores a ledger with dangling paths")
    }

    // MARK: - F · fail-closed

    /// The shared shape: make the snapshot fail, then prove NOTHING happened to the ledger.
    private func assertFailClosed(_ label: String,
                                  makeItFail: (URL, URL) throws -> Void,
                                  hooks: PreMigrationSnapshot.Hooks = .init(),
                                  expect: PreMigrationSnapshotError) throws {
        let active = try makeActiveLedger()
        let from = SchemaMigrator.schemaVersion - 1
        try rewindVersion(active, to: from)
        let backups = try td().appendingPathComponent("Backups", isDirectory: true)
        let attachments = try td().appendingPathComponent("docs", isDirectory: true)
        try makeItFail(backups, attachments)

        let before = try sha256(active)
        XCTAssertThrowsError(try open(active, snapshot: plan(backups: backups, attachments: attachments),
                                      hooks: hooks), label) { error in
            XCTAssertEqual(error as? PreMigrationSnapshotError, expect, "\(label): typed failure")
        }
        // F2/F3 — the two claims that matter, asserted for EVERY failure mode.
        XCTAssertEqual(try sha256(active), before, "\(label): the active ledger must be byte-identical")
        let after = try SQLiteDatabase(path: active.path, readOnly: true)
        defer { try? after.close() }
        XCTAssertEqual(try after.userVersion(), from, "\(label): the migration must NOT have run")
    }

    func testF1AndF2AnUnwritableBackupsLocationAbortsTheOpenAndLeavesTheLedgerUntouched() throws {
        try assertFailClosed("unwritable backups dir", makeItFail: { backups, _ in
            // A regular FILE where the directory must be: createDirectory fails, so does the write.
            try Data().write(to: backups)
        }, expect: .writeFailed)
    }

    func testF3AVerificationFailureAbortsTheOpenAndRemovesTheBadBundle() throws {
        var seenBundle: URL?
        let backupsBox = Box<URL>()
        var hooks = PreMigrationSnapshot.Hooks()
        hooks.afterWrite = {
            // Corrupt the freshly-written snapshot so verification cannot pass.
            guard let backups = backupsBox.value else { return }
            let dirs = ((try? FileManager.default.contentsOfDirectory(atPath: backups.path)) ?? [])
                .filter { $0.hasPrefix(PreMigrationSnapshot.namePrefix) }.sorted()
            guard let name = dirs.last else { return }
            let bundle = backups.appendingPathComponent(name, isDirectory: true)
            seenBundle = bundle
            try Data("not a database".utf8)
                .write(to: bundle.appendingPathComponent(AppPaths.databaseFileName))
        }
        try assertFailClosed("verification failure", makeItFail: { backups, _ in
            backupsBox.value = backups
        }, hooks: hooks, expect: .verificationFailed)

        XCTAssertNotNil(seenBundle, "the seam must have fired — otherwise the test proves nothing")
        if let bundle = seenBundle {
            XCTAssertFalse(fm.fileExists(atPath: bundle.path),
                           "an unverified snapshot is REMOVED — a backup nobody knows is bad is worse than none")
        }
    }

    func testF4AWriteFailureMidWayAbortsTheOpenAndLeavesNoPartialBundle() throws {
        var hooks = PreMigrationSnapshot.Hooks()
        struct Boom: Error {}
        hooks.beforeWrite = { throw Boom() }
        try assertFailClosed("write seam failure", makeItFail: { _, _ in }, hooks: hooks,
                             expect: .writeFailed)
    }

    func testF5TheConnectionIsDeterministicallyClosedOnASnapshotFailure() throws {
        let active = try makeActiveLedger()
        try rewindVersion(active, to: SchemaMigrator.schemaVersion - 1)
        let backups = try td().appendingPathComponent("Backups", isDirectory: true)
        try Data().write(to: backups)                     // force .writeFailed
        let attachments = try td().appendingPathComponent("docs", isDirectory: true)

        var closes: [Bool] = []
        var h = LedgerStore.HardenedOpenHooks()
        h.observeClose = { closes.append($0) }
        XCTAssertThrowsError(try LedgerStore.openActiveExistingHardened(
            databaseURL: active, expect: try evidence(for: active),
            snapshot: plan(backups: backups, attachments: attachments), hooks: h))
        XCTAssertEqual(closes, [true], "exactly one close, and it succeeded — no descriptor leak")
    }

    func testF6APruneFailureDoesNotBlockTheOpen() throws {
        let backups = try td().appendingPathComponent("Backups", isDirectory: true)
        try fm.createDirectory(at: backups, withIntermediateDirectories: true)
        // Four snapshots, retention 3 → the oldest is a prune candidate. Make it undeletable by
        // clearing write permission on its PARENT (the backups dir), which is what actually gates
        // unlink; the directory itself is still listable.
        for i in 1...4 {
            try fm.createDirectory(at: backups.appendingPathComponent("\(PreMigrationSnapshot.namePrefix)v22-2026-08-0\(i)-000000"),
                                   withIntermediateDirectories: true)
        }
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: backups.path)
        PreMigrationSnapshot.prune(in: backups, keeping: 3)   // must not throw
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: backups.path)
        XCTAssertEqual(snapshotDirs(in: backups).count, 4, "the prune could not delete — and did not raise")
    }

    // MARK: - R · the snapshot is restorable through the SHIPPING chain

    func testR1TheSnapshotPassesTheRestoreChainsOwnValidation() throws {
        let active = try makeActiveLedger()
        try rewindVersion(active, to: SchemaMigrator.schemaVersion - 1)
        let backups = try td().appendingPathComponent("Backups", isDirectory: true)
        let attachments = try td().appendingPathComponent("docs", isDirectory: true)
        let store = try open(active, snapshot: plan(backups: backups, attachments: attachments))
        try store.db.close()

        let bundle = backups.appendingPathComponent(snapshotDirs(in: backups)[0], isDirectory: true)
        XCTAssertNoThrow(try BackupRestore.validateBundle(bundle),
                         "a snapshot the restore chain refuses is a dead backup")
    }

    func testR2TheSnapshotSurvivesTheMigrateToHeadTheRestoreChainPerforms() throws {
        let active = try makeActiveLedger()
        let from = SchemaMigrator.schemaVersion - 1
        try rewindVersion(active, to: from)
        let backups = try td().appendingPathComponent("Backups", isDirectory: true)
        let attachments = try td().appendingPathComponent("docs", isDirectory: true)
        let store = try open(active, snapshot: plan(backups: backups, attachments: attachments))
        try store.db.close()

        // The restore chain migrates the incoming bundle to head on a copy. Reproduce that step
        // faithfully rather than asserting it in prose.
        let bundle = backups.appendingPathComponent(snapshotDirs(in: backups)[0], isDirectory: true)
        let copy = try td().appendingPathComponent("restored.db")
        try fm.copyItem(at: bundle.appendingPathComponent(AppPaths.databaseFileName), to: copy)
        let restored = try LedgerStore(databaseURL: copy)
        defer { try? restored.db.close() }
        XCTAssertEqual(try restored.schemaVersion(), SchemaMigrator.schemaVersion,
                       "restoring a pre-migrate snapshot gives back the DATA, re-migrated to head")
        XCTAssertEqual(try restored.transaction(id: "t-snapshot")?.amount, 123.45)
    }

    func testR3TheRestoredBundleCarriesItsAttachments() throws {
        let active = try makeActiveLedger()
        try rewindVersion(active, to: SchemaMigrator.schemaVersion - 1)
        let backups = try td().appendingPathComponent("Backups", isDirectory: true)
        let attachments = try td().appendingPathComponent("docs", isDirectory: true)
        try fm.createDirectory(at: attachments, withIntermediateDirectories: true)
        try Data("scan".utf8).write(to: attachments.appendingPathComponent("b.pdf"))
        let store = try open(active, snapshot: plan(backups: backups, attachments: attachments))
        try store.db.close()

        let bundle = backups.appendingPathComponent(snapshotDirs(in: backups)[0], isDirectory: true)
        XCTAssertNoThrow(try BackupRestore.validateBundle(bundle))
        let docs = bundle.appendingPathComponent("attachments", isDirectory: true)
                         .appendingPathComponent("docs", isDirectory: true)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: docs.path), ["b.pdf"])
    }

    /// R4 — why the format is a BUNDLE. A bare `.db` snapshot, the other candidate, is refused by
    /// the restore chain's first check, so it could never be restored in-app.
    func testR4ABareDatabaseSnapshotWouldBeADeadBackup() throws {
        let dir = try td().appendingPathComponent("bare", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let active = try makeActiveLedger()
        try fm.copyItem(at: active, to: dir.appendingPathComponent("pre-migrate-v22.db"))
        XCTAssertThrowsError(try BackupRestore.validateBundle(dir)) { error in
            XCTAssertEqual(error as? BackupRestore.Failure,
                           .bundleDatabaseMissing(dir.appendingPathComponent(AppPaths.databaseFileName).path))
        }
    }

    // MARK: - I · idempotence and retention

    func testI1TheSecondOpenOfTheSameLedgerTakesNoSecondSnapshot() throws {
        let active = try makeActiveLedger()
        try rewindVersion(active, to: SchemaMigrator.schemaVersion - 1)
        let backups = try td().appendingPathComponent("Backups", isDirectory: true)
        let attachments = try td().appendingPathComponent("docs", isDirectory: true)
        let p = plan(backups: backups, attachments: attachments)

        let first = try open(active, snapshot: p)
        try first.db.close()
        XCTAssertEqual(snapshotDirs(in: backups).count, 1)

        let second = try open(active, snapshot: p)          // now at head → nothing pending
        try second.db.close()
        XCTAssertEqual(snapshotDirs(in: backups).count, 1, "a boot with nothing to migrate snapshots nothing")
    }

    func testI2ASameSecondRetryGetsItsOwnNameInsteadOfFailingTheOpen() throws {
        let backups = try td().appendingPathComponent("Backups", isDirectory: true)
        try fm.createDirectory(at: backups, withIntermediateDirectories: true)
        let first = try PreMigrationSnapshot.uniqueDestination(in: backups, fromVersion: 22, timestamp: "T")
        try fm.createDirectory(at: first, withIntermediateDirectories: true)
        let second = try PreMigrationSnapshot.uniqueDestination(in: backups, fromVersion: 22, timestamp: "T")
        try fm.createDirectory(at: second, withIntermediateDirectories: true)
        let third = try PreMigrationSnapshot.uniqueDestination(in: backups, fromVersion: 22, timestamp: "T")

        XCTAssertEqual(first.lastPathComponent, "pre-migrate-v22-T")
        XCTAssertEqual(second.lastPathComponent, "pre-migrate-v22-T-2")
        XCTAssertEqual(third.lastPathComponent, "pre-migrate-v22-T-3")
    }

    func testI3RetentionKeepsTheNewestAndNeverTouchesForeignEntries() throws {
        let backups = try td().appendingPathComponent("Backups", isDirectory: true)
        try fm.createDirectory(at: backups, withIntermediateDirectories: true)
        for day in ["01", "02", "03", "04"] {
            try fm.createDirectory(at: backups.appendingPathComponent("pre-migrate-v22-2026-08-\(day)-000000"),
                                   withIntermediateDirectories: true)
        }
        // Neighbours that must survive: the restore safety net and a user's own export.
        try fm.createDirectory(at: backups.appendingPathComponent("pre-restore-2026-08-01-000000"),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: backups.appendingPathComponent("SoloLedger-Backup-2026-08-01-000000"),
                               withIntermediateDirectories: true)

        PreMigrationSnapshot.prune(in: backups, keeping: 3)

        XCTAssertEqual(snapshotDirs(in: backups),
                       ["pre-migrate-v22-2026-08-02-000000",
                        "pre-migrate-v22-2026-08-03-000000",
                        "pre-migrate-v22-2026-08-04-000000"],
                       "the OLDEST is dropped and the newest three stay")
        XCTAssertTrue(fm.fileExists(atPath: backups.appendingPathComponent("pre-restore-2026-08-01-000000").path),
                      "pruning must never reach the restore safety net")
        XCTAssertTrue(fm.fileExists(atPath: backups.appendingPathComponent("SoloLedger-Backup-2026-08-01-000000").path),
                      "nor a user's own export")
    }

    func testI4PruningHappensAfterTheWriteSoAFailedWriteCostsNoOldSnapshot() throws {
        let active = try makeActiveLedger()
        try rewindVersion(active, to: SchemaMigrator.schemaVersion - 1)
        let backups = try td().appendingPathComponent("Backups", isDirectory: true)
        try fm.createDirectory(at: backups, withIntermediateDirectories: true)
        for day in ["01", "02", "03", "04"] {
            try fm.createDirectory(at: backups.appendingPathComponent("pre-migrate-v22-2026-08-\(day)-000000"),
                                   withIntermediateDirectories: true)
        }
        let attachments = try td().appendingPathComponent("docs", isDirectory: true)
        var hooks = PreMigrationSnapshot.Hooks()
        struct Boom: Error {}
        hooks.beforeWrite = { throw Boom() }

        XCTAssertThrowsError(try open(active, snapshot: plan(backups: backups, attachments: attachments),
                                      hooks: hooks))
        XCTAssertEqual(snapshotDirs(in: backups).count, 4,
                       "prune runs only after a verified write — a failed write must not also delete history")
    }

    // MARK: - M · the mutation points, named

    /// Not a behaviour test: a checklist a reviewer can hold against the code. Each entry names a
    /// line whose removal must turn a test above red; the report records the measured result.
    func testM0TheMutationPointsAreEnumerated() {
        let points = [
            "the `from < SchemaMigrator.schemaVersion` guard (→ S2/I1)",
            "the snapshot call site sits BEFORE `LedgerStore(adopting:)` (→ S3)",
            "the `throw` on a snapshot failure, i.e. fail-closed (→ F1/F2/F4)",
            "the bundle removal on a verification failure (→ F3)",
            "prune runs AFTER the write (→ I4)",
            "prune filters on `namePrefix` (→ I3)",
        ]
        XCTAssertEqual(points.count, 6, "six mutation points, each with its guarding test")
    }
}

/// A tiny reference box so a `Hooks` closure can see a value the test sets later. Hooks are
/// `(() throws -> Void)` by design (no payload), so the seam stays free of test-only parameters.
private final class Box<T> {
    var value: T?
}
