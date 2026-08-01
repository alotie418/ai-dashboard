import Foundation

/// Carries out the conversion a ``LegacyConversionPlan`` described: legacy `sales` /
/// `purchases` rows become `transactions` rows, each recorded in `legacy_migrations`.
///
/// ## The two properties everything else serves
///
/// **All or nothing.** Every write happens inside ONE transaction. There is no per-row error
/// handling and there is deliberately no `catch` around a row: the Electron converter this
/// replaces wraps each row in `try { … } catch { skipped++ }` inside its transaction
/// (`electron/handlers/migrations.js:106-130`), which commits whatever survived and leaves an
/// orphan `transactions` row behind whenever the mapping insert is the half that failed —
/// after which the legacy row still looks unconverted and a second run duplicates it. Removing
/// the swallow removes that whole class; the ordering fix the gap table proposed is then moot.
///
/// **You convert the plan you were shown.** The user consents to a plan — a row set, a count,
/// a disclosed set of consequences. Between the preflight and the confirmation the Electron
/// app may have written to the same file. So the plan is recomputed INSIDE the write
/// transaction and must equal the one handed in, and the identity set actually converted is
/// asserted equal to `convertible − skipped` before the commit. A ledger that moved is
/// ``LegacyConversionFailure/ledgerChanged``, not a silent conversion of something else.
///
/// ## What it does not do
///
/// It never repairs a value. Every corruption class is graded `needsAdjudication` by
/// ``LegacyConversionPlan`` and therefore never reaches this file — and that is ASSERTED here
/// rather than assumed, by re-grading each row inside the transaction. It never deletes or
/// edits a legacy row: the originals stay exactly as they were, which is what makes the
/// conversion reversible at all. It writes no UI state and touches no settings.
public struct LegacyRowIdentity: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let table: LegacyTable
    public let legacyID: String

    public init(table: LegacyTable, legacyID: String) {
        self.table = table
        self.legacyID = legacyID
    }

    /// COMPOSITE, always. `sales` and `purchases` are independent id spaces — the Electron
    /// converter's own anti-join is scoped by `legacy_table` and `legacy_migrations` is
    /// `UNIQUE(legacy_table, legacy_id)` — so an identity that is only the id would let a
    /// skip of one table silently skip the other table's row of the same name.
    public static func < (lhs: LegacyRowIdentity, rhs: LegacyRowIdentity) -> Bool {
        (lhs.table.rawValue, lhs.legacyID) < (rhs.table.rawValue, rhs.legacyID)
    }

    public var description: String { "\(table.rawValue):\(legacyID)" }
}

public extension LegacyConversionPlan {
    /// The composite identities of every row this plan says can be carried.
    ///
    /// `id` is non-optional here because a row whose id has no text reading is graded
    /// `unconvertible` (``LegacyRowIssue/idNotReadableAsText``), so it cannot appear.
    var convertibleIdentities: Set<LegacyRowIdentity> {
        Set(rows(graded: .convertible).compactMap { row in
            row.id.map { LegacyRowIdentity(table: row.table, legacyID: $0) }
        })
    }
}

/// Everything one conversion needs. All of it is supplied by the caller — nothing is
/// resolved from the environment.
public struct LegacyConversionRequest: Sendable {
    /// The plan the user was shown and agreed to.
    public let plan: LegacyConversionPlan
    /// Rows the user chose to leave behind. Must be a subset of the plan's convertible set.
    public let skipped: Set<LegacyRowIdentity>
    /// Required iff the execution set contains a `sales` row.
    public let defaultIncomeCategoryID: String?
    /// Required iff the execution set contains a `purchases` row.
    public let defaultExpenseCategoryID: String?
    /// Where the pre-conversion backup bundle is written. A COMPLETE url, supplied by the
    /// caller — see the note on ``LedgerStore/runLegacyConversion(_:)`` for why this file
    /// resolves no path of its own.
    public let backupDestination: URL
    /// The live attachments root the backup should mirror.
    public let attachmentsDirectory: URL

