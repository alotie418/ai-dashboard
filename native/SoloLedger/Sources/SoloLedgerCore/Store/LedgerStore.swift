import Foundation

public enum LedgerError: Error, CustomStringConvertible {
    case validation([String])
    case notFound(String)
    public var description: String {
        switch self {
        case .validation(let errs): return errs.joined(separator: "; ")
        case .notFound(let id): return "Transaction not found: \(id)"
        }
    }
}

/// Whether opening the active ledger may CREATE its file. The C12 boot coordinator
/// authorizes exactly one origin to create (a fresh install); every other authorization
/// opens an EXISTING database so that a VANISHED path fails to open rather than fabricating
/// an empty ledger over it.
public enum StoreOpenIntent: Equatable {
    /// Fresh install: create the database file when absent.
    case createIfMissing
    /// The database must already exist: opens with SQLITE_OPEN_READWRITE WITHOUT
    /// SQLITE_OPEN_CREATE, so a VANISHED path fails to open instead of fabricating an empty
    /// ledger. This closes ONLY the "path gone → empty DB created" window; it does NOT close
    /// the confirm→open path / inode / symlink-swap window, which remains a registered
    /// residual (C12b design, decision #18).
    case existingOnly

    /// The SQLite open mode this intent maps to (exhaustive; no default).
    var openMode: SQLiteDatabase.OpenMode {
        switch self {
        case .createIfMissing: return .readWriteCreate
        case .existingOnly:    return .readWriteExisting
        }
    }
}

/// The prototype's data access layer over one SQLite connection. Opens the DB,
/// applies the runtime PRAGMAs and full migration ladder, seeds categories, and
/// exposes the Phase-1 CRUD/aggregation surface — a faithful port of the Electron
/// `transactions` / `categories` / `settings` handlers.
public final class LedgerStore {
    public let db: SQLiteDatabase
    public let settings: SettingsStore

    /// Open the DB at `url` with an explicit open semantics, then migrate + seed. ONLY the
    /// SQLite open mode is parameterized by `intent`; pragmas, the migration ladder and
    /// category seeding are byte-for-byte identical to the historical path.
    public init(databaseURL: URL, open intent: StoreOpenIntent) throws {
        self.db = try SQLiteDatabase(path: databaseURL.path, mode: intent.openMode)
        self.settings = SettingsStore(db)
        try applyPragmas()
        try SchemaMigrator.migrate(db)
    }

    /// Open (creating if needed) the DB at `url`, then migrate + seed. Source-compatible
    /// with the historical default; delegates to `.createIfMissing`.
    public convenience init(databaseURL: URL) throws {
        try self.init(databaseURL: databaseURL, open: .createIfMissing)
    }

    /// C12x-A1: adopt an ALREADY-OPEN connection (for the hardened active path, one that has
    /// already passed the NOFOLLOW/HAS_MOVED/fingerprint checks) and run pragmas + migration on
    /// the SAME connection — NO second open. A pragma/migration failure explicitly closes the
    /// adopted connection before rethrowing, so no descriptor/lock leaks on the failure path.
    init(adopting db: SQLiteDatabase) throws {
        self.db = db
        self.settings = SettingsStore(db)
        do {
            try applyPragmas()
            try SchemaMigrator.migrate(db)
        } catch {
            try? db.close()
            throw error
        }
    }

    /// INTERNAL test seams for the hardened active-open. Nil in production (the SHIPPING public
    /// entry passes an empty instance), so no hook is ever reachable from the App. `open` defaults
    /// to the single real NOFOLLOW open; a test injects a counting/observing opener to prove the
    /// single-open invariant without any global mutable state.
    struct HardenedOpenHooks {
        var open: (URL) throws -> SQLiteDatabase = {
            try SQLiteDatabase(path: $0.path, mode: .activeExistingNoFollow)
        }
        /// Fired AFTER the size guard and BEFORE the open — swap/truncate the file here.
        var beforeOpen: (() throws -> Void)? = nil
        /// Fired AFTER the single open and BEFORE the identity checks — swap the file here.
        var afterOpenBeforeChecks: (() throws -> Void)? = nil
        /// Deterministically inject a `HAS_MOVED` result (e.g. `.notFound`) into the real flow.
        var hasMovedOverride: (() -> HasMovedResult)? = nil
        /// Observe the identity connection being closed on a failure path (`true` == close ok).
        var observeClose: ((Bool) -> Void)? = nil
    }

