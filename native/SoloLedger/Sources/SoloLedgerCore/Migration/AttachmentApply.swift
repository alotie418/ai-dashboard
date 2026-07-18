import Foundation
import CryptoKit

// MARK: - Unresolved report

/// A structured record of everything that could not be cleanly migrated: files missing from
/// staging, ingest-stage skips (symlink/dir/special/illegal name), and — supplied later by
/// the coordinator's DB reference audit — ledger references that resolve to no file. A
/// non-empty report BLOCKS auto-completion: the import may only be marked `.complete` after
/// an explicit user acknowledgement BOUND to `reportHash`.
public struct UnresolvedReport: Codable, Equatable {
    public struct Item: Codable, Equatable {
        public enum Kind: String, Codable {
            case missingStagedFile
            case skippedSymlink, skippedDirectory, skippedSpecial, rejectedName
            case danglingReference
            /// A stored DB reference that is not a well-formed `attachments/docs/<name>`
            /// value at all (wrong prefix, traversal, absolute path, non-TEXT column value).
            /// Introduced with manifest formatVersion 2.
            case invalidReference
        }
        public var name: String
        public var kind: Kind
        public var detail: String?
        public init(name: String, kind: Kind, detail: String? = nil) {
            self.name = name; self.kind = kind; self.detail = detail
        }
    }
    public var items: [Item]
    public init(items: [Item]) {
        // Total order incl. nil-vs-present detail (nil sorts before present) so the hash is
        // deterministic even when two items differ only by absent-vs-empty detail.
        self.items = items.sorted {
            ($0.kind.rawValue, $0.name, $0.detail == nil ? 0 : 1, $0.detail ?? "")
                < ($1.kind.rawValue, $1.name, $1.detail == nil ? 0 : 1, $1.detail ?? "")
        }
    }
    public var isEmpty: Bool { items.isEmpty }
    /// Canonical, order-stable, INJECTIVE hash over (kind, name, detail) for every item.
    /// Each field is length-prefixed (UTF-8 byte count) and the item count is prefixed, so the
    /// encoding is self-delimiting — no attacker-influenceable name/detail (e.g. a rejectedName
    /// carrying raw source-filename bytes) can smuggle a separator and collide two distinct
    /// reports. `detail` carries an explicit present/absent marker so `nil` and `""` hash
    /// DIFFERENTLY. A change in ANY field (including a user-visible `detail`, or a new dangling
    /// ref) changes the hash, so an acknowledgement of an OLD report can never confirm a CHANGED one.
    public var reportHash: String {
        func field(_ s: String) -> String { "\(s.utf8.count):\(s)" }
        func optField(_ s: String?) -> String { s == nil ? "-" : "+" + field(s!) }
        var s = "\(items.count)#"
        for it in items { s += field(it.kind.rawValue) + field(it.name) + optField(it.detail) }
        return SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func merged(with extra: [Item]) -> UnresolvedReport { UnresolvedReport(items: items + extra) }
}

// MARK: - Acknowledgement

// `ReferenceAudit` + its only sanctioned producer live in AttachmentReferenceAuditor.swift.

/// What a caller must acknowledge: the FULL operation identity plus the unresolved-report hash.
/// An `Acknowledgement` can only be produced from a request, so it is inseparable from that
/// identity — an acknowledgement of import A can never confirm import B (even with an identical
/// unresolved list).
public struct AcknowledgementRequest: Equatable {
    public let importID: String
    public let snapshotIdentitySHA256: String
    public let attachmentManifestSHA256: String
    public let preparedDBIdentity: String
    public let unresolvedReportHash: String
    init(importID: String, snapshotIdentitySHA256: String, attachmentManifestSHA256: String,
         preparedDBIdentity: String, unresolvedReportHash: String) {
        self.importID = importID
        self.snapshotIdentitySHA256 = snapshotIdentitySHA256
        self.attachmentManifestSHA256 = attachmentManifestSHA256
        self.preparedDBIdentity = preparedDBIdentity
        self.unresolvedReportHash = unresolvedReportHash
    }
    public func acknowledge() -> Acknowledgement { Acknowledgement(request: self) }
}

public struct Acknowledgement: Equatable {
    let importID: String
    let snapshotIdentitySHA256: String
    let attachmentManifestSHA256: String
    let preparedDBIdentity: String
    let unresolvedReportHash: String
    init(request: AcknowledgementRequest) {
        self.importID = request.importID
        self.snapshotIdentitySHA256 = request.snapshotIdentitySHA256
        self.attachmentManifestSHA256 = request.attachmentManifestSHA256
        self.preparedDBIdentity = request.preparedDBIdentity
        self.unresolvedReportHash = request.unresolvedReportHash
    }
}

// MARK: - Plan (pre-swap gate)

public struct AttachmentPlan: Equatable {
    public struct Conflict: Equatable {
        public let name: String
        public let stagedSHA256: String
        public let activeSHA256: String
    }
    public var toCopy: [String]
    public var identical: [String]
    public var conflicts: [Conflict]
    public var missing: [String]
    public var hasConflicts: Bool { !conflicts.isEmpty }
}

// MARK: - Errors / results

/// The completion sentinel's durability barriers, in publication order. Both also replay
/// on every adopt of a pre-existing identical sentinel (repair-on-retry).
public enum SentinelSyncPoint: String, Equatable {
    case sentinelFile, sentinelDirEntry
}

public enum AttachmentApplyError: Error, CustomStringConvertible {
    case manifestUnreadable(String)
    case invalidImportID(String)
    case invalidAttachmentName(String)
    case attachmentPathEscape(String)
    case duplicateAttachmentName(String)
    case attachmentManifestHashMismatch
    case stagedFileHashMismatch(String)
    case conflicts([AttachmentPlan.Conflict])
    case conflictDuringApply(String)
    case activeFileHashMismatch(String)
    case sentinelIdentityMismatch(String)
    case unsupportedManifestFormat(Int?)
    case referenceAuditMismatch(field: String)
    case preparedDatabaseIdentityMismatch(expected: String, actual: String)
    case preparedDatabaseCorrupt(String)
    case preparedDatabaseSchemaUnsupported(String)
    case preparedDatabaseChangedDuringAudit(before: String, after: String)
    case referencedFileChangedSinceAudit(String)
    case stagedEntryNotRegularFile(String)
    case activeEntryNotRegularFile(String)
    case sentinelDurabilityFailed(SentinelSyncPoint, String)
    case sentinelPublishIncomplete(String)

