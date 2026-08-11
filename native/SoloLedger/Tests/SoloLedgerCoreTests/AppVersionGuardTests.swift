import XCTest

/// 2c-3 — the App's version numbers, pinned to the decisions that chose them, and tied to the
/// bundle they actually reach.
///
/// ## The chain this holds, end to end
///
/// `project.pbxproj` declares `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in the app
/// target's two configurations; `App/Support/Info.plist` maps them onto
/// `CFBundleShortVersionString` and `CFBundleVersion`; since #469 the About tab reads those
/// back out of the bundle. **Every link is asserted here.** An earlier draft of this file
/// checked only the build settings and stated the rest as a documentation axiom — which would
/// have let someone replace the `$(…)` substitutions with literals, or swap them, and ship a
/// different version with every test green. That shape (the load-bearing link written in a
/// comment instead of an assertion) is the one this repository has already been bitten by once.
///
/// The link from the target to those configurations is followed by **object id**, not by
/// `name = Debug;`: `PBXNativeTarget` → `buildConfigurationList` → `XCConfigurationList`. A
/// text-level match on the configuration name would accept an orphaned block — one still
/// spelling out the right versions while the target's list points somewhere else entirely.
/// This is the same lesson `AppTargetRegistrationGuardTests` records about `/* comments */`.
///
/// There is no generator, no `agvtool`, no CI injection and no bump script for this target:
/// no `.xcconfig`, no `baseConfigurationReference`, no `INFOPLIST_KEY_*`, no
/// `GENERATE_INFOPLIST_FILE`, and CI passes no setting overrides. (The Electron line does
/// carry its own `buildVersion` in `electron-builder.mas.yml`; that is a different producer for
/// a different product, and is not what this file governs.) Every change here is a hand edit.
///
/// ## The build-number scheme (D2), and why `2`
///
/// The build number is a **bare positive integer**, starting at `2`.
///
/// The floor comes from a recorded human observation, not from anything this repository can
/// measure: the maintainer's App Store Connect check on 2026-08-10 put the highest accepted
/// `CFBundleVersion` under this bundle id at **`1.0.0`**. (The `1.0.1` artifact in the working
/// tree was never uploaded — see `docs/MAS_SUBMISSION.md`.)
///
/// On Apple's side the constraint is that a build number must not collide with, and must
/// advance past, what the same version train already used. This repository deliberately adopts
/// a **stricter, simpler** floor — higher than *every* build ever accepted under this bundle
/// id — because it is checkable here and cannot be wrong in the unsafe direction. `2` clears
/// that floor: comparing as period-separated integers, `2` versus `1.0.0` is decided at the
/// first component. ``testThePinnedBuildNumberOutranksWhatAppStoreConnectHas`` checks the
/// relation rather than asserting it in prose, so revising either constant re-runs it.
/// **App Store Connect remains the authority for the floor itself.**
///
/// ## The ratchet, and what raising a version actually costs
///
/// Both values are pinned to constants, so raising a version is a deliberate edit, not a
/// character someone changed. There is no "greater than or equal" slack: a ratchet that
/// accepted anything higher would wave through an accidental bump, and a bump is
/// unrecoverable — an uploaded build number can never be reused.
///
/// Raising a version touches, in one pull request:
/// 1. `project.pbxproj` — both configurations;
/// 2. ``pinnedBuildNumber`` / ``pinnedMarketingVersion`` here;
/// 3. ``appStoreConnectHighWaterMark`` — but only *after* an upload succeeds, as a separate
///    step recording what App Store Connect accepted (see that constant's note).
///
/// Nothing else in the tree should carry a copy. The counterexamples below derive their values
/// from the pins for exactly this reason: a hard-coded "3" would turn into a false failure on
/// the day the build number legitimately became 3.
///
/// ## Relationship to `AboutVersionTests`
///
/// That file deliberately pins **no** numbers: it proves the About tab reads the bundle rather
/// than a literal, and pinning a number there would re-create the coupling it exists to remove.
/// This file is the layer where the numbers themselves are decided, so this is where they are
/// pinned. Two layers, two jobs.
///
/// Depends on `AppTargetRegistrationGuardTests` for `section(_:of:)`, `leadingID(of:)` and
/// `projectText()` — deliberately shared so the two guards cannot drift in how they read the
/// project file.
final class AppVersionGuardTests: XCTestCase {

