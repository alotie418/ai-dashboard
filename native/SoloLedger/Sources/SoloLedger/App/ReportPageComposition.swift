import Foundation
import SoloLedgerCore

/// What the report page draws, region by region, as a value a test can hold.
///
/// ## Why this exists
///
/// The four disclaimers have to be PROVEN to be on screen, and the usual way — drive the UI
/// and look — is closed: XCUITest needs the runner to enable automation mode, and that hangs
/// in a headless session. So the page is built from a declared composition instead of from
/// keys scattered through view bodies, and the composition is what the tests read.
///
/// That only works if the views have no OTHER source of keys. They do not: every subview is
/// handed its slice of this value and renders exactly what the slice names. A key that is not
/// in the composition cannot reach the screen, and a key in the composition that the view
/// forgets to draw is a bug the region assertions catch.
///
/// ## Two layers
///
/// ``placement`` is the static half — every key this page can ever draw, and where. It is total
/// over the whole `report.*` namespace, so a key with no entry is copy the page never shows and
/// a key in the namespace with no entry fails the closure test.
///
/// ``compose(_:uiLanguage:)`` is the per-state half: given one `ReportPageState`, exactly which
/// of those keys this particular render uses.
enum ReportPageComposition {

    /// Where on the page a key is drawn.
    enum Region: String, CaseIterable, Equatable {
        case header
        case notRequested
        case blocked
        case failed
        /// A figure that is not a number — damaged, refused, or a setting needing repair.
        case fieldState
        case section
        case undeclaredBlock
        case parameters
        case cashflow
        case monthly
        case notes
        case warnings
        case pageFooter
    }

