import XCTest
@testable import SoloLedgerCore

/// D-1 · Q4 — the document arithmetic, against the JavaScript it reproduces.
///
/// Every expected value here was produced by running the REAL expression in node v24, not by
/// reading the source: an oracle script evaluated `DocumentModal.tsx`'s `round2` / `computed` and
/// `documents.js`'s `num` / `round2` / `sumTotals` verbatim over a grid of 29,446 rows
/// (14,045 scalars × 2 chains, 10,560 quantity × price × rate triples, 412 line sets, 165 trim
/// inputs, 4,235 `parseFloat` inputs, 29 tax-rate strings) and this implementation replayed it with
/// **zero divergences over 54,875 comparisons**. What is committed below is the subset that pins
/// each decision individually, so a regression names itself instead of arriving as "the corpus
/// changed".
///
/// The corpus itself is deliberately NOT committed. `DocumentMath.round` is pinned equal to
/// `ReportMath.round` here, and THAT function is replayed against a committed V8 corpus in
/// `ReportMathTests`, so the engine-measured oracle reaches this file through an equality a test
/// enforces rather than through a second 2.7 MB fixture that would need its own CI wiring.
///
/// D-2 added ``DocumentMath/jsNumberToString(_:)`` and measured it the same way: **67,624 doubles,
/// zero mismatches** against node's `String(n)` — every `parseInt` of a 1-to-64-digit run and that
/// value plus one, every integer to 5,000, every power of ten from `1e-330` to `1e330` and its two
/// neighbours, the values around 2^53 / 2^63 / 1e21, 60,000 seeded pseudo-random doubles, and the
/// named edges. The pinned cases below are the subset where each layout rule decides the answer.
final class DocumentMathTests: XCTestCase {

    // MARK: - `Math.round`

    /// The five values where the two obvious Swift spellings each break, from `ReportMath.round`'s
    /// own table. Ties go toward `+∞`, not away from zero, and `floor(x + 0.5)` is not equivalent.
    func testRoundReproducesTheFiveValuesThatBreakBothObviousSpellings() {
        XCTAssertEqual(DocumentMath.round(0.49999999999999994), 0, "floor(x + 0.5) would answer 1")
        XCTAssertEqual(DocumentMath.round(-2.5), -2, "x.rounded() would answer -3")
        XCTAssertEqual(DocumentMath.round(-12.5), -12, "x.rounded() would answer -13")
        XCTAssertEqual(DocumentMath.round(2.5), 3, "ties go toward +∞")
        XCTAssertEqual(DocumentMath.round(-0.5).sign, .minus, "Math.round(-0.5) is -0, not +0")
        XCTAssertEqual(DocumentMath.round(-0.4).sign, .minus, "Math.round(-0.4) is -0, not +0")
    }

    /// `-0` is a distinct bit pattern that compares equal to `0`, so an assertion written with
    /// `XCTAssertEqual` alone cannot see it. This one looks at the sign bit.
    func testRoundPreservesNegativeZeroThroughTheDivideByOneHundred() {
        XCTAssertEqual(DocumentMath.storedRound2(-0.001).sign, .minus,
                       "Math.round(-0.001 * 100) / 100 is -0 in node; the sign must survive")
        XCTAssertEqual(DocumentMath.storedRound2(-0.001), 0, "…and it still compares equal to zero")
    }

    /// The equality that gives this file its oracle: three copies of the same rule, pinned equal.
    ///
    /// They are separate on purpose — one rounding rule per subsystem, so a change made for a
    /// report golden cannot silently change what a customer is invoiced — and this is what makes
    /// "separate" different from "free to drift".
    func testTheThreeCopiesOfMathRoundAgreeEverywhere() {
        var values: [Double] = [0, -0.0, 0.49999999999999994, -0.49999999999999994, 0.5, -0.5,
                                2.5, -2.5, 12.5, -12.5, 4503599627370496, -4503599627370496,
                                .greatestFiniteMagnitude, -.greatestFiniteMagnitude,
                                .leastNonzeroMagnitude, -.leastNonzeroMagnitude,
                                .infinity, -.infinity, .nan]
        for i in -20_000...20_000 { values.append(Double(i) / 8) }
        var generator = SplitMix64(seed: 0x5EED_D1D1)
        for _ in 0..<20_000 { values.append(generator.nextDouble(magnitude: 1e9)) }

        for x in values {
            let mine = DocumentMath.round(x)
            let report = ReportMath.round(x)
            let metrics = MonthlyComparisons.jsRound(x)
            if x.isNaN {
                XCTAssertTrue(mine.isNaN && report.isNaN && metrics.isNaN, "NaN in, NaN out")
                continue
            }
            XCTAssertEqual(mine.bitPattern, report.bitPattern, "ReportMath disagrees at \(x)")
            XCTAssertEqual(mine.bitPattern, metrics.bitPattern, "MonthlyComparisons disagrees at \(x)")
        }
    }