    public var description: String {
        switch self {
        case .manifestUnreadable(let p): return "Staged import manifest is unreadable: \(p)"
        case .invalidImportID(let s): return "Manifest importID is not a valid ImportID: \(s)"
        case .invalidAttachmentName(let n): return "Manifest attachment name fails the whitelist: \(n)"
        case .attachmentPathEscape(let n): return "Attachment '\(n)' resolves outside the staged docs dir"
        case .duplicateAttachmentName(let n): return "Duplicate attachment name in manifest: \(n)"
        case .attachmentManifestHashMismatch: return "Recomputed attachmentManifestSHA256 does not match the manifest"
        case .stagedFileHashMismatch(let n): return "Staged file '\(n)' bytes do not match the manifest SHA-256"
        case .conflicts(let c): return "Attachment conflicts (same name, different content) — resolve before importing: \(c.map { $0.name }.joined(separator: ", "))"
        case .conflictDuringApply(let n): return "Attachment '\(n)' changed under us during apply — refusing to overwrite"
        case .activeFileHashMismatch(let n): return "Active attachment '\(n)' changed after planning — refusing to complete"
        case .sentinelIdentityMismatch(let id): return "A completion sentinel for import \(id) already exists with a different identity — refusing to overwrite"
        case .unsupportedManifestFormat(let v): return "Unsupported manifest formatVersion \(v.map(String.init) ?? "nil") — refusing to process"
        case .referenceAuditMismatch(let field): return "Reference audit does not belong to this import (\(field) mismatch) — refusing to complete"
        case .preparedDatabaseIdentityMismatch: return "The prepared database is not the one this import was applied against — refusing to audit"
        case .preparedDatabaseCorrupt(let m): return "Prepared database failed its integrity check: \(m)"
        case .preparedDatabaseSchemaUnsupported(let m): return "Prepared database schema is unsupported (\(m)) — refusing to audit references"
        case .preparedDatabaseChangedDuringAudit: return "The prepared database changed during the reference audit — refusing to trust the scan"
        case .referencedFileChangedSinceAudit(let n): return "Referenced attachment '\(n)' changed after the audit — re-run the reference audit before completing"
        case .stagedEntryNotRegularFile(let n): return "Staged attachment '\(n)' is not a regular file (symlink/directory/special) — refusing to apply"
        case .activeEntryNotRegularFile(let n): return "Active attachment entry '\(n)' is not a regular file (symlink/directory/special) — refusing to touch it"
        case let .sentinelDurabilityFailed(point, m): return "Completion-sentinel durability barrier failed at \(point.rawValue) (retry — staging is kept): \(m)"
        case .sentinelPublishIncomplete(let m): return "Completion-sentinel publication did not complete (retry): \(m)"
        }
    }
}

/// Result of the attachment-FILE apply (files copied; NOT yet complete — completion needs the
/// DB reference audit and any acknowledgement).
public struct AttachmentApplyReport {
    public let importID: ImportID
    public let stagingDir: URL
    public let activeAttachmentsDir: URL
    public let manifest: ImportManifest
    /// Identity of the prepared/active DB this apply is bound to (supplied by the coordinator).
    /// The reference audit must carry the SAME value or `complete` rejects it as cross-database.
    public let preparedDBIdentity: String
    public let applied: ImportManifest.AppliedSummary
    /// Missing staged files + ingest-stage skips. The DB reference audit's dangling refs are
    /// merged in at `complete` time.
    public let fileUnresolved: UnresolvedReport

    // INTERNAL: only `apply()` (Core) produces a report; the App module cannot fabricate one.
    // `@testable` tests may still construct it directly.
    init(importID: ImportID, stagingDir: URL, activeAttachmentsDir: URL, manifest: ImportManifest,
         preparedDBIdentity: String, applied: ImportManifest.AppliedSummary, fileUnresolved: UnresolvedReport) {
        self.importID = importID; self.stagingDir = stagingDir; self.activeAttachmentsDir = activeAttachmentsDir
        self.manifest = manifest; self.preparedDBIdentity = preparedDBIdentity
        self.applied = applied; self.fileUnresolved = fileUnresolved
    }
}

public struct ApplyResult: Equatable {
    public let importID: String
    public let applied: ImportManifest.AppliedSummary
    public let unresolved: UnresolvedReport
    public let completionSentinelURL: URL
    public let stagingCleaned: Bool
    public let stagingCleanupError: String?
}

public enum CompleteOutcome: Equatable {
    case completed(ApplyResult)
    /// Unresolved items remain (files and/or dangling refs). The caller must turn `request`
    /// into an `Acknowledgement` (via `request.acknowledge()`) after the user confirms, then
    /// call `complete` again. Nothing was persisted; staging is kept.
    case requiresAcknowledgement(request: AcknowledgementRequest, unresolved: UnresolvedReport)
}

/// Test-only fault seams (all `internal`, defaulting to no-op).
struct ApplyHooks {
    var onAttachmentCopy: ((String) throws -> Void)?
    var onBeforePublish: ((String) throws -> Void)?
    var onCompletionTempWrite: (() throws -> Void)?
    var onCompletionPublish: (() throws -> Void)?
    /// Fires BEFORE the real sync syscall of each sentinel durability barrier; it may throw
    /// (deterministic barrier-failure injection) or tamper the disk via the path — which is
    /// exactly why every barrier is followed by a re-verification on the bound inode.
    var onSentinelSync: ((SentinelSyncPoint) throws -> Void)?
    /// Fires AFTER the sentinel's exclusive rename and BEFORE the directory barrier — the
    /// crash-simulation / post-publish tamper window.
    var afterSentinelPublished: ((URL) throws -> Void)?
    /// Fires after the staging dir is bound and its entry verified, BEFORE the first unlink —
    /// the adversarial window for a name swap (deletions must stay on the bound tree).
    var beforeStagingRemoval: ((URL) throws -> Void)?
    var cleanup: ((URL) throws -> Void)?
    init(onAttachmentCopy: ((String) throws -> Void)? = nil,
         onBeforePublish: ((String) throws -> Void)? = nil,
         onCompletionTempWrite: (() throws -> Void)? = nil,
         onCompletionPublish: (() throws -> Void)? = nil,
         onSentinelSync: ((SentinelSyncPoint) throws -> Void)? = nil,
         afterSentinelPublished: ((URL) throws -> Void)? = nil,
         beforeStagingRemoval: ((URL) throws -> Void)? = nil,
         cleanup: ((URL) throws -> Void)? = nil) {
        self.onAttachmentCopy = onAttachmentCopy
        self.onBeforePublish = onBeforePublish
        self.onCompletionTempWrite = onCompletionTempWrite
        self.onCompletionPublish = onCompletionPublish
        self.onSentinelSync = onSentinelSync
        self.afterSentinelPublished = afterSentinelPublished
        self.beforeStagingRemoval = beforeStagingRemoval
        self.cleanup = cleanup
    }
}

/// Non-destructive, fail-closed attachment application + a two-phase completion sentinel.
///
/// PHASES:
///  - `plan` (side-effect-free) validates staging fail-closed and classifies vs the active
///    dir — the PRE-SWAP conflict gate.
///  - `apply` re-validates, copies ONLY absent files (per-copy `.part-<uuid>`, hash-verified
///    before publish, NEVER overwriting), and returns the ACTUAL outcomes + a file-level
///    unresolved report. It does NOT write a sentinel or clean staging.
///  - `complete` merges the DB reference audit, recomputes the prepared DB's identity from
///    the actual file (post-audit mutation fails closed), and only if there are no
///    unresolved items (or a matching acknowledgement) re-verifies every audited-resolved
///    reference and every final active file hash, publishes the completion sentinel
///    descriptor-rooted and create-only (bound temp → file barrier → RENAME_EXCL →
///    published-name + semantic read-back → directory barrier), and ONLY after both
///    durability barriers cleans staging (descriptor-rooted, known-tree only) — so a
///    power loss can never leave staging destroyed with the sentinel unpersisted.
///
/// ROLLBACK NOTE: because attachment apply is strictly add-only (never overwrites), a DB-only
/// backup is a LOGICAL LEDGER rollback point — the DB and every pre-existing attachment are
/// recoverable. It is NOT a byte-level filesystem-complete rollback: newly copied add-only
/// files may become unreferenced ORPHANS after a DB rollback (safe, but present on disk until
/// a future reaper collects them).
public struct AttachmentApply {
    public init() {}

