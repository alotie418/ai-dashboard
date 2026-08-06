import XCTest
@testable import SoloLedgerCore

/// The `inventory.*` six-language copy — 93 keys plus `nav.inventory`.
///
/// Two rounds landed it. N-PR-3 wrote the 68 the inventory PAGE draws; N-PR-4 gave those a
/// composition, so IC11 now holds them to exactly one file. N-PR-5a adds the 25 the opening-stock
/// WIZARD will draw, and those are still DORMANT — the wizard's plan, its composition and its view
/// are N-PR-5b, and `nav.inventory` waits for N-PR-6.
///
/// ## Why this namespace could not be borrowed
///
/// Every other copy round had a source to mirror. This one does not. Electron ships an
/// `inventory.*` namespace of its own, and its wording describes a DIFFERENT calculation:
/// purchases-to-date net over purchases-to-date quantity, which sales never touch. The native
/// engine is a moving weighted average. Copying those sentences across would be a false statement
/// about what the app does, so the whole namespace is original and IC12 keeps it that way.
///
/// ## The rule that shapes the numbers
///
/// No quantity, amount or average appears inside a sentence. They are cell and card VALUES,
/// formatted by the presentation layer, so the display rounding (N-8's `.toNearestOrAwayFromZero`)
/// lives in exactly one place instead of being re-decided per language.
///
/// That rule is about FIGURES, not about the character `0`: a handful of sentences do carry a
/// digit where the digit is part of what is being said — "e.g. 10" as a placeholder, "enter 0 for
/// a free sample", "only the last 1" in Japanese. An earlier draft of this comment claimed the
/// table "contains no digits at all", which was measurably untrue and is corrected here. Nothing
/// enforces a no-digit rule and nothing should start to without a decision of its own.
///
/// Placeholders are `{name}` — a product name — and `{count}`, which the wizard's two counting
/// sentences carry. Neither is a money amount.
final class InventoryCopyTests: XCTestCase {

    private let languages = ["zh-Hans", "zh-Hant", "en", "ja", "ko", "fr"]

    // MARK: - The adjudicated table

    private static let pageKeys = ["inventory.page.title", "inventory.page.subtitle",
                                   "inventory.page.basisNote", "inventory.page.reportNote",
                                   "inventory.page.unitNote"]
    private static let columnKeys = ["inventory.col.date", "inventory.col.type",
                                     "inventory.col.quantity", "inventory.col.unitCost",
                                     "inventory.col.cost", "inventory.col.source",
                                     "inventory.col.note", "inventory.col.status"]
    private static let statusKeys = ["inventory.status.posted", "inventory.status.reversed",
                                     "inventory.status.reversal"]
    private static let typeKeys = InventoryMovementType.allCases.map { "inventory.type.\($0.camelName)" }
    private static let balanceKeys = ["inventory.balance.title", "inventory.balance.quantity",
                                      "inventory.balance.cost", "inventory.balance.unitCost",
                                      "inventory.balance.currencyNote"]
    private static let formKeys = ["inventory.form.title", "inventory.form.quantityPlaceholder",
                                   "inventory.form.unitCostHint", "inventory.form.costDelta",
                                   "inventory.form.costDeltaHint", "inventory.form.sourcePlaceholder",
                                   "inventory.form.submit"]
    private static let errorKeys = allErrors.map { "inventory.error.\($0)" }
    private static let emptyKeys = ["inventory.empty.noProduct.title", "inventory.empty.noProduct.message",
                                    "inventory.empty.noMovement.title", "inventory.empty.noMovement.message",
                                    "inventory.empty.noOpening.title", "inventory.empty.noOpening.message"]
    private static let reverseKeys = ["inventory.reverse.action", "inventory.reverse.confirmTitle",
                                      "inventory.reverse.confirmMessage", "inventory.reverse.onlyLastNote"]
    private static let exceptionKeys = ["inventory.exception.title"]
        + InventoryExceptionKind.allCases.map { "inventory.exception.\($0.camelName)" }

