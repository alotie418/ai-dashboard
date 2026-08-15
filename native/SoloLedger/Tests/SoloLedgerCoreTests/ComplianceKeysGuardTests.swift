import XCTest

/// 2c-9 — the two compliance keys in `App/Support/Info.plist`, pinned to the decisions that
/// chose them and to the evidence those decisions rest on.
///
/// ## What is being held here
///
/// * `ITSAppUsesNonExemptEncryption = false` (D7). App Store Connect reads this key to skip the
///   export-compliance questionnaire. Declaring it is a statement about the product, so this
///   file pins the statement AND the shape it is written in.
/// * `NSHumanReadableCopyright` (D8). macOS shows this string in the standard About panel. Its
///   value is not this round's invention — it is the same holder four other declarations in
///   this repository already name, and the corroboration is asserted, not narrated.
///
/// ## Why the TYPE of the compliance key is a test and not a detail
///
/// `<string>false</string>` is a non-empty string. A reader that coerces it to a truthiness
/// value gets `true` — the exact opposite of the declaration. So the assertion is not
/// "the value reads false"; it is "the value is a Boolean, and that Boolean is false".
/// ``booleanValue(_:)`` returns `nil` for anything that is not a `CFBoolean`, which is what
/// makes the string shape a detectable failure rather than a passing accident.
/// ``testAStringTypedExportComplianceKeyIsDetected`` is the counterexample that proves it.
///
/// ## Why the plist is read TYPED, not by regex
///
/// `AppVersionGuardTests.plistPairs` scrapes `<key>…</key><string>…</string>` pairs, which is
/// the right tool for the version substitutions it checks — every one of those is a string. It
/// is the wrong tool here: it cannot see `<false/>` at all, so a guard built on it would report
/// "key missing" and "key present as a string" identically. This file parses the file with
/// `PropertyListSerialization` and keeps the types.
///
/// ## The link to the bundle
///
/// A pinned key in a file that the app target does not build is worth nothing.
/// ``AppVersionGuardTests.testTheInfoPlistCarriesTheBuildSettingsThroughToTheBundle`` already
/// asserts `INFOPLIST_FILE = Support/Info.plist` and the absence of `GENERATE_INFOPLIST_FILE`
/// on both of the app target's configurations; this file re-asserts the same link (so the two
/// compliance keys are not relying on a neighbouring file's test staying where it is) and adds
/// the piece that was missing on both sides — the **conditional variant**.
///
/// That gap is the third instance of a shape this repository has now been bitten by twice:
/// 2c-3's version keys and 2c-7's `CODE_SIGN_ENTITLEMENTS` both survived a guard because
/// `KEY[sdk=macosx*]` is a DIFFERENT key from `KEY`, so an assertion on the bare key passes
/// while the variant shadows it at build time. `INFOPLIST_FILE[sdk=macosx*]` would do exactly
/// that to everything this file pins. ``testNoConditionalVariantShadowsTheInfoPlistWiring``
/// closes it.
final class ComplianceKeysGuardTests: XCTestCase {

    // MARK: - The pinned values

    /// D7. `false` = this app contains and uses no non-exempt encryption.
    ///
    /// The three-layer evidence, each layer independently recomputable:
    ///  1. the entitlements are a closed set with no `com.apple.security.network.client`
    ///     (`EntitlementsClosedSetGuardTests`), so under the sandbox nothing can reach the
    ///     network however the code is written;
    ///  2. 2c-8's Release-sandbox verification matrix exercised the real product end to end
    ///     with no outbound traffic;
    ///  3. every `CryptoKit` call site in this package is `SHA256` used for integrity and
    ///     identity digests — hashing is not encryption in the export-control sense — and the
    ///     package imports neither `Security` nor `CommonCrypto`.
    static let exportComplianceDeclaration = false

    /// D8. Verbatim the string the already-produced MAS artifact carries, so both product
    /// lines' About panels say the same thing. See ``copyrightCorroborationSources``.
    static let pinnedCopyright = "© 2026 alotie418"

