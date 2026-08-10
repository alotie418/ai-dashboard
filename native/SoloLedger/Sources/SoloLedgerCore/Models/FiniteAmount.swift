import Foundation

/// A `Double` that is a real number — never a NaN, never an infinity.
///
/// The same shape as ``FiniteRate``, and deliberately NOT the same type. That one carries
/// RATE semantics and lives under `Reports/`, which is a protected area with its own closed
/// public surface; borrowing it here would drag the money path into that closed set and give
/// a rate type a second, unrelated meaning. Two small types cost less than either.
///
/// Its job is to make "we checked" a fact about the value rather than a claim about the code
/// path. `Transaction.validationErrors()` shows why that matters: it has carried an
/// `!amount.isFinite` check since the first prototype, and that check has never once run in
/// production, because `normalized()` is called first and has already replaced the value.
/// A check that lives beside the value cannot be bypassed by call order.
struct FiniteAmount: Equatable, Sendable {
    let value: Double

    /// Fails for NaN and for ±infinity. This is the only way a runtime value gets in.
    init?(_ value: Double) {
        guard value.isFinite else { return nil }
        self.value = value
    }
}

extension FiniteAmount: ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral {
    // Unreachable in practice — Swift has no non-finite numeric literal — but stated rather
    // than assumed, for the same reason ``FiniteRate`` states it: "cannot happen" and "is not
    // checked" read the same in a diff.
    init(integerLiteral value: Int) { self.value = Double(value) }
    init(floatLiteral value: Double) {
        precondition(value.isFinite, "FiniteAmount literal must be finite")
        self.value = value
    }
}

/// The five money columns a ``Transaction`` carries.
///
/// Public because the refusal has to name the field that caused it: the App layer maps each
/// case to its own sentence, the way `ProductCatalogError` does. A shared "some amount is bad"
/// message would leave the user hunting across five fields, four of which the transaction list
/// does not even display.
public enum TransactionAmountField: String, CaseIterable, Sendable {
    case amount
    case amountNet
    case taxAmount
    case taxRate
    case paidAmount
}

public extension Transaction {

    /// The money fields holding a value this ledger cannot record, in a stable order.
    ///
    /// Reads the values AS GIVEN. Callers must ask before ``Transaction/normalized()`` runs —
    /// after it there is nothing left to find, because it replaces every non-finite number
    /// with `0` (and `amountNet` with `nil`). That replacement is the defect this gate exists
    /// to stop: in a ledger, silently recording a different number is worse than refusing.
    ///
    /// `amountNet` is absent-able, and absence is not a fault: `nil` means "not recorded" and
    /// travels to the engines as SQL NULL, which is a value they read (`amount_net || amount`).
    /// Only a PRESENT non-finite value is reported.
    func nonFiniteAmountFields() -> [TransactionAmountField] {
        var found: [TransactionAmountField] = []
        for field in TransactionAmountField.allCases {
            switch field {
            case .amount:     if FiniteAmount(amount) == nil { found.append(field) }
            case .amountNet:  if let n = amountNet, FiniteAmount(n) == nil { found.append(field) }
            case .taxAmount:  if FiniteAmount(taxAmount) == nil { found.append(field) }
            case .taxRate:    if FiniteAmount(taxRate) == nil { found.append(field) }
            case .paidAmount: if FiniteAmount(paidAmount) == nil { found.append(field) }
            }
        }
        return found
    }
}
