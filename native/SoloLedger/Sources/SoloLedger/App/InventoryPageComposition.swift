import Foundation
import SoloLedgerCore

/// What the inventory page draws, region by region, as a value a test can hold.
///
/// ## Why this exists
///
/// The same reason `ProductPageComposition` does: XCUITest cannot run in a headless session, so
/// "is it on screen" has to be answerable structurally. The view has no other source of keys —
/// each subview is handed its slice of these values and renders exactly what the slice names —
/// which is why `InventoryView.swift` holds no `inventory.` string literal at all.
///
/// ## `[String: Set<Region>]`, and why this page needs it
///
/// Three facts about THIS page, each of which a one-region-per-key map would have to lose:
///
///  * `inventory.form.title` is both the label of the control that opens the panel and the
///    panel's own heading. The copy has no separate action key, so the button borrows it.
///  * Six of the eight column headings are also the form's field labels. That is not a choice
///    made here: `InventoryCopyTests`' region buckets already pin it, with `inventory.col.cost`
///    and `inventory.col.status` deliberately excluded from the form.
///  * The eight `inventory.type.*` labels are both a row's type cell and the form's type picker.
///
/// ## Rounding and scale (N-8 derived prohibition)
///
/// The engine keeps three integer scales (`quantityMilli` ×1e3, `unitCostMicro` ×1e6,
/// `costBalanceMinor` ×1). Turning them into text happens HERE and nowhere else, on integers:
/// quantity and amounts need no rounding at all (their stored scale already IS the display
/// scale), and the only figure that does — the average — is rounded by ``ticksAwayFromZero(_:per:)``,
/// this file's integer form of `.toNearestOrAwayFromZero`.
///
/// Nothing here calls `ReportMath` (the App target may not name it at all) and nothing reuses
/// `ReportFormat.money`, whose two fixed decimals would flatten a three-decimal quantity and a
/// four-decimal average.
///
/// ## Nothing constructs `InventoryView` yet
///
/// This stage lands the page compiled, tested and unreachable: no `SidebarSection` case, no
/// `RootView` branch, and `InventoryMountingTests` asserts the absence of every construction
/// site. The sidebar entry is a later stage.
enum InventoryPageComposition {

    // MARK: - Regions

    /// Where on the page a key is drawn.
    enum Region: String, CaseIterable, Equatable {
        /// Page subtitle. The title is drawn by the window's navigation title.
        case header
        /// The three standing declarations: the costing basis, the report boundary, the units.
        case note
        /// The one control that opens the new-movement panel.
        case action
        /// The control that opens the opening-stock wizard, and its hint. The wizard's own copy
        /// belongs to `InventoryOpeningComposition`; these two are placed HERE because this
        /// page's header is what draws them, and what draws a key decides where it is placed.
        case openingAction
        /// The single sentence a refused write leaves behind.
        case errorBanner
        /// On hand / cost balance / current average, plus the currency declaration.
        case balanceCard
        /// The eight column headings.
        case listHeader
        case typeCell
        case statusCell
        /// The product's unit, drawn beside every quantity. Reached only by ``sharedKeys``.
        case unitLabel
        /// The new-movement panel.
        case form
        /// The eight options inside that panel's type control.
        case typePicker
        /// The per-row reverse control — present on the last live row only.
        case rowAction
        case reverseDialog
        /// The standing note under the list that explains why only one row has that control.
        case listNote
        case empty
        /// The "no opening stock" advice, which is true exactly while an opening is still legal.
        case openingHint
        case exception
    }

    // MARK: - Placement

