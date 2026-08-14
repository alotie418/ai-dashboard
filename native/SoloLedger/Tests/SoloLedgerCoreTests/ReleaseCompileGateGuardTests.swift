import Foundation
import XCTest

/// 2c-6 — the CI step that compiles the Release configuration, and the constraints that keep it
/// a *compile* gate.
///
/// ## What was missing
///
/// Both `xcodebuild` invocations in `.github/workflows/ci.yml` said `-configuration Debug`, and
/// `swift test` never sees the app target at all (`Package.swift` leaves `Sources/SoloLedger/**`
/// out of every SwiftPM target). So nothing in this repository ever compiled Release. That is not
/// a formality: the two configurations are not the same code. `#if DEBUG` picks the data
/// directory name, wraps the Powerbox panel override in `FilePanels`, and gates the debug
/// harnesses — so a Release-only compile error could sit in `main` indefinitely and surface for
/// the first time inside an App Store archive, which is the worst place to learn about it. 2c-4
/// had already pointed `ArchiveAction` at Release; this round is what makes that configuration
/// actually get built by something.
///
/// ## Why the gate must never grow past `build`
///
/// Release carries the production bundle id `com.alotie418.sololedger`, so anything RUN from it
/// resolves `Application Support` into `~/Library/Containers/com.alotie418.sololedger` — the real
/// container, shared with the Electron MAS line. That is the same red line
/// ``SchemeConfigurationGuardTests`` holds on the scheme side, and it has to be held here too:
/// the cheapest way to "improve" a Release build step is to append `test` to it, and that would
/// point the app-hosted tests at live user data. Compiling opens no container.
///
/// `archive` is excluded for a different reason: archiving needs the certificates and the
/// provisioning profile that `scripts/archive-mas.sh` demands, no archive has ever been produced,
/// and doing it is a separately authorised step — not something CI should start doing quietly.
///
/// ## Why the workflow is parsed by hand
///
/// `SoloLedgerCore` has no dependencies and gaining one so a guard can parse YAML would be a
/// worse trade than a small scanner. The scanner is line- and indentation-based, and every
/// structural assumption it makes is pinned twice: once against the real file (it must find the
/// real jobs, the real steps and the real invocations, and must NOT invent any) and once against
/// synthetic text carrying each defect shape. Comment lines are dropped before commands are
/// located — a comment is not a command — which is also why the prose above may name a flag
/// without tripping the checks below.
///
/// ## Deliberately not pinned, recorded so the omission is not mistaken for an oversight
///
/// * **The gate's separate `-derivedDataPath`.** Its product carries the production bundle id, so
///   it is kept out of the tree the Debug steps used; that is hygiene, not a safety property, and
///   a future round that wants to share the directory for speed should be free to.
/// * **`ARCHS`.** Neither `ARCHS` nor `ONLY_ACTIVE_ARCH` is set for Release, so the gate builds a
///   universal binary (measured: `x86_64 arm64`) while D4 says the product ships arm64-only.
///   Pinning the shipped architecture belongs with the archive/export round; for a compile gate,
///   two slices is more coverage rather than less.
/// * **The test bundles.** Measured: `xcodebuild build` on this scheme produces `SoloLedger.app`
///   and no `.xctest` — the two test targets are `buildForTesting` only. This gate therefore
///   covers the app target and `SoloLedgerCore`, not the test targets' own sources.
final class ReleaseCompileGateGuardTests: XCTestCase {

    static let workflowPath = ".github/workflows/ci.yml"

    /// The job key under `jobs:`, and the `name:` GitHub shows for it. The name is the string
    /// configured in this repository's required-status-check list; the key is not.
    static let gateJobKey = "native-app"
    static let requiredCheckName = "Native SwiftUI app (xcodebuild + unit tests)"

    static let expectedJobKeys = ["checks", "e2e", "electron-e2e", "native-app", "report-goldens"]

    static let gateProject = "native/SoloLedger/App/SoloLedger.xcodeproj"
    static let gateScheme = "SoloLedger"

