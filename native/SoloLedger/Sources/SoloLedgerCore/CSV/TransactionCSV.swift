import Foundation

/// Export/import of `transactions` as CSV.
///
/// The column order matches `PRAGMA table_info(transactions)` (i.e. the export
/// subsystem's ordering in `_csvExport.js`), so a native export lines up with an
/// Electron export. `transactions` has no CSV *import* path in the Electron app,
/// so the round-trip import here is net-new (Phase-1 minimal validation).
public enum TransactionCSV {

    /// Full column order, identical to the `transactions` table definition.
    public static let columns: [String] = [
        "id", "type", "date", "amount", "amount_net", "tax_amount", "tax_rate", "currency",
        "category_id", "counterparty", "invoice_no", "invoice_status",
        "payment_status", "paid_amount", "payment_date", "due_date",
        "description", "attachment_path", "source_meta", "created_at", "updated_at",
    ]

    private static let numericColumns: Set<String> = ["amount", "amount_net", "tax_amount", "tax_rate", "paid_amount"]

    // MARK: - Export

    public static func export(_ transactions: [Transaction], includeBOM: Bool = true) -> String {
        let rows = transactions.map { t -> [CSVCell] in
            columns.map { cell(for: $0, of: t) }
        }
        return CSVWriter.format(rows: rows, header: columns, includeBOM: includeBOM)
    }

    private static func cell(for column: String, of t: Transaction) -> CSVCell {
        switch column {
        case "id": return .text(t.id)
        case "type": return .text(t.type.rawValue)
        case "date": return .text(t.date)
        case "amount": return .number(t.amount)
        case "amount_net": return .number(t.amountNet)
        case "tax_amount": return .number(t.taxAmount)
        case "tax_rate": return .number(t.taxRate)
        case "currency": return .text(t.currency)
        case "category_id": return .text(t.categoryID)
        case "counterparty": return .text(t.counterparty)
        case "invoice_no": return .text(t.invoiceNo)
        case "invoice_status": return .text(t.invoiceStatus.rawValue)
        case "payment_status": return .text(t.paymentStatus.rawValue)
        case "paid_amount": return .number(t.paidAmount)
        case "payment_date": return .text(t.paymentDate)
        case "due_date": return .text(t.dueDate)
        case "description": return .text(t.description)
        case "attachment_path": return .text(t.attachmentPath)
        case "source_meta": return .text(t.sourceMeta)
        case "created_at": return .text(t.createdAt)
        case "updated_at": return .text(t.updatedAt)
        default: return .text(nil)
        }
    }

    // MARK: - Import (net-new)

    public struct ParseResult {
        public var transactions: [Transaction]
        public var skipped: Int
    }

    /// Parse CSV into transactions. Rows missing a valid type/date/amount are
    /// skipped (counted). DB-managed timestamps are ignored; a blank `id` gets a
    /// fresh generated id.
    public static func parse(_ csv: String) -> ParseResult {
        let rows = CSVReader.parse(csv)
        guard let header = rows.first else { return ParseResult(transactions: [], skipped: 0) }
        var index: [String: Int] = [:]
        for (i, name) in header.enumerated() { index[name] = i }

        var out: [Transaction] = []
        var skipped = 0
        for dataRow in rows.dropFirst() {
            if dataRow.allSatisfy({ $0.isEmpty }) { continue } // ignore blank lines
            func field(_ name: String) -> String? {
                guard let i = index[name], i < dataRow.count else { return nil }
                let v = unguard(dataRow[i])
                return v.isEmpty ? nil : v
            }
            guard let typeRaw = field("type"), let type = TransactionType(rawValue: typeRaw),
                  let date = field("date"),
                  let amountStr = field("amount"), let amount = Double(amountStr) else {
                skipped += 1
                continue
            }
            let t = Transaction(
                // Always a fresh id: import is purely ADDITIVE and must never
                // overwrite or collide with an existing row. (Preserving the
                // exported id would abort the whole batch on any pre-existing id.)
                id: IDGenerator.transactionID(),
                type: type,
                date: date,
                amount: amount,
                amountNet: field("amount_net").flatMap(Double.init),
                taxAmount: field("tax_amount").flatMap(Double.init) ?? 0,
                taxRate: field("tax_rate").flatMap(Double.init) ?? 0,
                currency: field("currency") ?? "CNY",
                categoryID: field("category_id"),
                counterparty: field("counterparty") ?? "",
                invoiceNo: field("invoice_no") ?? "",
                invoiceStatus: InvoiceStatus(rawValue: field("invoice_status") ?? "n/a") ?? .na,
                paymentStatus: PaymentStatus(rawValue: field("payment_status") ?? "paid") ?? .paid,
                paidAmount: field("paid_amount").flatMap(Double.init) ?? 0,
                paymentDate: field("payment_date"),
                dueDate: field("due_date"),
                description: field("description") ?? "",
                attachmentPath: field("attachment_path"),
                sourceMeta: field("source_meta")
            )
            out.append(t)
        }
        return ParseResult(transactions: out, skipped: skipped)
    }

    /// Reverse the CSV formula-injection guard: on export a leading "'" is added
    /// ONLY when the original text starts with = + - @ TAB or CR. Strip it back so
    /// round-trips are faithful. (Numbers were never guarded, so numeric fields —
    /// which never start with "'" — pass through untouched.)
    private static func unguard(_ s: String) -> String {
        guard s.first == "'", s.count >= 2 else { return s }
        let second = s[s.index(after: s.startIndex)]
        let dangerous: Set<Character> = ["=", "+", "-", "@", "\t", "\r"]
        return dangerous.contains(second) ? String(s.dropFirst()) : s
    }
}

public extension LedgerStore {
    /// Convenience: export the current (filtered) transactions to a CSV string.
    func exportTransactionsCSV(type: TransactionType? = nil, from: String? = nil, to: String? = nil) throws -> String {
        let txns = try listTransactions(type: type, from: from, to: to, limit: 5000)
        return TransactionCSV.export(txns)
    }

    /// Convenience: parse + insert transactions from CSV. Returns (imported, skipped).
    @discardableResult
    func importTransactionsCSV(_ csv: String) throws -> (imported: Int, skipped: Int) {
        let result = TransactionCSV.parse(csv)
        var imported = 0
        try db.transaction {
            for t in result.transactions {
                try create(t)
                imported += 1
            }
        }
        return (imported, result.skipped)
    }
}
