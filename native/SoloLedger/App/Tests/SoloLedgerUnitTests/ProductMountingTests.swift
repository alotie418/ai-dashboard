import XCTest
@testable import SoloLedger
import SoloLedgerCore

/// Stage 2b-A3 — where the products page puts things, what it refuses to say, and the single
/// route that opens it (2b-A4).
///
/// XCUITest is not available here (the runner hangs enabling automation mode in a headless
/// session), so "is it on screen" is answered structurally: the page is built from
/// ``ProductPageComposition`` and nothing else, and `ProductsView.swift` holds no `product.*`
/// literal at all, so asserting on the composition IS asserting on what the view can draw.
///
/// The two halves are checked separately, the way the report page's mounting tests do it — the
/// static placement table covers the whole namespace, and the per-input composition covers what
/// one render uses. What this file adds beyond that shape is the write path: the page has
/// controls, so the last group drives a real ledger and asserts the LIST changed, not just that
/// a flag flipped.
@MainActor
final class ProductMountingTests: XCTestCase {

    private let languages = ["zh-Hans", "zh-Hant", "en", "ja", "ko", "fr"]

    // MARK: - Fixtures

    private func product(id: String = "p1", name: String = "Widget", unit: String? = "piece",
                         cost: Double = 0, isService: Bool = false, isActive: Bool = true,
                         sortOrder: Int = 0) -> Product {
        Product(id: id, name: name, unit: unit, defaultUnitCost: cost,
                isService: isService, isActive: isActive, sortOrder: sortOrder)
    }

    private func catalog(_ products: [Product], unreadable: Int = 0) -> ProductCatalogPage {
        ProductCatalogPage(products: products, unreadableCount: unreadable)
    }

    /// One page per shape the composition can take. Between them they must draw every placed key.
    private func compositions() -> [ProductPageComposition.Page] {
        let rows = [product(id: "a", name: "Box", unit: "box", cost: 12.5),
                    product(id: "b", name: "Consulting", unit: "hour", cost: 0,
                            isService: true, isActive: false),
                    product(id: "c", name: "Crate", unit: "crate"),
                    product(id: "d", name: "Bytes", unit: nil)]
        var pages: [ProductPageComposition.Page] = [
            ProductPageComposition.compose(.init(catalog: catalog(rows))),
            // Nothing at all, and nothing unreadable either: the only shape that says "yet".
            ProductPageComposition.compose(.init(catalog: catalog([]))),
            // Rows exist but none of them decoded.
            ProductPageComposition.compose(.init(catalog: catalog([], unreadable: 3))),
            ProductPageComposition.compose(.init(catalog: catalog(rows, unreadable: 1))),
            ProductPageComposition.compose(.init(catalog: catalog(rows),
                                                 form: ProductFormDraft(editing: nil))),
            ProductPageComposition.compose(.init(catalog: catalog(rows),
                                                 form: ProductFormDraft(editing: rows[0]))),
            ProductPageComposition.compose(.init(catalog: catalog(rows),
                                                 pendingDelete: rows[0])),
        ]
        for error in Self.allErrors {
            pages.append(ProductPageComposition.compose(.init(catalog: catalog(rows),
                                                              error: error)))
        }
        return pages
    }

    /// Every `ProductCatalogError`. Kept honest by ``ProductPageComposition/key(for:)``, whose
    /// switch is exhaustive: an eighth case stops the production file compiling.
    private static let allErrors: [ProductCatalogError] = [
        .invalidID, .nameRequired, .unitNotRecognized, .notFound, .idCollision,
        .hasInventoryMovements, .storageFailure,
    ]

    /// Where one key sits: the region, plus the SLOT inside it.
    ///
    /// The slot is what makes the ambiguity check meaningful. Two column headings side by side
    /// are ambiguous if they read the same; a heading that reads like a form field label three
    /// regions away is not — they are the same key by design.
    private struct Slot: Hashable {
        let region: ProductPageComposition.Region
        let detail: String
    }

