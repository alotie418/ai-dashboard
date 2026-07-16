import Foundation
import CryptoKit

// MARK: - Streaming file hash

public enum FileHash {
    /// Streaming SHA-256 of a file as lowercase hex. Reads in chunks so a large DB or
    /// attachment never loads fully into memory. Size alone is NEVER treated as content
    /// equality — this is the content hash used when a decision needs true identity.
    public static func sha256Hex(of url: URL, chunkSize: Int = 1 << 20) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Attachment filename validation

public enum AttachmentName {
    /// The FILENAME portion of Electron's REL_RE `attachments/docs/[A-Za-z0-9][A-Za-z0-9._-]*`:
    /// a single path segment, first char alphanumeric, remaining chars in `[A-Za-z0-9._-]`,
    /// no `/`, no `..`. Non-ASCII fails (matching the ASCII regex).
    public static func isValid(_ name: String) -> Bool {
        guard !name.isEmpty, !name.contains("/"), !name.contains("..") else { return false }
        var first = true
        for ch in name.unicodeScalars {
            let isAlnum = (ch >= "A" && ch <= "Z") || (ch >= "a" && ch <= "z") || (ch >= "0" && ch <= "9")
            if first {
                if !isAlnum { return false }
                first = false
            } else if !(isAlnum || ch == "." || ch == "_" || ch == "-") {
                return false
            }
        }
        return true
    }
}

// MARK: - Source stability (concurrent-change detector)

/// A cheap fingerprint of the SOURCE, used ONLY to detect whether the source changed
/// DURING ingest (a live old Electron app still writing). Uses size + mtime — a write
/// bumps mtime — so it is a change-DETECTOR, never a content-equality proof.
struct SourceStabilityManifest: Equatable {
    struct Entry: Equatable { let name: String; let size: Int64; let mtime: TimeInterval }
    var db: Entry?
    var wal: Entry?
    var attachments: [Entry]   // ingest-set only, sorted by name
}

// MARK: - Import manifest (out-of-DB, per-import completion record)

/// The out-of-database, per-import record. Bound to an import ID, the source DB hash, an
/// attachment-set hash and per-file results. It is DELIBERATELY not a global `settings`
/// boolean: importing an old backup must never inherit a stale "attachments migrated" flag
/// and thereby skip copying. `report`/terminal statuses are filled by later apply stages.
public struct ImportManifest: Codable, Equatable {
    public enum Status: String, Codable { case ingested }

    public struct FileResult: Codable, Equatable {
        public enum Outcome: String, Codable {
            case ingested, skippedSymlink, skippedDirectory, skippedSpecial, rejectedName
        }
        public var name: String
        public var outcome: Outcome
        public var sha256: String?   // ingested files only
        public var size: Int64?      // ingested files only
    }

    public var importID: String
    public var sourceKind: String
    public var createdAt: String
    public var sourceDBSHA256: String
    /// Stable hash over the sorted set of ingested (name, sha256) — the attachment payload identity.
    public var attachmentManifestSHA256: String
    public var files: [FileResult]
    public var status: Status
    public var report: String?

    public var ingestedCount: Int { files.filter { $0.outcome == .ingested }.count }
    public var skippedCount: Int { files.filter { $0.outcome != .ingested }.count }
}

// MARK: - Ingest

public enum IngestError: Error, CustomStringConvertible {
    case sourceDatabaseMissing(String)
    /// The source kept changing across attempts — the old Electron app is likely still
    /// running and writing. The user must quit it and retry.
    case sourceBusy(attempts: Int)

    public var description: String {
        switch self {
        case .sourceDatabaseMissing(let p): return "Source database not found: \(p)"
        case .sourceBusy(let n): return "Source kept changing across \(n) attempts — quit the old SoloLedger (Electron) app and retry the import."
        }
    }
}

public struct IngestResult {
    public let importID: String
    public let stagingDir: URL
    public let stagedDatabaseURL: URL
    public let stagedWALURL: URL?
    public let stagedAttachmentsDir: URL?
    public let manifest: ImportManifest
}

/// Copies a `MigrationSource` into an isolated, native-owned staging directory, verifying
/// the source did not change during the copy. After it returns, NOTHING touches the
/// original source again — all later verify/swap/retry work reads from staging.
public struct StagingIngest {
    public init() {}

