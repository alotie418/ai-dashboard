import SwiftUI
import SoloLedgerCore

/// The legacy-conversion wizard.
///
/// **Reached from the two entry points on `LegacyLedgerNotice` / `LegacyLedgerBanner`**, and
/// mounted in exactly one place (`RootView`). One scrolling sheet, not a multi-step flow: the
/// adjudicated copy has an opening paragraph, one confirm button and a cancel, and no
/// next/back labels — the decision is made on one page after reading it.
///
/// Every key this sheet draws comes from ``LegacyConversionComposition``. The subviews take
/// their slice of that value and render exactly what it names, which is what makes "the entry
/// point is on the `hasUnconverted` branch and nowhere else" and "a failure shows a key, never
/// an `Error`" provable without driving the UI.
struct LegacyConversionView: View {
    @EnvironmentObject var model: AppModel

    private var page: LegacyConversionComposition.Page {
        LegacyConversionComposition.compose(model.legacyConversion)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    content
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(minWidth: 660, idealWidth: 720, minHeight: 520, idealHeight: 620)
    }

    @ViewBuilder private var header: some View {
        if page.frameKeys.contains("legacy.convert.title") {
            Text(model.t("legacy.convert.title"))
                .font(.title3).fontWeight(.semibold)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24).padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var content: some View {
        if page.frameKeys.contains("legacy.convert.intro") {
            Text(model.t("legacy.convert.intro"))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        switch model.legacyConversion {
        case .idle:
            EmptyView()
        case .blocked(let blocker):
            if let keys = page.blockedKeys {
                LegacyConversionBlockedView(blocker: blocker, keys: keys)
            }
        case .summary(let plan):
            if let block = page.summary {
                LegacyConversionPlanView(plan: plan, block: block)
            }
        case .running:
            if let keys = page.runningKeys {
                LegacyConversionRunningView(keys: keys)
            }
        case .completed(let converted, let notConverted, let backupPath):
            if let keys = page.doneKeys {
                LegacyConversionDoneView(convertedCount: converted,
                                         notConvertedCount: notConverted,
                                         backupPath: backupPath, keys: keys)
            }
        case .failed:
            if let keys = page.failedKeys {
                LegacyConversionFailedView(keys: keys)
            }
        }
    }

    /// The only two actions this sheet ever offers, and neither exists while it is running:
    /// a conversion in flight holds a write transaction, and both closing the window and
    /// pressing the button again would be a second opinion about a decision already taken.
    @ViewBuilder private var footer: some View {
        HStack {
            Spacer()
            switch model.legacyConversion {
            case .idle, .running:
                EmptyView()
            case .blocked:
                Button(model.t("common.cancel")) { model.dismissLegacyConversion() }
                    .keyboardShortcut(.cancelAction)
            case .summary(let plan):
                Button(model.t("common.cancel")) { model.dismissLegacyConversion() }
                    .keyboardShortcut(.cancelAction)
                if !plan.hasNothingToConvert {
                    Button(model.t("legacy.convert.action.convert")) {
                        model.confirmLegacyConversion()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.legacyConversionCanStart)
                }
            case .completed, .failed:
                Button(model.t("common.ok")) { model.dismissLegacyConversion() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
    }
}

// MARK: - Blocked

private struct LegacyConversionBlockedView: View {
    @EnvironmentObject var model: AppModel
    let blocker: LegacyConversionBlocker
    let keys: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(model.t(keys[0]), systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text(model.t(keys[1], ["currency": currency]))
                .fixedSize(horizontal: false, vertical: true)
            if keys.contains("legacy.convert.storedText.label"),
               let stored = LegacyConversionComposition.storedText(for: blocker) {
                LegacyStoredTextPreview(label: model.t("legacy.convert.storedText.label"),
                                        raw: stored)
            }
        }
    }

    /// Only `currencyNotStorableVerbatim` interpolates one; the rest carry no token, and a
    /// substitution for a token that is not there is a no-op.
    private var currency: String {
        if case .currencyNotStorableVerbatim(let code) = blocker {
            return ReportFormat.currencyDisplay(code)
        }
        return ""
    }
}

/// The ledger's own bytes, escaped for display only.
///
/// The escaping rule is the one the report page already uses — control characters, bidi
/// overrides and `U+FEFF` become `<U+XXXX>` — because a second rule would drift from it, and
/// because on a damaged row the invisible character IS the damage.
private struct LegacyStoredTextPreview: View {
    let label: String
    let raw: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(ReportFormat.safePreview(raw))
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.12))
                .cornerRadius(6)
        }
    }
}

// MARK: - The plan

