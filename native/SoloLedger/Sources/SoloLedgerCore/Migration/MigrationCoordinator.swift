import Foundation

// MARK: - 2B-3 C12a: migration coordinator — probe-first boot adjudication over the C1–C11 chain
//
// The PUBLIC mapping layer the chain was built for ("a future coordinator maps these
// errors/results to public types"). It sequences ingest → gate → run → activate → finalize,
// derives every boot decision FROM DISK (probe-first, no in-memory state), and emits only
// typed outcomes: a store-open AUTHORIZATION, an acknowledgement request, an import
// selection request, or a typed `MigrationBlock`. The coordinator itself NEVER constructs
// a `LedgerStore` (C12a contract) — the App layer does, and only after re-confirming the
// authorization through `confirmOpenAuthorization` immediately before construction.
//
// `StoreOpenAuthorization` is a TYPED INTENT, not an unforgeable security capability: the
// real gates are the from-disk re-verification in `confirmOpenAuthorization` plus the
// chain's own bound-evidence gates. The window between a passed confirm and SQLite's
// path-based open is an adjacent-syscall residual (point-in-time, not closable on Darwin).
//
// All inspections are no-follow and descriptor-rooted where the primitives allow
// (`DirectoryHandle` / `FileFingerprint` / `BoundRegularFile`) — never
// `FileManager.fileExists`. Every upstream error is mapped through EXHAUSTIVE switches
// (no `default`) into a typed `MigrationBlock`; error `description` text is never parsed.

// MARK: - Public vocabulary

public enum MigrationIssueCode: String, Equatable {
    case sourceBusy, invalidSource, sourceCorrupt, schemaUnsupported, migrationFailed
    case stagingTampered, sentinelOrphan, sentinelEntryInvalid, recordMissingForCompletedImport
    case importSlotOccupied, recordMalformed, recordConflict, identityMismatch
    case sentinelConflict, attachmentConflict
    case activeEntryInvalid, activeMissingAfterCompletion, activeDatabaseUnsupported
    case interference, ioTransient, importCannotComplete, invalidSelection
    case storeOpenFailed, internalError
}

public struct MigrationBlock: Equatable {
    public enum Class: Equatable { case retriable, terminal }
    public let code: MigrationIssueCode
    public let classification: Class
    /// Structured parameters (importID / field / expected / actual / entry …) — data for
    /// localized copy, never prose to parse.
    public let params: [String: String]
    public init(code: MigrationIssueCode, classification: Class, params: [String: String] = [:]) {
        self.code = code; self.classification = classification; self.params = params
    }
    static func retriable(_ code: MigrationIssueCode, _ params: [String: String] = [:]) -> MigrationBlock {
        MigrationBlock(code: code, classification: .retriable, params: params)
    }
    static func terminal(_ code: MigrationIssueCode, _ params: [String: String] = [:]) -> MigrationBlock {
        MigrationBlock(code: code, classification: .terminal, params: params)
    }
}

/// Opaque completion evidence: the owner record as bound-verified when the authorization
/// was minted. The stored property (and therefore the memberwise initializer) is INTERNAL,
/// so the App layer cannot fabricate one — only the coordinator mints it, and
/// `confirmOpenAuthorization` re-verifies the CURRENT bound record against it full-field.
public struct CompletionEvidence: Equatable {
    let record: ActivationRecord
}

/// Typed intent for the App layer's single store-construction site. NOT a capability —
/// see the header; `confirmOpenAuthorization` re-derives each precondition from disk.
public enum StoreOpenAuthorization: Equatable {
    case createFreshExpectedAbsent
    /// A plain (chain-less) active DB: B2 only — active regular ∧ no record ∧ no
    /// canonical/invalid sentinel, all re-verified at confirm time.
    case openExistingPlain
    /// A chain-completed active DB: probe-verified completion. Confirm re-reads the bound
    /// record, requires full-field equality with the evidence, re-runs the WAL-safe probe
    /// (accepting ONLY completed/cleanupPending; never recomputing DB identity/quiescence)
    /// and re-passes the active no-follow regular-file gate.
    case openExistingCompleted(CompletionEvidence)
}

/// C12x-A1: from-disk identity evidence for the authorized ACTIVE existing-store, captured by
/// the coordinator as the LAST disk step before it returns `.proceed(.existing)`. Value type
/// with an INTERNAL initializer and INTERNAL fields, so only the coordinator (and in-module
/// tests) can mint one — the App layer can pass it through but can neither forge nor read it.
/// Carries the active file's PARENT (device,inode) and the full no-follow leaf `FileFingerprint`.
public struct ActiveOpenEvidence: Equatable {
    let parentDevice: Int32
    let parentInode: UInt64
    let leaf: FileFingerprint
    init(parentDevice: Int32, parentInode: UInt64, leaf: FileFingerprint) {
        self.parentDevice = parentDevice
        self.parentInode = parentInode
        self.leaf = leaf
    }
}

/// What a passed `confirmOpenAuthorization` authorizes the single store-open site to do. There
/// is deliberately NO optional evidence: a fresh create carries none, an existing open carries
/// the MANDATORY `ActiveOpenEvidence`, so the two intents can never be conflated or downgraded.
public enum ConfirmedOpenPlan: Equatable {
    case createFresh
    case existing(ActiveOpenEvidence)
}

public enum OpenPrecheck: Equatable {
    case proceed(ConfirmedOpenPlan)
    /// Disk changed since the authorization was minted — run one bounded `bootResolve`
    /// again; never construct the store, never create an empty file on this path.
    case reResolve
    case blocked(MigrationBlock)
}

/// C12x-A1 hardened active-open failure, thrown by `LedgerStore.openActiveExistingHardened` and
/// mapped to a typed `MigrationUIState` by `MigrationBootDriver`. Every case is typed data —
/// there is NO `Error.description`, sqlite message, path or `strerror` anywhere in it.
public enum HardenedOpenError: Error, Equatable {
    /// A path/inode identity check failed BEFORE any write; fail-closed, never auto-reResolve.
    case identity(IdentityViolation)
    /// `HAS_MOVED` returned `SQLITE_NOTFOUND` — cannot verify; treated as a store-open failure.
    case hasMovedUnavailable
    /// `HAS_MOVED` returned `SQLITE_MISUSE` — a programming error; treated as internal.
    case hasMovedMisuse
    /// `HAS_MOVED` returned any other non-OK rc (e.g. an IOERR when a WAL DB's file was swapped).
    /// Carries the AUTHORITATIVE `file_control` rc (not the connection's extended errcode).
    case hasMovedFailed(fileControlRC: Int32, systemErrno: Int32)
    /// A failed `sqlite3_open_v2`, with STRUCTURED numeric codes only (primary/extended/errno).
    case sqlite(primary: Int32, extended: Int32, systemErrno: Int32)
    /// C12x-A2 createFresh: the exclusive reservation `openat(O_CREAT|O_EXCL|O_NOFOLLOW)` hit an
    /// existing entry (EEXIST) — a squatter occupied a supposed-fresh active path. Its OWN error
    /// domain (not an `IdentityViolation`); must NOT auto-reResolve into adopting the squatter.
    case freshCollision
    /// C12x-A2 createFresh: a reservation step failed (parent bind / exclusive create / fstat /
    /// the explicit fd close). Carries only a stable `step` tag and a numeric errno.
    case reservationFailed(step: ReservationStep, errno: Int32)
}

/// Which step of the createFresh exclusive reservation failed (stable tags; no path/message).
public enum ReservationStep: String, Equatable {
    case parentBind    // DirectoryHandle.open(parent) failed (e.g. immediate-parent symlink)
    case openExcl      // openat(O_CREAT|O_EXCL|O_NOFOLLOW) failed with a non-EEXIST errno
    case fstat         // fstat on the freshly-reserved fd failed
    case close         // the explicit, pre-SQL reservation fd close returned non-zero
}

