import Foundation

// MARK: - 2B-3 C11b: finalize — bracketed apply → audit → complete over the activated DB
//
// Orchestrates the 2B-1 attachment machinery (AttachmentApply / AttachmentReferenceAuditor)
// against the ACTIVE database using the bound evidence C10 handed over (`ActivatedDatabase`)
// and the gate evidence the whole chain rides on (`GatedStagedSnapshot`). The 2B-1 steps are
// PATH-BASED (SQLite opens by path; FileManager copies by path) — this finalizer brackets
// every path-based step with point-in-time gates on the bound inodes (`ActiveSlotGates`,
// staging/attachments dir bindings) and injects the same gates as `prePublishGate` into
// C11a's sentinel publication, so every completion-validity check happens BEFORE the
// sentinel becomes durable. NEVER a full descriptor closure — the interiors of apply/audit/
// complete remain path-based (registered residual, C10's contract carried forward).
//
// Everything here is INTERNAL: no public API surface (the future C12 coordinator maps
// outcomes/errors to public types), and only Core can mint the input evidence
// (`ActivatedDatabase`, `GatedStagedSnapshot` inits are internal), so the App layer cannot
// call finalize with fabricated proof.
//
// STORE-OPEN CONTRACT (enforced by the C12 caller): only `.completed` /
// `.completedButCleanupFailed` (durable sentinel + every completion gate passed) permit
// opening LedgerStore. `.requiresAcknowledgement` persists nothing and keeps staging; every
// thrown error forbids opening the store.

// MARK: - Outcome / evidence

struct FinalizedImport {
    let importID: ImportID
    let preparedDBIdentity: String
    let applyResult: ApplyResult
}

enum FinalizeOutcome {
    /// Sentinel durable at its canonical path, every gate passed, staging cleaned.
    case completed(FinalizedImport)
    /// Completion is durable (both barriers succeeded before cleanup was attempted) but
    /// staging removal was blocked/failed — residue for a re-run or a future reaper. The
    /// store may open; cleanup is deferred, never forced.
    case completedButCleanupFailed(FinalizedImport, cleanupError: String)
    /// Unresolved items and no matching acknowledgement: NOTHING was persisted, staging is
    /// kept, the store must NOT open. Ack the request and re-run finalize.
    case requiresAcknowledgement(request: AcknowledgementRequest, unresolved: UnresolvedReport)
}

// MARK: - Errors (typed, exhaustively classified)

enum FinalizeStage: String, Equatable { case entry, apply, audit, complete, cleanup }

enum FinalizeErrorClass: Equatable { case retriable, terminal }

/// C11b's error vocabulary. Every upstream error is mapped through an EXHAUSTIVE switch
/// (no default) into one of these typed cases; `classification` is total. `retriable`
/// means fail-closed and safe to re-run finalize; `terminal` needs an operator / a future
/// replace-reset operation. `requiresAcknowledgement` and `completedButCleanupFailed` are
/// outcomes, not errors.
enum FinalizeError: Error, Equatable, CustomStringConvertible {
    // retriable
    case stagingUnbound(String)
    case activeEnvelopeViolated(stage: FinalizeStage, String)
    case sentinelDurabilityFailed(SentinelSyncPoint, String)
    case sentinelPublishIncomplete(String)
    case activeDatabaseBusy(String)
    case transientIO(stage: FinalizeStage, String)
    case referencedFileChangedSinceAudit(String)
    // terminal
    case evidenceMismatch(field: String)
    case activeIdentityMismatch(expected: String, actual: String)
    case attachmentConflict(String)
    case stagingTampered(String)
    case sentinelConflict(String)
    case activeDatabaseUnsupported(String)

    var classification: FinalizeErrorClass {
        switch self {
        case .stagingUnbound, .activeEnvelopeViolated, .sentinelDurabilityFailed,
             .sentinelPublishIncomplete, .activeDatabaseBusy, .transientIO,
             .referencedFileChangedSinceAudit:
            return .retriable
        case .evidenceMismatch, .activeIdentityMismatch, .attachmentConflict,
             .stagingTampered, .sentinelConflict, .activeDatabaseUnsupported:
            return .terminal
        }
    }

