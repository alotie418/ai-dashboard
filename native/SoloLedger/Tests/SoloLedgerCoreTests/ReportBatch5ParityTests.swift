import XCTest
@testable import SoloLedgerCore

/// Batch-5 parity: the estimate layer, against every golden that carries one.
///
/// ## READ THIS BEFORE TRUSTING THE GREEN TICK
///
/// Counted, not estimated — 60 goldens, 270 estimate-layer scalar cells (215 numeric,
/// 55 null). Most of that surface is weaker than the number suggests:
///
/// * **`additionalMedicare` is 0 in all ten US goldens.** The threshold is 200,000
///   and the fixture's largest `seEarnings` is 39,479.63. Writing `return 0`,
///   mistyping the threshold, mistyping the rate, or flipping `>` to `<` moves no
///   cell. Covered in `ReportBatch5BlindSpotTests` instead.
/// * **The social-security wage cap never binds** — same reason. `Math.min` could be
///   deleted entirely and every golden would still pass.
/// * **`paramYear` is the only golden-visible evidence that the constant table is
///   year-keyed.** The three keyed years differ only in `ssWageCap`, which never
///   binds; hard-coding one year's constants and passing `paramYear` through would
///   be invisible here.
/// * **`annualSETax` ≡ `totalSETax`** and **`netEarnings` ≡ `line31_netProfit`** —
///   the same JS variables (`us.js:74`, `us.js:66`). No input separates either pair.
/// * **JP / EU / KR / TW produce identical estimate triples in every variant.**
///   120 cells carry 30 distinct values; wiring Korea's engine to Japan's is
///   undetectable here.
/// * **`malformed-raw-*` is byte-identical to `malformed-*`** for these blocks. It
///   adds 0 bits of discrimination to the estimate layer — its value is entirely in
///   the settings-reading layer, where `ReportRateSettingTests` covers it.
/// * **`notConfigured` and `needsRepair` are indistinguishable to every golden.**
///   Both are `null` in the JSON. That distinction is asserted by the type-level
///   tests, never here, and a green run of this file says nothing about it.
///
/// Real arithmetic — a rate actually multiplied into a non-zero number — happens in
/// single digits: six cells across the five VAT regimes, eighteen for the US.
///
/// ## Exact comparison, deliberately
///
/// Plan §4.2 permits `eps = 0.011` for golden comparison. This suite does NOT use it,
/// for one measured reason: `totalAnnual` is unrounded (`us.js:82`) and two goldens
/// carry the float tail that proves it — `base-US-2024` = `1542.6599999999999` and
/// `base-US-2026` = `14590.380000000001`. A tolerance of half a cent swallows exactly
/// that difference, and with it the only evidence that the mirror did not "tidy" the
/// sum.
///
/// **The goldens are FROZEN here** — this suite reads them and changes none; no commit
/// in R7 declares `Allowed-Golden-Changes`.
final class ReportBatch5ParityTests: LedgerTestCase {

    // MARK: - Fixture plumbing

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

    /// The generator's own mutations (`make-report-goldens.mjs:81-113`), including the
    /// `malformed-raw` family A4-3 added. Batches 1–4 predate that family and their
    /// variant lists stop at four — copying one of those would silently narrow this
    /// matrix, so the five are spelled out here.
    private static let variants = ["base", "unset", "zero", "malformed", "malformed-raw"]
    private static let rateKeys = ["vat_rate", "surcharge_rate", "income_tax_rate",
                                   "admin_expense_annual"]

    private func applyVariant(_ variant: String, to db: SQLiteDatabase) throws {
        func put(_ key: String, _ raw: String) throws {
            try db.execute("""
                INSERT INTO settings (key, value, updated_at)
                VALUES ('\(key)', '\(raw)', datetime('now'))
                ON CONFLICT(key) DO UPDATE SET value='\(raw)', updated_at=datetime('now')
                """)
        }
        switch variant {
        case "base": break
        case "unset":
            let list = Self.rateKeys.map { "'\($0)'" }.joined(separator: ",")
            try db.execute("DELETE FROM settings WHERE key IN (\(list))")
        case "zero":
            for key in Self.rateKeys { try put(key, "0") }
        case "malformed":                       // valid JSON, unusable content
            try put("surcharge_rate", "\"12%\"")
            try put("income_tax_rate", "\"25%\"")
        case "malformed-raw":                   // not JSON at all — note the quoting
            try put("surcharge_rate", "12%")
            try put("income_tax_rate", "25%")
        default: XCTFail("unknown variant \(variant)")
        }
    }

