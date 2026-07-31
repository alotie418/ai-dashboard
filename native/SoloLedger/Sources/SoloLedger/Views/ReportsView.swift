import SwiftUI
import SoloLedgerCore

/// The report page.
///
/// **Reached from the `.reports` sidebar section** (P3e) through the split view's detail switch —
/// one enum case serving both the sidebar list and the menu-bar picker. The entry point was a
/// separate change, deliberately: until that case existed this page was compiled, tested and
/// unreachable, so every intermediate `main` shipped the product byte for byte unchanged.
///
/// Every key this page draws comes from ``ReportPageComposition``. The subviews below take their
/// slice of that value and render exactly what it names — which is what makes the four
/// disclaimers provable without driving the UI.
struct ReportsView: View {
    @EnvironmentObject var model: AppModel

    private var page: ReportPageComposition.Page {
        ReportPageComposition.compose(model.reportState, uiLanguage: model.language)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ReportYearBar()
                content
                if !page.footerKeys.isEmpty {
                    Divider()
                    ReportDisclaimerText(key: ReportPageComposition.reportDisclaimerKey)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(model.t("report.page.title"))
    }

    @ViewBuilder private var content: some View {
        switch model.reportState {
        case .notRequested:
            ReportNotRequestedView()
        case .failed(let year):
            ReportFailedView(year: year)
        case .blocked(let year, let blocker):
            if let blocked = page.blocked {
                ReportBlockedView(year: year, blocker: blocker, block: blocked)
            }
        case .report(let report):
            if let body = page.body {
                ReportBodyView(report: report, body: body)
            }
        }
    }
}

// MARK: - Year

/// Four ASCII digits, `0001`-`9999`, entered directly or stepped one at a time. The bounds are
/// the storage format's, not a product guess — see `ReportYear`.
private struct ReportYearBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text(model.t("report.year.label")).font(.callout)
                TextField("", text: Binding(
                    get: { model.reportYearText },
                    set: { model.reportYearText = String($0.prefix(ReportYear.width)) }
                ))
                .frame(width: 72)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .accessibilityIdentifier("report.year.field")

                Stepper(model.t("report.year.label")) {
                    model.reportYearText = ReportYear.stepped(model.reportYearText, by: 1)
                } onDecrement: {
                    model.reportYearText = ReportYear.stepped(model.reportYearText, by: -1)
                }
                .labelsHidden()

                Button(model.t("report.action.build")) { model.buildReport() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.reportYearIsValid)
                    .accessibilityIdentifier("report.action.build")
                Spacer()
            }
            if !model.reportYearIsValid {
                Text(model.t("report.year.invalid"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - The three states with no report

private struct ReportNotRequestedView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        EmptyStateView(systemImage: "doc.text.magnifyingglass",
                       title: model.t("report.notRequested.title"),
                       message: model.t("report.notRequested.message"))
    }
}

/// An I/O fault. The year is shown; the error is not. `ReportPageState.failed` carries no error
/// to show, so nothing here could leak a path or a SQLite message even by accident.
private struct ReportFailedView: View {
    @EnvironmentObject var model: AppModel
    let year: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(year).font(.title3).fontWeight(.semibold).monospacedDigit()
            Text(model.t("report.error.title")).font(.headline)
            Text(model.t("report.error.message"))
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(model.t("report.action.retry")) { model.buildReport() }
                .accessibilityIdentifier("report.action.retry")
        }
        .frame(maxWidth: 560, alignment: .leading)
    }
}

