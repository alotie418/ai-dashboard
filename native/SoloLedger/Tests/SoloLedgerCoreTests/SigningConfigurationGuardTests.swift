import Foundation
import XCTest

/// 2c-5 — the Release signing configuration, and the rule that the Team ID never enters this
/// repository.
///
/// ## What is and is not a secret here
///
/// The signing identity name (`Apple Distribution`) and the provisioning profile name
/// (`SoloLedger MAS 1.0.1`) are committed on purpose: they are labels, they have to match what
/// the archive step asks for, and pinning them is what makes a silent change visible. The
/// **Team ID is held out** — `DEVELOPMENT_TEAM` stays empty in `project.pbxproj` and
/// `scripts/archive-mas.sh` injects it from the environment at build time. That is a decision
/// recorded in the packaging chapter's decision book, and `docs/MAS_SUBMISSION.md` has carried
/// the same rule ("no certificate, password, Team ID or provisioning profile in the repository")
/// since long before this round — a rule the repository was, until now, violating in two files.
///
/// ## How the Team ID is detected without storing it
///
/// A guard that pinned the real value — or a hash of it, which for a ten-character alphanumeric
/// string is a few seconds of brute force — would re-introduce exactly what this round removes.
/// So nothing derived from the value is stored. The detection is **by shape**: an Apple Team ID
/// is exactly ten characters of uppercase letters and digits, containing at least one of each.
///
/// Measured before adopting it: across every tracked text file, that shape matched **only** the
/// two occurrences this round removed. It now matches nothing, so the rule can be "the set is
/// empty" rather than "the set does not contain <value>". ``sanctionedTokens`` exists for the
/// day some unrelated ten-character token legitimately needs to be committed; it is empty, and
/// adding to it is a decision someone has to defend rather than a silent pass.
///
/// The counterexample values below are assembled from fragments at runtime rather than written
/// as literals, because a literal of the right shape in this file would make the guard fail on
/// itself — the failure mode this design exists to avoid.
final class SigningConfigurationGuardTests: XCTestCase {

    // MARK: - Pinned signing configuration (not secrets)

    static let expectedIdentity = "Apple Distribution"
    static let expectedProfile = "SoloLedger MAS 1.0.1"
    static let expectedStyle = "Manual"

    /// Ten-character tokens that are allowed to be committed despite matching the Team ID shape.
    /// Empty by design.
    static let sanctionedTokens: Set<String> = []

    // MARK: - (1) the Team ID is not in the project file

    func testTheProjectFileDeclaresNoDevelopmentTeam() throws {
        let text = try AppTargetRegistrationGuardTests.projectText()
        let declared = AppVersionGuardTests.configurations(in: text)
            .compactMap { config -> String? in
                guard let team = config.settings["DEVELOPMENT_TEAM"], !team.isEmpty else { return nil }
                return "\(config.name) (\(config.id))"
            }
        XCTAssertEqual(declared.sorted(), [], """
            project.pbxproj declares a DEVELOPMENT_TEAM in \(declared.sorted()). The Team ID is \
            injected at build time by scripts/archive-mas.sh and must not be committed — see \
            docs/MAS_SUBMISSION.md's rule on credentials. Empty or absent are both fine; a value \
            is not.
            """)
    }

    // MARK: - (3) the Release signing configuration

    func testTheAppTargetsReleaseConfigurationSignsForDistribution() throws {
        let configs = AppVersionGuardTests.appTargetConfigurations(
            in: try AppTargetRegistrationGuardTests.projectText())
        XCTAssertEqual(configs.count, 2, "expected the app target's two configurations")
        let release = try XCTUnwrap(configs.first { $0.name == "Release" })

        XCTAssertEqual(release.settings["CODE_SIGN_IDENTITY"], Self.expectedIdentity, """
            the Release configuration no longer signs with \(Self.expectedIdentity). Mac App \
            Store submissions are signed with that identity; ad-hoc ("-") produces a package \
            App Store Connect will not accept.
            """)
        XCTAssertEqual(release.settings["CODE_SIGN_STYLE"], Self.expectedStyle, """
            Release must sign manually. Automatic signing asks Xcode to pick a profile from the \
            developer account, which needs the Team ID that this repository deliberately lacks — \
            it would fail on every machine that has not signed in, and silently pick a different \
            profile on the ones that have.
            """)
        XCTAssertEqual(release.settings["PROVISIONING_PROFILE_SPECIFIER"], Self.expectedProfile, """
            the Release provisioning profile name changed. It must match the profile the archive \
            step supplies; a mismatch fails at signing time, which is the last place anyone \
            wants to discover it.
            """)
    }

