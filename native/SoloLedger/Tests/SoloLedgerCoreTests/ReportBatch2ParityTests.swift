import XCTest
@testable import SoloLedgerCore

/// Batch-2 parity: `taxInclusiveSummary`, `monthlyBreakdown` and
/// `cashflowStatement`, against all 54 committed goldens.
///
/// ## What this layer proves, and what it does not
///
/// It proves the arithmetic agrees on the data the fixture happens to hold. R2
/// established, the hard way, that this is much less than it sounds: all 360
/// batch-1 fields matched while four of six deliberate mutations passed
/// unnoticed. So this file is layer one of three, and `ReportBatch2BlindSpotTests`
/// is where most of `_cashflow.js` is actually pinned — of seventeen mutations
/// probed against that file, sixteen are invisible here.
///
/// The goldens are FROZEN: no commit in this PR declares
/// `Allowed-Golden-Changes`, so if Swift and a golden disagree, Swift is wrong.
///
/// ## The legacy periods are compared through a TEST-ONLY path
///
/// Six goldens (`base-{CN,EU,JP,KR,TW,US}-2024`) were generated from the legacy
/// `sales` / `purchases` tables, which the native app does not read (plan §6.1,
/// per #395). Their cash-flow figures — inflow 9040 / outflow 7780 / net 1260 —
/// are therefore not reproducible by production code BY DESIGN.
///
/// They are still asserted, through a test-local mirror of the legacy SQL, for the
/// same reason R2 did it: without them the entire legacy branch of `_cashflow.js`
/// would have zero coverage. What production does for those periods is asserted
/// separately, in `testProductionEmitsNotConfiguredForLegacyPeriods`.
final class ReportBatch2ParityTests: LedgerTestCase {

