import Foundation
import OSLog
import SoloLedgerCore

// MARK: - 2a-4: the conversion wizard's state, its outcome value, and the failure→copy map
//
// Three things live here, and they are together because each one exists to keep a machine
// string off the screen:
//
//  * ``LegacyConversionState`` — what the wizard is doing. Every case carries only values a
//    view may render.
//  * ``LegacyConversionOutcome`` — what the BACKGROUND run returns. It is `Sendable`;
//    `LegacyConversionFailure` is not, and it deliberately never crosses the actor boundary.
//  * ``LegacyConversionFailureMap`` — the only place a `LegacyConversionFailure` is turned
//    into something the user sees, and it turns it into a localization KEY.

/// The wizard's whole state. `idle` is also "the sheet is not open".
///
/// There is no `preflighting` case, for the same reason the report page has no `.loading`:
/// `legacyConversionPreflight()` is one synchronous read transaction inside a single
/// `AppModel` turn, so a frame for it is never rendered. `running` DOES exist, because the
/// conversion really does run off the main actor and the user really does wait for it.
enum LegacyConversionState: Equatable {
    /// Nothing asked for. The only state in which the sheet may be dismissed freely.
    case idle
    /// The preflight refused the whole batch. Nothing was read past the two settings.
    case blocked(LegacyConversionBlocker)
    /// The plan the user is being shown, and the one a confirmation will convert. Held by
    /// value: the wizard hands THIS plan to the runner, which compares it — fingerprints and
    /// all — against a plan it recomputes inside its own write transaction.
    case summary(LegacyConversionPlan)
    /// The conversion is running off the main actor. Carries the plan so the completion page
    /// can state how many records were left behind without asking the ledger again.
    case running(LegacyConversionPlan)
    /// Done. Counts and a path — no report object, no identities, no machine text.
    case completed(convertedCount: Int, notConvertedCount: Int, backupPath: String?)
    /// Refused. Carries a localization key, never an `Error`.
    case failed(LegacyConversionFailureCopy)

    /// True while the database is being written. Everything that could touch the ledger —
    /// dismissing the sheet included — is refused for exactly this long.
    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

/// What one background conversion returned, reduced to values the main actor may receive.
///
/// `LegacyConversionFailure` is `Error, Equatable, CustomStringConvertible` and is NOT
/// `Sendable`; its `description` interpolates row identities and SQLite messages. So it is
/// mapped to a key on the background thread and never sent anywhere. That also means the App
/// cannot accidentally render it: it does not have one.
enum LegacyConversionOutcome: Sendable, Equatable {
    case converted(convertedCount: Int, backupPath: String?)
    case failed(LegacyConversionFailureCopy)
}

/// A refusal, as the user sees it.
///
/// Two fields, and no more, because everything else the user needs to do next is already IN
/// the localized sentence: `legacy.convert.failed.ledgerChanged` says to run the preflight
/// again, `…categoryNotFound` says to choose a category again. Re-encoding those as Swift
/// booleans would be a second source of truth that can drift from the copy it duplicates.
struct LegacyConversionFailureCopy: Sendable, Equatable {
    /// A `legacy.convert.failed.*` key. Never a message, never an id.
    let messageKey: String
    /// Whether the run could have left a backup bundle on disk — the condition
    /// `legacy.convert.failed.retryNote` describes.
    let showsRetryNote: Bool

    static let ledgerChanged = LegacyConversionFailureCopy(
        messageKey: "legacy.convert.failed.ledgerChanged", showsRetryNote: false)
    static let internalFailure = LegacyConversionFailureCopy(
        messageKey: "legacy.convert.failed.internal", showsRetryNote: false)
}

/// The single crossing point between the runner's typed failures and the wizard's copy.
enum LegacyConversionFailureMap {

