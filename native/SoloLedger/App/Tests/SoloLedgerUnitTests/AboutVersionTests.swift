import XCTest
@testable import SoloLedger

/// 2c-1 — the About tab must report the version the build actually carries.
///
/// Before this round `SettingsView` drew `"1.0.0 (prototype)"` and `"macOS 13.0+"` as string
/// literals. Both were wrong in the same silent way: raising `MARKETING_VERSION`,
/// `CURRENT_PROJECT_VERSION` or `MACOSX_DEPLOYMENT_TARGET` changed the shipped package but not
/// the screen, and no test could tell, because nothing connected the two.
///
/// ## Why the lookup is injected rather than read from `Bundle.main`
///
/// A test that compares `AppBundleInfo.versionText()` against `Bundle.main`'s own keys passes
/// over a hardcoded string just as happily as over a correct implementation — both sides would
/// then be constants this file has no way to distinguish. Feeding a dictionary that exists
/// nowhere in the product is the only assertion that can fail for the original defect.
/// ``testTheShippedBundleSuppliesEveryKeyTheAboutTabReads`` then closes the other half against
/// the REAL host bundle, so the pair covers both "does it read the dictionary" and "does the
/// dictionary have anything to read".
final class AboutVersionTests: XCTestCase {

    /// A dictionary the product cannot know, so a literal cannot reproduce it.
    private static let fake: [String: String] = [
        "CFBundleShortVersionString": "9.9.9",
        "CFBundleVersion": "4242",
        "LSMinimumSystemVersion": "26.4",
    ]

    private static func lookup(_ key: String) -> String? { fake[key] }
    private static func empty(_: String) -> String? { nil }

    // MARK: - The values come from the dictionary

    func testVersionTextIsBuiltFromTheTwoInfoDictionaryVersionKeys() {
        XCTAssertEqual(AppBundleInfo.versionText(Self.lookup), "9.9.9 (4242)",
                       "the About version must be the bundle's short version and build number")
    }

    func testMinimumSystemTextIsBuiltFromTheDeploymentTargetKey() {
        XCTAssertEqual(AppBundleInfo.minimumSystemText(Self.lookup), "macOS 26.4+",
                       "the minimum-OS row must follow LSMinimumSystemVersion")
    }

    /// A bundle missing the keys must say so rather than invent a number. `?` is never seen in
    /// a real build; what matters is that the failure mode is not "print a plausible version".
    func testMissingKeysDegradeInsteadOfInventingAVersion() {
        XCTAssertEqual(AppBundleInfo.versionText(Self.empty), "? (?)")
        XCTAssertEqual(AppBundleInfo.minimumSystemText(Self.empty), "?")
    }

    /// An empty string is a present-but-useless value, and `macOS +` would be worse than `?`.
    func testAnEmptyDeploymentTargetIsTreatedAsAbsent() {
        XCTAssertEqual(AppBundleInfo.minimumSystemText { _ in "" }, "?")
    }

    // MARK: - The shipped bundle really carries them

    /// The other half of the pair: the host app under test IS the product bundle, so this
    /// proves the three `$(…)` substitutions in `App/Support/Info.plist` resolve to something.
    /// Deliberately asserts no specific number — pinning `1.1.0` here would make every version
    /// bump a test edit, which is the coupling this round exists to remove.
    func testTheShippedBundleSuppliesEveryKeyTheAboutTabReads() throws {
        for key in ["CFBundleShortVersionString", "CFBundleVersion", "LSMinimumSystemVersion"] {
            let value = try XCTUnwrap(AppBundleInfo.infoValue(key),
                                      "\(key) is missing from the shipped Info.plist")
            XCTAssertFalse(value.isEmpty, "\(key) is present but empty")
            XCTAssertFalse(value.hasPrefix("$("),
                           "\(key) reached the bundle unsubstituted: \(value)")
        }
        XCTAssertNotEqual(AppBundleInfo.versionText(), AppBundleInfo.unknown)
        XCTAssertFalse(AppBundleInfo.versionText().contains(AppBundleInfo.unknown),
                       "the real bundle must not fall back for either version key")
        XCTAssertTrue(AppBundleInfo.minimumSystemText().hasPrefix("macOS "))
    }

    // MARK: - Nothing draws a version from anywhere else

    func testTheAboutTabHoldsNoVersionLiteralAndNoPrototypeWording() throws {
        let source = try ReportFixtureBuilder.appSource("Views/SettingsView.swift")
        XCTAssertFalse(source.contains("prototype"),
                       "a shipped build must not describe itself as a prototype")
        XCTAssertFalse(source.contains("macOS 13.0+"),
                       "the minimum-OS row must not restate the deployment target as a literal")
        XCTAssertNil(source.range(of: #""[0-9]+\.[0-9]+\.[0-9]+"#, options: .regularExpression),
                     "SettingsView must hold no version-shaped literal")
        XCTAssertTrue(source.contains("AppBundleInfo.versionText()"),
                      "the version row must read the bundle")
        XCTAssertTrue(source.contains("AppBundleInfo.minimumSystemText()"),
                      "the minimum-OS row must read the bundle")
    }

    /// Closure, not just replacement: after this round exactly ONE file in the App target may
    /// name the Info-dictionary keys. Without this, a second reader could reappear beside
    /// `AppBundleInfo` — which is precisely how the diagnostics export and the About tab came
    /// to disagree in the first place (the export read the bundle, the tab read a literal).
    func testExactlyOneAppSourceReadsTheInfoDictionary() throws {
        let root = ReportFixtureBuilder.packageRoot()
            .appendingPathComponent("Sources/SoloLedger", isDirectory: true)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(atPath: root.path))

        var owners: [String] = []
        var scanned = 0
        for case let relative as String in enumerator where relative.hasSuffix(".swift") {
            let text = try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
            scanned += 1
            // Comments are not code: this guard's own explanation names the keys too.
            let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            if code.contains("forInfoDictionaryKey") || code.contains("CFBundleShortVersionString") {
                owners.append(relative)
            }
        }

        XCTAssertGreaterThan(scanned, 20, "the scan must have found the App target's sources")
        XCTAssertEqual(owners, ["App/SoloLedgerApp.swift"], """
            the Info dictionary must be read in exactly one place; found \(owners). A second \
            reader is how the About tab and the diagnostics export drifted apart.
            """)
    }
}
