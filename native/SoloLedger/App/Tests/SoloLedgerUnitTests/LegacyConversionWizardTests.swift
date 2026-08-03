import XCTest
@testable import SoloLedger
@testable import SoloLedgerCore

/// Stage 2a-4 — the conversion wizard: its entry points, its composition, its failure map and
/// the paths it is forbidden to take.
///
/// ## What is proved here, and what is proved elsewhere
///
/// The WRITE is not re-tested here. `LegacyConversionRunnerTests` already proves atomicity,
/// the backup ordering, the category checks and the plan-staleness gate against a real ledger,
/// and repeating any of that in the App target would be a second, weaker copy of it.
///
/// What only this file can see is the layer above: that the entry point appears on the
/// `hasUnconverted` branch and nowhere else, that every one of the ninety-seven adjudicated
/// strings has a state that draws it, that a refusal reaches the screen as a localization key
/// rather than as the runner's own words, and that the background run is the only thing that
/// ever opens a second connection — through the hardened path, never a plain one.
@MainActor
final class LegacyConversionWizardTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SLWizard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    private func tempURL(_ name: String) -> URL { tempDir.appendingPathComponent(name) }

    // MARK: - Fixtures

    private let sales = LegacyLedgerSummary(salesTotal: 3, salesUnconverted: 3)
    private let purchasesOnly = LegacyLedgerSummary(purchasesTotal: 2, purchasesUnconverted: 2)
    private let othersOnly = LegacyLedgerSummary(otherRecords: 9)
    private let nothing = LegacyLedgerSummary()

    private func row(_ table: LegacyTable, _ id: String?, _ date: String?,
                     _ issues: [LegacyRowIssue] = []) -> LegacyConversionRow {
        LegacyConversionRow(table: table, id: id, storedDate: date, issues: issues)
    }

    private func plan(rows: [LegacyConversionRow],
                      lineItems: Int = 0,
                      outlook: [LegacyYearOutlook] = []) -> LegacyConversionPlan {
        LegacyConversionPlan(accountingLocale: .CN, currency: "CNY", rows: rows,
                             headersWithLineItems: lineItems, yearOutlook: outlook)
    }

    // ==========================================================================================
    // MARK: - W01/W02 — the entry point is on one branch and one branch only
    // ==========================================================================================

    /// The four quadrants of (`hasUnconverted`, ledger-is-empty), driven through the same pure
    /// functions the two views call. A view cannot disagree with this: it has no other source
    /// of keys.
    func testW01TheEntryPointAppearsOnlyForUnconvertedLegacyRows() {
        for summary in [sales, purchasesOnly,
                        LegacyLedgerSummary(salesUnconverted: 1, purchasesUnconverted: 1)] {
            XCTAssertTrue(LegacyConversionComposition.notice(summary).offersConversion)
            XCTAssertEqual(LegacyConversionComposition.notice(summary).entry,
                           LegacyConversionComposition.entryKeys)
            XCTAssertTrue(LegacyConversionComposition.banner(summary, ledgerIsEmpty: false)
                .offersConversion)
        }
    }

    /// `legacy.other.*` describes invoices, products and fixed assets. `LegacyConversionPlan`
    /// never scans those tables and the runner cannot carry them, so an entry point there could
    /// only ever report that there is nothing to convert.
    func testW02TheOtherRecordsBranchNeverOffersAConversion() {
        let notice = LegacyConversionComposition.notice(othersOnly)
        XCTAssertEqual(notice.titleKey, "legacy.other.title")
        XCTAssertEqual(notice.messageKey, "legacy.other.message")
        XCTAssertFalse(notice.offersConversion)
        XCTAssertEqual(notice.allKeys, ["legacy.other.title", "legacy.other.message"])

        // …and neither does an empty ledger, or the banner on a ledger with nothing to show.
        XCTAssertFalse(LegacyConversionComposition.notice(nothing).offersConversion)
        XCTAssertFalse(LegacyConversionComposition.banner(othersOnly, ledgerIsEmpty: false)
            .offersConversion)
        XCTAssertNil(LegacyConversionComposition.banner(sales, ledgerIsEmpty: true).labelKey,
                     "the banner is for a ledger that HAS transactions; the notice covers the rest")
        XCTAssertTrue(LegacyConversionComposition.banner(sales, ledgerIsEmpty: true).entry.isEmpty)
    }

    /// The notice is one of two notices, never a blend: the conversion entry and the
    /// other-records message can never be composed together.
    func testW02bTheTwoNoticesAreMutuallyExclusive() {
        for summary in [sales, purchasesOnly, othersOnly, nothing,
                        LegacyLedgerSummary(salesUnconverted: 1, otherRecords: 5)] {
            let notice = LegacyConversionComposition.notice(summary)
            XCTAssertEqual(notice.offersConversion, notice.messageKey == "legacy.notice.message")
            XCTAssertEqual(notice.offersConversion, summary.hasUnconverted)
        }
    }

    // ==========================================================================================
    // MARK: - W03/W04/W05 — the closed sets render completely and distinguishably
    // ==========================================================================================

    /// Five blockers, five distinct pairs, and the stored-text label on exactly the two that
    /// carry stored text — a label over an empty box would claim the ledger holds something.
    func testW03EveryBlockerComposesItsOwnPairAndOnlyTheTwoWithBytesShowThem() {
        let blockers: [LegacyConversionBlocker] = [
            .accountingLocaleNotConfigured,
            .accountingLocaleInvalid(storedText: "\u{FEFF}\"US\""),
            .currencyNotConfigured,
            .currencyInvalid(storedText: "123"),
            .currencyNotStorableVerbatim(currency: "TOOLONGCODE"),
        ]
        var seen: Set<[String]> = []
        for blocker in blockers {
            let keys = LegacyConversionComposition.blockedKeys(for: blocker)
            XCTAssertTrue(keys.count == 2 || keys.count == 3, "\(blocker): \(keys)")
            XCTAssertTrue(keys[0].hasSuffix(".title"))
            XCTAssertTrue(keys[1].hasSuffix(".body"))
            seen.insert(keys)
            let carriesBytes = LegacyConversionComposition.storedText(for: blocker) != nil
            XCTAssertEqual(keys.contains("legacy.convert.storedText.label"), carriesBytes,
                           "\(blocker): the stored-text label must follow the stored text")
        }
        XCTAssertEqual(seen.count, 5, "two blockers compose the same page")
    }

    /// All three counts, always — a grade hidden at zero is indistinguishable from one nobody
    /// checked. The explanatory note follows the count: there is no set to describe at zero.
    func testW04AllThreeGradesAreCountedAndOnlyNonEmptyOnesAreExplained() {
        let mixed = plan(rows: [row(.sales, "s1", "2024-01-02"),
                                row(.sales, "s2", "2024-01-03", [.taxRateNotANumber]),
                                row(.purchases, "p1", nil, [.dateMissing])])
        let keys = LegacyConversionComposition.gradeKeys(for: mixed)
        for grade in LegacyRowGrade.allCases {
            XCTAssertTrue(keys.contains("legacy.convert.grade.\(grade.rawValue)"),
                          "\(grade.rawValue) count must always be shown")
            XCTAssertTrue(keys.contains("legacy.convert.grade.\(grade.rawValue).note"))
        }
        XCTAssertFalse(keys.contains("legacy.convert.nothingToConvert.title"))

        // Only convertible rows → the other two notes have nothing to describe.
        let clean = plan(rows: [row(.sales, "s1", "2024-01-02")])
        let cleanKeys = LegacyConversionComposition.gradeKeys(for: clean)
        XCTAssertTrue(cleanKeys.contains("legacy.convert.grade.convertible.note"))
        XCTAssertFalse(cleanKeys.contains("legacy.convert.grade.needsAdjudication.note"))
        XCTAssertFalse(cleanKeys.contains("legacy.convert.grade.unconvertible.note"))
        XCTAssertTrue(cleanKeys.contains("legacy.convert.grade.unconvertible"), "the zero is shown")
    }

    /// Every issue the plan can produce has a sentence composed for it, and only the ones a
    /// plan actually holds are drawn.
    func testW05EveryRowIssueIsComposedAndOnlyThePresentOnesAre() {
        let all = LegacyRowIssue.allCases
        XCTAssertEqual(all.count, 17)
        let everything = plan(rows: all.map { row(.sales, "s-\($0.rawValue)", "2024-01-01", [$0]) })
        let keys = Set(LegacyConversionComposition.rowKeys(for: everything))
        for issue in all {
            XCTAssertTrue(keys.contains("legacy.convert.issue.\(issue.rawValue)"),
                          "\(issue.rawValue) has no sentence on the page")
        }
        // A plan with one issue draws one sentence, not seventeen.
        let one = plan(rows: [row(.sales, "s1", "2024-01-01", [.taxRateNotANumber])])
        let oneKeys = LegacyConversionComposition.rowKeys(for: one)
            .filter { $0.hasPrefix("legacy.convert.issue.") }
        XCTAssertEqual(oneKeys, ["legacy.convert.issue.taxRateNotANumber"])
    }

    /// The two missing-value stand-ins are drawn only when a row actually needs one, and the
    /// table names only for tables that appear.
    func testW05bTheRowStandInsAndTableNamesFollowTheData() {
        let ordinary = plan(rows: [row(.sales, "s1", "2024-01-01")])
        let keys = Set(LegacyConversionComposition.rowKeys(for: ordinary))
        XCTAssertTrue(keys.contains("legacy.convert.table.sales"))
        XCTAssertFalse(keys.contains("legacy.convert.table.purchases"))
        XCTAssertFalse(keys.contains("legacy.convert.row.idUnreadable"))
        XCTAssertFalse(keys.contains("legacy.convert.row.storedDateAbsent"))

        let damaged = plan(rows: [row(.purchases, nil, nil, [.idNotReadableAsText, .dateMissing])])
        let damagedKeys = Set(LegacyConversionComposition.rowKeys(for: damaged))
        XCTAssertTrue(damagedKeys.contains("legacy.convert.table.purchases"))
        XCTAssertTrue(damagedKeys.contains("legacy.convert.row.idUnreadable"))
        XCTAssertTrue(damagedKeys.contains("legacy.convert.row.storedDateAbsent"))

        XCTAssertTrue(LegacyConversionComposition.rowKeys(for: plan(rows: [])).isEmpty)
    }

    // ==========================================================================================
    // MARK: - W06/W07/W08 — the execution set
    // ==========================================================================================

    /// 2a-4 offers no per-record skip control, so `skipped` is empty and the execution set is
    /// exactly the plan's convertible set. Asserted against the runner's OWN definition of that
    /// set rather than against a re-derived one.
    func testW06AndW07TheExecutionSetIsExactlyTheConvertibleSet() {
        let mixed = plan(rows: [row(.sales, "s1", "2024-01-02"),
                                row(.purchases, "p1", "2024-01-05"),
                                row(.sales, "s2", "2024-01-03", [.paymentStatusUnrecognized]),
                                row(.purchases, "p2", nil, [.dateMissing])])
        let skipped: Set<LegacyRowIdentity> = []
        let expected = mixed.convertibleIdentities.subtracting(skipped)
        XCTAssertEqual(expected, [LegacyRowIdentity(table: .sales, legacyID: "s1"),
                                  LegacyRowIdentity(table: .purchases, legacyID: "p1")])
        XCTAssertTrue(skipped.isSubset(of: mixed.convertibleIdentities))
        XCTAssertEqual(expected.count, mixed.convertibleCount)
    }

    /// A row that needs adjudication or cannot be converted is not in the set the runner is
    /// given, and no user action can put it there — the composition offers no control that
    /// could.
    func testW08NonConvertibleRowsAreNeverInTheExecutionSet() {
        let mixed = plan(rows: [row(.sales, "s1", "2024-01-02"),
                                row(.sales, "adj", "2024-01-03", [.taxAmountNotANumber]),
                                row(.sales, "no", nil, [.dateMissing])])
        let identities = mixed.convertibleIdentities.map(\.legacyID)
        XCTAssertEqual(identities, ["s1"])
        XCTAssertEqual(mixed.rows(graded: .needsAdjudication).map(\.id), ["adj"])
        XCTAssertEqual(mixed.rows(graded: .unconvertible).map(\.id), ["no"])
    }

    // ==========================================================================================
    // MARK: - W09/W10/W11 — categories are asked for only where they are used
    // ==========================================================================================

    func testW09CategoryKeysFollowTheDirectionsActuallyPresent() {
        let both = plan(rows: [row(.sales, "s1", "2024-01-01"), row(.purchases, "p1", "2024-01-01")])
        XCTAssertEqual(LegacyConversionComposition.requiredDirections(both), [.income, .expense])
        let keys = LegacyConversionComposition.categoryKeys(for: both)
        XCTAssertTrue(keys.contains("legacy.convert.category.income"))
        XCTAssertTrue(keys.contains("legacy.convert.category.expense"))
    }

    func testW10SalesOnlyNeverAsksForAnExpenseCategory() {
        let salesOnly = plan(rows: [row(.sales, "s1", "2024-01-01"),
                                    row(.purchases, "p1", nil, [.dateMissing])])
        XCTAssertEqual(LegacyConversionComposition.requiredDirections(salesOnly), [.income])
        let keys = LegacyConversionComposition.categoryKeys(for: salesOnly)
        XCTAssertTrue(keys.contains("legacy.convert.category.income"))
        XCTAssertFalse(keys.contains("legacy.convert.category.expense"),
                       "asking for a category no converted row would carry is a choice with no consequence")
    }

    func testW11PurchasesOnlyNeverAsksForAnIncomeCategory() {
        let purchasesOnlyPlan = plan(rows: [row(.purchases, "p1", "2024-01-01")])
        XCTAssertEqual(LegacyConversionComposition.requiredDirections(purchasesOnlyPlan), [.expense])
        let keys = LegacyConversionComposition.categoryKeys(for: purchasesOnlyPlan)
        XCTAssertFalse(keys.contains("legacy.convert.category.income"))
        XCTAssertTrue(keys.contains("legacy.convert.category.expense"))
    }

    // ==========================================================================================
    // MARK: - W12 — a plan that can convert nothing offers nothing
    // ==========================================================================================

    /// No confirm button, no category question, no consequences and no backup section: every
    /// one of those describes something that would happen, and nothing would.
    func testW12NothingToConvertOffersNoActionAndNoBackup() {
        let hopeless = plan(rows: [row(.sales, "s1", nil, [.dateMissing]),
                                   row(.purchases, "p1", "2024-01-01", [.taxRateNotANumber])])
        XCTAssertTrue(hopeless.hasNothingToConvert)
        let block = LegacyConversionComposition.summaryBlock(for: hopeless)
        XCTAssertTrue(block.actionKeys.isEmpty)
        XCTAssertTrue(block.backupKeys.isEmpty)
        XCTAssertTrue(block.categoryKeys.isEmpty)
        XCTAssertTrue(block.consequenceKeys.isEmpty)
        XCTAssertTrue(block.gradeKeys.contains("legacy.convert.nothingToConvert.title"))
        XCTAssertTrue(block.gradeKeys.contains("legacy.convert.nothingToConvert.message"))
        // The rows are still listed: the user is owed the reason each one was left out.
        XCTAssertFalse(block.rowKeys.isEmpty)
    }

    // ==========================================================================================
    // MARK: - W13/W14 — opening, cancelling and double-submitting
    // ==========================================================================================

    /// Opening the wizard runs the preflight and writes nothing. Measured the way 2a-1 measures
    /// it: the database file and its `-wal` are hashed either side.
    func testW13OpeningTheWizardWritesNothingAndCancellingLeavesNoState() async throws {
        let model = try await bootedModel(withLegacyRows: true)
        let dbURL = tempURL("wizard.db")
        let before = try Self.fileDigests(dbURL)

        model.beginLegacyConversion()
        XCTAssertTrue(model.showingLegacyConversion)
        guard case .summary(let plan) = model.legacyConversion else {
            return XCTFail("expected a plan, got \(model.legacyConversion)")
        }
        XCTAssertEqual(plan.convertibleCount, 2)
        XCTAssertEqual(try Self.fileDigests(dbURL), before, "the preflight wrote to the ledger")

        model.dismissLegacyConversion()
        XCTAssertFalse(model.showingLegacyConversion)
        XCTAssertEqual(model.legacyConversion, .idle)
        XCTAssertNil(model.conversionIncomeCategoryID)
        XCTAssertNil(model.conversionExpenseCategoryID)
        XCTAssertEqual(try Self.fileDigests(dbURL), before, "cancelling wrote to the ledger")
    }

    /// The CTA is not reachable for a ledger with nothing unconverted — and the model refuses
    /// even if something called it anyway.
    func testW13bTheWizardRefusesToOpenWithoutUnconvertedRows() async throws {
        let model = try await bootedModel(withLegacyRows: false)
        model.beginLegacyConversion()
        XCTAssertFalse(model.showingLegacyConversion)
        XCTAssertEqual(model.legacyConversion, .idle)
    }

    /// A second `beginLegacyConversion` while a plan is already on screen must not silently
    /// replace it — the plan the user is reading is the plan a confirmation converts.
    func testW14ASecondOpenDoesNotReplaceThePlanOnScreen() async throws {
        let model = try await bootedModel(withLegacyRows: true)
        model.beginLegacyConversion()
        guard case .summary(let first) = model.legacyConversion else { return XCTFail("no plan") }
        model.conversionIncomeCategoryID = "chosen"
        model.beginLegacyConversion()
        guard case .summary(let second) = model.legacyConversion else { return XCTFail("no plan") }
        XCTAssertEqual(first, second)
        XCTAssertEqual(model.conversionIncomeCategoryID, "chosen",
                       "a rejected re-entry must not clear a choice already made")
    }

    /// The confirm button is refused until every direction the execution set contains has a
    /// category, which is also the runner's own rule.
    func testW14bTheConfirmButtonWaitsForEveryDirectionsCategory() async throws {
        let model = try await bootedModel(withLegacyRows: true)
        model.beginLegacyConversion()
        XCTAssertFalse(model.legacyConversionCanStart)
        model.conversionIncomeCategoryID = "cat-income"
        XCTAssertFalse(model.legacyConversionCanStart, "the plan also carries a purchase")
        model.conversionExpenseCategoryID = "cat-expense"
        XCTAssertTrue(model.legacyConversionCanStart)
        // Confirming with no retained authorization must refuse rather than open anything.
        model.storeOpenAuthorization = nil
        model.confirmLegacyConversion()
        XCTAssertEqual(model.legacyConversion, .failed(.internalFailure))
    }

    /// A `createFresh` authorization can only ever confirm into a `createFresh` plan, which
    /// this feature must never take. It is refused before any task starts.
    func testW14cACreateFreshAuthorizationNeverStartsAConversion() async throws {
        let model = try await bootedModel(withLegacyRows: true)
        model.beginLegacyConversion()
        model.conversionIncomeCategoryID = "cat-income"
        model.conversionExpenseCategoryID = "cat-expense"
        model.storeOpenAuthorization = .createFreshExpectedAbsent
        XCTAssertFalse(StoreOpenAuthorization.createFreshExpectedAbsent.authorizesExistingLedger)
        model.confirmLegacyConversion()
        XCTAssertEqual(model.legacyConversion, .failed(.internalFailure))
        XCTAssertTrue(StoreOpenAuthorization.openExistingPlain.authorizesExistingLedger)
        XCTAssertTrue(StoreOpenAuthorization
            .openExistingCompleted(CompletionEvidence(record: try Self.someRecord()))
            .authorizesExistingLedger)
    }

    // ==========================================================================================
    // MARK: - W15/W16 — failures reach the screen as copy, never as the runner's own words
    // ==========================================================================================

    /// Every case of the enum maps to a `legacy.convert.failed.*` key that really exists in all
    /// six languages, and the twelve cases cover thirteen distinct sentences (only
    /// `categoryRequired` splits by direction).
    func testW15EveryFailureCaseMapsToALandedKey() throws {
        let sale = LegacyRowIdentity(table: .sales, legacyID: "s-1")
        let failures: [LegacyConversionFailure] = [
            .skippedIdentityNotConvertible(sale),
            .categoryRequired(.income),
            .categoryRequired(.expense),
            .categoryNotFound(id: "cat-1"),
            .categoryWrongType(id: "cat-1", expected: .income, actual: .expense),
            .categoryWrongLocale(id: "cat-1", expected: "CN", actual: "US"),
            .ledgerChanged,
            .rowVanished(sale),
            .rowNoLongerConvertible(sale, [.dateMissing]),
            .writeSetMismatch("owed 2 got 1"),
            .backupFailed("no such directory"),
            .backupNotValid("missing sololedger.db"),
            .busy("database is locked (code 5)"),
        ]
        var keys: Set<String> = []
        for failure in failures {
            let copy = LegacyConversionFailureMap.copy(for: failure)
            XCTAssertTrue(copy.messageKey.hasPrefix("legacy.convert.failed."), copy.messageKey)
            keys.insert(copy.messageKey)
            for language in Self.languages {
                let rendered = Localizer(language: language).t(copy.messageKey)
                XCTAssertNotEqual(rendered, copy.messageKey, "\(language)/\(copy.messageKey) is raw")
                XCTAssertFalse(rendered.isEmpty)
            }
        }
        // Thirteen sentences for thirteen constructions: the two internal failures share one.
        XCTAssertEqual(keys.count, 12, "\(keys.sorted())")
        XCTAssertEqual(LegacyConversionFailureMap.copy(for: .skippedIdentityNotConvertible(sale)),
                       .internalFailure)
        XCTAssertEqual(LegacyConversionFailureMap.copy(for: .writeSetMismatch("x")).messageKey,
                       "legacy.convert.failed.internal")
    }

    /// The retry note promises a bundle is still on disk. It is shown for exactly the failures
    /// that can be reached AFTER the backup is written — sending the user to look for a folder
    /// that was never created would be its own small lie.
    func testW15bTheRetryNoteFollowsWhetherABundleCanExist() {
        let sale = LegacyRowIdentity(table: .sales, legacyID: "s-1")
        let beforeAnyBundle: [LegacyConversionFailure] = [
            .skippedIdentityNotConvertible(sale), .categoryRequired(.income),
            .categoryRequired(.expense), .categoryNotFound(id: "c"),
            .categoryWrongType(id: "c", expected: .income, actual: .expense),
            .categoryWrongLocale(id: "c", expected: "CN", actual: "US"),
            .backupFailed("could not write"),
        ]
        for failure in beforeAnyBundle {
            XCTAssertFalse(LegacyConversionFailureMap.copy(for: failure).showsRetryNote,
                           "\(failure) cannot have left a bundle behind")
        }
        let afterABundleMayExist: [LegacyConversionFailure] = [
            .ledgerChanged, .rowVanished(sale), .rowNoLongerConvertible(sale, [.dateMissing]),
            .backupNotValid("unreadable"), .busy("locked (code 5)"), .writeSetMismatch("x"),
        ]
        for failure in afterABundleMayExist {
            XCTAssertTrue(LegacyConversionFailureMap.copy(for: failure).showsRetryNote,
                          "\(failure) may have left a bundle behind")
        }
    }

    /// The open chain's three outcome classes, mapped by the adjudicated rule: an identity
    /// finding means the file is not the one that was authorized, which to the user is the
    /// ledger having changed; everything else is internal.
    func testW15cTheHardenedOpenRefusalsMapToTheAdjudicatedKeys() {
        for violation in [IdentityViolation.moved, .vanished, .parentIdentityMismatch,
                          .fingerprintMismatch, .zeroSizeActiveLeaf,
                          .unsupportedSymlinkedActivePath] {
            XCTAssertEqual(LegacyConversionFailureMap.copy(forOpen: .identity(violation)),
                           .ledgerChanged, "\(violation)")
        }
        for other: HardenedOpenError in [.hasMovedUnavailable, .hasMovedMisuse,
                                         .hasMovedFailed(fileControlRC: 5, systemErrno: 2),
                                         .sqlite(primary: 14, extended: 14, systemErrno: 2),
                                         .freshCollision,
                                         .reservationFailed(step: .openExcl, errno: 17)] {
            XCTAssertEqual(LegacyConversionFailureMap.copy(forOpen: other), .internalFailure)
        }
        XCTAssertEqual(LegacyConversionFailureCopy.ledgerChanged.messageKey,
                       "legacy.convert.failed.ledgerChanged")
        XCTAssertFalse(LegacyConversionFailureCopy.ledgerChanged.showsRetryNote,
                       "the store is not even open, so no bundle can exist")
    }

    /// The composed failure page holds a key, a title and possibly the retry note — and nothing
    /// that could carry a description, an identity, an issue rawValue or a SQLite message. The
    /// strongest form of this is structural: `LegacyConversionFailureCopy` has nowhere to put
    /// one, and the failure itself never crosses back from the background thread.
    func testW16TheFailurePageCarriesNoMachineText() throws {
        let sale = LegacyRowIdentity(table: .sales, legacyID: "s-1")
        let leaky: [LegacyConversionFailure] = [
            .rowNoLongerConvertible(sale, [.dateMissing, .taxRateNotANumber]),
            .busy("database is locked (code 5)"),
            .categoryNotFound(id: "cat-secret"),
            .writeSetMismatch("converted [sales:s-1] but owed [sales:s-2]"),
        ]
        for failure in leaky {
            let page = LegacyConversionComposition.compose(
                .failed(LegacyConversionFailureMap.copy(for: failure)))
            let keys = try XCTUnwrap(page.failedKeys)
            for language in Self.languages {
                let rendered = keys.map { Localizer(language: language).t($0) }.joined(separator: "\n")
                XCTAssertFalse(rendered.contains(failure.description),
                               "\(language): the page renders the failure's own description")
                XCTAssertFalse(rendered.contains(sale.description),
                               "\(language): the page renders a row identity")
                XCTAssertFalse(rendered.contains("cat-secret"))
                XCTAssertFalse(rendered.contains("(code 5)"))
                XCTAssertFalse(rendered.contains("sales:"))
                for issue in LegacyRowIssue.allCases {
                    XCTAssertFalse(rendered.contains(issue.rawValue), issue.rawValue)
                }
            }
        }
    }

    // ==========================================================================================
    // MARK: - W17/W18 — interpolation
    // ==========================================================================================

    /// The status disclosure fills its three tokens from `invoice.issued` / `.pending` / `.na`.
    /// Not a style preference: the zh label for the first is a `filingWords` pattern whose only
    /// sanction is bound to `invoice.issued` by triple, so writing it into any other string
    /// re-opens the violation the placeholder shape was chosen to avoid.
    func testW17TheStatusDisclosureIsFilledFromTheInvoiceStatusKeys() throws {
        for language in Self.languages {
            let localizer = Localizer(language: language)
            let labels = ["invoice.issued", "invoice.pending", "invoice.na"].map { localizer.t($0) }
            let rendered = localizer.t("legacy.convert.consequence.statuses",
                                       ["issued": labels[0], "pending": labels[1], "na": labels[2]])
            for label in labels {
                XCTAssertTrue(rendered.contains(label), "\(language): lost the \(label) label")
            }
            XCTAssertFalse(rendered.contains("{") || rendered.contains("}"),
                           "\(language): a token survived")
        }
        // The view must not hard-code the labels. Whole-literal scan of the file that renders it.
        let view = try Self.appSource("Views/LegacyConversionView.swift")
        for key in ["invoice.issued", "invoice.pending", "invoice.na"] {
            XCTAssertTrue(view.contains("\"\(key)\""), "the disclosure must read \(key)")
        }
        let zhIssued = Localizer(language: "zh-Hans").t("invoice.issued")
        XCTAssertTrue(zhIssued.contains("已开票"))
        XCTAssertFalse(view.contains(zhIssued),
                       "the banned label must stay in the key that is sanctioned for it")
    }

    /// Zero, one and many all read as ordinary prose, in all six languages, for every key the
    /// wizard interpolates a count into.
    func testW18CountsRenderAtZeroOneAndMany() {
        let counted = ["legacy.convert.grade.convertible", "legacy.convert.grade.needsAdjudication",
                       "legacy.convert.grade.unconvertible", "legacy.convert.consequence.lineItems",
                       "legacy.convert.done.message", "legacy.convert.done.skipped",
                       "legacy.convert.year.existing"]
        for language in Self.languages {
            let localizer = Localizer(language: language)
            for key in counted {
                for count in ["0", "1", "42"] {
                    let rendered = localizer.t(key, ["count": count, "year": "2024"])
                    XCTAssertTrue(rendered.contains(count), "\(language)/\(key) dropped \(count)")
                    XCTAssertFalse(rendered.contains("{") || rendered.contains("}"),
                                   "\(language)/\(key) left a brace: \(rendered)")
                }
            }
        }
    }

    /// A year either already holds transactions or does not — never both — and the
    /// second-currency warning is additional to whichever applies.
    func testW18bTheYearLinesAreExclusiveExceptTheCurrencyWarning() {
        let outlooks = [LegacyYearOutlook(year: "2023", existingTransactionCount: 4,
                                          existingCurrencies: ["CNY"], wouldHoldASecondCurrency: false),
                        LegacyYearOutlook(year: "2024", existingTransactionCount: 0,
                                          existingCurrencies: [], wouldHoldASecondCurrency: false),
                        LegacyYearOutlook(year: "2025", existingTransactionCount: 2,
                                          existingCurrencies: ["CNY", "USD"], wouldHoldASecondCurrency: true)]
        let keys = LegacyConversionComposition.yearKeys(
            for: plan(rows: [row(.sales, "s1", "2024-01-01")], outlook: outlooks))
        XCTAssertEqual(keys.first, "legacy.convert.year.title")
        XCTAssertEqual(keys.last, "legacy.convert.year.upperBound")
        XCTAssertEqual(keys.filter { $0 == "legacy.convert.year.existing" }.count, 2)
        XCTAssertEqual(keys.filter { $0 == "legacy.convert.year.noneYet" }.count, 1)
        XCTAssertEqual(keys.filter { $0 == "legacy.convert.year.secondCurrency" }.count, 1)
        XCTAssertTrue(LegacyConversionComposition
            .yearKeys(for: plan(rows: [row(.sales, "s1", "2024-01-01")])).isEmpty)
    }

    // ==========================================================================================
    // MARK: - W19 — a retry never overwrites the bundle it is retrying past
    // ==========================================================================================

    /// `BackupExport.writeBundle` refuses an existing destination, and the timestamp is only
    /// second-resolution, so two attempts inside one second would collide. The suffix is what
    /// keeps `legacy.convert.failed.retryNote`'s promise true at every retry interval.
    func testW19EachRetryTakesAFreshDestinationAndKeepsTheOldOne() {
        let root = tempURL("Backups")
        var taken: Set<String> = []
        let exists: (URL) -> Bool = { taken.contains($0.lastPathComponent) }

        let first = AppModel.conversionBackupDestination(in: root, timestamp: "2026-08-03-101500",
                                                         exists: exists)
        XCTAssertEqual(first.lastPathComponent, "pre-convert-2026-08-03-101500")
        taken.insert(first.lastPathComponent)

        let second = AppModel.conversionBackupDestination(in: root, timestamp: "2026-08-03-101500",
                                                          exists: exists)
        XCTAssertNotEqual(second, first, "a retry must not be handed the directory it failed on")
        XCTAssertEqual(second.lastPathComponent, "pre-convert-2026-08-03-101500-2")
        taken.insert(second.lastPathComponent)

        let third = AppModel.conversionBackupDestination(in: root, timestamp: "2026-08-03-101500",
                                                         exists: exists)
        XCTAssertEqual(third.lastPathComponent, "pre-convert-2026-08-03-101500-3")
        // The earlier ones are untouched: this function only ever NAMES a directory.
        XCTAssertEqual(taken, ["pre-convert-2026-08-03-101500", "pre-convert-2026-08-03-101500-2"])
        // A different second gets the plain name again.
        XCTAssertEqual(AppModel.conversionBackupDestination(in: root, timestamp: "2026-08-03-101501",
                                                            exists: exists).lastPathComponent,
                       "pre-convert-2026-08-03-101501")
    }

    // ==========================================================================================
    // MARK: - W20 — the composition is total, and every state draws something
    // ==========================================================================================

    /// Every key the wizard can draw is placed, and every placement is drawn by some state.
    /// A key placed but never composed is copy the user can never see; a key composed but not
    /// placed would resolve to a raw string on screen.
    func testW20EveryPlacedKeyIsDrawnBySomeState() {
        let full = plan(rows: LegacyRowIssue.allCases.map {
                            row(.sales, "s-\($0.rawValue)", "2024-01-01", [$0])
                        } + [row(.sales, "ok", "2024-01-01"), row(.purchases, "p", "2024-01-01"),
                             row(.purchases, nil, nil, [.idNotReadableAsText, .dateMissing])],
                        lineItems: 3,
                        outlook: [LegacyYearOutlook(year: "2024", existingTransactionCount: 1,
                                                    existingCurrencies: ["CNY", "USD"],
                                                    wouldHoldASecondCurrency: true),
                                  LegacyYearOutlook(year: "2025", existingTransactionCount: 0,
                                                    existingCurrencies: [],
                                                    wouldHoldASecondCurrency: false)])
        var drawn: Set<String> = LegacyConversionComposition.entryKeys.reduce(into: []) { $0.insert($1) }
        drawn.formUnion(LegacyConversionComposition.compose(.summary(full)).allKeys)
        drawn.formUnion(LegacyConversionComposition.compose(.running(full)).allKeys)
        drawn.formUnion(LegacyConversionComposition
            .compose(.completed(convertedCount: 2, notConvertedCount: 1, backupPath: "/tmp/b")).allKeys)
        // Nothing-to-convert is its own render.
        drawn.formUnion(LegacyConversionComposition
            .compose(.summary(plan(rows: [row(.sales, "s", nil, [.dateMissing])]))).allKeys)
        for blocker: LegacyConversionBlocker in [.accountingLocaleNotConfigured,
                                                 .accountingLocaleInvalid(storedText: "x"),
                                                 .currencyNotConfigured,
                                                 .currencyInvalid(storedText: "y"),
                                                 .currencyNotStorableVerbatim(currency: "LONGCODE1")] {
            drawn.formUnion(LegacyConversionComposition.compose(.blocked(blocker)).allKeys)
        }
        let sale = LegacyRowIdentity(table: .sales, legacyID: "s")
        for failure: LegacyConversionFailure in [.skippedIdentityNotConvertible(sale),
                                                 .categoryRequired(.income), .categoryRequired(.expense),
                                                 .categoryNotFound(id: "c"),
                                                 .categoryWrongType(id: "c", expected: .income, actual: .expense),
                                                 .categoryWrongLocale(id: "c", expected: "CN", actual: "US"),
                                                 .ledgerChanged, .rowVanished(sale),
                                                 .rowNoLongerConvertible(sale, []),
                                                 .backupFailed("x"), .backupNotValid("y"),
                                                 .busy("z"), .writeSetMismatch("w")] {
            drawn.formUnion(LegacyConversionComposition
                .compose(.failed(LegacyConversionFailureMap.copy(for: failure))).allKeys)
        }

        let placed = Set(LegacyConversionComposition.placement.keys)
        XCTAssertEqual(placed.count, 97)
        XCTAssertEqual(drawn, placed, """
            placed but never drawn (copy nobody can reach): \(placed.subtracting(drawn).sorted())
            drawn but not placed (a raw key on screen): \(drawn.subtracting(placed).sorted())
            """)
        XCTAssertTrue(LegacyConversionComposition.compose(.idle).allKeys.isEmpty)
    }

    /// The running page drops the opening paragraph. `legacy.convert.intro` ends by promising
    /// that nothing is written until you confirm; keeping it on the screen that writes would be
    /// describing the previous page.
    func testW20bTheIntroIsGoneOnceTheWriteHasStarted() {
        let some = plan(rows: [row(.sales, "s", "2024-01-01")])
        XCTAssertTrue(LegacyConversionComposition.compose(.summary(some))
            .frameKeys.contains("legacy.convert.intro"))
        XCTAssertTrue(LegacyConversionComposition.compose(.blocked(.currencyNotConfigured))
            .frameKeys.contains("legacy.convert.intro"))
        for state: LegacyConversionState in [
            .running(some),
            .completed(convertedCount: 1, notConvertedCount: 0, backupPath: "/tmp/x"),
            .failed(.ledgerChanged),
        ] {
            XCTAssertFalse(LegacyConversionComposition.compose(state)
                .frameKeys.contains("legacy.convert.intro"), "\(state)")
            XCTAssertTrue(LegacyConversionComposition.compose(state)
                .frameKeys.contains("legacy.convert.title"))
        }
        XCTAssertTrue(LegacyConversionComposition.compose(.running(some)).isRunningState)
    }

    /// Success lands as a completion page AND refreshes every read model the conversion
    /// invalidated: the transaction list, the legacy counts that drive the entry point, and the
    /// report — whose figures for the affected years are now computed from `transactions`.
    ///
    /// The report is CLEARED rather than rebuilt. Rebuilding would be a second decision taken
    /// on the user's behalf, and the year in the picker need not be one this conversion touched.
    func testW20dSuccessLandsAndRefreshesTheAffectedReadModels() async throws {
        let model = try await bootedModel(withLegacyRows: true)
        model.beginLegacyConversion()
        guard case .summary(let plan) = model.legacyConversion else { return XCTFail("no plan") }
        XCTAssertEqual(plan.rows.count, 2)
        XCTAssertTrue(model.legacyLedger.hasUnconverted)

        model.buildReport()   // put something on the report page first
        XCTAssertNotEqual(model.reportState, .notRequested)

        // What the background worker did on ITS connection: two transactions written and both
        // legacy rows recorded as converted. The main-actor model still holds the
        // pre-conversion picture until it is told to reload — which is the whole point of this
        // test, and what a dropped `reloadAll()` would leave standing.
        let store = try XCTUnwrap(model.store)
        try store.create(Transaction(id: "t-s1", type: .income, date: "2024-03-10",
                                     amount: 9040, currency: "CNY"))
        try store.create(Transaction(id: "t-p1", type: .expense, date: "2024-03-01",
                                     amount: 6780, currency: "CNY"))
        for (table, legacyID, newID) in [("sales", "s1", "t-s1"), ("purchases", "p1", "t-p1")] {
            try store.db.run("""
                INSERT INTO legacy_migrations (legacy_table, legacy_id, new_id) VALUES (?, ?, ?)
                """, [.text(table), .text(legacyID), .text(newID)])
        }
        XCTAssertTrue(model.legacyLedger.hasUnconverted, "the model has not been told yet")
        XCTAssertTrue(model.transactions.isEmpty)

        model.finishLegacyConversion(.converted(convertedCount: 2, backupPath: "/tmp/pre-convert-x"),
                                     plannedRowCount: plan.rows.count)

        XCTAssertEqual(model.legacyConversion,
                       .completed(convertedCount: 2, notConvertedCount: 0,
                                  backupPath: "/tmp/pre-convert-x"))
        // The transaction list is reloaded…
        XCTAssertEqual(model.transactions.count, 2, "the transaction list was not reloaded")
        XCTAssertEqual(model.summary.incomeCount, 1)
        // …and so is the legacy count, which is what makes the entry point disappear.
        XCTAssertFalse(model.legacyLedger.hasUnconverted,
                       "the legacy summary was not reloaded, so the entry point would still be offered")
        XCTAssertFalse(LegacyConversionComposition.notice(model.legacyLedger).offersConversion)
        XCTAssertEqual(model.reportState, .notRequested,
                       "a report built before the conversion describes a ledger that no longer exists")
        XCTAssertNil(model.actionError, "the refresh must not report a failure of its own")
    }

    /// The count on the completion page is what was left behind, never a negative number, and
    /// a failure lands as a failure without touching the report or the counts.
    func testW20eTheSkippedCountIsTheRemainderAndFailuresRefreshNothing() async throws {
        let model = try await bootedModel(withLegacyRows: true)
        model.beginLegacyConversion()
        model.finishLegacyConversion(.converted(convertedCount: 1, backupPath: nil),
                                     plannedRowCount: 5)
        XCTAssertEqual(model.legacyConversion,
                       .completed(convertedCount: 1, notConvertedCount: 4, backupPath: nil))
        // A count that cannot go negative even if the two numbers ever disagreed.
        model.finishLegacyConversion(.converted(convertedCount: 9, backupPath: nil),
                                     plannedRowCount: 2)
        XCTAssertEqual(model.legacyConversion,
                       .completed(convertedCount: 9, notConvertedCount: 0, backupPath: nil))

        model.buildReport()
        let before = model.reportState
        model.finishLegacyConversion(.failed(.ledgerChanged), plannedRowCount: 2)
        XCTAssertEqual(model.legacyConversion, .failed(.ledgerChanged))
        XCTAssertEqual(model.reportState, before,
                       "a refused conversion changed nothing, so nothing needs refreshing")
    }

    /// The backup path line is drawn when there is a path and omitted when there is not.
    func testW20cTheBackupPathLineFollowsTheReport() {
        let withPath = LegacyConversionComposition
            .compose(.completed(convertedCount: 1, notConvertedCount: 0, backupPath: "/tmp/b"))
        XCTAssertTrue(try! XCTUnwrap(withPath.doneKeys).contains("legacy.convert.done.backup"))
        let without = LegacyConversionComposition
            .compose(.completed(convertedCount: 0, notConvertedCount: 0, backupPath: nil))
        XCTAssertFalse(try! XCTUnwrap(without.doneKeys).contains("legacy.convert.done.backup"))
    }

    // ==========================================================================================
    // MARK: - W21…W26 — the paths the wizard may not take
    // ==========================================================================================

    /// Source scanning is the SECOND line of defence, and it is the weaker one — it catches a
    /// forbidden call that was written, not one that could be. The primary controls are
    /// structural: `ActiveOpenEvidence`'s initialiser and all three of its fields are
    /// `internal` to Core, so the App target cannot construct one at all; and
    /// `authorizesExistingLedger` refuses the only authorization that could confirm into a
    /// `createFresh` plan. Recording the division so a green run is not read as more than it is.
    func testW21ThroughW24TheForbiddenOpenPathsAppearNowhereInTheAppTarget() throws {
        let sources = try Self.appSources()
        XCTAssertGreaterThan(sources.count, 10)
        // A plain existing open is forbidden EVERYWHERE. `StoreOpenIntent` is how one would be
        // asked for, and the App has never needed either since the hardened path landed.
        for forbidden in ["existingOnly", "StoreOpenIntent"] {
            XCTAssertTrue(Self.mentions(of: forbidden, in: sources).isEmpty,
                          "\(forbidden) is named at \(Self.mentions(of: forbidden, in: sources))")
        }
        // The COORDINATOR's two resolution entry points stay where they were — in the one
        // factory that maps a `BootIntent` — and the wizard may not reach either. `bootResolve`
        // is the specific hazard: its `.pending` arm performs the resume writes before it
        // returns, so a caller inspecting its result is looking at a ledger already changed.
        // (`confirmCreateFresh` and `runImport` are also `BootIntent` case names, so they
        // legitimately appear in the runner protocol and the source-choice screen; the
        // wizard-scoped ban below is what covers them.)
        for bootOnly in ["bootResolve", "resolveSelectedImport"] {
            XCTAssertEqual(Self.mentions(of: bootOnly, in: sources),
                           ["Sources/SoloLedger/App/AppModel.swift"],
                           "\(bootOnly) must stay inside the boot-chain factory")
        }
        // The wizard additionally may not touch the createFresh open or fabricate evidence.
        // `ActiveOpenEvidence`'s initialiser and all three fields are `internal` to Core, so the
        // construction below cannot compile from here at all — the scan is the belt to that
        // structural brace, and it is the weaker of the two.
        let wizardFiles = sources.filter { $0.path.contains("LegacyConversion") }
        XCTAssertEqual(wizardFiles.count, 3, "the three wizard files must resolve")
        for forbidden in ["createFreshReservedHardened", "ActiveOpenEvidence(",
                          "bootResolve", "resolveSelectedImport", "confirmCreateFresh",
                          "runImport", "LedgerStore("] {
            XCTAssertTrue(Self.mentions(of: forbidden, in: wizardFiles).isEmpty,
                          "the wizard names \(forbidden)")
        }
    }

    /// The hardened open has two call sites, and both are accounted for: the boot chain's
    /// Phase-B dispatch, which has always been there, and the wizard's background worker, which
    /// is what 2a-4 adds. Anything else is a third way into the active ledger.
    ///
    /// `.reResolve` is TERMINAL in the worker — re-running `bootResolve` is forbidden because
    /// its `.pending` arm performs the resume writes before it returns, so a "retry" would have
    /// written to the ledger by the time its result was inspected.
    func testW23TheHardenedOpenHasTwoAccountedCallSitesAndReResolveIsTerminal() throws {
        let sources = try Self.appSources()
        XCTAssertEqual(Self.mentions(of: "openActiveExistingHardened", in: sources),
                       ["Sources/SoloLedger/App/AppModel.swift",              // boot: openStoreForPlan
                        "Sources/SoloLedger/App/LegacyConversionState.swift"], // wizard: the worker
                       "the hardened open gained or lost a call site")
        XCTAssertEqual(Self.mentions(of: "confirmOpenAuthorization", in: sources),
                       ["Sources/SoloLedger/App/AppModel.swift",              // boot: the confirm closure
                        "Sources/SoloLedger/App/LegacyConversionState.swift"])
        // One occurrence each inside the wizard: a single confirm, feeding a single open.
        let worker = try Self.appSource("App/LegacyConversionState.swift")
        XCTAssertEqual(Self.occurrences(of: "openActiveExistingHardened", inCodeOf: worker), 1)
        XCTAssertEqual(Self.occurrences(of: "confirmOpenAuthorization", inCodeOf: worker), 1)
        // …and the boot path still has exactly its own one, so neither borrowed the other's.
        let model = try Self.appSource("App/AppModel.swift")
        XCTAssertEqual(Self.occurrences(of: "openActiveExistingHardened", inCodeOf: model), 1)

        // Terminal, not a loop: the `.reResolve` arm returns, and the worker's CODE holds no
        // loop or recursion that could bring it back round. Comments are not code — this file's
        // own prose says "while the database is being written".
        XCTAssertEqual(Self.occurrences(of: "case .reResolve:", inCodeOf: worker), 1)
        for loop in ["while ", "repeat {", "for ("] {
            XCTAssertEqual(Self.occurrences(of: loop, inCodeOf: worker), 0,
                           "the worker must not loop over the confirm (\(loop))")
        }
        XCTAssertEqual(Self.occurrences(of: "LegacyConversionWorker.run", inCodeOf: worker), 0,
                       "the worker must not call itself")
        XCTAssertEqual(LegacyConversionFailureCopy.ledgerChanged.messageKey,
                       "legacy.convert.failed.ledgerChanged")
    }

    /// The wizard is CONSTRUCTED once, in `RootView`, and the two entry points are the only
    /// things that open it.
    func testW26TheWizardHasOneMountAndTwoEntryPoints() throws {
        let sources = try Self.appSources()
        XCTAssertEqual(Self.mentions(of: "LegacyConversionView(", in: sources),
                       ["Sources/SoloLedger/Views/RootView.swift"],
                       "the sheet must be constructed in exactly one place")
        XCTAssertEqual(Self.mentions(of: "showingLegacyConversion", in: sources),
                       ["Sources/SoloLedger/App/AppModel.swift",
                        "Sources/SoloLedger/Views/RootView.swift"],
                       "only the model and its single mount may drive the sheet's presentation")
        XCTAssertEqual(Self.mentions(of: "beginLegacyConversion", in: sources),
                       ["Sources/SoloLedger/App/AppModel.swift",
                        "Sources/SoloLedger/Views/Components.swift"],
                       "the wizard must be opened only from the two entry points")
        XCTAssertEqual(Self.mentions(of: "confirmLegacyConversion", in: sources),
                       ["Sources/SoloLedger/App/AppModel.swift",
                        "Sources/SoloLedger/Views/LegacyConversionView.swift"])
        // Both entry points live in the one file that draws the notice and the banner.
        let components = try Self.appSource("Views/Components.swift")
        XCTAssertEqual(Self.occurrences(of: "model.beginLegacyConversion()", inCodeOf: components), 2,
                       "one call for the notice, one for the banner")

        // The scanner is proved on synthetic text: "no hits" and "the scanner is broken" look
        // the same otherwise.
        XCTAssertFalse(Self.mentions(of: "beginLegacyConversion",
                                     in: [("X.swift", "model.beginLegacyConversion()")]).isEmpty)
        XCTAssertTrue(Self.mentions(of: "beginLegacyConversion",
                                    in: [("X.swift", "  // beginLegacyConversion is 2a-4")]).isEmpty)
        XCTAssertTrue(Self.mentions(of: "LegacyConversionView(",
                                    in: [("X.swift", "LegacyConversionViewModel()")]).isEmpty,
                      "whole-identifier matching only")
    }

    // ==========================================================================================
    // MARK: - W27 — the sheet has exactly one way out, and it is the footer
    // ==========================================================================================

    /// A system dismissal writes `false` straight into `$model.showingLegacyConversion` without
    /// going through `dismissLegacyConversion()`. The sheet would disappear while the model
    /// stayed in `.blocked` / `.summary` / `.completed` / `.failed` with the category choices
    /// still set — and the next press of the entry point would hit `guard case .idle` and do
    /// nothing at all, which reads as a button that has silently stopped working.
    ///
    /// So the modifier is UNCONDITIONAL. A `.running`-only version would close the write window
    /// and leave the rest of that class open, `.completed` most expensively of all: the
    /// pre-conversion backup path is on that page and nowhere else.
    func testW27TheWizardSheetDisablesInteractiveDismissalUnconditionally() throws {
        let root = try Self.appSource("Views/RootView.swift")
        let closure = try Self.sheetClosure(binding: "showingLegacyConversion", in: root)
        XCTAssertTrue(Self.occurrences(of: "LegacyConversionView()", inCodeOf: closure) == 1,
                      "the wizard sheet closure must build the wizard")

        let arguments = Self.callArguments(to: "interactiveDismissDisabled", inCodeOf: closure)
        XCTAssertEqual(arguments, [""], """
            the wizard sheet must carry exactly one UNCONDITIONAL interactiveDismissDisabled().
            found: \(arguments)
            """)
        // File-wide, so the modifier cannot be satisfied by one somewhere else on the view tree.
        XCTAssertEqual(Self.occurrences(of: "interactiveDismissDisabled", inCodeOf: root), 1)

        // The transaction editor is deliberately NOT disabled: it is an ordinary form with no
        // state left behind, and taking Escape away from it would be a regression of its own.
        let editor = try Self.sheetClosure(binding: "showingEditor", in: root)
        XCTAssertEqual(Self.occurrences(of: "interactiveDismissDisabled", inCodeOf: editor), 0)
    }

    /// The guard above asserts the SHAPE of a call, so its own parser is proved against the
    /// three ways this modifier gets weakened — removed, made conditional, or passed `false`.
    /// Without this, "the assertion passes" and "the parser cannot see the argument" look the
    /// same.
    func testW27bTheDismissGuardRejectsEveryWeakenedForm() throws {
        func closure(_ body: String) throws -> String {
            try Self.sheetClosure(binding: "showingLegacyConversion", in: """
                struct R: View {
                    var body: some View {
                        content
                            .sheet(isPresented: $model.showingLegacyConversion) {
                \(body)
                            }
                    }
                }
                """)
        }
        // The shipping shape.
        XCTAssertEqual(
            Self.callArguments(to: "interactiveDismissDisabled",
                               inCodeOf: try closure("            LegacyConversionView()\n                .interactiveDismissDisabled()")),
            [""])
        // Removed entirely.
        XCTAssertEqual(
            Self.callArguments(to: "interactiveDismissDisabled",
                               inCodeOf: try closure("            LegacyConversionView()")),
            [])
        // Made conditional on the run.
        XCTAssertEqual(
            Self.callArguments(to: "interactiveDismissDisabled",
                               inCodeOf: try closure("            LegacyConversionView()\n                .interactiveDismissDisabled(model.legacyConversion.isRunning)")),
            ["model.legacyConversion.isRunning"])
        // Turned off outright.
        XCTAssertEqual(
            Self.callArguments(to: "interactiveDismissDisabled",
                               inCodeOf: try closure("            LegacyConversionView()\n                .interactiveDismissDisabled(false)")),
            ["false"])
        // Commented out is not a call.
        XCTAssertEqual(
            Self.callArguments(to: "interactiveDismissDisabled",
                               inCodeOf: try closure("            LegacyConversionView()\n                // .interactiveDismissDisabled()")),
            [])
    }

    /// Taking the system's exits away is only safe because the app's own are still there: one
    /// per state that can be closed, and none for the one that cannot.
    func testW27cTheFooterButtonsRemainTheWayOut() throws {
        let view = try Self.appSource("Views/LegacyConversionView.swift")
        XCTAssertEqual(Self.occurrences(of: "model.dismissLegacyConversion()", inCodeOf: view), 3,
                       "one Cancel for .blocked, one for .summary, one OK for .completed/.failed")
        // `.running` shares its footer arm with `.idle`, and that arm draws nothing — the write
        // is in flight and there is nothing a dismissal could mean.
        XCTAssertEqual(Self.occurrences(of: "case .idle, .running:", inCodeOf: view), 1)
        XCTAssertTrue(LegacyConversionState.running(plan(rows: [row(.sales, "s", "2024-01-01")]))
            .isRunning)
        // Every other state IS closable, which is why each of them has a button.
        for state: LegacyConversionState in [.idle, .blocked(.currencyNotConfigured),
                                             .summary(plan(rows: [row(.sales, "s", "2024-01-01")])),
                                             .completed(convertedCount: 1, notConvertedCount: 0,
                                                        backupPath: nil),
                                             .failed(.ledgerChanged)] {
            XCTAssertFalse(state.isRunning, "\(state) has a footer button and must be closable")
        }
    }

    // ==========================================================================================
    // MARK: - W28 — a restore may not start unless the wizard is idle
    // ==========================================================================================

    /// The predicate, over EVERY state the wizard can be in. Only `.idle` permits a restore.
    ///
    /// This is where `.running` is covered. Reaching `.running` at runtime means calling
    /// `confirmLegacyConversion`, which resolves the app's REAL `AppPaths` and starts a worker
    /// against the production container — so the end-to-end refusals below drive the four
    /// non-idle states an isolated test can honestly reach, and the binding to `.running` is
    /// made here and pinned structurally by
    /// ``testW28bTheRestoreGuardIsTheFirstStatementAndReadsTheOnePredicate``.
    func testW28OnlyIdlePermitsADestructiveRestore() {
        let some = plan(rows: [row(.sales, "s", "2024-01-01")])
        let table: [(LegacyConversionState, Bool)] = [
            (.idle, true),
            (.blocked(.currencyNotConfigured), false),
            (.summary(some), false),
            (.running(some), false),
            (.completed(convertedCount: 1, notConvertedCount: 0, backupPath: "/tmp/b"), false),
            (.failed(.ledgerChanged), false),
        ]
        XCTAssertEqual(table.count, 6, "every case of LegacyConversionState must be decided")
        for (state, permitted) in table {
            XCTAssertEqual(state.permitsDestructiveRestore, permitted, "\(state)")
        }
        XCTAssertEqual(table.filter(\.1).count, 1, "exactly one state may restore")
    }

    /// The guard has to be the FIRST thing the destructive seam does, and it has to read the
    /// same predicate the Settings button reads. Both halves are structural because both are
    /// about ordering and identity, which no single call can demonstrate.
    func testW28bTheRestoreGuardIsTheFirstStatementAndReadsTheOnePredicate() throws {
        let model = try Self.appSource("App/AppModel.swift")
        let seam = try Self.functionBody(
            startingWith: "func restoreFromBackup(bundleURL: URL, config: MigrationCoordinator.Config,",
            in: model)
        let statements = Self.codeLines(of: seam)
        XCTAssertEqual(statements.first, "guard canRestoreFromBackup else {", """
            the interlock must precede every side effect of the restore. first statement: \
            \(statements.prefix(3))
            """)
        // Every side effect the authorisation names must come AFTER it.
        for effect in ["startAccessingSecurityScopedResource", "BackupRestore.validateBundle",
                       "BackupExport.writeBundle", "store.db.close()", "self.store = nil",
                       "ready = false", "BackupRestore.clearActiveSlot", "migrateFromUserDir"] {
            let at = try XCTUnwrap(statements.firstIndex { $0.contains(effect) },
                                   "\(effect) is no longer in the restore seam")
            XCTAssertGreaterThan(at, 0, "\(effect) runs before the interlock")
        }
        // The production wrapper is guarded too — it creates directories while resolving paths.
        let wrapper = try Self.functionBody(startingWith: "func restoreFromBackup(bundleURL: URL) {",
                                            in: model)
        XCTAssertEqual(Self.codeLines(of: wrapper).first, "guard canRestoreFromBackup else {")

        // One predicate, one definition, delegating to the pure state answer.
        XCTAssertEqual(Self.occurrences(of: "var canRestoreFromBackup: Bool", inCodeOf: model), 1)
        XCTAssertEqual(Self.occurrences(of: "legacyConversion.permitsDestructiveRestore",
                                        inCodeOf: model), 1)
        XCTAssertEqual(Self.occurrences(of: "canRestoreFromBackup", inCodeOf: model), 3,
                       "its one declaration and the two restore guards — no third reader, and "
                       + "no second definition to drift from it")
    }

    /// The Settings button follows the same predicate — and it is the SECOND line of defence,
    /// which is why the model guard above is asserted independently of it.
    func testW28cTheSettingsRestoreButtonFollowsTheSamePredicate() throws {
        let settings = try Self.appSource("Views/SettingsView.swift")
        let arguments = Self.callArguments(to: "disabled", inCodeOf: settings)
        XCTAssertTrue(arguments.contains("!model.canRestoreFromBackup"), """
            the restore button must be disabled by the one predicate. found: \(arguments)
            """)
        XCTAssertEqual(Self.occurrences(of: "!model.canRestoreFromBackup", inCodeOf: settings), 1)
        // It sits on the restore button, not on the export beside it.
        let restoreLine = try XCTUnwrap(Self.codeLines(of: settings).firstIndex {
            $0.contains("model.t(\"settings.restore\"), role: .destructive")
        })
        XCTAssertTrue(Self.codeLines(of: settings)[restoreLine + 1]
            .contains(".disabled(!model.canRestoreFromBackup)"),
                      "the disabled modifier must be attached to the restore button itself")
    }

    /// The other destructive recovery path — the legacy `DatabaseUpgrade` screen — is already
    /// unreachable during a conversion, and this records WHY rather than adding a second guard
    /// that would never fire. `legacyRecoveryAllowed` requires `store == nil && !ready`, and a
    /// conversion cannot start without a live, ready store.
    func testW28dTheLegacyRecoveryPathIsStructurallyUnreachableDuringAConversion() async throws {
        let model = try await bootedModel(withLegacyRows: true)
        XCTAssertTrue(model.ready)
        XCTAssertNotNil(model.store)
        XCTAssertFalse(model.legacyRecoveryAllowed,
                       "a ready ledger already refuses the DatabaseUpgrade recovery actions")
        model.beginLegacyConversion()
        guard case .summary = model.legacyConversion else { return XCTFail("no plan") }
        XCTAssertFalse(model.legacyRecoveryAllowed)
        XCTAssertFalse(model.canRestoreFromBackup)
    }

    // ==========================================================================================
    // MARK: - W29 — the refusal log names the state and nothing inside it
    // ==========================================================================================

    /// Six cases, six fixed labels, and no eighth answer.
    func testW29EveryStateMapsToItsOwnFixedLabel() {
        let some = plan(rows: [row(.sales, "s", "2024-01-01")])
        let table: [(LegacyConversionState, String)] = [
            (.idle, "idle"),
            (.blocked(.currencyNotConfigured), "blocked"),
            (.summary(some), "summary"),
            (.running(some), "running"),
            (.completed(convertedCount: 1, notConvertedCount: 0, backupPath: "/tmp/b"), "completed"),
            (.failed(.ledgerChanged), "failed"),
        ]
        XCTAssertEqual(table.count, 6, "every case of LegacyConversionState must have a label")
        for (state, label) in table {
            XCTAssertEqual(state.diagnosticLabel, label)
        }
        XCTAssertEqual(Set(table.map(\.1)),
                       ["idle", "blocked", "summary", "running", "completed", "failed"])
        XCTAssertEqual(Set(table.map(\.1)).count, 6, "two states share a label")
    }

    /// The payloads are the point, so every one of them is loaded with a sentinel a `grep` over
    /// a sysdiagnose would find, and the label is required to contain none of them.
    ///
    /// The last assertion is the anti-vacuity half: `String(describing:)` really does print the
    /// sentinels. Without it, "the label is clean" and "these payloads were never reachable"
    /// would look identical.
    func testW29bTheLabelCarriesNoPayloadWhileStringDescribingWould() {
        let sentinels = ["SENTINEL-STORED-BYTES", "SENTINEL-ROW-ID", "SENTINEL-DATE",
                         "SENTINEL-CURRENCY", "SENTINEL-BACKUP-PATH", "SENTINEL-FAILURE-KEY",
                         "SENTINEL-YEAR"]
        let loaded = LegacyConversionPlan(
            accountingLocale: .CN,
            currency: "SENTINEL-CURRENCY",
            rows: [LegacyConversionRow(table: .sales, id: "SENTINEL-ROW-ID",
                                       storedDate: "SENTINEL-DATE",
                                       issues: [.dateNotACalendarDay])],
            headersWithLineItems: 7,
            yearOutlook: [LegacyYearOutlook(year: "SENTINEL-YEAR", existingTransactionCount: 3,
                                            existingCurrencies: ["SENTINEL-CURRENCY"],
                                            wouldHoldASecondCurrency: true)])
        let states: [LegacyConversionState] = [
            .idle,
            .blocked(.accountingLocaleInvalid(storedText: "SENTINEL-STORED-BYTES")),
            .blocked(.currencyInvalid(storedText: "SENTINEL-STORED-BYTES")),
            .blocked(.currencyNotStorableVerbatim(currency: "SENTINEL-CURRENCY")),
            .summary(loaded),
            .running(loaded),
            .completed(convertedCount: 42, notConvertedCount: 7,
                       backupPath: "/Users/x/Backups/SENTINEL-BACKUP-PATH"),
            .failed(LegacyConversionFailureCopy(messageKey: "SENTINEL-FAILURE-KEY",
                                                showsRetryNote: true)),
        ]
        let allowed: Set<String> = ["idle", "blocked", "summary", "running", "completed", "failed"]
        for state in states {
            let label = state.diagnosticLabel
            XCTAssertTrue(allowed.contains(label), "\(label) is not one of the six fixed labels")
            for sentinel in sentinels {
                XCTAssertFalse(label.contains(sentinel), "the label leaked \(sentinel)")
            }
            // Nothing structural either: no separators a payload would have arrived through.
            for fragment in ["(", ")", "/", "\"", "sales", "purchases", "2024", "42"] {
                XCTAssertFalse(label.contains(fragment), "the label carries \(fragment)")
            }
        }

        // Anti-vacuity: the thing that was being logged really did carry all of it.
        let described = states.map { String(describing: $0) }.joined(separator: "\n")
        for sentinel in sentinels {
            XCTAssertTrue(described.contains(sentinel),
                          "String(describing:) no longer prints \(sentinel) — this guard is testing nothing")
        }
    }

    /// The narrowing has to be structural, not a habit: the diagnostics entry takes the STATE,
    /// so there is no argument a caller could build that carries a payload.
    func testW29cNothingInTheAppTargetLogsTheWholeState() throws {
        let sources = try Self.appSources()
        XCTAssertGreaterThan(sources.count, 10)
        for forbidden in ["String(describing: legacyConversion)",
                          "String(reflecting: legacyConversion)",
                          "Mirror(reflecting: legacyConversion)",
                          "\\(legacyConversion)",
                          "String(describing: state)"] {
            XCTAssertTrue(Self.mentions(of: forbidden, in: sources).isEmpty,
                          "\(forbidden) is named at \(Self.mentions(of: forbidden, in: sources))")
        }
        let model = try Self.appSource("App/AppModel.swift")
        // The entry point takes the state, and the only thing it interpolates is the label.
        XCTAssertEqual(
            Self.occurrences(of: "static func restoreRefused(_ state: LegacyConversionState)",
                             inCodeOf: model), 1)
        XCTAssertEqual(Self.occurrences(of: "state.diagnosticLabel, privacy: .public", inCodeOf: model), 1)
        XCTAssertEqual(Self.occurrences(of: "privacy: .public", inCodeOf: model), 1,
                       "the fixed label is the only thing this file logs publicly")
        // Both call sites hand it the state itself.
        XCTAssertEqual(
            Self.callArguments(to: "LegacyConversionDiagnostics.restoreRefused", inCodeOf: model),
            ["legacyConversion", "legacyConversion"])
        // The mapping is exhaustive — no default to hide a new case in.
        let label = try Self.functionBody(startingWith: "var diagnosticLabel: String {", in: model)
        XCTAssertEqual(Self.occurrences(of: "default:", inCodeOf: label), 0,
                       "a default would let a new case fall through instead of failing the build")
        for label6 in ["idle", "blocked", "summary", "running", "completed", "failed"] {
            XCTAssertEqual(Self.occurrences(of: "return \"\(label6)\"", inCodeOf: label), 1)
        }
    }

    // MARK: - Helpers

    private static let languages = ["zh-Hans", "zh-Hant", "en", "ja", "ko", "fr"]

    /// The body of the first function whose declaration begins with `prefix`, brace-matched.
    private static func functionBody(startingWith prefix: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: prefix), "no function begins with \(prefix)")
        let open = try XCTUnwrap(source.range(of: "{", range: start.lowerBound..<source.endIndex))
        var depth = 1
        var index = open.upperBound
        while index < source.endIndex, depth > 0 {
            if source[index] == "{" { depth += 1 }
            if source[index] == "}" { depth -= 1; if depth == 0 { break } }
            index = source.index(after: index)
        }
        XCTAssertEqual(depth, 0, "\(prefix) is unbalanced")
        return String(source[open.upperBound..<index])
    }

    /// Non-comment, non-blank lines, trimmed — the statements, in order.
    private static func codeLines(of source: String) -> [String] {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("//") && !$0.hasPrefix("*") && !$0.hasPrefix("/*") }
    }

    /// The body of `.sheet(isPresented: $model.<binding>) { … }`, brace-matched.
    private static func sheetClosure(binding: String, in source: String) throws -> String {
        let opener = ".sheet(isPresented: $model.\(binding)) {"
        let start = try XCTUnwrap(source.range(of: opener),
                                  "no sheet is presented by $model.\(binding)")
        var depth = 1
        var index = start.upperBound
        while index < source.endIndex, depth > 0 {
            if source[index] == "{" { depth += 1 }
            if source[index] == "}" { depth -= 1; if depth == 0 { break } }
            index = source.index(after: index)
        }
        XCTAssertEqual(depth, 0, "the \(binding) sheet closure is unbalanced")
        return String(source[start.upperBound..<index])
    }

    /// The argument text of every call to `name(...)` on a non-comment line, in order. An empty
    /// string means the call takes no argument, which is the only form that disables a sheet's
    /// interactive dismissal for good.
    private static func callArguments(to name: String, inCodeOf source: String) -> [String] {
        var out: [String] = []
        for raw in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("*"), !trimmed.hasPrefix("/*") else {
                continue
            }
            var search = line.startIndex
            while let call = line.range(of: "\(name)(", range: search..<line.endIndex) {
                var depth = 1
                var index = call.upperBound
                while index < line.endIndex, depth > 0 {
                    if line[index] == "(" { depth += 1 }
                    if line[index] == ")" { depth -= 1; if depth == 0 { break } }
                    index = line.index(after: index)
                }
                if depth == 0 {
                    out.append(String(line[call.upperBound..<index])
                        .trimmingCharacters(in: .whitespaces))
                }
                search = call.upperBound
            }
        }
        return out
    }

    /// `ActivationRecord`'s only initialiser binds a real `PreparedImport`, so a stand-in is
    /// decoded rather than constructed. Its CONTENT is irrelevant here — the assertion is about
    /// which authorization cases carry evidence at all.
    private static func someRecord() throws -> ActivationRecord {
        let json = """
            {"formatVersion":1,"importID":"20260101-000000-aaaaaaaa",
             "snapshotIdentitySHA256":"a","attachmentManifestSHA256":"b","sourceDBSHA256":"c",
             "preparedDBIdentity":"d","transactionsMigrated":0}
            """
        return try JSONDecoder().decode(ActivationRecord.self, from: Data(json.utf8))
    }

    /// A booted model over a REAL temporary ledger, adopted through the same Phase-B seam the
    /// production chain uses — so `storeOpenAuthorization` is retained exactly as it is in the
    /// shipping app rather than injected.
    private func bootedModel(withLegacyRows: Bool) async throws -> AppModel {
        let url = tempURL("wizard.db")
        let store = try LedgerStore(databaseURL: url, open: .createIfMissing)
        try store.settings.setString("CN", for: SettingsStore.Key.accountingLocale)
        try store.settings.setString("CNY", for: SettingsStore.Key.currency)
        if withLegacyRows {
            try store.db.run("""
                INSERT INTO sales (id, date, customer, totalAmount, amountWithoutTax, taxAmount,
                                   taxRate, paid_amount, payment_status)
                VALUES ('s1', '2024-03-10', 'A', 9040, 8000, 1040, 13, 9040, 'paid')
                """)
            try store.db.run("""
                INSERT INTO purchases (id, date, supplier, totalAmount, amountWithoutTax, taxAmount,
                                       taxRate, paid_amount, payment_status)
                VALUES ('p1', '2024-03-01', 'B', 6780, 6000, 780, 13, 6780, 'paid')
                """)
        }
        let fake = FakeRunner(store: store)
        let model = AppModel(runner: fake)
        model.boot()
        await model.currentBootTask?.value
        XCTAssertNotNil(model.store, "the fixture model must have adopted a store")
        XCTAssertEqual(model.storeOpenAuthorization, .openExistingPlain,
                       "the adopted authorization must be retained for the wizard")
        return model
    }

    /// Drives one adoption through the real Phase-A/Phase-B seam.
    private final class FakeRunner: BootChainRunner {
        private let store: LedgerStore
        init(store: LedgerStore) { self.store = store }

        @MainActor func resolveOutcome(_ intent: BootIntent) async -> BootOutcome {
            .openStore(authorization: .openExistingPlain, residual: nil)
        }

        @MainActor func attempt(_ authorization: StoreOpenAuthorization,
                                residual: MigrationResidual?) -> MigrationBootDriver.Attempt {
            .opened(store, residual)
        }
    }

    /// SHA-256 of the database and its `-wal`, the way 2a-1 measures "wrote nothing".
    private static func fileDigests(_ url: URL) throws -> [String] {
        try ["", "-wal"].map { suffix -> String in
            let path = url.path + suffix
            guard let data = FileManager.default.contents(atPath: path) else { return "absent" }
            return data.map { String(format: "%02x", $0) }.joined()
        }
    }

    /// …/native/SoloLedger/App/Tests/SoloLedgerUnitTests/<this>.swift → …/native/SoloLedger
    private static func packageRoot() -> URL {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { dir.deleteLastPathComponent() }
        return dir
    }

    private static func appSource(_ relative: String) throws -> String {
        try String(contentsOf: packageRoot()
            .appendingPathComponent("Sources/SoloLedger/\(relative)"), encoding: .utf8)
    }

    private static func appSources() throws -> [(path: String, text: String)] {
        let root = packageRoot().appendingPathComponent("Sources/SoloLedger")
        guard let walker = FileManager.default.enumerator(atPath: root.path) else { return [] }
        var out: [(String, String)] = []
        for case let rel as String in walker where rel.hasSuffix(".swift") {
            let url = root.appendingPathComponent(rel)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            out.append(("Sources/SoloLedger/\(rel)", text))
        }
        return out
    }

    /// Files naming `name` as a whole identifier on a non-comment line, sorted.
    private static func mentions(of name: String,
                                 in sources: [(path: String, text: String)]) -> [String] {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let boundary = name.last.map { $0.isLetter || $0.isNumber || $0 == "_" } ?? false
        let pattern = boundary
            ? "(?<![A-Za-z0-9_])\(escaped)(?![A-Za-z0-9_])"
            : "(?<![A-Za-z0-9_])\(escaped)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var found: Set<String> = []
        for source in sources {
            for raw in source.text.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = String(raw)
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") {
                    continue
                }
                if regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                    found.insert(source.path)
                }
            }
        }
        return found.sorted()
    }

    /// How many times `needle` appears on a NON-COMMENT line of one file. Comments are not
    /// code — this suite's own subjects carry doc comments naming the very things it forbids.
    private static func occurrences(of needle: String, inCodeOf source: String) -> Int {
        source.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) { total, raw in
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("*"), !trimmed.hasPrefix("/*") else {
                return total
            }
            return total + line.components(separatedBy: needle).count - 1
        }
    }
}

private extension LegacyConversionComposition.Page {
    /// The running page is the only one with running keys — a small readability helper for the
    /// assertion above, not a second source of truth.
    var isRunningState: Bool { runningKeys != nil }
}
