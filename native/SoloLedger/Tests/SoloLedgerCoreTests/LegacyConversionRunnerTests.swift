import XCTest
@testable import SoloLedgerCore

/// The writer. Every test here asks one of two questions: did the right rows arrive, and —
/// far more often — did NOTHING arrive when something was wrong.
///
/// Counts are never the whole assertion. A conversion that wrote one row twice and missed
/// another would satisfy every count in this file; the identity SETS are what is compared.
final class LegacyConversionRunnerTests: LedgerTestCase {

    // MARK: - Fixtures

    private struct Fixture {
        let store: LedgerStore
        let dbURL: URL
        let backupDir: URL
        let attachmentsDir: URL
    }

    private func fixture(locale: String = "CN", currency: String = "CNY") throws -> Fixture {
        let dir = try trackedTempDir()
        let dbURL = dir.appendingPathComponent("ledger.db")
        let store = try LedgerStore(databaseURL: dbURL)
        try store.settings.setString(locale, for: SettingsStore.Key.accountingLocale)
        try store.settings.setString(currency, for: SettingsStore.Key.currency)
        return Fixture(store: store, dbURL: dbURL,
                       backupDir: dir.appendingPathComponent("pre-convert-20260801-120000"),
                       attachmentsDir: dir.appendingPathComponent("attachments/docs"))
    }

