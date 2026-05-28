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
      certifiedInput:{ 'zh-CN': '已认证进项税额', 'zh-TW': '已認證進項稅額', en: 'Certified Input VAT', ja: '認証済み仕入税額', ko: '인증된 매입세액', fr: 'TVA déductible certifiée' },
      invoicedOutput:{ 'zh-CN': '已开票销项税额', 'zh-TW': '已開票銷項稅額', en: 'Invoiced Output VAT', ja: '請求済み売上税額', ko: '발행된 매출세액', fr: 'TVA collectée facturée' },
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
      plTitle:       { 'zh-CN': '利润表', 'zh-TW': '利潤表', en: 'Income Statement', ja: '損益計算書', ko: '손익계산서', fr: 'Compte de résultat' },
      tabPlLabel:    { 'zh-CN': '利润表', 'zh-TW': '利潤表', en: 'P&L', ja: '損益', ko: '손익', fr: 'Résultat' },
      formTaxRate:   { 'zh-CN': '增值税率', 'zh-TW': '增值稅率', en: 'VAT Rate', ja: '増値税率', ko: '증치세율', fr: 'Taux VAT' },
      invoiceInputLabel: { 'zh-CN': '累计进项票数', 'zh-TW': '累計進項票數', en: 'Total Input Invoices', ja: '仕入請求書数', ko: '매입세금계산서', fr: 'Factures achats' },
      invoiceOutputLabel: { 'zh-CN': '累计销项票数', 'zh-TW': '累計銷項票數', en: 'Total Output Invoices', ja: '売上請求書数', ko: '매출세금계산서', fr: 'Factures ventes' },
      invoicePendingTax: { 'zh-CN': '待认证进项额', 'zh-TW': '待認證進項額', en: 'Pending Input VAT', ja: '未認証仕入税額', ko: '미인증 매입세액', fr: 'TVA achats en attente' },
      invoiceTypeOutput: { 'zh-CN': '销项', 'zh-TW': '銷項', en: 'Output', ja: '売上', ko: '매출', fr: 'Vente' },
      invoiceTypeInput: { 'zh-CN': '进项', 'zh-TW': '進項', en: 'Input', ja: '仕入', ko: '매입', fr: 'Achat' },
      inventoryUnit: { 'zh-CN': '吨', 'zh-TW': '噸', en: 'units', ja: '単位', ko: '단위', fr: 'unités' },
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
      plTitle:       { 'zh-CN': 'Schedule C（营业损益表）', 'zh-TW': 'Schedule C（營業損益表）', en: 'Schedule C — Profit or Loss From Business', ja: 'Schedule C（事業損益）', ko: 'Schedule C (사업 손익)', fr: 'Schedule C (Profits ou pertes d\'activité)' },
      tabPlLabel:    { 'zh-CN': 'Schedule C', 'zh-TW': 'Schedule C', en: 'Schedule C', ja: 'Schedule C', ko: 'Schedule C', fr: 'Schedule C' },
      formTaxRate:   { 'zh-CN': 'Sales Tax 税率', 'zh-TW': 'Sales Tax 稅率', en: 'Sales Tax Rate', ja: 'Sales Tax 率', ko: 'Sales Tax 세율', fr: 'Taux Sales Tax' },
      kpiGrossIncome:{ 'zh-CN': '营业总所得', 'zh-TW': '營業總所得', en: 'Gross Income', ja: '総所得', ko: '총소득', fr: 'Revenu brut' },
      kpiQuarterlyTax:{ 'zh-CN': '预估季度税', 'zh-TW': '預估季度稅', en: 'Est. Quarterly Tax', ja: '四半期予定税', ko: '예상 분기 세금', fr: 'Acompte trimestriel' },
      profitMargins: { 'zh-CN': '利润率指标', 'zh-TW': '利潤率指標', en: 'Profit Margins', ja: '利益率指標', ko: '이익률 지표', fr: 'Marges bénéficiaires' },
      grossMargin:   { 'zh-CN': '毛利率', 'zh-TW': '毛利率', en: 'Gross Margin', ja: '粗利率', ko: '매출총이익률', fr: 'Marge brute' },
      netMargin:     { 'zh-CN': '净利率', 'zh-TW': '淨利率', en: 'Net Margin', ja: '純利益率', ko: '순이익률', fr: 'Marge nette' },
      socialSecurity:{ 'zh-CN': 'Social Security（社会保障税）', 'zh-TW': 'Social Security（社會保障稅）', en: 'Social Security', ja: 'Social Security（社会保障税）', ko: 'Social Security (사회보장세)', fr: 'Social Security (sécurité sociale)' },
      medicare:      { 'zh-CN': 'Medicare（医疗保险税）', 'zh-TW': 'Medicare（醫療保險稅）', en: 'Medicare', ja: 'Medicare（医療保険税）', ko: 'Medicare (의료보험세)', fr: 'Medicare (assurance maladie)' },
      additionalMedicare: { 'zh-CN': 'Additional Medicare（附加医疗保险税）', 'zh-TW': 'Additional Medicare（附加醫療保險稅）', en: 'Additional Medicare', ja: 'Additional Medicare（追加医療保険税）', ko: 'Additional Medicare (추가 의료보험세)', fr: 'Additional Medicare (taxe additionnelle)' },
      dueLabel:      { 'zh-CN': '到期日', 'zh-TW': '到期日', en: 'Due', ja: '期限', ko: '납기', fr: 'Échéance' },
      pageTitlePurchase:  { 'zh-CN': '采购与费用', 'zh-TW': '採購與費用', en: 'Purchases & Expenses', ja: '仕入と経費', ko: '매입 및 비용', fr: 'Achats & dépenses' },
      uploadTitle:        { 'zh-CN': '拖放或点击上传收据、账单或发票', 'zh-TW': '拖放或點擊上傳收據、帳單或發票', en: 'Drag and drop or click to upload a receipt, bill or invoice', ja: 'レシート・請求書・伝票をドラッグまたはクリックでアップロード', ko: '영수증, 청구서 또는 인보이스를 드래그하거나 클릭해 업로드', fr: 'Glissez ou cliquez pour téléverser un reçu, une facture ou un justificatif' },
      uploadSubtitle:     { 'zh-CN': '自动提取日期、金额、供应商及票据号码', 'zh-TW': '自動擷取日期、金額、供應商及票據號碼', en: 'Auto-extract date, amount, vendor and receipt/invoice number', ja: '日付、金額、仕入先、伝票番号を自動抽出', ko: '날짜, 금액, 공급업체, 영수증 번호를 자동 추출', fr: 'Extraction automatique de la date, du montant, du fournisseur et du numéro' },
      headerUnitPrice:    { 'zh-CN': '单价', 'zh-TW': '單價', en: 'Unit Price', ja: '単価', ko: '단가', fr: 'Prix unitaire' },
      headerAmount:       { 'zh-CN': '金额', 'zh-TW': '金額', en: 'Amount', ja: '金額', ko: '금액', fr: 'Montant' },
      headerTaxAmount:    { 'zh-CN': '税额', 'zh-TW': '稅額', en: 'Tax', ja: '税額', ko: '세액', fr: 'Taxe' },
      headerTotalWithTax: { 'zh-CN': '总额', 'zh-TW': '總額', en: 'Total', ja: '合計', ko: '총액', fr: 'Total' },
      headerInvoiceNo:    { 'zh-CN': '票据号码', 'zh-TW': '票據號碼', en: 'Receipt / Invoice #', ja: '伝票番号', ko: '영수증 번호', fr: 'N° de pièce' },
      invoiceInputLabel: { 'zh-CN': '费用凭证数', 'zh-TW': '費用憑證數', en: 'Expense Receipts', ja: '経費レシート', ko: '비용 영수증', fr: 'Reçus de dépenses' },
      invoiceOutputLabel: { 'zh-CN': '收入凭证数', 'zh-TW': '收入憑證數', en: 'Income Receipts', ja: '収入レシート', ko: '수입 영수증', fr: 'Reçus de revenus' },
      invoicePendingTax: { 'zh-CN': '待报税凭证额', 'zh-TW': '待報稅憑證額', en: 'Pending Tax Documents', ja: '未申告税務書類', ko: '미신고 세무 서류', fr: 'Documents fiscaux en attente' },
      invoiceTypeOutput: { 'zh-CN': '收入', 'zh-TW': '收入', en: 'Income', ja: '収入', ko: '수입', fr: 'Revenu' },
      invoiceTypeInput: { 'zh-CN': '费用', 'zh-TW': '費用', en: 'Expense', ja: '経費', ko: '비용', fr: 'Dépense' },
      inventoryUnit: { 'zh-CN': '单位', 'zh-TW': '單位', en: 'units', ja: '単位', ko: '단위', fr: 'unités' },
      taxSummaryTitle:{ 'zh-CN': '收支汇总 (对账用)', 'zh-TW': '收支匯總 (對帳用)', en: 'Income & Expense Summary (Reconciliation)', ja: '収支集計（照合用）', ko: '수입·지출 요약 (대조용)', fr: 'Résumé recettes/dépenses (rapprochement)' },
      purchaseTotal: { 'zh-CN': '费用总额', 'zh-TW': '費用總額', en: 'Total Expenses', ja: '経費合計', ko: '비용 총액', fr: 'Total dépenses' },
      salesTotal:    { 'zh-CN': '收入总额', 'zh-TW': '收入總額', en: 'Total Income', ja: '収入合計', ko: '수입 총액', fr: 'Total revenus' },
      taxDifference: { 'zh-CN': '收支差额', 'zh-TW': '收支差額', en: 'Net Difference', ja: '収支差額', ko: '수입·지출 차액', fr: 'Différence nette' },
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
      inputTax:      { 'zh-CN': '进项消费税', 'zh-TW': '進項消費稅', en: 'Consumption Tax Paid (Input)', ja: '仕入税額', ko: '매입 소비세', fr: 'Taxe payée (achats)' },
      outputTax:     { 'zh-CN': '销项消费税', 'zh-TW': '銷項消費稅', en: 'Consumption Tax Collected (Output)', ja: '売上税額', ko: '매출 소비세', fr: 'Taxe collectée (ventes)' },
      estimatedTax:  { 'zh-CN': '预计应缴消费税', 'zh-TW': '預計應繳消費稅', en: 'Estimated Consumption Tax Payable', ja: '消費税推定納付額', ko: '예상 소비세 납부액', fr: 'Taxe consommation estimée' },
      certifiedInput:{ 'zh-CN': '可抵扣进项消费税', 'zh-TW': '可抵扣進項消費稅', en: 'Deductible Input Tax', ja: '控除対象仕入税額', ko: '공제 가능 매입 소비세', fr: 'Taxe déductible certifiée' },
      invoicedOutput:{ 'zh-CN': '已开票销项消费税', 'zh-TW': '已開票銷項消費稅', en: 'Invoiced Output Tax', ja: '請求済み売上税額', ko: '발행된 매출 소비세', fr: 'Taxe collectée facturée' },
      plRevenue:     { 'zh-CN': '营业收入', 'zh-TW': '營業收入', en: 'Sales Revenue', ja: '売上高', ko: '매출', fr: 'Chiffre d\'affaires' },
      plCost:        { 'zh-CN': '营业成本', 'zh-TW': '營業成本', en: 'Cost of Sales', ja: '売上原価', ko: '매출원가', fr: 'Coût des ventes' },
      plGrossProfit: { 'zh-CN': '毛利', 'zh-TW': '毛利', en: 'Gross Profit', ja: '売上総利益', ko: '매출총이익', fr: 'Marge brute' },
      plAdmin:       { 'zh-CN': '销售及管理费用', 'zh-TW': '銷售及管理費用', en: 'SG&A Expense', ja: '販売費及び一般管理費', ko: '판관비', fr: 'Frais généraux' },
      plIncomeTax:   { 'zh-CN': '法人税', 'zh-TW': '法人稅', en: 'Corporate Tax', ja: '法人税等', ko: '법인세', fr: 'Impôt sur les sociétés' },
      plNetProfit:   { 'zh-CN': '当期净利润', 'zh-TW': '當期淨利潤', en: 'Net Income', ja: '当期純利益', ko: '당기순이익', fr: 'Résultat net' },
      plPeriodPrefix:{ 'zh-CN': '币种：日元 | 会计期间：', 'zh-TW': '幣種：日圓 | 會計期間：', en: 'Currency: JPY | Period: ', ja: '通貨：円 | 期間：', ko: '통화: JPY | 기간: ', fr: 'Devise : JPY | Période : ' },
      plTitle:       { 'zh-CN': '损益表', 'zh-TW': '損益表', en: 'Income Statement', ja: '損益計算書', ko: '손익계산서', fr: 'Compte de résultat' },
      tabPlLabel:    { 'zh-CN': '损益表', 'zh-TW': '損益表', en: 'P&L', ja: '損益計算書', ko: '손익', fr: 'Résultat' },
      formTaxRate:   { 'zh-CN': '消费税率', 'zh-TW': '消費稅率', en: 'Consumption Tax Rate', ja: '消費税率', ko: '소비세율', fr: 'Taux taxe consommation' },
      invoiceInputLabel: { 'zh-CN': '采购发票数', 'zh-TW': '採購發票數', en: 'Purchase Invoices', ja: '仕入請求書数', ko: '매입계산서', fr: 'Factures achats' },
      invoiceOutputLabel: { 'zh-CN': '销售发票数', 'zh-TW': '銷售發票數', en: 'Sales Invoices', ja: '売上請求書数', ko: '매출계산서', fr: 'Factures ventes' },
      invoicePendingTax: { 'zh-CN': '待申报消费税', 'zh-TW': '待申報消費稅', en: 'Pending Consumption Tax', ja: '未申告消費税', ko: '미신고 소비세', fr: 'Taxe consommation en attente' },
      invoiceTypeOutput: { 'zh-CN': '销项', 'zh-TW': '銷項', en: 'Sales', ja: '売上', ko: '매출', fr: 'Vente' },
      invoiceTypeInput: { 'zh-CN': '进项', 'zh-TW': '進項', en: 'Purchase', ja: '仕入', ko: '매입', fr: 'Achat' },
      inventoryUnit: { 'zh-CN': '单位', 'zh-TW': '單位', en: 'units', ja: '単位', ko: '단위', fr: 'unités' },
      taxSummaryTitle:{ 'zh-CN': '消费税含税汇总 (对账用)', 'zh-TW': '消費稅含稅匯總 (對帳用)', en: 'Tax-Inclusive Summary (Reconciliation)', ja: '税込金額集計（照合用）', ko: '소비세 포함 요약 (대조용)', fr: 'Résumé TTC (rapprochement)' },
      purchaseTotal: { 'zh-CN': '采购含税总额', 'zh-TW': '採購含稅總額', en: 'Purchase Total (Incl. Tax)', ja: '仕入税込合計', ko: '매입 세금포함 총액', fr: 'Total achats TTC' },
      salesTotal:    { 'zh-CN': '销售含税总额', 'zh-TW': '銷售含稅總額', en: 'Sales Total (Incl. Tax)', ja: '売上税込合計', ko: '매출 세금포함 총액', fr: 'Total ventes TTC' },
      taxDifference: { 'zh-CN': '消费税差额', 'zh-TW': '消費稅差額', en: 'Consumption Tax Difference', ja: '消費税差額', ko: '소비세 차액', fr: 'Différence taxe consommation' },
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
      certifiedInput:{ 'zh-CN': '可抵扣进项 VAT', 'zh-TW': '可抵扣進項 VAT', en: 'Deductible Input VAT', ja: '控除対象仕入VAT', ko: '공제 가능 매입 VAT', fr: 'TVA déductible certifiée' },
      invoicedOutput:{ 'zh-CN': '已开票销项 VAT', 'zh-TW': '已開票銷項 VAT', en: 'Invoiced Output VAT', ja: '請求済み売上VAT', ko: '발행된 매출 VAT', fr: 'TVA collectée facturée' },
      plRevenue:     { 'zh-CN': '营业收入', 'zh-TW': '營業收入', en: 'Revenue', ja: '売上', ko: '매출', fr: 'Chiffre d\'affaires' },
      plCost:        { 'zh-CN': '营业成本', 'zh-TW': '營業成本', en: 'Cost of Sales', ja: '売上原価', ko: '매출원가', fr: 'Coût des ventes' },
      plGrossProfit: { 'zh-CN': '毛利', 'zh-TW': '毛利', en: 'Gross Profit', ja: '粗利益', ko: '매출총이익', fr: 'Marge brute' },
      plAdmin:       { 'zh-CN': '管理费用', 'zh-TW': '管理費用', en: 'Admin Expense', ja: '一般管理費', ko: '관리비', fr: 'Frais administratifs' },
      plIncomeTax:   { 'zh-CN': '所得税', 'zh-TW': '所得稅', en: 'Income Tax', ja: '法人税', ko: '법인세', fr: 'Impôt sur le revenu' },
      plNetProfit:   { 'zh-CN': '净利润', 'zh-TW': '淨利潤', en: 'Net Profit', ja: '純利益', ko: '순이익', fr: 'Bénéfice net' },
      plPeriodPrefix:{ 'zh-CN': '币种：欧元 | 会计期间：', 'zh-TW': '幣種：歐元 | 會計期間：', en: 'Currency: EUR | Period: ', ja: '通貨：EUR | 期間：', ko: '통화: EUR | 기간: ', fr: 'Devise : EUR | Période : ' },
      plTitle:       { 'zh-CN': '损益表', 'zh-TW': '損益表', en: 'Profit & Loss', ja: '損益計算書', ko: '손익계산서', fr: 'Compte de résultat' },
      tabPlLabel:    { 'zh-CN': '损益表', 'zh-TW': '損益表', en: 'P&L', ja: '損益', ko: '손익', fr: 'Résultat' },
      formTaxRate:   { 'zh-CN': 'VAT 税率', 'zh-TW': 'VAT 稅率', en: 'VAT Rate', ja: 'VAT率', ko: 'VAT 세율', fr: 'Taux TVA' },
      invoiceInputLabel: { 'zh-CN': '进项 VAT 单据', 'zh-TW': '進項 VAT 單據', en: 'Input VAT Documents', ja: '仕入VAT書類', ko: '매입 VAT 서류', fr: 'Documents TVA achats' },
      invoiceOutputLabel: { 'zh-CN': '销项 VAT 单据', 'zh-TW': '銷項 VAT 單據', en: 'Output VAT Documents', ja: '売上VAT書類', ko: '매출 VAT 서류', fr: 'Documents TVA ventes' },
      invoicePendingTax: { 'zh-CN': '待申报 VAT', 'zh-TW': '待申報 VAT', en: 'Pending VAT Filing', ja: '未申告VAT', ko: '미신고 VAT', fr: 'TVA en attente de déclaration' },
      invoiceTypeOutput: { 'zh-CN': '销项', 'zh-TW': '銷項', en: 'Output', ja: '売上', ko: '매출', fr: 'Vente' },
      invoiceTypeInput: { 'zh-CN': '进项', 'zh-TW': '進項', en: 'Input', ja: '仕入', ko: '매입', fr: 'Achat' },
      inventoryUnit: { 'zh-CN': '单位', 'zh-TW': '單位', en: 'units', ja: '単位', ko: '단위', fr: 'unités' },
      taxSummaryTitle:{ 'zh-CN': 'VAT 含税汇总 (对账用)', 'zh-TW': 'VAT 含稅匯總 (對帳用)', en: 'VAT-Inclusive Summary (Reconciliation)', ja: 'VAT税込集計（照合用）', ko: 'VAT 세금포함 요약 (대조용)', fr: 'Résumé TTC TVA (rapprochement)' },
      purchaseTotal: { 'zh-CN': '采购含税总额', 'zh-TW': '採購含稅總額', en: 'Purchase Total (Incl. VAT)', ja: '仕入VAT込合計', ko: '매입 VAT포함 총액', fr: 'Total achats TTC' },
      salesTotal:    { 'zh-CN': '销售含税总额', 'zh-TW': '銷售含稅總額', en: 'Sales Total (Incl. VAT)', ja: '売上VAT込合計', ko: '매출 VAT포함 총액', fr: 'Total ventes TTC' },
      taxDifference: { 'zh-CN': 'VAT 差额', 'zh-TW': 'VAT 差額', en: 'VAT Difference', ja: 'VAT差額', ko: 'VAT 차액', fr: 'Différence TVA' },
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
      taxTitle:      { 'zh-CN': '韩国 VAT 统计', 'zh-TW': '韓國 VAT 統計', en: 'Korean VAT Summary', ja: '韓国VAT集計', ko: '부가가치세 요약', fr: 'Résumé TVA (Corée)' },
      inputTax:      { 'zh-CN': '进项 VAT', 'zh-TW': '進項 VAT', en: 'Input VAT', ja: '仕入VAT', ko: '매입세액', fr: 'TVA déductible' },
      outputTax:     { 'zh-CN': '销项 VAT', 'zh-TW': '銷項 VAT', en: 'Output VAT', ja: '売上VAT', ko: '매출세액', fr: 'TVA collectée' },
      estimatedTax:  { 'zh-CN': '预计应缴 VAT', 'zh-TW': '預計應繳 VAT', en: 'Estimated VAT Payable', ja: 'VAT推定納付額', ko: '예상 부가가치세 납부액', fr: 'TVA estimée à payer' },
      certifiedInput:{ 'zh-CN': '可抵扣进项 VAT', 'zh-TW': '可抵扣進項 VAT', en: 'Deductible Input VAT', ja: '控除対象仕入VAT', ko: '공제 가능 매입세액', fr: 'TVA déductible certifiée' },
      invoicedOutput:{ 'zh-CN': '已开票销项 VAT', 'zh-TW': '已開票銷項 VAT', en: 'Invoiced Output VAT', ja: '請求済み売上VAT', ko: '발행된 매출세액', fr: 'TVA collectée facturée' },
      plRevenue:     { 'zh-CN': '营业收入', 'zh-TW': '營業收入', en: 'Revenue', ja: '売上', ko: '매출', fr: 'Chiffre d\'affaires' },
      plCost:        { 'zh-CN': '营业成本', 'zh-TW': '營業成本', en: 'Cost of Sales', ja: '売上原価', ko: '매출원가', fr: 'Coût des ventes' },
      plGrossProfit: { 'zh-CN': '毛利', 'zh-TW': '毛利', en: 'Gross Profit', ja: '売上総利益', ko: '매출총이익', fr: 'Marge brute' },
      plAdmin:       { 'zh-CN': '销售及管理费用', 'zh-TW': '銷售及管理費用', en: 'SG&A Expense', ja: '販売費及び一般管理費', ko: '판매비와관리비', fr: 'Frais généraux' },
      plIncomeTax:   { 'zh-CN': '法人税', 'zh-TW': '法人稅', en: 'Corporate Tax', ja: '法人税', ko: '법인세', fr: 'Impôt sur les sociétés' },
      plNetProfit:   { 'zh-CN': '当期净利润', 'zh-TW': '當期淨利潤', en: 'Net Income', ja: '当期純利益', ko: '당기순이익', fr: 'Résultat net' },
      plPeriodPrefix:{ 'zh-CN': '币种：韩元 | 会计期间：', 'zh-TW': '幣種：韓元 | 會計期間：', en: 'Currency: KRW | Period: ', ja: '通貨：KRW | 期間：', ko: '통화: KRW | 기간: ', fr: 'Devise : KRW | Période : ' },
      plTitle:       { 'zh-CN': '损益表', 'zh-TW': '損益表', en: 'Income Statement', ja: '損益計算書', ko: '손익계산서', fr: 'Compte de résultat' },
      tabPlLabel:    { 'zh-CN': '损益表', 'zh-TW': '損益表', en: 'P&L', ja: '損益', ko: '손익계산서', fr: 'Résultat' },
      formTaxRate:   { 'zh-CN': '韩国 VAT 税率', 'zh-TW': '韓國 VAT 稅率', en: 'Korean VAT Rate', ja: '韓国VAT率', ko: '부가가치세율', fr: 'Taux TVA (Corée)' },
      invoiceInputLabel: { 'zh-CN': '进项税金计算书', 'zh-TW': '進項稅金計算書', en: 'Purchase Tax Invoices', ja: '仕入税金計算書', ko: '매입세금계산서', fr: 'Factures TVA achats' },
      invoiceOutputLabel: { 'zh-CN': '销项税金计算书', 'zh-TW': '銷項稅金計算書', en: 'Sales Tax Invoices', ja: '売上税金計算書', ko: '매출세금계산서', fr: 'Factures TVA ventes' },
      invoicePendingTax: { 'zh-CN': '待申报 VAT', 'zh-TW': '待申報 VAT', en: 'Pending VAT Filing', ja: '未申告VAT', ko: '미신고 부가가치세', fr: 'TVA en attente de déclaration' },
      invoiceTypeOutput: { 'zh-CN': '销项', 'zh-TW': '銷項', en: 'Sales', ja: '売上', ko: '매출', fr: 'Vente' },
      invoiceTypeInput: { 'zh-CN': '进项', 'zh-TW': '進項', en: 'Purchase', ja: '仕入', ko: '매입', fr: 'Achat' },
      inventoryUnit: { 'zh-CN': '单位', 'zh-TW': '單位', en: 'units', ja: '単位', ko: '단위', fr: 'unités' },
      taxSummaryTitle:{ 'zh-CN': '韩国 VAT 含税汇总（对账用）', 'zh-TW': '韓國 VAT 含稅匯總（對帳用）', en: 'Korean VAT-Inclusive Summary (Reconciliation)', ja: '韓国VAT税込集計（照合用）', ko: '한국 부가가치세 포함 요약 (대조용)', fr: 'Résumé TTC TVA Corée (rapprochement)' },
      purchaseTotal: { 'zh-CN': '采购含税总额', 'zh-TW': '採購含稅總額', en: 'Purchase Total (Incl. VAT)', ja: '仕入VAT込合計', ko: '매입 세금포함 총액', fr: 'Total achats TTC' },
      salesTotal:    { 'zh-CN': '销售含税总额', 'zh-TW': '銷售含稅總額', en: 'Sales Total (Incl. VAT)', ja: '売上VAT込合計', ko: '매출 세금포함 총액', fr: 'Total ventes TTC' },
      taxDifference: { 'zh-CN': 'VAT 差额', 'zh-TW': 'VAT 差額', en: 'VAT Difference', ja: 'VAT差額', ko: '부가가치세 차액', fr: 'Différence TVA' },
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
      certifiedInput:{ 'zh-CN': '可抵扣进项营业税', 'zh-TW': '可抵扣進項營業稅', en: 'Deductible Input Tax', ja: '控除対象仕入営業税', ko: '공제 가능 매입 영업세', fr: 'Taxe déductible certifiée' },
      invoicedOutput:{ 'zh-CN': '已开票销项营业税', 'zh-TW': '已開票銷項營業稅', en: 'Invoiced Output Tax', ja: '請求済み売上営業税', ko: '발행된 매출 영업세', fr: 'Taxe collectée facturée' },
      plRevenue:     { 'zh-CN': '銷售收入', 'zh-TW': '銷售收入', en: 'Sales Revenue', ja: '売上', ko: '매출', fr: 'Chiffre d\'affaires' },
      plCost:        { 'zh-CN': '銷貨成本', 'zh-TW': '銷貨成本', en: 'COGS', ja: '売上原価', ko: '매출원가', fr: 'Coût des ventes' },
      plGrossProfit: { 'zh-CN': '毛利', 'zh-TW': '毛利', en: 'Gross Profit', ja: '粗利益', ko: '매출총이익', fr: 'Marge brute' },
      plAdmin:       { 'zh-CN': '管理費用', 'zh-TW': '管理費用', en: 'Admin Expense', ja: '一般管理費', ko: '관리비', fr: 'Frais admin' },
      plIncomeTax:   { 'zh-CN': '營利事業所得稅', 'zh-TW': '營利事業所得稅', en: 'Business Income Tax', ja: '営利事業所得税', ko: '영리사업 소득세', fr: 'Impôt sur les bénéfices' },
      plNetProfit:   { 'zh-CN': '净利润', 'zh-TW': '淨利潤', en: 'Net Profit', ja: '純利益', ko: '순이익', fr: 'Bénéfice net' },
      plPeriodPrefix:{ 'zh-CN': '币种：新台币 | 会计期间：', 'zh-TW': '幣種：新臺幣 | 會計期間：', en: 'Currency: TWD | Period: ', ja: '通貨：TWD | 期間：', ko: '통화: TWD | 기간: ', fr: 'Devise : TWD | Période : ' },
      plTitle:       { 'zh-CN': '损益表', 'zh-TW': '損益表', en: 'Income Statement', ja: '損益計算書', ko: '손익계산서', fr: 'Compte de résultat' },
      tabPlLabel:    { 'zh-CN': '损益表', 'zh-TW': '損益表', en: 'P&L', ja: '損益', ko: '손익', fr: 'Résultat' },
      formTaxRate:   { 'zh-CN': '营业税率', 'zh-TW': '營業稅率', en: 'Business Tax Rate', ja: '営業税率', ko: '영업세율', fr: 'Taux taxe activité' },
      invoiceInputLabel: { 'zh-CN': '进项发票数', 'zh-TW': '進項發票數', en: 'Input Invoices', ja: '仕入請求書', ko: '매입계산서', fr: 'Factures achats' },
      invoiceOutputLabel: { 'zh-CN': '销项发票数', 'zh-TW': '銷項發票數', en: 'Output Invoices', ja: '売上請求書', ko: '매출계산서', fr: 'Factures ventes' },
      invoicePendingTax: { 'zh-CN': '待申报营业税', 'zh-TW': '待申報營業稅', en: 'Pending Business Tax', ja: '未申告営業税', ko: '미신고 영업세', fr: 'Taxe activité en attente' },
      invoiceTypeOutput: { 'zh-CN': '销项', 'zh-TW': '銷項', en: 'Output', ja: '売上', ko: '매출', fr: 'Vente' },
      invoiceTypeInput: { 'zh-CN': '进项', 'zh-TW': '進項', en: 'Input', ja: '仕入', ko: '매입', fr: 'Achat' },
      inventoryUnit: { 'zh-CN': '单位', 'zh-TW': '單位', en: 'units', ja: '単位', ko: '단위', fr: 'unités' },
      taxSummaryTitle:{ 'zh-CN': '营业税含税汇总 (对账用)', 'zh-TW': '營業稅含稅匯總 (對帳用)', en: 'Tax-Inclusive Summary (Reconciliation)', ja: '税込金額集計（照合用）', ko: '세금포함 요약 (대조용)', fr: 'Résumé TTC (rapprochement)' },
      purchaseTotal: { 'zh-CN': '采购含税总额', 'zh-TW': '採購含稅總額', en: 'Purchase Total (Incl. Tax)', ja: '仕入税込合計', ko: '매입 세금포함 총액', fr: 'Total achats TTC' },
      salesTotal:    { 'zh-CN': '销售含税总额', 'zh-TW': '銷售含稅總額', en: 'Sales Total (Incl. Tax)', ja: '売上税込合計', ko: '매출 세금포함 총액', fr: 'Total ventes TTC' },
      taxDifference: { 'zh-CN': '营业税差额', 'zh-TW': '營業稅差額', en: 'Business Tax Difference', ja: '営業税差額', ko: '영업세 차액', fr: 'Différence taxe activité' },
    },
    dashboardSections: ['profit_loss', 'profit_margins', 'business_tax_summary', 'tax_inclusive_summary'],
    reportTypes: ['income-statement', 'business-tax'],
    aiContext: 'Use Taiwan Business Tax (營業稅) 5% standard. 營利事業所得稅 20%.',
  },
};

export function getAccountingLocale(id: string): AccountingLocaleConfig {
  return ACCOUNTING_LOCALES[id as AccountingLocaleId] || ACCOUNTING_LOCALES.CN;
}
