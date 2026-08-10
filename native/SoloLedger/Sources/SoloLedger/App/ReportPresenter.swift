import Foundation
import SoloLedgerCore

/// Every mapping from something `ReportBuilder` can emit to the localization key that
/// describes it. No SwiftUI, no formatting, no database, no clock.
///
/// ## Two kinds of enforcement, because there are two kinds of input
///
/// Most of what a report carries is a Swift `enum`, and the mappings for those are written as
/// `switch` statements **without a `default:`** — adding a case to the Core makes this file
/// fail to compile, which is the strongest guarantee available.
///
/// Line ids and report-type ids are `String`, so the compiler cannot help. Their closed sets
/// are therefore written out literally below and pinned by a test that DERIVES the same sets
/// by driving `ReportBuilder.build` over one real ledger per accounting regime. A line the
/// engines start emitting, or one they stop emitting, breaks that test; a hand-maintained
/// list on its own would not have noticed either.
///
/// ## Why the lookups return an enum rather than an Optional
///
/// `String?` invites `if let`, and the branch people write for the `nil` case is the one that
/// skips the row — silently dropping a figure the engines computed. ``LineLabel/unmapped(id:)``
/// and ``SectionTitle/unmapped(locale:reportTypeID:)`` exist so that outcome has to be
/// handled deliberately. They are unreachable for any report the builder can produce today,
/// and the closed-set tests are what say so.
enum ReportPresenter {

    /// Every key this file can produce starts here. Asserted, so a stray key from some other
    /// namespace cannot slip into the report page's copy.
    static let keyPrefix = "report."

    // MARK: - Line labels (63 ids, keys SHARED across accounting regimes)

    enum LineLabel: Equatable {
        case key(String)
        /// The builder emitted a line id this layer does not know. Unreachable today.
        case unmapped(id: String)
    }

    /// The 63 line ids `ReportBuilder` can emit, across all six accounting regimes.
    ///
    /// Kept as ONE set, not one per regime, because the label copy is shared: the regime
    /// context is carried by the section title above the line. The two ids that look like
    /// duplicates are not — see ``taxInterpolatedLineIDs`` for the turnover-tax group, and
    /// note that `revenue` (EU) and `salesRevenue` (everyone else) are deliberately DISTINCT.
    /// That asymmetry is the engines' own naming (`eu.js` calls it `revenue`) and tidying it
    /// away here would hide a fact about the source.
    static let knownLineIDs: Set<String> = [
        // — profit-and-loss family
        "salesRevenue", "revenue", "costOfSales", "costOfGoodsSold", "operatingExpenses",
        "grossProfit", "grossMargin", "shippingFee", "adminExpense", "operatingProfit",
        "taxSurcharge", "incomeTax", "netProfit", "netMargin",
        // — China's turnover-tax block
        "cumulativeInput", "cumulativeOutput", "certifiedInput", "invoicedOutput",
        "estimatedPayable",
        // — Japan / Taiwan turnover-tax block
        "collected", "paid", "payable",
        // — EU / Korea turnover-tax block
        "outputVAT", "inputVAT", "vatPayable",
        // — the tax-inclusive block (a declared section on China, an undeclared block on the
        //   other four VAT regimes)
        "purchaseTotal", "salesTotal", "difference",
        // — US Schedule C, the 25 contract lines
        "line1_grossReceipts", "line2_returns", "line6_otherIncome", "line7_grossIncome",
        "line8_advertising", "line9_car", "line10_commissions", "line11_contract",
        "line13_depreciation", "line15_insurance", "line16b_interest", "line17_legal",
        "line18_office", "line20_rent", "line21_repairs", "line22_supplies", "line23_taxes",
        "line24a_travel", "line24b_meals", "line25_utilities", "line26_wages",
        "line27a_other", "line30_homeOffice", "line28_totalExpenses", "line31_netProfit",
        // — US self-employment tax and the quarterly estimate it feeds
        "netEarnings", "seEarnings", "socialSecurityTax", "medicareTax", "additionalMedicare",
        "totalSETax", "annualIncomeTax", "annualSETax", "totalAnnual", "quarterlyPayment",
    ]

