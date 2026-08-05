import Foundation

/// The vocabulary of the native inventory ledger — movement kinds, the running balance, the
/// exception record, and the closed set of refusals.
///
/// ## This is not a mirror
///
/// Everything else under `Reports/` is a line-by-line port of Electron. This is not. The audited
/// Electron inventory read computes "purchases-to-date net ÷ purchases-to-date quantity × current
/// net on hand": sales never touch the average, so buy 10@100 → sell all → buy 10@200 reports a
/// remaining cost of 1500 where the true figure is 2000. It was rejected rather than ported. Every
/// rule here traces to the N0 costing ruling or to the N1 follow-up rulings, and each is cited at
/// the place it is enforced.
///
/// ## Integer scaling (N-8)
///
/// Money is integers. Three scales, and mixing them is the easiest mistake to make here:
///
/// | field | scale | meaning |
/// |---|---|---|
/// | `quantityMilli` | ×1e3 | quantity |
/// | `unitCostMicro` | ×1e6 | tax-exclusive cost of ONE unit, in minor currency units |
/// | `totalCostMinor` / `costBalanceMinor` | ×1 | minor currency units (cents) |
///
/// The bridge between them is `totalCostMinor = quantityMilli × unitCostMicro / 1e9`, and every
/// multiplication on that path goes through `multipliedReportingOverflow` and REFUSES on overflow
/// rather than wrapping (N1 §2.4).
///
/// ## Direction
///
/// Quantities are never negative; the direction is carried by the movement type, which is why
/// there is no sign column in the schema. Two consequences worth stating plainly:
///
///  * ``InventoryMovementType/manualAdjust`` moves NO quantity at all (F1 案丙). It is the
///    cost-only correction — "the purchase price was keyed in wrong" — which none of the other
///    seven types expresses. Anything that moves quantity without a document goes through
///    `countGain` / `countLoss`.
///  * A row carrying `reversesID` means the OPPOSITE of its type. One rule for all eight types;
///    see ``InventoryPostedMovement/effectiveDirection``.
///
/// ## STRICT is not input validation (measured, PR #452)
///
/// The v24 tables are STRICT, and it is tempting to lean on that. Do not. STRICT only refuses a
/// value that cannot be converted LOSSLESSLY: on SQLite 3.51.0 `TEXT '5'` is accepted into an
/// INTEGER column and stored as `5`, and `REAL 2.0` is stored as `2`; only `'abc'`, `1.5` and
/// `'1.5'` are refused. So N-5 (no negative stock), N-7 (no untaxed-cost inbound), D-1 (no
/// currency mixing) and D-10 (zero cost is legal, absent cost is not) are ALL enforced here, in
/// the engine, and none of them may be left to the schema to catch.

// MARK: - Movement kinds

/// The eight movement kinds — the closed set the v24 `CHECK` constraint carries.
///
/// Raw values are the stored strings; renaming a case without renaming the raw value would write
/// rows the CHECK refuses.
public enum InventoryMovementType: String, CaseIterable, Sendable {
    /// Goods received against a purchase. Requires an explicit tax-exclusive unit cost (N-7).
    case purchaseIn = "purchase_in"
    /// Goods issued against a sale. Costed at the average in force BEFORE the issue (N-1).
    case saleOut = "sale_out"
    /// A customer's return coming back into stock. Costed at the original sale's cost when the
    /// origin document is found, otherwise at the current average WITH an exception row (N-4).
    case saleReturnIn = "sale_return_in"
    /// Goods returned to a supplier. Costed at the original purchase's unit cost when the origin
    /// is found, otherwise at the current average WITH an exception row (N-4).
    case purchaseReturnOut = "purchase_return_out"
    /// A stock count found MORE than the books hold. An inbound, so N-7 applies: it must carry an
    /// explicit unit cost and may NOT silently borrow the current average.
    case countGain = "count_gain"
    /// A stock count found LESS than the books hold. Costed at the current average.
    case countLoss = "count_loss"
    /// A cost-only correction. Quantity is always zero; the cost delta may be negative (F1 案丙).
    case manualAdjust = "manual_adjust"
    /// The opening balance carried in at switch-over. Must be the product's FIRST movement (D-5).
    case opening = "opening"

