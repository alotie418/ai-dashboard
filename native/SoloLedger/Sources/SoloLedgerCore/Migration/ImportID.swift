import Foundation

/// A validated import identifier. Constrained to a safe, single-path-segment character set
/// (`[A-Za-z0-9-]`, 1…64 chars, no `..`) so it can NEVER escape the Staging root — no `/`,
/// no `..`, no over-long values. Construct via `generate()` (UUID-backed) or the failable
/// `init?` which rejects anything unsafe.
public struct ImportID: Hashable, CustomStringConvertible {
    public let rawValue: String

    public static let maxLength = 64

    /// Fails for empty, over-long (> `maxLength`), or unsafe values (any char outside
    /// `[A-Za-z0-9-]`, or a `..` substring).
    public init?(_ raw: String) {
        guard ImportID.isValid(raw) else { return nil }
        self.rawValue = raw
    }

    private init(unchecked raw: String) { self.rawValue = raw }

    /// A fresh, always-valid ID from a UUID (lowercase hex + `-` only, length 36).
    public static func generate() -> ImportID { ImportID(unchecked: UUID().uuidString.lowercased()) }

    public static func isValid(_ raw: String) -> Bool {
        guard !raw.isEmpty, raw.count <= maxLength, !raw.contains("..") else { return false }
        for ch in raw.unicodeScalars {
            let ok = (ch >= "A" && ch <= "Z") || (ch >= "a" && ch <= "z")
                || (ch >= "0" && ch <= "9") || ch == "-"
            if !ok { return false }
        }
        return true
    }

    public var description: String { rawValue }
}
