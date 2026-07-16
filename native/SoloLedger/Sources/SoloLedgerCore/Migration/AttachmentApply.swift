import Foundation

/// A plan for applying a staged import's attachments to the active dir, computed WITHOUT
/// writing anything. The coordinator runs this as a PRE-SWAP gate: if `hasConflicts`, the
/// DB swap must be blocked and the conflicts reported — a same-name-different-content file
/// is NEVER overwritten.
public struct AttachmentPlan: Equatable {
    public struct Conflict: Equatable {
        public let name: String
        public let stagedSHA256: String
        public let activeSHA256: String
    }
    /// Absent in the active dir → will be copied.
    public var toCopy: [String]
    /// Present with an identical SHA-256 → will be skipped (idempotent).
    public var identical: [String]
    /// Present with a DIFFERENT SHA-256 → blocks the apply; never overwritten.
    public var conflicts: [Conflict]
    /// Listed in the manifest but absent from staging on disk → itemized, not copied.
    public var missing: [String]

    public var hasConflicts: Bool { !conflicts.isEmpty }
}

public enum AttachmentApplyError: Error, CustomStringConvertible {
    case manifestUnreadable(String)
    /// Same-name, different-content files exist in the active dir. Reported BEFORE any DB
    /// swap; nothing is copied and nothing is overwritten.
    case conflicts([AttachmentPlan.Conflict])
    /// A target file appeared with different content between plan and copy (a race guard);
    /// never overwritten.
    case conflictDuringApply(String)

    public var description: String {
        switch self {
        case .manifestUnreadable(let p): return "Staged import manifest is unreadable: \(p)"
        case .conflicts(let c): return "Attachment conflicts (same name, different content) — resolve before importing: \(c.map { $0.name }.joined(separator: ", "))"
        case .conflictDuringApply(let n): return "Attachment '\(n)' changed under us during apply — refusing to overwrite"
        }
    }
}

public struct ApplyResult: Equatable {
    public let importID: String
    public let copied: [String]
    public let skippedIdentical: [String]
    public let missing: [String]
    /// The persisted per-import completion sentinel (`ImportManifests/<id>.json`).
    public let completionSentinelURL: URL
    /// False when staging could not be removed AFTER completion was recorded — the import IS
    /// complete, but a `Staging/import-<id>` residue remains for a later reaper to collect.
    public let stagingCleaned: Bool
    public let stagingCleanupError: String?
}

/// Non-destructive, idempotent attachment application + per-import completion sentinel.
///
/// ORDERING GUARANTEES:
///  - `plan` is side-effect-free and is the PRE-SWAP conflict gate.
///  - `apply` copies ONLY absent files (`.part` + rename, atomic per file), skips
///    byte-identical ones, NEVER overwrites, and refuses on any same-name-different-content
///    file (blocking before a DB swap).
///  - The final manifest/report is ATOMICALLY persisted to `ImportManifests` (temp write →
///    rename) FIRST; only AFTER that succeeds is staging cleaned.
///  - On any failure (or crash) before the completion sentinel is published, staging is KEPT
///    so a later run resumes idempotently. A staging-cleanup failure AFTER completion is
///    non-fatal (surfaced), leaving a residue for a future age-bounded reaper.
public struct AttachmentApply {
    public init() {}

    /// Side-effect-free classification of the staged import against the active dir.
    public func plan(stagingDir: URL, activeAttachmentsDir: URL) throws -> AttachmentPlan {
        let manifest = try Self.loadManifest(stagingDir)
        return try Self.buildPlan(manifest: manifest, stagingDir: stagingDir, activeDir: activeAttachmentsDir)
    }

    /// Apply the staged import to the active attachments dir, persist the completion
    /// sentinel, then clean staging. Throws `.conflicts` (blocking) if any same-name file
    /// differs. Idempotent: a re-run copies only still-absent files and re-completes.
    @discardableResult
    public func apply(stagingDir: URL, activeAttachmentsDir: URL) throws -> ApplyResult {
        try apply(stagingDir: stagingDir, activeAttachmentsDir: activeAttachmentsDir,
                  manifestsDir: try AppPaths.importManifestsDirectory(), hooks: ApplyHooks())
    }

    /// Internal entry point with injectable manifests dir + fault seams (test-only).
    @discardableResult
    func apply(stagingDir: URL, activeAttachmentsDir: URL, manifestsDir: URL, hooks: ApplyHooks) throws -> ApplyResult {
        let manifest = try Self.loadManifest(stagingDir)
        let plan = try Self.buildPlan(manifest: manifest, stagingDir: stagingDir, activeDir: activeAttachmentsDir)

        // PRE-SWAP gate: any same-name-different-content file blocks — never overwrite.
        if plan.hasConflicts { throw AttachmentApplyError.conflicts(plan.conflicts) }

        let fm = FileManager.default
        try fm.createDirectory(at: activeAttachmentsDir, withIntermediateDirectories: true)

        let stagedDocs = Self.stagedDocsDir(stagingDir)
        for name in plan.toCopy {
            let src = stagedDocs.appendingPathComponent(name)
            let dst = activeAttachmentsDir.appendingPathComponent(name)
            try Self.copyNonDestructive(from: src, to: dst, name: name, hooks: hooks)
        }

        // Build + ATOMICALLY persist the completion sentinel BEFORE cleaning staging.
        var final = manifest
        final.status = .complete
        final.applied = ImportManifest.AppliedSummary(copied: plan.toCopy,
                                                      skippedIdentical: plan.identical,
                                                      missing: plan.missing)
        final.report = Self.report(plan: plan)
        let sentinelURL = try Self.persistCompletion(final, importID: manifest.importID,
                                                     manifestsDir: manifestsDir, hooks: hooks)

        // Only now clean staging. A cleanup failure is surfaced but does NOT undo completion
        // (the import is already complete); the residue is left for a future reaper.
        var cleanupError: String?
        do {
            try Self.cleanStaging(stagingDir, hooks: hooks)
        } catch {
            cleanupError = "\(error)"
        }

        return ApplyResult(importID: manifest.importID, copied: plan.toCopy,
                           skippedIdentical: plan.identical, missing: plan.missing,
                           completionSentinelURL: sentinelURL,
                           stagingCleaned: cleanupError == nil, stagingCleanupError: cleanupError)
    }

