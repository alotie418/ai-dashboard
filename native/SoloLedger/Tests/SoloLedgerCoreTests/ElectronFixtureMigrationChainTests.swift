import XCTest
@testable import SoloLedgerCore

/// N7.0 release gate (design §9, decision 8): the REAL committed Electron `electron-v23.db`
/// fixture must survive the full `.userSelectedDataDir` production pipeline —
/// ingest → gate → prepare → activate → finalize (apply → audit → complete) — and then be
/// opened through the PRODUCTION hardened path (`confirmOpenAuthorization` →
/// `openActiveExistingHardened`), never the naive `LedgerStore.init`.
///
/// Scenarios pinned here:
///   1. full migration + freshly-completed open with exact ledger assertions;
///   2. completed-after-restart: a SECOND coordinator over the same disk config re-probes to
///      `.openExistingCompleted`, with the deep belt-and-suspenders assertion that
///      `confirmOpenAuthorization` itself returns `.proceed(.existing)`;
///   3. attachment variant, clean: `transactions.attachment_path` +
///      `business_documents.tax_invoice_attachment_path` both resolve, apply/audit/complete
///      run end-to-end, and every applied file is sha256-verified against the sentinel;
///   4. attachment variant, dangling: one reference with no staged file demands
///      `requiresAcknowledgement`, the acknowledged re-run converges, and the sentinel binds
///      `acknowledgedReportHash`;
///   5. attachment variant, completed-after-restart: applied attachments and DB references
///      survive a restart probe + hardened reopen.
///
/// FIXTURE DETERMINISM / AUDITABILITY: the attachment variant is DERIVED AT TEST TIME from
/// the committed real-Electron-engine fixture — two fixed-value `attachment_path` UPDATEs and
/// one fully explicit `business_documents` INSERT (explicit timestamps, validated by the real
/// v23 CHECK constraints), plus attachment files with fixed byte content declared below. No
/// generated binary is committed and the test run has NO Node/Electron dependency; every
/// derived value is visible in this file.
final class ElectronFixtureMigrationChainTests: LedgerTestCase {

    private let fm = FileManager.default

    // MARK: - Deterministic attachment-variant constants

    private static let receiptName = "receipt-a.pdf"
    private static let receiptRef = "attachments/docs/receipt-a.pdf"
    private static let receiptBytes = Data("SoloLedger N7.0 deterministic attachment A (transaction receipt)\n".utf8)

    private static let taxInvoiceName = "tax-invoice-b.pdf"
    private static let taxInvoiceRef = "attachments/docs/tax-invoice-b.pdf"
    private static let taxInvoiceBytes = Data("SoloLedger N7.0 deterministic attachment B (business document tax invoice)\n".utf8)

    private static let danglingName = "missing-note.pdf"
    private static let danglingRef = "attachments/docs/missing-note.pdf"

    // MARK: - Isolated chain harness (same seam pattern as MigrationCoordinatorTests)

    private struct Ctx {
        let config: MigrationCoordinator.Config
        let stagingRoot: URL
    }

    /// A SYMLINK-FREE temp dir (realpath-canonicalized). `FileManager.temporaryDirectory`
    /// lives under the `/var` → `/private/var` symlink, which whole-path NOFOLLOW hardened
    /// open would reject; production active-store paths are symlink-free.
    private func td() throws -> URL {
        let d = try trackedTempDir()
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(d.path, &buf) != nil else { return d }
        return URL(fileURLWithPath: String(cString: buf), isDirectory: true)
    }

