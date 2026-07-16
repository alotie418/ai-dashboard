import XCTest
@testable import SoloLedgerCore

/// Real DB reference audit (Phase 2B-1 C2): read-only scan of the two authoritative
/// attachment-reference columns, structured resolved/dangling/invalid evidence with
/// provenance, fail-closed schema/identity gates. All fixtures are synthetic temp files.
final class AttachmentReferenceAuditorTests: LedgerTestCase {

    private let fm = FileManager.default
    private struct TestError: Error {}

    // MARK: - Fixtures

    /// A migrated (user_version 23), quiescent DELETE-journal prepared DB whose reference
    /// columns hold the given RAW SQLite values (so tests can plant numeric/blob junk).
    private func makePreparedDB(txnRefs: [SQLiteValue] = [], docRefs: [SQLiteValue] = []) throws -> URL {
        let url = try trackedTempDir().appendingPathComponent("prepared.db")
        do {
            let db = try SQLiteDatabase(path: url.path)
            try db.execute("PRAGMA journal_mode = DELETE")
            try SchemaMigrator.migrate(db)
            try insertRefs(db, txnRefs: txnRefs, docRefs: docRefs)
        }
        return url
    }

    private func insertRefs(_ db: SQLiteDatabase, txnRefs: [SQLiteValue], docRefs: [SQLiteValue]) throws {
        for (i, v) in txnRefs.enumerated() {
            try db.run("INSERT INTO transactions (id, type, date, amount, attachment_path) VALUES (?, 'expense', '2026-01-01', 1.0, ?)",
                       [.text("txn-\(i)-\(UUID().uuidString)"), v])
        }
        for (i, v) in docRefs.enumerated() {
            try db.run("INSERT INTO business_documents (id, doc_type, doc_number, doc_date, customer_name, tax_invoice_attachment_path) VALUES (?, 'quotation', ?, '2026-01-01', 'c', ?)",
                       [.text("doc-\(i)-\(UUID().uuidString)"), .text("Q-\(i)-\(UUID().uuidString)"), v])
        }
    }

    private func ref(_ name: String) -> SQLiteValue { .text("attachments/docs/" + name) }

