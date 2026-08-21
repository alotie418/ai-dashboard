import XCTest
@testable import SoloLedger
import SoloLedgerCore

/// N-PR-5b — what the opening-stock wizard puts on each of its states, what it refuses to say,
/// and the fact that the inventory page is the only thing that can open it.
///
/// XCUITest is not available here, so "is it on screen" is answered structurally: the sheet is
/// built from ``InventoryOpeningComposition`` and nothing else, and `InventoryOpeningView.swift`
/// holds no literal in the copy's namespace. The last group drives a REAL ledger through the
/// model's own intents and reads the result back through a second connection.
@MainActor
final class InventoryOpeningWizardTests: XCTestCase {

    private let languages = ["zh-Hans", "zh-Hant", "en", "ja", "ko", "fr"]

    // ==============================================================================================
    // MARK: - Fixtures
    // ==============================================================================================

    private func plan(_ names: [String], alreadyMoving: Int = 0) -> InventoryOpeningPlan {
        InventoryOpeningPlan(
            candidates: names.enumerated().map { index, name in
                InventoryOpeningCandidate(productID: "p\(index)", name: name, unit: "kg")
            },
            alreadyMovingCount: alreadyMoving)
    }

    private func draft(_ names: [String] = ["Alpha", "Beta"],
                       filled: [(quantity: String, amount: String)] = []) -> InventoryOpeningDraft {
        var draft = InventoryOpeningDraft(plan: plan(names), occurredOn: "2026-01-10")
        for (index, values) in filled.enumerated() where draft.lines.indices.contains(index) {
            draft.lines[index].quantityText = values.quantity
            draft.lines[index].amountText = values.amount
        }
        return draft
    }

    private static let refusals = [
        InventoryOpeningRefusal(productName: "Alpha",
                                messageKey: "inventory.error.openingMustBeFirst"),
        InventoryOpeningRefusal(productName: "Beta",
                                messageKey: "inventory.error.currencyMismatch"),
    ]

    /// One page per state the wizard can be in. Between them they must draw every placed key.
    private func compositions() -> [InventoryOpeningComposition.Page] {
        [
            InventoryOpeningComposition.compose(.idle),
            InventoryOpeningComposition.compose(.blocked(.noProduct)),
            InventoryOpeningComposition.compose(.blocked(.noneEligible)),
            InventoryOpeningComposition.compose(.editing(draft())),
            InventoryOpeningComposition.compose(.editing(draft(filled: [("10", "125")]))),
            InventoryOpeningComposition.compose(.editing(draft(filled: [("10", "125"), ("3", "0")]))),
            InventoryOpeningComposition.compose(.done),
            InventoryOpeningComposition.compose(.partial(Self.refusals)),
        ]
    }

    private struct Slot: Hashable {
        let region: InventoryOpeningComposition.Region
        let detail: String
    }

    private func placements(in page: InventoryOpeningComposition.Page) -> [(key: String, slot: Slot)] {
        func slot(_ region: InventoryOpeningComposition.Region, _ detail: String = "") -> Slot {
            Slot(region: region, detail: detail)
        }
        var out: [(String, Slot)] = []
        if let titleKey = page.titleKey { out.append((titleKey, slot(.frame, "title"))) }
        out += page.noteKeys.map { ($0, slot(.frame, "notes")) }
        out += page.blockedKeys.map { ($0, slot(.blocked)) }
        if let key = page.blockedDismissKey { out.append((key, slot(.confirm, "actions"))) }
        if let list = page.list {
            out += list.headerKeys.map { ($0, slot(.listHeader)) }
        }
        if let form = page.form {
            out.append((form.dateLabelKey, slot(.form, "date")))
            out.append((form.dateNoteKey, slot(.form, "date")))
            out.append((form.quantityHintKey, slot(.form, "hints")))
            out.append((form.amountHintKey, slot(.form, "hints")))
            out.append((form.roundingNoteKey, slot(.form, "hints")))
        }
        if let confirm = page.confirm {
            out.append((confirm.summaryKey, slot(.confirm, "summary")))
            out.append((confirm.currencyNoteKey, slot(.confirm, "summary")))
            out.append((confirm.submitActionKey, slot(.confirm, "actions")))
            out.append((confirm.cancelActionKey, slot(.confirm, "actions")))
        }
        if let outcome = page.outcome {
            out.append((outcome.titleKey, slot(.outcome, "title")))
            out.append((outcome.messageKey, slot(.outcome, "message")))
            out.append((outcome.dismissActionKey, slot(.outcome, "actions")))
        }
        return out.map { (key: $0.0, slot: $0.1) }
    }

