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
        }
        .formStyle(.grouped)
    }
}

private struct DataSettingsTab: View {
    @EnvironmentObject var model: AppModel

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
        }
        .formStyle(.grouped)
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
