import Foundation
import SoloLedgerCore

// MARK: - 2B-3 C12b-3: the App-layer presentation + routing mapping for C12 migration state
//
// The SINGLE issue-code / status / kind → localization-key mapping in the app, PLUS the single
// pure routing decision (`route`) shared by production `RootView`, the DEBUG preview, and the
// unit tests. It NEVER parses or displays an `Error.description`, a raw enum, a raw code, a raw
// localization key, or a raw sourceKind string — only stable `migration.*` keys. Every enum
// switch is EXHAUSTIVE with NO `default` (a `String`-keyed lookup like `sourceKind` uses a
// documented unknown fallback, which is required, not a missing case).

enum MigrationPresenter {

    // MARK: Routing (pure; shared by production, preview and tests)

    enum ChainSeverity: Equatable { case retriable, terminal }

    /// A rendering-independent classification of `MigrationUIState` so both the real state and
    /// the DEBUG preview feed the SAME `route`. Carries no Core-internal payload.
    enum RouteInput: Equatable {
        case none, running, acknowledgement, importSelection, retriable, terminal, cleanupResidual
        /// N7.2: a first boot found a clean disk and no usable auto source — the user must
        /// choose "migrate old data" or "create a new ledger" before any store exists.
        case sourceChoice
    }

    /// The mutually-exclusive destination for the root view. Carries only value data.
    enum MigrationRoute: Equatable {
        case bootError
        case legacyRecovery
        case running
        case acknowledgement
        case importSelection
        /// N7.2: the pre-open source-choice screen — fully independent of onboarding, which
        /// continues unchanged only after a store is adopted.
        case chooseSource
        case chainRecovery(ChainSeverity)
        case loading
        case onboarding
        case main(showResidualBanner: Bool)
    }

    static func routeInput(for state: MigrationUIState) -> RouteInput {
        switch state {
        case .none:                    return .none
        case .running:                 return .running
        case .awaitingAcknowledgement: return .acknowledgement
        case .awaitingImportSelection: return .importSelection
        case .retriable:               return .retriable
        case .terminal:                return .terminal
        case .cleanupResidual:         return .cleanupResidual
        case .awaitingSourceChoice:    return .sourceChoice
        }
    }

    /// The mutually-exclusive priority: bootError → legacy recovery → the C12 state (with the
    /// `ready` gate applied to the neutral `.none` / `.cleanupResidual` inputs). `.none` is NOT
    /// "authorized to open" — `ready` still gates it. Exhaustive; no default.
    static func route(bootError: Bool, migrationFailure: Bool, input: RouteInput,
                      ready: Bool, onboardingDone: Bool) -> MigrationRoute {
        if bootError { return .bootError }
        if migrationFailure { return .legacyRecovery }
        switch input {
        case .running:          return .running
        case .sourceChoice:     return .chooseSource
        case .acknowledgement:  return .acknowledgement
        case .importSelection:  return .importSelection
        case .retriable:        return .chainRecovery(.retriable)
        case .terminal:         return .chainRecovery(.terminal)
        case .cleanupResidual:
            guard ready else { return .loading }
            return onboardingDone ? .main(showResidualBanner: true) : .onboarding
        case .none:
            guard ready else { return .loading }
            return onboardingDone ? .main(showResidualBanner: false) : .onboarding
        }
    }

    // MARK: Issue-code → message key (exhaustive; no default)

    /// The localized-message key for a block. Reads the structured `reason` param for the one
    /// case that overrides its code (a user cancel is NOT an invalid selection); otherwise it
    /// maps purely by code. Never reads `detail` or any `Error` text.
    static func messageKey(for block: MigrationBlock) -> String {
        if block.code == .invalidSelection, block.params["reason"] == "userCancelled" {
            return "migration.msg.selectionCancelled"
        }
        return messageKey(for: block.code)
    }

