import Foundation

/// The ONE database→report door the App may use.
///
/// Everything the report layer can say is said through ``build(_:period:)``: the regime,
/// the period, the currency, all four parameter states, every section already paired with
/// its availability, and every number already classified. Nothing downstream re-reads
/// `settings`, and nothing downstream can obtain an unclassified value, because
/// ``PresentedReport`` does not contain one.
///
/// A successful result carries no "source": it is by construction built from `transactions`,
/// because a period the dispatcher would route to the legacy tables stops at
/// ``ReportBlocker/legacySourceUnavailable`` before any of this runs.
///
/// ## One snapshot
///
/// Every read happens inside a single `readSnapshot` (a DEFERRED read transaction). A report
/// asks the ledger eight questions and they must describe ONE ledger; running them on the
/// main actor orders this process's calls and says nothing about the Electron app writing
/// between two of them.
///
/// ## What is deliberately absent
///
/// **No `locale` parameter on the public entry point.** The accounting regime is a persisted
/// user choice; letting a view pass a different one would make the safe façade the way
/// around it. The internal overload exists for golden/parity tests, which must drive all six
/// regimes against one fixture.
public enum ReportBuilder {

    /// Build the report for the ledger's own accounting regime.
    public static func build(_ db: SQLiteDatabase,
                             period: ReportPeriod) throws -> ReportOutcome {
        try build(db, explicitLocale: nil, period: period)
    }

    /// Tests only — drives a chosen regime against a fixture. `internal`, so the App target
    /// cannot reach it and cannot bypass the ledger's stored regime.
    static func build(_ db: SQLiteDatabase, locale: String,
                      period: ReportPeriod) throws -> ReportOutcome {
        try build(db, explicitLocale: locale, period: period)
    }

    private static func build(_ db: SQLiteDatabase, explicitLocale: String?,
                              period: ReportPeriod) throws -> ReportOutcome {
        try db.readSnapshot {
            // ── 1. The regime ────────────────────────────────────────────────────────
            let locale: String
            if let explicitLocale {
                locale = explicitLocale
            } else {
                switch resolveAccountingLocale(db) {
                case .resolved(let l): locale = l
                case .blocked(let b):  return .blocked(b)
                }
            }
            let regimeDefaultCurrency = AccountingLocale(rawValue: locale)?.defaultCurrency ?? ""

            // ── 2. The source — and a hard stop when it is not `transactions` ────────
            // This is a FAIL-CLOSED gate, and it comes before everything else on purpose.
            // Continuing here would hand the engines empty arrays and produce a
            // complete-looking statement of zeros for a period whose money may be sitting in
            // the legacy tables this app does not read. See `legacySourceUnavailable`.
            let hasTable = try ReportFetch.hasTransactionsTable(db)
            let periodTxnCount = hasTable
                ? try ReportFetch.periodTransactionCount(db, from: period.from, to: period.to) : 0
            guard selectReportSource(hasTransactionsTable: hasTable,
                                     periodTxnCount: periodTxnCount) == .transactions else {
                return .blocked(.legacySourceUnavailable)
            }

            // ── 3. The currency ──────────────────────────────────────────────────────
            // Reached only on the transactions path, so the set below always describes rows
            // that really do feed this report.
            let periodCurrencies = try periodCurrencySet(db, period: period)
            let currency: String
            switch resolveCurrency(db, periodCurrencies: periodCurrencies,
                                   regimeDefault: regimeDefaultCurrency) {
            case .resolved(let c): currency = c
            case .blocked(let b):  return .blocked(b)
            }

            // ── 4. The engines' input, read once ─────────────────────────────────────
            let incomeRows = try ReportFetch.rows(db, type: "income",
                                                  from: period.from, to: period.to)
            let expenseRows = try ReportFetch.rows(db, type: "expense",
                                                   from: period.from, to: period.to)
            // `index.js locale` wraps the categories read in a swallowing catch because the
            // table may not exist on an early-schema ledger.
            let categories = (try? ReportFetch.categories(db, locale: locale)) ?? []

            let incomeTaxRate = ReportSettings.incomeTaxRate(db, locale: locale)
            let surchargeRate = ReportSettings.surchargeRate(db, locale: locale)
            let adminExpense = ReportSettings.number(db, "admin_expense_annual", fallback: 0)

            let ctx = ReportContext(
                incomeRows: incomeRows, expenseRows: expenseRows, categories: categories,
                adminExpense: adminExpense,
                incomeTaxRate: incomeTaxRate, surchargeRate: surchargeRate,
                currency: currency, year: period.year, from: period.from, to: period.to)

            // ── 5. Everything below is pure ──────────────────────────────────────────
            let cashflowRows = try ReportFetch.cashflowRows(db, from: period.from, to: period.to)

            return .report(PresentedReport(
                locale: locale, period: period, currency: currency,
                parameters: parameters(db, locale: locale, ctx: ctx),
                sections: sections(locale: locale, ctx: ctx),
                undeclaredTaxInclusiveSummary: undeclaredTaxInclusive(locale: locale, ctx: ctx),
                monthlyBreakdown: months(locale: locale, ctx: ctx),
                cashflow: cashflow(rows: cashflowRows),
                warnings: warnings(locale: locale, ctx: ctx)))
        }
    }