    // ==============================================================================================
    // MARK: - IW1 — the placement table is the wizard's half of the namespace, both directions
    // ==============================================================================================

    /// The `inventory.opening.*` copy is split across two tables: the two entry keys belong to the
    /// page whose header draws them, the other twenty-three to this wizard. That split is asserted
    /// as a PARTITION in `InventoryMountingTests`; here it is asserted from the wizard's side.
    func testIW1ThePlacementTableIsTheWizardsTwentyThreeKeys() throws {
        let placed = Set(InventoryOpeningComposition.placement.keys)
        XCTAssertEqual(placed.count, 23, "twenty-five landed by N-PR-5a, less the two entry keys")
        let entry = Set(["inventory.opening.cta", "inventory.opening.cta.hint"])
        for language in languages {
            let landed = Set(try sourceTable(language).keys.filter {
                $0.hasPrefix("inventory.opening.")
            })
            XCTAssertEqual(landed, placed.union(entry), """
                \(language): the wizard copy and the two placement tables disagree.
                written but never drawn: \(landed.subtracting(placed.union(entry)).sorted())
                drawn but never written: \(placed.union(entry).subtracting(landed).sorted())
                """)
            XCTAssertTrue(placed.isDisjoint(with: entry), "the entry keys belong to the page")
        }
        XCTAssertTrue(InventoryOpeningComposition.exemptKeys.isEmpty,
                      "this wizard's closure test is a plain equality and stays one")
        XCTAssertEqual(InventoryOpeningComposition.pageTitleKey, "inventory.opening.title")
    }

    // MARK: - IW2 — every region is used and every key has exactly one

    func testIW2EveryRegionIsUsedAndEveryKeyHasExactlyOne() {
        var byRegion: [InventoryOpeningComposition.Region: [String]] = [:]
        for (key, region) in InventoryOpeningComposition.placement {
            byRegion[region, default: []].append(key)
        }
        for (key, region) in InventoryOpeningComposition.sharedKeys {
            byRegion[region, default: []].append(key)
        }
        for region in InventoryOpeningComposition.Region.allCases {
            XCTAssertFalse((byRegion[region] ?? []).isEmpty, "\(region) has no keys")
        }
        // Unlike the two page tables, nothing here is drawn twice — the map is one region per key
        // rather than a set, and that is a fact about this screen worth keeping true.
        XCTAssertEqual(InventoryOpeningComposition.placement.count,
                       Set(InventoryOpeningComposition.placement.keys).count)
        XCTAssertEqual(byRegion.values.map(\.count).reduce(0, +), 25, "23 placed + 2 borrowed")
    }

    // MARK: - IW3 — every placed key is drawn by some state, and vice versa

    func testIW3EveryPlacedKeyIsDrawnBySomeStateAndViceVersa() {
        var drawn: Set<String> = []
        for page in compositions() { drawn.formUnion(page.allKeys) }
        let placed = Set(InventoryOpeningComposition.placement.keys)
        let shared = Set(InventoryOpeningComposition.sharedKeys.keys)
        XCTAssertEqual(drawn, placed.union(shared), """
            placed but never drawn: \(placed.union(shared).subtracting(drawn).sorted())
            drawn but not placed:   \(drawn.subtracting(placed.union(shared)).sorted())
            """)
        // The closed sheet draws nothing at all — not even its own title.
        XCTAssertTrue(InventoryOpeningComposition.compose(.idle).allKeys.isEmpty)
        XCTAssertNil(InventoryOpeningComposition.compose(.idle).titleKey)
    }

    // MARK: - IW4 — a composed key lands in a region it was declared for

    func testIW4EveryComposedKeyLandsInADeclaredRegion() {
        for page in compositions() {
            for (key, slot) in placements(in: page) {
                let declared = InventoryOpeningComposition.placement[key]
                    ?? InventoryOpeningComposition.sharedKeys[key]
                guard let declared else {
                    XCTFail("\(key) is composed but declared nowhere"); continue
                }
                XCTAssertEqual(declared, slot.region, "\(key) is drawn in \(slot.region)")
            }
        }
    }

    // MARK: - IW5 — the borrowed buttons

