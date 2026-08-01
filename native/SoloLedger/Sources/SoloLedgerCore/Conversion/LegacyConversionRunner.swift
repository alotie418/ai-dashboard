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

    /// Internal test entry point. NOT public — neither seam may be reachable in production.
    ///
    /// - Parameter afterBackup: fires inside the transaction, after the backup and BEFORE the
    ///   first database write. That instant is the one the whole snapshot design is about and
    ///   it is otherwise unobservable: `faultInjection` is too late, because by then the first
    ///   row has been written and the connection already holds the write lock, which changes
    ///   what a concurrent writer is even able to do.
    /// - Parameter faultInjection: fires after the first row is written, for the
    ///   all-or-nothing rollback.
    @discardableResult
    func runLegacyConversion(_ request: LegacyConversionRequest,
                             afterBackup: (() throws -> Void)? = nil,
                             faultInjection: (() throws -> Void)?) throws
    -> LegacyConversionReport {
        do {
            return try convertLegacyRows(request, afterBackup: afterBackup,
                                         faultInjection: faultInjection)
        } catch let failure as LegacyConversionFailure {
            throw failure                                  // already classified
        } catch {
            // A lock held by another connection can be met at ANY point, and every one of
            // them means the same thing: nothing was written and the whole conversion can be
            // retried unchanged. Measured, with a second connection holding `BEGIN EXCLUSIVE`
            // on a rollback-journal ledger: the FIRST thing to notice it is the read-only
            // category query, well before the backup — so classifying only at the backup
            // would leave the commonest case surfacing as a raw SQLite error. The backup call
            // site classifies explicitly as well, because the failure it must NOT produce
            // there (`backupFailed`, "your backup is broken") is a different lie.
            if let busy = LegacyConversionRunner.retriableBusyMessage(error) {
                throw LegacyConversionFailure.busy(busy)
            }
            throw error
        }
    }

    private func convertLegacyRows(_ request: LegacyConversionRequest,
                                   afterBackup: (() throws -> Void)?,
                                   faultInjection: (() throws -> Void)?) throws
    -> LegacyConversionReport {
        let plan = request.plan

        // ── A. Request-shape checks. These read NO database ──────────────────────────────
        // Deliberately: they are about the REQUEST, not the ledger, so they must not be the
        // thing that pins a snapshot — and a malformed request must not cost the user a
        // backup. Everything that asks the ledger a question happens inside the transaction.
        let convertible = plan.convertibleIdentities
        for identity in request.skipped.sorted() where !convertible.contains(identity) {
            throw LegacyConversionFailure.skippedIdentityNotConvertible(identity)
        }
        // Belt and braces over a gate the plan already holds: a currency the write path would
        // shorten is blocked in the preflight, so a plan carrying one cannot exist. Asserted
        // here because this is the line that stamps it on every row.
        guard !LegacyConversionPlan.wouldTruncateCurrency(plan.currency) else {
            throw LegacyConversionFailure.writeSetMismatch(
                "the plan's currency would not be stored verbatim")
        }
        let expected = convertible.subtracting(request.skipped)

        // ── B. Nothing to do ────────────────────────────────────────────────────────────
        // No transaction, no backup: re-running a finished conversion must be free and must
        // not litter the backups folder with snapshots of a ledger nothing happened to.
        guard !expected.isEmpty else {
            return LegacyConversionReport(converted: [], backupDirectory: nil)
        }

        // ── C. The one transaction ──────────────────────────────────────────────────────
        //
        // THE BACKUP IS TAKEN INSIDE IT. That is the correction this stage was missing, and
        // it is measured rather than argued. Taking the backup before `BEGIN` leaves a window
        // in which another connection can commit: the transaction then SEES that commit and
        // keeps it, the conversion succeeds, and the "pre-conversion backup" it hands back
        // does not contain it — so restoring that backup to undo the conversion silently
        // undoes the other change too. Reproduced in both journal modes: an external
        // `UPDATE transactions SET amount = 999` in the window left the live ledger at 999
        // and the bundle at 100.
        //
        // A plain deferred `BEGIN` still holds only a READ lock here, so the backup is taken
        // before any write lock exists — the online-backup API runs happily from inside it
        // (measured, both modes) and copies THIS transaction's snapshot, not the live file.
        // What an external commit does next differs by mode and both answers are safe:
        //   WAL     — the commit succeeds, and our first write then fails BUSY, so the whole
        //             batch rolls back and the caller gets a retriable `.busy`.
        //   DELETE  — our read lock refuses the external COMMIT outright.
        // Neither leaves "external commit succeeded AND the conversion shipped a stale backup".
        var converted: Set<LegacyRowIdentity> = []
        do {
            try db.transaction {
                // D — the FIRST read. This is what pins the snapshot everything below shares.
                guard case .plan(let fresh) = try legacyConversionPreflightBody(),
                      fresh == plan else {
                    throw LegacyConversionFailure.ledgerChanged
                }
                // E — recomputed from the FRESH plan and then required to match, rather than
                // reused from step A: the equality above already implies it, and stating it
                // separately means a future change to either side has to break one of two
                // assertions instead of quietly agreeing with itself.
                let expectedFresh = fresh.convertibleIdentities.subtracting(request.skipped)
                guard expectedFresh == expected else {
                    throw LegacyConversionFailure.writeSetMismatch(
                        "the recomputed execution set differs from the one checked")
                }

                // F — categories, on this snapshot, BEFORE the backup: a request naming a
                // category that does not exist must not cost the user a bundle.
                try validateConversionCategories(for: expectedFresh, request: request,
                                                 locale: fresh.accountingLocale)

                // G — the backup, and proof it is readable. Still no write lock.
                do {
                    try BackupExport.writeBundle(database: db,
                                                 attachmentsDir: request.attachmentsDirectory,
                                                 to: request.backupDestination)
                } catch {
                    // A backup refused because another connection holds the database is the
                    // SAME retriable situation as a refused write, and reporting it as
                    // `backupFailed` would tell the user their backup is broken when nothing
                    // is: the online-backup API surfaces it as
                    // `sqlite3_backup_step failed (rc 5)` and succeeds unchanged once the
                    // lock is released. Classified before wrapping, because wrapping turns
                    // the typed error into a string.
                    if let busy = LegacyConversionRunner.retriableBusyMessage(error) {
                        throw LegacyConversionFailure.busy(busy)
                    }
                    throw LegacyConversionFailure.backupFailed("\(error)")
                }
                do {
                    try BackupRestore.validateBundle(request.backupDestination)
                } catch {
                    throw LegacyConversionFailure.backupNotValid("\(error)")
                }

                try afterBackup?()

                let transactionsBefore = try rowCount("transactions")
                let mappingsBefore = try rowCount("legacy_migrations")

                // H — the first database WRITE happens here and nowhere earlier. Per row: the
                // transaction first, then its mapping, matching `migrations.js:116-125`. With
                // no per-row catch the order carries no meaning: either both land or neither.
                for identity in expectedFresh.sorted() {
                    guard let source = try readLegacySourceRow(identity) else {
                        throw LegacyConversionFailure.rowVanished(identity)
                    }
                    let issues = LegacyConversionPlan.issues(in: source.graded)
                    guard issues.isEmpty else {
                        throw LegacyConversionFailure.rowNoLongerConvertible(identity, issues)
                    }
                    // The values, not just the verdict. A clean value replaced by another
                    // clean value leaves the table, the id, the date and the (empty) issue
                    // list identical — measured, sixteen of twenty ordinary edits do exactly
                    // that — so without this the writer would store money the plan never
                    // showed. Reachable inside the transaction: our own writes are visible to
                    // our own later reads, so a trigger that edits a not-yet-converted row is
                    // caught here.
                    guard let planned = fresh.row(table: identity.table,
                                                  legacyID: identity.legacyID),
                          planned.sourceFingerprint
                            == LegacyConversionPlan.sourceFingerprint(of: source.graded) else {
                        throw LegacyConversionFailure.ledgerChanged
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

    /// The SELECT list is ``LegacyConversionPlan/sourceColumns(for:)`` — the same one the plan
    /// scanned with. Two lists would mean two fingerprints over two different column sets, and
    /// the comparison between them would be meaningless.
    private func readLegacySourceRow(_ identity: LegacyRowIdentity) throws
    -> LegacyConversionRunner.SourceRow? {
        let sql = """
            SELECT \(LegacyConversionPlan.sourceColumns(for: identity.table))
              FROM \(identity.table.rawValue) r
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
        /// The whole row, built by ``LegacyConversionPlan/storedRow(from:)`` — the SAME
        /// function the plan's scan uses. The re-grade and the fingerprint comparison are
        /// therefore asking the identical question of the identical shape; two constructors
        /// would let the two sides drift while still looking like they agreed.
        let graded: LegacyConversionPlan.StoredRow
        /// Generated once per row so the `transactions` row and its `legacy_migrations`
        /// mapping cannot disagree about which id was written.
        let newTransactionID: String

        var invoiceStatus: SQLiteValue { graded.invoiceStatus }
        var tons: SQLiteValue { graded.tons }
        var pricePerTon: SQLiteValue { graded.pricePerTon }
        var shippingCost: SQLiteValue { graded.shippingCost }
        var createdAt: SQLiteValue { graded.createdAt }

        init(_ row: SQLiteRow) {
            graded = LegacyConversionPlan.storedRow(from: row)
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
            counterparty: copiedText(g.counterparty),
            invoiceNo: copiedText(g.invoiceNo),
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
            paymentDate: copiedOptionalText(g.paymentDate),
            dueDate: copiedOptionalText(g.dueDate),
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
    /// JavaScript's falsiness is what decides inclusion for four of the five storage classes,
    /// because that is what the source does: `0`, `NULL` and `''` are omitted, and a stored
    /// non-empty TEXT is truthy in JS and included with its text — which is why this reads
    /// the value rather than a number.
    ///
    /// **A BLOB is the deliberate exception, and it is NOT a mirror.** better-sqlite3 hands a
    /// BLOB to `migrations.js` as a `Buffer`, which is truthy, so Electron would interpolate
    /// its bytes into the description — arbitrary binary decoded as text, control characters
    /// and all, in a field the app renders. This omits it instead. Nothing is lost by doing
    /// so: the bytes are kept, tagged and base64-encoded, in `source_meta`, which is where a
    /// value this app cannot render belongs. Registered as an intentional difference from the
    /// source rather than dressed up as parity.
    static func description(for source: SourceRow, table: LegacyTable) -> String {
        [segment("qty", source.tons),
         segment("unit", source.pricePerTon),
         table == .sales ? segment("shipping", source.shippingCost) : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    static func segment(_ label: String, _ value: SQLiteValue) -> String? {
        switch value {
        // NULL is falsy in the source and omitted; a BLOB is truthy there and is omitted
        // ANYWAY — see the note above. The two share a line of code, not a reason.
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
    /// `SQLiteDatabase` may not be changed by this PR, so the numeric result code is read
    /// back out of the message — and it appears in TWO shapes that a single suffix test
    /// cannot cover. Measured against the real strings that type emits:
    ///
    ///     "database is locked (code 5)"                                  ← statement path, at the END
    ///     "sqlite3_backup_step failed (rc 5): database is locked"        ← online-backup path, in the MIDDLE
    ///     "sqlite3_backup_finish failed (rc 5)"                          ← online-backup path, at the end
    ///
    /// So the code is parsed as a DELIMITED TOKEN — `(code N)` or `(rc N)` — never searched
    /// for as a loose substring: a message that merely contains the digit 5 is not a busy
    /// error, and `testOnlyTheBusyFamilyIsClassifiedAsRetriable` pins that.
    ///
    /// Deferred `BEGIN` means the write lock is taken at the first INSERT, so a concurrent
    /// writer surfaces as a failed upgrade — which rolls the transaction back, leaving
    /// nothing to clean up before a retry. A backup refused for the same reason has written
    /// no bundle and opened no transaction, so it is retriable in the same sense.
    static func retriableBusyMessage(_ error: Error) -> String? {
        guard let sqlite = error as? SQLiteError else { return nil }
        let text: String
        switch sqlite {
        case .step(let m), .prepare(let m), .message(let m): text = m
        case .open: return nil
        }
        // SQLITE_BUSY, _RECOVERY, _SNAPSHOT, _TIMEOUT.
        let busy: Set<Int> = [5, 261, 517, 773]
        return resultCodes(in: text).contains(where: busy.contains) ? text : nil
    }

    /// Every `(code N)` / `(rc N)` token in a message, in order.
    static func resultCodes(in text: String) -> [Int] {
        guard let re = try? NSRegularExpression(pattern: #"\((?:code|rc) (\d+)\)"#) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return re.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).flatMap { Int(text[$0]) }
        }
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

    /// A string column copied verbatim. SQL NULL becomes `""` — the registered difference
    /// from `migrations.js`, which wrote NULL — and anything with no text reading traps
    /// rather than being flattened into that same `""`.
    ///
    /// The trap is the third layer, not the gate: ``LegacyRowIssue/counterpartyNotReadableAsText``
    /// and its invoice twin grade such a row `needsAdjudication`, and the re-grade inside the
    /// write transaction re-checks it. Writing `""` here would have reported "no
    /// counterparty" for a row that has one.
    private static func copiedText(_ value: SQLiteValue) -> String {
        guard !LegacyConversionPlan.hasNoTextReading(value) else {
            preconditionFailure("a graded-convertible row held a non-text copied string")
        }
        return value.stringValue ?? ""
    }

    /// An optional date copied verbatim. SQL NULL and the empty string are both a real
    /// absence (`LedgerStore.bindings` turns `""` into SQL NULL); a value with no text
    /// reading is NOT, and traps for the same reason as ``copiedText(_:)``.
    private static func copiedOptionalText(_ value: SQLiteValue) -> String? {
        guard !LegacyConversionPlan.hasNoTextReading(value) else {
            preconditionFailure("a graded-convertible row held a non-text date")
        }
        return value.stringValue
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
