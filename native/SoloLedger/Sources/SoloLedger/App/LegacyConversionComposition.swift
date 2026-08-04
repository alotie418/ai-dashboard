import Foundation
import SoloLedgerCore

/// What the conversion entry points and the conversion wizard draw, as values a test can hold.
///
/// ## Why this exists, again
///
/// The same reason `ReportPageComposition` does: the claims that matter here — that the entry
/// point appears on the `hasUnconverted` branch and NOWHERE else, that every one of the
/// ninety-seven adjudicated strings has a render that uses it, that a failure page shows a key
/// and never an `Error` — have to be provable without driving the UI, and XCUITest cannot run
/// in a headless session.
///
/// So the views have no other source of keys. Each one is handed its slice of these values and
/// renders exactly what the slice names. A key that is not composed cannot reach the screen.
enum LegacyConversionComposition {

    // MARK: - The entry points
    //
    // `LegacyLedgerNotice` renders one of two different notices; only one of them may offer a
    // conversion. `legacy.other.*` describes invoices, fixed assets and the rest —
    // `LegacyConversionPlan` never scans those tables and `LegacyConversionRunner` cannot
    // carry them, so an entry point there would be a button that can only ever report
    // "nothing to convert". That is why the branch is decided HERE, once, rather than in a
    // view body where the two texts sit three lines apart.

    /// The two keys every conversion entry point draws, in order.
    static let entryKeys = ["legacy.convert.cta", "legacy.convert.cta.hint"]

    /// What `LegacyLedgerNotice` draws for one ledger summary.
    struct NoticeBlock: Equatable {
        let titleKey: String
        let messageKey: String
        /// ``entryKeys``, or empty. Empty is the `legacy.other.*` branch.
        let entry: [String]

        var allKeys: [String] { [titleKey, messageKey] + entry }
        var offersConversion: Bool { !entry.isEmpty }
    }

    /// What `LegacyLedgerBanner` draws. Both nil/empty when the banner does not render at all.
    struct BannerBlock: Equatable {
        let labelKey: String?
        let entry: [String]

        var allKeys: [String] { (labelKey.map { [$0] } ?? []) + entry }
        var offersConversion: Bool { !entry.isEmpty }
    }

    /// The notice's composition. The conversion entry is offered on `hasUnconverted` and on
    /// nothing else — `otherRecords` alone gets the notice that promises nothing.
    static func notice(_ summary: LegacyLedgerSummary) -> NoticeBlock {
        summary.hasUnconverted
            ? NoticeBlock(titleKey: "legacy.notice.title",
                          messageKey: "legacy.notice.message",
                          entry: entryKeys)
            : NoticeBlock(titleKey: "legacy.other.title",
                          messageKey: "legacy.other.message",
                          entry: [])
    }

    /// The banner's composition. It renders only for a ledger that has BOTH unconverted legacy
    /// rows and transactions to show; the notice covers the empty-looking ledger.
    static func banner(_ summary: LegacyLedgerSummary, ledgerIsEmpty: Bool) -> BannerBlock {
        guard summary.hasUnconverted, !ledgerIsEmpty else {
            return BannerBlock(labelKey: nil, entry: [])
        }
        return BannerBlock(labelKey: "legacy.banner", entry: entryKeys)
    }

    // MARK: - Where every conversion key is drawn

    /// Where on the wizard a key belongs. Total over the whole `legacy.convert.*` namespace.
    enum Region: String, CaseIterable, Equatable {
        /// The call to action, on the two entry points — not inside the sheet.
        case entry
        /// Sheet title and opening paragraph.
        case frame
        case blocked
        case summary
        case rows
        case mapping
        case category
        case consequence
        case year
        case backup
        case running
        case done
        case failed
    }

