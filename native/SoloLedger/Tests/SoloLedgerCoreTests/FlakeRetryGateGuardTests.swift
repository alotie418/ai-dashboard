import Foundation
import XCTest

/// T1.5 — the CI wiring that retries the flake tracked in issue #400, and the
/// constraints that keep the retry honest.
///
/// ## What was missing
///
/// `HardenedActiveOpenTests.testPostOpenUnlinkCaughtByHasMoved` fails intermittently
/// (`SQLITE_FCNTL_HAS_MOVED` returning `SQLITE_IOERR_VNODE`, rc 6922). Five occurrences
/// are on issue #400's ledger, the last of them a same-image, same-window red-vs-green
/// pair, and the escalation clause on that issue — "if the recurrence rate starts hurting
/// the merge queue, escalate to job-level single-test retry + mandatory accounting" — was
/// met. Until now every recurrence was handled by a human: stop, write a ledger row, ask
/// for authorisation, re-run. This round makes the machine do it, and makes it impossible
/// for the machine to do only half.
///
/// ## What must not drift
///
/// The other clause on #400 is the one worth guarding: **an auto-rerun that leaves no
/// trace is never allowed.** The wrapper therefore only reaches a green exit through a
/// path that has already recorded the recurrence on the issue, in the job summary and in
/// the log. Two things could quietly undo that from outside the wrapper — putting a bare
/// `swift test` back in the workflow (the retry never runs), or taking `issues: write` off
/// the job (the recording can never succeed, and someone "fixes" the red by deleting the
/// accounting). Both are pinned below.
///
/// ## Why the sources are scanned with comments stripped
///
/// `scripts/swift-test-with-retry.mjs` documents itself at length: its prose names
/// `::warning::`, `GITHUB_STEP_SUMMARY`, `--filter` and `swift test`. A grep over the raw
/// file would therefore stay green after the code implementing any of them was deleted,
/// as long as the paragraph describing it survived — the failure mode
/// ``WindowReopenCommandGuardTests`` was built to avoid. Every scan here runs on the file
/// with comments removed, and ``testTheCommentStripperIsNotFooledByProseOrByURLs`` proves
/// the stripper both drops a decoy and keeps a `//` that belongs to a string.
///
/// ## Deliberately not pinned, recorded so the omission is not mistaken for an oversight
///
/// * **The retry's behaviour.** That the retry happens exactly once, only for a lone
///   failure of this test, and only when recording succeeds, is decided by control flow
///   in JavaScript and is pinned where it can actually be executed:
///   `scripts/test-swift-test-with-retry.mjs`, which this guard checks is wired into
///   `check:all` so CI runs it. What is pinned *here* is the wiring, not the logic.
/// * **The order of steps inside the job.** The accounting is inside the wrapper rather
///   than a separate workflow step, precisely so that "record, then go green" is one
///   decision in one process instead of an ordering convention a later edit could shuffle.
/// * **Which HTTP status the API returns, and fork-PR behaviour.** A pull request from a
///   fork gets a read-only token whatever `permissions:` says, so the recording would fail
///   and the job would go red rather than re-run silently. That is the right direction to
///   fail in, it is documented in the wrapper, and it is not simulated here.
final class FlakeRetryGateGuardTests: XCTestCase {

    static let workflowPath = ".github/workflows/ci.yml"
    static let wrapperPath = "scripts/swift-test-with-retry.mjs"
    static let semanticsPath = "scripts/test-swift-test-with-retry.mjs"
    static let packageJSONPath = "package.json"

    /// The job key under `jobs:`, and the `name:` GitHub reports it under — that string is
    /// the required status check configured on `main`.
    static let testJobKey = "checks"
    static let requiredCheckName = "Guards + migrations + build"

    /// The one test the wrapper is allowed to retry, and where it is declared.
    static let flakySuite = "HardenedActiveOpenTests"
    static let flakyMethod = "testPostOpenUnlinkCaughtByHasMoved"
    static let flakyModule = "SoloLedgerCoreTests"
    static let issueNumber = 400

    static let npmScriptName = "check:flaky-retry"

    // MARK: - Reading files