    var description: String {
        switch self {
        case .stagingUnbound(let m): return "Staging no longer resolves to the gate-bound root (retry): \(m)"
        case let .activeEnvelopeViolated(stage, m): return "Active-slot envelope violated at stage \(stage.rawValue) (retry): \(m)"
        case let .sentinelDurabilityFailed(p, m): return "Sentinel durability barrier failed at \(p.rawValue) (retry — staging kept): \(m)"
        case .sentinelPublishIncomplete(let m): return "Sentinel publication did not complete (retry): \(m)"
        case .activeDatabaseBusy(let m): return "Active database is busy / changed underneath (retry after it settles): \(m)"
        case let .transientIO(stage, m): return "Transient I/O failure at stage \(stage.rawValue) (retry): \(m)"
        case .referencedFileChangedSinceAudit(let n): return "Referenced attachment '\(n)' changed after the audit (retry — re-audits): \(n)"
        case .evidenceMismatch(let f): return "Finalize evidence mismatch (\(f)) — terminal, do not open the store"
        case let .activeIdentityMismatch(e, a): return "Active database identity \(a) does not match the activation evidence \(e) — terminal, do not open the store"
        case .attachmentConflict(let m): return "Attachment conflict (never overwritten) — needs operator resolution: \(m)"
        case .stagingTampered(let m): return "Staging content does not match its gated manifest — re-ingest required: \(m)"
        case .sentinelConflict(let m): return "A foreign completion sentinel occupies this import's slot — terminal: \(m)"
        case .activeDatabaseUnsupported(let m): return "Active database is unsupported/corrupt or was opened before completion — terminal: \(m)"
        }
    }

    // MARK: upstream mapping (exhaustive, no default)

    static func map(_ error: Error, stage: FinalizeStage) -> FinalizeError {
        if let f = error as? FinalizeError { return f }
        if let a = error as? AttachmentApplyError { return map(a, stage: stage) }
        if let p = error as? PreparedDatabaseError { return map(p, stage: stage) }
        return .transientIO(stage: stage, "\(error)")
    }

    static func map(_ e: AttachmentApplyError, stage: FinalizeStage) -> FinalizeError {
        switch e {
        case .manifestUnreadable(let m): return .stagingTampered("manifest unreadable: \(m)")
        case .invalidImportID(let m): return .stagingTampered("invalid importID: \(m)")
        case .invalidAttachmentName(let m): return .stagingTampered("invalid attachment name: \(m)")
        case .attachmentPathEscape(let m): return .stagingTampered("attachment path escape: \(m)")
        case .duplicateAttachmentName(let m): return .stagingTampered("duplicate attachment name: \(m)")
        case .attachmentManifestHashMismatch: return .stagingTampered("attachment manifest hash mismatch")
        case .stagedFileHashMismatch(let n): return .stagingTampered("staged file hash mismatch: \(n)")
        case .stagedEntryNotRegularFile(let n): return .stagingTampered("staged entry not a regular file: \(n)")
        case .unsupportedManifestFormat(let v): return .stagingTampered("unsupported manifest formatVersion \(v.map(String.init) ?? "nil")")
        case .conflicts(let c): return .attachmentConflict(c.map { $0.name }.joined(separator: ", "))
        case .conflictDuringApply(let n): return .attachmentConflict(n)
        case .activeEntryNotRegularFile(let n): return .attachmentConflict("active entry not a regular file: \(n)")
        // Applied/pre-existing attachment bytes no longer match the manifest — an operator
        // must decide; NEVER retriable (re-running would keep failing or paper over it).
        case .activeFileHashMismatch(let n): return .attachmentConflict("active attachment content mismatch: \(n)")
        case .referencedFileChangedSinceAudit(let n): return .referencedFileChangedSinceAudit(n)
        case .sentinelIdentityMismatch(let id): return .sentinelConflict(id)
        case let .sentinelDurabilityFailed(p, m): return .sentinelDurabilityFailed(p, m)
        case .sentinelPublishIncomplete(let m): return .sentinelPublishIncomplete(m)
        case .referenceAuditMismatch(let f): return .evidenceMismatch(field: "referenceAudit.\(f)")
        case let .preparedDatabaseIdentityMismatch(expected, actual): return .activeIdentityMismatch(expected: expected, actual: actual)
        case .preparedDatabaseCorrupt(let m): return .activeDatabaseUnsupported("corrupt: \(m)")
        case .preparedDatabaseSchemaUnsupported(let m): return .activeDatabaseUnsupported("schema: \(m)")
        case let .preparedDatabaseChangedDuringAudit(before, after): return .activeDatabaseBusy("changed during audit: \(before) -> \(after)")
        }
    }

    static func map(_ e: PreparedDatabaseError, stage: FinalizeStage) -> FinalizeError {
        switch e {
        case .databaseMissing(let m): return .activeEnvelopeViolated(stage: stage, "active database missing at its path: \(m)")
        case .databaseNotRegularFile(let m): return .activeEnvelopeViolated(stage: stage, "active database path is not a regular file: \(m)")
        case .notQuiescent(let s): return .activeDatabaseBusy("sidecar present: \(s)")
        case .wrongJournalMode(let m): return .activeDatabaseUnsupported("journal_mode '\(m)' — the store was opened before completion")
        case .unreadable(let m): return .transientIO(stage: stage, m)
        }
    }
}

// MARK: - Hooks (test-only fault seams)

