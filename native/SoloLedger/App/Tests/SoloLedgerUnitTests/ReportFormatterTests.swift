import XCTest
@testable import SoloLedger

/// R8 P3a — the number, currency and stored-text formatting rules.
///
/// The assertions come in two strengths on purpose. Structural ones (exactly two fraction
/// digits, no currency symbol, the escape is applied) hold in every language and survive an
/// ICU update. Byte-exact ones are applied to `en` and `zh-Hans` only — French groups digits
/// with a separator whose code point has changed between OS releases, and pinning that byte
/// would make the suite fail for a reason that has nothing to do with this app.
final class ReportFormatterTests: XCTestCase {

    private let languages = ["zh-Hans", "zh-Hant", "en", "ja", "ko", "fr"]

    /// The digits after the locale's decimal separator.
    private func fractionDigits(_ text: String, language: String) -> String? {
        let separator = Locale(identifier: language).decimalSeparator ?? "."
        guard let range = text.range(of: separator, options: .backwards) else { return nil }
        return String(text[range.upperBound...])
    }

    // MARK: - Money: always two decimals, never a currency symbol

    // T16
    func testMoneyAlwaysCarriesExactlyTwoFractionDigitsInEveryLanguage() {
        for language in languages {
            for value in [0, 1, 1234.5, -1234.5, 0.005, -9.999, 1e12] as [Double] {
                let text = ReportFormat.money(value, language: language)
                let digits = fractionDigits(text, language: language)
                XCTAssertEqual(digits?.count, 2,
                               "\(language) money(\(value)) = \(text) has \(digits?.count ?? -1) "
                               + "fraction digits")
                XCTAssertTrue(digits?.allSatisfy { $0.isNumber } ?? false,
                              "\(language) money(\(value)) = \(text)")
            }
        }
    }

    func testMoneyIsByteExactWhereTheSeparatorIsStable() {
        for language in ["en", "zh-Hans"] {
            XCTAssertEqual(ReportFormat.money(0, language: language), "0.00")
            XCTAssertEqual(ReportFormat.money(1234.5, language: language), "1,234.50")
            XCTAssertEqual(ReportFormat.money(-1234.5, language: language), "-1,234.50")
            XCTAssertEqual(ReportFormat.money(0.005, language: language), "0.01")
        }
    }

    /// The currency never reaches `NumberFormatter`, so no symbol can appear — not the one
    /// for the ledger's code and not an improvised one for a code ICU does not know.
    func testMoneyNeverEmitsACurrencySymbolOrLetter() {
        for language in languages {
            let text = ReportFormat.money(1234.5, language: language)
            for symbol in ["¥", "$", "€", "₩", "£", "￥", "NT", "CN", "USD"] {
                XCTAssertFalse(text.contains(symbol), "\(language): \(text) contains \(symbol)")
            }
            XCTAssertFalse(text.contains(where: { $0.isLetter }), "\(language): \(text)")
        }
    }

    // T17 — the A10 rule
    func testANegativeValueThatRoundsToZeroLosesItsSignAndNothingElseIsClamped() {
        for language in ["en", "zh-Hans"] {
            // The rule: a minus sign in front of a zero reads as a loss that is not there.
            XCTAssertEqual(ReportFormat.money(-0.004, language: language), "0.00")
            XCTAssertEqual(ReportFormat.money(-0.0001, language: language), "0.00")
            XCTAssertEqual(ReportFormat.money(-0.0, language: language), "0.00")
            XCTAssertEqual(ReportFormat.money(0.004, language: language), "0.00")

            // …and it is a SIGN rule, not a clamp. Everything that rounds to a non-zero
            // figure keeps its value and its sign.
            XCTAssertEqual(ReportFormat.money(-0.005, language: language), "-0.01")
            XCTAssertEqual(ReportFormat.money(-0.01, language: language), "-0.01")
            XCTAssertEqual(ReportFormat.money(-0.6, language: language), "-0.60")
            XCTAssertEqual(ReportFormat.money(-1, language: language), "-1.00")
        }
        // In every language the rounded-to-zero case is free of a minus sign.
        for language in languages {
            XCTAssertFalse(ReportFormat.money(-0.004, language: language).contains("-"),
                           "\(language) kept a sign on a value that rounds to zero")
            XCTAssertTrue(ReportFormat.money(-0.005, language: language).contains("-"),
                          "\(language) dropped the sign of a real negative")
        }
    }

