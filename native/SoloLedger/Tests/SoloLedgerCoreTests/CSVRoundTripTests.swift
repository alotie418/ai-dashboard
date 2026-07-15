import XCTest
@testable import SoloLedgerCore

final class CSVRoundTripTests: LedgerTestCase {

    func testNumberFormattingMatchesJSStyle() {
        XCTAssertEqual(CSVWriter.numberString(100), "100")
        XCTAssertEqual(CSVWriter.numberString(0), "0")
        XCTAssertEqual(CSVWriter.numberString(100.5), "100.5")
        XCTAssertEqual(CSVWriter.numberString(-42), "-42")
    }

    func testExportHasBOMAndSchemaColumnOrder() throws {
        let store = try makeStore()
        try store.create(Transaction(type: .income, date: "2026-01-01", amount: 10, currency: "CNY"))
        let csv = try store.exportTransactionsCSV()
        XCTAssertTrue(csv.hasPrefix("\u{FEFF}"), "missing UTF-8 BOM")
        let header = csv.dropFirst().split(separator: "\r\n").first.map(String.init) ?? ""
        XCTAssertEqual(header, TransactionCSV.columns.joined(separator: ","))
    }

    func testRFC4180EscapingAndInjectionGuard() {
        let t = Transaction(
            type: .expense, date: "2026-01-01", amount: -5, currency: "CNY",
            counterparty: "Doe, John \"Jr\"",       // comma + quotes → must be quoted
            description: "=SUM(A1)"                  // formula-injection → leading apostrophe
        )
        let csv = TransactionCSV.export([t], includeBOM: false)
        XCTAssertTrue(csv.contains("\"Doe, John \"\"Jr\"\"\""), "counterparty not RFC-4180 escaped")
        XCTAssertTrue(csv.contains("'=SUM(A1)"), "description not guarded against CSV injection")
        // Negative numbers go through the number path, NOT the injection guard.
        XCTAssertTrue(csv.contains(",-5,"), "negative amount should not be prefixed")
    }

    func testRoundTripPreservesTotals() throws {
        let store = try makeStore()
        let inc = try store.categories(locale: .CN, type: .income).first
        try store.create(Transaction(type: .income, date: "2026-01-05", amount: 1000, currency: "CNY", categoryID: inc?.id, counterparty: "Acme, Inc"))
        try store.create(Transaction(type: .income, date: "2026-02-10", amount: 700, currency: "CNY"))
        try store.create(Transaction(type: .expense, date: "2026-02-15", amount: 250, currency: "CNY"))

        let csv = try store.exportTransactionsCSV()

        // Import into a completely fresh DB.
        let store2 = try makeStore()
        let result = try store2.importTransactionsCSV(csv)
        XCTAssertEqual(result.imported, 3)
        XCTAssertEqual(result.skipped, 0)

        let a = try store.summary()
        let b = try store2.summary()
        XCTAssertEqual(a.incomeTotal, b.incomeTotal)
        XCTAssertEqual(a.expenseTotal, b.expenseTotal)
        XCTAssertEqual(b.net, 1450)
    }

    func testParseSkipsInvalidRows() {
        let csv = """
        type,date,amount\r
        income,2026-01-01,100\r
        ,2026-01-02,50\r
        expense,,30\r
        expense,2026-01-03,notanumber\r
        expense,2026-01-04,20\r
        """
        let result = TransactionCSV.parse(csv)
        XCTAssertEqual(result.transactions.count, 2) // 2 valid
        XCTAssertEqual(result.skipped, 3)            // 3 invalid
    }

    func testParseHandlesQuotedFieldsWithCommas() {
        let csv = "type,date,amount,counterparty\r\nincome,2026-01-01,100,\"Doe, John\"\r\n"
        let result = TransactionCSV.parse(csv)
        XCTAssertEqual(result.transactions.first?.counterparty, "Doe, John")
    }

    /// Regression: numberString must not strip a scientific-notation exponent's
    /// trailing zero (1.5e20 -> "1.5e+2" would silently become 150).
    func testScientificNotationNotCorrupted() {
        for v in [1.5e20, 1.5e-10, 1.2e30, 3.7e-20, 6.02e23] {
            let s = CSVWriter.numberString(v)
            XCTAssertEqual(Double(s), v, "numberString(\(v)) = \(s) did not round-trip")
        }
        XCTAssertEqual(CSVWriter.numberString(100), "100")
        XCTAssertEqual(CSVWriter.numberString(100.5), "100.5")
    }

    /// Values that trip the CSV formula-injection guard must survive a round-trip.
    func testInjectionGuardRoundTrips() throws {
        let store = try makeStore()
        try store.create(Transaction(type: .expense, date: "2026-01-01", amount: 5, currency: "CNY",
                                     counterparty: "-NegVendor", description: "=SUM(A1)"))
        let csv = try store.exportTransactionsCSV()
        let store2 = try makeStore()
        _ = try store2.importTransactionsCSV(csv)
        let t = try store2.listTransactions().first
        XCTAssertEqual(t?.description, "=SUM(A1)")
        XCTAssertEqual(t?.counterparty, "-NegVendor")
    }

    /// Import is additive with fresh ids: re-importing an export into the SAME
    /// store must not abort on an id collision, and must not overwrite.
    func testImportIsAdditiveWithFreshIds() throws {
        let store = try makeStore()
        try store.create(Transaction(type: .income, date: "2026-01-01", amount: 100, currency: "CNY"))
        try store.create(Transaction(type: .expense, date: "2026-01-02", amount: 40, currency: "CNY"))
        let csv = try store.exportTransactionsCSV()
        let r1 = try store.importTransactionsCSV(csv)
        XCTAssertEqual(r1.imported, 2)
        let all = try store.listTransactions()
        XCTAssertEqual(all.count, 4)                     // additive
        XCTAssertEqual(Set(all.map { $0.id }).count, 4)  // all ids unique
    }
}