    // MARK: - The two round2 chains

    /// The editor's chain and the handler's chain differ on exactly three values. Measured in node
    /// over 14,045 scalars: these three and nothing else.
    func testTheTwoRound2ChainsDifferOnNegativeZeroAndOnInfinity() {
        // `-0` is falsy, so the editor's `|| 0` flattens it; `num()` keeps it, because it is finite.
        XCTAssertEqual(DocumentMath.lineRound2(-0.0).sign, .plus)
        XCTAssertEqual(DocumentMath.storedRound2(-0.0).sign, .minus)
        // `Infinity` is truthy, so the editor's chain carries it; `Number.isFinite` folds it to 0.
        XCTAssertEqual(DocumentMath.lineRound2(.infinity), .infinity)
        XCTAssertEqual(DocumentMath.storedRound2(.infinity), 0)
        XCTAssertEqual(DocumentMath.lineRound2(-.infinity), -.infinity)
        XCTAssertEqual(DocumentMath.storedRound2(-.infinity), 0)
    }

    /// …and agree on everything else, which is the half that makes the previous test a statement
    /// about three values rather than about an unexplored difference.
    func testTheTwoRound2ChainsAgreeOnEveryOtherValue() {
        var values: [Double] = [0, .nan, 0.005, -0.005, 1.005, 2.675, 99999999.995, 1 / 3]
        for i in -10_000...10_000 { values.append(Double(i) / 200) }
        var generator = SplitMix64(seed: 0xC0FF_EE01)
        for _ in 0..<20_000 { values.append(generator.nextDouble(magnitude: 1e6)) }

        for x in values where x != 0 && x.isFinite {
            XCTAssertEqual(DocumentMath.lineRound2(x).bitPattern,
                           DocumentMath.storedRound2(x).bitPattern,
                           "the chains disagree at \(x), which the node scan says they should not")
        }
        // Both fold `nil` and `NaN` to +0 — by different routes, to the same bit pattern.
        for chain in [DocumentMath.lineRound2, DocumentMath.storedRound2] {
            XCTAssertEqual(chain(nil).bitPattern, (0.0).bitPattern)
            XCTAssertEqual(chain(.nan).bitPattern, (0.0).bitPattern)
        }
    }

    /// The two folds, pinned directly. `truthyOrZero`'s `-0` arm and `finiteOrZero`'s `±∞` arm are
    /// each invisible through the chains above without the sign/finite check, because `-0 == 0`.
    func testTheTwoFoldsDifferInBothDirections() {
        XCTAssertEqual(DocumentMath.truthyOrZero(-0.0).sign, .plus, "JS: -0 is falsy")
        XCTAssertEqual(DocumentMath.finiteOrZero(-0.0).sign, .minus, "JS: -0 is finite")
        XCTAssertEqual(DocumentMath.truthyOrZero(.infinity), .infinity, "JS: Infinity is truthy")
        XCTAssertEqual(DocumentMath.finiteOrZero(.infinity), 0, "JS: Infinity is not finite")
        for fold in [DocumentMath.truthyOrZero, DocumentMath.finiteOrZero] {
            XCTAssertEqual(fold(nil), 0)
            XCTAssertEqual(fold(.nan), 0)
            XCTAssertEqual(fold(7.5), 7.5)
        }
    }

    // MARK: - Q4 · the line arithmetic

    /// **The order of the two roundings is a different answer, not a style.** Q4 asks for a case
    /// where "round then multiply" and "multiply then round" disagree; the node scan found 29 of
    /// them in a 1,287-cell grid, and these are four.
    func testTheRoundingOrderChangesTheTaxAndTheSpecifiedOrderIsRoundFirst() {
        // (quantity, unit price, rate %, expected amount, expected tax, what one step would give)
        let cases: [(Double, Double, Double, Double, Double, Double)] = [
            (1, 3.335, 25, 3.34, 0.84, 0.83),
            (0.5, 2.675, 25, 1.34, 0.34, 0.33),
            (3, 2.675, 21, 8.02, 1.68, 1.69),
            (7, 3.335, 10, 23.35, 2.34, 2.33),
        ]
        for (quantity, price, rate, expectedAmount, expectedTax, oneStep) in cases {
            let amount = DocumentMath.lineAmount(quantity: quantity, unitPrice: price)
            XCTAssertEqual(amount, expectedAmount, "amount for \(quantity) × \(price)")
            XCTAssertEqual(DocumentMath.lineTax(amount: amount, ratePercent: rate), expectedTax,
                           "tax for \(quantity) × \(price) @ \(rate)%")
            XCTAssertNotEqual(expectedTax, oneStep,
                              "this case would not discriminate the two orders")
            XCTAssertNotEqual(DocumentMath.lineRound2(quantity * price * rate / 100), expectedTax,
                              "one-step rounding must NOT reproduce the two-step answer here")
        }
    }

