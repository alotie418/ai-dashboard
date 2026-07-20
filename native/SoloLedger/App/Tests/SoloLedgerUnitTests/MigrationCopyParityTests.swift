import XCTest
@testable import SoloLedger
@testable import SoloLedgerCore

/// 2B-3 C12b-3: presentation + ROUTING safety for the migration UI. Verifies the pure
/// `MigrationPresenter.route` decision (shared by production RootView, the DEBUG preview and
/// these tests), the exhaustive code / kind / status / source mappings, six-locale key &
/// placeholder parity, the unavailable ≠ invalid and userCancelled ≠ invalid distinctions,
/// candidate metadata, and the diagnostics privacy bounds.
final class MigrationCopyParityTests: XCTestCase {

    private let locales = ["en", "zh-Hans", "zh-Hant", "ja", "ko", "fr"]

    private func allMigrationKeys() -> [String] {
        let codeKeys = MigrationPresenter.allIssueCodes.map { MigrationPresenter.messageKey(for: $0) }
        let kindKeys = MigrationPresenter.allUnresolvedKinds.map { MigrationPresenter.unresolvedKindKey(for: $0) }
        let sourceKeys = MigrationPresenter.productionSourceKinds.map { MigrationPresenter.sourceKindKey(for: $0) }
            + ["migration.source.unknown"]
        let chrome = [
            "migration.running.title", "migration.running.message",
            "migration.retriable.title", "migration.terminal.title",
            "migration.action.retry", "migration.action.exportDiagnostics", "migration.action.acknowledge",
            "migration.action.select", "migration.action.cancel",
            "migration.selection.title", "migration.selection.message",
            "migration.acknowledgement.title", "migration.acknowledgement.message",
            "migration.acknowledgement.unresolvedCount",
            "migration.candidate.valid", "migration.candidate.unavailable", "migration.candidate.invalid",
            "migration.candidate.validHint", "migration.candidate.unavailableHint", "migration.candidate.invalidHint",
            "migration.candidate.entries", "migration.candidate.noMeta",
            "migration.residual.note", "migration.residual.dismiss",
            "migration.diagnostics.title", "migration.diagnostics.filename", "migration.diagnostics.writeFailed",
            "migration.msg.selectionCancelled",
        ]
        return codeKeys + kindKeys + sourceKeys + chrome
    }

    private func rawValue(_ lang: String, _ key: String) -> String? {
        let sentinel = "\u{0}__MISSING__"
        let path = Localizer.resourceBundle.path(forResource: lang, ofType: "lproj")
            ?? Localizer.resourceBundle.path(forResource: lang.lowercased(), ofType: "lproj")
        guard let path, let bundle = Bundle(path: path) else { return nil }
        let v = bundle.localizedString(forKey: key, value: sentinel, table: nil)
        return v == sentinel ? nil : v
    }

