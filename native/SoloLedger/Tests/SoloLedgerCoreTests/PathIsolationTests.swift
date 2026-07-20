import XCTest
@testable import SoloLedgerCore

/// The native app's data folder and the Electron discovery path must be config- and
/// container-isolated so a Debug build can never reach the production database.
final class PathIsolationTests: XCTestCase {

    func testDebugPreviewReleaseProductionFolder() {
        #if DEBUG
        XCTAssertEqual(AppPaths.nativeDataFolderName, "SoloLedgerNativePreview")
        #else
        XCTAssertEqual(AppPaths.nativeDataFolderName, "SoloLedgerNative")  // no "Preview" in production
        #endif
    }

    func testNativeFolderNeverEqualsElectronFolder() {
        XCTAssertNotEqual(AppPaths.nativeDataFolderName, AppPaths.electronProductFolderName)
        XCTAssertEqual(AppPaths.electronProductFolderName, "SoloLedger")
    }

    /// Discovery is container-relative: the Electron path resolves under the SAME
    /// Application Support as the app's own data. So a Debug build runs inside the
    /// isolated `.dev` container — where no production data exists — and can never
    /// reach the production container's database. (No dirs are created here.)
    func testDiscoveryIsContainerRelative() throws {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        let electronDB = try AppPaths.electronLegacyDatabaseURL()

        XCTAssertEqual(
            electronDB.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path,
            appSupport.standardizedFileURL.path,
            "Electron discovery must be under the app's own Application Support (its sandbox container)")
        XCTAssertEqual(electronDB.deletingLastPathComponent().lastPathComponent, AppPaths.electronProductFolderName)
        XCTAssertEqual(electronDB.lastPathComponent, AppPaths.databaseFileName)
    }
}
