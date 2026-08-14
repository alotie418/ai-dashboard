import Foundation
import XCTest

/// 2c-7 — the two entitlements files, pinned as closed sets, and the project wiring that decides
/// which one reaches which configuration.
///
/// ## Why these two files are load-bearing
///
/// "No AI, no API key, no OCR, no network, no StoreKit, no paid unlock" is a product claim this
/// repository makes in its README, in `docs/SWIFTUI_MIGRATION_PLAN.md`, and — under D7 — in what
/// gets told to Apple about export compliance. **The Release entitlements file is the machine-
/// checkable form of that claim.** A single added key (`com.apple.security.network.client` is the
/// obvious one) would make all of it false, and nothing in this repository would have said so:
/// entitlements are read by `codesign`, which no check here runs. The claim was resting on a
/// manual `grep` recorded in a design document.
///
/// So the sets are pinned CLOSED. Not "must contain the sandbox key" — **exactly these keys, and
/// nothing else**, with their values. Adding a capability is then a decision someone has to make
/// here, in a file that says why the list is short, rather than a line that slips through review.
///
/// ## Why Debug is pinned as a delta rather than as its own list
///
/// The two files must not drift apart in any way EXCEPT the one difference that has a reason.
/// `get-task-allow` lets a debugger and the XCUITest runner attach; it is a debug-only signing
/// entitlement, and an App Store submission carrying it is rejected — that is why Release must not
/// have it. Everything else about the sandbox posture has to be identical, because Debug is what
/// everyone actually runs and tests: a capability that exists only in Debug is a capability whose
/// absence in Release is discovered at runtime, in the shipped build.
///
/// Pinning Debug as `Release + {get-task-allow}` catches both directions with one statement — a
/// key added to Debug alone, and a key added to Release alone — and the shared-values test closes
/// the remaining gap, where the same key is present in both files but says something different.
///
/// ## Why the wiring is part of this round
///
/// A perfect pair of files is worth nothing if the project points at neither. `project.pbxproj`
/// names them per configuration, and the Debug entry is QUOTED in the file while the Release entry
/// is not — the shape that made an earlier guard in 2c-3 silently pass, so the comparison goes
/// through the same unquoting parser that round installed.
/// ``AppVersionGuardTests.testTheConfigurationScannerReadsRealSettingsAndInventsNone`` deliberately
/// asserted only the SHAPE of that setting, leaving the paths to "the packaging chapter"; this is
/// that chapter, so the paths are pinned here and the two files' existence with them.
///
/// ## Scope
///
/// This round changes neither entitlements file and neither project setting: it pins what is
/// already there. `build/entitlements.mas.plist` and `build/entitlements.mac.plist` belong to the
/// Electron lines and are out of scope (D6 froze the MAS one; `SigningConfigurationGuardTests`
/// already holds its Team-ID placeholder). Runtime sandbox behaviour is likewise untouched — R9 in
/// `docs/SWIFTUI_DMG_MIGRATION_DESIGN.md` records that it has no headless coverage, and a static
/// check of the file cannot give it any.
final class EntitlementsClosedSetGuardTests: XCTestCase {

    // MARK: - The pinned sets

    static let sandbox = "com.apple.security.app-sandbox"
    static let userSelectedReadWrite = "com.apple.security.files.user-selected.read-write"
    static let getTaskAllow = "com.apple.security.get-task-allow"

    /// Everything the shipped app is allowed to ask the system for.
    static let releaseKeys: Set<String> = [sandbox, userSelectedReadWrite]
    /// The one thing Debug may add, and the only thing.
    static let debugOnlyKeys: Set<String> = [getTaskAllow]
    static var debugKeys: Set<String> { releaseKeys.union(debugOnlyKeys) }

    /// Paths as `project.pbxproj` spells them: relative to the `App/` directory that holds the
    /// `.xcodeproj`.
    static let releaseEntitlementsPath = "Support/SoloLedger.entitlements"
    static let debugEntitlementsPath = "Support/SoloLedger-Debug.entitlements"

    // MARK: - Reading the files

    static func appDirectory() -> URL {
        AppTargetRegistrationGuardTests.packageRoot().appendingPathComponent("App", isDirectory: true)
    }