    static func messageKey(for code: MigrationIssueCode) -> String {
        switch code {
        case .sourceBusy:                      return "migration.msg.sourceBusy"
        case .invalidSource:                   return "migration.msg.invalidSource"
        case .sourceCorrupt:                   return "migration.msg.sourceCorrupt"
        case .schemaUnsupported:               return "migration.msg.schemaUnsupported"
        case .migrationFailed:                 return "migration.msg.migrationFailed"
        case .stagingTampered:                 return "migration.msg.stagingTampered"
        case .sentinelOrphan:                  return "migration.msg.sentinelOrphan"
        case .sentinelEntryInvalid:            return "migration.msg.sentinelEntryInvalid"
        case .recordMissingForCompletedImport: return "migration.msg.recordMissingForCompletedImport"
        case .importSlotOccupied:              return "migration.msg.importSlotOccupied"
        case .recordMalformed:                 return "migration.msg.recordMalformed"
        case .recordConflict:                  return "migration.msg.recordConflict"
        case .identityMismatch:                return "migration.msg.identityMismatch"
        case .sentinelConflict:                return "migration.msg.sentinelConflict"
        case .attachmentConflict:              return "migration.msg.attachmentConflict"
        case .activeEntryInvalid:              return "migration.msg.activeEntryInvalid"
        case .activeMissingAfterCompletion:    return "migration.msg.activeMissingAfterCompletion"
        case .activeDatabaseUnsupported:       return "migration.msg.activeDatabaseUnsupported"
        case .interference:                    return "migration.msg.interference"
        case .ioTransient:                     return "migration.msg.ioTransient"
        case .importCannotComplete:            return "migration.msg.importCannotComplete"
        case .invalidSelection:                return "migration.msg.invalidSelection"
        case .storeOpenFailed:                 return "migration.msg.storeOpenFailed"
        case .internalError:                   return "migration.msg.internalError"
        }
    }

    static let allIssueCodes: [MigrationIssueCode] = [
        .sourceBusy, .invalidSource, .sourceCorrupt, .schemaUnsupported, .migrationFailed,
        .stagingTampered, .sentinelOrphan, .sentinelEntryInvalid, .recordMissingForCompletedImport,
        .importSlotOccupied, .recordMalformed, .recordConflict, .identityMismatch,
        .sentinelConflict, .attachmentConflict, .activeEntryInvalid, .activeMissingAfterCompletion,
        .activeDatabaseUnsupported, .interference, .ioTransient, .importCannotComplete,
        .invalidSelection, .storeOpenFailed, .internalError,
    ]

    // MARK: Unresolved-item kind → key (all 7; exhaustive; no default)

    static func unresolvedKindKey(for kind: UnresolvedReport.Item.Kind) -> String {
        switch kind {
        case .missingStagedFile: return "migration.unresolved.missingStagedFile"
        case .skippedSymlink:    return "migration.unresolved.skippedSymlink"
        case .skippedDirectory:  return "migration.unresolved.skippedDirectory"
        case .skippedSpecial:    return "migration.unresolved.skippedSpecial"
        case .rejectedName:      return "migration.unresolved.rejectedName"
        case .danglingReference: return "migration.unresolved.danglingReference"
        case .invalidReference:  return "migration.unresolved.invalidReference"
        }
    }

    static let allUnresolvedKinds: [UnresolvedReport.Item.Kind] = [
        .missingStagedFile, .skippedSymlink, .skippedDirectory, .skippedSpecial,
        .rejectedName, .danglingReference, .invalidReference,
    ]

    // MARK: Candidate status + source

    static func candidateStatusKey(for status: RecoverableImport.Status) -> String {
        switch status {
        case .valid:       return "migration.candidate.valid"
        case .unavailable: return "migration.candidate.unavailable"
        case .invalid:     return "migration.candidate.invalid"
        }
    }

    static func candidateHintKey(for status: RecoverableImport.Status) -> String {
        switch status {
        case .valid:       return "migration.candidate.validHint"
        case .unavailable: return "migration.candidate.unavailableHint"
        case .invalid:     return "migration.candidate.invalidHint"
        }
    }

