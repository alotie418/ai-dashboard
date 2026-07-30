// NOTE THE IMPORT. This file is the only one in the suite WITHOUT `@testable`, and that is
// its entire purpose: it consumes the report façade exactly as the SwiftUI target will.
//
// If any type, member or initialiser the App needs were left internal, this file would fail
// to COMPILE — which is a stronger and earlier signal than a failing assertion. Conversely,
// everything it does not need is free to stay internal, and the closed-set guard
// (`scripts/check-reports-public-surface.mjs`) fails if something new becomes public.
import XCTest
import SoloLedgerCore

final class ReportBuilderPublicAPITests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func ledger() throws -> SQLiteDatabase {
        let db = try SQLiteDatabase(path: dir.appendingPathComponent("l.db").path)
        try db.execute("""
            CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at TEXT);
            CREATE TABLE transactions (
              id TEXT PRIMARY KEY, type TEXT, date TEXT, amount REAL, amount_net REAL,
              tax_amount REAL, category_id TEXT, currency TEXT NOT NULL DEFAULT 'CNY',
              payment_status TEXT, paid_amount REAL, payment_date TEXT);
            INSERT INTO settings VALUES ('accounting_locale','"CN"','');
            INSERT INTO settings VALUES ('currency','"CNY"','');
            INSERT INTO transactions VALUES
              ('t1','income','2025-06-01',100,100,0,NULL,'CNY','paid',100,NULL);
            """)
        return db
    }

    /// The whole App-facing flow, written the way a view would write it: build, switch,
    /// exhaust. No `@testable`, no internal helper, no raw type named anywhere.
    func testTheWholeFlowIsReachableThroughThePublicSurfaceAlone() throws {
        let outcome = try ReportBuilder.build(try ledger(), period: ReportPeriod(year: "2025"))

        switch outcome {
        case .blocked(let blocker):
            // Exhaustive, no `default:` — a new blocker must be handled, not swallowed.
            switch blocker {
            case .accountingLocaleNotConfigured: XCTFail("locale is configured")
            case .accountingLocaleInvalid:       XCTFail("locale is valid")
            case .currencyNotConfigured:         XCTFail("currency is configured")
            case .currencyInvalid:               XCTFail("currency is valid")
            case .currencyMismatch:              XCTFail("currency matches")
            case .multipleCurrenciesInPeriod:    XCTFail("one currency")
            }

        case .report(let report):
            XCTAssertEqual(report.locale, "CN")
            XCTAssertEqual(report.currency, "CNY")
            XCTAssertEqual(report.source, ReportSource.transactions)
            XCTAssertEqual(report.period.year, "2025")

            // Parameters — both axes, exhaustively.
            XCTAssertEqual(report.parameters.count, 4)
            for parameter in report.parameters {
                switch parameter.stored {
                case .absent, .usable, .needsRepair: break
                }
                switch parameter.nativeEffect {
                case .appliedValue, .appliedNonFinite, .refused: break
                }
                switch parameter.consumption {
                case .consumed, .storedButUnread: break
                }
                _ = parameter.key.rawValue
            }

            // Sections — every report type arrives with its availability attached, and every
            // line is a classified value. There is no `Double` to reach for.
            XCTAssertFalse(report.sections.isEmpty)
            for section in report.sections {
                switch section.availability {
                case .renderInFull, .renderWithMissingLines: XCTAssertFalse(section.lines.isEmpty)
                case .withhold:                              XCTAssertTrue(section.lines.isEmpty)
                }
                for line in section.lines {
                    switch line.unit {
                    case .money, .percent: break
                    }
                    switch line.value {
                    case .amount(let x):    XCTAssertTrue(x.isFinite)
                    case .corrupted:        break
                    case .notConfigured(let p):     _ = p
                    case .needsRepair(let p, let t): _ = p; _ = t
                    }
                    XCTAssertFalse(line.id.isEmpty)
                }
                for note in section.notes {
                    switch note {
                    case .estimatedTaxDueDates(let d):       XCTAssertFalse(d.isEmpty)
                    case .selfEmploymentParameterYear(let y): XCTAssertGreaterThan(y, 0)
                    }
                }
            }

            // Monthly breakdown, cash flow, warnings, tax-inclusive.
            XCTAssertEqual(report.monthlyBreakdown.count, 12)
            for month in report.monthlyBreakdown { XCTAssertGreaterThan(month.month, 0) }
            XCTAssertEqual(report.cashflow.basis, "cash")
            XCTAssertFalse(report.cashflow.statutory)
            for section in [report.cashflow.operating, report.cashflow.investing,
                            report.cashflow.financing, report.cashflow.beginningCash,
                            report.cashflow.endingCash] {
                switch section {
                case .computed, .noTransactionsInPeriod, .notDerivableFromThisDataModel: break
                }
            }
            for warning in report.warnings {
                switch warning {
                case .estimatedQuarterlyPayment, .mealsLimitedToFiftyPercent: break
                }
            }
            if let taxInclusive = report.undeclaredTaxInclusiveSummary {
                _ = taxInclusive.purchaseTotal; _ = taxInclusive.salesTotal
                _ = taxInclusive.difference
            }
        }
    }

    /// Both `ReportPeriod` initialisers are reachable, and a full year expands the way
    /// `index.js:34-35` does.
    func testPeriodInitialisersArePublic() {
        XCTAssertEqual(ReportPeriod(year: "2025").from, "2025-01-01")
        XCTAssertEqual(ReportPeriod(year: "2025").to, "2025-12-31")
        let q2 = ReportPeriod(year: "2025", from: "2025-04-01", to: "2025-06-30")
        XCTAssertEqual(q2.from, "2025-04-01")
    }

    /// The presented types are `Equatable` and `Sendable` from outside the module — a view
    /// model will hold them across actor boundaries and diff them.
    func testPresentedTypesAreEquatableAndSendableFromOutside() {
        func requireSendable<T: Sendable & Equatable>(_ value: T) -> Bool { value == value }
        XCTAssertTrue(requireSendable(ReportFieldPresentation.amount(1)))
        XCTAssertTrue(requireSendable(ReportSectionPresentation.renderInFull))
        XCTAssertTrue(requireSendable(ReportRateProvenance.userConfigured))
        XCTAssertTrue(requireSendable(ReportTypePresentation(id: "x", section: .withhold)))
        XCTAssertTrue(requireSendable(ReportPeriod(year: "2025")))
        XCTAssertTrue(requireSendable(ReportLineUnit.money))
        XCTAssertTrue(requireSendable(ReportParameterKey.vatRate))
        XCTAssertTrue(requireSendable(StoredSettingState.absent))
        XCTAssertTrue(requireSendable(ParameterEffect.appliedNonFinite))
        XCTAssertTrue(requireSendable(EffectOrigin.regimeDefault))
        XCTAssertTrue(requireSendable(ParameterConsumption.consumed))
        XCTAssertTrue(requireSendable(PresentedWarning.mealsLimitedToFiftyPercent))
        XCTAssertTrue(requireSendable(PresentedCashflowSection.noTransactionsInPeriod))
        XCTAssertTrue(requireSendable(PresentedNote.selfEmploymentParameterYear(2025)))
    }
}