    private func encode(_ m: ImportManifest) throws -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return try e.encode(m)
    }

    private func makeStaging(ingested: [(name: String, bytes: String)]) throws -> URL {
        let importID = ImportID("audit-\(UUID().uuidString)")!
        let dir = try trackedTempDir().appendingPathComponent("import-\(importID.rawValue)", isDirectory: true)
        let docs = dir.appendingPathComponent("attachments", isDirectory: true).appendingPathComponent("docs", isDirectory: true)
        try fm.createDirectory(at: docs, withIntermediateDirectories: true)
        var files: [ImportManifest.FileResult] = []
        for f in ingested {
            let url = docs.appendingPathComponent(f.name)
            try Data(f.bytes.utf8).write(to: url)
            files.append(.init(name: f.name, outcome: .ingested, sha256: try FileHash.sha256Hex(of: url), size: Int64(f.bytes.utf8.count)))
        }
        let manifest = ImportManifest(formatVersion: ImportManifest.currentFormatVersion, importID: importID.rawValue,
                                      sourceKind: "test", createdAt: "t", sourceDBSHA256: "db", walSHA256: nil,
                                      snapshotIdentitySHA256: "snap", attachmentManifestSHA256: ImportManifest.attachmentSetHash(files),
                                      files: files, status: .ingested, report: nil)
        try encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
        return dir
    }

    private func makeActive(_ files: [(name: String, bytes: String)] = []) throws -> URL {
        let dir = try trackedTempDir().appendingPathComponent("active-docs", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in files { try Data(f.bytes.utf8).write(to: dir.appendingPathComponent(f.name)) }
        return dir
    }

    private func makeManifestsDir() throws -> URL {
        let dir = try trackedTempDir().appendingPathComponent("ImportManifests", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Stage + apply against the REAL identity of `dbURL`, so the audit's recompute matches.
    private func applyReport(staged: [(name: String, bytes: String)], active: URL, dbURL: URL) throws -> AttachmentApplyReport {
        let staging = try makeStaging(ingested: staged)
        let identity = try PreparedDatabaseIdentity.compute(at: dbURL)
        return try AttachmentApply().apply(stagingDir: staging, activeAttachmentsDir: active,
                                           preparedDBIdentity: identity, hooks: ApplyHooks())
    }

    private func audit(_ report: AttachmentApplyReport, _ dbURL: URL,
                       hooks: AttachmentReferenceAuditor.AuditHooks = .init()) throws -> ReferenceAudit {
        try AttachmentReferenceAuditor().audit(report: report, preparedDatabaseAt: dbURL, hooks: hooks)
    }

    // MARK: - Happy path / skips

    func testResolvedReferencesHappyPath() throws {
        let db = try makePreparedDB(txnRefs: [ref("a.pdf")], docRefs: [ref("b.pdf")])
        let active = try makeActive()
        let report = try applyReport(staged: [("a.pdf", "A"), ("b.pdf", "B")], active: active, dbURL: db)
        let a = try audit(report, db)

        XCTAssertEqual(a.dangling, []); XCTAssertEqual(a.invalid, [])
        XCTAssertEqual(a.resolved.map { $0.name }, ["a.pdf", "b.pdf"])
        XCTAssertEqual(a.resolved.map { $0.provenance },
                       ["transactions.attachment_path×1", "business_documents.tax_invoice_attachment_path×1"])
        XCTAssertEqual(a.resolved[0].sha256, try FileHash.sha256Hex(of: active.appendingPathComponent("a.pdf")))

        let outcome = try AttachmentApply().complete(report: report, referenceAudit: a, acknowledgement: nil,
                                                     preparedDatabaseAt: db, manifestsDir: try makeManifestsDir(), hooks: ApplyHooks())
        guard case .completed(let r) = outcome else { return XCTFail("got \(outcome)") }
        XCTAssertTrue(r.unresolved.isEmpty)
    }

    func testNullAndEmptyAreNotReferences() throws {
        let db = try makePreparedDB(txnRefs: [.null, .text("")], docRefs: [.null, .text("")])
        let report = try applyReport(staged: [], active: try makeActive(), dbURL: db)
        let a = try audit(report, db)
        XCTAssertEqual(a.resolved, []); XCTAssertEqual(a.dangling, []); XCTAssertEqual(a.invalid, [])
    }

    // MARK: - Dangling with provenance

    func testDanglingProvenanceAggregatesColumnsAndCounts() throws {
        let db = try makePreparedDB(txnRefs: [ref("ghost.pdf"), ref("ghost.pdf")], docRefs: [ref("ghost.pdf")])
        let report = try applyReport(staged: [], active: try makeActive(), dbURL: db)
        let a = try audit(report, db)

        XCTAssertEqual(a.dangling, [.init(name: "ghost.pdf",
                                          provenance: "business_documents.tax_invoice_attachment_path×1; transactions.attachment_path×2")])

        let manifests = try makeManifestsDir()
        let o1 = try AttachmentApply().complete(report: report, referenceAudit: a, acknowledgement: nil,
                                                preparedDatabaseAt: db, manifestsDir: manifests, hooks: ApplyHooks())
        guard case .requiresAcknowledgement(let req, let unresolved) = o1 else { return XCTFail("got \(o1)") }
        XCTAssertEqual(unresolved.items, [.init(name: "ghost.pdf", kind: .danglingReference,
                                                detail: "business_documents.tax_invoice_attachment_path×1; transactions.attachment_path×2")])

        let o2 = try AttachmentApply().complete(report: report, referenceAudit: a, acknowledgement: req.acknowledge(),
                                                preparedDatabaseAt: db, manifestsDir: manifests, hooks: ApplyHooks())
        guard case .completed(let r) = o2 else { return XCTFail("got \(o2)") }
        XCTAssertEqual(r.unresolved.items.first?.detail,
                       "business_documents.tax_invoice_attachment_path×1; transactions.attachment_path×2")
    }

    /// Same unresolved NAME but different provenance/count ⇒ different reportHash ⇒ a
    /// previously issued acknowledgement is stale and must be rejected.
    func testProvenanceOrCountChangeInvalidatesAcknowledgement() throws {
        let db = try makePreparedDB(txnRefs: [ref("g.pdf")])
        let report = try applyReport(staged: [], active: try makeActive(), dbURL: db)
        func evidence(_ provenance: String) -> ReferenceAudit {
            ReferenceAudit(importID: report.importID.rawValue,
                           snapshotIdentitySHA256: report.manifest.snapshotIdentitySHA256,
                           attachmentManifestSHA256: report.manifest.attachmentManifestSHA256,
                           preparedDBIdentity: report.preparedDBIdentity,
                           dangling: [.init(name: "g.pdf", provenance: provenance)])
        }
        let manifests = try makeManifestsDir()
        let o1 = try AttachmentApply().complete(report: report, referenceAudit: evidence("transactions.attachment_path×1"),
                                                acknowledgement: nil, preparedDatabaseAt: db, manifestsDir: manifests, hooks: ApplyHooks())
        guard case .requiresAcknowledgement(let req1, _) = o1 else { return XCTFail("got \(o1)") }

        for changed in ["transactions.attachment_path×2",
                        "business_documents.tax_invoice_attachment_path×1; transactions.attachment_path×1"] {
            let o2 = try AttachmentApply().complete(report: report, referenceAudit: evidence(changed),
                                                    acknowledgement: req1.acknowledge(), preparedDatabaseAt: db, manifestsDir: manifests, hooks: ApplyHooks())
            guard case .requiresAcknowledgement(let req2, _) = o2 else { return XCTFail("stale ack must be rejected for '\(changed)'") }
            XCTAssertNotEqual(req2.unresolvedReportHash, req1.unresolvedReportHash)
        }
    }

    // MARK: - Invalid values (never silently dropped, never mutate the DB)

    func testInvalidValuesRecordedGatedAndReadOnly() throws {
        // NOTE: the real columns have TEXT affinity, so bound INTEGER/REAL junk is stored
        // as its text rendering ("7", "1.5") and surfaces as an invalid TEXT reference;
        // BLOBs survive affinity untouched. Genuinely non-TEXT stored values are covered
        // by testNonTextValuesRecordedAsTypedInvalid on a no-affinity schema.
        let db = try makePreparedDB(
            txnRefs: [.text("/abs/x.pdf"), .text("attachments/docs/../up.pdf"), .integer(7), .real(1.5), .blob(Data([1, 2, 3]))],
            docRefs: [.text("docs/x.pdf")])
        let report = try applyReport(staged: [], active: try makeActive(), dbURL: db)

        let dirBefore = try fm.contentsOfDirectory(atPath: db.deletingLastPathComponent().path).sorted()
        let hashBefore = try FileHash.sha256Hex(of: db)
        let a = try audit(report, db)
        XCTAssertEqual(try FileHash.sha256Hex(of: db), hashBefore, "audit must not modify the database")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: db.deletingLastPathComponent().path).sorted(), dirBefore,
                       "audit must not create files")

        XCTAssertEqual(a.resolved, []); XCTAssertEqual(a.dangling, [])
        XCTAssertEqual(a.invalid.map { $0.value },
                       ["/abs/x.pdf", "1.5", "7", "<BLOB 3 bytes>", "attachments/docs/../up.pdf", "docs/x.pdf"])
        XCTAssertEqual(a.invalid.first?.provenance, "transactions.attachment_path×1")
        XCTAssertEqual(a.invalid.last?.provenance, "business_documents.tax_invoice_attachment_path×1")

        let manifests = try makeManifestsDir()
        let o1 = try AttachmentApply().complete(report: report, referenceAudit: a, acknowledgement: nil,
                                                preparedDatabaseAt: db, manifestsDir: manifests, hooks: ApplyHooks())
        guard case .requiresAcknowledgement(let req, let unresolved) = o1 else { return XCTFail("invalid refs must gate completion") }
        XCTAssertEqual(Set(unresolved.items.map { $0.kind }), [.invalidReference])

        let o2 = try AttachmentApply().complete(report: report, referenceAudit: a, acknowledgement: req.acknowledge(),
                                                preparedDatabaseAt: db, manifestsDir: manifests, hooks: ApplyHooks())
        guard case .completed(let r) = o2 else { return XCTFail("got \(o2)") }
        XCTAssertEqual(r.unresolved.items.count, 6)
    }

    /// A database written by other tooling can hold genuinely non-TEXT values in these
    /// columns (no affinity conversion). They must surface as typed invalid evidence,
    /// never be coerced through a string accessor into a plausible-looking path.
    func testNonTextValuesRecordedAsTypedInvalid() throws {
        let db = try makeBareDB(tables: [
            "CREATE TABLE transactions (id TEXT PRIMARY KEY, attachment_path)",          // no affinity
            "CREATE TABLE business_documents (id TEXT PRIMARY KEY, tax_invoice_attachment_path)",
        ])
        do {
            let w = try SQLiteDatabase(path: db.path)
            try w.run("INSERT INTO transactions (id, attachment_path) VALUES ('t1', ?)", [.integer(7)])
            try w.run("INSERT INTO transactions (id, attachment_path) VALUES ('t2', ?)", [.real(1.5)])
            try w.run("INSERT INTO business_documents (id, tax_invoice_attachment_path) VALUES ('d1', ?)", [.blob(Data([9]))])
        }
        let report = try applyReport(staged: [], active: try makeActive(), dbURL: db)
        let a = try audit(report, db)
        XCTAssertEqual(a.invalid.map { $0.value }, ["<BLOB 1 bytes>", "<INTEGER 7>", "<REAL 1.5>"])
        XCTAssertEqual(a.resolved, []); XCTAssertEqual(a.dangling, [])
    }

    // MARK: - Embedded NUL in TEXT (never truncated into a plausible path)

    func testEmbeddedNulTextRoundTripsThroughSQLite() throws {
        let url = try trackedTempDir().appendingPathComponent("nul.db")
        let db = try SQLiteDatabase(path: url.path)
        try db.execute("CREATE TABLE t (v TEXT)")
        let value = "attachments/docs/a.pdf\u{0}suffix"
        try db.run("INSERT INTO t (v) VALUES (?)", [.text(value)])
        // length(v) on TEXT counts only up to the first NUL (documented SQLite behavior),
        // so probe the stored size via the BLOB cast: the byte count must be the FULL value.
        let rows = try db.query("SELECT v, length(CAST(v AS BLOB)) AS n FROM t")
        XCTAssertEqual(rows.first?["v"], .text(value), "embedded NUL must survive bind AND read intact")
        XCTAssertEqual(rows.first?.int("n"), value.utf8.count, "SQLite must have stored every byte")
    }

    func testEmbeddedNulReferenceIsInvalidNeverResolvedOrDangling() throws {
        // "attachments/docs/a.pdf\0suffix" would String(cString:)-truncate to a VALID
        // reference to a.pdf — which exists in the active dir. It must instead surface as
        // an invalidReference for the FULL value: never resolved, never dangling.
        let smuggled = "attachments/docs/a.pdf\u{0}suffix"
        let db = try makePreparedDB(txnRefs: [.text(smuggled)])
        let active = try makeActive()
        let report = try applyReport(staged: [("a.pdf", "A")], active: active, dbURL: db)

        let hashBefore = try FileHash.sha256Hex(of: db)
        let a = try audit(report, db)
        XCTAssertEqual(try FileHash.sha256Hex(of: db), hashBefore, "audit stayed read-only")

        XCTAssertEqual(a.resolved, [], "a.pdf is NOT referenced — truncation would fabricate this")
        XCTAssertEqual(a.dangling, [])
        XCTAssertEqual(a.invalid, [.init(value: smuggled, provenance: "transactions.attachment_path×1")])

        // The item flows through ack + reportHash + sentinel with the full NUL-bearing value.
        let manifests = try makeManifestsDir()
        let o1 = try AttachmentApply().complete(report: report, referenceAudit: a, acknowledgement: nil,
                                                preparedDatabaseAt: db, manifestsDir: manifests, hooks: ApplyHooks())
        guard case .requiresAcknowledgement(let req, let unresolved) = o1 else { return XCTFail("got \(o1)") }
        XCTAssertEqual(unresolved.items, [.init(name: smuggled, kind: .invalidReference,
                                                detail: "transactions.attachment_path×1")])
        // A truncated variant of the same report must NOT share the hash (injective encoding).
        let truncated = UnresolvedReport(items: [.init(name: "attachments/docs/a.pdf", kind: .invalidReference,
                                                       detail: "transactions.attachment_path×1")])
        XCTAssertNotEqual(req.unresolvedReportHash, truncated.reportHash)

        let o2 = try AttachmentApply().complete(report: report, referenceAudit: a, acknowledgement: req.acknowledge(),
                                                preparedDatabaseAt: db, manifestsDir: manifests, hooks: ApplyHooks())
        guard case .completed(let r) = o2 else { return XCTFail("got \(o2)") }
        XCTAssertEqual(r.unresolved.items.first?.name, smuggled)
    }

    // MARK: - Non-regular active targets are never resolved

    func testActiveNonRegularTargetsAreNotResolved() throws {
        let db = try makePreparedDB(txnRefs: [ref("link.pdf"), ref("dir.pdf"), ref("fifo.pdf")])
        let active = try makeActive([("real.pdf", "R")])
        try fm.createSymbolicLink(at: active.appendingPathComponent("link.pdf"),
                                  withDestinationURL: active.appendingPathComponent("real.pdf"))
        try fm.createDirectory(at: active.appendingPathComponent("dir.pdf"), withIntermediateDirectories: true)
        guard mkfifo(active.appendingPathComponent("fifo.pdf").path, 0o644) == 0 else {
            throw XCTSkip("mkfifo unavailable in this environment")
        }

        let report = try applyReport(staged: [], active: active, dbURL: db)
        let a = try audit(report, db)
        XCTAssertEqual(a.resolved, [], "symlink/directory/fifo must never resolve")
        XCTAssertEqual(a.dangling.map { $0.name }, ["dir.pdf", "fifo.pdf", "link.pdf"])
        for d in a.dangling {
            XCTAssertTrue(d.provenance.hasSuffix("; active entry is not a regular file"), d.provenance)
        }
    }

    // MARK: - Fail-closed schema / integrity / version gates

    /// Handcrafted stand-in DB (right user_version, wrong shape) for schema-gate tests.
    private func makeBareDB(tables: [String], userVersion: Int = SchemaMigrator.schemaVersion) throws -> URL {
        let url = try trackedTempDir().appendingPathComponent("bare.db")
        do {
            let db = try SQLiteDatabase(path: url.path)
            try db.execute("PRAGMA journal_mode = DELETE")
            for t in tables { try db.execute(t) }
            try db.setUserVersion(userVersion)
        }
        return url
    }

    func testMissingTableFailsClosed() throws {
        let db = try makeBareDB(tables: ["CREATE TABLE transactions (id TEXT PRIMARY KEY, attachment_path TEXT)"])
        let report = try applyReport(staged: [], active: try makeActive(), dbURL: db)
        XCTAssertThrowsError(try audit(report, db)) { e in
            guard case AttachmentApplyError.preparedDatabaseSchemaUnsupported(let m) = e else { return XCTFail("got \(e)") }
            XCTAssertTrue(m.contains("business_documents"), m)
        }
    }

    func testMissingColumnFailsClosed() throws {
        let db = try makeBareDB(tables: ["CREATE TABLE transactions (id TEXT PRIMARY KEY)",
                                         "CREATE TABLE business_documents (id TEXT PRIMARY KEY, tax_invoice_attachment_path TEXT)"])
        let report = try applyReport(staged: [], active: try makeActive(), dbURL: db)
        XCTAssertThrowsError(try audit(report, db)) { e in
            guard case AttachmentApplyError.preparedDatabaseSchemaUnsupported(let m) = e else { return XCTFail("got \(e)") }
            XCTAssertTrue(m.contains("transactions.attachment_path"), m)
        }
    }

    func testWrongUserVersionFailsClosed() throws {
        for version in [SchemaMigrator.schemaVersion - 1, SchemaMigrator.schemaVersion + 1] {
            let db = try makePreparedDB()
            do {
                let w = try SQLiteDatabase(path: db.path)
                try w.execute("PRAGMA user_version = \(version)")
            }
            let report = try applyReport(staged: [], active: try makeActive(), dbURL: db)
            XCTAssertThrowsError(try audit(report, db), "user_version \(version)") { e in
                guard case AttachmentApplyError.preparedDatabaseSchemaUnsupported(let m) = e else { return XCTFail("got \(e)") }
                XCTAssertTrue(m.contains("user_version \(version)"), m)
            }
        }
    }

    func testCorruptDatabaseFailsClosed() throws {
        let db = try makePreparedDB(txnRefs: (0..<40).map { ref("f\($0).pdf") })
        // Smash the page headers of several interior pages: page 1 stays valid, so the
        // identity gate's header/journal probes pass, but quick_check (or the scan itself)
        // hits the mangled b-tree.
        let size = (try fm.attributesOfItem(atPath: db.path)[.size] as? NSNumber)?.int64Value ?? 0
        XCTAssertGreaterThan(size, 5 * 4096, "fixture too small to corrupt interior pages")
        let handle = try FileHandle(forWritingTo: db)
        for page in [2, 4, 6] where Int64((page + 1) * 4096) <= size {
            try handle.seek(toOffset: UInt64(page * 4096))
            try handle.write(contentsOf: Data(repeating: 0xFF, count: 64))
        }
        try handle.close()

        let report = try applyReport(staged: [], active: try makeActive(), dbURL: db)
        XCTAssertThrowsError(try audit(report, db)) { e in
            // Fail-closed either way: our quick_check gate, or SQLite's own corruption error.
            switch e {
            case AttachmentApplyError.preparedDatabaseCorrupt, is SQLiteError: break
            default: XCTFail("got \(e)")
            }
        }
    }

    // MARK: - Identity binding / change detection

    func testAuditAgainstDifferentDatabaseRejected() throws {
        let dbA = try makePreparedDB(txnRefs: [ref("a.pdf")])
        let dbB = try makePreparedDB(txnRefs: [ref("b.pdf")])
        let report = try applyReport(staged: [], active: try makeActive(), dbURL: dbA)
        XCTAssertThrowsError(try audit(report, dbB)) { e in
            guard case AttachmentApplyError.preparedDatabaseIdentityMismatch = e else { return XCTFail("got \(e)") }
        }
    }

    func testDatabaseChangedDuringAuditRejected() throws {
        let db = try makePreparedDB(txnRefs: [ref("a.pdf")])
        let report = try applyReport(staged: [("a.pdf", "A")], active: try makeActive(), dbURL: db)

        // Content mutated mid-audit → identity re-check fails.
        let mutate = AttachmentReferenceAuditor.AuditHooks(afterScan: {
            let h = try FileHandle(forWritingTo: db)
            try h.seekToEnd(); try h.write(contentsOf: Data([0x00])); try h.close()
        })
        XCTAssertThrowsError(try audit(report, db, hooks: mutate)) { e in
            guard case AttachmentApplyError.preparedDatabaseChangedDuringAudit = e else { return XCTFail("got \(e)") }
        }
    }

    func testSidecarAppearingDuringAuditRejected() throws {
        let db = try makePreparedDB(txnRefs: [ref("a.pdf")])
        let report = try applyReport(staged: [("a.pdf", "A")], active: try makeActive(), dbURL: db)
        let sidecar = AttachmentReferenceAuditor.AuditHooks(afterScan: {
            try Data("w".utf8).write(to: URL(fileURLWithPath: db.path + "-wal"))
        })
        XCTAssertThrowsError(try audit(report, db, hooks: sidecar)) { e in
            guard let pe = e as? PreparedDatabaseError, case .notQuiescent = pe else { return XCTFail("got \(e)") }
        }
    }

    // MARK: - audit → complete races (C3)

    /// Setup where the audit resolves TWO references: one file this import copied, one
    /// pre-existing active file that was NOT part of the import (only the audit knows it).
    private func resolvedPairFixture() throws -> (db: URL, active: URL, report: AttachmentApplyReport, audit: ReferenceAudit) {
        let db = try makePreparedDB(txnRefs: [ref("mine.pdf")], docRefs: [ref("pre.pdf")])
        let active = try makeActive([("pre.pdf", "PRE")])   // pre-existing, never staged
        let report = try applyReport(staged: [("mine.pdf", "M")], active: active, dbURL: db)
        let a = try audit(report, db)
        XCTAssertEqual(a.resolved.map { $0.name }, ["mine.pdf", "pre.pdf"])
        return (db, active, report, a)
    }

    private func assertCompleteFailsClosed(_ f: (db: URL, active: URL, report: AttachmentApplyReport, audit: ReferenceAudit),
                                           _ expected: (Error) -> Bool, _ label: String,
                                           file: StaticString = #filePath, line: UInt = #line) throws {
        let manifests = try makeManifestsDir()
        XCTAssertThrowsError(try AttachmentApply().complete(report: f.report, referenceAudit: f.audit, acknowledgement: nil,
                                                            preparedDatabaseAt: f.db, manifestsDir: manifests, hooks: ApplyHooks()),
                             label, file: file, line: line) { e in
            if !expected(e) { XCTFail("\(label): got \(e)", file: file, line: line) }
        }
        XCTAssertTrue(fm.fileExists(atPath: f.report.stagingDir.path), "\(label): staging must be kept", file: file, line: line)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: manifests.path), [], "\(label): no sentinel", file: file, line: line)
    }

    func testResolvedReferenceDeletedAfterAuditFailsComplete() throws {
        let f = try resolvedPairFixture()
        try fm.removeItem(at: f.active.appendingPathComponent("pre.pdf"))   // NOT part of this import's copy set
        try assertCompleteFailsClosed(f, {
            if case AttachmentApplyError.referencedFileChangedSinceAudit("pre.pdf") = $0 { return true }; return false
        }, "deleted after audit")
    }

    func testResolvedReferenceReplacedAfterAuditFailsComplete() throws {
        let f = try resolvedPairFixture()
        try Data("SWAPPED".utf8).write(to: f.active.appendingPathComponent("pre.pdf"))
        try assertCompleteFailsClosed(f, {
            if case AttachmentApplyError.referencedFileChangedSinceAudit("pre.pdf") = $0 { return true }; return false
        }, "replaced after audit")
    }

    /// Same bytes behind a symlink is still a fail: the entry must remain a REGULAR file.
    func testResolvedReferenceSwappedForSameContentSymlinkFailsComplete() throws {
        let f = try resolvedPairFixture()
        let target = f.active.appendingPathComponent("pre.pdf")
        let elsewhere = try trackedTempDir().appendingPathComponent("pre.pdf")
        try Data("PRE".utf8).write(to: elsewhere)                      // identical content
        try fm.removeItem(at: target)
        try fm.createSymbolicLink(at: target, withDestinationURL: elsewhere)
        try assertCompleteFailsClosed(f, {
            if case AttachmentApplyError.referencedFileChangedSinceAudit("pre.pdf") = $0 { return true }; return false
        }, "symlink swap after audit")
    }

    func testDatabaseMutatedAfterAuditFailsComplete() throws {
        let f = try resolvedPairFixture()
        do {   // a new referencing row appears after the audit → identity recompute rejects
            let w = try SQLiteDatabase(path: f.db.path)
            try insertRefs(w, txnRefs: [ref("late.pdf")], docRefs: [])
        }
        try assertCompleteFailsClosed(f, {
            if case AttachmentApplyError.preparedDatabaseIdentityMismatch = $0 { return true }; return false
        }, "DB mutated after audit")
    }

    func testCompleteAgainstDifferentDatabaseFailsClosed() throws {
        let f = try resolvedPairFixture()
        let other = try makePreparedDB()
        let manifests = try makeManifestsDir()
        XCTAssertThrowsError(try AttachmentApply().complete(report: f.report, referenceAudit: f.audit, acknowledgement: nil,
                                                            preparedDatabaseAt: other, manifestsDir: manifests, hooks: ApplyHooks())) { e in
            guard case AttachmentApplyError.preparedDatabaseIdentityMismatch = e else { return XCTFail("got \(e)") }
        }
    }

    func testSidecarAppearingBeforeCompleteFailsClosed() throws {
        let f = try resolvedPairFixture()
        try Data("j".utf8).write(to: URL(fileURLWithPath: f.db.path + "-journal"))
        try assertCompleteFailsClosed(f, {
            if let pe = $0 as? PreparedDatabaseError, case .notQuiescent = pe { return true }; return false
        }, "sidecar before complete")
    }

    // MARK: - Public URL-based API end-to-end (no @testable seams)

    func testPublicAPIEndToEnd() throws {
        let db = try makePreparedDB(txnRefs: [ref("a.pdf")])
        let active = try makeActive()
        let staging = try makeStaging(ingested: [("a.pdf", "A")])

        let report = try AttachmentApply().apply(stagingDir: staging, activeAttachmentsDir: active, preparedDatabaseAt: db)
        XCTAssertEqual(report.preparedDBIdentity, try PreparedDatabaseIdentity.compute(at: db),
                       "apply must stamp the identity it computed itself")
        let a = try AttachmentReferenceAuditor().audit(report: report, preparedDatabaseAt: db)
        XCTAssertEqual(a.resolved.map { $0.name }, ["a.pdf"])
        // The public complete writes to AppPaths' real manifests dir; use the internal
        // entry point ONLY to redirect the sentinel into a temp dir — the identity
        // recompute path is identical.
        let outcome = try AttachmentApply().complete(report: report, referenceAudit: a, acknowledgement: nil,
                                                     preparedDatabaseAt: db, manifestsDir: try makeManifestsDir(), hooks: ApplyHooks())
        guard case .completed = outcome else { return XCTFail("got \(outcome)") }
    }

    // MARK: - Determinism

    func testAuditDeterministicAcrossInsertOrder() throws {
        let refsA: [SQLiteValue] = [ref("x.pdf"), ref("gone.pdf"), .text("/abs.pdf")]
        let dbA = try makePreparedDB(txnRefs: refsA, docRefs: [ref("x.pdf")])
        let dbB = try makePreparedDB(txnRefs: refsA.reversed(), docRefs: [ref("x.pdf")])

        func run(_ db: URL) throws -> ReferenceAudit {
            let active = try makeActive([("x.pdf", "X")])
            let report = try applyReport(staged: [], active: active, dbURL: db)
            return try audit(report, db)
        }
        let a = try run(dbA), b = try run(dbB)
        XCTAssertEqual(a.resolved.map { "\($0.name)|\($0.provenance)" }, b.resolved.map { "\($0.name)|\($0.provenance)" })
        XCTAssertEqual(a.dangling, b.dangling)
        XCTAssertEqual(a.invalid, b.invalid)
    }
}
