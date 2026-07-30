import Foundation

/// The year a report period may be asked for, and the ONE place the wall clock is read.
///
/// ## Where the bounds come from
///
/// They are not a product guess and they are not "the last N years". `ReportPeriod(year:)`
/// builds its bounds by string interpolation — `"\(year)-01-01"` and `"\(year)-12-31"` — and
/// the report windows compare those against `transactions.date` as **TEXT**. Dates are
/// written by `DateFormat` with `yyyy-MM-dd` under `en_US_POSIX`/gregorian, so the year is
/// zero-padded to four digits. Lexicographic order over two TEXT dates equals chronological
/// order **only when both years have the same digit count**.
///
/// So a three-digit year (`"999-01-01"`) or a five-digit one (`"10000-01-01"`) would compare
/// wrongly and silently select the wrong rows. Four ASCII digits, `0001`–`9999`, is exactly
/// the domain in which the comparison is sound — which is why entry outside it is refused
/// rather than clamped: clamping would run a report for a year the user did not ask for.
///
/// A ledger from 1998 is therefore selectable. If that year's records live in the legacy
/// tables this app does not read, the builder answers with `legacySourceUnavailable`, which
/// is the honest answer and needs no extra state here.
enum ReportYear {
    static let minimum = 1
    static let maximum = 9999
    /// Four ASCII digits — see the note above; this is a storage-format fact, not a style.
    static let width = 4

    /// The numeric year, or `nil` when `text` is outside the sound domain.
    ///
    /// `Character.isNumber` alone would accept `"٢٠٢٥"`, whose digits are not ASCII and would
    /// not survive interpolation into a comparable date string, so `isASCII` is required too.
    static func value(_ text: String) -> Int? {
        guard text.count == width,
              text.allSatisfy({ $0.isASCII && $0.isNumber }),
              let year = Int(text),
              year >= minimum, year <= maximum else { return nil }
        return year
    }

    static func isValid(_ text: String) -> Bool { value(text) != nil }

    /// Zero-padded to `width`, so the result is always in the sound domain.
    static func text(_ year: Int) -> String {
        String(format: "%0\(width)d", min(max(year, minimum), maximum))
    }

    /// One step away from `text`, or `text` unchanged when it is not a valid year or the step
    /// would leave the domain. Never silently wraps.
    static func stepped(_ text: String, by delta: Int) -> String {
        guard let year = value(text) else { return text }
        let next = year + delta
        guard next >= minimum, next <= maximum else { return text }
        return Self.text(next)
    }

    /// **The only wall-clock read in the report feature.** `AppModel` calls it exactly once,
    /// in a property initialiser, and never again — so a report page open across midnight on
    /// 31 December does not silently change which year it is describing.
    ///
    /// The parameters exist so tests can pin the mapping without waiting for a date.
    static func currentYearText(now: Date = Date(),
                                calendar: Calendar = Calendar(identifier: .gregorian)) -> String {
        text(calendar.component(.year, from: now))
    }
}