    static func repoText(_ path: String) throws -> String {
        try String(contentsOf: ReleaseCompileGateGuardTests.repoRoot().appendingPathComponent(path),
                   encoding: .utf8)
    }

    // MARK: - Stripping JavaScript comments

    /// `source` with `//` and `/* … */` comments removed, and string literals left alone.
    ///
    /// String awareness is the whole point: `'https://api.github.com'` contains `//` and a
    /// stripper that did not know it was inside quotes would cut the line in half — which
    /// would make the assertions below pass for reasons unrelated to what they claim.
    static func strippedJavaScript(_ source: String) -> String {
        var out = ""
        var inBlockComment = false
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            var kept = ""
            var quote: Character?
            var escaped = false
            let characters = Array(line)
            var index = 0
            while index < characters.count {
                let character = characters[index]
                let next = index + 1 < characters.count ? characters[index + 1] : nil
                if inBlockComment {
                    if character == "*" && next == "/" { inBlockComment = false; index += 2; continue }
                    index += 1
                    continue
                }
                if let open = quote {
                    kept.append(character)
                    if escaped { escaped = false } else if character == "\\" { escaped = true }
                    else if character == open { quote = nil }
                    index += 1
                    continue
                }
                if character == "/" && next == "/" { break }
                if character == "/" && next == "*" { inBlockComment = true; index += 2; continue }
                if character == "'" || character == "\"" || character == "`" { quote = character }
                kept.append(character)
                index += 1
            }
            out += kept + "\n"
        }
        return out
    }

    /// The value of `export const NAME = '…';` in already-stripped JavaScript.
    static func stringConstant(_ name: String, in stripped: String) -> String? {
        for line in stripped.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("export const \(name) = ") else { continue }
            var value = String(trimmed.dropFirst("export const \(name) = ".count))
            guard value.hasSuffix(";") else { return nil }
            value = String(value.dropLast())
            guard value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") else { return nil }
            return String(value.dropFirst().dropLast())
        }
        return nil
    }

    static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var cursor = haystack.startIndex
        while let found = haystack.range(of: needle, range: cursor..<haystack.endIndex) {
            count += 1
            cursor = found.upperBound
        }
        return count
    }

    // MARK: - Reading the workflow

    /// Every command line inside a job's steps, comments dropped.
    static func commandLines(inJob key: String, of yaml: String) -> [String] {
        guard let job = ReleaseCompileGateGuardTests.jobBlocks(in: yaml).first(where: { $0.key == key })
        else { return [] }
        return ReleaseCompileGateGuardTests.stepBlocks(in: job.body).flatMap { step in
            step.text.split(separator: "\n", omittingEmptySubsequences: false)
                .compactMap { ReleaseCompileGateGuardTests.commandLine(String($0)) }
        }
    }

    /// The `permissions:` mapping a job declares — `["contents": "read", …]`. A job that
    /// declares none returns `nil`, which is NOT the same as declaring an empty one: a job
    /// with no block inherits the repository default, measured here as read-only.
    static func permissions(ofJob key: String, in yaml: String) -> [String: String]? {
        guard let job = ReleaseCompileGateGuardTests.jobBlocks(in: yaml).first(where: { $0.key == key })
        else { return nil }
        let lines = job.body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(where: {
            $0.hasPrefix("    permissions:") && !$0.hasPrefix("     ")
        }) else { return nil }
        var out: [String: String] = [:]
        for line in lines[(start + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard line.hasPrefix("      "), !line.hasPrefix("       "),
                  let colon = trimmed.firstIndex(of: ":") else { break }
            out[String(trimmed[trimmed.startIndex..<colon])] =
                String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        return out
    }

    /// The value of an `env:` key anywhere in the workflow, e.g.
    /// `SWIFT_WARNING_SCRATCH_PATH: .swift-gate-build`.
    static func envValue(_ key: String, in yaml: String) -> String? {
        for line in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // A comment that quotes the key is not a declaration of it.
            guard !trimmed.hasPrefix("#"), trimmed.hasPrefix("\(key):") else { continue }
            return String(trimmed.dropFirst("\(key):".count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// The step that runs the wrapper, found by what it RUNS rather than by what its text
    /// mentions.
    ///
    /// The distinction is not academic. A block of `#` comments sitting between two steps
    /// belongs, as far as an indentation scanner is concerned, to the one above it — so the
    /// paragraph in ci.yml explaining the wrapper is part of the *warning gate's* step text,
    /// and picking a step by `text.contains(wrapperPath)` selects the wrong one. (Measured:
    /// the first version of this file did exactly that and reported a missing token on a
    /// step that never needed one.) Comments are dropped first, so only a real `run:` counts.
    static func wrapperStep(in yaml: String) -> (name: String, text: String)? {
        guard let job = ReleaseCompileGateGuardTests.jobBlocks(in: yaml)
            .first(where: { $0.key == testJobKey }) else { return nil }
        return ReleaseCompileGateGuardTests.stepBlocks(in: job.body).first { step in
            step.text.split(separator: "\n", omittingEmptySubsequences: false)
                .compactMap { ReleaseCompileGateGuardTests.commandLine(String($0)) }
                .contains { $0.contains(wrapperPath) }
        }
    }

    /// Commands that run the Swift test suite directly, rather than through the wrapper.
    static func bareSwiftTestCommands(in yaml: String) -> [String] {
        ReleaseCompileGateGuardTests.jobBlocks(in: yaml).flatMap { job in
            commandLines(inJob: job.key, of: yaml)
        }.filter { $0 == "swift test" || $0.hasPrefix("swift test ") }
    }

    // MARK: - The scanners are not no-ops, measured on the real files

    func testTheCommentStripperIsNotFooledByProseOrByURLs() {
        let stripped = Self.strippedJavaScript("""
        // const SCRATCH_PATH = '.decoy'; ::warning:: GITHUB_STEP_SUMMARY --filter
        const api = 'https://api.github.com'; // a trailing comment
        /* block
           ::warning:: */ const kept = 1;
        """)
        XCTAssertFalse(stripped.contains("decoy"), "a commented-out constant must not read as one")
        XCTAssertFalse(stripped.contains("a trailing comment"))
        XCTAssertFalse(stripped.contains("block"))
        XCTAssertTrue(stripped.contains("'https://api.github.com'"), """
            the `//` inside a URL string was treated as a comment. Every assertion in this \
            file scans stripped source, so a stripper that cuts strings in half would make \
            them pass or fail for reasons that have nothing to do with the code.
            """)
        XCTAssertTrue(stripped.contains("const kept = 1;"))
        XCTAssertEqual(Self.occurrences(of: "::warning::", in: stripped), 0)
    }

    func testTheWorkflowScannerFindsTheRealJobAndItsSteps() throws {
        let yaml = try Self.repoText(Self.workflowPath)
        let commands = Self.commandLines(inJob: Self.testJobKey, of: yaml)
        XCTAssertTrue(commands.contains("npm ci --ignore-scripts"), """
            the scanner found \(commands.count) command(s) in `\(Self.testJobKey)` and none of \
            them was the npm install. A scanner that reads nothing agrees with everything.
            """)
        XCTAssertTrue(commands.contains("npm run check:all"), "parsed commands: \(commands)")
        XCTAssertEqual(Self.commandLines(inJob: "no-such-job", of: yaml), [],
                       "an unknown job must yield nothing rather than the whole file")
    }

    func testTheConstantReaderReadsTheRealWrapperAndRefusesJunk() throws {
        let stripped = Self.strippedJavaScript(try Self.repoText(Self.wrapperPath))
        XCTAssertEqual(Self.stringConstant("FLAKY_SUITE", in: stripped), Self.flakySuite)
        XCTAssertNil(Self.stringConstant("NO_SUCH_CONSTANT", in: stripped))
        XCTAssertNil(Self.stringConstant("X", in: "export const X = 1;\n"),
                     "a non-string constant is not a string constant")
    }

    // MARK: - (a) the Core tests still run, and they run through the wrapper

    func testTheCoreTestJobIsStillTheOneTheRequiredCheckNames() throws {
        let yaml = try Self.repoText(Self.workflowPath)
        let job = try XCTUnwrap(ReleaseCompileGateGuardTests.jobBlocks(in: yaml)
            .first { $0.key == Self.testJobKey }, """
            the `\(Self.testJobKey)` job is gone. The Core test run — and with it the retry \
            wrapper — lives inside it.
            """)
        XCTAssertEqual(ReleaseCompileGateGuardTests.declaredName(ofJob: job.body),
                       Self.requiredCheckName, """
            the job's `name:` changed. That string IS a required status check on `main`; a \
            renamed job never reports under the old name, so the check sits as "Expected" and \
            blocks every pull request permanently — including the one that renamed it.
            """)
    }

    func testTheCoreTestsRunThroughTheRetryWrapper() throws {
        let yaml = try Self.repoText(Self.workflowPath)
        let invocations = Self.commandLines(inJob: Self.testJobKey, of: yaml)
            .filter { $0.contains(Self.wrapperPath) }
        XCTAssertEqual(invocations, ["node \(Self.wrapperPath)"], """
            the `\(Self.testJobKey)` job no longer runs the Core tests through \
            \(Self.wrapperPath). Without it there is no retry — and, more to the point, no \
            accounting: issue #\(Self.issueNumber) allows a re-run only if it leaves a trace.
            """)
    }

    func testNothingRunsTheSwiftTestSuiteAroundTheWrapper() throws {
        let yaml = try Self.repoText(Self.workflowPath)
        XCTAssertEqual(Self.bareSwiftTestCommands(in: yaml), [], """
            the workflow runs `swift test` directly. That bypasses the wrapper entirely: the \
            flake goes back to failing the job outright, and — worse — a second, unwrapped run \
            would be an auto-rerun with no ledger entry, which is what issue \
            #\(Self.issueNumber) forbids in as many words.
            """)
    }

    func testTheWrapperAndTheWarningGateStillShareOneBuildDirectory() throws {
        let yaml = try Self.repoText(Self.workflowPath)
        let stripped = Self.strippedJavaScript(try Self.repoText(Self.wrapperPath))
        let gatePath = try XCTUnwrap(Self.envValue("SWIFT_WARNING_SCRATCH_PATH", in: yaml), """
            the warning gate no longer names its scratch path in the workflow.
            """)
        XCTAssertEqual(Self.stringConstant("SCRATCH_PATH", in: stripped), gatePath, """
            the wrapper's scratch path and the warning gate's diverged. They were one \
            directory on purpose: the gate builds from a throwaway path and KEEPS it so the \
            test run reuses that compile. Two paths means two full builds, silently.
            """)
        XCTAssertEqual(Self.stringConstant("PACKAGE_PATH", in: stripped), "native/SoloLedger", """
            the wrapper tests a different package than the one CI used to.
            """)
    }

    // MARK: - (b) the job can actually record what it retried

    func testTheJobMayWriteToTheIssueItAccountsIn() throws {
        let yaml = try Self.repoText(Self.workflowPath)
        let declared = try XCTUnwrap(Self.permissions(ofJob: Self.testJobKey, in: yaml), """
            the `\(Self.testJobKey)` job declares no `permissions:` block, so it falls back to \
            the repository default — measured read-only. The retry would then always fail to \
            record, which fails the job; the tempting "fix" for that red is to delete the \
            accounting, and this assertion is what stands in the way.
            """)
        XCTAssertEqual(declared["issues"], "write", """
            the job cannot append to issue #\(Self.issueNumber)'s ledger. permissions: \(declared)
            """)
        XCTAssertEqual(declared["contents"], "read", """
            a job-level `permissions:` block replaces the defaults wholesale rather than \
            adding to them, so dropping `contents: read` breaks actions/checkout. \
            permissions: \(declared)
            """)
    }

    func testTheWrapperStepIsHandedTheToken() throws {
        let yaml = try Self.repoText(Self.workflowPath)
        let step = try XCTUnwrap(Self.wrapperStep(in: yaml), "the wrapper step is gone")
        XCTAssertTrue(step.text.contains("GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}"), """
            the wrapper step does not map the token into its environment. `permissions:` alone \
            is not enough — GitHub does not put GITHUB_TOKEN in a `run:` step's environment \
            unless the step asks for it, so the recording would fail for a reason that looks \
            nothing like its cause. Step text: \(step.text)
            """)
    }

    // MARK: - (c) the wrapper retries that test and no other, and records three ways

    func testTheWrapperNamesATestThatExists() throws {
        let stripped = Self.strippedJavaScript(try Self.repoText(Self.wrapperPath))
        XCTAssertEqual(Self.stringConstant("FLAKY_MODULE", in: stripped), Self.flakyModule)
        XCTAssertEqual(Self.stringConstant("FLAKY_SUITE", in: stripped), Self.flakySuite)
        XCTAssertEqual(Self.stringConstant("FLAKY_METHOD", in: stripped), Self.flakyMethod)

        // The strongest oracle available for a typo: the name has to belong to a test that
        // is really there. A `--filter` that matches nothing exits 0 with "Executed 0 tests"
        // (measured), so a misspelling would otherwise turn the retry into a rubber stamp.
        let suiteSource = try String(
            contentsOf: AppTargetRegistrationGuardTests.packageRoot()
                .appendingPathComponent("Tests/\(Self.flakyModule)/\(Self.flakySuite).swift"),
            encoding: .utf8)
        XCTAssertEqual(Self.occurrences(of: "func \(Self.flakyMethod)()", in: suiteSource), 1, """
            \(Self.flakySuite).swift does not declare exactly one \(Self.flakyMethod)(). The \
            wrapper retries that name by string; if it stops naming a real test the retry \
            silently stops testing anything.
            """)
    }

    func testTheWrapperRetriesByFilterAndAnchorsTheName() throws {
        let stripped = Self.strippedJavaScript(try Self.repoText(Self.wrapperPath))
        XCTAssertEqual(Self.occurrences(of: "'--filter'", in: stripped), 1, """
            the wrapper passes `--filter` in \(Self.occurrences(of: "'--filter'", in: stripped)) \
            places. Exactly one is what makes the retry a single-test retry.
            """)
        XCTAssertTrue(stripped.contains("${FLAKY_MODULE}\\\\.${FLAKY_SUITE}/${FLAKY_METHOD}$"), """
            the filter is no longer built from the three pinned name constants, anchored at \
            the end. `--filter` takes a regex, so an unanchored pattern also selects \
            `\(Self.flakyMethod)Twice` and any other name that merely starts the same way.
            """)
    }

    func testTheWrapperRecordsThroughAllThreeChannels() throws {
        let stripped = Self.strippedJavaScript(try Self.repoText(Self.wrapperPath))
        XCTAssertTrue(stripped.contains("export const ISSUE_NUMBER = \(Self.issueNumber);"), """
            the wrapper no longer records against issue #\(Self.issueNumber).
            """)
        // Each needle is the CALL, not the name of the thing it talks to: deleting
        // `await io.appendFile(summaryPath, …)` while leaving `const summaryPath =
        // env.GITHUB_STEP_SUMMARY` behind would satisfy a needle written the other way.
        for (channel, needle) in [
            ("the issue's ledger", "/issues/${ISSUE_NUMBER}/comments"),
            ("the job summary", "await io.appendFile(summaryPath,"),
            ("the log annotation", "io.warn(`::warning::"),
        ] {
            XCTAssertTrue(stripped.contains(needle), """
                the wrapper no longer writes to \(channel) (`\(needle)` is gone from its code — \
                comments do not count). All three are load-bearing: recording is the \
                precondition for the retry being allowed to pass.
                """)
        }
    }

    // MARK: - (d) the behaviour is pinned somewhere CI actually runs

    /// The annotation is only recorded if it is actually delivered. On POSIX a stdout
    /// that is a pipe — a runner step's stdout — is written asynchronously, and
    /// `process.exit()` does not wait for pending writes. Measured with a slow reader:
    /// `process.exit(0)` after 20001 lines delivered 1332 of them and dropped the
    /// `::warning::` line entirely, while still exiting 0. That is the accounting
    /// silently failing on the green path, which is the one failure mode this whole
    /// round exists to prevent.
    func testTheWrapperNeverCutsItsOwnOutputShort() throws {
        let stripped = Self.strippedJavaScript(try Self.repoText(Self.wrapperPath))
        XCTAssertEqual(Self.occurrences(of: "process.exit(", in: stripped), 0, """
            the wrapper calls process.exit(). On a pipe that discards output still queued \
            for stdout — including the ::warning:: annotation written a moment earlier — \
            so the job can exit 0 having recorded less than it claims. Set \
            `process.exitCode` and let the event loop drain instead.
            """)
        XCTAssertTrue(stripped.contains("process.exitCode = code;"), """
            the wrapper no longer sets an exit code at all, so a red Core run would exit 0.
            """)
    }

    func testTheRetrySemanticsAreExercisedByEveryPullRequest() throws {
        let packageJSON = try Self.repoText(Self.packageJSONPath)
        XCTAssertTrue(packageJSON.contains("\"\(Self.npmScriptName)\": \"node \(Self.semanticsPath)\""), """
            package.json no longer defines `\(Self.npmScriptName)` as `node \(Self.semanticsPath)`. \
            That script is where the retry's decision tree — retry once, only for this test, \
            only when recording succeeds — is actually executed.
            """)
        XCTAssertTrue(packageJSON.contains("npm run \(Self.npmScriptName)"), """
            `\(Self.npmScriptName)` is defined but nothing runs it. It has to be inside \
            `check:all`, which the \(Self.testJobKey) job runs, or the semantics are pinned \
            by a file no pull request ever executes.
            """)
        let checkAll = try XCTUnwrap(packageJSON.split(separator: "\n")
            .first { $0.contains("\"check:all\":") }.map(String.init))
        XCTAssertTrue(checkAll.contains("npm run \(Self.npmScriptName)"),
                      "check:all does not chain \(Self.npmScriptName): \(checkAll)")
    }

    // MARK: - Fail-closed

    func testUnreadableInputsYieldNothingRatherThanSilentAgreement() {
        XCTAssertEqual(Self.commandLines(inJob: Self.testJobKey, of: ""), [])
        XCTAssertNil(Self.permissions(ofJob: Self.testJobKey, in: ""))
        XCTAssertNil(Self.envValue("SWIFT_WARNING_SCRATCH_PATH", in: ""))
        XCTAssertNil(Self.stringConstant("SCRATCH_PATH", in: ""))
        XCTAssertEqual(Self.bareSwiftTestCommands(in: ""), [])
    }

    // MARK: - Reverse proof: each defect shape, on synthetic workflow text

    static func fixture(jobName: String = FlakeRetryGateGuardTests.requiredCheckName,
                        permissionsBlock: [String] = ["contents: read", "issues: write"],
                        declarePermissions: Bool = true,
                        testCommand: String = "node scripts/swift-test-with-retry.mjs",
                        mapToken: Bool = true) -> String {
        var out = "jobs:\n"
        out += "  checks:\n"
        out += "    name: \(jobName)\n"
        out += "    runs-on: macos-latest\n"
        if declarePermissions {
            out += "    permissions:\n"
            for entry in permissionsBlock { out += "      \(entry)\n" }
        }
        out += "    steps:\n"
        out += "      - uses: actions/checkout@v4\n"
        out += "      - run: npm ci --ignore-scripts\n"
        out += "      - name: Native Swift warning gate\n"
        out += "        env:\n"
        out += "          SWIFT_WARNING_SCRATCH_PATH: .swift-gate-build\n"
        out += "        run: npm run check:swift-warnings\n"
        out += "      # a comment may mention `swift test` without being one\n"
        out += "      - name: Native SwiftUI Core tests\n"
        if mapToken {
            out += "        env:\n"
            out += "          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}\n"
        }
        out += "        run: \(testCommand)\n"
        return out
    }

    /// The fixture at the pinned shape reads exactly as the real file does, or the
    /// counterexamples below would prove nothing.
    func testTheFixtureAtThePinnedShapeIsClean() throws {
        let yaml = Self.fixture()
        XCTAssertEqual(Self.permissions(ofJob: Self.testJobKey, in: yaml),
                       ["contents": "read", "issues": "write"])
        XCTAssertEqual(Self.commandLines(inJob: Self.testJobKey, of: yaml)
                        .filter { $0.contains(Self.wrapperPath) }, ["node \(Self.wrapperPath)"])
        XCTAssertEqual(Self.bareSwiftTestCommands(in: yaml), [], "…and the comment is not a command")
        XCTAssertEqual(Self.envValue("SWIFT_WARNING_SCRATCH_PATH", in: yaml), ".swift-gate-build")
        XCTAssertEqual(ReleaseCompileGateGuardTests.declaredName(
            ofJob: try XCTUnwrap(ReleaseCompileGateGuardTests.jobBlocks(in: yaml).first).body),
                       Self.requiredCheckName)
    }

    /// (a) The state this round replaces: `swift test` run directly, no wrapper.
    func testAWorkflowThatCallsSwiftTestDirectlyIsReported() {
        let yaml = Self.fixture(testCommand: "swift test --package-path native/SoloLedger")
        XCTAssertEqual(Self.bareSwiftTestCommands(in: yaml),
                       ["swift test --package-path native/SoloLedger"])
        XCTAssertEqual(Self.commandLines(inJob: Self.testJobKey, of: yaml)
                        .filter { $0.contains(Self.wrapperPath) }, [],
                       "…and the wrapper is correctly reported as absent")
    }

    /// (a′) A second, unwrapped run added alongside the wrapper — the "just re-run it"
    /// shape, which would retry with no ledger entry at all.
    func testAnExtraBareSwiftTestAlongsideTheWrapperIsReported() {
        var yaml = Self.fixture()
        yaml += "      - name: one more for luck\n"
        yaml += "        run: swift test --package-path native/SoloLedger\n"
        XCTAssertEqual(Self.bareSwiftTestCommands(in: yaml).count, 1)
        XCTAssertEqual(Self.commandLines(inJob: Self.testJobKey, of: yaml)
                        .filter { $0.contains(Self.wrapperPath) }.count, 1,
                       "…while the wrapper is still there, which is what makes this shape sneaky")
    }

    /// (b) The permission removals, in both shapes.
    func testAJobWithoutAPermissionsBlockIsReported() {
        XCTAssertNil(Self.permissions(ofJob: Self.testJobKey, in: Self.fixture(declarePermissions: false)))
    }

    func testAJobThatCannotWriteIssuesIsReported() {
        let declared = Self.permissions(ofJob: Self.testJobKey,
                                        in: Self.fixture(permissionsBlock: ["contents: read"]))
        XCTAssertEqual(declared, ["contents": "read"])
        XCTAssertNil(declared?["issues"])
    }

    func testAJobThatForgotContentsReadIsReported() {
        let declared = Self.permissions(ofJob: Self.testJobKey,
                                        in: Self.fixture(permissionsBlock: ["issues: write"]))
        XCTAssertEqual(declared, ["issues": "write"])
        XCTAssertNil(declared?["contents"])
    }

    /// (c) The token that `permissions:` alone does not provide.
    func testAStepThatDoesNotMapTheTokenIsReported() throws {
        let step = try XCTUnwrap(Self.wrapperStep(in: Self.fixture(mapToken: false)))
        XCTAssertFalse(step.text.contains("GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}"))
    }

    /// (c′) …and the step is picked by what it runs, not by what its neighbour's comment
    /// mentions. The fixture places a comment naming the wrapper between two steps, which
    /// an indentation scanner attributes to the step ABOVE — the shape that made the first
    /// version of this file report a missing token on the warning-gate step.
    func testTheStepIsPickedByWhatItRunsNotByProseAboveIt() throws {
        var yaml = Self.fixture()
        yaml = yaml.replacingOccurrences(
            of: "      # a comment may mention `swift test` without being one\n",
            with: "      # a comment may mention `swift test` and even node scripts/swift-test-with-retry.mjs\n")
        let step = try XCTUnwrap(Self.wrapperStep(in: yaml))
        XCTAssertEqual(step.name, "Native SwiftUI Core tests", """
            the step carrying the comment was selected instead of the step running the \
            wrapper. Selected: \(step.name)
            """)
        XCTAssertTrue(step.text.contains("GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}"))
    }

    /// (d) The rename that would silently unhook the required check.
    func testARenamedJobIsReported() throws {
        let yaml = Self.fixture(jobName: "Guards")
        XCTAssertNotEqual(ReleaseCompileGateGuardTests.declaredName(
            ofJob: try XCTUnwrap(ReleaseCompileGateGuardTests.jobBlocks(in: yaml).first).body),
                          Self.requiredCheckName)
    }

    /// (e) A wrapper whose accounting has been deleted while its prose survives — the
    /// exact shape a raw grep would miss.
    func testAWrapperWhoseAccountingWasDeletedButDocumentedIsReported() {
        let gutted = """
        // Records to ::warning::, to env.GITHUB_STEP_SUMMARY and to
        // /issues/${ISSUE_NUMBER}/comments before going green.
        export const ISSUE_NUMBER = 400;
        export async function record() { return; }
        """
        XCTAssertTrue(gutted.contains("::warning::"), "the decoy prose is there in the raw file…")
        let stripped = Self.strippedJavaScript(gutted)
        XCTAssertFalse(stripped.contains("::warning::"), "…and gone once comments are dropped")
        XCTAssertFalse(stripped.contains("env.GITHUB_STEP_SUMMARY"))
        XCTAssertFalse(stripped.contains("/issues/${ISSUE_NUMBER}/comments"))
        XCTAssertTrue(stripped.contains("export const ISSUE_NUMBER = 400;"),
                      "…while the code that is still code survives")
    }

    /// (f) A misspelled test name — the defect that would make `--filter` match nothing
    /// and every retry pass.
    func testAMisspelledTestNameIsReported() throws {
        let suiteSource = try String(
            contentsOf: AppTargetRegistrationGuardTests.packageRoot()
                .appendingPathComponent("Tests/\(Self.flakyModule)/\(Self.flakySuite).swift"),
            encoding: .utf8)
        XCTAssertEqual(Self.occurrences(of: "func \(Self.flakyMethod)Typo()", in: suiteSource), 0, """
            a name that does not exist must count zero — otherwise the existence check above \
            proves nothing.
            """)
        XCTAssertEqual(Self.occurrences(of: "func testPostOpenUnlink()", in: suiteSource), 0)
    }

    /// (g) An unanchored filter, which would also select longer names.
    func testAnUnanchoredFilterIsReported() {
        let unanchored = "export const FLAKY_FILTER = `${FLAKY_MODULE}\\\\.${FLAKY_SUITE}/${FLAKY_METHOD}`;"
        XCTAssertFalse(unanchored.contains("${FLAKY_MODULE}\\\\.${FLAKY_SUITE}/${FLAKY_METHOD}$"))
        let hardcoded = "export const FLAKY_FILTER = 'HardenedActiveOpenTests/testPostOpen';"
        XCTAssertFalse(hardcoded.contains("${FLAKY_MODULE}\\\\.${FLAKY_SUITE}/${FLAKY_METHOD}$"), """
            a filter written out by hand no longer tracks the pinned constants, so renaming \
            the test would leave the filter pointing at nothing.
            """)
    }

    /// (h) The semantics test defined but unchained — pinned by a file nothing runs.
    func testASemanticsScriptThatNothingRunsIsReported() {
        let orphan = """
          "check:flaky-retry": "node scripts/test-swift-test-with-retry.mjs",
          "check:all": "npm run check:raw-keys && npm run check:csp",
        """
        XCTAssertTrue(orphan.contains("\"\(Self.npmScriptName)\": \"node \(Self.semanticsPath)\""))
        let checkAll = orphan.split(separator: "\n").first { $0.contains("\"check:all\":") }
        XCTAssertFalse(String(checkAll ?? "").contains("npm run \(Self.npmScriptName)"), """
            a check:all that does not chain the script must be visible as such, or the \
            assertion on the real package.json is satisfied by the definition alone.
            """)
    }
}