    /// Every key the report page can draw, and the region it belongs to.
    ///
    /// Total over the `report.*` namespace by construction, and asserted to be — 161 keys landed
    /// by the two copy PRs plus the four disclaimers this one adds.
    static let placement: [String: Region] = [
        // MARK: header (8)
        "report.page.title": .header,
        "report.year.label": .header,
        "report.year.invalid": .header,
        "report.period.caption": .header,
        "report.currency.caption": .header,
        "report.currency.note": .header,
        "report.currency.formatNote": .header,
        "report.estimate.badge": .header,
        // MARK: notRequested (3)
        "report.notRequested.title": .notRequested,
        "report.notRequested.message": .notRequested,
        "report.action.build": .notRequested,
        // MARK: blocked (19)
        "report.blocker.accountingLocaleInvalid.body": .blocked,
        "report.blocker.accountingLocaleInvalid.title": .blocked,
        "report.blocker.accountingLocaleNotConfigured.body": .blocked,
        "report.blocker.accountingLocaleNotConfigured.title": .blocked,
        "report.blocker.currencyInvalid.body": .blocked,
        "report.blocker.currencyInvalid.title": .blocked,
        "report.blocker.currencyMismatch.body": .blocked,
        "report.blocker.currencyMismatch.title": .blocked,
        "report.blocker.currencyNotConfigured.body": .blocked,
        "report.blocker.currencyNotConfigured.title": .blocked,
        "report.blocker.legacySourceUnavailable.body": .blocked,
        "report.blocker.legacySourceUnavailable.title": .blocked,
        "report.blocker.multipleCurrenciesInPeriod.body": .blocked,
        "report.blocker.multipleCurrenciesInPeriod.title": .blocked,
        "report.blocker.periodCurrencies": .blocked,
        "report.blocker.regimeDefaultCurrency": .blocked,
        "report.blocker.storedCurrency": .blocked,
        "report.action.openSettings": .blocked,
        "report.action.openSettings.hint": .blocked,
        // MARK: failed (3)
        "report.error.title": .failed,
        "report.error.message": .failed,
        "report.action.retry": .failed,
        // MARK: fieldState (4)
        "report.field.corrupted": .fieldState,
        "report.field.notConfigured": .fieldState,
        "report.field.needsRepair": .fieldState,
        "report.storedText.label": .fieldState,
        // MARK: section (80)
        "report.section.CN.incomeStatement": .section,
        "report.section.CN.taxInclusive": .section,
        "report.section.CN.vatSummary": .section,
        "report.section.CN.vatSummary.aliasNote": .section,
        "report.section.EU.profitLoss": .section,
        "report.section.EU.vatReturn": .section,
        "report.section.JP.consumptionTax": .section,
        "report.section.JP.incomeStatement": .section,
        "report.section.KR.incomeStatement": .section,
        "report.section.KR.vatSummary": .section,
        "report.section.TW.businessTax": .section,
        "report.section.TW.incomeStatement": .section,
        "report.section.US.scheduleC": .section,
        "report.section.US.seTax": .section,
        "report.section.missingLines": .section,
        "report.line.additionalMedicare": .section,
        "report.line.adminExpense": .section,
        "report.line.annualIncomeTax": .section,
        "report.line.annualSETax": .section,
        "report.line.certifiedInput": .section,
        "report.line.collected": .section,
        "report.line.costOfGoodsSold": .section,
        "report.line.costOfSales": .section,
        "report.line.cumulativeInput": .section,
        "report.line.cumulativeOutput": .section,
        "report.line.difference": .section,
        "report.line.estimatedPayable": .section,
        "report.line.grossMargin": .section,
        "report.line.grossProfit": .section,
        "report.line.incomeTax": .section,
        "report.line.inputVAT": .section,
        "report.line.invoicedOutput": .section,
        "report.line.line10_commissions": .section,
        "report.line.line11_contract": .section,
        "report.line.line13_depreciation": .section,
        "report.line.line15_insurance": .section,
        "report.line.line16b_interest": .section,
        "report.line.line17_legal": .section,
        "report.line.line18_office": .section,
        "report.line.line1_grossReceipts": .section,
        "report.line.line20_rent": .section,
        "report.line.line21_repairs": .section,
        "report.line.line22_supplies": .section,
        "report.line.line23_taxes": .section,
        "report.line.line24a_travel": .section,
        "report.line.line24b_meals": .section,
        "report.line.line25_utilities": .section,
        "report.line.line26_wages": .section,
        "report.line.line27a_other": .section,
        "report.line.line28_totalExpenses": .section,
        "report.line.line2_returns": .section,
        "report.line.line30_homeOffice": .section,
        "report.line.line31_netProfit": .section,
        "report.line.line6_otherIncome": .section,
        "report.line.line7_grossIncome": .section,
        "report.line.line8_advertising": .section,
        "report.line.line9_car": .section,
        "report.line.medicareTax": .section,
        "report.line.netEarnings": .section,
        "report.line.netMargin": .section,
        "report.line.netProfit": .section,
        "report.line.operatingExpenses": .section,
        "report.line.operatingProfit": .section,
        "report.line.outputVAT": .section,
        "report.line.paid": .section,
        "report.line.payable": .section,
        "report.line.purchaseTotal": .section,
        "report.line.quarterlyPayment": .section,
        "report.line.revenue": .section,
        "report.line.salesRevenue": .section,
        "report.line.salesTotal": .section,
        "report.line.seEarnings": .section,
        "report.line.shippingFee": .section,
        "report.line.socialSecurityTax": .section,
        "report.line.taxSurcharge": .section,
        "report.line.totalAnnual": .section,
        "report.line.totalSETax": .section,
        "report.line.vatPayable": .section,
        "report.disclaimer.tax": .section,
        "report.disclaimer.usTax": .section,
        // MARK: undeclaredBlock (4)
        "report.block.EU.taxInclusive": .undeclaredBlock,
        "report.block.JP.taxInclusive": .undeclaredBlock,
        "report.block.KR.taxInclusive": .undeclaredBlock,
        "report.block.TW.taxInclusive": .undeclaredBlock,
        // MARK: parameters (20)
        "report.params.title": .parameters,
        "report.params.axis.consumption": .parameters,
        "report.params.axis.effect": .parameters,
        "report.params.axis.stored": .parameters,
        "report.param.consumption.consumed": .parameters,
        "report.param.consumption.storedButUnread": .parameters,
        "report.param.effect.applied": .parameters,
        "report.param.effect.nonFinite": .parameters,
        "report.param.effect.refused": .parameters,
        "report.param.name.adminExpenseAnnual": .parameters,
        "report.param.name.incomeTaxRate": .parameters,
        "report.param.name.surchargeRate": .parameters,
        "report.param.name.vatRate": .parameters,
        "report.param.origin.dispatcherFallback": .parameters,
        "report.param.origin.regimeDefault": .parameters,
        "report.param.origin.storedValue": .parameters,
        "report.param.stored.absent": .parameters,
        "report.param.stored.needsRepair": .parameters,
        "report.param.stored.usable": .parameters,
        "report.disclaimer.rates": .parameters,
        // MARK: cashflow (12)
        "report.cashflow.basisNote": .cashflow,
        "report.cashflow.beginningCash": .cashflow,
        "report.cashflow.endingCash": .cashflow,
        "report.cashflow.financing": .cashflow,
        "report.cashflow.inflow": .cashflow,
        "report.cashflow.investing": .cashflow,
        "report.cashflow.net": .cashflow,
        "report.cashflow.notDerivable": .cashflow,
        "report.cashflow.operating.title": .cashflow,
        "report.cashflow.outflow": .cashflow,
        "report.cashflow.title": .cashflow,
        "report.cashflow.vsProfitNote": .cashflow,
        // MARK: monthly (5)
        "report.monthly.cost": .monthly,
        "report.monthly.month": .monthly,
        "report.monthly.profit": .monthly,
        "report.monthly.revenue": .monthly,
        "report.monthly.title": .monthly,
        // MARK: notes (3)
        "report.notes.title": .notes,
        "report.note.estimatedTaxDueDates": .notes,
        "report.note.selfEmploymentParameterYear": .notes,
        // MARK: warnings (3)
        "report.warnings.title": .warnings,
        "report.warning.estimatedQuarterlyPayment": .warnings,
        "report.warning.mealsLimitedToFiftyPercent": .warnings,
        // MARK: pageFooter (1)
        "report.disclaimer.report": .pageFooter,
    ]