    /// Every key the conversion feature can draw, and where. Asserted to be exactly the
    /// ninety-seven `legacy.convert.*` keys, in both directions.
    static let placement: [String: Region] = [
        // MARK: entry (2)
        "legacy.convert.cta": .entry,
        "legacy.convert.cta.hint": .entry,
        // MARK: frame (3)
        "legacy.convert.title": .frame,
        "legacy.convert.intro": .frame,
        "legacy.convert.action.convert": .frame,
        // MARK: blocked (11)
        "legacy.convert.blocked.accountingLocaleNotConfigured.title": .blocked,
        "legacy.convert.blocked.accountingLocaleNotConfigured.body": .blocked,
        "legacy.convert.blocked.accountingLocaleInvalid.title": .blocked,
        "legacy.convert.blocked.accountingLocaleInvalid.body": .blocked,
        "legacy.convert.blocked.currencyNotConfigured.title": .blocked,
        "legacy.convert.blocked.currencyNotConfigured.body": .blocked,
        "legacy.convert.blocked.currencyInvalid.title": .blocked,
        "legacy.convert.blocked.currencyInvalid.body": .blocked,
        "legacy.convert.blocked.currencyNotStorableVerbatim.title": .blocked,
        "legacy.convert.blocked.currencyNotStorableVerbatim.body": .blocked,
        "legacy.convert.storedText.label": .blocked,
        // MARK: summary (9)
        "legacy.convert.summary.title": .summary,
        "legacy.convert.grade.convertible": .summary,
        "legacy.convert.grade.convertible.note": .summary,
        "legacy.convert.grade.needsAdjudication": .summary,
        "legacy.convert.grade.needsAdjudication.note": .summary,
        "legacy.convert.grade.unconvertible": .summary,
        "legacy.convert.grade.unconvertible.note": .summary,
        "legacy.convert.nothingToConvert.title": .summary,
        "legacy.convert.nothingToConvert.message": .summary,
        // MARK: rows (26)
        "legacy.convert.rows.title": .rows,
        "legacy.convert.row.col.table": .rows,
        "legacy.convert.row.col.id": .rows,
        "legacy.convert.row.col.storedDate": .rows,
        "legacy.convert.row.col.issues": .rows,
        "legacy.convert.table.sales": .rows,
        "legacy.convert.table.purchases": .rows,
        "legacy.convert.row.idUnreadable": .rows,
        "legacy.convert.row.storedDateAbsent": .rows,
        "legacy.convert.issue.idNotReadableAsText": .rows,
        "legacy.convert.issue.dateMissing": .rows,
        "legacy.convert.issue.dateNotACalendarDay": .rows,
        "legacy.convert.issue.paymentDateNotACalendarDay": .rows,
        "legacy.convert.issue.dueDateNotACalendarDay": .rows,
        "legacy.convert.issue.totalAmountNotANumber": .rows,
        "legacy.convert.issue.taxAmountNotANumber": .rows,
        "legacy.convert.issue.taxRateNotANumber": .rows,
        "legacy.convert.issue.paidAmountNotANumber": .rows,
        "legacy.convert.issue.amountWithoutTaxNotANumber": .rows,
        "legacy.convert.issue.paymentStatusUnrecognized": .rows,
        "legacy.convert.issue.counterpartyWouldBeTruncated": .rows,
        "legacy.convert.issue.invoiceNoWouldBeTruncated": .rows,
        "legacy.convert.issue.counterpartyNotReadableAsText": .rows,
        "legacy.convert.issue.invoiceNoNotReadableAsText": .rows,
        "legacy.convert.issue.paymentDateNotReadableAsText": .rows,
        "legacy.convert.issue.dueDateNotReadableAsText": .rows,
        // MARK: mapping (1)
        "legacy.convert.mapping.note": .mapping,
        // MARK: category (5)
        "legacy.convert.category.title": .category,
        "legacy.convert.category.income": .category,
        "legacy.convert.category.expense": .category,
        "legacy.convert.category.placeholder": .category,
        "legacy.convert.category.note": .category,
        // MARK: consequence (10)
        "legacy.convert.consequence.title": .consequence,
        "legacy.convert.consequence.reportSource": .consequence,
        "legacy.convert.consequence.currency": .consequence,
        "legacy.convert.consequence.shipping": .consequence,
        "legacy.convert.consequence.lineItems": .consequence,
        "legacy.convert.consequence.createdAt": .consequence,
        "legacy.convert.consequence.statuses": .consequence,
        "legacy.convert.consequence.sourceRecord": .consequence,
        "legacy.convert.consequence.legacyRowsKept": .consequence,
        "legacy.convert.consequence.attachments": .consequence,
        // MARK: year (5)
        "legacy.convert.year.title": .year,
        "legacy.convert.year.existing": .year,
        "legacy.convert.year.noneYet": .year,
        "legacy.convert.year.secondCurrency": .year,
        "legacy.convert.year.upperBound": .year,
        // MARK: backup (3)
        "legacy.convert.backup.title": .backup,
        "legacy.convert.backup.note": .backup,
        "legacy.convert.backup.scope": .backup,
        // MARK: running (2)
        "legacy.convert.running.title": .running,
        "legacy.convert.running.message": .running,
        // MARK: done (6)
        "legacy.convert.done.title": .done,
        "legacy.convert.done.message": .done,
        "legacy.convert.done.skipped": .done,
        "legacy.convert.done.backup": .done,
        "legacy.convert.done.legacyKept": .done,
        "legacy.convert.done.reportNote": .done,
        // MARK: failed (14)
        "legacy.convert.failed.title": .failed,
        "legacy.convert.failed.categoryRequiredIncome": .failed,
        "legacy.convert.failed.categoryRequiredExpense": .failed,
        "legacy.convert.failed.categoryNotFound": .failed,
        "legacy.convert.failed.categoryWrongType": .failed,
        "legacy.convert.failed.categoryWrongLocale": .failed,
        "legacy.convert.failed.ledgerChanged": .failed,
        "legacy.convert.failed.rowVanished": .failed,
        "legacy.convert.failed.rowNoLongerConvertible": .failed,
        "legacy.convert.failed.backupFailed": .failed,
        "legacy.convert.failed.backupNotValid": .failed,
        "legacy.convert.failed.busy": .failed,
        "legacy.convert.failed.internal": .failed,
        "legacy.convert.failed.retryNote": .failed,
    ]

