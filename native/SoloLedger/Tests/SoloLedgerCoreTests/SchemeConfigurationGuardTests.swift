import XCTest

/// 2c-4 — which build configuration each scheme action uses.
///
/// ## Why archiving had to change, and why running/testing must NOT
///
/// The shared scheme decides what `xcodebuild archive -scheme SoloLedger` and Xcode's
/// Product ▸ Archive actually build. Until this round its `ArchiveAction` said **Debug**, so the
/// archive anyone would produce by following the README carried the Debug configuration's
/// `com.alotie418.sololedger.dev` bundle id and its `com.apple.security.get-task-allow`
/// entitlement. `get-task-allow` lets a debugger attach; App Store submissions carrying it are
/// rejected, and the bundle id is not the one the store record is for. Archiving was therefore
/// guaranteed to produce something unsubmittable — silently, because nothing builds Release.
///
/// `TestAction` and `LaunchAction` stay **Debug**, and that is a data-safety constraint rather
/// than an oversight left behind. The Release configuration's bundle id is the production one,
/// so a sandboxed process launched or tested under it resolves
/// `Application Support` into `~/Library/Containers/com.alotie418.sololedger` — the real
/// container, shared with the Electron MAS line and measured to exist on the maintainer's
/// machine. Debug's `.dev` bundle id lands in an isolated preview container instead. Running
/// the app-hosted tests under Release would point them at live user data; the split is the
/// protection, so this file pins BOTH sides. Raising the archive configuration without holding
/// the other two down would trade one defect for a worse one.
///
/// `ProfileAction` is left as it is (already Release) and `AnalyzeAction` likewise (Debug):
/// neither produces a shippable artifact nor opens a store container, so neither is pinned —
/// stated so a future reader does not mistake the omission for an oversight.
///
/// ## Why the scheme FILE list is part of the guard
///
/// Every assertion below reads one file. A second shared scheme — say `SoloLedger-Release` —
/// would be equally buildable and equally shippable while this file kept passing on the old
/// one. So the set of shared schemes is itself closed: adding one has to come with a decision
/// about which configuration it archives.
///
/// Scope: this round changed the configuration only. Signing identity, team, provisioning
/// profile and `ExportOptions.plist` are 2c-5; nothing here builds or archives anything.
final class SchemeConfigurationGuardTests: XCTestCase {

    /// The complete set of shared schemes. Shared schemes are the ones committed and therefore
    /// the ones CI and other machines see; per-user schemes live in `xcuserdata/`, which is not
    /// tracked.
    static let expectedSchemeFiles = ["SoloLedger.xcscheme"]

    /// Action → the configuration it must use, and why that specific one.
    static let pinnedConfigurations: [String: String] = [
        "Archive": "Release",   // a Debug archive is unsubmittable: .dev id + get-task-allow
        "Test": "Debug",        // Release would run app-hosted tests in the production container
        "Launch": "Debug",      // …same container hazard for Product ▸ Run
    ]

    // MARK: - Reading the scheme

    static func schemesDirectory() -> URL {
        AppTargetRegistrationGuardTests.packageRoot()
            .appendingPathComponent("App/SoloLedger.xcodeproj/xcshareddata/xcschemes",
                                    isDirectory: true)
    }

    static func sharedSchemeFileNames() throws -> [String] {
        try FileManager.default
            .contentsOfDirectory(atPath: schemesDirectory().path)
            .filter { $0.hasSuffix(".xcscheme") }
            .sorted()
    }

    static func schemeText(_ name: String) throws -> String {
        try String(contentsOf: schemesDirectory().appendingPathComponent(name), encoding: .utf8)
    }

    /// `<XxxAction … buildConfiguration = "Y" …>` → `["Xxx": "Y"]`.
    ///
    /// The match is confined to a single opening tag (`[^>]*`), so it cannot pair one action's
    /// name with a later action's configuration — the failure mode that would make every
    /// assertion below agree with itself while describing the wrong element.
    static func actionConfigurations(in xml: String) -> [String: String] {
        let pattern = #"<(\w+)Action\b[^>]*?buildConfiguration\s*=\s*"([^"]*)""#
        guard let re = try? NSRegularExpression(pattern: pattern,
                                                options: [.dotMatchesLineSeparators]) else { return [:] }
        var out: [String: String] = [:]
        let ns = xml as NSString
        for match in re.matches(in: xml, range: NSRange(location: 0, length: ns.length)) {
            out[ns.substring(with: match.range(at: 1))] = ns.substring(with: match.range(at: 2))
        }
        return out
    }