    /// An empty editor field is `parseFloat("") || 0`, i.e. zero — for either factor and for the
    /// rate. A non-finite factor is folded the same way, because the editor's `|| 0` sees it first.
    func testAnEmptyFieldIsZeroInTheLineArithmetic() {
        XCTAssertEqual(DocumentMath.lineAmount(quantity: nil, unitPrice: 10), 0)
        XCTAssertEqual(DocumentMath.lineAmount(quantity: 10, unitPrice: nil), 0)
        XCTAssertEqual(DocumentMath.lineAmount(quantity: .nan, unitPrice: 10), 0)
        XCTAssertEqual(DocumentMath.lineTax(amount: 100, ratePercent: nil), 0)
        // Infinity is truthy, so it is NOT folded — it multiplies, and the editor's chain keeps it.
        XCTAssertEqual(DocumentMath.lineAmount(quantity: .infinity, unitPrice: 1), .infinity)
        // …but Infinity × 0 is NaN, and NaN is folded by the round2 that follows.
        XCTAssertEqual(DocumentMath.lineAmount(quantity: .infinity, unitPrice: 0), 0)
    }

    // MARK: - Q4 · the header totals

    /// `sumTotals` sums the STORED line values. The header of a document whose lines were copied
    /// rather than computed must agree with those lines, not with a fresh quantity × price.
    func testTotalsSumTheStoredLineValuesAndNeverRecompute() {
        let totals = DocumentMath.totals(ofLines: [(amount: 100, taxAmount: 13),
                                                   (amount: 200, taxAmount: 26)])
        XCTAssertEqual(totals.subtotal, 300)
        XCTAssertEqual(totals.taxAmount, 39)
        XCTAssertEqual(totals.total, 339)
    }

    /// A `nil` money field contributes `0` — `num(undefined)` — while remaining a distinct value in
    /// the row itself. This is what lets a statement line hold SQL `NULL` tax without disturbing
    /// the header.
    func testANilLineValueContributesZeroToTheTotals() {
        let totals = DocumentMath.totals(ofLines: [(amount: 50, taxAmount: nil),
                                                   (amount: nil, taxAmount: 4)])
        XCTAssertEqual(totals.subtotal, 50)
        XCTAssertEqual(totals.taxAmount, 4)
        XCTAssertEqual(totals.total, 54)
    }

    func testTotalsOfNoLinesAreAllZero() {
        let totals = DocumentMath.totals(ofLines: [])
        XCTAssertEqual(totals.subtotal, 0)
        XCTAssertEqual(totals.taxAmount, 0)
        XCTAssertEqual(totals.total, 0)
    }

    /// The fold runs left to right in the order the lines are given, because floating-point
    /// addition is not associative. Reordering the same three lines is a different subtotal — so a
    /// "tidy-up" that sorted or grouped the lines first would change the ledger.
    func testTheFoldOrderIsPartOfTheAnswer() {
        func subtotal(_ amounts: [Double]) -> Double {
            DocumentMath.totals(ofLines: amounts.map { (amount: $0, taxAmount: 0) }).subtotal
        }
        // Three half-cent lines. `0.005 + 0.015` then `+ 0.015` lands just ABOVE the 3.5 tie once
        // scaled; `0.015 + 0.015` then `+ 0.005` lands just below it. One cent of difference, from
        // nothing but the order of three identical-looking additions.
        XCTAssertEqual(subtotal([0.005, 0.015, 0.015]), 0.04)
        XCTAssertEqual(subtotal([0.015, 0.015, 0.005]), 0.03)
        // And at a magnitude where the small line is absorbed entirely rather than nudged.
        XCTAssertEqual(subtotal([0.005, 1e16, -1e16]), 0, "1e16 swallows the half cent")
        XCTAssertEqual(subtotal([-1e16, 1e16, 0.005]), 0.01, "…unless it is added last")
    }