    func testIW5TheBorrowedKeysAreTheTwoSharedButtons() {
        let shared = InventoryOpeningComposition.sharedKeys
        XCTAssertEqual(Set(shared.keys), ["common.cancel", "common.ok"])
        XCTAssertEqual(shared["common.cancel"], .confirm)
        XCTAssertEqual(shared["common.ok"], .outcome)
        for key in shared.keys {
            XCTAssertFalse(key.hasPrefix("inventory."), "\(key) belongs in placement, not here")
            XCTAssertNil(InventoryOpeningComposition.placement[key], "\(key) is in both tables")
            for language in languages {
                XCTAssertNotEqual(value(language, key), key, "\(language)/\(key) leaks the raw key")
            }
        }
    }

    // MARK: - IW6 — the two refusals to start

    /// Each blocker has its own pair. Mapping both to one sentence would tell a user with no
    /// products that every product already has movements, which is a different and false thing.
    func testIW6EachBlockerHasItsOwnPair() {
        let noProduct = InventoryOpeningComposition.keys(for: .noProduct)
        let noneEligible = InventoryOpeningComposition.keys(for: .noneEligible)
        XCTAssertEqual(noProduct.count, 2)
        XCTAssertEqual(noneEligible.count, 2)
        XCTAssertTrue(Set(noProduct).isDisjoint(with: Set(noneEligible)))
        for language in languages {
            XCTAssertNotEqual(value(language, noProduct[0]), value(language, noneEligible[0]))
            XCTAssertNotEqual(value(language, noProduct[1]), value(language, noneEligible[1]))
        }
        XCTAssertEqual(InventoryOpeningComposition.compose(.blocked(.noProduct)).blockedKeys,
                       noProduct)
        XCTAssertEqual(InventoryOpeningComposition.compose(.blocked(.noneEligible)).blockedKeys,
                       noneEligible)
    }

    // MARK: - IW7 — no two keys in one slot read the same

    func testIW7NoTwoKeysInOneSlotRenderTheSameLabel() {
        for page in compositions() {
            for language in languages {
                var bySlotText: [String: Set<String>] = [:]
                for (key, slot) in placements(in: page) {
                    bySlotText["\(slot.region.rawValue)/\(slot.detail)|\(value(language, key))",
                               default: []].insert(key)
                }
                for (bucket, keys) in bySlotText where keys.count > 1 {
                    XCTFail("\(language) \(bucket): \(keys.sorted()) render identically")
                }
            }
        }
    }

    /// The three sentences an outcome page can stack — its own message and any number of borrowed
    /// refusals — live in different regions, so the slot buckets above cannot see a collision.
    func testIW7bAnOutcomeMessageNeverReadsLikeARefusal() {
        let outcome = ["inventory.opening.done.message", "inventory.opening.partial.message"]
        let errors = Self.allErrorCases.map(InventoryPageComposition.key(for:))
        for language in languages {
            var seen: [String: String] = [:]
            for key in outcome + errors {
                let rendered = Localizer(language: language).t(key, ["count": "3"])
                if let other = seen[rendered] {
                    XCTFail("\(language): “\(rendered)” is rendered by both \(other) and \(key)")
                }
                seen[rendered] = key
            }
        }
    }

    // ==============================================================================================
    // MARK: - IW8 — the wizard is reachable from the page, and the page from the sidebar
    // ==============================================================================================

