import SwiftUI

/// Appearance preference. The Electron app is light-only; the native app adds
/// Dark Mode support (a Phase-1 requirement) with a System/Light/Dark choice.
enum Appearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark
    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var titleKey: String {
        switch self {
        case .system: return "settings.appearance.system"
        case .light: return "settings.appearance.light"
        case .dark: return "settings.appearance.dark"
        }
    }
}
