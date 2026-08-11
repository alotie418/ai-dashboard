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
/// ## The join key is the object ID, never the comment
///
/// pbxproj annotates every reference with a `/* Foo.swift */` comment, and it is tempting to
/// read those and be done. **They are decoration.** Xcode resolves `PBXBuildFile.fileRef` and
/// `children` entries by 24-hex object ID, so a hand edit that copies a line, updates the
/// comment and forgets the `fileRef` produces a project whose comments all agree and whose
/// compiler input is wrong — the new file is never built and some other file is built twice.
/// Measured: a comment-keyed version of this guard passed all fourteen of its own tests against
/// exactly that mutation. Everything below therefore resolves IDs and compares the
/// `PBXFileReference.path` values it lands on; ``testEveryReferenceCommentMatchesItsResolvedPath``
/// then pins the decoration to the meaning, because a lying comment is a trap for the next
/// person editing by hand even when the wiring underneath happens to be right.
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

    // MARK: - What the project file says, after resolving IDs

    struct Registration: Equatable {
        /// Declared files (`PBXFileReference.path`).
        var fileReferences: Set<String> = []
        /// What the `… in Sources` `PBXBuildFile`s resolve to.
        var buildFiles: Set<String> = []
        /// What some `PBXGroup.children` entry resolves to — i.e. visible in the navigator.
        var groupChildren: Set<String> = []
        /// Per native target: what its `PBXSourcesBuildPhase` actually hands the compiler.
        var sourcesByTarget: [String: Set<String>] = [:]

        /// `PBXBuildFile`s whose `fileRef` names no declared reference — Xcode would fail to
        /// open the project, and a comment-keyed reader would never notice.
        var danglingBuildFiles: [String] = []
        /// Target → files its Sources phase compiles more than once.
        var duplicateCompiles: [String: [String]] = [:]
        /// `id: comment ≠ resolved path` — decoration that disagrees with meaning.
        var commentMismatches: [String] = []

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

    /// The object ID a line starts with.
    static func leadingID(of line: Substring) -> String? {
        let token = line.trimmingCharacters(in: .whitespaces)
            .prefix { $0 != " " && $0 != "," }
        let id = String(token)
        return id.count == 24 && id.allSatisfy(\.isHexDigit) ? id : nil
    }

    /// The FIRST `/* … */` comment on a line — the human-readable label, which this guard
    /// treats as a claim to be checked, never as the key to join on.
    static func firstComment(in line: Substring) -> String? {
        guard let open = line.range(of: "/* "),
              let close = line.range(of: " */", range: open.upperBound..<line.endIndex)
        else { return nil }
        return String(line[open.upperBound..<close.lowerBound])
    }

    /// `key = value;` → `value`, unquoted.
    static func setting(_ key: String, in line: Substring) -> String? {
        guard let start = line.range(of: "\(key) = "),
              let end = line.range(of: ";", range: start.upperBound..<line.endIndex)
        else { return nil }
        var value = String(line[start.upperBound..<end.lowerBound])
        if value.hasPrefix("\"") && value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
        return value
    }

    static func parse(_ text: String) -> Registration {
        var out = Registration()

        // id → the path it declares, and the comment it advertises.
        var refPath: [String: String] = [:]
        var refLabel: [String: String] = [:]
        var refComment: [String: String] = [:]
        for line in section("PBXFileReference", of: text) {
            guard let id = leadingID(of: line), let path = setting("path", in: line) else { continue }
            refPath[id] = path
            refLabel[id] = setting("name", in: line) ?? path
            refComment[id] = Self.firstComment(in: line)
            if path.hasSuffix(".swift") { out.fileReferences.insert(path) }
        }

        // build-file id → the reference it wires. `… in Sources` only; Resources are not ours.
        var wiring: [String: String] = [:]
        for line in section("PBXBuildFile", of: text) {
            guard let id = leadingID(of: line),
                  let comment = Self.firstComment(in: line), comment.hasSuffix(" in Sources"),
                  let ref = setting("fileRef", in: line)?.prefix(24).description
            else { continue }
            wiring[id] = ref
            guard let path = refPath[ref] else {
                out.danglingBuildFiles.append("\(id) → \(ref) (no such PBXFileReference)")
                continue
            }
            if path.hasSuffix(".swift") { out.buildFiles.insert(path) }
        }

        for line in section("PBXGroup", of: text) {
            guard line.hasSuffix(","), let id = leadingID(of: line), let path = refPath[id],
                  path.hasSuffix(".swift")
            else { continue }
            out.groupChildren.insert(path)
        }

        // Sources phases are keyed by object id; native targets name them. Read both, then join.
        var buildFilesByPhase: [String: [String]] = [:]
        var currentPhase: String?
        for line in section("PBXSourcesBuildPhase", of: text) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix("= {"), let id = leadingID(of: line) {
                currentPhase = id
                buildFilesByPhase[id] = []
                continue
            }
            if trimmed == "};" { currentPhase = nil; continue }
            guard let phase = currentPhase, line.hasSuffix(","), let id = leadingID(of: line)
            else { continue }
            buildFilesByPhase[phase, default: []].append(id)
        }

        var currentTargetPhases: [String] = []
        var inBuildPhases = false
        for line in section("PBXNativeTarget", of: text) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "buildPhases = (" { inBuildPhases = true; continue }
            if inBuildPhases {
                if trimmed == ");" { inBuildPhases = false; continue }
                if Self.firstComment(in: line) == "Sources", let id = leadingID(of: line) {
                    currentTargetPhases.append(id)
                }
                continue
            }
            guard trimmed.hasPrefix("name = "), trimmed.hasSuffix(";") else { continue }
            let target = String(trimmed.dropFirst("name = ".count).dropLast())
            let compiled = currentTargetPhases
                .flatMap { buildFilesByPhase[$0] ?? [] }
                .compactMap { wiring[$0].flatMap { refPath[$0] } }
                .filter { $0.hasSuffix(".swift") }
            out.sourcesByTarget[target] = Set(compiled)
            let repeated = Dictionary(grouping: compiled, by: { $0 }).filter { $0.value.count > 1 }
            if !repeated.isEmpty { out.duplicateCompiles[target] = repeated.keys.sorted() }
            currentTargetPhases = []
        }

        // The label a reference advertises is its `name` when it declares one, otherwise its
        // `path` — that is the real pbxproj convention, and getting it wrong here produces
        // false positives on perfectly correct objects. Measured while writing this: a naive
        // `comment == path` rule fired on all six `.lproj` variant children (comment is the
        // language, `zh-Hans`, while the path is `zh-Hans.lproj/Localizable.strings`) and on
        // the local package folder (`name = SoloLedger`, `path = ..`). A `.swift` reference
        // declares no `name`, so for the files this guard is about the rule still reduces to
        // "the comment must be the file name".
        out.commentMismatches = refLabel.compactMap { id, label in
            guard let comment = refComment[id], comment != label else { return nil }
            return "\(id): comment says \(comment), object declares \(label)"
        }.sorted()

        return out
    }

    // MARK: - The two comparators, pure

    struct Drift: Equatable, CustomStringConvertible {
        /// On disk, compiled by nobody — the silent one.
        var unregistered: [String] = []
        /// Registered, but no such file — a build break waiting for a clean checkout.
        var phantom: [String] = []
        var isEmpty: Bool { unregistered.isEmpty && phantom.isEmpty }
        var description: String { "unregistered=\(unregistered) phantom=\(phantom)" }
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

    /// The "exactly four lines per file" rule, machine-checked.
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

    // MARK: - The ID layer the comments sit on top of

    func testEveryBuildFileResolvesToADeclaredFileReference() throws {
        let r = Self.parse(try Self.projectText())
        XCTAssertEqual(r.danglingBuildFiles, [], """
            a PBXBuildFile points at an object that is not a PBXFileReference. Xcode cannot \
            open this project, and a reader that trusted the /* comments */ would call it fine.
            """)
    }

    func testNoTargetCompilesTheSameFileTwice() throws {
        let r = Self.parse(try Self.projectText())
        XCTAssertEqual(r.duplicateCompiles, [:], """
            a Sources phase hands the compiler the same file more than once. The usual cause is \
            a hand-copied PBXBuildFile whose fileRef was never repointed — which also means the \
            file that line was supposed to wire is not being compiled at all.
            """)
    }

    /// The decoration must match the meaning. A `/* Foo.swift */` comment on a reference whose
    /// `path` is `Bar.swift` compiles correctly TODAY and misleads every hand edit after it.
    func testEveryReferenceCommentMatchesItsResolvedPath() throws {
        let r = Self.parse(try Self.projectText())
        XCTAssertEqual(r.commentMismatches, [], """
            a /* comment */ disagrees with the path its object declares. pbxproj comments are \
            decoration — Xcode joins on the 24-hex id — so a mismatch is a trap laid for the \
            next person editing this file by hand.
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
    /// exactly one of them — or to misroute the wiring while leaving every comment truthful.
    /// Synthetic, so no violating file is ever committed.
    /// 24-hex object ids, spelled out so the fixture reads like the real file.
    private static let wiringID = "BB1100000000000000000001"   // the PBXBuildFile
    private static let widgetID = "FA2200000000000000000002"   // Widget.swift's PBXFileReference
    private static let neighbourID = "FA3300000000000000000003" // an innocent bystander
    private static let deadID = "DEAD0000000000000000000F"     // names no object at all

    static func fixture(fileReference: Bool = true, buildFile: Bool = true,
                        groupChild: Bool = true, phaseEntry: Bool = true,
                        misroutedFileRef: Bool = false, danglingFileRef: Bool = false,
                        name: String = "Widget.swift") -> String {
        // Only the `fileRef` moves. Every `/* Widget.swift */` comment stays truthful — which
        // is exactly the shape a comment-keyed reader cannot see.
        let ref = danglingFileRef ? deadID : (misroutedFileRef ? neighbourID : widgetID)
        return """
        /* Begin PBXBuildFile section */
        \(buildFile ? "\t\t\(wiringID) /* \(name) in Sources */ = {isa = PBXBuildFile; fileRef = \(ref) /* \(name) */; };" : "")
        /* End PBXBuildFile section */
        /* Begin PBXFileReference section */
        \(fileReference ? "\t\t\(widgetID) /* \(name) */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = \(name); sourceTree = \"<group>\"; };" : "")
        \t\t\(neighbourID) /* Neighbour.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Neighbour.swift; sourceTree = "<group>"; };
        /* End PBXFileReference section */
        /* Begin PBXGroup section */
        \t\t6A4400000000000000000004 /* App */ = {
        \t\t\tisa = PBXGroup;
        \t\t\tchildren = (
        \(groupChild ? "\t\t\t\t\(widgetID) /* \(name) */," : "")
        \t\t\t);
        \t\t\tpath = App;
        \t\t};
        /* End PBXGroup section */
        /* Begin PBXNativeTarget section */
        \t\t7A5500000000000000000005 /* SoloLedger */ = {
        \t\t\tisa = PBXNativeTarget;
        \t\t\tbuildPhases = (
        \t\t\t\t8A6600000000000000000006 /* Sources */,
        \t\t\t);
        \t\t\tname = SoloLedger;
        \t\t};
        /* End PBXNativeTarget section */
        /* Begin PBXSourcesBuildPhase section */
        \t\t8A6600000000000000000006 /* Sources */ = {
        \t\t\tisa = PBXSourcesBuildPhase;
        \t\t\tfiles = (
        \(phaseEntry ? "\t\t\t\t\(wiringID) /* \(name) in Sources */," : "")
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
        XCTAssertEqual(r.fileReferences, ["Widget.swift", "Neighbour.swift"])
        XCTAssertEqual(r.buildFiles, ["Widget.swift"])
        XCTAssertEqual(r.danglingBuildFiles, [])
        XCTAssertEqual(r.duplicateCompiles, [:])
        XCTAssertEqual(r.commentMismatches, [])
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

    /// The four-line rule, each half broken in turn.
    ///
    /// Note the second shape is "wired but in no phase", NOT "no `PBXBuildFile`". Once
    /// resolution follows ids, deleting the `PBXBuildFile` makes the phase entry resolve to
    /// nothing, so BOTH sides of that equality go empty and agree — the defect surfaces as a
    /// dangling wiring and as family (a) instead, which is what the other two assertions here
    /// pin. An equality that cannot distinguish "both empty" from "both correct" is not the
    /// place to catch it.
    func testAHalfWrittenRegistrationIsReported() {
        let noRef = Self.parse(Self.fixture(fileReference: false))
        XCTAssertNotEqual(noRef.fileReferences, noRef.groupChildren,
                          "a missing PBXFileReference must not read as consistent")
        XCTAssertEqual(noRef.danglingBuildFiles.count, 1,
                       "the wiring now points at an object that does not exist")
        XCTAssertEqual(Self.drift(disk: ["Widget.swift"], compiled: noRef.allCompiled).unregistered,
                       ["Widget.swift"], "and nothing compiles the file")

        let notInAnyPhase = Self.parse(Self.fixture(phaseEntry: false))
        XCTAssertNotEqual(notInAnyPhase.buildFiles, notInAnyPhase.allCompiled,
                          "a PBXBuildFile that no phase lists must not read as consistent")
    }

    /// **The shape a comment-keyed guard cannot see.** Every `/* Widget.swift */` comment is
    /// still truthful; only the `fileRef` points elsewhere. Xcode compiles `Neighbour.swift`
    /// and never compiles `Widget.swift`.
    func testAMisroutedFileRefIsReportedEvenThoughEveryCommentStillSaysWidget() {
        let text = Self.fixture(misroutedFileRef: true)
        XCTAssertTrue(text.contains("/* Widget.swift in Sources */"),
                      "the fixture must keep the misleading comment, or it proves nothing")
        let r = Self.parse(text)
        XCTAssertEqual(r.sourcesByTarget["SoloLedger"], ["Neighbour.swift"],
                       "resolution must follow the id, not the comment")
        XCTAssertEqual(Self.drift(disk: ["Widget.swift"], compiled: r.allCompiled).unregistered,
                       ["Widget.swift"], "family (a) must see that Widget is not compiled")
        XCTAssertEqual(Self.groupPhaseDrift(r), Drift(unregistered: ["Widget.swift"],
                                                      phantom: ["Neighbour.swift"]))
    }

    func testABuildFilePointingAtNothingIsReported() {
        let r = Self.parse(Self.fixture(danglingFileRef: true))
        XCTAssertEqual(r.danglingBuildFiles.count, 1, "a dangling fileRef must be named")
        XCTAssertTrue(r.allCompiled.isEmpty, "a dangling wiring compiles nothing")
    }

    func testACommentThatDisagreesWithItsPathIsReported() {
        let text = Self.fixture()
            .replacingOccurrences(of: "/* Neighbour.swift */ = {isa = PBXFileReference",
                                  with: "/* Widget.swift */ = {isa = PBXFileReference")
        let r = Self.parse(text)
        XCTAssertEqual(r.commentMismatches.count, 1,
                       "a comment that disagrees with its own path must be reported")
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