    // MARK: - One render

    /// The plan page. Every list is in display order and holds only the keys THIS plan uses.
    struct SummaryBlock: Equatable {
        let gradeKeys: [String]
        let rowKeys: [String]
        let mappingKeys: [String]
        let categoryKeys: [String]
        let consequenceKeys: [String]
        let yearKeys: [String]
        let backupKeys: [String]
        let actionKeys: [String]

        var allKeys: [String] {
            gradeKeys + rowKeys + mappingKeys + categoryKeys
                + consequenceKeys + yearKeys + backupKeys + actionKeys
        }
    }

    /// One render of the wizard.
    struct Page: Equatable {
        let frameKeys: [String]
        /// Exactly one of the five below is non-nil, matching the state it was composed from.
        let blockedKeys: [String]?
        let summary: SummaryBlock?
        let runningKeys: [String]?
        let doneKeys: [String]?
        let failedKeys: [String]?

        var allKeys: Set<String> {
            var keys = Set(frameKeys)
            keys.formUnion(blockedKeys ?? [])
            keys.formUnion(summary?.allKeys ?? [])
            keys.formUnion(runningKeys ?? [])
            keys.formUnion(doneKeys ?? [])
            keys.formUnion(failedKeys ?? [])
            return keys
        }
    }

    /// The empty page: the sheet is not open.
    static let idlePage = Page(frameKeys: [], blockedKeys: nil, summary: nil,
                               runningKeys: nil, doneKeys: nil, failedKeys: nil)

    static func compose(_ state: LegacyConversionState) -> Page {
        switch state {
        case .idle:
            return idlePage

        case .blocked(let blocker):
            // The opening paragraph stays: it says what a conversion would be and that nothing
            // is written until you confirm, both of which remain true on a page where one
            // cannot be started at all.
            return Page(frameKeys: ["legacy.convert.title", "legacy.convert.intro"],
                        blockedKeys: blockedKeys(for: blocker),
                        summary: nil, runningKeys: nil, doneKeys: nil, failedKeys: nil)

        case .summary(let plan):
            return Page(frameKeys: ["legacy.convert.title", "legacy.convert.intro"],
                        blockedKeys: nil, summary: summaryBlock(for: plan),
                        runningKeys: nil, doneKeys: nil, failedKeys: nil)

        case .running:
            // No `intro` here: "nothing is written until you confirm" is no longer the
            // situation, and a paragraph that describes the previous screen is a lie about
            // this one.
            return Page(frameKeys: ["legacy.convert.title"], blockedKeys: nil, summary: nil,
                        runningKeys: ["legacy.convert.running.title",
                                      "legacy.convert.running.message"],
                        doneKeys: nil, failedKeys: nil)

        case .completed(_, _, let backupPath):
            var done = ["legacy.convert.done.title", "legacy.convert.done.message",
                        "legacy.convert.done.skipped"]
            // `backupDirectory` is nil only for an empty execution set, which never reaches a
            // run — but the page states what it has rather than what it expects to have.
            if backupPath != nil { done.append("legacy.convert.done.backup") }
            done += ["legacy.convert.done.legacyKept", "legacy.convert.done.reportNote"]
            return Page(frameKeys: ["legacy.convert.title"], blockedKeys: nil, summary: nil,
                        runningKeys: nil, doneKeys: done, failedKeys: nil)

        case .failed(let copy):
            var failed = ["legacy.convert.failed.title", copy.messageKey]
            if copy.showsRetryNote { failed.append("legacy.convert.failed.retryNote") }
            return Page(frameKeys: ["legacy.convert.title"], blockedKeys: nil, summary: nil,
                        runningKeys: nil, doneKeys: nil, failedKeys: failed)
        }
    }

