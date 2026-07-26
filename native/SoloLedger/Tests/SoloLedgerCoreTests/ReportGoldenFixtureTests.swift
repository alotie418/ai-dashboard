import XCTest
@testable import SoloLedgerCore

/// Guards the report-parity FIXTURE itself, before any engine is mirrored.
///
/// The phase-1 mirroring PRs assert the Swift report output field-by-field against
/// these goldens, so the goldens have to be present, complete and — most
/// importantly — DISCRIMINATING. A fixture whose cases cannot tell two behaviours
/// apart turns every later parity test into a test that passes for the wrong
/// reason.
final class ReportGoldenFixtureTests: LedgerTestCase {

    private let variants = ["base", "unset", "zero", "malformed"]
    private let locales = ["CN", "US", "JP", "EU", "KR", "TW"]
    private let basePeriods = ["2024", "2025", "2026", "2025Q2", "2025-06", "2024H2-2025H1"]

    private func goldensDirectory() throws -> URL {
        guard let url = Bundle.module.url(forResource: "reports", withExtension: nil)?
            .appendingPathComponent("goldens") else {
            throw XCTSkip("report fixtures missing from the test bundle")
        }
        return url
    }

    private func golden(_ name: String) throws -> [String: Any] {
        let url = try goldensDirectory().appendingPathComponent("\(name).json")
        let data = try Data(contentsOf: url)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("\(name).json is not a JSON object"); return [:]
        }
        return obj
    }

    // MARK: - The matrix exists and is complete

    /// URL of the bundled fixture. NEVER open it read-write: `LedgerStore` runs the
    /// migrator and switches journal mode on open, which rewrites the file in place
    /// and would make the content hash below drift depending on test order.
    private func bundledFixtureURL() throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: "reports", withExtension: nil))
            .appendingPathComponent("reports-base.db")
    }

    /// A writable copy, for anything that needs to open the ledger.
    private func fixtureCopy() throws -> URL {
        let dst = try trackedTempDir().appendingPathComponent("reports-base.db")
        try FileManager.default.copyItem(at: try bundledFixtureURL(), to: dst)
        return dst
    }

    func testFixtureDatabaseShipsInTheTestBundle() throws {
        XCTAssertTrue(FileManager.default.fileExists(atPath: try bundledFixtureURL().path),
                      "reports-base.db must ship")
        let store = try LedgerStore(databaseURL: try fixtureCopy())
        XCTAssertEqual(try store.schemaVersion(), 23)
    }

    func testGoldenMatrixIsComplete() throws {
        var expected = Set<String>()
        for locale in locales {
            for period in basePeriods { expected.insert("base-\(locale)-\(period)") }
            for variant in ["unset", "zero", "malformed"] { expected.insert("\(variant)-\(locale)-2025") }
        }
        let dir = try goldensDirectory()
        let present = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".json") && $0 != "GOLDEN_ENV.json" }
            .map { String($0.dropLast(5)) })
        XCTAssertEqual(present, expected, "golden matrix drifted from the generator's definition")
    }

    func testEveryGoldenCarriesTheEngineContract() throws {
        for locale in locales {
            let g = try golden("base-\(locale)-2025")
            for key in ["locale", "period", "currency", "reportTypes", "monthlyBreakdown",
                        "warnings", "cashflowStatement"] {
                XCTAssertNotNil(g[key], "\(locale): missing top-level key \(key)")
            }
            XCTAssertEqual(g["locale"] as? String, locale)
            // The statement block is NOT uniformly named — EU says profitLoss, US has
            // no P&L block at all. The mirror must not "tidy" this.
            let hasStatement = g["incomeStatement"] != nil || g["profitLoss"] != nil || g["scheduleC"] != nil
            XCTAssertTrue(hasStatement, "\(locale): no statement block")
        }
        XCTAssertNotNil(try golden("base-EU-2025")["profitLoss"], "EU uses profitLoss, not incomeStatement")
        XCTAssertNotNil(try golden("base-US-2025")["scheduleC"], "US produces a Schedule C, not a P&L")
    }

    private func environmentRecord() throws -> [String: Any] {
        let url = try goldensDirectory().appendingPathComponent("GOLDEN_ENV.json")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func testEnvironmentRecordPinsTheGeneratingRuntime() throws {
        let env = try environmentRecord()
        XCTAssertEqual(env["resolvedIntlLocale"] as? String, "en-US",
                       "us.js formats with toLocaleString(); a different Intl locale moves the numbers")
        let required = try XCTUnwrap(env["env"] as? [String: String])
        XCTAssertEqual(required["LC_ALL"], "C")
        XCTAssertEqual(required["TZ"], "UTC")
        for key in ["electron", "node", "icu", "betterSqlite3", "sqlite"] {
            XCTAssertNotNil(env[key], "the generating \(key) version must be recorded")
        }
    }

    /// The goldens are only meaningful for the exact fixture they were generated
    /// from. A rebuilt or hand-edited database with stale goldens would otherwise
    /// pass every parity test while measuring the wrong ledger.
    func testGoldensWereGeneratedFromTheShippedFixture() throws {
        let record = try XCTUnwrap(try environmentRecord()["fixture"] as? [String: Any])
        let recorded = try XCTUnwrap(record["sha256"] as? String)
        // Hash the COMMITTED file, not the bundle copy: the generator hashed the
        // committed one, and a bundled resource can be mutated in place by a test
        // that opens it. Same technique MigrationCopyParityTests uses for .strings.
        var dir = URL(fileURLWithPath: #filePath)
        dir.deleteLastPathComponent()                                  // …/SoloLedgerCoreTests
        let source = dir.appendingPathComponent("Fixtures/reports/reports-base.db")
        let actual = try FileHash.sha256HexOfRegularFile(at: source)
        XCTAssertEqual(actual, recorded,
                       "reports-base.db changed without regenerating the goldens — rerun make-report-goldens.mjs")
        XCTAssertEqual(record["path"] as? String,
                       "native/SoloLedger/Tests/SoloLedgerCoreTests/Fixtures/reports/reports-base.db")
    }

    // MARK: - The cases are DISCRIMINATING (this is why they exist)

    /// The hard constraint: "not configured" must be decided by the ABSENCE of the
    /// settings row, never by the computed value. That rule is only testable if a
    /// ledger with no rate row and a ledger with an explicit 0% rate produce
    /// DIFFERENT engine output — otherwise the later implementation could satisfy a
    /// value-based check and still be wrong.
    func testMissingRateAndExplicitZeroRateAreDistinguishable() throws {
        for locale in locales {
            let unset = try golden("unset-\(locale)-2025")
            let zero = try golden("zero-\(locale)-2025")
            XCTAssertNotEqual(NSDictionary(dictionary: unset), NSDictionary(dictionary: zero),
                              "\(locale): a missing rate row must not look like an explicit 0%")
        }
        // Spelled out for the two shapes, so a future reader sees WHAT differs.
        let unsetUS = try XCTUnwrap(try golden("unset-US-2025")["estimatedTax"] as? [String: Any])
        let zeroUS = try XCTUnwrap(try golden("zero-US-2025")["estimatedTax"] as? [String: Any])
        XCTAssertEqual(unsetUS["annualIncomeTax"] as? Double, 1100,
                       "today a missing rate silently applies China's 25% to a US ledger")
        XCTAssertEqual(zeroUS["annualIncomeTax"] as? Double, 0, "an explicit 0% is a real, different answer")
    }

    /// The stored rates deliberately differ from the engine's own fallbacks, so a
    /// mirror that reads a fallback where it should read the row produces a WRONG
    /// number instead of coincidentally matching.
    func testStoredRatesDifferFromTheEngineFallbacks() throws {
        let base = try XCTUnwrap(try golden("base-US-2025")["estimatedTax"] as? [String: Any])
        let unset = try XCTUnwrap(try golden("unset-US-2025")["estimatedTax"] as? [String: Any])
        XCTAssertEqual(base["annualIncomeTax"] as? Double, 880, "fixture stores 20%, not the 25% fallback")
        XCTAssertNotEqual(base["annualIncomeTax"] as? Double, unset["annualIncomeTax"] as? Double)
    }

    /// A rate that is PRESENT but not a number is what actually produces the NaN
    /// path — not a missing row, which quietly takes the fallback. CN degrades to
    /// JSON null while US degrades to 0; both are pinned so the mirror reproduces
    /// the asymmetry rather than tidying it.
    func testMalformedRateProducesTheNaNPathNotAFallback() throws {
        let cn = try XCTUnwrap(try golden("malformed-CN-2025")["incomeStatement"] as? [String: Any])
        XCTAssertTrue(cn["taxSurcharge"] is NSNull, "CN serializes NaN as null (cn.js has no || 0 guard)")
        XCTAssertTrue(cn["netProfit"] is NSNull, "the NaN propagates through the CN chain")
        let unsetCN = try XCTUnwrap(try golden("unset-CN-2025")["incomeStatement"] as? [String: Any])
        XCTAssertEqual(unsetCN["taxSurcharge"] as? Double, 24.45,
                       "a MISSING row takes the 12% fallback — it is not the NaN path")
    }

    /// 2024 holds only legacy sales/purchases rows and 2025 only transactions, so
    /// this pair pins that the source is chosen per period. It also pins two facts
    /// the mirror must reproduce rather than fix: the legacy rows carry no
    /// category_id so COGS is structurally 0 there, and shippingCost exists ONLY on
    /// the legacy table so CN's shipping deduction is always 0 on the transactions path.
    /// A period holding BOTH transactions and legacy rows reports only the
    /// transactions — the legacy rows inside that same window are silently dropped.
    /// That is an UNDER-count, and it is the reason the native app must say how many
    /// legacy records a period excludes rather than printing a total as if complete.
    ///
    /// The fixture makes this observable: it carries a legacy sale dated 2025-09-15
    /// and a legacy purchase dated 2025-09-20 — inside a year whose report is driven
    /// entirely by transactions — plus a legacy purchase dated 2024-07-05 that falls
    /// inside the spanning period. Neither contributes a cent.
    func testLegacyRowsInsideATransactionsPeriodAreSilentlyExcluded() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "reports", withExtension: nil))
            .appendingPathComponent("reports-base.db")
        let store = try LedgerStore(databaseURL: url)
        let sales2025 = try store.db.query(
            "SELECT COUNT(*) AS c FROM sales WHERE date >= '2025-01-01' AND date <= '2025-12-31'")
            .first?.int("c")
        let purchases2025 = try store.db.query(
            "SELECT COUNT(*) AS c FROM purchases WHERE date >= '2025-01-01' AND date <= '2025-12-31'")
            .first?.int("c")
        XCTAssertEqual(sales2025, 1, "fixture assumption: a legacy sale sits inside 2025")
        XCTAssertEqual(purchases2025, 1, "fixture assumption: a legacy purchase sits inside 2025")

        // 2025 revenue is exactly the transactions figure; the 5000/5650 legacy sale
        // in the same year appears nowhere.
        let mixed = try XCTUnwrap(try golden("base-CN-2025")["incomeStatement"] as? [String: Any])
        XCTAssertEqual(mixed["salesRevenue"] as? Double, 12233.96,
                       "the same-period legacy sale must not be added in")

        // Same story for a window that straddles the boundary.
        let spanning = try XCTUnwrap(try golden("base-CN-2024H2-2025H1")["incomeStatement"] as? [String: Any])
        XCTAssertEqual(spanning["salesRevenue"] as? Double, 12233.96)
        XCTAssertEqual(spanning["shippingFee"] as? Double, 0,
                       "the in-window legacy purchase contributes nothing, shipping included")
    }

    func testAdjacentPeriodsUseDifferentSourcesAndPinTheirQuirks() throws {
        let legacy = try XCTUnwrap(try golden("base-CN-2024")["incomeStatement"] as? [String: Any])
        let txns = try XCTUnwrap(try golden("base-CN-2025")["incomeStatement"] as? [String: Any])
        XCTAssertEqual(legacy["shippingFee"] as? Double, 300, "legacy rows carry shippingCost")
        XCTAssertEqual(txns["shippingFee"] as? Double, 0, "the transactions table has no shippingCost column")
        XCTAssertEqual(legacy["costOfSales"] as? Double, 0, "legacy rows have no category_id, so no COGS")
        XCTAssertNotEqual(txns["costOfSales"] as? Double, 0, "the transactions period does split COGS")
    }
}
