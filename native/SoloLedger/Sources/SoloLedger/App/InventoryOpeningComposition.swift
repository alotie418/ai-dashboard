import Foundation
import SoloLedgerCore

/// What the opening-stock wizard draws, region by region, as a value a test can hold.
///
/// The same reason the two page compositions exist: XCUITest cannot run in a headless session, so
/// "is it on screen" has to be answerable structurally. The view has no other source of keys, and
/// `InventoryOpeningView.swift` holds no literal in the copy's namespace at all.
///
/// ## Why this is its own table and not part of the page's
///
/// The two Region sets barely intersect — the page has a balance card, a movement table, a status
/// column and a row action; the wizard has a blocked state, a confirmation and an outcome. Folding
/// them together would turn "every region has at least one key" into an assertion spanning two
/// screens, which is weaker than either half. So the `inventory.*` namespace is PARTITIONED across
/// the two tables, and `InventoryMountingTests` asserts exactly that: disjoint, and together the
/// whole ninety-three.
///
/// The wizard's entry point is the exception, and deliberately so: `inventory.opening.cta` and its
/// hint are drawn by the inventory page's header, so they are placed in the PAGE's table. What
/// draws a key decides where it is placed.
///
/// ## What it borrows, and why the borrowings are not spelled out
///
/// Two `common.*` buttons, declared below. And the refusal sentences on the outcome page, which
/// are `inventory.error.*` — the page's, mapped by `InventoryPageComposition.key(for:)` and passed
/// through as resolved keys. They are NOT written out here: `InventoryCopyTests` IC11 holds every
/// one of those literals to the page's composition file, and a second spelling is exactly what
/// that guard exists to stop. What is asserted instead is the shape — every refusal key this file
/// emits begins with ``borrowedRefusalPrefix`` and is one of the engine's eighteen.
///
/// ## The numbers are formatted by the page's helpers, on purpose
///
/// `InventoryPageComposition` owns the three integer scales, the one display rounding and the
/// exact text parser. N-8's derived rule is that the display rounding lives in exactly ONE place;
/// a second copy here would break it in the way that is hardest to notice — two functions that
/// agree today. So this file names that type, and `InventoryMountingTests` widens its closed set
/// by this one file rather than pretending the coupling is not there.
enum InventoryOpeningComposition {

    // MARK: - Regions

    /// Where on the wizard a key is drawn.
    enum Region: String, CaseIterable, Equatable {
        /// The sheet's heading and the two standing declarations above the list.
        case frame
        /// Either of the two refusals to start at all.
        case blocked
        /// The four column headings.
        case listHeader
        /// The switch-over date and the three things that have to be said beside the fields.
        case form
        /// What pressing the button will do, and the button.
        case confirm
        /// What it did.
        case outcome
    }

    // MARK: - Placement

    /// Every `inventory.opening.*` key this wizard draws, and the region it belongs to.
    ///
    /// Twenty-three: the namespace's twenty-five minus the two the inventory page's header draws.
    /// One key, one region — unlike the two page tables, nothing here is drawn twice.
    static let placement: [String: Region] = [
        // MARK: frame (3)
        "inventory.opening.title": .frame,
        "inventory.opening.intro": .frame,
        "inventory.opening.forwardNote": .frame,
        // MARK: blocked (4)
        "inventory.opening.blocked.noProduct.title": .blocked,
        "inventory.opening.blocked.noProduct.message": .blocked,
        "inventory.opening.blocked.noneEligible.title": .blocked,
        "inventory.opening.blocked.noneEligible.message": .blocked,
        // MARK: listHeader (4)
        "inventory.opening.col.product": .listHeader,
        "inventory.opening.col.quantity": .listHeader,
        "inventory.opening.col.amount": .listHeader,
        "inventory.opening.col.unitCost": .listHeader,
        // MARK: form (5)
        "inventory.opening.date.label": .form,
        "inventory.opening.date.note": .form,
        "inventory.opening.quantityHint": .form,
        "inventory.opening.amountHint": .form,
        "inventory.opening.roundingNote": .form,
        // MARK: confirm (3)
        "inventory.opening.summary": .confirm,
        "inventory.opening.currencyNote": .confirm,
        "inventory.opening.action.post": .confirm,
        // MARK: outcome (4)
        "inventory.opening.done.title": .outcome,
        "inventory.opening.done.message": .outcome,
        "inventory.opening.partial.title": .outcome,
        "inventory.opening.partial.message": .outcome,
    ]