    /// Actions that make xcodebuild run a process built from the configuration under test.
    static let actionsThatRunTheProduct: Set<String> = ["test", "test-without-building", "run"]

    // MARK: - Reading the workflow

    static func repoRoot() -> URL {
        AppTargetRegistrationGuardTests.packageRoot()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    static func workflowText() throws -> String {
        try String(contentsOf: repoRoot().appendingPathComponent(workflowPath), encoding: .utf8)
    }

    // MARK: - The scanner

    /// A line that could carry a command: comments dropped, a leading `run:` stripped, the block
    /// scalar indicator (`|`) discarded. Returns `nil` for anything that cannot be one.
    static func commandLine(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { return nil }
        for prefix in ["- run:", "run:"] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        if text.isEmpty || text == "|" || text == ">" { return nil }
        return text
    }

    /// Every `xcodebuild …` command in a chunk of workflow text, as token lists. Backslash line
    /// continuations are joined; quotes around a whole token are stripped.
    static func xcodebuildCommands(in text: String) -> [[String]] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { commandLine(String($0)) }
        var out: [[String]] = []
        var index = 0
        while index < lines.count {
            guard lines[index] == "xcodebuild" || lines[index].hasPrefix("xcodebuild ") else {
                index += 1
                continue
            }
            var joined = ""
            var cursor = index
            while cursor < lines.count {
                var piece = lines[cursor]
                let continues = piece.hasSuffix("\\")
                if continues { piece = String(piece.dropLast()) }
                joined += piece + " "
                cursor += 1
                if !continues { break }
            }
            out.append(tokenize(joined))
            index = cursor
        }
        return out
    }

    static func tokenize(_ command: String) -> [String] {
        command.split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map { raw -> String in
                var token = String(raw)
                for quote in ["'", "\""]
                where token.count >= 2 && token.hasPrefix(quote) && token.hasSuffix(quote) {
                    token = String(token.dropFirst().dropLast())
                    break
                }
                return token
            }
            .filter { !$0.isEmpty }
    }

    /// xcodebuild actions this guard knows by name. Anything else in a command line is a flag, a
    /// flag's value, or a `KEY=value` build setting.
    static let knownActions: Set<String> = [
        "build", "test", "archive", "clean", "analyze", "install", "installsrc",
        "build-for-testing", "test-without-building", "docbuild", "run",
    ]

    /// Flags whose value is a SEPARATE token, so that `-scheme test` names a scheme rather than
    /// requesting a test run.
    ///
    /// This is an allow-list, and deliberately so. The obvious rule — "any token after anything
    /// starting with `-` is a value" — reads `xcodebuild -only-testing:Foo test` as asking for no
    /// action at all, because the flag carries its own value and consumes the next token anyway;
    /// same for boolean flags like `-quiet`. That direction is the dangerous one: it makes the
    /// guard blind to exactly the command it exists to forbid. With an allow-list, a flag nobody
    /// listed can at worst make an action appear that was not asked for, which shows up as a red
    /// check somebody then reads — noisy rather than silent.
    static let valueTakingFlags: Set<String> = [
        "-project", "-workspace", "-scheme", "-target", "-configuration", "-destination",
        "-destination-timeout", "-sdk", "-arch", "-xcconfig", "-derivedDataPath", "-toolchain",
        "-resultBundlePath", "-resultStreamPath", "-testPlan", "-xctestrun", "-archivePath",
        "-exportOptionsPlist", "-exportPath", "-jobs", "-only-testing", "-skip-testing",
        "-only-test-configuration", "-skip-test-configuration", "-parallel-testing-worker-count",
        "-clonedSourcePackagesDirPath", "-packageCachePath",
    ]

    /// The actions a command asks for.
    static func actions(in tokens: [String]) -> Set<String> {
        var out: Set<String> = []
        var previous: String?
        for token in tokens {
            defer { previous = token }
            if token == "xcodebuild" { continue }
            if let previous, valueTakingFlags.contains(previous) { continue }
            if knownActions.contains(token) { out.insert(token) }
        }
        return out
    }