    public init(plan: LegacyConversionPlan,
                skipped: Set<LegacyRowIdentity> = [],
                defaultIncomeCategoryID: String? = nil,
                defaultExpenseCategoryID: String? = nil,
                backupDestination: URL,
                attachmentsDirectory: URL) {
        self.plan = plan
        self.skipped = skipped
        self.defaultIncomeCategoryID = defaultIncomeCategoryID
        self.defaultExpenseCategoryID = defaultExpenseCategoryID
        self.backupDestination = backupDestination
        self.attachmentsDirectory = attachmentsDirectory
    }
}

/// What a completed conversion did.
public struct LegacyConversionReport: Equatable, Sendable {
    /// Exactly the identities carried over, sorted. Empty when there was nothing to do.
    public let converted: [LegacyRowIdentity]
    /// The backup bundle written before any row was touched — `nil` only when the execution
    /// set was empty, in which case no backup was taken because nothing was at risk.
    public let backupDirectory: URL?

    public init(converted: [LegacyRowIdentity], backupDirectory: URL?) {
        self.converted = converted
        self.backupDirectory = backupDirectory
    }

    public var convertedCount: Int { converted.count }
}

/// Why a conversion refused. Every case leaves the ledger byte-identical.
public enum LegacyConversionFailure: Error, Equatable, CustomStringConvertible {
    /// A skipped identity is not in the plan's convertible set — it does not exist, belongs to
    /// the other table, or was never convertible. The caller and the plan disagree.
    case skippedIdentityNotConvertible(LegacyRowIdentity)
    /// The execution set contains rows of this direction but no category was supplied for it.
    case categoryRequired(TransactionType)
    case categoryNotFound(id: String)
    case categoryWrongType(id: String, expected: TransactionType, actual: TransactionType)
    /// The category belongs to another accounting regime. Not cosmetic: the report engines
    /// read categories with `WHERE locale = ?`, so a foreign category matches nothing, every
    /// row falls to operating expenses and the P&L's cost-of-sales split silently collapses.
    case categoryWrongLocale(id: String, expected: String, actual: String)
    /// The plan recomputed inside the write transaction differs from the one handed in: the
    /// ledger changed between the preflight and now.
    case ledgerChanged
    /// A row in the execution set was not found when it was re-read. Reachable only alongside
    /// `ledgerChanged`; kept distinct so the failure names what actually happened.
    case rowVanished(LegacyRowIdentity)
    /// A row in the execution set no longer grades clean. This is the assertion that keeps
    /// "corrupt values never reach the writer" a measured fact rather than a comment.
    case rowNoLongerConvertible(LegacyRowIdentity, [LegacyRowIssue])
    /// A closing assertion failed — the set written is not the set that was owed, or the two
    /// tables did not gain the same number of rows. Should be unreachable; if it ever fires,
    /// the transaction is rolled back and nothing is written.
    case writeSetMismatch(String)
    case backupFailed(String)
    case backupNotValid(String)
    /// Another writer held the database. Nothing was written and the whole conversion can be
    /// retried as-is.
    case busy(String)

    public var description: String {
        switch self {
        case .skippedIdentityNotConvertible(let i):
            return "Cannot skip \(i): it is not in the plan's convertible set"
        case .categoryRequired(let t):
            return "The conversion includes \(t.rawValue) rows but no \(t.rawValue) category was chosen"
        case .categoryNotFound(let id): return "Category not found: \(id)"
        case let .categoryWrongType(id, expected, actual):
            return "Category \(id) is \(actual.rawValue); a \(expected.rawValue) category is required"
        case let .categoryWrongLocale(id, expected, actual):
            return "Category \(id) belongs to \(actual), not to this ledger's \(expected)"
        case .ledgerChanged:
            return "The ledger changed since the plan was made; nothing was converted"
        case .rowVanished(let i): return "\(i) is no longer in the ledger"
        case let .rowNoLongerConvertible(i, issues):
            return "\(i) is no longer convertible: \(issues.map(\.rawValue).joined(separator: ", "))"
        case .writeSetMismatch(let m): return "Conversion closing check failed: \(m)"
        case .backupFailed(let m): return "The pre-conversion backup failed: \(m)"
        case .backupNotValid(let m): return "The pre-conversion backup did not validate: \(m)"
        case .busy(let m): return "The ledger is being written by another process: \(m)"
        }
    }
}

// MARK: - The run

