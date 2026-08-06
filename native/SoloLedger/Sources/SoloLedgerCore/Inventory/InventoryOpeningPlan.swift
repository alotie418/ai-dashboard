import Foundation

/// The opening-stock wizard's two halves: a READ-ONLY preflight that reports which products can
/// still take an opening balance, and a runner that posts the ones the user filled in.
///
/// ## Why the preflight is a separate, write-free stage
///
/// Setting an opening balance is not reversible in the sense that matters here: D-5 makes an
/// opening the product's FIRST live movement, so once any movement exists that product can never
/// take one again. The plan is the screen that decision is made on, and it decides nothing and
/// writes nothing — `InventoryOpeningTests` hashes the database file and its `-wal` either side of
/// a full preflight and requires both to be byte-identical, so "read-only" is measured rather than
/// asserted in a comment.
///
/// It also has to be ONE view of the ledger. Eligibility is `products` joined against every
/// product's live movements — one statement plus N — and those N+1 reads must describe one
/// database or the plan can contradict itself. Hence `readSnapshot`, and hence this file being in
/// Core: that entry point is internal to the module on purpose.
///
/// ## Why there is no all-or-nothing transaction
///
/// Each product's opening is posted on its own, through the engine's own `postInventoryMovement`,
/// which already wraps itself in one transaction. That is not a compromise forced by the private
/// write primitives — it is the only atomicity that means anything here. The engine has no state
/// that spans products: every statement in `InventoryLedger` filters on `product_id` and there is
/// deliberately no query in it that could aggregate across products. So a batch of N openings is N
/// independent facts, and a refusal on one of them leaves the others exactly as correct as they
/// were. The legacy-conversion runner is all-or-nothing because THERE the rows and their mappings
/// are one invariant; here there is no such invariant to protect, and pretending otherwise would
/// buy nothing while requiring the engine to grow a batch entry point.
///
/// What follows from that is a reporting obligation, not a rollback: the outcome names every line
/// that was refused and why, and the copy says "some were not recorded" rather than claiming the
/// batch was undone.
///
/// ## What it must never do
///
/// Never repair. A line whose quantity or amount cannot be read is not this file's to guess at —
/// it never becomes an entry. Never invent a cost: the amount the user typed IS the cost basis,
/// and the unit cost is derived from it by the one truncating division documented below.

// MARK: - The plan

/// One product that can still be given an opening balance.
public struct InventoryOpeningCandidate: Equatable, Sendable, Identifiable {
    public let productID: String
    public let name: String
    /// The stored unit key, verbatim. Carried so a caller can label the quantity without going
    /// back to the catalogue; not validated here, for the same reason `Product.unit` is not.
    public let unit: String?

    public var id: String { productID }

    public init(productID: String, name: String, unit: String?) {
        self.productID = productID
        self.name = name
        self.unit = unit
    }
}

/// Why the wizard has nothing to offer.
public enum InventoryOpeningBlocker: Equatable, Sendable {
    /// The catalogue is empty. An opening balance is always recorded against one product.
    case noProduct
    /// Every product already has live movements, so D-5 refuses an opening for all of them.
    case noneEligible
}

public struct InventoryOpeningPlan: Equatable, Sendable {
    public let candidates: [InventoryOpeningCandidate]
    /// How many products were left out because they already have live movements. Reported so the
    /// screen can be honest about a partial list rather than looking like the whole catalogue.
    public let alreadyMovingCount: Int

    public init(candidates: [InventoryOpeningCandidate], alreadyMovingCount: Int) {
        self.candidates = candidates
        self.alreadyMovingCount = alreadyMovingCount
    }
}

/// Either the wizard is refused outright, or there is a plan. A caller cannot reach the plan
/// without having handled the refusal.
public enum InventoryOpeningPreflight: Equatable, Sendable {
    case blocked(InventoryOpeningBlocker)
    case plan(InventoryOpeningPlan)
}

// MARK: - The request and what came of it

/// One line the user filled in. Quantity and amount are the two things a physical stock count
/// produces; the unit cost is derived, never typed.
public struct InventoryOpeningEntry: Equatable, Sendable {
    public let productID: String
    /// ×1e3, must be positive — a line with no quantity is not an opening, it is a line the user
    /// left out, and the caller drops it rather than sending a zero.
    public let quantityMilli: Int64
    /// Tax-exclusive, in minor units. Zero is legal (D-10); absent is not representable here,
    /// which is deliberate — "not filled in" is a state the caller resolves before this type.
    public let amountMinor: Int64

    public init(productID: String, quantityMilli: Int64, amountMinor: Int64) {
        self.productID = productID
        self.quantityMilli = quantityMilli
        self.amountMinor = amountMinor
    }
}

public struct InventoryOpeningRequest: Equatable, Sendable {
    /// The switch-over date, shared by every line. N-6 measures every later movement against it.
    public let occurredOn: String
    /// The currency every opening freezes its product's stock in (D-1). One value for the batch:
    /// an eligible product has no balance to disagree with.
    public let currency: String
    public let entries: [InventoryOpeningEntry]

    public init(occurredOn: String, currency: String, entries: [InventoryOpeningEntry]) {
        self.occurredOn = occurredOn
        self.currency = currency
        self.entries = entries
    }
}

/// What one line did. `refusal == nil` means the opening is in the ledger.
public struct InventoryOpeningResult: Equatable, Sendable {
    public let productID: String
    public let refusal: InventoryPostingError?

    public init(productID: String, refusal: InventoryPostingError?) {
        self.productID = productID
        self.refusal = refusal
    }
}

