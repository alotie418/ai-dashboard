import Foundation

/// Swift port of `electron/db/seedCategories.js` — the 78 pre-seeded accounting
/// categories across 6 accounting locales (CN/US/JP/EU/KR/TW). `id` convention
/// is `{locale}-{type}-{slug}`. Inserted by migration v4 with `is_system = 1` and
/// WITHOUT `is_cogs` (v13 backfills that), exactly mirroring the JS seed.
public struct SeedCategory {
    public let id, locale, type, slug: String
    public let labelZhCN, labelZhTW, labelEN, labelJA, labelKO, labelFR: String
    public let scheduleLine: String
    public let sortOrder: Int
    public let deductiblePct: Double
}

public enum CategorySeed {

    /// Insert all seed rows (idempotent via `INSERT OR IGNORE` + UNIQUE(locale,type,slug)).
    public static func seed(into db: SQLiteDatabase) throws {
        let sql = """
            INSERT OR IGNORE INTO categories
              (id, locale, type, slug, label_zh_cn, label_zh_tw, label_en, label_ja, label_ko, label_fr,
               schedule_line, is_deductible, deductible_pct, sort_order, is_system)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,1,?,?,1)
            """
        for c in all {
            try db.run(sql, [
                .text(c.id), .text(c.locale), .text(c.type), .text(c.slug),
                .text(c.labelZhCN), .text(c.labelZhTW), .text(c.labelEN),
                .text(c.labelJA), .text(c.labelKO), .text(c.labelFR),
                .text(c.scheduleLine), .real(c.deductiblePct), .integer(Int64(c.sortOrder)),
            ])
        }
    }

    private static func c(_ id: String, _ locale: String, _ type: String, _ slug: String,
                          _ zhCN: String, _ zhTW: String, _ en: String, _ ja: String, _ ko: String, _ fr: String,
                          _ schedule: String, _ sort: Int, _ ded: Double = 100) -> SeedCategory {
        SeedCategory(id: id, locale: locale, type: type, slug: slug,
                     labelZhCN: zhCN, labelZhTW: zhTW, labelEN: en, labelJA: ja, labelKO: ko, labelFR: fr,
                     scheduleLine: schedule, sortOrder: sort, deductiblePct: ded)
    }

