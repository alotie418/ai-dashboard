import XCTest

/// 2c-2 — `project.pbxproj` is the truth source for the App targets, and this file is what
/// holds it to the disk.
///
/// ## The failure this exists to catch
///
/// The App targets are NOT globbed. `Package.swift` leaves `Sources/SoloLedger/**` out of every
/// SwiftPM target; those files reach a build only through `SoloLedger.xcodeproj`, where each one
/// is registered BY HAND in exactly four places — a `PBXFileReference`, a `PBXBuildFile`, an
/// entry in its group's `children`, and an entry in the target's `PBXSourcesBuildPhase.files`.
///
/// Miss any of them and **nothing reports it**. The file sits on disk, `git` shows it, the
/// review shows it, the build stays green — and the code simply is not compiled. For a test
/// file the symptom is that the test count does not move; for a production file it is a symbol
/// that mysteriously will not resolve. That silence is the whole reason this guard exists:
/// every other check in this repository runs on code that was compiled.
///
/// Until 2c-2 there was a second, worse hazard layered on top: `App/project.yml`, an XcodeGen
/// spec that LOOKED like the source of truth. Nothing read it at build time, `xcodegen` was
/// forbidden (running it reissues object IDs even with zero source changes), and it stayed
/// correct only by luck — every file added since 2026-07-20 happened to land in a directory it
/// already globbed. It was deleted; this guard is what replaces it, and unlike the spec it
/// fails when it is wrong.
///
/// ## Why the comparisons are name-based
///
/// Every `.swift` basename is unique within each target's directory —
/// ``testEachTargetDirectoryHasUniqueSwiftBasenames`` pins that precondition rather than
/// assuming it, so if a future `Models/Row.swift` ever collides with `Views/Row.swift` this
/// method's assumption fails LOUDLY instead of silently comparing the wrong things.
///
/// ## Why the comparators are pure
///
/// Same reason as ``AppTargetBypassGuardTests``: a guard whose only input is the real file can
/// only ever be observed passing. Each defect shape below is reproduced against synthetic
/// pbxproj text and a synthetic disk listing, so "this check is not a no-op" is measured, not
/// asserted in a comment.
final class AppTargetRegistrationGuardTests: XCTestCase {

    // MARK: - What the project file says

    /// The `.swift` populations of the four places a registration has to appear.
    struct Registration: Equatable {
        /// Declared files (`PBXFileReference`).
        var fileReferences: Set<String> = []
        /// Compile wirings (`PBXBuildFile`, the `… in Sources` ones).
        var buildFiles: Set<String> = []
        /// Everything named in some `PBXGroup.children` — i.e. visible in the navigator.
        var groupChildren: Set<String> = []
        /// Per native target: what its `PBXSourcesBuildPhase` actually compiles.
        var sourcesByTarget: [String: Set<String>] = [:]

        var allCompiled: Set<String> { sourcesByTarget.values.reduce(into: []) { $0.formUnion($1) } }
    }

    /// The three targets the Xcode project builds, and the directory each one owns.
    /// `SoloLedgerCoreTests` is deliberately absent: Core is a SwiftPM target, globbed by
    /// `Package.swift`, and its files are not registered here at all.
    static let targetDirectories: [(target: String, directory: String)] = [
        ("SoloLedger", "Sources/SoloLedger"),
        ("SoloLedgerUnitTests", "App/Tests/SoloLedgerUnitTests"),
        ("SoloLedgerUITests", "App/Tests/SoloLedgerUITests"),
    ]

    // MARK: - Parsing, as a pure function over the project text

