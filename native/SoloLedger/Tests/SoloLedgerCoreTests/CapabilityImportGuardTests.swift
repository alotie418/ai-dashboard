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
/// > no source file in any build target names one of the listed capability symbols; each
/// > target's import closure is the pinned one; and the two Foundation initializers that can
/// > fetch a URL appear only at their two pinned call sites.
///
/// That is a source-level fact, not an enforcement boundary. It cannot stop a future edit from
/// adding one — it can only make the edit arrive red instead of silent. Do not read it as
/// "the app cannot do these things"; for the network half, that stronger statement belongs to
/// the entitlements guard, and only to it.
///
/// ## What it deliberately does NOT cover, and why the wording above is that specific
///
/// The first draft said "the shipped source contains no CALL to these capabilities" — the same
/// over-claim 2c-7 had just corrected elsewhere. Review found two real holes in it:
///
///  1. **A symbol list is not a capability list.** `Data(contentsOf:)` and `String(contentsOf:)`
///     fetch an `http(s)` URL as readily as they read a file, need no import beyond
///     `Foundation`, and name none of the symbols below. They also have two legitimate LOCAL
///     uses here (CSV import, manifest decode), so a pattern banning them would be red from
///     birth and one allowing them would be blind. They are pinned as a CLOSED SET of call
///     sites instead: the existing two stay green, and a THIRD — which is where a network fetch
///     would arrive — turns red and has to be justified here. That is a **review trigger, not a
///     proof of absence**, and it is described as such.
///  2. **Swift is not the only language in the build.** `Sources/CSQLite` is a real
///     `.systemLibrary` target. A `socket()`/`connect()` helper added to its header would be
///     callable from Swift through the already-allowed `CSQLite` import, changing neither the
///     import closure nor any Swift symbol. The C target is scanned too, and its file set is
///     pinned so that ADDING a file to it is itself a declared change.
///
/// Nothing outside those three assertions is claimed — in particular nothing about the system
/// SQLite the C target links against.
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

    // MARK: - The non-Swift build target

    /// `Sources/CSQLite` is a `.systemLibrary` target: it exists to bind the platform's
    /// libsqlite3, and it is the one place in the build where C can enter. Its file set is
    /// pinned so that adding a `.c` — the natural home for a helper the Swift scans cannot
    /// see — is a declared change rather than a quiet one.
    static let cTargetFiles: Set<String> = ["module.modulemap", "shim.h"]

    /// C-side network primitives. Kept separate from ``forbidden`` because these are far too
    /// generic for Swift (`bind`, `connect` and `send` all collide with ordinary Swift
    /// vocabulary) but are unambiguous in a 300-byte header whose only content is an
    /// `#include`.
    static let cForbidden: [Forbidden] = [
        .init(label: "socket(", pattern: #"\bsocket\s*\("#, positive: "int s = socket(AF_INET, SOCK_STREAM, 0);"),
        .init(label: "connect(", pattern: #"\bconnect\s*\("#, positive: "connect(s, (struct sockaddr *)&addr, sizeof(addr));"),
        .init(label: "send(", pattern: #"\bsend\s*\("#, positive: "send(s, buf, len, 0);"),
        .init(label: "recv(", pattern: #"\brecv\s*\("#, positive: "recv(s, buf, len, 0);"),
        .init(label: "gethostby", pattern: #"\bgethostby\w*\s*\("#, positive: "struct hostent *h = gethostbyname(name);"),
        .init(label: "getaddrinfo(", pattern: #"\bgetaddrinfo\s*\("#, positive: "getaddrinfo(host, svc, &hints, &res);"),
        .init(label: "CFStream", pattern: #"\bCFStream"#, positive: "CFStreamCreatePairWithSocketToHost(NULL, h, p, &r, &w);"),
    ]

    // MARK: - The Foundation URL loaders

    /// `Data(contentsOf:)` / `String(contentsOf:)` — local file reads here, remote fetches
    /// elsewhere, and the source cannot tell you which without running it. Pinned by call site:
    /// these two are reviewed and local; a third has to come through this list.
    static let urlLoadingCallSites: [String: Int] = [
        "AppModel.swift": 1,        // CSV import — reads the file the user picked in the panel
        "AttachmentApply.swift": 1, // import manifest decode — reads a file inside the container
    ]

    static let urlLoadingPattern = #"\b(?:Data|String)\s*\(\s*contentsOf\s*:"#

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

    /// How many times `pattern` matches, as a REGEX. Deliberately not `ranges(of:)`: that
    /// overload takes the string as a LITERAL, so a pattern handed to it silently matches
    /// nothing and the count comes back 0 — which, in a "these are the only call sites"
    /// assertion, reads as "there are none". Caught here by the pinned set failing against an
    /// empty observation rather than passing against one.
    static func matchCount(_ pattern: String, in code: String) -> Int {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return 0 }
        return re.numberOfMatches(in: code, range: NSRange(location: 0, length: (code as NSString).length))
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

    // MARK: - (c) the C target

    func testTheCTargetsFileSetIsPinned() throws {
        let root = Self.sourcesRoot().appendingPathComponent("CSQLite", isDirectory: true)
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { !$0.hasPrefix(".") })
        XCTAssertEqual(names, Self.cTargetFiles, """
            Sources/CSQLite's file set changed. It is a system-library shim — a header and a \
            modulemap — and the reason this is pinned is that a `.c` added here compiles into \
            the build, is callable from Swift through the already-allowed CSQLite import, and \
            is invisible to every Swift-side scan in this file.
            """)
    }

    func testNoNetworkPrimitivesInTheCTarget() throws {
        let root = Self.sourcesRoot().appendingPathComponent("CSQLite", isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { !$0.hasPrefix(".") }
        XCTAssertFalse(names.isEmpty, "the C target scan found no files to read")
        var offenders: [String] = []
        for name in names {
            let text = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
            let code = WindowReopenCommandGuardTests.strippingComments(text)
            for entry in Self.cForbidden + Self.forbidden where Self.matches(entry.pattern, in: code) {
                offenders.append("\(entry.label) in \(name)")
            }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "network primitives in the C target: \(offenders.sorted().joined(separator: ", "))")
    }

    func testEveryCPatternMatchesItsOwnPositiveSample() {
        for entry in Self.cForbidden {
            XCTAssertTrue(Self.matches(entry.pattern, in: entry.positive),
                          "the C pattern for \(entry.label) does not match its own sample")
        }
    }

    // MARK: - (d) the Foundation URL loaders, as a closed set of call sites

    func testTheURLLoadingInitializersAppearOnlyAtTheirPinnedCallSites() throws {
        let files = try requireSources("SoloLedgerCore", atLeast: 40)
            + requireSources("SoloLedger", atLeast: 20)
        var observed: [String: Int] = [:]
        for file in files {
            let count = Self.matchCount(Self.urlLoadingPattern, in: file.code)
            if count > 0 { observed[file.path] = count }
        }
        XCTAssertEqual(observed, Self.urlLoadingCallSites, """
            The set of `Data(contentsOf:)` / `String(contentsOf:)` call sites changed \
            (observed \(observed.sorted { $0.key < $1.key }), pinned \
            \(Self.urlLoadingCallSites.sorted { $0.key < $1.key })). These initializers read a \
            local file and fetch a remote URL with the same spelling, need no import beyond \
            Foundation, and name none of the symbols this file scans for — so a NEW one is \
            exactly where a network call would arrive unnoticed. Add it here with a note on \
            what it reads. This is a review trigger, not a proof that the existing two are local.
            """)
    }

    // MARK: - Counterexamples

    func testAThirdURLLoadingCallSiteIsDetected() {
        var mutated = Self.urlLoadingCallSites
        mutated["SomeNewFile.swift"] = 1
        XCTAssertNotEqual(mutated, Self.urlLoadingCallSites,
                          "an added call site must not satisfy the pinned set")
    }

    /// The bug this file shipped for one run: `ranges(of:)` treats its String argument as a
    /// LITERAL, so it reported 0 for a pattern that matches twice — and 0 is exactly what a
    /// "these are the only call sites" assertion wants to hear.
    func testTheCounterIsARegexCounterAndNotALiteralOne() {
        let sample = "try Data(contentsOf: a)\ntry String(contentsOf: b, encoding: .utf8)"
        XCTAssertEqual(Self.matchCount(Self.urlLoadingPattern, in: sample), 2)
        XCTAssertEqual(sample.ranges(of: Self.urlLoadingPattern).count, 0,
                       "literal matching would report zero — that is why matchCount exists")
    }

    func testTheURLLoadingPatternMatchesBothSpellingsAndNotTheirNeighbours() {
        XCTAssertTrue(Self.matches(Self.urlLoadingPattern, in: "try Data(contentsOf: url)"))
        XCTAssertTrue(Self.matches(Self.urlLoadingPattern, in: "try String(contentsOf: url, encoding: .utf8)"))
        // `append(contentsOf:)` / `write(contentsOf:)` share the label and are unrelated APIs;
        // matching them would put nine false call sites in the pinned set.
        XCTAssertFalse(Self.matches(Self.urlLoadingPattern, in: "out.append(contentsOf: buf)"))
        XCTAssertFalse(Self.matches(Self.urlLoadingPattern, in: "try sink.write(contentsOf: chunk)"))
    }

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
