import XCTest
@testable import SoloLedgerCore

/// The storage-atomicity round's third item — ``AttachmentDeletion`` — and the four properties it
/// only has if they are measured: the reference set is BOTH columns, the target is an inode and not
/// a name, the parent is a descriptor and not a path, and the gap between "nothing references it"
/// and `unlink` is held shut by a lock a second connection can be seen bouncing off.
///
/// Every one of those is written so that removing the thing it protects turns THIS file red and
/// nothing else. The mutation each test kills is named on the test.
///
/// **What is deliberately not here: a test for race E.** After the file is gone the relative name is
/// free, and a stale or non-cooperating writer can claim it again. This round does not close that and
/// does not pretend to; ``testTheResidualRaceIsRegisteredAsADSixPrerequisiteRatherThanClosed`` checks
/// that the spec says so in as many words, which is the opposite of a green test standing in for a
/// fix.
final class AttachmentDeletionTests: LedgerTestCase {

    // MARK: - Fixtures

    /// A ledger and an attachments directory that are SIBLINGS, so a test may rename the attachments
    /// directory without disturbing the database — which is exactly what the descriptor-rooted
    /// property has to survive.
    private struct Bench {
        let store: LedgerStore
        let attachments: URL
        let root: URL
    }

    private func makeBench() throws -> Bench {
        let root = try symlinkFreeTempDir()
        let ledger = root.appendingPathComponent("ledger", isDirectory: true)
        let attachments = root.appendingPathComponent("attachments-root", isDirectory: true)
        try FileManager.default.createDirectory(at: ledger, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        let store = try LedgerStore(databaseURL: ledger.appendingPathComponent("test.db"))
        return Bench(store: store, attachments: attachments, root: root)
    }

    /// `/var/…` is a symlink to `/private/var` on macOS, and `DirectoryHandle.open` is no-follow on
    /// the LAST component only — but resolving up front keeps every path in these tests describing
    /// one object under both spellings.
    private func symlinkFreeTempDir() throws -> URL {
        let directory = try trackedTempDir()
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(directory.path, &buffer) != nil else { return directory }
        return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
    }

    @discardableResult
    private func plant(_ name: String, _ contents: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func exists(_ name: String, in directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
    }

    private func contents(_ name: String, in directory: URL) -> String? {
        try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    }

    private func reference(_ path: String) -> String { "attachments/docs/" + path }

    /// A transaction that points at `storedPath` — the FIRST of the two authoritative columns.
    private func seedTransactionReference(_ store: LedgerStore, path: String, id: String = "t1") throws {
        try store.db.run("""
            INSERT INTO transactions (id, type, date, amount, currency, counterparty, attachment_path)
            VALUES (?, 'income', '2026-01-10', 100, 'CNY', 'Acme', ?)
            """, [.text(id), .text(path)])
    }

    /// A document that points at `storedPath` — the SECOND column.
    @discardableResult
    private func seedDocumentReference(_ store: LedgerStore, path: String) throws -> String {
        let id = try store.createBusinessDocument(
            BusinessDocumentDraft(type: .quotation, number: "AD-\(path.count)-\(UUID().uuidString.prefix(6))",
                                  date: "2026-01-01", customerName: "C"))
        _ = try store.updateTaxInvoice(documentID: id, TaxInvoiceEdit(attachmentPath: path))
        return id
    }

    /// A REAL second connection to the same file, with a short busy timeout so a blocked write fails
    /// in milliseconds instead of after the store's own five seconds.
    private func secondConnection(to store: LedgerStore) throws -> SQLiteDatabase {
        let other = try SQLiteDatabase(path: store.db.path, mode: .readWriteExisting)
        try other.execute("PRAGMA busy_timeout = 50")
        try other.execute("PRAGMA foreign_keys = ON")
        return other
    }

    // MARK: - 1 · the happy path, so nothing below passes by finding nothing

    func testAnUnreferencedCopyIsRemoved() throws {
        let bench = try makeBench()
        defer { try? bench.store.db.close() }
        try plant("a.pdf", "payload", in: bench.attachments)

        let outcome = AttachmentDeletion.deleteIfUnreferenced(
            reference("a.pdf"), in: bench.attachments, using: bench.store.db)

        XCTAssertEqual(outcome, .deleted)
        XCTAssertFalse(exists("a.pdf", in: bench.attachments))
    }

    /// A missing file is success, per the ruling. Reported as its own case so a log can tell the two
    /// apart, but a caller treats both as done.
    func testAMissingCopyIsSuccessAndNotAFailure() throws {
        let bench = try makeBench()
        defer { try? bench.store.db.close() }
        XCTAssertEqual(AttachmentDeletion.deleteIfUnreferenced(
            reference("gone.pdf"), in: bench.attachments, using: bench.store.db), .alreadyGone)
    }

    // MARK: - 2 · BOTH reference columns (kills: scanning only the documents table)

    /// **Mutation killed: dropping `transactions.attachment_path` from `referenceColumns`.** The two
    /// features share one directory; a scan of the documents column alone deletes a receipt a
    /// transaction still points at.
    func testATransactionReferenceKeepsTheFile() throws {
        let bench = try makeBench()
        defer { try? bench.store.db.close() }
        try plant("t.pdf", "receipt", in: bench.attachments)
        try seedTransactionReference(bench.store, path: reference("t.pdf"))

        XCTAssertEqual(AttachmentDeletion.deleteIfUnreferenced(
            reference("t.pdf"), in: bench.attachments, using: bench.store.db), .stillReferenced)
        XCTAssertEqual(contents("t.pdf", in: bench.attachments), "receipt",
                       "the file a transaction still points at must be untouched")
    }

    /// The other half of the same closed set.
    func testADocumentReferenceKeepsTheFile() throws {
        let bench = try makeBench()
        defer { try? bench.store.db.close() }
        try plant("d.pdf", "invoice", in: bench.attachments)
        try seedDocumentReference(bench.store, path: reference("d.pdf"))

        XCTAssertEqual(AttachmentDeletion.deleteIfUnreferenced(
            reference("d.pdf"), in: bench.attachments, using: bench.store.db), .stillReferenced)
        XCTAssertEqual(contents("d.pdf", in: bench.attachments), "invoice")
    }

    /// …and the set is COMPLETE: no other column in the shipped schema can hold such a reference.
    /// Asked of the live database rather than of the source, so a column added by a future migration
    /// shows up here rather than in a review.
    func testTheTwoColumnsAreEveryColumnThatCanHoldAReference() throws {
        let bench = try makeBench()
        defer { try? bench.store.db.close() }
        let tables = try bench.store.db
            .query("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")
            .compactMap { $0.string("name") }
        XCTAssertGreaterThan(tables.count, 5, "an empty table list would satisfy the scan trivially")

        var found: [String] = []
        for table in tables {
            for column in try bench.store.db.query("PRAGMA table_info(\(table))") {
                guard let name = column.string("name") else { continue }
                if name.lowercased().contains("attachment") { found.append("\(table).\(name)") }
            }
        }
        XCTAssertEqual(found.sorted(),
                       ["business_documents.tax_invoice_attachment_path", "transactions.attachment_path"],
                       "a third attachment column exists; AttachmentDeletion.referenceColumns must learn about it")
        XCTAssertEqual(AttachmentDeletion.referenceColumns.map { "\($0.table).\($0.column)" }.sorted(),
                       found.sorted())
    }

    /// The comparison is the WIDE one on purpose: a false "referenced" keeps a file, a false
    /// "unreferenced" destroys one. Canonically-equal spellings count, a different name does not, and
    /// only the final segment is looked at.
    func testTheReferenceComparisonIsWiderThanTheOwnershipOne() {
        XCTAssertTrue(AttachmentDeletion.namesTheSameFile("attachments/docs/a.pdf", "a.pdf"))
        XCTAssertTrue(AttachmentDeletion.namesTheSameFile("a.pdf", "a.pdf"), "a bare name still counts")
        XCTAssertTrue(AttachmentDeletion.namesTheSameFile("wherever/else/a.pdf", "a.pdf"),
                      "a reference the whitelist would reject still keeps the file")
        XCTAssertFalse(AttachmentDeletion.namesTheSameFile("attachments/docs/b.pdf", "a.pdf"))
        XCTAssertFalse(AttachmentDeletion.namesTheSameFile("attachments/docs/", "a.pdf"))
        XCTAssertFalse(AttachmentDeletion.namesTheSameFile("", "a.pdf"))
        // Canonical equivalence, which `StatementText.areEqual` — JS `===` — reports as different.
        let composed = "e\u{0301}.pdf", precomposed = "\u{e9}.pdf"
        XCTAssertFalse(StatementText.areEqual(composed, precomposed), "the two spellings really differ")
        XCTAssertTrue(AttachmentDeletion.namesTheSameFile("attachments/docs/" + composed, precomposed),
                      "…and the deletion primitive still treats them as one file")
    }

    // MARK: - 3 · the path whitelist (kills: taking the last path component instead)

    /// **Mutation killed: replacing ``AttachmentRelPath/bareName(of:)`` with anything looser** — the
    /// obvious loosening being "take the segment after the last slash", which turns a traversal
    /// reference into a delete of a neighbour.
    func testATraversalReferenceIsRefusedAndItsVictimSurvives() throws {
        let bench = try makeBench()
        defer { try? bench.store.db.close() }
        try plant("victim.pdf", "keep me", in: bench.attachments)

        XCTAssertEqual(AttachmentDeletion.deleteIfUnreferenced(
            "attachments/docs/../victim.pdf", in: bench.attachments, using: bench.store.db),
            .rejectedReference)
        XCTAssertEqual(contents("victim.pdf", in: bench.attachments), "keep me")
    }

    func testEveryShapeOutsideTheWhitelistIsRefusedBeforeTheFilesystemIsTouched() throws {
        let bench = try makeBench()
        defer { try? bench.store.db.close() }
        try plant("real.pdf", "payload", in: bench.attachments)

        let refused = [
            "/etc/passwd",                              // absolute
            "attachments/docs/",                        // empty name
            "attachments/docs/sub/real.pdf",            // extra segment
            "attachments/real.pdf",                     // wrong prefix
            "real.pdf",                                 // no prefix
            "attachments/docs/.hidden.pdf",             // first character not alphanumeric
            "attachments/docs/ré.pdf",                  // non-ASCII
            "ATTACHMENTS/DOCS/real.pdf",                // prefix is case-sensitive
        ]
        for raw in refused {
            XCTAssertEqual(AttachmentDeletion.deleteIfUnreferenced(
                raw, in: bench.attachments, using: bench.store.db), .rejectedReference, raw)
        }
        XCTAssertTrue(exists("real.pdf", in: bench.attachments), "nothing was touched")
        // Not vacuous: the whitelisted spelling of the same file IS accepted.
        XCTAssertEqual(AttachmentDeletion.deleteIfUnreferenced(
            reference("real.pdf"), in: bench.attachments, using: bench.store.db), .deleted)
    }

    // MARK: - 4 · the target is an inode (kills: unlinking by name)

    /// **Mutation killed: dropping the device+inode comparison**, i.e. calling `unlinkat` on the name
    /// instead of `unlinkIfStillBound`. The stand-in put there during the window must survive.
    func testAStandInSwappedInDuringTheWindowIsNotRemoved() throws {
        let bench = try makeBench()
        defer { try? bench.store.db.close() }
        try plant("swap.pdf", "original", in: bench.attachments)

        var hooks = AttachmentDeletion.Hooks()
        hooks.afterScanBeforeUnlink = { [attachments = bench.attachments] in
            // Remove the bound file and put a DIFFERENT file at the same name.
            try? FileManager.default.removeItem(at: attachments.appendingPathComponent("swap.pdf"))
            try? Data("stand-in".utf8).write(to: attachments.appendingPathComponent("swap.pdf"))
        }

        let outcome = AttachmentDeletion.deleteIfUnreferenced(
            reference("swap.pdf"), in: bench.attachments, using: bench.store.db, hooks: hooks)

        XCTAssertEqual(outcome, .movedUnderUs)
        XCTAssertEqual(contents("swap.pdf", in: bench.attachments), "stand-in",
                       "the object that is there now was never the one this call bound")
    }

    /// A symlink and a directory at the name are refused at the bind, before any unlink is possible.
    func testASymlinkOrADirectoryAtTheNameIsNeverFollowedAndNeverRemoved() throws {
        let bench = try makeBench()
        defer { try? bench.store.db.close() }
        let outside = try plant("secret.pdf", "do not touch", in: bench.root)

        try FileManager.default.createSymbolicLink(
            at: bench.attachments.appendingPathComponent("link.pdf"), withDestinationURL: outside)
        try FileManager.default.createDirectory(
            at: bench.attachments.appendingPathComponent("dir.pdf"), withIntermediateDirectories: false)

        XCTAssertEqual(AttachmentDeletion.deleteIfUnreferenced(
            reference("link.pdf"), in: bench.attachments, using: bench.store.db), .notARegularFile)
        XCTAssertEqual(AttachmentDeletion.deleteIfUnreferenced(
            reference("dir.pdf"), in: bench.attachments, using: bench.store.db), .notARegularFile)

        XCTAssertEqual(contents("secret.pdf", in: bench.root), "do not touch",
                       "the symlink's target must be untouched")
        XCTAssertTrue(exists("link.pdf", in: bench.attachments), "…and so must the link itself")
        XCTAssertTrue(exists("dir.pdf", in: bench.attachments))
    }

    // MARK: - 5 · the parent is a descriptor (kills: deleting through a path)

    /// **Mutation killed: `FileManager.removeItem(at: attachmentsDirectory.appending(name))`.**
    ///
    /// The directory is renamed away during the window and a FRESH directory with a file of the same
    /// name is put at the old path. A path-based delete removes the planted replacement — a file this
    /// call never saw, in a directory it never bound. The descriptor-rooted `unlinkat` removes the
    /// real one, inside the renamed directory, and leaves the replacement alone.
    func testRenamingTheParentDuringTheWindowCannotRedirectTheUnlink() throws {
        let bench = try makeBench()
        defer { try? bench.store.db.close() }
        try plant("target.pdf", "the real one", in: bench.attachments)
        let moved = bench.root.appendingPathComponent("attachments-moved", isDirectory: true)

        var hooks = AttachmentDeletion.Hooks()
        hooks.afterScanBeforeUnlink = { [original = bench.attachments] in
            try? FileManager.default.moveItem(at: original, to: moved)
            try? FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
            try? Data("planted".utf8).write(to: original.appendingPathComponent("target.pdf"))
        }

        let outcome = AttachmentDeletion.deleteIfUnreferenced(
            reference("target.pdf"), in: bench.attachments, using: bench.store.db, hooks: hooks)

        XCTAssertEqual(outcome, .deleted)
        XCTAssertEqual(contents("target.pdf", in: bench.attachments), "planted", """
            the planted replacement at the ORIGINAL path was removed, which means the unlink resolved \
            a path instead of using the bound descriptor
            """)
        XCTAssertFalse(exists("target.pdf", in: moved), "the file this call actually bound is gone")
    }

    // MARK: - 6 · the D window (kills: scanning outside the write lock)

    /// **Mutation killed: moving the scan and the unlink out of
    /// ``SQLiteDatabase/immediateTransaction(_:)``.**
    ///
    /// A real second connection to the same file tries to claim the path at exactly the instant
    /// between "nothing references it" and `unlink`. With the write lock held it cannot commit; with
    /// the scan outside the lock it can, and the file is then deleted while a row points at it.
    ///
    /// Two assertions, because either alone could pass for the wrong reason: the claim must FAIL, and
    /// the ledger must not end up holding a reference to a file that is gone.
    func testASecondConnectionCannotClaimThePathInsideTheWindow() throws {
        let bench = try makeBench()
        defer { try? bench.store.db.close() }
        try plant("race.pdf", "payload", in: bench.attachments)
        let other = try secondConnection(to: bench.store)
        defer { try? other.close() }

        var claimError: Error?
        var hooks = AttachmentDeletion.Hooks()
        hooks.afterScanBeforeUnlink = {
            do {
                try other.run("""
                    INSERT INTO transactions (id, type, date, amount, currency, counterparty, attachment_path)
                    VALUES ('racer', 'income', '2026-01-10', 100, 'CNY', 'Acme', ?)
                    """, [.text(self.reference("race.pdf"))])
            } catch { claimError = error }
        }

        let outcome = AttachmentDeletion.deleteIfUnreferenced(
            reference("race.pdf"), in: bench.attachments, using: bench.store.db, hooks: hooks)

        XCTAssertNotNil(claimError, """
            a second connection committed a reference between the scan and the unlink. The scan and \
            the unlink must sit inside one BEGIN IMMEDIATE.
            """)
        XCTAssertEqual(outcome, .deleted)
        XCTAssertFalse(exists("race.pdf", in: bench.attachments))
        let dangling = try bench.store.db.query(
            "SELECT id FROM transactions WHERE attachment_path IS NOT NULL")
        XCTAssertTrue(dangling.isEmpty, "the ledger points at a file that no longer exists")
    }

    /// The lock is real in the other direction too: a claim committed BEFORE the call is seen, and the
    /// file survives. Without this, the test above could pass on a connection that simply cannot write.
    func testTheSecondConnectionCanWriteWhenTheWindowIsNotOpen() throws {
        let bench = try makeBench()
        defer { try? bench.store.db.close() }
        try plant("ok.pdf", "payload", in: bench.attachments)
        let other = try secondConnection(to: bench.store)
        defer { try? other.close() }

        XCTAssertNoThrow(try other.run("""
            INSERT INTO transactions (id, type, date, amount, currency, counterparty, attachment_path)
            VALUES ('early', 'income', '2026-01-10', 100, 'CNY', 'Acme', ?)
            """, [.text(reference("ok.pdf"))]))

        XCTAssertEqual(AttachmentDeletion.deleteIfUnreferenced(
            reference("ok.pdf"), in: bench.attachments, using: bench.store.db), .stillReferenced)
        XCTAssertTrue(exists("ok.pdf", in: bench.attachments))
    }

    // MARK: - 7 · the transaction helper this primitive needed

    func testTheImmediateTransactionCommitsItsWorkAndReturnsAValue() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        let answer = try store.db.immediateTransaction { () -> Int in
            try store.db.run("""
                INSERT INTO transactions (id, type, date, amount, currency, counterparty)
                VALUES ('c1', 'income', '2026-01-10', 100, 'CNY', 'Acme')
                """)
            return 42
        }
        XCTAssertEqual(answer, 42)
        XCTAssertEqual(try store.db.query("SELECT id FROM transactions").count, 1)
    }

    func testTheImmediateTransactionRollsBackEverythingWhenTheBlockThrows() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        struct Boom: Error {}
        XCTAssertThrowsError(try store.db.immediateTransaction { () -> Int in
            try store.db.run("""
                INSERT INTO transactions (id, type, date, amount, currency, counterparty)
                VALUES ('r1', 'income', '2026-01-10', 100, 'CNY', 'Acme')
                """)
            throw Boom()
        }) { XCTAssertTrue($0 is Boom, "the caller's own error is rethrown, not a SQLite one") }
        XCTAssertEqual(try store.db.query("SELECT id FROM transactions").count, 0)

        // …and the connection is usable afterwards, i.e. the ROLLBACK really ran.
        XCTAssertNoThrow(try store.db.immediateTransaction { try store.db.run("SELECT 1") })
    }

