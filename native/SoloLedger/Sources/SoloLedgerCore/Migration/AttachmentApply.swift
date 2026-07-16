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
        self.items = items.sorted { ($0.kind.rawValue, $0.name) < ($1.kind.rawValue, $1.name) }
    }
    public var isEmpty: Bool { items.isEmpty }
    /// Stable hash over the sorted (kind, name) set. Any change — e.g. new dangling refs added
    /// by the DB audit — changes this hash, so an acknowledgement of an OLD report can never
    /// confirm a CHANGED one.
    public var reportHash: String {
        let s = items.map { "\($0.kind.rawValue)\u{0}\($0.name)" }.joined(separator: "\n")
        return SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func merged(with extra: [Item]) -> UnresolvedReport { UnresolvedReport(items: items + extra) }
}

// MARK: - Reference audit + acknowledgement

/// The DB reference audit the coordinator runs AFTER the active DB exists: whether it was
/// actually performed, and which attachment reference values the ledger points at resolve to
/// no present file. `complete` REFUSES to finalize unless `performed` is true, and records
/// that fact in the sentinel — so "audited, nothing dangling" is never confused with
/// "not yet audited". An empty `danglingReferences` with `performed == false` is explicitly
/// NOT a clean audit.
public struct ReferenceAudit: Equatable {
    public let performed: Bool
    public let danglingReferences: [String]
    public init(performed: Bool, danglingReferences: [String]) {
        self.performed = performed; self.danglingReferences = danglingReferences
    }
    /// The audit RAN and found the given dangling references (empty ⇒ clean).
    public static func audited(danglingReferences: [String] = []) -> ReferenceAudit {
        ReferenceAudit(performed: true, danglingReferences: danglingReferences)
    }
    /// The audit has NOT run — `complete` will refuse with `.referenceAuditNotPerformed`.
    public static let notPerformed = ReferenceAudit(performed: false, danglingReferences: [])
}

/// A user acknowledgement, bound to the exact unresolved-report hash it confirms.
public struct Acknowledgement: Equatable {
    public let reportHash: String
    public init(reportHash: String) { self.reportHash = reportHash }
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
    case referenceAuditNotPerformed

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
        case .referenceAuditNotPerformed: return "Refusing to complete: the DB reference audit has not been run (referenceAudit.performed == false)"
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
    public let applied: ImportManifest.AppliedSummary
    /// Missing staged files + ingest-stage skips. The DB reference audit's dangling refs are
    /// merged in at `complete` time.
    public let fileUnresolved: UnresolvedReport
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
    /// Unresolved items remain (files and/or dangling refs). The caller must obtain a user
    /// acknowledgement bound to `reportHash` and call `complete` again. Nothing was persisted;
    /// staging is kept.
    case requiresAcknowledgement(reportHash: String, unresolved: UnresolvedReport)
}

/// Test-only fault seams (all `internal`, defaulting to no-op).
struct ApplyHooks {
    var onAttachmentCopy: ((String) throws -> Void)?
    var onCompletionTempWrite: (() throws -> Void)?
    var onCompletionPublish: (() throws -> Void)?
    var cleanup: ((URL) throws -> Void)?
    init(onAttachmentCopy: ((String) throws -> Void)? = nil,
         onCompletionTempWrite: (() throws -> Void)? = nil,
         onCompletionPublish: (() throws -> Void)? = nil,
         cleanup: ((URL) throws -> Void)? = nil) {
        self.onAttachmentCopy = onAttachmentCopy
        self.onCompletionTempWrite = onCompletionTempWrite
        self.onCompletionPublish = onCompletionPublish
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
///  - `complete` merges the coordinator's DB reference audit, and only if there are no
///    unresolved items (or a matching acknowledgement) re-verifies every final active file
///    hash, ATOMICALLY persists the completion sentinel, then cleans staging.
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
    /// report ACTUAL outcomes + file-level unresolved items. No sentinel, no staging cleanup.
    public func apply(stagingDir: URL, activeAttachmentsDir: URL) throws -> AttachmentApplyReport {
        try apply(stagingDir: stagingDir, activeAttachmentsDir: activeAttachmentsDir, hooks: ApplyHooks())
    }

    /// Finalize: merge the DB reference audit, gate on acknowledgement if anything is
    /// unresolved, re-verify active files, persist the sentinel, then clean staging.
    @discardableResult
    public func complete(report: AttachmentApplyReport, referenceAudit: ReferenceAudit,
                         acknowledgement: Acknowledgement?) throws -> CompleteOutcome {
        try complete(report: report, referenceAudit: referenceAudit, acknowledgement: acknowledgement,
                     manifestsDir: try AppPaths.importManifestsDirectory(), hooks: ApplyHooks())
    }

    // MARK: - Internal (fault seams / injectable dirs)

    func apply(stagingDir: URL, activeAttachmentsDir: URL, hooks: ApplyHooks) throws -> AttachmentApplyReport {
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
                                     applied: applied, fileUnresolved: Self.fileUnresolved(v))
    }

