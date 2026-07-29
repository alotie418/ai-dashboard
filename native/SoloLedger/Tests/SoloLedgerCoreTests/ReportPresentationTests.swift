import XCTest
@testable import SoloLedgerCore

/// Coverage for the pure decision layer (`ReportPresentation`).
///
/// The suite is built around one idea: **the value of this layer is the states it keeps
/// APART**, so most of these tests assert inequality rather than equality. A mapping that
/// merges two model states compiles, passes any golden, and is exactly the defect the
/// layer exists to make impossible.
final class ReportPresentationTests: XCTestCase {

    // MARK: - The four field kinds are pairwise distinct

    /// The headline guard. Four model states that a naive view would flatten into
    /// "a number or nothing" must produce four different answers.
    ///
    /// `.computed(0)` is in here on purpose: a legitimate zero and a refusal are the pair
    /// the whole scheme turns on, and the goldens prove they are different rows —
    /// `zero-US-2025` reports `annualIncomeTax: 0` while `unset-US-2025` and
    /// `malformed-US-2025` BOTH report `null`.
    func testTheFourFieldKindsArePairwiseDistinct() {
        let cases: [(String, ReportFieldPresentation)] = [
            ("legitimate zero", ReportPresentation.field(EstimatedValue.computed(0))),
            ("corrupted",       ReportPresentation.field(EstimatedValue.computed(.nan))),
            ("notConfigured",   ReportPresentation.field(
                EstimatedValue.notConfigured(parameter: .incomeTaxRate))),
            ("needsRepair",     ReportPresentation.field(
                EstimatedValue.needsRepair(parameter: .incomeTaxRate, rawValue: "\"25%\""))),
        ]
        for i in cases.indices {
            for j in cases.indices where j > i {
                XCTAssertNotEqual(cases[i].1, cases[j].1,
                                  "\(cases[i].0) and \(cases[j].0) must not present identically")
            }
        }
    }

    /// The two refusals differ ONLY in kind and payload, never collapse — they ask the
    /// user for different things ("configure" vs "repair"), and no golden can tell them
    /// apart, so this assertion is the only thing that does.
    func testNotConfiguredAndNeedsRepairNeverCollapse() {
        for parameter in [ReportRateParameter.incomeTaxRate, .surchargeRate] {
            let unset = ReportPresentation.field(
                EstimatedValue.notConfigured(parameter: parameter))
            let broken = ReportPresentation.field(
                EstimatedValue.needsRepair(parameter: parameter, rawValue: "\"25%\""))
            XCTAssertNotEqual(unset, broken, "\(parameter): the two refusals must stay apart")
            XCTAssertEqual(unset, .notConfigured(parameter: parameter))
            XCTAssertEqual(broken, .needsRepair(parameter: parameter, storedText: "\"25%\""))
        }
    }

    /// Parameter identity survives, in both refusals and both parameters. China's income
    /// statement can refuse two lines blaming the SURCHARGE and three blaming the
    /// INCOME-TAX row in the same statement (`CNReportEngine` gates them on different
    /// expressions), so a presentation that dropped the parameter would point the repair
    /// door at the wrong settings field.
    func testParameterIdentitySurvivesBothRefusals() {
        XCTAssertNotEqual(
            ReportPresentation.field(EstimatedValue.notConfigured(parameter: .incomeTaxRate)),
            ReportPresentation.field(EstimatedValue.notConfigured(parameter: .surchargeRate)))
        XCTAssertNotEqual(
            ReportPresentation.field(EstimatedValue.needsRepair(parameter: .incomeTaxRate,
                                                               rawValue: "x")),
            ReportPresentation.field(EstimatedValue.needsRepair(parameter: .surchargeRate,
                                                               rawValue: "x")))
    }

    // MARK: - Finiteness

    /// `.amount` is the ONLY case carrying a Double and its payload is ALWAYS finite.
    ///
    /// Stated as an invariant over a corpus rather than as three examples, because the
    /// property is what a view relies on: if it matched `.amount(let x)` it may format
    /// `x` without a guard of its own.
    func testAmountPayloadIsAlwaysFinite() {
        let corpus: [Double] = [
            0, -0.0, 1, -1, 0.005, -0.005, 1e-300, -1e-300, 1e308, -1e308,
            .greatestFiniteMagnitude, -.greatestFiniteMagnitude,
            .leastNonzeroMagnitude, .nan, .signalingNaN, .infinity, -.infinity,
        ]
        for x in corpus {
            for presentation in [ReportPresentation.field(x),
                                 ReportPresentation.field(EstimatedValue.computed(x))] {
                if case .amount(let out) = presentation {
                    XCTAssertTrue(out.isFinite, "\(x) presented as a non-finite amount \(out)")
                } else {
                    XCTAssertEqual(presentation, .corrupted,
                                   "\(x) must be either a finite amount or corrupted")
                    XCTAssertFalse(x.isFinite, "\(x) is finite and must not be corrupted")
                }
            }
        }
    }

