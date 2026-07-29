import XCTest
@testable import SoloLedgerCore

/// Wording guard over the six native `Localizable.strings`.
///
/// ## Why a Swift guard, when 43 `check:*` scripts already exist
///
/// **None of them reads Swift or `.strings`.** Only three scripts under `scripts/` name
/// `native/` at all — `check-golden-changes.mjs`, `check-swift-warnings.mjs` and
/// `test-malformed-rate-refusal.mjs` — and none of those looks at copy. In particular
/// `check-tax-labels.mjs` and `check-report-titles.mjs`, which enforce the product's
/// "management estimate, not a statutory filing" positioning, enumerate
/// `components/accountingLocaleConfig.ts` and `i18n/locales/*.json` BY NAME. The native
/// bundle has always been outside their reach.
///
/// That was survivable while the native app had no tax-facing copy. R8 adds report
/// screens whose most natural translations are the banned words — the engines' own field
/// names are `certifiedInput`, `invoicedOutput`, `estimatedPayable`, `vatPayable` — so the
/// guard has to exist before the copy does.
///
/// Kept INDEPENDENT of the JS guards rather than extending them: two products, two bundles,
/// two release trains. The word lists below are seeded from the reviewed JS lists and are
/// owned here.
///
/// ## The shape: a ratchet, not an allowlist
///
/// Every key in every locale is scanned. A hit is a failure UNLESS the key is in
/// ``sanctionedUses`` with a written reason — and an entry in that table that matches
/// NOTHING is also a failure, so a string that gets cleaned up cannot leave a permanent
/// exception behind. Same bidirectional discipline as `warning-baseline.json`.
///
/// Scanning everything and exempting by name is the opposite of the JS guards' approach
/// (they scan a named key list). It is chosen deliberately: a key list cannot see a key
/// that does not exist yet, and every R8 string is a key that does not exist yet.
final class LocalizationWordingGuardTests: XCTestCase {

    private let locales = ["zh-Hans", "zh-Hant", "en", "ja", "ko", "fr"]

    // MARK: - The word lists

    /// Wording that claims a statutory filing, an official certification, or a legal
    /// liability. Seeded from `scripts/check-tax-labels.mjs`'s `BANNED`.
    ///
    /// `Payable` / 应交 / 应缴 matter most for R8: five of the six engines emit a field
    /// literally called `payable` or `vatPayable`, and the obvious label for it is the one
    /// that asserts a debt to a tax authority — which this product does not compute.
    private static let filingWords: [(pattern: String, label: String)] = [
        ("申报", "申报"), ("申報", "申報"), ("报税", "报税"), ("報稅", "報稅"),
        ("认证", "认证"), ("認證", "認證"),
        ("已开票", "已开票"), ("已開票", "已開票"), ("可抵扣", "可抵扣"),
        ("\\bFiling\\b", "Filing"), ("\\bCertified\\b", "Certified"),
        ("Invoiced\\s+(?:Input|Output)", "Invoiced Input/Output"),
        ("\\bDeductible\\b", "Deductible"), ("Auto-certify", "Auto-certify"),
        ("应交", "应交"), ("應交", "應交"), ("应缴", "应缴"), ("應繳", "應繳"),
        ("\\bPayable\\b", "Payable"),
    ]

    /// Names of statutory financial statements. Seeded from
    /// `scripts/check-report-titles.mjs`'s `STMT_NAMES`.
    ///
    /// The product boundary in CLAUDE.md is that reports are management views; a screen
    /// titled 损益表 / Income Statement claims to be the statutory document. There are
    /// currently ZERO hits and therefore zero sanctioned uses — this list starts clean and
    /// must stay that way.
    private static let statutoryStatementNames: [(pattern: String, label: String)] = [
        ("利润表", "利润表"), ("利潤表", "利潤表"), ("损益表", "损益表"), ("損益表", "損益表"),
        ("资产负债表", "资产负债表"), ("資產負債表", "資產負債表"),
        ("貸借対照表", "貸借対照表"), ("재무상태표", "재무상태표"),
        ("现金流量表", "现金流量表"), ("現金流量表", "現金流量表"),
        ("(?i)Income Statement", "Income Statement"),
        ("(?i)Balance Sheet", "Balance Sheet"),
        ("(?i)Cash Flow Statement", "Cash Flow Statement"),
        ("(?i)Profit\\s*&?\\s*Loss\\s+Statement", "Profit & Loss Statement"),
    ]