    /// Every `inventory.*` key this page can draw, and the regions it belongs to.
    ///
    /// Seventy: the sixty-eight N-PR-3 landed for the page itself, plus the two the opening-stock
    /// wizard's entry point needs — that control lives in this page's header, so this page draws
    /// it. The rest of `inventory.opening.*` belongs to `InventoryOpeningComposition`, and
    /// `InventoryMountingTests` asserts the two tables PARTITION the ninety-three: disjoint, and
    /// together the whole namespace. See ``exemptKeys``.
    static let placement: [String: Set<Region>] = [
        // MARK: header (2)
        "inventory.page.title": [.header],
        "inventory.page.subtitle": [.header],
        // MARK: note (3)
        "inventory.page.basisNote": [.note],
        "inventory.page.reportNote": [.note],
        "inventory.page.unitNote": [.note],
        // MARK: listHeader, six of them also form field labels (8)
        "inventory.col.date": [.listHeader, .form],
        "inventory.col.type": [.listHeader, .form],
        "inventory.col.quantity": [.listHeader, .form],
        "inventory.col.unitCost": [.listHeader, .form],
        "inventory.col.cost": [.listHeader],
        "inventory.col.source": [.listHeader, .form],
        "inventory.col.note": [.listHeader, .form],
        "inventory.col.status": [.listHeader],
        // MARK: statusCell (3)
        "inventory.status.posted": [.statusCell],
        "inventory.status.reversed": [.statusCell],
        "inventory.status.reversal": [.statusCell],
        // MARK: typeCell + typePicker (8)
        "inventory.type.purchaseIn": [.typeCell, .typePicker],
        "inventory.type.saleOut": [.typeCell, .typePicker],
        "inventory.type.saleReturnIn": [.typeCell, .typePicker],
        "inventory.type.purchaseReturnOut": [.typeCell, .typePicker],
        "inventory.type.countGain": [.typeCell, .typePicker],
        "inventory.type.countLoss": [.typeCell, .typePicker],
        "inventory.type.manualAdjust": [.typeCell, .typePicker],
        "inventory.type.opening": [.typeCell, .typePicker],
        // MARK: balanceCard (5)
        "inventory.balance.title": [.balanceCard],
        "inventory.balance.quantity": [.balanceCard],
        "inventory.balance.cost": [.balanceCard],
        "inventory.balance.unitCost": [.balanceCard],
        "inventory.balance.currencyNote": [.balanceCard],
        // MARK: action + form (7)
        "inventory.form.title": [.action, .form],
        "inventory.form.quantityPlaceholder": [.form],
        "inventory.form.unitCostHint": [.form],
        "inventory.form.costDelta": [.form],
        "inventory.form.costDeltaHint": [.form],
        "inventory.form.sourcePlaceholder": [.form],
        "inventory.form.submit": [.form],
        // MARK: errorBanner (18)
        "inventory.error.netAmountRequired": [.errorBanner],
        "inventory.error.unitCostMustNotBeNegative": [.errorBanner],
        "inventory.error.quantityMustBePositive": [.errorBanner],
        "inventory.error.manualAdjustMustNotMoveQuantity": [.errorBanner],
        "inventory.error.manualAdjustRequiresStock": [.errorBanner],
        "inventory.error.costBalanceWouldGoNegative": [.errorBanner],
        "inventory.error.insufficientStock": [.errorBanner],
        "inventory.error.backdatedNotSupported": [.errorBanner],
        "inventory.error.currencyMismatch": [.errorBanner],
        "inventory.error.openingMustBeFirst": [.errorBanner],
        "inventory.error.returnExceedsOrigin": [.errorBanner],
        "inventory.error.onlyTheLastMovementCanBeReversed": [.errorBanner],
        "inventory.error.movementAlreadyReversed": [.errorBanner],
        "inventory.error.reversalTargetNotFound": [.errorBanner],
        "inventory.error.productNotFound": [.errorBanner],
        "inventory.error.arithmeticOverflow": [.errorBanner],
        "inventory.error.ledgerInconsistent": [.errorBanner],
        "inventory.error.storageFailure": [.errorBanner],
        // MARK: empty + openingHint (6)
        "inventory.empty.noProduct.title": [.empty],
        "inventory.empty.noProduct.message": [.empty],
        "inventory.empty.noMovement.title": [.empty],
        "inventory.empty.noMovement.message": [.empty],
        "inventory.empty.noOpening.title": [.openingHint],
        "inventory.empty.noOpening.message": [.openingHint],
        // MARK: rowAction + reverseDialog + listNote (4)
        "inventory.reverse.action": [.rowAction, .reverseDialog],
        "inventory.reverse.confirmTitle": [.reverseDialog],
        "inventory.reverse.confirmMessage": [.reverseDialog],
        "inventory.reverse.onlyLastNote": [.listNote],
        // MARK: openingAction (2) — the wizard's entry point, drawn by this page's header
        "inventory.opening.cta": [.openingAction],
        "inventory.opening.cta.hint": [.openingAction],
        // MARK: exception (4)
        "inventory.exception.title": [.exception],
        "inventory.exception.returnOriginNotFound": [.exception],
        "inventory.exception.manualAdjust": [.exception],
        "inventory.exception.openingSeeded": [.exception],
    ]

    /// The keys this page borrows from other namespaces, and where they land.
    ///
    /// Kept OUT of ``placement`` on purpose, exactly as the products page keeps its four
    /// `common.*` borrowings out of its own: that map's contract is "total over `inventory.*`",
    /// and the closure test compares it to the namespace as an equality in both directions.
    ///
    /// The eleven unit labels are spelled from their stored keys rather than written out one by
    /// one. Two reasons, both mechanical: `ProductCopyTests` asserts that every `product.*` key
    /// is named as a literal by `ProductPageComposition.swift` and by no other file, and
    /// `ProductMountingTests` asserts that `ProductPageComposition` itself is named by exactly
    /// three files, none of them this one. Deriving the keys satisfies both, and
    /// `InventoryMountingTests` compares the derived set against `ProductUnit.allCases` so it
    /// cannot go stale — a twelfth unit fails there rather than silently losing a label.
    static let sharedKeys: [String: Set<Region>] = {
        var out: [String: Set<Region>] = ["common.cancel": [.form, .reverseDialog]]
        for raw in unitRawValues { out["product.unit.\(raw)"] = [.unitLabel] }
        return out
    }()

    /// The stored unit keys, in the write-side whitelist's own order.
    ///
    /// Hand-written here and nowhere else in this target, for the naming reasons above; pinned
    /// against the real enum by `InventoryMountingTests`.
    static let unitRawValues = ["piece", "box", "bag", "kg", "ton", "liter",
                                "bottle", "pack", "session", "hour", "month"]

    /// Keys written into the copy that this page deliberately does not place.
    ///
    /// Empty, and asserted to be empty. A page whose closure test is `placement ∪ exemptions`
    /// can absorb a stray key by growing the exemption list; keeping this at zero means the
    /// closure is a plain equality, and anyone who needs an exemption has to change this
    /// declaration first.
    static let exemptKeys: Set<String> = []