public struct InventoryOpeningOutcome: Equatable, Sendable {
    /// One per entry, in the order they were sent.
    public let results: [InventoryOpeningResult]

    public init(results: [InventoryOpeningResult]) {
        self.results = results
    }

    public var recordedCount: Int { results.filter { $0.refusal == nil }.count }
    public var refusedCount: Int { results.filter { $0.refusal != nil }.count }
    public var refusals: [InventoryOpeningResult] { results.filter { $0.refusal != nil } }
}

// MARK: - The derivation

public enum InventoryOpening {

    /// The same 1e9 bridge the engine uses between the three integer scales.
    ///
    /// Spelled out here rather than borrowed so that `InventoryPosting` stays a name no file
    /// outside the engine's own three mentions — the closed set in `InventoryLedgerTests` is what
    /// makes "nothing calls the state machine" a checkable claim, and it would be a poor trade to
    /// weaken it to save one constant. `InventoryOpeningTests` asserts the two are equal.
    static let scaleBridge: Int64 = 1_000_000_000

    /// The unit cost a typed quantity and amount imply: `amountMinor × 1e9 / quantityMilli`,
    /// truncated toward zero.
    ///
    /// Truncation is D-3's direction, and it has a consequence the screen has to say out loud:
    /// the ledger stores this unit cost and recomputes the amount from it, so when the division
    /// does not come out evenly the recorded amount is LOWER than the one typed, by less than one
    /// minor unit. That residue is not parked anywhere — unlike the engine's own issue path, where
    /// D-3 leaves it in the cost balance, here there is no balance yet for it to live in. Hence
    /// `inventory.opening.roundingNote`, which is the only honest way to ship this.
    ///
    /// Refuses rather than wrapping on overflow, and refuses a non-positive quantity: a line the
    /// user left blank is dropped by the caller, so a zero arriving here is a bug, not a blank.
    public static func unitCostMicro(amountMinor: Int64, quantityMilli: Int64) throws -> Int64 {
        guard quantityMilli > 0 else { throw InventoryPostingError.quantityMustBePositive }
        guard amountMinor >= 0 else { throw InventoryPostingError.unitCostMustNotBeNegative }
        let (numerator, overflow) = amountMinor.multipliedReportingOverflow(by: scaleBridge)
        guard !overflow else { throw InventoryPostingError.arithmeticOverflow }
        return numerator / quantityMilli          // both operands ≥ 0 → toward zero == floor
    }
}

// MARK: - Reads and writes

public extension LedgerStore {

    /// Which products can still be given an opening balance, or why none can.
    ///
    /// One consistent view of the ledger for the whole scan — see the type's note.
    func inventoryOpeningPreflight() throws -> InventoryOpeningPreflight {
        try db.readSnapshot { try inventoryOpeningPreflightBody() }
    }

    /// Post the openings the user filled in, one product at a time.
    ///
    /// Total: every entry produces a result. A refusal is the engine's own, named, and leaves that
    /// product byte-identical — `postInventoryMovement` runs its guards before `BEGIN` and rolls
    /// back on anything inside it. The commonest refusal here is `openingMustBeFirst`, which is
    /// exactly the case where another writer got to that product between the preflight and the
    /// confirmation; it needs no staleness gate of its own because D-5 already is one.
    @discardableResult
    func runInventoryOpening(_ request: InventoryOpeningRequest) -> InventoryOpeningOutcome {
        var results: [InventoryOpeningResult] = []
        for entry in request.entries {
            do {
                let unitCostMicro = try InventoryOpening.unitCostMicro(
                    amountMinor: entry.amountMinor, quantityMilli: entry.quantityMilli)
                _ = try postInventoryMovement(InventoryPostingRequest(
                    productID: entry.productID,
                    type: .opening,
                    occurredOn: request.occurredOn,
                    quantityMilli: entry.quantityMilli,
                    unitCostMicro: unitCostMicro,
                    currency: request.currency))
                results.append(InventoryOpeningResult(productID: entry.productID, refusal: nil))
            } catch let error as InventoryPostingError {
                results.append(InventoryOpeningResult(productID: entry.productID, refusal: error))
            } catch {
                // Nothing else should reach here — the engine maps its whole storage surface — but
                // a total function is worth more than a crash, and `storageFailure` is the sentence
                // that is true of anything unnamed.
                results.append(InventoryOpeningResult(productID: entry.productID,
                                                      refusal: .storageFailure))
            }
        }
        return InventoryOpeningOutcome(results: results)
    }
}

private extension LedgerStore {

    /// Split out so the snapshot is taken by the public entry point and by nobody else. A caller
    /// that opened no transaction would get the torn view the snapshot exists to prevent.
    func inventoryOpeningPreflightBody() throws -> InventoryOpeningPreflight {
        let catalogue = try productCatalog()
        guard !catalogue.products.isEmpty else { return .blocked(.noProduct) }

        var candidates: [InventoryOpeningCandidate] = []
        var alreadyMoving = 0
        for product in catalogue.products {
            // D-5's own condition, asked the engine's way. A product whose movements were all
            // reversed reads as empty here — a reversed pair does not exist — so a mis-keyed
            // opening that was undone leaves that product eligible again.
            if try liveInventoryMovements(productID: product.id).isEmpty {
                candidates.append(InventoryOpeningCandidate(productID: product.id,
                                                            name: product.name,
                                                            unit: product.unit))
            } else {
                alreadyMoving += 1
            }
        }
        guard !candidates.isEmpty else { return .blocked(.noneEligible) }
        return .plan(InventoryOpeningPlan(candidates: candidates,
                                          alreadyMovingCount: alreadyMoving))
    }
}