/// A stated refusal. Facts, never a repair that does not exist: the two accounting-profile cases
/// offer a route to Settings because Settings really does hold that control, and the other five
/// offer nothing because nothing in this app can change their answer.
private struct ReportBlockedView: View {
    @EnvironmentObject var model: AppModel
    let year: String
    let blocker: ReportBlocker
    let block: ReportPageComposition.BlockedBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(year).font(.title3).fontWeight(.semibold).monospacedDigit()
            Text(model.t(block.titleKey)).font(.headline)
            Text(model.t(block.bodyKey))
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            facts
            if block.action == .openSettings { settingsRoute }
        }
        .frame(maxWidth: 560, alignment: .leading)
        .accessibilityIdentifier("report.blocked")
    }

    @ViewBuilder private var facts: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(block.factKeys, id: \.self) { key in
                factRow(key)
            }
        }
    }

    @ViewBuilder private func factRow(_ key: String) -> some View {
        switch key {
        case "report.storedText.label":
            StoredTextPreview(label: model.t(key), raw: storedText)
        case "report.blocker.storedCurrency":
            Text(model.t(key, ["currency": ReportFormat.currencyDisplay(storedCurrency)]))
                .font(.footnote)
        case "report.blocker.periodCurrencies":
            Text(model.t(key, ["codes": periodCurrencies]))
                .font(.footnote)
        case "report.blocker.regimeDefaultCurrency":
            Text(model.t(key, ["currency": ReportFormat.currencyDisplay(regimeDefault)]))
                .font(.footnote)
        default:
            EmptyView()
        }
    }

    private var storedText: String {
        switch blocker {
        case .accountingLocaleInvalid(let text):  return text
        case .currencyInvalid(let text, _, _):    return text
        default:                                  return ""
        }
    }

    private var storedCurrency: String {
        if case .currencyMismatch(let stored, _) = blocker { return stored }
        return ""
    }

    private var periodCurrencies: String {
        switch blocker {
        case .currencyNotConfigured(let codes, _):     return joined(codes)
        case .currencyInvalid(_, let codes, _):        return joined(codes)
        case .multipleCurrenciesInPeriod(let codes):   return joined(codes)
        case .currencyMismatch(_, let period):         return ReportFormat.currencyDisplay(period)
        default:                                       return ""
        }
    }

    private var regimeDefault: String {
        switch blocker {
        case .currencyNotConfigured(_, let preset):  return preset
        case .currencyInvalid(_, _, let preset):     return preset
        default:                                     return ""
        }
    }

    private func joined(_ codes: [String]) -> String {
        codes.map(ReportFormat.currencyDisplay).joined(separator: " · ")
    }

    /// Opens the Settings scene. `SettingsLink` is the supported way and needs macOS 14; on 13
    /// the action selector is the only route. Either way the menu path is spelled out below the
    /// control, so a user is never stranded if neither works.
    @ViewBuilder private var settingsRoute: some View {
        VStack(alignment: .leading, spacing: 4) {
            if #available(macOS 14, *) {
                SettingsLink { Text(model.t("report.action.openSettings")) }
                    .accessibilityIdentifier("report.action.openSettings")
            } else {
                Button(model.t("report.action.openSettings")) {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
                .accessibilityIdentifier("report.action.openSettings")
            }
            Text(model.t("report.action.openSettings.hint"))
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A stored setting exactly as the ledger holds it: quotes kept, nothing trimmed, control and
/// bidirectional-override scalars turned into literals, and the whole thing bounded.
private struct StoredTextPreview: View {
    let label: String
    let raw: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.footnote).foregroundStyle(.secondary)
            Text(ReportFormat.safePreview(raw))
                .font(.caption).monospaced()
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
        .frame(maxWidth: 460, alignment: .leading)
        .accessibilityIdentifier("report.storedText")
    }
}

// MARK: - A report

private struct ReportBodyView: View {
    @EnvironmentObject var model: AppModel
    let report: PresentedReport
    let body_: ReportPageComposition.ReportBody

    init(report: PresentedReport, body: ReportPageComposition.ReportBody) {
        self.report = report
        self.body_ = body
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ReportCaptionBar(report: report)
            ForEach(body_.sections, id: \.reportTypeID) { block in
                if let section = report.sections.first(where: { $0.reportTypeID == block.reportTypeID }) {
                    ReportSectionView(report: report, section: section, block: block)
                }
            }
            if let undeclared = body_.undeclaredTaxInclusive,
               let summary = report.undeclaredTaxInclusiveSummary {
                ReportTaxInclusiveBlockView(report: report, summary: summary, block: undeclared)
            }
            ReportParameterTable(report: report, block: body_.parameters)
            ReportCashflowView(report: report, keys: body_.cashflowKeys)
            if !body_.monthlyKeys.isEmpty { ReportMonthlyTable(report: report) }
            if !body_.noteKeys.isEmpty { ReportNotesView(report: report) }
            if !body_.warningKeys.isEmpty { ReportWarningsView(report: report) }
        }
    }
}

/// Period, currency and the estimate badge. The currency shown is `report.currency` and nothing
/// else — never the ledger's current setting, never a default, never a substitution.
private struct ReportCaptionBar: View {
    @EnvironmentObject var model: AppModel
    let report: PresentedReport

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(report.period.year).font(.title2).fontWeight(.semibold).monospacedDigit()
            Text(model.t("report.period.caption",
                         ["from": report.period.from, "to": report.period.to]))
                .font(.footnote).foregroundStyle(.secondary)
            Text(model.t("report.currency.caption",
                         ["currency": ReportFormat.currencyDisplay(report.currency)]))
                .font(.footnote).foregroundStyle(.secondary)
                .accessibilityIdentifier("report.currency.caption")
            Text(model.t("report.currency.note"))
                .font(.footnote).foregroundStyle(.secondary)
            if ReportFormat.currencyShape(report.currency) == .other {
                Text(model.t("report.currency.formatNote"))
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(model.t("report.estimate.badge")).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct ReportSectionView: View {
    @EnvironmentObject var model: AppModel
    let report: PresentedReport
    let section: PresentedSection
    let block: ReportPageComposition.SectionBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.t(block.titleKey)).font(.headline)
            ForEach(section.lines.indices, id: \.self) { index in
                ReportLineRow(report: report, line: section.lines[index])
            }
            ForEach(block.noteKeys, id: \.self) { key in
                Text(model.t(key)).font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(block.disclaimerKeys, id: \.self) { key in
                ReportDisclaimerText(key: key)
            }
        }
        .accessibilityIdentifier("report.section.\(block.reportTypeID)")
    }
}

