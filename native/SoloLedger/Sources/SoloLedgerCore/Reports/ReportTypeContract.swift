import Foundation

/// One entry of `reportTypes` — every engine's fourth top-level key
/// (`cn.js reportTypes`, `jp.js reportTypes`, `eu.js reportTypes`, `kr.js reportTypes`, `tw.js reportTypes`, `us.js reportTypes`).
///
/// The `id` is a stable identifier. The `name` map is HISTORICAL COPY and is
/// mirrored verbatim, gaps and all — see ``ReportTypeEntry/name``.
struct ReportTypeEntry: Equatable, Sendable {
    let id: String

    /// The engine's own `name` map, byte for byte, INCLUDING what is wrong with it.
    ///
    /// **This is not display copy and must not be rendered.** The app ships six UI
    /// languages; no entry here carries more than three, and the batch that
    /// reviewed this copy (R5) recorded four separate defects in it rather than
    /// repairing them, because repairing them means writing wording — a
    /// jurisdiction/translation decision CLAUDE.md reserves for a human, and
    /// because these strings live in `electron/reports/*`, which this phase does
    /// not touch.
    ///
    /// ## What is wrong with it, each pinned by a test
    ///
    /// 1. **Sparse.** CN and US carry `zh-CN` + `en`; JP adds `ja`, EU adds `fr`,
    ///    KR adds `ko`, TW adds `zh-TW`. Four to five of the six UI languages are
    ///    missing from every entry. **Nothing is backfilled here** — a map with a
    ///    key is a string the engine really emits, and a map without one is a fact
    ///    about the engine, not a hole to plug.
    /// 2. **`jp.js`'s `zh-CN` slot holds Japanese.** Both JP values are
    ///    byte-identical to their own `ja` sibling: `消費税概要` uses the
    ///    traditional 費 (U+8CBB) where Simplified Chinese is 消费税概要, and
    ///    `損益計算書` is Japanese throughout. A zh-CN reader on a Japan ledger
    ///    would be shown Japanese.
    /// 3. **`eu.js`'s `vat-return` says 申报** (`"VAT 申报概要"`) — the filing word
    ///    that `scripts/check-tax-labels.mjs:22` bans on every other user-facing
    ///    tax label in the product. That guard does not read `electron/reports/`,
    ///    which is why it never fired.
    /// 4. **It contradicts the shipped UI copy for the same concept.** CN
    ///    `vat-summary` is `"VAT Summary"` here and `"VAT Statistics"` in
    ///    `components/accountingLocaleConfig.ts:194`; KR `vat-summary` is
    ///    `"附加价值税概要"` here and `"韩国 VAT 统计"` there.
    ///
    /// Today nothing renders it: no `.tsx`, no handler and no Swift view reads
    /// `reportTypes[].name` — only `scripts/test-handlers.mjs:1953` asserts the
    /// array is non-empty. R8 supplies its own reviewed six-language strings and
    /// uses ``ReportTypes/availability(for:locale:)`` to decide what may be shown
    /// at all. Deliberately, there is **no `name(for language:)` accessor here**:
    /// any such helper would have to invent a fallback, and inventing a fallback is
    /// how historical copy escapes into a UI.
    let name: [String: String]

    init(id: String, name: [String: String]) {
        self.id = id
        self.name = name
    }
}

/// How much of a report type the native mirror can actually produce today.
///
/// **The gate plan §7.3 requires.** After batches 1–4 the China income statement
/// has no pre-tax profit, no income tax and no net profit; rendering it beside a
/// complete-looking title is exactly the "貌似完整的中国损益表" the plan forbids.
/// A caller that switches over this enum cannot forget the case, whereas a caller
/// handed a bare list of report types has nothing to forget.
///
/// The three cases are defined AGAINST THE GOLDENS, not against intent, so they
/// can be checked by machine rather than believed:
/// `ReportBatch4ParityTests.testAvailabilityMatchesWhatTheGoldensShowIsMirrored`
/// derives them from the committed golden blocks and asserts the table below.
enum ReportTypeAvailability: Equatable, Sendable {
    /// Every field the golden block carries is produced by the native mirror.
    case mirrored
    /// Some fields are produced and some are not. **Rendering this as a finished
    /// statement is the plan §7.3 violation**; a caller must either withhold the
    /// report or mark the missing lines as not-yet-provided.
    case truncated
    /// No field of this report type is mirrored yet.
    case absent
}

/// The six engines' `reportTypes` arrays, mirrored verbatim.
enum ReportTypes {

    /// `cn.js reportTypes`.
    static let cn: [ReportTypeEntry] = [
        ReportTypeEntry(id: "income-statement",
                        name: ["zh-CN": "损益表（利润表）", "en": "Income Statement (P&L)"]),
        ReportTypeEntry(id: "vat-summary",
                        name: ["zh-CN": "增值税统计", "en": "VAT Summary"]),
        // ONLY China declares this one, although all five VAT engines emit a
        // `taxInclusiveSummary` block. Mirrored as-is: the asymmetry is the
        // source's, and "add the missing entry" would be authoring a report type.
        ReportTypeEntry(id: "tax-inclusive",
                        name: ["zh-CN": "含税金额汇总", "en": "Tax-Inclusive Summary"]),
    ]

