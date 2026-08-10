import XCTest
@testable import SoloLedgerCore

/// The four `settings` keys, over every stored shape the mirror has to agree about.
///
/// The suite's reason for existing is the SEPARATION OF THE TWO AXES. A single "is this
/// parameter OK" answer would have to choose between two true statements about a row
/// holding `true`: the engines subtracted **1**, and the row is not a setting anybody
/// chose. `PresentedParameter` says both, and these tests hold it to that.
///
/// The Electron column is not asserted from belief: `js-settings-coercion.json` is recorded
/// from the repo-locked Electron and regenerated + byte-compared in CI.
final class ReportParameterMatrixTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func ledger(_ storedAdmin: String?) throws -> SQLiteDatabase {
        let db = try SQLiteDatabase(path: dir.appendingPathComponent("\(UUID().uuidString).db").path)
        try db.execute("""
            CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at TEXT);
            CREATE TABLE transactions (
              id TEXT PRIMARY KEY, type TEXT, date TEXT, amount REAL, amount_net REAL,
              tax_amount REAL, category_id TEXT, currency TEXT NOT NULL DEFAULT 'CNY',
              payment_status TEXT, paid_amount REAL, payment_date TEXT);
            """)
        _ = try db.run("INSERT INTO settings VALUES ('accounting_locale','\"CN\"','')")
        _ = try db.run("INSERT INTO settings VALUES ('currency','\"CNY\"','')")
        // One in-period row: without it the period is a legacy stop and no report — and so
        // no parameter state — is produced at all.
        _ = try db.run("""
            INSERT INTO transactions (id, type, date, amount, amount_net, tax_amount,
                                      category_id, currency, payment_status, paid_amount,
                                      payment_date)
            VALUES ('t1','income','2025-06-01',100,100,0,NULL,'CNY','paid',100,NULL)
            """)
        if let storedAdmin {
            _ = try db.run("INSERT INTO settings VALUES ('admin_expense_annual',?,'')",
                           [.text(storedAdmin)])
        }
        return db
    }

    private func parameter(_ db: SQLiteDatabase, _ key: ReportParameterKey,
                           locale: String = "CN") throws -> PresentedParameter {
        guard case .report(let r) = try ReportBuilder.build(db, locale: locale,
                                                            period: ReportPeriod(year: "2025"))
        else { throw XCTSkip("blocked") }
        return try XCTUnwrap(r.parameters.first { $0.key == key })
    }

    // MARK: - The BOM boundary

    /// **The BOM boundary for a value.** `admin_expense_annual` holding a UTF-8 BOM followed
    /// by `5000` must read as needs-repair with the text kept verbatim, while the effect
    /// reports the 0 the engines actually subtracted.
    ///
    /// Measured on the same row today, and the reason this boundary matters:
    ///
    ///     SettingsStore.number("admin_expense_annual")            -> 5000
    ///     ReportSettings.number(db, …, fallback: 0)                -> 0
    ///
    /// The Settings screen showed 5000; the engines used 0. `SettingsStore.number` still reads
    /// 5000 — it is the lenient DISPLAY accessor and is deliberately unchanged — but P4d gave
    /// `SettingsStore` a strict accessor beside it (`reportParameterState`) that applies THIS
    /// rule, so the Settings screen no longer presents that number as a setting. The two
    /// readers are pinned equal by `ParameterReadAlignmentTests`. The façade's own job here is
    /// unchanged: report the 0 it really used, and never launder the row into a `.usable(5000)`.
    func testBOMPrefixedAdminExpenseIsNeedsRepairWithExactTextWhileNativeEffectIsTheFallbackZero()
        throws {
        let stored = "\u{FEFF}5000"
        let p = try parameter(try ledger(stored), .adminExpenseAnnual)

        XCTAssertEqual(p.stored, .needsRepair(storedText: stored),
                       "the stored text must survive byte for byte, BOM included")
        if case .needsRepair(let text) = p.stored {
            XCTAssertEqual(Array(text.unicodeScalars.map(\.value)),
                           [0xFEFF, 0x35, 0x30, 0x30, 0x30],
                           "storedText must be exactly U+FEFF then 5000")
        }
        XCTAssertEqual(p.nativeEffect, .appliedValue(0, origin: .dispatcherFallback),
                       "JSON.parse rejects the BOM, so readSetting's catch returned the fallback")
        XCTAssertNotEqual(p.stored, .usable(5000),
                          "the Settings screen reads 5000 here; the report must not repeat it")
    }

    // MARK: - The two axes disagree

    /// The headline: a finite, ordinary-looking result is NOT evidence of a sound row.
    func testAFiniteEffectDoesNotImplyAUsableStoredValue() throws {
        for (stored, applied) in [("true", 1.0), ("[5000]", 5000.0), ("null", 0.0),
                                  ("false", 0.0), ("[]", 0.0), ("\"\"", 0.0)] {
            let p = try parameter(try ledger(stored), .adminExpenseAnnual)
            XCTAssertEqual(p.stored, .needsRepair(storedText: stored),
                           "\(stored) is not a sound setting")
            XCTAssertEqual(p.nativeEffect, .appliedValue(applied, origin: .storedValue),
                           "\(stored) still reached the engines as \(applied)")
        }
    }

    func testSoundValuesAreUsableAndApplied() throws {
        for (stored, value) in [("0", 0.0), ("5000", 5000.0), ("-5000", -5000.0),
                                ("\"5000\"", 5000.0), ("\" 5000 \"", 5000.0),
                                ("\"0x1388\"", 5000.0), ("1e308", 1e308)] {
            let p = try parameter(try ledger(stored), .adminExpenseAnnual)
            XCTAssertEqual(p.stored, .usable(value), "\(stored)")
            XCTAssertEqual(p.nativeEffect, .appliedValue(value, origin: .storedValue), "\(stored)")
        }
    }

    func testAbsentRowIsARealZeroNotARefusal() throws {
        let p = try parameter(try ledger(nil), .adminExpenseAnnual)
        XCTAssertEqual(p.stored, .absent)
        XCTAssertEqual(p.nativeEffect, .appliedValue(0, origin: .dispatcherFallback),
                       "index.js:133 falls back to 0 regardless of regime — not a refusal")
        if case .refused = p.nativeEffect { XCTFail("the admin expense never refuses") }
    }

    func testUnparseableTextReachesTheEnginesAsTheDispatcherFallback() throws {
        for stored in ["5000元", "abc", "", "Infinity", "NaN", "1e999", "\u{FEFF}5000"] {
            let p = try parameter(try ledger(stored), .adminExpenseAnnual)
            XCTAssertEqual(p.stored, .needsRepair(storedText: stored), "\(stored.debugDescription)")
            XCTAssertEqual(p.nativeEffect, .appliedValue(0, origin: .dispatcherFallback),
                           "\(stored.debugDescription) — JSON.parse threw, catch returned 0")
        }
    }

    func testParsedButNonNumericValuesReachTheEnginesAsNonFinite() throws {
        for stored in ["{}", "{\"v\":5000}", "[1,2]", "\"5000元\""] {
            let p = try parameter(try ledger(stored), .adminExpenseAnnual)
            XCTAssertEqual(p.stored, .needsRepair(storedText: stored))
            XCTAssertEqual(p.nativeEffect, .appliedNonFinite, "\(stored) coerces to NaN")
        }
    }

    /// The non-finite admin expense is carried into China's report and flattened to a
    /// confident 0 by the other five. Mirrored, not normalised.
    func testNonFiniteAdminExpenseIsRegimeAsymmetricAtTheLineButNotAtTheParameter() throws {
        for locale in ["CN", "JP", "EU", "KR", "TW", "US"] {
            let db = try ledger("{}")
            guard case .report(let r) = try ReportBuilder.build(db, locale: locale,
                                                                period: ReportPeriod(year: "2025"))
            else { return XCTFail("\(locale) must build") }
            let p = try XCTUnwrap(r.parameters.first { $0.key == .adminExpenseAnnual })
            XCTAssertEqual(p.nativeEffect, .appliedNonFinite,
                           "\(locale): the parameter state is the same everywhere")

            let statement = r.sections.first { $0.reportTypeID != "vat-summary" }
            let adminLine = statement?.lines.first { $0.id == "adminExpense" }
            if locale == "CN" {
                XCTAssertEqual(adminLine?.value, .corrupted,
                               "China's round2 has no || 0 guard, so the NaN reaches the line")
            } else if let adminLine {
                XCTAssertEqual(adminLine.value, .amount(0),
                               "\(locale) uses round2OrZero and reports a confident 0")
            }
        }
    }

    // MARK: - Rates keep their own model

    func testChinaFallbackIsDisclosedAsARegimeDefaultRatherThanAUserChoice() throws {
        let p = try parameter(try ledger(nil), .incomeTaxRate, locale: "CN")
        XCTAssertEqual(p.stored, .absent)
        XCTAssertEqual(p.nativeEffect, .appliedValue(25, origin: .regimeDefault),
                       "the user never chose 25 — the report must be able to say so")
        XCTAssertEqual(p.consumption, .consumed)
    }

    func testNonChineseRegimeRefusesRatherThanInventingARate() throws {
        let p = try parameter(try ledger(nil), .incomeTaxRate, locale: "US")
        XCTAssertEqual(p.stored, .absent)
        XCTAssertEqual(p.nativeEffect, .refused(.incomeTaxRate))
    }

    func testARateNeverReachesTheNonFiniteEffect() throws {
        for stored in ["\"25%\"", "{}", "1e999", "true", "[25]"] {
            let db = try ledger(nil)
            _ = try db.run("INSERT INTO settings VALUES ('income_tax_rate',?,'')", [.text(stored)])
            let p = try parameter(db, .incomeTaxRate)
            XCTAssertEqual(p.stored, .needsRepair(storedText: stored))
            XCTAssertEqual(p.nativeEffect, .refused(.incomeTaxRate),
                           "FiniteRate makes a non-finite rate structurally impossible")
        }
    }

    /// `vat_rate` is loaded and read by nobody; the surcharge is read only by China. A view
    /// must be able to tell "unset and it matters" from "unset and nothing reads it".
    func testConsumptionDistinguishesParametersNoEngineReads() throws {
        let db = try ledger(nil)
        XCTAssertEqual(try parameter(db, .vatRate, locale: "CN").consumption, .storedButUnread)
        XCTAssertEqual(try parameter(db, .vatRate, locale: "US").consumption, .storedButUnread)
        XCTAssertEqual(try parameter(db, .surchargeRate, locale: "CN").consumption, .consumed)
        XCTAssertEqual(try parameter(db, .surchargeRate, locale: "JP").consumption,
                       .storedButUnread)
        XCTAssertEqual(try parameter(db, .incomeTaxRate, locale: "JP").consumption, .consumed)
    }

    /// The WHOLE consumption axis, all 6 regimes × 4 parameters, pinned as one table.
    ///
    /// The test above samples five of these twenty-four cells, which is how
    /// `admin_expense_annual` could claim `.consumed` under the US — where `us.js` does not
    /// name it — for as long as it did. A sample cannot say "and nothing else moved"; this
    /// table can, and that is the property a regime-conditional answer needs.
    ///
    /// Written out rather than computed from the same `locale == …` expressions the subject
    /// uses, because a table derived from the implementation would agree with it by
    /// construction. The independent derivation lives in the test below, from the engines'
    /// own source.
    func testTheFullSixByFourConsumptionMatrixIsPinned() throws {
        let keys: [ReportParameterKey] = [.vatRate, .surchargeRate, .incomeTaxRate,
                                          .adminExpenseAnnual]
        var actual: [String] = []
        for locale in ["CN", "EU", "JP", "KR", "TW", "US"] {
            let db = try ledger(nil)
            for key in keys {
                let mark = try parameter(db, key, locale: locale).consumption == .consumed
                    ? "consumed" : "storedButUnread"
                actual.append("\(locale) \(key.rawValue) \(mark)")
            }
        }
        XCTAssertEqual(actual, [
            "CN vat_rate storedButUnread",
            "CN surcharge_rate consumed",
            "CN income_tax_rate consumed",
            "CN admin_expense_annual consumed",
            "EU vat_rate storedButUnread",
            "EU surcharge_rate storedButUnread",
            "EU income_tax_rate consumed",
            "EU admin_expense_annual consumed",
            "JP vat_rate storedButUnread",
            "JP surcharge_rate storedButUnread",
            "JP income_tax_rate consumed",
            "JP admin_expense_annual consumed",
            "KR vat_rate storedButUnread",
            "KR surcharge_rate storedButUnread",
            "KR income_tax_rate consumed",
            "KR admin_expense_annual consumed",
            "TW vat_rate storedButUnread",
            "TW surcharge_rate storedButUnread",
            "TW income_tax_rate consumed",
            "TW admin_expense_annual consumed",
            "US vat_rate storedButUnread",
            "US surcharge_rate storedButUnread",
            "US income_tax_rate consumed",
            // The one cell this round moves. `us.js` — and `USReportEngine` — never name the
            // admin expense; Schedule C has no such line.
            "US admin_expense_annual storedButUnread",
        ], "the consumption matrix moved: 23 of these cells are other regimes and must not")
    }

    /// The consumption axis is a claim about what the ENGINES read, so derive it from their
    /// source instead of restating the presenter's own condition.
    ///
    /// This is the guard the defect it pins did not have: `.consumed` for
    /// `admin_expense_annual` was a sentence somebody wrote, and nothing ever compared it to
    /// `USReportEngine`, which does not mention `ctx.adminExpense` at all. A regime that stops
    /// reading a parameter — or starts — now fails here instead of shipping a report screen
    /// that tells the user the opposite.
    ///
    /// `Reports/Presentation` is deliberately NOT scanned: `ReportBuilder` names
    /// `ctx.incomeTaxRate` and `ctx.surchargeRate` while BUILDING this very answer, so
    /// including it would let the subject satisfy its own oracle. Comment lines are dropped
    /// for the same reason — a mirror note naming a field is not a read of it.
    func testConsumptionAgreesWithWhatTheEngineSourcesActuallyRead() throws {
        var dir = URL(fileURLWithPath: #filePath)
        dir.deleteLastPathComponent()                       // …/SoloLedgerCoreTests
        dir.deleteLastPathComponent()                       // …/Tests
        dir.deleteLastPathComponent()                       // …/SoloLedger
        let engines = dir.appendingPathComponent("Sources/SoloLedgerCore/Reports")

        // `vat_rate` has no `ReportContext` field at all, so no engine can read it — the
        // absent field is itself the mirror of Appendix A6.
        let field: [ReportParameterKey: String] = [
            .vatRate: "ctx.vatRate",
            .surchargeRate: "ctx.surchargeRate",
            .incomeTaxRate: "ctx.incomeTaxRate",
            .adminExpenseAnnual: "ctx.adminExpense",
        ]

        for locale in ["CN", "EU", "JP", "KR", "TW", "US"] {
            let file = engines.appendingPathComponent("\(locale)ReportEngine.swift")
            let text = try String(contentsOf: file, encoding: .utf8)
            let code = text.split(separator: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            // A rename that emptied the scan would make every regime look like a
            // non-consumer and pass silently.
            XCTAssertGreaterThan(code.count, 2000, "\(locale): the engine source did not resolve")

            let db = try ledger(nil)
            for (key, ctxField) in field {
                let reads = code.contains(ctxField)
                XCTAssertEqual(try parameter(db, key, locale: locale).consumption,
                               reads ? .consumed : .storedButUnread,
                               "\(locale) / \(key.rawValue): the engine "
                               + (reads ? "reads \(ctxField) but the parameter says nothing does"
                                        : "never names \(ctxField) but the parameter says it is read"))
            }
        }
    }

    /// `vat_rate` is an UNGATED `Number(readSetting(db,'vat_rate',13))` (`index.js:126`), so
    /// it never refuses — modelling it with the rates' four states would report a refusal
    /// Electron does not perform.
    func testVatRateNeverRefusesBecauseSchemeANeverGatesIt() throws {
        for locale in ["CN", "US", "JP", "EU", "KR", "TW"] {
            let p = try parameter(try ledger(nil), .vatRate, locale: locale)
            XCTAssertEqual(p.nativeEffect, .appliedValue(13, origin: .dispatcherFallback),
                           "\(locale): index.js:126's fallback is 13, ungated")
        }
    }

    func testAllFourKeysAreAlwaysPresent() throws {
        guard case .report(let r) = try ReportBuilder.build(try ledger(nil),
                                                            period: ReportPeriod(year: "2025"))
        else { return XCTFail("must build") }
        XCTAssertEqual(Set(r.parameters.map(\.key)), Set(ReportParameterKey.allCases))
        XCTAssertEqual(r.parameters.count, 4)
    }

    // MARK: - Against the Electron oracle

    /// Every `admin_expense_annual` shape in the corpus, checked against what ELECTRON
    /// recorded — and where the two runtimes disagree, the disagreement is asserted rather
    /// than hidden, so it cannot change unnoticed.
    ///
    /// Compared at the COERCION layer (`ReportSettings.number`), not at
    /// ``ParameterEffect``: the presentation deliberately collapses every non-finite value
    /// into one `.appliedNonFinite` case, because a view has one thing to say about damaged
    /// data. That collapse is correct for a UI and useless for an oracle, which is asking
    /// whether the two runtimes produced the SAME BITS.
    ///
    /// Three divergences are registered today, all from Foundation's JSON number parser:
    ///
    /// | case | Electron | native |
    /// | --- | --- | --- |
    /// | `1e999` | `Infinity` | throws ⇒ fallback 0 |
    /// | `1.12345678912345678e145` | finite | throws ⇒ fallback 0 |
    /// | `1.12345678912345678e144` | `5DD70848B44D7BBA` | `5DD70848B44D7BB6` — **both accept, 4 ULP apart** |
    ///
    /// The third is the dangerous one: no gate rejects it, both sides call the row usable,
    /// and the two apps subtract different numbers. It is registered here and in
    /// `ReportSettings.jsonFragment`'s documentation, and it is NOT repaired — changing the
    /// parser changes behaviour on a protected path and needs its own approved parity PR.
    func testNativeCoercionAgreesWithTheElectronOracleExceptWhereRegistered() throws {
        struct Corpus: Decodable {
            struct Applied: Decodable { let bits: String; let repr: String }
            struct Case: Decodable {
                let name: String; let storedText: String?
                let parseThrew: Bool; let applied: [String: Applied]
            }
            let runtime: String
            let cases: [Case]
        }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "reportmath", withExtension: nil)?
            .appendingPathComponent("js-settings-coercion.json"))
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
        XCTAssertEqual(corpus.runtime, "electron", "the oracle must be the locked Electron")
        XCTAssertGreaterThan(corpus.cases.count, 30)

        // Asserted as a SET so a NEW divergence fails rather than passing quietly, and so a
        // divergence that closes also fails — an entry that stops matching must be removed.
        let registered: Set<String> = [
            "positiveOverflow",             // Electron Infinity, native throws -> fallback 0
            "seventeenDigitsHighExponent",  // Electron finite,   native throws -> fallback 0
            "seventeenDigitsInRange",       // both accept, 4 ULP apart
        ]
        var diverged: Set<String> = []

        for c in corpus.cases {
            let electron = try XCTUnwrap(c.applied["admin_expense_annual"]).bits
            let db = try ledger(c.storedText)
            let native = Self.bits(ReportSettings.number(db, "admin_expense_annual", fallback: 0))
            if native != electron { diverged.insert(c.name) }
        }
        XCTAssertEqual(diverged, registered, """
            the set of native/Electron coercion divergences changed. New: \
            \(diverged.subtracting(registered).sorted()); gone: \
            \(registered.subtracting(diverged).sorted()). A new one is not a test to relax — \
            it is a parity question for a separately-approved PR.
            """)
    }

    /// The one case where both runtimes accept the value and produce DIFFERENT doubles,
    /// spelled out on its own because a set membership does not convey how quiet it is.
    func testTheFourULPDivergenceIsAcceptedByBothSidesAndStillDiffers() throws {
        let stored = "1.12345678912345678e144"
        let db = try ledger(stored)
        let p = try parameter(db, .adminExpenseAnnual)
        XCTAssertEqual(p.stored, .usable(1.123456789123456e+144),
                       "both parsers accept it — nothing flags this row as damaged")
        let native = Self.bits(ReportSettings.number(db, "admin_expense_annual", fallback: 0))
        XCTAssertEqual(native, "5DD70848B44D7BB6", "Foundation's parse")
        XCTAssertNotEqual(native, "5DD70848B44D7BBA",
                          "V8 parses the same text 4 ULP away; the two apps subtract "
                          + "different numbers and no state says so")
    }

    private static func bits(_ v: Double) -> String {
        if v.isNaN { return "7FF8000000000000" }
        return String(format: "%016llX", (v == 0 ? 0.0 : v).bitPattern)
    }
}