    /// `±∞` in a line becomes `0` in the total, because the handler's rounder folds it. The result
    /// is a total that silently disagrees with a line the caller passed in — registered, and
    /// reproduced deliberately (Q9).
    func testANonFiniteLineIsSilentlyFlattenedInTheTotals() {
        let totals = DocumentMath.totals(ofLines: [(amount: .infinity, taxAmount: 1),
                                                   (amount: -.infinity, taxAmount: 1)])
        // `num()` is applied to each line BEFORE it is added, so each infinity becomes 0 on its
        // own; the sum never becomes `NaN`. Adding the raw values first would — and would then be
        // folded to 0 too, which is why this needs the intermediate stated rather than the result.
        XCTAssertEqual(totals.subtotal, 0, "each ±∞ line is folded to 0 individually")
        XCTAssertTrue((Double.infinity + -Double.infinity).isNaN,
                      "…whereas summing them raw is NaN — a different route to the same total here")
        XCTAssertEqual(totals.taxAmount, 2)
        XCTAssertEqual(totals.total, 2)
    }

    // MARK: - Tax-rate text

    func testTaxRateTextIsReadBackWithTheEditorsOwnChain() {
        XCTAssertNil(DocumentMath.taxRatePercent(from: nil), "no rate stored")
        XCTAssertNil(DocumentMath.taxRatePercent(from: ""), "JS `!it.taxRate` catches the empty string")
        XCTAssertEqual(DocumentMath.taxRatePercent(from: "13%"), 13)
        XCTAssertEqual(DocumentMath.taxRatePercent(from: "13"), 13, "the % is optional on the way in")
        XCTAssertEqual(DocumentMath.taxRatePercent(from: "17.5%"), 17.5)
        XCTAssertEqual(DocumentMath.taxRatePercent(from: "-13%"), -13)
        XCTAssertEqual(DocumentMath.taxRatePercent(from: ".5%"), 0.5)
        XCTAssertEqual(DocumentMath.taxRatePercent(from: "1e2%"), 100)
        XCTAssertNil(DocumentMath.taxRatePercent(from: "abc"))
        XCTAssertNil(DocumentMath.taxRatePercent(from: "%"))
    }

    /// An explicit zero rate is NOT "no rate". Losing that distinction would make a re-save invent
    /// a rate on a line that had none, or drop the zero from one that chose it.
    func testAZeroRateIsDistinctFromNoRate() {
        XCTAssertEqual(DocumentMath.taxRatePercent(from: "0%"), 0)
        XCTAssertNotNil(DocumentMath.taxRatePercent(from: "0%"))
        XCTAssertNil(DocumentMath.taxRatePercent(from: nil))
    }

    /// `Number.isFinite(n)` is the last gate in the editor's chain, so `"Infinity%"` reads back as
    /// no rate rather than as an infinite one.
    func testANonFiniteRateReadsBackAsNoRate() {
        XCTAssertNil(DocumentMath.taxRatePercent(from: "Infinity%"))
        XCTAssertNil(DocumentMath.taxRatePercent(from: "-Infinity"))
    }

    /// JS `String.replace` with a string pattern replaces ONE occurrence, so a second `%` stays and
    /// ends the numeric prefix where it stands.
    func testOnlyTheFirstPercentSignIsRemoved() {
        XCTAssertEqual(DocumentMath.taxRatePercent(from: "13%%"), 13)
        XCTAssertNil(DocumentMath.taxRatePercent(from: "%%13"), "the surviving % precedes the digits")
    }

    // MARK: - `String.prototype.trim`

    /// All 25 code points ECMAScript trims, one at a time, on both sides.
    func testEveryEcmascriptWhitespaceCodePointIsTrimmed() {
        let scalars: [Unicode.Scalar] = ["\u{0009}", "\u{000A}", "\u{000B}", "\u{000C}", "\u{000D}",
                                         "\u{0020}", "\u{00A0}", "\u{1680}",
                                         "\u{2000}", "\u{2001}", "\u{2002}", "\u{2003}", "\u{2004}",
                                         "\u{2005}", "\u{2006}", "\u{2007}", "\u{2008}", "\u{2009}",
                                         "\u{200A}", "\u{2028}", "\u{2029}", "\u{202F}", "\u{205F}",
                                         "\u{3000}", "\u{FEFF}"]
        XCTAssertEqual(scalars.count, 25, "ECMAScript's StrWhiteSpace has 25 code points")
        XCTAssertEqual(Set(scalars), DocumentMath.stringWhitespace, "…and the set must be those 25")
        for scalar in scalars {
            let padded = "\(scalar)Acme\(scalar)"
            XCTAssertEqual(DocumentMath.jsTrim(padded), "Acme",
                           "U+\(String(format: "%04X", scalar.value)) was not trimmed")
        }
    }

