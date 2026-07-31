import Foundation

/// Every string the report page makes out of a number or a stored byte sequence.
///
/// Nothing here reads settings, the ledger, or the clock. It is given a value and a UI
/// language and returns text — which is what makes the rules below testable as rules rather
/// than as screenshots.
enum ReportFormat {

    // MARK: - Money and percent

    /// Two decimals, always, and **no currency symbol**.
    ///
    /// The currency travels separately (``currencyDisplay(_:)``) and is never handed to
    /// `NumberFormatter`. That is the whole design: `numberStyle = .currency` would consult
    /// ICU's table for the code, substitute a symbol for the ones it knows and improvise for
    /// the ones it does not — turning "what does the ledger say the currency is" into "what
    /// does this OS version think it is". Here the question never gets asked, so an unknown
    /// code cannot change a single digit.
    ///
    /// Deliberately NOT `Money.string` (`Formatters.swift`), whose `minimumFractionDigits` is
    /// 0 and whose style is `.currency`. Both are wrong for a report and the overview's
    /// behaviour must not change, so the two coexist.
    static func money(_ value: Double, language: String) -> String {
        digits(value, language: language)
    }

    /// A percentage that is ALREADY in percentage points.
    ///
    /// The engines emit `netMargin` / `grossMargin` through `ReportMath.percent2`, which has
    /// already multiplied by 100. `NumberFormatter`'s `.percent` style multiplies AGAIN, so a
    /// 12.34% margin would print as 1234%. This function therefore never uses that style: it
    /// formats the number exactly as `money` does and appends the sign itself.
    static func percent(_ value: Double, language: String) -> String {
        digits(value, language: language) + "%"
    }

    /// The shared digit pipeline: round once, kill a rounded-away minus sign, then format.
    ///
    /// Rounding happens HERE rather than being left to `NumberFormatter`, because the
    /// formatter's rounding mode and this function's zero test have to agree about what
    /// "rounds to zero" means. Doing it once, explicitly, removes the possibility that they
    /// disagree on a half-way value.
    private static func digits(_ value: Double, language: String) -> String {
        formatter(language: language).string(from: NSNumber(value: rounded(value)))
            ?? fallback(rounded(value))
    }

    /// Round to two decimals, and normalise a NEGATIVE value whose rounded result is zero.
    ///
    /// `-0.004` must print `0.00`, not `-0.00`: a minus sign in front of a zero reads as a
    /// loss that is not there. This is the same rule `ReportPresentation.field(_:)` already
    /// applies to an exact `-0.0` in the Core, extended to the rounding boundary where the
    /// sign is likewise an artefact — and it is applied at the DISPLAY boundary only.
    ///
    /// It does not clamp: `-0.005` rounds away from zero to `-0.01` and keeps its sign, and
    /// no value that rounds to a non-zero figure is touched. No computed number changes.
    private static func rounded(_ value: Double) -> Double {
        let scaled = value * 100
        // Above 2^53 the scaling is no longer exact, and a value that large cannot be a
        // rounded-away zero anyway. Hand it over untouched rather than corrupt it.
        guard scaled.isFinite, abs(scaled) < 9_007_199_254_740_992 else { return value }
        let cents = scaled.rounded(.toNearestOrAwayFromZero)
        return cents == 0 ? 0 : cents / 100
    }

