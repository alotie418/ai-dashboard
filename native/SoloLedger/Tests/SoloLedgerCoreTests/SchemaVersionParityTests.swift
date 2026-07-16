import XCTest
@testable import SoloLedgerCore

/// GUARD (fail-closed, build/release consistency): the native schema target MUST equal
/// Electron's authoritative `SCHEMA_VERSION`. If they drift, a native release either
/// migrates to the wrong head or — via the runtime version gate — rejects EVERY real
/// production DB whose `user_version` exceeds the native target as `.unknownVersion`,
/// fleet-blocking upgrading users.
///
/// We read Electron's value from its ACTUAL exported constant by `require()`-ing
/// `electron/db/index.js` in Node (`SCHEMA_VERSION = MIGRATIONS.length`). That is the
/// single source of truth: NO duplicated constant is kept native-side, and NO fragile
/// source-text parsing is done. The native value is read in-process from
/// `SchemaMigrator.schemaVersion`.
///
/// FAIL-CLOSED: the ONLY case that skips is a genuinely detached package where
/// `electron/db/index.js` cannot be located (no authority to compare against). Whenever
/// the Electron source IS present — as it is in-repo and in CI — a missing Node, a failed
/// `require`, or non-integer output all FAIL the test, so it can never pass silently. The
/// `checks` CI job (macos-latest, Node installed) runs `swift test`, so PRs enforce this.
final class SchemaVersionParityTests: XCTestCase {

    func testNativeSchemaVersionMatchesElectronAuthority() throws {
        // The ONLY permitted skip: we are a Swift package detached from the monorepo, so
        // there is no Electron authority to compare against. Whenever the Electron source
        // IS present the guard is FAIL-CLOSED — a missing Node, a failed require, or invalid
        // output all FAIL the test (never skip), so it can never pass without verifying.
        guard let electronIndex = Self.locateElectronDbIndex() else {
            throw XCTSkip("electron/db/index.js not found by walking up from \(#filePath) — package is detached from the monorepo; parity is enforced in-repo / CI")
        }

        // Read the REAL exported value; `require('electron')` in plain Node returns a
        // path string (so `app` is undefined and no DB is ever opened) — loading the
        // module only defines the MIGRATIONS array, so this has no side effects.
        let r = Self.runEnvNode([
            "-e",
            "process.stdout.write(String(require(process.argv[1]).SCHEMA_VERSION))",
            electronIndex.path,
        ])
        guard r.status == 0 else {
            return XCTFail("""
                Electron source is present but its authoritative SCHEMA_VERSION could not be read \
                (`env node` exited \(r.status) — Node missing or the require failed). In-repo the \
                guard MUST run; install Node / fix the Electron require. stderr: \(r.err.prefix(400))
                """)
        }
        guard let electronVersion = Int(r.out.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return XCTFail("Electron SCHEMA_VERSION output was not an integer: '\(r.out)' (stderr: \(r.err.prefix(400)))")
        }

        XCTAssertGreaterThan(electronVersion, 0, "Electron SCHEMA_VERSION should be a positive integer")
        XCTAssertEqual(
            SchemaMigrator.schemaVersion, electronVersion,
            """
            SCHEMA DRIFT: native SchemaMigrator.schemaVersion=\(SchemaMigrator.schemaVersion) \
            but Electron SCHEMA_VERSION=\(electronVersion). Port the missing migration(s) and bump \
            the native migrator to match BEFORE releasing — a lower native target rejects real \
            production DBs as .unknownVersion (fleet-wide block); a higher one migrates to a head \
            Electron never wrote.
            """)
    }

    // MARK: - Helpers

    /// Walk up from this test file to the monorepo root containing electron/db/index.js.
    private static func locateElectronDbIndex() -> URL? {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<12 {
            let candidate = dir.appendingPathComponent("electron/db/index.js")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }   // reached filesystem root
            dir = parent
        }
        return nil
    }

    /// Run `env node <args>`, capturing stdout/stderr/status. `env` resolves node from
    /// PATH; a missing node yields a non-zero status (handled as a skip by the caller).
    private static func runEnvNode(_ nodeArgs: [String]) -> (out: String, err: String, status: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["node"] + nodeArgs
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        do { try p.run() } catch { return ("", "spawn failed: \(error)", -1) }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(data: outData, encoding: .utf8) ?? "",
                String(data: errData, encoding: .utf8) ?? "",
                p.terminationStatus)
    }
}
