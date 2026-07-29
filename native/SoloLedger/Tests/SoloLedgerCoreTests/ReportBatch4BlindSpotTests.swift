import XCTest
@testable import SoloLedgerCore

/// The batch-4 behaviours the GOLDENS CANNOT SEE.
///
/// `ReportBatch4ParityTests` asserts 153 turnover fields and they all match, but
/// the fixture yields only four distinct vectors per locale and every rate variant
/// repeats the same block. **This file is where the batch's actual risks live**:
/// the clamp that hides a credit position, the rounding order, the NaN guard, and
/// the copy defects in `reportTypes` that must survive the mirror rather than be
/// tidied away.
///
/// Every expected number below was produced by running the REAL engines with a
/// hand-built context (plan §4.1 Tier-1), under `LC_ALL=C LANG=C TZ=UTC`, and each
/// test quotes the case it came from.
///
///     node -e "const cn=require('./electron/reports/cn.js'); …"
final class ReportBatch4BlindSpotTests: XCTestCase {

    private func ctx(income: [ReportRow] = [], expense: [ReportRow] = [],
                     adminExpense: Double = 0, currency: String = "CNY") -> ReportContext {
        // The turnover-tax blocks read no rate at all — they sum recorded
        // `tax_amount` (plan §0). `.notConfigured` is the strictest filler.
        ReportContext(incomeRows: income, expenseRows: expense, categories: [],
                      adminExpense: adminExpense, incomeTaxRate: .notConfigured,
                      surchargeRate: .notConfigured,
                      currency: currency, year: "2026",
                      from: "2026-01-01", to: "2026-12-31")
    }

    /// A row that carries `tax`. `amount` / `amount_net` are filled in so the row is
    /// realistic, and are provably irrelevant here — see
    /// ``testTheBlockReadsOnlyTheTaxColumn``.
    private func row(_ tax: Double?, amount: Double = 1000) -> ReportRow {
        ReportRow(amountNet: amount - (tax ?? 0), amount: amount, taxAmount: tax,
                  date: "2026-03-01")
    }

    // MARK: - The clamp

    /// **Input tax exceeding output tax is reported as a payable of ZERO.**
    ///
    /// The real position is a credit carried forward (留抵税额). Every engine
    /// clamps it away, and the fixture reaches this state in two periods
    /// (`base-CN-2025Q2`, `base-CN-2025-06`), so the goldens already record the
    /// clamped answer.
    ///
    ///     …incomeRows:[], expenseRows:[{tax_amount:135.85}]
    ///     => CN {135.85, 0, 135.85, 0, 0}  JP/TW {0, 135.85, 0}
    ///        EU/KR {0, 135.85, 0}
    ///
    /// **The mirror reports the same `0` and adds nothing.** The information the
    /// clamp discards — that 135.85 is carried forward rather than nothing being
    /// owed — is registered in plan Appendix A14, not surfaced as an extra field.
    /// An earlier revision of this batch did carry one; it was removed because a
    /// value no engine emits and no golden contains does not belong in a mirror.
    /// The 135.85 remains visible here on the INPUT row, which is what the engine
    /// itself reports.
    func testTheClampTurnsACreditPositionIntoZero() {
        let c = ctx(expense: [row(135.85)])

        let cn = CNReportEngine.vatSummary(c)
        XCTAssertEqual(cn.cumulativeInput, 135.85)
        XCTAssertEqual(cn.cumulativeOutput, 0)
        XCTAssertEqual(cn.estimatedPayable, 0,
                       "the clamp, mirrored — the credit position reads as owing nothing")

        let jp = JPReportEngine.consumptionTax(c)
        XCTAssertEqual([jp.collected, jp.paid, jp.payable], [0, 135.85, 0])

        let eu = EUReportEngine.vatReturn(c)
        XCTAssertEqual([eu.outputVAT, eu.inputVAT, eu.vatPayable], [0, 135.85, 0])

        let kr = KRReportEngine.vatSummary(c)
        XCTAssertEqual([kr.outputVAT, kr.inputVAT, kr.vatPayable], [0, 135.85, 0])

        let tw = TWReportEngine.businessTax(c)
        XCTAssertEqual([tw.collected, tw.paid, tw.payable], [0, 135.85, 0])
    }