extension LedgerStore {

    /// Convert `plan.convertible − skipped`, or write nothing at all.
    ///
    /// The order below is the whole safety argument and is not rearrangeable:
    ///
    /// 1. read-only checks — a bad request must not cost the user a backup;
    /// 2. an EMPTY execution set returns 0 without a backup and without opening a
    ///    transaction, so re-running a finished conversion is free;
    /// 3. the backup is written;
    /// 4. and immediately validated — an unreadable backup is not a safety net, and finding
    ///    that out after the writes would be finding out too late;
    /// 5. only then does the single write transaction open.
    ///
    /// This mirrors `AppModel.restoreFromBackup`'s safety-first order, which snapshots the
    /// live ledger before anything destructive and aborts if the snapshot fails.
    ///
    /// **Never call this from the boot chain.** `AppModelBootTests` T3 proves a ledger holding
    /// unconverted legacy rows is refused by `seedCurrencyIfProvablyNew`, and
    /// `canLoadDemoData` gates on the same `holdsHiddenRecords`; a conversion that ran by
    /// itself would be operating on exactly the ledgers those two protect.
    ///
    /// **`backupDestination` and `attachmentsDirectory` are parameters on purpose.**
    /// `AppPaths.backupsDirectory()` resolves the REAL location, so a Core routine that called
    /// it would reach live user data from any unsandboxed harness. `restoreFromBackup` takes
    /// the same two as parameters for the same reason.
    @discardableResult
    public func runLegacyConversion(_ request: LegacyConversionRequest) throws
    -> LegacyConversionReport {
        try runLegacyConversion(request, faultInjection: nil)
    }

