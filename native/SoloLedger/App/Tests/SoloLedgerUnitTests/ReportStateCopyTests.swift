import XCTest
@testable import SoloLedger
import SoloLedgerCore

/// R8 P3c — the state and parameter-disclosure copy keys: seven blockers, the three
/// non-numeric field states, the four parameter axes, cash flow, the monthly table, notes and
/// warnings, and the page chrome.
///
/// ## Why this file carries a literal key list and `ReportStructuralCopyTests` did not
///
/// P3b's keys were all emitted by `ReportPresenter`, so that test could DERIVE them from the
/// mapping functions and no hand-written list was needed. This half is split: some keys the
/// presenter emits, and the rest the VIEW asks for directly — those the presenter never sees,
/// so nothing here can derive them. The two counts are asserted in `testStateKeyUniverse…`
/// rather than restated here, where they would rot.
///
/// A predicted key set fails in two directions and neither is caught by anything already in
/// the tree. A key P3d turns out to need but nobody wrote makes P3d add copy, which is not
/// what P3d is for. A key nobody ends up using is dead copy that six-locale parity happily
/// waves through, because it IS present in all six. ``viewLayerKeys`` plus
/// ``testEveryReportKeyInTheStringsFilesIsAccountedFor`` close both directions: the union of
/// what the presenter can emit and what this list declares must equal, exactly, the `report.*`
/// keys in the `.strings` files.
///
/// The list lives here rather than in the app target on purpose — P3c ships no production
/// code, and a test-only inventory is enough to make the universe closed.
final class ReportStateCopyTests: XCTestCase {

    private let languages = ["zh-Hans", "zh-Hant", "en", "ja", "ko", "fr"]

    // MARK: - The two halves of the universe

    /// The 37 keys `ReportPresenter` emits that P3b did not land — everything in
    /// `allEmittableKeys()` that is not a section title, block title, note or line label.
    private func presenterStateKeys() -> Set<String> {
        var structural = Set(ReportPresenter.sectionTitleKeys.values)
        structural.formUnion(ReportPresenter.undeclaredTaxInclusiveTitleKeys.values)
        structural.insert("\(ReportPresenter.keyPrefix)section.missingLines")
        structural.insert(ReportPresenter.chinaTurnoverTaxAliasNoteKey)
        for id in ReportPresenter.knownLineIDs {
            if case .key(let key) = ReportPresenter.lineLabel(for: id) { structural.insert(key) }
        }
        return ReportPresenter.allEmittableKeys().subtracting(structural)
    }

    /// The keys the report VIEW asks for and the presenter never emits. Declared, not derived —
    /// see the type's note; the count is asserted, not written down twice.
    static let viewLayerKeys: Set<String> = [
        // page chrome
        "report.page.title", "report.year.label", "report.year.invalid", "report.action.build",
        "report.notRequested.title", "report.notRequested.message",
        "report.error.title", "report.error.message",
        "report.action.retry", "report.action.openSettings", "report.action.openSettings.hint",
        "report.currency.caption", "report.currency.note", "report.currency.formatNote",
        "report.period.caption", "report.estimate.badge",
        // the stored-setting preview's heading
        "report.storedText.label",
        // the facts a blocked page states without claiming them as a repair
        "report.blocker.storedCurrency", "report.blocker.periodCurrencies",
        "report.blocker.regimeDefaultCurrency",
        // the parameter table's own chrome
        "report.params.title", "report.params.axis.stored", "report.params.axis.effect",
        "report.params.axis.consumption",
        // cash flow
        "report.cashflow.title", "report.cashflow.operating.title",
        "report.cashflow.inflow", "report.cashflow.outflow", "report.cashflow.net",
        "report.cashflow.investing", "report.cashflow.financing",
        "report.cashflow.beginningCash", "report.cashflow.endingCash",
        "report.cashflow.basisNote", "report.cashflow.vsProfitNote",
        // the monthly table
        "report.monthly.title", "report.monthly.month", "report.monthly.revenue",
        "report.monthly.cost", "report.monthly.profit",
        // grouping headings
        "report.notes.title", "report.warnings.title",
        // the four disclaimers, added by the view PR. They live in the `report.*` namespace and
        // the presenter does not emit them, so they are claimed here — which is exactly what
        // this list is for, and what made the closure test go red until they were.
        "report.disclaimer.report", "report.disclaimer.tax",
        "report.disclaimer.usTax", "report.disclaimer.rates",
    ]