    // MARK: - Public phases

    /// Side-effect-free, fail-closed classification vs the active dir. Throws on any staging
    /// integrity failure; returns conflicts for the coordinator to block a swap on.
    public func plan(stagingDir: URL, activeAttachmentsDir: URL) throws -> AttachmentPlan {
        let v = try Self.validate(stagingDir: stagingDir)
        return try Self.buildPlan(validated: v, activeDir: activeAttachmentsDir)
    }

    /// Copy the staged import's absent attachments to the active dir (non-destructive) and
    /// report ACTUAL outcomes + file-level unresolved items. The report is bound to the
    /// prepared/active DB at `preparedDatabaseAt` via an identity COMPUTED HERE through the
    /// quiescence gate — callers never supply an identity string of their own, so a
    /// reference audit for a different DB can never complete this report. No sentinel, no
    /// staging cleanup.
    public func apply(stagingDir: URL, activeAttachmentsDir: URL, preparedDatabaseAt url: URL) throws -> AttachmentApplyReport {
        try apply(stagingDir: stagingDir, activeAttachmentsDir: activeAttachmentsDir,
                  preparedDBIdentity: try PreparedDatabaseIdentity.compute(at: url), hooks: ApplyHooks())
    }

    /// Finalize: merge the DB reference audit, gate on acknowledgement if anything is
    /// unresolved, recompute the prepared DB's identity and re-verify every audited-resolved
    /// reference and every active file, persist the sentinel, then clean staging.
    @discardableResult
    public func complete(report: AttachmentApplyReport, referenceAudit: ReferenceAudit,
                         acknowledgement: Acknowledgement?, preparedDatabaseAt url: URL) throws -> CompleteOutcome {
        try complete(report: report, referenceAudit: referenceAudit, acknowledgement: acknowledgement,
                     preparedDatabaseAt: url, manifestsDir: try AppPaths.importManifestsDirectory(), hooks: ApplyHooks())
    }

    // MARK: - Internal (fault seams / injectable dirs)

    func apply(stagingDir: URL, activeAttachmentsDir: URL, preparedDBIdentity: String, hooks: ApplyHooks) throws -> AttachmentApplyReport {
        let v = try Self.validate(stagingDir: stagingDir)
        let plan = try Self.buildPlan(validated: v, activeDir: activeAttachmentsDir)
        if plan.hasConflicts { throw AttachmentApplyError.conflicts(plan.conflicts) }   // PRE-SWAP gate

        let fm = FileManager.default
        try fm.createDirectory(at: activeAttachmentsDir, withIntermediateDirectories: true)
        let byName = Dictionary(uniqueKeysWithValues: v.files.map { ($0.name, $0) })

        var copied: [String] = []
        var skippedIdentical: [String] = plan.identical   // plan-time identicals
        for name in plan.toCopy {
            guard let vf = byName[name] else { continue }
            let outcome = try Self.copyNonDestructive(from: vf.staged, to: activeAttachmentsDir.appendingPathComponent(name),
                                                      name: name, expectedSHA: vf.expectedSHA, hooks: hooks)
            switch outcome {
            case .copied: copied.append(name)
            case .skippedIdenticalRace: skippedIdentical.append(name)   // ACTUAL outcome, not the plan's guess
            }
        }
        let applied = ImportManifest.AppliedSummary(copied: copied.sorted(),
                                                    skippedIdentical: skippedIdentical.sorted(),
                                                    missing: plan.missing)
        return AttachmentApplyReport(importID: v.importID, stagingDir: stagingDir,
                                     activeAttachmentsDir: activeAttachmentsDir, manifest: v.manifest,
                                     preparedDBIdentity: preparedDBIdentity, applied: applied,
                                     fileUnresolved: Self.fileUnresolved(v))
    }