    /// Internal test entry point: identical, with a seam that fires after the first row is
    /// written so the all-or-nothing rollback can be proved. NOT public — the seam must be
    /// unreachable in production.
    @discardableResult
    func runLegacyConversion(_ request: LegacyConversionRequest,
                             faultInjection: (() throws -> Void)?) throws
    -> LegacyConversionReport {
        let plan = request.plan

        // ── 1. Read-only checks ─────────────────────────────────────────────────────────
        let convertible = plan.convertibleIdentities
        for identity in request.skipped.sorted() where !convertible.contains(identity) {
            throw LegacyConversionFailure.skippedIdentityNotConvertible(identity)
        }
        let expected = convertible.subtracting(request.skipped)

        // Belt and braces over a gate the plan already holds: a currency the write path would
        // shorten is `ReportBlocker`-style blocked in the preflight, so a plan carrying one
        // cannot exist. Asserted here because this is the line that stamps it on every row.
        guard !LegacyConversionPlan.wouldTruncateCurrency(plan.currency) else {
            throw LegacyConversionFailure.writeSetMismatch(
                "the plan's currency would not be stored verbatim")
        }
        try validateConversionCategories(for: expected, request: request,
                                         locale: plan.accountingLocale)

        // ── 2. Nothing to do ────────────────────────────────────────────────────────────
        // Before the backup, deliberately: re-running a finished conversion must be free and
        // must not litter the backups folder with snapshots of a ledger nothing happened to.
        guard !expected.isEmpty else {
            return LegacyConversionReport(converted: [], backupDirectory: nil)
        }

        // ── 3/4. Backup, then prove the backup is readable ──────────────────────────────
        do {
            try BackupExport.writeBundle(database: db,
                                         attachmentsDir: request.attachmentsDirectory,
                                         to: request.backupDestination)
        } catch {
            throw LegacyConversionFailure.backupFailed("\(error)")
        }
        do {
            try BackupRestore.validateBundle(request.backupDestination)
        } catch {
            throw LegacyConversionFailure.backupNotValid("\(error)")
        }

        // ── 5. The one transaction ──────────────────────────────────────────────────────
        var converted: Set<LegacyRowIdentity> = []
        do {
            try db.transaction {
                // 6a — the plan, recomputed on the view this transaction will write into.
                guard case .plan(let fresh) = try legacyConversionPreflightBody(),
                      fresh == plan else {
                    throw LegacyConversionFailure.ledgerChanged
                }
                // Recomputed from the FRESH plan and then required to match, rather than
                // reused from step 1: the equality above already implies it, and stating it
                // separately means a future change to either side has to break one of two
                // assertions instead of quietly agreeing with itself.
                let expectedFresh = fresh.convertibleIdentities.subtracting(request.skipped)
                guard expectedFresh == expected else {
                    throw LegacyConversionFailure.writeSetMismatch(
                        "the recomputed execution set differs from the one checked")
                }

                // 6b — categories again, on this transaction's view. A category deleted
                // between step 1 and here would otherwise be caught only by the FK, which
                // reports an id and not a reason.
                try validateConversionCategories(for: expectedFresh, request: request,
                                                 locale: fresh.accountingLocale)

                let transactionsBefore = try rowCount("transactions")
                let mappingsBefore = try rowCount("legacy_migrations")

                // 7 — per row: the transaction first, then its mapping, matching
                // `migrations.js:116-125`. With no per-row catch the order carries no
                // meaning: either both land or neither does.
                for identity in expectedFresh.sorted() {
                    guard let source = try readLegacySourceRow(identity) else {
                        throw LegacyConversionFailure.rowVanished(identity)
                    }
                    let issues = LegacyConversionPlan.issues(in: source.graded)
                    guard issues.isEmpty else {
                        throw LegacyConversionFailure.rowNoLongerConvertible(identity, issues)
                    }
                    try create(LegacyConversionRunner.transaction(
                        from: source, identity: identity, request: request, plan: fresh))
                    try db.run("""
                        INSERT INTO legacy_migrations (legacy_table, legacy_id, new_id)
                        VALUES (?, ?, ?)
                        """, [.text(identity.table.rawValue), .text(identity.legacyID),
                              .text(source.newTransactionID)])
                    converted.insert(identity)
                    if converted.count == 1 { try faultInjection?() }
                }

                // 8 — closing assertions, still inside the transaction so a failure rolls
                // everything back. Identity sets, not counts: two rows converted twice and
                // one missed would pass a count check.
                guard converted == expectedFresh else {
                    throw LegacyConversionFailure.writeSetMismatch(
                        "converted \(converted.sorted()) but owed \(expectedFresh.sorted())")
                }
                let gainedTransactions = try rowCount("transactions") - transactionsBefore
                let gainedMappings = try rowCount("legacy_migrations") - mappingsBefore
                guard gainedTransactions == expectedFresh.count,
                      gainedMappings == expectedFresh.count else {
                    throw LegacyConversionFailure.writeSetMismatch(
                        "gained \(gainedTransactions) transactions and \(gainedMappings) "
                        + "mappings for \(expectedFresh.count) rows")
                }
            }
        } catch {
            // A conversion refused because another process held the database is retriable
            // as-is: the transaction rolled back, so there is nothing to undo first.
            if let busy = LegacyConversionRunner.retriableBusyMessage(error) {
                throw LegacyConversionFailure.busy(busy)
            }
            throw error
        }

        return LegacyConversionReport(converted: converted.sorted(),
                                      backupDirectory: request.backupDestination)
    }

    // MARK: - Categories

    /// Existence, direction and REGIME, checked before any write and again inside the
    /// transaction. The foreign key is not allowed to be the only check: it fires mid-write
    /// with an opaque message, and it cannot see the other two questions at all.
    private func validateConversionCategories(for expected: Set<LegacyRowIdentity>,
                                              request: LegacyConversionRequest,
                                              locale: AccountingLocale) throws {
        // Only the directions actually present are required. Demanding an expense category
        // for a conversion that carries no purchases would be asking the user to make a
        // choice with no consequence.
        for direction in Set(expected.map(\.table.transactionType)).sorted(by: {
            $0.rawValue < $1.rawValue
        }) {
            let chosen = direction == .income
                ? request.defaultIncomeCategoryID
                : request.defaultExpenseCategoryID
            guard let id = chosen, !id.isEmpty else {
                throw LegacyConversionFailure.categoryRequired(direction)
            }
            guard let row = try db.query(
                "SELECT id, locale, type FROM categories WHERE id = ?", [.text(id)]).first
            else { throw LegacyConversionFailure.categoryNotFound(id: id) }

            guard let typeRaw = row.string("type"),
                  let actualType = TransactionType(rawValue: typeRaw) else {
                throw LegacyConversionFailure.categoryNotFound(id: id)
            }
            guard actualType == direction else {
                throw LegacyConversionFailure.categoryWrongType(
                    id: id, expected: direction, actual: actualType)
            }
            let actualLocale = row.string("locale") ?? ""
            guard actualLocale == locale.rawValue else {
                throw LegacyConversionFailure.categoryWrongLocale(
                    id: id, expected: locale.rawValue, actual: actualLocale)
            }
        }
    }

