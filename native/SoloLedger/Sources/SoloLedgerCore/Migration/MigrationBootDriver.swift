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
        case .requiresSourceChoice:
            // N7.1 dormant: a NON-openStore outcome — it can only become a UI state, never an
            // authorization, so the source-choice state can never construct a LedgerStore.
            return .ui(.awaitingSourceChoice)
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
                                   openStore: (ConfirmedOpenPlan) throws -> LedgerStore) -> Attempt {
        switch confirm(authorization) {
        case .proceed(let plan):
            // Exhaustive authorization × plan cross-check. An impossible pairing (a confirm that
            // minted a plan that does not match its authorization) maps to a typed internalError
            // and NEVER opens — belt-and-suspenders over the coordinator minting the plan.
            switch (authorization, plan) {
            case (.createFreshExpectedAbsent, .createFresh),
                 (.openExistingPlain, .existing),
                 (.openExistingCompleted, .existing):
                break   // valid pairing
            case (.createFreshExpectedAbsent, .existing),
                 (.openExistingPlain, .createFresh),
                 (.openExistingCompleted, .createFresh):
                return .ui(.terminal(MigrationBlock(code: .internalError, classification: .terminal,
                                                    params: ["op": "attemptOpen", "reason": "planAuthorizationMismatch"])))
            }
            do {
                let store = try openStore(plan)
                return .opened(store, residual)
            } catch let e as HardenedOpenError {
                return .ui(mapHardenedError(e))
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

    /// Map a C12x hardened-open failure to a typed UI state. Every mapping carries only stable
    /// reason tags (and, for a generic sqlite failure, structured NUMERIC codes) — never
    /// `Error.description`, a sqlite message, a path or `strerror`. Exhaustive; no default.
    ///
    /// Post-open identity findings (symlink / moved / mismatch / vanished) DELIBERATELY never
    /// return `.needsReResolve`: an automatic re-resolve would re-adopt a persistently-swapped
    /// file as `openExistingPlain`, or an absent one as `createFreshExpectedAbsent`. A symlinked
    /// active path is PERMANENT, so it lands terminal (not a retriable transient).
    static func mapHardenedError(_ e: HardenedOpenError) -> MigrationUIState {
        switch e {
        case .identity(let v):
            switch v {
            case .unsupportedSymlinkedActivePath:
                return .terminal(MigrationBlock(code: .activeEntryInvalid, classification: .terminal,
                                                params: ["op": "activeOpen", "reason": v.rawValue]))
            case .moved, .vanished, .parentIdentityMismatch, .fingerprintMismatch, .zeroSizeActiveLeaf:
                return .retriable(MigrationBlock(code: .interference, classification: .retriable,
                                                 params: ["op": "activeOpen", "reason": v.rawValue]))
            }
        case .hasMovedUnavailable:
            return .retriable(MigrationBlock(code: .storeOpenFailed, classification: .retriable,
                                             params: ["op": "activeOpen", "reason": "hasMovedUnavailable"]))
        case .hasMovedMisuse:
            return .terminal(MigrationBlock(code: .internalError, classification: .terminal,
                                            params: ["op": "activeOpen", "reason": "hasMovedMisuse"]))
        case .hasMovedFailed:
            // A HAS_MOVED file-control error (e.g. an IOERR when a WAL DB's file was swapped) —
            // fail-closed, never reResolve. Structured codes stay in the typed error (Core tests).
            return .retriable(MigrationBlock(code: .storeOpenFailed, classification: .retriable,
                                             params: ["op": "activeOpen", "reason": "hasMovedFailed"]))
        case .sqlite:
            // Structured numeric codes stay in the typed error (asserted by Core tests); the UI
            // block carries only a stable reason tag this round (diagnostics export deferred).
            return .retriable(MigrationBlock(code: .storeOpenFailed, classification: .retriable,
                                             params: ["op": "activeOpen", "reason": "sqliteOpen"]))
        case .freshCollision:
            // A squatter occupied a supposed-fresh active path. Fail-closed; DELIBERATELY never
            // reResolve — an automatic re-resolve could re-adopt the squatter as an existing plain
            // store. Retriable so the user may act; a manual retry re-runs the whole chain.
            return .retriable(MigrationBlock(code: .interference, classification: .retriable,
                                             params: ["op": "createFresh", "reason": "freshCollision"]))
        case .reservationFailed(let step, let sysErrno):
            // A reservation step failed — stable tag + numeric errno only (no path/message/strerror).
            return .retriable(MigrationBlock(code: .storeOpenFailed, classification: .retriable,
                                             params: ["op": "createFresh", "reason": "reservationFailed",
                                                      "step": step.rawValue, "errno": String(sysErrno)]))
        }
    }
}