    static func isSelectable(_ status: RecoverableImport.Status) -> Bool {
        switch status {
        case .valid:                 return true
        case .unavailable, .invalid: return false
        }
    }

    /// The four production `MigrationSource.kind` values → localized labels; any other value maps
    /// to a localized "unknown source" (never the raw string). The `default` is REQUIRED here —
    /// `sourceKind` is a manifest String, not a closed enum.
    static func sourceKindKey(for sourceKind: String) -> String {
        switch sourceKind {
        case "masContainer":        return "migration.source.masContainer"
        case "userSelectedDataDir": return "migration.source.userSelectedDataDir"
        case "exportBundle":        return "migration.source.exportBundle"
        case "legacySingleDB":      return "migration.source.legacySingleDB"
        default:                    return "migration.source.unknown"
        }
    }

    static let productionSourceKinds = ["masContainer", "userSelectedDataDir", "exportBundle", "legacySingleDB"]

    // MARK: Diagnostics (structured allowlist; aggressive path redaction; never Error text)

    /// The generic params that pass through `sanitize` into the report. `step`/`errno` are
    /// deliberately NOT here — they take the contract-gated `reservationDiagnostics` path
    /// (Issue #383), which re-serializes canonical values instead of sanitizing raw input.
    static let diagnosticsAllowedParamKeys: [String] = [
        "op", "reason", "field", "importID", "requestedImportID", "existingImportID",
        "attempts", "userVersion",
    ]

    /// A user-savable, privacy-bounded diagnostics report. PURE. Contains NO transactions,
    /// attachments or database contents, NEVER an `Error.description`; the database path is
    /// reduced to its FILENAME only. Two distinct value paths: GENERIC allowlisted params pass
    /// through `sanitize` (newlines collapsed, absolute paths — home / container / /private /
    /// /var — reduced to `<redacted>/<name>`); the CONTRACT-GATED `step`/`errno` (Issue #383) are
    /// instead PARSED and emitted as canonical RE-SERIALIZED values (enum rawValue / `String(Int32)`),
    /// never routed through the generic allowlist and never through `sanitize`.
    static func diagnosticsText(state: MigrationUIState, schemaVersion: String, databasePath: String,
                                appVersion: String, osVersion: String, homeDirectory: String) -> String {
        var lines: [String] = []
        lines.append("SoloLedger migration diagnostics")
        lines.append("app: \(sanitize(appVersion, home: homeDirectory))")
        lines.append("os: \(sanitize(osVersion, home: homeDirectory))")
        lines.append("schema: \(sanitize(schemaVersion, home: homeDirectory))")
        lines.append("db: <redacted>/\(fileName(databasePath))")   // filename ONLY — no directory structure
        lines.append("state: \(stateTag(state))")
        if let block = block(from: state) {
            lines.append("code: \(block.code.rawValue)")
            lines.append("classification: \(block.classification == .retriable ? "retriable" : "terminal")")
            for key in diagnosticsAllowedParamKeys where block.params[key] != nil {
                lines.append("param.\(key): \(sanitize(block.params[key]!, home: homeDirectory))")
            }
            // Issue #383: createFresh reservation step/errno — emitted ONLY when the full typed
            // contract holds, as canonical RE-SERIALIZED values (never routed through the generic
            // allowlist above, never through `sanitize`), and PAIR-ATOMICALLY (both or neither).
            if let rd = reservationDiagnostics(block) {
                lines.append("param.step: \(rd.step)")
                lines.append("param.errno: \(rd.errno)")
            }
        }
        lines.append("note: no transactions, attachments, or database contents are included.")
        return lines.joined(separator: "\n")
    }

