import Foundation
import SoloLedgerCore
import XCTest

/// Real ledgers, one per accounting regime, driven through the PRODUCTION door.
///
/// The point is that the closed sets `ReportPresenter` claims are never compared against a
/// second hand-written list. They are compared against what `ReportBuilder.build` actually
/// emits for a real SQLite ledger — so an engine that gains or loses a line breaks the test,
/// which a hand-written list on both sides could not do.
///
/// Deliberately a plain `import SoloLedgerCore`, not `@testable`: everything below is reachable
/// through the App-facing public surface, and if that ever stopped being true this file would
/// stop compiling, which is exactly the signal wanted.
enum ReportFixtureBuilder {

    /// The year every fixture records into. Fixed, never derived from the clock.
    static let year = "2025"

    static func makeDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SLReportFixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A ledger that produces a REPORT (not a blocker) for ``year``.
    ///
    /// `applyRegimeSwitch` is what makes it so: it writes the regime, its preset rates AND its
    /// currency in one transaction. A bare `LedgerStore` seeds `accounting_locale` only, so it
    /// would stop at `currencyNotConfigured` — which is itself a fixture used below.
    static func makeStore(regime: AccountingLocale, in directory: URL,
                          filename: String = UUID().uuidString) throws -> LedgerStore {
        let store = try LedgerStore(databaseURL:
            directory.appendingPathComponent("\(regime.rawValue)-\(filename).db"))
        try store.settings.applyRegimeSwitch(AccountingProfile.profile(for: regime))
        let currency = regime.defaultCurrency
        try store.create(Transaction(type: .income, date: "\(year)-03-01", amount: 1_000,
                                     taxAmount: 130, currency: currency))
        try store.create(Transaction(type: .expense, date: "\(year)-04-01", amount: 400,
                                     taxAmount: 52, currency: currency))
        return store
    }

    /// The report for one regime, or a test failure explaining which blocker got in the way.
    static func report(regime: AccountingLocale, in directory: URL,
                       file: StaticString = #filePath, line: UInt = #line) throws -> PresentedReport {
        let store = try makeStore(regime: regime, in: directory)
        defer { try? store.db.close() }
        switch try ReportBuilder.build(store.db, period: ReportPeriod(year: year)) {
        case .report(let report):
            return report
        case .blocked(let blocker):
            XCTFail("\(regime.rawValue) fixture was blocked by \(blocker)", file: file, line: line)
            throw FixtureError.blocked
        }
    }

    static func allReports(in directory: URL,
                           file: StaticString = #filePath,
                           line: UInt = #line) throws -> [(AccountingLocale, PresentedReport)] {
        try AccountingLocale.allCases.map {
            ($0, try report(regime: $0, in: directory, file: file, line: line))
        }
    }

    /// Write a `settings` row VERBATIM, bypassing `SettingsStore`'s JSON encoding.
    ///
    /// Needed to reproduce the rows a repair flow exists for — the five bytes `"25%"` and the
    /// three bytes `25%` are different rows and `setString` can only produce the first.
    static func writeRawSetting(_ store: LedgerStore, key: String, rawText: String) throws {
        _ = try store.db.run("INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)",
                             [.text(key), .text(rawText)])
    }

    enum FixtureError: Error { case blocked }

    // MARK: - Source-file access (for the guards that read this PR's own code)

    /// …/native/SoloLedger/App/Tests/SoloLedgerUnitTests/<this>.swift → …/native/SoloLedger
    static func packageRoot() -> URL {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { dir.deleteLastPathComponent() }
        return dir
    }

    static func appSource(_ relativePath: String) throws -> String {
        let url = packageRoot().appendingPathComponent("Sources/SoloLedger/\(relativePath)")
        return try String(contentsOf: url, encoding: .utf8)
    }
}