    /// Keys whose value legitimately contains an otherwise-banned word, each with the
    /// reason it is sanctioned. **Every entry must actually match something** — see
    /// ``testEverySanctionedUseStillMatchesSomething``.
    ///
    /// Three of the four are DISCLAIMERS: they contain 申报 / 报税 / Filing precisely in
    /// order to deny that the app does it. Banning the word there would force the product
    /// boundary to be stated less clearly, which inverts the guard's purpose. The fourth is
    /// an invoice STATUS enum value, not a tax-amount label — the same carve-out
    /// `check-tax-labels.mjs` documents for `invoices.statusDeducted`.
    private static let sanctionedUses: [String: String] = [
        "about.positioning":
            "product positioning: states the app does NOT replace a statutory filing system",
        "overview.dataSourceNote":
            "data-source disclaimer: states the totals are NOT a basis for tax filing",
        "settings.accountingNote":
            "accounting-profile note: states the profile is NOT a statutory filing configuration",
        "invoice.issued":
            "invoice STATUS enum value (已开票 / Issued), not a tax-amount label — same carve-out "
            + "check-tax-labels.mjs documents for invoices.statusDeducted",
    ]

    // MARK: - The guards

    /// No user-visible string may claim a filing, a certification, or a statutory
    /// liability, except where sanctioned above.
    func testNoFilingOrCertificationWordingOutsideTheSanctionedDisclaimers() {
        assertNoBannedWording(Self.filingWords, family: "filing/certification/liability")
    }

    /// No user-visible string may carry the name of a statutory financial statement.
    /// There are no sanctioned uses of these and there should never be one: this product
    /// ships management views.
    func testNoStatutoryStatementNamesAnywhere() {
        for (locale, key, value) in allStrings() {
            for (pattern, label) in Self.statutoryStatementNames where matches(pattern, value) {
                XCTFail("""
                    \(locale)/\(key) contains the statutory statement name "\(label)". Reports in \
                    this product are management views (CLAUDE.md product boundary); use wording \
                    that does not name the statutory document. Value: \(value.debugDescription)
                    """)
            }
        }
    }

    /// The ratchet's second direction: a sanctioned entry that no longer matches anything
    /// must be REMOVED, so the exception list cannot rot into a permanent blanket.
    func testEverySanctionedUseStillMatchesSomething() {
        let all = allStrings()
        for (key, reason) in Self.sanctionedUses {
            let stillHits = all.contains { locale, k, value in
                _ = locale
                return k == key && Self.filingWords.contains { matches($0.pattern, value) }
            }
            XCTAssertTrue(stillHits, """
                "\(key)" is sanctioned (\(reason)) but no longer contains any banned word in any \
                locale. Delete the entry — a stale exception silently widens the guard.
                """)
        }
    }

    /// Sanctioned keys must still exist. A renamed key would otherwise carry its exemption
    /// nowhere and the new name would be unguarded.
    func testEverySanctionedKeyStillExists() {
        let universe = Set(allStrings().map(\.key))
        for key in Self.sanctionedUses.keys {
            XCTAssertTrue(universe.contains(key),
                          "sanctioned key \"\(key)\" no longer exists — remove or retarget it")
        }
    }

