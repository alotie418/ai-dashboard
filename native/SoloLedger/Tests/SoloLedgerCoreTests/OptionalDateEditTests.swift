import XCTest
@testable import SoloLedgerCore

/// Guard for the editor date round-trip policy (review finding on the N1
/// capture-fields change): opening a transaction whose stored payment_date /
/// due_date the strict yyyy-MM-dd parser cannot read, then saving WITHOUT
/// touching the row, must preserve the stored string byte-for-byte — never
/// silently persist NULL or a canonical rewrite.
final class OptionalDateEditTests: XCTestCase {

    /// Real-world shapes that reach the DB unvalidated (CSV import stores the
    /// column verbatim; Electron normalize() is `data.payment_date || null`).
    private let unparseable = [
        "2026-07-25T00:00:00Z",
        "2026-07-25T00:00:00.000Z",
        "2026-07-25 10:00",
        "07/25/2026",
        "not-a-date",
    ]

    func testStrictParserRejectsTheFixturesThisGuardExistsFor() {
        for s in unparseable {
            XCTAssertNil(DateFormat.date(from: s), "\(s) must not parse — fixture invalid")
        }
    }

    // MARK: - persisted(original:initial:edited:)

    func testUntouchedUnparseableOriginalRoundTripsVerbatim() {
        for s in unparseable {
            let initial = DateFormat.date(from: s)   // nil by the fixture guard
            XCTAssertEqual(OptionalDateEdit.persisted(original: s, initial: initial, edited: initial), s,
                           "untouched unparseable value must survive a save byte-for-byte")
        }
    }

    func testUntouchedParseableOriginalRoundTripsVerbatimEvenWhenNonCanonical() {
        // Whatever the parser accepts, an untouched row must NOT be rewritten
        // to canonical form behind the user's back.
        let candidates = ["2026-07-05", "2026-7-5", "2026/07/05"]
        for s in candidates {
            let initial = DateFormat.date(from: s)
            XCTAssertEqual(OptionalDateEdit.persisted(original: s, initial: initial, edited: initial), s,
                           "untouched stored value must round-trip verbatim: \(s)")
        }
    }

    func testUserClearingAParsedDatePersistsNil() {
        let original = "2026-07-05"
        let initial = DateFormat.date(from: original)
        XCTAssertNotNil(initial)
        XCTAssertNil(OptionalDateEdit.persisted(original: original, initial: initial, edited: nil),
                     "explicit uncheck of a parsed date must persist NULL")
    }

    func testUserEditingPersistsCanonicalString() {
        let original = "2026-07-05"
        let initial = DateFormat.date(from: original)!
        let edited = DateFormat.date(from: "2026-08-09")!
        XCTAssertEqual(OptionalDateEdit.persisted(original: original, initial: initial, edited: edited),
                       "2026-08-09")
    }

    func testUserPickingADateOverUnparseableOriginalPersistsCanonicalString() {
        let edited = DateFormat.date(from: "2026-08-09")!
        XCTAssertEqual(OptionalDateEdit.persisted(original: "not-a-date", initial: nil, edited: edited),
                       "2026-08-09", "an explicit user pick replaces the unparseable value")
    }

    func testNewRowWithNoDatePersistsNil() {
        XCTAssertNil(OptionalDateEdit.persisted(original: nil, initial: nil, edited: nil))
    }

    // MARK: - unparsedFallback(original:initial:current:)

    func testFallbackShownOnlyForUnparsedUntouchedValue() {
        XCTAssertEqual(OptionalDateEdit.unparsedFallback(original: "not-a-date", initial: nil, current: nil),
                       "not-a-date")
        // Parsed normally → picker shows the date, no fallback text.
        let parsed = DateFormat.date(from: "2026-07-05")
        XCTAssertNil(OptionalDateEdit.unparsedFallback(original: "2026-07-05", initial: parsed, current: parsed))
        // User picked a date over the unparseable value → fallback disappears.
        XCTAssertNil(OptionalDateEdit.unparsedFallback(original: "not-a-date", initial: nil, current: Date()))
        // Empty column → nothing to show.
        XCTAssertNil(OptionalDateEdit.unparsedFallback(original: nil, initial: nil, current: nil))
    }
}