    /// The window title. Named here rather than written into the view, so every string the page
    /// draws is reachable from this one file.
    static let pageTitleKey = "inventory.page.title"

    /// The `source_type` every movement this page writes carries.
    ///
    /// One constant for the whole of V1, where every movement is keyed in by hand. It is what
    /// makes a return findable: the engine looks an origin document up by `(sourceType, sourceID)`
    /// together, so a sale and the return that points at it must agree on both halves. What KIND
    /// of event a row is stays in `movement_type`, and a hand-entered opening is additionally
    /// recorded by the engine's own `openingSeeded` exception — this string carries neither
    /// meaning, and the other values are reserved for real documents and platform connectors.
    static let manualSourceType = "manual"

    // MARK: - Error copy

    /// The one place an `InventoryPostingError` becomes a sentence.
    ///
    /// Exhaustive with no `default`: a nineteenth case stops this file compiling instead of
    /// silently falling into a bucket. The enum carries no payload, so there is nothing here
    /// that could print a statement, a path or SQLite's own wording even by accident.
    static func key(for error: InventoryPostingError) -> String {
        switch error {
        case .netAmountRequired:                return "inventory.error.netAmountRequired"
        case .unitCostMustNotBeNegative:        return "inventory.error.unitCostMustNotBeNegative"
        case .quantityMustBePositive:           return "inventory.error.quantityMustBePositive"
        case .manualAdjustMustNotMoveQuantity:  return "inventory.error.manualAdjustMustNotMoveQuantity"
        case .manualAdjustRequiresStock:        return "inventory.error.manualAdjustRequiresStock"
        case .costBalanceWouldGoNegative:       return "inventory.error.costBalanceWouldGoNegative"
        case .insufficientStock:                return "inventory.error.insufficientStock"
        case .backdatedNotSupported:            return "inventory.error.backdatedNotSupported"
        case .currencyMismatch:                 return "inventory.error.currencyMismatch"
        case .openingMustBeFirst:               return "inventory.error.openingMustBeFirst"
        case .returnExceedsOrigin:              return "inventory.error.returnExceedsOrigin"
        case .onlyTheLastMovementCanBeReversed: return "inventory.error.onlyTheLastMovementCanBeReversed"
        case .movementAlreadyReversed:          return "inventory.error.movementAlreadyReversed"
        case .reversalTargetNotFound:           return "inventory.error.reversalTargetNotFound"
        case .productNotFound:                  return "inventory.error.productNotFound"
        case .arithmeticOverflow:               return "inventory.error.arithmeticOverflow"
        case .ledgerInconsistent:               return "inventory.error.ledgerInconsistent"
        case .storageFailure:                   return "inventory.error.storageFailure"
        }
    }

    /// The label of one movement kind. Exhaustive for the same reason.
    static func key(for type: InventoryMovementType) -> String {
        switch type {
        case .purchaseIn:        return "inventory.type.purchaseIn"
        case .saleOut:           return "inventory.type.saleOut"
        case .saleReturnIn:      return "inventory.type.saleReturnIn"
        case .purchaseReturnOut: return "inventory.type.purchaseReturnOut"
        case .countGain:         return "inventory.type.countGain"
        case .countLoss:         return "inventory.type.countLoss"
        case .manualAdjust:      return "inventory.type.manualAdjust"
        case .opening:           return "inventory.type.opening"
        }
    }

    /// The sentence one exception record reads as. Exhaustive for the same reason.
    static func key(for kind: InventoryExceptionKind) -> String {
        switch kind {
        case .returnOriginNotFound: return "inventory.exception.returnOriginNotFound"
        case .manualAdjust:         return "inventory.exception.manualAdjust"
        case .openingSeeded:        return "inventory.exception.openingSeeded"
        }
    }

    // MARK: - Row status

    /// What one stored row is, as the list reports it.
    ///
    /// Derived from the engine's OWN live set rather than re-deciding what "still counts" means:
    /// `liveInventoryMovements` drops a reversed row and its reversal together, so a row that is
    /// missing from it and carries no `reversesID` is precisely a reversed one.
    enum RowStatus: Equatable {
        case posted
        case reversed
        case reversal

        var key: String {
            switch self {
            case .posted:   return "inventory.status.posted"
            case .reversed: return "inventory.status.reversed"
            case .reversal: return "inventory.status.reversal"
            }
        }
    }

    static func status(of movement: InventoryPostedMovement, liveIDs: Set<String>) -> RowStatus {
        if movement.isReversal { return .reversal }
        return liveIDs.contains(movement.id) ? .posted : .reversed
    }

    // MARK: - Form fields

    /// Which of the three amount fields a movement kind asks for.
    ///
    /// Read off the engine's own vocabulary — ``InventoryMovementType/direction`` and
    /// ``InventoryMovementType/isReturn`` — rather than restated as a table of eight rows. A
    /// table would be the same rule written twice, and the copy of it in this file would not go
    /// red on the day the engine changed its mind; the screen would simply start asking for a
    /// field the engine refuses.
    ///
    /// The three shapes that fall out:
    ///
    ///  * an inbound that is not a return (`purchaseIn` / `countGain` / `opening`) must carry its
    ///    own tax-exclusive unit cost — N-7, and a count gain may not quietly borrow the average;
    ///  * a return of either direction takes its basis from the origin document (N-4), so there
    ///    is no unit cost to type;
    ///  * an average-priced issue takes the average in force before it (N-1), likewise;
    ///  * `manualAdjust` moves no quantity at all and carries a signed cost delta (F1 案丙).
    struct FieldSet: Equatable {
        let showsQuantity: Bool
        let showsUnitCost: Bool
        let showsCostDelta: Bool
    }