    /// Every case of `LegacyConversionFailure`, mapped to one of the twelve adjudicated keys.
    ///
    /// `showsRetryNote` is not decoration: `legacy.convert.failed.retryNote` promises that a
    /// bundle written before the failure is still on disk and that a retry writes a new one
    /// beside it. That is true only for the failures that can be reached AFTER step 7 of
    /// `runLegacyConversion` — the request-shape checks and the category validation all run
    /// before any bundle exists, and saying otherwise would send the user looking for a
    /// folder that was never created.
    static func copy(for failure: LegacyConversionFailure) -> LegacyConversionFailureCopy {
        switch failure {
        // — before the transaction opens: a malformed request. Adjudicated to the internal
        //   failure, because reaching it means the wizard offered a skip the plan never
        //   allowed, which is this app's bug and not a fact about the user's ledger.
        case .skippedIdentityNotConvertible:
            return .internalFailure
        // — category validation, step 6: on the snapshot, before any bundle is written.
        case .categoryRequired(let direction):
            switch direction {
            case .income:
                return .init(messageKey: "legacy.convert.failed.categoryRequiredIncome",
                             showsRetryNote: false)
            case .expense:
                return .init(messageKey: "legacy.convert.failed.categoryRequiredExpense",
                             showsRetryNote: false)
            }
        case .categoryNotFound:
            return .init(messageKey: "legacy.convert.failed.categoryNotFound",
                         showsRetryNote: false)
        case .categoryWrongType:
            return .init(messageKey: "legacy.convert.failed.categoryWrongType",
                         showsRetryNote: false)
        case .categoryWrongLocale:
            return .init(messageKey: "legacy.convert.failed.categoryWrongLocale",
                         showsRetryNote: false)
        // — the ledger moved under the plan. Reachable at step 4 (before the bundle) and again
        //   per row at step 9 (after it), so the note is shown.
        case .ledgerChanged:
            return .init(messageKey: "legacy.convert.failed.ledgerChanged", showsRetryNote: true)
        case .rowVanished:
            return .init(messageKey: "legacy.convert.failed.rowVanished", showsRetryNote: true)
        case .rowNoLongerConvertible:
            return .init(messageKey: "legacy.convert.failed.rowNoLongerConvertible",
                         showsRetryNote: true)
        // — the backup itself. `backupFailed` means `writeBundle` did not finish, so there is
        //   no bundle to point at; `backupNotValid` means one IS on disk.
        case .backupFailed:
            return .init(messageKey: "legacy.convert.failed.backupFailed", showsRetryNote: false)
        case .backupNotValid:
            return .init(messageKey: "legacy.convert.failed.backupNotValid", showsRetryNote: true)
        // — another writer. The lock can be met anywhere in the run, including after step 7.
        case .busy:
            return .init(messageKey: "legacy.convert.failed.busy", showsRetryNote: true)
        // — a closing assertion. Only reachable at step 10, which is after the bundle.
        case .writeSetMismatch:
            return .init(messageKey: "legacy.convert.failed.internal", showsRetryNote: true)
        }
    }

    /// A hardened-open refusal, mapped by the same rule the boot driver applies to it: an
    /// IDENTITY finding means the file on disk is not the one the authorization described —
    /// which is the same thing, to the user, as the ledger having changed. Everything else is
    /// an internal or I/O condition with nothing actionable in it.
    ///
    /// No bundle can exist for any of these: the store is not even open yet.
    static func copy(forOpen error: HardenedOpenError) -> LegacyConversionFailureCopy {
        switch error {
        case .identity:
            return .ledgerChanged
        case .hasMovedUnavailable, .hasMovedMisuse, .hasMovedFailed, .sqlite,
             .freshCollision, .reservationFailed:
            return .internalFailure
        }
    }
}

/// Where the technical detail goes instead of the UI.
///
/// The same division `ReportDiagnostics` draws: nothing identifying is `.public`, and the
/// error itself is `.private`, so it is redacted in collected logs.
enum LegacyConversionDiagnostics {
    static let logger = Logger(subsystem: "com.alotie418.sololedger", category: "legacy-conversion")

    static func preflightFailed(_ error: Error) {
        logger.error("legacy conversion preflight failed: \(String(describing: error), privacy: .private)")
    }

    static func conversionFailed(_ error: Error) {
        logger.error("legacy conversion failed: \(String(describing: error), privacy: .private)")
    }

