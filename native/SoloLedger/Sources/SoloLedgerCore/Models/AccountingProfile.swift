import Foundation

/// The per-regime accounting presets, MIRRORED verbatim from the Electron app's
/// `components/accountingProfiles.ts` (`ACCOUNTING_PROFILES`). Rates are whole
/// percent (13 means 13%), matching the `rate / 100` convention the report
/// engines use in `electron/reports/*`.
///
/// This table is the only sanctioned source of default rates for the native app.
/// Do NOT invent, "correct", or re-derive a value here — every number below has a
/// counterpart in the Electron file and changing one is an accounting-policy
/// decision that needs user/accountant approval (CLAUDE.md). `AccountingProfileTests`
/// pins the whole table so drift is a red test.
public struct AccountingProfile: Sendable, Equatable {
    public let locale: AccountingLocale
    /// Standard turnover-tax rate (VAT / sales tax / consumption tax / business tax).
    public let vatRate: Double
    /// The regime's selectable rate bands, carried so the mirrored table stays complete.
    /// The native app applies NO range policy to a stored rate — it shows and keeps
    /// whatever the ledger holds, which is what the report engines read.
    public let vatRateOptions: [Double]
    /// Surcharge on the turnover tax — 12 for CN, 0 everywhere else.
    public let surchargeRate: Double
    /// Corporate/profit income-tax rate.
    public let incomeTaxRate: Double
    public let currency: String

    /// The regime's own name for its turnover tax, keyed by native UI language
    /// (`taxLabel` in accountingProfiles.ts; its `zh-CN`/`zh-TW` map to zh-Hans/zh-Hant).
    /// Calling Taiwan's 5% "VAT" or the US sales tax "增值税" would be factually wrong,
    /// so the label travels with the regime rather than living in the string table.
    public let taxLabel: [String: String]
    /// Per-regime override of the surcharge field label (`surchargeLabel`); languages
    /// absent here fall back to the generic localized label.
    public let surchargeLabel: [String: String]

    // Declared one-by-one rather than as a single nested literal: a six-entry
    // dictionary of structs holding two string dictionaries each blows past the
    // type-checker's expression budget.
    public static let all: [AccountingLocale: AccountingProfile] = {
        var m = [AccountingLocale: AccountingProfile]()
        for p in [cn, us, jp, eu, kr, tw] { m[p.locale] = p }
        return m
    }()

    public static let cn = AccountingProfile(
            locale: .CN,
            vatRate: 13,
            vatRateOptions: [13, 9, 6, 3, 0],
            surchargeRate: 12,           // 城建 7% + 教育费附加 3% + 地方教育附加 2%
            incomeTaxRate: 25,
            currency: "CNY",
            taxLabel: ["zh-Hans": "增值税", "zh-Hant": "增值稅", "en": "VAT",
                       "ja": "増値税", "ko": "부가가치세", "fr": "TVA"],
            surchargeLabel: [:]
    )

    public static let us = AccountingProfile(
            locale: .US,
            vatRate: 0,                  // no federal VAT; state rates vary, user adjusts
            vatRateOptions: [0, 4, 6, 7, 8, 9, 10],
            surchargeRate: 0,
            incomeTaxRate: 21,           // federal corporate tax; state tax is separate
            currency: "USD",
            taxLabel: ["zh-Hans": "销售税", "zh-Hant": "銷售稅", "en": "Sales Tax",
                       "ja": "売上税", "ko": "판매세", "fr": "Sales Tax"],
            surchargeLabel: ["zh-Hans": "地方税率", "zh-Hant": "地方稅率"]
    )

    public static let jp = AccountingProfile(
            locale: .JP,
            vatRate: 10,
            vatRateOptions: [10, 8],
            surchargeRate: 0,
            incomeTaxRate: 23.2,         // 法人税率 (中央 + 地方简化合并)
            currency: "JPY",
            taxLabel: ["zh-Hans": "消费税", "zh-Hant": "消費稅", "en": "Consumption Tax",
                       "ja": "消費税", "ko": "소비세", "fr": "Taxe à la consommation"],
            surchargeLabel: [:]
    )

    public static let eu = AccountingProfile(
            locale: .EU,
            vatRate: 20,
            vatRateOptions: [25, 24, 23, 22, 21, 20, 19, 17, 10, 7, 5, 0],
            surchargeRate: 0,
            incomeTaxRate: 25,
            currency: "EUR",
            taxLabel: ["zh-Hans": "增值税", "zh-Hant": "增值稅", "en": "VAT",
                       "ja": "VAT", "ko": "VAT", "fr": "TVA"],
            surchargeLabel: [:]
    )

