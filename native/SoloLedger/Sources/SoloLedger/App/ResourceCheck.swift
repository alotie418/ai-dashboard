import Foundation

/// Headless regression check that the PACKAGED localization resources actually
/// load. The launch crash we fixed was `Bundle.module` hard-`fatalError`ing
/// inside the assembled .app because the SwiftPM accessor never looks in
/// Contents/Resources. Run via `SoloLedger --check-resources`; scripts/build-app.sh
/// runs it right after assembly so a broken/missing resource bundle fails the
/// build instead of crashing the app on the user's machine.
enum ResourceCheck {
    struct Report {
        var passed: Bool
        var lines: [String]
        var text: String { lines.joined(separator: "\n") }
    }

    static func run() -> Report {
        var lines: [String] = []
        var ok = true
        func check(_ label: String, _ cond: Bool, _ detail: String = "") {
            if !cond { ok = false }
            lines.append("[\(cond ? "PASS" : "FAIL")] \(label)\(detail.isEmpty ? "" : " — \(detail)")")
        }

        lines.append("resourceBundle: \(Localizer.resourceBundle.bundleURL.path)")
        check("localization resource bundle located (not degraded to main bundle)", Localizer.resourcesLoaded)

        let en = Localizer(language: "en")
        check("en app.name", en.t("app.name") == "SoloLedger", en.t("app.name"))
        check("en nav.overview", en.t("nav.overview") == "Overview", en.t("nav.overview"))

        let zh = Localizer(language: "zh-Hans")
        check("zh-Hans nav.overview", zh.t("nav.overview") == "概览", zh.t("nav.overview"))

        let ja = Localizer(language: "ja")
        check("ja nav.overview", ja.t("nav.overview") == "概要", ja.t("nav.overview"))

        // Untranslated key falls back to the source language (zh-Hans).
        let fr = Localizer(language: "fr")
        check("fr untranslated key falls back to zh-Hans source",
              fr.t("overview.dataSourceNote").hasPrefix("数据来源"), fr.t("overview.dataSourceNote"))

        lines.append(ok ? "\nRESOURCE-CHECK RESULT: PASS ✅" : "\nRESOURCE-CHECK RESULT: FAIL ❌")
        return Report(passed: ok, lines: lines)
    }
}
