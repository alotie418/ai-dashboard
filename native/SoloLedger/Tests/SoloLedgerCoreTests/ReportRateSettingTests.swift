import XCTest
@testable import SoloLedgerCore

/// A4-2 — the fourth state: a rate row that EXISTS and whose value is unusable.
///
/// ## Why the decision cannot be made from the coerced number
///
/// The same argument as A-3, one layer down, and it is a measurement rather than a
/// preference. `Number()` of the shapes a corrupt row can hold:
///
/// ```
///   null → 0      "" → 0      " " → 0      false → 0      [] → 0
///   true → 1      [25] → 25   "25" → 25    "25%" → NaN    {} → NaN
///   (not JSON at all: readSetting's catch returns the FALLBACK — 25)
/// ```
///
/// Six of those are ordinary rates. A gate reading the coerced value would call a
/// corrupt row a deliberate 0%, or 1%, or 25% — and `malformed-US-2025.json` is today
/// **byte-identical to `zero-US-2025.json`**, warning string included, which is the
/// proof that no value-based check can separate them. So the classification reads the
/// STORED TEXT — the `settings.value` string before JSON parsing and before numeric
/// coercion — and ``ReportRateSetting/needsRepair(rawValue:)`` carries it.
///
/// ## What this suite deliberately does NOT assert
///
/// That the two apps agree. They do not, yet: until A4-3 lands, `electron/reports/*`
/// still coerces these rows while the native model refuses them. That divergence is
/// pinned below by name rather than left to be discovered, and closing it is A4-3's
/// whole job.
///
/// **The goldens are FROZEN here** — this suite reads them and changes none; no
/// commit in A4-2 declares `Allowed-Golden-Changes`.
final class ReportRateSettingTests: LedgerTestCase {