    /// What this kind does to quantity, IGNORING any reversal. Use
    /// ``InventoryPostedMovement/effectiveDirection`` on a stored row.
    public var direction: InventoryMovementDirection {
        switch self {
        case .purchaseIn, .saleReturnIn, .countGain, .opening: return .inbound
        case .saleOut, .purchaseReturnOut, .countLoss:         return .outbound
        case .manualAdjust:                                    return .costOnly
        }
    }

    /// True for the two kinds N-4 costs from an origin document rather than from the average.
    public var isReturn: Bool { self == .saleReturnIn || self == .purchaseReturnOut }

    /// True for the outbound kinds costed at the average in force before the issue — the ones
    /// P5 ("an issue does not move the unit cost") applies to.
    ///
    /// `purchaseReturnOut` is deliberately NOT one of them: N-4 costs it at the ORIGINAL purchase
    /// unit cost, which in general differs from the current average, so removing it necessarily
    /// moves the average of what remains. P5 cannot hold for it and does not claim to.
    public var isAveragePricedOutbound: Bool { self == .saleOut || self == .countLoss }
}

/// What a movement does to quantity.
public enum InventoryMovementDirection: Sendable, Equatable {
    case inbound
    case outbound
    /// Quantity is untouched; only the cost balance moves. `manualAdjust` only.
    case costOnly

    /// The direction a reversal of this one has.
    public var reversed: InventoryMovementDirection {
        switch self {
        case .inbound:  return .outbound
        case .outbound: return .inbound
        case .costOnly: return .costOnly   // the INVERSION is on the signed cost delta
        }
    }
}

// MARK: - Rows

/// One row of `inventory_movements`, as stored. Immutable by contract: a posted movement is never
/// edited or deleted — it is reversed by appending another row that points at it.
public struct InventoryPostedMovement: Equatable, Sendable, Identifiable {
    public let id: String
    public let productID: String
    public let type: InventoryMovementType
    public let occurredOn: String
    /// Assigned by the engine in posting order (D-4). Callers cannot supply it: the moving average
    /// is order-dependent, so letting a caller choose the order would let it choose the answer.
    public let seq: Int64
    /// Always ≥ 0. Exactly 0 for `manualAdjust`.
    public let quantityMilli: Int64
    /// The tax-exclusive unit cost this row was priced at, when the row HAS one of its own.
    /// `nil` on average-priced issues, whose price is the balance's, not theirs.
    public let unitCostMicro: Int64?
    /// The cost this row moved. Signed ONLY for `manualAdjust`; a magnitude for everything else,
    /// with the direction supplied by ``effectiveDirection``.
    public let totalCostMinor: Int64?
    public let currency: String
    public let sourceType: String?
    public let sourceID: String?
    /// The movement this row reverses, if it is a reversal.
    public let reversesID: String?
    public let note: String?

    public init(id: String, productID: String, type: InventoryMovementType, occurredOn: String,
                seq: Int64, quantityMilli: Int64, unitCostMicro: Int64?, totalCostMinor: Int64?,
                currency: String, sourceType: String? = nil, sourceID: String? = nil,
                reversesID: String? = nil, note: String? = nil) {
        self.id = id
        self.productID = productID
        self.type = type
        self.occurredOn = occurredOn
        self.seq = seq
        self.quantityMilli = quantityMilli
        self.unitCostMicro = unitCostMicro
        self.totalCostMinor = totalCostMinor
        self.currency = currency
        self.sourceType = sourceType
        self.sourceID = sourceID
        self.reversesID = reversesID
        self.note = note
    }

    /// The direction this row actually has: its type's, inverted when it is a reversal (F2).
    ///
    /// The alternative — writing the mirror-image TYPE for a reversal — was rejected because it
    /// destroys audit information: returning goods to a supplier and undoing a mis-keyed purchase
    /// are different events, and `purchase_return_out` would have named them the same thing. Same
    /// type + `reversesID` keeps them distinguishable, and it is one rule rather than a table of
    /// eight mirror pairs.
    ///
    /// Note this is a READER's fact. The balance never folds a reversal row: a reversed pair is
    /// excluded wholesale and the balance is rebuilt by replay (see `InventoryPosting.replay`).
    public var effectiveDirection: InventoryMovementDirection {
        reversesID == nil ? type.direction : type.direction.reversed
    }