    /// `prePublishGate` is the CALLER's completion-validity gate (e.g. C11's active-envelope
    /// + bound-rehash bracket). It runs twice inside sentinel publication — once before the
    /// manifests dir is touched, once immediately before the exclusive rename — so every
    /// completion-validity check happens BEFORE the sentinel becomes durable; after publish
    /// only publish-integrity is verified and restart semantics derive from disk alone.
    ///
    /// `trustedStagingRoot` is the caller's ALREADY-BOUND staging evidence (C11b passes
    /// `GatedStagedSnapshot.root`). When supplied, the staging URL is never re-opened —
    /// cleanup trusts exactly this handle, and a pre-swapped impostor at the URL is never
    /// bound or deleted. When nil (the 2B-1 standalone path), the root is bound from
    /// `report.stagingDir` at complete() entry — still strictly before sentinel publication.
    func complete(report: AttachmentApplyReport, referenceAudit: ReferenceAudit,
                  acknowledgement: Acknowledgement?, preparedDatabaseAt preparedDBURL: URL,
                  manifestsDir: URL, prePublishGate: (() throws -> Void)? = nil,
                  trustedStagingRoot: DirectoryHandle? = nil,
                  hooks: ApplyHooks) throws -> CompleteOutcome {
        // The audit evidence must belong to THIS exact import — reject cross-import / snapshot /
        // attachment-set / database audits field-by-field.
        guard referenceAudit.importID == report.importID.rawValue else { throw AttachmentApplyError.referenceAuditMismatch(field: "importID") }
        guard referenceAudit.snapshotIdentitySHA256 == report.manifest.snapshotIdentitySHA256 else { throw AttachmentApplyError.referenceAuditMismatch(field: "snapshotIdentity") }
        guard referenceAudit.attachmentManifestSHA256 == report.manifest.attachmentManifestSHA256 else { throw AttachmentApplyError.referenceAuditMismatch(field: "attachmentManifest") }
        guard referenceAudit.preparedDBIdentity == report.preparedDBIdentity else { throw AttachmentApplyError.referenceAuditMismatch(field: "preparedDBIdentity") }

        // The prepared database must STILL be the exact database everything above was bound
        // to — recompute its identity from the actual file (quiescence gate included). A row
        // edited after the audit, a swapped file, or a sidecar appearing all fail here, so a
        // sentinel can never seal evidence about a database that no longer exists as audited.
        let currentIdentity = try PreparedDatabaseIdentity.compute(at: preparedDBURL)
        guard currentIdentity == report.preparedDBIdentity else {
            throw AttachmentApplyError.preparedDatabaseIdentityMismatch(expected: report.preparedDBIdentity, actual: currentIdentity)
        }

        // Structured audit items flow in with their provenance as `detail`, so the display,
        // the reportHash AND the acknowledgement binding all cover "table.column×rows" — a
        // changed provenance or count invalidates a previously issued acknowledgement.
        let dangling = referenceAudit.dangling.map {
            UnresolvedReport.Item(name: $0.name, kind: .danglingReference, detail: $0.provenance)
        }
        let invalid = referenceAudit.invalid.map {
            UnresolvedReport.Item(name: $0.value, kind: .invalidReference, detail: $0.provenance)
        }
        let unresolved = report.fileUnresolved.merged(with: dangling + invalid)
        let reportHash = unresolved.reportHash

        // Acknowledgement gate: unresolved ⇒ no auto-complete, no staging cleanup. The ack must
        // match the FULL operation identity (importID + snapshot + attachment set + this report's
        // unresolved hash), so an ack from another import — even with an identical unresolved
        // list — cannot confirm this one.
        if !unresolved.isEmpty {
            let request = AcknowledgementRequest(importID: report.importID.rawValue,
                                                 snapshotIdentitySHA256: report.manifest.snapshotIdentitySHA256,
                                                 attachmentManifestSHA256: report.manifest.attachmentManifestSHA256,
                                                 preparedDBIdentity: report.preparedDBIdentity,
                                                 unresolvedReportHash: reportHash)
            guard let ack = acknowledgement,
                  ack.importID == request.importID,
                  ack.snapshotIdentitySHA256 == request.snapshotIdentitySHA256,
                  ack.attachmentManifestSHA256 == request.attachmentManifestSHA256,
                  ack.preparedDBIdentity == request.preparedDBIdentity,
                  ack.unresolvedReportHash == request.unresolvedReportHash else {
                return .requiresAcknowledgement(request: request, unresolved: unresolved)
            }
        }

        // Re-verify EVERY reference the audit resolved — not just this import's copied/
        // skipped files: a pre-existing referenced attachment deleted or replaced after the
        // audit must fail closed. The no-follow regular-file-only hash guarantees the entry
        // is STILL a regular file (a same-content symlink swapped in is rejected, a FIFO is
        // never opened blocking) with the exact audited bytes.
        for r in referenceAudit.resolved {
            let target = report.activeAttachmentsDir.appendingPathComponent(r.name)
            guard let actual = try? FileHash.sha256HexOfRegularFile(at: target), actual == r.sha256 else {
                throw AttachmentApplyError.referencedFileChangedSinceAudit(r.name)
            }
        }

        // Re-verify EVERY final active file against the manifest SHA (catch post-plan
        // changes). Same no-follow primitive: missing, swapped-for-symlink, directory or
        // special all fail as a hash mismatch.
        let expected = Dictionary(uniqueKeysWithValues:
            report.manifest.files.filter { $0.outcome == .ingested }.compactMap { f in f.sha256.map { (f.name, $0) } })
        for name in report.applied.copied + report.applied.skippedIdentical {
            let active = report.activeAttachmentsDir.appendingPathComponent(name)
            guard let exp = expected[name],
                  let actual = try? FileHash.sha256HexOfRegularFile(at: active),
                  actual == exp else {
                throw AttachmentApplyError.activeFileHashMismatch(name)
            }
        }

        var final = report.manifest
        final.status = .complete
        final.applied = report.applied
        final.unresolved = unresolved
        final.acknowledgedReportHash = unresolved.isEmpty ? nil : reportHash
        final.referenceAuditPerformed = true
        final.preparedDBIdentity = report.preparedDBIdentity
        final.report = Self.reportString(applied: report.applied, unresolved: unresolved)

        // Bind everything staging cleanup will need BEFORE the sentinel becomes durable —
        // after publish no staging path is re-opened by URL, so a tree swapped in during
        // the publish window can never be entered or deleted. A caller-supplied trusted
        // root (C11b: GatedStagedSnapshot.root) replaces even the entry-time URL bind.
        let cleanupPlan = Self.bindStagingForCleanup(stagingDir: report.stagingDir,
                                                     trustedRoot: trustedStagingRoot)

        // Sentinel publication (descriptor-rooted, barriered) MUST fully succeed — including
        // both durability barriers — before staging cleanup may destroy the ability to re-run.
        let sentinelURL = try Self.persistCompletion(final, importID: report.importID, manifestsDir: manifestsDir,
                                                     prePublishGate: prePublishGate, hooks: hooks)

        var cleanupError: String?
        do { try Self.cleanStaging(plan: cleanupPlan, stagingDir: report.stagingDir, manifest: final, hooks: hooks) }
        catch { cleanupError = "\(error)" }

        return .completed(ApplyResult(importID: report.importID.rawValue, applied: report.applied,
                                      unresolved: unresolved, completionSentinelURL: sentinelURL,
                                      stagingCleaned: cleanupError == nil, stagingCleanupError: cleanupError))
    }

    // MARK: - Validation (fail-closed)

    struct ValidatedFile { let name: String; let expectedSHA: String; let staged: URL; let present: Bool }
    struct ValidatedStaging { let importID: ImportID; let manifest: ImportManifest; let files: [ValidatedFile] }

    static func validate(stagingDir: URL) throws -> ValidatedStaging {
        let manifest = try loadManifest(stagingDir)
        // Fail-closed on format: a missing (old) or newer/unknown version is rejected, never
        // best-effort parsed.
        guard manifest.formatVersion == ImportManifest.currentFormatVersion else {
            throw AttachmentApplyError.unsupportedManifestFormat(manifest.formatVersion)
        }
        // Reconstruct + validate a strongly-typed ImportID — never use the raw string for paths.
        guard let importID = ImportID(manifest.importID) else {
            throw AttachmentApplyError.invalidImportID(manifest.importID)
        }
        // The manifest's own hash must match its recorded file set (catches tampered names/hashes).
        guard ImportManifest.attachmentSetHash(manifest.files) == manifest.attachmentManifestSHA256 else {
            throw AttachmentApplyError.attachmentManifestHashMismatch
        }

        let stagedDocs = stagedDocsDir(stagingDir)
        let stagedDocsPath = stagedDocs.standardizedFileURL.path
        var seen = Set<String>()
        var files: [ValidatedFile] = []
        for f in manifest.files {
            // Dedup across the WHOLE manifest: a single source scan can't yield two entries
            // with one name, so any duplicate (ingested or skipped) means tampering.
            guard seen.insert(f.name).inserted else { throw AttachmentApplyError.duplicateAttachmentName(f.name) }
            guard f.outcome == .ingested else { continue }   // skipped entries: dedup only
            guard AttachmentName.isValid(f.name) else { throw AttachmentApplyError.invalidAttachmentName(f.name) }
            let staged = stagedDocs.appendingPathComponent(f.name)
            guard staged.standardizedFileURL.path.hasPrefix(stagedDocsPath + "/") else {
                throw AttachmentApplyError.attachmentPathEscape(f.name)
            }
            guard let expected = f.sha256 else { throw AttachmentApplyError.stagedFileHashMismatch(f.name) }
            // No-follow, regular-file-only: a staged symlink/directory/FIFO where the
            // manifest promises an ingested regular file is tampering — fail closed.
            // Only a definitive ENOENT counts as "missing" (an unresolved item).
            let present: Bool
            do {
                let actual = try FileHash.sha256HexOfRegularFile(at: staged)
                guard actual == expected else { throw AttachmentApplyError.stagedFileHashMismatch(f.name) }
                present = true
            } catch let e as FileHashError {
                if case .notARegularFile = e { throw AttachmentApplyError.stagedEntryNotRegularFile(f.name) }
                guard e.isFileMissing else { throw e }
                present = false
            }
            files.append(ValidatedFile(name: f.name, expectedSHA: expected, staged: staged, present: present))
        }
        return ValidatedStaging(importID: importID, manifest: manifest, files: files)
    }