    /// The sixty-eight the PAGE draws. N-PR-4 gave every one of them a placement, so IC11 holds
    /// them to `InventoryPageComposition.swift` and to no other file.
    private static var pageAdjudicatedKeys: [String] {
        pageKeys + columnKeys + statusKeys + typeKeys + balanceKeys + formKeys
            + errorKeys + emptyKeys + reverseKeys + exceptionKeys
    }

    // MARK: - The wizard's table (N-PR-5a, dormant)

    /// The opening-stock wizard's entry point, on the inventory page's header beside the control
    /// that opens the movement panel.
    private static let openingEntryKeys = ["inventory.opening.cta", "inventory.opening.cta.hint"]

    /// One scrolling sheet, not a multi-step flow — so there are no next/back labels to write.
    private static let openingFrameKeys = ["inventory.opening.title", "inventory.opening.intro",
                                           "inventory.opening.forwardNote"]

    /// The two ways the wizard has nothing to offer: no products at all, and every product
    /// already carrying live movements — which D-5 makes permanent for those products.
    private static let openingBlockedKeys = ["inventory.opening.blocked.noProduct.title",
                                             "inventory.opening.blocked.noProduct.message",
                                             "inventory.opening.blocked.noneEligible.title",
                                             "inventory.opening.blocked.noneEligible.message"]

    /// The list's four headings. The first three are typed; the last is derived and read-only.
    private static let openingColumnKeys = ["inventory.opening.col.product",
                                            "inventory.opening.col.quantity",
                                            "inventory.opening.col.amount",
                                            "inventory.opening.col.unitCost"]

    /// What the user types, and the three things that have to be said next to it: what dating the
    /// openings costs (N-6), how to leave a product out, that zero is a price and empty is not
    /// (D-10 / N-7), and where the division's remainder goes (D-3).
    private static let openingInputKeys = ["inventory.opening.date.label",
                                           "inventory.opening.date.note",
                                           "inventory.opening.quantityHint",
                                           "inventory.opening.amountHint",
                                           "inventory.opening.roundingNote"]

    private static let openingConfirmKeys = ["inventory.opening.summary",
                                             "inventory.opening.currencyNote",
                                             "inventory.opening.action.post"]

    /// Two outcomes, not three. Each product's opening is one transaction of its own — the engine
    /// has no state that spans products — so a refusal takes that product out and leaves the rest
    /// written. There is no all-or-nothing rollback here and the copy does not claim one.
    private static let openingOutcomeKeys = ["inventory.opening.done.title",
                                             "inventory.opening.done.message",
                                             "inventory.opening.partial.title",
                                             "inventory.opening.partial.message"]

    private static var openingKeys: [String] {
        openingEntryKeys + openingFrameKeys + openingBlockedKeys + openingColumnKeys
            + openingInputKeys + openingConfirmKeys + openingOutcomeKeys
    }

    private static var adjudicatedKeys: [String] { pageAdjudicatedKeys + openingKeys }

    /// Every `InventoryPostingError`, listed once.
    ///
    /// Spelled as STRINGS rather than as cases so the list can be compared against the type's own
    /// `description`, which is itself an exhaustive switch. A new case therefore has to appear in
    /// three places — the enum, that switch, and here — and IC5 fails on any of the three being
    /// forgotten, in both directions.
    private static let allErrors = [
        "netAmountRequired", "unitCostMustNotBeNegative", "quantityMustBePositive",
        "manualAdjustMustNotMoveQuantity", "manualAdjustRequiresStock", "costBalanceWouldGoNegative",
        "insufficientStock", "backdatedNotSupported", "currencyMismatch", "openingMustBeFirst",
        "returnExceedsOrigin", "onlyTheLastMovementCanBeReversed", "movementAlreadyReversed",
        "reversalTargetNotFound", "productNotFound", "arithmeticOverflow", "ledgerInconsistent",
        "storageFailure",
    ]