    /// The clamp happens BEFORE the rounding, and the two orders disagree.
    ///
    ///     …incomeRows:[{tax_amount:0.005}], expenseRows:[{tax_amount:0.004}]
    ///     => CN {0, 0.01, 0, 0.01, 0}
    ///
    /// Clamp-then-round: `r(max(0, 0.005 - 0.004))` = `r(0.001)` = **0**.
    /// Round-then-clamp: `max(0, r(0.005) - r(0.004))` = `0.01 - 0` = **0.01**.
    ///
    /// The engine gives 0, so the displayed rows do not reconcile: the card shows
    /// output 0.01, input 0.00 and a payable of 0.00. Mirrored, not repaired.
    func testTheClampHappensBeforeRoundingNotAfter() {
        let c = ctx(income: [row(0.005)], expense: [row(0.004)])

        let cn = CNReportEngine.vatSummary(c)
        XCTAssertEqual(cn.cumulativeOutput, 0.01, "0.005 rounds up on its own")
        XCTAssertEqual(cn.cumulativeInput, 0, "0.004 rounds down on its own")
        // …yet the payable is 0, not 0.01. Note it is the ROUNDING that produces
        // the 0 here, not the clamp: the difference is +0.001, which the clamp
        // passes through untouched and `r` then takes to 0.
        XCTAssertEqual(cn.estimatedPayable, 0)

        XCTAssertEqual(JPReportEngine.consumptionTax(c).payable, 0)
        XCTAssertEqual(EUReportEngine.vatReturn(c).vatPayable, 0)
        XCTAssertEqual(KRReportEngine.vatSummary(c).vatPayable, 0)
        XCTAssertEqual(TWReportEngine.businessTax(c).payable, 0)
    }

    /// Rows are SUMMED first and rounded once, not rounded row by row.
    ///
    ///     …expenseRows:[{tax_amount:0.004} x 3]  => cumulativeInput 0.01
    ///
    /// Per-row rounding would give `0 + 0 + 0 = 0`. The sum is 0.012, which rounds
    /// to 0.01.
    func testRowsAreSummedBeforeRoundingNotRoundedIndividually() {
        let c = ctx(expense: [row(0.004), row(0.004), row(0.004)])
        XCTAssertEqual(CNReportEngine.vatSummary(c).cumulativeInput, 0.01,
                       "0.004 x 3 = 0.012 -> 0.01; per-row rounding would give 0")
        XCTAssertEqual(JPReportEngine.consumptionTax(c).paid, 0.01)
        XCTAssertEqual(EUReportEngine.vatReturn(c).inputVAT, 0.01)
        XCTAssertEqual(KRReportEngine.vatSummary(c).inputVAT, 0.01)
        XCTAssertEqual(TWReportEngine.businessTax(c).paid, 0.01)
    }

    // MARK: - China's duplicate pair

    /// **`certifiedInput` is `cumulativeInput`, and no input can separate them.**
    ///
    /// `cn.js:70` and `cn.js:72` are the same expression, as are `:71` and `:73`.
    /// This is the batch's one truly untestable-by-parity field pair — every CN
    /// golden shows the pair equal, so a transposition in the mirror is invisible
    /// there. Verified against the real `cn.js` over 200 random draws before being
    /// written down here; what the test can assert is the invariant itself, over
    /// inputs chosen to be as hostile as the type allows.
    ///
    /// If a future change to `cn.js` makes the two differ, this test fails and the
    /// mirror must follow — it is a tripwire, not an endorsement.
    func testChinasDuplicatePairCannotBeSeparatedByAnyInput() {
        let taxes: [Double?] = [0, -0.0, 1, -1, 0.005, -135.85, 1e15, 1e-15, nil, .nan,
                                .infinity, -.infinity, 1234.567]
        for a in taxes {
            for b in taxes {
                let block = CNReportEngine.vatSummary(ctx(income: [row(a)], expense: [row(b)]))
                XCTAssertEqual(block.certifiedInput.isNaN, block.cumulativeInput.isNaN)
                if !block.cumulativeInput.isNaN {
                    XCTAssertEqual(block.certifiedInput, block.cumulativeInput,
                                   "cn.js:70 and :72 are the same expression (tax \(String(describing: b)))")
                }
                XCTAssertEqual(block.invoicedOutput.isNaN, block.cumulativeOutput.isNaN)
                if !block.cumulativeOutput.isNaN {
                    XCTAssertEqual(block.invoicedOutput, block.cumulativeOutput,
                                   "cn.js:71 and :73 are the same expression (tax \(String(describing: a)))")
                }
            }
        }
    }

