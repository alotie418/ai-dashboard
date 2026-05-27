// Accounting Locale Config — 独立于 UI Language
//
// 核心原则：
//   - accountingLocale 决定：税制、币种、报表结构、仪表盘区块、AI 财务上下文
//   - uiLanguage 决定：所有可见文字的显示语言
//   - 二者互不推导：JP 会计 + 中文 UI = 日本消费税逻辑 + 中文标签
//
// taxConcepts 里每个 key 都有多语言翻译，渲染时按 uiLanguage 取值

export type AccountingLocaleId = 'CN' | 'US' | 'JP' | 'EU' | 'KR' | 'TW';
export type UILanguageCode = 'zh-CN' | 'zh-TW' | 'en' | 'ja' | 'ko' | 'fr';

export interface TaxConceptLabels {
  [uiLang: string]: string;
}

export interface AccountingLocaleConfig {
  id: AccountingLocaleId;
  defaultCurrency: string;
  currencySymbol: string;
  taxRegime: string;

  // 税务概念标签 — 每个 key 的值是 { uiLanguage → 翻译 } 的映射
  taxConcepts: Record<string, TaxConceptLabels>;

  // 仪表盘应显示哪些区块（按 accountingLocale 决定，不按 uiLanguage）
  dashboardSections: string[];

  // 报表类型
  reportTypes: string[];

  // AI 用的会计制度上下文（英文，语言指令由 uiLanguage 单独注入）
  aiContext: string;
}

// ─── 6 国配置 ───

