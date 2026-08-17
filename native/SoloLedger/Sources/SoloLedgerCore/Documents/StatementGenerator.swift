import Foundation

/// The statement generator — `docs/BUSINESS_DOCUMENTS_SPEC.md` Q2, **the one invention this chapter
/// accepts**, and the only writer of the `currency` column added at v25.
///
/// ## Why it is an invention rather than a mirror
///
/// Electron builds a statement from the `sales` table. The native ledger writes ten tables and
/// `sales` is not one of them, so a word-for-word port would be a feature that can never produce a
/// single line on a ledger this app created — the shape that got the balance-overview chapter
/// suspended. The ruling redirects the row source to `transactions`, and with it comes a change of
/// meaning that the product copy has to carry (D-3):
///
/// > A native statement is a **period summary of amounts due between you and one customer**, not an
/// > itemised invoice. It summarises a period's income transactions for that customer; it does not
/// > describe goods, and it is not a tax document of any kind.
///
/// ## What it produces, and what it deliberately does not
///
/// It returns ``StatementDraft`` values — one per currency, Q2-d — and stops there. **It assigns no
/// document number and writes nothing.** Numbering is Q3 and belongs to D-2, and Q2-d's consequence
/// ① (N currencies consume N `ST` numbers in one go) is a fact about that round, expressed here as
/// N separate drafts each still needing a number of its own.
public struct StatementDraft: Equatable, Sendable {
    /// The customer, already normalised — this is the value the picker offered, not the raw text of
    /// any one transaction.
    public let customerName: String
    /// The requested period, inclusive at both ends.
    public let periodStart: String
    public let periodEnd: String

    /// The single currency every line here is in, exactly as `transactions.currency` stores it.
    ///
    /// `nil` only when that cell has no text reading at all (a BLOB). Both writers in both apps
    /// clamp an empty currency to `"CNY"` before storing it — `transactions.js:45`
    /// `safeString(data.currency || 'CNY', 8)` and `Transaction.normalized()`'s
    /// `currency.isEmpty ? "CNY" : currency` — so neither an empty nor an unreadable currency is
    /// reachable through any supported path. The `nil` case is carried rather than assumed away,
    /// and it lands as SQL `NULL`, i.e. as "derive the display currency from `acc_locale`".
    public let currency: String?

    /// The lines, in `date, id` order, each already in the shape ``BusinessDocumentLineOrigin``'s
    /// `statementGenerator` case expects.
    public let lines: [BusinessDocumentLineDraft]

    /// Turn this into something ``LedgerStore/createBusinessDocument(_:)`` accepts.
    ///
    /// `number` and `date` are the caller's on purpose. The number is Q3's and this round has no
    /// numbering; the document date is a form field Electron leaves at whatever the editor was
    /// showing (its `generateStatement` does not set it), so choosing one here would be inventing a
    /// rule — "today", "the period end" — that no ruling states.
    public func documentDraft(number: String,
                              date: String,
                              accountingLocale: AccountingLocale? = nil) -> BusinessDocumentDraft {
        BusinessDocumentDraft(type: .statement,
                              number: number,
                              date: date,
                              customerName: customerName,
                              // Q2-d-②: the generator is the first and only writer of this column.
                              periodStart: periodStart,
                              periodEnd: periodEnd,
                              currency: currency,
                              accountingLocale: accountingLocale,
                              lines: lines,
                              lineOrigin: .statementGenerator)
    }
}

public extension LedgerStore {