    /// Ingest `source` into `AppPaths.stagingDirectory(importID:)`. Copies the DB (and its
    /// `-wal` only when the source legitimately has one), then every REL_RE-conforming
    /// REGULAR attachment file; symlinks, special files, nested directories and
    /// illegally-named entries are SKIPPED and recorded, never ingested. Re-fingerprints
    /// the source before/after and retries on change, throwing `.sourceBusy` when exhausted.
    @discardableResult
    public func ingest(_ source: MigrationSource,
                       importID: String = UUID().uuidString.lowercased(),
                       timestamp: String = DateFormat.timestamp()) throws -> IngestResult {
        try ingest(source, importID: importID, timestamp: timestamp, maxAttempts: 3, midAttemptHook: nil)
    }

    /// Internal test entry point: adds an attempt bound and a fault seam invoked mid-attempt
    /// (after the copy, before the after-fingerprint) so a test can mutate the source to
    /// exercise the concurrent-change retry / `.sourceBusy` path. NOT part of the public API.
    @discardableResult
    func ingest(_ source: MigrationSource, importID: String, timestamp: String,
                maxAttempts: Int, midAttemptHook: ((Int) throws -> Void)?) throws -> IngestResult {
        let dbURL = try source.databaseURL()
        return try source.withAccess {
            guard FileManager.default.fileExists(atPath: dbURL.path) else {
                throw IngestError.sourceDatabaseMissing(dbURL.path)
            }
            var attempt = 0
            while true {
                attempt += 1
                let stagingDir = try AppPaths.stagingDirectory(importID: importID)

                let before = try Self.stability(source)
                let staged = try Self.copyInto(stagingDir, source: source, dbURL: dbURL)
                try midAttemptHook?(attempt)
                let after = try Self.stability(source)

                if before != after {
                    try? FileManager.default.removeItem(at: stagingDir)
                    if attempt >= maxAttempts { throw IngestError.sourceBusy(attempts: attempt) }
                    continue
                }

                let manifest = try Self.buildManifest(importID: importID, source: source,
                                                      timestamp: timestamp, staged: staged)
                try Self.writeManifest(manifest, to: stagingDir)
                return IngestResult(importID: importID, stagingDir: stagingDir,
                                    stagedDatabaseURL: staged.dbURL, stagedWALURL: staged.walURL,
                                    stagedAttachmentsDir: staged.attachmentsDir, manifest: manifest)
            }
        }
    }

    // MARK: - Internals

    private struct ClassifiedAttachment {
        let url: URL
        let name: String
        let outcome: ImportManifest.FileResult.Outcome
        var isIngested: Bool { outcome == .ingested }
    }

