import Foundation

/// A row of the `categories` table (the classification dimension for
/// income/expense). Localized labels are data-driven from the DB, keyed by the
/// active UI language.
public struct Category: Identifiable, Hashable, Sendable {
    public let id: String
    public let locale: String          // accounting locale (CN/US/JP/EU/KR/TW)
    public let type: TransactionType
    public let slug: String
    public let labelZhCN: String
    public let labelZhTW: String?
    public let labelEN: String
    public let labelJA: String?
    public let labelKO: String?
    public let labelFR: String?
    public let scheduleLine: String?
    public let isCOGS: Bool
    public let sortOrder: Int

    public init(id: String, locale: String, type: TransactionType, slug: String,
                labelZhCN: String, labelZhTW: String?, labelEN: String,
                labelJA: String?, labelKO: String?, labelFR: String?,
                scheduleLine: String?, isCOGS: Bool, sortOrder: Int) {
        self.id = id; self.locale = locale; self.type = type; self.slug = slug
        self.labelZhCN = labelZhCN; self.labelZhTW = labelZhTW; self.labelEN = labelEN
        self.labelJA = labelJA; self.labelKO = labelKO; self.labelFR = labelFR
        self.scheduleLine = scheduleLine; self.isCOGS = isCOGS; self.sortOrder = sortOrder
    }

    /// Localized label for a UI language code (Apple-style: zh-Hans/zh-Hant/en/ja/ko/fr).
    /// Falls back to English, then Simplified Chinese (the source of truth).
    public func label(for languageCode: String) -> String {
        switch languageCode {
        case "zh-Hans", "zh-CN": return labelZhCN
        case "zh-Hant", "zh-TW": return nonEmpty(labelZhTW) ?? labelZhCN
        case "ja": return nonEmpty(labelJA) ?? labelEN
        case "ko": return nonEmpty(labelKO) ?? labelEN
        case "fr": return nonEmpty(labelFR) ?? labelEN
        case "en": return labelEN
        default: return labelEN
        }
    }

    private func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    static func from(_ row: SQLiteRow) -> Category? {
        guard let id = row.string("id"),
              let locale = row.string("locale"),
              let typeRaw = row.string("type"),
              let type = TransactionType(rawValue: typeRaw),
              let slug = row.string("slug"),
              let labelZhCN = row.string("label_zh_cn"),
              let labelEN = row.string("label_en") else { return nil }
        return Category(
            id: id, locale: locale, type: type, slug: slug,
            labelZhCN: labelZhCN, labelZhTW: row.string("label_zh_tw"), labelEN: labelEN,
            labelJA: row.string("label_ja"), labelKO: row.string("label_ko"), labelFR: row.string("label_fr"),
            scheduleLine: row.string("schedule_line"),
            isCOGS: (row.int("is_cogs") ?? 0) == 1,
            sortOrder: row.int("sort_order") ?? 0
        )
    }
}