/// The specific identity check that failed on the hardened active-open path (stable tags).
public enum IdentityViolation: String, Equatable {
    /// Open refused with `SQLITE_CANTOPEN_SYMLINK` — a symlink in the resolved active path. A
    /// PERMANENT signal (unsupported path / attack), NOT presented as a retriable transient.
    case unsupportedSymlinkedActivePath
    /// `HAS_MOVED` reported the open connection is bound to a file no longer at its path.
    case moved
    /// The active leaf (or its parent) is gone (ENOENT) at the post-open re-fingerprint.
    case vanished
    /// The active leaf's parent directory (device,inode) no longer matches the evidence.
    case parentIdentityMismatch
    /// The active leaf's full no-follow fingerprint no longer matches the evidence.
    case fingerprintMismatch
    /// The evidence leaf is zero-length — never a valid existing store; refused before open.
    case zeroSizeActiveLeaf
}

/// Cleanup residue note carried alongside a store-open authorization (non-blocking).
public struct MigrationResidual: Equatable {
    public let importID: String
}

public struct RecoverableImport: Equatable {
    /// Candidate classification for the selection UI. The gate's retriable/terminal
    /// distinction is PRESERVED — a transient failure must never display as tampering.
    public enum Status: Equatable {
        case valid
        /// Retriable (transient I/O / interference): not selectable right now; a fresh
        /// probe (re-list / re-select) may recover it.
        case unavailable(MigrationIssueCode)
        /// Terminal (tampered/foreign/unsupported): not selectable.
        case invalid(MigrationIssueCode)
    }
    public let importID: String          // from the validated DIRECTORY name, not the manifest
    public let status: Status
    public let createdAt: String?        // gated-manifest facts; nil unless status is valid
    public let sourceKind: String?       // nil unless status is valid
    public let ingestedCount: Int?       // nil unless status is valid
}

public enum BootOutcome: Equatable {
    case openStore(authorization: StoreOpenAuthorization, residual: MigrationResidual?)
    case requiresAcknowledgement(request: AcknowledgementRequest, unresolved: UnresolvedReport)
    case requiresImportSelection([RecoverableImport])
    case blocked(MigrationBlock)
}

// MARK: - Coordinator

public struct MigrationCoordinator {