    /// Only the ACTIVE SLOT lives under the canonical (symlink-free) root — that is the one
    /// path the hardened NOFOLLOW open walks. Every other root deliberately stays on the
    /// plain `/var/folders` spelling: giving the attachments dir a `/private/var` spelling
    /// makes `standardizedFileURL` strip the prefix for the (existing) root but not for a
    /// MISSING child, so the auditor's escape backstop classifies a dangling reference as
    /// invalid instead. So far this is reproduced ONLY under the `/var` ↔ `/private/var`
    /// dual-spelling temp environment and has not been reproduced on a standard Application
    /// Support path; both classifications stay fail-closed (each demands acknowledgement).
    /// Kept as an independent `AttachmentReferenceAuditor` path-identity hardening
    /// observation — deliberately NOT part of the N7.1 self-import guard, whose duty is
    /// different.
    private func makeCtx() throws -> Ctx {
        func dir(_ name: String) throws -> URL {
            let d = try trackedTempDir().appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
            return d
        }
        func canonicalDir(_ name: String) throws -> URL {
            let d = try td().appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
            return d
        }
        let config = MigrationCoordinator.Config(
            activeDestination: try canonicalDir("ActiveSlot").appendingPathComponent(AppPaths.databaseFileName),
            activeAttachmentsDir: try dir("active-docs"),
            manifestsDir: try dir("ImportManifests"),
            workingDirectory: try dir("Work"),
            preparedRoot: try dir("PreparedImports"))
        return Ctx(config: config, stagingRoot: try dir("Staging"))
    }

    /// Ingest through the REAL chain, then relocate the published staging into the test's
    /// isolated root (moving only the entry this call just created).
    private static func seamIngest(_ source: MigrationSource, _ importID: ImportID,
                                   into root: URL) throws -> IngestResult {
        let r = try StagingIngest().ingest(source, importID: importID, timestamp: "t")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dst = root.appendingPathComponent("import-\(importID.rawValue)", isDirectory: true)
        try FileManager.default.moveItem(at: r.stagingDir, to: dst)
        let docs = dst.appendingPathComponent("attachments", isDirectory: true)
                      .appendingPathComponent("docs", isDirectory: true)
        return IngestResult(importID: r.importID, stagingDir: dst,
                            stagedDatabaseURL: dst.appendingPathComponent(AppPaths.databaseFileName),
                            stagedWALURL: r.stagedWALURL.map { _ in URL(fileURLWithPath: dst.path + "/" + AppPaths.databaseFileName + "-wal") },
                            stagedAttachmentsDir: r.stagedAttachmentsDir.map { _ in docs },
                            manifest: r.manifest)
    }

    private func coord(_ ctx: Ctx) -> MigrationCoordinator {
        let root = ctx.stagingRoot
        return MigrationCoordinator(config: ctx.config, stagingRootOverride: root,
                                    ingestOverride: { source, id in
            try Self.seamIngest(source, id, into: root)
        })
    }

    // MARK: - Source-tree builders (real fixture, deterministic derivation)

    private enum Variant {
        case base                    // committed fixture as-is (all attachment refs NULL)
        case attachmentsClean        // txn + business-document refs, both files staged
        case attachmentsWithDangling // clean variant + one reference whose file is absent
    }