private struct ReportTaxInclusiveBlockView: View {
    @EnvironmentObject var model: AppModel
    let report: PresentedReport
    let summary: PresentedTaxInclusiveSummary
    let block: ReportPageComposition.SectionBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.t(block.titleKey)).font(.headline)
            row("purchaseTotal", summary.purchaseTotal)
            row("salesTotal", summary.salesTotal)
            row("difference", summary.difference)
        }
    }

    @ViewBuilder private func row(_ id: String, _ field: ReportFieldPresentation) -> some View {
        ReportLineRow(report: report, line: nil, fallbackID: id, fallbackValue: field)
    }
}

/// One figure. Four kinds and no fifth: an amount, damaged data, a refusal with no configured
/// rate, and a stored value that needs repair. A refusal never renders as `0`.
private struct ReportLineRow: View {
    @EnvironmentObject var model: AppModel
    let report: PresentedReport
    let line: PresentedLine?
    var fallbackID: String = ""
    var fallbackValue: ReportFieldPresentation = .amount(0)

    private var id: String { line?.id ?? fallbackID }
    private var field: ReportFieldPresentation { line?.value ?? fallbackValue }
    private var unit: ReportLineUnit { line?.unit ?? .money }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.callout)
            Spacer(minLength: 16)
            value
        }
    }

    private var label: String {
        switch ReportPresenter.lineLabelText(for: id, reportLocale: report.locale,
                                             uiLanguage: model.language,
                                             localized: { model.t($0) }) {
        case .text(let text):          return text
        case .unmapped(let id):        return id
        case .unresolvedTaxName(let id): return id
        }
    }

    @ViewBuilder private var value: some View {
        switch ReportPresenter.rendering(for: field) {
        case .amount(let amount):
            Text(unit == .percent ? ReportFormat.percent(amount, language: model.language)
                                  : ReportFormat.money(amount, language: model.language))
                .monospacedDigit()
        case .corrupted(let key):
            Text(model.t(key)).font(.footnote).foregroundStyle(.secondary)
        case .notConfigured(let key, let nameKey):
            refusal(model.t(key), model.t(nameKey))
        case .needsRepair(let key, let nameKey, let stored):
            VStack(alignment: .trailing, spacing: 4) {
                refusal(model.t(key), model.t(nameKey))
                StoredTextPreview(label: model.t("report.storedText.label"), raw: stored)
            }
        }
    }

    private func refusal(_ text: String, _ name: String) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(text).font(.footnote).foregroundStyle(.secondary)
            Text(name).font(.caption2).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.trailing)
    }
}

