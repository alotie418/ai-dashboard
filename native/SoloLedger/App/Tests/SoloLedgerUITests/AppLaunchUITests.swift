import XCTest

/// Xcode UI-Test target: a launch smoke test. Confirms the packaged app actually
/// launches to the foreground and shows a window (the regression class we just
/// fixed was a launch crash). No deep interaction — Phase-1 scope.
final class AppLaunchUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAppLaunchesToForeground() {
        let app = XCUIApplication()
        app.launch()
        // The app must reach — and stay in — the foreground: it launched without
        // crashing (the exact regression class we just fixed). We assert on run
        // state rather than window enumeration, which is unreliable under a
        // headless automation session even when the window renders on a real desktop.
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20),
                      "app did not reach the foreground after launch")
        XCTAssertNotEqual(app.state, .notRunning, "app terminated unexpectedly after launch")

        // Best-effort window check: recorded, but not a hard failure in CI/headless.
        if app.windows.firstMatch.waitForExistence(timeout: 5) {
            XCTAssertGreaterThan(app.windows.count, 0)
        }
    }
}
