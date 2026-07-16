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
    /// modifies or deletes it; its own active DB lives in `previewFolderName`.
    public static let electronProductFolderName = "SoloLedger"

    public static func electronLegacyDatabaseURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false)
        return base.appendingPathComponent(electronProductFolderName, isDirectory: true)
            .appendingPathComponent(databaseFileName)
    }
}