    /// **U+0085 NEL is the trap.** Foundation's `.whitespacesAndNewlines` contains it; ECMAScript's
    /// `StrWhiteSpace` does not. Trimming it would let a counterparty match here that does not
    /// match in Electron — a difference measured in money on the resulting statement.
    func testTheCharactersEcmascriptDoesNotTrimSurvive() {
        for scalar in ["\u{0085}", "\u{200B}", "\u{180E}", "\u{2060}", "\u{0000}", "\u{001F}"] {
            let padded = "\(scalar)Acme\(scalar)"
            XCTAssertEqual(DocumentMath.jsTrim(padded), padded,
                           "U+\(String(format: "%04X", scalar.unicodeScalars.first!.value)) must NOT be trimmed")
        }
        XCTAssertFalse(DocumentMath.stringWhitespace.contains("\u{0085}"),
                       "NEL is in Foundation's set and not in ECMAScript's; this file uses ECMAScript's")
    }

    /// Trimming runs on scalars, not on `Character`s: a grapheme cluster that merely BEGINS with a
    /// space (a combining mark applied to one) is a single `Character` that must not vanish whole.
    func testTrimmingOperatesOnScalarsSoACombiningClusterIsNotEatenWhole() {
        let spaceWithAcute = "\u{0020}\u{0301}"
        XCTAssertEqual(spaceWithAcute.count, 1, "…it really is one Character")
        XCTAssertEqual(DocumentMath.jsTrim(spaceWithAcute), "\u{0301}",
                       "JS drops the space code unit and keeps the combining mark")
    }

    func testTrimmingHandlesTheDegenerateInputs() {
        XCTAssertEqual(DocumentMath.jsTrim(""), "")
        XCTAssertEqual(DocumentMath.jsTrim("   "), "")
        XCTAssertEqual(DocumentMath.jsTrim("Acme  Co"), "Acme  Co", "inner whitespace is untouched")
    }

    // MARK: - `String.prototype.slice(0, n)`

    /// The clamp counts UTF-16 code units. Every expectation was measured on BOTH engines: the JS
    /// side by running `safeString(v, n)` from `documents.js` and binding the result through a real
    /// `better-sqlite3`, the Swift side by the same clamp writing into SQLite — then comparing the
    /// stored bytes. The `prefix` column is what the first revision of this file did, and it is why
    /// this is a defect rather than a preference.
    ///
    /// ```text
    ///   input                          units  slice(60)  prefix(60)
    ///   31 × U+1F44D                      62     60          62   ← no clamp at all
    ///   "A" + 30 × U+1F44D                61     60          61
    ///   "A" + 100 × U+1F44D (cap 200)    201    200         201
    ///   "e" + 60 × U+0301                 61     60          61
    ///   10 × 👨‍👩‍👧 (ZWJ family)             80     60          80
    /// ```
    func testTheClampCountsCodeUnitsAndNotCharacters() {
        let thumbs = String(repeating: "\u{1F44D}", count: 31)
        XCTAssertEqual(thumbs.utf16.count, 62)
        XCTAssertEqual(thumbs.count, 31, "…and 31 Characters, which is what prefix would count")
        XCTAssertEqual(DocumentMath.jsSlice(thumbs, to: 60).utf16.count, 60)
        XCTAssertEqual(String(thumbs.prefix(60)).utf16.count, 62,
                       "the old spelling clamped NOTHING here — that is the defect")

        let acutes = "e" + String(repeating: "\u{0301}", count: 60)
        XCTAssertEqual(acutes.utf16.count, 61)
        XCTAssertEqual(acutes.count, 1, "one Character: a grapheme cluster 61 code units long")
        XCTAssertEqual(DocumentMath.jsSlice(acutes, to: 60).utf16.count, 60)
        XCTAssertEqual(String(acutes.prefix(60)).utf16.count, 61)
    }