    // MARK: - The pinned values

    /// `CURRENT_PROJECT_VERSION`. Raise this and `project.pbxproj` together, never one alone.
    static let pinnedBuildNumber = "2"

    /// `MARKETING_VERSION` — the first native release (三问 c).
    ///
    /// `1.0` is NOT technically unavailable: that submission was rejected on 2026-07-09 and
    /// never published, and the repository's own resubmission plan reuses it
    /// (`docs/MAS_RESUBMISSION_1.0.1.md`). Going to 1.1.0 is a product decision — a rewritten
    /// app is a new feature version — not a constraint. Recorded so nobody later "corrects" it
    /// back on the theory that it had to be this way.
    static let pinnedMarketingVersion = "1.1.0"

    /// Highest `CFBundleVersion` App Store Connect has accepted under this bundle id, per the
    /// maintainer's 2026-08-10 check. **Recorded, not measured.**
    ///
    /// Update protocol: after an upload succeeds, set this to the build number that was just
    /// accepted — as its own commit, separate from the next bump. Nothing mechanical enforces
    /// that; the monotonicity of this constant is held by review, and this file only checks
    /// that the pinned build number outranks whatever value is recorded here.
    static let appStoreConnectHighWaterMark = "1.0.0"

    /// The Release bundle id the whole App Store argument above is scoped to. Pinned because
    /// if it changed, the high-water mark would silently be about a different app record.
    static let releaseBundleIdentifier = "com.alotie418.sololedger"
    static let debugBundleIdentifier = "com.alotie418.sololedger.dev"

    // MARK: - Reading the app target's configurations, by object id

    struct Configuration: Equatable {
        var id: String
        var name: String
        var settings: [String: String]
    }

    static func unquoted(_ token: String) -> String {
        guard token.count >= 2, token.hasPrefix("\""), token.hasSuffix("\"") else { return token }
        return String(token.dropFirst().dropLast())
    }