    private func stateKeys() -> Set<String> {
        presenterStateKeys().union(Self.viewLayerKeys)
    }

    private func value(_ language: String, _ key: String) -> String {
        Localizer(language: language).t(key)
    }

    /// Every `report.*` key present in a locale's committed `.strings`, read as a property list.
    private func reportKeysInStrings(_ language: String) -> Set<String> {
        let path = Localizer.resourceBundle.path(forResource: language, ofType: "lproj")
            ?? Localizer.resourceBundle.path(forResource: language.lowercased(), ofType: "lproj")
        guard let path, let bundle = Bundle(path: path),
              let url = bundle.url(forResource: "Localizable", withExtension: "strings"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [],
                                                                     format: nil),
              let dict = plist as? [String: String] else {
            XCTFail("\(language): could not load Localizable.strings"); return []
        }
        return Set(dict.keys.filter { $0.hasPrefix(ReportPresenter.keyPrefix) })
    }

    // MARK: - C2 — the universe is exactly 83, split 37 / 46

    func testStateKeyUniverseIsExactlyTheTwoDisjointHalves() {
        XCTAssertEqual(presenterStateKeys().count, 37)
        XCTAssertEqual(Self.viewLayerKeys.count, 46)
        XCTAssertEqual(stateKeys().count, 83, "37 presenter-emitted + 46 view-layer")
        XCTAssertTrue(presenterStateKeys().isDisjoint(with: Self.viewLayerKeys),
                      "a key is emitted by the presenter or declared by the view, never both")
    }

    // MARK: - C3 — the `report.*` namespace is closed in BOTH directions

    /// Stale copy and missing copy are the two ways a predicted key set goes wrong, and six-locale
    /// parity catches neither: a key nobody uses is present in all six, and a key nobody wrote is
    /// absent from all six. This is the assertion that does catch them.
    func testEveryReportKeyInTheStringsFilesIsAccountedFor() {
        let accounted = ReportPresenter.allEmittableKeys().union(Self.viewLayerKeys)
        for language in languages {
            let onDisk = reportKeysInStrings(language)
            XCTAssertEqual(onDisk, accounted, """
                \(language): the report copy and the code disagree.
                in the file, used by nothing (delete it): \(onDisk.subtracting(accounted).sorted())
                asked for by code, not written (add it): \(accounted.subtracting(onDisk).sorted())
                """)
        }
        // 82 structural (P3b) + 79 state (P3c) + 4 disclaimers (P3d)
        XCTAssertEqual(accounted.count, 165)
    }

    // MARK: - C1 — every key resolves, in all six languages

    func testEveryStateKeyResolvesInAllSixLocales() {
        let keys = stateKeys().sorted()
        for language in languages {
            let localizer = Localizer(language: language)
            for key in keys {
                let resolved = localizer.t(key)
                XCTAssertNotEqual(resolved, key, "\(language) leaks the raw key \(key)")
                XCTAssertFalse(resolved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                               "\(language)/\(key) is blank")
            }
        }
    }

    // MARK: - C4 — the statutory guard needs a SPACE in "Cash Flow Statement"