    // MARK: - (c) the closed set of shared schemes

    func testTheSharedSchemesAreExactlyTheExpectedOnes() throws {
        let found = try Self.sharedSchemeFileNames()
        XCTAssertEqual(found, Self.expectedSchemeFiles, """
            the set of shared schemes changed. Every assertion in this file reads \
            \(Self.expectedSchemeFiles); a second shared scheme would be just as buildable and \
            just as shippable while these checks kept passing on the old one. Adding one has to \
            come with a decision about which configuration it archives.
            """)
    }

    // MARK: - (a) and (b) the pinned configurations

    /// Fail-closed accessor: an unreadable or unparsable scheme must not let a pin assertion
    /// pass by comparing `nil` against nothing.
    func requireActions(file: StaticString = #filePath, line: UInt = #line) throws -> [String: String] {
        let actions = Self.actionConfigurations(in: try Self.schemeText("SoloLedger.xcscheme"))
        XCTAssertGreaterThanOrEqual(actions.count, Self.pinnedConfigurations.count,
                                    "the scheme scan came back short — parsed: \(actions)",
                                    file: file, line: line)
        return actions
    }

    /// (a) The defect this round removes. Kept separate from (b) so a failure says which of the
    /// two opposing constraints broke — they fail for entirely different reasons.
    func testTheArchiveActionBuildsRelease() throws {
        let actions = try requireActions()
        XCTAssertEqual(actions["Archive"], Self.pinnedConfigurations["Archive"], """
            ArchiveAction builds \(actions["Archive"] ?? "nothing") but must build Release. A \
            Debug archive carries the .dev bundle id and get-task-allow, so App Store \
            submission rejects it — and nothing else in this repository builds Release, so the \
            mistake would surface only at upload.
            """)
    }

    /// (b) The trade this round must not make. Promoting run or test to Release would "fix"
    /// archiving in the worst possible way.
    func testRunningAndTestingStayOnDebug() throws {
        let actions = try requireActions()
        for action in ["Test", "Launch"] {
            XCTAssertEqual(actions[action], Self.pinnedConfigurations[action], """
                \(action)Action builds \(actions[action] ?? "nothing") but must build Debug. \
                Release resolves Application Support into the PRODUCTION container \
                (com.alotie418.sololedger, shared with the Electron line and holding real user \
                data). Debug's .dev bundle id keeps run/test in an isolated preview container. \
                This is a data-safety constraint, not a leftover default.
                """)
        }
    }

    /// The two unpinned actions, recorded rather than asserted-away: if a later round wants to
    /// change either, this is where it should notice that nothing was holding it.
    func testTheUnpinnedActionsAreTheOnesThisRoundDeliberatelyLeftAlone() throws {
        let actions = Self.actionConfigurations(in: try Self.schemeText("SoloLedger.xcscheme"))
        let unpinned = Set(actions.keys).subtracting(Self.pinnedConfigurations.keys)
        XCTAssertEqual(unpinned.sorted(), ["Analyze", "Profile"], """
            the scheme has an action this guard neither pins nor knows about: \
            \(unpinned.sorted()). Every action that builds something deserves a decision \
            about which configuration it builds.
            """)
    }

    // MARK: - The scanner is not a no-op

    func testTheScannerReadsRealActionsAndInventsNone() throws {
        let actions = Self.actionConfigurations(in: try Self.schemeText("SoloLedger.xcscheme"))
        XCTAssertEqual(Set(actions.keys), ["Test", "Launch", "Profile", "Analyze", "Archive"],
                       "parsed actions: \(actions)")
        XCTAssertNil(actions["Deploy"], "the scanner invents actions")
        // `BuildAction` really has no buildConfiguration — proving the scan reports absence
        // rather than defaulting.
        XCTAssertNil(actions["Build"],
                     "BuildAction carries no buildConfiguration; a scan that supplies one is guessing")
    }

    func testTheSchemeFileScannerFindsTheRealFileAndMissesAnInventedOne() throws {
        let found = try Self.sharedSchemeFileNames()
        XCTAssertTrue(found.contains("SoloLedger.xcscheme"))
        XCTAssertFalse(found.contains("ThisSchemeHasNeverExisted.xcscheme"))
    }

    // MARK: - Reverse proof: each defect shape, on synthetic text

