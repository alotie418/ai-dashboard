import XCTest
@testable import SoloLedger
import SoloLedgerCore

/// N-PR-4 — where the inventory page puts things, what it refuses to say, what it computes out of
/// the engine's integers, and the single route that opens it (N-PR-6).
///
/// XCUITest is not available here (the runner hangs enabling automation mode in a headless
/// session), so "is it on screen" is answered structurally: the page is built from
/// ``InventoryPageComposition`` and nothing else, and `InventoryView.swift` holds no literal in
/// the copy's namespace, so asserting on the composition IS asserting on what the view can draw.
///
/// The last group drives a REAL ledger through the model's own intents and asserts that the read
/// model moved — the balance card's three figures and the list's rows together — and then reads
/// the same facts back through a second connection, because "the state is right" and "it is on
/// disk" are different claims.
@MainActor
final class InventoryMountingTests: XCTestCase {

    private let languages = ["zh-Hans", "zh-Hant", "en", "ja", "ko", "fr"]

    // ==============================================================================================
    // MARK: - Fixtures
    // ==============================================================================================

    private func choice(_ id: String = "p1", _ name: String = "Widget")
        -> InventoryPageComposition.ProductChoice {
        InventoryPageComposition.ProductChoice(id: id, name: name)
    }

    private func movement(_ id: String,
                          type: InventoryMovementType,
                          on occurredOn: String = "2026-01-01",
                          seq: Int64 = 1,
                          quantityMilli: Int64 = 1_000,
                          unitCostMicro: Int64? = 1_000_000,
                          totalCostMinor: Int64? = 1_000,
                          source: String? = nil,
                          note: String? = nil,
                          reverses: String? = nil) -> InventoryPostedMovement {
        InventoryPostedMovement(id: id, productID: "p1", type: type, occurredOn: occurredOn,
                                seq: seq, quantityMilli: quantityMilli,
                                unitCostMicro: unitCostMicro, totalCostMinor: totalCostMinor,
                                currency: "CNY",
                                sourceType: source == nil ? nil : "manual", sourceID: source,
                                reversesID: reverses, note: note)
    }

    /// Nine rows: one of each of the eight kinds, plus a reversal of the last of them. Between
    /// them they exercise every type label and all three statuses.
    private func fullHistory() -> (rows: [InventoryPostedMovement], liveIDs: [String]) {
        let kinds = InventoryMovementType.allCases
        var rows: [InventoryPostedMovement] = []
        for (index, kind) in kinds.enumerated() {
            rows.append(movement("m\(index)", type: kind, seq: Int64(index + 1),
                                 source: "DOC-\(index)", note: "n\(index)"))
        }
        let target = rows[rows.count - 1]
        rows.append(movement("r0", type: target.type, seq: Int64(kinds.count + 1),
                             reverses: target.id))
        let live = rows.dropLast(2).map(\.id)
        return (rows, Array(live))
    }

    private func exception(_ id: String, _ kind: InventoryExceptionKind,
                           movementID: String?) -> InventoryException {
        InventoryException(id: id, productID: "p1", movementID: movementID, kind: kind,
                           detail: nil)
    }

    private func balance(quantityMilli: Int64 = 7_000, costBalanceMinor: Int64 = 8_400,
                         unitCostMicro: Int64 = 1_200_000) -> InventoryBalance {
        InventoryBalance(productID: "p1", quantityMilli: quantityMilli,
                         costBalanceMinor: costBalanceMinor, unitCostMicro: unitCostMicro,
                         currency: "CNY", lastMovementID: "m7", lastOccurredOn: "2026-01-01",
                         lastSeq: 9)
    }

    private func stocked(form: InventoryFormDraft? = nil,
                         pendingReversal: InventoryPostedMovement? = nil,
                         exceptions: [InventoryException] = [],
                         unit: InventoryPageComposition.UnitLabel = .key("product.unit.kg"))
        -> InventoryPageComposition.Input {
        let history = fullHistory()
        return .init(products: [choice()], selectedProductID: "p1", unit: unit,
                     balance: balance(), movements: history.rows, liveIDs: history.liveIDs,
                     exceptions: exceptions, form: form, pendingReversal: pendingReversal)
    }

    /// One page per shape the composition can take. Between them they must draw every placed key
    /// and every borrowed one.
    private func compositions() -> [InventoryPageComposition.Page] {
        let history = fullHistory()
        var pages: [InventoryPageComposition.Page] = [
            // Nothing to record a movement against.
            InventoryPageComposition.compose(.init()),
            // A product with no movements at all.
            InventoryPageComposition.compose(.init(products: [choice()], selectedProductID: "p1",
                                                   unit: .key("product.unit.kg"))),
            // The full history, every kind and all three statuses.
            InventoryPageComposition.compose(stocked()),
            // Every movement reversed away: rows on screen, but an opening is legal again.
            InventoryPageComposition.compose(.init(products: [choice()], selectedProductID: "p1",
                                                   unit: .key("product.unit.kg"),
                                                   balance: balance(quantityMilli: 0,
                                                                    costBalanceMinor: 0,
                                                                    unitCostMicro: 0),
                                                   movements: [history.rows[0],
                                                               self.movement("rx",
                                                                             type: history.rows[0].type,
                                                                             seq: 99,
                                                                             reverses: "m0")],
                                                   liveIDs: [])),
            // The panel, in each of its three shapes.
            InventoryPageComposition.compose(stocked(form: draft(.purchaseIn))),
            InventoryPageComposition.compose(stocked(form: draft(.manualAdjust))),
            InventoryPageComposition.compose(stocked(form: draft(.saleOut))),
            // The reversal confirmation.
            InventoryPageComposition.compose(stocked(pendingReversal: history.rows[6])),
            // Every exception kind.
            InventoryPageComposition.compose(stocked(exceptions: [
                exception("x1", .returnOriginNotFound, movementID: "m2"),
                exception("x2", .manualAdjust, movementID: "m6"),
                exception("x3", .openingSeeded, movementID: "m7"),
            ])),
        ]
        // One page per unit label, so all eleven borrowed keys are drawn by some render.
        for raw in InventoryPageComposition.unitRawValues {
            pages.append(InventoryPageComposition.compose(
                stocked(form: draft(.purchaseIn), unit: .key("product.unit.\(raw)"))))
        }
        for error in Self.allErrorCases {
            pages.append(InventoryPageComposition.compose(
                .init(products: [choice()], selectedProductID: "p1", error: error)))
        }
        return pages
    }

    private func draft(_ type: InventoryMovementType) -> InventoryFormDraft {
        var draft = InventoryFormDraft(occurredOn: "2026-01-02")
        draft.type = type
        return draft
    }

    /// Every `InventoryPostingError`, as values. Kept honest against the enum's own source by
    /// IM6, which reads the case names out of `InventoryModels.swift`.
    private static let allErrorCases: [InventoryPostingError] = [
        .netAmountRequired, .unitCostMustNotBeNegative, .quantityMustBePositive,
        .manualAdjustMustNotMoveQuantity, .manualAdjustRequiresStock, .costBalanceWouldGoNegative,
        .insufficientStock, .backdatedNotSupported, .currencyMismatch, .openingMustBeFirst,
        .returnExceedsOrigin, .onlyTheLastMovementCanBeReversed, .movementAlreadyReversed,
        .reversalTargetNotFound, .productNotFound, .arithmeticOverflow, .ledgerInconsistent,
        .storageFailure,
    ]

