import Foundation
import SoloLedgerCore

/// What the Overview page's month-on-month / year-on-year block draws, as a value a test can
/// hold — the same shape `ProductPageComposition` and `InventoryPageComposition` use, and for
/// the same reason: XCUITest cannot run headless, so "is it on screen" has to be answerable
/// structurally.
///
/// ## What this block claims, and what it does NOT
///
/// It claims exactly the eleven keys under the `overview` metrics prefix. The seventeen older
/// keys on this page have no placement table and are not adjudicated here — that debt is
/// registered and deliberately left alone, so the closure test below is written against the
/// block's own prefix rather than the page's.
///
/// The month column reuses the page's existing month heading, which the chart above already
/// draws. This file does not claim it: one round's block should not quietly take ownership of
/// a key another part of the same page has been writing all along.
///
/// ## The basis sentence is dispatched by accounting regime
///
/// Five of the six regimes compute monthly revenue from each transaction's tax-exclusive
/// amount, falling back to the full amount when none was recorded. The United States regime
/// does not: it sums the full recorded amount always, because Schedule C works in gross
/// receipts throughout. One sentence therefore cannot be true for all six, and
/// ``basisNoteKey(for:)`` picks the one that is true for the ledger in front of the user.
///
/// This is the sharp edge of the rule that a sentence about a calculation is answerable to the
/// implementation and not to any summary of it: the copy round pinned its sentence to the
/// shared fallback helper, which is a true statement about that helper and still the wrong
/// sentence for a US ledger, because the US engine never calls it.
///
/// ## Percentages, and the three states a cell can be in
///
/// The engine answers `nil` when the base period is missing or zero — the promise the no-base
/// sentence makes — and it answers a NON-nil `NaN` when the current month itself has no
/// figure, which is what its JavaScript original produces. Both must reach the screen as the
/// same dash, so ``finite(_:)`` folds them together before anything is formatted. A `NaN` that
/// slipped through would print as literal text under a heading that promises a percentage.
///
/// Formatting lives here rather than in the view, and does NOT reuse the report page's
/// percentage helper: that one is fixed at two decimals, while these figures are quantised to
/// one by the engine and the no-base sentence names a one-decimal zero in all six languages.
enum OverviewPageComposition {

    // MARK: - Regions

    /// Where in the block a key is drawn.
    enum Region: String, CaseIterable, Equatable {
        /// The block heading. The year it describes is drawn beside it as a bare numeral —
        /// data, not copy, in the shape the currency code beside the chart heading already uses.
        case header
        /// The three value column headings. The month column's heading is not one of them.
        case columnHeader
        /// The two sentences under the table that say what each column compares against.
        case caption
        /// The standing declarations: which amounts the figures are computed on, and why a
        /// cell is left blank instead of showing a zero percent.
        case note
        /// Shown instead of the table when nothing in the year can be compared.
        case empty
    }

    // MARK: - Placement

    /// Every key this block can draw, and the regions it belongs to.
    ///
    /// Eleven: the ten the copy round landed, plus the US basis sentence this round adds. Both
    /// basis sentences are placed, because both are reachable — which one appears depends on
    /// the ledger's regime, not on this table.
    static let placement: [String: Set<Region>] = [
        "overview.metrics.title": [.header],
        "overview.metrics.revenue": [.columnHeader],
        "overview.metrics.mom": [.columnHeader],
        "overview.metrics.yoy": [.columnHeader],
        "overview.metrics.momCaption": [.caption],
        "overview.metrics.yoyCaption": [.caption],
        "overview.metrics.basisNote": [.note],
        "overview.metrics.basisNoteUS": [.note],
        "overview.metrics.noBaseNote": [.note],
        "overview.metrics.empty.title": [.empty],
        "overview.metrics.empty.message": [.empty],
    ]

    /// Keys borrowed from other namespaces. Empty on purpose — see the type doc on the month
    /// heading, which the chart draws and this block reuses without claiming.
    static let sharedKeys: [String: Set<Region>] = [:]

    /// Keys written into the block's namespace that it deliberately does not place. Empty, and
    /// asserted to be empty, so the closure test stays a plain equality.
    static let exemptKeys: Set<String> = []

    /// The block heading, named here rather than written into the view.
    static let blockTitleKey = "overview.metrics.title"

