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

    /// The bundle holding the `.lproj` localizations, resolved to work across all
    /// packaging layouts WITHOUT ever referencing SwiftPM's `Bundle.module` — that
    /// symbol only exists in an SPM target with resources (so it fails to compile
    /// inside a native Xcode app target) and hard-`fatalError`s in an assembled
    /// SPM .app because its accessor never checks Contents/Resources:
    ///  - native Xcode .app: `.lproj` sit directly in Bundle.main -> use Bundle.main
    ///  - assembled SPM .app: `SoloLedger_SoloLedger.bundle` in Contents/Resources
    ///  - `swift run`: that bundle sits next to the executable in .build/<config>
    /// If nothing matches we degrade to the main bundle rather than crash.
    static let resourceBundle: Bundle = {
        let name = "SoloLedger_SoloLedger.bundle"
        let candidates: [URL?] = [
            Bundle.main.resourceURL?.appendingPathComponent(name),  // SPM .app: Contents/Resources
            Bundle.main.bundleURL.appendingPathComponent(name),     // swift run: next to executable
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(name),
        ]
        for case let url? in candidates {
            if let bundle = Bundle(url: url) { return bundle }
        }
        return .main   // native Xcode app: .lproj live directly in the main bundle
    }()

    /// True when an English localization actually resolves — works for BOTH the
    /// SPM-resource-bundle layout and the native-.lproj-in-main-bundle layout.
    /// Used by the packaged-resource regression check.
    static var resourcesLoaded: Bool {
        let sentinel = "\u{0}__missing__"
        return bundle(for: "en").localizedString(forKey: "app.name", value: sentinel, table: nil) != sentinel
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
