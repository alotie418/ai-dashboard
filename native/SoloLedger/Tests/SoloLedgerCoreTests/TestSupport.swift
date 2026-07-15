import XCTest
@testable import SoloLedgerCore

/// Base case that hands each test an isolated, throwaway on-disk database and
/// cleans it up afterwards. Never touches the preview/production data.
class LedgerTestCase: XCTestCase {
    private var tempDirs: [URL] = []

    func makeStore() throws -> LedgerStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SLTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return try LedgerStore(databaseURL: dir.appendingPathComponent("test.db"))
    }

    func tempDatabaseURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SLTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir.appendingPathComponent("test.db")
    }

    override func tearDown() {
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs.removeAll()
        super.tearDown()
    }
}