    public static let all: [SeedCategory] = [
        // ===================== CN =====================
        c("cn-income-sales", "CN", "income", "sales", "主营业务收入", "主營業務收入", "Sales Revenue", "売上高", "매출", "Chiffre d'affaires", "损益表-营业收入", 10),
        c("cn-income-other", "CN", "income", "other-revenue", "其他业务收入", "其他業務收入", "Other Revenue", "営業外収益", "기타영업수익", "Autres produits", "损益表-其他业务收入", 20),
        c("cn-income-interest", "CN", "income", "interest", "利息收入", "利息收入", "Interest Income", "受取利息", "이자수익", "Produits financiers", "损益表-财务收入", 30),
        c("cn-expense-cogs", "CN", "expense", "cogs", "营业成本", "營業成本", "Cost of Goods Sold", "売上原価", "매출원가", "Coût des marchandises", "损益表-营业成本", 10),
        c("cn-expense-selling", "CN", "expense", "selling", "销售费用", "銷售費用", "Selling Expense", "販売費", "판매비", "Frais commerciaux", "损益表-销售费用", 20),
        c("cn-expense-admin", "CN", "expense", "admin", "管理费用", "管理費用", "Administrative Expense", "一般管理費", "관리비", "Frais administratifs", "损益表-管理费用", 30),
        c("cn-expense-financial", "CN", "expense", "financial", "财务费用", "財務費用", "Financial Expense", "財務費用", "재무비용", "Frais financiers", "损益表-财务费用", 40),
        c("cn-expense-tax-surcharge", "CN", "expense", "tax-surcharge", "营业税金及附加", "營業稅金及附加", "Tax Surcharge", "租税公課", "제세공과금", "Taxes & impôts", "损益表-税金及附加", 50),
        c("cn-expense-income-tax", "CN", "expense", "income-tax", "所得税", "所得稅", "Income Tax", "法人税", "법인세", "Impôt sur le revenu", "损益表-所得税", 60),

        // ===================== US (Schedule C) =====================
        c("us-income-gross-receipts", "US", "income", "gross-receipts", "总收入或销售额", "總收入或銷售額", "Gross Receipts", "総収入", "총수입", "Recettes brutes", "Schedule C Line 1", 10),
        c("us-income-returns", "US", "income", "returns", "退货与折让", "退貨與折讓", "Returns & Allowances", "返品・値引", "반품·할인", "Retours & rabais", "Schedule C Line 2", 20),
        c("us-income-other", "US", "income", "other-income", "其他收入", "其他收入", "Other Income", "その他収入", "기타수입", "Autres revenus", "Schedule C Line 6", 30),
        c("us-expense-advertising", "US", "expense", "advertising", "广告费", "廣告費", "Advertising", "広告宣伝費", "광고선전비", "Publicité", "Schedule C Line 8", 10),
        c("us-expense-car", "US", "expense", "car-truck", "车辆费用", "車輛費用", "Car & Truck Expenses", "車両費", "차량유지비", "Frais de véhicule", "Schedule C Line 9", 20),
        c("us-expense-commissions", "US", "expense", "commissions", "佣金", "佣金", "Commissions & Fees", "手数料", "수수료", "Commissions", "Schedule C Line 10", 30),
        c("us-expense-contract", "US", "expense", "contract-labor", "外包劳务", "外包勞務", "Contract Labor", "外注費", "외주용역비", "Sous-traitance", "Schedule C Line 11", 40),
        c("us-expense-depreciation", "US", "expense", "depreciation", "折旧", "折舊", "Depreciation", "減価償却", "감가상각비", "Amortissements", "Schedule C Line 13", 50),
        c("us-expense-insurance", "US", "expense", "insurance", "保险（非健康）", "保險（非健康）", "Insurance (non-health)", "保険料", "보험료", "Assurance", "Schedule C Line 15", 60),
        c("us-expense-interest", "US", "expense", "interest", "利息支出", "利息支出", "Interest", "支払利息", "이자비용", "Intérêts", "Schedule C Line 16b", 70),
        c("us-expense-legal", "US", "expense", "legal-pro", "法律与专业服务", "法律與專業服務", "Legal & Professional", "専門家報酬", "법무·전문가비", "Honoraires", "Schedule C Line 17", 80),
        c("us-expense-office", "US", "expense", "office", "办公费用", "辦公費用", "Office Expense", "事務用品費", "사무용품비", "Fournitures bureau", "Schedule C Line 18", 90),
        c("us-expense-rent", "US", "expense", "rent", "租金", "租金", "Rent", "地代家賃", "임차료", "Loyer", "Schedule C Line 20", 100),
        c("us-expense-repairs", "US", "expense", "repairs", "维修费", "維修費", "Repairs & Maintenance", "修繕費", "수선유지비", "Réparations", "Schedule C Line 21", 110),
        c("us-expense-supplies", "US", "expense", "supplies", "耗材", "耗材", "Supplies", "消耗品費", "소모품비", "Fournitures", "Schedule C Line 22", 120),
        c("us-expense-taxes", "US", "expense", "taxes", "税款与执照", "稅款與執照", "Taxes & Licenses", "租税公課", "제세공과금", "Taxes & licences", "Schedule C Line 23", 130),
        c("us-expense-travel", "US", "expense", "travel", "差旅", "差旅", "Travel", "旅費交通費", "여비교통비", "Frais de déplacement", "Schedule C Line 24a", 140),
        c("us-expense-meals", "US", "expense", "meals", "餐费（50%可抵）", "餐費（50%可抵）", "Meals (50%)", "接待交際費（50%）", "식비(50%)", "Repas (50%)", "Schedule C Line 24b", 150, 50),
        c("us-expense-utilities", "US", "expense", "utilities", "水电网", "水電網", "Utilities", "水道光熱費", "수도광열비", "Énergie", "Schedule C Line 25", 160),
        c("us-expense-wages", "US", "expense", "wages", "工资", "工資", "Wages", "給料手当", "급여", "Salaires", "Schedule C Line 26", 170),
        c("us-expense-other", "US", "expense", "other", "其他费用", "其他費用", "Other Expenses", "雑費", "잡비", "Autres charges", "Schedule C Line 27a", 180),
        c("us-expense-home-office", "US", "expense", "home-office", "家庭办公室", "家庭辦公室", "Home Office", "在宅オフィス", "재택사무실", "Bureau à domicile", "Form 8829", 190),

        // ===================== JP =====================
        c("jp-income-sales", "JP", "income", "sales", "销售额", "銷售額", "Sales", "売上高", "매출", "Ventes", "損益計算書-売上高", 10),
        c("jp-income-other", "JP", "income", "other", "营业外收益", "營業外收益", "Non-Operating Income", "営業外収益", "영업외수익", "Produits hors exploitation", "損益計算書-営業外収益", 20),
        c("jp-expense-cogs", "JP", "expense", "cogs", "销货成本", "銷貨成本", "Cost of Goods Sold", "売上原価", "매출원가", "Coût des ventes", "損益計算書-売上原価", 10),
        c("jp-expense-salary", "JP", "expense", "salary", "工资", "工資", "Salaries", "給料手当", "급여", "Salaires", "販管費-給料手当", 20),
        c("jp-expense-travel", "JP", "expense", "travel", "差旅交通", "差旅交通", "Travel", "旅費交通費", "여비교통비", "Déplacements", "販管費-旅費交通費", 30),
        c("jp-expense-comm", "JP", "expense", "communication", "通讯", "通訊", "Communication", "通信費", "통신비", "Télécom", "販管費-通信費", 40),
        c("jp-expense-utilities", "JP", "expense", "utilities", "水电费", "水電費", "Utilities", "水道光熱費", "수도광열비", "Énergie", "販管費-水道光熱費", 50),
        c("jp-expense-supplies", "JP", "expense", "supplies", "消耗品", "消耗品", "Supplies", "消耗品費", "소모품비", "Fournitures", "販管費-消耗品費", 60),
        c("jp-expense-entertain", "JP", "expense", "entertain", "招待交际", "招待交際", "Entertainment", "接待交際費", "접대비", "Représentation", "販管費-接待交際費", 70),
        c("jp-expense-ad", "JP", "expense", "advertising", "广告", "廣告", "Advertising", "広告宣伝費", "광고선전비", "Publicité", "販管費-広告宣伝費", 80),
        c("jp-expense-rent", "JP", "expense", "rent", "租金", "租金", "Rent", "地代家賃", "임차료", "Loyer", "販管費-地代家賃", 90),
        c("jp-expense-tax", "JP", "expense", "tax", "税金", "稅金", "Taxes", "租税公課", "제세공과금", "Impôts", "販管費-租税公課", 100),
        c("jp-expense-dep", "JP", "expense", "depreciation", "折旧", "折舊", "Depreciation", "減価償却費", "감가상각비", "Amortissements", "販管費-減価償却費", 110),
        c("jp-expense-misc", "JP", "expense", "misc", "杂费", "雜費", "Miscellaneous", "雑費", "잡비", "Divers", "販管費-雑費", 120),

        // ===================== EU (Generic) =====================
        c("eu-income-revenue", "EU", "income", "revenue", "营业收入", "營業收入", "Revenue", "売上", "매출", "Chiffre d'affaires", "P&L - Revenue", 10),
        c("eu-income-financial", "EU", "income", "financial", "财务收入", "財務收入", "Financial Income", "財務収益", "재무수익", "Produits financiers", "P&L - Financial Income", 20),
        c("eu-expense-purchases", "EU", "expense", "purchases", "采购", "採購", "Purchases", "仕入", "매입", "Achats", "P&L - Purchases", 10),
        c("eu-expense-rent", "EU", "expense", "rent", "租金", "租金", "Rent", "賃料", "임차료", "Loyer", "P&L - Rent", 20),
        c("eu-expense-salaries", "EU", "expense", "salaries", "工资", "工資", "Salaries", "給与", "급여", "Salaires", "P&L - Salaries", 30),
        c("eu-expense-social", "EU", "expense", "social-charges", "社会保险", "社會保險", "Social Charges", "社会保険料", "사회보험료", "Charges sociales", "P&L - Social", 40),
        c("eu-expense-travel", "EU", "expense", "travel", "差旅", "差旅", "Travel", "出張費", "여비교통비", "Déplacements", "P&L - Travel", 50),
        c("eu-expense-fees", "EU", "expense", "professional", "专业服务", "專業服務", "Professional Fees", "専門家報酬", "전문가비", "Honoraires", "P&L - Fees", 60),
        c("eu-expense-marketing", "EU", "expense", "marketing", "市场推广", "市場推廣", "Marketing", "マーケティング", "마케팅비", "Marketing", "P&L - Marketing", 70),
        c("eu-expense-energy", "EU", "expense", "energy", "能源", "能源", "Energy", "光熱費", "에너지비", "Énergie", "P&L - Energy", 80),
        c("eu-expense-amortization", "EU", "expense", "amortization", "摊销", "攤銷", "Amortization", "償却", "상각비", "Amortissements", "P&L - Amortization", 90),
        c("eu-expense-vat-net", "EU", "expense", "vat-net", "VAT 应纳", "VAT 應納", "VAT Payable (Net)", "VAT 納付", "VAT 납부", "TVA à payer", "VAT Return", 100),

        // ===================== KR =====================
        c("kr-income-sales", "KR", "income", "sales", "销售", "銷售", "Sales", "売上", "매출", "Ventes", "손익계산서-매출", 10),
        c("kr-income-non-op", "KR", "income", "non-operating", "营业外收益", "營業外收益", "Non-Operating Income", "営業外収益", "영업외수익", "Produits hors exploitation", "손익계산서-영업외수익", 20),
        c("kr-expense-cogs", "KR", "expense", "cogs", "销售成本", "銷售成本", "Cost of Sales", "売上原価", "매출원가", "Coût des ventes", "손익계산서-매출원가", 10),
        c("kr-expense-salary", "KR", "expense", "salary", "工资", "工資", "Salary", "給与", "급여", "Salaires", "판관비-급여", 20),
        c("kr-expense-welfare", "KR", "expense", "welfare", "福利", "福利", "Welfare", "福利厚生費", "복리후생비", "Avantages sociaux", "판관비-복리후생비", 30),
        c("kr-expense-travel", "KR", "expense", "travel", "差旅", "差旅", "Travel", "旅費交通費", "여비교통비", "Déplacements", "판관비-여비교통비", 40),
        c("kr-expense-comm", "KR", "expense", "communication", "通讯", "通訊", "Communication", "通信費", "통신비", "Télécom", "판관비-통신비", 50),
        c("kr-expense-utilities", "KR", "expense", "utilities", "水电费", "水電費", "Utilities", "水道光熱費", "수도광열비", "Énergie", "판관비-수도광열비", 60),
        c("kr-expense-supplies", "KR", "expense", "supplies", "消耗品", "消耗品", "Supplies", "消耗品費", "소모품비", "Fournitures", "판관비-소모품비", 70),
        c("kr-expense-entertain", "KR", "expense", "entertain", "招待", "招待", "Entertainment", "接待費", "접대비", "Représentation", "판관비-접대비", 80),
        c("kr-expense-ad", "KR", "expense", "advertising", "广告", "廣告", "Advertising", "広告宣伝費", "광고선전비", "Publicité", "판관비-광고선전비", 90),
        c("kr-expense-rent", "KR", "expense", "rent", "租金", "租金", "Rent", "賃料", "임차료", "Loyer", "판관비-임차료", 100),
        c("kr-expense-dep", "KR", "expense", "depreciation", "折旧", "折舊", "Depreciation", "減価償却費", "감가상각비", "Amortissements", "판관비-감가상각비", 110),

        // ===================== TW =====================
        c("tw-income-sales", "TW", "income", "sales", "销售收入", "銷售收入", "Sales Revenue", "売上", "매출", "Ventes", "損益表-營業收入", 10),
        c("tw-income-other", "TW", "income", "other", "其他营业收入", "其他營業收入", "Other Operating Income", "その他営業収益", "기타영업수익", "Autres produits", "損益表-其他營業收入", 20),
        c("tw-expense-cogs", "TW", "expense", "cogs", "销货成本", "銷貨成本", "Cost of Goods Sold", "売上原価", "매출원가", "Coût des marchandises", "損益表-銷貨成本", 10),
        c("tw-expense-selling", "TW", "expense", "selling", "推销费用", "推銷費用", "Selling Expense", "販売費", "판매비", "Frais de vente", "損益表-推銷費用", 20),
        c("tw-expense-admin", "TW", "expense", "admin", "管理费用", "管理費用", "Administrative Expense", "一般管理費", "관리비", "Frais admin", "損益表-管理費用", 30),
        c("tw-expense-rd", "TW", "expense", "rd", "研发费用", "研發費用", "R&D Expense", "研究開発費", "연구개발비", "R&D", "損益表-研究發展費用", 40),
        c("tw-expense-business-tax", "TW", "expense", "business-tax", "营业税", "營業稅", "Business Tax", "営業税", "영업세", "Taxe activité", "損益表-營業稅", 50),
        c("tw-expense-income-tax", "TW", "expense", "income-tax", "所得税", "所得稅", "Income Tax", "法人税", "법인세", "Impôt sur le revenu", "損益表-所得稅", 60),
    ]
}