    /// `(?i)Cash Flow Statement` is a literal with a space in it, so `cash-flow statement`
    /// slips past. Electron's own basis note relies on exactly that, and this app deliberately
    /// does NOT: its English says "not a statutory statement", so the copy is legal on its own
    /// terms rather than on a hyphen.
    ///
    /// The assertion stays anyway, in both directions, because the next person to write English
    /// cash-flow copy needs to know which of those two facts they are standing on.
    func testTheStatutoryGuardRequiresASpaceInCashFlowStatement() throws {
        let regex = try NSRegularExpression(pattern: #"(?i)Cash Flow Statement"#)
        func matches(_ text: String) -> Bool {
            regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
        XCTAssertTrue(matches("Cash Flow Statement"))
        XCTAssertTrue(matches("a statutory cash flow statement"))
        XCTAssertFalse(matches("cash-flow statement"),
                       "the hyphenated spelling does not match — do not build copy on this")

        // This app's own note does not depend on that gap.
        let note = value("en", "report.cashflow.basisNote")
        XCTAssertFalse(matches(note))
        XCTAssertFalse(note.lowercased().contains("cash-flow statement"),
                       "the English note must be legal on its own wording, not on a hyphen")
    }

    // MARK: - C5 — "not read here" must never read as "you have not configured it"

    func testStoredButUnreadNeverReadsAsNotConfigured() {
        let unread = "\(ReportPresenter.keyPrefix)param.consumption.storedButUnread"
        let absent = "\(ReportPresenter.keyPrefix)param.stored.absent"
        let forbidden = ["未配置", "未設定", "미설정", "not configured", "non configuré"]
        for language in languages {
            let text = value(language, unread)
            for word in forbidden {
                XCTAssertFalse(text.lowercased().contains(word.lowercased()),
                               "\(language): storedButUnread must not say “\(word)” — the row may "
                               + "well be set; nothing here reads it")
            }
            XCTAssertNotEqual(text, value(language, absent),
                              "\(language): “nothing reads this” and “the ledger has no such row” "
                              + "are different facts")
        }
    }

    // MARK: - C6 — the legacy refusal neither asserts nor denies that there was business

    /// A naive ban on 没有业务 would fail the approved copy, because it appears inside
    /// 「无法判断该期间确实没有业务，还是……」 — an explicit statement of NOT knowing. So the
    /// assertion is a pair: the confident phrasing must be absent, and the uncertainty must be
    /// present.
    func testLegacyRefusalNeitherAssertsNorDeniesBusiness() {
        let key = "\(ReportPresenter.keyPrefix)blocker.legacySourceUnavailable.body"
        let asserted = ["本期无数据", "本期無資料", "no data", "データなし", "데이터 없음", "aucune donnée"]
        let uncertainty = ["无法判断", "無法判斷", "cannot tell whether", "判断できません",
                           "판단할 수 없습니다", "ne peut donc pas déterminer"]
        let untouched = ["账本文件未被修改", "帳本檔案未被修改", "was not modified",
                         "変更されていません", "변경되지 않았습니다", "n'a pas été modifié"]
        for (index, language) in languages.enumerated() {
            let text = value(language, key)
            for word in asserted {
                XCTAssertFalse(text.lowercased().contains(word.lowercased()),
                               "\(language): must not claim the period is empty — it cannot know")
            }
            XCTAssertTrue(text.contains(uncertainty[index]),
                          "\(language): must say it CANNOT TELL, not merely that it found nothing")
            XCTAssertTrue(text.contains(untouched[index]),
                          "\(language): must say the ledger file was not modified")
        }
    }

    // MARK: - C7 — every refusal says the ledger was left alone

    /// A blocked report is the moment a user most easily concludes their data is damaged. All
    /// seven say otherwise.
    func testEveryBlockerBodyStatesTheLedgerWasNotModified() {
        let untouched = ["账本文件未被修改", "帳本檔案未被修改", "was not modified",
                         "変更されていません", "변경되지 않았습니다", "n'a pas été modifié"]
        for blocker in ReportPresenter.allBlockerRepresentatives {
            let body = ReportPresenter.copy(for: blocker).bodyKey
            for (index, language) in languages.enumerated() {
                XCTAssertTrue(value(language, body).contains(untouched[index]),
                              "\(language)/\(body) does not state the ledger was left alone")
            }
        }
    }

    // MARK: - C8 — only the two accounting-profile refusals point anywhere

    func testOnlyTheTwoLocaleBlockersOfferSettingsAndTheOthersPromiseNothing() {
        let actions = ReportPresenter.allBlockerRepresentatives.map {
            ReportPresenter.copy(for: $0).action
        }
        XCTAssertEqual(actions.filter { $0 == .openSettings }.count, 2)
        XCTAssertEqual(actions.filter { $0 == .none }.count, 5)

        // The five with no control must not describe one either. Settings holds the accounting
        // profile and NOT the currency, and nothing anywhere can undo a legacy-source refusal;
        // copy that suggests otherwise would be the fake repair the design forbids.
        let actionWords = ["打开设置", "開啟設定", "open settings", "設定を開く", "설정 열기",
                           "ouvrir les réglages", "重试", "重試", "retry", "再試行", "재시도", "réessayer"]
        for blocker in ReportPresenter.allBlockerRepresentatives
        where ReportPresenter.copy(for: blocker).action == ReportPresenter.BlockerAction.none {
            let body = ReportPresenter.copy(for: blocker).bodyKey
            for language in languages {
                let text = value(language, body).lowercased()
                for word in actionWords {
                    XCTAssertFalse(text.contains(word.lowercased()),
                                   "\(language)/\(body) offers “\(word)” but has no control")
                }
            }
        }
    }

    // MARK: - C13 — the two retired over-claims may not come back

    /// Both sentences were true when they were written and both stopped being true later.
    ///
    /// "This app does not provide financial reports yet" died the moment P3e put the report page
    /// in the sidebar. "This app has no way to change the currency" was never quite right:
    /// Settings holds no currency control, but switching the accounting profile runs
    /// `applyRegimeSwitch`, which writes the regime, its preset rates AND its currency in one
    /// transaction — so the ledger's currency does change, from a screen the copy said could not
    /// change it.
    ///
    /// Ratcheted on the WHOLE retired sentence, per locale, rather than on keywords: "yet",
    /// "currency" and "provide" all have legitimate uses in this copy, and a keyword ban would
    /// fail the replacement text it is supposed to protect.
    func testTheRetiredOverclaimsDoNotComeBack() {
        let retiredPending = ["本 App 尚未提供财务报表功能", "本 App 尚未提供財務報表功能",
                              "does not provide financial reports yet",
                              "まだ財務帳票を提供していません", "아직 재무 보고서를 제공하지 않습니다",
                              "ne propose pas encore de rapports financiers"]
        let retiredCurrency = ["没有修改币种的入口", "沒有修改幣別的入口",
                               "no way to change the currency",
                               "通貨を変更する手段がありません", "통화를 변경하는 방법이 없습니다",
                               "ne permet pas encore de changer la devise"]
        for (index, language) in languages.enumerated() {
            XCTAssertFalse(value(language, "settings.reportParamsPending")
                .contains(retiredPending[index]),
                "\(language): the parameters note must not deny that the report page exists")
            for key in ["\(ReportPresenter.keyPrefix)blocker.currencyNotConfigured.body",
                        "\(ReportPresenter.keyPrefix)blocker.currencyInvalid.body"] {
                XCTAssertFalse(value(language, key).contains(retiredCurrency[index]),
                    "\(language)/\(key) claims the currency cannot be changed — switching the "
                    + "accounting profile rewrites it")
            }
        }
    }

    // MARK: - C9 — no two keys in one region render the same label

    /// The extension of P3b's collision check. The regions below are the ones where two labels
    /// really do sit side by side; a repeat there is ambiguity, not consistency.
    func testNoTwoKeysInOneUIRegionRenderTheSameLabel() {
        let P = ReportPresenter.keyPrefix
        let regions: [String: [String]] = [
            "parameter axes": ["\(P)params.axis.stored", "\(P)params.axis.effect",
                               "\(P)params.axis.consumption"],
            "parameter names": ReportParameterKey.allCases.map(ReportPresenter.nameKey(for:)),
            "stored states": [StoredSettingState.absent, .usable(1), .needsRepair(storedText: "x")]
                .map(ReportPresenter.storedKey(for:)),
            "effect states": [ParameterEffect.appliedValue(1, origin: .storedValue),
                              .appliedNonFinite, .refused(.incomeTaxRate)]
                .map(ReportPresenter.effectKey(for:)),
            "effect origins": [EffectOrigin.storedValue, .regimeDefault, .dispatcherFallback]
                .map(ReportPresenter.originKey(for:)),
            "consumption": [ParameterConsumption.consumed, .storedButUnread]
                .map(ReportPresenter.consumptionKey(for:)),
            "field states": ["\(P)field.corrupted", "\(P)field.notConfigured", "\(P)field.needsRepair"],
            "cash-flow regions": ["\(P)cashflow.operating.title", "\(P)cashflow.investing",
                                  "\(P)cashflow.financing", "\(P)cashflow.beginningCash",
                                  "\(P)cashflow.endingCash"],
            "cash-flow rows": ["\(P)cashflow.inflow", "\(P)cashflow.outflow", "\(P)cashflow.net"],
            "monthly columns": ["\(P)monthly.month", "\(P)monthly.revenue", "\(P)monthly.cost",
                                "\(P)monthly.profit"],
            "blocker titles": ReportPresenter.allBlockerRepresentatives
                .map { ReportPresenter.copy(for: $0).titleKey },
            "blocker facts": ["\(P)blocker.storedCurrency", "\(P)blocker.periodCurrencies",
                              "\(P)blocker.regimeDefaultCurrency"],
        ]
        for (region, keys) in regions {
            for language in languages {
                var byText: [String: [String]] = [:]
                for key in keys { byText[value(language, key), default: []].append(key) }
                for (text, sharing) in byText where sharing.count > 1 {
                    XCTFail("\(region) [\(language)]: \(sharing.sorted()) all render as “\(text)”")
                }
            }
        }
    }

    /// The monthly table sums ALL expense rows (`cn.js:99`), while the P&L's cost line is COGS
    /// only (`cn.js:28`); its profit is revenue minus every expense, where the P&L's net profit
    /// is after surcharge, shipping, admin expense and income tax. Two different quantities may
    /// not share a label, or the same page shows one name over two numbers.
    ///
    /// `monthly.revenue` is exempt from the rewrite and must stay exempt — but exempt does NOT
    /// mean byte-identical to `salesRevenue`. The two are the same quantity over different
    /// windows, and the monthly table legitimately uses the shorter column spelling the source
    /// already had (`Revenue` / `売上` / `CA` against the statement's `Sales Revenue` /
    /// `売上高` / `Chiffre d'affaires`). What must hold is that revenue was not dragged into
    /// the "total / difference" family with the other two columns.
    func testTheMonthlyColumnsDoNotBorrowTheProfitAndLossLabels() {
        let P = ReportPresenter.keyPrefix
        for language in languages {
            for (monthly, pl) in [("\(P)monthly.cost", "costOfSales"),
                                  ("\(P)monthly.profit", "netProfit")] {
                guard case .key(let plKey) = ReportPresenter.lineLabel(for: pl) else {
                    XCTFail("\(pl) must be a known line"); continue
                }
                XCTAssertNotEqual(value(language, monthly), value(language, plKey),
                                  "\(language): \(monthly) and \(plKey) are different quantities")
            }
            XCTAssertNotEqual(value(language, "\(P)monthly.revenue"),
                              value(language, "\(P)monthly.cost"),
                              "\(language): revenue must not read as a total of expenses")
            XCTAssertNotEqual(value(language, "\(P)monthly.revenue"),
                              value(language, "\(P)monthly.profit"),
                              "\(language): revenue must not read as a difference")
        }
    }

    // MARK: - C10 / C11 — the placeholder contracts

    /// The presenter's own contract, checked exactly: a key it emits carries the tokens
    /// `requiredPlaceholders` declares and no others. This is what catches copy that quietly
    /// grows a `{parameter}` the substitution layer would never fill.
    func testPresenterKeyPlaceholdersMatchTheContractExactly() {
        for key in presenterStateKeys() {
            let declared = ReportPresenter.requiredPlaceholders[key] ?? []
            for language in languages {
                XCTAssertEqual(placeholders(in: value(language, key)), declared,
                               "\(language)/\(key): copy tokens disagree with the contract")
            }
        }
    }

    /// `requiredPlaceholders` covers only what the presenter emits, so the view-layer keys carry
    /// their contract here.
    func testViewLayerPlaceholdersAreDeclaredAndConsistent() {
        let P = ReportPresenter.keyPrefix
        let declared: [String: Set<String>] = [
            "\(P)currency.caption": ["{currency}"],
            "\(P)period.caption": ["{from}", "{to}"],
            "\(P)blocker.storedCurrency": ["{currency}"],
            "\(P)blocker.periodCurrencies": ["{codes}"],
            "\(P)blocker.regimeDefaultCurrency": ["{currency}"],
        ]
        for key in Self.viewLayerKeys {
            let want = declared[key] ?? []
            for language in languages {
                XCTAssertEqual(placeholders(in: value(language, key)), want,
                               "\(language)/\(key): view-layer tokens disagree with this contract")
            }
        }
    }

    private func placeholders(in text: String) -> Set<String> {
        let regex = try! NSRegularExpression(pattern: #"\{[A-Za-z]+\}"#)
        let range = NSRange(text.startIndex..., in: text)
        return Set(regex.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        })
    }

    // MARK: - Two disclosures the design turns on

    /// A rate the app chose on the user's behalf and a dispatcher fallback of 0 are different
    /// facts, and only the first has to be disclosed. Different keys is not enough — the copy
    /// has to actually say the different things.
    func testTheRegimeDefaultDisclosureNamesThePercentAndTheFallbackDoesNot() {
        let regime = ReportPresenter.originKey(for: .regimeDefault)
        let fallback = ReportPresenter.originKey(for: .dispatcherFallback)
        for language in languages {
            XCTAssertTrue(value(language, regime).contains("{percent}"),
                          "\(language): the disclosure must name the percent that was applied")
            XCTAssertFalse(value(language, fallback).contains("{percent}"))
            XCTAssertNotEqual(value(language, regime), value(language, fallback))
        }
        XCTAssertTrue(value("zh-Hans", regime).contains("未保存用户值"))
        XCTAssertTrue(value("zh-Hans", fallback).contains("真实的零"))
    }

    /// "Cannot be derived" is not "zero", and the copy says so in as many words.
    func testTheNotDerivableNoteDeniesThatItMeansZero() {
        let key = "\(ReportPresenter.keyPrefix)cashflow.notDerivable"
        XCTAssertTrue(value("zh-Hans", key).contains("这不是零"))
        XCTAssertTrue(value("zh-Hant", key).contains("這不是零"))
        XCTAssertTrue(value("en", key).lowercased().contains("not zero"))
        XCTAssertTrue(value("ja", key).contains("ゼロではありません"))
        XCTAssertTrue(value("ko", key).contains("0이 아닙니다"))
        XCTAssertTrue(value("fr", key).lowercased().contains("pas zéro"))
    }

    /// The currency disclosure must not claim a validation this app never performs.
    func testTheCurrencyNoteClaimsNoValidation() {
        let P = ReportPresenter.keyPrefix
        for key in ["\(P)currency.note", "\(P)currency.formatNote"] {
            for language in languages {
                let text = value(language, key).lowercased()
                for claim in ["iso 4217", "iso4217"] where text.contains(claim) {
                    XCTFail("\(language)/\(key) claims an ISO check this app does not do")
                }
            }
        }
    }

    // MARK: - C12 — the entry point names the page it opens

    /// The sidebar row and the page's own title are two different keys, and they carry the SAME
    /// string. The other three sections use ONE key for both, so equal text here is what
    /// reproduces their behaviour; differing text would make reports the only section whose
    /// sidebar row and window title disagree.
    func testTheSidebarLabelMatchesThePageTitleVerbatim() {
        XCTAssertEqual(SidebarSection.allCases.map(\.rawValue),
                       ["overview", "transactions", "categories", "products", "inventory",
                        "documents", "reports"])
        for language in languages {
            XCTAssertEqual(value(language, "nav.reports"),
                           value(language, "report.page.title"),
                           "\(language): the sidebar entry and the page title must be identical")
        }
    }

    /// 2b-A4 adds the second section built this way, and it follows the same rule for the same
    /// reason: one key for the sidebar row, one for the window title, and the two carry the
    /// identical string. A separate proposition from the one above — the two sections can break
    /// independently, and a single test covering both would report only the first.
    func testTheProductsSidebarLabelMatchesItsPageTitleVerbatim() {
        for language in languages {
            XCTAssertEqual(value(language, "nav.products"),
                           value(language, "product.page.title"),
                           "\(language): the sidebar entry and the page title must be identical")
            XCTAssertNotEqual(value(language, "nav.products"), "nav.products",
                              "\(language): nav.products leaks the raw key")
        }
    }
}