    private func bundledFixtureURL() throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: "reports", withExtension: nil),
                      "report fixtures missing from the test bundle")
            .appendingPathComponent("reports-base.db")
    }

    private func fixtureCopy(_ name: String) throws -> SQLiteDatabase {
        let dst = try trackedTempDir().appendingPathComponent("\(name).db")
        try FileManager.default.copyItem(at: try bundledFixtureURL(), to: dst)
        return try SQLiteDatabase(path: dst.path)
    }

    private func golden(_ name: String) throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "reports", withExtension: nil))
            .appendingPathComponent("goldens").appendingPathComponent("\(name).json")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url))
                             as? [String: Any], "\(name).json is not an object")
    }

    private func put(_ db: SQLiteDatabase, _ key: String, _ rawJSON: String) throws {
        try db.execute("""
            INSERT INTO settings (key, value, updated_at)
            VALUES ('\(key)', '\(rawJSON)', datetime('now'))
            ON CONFLICT(key) DO UPDATE SET value='\(rawJSON)', updated_at=datetime('now')
            """)
    }

    private let allLocales = ["CN", "US", "JP", "EU", "KR", "TW"]

    // MARK: - The classification, over the shapes a row can actually hold

    /// Usable — and no more than these.
    func testOnlyFiniteNumbersAndNumericStringsAreUsable() {
        for (raw, want) in [("25", 25.0), ("25.5", 25.5), ("0", 0), ("-5", -5),
                            ("1e3", 1000), ("\"25\"", 25), ("\"13\"", 13),
                            ("\" 25 \"", 25), ("\"0\"", 0), ("\"-5\"", -5)] {
            XCTAssertEqual(ReportSettings.classifyRate(raw), .configured(FiniteRate(want)!),
                           "stored \(raw) is a usable rate")
        }
    }

    /// Unusable — the three families, each of which behaves differently in today's JS.
    func testEveryCorruptShapeNeedsRepairAndKeepsItsBytes() {
        let corrupt = [
            // JSON, but coerces to an ordinary-looking NUMBER. The dangerous family:
            // the result looks like a setting the user chose.
            "null", "\"\"", "\"   \"", "true", "false", "[]", "[25]",
            // JSON, coerces to NaN.
            "\"25%\"", "{}", "[1,2]", "{\"v\":25}", "\"abc\"", "\"Infinity\"",
            // Not JSON at all — readSetting's catch returns the FALLBACK, so this is
            // the family that silently prices a US ledger at China's 25%.
            "abc", "25%", "", "Infinity", "NaN",
            // Numbers JSON cannot even hold, spelled as text.
            "1e999",
        ]
        for raw in corrupt {
            let s = ReportSettings.classifyRate(raw)
            XCTAssertEqual(s, .needsRepair(rawValue: raw), "stored \(raw) must need repair")
            XCTAssertNil(s.rate, "stored \(raw) must not price anything")
            XCTAssertEqual(s.needsRepairRawValue, raw,
                           "the stored TEXT is what a repair flow has to show the user")
        }
    }

    /// The four families are not interchangeable, stated as one table.
    func testTheCoercedValueWouldHaveGotItWrong() {
        // What the coerced value says, measured through the mirror's own ToNumber.
        XCTAssertEqual(ReportMath.number(.null), 0)
        XCTAssertEqual(ReportMath.number(.boolean(true)), 1)
        XCTAssertEqual(ReportMath.number(.string("")), 0)
        XCTAssertEqual(ReportMath.number(.array([])), 0)
        XCTAssertEqual(ReportMath.number(.array([.number(25)])), 25)
        // …and what the stored TEXT says. Every one of the five above is corrupt.
        for raw in ["null", "true", "\"\"", "[]", "[25]"] {
            XCTAssertNil(ReportSettings.classifyRate(raw).rate,
                         "\(raw) coerces to a perfectly ordinary rate and is still corrupt")
        }
        // A genuine 0 is not corrupt, and that is the pair the whole rule turns on.
        XCTAssertEqual(ReportSettings.classifyRate("0"), .configured(0))
        XCTAssertNotEqual(ReportSettings.classifyRate("0"), ReportSettings.classifyRate("\"\""),
                          "a stored 0 and an empty string both coerce to 0 — they are not the same state")
    }

    // MARK: - Fed from the committed goldens' own variants

    /// The malformed variant, applied to the real fixture exactly as the golden
    /// generator applies it, resolved through the real production entry points.
    ///
    /// This is the arm plan §6.4 asks for and R6 could not write: R6's
    /// `testTheStatesAgreeWithWhatTheGoldensRecord` covers `unset` and `zero` only, so
    /// until now the malformed contract was asserted against the TYPE and never
    /// against a golden.
    func testTheMalformedGoldenVariantResolvesToNeedsRepairEverywhere() throws {
        let db = try fixtureCopy("malformed")
        // make-report-goldens.mjs:95-100 — the exact mutation.
        try put(db, "surcharge_rate", "\"12%\"")
        try put(db, "income_tax_rate", "\"25%\"")

        for locale in allLocales {
            XCTAssertEqual(ReportSettings.incomeTaxRate(db, locale: locale),
                           .needsRepair(rawValue: "\"25%\""),
                           "\(locale): income tax")
            XCTAssertEqual(ReportSettings.surchargeRate(db, locale: locale),
                           .needsRepair(rawValue: "\"12%\""),
                           "\(locale): surcharge — including China, which has no not-configured state")

            // …and it reaches an engine that way, through the dispatcher's own path.
            //
            // The two rates carry DIFFERENT bytes on purpose ("25%" vs "12%"): a
            // dispatcher that wired `surchargeRate:` to the income-tax resolver — the
            // one-word mistake this PR's new argument makes possible — would pass an
            // assertion that only checked "both are needs-repair".
            let ctx = try ReportDispatcher.context(db, locale: locale, source: .transactions,
                                                   year: "2025", from: "2025-01-01", to: "2025-12-31")
            XCTAssertNil(ctx.incomeTaxRate.rate, "\(locale): nothing to price with")
            XCTAssertNil(ctx.surchargeRate.rate, "\(locale): nor a surcharge")
            XCTAssertEqual(ctx.incomeTaxRate.needsRepairRawValue, "\"25%\"",
                           "\(locale): income tax carries ITS row's bytes")
            XCTAssertEqual(ctx.surchargeRate.needsRepairRawValue, "\"12%\"",
                           "\(locale): the surcharge carries ITS OWN row's bytes, not the income tax one")
        }
    }

    /// A row holding text that is **not JSON at all**, driven through the real
    /// database resolution — not through ``ReportSettings/classifyRate(_:)`` directly.
    ///
    /// This is the scheme-A hole and the most dangerous of the three families: in
    /// today's JavaScript `JSON.parse` throws, `readSetting`'s catch returns the
    /// FALLBACK, and `settingRowExists` has already answered true — so the gate opens
    /// and a US ledger is priced at China's 25%. Measured on the fixture:
    /// `annualIncomeTax = 1100`, byte-identical to the pre-#419 missing-row bug.
    ///
    /// It gets its own test because the family is invisible to every classifier-level
    /// test: `classifyRate` is called directly there, which skips the exact line where
    /// the fallback would be reintroduced. Found by mutation — reinstating the
    /// fallback inside `rate(_:_:locale:chinaFallback:)` left every other test green.
    func testRowsThatAreNotJSONAtAllNeedRepairThroughTheRealPath() throws {
        for raw in ["abc", "25%", "Infinity", "NaN"] {
            let db = try fixtureCopy("notjson-\(raw.count)-\(raw.first.map(String.init) ?? "e")")
            try put(db, "income_tax_rate", raw)
            try put(db, "surcharge_rate", raw)

            for locale in allLocales {
                XCTAssertEqual(ReportSettings.incomeTaxRate(db, locale: locale),
                               .needsRepair(rawValue: raw),
                               "\(locale): stored \(raw) is not JSON — it must NOT take the fallback")
                XCTAssertEqual(ReportSettings.surchargeRate(db, locale: locale),
                               .needsRepair(rawValue: raw), "\(locale): surcharge, same row shape")
                // China too: the fallback is for an ABSENT row, never for a present
                // one whose value cannot be read.
                XCTAssertNotEqual(ReportSettings.incomeTaxRate(db, locale: locale),
                                  .chinaFallback(25),
                                  "\(locale): a present-but-unreadable row is not an absent row")

                let ctx = try ReportDispatcher.context(db, locale: locale, source: .transactions,
                                                       year: "2025", from: "2025-01-01", to: "2025-12-31")
                XCTAssertNil(ctx.incomeTaxRate.rate, "\(locale): nothing reaches the engine to price with")
                XCTAssertEqual(ctx.incomeTaxRate.needsRepairRawValue, raw)
            }
        }
    }

    /// The same hole one level up: `number(_:_:fallback:)` — the faithful mirror of
    /// `readSetting` — still returns the fallback for these rows, and the rate gate
    /// must NOT be built on it.
    ///
    /// Pinned as a pair so the difference is visible rather than implied: the mirror
    /// keeps mirroring, and the gate declines to use it.
    func testTheReadSettingMirrorStillFallsBackAndIsDeliberatelyNotUsedByTheGate() throws {
        let db = try fixtureCopy("mirror-vs-gate")
        try put(db, "income_tax_rate", "abc")
        XCTAssertEqual(ReportSettings.number(db, "income_tax_rate", fallback: 25), 25,
                       "the readSetting mirror swallows the parse error and returns 25 — unchanged")
        XCTAssertEqual(ReportSettings.incomeTaxRate(db, locale: "US"),
                       .needsRepair(rawValue: "abc"),
                       "…while the gate reads the bytes and refuses")
    }

    /// The other three variants keep the states R6 established.
    func testTheOtherVariantsAreUnchangedByTheFourthState() throws {
        let base = try fixtureCopy("base")
        XCTAssertEqual(ReportSettings.incomeTaxRate(base, locale: "US"), .configured(20))
        XCTAssertEqual(ReportSettings.surchargeRate(base, locale: "CN"), .configured(10),
                       "the fixture stores 10, not the engine's 12 fallback")

        let unset = try fixtureCopy("unset")
        try unset.execute(
            "DELETE FROM settings WHERE key IN ('vat_rate','surcharge_rate','income_tax_rate','admin_expense_annual')")
        XCTAssertEqual(ReportSettings.incomeTaxRate(unset, locale: "US"), .notConfigured)
        XCTAssertEqual(ReportSettings.incomeTaxRate(unset, locale: "CN"), .chinaFallback(25))
        XCTAssertEqual(ReportSettings.surchargeRate(unset, locale: "CN"), .chinaFallback(12))
        // Outside China a missing surcharge row is not-configured, and R7 must simply
        // not look — a Japanese report must not be blocked by a rate no Japanese line
        // reads. Pinned here so that rule has a test rather than only a comment.
        XCTAssertEqual(ReportSettings.surchargeRate(unset, locale: "JP"), .notConfigured)

        let zero = try fixtureCopy("zero")
        for key in ["vat_rate", "surcharge_rate", "income_tax_rate", "admin_expense_annual"] {
            try put(zero, key, "0")
        }
        XCTAssertEqual(ReportSettings.incomeTaxRate(zero, locale: "US"), .configured(0),
                       "an explicit 0% is a real, different answer")
        XCTAssertEqual(ReportSettings.surchargeRate(zero, locale: "CN"), .configured(0))
    }

    // MARK: - The divergence A4-3 has to close

    /// **Pinned on purpose.** After A4-2 the native model refuses a malformed rate
    /// while `electron/reports/*` still coerces it, so the committed goldens disagree
    /// with the model. That is expected — A4-2 is native-only and changes no golden —
    /// and it is asserted here so the gap is a fact under test rather than a surprise.
    ///
    /// A4-3 makes the engines refuse too, at which point these expectations become
    /// null / absent and this test is the one that says so.
    func testTheGoldensStillRecordTheOldCoercionUntilA4Dash3() throws {
        // Four non-CN engines flatten NaN to 0 through their `|| 0` rounders.
        for locale in ["JP", "EU", "KR", "TW"] {
            let key = locale == "EU" ? "profitLoss" : "incomeStatement"
            let block = try XCTUnwrap(try golden("malformed-\(locale)-2025")[key] as? [String: Any])
            XCTAssertEqual(block["incomeTax"] as? Double, 0,
                           "\(locale): TODAY the golden records 0 — A4-3 turns this null")
        }
        // The US estimate layer does the same.
        let us = try XCTUnwrap(try golden("malformed-US-2025")["estimatedTax"] as? [String: Any])
        XCTAssertEqual(us["annualIncomeTax"] as? Double, 0,
                       "US: TODAY 0 — A4-3 turns this null")

        // China is the exception and will NOT move in A4-3: `cn.js`'s rounder has no
        // `|| 0` guard, so the NaN already serialises as null. Same bytes, different
        // reason — an explicit refusal instead of an accident.
        let cn = try XCTUnwrap(try golden("malformed-CN-2025")["incomeStatement"] as? [String: Any])
        XCTAssertTrue(cn["taxSurcharge"] is NSNull, "CN already records null, via the NaN path")
        XCTAssertTrue(cn["netProfit"] is NSNull)

        // And the measurement that justifies the whole batch: a corrupt US ledger is
        // today indistinguishable from one that deliberately configured 0%.
        let zeroUS = try XCTUnwrap(try golden("zero-US-2025")["estimatedTax"] as? [String: Any])
        XCTAssertEqual(NSDictionary(dictionary: us), NSDictionary(dictionary: zeroUS),
                       "malformed and zero are the SAME document today — that is the defect")
    }

    /// The BOM fix lands in ``ReportSettings/jsonFragment(_:)``, so it also repairs the
    /// two OTHER settings readers — and those were producing a visible divergence today.
    ///
    /// This is not scope creep, it is where the bug was: the rate gate only made the
    /// pre-existing hole reachable from a new place. `accounting_locale` is the sharp
    /// one — a single BOM-prefixed row routed the SAME ledger to China's engine in
    /// Electron and the US engine here, which is a different regime for the entire
    /// report, not a rounding difference.
    func testTheBOMFixAlsoAlignsTheOtherSettingsReaders() throws {
        let db = try fixtureCopy("bom-others")
        try put(db, "accounting_locale", "\u{FEFF}\"US\"")
        try put(db, "admin_expense_annual", "\u{FEFF}5000")

        // `readSetting`'s catch returns the fallback on a parse failure, and now both
        // languages agree that these ARE parse failures.
        XCTAssertEqual(ReportSettings.string(db, "accounting_locale", fallback: "CN"), "CN",
                       "a BOM-prefixed locale is unparseable — the ledger must not silently switch regime")
        XCTAssertEqual(ReportSettings.number(db, "admin_expense_annual", fallback: 0), 0,
                       "…and an unparseable admin expense takes the 0 fallback, as it does in Electron")
    }

    /// The exact edge of what ``ReportRateSetting/needsRepair(rawValue:)`` promises.
    ///
    /// The payload is the stored TEXT before parsing and before coercion — and that
    /// promise stops at ``SQLiteDatabase``'s decoding boundary, which is NOT lossless.
    /// TEXT is read with `String(decoding:as: UTF8.self)`, deliberately (its own
    /// comment explains why `String(cString:)` would be worse: it stops at an embedded
    /// NUL and silently truncates), and that substitutes U+FFFD for invalid UTF-8.
    ///
    /// So a row holding `0xFF` does NOT come back as `0xFF`. Asserted rather than
    /// documented-and-hoped, because the difference between "the bytes in your ledger"
    /// and "the bytes your ledger's reader could decode" is exactly the kind of
    /// over-claim a repair flow would inherit and repeat to the user.
    ///
    /// The classification is unaffected: the substituted text is still not JSON, so
    /// the row is still needs-repair. Only the fidelity of the carried payload moves.
    func testInvalidUTF8ArrivesLossyAtTheDecodingBoundary() throws {
        let db = try fixtureCopy("invalid-utf8")
        // A lone 0xFF is not valid UTF-8 in any position. CAST(... AS TEXT) stores the
        // raw byte in the TEXT column without SQLite validating it.
        try db.execute("""
            INSERT INTO settings (key, value, updated_at)
            VALUES ('income_tax_rate', CAST(x'FF' AS TEXT), datetime('now'))
            ON CONFLICT(key) DO UPDATE SET value=CAST(x'FF' AS TEXT), updated_at=datetime('now')
            """)

        let s = ReportSettings.incomeTaxRate(db, locale: "US")
        XCTAssertEqual(s, .needsRepair(rawValue: "\u{FFFD}"),
                       "the row is still needs-repair, and the payload is what the decoder produced")
        XCTAssertNil(s.rate, "still nothing to price with")
        XCTAssertEqual(s.needsRepairRawValue, "\u{FFFD}")
        XCTAssertNotEqual(s.needsRepairRawValue, "\u{00FF}",
                          "it is NOT the original byte reinterpreted — it is the replacement character")

        // Same boundary through the row reader itself, so the loss is attributed to
        // SQLiteDatabase rather than to anything this batch added.
        XCTAssertEqual(ReportSettings.rawValue(db, "income_tax_rate"), "\u{FFFD}")

        // Valid UTF-8, including non-ASCII, is untouched — the promise still holds
        // everywhere a write path can actually reach.
        try put(db, "surcharge_rate", "十二%")
        XCTAssertEqual(ReportSettings.surchargeRate(db, locale: "CN"),
                       .needsRepair(rawValue: "十二%"),
                       "valid UTF-8 survives verbatim, multi-byte scalars included")
    }

    /// ``ReportMath/jsTrim(_:)`` — added by this batch and otherwise asserted nowhere.
    ///
    /// It exists because the coerced value cannot report emptiness: `Number("")` and
    /// `Number("   ")` are both 0, indistinguishable from a stored 0. If its whitespace
    /// set ever drifted from `stringToNumber`'s, an empty-ish string would start
    /// reading as a deliberate 0% — the exact confusion this batch exists to prevent.
    func testJSTrimMatchesTheCoercerItWasExtractedFrom() {
        for raw in ["", " ", "\t", "\n", "\r", "\u{000B}", "\u{000C}", "\u{00A0}",
                    "\u{FEFF}", "\u{2028}", "\u{2029}", "\u{1680}", "  \t\n  "] {
            XCTAssertEqual(ReportMath.jsTrim(raw), "",
                           "\(raw.unicodeScalars.map { String($0.value, radix: 16) }) is JS whitespace")
            // The pairing that matters: whatever trims to nothing coerces to 0, so the
            // emptiness question has to be asked separately — which is why jsTrim exists.
            XCTAssertEqual(ReportMath.stringToNumber(raw), 0)
            XCTAssertEqual(ReportSettings.classifyRate("\"\(raw)\""), .needsRepair(rawValue: "\"\(raw)\""),
                           "…and a rate that trims to nothing is corrupt, not 0%")
        }
        XCTAssertEqual(ReportMath.jsTrim(" 25 "), "25")
        XCTAssertEqual(ReportMath.jsTrim("2 5"), "2 5", "only the ends are trimmed")
        XCTAssertEqual(ReportMath.jsTrim("\u{FEFF}25\u{FEFF}"), "25")
    }

    // MARK: - One rule, two implementations

    /// The native classifier and A4-1's shipped write gate must agree, shape by shape.
    ///
    /// `electron/handlers/_rateValue.js` decides what may be STORED; this decides what
    /// may be PRICED. If they disagree, a user stores a rate the reports then refuse,
    /// or the reports price something the write gate would have rejected. Neither can
    /// be discovered by reading one file, so the corpus is asserted here and the JS
    /// side asserts the same corpus in `scripts/test-rate-write-gate.mjs`.
    ///
    /// Kept as literal expectations rather than by shelling out to node: this suite
    /// must run in `swift test` with no toolchain beyond Swift.
    ///
    /// **What that costs, stated plainly:** these are expectations ABOUT the JS side,
    /// not a comparison WITH it. The pairing is maintained by hand, and the JS guard
    /// (`scripts/test-rate-write-gate.mjs` §1.3) asserts a shorter stored-byte list
    /// than this one. Making the two literally share a corpus means touching an
    /// Electron-side file, which this batch is not allowed to do — registered as a
    /// follow-up rather than smuggled in.
    ///
    /// The `\u{FEFF}` rows below are here because this corpus MISSED them: a leading
    /// BOM made `JSONSerialization` parse where `JSON.parse` throws, and every test in
    /// this file passed anyway. Found by adversarial review, fixed in ``jsonFragment``.
    func testTheStoredShapeRulesMatchTheShippedWriteGate() {
        // (stored TEXT, usable?) — the same table as _rateValue.js's classifyStoredRate.
        let corpus: [(String, Bool)] = [
            ("25", true), ("25.5", true), ("0", true), ("-5", true), ("1e3", true),
            ("\"25\"", true), ("\"13\"", true), ("\" 25 \"", true), ("\"0\"", true),
            ("\"25%\"", false), ("\"\"", false), ("\"   \"", false), ("\"abc\"", false),
            ("\"Infinity\"", false),
            ("null", false), ("true", false), ("false", false),
            ("[]", false), ("[25]", false), ("[1,2]", false), ("{}", false), ("{\"v\":25}", false),
            ("abc", false), ("25%", false), ("", false), ("Infinity", false), ("NaN", false),
            // A leading BOM: Foundation's RFC-4627 sniffing eats it, JSON.parse does
            // not. Both sides must call it corrupt.
            ("\u{FEFF}25", false), ("\u{FEFF}5000", false), ("\u{FEFF}\"25\"", false),
            ("\u{FEFF}0", false), ("\u{FEFF}abc", false),
            // …but only at offset 0. These already agreed and must keep agreeing.
            (" \u{FEFF}25", false), ("25\u{FEFF}", false), ("\u{FEFF}\u{FEFF}25", false),
            // A BOM INSIDE a JSON string is usable on both sides — U+FEFF is JS
            // whitespace, so Number("\u{FEFF}25") is 25 in both languages.
            ("\"\u{FEFF}25\"", true),
        ]
        for (raw, usable) in corpus {
            XCTAssertEqual(ReportSettings.classifyRate(raw).isConfigured, usable,
                           "stored \(raw): native says \(!usable ? "corrupt" : "usable"), "
                           + "the write gate says \(usable ? "usable" : "corrupt")")
        }
    }

    /// `.configured` can never hold a non-finite value — over the whole corpus, not
    /// just the cases someone remembered to write down.
    func testNoStoredShapeCanProduceANonFiniteConfiguredRate() {
        let shapes = ["25", "1e3", "1e999", "-1e999", "\"1e999\"", "\"Infinity\"", "\"-Infinity\"",
                      "\"NaN\"", "\"0x19\"", "\"0b101\"", "null", "{}", "abc", "\"\""]
        for raw in shapes {
            if case .configured(let r) = ReportSettings.classifyRate(raw) {
                XCTAssertTrue(r.value.isFinite, "stored \(raw) produced a non-finite configured rate")
            }
        }
        // `1e999` is corrupt on both sides, by different routes — JSON.parse yields
        // +Infinity and the write gate rejects it as non-finite; Foundation throws
        // outright, so this side calls it unparseable. Same verdict, and the reason
        // is recorded because the two are not the same mechanism.
        XCTAssertNil(ReportSettings.classifyRate("1e999").rate)

        // A BOM at offset 0 is not JSON to `JSON.parse`, and must not be to us either.
        // Foundation's RFC-4627 sniffing would otherwise eat it and hand back a
        // perfectly good number — the exact hole ``ReportSettings/jsonFragment(_:)``
        // now closes before Foundation sees the bytes.
        XCTAssertEqual(ReportSettings.classifyRate("\u{FEFF}25"), .needsRepair(rawValue: "\u{FEFF}25"))
        XCTAssertNil(ReportSettings.jsonFragment("\u{FEFF}25"))
        // …and the fix must not over-reach: the same scalar inside a JSON string is
        // ordinary JS whitespace and stays usable.
        XCTAssertEqual(ReportSettings.classifyRate("\"\u{FEFF}25\""), .configured(25))
        // …while `"0x19"` is a JS numeric literal (25) and IS usable — recorded rather
        // than left to surprise someone, and matching the write gate exactly.
        XCTAssertEqual(ReportSettings.classifyRate("\"0x19\""), .configured(25))
    }
}
