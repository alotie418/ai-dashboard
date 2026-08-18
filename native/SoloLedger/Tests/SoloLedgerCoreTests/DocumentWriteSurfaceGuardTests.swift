import XCTest
@testable import SoloLedgerCore

/// D-2 — the three rules that have to hold as **properties of the source**, because a behavioural
/// test can only ever check the paths somebody thought to call.
///
///  1. **A8's design constraint.** `docs/BUSINESS_DOCUMENTS_SPEC.md` §3 registers that Electron's
///     `update` recomputes the header totals only when the request carried `items`, and then binds
///     the native side with: 原生 API 不得开放 A8 的「改了明细却不传 items」路径. `DocumentLifecycleTests`
///     measures that the totals describe the lines after every write this API offers; what it
///     cannot measure is whether some OTHER writer exists. This file counts them.
///  2. **A tax-invoice number is never generated.** §4 · 2–3 and `documents.js:1-3`: the app records
///     an invoice somebody else issued and has no issuing function. The behavioural half is in
///     `DocumentLifecycleTests`; the half that says "and there is no code path that could" is here,
///     as the numbering symbols being absent from the file that holds the association's writer.
///  3. **The numbering calendar is named, not inherited.** `Calendar.current` follows the user's
///     region and answers a Reiwa year on a Japanese-calendar Mac. No in-process test can tell
///     `.gregorian` from `Calendar.current` on a machine that already uses the Gregorian calendar,
///     so this one is checkable only as source.
///
/// All three are closed-set assertions over comment-stripped source, and all three are
/// self-validating: every pattern is fired at samples it must match and samples it must not, and
/// every "this appears nowhere" claim is paired with a place it does appear. An empty walk fails
/// before any of it runs.
///
/// ## What this file does NOT cover
///
/// The write probes match a **literal table name**. A write whose table name arrives through string
/// interpolation is invisible to them, and the package ships exactly one such writer —
/// `LedgerStore.insertRawRow(into:_:)`, used by undo/restore. That is not closed by a table-name
/// grep and is not pretended to be: instead ``testTheOnlyWriteWithAnInterpolatedTableNameIsTheRestorePath``
/// pins the closed set of interpolated writes at one, so a SECOND one — the shape a
/// documents-undo would take — has to come through this list and be looked at by a person. Treat
/// that assertion as a review trigger, not as proof that no such write can reach these tables.
final class DocumentWriteSurfaceGuardTests: XCTestCase {

    /// One scanned pattern, with the samples that decide whether it is worth trusting.
    struct Probe {
        let label: String
        let pattern: String
        /// Every file that may contain it, and exactly how often. A file not listed must have none.
        let expected: [String: Int]
        /// Spellings the probe MUST find — one match each. More than one because SQLite spells the
        /// same write several ways and a probe that knows only the house style is a probe a
        /// regression walks past.
        let matches: [String]
        /// Spellings it must ignore — reads, and the neighbouring table.
        let doesNotMatch: [String]
    }

    // MARK: - The write surface

