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

    /// The resource bundle holding the `.lproj` localizations.
    ///
    /// We resolve it EXPLICITLY from `Bundle.main` (Contents/Resources in a
    /// packaged .app, or next to the executable under `swift run`) instead of the
    /// SwiftPM-generated `Bundle.module`. That generated accessor looks only at
    /// the .app ROOT and a build-time absolute `.build/...` path and hard
    /// `fatalError`s when neither exists — which crashed the packaged app on
    /// launch (the bundle lives in Contents/Resources, which the accessor never
    /// checks). We fall back to `Bundle.module` ONLY when not running from a .app
    /// (where it is safe), and otherwise degrade to the main bundle — never crash.
    static let resourceBundle: Bundle = {
        let name = "SoloLedger_SoloLedger.bundle"
        let candidates: [URL?] = [
            Bundle.main.resourceURL?.appendingPathComponent(name),  // .app/Contents/Resources
            Bundle.main.bundleURL.appendingPathComponent(name),     // next-to-exe (swift run) / app root
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(name),
        ]
        for case let url? in candidates {
            if let bundle = Bundle(url: url) { return bundle }
        }
        let isAppBundle = Bundle.main.bundleURL.pathExtension == "app"
        return isAppBundle ? Bundle.main : Bundle.module
    }()

    /// True when the localization resource bundle was actually located (not the
    /// degraded main-bundle fallback). Used by the packaged-resource regression check.
    static var resourcesLoaded: Bool {
        resourceBundle.bundleURL.lastPathComponent == "SoloLedger_SoloLedger.bundle"
    }

    private static func bundle(for language: String) -> Bundle {
        // SwiftPM lowercases .lproj dir names (zh-Hans -> zh-hans.lproj), so try
        // the exact code and a lowercased variant.
        for candidate in [language, language.lowercased()] {
            if let path = resourceBundle.path(forResource: candidate, ofType: "lproj"),
               let localized = Bundle(path: path) {
                return localized
            }
        }
        return resourceBundle
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