    /// The customer picker's value domain — Q2 · 4: `transactions.counterparty`, trimmed, empties
    /// dropped, de-duplicated, sorted.
    ///
    /// **No transaction-type filter**, because the ruling names the column and not a subset of it.
    /// The visible consequence is registered rather than designed around: a name that only ever
    /// appears on expenses — a supplier — is offered here, and picking it produces a statement with
    /// no lines. Electron cannot show that, because its picker reads `sales.customer`, a
    /// customers-only table; the native ledger has one counterparty namespace and no way to tell
    /// the two roles apart (Q6 registers exactly this).
    ///
    /// The de-duplication, the ordering and — in ``statementDrafts(customerName:periodStart:periodEnd:)``
    /// — the matching all run on **UTF-16 code units**, which is what JS does and what Q2 · 2 asks
    /// for when it says no folding of any kind. Swift's own `String` equality, hashing and ordering
    /// apply Unicode canonical equivalence, so `Set` and `sorted()` would treat a precomposed `é`
    /// and a decomposed `e` + U+0301 as one string where JS treats them as two. That is not an
    /// abstract difference here: it would merge two picker entries into one and then pull BOTH
    /// customers' money onto a single statement.
    func statementCustomerNames() throws -> [String] {
        let names = try db.query("SELECT counterparty FROM transactions")
            .map { StatementText.normalized($0.string("counterparty")) }
            .filter { !$0.isEmpty }                       // JS `.filter(Boolean)` on a string
            .sorted(by: StatementText.isOrderedBefore)     // JS `Array.prototype.sort()`
        // Equal-by-code-units strings are adjacent after that sort, so one pass de-duplicates with
        // the same identity the sort used. `Set<String>` would use a different one.
        var unique: [String] = []
        for name in names where !(unique.last.map { StatementText.areEqual($0, name) } ?? false) {
            unique.append(name)
        }
        return unique
    }

    /// Q2: the statement rows for one customer over one period, split by currency.
    ///
    /// The selection is exactly the ruling's three clauses, and each is applied where it can be
    /// applied faithfully:
    ///
    ///  * **`type = 'income'`** and the **closed date interval** run in SQL. Both sides compare ISO
    ///    date TEXT, and SQLite's comparison agrees with JS's for text — `listTransactions` filters
    ///    the same two ways for the same reason.
    ///  * **The counterparty match runs in Swift**, because it is "trim both sides, then compare
    ///    exactly" and SQL's `TRIM` strips a different set of characters than
    ///    `String.prototype.trim` does. Q2 · 5 requires the picker and the filter to share ONE
    ///    normalisation, and ``StatementText/normalized(_:)`` is it.
    ///
    /// Rows are ordered `date, id`. Electron sorts its matches by date alone and inherits its
    /// source order for ties; there is no native counterpart to that order, so `id` is the tiebreak
    /// — chosen because it is deterministic and stable, and registered because it is a choice.
    ///
    /// The read does NOT go through ``LedgerStore/listTransactions(type:from:to:categoryID:search:sort:limit:)``,
    /// for two reasons that are both about correctness rather than taste: that API's default caps
    /// the result at 500 rows without telling anyone, and its `Transaction` model types `taxAmount`
    /// as a non-optional `Double`, which erases the very `NULL` Q2-a requires a statement line to
    /// preserve.
    func statementDrafts(customerName: String,
                         periodStart: String,
                         periodEnd: String) throws -> [StatementDraft] {
        let wanted = StatementText.normalized(customerName)
        let rows = try db.query("""
            SELECT id, counterparty, description, currency,
                   COALESCE(amount_net, amount) AS line_amount, tax_amount, date
              FROM transactions
             WHERE type = ? AND date >= ? AND date <= ?
             ORDER BY date, id
            """, [.text(TransactionType.income.rawValue), .text(periodStart), .text(periodEnd)])

        // Buckets are an ARRAY looked up by code-unit identity, not a `Dictionary` keyed by
        // `String`. A dictionary would key on Swift's hashing, which is canonical equivalence —
        // the same folding ``StatementText/areEqual(_:_:)`` exists to avoid, applied to the value
        // that decides how many documents come out.
        var buckets: [(currency: String?, lines: [BusinessDocumentLineDraft])] = []

        for row in rows {
            guard StatementText.areEqual(StatementText.normalized(row.string("counterparty")), wanted) else { continue }
            let currency = row.string("currency")
            let index = buckets.firstIndex { bucket in
                switch (bucket.currency, currency) {
                case let (a?, b?): return StatementText.areEqual(a, b)
                case (nil, nil): return true
                default: return false
                }
            } ?? {
                buckets.append((currency: currency, lines: []))
                return buckets.count - 1
            }()
            buckets[index].lines.append(BusinessDocumentLineDraft(
                // Q2-a. A source transaction with no description keeps its line, stored as `""`:
                // the column is `NOT NULL`, and dropping the line would take a real income
                // transaction's money off a document that goes to a customer — and out of the
                // header totals with it. `NULL` and `""` both arrive here as `""`; the column
                // cannot tell them apart and neither can the customer reading the page.
                description: row.string("description") ?? "",
                // quantity / unit / unitPrice stay nil: a period summary describes no goods, and
                // `transactions` holds none of the three.
                // tax_rate stays nil as well — Q2-b: `transactions.tax_rate` has no agreed
                // dimension anywhere in this schema, and an unlabelled number does not go on a
                // document that leaves the machine.
                taxAmount: Self.optionalMoney(row["tax_amount"]),
                amount: row.double("line_amount"),
                refSalesID: row.string("id"),
                // The only date carrier the line table has; Q2-a settles for it rather than
                // choosing it, and Q2-b gives it its own column instead of Electron's practice of
                // prefixing the date into the description text.
                refDate: row.string("date")))
        }

        // Q2-d: one document per currency. The ORDER is currency code ascending, because it is the
        // order D-2 will consume when it takes N consecutive `ST` numbers — so it must not depend
        // on which transaction happened to be entered first. An unreadable currency sorts last.
        return buckets
            .sorted { a, b in
                switch (a.currency, b.currency) {
                case let (x?, y?): return StatementText.isOrderedBefore(x, y)
                case (nil, _?): return false
                case (_?, nil): return true
                case (nil, nil): return false
                }
            }
            .map { bucket in
                StatementDraft(customerName: wanted,
                               periodStart: periodStart,
                               periodEnd: periodEnd,
                               currency: bucket.currency,
                               lines: bucket.lines)
            }
    }