    /// **A cut that lands inside a surrogate pair leaves half of one, and both engines resolve that
    /// half to exactly one U+FFFD.** JS keeps the lone surrogate in memory and `better-sqlite3`
    /// replaces it while encoding to UTF-8; Swift cannot hold one at all and replaces it here. The
    /// two agree on what reaches the column, which is the only place the mirror is claimed.
    ///
    /// Measured: `"A" + 30 × U+1F44D` cut at 60 stores `…F0 9F 91 8D EF BF BD` on both sides. Had
    /// `better-sqlite3` written WTF-8 (`ED A0 BD`) instead, Swift could not have reproduced it and
    /// this would have been an unreachable mirror rather than a fixable clamp.
    func testACutInsideASurrogatePairBecomesExactlyOneReplacementCharacter() {
        let split = "A" + String(repeating: "\u{1F44D}", count: 30)
        XCTAssertEqual(split.utf16.count, 61, "the 60th unit is the HIGH half of the last pair")

        let cut = DocumentMath.jsSlice(split, to: 60)
        XCTAssertEqual(cut.utf16.count, 60, "the replacement is one code unit, as the surrogate was")
        XCTAssertEqual(cut.utf16.last, 0xFFFD)
        XCTAssertEqual(Array(cut.utf8.suffix(3)), [0xEF, 0xBF, 0xBD],
                       "…and it encodes to the three bytes better-sqlite3 was measured to write")
        XCTAssertNotEqual(Array(cut.utf8.suffix(3)), [0xED, 0xA0, 0xBD], "NOT WTF-8")

        // The same shape at the customer-name budget, and inside a ZWJ sequence.
        let long = "A" + String(repeating: "\u{1F44D}", count: 100)
        XCTAssertEqual(long.utf16.count, 201)
        XCTAssertEqual(DocumentMath.jsSlice(long, to: 200).utf16.last, 0xFFFD)

        let family = String(repeating: "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", count: 10)
        XCTAssertEqual(family.utf16.count, 80)
        let familyCut = DocumentMath.jsSlice(family, to: 60)
        XCTAssertEqual(familyCut.utf16.count, 60)
        XCTAssertEqual(Array(familyCut.utf16.suffix(3)), [0xDC68, 0x200D, 0xFFFD],
                       "measured in node: the cut falls after a ZWJ, mid-pair")
    }

    /// A cut that lands ON a pair boundary loses nothing, and a cap at or beyond the length is the
    /// identity — `slice` past the end returns the whole string.
    func testACleanCutAndAnOversizedCapAreBothLossless() {
        let thirty = String(repeating: "\u{1F44D}", count: 30)
        XCTAssertEqual(DocumentMath.jsSlice(thirty, to: 60), thirty)
        XCTAssertFalse(DocumentMath.jsSlice(thirty, to: 60).unicodeScalars.contains("\u{FFFD}"),
                       "a clean cut introduces no replacement character")
        XCTAssertEqual(DocumentMath.jsSlice("Acme", to: 60), "Acme")
        XCTAssertEqual(DocumentMath.jsSlice("Acme", to: 4), "Acme")
        XCTAssertEqual(DocumentMath.jsSlice("Acme", to: 0), "")
        XCTAssertEqual(DocumentMath.jsSlice("", to: 60), "")
    }

    // MARK: - `parseFloat`

    /// The four places a naive port of `parseFloat` goes wrong, plus the ordinary cases.
    func testParseFloatMatchesTheEngineOnTheCasesThatDiscriminate() {
        let cases: [(String, Double?)] = [
            ("", nil), (" ", nil), (".", nil), ("+", nil), ("-", nil), ("abc", nil), ("%", nil),
            ("5", 5), ("-5", -5), ("+5", 5), ("  \t\n 42 ", 42), ("42abc", 42),
            ("5.", 5), (".5", 0.5), ("-.5", -0.5), ("5.e3", 5000), (".5e3", 500),
            ("1e", 1), ("1e+", 1), ("1e-", 1), ("1e5", 100_000), ("1E5", 100_000), ("1e-5", 1e-5),
            ("Infinity", .infinity), ("-Infinity", -.infinity), ("+Infinity", .infinity),
            ("infinity", nil), ("INFINITY", nil), ("Infinit", nil), ("InfinityX", .infinity),
            ("NaN", nil), ("0x10", 0), ("0X10", 0), ("0b11", 0), ("1,234", 1), ("1 234", 1),
            ("1e1000", .infinity), ("1e-1000", 0),
            ("0.30000000000000004", 0.30000000000000004),
            ("0.49999999999999994", 0.49999999999999994),
        ]
        for (input, expected) in cases {
            let got = DocumentMath.jsParseFloat(input)
            if let expected {
                XCTAssertEqual(got, expected, "parseFloat(\(String(reflecting: input)))")
            } else {
                XCTAssertNil(got, "parseFloat(\(String(reflecting: input))) is NaN")
            }
        }
    }