    /// Classify the TOP-LEVEL entries of an attachments root (never recursive). Order:
    /// symlink (lstat, not followed) → directory → regular file (name-validated) → special.
    private static func enumerateAttachments(root: URL) throws -> [ClassifiedAttachment] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { return [] }
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]
        let entries = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: keys, options: [])
        var out: [ClassifiedAttachment] = []
        for url in entries {
            let name = url.lastPathComponent
            let v = try url.resourceValues(forKeys: Set(keys))
            let outcome: ImportManifest.FileResult.Outcome
            if v.isSymbolicLink == true {
                outcome = .skippedSymlink
            } else if v.isDirectory == true {
                outcome = .skippedDirectory
            } else if v.isRegularFile == true {
                outcome = AttachmentName.isValid(name) ? .ingested : .rejectedName
            } else {
                outcome = .skippedSpecial
            }
            out.append(ClassifiedAttachment(url: url, name: name, outcome: outcome))
        }
        return out.sorted { $0.name < $1.name }
    }

    private static func stability(_ source: MigrationSource) throws -> SourceStabilityManifest {
        let fm = FileManager.default
        func entry(_ url: URL, name: String) -> SourceStabilityManifest.Entry? {
            guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { return nil }
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? -1
            let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
            return .init(name: name, size: size, mtime: mtime)
        }
        let db = entry(try source.databaseURL(), name: "db")
        var wal: SourceStabilityManifest.Entry?
        if let w = try source.walURL(), fm.fileExists(atPath: w.path) { wal = entry(w, name: "wal") }
        var atts: [SourceStabilityManifest.Entry] = []
        if let root = try source.attachmentsRootURL() {
            for c in try enumerateAttachments(root: root) where c.isIngested {
                if let e = entry(c.url, name: c.name) { atts.append(e) }
            }
        }
        return SourceStabilityManifest(db: db, wal: wal, attachments: atts.sorted { $0.name < $1.name })
    }

    private struct StagedLayout {
        let dbURL: URL
        let walURL: URL?
        let attachmentsDir: URL?
        let fileResults: [ImportManifest.FileResult]   // sha/size filled later
    }

    private static func copyInto(_ stagingDir: URL, source: MigrationSource, dbURL: URL) throws -> StagedLayout {
        let fm = FileManager.default
        // Fresh staging each attempt: clear any prior contents.
        if let items = try? fm.contentsOfDirectory(at: stagingDir, includingPropertiesForKeys: nil) {
            for i in items { try? fm.removeItem(at: i) }
        }

        let stagedDB = stagingDir.appendingPathComponent(AppPaths.databaseFileName)
        try fm.copyItem(at: dbURL, to: stagedDB)

        var stagedWAL: URL?
        if let w = try source.walURL(), fm.fileExists(atPath: w.path) {
            let dst = URL(fileURLWithPath: stagedDB.path + "-wal")
            try fm.copyItem(at: w, to: dst)
            stagedWAL = dst
        }

        var stagedAttachDir: URL?
        var results: [ImportManifest.FileResult] = []
        if let root = try source.attachmentsRootURL() {
            let classified = try enumerateAttachments(root: root)
            if !classified.isEmpty {
                let dstRoot = stagingDir.appendingPathComponent("attachments", isDirectory: true)
                    .appendingPathComponent("docs", isDirectory: true)
                try fm.createDirectory(at: dstRoot, withIntermediateDirectories: true)
                stagedAttachDir = dstRoot
                for c in classified {
                    if c.isIngested {
                        try fm.copyItem(at: c.url, to: dstRoot.appendingPathComponent(c.name))
                    }
                    results.append(.init(name: c.name, outcome: c.outcome, sha256: nil, size: nil))
                }
            }
        }
        return StagedLayout(dbURL: stagedDB, walURL: stagedWAL, attachmentsDir: stagedAttachDir, fileResults: results)
    }

    private static func buildManifest(importID: String, source: MigrationSource,
                                      timestamp: String, staged: StagedLayout) throws -> ImportManifest {
        let dbHash = try FileHash.sha256Hex(of: staged.dbURL)
        var files: [ImportManifest.FileResult] = []
        for r in staged.fileResults {
            if r.outcome == .ingested, let dir = staged.attachmentsDir {
                let f = dir.appendingPathComponent(r.name)
                let sha = try FileHash.sha256Hex(of: f)
                let size = (try? FileManager.default.attributesOfItem(atPath: f.path))
                    .flatMap { ($0[.size] as? NSNumber)?.int64Value }
                files.append(.init(name: r.name, outcome: .ingested, sha256: sha, size: size))
            } else {
                files.append(r)
            }
        }
        files.sort { $0.name < $1.name }
        return ImportManifest(importID: importID, sourceKind: source.kind, createdAt: timestamp,
                              sourceDBSHA256: dbHash, attachmentManifestSHA256: attachmentSetHash(files),
                              files: files, status: .ingested, report: nil)
    }

    /// Stable hash over the sorted ingested (name, sha256) set — the attachment payload identity.
    private static func attachmentSetHash(_ files: [ImportManifest.FileResult]) -> String {
        let lines = files.filter { $0.outcome == .ingested }
            .sorted { $0.name < $1.name }
            .map { "\($0.name)\u{0}\($0.sha256 ?? "")" }
            .joined(separator: "\n")
        return SHA256.hash(data: Data(lines.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func writeManifest(_ manifest: ImportManifest, to stagingDir: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(manifest).write(to: stagingDir.appendingPathComponent("manifest.json"))
    }
}