    // MARK: - The four disclaimers, and where each one sits

    static let reportDisclaimerKey = "report.disclaimer.report"
    static let taxDisclaimerKey    = "report.disclaimer.tax"
    static let usTaxDisclaimerKey  = "report.disclaimer.usTax"
    static let ratesDisclaimerKey  = "report.disclaimer.rates"

    /// The five report types that state an ESTIMATED tax amount, and therefore carry
    /// ``taxDisclaimerKey`` at the foot of their block.
    ///
    /// The tax-inclusive blocks are deliberately NOT in this set. They add up amounts the user
    /// recorded and state the difference; they estimate no tax, so a note saying "this is an
    /// estimate, not a basis for filing" would be attached to figures it does not describe.
    /// The page-level disclaimer still covers them.
    static let turnoverTaxReportTypeIDs: Set<ReportPresenter.SectionID> = [
        ReportPresenter.SectionID("CN", "vat-summary"),
        ReportPresenter.SectionID("JP", "consumption-tax"),
        ReportPresenter.SectionID("EU", "vat-return"),
        ReportPresenter.SectionID("KR", "vat-summary"),
        ReportPresenter.SectionID("TW", "business-tax"),
    ]

    static let selfEmploymentSectionID = ReportPresenter.SectionID("US", "se-tax")

    // MARK: - One section as the page will draw it