    static func fields(for type: InventoryMovementType) -> FieldSet {
        switch type.direction {
        case .costOnly:
            return FieldSet(showsQuantity: false, showsUnitCost: false, showsCostDelta: true)
        case .inbound:
            return FieldSet(showsQuantity: true, showsUnitCost: !type.isReturn, showsCostDelta: false)
        case .outbound:
            return FieldSet(showsQuantity: true, showsUnitCost: false, showsCostDelta: false)
        }
    }

    // MARK: - Scales and display rounding

    /// Digits after the separator, per figure.
    ///
    /// Quantity and amounts are EXACT: `quantityMilli` already is three decimals and a minor
    /// unit already is two, so nothing is rounded away and no policy is being chosen. The
    /// average is the one figure that has to be rounded, and it gets four rather than two —
    /// at two, an average of 0.004 would read as `0.00`, and a non-zero figure shown as zero is
    /// exactly the misleading display this app must not produce.
    enum Decimals {
        static let quantity = 3
        static let amount = 2
        static let average = 4
    }

    /// `.toNearestOrAwayFromZero`, written on integers.
    ///
    /// On integers rather than on a `Double` because every input here is an `Int64` whose
    /// magnitude can exceed 2^53, where a `Double` no longer represents it exactly. Ties go
    /// away from zero in both directions, which is the whole point of naming the rule.
    static func ticksAwayFromZero(_ value: Int64, per divisor: Int64) -> Int64 {
        precondition(divisor > 0, "a scale divisor is positive")
        let quotient = value / divisor          // truncates toward zero
        let remainder = value % divisor         // carries the sign of `value`
        // `remainder.magnitude < divisor`, so doubling it cannot overflow a UInt64, and
        // `|quotient| <= |value| / divisor`, so the step below cannot overflow an Int64.
        guard remainder.magnitude * 2 >= UInt64(divisor) else { return quotient }
        return value >= 0 ? quotient + 1 : quotient - 1
    }

    /// A quantity as text: `quantityMilli` at three decimals, exactly.
    static func quantityText(_ quantityMilli: Int64, language: String) -> String {
        text(decimal(quantityMilli, exponent: -3), decimals: Decimals.quantity, language: language)
    }

    /// An amount as text: minor units at two decimals, exactly. No currency symbol and no code —
    /// the copy has no caption to label one with, and an unlabelled code beside a number would
    /// be a value this page cannot say what it means. `inventory.balance.currencyNote` states
    /// the rule instead.
    static func amountText(_ minor: Int64, language: String) -> String {
        text(decimal(minor, exponent: -2), decimals: Decimals.amount, language: language)
    }

    /// The average as text: `unitCostMicro` is a cost per unit in minor units ×1e6, so a major
    /// unit is 1e8 of it and a four-decimal tick is 1e4 of it. The one rounding on the page.
    static func averageText(_ unitCostMicro: Int64, language: String) -> String {
        let ticks = ticksAwayFromZero(unitCostMicro, per: 10_000)
        return text(decimal(ticks, exponent: -4), decimals: Decimals.average, language: language)
    }

    /// An exact `Decimal` for `value × 10^exponent`. Built rather than divided, so no rounding
    /// can enter through the arithmetic.
    private static func decimal(_ value: Int64, exponent: Int) -> Decimal {
        Decimal(sign: value < 0 ? .minus : .plus,
                exponent: exponent,
                significand: Decimal(value.magnitude))
    }