    /// Every case of the error enum, as values, so IC5 can compare against the type and not
    /// against a hand-written echo of it.
    private static let allErrorCases: [InventoryPostingError] = [
        .netAmountRequired, .unitCostMustNotBeNegative, .quantityMustBePositive,
        .manualAdjustMustNotMoveQuantity, .manualAdjustRequiresStock, .costBalanceWouldGoNegative,
        .insufficientStock, .backdatedNotSupported, .currencyMismatch, .openingMustBeFirst,
        .returnExceedsOrigin, .onlyTheLastMovementCanBeReversed, .movementAlreadyReversed,
        .reversalTargetNotFound, .productNotFound, .arithmeticOverflow, .ledgerInconsistent,
        .storageFailure,
    ]

    private static let allowedPlaceholders: Set<String> = ["{name}", "{count}"]
    private static let placeholderContract: [String: Set<String>] = [
        "inventory.balance.title": ["{name}"],
        "inventory.opening.summary": ["{count}"],
        "inventory.opening.partial.message": ["{count}"],
    ]

    // MARK: - IC1 · the key universe

    func testIC1TheInventoryNamespaceIsExactlyNinetyThreeKeys() throws {
        XCTAssertEqual(Self.adjudicatedKeys.count, 93, "the adjudicated table itself must be ninety-three")
        XCTAssertEqual(Set(Self.adjudicatedKeys).count, 93, "the adjudicated table has a duplicate")
        // The split is load-bearing: IC11 holds the page's half to one file and requires the
        // wizard's half to be named nowhere at all, so a key moving between the two halves is a
        // change of reachability and not a rename.
        XCTAssertEqual(Self.pageAdjudicatedKeys.count, 68, "N-PR-3's page namespace")
        XCTAssertEqual(Self.openingKeys.count, 25, "N-PR-5a's wizard namespace")
        XCTAssertTrue(Set(Self.pageAdjudicatedKeys).isDisjoint(with: Set(Self.openingKeys)))
        XCTAssertTrue(Self.openingKeys.allSatisfy { $0.hasPrefix("inventory.opening.") })
        XCTAssertTrue(Self.pageAdjudicatedKeys.allSatisfy { !$0.hasPrefix("inventory.opening.") })
        for language in languages {
            let landed = try sourceTable(language).keys.filter { $0.hasPrefix("inventory.") }.sorted()
            XCTAssertEqual(landed, Self.adjudicatedKeys.sorted(),
                           "\(language) landed a different inventory.* set")
        }
    }

    // MARK: - IC2 · the whole universe, and six identical key sets

    func testIC2EverySixLocaleFileHoldsSixHundredThirtyFourKeys() throws {
        var inventorySets: [Set<String>] = []
        for language in languages {
            let table = try sourceTable(language)
            XCTAssertEqual(table.count, 634, "\(language) has \(table.count) keys")
            XCTAssertEqual(table.keys.filter { $0.hasPrefix("nav.") }.count, 7, "\(language) nav.*")
            XCTAssertEqual(table.keys.filter { $0.hasPrefix("product.") }.count, 41, "\(language) product.*")
            inventorySets.append(Set(table.keys.filter { $0.hasPrefix("inventory.") }))
        }
        XCTAssertEqual(Set(inventorySets).count, 1, "the six locales do not agree on the inventory.* key set")
    }

    // MARK: - IC3 · every key resolves, everywhere

    func testIC3EveryInventoryKeyResolvesInAllSixLocales() throws {
        for language in languages {
            let table = try sourceTable(language)
            for key in Self.adjudicatedKeys + ["nav.inventory"] {
                guard let value = table[key] else {
                    return XCTFail("\(language) is missing \(key)")
                }
                XCTAssertFalse(value.trimmingCharacters(in: .whitespaces).isEmpty, "\(language)/\(key) is empty")
                XCTAssertNotEqual(value, key, "\(language)/\(key) renders its own key")
            }
        }
    }

    // MARK: - IC4 · the placeholder contract