    private func placements(in page: ProductPageComposition.Page) -> [(key: String, slot: Slot)] {
        func slot(_ region: ProductPageComposition.Region, _ detail: String = "") -> Slot {
            Slot(region: region, detail: detail)
        }
        var out: [(String, Slot)] = [(page.titleKey, slot(.header))]
        out += page.headerKeys.map { ($0, slot(.header)) }
        out += page.noteKeys.map { ($0, slot(.note)) }
        out += page.actionKeys.map { ($0, slot(.action)) }
        out += page.errorKeys.map { ($0, slot(.errorBanner)) }
        out += page.emptyKeys.map { ($0, slot(.empty)) }
        out += page.unreadableKeys.map { ($0, slot(.unreadable)) }
        if let list = page.list {
            out += list.headerKeys.map { ($0, slot(.listHeader)) }
            for row in list.rows {
                out.append((row.typeKey, slot(.typeCell, "row:\(row.id)")))
                out.append((row.statusKey, slot(.statusCell, "row:\(row.id)")))
                out.append((row.toggleHintKey, slot(.statusCell, "row:\(row.id)")))
                if case .key(let unitKey) = row.unit {
                    out.append((unitKey, slot(.unitCell, "row:\(row.id)")))
                }
                out += row.actionKeys.map { ($0, slot(.rowAction, "row:\(row.id)")) }
            }
        }
        if let form = page.form {
            out.append((form.titleKey, slot(.form, "title")))
            out += form.fieldLabelKeys.map { ($0, slot(.form, "fields")) }
            out.append((form.placeholderKey, slot(.form, "placeholder")))
            out.append((form.serviceLabelKey, slot(.form, "service")))
            out.append((form.serviceHintKey, slot(.form, "service")))
            out += form.unitOptions.map { ($0.labelKey, slot(.unitPicker)) }
            out += form.actionKeys.map { ($0, slot(.form, "actions")) }
        }
        if let block = page.delete {
            out.append((block.titleKey, slot(.deleteDialog, "title")))
            out.append((block.messageKey, slot(.deleteDialog, "message")))
            out += block.actionKeys.map { ($0, slot(.deleteDialog, "actions")) }
        }
        return out.map { (key: $0.0, slot: $0.1) }
    }

    // ==============================================================================================
    // MARK: - PM1 — the placement table is the adjudicated namespace, in both directions
    // ==============================================================================================

    func testPM1ThePlacementTableIsExactlyTheFortyAdjudicatedKeys() throws {
        let placed = Set(ProductPageComposition.placement.keys)
        XCTAssertEqual(placed.count, 41, "2b-A2 adjudicated forty product.* keys; N-PR-3 adds the seventh error case")
        for language in languages {
            let landed = Set(try sourceTable(language).keys.filter { $0.hasPrefix("product.") })
            XCTAssertEqual(landed, placed, """
                \(language): the copy and the page's placement table disagree.
                written but never drawn: \(landed.subtracting(placed).sorted())
                drawn but never written: \(placed.subtracting(landed).sorted())
                """)
        }
        // And the page title is one of them rather than a literal hiding in the view.
        XCTAssertTrue(placed.contains(ProductPageComposition.pageTitleKey))
    }

    // MARK: - PM2 — every region is used and every key has one

    func testPM2EveryRegionIsUsedAndEveryKeyHasAtLeastOne() {
        var byRegion: [ProductPageComposition.Region: [String]] = [:]
        for (key, regions) in ProductPageComposition.placement {
            XCTAssertFalse(regions.isEmpty, "\(key) is placed nowhere")
            for region in regions { byRegion[region, default: []].append(key) }
        }
        for (key, regions) in ProductPageComposition.sharedKeys {
            XCTAssertFalse(regions.isEmpty, "\(key) is placed nowhere")
            for region in regions { byRegion[region, default: []].append(key) }
        }
        for region in ProductPageComposition.Region.allCases {
            XCTAssertFalse((byRegion[region] ?? []).isEmpty, "\(region) has no keys")
        }
        // The three column headings that are also form field labels, and the eleven unit labels
        // that are also picker options, are the reason this map is a Set per key.
        XCTAssertEqual(ProductPageComposition.placement["product.col.name"], [.listHeader, .form])
        XCTAssertEqual(ProductPageComposition.placement["product.unit.kg"], [.unitCell, .unitPicker])
        XCTAssertEqual(ProductPageComposition.placement["product.col.type"], [.listHeader])
    }

    // MARK: - PM3 — every placed key is drawn by some render

    /// A key placed but never composed is copy nobody can reach; a key composed but not placed
    /// would resolve on screen with nothing accounting for it.
    func testPM3EveryPlacedKeyIsDrawnBySomeRenderAndViceVersa() {
        var drawn: Set<String> = []
        for page in compositions() { drawn.formUnion(page.allKeys) }
        let placed = Set(ProductPageComposition.placement.keys)
        let shared = Set(ProductPageComposition.sharedKeys.keys)
        XCTAssertEqual(drawn, placed.union(shared), """
            placed but never drawn: \(placed.union(shared).subtracting(drawn).sorted())
            drawn but not placed:   \(drawn.subtracting(placed.union(shared)).sorted())
            """)
    }

    // MARK: - PM4 — a composed key lands in a region it was declared for