    // MARK: - The regime

    private enum Resolution<T> { case resolved(T); case blocked(ReportBlocker) }

    /// The stored regime, classified from its RAW row.
    ///
    /// Deliberately not `ReportSettings.string(db, "accounting_locale", fallback: "CN")`.
    /// That fallback mirrors `index.js:27` faithfully and silently runs Chinese accounting
    /// policy for a ledger that never chose it — and it does so for a BOM-prefixed row too,
    /// where `SettingsStore` reads `US` and the engines would run `CN`. Measured, and
    /// pinned by `testBOMPrefixedAccountingLocaleIsBlockedAsInvalidAndNeverSilentlyRunsChina`.
    private static func resolveAccountingLocale(_ db: SQLiteDatabase) -> Resolution<String> {
        guard ReportSettings.rowExists(db, "accounting_locale") else {
            return .blocked(.accountingLocaleNotConfigured)
        }
        let raw = ReportSettings.rawValue(db, "accounting_locale") ?? ""
        guard let locale = ReportSettings.recognizedAccountingLocale(fromStoredText: raw) else {
            return .blocked(.accountingLocaleInvalid(storedText: raw))
        }
        return .resolved(locale.rawValue)
    }

    // MARK: - The currency

    /// The currencies the period's rows are actually denominated in.
    ///
    /// The two `WHERE` clauses are the two real fetch paths, WORD FOR WORD: the P&L window
    /// (`ReportFetch.rowSQL`) and the realized-cash window (`ReportFetch.cashflowSQL`,
    /// `payment_status IN ('paid','partial')` included). A currency set that did not match
    /// the rows actually taken would gate on one question and compute on another — an
    /// `unpaid` row whose `payment_date` lands in the period must not count.
    ///
    /// Only ever called on the transactions path: a legacy period has already returned
    /// ``ReportBlocker/legacySourceUnavailable``, so this never runs over a table nothing
    /// will be taken from.
    private static func periodCurrencySet(_ db: SQLiteDatabase,
                                          period: ReportPeriod) throws -> [String] {
        let sql = """
            SELECT DISTINCT currency FROM transactions
             WHERE type IN ('income','expense') AND date >= ? AND date <= ?
            UNION
            SELECT DISTINCT currency FROM transactions
             WHERE payment_status IN ('paid','partial')
               AND COALESCE(payment_date, date) >= ? AND COALESCE(payment_date, date) <= ?
            """
        let rows = try db.query(sql, [.text(period.from), .text(period.to),
                                      .text(period.from), .text(period.to)])
        return rows.compactMap { $0.string("currency") }.sorted()
    }

