import XCTest
import AppKit

/// Launch smoke test for the packaged app. Verifies it starts and stays alive (no
/// launch crash — the exact regression class we fixed). It launches via `open` and
/// checks the running process rather than driving XCUITest's foreground automation,
/// which is unreliable in headless / no-WindowServer sessions even when the app
/// renders fine on a real desktop.
final class AppLaunchUITests: XCTestCase {

    private let bundleID = "com.alotie418.sololedger.dev"

    func testPackagedAppLaunchesWithoutCrashing() throws {
        let appURL = try builtAppURL()

        // Launch a fresh instance (no dependency on the test session foregrounding it).
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-n", appURL.path]
        try open.run()
        open.waitUntilExit()
        XCTAssertEqual(open.terminationStatus, 0, "`open` failed to launch the app")

        // Give it time to boot (open DB, run the migration decision, render), then
        // assert it is still running — i.e. it did not crash on launch.
        let deadline = Date().addingTimeInterval(15)
        var running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        while running.isEmpty && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.3)
            running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        }
        XCTAssertFalse(running.isEmpty, "app is not running after launch — did it crash?")
        // Still alive a moment later (didn't crash during boot).
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(running.allSatisfy { $0.isTerminated }, "app terminated unexpectedly after launch")

        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            app.terminate()
        }
    }

    /// The built app sits next to this test bundle in Products/<config>.
    private func builtAppURL() throws -> URL {
        var dir = Bundle(for: type(of: self)).bundleURL
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("SoloLedger.app")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        throw XCTSkip("could not locate the built SoloLedger.app next to the test bundle")
    }
}