    struct SectionBlock: Equatable {
        let reportTypeID: String
        let titleKey: String
        /// In the engine's own emit order — the order is data, not presentation.
        let lineKeys: [String]
        /// The China alias note, and the not-fully-mirrored note when that state ever occurs.
        let noteKeys: [String]
        /// The disclaimer at the foot of this block, if this block states an estimated tax.
        let disclaimerKeys: [String]

        var allKeys: [String] { [titleKey] + lineKeys + noteKeys + disclaimerKeys }
    }

    /// A refused report: what it says, what facts it shows, and what — if anything — it offers.
    struct BlockedBlock: Equatable {
        let titleKey: String
        let bodyKey: String
        /// The currency codes or the stored text the refusal can point at. Facts, not repairs.
        let factKeys: [String]
        let action: ReportPresenter.BlockerAction
        /// Empty whenever `action` is `.none`, so a page with no control also has no copy
        /// describing one.
        let actionKeys: [String]

        var allKeys: [String] { [titleKey, bodyKey] + factKeys + actionKeys }
    }

    struct ParameterBlock: Equatable {
        let titleKey: String
        let axisKeys: [String]
        /// One entry per parameter: its name, and the three keys describing its three axes.
        let rows: [[String]]
        let disclaimerKeys: [String]

        var allKeys: [String] { [titleKey] + axisKeys + rows.flatMap { $0 } + disclaimerKeys }
    }

    struct ReportBody: Equatable {
        let sections: [SectionBlock]
        let undeclaredTaxInclusive: SectionBlock?
        let parameters: ParameterBlock
        let cashflowKeys: [String]
        let monthlyKeys: [String]
        let noteKeys: [String]
        let warningKeys: [String]
        /// The page-level disclaimer.
        let footerKeys: [String]

        var allKeys: [String] {
            sections.flatMap(\.allKeys)
                + (undeclaredTaxInclusive?.allKeys ?? [])
                + parameters.allKeys + cashflowKeys + monthlyKeys
                + noteKeys + warningKeys + footerKeys
        }
    }

    // MARK: - The composition itself

    struct Page: Equatable {
        let headerKeys: [String]
        /// Exactly one of the four below is non-nil, matching the state it was composed from.
        let notRequestedKeys: [String]?
        let blocked: BlockedBlock?
        let failedKeys: [String]?
        let body: ReportBody?
        /// The page-level disclaimer for the two states that have no body. `.notRequested`
        /// leaves it empty: nothing is on screen for it to qualify.
        let footerKeys: [String]

        var allKeys: Set<String> {
            var keys = Set(headerKeys)
            keys.formUnion(notRequestedKeys ?? [])
            keys.formUnion(blocked?.allKeys ?? [])
            keys.formUnion(failedKeys ?? [])
            keys.formUnion(body?.allKeys ?? [])
            keys.formUnion(footerKeys)
            return keys
        }
    }

    /// Compose the page for one state.
    ///
    /// `uiLanguage` is carried because the line labels the section blocks name are resolved with
    /// `{tax}` filled from the REPORT's regime — the composition names keys, and the view fills
    /// the token through `ReportPresenter.lineLabelText`.
    static func compose(_ state: ReportPageState, uiLanguage: String) -> Page {
        switch state {
        case .notRequested:
            return Page(headerKeys: headerKeys(showsCurrency: false, unusualCurrency: false),
                        notRequestedKeys: ["report.notRequested.title",
                                           "report.notRequested.message",
                                           "report.action.build"],
                        blocked: nil, failedKeys: nil, body: nil,
                        footerKeys: [])

        case .failed:
            return Page(headerKeys: headerKeys(showsCurrency: false, unusualCurrency: false),
                        notRequestedKeys: nil, blocked: nil,
                        failedKeys: ["report.error.title", "report.error.message",
                                     "report.action.retry"],
                        body: nil,
                        footerKeys: [reportDisclaimerKey])

        case .blocked(_, let blocker):
            return Page(headerKeys: headerKeys(showsCurrency: false, unusualCurrency: false),
                        notRequestedKeys: nil, blocked: blockedBlock(for: blocker),
                        failedKeys: nil, body: nil,
                        footerKeys: [reportDisclaimerKey])

        case .report(let report):
            let unusual = ReportFormat.currencyShape(report.currency) == .other
            return Page(headerKeys: headerKeys(showsCurrency: true, unusualCurrency: unusual),
                        notRequestedKeys: nil, blocked: nil, failedKeys: nil,
                        body: body(for: report),
                        footerKeys: [reportDisclaimerKey])
        }
    }