    static func fileUnresolved(_ v: ValidatedStaging) -> UnresolvedReport {
        var items: [UnresolvedReport.Item] = []
        for vf in v.files where !vf.present { items.append(.init(name: vf.name, kind: .missingStagedFile)) }
        for f in v.manifest.files where f.outcome != .ingested {
            let kind: UnresolvedReport.Item.Kind
            switch f.outcome {
            case .skippedSymlink: kind = .skippedSymlink
            case .skippedDirectory: kind = .skippedDirectory
            case .skippedSpecial: kind = .skippedSpecial
            case .rejectedName: kind = .rejectedName
            case .ingested: continue
            }
            items.append(.init(name: f.name, kind: kind))
        }
        return UnresolvedReport(items: items)
    }

    static func buildPlan(validated: ValidatedStaging, activeDir: URL) throws -> AttachmentPlan {
        var toCopy: [String] = [], identical: [String] = [], missing: [String] = []
        var conflicts: [AttachmentPlan.Conflict] = []
        for vf in validated.files {
            if !vf.present { missing.append(vf.name); continue }
            let active = activeDir.appendingPathComponent(vf.name)
            // No-follow, regular-file-only: a same-name symlink (even to identical
            // content, even dangling), directory or FIFO in the active dir is an explicit
            // pre-swap error — it is never followed, never opened blocking, and never
            // classified as identical/toCopy.
            let activeSHA: String?
            do {
                activeSHA = try FileHash.sha256HexOfRegularFile(at: active)
            } catch let e as FileHashError {
                if case .notARegularFile = e { throw AttachmentApplyError.activeEntryNotRegularFile(vf.name) }
                guard e.isFileMissing else { throw e }
                activeSHA = nil
            }
            guard let activeSHA else { toCopy.append(vf.name); continue }
            if activeSHA == vf.expectedSHA { identical.append(vf.name) }
            else { conflicts.append(.init(name: vf.name, stagedSHA256: vf.expectedSHA, activeSHA256: activeSHA)) }
        }
        return AttachmentPlan(toCopy: toCopy.sorted(), identical: identical.sorted(),
                              conflicts: conflicts.sorted { $0.name < $1.name }, missing: missing.sorted())
    }

    // MARK: - Copy / persist internals

    private enum CopyOutcome { case copied; case skippedIdenticalRace }

    /// Copy `src` → `dst` only if `dst` is absent (non-destructive). A per-copy `.part-<uuid>`
    /// is hash-verified against the expected SHA before an atomic rename; on any failure the
    /// part is cleaned. A `dst` that appears mid-copy: identical ⇒ skip; different ⇒ conflict,
    /// never overwrite.
    /// A target already present at the destination: identical content ⇒ skip, different ⇒
    /// conflict. NEVER overwrites, NEVER follows a symlink, NEVER opens a FIFO blocking —
    /// a non-regular entry (however it appeared, including mid-publish races) is an error.
    private static func classifyExistingTarget(_ dst: URL, expectedSHA: String, name: String) throws -> CopyOutcome {
        let dstSHA: String
        do {
            dstSHA = try FileHash.sha256HexOfRegularFile(at: dst)
        } catch let e as FileHashError {
            if case .notARegularFile = e { throw AttachmentApplyError.activeEntryNotRegularFile(name) }
            throw e
        }
        if dstSHA == expectedSHA { return .skippedIdenticalRace }
        throw AttachmentApplyError.conflictDuringApply(name)
    }

    private static func copyNonDestructive(from src: URL, to dst: URL, name: String,
                                           expectedSHA: String, hooks: ApplyHooks) throws -> CopyOutcome {
        let fm = FileManager.default
        if fm.fileExists(atPath: dst.path) { return try classifyExistingTarget(dst, expectedSHA: expectedSHA, name: name) }
        try hooks.onAttachmentCopy?(name)

        let part = URL(fileURLWithPath: dst.path + ".part-\(UUID().uuidString)")
        var published = false
        defer {
            if !published, fm.fileExists(atPath: part.path) {
                do { try fm.removeItem(at: part) } catch { /* leave this round's part for a reaper */ }
            }
        }
        try fm.copyItem(at: src, to: part)
        let partSHA = try FileHash.sha256HexOfRegularFile(at: part)
        guard partSHA == expectedSHA else { throw AttachmentApplyError.stagedFileHashMismatch(name) }

        if fm.fileExists(atPath: dst.path) { return try classifyExistingTarget(dst, expectedSHA: expectedSHA, name: name) }   // post-copy check
        // FINAL-publish race seam: fires in the genuine TOCTOU window — AFTER the last
        // deterministic check and immediately BEFORE the rename — so a target appearing here is
        // caught by moveItem (which THROWS on an existing destination, never overwriting) and
        // re-classified same-hash-skip / different-conflict. This exercises the catch path.
        try hooks.onBeforePublish?(name)
        do {
            try fm.moveItem(at: part, to: dst)
        } catch {
            if fm.fileExists(atPath: dst.path) { return try classifyExistingTarget(dst, expectedSHA: expectedSHA, name: name) }
            throw error   // some other move failure (not an existing-target race)
        }
        published = true
        return .copied
    }

    private static func reportString(applied: ImportManifest.AppliedSummary, unresolved: UnresolvedReport) -> String {
        var s = "attachments: copied \(applied.copied.count), identical \(applied.skippedIdentical.count)"
        if !unresolved.isEmpty {
            let byKind = Dictionary(grouping: unresolved.items, by: { $0.kind.rawValue }).mapValues { $0.count }
            s += "; unresolved " + byKind.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        }
        return s
    }

    /// Sentinel read ceiling. A completion sentinel lists every attachment, so it is larger
    /// than the fixed-shape owner record but still bounded (thousands of entries fit well
    /// under 8 MiB); a bigger file at the sentinel name is malformed/hostile and must never
    /// be slurped unbounded — exceeding the cap fails closed, never a truncated success.
    static let maxSentinelBytes = 8 << 20

