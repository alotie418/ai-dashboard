import XCTest
@testable import SoloLedgerCore

/// Base case that hands each test isolated, throwaway on-disk locations and cleans
/// them up afterwards. Never touches the preview/production data.
class LedgerTestCase: XCTestCase {
    private var tempDirs: [URL] = []

    /// A fresh temp directory tracked for automatic cleanup.
    func trackedTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SLTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    func makeStore() throws -> LedgerStore {
        try LedgerStore(databaseURL: trackedTempDir().appendingPathComponent("test.db"))
    }

    func tempDatabaseURL() throws -> URL {
        try trackedTempDir().appendingPathComponent("test.db")
    }

    /// URL of the committed Electron v23 fixture inside the test bundle.
    func fixtureURL() throws -> URL {
        let bundle = Bundle.module
        if let url = bundle.url(forResource: "electron-v23", withExtension: "db", subdirectory: "Fixtures") { return url }
        if let url = bundle.url(forResource: "electron-v23", withExtension: "db") { return url }
        throw XCTSkip("electron-v23.db fixture missing from the test bundle")
    }

    /// A writable copy of the Electron v23 fixture in a fresh temp dir.
    func electronFixtureCopy(named name: String = "electron.db") throws -> URL {
        let dst = try trackedTempDir().appendingPathComponent(name)
        try FileManager.default.copyItem(at: fixtureURL(), to: dst)
        return dst
    }

    override func tearDown() {
        for dir in tempDirs {
            // Restore permissions in case a test made something read-only.
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            if let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) {
                for case let u as URL in en {
                    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
                }
            }
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs.removeAll()
        super.tearDown()
    }
}
