import XCTest
@testable import SoloLedgerCore

/// Batch-4 parity: the five turnover-tax blocks and `reportTypes`, against every
/// golden that carries them.
///
/// ## READ THIS BEFORE TRUSTING THE GREEN TICK
///
/// **The turnover half of this suite is weakly discriminating and the numbers say
/// so.** 153 fields are asserted across 45 goldens, but:
///
/// * the fixture produces only FOUR distinct turnover vectors in total, and the
///   whole `2026` column is zeros;
/// * China's five fields are only TWO distinct numbers, because `cn.js:70` and
///   `:72` are the same expression (and `:71`/`:73` likewise) — so transposing
///   `certifiedInput` with `cumulativeInput` in the Swift mirror is **undetectable
///   here, and undetectable by any input whatsoever**. That is not a gap to close;
///   it is the defect being mirrored, and
///   `ReportBatch4BlindSpotTests.testChinasDuplicatePairCannotBeSeparatedByAnyInput`
///   pins it as such;
/// * every rate variant produces the identical block, so `unset` / `zero` /
///   `malformed` add no discrimination to this batch at all — which is itself the
///   claim `testTurnoverTaxIsUnaffectedByEveryRateVariant` turns into a check.
///
/// What IS strongly pinned: input-versus-output cannot be swapped (362.27 against
/// 566.04), the clamp is exercised in two periods where input tax exceeds output
/// tax, and the legacy-sourced 2024 period carries non-zero tax from a different
/// table.
///
/// **The `reportTypes` half is the strong one.** Every golden embeds the engine's
/// name map as JSON, so all six Swift tables are verified string-by-string against
/// committed data — 54 arrays, 118 name entries. A mistyped character fails.
///
/// The goldens are FROZEN — no commit here declares `Allowed-Golden-Changes`.
final class ReportBatch4ParityTests: LedgerTestCase {

    // MARK: - Fixture plumbing (mirrors ReportBatch3ParityTests)

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
    private static let vatLocales = ["CN", "JP", "EU", "KR", "TW"]

