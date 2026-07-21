import XCTest
import AppKit

/// 2B-3 C12b-3: migration UI smoke, driven by the DEBUG-only `--migration-ui-preview <state>`
/// launch argument (compiled out of Release). The DEBUG preview feeds SYNTHETIC primitives
/// through the SAME `MigrationPresenter.route` as production, so these exercise the real routing.
///
/// TWO layers:
///  1. `testZzzEachPreviewStateRendersWithoutCrashing` — process-based (headless-safe): launches
///     each preview state via `open` and asserts it renders without crashing. Named to sort LAST
///     so it never contends with the foreground-automation launches.
///  2. Foreground-automation assertions — run UNCONDITIONALLY (0 skipped). Each terminates its
///     app instance in teardown so sequential launches don't contend. Routing SAFETY is also
///     proven independently by the non-skipped routing unit tests in `MigrationCopyParityTests`.
final class MigrationRecoveryUITests: XCTestCase {

    private let bundleID = "com.alotie418.sololedger.dev"
    private var app: XCUIApplication?

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
        terminateAllAndWait()
    }

    override func tearDown() {
        app?.terminate()
        app = nil
        terminateAllAndWait()
        super.tearDown()
    }

    /// Terminate every running instance and WAIT until the bundle is gone, so the next test's
    /// `launch()` never contends with a still-activating/terminating instance.
    private func terminateAllAndWait() {
        terminateAll()
        let deadline = Date().addingTimeInterval(8)
        while !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty,
              Date() < deadline {
            terminateAll()
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    // MARK: - Foreground-automation assertions (0 skipped)

    private func launch(_ state: String) -> XCUIApplication {
        let a = XCUIApplication()
        a.launchArguments += ["--migration-ui-preview", state]
        a.launch()
        app = a
        return a
    }

    func testRunningShowsProgress() {
        let app = launch("running")
        XCTAssertTrue(app.staticTexts["migration.running"].waitForExistence(timeout: 10),
                      "running state must show the progress message")
    }

    func testRetriableOffersRetryAndExport() {
        let app = launch("retriable")
        XCTAssertTrue(app.buttons["migration.action.retry"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["migration.action.exportDiagnostics"].exists)
    }

    func testTerminalHasRetryExportButNoRestoreOrBlank() {
        let app = launch("terminal")
        XCTAssertTrue(app.buttons["migration.action.retry"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["migration.action.exportDiagnostics"].exists)
        XCTAssertFalse(app.buttons["recovery.restore"].exists, "terminal chain UI must NOT offer restore")
        XCTAssertFalse(app.buttons["recovery.blank"].exists, "terminal chain UI must NOT offer create-blank")
    }

    func testAcknowledgementListsItemsHasConfirmAndNoCancel() {
        let app = launch("ack")
        XCTAssertTrue(app.buttons["migration.action.acknowledge"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["invoice-scan.pdf"].waitForExistence(timeout: 10),
                      "acknowledgement must list each unresolved item by name")
        XCTAssertTrue(app.staticTexts["logo.png"].exists)
        XCTAssertFalse(app.buttons["migration.action.cancel"].exists, "acknowledgement must have no cancel")
    }

    func testSelectionSeveritiesDifferInSelectability() {
        let app = launch("selection")
        let valid = app.buttons["migration.action.select.import-valid-1"]
        let unavailable = app.buttons["migration.action.select.import-unavail-1"]
        let invalid = app.buttons["migration.action.select.import-invalid-1"]
        XCTAssertTrue(valid.waitForExistence(timeout: 10))
        XCTAssertTrue(valid.isEnabled, "a valid candidate must be selectable")
        XCTAssertFalse(unavailable.isEnabled, "an unavailable candidate must not be selectable")
        XCTAssertFalse(invalid.isEnabled, "an invalid candidate must not be selectable")
        XCTAssertTrue(app.buttons["migration.action.cancel"].exists, "selection must offer cancel")
    }

    /// N7.2: the source-choice screen renders BOTH actions; "create new ledger" NEVER fires
    /// directly — it must raise the confirmation dialog first, and "go back" returns to the
    /// still-rendered choice screen (zero intents; the preview's closures are inert, so any
    /// visible route change here would mean the view bypassed the dialog gate).
    func testChooseSourceShowsBothActionsAndConfirmationGate() {
        var app = launch("chooseSource")
        var migrate = app.buttons["migration.chooseSource.migrate"]
        if !migrate.waitForExistence(timeout: 10) {
            // ONE relaunch guard against post-teardown window-activation contention (the same
            // sequential-launch contention terminateAllAndWait/Zzz-ordering mitigate). The
            // assertions below stay strict — a genuinely missing button still fails.
            app.terminate()
            terminateAllAndWait()
            app = launch("chooseSource")
            migrate = app.buttons["migration.chooseSource.migrate"]
        }
        let createNew = app.buttons["migration.chooseSource.createNew"]
        XCTAssertTrue(migrate.waitForExistence(timeout: 10), "the migrate action must render")
        XCTAssertTrue(createNew.exists, "the create-new action must render")

        createNew.click()
        let confirm = app.buttons["migration.chooseSource.confirm.create"].firstMatch
        let back = app.buttons["migration.chooseSource.confirm.back"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10),
                      "create-new must FIRST raise the confirmation dialog — never create directly")
        XCTAssertTrue(back.exists, "the confirmation dialog must offer a way back")

        back.click()
        XCTAssertTrue(createNew.waitForExistence(timeout: 10),
                      "going back must stay on the source-choice screen")
        XCTAssertTrue(migrate.exists)
        XCTAssertFalse(app.buttons["migration.chooseSource.confirm.create"].exists,
                       "the dialog must be dismissed after going back")
    }

    func testCleanupResidualKeepsMainUIUsable() {
        let app = launch("residual")
        // The MAIN UI renders (sidebar present) — cleanupResidual does NOT block it with a
        // chain-recovery screen. (That the banner is ROUTED is proven deterministically by the
        // non-skipped routing unit test `testRouteCleanupResidualReadyGoesToMainWithBanner`.)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "main.sidebar").firstMatch
                        .waitForExistence(timeout: 12),
                      "cleanupResidual must keep the main UI usable, not block it")
        XCTAssertFalse(app.buttons["migration.action.retry"].exists,
                       "cleanupResidual must NOT show a blocking chain-recovery screen")
    }

    // MARK: - Process-based smoke (headless-safe; sorts last)

    func testZzzEachPreviewStateRendersWithoutCrashing() throws {
        let states = ["running", "retriable", "terminal", "ack", "selection", "residual", "chooseSource", "none"]
        let appURL = try builtAppURL()
        for state in states {
            terminateAll()
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-n", appURL.path, "--args", "--migration-ui-preview", state]
            try open.run(); open.waitUntilExit()
            XCTAssertEqual(open.terminationStatus, 0, "`open` failed for state \(state)")

            let deadline = Date().addingTimeInterval(15)
            var running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            while running.isEmpty && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.3)
                running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            }
            XCTAssertFalse(running.isEmpty, "state \(state): app not running — did it crash on render?")
            Thread.sleep(forTimeInterval: 1.5)
            XCTAssertFalse(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                            .allSatisfy { $0.isTerminated },
                           "state \(state): app terminated after render — a preview view crashed")
        }
        terminateAll()
    }

    // MARK: - Helpers

    private func terminateAll() {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) { app.terminate() }
    }

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