struct FinalizeHooks {
    var afterEntryGate: (() throws -> Void)?
    var afterApply: (() throws -> Void)?
    var afterAudit: (() throws -> Void)?
    var apply: ApplyHooks
    var audit: AttachmentReferenceAuditor.AuditHooks
    init(afterEntryGate: (() throws -> Void)? = nil,
         afterApply: (() throws -> Void)? = nil,
         afterAudit: (() throws -> Void)? = nil,
         apply: ApplyHooks = ApplyHooks(),
         audit: AttachmentReferenceAuditor.AuditHooks = .init()) {
        self.afterEntryGate = afterEntryGate
        self.afterApply = afterApply
        self.afterAudit = afterAudit
        self.apply = apply
        self.audit = audit
    }
}

// MARK: - The finalizer

struct PreparedImportFinalizer {
    init() {}

    /// Finalize the activated import: bracketed apply → audit → complete. See the file
    /// header for the contract. `manifestsDir` defaults to the app's ImportManifests store;
    /// tests inject their own. The `ActivatedDatabase` value must stay alive for the whole
    /// call (its bound fds ARE the evidence; NOT Sendable — same concurrency domain as
    /// activation).
    func finalize(_ activated: ActivatedDatabase, gated: GatedStagedSnapshot,
                  activeAttachmentsDir: URL, acknowledgement: Acknowledgement? = nil,
                  manifestsDir: URL? = nil,
                  hooks: FinalizeHooks = FinalizeHooks()) throws -> FinalizeOutcome {
        let manifests: URL
        do { manifests = try manifestsDir ?? AppPaths.importManifestsDirectory() }
        catch { throw FinalizeError.transientIO(stage: .entry, "manifests dir resolution: \(error)") }
        let activeName = AppPaths.databaseFileName

        // ---- E0: evidence cross-verification (all terminal on mismatch) ----
        guard gated.importID.rawValue == activated.importID.rawValue else {
            throw FinalizeError.evidenceMismatch(field: "importID")
        }
        // Decode the owner record through the BOUND fd (never by name/path).
        let record: ActivationRecord
        do { record = try activated.boundOwnerRecord.decode(ActivationRecord.self) }
        catch { throw FinalizeError.activeEnvelopeViolated(stage: .entry, "owner record undecodable via the bound fd: \(error)") }
        guard record.formatVersion == ActivationRecord.currentFormatVersion else {
            throw FinalizeError.evidenceMismatch(field: "record.formatVersion")
        }
        guard record.importID == activated.importID.rawValue else { throw FinalizeError.evidenceMismatch(field: "record.importID") }
        guard record.preparedDBIdentity == activated.preparedDBIdentity else { throw FinalizeError.evidenceMismatch(field: "record.preparedDBIdentity") }
        guard record.snapshotIdentitySHA256 == gated.manifest.snapshotIdentitySHA256 else { throw FinalizeError.evidenceMismatch(field: "record.snapshotIdentitySHA256") }
        guard record.sourceDBSHA256 == gated.manifest.sourceDBSHA256 else { throw FinalizeError.evidenceMismatch(field: "record.sourceDBSHA256") }
        guard record.walSHA256 == gated.manifest.walSHA256 else { throw FinalizeError.evidenceMismatch(field: "record.walSHA256") }
        guard record.attachmentManifestSHA256 == gated.manifest.attachmentManifestSHA256 else { throw FinalizeError.evidenceMismatch(field: "record.attachmentManifestSHA256") }
        guard record.transactionsMigrated == activated.transactionsMigrated else { throw FinalizeError.evidenceMismatch(field: "record.transactionsMigrated") }
        guard activated.preparedDBIdentity.hasPrefix("sha256:") else {
            throw FinalizeError.evidenceMismatch(field: "preparedDBIdentity format")
        }
        let identityHex = String(activated.preparedDBIdentity.dropFirst("sha256:".count))

        // ---- Entry active envelope: BRACKETS the probe short-circuit ----
        // The finalizer must never declare (or act on) completion while the active slot
        // itself is violated: the active name must still resolve to the bound activeFile,
        // no sidecar may exist, and the owner-record name must still resolve to the bound
        // record with a full-field decode match. Checked BEFORE the probe AND again after
        // a completed/cleanupPending probe return (the probe's barrier-replay seams run
        // arbitrary code) — before any cleanup or outcome. A violated slot fails closed:
        // no probe result is acted on, no cleanup, no completed. (This constrains the
        // FINALIZER only; the C12 WAL-safe boot path uses `probeCompletion` directly and
        // never re-derives DB identity.)
        func entryEnvelope() throws {
            do {
                try ActiveSlotGates.assertEnvelope(active: activated.activeFile, activeName: activeName,
                                                   ownerRecord: activated.boundOwnerRecord, expected: record,
                                                   in: activated.activeParent)
            } catch { throw FinalizeError.activeEnvelopeViolated(stage: .entry, "\(error)") }
        }
        try entryEnvelope()

        // ---- Probe short-circuit (state S3/S3c): completion may ALREADY be durable ----
        // A crash after the sentinel published (e.g. before the dir barrier or during
        // cleanup) resumes here. Re-running apply would legitimately change the applied
        // summary (copied → skippedIdentical), so convergence is NEVER re-derived by
        // re-completion: the validated canonical sentinel IS the completion fact. The probe
        // re-validates every invariant against the owner record and replays both barriers;
        // only the staging residue is then retried — through the gate-bound root, never a
        // URL. An invalid/foreign sentinel is a terminal conflict before anything runs.
        let probeOutcome: CompletionProbe
        do {
            probeOutcome = try Self.probeCompletion(expected: record, importID: activated.importID,
                                                    manifestsDir: manifests, stagingDir: gated.stagingDir,
                                                    hooks: hooks.apply)
        } catch { throw FinalizeError.map(error, stage: .entry) }
        switch probeOutcome {
        case .conflict(let why):
            throw FinalizeError.sentinelConflict(why)
        case .completed(let validated):
            try entryEnvelope()   // exit bracket — before the outcome is declared
            return .completed(Self.shortCircuitResult(activated: activated, validated: validated,
                                                      stagingCleaned: true, cleanupError: nil))
        case .cleanupPending(let validated):
            try entryEnvelope()   // exit bracket — before ANY cleanup
            let cleanupError = Self.cleanupResidue(gated: gated)
            let finalized = Self.shortCircuitResult(activated: activated, validated: validated,
                                                    stagingCleaned: cleanupError == nil,
                                                    cleanupError: cleanupError)
            if let cleanupError { return .completedButCleanupFailed(finalized, cleanupError: cleanupError) }
            return .completed(finalized)
        case .pending:
            break   // no completion on disk — run the full chain below
        }

        // Bind the active attachments dir (ensure-exists first: apply would create it
        // anyway; binding needs it present). Interior operations stay path-based within it
        // — the binding is a stage-boundary bracket, not a descriptor closure.
        do { try FileManager.default.createDirectory(at: activeAttachmentsDir, withIntermediateDirectories: true) }
        catch { throw FinalizeError.transientIO(stage: .entry, "active attachments dir create: \(error)") }
        let attachmentsHandle: DirectoryHandle
        do { attachmentsHandle = try DirectoryHandle.open(at: activeAttachmentsDir) }
        catch { throw FinalizeError.transientIO(stage: .entry, "active attachments dir bind: \(error)") }

        func envelope(_ stage: FinalizeStage) throws {
            do {
                try ActiveSlotGates.assertEnvelope(active: activated.activeFile, activeName: activeName,
                                                   ownerRecord: activated.boundOwnerRecord, expected: record,
                                                   in: activated.activeParent)
            } catch { throw FinalizeError.activeEnvelopeViolated(stage: stage, "\(error)") }
        }
        func stagingBound(_ stage: FinalizeStage) throws {
            guard let fp = try? FileFingerprint.capture(at: gated.stagingDir), fp.isDirectory,
                  fp.device == gated.root.device, fp.inode == gated.root.inode else {
                throw FinalizeError.stagingUnbound("stage \(stage.rawValue): staging path no longer resolves to the gate-bound root")
            }
        }
        func attachmentsBound(_ stage: FinalizeStage) throws {
            guard let fp = try? FileFingerprint.capture(at: activeAttachmentsDir), fp.isDirectory,
                  fp.device == attachmentsHandle.device, fp.inode == attachmentsHandle.inode else {
                throw FinalizeError.activeEnvelopeViolated(stage: stage, "active attachments dir no longer resolves to the bound directory")
            }
        }

        try envelope(.entry)
        try stagingBound(.entry)
        try attachmentsBound(.entry)
        do { try hooks.afterEntryGate?() } catch { throw FinalizeError.map(error, stage: .entry) }

        // ---- APPLY (path-based; bracketed) ----
        try envelope(.apply)
        try stagingBound(.apply)
        try attachmentsBound(.apply)
        let report: AttachmentApplyReport
        do {
            report = try AttachmentApply().apply(stagingDir: gated.stagingDir,
                                                 activeAttachmentsDir: activeAttachmentsDir,
                                                 preparedDBIdentity: activated.preparedDBIdentity,
                                                 hooks: hooks.apply)
        } catch { throw FinalizeError.map(error, stage: .apply) }
        // The manifest apply just re-read from the PATH must be the very manifest the gate
        // verified against disk — a mid-apply staging swap that survived the fingerprint
        // brackets cannot smuggle a different (self-consistent) manifest into the chain.
        guard report.importID.rawValue == gated.importID.rawValue else { throw FinalizeError.evidenceMismatch(field: "report.importID") }
        guard report.manifest == gated.manifest else { throw FinalizeError.evidenceMismatch(field: "report.manifest") }
        try stagingBound(.apply)
        try attachmentsBound(.apply)
        try envelope(.apply)
        do { try hooks.afterApply?() } catch { throw FinalizeError.map(error, stage: .apply) }

        // ---- AUDIT (path-based; bracketed; identity recomputed inside before AND after) ----
        try envelope(.audit)
        try attachmentsBound(.audit)
        let audit: ReferenceAudit
        do {
            audit = try AttachmentReferenceAuditor().audit(report: report,
                                                           preparedDatabaseAt: activated.activeDatabaseURL,
                                                           hooks: hooks.audit)
        } catch { throw FinalizeError.map(error, stage: .audit) }
        try envelope(.audit)
        try attachmentsBound(.audit)
        do { try hooks.afterAudit?() } catch { throw FinalizeError.map(error, stage: .audit) }

        // ---- COMPLETE (C11a machinery; validity gates injected BEFORE the sentinel) ----
        try envelope(.complete)
        // The gate C11a runs TWICE — before the manifests dir is touched and again
        // immediately before the exclusive rename. Full strength both times: envelope
        // (active name → bound inode, no sidecars, owner-record full-field re-check) +
        // bound re-hash against the activation identity + attachments-dir binding.
        // Staging is deliberately NOT re-checked here: post-apply, completion validity no
        // longer depends on staging content (the report was cross-verified against the
        // gated manifest), and staging safety is owned end-to-end by `trustedStagingRoot`
        // — a swapped tree is refused by the pre-bound cleanup, never entered or deleted.
        let prePublishGate: () throws -> Void = {
            try envelope(.complete)
            let hash: String
            do { hash = try activated.activeFile.rehashSHA256() }
            catch { throw FinalizeError.transientIO(stage: .complete, "active bound re-hash: \(error)") }
            guard hash == identityHex else {
                throw FinalizeError.activeIdentityMismatch(expected: activated.preparedDBIdentity, actual: "sha256:" + hash)
            }
            try attachmentsBound(.complete)
        }
        let outcome: CompleteOutcome
        do {
            outcome = try AttachmentApply().complete(report: report, referenceAudit: audit,
                                                     acknowledgement: acknowledgement,
                                                     preparedDatabaseAt: activated.activeDatabaseURL,
                                                     manifestsDir: manifests,
                                                     prePublishGate: prePublishGate,
                                                     trustedStagingRoot: gated.root,
                                                     hooks: hooks.apply)
        } catch { throw FinalizeError.map(error, stage: .complete) }

        switch outcome {
        case .requiresAcknowledgement(let request, let unresolved):
            return .requiresAcknowledgement(request: request, unresolved: unresolved)
        case .completed(let result):
            let finalized = FinalizedImport(importID: activated.importID,
                                            preparedDBIdentity: activated.preparedDBIdentity,
                                            applyResult: result)
            if result.stagingCleaned { return .completed(finalized) }
            return .completedButCleanupFailed(finalized, cleanupError: result.stagingCleanupError ?? "unknown cleanup failure")
        }
    }

