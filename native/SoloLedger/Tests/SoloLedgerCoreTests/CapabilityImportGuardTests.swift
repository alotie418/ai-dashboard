import XCTest

/// The native app's absent capabilities — no networking, no OCR, no on-device ML, no StoreKit —
/// pinned by scanning its own source instead of by a sentence in a document.
///
/// ## What this guard proves, and what it does NOT
///
/// This is deliberately the SECOND half of a two-part claim, and the two halves prove different
/// things. `EntitlementsClosedSetGuardTests` pins the entitlements as a closed set; the thing
/// that set anchors is **"no network"** — under the App Sandbox an outbound connection requires
/// `com.apple.security.network.client`, so without that key the code cannot reach the network
/// however it is written. That is an enforcement boundary, and it is the strong half.
///
/// It anchors nothing else. Local model inference, on-device Vision, and StoreKit all run with
/// no extra entitlement at all — 2c-7 corrected an earlier over-claim that read the closed set
/// as evidence for those too, and `SWIFTUI_FEATURE_GAP.md` §5 records the correction along with
/// "the oracle for those is the source itself, and nothing in the repository pins it". **This
/// file is that missing pin**, and its claim is correspondingly narrower:
///
/// > the shipped source contains no CALL to these capabilities.
///
/// That is a source-level fact, not an enforcement boundary. It cannot stop a future edit from
/// adding one — it can only make the edit arrive red instead of silent. Do not read it as
/// "the app cannot do these things"; for the network half, that stronger statement belongs to
/// the entitlements guard, and only to it.
///
/// ## Two scans, because an import list is not enough
///
/// `import` alone would be a weak pin: `Foundation` already carries `URLSession`, so a network
/// call needs no new import at all. Hence (a) the import closure is pinned per package, and
/// (b) the capability symbols are scanned for directly.
///
/// ## Every pattern proves it can fire before it is trusted
///
/// A scan that matches nothing is indistinguishable from a scan whose pattern is wrong, and
/// this repository has been bitten by exactly that: `packaging-2c-survey-findings` records a
/// `grep 'ARCHS'` that could never have matched `ONLY_ACTIVE_ARCH`, read as "the key is absent".
/// The same shape recurred twice more in the balance-overview survey, where a
/// `FROM <literal table>` pattern could not see `FROM \(table)` and produced a false
/// "zero reads". So every entry here carries a `positive` sample, and
/// ``testEveryPatternMatchesItsOwnPositiveSample`` runs first: a pattern that cannot match its
/// own known-bad example is a broken pattern, and the zero it reports means nothing.
final class CapabilityImportGuardTests: XCTestCase {

    // MARK: - The pinned import closures

    /// Measured, then pinned. `SoloLedgerCore` is the data/report layer: no UI framework, and
    /// nothing that reaches outside the process except SQLite.
    static let coreImports: Set<String> = ["CSQLite", "CryptoKit", "Foundation"]

    /// The App layer adds exactly the UI stack it needs.
    static let appImports: Set<String> = [
        "AppKit", "Charts", "Foundation", "OSLog", "SoloLedgerCore", "SwiftUI",
        "UniformTypeIdentifiers",
    ]

    /// A capability the native app does not have, the pattern that finds it, and a sample the
    /// pattern MUST match. The sample is the pattern's own test — see the type doc.
    struct Forbidden {
        let label: String
        let pattern: String
        let positive: String
    }