    /// The two buttons this sheet borrows from the shared vocabulary. `common.cancel` while there
    /// is still a decision to make, `common.ok` once there is not.
    static let sharedKeys: [String: Region] = [
        "common.cancel": .confirm,
        "common.ok": .outcome,
    ]

    /// Keys written into the copy that this wizard deliberately does not place. Empty, and
    /// asserted to be — see `InventoryPageComposition.exemptKeys` for why that matters.
    static let exemptKeys: Set<String> = []

    static let pageTitleKey = "inventory.opening.title"

    /// Every refusal sentence the outcome page can show begins with this. The keys themselves are
    /// the page composition's to spell; this is the shape a test can hold them to.
    static let borrowedRefusalPrefix = "inventory.error."

    // MARK: - The blocked pair

    /// Exhaustive with no `default`: a third blocker stops this file compiling rather than
    /// quietly reusing one of these two sentences.
    static func keys(for blocker: InventoryOpeningBlocker) -> [String] {
        switch blocker {
        case .noProduct:
            return ["inventory.opening.blocked.noProduct.title",
                    "inventory.opening.blocked.noProduct.message"]
        case .noneEligible:
            return ["inventory.opening.blocked.noneEligible.title",
                    "inventory.opening.blocked.noneEligible.message"]
        }
    }

    // MARK: - One render

    struct RowBlock: Equatable, Identifiable {
        let productID: String
        let productName: String
        let quantityText: String
        let amountText: String
        /// `nil` whenever the line does not read as a postable pair — the column draws a dash
        /// rather than a number derived from half an input.
        let impliedUnitCostMicro: Int64?

        var id: String { productID }
    }

    struct ListBlock: Equatable {
        /// The four headings in draw order.
        let productHeaderKey: String
        let quantityHeaderKey: String
        let amountHeaderKey: String
        let unitCostHeaderKey: String
        let rows: [RowBlock]

        var headerKeys: [String] {
            [productHeaderKey, quantityHeaderKey, amountHeaderKey, unitCostHeaderKey]
        }
        var allKeys: [String] { headerKeys }
    }

    struct FormBlock: Equatable {
        let dateLabelKey: String
        /// N-6's consequence, said where the date is chosen and not on the way out.
        let dateNoteKey: String
        let quantityHintKey: String
        let amountHintKey: String
        /// Where the division's remainder goes. The one sentence that keeps "you typed 10.00 and
        /// the ledger holds 9.99" from being a silent fact.
        let roundingNoteKey: String
        let occurredOn: String

        var allKeys: [String] {
            [dateLabelKey, dateNoteKey, quantityHintKey, amountHintKey, roundingNoteKey]
        }
    }

    struct ConfirmBlock: Equatable {
        let summaryKey: String
        /// Fills `{count}` — the number of lines that READ as postable, not the number of
        /// products on screen. A user who filled in two of eleven is told two.
        let countedProducts: Int
        let currencyNoteKey: String
        let submitActionKey: String
        let cancelActionKey: String
        let canSubmit: Bool

        var allKeys: [String] {
            [summaryKey, currencyNoteKey, submitActionKey, cancelActionKey]
        }
    }

    struct OutcomeBlock: Equatable {
        let titleKey: String
        let messageKey: String
        /// Fills `{count}` on the partial sentence. Zero on the complete one, whose sentence
        /// carries no placeholder at all.
        let refusedCount: Int
        /// Product name plus a borrowed `inventory.error.*` key, in the order they were sent.
        let refusals: [InventoryOpeningRefusal]
        let dismissActionKey: String

        var allKeys: [String] { [titleKey, messageKey, dismissActionKey] }
        var refusalKeys: [String] { refusals.map(\.messageKey) }
    }