    public var isReversal: Bool { reversesID != nil }

    /// The order key. `(occurredOn, seq)` is a total order per product, and the v24 unique index
    /// on `(product_id, occurred_on, seq)` is what makes it one.
    public var orderKey: String { "\(occurredOn)#\(String(format: "%019d", seq))" }
}

/// The three things `inventory_exceptions` records — every one of them something N0 requires to be
/// visible after the fact rather than merely refused at the time.
public enum InventoryExceptionKind: String, CaseIterable, Sendable {
    /// N-4: a return whose origin document could not be found. The row was posted at the current
    /// average, and D-11's quantity ceiling could not be applied because there was nothing to
    /// compare against — so it is flagged instead of silently accepted.
    case returnOriginNotFound = "return_origin_not_found"
    /// F1 案丙: a cost-only correction. Human intervention, therefore an audit trail.
    case manualAdjust = "manual_adjust"
    /// N-10: an opening balance is an estimate carried in at switch-over; its provenance has to
    /// stay visible.
    case openingSeeded = "opening_seeded"
}

/// One row of `inventory_exceptions`.
public struct InventoryException: Equatable, Sendable, Identifiable {
    public let id: String
    public let productID: String?
    public let movementID: String?
    public let kind: InventoryExceptionKind
    public let detail: String?

    public init(id: String, productID: String?, movementID: String?,
                kind: InventoryExceptionKind, detail: String?) {
        self.id = id
        self.productID = productID
        self.movementID = movementID
        self.kind = kind
        self.detail = detail
    }
}

// MARK: - Balance

/// The running balance for ONE product — one row of `inventory_balances`.
///
/// `unitCostMicro` is a STATE, not a function of `(quantityMilli, costBalanceMinor)`. N-1 sets it
/// on receipt and freezes it across average-priced issues, so after any issue the pair no longer
/// reproduces it. That is the whole reason reversal replays rather than subtracting: restoring the
/// quantity and the cost does NOT restore the average.
///
/// Every field is per-product by construction. There is no aggregate over products anywhere in the
/// engine, because quantities of different products are in different units and adding them is
/// meaningless (N-9 / audit G23).
public struct InventoryBalance: Equatable, Sendable {
    public let productID: String
    /// On-hand quantity ×1e3. Never negative (N-5).
    public let quantityMilli: Int64
    /// Cost balance in minor currency units. Never negative. Exactly
    /// `Σ inbound cost − Σ outbound cost flow + Σ manual adjustments` (P2, amended for F1 案丙).
    public let costBalanceMinor: Int64
    /// The average in force for the NEXT issue, ×1e6. Zero whenever the quantity is zero (N-2).
    public let unitCostMicro: Int64
    /// Frozen by the first inbound; a later inbound in a different currency is refused (D-1). No
    /// conversion is ever performed.
    public let currency: String?
    public let lastMovementID: String?
    /// The backdating baseline (N-6): a movement dated before this is refused.
    public let lastOccurredOn: String?
    public let lastSeq: Int64?

    public init(productID: String, quantityMilli: Int64 = 0, costBalanceMinor: Int64 = 0,
                unitCostMicro: Int64 = 0, currency: String? = nil, lastMovementID: String? = nil,
                lastOccurredOn: String? = nil, lastSeq: Int64? = nil) {
        self.productID = productID
        self.quantityMilli = quantityMilli
        self.costBalanceMinor = costBalanceMinor
        self.unitCostMicro = unitCostMicro
        self.currency = currency
        self.lastMovementID = lastMovementID
        self.lastOccurredOn = lastOccurredOn
        self.lastSeq = lastSeq
    }

    /// The state of a product that has never been posted to.
    public static func empty(productID: String) -> InventoryBalance {
        InventoryBalance(productID: productID)
    }