    func testIW8TheWizardIsMountedOnceByThePageAndThePageOnceByTheDetailSwitch() throws {
        let sources = try Self.appSources()
        XCTAssertGreaterThan(sources.count, 10, "the scan must have seen the app target")

        XCTAssertEqual(Self.mentions(of: "InventoryView(", in: sources),
                       ["Views/RootView.swift"],
                       "the inventory page is constructed once, by the detail switch")
        XCTAssertEqual(Self.mentions(of: "InventoryOpeningView(", in: sources),
                       ["Views/InventoryView.swift"],
                       "the wizard is mounted exactly once, by the page it belongs to")
        // The composition is the sheet's only source of keys, and the model never touches it: the
        // model owns the STATE, the composition turns that state into what is drawn. Keeping the
        // model out of this list is what makes "a key that is not composed cannot reach the
        // screen" true of the wizard as well as of the two pages.
        XCTAssertEqual(Self.mentions(of: "InventoryOpeningComposition", in: sources),
                       ["App/InventoryOpeningComposition.swift", "Views/InventoryOpeningView.swift"])
        XCTAssertEqual(Self.mentions(of: "InventoryOpeningDraft", in: sources),
                       ["App/AppModel.swift", "App/InventoryOpeningComposition.swift",
                        "App/InventoryOpeningState.swift"])
        XCTAssertEqual(Self.mentions(of: "InventoryOpeningState", in: sources),
                       ["App/AppModel.swift", "App/InventoryOpeningComposition.swift",
                        "App/InventoryOpeningState.swift"])

        // The route's two halves, both present since N-PR-6. Restated here rather than left to
        // `InventoryMountingTests`: this suite's proposition is that the wizard reaches the user
        // through the page and through nothing else, and that claim is only worth anything while
        // the page itself has exactly one route.
        let root = try Self.appSource("Views/RootView.swift")
        XCTAssertEqual(Self.occurrences(of: "case .inventory", inCodeOf: root), 1)
        XCTAssertEqual(SidebarSection.allCases.map(\.rawValue),
                       ["overview", "transactions", "categories", "products", "inventory",
                        "documents", "reports"])

        XCTAssertEqual(Self.mentions(of: "InventoryOpeningView(",
                                     in: [("X.swift", "  InventoryOpeningView()")]), ["X.swift"])
        XCTAssertEqual(Self.mentions(of: "InventoryOpeningView(",
                                     in: [("X.swift", "  // InventoryOpeningView() later")]), [])
        XCTAssertEqual(Self.mentions(of: "InventoryOpeningView(",
                                     in: [("X.swift", "  InventoryOpeningViewModel()")]), [],
                       "whole-prefix matching only")
    }

    // MARK: - IW9 — no copy of its own, no spinner, no table

    func testIW9TheSheetHoldsNoCopyOfItsOwnAndDrawsNoTable() throws {
        let view = try Self.appSource("Views/InventoryOpeningView.swift")
        let composition = try Self.appSource("App/InventoryOpeningComposition.swift")
        for source in [view, composition, try Self.appSource("App/InventoryOpeningState.swift")] {
            XCTAssertFalse(source.contains("ProgressView"), "no spinner: the work is synchronous")
            XCTAssertFalse(source.contains("/*"), "block comments hide code from the guards")
        }
        for key in InventoryOpeningComposition.placement.keys {
            XCTAssertFalse(view.contains("\"\(key)\""), "the sheet names \(key) directly")
        }
        XCTAssertFalse(view.contains("\"inventory."),
                       "the sheet holds a literal in the copy's namespace")
        XCTAssertTrue(view.contains("\"inventoryOpening.sheet\""),
                      "the identifier prefix moved — is the rule still being followed?")
        // No `Table` here on purpose: the page's movement list needs one and pays for it with the
        // cell rule PM13 enforces. A VStack of rows cannot be rebuilt outside the environment.
        XCTAssertFalse(Self.namesIdentifier("Table", in: view),
                       "a Table here would need PM13's cell guard, and this list does not need one")
    }

    // MARK: - IW10 — the sheet cannot be dismissed around the model

    func testIW10TheSheetDisablesInteractiveDismissUnconditionally() throws {
        let page = try Self.appSource("Views/InventoryView.swift")
        XCTAssertEqual(Self.callArguments(to: "interactiveDismissDisabled", inCodeOf: page), [""],
                       "unconditional: a `.editing`-only version leaves every other state open")
        XCTAssertEqual(Self.occurrences(of: "interactiveDismissDisabled", inCodeOf: page), 1)
        XCTAssertEqual(Self.occurrences(of: "InventoryOpeningView()", inCodeOf: page), 1)
        // The parser is proved on synthetic text, or "no argument" and "cannot see one" look alike.
        XCTAssertEqual(Self.callArguments(to: "interactiveDismissDisabled",
                                          inCodeOf: "  .interactiveDismissDisabled(x)"), ["x"])
        XCTAssertEqual(Self.callArguments(to: "interactiveDismissDisabled",
                                          inCodeOf: "  // .interactiveDismissDisabled()"), [])
    }

    // ==============================================================================================
    // MARK: - IW11 — the counted sentences count the right thing
    // ==============================================================================================