    private static func resolveCurrency(_ db: SQLiteDatabase, periodCurrencies: [String],
                                        regimeDefault: String) -> Resolution<String> {
        guard ReportSettings.rowExists(db, "currency") else {
            return .blocked(.currencyNotConfigured(periodCurrencies: periodCurrencies,
                                                   regimeDefault: regimeDefault))
        }
        let raw = ReportSettings.rawValue(db, "currency") ?? ""
        guard case .string(let stored)? = ReportSettings.jsonFragment(raw),
              !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .blocked(.currencyInvalid(storedText: raw, periodCurrencies: periodCurrencies,
                                             regimeDefault: regimeDefault))
        }
        // A stored code that differs from the REGIME DEFAULT is a legitimate user choice —
        // the Electron accounting screen edits this field directly. Only a disagreement with
        // the money actually recorded is an error.
        if periodCurrencies.count > 1 {
            return .blocked(.multipleCurrenciesInPeriod(codes: periodCurrencies))
        }
        if let only = periodCurrencies.first, only != stored {
            return .blocked(.currencyMismatch(storedCurrency: stored, periodCurrency: only))
        }
        // An empty set is still reachable on the transactions path: the period HAS rows, but
        // none of them is selected by either window — e.g. every row is `unpaid` and dated
        // outside the P&L bounds by a same-day timestamp. Nothing is priced in that case, so
        // there is nothing for the stored currency to disagree with. (A legacy period cannot
        // arrive here at all; it returned `legacySourceUnavailable` earlier.)
        return .resolved(stored)
    }

    // MARK: - Parameters

    private static func parameters(_ db: SQLiteDatabase, locale: String,
                                   ctx: ReportContext) -> [PresentedParameter] {
        ReportParameterKey.allCases.map { key in
            switch key {
            case .incomeTaxRate:
                return rateParameter(key, setting: ctx.incomeTaxRate,
                                     parameter: .incomeTaxRate, consumption: .consumed)
            case .surchargeRate:
                // Only `cn.js vatPayable` reads it. Elsewhere a missing row must not read as a
                // problem: a Japanese report is not blocked by a rate no Japanese line uses.
                return rateParameter(key, setting: ctx.surchargeRate, parameter: .surchargeRate,
                                     consumption: locale == "CN" ? .consumed : .storedButUnread)
            case .vatRate:
                // `index.js vatRate` — `Number(readSetting(db, 'vat_rate', 13))`. An UNGATED
                // coercion with a fallback, exactly like the admin expense and NOT like the
                // two rates: scheme A never gates it (`index.js generate` says so), so it has no
                // refusal state and modelling it with the rate's four states would report a
                // refusal Electron never performs. Read by no engine (Appendix A6).
                return ungatedNumericParameter(db, key: key, fallback: 13,
                                               consumption: .storedButUnread)
            case .adminExpenseAnnual:
                // `index.js adminExpense` — the same shape, fallback 0, and consumed by every engine.
                return ungatedNumericParameter(db, key: key, fallback: 0,
                                               consumption: .consumed)
            }
        }
    }

    private static func rateParameter(_ key: ReportParameterKey, setting: ReportRateSetting,
                                      parameter: ReportRateParameter,
                                      consumption: ParameterConsumption) -> PresentedParameter {
        let stored: StoredSettingState
        let effect: ParameterEffect
        switch setting {
        case .configured(let r):
            stored = .usable(r.value); effect = .appliedValue(r.value, origin: .storedValue)
        case .chinaFallback(let r):
            stored = .absent;          effect = .appliedValue(r.value, origin: .regimeDefault)
        case .notConfigured:
            stored = .absent;          effect = .refused(parameter)
        case .needsRepair(let raw):
            stored = .needsRepair(storedText: raw); effect = .refused(parameter)
        }
        return PresentedParameter(key: key, stored: stored, nativeEffect: effect,
                                  consumption: consumption)
    }

    /// `vat_rate` and `admin_expense_annual`: `Number(readSetting(db, key, fallback))`, with
    /// NO gate on either side. These do not get the rates' four states.
    ///
    /// Absence is a real value, not a refusal — the dispatcher substitutes the fallback
    /// before `Number()` ever sees the absence — and a row whose text `JSON.parse` rejects
    /// is ALSO the fallback, by way of `readSetting`'s swallowing catch.
    ///
    /// Soundness is judged SEPARATELY, by the same shared rule the rates use. That is the
    /// whole point of the two axes: `true` reaches the engines as **1** and `[5000]` as
    /// **5000**, and both must stay visible as damage rather than pass for a setting someone
    /// chose. A finite result is not evidence of a sound row.
    private static func ungatedNumericParameter(_ db: SQLiteDatabase, key: ReportParameterKey,
                                                fallback: Double,
                                                consumption: ParameterConsumption)
        -> PresentedParameter {
        let applied = ReportSettings.number(db, key.rawValue, fallback: fallback)
        guard ReportSettings.rowExists(db, key.rawValue) else {
            return PresentedParameter(key: key, stored: .absent,
                                      nativeEffect: .appliedValue(fallback,
                                                                  origin: .dispatcherFallback),
                                      consumption: consumption)
        }
        let raw = ReportSettings.rawValue(db, key.rawValue) ?? ""
        let stored: StoredSettingState
        if case .configured(let r) = ReportSettings.classifyRate(raw) {
            stored = .usable(r.value)
        } else {
            stored = .needsRepair(storedText: raw)
        }
        guard applied.isFinite else {
            // Only reachable here: a parsed value that coerces to NaN (`{}`, `"5000元"`).
            // China's `round2` carries it into the report; the other five flatten it to 0
            // with `round2OrZero`. Neither is normalised.
            return PresentedParameter(key: key, stored: stored, nativeEffect: .appliedNonFinite,
                                      consumption: consumption)
        }
        // A row whose text `JSON.parse` rejects reached the engines as the dispatcher's
        // fallback, not as its own value — the origin has to say which of the two happened.
        let origin: EffectOrigin = ReportSettings.jsonFragment(raw) == nil
            ? .dispatcherFallback : .storedValue
        return PresentedParameter(key: key, stored: stored,
                                  nativeEffect: .appliedValue(applied, origin: origin),
                                  consumption: consumption)
    }

    // MARK: - Sections

    private static func sections(locale: String, ctx: ReportContext) -> [PresentedSection] {
        (ReportPresentation.reportTypes(locale: locale) ?? []).map { type in
            PresentedSection(
                reportTypeID: type.id,
                availability: type.section,
                // A withheld section carries nothing to render, even by accident.
                lines: type.section == .withhold ? []
                                                 : lines(locale: locale, id: type.id, ctx: ctx),
                notes: type.section == .withhold ? []
                                                 : notes(locale: locale, id: type.id, ctx: ctx))
        }
    }

    private static func money(_ v: Double) -> ReportFieldPresentation { ReportPresentation.field(v) }
    private static func money(_ v: EstimatedValue) -> ReportFieldPresentation {
        ReportPresentation.field(v)
    }

    private static func lines(locale: String, id: String,
                              ctx: ReportContext) -> [PresentedLine] {
        func line(_ name: String, _ unit: ReportLineUnit,
                  _ value: ReportFieldPresentation) -> PresentedLine {
            PresentedLine(id: name, unit: unit, value: value)
        }
        switch (locale, id) {
        case ("CN", "income-statement"):
            let b = CNReportEngine.batchOne(ctx)
            return [line("salesRevenue", .money, money(b.salesRevenue)),
                    line("costOfSales", .money, money(b.costOfSales)),
                    line("costOfGoodsSold", .money, money(b.costOfGoodsSold)),
                    line("operatingExpenses", .money, money(b.operatingExpenses)),
                    line("grossProfit", .money, money(b.grossProfit)),
                    line("grossMargin", .percent, money(b.grossMargin)),
                    line("shippingFee", .money, money(b.shippingFee)),
                    line("adminExpense", .money, money(b.adminExpense)),
                    line("operatingProfit", .money, money(b.operatingProfit)),
                    line("taxSurcharge", .money, money(b.taxSurcharge)),
                    line("incomeTax", .money, money(b.incomeTax)),
                    line("netProfit", .money, money(b.netProfit)),
                    line("netMargin", .percent, money(b.netMargin))]
        case ("JP", "income-statement"), ("KR", "income-statement"), ("TW", "income-statement"):
            let b = locale == "JP" ? JPReportEngine.batchOne(ctx)
                  : locale == "KR" ? KRReportEngine.batchOne(ctx) : TWReportEngine.batchOne(ctx)
            return [line("salesRevenue", .money, money(b.salesRevenue)),
                    line("costOfSales", .money, money(b.costOfSales)),
                    line("costOfGoodsSold", .money, money(b.costOfGoodsSold)),
                    line("operatingExpenses", .money, money(b.operatingExpenses)),
                    line("grossProfit", .money, money(b.grossProfit)),
                    line("grossMargin", .percent, money(b.grossMargin)),
                    line("adminExpense", .money, money(b.adminExpense)),
                    line("operatingProfit", .money, money(b.operatingProfit)),
                    line("incomeTax", .money, money(b.incomeTax)),
                    line("netProfit", .money, money(b.netProfit)),
                    line("netMargin", .percent, money(b.netMargin))]
        case ("EU", "profit-loss"):
            let b = EUReportEngine.batchOne(ctx)
            // `revenue`, not `salesRevenue` — the source's own naming (`eu.js vatPayable`).
            return [line("revenue", .money, money(b.revenue)),
                    line("costOfSales", .money, money(b.costOfSales)),
                    line("costOfGoodsSold", .money, money(b.costOfGoodsSold)),
                    line("operatingExpenses", .money, money(b.operatingExpenses)),
                    line("grossProfit", .money, money(b.grossProfit)),
                    line("grossMargin", .percent, money(b.grossMargin)),
                    line("adminExpense", .money, money(b.adminExpense)),
                    line("operatingProfit", .money, money(b.operatingProfit)),
                    line("incomeTax", .money, money(b.incomeTax)),
                    line("netProfit", .money, money(b.netProfit)),
                    line("netMargin", .percent, money(b.netMargin))]
        case ("CN", "vat-summary"):
            let b = CNReportEngine.vatSummary(ctx)
            return [line("cumulativeInput", .money, money(b.cumulativeInput)),
                    line("cumulativeOutput", .money, money(b.cumulativeOutput)),
                    line("certifiedInput", .money, money(b.certifiedInput)),
                    line("invoicedOutput", .money, money(b.invoicedOutput)),
                    line("estimatedPayable", .money, money(b.estimatedPayable))]
        case ("JP", "consumption-tax"):
            let b = JPReportEngine.consumptionTax(ctx)
            return [line("collected", .money, money(b.collected)),
                    line("paid", .money, money(b.paid)),
                    line("payable", .money, money(b.payable))]
        case ("EU", "vat-return"):
            let b = EUReportEngine.vatReturn(ctx)
            return [line("outputVAT", .money, money(b.outputVAT)),
                    line("inputVAT", .money, money(b.inputVAT)),
                    line("vatPayable", .money, money(b.vatPayable))]
        case ("KR", "vat-summary"):
            let b = KRReportEngine.vatSummary(ctx)
            return [line("outputVAT", .money, money(b.outputVAT)),
                    line("inputVAT", .money, money(b.inputVAT)),
                    line("vatPayable", .money, money(b.vatPayable))]
        case ("TW", "business-tax"):
            let b = TWReportEngine.businessTax(ctx)
            return [line("collected", .money, money(b.collected)),
                    line("paid", .money, money(b.paid)),
                    line("payable", .money, money(b.payable))]
        case ("CN", "tax-inclusive"):
            return taxInclusiveLines(CNReportEngine.taxInclusiveSummary(ctx))
        case ("US", "schedule-c"):
            let c = USReportEngine.scheduleC(ctx)
            // The 25 CONTRACT lines only. `unroundedGrossIncome`, `unroundedTotalExpenses`
            // and `rawMealsTotal` are intermediates the engine does not emit
            // (`ReportBatch4ParityTests.nonContractFields`) and are not exported.
            return [line("line1_grossReceipts", .money, money(c.line1_grossReceipts)),
                    line("line2_returns", .money, money(c.line2_returns)),
                    line("line6_otherIncome", .money, money(c.line6_otherIncome)),
                    line("line7_grossIncome", .money, money(c.line7_grossIncome)),
                    line("line8_advertising", .money, money(c.line8_advertising)),
                    line("line9_car", .money, money(c.line9_car)),
                    line("line10_commissions", .money, money(c.line10_commissions)),
                    line("line11_contract", .money, money(c.line11_contract)),
                    line("line13_depreciation", .money, money(c.line13_depreciation)),
                    line("line15_insurance", .money, money(c.line15_insurance)),
                    line("line16b_interest", .money, money(c.line16b_interest)),
                    line("line17_legal", .money, money(c.line17_legal)),
                    line("line18_office", .money, money(c.line18_office)),
                    line("line20_rent", .money, money(c.line20_rent)),
                    line("line21_repairs", .money, money(c.line21_repairs)),
                    line("line22_supplies", .money, money(c.line22_supplies)),
                    line("line23_taxes", .money, money(c.line23_taxes)),
                    line("line24a_travel", .money, money(c.line24a_travel)),
                    line("line24b_meals", .money, money(c.line24b_meals)),
                    line("line25_utilities", .money, money(c.line25_utilities)),
                    line("line26_wages", .money, money(c.line26_wages)),
                    line("line27a_other", .money, money(c.line27a_other)),
                    line("line30_homeOffice", .money, money(c.line30_homeOffice)),
                    line("line28_totalExpenses", .money, money(c.line28_totalExpenses)),
                    line("line31_netProfit", .money, money(c.line31_netProfit))]
        case ("US", "se-tax"):
            let se = USReportEngine.selfEmploymentTax(ctx)
            let est = USReportEngine.estimatedTax(ctx)
            return [line("netEarnings", .money, money(se.netEarnings)),
                    line("seEarnings", .money, money(se.seEarnings)),
                    line("socialSecurityTax", .money, money(se.socialSecurityTax)),
                    line("medicareTax", .money, money(se.medicareTax)),
                    line("additionalMedicare", .money, money(se.additionalMedicare)),
                    line("totalSETax", .money, money(se.totalSETax)),
                    line("annualIncomeTax", .money, money(est.annualIncomeTax)),
                    line("annualSETax", .money, money(est.annualSETax)),
                    line("totalAnnual", .money, money(est.totalAnnual)),
                    line("quarterlyPayment", .money, money(est.quarterlyPayment))]
        default:
            return []
        }
    }

    private static func taxInclusiveLines(_ b: TaxInclusiveSummary) -> [PresentedLine] {
        [PresentedLine(id: "purchaseTotal", unit: .money, value: money(b.purchaseTotal)),
         PresentedLine(id: "salesTotal", unit: .money, value: money(b.salesTotal)),
         PresentedLine(id: "difference", unit: .money, value: money(b.difference))]
    }

    private static func notes(locale: String, id: String,
                              ctx: ReportContext) -> [PresentedNote] {
        guard locale == "US", id == "se-tax" else { return [] }
        return [.estimatedTaxDueDates(USReportEngine.estimatedTax(ctx).dueDates),
                .selfEmploymentParameterYear(USReportEngine.selfEmploymentTax(ctx).paramYear)]
    }

    /// JP / EU / KR / TW emit the block without declaring a report type id for it, so it
    /// would be dropped by `sections` alone. China declares the id and its block is a
    /// section; the US engine has no such block.
    private static func undeclaredTaxInclusive(locale: String,
                                               ctx: ReportContext) -> PresentedTaxInclusiveSummary? {
        let block: TaxInclusiveSummary
        switch locale {
        case "JP": block = JPReportEngine.taxInclusiveSummary(ctx)
        case "EU": block = EUReportEngine.taxInclusiveSummary(ctx)
        case "KR": block = KRReportEngine.taxInclusiveSummary(ctx)
        case "TW": block = TWReportEngine.taxInclusiveSummary(ctx)
        default:   return nil                       // CN declares it; US has none
        }
        return PresentedTaxInclusiveSummary(purchaseTotal: money(block.purchaseTotal),
                                            salesTotal: money(block.salesTotal),
                                            difference: money(block.difference))
    }

    private static func months(locale: String, ctx: ReportContext) -> [PresentedMonth] {
        let raw: [ReportMonth]
        switch locale {
        case "CN": raw = CNReportEngine.monthlyBreakdown(ctx)
        case "JP": raw = JPReportEngine.monthlyBreakdown(ctx)
        case "EU": raw = EUReportEngine.monthlyBreakdown(ctx)
        case "KR": raw = KRReportEngine.monthlyBreakdown(ctx)
        case "TW": raw = TWReportEngine.monthlyBreakdown(ctx)
        default:   raw = USReportEngine.monthlyBreakdown(ctx)
        }
        return raw.map { PresentedMonth(month: $0.month, revenue: money($0.revenue),
                                        cost: money($0.cost), profit: money($0.profit)) }
    }

    /// Only ever reached on the transactions path, so operating cash is always computed.
    ///
    /// An empty `rows` here is a HONEST zero and a different thing from the legacy stop: the
    /// period does have transactions, none of them is paid or partial, so no cash was
    /// realized. The table was read and the answer is nothing — which is exactly what the
    /// legacy case cannot say about itself.
    private static func cashflow(rows: [CashflowRow]) -> PresentedCashflow {
        let c = Cashflow.operating(rows: rows)
        return PresentedCashflow(basis: "cash", statutory: false,
                                 operating: .computed(inflow: money(c.inflow),
                                                      outflow: money(c.outflow),
                                                      net: money(c.net)),
                                 investing: .notDerivableFromThisDataModel,
                                 financing: .notDerivableFromThisDataModel,
                                 beginningCash: .notDerivableFromThisDataModel,
                                 endingCash: .notDerivableFromThisDataModel)
    }

    /// The US warnings, as facts. The predicates are `us.js warnings` and `:121` — the same two
    /// the engine uses — and `ReportBuilderTests.testPresentedWarningsMatchTheEnginesArray`
    /// asserts the result corresponds one-to-one with `USReportEngine.warnings(ctx)`, so the
    /// two spellings cannot drift.
    private static func warnings(locale: String, ctx: ReportContext) -> [PresentedWarning] {
        guard locale == "US" else { return [] }      // the five VAT engines hardcode `[]`
        var out: [PresentedWarning] = []
        let c = USReportEngine.scheduleC(ctx)
        let netProfit = c.unroundedGrossIncome - c.unroundedTotalExpenses
        let totalSETax = USReportEngine.selfEmploymentTax(ctx).totalSETax
        let estimate = USReportEngine.estimatedTax(ctx)
        if netProfit > 0, totalSETax > 0, case .computed(let q) = estimate.quarterlyPayment {
            out.append(.estimatedQuarterlyPayment(amount: money(q)))
        }
        if ReportMath.isTruthy(c.rawMealsTotal) { out.append(.mealsLimitedToFiftyPercent) }
        return out
    }
}
