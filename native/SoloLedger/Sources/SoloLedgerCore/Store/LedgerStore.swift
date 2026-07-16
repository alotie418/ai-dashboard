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

/// The prototype's data access layer over one SQLite connection. Opens the DB,
/// applies the runtime PRAGMAs and full migration ladder, seeds categories, and
/// exposes the Phase-1 CRUD/aggregation surface — a faithful port of the Electron
/// `transactions` / `categories` / `settings` handlers.
public final class LedgerStore {
    public let db: SQLiteDatabase
    public let settings: SettingsStore

    /// Open (creating if needed) the DB at `url`, then migrate + seed.
    public init(databaseURL: URL) throws {
        self.db = try SQLiteDatabase(path: databaseURL.path)
        self.settings = SettingsStore(db)
        try applyPragmas()
        try SchemaMigrator.migrate(db)
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
