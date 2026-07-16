import Foundation

// MARK: - Reference audit evidence

/// Un-forgeable DB-reference-audit evidence, BOUND to the exact import it scanned: the
/// importID, the snapshot identity (DB+WAL), the attachment-manifest identity, and the
/// prepared DB it audited. `complete` matches every field against the report and rejects any
/// cross-import / cross-snapshot / cross-database audit. The initializer is INTERNAL, so only
/// Core (`AttachmentReferenceAuditor`) and `@testable` tests can construct evidence — a
/// production caller can never fabricate an audit.
public struct ReferenceAudit: Equatable {
    public let importID: String
    public let snapshotIdentitySHA256: String
    public let attachmentManifestSHA256: String
    public let preparedDBIdentity: String

    /// A DB reference that resolved to a REGULAR file in the active dir at audit time,
    /// with the content hash observed — `complete` re-verifies every one before the
    /// sentinel is persisted, so a file deleted or replaced after the audit fails closed.
    public struct ResolvedReference: Equatable {
        public let name: String        // bare filename inside the active attachments dir
        public let sha256: String      // content hash observed at audit time
        public let provenance: String  // normalized "table.column×rows[; …]"
    }
    /// A syntactically valid reference with no usable regular file behind it (absent, or
    /// present as a symlink/directory/special file — those are NEVER treated as resolved).
    public struct DanglingReference: Equatable {
        public let name: String
        public let provenance: String
    }
    /// A stored value that is not a well-formed reference at all: wrong prefix, traversal,
    /// absolute path, illegal name, or a non-TEXT column value (typed placeholder).
    public struct InvalidReference: Equatable {
        public let value: String
        public let provenance: String
    }

    public let resolved: [ResolvedReference]
    public let dangling: [DanglingReference]
    public let invalid: [InvalidReference]

    init(importID: String, snapshotIdentitySHA256: String, attachmentManifestSHA256: String,
         preparedDBIdentity: String, resolved: [ResolvedReference] = [],
         dangling: [DanglingReference] = [], invalid: [InvalidReference] = []) {
        self.importID = importID
        self.snapshotIdentitySHA256 = snapshotIdentitySHA256
        self.attachmentManifestSHA256 = attachmentManifestSHA256
        self.preparedDBIdentity = preparedDBIdentity
        self.resolved = resolved
        self.dangling = dangling
        self.invalid = invalid
    }
}

// MARK: - Auditor

/// The ONLY sanctioned producer of `ReferenceAudit` evidence. Scans the prepared database's
/// authoritative attachment-reference columns via a strictly READ-ONLY connection and
/// classifies every stored value against the active attachments dir. Fail-closed at every
/// step: the DB must pass the `PreparedDatabaseIdentity` quiescence gate and match the
/// report's identity; a corrupt file, an unexpected `user_version`, a missing table or
/// column all abort the audit (never "zero references"); and the identity is recomputed
/// after the scan so a database that changed underneath is rejected.
public struct AttachmentReferenceAuditor {

    /// The authoritative reference columns — mirrored from the Electron schema
    /// (`electron/db/index.js`), which stores verbatim `attachments/docs/<name>` strings.
    struct ReferenceColumn {
        let table: String
        let column: String
        var key: String { "\(table).\(column)" }
    }
    static let referenceColumns = [
        ReferenceColumn(table: "transactions", column: "attachment_path"),
        ReferenceColumn(table: "business_documents", column: "tax_invoice_attachment_path"),
    ]

    /// Test-only fault seam, fires between the scan (connection closed) and the closing
    /// identity re-check.
    struct AuditHooks {
        var afterScan: (() throws -> Void)?
        init(afterScan: (() throws -> Void)? = nil) { self.afterScan = afterScan }
    }

    public init() {}

    public func audit(report: AttachmentApplyReport, preparedDatabaseAt url: URL) throws -> ReferenceAudit {
        try audit(report: report, preparedDatabaseAt: url, hooks: AuditHooks())
    }

