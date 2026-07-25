import XCTest
@testable import SoloLedgerCore

/// `BackupExport.writeBundle` — the user-visible "Export backup" primitive. Proves it produces a
/// bundle in the exact `MigrationSource.exportBundle` layout (`sololedger.db` + `attachments/docs/`),
/// with a consistent + quiescent single-file DB snapshot and verbatim attachment copies, so a
/// produced bundle is restorable through the same hardened import chain.
final class BackupExportTests: LedgerTestCase {

    private let fm = FileManager.default

    func testWriteBundleProducesRestorableExportBundle() throws {
        let root = try trackedTempDir()

        // A live active store (WAL mode via applyPragmas) with content.
        let activeDir = root.appendingPathComponent("active", isDirectory: true)
        try fm.createDirectory(at: activeDir, withIntermediateDirectories: true)
        let store = try LedgerStore(databaseURL: activeDir.appendingPathComponent(AppPaths.databaseFileName),
                                    open: .createIfMissing)
        try store.create(Transaction(type: .income, date: "2026-01-01", amount: 100, currency: "CNY"))
        try store.create(Transaction(type: .expense, date: "2026-01-02", amount: 40, currency: "CNY"))

        // Active attachments dir with one regular file.
        let attDir = root.appendingPathComponent("active-docs", isDirectory: true)
        try fm.createDirectory(at: attDir, withIntermediateDirectories: true)
        let attName = "receipt.pdf"
        let attBytes = Data("backup-export test attachment\n".utf8)
        try attBytes.write(to: attDir.appendingPathComponent(attName))

        // Export a consistent snapshot of the LIVE store, then close it.
        let bundle = root.appendingPathComponent("Backup-Bundle", isDirectory: true)
        try BackupExport.writeBundle(database: store.db, attachmentsDir: attDir, to: bundle)
        try store.db.close()

        // Bundle layout matches the export-bundle contract: single-file quiescent DB, no sidecars.
        let bundleDB = bundle.appendingPathComponent(AppPaths.databaseFileName)
        XCTAssertTrue(fm.fileExists(atPath: bundleDB.path), "bundle db present")
        XCTAssertFalse(fm.fileExists(atPath: bundleDB.path + "-wal"), "bundle is a quiescent single file (no -wal)")
        XCTAssertFalse(fm.fileExists(atPath: bundleDB.path + "-shm"), "no -shm")
        XCTAssertFalse(fm.fileExists(atPath: bundleDB.path + "-journal"), "no -journal")

        let bundleDoc = bundle.appendingPathComponent("attachments", isDirectory: true)
                              .appendingPathComponent("docs", isDirectory: true)
                              .appendingPathComponent(attName)
        XCTAssertEqual(try Data(contentsOf: bundleDoc), attBytes, "attachment copied verbatim")

        // The snapshot is a valid, complete, checkpointed DB.
        let restored = try SQLiteDatabase(path: bundleDB.path, mode: .readWriteExisting)
        XCTAssertEqual(try restored.scalar("PRAGMA user_version").intValue, SchemaMigrator.schemaVersion,
                       "migrated schema version preserved")
        XCTAssertEqual(try restored.query("SELECT COUNT(*) AS c FROM transactions").first?.int("c"), 2,
                       "both transactions captured")
        XCTAssertEqual(try restored.scalar("PRAGMA journal_mode").stringValue?.lowercased(), "delete",
                       "bundle DB normalized to a checkpointed single-file (delete) journal")
        try restored.close()

        // The .exportBundle source contract resolves onto exactly the produced bundle.
        let source = MigrationSource.exportBundle(bundle)
        XCTAssertEqual(try source.databaseURL().path, bundleDB.path)
        let attRoot = try XCTUnwrap(try source.attachmentsRootURL())
        XCTAssertEqual(attRoot.appendingPathComponent(attName).path, bundleDoc.path)
        XCTAssertTrue(fm.fileExists(atPath: attRoot.appendingPathComponent(attName).path))
    }

    func testWriteBundleRefusesExistingDestination() throws {
        let root = try trackedTempDir()
        let store = try LedgerStore(databaseURL: root.appendingPathComponent(AppPaths.databaseFileName),
                                    open: .createIfMissing)
        let bundle = root.appendingPathComponent("Existing", isDirectory: true)
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)   // pre-exists → must refuse
        XCTAssertThrowsError(try BackupExport.writeBundle(database: store.db, attachmentsDir: root, to: bundle)) { e in
            guard case BackupExport.Failure.destinationExists = e else {
                return XCTFail("expected destinationExists, got \(e)")
            }
        }
        try store.db.close()
    }

    func testWriteBundleWithNoAttachmentsStillProducesCompleteLayout() throws {
        let root = try trackedTempDir()
        let store = try LedgerStore(databaseURL: root.appendingPathComponent(AppPaths.databaseFileName),
                                    open: .createIfMissing)
        let absentAtt = root.appendingPathComponent("no-such-attachments", isDirectory: true)   // absent
        let bundle = root.appendingPathComponent("Empty-Att-Bundle", isDirectory: true)
        try BackupExport.writeBundle(database: store.db, attachmentsDir: absentAtt, to: bundle)
        try store.db.close()

        XCTAssertTrue(fm.fileExists(atPath: bundle.appendingPathComponent(AppPaths.databaseFileName).path))
        var isDir: ObjCBool = false
        let docsPath = bundle.appendingPathComponent("attachments", isDirectory: true)
                             .appendingPathComponent("docs", isDirectory: true).path
        XCTAssertTrue(fm.fileExists(atPath: docsPath, isDirectory: &isDir) && isDir.boolValue,
                      "empty docs dir still created for a complete bundle layout")
    }
}
