import Foundation

/// A row of the `transactions` table — the canonical income/expense ledger.
/// Money is `Double` (the DB stores REAL, NOT integer cents); dates are ISO
/// `YYYY-MM-DD` strings; currency is an ISO code. This matches the Electron
/// storage conventions exactly so the file stays byte-compatible.
public struct Transaction: Identifiable, Hashable, Sendable {
    public var id: String
    public var type: TransactionType
    public var date: String            // 'YYYY-MM-DD'
    public var amount: Double
    public var amountNet: Double?
    public var taxAmount: Double
    public var taxRate: Double
    public var currency: String
    public var categoryID: String?
    public var counterparty: String
    public var invoiceNo: String
    public var invoiceStatus: InvoiceStatus
    public var paymentStatus: PaymentStatus
    public var paidAmount: Double
    public var paymentDate: String?
    public var dueDate: String?
    public var description: String
    public var attachmentPath: String?
    public var sourceMeta: String?
    public var createdAt: String?
    public var updatedAt: String?

    public init(id: String = IDGenerator.transactionID(),
                type: TransactionType = .expense,
                date: String = DateFormat.today(),
                amount: Double = 0,
                amountNet: Double? = nil,
                taxAmount: Double = 0,
                taxRate: Double = 0,
                currency: String = "CNY",
                categoryID: String? = nil,
                counterparty: String = "",
                invoiceNo: String = "",
                invoiceStatus: InvoiceStatus = .na,
                paymentStatus: PaymentStatus = .paid,
                paidAmount: Double = 0,
                paymentDate: String? = nil,
                dueDate: String? = nil,
                description: String = "",
                attachmentPath: String? = nil,
                sourceMeta: String? = nil,
                createdAt: String? = nil,
                updatedAt: String? = nil) {
        self.id = id; self.type = type; self.date = date; self.amount = amount
        self.amountNet = amountNet; self.taxAmount = taxAmount; self.taxRate = taxRate
        self.currency = currency; self.categoryID = categoryID; self.counterparty = counterparty
        self.invoiceNo = invoiceNo; self.invoiceStatus = invoiceStatus; self.paymentStatus = paymentStatus
        self.paidAmount = paidAmount; self.paymentDate = paymentDate; self.dueDate = dueDate
        self.description = description; self.attachmentPath = attachmentPath; self.sourceMeta = sourceMeta
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    // MARK: - Validation (mirrors transactions.js `validate`)

    public func validationErrors() -> [String] {
        var errors: [String] = []
        if id.isEmpty { errors.append("id required") }
        if date.isEmpty { errors.append("date required") }
        if !amount.isFinite { errors.append("amount must be a number") }
        return errors
    }

    public var isValid: Bool { validationErrors().isEmpty }

    /// Apply the same normalization the JS handler does before persisting:
    /// clamp string lengths, default the currency, coerce non-finite numbers.
    public func normalized() -> Transaction {
        var t = self
        t.currency = String(currency.isEmpty ? "CNY" : currency).prefix(8).description
        t.counterparty = String(counterparty.prefix(200))
        t.invoiceNo = String(invoiceNo.prefix(100))
        t.description = String(description.prefix(1000))
        t.amount = amount.isFinite ? amount : 0
        t.taxAmount = taxAmount.isFinite ? taxAmount : 0
        t.taxRate = taxRate.isFinite ? taxRate : 0
        t.paidAmount = paidAmount.isFinite ? paidAmount : 0
        if let n = amountNet, !n.isFinite { t.amountNet = nil }
        return t
    }

    static func from(_ row: SQLiteRow) -> Transaction? {
        guard let id = row.string("id"),
              let typeRaw = row.string("type"),
              let type = TransactionType(rawValue: typeRaw),
              let date = row.string("date"),
              let amount = row.double("amount") else { return nil }
        return Transaction(
            id: id,
            type: type,
            date: date,
            amount: amount,
            amountNet: row.double("amount_net"),
            taxAmount: row.double("tax_amount") ?? 0,
            taxRate: row.double("tax_rate") ?? 0,
            currency: row.string("currency") ?? "CNY",
            categoryID: row.string("category_id"),
            counterparty: row.string("counterparty") ?? "",
            invoiceNo: row.string("invoice_no") ?? "",
            invoiceStatus: InvoiceStatus(rawValue: row.string("invoice_status") ?? "n/a") ?? .na,
            paymentStatus: PaymentStatus(rawValue: row.string("payment_status") ?? "paid") ?? .paid,
            paidAmount: row.double("paid_amount") ?? 0,
            paymentDate: row.string("payment_date"),
            dueDate: row.string("due_date"),
            description: row.string("description") ?? "",
            attachmentPath: row.string("attachment_path"),
            sourceMeta: row.string("source_meta"),
            createdAt: row.string("created_at"),
            updatedAt: row.string("updated_at")
        )
    }
}

/// Result of `LedgerStore.summary` — the ONLY factual overview metric set
/// (income total, expense total, net). Deliberately no balance-sheet / cash-flow
/// / ratio figures: those are unimplemented and CLAUDE.md forbids showing them.
public struct LedgerSummary: Equatable, Sendable {
    public var incomeTotal: Double
    public var incomeCount: Int
    public var expenseTotal: Double
    public var expenseCount: Int
    public var net: Double { incomeTotal - expenseTotal }

    public init(incomeTotal: Double = 0, incomeCount: Int = 0, expenseTotal: Double = 0, expenseCount: Int = 0) {
        self.incomeTotal = incomeTotal; self.incomeCount = incomeCount
        self.expenseTotal = expenseTotal; self.expenseCount = expenseCount
    }
}

/// Per-currency income/expense totals. Amounts in different currencies are NEVER
/// summed into one figure — each currency is reported separately (no FX conversion
/// is invented). Mirrors the raw stored amounts; the UI presents these per-currency.
public struct CurrencySummary: Identifiable, Equatable, Sendable {
    public var currency: String
    public var incomeTotal: Double
    public var expenseTotal: Double
    public var incomeCount: Int
    public var expenseCount: Int
    public var net: Double { incomeTotal - expenseTotal }
    public var count: Int { incomeCount + expenseCount }
    public var id: String { currency }

    public init(currency: String, incomeTotal: Double = 0, expenseTotal: Double = 0,
                incomeCount: Int = 0, expenseCount: Int = 0) {
        self.currency = currency; self.incomeTotal = incomeTotal; self.expenseTotal = expenseTotal
        self.incomeCount = incomeCount; self.expenseCount = expenseCount
    }
}

/// Sort orders for the transaction list (client- or query-side).
public enum TransactionSort: String, CaseIterable, Sendable {
    case dateDescending, dateAscending, amountDescending, amountAscending

    var orderBy: String {
        switch self {
        case .dateDescending: return "date DESC, created_at DESC"
        case .dateAscending: return "date ASC, created_at ASC"
        case .amountDescending: return "amount DESC, date DESC"
        case .amountAscending: return "amount ASC, date DESC"
        }
    }
}

/// One month's income/expense totals for the Swift Charts overview.
public struct MonthlyTotal: Identifiable, Equatable, Sendable {
    public var month: String   // 'YYYY-MM'
    public var income: Double
    public var expense: Double
    public var id: String { month }
    public var net: Double { income - expense }

    public init(month: String, income: Double, expense: Double) {
        self.month = month; self.income = income; self.expense = expense
    }
}
