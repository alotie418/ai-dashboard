import XCTest
@testable import SoloLedgerCore

/// Batch-1 parity: every no-tax-rate income-statement field, for all five VAT
/// engines, against the committed goldens.
///
/// The goldens are the output of the REAL `electron/reports/index.js` run over
/// `reports-base.db`. This suite rebuilds the engine input by issuing the
/// dispatcher's own SQL against the same fixture, runs the Swift engine, and
/// compares field by field. **If the two disagree, the Swift side is wrong** — the
/// goldens are frozen for this whole phase and no commit here declares
/// `Allowed-Golden-Changes`.
///
/// ## Why the comparison is `==` and not a tolerance
///
/// Plan §4.2 allows `eps = 0.011` for the general case, anticipating that a Swift
/// implementation rounding once at the end would differ from an engine that rounds
/// at several points. This mirror does not round differently — it rounds where the
/// engine rounds, using `ReportMath` — so every batch-1 field lands bit-identical
/// and an exact comparison is available. It is also the STRICTER choice in the one
/// place that matters: China's `grossMargin` scales by 10000 once where the other
/// four scale by 100 twice, and the resulting divergence is always exactly 0.01 —
/// *inside* eps. A tolerance would hide precisely the bug this batch can have.
///
/// `==` and not `bitPattern` equality, though: `JSON.stringify` writes `-0` as `0`,
/// so a golden can never carry a negative zero, while `ReportMath.round`
/// deliberately preserves one. `==` is exactly the equivalence JSON serialization
/// imposes.
final class ReportBatch1ParityTests: LedgerTestCase {

    // MARK: - Fixture plumbing

