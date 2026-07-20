import Foundation
import SoloLedgerCore

// MARK: - 2B-3 C12b-2: the AppModel ↔ C12 coordinator seam
//
// Splits a boot into two phases with EXPLICIT thread boundaries:
//  - Phase A (`resolveOutcome`): the heavy coordinator chain (integrity check, whole-DB copy,
//    hashing). It MUST run OFF the main actor and returns ONLY a value-typed `BootOutcome` —
//    never a `LedgerStore`. The production runner dispatches it to a detached background task
//    (not merely an `async` declaration), so the off-main boundary is real and testable.
//  - Phase B (`attempt`): `@MainActor`, synchronous. Delegates to `MigrationBootDriver.attemptOpen`
//    so confirm→open stay adjacent with no suspension, and the LedgerStore is created on the
//    main actor. `SQLiteDatabase` is not thread-safe, so the store is never built off-main.
//
// Everything here is INTERNAL — no public App API is added for testing.

/// One boot request variant. `Equatable` so tests can assert the exact intent handed to Phase A.
enum BootIntent: Equatable {
    case boot
    case acknowledgement(Acknowledgement)
    case selection(String)
}

protocol BootChainRunner {
    /// Phase A — called from the main actor (`@MainActor`), it MUST itself push the heavy work
    /// OFF the main actor (the production impl uses a detached task, not merely this `async`
    /// declaration). Returns a value type, never a `LedgerStore`.
    @MainActor func resolveOutcome(_ intent: BootIntent) async -> BootOutcome
    /// Phase B — runs ON the main actor; confirm→open stay adjacent (see `MigrationBootDriver`).
    @MainActor func attempt(_ authorization: StoreOpenAuthorization,
                            residual: MigrationResidual?) -> MigrationBootDriver.Attempt
}

/// Production runner: wraps the coordinator and the real thread boundaries. Phase A is
/// dispatched to a detached (background) task so the heavy chain never blocks the main actor;
/// Phase B runs `MigrationBootDriver.attemptOpen`, which is `@MainActor`.
struct ProductionBootChainRunner: BootChainRunner {
    /// The synchronous coordinator work for Phase A. `@Sendable` so it can cross to the
    /// detached task; it returns a value type and constructs no `LedgerStore`.
    let resolveWork: @Sendable (BootIntent) -> BootOutcome
    /// Phase-B confirm — invoked only from `attempt` (main actor).
    let confirm: (StoreOpenAuthorization) -> OpenPrecheck
    /// Phase-B store construction — invoked only from `attempt` (main actor). Receives the
    /// confirmed plan (createFresh vs existing+evidence) so the existing path can take the C12x
    /// hardened open.
    let openStore: (ConfirmedOpenPlan) throws -> LedgerStore

    /// Called on the main actor; the heavy `resolveWork` is explicitly dispatched to a DETACHED
    /// background task so it never runs on the main actor. Removing this detach is what the
    /// `testProductionPhaseARunsOffTheMainActor` guard catches.
    @MainActor func resolveOutcome(_ intent: BootIntent) async -> BootOutcome {
        let work = resolveWork
        return await Task.detached(priority: .userInitiated) { work(intent) }.value
    }

    @MainActor func attempt(_ authorization: StoreOpenAuthorization,
                            residual: MigrationResidual?) -> MigrationBootDriver.Attempt {
        MigrationBootDriver.attemptOpen(authorization: authorization, residual: residual,
                                        confirm: confirm, openStore: openStore)
    }
}