    /// Whole-sentinel decode through the BOUND fd (never by name), size-capped.
    private static func decodeSentinel(_ file: BoundRegularFile) throws -> ImportManifest {
        try JSONDecoder().decode(ImportManifest.self, from: try file.readAll(maxBytes: maxSentinelBytes))
    }

    /// Run one sentinel durability barrier: the test seam fires FIRST (it may throw to
    /// inject a failure, or tamper — post-sync gates re-verify), then the real barrier.
    private static func sentinelSync(_ point: SentinelSyncPoint, hooks: ApplyHooks,
                                     _ body: () throws -> Void) throws {
        do {
            try hooks.onSentinelSync?(point)
            try body()
        } catch { throw AttachmentApplyError.sentinelDurabilityFailed(point, "\(error)") }
    }

    /// Descriptor-rooted, barriered, create-only publication of the completion sentinel.
    ///
    /// Order (every step fd-relative to the BOUND manifests dir; barriers strictly BEFORE
    /// the caller may clean staging):
    ///   GX  caller's `prePublishGate` (completion-validity — before ANY side effect,
    ///       including the ensure-exists createDirectory of the manifests dir)
    ///   P0  bind ImportManifests AND its parent (O_NOFOLLOW|O_DIRECTORY, dev+inode) and
    ///       verify the parent's entry resolves to the bound dir — publication is only
    ///       meaningful while the CANONICAL ImportManifests name leads to this inode
    ///   P1  pre-existing sentinel ⇒ adopt (reuse iff SEMANTICALLY IDENTICAL — same
    ///       importID, formatVersion, status, referenceAuditPerformed, applied, unresolved,
    ///       acknowledgedReportHash, every identity hash — with BOTH barriers replayed;
    ///       anything else is rejected and never overwritten)
    ///   P2  exclusive hidden temp via BoundRegularFile (openat O_EXCL|O_NOFOLLOW, no reopen)
    ///   P3  bound write-back verify
    ///   P4  file barrier (F_FULLFSYNC, fail closed)         ← durability barrier 1
    ///   P5  post-sync re-verify (name still bound + bytes still exact)
    ///   GX′ caller's `prePublishGate` again, immediately before publish
    ///   P5′ FINAL temp re-verify directly before the rename (the gate ran arbitrary code):
    ///       tempName still resolves to the bound inode AND bound decode == the manifest
    ///   P6  same-directory RENAME_EXCL (create-only, never overwrites); losing the race
    ///       falls back to the P1 adopt path
    ///   P7  published name resolves to OUR bound inode + full semantic read-back
    ///   P8  directory-entry barrier                          ← durability barrier 2
    ///   P9  P7 re-verified after the barrier
    ///   P10 canonical-path linkage: the parent's ImportManifests entry STILL resolves to
    ///       the bound dir — a moved-aside dir would hold a sentinel no restart probe can
    ///       find, so an unlinked dir is retriable `sentinelPublishIncomplete`, never
    ///       completed (and staging stays, because cleanup runs only after this returns)
    ///
    /// A FINAL sentinel is never deleted or overwritten by any path here. Crash before P6
    /// leaves only the hidden temp (reaper residue); crash after P6 leaves a published,
    /// process-crash-safe sentinel whose durability is re-confirmed by the next run's adopt.
    private static func persistCompletion(_ manifest: ImportManifest, importID: ImportID,
                                          manifestsDir: URL, prePublishGate: (() throws -> Void)?,
                                          hooks: ApplyHooks) throws -> URL {
        try prePublishGate?()   // GX — strictly before ANY manifests-dir side effect

        try FileManager.default.createDirectory(at: manifestsDir, withIntermediateDirectories: true)
        let finalName = "\(importID.rawValue).json"
        let finalURL = manifestsDir.appendingPathComponent(finalName)
        let dirName = manifestsDir.lastPathComponent

        // P0: bind the manifests dir AND its parent; the parent's entry must resolve to the
        // bound dir now and STILL at P10 — a sentinel published into a moved-aside dir is
        // not published at its canonical path and must never count as completed.
        let dirParent: DirectoryHandle
        do { dirParent = try DirectoryHandle.open(at: manifestsDir.deletingLastPathComponent()) }
        catch { throw AttachmentApplyError.sentinelPublishIncomplete("manifests parent bind: \(error)") }
        let dir: DirectoryHandle
        do { dir = try DirectoryHandle.open(at: manifestsDir) }
        catch { throw AttachmentApplyError.sentinelPublishIncomplete("manifests dir bind: \(error)") }
        try assertManifestsDirStillLinked(dir, named: dirName, in: dirParent)

        let existingFP: FileFingerprint?
        do { existingFP = try dir.fingerprint(named: finalName) }
        catch { throw AttachmentApplyError.sentinelPublishIncomplete("sentinel fingerprint: \(error)") }
        if existingFP != nil {
            return try adoptExistingSentinel(named: finalName, in: dir, dirName: dirName, dirParent: dirParent,
                                             expected: manifest, importID: importID, finalURL: finalURL, hooks: hooks)
        }

        try hooks.onCompletionTempWrite?()
        let payload: Data
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            payload = try enc.encode(manifest)
        } catch { throw AttachmentApplyError.sentinelPublishIncomplete("sentinel encode: \(error)") }

        let tempName = ".tmp-\(importID.rawValue)-\(UUID().uuidString).json"
        let tmp: BoundRegularFile
        do { tmp = try BoundRegularFile.create(in: dir, named: tempName, contents: payload) }
        catch { throw AttachmentApplyError.sentinelPublishIncomplete("sentinel temp create: \(error)") }
        var published = false
        // Cleanup may touch ONLY the unpublished temp, and only while the name still
        // resolves to our bound inode. The FINAL sentinel is never deleted by any path.
        defer { if !published { tmp.unlinkIfStillBound(named: tempName, in: dir) } }

        guard (try? decodeSentinel(tmp)) == manifest else {                                    // P3
            throw AttachmentApplyError.sentinelPublishIncomplete("sentinel write-back mismatch")
        }
        try sentinelSync(.sentinelFile, hooks: hooks) { try tmp.syncToDisk() }                 // P4
        guard (try? tmp.matchesChild(named: tempName, in: dir)) == true,                       // P5
              (try? decodeSentinel(tmp)) == manifest else {
            throw AttachmentApplyError.sentinelPublishIncomplete("sentinel temp changed after the file barrier")
        }

        try prePublishGate?()   // GX′

        guard (try? tmp.matchesChild(named: tempName, in: dir)) == true else {                 // P5′ (name)
            throw AttachmentApplyError.sentinelPublishIncomplete("sentinel temp name unbound before publish")
        }
        guard (try? decodeSentinel(tmp)) == manifest else {                                    // P5′ (bytes)
            throw AttachmentApplyError.sentinelPublishIncomplete("sentinel temp content changed before publish")
        }