    func testIC4PlaceholdersAreTheContractedTokensAndNothingElse() throws {
        for language in languages {
            let table = try sourceTable(language)
            for key in Self.adjudicatedKeys {
                let text = table[key] ?? ""
                XCTAssertEqual(placeholders(in: text), Self.placeholderContract[key] ?? [],
                               "\(language)/\(key) placeholder set")
                // Full-width braces are the blind spot the ASCII regex cannot see: `｛name｝`
                // reads as "this key has no placeholder" and passes every parity check.
                XCTAssertNil(text.range(of: "[｛｝]", options: .regularExpression),
                             "\(language)/\(key) uses full-width braces")
            }
            for (key, tokens) in Self.placeholderContract {
                var rendered = table[key] ?? ""
                for token in tokens {
                    XCTAssertTrue(rendered.contains(token), "\(language)/\(key) lost \(token)")
                    rendered = rendered.replacingOccurrences(of: token, with: "A 型包装盒")
                }
                XCTAssertNil(rendered.range(of: "[{}｛｝]", options: .regularExpression),
                             "\(language)/\(key) still holds a brace after substitution")
            }
            XCTAssertTrue(Self.placeholderContract.values.allSatisfy { $0.isSubset(of: Self.allowedPlaceholders) })
        }
    }

    // MARK: - IC5 · the error enum and its sentences, both directions

    /// Adding a case without copy, or copy without a case, must fail. The list of case NAMES is
    /// compared against the enum's own `description`, so this cannot drift into agreeing with
    /// itself.
    func testIC5EveryErrorCaseHasExactlyOneSentenceAndViceVersa() throws {
        XCTAssertEqual(Self.allErrorCases.map(\.description), Self.allErrors,
                       "the case list and the enum disagree — a case was added or renamed")
        XCTAssertEqual(Set(Self.allErrors).count, Self.allErrors.count, "duplicate case name")

        // The enum is not `CaseIterable`, so the two lists above are both HAND-WRITTEN and would
        // agree with each other while both missing a newly added case. The case names are
        // therefore read out of the type's own SOURCE, which is the only side that cannot be
        // forgotten. (Making the enum `CaseIterable` would be the tidier fix and belongs to a
        // round that is allowed to touch the engine; this one is not.)
        let declared = try Self.errorCaseNamesFromSource()
        XCTAssertEqual(declared, Self.allErrors, """
            InventoryPostingError declares a different set of cases than this suite lists.
            declared but unlisted: \(Set(declared).subtracting(Self.allErrors).sorted())
            listed but undeclared: \(Set(Self.allErrors).subtracting(declared).sorted())
            """)

        for language in languages {
            let landed = Set(try sourceTable(language).keys.filter { $0.hasPrefix("inventory.error.") })
            XCTAssertEqual(landed, Set(Self.errorKeys), """
                \(language): the error copy and the error cases disagree.
                copy with no case: \(landed.subtracting(Self.errorKeys).sorted())
                case with no copy: \(Set(Self.errorKeys).subtracting(landed).sorted())
                """)
        }
    }

    /// The sentence a user reads may never be the machine's name for the refusal.
    func testIC5bErrorCopyNeverPrintsTheCaseNameOrAMachineToken() throws {
        for language in languages {
            let table = try sourceTable(language)
            for name in Self.allErrors {
                let text = table["inventory.error.\(name)"] ?? ""
                XCTAssertFalse(text.contains(name), "\(language): the copy prints the case name \(name)")
                for token in ["inventory_movements", "inventory_balances", "SQLITE", "nil", "Int64"] {
                    XCTAssertFalse(text.contains(token), "\(language)/\(name) leaks \(token)")
                }
            }
        }
    }

    // MARK: - IC6 / IC7 · the two closed sets, both directions

    func testIC6EveryMovementTypeHasExactlyOneLabelAndViceVersa() throws {
        XCTAssertEqual(InventoryMovementType.allCases.count, 8)
        for language in languages {
            let landed = Set(try sourceTable(language).keys.filter { $0.hasPrefix("inventory.type.") })
            XCTAssertEqual(landed, Set(Self.typeKeys), """
                \(language): the movement-type labels and the enum disagree.
                label with no case: \(landed.subtracting(Self.typeKeys).sorted())
                case with no label: \(Set(Self.typeKeys).subtracting(landed).sorted())
                """)
        }
    }