    /// TEST-ONLY legacy reads — the FOURTH copy, and still deliberately not
    /// extracted (batches 1–3 each carry one with the same note). This one differs
    /// from the others in a way that matters: it selects `taxAmount as tax_amount`,
    /// because batch 4 is the first batch to read that column, and the
    /// legacy-sourced 2024 period carries real tax there (1534 collected / 1014
    /// paid). Consolidating the four would edit three shipped test files inside a
    /// mirror PR; it is a clean standalone follow-up.
    /// `ReportBatch2ParityTests.testNoProductionSymbolReadsTheLegacyTables` fences
    /// all four.
    private func legacyRows(_ db: SQLiteDatabase, table: String,
                            from: String, to: String) throws -> [ReportRow] {
        let alias = table == "sales" ? "customer as counterparty" : "supplier as counterparty"
        return try db.query(
            "SELECT *, totalAmount as amount, amountWithoutTax as amount_net, " +
            "taxAmount as tax_amount, taxRate as tax_rate, \(alias) " +
            "FROM \(table) WHERE date >= ? AND date <= ? ORDER BY date",
            [.text(from), .text(to)]).map {
                ReportRow(amountNet: $0.double("amount_net"), amount: $0.double("amount"),
                          taxAmount: $0.double("tax_amount"), categoryID: nil,
                          shippingCost: $0.double("shippingCost"), date: $0.string("date"))
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

    // MARK: - The turnover-tax block

    /// The golden's key name for the block, per locale. Five engines, four
    /// different names, and `vatSummary` means two different shapes.
    private static let blockKey = ["CN": "vatSummary", "JP": "consumptionTax",
                                   "EU": "vatReturn", "KR": "vatSummary",
                                   "TW": "businessTax"]

    /// The contract fields, keyed exactly as the golden keys them — which for
    /// batch 4 is every field the block has.
    private func contractFields(_ locale: String, _ ctx: ReportContext) -> [(String, Double)] {
        switch locale {
        case "CN":
            let b = CNReportEngine.vatSummary(ctx)
            return [("cumulativeInput", b.cumulativeInput), ("cumulativeOutput", b.cumulativeOutput),
                    ("certifiedInput", b.certifiedInput), ("invoicedOutput", b.invoicedOutput),
                    ("estimatedPayable", b.estimatedPayable)]
        case "JP":
            let b = JPReportEngine.consumptionTax(ctx)
            return [("collected", b.collected), ("paid", b.paid), ("payable", b.payable)]
        case "EU":
            let b = EUReportEngine.vatReturn(ctx)
            return [("outputVAT", b.outputVAT), ("inputVAT", b.inputVAT),
                    ("vatPayable", b.vatPayable)]
        case "KR":
            let b = KRReportEngine.vatSummary(ctx)
            return [("outputVAT", b.outputVAT), ("inputVAT", b.inputVAT),
                    ("vatPayable", b.vatPayable)]
        default:
            let b = TWReportEngine.businessTax(ctx)
            return [("collected", b.collected), ("paid", b.paid), ("payable", b.payable)]
        }
    }

    func testTurnoverTaxMatchesEveryGoldenField() throws {
        var checked = 0, legacyPeriodsSeen = 0
        var vectors = Set<String>()

        for locale in Self.vatLocales {
            for (variant, periodIDs) in Self.variantPeriods {
                let url = try fixtureCopy("b4-\(locale)-\(variant)")
                let db = try SQLiteDatabase(path: url.path, mode: .readWriteExisting)
                try applyVariant(variant, to: db)

                for periodID in periodIDs {
                    let p = try XCTUnwrap(Self.periods[periodID])
                    let label = "\(variant)-\(locale)-\(periodID)"
                    let key = try XCTUnwrap(Self.blockKey[locale])
                    let block = try XCTUnwrap(try golden(label)[key] as? [String: Any], label)
                    if try ReportFetch.periodTransactionCount(db, from: p.from, to: p.to) == 0 {
                        legacyPeriodsSeen += 1
                    }
                    let mine = contractFields(locale, try context(db, locale: locale, period: p))

                    XCTAssertEqual(block.count, mine.count,
                                   "\(label): golden \(key) key count — an extra key here would "
                                   + "mean the mirror is emitting something the engine does not")
                    for (field, value) in mine {
                        let want = try XCTUnwrap(block[field] as? Double,
                                                 "\(label): golden has no \(field)")
                        XCTAssertEqual(value, want, "\(label).\(field) — golden \(want), Swift \(value)")
                        checked += 1
                    }
                    vectors.insert("\(locale):" + mine.map { "\($0.1)" }.joined(separator: ","))
                }
            }
        }

        // CN 9 goldens x 5 fields + (JP+EU+KR+TW) 36 goldens x 3 fields.
        XCTAssertEqual(checked, 153, "45 non-US goldens")
        // The discrimination facts, asserted rather than described. If the fixture
        // gains rows these move and the header above stops being true.
        XCTAssertEqual(vectors.count, 20, "only 4 distinct vectors per locale x 5 locales")
        XCTAssertEqual(legacyPeriodsSeen, 5, "2024 is the one legacy-sourced period, x 5 locales")
    }

    /// Plan §2's claim that this batch reads no rate, turned into a machine check
    /// using goldens already on disk: the block is IDENTICAL across all four rate
    /// variants, while the income-statement block moves.
    func testTurnoverTaxIsUnaffectedByEveryRateVariant() throws {
        for locale in Self.vatLocales {
            let key = try XCTUnwrap(Self.blockKey[locale])
            let plKey = locale == "EU" ? "profitLoss" : "incomeStatement"
            var blocks: [String: NSDictionary] = [:]
            var incomeTaxes: [String: Double] = [:]
            for variant in ["base", "unset", "zero", "malformed"] {
                let g = try golden("\(variant)-\(locale)-2025")
                blocks[variant] = NSDictionary(dictionary: try XCTUnwrap(g[key] as? [String: Any]))
                incomeTaxes[variant] = ((g[plKey] as? [String: Any])?["incomeTax"] as? Double) ?? -1
            }
            for variant in ["unset", "zero", "malformed"] {
                XCTAssertEqual(blocks["base"], blocks[variant],
                               "\(locale) \(key) must not move with the rate — \(variant)")
            }
            // …while the estimate line, which IS rate-driven, does move. (`malformed`
            // is China's null path, which decodes to nil and lands on the -1 sentinel.)
            XCTAssertNotEqual(incomeTaxes["base"], incomeTaxes["unset"],
                              "\(locale): the control is vacuous if the rate changes nothing")
        }
    }

    // MARK: - reportTypes

    /// Every golden embeds the engine's `reportTypes` verbatim, so this compares
    /// all six Swift tables against committed JSON — ids, language keys and the
    /// strings themselves.
    ///
    /// This is where a transcription slip in ``ReportTypes`` dies: the JP entries
    /// whose `zh-CN` value is Japanese, the EU entry carrying 申报, and the US
    /// fullwidth parentheses are all byte-compared here.
    func testReportTypesMatchEveryGolden() throws {
        var arrays = 0, entries = 0, nameStrings = 0
        for locale in ["CN", "US", "JP", "EU", "KR", "TW"] {
            let table = try XCTUnwrap(ReportTypes.table(for: locale))
            for (variant, periodIDs) in Self.variantPeriods {
                for periodID in periodIDs {
                    let label = "\(variant)-\(locale)-\(periodID)"
                    let raw = try XCTUnwrap(try golden(label)["reportTypes"] as? [[String: Any]],
                                            "\(label): reportTypes missing")
                    XCTAssertEqual(raw.count, table.count, "\(label): entry count")
                    for (index, entry) in table.enumerated() {
                        let want = raw[index]
                        XCTAssertEqual(want["id"] as? String, entry.id, "\(label)[\(index)].id")
                        let wantName = try XCTUnwrap(want["name"] as? [String: String],
                                                     "\(label)[\(index)].name")
                        XCTAssertEqual(wantName, entry.name,
                                       "\(label)[\(index)].name — the map must match byte for byte, "
                                       + "including which languages are MISSING")
                        nameStrings += wantName.count
                        entries += 1
                    }
                    arrays += 1
                }
            }
        }
        XCTAssertEqual(arrays, 54, "6 locales x 9 goldens")
        XCTAssertEqual(entries, 117, "CN has 3 entries, the other five have 2 — x 9 goldens")
        // 306, not 6 x 54: CN and US carry two languages per entry, JP/EU/KR/TW three.
        XCTAssertEqual(nameStrings, 306, "every name string in every golden")
    }

    // MARK: - availability

    /// The field names the native mirror actually produces for a report type,
    /// taken by REFLECTION off the real struct rather than retyped here — so this
    /// cannot drift from the code it describes.
    ///
    /// `nil` means no Swift type exists for that report type yet.
    private func mirroredFieldNames(locale: String, reportTypeID: String) -> Set<String>? {
        let ctx = ReportContext(incomeRows: [], expenseRows: [], categories: [],
                                adminExpense: 0, incomeTaxRate: .notConfigured,
                                surchargeRate: .notConfigured,
                                currency: "CNY", year: "2026",
                                from: "2026-01-01", to: "2026-12-31")
        let block: Any?
        switch (locale, reportTypeID) {
        case ("CN", "income-statement"): block = CNReportEngine.batchOne(ctx)
        case ("JP", "income-statement"): block = JPReportEngine.batchOne(ctx)
        case ("KR", "income-statement"): block = KRReportEngine.batchOne(ctx)
        case ("TW", "income-statement"): block = TWReportEngine.batchOne(ctx)
        case ("EU", "profit-loss"):      block = EUReportEngine.batchOne(ctx)
        case ("CN", "vat-summary"):      block = CNReportEngine.vatSummary(ctx)
        case ("JP", "consumption-tax"):  block = JPReportEngine.consumptionTax(ctx)
        case ("EU", "vat-return"):       block = EUReportEngine.vatReturn(ctx)
        case ("KR", "vat-summary"):      block = KRReportEngine.vatSummary(ctx)
        case ("TW", "business-tax"):     block = TWReportEngine.businessTax(ctx)
        case ("CN", "tax-inclusive"):    block = CNReportEngine.taxInclusiveSummary(ctx)
        case ("US", "schedule-c"):       block = USReportEngine.scheduleC(ctx)
        case ("US", "se-tax"):           block = USReportEngine.selfEmploymentTax(ctx)
        default:                         block = nil
        }
        guard let block else { return nil }
        return Set(Mirror(reflecting: block).children.compactMap(\.label))
    }

    /// Fields the mirror carries that the ENGINE does not emit — disclosures and
    /// intermediates. Removed before the comparison, and separately asserted to be
    /// absent from every golden so this list cannot be used to hide a real
    /// mismatch.
    ///
    /// Batch 4 contributes NOTHING to this list — its five blocks carry contract
    /// fields only. It briefly carried a sixth, `unclampedDifference`; that was an
    /// overreach for a mirror PR and was removed, so the entries below are batch
    /// 3's alone.
    private static let nonContractFields: Set<String> = [
        "unroundedGrossIncome", "unroundedTotalExpenses", "rawMealsTotal",  // batch 3
    ]

    /// Derives ``ReportTypeAvailability`` from the goldens and the real structs,
    /// then asserts the hand-written table says the same thing.
    ///
    /// The point is that the enum stops being a comment. When R7 mirrors the
    /// estimate layer, every `.truncated` row becomes derivable as `.mirrored` and
    /// this test fails until the table is updated.
    ///
    /// **That force did not extend to `.absent`.** `mirroredFieldNames` returned
    /// `nil` for `("US", "se-tax")` while no Swift type existed, and would have kept
    /// returning `nil` after one did — a switch cannot notice a type it was never
    /// told about. R7 extended it by hand; this test could not have caught the
    /// omission, which is why the note stays rather than being deleted as done.
    func testAvailabilityMatchesWhatTheGoldensShowIsMirrored() throws {
        let goldenBlockKey: [String: String] = [
            "income-statement": "incomeStatement", "profit-loss": "profitLoss",
            "vat-summary": "vatSummary", "consumption-tax": "consumptionTax",
            "vat-return": "vatReturn", "business-tax": "businessTax",
            "tax-inclusive": "taxInclusiveSummary", "schedule-c": "scheduleC",
            "se-tax": "selfEmploymentTax",
        ]
        var seen: [ReportTypeAvailability: Int] = [:]

        for locale in ["CN", "US", "JP", "EU", "KR", "TW"] {
            let g = try golden("base-\(locale)-2025")
            for entry in try XCTUnwrap(ReportTypes.table(for: locale)) {
                let blockKey = try XCTUnwrap(goldenBlockKey[entry.id], entry.id)
                let goldenKeys = Set(try XCTUnwrap(g[blockKey] as? [String: Any],
                                                   "\(locale) golden has no \(blockKey)").keys)
                let produced = (mirroredFieldNames(locale: locale, reportTypeID: entry.id) ?? [])
                    .subtracting(Self.nonContractFields)

                let derived: ReportTypeAvailability
                if produced.isEmpty {
                    derived = .absent
                } else if produced == goldenKeys {
                    derived = .mirrored
                } else {
                    XCTAssertTrue(produced.isSubset(of: goldenKeys),
                                  "\(locale)/\(entry.id): the mirror emits fields the engine does "
                                  + "not — \(produced.subtracting(goldenKeys).sorted())")
                    derived = .truncated
                }

                XCTAssertEqual(ReportTypes.availability(for: entry.id, locale: locale), derived,
                               "\(locale)/\(entry.id): the hand-written availability disagrees with "
                               + "what the code actually produces (golden has \(goldenKeys.count) "
                               + "fields, the mirror produces \(produced.count))")
                seen[derived, default: 0] += 1
            }
        }

        // Every report type the six engines declare: 5 turnover blocks +
        // CN tax-inclusive + US schedule-c + 5 income statements + US se-tax.
        XCTAssertEqual(seen[.mirrored], 13)
        // R7 emptied both of these. `XCTAssertNil` rather than `== 0`: the counter is
        // a dictionary, so an absent key is the shape a zero takes here, and asserting
        // 0 would silently pass on a key that was never inserted for another reason.
        XCTAssertNil(seen[.truncated],
                     "the estimate layer landed; no declared report type is partial")
        XCTAssertNil(seen[.absent],
                     "…and none is missing entirely — se-tax was the last one")
    }

    /// The non-contract fields really are non-contract: no golden, anywhere, has a
    /// key by any of those names. Without this, the subtraction above could be
    /// used to make a genuine mismatch disappear.
    func testNoGoldenCarriesANonContractFieldName() throws {
        var scanned = 0
        for locale in ["CN", "US", "JP", "EU", "KR", "TW"] {
            for (variant, periodIDs) in Self.variantPeriods {
                for periodID in periodIDs {
                    let g = try golden("\(variant)-\(locale)-\(periodID)")
                    for (_, value) in g {
                        guard let block = value as? [String: Any] else { continue }
                        for key in block.keys {
                            XCTAssertFalse(Self.nonContractFields.contains(key),
                                           "\(variant)-\(locale)-\(periodID) carries \(key), which "
                                           + "the parity comparison excludes as non-contract")
                            scanned += 1
                        }
                    }
                }
            }
        }
        XCTAssertEqual(scanned, 1728, "every object-valued key of every golden block")
    }

    /// An accounting locale no engine serves has no report types at all, rather
    /// than an empty list a picker would happily render.
    func testUnknownLocaleHasNoTable() {
        XCTAssertNil(ReportTypes.table(for: "FR"))
        XCTAssertNil(ReportTypes.table(for: ""))
        XCTAssertEqual(ReportTypes.availability(for: "vat-summary", locale: "FR"), .absent)
        // A real id under the wrong regime is also absent — Korea has no
        // `tax-inclusive` report type even though `kr.js` emits the block.
        XCTAssertEqual(ReportTypes.availability(for: "tax-inclusive", locale: "KR"), .absent)
    }
}