    /// Deliberately NOT on this list: a bare `Transaction`. StoreKit 2 spells its purchase
    /// record `Transaction`, and so does this app's own core model (`Models/Transaction.swift`,
    /// 200+ uses). A pattern for the StoreKit one would match the ledger one on every line and
    /// the guard would be red from birth — the reason it is absent is collision, not oversight,
    /// so `SKPaymentQueue` / `SKProduct` / `StoreKit` carry that family instead.
    static let forbidden: [Forbidden] = [
        // — Reaching the network. `URLSession` lives in Foundation, which every file imports;
        //   this is precisely why the import closure alone would not be a pin.
        .init(label: "URLSession", pattern: #"\bURLSession\b"#,
              positive: "let task = URLSession.shared.dataTask(with: url)"),
        .init(label: "URLRequest", pattern: #"\bURLRequest\b"#,
              positive: "var req = URLRequest(url: url)"),
        .init(label: "NSURLConnection", pattern: #"\bNSURLConnection\b"#,
              positive: "NSURLConnection.sendSynchronousRequest(req, returning: nil)"),
        .init(label: "NWConnection", pattern: #"\bNWConnection\b"#,
              positive: "let c = NWConnection(host: h, port: p, using: .tcp)"),
        .init(label: "NWListener", pattern: #"\bNWListener\b"#,
              positive: "let l = try NWListener(using: .tcp)"),
        .init(label: "NWBrowser", pattern: #"\bNWBrowser\b"#,
              positive: "let b = NWBrowser(for: .bonjour(type: t, domain: nil), using: .tcp)"),
        .init(label: "NWPathMonitor", pattern: #"\bNWPathMonitor\b"#,
              positive: "let m = NWPathMonitor()"),
        .init(label: "WKWebView", pattern: #"\bWKWebView\b"#,
              positive: "let web = WKWebView(frame: .zero)"),
        .init(label: "CFSocket", pattern: #"\bCFSocket"#,
              positive: "let s = CFSocketCreate(nil, 0, 0, 0, 0, nil, nil)"),
        .init(label: "getaddrinfo", pattern: #"\bgetaddrinfo\b"#,
              positive: "getaddrinfo(host, service, &hints, &result)"),
        // — On-device text recognition (OCR).
        .init(label: "VN*Request", pattern: #"\bVN[A-Z]\w*Request\b"#,
              positive: "let r = VNRecognizeTextRequest { _, _ in }"),
        .init(label: "VNImageRequestHandler", pattern: #"\bVNImageRequestHandler\b"#,
              positive: "let h = VNImageRequestHandler(cgImage: img)"),
        // — On-device ML.
        .init(label: "MLModel", pattern: #"\bMLModel\b"#,
              positive: "let model = try MLModel(contentsOf: url)"),
        .init(label: "MLPredictionOptions", pattern: #"\bMLPredictionOptions\b"#,
              positive: "let opts = MLPredictionOptions()"),
        // — In-app purchase.
        .init(label: "SKPaymentQueue", pattern: #"\bSKPaymentQueue\b"#,
              positive: "SKPaymentQueue.default().add(observer)"),
        .init(label: "SKProduct", pattern: #"\bSKProduct\b"#,
              positive: "func price(of p: SKProduct) -> Decimal { p.price as Decimal }"),
        .init(label: "StoreKit", pattern: #"\bStoreKit\b"#,
              positive: "import StoreKit"),
        .init(label: "AppStore.sync", pattern: #"\bAppStore\s*\.\s*sync\b"#,
              positive: "try await AppStore.sync()"),
    ]

    // MARK: - Reading the shipped source

    static func sourcesRoot() -> URL {
        AppTargetRegistrationGuardTests.packageRoot()
            .appendingPathComponent("Sources", isDirectory: true)
    }