    func testIC7EveryExceptionKindHasExactlyOneLabelAndViceVersa() throws {
        XCTAssertEqual(InventoryExceptionKind.allCases.count, 3)
        let kindKeys = Set(InventoryExceptionKind.allCases.map { "inventory.exception.\($0.camelName)" })
        for language in languages {
            let landed = Set(try sourceTable(language).keys.filter { $0.hasPrefix("inventory.exception.") })
                .subtracting(["inventory.exception.title"])
            XCTAssertEqual(landed, kindKeys, """
                \(language): the exception labels and the kinds disagree.
                label with no kind: \(landed.subtracting(kindKeys).sorted())
                kind with no label: \(kindKeys.subtracting(landed).sorted())
                """)
        }
    }

    // MARK: - IC8 · no two keys in one screen region read the same

    func testIC8NoTwoKeysInOneScreenRegionRenderTheSameLabel() throws {
        let buckets: [String: [String]] = [
            "page header": Self.pageKeys,
            "list header": Self.columnKeys,
            "status cell": Self.statusKeys,
            "type cell": Self.typeKeys,
            "balance card": Self.balanceKeys,
            // The form reuses the column labels for its field names — the same discipline the
            // products page uses — so both sets share one bucket.
            "form": Self.formKeys + Self.columnKeys.filter { $0 != "inventory.col.cost" && $0 != "inventory.col.status" },
            "error banner": Self.errorKeys,
            "empty state": Self.emptyKeys,
            "reverse dialog": Self.reverseKeys,
            "exception list": Self.exceptionKeys,
            // The wizard is a second screen, so its regions are its own buckets: a heading there
            // that reads like one on the page is not an ambiguity, because the two are never
            // drawn together.
            "wizard entry": Self.openingEntryKeys,
            "wizard frame": Self.openingFrameKeys,
            "wizard blocked": Self.openingBlockedKeys,
            "wizard list header": Self.openingColumnKeys,
            "wizard form": Self.openingInputKeys + Self.openingConfirmKeys,
            "wizard outcome": Self.openingOutcomeKeys,
        ]
        for language in languages {
            let table = try sourceTable(language)
            for (region, keys) in buckets {
                var seen: [String: String] = [:]
                for key in keys {
                    let rendered = table[key] ?? ""
                    if let other = seen[rendered] {
                        XCTFail("\(region)/\(language): “\(rendered)” is rendered by both \(other) and \(key)")
                    }
                    seen[rendered] = key
                }
            }
        }
    }

    // MARK: - IC9 / IC10 · the wording guard, re-run over this namespace

    func testIC9NewCopyHasZeroBannedWordingHits() throws {
        let source = try String(contentsOf: Self.guardSourceURL(), encoding: .utf8)
        let filing = try Self.patterns(inArrayNamed: "filingWords", of: source)
        let statutory = try Self.patterns(inArrayNamed: "statutoryStatementNames", of: source)
        XCTAssertEqual(filing.count, 22, "filingWords changed size — re-scan the copy")
        XCTAssertEqual(statutory.count, 21, "statutoryStatementNames changed size — re-scan the copy")
        // Being in the same target as the guard, the parse can be checked against the real arrays
        // instead of trusted. If the parser ever silently returns fewer patterns, this catches it
        // before a banned word slips past on a short list.
        XCTAssertEqual(filing, LocalizationWordingGuardTests.filingWords.map(\.pattern))
        XCTAssertEqual(statutory, LocalizationWordingGuardTests.statutoryStatementNames.map(\.pattern))

        let keys = Self.adjudicatedKeys + ["nav.inventory", "product.error.hasInventoryMovements"]
        for (label, patterns) in [("filingWords", filing), ("statutoryStatementNames", statutory)] {
            for pattern in patterns {
                let regex = try NSRegularExpression(pattern: pattern)
                for language in languages {
                    let table = try sourceTable(language)
                    for key in keys {
                        let text = table[key] ?? ""
                        let range = NSRange(text.startIndex..., in: text)
                        XCTAssertEqual(regex.numberOfMatches(in: text, range: range), 0,
                                       "\(language)/\(key) hits \(label) /\(pattern)/: \(text)")
                    }
                }
            }
        }
    }