    // MARK: - Header

    private static func headerKeys(showsCurrency: Bool, unusualCurrency: Bool) -> [String] {
        var keys = ["report.page.title", "report.year.label", "report.year.invalid"]
        guard showsCurrency else { return keys }
        keys += ["report.period.caption", "report.currency.caption", "report.currency.note",
                 "report.estimate.badge"]
        // Only a code that is not three letters gets the extra line. A three-letter code is
        // shown as it stands, with no comment on it — the app is in no position to say whether
        // it is a currency anyone recognises.
        if unusualCurrency { keys.append("report.currency.formatNote") }
        return keys
    }

    // MARK: - A refusal

    private static func blockedBlock(for blocker: ReportBlocker) -> BlockedBlock {
        let copy = ReportPresenter.copy(for: blocker)
        var facts: [String] = []
        switch blocker {
        case .accountingLocaleInvalid:
            facts = ["report.storedText.label"]
        case .currencyInvalid:
            facts = ["report.storedText.label", "report.blocker.periodCurrencies",
                     "report.blocker.regimeDefaultCurrency"]
        case .currencyNotConfigured:
            facts = ["report.blocker.periodCurrencies", "report.blocker.regimeDefaultCurrency"]
        case .currencyMismatch:
            facts = ["report.blocker.storedCurrency", "report.blocker.periodCurrencies"]
        case .multipleCurrenciesInPeriod:
            facts = ["report.blocker.periodCurrencies"]
        case .accountingLocaleNotConfigured, .legacySourceUnavailable:
            // Nothing to point at. The legacy refusal in particular has no fact to offer: the
            // whole reason it refuses is that it cannot see what is in the older tables.
            facts = []
        }
        let actions: [String] = copy.action == .openSettings
            ? ["report.action.openSettings", "report.action.openSettings.hint"] : []
        return BlockedBlock(titleKey: copy.titleKey, bodyKey: copy.bodyKey,
                            factKeys: facts, action: copy.action, actionKeys: actions)
    }

    // MARK: - A report

    private static func body(for report: PresentedReport) -> ReportBody {
        var sections: [SectionBlock] = []
        for section in report.sections {
            guard let block = sectionBlock(locale: report.locale, section: section) else { continue }
            sections.append(block)
        }
        return ReportBody(
            sections: sections,
            undeclaredTaxInclusive: undeclaredBlock(for: report),
            parameters: parameterBlock(for: report),
            cashflowKeys: cashflowKeys(for: report.cashflow),
            monthlyKeys: report.monthlyBreakdown.isEmpty ? [] :
                ["report.monthly.title", "report.monthly.month", "report.monthly.revenue",
                 "report.monthly.cost", "report.monthly.profit"],
            noteKeys: report.sections.flatMap(\.notes).isEmpty ? [] :
                ["report.notes.title"] + report.sections.flatMap(\.notes).map(ReportPresenter.key(for:)),
            warningKeys: report.warnings.isEmpty ? [] :
                ["report.warnings.title"] + report.warnings.map(ReportPresenter.key(for:)),
            footerKeys: [reportDisclaimerKey])
    }