    // MARK: - The blocked page

    /// The stored-text label is drawn for exactly the two blockers that CARRY stored text.
    /// The other three have nothing verbatim to show, and a label over an empty box would
    /// suggest the ledger holds something it does not.
    static func blockedKeys(for blocker: LegacyConversionBlocker) -> [String] {
        switch blocker {
        case .accountingLocaleNotConfigured:
            return ["legacy.convert.blocked.accountingLocaleNotConfigured.title",
                    "legacy.convert.blocked.accountingLocaleNotConfigured.body"]
        case .accountingLocaleInvalid:
            return ["legacy.convert.blocked.accountingLocaleInvalid.title",
                    "legacy.convert.blocked.accountingLocaleInvalid.body",
                    "legacy.convert.storedText.label"]
        case .currencyNotConfigured:
            return ["legacy.convert.blocked.currencyNotConfigured.title",
                    "legacy.convert.blocked.currencyNotConfigured.body"]
        case .currencyInvalid:
            return ["legacy.convert.blocked.currencyInvalid.title",
                    "legacy.convert.blocked.currencyInvalid.body",
                    "legacy.convert.storedText.label"]
        case .currencyNotStorableVerbatim:
            return ["legacy.convert.blocked.currencyNotStorableVerbatim.title",
                    "legacy.convert.blocked.currencyNotStorableVerbatim.body"]
        }
    }

    /// The ledger's own bytes, for the two blockers that carry them. Nil for the other three.
    static func storedText(for blocker: LegacyConversionBlocker) -> String? {
        switch blocker {
        case .accountingLocaleInvalid(let stored), .currencyInvalid(let stored):
            return stored
        case .accountingLocaleNotConfigured, .currencyNotConfigured, .currencyNotStorableVerbatim:
            return nil
        }
    }

    // MARK: - The plan page

    /// The directions the execution set actually contains — and therefore the only ones a
    /// category is required for. `LegacyConversionRunner` asks the same question of the same
    /// set; demanding an expense category for a conversion carrying no purchases would be
    /// asking the user to make a choice with no consequence.
    static func requiredDirections(_ plan: LegacyConversionPlan) -> Set<TransactionType> {
        Set(plan.rows(graded: .convertible).map { $0.table.transactionType })
    }

    static func summaryBlock(for plan: LegacyConversionPlan) -> SummaryBlock {
        SummaryBlock(gradeKeys: gradeKeys(for: plan),
                     rowKeys: rowKeys(for: plan),
                     mappingKeys: plan.rows.isEmpty ? [] : ["legacy.convert.mapping.note"],
                     categoryKeys: categoryKeys(for: plan),
                     consequenceKeys: consequenceKeys(for: plan),
                     yearKeys: yearKeys(for: plan),
                     backupKeys: plan.hasNothingToConvert
                         ? []
                         : ["legacy.convert.backup.title", "legacy.convert.backup.note",
                            "legacy.convert.backup.scope"],
                     actionKeys: plan.hasNothingToConvert
                         ? []
                         : ["legacy.convert.action.convert"])
    }