    /// Debug is untouched by this round, and must stay untouched: it signs ad-hoc so that
    /// building and testing needs no certificates at all.
    func testDebugStillSignsAdHocSoNoCertificateIsNeededToBuild() throws {
        let configs = AppVersionGuardTests.appTargetConfigurations(
            in: try AppTargetRegistrationGuardTests.projectText())
        let debug = try XCTUnwrap(configs.first { $0.name == "Debug" })
        XCTAssertNotEqual(debug.settings["CODE_SIGN_IDENTITY"], Self.expectedIdentity, """
            Debug picked up the distribution identity. Everyday builds and the whole CI matrix \
            would then need certificates nobody has on a runner.
            """)
        XCTAssertNil(debug.settings["PROVISIONING_PROFILE_SPECIFIER"],
                     "Debug must not require a provisioning profile")
    }

    /// The distribution identity must reach ONLY the app target. At project level it would also
    /// apply to the test bundles, and `-configuration Release` builds of those would then demand
    /// certificates — which is precisely how a later Release-compile gate would be blocked.
    func testTheDistributionIdentityIsScopedToTheAppTarget() throws {
        let text = try AppTargetRegistrationGuardTests.projectText()
        let appTargetIDs = Set(AppVersionGuardTests.appTargetConfigurations(in: text).map(\.id))
        let carriers = AppVersionGuardTests.configurations(in: text)
            .filter { $0.settings["CODE_SIGN_IDENTITY"] == Self.expectedIdentity }
        XCTAssertFalse(carriers.isEmpty, "nothing declares the distribution identity at all")
        for carrier in carriers {
            XCTAssertTrue(appTargetIDs.contains(carrier.id), """
                \(carrier.name) (\(carrier.id)) is not an app-target configuration but signs \
                with \(Self.expectedIdentity). Only the shipped app is submitted; widening this \
                makes every Release build of the test bundles need a certificate.
                """)
        }
    }

    // MARK: - (2) the Team ID is nowhere in the repository