    /// Where one key sits: the region, plus the SLOT inside it. The slot is what makes the
    /// ambiguity check meaningful — two column headings side by side are ambiguous if they read
    /// the same; a heading that reads like a form field label three regions away is not.
    private struct Slot: Hashable {
        let region: InventoryPageComposition.Region
        let detail: String
    }

    private func placements(in page: InventoryPageComposition.Page) -> [(key: String, slot: Slot)] {
        func slot(_ region: InventoryPageComposition.Region, _ detail: String = "") -> Slot {
            Slot(region: region, detail: detail)
        }
        var out: [(String, Slot)] = [(page.titleKey, slot(.header))]
        out += page.headerKeys.map { ($0, slot(.header)) }
        out += page.noteKeys.map { ($0, slot(.note)) }
        out += page.actionKeys.map { ($0, slot(.action)) }
        out.append((page.openingActionKey, slot(.openingAction)))
        out.append((page.openingHintKey, slot(.openingAction)))
        out += page.errorKeys.map { ($0, slot(.errorBanner)) }
        out += page.emptyKeys.map { ($0, slot(.empty)) }
        out += page.openingHintKeys.map { ($0, slot(.openingHint)) }
        if let card = page.balance {
            out.append((card.titleKey, slot(.balanceCard, "title")))
            out += card.labelKeys.map { ($0, slot(.balanceCard, "figures")) }
            out.append((card.currencyNoteKey, slot(.balanceCard, "note")))
            out += card.unit.keys.map { ($0, slot(.unitLabel, "balance")) }
        }
        if let list = page.list {
            out += list.headerKeys.map { ($0, slot(.listHeader)) }
            out.append((list.onlyLastNoteKey, slot(.listNote)))
            out += list.unit.keys.map { ($0, slot(.unitLabel, "list")) }
            for row in list.rows {
                out.append((row.typeKey, slot(.typeCell, "row:\(row.id)")))
                out.append((row.statusKey, slot(.statusCell, "row:\(row.id)")))
                if let key = row.reverseActionKey {
                    out.append((key, slot(.rowAction, "row:\(row.id)")))
                }
            }
        }
        if let form = page.form {
            out.append((form.titleKey, slot(.form, "title")))
            out += form.fieldLabelKeys.map { ($0, slot(.form, "fields")) }
            out += form.hintKeys.map { ($0, slot(.form, "hints")) }
            out += form.actionKeys.map { ($0, slot(.form, "actions")) }
            out += form.typeOptions.map { ($0.labelKey, slot(.typePicker)) }
            out += form.unit.keys.map { ($0, slot(.unitLabel, "form")) }
        }
        if let block = page.reverse {
            out.append((block.titleKey, slot(.reverseDialog, "title")))
            out.append((block.messageKey, slot(.reverseDialog, "message")))
            out += block.actionKeys.map { ($0, slot(.reverseDialog, "actions")) }
        }
        if let block = page.exceptions {
            out.append((block.titleKey, slot(.exception, "title")))
            out += block.rows.map { ($0.messageKey, slot(.exception, "row:\($0.id)")) }
        }
        return out.map { (key: $0.0, slot: $0.1) }
    }

    // ==============================================================================================
    // MARK: - IM1 — the placement table is the adjudicated namespace, in both directions
    // ==============================================================================================

    func testIM1ThePlacementTablesPartitionTheAdjudicatedNamespace() throws {
        let placed = Set(InventoryPageComposition.placement.keys)
        let wizard = Set(InventoryOpeningComposition.placement.keys)
        XCTAssertEqual(placed.count, 70, "N-PR-3's sixty-eight, plus the wizard's two entry keys")
        XCTAssertEqual(wizard.count, 23, "N-PR-5a's twenty-five, less those two")

        // N-PR-5a excluded the wizard's half by PREFIX, which needed a second assertion to keep
        // the filter from silently widening. Now that the wizard has a table of its own, the
        // exclusion is replaced by the stronger statement it was standing in for: the two tables
        // PARTITION the namespace. Nothing is placed twice, nothing is placed nowhere, and there
        // is no filter left to widen.
        XCTAssertTrue(placed.isDisjoint(with: wizard), """
            a key is placed by both tables: \(placed.intersection(wizard).sorted())
            """)
        for language in languages {
            let landed = Set(try sourceTable(language).keys.filter { $0.hasPrefix("inventory.") })
            XCTAssertEqual(landed, placed.union(wizard), """
                \(language): the copy and the two placement tables disagree.
                written but never drawn: \(landed.subtracting(placed.union(wizard)).sorted())
                drawn but never written: \(placed.union(wizard).subtracting(landed).sorted())
                """)
            XCTAssertEqual(landed.count, 93)
        }
        // The two entry keys are the whole of the overlap in SUBJECT — they are `inventory.opening.*`
        // strings placed by the page — so they are named here rather than left implicit.
        XCTAssertEqual(placed.filter { $0.hasPrefix("inventory.opening.") }.sorted(),
                       ["inventory.opening.cta", "inventory.opening.cta.hint"],
                       "the page draws the wizard's entry point and nothing else of it")
        // The closure above is an EQUALITY, not `placement ∪ exemptions`. Asserting the exemption
        // table is empty is what keeps it one: a later round that needs an exemption has to change
        // this line first, in the open, instead of quietly growing a list.
        XCTAssertTrue(InventoryPageComposition.exemptKeys.isEmpty,
                      "this page's closure test is a plain equality and stays one")
        XCTAssertTrue(placed.contains(InventoryPageComposition.pageTitleKey))
    }

    // MARK: - IM2 — every region is used and every key has one

    func testIM2EveryRegionIsUsedAndEveryKeyHasAtLeastOne() {
        var byRegion: [InventoryPageComposition.Region: [String]] = [:]
        for (key, regions) in InventoryPageComposition.placement {
            XCTAssertFalse(regions.isEmpty, "\(key) is placed nowhere")
            for region in regions { byRegion[region, default: []].append(key) }
        }
        for (key, regions) in InventoryPageComposition.sharedKeys {
            XCTAssertFalse(regions.isEmpty, "\(key) is placed nowhere")
            for region in regions { byRegion[region, default: []].append(key) }
        }
        for region in InventoryPageComposition.Region.allCases {
            XCTAssertFalse((byRegion[region] ?? []).isEmpty, "\(region) has no keys")
        }
        // The three facts that make this map a Set per key rather than one region per key.
        XCTAssertEqual(InventoryPageComposition.placement["inventory.form.title"],
                       [.action, .form], "the button borrows the panel's own heading")
        XCTAssertEqual(InventoryPageComposition.placement["inventory.col.quantity"],
                       [.listHeader, .form], "six column headings are also field labels")
        XCTAssertEqual(InventoryPageComposition.placement["inventory.type.countGain"],
                       [.typeCell, .typePicker])
        // …and the two that are headings and nothing else.
        XCTAssertEqual(InventoryPageComposition.placement["inventory.col.cost"], [.listHeader])
        XCTAssertEqual(InventoryPageComposition.placement["inventory.col.status"], [.listHeader])
    }

    // MARK: - IM3 — every placed key is drawn by some render, and vice versa

    func testIM3EveryPlacedKeyIsDrawnBySomeRenderAndViceVersa() {
        var drawn: Set<String> = []
        for page in compositions() { drawn.formUnion(page.allKeys) }
        let placed = Set(InventoryPageComposition.placement.keys)
        let shared = Set(InventoryPageComposition.sharedKeys.keys)
        XCTAssertEqual(drawn, placed.union(shared), """
            placed but never drawn: \(placed.union(shared).subtracting(drawn).sorted())
            drawn but not placed:   \(drawn.subtracting(placed.union(shared)).sorted())
            """)
    }

