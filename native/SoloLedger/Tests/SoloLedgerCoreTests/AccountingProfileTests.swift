import XCTest
@testable import SoloLedgerCore

/// Pins the accounting-profile presets and the report-parameter resolution rules.
///
/// The numbers below are MIRRORED from `components/accountingProfiles.ts`
/// (ACCOUNTING_PROFILES) — this test exists so a native-side edit to a tax rate is a
/// red test rather than a silent accounting-policy change (CLAUDE.md: rates and
/// accounting profiles may not be modified without explicit approval).
final class AccountingProfileTests: XCTestCase {

    /// (locale, vatRate, surchargeRate, incomeTaxRate, currency) exactly as the
    /// Electron table declares them.
    private let expected: [(AccountingLocale, Double, Double, Double, String)] = [
        (.CN, 13,  12, 25,   "CNY"),
        (.US,  0,   0, 21,   "USD"),
        (.JP, 10,   0, 23.2, "JPY"),
        (.EU, 20,   0, 25,   "EUR"),
        (.KR, 10,   0, 22,   "KRW"),
        (.TW,  5,   0, 20,   "TWD"),
    ]

    func testEveryRegimeMatchesTheElectronPresetTable() {
        for (locale, vat, surcharge, incomeTax, currency) in expected {
            let p = AccountingProfile.profile(for: locale)
            XCTAssertEqual(p.vatRate, vat, "\(locale) vatRate")
            XCTAssertEqual(p.surchargeRate, surcharge, "\(locale) surchargeRate")
            XCTAssertEqual(p.incomeTaxRate, incomeTax, "\(locale) incomeTaxRate")
            XCTAssertEqual(p.currency, currency, "\(locale) currency")
        }
    }

    func testVatRateOptionBandsMatchTheElectronTable() {
        XCTAssertEqual(AccountingProfile.cn.vatRateOptions, [13, 9, 6, 3, 0])
        XCTAssertEqual(AccountingProfile.us.vatRateOptions, [0, 4, 6, 7, 8, 9, 10])
        XCTAssertEqual(AccountingProfile.jp.vatRateOptions, [10, 8])
        XCTAssertEqual(AccountingProfile.eu.vatRateOptions, [25, 24, 23, 22, 21, 20, 19, 17, 10, 7, 5, 0])
        XCTAssertEqual(AccountingProfile.kr.vatRateOptions, [10, 0])
        XCTAssertEqual(AccountingProfile.tw.vatRateOptions, [5, 0])
    }

    func testSurchargeIsChinaOnly() {
        // Only the CN engine applies a surcharge (electron/reports/cn.js); every other
        // regime's preset is 0 and scripts/test-surcharge-locale.mjs locks that.
        XCTAssertEqual(AccountingProfile.cn.surchargeRate, 12)
        for locale in AccountingLocale.allCases where locale != .CN {
            XCTAssertEqual(AccountingProfile.profile(for: locale).surchargeRate, 0, "\(locale)")
        }
    }

    func testProfileCurrencyAgreesWithTheLocaleDefaultCurrency() {
        // The native app derives the displayed currency from the locale; the profile
        // table carries its own copy. A divergence would show one currency and store
        // parameters meant for another.
        for locale in AccountingLocale.allCases {
            XCTAssertEqual(AccountingProfile.profile(for: locale).currency, locale.defaultCurrency, "\(locale)")
        }
    }

    func testEveryRegimeHasATaxNameInAllSixUILanguages() {
        let languages = ["zh-Hans", "zh-Hant", "en", "ja", "ko", "fr"]
        for locale in AccountingLocale.allCases {
            let p = AccountingProfile.profile(for: locale)
            for lang in languages {
                let name = p.taxName(language: lang)
                XCTAssertFalse(name.isEmpty, "\(locale)/\(lang) has no tax name")
            }
        }
        // The regime-specific names are the point: Taiwan's 5% is a business tax,
        // not VAT, and the US has no VAT at all.
        XCTAssertEqual(AccountingProfile.tw.taxName(language: "zh-Hans"), "营业税")
        XCTAssertEqual(AccountingProfile.us.taxName(language: "en"), "Sales Tax")
        XCTAssertEqual(AccountingProfile.jp.taxName(language: "ja"), "消費税")
        // Only the US overrides the surcharge label, and only in the two Chinese locales.
        XCTAssertEqual(AccountingProfile.us.surchargeName(language: "zh-Hans"), "地方税率")
        XCTAssertNil(AccountingProfile.us.surchargeName(language: "en"))
        XCTAssertNil(AccountingProfile.cn.surchargeName(language: "zh-Hans"))
    }

    // MARK: - Preset cascade gating

    func testRecommittingTheSameRegimeNeverRewritesRates() {
        // Onboarding re-commits the unchanged regime on every first launch, and every
        // ledger migrated from Electron sees onboarding (the JS app has no
        // `onboarding_done`). A cascade there would silently replace rates the user
        // configured in the other app — e.g. a CN small-scale taxpayer's 3% / 5%.
        for locale in AccountingLocale.allCases {
            XCTAssertFalse(AccountingProfile.shouldApplyPresets(from: locale, to: locale, requested: true),
                           "\(locale): an unchanged regime must not trigger the cascade")
        }
    }

    func testCallSitesThatOnlyBrowseAnotherRegimeNeverRewriteRates() {
        // The Categories toolbar picker switches which category set is shown; it opts
        // out, so flipping to another regime there leaves the stored rates untouched.
        XCTAssertFalse(AccountingProfile.shouldApplyPresets(from: .CN, to: .US, requested: false))
    }

    func testAnActualRegimeSwitchFromAnOptedInPickerCascades() {
        XCTAssertTrue(AccountingProfile.shouldApplyPresets(from: .CN, to: .US, requested: true))
        XCTAssertTrue(AccountingProfile.shouldApplyPresets(from: .TW, to: .JP, requested: true))
    }

    // MARK: - ReportParametersStored

    func testAbsenceIsRepresentedAsAbsenceNotAsAPreset() {
        // The Settings tab must never show a rate the ledger does not hold: an absent
        // key stays nil rather than being resolved to the regime preset, because the
        // report engines apply their OWN fallbacks to an absent row.
        let stored = ReportParametersStored()
        for field in ReportParameterField.allCases {
            XCTAssertNil(stored[field], "\(field) must stay absent")
        }
    }

    func testSubscriptRoundTripsEveryField() {
        var p = ReportParametersStored()
        for (i, field) in ReportParameterField.allCases.enumerated() {
            p[field] = Double(i) + 0.5
        }
        for (i, field) in ReportParameterField.allCases.enumerated() {
            XCTAssertEqual(p[field], Double(i) + 0.5, "\(field)")
        }
        p[.vatRate] = nil
        XCTAssertNil(p[.vatRate])
        XCTAssertEqual(p[.surchargeRate], 1.5, "clearing one field must not disturb another")
    }

    func testFieldSettingsKeysMatchTheElectronSettingsKeys() {
        XCTAssertEqual(ReportParameterField.vatRate.settingsKey, "vat_rate")
        XCTAssertEqual(ReportParameterField.surchargeRate.settingsKey, "surcharge_rate")
        XCTAssertEqual(ReportParameterField.incomeTaxRate.settingsKey, "income_tax_rate")
        XCTAssertEqual(ReportParameterField.adminExpenseAnnual.settingsKey, "admin_expense_annual")
        XCTAssertFalse(ReportParameterField.adminExpenseAnnual.isPercentage)
        for field in ReportParameterField.allCases where field != .adminExpenseAnnual {
            XCTAssertTrue(field.isPercentage, "\(field)")
        }
    }
}