        try hooks.onCompletionPublish?()
        let ok: Bool
        do { ok = try dir.renameChildExclusively(from: tempName, to: finalName) }              // P6
        catch { throw AttachmentApplyError.sentinelPublishIncomplete("sentinel publish rename: \(error)") }
        guard ok else {
            // Lost the publish race — a sentinel appeared concurrently. NEVER overwrite:
            // adopt iff identical (with barrier replay), else reject. Temp cleaned by the defer.
            return try adoptExistingSentinel(named: finalName, in: dir, dirName: dirName, dirParent: dirParent,
                                             expected: manifest, importID: importID, finalURL: finalURL, hooks: hooks)
        }
        published = true

        try assertSentinelStillPublished(tmp, named: finalName, in: dir, expected: manifest,   // P7
                                         importID: importID, what: "immediately after publish")
        try hooks.afterSentinelPublished?(finalURL)
        try sentinelSync(.sentinelDirEntry, hooks: hooks) {                                    // P8
            try fsyncDirectoryEntry(dir, pathHint: manifestsDir.path)
        }
        try assertSentinelStillPublished(tmp, named: finalName, in: dir, expected: manifest,   // P9
                                         importID: importID, what: "after the directory barrier")
        try assertManifestsDirStillLinked(dir, named: dirName, in: dirParent)                  // P10
        return finalURL
    }

    /// The CANONICAL manifests-dir name must still resolve (dir type, device+inode) to the
    /// bound handle every fd-relative step ran inside. Verifying only names INSIDE the bound
    /// dir is not enough: a whole-dir swap leaves those checks passing while the sentinel
    /// sits in a moved-aside dir no restart probe can find. Unlinked ⇒ retriable
    /// `sentinelPublishIncomplete` (the caller keeps staging; a re-run republishes at the
    /// canonical path).
    private static func assertManifestsDirStillLinked(_ dir: DirectoryHandle, named dirName: String,
                                                      in parent: DirectoryHandle) throws {
        guard let fp = try? parent.fingerprint(named: dirName), fp.isDirectory,
              fp.device == dir.device, fp.inode == dir.inode else {
            throw AttachmentApplyError.sentinelPublishIncomplete(
                "'\(dirName)' no longer resolves to the bound manifests directory — the sentinel is not at its canonical path")
        }
    }

    /// Adopt a pre-existing FINAL sentinel: bind it (openat no-follow — a symlink or a
    /// directory at the name is a conflict, never followed), decode from the bound fd
    /// (size-capped), require SEMANTIC full-field equality with the completion we would
    /// write, then REPLAY both durability barriers with post-sync re-verification — a
    /// barrier that failed (or a crash) in an earlier run is repaired before the sentinel
    /// is trusted as durable. Anything non-identical is rejected and never overwritten.
    /// Exits through the same P10 canonical-linkage gate as the fresh path.
    private static func adoptExistingSentinel(named finalName: String, in dir: DirectoryHandle,
                                              dirName: String, dirParent: DirectoryHandle,
                                              expected: ImportManifest, importID: ImportID,
                                              finalURL: URL, hooks: ApplyHooks) throws -> URL {
        let existing: BoundRegularFile
        do { existing = try BoundRegularFile.open(in: dir, named: finalName) }
        catch let e as FileHashError {
            if case .notARegularFile = e { throw AttachmentApplyError.sentinelIdentityMismatch(importID.rawValue) }
            throw AttachmentApplyError.sentinelPublishIncomplete("existing sentinel open: \(e)")
        }
        catch { throw AttachmentApplyError.sentinelPublishIncomplete("existing sentinel open: \(error)") }
        guard (try? decodeSentinel(existing)) == expected else {
            throw AttachmentApplyError.sentinelIdentityMismatch(importID.rawValue)
        }
        try sentinelSync(.sentinelFile, hooks: hooks) { try existing.syncToDisk() }
        guard (try? existing.matchesChild(named: finalName, in: dir)) == true,
              (try? decodeSentinel(existing)) == expected else {
            throw AttachmentApplyError.sentinelPublishIncomplete("existing sentinel changed after the file barrier")
        }
        try sentinelSync(.sentinelDirEntry, hooks: hooks) {
            try fsyncDirectoryEntry(dir, pathHint: finalURL.deletingLastPathComponent().path)
        }
        guard (try? existing.matchesChild(named: finalName, in: dir)) == true,
              (try? decodeSentinel(existing)) == expected else {
            throw AttachmentApplyError.sentinelPublishIncomplete("existing sentinel changed after the directory barrier")
        }
        try assertManifestsDirStillLinked(dir, named: dirName, in: dirParent)                  // P10
        return finalURL
    }

    /// Publish-integrity check on the just-published sentinel: the final name must still
    /// resolve to OUR bound inode and read back semantically identical. On failure, decide
    /// from what is at the name NOW — restart semantics derive from disk the same way:
    ///  - vanished ⇒ retriable `sentinelPublishIncomplete` (a re-run republishes);
    ///  - a semantically IDENTICAL object ⇒ functional convergence, success;
    ///  - anything else (foreign/tampered) ⇒ terminal `sentinelIdentityMismatch`.
    private static func assertSentinelStillPublished(_ tmp: BoundRegularFile, named finalName: String,
                                                     in dir: DirectoryHandle, expected: ImportManifest,
                                                     importID: ImportID, what: String) throws {
        if (try? tmp.matchesChild(named: finalName, in: dir)) == true,
           (try? decodeSentinel(tmp)) == expected { return }
        let fp = try? dir.fingerprint(named: finalName)
        guard fp != nil else {
            throw AttachmentApplyError.sentinelPublishIncomplete("published sentinel vanished \(what)")
        }
        if let f = try? BoundRegularFile.open(in: dir, named: finalName),
           (try? decodeSentinel(f)) == expected { return }
        throw AttachmentApplyError.sentinelIdentityMismatch(importID.rawValue)
    }

    /// A staging-cleanup step that must leave everything untouched (replaced entry, unknown
    /// entry, non-empty directory). Surfaced by `complete` as `stagingCleanupError` —
    /// completion stays recorded; the residue is reaper territory.
    struct StagingCleanupBlocked: Error, CustomStringConvertible { let description: String }

    /// Everything staging cleanup needs, BOUND BEFORE the sentinel becomes durable. After
    /// publish no staging path (nor any subdirectory) is ever re-opened by URL — cleanup
    /// acts only through these pre-bound descriptors, so a post-publish swap of the staging
    /// tree at ANY level can only produce residue, never deletions inside a replacement.
    /// C11b's finalizer supplies `GatedStagedSnapshot.root` as `trustedStagingRoot` on the
    /// internal `complete` overload — then the root is never derived from a URL at all.
    struct StagingCleanupHandles {
        let parent: DirectoryHandle      // the Staging root, holding the import-<id> entry
        let entryName: String
        let root: DirectoryHandle        // the staging dir itself
        let attachments: DirectoryHandle?
        let docs: DirectoryHandle?
    }

    enum StagingCleanupPlan {
        case absent                      // nothing to clean (ENOENT at bind time)
        case bound(StagingCleanupHandles)
        case blocked(String)             // could not bind — surfaced post-completion, nothing touched
    }