    public static let kr = AccountingProfile(
            locale: .KR,
            vatRate: 10,
            vatRateOptions: [10, 0],
            surchargeRate: 0,
            incomeTaxRate: 22,           // 법인세 최고세율 simplified
            currency: "KRW",
            taxLabel: ["zh-Hans": "附加价值税", "zh-Hant": "附加價值稅", "en": "VAT",
                       "ja": "付加価値税", "ko": "부가가치세", "fr": "TVA"],
            surchargeLabel: [:]
    )

    public static let tw = AccountingProfile(
            locale: .TW,
            vatRate: 5,
            vatRateOptions: [5, 0],
            surchargeRate: 0,
            incomeTaxRate: 20,           // 營利事業所得稅
            currency: "TWD",
            taxLabel: ["zh-Hans": "营业税", "zh-Hant": "營業稅", "en": "Business Tax",
                       "ja": "営業税", "ko": "영업세", "fr": "Taxe sur les activités"],
            surchargeLabel: [:]
    )

    public static func profile(for locale: AccountingLocale) -> AccountingProfile {
        // `all` covers every case of AccountingLocale; CN is the documented default
        // (DEFAULT_ACCOUNTING_LOCALE in accountingProfiles.ts).
        all[locale] ?? cn
    }

    /// Whether committing `new` as the accounting regime may rewrite that regime's
    /// preset rates over whatever the ledger already holds.
    ///
    /// Both guards are load-bearing. `requested` keeps the cascade on the regime
    /// pickers that mean "apply this regime's presets" and off the ones that only
    /// change which category set is shown. The inequality keeps a re-commit of the
    /// SAME regime — which onboarding performs on every first launch, including the
    /// first launch of every ledger migrated from the Electron app — from wiping
    /// rates the user configured there.
    public static func shouldApplyPresets(from current: AccountingLocale,
                                          to new: AccountingLocale,
                                          requested: Bool) -> Bool {
        requested && current != new
    }

    /// The regime's turnover-tax name in `language`, falling back to English.
    public func taxName(language: String) -> String {
        taxLabel[language] ?? taxLabel["en"] ?? ""
    }

    /// The regime's surcharge label override in `language`, or nil to use the
    /// generic localized label.
    public func surchargeName(language: String) -> String? {
        surchargeLabel[language]
    }
}

/// The individually editable report parameters, paired with their `settings` keys.
public enum ReportParameterField: String, CaseIterable, Sendable {
    case vatRate, surchargeRate, incomeTaxRate, adminExpenseAnnual

    public var settingsKey: String {
        switch self {
        case .vatRate: return SettingsStore.Key.vatRate
        case .surchargeRate: return SettingsStore.Key.surchargeRate
        case .incomeTaxRate: return SettingsStore.Key.incomeTaxRate
        case .adminExpenseAnnual: return SettingsStore.Key.adminExpenseAnnual
        }
    }

    /// True for the three whole-percent rates; `adminExpenseAnnual` is a currency amount.
    public var isPercentage: Bool { self != .adminExpenseAnnual }
}

/// The four report parameters exactly as stored: nil means the row is absent, which
/// is a real state the report engines handle with their own built-in fallbacks. It is
/// deliberately NOT resolved to a regime preset here — showing a preset the ledger
/// does not hold would display a rate the engines would not use.
public struct ReportParametersStored: Sendable, Equatable {
    public var vatRate: Double?
    public var surchargeRate: Double?
    public var incomeTaxRate: Double?
    public var adminExpenseAnnual: Double?

    public init(vatRate: Double? = nil, surchargeRate: Double? = nil,
                incomeTaxRate: Double? = nil, adminExpenseAnnual: Double? = nil) {
        self.vatRate = vatRate
        self.surchargeRate = surchargeRate
        self.incomeTaxRate = incomeTaxRate
        self.adminExpenseAnnual = adminExpenseAnnual
    }

    public subscript(field: ReportParameterField) -> Double? {
        get {
            switch field {
            case .vatRate: return vatRate
            case .surchargeRate: return surchargeRate
            case .incomeTaxRate: return incomeTaxRate
            case .adminExpenseAnnual: return adminExpenseAnnual
            }
        }
        set {
            switch field {
            case .vatRate: vatRate = newValue
            case .surchargeRate: surchargeRate = newValue
            case .incomeTaxRate: incomeTaxRate = newValue
            case .adminExpenseAnnual: adminExpenseAnnual = newValue
            }
        }
    }
}