    private static func formatter(language: String) -> NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: language)
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f
    }

    /// Reached only if `NumberFormatter` returns nil, which it does not for a finite Double.
    /// Present so the function is total and never renders an empty cell.
    private static func fallback(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    // MARK: - Currency code

    /// What can honestly be said about a currency code, and nothing more.
    ///
    /// `ReportBuilder` proves the stored code against the money actually recorded in the
    /// period, but it never checks it against ISO 4217 — `resolveCurrency` requires only a
    /// JSON string that trims to something non-empty. And on a period whose rows are all
    /// outside both windows the set it is compared against is empty, so any non-empty string
    /// survives. `XYZ` therefore reaches here as a legitimate value of the ledger.
    ///
    /// So this enum says FORMAT and only format. Nothing in this file, and nothing that reads
    /// it, may describe a code as valid, standard, or ISO — that would be a claim no code in
    /// this app is in a position to make.
    enum CurrencyCodeShape: Equatable {
        /// Matches `^[A-Za-z]{3}$`. A statement about shape, NOT about ISO 4217.
        case threeLetter
        /// Anything else, including an empty-after-trim-but-not-empty string like `" CNY "`
        /// (which `resolveCurrency` accepts and returns untrimmed).
        case other
    }

    static func currencyShape(_ code: String) -> CurrencyCodeShape {
        guard code.count == 3, code.allSatisfy({ $0.isASCII && $0.isLetter }) else { return .other }
        return .threeLetter
    }

    /// The caption text for a currency code.
    ///
    /// A three-letter code is passed through BYTE FOR BYTE — not upper-cased. Normalising
    /// would display a code the ledger does not hold, which is the same class of mistake as
    /// stripping the quotes off a `storedText`.
    ///
    /// Anything else goes through the same bounded escape as a stored setting, because at
    /// that point it is an arbitrary string out of the database and has to be treated like
    /// one.
    static func currencyDisplay(_ code: String) -> String {
        switch currencyShape(code) {
        case .threeLetter: return code
        case .other:       return safePreview(code)
        }
    }

    // MARK: - Stored text

    /// How many SOURCE `Character`s a preview may consume. The rendered string can be longer
    /// than this when characters are escaped — the cap bounds what is read, which is the
    /// thing that could otherwise be unbounded.
    static let previewCharacterLimit = 120

    /// A bounded, escaped view of a raw `settings.value` — or any other untrusted string.
    ///
    /// **What it does not do, and why.** It does not trim, does not normalise Unicode, does
    /// not re-parse JSON, and above all does not strip quotes. The `malformed` golden variant
    /// stores the five bytes `"25%"` and the `malformed-raw` variant stores the three bytes
    /// `25%`; those are different rows, they look different to a user, and the difference is
    /// the only evidence a repair flow has to show. Any tidying here destroys it.
    ///
    /// What it DOES do is stop the string from acting on the UI: C0/C1 controls, DEL, the
    /// line and paragraph separators, and the bidirectional overrides/embeddings/isolates all
    /// become `<U+XXXX>` literals. The bidi set matters as much as the control set — a
    /// `U+202E` in a stored value can visually reverse the text after it and make one code
    /// read as another.
    static func safePreview(_ raw: String) -> String {
        var out = ""
        var consumed = 0
        var truncated = false
        for character in raw {
            if consumed == previewCharacterLimit { truncated = true; break }
            out += escaped(character)
            consumed += 1
        }
        return truncated ? out + "…" : out
    }

    private static func escaped(_ character: Character) -> String {
        guard character.unicodeScalars.contains(where: mustEscape) else { return String(character) }
        return character.unicodeScalars.map { scalar in
            mustEscape(scalar) ? String(format: "<U+%04X>", scalar.value)
                               : String(Character(scalar))
        }.joined()
    }

    private static func mustEscape(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1F, 0x7F...0x9F:  return true   // C0 controls, DEL, C1 controls
        case 0x2028, 0x2029:            return true   // line / paragraph separator
        case 0x202A...0x202E:           return true   // bidi embeddings and overrides
        case 0x2066...0x2069:           return true   // bidi isolates
        // U+FEFF renders as nothing at all, and on `accounting_locale` it is the whole
        // defect: `JSONSerialization` eats a leading one, `JSON.parse` does not, so one
        // invisible byte made the Settings screen say United States while the engines
        // refused the same row. A preview whose job is to show the user what is really in
        // their ledger cannot leave the damage invisible.
        case 0xFEFF:                    return true   // zero-width no-break space / BOM
        default:                        return false
        }
    }
}