    /// `{count}` on the confirmation is the number of lines that READ as postable, not the number
    /// of products on screen: a user who filled in two of eleven is told two.
    func testIW11TheCountedSentencesCountWhatTheyClaim() throws {
        let partly = InventoryOpeningComposition.compose(
            .editing(draft(["Alpha", "Beta", "Gamma"], filled: [("10", "125")])))
        XCTAssertEqual(partly.confirm?.countedProducts, 1, "one line reads, three products exist")
        XCTAssertEqual(partly.list?.rows.count, 3)

        let none = InventoryOpeningComposition.compose(.editing(draft(["Alpha", "Beta"])))
        XCTAssertEqual(none.confirm?.countedProducts, 0)
        XCTAssertEqual(none.confirm?.canSubmit, false, "nothing filled in is nothing to post")

        let both = InventoryOpeningComposition.compose(
            .editing(draft(filled: [("10", "125"), ("2", "8")])))
        XCTAssertEqual(both.confirm?.countedProducts, 2)
        XCTAssertEqual(both.confirm?.canSubmit, true)

        // And the outcome's `{count}` is the number REFUSED, not the number sent.
        let partial = InventoryOpeningComposition.compose(.partial(Self.refusals))
        XCTAssertEqual(partial.outcome?.refusedCount, 2)
        XCTAssertEqual(partial.outcome?.refusals.count, 2)
        XCTAssertEqual(InventoryOpeningComposition.compose(.done).outcome?.refusedCount, 0)
        XCTAssertEqual(InventoryOpeningComposition.compose(.done).outcome?.refusals, [])

        // The sentences really do carry the token, in every language.
        for language in languages {
            for key in ["inventory.opening.summary", "inventory.opening.partial.message"] {
                XCTAssertTrue(try XCTUnwrap(sourceTable(language)[key]).contains("{count}"),
                              "\(language)/\(key) lost its placeholder")
            }
        }
    }

    // ==============================================================================================
    // MARK: - IW12 — what a line is, and what may be posted out of it
    // ==============================================================================================

    func testIW12ABlankLineIsSkippedAndAHalfFilledOneStopsEverything() {
        var draft = self.draft(["Alpha", "Beta"])
        XCTAssertEqual(draft.entries.count, 0)
        XCTAssertFalse(draft.isPostable, "nothing to post")

        draft.lines[0].quantityText = "10"
        draft.lines[0].amountText = "125"
        XCTAssertEqual(draft.entries.count, 1)
        XCTAssertTrue(draft.isPostable, "a blank line is how a product is left out")

        // Half a line must BLOCK the whole submission. Dropping it would tell the user everything
        // went in while that product silently has no opening — and D-5 makes that permanent.
        draft.lines[1].quantityText = "3"
        XCTAssertTrue(draft.hasIncompleteLine)
        XCTAssertEqual(draft.entries.count, 1, "the half line is not an entry")
        XCTAssertFalse(draft.isPostable, "…and it is not silently skipped either")

        draft.lines[1].amountText = "abc"
        XCTAssertFalse(draft.isPostable, "an unreadable amount is not a zero")
        draft.lines[1].amountText = "0"
        XCTAssertTrue(draft.isPostable, "zero IS a price — goods that cost nothing")
        XCTAssertEqual(draft.entries.count, 2)

        draft.lines[1].quantityText = "0"
        XCTAssertFalse(draft.isPostable, "a zero quantity is not an opening")
        draft.lines[1].quantityText = "1,000"
        XCTAssertFalse(draft.isPostable, "a grouping separator means different things per locale")

        draft.lines[1].quantityText = ""
        draft.lines[1].amountText = ""
        XCTAssertTrue(draft.isPostable)
        draft.occurredOn = ""
        XCTAssertFalse(draft.isPostable, "every line shares one date, and it has to exist")
    }

    func testIW12bTheImpliedUnitCostIsShownOnlyForALineThatReads() throws {
        var draft = self.draft(["Alpha"])
        XCTAssertNil(draft.impliedUnitCostMicro(of: draft.lines[0]), "a blank line implies nothing")
        draft.lines[0].quantityText = "10"
        XCTAssertNil(draft.impliedUnitCostMicro(of: draft.lines[0]), "half a line implies nothing")
        draft.lines[0].amountText = "125"
        // 125.00 major over 10 units = 12.50 each = 1_250_000_000 micro.
        XCTAssertEqual(draft.impliedUnitCostMicro(of: draft.lines[0]), 1_250_000_000)

        let page = InventoryOpeningComposition.compose(.editing(draft))
        XCTAssertEqual(page.list?.rows.first?.impliedUnitCostMicro, 1_250_000_000)
        XCTAssertEqual(page.list?.rows.first?.quantityText, "10")
        XCTAssertEqual(page.list?.rows.first?.productName, "Alpha")
    }