    static func fixture(archive: String = "Release", test: String = "Debug",
                        launch: String = "Debug") -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <Scheme LastUpgradeVersion = "1430" version = "1.7">
           <BuildAction
              parallelizeBuildables = "YES"
              buildImplicitDependencies = "YES">
           </BuildAction>
           <TestAction
              buildConfiguration = "\(test)"
              shouldUseLaunchSchemeArgsEnv = "YES">
           </TestAction>
           <LaunchAction
              buildConfiguration = "\(launch)"
              launchStyle = "0">
           </LaunchAction>
           <ProfileAction
              buildConfiguration = "Release"
              shouldUseLaunchSchemeArgsEnv = "YES">
           </ProfileAction>
           <AnalyzeAction
              buildConfiguration = "Debug">
           </AnalyzeAction>
           <ArchiveAction
              buildConfiguration = "\(archive)"
              revealArchiveInOrganizer = "YES">
           </ArchiveAction>
        </Scheme>
        """
    }

    func testTheFixtureAtThePinnedConfigurationsIsClean() {
        let actions = Self.actionConfigurations(in: Self.fixture())
        for (action, expected) in Self.pinnedConfigurations {
            XCTAssertEqual(actions[action], expected)
        }
        XCTAssertEqual(Set(actions.keys), ["Test", "Launch", "Profile", "Analyze", "Archive"])
    }

    /// (a) The defect this round exists to remove.
    func testAnArchiveActionBackOnDebugIsReported() {
        let actions = Self.actionConfigurations(in: Self.fixture(archive: "Debug"))
        XCTAssertEqual(actions["Archive"], "Debug")
        XCTAssertNotEqual(actions["Archive"], Self.pinnedConfigurations["Archive"],
                          "a Debug archive must not read as pinned")
        // …and only that one moved.
        XCTAssertEqual(actions["Test"], "Debug")
        XCTAssertEqual(actions["Launch"], "Debug")
    }

    /// (b) The trade this round must not make: fixing archiving by promoting run/test.
    func testATestOrLaunchActionPromotedToReleaseIsReported() {
        let promotedTest = Self.actionConfigurations(in: Self.fixture(test: "Release"))
        XCTAssertNotEqual(promotedTest["Test"], Self.pinnedConfigurations["Test"],
                          "app-hosted tests under Release would run in the production container")
        XCTAssertEqual(promotedTest["Archive"], "Release", "…while archiving stayed correct")

        let promotedLaunch = Self.actionConfigurations(in: Self.fixture(launch: "Release"))
        XCTAssertNotEqual(promotedLaunch["Launch"], Self.pinnedConfigurations["Launch"])
    }

    /// (c) A second shared scheme is what the file-set assertion is for. Proven on the pure
    /// comparison, since the real directory holds exactly one.
    func testAnExtraSharedSchemeWouldBeReported() {
        let found = ["SoloLedger.xcscheme", "SoloLedger-Release.xcscheme"].sorted()
        XCTAssertNotEqual(found, Self.expectedSchemeFiles,
                          "a second shared scheme must not read as the expected set")
        XCTAssertEqual(Set(found).subtracting(Self.expectedSchemeFiles),
                       ["SoloLedger-Release.xcscheme"])
    }

    /// An unreadable scheme must not look like agreement: the parse yields nothing, and the
    /// count assertion in the pinned test is what turns that into a failure.
    func testAnEmptySchemeYieldsNoActionsRatherThanSilentAgreement() {
        let actions = Self.actionConfigurations(in: "")
        XCTAssertTrue(actions.isEmpty)
        XCTAssertLessThan(actions.count, Self.pinnedConfigurations.count,
                          "an empty parse must fail the count check the pinned test performs")
        for action in Self.pinnedConfigurations.keys {
            XCTAssertNil(actions[action],
                         "an empty parse must report absence, not the expected value")
        }
    }

    /// The regex must not pair one action's name with another action's configuration — a scheme
    /// whose ArchiveAction carries NO configuration must report absence, not inherit Profile's.
    func testAnActionWithoutAConfigurationIsNotGivenItsNeighboursValue() {
        let xml = """
        <Scheme>
           <ProfileAction
              buildConfiguration = "Release">
           </ProfileAction>
           <ArchiveAction
              revealArchiveInOrganizer = "YES">
           </ArchiveAction>
        </Scheme>
        """
        let actions = Self.actionConfigurations(in: xml)
        XCTAssertEqual(actions["Profile"], "Release")
        XCTAssertNil(actions["Archive"],
                     "an action with no buildConfiguration must not borrow the previous one's")
    }
}