    /// `nil` for a section the model says must not be drawn — a withheld section produces no
    /// block, so the view has nothing to render rather than a rule to remember.
    private static func sectionBlock(locale: String, section: PresentedSection) -> SectionBlock? {
        let id = ReportPresenter.SectionID(locale, section.reportTypeID)
        guard case .key(let titleKey) = ReportPresenter.sectionTitle(locale: locale,
                                                                    reportTypeID: section.reportTypeID)
        else { return nil }
        var notes: [String] = []
        switch ReportPresenter.rendering(for: section.availability) {
        case .withheld:
            return nil
        case .withMissingLines(let noteKey):
            notes.append(noteKey)
        case .full:
            break
        }
        if id == ReportPresenter.SectionID("CN", "vat-summary") {
            notes.append(ReportPresenter.chinaTurnoverTaxAliasNoteKey)
        }
        var disclaimers: [String] = []
        if turnoverTaxReportTypeIDs.contains(id) { disclaimers.append(taxDisclaimerKey) }
        if id == selfEmploymentSectionID { disclaimers.append(usTaxDisclaimerKey) }
        let lines: [String] = section.lines.compactMap {
            guard case .key(let key) = ReportPresenter.lineLabel(for: $0.id) else { return nil }
            return key
        }
        return SectionBlock(reportTypeID: section.reportTypeID, titleKey: titleKey,
                            lineKeys: lines, noteKeys: notes, disclaimerKeys: disclaimers)
    }

    private static func undeclaredBlock(for report: PresentedReport) -> SectionBlock? {
        guard report.undeclaredTaxInclusiveSummary != nil,
              let titleKey = ReportPresenter.undeclaredTaxInclusiveTitle(locale: report.locale)
        else { return nil }
        let lines = ["purchaseTotal", "salesTotal", "difference"].compactMap { id -> String? in
            guard case .key(let key) = ReportPresenter.lineLabel(for: id) else { return nil }
            return key
        }
        return SectionBlock(reportTypeID: "undeclared-tax-inclusive", titleKey: titleKey,
                            lineKeys: lines, noteKeys: [], disclaimerKeys: [])
    }

    private static func parameterBlock(for report: PresentedReport) -> ParameterBlock {
        let rows = report.parameters.map { parameter -> [String] in
            var row = [ReportPresenter.nameKey(for: parameter.key),
                       ReportPresenter.storedKey(for: parameter.stored)]
            row += effectKeys(for: parameter.nativeEffect)
            row.append(ReportPresenter.consumptionKey(for: parameter.consumption))
            return row
        }
        return ParameterBlock(titleKey: "report.params.title",
                              axisKeys: ["report.params.axis.stored", "report.params.axis.effect",
                                         "report.params.axis.consumption"],
                              rows: rows,
                              disclaimerKeys: [ratesDisclaimerKey])
    }

    /// An applied value also discloses where it came from; a refusal and a non-finite value have
    /// no origin to name.
    private static func effectKeys(for effect: ParameterEffect) -> [String] {
        switch effect {
        case .appliedValue(_, let origin):
            return [ReportPresenter.effectKey(for: effect), ReportPresenter.originKey(for: origin)]
        case .appliedNonFinite, .refused:
            return [ReportPresenter.effectKey(for: effect)]
        }
    }

    private static func cashflowKeys(for cashflow: PresentedCashflow) -> [String] {
        var keys = ["report.cashflow.title", "report.cashflow.operating.title",
                    "report.cashflow.investing", "report.cashflow.financing",
                    "report.cashflow.beginningCash", "report.cashflow.endingCash",
                    "report.cashflow.basisNote", "report.cashflow.vsProfitNote"]
        if case .computed = cashflow.operating {
            keys += ["report.cashflow.inflow", "report.cashflow.outflow", "report.cashflow.net"]
        }
        for section in [cashflow.investing, cashflow.financing,
                        cashflow.beginningCash, cashflow.endingCash] {
            if case .copy(let key) = ReportPresenter.rendering(for: section),
               !keys.contains(key) { keys.append(key) }
        }
        return keys
    }
}
