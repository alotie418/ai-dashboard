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
}
