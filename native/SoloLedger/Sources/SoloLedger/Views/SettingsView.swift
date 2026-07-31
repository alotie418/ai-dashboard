import SwiftUI
import SoloLedgerCore

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label(model.t("settings.general"), systemImage: "gearshape") }
            AccountingSettingsTab()
                .tabItem { Label(model.t("settings.accounting"), systemImage: "building.columns") }
            DataSettingsTab()
                .tabItem { Label(model.t("settings.data"), systemImage: "externaldrive") }
            AboutSettingsTab()
                .tabItem { Label(model.t("settings.about"), systemImage: "info.circle") }
        }
        .padding(20)
    }
}

private struct GeneralSettingsTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Picker(model.t("settings.appearance"), selection: Binding(
                get: { model.appearance }, set: { model.setAppearance($0) }
            )) {
                ForEach(Appearance.allCases) { a in
                    Text(model.t(a.titleKey)).tag(a)
                }
            }
            .pickerStyle(.segmented)

            Picker(model.t("settings.language"), selection: Binding(
                get: { model.language }, set: { model.setLanguage($0) }
            )) {
                ForEach(Localizer.supported, id: \.code) { lang in
                    Text(lang.label).tag(lang.code)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AccountingSettingsTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            UnreadableLocaleNotice(state: model.accountingLocaleState)
            Picker(model.t("settings.accountingLocale"), selection: Binding(
                get: { model.accountingLocale }, set: { model.setAccountingLocale($0) }
            )) {
                ForEach(AccountingLocale.allCases) { locale in
                    Text(locale.displayName).tag(locale)
                }
            }
            LabeledContent(model.t("settings.currency"), value: model.accountingLocale.defaultCurrency)
            TextField(model.t("settings.company"), text: Binding(
                get: { model.companyName }, set: { model.setCompanyName($0) }
            ))
            Text(model.t("settings.accountingNote"))
                .font(.footnote)
                .foregroundStyle(.secondary)

            Section(model.t("settings.reportParams")) {
                // The turnover-tax label travels with the regime (VAT / Sales Tax /
                // 消費税 / 營業稅) — a fixed string here would mislabel four of six.
                parameterField(.vatRate, label: profile.taxName(language: model.language))
                parameterField(.surchargeRate,
                               label: profile.surchargeName(language: model.language)
                                   ?? model.t("settings.surchargeRate"))
                parameterField(.incomeTaxRate, label: model.t("settings.incomeTaxRate"))
                parameterField(.adminExpenseAnnual, label: model.t("settings.adminExpenseAnnual"))

                Text(model.t("settings.reportParamsPending"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(model.t("settings.reportParamsNote"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var profile: AccountingProfile {
        AccountingProfile.profile(for: model.accountingLocale)
    }

    /// One parameter row. The unit is appended to the label so the number stays a
    /// bare number: "%" for the rates, the regime currency for the annual expense.
    ///
    /// The binding is optional on purpose: an empty field means the ledger has no
    /// value for that key, which is a real state (the report features apply their own
    /// built-in fallback). Clearing a field leaves the stored value alone rather than
    /// writing a 0 the user never chose.
    private func parameterField(_ field: ReportParameterField, label: String) -> some View {
        let unit = field.isPercentage ? "%" : model.accountingLocale.defaultCurrency
        return TextField("\(label) (\(unit))", value: Binding(
            get: { model.reportParameters[field] },
            set: { model.setReportParameter(field, to: $0) }
        ), format: .number.precision(.fractionLength(0...6)))
        .multilineTextAlignment(.trailing)
    }
}

/// What the ledger's `accounting_locale` row really says — shown ONLY when it does not name
/// a regime. In `.configured` this renders nothing at all, so the settled screen is untouched.
///
/// The picker below keeps showing the regime `AppModel.accountingLocale` falls back to. With
/// this notice above it that is no longer a claim the ledger made: the fallback is named as a
/// stand-in, and the row's own bytes are on screen next to it. Re-picking the shown regime
/// writes it without cascading (an unchanged regime never applies presets), which is the one
/// repair that leaves the user's saved tax rates alone — `repairHint` says so, and points at
/// `settings.reportParamsNote` below rather than restating the cascade.
///
/// The stored text goes through the SAME `ReportFormat.safePreview` the report page uses. Not
/// a second escape rule: one damaged row read two ways is the defect this whole line of work
/// exists to remove, and that applies to how it is displayed as much as to how it is parsed.
private struct UnreadableLocaleNotice: View {
    @EnvironmentObject var model: AppModel
    let state: StoredLocaleState

    var body: some View {
        switch state {
        case .configured:
            EmptyView()
        case .absent:
            block(title: "settings.accountingLocale.absent.title", storedText: nil)
        case .unreadable(let storedText):
            block(title: "settings.accountingLocale.unreadable.title", storedText: storedText)
        }
    }

    @ViewBuilder private func block(title: String, storedText: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.t(title)).font(.headline)
            if let storedText {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.t("settings.storedText.label"))
                        .font(.footnote).foregroundStyle(.secondary)
                    Text(ReportFormat.safePreview(storedText))
                        .font(.caption).monospaced()
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }
                .accessibilityIdentifier("settings.storedText")
            }
            Text(model.t("settings.accountingLocale.repairHint"))
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("settings.accountingLocale.notice")
    }
}

private struct DataSettingsTab: View {
    @EnvironmentObject var model: AppModel
    @State private var showRestoreConfirm = false

    var body: some View {
        Form {
            LabeledContent(model.t("settings.schemaVersion"), value: "v\(model.schemaVersionText)")
            Section(model.t("settings.dbLocation")) {
                Text(model.databasePath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
            }
            Section(model.t("settings.csv")) {
                HStack {
                    Button(model.t("cmd.exportCSV")) { model.exportCSVViaPanel() }
                    Button(model.t("cmd.importCSV")) { model.importCSVViaPanel() }
                }
            }
            Section(model.t("settings.backup")) {
                Button(model.t("settings.backup.export")) { model.exportBackupViaPanel() }
                Button(model.t("settings.restore"), role: .destructive) { showRestoreConfirm = true }
            }
            #if DEBUG
            if model.canLoadDemoData {
                Section("Debug") {
                    Button(model.t("overview.loadDemo")) { model.loadDemoData() }
                }
            }
            #endif
        }
        .formStyle(.grouped)
        .confirmationDialog(model.t("settings.restore.confirmTitle"),
                            isPresented: $showRestoreConfirm, titleVisibility: .visible) {
            Button(model.t("settings.restore.confirmAction"), role: .destructive) {
                model.restoreFromBackupBundleViaPanel()
            }
            Button(model.t("common.cancel"), role: .cancel) {}
        } message: {
            Text(model.t("settings.restore.confirmMessage"))
        }
    }
}

private struct AboutSettingsTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            LabeledContent(model.t("about.name"), value: model.t("app.name"))
            LabeledContent(model.t("about.version"), value: "1.0.0 (prototype)")
            LabeledContent(model.t("about.minOS"), value: "macOS 13.0+")
            Section {
                Text(model.t("about.positioning"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}