    func audit(report: AttachmentApplyReport, preparedDatabaseAt url: URL, hooks: AuditHooks) throws -> ReferenceAudit {
        // Identity gate: recompute from the actual file (quiescence enforced inside) and
        // require it to be the database this import was applied against.
        let identity = try PreparedDatabaseIdentity.compute(at: url)
        guard identity == report.preparedDBIdentity else {
            throw AttachmentApplyError.preparedDatabaseIdentityMismatch(expected: report.preparedDBIdentity, actual: identity)
        }

        // Occurrences per stored value, aggregated per column: value → column key → rows.
        var validCounts: [String: [String: Int]] = [:]     // bare name
        var invalidCounts: [String: [String: Int]] = [:]   // illegal value (or typed placeholder)
        func bump(_ dict: inout [String: [String: Int]], _ value: String, _ column: String) {
            dict[value, default: [:]][column, default: 0] += 1
        }

        do {
            let db = try SQLiteDatabase(path: url.path, readOnly: true)
            try db.execute("PRAGMA query_only = ON")
            guard try db.scalar("PRAGMA quick_check").stringValue == "ok" else {
                throw AttachmentApplyError.preparedDatabaseCorrupt("PRAGMA quick_check != ok")
            }
            let version = try db.userVersion()
            guard version == SchemaMigrator.schemaVersion else {
                throw AttachmentApplyError.preparedDatabaseSchemaUnsupported(
                    "user_version \(version), expected \(SchemaMigrator.schemaVersion)")
            }
            for col in Self.referenceColumns {
                guard try !db.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
                                    [.text(col.table)]).isEmpty else {
                    throw AttachmentApplyError.preparedDatabaseSchemaUnsupported("missing table '\(col.table)'")
                }
                let columns = try db.query("PRAGMA table_info(\(col.table))").compactMap { row -> String? in
                    guard case .text(let n) = row["name"] else { return nil }
                    return n
                }
                guard columns.contains(col.column) else {
                    throw AttachmentApplyError.preparedDatabaseSchemaUnsupported("missing column '\(col.key)'")
                }
                // Match the RAW SQLiteValue — never a string accessor that would coerce
                // numeric junk into a plausible-looking path. Only NULL and the empty
                // string mean "no reference"; any other non-TEXT value is evidence.
                for row in try db.query("SELECT \(col.column) AS ref FROM \(col.table)") {
                    switch row["ref"] {
                    case .null:
                        continue
                    case .text(let s):
                        if s.isEmpty { continue }
                        if let name = AttachmentRelPath.bareName(of: s) { bump(&validCounts, name, col.key) }
                        else { bump(&invalidCounts, s, col.key) }
                    case .integer(let i):
                        bump(&invalidCounts, "<INTEGER \(i)>", col.key)
                    case .real(let d):
                        bump(&invalidCounts, "<REAL \(d)>", col.key)
                    case .blob(let b):
                        bump(&invalidCounts, "<BLOB \(b.count) bytes>", col.key)
                    }
                }
            }
        }   // read-only connection closes here, before any file hashing

        try hooks.afterScan?()

        // Classify each referenced name against the active dir. lstat FIRST (a fifo must
        // never be opened for hashing); only a REGULAR file inside the container resolves.
        let fm = FileManager.default
        let activeRoot = report.activeAttachmentsDir.standardizedFileURL.path
        var resolved: [ReferenceAudit.ResolvedReference] = []
        var dangling: [ReferenceAudit.DanglingReference] = []
        var extraInvalid: [ReferenceAudit.InvalidReference] = []
        for (name, counts) in validCounts.sorted(by: { $0.key < $1.key }) {
            let prov = Self.provenance(counts)
            let target = report.activeAttachmentsDir.appendingPathComponent(name)
            guard target.standardizedFileURL.path.hasPrefix(activeRoot + "/") else {
                // AttachmentName already forbids everything that could get here; backstop.
                extraInvalid.append(.init(value: name, provenance: prov + "; escapes the active attachments dir"))
                continue
            }
            let attrs = try? fm.attributesOfItem(atPath: target.path)   // lstat: reports a symlink itself
            if attrs == nil {
                dangling.append(.init(name: name, provenance: prov))
            } else if (attrs?[.type] as? FileAttributeType) == .typeRegular {
                resolved.append(.init(name: name, sha256: try FileHash.sha256Hex(of: target), provenance: prov))
            } else {
                dangling.append(.init(name: name, provenance: prov + "; active entry is not a regular file"))
            }
        }
        let invalid = (invalidCounts.map {
            ReferenceAudit.InvalidReference(value: $0.key, provenance: Self.provenance($0.value))
        } + extraInvalid).sorted { ($0.value, $0.provenance) < ($1.value, $1.provenance) }

        // The database must not have changed while we scanned and hashed (includes a full
        // re-run of the quiescence gate — a sidecar appearing mid-audit also fails here).
        let after = try PreparedDatabaseIdentity.compute(at: url)
        guard after == identity else {
            throw AttachmentApplyError.preparedDatabaseChangedDuringAudit(before: identity, after: after)
        }

        return ReferenceAudit(importID: report.importID.rawValue,
                              snapshotIdentitySHA256: report.manifest.snapshotIdentitySHA256,
                              attachmentManifestSHA256: report.manifest.attachmentManifestSHA256,
                              preparedDBIdentity: identity,
                              resolved: resolved, dangling: dangling, invalid: invalid)
    }

    /// Deterministic provenance: column keys sorted, "table.column×rows" joined with "; ".
    static func provenance(_ counts: [String: Int]) -> String {
        counts.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: "; ")
    }
}