    /// The three numbers P7 restores. Named so a test can say what it compares.
    public var triple: (quantityMilli: Int64, costBalanceMinor: Int64, unitCostMicro: Int64) {
        (quantityMilli, costBalanceMinor, unitCostMicro)
    }
}

// MARK: - Refusals

/// Every way the engine refuses. Closed, typed, and payload-free except where the number IS the
/// explanation — the same posture ``ProductCatalogError`` records: no path, no `strerror`, and no
/// raw SQLite text for a presentation layer to print by accident.
public enum InventoryPostingError: Error, Equatable, Sendable, CustomStringConvertible {
    /// N-7: an inbound with no tax-exclusive unit cost, or a cost-only adjustment with no amount.
    /// NEVER falls back to a tax-inclusive figure — that is the audited Electron defect this
    /// engine exists to not repeat.
    case netAmountRequired
    /// A negative unit cost. Structural: a cost is a magnitude. Distinct from D-10's legal ZERO.
    case unitCostMustNotBeNegative
    /// A quantity-moving movement with a non-positive quantity.
    case quantityMustBePositive
    /// F1 案丙: `manualAdjust` carried a quantity. Cost-only means cost-only.
    case manualAdjustMustNotMoveQuantity
    /// F1 案丙 guard ②: nothing on hand to re-cost. Allowing it would produce `qty == 0` with
    /// `cost != 0`, which N-2 forbids.
    case manualAdjustRequiresStock
    /// F1 案丙 guard ①: the adjustment would drive the cost balance below zero — N-5's dual on the
    /// cost side.
    case costBalanceWouldGoNegative
    /// N-5: an issue larger than what is on hand. No silent negative stock, no estimate.
    case insufficientStock
    /// N-6: dated before the last posted movement. The first version refuses rather than recomputes.
    case backdatedNotSupported
    /// D-1: a different currency from the one this product's stock is held in. No conversion.
    case currencyMismatch
    /// D-5: an opening balance on a product that already has live movements.
    case openingMustBeFirst
    /// D-11: this return, plus everything already returned against the same origin, exceeds what
    /// the origin document carried.
    case returnExceedsOrigin
    /// F2 案(a): only the product's last live movement may be reversed. Earlier mistakes are
    /// corrected by posting FORWARD (a count, a return, a cost adjustment), never by rewriting.
    case onlyTheLastMovementCanBeReversed
    /// The target has already been reversed. The v24 partial unique index on `reverses_id` says
    /// the same thing; this says it before the write, with a name.
    case movementAlreadyReversed
    case reversalTargetNotFound
    /// No such product. The v24 foreign key refuses the row; this is that refusal, named.
    case productNotFound
    /// N1 §2.4: a product of the scaled integers left Int64. REFUSED, never wrapped.
    case arithmeticOverflow
    /// The stored rows do not fold into a legal balance — e.g. an issue that empties the stock
    /// while carrying a cost flow different from the whole remaining balance. Fails closed rather
    /// than publishing a balance that violates N-2.
    case ledgerInconsistent
    /// Any other refusal from the database.
    case storageFailure

    public var description: String {
        switch self {
        case .netAmountRequired:                return "netAmountRequired"
        case .unitCostMustNotBeNegative:        return "unitCostMustNotBeNegative"
        case .quantityMustBePositive:           return "quantityMustBePositive"
        case .manualAdjustMustNotMoveQuantity:  return "manualAdjustMustNotMoveQuantity"
        case .manualAdjustRequiresStock:        return "manualAdjustRequiresStock"
        case .costBalanceWouldGoNegative:       return "costBalanceWouldGoNegative"
        case .insufficientStock:                return "insufficientStock"
        case .backdatedNotSupported:            return "backdatedNotSupported"
        case .currencyMismatch:                 return "currencyMismatch"
        case .openingMustBeFirst:               return "openingMustBeFirst"
        case .returnExceedsOrigin:              return "returnExceedsOrigin"
        case .onlyTheLastMovementCanBeReversed: return "onlyTheLastMovementCanBeReversed"
        case .movementAlreadyReversed:          return "movementAlreadyReversed"
        case .reversalTargetNotFound:           return "reversalTargetNotFound"
        case .productNotFound:                  return "productNotFound"
        case .arithmeticOverflow:               return "arithmeticOverflow"
        case .ledgerInconsistent:               return "ledgerInconsistent"
        case .storageFailure:                   return "storageFailure"
        }
    }
}

