import XCTest
@testable import SoloLedgerCore

/// GUARD (fail-closed, build/release consistency) over a ladder that is now TWO segments:
/// v1…`sharedLadderVersion` are a port of Electron's `MIGRATIONS`, and `nativeOnlyVersions`
/// are rungs Electron has no counterpart for (v24, the inventory ledger, is the first).
///
/// ## What must not be lost
///
/// The original guard asserted `SchemaMigrator.schemaVersion == electronVersion` and existed
/// for one reason: if the native target is BEHIND Electron, the runtime version gate rejects
/// EVERY real production DB whose `user_version` exceeds the native target as
/// `.unknownVersion`, fleet-blocking upgrading users. A native-only rung makes head ≠ Electron
/// by design, so that single equality can no longer be the assertion — but deleting it would
/// take the fleet-block protection with it.
///
/// So it splits, and each half carries one half of the old meaning:
///
///  * **Segment one** — the SHARED PREFIX still matches Electron exactly
///    (`sharedLadderVersion == electronVersion`), and the native head is never behind Electron.
///    An Electron migration that is not ported turns this red, exactly as before.
///  * **Segment two** — the native-only increment is EXACTLY the declared list, and that list
///    is the contiguous range above the shared prefix. A rung cannot appear by bumping
///    `schemaVersion` alone, and cannot be smuggled into the shared segment either.
///  * **Segment three** — anti-vacuity. Both rules are evaluated as pure functions here, and
///    segment three drives them with SYNTHETIC drifted values to prove they can actually fail.
///    Without it, a rule that had been quietly weakened into a tautology would still look green.
///
/// We read Electron's value from its ACTUAL exported constant by `require()`-ing
/// `electron/db/index.js` in Node (`SCHEMA_VERSION = MIGRATIONS.length`). That is the
/// single source of truth: NO duplicated constant is kept native-side, and NO fragile
/// source-text parsing is done.
///
/// FAIL-CLOSED: the ONLY case that skips is a genuinely detached package where
/// `electron/db/index.js` cannot be located (no authority to compare against). Whenever
/// the Electron source IS present — as it is in-repo and in CI — a missing Node, a failed
/// `require`, or non-integer output all FAIL the test, so it can never pass silently. The
/// `checks` CI job (macos-latest, Node installed) runs `swift test`, so PRs enforce this.
final class SchemaVersionParityTests: XCTestCase {

    // MARK: - The two rules, as pure functions (so segment three can drive them)

    /// Segment-one rule. Returns the violations found; empty means the shared prefix is intact.
    static func sharedPrefixViolations(nativeShared: Int, electron: Int, nativeHead: Int) -> [String] {
        var found: [String] = []
        if nativeShared != electron { found.append("shared-prefix-drift") }
        if nativeHead < electron { found.append("native-head-behind-electron") }
        return found
    }

    /// Segment-two rule. Returns the violations found; empty means the native-only increment is
    /// exactly the declared, contiguous list.
    static func nativeIncrementViolations(declared: [Int], shared: Int, head: Int) -> [String] {
        var found: [String] = []
        if head != shared + declared.count { found.append("head-is-not-shared-plus-declared-count") }
        let contiguous = head > shared ? Array((shared + 1)...head) : []
        if declared != contiguous { found.append("declared-list-is-not-the-contiguous-range") }
        return found
    }

    // MARK: - Segment one · the shared ladder prefix still matches Electron

    func testTheSharedLadderPrefixStillMatchesElectron() throws {
        // The ONLY permitted skip: we are a Swift package detached from the monorepo, so
        // there is no Electron authority to compare against. Whenever the Electron source
        // IS present the guard is FAIL-CLOSED — a missing Node, a failed require, or invalid
        // output all FAIL the test (never skip), so it can never pass without verifying.
        let electronVersion = try Self.requireElectronSchemaVersion()

        XCTAssertEqual(
            Self.sharedPrefixViolations(nativeShared: SchemaMigrator.sharedLadderVersion,
                                        electron: electronVersion,
                                        nativeHead: SchemaMigrator.schemaVersion),
            [],
            """
            SHARED-PREFIX DRIFT: native sharedLadderVersion=\(SchemaMigrator.sharedLadderVersion), \
            Electron SCHEMA_VERSION=\(electronVersion), native head=\(SchemaMigrator.schemaVersion). \
            Electron added migration(s) the native ladder has not ported — port them INTO the \
            shared segment and bump `sharedLadderVersion`; do NOT append them above the \
            native-only rungs, which would renumber those. A native head below Electron rejects \
            real production DBs as .unknownVersion (fleet-wide block).
            """)
    }

    // MARK: - Segment two · the native-only increment is exactly the declared list

    func testTheNativeOnlyIncrementIsExactlyTheDeclaredList() {
        XCTAssertEqual(SchemaMigrator.nativeOnlyVersions, [24],
                       "every native-only rung is declared here by hand — add one and this line moves with it")

        XCTAssertEqual(
            Self.nativeIncrementViolations(declared: SchemaMigrator.nativeOnlyVersions,
                                           shared: SchemaMigrator.sharedLadderVersion,
                                           head: SchemaMigrator.schemaVersion),
            [],
            """
            NATIVE-INCREMENT DRIFT: declared=\(SchemaMigrator.nativeOnlyVersions), \
            sharedLadderVersion=\(SchemaMigrator.sharedLadderVersion), head=\(SchemaMigrator.schemaVersion). \
            The native-only rungs must be the contiguous range above the shared prefix and must \
            account for the whole distance to head — a `schemaVersion` bumped without a matching \
            entry (or vice versa) lands here.
            """)
    }