    /// The copy earns its place without an exemption. A sanction added for an inventory string
    /// would mean a banned word landed and was waved through rather than rewritten.
    func testIC10TheSanctionTableDidNotGrow() throws {
        let source = try String(contentsOf: Self.guardSourceURL(), encoding: .utf8)
        guard let start = source.range(of: "static let sanctionedUses"),
              let end = source.range(of: "\n    ]", range: start.upperBound..<source.endIndex) else {
            return XCTFail("could not locate the sanctionedUses array")
        }
        let table = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertEqual(table.components(separatedBy: ".init(locale:").count - 1, 40,
                       "sanctionedUses moved; N-PR-3 adds no exemption")
        XCTAssertEqual(LocalizationWordingGuardTests.sanctionedUses.count, 40)
    }

    // MARK: - IC11 · exactly one file names the copy

    /// The namespace's two halves are at two different stages, and this is where that is enforced.
    ///
    /// **The page's sixty-eight.** N-PR-3 landed them dormant and this test asserted that nobody
    /// named them. N-PR-4 gave them a page, so the assertion became a CLOSED SET rather than an
    /// empty one: every key is named by `InventoryPageComposition.swift` and by nothing else. Both
    /// directions matter — a key named nowhere is copy the page cannot reach; a key named in a
    /// second file means the page has grown a source of strings the composition does not know
    /// about, which is precisely what makes the placement proof in `InventoryMountingTests`
    /// meaningful.
    ///
    /// **The wizard's twenty-five.** N-PR-5a lands them dormant, so for them the assertion is
    /// still the empty one. The wizard's plan, composition and view are N-PR-5b; the round that
    /// writes them inverts this half exactly the way N-PR-4 inverted the other.
    ///
    /// `nav.inventory` stays at ZERO through both. The sidebar entry is N-PR-6, and even then
    /// `SidebarSection.titleKey` is computed from the raw value, so no production file will spell
    /// that string out — a hit on it means someone wrote a literal that the enum already derives.
    func testIC11TheCopyIsNamedByTheCompositionAndByNothingElse() throws {
        let sources = try Self.productionSources()
        XCTAssertGreaterThan(sources.count, 40, "the scan is not reading the tree")
        XCTAssertTrue(sources.contains { $0.path.hasSuffix("App/ProductPageComposition.swift") },
                      "the neighbouring composition is in scope")

        var named: [String: [String]] = [:]
        for (path, text) in sources {
            for key in Self.adjudicatedKeys + ["nav.inventory"] where text.contains("\"\(key)\"") {
                named[key, default: []].append(path)
            }
        }
        let composition = ["SoloLedger/App/InventoryPageComposition.swift"]
        for key in Self.pageAdjudicatedKeys {
            XCTAssertEqual((named[key] ?? []).sorted(), composition, """
                \(key) is named by \((named[key] ?? []).sorted()) — every string the inventory PAGE \
                draws belongs to its composition and to no other file.
                """)
        }
        for key in Self.openingKeys + ["nav.inventory"] {
            XCTAssertNil(named[key], """
                \(key) is already referenced in production by \((named[key] ?? []).sorted()). This \
                round lands the wizard's copy only — its plan, composition and view are N-PR-5b.
                """)
        }
    }

    /// The dormancy scan must be able to see a real use, or an empty offender list proves nothing.
    func testIC11bTheDormancyScanDetectsARealUse() throws {
        let sources = try Self.productionSources()
        XCTAssertTrue(sources.contains { $0.text.contains("\"product.error.storageFailure\"") },
                      "the scan cannot see a key that IS referenced in production")
    }