    // MARK: - Internals

    private static func stagedDocsDir(_ stagingDir: URL) -> URL {
        stagingDir.appendingPathComponent("attachments", isDirectory: true).appendingPathComponent("docs", isDirectory: true)
    }

    private static func loadManifest(_ stagingDir: URL) throws -> ImportManifest {
        let url = stagingDir.appendingPathComponent("manifest.json")
        do {
            return try JSONDecoder().decode(ImportManifest.self, from: Data(contentsOf: url))
        } catch {
            throw AttachmentApplyError.manifestUnreadable(url.path)
        }
    }

    private static func buildPlan(manifest: ImportManifest, stagingDir: URL, activeDir: URL) throws -> AttachmentPlan {
        let fm = FileManager.default
        let stagedDocs = stagedDocsDir(stagingDir)
        var toCopy: [String] = [], identical: [String] = [], missing: [String] = []
        var conflicts: [AttachmentPlan.Conflict] = []

        for f in manifest.files where f.outcome == .ingested {
            let staged = stagedDocs.appendingPathComponent(f.name)
            guard fm.fileExists(atPath: staged.path) else { missing.append(f.name); continue }
            let stagedSHA = try f.sha256 ?? FileHash.sha256Hex(of: staged)
            let active = activeDir.appendingPathComponent(f.name)
            if !fm.fileExists(atPath: active.path) {
                toCopy.append(f.name)
            } else {
                let activeSHA = try FileHash.sha256Hex(of: active)
                if activeSHA == stagedSHA {
                    identical.append(f.name)
                } else {
                    conflicts.append(.init(name: f.name, stagedSHA256: stagedSHA, activeSHA256: activeSHA))
                }
            }
        }
        return AttachmentPlan(toCopy: toCopy.sorted(), identical: identical.sorted(),
                              conflicts: conflicts.sorted { $0.name < $1.name }, missing: missing.sorted())
    }

    /// Copy `src` → `dst` only if `dst` is absent (non-destructive). If `dst` appeared and is
    /// byte-identical, skip; if it differs, refuse (never overwrite). Uses `.part` + rename
    /// so a partial copy never appears as a complete attachment.
    private static func copyNonDestructive(from src: URL, to dst: URL, name: String, hooks: ApplyHooks) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dst.path) {
            let dstSHA = try FileHash.sha256Hex(of: dst)
            let srcSHA = try FileHash.sha256Hex(of: src)
            if dstSHA == srcSHA { return }                             // identical → skip
            throw AttachmentApplyError.conflictDuringApply(name)       // differs → never overwrite
        }
        try hooks.onAttachmentCopy?(name)
        let part = URL(fileURLWithPath: dst.path + ".part")
        if fm.fileExists(atPath: part.path) { try fm.removeItem(at: part) }   // drop a stale part (explicit, not try?)
        try fm.copyItem(at: src, to: part)
        try fm.moveItem(at: part, to: dst)   // atomic per-file publish
    }

    private static func report(plan: AttachmentPlan) -> String {
        var s = "attachments: copied \(plan.toCopy.count), identical \(plan.identical.count)"
        if !plan.missing.isEmpty { s += ", MISSING \(plan.missing.count) (\(plan.missing.joined(separator: ", ")))" }
        return s
    }

    /// Atomically persist the completion sentinel: write a temp file, then rename it onto
    /// `ImportManifests/<id>.json`. Two named fault points model temp-write vs publish failure.
    private static func persistCompletion(_ manifest: ImportManifest, importID: String,
                                          manifestsDir: URL, hooks: ApplyHooks) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: manifestsDir, withIntermediateDirectories: true)
        let finalURL = manifestsDir.appendingPathComponent("\(importID).json")
        let tmpURL = manifestsDir.appendingPathComponent(".tmp-\(importID)-\(UUID().uuidString).json")

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(manifest)

        try hooks.onCompletionTempWrite?()   // "manifest write" fault
        try data.write(to: tmpURL)
        do {
            try hooks.onCompletionPublish?()  // "completion-state write" (publish) fault
            if fm.fileExists(atPath: finalURL.path) {
                _ = try fm.replaceItemAt(finalURL, withItemAt: tmpURL)   // idempotent re-complete
            } else {
                try fm.moveItem(at: tmpURL, to: finalURL)
            }
        } catch let publishError {
            // Publish failed → the sentinel is NOT recorded, so staging is KEPT. Best-effort
            // drop the unpublished temp; if that also fails, the publish error dominates and
            // the orphan temp is left for the reaper (deliberately not masked with try?).
            if fm.fileExists(atPath: tmpURL.path) {
                do { try fm.removeItem(at: tmpURL) } catch { /* leave orphan temp; publish error dominates */ }
            }
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
}

/// Test-only fault seams (all `internal`, defaulting to no-op). The public `apply` never
/// exposes them; only the `@testable` test target can inject failures.
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