    /// Which basis sentence is true for a ledger keeping this regime.
    ///
    /// Exhaustive with no `default`: a seventh regime stops this file compiling rather than
    /// silently inheriting a sentence that may not describe its engine.
    static func basisNoteKey(for regime: AccountingLocale) -> String {
        switch regime {
        case .US:
            return "overview.metrics.basisNoteUS"
        case .CN, .JP, .EU, .KR, .TW:
            return "overview.metrics.basisNote"
        }
    }

    // MARK: - Input

    /// Everything the block needs, already read from the ledger.
    ///
    /// Assembled by `AppModel`, never here: producing it costs two report builds, and a
    /// composition is evaluated inside a view's body.
    struct Input: Equatable {
        /// The regime the ledger stores. Decides which basis sentence is stated.
        var regime: AccountingLocale
        /// The calendar year the twelve rows describe — the most recent year holding a
        /// transaction, so a ledger that stopped being written to keeps showing its last full
        /// picture instead of emptying out every January.
        var year: String
        /// The currency the report was built in.
        var currency: String
        /// Twelve monthly revenues in month order; `nil` for a month the report could not
        /// classify as an amount.
        var revenue: [Double?]
        /// Last year's twelve, aligned by index. Empty when last year has no report at all,
        /// which is the ordinary case for a ledger in its first year.
        var priorRevenue: [Double?]
    }

    // MARK: - Page

    struct Row: Equatable, Identifiable {
        var id: Int { month }
        /// 1…12.
        let month: Int
        let revenue: Double?
        let mom: Double?
        let yoy: Double?
    }

    struct Page: Equatable {
        let titleKey: String
        /// Drawn beside the title as a bare numeral.
        let year: String
        let columnHeaderKeys: [String]
        let captionKeys: [String]
        let noteKeys: [String]
        let rows: [Row]
        let emptyKeys: [String]
    }

    /// Compose the block. Pure: same input, same page.
    static func compose(_ input: Input) -> Page {
        let comparisons = MonthlyComparisons.compute(
            input.revenue.map { MonthlyComparisons.Row(revenue: $0) },
            priorRevenue: input.priorRevenue)

        let rows = comparisons.enumerated().map { index, comparison in
            Row(month: index + 1,
                revenue: input.revenue.indices.contains(index) ? input.revenue[index] : nil,
                mom: finite(comparison.mom),
                yoy: finite(comparison.yoy))
        }

        // A DATA predicate, not a row count. The table is twelve rows for any ledger the
        // report will describe, so "not enough to compare" cannot be read off its length —
        // only off whether any comparison came out at all.
        let anyComparison = rows.contains { $0.mom != nil || $0.yoy != nil }
        guard anyComparison else {
            return Page(titleKey: blockTitleKey, year: input.year,
                        columnHeaderKeys: [], captionKeys: [], noteKeys: [], rows: [],
                        emptyKeys: ["overview.metrics.empty.title",
                                    "overview.metrics.empty.message"])
        }

        return Page(titleKey: blockTitleKey,
                    year: input.year,
                    columnHeaderKeys: ["overview.metrics.revenue",
                                       "overview.metrics.mom",
                                       "overview.metrics.yoy"],
                    captionKeys: ["overview.metrics.momCaption",
                                  "overview.metrics.yoyCaption"],
                    noteKeys: [basisNoteKey(for: input.regime),
                               "overview.metrics.noBaseNote"],
                    rows: rows,
                    emptyKeys: [])
    }

    // MARK: - Text

    /// A percentage as one decimal, or `nil` for a cell the view must leave as a dash.
    ///
    /// The engine has already quantised to one decimal; rounding again here is what makes the
    /// zero test and the formatter agree, and it is where a negative value whose rounded result
    /// is zero loses its sign. A minus in front of a zero reads as a decline that is not there,
    /// and the engine really can produce one: it mirrors a language whose own formatter hides
    /// it, so the sign survives into Swift where nothing would otherwise stop it.
    static func percentText(_ value: Double?, language: String) -> String? {
        guard let value, value.isFinite else { return nil }
        let tenths = (value * 10).rounded(.toNearestOrAwayFromZero)
        let normalised = tenths == 0 ? 0 : tenths / 10
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: language)
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        let digits = formatter.string(from: NSNumber(value: normalised))
            ?? String(format: "%.1f", normalised)
        return digits + "%"
    }

    /// A month's revenue, or `nil` for a month the report could not classify.
    static func revenueText(_ value: Double?, currency: String) -> String? {
        guard let value else { return nil }
        return Money.string(value, currency: currency)
    }

    /// `nil`, an infinity and a `NaN` all mean "no comparison"; only a finite number is one.
    private static func finite(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }
}
