import Foundation

// MARK: - 2B-3 C12b-1: the App-facing boot UI vocabulary (Core value types)
//
// These are PURE value types the App layer binds to. The driver never localizes (issue-code
// copy is an App-layer concern) and never constructs a LedgerStore off the main actor. Every
// associated value is a C12a PUBLIC migration type, so the App can pattern-match all of them.

/// The coarse migration progress step. Only ONE honest value exists today: the C12
/// coordinator's boot chain is a single synchronous call with NO intermediate progress
/// callback, so probe / import / finalize cannot be distinguished. A finer-grained progress
/// hook is a registered C12.x follow-up; adding speculative cases now would misreport a long
/// chain as merely "probing".
public enum MigrationStep: Equatable {
    case resolving
}

/// The eight-state UI vocabulary. Invariants (enforced by the App layer, see C12b-2):
///  - `ready == (store != nil)`;
///  - `.cleanupResidual` ⇒ ready == true ∧ store != nil (store opened; residue is non-blocking);
///  - `.running` / `.awaitingAcknowledgement` / `.awaitingImportSelection` /
///    `.awaitingSourceChoice` / `.retriable` / `.terminal` ⇒ ready == false ∧ store == nil;
///  - `.none` is NEUTRAL: before boot it coexists with ready == false; after a successful
///    open with no residue it coexists with ready == true. `.none` alone never means
///    "authorized to open".
public enum MigrationUIState: Equatable {
    case none
    case running(MigrationStep)
    case awaitingAcknowledgement(AcknowledgementRequest, UnresolvedReport)
    case awaitingImportSelection([RecoverableImport])
    /// N7.1 DORMANT (§1.2): the source-choice waiting state (`store == nil`, `ready == false`,
    /// never publishes a store). Production cannot reach it until N7.2 flips `resolveB1`'s
    /// `.unavailable` branch to emit `.requiresSourceChoice`; until then only tests drive it,
    /// and a guard test pins the production boot path to the old behavior.
    case awaitingSourceChoice
    /// Fail-closed but re-probeable (retriable classification).
    case retriable(MigrationBlock)
    /// Fail-closed and not re-adjudicable by retry alone (terminal classification).
    case terminal(MigrationBlock)
    /// Store opened (ready == true) with non-blocking staging-cleanup residue.
    case cleanupResidual(MigrationResidual)
}