    /// The text between `/* Begin <name> section */` and its `End`. Empty when absent, which
    /// every caller turns into a visible failure rather than a silently empty set.
    static func section(_ name: String, of text: String) -> [Substring] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let begin = lines.firstIndex(where: { $0.contains("/* Begin \(name) section */") }),
              let end = lines.firstIndex(where: { $0.contains("/* End \(name) section */") }),
              begin < end
        else { return [] }
        return Array(lines[(begin + 1)..<end])
    }

    /// The FIRST `/* … */` comment on a line. pbxproj puts the human-readable name there, and
    /// on a `PBXBuildFile` line the first one is the wiring (`Foo.swift in Sources`) while the
    /// second is the plain file — taking the first is what distinguishes them.
    static func firstComment(in line: Substring) -> String? {
        guard let open = line.range(of: "/* "),
              let close = line.range(of: " */", range: open.upperBound..<line.endIndex)
        else { return nil }
        return String(line[open.upperBound..<close.lowerBound])
    }

    static func parse(_ text: String) -> Registration {
        var out = Registration()

        for line in section("PBXFileReference", of: text) {
            if let name = firstComment(in: line), name.hasSuffix(".swift") {
                out.fileReferences.insert(name)
            }
        }

        for line in section("PBXBuildFile", of: text) {
            guard let name = firstComment(in: line), name.hasSuffix(" in Sources") else { continue }
            let file = String(name.dropLast(" in Sources".count))
            if file.hasSuffix(".swift") { out.buildFiles.insert(file) }
        }

        for line in section("PBXGroup", of: text) {
            // A children entry is `\t\t\t\tID /* Name */,` — the trailing comma is what separates
            // it from the group's own header line, which ends in ` = {`.
            guard line.hasSuffix(",") , let name = firstComment(in: line), name.hasSuffix(".swift")
            else { continue }
            out.groupChildren.insert(name)
        }

        // Sources phases are keyed by object id; native targets name them. Read both, then join.
        var filesByPhase: [String: Set<String>] = [:]
        var currentPhase: String?
        for line in section("PBXSourcesBuildPhase", of: text) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix("= {"), let id = trimmed.split(separator: " ").first {
                currentPhase = String(id)
                filesByPhase[String(id)] = []
                continue
            }
            if trimmed == "};" { currentPhase = nil; continue }
            guard let phase = currentPhase, line.hasSuffix(","),
                  let name = firstComment(in: line), name.hasSuffix(".swift in Sources")
            else { continue }
            filesByPhase[phase, default: []].insert(String(name.dropLast(" in Sources".count)))
        }

        var currentTargetPhases: [String] = []
        var inBuildPhases = false
        for line in section("PBXNativeTarget", of: text) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "buildPhases = (" { inBuildPhases = true; continue }
            if inBuildPhases {
                if trimmed == ");" { inBuildPhases = false; continue }
                if firstComment(in: line) == "Sources", let id = trimmed.split(separator: " ").first {
                    currentTargetPhases.append(String(id))
                }
                continue
            }
            if trimmed.hasPrefix("name = "), trimmed.hasSuffix(";") {
                let name = String(trimmed.dropFirst("name = ".count).dropLast())
                let compiled = currentTargetPhases.reduce(into: Set<String>()) {
                    $0.formUnion(filesByPhase[$1] ?? [])
                }
                out.sourcesByTarget[name] = compiled
                currentTargetPhases = []
            }
        }

        return out
    }

    // MARK: - The two comparators, pure

    struct Drift: Equatable, CustomStringConvertible {
        /// On disk, compiled by nobody — the silent one.
        var unregistered: [String] = []
        /// Registered, but no such file — a build break waiting for a clean checkout.
        var phantom: [String] = []
        var isEmpty: Bool { unregistered.isEmpty && phantom.isEmpty }
        var description: String {
            "unregistered=\(unregistered) phantom=\(phantom)"
        }
    }

    /// Family (a): disk ↔ pbxproj, BOTH directions. One direction alone is half a guard —
    /// `disk ⊆ phase` misses a stale entry, `phase ⊆ disk` misses the forgotten registration.
    static func drift(disk: Set<String>, compiled: Set<String>) -> Drift {
        Drift(unregistered: disk.subtracting(compiled).sorted(),
              phantom: compiled.subtracting(disk).sorted())
    }

    /// Family (b): what the navigator shows ↔ what the compiler is given. These are different
    /// pbxproj sections (`children` holds `PBXFileReference` ids, `files` holds `PBXBuildFile`
    /// ids), which is exactly why two of the four lines can be written and two forgotten.
    static func groupPhaseDrift(_ r: Registration) -> Drift {
        Drift(unregistered: r.groupChildren.subtracting(r.allCompiled).sorted(),
              phantom: r.allCompiled.subtracting(r.groupChildren).sorted())
    }

    // MARK: - Reading the real project + disk

    /// …/native/SoloLedger/Tests/SoloLedgerCoreTests/<this>.swift → …/native/SoloLedger
    static func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    static func projectText() throws -> String {
        try String(contentsOf: packageRoot()
            .appendingPathComponent("App/SoloLedger.xcodeproj/project.pbxproj"), encoding: .utf8)
    }

    /// Basenames of every `.swift` under `directory`, recursively.
    static func swiftBasenames(under directory: String) throws -> [String] {
        let root = packageRoot().appendingPathComponent(directory, isDirectory: true)
        let walker = try XCTUnwrap(FileManager.default.enumerator(atPath: root.path),
                                   "cannot enumerate \(directory)")
        var out: [String] = []
        for case let relative as String in walker where relative.hasSuffix(".swift") {
            out.append((relative as NSString).lastPathComponent)
        }
        return out
    }

    // MARK: - Preconditions of the method itself

    func testEachTargetDirectoryHasUniqueSwiftBasenames() throws {
        for (target, directory) in Self.targetDirectories {
            let names = try Self.swiftBasenames(under: directory)
            XCTAssertGreaterThan(names.count, 1, "\(directory) looks empty — the scan is broken")
            XCTAssertEqual(names.count, Set(names).count, """
                \(target): two files under \(directory) share a basename \
                (\(Dictionary(grouping: names, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted())). \
                Name-based comparison is no longer sound here — teach this guard full paths \
                before adding such a file.
                """)
        }
    }

    func testTheProjectFileParsesIntoNonEmptySections() throws {
        let r = Self.parse(try Self.projectText())
        XCTAssertGreaterThan(r.fileReferences.count, 40, "PBXFileReference scan came back empty")
        XCTAssertGreaterThan(r.buildFiles.count, 40, "PBXBuildFile scan came back empty")
        XCTAssertGreaterThan(r.groupChildren.count, 40, "PBXGroup scan came back empty")
        XCTAssertEqual(Set(r.sourcesByTarget.keys), Set(Self.targetDirectories.map(\.target)),
                       "the project no longer has exactly the three expected native targets")
    }

    // MARK: - Family (a): disk ↔ pbxproj, both directions

    func testEverySwiftFileOnDiskIsCompiledByItsTargetAndViceVersa() throws {
        let r = Self.parse(try Self.projectText())
        for (target, directory) in Self.targetDirectories {
            let disk = Set(try Self.swiftBasenames(under: directory))
            let compiled = try XCTUnwrap(r.sourcesByTarget[target], "no Sources phase for \(target)")
            let d = Self.drift(disk: disk, compiled: compiled)
            XCTAssertTrue(d.isEmpty, """
                \(target) (\(directory)) is out of step with project.pbxproj.
                On disk but compiled by nobody: \(d.unregistered) — add the four lines \
                (PBXFileReference, PBXBuildFile, group children, Sources phase); until then the \
                file is not built and NOTHING else will tell you.
                Registered but absent from disk: \(d.phantom) — a stale entry that breaks a \
                clean checkout.
                """)
        }
    }

    // MARK: - Family (b): navigator ↔ compiler, and the four-line rule

    func testGroupChildrenAndSourcesPhasesNameTheSameFiles() throws {
        let d = Self.groupPhaseDrift(Self.parse(try Self.projectText()))
        XCTAssertTrue(d.isEmpty, """
            project.pbxproj disagrees with itself.
            In a group but in no Sources phase: \(d.unregistered) — visible in Xcode's \
            navigator, never compiled. This is the shape that looks most like success.
            In a Sources phase but in no group: \(d.phantom) — compiled but invisible to anyone \
            reading the project.
            """)
    }

    /// The "exactly four lines per file" rule, machine-checked. `PBXFileReference` ↔ group
    /// children and `PBXBuildFile` ↔ Sources phase are the two id-level pairings the previous
    /// test's name-level comparison rides on; pinning them means a half-written registration
    /// cannot pass by being half-written in both places at once.
    func testEveryRegisteredSwiftFileHasAllFourLines() throws {
        let r = Self.parse(try Self.projectText())
        XCTAssertEqual(r.fileReferences.sorted(), r.groupChildren.sorted(), """
            declared files and group children disagree: \
            declared-not-grouped=\(r.fileReferences.subtracting(r.groupChildren).sorted()), \
            grouped-not-declared=\(r.groupChildren.subtracting(r.fileReferences).sorted())
            """)
        XCTAssertEqual(r.buildFiles.sorted(), r.allCompiled.sorted(), """
            compile wirings and Sources phases disagree: \
            wired-not-compiled=\(r.buildFiles.subtracting(r.allCompiled).sorted()), \
            compiled-not-wired=\(r.allCompiled.subtracting(r.buildFiles).sorted())
            """)
    }

    // MARK: - Counterexamples: the scanners are not no-ops

    /// The icon-name lesson: a scan that reports "no problems" over a corpus it cannot actually
    /// read reports exactly the same thing as a scan over a clean one. So: a name that IS there
    /// must be found, and one that is not must be missed, in every population.
    func testTheScannerFindsAKnownFileAndMissesAnInventedOne() throws {
        let r = Self.parse(try Self.projectText())
        let known = "SoloLedgerApp.swift"
        let invented = "ThisFileHasNeverExisted.swift"
        XCTAssertTrue(r.fileReferences.contains(known))
        XCTAssertTrue(r.buildFiles.contains(known))
        XCTAssertTrue(r.groupChildren.contains(known))
        XCTAssertTrue(r.sourcesByTarget["SoloLedger"]?.contains(known) == true)
        for population in [r.fileReferences, r.buildFiles, r.groupChildren, r.allCompiled] {
            XCTAssertFalse(population.contains(invented), "the scanner invents entries")
        }
        // And it must not smear one target's files into another's.
        XCTAssertFalse(r.sourcesByTarget["SoloLedgerUITests"]?.contains(known) == true,
                       "per-target attribution collapsed")
    }

    func testTheDiskScannerFindsAKnownFileAndMissesAnInventedOne() throws {
        let unit = try Self.swiftBasenames(under: "App/Tests/SoloLedgerUnitTests")
        XCTAssertTrue(unit.contains("AboutVersionTests.swift"))
        XCTAssertFalse(unit.contains("ThisFileHasNeverExisted.swift"))
        XCTAssertFalse(unit.contains("SoloLedgerApp.swift"),
                       "the App target's sources leaked into the test directory listing")
    }

    // MARK: - Reverse proof: each defect shape, reproduced

    /// A minimal project with one file wired through all four places, plus knobs to remove
    /// exactly one of them. Synthetic, so no violating file is ever committed.
    static func fixture(fileReference: Bool = true, buildFile: Bool = true,
                        groupChild: Bool = true, phaseEntry: Bool = true,
                        name: String = "Widget.swift") -> String {
        """
        /* Begin PBXBuildFile section */
        \(buildFile ? "\t\tBB1 /* \(name) in Sources */ = {isa = PBXBuildFile; fileRef = FR1 /* \(name) */; };" : "")
        /* End PBXBuildFile section */
        /* Begin PBXFileReference section */
        \(fileReference ? "\t\tFR1 /* \(name) */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = \(name); sourceTree = \"<group>\"; };" : "")
        /* End PBXFileReference section */
        /* Begin PBXGroup section */
        \t\tG1 /* App */ = {
        \t\t\tisa = PBXGroup;
        \t\t\tchildren = (
        \(groupChild ? "\t\t\t\tFR1 /* \(name) */," : "")
        \t\t\t);
        \t\t\tpath = App;
        \t\t};
        /* End PBXGroup section */
        /* Begin PBXNativeTarget section */
        \t\tT1 /* SoloLedger */ = {
        \t\t\tisa = PBXNativeTarget;
        \t\t\tbuildPhases = (
        \t\t\t\tP1 /* Sources */,
        \t\t\t);
        \t\t\tname = SoloLedger;
        \t\t};
        /* End PBXNativeTarget section */
        /* Begin PBXSourcesBuildPhase section */
        \t\tP1 /* Sources */ = {
        \t\t\tisa = PBXSourcesBuildPhase;
        \t\t\tfiles = (
        \(phaseEntry ? "\t\t\t\tBB1 /* \(name) in Sources */," : "")
        \t\t\t);
        \t\t};
        /* End PBXSourcesBuildPhase section */
        """
    }

    func testFixtureWithAllFourLinesIsClean() {
        let r = Self.parse(Self.fixture())
        XCTAssertEqual(r.sourcesByTarget["SoloLedger"], ["Widget.swift"])
        XCTAssertTrue(Self.groupPhaseDrift(r).isEmpty)
        XCTAssertTrue(Self.drift(disk: ["Widget.swift"], compiled: r.allCompiled).isEmpty)
        XCTAssertEqual(r.fileReferences, r.groupChildren)
        XCTAssertEqual(r.buildFiles, r.allCompiled)
    }

    /// (a) The forgotten registration — the file exists, nothing compiles it.
    func testAFileOnDiskThatNoPhaseCompilesIsReported() {
        let r = Self.parse(Self.fixture(buildFile: false, phaseEntry: false))
        let d = Self.drift(disk: ["Widget.swift"], compiled: r.sourcesByTarget["SoloLedger"] ?? [])
        XCTAssertEqual(d.unregistered, ["Widget.swift"])
        XCTAssertEqual(d.phantom, [])
    }

    /// (a) The stale entry — registered, but the file is gone.
    func testAPhaseEntryWithNoFileOnDiskIsReported() {
        let r = Self.parse(Self.fixture())
        let d = Self.drift(disk: [], compiled: r.sourcesByTarget["SoloLedger"] ?? [])
        XCTAssertEqual(d.unregistered, [])
        XCTAssertEqual(d.phantom, ["Widget.swift"])
    }

    /// (b) Added to the group, never to the phase — visible in Xcode, never compiled.
    func testAGroupChildWithNoPhaseEntryIsReported() {
        let d = Self.groupPhaseDrift(Self.parse(Self.fixture(buildFile: false, phaseEntry: false)))
        XCTAssertEqual(d.unregistered, ["Widget.swift"])
        XCTAssertEqual(d.phantom, [])
    }

    /// (b) The mirror shape — compiled, but nowhere in the navigator.
    func testAPhaseEntryWithNoGroupChildIsReported() {
        let d = Self.groupPhaseDrift(Self.parse(Self.fixture(groupChild: false)))
        XCTAssertEqual(d.unregistered, [])
        XCTAssertEqual(d.phantom, ["Widget.swift"])
    }

    /// The four-line rule, each half missing in turn.
    func testAMissingFileReferenceOrBuildFileLineIsReported() {
        let noRef = Self.parse(Self.fixture(fileReference: false))
        XCTAssertNotEqual(noRef.fileReferences, noRef.groupChildren,
                          "a missing PBXFileReference must not read as consistent")
        let noWiring = Self.parse(Self.fixture(buildFile: false))
        XCTAssertNotEqual(noWiring.buildFiles, noWiring.allCompiled,
                          "a missing PBXBuildFile must not read as consistent")
    }

    /// The guard must fail loudly on an unreadable project rather than passing over empty sets —
    /// the same fail-closed posture the rest of this package uses.
    func testAnEmptyProjectTextYieldsNothingRatherThanSilentAgreement() {
        let r = Self.parse("")
        XCTAssertTrue(r.fileReferences.isEmpty)
        XCTAssertTrue(r.sourcesByTarget.isEmpty)
        // …which is why the real-file tests assert the populations are large BEFORE comparing.
        XCTAssertEqual(Self.drift(disk: ["A.swift"], compiled: r.allCompiled).unregistered,
                       ["A.swift"], "an empty parse must look like total drift, not agreement")
    }
}