    /// Exactly ten characters, uppercase alphanumeric, with at least one letter and one digit,
    /// and not part of a longer alphanumeric run.
    static func teamIDShapedTokens(in text: String) -> Set<String> {
        let pattern = #"(?<![A-Za-z0-9])[A-Z0-9]{10}(?![A-Za-z0-9])"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        var out: Set<String> = []
        for match in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let token = ns.substring(with: match.range)
            let hasLetter = token.contains { $0.isLetter }
            let hasDigit = token.contains { $0.isNumber }
            if hasLetter && hasDigit { out.insert(token) }
        }
        return out
    }

    /// Repo-relative paths of every tracked file, straight from git. Fails closed: a git error,
    /// or an implausibly short list, must not read as "nothing to scan".
    static func trackedFiles() throws -> [String] {
        let repoRoot = AppTargetRegistrationGuardTests.packageRoot()
            .deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "ls-files", "-z"]
        process.currentDirectoryURL = repoRoot
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "SigningConfigurationGuardTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey:
                    "`git ls-files` failed in \(repoRoot.path); the scan cannot be trusted"])
        }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\0", omittingEmptySubsequences: true)
            .map(String.init)
    }

    private static let binaryExtensions: Set<String> = [
        "png", "icns", "db", "jpg", "jpeg", "ico", "pdf", "zip", "provisionprofile", "xctestplan",
    ]

    func testNoTrackedFileCarriesATeamIDShapedToken() throws {
        let repoRoot = AppTargetRegistrationGuardTests.packageRoot()
            .deletingLastPathComponent().deletingLastPathComponent()
        let files = try Self.trackedFiles()
        XCTAssertGreaterThan(files.count, 200, """
            `git ls-files` returned only \(files.count) paths — too few to be this repository. \
            The scan below would pass vacuously, so it stops here instead.
            """)

        var offenders: [String: Set<String>] = [:]
        var scanned = 0
        for path in files {
            let ext = (path as NSString).pathExtension.lowercased()
            if Self.binaryExtensions.contains(ext) { continue }
            guard let text = try? String(contentsOf: repoRoot.appendingPathComponent(path),
                                         encoding: .utf8) else { continue }
            scanned += 1
            let hits = Self.teamIDShapedTokens(in: text).subtracting(Self.sanctionedTokens)
            if !hits.isEmpty { offenders[path] = hits }
        }

        XCTAssertGreaterThan(scanned, 200, "only \(scanned) files were readable as text")
        XCTAssertEqual(offenders.keys.sorted(), [], """
            \(offenders.count) tracked file(s) carry a token shaped like an Apple Team ID: \
            \(offenders.keys.sorted()). The Team ID must not be committed — inject it at build \
            time (scripts/archive-mas.sh reads SOLOLEDGER_TEAM_ID). If one of these really is an \
            unrelated ten-character token, add it to `sanctionedTokens` with a reason; the list \
            is empty today and should stay short. Values are not printed here on purpose.
            """)
    }

    /// The two files this round cleaned, pinned by their placeholder rather than by absence —
    /// absence alone would also be satisfied by deleting the setting.
    func testTheTwoFormerPlaintextPointsHoldPlaceholders() throws {
        let repoRoot = AppTargetRegistrationGuardTests.packageRoot()
            .deletingLastPathComponent().deletingLastPathComponent()

        let entitlements = try String(
            contentsOf: repoRoot.appendingPathComponent("build/entitlements.mas.plist"),
            encoding: .utf8)
        XCTAssertTrue(entitlements.contains("<string>TEAM_ID.com.alotie418.sololedger</string>"), """
            build/entitlements.mas.plist no longer carries the TEAM_ID placeholder in its \
            application-groups entry. That file is the Electron MAS line's, frozen by decision \
            D6; the placeholder is how it stays free of the real value.
            """)

        let resubmission = try String(
            contentsOf: repoRoot.appendingPathComponent("docs/MAS_RESUBMISSION_1.0.1.md"),
            encoding: .utf8)
        XCTAssertTrue(resubmission.contains("| Team ID | **不入库**"), """
            the Team ID row in docs/MAS_RESUBMISSION_1.0.1.md no longer states that the value is \
            kept out of the repository.
            """)
    }

    // MARK: - The shape predicate, proven against counterexamples

    /// Assembled at runtime: a ten-character literal of this shape, written out in this file,
    /// would be caught by the very scan above.
    private static func shapedSample() -> String { "AB12" + "CD34" + "EF" }

    func testTheShapePredicateMatchesTeamIDsAndNothingElse() {
        XCTAssertEqual(Self.shapedSample().count, 10, "the assembled sample must be ten characters")
        XCTAssertEqual(Self.teamIDShapedTokens(in: "team " + Self.shapedSample() + " end"),
                       [Self.shapedSample()], "a bare ten-character mixed token must be found")

        for miss in ["TEAM_ID",                       // the placeholder
                     "1234567890",                    // digits only
                     "ABCDEFGHIJ",                    // letters only
                     "ab12cd34ef",                    // lowercase
                     "AB12CD34E",                     // nine
                     "AB12CD34EFG",                   // eleven
                     "2147483647",                    // a plain integer that appears in pbxproj
                     "MIGRATIONS"] {                  // an all-caps identifier
            XCTAssertTrue(Self.teamIDShapedTokens(in: "x \(miss) y").isEmpty,
                          "\"\(miss)\" must not be treated as a Team ID")
        }

        // Embedded in a longer alphanumeric run — e.g. a hex object id — must not match.
        let embedded = "A" + Self.shapedSample() + "9"
        XCTAssertTrue(Self.teamIDShapedTokens(in: embedded).isEmpty,
                      "a token inside a longer run is not a bare Team ID")

        // …but the app-group shape (`<id>.com.alotie418.sololedger`) IS a bare token, because
        // `.` ends the run. That is the exact form this round removed.
        let appGroup = Self.shapedSample() + ".com.alotie418.sololedger"
        XCTAssertEqual(Self.teamIDShapedTokens(in: appGroup), [Self.shapedSample()])
    }

    func testTheScanReportsAFileThatCarriesOneAndIgnoresOneThatDoesNot() {
        XCTAssertEqual(Self.teamIDShapedTokens(in: "nothing here at all"), [])
        let dirty = "<string>" + Self.shapedSample() + ".com.alotie418.sololedger</string>"
        XCTAssertEqual(Self.teamIDShapedTokens(in: dirty), [Self.shapedSample()])
        // The sanctioned list is what turns a hit into a pass, so prove it does.
        XCTAssertEqual(Self.teamIDShapedTokens(in: dirty).subtracting([Self.shapedSample()]), [])
    }

    func testTheTrackedFileListIsRealAndLarge() throws {
        let files = try Self.trackedFiles()
        XCTAssertGreaterThan(files.count, 200)
        XCTAssertTrue(files.contains("native/SoloLedger/App/SoloLedger.xcodeproj/project.pbxproj"),
                      "the tracked-file list does not look like this repository")
        XCTAssertFalse(files.contains("ThisFileHasNeverBeenTracked.txt"))
        XCTAssertTrue(files.contains("native/SoloLedger/scripts/archive-mas.sh"),
                      "the archive script must be tracked, or the export flow is not committed")
        XCTAssertTrue(files.contains("native/SoloLedger/App/ExportOptions.plist"))
    }

    // MARK: - The export template stays a template

    func testTheExportOptionsTemplateStillCarriesItsPlaceholder() throws {
        let repoRoot = AppTargetRegistrationGuardTests.packageRoot()
            .deletingLastPathComponent().deletingLastPathComponent()
        let template = try String(
            contentsOf: repoRoot.appendingPathComponent("native/SoloLedger/App/ExportOptions.plist"),
            encoding: .utf8)
        XCTAssertTrue(template.contains("__TEAM_ID__"), """
            App/ExportOptions.plist lost its __TEAM_ID__ placeholder. archive-mas.sh refuses to \
            export when the placeholder is missing, so this would break the flow — and if it was \
            replaced by a real value, it would also commit the Team ID.
            """)
        XCTAssertTrue(template.contains("<string>\(Self.expectedProfile)</string>"),
                      "the export template's profile name must match the project's")
        XCTAssertTrue(template.contains("<string>\(Self.expectedIdentity)</string>"),
                      "the export template's signing certificate must match the project's")
    }
}