    public struct Config {
        public var activeDestination: URL
        public var activeAttachmentsDir: URL
        public var manifestsDir: URL
        public var workingDirectory: URL
        public var preparedRoot: URL
        public init(activeDestination: URL, activeAttachmentsDir: URL, manifestsDir: URL,
                    workingDirectory: URL, preparedRoot: URL) {
            self.activeDestination = activeDestination
            self.activeAttachmentsDir = activeAttachmentsDir
            self.manifestsDir = manifestsDir
            self.workingDirectory = workingDirectory
            self.preparedRoot = preparedRoot
        }
        /// Production wiring — PURE PATH DERIVATION, creates NOTHING. Directories come
        /// into existence only when a chain step actually writes (the runner creates its
        /// work/prepared areas, ingest publishes staging, finalize creates the attachments
        /// and manifests dirs). Probe-first boots therefore never mint empty migration
        /// directories, and a completed/WAL boot works with none of them present.
        public static func standard() throws -> Config {
            let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: false)
                .appendingPathComponent(AppPaths.nativeDataFolderName, isDirectory: true)
            return Config(activeDestination: base.appendingPathComponent(AppPaths.databaseFileName),
                          activeAttachmentsDir: base.appendingPathComponent("attachments", isDirectory: true)
                              .appendingPathComponent("docs", isDirectory: true),
                          manifestsDir: base.appendingPathComponent("ImportManifests", isDirectory: true),
                          workingDirectory: base.appendingPathComponent("ImportWork", isDirectory: true),
                          preparedRoot: base.appendingPathComponent("PreparedImports", isDirectory: true))
        }
    }

    let config: Config
    /// The staging root in use — resolved by PURE derivation (never created here; ingest
    /// alone creates it when publishing). Internal dependency seam: tests inject an
    /// isolated root; production derives the AppPaths layout without touching disk.
    let stagingRootURL: URL?
    /// Internal ingest seam (tests relocate published stagings into their isolated root).
    let ingestOverride: ((MigrationSource, ImportID) throws -> IngestResult)?

    public init(config: Config) {
        self.init(config: config, stagingRootOverride: nil, ingestOverride: nil)
    }
    init(config: Config, stagingRootOverride: URL?,
         ingestOverride: ((MigrationSource, ImportID) throws -> IngestResult)? = nil) {
        self.config = config
        self.stagingRootURL = stagingRootOverride ?? (try? Self.defaultStagingRoot())
        self.ingestOverride = ingestOverride
    }

    /// PURE derivation of the production staging root (`<AppSupport>/<data folder>/Staging`)
    /// — never calls the AppPaths helpers that CREATE directories.
    static func defaultStagingRoot() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: false)
            .appendingPathComponent(AppPaths.nativeDataFolderName, isDirectory: true)
            .appendingPathComponent("Staging", isDirectory: true)
    }

    /// PURE per-import staging path (`<root>/import-<id>`) — the validated ImportID makes
    /// escape impossible; nothing is created.
    private func stagingDirPure(for importID: ImportID) -> URL? {
        stagingRootURL?.appendingPathComponent("import-\(importID.rawValue)", isDirectory: true)
    }

    private func runIngest(_ source: MigrationSource, importID: ImportID) throws -> IngestResult {
        if let ingestOverride { return try ingestOverride(source, importID) }
        return try source.withAccess {
            try StagingIngest().ingest(source, importID: importID, timestamp: DateFormat.timestamp())
        }
    }

    // MARK: Public entry points

    /// Probe-first boot adjudication. `autoSourceCandidate` is the location AUTO adoption
    /// is ALLOWED to use (production: `.masContainer`) — it does NOT assert the source
    /// exists; the coordinator derives the candidate's current state from disk on every
    /// call and never caches an earlier absence/presence conclusion.
    public func bootResolve(autoSourceCandidate: MigrationSource?,
                            acknowledgement: Acknowledgement? = nil) -> BootOutcome {
        bootResolve(autoSourceCandidate: autoSourceCandidate, acknowledgement: acknowledgement,
                    hooks: CoordinatorHooks())
    }

    /// Explicit user-driven import. Never mixes with `autoSourceCandidate`; slot conflicts
    /// are surfaced (`importSlotOccupied`) — the user's chosen import is never silently
    /// dropped or re-adjudicated away.
    public func runImport(source: MigrationSource,
                          acknowledgement: Acknowledgement? = nil) -> BootOutcome {
        fullChain(source: source, acknowledgement: acknowledgement,
                  context: .explicitImport, hooks: CoordinatorHooks())
    }

    /// Consume a selection from `requiresImportSelection`. Trusts NOTHING from the list
    /// stage: validates the ID, re-enumerates staging descriptor-rooted, re-confirms the
    /// candidate is still present, re-runs the gate, and consumes only that fresh evidence.
    public func resolveSelectedImport(importID raw: String,
                                      acknowledgement: Acknowledgement? = nil) -> BootOutcome {
        resolveSelectedImport(importID: raw, acknowledgement: acknowledgement, hooks: CoordinatorHooks())
    }

    /// FINAL authorization re-check — call IMMEDIATELY before constructing `LedgerStore`.
    /// Every authorization re-derives its preconditions from disk through this single
    /// entry (the App layer duplicates none of the scanning rules):
    ///  - `.createFreshExpectedAbsent`: active absent ∧ record absent ∧ no published or
    ///    suspicious `import-*` entry ∧ no canonicalFinal/invalid sentinel ∧ the
    ///    `autoSourceCandidate` is STILL unavailable (re-checked now, never cached);
    ///  - `.openExistingPlain`: the active name still resolves no-follow to a regular
    ///    file ∧ the owner record is STILL absent ∧ no canonicalFinal/invalid sentinel
    ///    has appeared;
    ///  - `.openExistingCompleted`: the CURRENT bound record equals the
    ///    `CompletionEvidence` record full-field ∧ the WAL-safe completion probe re-runs
    ///    and returns completed/cleanupPending ONLY (never recomputing DB identity,
    ///    never demanding quiescence) ∧ the active name re-passes the no-follow
    ///    regular-file gate.
    /// Any changed condition → `.reResolve` (no store, no empty file; the semantic
    /// classification belongs to the fresh `bootResolve`). The authorization is a typed
    /// INTENT, not a capability — the confirm→SQLite-open window remains an
    /// adjacent-syscall residual.
    public func confirmOpenAuthorization(_ authorization: StoreOpenAuthorization,
                                         autoSourceCandidate: MigrationSource?) -> OpenPrecheck {
        switch authorization {
        case .openExistingPlain:
            // Plain B2: active still a no-follow regular file, the record is STILL absent,
            // and no canonical/invalid sentinel has appeared.
            switch Self.inspectActiveEntry(activeDestination: config.activeDestination) {
            case .boundRegularFile: break
            case .absent, .invalidType: return .reResolve
            case .metadataReadFailed(let m): return .blocked(.retriable(.ioTransient, ["op": "activeEntry", "detail": m]))
            }
            switch Self.inspectRecord(activeDestination: config.activeDestination) {
            case .none: break
            case .record, .malformed: return .reResolve
            case .unreadableRetriable(let m): return .blocked(.retriable(.ioTransient, ["op": "record", "detail": m]))
            }
            switch Self.scanSentinels(manifestsDir: config.manifestsDir) {
            case .scanFailed(let m): return .blocked(.retriable(.ioTransient, ["op": "sentinelScan", "detail": m]))
            case .ok(let scan):
                if !scan.canonicalFinalIDs.isEmpty || !scan.invalidEntries.isEmpty { return .reResolve }
            }
            // Capture the active identity as the LAST disk step before authorizing the open.
            switch Self.captureActiveEvidence(activeDestination: config.activeDestination) {
            case .captured(let ev):    return .proceed(.existing(ev))
            case .absentOrInvalidType: return .reResolve
            case .metadataReadFailed:  return .blocked(.retriable(.ioTransient, ["op": "activeEvidence"]))
            }
        case .openExistingCompleted(let evidence):
            // The CURRENT bound record must equal the authorization-time record full-field.
            switch Self.inspectRecord(activeDestination: config.activeDestination) {
            case .record(let now):
                guard now == evidence.record else { return .reResolve }
            case .none, .malformed: return .reResolve
            case .unreadableRetriable(let m): return .blocked(.retriable(.ioTransient, ["op": "record", "detail": m]))
            }
            // WAL-safe probe re-run — ONLY completed/cleanupPending are acceptable; the
            // probe never recomputes DB identity or demands quiescence.
            guard let importID = ImportID(evidence.record.importID) else { return .reResolve }
            let probe: PreparedImportFinalizer.CompletionProbe
            do {
                probe = try PreparedImportFinalizer.probeCompletion(expected: evidence.record, importID: importID,
                                                                    manifestsDir: config.manifestsDir,
                                                                    stagingDir: stagingDirPure(for: importID))
            } catch { return .blocked(.retriable(.ioTransient, ["op": "probe", "detail": "\(error)"])) }
            switch probe {
            case .completed, .cleanupPending: break
            case .pending, .conflict: return .reResolve
            }
            // Capture the active identity as the LAST disk step before authorizing the open.
            switch Self.captureActiveEvidence(activeDestination: config.activeDestination) {
            case .captured(let ev):    return .proceed(.existing(ev))
            case .absentOrInvalidType: return .reResolve
            case .metadataReadFailed:  return .blocked(.retriable(.ioTransient, ["op": "activeEvidence"]))
            }
        case .createFreshExpectedAbsent:
            switch Self.inspectActiveEntry(activeDestination: config.activeDestination) {
            case .absent: break
            case .boundRegularFile, .invalidType: return .reResolve
            case .metadataReadFailed(let m): return .blocked(.retriable(.ioTransient, ["op": "activeEntry", "detail": m]))
            }
            switch Self.inspectRecord(activeDestination: config.activeDestination) {
            case .none: break
            case .record, .malformed: return .reResolve
            case .unreadableRetriable(let m): return .blocked(.retriable(.ioTransient, ["op": "record", "detail": m]))
            }
            switch Self.scanSentinels(manifestsDir: config.manifestsDir) {
            case .scanFailed(let m): return .blocked(.retriable(.ioTransient, ["op": "sentinelScan", "detail": m]))
            case .ok(let scan):
                if !scan.canonicalFinalIDs.isEmpty || !scan.invalidEntries.isEmpty { return .reResolve }
            }
            switch scanStaging() {
            case .scanFailed(let m), .suspiciousMetadata(let m):
                return .blocked(.retriable(.ioTransient, ["op": "stagingScan", "detail": m]))
            case .ok(let scan):
                if !scan.publishedImportIDs.isEmpty || !scan.suspiciousTerminal.isEmpty { return .reResolve }
            }
            switch Self.sourceState(autoSourceCandidate) {   // re-derived NOW, never cached
            case .available: return .reResolve
            case .unstable(let m): return .blocked(.retriable(.interference, ["op": "sourceState", "detail": m]))
            case .unavailable: return .proceed(.createFresh)
            }
        }
    }

    // MARK: Internal seams (test-only, no-op by default)

    struct CoordinatorHooks {
        /// Fires immediately before the activation step of a chain run — the adjudication
        /// window (a competing instance may publish the winner record here).
        var beforeActivate: (() throws -> Void)?
        init(beforeActivate: (() throws -> Void)? = nil) { self.beforeActivate = beforeActivate }
    }

    func bootResolve(autoSourceCandidate: MigrationSource?, acknowledgement: Acknowledgement?,
                     hooks: CoordinatorHooks) -> BootOutcome {
        switch Self.inspectRecord(activeDestination: config.activeDestination) {
        case .malformed(let m):
            return .blocked(.terminal(.recordMalformed, ["detail": m]))
        case .unreadableRetriable(let m):
            return .blocked(.retriable(.ioTransient, ["op": "record", "detail": m]))
        case .record(let record):
            return resolveWithRecord(record, acknowledgement: acknowledgement,
                                     autoSourceCandidate: autoSourceCandidate,
                                     adjudicated: false, hooks: hooks)
        case .none:
            return resolveWithoutRecord(acknowledgement: acknowledgement,
                                        autoSourceCandidate: autoSourceCandidate, hooks: hooks)
        }
    }

    // MARK: - R present: probe-first (B3/B4)

    private func resolveWithRecord(_ record: ActivationRecord, acknowledgement: Acknowledgement?,
                                   autoSourceCandidate: MigrationSource?,
                                   adjudicated: Bool, hooks: CoordinatorHooks) -> BootOutcome {
        guard let importID = ImportID(record.importID) else {
            return .blocked(.terminal(.recordMalformed, ["detail": "record importID fails validation"]))
        }
        guard let stagingDir = stagingDirPure(for: importID) else {
            return .blocked(.retriable(.ioTransient, ["op": "stagingRoot", "detail": "staging root derivation failed"]))
        }

        let probe: PreparedImportFinalizer.CompletionProbe
        do {
            probe = try PreparedImportFinalizer.probeCompletion(expected: record, importID: importID,
                                                                manifestsDir: config.manifestsDir,
                                                                stagingDir: stagingDir)
        } catch let e as FinalizeError { return .blocked(Self.map(e)) }
        catch { return .blocked(.retriable(.ioTransient, ["op": "probe", "detail": "\(error)"])) }

        switch probe {
        case .conflict(let why):
            return .blocked(.terminal(.sentinelConflict, ["importID": record.importID, "detail": why]))
        case .completed:
            return completedOpenOutcome(record: record, residual: nil)
        case .cleanupPending:
            var residual: MigrationResidual? = MigrationResidual(importID: record.importID)
            // Best-effort convergence: ONLY through re-gated evidence, never a URL removal.
            if let gated = try? StagedSnapshotGate().gate(stagingDir: stagingDir),
               Self.crossCheckField(gated, record) == nil,
               PreparedImportFinalizer.cleanupResidue(gated: gated) == nil {
                residual = nil
            }
            return completedOpenOutcome(record: record, residual: residual)
        case .pending:
            return resumeChain(record: record, importID: importID, stagingDir: stagingDir,
                               acknowledgement: acknowledgement,
                               autoSourceCandidate: autoSourceCandidate,
                               adjudicated: adjudicated, hooks: hooks)
        }
    }

    /// The store-open gate for a COMPLETED import: the active name must resolve no-follow
    /// to a regular file — absent means the completed import's database vanished (terminal;
    /// constructing a store would silently mint an empty ledger over a completed import).
    /// The minted authorization carries the OPAQUE completion evidence (bound record).
    private func completedOpenOutcome(record: ActivationRecord, residual: MigrationResidual?) -> BootOutcome {
        switch Self.inspectActiveEntry(activeDestination: config.activeDestination) {
        case .boundRegularFile:
            return .openStore(authorization: .openExistingCompleted(CompletionEvidence(record: record)),
                              residual: residual)
        case .absent:
            return .blocked(.terminal(.activeMissingAfterCompletion, ["importID": record.importID]))
        case .invalidType(let m):
            return .blocked(.terminal(.activeEntryInvalid, ["detail": m]))
        case .metadataReadFailed(let m):
            return .blocked(.retriable(.ioTransient, ["op": "activeEntry", "detail": m]))
        }
    }

    /// After a chain run just completed: re-derive the completion evidence from the disk
    /// record (bound double-read) and mint the completed authorization.
    private func completedOutcomeAfterChain(residual: MigrationResidual?) -> BootOutcome {
        switch Self.inspectRecord(activeDestination: config.activeDestination) {
        case .record(let record):
            return completedOpenOutcome(record: record, residual: residual)
        case .none:
            return .blocked(.retriable(.interference, ["op": "record", "detail": "record vanished after completion"]))
        case .malformed(let m):
            return .blocked(.terminal(.recordMalformed, ["detail": m]))
        case .unreadableRetriable(let m):
            return .blocked(.retriable(.ioTransient, ["op": "record", "detail": m]))
        }
    }

    // MARK: - R present, probe pending: resume

    private func resumeChain(record: ActivationRecord, importID: ImportID, stagingDir: URL,
                             acknowledgement: Acknowledgement?, autoSourceCandidate: MigrationSource?,
                             adjudicated: Bool, hooks: CoordinatorHooks) -> BootOutcome {
        let fp: FileFingerprint?
        do { fp = try FileFingerprint.capture(at: stagingDir) }
        catch { return .blocked(.retriable(.ioTransient, ["op": "stagingFingerprint", "detail": "\(error)"])) }

        if fp == nil {
            // Definitive ENOENT — the ONLY state that permits a same-importID re-ingest.
            switch Self.sourceState(autoSourceCandidate) {
            case .unavailable:
                return .blocked(.terminal(.importCannotComplete, ["importID": record.importID]))
            case .unstable(let m):
                return .blocked(.retriable(.interference, ["op": "sourceState", "detail": m]))
            case .available:
                do {
                    _ = try runIngest(autoSourceCandidate!, importID: importID)
                } catch let e as IngestError {
                    if case .importIDAlreadyExists = e {
                        // A racer republished the staging — gate the existing one below.
                    } else {
                        return .blocked(Self.map(e, context: .autoBoot))
                    }
                } catch { return .blocked(.retriable(.ioTransient, ["op": "reingest", "detail": "\(error)"])) }
            }
        }
        // Path exists (or was just republished): gate the EXISTING staging — never an
        // automatic re-ingest over it (importIDAlreadyExists is the safety boundary).
        let gated: GatedStagedSnapshot
        do { gated = try StagedSnapshotGate().gate(stagingDir: stagingDir) }
        catch let e as StagedSnapshotError { return .blocked(Self.map(e)) }
        catch { return .blocked(.retriable(.ioTransient, ["op": "gate", "detail": "\(error)"])) }

        // PRE-RUNNER cross-check: the gated evidence must be THIS record's snapshot —
        // a wrong source / swapped staging fails fast here, not at activation.
        if let field = Self.crossCheckField(gated, record) {
            return .blocked(.terminal(.identityMismatch, ["field": field, "importID": record.importID]))
        }
        return runChain(gated: gated, acknowledgement: acknowledgement,
                        autoSourceCandidate: autoSourceCandidate,
                        context: .autoBoot, adjudicated: adjudicated, hooks: hooks)
    }

    // MARK: - R absent: exhaustive Sent × ActiveEntry table, then B2/B1

    private func resolveWithoutRecord(acknowledgement: Acknowledgement?,
                                      autoSourceCandidate: MigrationSource?,
                                      hooks: CoordinatorHooks) -> BootOutcome {
        let active = Self.inspectActiveEntry(activeDestination: config.activeDestination)
        // P1: a violated active slot is reported before ANY sentinel interpretation.
        if case .invalidType(let m) = active {
            return .blocked(.terminal(.activeEntryInvalid, ["detail": m]))
        }
        let sentScan = Self.scanSentinels(manifestsDir: config.manifestsDir)
        let scan: SentinelScan
        switch sentScan {
        case .scanFailed(let m):                                                        // P2
            return .blocked(.retriable(.ioTransient, ["op": "sentinelScan", "detail": m]))
        case .ok(let s): scan = s
        }
        if let bad = scan.invalidEntries.first {                                        // P3
            return .blocked(.terminal(.sentinelEntryInvalid, ["entry": bad]))
        }
        if case .metadataReadFailed(let m) = active {                                    // P4
            return .blocked(.retriable(.ioTransient, ["op": "activeEntry", "detail": m]))
        }
        if let completedID = scan.canonicalFinalIDs.first {                              // P5
            switch active {
            case .absent:
                return .blocked(.terminal(.sentinelOrphan, ["importID": completedID]))
            case .boundRegularFile:
                return .blocked(.terminal(.recordMissingForCompletedImport, ["importID": completedID]))
            case .invalidType, .metadataReadFailed:
                return .blocked(.terminal(.internalError, ["detail": "unreachable: P1/P4 precede P5"]))
            }
        }
        switch active {                                                                  // P6
        case .boundRegularFile:
            return .openStore(authorization: .openExistingPlain, residual: nil)             // B2
        case .absent:
            return resolveB1(acknowledgement: acknowledgement,
                             autoSourceCandidate: autoSourceCandidate, hooks: hooks)
        case .invalidType, .metadataReadFailed:
            return .blocked(.terminal(.internalError, ["detail": "unreachable: P1/P4 precede P6"]))
        }
    }

    private func resolveB1(acknowledgement: Acknowledgement?, autoSourceCandidate: MigrationSource?,
                           hooks: CoordinatorHooks) -> BootOutcome {
        let stagingScan = scanStaging()
        let scan: StagingScan
        switch stagingScan {
        case .scanFailed(let m), .suspiciousMetadata(let m):
            return .blocked(.retriable(.ioTransient, ["op": "stagingScan", "detail": m]))
        case .ok(let s): scan = s
        }
        if let bad = scan.suspiciousTerminal.first {
            return .blocked(.terminal(.stagingTampered, ["entry": bad]))
        }
        switch scan.publishedImportIDs.count {
        case 0:
            switch Self.sourceState(autoSourceCandidate) {
            case .available:
                return fullChain(source: autoSourceCandidate!, acknowledgement: acknowledgement,
                                 context: .autoBoot, hooks: hooks)
            case .unstable(let m):
                return .blocked(.retriable(.interference, ["op": "sourceState", "detail": m]))
            case .unavailable:
                return .openStore(authorization: .createFreshExpectedAbsent, residual: nil)
            }
        case 1:
            let id = scan.publishedImportIDs[0]
            return recoverPublishedStaging(importIDRaw: id, acknowledgement: acknowledgement,
                                           autoSourceCandidate: autoSourceCandidate,
                                           context: .autoBoot, hooks: hooks)
        default:
            return .requiresImportSelection(buildCandidates(scan.publishedImportIDs))
        }
    }

    private func recoverPublishedStaging(importIDRaw: String, acknowledgement: Acknowledgement?,
                                         autoSourceCandidate: MigrationSource?,
                                         context: SourceContext,
                                         hooks: CoordinatorHooks) -> BootOutcome {
        guard let importID = ImportID(importIDRaw) else {
            return .blocked(.terminal(.stagingTampered, ["entry": "import-\(importIDRaw)"]))
        }
        guard let stagingDir = stagingDirPure(for: importID) else {
            return .blocked(.retriable(.ioTransient, ["op": "stagingRoot", "detail": "staging root derivation failed"]))
        }
        let gated: GatedStagedSnapshot
        do { gated = try StagedSnapshotGate().gate(stagingDir: stagingDir) }
        catch let e as StagedSnapshotError { return .blocked(Self.map(e)) }
        catch { return .blocked(.retriable(.ioTransient, ["op": "gate", "detail": "\(error)"])) }
        return runChain(gated: gated, acknowledgement: acknowledgement,
                        autoSourceCandidate: autoSourceCandidate,
                        context: context, adjudicated: false, hooks: hooks)
    }

    func resolveSelectedImport(importID raw: String, acknowledgement: Acknowledgement?,
                               hooks: CoordinatorHooks) -> BootOutcome {
        // 1. Validate — never trust the UI string (path escape / illegal chars).
        guard let importID = ImportID(raw) else {
            return .blocked(.terminal(.invalidSelection, ["importID": raw]))
        }
        // 2. Fresh descriptor-rooted enumeration (no list-stage caching).
        let scan: StagingScan
        switch scanStaging() {
        case .scanFailed(let m), .suspiciousMetadata(let m):
            return .blocked(.retriable(.ioTransient, ["op": "stagingScan", "detail": m]))
        case .ok(let s): scan = s
        }
        // 3. The candidate must still be present in THIS enumeration.
        guard scan.publishedImportIDs.contains(importID.rawValue) else {
            return .blocked(.terminal(.stagingTampered, ["importID": importID.rawValue]))
        }
        // 4+5. Fresh gate; consume only its snapshot. `selectedRecovery` context: a slot
        // conflict SURFACES (the user's choice is never re-adjudicated to an auto winner).
        return recoverPublishedStaging(importIDRaw: importID.rawValue, acknowledgement: acknowledgement,
                                       autoSourceCandidate: nil, context: .selectedRecovery, hooks: hooks)
    }

    // MARK: - Full chain (new import) and shared chain tail

    enum SourceContext { case autoBoot, explicitImport, selectedRecovery }

    private func fullChain(source: MigrationSource, acknowledgement: Acknowledgement?,
                           context: SourceContext, hooks: CoordinatorHooks) -> BootOutcome {
        let importID = ImportID.generate()
        let result: IngestResult
        do {
            result = try runIngest(source, importID: importID)
        } catch let e as IngestError { return .blocked(Self.map(e, context: context)) }
        catch { return .blocked(.retriable(.ioTransient, ["op": "ingest", "detail": "\(error)"])) }

        let gated: GatedStagedSnapshot
        do { gated = try StagedSnapshotGate().gate(result) }
        catch let e as StagedSnapshotError { return .blocked(Self.map(e)) }
        catch { return .blocked(.retriable(.ioTransient, ["op": "gate", "detail": "\(error)"])) }
        return runChain(gated: gated, acknowledgement: acknowledgement,
                        autoSourceCandidate: context == .autoBoot ? source : nil,
                        context: context, adjudicated: false, hooks: hooks)
    }

    private func runChain(gated: GatedStagedSnapshot, acknowledgement: Acknowledgement?,
                          autoSourceCandidate: MigrationSource?,
                          context: SourceContext, adjudicated: Bool,
                          hooks: CoordinatorHooks) -> BootOutcome {
        let prepared: PreparedImport
        do { prepared = try PreparedImportRunner().run(gated, workingDirectory: config.workingDirectory,
                                                       preparedRoot: config.preparedRoot) }
        catch let e as PreparedRunFailure { return .blocked(Self.map(e)) }
        catch { return .blocked(.retriable(.ioTransient, ["op": "runner", "detail": "\(error)"])) }

        do { try hooks.beforeActivate?() }
        catch { return .blocked(.retriable(.ioTransient, ["op": "hook", "detail": "\(error)"])) }

        let activated: ActivatedDatabase
        do { activated = try PreparedImportActivator().activate(prepared, activeDestination: config.activeDestination) }
        catch let e as ActivationError {
            switch e {
            case .publishRaceLost, .activationRecordConflict, .activeSlotOccupied:
                switch context {
                case .explicitImport, .selectedRecovery:
                    // The user's chosen import is never silently re-adjudicated away and
                    // never dropped: surface the conflict with both identities when the
                    // winner record is safely readable.
                    var params = ["requestedImportID": gated.importID.rawValue]
                    if case .record(let winner) = Self.inspectRecord(activeDestination: config.activeDestination) {
                        params["existingImportID"] = winner.importID
                    }
                    return .blocked(.terminal(.importSlotOccupied, params))
                case .autoBoot:
                    guard !adjudicated else {
                        return .blocked(.terminal(.recordConflict,
                                                  ["requestedImportID": gated.importID.rawValue]))
                    }
                    return adjudicateFromDisk(acknowledgement: acknowledgement,
                                              autoSourceCandidate: autoSourceCandidate, hooks: hooks)
                }
            case .invalidActiveDestination, .activeParentUnreadable, .activePublishFailed,
                 .activationRecordReadFailed, .activationRecordMalformed, .recordPublishFailed,
                 .recordWritebackMismatch, .recordNameSwapped, .recordPublishedMismatch,
                 .recordUnboundDuringActivation, .candidateMaterializeFailed, .candidateRehashMismatch,
                 .candidateNameSwapped, .publishedActiveMismatch, .sidecarAppeared,
                 .activeIdentityMismatch, .durabilitySyncFailed, .durabilityNotConfirmed:
                return .blocked(Self.map(e))
            }
        }
        catch { return .blocked(.retriable(.ioTransient, ["op": "activate", "detail": "\(error)"])) }

        let outcome: FinalizeOutcome
        do { outcome = try PreparedImportFinalizer().finalize(activated, gated: gated,
                                                              activeAttachmentsDir: config.activeAttachmentsDir,
                                                              acknowledgement: acknowledgement,
                                                              manifestsDir: config.manifestsDir) }
        catch let e as FinalizeError { return .blocked(Self.map(e)) }
        catch { return .blocked(.retriable(.ioTransient, ["op": "finalize", "detail": "\(error)"])) }

        switch outcome {
        case .requiresAcknowledgement(let request, let unresolved):
            return .requiresAcknowledgement(request: request, unresolved: unresolved)
        case .completed:
            return completedOutcomeAfterChain(residual: nil)
        case .completedButCleanupFailed:
            return completedOutcomeAfterChain(residual: MigrationResidual(importID: gated.importID.rawValue))
        }
    }

    /// BOUNDED (once) from-disk re-adjudication after an auto-boot activation conflict:
    /// re-read the winner's record and continue per the WINNER's state (probe-first).
    private func adjudicateFromDisk(acknowledgement: Acknowledgement?,
                                    autoSourceCandidate: MigrationSource?,
                                    hooks: CoordinatorHooks) -> BootOutcome {
        switch Self.inspectRecord(activeDestination: config.activeDestination) {
        case .record(let winner):
            return resolveWithRecord(winner, acknowledgement: acknowledgement,
                                     autoSourceCandidate: autoSourceCandidate,
                                     adjudicated: true, hooks: hooks)
        case .none:
            return .blocked(.terminal(.recordConflict, ["detail": "conflicting record vanished during adjudication"]))
        case .malformed(let m):
            return .blocked(.terminal(.recordMalformed, ["detail": m]))
        case .unreadableRetriable(let m):
            return .blocked(.retriable(.ioTransient, ["op": "record", "detail": m]))
        }
    }

    // MARK: - Disk inspections (no-follow; never FileManager.fileExists)

    enum ActiveEntryState {
        case absent
        case boundRegularFile
        case invalidType(String)
        case metadataReadFailed(String)
    }

    static func inspectActiveEntry(activeDestination: URL) -> ActiveEntryState {
        let parentURL = activeDestination.deletingLastPathComponent()
        let name = activeDestination.lastPathComponent
        let parent: DirectoryHandle
        do { parent = try DirectoryHandle.open(at: parentURL) }
        catch let e as FileHashError where e.isFileMissing { return .absent }
        catch { return .metadataReadFailed("active parent: \(error)") }
        do {
            guard let fp = try parent.fingerprint(named: name) else { return .absent }
            return fp.isRegularFile ? .boundRegularFile : .invalidType("active entry is not a regular file")
        } catch { return .metadataReadFailed("active entry: \(error)") }
    }

    /// Outcome of the final-step `ActiveOpenEvidence` capture for an existing-store confirm.
    enum ActiveEvidenceCapture {
        case captured(ActiveOpenEvidence)
        case absentOrInvalidType    // → confirm returns .reResolve (a pre-open semantic change)
        case metadataReadFailed     // → confirm returns .blocked(.retriable(.ioTransient))
    }

    /// C12x-A1: capture the active leaf's identity (parent device+inode and the full no-follow
    /// leaf fingerprint) — the LAST disk step before an existing-store confirm returns
    /// `.proceed(.existing)`. No error text leaves this function.
    static func captureActiveEvidence(activeDestination: URL) -> ActiveEvidenceCapture {
        let parentURL = activeDestination.deletingLastPathComponent()
        let name = activeDestination.lastPathComponent
        let parent: DirectoryHandle
        do { parent = try DirectoryHandle.open(at: parentURL) }
        catch let e as FileHashError where e.isFileMissing { return .absentOrInvalidType }
        catch { return .metadataReadFailed }
        do {
            guard let fp = try parent.fingerprint(named: name) else { return .absentOrInvalidType }
            guard fp.isRegularFile else { return .absentOrInvalidType }
            return .captured(ActiveOpenEvidence(parentDevice: parent.device, parentInode: parent.inode, leaf: fp))
        } catch { return .metadataReadFailed }
    }

    enum SlotRecordState {
        case none
        case record(ActivationRecord)
        case unreadableRetriable(String)
        case malformed(String)
    }

    /// Bound, no-follow, size-capped read of the owner record — same classification
    /// semantics as the activator's adopt path (malformed vs transient), without touching
    /// the database. The returned record is BOUND-VERIFIED: after the first decode the
    /// final name must still resolve to the bound fd, a SECOND bound read must decode
    /// semantically identical, and the name binding is checked once more — any name or
    /// content change during inspection fails closed retriable; a stale record is never
    /// returned. `afterFirstRead` is a test-only seam inside that window.
    static func inspectRecord(activeDestination: URL,
                              afterFirstRead: (() throws -> Void)? = nil) -> SlotRecordState {
        let parentURL = activeDestination.deletingLastPathComponent()
        let parent: DirectoryHandle
        do { parent = try DirectoryHandle.open(at: parentURL) }
        catch let e as FileHashError where e.isFileMissing { return .none }
        catch { return .unreadableRetriable("active parent: \(error)") }
        let name = PreparedImportActivator.recordName
        do {
            guard let fp = try parent.fingerprint(named: name) else { return .none }
            guard fp.isRegularFile else { return .malformed("owner record entry is not a regular file") }
        } catch { return .unreadableRetriable("record fingerprint: \(error)") }
        let rec: BoundRegularFile
        do { rec = try BoundRegularFile.open(in: parent, named: name) }
        catch let e as FileHashError {
            if case .notARegularFile = e { return .malformed("\(e)") }
            return .unreadableRetriable("record open: \(e)")
        }
        catch { return .unreadableRetriable("record open: \(error)") }

        enum Decoded { case ok(ActivationRecord); case fail(SlotRecordState) }
        func boundDecode(_ what: String) -> Decoded {
            let data: Data
            do { data = try rec.readAll() }   // 64 KiB owner-record cap; EFBIG fails below
            catch let e as FileHashError {
                if case .unreadable(_, let errno) = e, errno == EFBIG {
                    return .fail(.malformed("owner record exceeds the size cap"))
                }
                return .fail(.unreadableRetriable("record read \(what): \(e)"))
            }
            catch { return .fail(.unreadableRetriable("record read \(what): \(error)")) }
            guard let decoded = try? JSONDecoder().decode(ActivationRecord.self, from: data) else {
                return .fail(.malformed("undecodable owner record"))
            }
            guard decoded.formatVersion == ActivationRecord.currentFormatVersion else {
                return .fail(.malformed("unsupported owner-record formatVersion \(decoded.formatVersion)"))
            }
            return .ok(decoded)
        }

        let first: ActivationRecord
        switch boundDecode("first") {
        case .fail(let s): return s
        case .ok(let r): first = r
        }
        if let afterFirstRead {
            do { try afterFirstRead() }
            catch { return .unreadableRetriable("inspection seam: \(error)") }
        }
        guard (try? rec.matchesChild(named: name, in: parent)) == true else {
            return .unreadableRetriable("record name unbound after the first read")
        }
        let second: ActivationRecord
        switch boundDecode("second") {
        case .fail(let s): return s
        case .ok(let r): second = r
        }
        guard second == first else {
            return .unreadableRetriable("record content changed during inspection")
        }
        guard (try? rec.matchesChild(named: name, in: parent)) == true else {
            return .unreadableRetriable("record name unbound after the second read")
        }
        return .record(first)
    }

    struct SentinelScan {
        var canonicalFinalIDs: [String] = []   // strictly "<valid ImportID>.json" ∧ no-follow regular
        var invalidEntries: [String] = []      // canonical shape but symlink/directory/special
        var tempResidue: [String] = []         // C11a ".tmp-*" crash orphans (reaper; non-blocking)
        var unknownResidue: [String] = []      // foreign names (never read/deleted; non-blocking)
    }
    enum SentinelScanResult { case ok(SentinelScan); case scanFailed(String) }

    static func scanSentinels(manifestsDir: URL) -> SentinelScanResult {
        let dir: DirectoryHandle
        do { dir = try DirectoryHandle.open(at: manifestsDir) }
        catch let e as FileHashError where e.isFileMissing { return .ok(SentinelScan()) }
        catch { return .scanFailed("manifests dir: \(error)") }
        let names: [String]
        do { names = try dir.entryNames() }
        catch { return .scanFailed("manifests enumeration: \(error)") }
        var scan = SentinelScan()
        for name in names {
            if name.hasPrefix(".tmp-") { scan.tempResidue.append(name); continue }
            if name.hasSuffix(".json"), let id = ImportID(String(name.dropLast(".json".count))) {
                do {
                    guard let fp = try dir.fingerprint(named: name) else { continue }   // vanished mid-scan
                    if fp.isRegularFile { scan.canonicalFinalIDs.append(id.rawValue) }
                    else { scan.invalidEntries.append(name) }
                } catch { return .scanFailed("sentinel fingerprint '\(name)': \(error)") }
                continue
            }
            scan.unknownResidue.append(name)
        }
        return .ok(scan)
    }

    struct StagingScan {
        var publishedImportIDs: [String] = []   // "import-<valid id>" ∧ no-follow directory
        var suspiciousTerminal: [String] = []   // "import-*" with invalid id or non-directory type
        var attemptResidue: [String] = []       // ".attempt-*" (reaper; non-blocking)
        var unknownResidue: [String] = []       // non-blocking
    }
    enum StagingScanResult { case ok(StagingScan); case scanFailed(String); case suspiciousMetadata(String) }

    /// `import-*`-shaped entries with an invalid ImportID, a non-directory type, or
    /// unreadable metadata are NEVER unknown residue — they block createFresh (terminal /
    /// retriable respectively). Root ENOENT reads as an EMPTY scan; the root is never
    /// created for scanning.
    func scanStaging() -> StagingScanResult {
        guard let rootURL = stagingRootURL else { return .scanFailed("staging root derivation failed") }
        let root: DirectoryHandle
        do { root = try DirectoryHandle.open(at: rootURL) }
        catch let e as FileHashError where e.isFileMissing { return .ok(StagingScan()) }
        catch { return .scanFailed("staging root: \(error)") }
        let names: [String]
        do { names = try root.entryNames() }
        catch { return .scanFailed("staging enumeration: \(error)") }
        var scan = StagingScan()
        for name in names {
            if name.hasPrefix(".attempt-") { scan.attemptResidue.append(name); continue }
            guard name.hasPrefix("import-") else { scan.unknownResidue.append(name); continue }
            let stem = String(name.dropFirst("import-".count))
            guard let id = ImportID(stem) else { scan.suspiciousTerminal.append(name); continue }
            do {
                guard let fp = try root.fingerprint(named: name) else { continue }   // vanished mid-scan
                if fp.isDirectory { scan.publishedImportIDs.append(id.rawValue) }
                else { scan.suspiciousTerminal.append(name) }
            } catch { return .suspiciousMetadata("staging entry '\(name)': \(error)") }
        }
        scan.publishedImportIDs.sort()
        return .ok(scan)
    }

    enum SourceState { case available; case unavailable; case unstable(String) }

    /// The auto candidate's CURRENT state, derived from disk on every call (never cached):
    /// only a definitive ENOENT of the candidate database reads as unavailable; a regular
    /// file is available; anything else (non-regular type, metadata failure, unresolvable
    /// candidate paths) is unstable → retriable interference, never createFresh.
    static func sourceState(_ candidate: MigrationSource?) -> SourceState {
        guard let candidate else { return .unavailable }
        let dbURL: URL
        do { dbURL = try candidate.databaseURL() }
        catch { return .unstable("candidate database path: \(error)") }
        do {
            guard let fp = try FileFingerprint.capture(at: dbURL) else { return .unavailable }
            return fp.isRegularFile ? .available : .unstable("candidate database is not a regular file")
        } catch { return .unstable("candidate database metadata: \(error)") }
    }

    /// Candidate rows for `requiresImportSelection`. A gate failure KEEPS its
    /// classification (through the same exhaustive `map` the recovery path uses):
    /// retriable → `.unavailable`, terminal → `.invalid`; an unknown error fails closed
    /// as `.unavailable(.ioTransient)`, never as tampering. Rows are DISPLAY data only —
    /// `resolveSelectedImport` re-enumerates and re-gates from disk on every selection.
    func buildCandidates(_ importIDs: [String]) -> [RecoverableImport] {
        func row(_ raw: String, _ status: RecoverableImport.Status) -> RecoverableImport {
            RecoverableImport(importID: raw, status: status,
                              createdAt: nil, sourceKind: nil, ingestedCount: nil)
        }
        return importIDs.map { raw in
            guard let id = ImportID(raw) else { return row(raw, .invalid(.stagingTampered)) }
            guard let dir = stagingDirPure(for: id) else { return row(raw, .unavailable(.ioTransient)) }
            do {
                let gated = try StagedSnapshotGate().gate(stagingDir: dir)
                return RecoverableImport(importID: raw, status: .valid,
                                         createdAt: gated.manifest.createdAt,
                                         sourceKind: gated.manifest.sourceKind,
                                         ingestedCount: gated.manifest.ingestedCount)
            } catch let e as StagedSnapshotError {
                let block = Self.map(e)
                let status: RecoverableImport.Status
                switch block.classification {
                case .retriable: status = .unavailable(block.code)
                case .terminal: status = .invalid(block.code)
                }
                return row(raw, status)
            } catch {
                return row(raw, .unavailable(.ioTransient))
            }
        }
    }

    static func crossCheckField(_ gated: GatedStagedSnapshot, _ record: ActivationRecord) -> String? {
        if gated.importID.rawValue != record.importID { return "importID" }
        if gated.manifest.snapshotIdentitySHA256 != record.snapshotIdentitySHA256 { return "snapshotIdentitySHA256" }
        if gated.manifest.sourceDBSHA256 != record.sourceDBSHA256 { return "sourceDBSHA256" }
        if gated.manifest.walSHA256 != record.walSHA256 { return "walSHA256" }
        if gated.manifest.attachmentManifestSHA256 != record.attachmentManifestSHA256 { return "attachmentManifestSHA256" }
        return nil
    }

    // MARK: - Exhaustive upstream-error mapping (no default; description never parsed)

    static func map(_ e: IngestError, context: SourceContext) -> MigrationBlock {
        switch e {
        case .sourceDatabaseMissing:
            switch context {
            case .autoBoot: return .retriable(.interference, ["op": "ingest", "reason": "sourceDatabaseMissing"])
            case .explicitImport, .selectedRecovery: return .terminal(.invalidSource, ["reason": "sourceDatabaseMissing"])
            }
        case .sourceNotRegularFile:
            switch context {
            case .autoBoot: return .retriable(.interference, ["op": "ingest", "reason": "sourceNotRegularFile"])
            case .explicitImport, .selectedRecovery: return .terminal(.invalidSource, ["reason": "sourceNotRegularFile"])
            }
        case .attachmentsRootNotADirectory:
            switch context {
            case .autoBoot: return .retriable(.interference, ["op": "ingest", "reason": "attachmentsRootNotADirectory"])
            case .explicitImport, .selectedRecovery: return .terminal(.invalidSource, ["reason": "attachmentsRootNotADirectory"])
            }
        case .sourceBusy(let attempts):
            return .retriable(.sourceBusy, ["attempts": String(attempts)])
        case .importIDAlreadyExists:
            // Control flow (gate-existing), surfaced only if reached unexpectedly.
            return .retriable(.interference, ["op": "ingest", "reason": "importIDAlreadyExists"])
        case .stagedContentInconsistent:
            return .retriable(.ioTransient, ["op": "ingest", "reason": "stagedContentInconsistent"])
        case .cleanupFailed:
            return .retriable(.ioTransient, ["op": "ingest", "reason": "cleanupFailed"])
        }
    }

    static func map(_ e: StagedSnapshotError) -> MigrationBlock {
        switch e {
        case .stagingUnreadable(let m):
            return .retriable(.ioTransient, ["op": "gate", "detail": m])
        case .manifestUnreadable: return .terminal(.stagingTampered, ["reason": "manifestUnreadable"])
        case .unsupportedManifestFormat: return .terminal(.stagingTampered, ["reason": "unsupportedManifestFormat"])
        case .notIngested: return .terminal(.stagingTampered, ["reason": "notIngested"])
        case .nonCanonicalManifest: return .terminal(.stagingTampered, ["reason": "nonCanonicalManifest"])
        case .invalidImportID: return .terminal(.stagingTampered, ["reason": "invalidImportID"])
        case .importIDMismatch: return .terminal(.stagingTampered, ["reason": "importIDMismatch"])
        case .rootEntrySetMismatch: return .terminal(.stagingTampered, ["reason": "rootEntrySetMismatch"])
        case .attachmentTreeMismatch: return .terminal(.stagingTampered, ["reason": "attachmentTreeMismatch"])
        case .snapshotContentInconsistent: return .terminal(.stagingTampered, ["reason": "snapshotContentInconsistent"])
        case .attachmentManifestHashMismatch: return .terminal(.stagingTampered, ["reason": "attachmentManifestHashMismatch"])
        }
    }

    static func map(_ e: PreparedRunFailure) -> MigrationBlock {
        switch e {
        case .snapshotCopyFailed: return .retriable(.ioTransient, ["op": "runner", "reason": "snapshotCopyFailed"])
        case .unsupportedUserVersion(let v): return .terminal(.schemaUnsupported, ["userVersion": String(v)])
        case .integrityFailed: return .terminal(.sourceCorrupt, ["reason": "integrityFailed"])
        case .foreignKeyViolations: return .terminal(.sourceCorrupt, ["reason": "foreignKeyViolations"])
        case .migrationFailed: return .terminal(.migrationFailed, [:])
        case .schemaIncomplete: return .terminal(.schemaUnsupported, ["reason": "schemaIncomplete"])
        case .notQuiescent: return .retriable(.interference, ["op": "runner", "reason": "notQuiescent"])
        case .identityFailed: return .retriable(.ioTransient, ["op": "runner", "reason": "identityFailed"])
        case .publishFailed: return .retriable(.interference, ["op": "runner", "reason": "publishFailed"])
        case .preparedPublishConflict: return .terminal(.recordConflict, ["reason": "preparedPublishConflict"])
        case .workAreaSwapped: return .retriable(.interference, ["op": "runner", "reason": "workAreaSwapped"])
        }
    }

    /// Pure table — the adjudicable cases (`publishRaceLost` / `activationRecordConflict` /
    /// `activeSlotOccupied`) are intercepted by `runChain` BEFORE this mapping.
    static func map(_ e: ActivationError) -> MigrationBlock {
        switch e {
        case .invalidActiveDestination: return .terminal(.internalError, ["reason": "invalidActiveDestination"])
        case .activeParentUnreadable: return .retriable(.ioTransient, ["op": "activate", "reason": "activeParentUnreadable"])
        case .activeSlotOccupied: return .terminal(.importSlotOccupied, ["reason": "activeSlotOccupied"])
        case .activePublishFailed: return .retriable(.interference, ["op": "activate", "reason": "activePublishFailed"])
        case .activationRecordConflict: return .terminal(.recordConflict, ["reason": "activationRecordConflict"])
        case .activationRecordReadFailed: return .retriable(.ioTransient, ["op": "activate", "reason": "activationRecordReadFailed"])
        case .activationRecordMalformed: return .terminal(.recordMalformed, ["reason": "activationRecordMalformed"])
        case .recordPublishFailed: return .retriable(.interference, ["op": "activate", "reason": "recordPublishFailed"])
        case .recordWritebackMismatch: return .retriable(.interference, ["op": "activate", "reason": "recordWritebackMismatch"])
        case .recordNameSwapped: return .retriable(.interference, ["op": "activate", "reason": "recordNameSwapped"])
        case .recordPublishedMismatch: return .retriable(.interference, ["op": "activate", "reason": "recordPublishedMismatch"])
        case .recordUnboundDuringActivation: return .retriable(.interference, ["op": "activate", "reason": "recordUnboundDuringActivation"])
        case .candidateMaterializeFailed: return .retriable(.ioTransient, ["op": "activate", "reason": "candidateMaterializeFailed"])
        case .candidateRehashMismatch: return .retriable(.interference, ["op": "activate", "reason": "candidateRehashMismatch"])
        case .candidateNameSwapped: return .retriable(.interference, ["op": "activate", "reason": "candidateNameSwapped"])
        case .publishRaceLost: return .terminal(.recordConflict, ["reason": "publishRaceLost"])
        case .publishedActiveMismatch: return .retriable(.interference, ["op": "activate", "reason": "publishedActiveMismatch"])
        case .sidecarAppeared: return .retriable(.interference, ["op": "activate", "reason": "sidecarAppeared"])
        case .activeIdentityMismatch: return .terminal(.identityMismatch, ["reason": "activeIdentityMismatch"])
        case .durabilitySyncFailed: return .retriable(.ioTransient, ["op": "activate", "reason": "durabilitySyncFailed"])
        case .durabilityNotConfirmed: return .retriable(.ioTransient, ["op": "activate", "reason": "durabilityNotConfirmed"])
        }
    }

    static func map(_ e: FinalizeError) -> MigrationBlock {
        switch e {
        case .stagingUnbound: return .retriable(.interference, ["op": "finalize", "reason": "stagingUnbound"])
        case .activeEnvelopeViolated: return .retriable(.interference, ["op": "finalize", "reason": "activeEnvelopeViolated"])
        case .sentinelDurabilityFailed: return .retriable(.ioTransient, ["op": "finalize", "reason": "sentinelDurabilityFailed"])
        case .sentinelPublishIncomplete: return .retriable(.ioTransient, ["op": "finalize", "reason": "sentinelPublishIncomplete"])
        case .activeDatabaseBusy: return .retriable(.interference, ["op": "finalize", "reason": "activeDatabaseBusy"])
        case .transientIO: return .retriable(.ioTransient, ["op": "finalize", "reason": "transientIO"])
        case .referencedFileChangedSinceAudit: return .retriable(.interference, ["op": "finalize", "reason": "referencedFileChangedSinceAudit"])
        case .evidenceMismatch(let field): return .terminal(.identityMismatch, ["field": field])
        case .activeIdentityMismatch: return .terminal(.identityMismatch, ["reason": "activeIdentityMismatch"])
        case .attachmentConflict(let m): return .terminal(.attachmentConflict, ["detail": m])
        case .stagingTampered(let m): return .terminal(.stagingTampered, ["detail": m])
        case .sentinelConflict(let m): return .terminal(.sentinelConflict, ["detail": m])
        // Merged reason (wrongJournalMode / corrupt / schema) — mapped as ONE terminal
        // code; the payload is diagnostic only and is NEVER parsed to recover subtypes
        // (typed reasons are a future C12.x change to FinalizeError itself).
        case .activeDatabaseUnsupported: return .terminal(.activeDatabaseUnsupported, [:])
        }
    }
}