    /// Every statement in the shipped source that MODIFIES either document table.
    ///
    /// Reads are deliberately not here (`SELECT … FROM business_document_items` in
    /// `DocumentStore.swift`, `SELECT doc_number FROM business_documents` in
    /// `DocumentNumbering.swift`), and each probe is fired at a read sample so it cannot quietly be
    /// counting one.
    ///
    /// The patterns are case-INSENSITIVE and know the conflict clauses, because
    /// `INSERT OR REPLACE INTO` is this package's own idiom for an idempotent write
    /// (`SchemaMigrator`, `CategorySeed`) and a second writer using it would otherwise be invisible.
    static let writeSurface: [Probe] = [
        Probe(label: "insert lines",
              pattern: #"(?i)(?:INSERT(?:\s+OR\s+[A-Z]+)?|REPLACE)\s+INTO\s+business_document_items\b"#,
              expected: ["DocumentStore.swift": 1],
              matches: ["INSERT INTO business_document_items (doc_id) VALUES (?)",
                        "INSERT OR REPLACE INTO business_document_items (doc_id) VALUES (?)",
                        "INSERT OR IGNORE INTO business_document_items (doc_id) VALUES (?)",
                        "REPLACE INTO business_document_items (doc_id) VALUES (?)",
                        "insert into business_document_items (doc_id) values (?)"],
              doesNotMatch: ["SELECT id FROM business_document_items WHERE doc_id = ?",
                             "INSERT INTO business_document_items_backup (doc_id) VALUES (?)",
                             "INSERT INTO business_documents (id) VALUES (?)"]),
        Probe(label: "delete lines",
              pattern: #"(?i)DELETE\s+FROM\s+business_document_items\b"#,
              expected: ["DocumentStore.swift": 1],
              matches: ["DELETE FROM business_document_items WHERE doc_id = ?",
                        "delete from business_document_items where doc_id = ?"],
              doesNotMatch: ["SELECT id FROM business_document_items WHERE doc_id = ?",
                             "DELETE FROM business_documents WHERE id = ?"]),
        Probe(label: "update lines",
              pattern: #"(?i)UPDATE(?:\s+OR\s+[A-Z]+)?\s+business_document_items\b"#,
              expected: [:],
              matches: ["UPDATE business_document_items SET amount = 1",
                        "UPDATE OR REPLACE business_document_items SET amount = 1",
                        "update business_document_items set amount = 1"],
              doesNotMatch: ["SELECT amount FROM business_document_items",
                             "UPDATE business_documents SET notes = ?"]),
        Probe(label: "insert header",
              pattern: #"(?i)(?:INSERT(?:\s+OR\s+[A-Z]+)?|REPLACE)\s+INTO\s+business_documents\b"#,
              expected: ["DocumentStore.swift": 1],
              matches: ["INSERT INTO business_documents (id) VALUES (?)",
                        "INSERT OR REPLACE INTO business_documents (id) VALUES (?)",
                        "REPLACE INTO business_documents (id) VALUES (?)",
                        "insert into business_documents (id) values (?)"],
              doesNotMatch: ["SELECT id FROM business_documents",
                             "INSERT INTO business_document_items (doc_id) VALUES (?)"]),
        Probe(label: "update header",
              pattern: #"(?i)UPDATE(?:\s+OR\s+[A-Z]+)?\s+business_documents\b"#,
              expected: ["DocumentStore.swift": 2],   // the edit, and the tax-invoice association
              matches: ["UPDATE business_documents SET notes = ?",
                        "UPDATE OR ROLLBACK business_documents SET notes = ?",
                        "update business_documents set notes = ?"],
              doesNotMatch: ["SELECT notes FROM business_documents",
                             "UPDATE business_document_items SET amount = 1"]),
        Probe(label: "delete header",
              pattern: #"(?i)DELETE\s+FROM\s+business_documents\b"#,
              expected: ["DocumentStore.swift": 1],
              matches: ["DELETE FROM business_documents WHERE id = ?",
                        "delete from business_documents where id = ?"],
              doesNotMatch: ["SELECT id FROM business_documents WHERE id = ?",
                             "DELETE FROM business_document_items WHERE doc_id = ?"]),
    ]

    /// The numbering entry point and the namespace behind it. Listed with the places they DO
    /// appear, so "absent from `DocumentStore.swift`" is a measurement and not an empty pattern.
    static let numbering: [Probe] = [
        Probe(label: "nextBusinessDocumentNumber",
              pattern: #"nextBusinessDocumentNumber\("#,
              // two declarations plus the overload's own call, and one caller: Q2-d ①.
              expected: ["DocumentNumbering.swift": 3, "StatementGenerator.swift": 1],
              matches: ["try store.nextBusinessDocumentNumber(for: .statement)"],
              doesNotMatch: ["let n = suggestedNumber(for: .statement)"]),
        Probe(label: "DocumentNumbering namespace",
              pattern: #"DocumentNumbering\."#,
              expected: ["DocumentNumbering.swift": 5],
              matches: ["DocumentNumbering.prefix(for: type)"],
              doesNotMatch: ["documentNumbering.prefix(for: type)"]),
    ]