    /// `parseFloat("-0")` is `-0`, and the sign is the only thing that distinguishes it.
    func testParseFloatKeepsTheSignOfNegativeZero() {
        XCTAssertEqual(DocumentMath.jsParseFloat("-0")?.sign, .minus)
        XCTAssertEqual(DocumentMath.jsParseFloat("0")?.sign, .plus)
    }

    /// `parseFloat` skips exactly the same whitespace `trim` does — including U+FEFF, and NOT
    /// including U+0085.
    func testParseFloatSkipsExactlyTheEcmascriptWhitespace() {
        XCTAssertEqual(DocumentMath.jsParseFloat("\u{FEFF}42"), 42)
        XCTAssertEqual(DocumentMath.jsParseFloat("\u{3000}42"), 42)
        XCTAssertNil(DocumentMath.jsParseFloat("\u{0085}42"), "NEL is not ECMAScript whitespace")
    }

    // MARK: - D-2 · `String(n)`

    /// `Number::toString`'s six layout cases, each with a value that lands in it and nowhere else.
    ///
    /// Every string below is node's answer, and none of them is Swift's: Swift writes `10000.0`,
    /// `1e+19` and `-0.0` for the first, fourth and last of them. That is the whole reason this
    /// function exists — `nextNumber` ends in `String(max + 1)`, so the layout IS the output.
    func testNumberToStringReproducesEachOfTheSixLayoutCases() {
        // k ≤ n ≤ 21 — the digits, zero-padded out to the point.
        XCTAssertEqual(DocumentMath.jsNumberToString(8), "8")
        XCTAssertEqual(DocumentMath.jsNumberToString(9999), "9999")
        XCTAssertEqual(DocumentMath.jsNumberToString(10000), "10000")
        XCTAssertEqual(DocumentMath.jsNumberToString(1e15), "1000000000000000")
        XCTAssertEqual(DocumentMath.jsNumberToString(pow(2, 53)), "9007199254740992")
        XCTAssertEqual(DocumentMath.jsNumberToString(pow(2, 63)), "9223372036854776000",
                       "past 2^53 the shortest round-trip has fewer digits than the value")
        XCTAssertEqual(DocumentMath.jsNumberToString(1e19), "10000000000000000000")
        XCTAssertEqual(DocumentMath.jsNumberToString(1e20), "100000000000000000000")
        // Written in exponential form because the literal `123456789012345678901` is not exactly
        // representable and the compiler says so; this is the same Double, spelled without a warning.
        XCTAssertEqual(DocumentMath.jsNumberToString(1.2345678901234568e20), "123456789012345680000")

        // 0 < n ≤ 21 with n < k — a decimal point inside the digits.
        XCTAssertEqual(DocumentMath.jsNumberToString(1.5), "1.5")
        XCTAssertEqual(DocumentMath.jsNumberToString(100.25), "100.25")
        XCTAssertEqual(DocumentMath.jsNumberToString(1.2345678901234568e18), "1234567890123456800")

        // −6 < n ≤ 0 — a leading `0.` and then the digits.
        XCTAssertEqual(DocumentMath.jsNumberToString(0.1), "0.1")
        XCTAssertEqual(DocumentMath.jsNumberToString(0.5), "0.5")
        XCTAssertEqual(DocumentMath.jsNumberToString(1e-6), "0.000001")
        XCTAssertEqual(DocumentMath.jsNumberToString(1.0 / 3.0), "0.3333333333333333")

        // n > 21 or n ≤ −6 — exponential, one digit before the point when there is only one.
        XCTAssertEqual(DocumentMath.jsNumberToString(1e21), "1e+21", "the boundary: 1e20 is not this")
        XCTAssertEqual(DocumentMath.jsNumberToString(1e22), "1e+22")
        XCTAssertEqual(DocumentMath.jsNumberToString(1e52), "1e+52")
        XCTAssertEqual(DocumentMath.jsNumberToString(1e300), "1e+300")
        XCTAssertEqual(DocumentMath.jsNumberToString(1e-7), "1e-7", "and 1e-6 is not")
        XCTAssertEqual(DocumentMath.jsNumberToString(5e-324), "5e-324")
        XCTAssertEqual(DocumentMath.jsNumberToString(.greatestFiniteMagnitude),
                       "1.7976931348623157e+308")
        XCTAssertEqual(DocumentMath.jsNumberToString(.ulpOfOne), "2.220446049250313e-16")
    }