    func complete(report: AttachmentApplyReport, referenceAudit: ReferenceAudit,
                  acknowledgement: Acknowledgement?, manifestsDir: URL, hooks: ApplyHooks) throws -> CompleteOutcome {
        // The attachment migration is never `complete` until the DB references were audited.
        guard referenceAudit.performed else { throw AttachmentApplyError.referenceAuditNotPerformed }
        let dangling = referenceAudit.danglingReferences.map { UnresolvedReport.Item(name: $0, kind: .danglingReference) }
        let unresolved = report.fileUnresolved.merged(with: dangling)
        let reportHash = unresolved.reportHash

        // Acknowledgement gate: unresolved ⇒ no auto-complete, no staging cleanup. A stale ack
        // (bound to a different hash) is treated as no ack.
        if !unresolved.isEmpty {
            guard let ack = acknowledgement, ack.reportHash == reportHash else {
                return .requiresAcknowledgement(reportHash: reportHash, unresolved: unresolved)
            }
        }

        // Re-verify EVERY final active file against the manifest SHA (catch post-plan changes).
        let expected = Dictionary(uniqueKeysWithValues:
            report.manifest.files.filter { $0.outcome == .ingested }.compactMap { f in f.sha256.map { (f.name, $0) } })
        for name in report.applied.copied + report.applied.skippedIdentical {
            let active = report.activeAttachmentsDir.appendingPathComponent(name)
            guard let exp = expected[name], FileManager.default.fileExists(atPath: active.path) else {
                throw AttachmentApplyError.activeFileHashMismatch(name)
            }
            let actual = try FileHash.sha256Hex(of: active)
            guard actual == exp else { throw AttachmentApplyError.activeFileHashMismatch(name) }
        }

        var final = report.manifest
        final.status = .complete
        final.applied = report.applied
        final.unresolved = unresolved
        final.acknowledgedReportHash = unresolved.isEmpty ? nil : reportHash
        final.referenceAuditPerformed = true
        final.report = Self.reportString(applied: report.applied, unresolved: unresolved)

        let sentinelURL = try Self.persistCompletion(final, importID: report.importID, manifestsDir: manifestsDir, hooks: hooks)

        var cleanupError: String?
        do { try Self.cleanStaging(report.stagingDir, hooks: hooks) } catch { cleanupError = "\(error)" }

        return .completed(ApplyResult(importID: report.importID.rawValue, applied: report.applied,
                                      unresolved: unresolved, completionSentinelURL: sentinelURL,
                                      stagingCleaned: cleanupError == nil, stagingCleanupError: cleanupError))
    }

    // MARK: - Validation (fail-closed)

    struct ValidatedFile { let name: String; let expectedSHA: String; let staged: URL; let present: Bool }
    struct ValidatedStaging { let importID: ImportID; let manifest: ImportManifest; let files: [ValidatedFile] }