    // MARK: - Completion probe (read-only + barrier replay; for the C12 boot)

    /// The probe's carrier: the sentinel manifest as FINALLY re-verified through the bound
    /// fd AFTER both barrier replays. Consumers (short-circuit results, C12 boot) must use
    /// THIS manifest — never a fresh URL read of the sentinel.
    struct ValidatedCompletion: Equatable {
        let sentinelURL: URL
        let manifest: ImportManifest
    }

    enum CompletionProbe: Equatable {
        /// A canonical, fully valid, durable (barriers replayed + content re-verified)
        /// completion sentinel.
        case completed(ValidatedCompletion)
        /// Completed AND staging residue exists at the canonical staging path — or its
        /// absence could NOT be proven (a non-ENOENT metadata error fails closed here,
        /// never as "cleaned"). The probe NEVER cleans it — that needs a re-gated
        /// `GatedStagedSnapshot.root` (descriptor-rooted cleanup) or a future reaper.
        case cleanupPending(ValidatedCompletion)
        /// No sentinel at the canonical path — finalize has not completed; resume the chain.
        case pending
        /// A foreign/invalid/tampered object occupies the sentinel slot — terminal.
        case conflict(String)
    }

    /// Disk-derived completion probe. Binds the ImportManifests parent, the dir and the
    /// sentinel file (no-follow, regular-file-only, 8 MiB cap), verifies canonical
    /// directory linkage, validates EVERY completed-sentinel invariant against the owner
    /// record, then replays both best-effort durability barriers. It NEVER touches the
    /// active database (no identity/quiescence computation — a completed import's DB may
    /// already be WAL), never cleans staging, and never consults in-memory state: the
    /// answer derives from disk alone. `stagingDir` (optional) is only lstat-probed to
    /// distinguish `.completed` from `.cleanupPending`.
    static func probeCompletion(expected record: ActivationRecord, importID: ImportID,
                                manifestsDir: URL, stagingDir: URL? = nil,
                                hooks: ApplyHooks = ApplyHooks()) throws -> CompletionProbe {
        let dirName = manifestsDir.lastPathComponent
        let sentinelName = "\(importID.rawValue).json"
        let finalURL = manifestsDir.appendingPathComponent(sentinelName)

        let parent: DirectoryHandle
        do { parent = try DirectoryHandle.open(at: manifestsDir.deletingLastPathComponent()) }
        catch let e as FileHashError where e.isFileMissing { return .pending }
        catch { throw FinalizeError.transientIO(stage: .complete, "manifests parent bind: \(error)") }
        let dir: DirectoryHandle
        do { dir = try DirectoryHandle.open(at: manifestsDir) }
        catch let e as FileHashError where e.isFileMissing { return .pending }
        catch { throw FinalizeError.transientIO(stage: .complete, "manifests dir bind: \(error)") }
        guard let dfp = try? parent.fingerprint(named: dirName), dfp.isDirectory,
              dfp.device == dir.device, dfp.inode == dir.inode else {
            throw FinalizeError.transientIO(stage: .complete, "manifests dir not canonically linked")
        }

        let fp: FileFingerprint?
        do { fp = try dir.fingerprint(named: sentinelName) }
        catch { throw FinalizeError.transientIO(stage: .complete, "sentinel fingerprint: \(error)") }
        guard let fp else { return .pending }
        guard fp.isRegularFile else { return .conflict("sentinel entry is not a regular file") }

        let sentinel: BoundRegularFile
        do { sentinel = try BoundRegularFile.open(in: dir, named: sentinelName) }
        catch let e as FileHashError {
            if case .notARegularFile = e { return .conflict("sentinel entry is not a regular file") }
            throw FinalizeError.transientIO(stage: .complete, "sentinel open: \(e)")
        }
        catch { throw FinalizeError.transientIO(stage: .complete, "sentinel open: \(error)") }

        let manifest: ImportManifest
        do {
            let data = try sentinel.readAll(maxBytes: AttachmentApply.maxSentinelBytes)
            manifest = try JSONDecoder().decode(ImportManifest.self, from: data)
        } catch { return .conflict("sentinel unreadable/undecodable within the size cap: \(error)") }

        if let violation = validateCompletedSentinel(manifest, record: record, importID: importID) {
            return .conflict("sentinel invariant violated: \(violation)")
        }

        // Replay both best-effort durability barriers (repair after a crash between the
        // rename and the directory barrier). AFTER EACH barrier the sentinel's CONTENT is
        // fully re-verified through the SAME bound fd — re-read (size-capped), re-decoded,
        // re-validated, and compared semantically against the pre-barrier manifest.
        // matchesChild/dev+inode alone cannot prove the bytes are unchanged (the seam, or
        // anyone, can rewrite the SAME inode in place).
        func replay(_ point: SentinelSyncPoint, _ body: () throws -> Void) throws {
            do { try hooks.onSentinelSync?(point); try body() }
            catch { throw FinalizeError.sentinelDurabilityFailed(point, "\(error)") }
        }
        // Returns the re-verified manifest, a `.conflict` to surface, or throws retriable.
        enum Reverified { case ok(ImportManifest); case conflict(CompletionProbe) }
        func reverify(_ what: String) throws -> Reverified {
            guard (try? sentinel.matchesChild(named: sentinelName, in: dir)) == true else {
                throw FinalizeError.sentinelPublishIncomplete("sentinel name unbound \(what)")
            }
            let data: Data
            do { data = try sentinel.readAll(maxBytes: AttachmentApply.maxSentinelBytes) }
            catch { return .conflict(.conflict("sentinel unreadable within the size cap \(what): \(error)")) }
            guard let m = try? JSONDecoder().decode(ImportManifest.self, from: data) else {
                return .conflict(.conflict("sentinel undecodable \(what)"))
            }
            if let violation = validateCompletedSentinel(m, record: record, importID: importID) {
                return .conflict(.conflict("sentinel invariant violated \(what): \(violation)"))
            }
            guard m == manifest else {
                return .conflict(.conflict("sentinel content changed \(what) (semantic mismatch with the validated manifest)"))
            }
            return .ok(m)
        }

        try replay(.sentinelFile) { try sentinel.syncToDisk() }
        switch try reverify("after the file barrier replay") {
        case .conflict(let probe): return probe
        case .ok: break
        }

        try replay(.sentinelDirEntry) { try fsyncDirectoryEntry(dir, pathHint: manifestsDir.path) }
        let final: ImportManifest
        switch try reverify("after the directory barrier replay") {
        case .conflict(let probe): return probe
        case .ok(let m): final = m
        }
        guard let dfp2 = try? parent.fingerprint(named: dirName), dfp2.isDirectory,
              dfp2.device == dir.device, dfp2.inode == dir.inode else {
            throw FinalizeError.sentinelPublishIncomplete("manifests dir no longer canonically linked after the barrier replay")
        }

        let validated = ValidatedCompletion(sentinelURL: finalURL, manifest: final)
        if let stagingDir {
            // ONLY a definitive ENOENT proves the staging residue absent; any other
            // metadata failure fails closed as cleanup-pending, never as "cleaned".
            let fp: FileFingerprint?
            do { fp = try FileFingerprint.capture(at: stagingDir) }
            catch { return .cleanupPending(validated) }
            if fp != nil { return .cleanupPending(validated) }
        }
        return .completed(validated)
    }

