import SwiftUI
import SoloLedgerCore

/// First-run onboarding: pick UI language + accounting regime (+ optional company
/// name), then enter the app. No AI-provider / account / unlock step — the native
/// app is local-only by design.
struct OnboardingView: View {
    @EnvironmentObject var model: AppModel

    @State private var language = Localizer.defaultCode
    @State private var accountingLocale: AccountingLocale = .CN
    @State private var company = ""
    @State private var didInit = false

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 8) {
                Image(systemName: "book.closed")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                Text(model.t("app.name")).font(.largeTitle).fontWeight(.bold)
                Text(model.t("onboarding.tagline"))
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Form {
                Picker(model.t("settings.language"), selection: $language) {
                    ForEach(Localizer.supported, id: \.code) { lang in
                        Text(lang.label).tag(lang.code)
                    }
                }
                Picker(model.t("settings.accountingLocale"), selection: $accountingLocale) {
                    ForEach(AccountingLocale.allCases) { locale in
                        Text(locale.displayName).tag(locale)
                    }
                }
                LabeledContent(model.t("settings.currency"), value: accountingLocale.defaultCurrency)
                TextField(model.t("onboarding.company"), text: $company)
            }
            .formStyle(.grouped)
            .frame(maxWidth: 440, maxHeight: 240)

            Button(model.t("onboarding.start")) { finish() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)

            Text(model.t("onboarding.privacy"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: language) { newValue in
            model.setLanguage(newValue, persist: false) // live preview
        }
        .onAppear {
            guard !didInit else { return }
            didInit = true
            language = model.language
            accountingLocale = model.accountingLocale
            company = model.companyName
        }
    }

    private func finish() {
        model.setLanguage(language)
        model.setAccountingLocale(accountingLocale)
        model.setCompanyName(company)
        model.completeOnboarding()
    }
}