    /// Group separators are the locale's; the decimal separator is too.
    ///
    /// Grouping is left on, unlike `ProductFormDraft.costText(_:)`, and the difference is not an
    /// inconsistency: that function SEEDS an editable field and has to round-trip through a
    /// parser, whereas nothing on this page is ever seeded from a formatted string — the panel
    /// only ever creates a movement, never edits one, so the seed-and-parse mismatch it guards
    /// against cannot arise here.
    private static func text(_ value: Decimal, decimals: Int, language: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: language)
        formatter.minimumFractionDigits = decimals
        formatter.maximumFractionDigits = decimals
        let number = NSDecimalNumber(decimal: value)
        // Reached only if `NumberFormatter` returns nil, which it does not for a finite decimal.
        // Present so the function is total and never renders an empty cell.
        return formatter.string(from: number) ?? number.stringValue
    }

    // MARK: - Typing a scaled integer

    /// Read a typed decimal into a scaled `Int64`, or `nil` when it cannot be read EXACTLY.
    ///
    /// No `Double` anywhere: `Double("0.1")` is not one tenth, and a quantity that is off in the
    /// last place is a wrong quantity. More fraction digits than the scale can carry is a
    /// refusal rather than a rounding — the engine cannot store them, and silently dropping them
    /// would post a number the user did not type.
    ///
    /// Grouping separators are refused for the same reason `ProductFormDraft.parseCost(_:)`
    /// refuses them: `1,000` means a thousand in one locale and one in another, and this app is
    /// in no position to decide which.
    static func scaled(_ text: String, decimals: Int) -> Int64? {
        precondition(decimals >= 0, "a scale has no negative digits")
        var body = Substring(text.trimmingCharacters(in: .whitespaces))
        guard !body.isEmpty else { return nil }
        var negative = false
        if body.first == "-" { negative = true; body = body.dropFirst() }
        else if body.first == "+" { body = body.dropFirst() }

        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 else { return nil }
        let whole = parts[0]
        let fraction = parts.count == 2 ? parts[1] : ""
        guard !(whole.isEmpty && fraction.isEmpty) else { return nil }
        guard whole.allSatisfy(isASCIIDigit), fraction.allSatisfy(isASCIIDigit) else { return nil }
        guard fraction.count <= decimals else { return nil }

        let padded = String(whole) + String(fraction) + String(repeating: "0",
                                                              count: decimals - fraction.count)
        guard let magnitude = UInt64(padded), magnitude <= UInt64(Int64.max) else { return nil }
        let value = Int64(magnitude)
        return negative ? -value : value
    }

    private static func isASCIIDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }

    // MARK: - The page's input

    /// One selectable product: what the picker shows and what it selects with. Deliberately not
    /// the store's own row type — this page reads master data, it does not manage it.
    struct ProductChoice: Equatable, Identifiable {
        let id: String
        let name: String

        init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// How the selected product's unit reads on screen: the already-classified answer of the
    /// products page's own three-armed rule, carried here as a value.
    enum UnitLabel: Equatable {
        case key(String)
        case verbatim(String)
        case none
    }

    /// Everything the composition needs, and nothing that could let it read the ledger itself.
    struct Input: Equatable {
        /// The products a movement can be recorded against. Rows that could not be decoded are
        /// not among them and are not counted here either: an undecodable row is not selectable,
        /// and the one page that reports such rows is the products page, which is exactly where
        /// `inventory.empty.noProduct.message` sends the user.
        var products: [ProductChoice]
        var selectedProductID: String?
        var unit: UnitLabel
        var balance: InventoryBalance?
        /// The AUDIT view — reversed rows and their reversals included. It has to be: the copy
        /// has a `reversed` and a `reversal` status, and a list built from the live rows could
        /// never draw either of them.
        var movements: [InventoryPostedMovement]
        /// The ids of the rows that still count, in the engine's own order.
        var liveIDs: [String]
        var exceptions: [InventoryException]
        var form: InventoryFormDraft?
        var pendingReversal: InventoryPostedMovement?
        var error: InventoryPostingError?

        init(products: [ProductChoice] = [],
             selectedProductID: String? = nil,
             unit: UnitLabel = .none,
             balance: InventoryBalance? = nil,
             movements: [InventoryPostedMovement] = [],
             liveIDs: [String] = [],
             exceptions: [InventoryException] = [],
             form: InventoryFormDraft? = nil,
             pendingReversal: InventoryPostedMovement? = nil,
             error: InventoryPostingError? = nil) {
            self.products = products
            self.selectedProductID = selectedProductID
            self.unit = unit
            self.balance = balance
            self.movements = movements
            self.liveIDs = liveIDs
            self.exceptions = exceptions
            self.form = form
            self.pendingReversal = pendingReversal
            self.error = error
        }
    }

    // MARK: - One render

    struct RowBlock: Equatable, Identifiable {
        let id: String
        let occurredOn: String
        let typeKey: String
        let status: RowStatus
        let quantityMilli: Int64
        /// `nil` on an average-priced issue, whose price is the balance's and not its own.
        let unitCostMicro: Int64?
        let totalCostMinor: Int64?
        /// Stored text, drawn as it stands.
        let source: String
        let note: String
        /// Non-nil on the product's last live row and on no other: only that row can be
        /// reversed, so only that row offers the control.
        let reverseActionKey: String?

        var statusKey: String { status.key }
        /// A reversed row and a reversal row are both still in the ledger, but neither is what
        /// the balance is made of — the list says so in words and draws them back.
        var isSuperseded: Bool { status != .posted }
        var allKeys: [String] { [typeKey, statusKey] + (reverseActionKey.map { [$0] } ?? []) }
    }

    struct ListBlock: Equatable {
        /// The eight headings in DRAW order.
        let dateHeaderKey: String
        let typeHeaderKey: String
        let quantityHeaderKey: String
        let unitCostHeaderKey: String
        let costHeaderKey: String
        let sourceHeaderKey: String
        let noteHeaderKey: String
        let statusHeaderKey: String
        /// Why only one row carries the reverse control, said once under the list.
        let onlyLastNoteKey: String
        let unit: UnitLabel
        let rows: [RowBlock]

        var headerKeys: [String] {
            [dateHeaderKey, typeHeaderKey, quantityHeaderKey, unitCostHeaderKey,
             costHeaderKey, sourceHeaderKey, noteHeaderKey, statusHeaderKey]
        }
        var allKeys: [String] {
            headerKeys + [onlyLastNoteKey] + unit.keys + rows.flatMap(\.allKeys)
        }
    }

    struct BalanceBlock: Equatable {
        let titleKey: String
        /// The name that fills `{name}`. Carried here so the view never looks anything up.
        let productName: String
        let quantityLabelKey: String
        let costLabelKey: String
        let unitCostLabelKey: String
        let currencyNoteKey: String
        let quantityMilli: Int64
        let costBalanceMinor: Int64
        let unitCostMicro: Int64
        let unit: UnitLabel

        var labelKeys: [String] { [quantityLabelKey, costLabelKey, unitCostLabelKey] }
        var allKeys: [String] { [titleKey] + labelKeys + [currencyNoteKey] + unit.keys }
    }

    /// One option of the type control: what would be posted, and what it reads as.
    struct TypeOption: Equatable, Identifiable {
        let type: InventoryMovementType
        let labelKey: String
        var id: String { type.rawValue }
    }

    struct FormBlock: Equatable {
        let titleKey: String
        let dateLabelKey: String
        let typeLabelKey: String
        /// All eight, always: the control offers the whole vocabulary whatever is selected.
        let typeOptions: [TypeOption]
        /// `nil` when the selected kind moves no quantity.
        let quantityLabelKey: String?
        let quantityPlaceholderKey: String?
        /// `nil` unless the selected kind must carry its own tax-exclusive unit cost.
        let unitCostLabelKey: String?
        let unitCostHintKey: String?
        /// `nil` unless the selected kind is the cost-only correction.
        let costDeltaLabelKey: String?
        let costDeltaHintKey: String?
        let sourceLabelKey: String
        let sourcePlaceholderKey: String
        let noteLabelKey: String
        let submitActionKey: String
        let cancelActionKey: String
        let unit: UnitLabel
        /// Whether the panel currently reads as a postable movement.
        let canSubmit: Bool

        var fieldLabelKeys: [String] {
            [dateLabelKey, typeLabelKey, sourceLabelKey, noteLabelKey]
                + [quantityLabelKey, unitCostLabelKey, costDeltaLabelKey].compactMap { $0 }
        }
        var hintKeys: [String] {
            [quantityPlaceholderKey, unitCostHintKey, costDeltaHintKey].compactMap { $0 }
                + [sourcePlaceholderKey]
        }
        var actionKeys: [String] { [submitActionKey, cancelActionKey] }
        var allKeys: [String] {
            [titleKey] + fieldLabelKeys + hintKeys + actionKeys
                + typeOptions.map(\.labelKey) + unit.keys
        }
    }

    struct ReverseBlock: Equatable {
        let titleKey: String
        let messageKey: String
        let confirmActionKey: String
        let cancelActionKey: String

        var actionKeys: [String] { [confirmActionKey, cancelActionKey] }
        var allKeys: [String] { [titleKey, messageKey] + actionKeys }
    }

    struct ExceptionRow: Equatable, Identifiable {
        let id: String
        let messageKey: String
    }

    struct ExceptionBlock: Equatable {
        let titleKey: String
        let rows: [ExceptionRow]

        var allKeys: [String] { [titleKey] + rows.map(\.messageKey) }
    }

    struct Page: Equatable {
        let titleKey: String
        let headerKeys: [String]
        let noteKeys: [String]
        let actionKeys: [String]
        /// The opening-stock wizard's entry point. Always drawn: a ledger with no products still
        /// gets the button, because the wizard's own `noProduct` page is a better answer than a
        /// disabled control with nothing to explain it.
        let openingActionKey: String
        let openingHintKey: String
        /// One sentence, or none.
        let errorKeys: [String]
        let products: [ProductChoice]
        let selectedProductID: String?
        /// `nil` whenever there is no row to draw, so the card and the empty state are never on
        /// screen together.
        let balance: BalanceBlock?
        let list: ListBlock?
        /// "No products yet" OR "no movements for this product" — never both, and never with a
        /// list.
        let emptyKeys: [String]
        /// True exactly while an opening is still legal, which is what makes the advice
        /// actionable: once a live movement exists the engine refuses an opening for good.
        let openingHintKeys: [String]
        let form: FormBlock?
        let reverse: ReverseBlock?
        let exceptions: ExceptionBlock?

        var allKeys: Set<String> {
            var keys: Set<String> = [titleKey]
            keys.formUnion(headerKeys)
            keys.formUnion(noteKeys)
            keys.formUnion(actionKeys)
            keys.insert(openingActionKey)
            keys.insert(openingHintKey)
            keys.formUnion(errorKeys)
            keys.formUnion(balance?.allKeys ?? [])
            keys.formUnion(list?.allKeys ?? [])
            keys.formUnion(emptyKeys)
            keys.formUnion(openingHintKeys)
            keys.formUnion(form?.allKeys ?? [])
            keys.formUnion(reverse?.allKeys ?? [])
            keys.formUnion(exceptions?.allKeys ?? [])
            return keys
        }
    }

    /// Compose the page for one input.
    static func compose(_ input: Input) -> Page {
        let selected = input.products.first { $0.id == input.selectedProductID }
            ?? input.products.first
        let errorKeys = input.error.map { [key(for: $0)] } ?? []

        guard let selected else {
            // Nothing to record a movement against. Everything below the header is a single
            // sentence pointing at the page that can fix it.
            return Page(titleKey: pageTitleKey,
                        headerKeys: Self.headerKeys,
                        noteKeys: Self.noteKeys,
                        actionKeys: Self.actionKeys,
                        openingActionKey: Self.openingActionKey,
                        openingHintKey: Self.openingHintKey,
                        errorKeys: errorKeys,
                        products: [],
                        selectedProductID: nil,
                        balance: nil,
                        list: nil,
                        emptyKeys: ["inventory.empty.noProduct.title",
                                    "inventory.empty.noProduct.message"],
                        openingHintKeys: [],
                        form: nil,
                        reverse: nil,
                        exceptions: nil)
        }

        let liveIDs = Set(input.liveIDs)
        let rows = input.movements.map { movement in
            RowBlock(id: movement.id,
                     occurredOn: movement.occurredOn,
                     typeKey: key(for: movement.type),
                     status: status(of: movement, liveIDs: liveIDs),
                     quantityMilli: movement.quantityMilli,
                     unitCostMicro: movement.unitCostMicro,
                     totalCostMinor: movement.totalCostMinor,
                     source: movement.sourceID ?? "",
                     note: movement.note ?? "",
                     reverseActionKey: movement.id == input.liveIDs.last
                        ? "inventory.reverse.action" : nil)
        }

        let list = rows.isEmpty ? nil : ListBlock(dateHeaderKey: "inventory.col.date",
                                                  typeHeaderKey: "inventory.col.type",
                                                  quantityHeaderKey: "inventory.col.quantity",
                                                  unitCostHeaderKey: "inventory.col.unitCost",
                                                  costHeaderKey: "inventory.col.cost",
                                                  sourceHeaderKey: "inventory.col.source",
                                                  noteHeaderKey: "inventory.col.note",
                                                  statusHeaderKey: "inventory.col.status",
                                                  onlyLastNoteKey: "inventory.reverse.onlyLastNote",
                                                  unit: input.unit,
                                                  rows: rows)

        let balance = list == nil ? nil : balanceBlock(input, product: selected)

        return Page(titleKey: pageTitleKey,
                    headerKeys: Self.headerKeys,
                    noteKeys: Self.noteKeys,
                    actionKeys: Self.actionKeys,
                    openingActionKey: Self.openingActionKey,
                    openingHintKey: Self.openingHintKey,
                    errorKeys: errorKeys,
                    products: input.products,
                    selectedProductID: selected.id,
                    balance: balance,
                    list: list,
                    emptyKeys: rows.isEmpty ? ["inventory.empty.noMovement.title",
                                               "inventory.empty.noMovement.message"] : [],
                    openingHintKeys: input.liveIDs.isEmpty ? ["inventory.empty.noOpening.title",
                                                              "inventory.empty.noOpening.message"] : [],
                    form: input.form.map { formBlock(for: $0, unit: input.unit) },
                    reverse: input.pendingReversal == nil ? nil : reverseBlock(),
                    exceptions: exceptionBlock(input))
    }

    private static let headerKeys = ["inventory.page.subtitle"]
    private static let noteKeys = ["inventory.page.basisNote",
                                   "inventory.page.reportNote",
                                   "inventory.page.unitNote"]
    /// The control that opens the panel borrows the panel's own heading — the copy has no
    /// separate action key, and inventing one would be a sixty-ninth string.
    private static let actionKeys = ["inventory.form.title"]
    /// The opening-stock wizard's entry point, beside it.
    private static let openingActionKey = "inventory.opening.cta"
    private static let openingHintKey = "inventory.opening.cta.hint"

    private static func balanceBlock(_ input: Input, product: ProductChoice) -> BalanceBlock {
        let balance = input.balance
        return BalanceBlock(titleKey: "inventory.balance.title",
                            productName: product.name,
                            quantityLabelKey: "inventory.balance.quantity",
                            costLabelKey: "inventory.balance.cost",
                            unitCostLabelKey: "inventory.balance.unitCost",
                            currencyNoteKey: "inventory.balance.currencyNote",
                            quantityMilli: balance?.quantityMilli ?? 0,
                            costBalanceMinor: balance?.costBalanceMinor ?? 0,
                            unitCostMicro: balance?.unitCostMicro ?? 0,
                            unit: input.unit)
    }

    private static func formBlock(for draft: InventoryFormDraft, unit: UnitLabel) -> FormBlock {
        let fields = self.fields(for: draft.type)
        return FormBlock(titleKey: "inventory.form.title",
                         dateLabelKey: "inventory.col.date",
                         typeLabelKey: "inventory.col.type",
                         typeOptions: InventoryMovementType.allCases.map {
                             TypeOption(type: $0, labelKey: key(for: $0))
                         },
                         quantityLabelKey: fields.showsQuantity ? "inventory.col.quantity" : nil,
                         quantityPlaceholderKey: fields.showsQuantity
                            ? "inventory.form.quantityPlaceholder" : nil,
                         unitCostLabelKey: fields.showsUnitCost ? "inventory.col.unitCost" : nil,
                         unitCostHintKey: fields.showsUnitCost ? "inventory.form.unitCostHint" : nil,
                         costDeltaLabelKey: fields.showsCostDelta ? "inventory.form.costDelta" : nil,
                         costDeltaHintKey: fields.showsCostDelta
                            ? "inventory.form.costDeltaHint" : nil,
                         sourceLabelKey: "inventory.col.source",
                         sourcePlaceholderKey: "inventory.form.sourcePlaceholder",
                         noteLabelKey: "inventory.col.note",
                         submitActionKey: "inventory.form.submit",
                         cancelActionKey: "common.cancel",
                         unit: fields.showsQuantity ? unit : .none,
                         canSubmit: draft.isPostable)
    }

    private static func reverseBlock() -> ReverseBlock {
        ReverseBlock(titleKey: "inventory.reverse.confirmTitle",
                     messageKey: "inventory.reverse.confirmMessage",
                     confirmActionKey: "inventory.reverse.action",
                     cancelActionKey: "common.cancel")
    }

    /// The exception records, in the order of the movements they belong to.
    ///
    /// The store returns them ordered by their own id, which is a fresh UUID — an order with no
    /// meaning on screen. Sorting them by where their movement sits in the list is a
    /// presentation decision and touches neither the engine nor what the records say. Records
    /// whose movement is not in the list keep their stored order, after the rest.
    private static func exceptionBlock(_ input: Input) -> ExceptionBlock? {
        guard !input.exceptions.isEmpty else { return nil }
        var position: [String: Int] = [:]
        for (index, movement) in input.movements.enumerated() { position[movement.id] = index }
        let rows = input.exceptions.enumerated()
            .sorted { left, right in
                let leftAt = left.element.movementID.flatMap { position[$0] } ?? Int.max
                let rightAt = right.element.movementID.flatMap { position[$0] } ?? Int.max
                if leftAt != rightAt { return leftAt < rightAt }
                return left.offset < right.offset
            }
            .map { ExceptionRow(id: $0.element.id, messageKey: key(for: $0.element.kind)) }
        return ExceptionBlock(titleKey: "inventory.exception.title", rows: rows)
    }
}