    /// Build the short-circuit `FinalizedImport` STRICTLY from the probe's
    /// `ValidatedCompletion` — the manifest as finally re-verified through the bound fd
    /// after both barrier replays. A PURE function over its inputs: it never touches the
    /// filesystem, and in particular never re-opens the sentinel by URL (a fresh path read
    /// would trust whatever sits at the name at consumption time). Internal so the purity
    /// contract is directly unit-tested against an unreadable/foreign `sentinelURL`.
    static func shortCircuitResult(activated: ActivatedDatabase, validated: ValidatedCompletion,
                                   stagingCleaned: Bool, cleanupError: String?) -> FinalizedImport {
        let m = validated.manifest
        let result = ApplyResult(importID: activated.importID.rawValue,
                                 applied: m.applied ?? .init(copied: [], skippedIdentical: [], missing: []),
                                 unresolved: m.unresolved ?? UnresolvedReport(items: []),
                                 completionSentinelURL: validated.sentinelURL,
                                 stagingCleaned: stagingCleaned, stagingCleanupError: cleanupError)
        return FinalizedImport(importID: activated.importID,
                               preparedDBIdentity: activated.preparedDBIdentity,
                               applyResult: result)
    }

    /// S3c residue cleanup: completion is already durable (probe-validated) but staging
    /// remains. Applies the SAME known-tree, descriptor-rooted removal contract as
    /// `AttachmentApply`'s private cleanup, over handles bound from the GATE evidence
    /// (`trustedRoot: gated.root`) — never a URL re-bind; unknown/replaced/non-empty
    /// entries stay untouched as residue. Returns nil on success, else the surfaced
    /// reason. Internal: the C12 coordinator converges boot-time cleanup residue through
    /// this same contract (re-gated evidence only). REGISTERED FOLLOW-UP: dedup with
    /// AttachmentApply's private twin in a commit that may touch that file.
    static func cleanupResidue(gated: GatedStagedSnapshot) -> String? {
        let h: AttachmentApply.StagingCleanupHandles
        switch AttachmentApply.bindStagingForCleanup(stagingDir: gated.stagingDir, trustedRoot: gated.root) {
        case .absent: return nil
        case .blocked(let why): return why
        case .bound(let handles): h = handles
        }
        do {
            guard let fp = try h.parent.fingerprint(named: h.entryName), fp.isDirectory,
                  fp.device == h.root.device, fp.inode == h.root.inode else {
                return "staging entry '\(h.entryName)' no longer resolves to the bound directory — nothing deleted"
            }
            if let docs = h.docs {
                for f in gated.manifest.files where f.outcome == .ingested {
                    try docs.removeNonDirectoryChild(named: f.name)
                }
                guard let attachments = h.attachments else { return "internal: docs handle without attachments handle" }
                if let e = removeBoundEmptyDir(docs, named: "docs", in: attachments) { return e }
            }
            if let attachments = h.attachments {
                if let e = removeBoundEmptyDir(attachments, named: "attachments", in: h.root) { return e }
            }
            try h.root.removeNonDirectoryChild(named: "manifest.json")
            try h.root.removeNonDirectoryChild(named: AppPaths.databaseFileName)
            try h.root.removeNonDirectoryChild(named: AppPaths.databaseFileName + "-wal")
            if let e = removeBoundEmptyDir(h.root, named: h.entryName, in: h.parent) { return e }
            return nil
        } catch { return "\(error)" }
    }

