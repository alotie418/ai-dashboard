import XCTest
@testable import SoloLedgerCore

/// Phase 2B migration path accessors: the native active attachments root, per-import
/// staging, the out-of-DB manifest store, and the READ-ONLY Electron attachments source
/// must be correctly located AND container-isolated from Electron's data.
final class MigrationPathsTests: XCTestCase {

    private let fm = FileManager.default

    func testAttachmentsRelativeRootMirrorsElectron() {
        XCTAssertEqual(AppPaths.attachmentsRelativeRoot, "attachments/docs")
    }

    func testNativeAttachmentsDirectoryUnderDataDirAndCreated() throws {
        let dataDir = try AppPaths.dataDirectory()
        let attach = try AppPaths.nativeAttachmentsDirectory()

        XCTAssertTrue(attach.path.hasPrefix(dataDir.path + "/"), "native attachments must live under the native data dir")
        XCTAssertEqual(Array(attach.pathComponents.suffix(2)), ["attachments", "docs"])
        XCTAssertTrue(attach.pathComponents.contains(AppPaths.nativeDataFolderName))
        // Isolation: never under Electron's product folder ("SoloLedger").
        XCTAssertFalse(attach.pathComponents.contains(AppPaths.electronProductFolderName))

        var isDir: ObjCBool = false
        XCTAssertTrue(fm.fileExists(atPath: attach.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    func testImportManifestsDirectoryUnderDataDirAndCreated() throws {
        let dataDir = try AppPaths.dataDirectory()
        let manifests = try AppPaths.importManifestsDirectory()
        XCTAssertTrue(manifests.path.hasPrefix(dataDir.path + "/"))
        XCTAssertEqual(manifests.lastPathComponent, "ImportManifests")
        XCTAssertFalse(manifests.pathComponents.contains(AppPaths.electronProductFolderName))
        XCTAssertTrue(fm.fileExists(atPath: manifests.path))
    }

    func testStagedImportDirectoriesArePerImportIsolatedAndContained() throws {
        let root = try AppPaths.stagingRootDirectory()
        XCTAssertTrue(fm.fileExists(atPath: root.path))            // root IS created
        XCTAssertEqual(root.lastPathComponent, "Staging")

        let idA = try XCTUnwrap(ImportID("test-\(UUID().uuidString)"))
        let idB = try XCTUnwrap(ImportID("test-\(UUID().uuidString)"))
        let a = try AppPaths.stagedImportDirectory(importID: idA)
        let b = try AppPaths.stagedImportDirectory(importID: idB)

        XCTAssertNotEqual(a.path, b.path, "distinct import IDs must get distinct staging dirs")
        XCTAssertEqual(a.deletingLastPathComponent().lastPathComponent, "Staging")
        XCTAssertEqual(a.lastPathComponent, "import-\(idA.rawValue)")
        // Strictly under the Staging root; never under Electron's folder.
        XCTAssertTrue(a.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/"))
        XCTAssertFalse(a.pathComponents.contains(AppPaths.electronProductFolderName))
        // Path only — the accessor does NOT create it (ingest publishes into it atomically).
        XCTAssertFalse(fm.fileExists(atPath: a.path))
    }

    func testFreshStagingAttemptDirectoriesAreUniqueContainedAndCreated() throws {
        let root = try AppPaths.stagingRootDirectory()
        let x = try AppPaths.freshStagingAttemptDirectory()
        let y = try AppPaths.freshStagingAttemptDirectory()
        defer { try? fm.removeItem(at: x); try? fm.removeItem(at: y) }

        XCTAssertNotEqual(x.path, y.path, "each attempt must get a distinct temp dir")
        XCTAssertTrue(x.lastPathComponent.hasPrefix(".attempt-"))
        XCTAssertTrue(x.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/"))
        XCTAssertTrue(fm.fileExists(atPath: x.path))
    }

    func testElectronLegacyAttachmentsURLIsContainerRelativeAndDistinct() throws {
        let appSupport = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: false)
        let electronAttach = try AppPaths.electronLegacyAttachmentsURL()

        // .../<AppSupport>/SoloLedger/attachments/docs
        XCTAssertEqual(Array(electronAttach.pathComponents.suffix(3)), ["SoloLedger", "attachments", "docs"])
        // rooted at the SAME Application Support as the app's own data (its sandbox container)
        let productFolder = electronAttach
            .deletingLastPathComponent()   // docs -> attachments
            .deletingLastPathComponent()   // attachments -> SoloLedger
            .deletingLastPathComponent()   // SoloLedger -> AppSupport
        XCTAssertEqual(productFolder.standardizedFileURL.path, appSupport.standardizedFileURL.path)

        // Isolation: the Electron source is NOT under the native data dir, and vice-versa.
        let dataDir = try AppPaths.dataDirectory()
        XCTAssertFalse(electronAttach.path.hasPrefix(dataDir.path + "/"))
        XCTAssertFalse(electronAttach.pathComponents.contains(AppPaths.nativeDataFolderName))

        // The accessor must NOT create the source (create:false); we don't assert absence
        // (a real install may have it) but confirm it's a distinct location from ours.
        let nativeAttach = try AppPaths.nativeAttachmentsDirectory()
        XCTAssertNotEqual(electronAttach.standardizedFileURL.path, nativeAttach.standardizedFileURL.path)
    }
}