    /// Acquire the cleanup evidence (pre-publish). Never throws: a staging tree that cannot
    /// be bound (symlink at the path, non-dir levels, metadata errors) becomes `.blocked` —
    /// completion proceeds and the problem is surfaced as `stagingCleanupError`.
    ///
    /// When the caller already HOLDS bound evidence (`trustedRoot`, e.g. C11b passing
    /// `GatedStagedSnapshot.root`), that handle IS the root — the staging URL is never
    /// re-opened; the parent is bound only to verify (and later remove) the entry, and the
    /// attachments/docs handles are bound fd-relative FROM the trusted root. A staging URL
    /// whose entry no longer resolves to the trusted root (a pre-swapped impostor) blocks
    /// with the impostor never bound, never entered.
    static func bindStagingForCleanup(stagingDir: URL, trustedRoot: DirectoryHandle? = nil) -> StagingCleanupPlan {
        let root: DirectoryHandle
        if let trustedRoot {
            root = trustedRoot
        } else {
            do { root = try DirectoryHandle.open(at: stagingDir) }
            catch let e as FileHashError where e.isFileMissing { return .absent }
            catch { return .blocked("staging bind: \(error)") }
        }
        let parent: DirectoryHandle
        do { parent = try DirectoryHandle.open(at: stagingDir.deletingLastPathComponent()) }
        catch { return .blocked("staging parent bind: \(error)") }
        let entryName = stagingDir.lastPathComponent
        do {
            guard let fp = try parent.fingerprint(named: entryName) else {
                // Entry definitively absent: already cleaned (nothing at the canonical name).
                return .absent
            }
            guard fp.isDirectory, fp.device == root.device, fp.inode == root.inode else {
                return .blocked("staging entry '\(entryName)' does not resolve to the bound directory")
            }
        } catch { return .blocked("staging entry fingerprint: \(error)") }
        var attachments: DirectoryHandle?
        var docs: DirectoryHandle?
        do {
            if let afp = try root.fingerprint(named: "attachments") {
                guard afp.isDirectory else { return .blocked("'attachments' is not a directory — left untouched") }
                let a = try root.subdirectory(named: "attachments")
                attachments = a
                if let dfp = try a.fingerprint(named: "docs") {
                    guard dfp.isDirectory else { return .blocked("'attachments/docs' is not a directory — left untouched") }
                    docs = try a.subdirectory(named: "docs")
                }
            }
        } catch { return .blocked("staging subtree bind: \(error)") }
        return .bound(StagingCleanupHandles(parent: parent, entryName: entryName, root: root,
                                            attachments: attachments, docs: docs))
    }

    /// Descriptor-rooted, known-tree staging cleanup over PRE-PUBLISH bound evidence. NEVER
    /// `FileManager.removeItem` on the staging path, and NEVER a fresh URL bind after the
    /// sentinel is durable: a path re-resolution at cleanup time would happily bind a
    /// structurally identical impostor swapped in during the publish window and delete
    /// inside it. Only entries this import's manifest declares are unlinked, strictly
    /// fd-relative (`removeNonDirectoryChild` — unlinkat flag 0, can never remove or
    /// recurse into a directory), with each directory level collapsed bottom-up via a
    /// bound-inode-checked AT_REMOVEDIR. Unknown entries, a replaced entry, or a non-empty
    /// directory are LEFT IN PLACE and surfaced as a cleanup error — never enumerated,
    /// never recursed; a swapped entry blocks with NOTHING deleted. ENOENT anywhere is an
    /// idempotent no-op, so a partially cleaned staging converges on re-run (which re-binds
    /// at ITS OWN entry, before ITS publish). Point-in-time residual (same class as
    /// `removeBoundChildDir`): the fingerprint→rmdir gap cannot be closed on Darwin — at
    /// worst an EMPTY foreign dir renamed onto the name in that gap is removed, never data.
    private static func cleanStaging(plan: StagingCleanupPlan, stagingDir: URL,
                                     manifest: ImportManifest, hooks: ApplyHooks) throws {
        if let override = hooks.cleanup { try override(stagingDir); return }
        let h: StagingCleanupHandles
        switch plan {
        case .absent: return                                            // already cleaned
        case .blocked(let why): throw StagingCleanupBlocked(description: why)
        case .bound(let handles): h = handles
        }

        // The entry must STILL resolve to the pre-publish bound tree; a swap during the
        // publish window leaves the replacement completely untouched (nothing deleted).
        guard let fp = try h.parent.fingerprint(named: h.entryName), fp.isDirectory,
              fp.device == h.root.device, fp.inode == h.root.inode else {
            throw StagingCleanupBlocked(description: "staging entry '\(h.entryName)' no longer resolves to the bound directory — nothing deleted")
        }

        try hooks.beforeStagingRemoval?(stagingDir)

        if let docs = h.docs {
            for f in manifest.files where f.outcome == .ingested {
                try docs.removeNonDirectoryChild(named: f.name)
            }
            guard let attachments = h.attachments else {
                throw StagingCleanupBlocked(description: "internal: docs handle without attachments handle")
            }
            try removeBoundEmptyDir(docs, named: "docs", in: attachments)
        }
        if let attachments = h.attachments {
            try removeBoundEmptyDir(attachments, named: "attachments", in: h.root)
        }
        try h.root.removeNonDirectoryChild(named: "manifest.json")
        try h.root.removeNonDirectoryChild(named: AppPaths.databaseFileName)
        try h.root.removeNonDirectoryChild(named: AppPaths.databaseFileName + "-wal")
        try removeBoundEmptyDir(h.root, named: h.entryName, in: h.parent)
    }

    /// Remove a directory ENTRY only while `name` still resolves (dir type, device+inode)
    /// to the BOUND handle the cleanup worked through. AT_REMOVEDIR refuses non-empty dirs
    /// (ENOTEMPTY ⇒ unknown entries remain ⇒ residue) and cannot follow a substituted
    /// symlink; a replaced entry is left untouched.
    private static func removeBoundEmptyDir(_ child: DirectoryHandle, named name: String,
                                            in parent: DirectoryHandle) throws {
        guard let fp = try parent.fingerprint(named: name), fp.isDirectory,
              fp.device == child.device, fp.inode == child.inode else {
            throw StagingCleanupBlocked(description: "'\(name)' no longer resolves to the bound directory — left untouched")
        }
        guard unlinkat(parent.fd, name, AT_REMOVEDIR) == 0 else {
            let e = errno
            if e == ENOENT { return }
            throw StagingCleanupBlocked(description: "rmdir '\(name)' failed (errno \(e)) — left for a reaper")
        }
    }

    private static func stagedDocsDir(_ stagingDir: URL) -> URL {
        stagingDir.appendingPathComponent("attachments", isDirectory: true).appendingPathComponent("docs", isDirectory: true)
    }

    private static func loadManifest(_ stagingDir: URL) throws -> ImportManifest {
        let url = stagingDir.appendingPathComponent("manifest.json")
        do { return try JSONDecoder().decode(ImportManifest.self, from: Data(contentsOf: url)) }
        catch { throw AttachmentApplyError.manifestUnreadable(url.path) }
    }
}