    /// Files that already name the copyright holder, none of them owned by this guard. They are
    /// what makes ``pinnedCopyright`` a RECORD of an existing decision rather than a value this
    /// round made up: if the pin and these ever disagree, one of them is wrong and the pair of
    /// tests says which.
    static let copyrightCorroborationSources = [
        "LICENSE",
        "README.md",
        "electron-builder.dmg.yml",
        "electron-builder.mas.yml",
    ]

    // MARK: - Reading

    static func repoRoot() -> URL {
        AppTargetRegistrationGuardTests.packageRoot()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    static func infoPlistURL() -> URL {
        AppTargetRegistrationGuardTests.packageRoot()
            .appendingPathComponent("App/Support/Info.plist")
    }

    /// The Info.plist as a typed dictionary. `$(…)` build-setting substitutions are ordinary
    /// strings at this stage, so the file parses without a build.
    static func infoPlist(_ url: URL? = nil) throws -> [String: Any] {
        let data = try Data(contentsOf: url ?? infoPlistURL())
        let any = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return (any as? [String: Any]) ?? [:]
    }

    /// `true`/`false` ONLY for a real plist Boolean. A string, a number, or a missing key all
    /// give `nil` — never a coerced truthiness. This is the whole point of the file.
    static func booleanValue(_ value: Any?) -> Bool? {
        guard let value else { return nil }
        guard CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    /// A copyright string is usable when it is a string with non-whitespace content. Empty and
    /// whitespace-only are the two ways this key rots without anyone noticing: macOS shows a
    /// blank copyright line and nothing errors.
    static func isUsableCopyright(_ value: Any?) -> Bool {
        guard let text = value as? String else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Fail-closed accessor: a parse that came back empty must not let every `XCTAssertEqual`
    /// below pass over `nil == nil`. Same reason `AppVersionGuardTests` gates on its
    /// configuration count before asserting anything about versions.
    func requireInfoPlist(file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let plist = try Self.infoPlist()
        XCTAssertGreaterThan(plist.count, 5, """
            the Info.plist parsed to \(plist.count) keys. Every assertion in this file is about \
            a key in that dictionary, and all of them pass vacuously over an empty one, so this \
            stops here.
            """, file: file, line: line)
        return plist
    }

    // MARK: - The real file

    func testTheInfoPlistParsesAsATypedPropertyList() throws {
        let plist = try requireInfoPlist()
        // Keys that were there before this round — proof the parse is reading the real file and
        // not a fixture that happens to carry the two new keys.
        XCTAssertEqual(plist["CFBundleShortVersionString"] as? String, "$(MARKETING_VERSION)")
        XCTAssertEqual(plist["LSApplicationCategoryType"] as? String, "public.app-category.finance")
        XCTAssertEqual(Self.booleanValue(plist["NSHighResolutionCapable"]), true,
                       "NSHighResolutionCapable is the file's other Boolean; if it stopped reading as one, the parser is wrong, not the compliance key")
    }

    func testTheExportComplianceKeyIsABooleanFalse() throws {
        let plist = try requireInfoPlist()
        let value = plist["ITSAppUsesNonExemptEncryption"]
        XCTAssertNotNil(value, """
            ITSAppUsesNonExemptEncryption is absent. Without it App Store Connect asks the \
            export-compliance question on every single upload, and the answer gets typed by \
            hand each time.
            """)
        XCTAssertEqual(Self.booleanValue(value), Self.exportComplianceDeclaration, """
            ITSAppUsesNonExemptEncryption must be a plist Boolean equal to \
            \(Self.exportComplianceDeclaration). Got \(String(describing: value)) of type \
            \(type(of: value as Any)). A <string>false</string> is a non-empty string and can \
            be read as true — that is the failure this asserts against, not a typo.
            """)
    }

    func testTheCopyrightKeyCarriesTheRepositorysOwnHolder() throws {
        let plist = try requireInfoPlist()
        let value = plist["NSHumanReadableCopyright"]
        XCTAssertTrue(Self.isUsableCopyright(value), """
            NSHumanReadableCopyright is missing, not a string, or blank. macOS shows this in \
            the standard About panel, where an empty value looks like an oversight and a \
            non-copyright looks like a slogan.
            """)
        XCTAssertEqual(value as? String, Self.pinnedCopyright, """
            NSHumanReadableCopyright is not the holder this repository already declares. The \
            pin is a record of an existing decision, not a preference — see \
            testTheCopyrightHolderIsCorroboratedByEveryOtherDeclarationInTheRepository. If the \
            holder genuinely changed, change it in all five places together.
            """)
    }

    func testTheCopyrightHolderIsCorroboratedByEveryOtherDeclarationInTheRepository() throws {
        let root = Self.repoRoot()
        for name in Self.copyrightCorroborationSources {
            let url = root.appendingPathComponent(name)
            let text = try XCTUnwrap(try? String(contentsOf: url, encoding: .utf8),
                                     "\(name) is unreadable, so it cannot corroborate anything")
            XCTAssertFalse(text.isEmpty, "\(name) is empty; an empty file `contains` nothing and would pass silently")
            XCTAssertTrue(text.contains(Self.pinnedCopyright), """
                \(name) does not contain "\(Self.pinnedCopyright)". Either the holder changed \
                in one place only, or the pinned value in this file is no longer sourced from \
                the repository and has become this guard's own invention.
                """)
        }
    }

    // MARK: - The link from the file to the bundle

    /// Re-asserted here rather than inherited: the two compliance keys must not depend on a
    /// neighbouring guard's test keeping its current scope.
    func testTheInfoPlistCheckedHereIsTheOneTheAppTargetBuilds() throws {
        let configs = Self.appTargetConfigurations()
        XCTAssertEqual(configs.count, 2, """
            expected exactly two configurations on the SoloLedger target, resolved through \
            PBXNativeTarget → buildConfigurationList → XCConfigurationList. Got \
            \(configs.map(\.name)). Asserting over an empty set proves nothing.
            """)
        for config in configs {
            XCTAssertEqual(config.settings["INFOPLIST_FILE"], "Support/Info.plist",
                           "\(config.name) builds a different Info.plist than the one this file pins")
            XCTAssertNil(config.settings["GENERATE_INFOPLIST_FILE"], """
                \(config.name) would SYNTHESISE its Info.plist, so the file this test pins is \
                not necessarily what ships.
                """)
        }
    }

    /// The 2c-3 / 2c-7 shape, third instance. A variant key shadows the bare key at build time
    /// while every assertion on the bare key stays green.
    func testNoConditionalVariantShadowsTheInfoPlistWiring() throws {
        let configs = Self.appTargetConfigurations()
        XCTAssertEqual(configs.count, 2, "fail-closed: an empty set has no offending keys and would pass")
        for config in configs {
            let offenders = Self.infoPlistShadowingKeys(in: config.settings.keys)
            XCTAssertTrue(offenders.isEmpty, """
                \(config.name) declares \(offenders.sorted()). A conditional variant of \
                INFOPLIST_FILE / GENERATE_INFOPLIST_FILE takes precedence over the \
                unconditional key, and INFOPLIST_KEY_* is merged into a synthesised plist — \
                either way what ships stops being the file this test reads.
                """)
        }
    }

    /// Any key that could redirect or overwrite the pinned Info.plist. Deliberately a prefix
    /// rule over the CONDITION bracket, not an equality: the point is to catch spellings nobody
    /// has thought of yet.
    static func infoPlistShadowingKeys<S: Sequence>(in keys: S) -> [String] where S.Element == String {
        keys.filter { key in
            if key.hasPrefix("INFOPLIST_KEY_") { return true }
            for base in ["INFOPLIST_FILE", "GENERATE_INFOPLIST_FILE", "INFOPLIST_PREPROCESS"]
            where key.hasPrefix(base) && key != base {
                return true
            }
            return false
        }
    }

    static func appTargetConfigurations() -> [AppVersionGuardTests.Configuration] {
        guard let text = try? AppTargetRegistrationGuardTests.projectText() else { return [] }
        return AppVersionGuardTests.appTargetConfigurations(in: text)
    }

    // MARK: - Counterexamples: every rule above, shown firing

    func testAMissingExportComplianceKeyIsDetected() {
        let plist: [String: Any] = ["CFBundleName": "SoloLedger"]
        XCTAssertNil(Self.booleanValue(plist["ITSAppUsesNonExemptEncryption"]),
                     "an absent key must read as nil, not as false")
        XCTAssertNotEqual(Self.booleanValue(plist["ITSAppUsesNonExemptEncryption"]),
                          Self.exportComplianceDeclaration,
                          "absent must not satisfy the pin — that is the whole failure mode")
    }

    func testAnExportComplianceKeyThatIsTrueIsDetected() {
        let plist: [String: Any] = ["ITSAppUsesNonExemptEncryption": true]
        XCTAssertEqual(Self.booleanValue(plist["ITSAppUsesNonExemptEncryption"]), true)
        XCTAssertNotEqual(Self.booleanValue(plist["ITSAppUsesNonExemptEncryption"]),
                          Self.exportComplianceDeclaration,
                          "a `true` declaration must not satisfy the pin")
    }

    func testAStringTypedExportComplianceKeyIsDetected() {
        // The shape the typed read exists for. `"false"` is a non-empty string; anything that
        // coerces it to a Bool gets `true`.
        let plist: [String: Any] = ["ITSAppUsesNonExemptEncryption": "false"]
        XCTAssertNil(Self.booleanValue(plist["ITSAppUsesNonExemptEncryption"]), """
            a string-typed declaration must read as "not a Boolean", never as false
            """)
        XCTAssertNotEqual(Self.booleanValue(plist["ITSAppUsesNonExemptEncryption"]),
                          Self.exportComplianceDeclaration)
    }

    func testAnEmptyOrWhitespaceCopyrightIsDetected() {
        XCTAssertFalse(Self.isUsableCopyright(""))
        XCTAssertFalse(Self.isUsableCopyright("   \n\t "))
        XCTAssertFalse(Self.isUsableCopyright(nil))
        XCTAssertFalse(Self.isUsableCopyright(42), "a non-string value is not a copyright line")
        XCTAssertTrue(Self.isUsableCopyright(Self.pinnedCopyright))
    }

    func testACopyrightNamingADifferentHolderIsDetected() {
        // Shaped like the real thing, different holder — the case a corroboration test that
        // only asked "is it non-empty" would wave through.
        let impostor = "© 2026 Someone Else"
        XCTAssertTrue(Self.isUsableCopyright(impostor), "it IS a usable string; that is the trap")
        XCTAssertNotEqual(impostor, Self.pinnedCopyright)
        // And the previous value of this very key, which was a slogan rather than a copyright.
        XCTAssertNotEqual("Local-first. No account, no network, no AI.", Self.pinnedCopyright)
    }

    func testTheConditionalVariantDetectorSeesTheShapeItIsFor() {
        XCTAssertEqual(Self.infoPlistShadowingKeys(in: ["INFOPLIST_FILE"]), [],
                       "the unconditional key is the one that is supposed to be there")
        XCTAssertEqual(Self.infoPlistShadowingKeys(in: ["INFOPLIST_FILE[sdk=macosx*]"]),
                       ["INFOPLIST_FILE[sdk=macosx*]"])
        XCTAssertEqual(Self.infoPlistShadowingKeys(in: ["GENERATE_INFOPLIST_FILE[arch=arm64]"]),
                       ["GENERATE_INFOPLIST_FILE[arch=arm64]"])
        XCTAssertEqual(Self.infoPlistShadowingKeys(in: ["INFOPLIST_KEY_NSHumanReadableCopyright"]),
                       ["INFOPLIST_KEY_NSHumanReadableCopyright"])
        XCTAssertEqual(Self.infoPlistShadowingKeys(in: ["PRODUCT_NAME", "SWIFT_VERSION"]), [],
                       "ordinary settings must not be reported")
    }

    func testAnUnparsablePlistYieldsNoPairsRatherThanASilentPass() throws {
        let broken = FileManager.default.temporaryDirectory
            .appendingPathComponent("compliance-guard-broken-\(UUID().uuidString).plist")
        try Data("not a property list at all".utf8).write(to: broken)
        defer { try? FileManager.default.removeItem(at: broken) }
        XCTAssertThrowsError(try Self.infoPlist(broken), """
            an unreadable plist must throw. Returning [:] here is what would make \
            requireInfoPlist's count gate the only thing standing between a corrupt file and a \
            green run.
            """)
    }
}
