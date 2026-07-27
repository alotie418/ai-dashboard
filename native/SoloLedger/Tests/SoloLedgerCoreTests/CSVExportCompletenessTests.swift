import XCTest
@testable import SoloLedgerCore

/// The CSV export must contain EVERY matching row.
///
/// It used to pass `limit: 5000` into `listTransactions`, which is exactly the
/// ceiling that method clamps to — so past 5000 rows the export silently dropped
/// the tail. No warning, no log, no marker in the file. The user received a
/// plausible-looking CSV missing an arbitrary slice of their own records, and
/// nothing in the product could tell them.
///
/// This is the same family as the report-fetch cap (plan §8.2) and as Appendix A1:
/// an incomplete figure presented as a complete one. The export is the worst place
/// for it, because that file is the data-portability path — it gets archived,
/// re-imported, and handed to accountants long after the app has forgotten it was
/// truncated.
///
/// The transaction LIST still caps at 500 without disclosure. That is a separate,
/// recorded defect deferred to the report-UI work, where the "showing N of M"
/// affordance it needs is being designed. It is deliberately NOT fixed here.
final class CSVExportCompletenessTests: LedgerTestCase {

    /// Data lines of a CSV, header dropped.
    ///
    /// Split on the literal `"\r\n"`, NOT on `"\n"`. Swift strings are collections
    /// of grapheme clusters and CRLF is ONE cluster, so `csv.contains("\n")` is
    /// `false` for this file and `split(separator: "\n")` returns the whole string
    /// as a single element. A count taken that way is 0 after dropping the header —
    /// which reads exactly like a truncated export, and is how this test first
    /// failed against a perfectly correct one.
    private func dataLines(_ csv: String) -> [String] {
        Array(csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }.dropFirst())
    }

    /// Builds a ledger with `rows` transactions in one period.
    private func ledger(rows: Int) throws -> LedgerStore {
        let store = try makeStore()
        try store.db.execute("BEGIN")
        for i in 0..<rows {
            let month = String(format: "%02d", (i % 12) + 1)
            try store.db.execute("""
                INSERT INTO transactions (id, type, date, amount, currency, payment_status,
                                          created_at, updated_at)
                VALUES ('t\(i)', 'income', '2025-\(month)-15', \(Double(i) + 1.5), 'CNY',
                        'unpaid', '2025-01-01', '2025-01-01')
                """)
        }
        try store.db.execute("COMMIT")
        return store
    }

    /// 5001 rows — one past the clamp ceiling, so a regression loses exactly one
    /// row and would be easy to miss without an exact count.
    func testExportContainsEveryRowPastTheOldCap() throws {
        let store = try ledger(rows: 5001)

        let csv = try store.exportTransactionsCSV()
        let lines = dataLines(csv)
        XCTAssertEqual(lines.count, 5001,
                       "the export truncated — this is the bug, and it is silent")

        // Cross-check against the ledger's own count, so the test cannot pass by
        // agreeing with a wrong constant.
        let sqlCount = try XCTUnwrap(try store.db
            .query("SELECT COUNT(*) AS c FROM transactions").first?.int("c"))
        XCTAssertEqual(lines.count, sqlCount)

        // And the LAST row is present — truncation takes the tail, so a test that
        // only checked the count could in principle pass on a reordered read.
        XCTAssertTrue(csv.contains("t5000"), "the final row must survive the export")
    }

    /// `limit: nil` means no cap; a non-nil limit still clamps exactly as before,
    /// so the list view's behaviour is untouched by this change.
    func testNilLimitMeansNoCapAndNonNilStillClamps() throws {
        let store = try ledger(rows: 5001)
        XCTAssertEqual(try store.listTransactions(limit: nil).count, 5001)
        XCTAssertEqual(try store.listTransactions(limit: 10).count, 10)
        // Above the ceiling, still clamped — unchanged behaviour.
        XCTAssertEqual(try store.listTransactions(limit: 99_999).count, 5000)
        // The shipped default, also unchanged. It is the recorded, deferred defect.
        XCTAssertEqual(try store.listTransactions().count, 500)
    }

    /// A filtered export is complete WITHIN its filter — the fix must not have been
    /// "fetch everything and hope", which would break the type/date filters.
    func testAFilteredExportIsCompleteWithinItsFilter() throws {
        let store = try ledger(rows: 5001)
        try store.db.execute("""
            INSERT INTO transactions (id, type, date, amount, currency, payment_status,
                                      created_at, updated_at)
            VALUES ('exp1', 'expense', '2025-03-01', 42, 'CNY', 'unpaid',
                    '2025-01-01', '2025-01-01')
            """)
        let income = try store.exportTransactionsCSV(type: .income)
        XCTAssertEqual(dataLines(income).count, 5001)
        XCTAssertFalse(income.contains("exp1"), "the type filter must still apply")

        let expense = try store.exportTransactionsCSV(type: .expense)
        XCTAssertEqual(dataLines(expense).count, 1)
        XCTAssertTrue(expense.contains("exp1"))
    }

    /// A round trip past the old cap: everything exported comes back.
    ///
    /// Without this, an export that dropped rows and an import that dropped rows
    /// would agree with each other and both tests would pass.
    func testRoundTripPastTheOldCapPreservesEveryRow() throws {
        let source = try ledger(rows: 5001)
        let csv = try source.exportTransactionsCSV()

        let destination = try makeStore()
        let (imported, skipped) = try destination.importTransactionsCSV(csv)
        XCTAssertEqual(skipped, 0)
        XCTAssertEqual(imported, 5001)
        XCTAssertEqual(try destination.listTransactions(limit: nil).count, 5001)
    }
}