    // MARK: - Percent: already in percentage points

    // T14 / T15
    func testPercentDoesNotMultiplyAgain() {
        XCTAssertEqual(ReportFormat.percent(12.34, language: "en"), "12.34%")
        XCTAssertEqual(ReportFormat.percent(12.34, language: "zh-Hans"), "12.34%")
        // The falsification: `NumberFormatter`'s `.percent` style would answer "50%" here,
        // because it multiplies by 100 a second time. The engines already did that.
        XCTAssertEqual(ReportFormat.percent(0.5, language: "en"), "0.50%")
        XCTAssertNotEqual(ReportFormat.percent(0.5, language: "en"), "50.00%")
        XCTAssertEqual(ReportFormat.percent(100, language: "en"), "100.00%")
        XCTAssertEqual(ReportFormat.percent(0, language: "en"), "0.00%")
        XCTAssertEqual(ReportFormat.percent(-0.004, language: "en"), "0.00%")
    }

    func testPercentAlwaysEndsWithTheSignAndTwoDigits() {
        for language in languages {
            let text = ReportFormat.percent(12.34, language: language)
            XCTAssertTrue(text.hasSuffix("%"), "\(language): \(text)")
            let digits = fractionDigits(String(text.dropLast()), language: language)
            XCTAssertEqual(digits?.count, 2, "\(language): \(text)")
        }
    }

    // MARK: - Currency code

    // T19 — a three-letter code is passed through, with NO annotation and NO validity claim
    func testAThreeLetterCodeIsPassedThroughUnchangedWhateverItSays() {
        for code in ["CNY", "USD", "EUR", "XYZ", "usd", "Xyz", "ZZZ"] {
            XCTAssertEqual(ReportFormat.currencyShape(code), .threeLetter, code)
            XCTAssertEqual(ReportFormat.currencyDisplay(code), code,
                           "\(code) must be shown byte for byte — no upper-casing, no note")
        }
        // The correction this test exists for: `XYZ` is not an ISO code, but it IS three
        // letters, so it must be treated exactly like `CNY` here. The app never claims a code
        // is valid, and it must not single one out as anomalous either.
        XCTAssertEqual(ReportFormat.currencyShape("XYZ"), ReportFormat.currencyShape("CNY"))
    }

    // T20
    func testANonThreeLetterCodeIsEscapedAndMarkedAsAFormatDifference() {
        let cases = ["CN", "CNYY", " CNY ", "人民币", "", "12", "C N", "US$",
                     String(repeating: "A", count: 200)]
        for code in cases {
            XCTAssertEqual(ReportFormat.currencyShape(code), .other, "\(code.debugDescription)")
        }
        // `resolveCurrency` accepts a value that merely TRIMS to non-empty and returns it
        // untrimmed, so a padded code really can arrive here.
        XCTAssertEqual(ReportFormat.currencyDisplay(" CNY "), " CNY ")
        XCTAssertEqual(ReportFormat.currencyDisplay("人民币"), "人民币")
        XCTAssertEqual(ReportFormat.currencyDisplay(String(repeating: "A", count: 200)).count,
                       ReportFormat.previewCharacterLimit + 1)
    }

    func testAControlOrBidiCurrencyCodeCannotActOnTheLayout() {
        let control = ReportFormat.currencyDisplay("A\u{0}B")
        XCTAssertFalse(control.unicodeScalars.contains { $0.value == 0 })
        XCTAssertTrue(control.contains("<U+0000>"))

        let bidi = ReportFormat.currencyDisplay("\u{202E}USD")
        XCTAssertFalse(bidi.unicodeScalars.contains { $0.value == 0x202E })
        XCTAssertTrue(bidi.contains("<U+202E>"))
        XCTAssertEqual(ReportFormat.currencyShape("\u{202E}USD"), .other)
    }

    // MARK: - Stored text