    /// C12x-A1: open the coordinator-authorized EXISTING active store with layered path/inode
    /// hardening, then adopt the SAME connection. EXACTLY ONE open; on ANY failure before adoption
    /// the connection is DETERMINISTICALLY closed and NO application-layer SQL / PRAGMA / migration
    /// / settings read runs — so on a SUPPORTED APFS active path a failed identity check performs
    /// no application-layer write. (A zero-length open on a MSDOS/FAT volume MAY write one byte at
    /// the VFS layer; that filesystem-support edge is a registered compatibility residual, not
    /// closed here.)
    ///
    /// Layers: (1) refuse when the CONFIRM-TIME evidence leaf size is zero (a confirmed-empty
    /// active is never valid) — this does NOT catch a LATE swap to a zero-length file after
    /// confirm (evidence is still > 0), which reaches the open and is caught by the fingerprint
    /// (size mismatch); (2) NOFOLLOW open (a symlink anywhere in the resolved path →
    /// `CANTOPEN_SYMLINK`); (3) HAS_MOVED (open fd inode ≠ current path
    /// inode — catches an opened-then-restored double-swap that a path re-stat would miss); (4)
    /// parent (device,inode) + full no-follow leaf fingerprint vs the confirm-time evidence.
    /// NONE proves the blessed inode was the one opened — a same-inode-at-both-ends race between
    /// the checks remains residual R1; this is a CURRENT-PATH identity check, not a proof of the
    /// opened inode. The SHIPPING entry takes ONLY `databaseURL` + `expect`; no test hook is exposed.
    public static func openActiveExistingHardened(databaseURL url: URL,
                                                  expect: ActiveOpenEvidence) throws -> LedgerStore {
        try openActiveExistingHardened(databaseURL: url, expect: expect, hooks: HardenedOpenHooks())
    }

    /// INTERNAL overload carrying the test seams; not reachable from the App.
    static func openActiveExistingHardened(databaseURL url: URL, expect: ActiveOpenEvidence,
                                           hooks: HardenedOpenHooks) throws -> LedgerStore {
        // (1) Refuse when the CONFIRM-TIME evidence leaf size is zero. This guards a
        //     confirmed-empty active only; a LATE zero-length swap (evidence still > 0) is NOT
        //     rejected here — it reaches the open and is caught downstream by the fingerprint.
        guard expect.leaf.size > 0 else { throw HardenedOpenError.identity(.zeroSizeActiveLeaf) }

        try hooks.beforeOpen?()

        // (2) The SINGLE open — via the injected opener (default = the real NOFOLLOW open).
        let db: SQLiteDatabase
        do {
            db = try hooks.open(url)
        } catch let e as SQLiteError {
            throw Self.mapHardenedOpenError(e)
        }

        // (3)+(4) identity checks BEFORE any SQL. On failure: DETERMINISTIC close, then rethrow
        //         the ORIGINAL typed error (never the close error, so no close-failure text leaks).
        do {
            try hooks.afterOpenBeforeChecks?()
            try Self.verifyActiveIdentity(db: db, url: url, expect: expect, hooks: hooks)
        } catch {
            var closed = false
            do { try db.close(); closed = true } catch { closed = false }
            hooks.observeClose?(closed)
            throw error
        }

        // Adopt the SAME verified connection; only now do pragmas + migration (writes) run.
        return try LedgerStore(adopting: db)
    }

    private static func mapHardenedOpenError(_ e: SQLiteError) -> HardenedOpenError {
        if e.isCantOpenSymlink { return .identity(.unsupportedSymlinkedActivePath) }
        guard case let .open(_, primary, extended, systemErrno) = e else {
            return .sqlite(primary: 0, extended: 0, systemErrno: 0)
        }
        return .sqlite(primary: primary, extended: extended, systemErrno: systemErrno)
    }