private struct LegacyConversionPlanView: View {
    @EnvironmentObject var model: AppModel
    let plan: LegacyConversionPlan
    let block: LegacyConversionComposition.SummaryBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            grades
            if !block.rowKeys.isEmpty { LegacyConversionRowsView(plan: plan, keys: block.rowKeys) }
            if !block.mappingKeys.isEmpty { note(block.mappingKeys[0]) }
            if !block.categoryKeys.isEmpty {
                LegacyConversionCategoryView(plan: plan, keys: block.categoryKeys)
            }
            if !block.consequenceKeys.isEmpty { consequences }
            if !block.yearKeys.isEmpty { years }
            if !block.backupKeys.isEmpty { backup }
        }
    }

    // — the three grades, counts always, notes only where there is a set to describe —

    @ViewBuilder private var grades: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.t("legacy.convert.summary.title")).font(.headline)
            if block.gradeKeys.contains("legacy.convert.nothingToConvert.title") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.t("legacy.convert.nothingToConvert.title")).fontWeight(.semibold)
                    Text(model.t("legacy.convert.nothingToConvert.message"))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(LegacyRowGrade.allCases, id: \.rawValue) { grade in
                gradeRow(grade)
            }
        }
    }

    @ViewBuilder private func gradeRow(_ grade: LegacyRowGrade) -> some View {
        let countKey = "legacy.convert.grade.\(grade.rawValue)"
        let noteKey = countKey + ".note"
        VStack(alignment: .leading, spacing: 2) {
            Text(model.t(countKey, ["count": String(count(of: grade))]))
                .fontWeight(.medium)
            if block.gradeKeys.contains(noteKey) {
                Text(model.t(noteKey))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 2)
    }

    private func count(of grade: LegacyRowGrade) -> Int {
        switch grade {
        case .convertible:       return plan.convertibleCount
        case .needsAdjudication: return plan.needsAdjudicationCount
        case .unconvertible:     return plan.unconvertibleCount
        }
    }

    // — what converting changes —

    @ViewBuilder private var consequences: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.t("legacy.convert.consequence.title")).font(.headline)
            ForEach(block.consequenceKeys.dropFirst(), id: \.self) { key in
                Text(model.t(key, substitutions(for: key)))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The status disclosure fills its three tokens from `invoice.issued` / `.pending` / `.na`
    /// and never from a literal. That is not a style choice: the zh label for the first of them
    /// is a banned filing word whose only sanction is bound to `invoice.issued` by triple, so
    /// writing it into any other string re-opens the violation this shape was chosen to avoid.
    private func substitutions(for key: String) -> [String: String] {
        switch key {
        case "legacy.convert.consequence.currency":
            return ["currency": ReportFormat.currencyDisplay(plan.currency)]
        case "legacy.convert.consequence.lineItems":
            return ["count": String(plan.headersWithLineItems)]
        case "legacy.convert.consequence.statuses":
            return ["issued": model.t("invoice.issued"),
                    "pending": model.t("invoice.pending"),
                    "na": model.t("invoice.na")]
        default:
            return [:]
        }
    }

    // — the years —

    @ViewBuilder private var years: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.t("legacy.convert.year.title")).font(.headline)
            ForEach(plan.yearOutlook, id: \.year) { outlook in
                VStack(alignment: .leading, spacing: 2) {
                    Text(outlook.existingTransactionCount > 0
                         ? model.t("legacy.convert.year.existing",
                                   ["year": outlook.year,
                                    "count": String(outlook.existingTransactionCount)])
                         : model.t("legacy.convert.year.noneYet", ["year": outlook.year]))
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    if outlook.wouldHoldASecondCurrency {
                        Text(model.t("legacy.convert.year.secondCurrency",
                                     ["year": outlook.year,
                                      "codes": joined(outlook.existingCurrencies)]))
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            note("legacy.convert.year.upperBound")
        }
    }

    private func joined(_ codes: [String]) -> String {
        codes.map(ReportFormat.currencyDisplay).joined(separator: " · ")
    }

    // — the backup —

    @ViewBuilder private var backup: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.t("legacy.convert.backup.title")).font(.headline)
            Text(model.t("legacy.convert.backup.note"))
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Text(model.t("legacy.convert.backup.scope"))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func note(_ key: String) -> some View {
        Text(model.t(key))
            .font(.footnote).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Record by record

private struct LegacyConversionRowsView: View {
    @EnvironmentObject var model: AppModel
    let plan: LegacyConversionPlan
    let keys: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.t("legacy.convert.rows.title")).font(.headline)
            HStack(alignment: .top, spacing: 12) {
                Text(model.t("legacy.convert.row.col.table")).frame(width: 96, alignment: .leading)
                Text(model.t("legacy.convert.row.col.id")).frame(width: 150, alignment: .leading)
                Text(model.t("legacy.convert.row.col.storedDate")).frame(width: 120, alignment: .leading)
                Text(model.t("legacy.convert.row.col.issues")).frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption).foregroundStyle(.secondary)
            Divider()
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(Array(plan.rows.enumerated()), id: \.offset) { _, row in
                    rowView(row)
                    Divider()
                }
            }
        }
    }

    @ViewBuilder private func rowView(_ row: LegacyConversionRow) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(model.t("legacy.convert.table.\(row.table.rawValue)"))
                .frame(width: 96, alignment: .leading)
            // The LEDGER's own id, escaped for display — not `LegacyRowIdentity`, whose
            // `description` is machine text ("sales:s-1") and belongs nowhere near a screen.
            identifier(row)
                .frame(width: 150, alignment: .leading)
            storedDate(row)
                .frame(width: 120, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(row.issues, id: \.rawValue) { issue in
                    Text(model.t("legacy.convert.issue.\(issue.rawValue)"))
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
    }

    @ViewBuilder private func identifier(_ row: LegacyConversionRow) -> some View {
        if let id = row.id {
            Text(ReportFormat.safePreview(id))
                .font(.system(.caption, design: .monospaced)).lineLimit(2)
        } else {
            Text(model.t("legacy.convert.row.idUnreadable"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func storedDate(_ row: LegacyConversionRow) -> some View {
        if let date = row.storedDate {
            Text(ReportFormat.safePreview(date))
                .font(.system(.caption, design: .monospaced)).lineLimit(2)
        } else {
            Text(model.t("legacy.convert.row.storedDateAbsent"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Categories

private struct LegacyConversionCategoryView: View {
    @EnvironmentObject var model: AppModel
    let plan: LegacyConversionPlan
    let keys: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.t("legacy.convert.category.title")).font(.headline)
            if keys.contains("legacy.convert.category.income") {
                picker(label: "legacy.convert.category.income", type: .income,
                       selection: $model.conversionIncomeCategoryID)
            }
            if keys.contains("legacy.convert.category.expense") {
                picker(label: "legacy.convert.category.expense", type: .expense,
                       selection: $model.conversionExpenseCategoryID)
            }
            Text(model.t("legacy.convert.category.note"))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Only categories of THIS ledger's accounting profile are offered — `AppModel.categories`
    /// is loaded with `locale: accountingLocale` — so the runner's regime check cannot be the
    /// first place the user hears about a mismatch. It still runs, inside the transaction, as
    /// the final word.
    @ViewBuilder private func picker(label: String, type: TransactionType,
                                     selection: Binding<String?>) -> some View {
        Picker(model.t(label), selection: selection) {
            Text(model.t("legacy.convert.category.placeholder")).tag(String?.none)
            ForEach(model.categories(for: type)) { category in
                Text(model.categoryLabel(category)).tag(String?.some(category.id))
            }
        }
        .frame(maxWidth: 420, alignment: .leading)
    }
}

// MARK: - Running / done / failed

private struct LegacyConversionRunningView: View {
    @EnvironmentObject var model: AppModel
    let keys: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(model.t("legacy.convert.running.title")).font(.headline)
            }
            Text(model.t("legacy.convert.running.message"))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct LegacyConversionDoneView: View {
    @EnvironmentObject var model: AppModel
    let convertedCount: Int
    let notConvertedCount: Int
    let backupPath: String?
    let keys: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(model.t("legacy.convert.done.title"), systemImage: "checkmark.circle")
                .font(.headline)
            Text(model.t("legacy.convert.done.message", ["count": String(convertedCount)]))
                .fixedSize(horizontal: false, vertical: true)
            Text(model.t("legacy.convert.done.skipped", ["count": String(notConvertedCount)]))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if keys.contains("legacy.convert.done.backup"), let path = backupPath {
                Text(model.t("legacy.convert.done.backup", ["path": path]))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(model.t("legacy.convert.done.legacyKept"))
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Text(model.t("legacy.convert.done.reportNote"))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A refusal, in the app's own words.
///
/// `keys[1]` is a `legacy.convert.failed.*` key chosen by ``LegacyConversionFailureMap``. The
/// `LegacyConversionFailure` it came from never left the background thread, so there is no
/// `description`, no row identity, no `LegacyRowIssue.rawValue` and no SQLite message anywhere
/// in reach of this view.
private struct LegacyConversionFailedView: View {
    @EnvironmentObject var model: AppModel
    let keys: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(model.t("legacy.convert.failed.title"), systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text(model.t(keys[1]))
                .fixedSize(horizontal: false, vertical: true)
            if keys.contains("legacy.convert.failed.retryNote") {
                Text(model.t("legacy.convert.failed.retryNote"))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