    /// Line ids whose copy carries a `{tax}` token.
    ///
    /// Five regimes name the same three quantities after their OWN turnover tax — Japan's
    /// 消費税, Taiwan's 營業稅, the EU's VAT — so one shared label with the tax name filled in
    /// says the right thing everywhere without 30 separate keys. The name comes from
    /// ``turnoverTaxName(reportLocale:uiLanguage:)``, i.e. from the REPORT's regime.
    static let taxInterpolatedLineIDs: Set<String> = [
        "collected", "paid", "payable", "outputVAT", "inputVAT", "vatPayable",
    ]

    static func lineLabel(for id: String) -> LineLabel {
        knownLineIDs.contains(id) ? .key("\(keyPrefix)line.\(id)") : .unmapped(id: id)
    }

    // MARK: - Section titles (13 (accounting locale, report type) pairs)

    /// A declared report type, identified the way the builder identifies it.
    struct SectionID: Hashable {
        let locale: String
        let reportTypeID: String

        init(_ locale: String, _ reportTypeID: String) {
            self.locale = locale
            self.reportTypeID = reportTypeID
        }
    }

    enum SectionTitle: Equatable {
        case key(String)
        case unmapped(locale: String, reportTypeID: String)
    }

    /// The 13 declared pairs, each with its own key.
    ///
    /// Per-pair rather than per-id because the same id means different documents: China's
    /// `vat-summary` and Korea's `vat-summary` are different taxes, and Japan's
    /// `income-statement` is not China's. A shared key would force one wording to serve both.
    static let sectionTitleKeys: [SectionID: String] = [
        SectionID("CN", "income-statement"): "\(keyPrefix)section.CN.incomeStatement",
        SectionID("CN", "vat-summary"):      "\(keyPrefix)section.CN.vatSummary",
        SectionID("CN", "tax-inclusive"):    "\(keyPrefix)section.CN.taxInclusive",
        SectionID("US", "schedule-c"):       "\(keyPrefix)section.US.scheduleC",
        SectionID("US", "se-tax"):           "\(keyPrefix)section.US.seTax",
        SectionID("JP", "income-statement"): "\(keyPrefix)section.JP.incomeStatement",
        SectionID("JP", "consumption-tax"):  "\(keyPrefix)section.JP.consumptionTax",
        SectionID("EU", "profit-loss"):      "\(keyPrefix)section.EU.profitLoss",
        SectionID("EU", "vat-return"):       "\(keyPrefix)section.EU.vatReturn",
        SectionID("KR", "income-statement"): "\(keyPrefix)section.KR.incomeStatement",
        SectionID("KR", "vat-summary"):      "\(keyPrefix)section.KR.vatSummary",
        SectionID("TW", "income-statement"): "\(keyPrefix)section.TW.incomeStatement",
        SectionID("TW", "business-tax"):     "\(keyPrefix)section.TW.businessTax",
    ]

    static func sectionTitle(locale: String, reportTypeID: String) -> SectionTitle {
        if let key = sectionTitleKeys[SectionID(locale, reportTypeID)] { return .key(key) }
        return .unmapped(locale: locale, reportTypeID: reportTypeID)
    }

    /// The four regimes that EMIT a tax-inclusive block without declaring a report type for
    /// it, so it arrives as `PresentedReport.undeclaredTaxInclusiveSummary` instead of a
    /// section and needs its own heading. China declares the id; the US engine has no block.
    static let undeclaredTaxInclusiveTitleKeys: [String: String] = [
        "JP": "\(keyPrefix)block.JP.taxInclusive",
        "EU": "\(keyPrefix)block.EU.taxInclusive",
        "KR": "\(keyPrefix)block.KR.taxInclusive",
        "TW": "\(keyPrefix)block.TW.taxInclusive",
    ]

    static func undeclaredTaxInclusiveTitle(locale: String) -> String? {
        undeclaredTaxInclusiveTitleKeys[locale]
    }