    // MARK: - IC12 · the retired Electron costing wording stays out

    /// The other app's inventory copy describes a purchases-to-date average. Reusing any of it
    /// would state something false about this engine, so the vocabulary is checked directly.
    func testIC12TheCopyDoesNotBorrowTheOtherAppsCostingWording() throws {
        let banned = [
            "累计采购", "累計採購", "purchases-to-date", "参考估值", "參考估值",
            "cumulative purchase", "库存参考", "庫存參考",
        ]
        for language in languages {
            let table = try sourceTable(language)
            for key in Self.adjudicatedKeys {
                let text = table[key] ?? ""
                for phrase in banned {
                    XCTAssertFalse(text.localizedCaseInsensitiveContains(phrase),
                                   "\(language)/\(key) borrows the other app's costing wording: \(phrase)")
                }
            }
        }
    }

    /// …and the moving-average claim is actually MADE, in every language. A namespace that merely
    /// avoids the wrong words would pass the test above while saying nothing at all.
    func testIC12bTheCostingBasisIsStatedInEveryLanguage() throws {
        let expected = ["zh-Hans": "移动加权平均", "zh-Hant": "移動加權平均",
                        "en": "moving weighted average", "ja": "移動平均法",
                        "ko": "이동평균법", "fr": "coût moyen pondéré mobile"]
        for (language, phrase) in expected {
            let text = try sourceTable(language)["inventory.page.basisNote"] ?? ""
            XCTAssertTrue(text.localizedCaseInsensitiveContains(phrase),
                          "\(language) does not state the costing basis: \(text)")
        }
    }

    // MARK: - IC13 · the sidebar label and the page title are one string

    /// P3e / Q-A2-7: the sidebar entry and the page heading are the same words, in all six
    /// languages. Pinned HERE rather than in the activation round, because the two keys land
    /// together and drifting apart between rounds is exactly what this catches.
    func testIC13TheSidebarLabelMatchesThePageTitleEverywhere() throws {
        for language in languages {
            let table = try sourceTable(language)
            let nav = table["nav.inventory"] ?? ""
            let title = table["inventory.page.title"] ?? ""
            XCTAssertFalse(nav.isEmpty, "\(language) has no nav.inventory")
            XCTAssertEqual(nav, title, "\(language): the sidebar and the page title have drifted apart")
        }
        // And the sidebar entry is distinct from every other sidebar entry, in every language.
        for language in languages {
            let table = try sourceTable(language)
            let navValues = table.filter { $0.key.hasPrefix("nav.") }.map(\.value)
            XCTAssertEqual(Set(navValues).count, navValues.count,
                           "\(language): two sidebar entries read the same")
        }
    }

    // MARK: - Helpers

    private func placeholders(in text: String) -> Set<String> {
        var found: Set<String> = []
        var search = text.startIndex..<text.endIndex
        while let range = text.range(of: "\\{[a-zA-Z]+\\}", options: .regularExpression, range: search) {
            found.insert(String(text[range]))
            search = range.upperBound..<text.endIndex
        }
        return found
    }

    /// …/native/SoloLedger/Tests/SoloLedgerCoreTests/<this>.swift → …/native/SoloLedger
    ///
    /// This suite lives in the CORE test target, not beside `ProductCopyTests` in the App one.
    /// It needs nothing from the App target — only `SoloLedgerCore`'s enums and the `.strings`
    /// files on disk — and a new file under `App/Tests/` would have to be written into the
    /// committed `project.pbxproj` as well, which is a file this round does not touch.
    private static func packageRoot() -> URL {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { dir.deleteLastPathComponent() }
        return dir
    }

    private static func guardSourceURL() -> URL {
        packageRoot().appendingPathComponent("Tests/SoloLedgerCoreTests/LocalizationWordingGuardTests.swift")
    }