// MARK: - Requests

/// What a caller asks the engine to post. Deliberately NOT a `InventoryPostedMovement`: the id,
/// the `seq` and the cost basis are the engine's to decide (D-4, N-1, N-4).
public struct InventoryPostingRequest: Equatable, Sendable {
    public let productID: String
    public let type: InventoryMovementType
    public let occurredOn: String
    /// ×1e3. Must be 0 for `manualAdjust`, positive otherwise.
    public let quantityMilli: Int64
    /// ×1e6, tax-exclusive. Required on `purchaseIn` / `countGain` / `opening` (N-7); `0` is a
    /// legal value for a free sample (D-10) and is NOT the same as absent. Ignored on issues and
    /// on returns, which take their basis from the average or the origin.
    public let unitCostMicro: Int64?
    /// Signed, minor units. `manualAdjust` only — the whole point of that kind.
    public let costDeltaMinor: Int64?
    public let currency: String
    public let sourceType: String?
    public let sourceID: String?
    public let note: String?

    public init(productID: String, type: InventoryMovementType, occurredOn: String,
                quantityMilli: Int64, unitCostMicro: Int64? = nil, costDeltaMinor: Int64? = nil,
                currency: String, sourceType: String? = nil, sourceID: String? = nil,
                note: String? = nil) {
        self.productID = productID
        self.type = type
        self.occurredOn = occurredOn
        self.quantityMilli = quantityMilli
        self.unitCostMicro = unitCostMicro
        self.costDeltaMinor = costDeltaMinor
        self.currency = currency
        self.sourceType = sourceType
        self.sourceID = sourceID
        self.note = note
    }
}

/// What the engine found out about a return's origin document — the input N-4 and D-11 need, and
/// the only thing the pure planner cannot work out for itself.
public struct InventoryOriginFacts: Equatable, Sendable {
    /// The quantity the origin document carried, ×1e3.
    public let quantityMilli: Int64
    /// The unit cost the origin was priced at, ×1e6.
    public let unitCostMicro: Int64
    /// How much has ALREADY been returned against this origin, ×1e3. Cumulative, because a
    /// per-return ceiling would be no ceiling at all: two returns of 6 against an order of 10 each
    /// pass on their own (F3).
    public let alreadyReturnedMilli: Int64

    public init(quantityMilli: Int64, unitCostMicro: Int64, alreadyReturnedMilli: Int64) {
        self.quantityMilli = quantityMilli
        self.unitCostMicro = unitCostMicro
        self.alreadyReturnedMilli = alreadyReturnedMilli
    }
}

/// The facts the pure planner needs but cannot read for itself.
public struct InventoryPostingContext: Equatable, Sendable {
    /// Whether the product already has any LIVE movement — reversed pairs excluded. D-5 turns on
    /// this: an opening that was itself reversed must not block a corrected one.
    public let hasLiveMovements: Bool
    /// The origin document of a return, when one was found. `nil` means "not found", which N-4
    /// costs at the current average and flags, and which leaves D-11 with nothing to check.
    public let origin: InventoryOriginFacts?
    /// The `seq` the engine assigns (D-4).
    public let seq: Int64
    /// The id the engine mints.
    public let movementID: String

    public init(hasLiveMovements: Bool, origin: InventoryOriginFacts?, seq: Int64, movementID: String) {
        self.hasLiveMovements = hasLiveMovements
        self.origin = origin
        self.seq = seq
        self.movementID = movementID
    }
}

/// What the planner decided: the row to write, the balance that follows, and the exception the
/// ruling requires alongside it.
public struct InventoryPostingPlan: Equatable, Sendable {
    public let movement: InventoryPostedMovement
    public let balance: InventoryBalance
    public let exception: InventoryExceptionKind?

    public init(movement: InventoryPostedMovement, balance: InventoryBalance,
                exception: InventoryExceptionKind?) {
        self.movement = movement
        self.balance = balance
        self.exception = exception
    }
}