    /// The China-only note that two of its five turnover-tax lines repeat two others.
    ///
    /// `cn.js generate` computes `certifiedInput` from the SAME expression as `cumulativeInput`
    /// and `invoicedOutput` from the same one as `cumulativeOutput`, so those pairs are equal
    /// by construction. All five are shown, because dropping a line the model carries would
    /// be the view deciding what the report says — and this note is how the repetition is
    /// explained instead of left to look like an error. It states the fact and claims no
    /// accounting difference between them.
    static let chinaTurnoverTaxAliasNoteKey = "\(keyPrefix)section.CN.vatSummary.aliasNote"

    // MARK: - Blockers

    /// What a blocked page offers the user. Two values, and the smaller one is the point.
    enum BlockerAction: Equatable {
        /// No action. Not an oversight: for the four currency blockers this app has no
        /// currency editor at all (Settings shows the code read-only), and for
        /// `legacySourceUnavailable` there is nothing any button could do, because this app
        /// does not read the legacy tables by design. A "fix this" control that leads
        /// nowhere is worse than no control.
        case none
        /// Opens the Settings scene. Offered ONLY where Settings really does contain the
        /// control in question — the accounting-profile picker. It is deliberately not
        /// called "repair": selecting the profile already shown does not write anything, so
        /// this is a route to the right screen and not a promise about the outcome.
        case openSettings
    }

    struct BlockerCopy: Equatable {
        let titleKey: String
        let bodyKey: String
        let action: BlockerAction
    }

    static func copy(for blocker: ReportBlocker) -> BlockerCopy {
        switch blocker {
        case .accountingLocaleNotConfigured:
            return copy("accountingLocaleNotConfigured", action: .openSettings)
        case .accountingLocaleInvalid:
            return copy("accountingLocaleInvalid", action: .openSettings)
        case .currencyNotConfigured:
            return copy("currencyNotConfigured", action: .none)
        case .currencyInvalid:
            return copy("currencyInvalid", action: .none)
        case .legacySourceUnavailable:
            return copy("legacySourceUnavailable", action: .none)
        case .currencyMismatch:
            return copy("currencyMismatch", action: .none)
        case .multipleCurrenciesInPeriod:
            return copy("multipleCurrenciesInPeriod", action: .none)
        }
    }

    private static func copy(_ name: String, action: BlockerAction) -> BlockerCopy {
        BlockerCopy(titleKey: "\(keyPrefix)blocker.\(name).title",
                    bodyKey: "\(keyPrefix)blocker.\(name).body",
                    action: action)
    }

    /// The seven blockers, for the closed-set test. `ReportBlocker` is not `CaseIterable`
    /// (three of its cases carry payloads), so representatives are listed here; the test
    /// asserts the seven produce seven distinct key pairs.
    static let allBlockerRepresentatives: [ReportBlocker] = [
        .accountingLocaleNotConfigured,
        .accountingLocaleInvalid(storedText: "\"XX\""),
        .currencyNotConfigured(periodCurrencies: [], regimeDefault: "CNY"),
        .currencyInvalid(storedText: "\"\"", periodCurrencies: [], regimeDefault: "CNY"),
        .legacySourceUnavailable,
        .currencyMismatch(storedCurrency: "CNY", periodCurrency: "USD"),
        .multipleCurrenciesInPeriod(codes: ["CNY", "USD"]),
    ]

    // MARK: - One field

    /// What a view must draw for one figure. Four cases, mirroring the model's four, with the
    /// copy already chosen — so no branch can end up rendering `0` for a refusal.
    enum FieldRendering: Equatable {
        /// A finite number. Format with `ReportFormat.money` / `.percent` per the line's unit.
        case amount(Double)
        /// The engine produced a non-finite value; never render a number.
        case corrupted(key: String)
        /// No rate row and no regime fallback: nothing was computed.
        case notConfigured(key: String, parameterNameKey: String)
        /// The rate row exists and is not usable. `storedText` is verbatim and must go
        /// through `ReportFormat.safePreview` before it reaches a `Text`.
        case needsRepair(key: String, parameterNameKey: String, storedText: String)
    }

