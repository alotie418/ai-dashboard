import Foundation

/// income / expense — mirrors transactions.type CHECK and VALID_TYPES.
public enum TransactionType: String, CaseIterable, Codable, Identifiable, Sendable {
    case income
    case expense
    public var id: String { rawValue }
}

/// paid / partial / unpaid — mirrors VALID_PAYMENT_STATUS in transactions.js.
public enum PaymentStatus: String, CaseIterable, Codable, Identifiable, Sendable {
    case paid
    case partial
    case unpaid
    public var id: String { rawValue }
}

/// issued / pending / n/a — mirrors VALID_INVOICE_STATUS. Raw value keeps the
/// exact "n/a" string the JS handler stores.
public enum InvoiceStatus: String, CaseIterable, Codable, Identifiable, Sendable {
    case issued
    case pending
    case na = "n/a"
    public var id: String { rawValue }
}

/// The accounting-regime axis (distinct from the UI-language axis). Selects which
/// `categories.locale` set and default currency a new transaction uses. Mirrors
/// the JS app's `accounting_locale` setting and its per-locale currency defaults.
public enum AccountingLocale: String, CaseIterable, Codable, Identifiable, Sendable {
    case CN, US, JP, EU, KR, TW
    public var id: String { rawValue }

    /// Default currency seeded on new transactions for this regime
    /// (US→USD, JP→JPY, EU→EUR, KR→KRW, TW→TWD, else CNY).
    public var defaultCurrency: String {
        switch self {
        case .US: return "USD"
        case .JP: return "JPY"
        case .EU: return "EUR"
        case .KR: return "KRW"
        case .TW: return "TWD"
        case .CN: return "CNY"
        }
    }

    public var displayName: String {
        switch self {
        case .CN: return "中国大陆 (CN)"
        case .US: return "United States (US)"
        case .JP: return "日本 (JP)"
        case .EU: return "European Union (EU)"
        case .KR: return "대한민국 (KR)"
        case .TW: return "台灣 (TW)"
        }
    }
}