    private func bundledFixtureURL() throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: "reports", withExtension: nil),
                      "report fixtures missing from the test bundle")
            .appendingPathComponent("reports-base.db")
    }

    /// A writable copy. NEVER open the bundled file read-write — `LedgerStore`
    /// would run the migrator and switch journal mode, rewriting the file whose
    /// sha256 `GOLDEN_ENV.json` pins.
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

    /// The four rate variants, applying the SAME mutations as
    /// `make-report-goldens.mjs:80-101`. Written out rather than imported so a
    /// drift between generator and test is a visible diff on both sides.
    private static let rateKeys = ["vat_rate", "surcharge_rate", "income_tax_rate",
                                   "admin_expense_annual"]

    private func applyVariant(_ variant: String, to db: SQLiteDatabase) throws {
        switch variant {
        case "base":
            break
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
            // Only these two, and NOT admin_expense_annual — which is why every
            // malformed golden still carries adminExpense 12000. The engines' NaN
            // path lives in batch 5; batch 1 sees this variant as a no-op, and
            // asserting that is the point.
            for (key, raw) in [("surcharge_rate", "\"12%\""), ("income_tax_rate", "\"25%\"")] {
                try db.execute("""
                    INSERT INTO settings (key, value, updated_at) VALUES ('\(key)', '\(raw)', datetime('now'))
                    ON CONFLICT(key) DO UPDATE SET value='\(raw)', updated_at=datetime('now')
                    """)
            }
        default:
            XCTFail("unknown variant \(variant)")
        }
    }

    // MARK: - The dispatcher's own reads, mirrored

    /// `index.js:16-21` + `:77` — `Number(readSetting(db, 'admin_expense_annual', 0))`.
    ///
    /// Deliberately NOT `SettingsStore.number`. That helper returns `nil` for a
    /// missing row AND for the unparseable string `"25%"`, collapsing the two
    /// states plan §6.2 spends its whole four-variant matrix keeping apart. The
    /// dispatcher's order is: read the row; if absent substitute the FALLBACK
    /// LITERAL (so `Number()` never sees the absence); otherwise `JSON.parse` then
    /// `Number()`.
    private func adminExpense(_ db: SQLiteDatabase) throws -> Double {
        let rows = try db.query("SELECT value FROM settings WHERE key = ?",
                                [.text("admin_expense_annual")])
        guard let raw = rows.first?.string("value") else { return 0 }   // the fallback literal
        guard let parsed = Self.parseJSONFragment(raw) else { return .nan } // JSON.parse threw
        return ReportMath.number(parsed)
    }

    /// `JSON.parse` of a settings value, as a `ReportMath.JSValue`. Test-local: no
    /// production code needs this bridge until the dispatcher is mirrored (R3).
    private static func parseJSONFragment(_ text: String) -> ReportMath.JSValue? {
        guard let data = text.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return nil }
        return jsValue(any)
    }

    private static func jsValue(_ any: Any) -> ReportMath.JSValue {
        if any is NSNull { return .null }
        if let n = any as? NSNumber {
            // NSNumber erases Bool into a number; CFBoolean identity is the only
            // way back, and `Number(true)` is 1 while `Number("true")` is NaN.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .boolean(n.boolValue) }
            return .number(n.doubleValue)
        }
        if let s = any as? String { return .string(s) }
        if let a = any as? [Any] { return .array(a.map(jsValue)) }
        return .object
    }

    /// `index.js:41-52` and `:60-64` — the dispatcher's row reads, verbatim.
    ///
    /// Period bounds are bound as TEXT because the SQL compares them as text; that
    /// is why a row stamped `2025-06-15T00:00:00` still falls inside the
    /// `2025-06-01`…`2025-06-30` window.
    private func loadContext(_ db: SQLiteDatabase, locale: String,
                             year: String, from: String, to: String) throws
        -> (ctx: ReportContext, source: ReportSource) {

        let hasTransactions = !(try db.query(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='transactions'")).isEmpty
        let periodTxnCount = hasTransactions
            ? (try db.query("SELECT COUNT(*) AS c FROM transactions WHERE date >= ? AND date <= ?",
                            [.text(from), .text(to)]).first?.int("c") ?? 0)
            : 0
        let source = selectReportSource(hasTransactionsTable: hasTransactions,
                                        periodTxnCount: periodTxnCount)

        let incomeRows: [ReportRow], expenseRows: [ReportRow]
        if source == .transactions {
            incomeRows = try db.query(
                "SELECT * FROM transactions WHERE type = 'income' AND date >= ? AND date <= ? ORDER BY date",
                [.text(from), .text(to)]).map(Self.transactionRow)
            expenseRows = try db.query(
                "SELECT * FROM transactions WHERE type = 'expense' AND date >= ? AND date <= ? ORDER BY date",
                [.text(from), .text(to)]).map(Self.transactionRow)
        } else {
            // The legacy aliased SELECTs, character for character from index.js:60-63.
            //
            // This is TEST-ONLY, and the distinction is load-bearing: plan §6.1
            // decided the native app never reads these tables (per #395), so no
            // production code here may call this. What it buys is that the five
            // legacy-sourced goldens become real assertions instead of a documented
            // gap — including the only non-zero `shippingFee` in the entire golden
            // set (base-CN-2024, 300). Without it, every asserted shippingFee is 0
            // and an engine that hardcoded 0 would pass the whole comparison.
            incomeRows = try db.query(
                "SELECT *, totalAmount as amount, amountWithoutTax as amount_net, taxAmount as tax_amount, taxRate as tax_rate, customer as counterparty FROM sales WHERE date >= ? AND date <= ? ORDER BY date",
                [.text(from), .text(to)]).map(Self.legacyRow)
            expenseRows = try db.query(
                "SELECT *, totalAmount as amount, amountWithoutTax as amount_net, taxAmount as tax_amount, taxRate as tax_rate, supplier as counterparty FROM purchases WHERE date >= ? AND date <= ? ORDER BY date",
                [.text(from), .text(to)]).map(Self.legacyRow)
        }

        // index.js:70 — note `WHERE locale = ?`. A row whose category belongs to a
        // different regime therefore matches nothing and falls to operating
        // expenses; mirrored, not repaired.
        let categories = try db.query(
            "SELECT * FROM categories WHERE locale = ? ORDER BY type, sort_order",
            [.text(locale)]).map {
                ReportCategory(id: $0.string("id") ?? "", isCogs: $0["is_cogs"])
            }

        let ctx = ReportContext(
            incomeRows: incomeRows, expenseRows: expenseRows, categories: categories,
            adminExpense: try adminExpense(db),
            incomeTaxRate: ReportSettings.incomeTaxRate(db, locale: locale),
            surchargeRate: ReportSettings.surchargeRate(db, locale: locale),
            currency: "CNY", year: year, from: from, to: to)
        return (ctx, source)
    }

    private static func transactionRow(_ r: SQLiteRow) -> ReportRow {
        ReportRow(amountNet: r.double("amount_net"), amount: r.double("amount"),
                  categoryID: r.string("category_id"),
                  // The transactions table has NO shippingCost column at all.
                  shippingCost: nil)
    }

    private static func legacyRow(_ r: SQLiteRow) -> ReportRow {
        ReportRow(amountNet: r.double("amount_net"), amount: r.double("amount"),
                  // The legacy SELECT never yields category_id — in JS that is
                  // `undefined`, and `row.category_id == null` is TRUE for it. This
                  // is the mechanism that makes COGS structurally 0 on every
                  // legacy period.
                  categoryID: nil,
                  // `sales` has shippingCost; `purchases` does not, so it reads nil
                  // there — which is fine, since only income rows are summed.
                  shippingCost: r.double("shippingCost"))
    }

    // MARK: - Comparison

    private func statement(_ g: [String: Any], _ locale: String) throws -> [String: Any] {
        // EU says profitLoss; everyone else says incomeStatement. Not tidied.
        try XCTUnwrap(g[locale == "EU" ? "profitLoss" : "incomeStatement"] as? [String: Any],
                      "\(locale): missing statement block")
    }

    private func expect(_ block: [String: Any], _ key: String, _ actual: Double,
                        _ label: String, _ checked: inout Int) throws {
        let want = try XCTUnwrap(block[key] as? Double, "\(label): golden has no \(key)")
        XCTAssertEqual(actual, want, "\(label).\(key) — golden \(want), Swift \(actual)")
        checked += 1
    }

    /// The one test that matters. Every batch-1 field, every locale, every period
    /// and variant the generator produced.
    func testBatchOneMatchesEveryGoldenFieldForFiveEngines() throws {
        let variantPeriods: [String: [String]] = [
            "base": ["2024", "2025", "2026", "2025Q2", "2025-06", "2024H2-2025H1"],
            "unset": ["2025"], "zero": ["2025"], "malformed": ["2025"],
        ]
        let periods: [String: (year: String, from: String, to: String)] = [
            "2024": ("2024", "2024-01-01", "2024-12-31"),
            "2025": ("2025", "2025-01-01", "2025-12-31"),
            "2026": ("2026", "2026-01-01", "2026-12-31"),
            "2025Q2": ("2025", "2025-04-01", "2025-06-30"),
            "2025-06": ("2025", "2025-06-01", "2025-06-30"),
            "2024H2-2025H1": ("2025", "2024-07-01", "2025-06-30"),
        ]
        var checked = 0
        var legacyPeriodsSeen = 0

        for (variant, periodIDs) in variantPeriods.sorted(by: { $0.key < $1.key }) {
            let url = try fixtureCopy(variant)
            let db = try SQLiteDatabase(path: url.path, mode: .readWriteExisting)
            try applyVariant(variant, to: db)

            for locale in ["CN", "JP", "EU", "KR", "TW"] {
                for periodID in periodIDs {
                    let p = try XCTUnwrap(periods[periodID])
                    let label = "\(variant)-\(locale)-\(periodID)"
                    let g = try golden(label)
                    let block = try statement(g, locale)
                    let (ctx, source) = try loadContext(db, locale: locale,
                                                        year: p.year, from: p.from, to: p.to)
                    if source == .legacy { legacyPeriodsSeen += 1 }

                    switch locale {
                    case "CN":
                        let s = CNReportEngine.batchOne(ctx)
                        try expect(block, "salesRevenue", s.salesRevenue, label, &checked)
                        try expect(block, "costOfSales", s.costOfSales, label, &checked)
                        try expect(block, "costOfGoodsSold", s.costOfGoodsSold, label, &checked)
                        try expect(block, "operatingExpenses", s.operatingExpenses, label, &checked)
                        try expect(block, "grossProfit", s.grossProfit, label, &checked)
                        try expect(block, "grossMargin", s.grossMargin, label, &checked)
                        try expect(block, "shippingFee", s.shippingFee, label, &checked)
                        try expect(block, "adminExpense", s.adminExpense, label, &checked)
                    case "EU":
                        let s = EUReportEngine.batchOne(ctx)
                        try expect(block, "revenue", s.revenue, label, &checked)
                        try expect(block, "costOfSales", s.costOfSales, label, &checked)
                        try expect(block, "costOfGoodsSold", s.costOfGoodsSold, label, &checked)
                        try expect(block, "operatingExpenses", s.operatingExpenses, label, &checked)
                        try expect(block, "grossProfit", s.grossProfit, label, &checked)
                        try expect(block, "grossMargin", s.grossMargin, label, &checked)
                        try expect(block, "adminExpense", s.adminExpense, label, &checked)
                        try expect(block, "operatingProfit", s.operatingProfit, label, &checked)
                    default:
                        let s = locale == "JP" ? JPReportEngine.batchOne(ctx)
                              : locale == "KR" ? KRReportEngine.batchOne(ctx)
                                               : TWReportEngine.batchOne(ctx)
                        try expect(block, "salesRevenue", s.salesRevenue, label, &checked)
                        try expect(block, "costOfSales", s.costOfSales, label, &checked)
                        try expect(block, "costOfGoodsSold", s.costOfGoodsSold, label, &checked)
                        try expect(block, "operatingExpenses", s.operatingExpenses, label, &checked)
                        try expect(block, "grossProfit", s.grossProfit, label, &checked)
                        try expect(block, "grossMargin", s.grossMargin, label, &checked)
                        try expect(block, "adminExpense", s.adminExpense, label, &checked)
                        try expect(block, "operatingProfit", s.operatingProfit, label, &checked)
                    }
                }
            }
        }

        // 45 goldens: 5 locales x (6 base periods + 3 variants). CN contributes 8
        // fields per golden and so do the other four, so the total is fixed —
        // asserted so a silently-skipped locale or period cannot pass as success.
        XCTAssertEqual(checked, 360, "expected 8 fields x 45 non-US goldens")
        XCTAssertEqual(legacyPeriodsSeen, 5, "the five 2024 goldens must take the legacy path")
    }

    /// `selectReportSource`'s whole truth table. It has no production caller yet —
    /// the dispatcher is a later batch — so without this it would ship unexercised
    /// except incidentally.
    ///
    /// The bug it encodes is worth restating: the choice is made PER PERIOD. A
    /// global `SELECT COUNT(*) FROM transactions` meant one transaction in any year
    /// forced EVERY year onto the transactions model, so a year holding only legacy
    /// rows reported 0 instead of falling back.
    func testSourceSelectionIsPerPeriod() {
        XCTAssertEqual(selectReportSource(hasTransactionsTable: true, periodTxnCount: 1), .transactions)
        XCTAssertEqual(selectReportSource(hasTransactionsTable: true, periodTxnCount: 999), .transactions)
        // No transactions IN THIS PERIOD → legacy, however many exist elsewhere.
        XCTAssertEqual(selectReportSource(hasTransactionsTable: true, periodTxnCount: 0), .legacy)
        // No table at all → legacy, whatever the count says.
        XCTAssertEqual(selectReportSource(hasTransactionsTable: false, periodTxnCount: 0), .legacy)
        XCTAssertEqual(selectReportSource(hasTransactionsTable: false, periodTxnCount: 5), .legacy)
    }

    /// The legacy periods are not merely covered — they are the ONLY place two
    /// batch-1 behaviours are observable at all, so this states what would silently
    /// stop being tested if they were dropped.
    func testTheLegacyPeriodIsTheOnlyPlaceTwoQuirksAreVisible() throws {
        let url = try fixtureCopy("legacy-probe")
        let db = try SQLiteDatabase(path: url.path, mode: .readWriteExisting)
        let (ctx, source) = try loadContext(db, locale: "CN", year: "2024",
                                            from: "2024-01-01", to: "2024-12-31")
        XCTAssertEqual(source, .legacy)
        let s = CNReportEngine.batchOne(ctx)

        // 1. shippingCost exists ONLY on the legacy `sales` table, so this is the
        //    one and only non-zero shippingFee in the whole golden set. On the
        //    transactions path cn.js:24 is structurally 0 (Appendix A4).
        XCTAssertEqual(s.shippingFee, 300)
        // 2. The legacy SELECT never yields category_id, so nothing can be COGS.
        XCTAssertEqual(s.costOfSales, 0)
        XCTAssertEqual(s.costOfGoodsSold, 0)
        //    …so gross profit collapses to revenue, and every expense lands in
        //    operating expenses. That is the SHAPE of a legacy period: an income
        //    statement with no cost of sales at all.
        XCTAssertEqual(s.grossProfit, s.salesRevenue)
        XCTAssertGreaterThan(s.operatingExpenses, 0, "the 2024 purchases are all operating")

        // The transactions path, for contrast: shipping gone, COGS real.
        let (ctx2025, source2025) = try loadContext(db, locale: "CN", year: "2025",
                                                    from: "2025-01-01", to: "2025-12-31")
        XCTAssertEqual(source2025, .transactions)
        let s2025 = CNReportEngine.batchOne(ctx2025)
        XCTAssertEqual(s2025.shippingFee, 0, "the transactions table has no shippingCost column")
        XCTAssertNotEqual(s2025.costOfSales, 0, "the transactions period does split COGS")
    }
}
