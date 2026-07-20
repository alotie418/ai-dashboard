import Foundation
import CSQLite

/// A dynamically-typed SQLite value used for binds and column reads.
public enum SQLiteValue: Equatable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    // Convenience accessors ------------------------------------------------

    public var stringValue: String? {
        switch self {
        case .text(let s): return s
        case .integer(let i): return String(i)
        case .real(let d): return String(d)
        case .null, .blob: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .real(let d): return d
        case .integer(let i): return Double(i)
        case .text(let s): return Double(s)
        case .null, .blob: return nil
        }
    }

    public var intValue: Int? {
        switch self {
        case .integer(let i): return Int(i)
        case .real(let d): return Int(d)
        case .text(let s): return Int(s)
        case .null, .blob: return nil
        }
    }
}

public enum SQLiteError: Error, CustomStringConvertible {
    /// A failed `sqlite3_open_v2`. Carries the STRUCTURED numeric codes (primary, extended and
    /// the underlying `sqlite3_system_errno`), collected BEFORE the partial handle is closed, so
    /// a caller (e.g. the C12x hardened active-open) can classify a symlink / IO failure by code
    /// WITHOUT parsing the human `message`. The message is retained only for developer logs and
    /// is NEVER surfaced into a `MigrationBlock.params`.
    case open(message: String, primary: Int32, extended: Int32, systemErrno: Int32)
    case prepare(String)
    case step(String)
    case message(String)

    public var description: String {
        switch self {
        case let .open(m, primary, extended, sys):
            return "SQLite open failed: \(m) (primary \(primary), extended \(extended), errno \(sys))"
        case .prepare(let m): return "SQLite prepare failed: \(m)"
        case .step(let m): return "SQLite step failed: \(m)"
        case .message(let m): return "SQLite error: \(m)"
        }
    }
}

public extension SQLiteError {
    /// True iff this is an `.open` failure whose EXTENDED code is `SQLITE_CANTOPEN_SYMLINK`
    /// (a symlink somewhere in the resolved path, rejected under `SQLITE_OPEN_NOFOLLOW`).
    /// `SQLITE_CANTOPEN_SYMLINK` is an expression macro not imported to Swift, so it is computed.
    var isCantOpenSymlink: Bool {
        guard case let .open(_, _, extended, _) = self else { return false }
        return extended == (SQLITE_CANTOPEN | (6 << 8))
    }
}

/// Result of a post-open `SQLITE_FCNTL_HAS_MOVED` check on the "main" database file.
/// The Unix VFS compares the OPEN descriptor's inode against the inode currently at the path
/// (INODE ONLY — not device); see the C12x residual notes for cross-device / between-check gaps.
public enum HasMovedResult: Equatable {
    /// `rc == SQLITE_OK`; `moved` is true when the open fd's inode is no longer the path's inode
    /// (replaced / unlinked / opened-then-restored), i.e. the connection is bound to a file that
    /// no longer lives at this path.
    case ok(moved: Bool)
    /// `rc == SQLITE_NOTFOUND` — the VFS does not implement the opcode (e.g. an in-memory DB).
    case notFound
    /// `rc == SQLITE_MISUSE` — misuse (e.g. an unknown schema name); a programming error.
    case misuse
    /// Any other non-OK `rc` from `sqlite3_file_control`. Carries the AUTHORITATIVE per-call
    /// `fileControlRC` (the file-control return value itself — NOT `sqlite3_extended_errcode`,
    /// which reflects the connection's last statement, not this control call) plus the
    /// `sqlite3_system_errno` snapshot. Numbers only; no message.
    case fileControlFailed(fileControlRC: Int32, systemErrno: Int32)
}

/// A single result row keyed by column name, preserving column order.
public struct SQLiteRow {
    public let columns: [String]
    private let values: [String: SQLiteValue]

    init(columns: [String], values: [String: SQLiteValue]) {
        self.columns = columns
        self.values = values
    }

    public subscript(_ column: String) -> SQLiteValue { values[column] ?? .null }

    public func string(_ column: String) -> String? { self[column].stringValue }
    public func double(_ column: String) -> Double? { self[column].doubleValue }
    public func int(_ column: String) -> Int? { self[column].intValue }
}

