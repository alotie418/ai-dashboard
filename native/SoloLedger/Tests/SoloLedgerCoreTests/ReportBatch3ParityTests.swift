import XCTest
@testable import SoloLedgerCore

/// Batch-3 parity: `scheduleC`, against all 9 US goldens — 225 fields.
///
/// ## READ THIS BEFORE TRUSTING THE GREEN TICK
///
/// This suite asserts every golden-observable Schedule C field and they all match.
/// That is a much weaker statement than it sounds, and the numbers are worth
/// stating rather than leaving a reader to assume:
///
/// * **195 of the 250 asserted cells are the literal 0.** The fixture's US rows
///   touch few lines, so most of the comparison is zero-against-zero.
/// * **There are only 5 distinct `scheduleC` vectors** across the 10 goldens — the
///   count did not move when A4-3 added a tenth, because that variant differs only in
///   a rate and Schedule C reads none.
/// * **Only 4 of the 19 slug→line mappings are pinned here** — advertising, meals,
///   home-office and other — and three of those four rest on `base-US-2026` alone.
///
/// Measured, not inferred: pointing any of the other 15 lookups at an impossible
/// slug changes **zero** golden fields, and swapping `line20_rent` with
/// `line21_repairs`, or mistyping `car-truck` as `car_truck`, produces a
/// byte-identical `scheduleC` on every base period.
///
/// The mapping table IS this batch's deliverable, so those 15 are covered
/// elsewhere and on purpose: `ReportBatch3BlindSpotTests` exercises all 19 against
/// the real engine, and `testTheMappingAgreesWithTheLedgersOwnScheduleLineColumn`
/// below checks them against an INDEPENDENT oracle that was already committed —
/// the fixture's own `categories.schedule_line` column. Widening the fixture so the
/// goldens could cover them was considered and declined; that coverage is
/// permanent as it stands.
///
/// The goldens this file READS are not frozen in A4-3 — that batch declares the
/// `malformed-*` series and adds `malformed-raw-*` — but this file changes none of
/// them; it only follows the counts.
final class ReportBatch3ParityTests: LedgerTestCase {

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

