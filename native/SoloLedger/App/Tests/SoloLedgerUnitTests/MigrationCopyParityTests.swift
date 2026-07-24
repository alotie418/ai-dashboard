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
        // N7.2 source-choice copy (design §8) — deliberately ALL placeholder-free.
        let chooseSource = [
            "migration.chooseSource.title", "migration.chooseSource.body",
            "migration.chooseSource.migrate.button", "migration.chooseSource.migrate.hint",
            "migration.chooseSource.createNew.button", "migration.chooseSource.createNew.hint",
            "migration.chooseSource.picker.prompt", "migration.chooseSource.picker.noData",
            "migration.chooseSource.importing",
            "migration.chooseSource.confirm.title", "migration.chooseSource.confirm.body",
            "migration.chooseSource.confirm.back", "migration.chooseSource.confirm.create",
        ]
        return codeKeys + kindKeys + sourceKeys + chrome + chooseSource
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

    func testSourceChoiceInputRoutesToTheDedicatedChooseSourceScreen() {
        // N7.2: the source-choice state routes to its OWN pre-open screen (independent of
        // onboarding — `.onboarding` is only reachable after ready==true) and carries no block.
        XCTAssertEqual(MigrationPresenter.route(bootError: false, migrationFailure: false,
                                                input: .sourceChoice, ready: false, onboardingDone: false),
                       .chooseSource)
        XCTAssertNil(MigrationPresenter.block(from: .awaitingSourceChoice))
        XCTAssertEqual(MigrationPresenter.stateTag(.awaitingSourceChoice), "awaitingSourceChoice")
    }

    func testCreateFreshConfirmZhHansCopyIsLockedVerbatim() {
        // Design §1.3/§8: the zh-Hans second-confirmation copy is LOCKED — byte-for-byte,
        // including CJK punctuation and the quoted button reference. Any drift is a red test.
        XCTAssertEqual(rawValue("zh-Hans", "migration.chooseSource.confirm.title"),
                       "创建新的空账本？")
        XCTAssertEqual(rawValue("zh-Hans", "migration.chooseSource.confirm.body"),
                       "这不会删除或修改旧版 SoloLedger 的数据，但会跳过迁移并为当前 App 创建一个空账本。旧数据不会自动导入；如需迁移，请返回并选择“迁移旧数据”。")
        XCTAssertEqual(rawValue("zh-Hans", "migration.chooseSource.confirm.back"), "返回")
        XCTAssertEqual(rawValue("zh-Hans", "migration.chooseSource.confirm.create"), "创建空账本")
    }

    /// Issue #382: the source-choice title is action-oriented, NOT a detection claim. On a
    /// truly-empty first launch (`.requiresSourceChoice`) the screen has discovered nothing, so
    /// the title must not assert found data. Six locales are LOCKED byte-for-byte to the approved
    /// action-oriented copy, and the two Chinese locales are additionally asserted to be free of
    /// the detection verbs "发现"/"發現" (the specific misleading wording this change removes).
    func testSourceChoiceTitleIsActionOrientedAndLockedVerbatim() {
        let expected: [String: String] = [
            "zh-Hans": "选择开始方式",
            "zh-Hant": "選擇開始方式",
            "en":      "Choose how to start",
            "ja":      "開始方法を選んでください",
            "ko":      "시작 방법을 선택하세요",
            "fr":      "Choisissez comment commencer",
        ]
        for (lang, text) in expected {
            XCTAssertEqual(rawValue(lang, "migration.chooseSource.title"), text,
                           "\(lang) chooseSource.title must equal the approved action-oriented copy")
        }
        // The detection verb the old copy used must be gone from both Chinese titles.
        XCTAssertFalse(rawValue("zh-Hans", "migration.chooseSource.title")?.contains("发现") ?? true,
                       "zh-Hans title must not use the detection verb 发现")
        XCTAssertFalse(rawValue("zh-Hant", "migration.chooseSource.title")?.contains("發現") ?? true,
                       "zh-Hant title must not use the detection verb 發現")
        // The dedicated import-selection screen keeps its OWN, unrelated title in every locale.
        for lang in locales {
            XCTAssertNotEqual(rawValue(lang, "migration.chooseSource.title"),
                              rawValue(lang, "migration.selection.title"),
                              "\(lang): chooseSource.title and selection.title must stay distinct")
            // The body still exists and differs from the title (title-only change; body untouched).
            let body = rawValue(lang, "migration.chooseSource.body")
            XCTAssertNotNil(body, "\(lang) chooseSource.body must exist")
            XCTAssertNotEqual(body, rawValue(lang, "migration.chooseSource.title"),
                              "\(lang): body and title must differ")
        }
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

    // MARK: - Issue #383: createFresh step/errno structured diagnostics (contract-gated, pair-atomic)
    //
    // SYNTHETIC FIXTURES ONLY: every errno number below is a hand-picked test input, NOT a value
    // observed from any run — the B1 experiment never directly observed an errno. These guards
    // prove the value-level contract (code+reason+known-step+canonical-positive-Int32-errno), the
    // pair-atomic omission of BOTH fields off-contract, canonical re-serialization (never raw
    // input, never `sanitize`), the untouched 8-key generic allowlist, and no path/strerror leak.

    private func diagText(_ block: MigrationBlock) -> String {
        MigrationPresenter.diagnosticsText(
            state: .retriable(block), schemaVersion: "9",
            databasePath: "/Users/x/Library/Application Support/db.sqlite",
            appVersion: "1.0 (1)", osVersion: "Version 14.0", homeDirectory: "/Users/x")
    }

    /// A createFresh reservation-failure block. `nil` step/errno/reason are simply absent params.
    private func reservationBlock(step: String?, errno: String?,
                                  code: MigrationIssueCode = .storeOpenFailed,
                                  reason: String? = "reservationFailed",
                                  op: String = "createFresh") -> MigrationBlock {
        var p: [String: String] = ["op": op]
        if let reason { p["reason"] = reason }
        if let step { p["step"] = step }
        if let errno { p["errno"] = errno }
        return MigrationBlock(code: code, classification: .retriable, params: p)
    }

    /// The six known ReservationStep raw values (kept in sync by hand — ReservationStep is not
    /// CaseIterable and lives in Core, which this change must not touch).
    private let knownReservationSteps = ["parentBind", "ancestorBind", "parentCreate",
                                         "openExcl", "fstat", "close"]

    // (1) legal contract → both fields emitted, canonical.
    func testReservationDiagnosticsEmitsCanonicalStepErrnoWhenContractHolds() {
        for step in knownReservationSteps {
            let text = diagText(reservationBlock(step: step, errno: "2"))   // 2 is a synthetic fixture
            XCTAssertTrue(text.contains("param.step: \(step)"), "step \(step) must be emitted")
            XCTAssertTrue(text.contains("param.errno: 2"), "errno must be emitted for step \(step)")
        }
        // Int32.max boundary accepted and echoed canonically.
        XCTAssertTrue(diagText(reservationBlock(step: "parentBind", errno: "2147483647"))
                        .contains("param.errno: 2147483647"))
    }

    // (2) code or reason mismatch → neither field.
    func testReservationDiagnosticsSuppressedOnCodeOrReasonMismatch() {
        for text in [
            diagText(reservationBlock(step: "parentBind", errno: "2", code: .ioTransient)),   // wrong code
            diagText(reservationBlock(step: "parentBind", errno: "2", reason: "somethingElse")), // wrong reason
            diagText(reservationBlock(step: "parentBind", errno: "2", reason: nil)),           // missing reason
        ] {
            XCTAssertFalse(text.contains("param.step"))
            XCTAssertFalse(text.contains("param.errno"))
        }
    }

    // (3) step forgery matrix (errno held legal) → pair-atomic omission, no leak.
    func testReservationDiagnosticsRejectsForgedStepPairAtomically() {
        let forgedSteps = [
            "notastep",                    // unknown enum value
            "/etc/passwd",                 // path
            "No such file or directory",   // strerror / system text
            "parent\nBind",                // embedded newline
            "parentBind ",                 // trailing space (not a raw value)
            "PARENTBIND",                  // wrong case
        ]
        for forged in forgedSteps {
            let text = diagText(reservationBlock(step: forged, errno: "2"))
            XCTAssertFalse(text.contains("param.step"), "forged step emitted: \(forged.debugDescription)")
            XCTAssertFalse(text.contains("param.errno"), "pair-atomic errno not suppressed: \(forged.debugDescription)")
            XCTAssertFalse(text.contains(forged), "forged step text leaked: \(forged.debugDescription)")
        }
    }

    // (4) errno forgery matrix (step held legal) → pair-atomic omission.
    func testReservationDiagnosticsRejectsForgedErrnoPairAtomically() {
        let forgedErrnos = [
            "",                          // empty
            "0",                         // zero
            "-1",                        // negative
            "+1",                        // leading plus
            "abc",                       // non-numeric
            " 2",                        // leading whitespace
            "2 ",                        // trailing whitespace
            "2\n",                       // trailing newline
            "/tmp/x",                    // path
            "No such file or directory", // strerror / system text
            "2147483648",                // Int32 overflow (max + 1)
            "9999999999",                // far overflow
            "01",                        // non-canonical leading zero
            "0x10",                      // hex
            "\u{FF11}",                  // full-width digit ONE (not ASCII)
        ]
        for forged in forgedErrnos {
            let text = diagText(reservationBlock(step: "parentBind", errno: forged))
            XCTAssertFalse(text.contains("param.errno"), "forged errno emitted: \(forged.debugDescription)")
            XCTAssertFalse(text.contains("param.step"), "pair-atomic step not suppressed: \(forged.debugDescription)")
        }
    }

    // (5) missing / partial fields → pair-atomic omission.
    func testReservationDiagnosticsPairAtomicityOnMissingOrPartialFields() {
        for text in [
            diagText(reservationBlock(step: nil, errno: "2")),        // missing step
            diagText(reservationBlock(step: "parentBind", errno: nil)), // missing errno
            diagText(reservationBlock(step: "parentBind", errno: "0")), // legal step, illegal errno
            diagText(reservationBlock(step: "bogus", errno: "2")),      // illegal step, legal errno
        ] {
            XCTAssertFalse(text.contains("param.step"))
            XCTAssertFalse(text.contains("param.errno"))
        }
    }

    // (6) generic 8-key allowlist unchanged; step/errno never surface via it.
    func testGenericAllowlistUnchangedAndExcludesStepErrno() {
        XCTAssertEqual(MigrationPresenter.diagnosticsAllowedParamKeys,
                       ["op", "reason", "field", "importID", "requestedImportID", "existingImportID",
                        "attempts", "userVersion"],
                       "the 8 generic allowlist keys (and order) must not change")
        XCTAssertFalse(MigrationPresenter.diagnosticsAllowedParamKeys.contains("step"))
        XCTAssertFalse(MigrationPresenter.diagnosticsAllowedParamKeys.contains("errno"))
        // A NON-reservation block carrying step/errno params must not surface them.
        let text = diagText(MigrationBlock(code: .ioTransient, classification: .retriable,
                                           params: ["op": "record", "importID": "imp-9",
                                                    "step": "parentBind", "errno": "2"]))
        XCTAssertTrue(text.contains("param.op: record"))
        XCTAssertTrue(text.contains("param.importID: imp-9"))
        XCTAssertFalse(text.contains("param.step"), "step must never leak via the generic allowlist")
        XCTAssertFalse(text.contains("param.errno"), "errno must never leak via the generic allowlist")
    }

    // (7) no path / strerror leak; a legal pair adds EXACTLY two lines (no injection).
    func testReservationDiagnosticsNeverLeaksPathsOrErrorTextAndAddsExactlyTwoLines() {
        let forged = diagText(reservationBlock(step: "/Users/a/secret", errno: "No such file or directory"))
        XCTAssertFalse(forged.contains("param.step"))
        XCTAssertFalse(forged.contains("param.errno"))
        XCTAssertFalse(forged.contains("secret"))
        XCTAssertFalse(forged.contains("No such file"))

        let legal = diagText(reservationBlock(step: "parentBind", errno: "2"))
        let baseline = diagText(reservationBlock(step: nil, errno: nil))
        XCTAssertEqual(legal.split(separator: "\n", omittingEmptySubsequences: false).count,
                       baseline.split(separator: "\n", omittingEmptySubsequences: false).count + 2,
                       "a legal pair adds exactly two lines, nothing injected")
        XCTAssertTrue(legal.contains("param.step: parentBind"))
        XCTAssertTrue(legal.contains("param.errno: 2"))
    }

    // (8) main storeOpenFailed copy + six locales unchanged. The user-facing copy is the SAME as
    // before #383 (this change only surfaces step/errno in the exported diagnostics, never the
    // message). Pin all six verbatim so a reword — which the mapping/non-nil/≠-raw-key checks would
    // all silently pass — is a red test.
    func testStoreOpenFailedMainCopyUnchangedAcrossLocales() {
        XCTAssertEqual(MigrationPresenter.messageKey(for: .storeOpenFailed), "migration.msg.storeOpenFailed")
        let expected: [String: String] = [
            "zh-Hans": "打开账本失败。请重试。",
            "zh-Hant": "開啟帳本失敗，請再試一次。",
            "en":      "Couldn't open the ledger. Please try again.",
            "ja":      "台帳を開けませんでした。もう一度お試しください。",
            "ko":      "장부를 열지 못했습니다. 다시 시도하세요.",
            "fr":      "Impossible d'ouvrir la comptabilité. Veuillez réessayer.",
        ]
        for lang in locales {
            XCTAssertEqual(rawValue(lang, "migration.msg.storeOpenFailed"), expected[lang],
                           "\(lang) storeOpenFailed copy must be unchanged by #383")
        }
    }

    // Direct helper edge coverage (belt-and-suspenders over the end-to-end guards above).
    func testCanonicalPositiveInt32AcceptsOnlyCanonicalDecimals() {
        XCTAssertEqual(MigrationPresenter.canonicalPositiveInt32("1"), 1)
        XCTAssertEqual(MigrationPresenter.canonicalPositiveInt32("13"), 13)
        XCTAssertEqual(MigrationPresenter.canonicalPositiveInt32("2147483647"), Int32.max)
        for bad in ["", "0", "00", "01", "-1", "+1", " 1", "1 ", "1\n", "\n1", "abc",
                    "1a", "0x1", "/1", "2147483648", "9999999999", "\u{FF11}", "\u{0661}", "1_000"] {
            XCTAssertNil(MigrationPresenter.canonicalPositiveInt32(bad), "\(bad.debugDescription) must be rejected")
        }
    }

    func testReservationDiagnosticsHelperReturnsNilOffContractAndValuesOnContract() {
        XCTAssertNil(MigrationPresenter.reservationDiagnostics(
            MigrationBlock(code: .ioTransient, classification: .retriable,
                           params: ["reason": "reservationFailed", "step": "parentBind", "errno": "2"])))
        let ok = MigrationPresenter.reservationDiagnostics(
            MigrationBlock(code: .storeOpenFailed, classification: .retriable,
                           params: ["reason": "reservationFailed", "step": "parentBind", "errno": "2"]))
        XCTAssertEqual(ok?.step, "parentBind")
        XCTAssertEqual(ok?.errno, "2")
    }

    // (9) I2: precise-gating persistence — near-miss reason/step/errno (trailing space, embedded
    // NUL, CR, empty) all suppress BOTH fields pair-atomically, and forged raw step/errno never
    // surface via the dedicated fields. The reason cases pair a near-miss reason with a VALID
    // step+errno so the reason gate is the ONLY rejector — this is what kills a
    // reason `== "reservationFailed"` → `hasPrefix("reservationFailed")` degradation. Per #383
    // scope, `reason` is a generic-allowlist key, so its raw value is NOT asserted absent.
    func testReservationDiagnosticsPreciseGatingRejectsNearMisses() {
        for reason in ["reservationFailed ", "reservationFailed\u{0}suffix", "reservationFailed\r"] {
            let text = diagText(reservationBlock(step: "parentBind", errno: "2", reason: reason))
            XCTAssertFalse(text.contains("param.step"), "near-miss reason must suppress step: \(reason.debugDescription)")
            XCTAssertFalse(text.contains("param.errno"), "near-miss reason must suppress errno: \(reason.debugDescription)")
        }
        for step in ["", "parentBind\u{0}suffix", "parent\rBind"] {
            let text = diagText(reservationBlock(step: step, errno: "2"))
            XCTAssertFalse(text.contains("param.step"), "near-miss step must suppress step: \(step.debugDescription)")
            XCTAssertFalse(text.contains("param.errno"), "pair-atomic: errno suppressed: \(step.debugDescription)")
            if !step.isEmpty { XCTAssertFalse(text.contains(step), "forged step text leaked: \(step.debugDescription)") }
        }
        for errno in ["2\u{0}suffix", "2\r", "\r2"] {
            let text = diagText(reservationBlock(step: "parentBind", errno: errno))
            XCTAssertFalse(text.contains("param.errno"), "near-miss errno must suppress errno: \(errno.debugDescription)")
            XCTAssertFalse(text.contains("param.step"), "pair-atomic: step suppressed: \(errno.debugDescription)")
            XCTAssertFalse(text.contains(errno), "forged errno text leaked: \(errno.debugDescription)")
        }
    }

    // (10) I2: all 8 generic allowlist keys survive END-TO-END — each emitted exactly once as a
    // full `param.<key>: <value>` line — and step/errno never ride the generic path. Kills an
    // output loop that silently drops one allowlisted key (e.g. skipping `attempts`) while the
    // array literal stays intact.
    func testAllEightGenericAllowlistKeysSurviveEndToEnd() {
        let values: [String: String] = [
            "op": "OP1", "reason": "RSN1", "field": "FLD1", "importID": "IMP1",
            "requestedImportID": "REQ1", "existingImportID": "EXI1", "attempts": "ATT1", "userVersion": "UV1",
        ]
        var params = values
        params["step"] = "parentBind"   // present but must NOT surface (code is not storeOpenFailed)
        params["errno"] = "2"
        let block = MigrationBlock(code: .ioTransient, classification: .retriable, params: params)
        let lines = diagText(block).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for key in ["op", "reason", "field", "importID", "requestedImportID",
                    "existingImportID", "attempts", "userVersion"] {
            let expected = "param.\(key): \(values[key]!)"
            XCTAssertEqual(lines.filter { $0 == expected }.count, 1, "\(expected) must appear exactly once")
        }
        let joined = lines.joined(separator: "\n")
        XCTAssertFalse(joined.contains("param.step"), "step must not ride the generic path")
        XCTAssertFalse(joined.contains("param.errno"), "errno must not ride the generic path")
    }

    // MARK: - Full-app locale parity (precise ratchet toward six-locale key equality)
    //
    // Unlike the migration-only guards above, these cover the ENTIRE key universe. The four
    // partially-translated locales (zh-Hant/ja/ko/fr) are being filled batch by batch; until they
    // are complete, each one's missing-key set must EXACTLY equal a single shared debt set. The
    // `==` (not `⊆`) is the ratchet: a NEW missing key, a locale that prematurely fills a debt key
    // out of lockstep, an unexpected extra key, or any single-locale drift all fail. Each batch
    // removes its keys from `knownLocalizationDebt` in the SAME change that adds the translations.
    // When the set is emptied, delete it and assert `missing.isEmpty` for strict six-locale parity.

    /// The remaining app-UI keys not yet translated in zh-Hant/ja/ko/fr (identical across all four).
    /// B1 filled `editor.*` (15); B2 the transaction list / filters / status (30); B5 the categories /
    /// common chrome / onboarding / boot error (9); B3 the overview dashboard (14); B4 the about pane /
    /// CSV commands / partial-import result (7); this is the residual 24. Shrinks one batch at a time.
    private static let knownLocalizationDebt: Set<String> = [
        "recovery.blank", "recovery.blankConfirm",
        "recovery.blankConfirmMessage", "recovery.blankConfirmTitle", "recovery.message",
        "recovery.restore", "recovery.retry", "recovery.safeNote", "recovery.title", "recovery.viewError",
        "settings.about", "settings.accounting", "settings.accountingLocale", "settings.accountingNote",
        "settings.appearance.dark", "settings.appearance.light", "settings.appearance.system",
        "settings.company", "settings.csv", "settings.currency", "settings.data", "settings.dbLocation",
        "settings.general", "settings.schemaVersion",
    ]

    /// URL of a locale's `Localizable.strings` (resolves the SwiftPM-lowercased `.lproj` too).
    private func localeStringsURL(_ lang: String) -> URL? {
        let path = Localizer.resourceBundle.path(forResource: lang, ofType: "lproj")
            ?? Localizer.resourceBundle.path(forResource: lang.lowercased(), ofType: "lproj")
        guard let path, let bundle = Bundle(path: path) else { return nil }
        return bundle.url(forResource: "Localizable", withExtension: "strings")
    }

    /// The KEY SET of a locale, parsed with `PropertyListSerialization` (a `.strings` file is an
    /// old-style property list). Deduplicates by nature — see `rawKeyOccurrences` for dup detection.
    private func localeKeySet(_ lang: String) -> Set<String> {
        guard let url = localeStringsURL(lang),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: String] else {
            XCTFail("\(lang): could not load Localizable.strings as a property list"); return []
        }
        return Set(dict.keys)
    }

    /// The SOURCE `Localizable.strings` URL. Xcode compiles the BUNDLED `.strings` to a binary
    /// property list, so raw-text duplicate detection must read the committed source, located
    /// relative to this test file (…/App/Tests/SoloLedgerUnitTests/<this>.swift → …/native/SoloLedger).
    private func sourceStringsURL(_ lang: String) -> URL {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { dir.deleteLastPathComponent() }
        return dir.appendingPathComponent("Sources/SoloLedger/Resources/\(lang).lproj/Localizable.strings")
    }

    /// Per-key line occurrence counts by reading the RAW SOURCE text and matching anchored key lines
    /// (`"<key>" =` at line start) in Swift — no external tools, and it sees duplicates that the
    /// property-list parser would silently collapse.
    private func rawKeyOccurrences(_ lang: String) -> [String: Int] {
        let url = sourceStringsURL(lang)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            XCTFail("\(lang): could not read source Localizable.strings as text at \(url.path)"); return [:]
        }
        let re = try! NSRegularExpression(pattern: "^\\s*\"([^\"]+)\"\\s*=")
        var counts: [String: Int] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line); let ns = s as NSString
            guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { continue }
            counts[ns.substring(with: m.range(at: 1)), default: 0] += 1
        }
        return counts
    }

    /// zh-Hans is the source of truth (`Localizer.defaultCode`); en must match it exactly; each
    /// partial locale's missing set must EXACTLY equal `knownLocalizationDebt`, with no extra keys.
    func testFullLocaleKeyUniverseRatchet() {
        let universe = localeKeySet("zh-Hans")
        XCTAssertFalse(universe.isEmpty, "zh-Hans universe must load")
        XCTAssertEqual(localeKeySet("en"), universe,
                       "en key set must exactly equal the zh-Hans source-of-truth universe")
        for lang in ["zh-Hant", "ja", "ko", "fr"] {
            let ks = localeKeySet(lang)
            let extra = ks.subtracting(universe)
            XCTAssertTrue(extra.isEmpty, "\(lang) has keys outside the universe: \(extra.sorted())")
            let missing = universe.subtracting(ks)
            XCTAssertEqual(missing, Self.knownLocalizationDebt,
                "\(lang) missing-key set must EXACTLY equal knownLocalizationDebt — " +
                "newly-missing=\(missing.subtracting(Self.knownLocalizationDebt).sorted()) " +
                "prematurely-filled=\(Self.knownLocalizationDebt.subtracting(missing).sorted())")
        }
    }

    /// Placeholder-set parity over the FULL universe: for every key, all locales that CONTAIN it
    /// must share the same `{name}` token set (debt keys exist only in en+zh-Hans and match there).
    func testFullLocalePlaceholderParityForSharedKeys() {
        let universe = localeKeySet("zh-Hans")
        let sets = Dictionary(uniqueKeysWithValues: locales.map { ($0, localeKeySet($0)) })
        for key in universe {
            var reference: Set<String>? = nil
            var referenceLang = ""
            for lang in locales where sets[lang]?.contains(key) == true {
                let ph = placeholders(rawValue(lang, key) ?? "")
                if let reference {
                    XCTAssertEqual(ph, reference, "\(lang) placeholder set for \(key) differs from \(referenceLang)")
                } else { reference = ph; referenceLang = lang }
            }
        }
    }

    /// No locale file may define the same key twice (the property-list parser would hide this).
    func testNoDuplicateKeysInAnyLocaleFile() {
        for lang in locales {
            let dups = rawKeyOccurrences(lang).filter { $0.value > 1 }.keys.sorted()
            XCTAssertTrue(dups.isEmpty, "\(lang) defines duplicate keys: \(dups)")
        }
    }

    /// The Localizer must never surface a raw key for ANY universe key in ANY locale — debt keys
    /// resolve through the zh-Hans fallback, so this also proves the fallback path stays intact.
    func testLocalizerNeverReturnsRawKeyForAnyUniverseKey() {
        let universe = localeKeySet("zh-Hans")
        for lang in locales {
            let loc = Localizer(language: lang)
            for key in universe {
                XCTAssertNotEqual(loc.t(key), key, "\(lang) Localizer returned the raw key \(key)")
            }
        }
    }
}
