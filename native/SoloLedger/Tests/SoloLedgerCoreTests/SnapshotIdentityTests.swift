import XCTest
@testable import SoloLedgerCore

/// The shared DB(+WAL) snapshot-identity recompute helper (Phase 2B-3 C1). Promoting the
/// formerly-private ingest-side function to ImportManifest gives the read-side staged-snapshot
/// gate one canonical implementation, so ingest and verify can never drift. Algorithm and
/// manifest format are unchanged — these tests pin the byte-exact contract.
final class SnapshotIdentityTests: LedgerTestCase {

    private let fm = FileManager.default

    // MARK: - Parity: the helper equals the value ingest stamps into the manifest

    func testHelperMatchesValueIngestStamps() throws {
        // A real ingest (no WAL) so sourceDBSHA256 / walSHA256 come from the pipeline itself.
        let dir = try trackedTempDir().appendingPathComponent("SoloLedger", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("synthetic-db-bytes".utf8).write(to: dir.appendingPathComponent("sololedger.db"))
        let id = ImportID("snapid-\(UUID().uuidString)")!
        defer { if let d = try? AppPaths.stagedImportDirectory(importID: id) { try? fm.removeItem(at: d) } }

        let result = try StagingIngest().ingest(.userSelectedDataDir(dir), importID: id, timestamp: "t")
        let m = result.manifest
        XCTAssertNil(m.walSHA256)
        XCTAssertEqual(m.snapshotIdentitySHA256,
                       ImportManifest.snapshotIdentity(dbSHA: m.sourceDBSHA256, walSHA: m.walSHA256),
                       "the manifest's stored identity must equal the shared helper's recompute")
    }

    // MARK: - Determinism + injectivity

    func testDeterministicAndPure() {
        let a = ImportManifest.snapshotIdentity(dbSHA: "deadbeef", walSHA: "cafe")
        let b = ImportManifest.snapshotIdentity(dbSHA: "deadbeef", walSHA: "cafe")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 64, "lowercase hex SHA-256")
    }

    func testNoWalDiffersFromEmptyWalFileHash() {
        // nil WAL (no sidecar) must NOT collide with a present-but-EMPTY WAL, whose sha256 is
        // the well-known hash of zero bytes. This is the real-data distinction that matters:
        // a real walSHA256 is always a 64-hex digest, never the empty string.
        let emptyFileSHA = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        let noWal = ImportManifest.snapshotIdentity(dbSHA: "db", walSHA: nil)
        let emptyWal = ImportManifest.snapshotIdentity(dbSHA: "db", walSHA: emptyFileSHA)
        XCTAssertNotEqual(noWal, emptyWal, "absent WAL and empty-WAL-file must produce different identities")
        // NOTE (unchanged algorithm): walSHA nil is encoded as "" (walSHA ?? ""), so nil and the
        // empty STRING coincide — harmless, since a hashed file never yields "" and the writer
        // only ever passes nil or a 64-hex digest.
    }

    func testDifferentWalDifferentIdentitySameDb() {
        let base = ImportManifest.snapshotIdentity(dbSHA: "db", walSHA: "wal-1")
        XCTAssertNotEqual(base, ImportManifest.snapshotIdentity(dbSHA: "db", walSHA: "wal-2"))
        XCTAssertNotEqual(base, ImportManifest.snapshotIdentity(dbSHA: "db", walSHA: nil))
    }

    func testDifferentDbDifferentIdentitySameWal() {
        XCTAssertNotEqual(ImportManifest.snapshotIdentity(dbSHA: "db-1", walSHA: "w"),
                          ImportManifest.snapshotIdentity(dbSHA: "db-2", walSHA: "w"))
    }

    /// The NUL separator + `wal:` marker must be injective: no field boundary can be smuggled
    /// so that two distinct (db, wal) pairs collide.
    func testFieldBoundaryIsInjective() {
        // If concatenation were naive ("db"+wal), these could collide; the marker prevents it.
        XCTAssertNotEqual(ImportManifest.snapshotIdentity(dbSHA: "a", walSHA: "b"),
                          ImportManifest.snapshotIdentity(dbSHA: "ab", walSHA: ""))
        XCTAssertNotEqual(ImportManifest.snapshotIdentity(dbSHA: "a", walSHA: "b"),
                          ImportManifest.snapshotIdentity(dbSHA: "a\u{0}wal:b", walSHA: nil))
    }
}