    func testPM4EveryComposedKeyLandsInADeclaredRegion() {
        for page in compositions() {
            for (key, slot) in placements(in: page) {
                let declared = ProductPageComposition.placement[key]
                    ?? ProductPageComposition.sharedKeys[key]
                guard let declared else {
                    XCTFail("\(key) is composed but declared nowhere"); continue
                }
                XCTAssertTrue(declared.contains(slot.region),
                              "\(key) is drawn in \(slot.region), declared \(declared.sorted(by: { $0.rawValue < $1.rawValue }))")
            }
        }
    }

    // MARK: - PM5 — the borrowed vocabulary is exactly four keys, and stays outside the namespace

    /// `sharedKeys` is kept out of `placement` so PM1 can compare that map to the namespace as an
    /// equality rather than as a filtered subset. This is what keeps the two tables from merging
    /// by accident.
    func testPM5TheSharedKeysAreFourAndNoneOfThemIsAProductKey() {
        let shared = ProductPageComposition.sharedKeys
        XCTAssertEqual(Set(shared.keys),
                       ["common.edit", "common.delete", "common.cancel", "common.save"])
        for key in shared.keys {
            XCTAssertFalse(key.hasPrefix("product."), "\(key) belongs in placement, not here")
            XCTAssertNil(ProductPageComposition.placement[key], "\(key) is in both tables")
            for language in languages {
                XCTAssertNotEqual(value(language, key), key, "\(language)/\(key) leaks the raw key")
            }
        }
    }

    // MARK: - PM6 — every refusal has exactly one sentence, and it is the production mapping

    /// The switch lives in `ProductPageComposition` and this test READS it. 2b-A2 kept a copy of
    /// the mapping in its own file because there was no production one yet; keeping two would let
    /// the shipped mapping change while the test went on agreeing with itself.
    func testPM6EveryErrorCaseMapsToItsOwnLandedSentence() throws {
        let mapped = Self.allErrors.map(ProductPageComposition.key(for:))
        XCTAssertEqual(Set(mapped).count, Self.allErrors.count, "two cases share a sentence")
        for language in languages {
            let landed = Set(try sourceTable(language).keys.filter {
                $0.hasPrefix("product.error.")
            })
            XCTAssertEqual(landed, Set(mapped), """
                \(language): the error copy and the error cases disagree.
                copy with no case: \(landed.subtracting(mapped).sorted())
                case with no copy: \(Set(mapped).subtracting(landed).sorted())
                """)
        }
        // The banner draws exactly one sentence, and only when there is a refusal to report.
        for error in Self.allErrors {
            let page = ProductPageComposition.compose(.init(catalog: catalog([]), error: error))
            XCTAssertEqual(page.errorKeys, [ProductPageComposition.key(for: error)])
        }
        XCTAssertEqual(ProductPageComposition.compose(.init(catalog: catalog([]))).errorKeys, [])
    }

    // MARK: - PM7 — no two keys in one slot read the same