    /// SQL `NULL` becomes `nil`; anything with a numeric reading becomes that number.
    ///
    /// This is the explicit `NULL` test Q2-a asks for, as opposed to a falsy one: `0` is a tax of
    /// zero and must survive as `0`. A cell with no numeric reading at all (a BLOB) also yields
    /// `nil` — there is no number to carry, and the column's other meaning for `nil`, "nothing was
    /// recorded", is the closer of the two readings.
    internal static func optionalMoney(_ value: SQLiteValue) -> Double? {
        if case .null = value { return nil }
        return value.doubleValue
    }
}

/// The ONE normalisation Q2 · 5 requires the picker and the filter to share, plus the two JS string
/// operations that go with it.
///
/// Kept as its own namespace so "there is only one of these" is visible rather than asserted: both
/// call sites are in this file and both call these functions.
public enum StatementText {

    /// Q2 · 2 and · 4 — `String.prototype.trim()`, and nothing else. No case folding, no fuzzy
    /// matching, no Unicode normalisation.
    ///
    /// A `nil` column reads as the empty string, which is `String(null)`'s role on the JS side of
    /// this comparison: it can never equal a customer name, since a name that trims to empty is
    /// dropped from the picker before it can be chosen.
    public static func normalized(_ raw: String?) -> String {
        guard let raw else { return "" }
        return DocumentMath.jsTrim(raw)
    }

    /// JS `===` for strings: identity of the UTF-16 code-unit sequence.
    ///
    /// Swift's `==` is canonical equivalence, which would report `"e\u{0301}" == "\u{e9}"` as true.
    /// Both spellings render as `é`, so a user cannot see the difference — which is exactly why
    /// merging them silently is the wrong default for a rule the ruling wrote as "exactly equal".
    public static func areEqual(_ a: String, _ b: String) -> Bool {
        a.utf16.elementsEqual(b.utf16)
    }

    /// JS `Array.prototype.sort()`'s default comparator for strings: code-unit order, which is NOT
    /// Swift's `<`. It puts every BMP character before every astral one, because an astral
    /// character is a surrogate pair beginning at U+D800 — below U+E000 and above every CJK block.
    public static func isOrderedBefore(_ a: String, _ b: String) -> Bool {
        var lhs = a.utf16.makeIterator()
        var rhs = b.utf16.makeIterator()
        while true {
            switch (lhs.next(), rhs.next()) {
            case (nil, nil): return false           // equal
            case (nil, _): return true              // a is a prefix of b
            case (_, nil): return false
            case let (l?, r?): if l != r { return l < r }
            }
        }
    }
}
