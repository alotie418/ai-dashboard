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
/// That was survivable while the native app had no tax-facing copy. R8 adds report screens
/// whose most natural translations are the banned words — the engines' own field names are
/// `certifiedInput`, `invoicedOutput`, `estimatedPayable`, `vatPayable` — so the guard has
/// to exist before the copy does.
///
/// Kept INDEPENDENT of the JS guards rather than extending them: two products, two bundles,
/// two release trains. The word lists are seeded from the reviewed JS lists and owned here,
/// **including their `/i` flags** — the Latin patterns carry `(?i)` because
/// `check-tax-labels.mjs` matches `/\bFiling\b/i`, and a case-sensitive port would let
/// "statutory filing system" through a guard whose whole purpose is to catch it.
///
/// ## The exemption is a (locale, key, pattern) TRIPLE, never a whole key
///
/// An earlier draft filtered with `sanctionedUses[key] == nil`, which skipped the entire key
/// for every banned word in every language. That is a blanket, not a ratchet: a sanctioned
/// key could later gain a second, unrelated, unapproved banned word and the suite would stay
/// green. ``SanctionedUse`` therefore authorises exactly one pattern, in exactly one locale,
/// for exactly one key — everything else about that key, in that locale and in the other
/// five, is still scanned.
///
/// The ratchet runs in both directions, as `warning-baseline.json` does:
///
/// * an unsanctioned hit FAILS (``testNoFilingOrCertificationWordingOutsideSanctionedUses``);
/// * a sanctioned entry that no longer matches its exact pattern in its exact locale also
///   FAILS (``testEverySanctionedUseStillMatchesItsExactPatternInItsExactLocale``), so a
///   cleaned-up string cannot leave a permanent exception behind.
///
/// Scanning everything and exempting by triple is the opposite of the JS guards' approach
/// (they scan a named key list). Chosen deliberately: a key list cannot see a key that does
/// not exist yet, and every R8 string is a key that does not exist yet.
///
/// ## Registered limitations
///
/// **1. Vocabulary coverage.** The banned lists are Chinese/English by origin, so they carry
/// **no Japanese, Korean or French filing vocabulary** — `法定申告`, `법정 신고` and
/// `déclaration légale` all pass today. Those three locales are covered only through the
/// Latin patterns. Widening the vocabulary is a wording decision (CLAUDE.md reserves those
/// for a human) and would add exemptions to the disclaimers that legitimately use those
/// words, so it is registered here rather than done silently.
///
/// **2. One known equivalent mutant.** Passing ``sanctionedUses`` instead of `[]` to the
/// statutory scan in ``testNoStatutoryStatementNamesAnywhere`` cannot change any verdict,
/// because ``testFilingAndStatutoryWordListsAreDisjoint`` proves no sanction ever names a
/// statutory pattern. It survives mutation testing by construction; the disjointness test is
/// what goes red if that ever stops being true. Recorded so nobody chases it.
final class LocalizationWordingGuardTests: XCTestCase {

    /// The languages to scan, **DISCOVERED FROM DISK** rather than declared.
    ///
    /// This is deliberately not a hardcoded array, and the reason is a mutation that
    /// survived one: with a declared list, dropping a language from it made the scan skip
    /// that language while every assertion — including the anti-vacuity one, which compared
    /// the scanned set against the same property — shrank with it and stayed green. A whole
    /// language could go unguarded with no test noticing.
    ///
    /// Discovery removes the failure mode instead of testing for it: there is no list to
    /// edit. Every `*.lproj` that ships a `Localizable.strings` is scanned, and
    /// ``testDiscoveredLocalesAreExactlyTheSixShippedLanguages`` compares the discovered set
    /// against six literals — so a language that disappears from disk, and a seventh that
    /// appears without the guard being reviewed, both fail.
    private static let locales: [String] = discoverLocales()

