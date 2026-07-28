import XCTest
@testable import SoloLedgerCore

/// The income-tax rate's states, and the rule that decides them (R6 + A4-2).
///
/// The rule (plan §6.2 / §9.1 scheme A) is one sentence: **"not configured" is
/// decided by the ABSENCE of the settings row, never by the computed value.** It
/// is a hard constraint because of a measurement, not a preference — a missing row
/// used to produce 1100 on the US fixture, China's 25% fallback quietly applied,
/// which is arithmetically indistinguishable from a user who really stored 25%.
///
/// So the central assertion here is a NEGATIVE one:
/// ``testMissingRowAndAStoredTwentyFiveAreDifferentStates`` shows that a ledger with
/// no row and a ledger storing exactly the fallback resolve to different values —
/// something no value-based implementation can achieve, since both would compute
/// 25. Every other test in this file is scaffolding around that one.
///
/// **The goldens are FROZEN here.** This suite reads them (to tie the Swift model to
/// the committed Electron truth) and changes none; no commit in R6 declares
/// `Allowed-Golden-Changes`.
final class ReportMissingRateTests: LedgerTestCase {

    // MARK: - Fixtures

    private func bundledFixtureURL() throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: "reports", withExtension: nil),
                      "report fixtures missing from the test bundle")
            .appendingPathComponent("reports-base.db")
    }

    /// A writable copy. NEVER open the bundled file read-write — `LedgerStore`
    /// migrates and switches journal mode on open, rewriting it in place.
    private func fixtureCopy(_ name: String) throws -> SQLiteDatabase {
        let dst = try trackedTempDir().appendingPathComponent("\(name).db")
        try FileManager.default.copyItem(at: try bundledFixtureURL(), to: dst)
        return try SQLiteDatabase(path: dst.path)
    }

    private func golden(_ name: String) throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "reports", withExtension: nil))
            .appendingPathComponent("goldens").appendingPathComponent("\(name).json")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url))
                             as? [String: Any], "\(name).json is not an object")
    }

    /// The SAME mutations `make-report-goldens.mjs:80-101` applies, so a variant here
    /// and a variant in the goldens cannot drift apart.
    private static let rateKeys = ["vat_rate", "surcharge_rate", "income_tax_rate",
                                   "admin_expense_annual"]

    private func applyVariant(_ variant: String, to db: SQLiteDatabase) throws {
        switch variant {
        case "base": break
        case "unset":
            let list = Self.rateKeys.map { "'\($0)'" }.joined(separator: ",")
            try db.execute("DELETE FROM settings WHERE key IN (\(list))")
        case "zero":
            for key in Self.rateKeys { try put(db, key, "0") }
        case "malformed":
            try put(db, "surcharge_rate", "\"12%\"")
            try put(db, "income_tax_rate", "\"25%\"")
        default: XCTFail("unknown variant \(variant)")
        }
    }

    private func put(_ db: SQLiteDatabase, _ key: String, _ rawJSON: String) throws {
        try db.execute("""
            INSERT INTO settings (key, value, updated_at)
            VALUES ('\(key)', '\(rawJSON)', datetime('now'))
            ON CONFLICT(key) DO UPDATE SET value='\(rawJSON)', updated_at=datetime('now')
            """)
    }

    private func variant(_ name: String) throws -> SQLiteDatabase {
        let db = try fixtureCopy("rate-\(name)")
        try applyVariant(name, to: db)
        return db
    }

    private let nonCN = ["US", "JP", "EU", "KR", "TW"]

    // MARK: - The constraint (A-3)

    /// **The test this file exists for.**
    ///
    /// Two ledgers: one with no `income_tax_rate` row, one storing exactly the
    /// fallback the engine would have applied. Before scheme A both produced the
    /// identical number, so no implementation reading the COMPUTED value could tell
    /// them apart. They must be different values here.
    func testMissingRowAndAStoredTwentyFiveAreDifferentStates() throws {
        let absent = try variant("unset")
        let stored = try variant("unset")
        try put(stored, "income_tax_rate", "25")

        for locale in nonCN {
            let a = ReportSettings.incomeTaxRate(absent, locale: locale)
            let s = ReportSettings.incomeTaxRate(stored, locale: locale)
            XCTAssertEqual(a, .notConfigured, "\(locale): a missing row is not configured")
            XCTAssertEqual(s, .configured(25), "\(locale): a stored 25 is a real answer")
            XCTAssertNotEqual(a, s,
                "\(locale): the two states must not collapse — they compute the same number, "
                + "which is exactly why the decision cannot be made from the number")
            XCTAssertNil(a.rate, "\(locale): nothing to price with")
            XCTAssertEqual(s.rate, 25)
        }

        // China resolves both, and STILL distinguishes them: the applied number is
        // the same 25, but "the app chose it" and "the user chose it" are different
        // facts and a view may need to say which.
        XCTAssertEqual(ReportSettings.incomeTaxRate(absent, locale: "CN"), .chinaFallback(25))
        XCTAssertEqual(ReportSettings.incomeTaxRate(stored, locale: "CN"), .configured(25))
        XCTAssertNotEqual(ReportSettings.incomeTaxRate(absent, locale: "CN"),
                          ReportSettings.incomeTaxRate(stored, locale: "CN"))
        XCTAssertEqual(ReportSettings.incomeTaxRate(absent, locale: "CN").rate, 25,
                       "A-2: China keeps its fallback and still prices")
    }

    /// An explicit 0% is a REAL rate, not an absence.
    ///
    /// The trap this guards is the falsy one: a `value ?? 0`-shaped implementation,
    /// or a `if rate == 0 { notConfigured }` shortcut, passes every other test in
    /// this file and fails this one.
    func testAnExplicitZeroIsARateAndNotAnAbsence() throws {
        let zero = try variant("zero")
        for locale in nonCN + ["CN"] {
            let s = ReportSettings.incomeTaxRate(zero, locale: locale)
            XCTAssertEqual(s, .configured(0), "\(locale): 0% is stored, so it is configured")
            XCTAssertEqual(s.rate, 0, "\(locale): and it prices at 0, which is a real answer")
            XCTAssertTrue(s.isConfigured, "\(locale): configured, despite the value being falsy")
            XCTAssertNotEqual(s, .notConfigured)
        }
    }

    // MARK: - The three states, from the real fixture

    func testTheFourFixtureVariantsResolveAsTheGoldensDo() throws {
        // base: the fixture stores 20 — deliberately NOT the engine's 25 fallback,
        // so a resolver that read the fallback would show a wrong number rather
        // than coincidentally matching.
        let base = try variant("base")
        for locale in nonCN + ["CN"] {
            XCTAssertEqual(ReportSettings.incomeTaxRate(base, locale: locale), .configured(20),
                           "\(locale): the fixture stores 20%")
        }

        let unset = try variant("unset")
        for locale in nonCN {
            XCTAssertEqual(ReportSettings.incomeTaxRate(unset, locale: locale), .notConfigured,
                           "\(locale): A-1 — row absent, non-Chinese regime")
        }
        XCTAssertEqual(ReportSettings.incomeTaxRate(unset, locale: "CN"), .chinaFallback(25),
                       "A-2 — China keeps the 25 fallback")
    }

    /// malformed is the FOURTH state (A-4): the row exists and its value is unusable.
    ///
    /// R6 modelled this as `.configured(.nan)`, which made the corrupt state a *kind
    /// of configured* — so every `guard let rate = setting.rate` in R7 would have
    /// sailed past it and multiplied by NaN. A4-2 makes it its own case, carrying the
    /// stored bytes so a repair flow can show the user what is actually there.
    ///
    /// It must not collapse into `.notConfigured` either: both refuse to compute, but
    /// one says "go configure a rate" and the other says "fix a broken value", and
    /// R8 puts a different door in front of each.
    func testMalformedIsItsOwnStateAndCarriesTheStoredBytes() throws {
        let bad = try variant("malformed")
        for locale in nonCN + ["CN"] {
            let s = ReportSettings.incomeTaxRate(bad, locale: locale)
            XCTAssertEqual(s, .needsRepair(rawValue: "\"25%\""),
                           "\(locale): the row EXISTS and its value is unusable")
            XCTAssertNotEqual(s, .notConfigured,
                              "\(locale): needs-repair and not-configured are two states")
            XCTAssertFalse(s.isConfigured, "\(locale): nothing may be priced with it")
            XCTAssertNil(s.rate, "\(locale): and there is no NaN to accidentally multiply by")
            XCTAssertEqual(s.needsRepairRawValue, "\"25%\"",
                           "\(locale): the RAW stored text, not the parsed string, not Number()")

            // The surcharge row is malformed in this variant too — and it is the one
            // that produces China's five nulls in `malformed-CN-2025.json`.
            XCTAssertEqual(ReportSettings.surchargeRate(bad, locale: locale),
                           .needsRepair(rawValue: "\"12%\""),
                           "\(locale): the surcharge row is malformed in this variant as well")
        }
    }

    /// A ledger with no `settings` table at all.
    ///
    /// `index.js`'s `settingRowExists` swallows the throw and answers false, so a
    /// non-Chinese regime is not-configured — which is also the honest reading: a
    /// ledger with no settings table has certainly not configured a tax rate.
    func testAnAbsentSettingsTableIsNotConfiguredOutsideChina() throws {
        let db = try fixtureCopy("no-settings")
        try db.execute("DROP TABLE settings")
        for locale in nonCN {
            XCTAssertEqual(ReportSettings.incomeTaxRate(db, locale: locale), .notConfigured,
                           "\(locale): cannot ask → not configured")
        }
        XCTAssertEqual(ReportSettings.incomeTaxRate(db, locale: "CN"), .chinaFallback(25),
                       "China never asks about the row, so it is unaffected")
    }

    /// The row-presence question is asked of the ROW, not of the value.
    func testRowExistsAnswersAboutTheRow() throws {
        let db = try variant("unset")
        XCTAssertFalse(ReportSettings.rowExists(db, "income_tax_rate"))
        try put(db, "income_tax_rate", "0")
        XCTAssertTrue(ReportSettings.rowExists(db, "income_tax_rate"),
                      "a row storing 0 exists; 0 is a value, not an absence")
        try put(db, "income_tax_rate", "\"25%\"")
        XCTAssertTrue(ReportSettings.rowExists(db, "income_tax_rate"),
                      "a row storing nonsense still exists")
        XCTAssertFalse(ReportSettings.rowExists(db, "no_such_key_at_all"))
    }

    // MARK: - Propagation: what actually reaches an engine

    /// The dispatcher's own context — the path production takes — carries the state.
    ///
    /// R7's estimate layer reads `ctx.incomeTaxRate`; if the dispatcher resolved it
    /// against the wrong regime or dropped it, every later parity test would be
    /// measuring a context that production never builds.
    func testTheDispatcherContextCarriesTheResolvedState() throws {
        let unset = try variant("unset")
        for locale in nonCN {
            let ctx = try ReportDispatcher.context(
                unset, locale: locale, source: .transactions,
                year: "2025", from: "2025-01-01", to: "2025-12-31")
            XCTAssertEqual(ctx.incomeTaxRate, .notConfigured, "\(locale): reaches the engine as absent")
            XCTAssertNil(ctx.incomeTaxRate.rate)
        }
        let cn = try ReportDispatcher.context(
            unset, locale: "CN", source: .transactions,
            year: "2025", from: "2025-01-01", to: "2025-12-31")
        XCTAssertEqual(cn.incomeTaxRate, .chinaFallback(25))

        let base = try variant("base")
        let us = try ReportDispatcher.context(
            base, locale: "US", source: .transactions,
            year: "2025", from: "2025-01-01", to: "2025-12-31")
        XCTAssertEqual(us.incomeTaxRate, .configured(20))
    }

    /// The gate reads the EFFECTIVE locale, not whatever `settings` happens to hold.
    ///
    /// The fixture is stamped CN. Asking for a US report on it must gate as US —
    /// otherwise a caller passing `opts.locale` would gate under one regime and
    /// compute under another, which is the #395-era bug in a new place.
    func testTheGateFollowsTheOverriddenLocaleNotTheStoredOne() throws {
        let unset = try variant("unset")
        XCTAssertEqual(ReportSettings.string(unset, "accounting_locale", fallback: "CN"), "CN",
                       "fixture assumption: the ledger is stamped CN")
        XCTAssertEqual(try ReportDispatcher.resolveLocale(unset, "US"), "US")
        let ctx = try ReportDispatcher.context(
            unset, locale: try ReportDispatcher.resolveLocale(unset, "US"),
            source: .transactions, year: "2025", from: "2025-01-01", to: "2025-12-31")
        XCTAssertEqual(ctx.incomeTaxRate, .notConfigured,
                       "gated as US — the stored CN must not rescue it")
    }

    /// `adminExpense` is NOT gated, and operating profit is therefore untouched.
    ///
    /// Pinned because it was a live question when scheme A was designed: the
    /// `unset` variant deletes `admin_expense_annual` too, and gating it would have
    /// turned the four non-Chinese operating profits null as a side effect. It falls
    /// back to 0 regardless of regime (`index.js:100`) and is not a tax rate.
    func testAdminExpenseIsNotGatedByTheMissingRate() throws {
        let unset = try variant("unset")
        let ctx = try ReportDispatcher.context(
            unset, locale: "JP", source: .transactions,
            year: "2025", from: "2025-01-01", to: "2025-12-31")
        XCTAssertEqual(ctx.incomeTaxRate, .notConfigured)
        XCTAssertEqual(ctx.adminExpense, 0, "a missing admin-expense row still means 0")

        // And the batch-1 block that consumes it is unchanged — 4196.23 is the
        // operating profit the committed `unset-JP-2025` golden carries.
        let jp = JPReportEngine.batchOne(ctx)
        let golden = try XCTUnwrap(try golden("unset-JP-2025")["incomeStatement"] as? [String: Any])
        XCTAssertEqual(jp.operatingProfit, try XCTUnwrap(golden["operatingProfit"] as? Double),
                       accuracy: 0.011)
        XCTAssertEqual(jp.adminExpense, try XCTUnwrap(golden["adminExpense"] as? Double),
                       accuracy: 0.011)
    }

    // MARK: - Tied to the committed Electron truth

    /// The Swift states agree with what the goldens actually record.
    ///
    /// Without this the model could be internally consistent and still describe a
    /// different engine than the one shipping. `incomeTax` is R7's field, so this
    /// asserts on the GOLDEN rather than on Swift output: null ⟺ `.notConfigured`,
    /// a number ⟺ configured.
    func testTheStatesAgreeWithWhatTheGoldensRecord() throws {
        for locale in ["JP", "EU", "KR", "TW"] {
            let key = locale == "EU" ? "profitLoss" : "incomeStatement"
            let unsetBlock = try XCTUnwrap(try golden("unset-\(locale)-2025")[key] as? [String: Any])
            let zeroBlock = try XCTUnwrap(try golden("zero-\(locale)-2025")[key] as? [String: Any])
            XCTAssertTrue(unsetBlock["incomeTax"] is NSNull,
                          "\(locale): the golden records null for a missing row")
            XCTAssertEqual(zeroBlock["incomeTax"] as? Double, 0,
                           "\(locale): the golden records a real 0 for an explicit 0%")

            let unsetDB = try variant("unset"), zeroDB = try variant("zero")
            XCTAssertEqual(ReportSettings.incomeTaxRate(unsetDB, locale: locale), .notConfigured)
            XCTAssertEqual(ReportSettings.incomeTaxRate(zeroDB, locale: locale), .configured(0))
        }

        // The US shape differs: no P&L block, the estimate lives in `estimatedTax`.
        let unsetUS = try XCTUnwrap(try golden("unset-US-2025")["estimatedTax"] as? [String: Any])
        XCTAssertTrue(unsetUS["annualIncomeTax"] is NSNull)
        XCTAssertEqual(ReportSettings.incomeTaxRate(try variant("unset"), locale: "US"),
                       .notConfigured)

        // China's golden is the control: it carries a NUMBER for the same missing
        // row, because A-2 keeps the fallback.
        let unsetCN = try XCTUnwrap(try golden("unset-CN-2025")["incomeStatement"] as? [String: Any])
        XCTAssertEqual(unsetCN["incomeTax"] as? Double, 1042.95,
                       "A-2: China still prices a missing row at 25%")
        XCTAssertEqual(ReportSettings.incomeTaxRate(try variant("unset"), locale: "CN"),
                       .chinaFallback(25))
    }

    // MARK: - The type itself

    func testTheRateAccessorRefusesBothNonComputingCases() {
        XCTAssertEqual(ReportRateSetting.configured(21).rate, 21)
        XCTAssertEqual(ReportRateSetting.chinaFallback(25).rate, 25)
        XCTAssertNil(ReportRateSetting.notConfigured.rate)
        XCTAssertNil(ReportRateSetting.needsRepair(rawValue: "\"25%\"").rate,
                     "a corrupt rate is not a rate — there is no NaN to hand back")
        XCTAssertTrue(ReportRateSetting.configured(0).isConfigured,
                      "0 is a rate; falsiness is a JavaScript problem, not a state")
        XCTAssertFalse(ReportRateSetting.notConfigured.isConfigured)
        XCTAssertFalse(ReportRateSetting.needsRepair(rawValue: "x").isConfigured)
        // Only needs-repair answers the raw-bytes question.
        XCTAssertEqual(ReportRateSetting.needsRepair(rawValue: "abc").needsRepairRawValue, "abc")
        XCTAssertNil(ReportRateSetting.notConfigured.needsRepairRawValue)
        XCTAssertNil(ReportRateSetting.configured(21).needsRepairRawValue)
        // `.configured(.nan)` does not compile: the payload is FiniteRate, whose only
        // NON-LITERAL initialiser is failable. That is the guarantee, in the type.
        //
        // A runtime value has to pass the check…
        let nan = Double.nan, plusInf = Double.infinity, ordinary = 21.0
        XCTAssertNil(FiniteRate(nan))
        XCTAssertNil(FiniteRate(plusInf))
        XCTAssertNil(FiniteRate(-plusInf))
        XCTAssertEqual(FiniteRate(ordinary)?.value, 21)
        // …while a LITERAL takes the non-failable path, which is why `.configured(21)`
        // reads normally at call sites. There is no non-finite literal to abuse it
        // with: `.nan` and `.infinity` are members of Double, not literals, and
        // FiniteRate has no such members.
        XCTAssertEqual(ReportRateSetting.configured(21).rate, 21)
        XCTAssertEqual(ReportRateSetting.configured(23.2).rate, 23.2)
    }

    /// The same number in two different states is two different values.
    func testEqualityDistinguishesTheOriginOfTheSameNumber() {
        XCTAssertNotEqual(ReportRateSetting.configured(25), .chinaFallback(25))
        XCTAssertEqual(ReportRateSetting.configured(25).rate,
                       ReportRateSetting.chinaFallback(25).rate,
                       "…while the number they price with is the same, which is the whole problem")
    }
}