    /// `jp.js reportTypes`. Both `zh-CN` values are the `ja` value — defect 2 above.
    static let jp: [ReportTypeEntry] = [
        ReportTypeEntry(id: "income-statement",
                        name: ["zh-CN": "損益計算書", "en": "Income Statement (P&L)", "ja": "損益計算書"]),
        ReportTypeEntry(id: "consumption-tax",
                        name: ["zh-CN": "消費税概要", "en": "Consumption Tax Summary", "ja": "消費税概要"]),
    ]

    /// `eu.js reportTypes`. `vat-return`'s `zh-CN` carries 申报 — defect 3 above.
    static let eu: [ReportTypeEntry] = [
        ReportTypeEntry(id: "profit-loss",
                        name: ["zh-CN": "损益表", "en": "Profit & Loss", "fr": "Compte de résultat"]),
        ReportTypeEntry(id: "vat-return",
                        name: ["zh-CN": "VAT 申报概要", "en": "VAT Return Summary", "fr": "Déclaration TVA"]),
    ]

    /// `kr.js reportTypes`.
    static let kr: [ReportTypeEntry] = [
        ReportTypeEntry(id: "income-statement",
                        name: ["zh-CN": "损益计算书", "en": "Income Statement", "ko": "손익계산서"]),
        ReportTypeEntry(id: "vat-summary",
                        name: ["zh-CN": "附加价值税概要", "en": "VAT Summary", "ko": "부가가치세 요약"]),
    ]

    /// `tw.js reportTypes`.
    static let tw: [ReportTypeEntry] = [
        ReportTypeEntry(id: "income-statement",
                        name: ["zh-CN": "损益表", "en": "Income Statement", "zh-TW": "損益表"]),
        ReportTypeEntry(id: "business-tax",
                        name: ["zh-CN": "营业税概要", "en": "Business Tax Summary", "zh-TW": "營業稅概要"]),
    ]

    /// `us.js reportTypes`. The `zh-CN` strings use FULLWIDTH parentheses (U+FF08/U+FF09).
    static let us: [ReportTypeEntry] = [
        ReportTypeEntry(id: "schedule-c",
                        name: ["zh-CN": "Schedule C（个体经营损益）", "en": "Schedule C (Profit or Loss)"]),
        ReportTypeEntry(id: "se-tax",
                        name: ["zh-CN": "Self-Employment Tax 估算", "en": "Self-Employment Tax Estimate"]),
    ]

    /// The table for an accounting locale, or `nil` for one no engine serves.
    ///
    /// `nil` rather than an empty array: `index.js generate` THROWS on an unknown
    /// locale, so "no report types" is not a state the source can reach, and
    /// returning `[]` would let a caller render an empty picker for a ledger that
    /// should have been rejected.
    static func table(for locale: String) -> [ReportTypeEntry]? {
        switch locale {
        case "CN": return cn
        case "US": return us
        case "JP": return jp
        case "EU": return eu
        case "KR": return kr
        case "TW": return tw
        default:   return nil
        }
    }

    /// How much of `id` under `locale` the native mirror produces today.
    ///
    /// Hand-written rather than computed, because the thing being stated is which
    /// Swift code EXISTS — and that is not derivable at run time from a type that
    /// has not been written. The parity test closes the loop by deriving the same
    /// answer from the goldens and comparing.
    ///
    /// **R7 moved every row to `.mirrored`**, and the two halves of that move were
    /// defended very differently — worth keeping, because the weaker one will be
    /// the shape of the next `.absent` row somebody adds.
    ///
    /// For the five formerly-`.truncated` rows the test **forced** the update: their
    /// structs are wired into its reflection switch, so widening one made the derived
    /// answer `.mirrored` and the assertion failed until this table agreed. Seven
    /// assertions went red the moment the structs grew, which is exactly what should
    /// have happened.
    ///
    /// For `se-tax` it did NOT. A switch cannot notice a type that did not exist when
    /// it was written, so `ReportBatch4ParityTests.mirroredFieldNames` had to gain its
    /// `("US", "se-tax")` branch BY HAND alongside this line. Had both been forgotten,
    /// every test would still have passed and R8 would simply never have rendered the
    /// self-employment tax. Only changing one of the two goes red — which is the safe
    /// failure and the reason to change them in the same edit.
    static func availability(for id: String, locale: String) -> ReportTypeAvailability {
        switch (locale, id) {
        // Batch 4 (R5) — the whole turnover-tax block, every field.
        case ("CN", "vat-summary"), ("JP", "consumption-tax"), ("EU", "vat-return"),
             ("KR", "vat-summary"), ("TW", "business-tax"):
            return .mirrored
        // Batch 2 (R3) — China is the only regime that declares this report type.
        case ("CN", "tax-inclusive"):
            return .mirrored
        // Batch 3 (R4) — all 25 Schedule C lines.
        case ("US", "schedule-c"):
            return .mirrored
        // Batch 1 (R2) reached gross profit; batch 5 (R7) added the estimate lines
        // below it — income tax, net profit, net margin, and China's surcharge
        // chain — so these blocks are now complete.
        case ("CN", "income-statement"), ("JP", "income-statement"),
             ("EU", "profit-loss"), ("KR", "income-statement"),
             ("TW", "income-statement"):
            return .mirrored
        // Batch 5 (R7). Both `selfEmploymentTax` and the `estimatedTax` block it
        // feeds are mirrored; only the former has a report-type id.
        case ("US", "se-tax"):
            return .mirrored
        default:
            // An id/locale pair no engine emits. `.absent` is the only honest
            // answer: the caller asked about a report that does not exist here.
            return .absent
        }
    }
}