    private static let periods: [String: (year: String, from: String, to: String)] = [
        "2024": ("2024", "2024-01-01", "2024-12-31"),
        "2025": ("2025", "2025-01-01", "2025-12-31"),
        "2026": ("2026", "2026-01-01", "2026-12-31"),
        "2025Q2": ("2025", "2025-04-01", "2025-06-30"),
        "2025-06": ("2025", "2025-06-01", "2025-06-30"),
        "2024H2-2025H1": ("2025", "2024-07-01", "2025-06-30"),
    ]
    private static let variantPeriods: [(String, [String])] = [
        ("base", ["2024", "2025", "2026", "2025Q2", "2025-06", "2024H2-2025H1"]),
        ("unset", ["2025"]), ("zero", ["2025"]),
        ("malformed", ["2025"]), ("malformed-raw", ["2025"]),
    ]

    /// TEST-ONLY legacy reads. The fourth copy in this suite family, and deliberately
    /// not extracted for the reason batch 3 gives: consolidating would edit shipped
    /// test files and invalidate their "exists ONLY here" comments.
    private func legacyRows(_ db: SQLiteDatabase, table: String,
                            from: String, to: String) throws -> [ReportRow] {
        let alias = table == "sales" ? "customer as counterparty" : "supplier as counterparty"
        return try db.query(
            "SELECT *, totalAmount as amount, amountWithoutTax as amount_net, " +
            "taxAmount as tax_amount, taxRate as tax_rate, \(alias) " +
            "FROM \(table) WHERE date >= ? AND date <= ? ORDER BY date",
            [.text(from), .text(to)]).map {
                ReportRow(amountNet: $0.double("amount_net"), amount: $0.double("amount"),
                          // `taxAmount` is load-bearing HERE where it was not in
                          // batch 1: China's surcharge rides on the VAT payable, and
                          // dropping it silently reports `base-CN-2024` as
                          // taxSurcharge 0 / operatingProfit -8300 instead of 52 /
                          // -8352. The parity sweep caught exactly that.
                          taxAmount: $0.double("tax_amount"), categoryID: nil,
                          shippingCost: $0.double("shippingCost"),
                          date: $0.string("date"))
            }
    }