    static func rendering(for field: ReportFieldPresentation) -> FieldRendering {
        switch field {
        case .amount(let value):
            return .amount(value)
        case .corrupted:
            return .corrupted(key: "\(keyPrefix)field.corrupted")
        case .notConfigured(let parameter):
            return .notConfigured(key: "\(keyPrefix)field.notConfigured",
                                  parameterNameKey: nameKey(for: parameter))
        case .needsRepair(let parameter, let storedText):
            return .needsRepair(key: "\(keyPrefix)field.needsRepair",
                                parameterNameKey: nameKey(for: parameter),
                                storedText: storedText)
        }
    }

    // MARK: - One section's availability

    enum SectionRendering: Equatable {
        case full
        /// Some lines are mirrored and some are not; the missing ones must be marked.
        /// **No producer today** — every declared pair is `renderInFull` after R7. The case
        /// and its copy exist so a future partially-mirrored report type finds them ready;
        /// exercising it in a test is a check of THIS mapping, not evidence that a real
        /// ledger can reach it.
        case withMissingLines(noteKey: String)
        /// Draw nothing. The builder already emptied `lines`, so this is belt and braces.
        case withheld
    }

    static func rendering(for availability: ReportSectionPresentation) -> SectionRendering {
        switch availability {
        case .renderInFull:           return .full
        case .renderWithMissingLines: return .withMissingLines(noteKey: "\(keyPrefix)section.missingLines")
        case .withhold:               return .withheld
        }
    }

    // MARK: - Parameter disclosure

    static func storedKey(for stored: StoredSettingState) -> String {
        switch stored {
        case .absent:      return "\(keyPrefix)param.stored.absent"
        case .usable:      return "\(keyPrefix)param.stored.usable"
        case .needsRepair: return "\(keyPrefix)param.stored.needsRepair"
        }
    }

    static func effectKey(for effect: ParameterEffect) -> String {
        switch effect {
        case .appliedValue:    return "\(keyPrefix)param.effect.applied"
        case .appliedNonFinite: return "\(keyPrefix)param.effect.nonFinite"
        case .refused:         return "\(keyPrefix)param.effect.refused"
        }
    }

    /// The three origins get three DIFFERENT keys, and `regimeDefault` is why the axis exists
    /// at all: China's engine substitutes 25% / 12% for a missing rate row, the user never
    /// chose it, and CLAUDE.md forbids applying an accounting policy without saying so. Its
    /// copy carries `{percent}` so the disclosure can name the number that was used.
    /// `dispatcherFallback` is a real zero, not a policy — collapsing the two would erase the
    /// distinction the Core went out of its way to preserve.
    static func originKey(for origin: EffectOrigin) -> String {
        switch origin {
        case .storedValue:        return "\(keyPrefix)param.origin.storedValue"
        case .regimeDefault:      return "\(keyPrefix)param.origin.regimeDefault"
        case .dispatcherFallback: return "\(keyPrefix)param.origin.dispatcherFallback"
        }
    }

    /// `storedButUnread` must read as "nothing here reads this", NOT as "you have not
    /// configured it": `surcharge_rate` outside China, `vat_rate` everywhere, and
    /// `admin_expense_annual` under the US are all loaded by the dispatcher and read by the
    /// engine that regime routes to in none of those cases, so prompting for a value would be
    /// asking the user to change a number that changes nothing.
    static func consumptionKey(for consumption: ParameterConsumption) -> String {
        switch consumption {
        case .consumed:        return "\(keyPrefix)param.consumption.consumed"
        case .storedButUnread: return "\(keyPrefix)param.consumption.storedButUnread"
        }
    }

    /// The four settings keys the dispatcher loads. `vatRate`'s copy carries `{tax}` because
    /// the turnover tax is not called the same thing in six regimes.
    static func nameKey(for key: ReportParameterKey) -> String {
        switch key {
        case .vatRate:            return "\(keyPrefix)param.name.vatRate"
        case .surchargeRate:      return "\(keyPrefix)param.name.surchargeRate"
        case .incomeTaxRate:      return "\(keyPrefix)param.name.incomeTaxRate"
        case .adminExpenseAnnual: return "\(keyPrefix)param.name.adminExpenseAnnual"
        }
    }