    /// The only write in the package whose table name is interpolated rather than written out.
    /// See this type's own note on what the table-name probes cannot see.
    static let interpolatedWrite = Probe(
        label: "write with an interpolated table name",
        pattern: #"(?i)(?:INSERT(?:\s+OR\s+[A-Z]+)?\s+INTO|REPLACE\s+INTO|DELETE\s+FROM|UPDATE)\s+\\\("#,
        expected: ["LedgerStore.swift": 1],   // `insertRawRow(into:_:)`, the undo/restore path
        matches: [#"INSERT INTO \(table) (\(cols)) VALUES (\(marks))"#,
                  #"DELETE FROM \(table) WHERE id = ?"#],
        doesNotMatch: ["INSERT INTO business_documents (id) VALUES (?)",
                       #"SELECT * FROM \(table)"#])

    // MARK: - Reading

    /// Every `.swift` in both shipped packages, comment-stripped — the App target included, because
    /// a raw write added there would be just as much a second writer as one in Core.
    static func shippedSources() throws -> [(path: String, code: String)] {
        try ["SoloLedgerCore", "SoloLedger"]
            .flatMap { try CapabilityImportGuardTests.strippedSources(of: $0) }
    }

    func requireShippedSources(file: StaticString = #filePath, line: UInt = #line
    ) throws -> [(path: String, code: String)] {
        let files = try Self.shippedSources()
        XCTAssertGreaterThanOrEqual(files.count, 100, """
            walked \(files.count) .swift files, expected at least 100. Every closed set below is \
            satisfied trivially by an empty corpus, so this stops here.
            """, file: file, line: line)
        return files
    }

    /// `file basename → occurrences`, omitting the files with none.
    ///
    /// **Accumulates.** `strippedSources` keys files by basename, and the two packages can hold two
    /// files with the same one; assigning rather than adding would let the second silently replace
    /// the first's count — a second `DocumentStore.swift` elsewhere in the tree would then be
    /// invisible to every closed set below.
    func distribution(of pattern: String, in files: [(path: String, code: String)]) -> [String: Int] {
        var out: [String: Int] = [:]
        for file in files {
            let count = CapabilityImportGuardTests.matchCount(pattern, in: file.code)
            if count > 0 { out[file.path, default: 0] += count }
        }
        return out
    }

    // MARK: - (0) the patterns are trusted only after they fire

    func testEveryProbeMatchesItsOwnSamplesAndRefusesTheOthers() {
        let probes = Self.writeSurface + Self.numbering + [Self.interpolatedWrite]
        XCTAssertEqual(probes.count, 9, "an empty probe list scans for nothing")
        XCTAssertEqual(probes.reduce(0) { $0 + $1.matches.count }, 23,
                       "the spellings this file claims to know; adding one means adding its sample")
        for probe in probes {
            XCTAssertFalse(probe.matches.isEmpty, "\(probe.label) has no positive sample")
            for sample in probe.matches {
                XCTAssertEqual(CapabilityImportGuardTests.matchCount(probe.pattern, in: sample), 1,
                               "\(probe.label) does not find \(sample.debugDescription)")
            }
            for sample in probe.doesNotMatch {
                XCTAssertEqual(CapabilityImportGuardTests.matchCount(probe.pattern, in: sample), 0,
                               "\(probe.label) fires on \(sample.debugDescription)")
            }
        }
    }

    /// The stripper is what makes an absence claim mean anything: this file's own neighbours discuss
    /// the statements being counted, and a raw-text scan would find them in the prose.
    func testACommentedOutWriteIsNotCounted() {
        let code = WindowReopenCommandGuardTests.strippingComments("""
            // INSERT INTO business_document_items would be a second writer
            let sql = "SELECT 1"
            """)
        XCTAssertEqual(CapabilityImportGuardTests.matchCount(
            #"(?i)(?:INSERT(?:\s+OR\s+[A-Z]+)?|REPLACE)\s+INTO\s+business_document_items\b"#, in: code), 0)
        let live = WindowReopenCommandGuardTests.strippingComments("""
            let sql = "INSERT INTO business_document_items (doc_id) VALUES (?)"
            """)
        XCTAssertEqual(CapabilityImportGuardTests.matchCount(
            #"(?i)(?:INSERT(?:\s+OR\s+[A-Z]+)?|REPLACE)\s+INTO\s+business_document_items\b"#, in: live), 1,
            "…while the real one survives")
    }

    /// `distribution` adds rather than assigns, so two files sharing a basename cannot hide one
    /// another's writes.
    func testTheDistributionCounterAccumulatesAcrossFilesOfTheSameName() {
        let twins = [(path: "DocumentStore.swift", code: "INSERT INTO business_documents (id)"),
                     (path: "DocumentStore.swift", code: "INSERT INTO business_documents (id)")]
        XCTAssertEqual(distribution(of: #"(?i)INSERT\s+INTO\s+business_documents\b"#, in: twins),
                       ["DocumentStore.swift": 2], "assignment would have answered 1")
    }

    // MARK: - (1) A8 · the writers are the two that compute the totals

    func testEveryWriteToEitherDocumentTableIsInTheOneFileThatComputesTheTotals() throws {
        let files = try requireShippedSources()
        for probe in Self.writeSurface {
            XCTAssertEqual(distribution(of: probe.pattern, in: files), probe.expected, """
                \(probe.label): the set of places that write these tables changed. A new writer has \
                to compute `subtotal`/`tax_amount`/`total` from the lines it is writing, in the same \
                transaction — that is the A8 design constraint — and then be listed here.
                """)
        }
    }

    /// The line inserter is one function with exactly two callers. Anything else calling it, or a
    /// third path spelling the `INSERT` out again, changes one of these two numbers.
    func testTheLineInserterIsDeclaredOnceAndCalledExactlyTwice() throws {
        let files = try requireShippedSources()
        let declarations = distribution(of: #"func\s+insertDocumentLines\("#, in: files)
        let mentions = distribution(of: #"insertDocumentLines\("#, in: files)
        XCTAssertEqual(declarations, ["DocumentStore.swift": 1])
        XCTAssertEqual(mentions, ["DocumentStore.swift": 3], "one declaration + two call sites")

        // …and the two callers are the two writers, each of which sets the three totals. Counted
        // rather than read: `create` writes them as INSERT columns, `update` as SET assignments.
        let store = try XCTUnwrap(files.first { $0.path == "DocumentStore.swift" })
        XCTAssertEqual(CapabilityImportGuardTests.matchCount(#"set\("subtotal""#, in: store.code), 1)
        XCTAssertEqual(CapabilityImportGuardTests.matchCount(#"set\("tax_amount""#, in: store.code), 1)
        XCTAssertEqual(CapabilityImportGuardTests.matchCount(#"set\("total""#, in: store.code), 1)
        // Each of the three totals is bound from the freshly computed `totals` value TWICE — once
        // per writer. That is the constraint stated as a count: a writer that bound a stored total,
        // or none at all, would not be one of these two.
        // (A column-list pattern such as `subtotal, tax_amount, total` would not discriminate: the
        // SELECT list spells it exactly the same way.)
        for field in ["subtotal", "taxAmount", "total"] {
            XCTAssertEqual(CapabilityImportGuardTests.matchCount(#"\.real\(totals\.\#(field)\)"#,
                                                                 in: store.code), 2,
                           "\(field) is bound once by `create` and once by `update`")
        }
    }

    /// The one write in the package whose table name is interpolated. It is the undo/restore path
    /// and it is not aimed at these tables today; a second one is the shape a documents-undo would
    /// take, and it must be looked at rather than counted.
    func testTheOnlyWriteWithAnInterpolatedTableNameIsTheRestorePath() throws {
        let files = try requireShippedSources()
        XCTAssertEqual(distribution(of: Self.interpolatedWrite.pattern, in: files),
                       Self.interpolatedWrite.expected, """
                       A write whose table name is interpolated is invisible to every table-name \
                       probe in this file. There is one, `LedgerStore.insertRawRow(into:_:)`. If \
                       this count moved, decide by hand whether the new one can reach \
                       business_documents / business_document_items — the other assertions here \
                       cannot answer that for you.
                       """)
    }

    // MARK: - (2) the association cannot reach the number generator

    /// The tax-invoice writer and the number generator live in different files, and the file that
    /// holds the writer never names the generator. That is what makes "the number is never
    /// generated" checkable rather than promised.
    func testTheNumberGeneratorIsNotReachableFromTheAssociationsFile() throws {
        let files = try requireShippedSources()

        // Where the association's writer is — if this ever moves, the absence claim below is about
        // the wrong file and this assertion says so.
        XCTAssertEqual(distribution(of: #"func\s+updateTaxInvoice\("#, in: files),
                       ["DocumentStore.swift": 1])
        XCTAssertEqual(distribution(of: #"set\("tax_invoice_number""#, in: files),
                       ["DocumentStore.swift": 1], "one place writes that column")

        for probe in Self.numbering {
            let found = distribution(of: probe.pattern, in: files)
            XCTAssertEqual(found, probe.expected, """
                \(probe.label): the numbering symbol's call sites changed. If a new one is \
                legitimate, add it here — but not in DocumentStore.swift, which is where the \
                tax-invoice association is written.
                """)
            XCTAssertNil(found["DocumentStore.swift"], """
                \(probe.label) appeared in the file that writes tax_invoice_number. The formal \
                invoice number is typed in by a human and is never generated (spec §4 · 2–3).
                """)
            XCTAssertFalse(found.isEmpty, "…and the pattern does find the real declarations")
        }
    }

    // MARK: - (3) the numbering calendar is named

    /// `DocumentNumbering` names the Gregorian calendar and never asks for the user's.
    ///
    /// This is a source assertion because it cannot be a behavioural one: on a machine whose region
    /// already uses the Gregorian calendar — every machine this suite runs on — `Calendar.current`
    /// and `Calendar(identifier: .gregorian)` return the same year for every instant, so no test
    /// can tell them apart. On a Japanese-calendar Mac they differ by about two thousand, and the
    /// suggestion becomes `QT-8-0001`.
    ///
    /// Scoped to the one file, deliberately: pinning `Calendar.current` across the package would
    /// make this test the gatekeeper for code that has nothing to do with document numbering.
    func testTheNumberingCalendarIsNamedRatherThanInherited() throws {
        let files = try requireShippedSources()
        let numbering = try XCTUnwrap(files.first { $0.path == "DocumentNumbering.swift" },
                                      "the file this assertion is about was not walked")
        XCTAssertEqual(CapabilityImportGuardTests.matchCount(#"Calendar\(identifier:\s*\.gregorian\)"#,
                                                             in: numbering.code), 1,
                       "the calendar must be named in the numbering file")
        XCTAssertEqual(CapabilityImportGuardTests.matchCount(#"Calendar\.current"#,
                                                             in: numbering.code), 0, """
            DocumentNumbering asked for the user's calendar. `getFullYear()` is Gregorian whatever \
            the region is set to, and a Japanese-calendar Mac would suggest QT-8-0001.
            """)
        // Both patterns proved on samples, so the 1 and the 0 above are measurements.
        XCTAssertEqual(CapabilityImportGuardTests.matchCount(
            #"Calendar\(identifier:\s*\.gregorian\)"#, in: "var c = Calendar(identifier: .gregorian)"), 1)
        XCTAssertEqual(CapabilityImportGuardTests.matchCount(
            #"Calendar\.current"#, in: "var c = Calendar.current"), 1)
        XCTAssertEqual(CapabilityImportGuardTests.matchCount(
            #"Calendar\.current"#, in: "var c = Calendar(identifier: .japanese)"), 0)
    }
}