    private func rowCount(_ table: String) throws -> Int {
        // Fixed literals only; `table` is never derived from stored data.
        try db.query("SELECT COUNT(*) AS c FROM \(table)").first?.int("c") ?? 0
    }

    // MARK: - Reading one legacy row

    private func readLegacySourceRow(_ identity: LegacyRowIdentity) throws
    -> LegacyConversionRunner.SourceRow? {
        let table = identity.table
        let shipping = table == .sales ? "r.shippingCost" : "NULL"
        let sql = """
            SELECT r.id AS id, r.date AS date, r.\(table.counterpartyColumn) AS counterparty,
                   r.invoiceNumber AS invoiceNumber, r.invoiceStatus AS invoiceStatus,
                   r.totalAmount AS totalAmount, r.amountWithoutTax AS amountWithoutTax,
                   r.taxAmount AS taxAmount, r.taxRate AS taxRate,
                   r.paid_amount AS paid_amount, r.payment_status AS payment_status,
                   r.payment_date AS payment_date, r.due_date AS due_date,
                   r.tons AS tons, r.pricePerTon AS pricePerTon,
                   \(shipping) AS shippingCost, r.created_at AS created_at
              FROM \(table.rawValue) r
             WHERE r.id = ?
            """
        guard let row = try db.query(sql, [.text(identity.legacyID)]).first else { return nil }
        return LegacyConversionRunner.SourceRow(row)
    }
}

// MARK: - Building the transaction

enum LegacyConversionRunner {

    /// One legacy row as read for conversion: the columns the plan grades, plus the ones only
    /// the writer needs. The graded subset is rebuilt into a `StoredRow` so the re-grade
    /// inside the transaction asks EXACTLY the question the preflight asked.
    struct SourceRow {
        let graded: LegacyConversionPlan.StoredRow
        let invoiceStatus: SQLiteValue
        let tons: SQLiteValue
        let pricePerTon: SQLiteValue
        let shippingCost: SQLiteValue
        let createdAt: SQLiteValue
        /// Generated once per row so the `transactions` row and its `legacy_migrations`
        /// mapping cannot disagree about which id was written.
        let newTransactionID: String

        init(_ row: SQLiteRow) {
            graded = LegacyConversionPlan.StoredRow(
                id: row["id"], date: row["date"], counterparty: row["counterparty"],
                invoiceNo: row["invoiceNumber"],
                totalAmount: row["totalAmount"], amountWithoutTax: row["amountWithoutTax"],
                taxAmount: row["taxAmount"], taxRate: row["taxRate"],
                paidAmount: row["paid_amount"], paymentStatus: row["payment_status"],
                paymentDate: row["payment_date"], dueDate: row["due_date"])
            invoiceStatus = row["invoiceStatus"]
            tons = row["tons"]
            pricePerTon = row["pricePerTon"]
            shippingCost = row["shippingCost"]
            createdAt = row["created_at"]
            newTransactionID = IDGenerator.transactionID()
        }
    }