    /// Defaults are a clean, convertible sale. Every column is overridable as a RAW
    /// `SQLiteValue` so a test can pin the storage class it means.
    private func insertSale(_ f: Fixture, id: String,
                            date: SQLiteValue = .text("2024-03-10"),
                            customer: SQLiteValue = .text("旧客户甲"),
                            tons: SQLiteValue = .real(10),
                            pricePerTon: SQLiteValue = .real(800),
                            totalAmount: SQLiteValue = .real(9040),
                            amountWithoutTax: SQLiteValue = .real(8000),
                            taxAmount: SQLiteValue = .real(1040),
                            taxRate: SQLiteValue = .real(13),
                            shippingCost: SQLiteValue = .real(300),
                            invoiceNumber: SQLiteValue = .text("OLD-001"),
                            invoiceStatus: SQLiteValue = .text("已开"),
                            paymentStatus: SQLiteValue = .text("paid"),
                            paidAmount: SQLiteValue = .real(9040),
                            paymentDate: SQLiteValue = .text("2024-03-15"),
                            dueDate: SQLiteValue = .null,
                            createdAt: SQLiteValue = .text("2019-01-01 00:00:00")) throws {
        try f.store.db.run("""
            INSERT INTO sales (id, date, customer, tons, pricePerTon, totalAmount,
                               amountWithoutTax, taxAmount, taxRate, shippingCost,
                               invoiceNumber, invoiceStatus, payment_status, paid_amount,
                               payment_date, due_date, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [.text(id), date, customer, tons, pricePerTon, totalAmount, amountWithoutTax,
                  taxAmount, taxRate, shippingCost, invoiceNumber, invoiceStatus,
                  paymentStatus, paidAmount, paymentDate, dueDate, createdAt])
    }

    private func insertPurchase(_ f: Fixture, id: String,
                                date: SQLiteValue = .text("2024-03-01"),
                                supplier: SQLiteValue = .text("旧供应商甲"),
                                tons: SQLiteValue = .real(12),
                                pricePerTon: SQLiteValue = .real(500),
                                totalAmount: SQLiteValue = .real(6780),
                                amountWithoutTax: SQLiteValue = .real(6000),
                                taxAmount: SQLiteValue = .real(780),
                                taxRate: SQLiteValue = .real(13),
                                invoiceNumber: SQLiteValue = .text("OLD-P1"),
                                invoiceStatus: SQLiteValue = .text("已收"),
                                paymentStatus: SQLiteValue = .text("paid"),
                                paidAmount: SQLiteValue = .real(6780),
                                createdAt: SQLiteValue = .text("2019-02-02 00:00:00")) throws {
        try f.store.db.run("""
            INSERT INTO purchases (id, date, supplier, tons, pricePerTon, totalAmount,
                                   amountWithoutTax, taxAmount, taxRate, invoiceNumber,
                                   invoiceStatus, payment_status, paid_amount, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [.text(id), date, supplier, tons, pricePerTon, totalAmount, amountWithoutTax,
                  taxAmount, taxRate, invoiceNumber, invoiceStatus, paymentStatus, paidAmount,
                  createdAt])
    }

    private func plan(_ f: Fixture, file: StaticString = #filePath, line: UInt = #line) throws
    -> LegacyConversionPlan {
        switch try f.store.legacyConversionPreflight() {
        case .plan(let p): return p
        case .blocked(let b):
            XCTFail("expected a plan, got \(b)", file: file, line: line)
            throw XCTSkip("blocked")
        }
    }

    private func request(_ f: Fixture, _ p: LegacyConversionPlan,
                         skipped: Set<LegacyRowIdentity> = [],
                         income: String? = "cn-income-sales",
                         expense: String? = "cn-expense-cogs",
                         backupDir: URL? = nil) -> LegacyConversionRequest {
        LegacyConversionRequest(plan: p, skipped: skipped,
                                defaultIncomeCategoryID: income,
                                defaultExpenseCategoryID: expense,
                                backupDestination: backupDir ?? f.backupDir,
                                attachmentsDirectory: f.attachmentsDir)
    }

    private func counts(_ f: Fixture) throws -> (transactions: Int, mappings: Int) {
        (try f.store.db.query("SELECT COUNT(*) AS c FROM transactions").first?.int("c") ?? -1,
         try f.store.db.query("SELECT COUNT(*) AS c FROM legacy_migrations").first?.int("c") ?? -1)
    }

    /// Every legacy row, verbatim, so a test can prove the originals were not touched.
    private func legacySnapshot(_ f: Fixture) throws -> [String] {
        let sales = try f.store.db.query("SELECT * FROM sales ORDER BY id")
        let purchases = try f.store.db.query("SELECT * FROM purchases ORDER BY id")
        return (sales + purchases).map { row in
            row.columns.map { "\($0)=\(row[$0])" }.joined(separator: "|")
        }
    }

    private func sid(_ id: String) -> LegacyRowIdentity { .init(table: .sales, legacyID: id) }
    private func pid(_ id: String) -> LegacyRowIdentity { .init(table: .purchases, legacyID: id) }

    /// Assert a closure throws the expected conversion failure AND changed nothing at all.
    private func assertRefusedAndUntouched(
        _ f: Fixture, _ expected: LegacyConversionFailure,
        file: StaticString = #filePath, line: UInt = #line,
        _ body: () throws -> Void
    ) throws {
        let before = try counts(f)
        let legacyBefore = try legacySnapshot(f)
        do {
            try body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as LegacyConversionFailure {
            XCTAssertEqual(error, expected, file: file, line: line)
        }
        XCTAssertEqual(try counts(f).transactions, before.transactions,
                       "transactions changed", file: file, line: line)
        XCTAssertEqual(try counts(f).mappings, before.mappings,
                       "legacy_migrations changed", file: file, line: line)
        XCTAssertEqual(try legacySnapshot(f), legacyBefore,
                       "a legacy row was modified", file: file, line: line)
    }

    // MARK: - The happy path

    func testAConvertibleLedgerIsCarriedOverExactlyOnce() throws {
        let f = try fixture()
        try insertSale(f, id: "s-1")
        try insertPurchase(f, id: "p-1")
        let p = try plan(f)

        let report = try f.store.runLegacyConversion(request(f, p))

        XCTAssertEqual(Set(report.converted), [sid("s-1"), pid("p-1")])
        XCTAssertEqual(report.convertedCount, 2)
        XCTAssertEqual(report.backupDirectory, f.backupDir)
        XCTAssertEqual(try counts(f).transactions, 2)
        XCTAssertEqual(try counts(f).mappings, 2)
        // The originals are untouched — that is what makes the conversion reversible.
        XCTAssertEqual(try f.store.db.query("SELECT COUNT(*) AS c FROM sales")
            .first?.int("c"), 1)
        // And the probe now agrees there is nothing left unconverted.
        XCTAssertEqual(try f.store.legacyLedgerSummary().unconverted, 0)
    }

    func testTheMappingPointsAtTheRowItCreated() throws {
        let f = try fixture()
        try insertSale(f, id: "s-1")
        _ = try f.store.runLegacyConversion(request(f, try plan(f)))

        let map = try XCTUnwrap(f.store.db.query("SELECT * FROM legacy_migrations").first)
        XCTAssertEqual(map.string("legacy_table"), "sales")
        XCTAssertEqual(map.string("legacy_id"), "s-1")
        let newID = try XCTUnwrap(map.string("new_id"))
        XCTAssertNotNil(try f.store.transaction(id: newID),
                        "the mapping names a transaction that exists")
        XCTAssertTrue(newID.hasPrefix("txn-"))
        XCTAssertFalse(newID.contains("s-1"), "the legacy id must not be in the primary key")
    }

    // MARK: - 1. Atomicity

    /// A trigger that aborts the SECOND `transactions` insert. The first row is already
    /// written when it fires, so this is exactly the state a per-row `catch` would commit.
    func testAFailureOnTheSecondTransactionRowRollsTheWholeBatchBack() throws {
        let f = try fixture()
        try insertSale(f, id: "s-1")
        try insertSale(f, id: "s-2")
        try insertPurchase(f, id: "p-1")
        let p = try plan(f)
        try f.store.db.execute("""
            CREATE TRIGGER boom BEFORE INSERT ON transactions
            WHEN (SELECT COUNT(*) FROM transactions) >= 1
            BEGIN SELECT RAISE(ABORT, 'injected'); END
            """)
        let before = try counts(f)
        let legacyBefore = try legacySnapshot(f)

        XCTAssertThrowsError(try f.store.runLegacyConversion(request(f, p)))

        XCTAssertEqual(try counts(f).transactions, before.transactions)
        XCTAssertEqual(try counts(f).mappings, before.mappings)
        XCTAssertEqual(try legacySnapshot(f), legacyBefore)
    }

    /// The other half: the mapping insert is the one that fails. Electron's converter commits
    /// an orphan `transactions` row in exactly this case (`migrations.js:127-130` swallows it),
    /// after which the legacy row still reads as unconverted and a second run duplicates it.
    func testAFailureOnTheMappingInsertLeavesNoOrphanTransaction() throws {
        let f = try fixture()
        try insertSale(f, id: "s-1")
        try insertSale(f, id: "s-2")
        let p = try plan(f)
        try f.store.db.execute("""
            CREATE TRIGGER boom BEFORE INSERT ON legacy_migrations
            BEGIN SELECT RAISE(ABORT, 'injected'); END
            """)

        XCTAssertThrowsError(try f.store.runLegacyConversion(request(f, p)))

        XCTAssertEqual(try counts(f).transactions, 0, "no orphan transaction survived")
        XCTAssertEqual(try counts(f).mappings, 0)
        XCTAssertEqual(try f.store.legacyLedgerSummary().unconverted, 2)
    }

    /// The internal seam, fired after the first row — the same shape `deleteBatch` uses to
    /// prove its own all-or-nothing behaviour.
    func testTheFaultSeamAfterTheFirstRowRollsEverythingBack() throws {
        let f = try fixture()
        try insertSale(f, id: "s-1")
        try insertSale(f, id: "s-2")
        let p = try plan(f)
        struct Boom: Error {}

        XCTAssertThrowsError(try f.store.runLegacyConversion(request(f, p),
                                                             faultInjection: { throw Boom() }))
        XCTAssertEqual(try counts(f).transactions, 0)
        XCTAssertEqual(try counts(f).mappings, 0)
    }

    /// **The per-row re-grade, reached.** It cannot be reached by editing the ledger before
    /// the call — that changes the plan and `ledgerChanged` fires first — so the corruption is
    /// injected DURING the transaction, by a trigger that damages the next row as the previous
    /// one is written. This is the defence that keeps "the writer never faces a corrupt value"
    /// a measured fact instead of an inference from the plan's grading.
    func testARowCorruptedMidTransactionIsCaughtByTheRegradeAndRollsEverythingBack() throws {
        let f = try fixture()
        try insertSale(f, id: "s-1")
        try insertSale(f, id: "s-2")
        let p = try plan(f)
        try f.store.db.execute("""
            CREATE TRIGGER corrupt AFTER INSERT ON transactions
            BEGIN UPDATE sales SET totalAmount = 'not a number' WHERE id = 's-2'; END
            """)

        do {
            _ = try f.store.runLegacyConversion(request(f, p))
            XCTFail("expected the re-grade to refuse")
        } catch let error as LegacyConversionFailure {
            XCTAssertEqual(error,
                           .rowNoLongerConvertible(sid("s-2"), [.totalAmountNotANumber]))
        }
        XCTAssertEqual(try counts(f).transactions, 0)
        XCTAssertEqual(try counts(f).mappings, 0)
        // The trigger's own write is rolled back with everything else.
        XCTAssertEqual(try f.store.db.query(
            "SELECT typeof(totalAmount) AS t FROM sales WHERE id='s-2'").first?.string("t"),
                       "real")
    }

    /// The same seam for the other in-loop refusal: a row that disappears mid-transaction.
    func testARowDeletedMidTransactionIsReportedAsVanished() throws {
        let f = try fixture()
        try insertSale(f, id: "s-1")
        try insertSale(f, id: "s-2")
        let p = try plan(f)
        try f.store.db.execute("""
            CREATE TRIGGER vanish AFTER INSERT ON transactions
            BEGIN DELETE FROM sales WHERE id = 's-2'; END
            """)

        do {
            _ = try f.store.runLegacyConversion(request(f, p))
            XCTFail("expected the vanished row to refuse")
        } catch let error as LegacyConversionFailure {
            XCTAssertEqual(error, .rowVanished(sid("s-2")))
        }
        XCTAssertEqual(try counts(f).transactions, 0)
        XCTAssertEqual(try f.store.db.query("SELECT COUNT(*) AS c FROM sales")
            .first?.int("c"), 2, "the deletion rolled back too")
    }

    // MARK: - 1b. Category validation

    func testAMissingCategoryForADirectionThatIsPresentIsRefused() throws {
        let f = try fixture()
        try insertSale(f, id: "s-1")
        let p = try plan(f)
        try assertRefusedAndUntouched(f, .categoryRequired(.income)) {
            _ = try f.store.runLegacyConversion(request(f, p, income: nil))
        }
        try assertRefusedAndUntouched(f, .categoryRequired(.income)) {
            _ = try f.store.runLegacyConversion(request(f, p, income: ""))
        }
    }

    /// Only the directions actually present are demanded. A conversion carrying no purchases
    /// must not make the user choose an expense category it will never use.
    func testACategoryIsNotDemandedForADirectionThatIsAbsent() throws {
        let f = try fixture()
        try insertSale(f, id: "s-1")
        let report = try f.store.runLegacyConversion(request(f, try plan(f), expense: nil))
        XCTAssertEqual(Set(report.converted), [sid("s-1")])
    }

    func testANonExistentCategoryIsRefused() throws {
        let f = try fixture()
        try insertSale(f, id: "s-1")
        let p = try plan(f)
        try assertRefusedAndUntouched(f, .categoryNotFound(id: "no-such-category")) {
            _ = try f.store.runLegacyConversion(request(f, p, income: "no-such-category"))
        }
    }

    func testACategoryOfTheWrongDirectionIsRefused() throws {
        let f = try fixture()
        try insertSale(f, id: "s-1")
        let p = try plan(f)
        try assertRefusedAndUntouched(
            f, .categoryWrongType(id: "cn-expense-cogs", expected: .income, actual: .expense)
        ) {
            _ = try f.store.runLegacyConversion(request(f, p, income: "cn-expense-cogs"))
        }
    }

    /// **The one that would not have shown up as an error.** A US category on a CN ledger
    /// exists and has the right direction; the FK accepts it. But `ReportFetch.categories`
    /// reads `WHERE locale = ?`, so it matches nothing, `_expenseSplit` treats every row as
    /// uncategorised, and the P&L's cost-of-sales silently collapses to zero.
    func testACategoryFromAnotherAccountingRegimeIsRefused() throws {
        let f = try fixture()
        try insertPurchase(f, id: "p-1")
        let p = try plan(f)
        // Control: it really does exist and really is an expense category.
        let row = try XCTUnwrap(f.store.db.query(
            "SELECT locale, type FROM categories WHERE id = ?",
            [.text("us-expense-advertising")]).first)
        XCTAssertEqual(row.string("type"), "expense")
        XCTAssertEqual(row.string("locale"), "US")

        try assertRefusedAndUntouched(
            f, .categoryWrongLocale(id: "us-expense-advertising", expected: "CN", actual: "US")
        ) {
            _ = try f.store.runLegacyConversion(
                request(f, p, expense: "us-expense-advertising"))
        }
    }

    /// A category deleted between the request and the write is caught by the SECOND
    /// validation, inside the transaction — not by the foreign key, which reports an id
    /// without a reason.
    func testACategoryDeletedAfterTheRequestIsCaughtInsideTheTransaction() throws {
        let f = try fixture()
        try insertSale(f, id: "s-1")
        let p = try plan(f)
        // Deleting a category does not change the plan, so this reaches the in-transaction
        // check rather than `ledgerChanged`.
        try f.store.db.run("DELETE FROM categories WHERE id = ?", [.text("cn-income-sales")])
        try assertRefusedAndUntouched(f, .categoryNotFound(id: "cn-income-sales")) {
            _ = try f.store.runLegacyConversion(request(f, p))
        }
    }

    // MARK: - 2. Backup

    func testAFailedBackupStopsBeforeAnyTransactionIsOpened() throws {
        let f = try fixture()
        try insertSale(f, id: "s-1")
        let p = try plan(f)
        try FileManager.default.createDirectory(at: f.backupDir, withIntermediateDirectories: true)

        let dbBefore = try Data(contentsOf: f.dbURL)
        let walBefore = try? Data(contentsOf: URL(fileURLWithPath: f.dbURL.path + "-wal"))

        do {
            _ = try f.store.runLegacyConversion(request(f, p))
            XCTFail("expected the backup to fail")
        } catch let error as LegacyConversionFailure {
            guard case .backupFailed = error else { return XCTFail("got \(error)") }
        }
        XCTAssertEqual(try counts(f).transactions, 0)
        XCTAssertEqual(try counts(f).mappings, 0)
        XCTAssertEqual(try Data(contentsOf: f.dbURL), dbBefore,
                       "the database file changed, so a transaction was opened")
        XCTAssertEqual(try? Data(contentsOf: URL(fileURLWithPath: f.dbURL.path + "-wal")),
                       walBefore)
    }

    func testTheBackupItWritesIsOneTheRestorePathAccepts() throws {
        let f = try fixture()
        try insertSale(f, id: "s-1")
        _ = try f.store.runLegacyConversion(request(f, try plan(f)))
        XCTAssertNoThrow(try BackupRestore.validateBundle(f.backupDir))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: f.backupDir.appendingPathComponent("sololedger.db").path))
    }

    /// The ORDER, proved from the other side: when the transaction fails, the backup is
    /// already on disk and still valid, and the ledger gained nothing.
    func testABackupTakenBeforeAFailedTransactionSurvivesAndTheLedgerDoesNot() throws {
        let f = try fixture()
        try insertSale(f, id: "s-1")
        try insertSale(f, id: "s-2")
        let p = try plan(f)
        try f.store.db.execute("""
            CREATE TRIGGER boom BEFORE INSERT ON transactions
            WHEN (SELECT COUNT(*) FROM transactions) >= 1
            BEGIN SELECT RAISE(ABORT, 'injected'); END
            """)

        XCTAssertThrowsError(try f.store.runLegacyConversion(request(f, p)))

        XCTAssertTrue(FileManager.default.fileExists(atPath: f.backupDir.path),
                      "the backup must precede the transaction")
        XCTAssertNoThrow(try BackupRestore.validateBundle(f.backupDir))
        XCTAssertEqual(try counts(f).transactions, 0)
        XCTAssertEqual(try counts(f).mappings, 0)
    }

    /// Take a REAL exclusive lock on the ledger from a second connection. WAL does not
    /// reproduce contention here (a backup reads a snapshot), and `BEGIN IMMEDIATE` blocks
    /// neither reads nor the backup — both measured — so the ledger is switched to a rollback
    /// journal and the lock is `BEGIN EXCLUSIVE`. Instant, deterministic, releases cleanly.
    private func lockLedgerExclusively(_ f: Fixture) throws -> SQLiteDatabase {
        try f.store.db.execute("PRAGMA journal_mode = DELETE")
        try f.store.db.execute("PRAGMA busy_timeout = 0")
        let other = try SQLiteDatabase(path: f.dbURL.path)
        try other.execute("PRAGMA busy_timeout = 0")
        try other.execute("BEGIN EXCLUSIVE")
        return other
    }

    /// **The backup path's own error, produced for real and routed for real.**
    ///
    /// The online-backup API reports a lock as `sqlite3_backup_step failed (rc 5): …` — the
    /// code sits in the MIDDLE of the message and uses `rc`, not `code`, a shape the
    /// statement path never emits. A classifier written for the statement path alone reads it
    /// as an ordinary failure, and the conversion then tells the user their BACKUP is broken
    /// when nothing is broken and a retry would succeed.
    ///
    /// Nothing here is simulated: `BackupExport.writeBundle` is called against a genuinely
    /// locked ledger and the error it actually throws is fed through the actual routing.
    func testTheRealBackupErrorUnderALockIsClassifiedRetriable() throws {
        let f = try fixture()
        let other = try lockLedgerExclusively(f)
        defer { try? other.execute("ROLLBACK"); try? other.close() }

        var thrown: Error?
        do {
            try BackupExport.writeBundle(database: f.store.db,
                                         attachmentsDir: f.attachmentsDir,
                                         to: f.backupDir)
            XCTFail("a locked ledger must refuse the backup")
        } catch { thrown = error }

        let error = try XCTUnwrap(thrown)
        XCTAssertTrue("\(error)".contains("sqlite3_backup_step failed (rc 5)"), "\(error)")
        // The routing, on that exact error — not on a string this test made up.
        XCTAssertNotNil(LegacyConversionRunner.retriableBusyMessage(error),
                        "the backup path's own error must classify as retriable")
        // And the discrimination that matters: it must NOT become `backupFailed`.
        XCTAssertEqual(LegacyConversionRunner.resultCodes(in: "\(error)"), [5])
    }

    /// **A locked ledger is retriable, not broken — end to end.**
    ///
    /// Note WHERE the lock is noticed: measured, the first statement to meet it is the
    /// read-only category query, before the backup is ever attempted. There is no lock state
    /// that blocks the backup while permitting reads (`EXCLUSIVE` blocks both, `IMMEDIATE`
    /// blocks neither), so classifying only at the backup call site would leave the commonest
    /// real case surfacing as a raw SQLite error. Both are classified; this proves the whole
    /// run, and the test above proves the backup path's own error.
    func testALockedLedgerRefusesRetriablyAndWritesNothing() throws {
        let f = try fixture()
        try insertSale(f, id: "s-1")
        let p = try plan(f)
        let other = try lockLedgerExclusively(f)

        do {
            _ = try f.store.runLegacyConversion(request(f, p))
            XCTFail("expected the locked ledger to refuse")
        } catch let error as LegacyConversionFailure {
            guard case .busy(let message) = error else {
                return XCTFail("a locked ledger must be `busy`, not \(error)")
            }
            XCTAssertEqual(LegacyConversionRunner.resultCodes(in: message), [5], message)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.backupDir.path),
                       "no bundle was left behind")

        // Retriable in the literal sense: the same work succeeds once the lock is gone.
        try other.execute("ROLLBACK")
        try other.close()
        XCTAssertEqual(try counts(f).transactions, 0)
        XCTAssertEqual(try counts(f).mappings, 0)
        let report = try f.store.runLegacyConversion(request(f, try plan(f)))
        XCTAssertEqual(Set(report.converted), [sid("s-1")])
    }