    private func makeElectronSource(_ variant: Variant) throws -> (dir: URL, source: MigrationSource) {
        let src = try td().appendingPathComponent("SoloLedger", isDirectory: true)
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        let dbURL = src.appendingPathComponent(AppPaths.databaseFileName)
        try fm.copyItem(at: try fixtureURL(), to: dbURL)

        if variant != .base {
            let docs = src.appendingPathComponent("attachments", isDirectory: true)
                          .appendingPathComponent("docs", isDirectory: true)
            try fm.createDirectory(at: docs, withIntermediateDirectories: true)
            try Self.receiptBytes.write(to: docs.appendingPathComponent(Self.receiptName))
            try Self.taxInvoiceBytes.write(to: docs.appendingPathComponent(Self.taxInvoiceName))

            let db = try SQLiteDatabase(path: dbURL.path, mode: .readWriteExisting)
            try db.run("UPDATE transactions SET attachment_path = ? WHERE id = 'txn-fixture-1'",
                       [.text(Self.receiptRef)])
            try db.run("""
                INSERT INTO business_documents
                  (id, doc_type, doc_number, status, doc_date, customer_name, acc_locale,
                   subtotal, tax_amount, total, tax_invoice_issued, tax_invoice_number,
                   tax_invoice_date, tax_invoice_attachment_path, created_at, updated_at)
                VALUES ('doc-fixture-1', 'commercial_invoice', 'CI-2026-001', 'issued',
                        '2026-02-01', '客户B', 'CN', 2358.96, 141.54, 2500.50, 1, 'TAX-001',
                        '2026-02-02', ?, '2026-02-01 00:00:00', '2026-02-01 00:00:00')
                """, [.text(Self.taxInvoiceRef)])
            if variant == .attachmentsWithDangling {
                try db.run("UPDATE transactions SET attachment_path = ? WHERE id = 'txn-fixture-5'",
                           [.text(Self.danglingRef)])
            }
            try db.close()
            // The fixture is journal_mode=DELETE; a clean close leaves no sidecars, which the
            // snapshot-identity and quiescence gates downstream depend on.
            XCTAssertFalse(fm.fileExists(atPath: dbURL.path + "-wal"))
            XCTAssertFalse(fm.fileExists(atPath: dbURL.path + "-journal"))
        }
        return (src, .userSelectedDataDir(src))
    }

    // MARK: - Shared open + assertion helpers

    private enum Fail: Error { case notCompleted, notProceedExisting }

    @discardableResult
    private func runImportToCompleted(_ ctx: Ctx, _ source: MigrationSource,
                                      file: StaticString = #filePath, line: UInt = #line) throws -> StoreOpenAuthorization {
        let outcome = coord(ctx).runImport(source: source)
        guard case .openStore(let auth, let residual) = outcome else {
            XCTFail("runImport must converge to openStore, got \(outcome)", file: file, line: line)
            throw Fail.notCompleted
        }
        guard case .openExistingCompleted = auth else {
            XCTFail("full chain must mint completed authorization, got \(auth)", file: file, line: line)
            throw Fail.notCompleted
        }
        XCTAssertNil(residual, file: file, line: line)
        return auth
    }

    /// PRODUCTION open discipline: confirm from disk, then the hardened NOFOLLOW open —
    /// never the naive `LedgerStore.init`.
    private func openHardened(_ ctx: Ctx, _ auth: StoreOpenAuthorization,
                              file: StaticString = #filePath, line: UInt = #line) throws -> LedgerStore {
        let precheck = coord(ctx).confirmOpenAuthorization(auth, autoSourceCandidate: nil)
        guard case .proceed(.existing(let evidence)) = precheck else {
            XCTFail("confirm must proceed with existing evidence, got \(precheck)", file: file, line: line)
            throw Fail.notProceedExisting
        }
        return try LedgerStore.openActiveExistingHardened(databaseURL: ctx.config.activeDestination,
                                                          expect: evidence)
    }

    /// The exact-value ledger battery from design §9: counts, sums, settings, categories,
    /// full enum coverage — strong assertions, not subset checks.
    private func assertFixtureLedger(_ store: LedgerStore,
                                     file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try store.schemaVersion(), SchemaMigrator.schemaVersion, file: file, line: line)

        let all = try store.listTransactions()
        XCTAssertEqual(all.count, 7, file: file, line: line)
        XCTAssertEqual(try store.listTransactions(type: .income).count, 4, file: file, line: line)
        XCTAssertEqual(try store.listTransactions(type: .expense).count, 3, file: file, line: line)