    static func validate(stagingDir: URL) throws -> ValidatedStaging {
        let manifest = try loadManifest(stagingDir)
        // Reconstruct + validate a strongly-typed ImportID — never use the raw string for paths.
        guard let importID = ImportID(manifest.importID) else {
            throw AttachmentApplyError.invalidImportID(manifest.importID)
        }
        // The manifest's own hash must match its recorded file set (catches tampered names/hashes).
        guard ImportManifest.attachmentSetHash(manifest.files) == manifest.attachmentManifestSHA256 else {
            throw AttachmentApplyError.attachmentManifestHashMismatch
        }

        let fm = FileManager.default
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
            let present = fm.fileExists(atPath: staged.path)
            if present {
                let actual = try FileHash.sha256Hex(of: staged)
                guard actual == expected else { throw AttachmentApplyError.stagedFileHashMismatch(f.name) }
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
        let fm = FileManager.default
        var toCopy: [String] = [], identical: [String] = [], missing: [String] = []
        var conflicts: [AttachmentPlan.Conflict] = []
        for vf in validated.files {
            if !vf.present { missing.append(vf.name); continue }
            let active = activeDir.appendingPathComponent(vf.name)
            if !fm.fileExists(atPath: active.path) { toCopy.append(vf.name); continue }
            let activeSHA = try FileHash.sha256Hex(of: active)
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
    private static func copyNonDestructive(from src: URL, to dst: URL, name: String,
                                           expectedSHA: String, hooks: ApplyHooks) throws -> CopyOutcome {
        let fm = FileManager.default
        if fm.fileExists(atPath: dst.path) {
            let dstSHA = try FileHash.sha256Hex(of: dst)
            if dstSHA == expectedSHA { return .skippedIdenticalRace }
            throw AttachmentApplyError.conflictDuringApply(name)
        }
        try hooks.onAttachmentCopy?(name)

        let part = URL(fileURLWithPath: dst.path + ".part-\(UUID().uuidString)")
        var published = false
        defer {
            if !published, fm.fileExists(atPath: part.path) {
                do { try fm.removeItem(at: part) } catch { /* leave this round's part for a reaper */ }
            }
        }
        try fm.copyItem(at: src, to: part)
        let partSHA = try FileHash.sha256Hex(of: part)
        guard partSHA == expectedSHA else { throw AttachmentApplyError.stagedFileHashMismatch(name) }
        if fm.fileExists(atPath: dst.path) {   // race: dst appeared during our copy
            let dstSHA = try FileHash.sha256Hex(of: dst)
            if dstSHA == expectedSHA { return .skippedIdenticalRace }   // defer cleans the part
            throw AttachmentApplyError.conflictDuringApply(name)
        }
        try fm.moveItem(at: part, to: dst)
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

    private static func persistCompletion(_ manifest: ImportManifest, importID: ImportID,
                                          manifestsDir: URL, hooks: ApplyHooks) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: manifestsDir, withIntermediateDirectories: true)
        let finalURL = manifestsDir.appendingPathComponent("\(importID.rawValue).json")

        // Idempotency: an existing sentinel for this ID may be replaced ONLY if it has the
        // SAME snapshot + attachment-set identity; otherwise REJECT (never overwrite).
        if fm.fileExists(atPath: finalURL.path) {
            let existing = try? JSONDecoder().decode(ImportManifest.self, from: Data(contentsOf: finalURL))
            guard let existing,
                  existing.snapshotIdentitySHA256 == manifest.snapshotIdentitySHA256,
                  existing.attachmentManifestSHA256 == manifest.attachmentManifestSHA256 else {
                throw AttachmentApplyError.sentinelIdentityMismatch(importID.rawValue)
            }
        }

        let tmpURL = manifestsDir.appendingPathComponent(".tmp-\(importID.rawValue)-\(UUID().uuidString).json")
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(manifest)

        try hooks.onCompletionTempWrite?()
        try data.write(to: tmpURL)
        do {
            try hooks.onCompletionPublish?()
            if fm.fileExists(atPath: finalURL.path) { _ = try fm.replaceItemAt(finalURL, withItemAt: tmpURL) }
            else { try fm.moveItem(at: tmpURL, to: finalURL) }
        } catch let publishError {
            if fm.fileExists(atPath: tmpURL.path) { do { try fm.removeItem(at: tmpURL) } catch { /* orphan temp → reaper */ } }
            throw publishError
        }
        return finalURL
    }

    private static func cleanStaging(_ stagingDir: URL, hooks: ApplyHooks) throws {
        if let override = hooks.cleanup { try override(stagingDir); return }
        if FileManager.default.fileExists(atPath: stagingDir.path) {
            try FileManager.default.removeItem(at: stagingDir)   // NOT try? — surfaced by the caller
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