    // MARK: - IM4 — a composed key lands in a region it was declared for

    func testIM4EveryComposedKeyLandsInADeclaredRegion() {
        for page in compositions() {
            for (key, slot) in placements(in: page) {
                let declared = InventoryPageComposition.placement[key]
                    ?? InventoryPageComposition.sharedKeys[key]
                guard let declared else {
                    XCTFail("\(key) is composed but declared nowhere"); continue
                }
                XCTAssertTrue(declared.contains(slot.region), """
                    \(key) is drawn in \(slot.region), declared \
                    \(declared.sorted(by: { $0.rawValue < $1.rawValue }))
                    """)
            }
        }
    }

    // MARK: - IM5 — the borrowed vocabulary, and that it cannot go stale

    /// The eleven unit keys are spelled from raw values rather than written out, so that neither
    /// `ProductCopyTests`' literal scan nor `ProductMountingTests`' three-file rule is disturbed.
    /// The price of deriving them is a hand-written list of raw values, and this is what keeps
    /// that list honest: it is compared against the enum itself AND against the products page's
    /// own placement table.
    func testIM5TheBorrowedKeysAreTheUnitsPlusCancelAndCannotGoStale() {
        let shared = InventoryPageComposition.sharedKeys
        let unitKeys = Set(shared.keys.filter { $0.hasPrefix("product.unit.") })

        XCTAssertEqual(InventoryPageComposition.unitRawValues, ProductUnit.allCases.map(\.rawValue),
                       "the derived unit list and the write-side whitelist have diverged")
        XCTAssertEqual(unitKeys, Set(ProductUnit.allCases.map { "product.unit.\($0.rawValue)" }))
        XCTAssertEqual(unitKeys,
                       Set(ProductPageComposition.placement.keys.filter {
                           $0.hasPrefix("product.unit.")
                       }),
                       "the products page places a different set of unit labels")
        XCTAssertEqual(Set(shared.keys), unitKeys.union(["common.cancel"]))
        XCTAssertEqual(shared["common.cancel"], [.form, .reverseDialog])

        for key in shared.keys {
            XCTAssertFalse(key.hasPrefix("inventory."), "\(key) belongs in placement, not here")
            XCTAssertNil(InventoryPageComposition.placement[key], "\(key) is in both tables")
            for language in languages {
                XCTAssertNotEqual(value(language, key), key, "\(language)/\(key) leaks the raw key")
            }
        }
    }

    // ==============================================================================================
    // MARK: - IM6 — every refusal has exactly one sentence, and it is the production mapping
    // ==============================================================================================

    /// The switch lives in `InventoryPageComposition` and this test READS it. Keeping a second
    /// copy of the mapping here would let the shipped one change while the test went on agreeing
    /// with itself.
    ///
    /// The eighteen cases are exhausted against the ENUM'S OWN SOURCE rather than against the
    /// hand-written list below: `InventoryPostingError` is not `CaseIterable`, so a nineteenth
    /// case would otherwise be missing from both and the two would agree while both were wrong.
    func testIM6EveryErrorCaseMapsToItsOwnLandedSentence() throws {
        let declared = try Self.errorCaseNamesFromSource()
        XCTAssertEqual(declared, Self.allErrorCases.map(\.description), """
            InventoryPostingError declares a different set of cases than this suite lists.
            declared but unlisted: \(Set(declared).subtracting(Self.allErrorCases.map(\.description)).sorted())
            listed but undeclared: \(Set(Self.allErrorCases.map(\.description)).subtracting(declared).sorted())
            """)
        XCTAssertEqual(declared.count, 18)

        let mapped = Self.allErrorCases.map(InventoryPageComposition.key(for:))
        XCTAssertEqual(Set(mapped).count, Self.allErrorCases.count, "two cases share a sentence")
        for language in languages {
            let landed = Set(try sourceTable(language).keys.filter {
                $0.hasPrefix("inventory.error.")
            })
            XCTAssertEqual(landed, Set(mapped), """
                \(language): the error copy and the error cases disagree.
                copy with no case: \(landed.subtracting(mapped).sorted())
                case with no copy: \(Set(mapped).subtracting(landed).sorted())
                """)
        }
        // The banner draws exactly one sentence, and only when there is a refusal to report.
        for error in Self.allErrorCases {
            let page = InventoryPageComposition.compose(.init(products: [choice()],
                                                              selectedProductID: "p1",
                                                              error: error))
            XCTAssertEqual(page.errorKeys, [InventoryPageComposition.key(for: error)])
        }
        XCTAssertEqual(InventoryPageComposition.compose(.init()).errorKeys, [])
    }

    /// The two other closed sets the page maps: the eight kinds and the three exception records.
    func testIM6bEveryKindAndEveryExceptionRecordHasItsOwnSentence() throws {
        let typeKeys = InventoryMovementType.allCases.map(InventoryPageComposition.key(for:))
        XCTAssertEqual(Set(typeKeys).count, 8, "two kinds share a label")
        let kindKeys = InventoryExceptionKind.allCases.map(InventoryPageComposition.key(for:))
        XCTAssertEqual(Set(kindKeys).count, 3, "two exception records share a sentence")
        for language in languages {
            let table = try sourceTable(language)
            XCTAssertEqual(Set(table.keys.filter { $0.hasPrefix("inventory.type.") }),
                           Set(typeKeys))
            XCTAssertEqual(Set(table.keys.filter { $0.hasPrefix("inventory.exception.") })
                            .subtracting(["inventory.exception.title"]),
                           Set(kindKeys))
        }
    }

    // MARK: - IM7 — no two keys in one slot read the same

