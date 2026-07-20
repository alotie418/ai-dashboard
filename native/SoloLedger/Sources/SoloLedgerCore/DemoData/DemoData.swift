import Foundation

/// Synthetic demo data for the Debug/.dev container and screenshots — anonymized,
/// never real user data. Multi-currency on purpose so the per-currency summary and
/// the "not directly summable" presentation are exercised.
public enum DemoData {

    public static func isEmpty(_ store: LedgerStore) throws -> Bool {
        try store.listTransactions(limit: 1).isEmpty
    }

    /// Seed a spread of income/expense across months, categories, currencies and
    /// payment states. IDEMPOTENT: a no-op (returns 0) if the ledger already has any
    /// transaction, and rows use stable `demo-N` ids so a re-run can never duplicate.
    @discardableResult
    public static func seed(into store: LedgerStore, locale: AccountingLocale = .CN) throws -> Int {
        guard try isEmpty(store) else { return 0 }
        let cats = try store.categories(locale: locale)
        func cat(_ slug: String) -> String? { cats.first { $0.slug == slug }?.id }

        // (type, date, amount, currency, categorySlug, counterparty, payment, invoice, desc)
        let rows: [(TransactionType, String, Double, String, String, String, PaymentStatus, InvoiceStatus, String)] = [
            (.income,  "2025-09-08", 12800.00, "CNY", "sales",     "华东贸易",   .paid,    .issued,  "9月项目款"),
            (.expense, "2025-09-12",  3200.00, "CNY", "cogs",      "宏达供应",   .paid,    .issued,  "原料采购"),
            (.expense, "2025-09-25",  4800.00, "CNY", "admin",     "科技园物业", .paid,    .issued,  "办公室租金"),
            (.income,  "2025-10-05",  9600.00, "CNY", "sales",     "南方零售",   .partial, .pending, "首付 60%"),
            (.expense, "2025-10-18",  1290.50, "CNY", "selling",   "灵动广告",   .paid,    .issued,  "线上推广"),
            (.income,  "2025-11-03",  1500.00, "USD", "other",     "Nordic AB",  .paid,    .na,      "海外咨询"),
            (.expense, "2025-11-15",   860.00, "USD", "financial", "Stripe",     .paid,    .na,      "支付手续费"),
            (.income,  "2025-11-28", 18400.00, "CNY", "sales",     "华东贸易",   .paid,    .issued,  "双十一结算"),
            (.expense, "2025-12-06",  5400.00, "CNY", "cogs",      "宏达供应",   .paid,    .issued,  "补货"),
            (.income,  "2025-12-20",  2100.00, "EUR", "other",     "Bourgogne",  .unpaid,  .pending, "样品订单"),
            (.expense, "2025-12-22",  4800.00, "CNY", "admin",     "科技园物业", .paid,    .issued,  "办公室租金"),
            (.income,  "2026-01-09", 15200.00, "CNY", "sales",     "南方零售",   .paid,    .issued,  "年初大单"),
            (.expense, "2026-01-16",  2380.00, "CNY", "selling",   "灵动广告",   .paid,    .issued,  "投放"),
            (.income,  "2026-02-11",  1750.00, "USD", "other",     "Nordic AB",  .paid,    .na,      "续约"),
            (.expense, "2026-02-20",  3120.00, "CNY", "cogs",      "宏达供应",   .partial, .pending, "季度备货"),
            (.income,  "2026-03-04", 11300.00, "CNY", "sales",     "华东贸易",   .paid,    .issued,  "3月回款"),
        ]

        try store.db.transaction {
            for (i, r) in rows.enumerated() {
                var t = Transaction(id: "demo-\(i + 1)", type: r.0, date: r.1, amount: r.2, currency: r.3,
                                    categoryID: cat(r.4), counterparty: r.5,
                                    invoiceStatus: r.7, paymentStatus: r.6, description: r.8)
                if r.6 == .partial { t.paidAmount = (r.2 * 0.6).rounded() }
                if r.6 == .paid { t.paidAmount = r.2; t.paymentDate = r.1 }
                try store.create(t)
            }
        }
        return rows.count
    }
}