export const ACCOUNTING_LOCALES: Record<AccountingLocaleId, AccountingLocaleConfig> = {
  CN: {
    id: 'CN',
    defaultCurrency: 'CNY',
    currencySymbol: '¥',
    taxRegime: 'vat',
    taxConcepts: {
      taxTitle:      { 'zh-CN': '增值税统计', 'zh-TW': '增值稅統計', en: 'VAT Statistics', ja: '増値税統計', ko: '부가가치세 통계', fr: 'Statistiques TVA' },
      inputTax:      { 'zh-CN': '累计进项税额', 'zh-TW': '累計進項稅額', en: 'Total Input VAT', ja: '仕入税額累計', ko: '매입세액 누계', fr: 'TVA déductible cumulée' },
      outputTax:     { 'zh-CN': '累计销项税额', 'zh-TW': '累計銷項稅額', en: 'Total Output VAT', ja: '売上税額累計', ko: '매출세액 누계', fr: 'TVA collectée cumulée' },
      certifiedInput:{ 'zh-CN': '已收进项税额 (已认证)', 'zh-TW': '已收進項稅額 (已認證)', en: 'Certified Input VAT', ja: '認証済み仕入税額', ko: '인증된 매입세액', fr: 'TVA déductible certifiée' },
      invoicedOutput:{ 'zh-CN': '已开销项税额 (已开票)', 'zh-TW': '已開銷項稅額 (已開票)', en: 'Invoiced Output VAT', ja: '請求済み売上税額', ko: '발행된 매출세액', fr: 'TVA collectée facturée' },
      estimatedTax:  { 'zh-CN': '预估应交增值税', 'zh-TW': '預估應交增值稅', en: 'Estimated VAT Payable', ja: '増値税推定納付額', ko: '예상 부가가치세 납부액', fr: 'TVA estimée à payer' },
      taxSummaryTitle:{ 'zh-CN': '含税金额汇总 (对账用)', 'zh-TW': '含稅金額匯總 (對帳用)', en: 'Tax-Inclusive Summary (Reconciliation)', ja: '税込金額集計（照合用）', ko: '세금 포함 금액 요약 (대조용)', fr: 'Résumé TTC (rapprochement)' },
      purchaseTotal: { 'zh-CN': '采购含税总额', 'zh-TW': '採購含稅總額', en: 'Purchase Total (Incl. Tax)', ja: '仕入税込合計', ko: '매입 세금포함 총액', fr: 'Total achats TTC' },
      salesTotal:    { 'zh-CN': '销售含税总额', 'zh-TW': '銷售含稅總額', en: 'Sales Total (Incl. Tax)', ja: '売上税込合計', ko: '매출 세금포함 총액', fr: 'Total ventes TTC' },
      taxDifference: { 'zh-CN': '含税差额', 'zh-TW': '含稅差額', en: 'Tax-Inclusive Difference', ja: '税込差額', ko: '세금포함 차액', fr: 'Différence TTC' },
      surchargeNote: { 'zh-CN': '税金及附加按增值税自动计算', 'zh-TW': '稅金及附加按增值稅自動計算', en: 'Tax surcharge auto-calculated from VAT', ja: '付加税は増値税から自動計算', ko: '부가세에서 자동 계산', fr: 'Surtaxe calculée automatiquement' },
      // P&L labels
      plRevenue:     { 'zh-CN': '一、营业收入', 'zh-TW': '一、營業收入', en: 'I. Revenue', ja: 'Ⅰ. 売上高', ko: 'Ⅰ. 매출', fr: 'I. Chiffre d\'affaires' },
      plCost:        { 'zh-CN': '减：营业成本', 'zh-TW': '減：營業成本', en: 'Less: COGS', ja: '売上原価', ko: '매출원가', fr: 'Coût des ventes' },
      plGrossProfit: { 'zh-CN': '二、毛利', 'zh-TW': '二、毛利', en: 'II. Gross Profit', ja: 'Ⅱ. 売上総利益', ko: 'Ⅱ. 매출총이익', fr: 'II. Marge brute' },
      plTaxSurcharge:{ 'zh-CN': '减：税金及附加', 'zh-TW': '減：稅金及附加', en: 'Less: Tax Surcharge', ja: '租税公課', ko: '제세공과금', fr: 'Taxes et surtaxes' },
      plShipping:    { 'zh-CN': '减：运费支出 (销售费用)', 'zh-TW': '減：運費支出 (銷售費用)', en: 'Less: Shipping Expense', ja: '運送費', ko: '운송비', fr: 'Frais de livraison' },
      plAdmin:       { 'zh-CN': '减：管理费用', 'zh-TW': '減：管理費用', en: 'Less: Admin Expense', ja: '一般管理費', ko: '관리비', fr: 'Frais administratifs' },
      plIncomeTax:   { 'zh-CN': '减：所得税费用', 'zh-TW': '減：所得稅費用', en: 'Less: Income Tax', ja: '法人税等', ko: '법인세', fr: 'Impôt sur le revenu' },
      plNetProfit:   { 'zh-CN': '三、净利润', 'zh-TW': '三、淨利潤', en: 'III. Net Profit', ja: 'Ⅲ. 当期純利益', ko: 'Ⅲ. 당기순이익', fr: 'III. Bénéfice net' },
      plPeriodPrefix:{ 'zh-CN': '单位：人民币元 | 会计期间：', 'zh-TW': '單位：人民幣元 | 會計期間：', en: 'Period: ', ja: '会計期間：', ko: '회계기간: ', fr: 'Période : ' },
    },
    dashboardSections: ['profit_loss', 'profit_margins', 'vat_summary', 'tax_inclusive_summary'],
    reportTypes: ['income-statement', 'vat-summary', 'tax-inclusive'],
    aiContext: 'Use Chinese VAT accounting rules. Input VAT vs Output VAT. Tax surcharge = VAT payable × 12%. Income tax 25%.',
  },

  US: {
    id: 'US',
    defaultCurrency: 'USD',
    currencySymbol: '$',
    taxRegime: 'schedule_c',
    taxConcepts: {
      taxTitle:      { 'zh-CN': 'Schedule C 概要', 'zh-TW': 'Schedule C 概要', en: 'Schedule C Summary', ja: 'Schedule C 概要', ko: 'Schedule C 요약', fr: 'Résumé Schedule C' },
      grossReceipts: { 'zh-CN': '总营业收入', 'zh-TW': '總營業收入', en: 'Gross Receipts', ja: '総収入', ko: '총수입', fr: 'Recettes brutes' },
      totalExpenses: { 'zh-CN': '总可抵扣费用', 'zh-TW': '總可抵扣費用', en: 'Total Deductible Expenses', ja: '経費合計', ko: '총 공제 비용', fr: 'Total charges déductibles' },
      netProfit:     { 'zh-CN': '净利润', 'zh-TW': '淨利潤', en: 'Net Profit', ja: '純利益', ko: '순이익', fr: 'Bénéfice net' },
      seTax:         { 'zh-CN': '自雇税', 'zh-TW': '自僱稅', en: 'Self-Employment Tax', ja: '自営業税', ko: '자영업세', fr: 'Cotisations sociales' },
      quarterlyTax:  { 'zh-CN': '季度预估税', 'zh-TW': '季度預估稅', en: 'Quarterly Estimated Tax', ja: '四半期概算税', ko: '분기 추정세', fr: 'Acompte trimestriel' },
      mileage:       { 'zh-CN': '里程抵扣', 'zh-TW': '里程抵扣', en: 'Mileage Deduction', ja: 'マイレージ控除', ko: '마일리지 공제', fr: 'Déduction kilométrique' },
      homeOffice:    { 'zh-CN': '家庭办公抵扣', 'zh-TW': '家庭辦公抵扣', en: 'Home Office Deduction', ja: '在宅勤務控除', ko: '재택근무 공제', fr: 'Déduction bureau à domicile' },
      // P&L labels (Schedule C lines)
      plRevenue:     { 'zh-CN': '总收入 (Line 7)', 'zh-TW': '總收入 (Line 7)', en: 'Gross Income (Line 7)', ja: '総収入 (Line 7)', ko: '총소득 (Line 7)', fr: 'Revenu brut (Line 7)' },
      plCost:        { 'zh-CN': '总费用 (Line 28)', 'zh-TW': '總費用 (Line 28)', en: 'Total Expenses (Line 28)', ja: '経費合計 (Line 28)', ko: '총비용 (Line 28)', fr: 'Total charges (Line 28)' },
      plGrossProfit: { 'zh-CN': '净利润 (Line 31)', 'zh-TW': '淨利潤 (Line 31)', en: 'Net Profit (Line 31)', ja: '純利益 (Line 31)', ko: '순이익 (Line 31)', fr: 'Bénéfice net (Line 31)' },
      plAdmin:       { 'zh-CN': '办公费用 (Line 18)', 'zh-TW': '辦公費用 (Line 18)', en: 'Office Expense (Line 18)', ja: '事務費 (Line 18)', ko: '사무비 (Line 18)', fr: 'Frais de bureau (Line 18)' },
      plIncomeTax:   { 'zh-CN': '联邦所得税', 'zh-TW': '聯邦所得稅', en: 'Federal Income Tax', ja: '連邦所得税', ko: '연방 소득세', fr: 'Impôt fédéral' },
      plNetProfit:   { 'zh-CN': '净利润', 'zh-TW': '淨利潤', en: 'Net Profit', ja: '純利益', ko: '순이익', fr: 'Bénéfice net' },
      plPeriodPrefix:{ 'zh-CN': '币种：美元 | 会计期间：', 'zh-TW': '幣種：美元 | 會計期間：', en: 'Currency: USD | Period: ', ja: '通貨：USD | 期間：', ko: '통화: USD | 기간: ', fr: 'Devise : USD | Période : ' },
    },
    dashboardSections: ['schedule_c_summary', 'deductions', 'se_tax_quarterly', 'profit_margins'],
    reportTypes: ['schedule-c', 'se-tax'],
    aiContext: 'Use US Schedule C sole proprietor accounting. No VAT. Sales Tax only if applicable. Self-Employment Tax (SS 12.4% + Medicare 2.9%). Quarterly estimated tax.',
  },

  JP: {
    id: 'JP',
    defaultCurrency: 'JPY',
    currencySymbol: '¥',
    taxRegime: 'consumption_tax',
    taxConcepts: {
      taxTitle:      { 'zh-CN': '消费税统计', 'zh-TW': '消費稅統計', en: 'Consumption Tax Summary', ja: '消費税集計', ko: '소비세 통계', fr: 'Résumé taxe consommation' },
      inputTax:      { 'zh-CN': '已付消费税（仕入）', 'zh-TW': '已付消費稅（仕入）', en: 'Consumption Tax Paid (Input)', ja: '仕入税額', ko: '매입 소비세', fr: 'Taxe payée (achats)' },
      outputTax:     { 'zh-CN': '已收消费税（売上）', 'zh-TW': '已收消費稅（売上）', en: 'Consumption Tax Collected (Output)', ja: '売上税額', ko: '매출 소비세', fr: 'Taxe collectée (ventes)' },
      estimatedTax:  { 'zh-CN': '预估应缴消费税', 'zh-TW': '預估應繳消費稅', en: 'Estimated Consumption Tax Payable', ja: '消費税推定納付額', ko: '예상 소비세 납부액', fr: 'Taxe consommation estimée' },
      plRevenue:     { 'zh-CN': '売上高', 'zh-TW': '売上高', en: 'Sales Revenue', ja: '売上高', ko: '매출', fr: 'Chiffre d\'affaires' },
      plCost:        { 'zh-CN': '売上原価', 'zh-TW': '売上原価', en: 'Cost of Sales', ja: '売上原価', ko: '매출원가', fr: 'Coût des ventes' },
      plGrossProfit: { 'zh-CN': '売上総利益', 'zh-TW': '売上總利益', en: 'Gross Profit', ja: '売上総利益', ko: '매출총이익', fr: 'Marge brute' },
      plAdmin:       { 'zh-CN': '贩管费', 'zh-TW': '販管費', en: 'SGA Expense', ja: '販売費及び一般管理費', ko: '판관비', fr: 'Frais généraux' },
      plIncomeTax:   { 'zh-CN': '法人税', 'zh-TW': '法人稅', en: 'Corporate Tax', ja: '法人税等', ko: '법인세', fr: 'Impôt sur les sociétés' },
      plNetProfit:   { 'zh-CN': '当期纯利益', 'zh-TW': '當期純利益', en: 'Net Income', ja: '当期純利益', ko: '당기순이익', fr: 'Résultat net' },
      plPeriodPrefix:{ 'zh-CN': '币种：日元 | 会计期间：', 'zh-TW': '幣種：日圓 | 會計期間：', en: 'Currency: JPY | Period: ', ja: '通貨：円 | 期間：', ko: '통화: JPY | 기간: ', fr: 'Devise : JPY | Période : ' },
    },
    dashboardSections: ['profit_loss', 'profit_margins', 'consumption_tax_summary', 'tax_inclusive_summary'],
    reportTypes: ['income-statement', 'consumption-tax'],
    aiContext: 'Use Japanese accounting with Consumption Tax (消費税) 10% standard / 8% reduced. ひとり会社 (one-person company) context.',
  },

  EU: {
    id: 'EU',
    defaultCurrency: 'EUR',
    currencySymbol: '€',
    taxRegime: 'vat',
    taxConcepts: {
      taxTitle:      { 'zh-CN': 'VAT 统计', 'zh-TW': 'VAT 統計', en: 'VAT Summary', ja: 'VAT集計', ko: 'VAT 통계', fr: 'Résumé TVA' },
      inputTax:      { 'zh-CN': '进项 VAT', 'zh-TW': '進項 VAT', en: 'Input VAT', ja: '仕入VAT', ko: '매입 VAT', fr: 'TVA déductible' },
      outputTax:     { 'zh-CN': '销项 VAT', 'zh-TW': '銷項 VAT', en: 'Output VAT', ja: '売上VAT', ko: '매출 VAT', fr: 'TVA collectée' },
      estimatedTax:  { 'zh-CN': '预估应缴 VAT', 'zh-TW': '預估應繳 VAT', en: 'Estimated VAT Payable', ja: 'VAT推定納付額', ko: '예상 VAT 납부액', fr: 'TVA estimée à payer' },
      plRevenue:     { 'zh-CN': '营业收入', 'zh-TW': '營業收入', en: 'Revenue', ja: '売上', ko: '매출', fr: 'Chiffre d\'affaires' },
      plCost:        { 'zh-CN': '营业成本', 'zh-TW': '營業成本', en: 'Cost of Sales', ja: '売上原価', ko: '매출원가', fr: 'Coût des ventes' },
      plGrossProfit: { 'zh-CN': '毛利', 'zh-TW': '毛利', en: 'Gross Profit', ja: '粗利益', ko: '매출총이익', fr: 'Marge brute' },
      plAdmin:       { 'zh-CN': '管理费用', 'zh-TW': '管理費用', en: 'Admin Expense', ja: '一般管理費', ko: '관리비', fr: 'Frais administratifs' },
      plIncomeTax:   { 'zh-CN': '所得税', 'zh-TW': '所得稅', en: 'Income Tax', ja: '法人税', ko: '법인세', fr: 'Impôt sur le revenu' },
      plNetProfit:   { 'zh-CN': '净利润', 'zh-TW': '淨利潤', en: 'Net Profit', ja: '純利益', ko: '순이익', fr: 'Bénéfice net' },
      plPeriodPrefix:{ 'zh-CN': '币种：欧元 | 会计期间：', 'zh-TW': '幣種：歐元 | 會計期間：', en: 'Currency: EUR | Period: ', ja: '通貨：EUR | 期間：', ko: '통화: EUR | 기간: ', fr: 'Devise : EUR | Période : ' },
    },
    dashboardSections: ['profit_loss', 'profit_margins', 'vat_summary', 'tax_inclusive_summary'],
    reportTypes: ['profit-loss', 'vat-return'],
    aiContext: 'Use EU VAT accounting. Standard VAT ~20%. Input VAT deduction from Output VAT.',
  },

  KR: {
    id: 'KR',
    defaultCurrency: 'KRW',
    currencySymbol: '₩',
    taxRegime: 'vat',
    taxConcepts: {
      taxTitle:      { 'zh-CN': '附加价值税统计', 'zh-TW': '附加價值稅統計', en: 'VAT Summary', ja: '付加価値税集計', ko: '부가가치세 요약', fr: 'Résumé TVA' },
      inputTax:      { 'zh-CN': '매입세额', 'zh-TW': '매입세額', en: 'Input VAT', ja: '仕入VAT', ko: '매입세액', fr: 'TVA déductible' },
      outputTax:     { 'zh-CN': '매출세额', 'zh-TW': '매출세額', en: 'Output VAT', ja: '売上VAT', ko: '매출세액', fr: 'TVA collectée' },
      estimatedTax:  { 'zh-CN': '预估应缴附加税', 'zh-TW': '預估應繳附加稅', en: 'Estimated VAT Payable', ja: 'VAT推定納付額', ko: '예상 부가가치세', fr: 'TVA estimée' },
      plRevenue:     { 'zh-CN': '매출', 'zh-TW': '매출', en: 'Sales', ja: '売上', ko: '매출', fr: 'Ventes' },
      plCost:        { 'zh-CN': '매출원가', 'zh-TW': '매출원가', en: 'COGS', ja: '売上原価', ko: '매출원가', fr: 'Coût des ventes' },
      plGrossProfit: { 'zh-CN': '매출총이익', 'zh-TW': '매출총이익', en: 'Gross Profit', ja: '粗利益', ko: '매출총이익', fr: 'Marge brute' },
      plAdmin:       { 'zh-CN': '판관비', 'zh-TW': '판관비', en: 'SGA', ja: '販管費', ko: '판매비와관리비', fr: 'Frais généraux' },
      plIncomeTax:   { 'zh-CN': '法人세', 'zh-TW': '法人세', en: 'Corporate Tax', ja: '法人税', ko: '법인세', fr: 'Impôt sur les sociétés' },
      plNetProfit:   { 'zh-CN': '당기순이익', 'zh-TW': '당기순이익', en: 'Net Income', ja: '純利益', ko: '당기순이익', fr: 'Résultat net' },
      plPeriodPrefix:{ 'zh-CN': '币种：韩元 | 会计期间：', 'zh-TW': '幣種：韓元 | 會計期間：', en: 'Currency: KRW | Period: ', ja: '通貨：KRW | 期間：', ko: '통화: KRW | 기간: ', fr: 'Devise : KRW | Période : ' },
    },
    dashboardSections: ['profit_loss', 'profit_margins', 'vat_summary', 'tax_inclusive_summary'],
    reportTypes: ['income-statement', 'vat-summary'],
    aiContext: 'Use Korean VAT accounting. 부가가치세 10%. 법인세 progressive rates.',
  },

  TW: {
    id: 'TW',
    defaultCurrency: 'TWD',
    currencySymbol: 'NT$',
    taxRegime: 'business_tax',
    taxConcepts: {
      taxTitle:      { 'zh-CN': '营业税统计', 'zh-TW': '營業稅統計', en: 'Business Tax Summary', ja: '営業税集計', ko: '영업세 통계', fr: 'Résumé taxe activité' },
      inputTax:      { 'zh-CN': '进项营业税', 'zh-TW': '進項營業稅', en: 'Input Business Tax', ja: '仕入営業税', ko: '매입 영업세', fr: 'Taxe payée' },
      outputTax:     { 'zh-CN': '销项营业税', 'zh-TW': '銷項營業稅', en: 'Output Business Tax', ja: '売上営業税', ko: '매출 영업세', fr: 'Taxe collectée' },
      estimatedTax:  { 'zh-CN': '预估应缴营业税', 'zh-TW': '預估應繳營業稅', en: 'Estimated Business Tax Payable', ja: '営業税推定納付額', ko: '예상 영업세', fr: 'Taxe estimée' },
      plRevenue:     { 'zh-CN': '銷售收入', 'zh-TW': '銷售收入', en: 'Sales Revenue', ja: '売上', ko: '매출', fr: 'Chiffre d\'affaires' },
      plCost:        { 'zh-CN': '銷貨成本', 'zh-TW': '銷貨成本', en: 'COGS', ja: '売上原価', ko: '매출원가', fr: 'Coût des ventes' },
      plGrossProfit: { 'zh-CN': '毛利', 'zh-TW': '毛利', en: 'Gross Profit', ja: '粗利益', ko: '매출총이익', fr: 'Marge brute' },
      plAdmin:       { 'zh-CN': '管理費用', 'zh-TW': '管理費用', en: 'Admin Expense', ja: '一般管理費', ko: '관리비', fr: 'Frais admin' },
      plIncomeTax:   { 'zh-CN': '營利事業所得稅', 'zh-TW': '營利事業所得稅', en: 'Business Income Tax', ja: '営利事業所得税', ko: '영리사업 소득세', fr: 'Impôt sur les bénéfices' },
      plNetProfit:   { 'zh-CN': '净利润', 'zh-TW': '淨利潤', en: 'Net Profit', ja: '純利益', ko: '순이익', fr: 'Bénéfice net' },
      plPeriodPrefix:{ 'zh-CN': '币种：新台币 | 会计期间：', 'zh-TW': '幣種：新臺幣 | 會計期間：', en: 'Currency: TWD | Period: ', ja: '通貨：TWD | 期間：', ko: '통화: TWD | 기간: ', fr: 'Devise : TWD | Période : ' },
    },
    dashboardSections: ['profit_loss', 'profit_margins', 'business_tax_summary', 'tax_inclusive_summary'],
    reportTypes: ['income-statement', 'business-tax'],
    aiContext: 'Use Taiwan Business Tax (營業稅) 5% standard. 營利事業所得稅 20%.',
  },
};

export function getAccountingLocale(id: string): AccountingLocaleConfig {
  return ACCOUNTING_LOCALES[id as AccountingLocaleId] || ACCOUNTING_LOCALES.CN;
}