    /// Issue #383: the structured step/errno for a createFresh reservation failure, or nil.
    /// PAIR-ATOMIC and CONTRACT-GATED — returns a value ONLY when EVERY condition holds:
    ///  - the block is a `storeOpenFailed` whose `reason` param is exactly `reservationFailed`;
    ///  - `step` strictly parses to a known `ReservationStep` case;
    ///  - `errno` is a CANONICAL positive `Int32` decimal (see `canonicalPositiveInt32`).
    /// The returned pair is RE-SERIALIZED from the parsed enum/integer, never the raw input, so no
    /// path / strerror / `Error.description` / injected newline can survive — the caller emits it
    /// WITHOUT `sanitize`. Any missing or non-conforming field yields nil (BOTH fields then
    /// omitted), so a partial or forged pair can never reach the report. `step`/`errno` are
    /// deliberately absent from `diagnosticsAllowedParamKeys`: this contract is their ONLY path.
    static func reservationDiagnostics(_ block: MigrationBlock) -> (step: String, errno: String)? {
        guard block.code == .storeOpenFailed,
              block.params["reason"] == "reservationFailed",
              let rawStep = block.params["step"],
              let step = ReservationStep(rawValue: rawStep),
              let rawErrno = block.params["errno"],
              let errno = canonicalPositiveInt32(rawErrno)
        else { return nil }
        return (step.rawValue, String(errno))
    }

    /// A CANONICAL positive `Int32` decimal, or nil. Accepts ONLY ASCII digits — no sign, no
    /// whitespace/newline, no leading zero, strictly positive, in `Int32` range. It deliberately
    /// does NOT rely on `Int32(_:)` alone: on the current Xcode Swift toolchain that init
    /// empirically accepts a leading `+` (`Int32("+1") == 1`) and leading zeros (`Int32("01") == 1`),
    /// which must be rejected here. The explicit ASCII-scalar validation defines an INDEPENDENT,
    /// closed input grammar whose accept set never depends on the underlying parser's; `Int32(_:)`
    /// then supplies only the overflow bound. The parsed value is re-serialized by the caller so
    /// only this canonical form is ever emitted.
    static func canonicalPositiveInt32(_ s: String) -> Int32? {
        guard !s.isEmpty else { return nil }
        let scalars = s.unicodeScalars
        guard scalars.first != "0" else { return nil }                 // no leading zero (also rejects "0")
        for u in scalars where !(u >= "0" && u <= "9") { return nil }   // ASCII digits only: rejects sign/ws/nl/unicode
        guard let v = Int32(s), v > 0 else { return nil }               // range/overflow; positivity belt-and-suspenders
        return v
    }

    /// Collapse newlines (no diagnostic-line injection) and reduce any absolute path token
    /// (leading `/`, `~/`, or the home dir) to `<redacted>/<lastComponent>`.
    static func sanitize(_ s: String, home: String) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        return flat.split(separator: " ", omittingEmptySubsequences: false).map { token -> String in
            let t = String(token)
            let isPath = t.hasPrefix("/") || t.hasPrefix("~/") || (!home.isEmpty && t.hasPrefix(home))
            guard isPath else { return t }
            return "<redacted>/\(fileName(t))"
        }.joined(separator: " ")
    }

    private static func fileName(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? "redacted"
    }

    static func stateTag(_ state: MigrationUIState) -> String {
        switch state {
        case .none:                     return "none"
        case .running:                  return "running"
        case .awaitingAcknowledgement:  return "awaitingAcknowledgement"
        case .awaitingImportSelection:  return "awaitingImportSelection"
        case .retriable:                return "retriable"
        case .terminal:                 return "terminal"
        case .cleanupResidual:          return "cleanupResidual"
        case .awaitingSourceChoice:     return "awaitingSourceChoice"
        }
    }

    static func block(from state: MigrationUIState) -> MigrationBlock? {
        switch state {
        case .retriable(let b), .terminal(let b): return b
        case .none, .running, .awaitingAcknowledgement, .awaitingImportSelection,
             .awaitingSourceChoice, .cleanupResidual:
            return nil
        }
    }
}