    /// It does not pretend to nest. SQLite has no nested transactions; the inner `BEGIN` throws, the
    /// outer rolls back, and the caller is never left believing it holds a lock it does not.
    func testTheImmediateTransactionDoesNotPretendToNest() throws {
        let store = try makeStore()
        defer { try? store.db.close() }
        XCTAssertThrowsError(try store.db.immediateTransaction { () -> Int in
            try store.db.run("""
                INSERT INTO transactions (id, type, date, amount, currency, counterparty)
                VALUES ('n1', 'income', '2026-01-10', 100, 'CNY', 'Acme')
                """)
            return try store.db.immediateTransaction { 1 }
        })
        XCTAssertEqual(try store.db.query("SELECT id FROM transactions").count, 0,
                       "the outer transaction rolled back rather than staying open")
        XCTAssertNoThrow(try store.db.run("""
            INSERT INTO transactions (id, type, date, amount, currency, counterparty)
            VALUES ('n2', 'income', '2026-01-10', 100, 'CNY', 'Acme')
            """), "and no transaction is left dangling on the connection")
    }

    // MARK: - 8 · nothing in the app calls it, and race E is registered rather than closed

    /// Ruling: the primitive lands with NO consumer. The App target must not name it, and the two
    /// places that drop a returned orphan must still drop it.
    func testTheAppTargetDoesNotCallThePrimitiveAndStillDiscardsBothOrphans() throws {
        let app = try CapabilityImportGuardTests.strippedSources(of: "SoloLedger")
        XCTAssertGreaterThan(app.count, 10, "an empty walk would satisfy the absence claim")

        let namers = app.filter { CapabilityImportGuardTests.matchCount(#"\bAttachmentDeletion\b"#,
                                                                        in: $0.code) > 0 }
        XCTAssertEqual(namers.map(\.path), [], """
            the App target names AttachmentDeletion. Connecting the deleting seam is D-6's, and it is \
            blocked on the residual-race ruling registered in the spec.
            """)
        // Not vacuous: the same walk finds the Core symbols the App legitimately names.
        XCTAssertGreaterThan(app.filter { CapabilityImportGuardTests.matchCount(#"\bLedgerStore\b"#,
                                                                                in: $0.code) > 0 }.count, 0)

        let model = try XCTUnwrap(app.first { $0.path == "AppModel.swift" })
        XCTAssertEqual(CapabilityImportGuardTests.matchCount(
            #"_ = try store\.deleteBusinessDocument\("#, in: model.code), 1,
            "the delete seam still discards the orphan it is handed")
        XCTAssertEqual(CapabilityImportGuardTests.matchCount(
            #"_ = try store\.updateTaxInvoice\("#, in: model.code), 1,
            "…and so does the association seam")
    }

    /// Race E — a stale or non-cooperating writer re-claiming the freed name — is NOT closed by this
    /// round. The only honest thing a test can assert about it is that the spec says so and makes it a
    /// prerequisite, which is what this checks. Reading the spec, not a comment: a comment can be
    /// deleted with the code it excuses.
    func testTheResidualRaceIsRegisteredAsADSixPrerequisiteRatherThanClosed() throws {
        let spec = try String(contentsOf: AppTargetRegistrationGuardTests.packageRoot()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/BUSINESS_DOCUMENTS_SPEC.md"), encoding: .utf8)
        XCTAssertGreaterThan(spec.count, 10_000, "the spec was not read")

        // The heading is asked for by itself, and so are the two candidate rulings underneath it.
        // Without the heading the remaining phrases still occur in the §9 revision row, so a spec that
        // had quietly dropped the registration would still satisfy a phrase-only check.
        for sentence in ["#### 竞态 E · 存储原子化的残余",
                         "D-6 接删除前的强制前置裁定",
                         "重新认领同一路径",
                         "**无 schema 协调**",
                         "**schema/所有权记录**"] {
            XCTAssertTrue(spec.contains(sentence), "the spec no longer registers race E: \(sentence)")
        }
        // The registration is NOT in the B series — the ruling puts it in the atomicity residual,
        // and a B row would file it as a settled difference instead of an open prerequisite.
        XCTAssertTrue(spec.contains("| B11 |"), "B11 registers the conditional writes themselves")
        XCTAssertFalse(spec.contains("| E |"), "race E must not be filed as a lettered difference row")
    }

    // MARK: - 9 · the wide match, measured END TO END rather than as a pure function

    /// **Mutation killed: making `namesTheSameFile` case-sensitive.**
    ///
    /// The default macOS volume is case-INSENSITIVE — measured right here, not assumed — so
    /// `A.pdf` and `a.pdf` are ONE file. A case-sensitive reference scan reports the other row's
    /// reference as "not this file", `openat` hands back the very inode that row points at, and the
    /// referenced file is destroyed. `AttachmentName` admits `A-Z`, and Electron-migrated names are
    /// not lower-cased, so the two spellings can genuinely coexist in one ledger.
    func testAReferenceThatDiffersOnlyInCaseStillKeepsTheFile() throws {
        let bench = try makeBench()
        defer { try? bench.store.db.close() }
        try plant("Receipt.PDF", "keep me", in: bench.attachments)

        // The premise, measured on the volume this test is running on. If the volume turns out to be
        // case-sensitive the fold is not load-bearing there, and the test says so instead of pretending.
        let lower = bench.attachments.appendingPathComponent("receipt.pdf")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: lower.path),
                          "this volume is case-sensitive; the case fold is not load-bearing here")
        XCTAssertEqual(try String(contentsOf: lower, encoding: .utf8), "keep me",
                       "the two spellings name one file on this volume")

        try seedTransactionReference(bench.store, path: reference("Receipt.PDF"))

        XCTAssertEqual(AttachmentDeletion.deleteIfUnreferenced(
            reference("receipt.pdf"), in: bench.attachments, using: bench.store.db), .stillReferenced)
        XCTAssertEqual(contents("Receipt.PDF", in: bench.attachments), "keep me",
                       "a case-sensitive scan would have deleted the file the transaction points at")
    }

    /// **Mutation killed: dropping `CAST(… AS TEXT)` from the scan.** `SQLiteValue.stringValue`
    /// answers `nil` for a BLOB, so a reference a foreign writer stored as a blob reads as no
    /// reference at all — and the file goes. Same class of foreign value the chapter already reasons
    /// about for a stored `''`.
    func testAReferenceStoredAsABlobStillKeepsTheFile() throws {
        let bench = try makeBench()
        defer { try? bench.store.db.close() }
        try plant("blob.pdf", "keep me", in: bench.attachments)
        try bench.store.db.run("""
            INSERT INTO transactions (id, type, date, amount, currency, counterparty, attachment_path)
            VALUES ('tb', 'income', '2026-01-10', 100, 'CNY', 'Acme', ?)
            """, [.blob(Data(reference("blob.pdf").utf8))])

        // The premise: it really is stored as a blob, and the plain decode really does drop it.
        XCTAssertEqual(try bench.store.db.query(
            "SELECT typeof(attachment_path) AS t FROM transactions WHERE id = 'tb'")
            .first?.string("t"), "blob")
        XCTAssertNil(try bench.store.db.query(
            "SELECT attachment_path AS ref FROM transactions WHERE id = 'tb'").first?.string("ref"),
            "an uncast read of the same cell hands back nothing at all")

        XCTAssertEqual(AttachmentDeletion.deleteIfUnreferenced(
            reference("blob.pdf"), in: bench.attachments, using: bench.store.db), .stillReferenced)
        XCTAssertEqual(contents("blob.pdf", in: bench.attachments), "keep me")
    }

    /// A reference whose stored spelling the whitelist itself would reject still keeps the file — the
    /// end-to-end half of ``testTheReferenceComparisonIsWiderThanTheOwnershipOne``, which until now
    /// only exercised the comparison as a pure function.
    func testAReferenceTheWhitelistWouldRejectStillKeepsTheFile() throws {
        let bench = try makeBench()
        defer { try? bench.store.db.close() }
        try plant("odd.pdf", "keep me", in: bench.attachments)
        try seedTransactionReference(bench.store, path: "somewhere/else/odd.pdf")

        XCTAssertEqual(AttachmentDeletion.deleteIfUnreferenced(
            reference("odd.pdf"), in: bench.attachments, using: bench.store.db), .stillReferenced)
        XCTAssertEqual(contents("odd.pdf", in: bench.attachments), "keep me")
    }

    // MARK: - 10 · `unavailable` is reachable and fail-closed

    /// A directory that cannot be bound reports ``AttachmentDeletion/Outcome/unavailable`` and removes
    /// nothing — the fail-closed branch, which until now no test entered at all.
    func testAnUnbindableDirectoryIsFailClosed() throws {
        let bench = try makeBench()
        defer { try? bench.store.db.close() }
        let missing = bench.root.appendingPathComponent("no-such-directory", isDirectory: true)
        XCTAssertEqual(AttachmentDeletion.deleteIfUnreferenced(
            reference("a.pdf"), in: missing, using: bench.store.db), .unavailable)

        // A file where a directory should be is the other way to fail the bind.
        try plant("not-a-dir", "x", in: bench.root)
        XCTAssertEqual(AttachmentDeletion.deleteIfUnreferenced(
            reference("a.pdf"), in: bench.root.appendingPathComponent("not-a-dir"),
            using: bench.store.db), .unavailable)
    }

    /// Called from inside an open transaction it removes nothing and says `unavailable`, because its
    /// own `BEGIN IMMEDIATE` cannot nest. That is the contract D-6 has to honour, so it is pinned
    /// rather than left to be discovered.
    func testCalledInsideATransactionItDeletesNothingAndSaysSo() throws {
        let bench = try makeBench()
        defer { try? bench.store.db.close() }
        try plant("nested.pdf", "payload", in: bench.attachments)

        try bench.store.db.transaction {
            XCTAssertEqual(AttachmentDeletion.deleteIfUnreferenced(
                reference("nested.pdf"), in: bench.attachments, using: bench.store.db), .unavailable)
        }
        XCTAssertEqual(contents("nested.pdf", in: bench.attachments), "payload")
        // …and the connection is still usable, i.e. the failed nested BEGIN did not wedge it.
        XCTAssertEqual(AttachmentDeletion.deleteIfUnreferenced(
            reference("nested.pdf"), in: bench.attachments, using: bench.store.db), .deleted)
    }
}