// SQLITE_TRANSIENT tells SQLite to copy the bound bytes (safe for Swift Strings/Data).
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Minimal, synchronous wrapper over the system libsqlite3 C API.
///
/// Intentionally small — it exists so the schema, migrations and CRUD can be an
/// exact port of the Electron/better-sqlite3 behavior without pulling in an
/// external dependency. Not thread-safe; callers use one instance per connection
/// and (for the GUI) hop to the main actor.
public final class SQLiteDatabase {
    private var handle: OpaquePointer?
    public let path: String

    /// How to open a database file.
    public enum OpenMode {
        /// Read/write, CREATE the file if absent. The historical default.
        case readWriteCreate
        /// Read/write but the file MUST already exist — sqlite3_open_v2 without
        /// SQLITE_OPEN_CREATE. A vanished/swapped path fails closed instead of
        /// fabricating a fresh EMPTY database (which every downstream check would then
        /// pass, presenting a blank ledger as a successful import).
        case readWriteExisting
        /// Read-only — used to inspect a source without ever modifying it.
        case readOnly
        /// C12x-A1 active existing-store hardened open: READWRITE **without** CREATE, plus
        /// `SQLITE_OPEN_NOFOLLOW` (the Unix VFS refuses a symlink ANYWHERE in the resolved path —
        /// leaf or ancestor — with `SQLITE_CANTOPEN_SYMLINK`) and `SQLITE_OPEN_EXRESCODE` (so the
        /// extended code is returned and a symlink is distinguishable from a generic CANTOPEN).
        /// Used ONLY for opening the coordinator-authorized existing active database; it is
        /// deliberately NOT a general-purpose mode (createFresh / restore / demo keep their modes).
        case activeExistingNoFollow

        var flags: Int32 {
            switch self {
            case .readWriteCreate: return SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
            case .readWriteExisting: return SQLITE_OPEN_READWRITE
            case .readOnly: return SQLITE_OPEN_READONLY
            case .activeExistingNoFollow:
                return SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW | SQLITE_OPEN_EXRESCODE
            }
        }
    }

    public init(path: String, mode: OpenMode) throws {
        self.path = path
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(path, &db, mode.flags, nil)
        guard rc == SQLITE_OK, let db else {
            // Collect the STRUCTURED codes from the partial handle BEFORE closing it; the path and
            // message are kept only for developer logs and never reach a MigrationBlock.
            let primary = rc & 0xFF
            let extended = db.map { sqlite3_extended_errcode($0) } ?? rc
            let sysErrno = db.map { sqlite3_system_errno($0) } ?? 0
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let db { sqlite3_close(db) }
            throw SQLiteError.open(message: msg, primary: primary, extended: extended, systemErrno: sysErrno)
        }
        self.handle = db
    }

    /// Post-open identity probe (`SQLITE_FCNTL_HAS_MOVED`) on the "main" file — pure: no SQL, no
    /// write, creates no `-wal`/`-shm`. Detects that the open connection's inode is no longer the
    /// one living at its path (replaced / unlinked / opened-then-restored). This is NOT proof the
    /// blessed inode was opened (a same-inode-at-both-ends race can still pass — residual R1);
    /// it is one of the layered checks in the C12x hardened active-open.
    func hasMoved() -> HasMovedResult {
        guard let handle else { return .misuse }
        var moved: Int32 = -1
        let rc = withUnsafeMutablePointer(to: &moved) {
            sqlite3_file_control(handle, "main", SQLITE_FCNTL_HAS_MOVED, UnsafeMutableRawPointer($0))
        }
        switch rc {
        case SQLITE_OK:       return .ok(moved: moved != 0)
        case SQLITE_NOTFOUND: return .notFound
        case SQLITE_MISUSE:   return .misuse
        default:
            // `rc` is the AUTHORITATIVE per-call return of THIS file_control; do NOT substitute
            // `sqlite3_extended_errcode`, which reflects the last statement on the connection.
            return .fileControlFailed(fileControlRC: rc, systemErrno: sqlite3_system_errno(handle))
        }
    }

    /// Compatibility convenience: `readOnly` selects `.readOnly`, otherwise `.readWriteCreate`.
    public convenience init(path: String, readOnly: Bool = false) throws {
        try self.init(path: path, mode: readOnly ? .readOnly : .readWriteCreate)
    }

