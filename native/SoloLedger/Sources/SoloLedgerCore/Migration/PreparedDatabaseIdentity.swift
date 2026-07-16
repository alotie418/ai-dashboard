import Foundation

// MARK: - Prepared-database quiescence gate + identity

public enum PreparedDatabaseError: Error, CustomStringConvertible, Equatable {
    case databaseMissing(String)
    case databaseNotRegularFile(String)
    case notQuiescent(sidecar: String)
    case wrongJournalMode(String)
    case unreadable(String)

    public var description: String {
        switch self {
        case .databaseMissing(let p):
            return "Prepared database is missing: \(p)"
        case .databaseNotRegularFile(let p):
            return "Prepared database is not a regular file (symlink/directory/special): \(p)"
        case .notQuiescent(let s):
            return "Prepared database is not quiescent — sidecar present: \(s)"
        case .wrongJournalMode(let m):
            return "Prepared database journal_mode is '\(m)' but must be 'delete' — checkpoint the WAL and close every connection first"
        case .unreadable(let m):
            return "Prepared database could not be read: \(m)"
        }
    }
}

/// The ONLY sanctioned source of a `preparedDBIdentity` string. Callers hand over the
/// prepared database's URL, never an identity string of their own making — apply, audit
/// and complete each recompute the identity from the actual file through this gate, so a
/// fabricated or stale identity can never bind an audit to the wrong database.
///
/// `compute` is also the QUIESCENCE GATE: it refuses to identify a database that could
/// still change underneath the migration. Requirements (all fail-closed):
///  - the main file exists and is a REGULAR file (a symlink/directory/special file is
///    rejected — identity must be the bytes at this exact path);
///  - no `-wal`, `-shm` or `-journal` sidecar exists (even as a symlink) — the caller
///    must have checkpointed and closed every connection;
///  - a strictly read-only probe reports `PRAGMA journal_mode == delete`, which catches a
///    WAL-mode database whose sidecars were merely deleted (its header still says WAL and
///    the next writer would recreate them).
///
/// The identity is `sha256:<streaming hex>` of the single main file. The read-only probe
/// cannot create or modify files; the sidecar check is re-run after it as defense in depth,
/// so the hashed bytes are provably the quiescent state that was gated.
public enum PreparedDatabaseIdentity {

    /// Sidecars whose presence means the database is not quiescent. `-journal` covers a
    /// DELETE-mode rollback journal left by an interrupted writer.
    static let sidecarSuffixes = ["-wal", "-shm", "-journal"]

    public static func compute(at url: URL) throws -> String {
        try assertQuiescent(at: url)

        // WAL mode is persistent in the file header (format read/write version bytes at
        // offsets 18/19 == 2). A read-only connection cannot even probe such a file once
        // its sidecars are gone (it may not create the -shm and fails with CANTOPEN), so
        // detect WAL from the header first for a precise, actionable error.
        if try headerSaysWAL(url) { throw PreparedDatabaseError.wrongJournalMode("wal") }

        do {
            let db = try SQLiteDatabase(path: url.path, readOnly: true)
            try db.execute("PRAGMA query_only = ON")
            let mode = try db.scalar("PRAGMA journal_mode").stringValue?.lowercased() ?? "unknown"
            guard mode == "delete" else { throw PreparedDatabaseError.wrongJournalMode(mode) }
        } catch let e as PreparedDatabaseError {
            throw e
        } catch {
            throw PreparedDatabaseError.unreadable("\(error)")
        }

        try assertQuiescent(at: url)   // re-check after the probe: still single-file
        return "sha256:" + (try FileHash.sha256Hex(of: url))
    }

    /// True iff the file carries a valid SQLite header whose format read/write version
    /// bytes (offsets 18/19) say WAL. Non-SQLite bytes return false here — the read-only
    /// pragma probe rejects those as unreadable with SQLite's own diagnostics.
    private static func headerSaysWAL(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let header = try handle.read(upToCount: 20), header.count == 20 else { return false }
        guard header.prefix(16).elementsEqual("SQLite format 3\0".utf8) else { return false }
        return header[18] == 2 || header[19] == 2
    }

    /// The filesystem half of the gate. `attributesOfItem` does not traverse symlinks, so a
    /// symlinked main file is rejected and a symlink NAMED like a sidecar counts as present.
    static func assertQuiescent(at url: URL) throws {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path) else {
            throw PreparedDatabaseError.databaseMissing(url.path)
        }
        guard (attrs[.type] as? FileAttributeType) == .typeRegular else {
            throw PreparedDatabaseError.databaseNotRegularFile(url.path)
        }
        for suffix in sidecarSuffixes {
            let side = url.path + suffix
            if (try? fm.attributesOfItem(atPath: side)) != nil {
                throw PreparedDatabaseError.notQuiescent(sidecar: side)
            }
        }
    }
}