    /// Same contract as `AttachmentApply`'s private twin: remove a directory ENTRY only
    /// while it still resolves (dir type, device+inode) to the bound handle; AT_REMOVEDIR
    /// refuses non-empty dirs; a replaced entry is left untouched. Returns nil on success.
    private static func removeBoundEmptyDir(_ child: DirectoryHandle, named name: String,
                                            in parent: DirectoryHandle) -> String? {
        guard let fp = try? parent.fingerprint(named: name), fp.isDirectory,
              fp.device == child.device, fp.inode == child.inode else {
            return "'\(name)' no longer resolves to the bound directory — left untouched"
        }
        guard unlinkat(parent.fd, name, AT_REMOVEDIR) == 0 else {
            let e = errno
            if e == ENOENT { return nil }
            return "rmdir '\(name)' failed (errno \(e)) — left for a reaper"
        }
        return nil
    }

    /// The COMPLETE invariant set a `.complete` sentinel must satisfy (13 checks — never
    /// just the identity fields). Returns nil when valid, else the violated invariant.
    static func validateCompletedSentinel(_ m: ImportManifest, record: ActivationRecord,
                                          importID: ImportID) -> String? {
        // ① explicit current format
        guard m.formatVersion == ImportManifest.currentFormatVersion else { return "formatVersion" }
        // ② completed status
        guard m.status == .complete else { return "status" }
        // ③ the reference audit actually ran
        guard m.referenceAuditPerformed == true else { return "referenceAuditPerformed" }
        // ④ attachment-set hash self-consistency (covers ingested AND skipped entries)
        guard ImportManifest.attachmentSetHash(m.files) == m.attachmentManifestSHA256 else { return "attachmentSetHash(files)" }
        // ⑤ snapshot identity self-consistency (db + wal recombine)
        guard ImportManifest.snapshotIdentity(dbSHA: m.sourceDBSHA256, walSHA: m.walSHA256) == m.snapshotIdentitySHA256 else { return "snapshotIdentity(db,wal)" }
        // ⑥ prepared-DB identity present and matching the owner record
        guard let prep = m.preparedDBIdentity, prep == record.preparedDBIdentity else { return "preparedDBIdentity" }
        // ⑦ importID: sentinel ↔ owner record ↔ (validated) expected id — three-way
        guard m.importID == importID.rawValue, m.importID == record.importID, ImportID(m.importID) != nil else { return "importID" }
        // ⑧ every identity field matches the owner record
        guard m.sourceDBSHA256 == record.sourceDBSHA256 else { return "sourceDBSHA256" }
        guard m.walSHA256 == record.walSHA256 else { return "walSHA256" }
        guard m.snapshotIdentitySHA256 == record.snapshotIdentitySHA256 else { return "snapshotIdentitySHA256" }
        guard m.attachmentManifestSHA256 == record.attachmentManifestSHA256 else { return "attachmentManifestSHA256" }
        // ⑨ acknowledgement binding: non-empty unresolved ⇔ ack hash == its reportHash
        let unresolved = m.unresolved ?? UnresolvedReport(items: [])
        if unresolved.isEmpty {
            guard m.acknowledgedReportHash == nil else { return "acknowledgedReportHash (must be nil)" }
        } else {
            guard m.acknowledgedReportHash == unresolved.reportHash else { return "acknowledgedReportHash" }
        }
        // ⑩ completed manifests carry the applied summary and the human report
        guard let applied = m.applied else { return "applied (missing)" }
        guard m.report != nil else { return "report (missing)" }
        // ⑭ uniqueness: the set-based checks below must never be reachable through
        // duplicate entries silently collapsed by Set construction.
        guard m.files.count == Set(m.files.map { $0.name }).count else { return "files (duplicate name)" }
        guard applied.copied.count == Set(applied.copied).count else { return "applied.copied (duplicates)" }
        guard applied.skippedIdentical.count == Set(applied.skippedIdentical).count else { return "applied.skippedIdentical (duplicates)" }
        guard applied.missing.count == Set(applied.missing).count else { return "applied.missing (duplicates)" }
        let missingNames = unresolved.items.filter { $0.kind == .missingStagedFile }.map { $0.name }
        guard missingNames.count == Set(missingNames).count else { return "unresolved (duplicate missingStagedFile items)" }
        // ⑪ applied is an exact partition of the ingested set (disjoint, covering, hashed)
        let ingested = Set(m.files.filter { $0.outcome == .ingested }.map { $0.name })
        let copied = Set(applied.copied), skipped = Set(applied.skippedIdentical), missing = Set(applied.missing)
        guard copied.isDisjoint(with: skipped), copied.isDisjoint(with: missing), skipped.isDisjoint(with: missing) else { return "applied (overlapping sets)" }
        guard copied.union(skipped).union(missing) == ingested else { return "applied (not a partition of the ingested set)" }
        guard m.files.allSatisfy({ $0.outcome != .ingested || $0.sha256 != nil }) else { return "files (ingested entry without sha256)" }
        // ⑫ unresolved ↔ files consistency: missing set matches, every skipped entry itemized
        let missingItems = Set(missingNames)
        guard missingItems == missing else { return "unresolved (missingStagedFile set mismatch)" }
        for f in m.files where f.outcome != .ingested {
            let kind: UnresolvedReport.Item.Kind
            switch f.outcome {
            case .skippedSymlink: kind = .skippedSymlink
            case .skippedDirectory: kind = .skippedDirectory
            case .skippedSpecial: kind = .skippedSpecial
            case .rejectedName: kind = .rejectedName
            case .ingested: continue
            }
            guard unresolved.items.contains(where: { $0.name == f.name && $0.kind == kind }) else {
                return "unresolved (skipped entry '\(f.name)' not itemized)"
            }
        }
        // ⑬ the size cap is enforced by the bound read feeding this validator (probe side).
        return nil
    }
}