    /// A backup that failed for any OTHER reason stays `backupFailed` — the routing is for
    /// the busy family alone and must not have swallowed the rest.
    func testANonBusyBackupFailureIsStillReportedAsBackupFailed() throws {
        let f = try fixture()
        try insertSale(f, id: "s-1")
        let p = try plan(f)
        try FileManager.default.createDirectory(at: f.backupDir, withIntermediateDirectories: true)
        do {
            _ = try f.store.runLegacyConversion(request(f, p))
            XCTFail("expected a backup failure")
        } catch let error as LegacyConversionFailure {
            guard case .backupFailed = error else { return XCTFail("got \(error)") }
        }
    }

    // MARK: - 2b. The backup and the conversion see ONE snapshot

    /// **P1-②, WAL.** The backup is taken INSIDE the conversion's transaction, after the
    /// snapshot is pinned and before any write. So an external connection that commits during
    /// the run cannot end up in the ledger-that-was-converted while being absent from the
    /// bundle: in WAL the external commit succeeds, and our first write then fails BUSY, so
    /// the whole batch rolls back.
    ///
    /// The lock is real and the timing is deterministic: the external commit is made from the
    /// `faultInjection` seam, which fires after the first row is written — i.e. strictly after
    /// the backup and strictly inside the transaction.
    func testAnExternalCommitAfterTheSnapshotCannotProduceAStaleBackup() throws {
        let f = try fixture()
        try insertSale(f, id: "s-1")
        try insertSale(f, id: "s-2")
        try f.store.create(Transaction(id: "pre", type: .income, date: "2024-05-01",
                                       amount: 100, currency: "CNY", paymentStatus: .unpaid))
        let p = try plan(f)
        XCTAssertEqual(try f.store.db.query("PRAGMA journal_mode").first?.string("journal_mode"),
                       "wal", "control: the store really is in WAL")

        let other = try SQLiteDatabase(path: f.dbURL.path)
        var externalCommit = "not attempted"
        do {
            _ = try f.store.runLegacyConversion(request(f, p), afterBackup: {
                // Strictly after the backup, strictly before the first write — the instant
                // the snapshot design exists for.
                do {
                    try other.execute("BEGIN IMMEDIATE")
                    _ = try other.run("UPDATE transactions SET amount = 999 WHERE id = 'pre'")
                    try other.execute("COMMIT")
                    externalCommit = "committed"
                } catch { try? other.execute("ROLLBACK"); externalCommit = "refused: \(error)" }
            }, faultInjection: nil)
            XCTFail("a conversion racing an external commit must not report success")
        } catch let error as LegacyConversionFailure {
            guard case .busy = error else { return XCTFail("expected .busy, got \(error)") }
        }
        try other.close()
        XCTAssertEqual(externalCommit, "committed",
                       "WAL lets the external writer through while we hold only a read lock")

        // Zero written by us; the external commit survives; the bundle is the pinned snapshot.
        XCTAssertEqual(try counts(f).transactions, 1, "only the pre-existing row")
        XCTAssertEqual(try counts(f).mappings, 0)
        XCTAssertEqual(try f.store.db.query(
            "SELECT amount FROM transactions WHERE id='pre'").first?["amount"], .real(999),
                       "the external commit must be preserved")
        XCTAssertNoThrow(try BackupRestore.validateBundle(f.backupDir))
        let bundled = try Self.bundleValue(f.backupDir,
                                           "SELECT amount FROM transactions WHERE id='pre'", "amount")
        XCTAssertEqual(bundled, .real(100),
                       "the bundle is the snapshot the conversion would have written into")
    }

    /// **P1-②, rollback journal.** The combination the ruling forbids — external commit
    /// succeeded AND the conversion shipped with a backup taken before it — must not occur.
    /// Here our read lock refuses the external COMMIT outright, so the conversion completes
    /// and the bundle it produced really is the state it converted from.
    func testInRollbackJournalTheForbiddenCombinationCannotOccur() throws {
        let f = try fixture()
        try f.store.db.execute("PRAGMA journal_mode = DELETE")
        try insertSale(f, id: "s-1")
        try insertSale(f, id: "s-2")
        try f.store.create(Transaction(id: "pre", type: .income, date: "2024-05-01",
                                       amount: 100, currency: "CNY", paymentStatus: .unpaid))
        let p = try plan(f)

        let other = try SQLiteDatabase(path: f.dbURL.path)
        try other.execute("PRAGMA busy_timeout = 0")
        var externalCommit = "not attempted"
        let report = try f.store.runLegacyConversion(request(f, p), afterBackup: {
            do {
                try other.execute("BEGIN IMMEDIATE")
                _ = try other.run("UPDATE transactions SET amount = 999 WHERE id = 'pre'")
                try other.execute("COMMIT")
                externalCommit = "committed"
            } catch { try? other.execute("ROLLBACK"); externalCommit = "refused" }
        }, faultInjection: nil)
        try other.close()

        XCTAssertEqual(externalCommit, "refused",
                       "our read lock must refuse the external COMMIT in rollback-journal mode")
        XCTAssertEqual(report.convertedCount, 2)
        // The forbidden pair, stated directly.
        XCTAssertFalse(externalCommit == "committed" && report.convertedCount > 0,
                       "external commit succeeded AND the conversion shipped a stale backup")
        XCTAssertEqual(try f.store.db.query(
            "SELECT amount FROM transactions WHERE id='pre'").first?["amount"], .real(100))
    }

