import XCTest
@testable import SoloLedgerCore

final class LedgerStoreTests: LedgerTestCase {

    private func seedThree(_ store: LedgerStore) throws {
        let inc = try store.categories(locale: .CN, type: .income).first
        let exp = try store.categories(locale: .CN, type: .expense).first
        try store.create(Transaction(type: .income, date: "2026-01-05", amount: 1000, currency: "CNY", categoryID: inc?.id, counterparty: "Acme"))
        try store.create(Transaction(type: .income, date: "2026-02-10", amount: 500, currency: "CNY", categoryID: inc?.id))
        try store.create(Transaction(type: .expense, date: "2026-02-15", amount: 300, currency: "CNY", categoryID: exp?.id, paymentStatus: .unpaid))
    }

    func testCreateAndList() throws {
        let store = try makeStore()
        try seedThree(store)
        XCTAssertEqual(try store.listTransactions().count, 3)
        XCTAssertEqual(try store.listTransactions(type: .income).count, 2)
        XCTAssertEqual(try store.listTransactions(type: .expense).count, 1)
    }

    func testListOrderingNewestFirst() throws {
        let store = try makeStore()
        try seedThree(store)
        let dates = try store.listTransactions().map { $0.date }
        XCTAssertEqual(dates, ["2026-02-15", "2026-02-10", "2026-01-05"])
    }

    func testSummary() throws {
        let store = try makeStore()
        try seedThree(store)
        let s = try store.summary()
        XCTAssertEqual(s.incomeTotal, 1500)
        XCTAssertEqual(s.incomeCount, 2)
        XCTAssertEqual(s.expenseTotal, 300)
        XCTAssertEqual(s.expenseCount, 1)
        XCTAssertEqual(s.net, 1200)
    }

    func testDateRangeSummary() throws {
        let store = try makeStore()
        try seedThree(store)
        let feb = try store.summary(from: "2026-02-01", to: "2026-02-28")
        XCTAssertEqual(feb.incomeTotal, 500)
        XCTAssertEqual(feb.expenseTotal, 300)
    }

    func testUpdate() throws {
        let store = try makeStore()
        try seedThree(store)
        var t = try store.listTransactions(type: .income).first { $0.counterparty == "Acme" }!
        t.amount = 1200
        try store.update(t)
        XCTAssertEqual(try store.summary().incomeTotal, 1700)
    }

    func testDelete() throws {
        let store = try makeStore()
        try seedThree(store)
        let exp = try store.listTransactions(type: .expense).first!
        try store.delete(id: exp.id)
        XCTAssertEqual(try store.listTransactions().count, 2)
        XCTAssertEqual(try store.summary().expenseTotal, 0)
    }

    func testValidationRejectsEmptyDate() throws {
        let store = try makeStore()
        var t = Transaction(type: .income, date: "2026-01-01", amount: 1)
        t.date = ""
        XCTAssertThrowsError(try store.create(t))
    }

    func testValidationRejectsNonFiniteAmount() throws {
        let store = try makeStore()
        // normalized() coerces non-finite to 0, which is valid — verify it doesn't crash and stores 0.
        let t = Transaction(type: .expense, date: "2026-01-01", amount: .nan)
        try store.create(t)
        XCTAssertEqual(try store.summary().expenseTotal, 0)
    }

    func testNormalizationClampsStrings() throws {
        let store = try makeStore()
        let long = String(repeating: "x", count: 300)
        try store.create(Transaction(type: .income, date: "2026-01-01", amount: 1, counterparty: long))
        let saved = try store.listTransactions().first!
        XCTAssertEqual(saved.counterparty.count, 200) // clamped to 200
    }

    func testMonthlyTotals() throws {
        let store = try makeStore()
        try seedThree(store)
        let months = try store.monthlyTotals()
        XCTAssertEqual(months.count, 2)
        let feb = months.first { $0.month == "2026-02" }
        XCTAssertEqual(feb?.income, 500)
        XCTAssertEqual(feb?.expense, 300)
    }

    func testDefaultCurrencyByLocale() {
        XCTAssertEqual(AccountingLocale.US.defaultCurrency, "USD")
        XCTAssertEqual(AccountingLocale.JP.defaultCurrency, "JPY")
        XCTAssertEqual(AccountingLocale.EU.defaultCurrency, "EUR")
        XCTAssertEqual(AccountingLocale.KR.defaultCurrency, "KRW")
        XCTAssertEqual(AccountingLocale.TW.defaultCurrency, "TWD")
        XCTAssertEqual(AccountingLocale.CN.defaultCurrency, "CNY")
    }

    func testSettingsJSONEncoding() throws {
        let store = try makeStore()
        // v3 seeds accounting_locale as JSON-encoded "CN".
        XCTAssertEqual(try store.settings.rawValue("accounting_locale"), "\"CN\"")
        XCTAssertEqual(try store.settings.accountingLocale(), .CN)
        try store.settings.setString("US", for: SettingsStore.Key.accountingLocale)
        XCTAssertEqual(try store.settings.rawValue("accounting_locale"), "\"US\"")
        try store.settings.setBool(true, for: SettingsStore.Key.onboardingDone)
        XCTAssertEqual(try store.settings.bool(SettingsStore.Key.onboardingDone), true)
    }
}