    /// Every `XCBuildConfiguration` block, with its object id.
    ///
    /// Array-valued settings (`LD_RUNPATH_SEARCH_PATHS = (` … `);`) are skipped rather than
    /// mis-parsed: the opening line does not end in `;` and the closing `);` carries no ` = `,
    /// so neither can close the settings dictionary early.
    static func configurations(in text: String) -> [Configuration] {
        var out: [Configuration] = []
        var settings: [String: String] = [:]
        var name: String?
        var id: String?
        var inSettings = false

        for line in AppTargetRegistrationGuardTests.section("XCBuildConfiguration", of: text) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix("= {"), !inSettings, trimmed != "buildSettings = {" {
                id = AppTargetRegistrationGuardTests.leadingID(of: line)
                continue
            }
            if trimmed == "buildSettings = {" { inSettings = true; continue }
            if inSettings {
                if trimmed == "};" { inSettings = false; continue }
                guard let equals = trimmed.range(of: " = "), trimmed.hasSuffix(";") else { continue }
                // BOTH sides get unquoted. pbxproj quotes any KEY containing special
                // characters, so a condition-qualified setting arrives as
                // `"CURRENT_PROJECT_VERSION[sdk=macosx*]"` — leaving the quotes on made
                // `hasPrefix("CURRENT_PROJECT_VERSION")` false and turned the guard against
                // that exact shape into a no-op. Measured: the shape passed until this line.
                let key = Self.unquoted(String(trimmed[trimmed.startIndex..<equals.lowerBound]))
                let value = Self.unquoted(
                    String(trimmed[equals.upperBound..<trimmed.index(before: trimmed.endIndex)]))
                settings[key] = value
                continue
            }
            if trimmed.hasPrefix("name = "), trimmed.hasSuffix(";") {
                name = String(trimmed.dropFirst("name = ".count).dropLast())
                continue
            }
            if trimmed == "};", let configName = name, let configID = id {
                out.append(Configuration(id: configID, name: configName, settings: settings))
                settings = [:]; name = nil; id = nil
            }
        }
        return out
    }

    /// `PBXNativeTarget` name → its `buildConfigurationList` object id.
    static func configurationListIDsByTarget(in text: String) -> [String: String] {
        var out: [String: String] = [:]
        var list: String?
        for line in AppTargetRegistrationGuardTests.section("PBXNativeTarget", of: text) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("buildConfigurationList = ") {
                list = String(trimmed.dropFirst("buildConfigurationList = ".count).prefix(24))
                continue
            }
            if trimmed.hasPrefix("name = "), trimmed.hasSuffix(";"), let listID = list {
                out[String(trimmed.dropFirst("name = ".count).dropLast())] = listID
                list = nil
            }
        }
        return out
    }

    /// `XCConfigurationList` object id → the configuration ids it holds.
    static func configurationIDsByList(in text: String) -> [String: [String]] {
        var out: [String: [String]] = [:]
        var current: String?
        var collecting = false
        for line in AppTargetRegistrationGuardTests.section("XCConfigurationList", of: text) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix("= {") { current = AppTargetRegistrationGuardTests.leadingID(of: line); continue }
            if trimmed == "buildConfigurations = (" { collecting = true; continue }
            if collecting {
                if trimmed == ");" { collecting = false; continue }
                if let listID = current, let configID = AppTargetRegistrationGuardTests.leadingID(of: line) {
                    out[listID, default: []].append(configID)
                }
            }
        }
        return out
    }

    /// The configurations the **SoloLedger app target** actually builds with, resolved through
    /// object ids. Never selected by configuration name or by "declares a version key".
    static func appTargetConfigurations(in text: String) -> [Configuration] {
        guard let listID = configurationListIDsByTarget(in: text)["SoloLedger"],
              let ids = configurationIDsByList(in: text)[listID]
        else { return [] }
        let wanted = Set(ids)
        return configurations(in: text).filter { wanted.contains($0.id) }
    }

    /// Blocks that spell out a version, however they are (or are not) wired up.
    static func versionBearingConfigurations(in text: String) -> [Configuration] {
        configurations(in: text).filter { $0.settings["MARKETING_VERSION"] != nil }
    }

    /// Fail-closed accessor: every pin assertion goes through this, so a parse that returns
    /// nothing fails loudly instead of vacuously satisfying a `for` loop over an empty set.
    func requireAppTargetConfigurations(
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> [Configuration] {
        let configs = Self.appTargetConfigurations(in: try AppTargetRegistrationGuardTests.projectText())
        XCTAssertEqual(configs.count, 2, """
            expected exactly two configurations on the SoloLedger target, resolved through \
            PBXNativeTarget → buildConfigurationList → XCConfigurationList. Got \
            \(configs.map { "\($0.id) \($0.name)" }). A version assertion over an empty set \
            passes without checking anything, so this stops here.
            """, file: file, line: line)
        return configs
    }

    // MARK: - Apple's CFBundleVersion ordering, modelled

    /// Period-separated integers, leftmost first, missing components read as 0.
    /// Non-numeric or unparsable components make the comparison undefined — callers must treat
    /// `nil` as a failure, never as "equal".
    static func compareBuildNumbers(_ lhs: String, _ rhs: String) -> ComparisonResult? {
        let left = lhs.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        let right = rhs.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !left.contains(nil), !right.contains(nil) else { return nil }
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? (left[index] ?? 0) : 0
            let r = index < right.count ? (right[index] ?? 0) : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    // MARK: - Preconditions: the blocks are the target's, and nothing else declares a version

    func testTheAppTargetsConfigurationsAreResolvedThroughObjectIDs() throws {
        let configs = try requireAppTargetConfigurations()
        XCTAssertEqual(configs.map(\.name).sorted(), ["Debug", "Release"])
        for config in configs {
            XCTAssertEqual(config.settings["PRODUCT_NAME"], "SoloLedger",
                           "\(config.id) \(config.name) is not an app-target configuration")
        }
    }

    /// Both directions: no version-bearing block outside the target's list (an orphan that
    /// looks right and builds nothing), and no target configuration without the keys.
    func testTheVersionKeysLiveExactlyInTheAppTargetsConfigurations() throws {
        let text = try AppTargetRegistrationGuardTests.projectText()
        let wired = Set(Self.appTargetConfigurations(in: text).map(\.id))
        let bearing = Set(Self.versionBearingConfigurations(in: text).map(\.id))
        XCTAssertEqual(bearing, wired, """
            version keys and the app target's configurations have come apart. \
            Declaring versions but not built by the target: \(bearing.subtracting(wired).sorted()) \
            — an orphaned block still reading 1.1.0 while the target builds something else. \
            Built by the target but declaring no version: \(wired.subtracting(bearing).sorted()).
            """)
        XCTAssertEqual(wired.count, 2)
    }

    /// A conditional variant (`CURRENT_PROJECT_VERSION[sdk=macosx*]`) is a different key to this
    /// parser and would override the unconditional one at build time — the pins would still
    /// match while the build used another number.
    func testNoConditionalVariantShadowsTheVersionKeys() throws {
        for config in try requireAppTargetConfigurations() {
            let shadowed = config.settings.keys.filter {
                ($0.hasPrefix("CURRENT_PROJECT_VERSION") || $0.hasPrefix("MARKETING_VERSION"))
                    && $0.contains("[")
            }
            XCTAssertEqual(shadowed.sorted(), [], """
                \(config.name) declares a condition-qualified version setting \(shadowed.sorted()), \
                which overrides the plain one for matching builds. The pins below would keep \
                matching a value nothing uses.
                """)
        }
    }

    // MARK: - The link from build settings to the shipped bundle

    /// `<key>K</key><string>V</string>` pairs, whitespace-tolerant.
    static func plistPairs(in text: String) -> [String: String] {
        let pattern = #"<key>([^<]+)</key>\s*<string>([^<]*)</string>"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [:] }
        var out: [String: String] = [:]
        let ns = text as NSString
        for match in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out[ns.substring(with: match.range(at: 1))] = ns.substring(with: match.range(at: 2))
        }
        return out
    }

    /// **The link an earlier draft left in a comment.** Without this, the build settings can be
    /// perfectly pinned while the bundle ships something else — by replacing a substitution
    /// with a literal, by swapping the two, or by pointing the target at another plist.
    func testTheInfoPlistCarriesTheBuildSettingsThroughToTheBundle() throws {
        let plistURL = AppTargetRegistrationGuardTests.packageRoot()
            .appendingPathComponent("App/Support/Info.plist")
        let pairs = Self.plistPairs(in: try String(contentsOf: plistURL, encoding: .utf8))
        XCTAssertGreaterThan(pairs.count, 5, "the Info.plist scan came back empty")

        // Exact equality, not `contains`: `contains` would accept the two being swapped.
        XCTAssertEqual(pairs["CFBundleShortVersionString"], "$(MARKETING_VERSION)", """
            CFBundleShortVersionString no longer resolves from MARKETING_VERSION. Everything \
            this file pins is about a value that then reaches the bundle through this line.
            """)
        XCTAssertEqual(pairs["CFBundleVersion"], "$(CURRENT_PROJECT_VERSION)", """
            CFBundleVersion no longer resolves from CURRENT_PROJECT_VERSION.
            """)

        for config in try requireAppTargetConfigurations() {
            XCTAssertEqual(config.settings["INFOPLIST_FILE"], "Support/Info.plist",
                           "\(config.name) builds a different Info.plist than the one checked above")
            XCTAssertNil(config.settings["GENERATE_INFOPLIST_FILE"], """
                \(config.name) would synthesise its Info.plist, so the file checked above is \
                not necessarily what ships.
                """)
        }
    }

    // MARK: - (a) the scheme

    /// The rule, in one place, so the real-file test and its counterexamples cannot diverge.
    /// No leading zero: `01` and `1` are one build number to Apple and two strings in a diff.
    static func isBarePositiveInteger(_ value: String) -> Bool {
        value.range(of: #"\A[1-9][0-9]*\z"#, options: .regularExpression) != nil
    }

    func testTheBuildNumberIsABarePositiveInteger() throws {
        for config in try requireAppTargetConfigurations() {
            let build = try XCTUnwrap(config.settings["CURRENT_PROJECT_VERSION"])
            XCTAssertTrue(Self.isBarePositiveInteger(build), """
                \(config.name): CURRENT_PROJECT_VERSION is "\(build)", which is not a bare \
                positive integer. D2 chose a plain counter to keep the comparison obvious: a \
                bare "1" and the already-accepted "1.0.0" compare EQUAL (missing components \
                read as 0), and equal is as unusable as lower. Counting from 2 removes the \
                question entirely.
                """)
        }
    }

    // MARK: - (b) the two configurations agree

    func testDebugAndReleaseDeclareTheSameVersions() throws {
        let configs = try requireAppTargetConfigurations()
        for key in ["CURRENT_PROJECT_VERSION", "MARKETING_VERSION"] {
            let values = Set(configs.compactMap { $0.settings[key] })
            XCTAssertEqual(values.count, 1, """
                Debug and Release disagree on \(key): \
                \(configs.map { "\($0.name)=\($0.settings[key] ?? "—")" }.sorted()). A build is \
                identified by these two strings alone; letting the configurations drift means \
                the number you tested is not the number you shipped.
                """)
        }
    }

    // MARK: - (c) and (d) the ratchet

    func testTheBuildNumberMatchesThePinnedValue() throws {
        for config in try requireAppTargetConfigurations() {
            XCTAssertEqual(config.settings["CURRENT_PROJECT_VERSION"], Self.pinnedBuildNumber, """
                \(config.name): the build number moved without this guard moving with it. \
                Raising it is a deliberate edit in ONE pull request — project.pbxproj's two \
                configurations and `pinnedBuildNumber` here — because an uploaded build number \
                can never be reused. Record the accepted value in \
                `appStoreConnectHighWaterMark` afterwards, separately.
                """)
        }
    }

    func testTheMarketingVersionMatchesThePinnedValue() throws {
        for config in try requireAppTargetConfigurations() {
            XCTAssertEqual(config.settings["MARKETING_VERSION"], Self.pinnedMarketingVersion, """
                \(config.name): MARKETING_VERSION moved without this guard moving with it. \
                1.1.0 is a product decision (三问 c) — see `pinnedMarketingVersion` for why \
                "1.0 is unavailable" would be the wrong reason to give.
                """)
        }
    }

    func testTheBundleIdentifiersTheAppStoreArgumentAssumes() throws {
        for config in try requireAppTargetConfigurations() {
            let expected = config.name == "Release"
                ? Self.releaseBundleIdentifier : Self.debugBundleIdentifier
            XCTAssertEqual(config.settings["PRODUCT_BUNDLE_IDENTIFIER"], expected, """
                \(config.name)'s bundle id changed. The recorded high-water mark \
                (\(Self.appStoreConnectHighWaterMark)) is scoped to \
                \(Self.releaseBundleIdentifier); under a different id it describes another app \
                record and the floor below is meaningless.
                """)
        }
    }

    /// The reason `2` clears the floor, kept executable rather than written in prose.
    func testThePinnedBuildNumberOutranksWhatAppStoreConnectHas() {
        let order = Self.compareBuildNumbers(Self.appStoreConnectHighWaterMark,
                                             Self.pinnedBuildNumber)
        XCTAssertEqual(order, .orderedAscending, """
            the pinned build number \(Self.pinnedBuildNumber) does not outrank \
            \(Self.appStoreConnectHighWaterMark), the highest build recorded as accepted under \
            \(Self.releaseBundleIdentifier). Equal counts as failing here: an already-used \
            build number cannot be uploaded again. If either constant is unparsable this also \
            fails — check the strings before checking App Store Connect.
            """)
    }

    // MARK: - The comparator is not a no-op

    func testTheComparatorImplementsAppleOrdering() {
        XCTAssertEqual(Self.compareBuildNumbers("2", "1.0.0"), .orderedDescending,
                       "a bare 2 must outrank 1.0.0 — this is the whole basis for the scheme")
        XCTAssertEqual(Self.compareBuildNumbers("1", "1.0.0"), .orderedSame,
                       "a bare 1 must read as EQUAL to 1.0.0 — the reason the count starts at 2")
        XCTAssertEqual(Self.compareBuildNumbers("1.0.1", "1.0.0"), .orderedDescending)
        XCTAssertEqual(Self.compareBuildNumbers("10", "9"), .orderedDescending,
                       "components are integers, not text — 10 must not sort below 9")
        XCTAssertEqual(Self.compareBuildNumbers("1.0", "1.0.0"), .orderedSame)
        XCTAssertEqual(Self.compareBuildNumbers("1.0.0", "2"), .orderedAscending)
        XCTAssertNil(Self.compareBuildNumbers("1.0-beta", "1"),
                     "a non-numeric component must be undefined, never silently equal")
        XCTAssertNil(Self.compareBuildNumbers("", "1"))
        XCTAssertNil(Self.compareBuildNumbers("1..2", "1"))
        XCTAssertNil(Self.compareBuildNumbers("99999999999999999999", "2"),
                     "an unparsable (overflowing) component must be undefined, not ordered")
    }

    // MARK: - The scanner is not a no-op

    func testTheConfigurationScannerReadsRealSettingsAndInventsNone() throws {
        let configs = try requireAppTargetConfigurations()
        for config in configs {
            XCTAssertNil(config.settings["THIS_SETTING_HAS_NEVER_EXISTED"],
                         "the scanner invents settings")
            XCTAssertEqual(config.id.count, 24, "configuration object ids must be captured")
        }
        // Quoted values must arrive unquoted, or every comparison silently fails. Asserted on
        // the shape rather than on a specific path: 2c is the packaging chapter and the
        // entitlements filenames are something it has reason to change.
        let quoted = configs.flatMap { $0.settings.values }.filter {
            $0.hasPrefix("\"") || $0.hasSuffix("\"")
        }
        XCTAssertEqual(quoted, [], "setting values must be unquoted by the scanner")
        XCTAssertTrue(configs.contains { $0.settings["CODE_SIGN_ENTITLEMENTS"]?.isEmpty == false },
                      "at least one configuration must carry a (quoted-in-file) entitlements path")
    }

    // MARK: - Reverse proof: each defect shape, on synthetic text

    /// Values default to the pins, so a bump never turns these into false failures.
    static func fixture(debugBuild: String = pinnedBuildNumber,
                        releaseBuild: String = pinnedBuildNumber,
                        debugMarketing: String = pinnedMarketingVersion,
                        releaseMarketing: String = pinnedMarketingVersion,
                        releaseConfigID: String = "EB5600000000000000000002",
                        listReleaseID: String? = nil) -> String {
        """
        /* Begin PBXNativeTarget section */
        \t\t7A5500000000000000000005 /* SoloLedger */ = {
        \t\t\tisa = PBXNativeTarget;
        \t\t\tbuildConfigurationList = 89A500000000000000000009 /* Build configuration list */;
        \t\t\tname = SoloLedger;
        \t\t};
        /* End PBXNativeTarget section */
        /* Begin XCConfigurationList section */
        \t\t89A500000000000000000009 /* Build configuration list */ = {
        \t\t\tisa = XCConfigurationList;
        \t\t\tbuildConfigurations = (
        \t\t\t\tC94300000000000000000001 /* Debug */,
        \t\t\t\t\(listReleaseID ?? releaseConfigID) /* Release */,
        \t\t\t);
        \t\t};
        /* End XCConfigurationList section */
        /* Begin XCBuildConfiguration section */
        \t\tC94300000000000000000001 /* Debug */ = {
        \t\t\tisa = XCBuildConfiguration;
        \t\t\tbuildSettings = {
        \t\t\t\tCURRENT_PROJECT_VERSION = \(debugBuild);
        \t\t\t\tLD_RUNPATH_SEARCH_PATHS = (
        \t\t\t\t\t"$(inherited)",
        \t\t\t\t);
        \t\t\t\tMARKETING_VERSION = \(debugMarketing);
        \t\t\t\tPRODUCT_NAME = SoloLedger;
        \t\t\t};
        \t\t\tname = Debug;
        \t\t};
        \t\t\(releaseConfigID) /* Release */ = {
        \t\t\tisa = XCBuildConfiguration;
        \t\t\tbuildSettings = {
        \t\t\t\tCURRENT_PROJECT_VERSION = \(releaseBuild);
        \t\t\t\tMARKETING_VERSION = \(releaseMarketing);
        \t\t\t\tPRODUCT_NAME = SoloLedger;
        \t\t\t};
        \t\t\tname = Release;
        \t\t};
        /* End XCBuildConfiguration section */
        """
    }

    func testTheFixtureAtThePinnedValuesIsClean() {
        let configs = Self.appTargetConfigurations(in: Self.fixture())
        XCTAssertEqual(configs.map(\.name).sorted(), ["Debug", "Release"])
        XCTAssertEqual(Set(configs.map { $0.settings["CURRENT_PROJECT_VERSION"] }),
                       [Self.pinnedBuildNumber])
        XCTAssertEqual(Set(configs.map { $0.settings["MARKETING_VERSION"] }),
                       [Self.pinnedMarketingVersion])
        // …and the array-valued setting in the Debug block did not derail the parse.
        XCTAssertEqual(configs.first { $0.name == "Debug" }?.settings["PRODUCT_NAME"], "SoloLedger")
    }

    /// (a) The dotted form D2 exists to forbid — including the exact string the Electron line
    /// used — plus the shapes a laxer rule would accept.
    func testTheBarePositiveIntegerRuleRejectsEveryOtherShape() {
        for bad in ["1.0.1", "1.0", "0", "01", "2.0", "", "two", " 2", "2 ", "+2", "-2", "2;", "2\n"] {
            XCTAssertFalse(Self.isBarePositiveInteger(bad),
                           "\"\(bad)\" must not pass the bare-positive-integer rule")
        }
        for good in ["1", "2", "10", "99", "1000"] {
            XCTAssertTrue(Self.isBarePositiveInteger(good), "\"\(good)\" must pass")
        }
        XCTAssertTrue(Self.isBarePositiveInteger(Self.pinnedBuildNumber),
                      "the pinned value must satisfy the rule it is pinned under")
    }

    func testTheRealProjectIsCheckedThroughThatSameRule() throws {
        let builds = try requireAppTargetConfigurations()
            .compactMap { $0.settings["CURRENT_PROJECT_VERSION"] }
        XCTAssertEqual(builds.count, 2, "both configurations must supply a build number to check")
        XCTAssertTrue(builds.allSatisfy(Self.isBarePositiveInteger))
    }

    /// (b) The two configurations drifting apart.
    func testConfigurationsThatDisagreeAreDetected() {
        let other = Self.pinnedBuildNumber + "0"      // never equal to the pin, whatever it is
        let builds = Self.appTargetConfigurations(in: Self.fixture(releaseBuild: other))
        XCTAssertEqual(Set(builds.compactMap { $0.settings["CURRENT_PROJECT_VERSION"] }).count, 2,
                       "a Debug/Release disagreement must be visible to the guard")
        let marketing = Self.appTargetConfigurations(
            in: Self.fixture(releaseMarketing: Self.pinnedMarketingVersion + "-rc"))
        XCTAssertEqual(Set(marketing.compactMap { $0.settings["MARKETING_VERSION"] }).count, 2)
    }

    /// (c)/(d) The ratchet: anything other than the pinned strings is a mismatch — in BOTH
    /// directions, because an unannounced bump is as unrecoverable as a revert.
    func testAnyValueOtherThanThePinnedOneIsAMismatch() {
        let lower = "1"
        let higher = Self.pinnedBuildNumber + "0"
        for value in [lower, higher] {
            let configs = Self.appTargetConfigurations(
                in: Self.fixture(debugBuild: value, releaseBuild: value))
            XCTAssertNotEqual(configs.first?.settings["CURRENT_PROJECT_VERSION"],
                              Self.pinnedBuildNumber, "\"\(value)\" must not read as pinned")
        }
        let oldMarketing = Self.appTargetConfigurations(
            in: Self.fixture(debugMarketing: "1.0.0", releaseMarketing: "1.0.0"))
        XCTAssertNotEqual(oldMarketing.first?.settings["MARKETING_VERSION"],
                          Self.pinnedMarketingVersion)
    }

    /// **The orphan shape.** The Release block still spells out the right version; the target's
    /// configuration list points at a different object. Selecting by `name = Release;` would
    /// call this fine — following the id does not.
    func testAnOrphanedConfigurationIsNotMistakenForTheTargets() {
        let orphaned = Self.fixture(listReleaseID: "F34900000000000000000099")
        let wired = Self.appTargetConfigurations(in: orphaned)
        XCTAssertEqual(wired.map(\.name), ["Debug"],
                       "only the configurations the target's list names may count")
        let bearing = Self.versionBearingConfigurations(in: orphaned)
        XCTAssertEqual(bearing.count, 2, "the orphan is still present in the file")
        XCTAssertNotEqual(Set(bearing.map(\.id)), Set(wired.map(\.id)), """
            the two sets must differ — that difference is exactly what \
            testTheVersionKeysLiveExactlyInTheAppTargetsConfigurations reports
            """)
    }

    /// The condition-qualified shape, which pbxproj writes with a QUOTED key. The guard against
    /// it was a no-op until the parser unquoted keys — proven here so it stays proven.
    func testAConditionQualifiedVersionSettingIsSeenAsSuchAKey() {
        let text = Self.fixture().replacingOccurrences(
            of: "\t\t\t\tPRODUCT_NAME = SoloLedger;",
            with: "\t\t\t\t\"CURRENT_PROJECT_VERSION[sdk=macosx*]\" = 1;\n\t\t\t\tPRODUCT_NAME = SoloLedger;")
        let configs = Self.appTargetConfigurations(in: text)
        let shadowed = configs.flatMap { config in
            config.settings.keys.filter { $0.hasPrefix("CURRENT_PROJECT_VERSION") && $0.contains("[") }
        }
        XCTAssertEqual(shadowed.count, 2, """
            a quoted, condition-qualified key must arrive unquoted so the prefix test can see \
            it. Found keys: \(configs.flatMap { $0.settings.keys }.sorted())
            """)
        // …while the plain key is untouched, which is why the pin assertions alone miss this.
        XCTAssertEqual(Set(configs.compactMap { $0.settings["CURRENT_PROJECT_VERSION"] }),
                       [Self.pinnedBuildNumber])
    }

    func testAnEmptyProjectTextYieldsNoConfigurations() {
        XCTAssertTrue(Self.configurations(in: "").isEmpty)
        XCTAssertTrue(Self.appTargetConfigurations(in: "").isEmpty)
        XCTAssertTrue(Self.plistPairs(in: "").isEmpty)
    }
}