    /// Explicitly close the connection. IDEMPOTENT (a second call is a no-op) and
    /// error-VISIBLE (a non-OK close — e.g. SQLITE_BUSY from an un-finalized statement —
    /// throws rather than being swallowed). Callers that must compute a file identity after
    /// closing (PreparedDatabaseIdentity) rely on this being deterministic, not deinit-timed.
    public func close() throws {
        guard let h = handle else { return }   // idempotent after a successful close
        let rc = sqlite3_close(h)
        // Nil the handle ONLY on success. On SQLITE_BUSY (an un-finalized statement or an
        // active backup) the connection is STILL OPEN — keep the handle so the caller can
        // finalize and retry close(), and so deinit can still close it. Losing the handle
        // here would leak the connection permanently.
        guard rc == SQLITE_OK else {
            throw SQLiteError.message("close failed (code \(rc)); connection remains open")
        }
        handle = nil
    }

    deinit {
        if let handle { sqlite3_close(handle) }   // best-effort backstop if close() was not called
    }

    // MARK: - Test seams (internal)

    /// Prepare a statement and DO NOT finalize it, so the NEXT `close()` sees SQLITE_BUSY.
    /// The caller MUST later pass the returned pointer to `finalizeTestStatement`. Test-only.
    func prepareUnfinalizedStatementForTesting(_ sql: String) throws -> OpaquePointer {
        guard let handle else { throw SQLiteError.message("connection closed") }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SQLiteError.prepare(lastMessage)
        }
        return stmt
    }

    /// Finalize a statement obtained from `prepareUnfinalizedStatementForTesting`. Test-only.
    func finalizeTestStatement(_ stmt: OpaquePointer) { sqlite3_finalize(stmt) }

    private var lastMessage: String {
        guard let handle else { return "no connection" }
        return String(cString: sqlite3_errmsg(handle))
    }

    /// Run one or more statements with no bindings (DDL / pragmas / scripts).
    public func execute(_ sql: String) throws {
        guard let handle else { throw SQLiteError.message("connection closed") }
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? lastMessage
            if let errMsg { sqlite3_free(errMsg) }
            throw SQLiteError.message("\(msg) — while executing: \(sql.prefix(200))")
        }
    }

    /// Prepare + bind + step a write statement to completion.
    @discardableResult
    public func run(_ sql: String, _ params: [SQLiteValue] = []) throws -> Int {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bind(stmt, params)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw SQLiteError.step("\(lastMessage) (code \(rc))")
        }
        return Int(sqlite3_changes(handle))
    }

    /// Prepare + bind + read all rows of a query.
    public func query(_ sql: String, _ params: [SQLiteValue] = []) throws -> [SQLiteRow] {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bind(stmt, params)

        let columnCount = Int(sqlite3_column_count(stmt))
        var columnNames: [String] = []
        columnNames.reserveCapacity(columnCount)
        for i in 0..<columnCount {
            columnNames.append(String(cString: sqlite3_column_name(stmt, Int32(i))))
        }

        var rows: [SQLiteRow] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                throw SQLiteError.step("\(lastMessage) (code \(rc))")
            }
            var values: [String: SQLiteValue] = [:]
            for i in 0..<columnCount {
                values[columnNames[i]] = readColumn(stmt, Int32(i))
            }
            rows.append(SQLiteRow(columns: columnNames, values: values))
        }
        return rows
    }

    /// Read a single scalar (first column of first row).
    public func scalar(_ sql: String, _ params: [SQLiteValue] = []) throws -> SQLiteValue {
        try query(sql, params).first?[columnAt: 0] ?? .null
    }

    // MARK: - user_version pragma (schema versioning, mirrors Electron)

    public func userVersion() throws -> Int {
        try scalar("PRAGMA user_version").intValue ?? 0
    }

    public func setUserVersion(_ version: Int) throws {
        // PRAGMA doesn't accept bound params; version is an Int we control.
        try execute("PRAGMA user_version = \(version)")
    }

    // MARK: - Integrity

    /// Fast structural check (`PRAGMA quick_check`). Returns true iff "ok".
    public func quickCheck() throws -> Bool {
        try scalar("PRAGMA quick_check").stringValue == "ok"
    }

    /// Full integrity check (`PRAGMA integrity_check`). Returns true iff "ok".
    public func integrityCheck() throws -> Bool {
        try scalar("PRAGMA integrity_check").stringValue == "ok"
    }

    // MARK: - Consistent backup (SQLite Online Backup API)

    /// Copy this database to a NEW file at `destPath` using the SQLite Online
    /// Backup API. This produces a consistent snapshot of the live database —
    /// including any un-checkpointed WAL frames — which a raw file copy of a WAL
    /// database cannot guarantee. The destination is overwritten/created fresh.
    public func backup(toPath destPath: String) throws {
        guard let src = handle else { throw SQLiteError.message("connection closed") }
        var dest: OpaquePointer?
        let openRC = sqlite3_open_v2(destPath, &dest, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard openRC == SQLITE_OK, let dest else {
            let msg = dest.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed (rc \(openRC))"
            if let dest { sqlite3_close(dest) }
            throw SQLiteError.message("backup destination open failed: \(msg)")
        }
        defer { sqlite3_close(dest) }

        guard let bk = sqlite3_backup_init(dest, "main", src, "main") else {
            throw SQLiteError.message("sqlite3_backup_init failed: \(String(cString: sqlite3_errmsg(dest)))")
        }
        let stepRC = sqlite3_backup_step(bk, -1)    // -1 == copy all remaining pages
        let finishRC = sqlite3_backup_finish(bk)
        guard stepRC == SQLITE_DONE else {
            throw SQLiteError.message("sqlite3_backup_step failed (rc \(stepRC)): \(String(cString: sqlite3_errmsg(dest)))")
        }
        guard finishRC == SQLITE_OK else {
            throw SQLiteError.message("sqlite3_backup_finish failed (rc \(finishRC))")
        }
    }

    // MARK: - Transactions

    public func transaction(_ block: () throws -> Void) throws {
        try execute("BEGIN")
        do {
            try block()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    // MARK: - Internals

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let handle else { throw SQLiteError.message("connection closed") }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            throw SQLiteError.prepare("\(lastMessage) — \(sql.prefix(200))")
        }
        return stmt
    }

    private func bind(_ stmt: OpaquePointer, _ params: [SQLiteValue]) throws {
        for (index, value) in params.enumerated() {
            let position = Int32(index + 1)
            let rc: Int32
            switch value {
            case .null:
                rc = sqlite3_bind_null(stmt, position)
            case .integer(let i):
                rc = sqlite3_bind_int64(stmt, position, i)
            case .real(let d):
                rc = sqlite3_bind_double(stmt, position, d)
            case .text(let s):
                // Explicit byte length (not -1) so a bound String with an embedded NUL is
                // stored in full — the read side (readColumn) is symmetric.
                rc = sqlite3_bind_text(stmt, position, s, Int32(s.utf8.count), SQLITE_TRANSIENT)
            case .blob(let data):
                rc = data.withUnsafeBytes { raw in
                    sqlite3_bind_blob(stmt, position, raw.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
                }
            }
            if rc != SQLITE_OK {
                throw SQLiteError.message("bind failed at \(position): \(lastMessage)")
            }
        }
    }

    private func readColumn(_ stmt: OpaquePointer, _ index: Int32) -> SQLiteValue {
        switch sqlite3_column_type(stmt, index) {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(stmt, index))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(stmt, index))
        case SQLITE_TEXT:
            if let c = sqlite3_column_text(stmt, index) {
                // NEVER String(cString:): it stops at the first NUL, silently truncating
                // TEXT with embedded \0 (e.g. "…a.pdf\0suffix" would read back as a
                // plausible "…a.pdf"). Read the exact byte length instead; invalid UTF-8
                // decodes lossily to U+FFFD, which can never form a valid ASCII-only path.
                let count = Int(sqlite3_column_bytes(stmt, index))
                return .text(String(decoding: UnsafeBufferPointer(start: c, count: count), as: UTF8.self))
            }
            return .null
        case SQLITE_BLOB:
            if let bytes = sqlite3_column_blob(stmt, index) {
                let count = Int(sqlite3_column_bytes(stmt, index))
                return .blob(Data(bytes: bytes, count: count))
            }
            return .null
        default:
            return .null
        }
    }
}

private extension SQLiteRow {
    subscript(columnAt index: Int) -> SQLiteValue {
        guard index >= 0, index < columns.count else { return .null }
        return self[columns[index]]
    }
}
