import XCTest
@testable import SoloLedgerCore

/// Phase 2A: the logic behind the new transaction search / sort / date filter and
/// the per-currency summary (which must never blend currencies into one total).
final class QueryAndSummaryTests: LedgerTestCase {

    private func demoStore() throws -> LedgerStore {
        let store = try makeStore()
        XCTAssertTrue(try DemoData.isEmpty(store))
        XCTAssertEqual(try DemoData.seed(into: store), 16)
        XCTAssertFalse(try DemoData.isEmpty(store))
        return store
    }

    func testSearchMatchesCounterpartyAndDescription() throws {
        let store = try demoStore()
        XCTAssertEqual(try store.listTransactions(search: "华东贸易").count, 3)
        XCTAssertEqual(try store.listTransactions(search: "Nordic").count, 2)
        XCTAssertEqual(try store.listTransactions(search: "租金").count, 2)      // description match
        XCTAssertEqual(try store.listTransactions(search: "无此对象").count, 0)
    }

    func testSort() throws {
        let store = try demoStore()
        XCTAssertEqual(try store.listTransactions(sort: .amountAscending).first?.amount, 860)     // USD Stripe fee
        XCTAssertEqual(try store.listTransactions(sort: .amountDescending).first?.amount, 18400)
        XCTAssertEqual(try store.listTransactions(sort: .dateAscending).first?.date, "2025-09-08")
        XCTAssertEqual(try store.listTransactions(sort: .dateDescending).first?.date, "2026-03-04")
    }

    func testDateRangeFilter() throws {
        let store = try demoStore()
        XCTAssertEqual(try store.listTransactions(from: "2026-01-01").count, 5)
        XCTAssertEqual(try store.listTransactions(from: "2025-09-01", to: "2025-09-30").count, 3)
    }

    func testSummaryByCurrencyNeverBlends() throws {
        let store = try demoStore()
        let byCur = try store.summaryByCurrency()
        XCTAssertEqual(byCur.map { $0.currency }, ["CNY", "USD", "EUR"])   // sorted by activity

        let cny = try XCTUnwrap(byCur.first { $0.currency == "CNY" })
        XCTAssertEqual(cny.incomeTotal, 67300, accuracy: 0.001)
        XCTAssertEqual(cny.expenseTotal, 24990.5, accuracy: 0.001)
        XCTAssertEqual(cny.net, 42309.5, accuracy: 0.001)

        let usd = try XCTUnwrap(byCur.first { $0.currency == "USD" })
        XCTAssertEqual(usd.net, 2390, accuracy: 0.001)

        let eur = try XCTUnwrap(byCur.first { $0.currency == "EUR" })
        XCTAssertEqual(eur.net, 2100, accuracy: 0.001)
        XCTAssertEqual(eur.expenseCount, 0)

        // More than one currency present → the UI must present per-currency, not one blended total.
        XCTAssertGreaterThan(byCur.count, 1)
    }

    // MARK: - Period consistency (summary / monthly / recent all respect the range)

    func testEmptyPeriodReturnsNothingAcrossSummaryMonthlyRecent() throws {
        let store = try makeStore()
        // Multi-currency history exists in 2025, but the "current period" (2026) is empty.
        try store.create(Transaction(type: .income, date: "2025-06-01", amount: 1000, currency: "CNY"))
        try store.create(Transaction(type: .expense, date: "2025-07-01", amount: 200, currency: "USD"))

        let from = "2026-01-01", to = "2026-12-31"   // this year → empty
        XCTAssertEqual(try store.summary(from: from, to: to).incomeCount, 0)
        XCTAssertEqual(try store.summary(from: from, to: to).expenseCount, 0)
        XCTAssertTrue(try store.summaryByCurrency(from: from, to: to).isEmpty)
        XCTAssertTrue(try store.monthlyTotals(currency: "CNY", from: from, to: to).isEmpty)
        XCTAssertTrue(try store.listTransactions(from: from, to: to, limit: 6).isEmpty)

        // The full history still shows both currencies (sanity: data is present, just out of range).
        XCTAssertEqual(try store.summaryByCurrency().count, 2)
    }

    func testMonthlyTotalsRespectsRangeAndCurrency() throws {
        let store = try makeStore()
        try store.create(Transaction(type: .income, date: "2025-12-15", amount: 500, currency: "CNY"))
        try store.create(Transaction(type: .income, date: "2026-01-15", amount: 800, currency: "CNY"))
        try store.create(Transaction(type: .income, date: "2026-01-20", amount: 999, currency: "USD"))

        let m = try store.monthlyTotals(currency: "CNY", from: "2026-01-01", to: "2026-12-31")
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m.first?.month, "2026-01")
        XCTAssertEqual(m.first?.income ?? 0, 800, accuracy: 0.001)   // no USD blend (999), no 2025 (500)
    }

    // MARK: - Sort applies before LIMIT (not a local sort of the loaded page)

    func testSortAppliesBeforeLimitOver500Rows() throws {
        let store = try makeStore()
        // 600 rows: larger i → older date AND larger amount, so a newest-500-by-date
        // load caps amounts at 499; a global amount sort must still surface 599.
        try store.db.transaction {
            for i in 0..<600 {
                try store.create(Transaction(id: "big-\(i)", type: .income,
                    date: String(format: "%04d-01-01", 3000 - i), amount: Double(i), currency: "CNY"))
            }
        }
        XCTAssertEqual(try store.listTransactions(sort: .amountDescending, limit: 500).first?.amount, 599)
        XCTAssertEqual(try store.listTransactions(sort: .amountAscending, limit: 500).first?.amount, 0)
        XCTAssertEqual(try store.listTransactions(sort: .dateDescending, limit: 500).first?.date, "3000-01-01")
    }

    // MARK: - Demo data idempotency

    func testDemoDataSeedIsIdempotent() throws {
        let store = try makeStore()
        XCTAssertEqual(try DemoData.seed(into: store), 16)
        XCTAssertEqual(try store.listTransactions(limit: 5000).count, 16)
        // Re-seed on a non-empty ledger → no-op, no duplicates.
        XCTAssertEqual(try DemoData.seed(into: store), 0)
        XCTAssertEqual(try DemoData.seed(into: store), 0)
        XCTAssertEqual(try store.listTransactions(limit: 5000).count, 16)
    }
}