    // T22 / T23 / T27
    func testTheQuotesOfAStoredValueSurviveAndTheTwoMalformedRowsStayDistinct() {
        // `malformed` stores the five bytes `"25%"`; `malformed-raw` stores the three bytes
        // `25%`. They look different to a user and they ARE different rows.
        XCTAssertEqual(ReportFormat.safePreview("\"25%\""), "\"25%\"")
        XCTAssertEqual(ReportFormat.safePreview("25%"), "25%")

        // The falsification. If anyone ever adds a "tidy the quotes away" step, this is the
        // assertion that fails — and it fails for the right reason: stripping the quotes
        // destroys the only evidence a repair flow has that the two rows differ.
        XCTAssertNotEqual(ReportFormat.safePreview("\"25%\""), ReportFormat.safePreview("25%"))
    }

    func testAStoredValueIsNeitherTrimmedNorNormalised() {
        XCTAssertEqual(ReportFormat.safePreview("  25  "), "  25  ")
        XCTAssertEqual(ReportFormat.safePreview("null"), "null")
        XCTAssertEqual(ReportFormat.safePreview("[5000]"), "[5000]")
        XCTAssertEqual(ReportFormat.safePreview("{}"), "{}")
        // A composed and a decomposed é are different byte sequences and stay that way.
        XCTAssertEqual(ReportFormat.safePreview("e\u{0301}"), "e\u{0301}")
        XCTAssertNotEqual(ReportFormat.safePreview("e\u{0301}").unicodeScalars.count,
                          ReportFormat.safePreview("\u{00E9}").unicodeScalars.count)
    }

    // T24 / T26
    func testControlAndBidiScalarsBecomeLiterals() {
        XCTAssertEqual(ReportFormat.safePreview("2\u{0}5"), "2<U+0000>5")
        XCTAssertEqual(ReportFormat.safePreview("a\tb"), "a<U+0009>b")
        XCTAssertEqual(ReportFormat.safePreview("a\u{7F}b"), "a<U+007F>b")
        XCTAssertEqual(ReportFormat.safePreview("a\u{2028}b"), "a<U+2028>b")
        XCTAssertEqual(ReportFormat.safePreview("a\u{202E}b"), "a<U+202E>b")
        XCTAssertEqual(ReportFormat.safePreview("a\u{2066}b"), "a<U+2066>b")
        // A newline is a control character too: a stored value must not be able to add rows
        // to the layout it is displayed in.
        XCTAssertEqual(ReportFormat.safePreview("a\nb"), "a<U+000A>b")
        // Ordinary text is untouched — the escape must not be a blanket rewrite.
        XCTAssertEqual(ReportFormat.safePreview("25% 增值税 🙂"), "25% 增值税 🙂")
    }

    /// P4c-2: U+FEFF joins the set, and it is the one that matters most on this screen.
    ///
    /// It renders as nothing at all, and on `accounting_locale` it IS the defect:
    /// `JSONSerialization` eats a leading one while `JSON.parse` rejects it, so an invisible
    /// byte made the Settings screen say United States while the report engines refused the
    /// same row. A preview whose whole job is to show the user what is really in their ledger
    /// cannot leave that byte invisible.
    ///
    /// The escape is a DISPLAY transform only — the stored text itself is still carried byte
    /// for byte (pinned by `AccountingLocaleReadAlignmentTests`), so this makes the evidence
    /// legible rather than altering it.
    func testTheByteOrderMarkIsMadeVisible() {
        XCTAssertEqual(ReportFormat.safePreview("a\u{FEFF}b"), "a<U+FEFF>b")
        XCTAssertEqual(ReportFormat.safePreview("\u{FEFF}\"US\""), "<U+FEFF>\"US\"")
        // A row that is merely `"US"` must still read as itself — the escape may not fire
        // where there is no BOM, or the two rows would look the same again.
        XCTAssertEqual(ReportFormat.safePreview("\"US\""), "\"US\"")
        XCTAssertNotEqual(ReportFormat.safePreview("\u{FEFF}\"US\""),
                          ReportFormat.safePreview("\"US\""),
                          "the damaged row and the good one must not render identically")
    }

