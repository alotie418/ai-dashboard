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
    /// Distinct from the Electron productName ("SoloLedger") on purpose.
    public static let previewFolderName = "SoloLedgerNativePreview"
    public static let databaseFileName = "sololedger.db"

    public static func dataDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent(previewFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func databaseURL() throws -> URL {
        try dataDirectory().appendingPathComponent(databaseFileName)
    }
}