    // MARK: - IW13 — the refusal sentences are borrowed, not respelled

    /// The wizard shows a reason beside every line the ledger would not take, and that reason is
    /// the page's sentence. Spelling those keys out here would put a second copy of the mapping
    /// within reach — `InventoryCopyTests` IC11 holds every one of them to the page's composition.
    func testIW13EveryRefusalSentenceIsOneOfTheEngineersEighteen() {
        let mapped = Self.allErrorCases.map(InventoryPageComposition.key(for:))
        XCTAssertEqual(Set(mapped).count, 18)
        for key in mapped {
            XCTAssertTrue(key.hasPrefix(InventoryOpeningComposition.borrowedRefusalPrefix),
                          "\(key) is not in the borrowed namespace")
        }
        let page = InventoryOpeningComposition.compose(.partial(Self.refusals))
        for key in page.outcome?.refusalKeys ?? [] {
            XCTAssertTrue(mapped.contains(key), "\(key) is not one of the engine's refusals")
        }
        // …and the wizard's own composition does not spell a single one of them.
        let source = try? Self.appSource("App/InventoryOpeningComposition.swift")
        for key in mapped {
            XCTAssertEqual(source?.contains("\"\(key)\""), false, "\(key) is respelled")
        }
    }

    // ==============================================================================================
    // MARK: - IW14 — a real ledger, and the page behind the sheet
    // ==============================================================================================

    func testIW14AOpeningsLandInTheLedgerAndInThePageBehind() async throws {
        let model = try await bootedModel()
        let store = try XCTUnwrap(model.store)
        let alpha = try store.createProduct(name: "Alpha", unit: "kg")
        _ = try store.createProduct(name: "Beta", unit: "box")
        model.reloadInventory()

        model.beginInventoryOpening()
        XCTAssertTrue(model.showingInventoryOpening)
        XCTAssertTrue(model.inventoryOpening.isEditing)
        XCTAssertEqual(model.inventoryOpeningDraft?.lines.map(\.name), ["Alpha", "Beta"])

        model.setInventoryOpeningDate("2026-01-10")
        model.setInventoryOpeningQuantity("10", at: 0)
        model.setInventoryOpeningAmount("125", at: 0)
        model.confirmInventoryOpening()

        XCTAssertEqual(model.inventoryOpening, .done)
        // The page behind the sheet was refreshed: the balance card, the list and the opening
        // advice all depend on what was just written.
        XCTAssertEqual(model.inventoryProductID, alpha)
        let page = InventoryPageComposition.compose(model.inventoryInput)
        XCTAssertEqual(page.balance?.quantityMilli, 10_000)
        XCTAssertEqual(page.balance?.costBalanceMinor, 12_500)
        XCTAssertEqual(page.balance?.unitCostMicro, 1_250_000_000)
        XCTAssertEqual(page.list?.rows.count, 1)
        XCTAssertTrue(page.openingHintKeys.isEmpty, "an opening is no longer legal for Alpha")

        // …and it is on disk, read through a second connection.
        let second = try LedgerStore(databaseURL: try XCTUnwrap(Self.ledgerURL))
        let landed = try second.inventoryMovements(productID: alpha)
        XCTAssertEqual(landed.count, 1)
        XCTAssertEqual(landed.first?.type, .opening)
        XCTAssertEqual(landed.first?.occurredOn, "2026-01-10")
        XCTAssertEqual(try second.inventoryBalance(productID: alpha).currency, "CNY")
        // The engine flags an opening as entered by hand — N-10's provenance requirement.
        XCTAssertEqual(try second.inventoryExceptions(productID: alpha).map(\.kind), [.openingSeeded])
    }