    /// The two rates an estimate can refuse over. Shares the `param.name.*` namespace with
    /// the settings keys above, so one concept has one string.
    static func nameKey(for parameter: ReportRateParameter) -> String {
        switch parameter {
        case .incomeTaxRate: return "\(keyPrefix)param.name.incomeTaxRate"
        case .surchargeRate: return "\(keyPrefix)param.name.surchargeRate"
        }
    }

    // MARK: - Cash flow

    enum CashflowRendering: Equatable {
        /// Real figures; format the three amounts.
        case computed
        /// There are no cash accounts, no fixed-asset register, no liabilities and no opening
        /// balances in this data model, so these sections can never carry a number. The copy
        /// says that, rather than showing a zero that would read as "nothing happened".
        case copy(key: String)
    }

    static func rendering(for section: PresentedCashflowSection) -> CashflowRendering {
        switch section {
        case .computed:                       return .computed
        case .notDerivableFromThisDataModel:  return .copy(key: "\(keyPrefix)cashflow.notDerivable")
        }
    }

    // MARK: - Notes and warnings

    static func key(for note: PresentedNote) -> String {
        switch note {
        case .estimatedTaxDueDates:        return "\(keyPrefix)note.estimatedTaxDueDates"
        case .selfEmploymentParameterYear: return "\(keyPrefix)note.selfEmploymentParameterYear"
        }
    }

    /// The engine builds its first warning as an English string with `toLocaleString()`,
    /// which is English-only, ICU-dependent, and drops a trailing zero. The amount therefore
    /// arrives classified and the wording is supplied here, with `{amount}` filled by
    /// `ReportFormat.money` so it matches every other figure on the page.
    static func key(for warning: PresentedWarning) -> String {
        switch warning {
        case .estimatedQuarterlyPayment: return "\(keyPrefix)warning.estimatedQuarterlyPayment"
        case .mealsLimitedToFiftyPercent: return "\(keyPrefix)warning.mealsLimitedToFiftyPercent"
        }
    }

    // MARK: - The turnover tax's own name

    /// The regime's name for its turnover tax, in the UI language.
    ///
    /// The REGIME comes from the report (`PresentedReport.locale`) and the LANGUAGE from the
    /// UI. That split is deliberate: which tax it is, is a fact about the report and must not
    /// be re-derived from the current settings, which the user may have changed since; what
    /// to call it, is a fact about the reader.
    static func turnoverTaxName(reportLocale: String, uiLanguage: String) -> String? {
        guard let locale = AccountingLocale(rawValue: reportLocale) else { return nil }
        return AccountingProfile.profile(for: locale).taxName(language: uiLanguage)
    }

    // MARK: - A line's finished label

    /// One line's label, ready to draw — or a stated reason there is none.
    ///
    /// Three cases rather than a `String?` for the reason ``LineLabel`` has two: the branch a
    /// caller writes for `nil` is the one that skips the row, and a report line that silently
    /// disappears is worse than one that says it could not be named. Both refusals are
    /// unreachable for a report `ReportBuilder` can produce, and the tests are what say so.
    enum LineLabelText: Equatable {
        case text(String)
        /// The builder emitted a line id this layer does not know.
        case unmapped(id: String)
        /// The copy carries `{tax}` and the report's accounting regime is not one of the six,
        /// so there is no tax name to put there. Deliberately NOT "substitute something
        /// plausible": a label reading `采购` with the tax silently dropped looks finished and
        /// is wrong, which is the failure this whole layer is built to avoid.
        case unresolvedTaxName(id: String)
    }

