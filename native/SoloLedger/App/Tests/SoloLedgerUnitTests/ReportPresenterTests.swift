import XCTest
@testable import SoloLedger
import SoloLedgerCore

/// R8 P3a — the mapping layer between what `ReportBuilder` emits and the keys that describe
/// it.
///
/// Two kinds of guard, because there are two kinds of input. Enum mappings are exhaustive by
/// compilation (`ReportPresenter` writes them without `default:`), so the tests here check
/// that the keys are DISTINCT — a mapping that compiles but collapses two states into one
/// string is the failure a compiler cannot see. String-keyed mappings get closed-set equality
/// against sets DERIVED from real reports.
///
/// Every mapping also gets at least one falsification: an input that must NOT map, a pair that
/// must NOT be equal, or an order that must NOT be rearranged.
final class ReportPresenterTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = try ReportFixtureBuilder.makeDirectory()
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: - Derived universes

    /// Every line id, every (locale, report type) pair and every line ORDER, taken from six
    /// real reports rather than restated.
    private func derived() throws -> (lineIDs: Set<String>,
                                      sections: Set<ReportPresenter.SectionID>,
                                      orderedLines: [ReportPresenter.SectionID: [String]]) {
        var lineIDs = Set<String>()
        var sections = Set<ReportPresenter.SectionID>()
        var ordered: [ReportPresenter.SectionID: [String]] = [:]
        for (regime, report) in try ReportFixtureBuilder.allReports(in: directory) {
            XCTAssertEqual(report.locale, regime.rawValue)
            for section in report.sections {
                let id = ReportPresenter.SectionID(report.locale, section.reportTypeID)
                sections.insert(id)
                let ids = section.lines.map(\.id)
                ordered[id] = ids
                lineIDs.formUnion(ids)
            }
            if report.undeclaredTaxInclusiveSummary != nil {
                // The four regimes that emit the block without declaring a report type for it
                // still put three named figures on screen. Their ids come from China's
                // DECLARED section, which is built first — asserted here rather than assumed,
                // because if China ever stopped declaring `tax-inclusive` these four blocks
                // would silently lose their labels.
                XCTAssertNotEqual(regime, .CN, "China declares the block; it must not be undeclared")
                for id in ["purchaseTotal", "salesTotal", "difference"] {
                    XCTAssertTrue(lineIDs.contains(id),
                                  "\(regime.rawValue): \(id) must already be in the derived universe")
                }
            }
        }
        return (lineIDs, sections, ordered)
    }

    // T1 ────────────────────────────────────────────────────────────────────────────────
    func testLineIDUniverseIsExactlySixtyThreeAndMatchesThePresenter() throws {
        let d = try derived()
        XCTAssertEqual(d.lineIDs.count, 63,
                       "the six engines emit 63 distinct line ids; got \(d.lineIDs.count)")
        XCTAssertEqual(ReportPresenter.knownLineIDs, d.lineIDs, """
            the presenter's line universe and the builder's disagree.
            only in the presenter (delete them): \(ReportPresenter.knownLineIDs.subtracting(d.lineIDs).sorted())
            only in the builder (map them): \(d.lineIDs.subtracting(ReportPresenter.knownLineIDs).sorted())
            """)
        for id in d.lineIDs {
            guard case .key(let key) = ReportPresenter.lineLabel(for: id) else {
                return XCTFail("\(id) is emitted by a real report but maps to .unmapped")
            }
            XCTAssertTrue(key.hasPrefix(ReportPresenter.keyPrefix))
        }
    }

    /// Falsification for T1: an id the engines do not emit must NOT acquire a key.
    func testAnUnknownLineIDIsReportedAsUnmappedRatherThanGivenAKey() {
        XCTAssertEqual(ReportPresenter.lineLabel(for: "notALineTheEnginesEmit"),
                       .unmapped(id: "notALineTheEnginesEmit"))
        XCTAssertEqual(ReportPresenter.lineLabel(for: ""), .unmapped(id: ""))
    }

    // T2 ────────────────────────────────────────────────────────────────────────────────
    func testSectionUniverseIsExactlyThirteenPairsAndMatchesThePresenter() throws {
        let d = try derived()
        XCTAssertEqual(d.sections.count, 13)
        XCTAssertEqual(Set(ReportPresenter.sectionTitleKeys.keys), d.sections, """
            the presenter's section universe and the builder's disagree.
            only in the presenter: \(Set(ReportPresenter.sectionTitleKeys.keys).subtracting(d.sections))
            only in the builder: \(d.sections.subtracting(Set(ReportPresenter.sectionTitleKeys.keys)))
            """)
        for id in d.sections {
            guard case .key = ReportPresenter.sectionTitle(locale: id.locale,
                                                           reportTypeID: id.reportTypeID) else {
                return XCTFail("\(id) is declared by a real report but maps to .unmapped")
            }
        }
    }

    /// Falsification for T2: a report type that exists under ONE regime must not resolve
    /// under another. `se-tax` is US-only; `tax-inclusive` is China-only.
    func testAReportTypeDoesNotResolveUnderARegimeThatDoesNotDeclareIt() {
        XCTAssertEqual(ReportPresenter.sectionTitle(locale: "CN", reportTypeID: "se-tax"),
                       .unmapped(locale: "CN", reportTypeID: "se-tax"))
        XCTAssertEqual(ReportPresenter.sectionTitle(locale: "JP", reportTypeID: "tax-inclusive"),
                       .unmapped(locale: "JP", reportTypeID: "tax-inclusive"))
        XCTAssertEqual(ReportPresenter.sectionTitle(locale: "XX", reportTypeID: "income-statement"),
                       .unmapped(locale: "XX", reportTypeID: "income-statement"))
    }

    // T3 / T4 ───────────────────────────────────────────────────────────────────────────
    func testLineKeysAreInjective() {
        var keys = Set<String>()
        for id in ReportPresenter.knownLineIDs {
            guard case .key(let key) = ReportPresenter.lineLabel(for: id) else {
                return XCTFail("\(id) is in the known set but does not map")
            }
            XCTAssertTrue(keys.insert(key).inserted, "two line ids share the key \(key)")
        }
        XCTAssertEqual(keys.count, 63)
    }

    func testSectionKeysAreInjective() {
        let keys = ReportPresenter.sectionTitleKeys.values
        XCTAssertEqual(Set(keys).count, keys.count, "two (locale, report type) pairs share a key")
        XCTAssertEqual(Set(keys).count, 13)
    }

    // T5 ────────────────────────────────────────────────────────────────────────────────
    /// The EU engine calls its top line `revenue` where the other five call it `salesRevenue`.
    /// That is the source's own naming and the plan forbids tidying it away; merging the two
    /// here would hide it behind one label.
    func testTheEUNamingAsymmetryIsPreserved() throws {
        let d = try derived()
        XCTAssertTrue(d.lineIDs.contains("revenue"))
        XCTAssertTrue(d.lineIDs.contains("salesRevenue"))
        XCTAssertNotEqual(ReportPresenter.lineLabel(for: "revenue"),
                          ReportPresenter.lineLabel(for: "salesRevenue"))
        XCTAssertEqual(d.orderedLines[ReportPresenter.SectionID("EU", "profit-loss")]?.first,
                       "revenue")
        XCTAssertEqual(d.orderedLines[ReportPresenter.SectionID("JP", "income-statement")]?.first,
                       "salesRevenue")
    }

    // T6 ────────────────────────────────────────────────────────────────────────────────
    /// Order is data. Schedule C emits `line28_totalExpenses` AFTER `line30_homeOffice`,
    /// which looks like a mistake and is not — it is the engine's own emit order. A test that
    /// only compared sets would let a "tidy-up" sort silently change what the page shows.
    func testLineOrderWithinASectionIsTheEnginesOwn() throws {
        let d = try derived()
        let scheduleC = d.orderedLines[ReportPresenter.SectionID("US", "schedule-c")] ?? []
        XCTAssertEqual(scheduleC.count, 25)
        XCTAssertEqual(scheduleC.first, "line1_grossReceipts")
        XCTAssertEqual(Array(scheduleC.suffix(3)), ["line30_homeOffice", "line28_totalExpenses",
                                                    "line31_netProfit"])
        XCTAssertNotEqual(scheduleC, scheduleC.sorted(),
                          "Schedule C is NOT in sorted order; a test that passes on the sorted "
                          + "array would not notice a reordering")

        XCTAssertEqual(d.orderedLines[ReportPresenter.SectionID("CN", "income-statement")],
                       ["salesRevenue", "costOfSales", "costOfGoodsSold", "operatingExpenses",
                        "grossProfit", "grossMargin", "shippingFee", "adminExpense",
                        "operatingProfit", "taxSurcharge", "incomeTax", "netProfit", "netMargin"])
        XCTAssertEqual(d.orderedLines[ReportPresenter.SectionID("CN", "vat-summary")],
                       ["cumulativeInput", "cumulativeOutput", "certifiedInput",
                        "invoicedOutput", "estimatedPayable"])
    }

    /// China emits two pairs of lines from the SAME expression, so they are equal by
    /// construction. All five are kept — dropping one would be the view editing the model —
    /// and a note key exists to say why the repetition is there.
    func testChinasTurnoverTaxAliasPairsAreEqualAndHaveANote() throws {
        let report = try ReportFixtureBuilder.report(regime: .CN, in: directory)
        let lines = report.sections.first { $0.reportTypeID == "vat-summary" }?.lines ?? []
        func amount(_ id: String) -> Double? {
            guard case .amount(let v)? = lines.first(where: { $0.id == id })?.value else { return nil }
            return v
        }
        XCTAssertEqual(amount("certifiedInput"), amount("cumulativeInput"))
        XCTAssertEqual(amount("invoicedOutput"), amount("cumulativeOutput"))
        XCTAssertTrue(ReportPresenter.chinaTurnoverTaxAliasNoteKey
            .hasPrefix(ReportPresenter.keyPrefix))
        XCTAssertTrue(ReportPresenter.allEmittableKeys()
            .contains(ReportPresenter.chinaTurnoverTaxAliasNoteKey))
    }

    // T7 ────────────────────────────────────────────────────────────────────────────────
    func testEveryBlockerHasDistinctCopyAndOnlyTheAccountingLocalePairOffersSettings() {
        var pairs = Set<String>()
        for blocker in ReportPresenter.allBlockerRepresentatives {
            let copy = ReportPresenter.copy(for: blocker)
            XCTAssertTrue(copy.titleKey.hasPrefix(ReportPresenter.keyPrefix))
            XCTAssertNotEqual(copy.titleKey, copy.bodyKey)
            XCTAssertTrue(pairs.insert("\(copy.titleKey)|\(copy.bodyKey)").inserted,
                          "two blockers share the same copy: \(blocker)")
        }
        XCTAssertEqual(pairs.count, 7)

        XCTAssertEqual(ReportPresenter.copy(for: .accountingLocaleNotConfigured).action,
                       .openSettings)
        XCTAssertEqual(ReportPresenter.copy(for: .accountingLocaleInvalid(storedText: "x")).action,
                       .openSettings)
        // The four currency blockers: Settings shows the currency READ-ONLY. Switching the
        // accounting profile does rewrite it, but it resets the three tax rates with it, so
        // routing a currency refusal there would be advising a side effect, not a repair.
        XCTAssertEqual(ReportPresenter.copy(for: .currencyNotConfigured(periodCurrencies: [],
                                                                       regimeDefault: "CNY")).action,
                       .none)
        XCTAssertEqual(ReportPresenter.copy(for: .currencyInvalid(storedText: "x",
                                                                  periodCurrencies: [],
                                                                  regimeDefault: "CNY")).action,
                       .none)
        XCTAssertEqual(ReportPresenter.copy(for: .currencyMismatch(storedCurrency: "CNY",
                                                                   periodCurrency: "USD")).action,
                       .none)
        XCTAssertEqual(ReportPresenter.copy(for: .multipleCurrenciesInPeriod(codes: ["CNY"])).action,
                       .none)
        // And the one that has no repair anywhere: this app does not read the legacy tables by
        // design, so no button could change the answer.
        XCTAssertEqual(ReportPresenter.copy(for: .legacySourceUnavailable).action, .none)
    }

    /// Falsification for T7: exactly two of the seven may offer Settings. If a later change
    /// adds a third, this count moves and the test says so.
    func testExactlyTwoBlockersOfferSettingsAndFiveOfferNothing() {
        let actions = ReportPresenter.allBlockerRepresentatives.map {
            ReportPresenter.copy(for: $0).action
        }
        XCTAssertEqual(actions.filter { $0 == .openSettings }.count, 2)
        XCTAssertEqual(actions.filter { $0 == .none }.count, 5)
    }

    // T8 ────────────────────────────────────────────────────────────────────────────────
    func testFieldRenderingKeepsTheFourStatesApart() {
        XCTAssertEqual(ReportPresenter.rendering(for: .amount(12.5)), .amount(12.5))

        guard case .corrupted(let corruptedKey) =
                ReportPresenter.rendering(for: .corrupted) else { return XCTFail("corrupted") }
        guard case .notConfigured(let notConfiguredKey, let notConfiguredName) =
                ReportPresenter.rendering(for: .notConfigured(parameter: .incomeTaxRate))
        else { return XCTFail("notConfigured") }
        guard case .needsRepair(let repairKey, let repairName, let storedText) =
                ReportPresenter.rendering(for: .needsRepair(parameter: .surchargeRate,
                                                            storedText: "\"25%\""))
        else { return XCTFail("needsRepair") }

        XCTAssertEqual(Set([corruptedKey, notConfiguredKey, repairKey]).count, 3,
                       "a refusal and a corrupt value must not share copy")
        XCTAssertNotEqual(notConfiguredName, repairName,
                          "the two rate parameters must not share a name key")
        XCTAssertEqual(storedText, "\"25%\"", "storedText must reach the view verbatim")
    }

    // T9 ────────────────────────────────────────────────────────────────────────────────
    /// `renderWithMissingLines` has NO producer today — every declared pair is `renderInFull`
    /// after R7. This verifies the MAPPING and is not evidence that a real ledger reaches it.
    func testSectionRenderingKeepsTheThreeStatesApart() throws {
        XCTAssertEqual(ReportPresenter.rendering(for: .renderInFull), .full)
        XCTAssertEqual(ReportPresenter.rendering(for: .withhold), .withheld)
        guard case .withMissingLines(let noteKey) =
                ReportPresenter.rendering(for: .renderWithMissingLines) else {
            return XCTFail("renderWithMissingLines must carry a note key")
        }
        XCTAssertTrue(noteKey.hasPrefix(ReportPresenter.keyPrefix))

        // And the production statement, measured: no real report is anything but full today.
        for (_, report) in try ReportFixtureBuilder.allReports(in: directory) {
            for section in report.sections {
                XCTAssertEqual(ReportPresenter.rendering(for: section.availability), .full,
                               "\(report.locale)/\(section.reportTypeID)")
            }
        }
    }

    // T10 ───────────────────────────────────────────────────────────────────────────────
    func testEachParameterAxisMapsToDistinctKeys() {
        let stored = [StoredSettingState.absent, .usable(1), .needsRepair(storedText: "x")]
            .map(ReportPresenter.storedKey(for:))
        XCTAssertEqual(Set(stored).count, 3)

        let effects = [ParameterEffect.appliedValue(1, origin: .storedValue), .appliedNonFinite,
                       .refused(.incomeTaxRate)].map(ReportPresenter.effectKey(for:))
        XCTAssertEqual(Set(effects).count, 3)

        let origins = [EffectOrigin.storedValue, .regimeDefault, .dispatcherFallback]
            .map(ReportPresenter.originKey(for:))
        XCTAssertEqual(Set(origins).count, 3)
        // The pair that matters: a rate the app chose on the user's behalf must be disclosed,
        // and a dispatcher fallback of 0 is a real value. Sharing a key would erase that.
        XCTAssertNotEqual(ReportPresenter.originKey(for: .regimeDefault),
                          ReportPresenter.originKey(for: .dispatcherFallback))

        let consumption = [ParameterConsumption.consumed, .storedButUnread]
            .map(ReportPresenter.consumptionKey(for:))
        XCTAssertEqual(Set(consumption).count, 2)

        let names = ReportParameterKey.allCases.map(ReportPresenter.nameKey(for:))
        XCTAssertEqual(Set(names).count, 4)
        // One concept, one string: the rate a refusal names and the settings row it comes from
        // must share a key, or the same rate gets two names on one screen.
        XCTAssertEqual(ReportPresenter.nameKey(for: ReportRateParameter.incomeTaxRate),
                       ReportPresenter.nameKey(for: ReportParameterKey.incomeTaxRate))
        XCTAssertEqual(ReportPresenter.nameKey(for: ReportRateParameter.surchargeRate),
                       ReportPresenter.nameKey(for: ReportParameterKey.surchargeRate))
    }

    /// The turnover-tax rate's label carries `{tax}`; the other three do not. A copy PR that
    /// forgets the token, or adds one where the code will not substitute it, fails here.
    func testOnlyTheDeclaredKeysRequirePlaceholders() {
        XCTAssertEqual(ReportPresenter.requiredPlaceholders[
            ReportPresenter.nameKey(for: ReportParameterKey.vatRate)], ["{tax}"])
        XCTAssertNil(ReportPresenter.requiredPlaceholders[
            ReportPresenter.nameKey(for: ReportParameterKey.incomeTaxRate)])
        XCTAssertEqual(ReportPresenter.requiredPlaceholders[
            ReportPresenter.originKey(for: .regimeDefault)], ["{percent}"])
        for id in ReportPresenter.taxInterpolatedLineIDs {
            guard case .key(let key) = ReportPresenter.lineLabel(for: id) else {
                return XCTFail("\(id) must be a known line")
            }
            XCTAssertEqual(ReportPresenter.requiredPlaceholders[key], ["{tax}"])
        }
        XCTAssertEqual(ReportPresenter.taxInterpolatedLineIDs.count, 6)
        // A profit-and-loss line is not regime-named and must NOT take the token.
        guard case .key(let netProfit) = ReportPresenter.lineLabel(for: "netProfit") else {
            return XCTFail("netProfit must be a known line")
        }
        XCTAssertNil(ReportPresenter.requiredPlaceholders[netProfit])
    }

    // T11 ───────────────────────────────────────────────────────────────────────────────
    func testOnlyOperatingCashflowIsEverComputed() throws {
        for (_, report) in try ReportFixtureBuilder.allReports(in: directory) {
            XCTAssertEqual(ReportPresenter.rendering(for: report.cashflow.operating), .computed)
            for section in [report.cashflow.investing, report.cashflow.financing,
                            report.cashflow.beginningCash, report.cashflow.endingCash] {
                guard case .copy(let key) = ReportPresenter.rendering(for: section) else {
                    return XCTFail("\(report.locale): a non-operating cash-flow section carried "
                                   + "a computed figure")
                }
                XCTAssertTrue(key.hasPrefix(ReportPresenter.keyPrefix))
            }
            XCTAssertFalse(report.cashflow.statutory)
            XCTAssertEqual(report.cashflow.basis, "cash")
        }
    }

    // T12 ───────────────────────────────────────────────────────────────────────────────
    func testNoteAndWarningKeysAreDistinct() {
        let notes = [PresentedNote.estimatedTaxDueDates(["2025-04-15"]),
                     .selfEmploymentParameterYear(2025)].map(ReportPresenter.key(for:))
        XCTAssertEqual(Set(notes).count, 2)
        let warnings = [PresentedWarning.estimatedQuarterlyPayment(amount: .amount(1)),
                        .mealsLimitedToFiftyPercent].map(ReportPresenter.key(for:))
        XCTAssertEqual(Set(warnings).count, 2)
        XCTAssertEqual(ReportPresenter.requiredPlaceholders[warnings[0]], ["{amount}"])
        XCTAssertNil(ReportPresenter.requiredPlaceholders[warnings[1]])
    }

    // T13 ───────────────────────────────────────────────────────────────────────────────
    /// The parameter states that matter, produced by real ledgers rather than constructed.
    func testParameterStatesAreReachableAndMapAsDesigned() throws {
        // (a) regimeDefault — China substitutes its own 25% for a MISSING income-tax row.
        let cn = try ReportFixtureBuilder.makeStore(regime: .CN, in: directory, filename: "regime")
        defer { try? cn.db.close() }
        try cn.settings.remove(SettingsStore.Key.incomeTaxRate)
        guard case .report(let cnReport) =
                try ReportBuilder.build(cn.db, period: ReportPeriod(year: ReportFixtureBuilder.year))
        else { return XCTFail("CN fixture blocked") }
        let incomeTax = try XCTUnwrap(cnReport.parameters.first { $0.key == .incomeTaxRate })
        XCTAssertEqual(incomeTax.stored, .absent)
        guard case .appliedValue(let percent, let origin) = incomeTax.nativeEffect else {
            return XCTFail("a missing Chinese income-tax rate must still price the report")
        }
        XCTAssertEqual(origin, .regimeDefault)
        XCTAssertEqual(percent, 25)
        XCTAssertEqual(ReportPresenter.originKey(for: origin),
                       ReportPresenter.originKey(for: .regimeDefault))

        // (b) storedButUnread — vat_rate is loaded by the dispatcher and read by no engine.
        let vat = try XCTUnwrap(cnReport.parameters.first { $0.key == .vatRate })
        XCTAssertEqual(vat.consumption, .storedButUnread)
        // and surcharge_rate is consumed ONLY under China
        XCTAssertEqual(try XCTUnwrap(cnReport.parameters.first { $0.key == .surchargeRate })
            .consumption, .consumed)
        let jpReport = try ReportFixtureBuilder.report(regime: .JP, in: directory)
        XCTAssertEqual(try XCTUnwrap(jpReport.parameters.first { $0.key == .surchargeRate })
            .consumption, .storedButUnread)

        // (c) needsRepair — the two rows a repair screen must be able to tell apart.
        let quoted = try ReportFixtureBuilder.makeStore(regime: .CN, in: directory, filename: "q")
        defer { try? quoted.db.close() }
        try ReportFixtureBuilder.writeRawSetting(quoted, key: SettingsStore.Key.incomeTaxRate,
                                                 rawText: "\"25%\"")
        guard case .report(let quotedReport) =
                try ReportBuilder.build(quoted.db,
                                        period: ReportPeriod(year: ReportFixtureBuilder.year))
        else { return XCTFail("quoted fixture blocked") }
        guard case .needsRepair(let quotedText) =
                try XCTUnwrap(quotedReport.parameters.first { $0.key == .incomeTaxRate }).stored
        else { return XCTFail("a non-numeric rate row must be needsRepair") }
        XCTAssertEqual(quotedText, "\"25%\"")

        let bare = try ReportFixtureBuilder.makeStore(regime: .CN, in: directory, filename: "b")
        defer { try? bare.db.close() }
        try ReportFixtureBuilder.writeRawSetting(bare, key: SettingsStore.Key.incomeTaxRate,
                                                 rawText: "25%")
        guard case .report(let bareReport) =
                try ReportBuilder.build(bare.db,
                                        period: ReportPeriod(year: ReportFixtureBuilder.year))
        else { return XCTFail("bare fixture blocked") }
        guard case .needsRepair(let bareText) =
                try XCTUnwrap(bareReport.parameters.first { $0.key == .incomeTaxRate }).stored
        else { return XCTFail("a bare non-JSON rate row must be needsRepair") }
        XCTAssertEqual(bareText, "25%")
        XCTAssertNotEqual(quotedText, bareText,
                          "the quoted and bare rows are different rows and must stay different")

        // (d) appliedNonFinite — only the admin expense can reach it.
        let nonFinite = try ReportFixtureBuilder.makeStore(regime: .CN, in: directory, filename: "n")
        defer { try? nonFinite.db.close() }
        try ReportFixtureBuilder.writeRawSetting(nonFinite,
                                                 key: SettingsStore.Key.adminExpenseAnnual,
                                                 rawText: "\"5000元\"")
        guard case .report(let nonFiniteReport) =
                try ReportBuilder.build(nonFinite.db,
                                        period: ReportPeriod(year: ReportFixtureBuilder.year))
        else { return XCTFail("non-finite fixture blocked") }
        XCTAssertEqual(try XCTUnwrap(nonFiniteReport.parameters
            .first { $0.key == .adminExpenseAnnual }).nativeEffect, .appliedNonFinite)
    }

    /// A blocker reached the honest way: a fresh ledger seeds `accounting_locale` and NOT
    /// `currency`, so the builder refuses instead of inventing one.
    func testAFreshLedgerIsBlockedOnCurrencyRatherThanDefaultingToOne() throws {
        let store = try LedgerStore(databaseURL: directory.appendingPathComponent("fresh.db"))
        defer { try? store.db.close() }
        try store.create(Transaction(type: .income, date: "\(ReportFixtureBuilder.year)-05-01",
                                     amount: 10, currency: "CNY"))
        guard case .blocked(let blocker) =
                try ReportBuilder.build(store.db,
                                        period: ReportPeriod(year: ReportFixtureBuilder.year))
        else { return XCTFail("a ledger with no currency row must not produce a report") }
        guard case .currencyNotConfigured = blocker else {
            return XCTFail("expected currencyNotConfigured, got \(blocker)")
        }
        XCTAssertEqual(ReportPresenter.copy(for: blocker).action, .none)
    }

    /// A year with no rows is a legacy-source refusal, NOT a report of zeros — which is what
    /// makes an arbitrary historical year safe to offer in the picker.
    func testAYearWithNoRowsIsRefusedRatherThanReportedAsZeros() throws {
        let store = try ReportFixtureBuilder.makeStore(regime: .CN, in: directory, filename: "empty")
        defer { try? store.db.close() }
        guard case .blocked(.legacySourceUnavailable) =
                try ReportBuilder.build(store.db, period: ReportPeriod(year: "1998")) else {
            return XCTFail("an empty period must stop at legacySourceUnavailable")
        }
        XCTAssertEqual(ReportPresenter.copy(for: .legacySourceUnavailable).action, .none)
    }

    // T18 ───────────────────────────────────────────────────────────────────────────────
    /// A built report is a value. Changing the ledger's regime afterwards cannot reach back
    /// into it — which is the structural reason a view may only read `report.currency`.
    func testAChangeOfSettingsDoesNotReachIntoAnAlreadyBuiltReport() throws {
        let store = try ReportFixtureBuilder.makeStore(regime: .CN, in: directory, filename: "snap")
        defer { try? store.db.close() }
        guard case .report(let report) =
                try ReportBuilder.build(store.db,
                                        period: ReportPeriod(year: ReportFixtureBuilder.year))
        else { return XCTFail("CN fixture blocked") }
        XCTAssertEqual(report.currency, "CNY")
        XCTAssertEqual(report.locale, "CN")

        try store.settings.applyRegimeSwitch(AccountingProfile.us)
        XCTAssertEqual(try store.settings.string(SettingsStore.Key.currency), "USD")

        XCTAssertEqual(report.currency, "CNY", "the held report must not follow the settings")
        XCTAssertEqual(report.locale, "CN")
        XCTAssertEqual(ReportFormat.currencyDisplay(report.currency), "CNY")
    }

    // MARK: - The turnover tax's own name

    func testTheTurnoverTaxNameComesFromTheReportsRegimeAndTheUILanguage() {
        XCTAssertEqual(ReportPresenter.turnoverTaxName(reportLocale: "JP", uiLanguage: "ja"), "消費税")
        XCTAssertEqual(ReportPresenter.turnoverTaxName(reportLocale: "JP", uiLanguage: "zh-Hans"),
                       "消费税")
        XCTAssertEqual(ReportPresenter.turnoverTaxName(reportLocale: "TW", uiLanguage: "en"),
                       "Business Tax")
        XCTAssertEqual(ReportPresenter.turnoverTaxName(reportLocale: "CN", uiLanguage: "fr"), "TVA")
        // Falsification: two different regimes must not answer the same thing in one language.
        XCTAssertNotEqual(ReportPresenter.turnoverTaxName(reportLocale: "JP", uiLanguage: "en"),
                          ReportPresenter.turnoverTaxName(reportLocale: "TW", uiLanguage: "en"))
        // An unknown language falls back to English rather than to an empty label.
        XCTAssertEqual(ReportPresenter.turnoverTaxName(reportLocale: "CN", uiLanguage: "de"), "VAT")
        XCTAssertNil(ReportPresenter.turnoverTaxName(reportLocale: "XX", uiLanguage: "en"))
    }

    /// The regime used for the name is the REPORT's, never the app's current one.
    func testTheTurnoverTaxNameIgnoresTheLedgersCurrentRegime() throws {
        let store = try ReportFixtureBuilder.makeStore(regime: .JP, in: directory, filename: "name")
        defer { try? store.db.close() }
        guard case .report(let report) =
                try ReportBuilder.build(store.db,
                                        period: ReportPeriod(year: ReportFixtureBuilder.year))
        else { return XCTFail("JP fixture blocked") }
        try store.settings.applyRegimeSwitch(AccountingProfile.tw)
        XCTAssertEqual(ReportPresenter.turnoverTaxName(reportLocale: report.locale,
                                                       uiLanguage: "en"),
                       "Consumption Tax")
    }

    // T34 ───────────────────────────────────────────────────────────────────────────────
    func testEveryEmittableKeyIsNamespacedCountedAndFreeOfValidityClaims() {
        let keys = ReportPresenter.allEmittableKeys()
        // A ratchet, not a smoke test: 63 lines + 13 sections + 4 undeclared blocks + 1 alias
        // note + 14 blocker (7 x title/body) + 3 field states + 1 missing-lines note + 3 stored
        // + 3 effect + 3 origin + 2 consumption + 4 parameter names + 1 cash-flow + 2 notes
        // + 2 warnings. Two concepts that collide on one key make this number fall.
        XCTAssertEqual(keys.count, 119)
        for key in keys {
            XCTAssertTrue(key.hasPrefix(ReportPresenter.keyPrefix), "\(key) escapes the namespace")
            XCTAssertFalse(key.contains(" "), "\(key) contains whitespace")
            XCTAssertFalse(key.hasSuffix("."), "\(key) is truncated")
            // The app is in no position to say a currency code is standard, official or ISO —
            // `resolveCurrency` checks a non-empty JSON string and nothing else, so a key named
            // for such a claim would invite copy that makes it.
            //
            // "invalid" is deliberately NOT banned: `currencyInvalid` and
            // `accountingLocaleInvalid` are the Core's own names for a REFUSAL to read a row,
            // which is the opposite of a claim about a standard.
            for banned in ["iso", "standard", "official"] {
                XCTAssertFalse(key.lowercased().contains(banned),
                               "\(key) names a validity claim this app cannot make")
            }
        }
        // Every placeholder contract must be about a key this file can actually emit.
        for key in ReportPresenter.requiredPlaceholders.keys {
            XCTAssertTrue(keys.contains(key), "\(key) has a placeholder contract but is never emitted")
        }
    }

    // T29 ───────────────────────────────────────────────────────────────────────────────
    /// The clock is read in exactly one place. A `Date()` that appears in the presenter or the
    /// formatters is a report whose content can change without the user asking.
    func testTheWallClockIsReadOnlyInReportYear() throws {
        for path in ["App/ReportPresenter.swift", "App/ReportPageState.swift",
                     "Views/ReportFormatters.swift"] {
            let text = try ReportFixtureBuilder.appSource(path)
            XCTAssertFalse(text.contains("Date()"), "\(path) reads the wall clock")
            XCTAssertFalse(text.contains("Calendar.current"), "\(path) reads the calendar")
        }
        XCTAssertTrue(try ReportFixtureBuilder.appSource("App/ReportYear.swift").contains("Date()"))
    }

    // T31 ───────────────────────────────────────────────────────────────────────────────
    /// P3e adds the user-reachable path. The sidebar list and the menu-bar picker both iterate
    /// `SidebarSection.allCases`, so the one new case is both entry points at once.
    ///
    /// This owns the ENUM's shape only. The copy behind `titleKey` is owned elsewhere:
    /// `ReportStructuralCopyTests` proves it resolves in six languages, `ReportStateCopyTests`
    /// proves it is the same string as the page's own title.
    func testTheReportPageHasItsEntryPoint() {
        XCTAssertEqual(SidebarSection.allCases.map(\.rawValue),
                       ["overview", "transactions", "categories", "products", "reports"])
        XCTAssertEqual(SidebarSection(rawValue: "reports"), .reports)
        XCTAssertEqual(SidebarSection.reports.titleKey, "nav.reports")
        for section in SidebarSection.allCases {
            XCTAssertEqual(section.titleKey, "nav.\(section.rawValue)")
            XCTAssertFalse(section.systemImage.isEmpty, "\(section.rawValue) has no sidebar icon")
        }
    }

    // T32 / T30 ─────────────────────────────────────────────────────────────────────────
    func testEveryNonEmptyStateCarriesItsOwnYear() throws {
        let report = try ReportFixtureBuilder.report(regime: .CN, in: directory)
        XCTAssertEqual(ReportPageState.report(report).year, ReportFixtureBuilder.year)
        XCTAssertEqual(ReportPageState.report(report).year, report.period.year)
        XCTAssertEqual(ReportPageState.blocked(year: "2019", .legacySourceUnavailable).year, "2019")
        XCTAssertEqual(ReportPageState.failed(year: "2019").year, "2019")
        XCTAssertNil(ReportPageState.notRequested.year)
    }

    @MainActor
    func testBuildingWithoutALedgerClearsTheStateAndAttemptsNothing() {
        let model = AppModel()
        XCTAssertEqual(model.reportState, .notRequested)
        XCTAssertTrue(ReportYear.isValid(model.reportYearText),
                      "the default year must be inside the sound domain")
        model.buildReport()
        XCTAssertEqual(model.reportState, .notRequested)
    }

    @MainActor
    func testTheDefaultYearIsReadOnceAndDoesNotDrift() {
        let model = AppModel()
        let first = model.reportYearText
        _ = model.reportYearText
        XCTAssertEqual(model.reportYearText, first)
        XCTAssertEqual(first.count, ReportYear.width)
    }

    @MainActor
    func testAnInvalidYearIsNotBuiltAtAll() {
        let model = AppModel()
        model.reportYearText = "20"
        XCTAssertFalse(model.reportYearIsValid)
        model.buildReport()
        XCTAssertEqual(model.reportState, .notRequested)
    }

    // T33 ───────────────────────────────────────────────────────────────────────────────
    /// The real proof that the new sources are members of the App target is that this file
    /// compiles: `@testable import SoloLedger` links the app, and a source Xcode did not build
    /// would make every reference below unresolved. The assertion keeps the intent visible.
    func testTheNewSourcesAreLinkedIntoTheAppTarget() {
        XCTAssertEqual(ReportPresenter.keyPrefix, "report.")
        XCTAssertEqual(ReportYear.width, 4)
        XCTAssertEqual(ReportFormat.previewCharacterLimit, 120)
        XCTAssertNil(ReportPageState.notRequested.year)
    }
}