    private static func verifyActiveIdentity(db: SQLiteDatabase, url: URL,
                                             expect: ActiveOpenEvidence, hooks: HardenedOpenHooks) throws {
        // (3) HAS_MOVED — the open connection's inode must still live at this path.
        switch hooks.hasMovedOverride?() ?? db.hasMoved() {
        case .ok(let moved): if moved { throw HardenedOpenError.identity(.moved) }
        case .notFound:      throw HardenedOpenError.hasMovedUnavailable
        case .misuse:        throw HardenedOpenError.hasMovedMisuse
        case .fileControlFailed(let rc, let sys):
            throw HardenedOpenError.hasMovedFailed(fileControlRC: rc, systemErrno: sys)
        }
        // (4) parent (device,inode) + full no-follow leaf fingerprint vs evidence. The metadata
        //     read is descriptor-rooted (openat O_NOFOLLOW + fstatat AT_SYMLINK_NOFOLLOW).
        let parentURL = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        let parent: DirectoryHandle
        do { parent = try DirectoryHandle.open(at: parentURL) }
        catch let e as FileHashError where e.isFileMissing { throw HardenedOpenError.identity(.vanished) }
        catch { throw HardenedOpenError.identity(.parentIdentityMismatch) }
        guard parent.device == expect.parentDevice, parent.inode == expect.parentInode else {
            throw HardenedOpenError.identity(.parentIdentityMismatch)
        }
        let fp: FileFingerprint?
        do { fp = try parent.fingerprint(named: name) }
        catch { throw HardenedOpenError.identity(.fingerprintMismatch) }
        guard let fp else { throw HardenedOpenError.identity(.vanished) }
        guard fp == expect.leaf else { throw HardenedOpenError.identity(.fingerprintMismatch) }
    }

    private func applyPragmas() throws {
        // Same posture as electron/db/index.js.
        try db.execute("PRAGMA journal_mode = WAL")
        try db.execute("PRAGMA foreign_keys = ON")
        try db.execute("PRAGMA synchronous = FULL")
        try db.execute("PRAGMA busy_timeout = 5000")
    }

    public func schemaVersion() throws -> Int { try db.userVersion() }

    // MARK: - Categories

    public func categories(locale: AccountingLocale, type: TransactionType? = nil) throws -> [Category] {
        var sql = "SELECT * FROM categories WHERE locale = ?"
        var params: [SQLiteValue] = [.text(locale.rawValue)]
        if let type {
            sql += " AND type = ?"
            params.append(.text(type.rawValue))
        }
        sql += " ORDER BY type, sort_order"
        return try db.query(sql, params).compactMap(Category.from)
    }

    // MARK: - Transactions CRUD (mirrors electron/handlers/transactions.js)

    public func listTransactions(type: TransactionType? = nil,
                                 from: String? = nil,
                                 to: String? = nil,
                                 categoryID: String? = nil,
                                 search: String? = nil,
                                 sort: TransactionSort = .dateDescending,
                                 limit: Int = 500) throws -> [Transaction] {
        var clauses: [String] = []
        var params: [SQLiteValue] = []
        if let type { clauses.append("type = ?"); params.append(.text(type.rawValue)) }
        if let from { clauses.append("date >= ?"); params.append(.text(from)) }
        if let to { clauses.append("date <= ?"); params.append(.text(to)) }
        if let categoryID { clauses.append("category_id = ?"); params.append(.text(categoryID)) }
        if let raw = search?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let like = "%\(raw)%"
            clauses.append("(counterparty LIKE ? OR description LIKE ? OR invoice_no LIKE ?)")
            params.append(.text(like)); params.append(.text(like)); params.append(.text(like))
        }