    /// Parse one `[BannedWord]` table out of the guard's SOURCE rather than restating it here: a
    /// hand-copied vocabulary goes stale in the direction that matters — the guard grows a word,
    /// this file keeps passing.
    private static func patterns(inArrayNamed name: String, of source: String) throws -> [String] {
        guard let start = source.range(of: "static let \(name): [BannedWord] = ["),
              let end = source.range(of: "\n    ]", range: start.upperBound..<source.endIndex) else {
            throw NSError(domain: "InventoryCopyTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "cannot locate \(name)"])
        }
        var out: [String] = []
        for line in source[start.upperBound..<end.lowerBound].split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix(".init(pattern:") else { continue }
            if let r = text.range(of: "#\"") ,
               let e = text.range(of: "\"#", range: r.upperBound..<text.endIndex) {
                out.append(String(text[r.upperBound..<e.lowerBound]))
            } else if let r = text.range(of: "pattern: \""),
                      let e = text.range(of: "\"", range: r.upperBound..<text.endIndex) {
                out.append(String(text[r.upperBound..<e.lowerBound]))
            }
        }
        return out
    }

    /// The `case` names declared by `InventoryPostingError`, read from the engine's source in
    /// declaration order.
    static func errorCaseNamesFromSource() throws -> [String] {
        let url = packageRoot()
            .appendingPathComponent("Sources/SoloLedgerCore/Inventory/InventoryModels.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        guard let start = source.range(of: "public enum InventoryPostingError"),
              let end = source.range(of: "\n    public var description",
                                     range: start.upperBound..<source.endIndex) else {
            throw NSError(domain: "InventoryCopyTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "cannot locate InventoryPostingError"])
        }
        var out: [String] = []
        for line in source[start.upperBound..<end.lowerBound].split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("case ") else { continue }
            out.append(String(text.dropFirst(5)).trimmingCharacters(in: .whitespaces))
        }
        XCTAssertGreaterThan(out.count, 10, "the case parser found almost nothing — it is broken")
        return out
    }

    /// Every `.swift` file under `Sources/` — Core library and SwiftUI App target.
    private static func productionSources() throws -> [(path: String, text: String)] {
        let root = packageRoot().appendingPathComponent("Sources")
        guard let walker = FileManager.default.enumerator(atPath: root.path) else {
            XCTFail("cannot enumerate \(root.path)"); return []
        }
        var out: [(String, String)] = []
        for case let relative as String in walker where relative.hasSuffix(".swift") {
            guard let text = try? String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8) else {
                XCTFail("cannot read \(relative)"); continue
            }
            out.append((relative, text))
        }
        return out
    }

    /// Read one locale's `.strings` from SOURCE. The App bundle resolves through the fallback
    /// chain, which would hide a missing key behind zh-Hans instead of failing.
    private func sourceTable(_ language: String) throws -> [String: String] {
        let url = Self.packageRoot()
            .appendingPathComponent("Sources/SoloLedger/Resources/\(language).lproj/Localizable.strings")
        let text = try String(contentsOf: url, encoding: .utf8)
        var table: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\""), trimmed.hasSuffix("\";") else { continue }
            let body = trimmed.dropFirst().dropLast(2)
            guard let split = body.range(of: "\" = \"") else { continue }
            let key = String(body[body.startIndex..<split.lowerBound])
            XCTAssertNil(table[key], "\(language) declares \(key) twice")
            table[key] = String(body[split.upperBound...])
        }
        return table
    }
}

// MARK: - Key spelling

private extension InventoryMovementType {
    /// `purchase_in` → `purchaseIn`. The stored value is snake_case; the localization key follows
    /// the Swift case name, the way `product.unit.*` follows `ProductUnit`'s.
    var camelName: String { InventoryCopyKeyName.camel(from: rawValue) }
}

private extension InventoryExceptionKind {
    var camelName: String { InventoryCopyKeyName.camel(from: rawValue) }
}

private enum InventoryCopyKeyName {
    static func camel(from snake: String) -> String {
        let parts = snake.split(separator: "_")
        guard let first = parts.first else { return snake }
        return ([String(first)] + parts.dropFirst().map(\.capitalizedFirst)).joined()
    }
}

private extension Substring {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