    // MARK: - Inputs the engines shrug off

    /// A `NaN` tax contributes 0 instead of poisoning the sum, because every term
    /// goes through `(row.tax_amount || 0)` (`cn.js:20`, `:23`).
    ///
    ///     …incomeRows:[{tax_amount:NaN},{tax_amount:50}], expenseRows:[{tax_amount:20}]
    ///     => CN {20, 50, 20, 50, 30}   JP/EU/KR/TW {50, 20, 30}
    ///
    /// This is why China's UNGUARDED rounder (`cn.js:43`, the one without `|| 0`)
    /// cannot emit `null` from this block, even though it does from the income
    /// statement under a malformed rate. The distinction is worth a test because
    /// using `round2OrZero` here would pass every golden and still be the wrong
    /// mirror.
    func testANaNTaxContributesZeroRatherThanPoisoningTheSum() {
        let c = ctx(income: [row(.nan), row(50)], expense: [row(20)])

        let cn = CNReportEngine.vatSummary(c)
        XCTAssertEqual([cn.cumulativeInput, cn.cumulativeOutput, cn.certifiedInput,
                        cn.invoicedOutput, cn.estimatedPayable], [20, 50, 20, 50, 30])
        XCTAssertFalse(cn.estimatedPayable.isNaN, "no NaN reaches China's unguarded rounder here")

        XCTAssertEqual(JPReportEngine.consumptionTax(c).payable, 30)
        XCTAssertEqual(EUReportEngine.vatReturn(c).vatPayable, 30)
        XCTAssertEqual(KRReportEngine.vatSummary(c).vatPayable, 30)
        XCTAssertEqual(TWReportEngine.businessTax(c).payable, 30)
    }

    /// A missing (SQL NULL) tax is also 0 — same guard, different falsy value.
    func testANullTaxContributesZero() {
        let c = ctx(income: [row(nil), row(50)], expense: [])
        XCTAssertEqual(CNReportEngine.vatSummary(c).cumulativeOutput, 50)
        XCTAssertEqual(TWReportEngine.businessTax(c).collected, 50)
    }

    /// An empty period is `0`, not absent — the engines emit the block regardless.
    ///
    /// Worth pinning because the surrounding phase draws the opposite conclusion
    /// elsewhere: `_cashflow`'s operating section becomes `.notConfigured` rather
    /// than `{0,0,0}` when the period has no transactions. These blocks do NOT do
    /// that, and the difference is the source's.
    func testAnEmptyPeriodIsZeroRatherThanAbsent() {
        let c = ctx()
        XCTAssertEqual(CNReportEngine.vatSummary(c).estimatedPayable, 0)
        XCTAssertEqual(JPReportEngine.consumptionTax(c).payable, 0)
    }

    /// **A NEGATIVE expense tax INFLATES the payable.** (Plan Appendix A13.)
    ///
    ///     …incomeRows:[{tax_amount:100}], expenseRows:[{tax_amount:-40}]
    ///     => CN {-40, 100, -40, 100, 140}
    ///
    /// `output - input` with a negative input is an addition, so a −40 credit note
    /// recorded as a negative tax raises the reported payable from 100 to 140, and
    /// the input row displays as −40.00. **No golden constrains this** — the
    /// fixture has no negative tax row — which is exactly why it is written down.
    /// Same family as Appendix A12 on the US side.
    func testANegativeExpenseTaxInflatesThePayable() {
        let c = ctx(income: [row(100)], expense: [row(-40)])
        let cn = CNReportEngine.vatSummary(c)
        XCTAssertEqual(cn.cumulativeInput, -40)
        XCTAssertEqual(cn.estimatedPayable, 140, "100 - (-40); mirrored, and unconstrained by goldens")
        XCTAssertEqual(JPReportEngine.consumptionTax(c).payable, 140)
        XCTAssertEqual(EUReportEngine.vatReturn(c).vatPayable, 140)
        XCTAssertEqual(KRReportEngine.vatSummary(c).vatPayable, 140)
        XCTAssertEqual(TWReportEngine.businessTax(c).payable, 140)
    }