    /// Parse with Foundation's own plist reader rather than a text scan: the file is a plist, the
    /// tools that consume it parse it as one, and a scanner that greps for `<key>` lines would
    /// disagree with them the first time the file is written in a different but equivalent form.
    ///
    /// Returns `nil` — never an empty dictionary — for anything that is not a plist dictionary, so
    /// an unreadable or malformed file cannot read as "carries no forbidden keys".
    static func parse(_ data: Data) -> [String: Any]? {
        guard let object = try? PropertyListSerialization.propertyList(from: data,
                                                                      options: [],
                                                                      format: nil) else { return nil }
        return object as? [String: Any]
    }

    static func parse(text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return parse(data)
    }

    static func entitlements(at relativePath: String) throws -> [String: Any] {
        let url = appDirectory().appendingPathComponent(relativePath)
        let data = try Data(contentsOf: url)
        guard let plist = parse(data) else {
            throw NSError(domain: "EntitlementsClosedSetGuardTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: """
                    \(relativePath) did not parse as a plist dictionary. The checks in this file \
                    are all "the set of keys is exactly X"; a failed parse must stop them rather \
                    than let an empty set satisfy a subtraction.
                    """])
        }
        return plist
    }

    /// Keys whose value is the plist boolean `<true/>`.
    ///
    /// The CFBoolean check is not pedantry: `<integer>1</integer>` bridges to `NSNumber`, and a
    /// plain `as? Bool` accepts it. Whether the signing tools would honour that form is not
    /// something this repository has measured — but a capability list that stopped saying
    /// `<true/>` is a change someone should look at either way, so it is not quietly accepted.
    static func keysSetToBooleanTrue(_ plist: [String: Any]) -> Set<String> {
        var out: Set<String> = []
        for (key, value) in plist {
            guard CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID(),
                  let flag = value as? Bool, flag else { continue }
            out.insert(key)
        }
        return out
    }

    // MARK: - (a) Release is a closed set

    func testTheReleaseEntitlementsAreExactlyTheTwoSandboxKeys() throws {
        let plist = try Self.entitlements(at: Self.releaseEntitlementsPath)
        XCTAssertEqual(Set(plist.keys), Self.releaseKeys, """
            \(Self.releaseEntitlementsPath) no longer declares exactly \
            \(Self.releaseKeys.sorted()). This file IS the machine-checkable form of the product's \
            "no AI, no network, no OCR, no StoreKit" claim and of what D7 export compliance is \
            answered from — adding a capability here makes those statements false everywhere they \
            appear. If a capability genuinely became necessary, change `releaseKeys` in the same \
            commit and say why; do not widen the check.
            """)
    }

    func testEveryReleaseEntitlementIsBooleanTrue() throws {
        let plist = try Self.entitlements(at: Self.releaseEntitlementsPath)
        XCTAssertEqual(Self.keysSetToBooleanTrue(plist), Self.releaseKeys, """
            a Release entitlement is present but is not the boolean <true/>: \
            \(Set(plist.keys).subtracting(Self.keysSetToBooleanTrue(plist)).sorted()). A key set to \
            <false/>, to an integer, or to a string is not a capability that is on, and the closed \
            set above would still be satisfied by it.
            """)
    }

    // MARK: - (b) Debug is Release plus exactly one debugging entitlement

    func testDebugIsTheReleaseSetPlusExactlyGetTaskAllow() throws {
        let debug = Set(try Self.entitlements(at: Self.debugEntitlementsPath).keys)
        let release = Set(try Self.entitlements(at: Self.releaseEntitlementsPath).keys)

        XCTAssertEqual(debug.subtracting(release), Self.debugOnlyKeys, """
            Debug adds \(debug.subtracting(release).sorted()) over Release, but the only addition \
            allowed is \(Self.debugOnlyKeys.sorted()) — the debugger / XCUITest-runner attach \
            entitlement. Any other capability that exists only in Debug is a capability whose \
            absence from the shipped build is discovered at runtime.
            """)
        XCTAssertEqual(release.subtracting(debug), [], """
            Release declares \(release.subtracting(debug).sorted()), which Debug does not. The \
            configuration everybody actually runs would then be exercising a different sandbox \
            posture from the one that ships.
            """)
    }

    func testTheKeysDebugSharesWithReleaseCarryIdenticalValues() throws {
        let debug = try Self.entitlements(at: Self.debugEntitlementsPath)
        let release = try Self.entitlements(at: Self.releaseEntitlementsPath)
        let shared = Set(debug.keys).intersection(release.keys)
        XCTAssertEqual(shared, Self.releaseKeys, "the shared set is not the Release set")

        let debugTrue = Self.keysSetToBooleanTrue(debug).intersection(shared)
        let releaseTrue = Self.keysSetToBooleanTrue(release).intersection(shared)
        XCTAssertEqual(debugTrue, releaseTrue, """
            a key present in both files says something different in each: \
            \(debugTrue.symmetricDifference(releaseTrue).sorted()). Matching key NAMES are not \
            enough — the same entitlement turned on in one configuration and off in the other is \
            exactly the drift the delta check above cannot see.
            """)
    }

    func testEveryDebugEntitlementIsBooleanTrue() throws {
        let plist = try Self.entitlements(at: Self.debugEntitlementsPath)
        XCTAssertEqual(Self.keysSetToBooleanTrue(plist), Self.debugKeys, """
            a Debug entitlement is present but is not the boolean <true/>: \
            \(Set(plist.keys).subtracting(Self.keysSetToBooleanTrue(plist)).sorted()).
            """)
    }

    // MARK: - (c) The wiring: which file reaches which configuration

    static func appTargetEntitlementsPaths() throws -> [String: String] {
        var out: [String: String] = [:]
        for config in AppVersionGuardTests.appTargetConfigurations(
            in: try AppTargetRegistrationGuardTests.projectText()) {
            out[config.name] = config.settings["CODE_SIGN_ENTITLEMENTS"]
        }
        return out
    }

    func testEachAppTargetConfigurationPointsAtItsOwnEntitlementsFile() throws {
        let paths = try Self.appTargetEntitlementsPaths()
        XCTAssertEqual(paths.count, 2, "expected the app target's two configurations, got \(paths)")
        XCTAssertEqual(paths["Release"], Self.releaseEntitlementsPath, """
            the Release configuration's CODE_SIGN_ENTITLEMENTS is \
            \(paths["Release"] ?? "absent"). Pinning the contents of \
            \(Self.releaseEntitlementsPath) proves nothing if the shipped configuration signs \
            against a different file — including the Debug one, which carries get-task-allow.
            """)
        XCTAssertEqual(paths["Debug"], Self.debugEntitlementsPath, """
            the Debug configuration's CODE_SIGN_ENTITLEMENTS is \(paths["Debug"] ?? "absent"). \
            (This value is QUOTED in project.pbxproj; the comparison goes through the unquoting \
            parser 2c-3 installed, because a comparison against the quoted token would pass \
            nothing and fail everything — or, worse, be written to expect the quotes and then \
            stop matching the day they are dropped.)
            """)
    }

    func testBothEntitlementsFilesExistAndParse() throws {
        for path in [Self.releaseEntitlementsPath, Self.debugEntitlementsPath] {
            let url = Self.appDirectory().appendingPathComponent(path)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), """
                project.pbxproj names \(path) but no such file exists. Xcode fails the build for \
                this, but only for a configuration someone actually builds — and until 2c-6 \
                nothing built Release at all.
                """)
            XCTAssertNotNil(Self.parse(try Data(contentsOf: url)),
                            "\(path) exists but is not a plist dictionary")
        }
    }

    func testNothingOutsideTheAppTargetDeclaresEntitlements() throws {
        let text = try AppTargetRegistrationGuardTests.projectText()
        let appTargetIDs = Set(AppVersionGuardTests.appTargetConfigurations(in: text).map(\.id))
        let carriers = AppVersionGuardTests.configurations(in: text)
            .filter { $0.settings["CODE_SIGN_ENTITLEMENTS"] != nil }
        XCTAssertEqual(carriers.count, 2, """
            expected exactly two configurations to declare CODE_SIGN_ENTITLEMENTS, found \
            \(carriers.map { "\($0.name) (\($0.id))" }.sorted()).
            """)
        for carrier in carriers {
            XCTAssertTrue(appTargetIDs.contains(carrier.id), """
                \(carrier.name) (\(carrier.id)) is not an app-target configuration but declares \
                entitlements. Only the shipped app is sandboxed and submitted; at project level \
                the setting would also reach both test bundles, which are signed ad-hoc precisely \
                so that building and testing needs nothing.
                """)
        }
    }

    // MARK: - The scanners are not no-ops

    func testTheParserReadsTheRealFilesAndReportsAbsenceForAnInventedKey() throws {
        let release = try Self.entitlements(at: Self.releaseEntitlementsPath)
        XCTAssertNotNil(release[Self.sandbox], "the parser did not find the sandbox key")
        XCTAssertNil(release["com.apple.security.this.has.never.existed"],
                     "the parser invents keys")
        XCTAssertNil(release[Self.getTaskAllow],
                     "the parser must report get-task-allow as absent from Release")
        let debug = try Self.entitlements(at: Self.debugEntitlementsPath)
        XCTAssertNotNil(debug[Self.getTaskAllow])
    }

    func testAMalformedOrNonDictionaryPlistParsesToNothing() {
        XCTAssertNil(Self.parse(text: ""), "empty input must not parse")
        XCTAssertNil(Self.parse(text: "<plist version=\"1.0\"><dict>"),
                     "truncated XML must not parse")
        XCTAssertNil(Self.parse(text: """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><array><string>x</string></array></plist>
            """), "a plist that is not a dictionary must not read as an empty dictionary")
        // Which is what makes the closed-set assertions fail rather than pass on such a file.
        XCTAssertNotEqual(Set<String>(), Self.releaseKeys,
                          "an empty key set must not equal the pinned Release set")
    }

    func testTheBooleanFilterRejectsIntegersStringsAndFalse() throws {
        let plist = try XCTUnwrap(Self.parse(text: Self.plistFixture([
            "yes": "<true/>",
            "no": "<false/>",
            "one": "<integer>1</integer>",
            "word": "<string>true</string>",
        ])))
        XCTAssertEqual(Set(plist.keys), ["yes", "no", "one", "word"],
                       "the fixture itself must carry all four shapes")
        XCTAssertEqual(Self.keysSetToBooleanTrue(plist), ["yes"], """
            only <true/> counts. <integer>1</integer> in particular bridges to NSNumber and would \
            be accepted by a plain `as? Bool`, which is why the filter checks the CFBoolean type.
            """)
    }

    // MARK: - Reverse proof: each defect shape, on synthetic text

    /// A plist dictionary from `key → raw XML value element`, emitted in sorted key order so the
    /// output is deterministic.
    static func plistFixture(_ entries: [String: String]) -> String {
        let body = entries.keys.sorted()
            .map { "  <key>\($0)</key>\(entries[$0]!)" }
            .joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \(body)
        </dict>
        </plist>
        """
    }

    static func fixture(release: Bool = true, extraKeys: [String: String] = [:]) -> String {
        var entries: [String: String] = [sandbox: "<true/>", userSelectedReadWrite: "<true/>"]
        if !release { entries[getTaskAllow] = "<true/>" }
        entries.merge(extraKeys) { _, new in new }
        return plistFixture(entries)
    }

    func testTheFixtureAtThePinnedSetsIsClean() throws {
        let release = try XCTUnwrap(Self.parse(text: Self.fixture(release: true)))
        let debug = try XCTUnwrap(Self.parse(text: Self.fixture(release: false)))
        XCTAssertEqual(Set(release.keys), Self.releaseKeys)
        XCTAssertEqual(Set(debug.keys), Self.debugKeys)
        XCTAssertEqual(Self.keysSetToBooleanTrue(release), Self.releaseKeys)
        XCTAssertEqual(Set(debug.keys).subtracting(release.keys), Self.debugOnlyKeys)
        XCTAssertEqual(Set(release.keys).subtracting(debug.keys), [])
    }

    /// (a) The defect this round exists to make impossible: one more capability in the shipped app.
    func testAThirdKeyInTheReleaseSetIsReported() throws {
        let plist = try XCTUnwrap(Self.parse(text: Self.fixture(
            release: true, extraKeys: ["com.apple.security.network.client": "<true/>"])))
        XCTAssertNotEqual(Set(plist.keys), Self.releaseKeys,
                          "a network entitlement must not read as the pinned Release set")
        XCTAssertEqual(Set(plist.keys).subtracting(Self.releaseKeys),
                       ["com.apple.security.network.client"])
        // A bookmark entitlement is the other one the migration design forbids by name.
        let bookmarked = try XCTUnwrap(Self.parse(text: Self.fixture(
            release: true, extraKeys: ["com.apple.security.files.bookmarks.app-scope": "<true/>"])))
        XCTAssertNotEqual(Set(bookmarked.keys), Self.releaseKeys)
    }

    /// (a′) The same set, but a key switched off — caught by the value check, not the key check.
    func testAReleaseKeyTurnedOffIsReportedEvenThoughTheKeySetIsUnchanged() throws {
        let plist = try XCTUnwrap(Self.parse(text: Self.plistFixture([
            Self.sandbox: "<true/>",
            Self.userSelectedReadWrite: "<false/>",
        ])))
        XCTAssertEqual(Set(plist.keys), Self.releaseKeys,
                       "the key set alone still looks correct — that is the point")
        XCTAssertNotEqual(Self.keysSetToBooleanTrue(plist), Self.releaseKeys,
                          "…and the value check is what catches it")
    }

    /// (b) Both directions of the delta.
    func testGetTaskAllowMissingFromDebugOrLeakingIntoReleaseIsReported() throws {
        let release = try XCTUnwrap(Self.parse(text: Self.fixture(release: true)))

        let debugWithout = try XCTUnwrap(Self.parse(text: Self.fixture(release: true)))
        XCTAssertNotEqual(Set(debugWithout.keys).subtracting(release.keys), Self.debugOnlyKeys,
                          "a Debug file that lost get-task-allow must not read as the pinned delta")

        let releaseWith = try XCTUnwrap(Self.parse(text: Self.fixture(
            release: true, extraKeys: [Self.getTaskAllow: "<true/>"])))
        XCTAssertNotEqual(Set(releaseWith.keys), Self.releaseKeys, """
            get-task-allow in Release must be reported: a submission carrying it is rejected, and \
            it lets a debugger attach to the shipped, sandboxed app.
            """)
        // …and, from the delta's side, the addition then reads as empty rather than as the pin.
        let debug = try XCTUnwrap(Self.parse(text: Self.fixture(release: false)))
        XCTAssertEqual(Set(debug.keys).subtracting(releaseWith.keys), [])
    }

    /// (b′) Same key, different value in each file.
    func testAKeyThatDisagreesBetweenTheTwoFilesIsReported() throws {
        let release = try XCTUnwrap(Self.parse(text: Self.fixture(release: true)))
        let debug = try XCTUnwrap(Self.parse(text: Self.plistFixture([
            Self.sandbox: "<false/>",
            Self.userSelectedReadWrite: "<true/>",
            Self.getTaskAllow: "<true/>",
        ])))
        XCTAssertEqual(Set(debug.keys).subtracting(release.keys), Self.debugOnlyKeys,
                       "the delta still looks right — which is why the value check exists")
        let shared = Set(debug.keys).intersection(release.keys)
        XCTAssertNotEqual(Self.keysSetToBooleanTrue(debug).intersection(shared),
                          Self.keysSetToBooleanTrue(release).intersection(shared))
    }

    /// (c) The wiring, on synthetic project text: a rewired path, and the quoted form.
    func testARewiredEntitlementsPathIsReported() {
        let rewired = Self.projectFixture(release: Self.debugEntitlementsPath)
        let configs = AppVersionGuardTests.configurations(in: rewired)
        let release = configs.first { $0.name == "Release" }
        XCTAssertEqual(release?.settings["CODE_SIGN_ENTITLEMENTS"], Self.debugEntitlementsPath)
        XCTAssertNotEqual(release?.settings["CODE_SIGN_ENTITLEMENTS"], Self.releaseEntitlementsPath,
                          "a Release configuration signing against the Debug entitlements must be reported")

        let quoted = AppVersionGuardTests.configurations(in: Self.projectFixture())
        XCTAssertEqual(quoted.first { $0.name == "Debug" }?.settings["CODE_SIGN_ENTITLEMENTS"],
                       Self.debugEntitlementsPath,
                       "the quoted form in the file must arrive unquoted, as it does in the real project")
    }

    /// Two configurations in the shape `project.pbxproj` writes them — Debug's value quoted,
    /// Release's not, exactly as the real file has it.
    static func projectFixture(debug: String? = nil, release: String? = nil) -> String {
        """
        /* Begin XCBuildConfiguration section */
        \t\tC94300000000000000000001 /* Debug */ = {
        \t\t\tisa = XCBuildConfiguration;
        \t\t\tbuildSettings = {
        \t\t\t\tCODE_SIGN_ENTITLEMENTS = "\(debug ?? debugEntitlementsPath)";
        \t\t\t\tPRODUCT_NAME = SoloLedger;
        \t\t\t};
        \t\t\tname = Debug;
        \t\t};
        \t\tEB5600000000000000000002 /* Release */ = {
        \t\t\tisa = XCBuildConfiguration;
        \t\t\tbuildSettings = {
        \t\t\t\tCODE_SIGN_ENTITLEMENTS = \(release ?? releaseEntitlementsPath);
        \t\t\t\tPRODUCT_NAME = SoloLedger;
        \t\t\t};
        \t\t\tname = Release;
        \t\t};
        /* End XCBuildConfiguration section */
        """
    }
}
