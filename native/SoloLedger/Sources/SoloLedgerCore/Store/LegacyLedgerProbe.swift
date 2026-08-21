import Foundation

/// How much of a ledger still lives in the legacy `sales` / `purchases` tables.
///
/// The native app reads only `transactions`, so a ledger whose records were never
/// converted renders as an EMPTY ledger even though the rows are physically present
/// in the file. This probe exists so the UI can say that plainly instead of showing
/// an empty state that is factually wrong.
///
/// It is strictly READ-ONLY and performs no conversion: converting a legacy row into
/// a transaction changes what the report engines compute for that period, which is an
/// accounting decision this app does not make on its own.
public struct LegacyLedgerSummary: Sendable, Equatable {
    /// Rows in the legacy table (0 when the table is absent).
    public var salesTotal: Int
    public var purchasesTotal: Int
    /// Rows with no `legacy_migrations` mapping — i.e. those a conversion would still
    /// have to carry over, and which the native app therefore cannot show today.
    public var salesUnconverted: Int
    public var purchasesUnconverted: Int
    /// Rows in the OTHER Electron data tables this app does not read either (fixed assets,
    /// liabilities, tax payments, …). They are not convertible into transactions, so they
    /// get no count breakdown — but their presence still means the file is in use, and
    /// an "empty ledger" claim would be just as wrong.
    ///
    /// The examples are kept current on purpose: `products` left this list at 2b-A4 and the two
    /// business-document tables left it at D-6, both because the app grew a page that shows them.
    public var otherRecords: Int

    public init(salesTotal: Int = 0, purchasesTotal: Int = 0,
                salesUnconverted: Int = 0, purchasesUnconverted: Int = 0,
                otherRecords: Int = 0) {
        self.salesTotal = salesTotal
        self.purchasesTotal = purchasesTotal
        self.salesUnconverted = salesUnconverted
        self.purchasesUnconverted = purchasesUnconverted
        self.otherRecords = otherRecords
    }

    public var total: Int { salesTotal + purchasesTotal }
    public var unconverted: Int { salesUnconverted + purchasesUnconverted }
    /// True when the ledger holds legacy sales/purchase records this app cannot display.
    public var hasUnconverted: Bool { unconverted > 0 }
    /// True when the file holds ANY record this app does not show — the honest test for
    /// "is this ledger really empty", and the gate for anything that writes into it.
    public var holdsHiddenRecords: Bool { hasUnconverted || otherRecords > 0 }
}

extension LegacyLedgerSummary {
    /// User-data tables the native app never reads, beyond `sales`/`purchases`.
    ///
    /// Deliberately excludes anything that is not a user RECORD: infrastructure
    /// (`alerts`, `assistant_*`, `ecommerce_*`, `ai_providers`) and the `home_office`
    /// singleton, which schema v6 seeds on every ledger — counting it would put a
    /// "you have hidden records" notice on a brand-new empty ledger.
    ///
    /// `products` left this list when the products page landed (2b-A4), for exactly the
    /// reason `home_office` was never in it: this list means "records the user cannot see
    /// here", and product rows are now on screen with their own page. Leaving it in would
    /// have told a user who had just added their first product that the ledger holds records
    /// this app does not show — while showing them.
    ///
    /// `business_documents` and `business_document_items` left for the same reason at D-6, when the
    /// sidebar gained the business-documents section. The chapter's Q9 stores into those very
    /// tables, so an Electron ledger's quotations and invoices are not merely "shown" in the
    /// abstract — they are the rows that page lists.
    ///
    /// **Leaving this list is not the same as being provably new**, and the two questions must not
    /// be read through one flag. `AppModel` asks the second one separately for both departures —
    /// see the note on `seedCurrencyIfProvablyNew`, where a catalogue conjunct and a documents
    /// conjunct sit beside `holdsHiddenRecords` precisely because visibility loosened this one.
    /// Table names are fixed literals here, never interpolated from input.
    static let otherRecordTables = [
        "accounts", "equity", "fixed_assets", "liabilities", "mileage_logs",
        "price_history", "purchase_items", "sales_items", "tax_payments",
    ]
}

extension LedgerStore {
    /// Count the legacy records, including how many are still unmapped.
    ///
    /// The unconverted count comes from the same anti-join the Electron converter uses
    /// to pick its work set (`LEFT JOIN legacy_migrations … WHERE m.id IS NULL`), so it
    /// answers "records this app cannot show" exactly rather than by subtracting a
    /// mapping count that can outlive its legacy row.
    public func legacyLedgerSummary() throws -> LegacyLedgerSummary {
        var summary = LegacyLedgerSummary()
        let mappingExists = try tableExists("legacy_migrations")

        if try tableExists("sales") {
            summary.salesTotal = try count("SELECT COUNT(*) AS c FROM sales")
            summary.salesUnconverted = mappingExists
                ? try count("""
                    SELECT COUNT(*) AS c FROM sales s
                    LEFT JOIN legacy_migrations m ON m.legacy_table = 'sales' AND m.legacy_id = s.id
                    WHERE m.id IS NULL
                    """)
                : summary.salesTotal
        }
        if try tableExists("purchases") {
            summary.purchasesTotal = try count("SELECT COUNT(*) AS c FROM purchases")
            summary.purchasesUnconverted = mappingExists
                ? try count("""
                    SELECT COUNT(*) AS c FROM purchases p
                    LEFT JOIN legacy_migrations m ON m.legacy_table = 'purchases' AND m.legacy_id = p.id
                    WHERE m.id IS NULL
                    """)
                : summary.purchasesTotal
        }
        for table in LegacyLedgerSummary.otherRecordTables where try tableExists(table) {
            summary.otherRecords += try count("SELECT COUNT(*) AS c FROM \(table)")
        }
        return summary
    }

    private func tableExists(_ name: String) throws -> Bool {
        try db.query("SELECT name FROM sqlite_master WHERE type='table' AND name = ?", [.text(name)])
            .isEmpty == false
    }

    private func count(_ sql: String) throws -> Int {
        try db.query(sql).first?.int("c") ?? 0
    }
}