    private func bundledFixtureURL() throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: "reports", withExtension: nil),
                      "report fixtures missing from the test bundle")
            .appendingPathComponent("reports-base.db")
    }

    private func fixtureCopy(_ name: String) throws -> URL {
        let dst = try trackedTempDir().appendingPathComponent("\(name).db")
        try FileManager.default.copyItem(at: try bundledFixtureURL(), to: dst)
        return dst
    }

    private func goldensDirectory() throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: "reports", withExtension: nil))
            .appendingPathComponent("goldens")
    }

    private func golden(_ name: String) throws -> [String: Any] {
        let url = try goldensDirectory().appendingPathComponent("\(name).json")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url))
                             as? [String: Any], "\(name).json is not an object")
    }

    private static let rateKeys = ["vat_rate", "surcharge_rate", "income_tax_rate",
                                   "admin_expense_annual"]

    /// The same mutations `make-report-goldens.mjs:80-101` applies.
    private func applyVariant(_ variant: String, to db: SQLiteDatabase) throws {
        switch variant {
        case "base": break
        case "unset":
            let list = Self.rateKeys.map { "'\($0)'" }.joined(separator: ",")
            try db.execute("DELETE FROM settings WHERE key IN (\(list))")
        case "zero":
            for key in Self.rateKeys {
                try db.execute("""
                    INSERT INTO settings (key, value, updated_at) VALUES ('\(key)', '0', datetime('now'))
                    ON CONFLICT(key) DO UPDATE SET value='0', updated_at=datetime('now')
                    """)
            }
        case "malformed":
            for (key, raw) in [("surcharge_rate", "\"12%\""), ("income_tax_rate", "\"25%\"")] {
                try db.execute("""
                    INSERT INTO settings (key, value, updated_at) VALUES ('\(key)', '\(raw)', datetime('now'))
                    ON CONFLICT(key) DO UPDATE SET value='\(raw)', updated_at=datetime('now')
                    """)
            }
        default: XCTFail("unknown variant \(variant)")
        }
    }

    private static let variantPeriods: [(String, [String])] = [
        ("base", ["2024", "2025", "2026", "2025Q2", "2025-06", "2024H2-2025H1"]),
        ("malformed", ["2025"]), ("unset", ["2025"]), ("zero", ["2025"]),
    ]
    private static let periods: [String: (year: String, from: String, to: String)] = [
        "2024": ("2024", "2024-01-01", "2024-12-31"),
        "2025": ("2025", "2025-01-01", "2025-12-31"),
        "2026": ("2026", "2026-01-01", "2026-12-31"),
        "2025Q2": ("2025", "2025-04-01", "2025-06-30"),
        "2025-06": ("2025", "2025-06-01", "2025-06-30"),
        "2024H2-2025H1": ("2025", "2024-07-01", "2025-06-30"),
    ]
    private static let locales = ["CN", "US", "JP", "EU", "KR", "TW"]

    // MARK: - TEST-ONLY legacy reads
    //
    // Mirrors of index.js:60-63 and _cashflow.js:67-80. These exist ONLY here.
    // `testNoProductionSymbolReadsTheLegacyTables` asserts that Sources/ contains
    // no reference to either table, so this cannot quietly become a product path.

    private func legacyRows(_ db: SQLiteDatabase, table: String,
                            from: String, to: String) throws -> [ReportRow] {
        let alias = table == "sales" ? "customer as counterparty" : "supplier as counterparty"
        return try db.query(
            "SELECT *, totalAmount as amount, amountWithoutTax as amount_net, " +
            "taxAmount as tax_amount, taxRate as tax_rate, \(alias) " +
            "FROM \(table) WHERE date >= ? AND date <= ? ORDER BY date",
            [.text(from), .text(to)]).map {
                ReportRow(amountNet: $0.double("amount_net"), amount: $0.double("amount"),
                          // The legacy SELECT never yields category_id.
                          categoryID: nil, shippingCost: $0.double("shippingCost"),
                          date: $0.string("date"))
            }
    }

    /// `_cashflow.js:67-80` — SUM(paid_amount) over paid/partial rows whose
    /// payment_date falls in the period. Note it windows on `payment_date` ALONE,
    /// with no COALESCE fallback to `date` — a different rule from the
    /// transactions branch.
    private func legacyCashflow(_ db: SQLiteDatabase, from: String, to: String) throws
        -> OperatingCashflow {
        func sum(_ table: String) throws -> Double {
            try db.query("""
                SELECT COALESCE(SUM(paid_amount), 0) AS s FROM \(table)
                 WHERE payment_status IN ('paid','partial')
                   AND payment_date IS NOT NULL AND payment_date >= ? AND payment_date <= ?
                """, [.text(from), .text(to)]).first?.double("s") ?? 0
        }
        let inflow = try sum("sales"), outflow = try sum("purchases")
        return OperatingCashflow(inflow: Cashflow.round2(inflow),
                                 outflow: Cashflow.round2(outflow),
                                 net: Cashflow.round2(inflow - outflow))
    }

    private func legacyContext(_ db: SQLiteDatabase, locale: String,
                               year: String, from: String, to: String) throws -> ReportContext {
        ReportContext(
            incomeRows: try legacyRows(db, table: "sales", from: from, to: to),
            expenseRows: try legacyRows(db, table: "purchases", from: from, to: to),
            categories: (try? ReportFetch.categories(db, locale: locale)) ?? [],
            adminExpense: ReportSettings.number(db, "admin_expense_annual", fallback: 0),
            incomeTaxRate: ReportSettings.incomeTaxRate(db, locale: locale),
            currency: ReportSettings.string(db, "currency", fallback: "CNY"),
            year: year, from: from, to: to)
    }

    // MARK: - Comparison helpers

    private func expect(_ block: [String: Any], _ key: String, _ actual: Double,
                        _ label: String, _ checked: inout Int) throws {
        let want = try XCTUnwrap(block[key] as? Double, "\(label): golden has no \(key)")
        XCTAssertEqual(actual, want, "\(label).\(key) — golden \(want), Swift \(actual)")
        checked += 1
    }

    // MARK: - The parity sweep

    func testBatchTwoMatchesEveryGoldenField() throws {
        var checked = 0
        var legacyCashflowSeen = 0

        for (variant, periodIDs) in Self.variantPeriods {
            let url = try fixtureCopy(variant)
            let db = try SQLiteDatabase(path: url.path, mode: .readWriteExisting)
            try applyVariant(variant, to: db)

            for locale in Self.locales {
                for periodID in periodIDs {
                    let p = try XCTUnwrap(Self.periods[periodID])
                    let label = "\(variant)-\(locale)-\(periodID)"
                    let g = try golden(label)

                    let hasTable = try ReportFetch.hasTransactionsTable(db)
                    let count = try ReportFetch.periodTransactionCount(db, from: p.from, to: p.to)
                    let source = selectReportSource(hasTransactionsTable: hasTable,
                                                    periodTxnCount: count)

                    // Build the context the way the golden's source demands. For a
                    // transactions period this is exactly what production does; for
                    // a legacy period it is the test-only mirror.
                    let ctx: ReportContext
                    if source == .transactions {
                        ctx = ReportContext(
                            incomeRows: try ReportFetch.rows(db, type: "income", from: p.from, to: p.to),
                            expenseRows: try ReportFetch.rows(db, type: "expense", from: p.from, to: p.to),
                            categories: (try? ReportFetch.categories(db, locale: locale)) ?? [],
                            adminExpense: ReportSettings.number(db, "admin_expense_annual", fallback: 0),
                            incomeTaxRate: ReportSettings.incomeTaxRate(db, locale: locale),
                            currency: ReportSettings.string(db, "currency", fallback: "CNY"),
                            year: p.year, from: p.from, to: p.to)
                    } else {
                        ctx = try legacyContext(db, locale: locale,
                                                year: p.year, from: p.from, to: p.to)
                    }

                    // --- taxInclusiveSummary (five engines; the US has none) ---
                    if locale == "US" {
                        XCTAssertNil(g["taxInclusiveSummary"],
                                     "us.js emits no taxInclusiveSummary at all")
                    } else {
                        let block = try XCTUnwrap(g["taxInclusiveSummary"] as? [String: Any], label)
                        let tis: TaxInclusiveSummary
                        switch locale {
                        case "CN": tis = CNReportEngine.taxInclusiveSummary(ctx)
                        case "JP": tis = JPReportEngine.taxInclusiveSummary(ctx)
                        case "EU": tis = EUReportEngine.taxInclusiveSummary(ctx)
                        case "KR": tis = KRReportEngine.taxInclusiveSummary(ctx)
                        default:   tis = TWReportEngine.taxInclusiveSummary(ctx)
                        }
                        try expect(block, "purchaseTotal", tis.purchaseTotal, label, &checked)
                        try expect(block, "salesTotal", tis.salesTotal, label, &checked)
                        try expect(block, "difference", tis.difference, label, &checked)
                    }

                    // --- monthlyBreakdown (all six; always twelve entries) ---
                    let months = try XCTUnwrap(g["monthlyBreakdown"] as? [[String: Any]], label)
                    XCTAssertEqual(months.count, 12, "\(label): A9 — always 12 calendar months")
                    let mine: [ReportMonth]
                    switch locale {
                    case "CN": mine = CNReportEngine.monthlyBreakdown(ctx)
                    case "JP": mine = JPReportEngine.monthlyBreakdown(ctx)
                    case "EU": mine = EUReportEngine.monthlyBreakdown(ctx)
                    case "KR": mine = KRReportEngine.monthlyBreakdown(ctx)
                    case "TW": mine = TWReportEngine.monthlyBreakdown(ctx)
                    default:   mine = USReportEngine.monthlyBreakdown(ctx)
                    }
                    XCTAssertEqual(mine.count, 12)
                    for (i, want) in months.enumerated() {
                        let got = mine[i]
                        let ml = "\(label).month[\(i + 1)]"
                        XCTAssertEqual(got.month, want["month"] as? Int, ml)
                        checked += 1
                        try expect(want, "revenue", got.revenue, ml, &checked)
                        try expect(want, "cost", got.cost, ml, &checked)
                        try expect(want, "profit", got.profit, ml, &checked)
                    }

                    // --- cashflowStatement ---
                    let cf = try XCTUnwrap(g["cashflowStatement"] as? [String: Any], label)
                    XCTAssertEqual(cf["basis"] as? String, "cash", label); checked += 1
                    XCTAssertEqual(cf["statutory"] as? Bool, false, label); checked += 1
                    XCTAssertEqual(cf["source"] as? String, source.rawValue, label); checked += 1
                    let op = try XCTUnwrap(cf["operating"] as? [String: Any], label)
                    let operating: OperatingCashflow
                    if source == .transactions {
                        operating = Cashflow.operating(
                            rows: try ReportFetch.cashflowRows(db, from: p.from, to: p.to))
                    } else {
                        legacyCashflowSeen += 1
                        operating = try legacyCashflow(db, from: p.from, to: p.to)
                    }
                    try expect(op, "inflow", operating.inflow, label, &checked)
                    try expect(op, "outflow", operating.outflow, label, &checked)
                    try expect(op, "net", operating.net, label, &checked)
                    // The four that must be null and can never be a number.
                    for key in ["investing", "financing", "beginningCash", "endingCash"] {
                        XCTAssertTrue(cf[key] is NSNull,
                                      "\(label).\(key) must be JSON null, never 0 or absent")
                        XCTAssertNotNil(cf.index(forKey: key), "\(label).\(key) key must EXIST")
                        checked += 1
                    }
                }
            }
        }

        // 54 goldens: 6 locales x (6 base periods + 3 variants).
        //   taxInclusiveSummary  3 x 45 non-US            = 135
        //   monthlyBreakdown     54 x 12 x 4              = 2592
        //   cashflowStatement    54 x (3 + 3 + 4)         = 540
        XCTAssertEqual(checked, 3267, "expected 135 + 2592 + 540 golden-asserted fields")
        XCTAssertEqual(legacyCashflowSeen, 6,
                       "all six 2024 goldens are legacy-sourced — US included, unlike batch 1")
    }

    /// What PRODUCTION does for those same six periods, which is deliberately NOT
    /// what the goldens contain.
    ///
    /// Electron reads the legacy tables and reports inflow 9040 / outflow 7780 /
    /// net 1260. The native app does not read them, so it has nothing to report —
    /// and the honest form of "nothing" is `.notConfigured`, not `{0, 0, 0}`.
    /// A zero here would be a confident statement that no cash moved, which is
    /// false, and CLAUDE.md's product boundary forbids exactly that.
    ///
    /// This is the assertion that makes the choice load-bearing rather than a
    /// comment.
    func testProductionEmitsNotConfiguredForLegacyPeriods() throws {
        let url = try fixtureCopy("legacy-production")
        let db = try SQLiteDatabase(path: url.path, mode: .readWriteExisting)

        for locale in Self.locales {
            let report = try ReportDispatcher.batchTwo(db, locale: locale, year: "2024",
                                                       from: "2024-01-01", to: "2024-12-31")
            XCTAssertEqual(report.cashflowStatement.source, .legacy, locale)
            XCTAssertEqual(report.cashflowStatement.operating, .notConfigured,
                           "\(locale): a period whose rows we do not read is NOT zero cash")
            // The golden, for contrast, carries real money for this very period.
            let g = try golden("base-\(locale)-2024")
            let cf = try XCTUnwrap(g["cashflowStatement"] as? [String: Any])
            let op = try XCTUnwrap(cf["operating"] as? [String: Any])
            XCTAssertEqual(op["inflow"] as? Double, 9040,
                           "Electron reports real money here; that is the gap being disclosed")
        }

        // A transactions period still computes normally.
        let ok = try ReportDispatcher.batchTwo(db, locale: "CN", year: "2025",
                                               from: "2025-01-01", to: "2025-12-31")
        guard case .computed(let operating) = ok.cashflowStatement.operating else {
            return XCTFail("2025 has transactions and must compute")
        }
        XCTAssertEqual(operating.inflow, 12500)
    }

    /// §6.1, mechanically: no production symbol may reach the legacy tables.
    ///
    /// A comment saying "test-only" is worth nothing if the next PR adds a
    /// production read. This greps `Sources/` — where a match would be a product
    /// path — while `Tests/` is allowed to name them.
    func testNoProductionSymbolReadsTheLegacyTables() throws {
        var dir = URL(fileURLWithPath: #filePath)
        dir.deleteLastPathComponent()                       // …/SoloLedgerCoreTests
        dir.deleteLastPathComponent()                       // …/Tests
        dir.deleteLastPathComponent()                       // …/SoloLedger
        let sources = dir.appendingPathComponent("Sources/SoloLedgerCore/Reports")
        let files = try FileManager.default.contentsOfDirectory(atPath: sources.path)
            .filter { $0.hasSuffix(".swift") }
        XCTAssertGreaterThan(files.count, 10, "the Reports directory did not resolve")

        for file in files {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for line in text.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces)
                .hasPrefix("//") {
                XCTAssertFalse(line.contains("FROM sales") || line.contains("FROM purchases"),
                               "\(file) reads a legacy table in PRODUCTION code — plan §6.1 " +
                               "says the native app never does. Keep it in the tests.")
            }
        }
    }
}