    /// Non-finite values are corrupted through BOTH funnels — the estimate one and the
    /// plain-Double one. The plain funnel is the load-bearing half: China's `adminExpense`
    /// is a plain `Double` and `ReportMath.round2` has no `|| 0` guard, so a corrupt
    /// `admin_expense_annual` reaches a view as an ordinary field with a NaN in it.
    func testNonFiniteIsCorruptedThroughBothFunnels() {
        for x in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(ReportPresentation.field(x), .corrupted)
            XCTAssertEqual(ReportPresentation.field(EstimatedValue.computed(x)), .corrupted)
        }
    }

    /// NaN must not sneak through as an `.amount` that merely compares unequal to itself.
    /// `.amount(.nan) == .amount(.nan)` is FALSE in Swift, so an equality-based test could
    /// pass while the payload was a NaN; this asserts the case tag directly.
    func testNaNProducesTheCorruptedCaseNotAnUnequalAmount() {
        guard case .corrupted = ReportPresentation.field(Double.nan) else {
            return XCTFail("NaN must produce .corrupted, not an .amount")
        }
    }

    /// `-0.0` is normalised, so no zero can render with a leading minus.
    ///
    /// Reachable: the engines' rounder is `round(x * 100) / 100`, and `round(-0.1)` is
    /// `-0.0`, so any net figure in `(-0.005, 0]` lands here. `-0.0 == 0.0` already, so
    /// `Equatable` cannot see the difference — only the sign bit can.
    func testNegativeZeroIsNormalisedSoNoZeroRendersWithAMinusSign() {
        for input in [-0.0, Double(0), -0.001, -0.004] {
            guard case .amount(let out) = ReportPresentation.field(input) else {
                return XCTFail("\(input) must present as an amount")
            }
            if out == 0 {
                XCTAssertFalse(out.sign == .minus,
                               "\(input) presented as a negative zero — a formatter prints -0.00")
            }
        }
        // The normalisation touches ONLY zero. A real negative keeps its sign.
        XCTAssertEqual(ReportPresentation.field(-12.34), .amount(-12.34))
    }

    /// Normalisation must not change any value. Equality is asserted against the input,
    /// not against a rounded or clamped version of it.
    func testFiniteValuesPassThroughUnchanged() {
        for x in [1.0, -1.0, 0.005, -12.34, 1e308, -1e308, 4171.78, -7824.15] {
            XCTAssertEqual(ReportPresentation.field(x), .amount(x))
            XCTAssertEqual(ReportPresentation.field(EstimatedValue.computed(x)), .amount(x))
        }
    }

    // MARK: - Stored text is passed through verbatim

    /// Every reachable `needsRepair` payload shape survives byte for byte. The repair flow
    /// has to show the user what is actually in their ledger; anything tidied here is
    /// evidence destroyed.
    ///
    /// The corpus is the one `ReportRateSettingTests` classifies, plus the two shapes the
    /// golden variants actually store: `"25%"` WITH its JSON quotes (`malformed`) and
    /// `25%` without them (`malformed-raw`).
    func testStoredTextIsPassedThroughVerbatim() {
        let corpus = [
            "\"25%\"", "25%", "\"12%\"", "12%",          // the golden variants
            "", " ", "\n", "abc", "null", "true", "[]", "[25]", "{}", "{\"v\":25}",
            "1e999", "Infinity", "NaN", "\u{FFFD}", "\u{FEFF}25", "十二%",
            String(repeating: "9", count: 10_000),        // unbounded length
            "line1\nline2\r\nline3",                      // embedded newlines
        ]
        for raw in corpus {
            let presented = ReportPresentation.field(
                EstimatedValue.needsRepair(parameter: .incomeTaxRate, rawValue: raw))
            guard case .needsRepair(_, let storedText) = presented else {
                return XCTFail("\(raw.debugDescription) must present as needsRepair")
            }
            XCTAssertEqual(storedText, raw,
                           "stored text \(raw.debugDescription) was altered on the way to the UI")
        }
    }

    /// The two JSON shapes of the SAME user mistake stay distinguishable. A repair UI that
    /// stripped quoting would show both as `25%` and could not explain why one ledger
    /// differs from another.
    func testQuotedAndUnquotedStoredTextRemainDifferent() {
        let quoted = ReportPresentation.field(
            EstimatedValue.needsRepair(parameter: .incomeTaxRate, rawValue: "\"25%\""))
        let bare = ReportPresentation.field(
            EstimatedValue.needsRepair(parameter: .incomeTaxRate, rawValue: "25%"))
        XCTAssertNotEqual(quoted, bare)
    }

    // MARK: - Rate provenance

    /// All four rate states map to four distinct answers — the China fallback most of all.
    ///
    /// Without `.regimeDefault` a Chinese ledger with no `income_tax_rate` row is
    /// indistinguishable from one the user configured at 25%: `EstimatedValue.refusal`
    /// routes `.configured` and `.chinaFallback` through the same arm, and the golden
    /// `unset-CN-2025` reports `incomeTax: 1042.95` from rows that do not exist.
    func testAllFourRateStatesPresentDistinctly() {
        let states: [(String, ReportRateProvenance)] = [
            ("configured",    ReportPresentation.provenance(.configured(25))),
            ("chinaFallback", ReportPresentation.provenance(.chinaFallback(25))),
            ("notConfigured", ReportPresentation.provenance(.notConfigured)),
            ("needsRepair",   ReportPresentation.provenance(.needsRepair(rawValue: "\"25%\""))),
        ]
        for i in states.indices {
            for j in states.indices where j > i {
                XCTAssertNotEqual(states[i].1, states[j].1,
                                  "\(states[i].0) and \(states[j].0) must not present identically")
            }
        }
        XCTAssertEqual(states[0].1, .userConfigured)
        XCTAssertEqual(states[1].1, .regimeDefault(percent: 25))
        XCTAssertEqual(states[2].1, .notConfigured)
        XCTAssertEqual(states[3].1, .needsRepair(storedText: "\"25%\""))
    }

    /// A configured 25% and a fallback 25% are the SAME number and must still differ.
    /// This is the assertion that would fail if provenance were ever derived from the
    /// value rather than carried.
    func testSamePercentFromDifferentSourcesStillDiffers() {
        XCTAssertNotEqual(ReportPresentation.provenance(.configured(25)),
                          ReportPresentation.provenance(.chinaFallback(25)))
    }

    /// The fallback carries the percent it applied, for both China defaults — 25 for
    /// income tax, 12 for the surcharge — so a disclosure can name the number instead of
    /// hardcoding it a second time.
    func testRegimeDefaultCarriesTheAppliedPercent() {
        XCTAssertEqual(ReportPresentation.provenance(.chinaFallback(25)),
                       .regimeDefault(percent: 25))
        XCTAssertEqual(ReportPresentation.provenance(.chinaFallback(12)),
                       .regimeDefault(percent: 12))
    }

    /// Provenance is derived from the SETTING, and the setting's own `rate` accessor —
    /// which is `nil` for both refusals — is not enough to reconstruct it.
    func testProvenanceIsNotDerivableFromTheRateAccessorAlone() {
        let refusals: [ReportRateSetting] = [.notConfigured, .needsRepair(rawValue: "\"25%\"")]
        for s in refusals { XCTAssertNil(s.rate) }
        XCTAssertNotEqual(ReportPresentation.provenance(refusals[0]),
                          ReportPresentation.provenance(refusals[1]),
                          "both have rate == nil and must still present differently")
    }

    // MARK: - Report types x availability

    /// The three availabilities map to three distinct sections, `.truncated` included.
    ///
    /// `.truncated` has NO producer today — R7 moved all 13 declared pairs to `.mirrored`
    /// — so this drives the internal mapping directly through `@testable`. That is the
    /// only way to reach the branch, and it is deliberately the only way: a public
    /// availability-taking entry point would be a production bypass of
    /// `ReportTypes.availability`.
    ///
    /// What this therefore does and does not prove: the MAPPING is pinned and the view
    /// branch will exist; it is NOT evidence that a real ledger reaches `.truncated`.
    func testEveryAvailabilityMapsToADistinctSection() {
        XCTAssertEqual(ReportPresentation.section(.mirrored), .renderInFull)
        XCTAssertEqual(ReportPresentation.section(.truncated), .renderWithMissingLines)
        XCTAssertEqual(ReportPresentation.section(.absent), .withhold)

        let all: [ReportSectionPresentation] = [
            ReportPresentation.section(.mirrored),
            ReportPresentation.section(.truncated),
            ReportPresentation.section(.absent),
        ]
        XCTAssertEqual(Set(all.map(String.init(describing:))).count, 3,
                       "three availabilities must not collapse into fewer sections")
    }

    /// `.truncated` must never present as a finished statement — the plan §7.3 violation
    /// spelled out as its own assertion so it cannot be lost in a refactor of the mapping.
    func testTruncatedIsNeverRenderedAsAFinishedStatement() {
        XCTAssertNotEqual(ReportPresentation.section(.truncated), .renderInFull)
    }

    /// `.absent` withholds. It is also what `ReportTypes.availability` answers for an id it
    /// does not know, so a typo'd id withholds rather than rendering an empty statement.
    func testAbsentWithholdsAndAnUnknownIdIsAbsent() {
        XCTAssertEqual(ReportPresentation.section(.absent), .withhold)
        XCTAssertEqual(ReportTypes.availability(for: "vat_summary", locale: "CN"), .absent)
        XCTAssertEqual(ReportTypes.availability(for: "balance-sheet", locale: "CN"), .absent)
        XCTAssertEqual(ReportTypes.availability(for: "income-statement", locale: "FR"), .absent)
    }

    /// Every one of the 13 declared pairs comes back paired with a decision, in the
    /// engines' own order, and the ids match the mirrored table exactly.
    func testAllThirteenDeclaredPairsArrivePairedWithADecision() {
        let expected: [String: [String]] = [
            "CN": ["income-statement", "vat-summary", "tax-inclusive"],
            "JP": ["income-statement", "consumption-tax"],
            "EU": ["profit-loss", "vat-return"],
            "KR": ["income-statement", "vat-summary"],
            "TW": ["income-statement", "business-tax"],
            "US": ["schedule-c", "se-tax"],
        ]
        var total = 0
        for (locale, ids) in expected {
            let presented = try? XCTUnwrap(ReportPresentation.reportTypes(locale: locale))
            guard let presented else { return XCTFail("\(locale) must have report types") }
            XCTAssertEqual(presented.map(\.id), ids, "\(locale) ids/order must mirror the table")
            for p in presented {
                XCTAssertEqual(p.section,
                               ReportPresentation.section(ReportTypes.availability(for: p.id,
                                                                                  locale: locale)),
                               "\(locale)/\(p.id) section must come from availability")
            }
            total += presented.count
        }
        XCTAssertEqual(total, 13, "the mirrored table declares exactly 13 pairs")
    }

    /// Today every declared pair is fully mirrored, so nothing is withheld. This is a
    /// RATCHET, not a tautology: if a later batch adds a report type without wiring its
    /// availability, this goes red and the UI is not silently handed a withheld section.
    func testNoDeclaredPairIsWithheldToday() {
        for locale in ["CN", "US", "JP", "EU", "KR", "TW"] {
            guard let presented = ReportPresentation.reportTypes(locale: locale) else {
                return XCTFail("\(locale) must have report types")
            }
            for p in presented {
                XCTAssertEqual(p.section, .renderInFull,
                               "\(locale)/\(p.id) is declared but not fully mirrored")
            }
        }
    }

    /// An unsupported locale answers `nil`, not `[]` — matching `ReportTypes.table(for:)`,
    /// so a caller cannot render an empty picker for a ledger the dispatcher would reject.
    func testUnsupportedLocaleAnswersNilNotEmpty() {
        for locale in ["FR", "GB", "cn", "", "CN "] {
            XCTAssertNil(ReportPresentation.reportTypes(locale: locale),
                         "\(locale.debugDescription) is not an accounting locale")
        }
    }

    /// The presented type must never gain a field that could carry the engines' historical
    /// `name` copy. Reflection rather than review, because "someone adds `name` for
    /// convenience" is exactly how that copy would reach a screen.
    func testPresentedReportTypeCarriesNoDisplayName() {
        let fields = Set(Mirror(reflecting: ReportTypePresentation(id: "x", section: .withhold))
            .children.compactMap(\.label))
        XCTAssertEqual(fields, ["id", "section"],
                       "ReportTypePresentation must expose only a stable id and a decision")
    }

    /// The ids handed out are the STABLE identifiers, and none of them is one of the
    /// historical display strings. A cheap, direct statement of the §7.3 copy rule.
    func testPresentedIdsAreNeverTheHistoricalDisplayCopy() {
        let historical = Set(["CN", "US", "JP", "EU", "KR", "TW"]
            .compactMap { ReportTypes.table(for: $0) }
            .flatMap { $0 }
            .flatMap { $0.name.values })
        XCTAssertFalse(historical.isEmpty, "the mirrored name maps must be non-empty")
        for locale in ["CN", "US", "JP", "EU", "KR", "TW"] {
            for p in ReportPresentation.reportTypes(locale: locale) ?? [] {
                XCTAssertFalse(historical.contains(p.id),
                               "\(p.id) collides with the historical display copy")
            }
        }
    }
}
