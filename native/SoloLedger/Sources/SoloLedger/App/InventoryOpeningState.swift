import Foundation
import SoloLedgerCore

/// The opening-stock wizard's whole state.
///
/// `idle` is also "the sheet is not open", so presentation is a second `@Published Bool` rather
/// than a case here — the same shape the legacy-conversion wizard has, for the same reason: a
/// system dismissal writes into the presentation binding without passing through the model, and
/// keeping the two separate is what lets `dismiss…()` be the one path that clears both.
///
/// **There is no `running` case**, and that is a decision rather than an omission. The legacy
/// wizard has one because its conversion really does run off the main actor and the user really
/// does wait. Here the work is N small inserts through `postInventoryMovement`, synchronous, on
/// the connection the model already holds; a frame for it is never rendered, so a state for it
/// would be copy describing something nobody can see. If a ledger ever appears where this is slow
/// enough to draw, the case earns its place then — and so does the copy for it.
enum InventoryOpeningState: Equatable {
    case idle
    /// Nothing to offer, and which of the two reasons it is.
    case blocked(InventoryOpeningBlocker)
    /// The one screen the decision is made on.
    case editing(InventoryOpeningDraft)
    /// Every line the user filled in is now its product's first movement.
    case done
    /// Some lines were refused. Each product's opening is its own transaction, so the rest ARE in
    /// the ledger — this case exists because saying otherwise would be false.
    case partial([InventoryOpeningRefusal])

    var isEditing: Bool {
        if case .editing = self { return true }
        return false
    }
}

/// One line the ledger would not take, and the sentence that says why.
///
/// The sentence arrives as a KEY, mapped once by `InventoryPageComposition.key(for:)` — the only
/// place an `InventoryPostingError` becomes copy. Carrying the error itself this far would put a
/// second mapping within reach of a view, and two mappings drift.
struct InventoryOpeningRefusal: Equatable {
    let productName: String
    let messageKey: String

    init(productName: String, messageKey: String) {
        self.productName = productName
        self.messageKey = messageKey
    }
}