    // T25
    func testThePreviewConsumesAtMostOneHundredAndTwentySourceCharacters() {
        let plain = String(repeating: "x", count: 10_000)
        let preview = ReportFormat.safePreview(plain)
        XCTAssertEqual(preview.count, ReportFormat.previewCharacterLimit + 1)
        XCTAssertTrue(preview.hasSuffix("…"))
        XCTAssertEqual(preview.dropLast().count, ReportFormat.previewCharacterLimit)

        // Exactly at the limit there is no ellipsis — the cap is on what is READ, so a string
        // that fits is shown whole.
        let exact = String(repeating: "x", count: ReportFormat.previewCharacterLimit)
        XCTAssertEqual(ReportFormat.safePreview(exact), exact)
        XCTAssertFalse(ReportFormat.safePreview(exact).hasSuffix("…"))

        // Escaping makes the RENDERED string longer than the cap, and that is intended: the
        // bound is on the source, and it is still a bound.
        let controls = String(repeating: "\u{0}", count: 10_000)
        let escaped = ReportFormat.safePreview(controls)
        XCTAssertTrue(escaped.hasSuffix("…"))
        XCTAssertLessThanOrEqual(escaped.count, ReportFormat.previewCharacterLimit * 9 + 1)
        XCTAssertFalse(escaped.unicodeScalars.contains { $0.value == 0 })

        XCTAssertEqual(ReportFormat.safePreview(""), "")
    }

    // MARK: - The year domain

    // T28
    func testOnlyFourAsciiDigitsInsideTheSoundDomainAreAccepted() {
        for text in ["0001", "1998", "2025", "9999"] {
            XCTAssertTrue(ReportYear.isValid(text), text)
            XCTAssertEqual(ReportYear.text(ReportYear.value(text) ?? -1), text)
        }
        // Outside the domain a TEXT date comparison would silently mis-order, so entry is
        // refused rather than clamped: clamping would run a year nobody asked for.
        for text in ["999", "10000", "20a5", "", " 2025", "2025 ", "0000", "-999", "٢٠٢٥",
                     "2_25", "20255"] {
            XCTAssertFalse(ReportYear.isValid(text), text.debugDescription)
            XCTAssertNil(ReportYear.value(text), text.debugDescription)
        }
    }

    func testSteppingStaysInsideTheDomainAndNeverWraps() {
        XCTAssertEqual(ReportYear.stepped("2025", by: 1), "2026")
        XCTAssertEqual(ReportYear.stepped("2025", by: -1), "2024")
        XCTAssertEqual(ReportYear.stepped("0001", by: -1), "0001")
        XCTAssertEqual(ReportYear.stepped("9999", by: 1), "9999")
        XCTAssertEqual(ReportYear.stepped("0002", by: -1), "0001")
        // A value that is not a year is returned untouched rather than silently repaired.
        XCTAssertEqual(ReportYear.stepped("20", by: 1), "20")
    }

    func testTheYearTextIsAlwaysFourDigits() {
        XCTAssertEqual(ReportYear.text(1), "0001")
        XCTAssertEqual(ReportYear.text(42), "0042")
        XCTAssertEqual(ReportYear.text(2025), "2025")
        // Out-of-range input to `text` is clamped INTO the domain, because its job is to
        // produce a renderable string; validation of user input is `value`'s job.
        XCTAssertEqual(ReportYear.text(0), "0001")
        XCTAssertEqual(ReportYear.text(-5), "0001")
        XCTAssertEqual(ReportYear.text(123_456), "9999")
    }

    func testTheCurrentYearMappingIsPinnedWithoutWaitingForADate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var components = DateComponents()
        components.year = 2025
        components.month = 6
        components.day = 15
        let date = try XCTUnwrap(calendar.date(from: components))
        XCTAssertEqual(ReportYear.currentYearText(now: date, calendar: calendar), "2025")

        components.year = 1998
        let old = try XCTUnwrap(calendar.date(from: components))
        XCTAssertEqual(ReportYear.currentYearText(now: old, calendar: calendar), "1998")
        XCTAssertTrue(ReportYear.isValid(ReportYear.currentYearText()))
    }
}