    /// All three counts, always — including the zeroes.
    ///
    /// A grade that is hidden at zero is indistinguishable on screen from a grade nobody
    /// checked, and "nothing here cannot be converted" is exactly the reassurance this page
    /// exists to give. The explanatory note beside a count is shown only when the count is
    /// non-zero: "these records contain values this app cannot carry" describes a set, and
    /// there is no set to describe when it is empty.
    static func gradeKeys(for plan: LegacyConversionPlan) -> [String] {
        var keys = ["legacy.convert.summary.title"]
        if plan.hasNothingToConvert {
            keys += ["legacy.convert.nothingToConvert.title",
                     "legacy.convert.nothingToConvert.message"]
        }
        for (grade, count) in [(LegacyRowGrade.convertible, plan.convertibleCount),
                               (.needsAdjudication, plan.needsAdjudicationCount),
                               (.unconvertible, plan.unconvertibleCount)] {
            keys.append("legacy.convert.grade.\(grade.rawValue)")
            if count > 0 { keys.append("legacy.convert.grade.\(grade.rawValue).note") }
        }
        return keys
    }

    /// The per-record list: the headers, the source tables that actually appear, the two
    /// missing-value stand-ins that are actually needed, and one sentence per issue actually
    /// present. Ordered by the enum's own `allCases`, so two runs over the same plan compose
    /// equal.
    static func rowKeys(for plan: LegacyConversionPlan) -> [String] {
        guard !plan.rows.isEmpty else { return [] }
        var keys = ["legacy.convert.rows.title",
                    "legacy.convert.row.col.table", "legacy.convert.row.col.id",
                    "legacy.convert.row.col.storedDate", "legacy.convert.row.col.issues"]
        for table in LegacyTable.allCases where plan.rows.contains(where: { $0.table == table }) {
            keys.append("legacy.convert.table.\(table.rawValue)")
        }
        if plan.rows.contains(where: { $0.id == nil }) {
            keys.append("legacy.convert.row.idUnreadable")
        }
        if plan.rows.contains(where: { $0.storedDate == nil }) {
            keys.append("legacy.convert.row.storedDateAbsent")
        }
        let present = Set(plan.rows.flatMap(\.issues))
        for issue in LegacyRowIssue.allCases where present.contains(issue) {
            keys.append("legacy.convert.issue.\(issue.rawValue)")
        }
        return keys
    }

    static func categoryKeys(for plan: LegacyConversionPlan) -> [String] {
        guard !plan.hasNothingToConvert else { return [] }
        var keys = ["legacy.convert.category.title"]
        let directions = requiredDirections(plan)
        if directions.contains(.income) { keys.append("legacy.convert.category.income") }
        if directions.contains(.expense) { keys.append("legacy.convert.category.expense") }
        keys += ["legacy.convert.category.placeholder", "legacy.convert.category.note"]
        return keys
    }

    /// All ten, or none.
    ///
    /// They are disclosures about what converting would change, so a plan that can convert
    /// nothing shows none of them — and a plan that can convert something shows all of them,
    /// including the ones whose figure happens to be zero. `consequence.lineItems` says in its
    /// own words that the count is an upper bound; suppressing it at zero would turn "no
    /// breakdowns will be collapsed" into silence.
    static func consequenceKeys(for plan: LegacyConversionPlan) -> [String] {
        guard !plan.hasNothingToConvert else { return [] }
        return ["legacy.convert.consequence.title",
                "legacy.convert.consequence.reportSource",
                "legacy.convert.consequence.currency",
                "legacy.convert.consequence.shipping",
                "legacy.convert.consequence.lineItems",
                "legacy.convert.consequence.createdAt",
                "legacy.convert.consequence.statuses",
                "legacy.convert.consequence.sourceRecord",
                "legacy.convert.consequence.legacyRowsKept",
                "legacy.convert.consequence.attachments"]
    }

    /// One line per year, plus the upper-bound caveat. `existing` and `noneYet` are exclusive —
    /// a year either already holds transactions or it does not — while `secondCurrency` is
    /// ADDITIONAL to whichever of the two applies.
    static func yearKeys(for plan: LegacyConversionPlan) -> [String] {
        guard !plan.yearOutlook.isEmpty else { return [] }
        var keys = ["legacy.convert.year.title"]
        for outlook in plan.yearOutlook {
            keys.append(outlook.existingTransactionCount > 0
                        ? "legacy.convert.year.existing"
                        : "legacy.convert.year.noneYet")
            if outlook.wouldHoldASecondCurrency {
                keys.append("legacy.convert.year.secondCurrency")
            }
        }
        keys.append("legacy.convert.year.upperBound")
        return keys
    }
}
