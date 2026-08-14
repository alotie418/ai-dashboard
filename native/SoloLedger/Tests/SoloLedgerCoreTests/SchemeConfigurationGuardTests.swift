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
/// guaranteed to produce something unsubmittable — silently, because at the time nothing in this
/// repository built Release at all. 2c-6 closed that half: the `native-app` job now compiles
/// Release on every pull request (build only, unsigned — see ``ReleaseCompileGateGuardTests``).
/// It still archives nothing, which is why the configuration itself has to be pinned here.
///
/// `TestAction`, `LaunchAction` and `ProfileAction` stay **Debug**, and that is a data-safety
/// constraint rather than an oversight left behind. The Release configuration's bundle id is the
/// production one, so a sandboxed process launched, tested or profiled under it resolves
/// `Application Support` into `~/Library/Containers/com.alotie418.sololedger` — the real
/// container, shared with the Electron MAS line and measured to exist on the maintainer's
/// machine. Debug's `.dev` bundle id lands in an isolated preview container instead. Running
/// the app-hosted tests under Release would point them at live user data; the split is the
/// protection, so this file pins BOTH sides. Raising the archive configuration without holding
/// the others down would trade one defect for a worse one.
///
/// **`ProfileAction` was Release until 2c-7b** — Xcode's own default, not something this
/// repository chose, and 2c-4 recorded it as undecided rather than pinning a value it had no
/// ruling for. It is the same hazard: Product ▸ Profile (⌘I) LAUNCHES the app, so under Release it
/// launched with the production bundle id straight into the real container. Instruments profiles
/// whatever it is given, so there is nothing it can measure under Release that Debug cannot also
/// be pointed at — and where an optimised build genuinely is the subject, that is the Core
/// package, which profiles through `swift test -c release` without an app bundle at all. Pinned
/// Debug alongside Test and Launch for exactly their reason.
///
/// `AnalyzeAction` remains unpinned (Debug): the static analyser builds but launches nothing and
/// opens no container. Stated so a future reader does not mistake the omission for an oversight.
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
        "Profile": "Debug",     // …and for Product ▸ Profile, which launches the app too (2c-7b)
    ]

    /// The actions that make Xcode LAUNCH a process built from the configuration. These are the
    /// ones the container hazard applies to, and the ones test (b) holds down.
    static let actionsThatLaunchTheApp = ["Test", "Launch", "Profile"]

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
            submission rejects it. CI compiles Release (2c-6) but archives nothing, so this \
            particular mistake still surfaces for the first time at upload.
            """)
    }

    /// (b) The trade this round must not make. Promoting run, test or profile to Release would
    /// "fix" archiving in the worst possible way.
    ///
    /// All three are asserted here rather than split up: they fail for one and the same reason —
    /// a process launched from the Release configuration opens the production container — so a
    /// reader who fixes one has to see the other two. The message names the offending action, so
    /// the failure still says which of them broke and how each one gets there.
    func testEverythingThatLaunchesTheAppStaysOnDebug() throws {
        let actions = try requireActions()
        for action in Self.actionsThatLaunchTheApp {
            let entryPoint: String
            switch action {
            case "Test": entryPoint = "the app-hosted tests (⌘U) would run"
            case "Launch": entryPoint = "Product ▸ Run (⌘R) would launch"
            default: entryPoint = "Product ▸ Profile (⌘I) would launch Instruments against"
            }
            XCTAssertEqual(actions[action], Self.pinnedConfigurations[action], """
                \(action)Action builds \(actions[action] ?? "nothing") but must build Debug, so \
                \(entryPoint) the production bundle id. Release resolves Application Support into \
                the PRODUCTION container (com.alotie418.sololedger, shared with the Electron line \
                and holding real user data). Debug's .dev bundle id keeps all three in an isolated \
                preview container. This is a data-safety constraint, not a leftover default.
                """)
        }
    }

    /// The remaining unpinned action, recorded rather than asserted-away: if a later round wants
    /// to change it, this is where it should notice that nothing was holding it.
    ///
    /// It was two until 2c-7b; `Profile` moved into the pinned set, which is what this assertion
    /// existed to make happen. `Analyze` stays out because the analyser launches nothing.
    func testTheUnpinnedActionsAreTheOnesThisRoundDeliberatelyLeftAlone() throws {
        let actions = Self.actionConfigurations(in: try Self.schemeText("SoloLedger.xcscheme"))
        let unpinned = Set(actions.keys).subtracting(Self.pinnedConfigurations.keys)
        XCTAssertEqual(unpinned.sorted(), ["Analyze"], """
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
                        launch: String = "Debug", profile: String = "Debug") -> String {
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
              buildConfiguration = "\(profile)"
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
        XCTAssertEqual(actions["Profile"], "Debug")
    }

    /// (b) The trade this round must not make: fixing archiving by promoting run/test/profile.
    /// Each of the three is shown separately, and each leaves the other two — and archiving —
    /// intact, so a failure can only be read as "this action moved".
    func testATestLaunchOrProfileActionPromotedToReleaseIsReported() {
        let promotedTest = Self.actionConfigurations(in: Self.fixture(test: "Release"))
        XCTAssertNotEqual(promotedTest["Test"], Self.pinnedConfigurations["Test"],
                          "app-hosted tests under Release would run in the production container")
        XCTAssertEqual(promotedTest["Archive"], "Release", "…while archiving stayed correct")
        XCTAssertEqual(promotedTest["Launch"], "Debug")
        XCTAssertEqual(promotedTest["Profile"], "Debug")

        let promotedLaunch = Self.actionConfigurations(in: Self.fixture(launch: "Release"))
        XCTAssertNotEqual(promotedLaunch["Launch"], Self.pinnedConfigurations["Launch"])
        XCTAssertEqual(promotedLaunch["Test"], "Debug")
        XCTAssertEqual(promotedLaunch["Profile"], "Debug")
    }

    /// (b′) 2c-7b's own defect shape: the value the scheme actually carried until this round.
    /// Kept as its own test because it is the one an existing project reproduces by default —
    /// Xcode writes `ProfileAction buildConfiguration = "Release"` into every new scheme, so this
    /// is what a regenerated or hand-copied scheme will come back as.
    func testAProfileActionBackOnReleaseIsReported() {
        let actions = Self.actionConfigurations(in: Self.fixture(profile: "Release"))
        XCTAssertEqual(actions["Profile"], "Release")
        XCTAssertNotEqual(actions["Profile"], Self.pinnedConfigurations["Profile"], """
            ⌘I under Release launches the app with the production bundle id, into the container \
            the Electron MAS line's real data lives in — Instruments profiles whatever it is \
            given, so there is nothing here Debug cannot measure.
            """)
        // …and it is distinguishable from the other two launching actions breaking.
        XCTAssertEqual(actions["Test"], "Debug")
        XCTAssertEqual(actions["Launch"], "Debug")
        XCTAssertEqual(actions["Archive"], "Release")
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
