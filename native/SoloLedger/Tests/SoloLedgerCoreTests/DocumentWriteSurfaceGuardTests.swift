import XCTest
@testable import SoloLedgerCore

/// D-2 — the two rules that have to hold as **properties of the source**, because a behavioural
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
///
/// Both are closed-set assertions over comment-stripped source, and both are self-validating: every
/// pattern is fired at a sample it must match and a sample it must not, and every "this appears
/// nowhere" claim is paired with a place it does appear. An empty walk fails before any of it runs.
final class DocumentWriteSurfaceGuardTests: XCTestCase {

    /// One scanned pattern, with the two samples that decide whether it is worth trusting.
    struct Probe {
        let label: String
        let pattern: String
        /// Every file that may contain it, and exactly how often. A file not listed must have none.
        let expected: [String: Int]
        let matches: String
        let doesNotMatch: String
    }

    // MARK: - The write surface

    /// Every statement in the shipped source that MODIFIES either document table.
    ///
    /// The reads are deliberately not here: `SELECT … FROM business_document_items` in
    /// `DocumentStore.swift` and `SELECT doc_number FROM business_documents` in
    /// `DocumentNumbering.swift` are not part of this claim, and each write pattern is checked
    /// against a read sample below so it cannot quietly be counting one.
    static let writeSurface: [Probe] = [
        Probe(label: "insert lines",
              pattern: #"INSERT\s+INTO\s+business_document_items"#,
              expected: ["DocumentStore.swift": 1],
              matches: "INSERT INTO business_document_items (doc_id) VALUES (?)",
              doesNotMatch: "SELECT id FROM business_document_items WHERE doc_id = ?"),
        Probe(label: "delete lines",
              pattern: #"DELETE\s+FROM\s+business_document_items"#,
              expected: ["DocumentStore.swift": 1],
              matches: "DELETE FROM business_document_items WHERE doc_id = ?",
              doesNotMatch: "SELECT id FROM business_document_items WHERE doc_id = ?"),
        Probe(label: "update lines",
              pattern: #"UPDATE\s+business_document_items"#,
              expected: [:],
              matches: "UPDATE business_document_items SET amount = 1",
              doesNotMatch: "SELECT amount FROM business_document_items"),
        Probe(label: "insert header",
              pattern: #"INSERT\s+INTO\s+business_documents"#,
              expected: ["DocumentStore.swift": 1],
              matches: "INSERT INTO business_documents (id) VALUES (?)",
              doesNotMatch: "SELECT id FROM business_documents"),
        Probe(label: "update header",
              pattern: #"UPDATE\s+business_documents"#,
              expected: ["DocumentStore.swift": 2],   // the edit, and the tax-invoice association
              matches: "UPDATE business_documents SET notes = ?",
              doesNotMatch: "SELECT notes FROM business_documents"),
        Probe(label: "delete header",
              pattern: #"DELETE\s+FROM\s+business_documents"#,
              expected: ["DocumentStore.swift": 1],
              matches: "DELETE FROM business_documents WHERE id = ?",
              doesNotMatch: "SELECT id FROM business_documents WHERE id = ?"),
    ]

    /// The numbering entry point and the namespace behind it. Listed with the places they DO
    /// appear, so "absent from `DocumentStore.swift`" is a measurement and not an empty pattern.
    static let numbering: [Probe] = [
        Probe(label: "nextBusinessDocumentNumber",
              pattern: #"nextBusinessDocumentNumber\("#,
              // two declarations plus the overload's own call, and one caller: Q2-d ①.
              expected: ["DocumentNumbering.swift": 3, "StatementGenerator.swift": 1],
              matches: "try store.nextBusinessDocumentNumber(for: .statement)",
              doesNotMatch: "let n = suggestedNumber(for: .statement)"),
        Probe(label: "DocumentNumbering namespace",
              pattern: #"DocumentNumbering\."#,
              expected: ["DocumentNumbering.swift": 5],
              matches: "DocumentNumbering.prefix(for: type)",
              doesNotMatch: "documentNumbering.prefix(for: type)"),
    ]

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
    func distribution(of pattern: String, in files: [(path: String, code: String)]) -> [String: Int] {
        var out: [String: Int] = [:]
        for file in files {
            let count = CapabilityImportGuardTests.matchCount(pattern, in: file.code)
            if count > 0 { out[file.path] = count }
        }
        return out
    }

    // MARK: - (0) the patterns are trusted only after they fire

    func testEveryProbeMatchesItsOwnSampleAndRefusesTheOther() {
        let probes = Self.writeSurface + Self.numbering
        XCTAssertEqual(probes.count, 8, "an empty probe list scans for nothing")
        for probe in probes {
            XCTAssertEqual(CapabilityImportGuardTests.matchCount(probe.pattern, in: probe.matches), 1,
                           "\(probe.label) does not match the statement it is supposed to find")
            XCTAssertEqual(CapabilityImportGuardTests.matchCount(probe.pattern, in: probe.doesNotMatch), 0,
                           "\(probe.label) fires on something it must ignore")
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
            #"INSERT\s+INTO\s+business_document_items"#, in: code), 0)
        let live = WindowReopenCommandGuardTests.strippingComments("""
            let sql = "INSERT INTO business_document_items (doc_id) VALUES (?)"
            """)
        XCTAssertEqual(CapabilityImportGuardTests.matchCount(
            #"INSERT\s+INTO\s+business_document_items"#, in: live), 1, "…while the real one survives")
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
}