    func testPM7NoTwoKeysInOneSlotRenderTheSameLabel() {
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

    /// The refusal banner and the unreadable notice can be on screen together — one reports a
    /// write that was refused, the other a read that did not decode — so they must not read the
    /// same. They live in different regions, which is exactly why the slot buckets above cannot
    /// see the collision.
    func testPM7bTheRefusalAndTheUnreadableNoticeNeverReadTheSame() {
        let keys = Self.allErrors.map(ProductPageComposition.key(for:)) + ["product.unreadable.notice"]
        for language in languages {
            var seen: [String: String] = [:]
            for key in keys {
                // The notice carries {count}; compare the filled sentence, since that is what is
                // on screen next to the refusal.
                let rendered = Localizer(language: language).t(key, ["count": "3"])
                if let other = seen[rendered] {
                    XCTFail("\(language): “\(rendered)” is rendered by both \(other) and \(key)")
                }
                seen[rendered] = key
            }
        }
    }

    // ==============================================================================================
    // MARK: - PM8 — the page is reachable, by exactly one route
    // ==============================================================================================

    /// 2b-A3 asserted NONE. 2b-A4 makes the page reachable, so this becomes exactly ONE — the
    /// shape `ReportsView`'s own D19 has had since P3e.
    ///
    /// Split into four assertions below, each carrying its own proposition rather than four
    /// restatements of one: there IS a route, it is the ONLY one, the sidebar half exists, and
    /// the composition is still consumed by nobody new.
    func testPM8TheProductsPageIsConstructedExactlyOnceAndByTheDetailSwitch() throws {
        let sources = try Self.appSources()
        XCTAssertGreaterThan(sources.count, 10, "the scan must have seen the app target")
        XCTAssertEqual(Self.mentions(of: "ProductsView(", in: sources),
                       ["Views/RootView.swift"],
                       "the products page must be constructed exactly once, by the detail switch")

        // …and that one construction is the `.products` branch, not a stray call elsewhere in
        // the file.
        let root = try Self.appSource("Views/RootView.swift")
        XCTAssertEqual(Self.occurrences(of: "case .products: ProductsView()", inCodeOf: root), 1,
                       "the one call site must be the `.products` branch of the detail switch")
        XCTAssertEqual(Self.occurrences(of: "ProductsView(", inCodeOf: root), 1)

        // The composition is consumed by the page and driven by the model, and by nothing else.
        // Its own file is in the list because it declares the type. RootView is NOT: it builds
        // the view and never touches the composition.
        XCTAssertEqual(Self.mentions(of: "ProductPageComposition", in: sources),
                       ["App/AppModel.swift", "App/ProductPageComposition.swift",
                        "Views/ProductsView.swift"])

        // The scanner is proved on synthetic text: a hit that is really there, one that is only
        // a comment, and a longer identifier that must not match.
        XCTAssertEqual(Self.mentions(of: "ProductsView(",
                                     in: [("X.swift", "  ProductsView()")]), ["X.swift"])
        XCTAssertEqual(Self.mentions(of: "ProductsView(",
                                     in: [("X.swift", "  // ProductsView() is 2b-A4")]), [])
        XCTAssertEqual(Self.mentions(of: "ProductsView(",
                                     in: [("X.swift", "  ProductsViewModel()")]), [],
                       "whole-prefix matching only")
    }

    /// The sidebar half of the route, and its own proposition: the case exists, in the
    /// adjudicated position, and carries the copy key the enum's own convention implies.
    ///
    /// Position is asserted as an ORDERED list because it is what the user sees: the sidebar
    /// list and the menu-bar picker both iterate `allCases` in declaration order.
    func testPM8bTheSidebarCarriesTheProductsEntryInItsAdjudicatedPlace() {
        XCTAssertEqual(SidebarSection.allCases.map(\.rawValue),
                       ["overview", "transactions", "categories", "products", "inventory",
                        "reports"],
                       "master data sits beside categories; reports stay last")
        XCTAssertEqual(SidebarSection(rawValue: "products"), .products)
        XCTAssertEqual(SidebarSection.products.titleKey, "nav.products")
        XCTAssertEqual(SidebarSection.products.systemImage, "shippingbox",
                       "the same symbol the page's own empty state draws")
        XCTAssertTrue(try! Self.appSource("Views/ProductsView.swift")
            .contains("systemImage: \"shippingbox\""),
                      "the page and the sidebar row must not drift apart")
    }

    /// The label the sidebar row draws, in all six languages, and its relationship to the page
    /// it opens: the same string, verbatim. The other sections use ONE key for both; reports
    /// established the two-key form and pinned them equal, and this follows it.
    func testPM8cTheSidebarLabelResolvesEverywhereAndMatchesThePageTitle() {
        for language in languages {
            let label = value(language, SidebarSection.products.titleKey)
            XCTAssertNotEqual(label, SidebarSection.products.titleKey,
                              "\(language): the sidebar entry leaks the raw key")
            XCTAssertFalse(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertEqual(label, value(language, ProductPageComposition.pageTitleKey),
                           "\(language): the sidebar entry and the page title must be identical")
        }
    }

    // MARK: - PM9 — no spinner, and no comment the scanners cannot see

    /// The catalogue is read synchronously on the main actor, so a loading frame is never
    /// rendered and a spinner would be a control the user can never see. Block comments are
    /// banned for the same reason the report page bans them: every guard in this file skips
    /// `//` lines, and `/* … */` would hide a call from all of them.
    func testPM9ThePageDrawsNoSpinnerAndUsesNoBlockComments() throws {
        for relative in ["Views/ProductsView.swift", "App/ProductPageComposition.swift"] {
            let source = try Self.appSource(relative)
            XCTAssertFalse(source.contains("ProgressView"), "\(relative) must not show a spinner")
            XCTAssertFalse(source.contains("/*"), "\(relative): block comments hide code from the guards")
        }
        // And the view really does hold no copy of its own — not one of the forty-one, and not
        // any other literal in that namespace either. The wider form is the one that matters: an
        // accessibility identifier written as `"product.form.isService"` IS one of the
        // forty-one, and reads to every scanner as the view having grown its own source of
        // strings.
        let view = try Self.appSource("Views/ProductsView.swift")
        for key in ProductPageComposition.placement.keys {
            XCTAssertFalse(view.contains("\"\(key)\""), "ProductsView names \(key) directly")
        }
        XCTAssertFalse(view.contains("\"product."),
                       "ProductsView holds a literal in the copy's namespace")
    }

    // ==============================================================================================
    // MARK: - PM13 — no cell of the table may look the model up for itself
    // ==============================================================================================

    /// A defect found by the 2b-A4 walkthrough, kept out by construction from here on.
    ///
    /// `Table` materialises its cell views AGAIN, outside the render pass, when an accessibility
    /// client walks the page. The environment is not attached there, so an `@EnvironmentObject`
    /// inside a cell traps: `Fatal error: No ObservableObject of type AppModel found`. It killed
    /// the app on a ledger holding one undecodable product row, under an accessibility traversal
    /// — VoiceOver's own code path — and neither condition alone reproduced it.
    ///
    /// The rule is therefore structural: the enclosing `ProductTable` reads the model once, while
    /// the environment is guaranteed, and hands the cells resolved text and intent closures. That
    /// is what `TransactionListView` and `CategoriesView` have always done.
    func testPM13NoTableCellViewLooksUpTheEnvironmentObject() throws {
        let source = try Self.appSource("Views/ProductsView.swift")
        let cells = ["ProductUnitCell", "ProductCostCell", "ProductStatusCell", "ProductRowActions"]
        for cell in cells {
            let body = try Self.structBody(named: cell, in: source)
            XCTAssertFalse(Self.namesIdentifier("EnvironmentObject", in: body), """
                \(cell) looks the model up for itself. A table cell is rebuilt outside the \
                environment during an accessibility traversal, where that lookup is fatal — \
                take resolved values from ProductTable instead.
                """)
            // …and it really is a cell, i.e. the table still builds it.
            XCTAssertTrue(Self.occurrences(of: "\(cell)(", inCodeOf: source) >= 1,
                          "\(cell) is no longer constructed — is this list stale?")
        }
        // The enclosing table is where the one lookup belongs, so the guard is not satisfied by a
        // file that simply stopped reading the model at all.
        XCTAssertTrue(Self.namesIdentifier("EnvironmentObject",
                                           in: try Self.structBody(named: "ProductTable", in: source)),
                      "ProductTable is the one place the cells' text may be resolved")

        // The parser is proved on synthetic text, or "no hits" and "it cannot see them" look the
        // same. Whole-identifier matching: `EnvironmentObjectish` is not a hit.
        XCTAssertTrue(Self.namesIdentifier("EnvironmentObject",
                                           in: "  @EnvironmentObject var model: AppModel"))
        XCTAssertFalse(Self.namesIdentifier("EnvironmentObject", in: "  let x = EnvironmentObjectish"))
        XCTAssertEqual(try Self.structBody(named: "Probe", in: "struct Probe: View { let a = 1 }"),
                       " let a = 1 ")
    }

    // ==============================================================================================
    // MARK: - PM10 — the price column
    // ==============================================================================================

    /// `ProductsSection.tsx:111` shows a positive price and an em dash for anything else. A value
    /// with no numeric reading was already read as zero by the store, so a damaged cell and a
    /// genuine zero are the same value by the time they arrive — and they land in the same place
    /// on both sides.
    func testPM10ThePriceShowsOnlyPositiveValuesAndAnEmDashOtherwise() {
        XCTAssertEqual(ProductPageComposition.cost(12.5), .amount(12.5))
        XCTAssertEqual(ProductPageComposition.cost(0.01), .amount(0.01))
        XCTAssertEqual(ProductPageComposition.cost(0), .dash, "a genuine zero")
        XCTAssertEqual(ProductPageComposition.cost(-0.0), .dash)
        XCTAssertEqual(ProductPageComposition.cost(-5), .dash, "the write path clamps, a file need not")
        // Infinity is reachable in the column — `ProductCatalogTests` proves the store reads it
        // back intact — and it is positive, so it takes the amount arm rather than being hidden.
        XCTAssertEqual(ProductPageComposition.cost(.infinity), .amount(.infinity))
        XCTAssertFalse(ReportFormat.money(.infinity, language: "en").isEmpty,
                       "an infinite price must still render as something")

        // The dash is a glyph, not copy: no locale has a key for it, and none needs one.
        for language in languages {
            XCTAssertFalse(ReportFormat.money(1234.5, language: language).contains("—"))
        }
    }

    /// The unit cell's three answers — `getProductUnitLabel`, mirrored.
    func testPM10bTheUnitCellNamesOnlyUnitsItKnows() {
        XCTAssertEqual(ProductPageComposition.unit("kg"), .key("product.unit.kg"))
        XCTAssertEqual(ProductPageComposition.unit("crate"), .verbatim("crate"),
                       "a unit that was never on the whitelist is shown as it stands")
        XCTAssertEqual(ProductPageComposition.unit(nil), ProductPageComposition.UnitDisplay.none,
                       "no text reading at all")
        XCTAssertEqual(ProductPageComposition.unit(""), ProductPageComposition.UnitDisplay.none,
                       "Electron treats an empty unit as falsy and draws nothing")
        for unit in ProductUnit.allCases {
            XCTAssertEqual(ProductPageComposition.unit(unit.rawValue),
                           .key("product.unit.\(unit.rawValue)"))
        }
    }

    // ==============================================================================================
    // MARK: - PM11 — the write-back guard
    // ==============================================================================================

    /// P4d, on this page. A save writes only the fields that differ from what the panel is
    /// showing, and a field that cannot be read writes nothing at all.
    func testPM11AnUntouchedFormWritesNothingAndATouchedFieldWritesOnlyItself() {
        let stored = product(id: "p", name: "Widget", unit: "kg", cost: 4.5, isService: false)
        var draft = ProductFormDraft(editing: stored)
        XCTAssertTrue(draft.changes.isEmpty, "an untouched panel is not a write")

        draft.name = "Widget v2"
        XCTAssertEqual(draft.changes.name, "Widget v2")
        XCTAssertNil(draft.changes.unit)
        XCTAssertNil(draft.changes.defaultUnitCost)
        XCTAssertNil(draft.changes.isService)

        var priced = ProductFormDraft(editing: stored)
        priced.costText = "9"
        XCTAssertEqual(priced.changes.defaultUnitCost, 9)
        priced.costText = "4.5"
        XCTAssertNil(priced.changes.defaultUnitCost, "retyping the value on screen is not a change")

        var flagged = ProductFormDraft(editing: stored)
        flagged.isService = true
        XCTAssertEqual(flagged.changes.isService, true)
    }

    /// The half that matters most: a row whose unit the picker cannot represent must come back
    /// out of the panel unchanged. Seeding the first option and writing it on save would replace
    /// bytes the user never chose — the settings screen's own defect, on a different column.
    func testPM11bAUnitThePickerCannotShowIsNeverWrittenBack() {
        for stored in [product(id: "x", unit: "crate"), product(id: "y", unit: nil),
                       product(id: "z", unit: "")] {
            var draft = ProductFormDraft(editing: stored)
            XCTAssertNil(draft.unit, "\(String(describing: stored.unit)) has nothing to select")
            XCTAssertTrue(draft.changes.isEmpty,
                          "\(String(describing: stored.unit)) was rewritten without being touched")
            // …and a deliberate pick does write.
            draft.unit = "kg"
            XCTAssertEqual(draft.changes.unit, "kg")
        }
        // A whitelisted unit seeds normally and re-selecting it is still not a write.
        var known = ProductFormDraft(editing: product(unit: "kg"))
        XCTAssertEqual(known.unit, "kg")
        known.unit = "kg"
        XCTAssertTrue(known.changes.isEmpty)
    }

    /// The other direction of the same guard: a price field that cannot be read is not a zero.
    func testPM11cAnUnreadableOrEmptiedPriceWritesNothing() {
        var draft = ProductFormDraft(editing: product(cost: 7))
        for text in ["", "   ", "abc", "1,000"] {
            draft.costText = text
            XCTAssertNil(draft.changes.defaultUnitCost,
                         "\(text.debugDescription) must not land in the ledger as a zero")
        }
        // An infinite price cannot be typed back, so the field is left empty and writes nothing.
        let infinite = ProductFormDraft(editing: product(cost: .infinity))
        XCTAssertEqual(infinite.costText, "")
        XCTAssertTrue(infinite.changes.isEmpty)
        // Seeding round-trips for the ordinary values, or an untouched field would look edited.
        for value in [0.0, 1, 4.5, -3, 1234.75] {
            XCTAssertEqual(ProductFormDraft.parseCost(ProductFormDraft.costText(value)), value,
                           "\(value) does not survive seed-then-parse")
        }
        // A new item submits everything, so `changes` is not its path at all.
        XCTAssertTrue(ProductFormDraft(editing: nil).changes.isEmpty)
        XCTAssertEqual(ProductFormDraft(editing: nil).unit, "piece")
        XCTAssertEqual(ProductFormDraft(editing: nil).costText, "0")
    }

    // MARK: - PM12 — the two empty renders are mutually exclusive

    /// "You have no products yet" is false on a ledger whose product rows all failed to decode,
    /// and the notice's own wording ("not listed above") stays true when there is nothing above
    /// it. So the notice replaces the empty state rather than joining it — the same choice the
    /// transaction list already makes for a ledger whose records are in tables it cannot read.
    func testPM12TheEmptyStateAndTheUnreadableNoticeNeverAppearTogether() {
        let rows = [product()]
        let cases: [(ProductCatalogPage, hasList: Bool, hasEmpty: Bool, hasNotice: Bool)] = [
            (catalog([]),                     false, true,  false),
            (catalog([], unreadable: 3),      false, false, true),
            (catalog(rows),                   true,  false, false),
            (catalog(rows, unreadable: 2),    true,  false, true),
        ]
        for (page, hasList, hasEmpty, hasNotice) in cases {
            let composed = ProductPageComposition.compose(.init(catalog: page))
            XCTAssertEqual(composed.list != nil, hasList, "\(page)")
            XCTAssertEqual(!composed.emptyKeys.isEmpty, hasEmpty, "\(page)")
            XCTAssertEqual(!composed.unreadableKeys.isEmpty, hasNotice, "\(page)")
            XCTAssertFalse(!composed.emptyKeys.isEmpty && !composed.unreadableKeys.isEmpty,
                           "\(page): both empty renders at once")
            XCTAssertEqual(composed.unreadableCount, page.unreadableCount)
        }
    }

    // ==============================================================================================
    // MARK: - M14 — every write refreshes the list, not just the state
    // ==============================================================================================

    /// Creating a product must leave the LIST holding it. "The call returned" and "the screen is
    /// right" are different claims, and the conversion wizard's own M14 mutation showed that a
    /// dropped reload passes the first while failing the second.
    func testM14ACreateLandsInTheList() async throws {
        let model = try await bootedModel()
        model.reloadProducts()
        XCTAssertEqual(model.products.products.count, 0)

        model.newProduct()
        model.productForm?.name = "  Steel plate  "
        model.productForm?.unit = "kg"
        model.productForm?.costText = "12.5"
        model.saveProductForm()

        XCTAssertNil(model.productForm, "an accepted create closes the panel")
        XCTAssertNil(model.productError)
        XCTAssertEqual(model.products.products.map(\.name), ["Steel plate"],
                       "the list was not reloaded after the create")
        XCTAssertEqual(model.products.products.first?.unit, "kg")
        XCTAssertEqual(model.products.products.first?.defaultUnitCost, 12.5)
        XCTAssertEqual(model.products.products.first?.sortOrder, 999, "create's own default")
    }

    /// An edit must leave the list holding the new value — and an edit that changes nothing must
    /// not touch the row at all.
    func testM14BUpdateLandsInTheListAndAnEmptyEditWritesNothing() async throws {
        let model = try await bootedModel()
        let store = try XCTUnwrap(model.store)
        let id = try store.createProduct(name: "Widget", unit: "piece", defaultUnitCost: 4)
        model.reloadProducts()

        // A sentinel only this test knows: `updated_at` has one-second resolution and cannot
        // prove a rewrite did not happen inside the same second.
        let sentinel = "SENTINEL-2b-a3-not-a-timestamp"
        try store.db.run("UPDATE products SET updated_at = ? WHERE id = ?",
                         [.text(sentinel), .text(id)])
        model.reloadProducts()

        model.editProduct(try XCTUnwrap(model.products.products.first))
        model.saveProductForm()
        XCTAssertNil(model.productForm, "an edit that changes nothing still closes the panel")
        model.reloadProducts()
        XCTAssertEqual(model.products.products.first?.updatedAt, sentinel,
                       "an untouched panel wrote to the ledger")

        model.editProduct(try XCTUnwrap(model.products.products.first))
        model.productForm?.name = "Widget v2"
        model.saveProductForm()
        XCTAssertEqual(model.products.products.map(\.name), ["Widget v2"],
                       "the list was not reloaded after the update")
        XCTAssertNotEqual(model.products.products.first?.updatedAt, sentinel)
    }

    /// The status control is not a form field, and flipping it must be visible in the list.
    func testM14CTogglingActiveLandsInTheList() async throws {
        let model = try await bootedModel()
        let store = try XCTUnwrap(model.store)
        _ = try store.createProduct(name: "Widget")
        model.reloadProducts()
        let row = try XCTUnwrap(model.products.products.first)
        XCTAssertTrue(row.isActive)

        model.toggleProductActive(row)
        XCTAssertEqual(model.products.products.first?.isActive, false,
                       "the list was not reloaded after the toggle")
        XCTAssertEqual(ProductPageComposition.compose(model.productInput)
            .list?.rows.first?.statusKey, "product.status.inactive")
    }

    /// A confirmed delete must remove the row from the list, and the pending state with it.
    func testM14DDeleteRemovesTheRowFromTheList() async throws {
        let model = try await bootedModel()
        let store = try XCTUnwrap(model.store)
        _ = try store.createProduct(name: "Keep")
        _ = try store.createProduct(name: "Drop", sortOrder: 5)
        model.reloadProducts()
        XCTAssertEqual(model.products.products.count, 2)

        let drop = try XCTUnwrap(model.products.products.first { $0.name == "Drop" })
        model.requestProductDelete(drop)
        XCTAssertNotNil(ProductPageComposition.compose(model.productInput).delete)
        model.confirmProductDelete()

        XCTAssertNil(model.pendingProductDelete)
        XCTAssertEqual(model.products.products.map(\.name), ["Keep"],
                       "the list was not reloaded after the delete")
        XCTAssertNil(model.productError)
    }

    /// A refused write reports one adjudicated sentence and changes nothing on screen.
    func testM14ERefusedWritesLeaveTheListAloneAndReportACase() async throws {
        let model = try await bootedModel()
        let store = try XCTUnwrap(model.store)
        _ = try store.createProduct(name: "Widget")
        model.reloadProducts()
        let before = model.products

        // Deleted underneath the page by another writer, then edited.
        let ghost = try XCTUnwrap(model.products.products.first)
        try store.deleteProduct(id: ghost.id)
        model.editProduct(ghost)
        model.productForm?.name = "Widget v2"
        model.saveProductForm()

        XCTAssertEqual(model.productError, .notFound)
        XCTAssertEqual(ProductPageComposition.compose(model.productInput).errorKeys,
                       ["product.error.notFound"])
        XCTAssertNotNil(model.productForm, "a refused save keeps the panel open")
        XCTAssertEqual(model.products, before, "nothing changed, so nothing was reloaded")

        model.cancelProductForm()
        model.dismissProductError()
        XCTAssertNil(model.productError)
    }

    /// One undecided write at a time: the panel and the delete confirmation cannot both be up,
    /// and neither can be opened while the other is.
    func testM14FOnlyOneUndecidedWriteAtATime() async throws {
        let model = try await bootedModel()
        let store = try XCTUnwrap(model.store)
        _ = try store.createProduct(name: "Widget")
        model.reloadProducts()
        let row = try XCTUnwrap(model.products.products.first)

        model.editProduct(row)
        XCTAssertTrue(model.productWriteIsPending)
        model.requestProductDelete(row)
        XCTAssertNil(model.pendingProductDelete, "a delete may not start while the panel is open")
        model.newProduct()
        XCTAssertEqual(model.productForm?.editing?.id, row.id, "the open panel was replaced")
        model.toggleProductActive(row)
        XCTAssertEqual(model.products.products.first?.isActive, true, "the toggle must be refused")

        model.cancelProductForm()
        model.requestProductDelete(row)
        XCTAssertNotNil(model.pendingProductDelete)
        model.newProduct()
        XCTAssertNil(model.productForm, "the panel may not open while a delete is pending")
        model.cancelProductDelete()
    }

    /// The read model is the ledger's, not the model's memory: a write made on a SECOND
    /// connection shows up as soon as the page reloads.
    func testM14GTheListIsReadFromTheLedgerAndNotFromMemory() async throws {
        let model = try await bootedModel()
        model.reloadProducts()
        XCTAssertTrue(model.products.products.isEmpty)

        let second = try LedgerStore(databaseURL: try XCTUnwrap(Self.ledgerURL))
        _ = try second.createProduct(name: "From another connection")
        XCTAssertTrue(model.products.products.isEmpty, "the model has not been told yet")

        model.reloadProducts()
        XCTAssertEqual(model.products.products.map(\.name), ["From another connection"])
    }

    // ==============================================================================================
    // MARK: - Helpers
    // ==============================================================================================

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

    /// Which files mention `needle` on a non-comment line. Comment lines are skipped so a
    /// sentence explaining a call cannot be mistaken for one.
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
    /// chain uses — the shape `LegacyConversionWizardTests` established, so the write path under
    /// test is the shipping one rather than an injected double.
    private func bootedModel() async throws -> AppModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SLProducts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectory = directory
        let url = directory.appendingPathComponent("products.db")
        Self.ledgerURL = url

        let store = try LedgerStore(databaseURL: url, open: .createIfMissing)
        try store.settings.setString("CN", for: SettingsStore.Key.accountingLocale)
        let model = AppModel(runner: FakeRunner(store: store))
        model.boot()
        await model.currentBootTask?.value
        XCTAssertNotNil(model.store, "the fixture model must have adopted a store")
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
}