    /// A zero-decimal currency is still rounded to two decimals (Appendix A8).
    ///
    ///     …currency:'JPY', incomeRows:[{tax_amount:1234.567}] => collected 1234.57
    ///
    /// The engines never read `currency` in this block, so the JPY and CNY answers
    /// are identical. Mirrored; the correction needs a rounding-policy decision.
    func testAZeroDecimalCurrencyIsStillRoundedToTwoDecimals() {
        let jpy = ctx(income: [row(1234.567)], currency: "JPY")
        let cny = ctx(income: [row(1234.567)], currency: "CNY")
        XCTAssertEqual(JPReportEngine.consumptionTax(jpy).collected, 1234.57)
        XCTAssertEqual(JPReportEngine.consumptionTax(jpy), JPReportEngine.consumptionTax(cny))
        XCTAssertEqual(KRReportEngine.vatSummary(ctx(income: [row(1234.567)], currency: "KRW")).outputVAT,
                       1234.57)
    }

    /// The block reads the tax column and nothing else — not `amount`, not
    /// `amount_net`, and not the one settings-derived number the context carries.
    ///
    /// Together with ``ReportContext`` having no rate field at all, this is the
    /// mechanical form of plan §2's claim that batch 4 carries no parameter risk.
    func testTheBlockReadsOnlyTheTaxColumn() {
        let base = CNReportEngine.vatSummary(ctx(income: [row(10)], expense: [row(4)]))

        // Same taxes, wildly different amounts.
        let differentAmounts = CNReportEngine.vatSummary(
            ctx(income: [row(10, amount: 999_999)], expense: [row(4, amount: 0)]))
        XCTAssertEqual(base, differentAmounts, "amount / amount_net are not read here")

        // Same taxes, a huge annual admin expense.
        let differentAdmin = CNReportEngine.vatSummary(
            ctx(income: [row(10)], expense: [row(4)], adminExpense: 99_999))
        XCTAssertEqual(base, differentAdmin, "adminExpense is not read here")
        XCTAssertEqual(base.estimatedPayable, 6)
    }

    // MARK: - reportTypes: the copy defects, preserved

    /// The `name` maps are SPARSE, and this pins exactly how sparse.
    ///
    /// The app ships six UI languages (`zh-Hans`, `zh-Hant`, `en`, `ja`, `ko`,
    /// `fr`). No entry carries more than three. Backfilling would be authoring
    /// jurisdiction copy, which this phase does not do — so the gaps are asserted
    /// as facts, and a future "helpful" completion fails here.
    func testTheNameMapsAreSparseAndUnpatched() throws {
        let expected: [String: Set<String>] = [
            "CN": ["zh-CN", "en"], "US": ["zh-CN", "en"],
            "JP": ["zh-CN", "en", "ja"], "EU": ["zh-CN", "en", "fr"],
            "KR": ["zh-CN", "en", "ko"], "TW": ["zh-CN", "en", "zh-TW"],
        ]
        for (locale, languages) in expected {
            for entry in try XCTUnwrap(ReportTypes.table(for: locale)) {
                XCTAssertEqual(Set(entry.name.keys), languages,
                               "\(locale)/\(entry.id): the language set is part of the mirror")
                XCTAssertLessThan(entry.name.count, 6,
                                  "no engine entry is six-language; R8 supplies its own strings")
                // The keys are the ENGINE's spelling (`zh-CN`/`zh-TW`), not the
                // app's Apple codes (`zh-Hans`/`zh-Hant`). Mirrored as found.
                XCTAssertFalse(entry.name.keys.contains("zh-Hans"))
            }
        }
    }

    /// **`jp.js` puts Japanese in the `zh-CN` slot** — the two values are
    /// byte-identical, and `消費税概要` carries the traditional 費 (U+8CBB) where
    /// Simplified Chinese writes 消费税概要.
    ///
    /// A zh-CN reader on a Japan ledger would be shown Japanese. Registered for a
    /// human to word; mirrored meanwhile, and pinned here so "fixing" it silently
    /// inside a mirror PR is impossible.
    func testJapansChineseNamesAreActuallyJapanese() throws {
        for entry in ReportTypes.jp {
            XCTAssertEqual(entry.name["zh-CN"], entry.name["ja"],
                           "\(entry.id): the zh-CN slot holds the ja string verbatim")
        }
        let consumption = try XCTUnwrap(ReportTypes.jp.first { $0.id == "consumption-tax" })
        let zhCN = try XCTUnwrap(consumption.name["zh-CN"])
        XCTAssertEqual(zhCN, "消費税概要")
        XCTAssertTrue(zhCN.unicodeScalars.contains("\u{8CBB}"),
                      "費 U+8CBB is the traditional form; Simplified Chinese is 费 U+8D39")
        XCTAssertNotEqual(zhCN, "消费税概要")
    }