    func testIW14BAProductThatAlreadyMovedIsNotOfferedAndAllOfThemBlocks() async throws {
        let model = try await bootedModel()
        let store = try XCTUnwrap(model.store)
        let alpha = try store.createProduct(name: "Alpha", unit: "kg")
        _ = try store.postInventoryMovement(InventoryPostingRequest(
            productID: alpha, type: .purchaseIn, occurredOn: "2026-01-05",
            quantityMilli: 1_000, unitCostMicro: 100_000_000, currency: "CNY"))

        model.beginInventoryOpening()
        XCTAssertEqual(model.inventoryOpening, .blocked(.noneEligible),
                       "the only product already has a live movement")

        model.dismissInventoryOpening()
        let beta = try store.createProduct(name: "Beta", unit: "box")
        model.beginInventoryOpening()
        XCTAssertEqual(model.inventoryOpeningDraft?.lines.map(\.productID), [beta])
        XCTAssertEqual(model.inventoryOpeningDraft?.alreadyMovingCount, 1,
                       "the list is not the whole catalogue and says so")
    }

    func testIW14CAnEmptyCatalogueBlocksWithItsOwnSentence() async throws {
        let model = try await bootedModel()
        model.beginInventoryOpening()
        XCTAssertEqual(model.inventoryOpening, .blocked(.noProduct))
        XCTAssertEqual(InventoryOpeningComposition.compose(model.inventoryOpening).blockedKeys,
                       ["inventory.opening.blocked.noProduct.title",
                        "inventory.opening.blocked.noProduct.message"])
        XCTAssertTrue(model.showingInventoryOpening, "the sheet still opens to say why")
    }

    /// A product that moved between the preflight and the confirmation is refused on its own, and
    /// the others go in. That is the whole reason this wizard reports rather than rolls back — and
    /// D-5 is the staleness gate, so there is no second one to forget.
    func testIW14DOneRefusedProductLeavesTheOthersRecorded() async throws {
        let model = try await bootedModel()
        let store = try XCTUnwrap(model.store)
        let alpha = try store.createProduct(name: "Alpha", unit: "kg")
        let beta = try store.createProduct(name: "Beta", unit: "box")
        model.reloadInventory()

        model.beginInventoryOpening()
        model.setInventoryOpeningDate("2026-01-10")
        model.setInventoryOpeningQuantity("10", at: 0)
        model.setInventoryOpeningAmount("125", at: 0)
        model.setInventoryOpeningQuantity("4", at: 1)
        model.setInventoryOpeningAmount("40", at: 1)

        // Another writer gets to Alpha first.
        let second = try LedgerStore(databaseURL: try XCTUnwrap(Self.ledgerURL))
        _ = try second.postInventoryMovement(InventoryPostingRequest(
            productID: alpha, type: .purchaseIn, occurredOn: "2026-01-09",
            quantityMilli: 1_000, unitCostMicro: 100_000_000, currency: "CNY"))

        model.confirmInventoryOpening()

        guard case .partial(let refusals) = model.inventoryOpening else {
            return XCTFail("expected a partial outcome, got \(model.inventoryOpening)")
        }
        XCTAssertEqual(refusals.map(\.productName), ["Alpha"])
        XCTAssertEqual(refusals.map(\.messageKey), ["inventory.error.openingMustBeFirst"])
        // Beta really is in the ledger — this is the claim the copy makes.
        XCTAssertEqual(try second.inventoryMovements(productID: beta).map(\.type), [.opening])
        XCTAssertEqual(try second.inventoryBalance(productID: beta).quantityMilli, 4_000)
        // …and Alpha is untouched by the wizard: one purchase, no opening.
        XCTAssertEqual(try second.inventoryMovements(productID: alpha).map(\.type), [.purchaseIn])

        let page = InventoryOpeningComposition.compose(model.inventoryOpening)
        XCTAssertEqual(page.outcome?.refusedCount, 1)
        XCTAssertEqual(page.outcome?.titleKey, "inventory.opening.partial.title")
    }

    func testIW14EDismissClearsTheStateAndTheSheetTogether() async throws {
        let model = try await bootedModel()
        _ = try XCTUnwrap(model.store).createProduct(name: "Alpha")
        model.beginInventoryOpening()
        XCTAssertTrue(model.showingInventoryOpening)

        model.dismissInventoryOpening()
        XCTAssertFalse(model.showingInventoryOpening)
        XCTAssertEqual(model.inventoryOpening, .idle)
        // …and the entry point works again, which is the whole point of clearing both.
        model.beginInventoryOpening()
        XCTAssertTrue(model.inventoryOpening.isEditing)
    }

