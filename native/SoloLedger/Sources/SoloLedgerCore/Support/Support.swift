import Foundation

public enum IDGenerator {
    /// App-generated string PK for a new transaction (matches the TEXT-id convention).
    public static func transactionID() -> String {
        "txn-" + UUID().uuidString.lowercased()
    }
}

public enum DateFormat {
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Today's local date as 'YYYY-MM-DD' (the DB stores user dates as TEXT).
    public static func today() -> String { dayFormatter.string(from: Date()) }

    public static func string(from date: Date) -> String { dayFormatter.string(from: date) }

    public static func date(from string: String) -> Date? { dayFormatter.date(from: string) }

    /// Month bucket 'YYYY-MM' from a 'YYYY-MM-DD' string (chart aggregation).
    public static func monthKey(_ dayString: String) -> String { String(dayString.prefix(7)) }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    /// Filename-safe timestamp for backup/working files, e.g. "20260715-200800".
    public static func timestamp(_ date: Date = Date()) -> String { stampFormatter.string(from: date) }
}

public enum AppPathsError: Error, CustomStringConvertible {
    /// A staging path resolved outside the Staging root (should be impossible given
    /// `ImportID` validation; this is the defense-in-depth backstop).
    case stagingPathEscape(String)
    public var description: String {
        switch self {
        case .stagingPathEscape(let p): return "Refusing a staging path that escapes the Staging root: \(p)"
        }
    }
}

/// Filesystem locations for the prototype.
///
/// CRITICAL SAFETY: the prototype's DB lives in its OWN folder,
/// `Application Support/SoloLedgerNativePreview/sololedger.db`, NEVER the
/// Electron app's `Application Support/SoloLedger/sololedger.db`. When the app
/// runs sandboxed under the dev Bundle ID, `.applicationSupportDirectory` already
/// resolves inside the isolated container; the distinct subfolder keeps the
/// unsandboxed (dev `swift run`) case isolated too. The production ledger is the
/// user's single source of financial truth and this experimental prototype must
/// never touch it.
public enum AppPaths {
    /// The native app's OWN data folder, deliberately distinct from Electron's
    /// productName folder ("SoloLedger"). Debug uses a clearly-marked preview folder;
    /// Release uses a stable production name with NO "Preview" in it.
    public static var nativeDataFolderName: String {
        #if DEBUG
        return "SoloLedgerNativePreview"
        #else
        return "SoloLedgerNative"
        #endif
    }
    public static let databaseFileName = "sololedger.db"

    public static func dataDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent(nativeDataFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func databaseURL() throws -> URL {
        try dataDirectory().appendingPathComponent(databaseFileName)
    }

    /// Consistent-backup directory (pre-upgrade snapshots live here).
    public static func backupsDirectory() throws -> URL {
        let dir = try dataDirectory().appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Scratch directory for the upgrade working copy (before the atomic swap).
    public static func upgradeWorkingDirectory() throws -> URL {
        let dir = try dataDirectory().appendingPathComponent("Upgrade", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Electron's productName folder ("SoloLedger") holding its `sololedger.db`, in
    /// the SAME sandbox `Application Support`.
    ///
    /// PATH MODEL:
    ///  - Electron MAS (Bundle ID `com.alotie418.sololedger`) stores its DB at, inside
    ///    the sandbox container,
    ///    `~/Library/Containers/com.alotie418.sololedger/Data/Library/Application Support/SoloLedger/sololedger.db`.
    ///  - The native RELEASE app uses the SAME Bundle ID, hence the SAME container, so
    ///    this URL resolves onto the Electron database — the upgrade source.
    ///  - The native DEBUG app (`com.alotie418.sololedger.dev`) has its OWN isolated
    ///    container; this URL resolves inside it, where no production data exists — so
    ///    Debug can never discover or touch the real database, and NO extra entitlement
    ///    to reach the production container is added.
    ///
    /// The native app reads this file READ-ONLY (integrity + backup snapshot) and never
    /// modifies or deletes it; its own active DB lives under `nativeDataFolderName`.
    public static let electronProductFolderName = "SoloLedger"

    public static func electronLegacyDatabaseURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false)
        return base.appendingPathComponent(electronProductFolderName, isDirectory: true)
            .appendingPathComponent(databaseFileName)
    }

    // MARK: - Attachments & staging (Phase 2B migration infrastructure)

    /// The relative layout Electron uses for document attachments
    /// (`attachments/docs/<name>`), stored VERBATIM in the DB. The native active
    /// attachments root mirrors it so a stored relative path resolves under the native
    /// data dir.
    public static let attachmentsRelativeRoot = "attachments/docs"

    /// The native app's OWN active attachments root (created). Mirrors Electron's
    /// `attachments/docs/` layout under the native data dir so migrated `attachment_path`
    /// / `tax_invoice_attachment_path` relative strings resolve here.
    public static func nativeAttachmentsDirectory() throws -> URL {
        let dir = try dataDirectory()
            .appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The Staging ROOT (created). Holds the per-import PUBLISHED dirs (`import-<id>`) and
    /// the transient per-attempt dirs (`.attempt-<uuid>`).
    public static func stagingRootDirectory() throws -> URL {
        let dir = try dataDirectory().appendingPathComponent("Staging", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The FINAL published staging dir for an import (`Staging/import-<id>`). PATH ONLY —
    /// NOT created; ingest publishes into it atomically (rename from a completed attempt).
    /// Defense in depth: even though `ImportID` already forbids unsafe values, the resolved
    /// path must stay STRICTLY under the Staging root or this throws.
    public static func stagedImportDirectory(importID: ImportID) throws -> URL {
        let root = try stagingRootDirectory()
        let dir = root.appendingPathComponent("import-\(importID.rawValue)", isDirectory: true)
        guard dir.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else {
            throw AppPathsError.stagingPathEscape(dir.path)
        }
        return dir
    }

    /// A fresh, unique, EMPTY attempt directory under the Staging root (created). Each ingest
    /// attempt writes here in isolation; on success it is atomically renamed to the published
    /// per-import dir, and on any failure it is removed. `withIntermediateDirectories: false`
    /// guarantees a brand-new dir (never silently reuses an existing one).
    public static func freshStagingAttemptDirectory() throws -> URL {
        let root = try stagingRootDirectory()
        let dir = root.appendingPathComponent(".attempt-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        return dir
    }

    /// Persisted ImportManifest / final-report store (created). Deliberately OUTSIDE the
    /// database and keyed PER IMPORT: the completion record survives staging cleanup and
    /// is never inherited by a different DB — importing an old backup must not pick up a
    /// stale "attachments already migrated" flag (that is exactly why completion state is
    /// not a global `settings` boolean).
    public static func importManifestsDirectory() throws -> URL {
        let dir = try dataDirectory().appendingPathComponent("ImportManifests", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Electron's attachments source root, container-relative (SAME Application Support,
    /// `SoloLedger/` product folder → `attachments/docs/`). READ-ONLY source, NOT created.
    /// Debug `.dev` container isolation applies exactly as for `electronLegacyDatabaseURL`.
    public static func electronLegacyAttachmentsURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false)
        return base.appendingPathComponent(electronProductFolderName, isDirectory: true)
            .appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent("docs", isDirectory: true)
    }
}