    /// Resolve one line's label: look up its key, then fill `{tax}` when the key declares it.
    ///
    /// `localized` is the app's own lookup (`AppModel.t`), passed in rather than reached for,
    /// so this stays a pure function over its inputs and a test can drive all six languages
    /// without a running app.
    ///
    /// The regime comes from the REPORT and the language from the UI — the split L8 fixes.
    /// Which tax it is, is a fact about the report and must not be re-derived from the current
    /// settings, which the user may have changed since the report was built; what to call it,
    /// is a fact about the reader.
    static func lineLabelText(for id: String, reportLocale: String, uiLanguage: String,
                              localized: (String) -> String) -> LineLabelText {
        guard case .key(let key) = lineLabel(for: id) else { return .unmapped(id: id) }
        let copy = localized(key)
        guard taxInterpolatedLineIDs.contains(id) else { return .text(copy) }
        guard let tax = turnoverTaxName(reportLocale: reportLocale, uiLanguage: uiLanguage),
              !tax.isEmpty else { return .unresolvedTaxName(id: id) }
        return .text(copy.replacingOccurrences(of: taxToken, with: tax))
    }

    /// The one token this layer substitutes.
    ///
    /// ``requiredPlaceholders`` states the same token independently — the copy contract and
    /// the substitution are two different claims and are written separately on purpose. A test
    /// asserts they agree, so drift between them fails rather than silently leaving `{tax}` on
    /// screen.
    static let taxToken = "{tax}"

    // MARK: - Placeholder contract

    /// The `{token}` set every listed key's copy MUST carry, in all six languages.
    ///
    /// Recorded here, in the PR that decides which keys exist, so the copy PRs that follow
    /// have something to be checked against instead of a convention. Keys absent from this
    /// table must carry no placeholder at all.
    static let requiredPlaceholders: [String: Set<String>] = {
        var table: [String: Set<String>] = [
            "\(keyPrefix)param.name.vatRate":            ["{tax}"],
            "\(keyPrefix)param.origin.regimeDefault":    ["{percent}"],
            "\(keyPrefix)warning.estimatedQuarterlyPayment": ["{amount}"],
            "\(keyPrefix)note.estimatedTaxDueDates":     ["{dates}"],
            "\(keyPrefix)note.selfEmploymentParameterYear": ["{year}"],
        ]
        for id in taxInterpolatedLineIDs { table["\(keyPrefix)line.\(id)"] = ["{tax}"] }
        return table
    }()

    /// Every key this file can produce, for the copy PRs and the end-to-end resolution test.
    static func allEmittableKeys() -> Set<String> {
        var keys = Set<String>()
        for id in knownLineIDs { keys.insert("\(keyPrefix)line.\(id)") }
        keys.formUnion(sectionTitleKeys.values)
        keys.formUnion(undeclaredTaxInclusiveTitleKeys.values)
        keys.insert(chinaTurnoverTaxAliasNoteKey)
        for blocker in allBlockerRepresentatives {
            let c = copy(for: blocker)
            keys.insert(c.titleKey)
            keys.insert(c.bodyKey)
        }
        keys.insert("\(keyPrefix)field.corrupted")
        keys.insert("\(keyPrefix)field.notConfigured")
        keys.insert("\(keyPrefix)field.needsRepair")
        keys.insert("\(keyPrefix)section.missingLines")
        for state in [StoredSettingState.absent, .usable(1), .needsRepair(storedText: "x")] {
            keys.insert(storedKey(for: state))
        }
        for effect in [ParameterEffect.appliedValue(1, origin: .storedValue), .appliedNonFinite,
                       .refused(.incomeTaxRate)] {
            keys.insert(effectKey(for: effect))
        }
        for origin in [EffectOrigin.storedValue, .regimeDefault, .dispatcherFallback] {
            keys.insert(originKey(for: origin))
        }
        for consumption in [ParameterConsumption.consumed, .storedButUnread] {
            keys.insert(consumptionKey(for: consumption))
        }
        for key in ReportParameterKey.allCases { keys.insert(nameKey(for: key)) }
        for parameter in [ReportRateParameter.incomeTaxRate, .surchargeRate] {
            keys.insert(nameKey(for: parameter))
        }
        keys.insert("\(keyPrefix)cashflow.notDerivable")
        for note in [PresentedNote.estimatedTaxDueDates([]), .selfEmploymentParameterYear(2025)] {
            keys.insert(key(for: note))
        }
        for warning in [PresentedWarning.estimatedQuarterlyPayment(amount: .amount(0)),
                        .mealsLimitedToFiftyPercent] {
            keys.insert(key(for: warning))
        }
        return keys
    }
}
