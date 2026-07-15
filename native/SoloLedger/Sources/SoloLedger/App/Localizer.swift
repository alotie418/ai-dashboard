import Foundation

/// Runtime UI-language resolver. SwiftPM ships one `.lproj` per language under the
/// executable's resource bundle; this loads the requested language's bundle and,
/// on a missing key, falls back to the default localization (zh-Hans — the source
/// of truth mirrored from the JS app's zh-CN). This lets the user switch UI
/// language live without relaunching, independent of the system locale.
final class Localizer {
    /// The six supported UI languages (Apple locale codes) and their display labels.
    static let supported: [(code: String, label: String)] = [
        ("zh-Hans", "简体中文"),
        ("zh-Hant", "繁體中文"),
        ("en", "English"),
        ("ja", "日本語"),
        ("ko", "한국어"),
        ("fr", "Français"),
    ]

    static let defaultCode = "zh-Hans"

    private(set) var language: String
    private var bundle: Bundle
    private let fallbackBundle: Bundle
    private static let missing = "\u{0}__missing__"

    init(language: String) {
        self.language = language
        self.bundle = Localizer.bundle(for: language)
        self.fallbackBundle = Localizer.bundle(for: Localizer.defaultCode)
    }

    func setLanguage(_ code: String) {
        language = code
        bundle = Localizer.bundle(for: code)
    }

    func t(_ key: String) -> String {
        let value = bundle.localizedString(forKey: key, value: Localizer.missing, table: nil)
        if value == Localizer.missing {
            return fallbackBundle.localizedString(forKey: key, value: key, table: nil)
        }
        return value
    }

    /// Interpolate a single {count}-style token (kept minimal for Phase-1).
    func t(_ key: String, _ replacements: [String: String]) -> String {
        var s = t(key)
        for (k, v) in replacements { s = s.replacingOccurrences(of: "{\(k)}", with: v) }
        return s
    }

    private static func bundle(for language: String) -> Bundle {
        if let path = Bundle.module.path(forResource: language, ofType: "lproj"),
           let localized = Bundle(path: path) {
            return localized
        }
        return Bundle.module
    }

    /// Best guess for the initial UI language from the system, constrained to the six.
    static func systemDefault() -> String {
        let preferred = Locale.preferredLanguages.first ?? "zh-Hans"
        if preferred.hasPrefix("zh-Hant") || preferred.hasPrefix("zh-TW") || preferred.hasPrefix("zh-HK") { return "zh-Hant" }
        if preferred.hasPrefix("zh") { return "zh-Hans" }
        if preferred.hasPrefix("ja") { return "ja" }
        if preferred.hasPrefix("ko") { return "ko" }
        if preferred.hasPrefix("fr") { return "fr" }
        if preferred.hasPrefix("en") { return "en" }
        return "zh-Hans"
    }
}