    struct Page: Equatable {
        /// `nil` only when the wizard is closed — the one state that draws nothing.
        let titleKey: String?
        let noteKeys: [String]
        /// Exactly two when blocked, empty otherwise.
        let blockedKeys: [String]
        /// The one action a blocked page offers.
        let blockedDismissKey: String?
        let list: ListBlock?
        let form: FormBlock?
        let confirm: ConfirmBlock?
        let outcome: OutcomeBlock?

        var allKeys: Set<String> {
            var keys: Set<String> = []
            if let titleKey { keys.insert(titleKey) }
            keys.formUnion(noteKeys)
            keys.formUnion(blockedKeys)
            if let blockedDismissKey { keys.insert(blockedDismissKey) }
            keys.formUnion(list?.allKeys ?? [])
            keys.formUnion(form?.allKeys ?? [])
            keys.formUnion(confirm?.allKeys ?? [])
            keys.formUnion(outcome?.allKeys ?? [])
            return keys
        }
    }

    static let idlePage = Page(titleKey: nil, noteKeys: [], blockedKeys: [],
                               blockedDismissKey: nil, list: nil, form: nil, confirm: nil,
                               outcome: nil)

    /// Compose the wizard for one state.
    static func compose(_ state: InventoryOpeningState) -> Page {
        switch state {
        case .idle:
            return idlePage

        case .blocked(let blocker):
            return Page(titleKey: pageTitleKey,
                        noteKeys: [],
                        blockedKeys: keys(for: blocker),
                        blockedDismissKey: "common.cancel",
                        list: nil, form: nil, confirm: nil, outcome: nil)

        case .editing(let draft):
            return Page(titleKey: pageTitleKey,
                        noteKeys: ["inventory.opening.intro", "inventory.opening.forwardNote"],
                        blockedKeys: [],
                        blockedDismissKey: nil,
                        list: listBlock(for: draft),
                        form: FormBlock(dateLabelKey: "inventory.opening.date.label",
                                        dateNoteKey: "inventory.opening.date.note",
                                        quantityHintKey: "inventory.opening.quantityHint",
                                        amountHintKey: "inventory.opening.amountHint",
                                        roundingNoteKey: "inventory.opening.roundingNote",
                                        occurredOn: draft.occurredOn),
                        confirm: ConfirmBlock(summaryKey: "inventory.opening.summary",
                                              countedProducts: draft.entries.count,
                                              currencyNoteKey: "inventory.opening.currencyNote",
                                              submitActionKey: "inventory.opening.action.post",
                                              cancelActionKey: "common.cancel",
                                              canSubmit: draft.isPostable),
                        outcome: nil)

        case .done:
            return outcomePage(titleKey: "inventory.opening.done.title",
                               messageKey: "inventory.opening.done.message",
                               refusals: [])

        case .partial(let refusals):
            return outcomePage(titleKey: "inventory.opening.partial.title",
                               messageKey: "inventory.opening.partial.message",
                               refusals: refusals)
        }
    }

    private static func outcomePage(titleKey: String, messageKey: String,
                                    refusals: [InventoryOpeningRefusal]) -> Page {
        Page(titleKey: pageTitleKey,
             noteKeys: [],
             blockedKeys: [],
             blockedDismissKey: nil,
             list: nil, form: nil, confirm: nil,
             outcome: OutcomeBlock(titleKey: titleKey,
                                   messageKey: messageKey,
                                   refusedCount: refusals.count,
                                   refusals: refusals,
                                   dismissActionKey: "common.ok"))
    }

    private static func listBlock(for draft: InventoryOpeningDraft) -> ListBlock {
        ListBlock(productHeaderKey: "inventory.opening.col.product",
                  quantityHeaderKey: "inventory.opening.col.quantity",
                  amountHeaderKey: "inventory.opening.col.amount",
                  unitCostHeaderKey: "inventory.opening.col.unitCost",
                  rows: draft.lines.map { line in
                      RowBlock(productID: line.productID,
                               productName: line.name,
                               quantityText: line.quantityText,
                               amountText: line.amountText,
                               impliedUnitCostMicro: draft.impliedUnitCostMicro(of: line))
                  })
    }
}