    /// **`eu.js` says 申报 (filing)** in a product whose every other tax label is
    /// forbidden to.
    ///
    /// `scripts/check-tax-labels.mjs:22` bans `/申报/` across
    /// `components/accountingLocaleConfig.ts` and `i18n/locales/*.json` — but it
    /// does not read `electron/reports/`, so this string never came up. Mirrored
    /// verbatim; the guard's scope and the wording are both human decisions.
    func testTheEUReportTypeCarriesTheBannedFilingWord() throws {
        let vatReturn = try XCTUnwrap(ReportTypes.eu.first { $0.id == "vat-return" })
        let zhCN = try XCTUnwrap(vatReturn.name["zh-CN"])
        XCTAssertEqual(zhCN, "VAT 申报概要")
        XCTAssertTrue(zhCN.contains("申报"))
    }

    /// Only China declares `tax-inclusive`, although all five VAT engines emit a
    /// `taxInclusiveSummary` block. The list is a mirror of what each engine
    /// declares, not a description of what it computes.
    func testOnlyChinaDeclaresTheTaxInclusiveReportType() throws {
        XCTAssertTrue(ReportTypes.cn.contains { $0.id == "tax-inclusive" })
        for locale in ["JP", "EU", "KR", "TW"] {
            let table = try XCTUnwrap(ReportTypes.table(for: locale))
            XCTAssertFalse(table.contains { $0.id == "tax-inclusive" },
                           "\(locale) emits the block and declares no report type for it")
        }
    }

    /// `vatSummary` is TWO different shapes depending on the ledger's regime, and
    /// nothing in the JSON says which. This is the `#414` trap, asserted.
    func testTheVatSummaryKeyMeansTwoDifferentShapes() {
        let c = ctx(income: [row(10)], expense: [row(4)])
        let china = Mirror(reflecting: CNReportEngine.vatSummary(c)).children.count
        let korea = Mirror(reflecting: KRReportEngine.vatSummary(c)).children.count
        // Contract fields only — the blocks carry nothing the engines do not emit.
        XCTAssertEqual(china, 5)
        XCTAssertEqual(korea, 3)
        XCTAssertNotEqual(china, korea,
                          "same block key, different shape — reading one as the other is what "
                          + "printed five fabricated zeros on four profiles before #414")
    }

    /// R8's gate. A caller must not be able to reach a rendered report type without
    /// meeting the availability enum first.
    ///
    /// This test used to be called `testAvailabilityMarksEveryIncomeStatementTruncated`
    /// and asserted exactly that, which was true until R7 mirrored the estimate layer.
    /// It is renamed rather than edited in place because the old name was a claim
    /// about the product, and a guard whose name says the opposite of what it checks
    /// is worse than no guard.
    ///
    /// **Every report type the six engines declare is now `.mirrored`** — 13 of them.
    /// `.truncated` and `.absent` have no rows left, and both cases are kept: R8
    /// needs them, and `ReportBatch4ParityTests` still derives its answer through
    /// them. What that means for plan §7.3's "no plausible-looking Chinese income
    /// statement" gate is that the gate is satisfied by having the lines, not by
    /// hiding them.
    func testAvailabilityMarksEveryDeclaredReportTypeMirrored() {
        for locale in ["CN", "US", "JP", "EU", "KR", "TW"] {
            let table = ReportTypes.table(for: locale) ?? []
            XCTAssertFalse(table.isEmpty, "\(locale) declares report types")
            for entry in table {
                XCTAssertEqual(ReportTypes.availability(for: entry.id, locale: locale), .mirrored,
                               "\(locale)/\(entry.id)")
            }
        }
        // A pair that does not exist is still `.absent` — the enum did not lose the
        // case, only its rows.
        XCTAssertEqual(ReportTypes.availability(for: "se-tax", locale: "CN"), .absent)
        XCTAssertEqual(ReportTypes.availability(for: "no-such-report", locale: "US"), .absent)
    }
}
