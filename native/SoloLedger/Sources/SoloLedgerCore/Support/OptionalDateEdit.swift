import Foundation

/// Round-trip policy for the optional stored date strings (`payment_date`,
/// `due_date`) edited through a parse-into-a-picker UI. CSV import and the
/// Electron handler both store these columns unvalidated, so values the strict
/// yyyy-MM-dd parser cannot read (or would rewrite) exist in real ledgers; an
/// UNTOUCHED row must round-trip the stored string byte-for-byte, and only an
/// actual user edit may produce a canonical rewrite.
public enum OptionalDateEdit {
    /// The string to persist on save. `initial` is the parse of `original`
    /// taken when the editor opened; `edited` is the row's current UI state.
    public static func persisted(original: String?, initial: Date?, edited: Date?) -> String? {
        if edited == initial { return original }
        return edited.map { DateFormat.string(from: $0) }
    }

    /// The stored string to display verbatim when it exists but did not parse
    /// (nil once the user picks a date, or when the value parsed normally).
    public static func unparsedFallback(original: String?, initial: Date?, current: Date?) -> String? {
        guard initial == nil, current == nil else { return nil }
        return original
    }
}
