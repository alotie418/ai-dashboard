import Foundation

/// Internal document numbering — `docs/BUSINESS_DOCUMENTS_SPEC.md` Q3, ported from
/// `electron/handlers/documents.js`'s `NUMBER_PREFIX` and `nextNumber`.
///
/// **The number this produces is a SUGGESTION.** The handler's own comment says so
/// (「仅作建议值，可编辑；不是正式发票号码」) and the editor stops following it the moment the user
/// types over it (`DocumentModal.tsx numberEditedRef`). Nothing here reserves anything, and two
/// callers a millisecond apart get the same answer.
///
/// ## What the suggestion is NOT
///
/// It is not a formal tax-invoice number. Those live in the four `tax_invoice_*` columns, are typed
/// in by hand from a document somebody else issued, and are **never generated** — see
/// ``LedgerStore/updateTaxInvoice(documentID:_:)``, whose whole contract is to record one.
/// `DocumentWriteSurfaceGuardTests` pins that separation as a machine check rather than a comment.
///
/// ## Continuity is not promised, and only deletion gives a number back
///
/// Gaps are normal. The query behind the suggestion filters on `doc_type` and a `doc_number LIKE`
/// pattern and **has no `status` condition**, and `idx_docs_type_number` is a plain unique index
/// with no `WHERE` clause. So a voided document still holds its number — it cannot be re-used, and
/// it still pushes the suggestion up. Deleting the row is the only thing that releases it. All
/// three facts are measured in `DocumentNumberingTests` against the live tables.
public enum DocumentNumbering {

    /// `NUMBER_PREFIX`. A `switch` rather than a dictionary so the compiler, not a test, is what
    /// notices a sixth document type — though `DocumentNumberingTests` still pins all five spellings,
    /// because exhaustiveness says nothing about which letters each case returns.
    public static func prefix(for type: BusinessDocumentType) -> String {
        switch type {
        case .quotation: return "QT"
        case .salesOrder: return "SO"
        case .proformaInvoice: return "PI"
        case .commercialInvoice: return "CI"
        case .statement: return "ST"
        }
    }

    /// `new Date().getFullYear()` — the year **in the machine's own time zone**, on an explicitly
    /// named Gregorian calendar.
    ///
    /// Both halves are load-bearing and neither is the Swift default:
    ///
    ///  * `Calendar.current` follows the user's region settings, and a region set to the Japanese
    ///    calendar answers `8` (Reiwa 8) where `getFullYear()` answers `2026`. The calendar is
    ///    therefore named, not inherited. `DocumentWriteSurfaceGuardTests` pins that naming as
    ///    source, because no in-process test can tell `.gregorian` from `Calendar.current` on a
    ///    machine whose region already uses the Gregorian calendar.
    ///  * The time zone is NOT named: it is the local one, exactly as `getFullYear()` uses it. Q3
    ///    registers the consequence rather than designing it away — on New Year's Eve, two machines
    ///    in different zones suggest numbers from different years.
    ///
    /// One registered inexactness: Foundation's `.gregorian` is ICU's hybrid calendar, which
    /// switches to Julian before 1582-10-15, while `getFullYear()` is proleptic. The two therefore
    /// disagree for instants no clock this is called with can produce, and agree for every instant
    /// one can.
    static func year(at instant: Date, in timeZone: TimeZone) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.component(.year, from: instant)
    }

    /// The `LIKE` pattern the row query uses: `<prefix>-<year>-%`.
    ///
    /// SQLite's `LIKE` is ASCII case-INSENSITIVE by default, so this also fetches `qt-2026-0500`.
    /// That is not a bug to fix here — it is what the handler's query does, and
    /// ``numericSuffix(of:)`` is what then refuses the lower-case spelling, exactly as the regex
    /// does on the other side. Measured: seeding `qt-2026-0500` leaves the suggestion at `0001`.
    static func likePattern(prefix: String, year: Int) -> String { "\(prefix)-\(year)-%" }

    /// `/^[A-Z]{2}-\d{4}-(\d+)$/` followed by `parseInt(m[1], 10)`, or `nil` when the number does
    /// not have that shape.
    ///
    /// Hand-parsed rather than handed to `NSRegularExpression`, and the reason is a real difference
    /// rather than taste: ICU's `$` also matches **before a final line terminator**, while
    /// JavaScript's `$` (without `m`) matches only at the very end of the input. A stored
    /// `"QT-2026-0007\n"` would therefore feed the maximum on the native side and not on the
    /// Electron side. Walking the scalars has no such corner.
    ///
    /// `[A-Z]` and `\d` are ASCII-only in both languages, so a non-ASCII character fails here for
    /// the same reason it fails there.
    ///
    /// The result is a `Double` because `parseInt` returns a Number: a 22-digit suffix does not fit
    /// an `Int64` and JS does not pretend it does — it yields `1e+22`, and the suggestion built from
    /// it says so.
    static func numericSuffix(of number: String) -> Double? {
        var scalars = Substring(number).unicodeScalars[...]

        func take(_ count: Int, where predicate: (Unicode.Scalar) -> Bool) -> String? {
            var taken = ""
            for _ in 0..<count {
                guard let first = scalars.first, predicate(first) else { return nil }
                taken.unicodeScalars.append(first)
                scalars = scalars.dropFirst()
            }
            return taken
        }
        func takeLiteral(_ scalar: Unicode.Scalar) -> Bool {
            guard scalars.first == scalar else { return false }
            scalars = scalars.dropFirst()
            return true
        }

        guard take(2, where: { $0 >= "A" && $0 <= "Z" }) != nil, takeLiteral("-"),
              take(4, where: { $0 >= "0" && $0 <= "9" }) != nil, takeLiteral("-")
        else { return nil }

        var digits = ""
        while let first = scalars.first, first >= "0", first <= "9" {
            digits.unicodeScalars.append(first)
            scalars = scalars.dropFirst()
        }
        // `(\d+)` needs at least one digit, and `$` means nothing may follow it.
        guard !digits.isEmpty, scalars.isEmpty else { return nil }
        // A run of ASCII digits is exactly the domain on which `Double(String)` and `parseInt(s, 10)`
        // agree, over-long runs included: 400 nines are `Infinity` on both sides. Measured.
        return Double(digits)
    }

    /// `` `${prefix}-${year}-${String(max + 1).padStart(4, '0')}` ``.
    ///
    /// `highestSuffix` is the largest number ``numericSuffix(of:)`` read from the fetched rows, or
    /// `0` when none of them had the shape — the handler's `let max = 0` starting point.
    static func suggestion(prefix: String, year: Int, highestSuffix: Double) -> String {
        let next = DocumentMath.jsNumberToString(highestSuffix + 1)
        return "\(prefix)-\(year)-" + DocumentMath.jsPadStart(next, to: 4)
    }
}