    func testIM7NoTwoKeysInOneSlotRenderTheSameLabel() {
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

    /// Four things can be on screen at once and live in four different regions, which is exactly
    /// why the slot buckets above cannot see a collision between them: the refusal, the opening
    /// advice, the note under the list, and every exception sentence.
    func testIM7bTheSentencesThatShareTheScreenNeverReadTheSame() {
        let keys = Self.allErrorCases.map(InventoryPageComposition.key(for:))
            + ["inventory.empty.noOpening.title", "inventory.empty.noOpening.message"]
            + ["inventory.reverse.onlyLastNote", "inventory.exception.title"]
            + InventoryExceptionKind.allCases.map(InventoryPageComposition.key(for:))
        for language in languages {
            var seen: [String: String] = [:]
            for key in keys {
                let rendered = value(language, key)
                if let other = seen[rendered] {
                    XCTFail("\(language): “\(rendered)” is rendered by both \(other) and \(key)")
                }
                seen[rendered] = key
            }
        }
    }

    // ==============================================================================================
    // MARK: - IM8 — the page is reachable, by exactly one route
    // ==============================================================================================

    /// N-PR-4 asserted NONE. N-PR-6 makes the page reachable, so this becomes exactly ONE — the
    /// shape `ProductsView`'s PM8 has had since 2b-A4 and `ReportsView`'s D19 since P3e.
    ///
    /// Split in two, each carrying its own proposition rather than two restatements of one: the
    /// route half is here, the sidebar half is `IM8b` below.
    func testIM8TheInventoryPageIsConstructedExactlyOnceAndByTheDetailSwitch() throws {
        let sources = try Self.appSources()
        XCTAssertGreaterThan(sources.count, 10, "the scan must have seen the app target")
        XCTAssertEqual(Self.mentions(of: "InventoryView(", in: sources),
                       ["Views/RootView.swift"],
                       "the inventory page must be constructed exactly once, by the detail switch")
        // The wizard is constructed by the page, once. Mounting the sheet inside the page is what
        // makes it one mount rather than a second entry point to keep in step — and now that the
        // page has a route of its own, that single mount is what carries the wizard to the user.
        XCTAssertEqual(Self.mentions(of: "InventoryOpeningView(", in: sources),
                       ["Views/InventoryView.swift"],
                       "the wizard is mounted exactly once, by the page it belongs to")

        // The composition is consumed by the page and driven by the model. Since N-PR-5b the
        // wizard's two files name it too — deliberately, and for one reason: that type owns the
        // three integer scales and the single display rounding N-8 requires to live in one place.
        // A second copy of `ticksAwayFromZero` would break that rule in the way that is hardest to
        // notice, so the coupling is declared here rather than avoided. The wizard's composition
        // uses the text PARSER, its view uses the FORMATTER, and neither has a copy of either.
        XCTAssertEqual(Self.mentions(of: "InventoryPageComposition", in: sources),
                       ["App/AppModel.swift", "App/InventoryOpeningComposition.swift",
                        "App/InventoryPageComposition.swift", "Views/InventoryOpeningView.swift",
                        "Views/InventoryView.swift"])
        XCTAssertEqual(Self.mentions(of: "InventoryFormDraft", in: sources),
                       ["App/AppModel.swift", "App/InventoryPageComposition.swift"])

        // …and that one construction is the `.inventory` branch, not a stray call elsewhere in
        // the file. Both counts are asserted: the branch text pins WHERE, the bare needle pins
        // that there is no second call the branch text would not have seen.
        let root = try Self.appSource("Views/RootView.swift")
        XCTAssertEqual(Self.occurrences(of: "case .inventory: InventoryView()", inCodeOf: root), 1,
                       "the one call site must be the `.inventory` branch of the detail switch")
        XCTAssertEqual(Self.occurrences(of: "case .inventory", inCodeOf: root), 1)
        XCTAssertEqual(Self.occurrences(of: "InventoryView(", inCodeOf: root), 1)

        // The scanner is proved on synthetic text: a hit that is really there, one that is only a
        // comment, and a longer identifier that must not match.
        XCTAssertEqual(Self.mentions(of: "InventoryView(",
                                     in: [("X.swift", "  InventoryView()")]), ["X.swift"])
        XCTAssertEqual(Self.mentions(of: "InventoryView(",
                                     in: [("X.swift", "  // InventoryView() in a comment")]), [])
        XCTAssertEqual(Self.mentions(of: "InventoryView(",
                                     in: [("X.swift", "  InventoryViewModel()")]), [],
                       "whole-prefix matching only")
    }

    /// The sidebar half of the route, and its own proposition: the case exists, in the adjudicated
    /// position, and carries the copy key the enum's own convention implies.
    ///
    /// Position is asserted as an ORDERED list because it is what the user sees: the sidebar list
    /// and the menu-bar picker both iterate `allCases` in declaration order, so one case is both
    /// entry points at once.
    ///
    /// The icon is pinned as a LITERAL, and this is the one place the inventory entry departs from
    /// `ProductMountingTests` PM8b: that test pins the sidebar symbol equal to the products page's
    /// own empty state. This page's empty state draws `tray.full` — the empty shelf — while the
    /// sidebar symbol is adjudicated separately (N1 §7.1). Asserting them equal would state
    /// something false, so what is pinned here is the adjudicated value itself.
    ///
    /// The label behind `titleKey` is owned elsewhere: `InventoryCopyTests` IC13 proves it resolves
    /// in six languages, equals the page's own title verbatim, and reads unlike every other sidebar
    /// row — which is why there is no six-language loop here.
    func testIM8bTheSidebarCarriesTheInventoryEntryInItsAdjudicatedPlace() {
        XCTAssertEqual(SidebarSection.allCases.map(\.rawValue),
                       ["overview", "transactions", "categories", "products", "inventory",
                        "reports"],
                       "stock reads after the products it counts; reports stay last")
        XCTAssertEqual(SidebarSection(rawValue: "inventory"), .inventory)
        XCTAssertEqual(SidebarSection.inventory.titleKey, "nav.inventory")
        XCTAssertEqual(SidebarSection.inventory.systemImage, "shippingbox.and.arrow.backward")
    }

    // MARK: - IM9 — no spinner, no comment the scanners cannot see, no copy of its own

    func testIM9ThePageDrawsNoSpinnerAndHoldsNoCopyOfItsOwn() throws {
        for relative in ["Views/InventoryView.swift", "App/InventoryPageComposition.swift"] {
            let source = try Self.appSource(relative)
            XCTAssertFalse(source.contains("ProgressView"), "\(relative) must not show a spinner")
            XCTAssertFalse(source.contains("/*"),
                           "\(relative): block comments hide code from the guards")
        }
        let view = try Self.appSource("Views/InventoryView.swift")
        for key in InventoryPageComposition.placement.keys {
            XCTAssertFalse(view.contains("\"\(key)\""), "InventoryView names \(key) directly")
        }
        // The wider form is the one that matters, and it is why the accessibility identifiers are
        // spelled `inventoryPage.` — `"inventory.table"` would read to every scanner as the view
        // having grown its own source of strings.
        XCTAssertFalse(view.contains("\"inventory."),
                       "InventoryView holds a literal in the copy's namespace")
        XCTAssertTrue(view.contains("\"inventoryPage.table\""),
                      "the table's identifier moved — is the prefix rule still being followed?")
    }

    // ==============================================================================================
    // MARK: - IM13 — no cell of the table may look the model up for itself
    // ==============================================================================================

    /// `Table` materialises its cell views AGAIN, outside the render pass, when an accessibility
    /// client walks the page. The environment is not attached there, so an `@EnvironmentObject`
    /// inside a cell traps: `Fatal error: No ObservableObject of type AppModel found`. It killed
    /// the app on the products page under a VoiceOver traversal, and this page's exposure is
    /// larger — a whole movement history with no paging, and a second block on screen beside the
    /// table.
    ///
    /// The rule is structural: the enclosing table reads the model once, while the environment is
    /// guaranteed, and hands the cells resolved text and intent closures.
    func testIM13NoTableCellViewLooksUpTheEnvironmentObject() throws {
        let source = try Self.appSource("Views/InventoryView.swift")
        let cells = ["InventoryTextCell", "InventoryAmountCell", "InventoryStatusCell",
                     "InventoryRowActions"]
        for cell in cells {
            let body = try Self.structBody(named: cell, in: source)
            XCTAssertFalse(Self.namesIdentifier("EnvironmentObject", in: body), """
                \(cell) looks the model up for itself. A table cell is rebuilt outside the \
                environment during an accessibility traversal, where that lookup is fatal — take \
                resolved values from InventoryMovementTable instead.
                """)
            XCTAssertTrue(Self.occurrences(of: "\(cell)(", inCodeOf: source) >= 1,
                          "\(cell) is no longer constructed — is this list stale?")
        }
        // The enclosing table is where the one lookup belongs, so the guard is not satisfied by a
        // file that simply stopped reading the model at all.
        XCTAssertTrue(Self.namesIdentifier("EnvironmentObject",
                                           in: try Self.structBody(named: "InventoryMovementTable",
                                                                   in: source)),
                      "InventoryMovementTable is the one place the cells' text may be resolved")

        // The parser is proved on synthetic text, or "no hits" and "it cannot see them" look the
        // same. Whole-identifier matching: `EnvironmentObjectish` is not a hit.
        XCTAssertTrue(Self.namesIdentifier("EnvironmentObject",
                                           in: "  @EnvironmentObject var model: AppModel"))
        XCTAssertFalse(Self.namesIdentifier("EnvironmentObject", in: "  let x = EnvironmentObjectish"))
        XCTAssertEqual(try Self.structBody(named: "Probe", in: "struct Probe: View { let a = 1 }"),
                       " let a = 1 ")
    }

    // ==============================================================================================
    // MARK: - IM10 — the three scales, and the one rounding
    // ==============================================================================================

    /// Quantity and amounts are EXACT conversions: `quantityMilli` already is three decimals and a
    /// minor unit already is two. Only the average is rounded, and it is rounded away from zero on
    /// integers rather than through a `Double`, whose 2^53 is well inside `Int64`.
    func testIM10TheQuantityAndAmountConversionsAreExactAndTheAverageRoundsAwayFromZero() {
        XCTAssertEqual(InventoryPageComposition.quantityText(1_500, language: "en"), "1.500")
        XCTAssertEqual(InventoryPageComposition.quantityText(0, language: "en"), "0.000")
        XCTAssertEqual(InventoryPageComposition.quantityText(1, language: "en"), "0.001")
        XCTAssertEqual(InventoryPageComposition.amountText(12_345, language: "en"), "123.45")
        XCTAssertEqual(InventoryPageComposition.amountText(0, language: "en"), "0.00")
        XCTAssertEqual(InventoryPageComposition.amountText(-5, language: "en"), "-0.05")

        // 333_333_333 micro = 3.33333333 major → four decimals, truncated side of the tie.
        XCTAssertEqual(InventoryPageComposition.averageText(333_333_333, language: "en"), "3.3333")
        XCTAssertEqual(InventoryPageComposition.averageText(0, language: "en"), "0.0000")
        // The tie goes AWAY from zero, in both directions.
        XCTAssertEqual(InventoryPageComposition.averageText(5_000, language: "en"), "0.0001")
        XCTAssertEqual(InventoryPageComposition.averageText(4_999, language: "en"), "0.0000")
        XCTAssertEqual(InventoryPageComposition.averageText(-5_000, language: "en"), "-0.0001")
        // …and a value that rounds away to zero never keeps a minus sign.
        XCTAssertEqual(InventoryPageComposition.averageText(-1, language: "en"), "0.0000")

        // Four decimals rather than two, because two would show a real average as no average.
        XCTAssertEqual(InventoryPageComposition.averageText(40_000, language: "en"), "0.0004")
        XCTAssertEqual(InventoryPageComposition.Decimals.average, 4)

        // The rounding rule itself, on integers.
        XCTAssertEqual(InventoryPageComposition.ticksAwayFromZero(14_999, per: 10_000), 1)
        XCTAssertEqual(InventoryPageComposition.ticksAwayFromZero(15_000, per: 10_000), 2)
        XCTAssertEqual(InventoryPageComposition.ticksAwayFromZero(-15_000, per: 10_000), -2)
        XCTAssertEqual(InventoryPageComposition.ticksAwayFromZero(-14_999, per: 10_000), -1)
        XCTAssertEqual(InventoryPageComposition.ticksAwayFromZero(Int64.max, per: 10_000),
                       Int64.max / 10_000 + 1, "the largest input must not overflow")

        // Locale separators differ; the digits do not.
        for language in languages {
            XCTAssertEqual(InventoryPageComposition.quantityText(1_500, language: language)
                            .filter(\.isNumber), "1500")
            XCTAssertEqual(InventoryPageComposition.amountText(12_345, language: language)
                            .filter(\.isNumber), "12345")
            XCTAssertEqual(InventoryPageComposition.averageText(333_333_333, language: language)
                            .filter(\.isNumber), "33333")
        }
    }

    /// Typed text becomes a scaled integer EXACTLY or not at all. More digits than the scale can
    /// carry is a refusal, not a rounding, and a grouping separator is a refusal too.
    func testIM10bTypedNumbersAreReadExactlyOrRefused() {
        let quantity = InventoryPageComposition.Decimals.quantity
        XCTAssertEqual(InventoryPageComposition.scaled("10", decimals: quantity), 10_000)
        XCTAssertEqual(InventoryPageComposition.scaled("1.5", decimals: quantity), 1_500)
        XCTAssertEqual(InventoryPageComposition.scaled("0.001", decimals: quantity), 1)
        XCTAssertEqual(InventoryPageComposition.scaled(" 2 ", decimals: quantity), 2_000)
        XCTAssertEqual(InventoryPageComposition.scaled("-1.5", decimals: quantity), -1_500)
        XCTAssertEqual(InventoryPageComposition.scaled("+3", decimals: quantity), 3_000)
        XCTAssertEqual(InventoryPageComposition.scaled(".5", decimals: quantity), 500)
        XCTAssertEqual(InventoryPageComposition.scaled("0", decimals: quantity), 0)

        for refused in ["", "   ", "abc", "1,000", "1 000", "1.2.3", "1e3", "٣", "1.0001", "-"] {
            XCTAssertNil(InventoryPageComposition.scaled(refused, decimals: quantity),
                         "\(refused.debugDescription) must not be read as a quantity")
        }
        // A number too large for the scale is refused rather than wrapped.
        XCTAssertNil(InventoryPageComposition.scaled("99999999999999999999", decimals: quantity))

        // The unit-cost field is a major-currency price and `unitCostMicro` is 1e8 of it, so eight
        // digits are exactly representable and a ninth is not.
        XCTAssertEqual(InventoryPageComposition.scaled("12.5", decimals: 8), 1_250_000_000)
        XCTAssertEqual(InventoryPageComposition.scaled("0", decimals: 8), 0)
        XCTAssertNil(InventoryPageComposition.scaled("0.123456789", decimals: 8))
    }

    // ==============================================================================================
    // MARK: - IM11 — which fields a kind asks for
    // ==============================================================================================

    /// Exhaustive over the eight kinds, and the expectation is derived from the ENGINE'S OWN
    /// vocabulary rather than from a table written here: a hand-written table would agree with a
    /// hand-written implementation while both drifted away from what the engine accepts.
    func testIM11EveryKindShowsExactlyTheFieldsTheEngineAsksItFor() {
        XCTAssertEqual(InventoryMovementType.allCases.count, 8)
        for type in InventoryMovementType.allCases {
            let fields = InventoryPageComposition.fields(for: type)
            let movesQuantity = type.direction != .costOnly
            XCTAssertEqual(fields.showsQuantity, movesQuantity, "\(type.rawValue) quantity")
            XCTAssertEqual(fields.showsUnitCost, type.direction == .inbound && !type.isReturn,
                           "\(type.rawValue) unit cost")
            XCTAssertEqual(fields.showsCostDelta, type.direction == .costOnly,
                           "\(type.rawValue) cost delta")

            let page = InventoryPageComposition.compose(stocked(form: draft(type)))
            let block = page.form
            XCTAssertEqual(block?.quantityLabelKey != nil, fields.showsQuantity)
            XCTAssertEqual(block?.quantityPlaceholderKey != nil, fields.showsQuantity)
            XCTAssertEqual(block?.unitCostLabelKey != nil, fields.showsUnitCost)
            XCTAssertEqual(block?.unitCostHintKey != nil, fields.showsUnitCost)
            XCTAssertEqual(block?.costDeltaLabelKey != nil, fields.showsCostDelta)
            XCTAssertEqual(block?.costDeltaHintKey != nil, fields.showsCostDelta)
            XCTAssertEqual(block?.typeOptions.count, 8, "the control offers the whole vocabulary")
        }
        // The three shapes, named.
        XCTAssertTrue(InventoryPageComposition.fields(for: .purchaseIn).showsUnitCost)
        XCTAssertTrue(InventoryPageComposition.fields(for: .countGain).showsUnitCost,
                      "a count gain may not quietly borrow the average")
        XCTAssertFalse(InventoryPageComposition.fields(for: .saleOut).showsUnitCost,
                       "an issue is costed at the average in force before it")
        XCTAssertFalse(InventoryPageComposition.fields(for: .saleReturnIn).showsUnitCost,
                       "a return takes its basis from the origin document")
        XCTAssertFalse(InventoryPageComposition.fields(for: .purchaseReturnOut).showsUnitCost)
        XCTAssertFalse(InventoryPageComposition.fields(for: .manualAdjust).showsQuantity,
                       "a cost adjustment moves no quantity at all")
    }

    /// A field the panel is not showing is not consulted, so text left in a hidden one can never
    /// reach the ledger.
    func testIM11bAHiddenFieldNeverTravelsToTheLedger() throws {
        var adjust = draft(.manualAdjust)
        adjust.quantityText = "999"
        adjust.unitCostText = "77"
        adjust.costDeltaText = "-1.25"
        let request = try XCTUnwrap(adjust.request(productID: "p1", currency: "CNY"))
        XCTAssertEqual(request.quantityMilli, 0, "the hidden quantity was passed through")
        XCTAssertNil(request.unitCostMicro)
        XCTAssertEqual(request.costDeltaMinor, -125)

        var issue = draft(.saleOut)
        issue.quantityText = "2"
        issue.unitCostText = "500"
        let issued = try XCTUnwrap(issue.request(productID: "p1", currency: "CNY"))
        XCTAssertEqual(issued.quantityMilli, 2_000)
        XCTAssertNil(issued.unitCostMicro, "an issue must not carry a price of its own")
        XCTAssertNil(issued.costDeltaMinor)

        // A shown field that cannot be read means nothing is postable at all.
        var receipt = draft(.purchaseIn)
        receipt.quantityText = "1"
        XCTAssertNil(receipt.request(productID: "p1", currency: "CNY"),
                     "an empty unit cost is not a zero")
        XCTAssertFalse(receipt.isPostable)
        receipt.unitCostText = "0"
        XCTAssertNotNil(receipt.request(productID: "p1", currency: "CNY"),
                        "zero IS a legal price — a free sample")
        XCTAssertTrue(receipt.isPostable)
        receipt.quantityText = "0"
        XCTAssertNil(receipt.request(productID: "p1", currency: "CNY"),
                     "a quantity-moving movement needs a positive quantity")

        // The source travels as a pair, or not at all: the engine finds an origin by both halves.
        var sourced = draft(.purchaseIn)
        sourced.quantityText = "1"
        sourced.unitCostText = "1"
        XCTAssertNil(try XCTUnwrap(sourced.request(productID: "p1", currency: "CNY")).sourceType)
        sourced.sourceText = " PO-9 "
        let withSource = try XCTUnwrap(sourced.request(productID: "p1", currency: "CNY"))
        XCTAssertEqual(withSource.sourceType, InventoryPageComposition.manualSourceType)
        XCTAssertEqual(withSource.sourceID, "PO-9")
    }

    // ==============================================================================================
    // MARK: - IM12 — the empty renders, and what they are each true of
    // ==============================================================================================

    /// Four states, four different things to say. The two empty sentences are mutually exclusive
    /// and neither shares the screen with a list; the opening advice is not an empty state at all
    /// — it is true exactly while an opening is still legal, which is why it can appear beside a
    /// list of rows that have all been reversed away.
    func testIM12TheEmptyRendersAreMutuallyExclusiveAndTheOpeningAdviceIsNot() {
        let history = fullHistory()
        let reversedAway = InventoryPageComposition.Input(
            products: [choice()], selectedProductID: "p1",
            balance: balance(quantityMilli: 0, costBalanceMinor: 0, unitCostMicro: 0),
            movements: [movement("m0", type: .purchaseIn),
                        movement("rx", type: .purchaseIn, seq: 2, reverses: "m0")],
            liveIDs: [])

        let cases: [(InventoryPageComposition.Input, hasList: Bool, hasCard: Bool,
                     empty: Int, opening: Int)] = [
            (.init(), false, false, 2, 0),
            (.init(products: [choice()], selectedProductID: "p1"), false, false, 2, 2),
            (reversedAway, true, true, 0, 2),
            (stocked(), true, true, 0, 0),
        ]
        for (input, hasList, hasCard, empty, opening) in cases {
            let page = InventoryPageComposition.compose(input)
            XCTAssertEqual(page.list != nil, hasList)
            XCTAssertEqual(page.balance != nil, hasCard)
            XCTAssertEqual(page.emptyKeys.count, empty)
            XCTAssertEqual(page.openingHintKeys.count, opening)
            XCTAssertFalse(page.list != nil && !page.emptyKeys.isEmpty,
                           "a list and an empty state at once")
            XCTAssertFalse(page.balance != nil && !page.emptyKeys.isEmpty,
                           "a balance card and an empty state at once")
        }
        // The two empty sentences are never the same one.
        XCTAssertEqual(InventoryPageComposition.compose(.init()).emptyKeys,
                       ["inventory.empty.noProduct.title", "inventory.empty.noProduct.message"])
        XCTAssertEqual(InventoryPageComposition.compose(
            .init(products: [choice()], selectedProductID: "p1")).emptyKeys,
                       ["inventory.empty.noMovement.title", "inventory.empty.noMovement.message"])
        XCTAssertEqual(history.liveIDs.count, 7, "the fixture's live set is the first seven rows")
    }

    /// The reverse control is offered on the last live row and on no other, because that is the
    /// only row the engine will accept a reversal for.
    func testIM12bOnlyTheLastLiveRowOffersTheReverseControl() {
        let page = InventoryPageComposition.compose(stocked())
        let list = page.list
        let offered = (list?.rows ?? []).filter { $0.reverseActionKey != nil }.map(\.id)
        XCTAssertEqual(offered, ["m6"], "the last LIVE row, not the last row in the list")
        XCTAssertEqual(list?.rows.last?.id, "r0", "the list still ends with the reversal row")
        XCTAssertNotNil(list?.onlyLastNoteKey, "and the note explains why the others have none")

        // The three statuses, derived from the engine's own live set.
        let byID = Dictionary(uniqueKeysWithValues: (list?.rows ?? []).map { ($0.id, $0) })
        XCTAssertEqual(byID["m0"]?.status, .posted)
        XCTAssertEqual(byID["m7"]?.status, .reversed)
        XCTAssertEqual(byID["r0"]?.status, .reversal)
        XCTAssertEqual(byID["m0"]?.isSuperseded, false)
        XCTAssertEqual(byID["m7"]?.isSuperseded, true)
        XCTAssertEqual(byID["r0"]?.isSuperseded, true)
    }

    /// The store returns exception records ordered by their own identifier, which is a fresh UUID
    /// and means nothing on screen. They are drawn in the order of the movements they belong to.
    func testIM12cTheExceptionListFollowsTheMovementsAndNotTheStoredOrder() {
        let page = InventoryPageComposition.compose(stocked(exceptions: [
            exception("zzz", .openingSeeded, movementID: "m7"),
            exception("aaa", .returnOriginNotFound, movementID: "m2"),
            exception("mmm", .manualAdjust, movementID: nil),
        ]))
        let block = page.exceptions
        XCTAssertEqual(block?.rows.map(\.id), ["aaa", "zzz", "mmm"],
                       "ordered by their movement; the one with no movement comes last")
        XCTAssertNil(InventoryPageComposition.compose(stocked()).exceptions,
                     "no records, no heading")
    }

    // ==============================================================================================
    // MARK: - IM14 — every write refreshes the read model, and it is really on disk
    // ==============================================================================================

    func testIM14APostingLandsInTheBalanceAndTheList() async throws {
        let model = try await bootedModel()
        let store = try XCTUnwrap(model.store)
        let id = try store.createProduct(name: "Steel plate", unit: "kg")
        model.reloadInventory()

        XCTAssertEqual(model.inventoryProductID, id, "a product is always selected while one exists")
        let before = InventoryPageComposition.compose(model.inventoryInput)
        XCTAssertNil(before.balance)
        XCTAssertNil(before.list)
        XCTAssertEqual(before.emptyKeys.count, 2)
        XCTAssertEqual(before.openingHintKeys.count, 2)

        model.newInventoryMovement()
        model.inventoryForm?.occurredOn = "2026-01-10"
        model.inventoryForm?.quantityText = "10"
        model.inventoryForm?.unitCostText = "12.5"
        model.submitInventoryForm()

        XCTAssertNil(model.inventoryForm, "an accepted posting closes the panel")
        XCTAssertNil(model.inventoryError)
        let after = InventoryPageComposition.compose(model.inventoryInput)
        let card = try XCTUnwrap(after.balance, "the balance card was not refreshed")
        XCTAssertEqual(card.quantityMilli, 10_000)
        XCTAssertEqual(card.costBalanceMinor, 12_500)
        XCTAssertEqual(card.unitCostMicro, 1_250_000_000)
        XCTAssertEqual(after.list?.rows.count, 1, "the list was not reloaded after the posting")
        XCTAssertEqual(after.list?.rows.first?.status, .posted)
        XCTAssertTrue(after.emptyKeys.isEmpty)
        XCTAssertTrue(after.openingHintKeys.isEmpty, "there is a live movement now")
    }

    func testIM14BReversingLandsInTheBalanceAndTheList() async throws {
        let model = try await bootedModel()
        let store = try XCTUnwrap(model.store)
        _ = try store.createProduct(name: "Steel plate", unit: "kg")
        model.reloadInventory()
        try post(model, quantity: "10", unitCost: "12.5")

        let target = try XCTUnwrap(model.inventoryRows.first)
        model.requestInventoryReversal(target.id)
        XCTAssertNotNil(InventoryPageComposition.compose(model.inventoryInput).reverse)
        model.confirmInventoryReversal()

        XCTAssertNil(model.inventoryError)
        XCTAssertNil(model.pendingInventoryReversal)
        let after = InventoryPageComposition.compose(model.inventoryInput)
        let card = try XCTUnwrap(after.balance)
        XCTAssertEqual(card.quantityMilli, 0, "the balance did not come back")
        XCTAssertEqual(card.costBalanceMinor, 0)
        XCTAssertEqual(card.unitCostMicro, 0)
        XCTAssertEqual(after.list?.rows.count, 2, "the reversal row was not added to the list")
        XCTAssertEqual(after.list?.rows.map(\.status), [.reversed, .reversal])
        XCTAssertEqual(after.openingHintKeys.count, 2, "an opening is legal again")
        XCTAssertTrue(after.emptyKeys.isEmpty, "there are still rows to show")
        // Dated on the movement it undoes, so the control can never be refused for a future row.
        XCTAssertEqual(model.inventoryRows.last?.occurredOn, target.occurredOn)
    }

    func testIM14CARefusedPostingChangesNothingOnScreen() async throws {
        let model = try await bootedModel()
        let store = try XCTUnwrap(model.store)
        _ = try store.createProduct(name: "Steel plate", unit: "kg")
        model.reloadInventory()
        try post(model, quantity: "10", unitCost: "12.5")

        let rowsBefore = model.inventoryRows
        let balanceBefore = model.inventoryBalanceRow

        model.newInventoryMovement()
        model.selectInventoryFormType(InventoryMovementType.saleOut.rawValue)
        model.inventoryForm?.quantityText = "999"
        model.submitInventoryForm()

        XCTAssertEqual(model.inventoryError, .insufficientStock)
        XCTAssertEqual(InventoryPageComposition.compose(model.inventoryInput).errorKeys,
                       ["inventory.error.insufficientStock"])
        XCTAssertNotNil(model.inventoryForm, "a refused posting keeps the panel open")
        XCTAssertEqual(model.inventoryRows, rowsBefore, "nothing changed, so nothing was reloaded")
        XCTAssertEqual(model.inventoryBalanceRow, balanceBefore)

        model.cancelInventoryForm()
        model.dismissInventoryError()
        XCTAssertNil(model.inventoryError)
    }

    func testIM14DOnlyTheLastLiveMovementCanBeReversed() async throws {
        let model = try await bootedModel()
        let store = try XCTUnwrap(model.store)
        _ = try store.createProduct(name: "Steel plate", unit: "kg")
        model.reloadInventory()
        try post(model, quantity: "10", unitCost: "12.5", on: "2026-01-10")
        try post(model, quantity: "4", unitCost: "13", on: "2026-01-11")
        XCTAssertEqual(model.inventoryRows.count, 2)

        let first = try XCTUnwrap(model.inventoryRows.first)
        model.requestInventoryReversal(first.id)
        model.confirmInventoryReversal()

        XCTAssertEqual(model.inventoryError, .onlyTheLastMovementCanBeReversed)
        XCTAssertEqual(model.inventoryRows.count, 2, "a refused reversal wrote a row")
        // …and the page only ever offered the control on the other one.
        let page = InventoryPageComposition.compose(model.inventoryInput)
        XCTAssertEqual((page.list?.rows ?? []).filter { $0.reverseActionKey != nil }.count, 1)
        XCTAssertNotNil(page.list?.rows.last?.reverseActionKey)
    }

    func testIM14EOnlyOneUndecidedWriteAtATime() async throws {
        let model = try await bootedModel()
        let store = try XCTUnwrap(model.store)
        _ = try store.createProduct(name: "Steel plate", unit: "kg")
        model.reloadInventory()
        try post(model, quantity: "10", unitCost: "12.5")
        let row = try XCTUnwrap(model.inventoryRows.first)

        model.newInventoryMovement()
        XCTAssertTrue(model.inventoryWriteIsPending)
        model.requestInventoryReversal(row.id)
        XCTAssertNil(model.pendingInventoryReversal,
                     "a reversal may not start while the panel is open")

        model.cancelInventoryForm()
        model.requestInventoryReversal(row.id)
        XCTAssertNotNil(model.pendingInventoryReversal)
        model.newInventoryMovement()
        XCTAssertNil(model.inventoryForm, "the panel may not open while a reversal is pending")
        model.cancelInventoryReversal()
        XCTAssertFalse(model.inventoryWriteIsPending)
    }

    func testIM14FSelectingAnotherProductSwapsTheWholeReadModel() async throws {
        let model = try await bootedModel()
        let store = try XCTUnwrap(model.store)
        // Both take `create`'s own default sort order, so the catalogue's `ORDER BY is_active
        // DESC, sort_order, name` leaves them in name order — which is the order the picker shows
        // and therefore the one "the first product" means.
        let first = try store.createProduct(name: "Alpha", unit: "kg")
        let second = try store.createProduct(name: "Beta", unit: "box")
        model.reloadInventory()
        XCTAssertEqual(model.inventoryProducts.map(\.name), ["Alpha", "Beta"])
        XCTAssertEqual(model.inventoryProductID, first)
        XCTAssertEqual(model.inventoryUnit, .key("product.unit.kg"))
        try post(model, quantity: "10", unitCost: "12.5")

        model.selectInventoryProduct(second)
        XCTAssertEqual(model.inventoryProductID, second)
        XCTAssertEqual(model.inventoryUnit, .key("product.unit.box"))
        XCTAssertEqual(model.inventoryRows.count, 0, "the other product's rows came along")
        XCTAssertEqual(model.inventoryBalanceRow?.quantityMilli, 0)
        let page = InventoryPageComposition.compose(model.inventoryInput)
        XCTAssertEqual(page.emptyKeys.count, 2)
        XCTAssertEqual(page.openingHintKeys.count, 2)

        model.selectInventoryProduct(first)
        XCTAssertEqual(model.inventoryRows.count, 1)
        XCTAssertEqual(model.inventoryBalanceRow?.quantityMilli, 10_000)
    }

    /// The read model is the ledger's, not the model's memory: what a SECOND connection sees is
    /// what was really written, and what a second connection writes shows up as soon as the page
    /// reloads.
    func testIM14GTheLedgerAndNotTheMemoryIsWhatWasRead() async throws {
        let model = try await bootedModel()
        let store = try XCTUnwrap(model.store)
        let id = try store.createProduct(name: "Steel plate", unit: "kg")
        model.reloadInventory()
        try post(model, quantity: "10", unitCost: "12.5", on: "2026-01-10")

        let second = try LedgerStore(databaseURL: try XCTUnwrap(Self.ledgerURL))
        let landed = try second.inventoryBalance(productID: id)
        XCTAssertEqual(landed.quantityMilli, 10_000, "the posting is not on disk")
        XCTAssertEqual(landed.costBalanceMinor, 12_500)
        XCTAssertEqual(landed.unitCostMicro, 1_250_000_000)
        XCTAssertEqual(landed.currency, "CNY", "the regime's currency, frozen by the first receipt")
        XCTAssertEqual(try second.inventoryMovements(productID: id).count, 1)
        XCTAssertEqual(try second.inventoryMovements(productID: id).first?.sourceType, nil)

        // The other direction: a write the model has not been told about.
        _ = try second.postInventoryMovement(InventoryPostingRequest(
            productID: id, type: .saleOut, occurredOn: "2026-01-11", quantityMilli: 2_000,
            currency: "CNY"))
        XCTAssertEqual(model.inventoryRows.count, 1, "the model has not been told yet")
        model.reloadInventory()
        XCTAssertEqual(model.inventoryRows.count, 2)
        XCTAssertEqual(model.inventoryBalanceRow?.quantityMilli, 8_000)
        // An average-priced issue carries no price of its own, so its cell draws the em dash.
        let page = InventoryPageComposition.compose(model.inventoryInput)
        XCTAssertNil(page.list?.rows.last?.unitCostMicro)
    }

    // ==============================================================================================
    // MARK: - Helpers
    // ==============================================================================================

    /// Post one receipt through the model's own intents, so every test exercises the shipping path.
    private func post(_ model: AppModel, quantity: String, unitCost: String,
                      on occurredOn: String = "2026-01-10") throws {
        model.newInventoryMovement()
        model.inventoryForm?.occurredOn = occurredOn
        model.inventoryForm?.quantityText = quantity
        model.inventoryForm?.unitCostText = unitCost
        model.submitInventoryForm()
        XCTAssertNil(model.inventoryError, "the fixture posting was refused")
        XCTAssertNil(model.inventoryForm)
    }

    private func value(_ language: String, _ key: String) -> String {
        Localizer(language: language).t(key)
    }

    /// The COMMITTED `.strings` of a locale, parsed as the old-style property list it is.
    private func sourceTable(_ language: String) throws -> [String: String] {
        let url = Self.packageRoot()
            .appendingPathComponent("Sources/SoloLedger/Resources/\(language).lproj/Localizable.strings")
        let plist = try PropertyListSerialization.propertyList(from: try Data(contentsOf: url),
                                                              options: [], format: nil)
        return try XCTUnwrap(plist as? [String: String], "\(language) is not a string dictionary")
    }

    /// The `case` names declared by `InventoryPostingError`, read from the engine's own source in
    /// declaration order.
    private static func errorCaseNamesFromSource() throws -> [String] {
        let url = packageRoot()
            .appendingPathComponent("Sources/SoloLedgerCore/Inventory/InventoryModels.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "public enum InventoryPostingError"))
        let end = try XCTUnwrap(source.range(of: "\n    public var description",
                                             range: start.upperBound..<source.endIndex))
        var out: [String] = []
        for line in source[start.upperBound..<end.lowerBound].split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("case ") else { continue }
            out.append(String(text.dropFirst(5)).trimmingCharacters(in: .whitespaces))
        }
        XCTAssertGreaterThan(out.count, 10, "the case parser found almost nothing — it is broken")
        return out
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

    /// The brace-matched body of `struct <name>`, comments and all.
    private static func structBody(named name: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: "struct \(name)"), "no struct named \(name)")
        let open = try XCTUnwrap(source.range(of: "{", range: start.upperBound..<source.endIndex))
        var depth = 1
        var index = open.upperBound
        while index < source.endIndex, depth > 0 {
            if source[index] == "{" { depth += 1 }
            if source[index] == "}" { depth -= 1; if depth == 0 { break } }
            index = source.index(after: index)
        }
        XCTAssertEqual(depth, 0, "\(name) is unbalanced")
        return String(source[open.upperBound..<index])
    }