/// Both axes of every parameter, plus where an applied value came from. A preset the app chose
/// on the user's behalf is named as such, with its percent.
private struct ReportParameterTable: View {
    @EnvironmentObject var model: AppModel
    let report: PresentedReport
    let block: ReportPageComposition.ParameterBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.t(block.titleKey)).font(.headline)
            HStack {
                ForEach(block.axisKeys, id: \.self) { key in
                    Text(model.t(key)).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            ForEach(report.parameters.indices, id: \.self) { index in
                parameterRow(report.parameters[index])
            }
            ForEach(block.disclaimerKeys, id: \.self) { key in
                ReportDisclaimerText(key: key)
            }
        }
        .accessibilityIdentifier("report.parameters")
    }

    private func parameterRow(_ parameter: PresentedParameter) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name(parameter)).font(.callout)
            HStack(alignment: .top) {
                axis(model.t(ReportPresenter.storedKey(for: parameter.stored)))
                axis(effectText(parameter.nativeEffect))
                axis(model.t(ReportPresenter.consumptionKey(for: parameter.consumption)))
            }
        }
    }

    private func name(_ parameter: PresentedParameter) -> String {
        let key = ReportPresenter.nameKey(for: parameter.key)
        let copy = model.t(key)
        guard copy.contains(ReportPresenter.taxToken),
              let tax = ReportPresenter.turnoverTaxName(reportLocale: report.locale,
                                                        uiLanguage: model.language)
        else { return copy }
        return copy.replacingOccurrences(of: ReportPresenter.taxToken, with: tax)
    }

    private func effectText(_ effect: ParameterEffect) -> String {
        let base = model.t(ReportPresenter.effectKey(for: effect))
        guard case .appliedValue(let value, let origin) = effect else { return base }
        let originCopy = model.t(ReportPresenter.originKey(for: origin))
        guard origin == .regimeDefault else { return base + "\n" + originCopy }
        return base + "\n" + originCopy.replacingOccurrences(
            of: "{percent}", with: ReportFormat.money(value, language: model.language))
    }

    private func axis(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Cash realised, on a management basis. The four sections this data model cannot produce say so
/// in words rather than showing a zero.
private struct ReportCashflowView: View {
    @EnvironmentObject var model: AppModel
    let report: PresentedReport
    let keys: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.t("report.cashflow.title")).font(.headline)
            operating
            underivable("report.cashflow.investing", report.cashflow.investing)
            underivable("report.cashflow.financing", report.cashflow.financing)
            underivable("report.cashflow.beginningCash", report.cashflow.beginningCash)
            underivable("report.cashflow.endingCash", report.cashflow.endingCash)
            Text(model.t("report.cashflow.basisNote"))
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(model.t("report.cashflow.vsProfitNote"))
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("report.cashflow")
    }

    @ViewBuilder private var operating: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.t("report.cashflow.operating.title")).font(.callout)
            if case .computed(let inflow, let outflow, let net) = report.cashflow.operating {
                amountRow("report.cashflow.inflow", inflow)
                amountRow("report.cashflow.outflow", outflow)
                amountRow("report.cashflow.net", net)
            }
        }
    }

    @ViewBuilder private func amountRow(_ key: String, _ field: ReportFieldPresentation) -> some View {
        HStack {
            Text(model.t(key)).font(.caption)
            Spacer(minLength: 16)
            if case .amount(let value) = ReportPresenter.rendering(for: field) {
                Text(ReportFormat.money(value, language: model.language))
                    .font(.caption).monospacedDigit()
            }
        }
    }

    @ViewBuilder private func underivable(_ key: String,
                                          _ section: PresentedCashflowSection) -> some View {
        if case .copy(let noteKey) = ReportPresenter.rendering(for: section) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.t(key)).font(.callout)
                Text(model.t(noteKey)).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ReportMonthlyTable: View {
    @EnvironmentObject var model: AppModel
    let report: PresentedReport

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.t("report.monthly.title")).font(.headline)
            HStack {
                header("report.monthly.month")
                header("report.monthly.revenue")
                header("report.monthly.cost")
                header("report.monthly.profit")
            }
            ForEach(report.monthlyBreakdown, id: \.month) { entry in
                HStack {
                    Text("\(entry.month)").font(.caption).monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    cell(entry.revenue)
                    cell(entry.cost)
                    cell(entry.profit)
                }
            }
        }
        .accessibilityIdentifier("report.monthly")
    }

    private func header(_ key: String) -> some View {
        Text(model.t(key)).font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func cell(_ field: ReportFieldPresentation) -> some View {
        Group {
            if case .amount(let value) = ReportPresenter.rendering(for: field) {
                Text(ReportFormat.money(value, language: model.language)).monospacedDigit()
            } else {
                Text(model.t("report.field.corrupted"))
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private struct ReportNotesView: View {
    @EnvironmentObject var model: AppModel
    let report: PresentedReport

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.t("report.notes.title")).font(.headline)
            ForEach(report.sections.flatMap(\.notes).indices, id: \.self) { index in
                let note = report.sections.flatMap(\.notes)[index]
                Text(text(for: note)).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func text(for note: PresentedNote) -> String {
        let key = ReportPresenter.key(for: note)
        switch note {
        case .estimatedTaxDueDates(let dates):
            return model.t(key, ["dates": dates.joined(separator: " · ")])
        case .selfEmploymentParameterYear(let year):
            return model.t(key, ["year": String(year)])
        }
    }
}

private struct ReportWarningsView: View {
    @EnvironmentObject var model: AppModel
    let report: PresentedReport

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.t("report.warnings.title")).font(.headline)
            ForEach(report.warnings.indices, id: \.self) { index in
                Text(text(for: report.warnings[index]))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func text(for warning: PresentedWarning) -> String {
        let key = ReportPresenter.key(for: warning)
        guard case .estimatedQuarterlyPayment(let amount) = warning else { return model.t(key) }
        guard case .amount(let value) = ReportPresenter.rendering(for: amount) else {
            return model.t(key, ["amount": model.t("report.field.corrupted")])
        }
        return model.t(key, ["amount": ReportFormat.money(value, language: model.language)])
    }
}

/// One disclaimer, wherever it is mounted. A single type so every mount point looks the same and
/// none of them can quietly become a different weight of text.
private struct ReportDisclaimerText: View {
    @EnvironmentObject var model: AppModel
    let key: String

    var body: some View {
        Text(model.t(key))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(key)
    }
}
