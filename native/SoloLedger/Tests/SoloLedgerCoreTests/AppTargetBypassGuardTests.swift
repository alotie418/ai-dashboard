import XCTest
@testable import SoloLedgerCore

/// A SECOND line of defence: the SwiftUI target must reach the report subsystem only
/// through `ReportBuilder`.
///
/// ## This guard is deliberately the weaker of the two, and says so
///
/// The primary control is structural — after P2 every raw report symbol is `internal`, so
/// the App target CANNOT name one, and `scripts/check-reports-public-surface.mjs` holds the
/// public surface to a closed set derived from the compiler's own symbol graph.
///
/// This test scans App source TEXT for the forbidden names. It catches a symbol that was
/// re-widened and then used, and it produces a much clearer failure than a compile error
/// would. It does NOT catch a new public wrapper in Core that leaks a raw value — that is
/// the closed-set guard's job, and it is where the real assurance lives. Recording the
/// division here so a green run is not read as more than it is.
final class AppTargetBypassGuardTests: XCTestCase {

    /// Names the App target must not mention. Every one of them is `internal` after P2, so a
    /// hit means someone widened it again.
    private static let forbidden: [String] = [
        "ReportContext", "ReportFetch", "ReportSettings", "ReportDispatcher",
        "ReportTypes", "ReportTypeEntry", "ReportTypeAvailability",
        "EstimatedValue", "ReportRateSetting", "FiniteRate", "ReportMath",
        "ReportRow", "ReportCategory", "ExpenseSplit",
        "CNReportEngine", "JPReportEngine", "EUReportEngine",
        "KRReportEngine", "TWReportEngine", "USReportEngine", "USTaxParams",
        "CNBatchOneIncomeStatement", "BatchOneIncomeStatementWithOperatingProfit",
        "EUBatchOneProfitLoss", "BatchOneIncomeStatement",
        "ScheduleC", "SelfEmploymentTax", "EstimatedTax", "TaxInclusiveSummary",
        "CNVATSummary", "JPConsumptionTax", "EUVATReturn", "KRVATSummary", "TWBusinessTax",
        "CashflowStatement", "OperatingCashflow", "CashflowSection",
        "OperatingCashflowSection", "CashflowRow", "ReportMonth",
        "selectReportSource", "readSnapshot",
        // Narrowed with the rest: `PresentedReport` no longer carries a `source`, because
        // `ReportBuilder` stops at `legacySourceUnavailable` and a successful report is by
        // construction built from `transactions`. A field with one possible value would only
        // suggest the other one is reachable.
        "ReportSource",
    ]

    /// What the App SHOULD use. Listed so the guard cannot be satisfied by an App that
    /// simply never mentions reports — see `testTheAllowedSurfaceIsRealAndNamed`.
    private static let allowed: [String] = [
        "ReportBuilder", "ReportOutcome", "ReportBlocker", "ReportPeriod",
        "PresentedReport", "PresentedSection", "PresentedLine", "PresentedNote",
        "PresentedMonth", "PresentedCashflow", "PresentedCashflowSection",
        "PresentedWarning", "PresentedTaxInclusiveSummary", "PresentedParameter",
        "ReportLineUnit", "ReportParameterKey", "StoredSettingState", "ParameterEffect",
        "EffectOrigin", "ParameterConsumption",
        "ReportFieldPresentation", "ReportRateProvenance",
        "ReportSectionPresentation", "ReportTypePresentation",
        "ReportRateParameter",
    ]

    // MARK: - The scan, as a pure function

    struct Hit: Hashable, CustomStringConvertible {
        let file: String, line: Int, symbol: String
        var description: String { "\(file):\(line) mentions \(symbol)" }
    }

    /// Pure, so the guard's own behaviour can be proved against synthetic sources without
    /// committing a violating file.
    static func hits(in sources: [(path: String, text: String)],
                     forbidding names: [String]) -> [Hit] {
        var out: [Hit] = []
        for (path, text) in sources {
            for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated() {
                let line = String(raw)
                // Comments are not code. A doc comment explaining why the App must not touch
                // `ReportContext` is exactly the sort of sentence this file itself contains.
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                for name in names where mentions(name, in: line) {
                    out.append(Hit(file: path, line: index + 1, symbol: name))
                }
            }
        }
        return out
    }

    /// Whole-identifier match, so `ReportSource` does not fire on `ReportSourceSelector` and
    /// `ScheduleC` does not fire on `ScheduleCell`.
    private static func mentions(_ name: String, in line: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: "(?<![A-Za-z0-9_])\(name)(?![A-Za-z0-9_])")
        else { return false }
        return re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    // MARK: - The guard over the real App target