    /// The write specification, in one place.
    ///
    /// Reached only for rows the plan graded convertible AND that re-graded clean moments
    /// ago, so every numeric read below is a value the plan proved finite. `?? 0` would be the
    /// optimistic coercion this whole stage exists to refuse; the values are read through
    /// ``LegacyConversionPlan/numericField(_:)`` and a non-usable one cannot arrive.
    static func transaction(from source: SourceRow, identity: LegacyRowIdentity,
                            request: LegacyConversionRequest,
                            plan: LegacyConversionPlan) -> Transaction {
        let g = source.graded
        return Transaction(
            // A fresh UUID. The legacy id is carried by `legacy_migrations` and by
            // `source_meta`; putting it in the primary key too would be a third copy, and
            // would let arbitrary stored bytes into a key.
            id: source.newTransactionID,
            type: identity.table.transactionType,
            // Verbatim. The plan proved the first ten characters are a real calendar day; it
            // did not licence rewriting the eleventh onwards.
            date: g.date.stringValue ?? "",
            amount: usable(g.totalAmount),
            // A stored 0 is a real value and stays 0; SQL NULL means "fall back to the gross
            // amount" in both engines and stays NULL. Unreadable cannot arrive.
            amountNet: optionalUsable(g.amountWithoutTax),
            taxAmount: usable(g.taxAmount),
            taxRate: usable(g.taxRate),
            currency: plan.currency,
            categoryID: identity.table.transactionType == .income
                ? request.defaultIncomeCategoryID
                : request.defaultExpenseCategoryID,
            counterparty: g.counterparty.stringValue ?? "",
            invoiceNo: g.invoiceNo.stringValue ?? "",
            invoiceStatus: mapInvoiceStatus(source.invoiceStatus),
            // The conservative correction: an empty or absent status carries over as `unpaid`
            // — the legacy column's own DEFAULT — and NOT as Electron's optimistic `paid`
            // (`migrations.js:121,158`). Any other string is graded `needsAdjudication` and
            // cannot arrive, so there is no third branch to guess at.
            paymentStatus: PaymentStatus(rawValue: g.paymentStatus.stringValue ?? "") ?? .unpaid,
            paidAmount: usable(g.paidAmount),
            // `LedgerStore.bindings` turns an empty string into SQL NULL for these two, so an
            // empty stored date becomes a real absence rather than a `''` that
            // `COALESCE(payment_date, date)` would take at face value.
            paymentDate: g.paymentDate.stringValue,
            dueDate: g.dueDate.stringValue,
            description: description(for: source, table: identity.table),
            // Legacy rows carry no attachment.
            attachmentPath: nil,
            sourceMeta: sourceMeta(for: source, identity: identity, request: request))
        // created_at / updated_at are left to the column defaults on purpose: they record when
        // the row entered `transactions`, which is now. The legacy timestamp is preserved in
        // `source_meta` rather than forged into a column that means something else.
    }

    /// `migrations.js:94`, verbatim. The four recognised values are Chinese because the
    /// legacy screens were; every other value — including the English an EU or US ledger
    /// would hold — maps to `n/a`. Mirrored rather than widened: inventing a mapping for a
    /// status this app never wrote would be inventing a fact about the user's invoicing.
    static func mapInvoiceStatus(_ stored: SQLiteValue) -> InvoiceStatus {
        switch stored.stringValue {
        case "已开", "已收": return .issued
        case "待开", "待收": return .pending
        default: return .na
        }
    }