    /// The success path, end to end: the bundle restores to exactly the pre-conversion
    /// database — the converted rows and their mappings are absent from it, everything else is
    /// there — and a file the database references arrives byte for byte.
    func testTheBundleIsThePreConversionStateAndCarriesAReferencedAttachment() throws {
        let f = try fixture()
        try FileManager.default.createDirectory(at: f.attachmentsDir,
                                                withIntermediateDirectories: true)
        let bytes = Data([0x25, 0x50, 0x44, 0x46, 0x00, 0xff])          // "%PDF" + two raw bytes
        try bytes.write(to: f.attachmentsDir.appendingPathComponent("receipt.pdf"))
        try f.store.create(Transaction(id: "pre", type: .income, date: "2024-05-01", amount: 100,
                                       currency: "CNY", paymentStatus: .unpaid,
                                       attachmentPath: "attachments/docs/receipt.pdf"))
        try insertSale(f, id: "s-1")

        let report = try f.store.runLegacyConversion(request(f, try plan(f)))
        XCTAssertEqual(report.convertedCount, 1)

        // The database half.
        XCTAssertEqual(try Self.bundleValue(f.backupDir,
                                            "SELECT COUNT(*) AS c FROM transactions", "c"),
                       .integer(1), "the converted row must be absent from a PRE-conversion backup")
        XCTAssertEqual(try Self.bundleValue(f.backupDir,
                                            "SELECT COUNT(*) AS c FROM legacy_migrations", "c"),
                       .integer(0))
        XCTAssertEqual(try Self.bundleValue(f.backupDir,
                                            "SELECT COUNT(*) AS c FROM sales", "c"),
                       .integer(1), "the legacy row is still there, untouched")
        XCTAssertEqual(try Self.bundleValue(
            f.backupDir, "SELECT attachment_path AS p FROM transactions WHERE id='pre'", "p"),
                       .text("attachments/docs/receipt.pdf"))
        // The file half — byte for byte, including the non-UTF-8 bytes.
        let bundled = try Data(contentsOf: f.backupDir
            .appendingPathComponent("attachments/docs/receipt.pdf"))
        XCTAssertEqual(bundled, bytes)
    }

    /// A conversion that failed AFTER the backup leaves the bundle where it is — deleting it
    /// would throw away the only snapshot of the state the failure interrupted. Retrying into
    /// the same directory is refused; a new directory behaves normally.
    func testAFailedConversionKeepsItsBundleAndRetryNeedsANewDirectory() throws {
        let f = try fixture()
        try insertSale(f, id: "s-1")
        try insertSale(f, id: "s-2")
        let p = try plan(f)
        try f.store.db.execute("""
            CREATE TRIGGER boom AFTER INSERT ON transactions
            WHEN (SELECT COUNT(*) FROM transactions) >= 1
            BEGIN SELECT RAISE(ABORT, 'injected'); END
            """)
        XCTAssertThrowsError(try f.store.runLegacyConversion(request(f, p)))

        XCTAssertTrue(FileManager.default.fileExists(atPath: f.backupDir.path),
                      "the bundle from the interrupted attempt must be kept")
        XCTAssertNoThrow(try BackupRestore.validateBundle(f.backupDir))
        XCTAssertEqual(try counts(f).transactions, 0)

        // Same directory → refused, and still nothing written.
        do {
            _ = try f.store.runLegacyConversion(request(f, p))
            XCTFail("retrying into an existing bundle directory must be refused")
        } catch let error as LegacyConversionFailure {
            guard case .backupFailed(let m) = error else { return XCTFail("got \(error)") }
            XCTAssertTrue(m.contains("already exists"), m)
        }
        XCTAssertEqual(try counts(f).transactions, 0)

        // A new directory: deterministic. (Still refused here, by the trigger — the point is
        // that the refusal is now the trigger's, not the leftover directory's.)
        try f.store.db.execute("DROP TRIGGER boom")
        let second = try trackedTempDir().appendingPathComponent("pre-convert-retry")
        let report = try f.store.runLegacyConversion(request(f, try plan(f), backupDir: second))
        XCTAssertEqual(report.convertedCount, 2)
        XCTAssertEqual(report.backupDirectory, second)
    }

    /// One value from a bundle's database, read the way a restore would.
    private static func bundleValue(_ bundle: URL, _ sql: String, _ column: String) throws
    -> SQLiteValue {
        let db = try SQLiteDatabase(path: bundle.appendingPathComponent("sololedger.db").path,
                                    mode: .readOnly)
        defer { try? db.close() }
        return try db.query(sql).first?[column] ?? .null
    }