    private func context(_ db: SQLiteDatabase, locale: String,
                         period p: (year: String, from: String, to: String))
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
            categories: (try? ReportFetch.categories(db, locale: locale)) ?? [],
            adminExpense: ReportSettings.number(db, "admin_expense_annual", fallback: 0),
            incomeTaxRate: ReportSettings.incomeTaxRate(db, locale: locale),
            surchargeRate: ReportSettings.surchargeRate(db, locale: locale),
            currency: ReportSettings.string(db, "currency", fallback: "CNY"),
            year: p.year, from: p.from, to: p.to)
    }

    // MARK: - Comparison

    /// A golden cell against an ``EstimatedValue``, EXACTLY.
    ///
    /// JSON `null` must meet a refusal and a number must meet `.computed` — the two
    /// directions are separate assertions on purpose, so "the mirror computed
    /// something where the engine refused" and "the mirror refused where the engine
    /// computed" are different failures.
    private func expect(_ block: [String: Any], _ key: String, _ actual: EstimatedValue,
                        _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let raw = block[key]
        XCTAssertNotNil(raw, "\(label).\(key): the golden has no such key", file: file, line: line)
        if raw is NSNull {
            if case .computed(let v) = actual {
                XCTFail("\(label).\(key): golden refused, mirror computed \(v)", file: file, line: line)
            }
            return
        }
        guard let want = raw as? Double else {
            XCTFail("\(label).\(key): golden value is not a number", file: file, line: line); return
        }
        guard case .computed(let got) = actual else {
            XCTFail("\(label).\(key): golden \(want), mirror refused (\(actual))", file: file, line: line)
            return
        }
        XCTAssertEqual(got, want, "\(label).\(key) — golden \(want), Swift \(got)",
                       file: file, line: line)
    }

    private func expect(_ block: [String: Any], _ key: String, _ actual: Double,
                        _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let want = block[key] as? Double else {
            XCTFail("\(label).\(key): golden value is missing or not a number", file: file, line: line)
            return
        }
        XCTAssertEqual(actual, want, "\(label).\(key) — golden \(want), Swift \(actual)",
                       file: file, line: line)
    }

    // MARK: - The five VAT regimes

    func testTheFiveIncomeStatementsMatchEveryGoldenEstimateField() throws {
        var checked = 0, refused = 0, nonZero = 0
        for (variant, periodIDs) in Self.variantPeriods {
            let url = try fixtureCopy("b5-\(variant)")
            let db = try SQLiteDatabase(path: url.path)
            try applyVariant(variant, to: db)

            for pid in periodIDs {
                let p = try XCTUnwrap(Self.periods[pid])
                for locale in ["CN", "JP", "EU", "KR", "TW"] {
                    let label = "\(variant)-\(locale)-\(pid)"
                    let g = try golden(label)
                    let key = locale == "EU" ? "profitLoss" : "incomeStatement"
                    let block = try XCTUnwrap(g[key] as? [String: Any], "\(label): no \(key)")
                    let ctx = try context(db, locale: locale, period: p)

                    let fields: [(String, EstimatedValue)]
                    switch locale {
                    case "CN":
                        let s = CNReportEngine.batchOne(ctx)
                        fields = [("operatingProfit", s.operatingProfit),
                                  ("taxSurcharge", s.taxSurcharge),
                                  ("incomeTax", s.incomeTax),
                                  ("netProfit", s.netProfit),
                                  ("netMargin", s.netMargin)]
                    case "JP":
                        let s = JPReportEngine.batchOne(ctx)
                        fields = [("incomeTax", s.incomeTax), ("netProfit", s.netProfit),
                                  ("netMargin", s.netMargin)]
                    case "KR":
                        let s = KRReportEngine.batchOne(ctx)
                        fields = [("incomeTax", s.incomeTax), ("netProfit", s.netProfit),
                                  ("netMargin", s.netMargin)]
                    case "TW":
                        let s = TWReportEngine.batchOne(ctx)
                        fields = [("incomeTax", s.incomeTax), ("netProfit", s.netProfit),
                                  ("netMargin", s.netMargin)]
                    default:
                        let s = EUReportEngine.batchOne(ctx)
                        fields = [("incomeTax", s.incomeTax), ("netProfit", s.netProfit),
                                  ("netMargin", s.netMargin)]
                    }
                    for (name, value) in fields {
                        expect(block, name, value, label)
                        checked += 1
                        if block[name] is NSNull { refused += 1 }
                        else if let d = block[name] as? Double, d != 0 { nonZero += 1 }
                    }
                }
            }
        }
        // The size of the surface, asserted rather than described — if the fixture or
        // the variant list changes, these numbers move and the header stops being true.
        XCTAssertEqual(checked, 170, "5 VAT regimes across 10 golden variant/periods — CN carries 5 estimate fields, the other four carry 3")
        XCTAssertEqual(refused, 46, "46 of the 170 cells assert only that NOTHING was computed")
        XCTAssertEqual(nonZero, 90, "…and 90 carry a non-zero number, most of them operatingProfit values batch 1 already pinned")
    }

    // MARK: - The US

    func testTheUSEstimateBlocksMatchEveryGolden() throws {
        var seCells = 0, estimateCells = 0
        for (variant, periodIDs) in Self.variantPeriods {
            let url = try fixtureCopy("b5-us-\(variant)")
            let db = try SQLiteDatabase(path: url.path)
            try applyVariant(variant, to: db)

            for pid in periodIDs {
                let p = try XCTUnwrap(Self.periods[pid])
                let label = "\(variant)-US-\(pid)"
                let g = try golden(label)
                let ctx = try context(db, locale: "US", period: p)

                let se = USReportEngine.selfEmploymentTax(ctx)
                let seBlock = try XCTUnwrap(g["selfEmploymentTax"] as? [String: Any])
                XCTAssertEqual(Set(seBlock.keys),
                               Set(["netEarnings", "seEarnings", "socialSecurityTax", "medicareTax",
                                    "additionalMedicare", "totalSETax", "paramYear"]),
                               "\(label): every selfEmploymentTax key must be visited")
                expect(seBlock, "netEarnings", se.netEarnings, label)
                expect(seBlock, "seEarnings", se.seEarnings, label)
                expect(seBlock, "socialSecurityTax", se.socialSecurityTax, label)
                expect(seBlock, "medicareTax", se.medicareTax, label)
                expect(seBlock, "additionalMedicare", se.additionalMedicare, label)
                expect(seBlock, "totalSETax", se.totalSETax, label)
                XCTAssertEqual(se.paramYear, seBlock["paramYear"] as? Int, "\(label).paramYear")
                seCells += 7

                let et = USReportEngine.estimatedTax(ctx)
                let etBlock = try XCTUnwrap(g["estimatedTax"] as? [String: Any])
                XCTAssertEqual(Set(etBlock.keys),
                               Set(["annualIncomeTax", "annualSETax", "totalAnnual",
                                    "quarterlyPayment", "dueDates"]),
                               "\(label): every estimatedTax key must be visited")
                expect(etBlock, "annualIncomeTax", et.annualIncomeTax, label)
                expect(etBlock, "annualSETax", et.annualSETax, label)
                expect(etBlock, "totalAnnual", et.totalAnnual, label)
                expect(etBlock, "quarterlyPayment", et.quarterlyPayment, label)
                XCTAssertEqual(et.dueDates, etBlock["dueDates"] as? [String], "\(label).dueDates")
                estimateCells += 5

                let warnings = try XCTUnwrap(g["warnings"] as? [String])
                XCTAssertEqual(USReportEngine.warnings(ctx), warnings, "\(label).warnings")
            }
        }
        XCTAssertEqual(seCells, 70)
        XCTAssertEqual(estimateCells, 50)
    }

    /// `totalAnnual` is NOT rounded — the two cells that prove it, named.
    ///
    /// Split out of the sweep above so the failure message says WHAT broke rather
    /// than which of 120 cells. These two float tails are the sharpest discriminator
    /// in the batch: a mirror that adds a tidy `round2` produces `1542.66` and
    /// `14590.38`, both of which look right.
    func testTotalAnnualCarriesTheUnroundedFloatTail() throws {
        for (pid, expected) in [("2024", 1542.6599999999999), ("2026", 14590.380000000001)] {
            let url = try fixtureCopy("b5-tail-\(pid)")
            let db = try SQLiteDatabase(path: url.path)
            let p = try XCTUnwrap(Self.periods[pid])
            let ctx = try context(db, locale: "US", period: p)
            guard case .computed(let got) = USReportEngine.estimatedTax(ctx).totalAnnual else {
                return XCTFail("base-US-\(pid): totalAnnual must be computed")
            }
            XCTAssertEqual(got, expected, "base-US-\(pid)")
            XCTAssertNotEqual(got, ReportMath.round2(expected),
                              "…and it must NOT equal the tidied value \(ReportMath.round2(expected))")
            // The golden records the same tail, so this is not a Swift-side artefact.
            let g = try XCTUnwrap(try golden("base-US-\(pid)")["estimatedTax"] as? [String: Any])
            XCTAssertEqual(g["totalAnnual"] as? Double, expected)
        }
    }

    /// The US income-tax estimate is NOT clamped at 0, unlike the five VAT engines.
    func testTheUSEstimateIsNotClampedSoLossPeriodsGoNegative() throws {
        // Read off the committed goldens, not guessed: 2025-06 and 2025Q2 are the two
        // loss periods (line31 −2850 and −3600 at the fixture's 20% rate).
        for (pid, expected) in [("2025-06", -570.0), ("2025Q2", -720.0)] {
            let url = try fixtureCopy("b5-neg-\(pid)")
            let db = try SQLiteDatabase(path: url.path)
            let p = try XCTUnwrap(Self.periods[pid])
            let ctx = try context(db, locale: "US", period: p)
            guard case .computed(let got) = USReportEngine.estimatedTax(ctx).annualIncomeTax else {
                return XCTFail("base-US-\(pid): annualIncomeTax must be computed")
            }
            XCTAssertEqual(got, expected,
                           "base-US-\(pid): a loss period estimates a NEGATIVE income tax; "
                           + "copying jp.js's Math.max(0, …) clamp here would give 0")
        }
    }
}
