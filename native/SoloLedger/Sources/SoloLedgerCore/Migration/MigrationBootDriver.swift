import Foundation

// MARK: - 2B-3 C12b-1: pure, synchronous store-open sequencer over C12a's boot outcomes
//
// The driver is a NAMESPACE of pure functions. It NEVER schedules threads, NEVER retries, and
// NEVER touches the coordinator's internals. The division of labor with the App layer (C12b-2):
//
//  - the App runs the HEAVY chain (`bootResolve` / `resolveSelectedImport`) OFF the main actor
//    and marshals back the value-typed `BootOutcome`;
//  - `classifyOutcome` turns that outcome into either an authorization-to-attempt or a
//    terminal-of-this-round UI state (no store construction);
//  - `attemptOpen` runs the confirm→open step; it is `@MainActor` so the COMPILER guarantees
//    confirm and the LedgerStore construction happen in one synchronous main-actor step with
//    no `await` / `yield` / Task hop between them. `SQLiteDatabase` is not thread-safe, so this
//    entry constructs the store ON the main actor. `@MainActor` governs only THIS call; it does
//    NOT guarantee that the RETURNED store is thereafter used only on the main actor — that
//    ongoing use-isolation is C12b-2's `@MainActor` AppModel's responsibility.
//
// Every dispatch below is an exhaustive `switch` with NO `default`, so a future added case in
// `StoreOpenAuthorization`, `MigrationBlock.Class`, `BootOutcome` or `OpenPrecheck` fails the
// build here rather than silently falling through.

public enum MigrationBootDriver {

    /// The single-attempt result of the confirm→open step. Carries a live `LedgerStore`, so it
    /// is deliberately NOT `Equatable`.
    public enum Attempt {
        /// confirm returned `.proceed` and the store opened. Carries the non-blocking residue.
        case opened(LedgerStore, MigrationResidual?)
        /// A typed UI state to surface. NO store was constructed.
        case ui(MigrationUIState)
        /// confirm returned `.reResolve`; the caller re-runs ONE more background `bootResolve`.
        case needsReResolve
    }

    /// A boot outcome split into "an authorization to attempt" vs "a UI state to surface".
    public enum OutcomeStep: Equatable {
        case openStore(StoreOpenAuthorization, MigrationResidual?)
        case ui(MigrationUIState)
    }

    /// Which open mode an authorization permits. `createFreshExpectedAbsent` is the ONLY
    /// authorization that may create the database; both `openExisting*` authorizations must
    /// refuse a vanished path. Exhaustive; no default.
    public static func openIntent(for authorization: StoreOpenAuthorization) -> StoreOpenIntent {
        switch authorization {
        case .createFreshExpectedAbsent: return .createIfMissing
        case .openExistingPlain:         return .existingOnly
        case .openExistingCompleted:     return .existingOnly
        }
    }

    /// A blocking migration block → the retriable / terminal UI state, by its classification.
    /// Exhaustive; no default.
    public static func classify(_ block: MigrationBlock) -> MigrationUIState {
        switch block.classification {
        case .retriable: return .retriable(block)
        case .terminal:  return .terminal(block)
        }
    }

    /// A boot outcome → either an authorization to attempt, or a UI state to surface. NO store
    /// is constructed here, so acknowledgement / selection / blocked outcomes can never reach
    /// `attemptOpen`. Exhaustive; no default.
    public static func classifyOutcome(_ outcome: BootOutcome) -> OutcomeStep {
        switch outcome {
        case .openStore(let authorization, let residual):
            return .openStore(authorization, residual)
        case .requiresAcknowledgement(let request, let unresolved):
            return .ui(.awaitingAcknowledgement(request, unresolved))
        case .requiresImportSelection(let candidates):
            return .ui(.awaitingImportSelection(candidates))
        case .blocked(let block):
            return .ui(classify(block))
        }
    }

    /// Confirm `authorization` from disk and, ONLY on `.proceed`, open the store. Being
    /// `@MainActor`, confirm and the `openStore` call run in one synchronous main-actor step —
    /// no suspension between them, and the LedgerStore this entry constructs is created on the
    /// main actor. (`@MainActor` governs only THIS call; ensuring the returned store is
    /// thereafter used only on the main actor is C12b-2's `@MainActor` AppModel's job.)
    /// `openStore` never receives an intent for a blocked / reResolve confirm, so no store is
    /// fabricated on a failed check. A store-open failure maps to a typed
    /// `retriable(.storeOpenFailed)`; the underlying `Error`'s text is NEVER copied into params.
    @MainActor
    public static func attemptOpen(authorization: StoreOpenAuthorization,
                                   residual: MigrationResidual?,
                                   confirm: (StoreOpenAuthorization) -> OpenPrecheck,
                                   openStore: (StoreOpenIntent) throws -> LedgerStore) -> Attempt {
        switch confirm(authorization) {
        case .proceed:
            do {
                let store = try openStore(openIntent(for: authorization))
                return .opened(store, residual)
            } catch {
                return .ui(.retriable(MigrationBlock(code: .storeOpenFailed,
                                                     classification: .retriable,
                                                     params: ["op": "storeOpen"])))
            }
        case .blocked(let block):
            return .ui(classify(block))
        case .reResolve:
            return .needsReResolve
        }
    }
}