    static func openRefused(_ reason: String) {
        logger.error("legacy conversion could not open the ledger: \(reason, privacy: .public)")
    }
}

// MARK: - The background run

extension StoreOpenAuthorization {
    /// True for the two authorizations that can only ever confirm into `.existing`.
    ///
    /// This is what makes "only `.proceed(.existing(evidence))` may run a conversion" a
    /// STRUCTURAL property rather than a check that could be forgotten:
    /// `confirmOpenAuthorization` returns `.proceed(.createFresh)` for exactly one
    /// authorization — `.createFreshExpectedAbsent` — and this refuses it before the
    /// background task is even started. A freshly created ledger has no legacy rows anyway,
    /// so the entry point that would reach it does not render.
    var authorizesExistingLedger: Bool {
        switch self {
        case .openExistingPlain, .openExistingCompleted: return true
        case .createFreshExpectedAbsent: return false
        }
    }
}

/// The conversion, off the main actor, on its own connection.
///
/// ## Why a second connection at all
///
/// `SQLiteDatabase` is not thread-safe, and `AppModel`'s store is `@MainActor`-isolated. A
/// conversion writes a whole-database backup, copies attachments and inserts every row, so
/// running it on the main actor would freeze the window for the duration — and the
/// `legacy.convert.running.*` copy would describe a frame that is never drawn. So the work
/// runs here, on a connection this function opens, uses and closes without it ever crossing
/// back.
///
/// ## What crosses the boundary
///
/// IN: `StoreOpenAuthorization` and `LegacyConversionRequest`, both `Sendable`.
/// OUT: ``LegacyConversionOutcome``, `Sendable`.
/// NEVER: `LedgerStore`, `SQLiteDatabase`, `MigrationCoordinator`, `ActiveOpenEvidence`, or
/// `LegacyConversionFailure`. The first four are created and destroyed inside this call; the
/// last is mapped to a key here.
enum LegacyConversionWorker {

    /// Confirm → open → convert. `confirm` and `open` are adjacent with no suspension point
    /// between them, which is the property `MigrationBootDriver.attemptOpen` gets from
    /// `@MainActor` and this one gets from being a plain synchronous function.
    static func run(authorization: StoreOpenAuthorization,
                    request: LegacyConversionRequest) -> LegacyConversionOutcome {
        let config: MigrationCoordinator.Config
        do {
            config = try MigrationCoordinator.Config.standard()
        } catch {
            LegacyConversionDiagnostics.conversionFailed(error)
            return .failed(.internalFailure)
        }
        let coordinator = MigrationCoordinator(config: config)

        // The FINAL authorization re-check, re-derived from disk. `.reResolve` is terminal
        // here: re-running `bootResolve` is forbidden — its `.pending` branch performs the
        // resume writes before it returns — so the answer is the one the copy already gives,
        // "the ledger changed; run the preflight again".
        let evidence: ActiveOpenEvidence
        switch coordinator.confirmOpenAuthorization(authorization, autoSourceCandidate: .masContainer) {
        case .proceed(.existing(let confirmed)):
            evidence = confirmed
        case .proceed(.createFresh):
            // Unreachable: `authorizesExistingLedger` refused that authorization upstream, and
            // no other authorization can mint this plan. Fail closed rather than open anything.
            LegacyConversionDiagnostics.openRefused("createFresh plan for an existing-ledger authorization")
            return .failed(.internalFailure)
        case .reResolve:
            LegacyConversionDiagnostics.openRefused("reResolve")
            return .failed(.ledgerChanged)
        case .blocked:
            LegacyConversionDiagnostics.openRefused("blocked")
            return .failed(.internalFailure)
        }

        let store: LedgerStore
        do {
            store = try LedgerStore.openActiveExistingHardened(databaseURL: config.activeDestination,
                                                               expect: evidence)
        } catch let error as HardenedOpenError {
            LegacyConversionDiagnostics.conversionFailed(error)
            return .failed(LegacyConversionFailureMap.copy(forOpen: error))
        } catch {
            LegacyConversionDiagnostics.conversionFailed(error)
            return .failed(.internalFailure)
        }
        defer { try? store.db.close() }

        do {
            // The runner recomputes the plan inside its own write transaction and requires it
            // to equal the one handed in — fingerprints included — so a ledger that moved
            // between the preflight and here surfaces as `ledgerChanged` and writes nothing.
            let report = try store.runLegacyConversion(request)
            return .converted(convertedCount: report.convertedCount,
                              backupPath: report.backupDirectory?.path)
        } catch let failure as LegacyConversionFailure {
            LegacyConversionDiagnostics.conversionFailed(failure)
            return .failed(LegacyConversionFailureMap.copy(for: failure))
        } catch {
            LegacyConversionDiagnostics.conversionFailed(error)
            return .failed(.internalFailure)
        }
    }
}