public extension LedgerStore {

    /// `GET /api/documents/next-number?type=…` — `documents.js nextNumber`. A suggestion, never a
    /// reservation; see ``DocumentNumbering``.
    ///
    /// The handler's fourth behaviour — refusing a `type` that is missing or outside the closed set
    /// — has no counterpart, because ``BusinessDocumentType`` takes those inputs out of the domain.
    /// That is the same trade `createBusinessDocument(_:)` already makes for `doc_type`.
    func nextBusinessDocumentNumber(for type: BusinessDocumentType) throws -> String {
        try nextBusinessDocumentNumber(for: type,
                                       year: DocumentNumbering.year(at: Date(), in: .current))
    }

    /// The year seam. `nextBusinessDocumentNumber(for:)` is the shipping entry point and reads the
    /// clock; this one exists so a test can ask what the suggestion is in a year that is not this
    /// one without moving the machine's clock.
    ///
    /// **`internal` on purpose**, even though it sits in a `public extension`: `GET
    /// /api/documents/next-number` takes only a type, so a public year parameter would be a piece
    /// of API Electron has no counterpart for. `@testable import` reaches it; the App cannot.
    internal func nextBusinessDocumentNumber(for type: BusinessDocumentType, year: Int) throws -> String {
        let prefix = DocumentNumbering.prefix(for: type)
        // The maximum is taken in Swift over the fetched rows, not with SQL `MAX()`, because the
        // column is TEXT: `MAX` would compare lexicographically and a user's own `CUSTOM-9999`
        // would outrank `QT-2026-0008`. The handler says so in its own comment.
        let rows = try db.query(
            "SELECT doc_number FROM business_documents WHERE doc_type = ? AND doc_number LIKE ?",
            [.text(type.rawValue), .text(DocumentNumbering.likePattern(prefix: prefix, year: year))])

        var highest = 0.0
        for row in rows {
            guard let number = row.string("doc_number"),
                  let suffix = DocumentNumbering.numericSuffix(of: number)
            else { continue }
            // `Math.max`, which keeps the larger of the two and — unlike a Swift `max` over an
            // optional chain — never sees a NaN, because a digit run cannot produce one.
            highest = Swift.max(highest, suffix)
        }
        return DocumentNumbering.suggestion(prefix: prefix, year: year, highestSuffix: highest)
    }
}