    /// `migrations.js:110-114` / `:148-151` — language-neutral, and only the segments the
    /// legacy row actually has. `purchases` has no shipping column, so it never gets that
    /// segment (the SELECT binds `NULL` there).
    ///
    /// JavaScript's falsiness is what decides inclusion, because that is what the source
    /// does: `0`, `NULL` and `''` are all omitted. A stored non-empty TEXT is truthy in JS
    /// and is included with its text, which is why this reads the value rather than a number.
    static func description(for source: SourceRow, table: LegacyTable) -> String {
        [segment("qty", source.tons),
         segment("unit", source.pricePerTon),
         table == .sales ? segment("shipping", source.shippingCost) : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    static func segment(_ label: String, _ value: SQLiteValue) -> String? {
        switch value {
        case .null, .blob: return nil
        case .integer(let i): return i == 0 ? nil : "\(label)=\(i)"
        case .real(let d):
            if d == 0 { return nil }
            guard d.isFinite else { return "\(label)=\(d > 0 ? "Infinity" : "-Infinity")" }
            // `JSONFragment.encodeNumber` is `JSON.stringify` for a finite Double, which is
            // also what JS template interpolation produces — 10.0 prints as `10`, not `10.0`.
            return "\(label)=\(JSONFragment.encodeNumber(d))"
        case .text(let s): return s.isEmpty ? nil : "\(label)=\(s)"
        }
    }

    /// The audit record. Everything the conversion could not carry into a typed column lives
    /// here, and nothing here is read back by any report.
    ///
    /// `.sortedKeys` because `JSON.stringify` preserves insertion order and Swift dictionaries
    /// do not: without it the same ledger would produce different bytes on different runs and
    /// no test could compare them.
    static func sourceMeta(for source: SourceRow, identity: LegacyRowIdentity,
                           request: LegacyConversionRequest) -> String? {
        var object: [String: Any] = [
            "migrated_from": identity.table.rawValue,
            "legacy_id": identity.legacyID,
            "tons": auditValue(source.tons),
            "pricePerTon": auditValue(source.pricePerTon),
            "legacy_created_at": auditValue(source.createdAt),
            "legacy_invoice_status": auditValue(source.invoiceStatus),
            "legacy_payment_status": auditValue(source.graded.paymentStatus),
            "default_income_category_id": request.defaultIncomeCategoryID ?? NSNull(),
            "default_expense_category_id": request.defaultExpenseCategoryID ?? NSNull(),
        ]
        // Sales only, exactly as `migrations.js:123` versus `:160`.
        if identity.table == .sales { object["shippingCost"] = auditValue(source.shippingCost) }

        guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    /// A stored value rendered so the JSON is always producible AND always tells the truth
    /// about what was there.
    ///
    /// `tons`, `pricePerTon` and `shippingCost` are NOT graded by the plan — nothing depends
    /// on them, so a row holding `9e999` or `'1,000'` in one of them is still convertible.
    /// That makes them the one place a non-finite Double could reach `JSONSerialization`,
    /// which THROWS on one; a throw here would abort a whole batch over a column no report
    /// reads. So a non-finite number becomes a tagged object rather than a number, and a BLOB
    /// becomes a tagged base64 object rather than the empty value a lossy reader would give.
    /// Nothing is coerced into a plain number that was not stored as one.
    static func auditValue(_ value: SQLiteValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .integer(let i): return NSNumber(value: i)
        case .real(let d):
            guard d.isFinite else {
                return ["sqlite_type": "real", "value": d > 0 ? "Infinity" : "-Infinity"]
            }
            return NSNumber(value: d)
        case .text(let s): return s
        case .blob(let data):
            return ["sqlite_type": "blob", "base64": data.base64EncodedString()]
        }
    }

    /// The message of a `SQLITE_BUSY` family error, or nil.
    ///
    /// `SQLiteDatabase` puts the numeric code at the END of the message
    /// (`"\(lastMessage) (code \(rc))"`), and this file may not change that type, so the code
    /// is read back out of the suffix. Deferred `BEGIN` means the write lock is taken at the
    /// first INSERT, so a concurrent writer surfaces as a failed upgrade — which rolls the
    /// transaction back, leaving nothing to clean up before a retry.
    static func retriableBusyMessage(_ error: Error) -> String? {
        guard let sqlite = error as? SQLiteError else { return nil }
        let text: String
        switch sqlite {
        case .step(let m), .prepare(let m), .message(let m): text = m
        case .open: return nil
        }
        // SQLITE_BUSY, _RECOVERY, _SNAPSHOT, _TIMEOUT.
        for code in [5, 261, 517, 773] where text.hasSuffix("(code \(code))") { return text }
        return nil
    }

    // MARK: - Numeric reads

    /// Reached only for values the plan proved usable, and it says so by trapping rather than
    /// substituting: a 0 written here because a read failed would be exactly the fabricated
    /// number the whole design refuses. The re-grade immediately upstream is what makes this
    /// unreachable, and `LegacyConversionRunnerTests` proves the re-grade fires.
    private static func usable(_ value: SQLiteValue) -> Double {
        guard case .usable(let d) = LegacyConversionPlan.numericField(value) else {
            preconditionFailure("a graded-convertible row held an unusable number")
        }
        return d
    }

    /// The one column where absence is representable, so absence is preserved.
    private static func optionalUsable(_ value: SQLiteValue) -> Double? {
        switch LegacyConversionPlan.numericField(value) {
        case .usable(let d): return d
        case .absent: return nil
        case .notANumber, .notFinite:
            preconditionFailure("a graded-convertible row held an unreadable amount_net")
        }
    }
}