    /// Whether `identifier` appears as a WHOLE identifier on a non-comment line.
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

    /// How many times `needle` appears on non-comment lines of one file.
    private static func occurrences(of needle: String, inCodeOf source: String) -> Int {
        source.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) { total, line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("*"), !trimmed.hasPrefix("/*") else {
                return total
            }
            return total + (line.components(separatedBy: needle).count - 1)
        }
    }

    /// Which files mention `needle` on a non-comment line.
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

    /// Set by ``bootedModel()`` so a test can open a SECOND connection to the same file.
    private static var ledgerURL: URL?

    private var temporaryDirectory: URL?

    override func tearDownWithError() throws {
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
        Self.ledgerURL = nil
    }

    /// A model over a REAL temporary ledger, adopted through the same Phase-B seam the production
    /// chain uses, so the write path under test is the shipping one.
    private func bootedModel() async throws -> AppModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SLInventory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectory = directory
        let url = directory.appendingPathComponent("inventory.db")
        Self.ledgerURL = url

        let store = try LedgerStore(databaseURL: url, open: .createIfMissing)
        try store.settings.setString("CN", for: SettingsStore.Key.accountingLocale)
        let model = AppModel(runner: InventoryFakeRunner(store: store))
        model.boot()
        await model.currentBootTask?.value
        XCTAssertNotNil(model.store, "the fixture model must have adopted a store")
        return model
    }

    /// Drives one adoption through the real Phase-A/Phase-B seam.
    private final class InventoryFakeRunner: BootChainRunner {
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
