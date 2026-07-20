import Foundation

/// Headless end-to-end smoke check. Runs the whole data layer (open → migrate →
/// seed → CRUD → summary → CSV round-trip) against a throwaway temp DB and never
/// touches the real preview/production data. Designed to be run from
/// `SoloLedger --self-test` in a headless environment (no WindowServer needed).
public enum SelfTest {

    public struct Report {
        public var passed: Bool
        public var lines: [String]
        public var text: String { lines.joined(separator: "\n") }
    }

    public static func run() -> Report {
        var lines: [String] = []
        var ok = true
        func check(_ label: String, _ condition: Bool, _ detail: String = "") {
            let mark = condition ? "PASS" : "FAIL"
            if !condition { ok = false }
            lines.append("[\(mark)] \(label)\(detail.isEmpty ? "" : " — \(detail)")")
        }

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SoloLedgerSelfTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        do {
            try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            let dbURL = tmpDir.appendingPathComponent("sololedger.db")
            let store = try LedgerStore(databaseURL: dbURL)

            // 1) Schema compatibility
            let version = try store.schemaVersion()
            check("schema migrated to head", version == SchemaMigrator.schemaVersion,
                  "user_version=\(version), expected \(SchemaMigrator.schemaVersion)")

            // 2) Category seed
            let allCats = try countRows(store, "categories")
            check("78 categories seeded", allCats == 78, "found \(allCats)")
            let cnCats = try store.categories(locale: .CN)
            check("CN has 9 categories", cnCats.count == 9, "found \(cnCats.count)")
            let cogs = cnCats.first { $0.slug == "cogs" }
            check("v13 backfilled is_cogs on CN cogs", cogs?.isCOGS == true)

            // 3) Insert income + expense
            let incomeCat = try store.categories(locale: .CN, type: .income).first
            let expenseCat = try store.categories(locale: .CN, type: .expense).first
            try store.create(Transaction(type: .income, date: "2026-01-05", amount: 1000, currency: "CNY",
                                         categoryID: incomeCat?.id, counterparty: "Acme Co", description: "Consulting"))
            try store.create(Transaction(type: .income, date: "2026-02-10", amount: 500, currency: "CNY",
                                         categoryID: incomeCat?.id, counterparty: "Beta Ltd"))
            try store.create(Transaction(type: .expense, date: "2026-02-15", amount: 300, currency: "CNY",
                                         categoryID: expenseCat?.id, counterparty: "Cloud Host",
                                         paymentStatus: .unpaid, description: "Servers"))

            var listed = try store.listTransactions()
            check("listed 3 transactions", listed.count == 3, "found \(listed.count)")

            // 4) Summary
            var summary = try store.summary()
            check("summary income = 1500", summary.incomeTotal == 1500, "got \(summary.incomeTotal)")
            check("summary expense = 300", summary.expenseTotal == 300, "got \(summary.expenseTotal)")
            check("summary net = 1200", summary.net == 1200, "got \(summary.net)")

            // 5) Edit + delete
            if var first = listed.first(where: { $0.counterparty == "Acme Co" }) {
                first.amount = 1200
                try store.update(first)
            }
            summary = try store.summary()
            check("edit updated income to 1700", summary.incomeTotal == 1700, "got \(summary.incomeTotal)")

            if let toDelete = listed.first(where: { $0.type == .expense }) {
                try store.delete(id: toDelete.id)
            }
            listed = try store.listTransactions()
            check("delete removed expense", listed.count == 2, "found \(listed.count)")

            // 6) Validation guard
            var bad = Transaction(type: .income, date: "", amount: 1)
            bad.date = ""
            check("empty date rejected", (try? store.create(bad)) == nil)

            // 7) Monthly aggregation (for charts)
            let months = try store.monthlyTotals()
            check("monthly buckets present", months.count == 2, "found \(months.count)")

            // 8) CSV round-trip into a fresh DB
            let csv = try store.exportTransactionsCSV()
            check("CSV has BOM", csv.hasPrefix("\u{FEFF}"))
            check("CSV header column order matches schema",
                  csv.dropFirst().hasPrefix(TransactionCSV.columns.joined(separator: ",")))
            let dbURL2 = tmpDir.appendingPathComponent("roundtrip.db")
            let store2 = try LedgerStore(databaseURL: dbURL2)
            let imported = try store2.importTransactionsCSV(csv)
            check("CSV imported 2 rows", imported.imported == 2, "imported \(imported.imported), skipped \(imported.skipped)")
            let summary2 = try store2.summary()
            check("round-trip income preserved", summary2.incomeTotal == 1700, "got \(summary2.incomeTotal)")
        } catch {
            check("self-test threw", false, "\(error)")
        }

        lines.append(ok ? "\nSELF-TEST RESULT: PASS ✅" : "\nSELF-TEST RESULT: FAIL ❌")
        return Report(passed: ok, lines: lines)
    }

    private static func countRows(_ store: LedgerStore, _ table: String) throws -> Int {
        try store.db.query("SELECT COUNT(*) AS c FROM \(table)").first?.int("c") ?? 0
    }
}