    private func golden(_ name: String) throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "reports", withExtension: nil))
            .appendingPathComponent("goldens").appendingPathComponent("\(name).json")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url))
                             as? [String: Any], "\(name).json is not an object")
    }

    private static let rateKeys = ["vat_rate", "surcharge_rate", "income_tax_rate",
                                   "admin_expense_annual"]

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
        case "malformed-raw":
            // Bytes that are not JSON at all — note the absent quoting, which is the
            // whole point of the variant.
            for (key, raw) in [("surcharge_rate", "12%"), ("income_tax_rate", "25%")] {
                try db.execute("""
                    INSERT INTO settings (key, value, updated_at) VALUES ('\(key)', '\(raw)', datetime('now'))
                    ON CONFLICT(key) DO UPDATE SET value='\(raw)', updated_at=datetime('now')
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
        ("malformed", ["2025"]), ("malformed-raw", ["2025"]), ("unset", ["2025"]), ("zero", ["2025"]),
    ]
    private static let periods: [String: (year: String, from: String, to: String)] = [
        "2024": ("2024", "2024-01-01", "2024-12-31"),
        "2025": ("2025", "2025-01-01", "2025-12-31"),
        "2026": ("2026", "2026-01-01", "2026-12-31"),
        "2025Q2": ("2025", "2025-04-01", "2025-06-30"),
        "2025-06": ("2025", "2025-06-01", "2025-06-30"),
        "2024H2-2025H1": ("2025", "2024-07-01", "2025-06-30"),
    ]

    /// TEST-ONLY legacy reads — the third copy, and deliberately not extracted.
    ///
    /// Batch 1 and batch 2 each carry their own with an "exists ONLY here" comment.
    /// Consolidating them would edit two shipped test files inside a mirror PR and
    /// invalidate both comments; it is a clean standalone follow-up, not this
    /// batch's problem. `ReportBatch2ParityTests.testNoProductionSymbolReadsTheLegacyTables`
    /// still fences all three.
    private func legacyRows(_ db: SQLiteDatabase, table: String,
                            from: String, to: String) throws -> [ReportRow] {
        let alias = table == "sales" ? "customer as counterparty" : "supplier as counterparty"
        return try db.query(
            "SELECT *, totalAmount as amount, amountWithoutTax as amount_net, " +
            "taxAmount as tax_amount, taxRate as tax_rate, \(alias) " +
            "FROM \(table) WHERE date >= ? AND date <= ? ORDER BY date",
            [.text(from), .text(to)]).map {
                ReportRow(amountNet: $0.double("amount_net"), amount: $0.double("amount"),
                          categoryID: nil, shippingCost: $0.double("shippingCost"),
                          date: $0.string("date"))
            }
    }

    private func context(_ db: SQLiteDatabase, period p: (year: String, from: String, to: String))
        throws -> ReportContext {
        let hasTable = try ReportFetch.hasTransactionsTable(db)
        let count = try ReportFetch.periodTransactionCount(db, from: p.from, to: p.to)
        let source = selectReportSource(hasTransactionsTable: hasTable, periodTxnCount: count)
        let income: [ReportRow], expense: [ReportRow]
        if source == .transactions {
            income = try ReportFetch.rows(db, type: "income", from: p.from, to: p.to)
            expense = try ReportFetch.rows(db, type: "expense", from: p.from, to: p.to)
        } else {
            income = try legacyRows(db, table: "sales", from: p.from, to: p.to)
            expense = try legacyRows(db, table: "purchases", from: p.from, to: p.to)
        }
        return ReportContext(
            incomeRows: income, expenseRows: expense,
            categories: (try? ReportFetch.categories(db, locale: "US")) ?? [],
            adminExpense: ReportSettings.number(db, "admin_expense_annual", fallback: 0),
            incomeTaxRate: ReportSettings.incomeTaxRate(db, locale: "US"),
            surchargeRate: ReportSettings.surchargeRate(db, locale: "US"),
            currency: ReportSettings.string(db, "currency", fallback: "CNY"),
            year: p.year, from: p.from, to: p.to)
    }

    /// Every field, keyed exactly as the golden keys them.
    private func fields(_ s: ScheduleC) -> [(String, Double)] {
        [("line1_grossReceipts", s.line1_grossReceipts), ("line2_returns", s.line2_returns),
         ("line6_otherIncome", s.line6_otherIncome), ("line7_grossIncome", s.line7_grossIncome),
         ("line8_advertising", s.line8_advertising), ("line9_car", s.line9_car),
         ("line10_commissions", s.line10_commissions), ("line11_contract", s.line11_contract),
         ("line13_depreciation", s.line13_depreciation), ("line15_insurance", s.line15_insurance),
         ("line16b_interest", s.line16b_interest), ("line17_legal", s.line17_legal),
         ("line18_office", s.line18_office), ("line20_rent", s.line20_rent),
         ("line21_repairs", s.line21_repairs), ("line22_supplies", s.line22_supplies),
         ("line23_taxes", s.line23_taxes), ("line24a_travel", s.line24a_travel),
         ("line24b_meals", s.line24b_meals), ("line25_utilities", s.line25_utilities),
         ("line26_wages", s.line26_wages), ("line27a_other", s.line27a_other),
         ("line30_homeOffice", s.line30_homeOffice),
         ("line28_totalExpenses", s.line28_totalExpenses),
         ("line31_netProfit", s.line31_netProfit)]
    }

    func testScheduleCMatchesEveryGoldenField() throws {
        var checked = 0, zeros = 0, legacyPeriodsSeen = 0
        var vectors = Set<String>()

        for (variant, periodIDs) in Self.variantPeriods {
            let url = try fixtureCopy("b3-\(variant)")
            let db = try SQLiteDatabase(path: url.path, mode: .readWriteExisting)
            try applyVariant(variant, to: db)

            for periodID in periodIDs {
                let p = try XCTUnwrap(Self.periods[periodID])
                let label = "\(variant)-US-\(periodID)"
                let block = try XCTUnwrap(try golden(label)["scheduleC"] as? [String: Any], label)
                if try ReportFetch.periodTransactionCount(db, from: p.from, to: p.to) == 0 {
                    legacyPeriodsSeen += 1
                }
                let mine = USReportEngine.scheduleC(try context(db, period: p))

                XCTAssertEqual(block.count, 25, "\(label): golden scheduleC key count")
                for (key, value) in fields(mine) {
                    let want = try XCTUnwrap(block[key] as? Double, "\(label): golden has no \(key)")
                    XCTAssertEqual(value, want, "\(label).\(key) — golden \(want), Swift \(value)")
                    if want == 0 { zeros += 1 }
                    checked += 1
                }
                vectors.insert(fields(mine).map { "\($0.1)" }.joined(separator: ","))
            }
        }

        XCTAssertEqual(checked, 250, "10 US goldens x 25 scheduleC fields")
        // The discrimination facts, asserted rather than described — if the fixture
        // ever gains US rows these numbers move and this header stops being true.
        //
        // A4-3 added `malformed-raw-US-2025`, so the counts went 225 → 250 and
        // 175 → 195. That is 25 more cells and 20 more zeros, and it buys NO new
        // discrimination for Schedule C: the new variant differs only in a rate, and
        // Schedule C reads none — `vectors.count` is still 5, which is the assertion
        // that says so. The numbers are updated because they are facts, not because
        // coverage improved.
        XCTAssertEqual(zeros, 195, "195 of the 250 asserted cells are the literal 0")
        XCTAssertEqual(vectors.count, 5, "only 5 distinct scheduleC vectors exist")
        XCTAssertEqual(legacyPeriodsSeen, 1, "base-US-2024 is the one legacy-sourced US golden")
    }

    /// Plan §2 claims batch 3 is "完全不受 incomeTaxRate 影响". This turns that
    /// sentence into a machine check, for free, using goldens already on disk:
    /// `scheduleC` is byte-identical across all four rate variants while
    /// `estimatedTax.annualIncomeTax` moves 880 / null / 0 / null / null.
    ///
    /// `unset` reads null rather than a number because a MISSING settings row is no
    /// longer priced at China's 25% fallback (plan §9.1 scheme A). The KEY still has
    /// to be there — a field that vanished would be a contract change, not a refusal
    /// to guess — so the raw value is unwrapped first and only then narrowed.
    func testScheduleCIsUnaffectedByEveryRateVariant() throws {
        var blocks: [String: NSDictionary] = [:]
        var incomeTaxes: [String: Double] = [:]
        var incomeTaxIsNull: [String: Bool] = [:]
        for variant in ["base", "unset", "zero", "malformed", "malformed-raw"] {
            let g = try golden("\(variant)-US-2025")
            blocks[variant] = NSDictionary(dictionary:
                try XCTUnwrap(g["scheduleC"] as? [String: Any]))
            let estimated = try XCTUnwrap(g["estimatedTax"] as? [String: Any])
            let raw = try XCTUnwrap(estimated["annualIncomeTax"],
                                    "\(variant): the annualIncomeTax key must exist even when null")
            incomeTaxIsNull[variant] = raw is NSNull
            incomeTaxes[variant] = raw as? Double
        }
        for variant in ["unset", "zero", "malformed", "malformed-raw"] {
            XCTAssertEqual(blocks["base"], blocks[variant],
                           "scheduleC must not move with the rate — \(variant)")
        }
        // …while the estimate layer, which IS rate-driven, moves a great deal.
        XCTAssertEqual(incomeTaxes["base"], 880)
        XCTAssertEqual(incomeTaxIsNull["unset"], true,
                       "a missing rate row is not priced — null, never a number")
        XCTAssertNil(incomeTaxes["unset"])
        XCTAssertEqual(incomeTaxes["zero"], 0)
        // A4-3: an unusable rate is REFUSED, so there is no number here at all. It
        // used to read 0 — `Number("25%")` is NaN and us.js's `|| 0` rounder flattened
        // it — which was indistinguishable from a ledger that configured 0%.
        XCTAssertEqual(incomeTaxIsNull["malformed"], true,
                       "a corrupt rate is not priced at 0")
        XCTAssertNil(incomeTaxes["malformed"])
        // …and the same for bytes that are not JSON at all, which used to be WORSE:
        // readSetting's catch returned the fallback, so this read 1100 — China's 25%
        // silently applied to a US ledger, the very number scheme A removed.
        XCTAssertEqual(incomeTaxIsNull["malformed-raw"], true,
                       "the fallback must not come back through the parse-failure door")
        XCTAssertNil(incomeTaxes["malformed-raw"])
    }

    /// The INDEPENDENT oracle for the 15 mappings no golden reaches.
    ///
    /// The fixture's `categories` table carries a `schedule_line` column, written
    /// when the fixture was built and never consulted by any engine. It is
    /// therefore a second, already-committed statement of the same mapping — so a
    /// transposed or mistyped slug literal in the Swift table disagrees with it
    /// even though every golden stays green.
    ///
    /// Two documented exceptions, both defects rather than test problems:
    /// `home-office` says `Form 8829` because that is where it belongs on the real
    /// form (while the engine sums it into Line 28 — defect 2), and lines 28/31 are
    /// derived, so no category names them.
    func testTheMappingAgreesWithTheLedgersOwnScheduleLineColumn() throws {
        let db = try SQLiteDatabase(path: try fixtureCopy("b3-oracle").path,
                                    mode: .readWriteExisting)
        var oracle: [String: String] = [:]
        for row in try db.query(
            "SELECT slug, schedule_line FROM categories WHERE locale = 'US' AND schedule_line IS NOT NULL") {
            oracle[row.string("slug") ?? ""] = row.string("schedule_line") ?? ""
        }
        XCTAssertEqual(oracle.count, 22, "19 expense + 3 income US categories carry the column")

        // The Swift side's table, spelled out so a disagreement names the slug.
        let mapping: [(slug: String, line: String)] = [
            ("advertising", "Schedule C Line 8"), ("car-truck", "Schedule C Line 9"),
            ("commissions", "Schedule C Line 10"), ("contract-labor", "Schedule C Line 11"),
            ("depreciation", "Schedule C Line 13"), ("insurance", "Schedule C Line 15"),
            ("interest", "Schedule C Line 16b"), ("legal-pro", "Schedule C Line 17"),
            ("office", "Schedule C Line 18"), ("rent", "Schedule C Line 20"),
            ("repairs", "Schedule C Line 21"), ("supplies", "Schedule C Line 22"),
            ("taxes", "Schedule C Line 23"), ("travel", "Schedule C Line 24a"),
            ("meals", "Schedule C Line 24b"), ("utilities", "Schedule C Line 25"),
            ("wages", "Schedule C Line 26"), ("other", "Schedule C Line 27a"),
            ("gross-receipts", "Schedule C Line 1"), ("returns", "Schedule C Line 2"),
            ("other-income", "Schedule C Line 6"),
        ]
        for (slug, line) in mapping {
            XCTAssertEqual(oracle[slug], line,
                           "the engine maps '\(slug)' to \(line); the ledger disagrees")
        }
        // The exception, asserted so it cannot drift silently.
        XCTAssertEqual(oracle["home-office"], "Form 8829",
                       "home-office is NOT a Schedule C line — yet us.js sums it into Line 28")
        XCTAssertEqual(mapping.count + 1, oracle.count, "every US category is accounted for")
    }
}
