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
    case open(String)
    case prepare(String)
    case step(String)
    case message(String)

    public var description: String {
        switch self {
        case .open(let m): return "SQLite open failed: \(m)"
        case .prepare(let m): return "SQLite prepare failed: \(m)"
        case .step(let m): return "SQLite step failed: \(m)"
        case .message(let m): return "SQLite error: \(m)"
        }
    }
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

        var flags: Int32 {
            switch self {
            case .readWriteCreate: return SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
            case .readWriteExisting: return SQLITE_OPEN_READWRITE
            case .readOnly: return SQLITE_OPEN_READONLY
            }
        }
    }

    public init(path: String, mode: OpenMode) throws {
        self.path = path
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(path, &db, mode.flags, nil)
        guard rc == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let db { sqlite3_close(db) }
            throw SQLiteError.open("\(msg) (code \(rc), path \(path))")
        }
        self.handle = db
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