        var sql = "SELECT * FROM transactions"
        if !clauses.isEmpty { sql += " WHERE " + clauses.joined(separator: " AND ") }
        sql += " ORDER BY \(sort.orderBy)"
        let clamped = min(max(limit, 1), 5000)
        sql += " LIMIT \(clamped)"
        return try db.query(sql, params).compactMap(Transaction.from)
    }

    public func transaction(id: String) throws -> Transaction? {
        try db.query("SELECT * FROM transactions WHERE id = ?", [.text(id)]).first.flatMap(Transaction.from)
    }

    public func create(_ input: Transaction) throws {
        let t = input.normalized()
        let errors = t.validationErrors()
        guard errors.isEmpty else { throw LedgerError.validation(errors) }
        try db.run("""
            INSERT INTO transactions
              (id, type, date, amount, amount_net, tax_amount, tax_rate, currency,
               category_id, counterparty, invoice_no, invoice_status,
               payment_status, paid_amount, payment_date, due_date,
               description, attachment_path, source_meta)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, bindings(for: t))
    }

    public func update(_ input: Transaction) throws {
        let t = input.normalized()
        let errors = t.validationErrors()
        guard errors.isEmpty else { throw LedgerError.validation(errors) }
        guard try transaction(id: t.id) != nil else { throw LedgerError.notFound(t.id) }
        try db.run("""
            UPDATE transactions SET
              type = ?, date = ?, amount = ?, amount_net = ?, tax_amount = ?, tax_rate = ?, currency = ?,
              category_id = ?, counterparty = ?, invoice_no = ?, invoice_status = ?,
              payment_status = ?, paid_amount = ?, payment_date = ?, due_date = ?,
              description = ?, attachment_path = ?, source_meta = ?,
              updated_at = datetime('now')
            WHERE id = ?
            """, Array(bindings(for: t).dropFirst()) + [.text(t.id)])
    }

    public func delete(id: String) throws {
        try db.transaction {
            // Mirror the handler: also clear any legacy mapping so re-migration isn't confused.
            try db.run("DELETE FROM legacy_migrations WHERE new_id = ?", [.text(id)])
            try db.run("DELETE FROM transactions WHERE id = ?", [.text(id)])
        }
    }

    /// Atomically delete a set of transactions AND their `legacy_migrations` mappings,
    /// returning a full snapshot for undo. All-or-nothing: any failure rolls the WHOLE
    /// batch back — the database loses nothing. Public production API.
    @discardableResult
    public func deleteBatch(ids: Set<String>) throws -> DeletionSnapshot {
        try deleteBatch(ids: ids, faultInjection: nil)
    }

    /// Internal test entry point: identical to `deleteBatch(ids:)` but with a
    /// fault-injection seam to verify the all-or-nothing rollback. NOT part of the
    /// public API (the fault seam must never be reachable in production).
    @discardableResult
    func deleteBatch(ids: Set<String>, faultInjection: (() throws -> Void)?) throws -> DeletionSnapshot {
        guard !ids.isEmpty else { return DeletionSnapshot(transactionRows: [], legacyMappingRows: []) }

        var transactionRows: [RawRow] = []
        var mappingRows: [RawRow] = []
        // Snapshot reads, mapping deletes and transaction deletes ALL run inside the
        // same transaction, so the captured snapshot is exactly the consistent set that
        // is removed (and a rollback discards both the snapshot and the deletes).
        //
        // Rows are captured RAW (SELECT * → RawRow), NOT via the lossy `Transaction`
        // model: this preserves every column's NULL state and storage class so undo is
        // byte-for-byte verbatim. A non-existent id simply yields no rows (its snapshot
        // entry is skipped) while its DELETEs still run as harmless no-ops.
        try db.transaction {
            for id in ids {
                for r in try db.query("SELECT * FROM transactions WHERE id = ?", [.text(id)]) {
                    transactionRows.append(RawRow(r))
                }
                for r in try db.query("SELECT * FROM legacy_migrations WHERE new_id = ?", [.text(id)]) {
                    mappingRows.append(RawRow(r))
                }
            }

            var deleted = 0
            for id in ids {
                try db.run("DELETE FROM legacy_migrations WHERE new_id = ?", [.text(id)])
                try db.run("DELETE FROM transactions WHERE id = ?", [.text(id)])
                deleted += 1
                if deleted == 1 { try faultInjection?() }   // throwing here rolls back the whole batch
            }
        }
        return DeletionSnapshot(transactionRows: transactionRows, legacyMappingRows: mappingRows)
    }

    /// Atomically restore a deletion snapshot — every `transactions` row and every
    /// `legacy_migrations` row, VERBATIM: each column is re-inserted with its captured
    /// raw value, so SQL `NULL`s, storage classes, the original `created_at` /
    /// `updated_at`, and the mapping's original primary key `id` are all preserved
    /// exactly (no `Transaction`-model coercion). All-or-nothing.
    public func restore(_ snapshot: DeletionSnapshot) throws {
        guard !snapshot.isEmpty else { return }
        try db.transaction {
            for row in snapshot.transactionRows { try insertRawRow(into: "transactions", row) }
            for row in snapshot.legacyMappingRows { try insertRawRow(into: "legacy_migrations", row) }
        }
    }

    /// Re-INSERT a captured raw row into `table`, binding every column's value
    /// verbatim (including `.null`). Column names come from the table's own schema
    /// (`SELECT *`), not from user input, so interpolating them is safe.
    private func insertRawRow(into table: String, _ row: RawRow) throws {
        guard !row.columns.isEmpty else { return }
        let cols = row.columns.joined(separator: ", ")
        let placeholders = Array(repeating: "?", count: row.columns.count).joined(separator: ", ")
        try db.run("INSERT INTO \(table) (\(cols)) VALUES (\(placeholders))", row.values)
    }

    // MARK: - Aggregation

    /// income total/count, expense total/count (net derived) — the factual summary.
    public func summary(from: String? = nil, to: String? = nil) throws -> LedgerSummary {
        func totals(_ type: TransactionType) throws -> (Double, Int) {
            var clauses = ["type = ?"]
            var params: [SQLiteValue] = [.text(type.rawValue)]
            if let from { clauses.append("date >= ?"); params.append(.text(from)) }
            if let to { clauses.append("date <= ?"); params.append(.text(to)) }
            let sql = "SELECT COALESCE(SUM(amount), 0) AS total, COUNT(*) AS cnt FROM transactions WHERE " + clauses.joined(separator: " AND ")
            let row = try db.query(sql, params).first
            return (row?.double("total") ?? 0, row?.int("cnt") ?? 0)
        }
        let inc = try totals(.income)
        let exp = try totals(.expense)
        return LedgerSummary(incomeTotal: inc.0, incomeCount: inc.1, expenseTotal: exp.0, expenseCount: exp.1)
    }

    /// Income/expense totals grouped BY currency — never a single blended total.
    /// Sorted by activity (most transactions first), then currency code.
    public func summaryByCurrency(from: String? = nil, to: String? = nil) throws -> [CurrencySummary] {
        var clauses: [String] = []
        var params: [SQLiteValue] = []
        if let from { clauses.append("date >= ?"); params.append(.text(from)) }
        if let to { clauses.append("date <= ?"); params.append(.text(to)) }
        let whereSQL = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        let rows = try db.query("""
            SELECT currency, type, COALESCE(SUM(amount), 0) AS total, COUNT(*) AS cnt
            FROM transactions\(whereSQL)
            GROUP BY currency, type
            """, params)

        var map: [String: CurrencySummary] = [:]
        for row in rows {
            let cur = row.string("currency") ?? "CNY"
            var s = map[cur] ?? CurrencySummary(currency: cur)
            let total = row.double("total") ?? 0
            let cnt = row.int("cnt") ?? 0
            if row.string("type") == TransactionType.income.rawValue {
                s.incomeTotal += total; s.incomeCount += cnt
            } else {
                s.expenseTotal += total; s.expenseCount += cnt
            }
            map[cur] = s
        }
        return map.values.sorted { a, b in
            a.count != b.count ? a.count > b.count : a.currency < b.currency
        }
    }

    /// Monthly income/expense totals over an optional date range. Pass a `currency`
    /// to keep amounts single-currency — the chart never blends currencies, and with
    /// a range it never mixes in other periods' data.
    public func monthlyTotals(currency: String? = nil, from: String? = nil, to: String? = nil,
                              limitMonths: Int = 12) throws -> [MonthlyTotal] {
        var clauses: [String] = []
        var params: [SQLiteValue] = []
        if let currency { clauses.append("currency = ?"); params.append(.text(currency)) }
        if let from { clauses.append("date >= ?"); params.append(.text(from)) }
        if let to { clauses.append("date <= ?"); params.append(.text(to)) }
        var sql = "SELECT substr(date, 1, 7) AS m, type, COALESCE(SUM(amount), 0) AS total FROM transactions"
        if !clauses.isEmpty { sql += " WHERE " + clauses.joined(separator: " AND ") }
        sql += " GROUP BY m, type ORDER BY m"
        let rows = try db.query(sql, params)
        var buckets: [String: (income: Double, expense: Double)] = [:]
        var order: [String] = []
        for row in rows {
            guard let m = row.string("m"), let typeRaw = row.string("type") else { continue }
            if buckets[m] == nil { buckets[m] = (0, 0); order.append(m) }
            let total = row.double("total") ?? 0
            if typeRaw == TransactionType.income.rawValue { buckets[m]?.income += total }
            else { buckets[m]?.expense += total }
        }
        let all = order.map { MonthlyTotal(month: $0, income: buckets[$0]!.income, expense: buckets[$0]!.expense) }
        return all.suffix(limitMonths).map { $0 }
    }

    // MARK: - Binding helpers

    private func bindings(for t: Transaction) -> [SQLiteValue] {
        [
            .text(t.id), .text(t.type.rawValue), .text(t.date), .real(t.amount),
            optionalReal(t.amountNet), .real(t.taxAmount), .real(t.taxRate), .text(t.currency),
            optionalText(t.categoryID), .text(t.counterparty), .text(t.invoiceNo), .text(t.invoiceStatus.rawValue),
            .text(t.paymentStatus.rawValue), .real(t.paidAmount), optionalText(t.paymentDate), optionalText(t.dueDate),
            .text(t.description), optionalText(t.attachmentPath), optionalText(t.sourceMeta),
        ]
    }

    private func optionalReal(_ d: Double?) -> SQLiteValue { d.map { .real($0) } ?? .null }
    private func optionalText(_ s: String?) -> SQLiteValue {
        guard let s, !s.isEmpty else { return .null }
        return .text(s)
    }
}