    private static func discoverLocales() -> [String] {
        let dir = resourcesDirectory()
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return []
        }
        return entries
            .filter { $0.hasSuffix(".lproj") }
            .map { String($0.dropLast(".lproj".count)) }
            .filter {
                FileManager.default.fileExists(
                    atPath: dir.appendingPathComponent("\($0).lproj/Localizable.strings").path)
            }
            .sorted()
    }

    // MARK: - Types

    struct LocalizedString: Hashable {
        let locale: String, key: String, value: String
    }

    struct BannedWord: Hashable {
        let pattern: String, label: String
    }

    /// Authorisation for ONE pattern, in ONE locale, on ONE key.
    ///
    /// `reason` is documentation and is deliberately excluded from the identity used when
    /// matching a hit — see ``authorises(locale:key:pattern:)`` — so editing a reason can
    /// never change what the guard permits.
    struct SanctionedUse: Hashable {
        let locale: String, key: String, pattern: String, reason: String
    }

    struct Violation: Hashable, CustomStringConvertible {
        let locale: String, key: String, label: String
        var description: String { "\(locale)/\(key): \"\(label)\"" }
    }

    // MARK: - The word lists

    /// Wording that claims a statutory filing, an official certification, or a legal
    /// liability. Seeded from `scripts/check-tax-labels.mjs`'s `BANNED`, `/i` flags included.
    ///
    /// `Payable` / 应交 / 应缴 matter most for R8: five of the six engines emit a field
    /// literally called `payable` or `vatPayable`, and the obvious label for it is the one
    /// that asserts a debt to a tax authority — which this product does not compute.
    static let filingWords: [BannedWord] = [
        .init(pattern: "申报", label: "申报"),
        .init(pattern: "申報", label: "申報"),
        .init(pattern: "报税", label: "报税"),
        .init(pattern: "報稅", label: "報稅"),
        .init(pattern: "认证", label: "认证"),
        .init(pattern: "認證", label: "認證"),
        .init(pattern: "已开票", label: "已开票"),
        .init(pattern: "已開票", label: "已開票"),
        .init(pattern: "可抵扣", label: "可抵扣"),
        .init(pattern: "应交", label: "应交"),
        .init(pattern: "應交", label: "應交"),
        .init(pattern: "应缴", label: "应缴"),
        .init(pattern: "應繳", label: "應繳"),
        .init(pattern: #"(?i)\bFiling\b"#, label: "Filing"),
        .init(pattern: #"(?i)\bCertified\b"#, label: "Certified"),
        .init(pattern: #"(?i)Invoiced\s+(?:Input|Output)"#, label: "Invoiced Input/Output"),
        .init(pattern: #"(?i)\bDeductible\b"#, label: "Deductible"),
        .init(pattern: #"(?i)Auto-certify"#, label: "Auto-certify"),
        .init(pattern: #"(?i)\bPayable\b"#, label: "Payable"),
    ]

    /// Names of statutory financial statements. Seeded from
    /// `scripts/check-report-titles.mjs`'s `STMT_NAMES`.
    ///
    /// The product boundary in CLAUDE.md is that reports are management views; a screen
    /// titled 损益表 / Income Statement claims to be the statutory document. There are
    /// currently ZERO hits and therefore ZERO sanctioned uses — this list starts clean and
    /// must stay that way.
    static let statutoryStatementNames: [BannedWord] = [
        .init(pattern: "利润表", label: "利润表"),
        .init(pattern: "利潤表", label: "利潤表"),
        .init(pattern: "损益表", label: "损益表"),
        .init(pattern: "損益表", label: "損益表"),
        .init(pattern: "资产负债表", label: "资产负债表"),
        .init(pattern: "資產負債表", label: "資產負債表"),
        .init(pattern: "貸借対照表", label: "貸借対照表"),
        .init(pattern: "재무상태표", label: "재무상태표"),
        .init(pattern: "现金流量表", label: "现金流量表"),
        .init(pattern: "現金流量表", label: "現金流量表"),
        .init(pattern: #"(?i)Income Statement"#, label: "Income Statement"),
        .init(pattern: #"(?i)Balance Sheet"#, label: "Balance Sheet"),
        .init(pattern: #"(?i)Cash Flow Statement"#, label: "Cash Flow Statement"),
        .init(pattern: #"(?i)Profit\s*&?\s*Loss\s+Statement"#, label: "Profit & Loss Statement"),
    ]

    /// The complete authorisation table: 11 triples, no key exempted as a whole.
    ///
    /// Nine of the eleven are DISCLAIMERS containing 申报 / 报税 / Filing precisely in order
    /// to DENY that the app does it. Banning the word there would force the product boundary
    /// to be stated less clearly, which inverts the guard's purpose. The other two are an
    /// invoice STATUS enum value — not a tax-amount label — the same carve-out
    /// `check-tax-labels.mjs` documents for `invoices.statusDeducted`.
    ///
    /// Note what the per-locale narrowing already buys: `invoice.issued` is sanctioned in
    /// zh-Hans and zh-Hant ONLY. Its `en` value is "Issued", which trips nothing — so if
    /// anyone ever changed it to "Invoiced Output", that would fail, on a key the old
    /// whole-key form would have waved through.
    static let sanctionedUses: [SanctionedUse] = [
        // — product positioning: states the app does NOT replace a statutory filing system
        .init(locale: "zh-Hans", key: "about.positioning", pattern: "申报",
              reason: "positioning disclaimer: denies replacing a statutory filing system"),
        .init(locale: "zh-Hant", key: "about.positioning", pattern: "申報",
              reason: "positioning disclaimer: denies replacing a statutory filing system"),
        .init(locale: "en", key: "about.positioning", pattern: #"(?i)\bFiling\b"#,
              reason: "positioning disclaimer: denies replacing a statutory filing system"),
        // — data-source note: states the totals are NOT a basis for tax filing
        .init(locale: "zh-Hans", key: "overview.dataSourceNote", pattern: "报税",
              reason: "data-source disclaimer: denies being a basis for tax filing"),
        .init(locale: "zh-Hant", key: "overview.dataSourceNote", pattern: "報稅",
              reason: "data-source disclaimer: denies being a basis for tax filing"),
        .init(locale: "en", key: "overview.dataSourceNote", pattern: #"(?i)\bFiling\b"#,
              reason: "data-source disclaimer: denies being a basis for tax filing"),
        // — accounting-profile note: states the profile is NOT a filing configuration
        .init(locale: "zh-Hans", key: "settings.accountingNote", pattern: "申报",
              reason: "accounting-profile note: denies being a statutory filing configuration"),
        .init(locale: "zh-Hant", key: "settings.accountingNote", pattern: "申報",
              reason: "accounting-profile note: denies being a statutory filing configuration"),
        .init(locale: "en", key: "settings.accountingNote", pattern: #"(?i)\bFiling\b"#,
              reason: "accounting-profile note: denies being a statutory filing configuration"),
        // — invoice STATUS enum value, not a tax-amount label (cf. invoices.statusDeducted)
        .init(locale: "zh-Hans", key: "invoice.issued", pattern: "已开票",
              reason: "invoice status enum value, not a tax-amount label"),
        .init(locale: "zh-Hant", key: "invoice.issued", pattern: "已開票",
              reason: "invoice status enum value, not a tax-amount label"),
        // — R8 P3d, the report page's four disclaimers. Same shape as the three above and for
        //   the same reason: each one uses the filing word in order to DENY that this app does
        //   the thing. `report.disclaimer.rates` says nothing about filing and needs no entry.
        .init(locale: "zh-Hans", key: "report.disclaimer.report", pattern: "申报",
              reason: "report-page disclaimer: denies being a statutory statement or a basis for filing"),
        .init(locale: "zh-Hans", key: "report.disclaimer.report", pattern: "报税",
              reason: "report-page disclaimer: denies being a statutory statement or a basis for filing"),
        .init(locale: "zh-Hant", key: "report.disclaimer.report", pattern: "申報",
              reason: "report-page disclaimer: denies being a statutory statement or a basis for filing"),
        .init(locale: "zh-Hant", key: "report.disclaimer.report", pattern: "報稅",
              reason: "report-page disclaimer: denies being a statutory statement or a basis for filing"),
        .init(locale: "en", key: "report.disclaimer.report", pattern: #"(?i)\bFiling\b"#,
              reason: "report-page disclaimer: denies being a statutory statement or a basis for filing"),
        .init(locale: "zh-Hans", key: "report.disclaimer.tax", pattern: "申报",
              reason: "tax-block disclaimer: denies being a basis for filing"),
        .init(locale: "zh-Hant", key: "report.disclaimer.tax", pattern: "申報",
              reason: "tax-block disclaimer: denies being a basis for filing"),
        .init(locale: "en", key: "report.disclaimer.tax", pattern: #"(?i)\bFiling\b"#,
              reason: "tax-block disclaimer: denies being a basis for filing"),
        .init(locale: "zh-Hans", key: "report.disclaimer.usTax", pattern: "报税",
              reason: "US tax disclaimer: denies being a basis for filing, points to a professional"),
        .init(locale: "zh-Hant", key: "report.disclaimer.usTax", pattern: "報稅",
              reason: "US tax disclaimer: denies being a basis for filing, points to a professional"),
        .init(locale: "en", key: "report.disclaimer.usTax", pattern: #"(?i)\bFiling\b"#,
              reason: "US tax disclaimer: denies being a basis for filing, points to a professional"),
    ]

    // MARK: - The scan, as a pure function

    /// Every unsanctioned hit in `corpus`. Pure, so the guard's own logic can be exercised
    /// against synthetic corpora — which is the only way to prove what it REJECTS without
    /// committing a violating string to the repo.
    static func violations(in corpus: [LocalizedString],
                           words: [BannedWord],
                           sanctioned: [SanctionedUse]) -> [Violation] {
        var out: [Violation] = []
        for s in corpus {
            for w in words where matches(w.pattern, s.value) {
                guard !authorises(sanctioned, locale: s.locale, key: s.key, pattern: w.pattern)
                else { continue }
                out.append(Violation(locale: s.locale, key: s.key, label: w.label))
            }
        }
        return out
    }

    /// Triple membership, ignoring `reason`. An entry authorises ONE pattern on ONE key in
    /// ONE locale — never the key as a whole.
    private static func authorises(_ table: [SanctionedUse],
                                   locale: String, key: String, pattern: String) -> Bool {
        table.contains { $0.locale == locale && $0.key == key && $0.pattern == pattern }
    }

    static func matches(_ pattern: String, _ text: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return false }
        return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    // MARK: - The guards over the real bundle

    /// No user-visible string may claim a filing, a certification, or a statutory liability,
    /// except where a (locale, key, pattern) triple authorises it.
    func testNoFilingOrCertificationWordingOutsideSanctionedUses() {
        let found = Self.violations(in: Self.allStrings(),
                                    words: Self.filingWords,
                                    sanctioned: Self.sanctionedUses)
        XCTAssertTrue(found.isEmpty, """
            filing / certification / statutory-liability wording found: \
            \(found.map(\.description).sorted().joined(separator: ", ")). This product computes \
            management estimates, not statutory filings (CLAUDE.md product boundary). Either \
            de-escalate the wording, or — if the use is legitimate, e.g. a disclaimer that \
            DENIES filing — add a SanctionedUse for that exact locale/key/pattern with a reason.
            """)
    }

    /// No user-visible string may carry the name of a statutory financial statement. There
    /// are no sanctioned uses of these and there should never be one: this product ships
    /// management views.
    func testNoStatutoryStatementNamesAnywhere() {
        let found = Self.violations(in: Self.allStrings(),
                                    words: Self.statutoryStatementNames,
                                    sanctioned: [])
        XCTAssertTrue(found.isEmpty, """
            statutory statement names found: \
            \(found.map(\.description).sorted().joined(separator: ", ")). Reports in this product \
            are management views; use wording that does not name the statutory document.
            """)
    }

    /// The ratchet's second direction, now at TRIPLE precision: every sanctioned entry must
    /// still match its EXACT pattern, on its EXACT key, in its EXACT locale.
    ///
    /// Strictly stronger than the whole-key form it replaces, which was satisfied by any one
    /// locale hitting any one word.
    func testEverySanctionedUseStillMatchesItsExactPatternInItsExactLocale() {
        let byLocaleKey = Dictionary(uniqueKeysWithValues:
            Self.allStrings().map { (LocaleKey(locale: $0.locale, key: $0.key), $0.value) })
        for use in Self.sanctionedUses {
            guard let value = byLocaleKey[LocaleKey(locale: use.locale, key: use.key)] else {
                XCTFail("""
                    sanctioned \(use.locale)/\(use.key) no longer exists (\(use.reason)) — remove \
                    or retarget the entry; an exemption pointing at nothing guards nothing.
                    """)
                continue
            }
            XCTAssertTrue(Self.matches(use.pattern, value), """
                sanctioned \(use.locale)/\(use.key) no longer contains \(use.pattern) \
                (\(use.reason)). Delete the entry — a stale exemption silently widens the guard. \
                Value: \(value.debugDescription)
                """)
        }
    }

    /// A sanctioned pattern must be one the guard actually bans. Otherwise an invented or
    /// mistyped pattern would sit in the table authorising nothing while looking like
    /// coverage, and the real word it was meant to cover would fail confusingly.
    func testEverySanctionedPatternIsARealBannedPattern() {
        let banned = Set(Self.filingWords.map(\.pattern))
        for use in Self.sanctionedUses {
            XCTAssertTrue(banned.contains(use.pattern), """
                \(use.locale)/\(use.key) is sanctioned for \(use.pattern), which is not in \
                `filingWords`. A sanction may only relax a pattern the guard enforces.
                """)
        }
    }

    /// No duplicate triples, and every sanctioned locale is a real one.
    func testSanctionedTableIsWellFormed() {
        let identities = Self.sanctionedUses.map { "\($0.locale)|\($0.key)|\($0.pattern)" }
        XCTAssertEqual(Set(identities).count, identities.count,
                       "duplicate SanctionedUse triples: \(identities.sorted())")
        for use in Self.sanctionedUses {
            XCTAssertTrue(Self.locales.contains(use.locale), "unknown locale \(use.locale)")
            XCTAssertFalse(use.reason.trimmingCharacters(in: .whitespaces).isEmpty,
                           "\(use.locale)/\(use.key) has no reason")
        }
    }

    // MARK: - Self-tests: what the guard REJECTS

    // These run the pure scan over synthetic corpora. They are the only way to prove the
    // rejection behaviour without committing a violating string, and they are the tests the
    // whole-key form could not have passed.

    /// **A sanctioned key that gains a SECOND, unrelated banned word must fail.**
    ///
    /// The exact hole the whole-key filter had: `about.positioning` is authorised for
    /// `Filing` only, so an added `Payable` is reported.
    func testASanctionedKeyGainingAnUnrelatedBannedWordIsReported() {
        let corpus = [LocalizedString(
            locale: "en", key: "about.positioning",
            value: "… not a statutory filing system. VAT Payable is estimated here.")]
        let found = Self.violations(in: corpus,
                                    words: Self.filingWords,
                                    sanctioned: Self.sanctionedUses)
        XCTAssertEqual(found, [Violation(locale: "en", key: "about.positioning", label: "Payable")],
                       "an unrelated banned word on a sanctioned key must still be reported")
    }

    /// The same, driven from the REAL committed value rather than a hand-written one, so the
    /// property is proved against the string that actually ships.
    func testRealSanctionedValuesStillFailWhenASecondBannedWordIsAppended() {
        let real = Self.allStrings()
        for use in Self.sanctionedUses {
            guard let s = real.first(where: { $0.locale == use.locale && $0.key == use.key })
            else { continue }
            let tampered = [LocalizedString(locale: s.locale, key: s.key,
                                            value: s.value + " 应交税额 / Amount Payable")]
            let found = Self.violations(in: tampered,
                                        words: Self.filingWords,
                                        sanctioned: Self.sanctionedUses)
            XCTAssertFalse(found.isEmpty, """
                \(use.locale)/\(use.key) absorbed an added banned word — its sanction is behaving \
                like a whole-key exemption.
                """)
            XCTAssertFalse(found.contains { $0.label == labelFor(use.pattern) },
                           "the sanctioned word itself must remain sanctioned")
        }
    }

    /// **The same key in a DIFFERENT locale is still scanned.** `invoice.issued` is
    /// sanctioned in zh-Hans/zh-Hant only; the English one is not exempt from anything.
    func testTheSameKeyInAnUnsanctionedLocaleIsStillScanned() {
        let corpus = [LocalizedString(locale: "en", key: "invoice.issued", value: "Invoiced Output")]
        XCTAssertEqual(Self.violations(in: corpus, words: Self.filingWords,
                                       sanctioned: Self.sanctionedUses),
                       [Violation(locale: "en", key: "invoice.issued",
                                  label: "Invoiced Input/Output")])
    }

    /// **The locale half of the triple is load-bearing on its own.** Every sanctioned
    /// (locale, key, pattern) is replayed with the SAME key and the SAME pattern in each of
    /// the OTHER five locales, and every one of those must be reported.
    ///
    /// Without this the exemption could match on (key, pattern) alone and nothing would
    /// notice: the real corpus happens to carry each pattern in only one locale per key, so
    /// dropping `locale` from the comparison changes no real verdict. Found by mutation —
    /// the cross-locale blanket survived until this test existed.
    func testTheSamePatternOnTheSameKeyInAnotherLocaleIsStillScanned() {
        for use in Self.sanctionedUses {
            guard let value = Self.allStrings().first(where: {
                $0.locale == use.locale && $0.key == use.key
            })?.value else {
                XCTFail("\(use.locale)/\(use.key) not found"); continue
            }
            for other in Self.locales where other != use.locale {
                let corpus = [LocalizedString(locale: other, key: use.key, value: value)]
                let found = Self.violations(in: corpus, words: Self.filingWords,
                                            sanctioned: Self.sanctionedUses)
                XCTAssertFalse(found.isEmpty, """
                    \(use.key) carrying \(use.pattern) in \(other) was NOT reported, but only \
                    \(use.locale) is sanctioned for it — the exemption is behaving as a \
                    cross-locale blanket.
                    """)
            }
        }
    }

    /// **The same pattern on a DIFFERENT key is still scanned.** A sanction is not a licence
    /// for the word anywhere else.
    func testTheSamePatternOnAnUnsanctionedKeyIsStillScanned() {
        let corpus = [LocalizedString(locale: "en", key: "report.plTitle",
                                      value: "Filing summary")]
        XCTAssertEqual(Self.violations(in: corpus, words: Self.filingWords,
                                       sanctioned: Self.sanctionedUses),
                       [Violation(locale: "en", key: "report.plTitle", label: "Filing")])
    }

    /// A brand-new key with banned wording — the R8 case the guard exists for — is reported
    /// in every locale.
    func testNewReportCopyWithBannedWordingIsReportedInEveryLocale() {
        let corpus = [
            LocalizedString(locale: "en", key: "report.vatPayable", value: "VAT Payable"),
            LocalizedString(locale: "zh-Hans", key: "report.vatPayable", value: "应交增值税"),
            LocalizedString(locale: "zh-Hant", key: "report.vatPayable", value: "應繳營業稅"),
        ]
        let found = Self.violations(in: corpus, words: Self.filingWords, sanctioned: Self.sanctionedUses)
        XCTAssertEqual(Set(found.map(\.locale)), ["en", "zh-Hans", "zh-Hant"])
        XCTAssertEqual(found.count, 3)
    }

    /// A statutory statement name is reported even on a key sanctioned for a filing word.
    ///
    /// Asserted with the filing table PASSED IN, not with an empty one, so the claim proved
    /// is the strong one — "a filing sanction can never excuse a statutory name" — rather
    /// than the weak "we happened to pass `[]` at the call site".
    func testStatutoryNamesAreNotCoveredByFilingSanctions() {
        let corpus = [LocalizedString(locale: "en", key: "about.positioning",
                                      value: "not a statutory filing system — see the Balance Sheet")]
        for table in [[], Self.sanctionedUses] {
            XCTAssertEqual(Self.violations(in: corpus, words: Self.statutoryStatementNames,
                                           sanctioned: table),
                           [Violation(locale: "en", key: "about.positioning",
                                      label: "Balance Sheet")])
        }
    }

    /// The two word lists share no pattern, which is what makes the assertion above hold
    /// structurally rather than by luck: a sanction names a `filingWords` pattern, so it can
    /// only ever relax that list.
    ///
    /// Stated as its own test because it is the invariant the statutory guard's `sanctioned: []`
    /// argument relies on. If someone ever adds a pattern to both lists, that argument stops
    /// being obviously irrelevant and this goes red first.
    func testFilingAndStatutoryWordListsAreDisjoint() {
        let filing = Set(Self.filingWords.map(\.pattern))
        let statutory = Set(Self.statutoryStatementNames.map(\.pattern))
        XCTAssertTrue(filing.isDisjoint(with: statutory),
                      "overlapping patterns: \(filing.intersection(statutory).sorted())")
        XCTAssertTrue(Set(Self.sanctionedUses.map(\.pattern)).isDisjoint(with: statutory),
                      "no sanction may name a statutory statement pattern")
    }

    /// A stale sanction is detected: an entry whose pattern the value no longer contains.
    /// Proves the second ratchet direction as LOGIC, not only against today's data.
    func testAStaleSanctionIsDetectable() {
        let cleaned = "SoloLedger is a local-first ledger for solo operators."
        let use = Self.sanctionedUses.first { $0.locale == "en" && $0.key == "about.positioning" }
        XCTAssertNotNil(use)
        XCTAssertFalse(Self.matches(use!.pattern, cleaned),
                       "a cleaned-up value must stop matching, so its sanction must be removed")
    }

    /// Case-insensitivity parity with `check-tax-labels.mjs`'s `/i` flags. A case-sensitive
    /// port would miss "statutory filing system" — the exact phrase this repo ships.
    func testLatinPatternsAreCaseInsensitiveLikeTheJSGuard() {
        for text in ["filing", "Filing", "FILING", "a statutory filing system"] {
            XCTAssertTrue(Self.matches(#"(?i)\bFiling\b"#, text), "\(text) must match")
        }
        for text in ["payable", "Payable", "VAT PAYABLE"] {
            XCTAssertTrue(Self.matches(#"(?i)\bPayable\b"#, text), "\(text) must match")
        }
        // Word boundaries still hold, so ordinary words are not swept up.
        XCTAssertFalse(Self.matches(#"(?i)\bFiling\b"#, "profiling"))
        XCTAssertFalse(Self.matches(#"(?i)\bPayable\b"#, "repayableness"))
    }

    /// Every pattern compiles, and the machinery can both fire and stay silent.
    func testTheWordListsCompileAndHaveWorkingControls() {
        for w in Self.filingWords + Self.statutoryStatementNames {
            XCTAssertNotNil(try? NSRegularExpression(pattern: w.pattern),
                            "\(w.label) is not a valid regular expression: \(w.pattern)")
        }
        let clean = [LocalizedString(locale: "en", key: "report.netProfit", value: "Net profit")]
        XCTAssertTrue(Self.violations(in: clean, words: Self.filingWords, sanctioned: []).isEmpty,
                      "negative control: clean copy must not be reported")
    }

    // MARK: - Anti-vacuity

    /// Discovery must find exactly the six shipped languages — no fewer (a language silently
    /// unguarded) and no more (a seventh added without the guard being reviewed).
    ///
    /// The six are written out as LITERALS, compared against what ``discoverLocales()`` found
    /// on disk. Two independent sources, so neither can quietly agree with the other:
    /// deleting `fr.lproj` fails here, and there is no declared list left to edit.
    func testDiscoveredLocalesAreExactlyTheSixShippedLanguages() {
        XCTAssertEqual(Set(Self.locales), ["zh-Hans", "zh-Hant", "en", "ja", "ko", "fr"], """
            the discovered `.lproj` set is \(Self.locales.sorted()). A language that vanished \
            is a language nothing scans; a new one needs its wording reviewed before it ships.
            """)
    }

    /// The guard must be reading real files. Without this a broken path would make every
    /// assertion above pass over an empty set — the classic vacuous green.
    func testTheGuardActuallyReadsEveryDiscoveredLocale() {
        let all = Self.allStrings()
        XCTAssertEqual(Set(all.map(\.locale)), Set(Self.locales),
                       "every discovered locale must contribute strings")
        let byLocale = Dictionary(grouping: all, by: \.locale).mapValues(\.count)
        for locale in Self.locales {
            XCTAssertGreaterThan(byLocale[locale] ?? 0, 200,
                                 "\(locale) contributed only \(byLocale[locale] ?? 0) strings")
        }
        XCTAssertEqual(Set(byLocale.values).count, 1,
                       "all locales must define the same number of keys: \(byLocale)")
    }

    /// Exactly the sanctioned triples are exempt — no more. Counts the real hits and checks
    /// they correspond one-to-one with the table, so an unnoticed new hit cannot hide behind
    /// an existing entry.
    func testSanctionedTableMatchesTheRealHitsExactly() {
        var hits: Set<String> = []
        for s in Self.allStrings() {
            for w in Self.filingWords where Self.matches(w.pattern, s.value) {
                hits.insert("\(s.locale)|\(s.key)|\(w.pattern)")
            }
        }
        let sanctioned = Set(Self.sanctionedUses.map { "\($0.locale)|\($0.key)|\($0.pattern)" })
        XCTAssertEqual(hits, sanctioned, """
            the real hits and the sanction table have drifted. \
            unsanctioned hits: \(hits.subtracting(sanctioned).sorted()); \
            stale sanctions: \(sanctioned.subtracting(hits).sorted())
            """)
    }

    /// No value may be empty or whitespace-only — an empty `.strings` value renders as a
    /// blank label, which reads as a bug and can read as a zero.
    func testNoLocaleHasAnEmptyOrWhitespaceOnlyValue() {
        for s in Self.allStrings() {
            XCTAssertFalse(s.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "\(s.locale)/\(s.key) is empty or whitespace-only")
        }
    }

    /// No value may BE a key. `Localizer.t` returns the raw key when a lookup misses in both
    /// the requested and the fallback bundle, so a value that already looks like a key makes
    /// that failure mode indistinguishable from success.
    func testNoValueLooksLikeARawKey() {
        let universe = Set(Self.allStrings().map(\.key))
        for s in Self.allStrings() {
            XCTAssertFalse(universe.contains(s.value),
                           "\(s.locale)/\(s.key) has a value that is itself a key: \(s.value)")
        }
    }

    // MARK: - Helpers

    private struct LocaleKey: Hashable { let locale: String, key: String }

    private func labelFor(_ pattern: String) -> String {
        Self.filingWords.first { $0.pattern == pattern }?.label ?? pattern
    }

    /// Every (locale, key, value) triple, read from the COMMITTED SOURCE files.
    ///
    /// Source rather than bundle on purpose: this target is `SoloLedgerCore`, which does not
    /// link the app's resources at all. Reading the files the reviewer sees in the diff is
    /// also the stronger check — Xcode compiles `.strings` to a binary plist, and a guard
    /// over the compiled artefact would be one build step removed from the text under review.
    static func allStrings() -> [LocalizedString] {
        var out: [LocalizedString] = []
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
            for (key, value) in dict {
                out.append(LocalizedString(locale: locale, key: key, value: value))
            }
        }
        return out
    }

    /// …/Tests/SoloLedgerCoreTests/<this>.swift → …/native/SoloLedger/Sources/SoloLedger/Resources.
    private static func resourcesDirectory() -> URL {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { dir.deleteLastPathComponent() }
        return dir.appendingPathComponent("Sources/SoloLedger/Resources")
    }

    private static func sourceStringsURL(_ locale: String) -> URL {
        resourcesDirectory().appendingPathComponent("\(locale).lproj/Localizable.strings")
    }
}