    /// `KEY=value` build settings passed on the command line. The key must look like a build
    /// setting, which is what keeps `platform=macOS` out.
    static func settings(in tokens: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for token in tokens {
            guard let equals = token.firstIndex(of: "=") else { continue }
            let key = String(token[token.startIndex..<equals])
            guard !key.isEmpty,
                  key.allSatisfy({ $0.isUppercase || $0.isNumber || $0 == "_" }) else { continue }
            out[key] = String(token[token.index(after: equals)...])
        }
        return out
    }

    static func value(after flag: String, in tokens: [String]) -> String? {
        guard let index = tokens.firstIndex(of: flag), index + 1 < tokens.count else { return nil }
        return tokens[index + 1]
    }

    // MARK: - Structure: jobs and steps

    static func isTopLevelKey(_ line: String) -> Bool {
        guard let first = line.first, first != " ", first != "#" else { return false }
        return line.contains(":")
    }

    /// The body of the top-level `jobs:` mapping. Isolating it first is what stops the two-space
    /// keys under `on:` (`push`, `pull_request`, `workflow_dispatch`) from reading as jobs.
    static func jobsSection(in yaml: String) -> String {
        let lines = yaml.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "jobs:"
                                                    && $0.hasPrefix("jobs:") }) else { return "" }
        var end = lines.count
        for index in (start + 1)..<lines.count where isTopLevelKey(lines[index]) {
            end = index
            break
        }
        return lines[(start + 1)..<end].joined(separator: "\n")
    }

    /// `  job-key:` — exactly two spaces of indent and nothing after the colon.
    static func jobKey(_ line: String) -> String? {
        guard line.hasPrefix("  "), !line.hasPrefix("   ") else { return nil }
        let body = line.dropFirst(2)
        guard body.hasSuffix(":") else { return nil }
        let name = String(body.dropLast())
        guard !name.isEmpty,
              name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            return nil
        }
        return name
    }

    static func jobBlocks(in yaml: String) -> [(key: String, body: String)] {
        let lines = jobsSection(in: yaml)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var out: [(key: String, body: String)] = []
        var current: String?
        var buffer: [String] = []
        for line in lines {
            if let key = jobKey(line) {
                if let current { out.append((current, buffer.joined(separator: "\n"))) }
                current = key
                buffer = []
            } else if current != nil {
                buffer.append(line)
            }
        }
        if let current { out.append((current, buffer.joined(separator: "\n"))) }
        return out
    }

    /// The `name:` a job declares — the string GitHub reports the check under.
    static func declaredName(ofJob body: String) -> String? {
        for line in body.split(separator: "\n", omittingEmptySubsequences: false)
        where line.hasPrefix("    name:") && !line.hasPrefix("     ") {
            return String(line.dropFirst("    name:".count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    static func isStepStart(_ line: String) -> Bool { line.hasPrefix("      - ") }

    static func stepBlocks(in jobBody: String) -> [(name: String, text: String)] {
        let lines = jobBody.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var out: [(name: String, text: String)] = []
        var buffer: [String] = []
        var started = false
        func flush() {
            guard started else { return }
            let text = buffer.joined(separator: "\n")
            out.append((stepName(in: text), text))
        }
        for line in lines {
            if isStepStart(line) {
                flush()
                started = true
                buffer = [line]
            } else if started {
                buffer.append(line)
            }
        }
        flush()
        return out
    }

    static func stepName(in text: String) -> String {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            for prefix in ["- name:", "- uses:"] where trimmed.hasPrefix(prefix) {
                return String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return "<unnamed step>"
    }

    // MARK: - Invocations

    struct Invocation {
        let job: String
        let step: String
        let tokens: [String]

        var configuration: String? {
            ReleaseCompileGateGuardTests.value(after: "-configuration", in: tokens)
        }
        var actions: Set<String> { ReleaseCompileGateGuardTests.actions(in: tokens) }
        var settings: [String: String] { ReleaseCompileGateGuardTests.settings(in: tokens) }
        /// An invocation that asks for no action at all is not a build — `xcodebuild -version`.
        var isBuild: Bool { !actions.isEmpty }
        var label: String { "\(job) ▸ \(step)" }
    }

    static func invocations(in yaml: String) -> [Invocation] {
        jobBlocks(in: yaml).flatMap { job in
            stepBlocks(in: job.body).flatMap { step in
                xcodebuildCommands(in: step.text).map {
                    Invocation(job: job.key, step: step.name, tokens: $0)
                }
            }
        }
    }

    static func buildInvocations(in yaml: String) -> [Invocation] {
        invocations(in: yaml).filter(\.isBuild)
    }

    /// Lines that would filter a job or the workflow by path.
    static func pathFilterLines(in yaml: String) -> [String] {
        yaml.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("paths:") || $0.hasPrefix("paths-ignore:") }
    }

    // MARK: - The scanner is not a no-op, measured on the real file

    func testTheScannerFindsTheRealJobsAndInventsNone() throws {
        let jobs = Self.jobBlocks(in: try Self.workflowText())
        XCTAssertEqual(jobs.map(\.key).sorted(), Self.expectedJobKeys, """
            the set of jobs in \(Self.workflowPath) changed. Every assertion below reads one of \
            them by key, so a rename or an addition has to be looked at here.
            """)
        for notAJob in ["push", "pull_request", "workflow_dispatch", "concurrency"] {
            XCTAssertFalse(jobs.contains { $0.key == notAJob }, """
                "\(notAJob)" was read as a job. It is a two-space key outside `jobs:`; a scanner \
                that cannot tell them apart would happily "find" a Release gate in the trigger \
                block.
                """)
        }
    }

    func testTheScannerFindsTheRealStepsAndTheVersionStepAsksForNoAction() throws {
        let yaml = try Self.workflowText()
        let job = try XCTUnwrap(Self.jobBlocks(in: yaml).first { $0.key == Self.gateJobKey })
        let steps = Self.stepBlocks(in: job.body)
        XCTAssertTrue(steps.contains { $0.name == "actions/checkout@v4" },
                      "parsed steps: \(steps.map(\.name))")
        XCTAssertTrue(steps.contains { $0.name == "Xcode version" },
                      "parsed steps: \(steps.map(\.name))")

        let all = Self.invocations(in: yaml).filter { $0.job == Self.gateJobKey }
        let versionCheck = try XCTUnwrap(all.first { $0.step == "Xcode version" }, """
            `xcodebuild -version` was not found. A scanner that misses a one-line `run:` command \
            would also miss a one-line `xcodebuild test`.
            """)
        XCTAssertEqual(versionCheck.actions, [], """
            `xcodebuild -version` was read as asking for \(versionCheck.actions.sorted()). It \
            asks for no action, and the configuration assertions below apply only to commands \
            that do.
            """)
        XCTAssertEqual(all.filter(\.isBuild).count, 3, """
            expected exactly three building xcodebuild commands in \(Self.gateJobKey) — Debug \
            build, Debug test, Release gate — found \
            \(all.filter(\.isBuild).map { "\($0.step) \($0.actions.sorted())" }).
            """)
    }

    // MARK: - (a) the gate exists

    func testTheGateJobIsStillTheOneTheRequiredCheckNames() throws {
        let yaml = try Self.workflowText()
        let job = try XCTUnwrap(Self.jobBlocks(in: yaml).first { $0.key == Self.gateJobKey }, """
            the `\(Self.gateJobKey)` job is gone. The Release compile gate lives inside it \
            precisely so that no new required check has to be configured (decision D10).
            """)
        XCTAssertEqual(Self.declaredName(ofJob: job.body), Self.requiredCheckName, """
            the job's `name:` changed. That string IS the required status check configured on \
            `main`; a renamed job never reports under the old name, so the check sits as \
            "Expected" and blocks every pull request permanently — including the one that \
            renamed it. Rename only by taking the check out of the required list first, and put \
            it back after the new name has reported on main.
            """)
    }

    func testTheGateJobCompilesTheReleaseConfiguration() throws {
        let yaml = try Self.workflowText()
        let release = Self.buildInvocations(in: yaml)
            .filter { $0.job == Self.gateJobKey && $0.configuration == "Release" }
        XCTAssertEqual(release.count, 1, """
            expected exactly one Release-configuration xcodebuild command in \
            \(Self.gateJobKey); found \(release.map(\.label)). Without it nothing in this \
            repository compiles Release, and a Release-only compile error would first appear \
            during an App Store archive.
            """)
        let gate = try XCTUnwrap(release.first)
        XCTAssertEqual(gate.actions, ["build"], """
            the Release command asks for \(gate.actions.sorted()); a compile gate builds and \
            does nothing else.
            """)
        XCTAssertEqual(Self.value(after: "-project", in: gate.tokens), Self.gateProject, """
            the Release command does not build \(Self.gateProject). A Release build of something \
            else satisfies the letter of this gate and covers none of the app.
            """)
        XCTAssertEqual(Self.value(after: "-scheme", in: gate.tokens), Self.gateScheme,
                       "the Release command does not build the \(Self.gateScheme) scheme")
    }

    func testTheGateDisablesCodeSigningSoItNeedsNoCertificate() throws {
        let yaml = try Self.workflowText()
        let gate = try XCTUnwrap(Self.buildInvocations(in: yaml)
            .first { $0.job == Self.gateJobKey && $0.configuration == "Release" })
        XCTAssertEqual(gate.settings["CODE_SIGNING_ALLOWED"], "NO", """
            the Release gate no longer passes CODE_SIGNING_ALLOWED=NO. Release signs with \
            `Apple Distribution` and a manual provisioning profile (2c-5) and a runner has \
            neither, so the gate would go red for a reason that has nothing to do with the code \
            — and the cheapest way to make it green again is to put a distribution certificate \
            on CI, which is not something this round wants to invite.
            """)
    }

    // MARK: - (b) the gate must not grow past compiling

    func testNoReleaseCommandAnywhereRunsTestsOrArchives() throws {
        for invocation in Self.buildInvocations(in: try Self.workflowText())
        where invocation.configuration == "Release" {
            XCTAssertEqual(invocation.actions, ["build"], """
                \(invocation.label) runs \(invocation.actions.sorted()) under Release. Release \
                carries the production bundle id com.alotie418.sololedger, so anything launched \
                from it resolves Application Support into the real container shared with the \
                Electron MAS line — app-hosted tests would run against live user data. \
                `archive` is excluded too: it needs the certificates and profile that \
                scripts/archive-mas.sh demands, and archiving is a separately authorised step.
                """)
            XCTAssertNil(invocation.tokens.first { $0.hasPrefix("-only-testing") }, """
                \(invocation.label) carries an -only-testing argument under Release, which only \
                makes sense for a test run.
                """)
        }
    }

    func testEveryCommandThatRunsTheProductStaysOnDebug() throws {
        let running = Self.buildInvocations(in: try Self.workflowText())
            .filter { !$0.actions.isDisjoint(with: Self.actionsThatRunTheProduct) }
        XCTAssertFalse(running.isEmpty, """
            no command in the workflow runs anything — the App-hosted unit tests step should \
            have been found, so this assertion is not testing what it claims to.
            """)
        for invocation in running {
            XCTAssertEqual(invocation.configuration, "Debug", """
                \(invocation.label) runs \(invocation.actions.sorted()) under \
                \(invocation.configuration ?? "the scheme's default") instead of Debug. This is \
                the trade this round must not make: adding a Release gate and then "unifying" \
                the test step onto Release would point the app-hosted tests at the production \
                container. Debug's .dev bundle id keeps them in an isolated preview container.
                """)
        }
    }

    func testNothingInTheWorkflowArchives() throws {
        let archiving = Self.buildInvocations(in: try Self.workflowText())
            .filter { $0.actions.contains("archive") }
        XCTAssertEqual(archiving.map(\.label), [], """
            CI archives. No archive has ever been produced from this repository; doing it needs \
            the Team ID, the distribution certificate and the provisioning profile, and it is a \
            separately authorised step (native/SoloLedger/scripts/archive-mas.sh).
            """)
    }

    func testEveryBuildingCommandStatesItsConfiguration() throws {
        for invocation in Self.buildInvocations(in: try Self.workflowText()) {
            XCTAssertNotNil(invocation.configuration, """
                \(invocation.label) passes no -configuration, so it silently follows whatever \
                the shared scheme says for that action. The scheme's actions are pinned to \
                different configurations on purpose (Archive Release, Test/Launch Debug — see \
                SchemeConfigurationGuardTests), so an unstated configuration means this \
                command's meaning changes the next time the scheme does.
                """)
        }
    }

    // MARK: - The gate only gates if it runs

    func testTheWorkflowFiltersNothingByPath() throws {
        XCTAssertEqual(Self.pathFilterLines(in: try Self.workflowText()), [], """
            \(Self.workflowPath) gained a path filter. A required check that is filtered out \
            does not report as skipped — it does not report at all, so it stays "Expected" and \
            blocks every pull request. The Release gate is only a gate if it runs on all of them.
            """)
    }

    // MARK: - Fail-closed

    func testAnUnreadableWorkflowYieldsNothingRatherThanSilentAgreement() {
        XCTAssertEqual(Self.jobBlocks(in: "").count, 0)
        XCTAssertEqual(Self.buildInvocations(in: "").count, 0)
        // Which is what makes the "exactly one Release command" assertion fail rather than pass.
        XCTAssertNotEqual(Self.buildInvocations(in: "")
            .filter { $0.configuration == "Release" }.count, 1)
    }

    // MARK: - Reverse proof: each defect shape, on synthetic workflow text

    static func fixture(jobName: String = ReleaseCompileGateGuardTests.requiredCheckName,
                        testConfiguration: String = "Debug",
                        includeGate: Bool = true,
                        gateConfiguration: String = "Release",
                        gateActions: String = "build",
                        gateSigningOptOut: Bool = true) -> String {
        var out = "jobs:\n"
        out += "  native-app:\n"
        out += "    name: \(jobName)\n"
        out += "    runs-on: macos-latest\n"
        out += "    steps:\n"
        out += "      - uses: actions/checkout@v4\n"
        out += "      - name: Xcode version\n"
        out += "        run: xcodebuild -version\n"
        out += "      - name: Build the real SwiftUI app\n"
        out += "        run: |\n"
        out += "          xcodebuild \\\n"
        out += "            -project \(gateProject) \\\n"
        out += "            -scheme \(gateScheme) \\\n"
        out += "            -configuration Debug \\\n"
        out += "            -destination 'platform=macOS' \\\n"
        out += "            build\n"
        out += "      - name: App-hosted unit tests\n"
        out += "        run: |\n"
        out += "          xcodebuild test \\\n"
        out += "            -project \(gateProject) \\\n"
        out += "            -scheme \(gateScheme) \\\n"
        out += "            -configuration \(testConfiguration) \\\n"
        out += "            -destination 'platform=macOS' \\\n"
        out += "            -only-testing:SoloLedgerUnitTests\n"
        if includeGate {
            out += "      - name: Release-configuration compile gate\n"
            out += "        run: |\n"
            out += "          xcodebuild \\\n"
            out += "            -project \(gateProject) \\\n"
            out += "            -scheme \(gateScheme) \\\n"
            out += "            -configuration \(gateConfiguration) \\\n"
            out += "            -destination 'generic/platform=macOS' \\\n"
            if gateSigningOptOut { out += "            CODE_SIGNING_ALLOWED=NO \\\n" }
            out += "            \(gateActions)\n"
        }
        return out
    }

    /// The fixture at the pinned shape reads exactly as the real file does, or the counterexamples
    /// below would prove nothing.
    func testTheFixtureAtThePinnedShapeIsClean() {
        let yaml = Self.fixture()
        let builds = Self.buildInvocations(in: yaml)
        XCTAssertEqual(builds.count, 3)
        XCTAssertTrue(builds.allSatisfy { $0.configuration != nil })

        let release = builds.filter { $0.configuration == "Release" }
        XCTAssertEqual(release.count, 1)
        XCTAssertEqual(release.first?.actions, ["build"])
        XCTAssertEqual(release.first?.settings["CODE_SIGNING_ALLOWED"], "NO")

        let running = builds.filter { !$0.actions.isDisjoint(with: Self.actionsThatRunTheProduct) }
        XCTAssertEqual(running.count, 1)
        XCTAssertEqual(running.first?.configuration, "Debug")

        XCTAssertEqual(Self.declaredName(ofJob: Self.jobBlocks(in: yaml)[0].body),
                       Self.requiredCheckName)
        XCTAssertEqual(Self.pathFilterLines(in: yaml), [])
    }

    /// (a) The state this round leaves behind: no Release command at all.
    func testAWorkflowWithoutTheGateIsReported() {
        let builds = Self.buildInvocations(in: Self.fixture(includeGate: false))
        XCTAssertEqual(builds.filter { $0.configuration == "Release" }.count, 0,
                       "a workflow with no Release command must not read as gated")
        XCTAssertEqual(builds.count, 2, "…and the two Debug commands are still seen")
    }

    /// (a′) A gate that stops being a Release gate — the same silence, dressed up.
    func testAGateQuietlyMovedBackToDebugIsReported() {
        let builds = Self.buildInvocations(in: Self.fixture(gateConfiguration: "Debug"))
        XCTAssertEqual(builds.filter { $0.configuration == "Release" }.count, 0)
        XCTAssertEqual(builds.count, 3, "the command is still there; only its configuration moved")
    }

    /// (b) The trade this round must not make, in its two shapes.
    func testAReleaseCommandThatAlsoTestsIsReported() {
        let builds = Self.buildInvocations(in: Self.fixture(gateActions: "build test"))
        let release = builds.filter { $0.configuration == "Release" }
        XCTAssertEqual(release.count, 1)
        XCTAssertEqual(release.first?.actions, ["build", "test"],
                       "appending `test` to the gate must be visible, not absorbed")
        XCTAssertNotEqual(release.first?.actions, ["build"])
    }

    func testATestCommandPromotedToReleaseIsReported() {
        let builds = Self.buildInvocations(in: Self.fixture(testConfiguration: "Release"))
        let running = builds.filter { !$0.actions.isDisjoint(with: Self.actionsThatRunTheProduct) }
        XCTAssertEqual(running.count, 1)
        XCTAssertEqual(running.first?.configuration, "Release",
                       "the promotion must be seen for what it is")
        XCTAssertNotEqual(running.first?.configuration, "Debug")
        // …and this shape also breaks the Release-is-build-only rule, from the other side.
        XCTAssertEqual(builds.filter { $0.configuration == "Release" }
            .filter { $0.actions != ["build"] }.count, 1)
    }

    func testAnArchivingCommandIsReported() {
        let builds = Self.buildInvocations(in: Self.fixture(gateActions: "archive"))
        XCTAssertEqual(builds.filter { $0.actions.contains("archive") }.count, 1)
    }

    /// (c) The gate without its signing opt-out: green here would mean the guard cannot tell the
    /// difference between "needs no certificate" and "needs one nobody has".
    func testAGateWithoutTheSigningOptOutIsReported() throws {
        let builds = Self.buildInvocations(in: Self.fixture(gateSigningOptOut: false))
        let release = try XCTUnwrap(builds.first { $0.configuration == "Release" })
        XCTAssertNil(release.settings["CODE_SIGNING_ALLOWED"])
        XCTAssertEqual(release.actions, ["build"], "…while everything else about it is fine")
    }

    /// (d) The rename that would silently unhook the required check.
    func testARenamedJobIsReported() {
        let yaml = Self.fixture(jobName: "Native SwiftUI app")
        XCTAssertNotEqual(Self.declaredName(ofJob: Self.jobBlocks(in: yaml)[0].body),
                          Self.requiredCheckName)
    }

    /// (e) A path filter, which turns the gate off without deleting it.
    func testAPathFilterIsReported() {
        let filtered = """
        on:
          pull_request:
            paths:
              - 'native/**'
        """
        XCTAssertEqual(Self.pathFilterLines(in: filtered), ["paths:"])
        XCTAssertEqual(Self.pathFilterLines(in: "        paths-ignore:\n"), ["paths-ignore:"])
        // A comment that merely mentions one is not one — ci.yml's own prose says `paths:`.
        XCTAssertEqual(Self.pathFilterLines(in: "      # NO paths: filtering, on purpose"), [])
    }

    // MARK: - The token scanner, proven against the shapes that would fool it

    func testTheActionScannerDoesNotMistakeFlagValuesForActions() {
        XCTAssertEqual(Self.actions(in: Self.tokenize("xcodebuild -scheme test build")), ["build"])
        XCTAssertEqual(Self.actions(in: Self.tokenize("xcodebuild -scheme archive -configuration Release build")),
                       ["build"])
        XCTAssertEqual(Self.actions(in: Self.tokenize("xcodebuild -version")), [])
        XCTAssertEqual(Self.actions(in: Self.tokenize("xcodebuild build test")), ["build", "test"])
        // The action may precede or follow the flags; both forms must read the same.
        XCTAssertEqual(Self.actions(in: Self.tokenize("xcodebuild test -configuration Debug")), ["test"])
        XCTAssertEqual(Self.actions(in: Self.tokenize("xcodebuild -configuration Debug test")), ["test"])
        // `-only-testing:Foo` is one token and is not the `test` action.
        XCTAssertEqual(Self.actions(in: Self.tokenize("xcodebuild -only-testing:Foo build")), ["build"])
        // …and, the direction that matters, a flag carrying its own value must not swallow the
        // action that follows it. Both of these ask for a test run and must read as one.
        XCTAssertEqual(Self.actions(in: Self.tokenize("xcodebuild -only-testing:Foo test")), ["test"])
        XCTAssertEqual(Self.actions(in: Self.tokenize("xcodebuild -quiet test")), ["test"])
        // The separate-token form of the same flag still shields its value.
        XCTAssertEqual(Self.actions(in: Self.tokenize("xcodebuild -only-testing build")), [])
    }

    func testTheSettingScannerSeparatesBuildSettingsFromDestinations() {
        let tokens = Self.tokenize(
            "xcodebuild -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build")
        XCTAssertEqual(Self.settings(in: tokens), ["CODE_SIGNING_ALLOWED": "NO"], """
            `platform=macOS` is a destination specifier, not a build setting; a scanner that \
            cannot tell them apart would accept a destination as proof that signing is off.
            """)
        XCTAssertEqual(Self.value(after: "-destination", in: tokens), "generic/platform=macOS",
                       "quotes around a whole token are stripped")
    }

    func testTheCommandScannerReadsBothOneLinersAndContinuedCommands() {
        let oneLiner = Self.xcodebuildCommands(in: "        run: xcodebuild -version")
        XCTAssertEqual(oneLiner.count, 1)
        XCTAssertEqual(oneLiner.first, ["xcodebuild", "-version"])

        let continued = Self.xcodebuildCommands(in: """
                  xcodebuild \\
                    -configuration Release \\
                    build
            """)
        XCTAssertEqual(continued.count, 1)
        XCTAssertEqual(continued.first, ["xcodebuild", "-configuration", "Release", "build"])

        XCTAssertEqual(Self.xcodebuildCommands(in: "      # xcodebuild test -configuration Release"),
                       [], "a comment is not a command")
        XCTAssertEqual(Self.xcodebuildCommands(in: "        run: swift test --package-path native"),
                       [], "only xcodebuild commands are in scope")
    }
}