// MARK: - The wizard's draft

/// What the user has typed, and the rules for what may be posted out of it.
///
/// A value type rather than a handful of `@Published` fields, so every rule below is a pure
/// function a test can exercise without a view, a model or a ledger.
struct InventoryOpeningDraft: Equatable {
    /// The switch-over date, shared by every line. One date for the batch is what makes N-6's
    /// consequence one sentence instead of one per product.
    var occurredOn: String
    var lines: [Line]
    /// Products left out of the list because they already have live movements. Carried so the
    /// screen can be honest that this is not the whole catalogue.
    let alreadyMovingCount: Int

    struct Line: Equatable, Identifiable {
        let productID: String
        let name: String
        var quantityText: String
        var amountText: String

        var id: String { productID }

        init(productID: String, name: String, quantityText: String = "", amountText: String = "") {
            self.productID = productID
            self.name = name
            self.quantityText = quantityText
            self.amountText = amountText
        }
    }

    init(plan: InventoryOpeningPlan, occurredOn: String) {
        self.occurredOn = occurredOn
        self.alreadyMovingCount = plan.alreadyMovingCount
        self.lines = plan.candidates.map { Line(productID: $0.productID, name: $0.name) }
    }

    /// What one line is, as the wizard reads it.
    ///
    /// The three cases are not decoration. `blank` is the documented way to leave a product out;
    /// `complete` is a line that can be posted; and `incomplete` — one field readable and the
    /// other not — must BLOCK the whole submission rather than be dropped. Dropping it is the
    /// defect that matters here: a user types a quantity, forgets the amount, presses the button
    /// and is told everything went in, while that product silently has no opening and can never
    /// be given one without first posting a stock count.
    enum LineState: Equatable {
        case blank
        case complete(InventoryOpeningEntry)
        case incomplete
    }

    static func state(of line: Line) -> LineState {
        let quantity = line.quantityText.trimmingCharacters(in: .whitespaces)
        let amount = line.amountText.trimmingCharacters(in: .whitespaces)
        if quantity.isEmpty && amount.isEmpty { return .blank }
        guard let quantityMilli = InventoryPageComposition.scaled(
                  quantity, decimals: InventoryPageComposition.Decimals.quantity),
              quantityMilli > 0,
              let amountMinor = InventoryPageComposition.scaled(
                  amount, decimals: InventoryPageComposition.Decimals.amount),
              amountMinor >= 0
        else { return .incomplete }
        return .complete(InventoryOpeningEntry(productID: line.productID,
                                               quantityMilli: quantityMilli,
                                               amountMinor: amountMinor))
    }

    /// The unit cost a line implies, or `nil` when it does not read as a postable pair.
    func impliedUnitCostMicro(of line: Line) -> Int64? {
        guard case .complete(let entry) = Self.state(of: line) else { return nil }
        return try? InventoryOpening.unitCostMicro(amountMinor: entry.amountMinor,
                                                   quantityMilli: entry.quantityMilli)
    }

    /// The lines that would be posted. Blank lines are left out; an incomplete one is not here
    /// either, but it also stops ``isPostable``, so it cannot be lost by omission.
    var entries: [InventoryOpeningEntry] {
        lines.compactMap {
            if case .complete(let entry) = Self.state(of: $0) { return entry }
            return nil
        }
    }

    var hasIncompleteLine: Bool {
        lines.contains { Self.state(of: $0) == .incomplete }
    }

    /// Whether the sheet reads as something postable at all. Says nothing about whether the
    /// LEDGER will accept it — D-5, D-1 and N-6 are the engine's to enforce, and their refusals
    /// come back per product on the outcome page.
    var isPostable: Bool {
        !occurredOn.isEmpty && !entries.isEmpty && !hasIncompleteLine
    }

    func request(currency: String) -> InventoryOpeningRequest? {
        guard isPostable, !currency.isEmpty else { return nil }
        return InventoryOpeningRequest(occurredOn: occurredOn, currency: currency, entries: entries)
    }
}