    private func placeholders(_ s: String) -> Set<String> {
        guard let re = try? NSRegularExpression(pattern: "\\{[a-zA-Z]+\\}") else { return [] }
        let ns = s as NSString
        return Set(re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) })
    }

    // MARK: - ROUTING (pure; the real safety net — non-skipped, headless)

    private let noFlags = (bootError: false, migrationFailure: false)

    func testRouteTerminalGoesToChainRecoveryTerminalNotLegacy() {
        let r = MigrationPresenter.route(bootError: false, migrationFailure: false,
                                         input: .terminal, ready: false, onboardingDone: false)
        XCTAssertEqual(r, .chainRecovery(.terminal))
        XCTAssertNotEqual(r, .legacyRecovery, "terminal must NEVER route to the legacy restore/blank screen")
    }

    func testRouteRetriableGoesToChainRecoveryRetriable() {
        XCTAssertEqual(MigrationPresenter.route(bootError: false, migrationFailure: false,
                                                input: .retriable, ready: false, onboardingDone: false),
                       .chainRecovery(.retriable))
    }

    func testRouteCleanupResidualReadyGoesToMainWithBanner() {
        XCTAssertEqual(MigrationPresenter.route(bootError: false, migrationFailure: false,
                                                input: .cleanupResidual, ready: true, onboardingDone: true),
                       .main(showResidualBanner: true),
                       "cleanupResidual with an open ledger must show the main UI + banner, never block it")
    }

    func testRouteNoneReadyFalseGoesToLoading() {
        XCTAssertEqual(MigrationPresenter.route(bootError: false, migrationFailure: false,
                                                input: .none, ready: false, onboardingDone: false),
                       .loading, ".none is neutral — ready==false gates it to loading, not the main UI")
    }

    func testRouteNoneReadyTrueGoesToMainOrOnboarding() {
        XCTAssertEqual(MigrationPresenter.route(bootError: false, migrationFailure: false,
                                                input: .none, ready: true, onboardingDone: true),
                       .main(showResidualBanner: false))
        XCTAssertEqual(MigrationPresenter.route(bootError: false, migrationFailure: false,
                                                input: .none, ready: true, onboardingDone: false),
                       .onboarding)
    }

    func testRoutePriorityBootErrorThenLegacyThenState() {
        XCTAssertEqual(MigrationPresenter.route(bootError: true, migrationFailure: true,
                                                input: .terminal, ready: false, onboardingDone: false), .bootError)
        XCTAssertEqual(MigrationPresenter.route(bootError: false, migrationFailure: true,
                                                input: .terminal, ready: false, onboardingDone: false), .legacyRecovery)
    }

    func testRouteInputMappingForEveryState() {
        XCTAssertEqual(MigrationPresenter.routeInput(for: .none), .none)
        XCTAssertEqual(MigrationPresenter.routeInput(for: .running(.resolving)), .running)
        XCTAssertEqual(MigrationPresenter.routeInput(for: .retriable(block(.ioTransient, .retriable))), .retriable)
        XCTAssertEqual(MigrationPresenter.routeInput(for: .terminal(block(.stagingTampered, .terminal))), .terminal)
        XCTAssertEqual(MigrationPresenter.routeInput(for: .cleanupResidual(MigrationResidual(importID: "x"))), .cleanupResidual)
        XCTAssertEqual(MigrationPresenter.routeInput(for: .awaitingImportSelection([])), .importSelection)
        let req = AcknowledgementRequest(importID: "i", snapshotIdentitySHA256: "s", attachmentManifestSHA256: "a",
                                         preparedDBIdentity: "sha256:p", unresolvedReportHash: "h")
        XCTAssertEqual(MigrationPresenter.routeInput(for: .awaitingAcknowledgement(req, UnresolvedReport(items: []))), .acknowledgement)
        XCTAssertEqual(MigrationPresenter.routeInput(for: .awaitingSourceChoice), .sourceChoice)
    }

    func testDormantSourceChoiceInputRendersAsRunningPlaceholderWithNoBlock() {
        // N7.1: the dormant state maps to the EXISTING neutral progress route (no new route,
        // view, or copy until N7.2 ships the real source-choice screen) and carries no block.
        XCTAssertEqual(MigrationPresenter.route(bootError: false, migrationFailure: false,
                                                input: .sourceChoice, ready: false, onboardingDone: false),
                       .running)
        XCTAssertNil(MigrationPresenter.block(from: .awaitingSourceChoice))
        XCTAssertEqual(MigrationPresenter.stateTag(.awaitingSourceChoice), "awaitingSourceChoice")
    }

    private func block(_ code: MigrationIssueCode, _ cls: MigrationBlock.Class) -> MigrationBlock {
        MigrationBlock(code: code, classification: cls)
    }

    // MARK: - 24-code mapping + userCancelled

    func testAllIssueCodesMapToDistinctExistingKeys() {
        XCTAssertEqual(MigrationPresenter.allIssueCodes.count, 24)
        var keys = Set<String>()
        for code in MigrationPresenter.allIssueCodes {
            let key = MigrationPresenter.messageKey(for: code)
            keys.insert(key)
            for lang in locales {
                XCTAssertNotNil(rawValue(lang, key), "\(lang) missing \(key)")
                XCTAssertNotEqual(rawValue(lang, key), key, "\(lang) leaks raw key \(key)")
            }
        }
        XCTAssertEqual(keys.count, 24, "each code maps to a DISTINCT key")
    }

    func testUserCancelledMessageDistinctFromInvalidSelection() {
        let cancelled = MigrationBlock(code: .invalidSelection, classification: .terminal, params: ["reason": "userCancelled"])
        let invalid = MigrationBlock(code: .invalidSelection, classification: .terminal, params: [:])
        XCTAssertEqual(MigrationPresenter.messageKey(for: cancelled), "migration.msg.selectionCancelled")
        XCTAssertEqual(MigrationPresenter.messageKey(for: invalid), "migration.msg.invalidSelection")
        XCTAssertNotEqual(MigrationPresenter.messageKey(for: cancelled), MigrationPresenter.messageKey(for: invalid))
    }

    // MARK: - unresolved kinds + source kinds

    func testUnresolvedKindsMapToDistinctExistingKeys() {
        XCTAssertEqual(MigrationPresenter.allUnresolvedKinds.count, 7)
        var keys = Set<String>()
        for kind in MigrationPresenter.allUnresolvedKinds {
            let key = MigrationPresenter.unresolvedKindKey(for: kind)
            keys.insert(key)
            for lang in locales {
                XCTAssertNotNil(rawValue(lang, key), "\(lang) missing \(key)")
                XCTAssertNotEqual(rawValue(lang, key), key, "\(lang) leaks raw key \(key)")
            }
        }
        XCTAssertEqual(keys.count, 7, "each unresolved kind maps to a DISTINCT key")
    }

    func testSourceKindMappingUnknownFallbackAndNoRawLeak() {
        var keys = Set<String>()
        for sk in MigrationPresenter.productionSourceKinds {
            let key = MigrationPresenter.sourceKindKey(for: sk)
            keys.insert(key)
            for lang in locales {
                let v = rawValue(lang, key)
                XCTAssertNotNil(v)
                XCTAssertNotEqual(v, sk, "\(lang) leaks raw sourceKind \(sk)")
            }
        }
        XCTAssertEqual(keys.count, 4, "four production source kinds map to distinct keys")
        XCTAssertEqual(MigrationPresenter.sourceKindKey(for: "somethingWeird"), "migration.source.unknown")
        XCTAssertEqual(MigrationPresenter.sourceKindKey(for: ""), "migration.source.unknown")
    }

    // MARK: - candidate metadata preserved

    func testCandidateVMPreservesMetadata() {
        let r = RecoverableImport(importID: "imp-1", status: .valid,
                                  createdAt: "2026-01-02", sourceKind: "exportBundle", ingestedCount: 42)
        let vm = MigrationCandidateVM(r)
        XCTAssertEqual(vm.createdAt, "2026-01-02")
        XCTAssertEqual(vm.sourceKind, "exportBundle")
        XCTAssertEqual(vm.ingestedCount, 42)
        XCTAssertEqual(MigrationPresenter.sourceKindKey(for: vm.sourceKind ?? ""), "migration.source.exportBundle")
    }

    // MARK: - six-locale key + placeholder parity, no raw-key leak

    func testMigrationKeyAndPlaceholderParityAcrossLocales() {
        for key in allMigrationKeys() {
            var perLocale: [String: Set<String>] = [:]
            for lang in locales {
                guard let v = rawValue(lang, key) else { return XCTFail("\(lang) is missing migration key: \(key)") }
                XCTAssertNotEqual(v, key, "\(lang) leaks the raw key: \(key)")
                perLocale[lang] = placeholders(v)
            }
            let reference = perLocale["en"] ?? []
            for lang in locales {
                XCTAssertEqual(perLocale[lang], reference, "\(lang) placeholder set differs from en for \(key)")
            }
        }
    }

    func testExpectedPlaceholderKeysOnly() {
        for key in allMigrationKeys() {
            let ph = placeholders(rawValue("en", key) ?? "")
            switch key {
            case "migration.acknowledgement.unresolvedCount", "migration.candidate.entries":
                XCTAssertEqual(ph, ["{count}"], "\(key) must carry {count}")
            case "migration.residual.note":
                XCTAssertEqual(ph, ["{importID}"])
            default:
                XCTAssertTrue(ph.isEmpty, "\(key) must have no placeholder")
            }
        }
    }

    func testLocalizerReturnsNoRawMigrationKey() {
        for lang in locales {
            let loc = Localizer(language: lang)
            for key in allMigrationKeys() {
                XCTAssertNotEqual(loc.t(key), key, "\(lang) Localizer returned the raw key \(key)")
            }
        }
    }

    // MARK: - unavailable ≠ invalid

    func testCandidateStatusCopyAndSelectabilityAreDistinct() {
        XCTAssertNotEqual(MigrationPresenter.candidateStatusKey(for: .unavailable(.ioTransient)),
                          MigrationPresenter.candidateStatusKey(for: .invalid(.stagingTampered)))
        XCTAssertTrue(MigrationPresenter.isSelectable(.valid))
        XCTAssertFalse(MigrationPresenter.isSelectable(.unavailable(.ioTransient)))
        XCTAssertFalse(MigrationPresenter.isSelectable(.invalid(.stagingTampered)))
        for lang in locales {
            XCTAssertNotEqual(rawValue(lang, "migration.candidate.unavailable"),
                              rawValue(lang, "migration.candidate.invalid"),
                              "\(lang): unavailable and invalid must read differently")
        }
    }

    // MARK: - diagnostics privacy bounds

    func testDiagnosticsRedactsPathsExcludesErrorTextAndCleansInjection() {
        let block = MigrationBlock(code: .ioTransient, classification: .retriable,
                                   params: ["op": "record",
                                            "importID": "imp-42",
                                            "field": "/private/var/folders/ab/leak.tmp",
                                            "reason": "line-one\nline-two",
                                            "detail": "SECRET_ERR_9f3 at /Users/alice/private/thing"])
        let text = MigrationPresenter.diagnosticsText(
            state: .retriable(block), schemaVersion: "9",
            databasePath: "/Users/alice/Library/Containers/x/Data/Library/Application Support/db.sqlite",
            appVersion: "1.0 (1)", osVersion: "Version 14.0", homeDirectory: "/Users/alice")

        // Error-bearing / non-allowlisted param never appears.
        XCTAssertFalse(text.contains("SECRET_ERR_9f3"))
        XCTAssertFalse(text.contains("param.detail"))
        // db reduced to filename only — no directory structure at all.
        XCTAssertTrue(text.contains("db: <redacted>/db.sqlite"))
        XCTAssertFalse(text.contains("Library"))
        XCTAssertFalse(text.contains("Containers"))
        XCTAssertFalse(text.contains("/Users/alice"))
        // absolute path inside an allowlisted param is normalized to <redacted>/<name>.
        XCTAssertTrue(text.contains("param.field: <redacted>/leak.tmp"))
        XCTAssertFalse(text.contains("/private/var"))
        // newline injection collapsed (no diagnostic-line splitting from a param value).
        XCTAssertFalse(text.contains("line-one\nline-two"))
        XCTAssertTrue(text.contains("param.reason: line-one line-two"))
        // allowlisted structured values preserved.
        XCTAssertTrue(text.contains("param.importID: imp-42"))
        XCTAssertTrue(text.contains("param.op: record"))
        XCTAssertTrue(text.contains("code: ioTransient"))
        XCTAssertTrue(text.contains("no transactions, attachments, or database contents"))
        XCTAssertFalse(text.contains("amount"))
    }

    func testDiagnosticsForNonBlockingStatesCarryNoBlock() {
        let text = MigrationPresenter.diagnosticsText(
            state: .none, schemaVersion: "9", databasePath: "/x/db", appVersion: "1", osVersion: "1", homeDirectory: "/h")
        XCTAssertTrue(text.contains("state: none"))
        XCTAssertFalse(text.contains("code:"))
    }
}