    /// No value may be empty or whitespace-only. An empty `.strings` value renders as a
    /// blank label, which reads as a bug and can read as a zero.
    func testNoLocaleHasAnEmptyOrWhitespaceOnlyValue() {
        for (locale, key, value) in allStrings() {
            XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "\(locale)/\(key) is empty or whitespace-only")
        }
    }

    /// No value may BE a key. `Localizer.t` returns the raw key when a lookup misses in
    /// both the requested and the fallback bundle, so a value that already looks like a key
    /// makes that failure mode indistinguishable from success.
    func testNoValueLooksLikeARawKey() {
        let universe = Set(allStrings().map(\.key))
        for (locale, key, value) in allStrings() {
            XCTAssertFalse(universe.contains(value),
                           "\(locale)/\(key) has a value that is itself a key: \(value)")
        }
    }

    /// The guard must be reading real files. Without this a broken path would make every
    /// assertion above pass over an empty set — the classic vacuous-green failure.
    func testTheGuardActuallyReadsAllSixLocales() {
        let all = allStrings()
        let seen = Set(all.map(\.locale))
        XCTAssertEqual(seen, Set(locales), "every locale must contribute strings")
        let byLocale = Dictionary(grouping: all, by: \.locale).mapValues(\.count)
        for locale in locales {
            XCTAssertGreaterThan(byLocale[locale] ?? 0, 200,
                                 "\(locale) contributed only \(byLocale[locale] ?? 0) strings")
        }
        XCTAssertEqual(Set(byLocale.values).count, 1,
                       "all six locales must define the same number of keys: \(byLocale)")
    }

    /// The word lists must be valid regular expressions, and the guard must be able to
    /// detect a violation. A guard that cannot fail is not a guard.
    func testTheWordListsCompileAndActuallyDetectViolations() {
        for (pattern, label) in Self.filingWords + Self.statutoryStatementNames {
            XCTAssertNotNil(try? NSRegularExpression(pattern: pattern),
                            "\(label) is not a valid regular expression: \(pattern)")
        }
        XCTAssertTrue(matches("\\bPayable\\b", "VAT Payable"), "positive control failed")
        XCTAssertTrue(matches("应交", "应交增值税"), "positive control failed")
        XCTAssertTrue(matches("(?i)Income Statement", "income statement"), "positive control failed")
        XCTAssertFalse(matches("\\bPayable\\b", "Estimated amount"), "negative control failed")
    }

    // MARK: - Helpers

    private func assertNoBannedWording(_ words: [(pattern: String, label: String)],
                                       family: String) {
        for (locale, key, value) in allStrings() where Self.sanctionedUses[key] == nil {
            for (pattern, label) in words where matches(pattern, value) {
                XCTFail("""
                    \(locale)/\(key) contains \(family) wording "\(label)". This product computes \
                    management estimates, not statutory filings (CLAUDE.md product boundary). \
                    Either de-escalate the wording, or — if the use is legitimate, e.g. a \
                    disclaimer that DENIES filing — add the key to `sanctionedUses` with a reason. \
                    Value: \(value.debugDescription)
                    """)
            }
        }
    }

    private func matches(_ pattern: String, _ text: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return false }
        return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Every (locale, key, value) triple, read from the COMMITTED SOURCE files.
    ///
    /// Source rather than bundle on purpose: this target is `SoloLedgerCore`, which does not
    /// link the app's resources at all. Reading the files the reviewer actually sees in the
    /// diff is also the stronger check — Xcode compiles `.strings` to a binary plist, and a
    /// guard over the compiled artefact would be one build step removed from the text under
    /// review.
    private func allStrings() -> [(locale: String, key: String, value: String)] {
        var out: [(String, String, String)] = []
        for locale in locales {
            let url = sourceStringsURL(locale)
            guard let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(from: data,
                                                                         options: [],
                                                                         format: nil),
                  let dict = plist as? [String: String] else {
                // Fail rather than skip. The files live INSIDE this package, so unlike
                // SchemaVersionParityTests (which compares against the Electron tree and may
                // legitimately be detached) there is no environment in which they are absent.
                XCTFail("could not read \(locale) Localizable.strings at \(url.path)")
                continue
            }
            for (key, value) in dict { out.append((locale, key, value)) }
        }
        return out
    }

    /// …/Tests/SoloLedgerCoreTests/<this>.swift → …/native/SoloLedger → the resource.
    private func sourceStringsURL(_ locale: String) -> URL {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { dir.deleteLastPathComponent() }
        return dir.appendingPathComponent(
            "Sources/SoloLedger/Resources/\(locale).lproj/Localizable.strings")
    }
}