extension InventoryPageComposition.UnitLabel {
    /// The copy key this label draws, when it draws one at all.
    var keys: [String] {
        if case .key(let key) = self { return [key] }
        return []
    }
}

// MARK: - The panel's draft

/// The new-movement panel's editable state, and the rule for what it is allowed to post.
///
/// A value type rather than a handful of `@Published` fields, so the rule below is a pure
/// function a test can exercise without a view, a model or a ledger.
///
/// There is no edit path and there never will be: a posted movement is immutable by contract and
/// is corrected by appending, so this draft only ever creates.
struct InventoryFormDraft: Equatable {
    var type: InventoryMovementType
    /// `YYYY-MM-DD`, produced by the panel's date control.
    var occurredOn: String
    var quantityText: String
    var unitCostText: String
    var costDeltaText: String
    var sourceText: String
    var noteText: String

    init(occurredOn: String, type: InventoryMovementType = .purchaseIn) {
        self.type = type
        self.occurredOn = occurredOn
        quantityText = ""
        unitCostText = ""
        costDeltaText = ""
        sourceText = ""
        noteText = ""
    }

    /// The movement this panel would post, or `nil` when a field it is SHOWING cannot be read.
    ///
    /// A field the selected kind does not show is not consulted at all, so leftover text in a
    /// hidden field can never reach the ledger. Zero is a legal unit cost — a free sample — and
    /// an empty field is not zero; that difference is why the field is text and not a number.
    func request(productID: String, currency: String) -> InventoryPostingRequest? {
        guard !productID.isEmpty, !currency.isEmpty, !occurredOn.isEmpty else { return nil }
        let fields = InventoryPageComposition.fields(for: type)

        var quantityMilli: Int64 = 0
        if fields.showsQuantity {
            guard let typed = InventoryPageComposition.scaled(quantityText,
                                                              decimals: InventoryPageComposition.Decimals.quantity),
                  typed > 0 else { return nil }
            quantityMilli = typed
        }

        var unitCostMicro: Int64?
        if fields.showsUnitCost {
            // A major-currency price per unit, typed. `unitCostMicro` is minor units ×1e6, so a
            // major unit is 1e8 of it: eight digits are exactly representable and a ninth is not.
            guard let typed = InventoryPageComposition.scaled(unitCostText, decimals: 8),
                  typed >= 0 else { return nil }
            unitCostMicro = typed
        }

        var costDeltaMinor: Int64?
        if fields.showsCostDelta {
            guard let typed = InventoryPageComposition.scaled(costDeltaText,
                                                              decimals: InventoryPageComposition.Decimals.amount)
            else { return nil }
            costDeltaMinor = typed
        }

        let source = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        return InventoryPostingRequest(
            productID: productID,
            type: type,
            occurredOn: occurredOn,
            quantityMilli: quantityMilli,
            unitCostMicro: unitCostMicro,
            costDeltaMinor: costDeltaMinor,
            currency: currency,
            sourceType: source.isEmpty ? nil : InventoryPageComposition.manualSourceType,
            sourceID: source.isEmpty ? nil : source,
            note: note.isEmpty ? nil : note)
    }

    /// Whether the panel reads as a postable movement at all, independent of any ledger.
    ///
    /// The submit control is disabled while this is false, so a panel that cannot post does not
    /// offer to. It says nothing about whether the LEDGER would accept it — insufficient stock,
    /// a frozen currency, an opening on a product that already moved are all the engine's to
    /// refuse, and their refusals reach the screen as one of the eighteen sentences.
    var isPostable: Bool {
        request(productID: "id", currency: "cur") != nil
    }
}