    /// Every `.swift` under one package, comment-stripped. Comments are removed for the same
    /// reason `WindowReopenCommandGuardTests` removes them: this very file's neighbours explain
    /// what the app deliberately does NOT use, and a raw-text scan would fire on the
    /// explanation. `strippingComments` is reused rather than re-implemented — one stripper,
    /// one set of counterexamples.
    static func strippedSources(of package: String) throws -> [(path: String, code: String)] {
        let root = sourcesRoot().appendingPathComponent(package, isDirectory: true)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        else { return [] }
        var out: [(String, String)] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            out.append((url.lastPathComponent,
                        WindowReopenCommandGuardTests.strippingComments(text)))
        }
        return out.sorted { $0.0 < $1.0 }
    }

    /// Module names on `import` lines, comment-stripped. `@testable import` cannot appear in
    /// shipped sources, and the leading-anchor pattern would not match it anyway.
    static func imports(in files: [(path: String, code: String)]) -> Set<String> {
        var found: Set<String> = []
        let re = try? NSRegularExpression(pattern: #"^\s*import\s+([A-Za-z_][A-Za-z0-9_.]*)"#,
                                          options: [.anchorsMatchLines])
        for file in files {
            let ns = file.code as NSString
            re?.enumerateMatches(in: file.code, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                if let m { found.insert(ns.substring(with: m.range(at: 1))) }
            }
        }
        return found
    }

    static func matches(_ pattern: String, in code: String) -> Bool {
        code.range(of: pattern, options: .regularExpression) != nil
    }

    /// Fail-closed: a walk that found nothing would satisfy every "no forbidden symbol"
    /// assertion below by having nothing to look at.
    func requireSources(_ package: String, atLeast minimum: Int,
                        file: StaticString = #filePath, line: UInt = #line
    ) throws -> [(path: String, code: String)] {
        let files = try Self.strippedSources(of: package)
        XCTAssertGreaterThanOrEqual(files.count, minimum, """
            walked \(files.count) .swift files under Sources/\(package), expected at least \
            \(minimum). Every scan below is "no match found", which an empty corpus satisfies \
            trivially. This stops here.
            """, file: file, line: line)
        return files
    }

    // MARK: - (0) the patterns are trusted only after they fire

    func testEveryPatternMatchesItsOwnPositiveSample() {
        XCTAssertFalse(Self.forbidden.isEmpty, "an empty forbidden list scans for nothing")
        for entry in Self.forbidden {
            XCTAssertTrue(Self.matches(entry.pattern, in: entry.positive), """
                the pattern for \(entry.label) does not match its own known-bad sample \
                (\(entry.positive)). A pattern that cannot fire reports zero for the wrong \
                reason — see this file's type doc for the three times that has happened here.
                """)
        }
    }

    func testPatternsDoNotFireOnOrdinaryLedgerCode() {
        // The app's own vocabulary, including the `Transaction` collision the StoreKit family
        // deliberately avoids.
        let ordinary = """
        let tx = Transaction(id: id, amount: amount, currency: "CNY")
        try store.upsert(tx)
        let url = try AppPaths.databaseURL()
        let session = try LedgerSession(url: url)
        """
        for entry in Self.forbidden {
            XCTAssertFalse(Self.matches(entry.pattern, in: ordinary),
                           "\(entry.label) fires on ordinary ledger code — it would be red from birth")
        }
    }

    // MARK: - (a) the import closures

    func testCoreImportClosure() throws {
        let files = try requireSources("SoloLedgerCore", atLeast: 40)
        XCTAssertEqual(Self.imports(in: files), Self.coreImports, """
            SoloLedgerCore's import closure changed. This is a pin, not a discovery: adding a \
            dependency is allowed, but it has to be declared HERE in the same PR, so the \
            addition is reviewed as a capability decision rather than noticed later. Note what \
            the current set says — the data layer pulls in no UI framework at all.
            """)
    }

    func testAppImportClosure() throws {
        let files = try requireSources("SoloLedger", atLeast: 20)
        XCTAssertEqual(Self.imports(in: files), Self.appImports, """
            The App layer's import closure changed. Same rule as SoloLedgerCore: declare the \
            new module here in the same PR.
            """)
    }

    // MARK: - (b) no calls into the absent capabilities

    func testNoForbiddenCapabilitySymbolsInShippedSource() throws {
        let files = try requireSources("SoloLedgerCore", atLeast: 40)
            + requireSources("SoloLedger", atLeast: 20)
        var offenders: [String] = []
        for entry in Self.forbidden {
            for file in files where Self.matches(entry.pattern, in: file.code) {
                offenders.append("\(entry.label) in \(file.path)")
            }
        }
        XCTAssertTrue(offenders.isEmpty, """
            capability symbols found in shipped source: \(offenders.sorted().joined(separator: ", ")). \
            The native app ships with no networking, no OCR, no on-device ML and no in-app \
            purchase; PRIVACY.native.draft.md §4 and SWIFTUI_FEATURE_GAP.md §6 say so to users. \
            If one of these is genuinely being added, this guard and both of those documents \
            change together — and the network family additionally needs an entitlement, which \
            EntitlementsClosedSetGuardTests pins separately.
            """)
    }

    // MARK: - Counterexamples

    func testAForbiddenSymbolInCodeIsDetected() {
        let code = WindowReopenCommandGuardTests.strippingComments("""
        func fetch() { let t = URLSession.shared.dataTask(with: url) { _,_,_ in }; t.resume() }
        """)
        let hit = Self.forbidden.first { Self.matches($0.pattern, in: code) }
        XCTAssertEqual(hit?.label, "URLSession")
    }

    /// The decoy: the capability named only in a comment must NOT be reported. Getting this
    /// backwards would make the guard fire on its own neighbours' documentation.
    func testAForbiddenSymbolInACommentIsNotDetected() {
        let commented = WindowReopenCommandGuardTests.strippingComments("""
        // Deliberately no URLSession here — the app does not reach the network.
        /* NWConnection and VNRecognizeTextRequest are likewise absent. */
        let x = 1
        """)
        XCTAssertTrue(commented.contains("let x = 1"), "the stripper removed the code as well")
        for entry in Self.forbidden {
            XCTAssertFalse(Self.matches(entry.pattern, in: commented),
                           "\(entry.label) fired on a comment")
        }
    }

    func testAnAddedImportIsDetected() {
        let withExtra = Self.coreImports.union(["Network"])
        XCTAssertNotEqual(withExtra, Self.coreImports,
                          "an added module must not satisfy the pinned closure")
    }

    func testARemovedImportIsDetected() {
        let missing = Self.coreImports.subtracting(["CryptoKit"])
        XCTAssertNotEqual(missing, Self.coreImports,
                          "a removed module must not satisfy the pinned closure either")
    }

    func testAnEmptyCorpusCannotSatisfyTheScan() {
        let files: [(path: String, code: String)] = []
        let offenders = Self.forbidden.flatMap { e in
            files.filter { Self.matches(e.pattern, in: $0.code) }.map { _ in e.label }
        }
        XCTAssertTrue(offenders.isEmpty, "an empty corpus reports no offenders …")
        XCTAssertEqual(Self.imports(in: files), [], "… and no imports — which is why requireSources gates on a count")
    }
}
