import XCTest
@testable import SoloLedgerCore

final class CategorySeedTests: LedgerTestCase {

    func testSeventyEightSeeded() throws {
        XCTAssertEqual(CategorySeed.all.count, 78)
        let store = try makeStore()
        let count = try store.db.query("SELECT COUNT(*) AS c FROM categories").first?.int("c")
        XCTAssertEqual(count, 78)
    }

    func testPerLocaleCounts() throws {
        let expected: [AccountingLocale: Int] = [.CN: 9, .US: 22, .JP: 14, .EU: 12, .KR: 13, .TW: 8]
        let store = try makeStore()
        for (locale, want) in expected {
            let got = try store.categories(locale: locale).count
            XCTAssertEqual(got, want, "locale \(locale.rawValue) expected \(want) got \(got)")
        }
    }

    func testCogsBackfilled() throws {
        let store = try makeStore()
        let cnCogs = try store.categories(locale: .CN, type: .expense).first { $0.slug == "cogs" }
        XCTAssertEqual(cnCogs?.isCOGS, true)
        let euPurchases = try store.categories(locale: .EU, type: .expense).first { $0.slug == "purchases" }
        XCTAssertEqual(euPurchases?.isCOGS, true)
        let cnAdmin = try store.categories(locale: .CN, type: .expense).first { $0.slug == "admin" }
        XCTAssertEqual(cnAdmin?.isCOGS, false)
    }

    func testUniqueConstraintPreventsDuplicateSeed() throws {
        let store = try makeStore()
        // Re-running the seed must not duplicate (UNIQUE(locale,type,slug) + INSERT OR IGNORE).
        try CategorySeed.seed(into: store.db)
        let count = try store.db.query("SELECT COUNT(*) AS c FROM categories").first?.int("c")
        XCTAssertEqual(count, 78)
    }

    func testLocalizedLabels() throws {
        let store = try makeStore()
        let sales = try store.categories(locale: .CN, type: .income).first { $0.slug == "sales" }
        XCTAssertEqual(sales?.label(for: "zh-Hans"), "主营业务收入")
        XCTAssertEqual(sales?.label(for: "en"), "Sales Revenue")
        XCTAssertEqual(sales?.label(for: "ja"), "売上高")
        // Unknown language falls back to English.
        XCTAssertEqual(sales?.label(for: "de"), "Sales Revenue")
    }
}