    /// The three values with no digits at all, and the one place in this file where `-0` is
    /// deliberately NOT preserved: `String(-0)` is `"0"`.
    func testNumberToStringFlattensNegativeZeroAndNamesTheNonNumbers() {
        XCTAssertEqual(DocumentMath.jsNumberToString(0), "0")
        XCTAssertEqual(DocumentMath.jsNumberToString(-0.0), "0",
                       "every other function here keeps the sign; this one drops it, as JS does")
        XCTAssertEqual(DocumentMath.jsNumberToString(-1), "-1")
        XCTAssertEqual(DocumentMath.jsNumberToString(-0.1), "-0.1")
        XCTAssertEqual(DocumentMath.jsNumberToString(.infinity), "Infinity")
        XCTAssertEqual(DocumentMath.jsNumberToString(-.infinity), "-Infinity")
        XCTAssertEqual(DocumentMath.jsNumberToString(.nan), "NaN")
    }

    /// The digit extraction underneath, stated as the identity it has to satisfy.
    func testTheShortestDecimalIsDigitsWithoutLeadingOrTrailingZeros() {
        for (value, digits, point) in [(10000.0, "1", 5), (0.1, "1", 0), (1.5, "15", 1),
                                       (1e21, "1", 22), (5e-324, "5", -323),
                                       (9223372036854775808.0, "9223372036854776", 19)] {
            let decomposed = DocumentMath.shortestDecimal(of: value)
            XCTAssertEqual(decomposed.digits, digits, "\(value)")
            XCTAssertEqual(decomposed.pointPosition, point, "\(value)")
        }

        // The shape rule, over values NOT pinned above — otherwise the equalities would already
        // have decided it and these assertions could never be the one that fails. Both zero
        // positions are reachable in Swift's own spelling (`1000000.0` has trailing zeros before
        // the point, `0.001` has leading ones after it), so this is a real normalisation step.
        var generator = SplitMix64(seed: 0x5EED_D2)
        var values: [Double] = [1e6, 0.001, 1e-5, 20.0, 300.5, 1e17, 4e-9]
        for _ in 0..<2000 { values.append(abs(generator.nextDouble(magnitude: 1e6))) }
        var sawMultiDigit = false
        for value in values where value > 0 && value.isFinite {
            let decomposed = DocumentMath.shortestDecimal(of: value)
            XCTAssertFalse(decomposed.digits.isEmpty, "\(value)")
            XCTAssertFalse(decomposed.digits.hasPrefix("0"), "\(value) kept a leading zero")
            XCTAssertFalse(decomposed.digits.hasSuffix("0"), "\(value) kept a trailing zero")
            // The identity the pair has to satisfy, checked by rebuilding the number from it.
            let k = decomposed.digits.count
            XCTAssertEqual(Double(decomposed.digits)! * pow(10, Double(decomposed.pointPosition - k)),
                           value, accuracy: abs(value) * 1e-12, "\(value)")
            if k > 1 { sawMultiDigit = true }
        }
        XCTAssertTrue(sawMultiDigit, "a corpus of single-digit values would not exercise the rule")
    }

    /// `padStart` pads and never truncates, and it counts UTF-16 code units.
    func testPadStartPadsButNeverTruncates() {
        XCTAssertEqual(DocumentMath.jsPadStart("8", to: 4), "0008")
        XCTAssertEqual(DocumentMath.jsPadStart("1", to: 4), "0001")
        XCTAssertEqual(DocumentMath.jsPadStart("9999", to: 4), "9999")
        XCTAssertEqual(DocumentMath.jsPadStart("10000", to: 4), "10000", "already longer: untouched")
        XCTAssertEqual(DocumentMath.jsPadStart("1e+21", to: 4), "1e+21")
        XCTAssertEqual(DocumentMath.jsPadStart("Infinity", to: 4), "Infinity")
        XCTAssertEqual(DocumentMath.jsPadStart("", to: 4), "0000")
        XCTAssertEqual(DocumentMath.jsPadStart("\u{1F44D}", to: 4), "00\u{1F44D}",
                       "one emoji is TWO code units, so two zeros are added, not three")
    }
}

/// A deterministic generator, so a failure is reproducible. `Math.random` has no place in a test
/// whose whole purpose is that the same values are checked every run.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A signed value spread over several decades of magnitude, which is where money-shaped inputs
    /// actually live.
    mutating func nextDouble(magnitude: Double) -> Double {
        let unit = Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
        let exponent = Double(Int(next() % 13)) - 6
        return (unit * 2 - 1) * magnitude * pow(10, exponent)
    }
}