    /// An empty execution set is free: no backup directory is created at all.
    func testAnEmptyExecutionSetTakesNoBackupAndWritesNothing() throws {
        let f = try fixture()
        let report = try f.store.runLegacyConversion(request(f, try plan(f)))
        XCTAssertEqual(report.converted, [])
        XCTAssertNil(report.backupDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.backupDir.path))
        XCTAssertEqual(try counts(f).transactions, 0)
    }

    // MARK: - 3. Plan ↔ Runner

    func testALegacyRowAddedAfterThePlanIsLedgerChanged() throws {
        let f = try fixture()
        try insertSale(f, id: "s-1")
        let stale = try plan(f)
        try insertSale(f, id: "s-2")
        try assertRefusedAndUntouched(f, .ledgerChanged) {
            _ = try f.store.runLegacyConversion(request(f, stale))
        }
    }

    func testALegacyRowRemovedAfterThePlanIsLedgerChanged() throws {
        let f = try fixture()
        try insertSale(f, id: "s-1")
        try insertSale(f, id: "s-2")
        let stale = try plan(f)
        try f.store.db.run("DELETE FROM sales WHERE id = ?", [.text("s-2")])
        try assertRefusedAndUntouched(f, .ledgerChanged) {
            _ = try f.store.runLegacyConversion(request(f, stale))
        }
    }

    func testASettingChangedAfterThePlanIsLedgerChanged() throws {
        let f = try fixture()
        try insertSale(f, id: "s-1")
        let stale = try plan(f)
        try f.store.settings.setString("USD", for: SettingsStore.Key.currency)
        try assertRefusedAndUntouched(f, .ledgerChanged) {
            _ = try f.store.runLegacyConversion(request(f, stale))
        }
    }

    /// A single field of the plan, edited by hand. `LegacyConversionPlan` is `Equatable`, so
    /// the whole value is compared and no field is exempt.
    func testAPlanWithOneAlteredFieldIsLedgerChanged() throws {
        let f = try fixture()
        try insertSale(f, id: "s-1")
        let real = try plan(f)
        let tampered = LegacyConversionPlan(
            accountingLocale: real.accountingLocale, currency: real.currency,
            rows: real.rows, headersWithLineItems: real.headersWithLineItems + 1,
            yearOutlook: real.yearOutlook)
        try assertRefusedAndUntouched(f, .ledgerChanged) {
            _ = try f.store.runLegacyConversion(request(f, tampered))
        }
    }

    /// **The reason identity is composite.** The two legacy tables are independent id spaces;
    /// skipping the sale must not skip the purchase that happens to share its name.
    func testSkippingOneTableDoesNotSkipTheOtherTablesRowOfTheSameID() throws {
        let f = try fixture()
        try insertSale(f, id: "shared")
        try insertPurchase(f, id: "shared")
        let p = try plan(f)
        XCTAssertEqual(p.convertibleIdentities, [sid("shared"), pid("shared")])

        let report = try f.store.runLegacyConversion(
            request(f, p, skipped: [sid("shared")]))

        XCTAssertEqual(Set(report.converted), [pid("shared")])
        let map = try XCTUnwrap(f.store.db.query("SELECT * FROM legacy_migrations").first)
        XCTAssertEqual(map.string("legacy_table"), "purchases")
        XCTAssertEqual(try f.store.legacyLedgerSummary().unconverted, 1)
    }

    func testSkippingAnIdentityThatIsNotConvertibleIsRefused() throws {
        let f = try fixture()
        try insertSale(f, id: "s-1")
        try insertSale(f, id: "bad", date: .text("2024/03/10"))   // needsAdjudication
        let p = try plan(f)

        try assertRefusedAndUntouched(f, .skippedIdentityNotConvertible(sid("bad"))) {
            _ = try f.store.runLegacyConversion(request(f, p, skipped: [sid("bad")]))
        }
        try assertRefusedAndUntouched(f, .skippedIdentityNotConvertible(sid("ghost"))) {
            _ = try f.store.runLegacyConversion(request(f, p, skipped: [sid("ghost")]))
        }
        // Right id, wrong table.
        try assertRefusedAndUntouched(f, .skippedIdentityNotConvertible(pid("s-1"))) {
            _ = try f.store.runLegacyConversion(request(f, p, skipped: [pid("s-1")]))
        }
    }

    /// The closing identity assertion, stated directly rather than through counts.
    func testTheConvertedSetIsExactlyConvertibleMinusSkipped() throws {
        let f = try fixture()
        for id in ["s-1", "s-2", "s-3"] { try insertSale(f, id: id) }
        try insertPurchase(f, id: "p-1")
        try insertSale(f, id: "bad", totalAmount: .null)          // needsAdjudication
        let p = try plan(f)
        let skipped: Set<LegacyRowIdentity> = [sid("s-2")]

        let report = try f.store.runLegacyConversion(request(f, p, skipped: skipped))

        XCTAssertEqual(Set(report.converted), p.convertibleIdentities.subtracting(skipped))
        XCTAssertEqual(Set(report.converted), [sid("s-1"), sid("s-3"), pid("p-1")])
        XCTAssertEqual(report.converted, report.converted.sorted(), "reported in a stable order")
        // Both tables gained the same number, and it is the size of the identity set.
        let after = try counts(f)
        XCTAssertEqual(after.transactions, report.converted.count)
        XCTAssertEqual(after.mappings, report.converted.count)
        // The two rows left behind are still unconverted, and still there.
        XCTAssertEqual(try f.store.legacyLedgerSummary().unconverted, 2)
    }

    // MARK: - 4. Values the plan refuses to carry

    /// Every corruption class is filtered by the plan, so the writer never faces one. Proved
    /// per class rather than asserted: each row is graded `needsAdjudication` and is absent
    /// from the converted set.
    func testCorruptRowsAreNeverWritten() throws {
        let f = try fixture()
        try insertSale(f, id: "clean")
        try insertSale(f, id: "net-text", amountWithoutTax: .text("abc"))
        try insertSale(f, id: "net-inf")
        try f.store.db.run("UPDATE sales SET amountWithoutTax = 9e999 WHERE id = 'net-inf'")
        try f.store.db.run("INSERT INTO sales (id, date, customer, totalAmount, amountWithoutTax, taxAmount, taxRate, paid_amount, payment_status) VALUES ('net-blob','2024-03-10','x',9040,?,1040,13,0,'unpaid')",
                           [.blob(Data([0x01, 0x02]))])
        try insertSale(f, id: "total-null", totalAmount: .null)
        try insertSale(f, id: "status", paymentStatus: .text("已付"))
        try insertSale(f, id: "date", date: .text("2024/03/10"))
        try insertSale(f, id: "party", customer: .text(String(repeating: "字", count: 201)))
        try insertSale(f, id: "invoice", invoiceNumber: .text(String(repeating: "I", count: 101)))

        let p = try plan(f)
        XCTAssertEqual(p.convertibleIdentities, [sid("clean")],
                       "only the clean row may be convertible")
        let report = try f.store.runLegacyConversion(request(f, p))
        XCTAssertEqual(Set(report.converted), [sid("clean")])
        XCTAssertEqual(try counts(f).transactions, 1)

        for id in ["net-text", "net-inf", "net-blob", "total-null", "status", "date",
                   "party", "invoice"] {
            let row = try XCTUnwrap(p.rows.first { $0.id == id })
            XCTAssertEqual(row.grade, .needsAdjudication, id)
        }
        // And the originals still hold their exact bytes — nothing was cleaned on the way.
        XCTAssertEqual(try f.store.db.query(
            "SELECT typeof(amountWithoutTax) AS t FROM sales WHERE id='net-text'")
            .first?.string("t"), "text")
    }

    /// The writer's side of the BLOB rule: none of the four columns copied as text can carry
    /// a BLOB into `transactions`, and the refusal comes from the plan rather than from a
    /// fallback in the writer. Asserted per column against REAL SQLite storage classes.
    func testABlobInACopiedTextColumnNeverReachesTheWriter() throws {
        let blob = SQLiteValue.blob(Data([0x00, 0xff, 0x10]))
        for (column, id) in [("customer", "b-party"), ("invoiceNumber", "b-invoice"),
                             ("payment_date", "b-paid"), ("due_date", "b-due")] {
            let f = try fixture()
            try insertSale(f, id: "clean")
            // The target column is bound raw and every other one is ordinary, so exactly one
            // storage class is under test per iteration.
            try f.store.db.run("""
                INSERT INTO sales (id, date, totalAmount, amountWithoutTax, taxAmount,
                                   taxRate, paid_amount, payment_status, \(column))
                VALUES (?, '2024-03-10', 9040, 8000, 1040, 13, 0, 'unpaid', ?)
                """, [.text(id), blob])
            // CONTROL: TEXT affinity really did leave it a BLOB.
            XCTAssertEqual(try f.store.db.query(
                "SELECT typeof(\(column)) AS t FROM sales WHERE id = ?", [.text(id)])
                .first?.string("t"), "blob", column)

            let p = try plan(f)
            XCTAssertEqual(p.convertibleIdentities, [sid("clean")], column)
            let report = try f.store.runLegacyConversion(request(f, p))

            XCTAssertEqual(Set(report.converted), [sid("clean")], column)
            XCTAssertEqual(try counts(f).transactions, 1, column)
            XCTAssertEqual(try counts(f).mappings, 1, column)
            XCTAssertNil(try f.store.db.query(
                "SELECT new_id FROM legacy_migrations WHERE legacy_id = ?", [.text(id)]).first,
                         "\(column): the blob row got a mapping")
            // The original still holds its exact bytes.
            XCTAssertEqual(try f.store.db.query(
                "SELECT typeof(\(column)) AS t FROM sales WHERE id = ?", [.text(id)])
                .first?.string("t"), "blob", column)
        }
    }

    // MARK: - 3b. The plan is the VALUES, not just the row set

    /// **P1-①.** A legal value replaced by another legal value used to be completely invisible:
    /// the row's table, id, date and (empty) issue list are unchanged, so `fresh == plan`
    /// passed and the writer stored money the user never saw. Measured before the fix,
    /// sixteen of twenty ordinary edits behaved this way.
    ///
    /// One test per GROUP of the seventeen protected columns, each changing one column.
    func testALegalValueChangedAfterThePlanIsLedgerChanged() throws {
        let edits: [(String, String)] = [
            ("money/totalAmount",      "UPDATE sales SET totalAmount = 1.0 WHERE id='s-1'"),
            ("money/taxAmount",        "UPDATE sales SET taxAmount = 0.5 WHERE id='s-1'"),
            ("money/taxRate",          "UPDATE sales SET taxRate = 6 WHERE id='s-1'"),
            ("money/paid_amount",      "UPDATE sales SET paid_amount = 0.25 WHERE id='s-1'"),
            ("money/amountWithoutTax", "UPDATE sales SET amountWithoutTax = 7.0 WHERE id='s-1'"),
            ("strings/customer",       "UPDATE sales SET customer = '乙' WHERE id='s-1'"),
            ("strings/invoiceNumber",  "UPDATE sales SET invoiceNumber = 'X' WHERE id='s-1'"),
            ("status/invoiceStatus",   "UPDATE sales SET invoiceStatus = '待开' WHERE id='s-1'"),
            ("status/payment_status",  "UPDATE sales SET payment_status = 'unpaid' WHERE id='s-1'"),
            ("dates/payment_date",     "UPDATE sales SET payment_date = NULL WHERE id='s-1'"),
            ("dates/due_date",         "UPDATE sales SET due_date = '2024-07-20' WHERE id='s-1'"),
            ("audit/tons",             "UPDATE sales SET tons = 99 WHERE id='s-1'"),
            ("audit/pricePerTon",      "UPDATE sales SET pricePerTon = 1 WHERE id='s-1'"),
            ("audit/shippingCost",     "UPDATE sales SET shippingCost = 0 WHERE id='s-1'"),
            ("audit/created_at",       "UPDATE sales SET created_at = '2020-01-01' WHERE id='s-1'"),
        ]
        for (label, sql) in edits {
            let f = try fixture()
            try insertSale(f, id: "s-1")
            let stale = try plan(f)
            try f.store.db.execute(sql)

            do {
                _ = try f.store.runLegacyConversion(request(f, stale))
                XCTFail("\(label): a stale plan must be refused")
            } catch let error as LegacyConversionFailure {
                XCTAssertEqual(error, .ledgerChanged, label)
            }
            XCTAssertEqual(try counts(f).transactions, 0, label)
            XCTAssertEqual(try counts(f).mappings, 0, label)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.backupDir.path),
                           "\(label): a refused conversion must not have cost a backup")
        }
    }

    /// **The per-row fingerprint, reached.** The plan-level equality cannot catch this one:
    /// the row is edited INSIDE our own transaction, after the fresh plan was taken, by a
    /// trigger that fires as the first row is written. Our own writes are visible to our own
    /// later reads, so the second row is re-read already changed — clean value to clean
    /// value, so `issues(in:)` still says nothing is wrong.
    func testACleanToCleanEditMidTransactionIsCaughtByThePerRowFingerprint() throws {
        let f = try fixture()
        try insertSale(f, id: "s-1")
        try insertSale(f, id: "s-2")
        let p = try plan(f)
        try f.store.db.execute("""
            CREATE TRIGGER retag AFTER INSERT ON transactions
            BEGIN UPDATE sales SET totalAmount = 1.0 WHERE id = 's-2'; END
            """)

        do {
            _ = try f.store.runLegacyConversion(request(f, p))
            XCTFail("expected the per-row fingerprint to refuse")
        } catch let error as LegacyConversionFailure {
            XCTAssertEqual(error, .ledgerChanged)
        }
        XCTAssertEqual(try counts(f).transactions, 0)
        XCTAssertEqual(try counts(f).mappings, 0)
        // The trigger's own write rolled back with everything else — s-2 still holds 9040.
        XCTAssertEqual(try f.store.db.query(
            "SELECT totalAmount AS a FROM sales WHERE id='s-2'").first?["a"], .real(9040))
        // CONTROL: the row is still perfectly clean, so the re-grade would have passed it.
        XCTAssertEqual(try plan(f).convertibleIdentities, [sid("s-1"), sid("s-2")])
    }

    /// A currency the write path would shorten is refused by the PLAN, so no request carrying
    /// one can be built.
    func testACurrencyLongerThanTheWritePathKeepsIsBlockedByThePlan() throws {
        let f = try fixture(currency: "VERYLONGCODE")
        try insertSale(f, id: "s-1")
        XCTAssertEqual(try f.store.legacyConversionPreflight(),
                       .blocked(.currencyNotStorableVerbatim(currency: "VERYLONGCODE")))
        // Control: eight characters is the boundary and is fine.
        let ok = try fixture(currency: "12345678")
        try insertSale(ok, id: "s-1")
        XCTAssertEqual(try plan(ok).currency, "12345678")
    }

    // MARK: - 5. The write specification, column by column

    private func converted(_ f: Fixture, _ legacyID: String,
                           file: StaticString = #filePath, line: UInt = #line) throws
    -> SQLiteRow {
        let newID = try XCTUnwrap(f.store.db.query(
            "SELECT new_id FROM legacy_migrations WHERE legacy_id = ?", [.text(legacyID)])
            .first?.string("new_id"), file: file, line: line)
        return try XCTUnwrap(f.store.db.query("SELECT * FROM transactions WHERE id = ?",
                                              [.text(newID)]).first, file: file, line: line)
    }

    func testTheMoneyAndTaxColumnsAreCarriedFaithfully() throws {
        let f = try fixture()
        try insertSale(f, id: "s-1")
        _ = try f.store.runLegacyConversion(request(f, try plan(f)))
        let t = try converted(f, "s-1")
        XCTAssertEqual(t.double("amount"), 9040)
        XCTAssertEqual(t.double("amount_net"), 8000)
        XCTAssertEqual(t.double("tax_amount"), 1040)
        XCTAssertEqual(t.double("tax_rate"), 13)
        XCTAssertEqual(t.double("paid_amount"), 9040)
        XCTAssertEqual(t.string("currency"), "CNY")
        XCTAssertEqual(t.string("type"), "income")
        XCTAssertEqual(t.string("category_id"), "cn-income-sales")
    }

    /// A stored 0 and a stored NULL are different facts and stay different. Asserted with
    /// `typeof`, because `double("amount_net")` reads both as a number-or-nil and would hide
    /// a 0 written where NULL belonged.
    func testAmountNetKeepsZeroAsZeroAndAbsentAsNull() throws {
        let f = try fixture()
        try insertSale(f, id: "zero", amountWithoutTax: .real(0))
        try insertSale(f, id: "absent", amountWithoutTax: .null)
        _ = try f.store.runLegacyConversion(request(f, try plan(f)))

        XCTAssertEqual(try converted(f, "zero")["amount_net"], .real(0))
        XCTAssertEqual(try converted(f, "absent")["amount_net"], .null)
    }

    func testPaymentStatusTakesTheConservativeCorrection() throws {
        let f = try fixture()
        try insertSale(f, id: "null-status", paymentStatus: .null)
        try insertSale(f, id: "empty-status", paymentStatus: .text(""))
        for value in ["paid", "partial", "unpaid"] {
            try insertSale(f, id: value, paymentStatus: .text(value))
        }
        _ = try f.store.runLegacyConversion(request(f, try plan(f)))

        // The correction: NOT Electron's optimistic `paid` (`migrations.js:121,158`).
        XCTAssertEqual(try converted(f, "null-status").string("payment_status"), "unpaid")
        XCTAssertEqual(try converted(f, "empty-status").string("payment_status"), "unpaid")
        for value in ["paid", "partial", "unpaid"] {
            XCTAssertEqual(try converted(f, value).string("payment_status"), value, value)
        }
    }

    func testInvoiceStatusMapsTheFourLegacyValuesAndNothingElse() throws {
        let f = try fixture()
        let cases = [("issued-1", "已开", "issued"), ("issued-2", "已收", "issued"),
                     ("pending-1", "待开", "pending"), ("pending-2", "待收", "pending"),
                     ("other", "Issued", "n/a"), ("blank", "", "n/a")]
        for (id, stored, _) in cases { try insertSale(f, id: id, invoiceStatus: .text(stored)) }
        try insertSale(f, id: "null-status2", invoiceStatus: .null)
        _ = try f.store.runLegacyConversion(request(f, try plan(f)))

        for (id, stored, expected) in cases {
            XCTAssertEqual(try converted(f, id).string("invoice_status"), expected,
                           "\(id) stored \(stored)")
        }
        XCTAssertEqual(try converted(f, "null-status2").string("invoice_status"), "n/a")
    }

    func testDatesAreCarriedVerbatimAndAnEmptyOptionalDateBecomesNull() throws {
        let f = try fixture()
        try insertSale(f, id: "stamped", date: .text("2024-03-10T08:30:00"),
                       paymentDate: .text(""), dueDate: .text("2024-07-20"))
        _ = try f.store.runLegacyConversion(request(f, try plan(f)))
        let t = try converted(f, "stamped")
        XCTAssertEqual(t.string("date"), "2024-03-10T08:30:00", "zero transformation")
        XCTAssertEqual(t["payment_date"], .null,
                       "an empty stored date is an absence, not a '' that COALESCE would take")
        XCTAssertEqual(t.string("due_date"), "2024-07-20")
    }

    func testCreatedAtIsTheConversionTimeAndTheLegacyStampIsPreserved() throws {
        let f = try fixture()
        try insertSale(f, id: "s-1", createdAt: .text("2019-01-01 00:00:00"))
        _ = try f.store.runLegacyConversion(request(f, try plan(f)))
        let t = try converted(f, "s-1")
        let created = try XCTUnwrap(t.string("created_at"))
        XCTAssertNotEqual(created, "2019-01-01 00:00:00",
                          "created_at records entry into `transactions`, not the legacy row's age")
        XCTAssertEqual(created.count, 19, "SQLite's datetime('now') shape")
        let meta = try sourceMeta(f, "s-1")
        XCTAssertEqual(meta["legacy_created_at"] as? String, "2019-01-01 00:00:00")
    }

    func testTheDescriptionMirrorsTheElectronSegments() throws {
        let f = try fixture()
        try insertSale(f, id: "all", tons: .real(10), pricePerTon: .real(800),
                       shippingCost: .real(300))
        try insertSale(f, id: "zeros", tons: .real(0), pricePerTon: .real(0),
                       shippingCost: .real(0))
        try insertPurchase(f, id: "p-1", tons: .real(12), pricePerTon: .real(500))
        _ = try f.store.runLegacyConversion(request(f, try plan(f)))

        XCTAssertEqual(try converted(f, "all").string("description"),
                       "qty=10 · unit=800 · shipping=300",
                       "integral doubles print without a .0, as JS does")
        XCTAssertEqual(try converted(f, "zeros").string("description"), "",
                       "0 is falsy in the source and the segment is omitted")
        XCTAssertEqual(try converted(f, "p-1").string("description"), "qty=12 · unit=500",
                       "purchases have no shipping column and so never get that segment")
    }

    /// The segment rule, per storage class. REAL affinity keeps whichever kind of zero it was
    /// handed, so a rule written for only one of them is half a rule.
    ///
    /// Four of the five omissions mirror JavaScript's falsiness, which is what the source
    /// uses: `0` (either storage class), `''` and NULL. **The BLOB is not one of them** — see
    /// `testABlobSegmentIsOmittedAsADeliberateDifferenceFromTheSource`.
    func testTheDescriptionSegmentRuleCoversEveryStorageClass() {
        for falsy in [SQLiteValue.real(0), .integer(0), .null, .text("")] {
            XCTAssertNil(LegacyConversionRunner.segment("qty", falsy), "\(falsy)")
        }
        XCTAssertEqual(LegacyConversionRunner.segment("qty", .real(10)), "qty=10")
        XCTAssertEqual(LegacyConversionRunner.segment("qty", .real(10.5)), "qty=10.5")
        XCTAssertEqual(LegacyConversionRunner.segment("qty", .integer(7)), "qty=7")
        XCTAssertEqual(LegacyConversionRunner.segment("qty", .text("1,000")), "qty=1,000")
        XCTAssertEqual(LegacyConversionRunner.segment("qty", .real(.infinity)), "qty=Infinity")
        XCTAssertEqual(LegacyConversionRunner.segment("qty", .real(-.infinity)), "qty=-Infinity")
    }

    /// **A registered divergence, not a mirror.** better-sqlite3 hands a BLOB to
    /// `migrations.js` as a `Buffer`, which is TRUTHY in JavaScript, so Electron would
    /// interpolate its bytes into the description — arbitrary binary decoded as text, control
    /// characters and all, in a field the app renders. This omits the segment instead, and
    /// nothing is lost: the bytes are kept tagged and base64-encoded in `source_meta`.
    ///
    /// Stated as its own test so the omission cannot be read as parity with the source.
    func testABlobSegmentIsOmittedAsADeliberateDifferenceFromTheSource() throws {
        let bytes = Data([0x00, 0x07, 0xff])
        XCTAssertNil(LegacyConversionRunner.segment("qty", .blob(bytes)),
                     "the segment is omitted rather than decoded")
        // The two reasons that share this line of code are different: NULL is falsy in the
        // source, a Buffer is not.
        XCTAssertNil(LegacyConversionRunner.segment("qty", .null))

        let f = try fixture()
        try f.store.db.run("""
            INSERT INTO sales (id, date, customer, tons, pricePerTon, totalAmount,
                               amountWithoutTax, taxAmount, taxRate, shippingCost, paid_amount,
                               payment_status)
            VALUES ('s-1','2024-03-10','Acme',?,800,9040,8000,1040,13,0,0,'unpaid')
            """, [.blob(bytes)])
        _ = try f.store.runLegacyConversion(request(f, try plan(f)))

        let description = try XCTUnwrap(converted(f, "s-1").string("description"))
        XCTAssertEqual(description, "unit=800", "no qty segment, and no control characters")
        XCTAssertFalse(description.unicodeScalars.contains { $0.properties.generalCategory == .control })
        // And the bytes really are still recoverable, in the place they belong.
        let tons = try XCTUnwrap(sourceMeta(f, "s-1")["tons"] as? [String: String])
        XCTAssertEqual(Data(base64Encoded: tons["base64"] ?? ""), bytes)
    }

    /// The registered, deliberate difference from Electron: `LedgerStore.create` writes an
    /// empty string where `migrations.js` wrote SQL NULL for these three columns. Accepted
    /// because reusing the one write path is worth more than byte-parity on a column whose
    /// value carries no accounting meaning — and because every transaction the native editor
    /// creates already stores `''` there, so matching Electron would make converted rows the
    /// odd ones out. Pinned so the difference cannot drift unnoticed.
    func testEmptyCopiedStringsBecomeEmptyStringsNotNull() throws {
        let f = try fixture()
        try insertSale(f, id: "bare", customer: .null,
                       tons: .real(0), pricePerTon: .real(0), shippingCost: .real(0),
                       invoiceNumber: .null)
        _ = try f.store.runLegacyConversion(request(f, try plan(f)))
        let t = try converted(f, "bare")
        XCTAssertEqual(t["counterparty"], .text(""))
        XCTAssertEqual(t["invoice_no"], .text(""))
        XCTAssertEqual(t["description"], .text(""))
        XCTAssertEqual(t["attachment_path"], .null, "a legacy row carries no attachment")
    }

    // MARK: - 5b. source_meta

    private func sourceMeta(_ f: Fixture, _ legacyID: String,
                            file: StaticString = #filePath, line: UInt = #line) throws
    -> [String: Any] {
        let raw = try XCTUnwrap(converted(f, legacyID).string("source_meta"),
                                file: file, line: line)
        let object = try JSONSerialization.jsonObject(with: Data(raw.utf8))
        return try XCTUnwrap(object as? [String: Any], file: file, line: line)
    }

    func testSourceMetaCarriesEveryRegisteredKey() throws {
        let f = try fixture()
        try insertSale(f, id: "s-1")
        try insertPurchase(f, id: "p-1")
        _ = try f.store.runLegacyConversion(request(f, try plan(f)))

        let sale = try sourceMeta(f, "s-1")
        XCTAssertEqual(Set(sale.keys), [
            "migrated_from", "legacy_id", "tons", "pricePerTon", "shippingCost",
            "legacy_created_at", "legacy_invoice_status", "legacy_payment_status",
            "default_income_category_id", "default_expense_category_id"])
        XCTAssertEqual(sale["migrated_from"] as? String, "sales")
        XCTAssertEqual(sale["legacy_id"] as? String, "s-1")
        XCTAssertEqual(sale["tons"] as? Double, 10)
        XCTAssertEqual(sale["legacy_invoice_status"] as? String, "已开")
        XCTAssertEqual(sale["legacy_payment_status"] as? String, "paid")
        XCTAssertEqual(sale["default_income_category_id"] as? String, "cn-income-sales")

        // `shippingCost` is a sales-only column, exactly as in `migrations.js:123` vs `:160`.
        XCTAssertFalse(try sourceMeta(f, "p-1").keys.contains("shippingCost"))
    }

    func testSourceMetaKeysAreSortedSoTwoRunsProduceTheSameBytes() throws {
        let f = try fixture()
        try insertSale(f, id: "s-1")
        _ = try f.store.runLegacyConversion(request(f, try plan(f)))
        let raw = try XCTUnwrap(converted(f, "s-1").string("source_meta"))
        let keys = raw.split(separator: ",").compactMap { chunk -> String? in
            guard let open = chunk.firstIndex(of: "\""),
                  let close = chunk[chunk.index(after: open)...].firstIndex(of: "\"")
            else { return nil }
            return String(chunk[chunk.index(after: open)..<close])
        }
        XCTAssertEqual(keys, keys.sorted(), "\(raw)")
    }

    /// **The three ungraded columns.** `tons`, `pricePerTon` and `shippingCost` are not
    /// graded by the plan, so a convertible row can hold anything in them — including the one
    /// thing `JSONSerialization` throws on. Each storage class is preserved with its type
    /// rather than flattened, and the result always parses.
    func testUngradedAuditColumnsSurviveEveryStorageClass() throws {
        let f = try fixture()
        try insertSale(f, id: "text", tons: .text("1,000"))
        try insertSale(f, id: "blob", tons: .blob(Data([0x00, 0xff])))
        try insertSale(f, id: "inf")
        try f.store.db.run("UPDATE sales SET tons = 9e999 WHERE id = 'inf'")
        try insertSale(f, id: "null", tons: .null)
        try insertSale(f, id: "int", tons: .integer(7))

        // Control: SQLite really is holding those storage classes.
        let kinds = try f.store.db.query("SELECT id, typeof(tons) AS t FROM sales ORDER BY id")
            .map { "\($0.string("id") ?? "")=\($0.string("t") ?? "")" }
        XCTAssertEqual(kinds, ["blob=blob", "inf=real", "int=real", "null=null", "text=text"])

        _ = try f.store.runLegacyConversion(request(f, try plan(f)))

        XCTAssertEqual(try sourceMeta(f, "text")["tons"] as? String, "1,000")
        XCTAssertEqual(try sourceMeta(f, "int")["tons"] as? Double, 7)
        XCTAssertTrue(try sourceMeta(f, "null")["tons"] is NSNull)
        let blob = try XCTUnwrap(try sourceMeta(f, "blob")["tons"] as? [String: String])
        XCTAssertEqual(blob["sqlite_type"], "blob")
        XCTAssertEqual(Data(base64Encoded: blob["base64"] ?? ""), Data([0x00, 0xff]))
        let inf = try XCTUnwrap(try sourceMeta(f, "inf")["tons"] as? [String: String])
        XCTAssertEqual(inf, ["sqlite_type": "real", "value": "Infinity"])
    }

    /// The reason the tagged encoding exists, measured: the naive encoding throws.
    func testTheNaiveEncodingOfANonFiniteNumberWouldHaveThrown() {
        XCTAssertFalse(JSONSerialization.isValidJSONObject(["tons": Double.infinity]),
                       "control: a raw infinity is not a serialisable JSON value")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(
            ["tons": LegacyConversionRunner.auditValue(.real(.infinity))]))
        XCTAssertTrue(JSONSerialization.isValidJSONObject(
            ["tons": LegacyConversionRunner.auditValue(.blob(Data([0x00])))]))
    }

    // MARK: - 6. Idempotence

    /// A finished conversion re-run: the plan now has nothing convertible, so it returns 0
    /// without a backup and without touching anything. The SENTINEL is what proves "without
    /// touching" — `updated_at` has one-second resolution and would hide a rewrite.
    func testRunningAgainAfterSuccessConvertsNothingAndRewritesNothing() throws {
        let f = try fixture()
        try insertSale(f, id: "s-1")
        let first = try f.store.runLegacyConversion(request(f, try plan(f)))
        XCTAssertEqual(first.convertedCount, 1)

        let newID = try XCTUnwrap(converted(f, "s-1").string("id"))
        try f.store.db.run("UPDATE transactions SET counterparty = ? WHERE id = ?",
                           [.text("SENTINEL-DO-NOT-REWRITE"), .text(newID)])

        let second = try f.store.runLegacyConversion(request(f, try plan(f)))
        XCTAssertEqual(second.converted, [])
        XCTAssertNil(second.backupDirectory)
        XCTAssertEqual(try counts(f).transactions, 1)
        XCTAssertEqual(try counts(f).mappings, 1)
        XCTAssertEqual(try f.store.transaction(id: newID)?.counterparty,
                       "SENTINEL-DO-NOT-REWRITE")
    }

    /// Replaying the ORIGINAL plan after a success is not idempotent — it is stale, and the
    /// only honest answer is to refuse. Only a freshly computed empty plan returns 0.
    func testReplayingTheOriginalPlanAfterASuccessIsLedgerChanged() throws {
        let f = try fixture()
        try insertSale(f, id: "s-1")
        let original = try plan(f)
        _ = try f.store.runLegacyConversion(request(f, original))

        let replayDir = try trackedTempDir().appendingPathComponent("replay")
        try assertRefusedAndUntouched(f, .ledgerChanged) {
            _ = try f.store.runLegacyConversion(
                request(f, original, backupDir: replayDir))
        }
    }

    /// The database-level backstop: a mapping that already exists makes the whole batch roll
    /// back rather than half-convert.
    func testAUniqueMappingConflictRollsTheWholeBatchBack() throws {
        let f = try fixture()
        try insertSale(f, id: "s-1")
        try insertSale(f, id: "s-2")
        let p = try plan(f)
        // A mapping whose legacy row is NOT in the anti-join's output would change the plan,
        // so plant a conflicting row via a trigger that fires on the second mapping insert.
        try f.store.db.execute("""
            CREATE TRIGGER dup BEFORE INSERT ON legacy_migrations
            WHEN (SELECT COUNT(*) FROM legacy_migrations) >= 1
            BEGIN SELECT RAISE(ABORT, 'UNIQUE constraint failed'); END
            """)

        XCTAssertThrowsError(try f.store.runLegacyConversion(request(f, p)))
        XCTAssertEqual(try counts(f).transactions, 0)
        XCTAssertEqual(try counts(f).mappings, 0)
    }

    // MARK: - 7. Reachability

    /// The runner ships UNREACHABLE, for the same reason the preflight does: two existing
    /// guarantees — `AppModelBootTests` T3 and `canLoadDemoData` — protect exactly the
    /// ledgers a self-starting conversion would operate on. The wizard (2a-4) is where it
    /// becomes reachable, from a user action.
    func testTheRunnerIsNotReachableFromTheAppTarget() throws {
        let sources = try Self.appSources()
        XCTAssertGreaterThan(sources.count, 10, "the App target did not resolve")
        let found = Self.mentions(of: Self.runnerSymbols, in: sources)
        XCTAssertTrue(found.isEmpty, """
            the SwiftUI target already names the conversion runner: \
            \(found.sorted().joined(separator: ", ")). 2a-2 ships unreachable; activation is \
            2a-4, and it must arrive with the wizard that discloses what converting changes.
            """)
    }

    func testTheReachabilityScanDetectsARealUseAndIgnoresAComment() {
        XCTAssertFalse(Self.mentions(of: Self.runnerSymbols,
                                     in: [("V.swift", "try store.runLegacyConversion(r)")]).isEmpty)
        XCTAssertTrue(Self.mentions(of: Self.runnerSymbols,
                                    in: [("V.swift", "  // runLegacyConversion lands in 2a-4")]).isEmpty)
        XCTAssertTrue(Self.mentions(of: ["LegacyConversionRunner"],
                                    in: [("V.swift", "LegacyConversionRunnerKit()")]).isEmpty,
                      "whole-identifier matching only")
        for symbol in Self.runnerSymbols {
            XCTAssertEqual(Self.mentions(of: Self.runnerSymbols,
                                         in: [("X.swift", "let v = \(symbol)")]).count, 1,
                           "\(symbol) must be individually detectable")
        }
    }

    // MARK: - Identity ordering

    /// Ordering is part of the composite key, not decoration: `sorted()` decides the write
    /// order and the reported order, and an ordering that ignored the table would make two
    /// same-id rows from different tables interchangeable in a sorted list.
    func testIdentityOrderingAndEqualityBothUseTheWholeCompositeKey() {
        XCTAssertNotEqual(sid("x"), pid("x"))
        XCTAssertNotEqual(sid("x").hashValue, pid("x").hashValue)
        XCTAssertEqual(Set([sid("x"), pid("x")]).count, 2)
        // purchases < sales, then by id — a total order over the composite, not over the id.
        XCTAssertEqual([sid("b"), pid("b"), sid("a"), pid("a")].sorted(),
                       [pid("a"), pid("b"), sid("a"), sid("b")])
        XCTAssertEqual(sid("a").description, "sales:a")
    }

    // MARK: - The safety order, asserted structurally

    /// The order in ``LedgerStore/runLegacyConversion(_:)`` IS the safety argument, and three
    /// of its steps are defences that cannot be reached from inside the process: a backup
    /// validated but never bad, a category re-check with no window to fail in, a closing
    /// identity assertion that the loop above it makes true by construction. A behavioural
    /// test cannot distinguish them from their own absence — so the skeleton is pinned where
    /// it is written, the same way the calendar rule is pinned against consulting a clock.
    func testTheSafetyOrderIsWrittenInThatOrder() throws {
        let source = try String(contentsOf: Self.packageRoot().appendingPathComponent(
            "Sources/SoloLedgerCore/Conversion/LegacyConversionRunner.swift"), encoding: .utf8)
        let body = try XCTUnwrap(source.range(of: "faultInjection: (() throws -> Void)?) throws")
            .map { String(source[$0.upperBound...]) })
        let steps = [
            "throw LegacyConversionFailure.skippedIdentityNotConvertible",  // A request shape
            "guard !LegacyConversionPlan.wouldTruncateCurrency",            // A request shape
            "guard !expected.isEmpty else {",                               // B nothing to do
            "try db.transaction {",                                         // C the one write tx
            "try legacyConversionPreflightBody()",                          // D pins the snapshot
            "guard expectedFresh == expected else {",                       // E same execution set
            "try validateConversionCategories(for: expectedFresh",          // F …before the backup
            "try BackupExport.writeBundle",                                 // G backup, in the tx
            "if let busy = LegacyConversionRunner.retriableBusyMessage(error) {",  // G busy ≠ broken
            "throw LegacyConversionFailure.backupFailed",                   // G …everything else
            "try BackupRestore.validateBundle",                             // G prove it reads
            "try create(LegacyConversionRunner.transaction",                // H the FIRST write
            "INSERT INTO legacy_migrations",                                // H its mapping
            "guard converted == expectedFresh else {",                      // I closing identity
            "guard gainedTransactions == expectedFresh.count,",             // I closing counts
        ]
        var cursor = body.startIndex
        for step in steps {
            guard let found = body.range(of: step, range: cursor..<body.endIndex) else {
                return XCTFail("`\(step)` is missing, or comes before the step above it")
            }
            cursor = found.upperBound
        }
    }

    /// The four columns copied AS TEXT must go through the guarded helpers, never through a
    /// bare `stringValue` that would flatten a BLOB into `""` or SQL NULL.
    ///
    /// Structural, because the guard is a THIRD layer: the plan grades such a row
    /// `needsAdjudication` and the in-transaction re-grade re-checks it, so the trap is
    /// unreachable while both hold — which is the design (the ruling is that the plan is the
    /// gate, not the writer). Unreachable is not the same as absent, and this is what tells
    /// the difference.
    func testTheCopiedTextColumnsAreWrittenThroughTheGuardedHelpers() throws {
        let source = try String(contentsOf: Self.packageRoot().appendingPathComponent(
            "Sources/SoloLedgerCore/Conversion/LegacyConversionRunner.swift"), encoding: .utf8)
        let spec = try XCTUnwrap(source.range(of: "static func transaction(from source: SourceRow")
            .flatMap { start in source.range(of: "static func mapInvoiceStatus",
                                             range: start.upperBound..<source.endIndex)
                .map { String(source[start.lowerBound..<$0.lowerBound]) } })
        for expected in ["counterparty: copiedText(g.counterparty)",
                         "invoiceNo: copiedText(g.invoiceNo)",
                         "paymentDate: copiedOptionalText(g.paymentDate)",
                         "dueDate: copiedOptionalText(g.dueDate)"] {
            XCTAssertTrue(spec.contains(expected), "the write spec must use `\(expected)`")
        }
        // And the helpers must actually refuse, rather than being pass-throughs.
        for helper in ["private static func copiedText", "private static func copiedOptionalText"] {
            let body = try XCTUnwrap(source.range(of: helper).map { start in
                String(source[start.lowerBound...].prefix(400)) })
            XCTAssertTrue(body.contains("hasNoTextReading") && body.contains("preconditionFailure"),
                          "\(helper) must refuse a value with no text reading")
        }
    }

    // MARK: - Busy classification

    /// The result code is read as a DELIMITED TOKEN, in both shapes `SQLiteDatabase` emits,
    /// and never as a loose substring.
    func testOnlyTheBusyFamilyIsClassifiedAsRetriable() {
        for code in [5, 261, 517, 773] {
            XCTAssertNotNil(LegacyConversionRunner.retriableBusyMessage(
                SQLiteError.step("database is locked (code \(code))")), "code \(code)")
            // The online-backup shape: the token sits in the MIDDLE, so a suffix test misses it.
            XCTAssertNotNil(LegacyConversionRunner.retriableBusyMessage(
                SQLiteError.message("sqlite3_backup_step failed (rc \(code)): database is locked")),
                            "rc \(code) mid-message")
            XCTAssertNotNil(LegacyConversionRunner.retriableBusyMessage(
                SQLiteError.message("sqlite3_backup_finish failed (rc \(code))")), "rc \(code) at end")
        }
        XCTAssertNil(LegacyConversionRunner.retriableBusyMessage(
            SQLiteError.step("constraint failed (code 19)")))
        XCTAssertNil(LegacyConversionRunner.retriableBusyMessage(
            SQLiteError.message("sqlite3_backup_step failed (rc 14): unable to open database file")))
        // The other real shape the backup path emits, measured: no code token at all.
        XCTAssertNil(LegacyConversionRunner.retriableBusyMessage(
            SQLiteError.message("backup destination open failed: unable to open database file")))
        XCTAssertNil(LegacyConversionRunner.retriableBusyMessage(
            SQLiteError.open(message: "x", primary: 14, extended: 14, systemErrno: 0)))
        XCTAssertNil(LegacyConversionRunner.retriableBusyMessage(LegacyConversionFailure.ledgerChanged))
        // Loose digits are not a code. These are the strings a substring test would misread.
        for notACode in ["error 5 occurred", "rc 5", "(code5)", "(rc  5)", "(errno 5)",
                         "backup of 5 pages failed"] {
            XCTAssertNil(LegacyConversionRunner.retriableBusyMessage(SQLiteError.message(notACode)),
                         notACode)
        }
        XCTAssertEqual(LegacyConversionRunner.resultCodes(
            in: "sqlite3_backup_step failed (rc 5): x (code 19)"), [5, 19])
        XCTAssertEqual(LegacyConversionRunner.resultCodes(in: "no codes here"), [])
    }

    // MARK: - Scan helpers

    private static let runnerSymbols = [
        "LegacyConversionRunner", "LegacyConversionRequest", "LegacyConversionReport",
        "LegacyConversionFailure", "LegacyRowIdentity", "runLegacyConversion",
        "convertibleIdentities",
    ]

    /// …/native/SoloLedger/Tests/SoloLedgerCoreTests/<this>.swift → …/native/SoloLedger
    private static func packageRoot() -> URL {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { dir.deleteLastPathComponent() }
        return dir
    }

    private static func appSources() throws -> [(path: String, text: String)] {
        let root = packageRoot().appendingPathComponent("Sources/SoloLedger")
        guard let walker = FileManager.default.enumerator(atPath: root.path) else {
            XCTFail("cannot enumerate \(root.path)"); return []
        }
        var out: [(String, String)] = []
        for case let rel as String in walker where rel.hasSuffix(".swift") {
            let url = root.appendingPathComponent(rel)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                XCTFail("cannot read \(rel)"); continue
            }
            out.append(("Sources/SoloLedger/\(rel)", text))
        }
        return out
    }

    private static func mentions(of names: [String],
                                 in sources: [(path: String, text: String)]) -> [String] {
        var out: [String] = []
        for (path, text) in sources {
            for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated() {
                let line = String(raw)
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                for name in names {
                    guard let re = try? NSRegularExpression(
                        pattern: "(?<![A-Za-z0-9_])\(name)(?![A-Za-z0-9_])") else { continue }
                    if re.firstMatch(in: line,
                                     range: NSRange(line.startIndex..., in: line)) != nil {
                        out.append("\(path):\(index + 1) \(name)")
                    }
                }
            }
        }
        return out
    }
}