    /// Confirming twice may not post twice: the state leaves `.editing` before the screen can
    /// offer the button again.
    func testIW14FConfirmingTwicePostsOnce() async throws {
        let model = try await bootedModel()
        let store = try XCTUnwrap(model.store)
        let alpha = try store.createProduct(name: "Alpha", unit: "kg")
        model.beginInventoryOpening()
        model.setInventoryOpeningDate("2026-01-10")
        model.setInventoryOpeningQuantity("10", at: 0)
        model.setInventoryOpeningAmount("125", at: 0)

        model.confirmInventoryOpening()
        model.confirmInventoryOpening()

        XCTAssertEqual(try store.inventoryMovements(productID: alpha).count, 1)
        XCTAssertEqual(model.inventoryOpening, .done)
    }

    // ==============================================================================================
    // MARK: - Helpers
    // ==============================================================================================

    private static let allErrorCases: [InventoryPostingError] = [
        .netAmountRequired, .unitCostMustNotBeNegative, .quantityMustBePositive,
        .manualAdjustMustNotMoveQuantity, .manualAdjustRequiresStock, .costBalanceWouldGoNegative,
        .insufficientStock, .backdatedNotSupported, .currencyMismatch, .openingMustBeFirst,
        .returnExceedsOrigin, .onlyTheLastMovementCanBeReversed, .movementAlreadyReversed,
        .reversalTargetNotFound, .productNotFound, .arithmeticOverflow, .ledgerInconsistent,
        .storageFailure,
    ]

    private func value(_ language: String, _ key: String) -> String {
        Localizer(language: language).t(key)
    }

    private func sourceTable(_ language: String) throws -> [String: String] {
        let url = Self.packageRoot()
            .appendingPathComponent("Sources/SoloLedger/Resources/\(language).lproj/Localizable.strings")
        let plist = try PropertyListSerialization.propertyList(from: try Data(contentsOf: url),
                                                              options: [], format: nil)
        return try XCTUnwrap(plist as? [String: String], "\(language) is not a string dictionary")
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
        for case let relative as String in walker where relative.hasSuffix(".swift") {
            guard let text = try? String(contentsOf: root.appendingPathComponent(relative),
                                         encoding: .utf8) else { continue }
            out.append((relative, text))
        }
        return out.sorted { $0.0 < $1.0 }
    }

    private static func namesIdentifier(_ identifier: String, in source: String) -> Bool {
        let pattern = "(^|[^A-Za-z0-9_])\(identifier)([^A-Za-z0-9_]|$)"
        return source.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("*"), !trimmed.hasPrefix("/*") else {
                return false
            }
            return line.range(of: pattern, options: .regularExpression) != nil
        }
    }

    private static func occurrences(of needle: String, inCodeOf source: String) -> Int {
        source.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) { total, line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("*"), !trimmed.hasPrefix("/*") else {
                return total
            }
            return total + (line.components(separatedBy: needle).count - 1)
        }
    }

    /// What each call to `name(` was passed, as raw text. `[""]` means one call with no argument.
    private static func callArguments(to name: String, inCodeOf source: String) -> [String] {
        var out: [String] = []
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("*"), !trimmed.hasPrefix("/*"),
                  let open = line.range(of: "\(name)("),
                  let close = line.range(of: ")", range: open.upperBound..<line.endIndex)
            else { continue }
            out.append(String(line[open.upperBound..<close.lowerBound]))
        }
        return out
    }

    private static func mentions(of needle: String,
                                 in sources: [(path: String, text: String)]) -> [String] {
        sources.filter { source in
            source.text.split(separator: "\n", omittingEmptySubsequences: false).contains {
                let trimmed = $0.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//") && !trimmed.hasPrefix("*") && trimmed.contains(needle)
            }
        }.map(\.path)
    }

    // MARK: - A booted model over a real temporary ledger

    private static var ledgerURL: URL?
    private var temporaryDirectory: URL?

    override func tearDownWithError() throws {
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
        Self.ledgerURL = nil
    }

    private func bootedModel() async throws -> AppModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SLOpening-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectory = directory
        let url = directory.appendingPathComponent("opening.db")
        Self.ledgerURL = url

        let store = try LedgerStore(databaseURL: url, open: .createIfMissing)
        try store.settings.setString("CN", for: SettingsStore.Key.accountingLocale)
        let model = AppModel(runner: OpeningFakeRunner(store: store))
        model.boot()
        await model.currentBootTask?.value
        XCTAssertNotNil(model.store, "the fixture model must have adopted a store")
        return model
    }

    private final class OpeningFakeRunner: BootChainRunner {
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
}