    /// The head is not a free-standing number: it is the shared prefix plus the declared rungs.
    func testTheHeadIsTheSharedPrefixPlusTheDeclaredRungs() {
        XCTAssertEqual(SchemaMigrator.schemaVersion,
                       SchemaMigrator.sharedLadderVersion + SchemaMigrator.nativeOnlyVersions.count)
    }

    // MARK: - Segment three · anti-vacuity — the rules are driven with synthetic drift

    /// Proves segment one can fail. If someone weakens it into a tautology, these go green-on-
    /// nothing and this test turns red. The REAL constants are never modified.
    func testTheSharedPrefixRuleRejectsSyntheticDrift() {
        // Electron moved ahead and nobody ported it.
        XCTAssertEqual(Self.sharedPrefixViolations(nativeShared: 23, electron: 24, nativeHead: 24),
                       ["shared-prefix-drift"])
        // The native head is behind Electron: the fleet-block case the original guard existed for.
        XCTAssertEqual(Self.sharedPrefixViolations(nativeShared: 22, electron: 23, nativeHead: 22),
                       ["shared-prefix-drift", "native-head-behind-electron"])
        // A native-only rung on top of an intact shared prefix is legal and must NOT be flagged.
        XCTAssertEqual(Self.sharedPrefixViolations(nativeShared: 23, electron: 23, nativeHead: 24), [])
    }

    /// Proves segment two can fail, in each of the ways a rung can be smuggled in.
    func testTheNativeIncrementRuleRejectsSyntheticDrift() {
        // `schemaVersion` bumped to 25 without declaring the rung.
        XCTAssertEqual(Self.nativeIncrementViolations(declared: [24], shared: 23, head: 25),
                       ["head-is-not-shared-plus-declared-count", "declared-list-is-not-the-contiguous-range"])
        // Declared but skipping a number.
        XCTAssertEqual(Self.nativeIncrementViolations(declared: [24, 26], shared: 23, head: 26),
                       ["head-is-not-shared-plus-declared-count", "declared-list-is-not-the-contiguous-range"])
        // A rung claimed to be native-only that actually sits inside the shared segment.
        XCTAssertEqual(Self.nativeIncrementViolations(declared: [23], shared: 23, head: 23),
                       ["head-is-not-shared-plus-declared-count", "declared-list-is-not-the-contiguous-range"])
        // The legal shapes: today's, and a hypothetical two-rung future.
        XCTAssertEqual(Self.nativeIncrementViolations(declared: [24], shared: 23, head: 24), [])
        XCTAssertEqual(Self.nativeIncrementViolations(declared: [24, 25], shared: 23, head: 25), [])
        // And the shape before any native-only rung existed.
        XCTAssertEqual(Self.nativeIncrementViolations(declared: [], shared: 23, head: 23), [])
    }

    // MARK: - Helpers

    /// Read Electron's authoritative `SCHEMA_VERSION`, or fail (never pass) when the source is
    /// present but unreadable. Skips ONLY when there is no Electron source to compare against.
    private static func requireElectronSchemaVersion() throws -> Int {
        guard let electronIndex = locateElectronDbIndex() else {
            throw XCTSkip("electron/db/index.js not found by walking up from \(#filePath) — package is detached from the monorepo; parity is enforced in-repo / CI")
        }

        // Read the REAL exported value; `require('electron')` in plain Node returns a
        // path string (so `app` is undefined and no DB is ever opened) — loading the
        // module only defines the MIGRATIONS array, so this has no side effects.
        let r = runEnvNode([
            "-e",
            "process.stdout.write(String(require(process.argv[1]).SCHEMA_VERSION))",
            electronIndex.path,
        ])
        guard r.status == 0 else {
            XCTFail("""
                Electron source is present but its authoritative SCHEMA_VERSION could not be read \
                (`env node` exited \(r.status) — Node missing or the require failed). In-repo the \
                guard MUST run; install Node / fix the Electron require. stderr: \(r.err.prefix(400))
                """)
            throw Abort.unreadable
        }
        guard let electronVersion = Int(r.out.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            XCTFail("Electron SCHEMA_VERSION output was not an integer: '\(r.out)' (stderr: \(r.err.prefix(400)))")
            throw Abort.unreadable
        }
        guard electronVersion > 0 else {
            XCTFail("Electron SCHEMA_VERSION should be a positive integer, got \(electronVersion)")
            throw Abort.unreadable
        }
        return electronVersion
    }

    /// Thrown after an `XCTFail` so the caller stops instead of comparing against a bogus value.
    /// It is never a silent path: the failure has already been recorded when this is thrown.
    private enum Abort: Error { case unreadable }

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
    /// PATH; a missing node yields a non-zero status (handled as a FAILURE by the caller).
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