    func testTheAppTargetNamesNoRawReportSymbol() throws {
        let sources = try Self.appSources()
        XCTAssertFalse(sources.isEmpty, "the App target must have sources to scan")
        let found = Self.hits(in: sources, forbidding: Self.forbidden)
        XCTAssertTrue(found.isEmpty, """
            the SwiftUI target names raw report symbols: \
            \(found.map(\.description).sorted().joined(separator: ", ")). Everything the App \
            needs arrives already classified on `PresentedReport`; reaching past it is how an \
            unclassified value gets onto a screen.
            """)
    }

    // MARK: - Self-tests: what the guard REJECTS

    func testAForbiddenSymbolInSyntheticAppSourceIsReported() {
        let source = [("Views/ReportsView.swift", """
            import SwiftUI
            import SoloLedgerCore
            struct ReportsView: View {
                var body: some View {
                    let ctx = ReportContext(incomeRows: [], expenseRows: [])
                    Text("\\(CNReportEngine.batchOne(ctx).grossProfit)")
                }
            }
            """)]
        let found = Self.hits(in: source, forbidding: Self.forbidden)
        XCTAssertEqual(Set(found.map(\.symbol)), ["ReportContext", "CNReportEngine"])
    }

    func testEveryForbiddenSymbolIsIndividuallyDetectable() {
        for name in Self.forbidden {
            let found = Self.hits(in: [("X.swift", "let x = \(name).self")], forbidding: [name])
            XCTAssertEqual(found.count, 1, "\(name) must be detectable")
        }
    }

    /// Whole-identifier matching: a longer name that merely CONTAINS a forbidden one is not
    /// a hit, and the forbidden one alone still is.
    func testMatchingIsWholeIdentifierNotSubstring() {
        XCTAssertTrue(Self.hits(in: [("X.swift", "ReportSource.transactions")],
                                forbidding: ["ReportSource"]).isEmpty == false)
        XCTAssertTrue(Self.hits(in: [("X.swift", "let s = ReportSourceSelector()")],
                                forbidding: ["ReportSource"]).isEmpty,
                      "a longer identifier must not fire")
        XCTAssertTrue(Self.hits(in: [("X.swift", "ScheduleCell(x)")],
                                forbidding: ["ScheduleC"]).isEmpty)
    }

    /// A comment naming a forbidden symbol is not a use. This very file is the proof that
    /// the distinction is needed.
    func testCommentsAreNotUses() {
        XCTAssertTrue(Self.hits(in: [("X.swift", "    // never touch ReportContext here")],
                                forbidding: Self.forbidden).isEmpty)
        XCTAssertFalse(Self.hits(in: [("X.swift", "let c = ReportContext()")],
                                 forbidding: Self.forbidden).isEmpty)
    }

    /// The allowed surface is not merely "everything we did not forbid": these names must
    /// really exist as public symbols, or the App would have nothing to use.
    func testTheAllowedSurfaceIsRealAndNamed() throws {
        let allowlist = try Self.publicSurfaceAllowlist()
        let roots = Set(allowlist.compactMap { $0.split(separator: "\t").last }
            .map { $0.split(separator: "/").first.map(String.init) ?? "" })
        for name in Self.allowed {
            XCTAssertTrue(roots.contains(name),
                          "\(name) is offered to the App but is not in the public closed set")
        }
        XCTAssertTrue(Set(Self.allowed).isDisjoint(with: Set(Self.forbidden)),
                      "a symbol cannot be both offered and forbidden")
    }

    // MARK: - Helpers

    /// …/native/SoloLedger/Tests/SoloLedgerCoreTests/<this>.swift → …/native/SoloLedger
    private static func packageRoot() -> URL {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { dir.deleteLastPathComponent() }
        return dir
    }

    private static func appSources() throws -> [(path: String, text: String)] {
        let root = packageRoot().appendingPathComponent("Sources/SoloLedger")
        guard let walker = FileManager.default.enumerator(atPath: root.path) else {
            XCTFail("cannot enumerate \(root.path)"); return []
        }
        var out: [(String, String)] = []
        for case let rel as String in walker where rel.hasSuffix(".swift") {
            let url = root.appendingPathComponent(rel)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                XCTFail("cannot read \(rel)"); continue
            }
            out.append(("Sources/SoloLedger/\(rel)", text))
        }
        return out
    }

    /// The closed-set allowlist the symbol-graph guard maintains. Read rather than
    /// duplicated, so the two guards cannot disagree about what is public.
    private static func publicSurfaceAllowlist() throws -> [String] {
        var dir = packageRoot()
        dir.deleteLastPathComponent(); dir.deleteLastPathComponent()   // …/<repo root>
        let url = dir.appendingPathComponent("scripts/reports-public-surface.allowlist.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([String].self, from: data)
    }
}