        let s = try store.summary()
        XCTAssertEqual(s.incomeTotal, 4600.75, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(s.expenseTotal, 1750.74, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(s.net, 2850.01, accuracy: 0.001, file: file, line: line)

        XCTAssertEqual(try store.db.query("SELECT COUNT(*) AS c FROM settings").first?.int("c"), 4,
                       file: file, line: line)
        XCTAssertEqual(try store.settings.string("accounting_locale"), "CN", file: file, line: line)
        XCTAssertEqual(try store.settings.string("currency"), "CNY", file: file, line: line)
        XCTAssertEqual(try store.settings.string("company_name"), "示例商贸有限公司", file: file, line: line)
        XCTAssertEqual(try store.settings.string("ui_language"), "zh-CN", file: file, line: line)

        XCTAssertEqual(try store.db.query("SELECT COUNT(*) AS c FROM categories").first?.int("c"), 78,
                       file: file, line: line)

        XCTAssertEqual(Set(all.map { $0.type }), [.income, .expense], file: file, line: line)
        XCTAssertEqual(Set(all.map { $0.paymentStatus }), [.paid, .partial, .unpaid], file: file, line: line)
        XCTAssertEqual(Set(all.map { $0.invoiceStatus }), [.issued, .pending, .na], file: file, line: line)
    }

    private func recordURL(_ ctx: Ctx) -> URL {
        ctx.config.activeDestination.deletingLastPathComponent()
            .appendingPathComponent(PreparedImportActivator.recordName)
    }

    private func readRecord(_ ctx: Ctx) throws -> ActivationRecord {
        try JSONDecoder().decode(ActivationRecord.self, from: Data(contentsOf: recordURL(ctx)))
    }

    private func sentinel(_ ctx: Ctx) throws -> ImportManifest {
        let record = try readRecord(ctx)
        let url = ctx.config.manifestsDir.appendingPathComponent("\(record.importID).json")
        return try JSONDecoder().decode(ImportManifest.self, from: Data(contentsOf: url))
    }

    private func activeDoc(_ ctx: Ctx, _ name: String) -> URL {
        ctx.config.activeAttachmentsDir.appendingPathComponent(name)
    }

    /// Applied file must be byte-identical to the declared source bytes AND hash-chained to
    /// the sentinel manifest entry (ingested outcome, matching sha256+size).
    private func assertAppliedAttachment(_ ctx: Ctx, name: String, bytes: Data,
                                         file: StaticString = #filePath, line: UInt = #line) throws {
        let url = activeDoc(ctx, name)
        XCTAssertEqual(try Data(contentsOf: url), bytes, file: file, line: line)
        let manifest = try sentinel(ctx)
        guard let entry = manifest.files.first(where: { $0.name == name }) else {
            return XCTFail("sentinel manifest missing entry for \(name)", file: file, line: line)
        }
        XCTAssertEqual(entry.outcome, .ingested, file: file, line: line)
        XCTAssertEqual(entry.sha256, try FileHash.sha256HexOfRegularFile(at: url), file: file, line: line)
        XCTAssertEqual(entry.size, Int64(bytes.count), file: file, line: line)
    }

    // MARK: - 1. Full migration + freshly-completed hardened open

    func testFullMigrationFreshlyCompletedHardenedOpenPreservesLedger() throws {
        let ctx = try makeCtx()
        let (_, source) = try makeElectronSource(.base)

        let auth = try runImportToCompleted(ctx, source)
        // finalize-before-open: the chain has fully finalized on the quiescent DB; only now open.
        let store = try openHardened(ctx, auth)
        try assertFixtureLedger(store)

        // The committed base fixture carries NO attachment references — the audit must have
        // seen none and the completion must be unacknowledged.
        let manifest = try sentinel(ctx)
        XCTAssertNil(manifest.acknowledgedReportHash)
        XCTAssertNil(try store.transaction(id: "txn-fixture-1")?.attachmentPath)
    }

    // MARK: - 2. Completed-after-restart probe (deep assertions)

    func testCompletedAfterRestartProbeConfirmsExistingAndReopens() throws {
        let ctx = try makeCtx()
        let (_, source) = try makeElectronSource(.base)
        _ = try runImportToCompleted(ctx, source)

        // "Restart": a SECOND coordinator over the same on-disk config re-derives everything
        // from disk (probe-first, no in-memory carry-over).
        let restarted = MigrationCoordinator(config: ctx.config,
                                             stagingRootOverride: ctx.stagingRoot,
                                             ingestOverride: nil)
        let outcome = restarted.bootResolve(autoSourceCandidate: nil)
        guard case .openStore(let auth, let residual) = outcome,
              case .openExistingCompleted(let evidence) = auth else {
            return XCTFail("restart boot must probe to openExistingCompleted, got \(outcome)")
        }
        XCTAssertNil(residual)
        XCTAssertEqual(evidence.record, try readRecord(ctx),
                       "completed evidence must carry the exact on-disk owner record")

        // Deep belt-and-suspenders: the completed-probe re-run inside confirm must itself
        // proceed with existing-open evidence (not merely rely on attemptOpen internals).
        let precheck = restarted.confirmOpenAuthorization(auth, autoSourceCandidate: nil)
        guard case .proceed(.existing(let openEvidence)) = precheck else {
            return XCTFail("confirm(completed) must return .proceed(.existing), got \(precheck)")
        }

        let store = try LedgerStore.openActiveExistingHardened(databaseURL: ctx.config.activeDestination,
                                                               expect: openEvidence)
        try assertFixtureLedger(store)

        // With the store open (live WAL), a further restart boot must STILL resolve via the
        // WAL-safe completion probe without touching the DB.
        guard case .openStore(let auth2, nil) = restarted.bootResolve(autoSourceCandidate: nil),
              case .openExistingCompleted = auth2 else {
            return XCTFail("WAL-live restart boot must stay probe-first completed")
        }
    }

    // MARK: - 3. Attachment variant, clean: apply → audit → complete + hash chain

    func testAttachmentVariantCleanChainAppliesAuditsAndHashVerifies() throws {
        let ctx = try makeCtx()
        let (_, source) = try makeElectronSource(.attachmentsClean)

        let auth = try runImportToCompleted(ctx, source)   // no acknowledgement demanded

        try assertAppliedAttachment(ctx, name: Self.receiptName, bytes: Self.receiptBytes)
        try assertAppliedAttachment(ctx, name: Self.taxInvoiceName, bytes: Self.taxInvoiceBytes)
        XCTAssertNil(try sentinel(ctx).acknowledgedReportHash,
                     "clean audit must complete without acknowledgement")

        let store = try openHardened(ctx, auth)
        try assertFixtureLedger(store)

        // Both audited reference columns survived the schema migration verbatim.
        XCTAssertEqual(try store.transaction(id: "txn-fixture-1")?.attachmentPath, Self.receiptRef)
        let docs = try store.db.query(
            "SELECT id, doc_type, doc_number, tax_invoice_attachment_path FROM business_documents")
        XCTAssertEqual(docs.count, 1)
        XCTAssertEqual(docs.first?.string("id"), "doc-fixture-1")
        XCTAssertEqual(docs.first?.string("doc_type"), "commercial_invoice")
        XCTAssertEqual(docs.first?.string("doc_number"), "CI-2026-001")
        XCTAssertEqual(docs.first?.string("tax_invoice_attachment_path"), Self.taxInvoiceRef)
    }

    // MARK: - 4. Attachment variant, dangling: requiresAcknowledgement → acknowledge → complete

    func testAttachmentVariantDanglingRefDemandsAcknowledgementThenCompletes() throws {
        let ctx = try makeCtx()
        let (_, source) = try makeElectronSource(.attachmentsWithDangling)

        let first = coord(ctx).runImport(source: source)
        guard case .requiresAcknowledgement(let request, let unresolved) = first else {
            return XCTFail("dangling DB reference must demand acknowledgement, got \(first)")
        }
        XCTAssertEqual(unresolved.items.count, 1)
        XCTAssertEqual(unresolved.items.first?.kind, .danglingReference)
        XCTAssertEqual(unresolved.items.first?.name, Self.danglingName)

        // Blocked completion persists NO sentinel (activation record may already exist).
        let record = try readRecord(ctx)
        XCTAssertFalse(fm.fileExists(
            atPath: ctx.config.manifestsDir.appendingPathComponent("\(record.importID).json").path))

        // Acknowledged resume converges — same production resume entry the App uses.
        let resumed = coord(ctx).bootResolve(autoSourceCandidate: nil,
                                             acknowledgement: request.acknowledge())
        guard case .openStore(let auth, nil) = resumed,
              case .openExistingCompleted = auth else {
            return XCTFail("acknowledged re-run must converge to completed, got \(resumed)")
        }

        let manifest = try sentinel(ctx)
        XCTAssertEqual(manifest.acknowledgedReportHash, request.unresolvedReportHash,
                       "sentinel must bind the acknowledged report hash")
        try assertAppliedAttachment(ctx, name: Self.receiptName, bytes: Self.receiptBytes)
        try assertAppliedAttachment(ctx, name: Self.taxInvoiceName, bytes: Self.taxInvoiceBytes)
        XCTAssertFalse(fm.fileExists(atPath: activeDoc(ctx, Self.danglingName).path),
                       "no file may be fabricated for a dangling reference")

        let store = try openHardened(ctx, auth)
        try assertFixtureLedger(store)
        // Acknowledgement preserves the ledger row verbatim — the dangling reference is
        // recorded, not scrubbed.
        XCTAssertEqual(try store.transaction(id: "txn-fixture-5")?.attachmentPath, Self.danglingRef)
        XCTAssertEqual(try store.transaction(id: "txn-fixture-1")?.attachmentPath, Self.receiptRef)
    }

    // MARK: - 5. Attachment variant, completed-after-restart

    func testAttachmentVariantCompletedAfterRestartKeepsAppliedAttachments() throws {
        let ctx = try makeCtx()
        let (_, source) = try makeElectronSource(.attachmentsWithDangling)

        guard case .requiresAcknowledgement(let request, _) = coord(ctx).runImport(source: source) else {
            return XCTFail("dangling DB reference must demand acknowledgement")
        }
        guard case .openStore = coord(ctx).bootResolve(autoSourceCandidate: nil,
                                                       acknowledgement: request.acknowledge()) else {
            return XCTFail("acknowledged re-run must converge")
        }

        let restarted = MigrationCoordinator(config: ctx.config,
                                             stagingRootOverride: ctx.stagingRoot,
                                             ingestOverride: nil)
        let outcome = restarted.bootResolve(autoSourceCandidate: nil)
        guard case .openStore(let auth, nil) = outcome,
              case .openExistingCompleted = auth else {
            return XCTFail("restart boot must probe to completed, got \(outcome)")
        }
        guard case .proceed(.existing(let evidence)) =
                restarted.confirmOpenAuthorization(auth, autoSourceCandidate: nil) else {
            return XCTFail("confirm(completed) must return .proceed(.existing)")
        }

        try assertAppliedAttachment(ctx, name: Self.receiptName, bytes: Self.receiptBytes)
        try assertAppliedAttachment(ctx, name: Self.taxInvoiceName, bytes: Self.taxInvoiceBytes)

        let store = try LedgerStore.openActiveExistingHardened(databaseURL: ctx.config.activeDestination,
                                                               expect: evidence)
        try assertFixtureLedger(store)
        XCTAssertEqual(try store.transaction(id: "txn-fixture-1")?.attachmentPath, Self.receiptRef)
        XCTAssertEqual(try store.transaction(id: "txn-fixture-5")?.attachmentPath, Self.danglingRef)
        XCTAssertEqual(
            try store.db.query("SELECT tax_invoice_attachment_path AS p FROM business_documents").first?.string("p"),
            Self.taxInvoiceRef)
    }
}
