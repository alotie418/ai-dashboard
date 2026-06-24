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

// ─── Non-CN generic business taxConcepts (shared base) ───
// Business-context labels that are the SAME for every non-CN accountingLocale
// (US / JP / KR / TW / EU): customer/supplier/document wording, NOT China-VAT
// (进项/销项/发票). Spread into JP/KR/TW/EU taxConcepts so any locale !== 'CN'
// renders generic wording while still localizing by uiLanguage. Tax-specific
// terms (Sales Tax / 消费税 / VAT / 營業稅) stay per-locale and override these.
// US keeps its own inline values (it predates this base) and is not spread.
const NON_CN_GENERIC: Record<string, TaxConceptLabels> = {
  // nav + page titles
  navPurchase:        { 'zh-CN': '采购与费用', 'zh-TW': '採購與費用', en: 'Purchases & Expenses', ja: '仕入・経費', ko: '매입 및 비용', fr: 'Achats & dépenses' },
  navSales:           { 'zh-CN': '销售与收入', 'zh-TW': '銷售與收入', en: 'Sales & Revenue', ja: '売上・収入', ko: '매출 및 수입', fr: 'Ventes & revenus' },
  invQueryTitle:      { 'zh-CN': '票据查询', 'zh-TW': '票據查詢', en: 'Document Search', ja: '伝票検索', ko: '문서 조회', fr: 'Recherche de pièces' },
  pageTitlePurchase:  { 'zh-CN': '采购与费用', 'zh-TW': '採購與費用', en: 'Purchases & Expenses', ja: '仕入と経費', ko: '매입 및 비용', fr: 'Achats & dépenses' },
  pageTitleSales:     { 'zh-CN': '销售与收入', 'zh-TW': '銷售與收入', en: 'Sales & Revenue', ja: '売上と収入', ko: '매출 및 수입', fr: 'Ventes & revenus' },
  // upload areas (receipt / bill / document — no 电子发票)
  uploadTitle:        { 'zh-CN': '拖放或点击上传收据、账单或票据', 'zh-TW': '拖放或點擊上傳收據、帳單或票據', en: 'Drag and drop or click to upload a receipt, bill or document', ja: 'レシート・請求書・伝票をドラッグまたはクリックでアップロード', ko: '영수증, 청구서 또는 전표를 드래그하거나 클릭해 업로드', fr: 'Glissez ou cliquez pour téléverser un reçu, une facture ou un justificatif' },
  uploadSubtitle:     { 'zh-CN': '自动提取日期、金额、供应商及票据号码', 'zh-TW': '自動擷取日期、金額、供應商及票據號碼', en: 'Auto-extract date, amount, vendor and document number', ja: '日付、金額、仕入先、伝票番号を自動抽出', ko: '날짜, 금액, 공급업체, 전표 번호를 자동 추출', fr: 'Extraction automatique de la date, du montant, du fournisseur et du numéro' },
  uploadTitleSales:   { 'zh-CN': '拖放或点击上传收据、账单或票据', 'zh-TW': '拖放或點擊上傳收據、帳單或票據', en: 'Drag and drop or click to upload a receipt, bill or document', ja: 'レシート・請求書・伝票をドラッグまたはクリックでアップロード', ko: '영수증, 청구서 또는 전표를 드래그하거나 클릭해 업로드', fr: 'Glissez ou cliquez pour téléverser un reçu, une facture ou un justificatif' },
  uploadSubtitleSales:{ 'zh-CN': '支持图片或 PDF，使用 AI 智能识别', 'zh-TW': '支援圖片或 PDF，使用 AI 智慧識別', en: 'Supports images or PDF, recognized by AI', ja: '画像またはPDFに対応、AIで自動認識', ko: '이미지 또는 PDF 지원, AI 자동 인식', fr: 'Images ou PDF, reconnaissance IA' },
  // OCR scanning-state text (shown while a document is being analyzed). Generic
  // 票据 / 往来单位 wording — never CN-VAT 进项 / 发票号(码). Shared by purchase + sales.
  scanningTitle:      { 'zh-CN': '正在分析票据…', 'zh-TW': '正在分析票據…', en: 'Analyzing document…', ja: '伝票を解析中…', ko: '문서 분석 중…', fr: 'Analyse du document…' },
  scanningSubtitle:   { 'zh-CN': 'AI 正在提取日期、金额、往来单位与税额…', 'zh-TW': 'AI 正在擷取日期、金額、往來單位與稅額…', en: 'AI is extracting date, amount, party and tax…', ja: 'AIが日付・金額・取引先・税額を抽出中…', ko: 'AI가 날짜·금액·거래처·세액을 추출 중…', fr: 'L’IA extrait la date, le montant, le tiers et la taxe…' },
  // table headers (pre-tax amounts; document number)
  headerUnitPrice:    { 'zh-CN': '税前单价', 'zh-TW': '稅前單價', en: 'Unit Price (pre-tax)', ja: '単価（税抜）', ko: '단가(세전)', fr: 'Prix unitaire (HT)' },
  headerAmount:       { 'zh-CN': '税前金额', 'zh-TW': '稅前金額', en: 'Amount (pre-tax)', ja: '金額（税抜）', ko: '금액(세전)', fr: 'Montant (HT)' },
  headerTaxAmount:    { 'zh-CN': '税额', 'zh-TW': '稅額', en: 'Tax', ja: '税額', ko: '세액', fr: 'Taxe' },
  headerTotalWithTax: { 'zh-CN': '总额', 'zh-TW': '總額', en: 'Total', ja: '合計', ko: '총액', fr: 'Total' },
  headerInvoiceNo:    { 'zh-CN': '票据号码', 'zh-TW': '票據號碼', en: 'Receipt / Document #', ja: '伝票番号', ko: '전표 번호', fr: 'N° de pièce' },
  // modals
  modalTitlePurchase: { 'zh-CN': '新增采购与费用记录', 'zh-TW': '新增採購與費用記錄', en: 'New Purchase / Expense', ja: '仕入・経費を追加', ko: '매입 및 비용 추가', fr: 'Nouvel achat / dépense' },
  modalSubtitlePurchase: { 'zh-CN': '请手动输入采购或费用明细', 'zh-TW': '請手動輸入採購或費用明細', en: 'Enter purchase or expense details manually', ja: '仕入または経費の詳細を入力', ko: '매입 또는 비용 세부 정보를 입력하세요', fr: "Saisir les détails de l'achat ou de la dépense" },
  modalTitleSales:    { 'zh-CN': '新增销售与收入记录', 'zh-TW': '新增銷售與收入記錄', en: 'New Sale / Revenue', ja: '売上・収入を追加', ko: '매출 및 수입 추가', fr: 'Nouvelle vente / revenu' },
  modalSubtitleSales: { 'zh-CN': '请手动输入销售或收入明细', 'zh-TW': '請手動輸入銷售或收入明細', en: 'Enter sale or revenue details manually', ja: '売上または収入の詳細を入力', ko: '매출 또는 수입 세부 정보를 입력하세요', fr: 'Saisir les détails de la vente ou du revenu' },
  // buttons + empty states
  newPurchaseButton:  { 'zh-CN': '新增采购记录', 'zh-TW': '新增採購記錄', en: 'New Purchase', ja: '仕入を追加', ko: '매입 추가', fr: 'Nouvel achat' },
  newSaleButton:      { 'zh-CN': '新增销售记录', 'zh-TW': '新增銷售記錄', en: 'New Sale', ja: '売上を追加', ko: '매출 추가', fr: 'Nouvelle vente' },
  emptyPurchase:      { 'zh-CN': '暂无采购或费用记录，请上传收据、账单或票据，或手动新增。', 'zh-TW': '暫無採購或費用記錄，請上傳收據、帳單或票據，或手動新增。', en: 'No purchase or expense records yet. Upload a receipt, bill or document, or add one manually.', ja: '仕入・経費の記録がありません。レシート・請求書・伝票をアップロードするか手動で追加してください。', ko: '매입/비용 기록이 없습니다. 영수증, 청구서, 전표를 업로드하거나 수동으로 추가하세요.', fr: 'Aucun achat/dépense. Téléversez un reçu, une facture ou ajoutez manuellement.' },
  emptySales:         { 'zh-CN': '暂无销售记录，请上传收据、账单或票据，或手动新增。', 'zh-TW': '暫無銷售記錄，請上傳收據、帳單或票據，或手動新增。', en: 'No sales records yet. Upload a receipt, bill or document, or add one manually.', ja: '売上記録がありません。レシート・請求書・伝票をアップロードするか手動で追加してください。', ko: '매출 기록이 없습니다. 영수증, 청구서, 전표를 업로드하거나 수동으로 추가하세요.', fr: 'Aucune vente. Téléversez un reçu, une facture ou ajoutez manuellement.' },
  // invoice-query (票据查询) basics: title / search / filter tabs / table headers
  invSearchPlaceholder:{ 'zh-CN': '搜索票据号码或往来单位...', 'zh-TW': '搜尋票據號碼或往來單位...', en: 'Search by document number or party...', ja: '伝票番号または取引先で検索...', ko: '문서 번호 또는 거래처로 검색...', fr: 'Rechercher par n° de pièce ou tiers...' },
  invFilterAll:       { 'zh-CN': '全部票据', 'zh-TW': '全部票據', en: 'All Documents', ja: 'すべての伝票', ko: '전체 문서', fr: 'Toutes les pièces' },
  invFilterInput:     { 'zh-CN': '采购与费用', 'zh-TW': '採購與費用', en: 'Purchases & Expenses', ja: '仕入・経費', ko: '매입 및 비용', fr: 'Achats & dépenses' },
  invFilterOutput:    { 'zh-CN': '销售与收入', 'zh-TW': '銷售與收入', en: 'Sales & Revenue', ja: '売上・収入', ko: '매출 및 수입', fr: 'Ventes & revenus' },
  invTableTitle:      { 'zh-CN': '票据流转全景视图', 'zh-TW': '票據流轉全景視圖', en: 'Document Flow Overview', ja: '伝票フロー全体ビュー', ko: '문서 흐름 개요', fr: "Vue d'ensemble des pièces" },
  invTableSubtitle:   { 'zh-CN': '核对票据流与库存/交易记录一致性', 'zh-TW': '核對票據流與庫存/交易記錄一致性', en: 'Reconcile document flow with inventory / transaction records', ja: '伝票フローと在庫・取引記録の整合性を確認', ko: '문서 흐름과 재고/거래 기록의 일관성 확인', fr: 'Rapprocher les pièces avec les stocks / transactions' },
  invHeaderDate:      { 'zh-CN': '业务日期', 'zh-TW': '業務日期', en: 'Date', ja: '取引日', ko: '거래일', fr: 'Date' },
  invHeaderWeight:    { 'zh-CN': '数量', 'zh-TW': '數量', en: 'Quantity', ja: '数量', ko: '수량', fr: 'Quantité' },
  invHeaderAmount:    { 'zh-CN': '金额', 'zh-TW': '金額', en: 'Amount', ja: '金額', ko: '금액', fr: 'Montant' },
  invHeaderInvoiceNo: { 'zh-CN': '票据号码', 'zh-TW': '票據號碼', en: 'Document #', ja: '伝票番号', ko: '문서 번호', fr: 'N° de pièce' },
  invEmpty:           { 'zh-CN': '未找到匹配的票据记录', 'zh-TW': '未找到匹配的票據記錄', en: 'No matching documents found', ja: '一致する伝票が見つかりません', ko: '일치하는 문서가 없습니다', fr: 'Aucune pièce correspondante' },
  // ── Accounts (应收应付) + Finance balance-sheet wording ──
  // Non-CN frames AR/AP by customer/supplier and uses owner's-equity terms
  // instead of China-GAAP 应收账款/应付账款/应交税费/实收资本/未分配利润. zh-CN/
  // zh-TW carry the agreed generic wording; en/ja/ko/fr match the finance.*
  // accounting terms so only the Chinese UI changes. (Values mirror the US
  // inline block, which is not spread from this base.)
  acctReceivableTab:  { 'zh-CN': '客户应收', 'zh-TW': '客戶應收', en: 'Customer Receivables', ja: '顧客売掛金', ko: '고객 미수금', fr: 'Créances clients' },
  acctPayableTab:     { 'zh-CN': '供应商应付', 'zh-TW': '供應商應付', en: 'Supplier Payables', ja: '仕入先買掛金', ko: '공급업체 미지급금', fr: 'Dettes fournisseurs' },
  acctTotalReceivable:{ 'zh-CN': '客户应收总额', 'zh-TW': '客戶應收總額', en: 'Total Customer Receivables', ja: '売掛金合計', ko: '고객 미수금 합계', fr: 'Total créances clients' },
  acctTotalPayable:   { 'zh-CN': '供应商应付总额', 'zh-TW': '供應商應付總額', en: 'Total Supplier Payables', ja: '買掛金合計', ko: '공급업체 미지급금 합계', fr: 'Total dettes fournisseurs' },
  balRecvLabel:       { 'zh-CN': '客户应收', 'zh-TW': '客戶應收', en: 'Accounts Receivable', ja: '売掛金', ko: '매출채권', fr: 'Créances clients' },
  balPayLabel:        { 'zh-CN': '供应商应付', 'zh-TW': '供應商應付', en: 'Accounts Payable', ja: '買掛金', ko: '매입채무', fr: 'Dettes fournisseurs' },
  balTaxPayLabel:     { 'zh-CN': '估算应付税款', 'zh-TW': '估算應付稅款', en: 'Estimated Tax Payable', ja: '推定未払税金', ko: '추정 미지급세금', fr: 'Dettes fiscales estimées' },
  balPaidInCapital:   { 'zh-CN': '所有者投入', 'zh-TW': '所有者投入', en: 'Paid-in Capital', ja: '資本金', ko: '납입자본금', fr: 'Capital social' },
  balRetainedEarnings:{ 'zh-CN': '留存收益', 'zh-TW': '留存收益', en: 'Retained Earnings', ja: '利益剰余金', ko: '이익잉여금', fr: 'Résultat reporté' },
  balLiabEquityHeader:{ 'zh-CN': '负债和所有者权益', 'zh-TW': '負債和所有者權益', en: 'Liabilities & Equity', ja: '負債及び純資産', ko: '부채 및 자본', fr: 'Passif' },
  balEquityHeader:    { 'zh-CN': '所有者权益', 'zh-TW': '所有者權益', en: 'Equity', ja: '純資産', ko: '자본', fr: 'Capitaux propres' },
  balTotalLiabEquity: { 'zh-CN': '负债和所有者权益总计', 'zh-TW': '負債和所有者權益總計', en: 'Total Liabilities & Equity', ja: '負債及び純資産合計', ko: '부채 및 자본 총계', fr: 'Total passif' },
  balCashflowAdd:     { 'zh-CN': '添加收支记录', 'zh-TW': '新增收支記錄', en: 'Add Transaction', ja: '取引を追加', ko: '거래 추가', fr: 'Ajouter une opération' },
  // ── System Settings (系统设置) — generic non-CN wording ──
  // Company / responsible-party / auto-process / deductible / notification /
  // data-migration labels that are the SAME for every non-CN locale (never
  // China-GAAP 统一社会信用代码 / 法定代表人 / 增值税 / 进项认证 / 税金及附加, and no
  // internal table/field/JSON names in the migration copy). The tax-ID field,
  // address & ID samples, tax-rate label, currency-per-year and tax hint differ
  // per regime and are defined per-locale on JP/KR/TW/EU below (US has its own
  // inline block and is not spread from this base).
  setNavAi:            { 'zh-CN': 'AI 服务商（BYOK）', 'zh-TW': 'AI 服務商（BYOK）', en: 'AI Providers (BYOK)', ja: 'AIプロバイダー（BYOK）', ko: 'AI 공급자(BYOK)', fr: 'Fournisseurs IA (BYOK)' },
  setLegalPersonLabel: { 'zh-CN': '负责人', 'zh-TW': '負責人', en: 'Responsible Party', ja: '代表者', ko: '대표자', fr: 'Responsable' },
  setLegalPersonPh:    { 'zh-CN': '例如：John Smith', 'zh-TW': '例如：John Smith', en: 'e.g. John Smith', ja: '例：John Smith', ko: '예: John Smith', fr: 'ex. : John Smith' },
  setCompanyNamePh:    { 'zh-CN': '例如：环球贸易有限公司', 'zh-TW': '例如：環球貿易有限公司', en: 'e.g. Global Trading Co., Ltd.', ja: '例：グローバル商事株式会社', ko: '예: 글로벌무역 주식회사', fr: 'ex. : Global Trading SARL' },
  setIndustryPh:       { 'zh-CN': '例如：贸易 / 零售 / 服务', 'zh-TW': '例如：貿易 / 零售 / 服務', en: 'e.g. Trade / Retail / Services', ja: '例：貿易／小売／サービス', ko: '예: 무역 / 소매 / 서비스', fr: 'ex. : Commerce / Détail / Services' },
  setRateByState:      { 'zh-CN': '标准税率', 'zh-TW': '標準稅率', en: 'Standard rate', ja: '標準税率', ko: '표준 세율', fr: 'Taux standard' },
  setRateCustom:       { 'zh-CN': '自定义税率', 'zh-TW': '自訂稅率', en: 'Custom rate', ja: 'カスタム税率', ko: '사용자 지정 세율', fr: 'Taux personnalisé' },
  setRateZero:         { 'zh-CN': '0%（免税）', 'zh-TW': '0%（免稅）', en: '0% (exempt)', ja: '0%（免税）', ko: '0% (면세)', fr: '0 % (exonéré)' },
  setAutoAuthLabel:    { 'zh-CN': '票据自动处理', 'zh-TW': '票據自動處理', en: 'Auto-process documents', ja: '伝票の自動処理', ko: '문서 자동 처리', fr: 'Traitement auto des pièces' },
  setAutoAuthDesc:     { 'zh-CN': '上传后自动用于分类、归档和报表统计', 'zh-TW': '上傳後自動用於分類、歸檔和報表統計', en: 'Uploaded documents are auto-categorized, filed, and included in reports', ja: 'アップロード後、自動的に分類・保管・集計', ko: '업로드 후 자동 분류·보관·집계', fr: 'Pièces classées, archivées et comptabilisées automatiquement' },
  setAdminExpenseLabel:{ 'zh-CN': '年度运营费用', 'zh-TW': '年度營運費用', en: 'Annual Operating Expenses', ja: '年間運営費', ko: '연간 운영비', fr: "Charges annuelles d'exploitation" },
  setDeductibleHeader: { 'zh-CN': '可扣除', 'zh-TW': '可扣除', en: 'Deductible', ja: '控除可', ko: '공제 가능', fr: 'Déductible' },
  setDeductiblePctLabel:{ 'zh-CN': '可扣除比例 (%)', 'zh-TW': '可扣除比例 (%)', en: 'Deductible %', ja: '控除割合 (%)', ko: '공제 비율 (%)', fr: 'Part déductible (%)' },
  // Alerts & notifications (threshold-based stock; 税款 not 税收)
  notifStockZero:      { 'zh-CN': '库存低于阈值提醒', 'zh-TW': '庫存低於閾值提醒', en: 'Low-stock alert (below threshold)', ja: '在庫が閾値を下回ったら通知', ko: '재고 임계값 미만 알림', fr: 'Alerte stock sous le seuil' },
  notifTaxDeviation:   { 'zh-CN': '税款偏差超过 15% 预警', 'zh-TW': '稅款偏差超過 15% 預警', en: 'Tax deviation over 15% alert', ja: '税額の乖離が15%を超えたら警告', ko: '세액 편차 15% 초과 경고', fr: 'Alerte écart de taxe supérieur à 15 %' },
  notifPriceVolatility:{ 'zh-CN': '异常价格波动提醒', 'zh-TW': '異常價格波動提醒', en: 'Unusual price movement alert', ja: '異常な価格変動を通知', ko: '비정상 가격 변동 알림', fr: 'Alerte de variation de prix inhabituelle' },
  notifMonthlyReport:  { 'zh-CN': '月度财务报告推送', 'zh-TW': '月度財務報告推送', en: 'Monthly financial report', ja: '月次財務レポートの配信', ko: '월간 재무 보고서 발송', fr: 'Rapport financier mensuel' },
  // Data migration (user-facing; no internal table/field/JSON names)
  dmSubtitle:          { 'zh-CN': '将旧版本销售和采购数据迁移为新的收入与费用记录。旧表仅保留备份，30 天内可回滚。', 'zh-TW': '將舊版本銷售和採購資料遷移為新的收入與費用記錄。舊表僅保留備份，30 天內可回復。', en: 'Migrate legacy sales & purchase data into the new income & expense records. Old data is kept as a backup and can be rolled back within 30 days.', ja: '旧版の売上・仕入データを新しい収入・費用の記録へ移行します。旧データはバックアップとして保持され、30日以内に元に戻せます。', ko: '이전 버전의 판매·구매 데이터를 새 수입·비용 기록으로 이전합니다. 기존 데이터는 백업으로 보관되며 30일 이내 되돌릴 수 있습니다.', fr: 'Migrez les anciennes données de ventes et achats vers les nouveaux enregistrements de revenus et dépenses. Les anciennes données sont conservées en sauvegarde et réversibles sous 30 jours.' },
  dmCardSales:         { 'zh-CN': '销售记录（旧版）→ 收入记录', 'zh-TW': '銷售記錄（舊版）→ 收入記錄', en: 'Sales records (legacy) → Income', ja: '売上記録（旧版）→ 収入', ko: '판매 기록(이전) → 수입', fr: 'Ventes (ancien) → Revenus' },
  dmCardPurchases:     { 'zh-CN': '采购记录（旧版）→ 费用记录', 'zh-TW': '採購記錄（舊版）→ 費用記錄', en: 'Purchase records (legacy) → Expenses', ja: '仕入記録（旧版）→ 費用', ko: '구매 기록(이전) → 비용', fr: 'Achats (ancien) → Dépenses' },
  dmNoLegacy:          { 'zh-CN': '没有需要迁移的旧版数据。', 'zh-TW': '沒有需要遷移的舊版資料。', en: 'No legacy data to migrate.', ja: '移行が必要な旧データはありません。', ko: '이전할 이전 데이터가 없습니다.', fr: 'Aucune ancienne donnée à migrer.' },
  dmResultIncome:      { 'zh-CN': '收入记录已迁移', 'zh-TW': '收入記錄已遷移', en: 'Income records migrated', ja: '収入の記録を移行しました', ko: '수입 기록 이전 완료', fr: 'Revenus migrés' },
  dmResultExpense:     { 'zh-CN': '费用记录已迁移', 'zh-TW': '費用記錄已遷移', en: 'Expense records migrated', ja: '費用の記録を移行しました', ko: '비용 기록 이전 완료', fr: 'Dépenses migrées' },
  dmRollbackConfirm:   { 'zh-CN': '确认回滚？这将删除 {count} 条已迁移的记录，旧数据保持不变。', 'zh-TW': '確認回復？這將刪除 {count} 筆已遷移的記錄，舊資料保持不變。', en: 'Roll back? This removes {count} migrated records; your old data stays unchanged.', ja: '元に戻しますか？移行済みの記録 {count} 件を削除します。旧データは変更されません。', ko: '되돌리시겠습니까? 이전된 기록 {count}건이 삭제되며 기존 데이터는 그대로 유지됩니다.', fr: 'Annuler ? Cela supprime {count} enregistrements migrés ; vos anciennes données restent intactes.' },
  dmRollback:          { 'zh-CN': '回滚迁移（删除已迁移的 {count} 条记录）', 'zh-TW': '回復遷移（刪除已遷移的 {count} 筆記錄）', en: 'Roll back migration (remove {count} migrated records)', ja: '移行を元に戻す（移行済み {count} 件を削除）', ko: '이전 되돌리기(이전된 {count}건 삭제)', fr: 'Annuler la migration (supprimer {count} enregistrements)' },
  dmNote1:             { 'zh-CN': '销售记录将迁移为收入记录，采购记录将迁移为费用记录。', 'zh-TW': '銷售記錄將遷移為收入記錄，採購記錄將遷移為費用記錄。', en: 'Sales records become income records; purchase records become expense records.', ja: '売上記録は収入に、仕入記録は費用に移行されます。', ko: '판매 기록은 수입으로, 구매 기록은 비용으로 이전됩니다.', fr: 'Les ventes deviennent des revenus ; les achats deviennent des dépenses.' },
  dmNote2:             { 'zh-CN': '旧表数据会保留，可随时回滚。', 'zh-TW': '舊表資料會保留，可隨時回復。', en: 'Old data is preserved and can be rolled back at any time.', ja: '旧データは保持され、いつでも元に戻せます。', ko: '기존 데이터는 보존되며 언제든 되돌릴 수 있습니다.', fr: 'Les anciennes données sont conservées et réversibles à tout moment.' },
  dmNote3:             { 'zh-CN': '迁移记录会保存原始记录快照，不会丢失。', 'zh-TW': '遷移記錄會保存原始記錄快照，不會遺失。', en: 'Each migration keeps a snapshot of the original record, so nothing is lost.', ja: '移行ごとに元の記録のスナップショットを保存するため、データは失われません。', ko: '이전 시 원본 기록 스냅샷을 저장하므로 데이터가 손실되지 않습니다.', fr: 'Chaque migration conserve un instantané de l’enregistrement d’origine ; rien n’est perdu.' },
  dmNote4:             { 'zh-CN': '原始的数量、单价、运费等明细会随记录一并保留。', 'zh-TW': '原始的數量、單價、運費等明細會隨記錄一併保留。', en: 'Original details such as quantity, unit price and shipping are preserved with each record.', ja: '数量・単価・送料などの元の明細も記録と共に保持されます。', ko: '수량·단가·배송비 등 원본 세부 정보도 기록과 함께 보존됩니다.', fr: 'Les détails d’origine (quantité, prix unitaire, frais de port) sont conservés avec chaque enregistrement.' },
  // ── Invoice-query (票据查询) stat cards / status filter / record counts ──
  // Generic non-CN document wording — never CN-VAT 进项/销项/认证/抵扣/待认证/
  // 已认证/已抵扣/预计可抵扣/发票号(码). zh-CN/zh-TW use 采购/费用·销售/收入·票据·
  // 待处理 framing; statuses are generic document statuses (核验/记录/处理). Values
  // mirror the US inline block (US is not spread from this base).
  invTotalInput:       { 'zh-CN': '累计采购/费用票据', 'zh-TW': '累計採購/費用票據', en: 'Total Purchase/Expense Documents', ja: '仕入・経費伝票数', ko: '매입/비용 문서 합계', fr: 'Total pièces achats/dépenses' },
  invTotalOutput:      { 'zh-CN': '累计销售/收入票据', 'zh-TW': '累計銷售/收入票據', en: 'Total Sales/Revenue Documents', ja: '売上・収入伝票数', ko: '매출/수입 문서 합계', fr: 'Total pièces ventes/revenus' },
  invPendingTax:       { 'zh-CN': '待处理税额', 'zh-TW': '待處理稅額', en: 'Pending Tax Amount', ja: '未処理税額', ko: '미처리 세액', fr: 'Taxe en attente' },
  invPendingTaxSub:    { 'zh-CN': '预计可处理税额', 'zh-TW': '預計可處理稅額', en: 'Estimated processable tax', ja: '処理予定税額', ko: '처리 예정 세액', fr: 'Taxe estimée à traiter' },
  invNoInput:          { 'zh-CN': '暂无采购/费用记录', 'zh-TW': '暫無採購/費用記錄', en: 'No purchase/expense records', ja: '仕入・経費の記録なし', ko: '매입/비용 기록 없음', fr: 'Aucun achat/dépense' },
  invNoOutput:         { 'zh-CN': '暂无销售/收入记录', 'zh-TW': '暫無銷售/收入記錄', en: 'No sales/revenue records', ja: '売上・収入の記録なし', ko: '매출/수입 기록 없음', fr: 'Aucune vente/revenu' },
  invDateRange:        { 'zh-CN': '业务日期范围', 'zh-TW': '業務日期範圍', en: 'Date Range', ja: '取引日範囲', ko: '거래일 범위', fr: 'Plage de dates' },
  invWeightRange:      { 'zh-CN': '数量范围', 'zh-TW': '數量範圍', en: 'Quantity Range', ja: '数量範囲', ko: '수량 범위', fr: 'Plage de quantité' },
  invStatusFilter:     { 'zh-CN': '票据状态', 'zh-TW': '票據狀態', en: 'Document Status', ja: '伝票ステータス', ko: '문서 상태', fr: 'Statut de la pièce' },
  invStatusAll:        { 'zh-CN': '全部状态', 'zh-TW': '全部狀態', en: 'All Statuses', ja: 'すべてのステータス', ko: '전체 상태', fr: 'Tous les statuts' },
  invStatusVerified:   { 'zh-CN': '已核验', 'zh-TW': '已核驗', en: 'Verified', ja: '確認済み', ko: '확인됨', fr: 'Vérifié' },
  invStatusCertified:  { 'zh-CN': '已记录', 'zh-TW': '已記錄', en: 'Recorded', ja: '記録済み', ko: '기록됨', fr: 'Enregistré' },
  invStatusDeducted:   { 'zh-CN': '已处理', 'zh-TW': '已處理', en: 'Processed', ja: '処理済み', ko: '처리됨', fr: 'Traité' },
  invStatusPendingCert:{ 'zh-CN': '待处理', 'zh-TW': '待處理', en: 'Pending', ja: '保留中', ko: '대기 중', fr: 'En attente' },
  invStatusPendingIssue:{ 'zh-CN': '待票据', 'zh-TW': '待票據', en: 'Awaiting Document', ja: '伝票待ち', ko: '문서 대기', fr: 'En attente de pièce' },
  invStatusIssued:     { 'zh-CN': '已开票', 'zh-TW': '已開票', en: 'Issued', ja: '発行済み', ko: '발행됨', fr: 'Émis' },
  invAdvFilterActive:  { 'zh-CN': '已启用筛选，找到 {count} 条票据记录', 'zh-TW': '已啟用篩選，找到 {count} 筆票據記錄', en: 'Filter active — {count} document(s) found', ja: 'フィルター適用中 — {count} 件の伝票', ko: '필터 적용됨 — 문서 {count}건', fr: 'Filtre actif — {count} pièce(s)' },
  invInputRecordCount: { 'zh-CN': '{count} 条采购/费用记录', 'zh-TW': '{count} 筆採購/費用記錄', en: '{count} purchase/expense record(s)', ja: '仕入・経費 {count} 件', ko: '매입/비용 {count}건', fr: '{count} achat(s)/dépense(s)' },
  invOutputRecordCount:{ 'zh-CN': '{count} 条销售/收入记录', 'zh-TW': '{count} 筆銷售/收入記錄', en: '{count} sales/revenue record(s)', ja: '売上・収入 {count} 件', ko: '매출/수입 {count}건', fr: '{count} vente(s)/revenu(s)' },
  // ── AI assistant document-extraction result (智能助手识别结果) ──
  // Generic non-CN result message — 票据/票据号码 framing and the non-CN nav names
  // (采购与费用 / 销售与收入), never CN-VAT 采购与进项 / 销售与销项 / 进项 / 销项 /
  // 发票号. The {date}/{partner}/{quantity}/{amount}/{shipping}/{invoiceNo} tokens
  // are substituted at render (getTaxLabel returns a plain string, no i18next
  // interpolation). CN keeps its own chat.invoiceExtractResult i18n message.
  chatExtractResult:  {
    'zh-CN': '票据识别成功！\n\n日期: {date}\n客户/供应商: {partner}\n数量: {quantity}\n金额: {amount}\n运费: {shipping}\n票据号码: {invoiceNo}\n\n以上信息已从票据中提取。如需记账，请前往「采购与费用」或「销售与收入」页面录入。',
    'zh-TW': '票據辨識成功！\n\n日期: {date}\n客戶/供應商: {partner}\n數量: {quantity}\n金額: {amount}\n運費: {shipping}\n票據號碼: {invoiceNo}\n\n以上資訊已從票據中擷取。如需記帳，請前往「採購與費用」或「銷售與收入」頁面錄入。',
    en: 'Document extracted successfully!\n\nDate: {date}\nCustomer/Supplier: {partner}\nQuantity: {quantity}\nAmount: {amount}\nShipping: {shipping}\nDocument #: {invoiceNo}\n\nGo to Purchases & Expenses or Sales & Revenue to record this transaction.',
    ja: '伝票の認識に成功しました！\n\n日付: {date}\n顧客/仕入先: {partner}\n数量: {quantity}\n金額: {amount}\n送料: {shipping}\n伝票番号: {invoiceNo}\n\n仕入・経費または売上・収入のページから記帳できます。',
    ko: '문서 인식 성공!\n\n날짜: {date}\n고객/공급업체: {partner}\n수량: {quantity}\n금액: {amount}\n배송비: {shipping}\n문서 번호: {invoiceNo}\n\n매입 및 비용 또는 매출 및 수입 페이지로 이동하여 기록하세요.',
    fr: 'Pièce extraite avec succès !\n\nDate : {date}\nClient/Fournisseur : {partner}\nQuantité : {quantity}\nMontant : {amount}\nFrais de port : {shipping}\nN° de pièce : {invoiceNo}\n\nAllez sur Achats & dépenses ou Ventes & revenus pour enregistrer.',
  },
};

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
      certifiedInput:{ 'zh-CN': '进项税额合计', 'zh-TW': '進項稅額合計', en: 'Total Input VAT', ja: '仕入税額合計', ko: '매입세액 합계', fr: 'TVA déductible (total)' },
      invoicedOutput:{ 'zh-CN': '销项税额合计', 'zh-TW': '銷項稅額合計', en: 'Total Output VAT', ja: '売上税額合計', ko: '매출세액 합계', fr: 'TVA collectée (total)' },
      estimatedTax:  { 'zh-CN': '增值税估算额', 'zh-TW': '增值稅估算額', en: 'Estimated VAT', ja: '増値税の試算額', ko: '부가가치세 추정액', fr: 'TVA estimée' },
      taxSummaryTitle:{ 'zh-CN': '含税金额汇总 (对账用)', 'zh-TW': '含稅金額統計', en: 'Tax-Inclusive Summary (Reconciliation)', ja: '税込金額集計（照合用）', ko: '세금 포함 금액 요약 (대조용)', fr: 'Résumé TTC (rapprochement)' },
      purchaseTotal: { 'zh-CN': '采购含税总额', 'zh-TW': '採購含稅總額', en: 'Purchase Total (Incl. Tax)', ja: '仕入税込合計', ko: '매입 세금포함 총액', fr: 'Total achats TTC' },
      salesTotal:    { 'zh-CN': '销售含税总额', 'zh-TW': '銷售含稅總額', en: 'Sales Total (Incl. Tax)', ja: '売上税込合計', ko: '매출 세금포함 총액', fr: 'Total ventes TTC' },
      taxDifference: { 'zh-CN': '含税差额', 'zh-TW': '含稅差額', en: 'Tax-Inclusive Difference', ja: '税込差額', ko: '세금포함 차액', fr: 'Différence TTC' },
      surchargeNote: { 'zh-CN': '税金及附加按增值税自动计算', 'zh-TW': '稅金及附加按增值稅自動計算', en: 'Tax surcharge auto-calculated from VAT', ja: '付加税は増値税から自動計算', ko: '부가세에서 자동 계산', fr: 'Surtaxe calculée automatiquement' },
      // P&L labels
      plRevenue:     { 'zh-CN': '一、营业收入', 'zh-TW': '一、營業收入', en: 'I. Revenue', ja: 'Ⅰ. 売上高', ko: 'Ⅰ. 매출', fr: 'I. Chiffre d\'affaires' },
      plCost:        { 'zh-CN': '减：营业成本', 'zh-TW': '減：營業成本', en: 'Less: COGS', ja: '売上原価', ko: '매출원가', fr: 'Coût des ventes' },
      plGrossProfit: { 'zh-CN': '二、毛利', 'zh-TW': '二、毛利', en: 'II. Gross Profit', ja: 'Ⅱ. 売上総利益', ko: 'Ⅱ. 매출총이익', fr: 'II. Marge brute' },
      plOperatingExpenses: { 'zh-CN': '减：期间费用', 'zh-TW': '減：期間費用', en: 'Less: Operating Expenses', ja: '営業費用', ko: '영업비용', fr: "Charges d'exploitation" },
      plOperatingProfit: { 'zh-CN': '经营利润', 'zh-TW': '經營利潤', en: 'Operating Profit', ja: '営業利益', ko: '영업이익', fr: "Résultat d'exploitation" },
      plTaxSurcharge:{ 'zh-CN': '减：税金及附加', 'zh-TW': '減：稅金及附加', en: 'Less: Tax Surcharge', ja: '租税公課', ko: '제세공과금', fr: 'Taxes et surtaxes' },
      plShipping:    { 'zh-CN': '减：运费支出 (销售费用)', 'zh-TW': '減：運費支出 (銷售費用)', en: 'Less: Shipping Expense', ja: '運送費', ko: '운송비', fr: 'Frais de livraison' },
      plAdmin:       { 'zh-CN': '减：管理费用', 'zh-TW': '減：管理費用', en: 'Less: Admin Expense', ja: '一般管理費', ko: '관리비', fr: 'Frais administratifs' },
      plIncomeTax:   { 'zh-CN': '减：所得税费用', 'zh-TW': '減：所得稅費用', en: 'Less: Income Tax', ja: '法人税等', ko: '법인세', fr: 'Impôt sur le revenu' },
      plNetProfit:   { 'zh-CN': '三、净利润', 'zh-TW': '三、淨利潤', en: 'III. Net Profit', ja: 'Ⅲ. 当期純利益', ko: 'Ⅲ. 당기순이익', fr: 'III. Bénéfice net' },
      plPeriodPrefix:{ 'zh-CN': '单位：人民币元 | 会计期间：', 'zh-TW': '單位：人民幣元 | 會計期間：', en: 'Period: ', ja: '会計期間：', ko: '회계기간: ', fr: 'Période : ' },
      plTitle:       { 'zh-CN': '经营损益概览', 'zh-TW': '經營損益概覽', en: 'Management P&L', ja: '経営損益サマリー', ko: '경영 손익 개요', fr: 'Aperçu du résultat (gestion)' },
      tabPlLabel:    { 'zh-CN': '经营损益', 'zh-TW': '經營損益', en: 'Operating P&L', ja: '経営損益', ko: '경영 손익', fr: 'Résultat (gestion)' },
      formTaxRate:   { 'zh-CN': '增值税率', 'zh-TW': '增值稅率', en: 'VAT Rate', ja: '増値税率', ko: '증치세율', fr: 'Taux VAT' },
      invoiceInputLabel: { 'zh-CN': '累计进项票数', 'zh-TW': '累計進項票數', en: 'Total Input Invoices', ja: '仕入請求書数', ko: '매입세금계산서', fr: 'Factures achats' },
      invoiceOutputLabel: { 'zh-CN': '累计销项票数', 'zh-TW': '累計銷項票數', en: 'Total Output Invoices', ja: '売上請求書数', ko: '매출세금계산서', fr: 'Factures ventes' },
      invoicePendingTax: { 'zh-CN': '待处理进项税额', 'zh-TW': '待處理進項稅額', en: 'Pending Input VAT', ja: '未処理仕入税額', ko: '미처리 매입세액', fr: 'TVA achats à traiter' },
      invoiceTypeOutput: { 'zh-CN': '销项', 'zh-TW': '銷項', en: 'Output', ja: '売上', ko: '매출', fr: 'Vente' },
      invoiceTypeInput: { 'zh-CN': '进项', 'zh-TW': '進項', en: 'Input', ja: '仕入', ko: '매입', fr: 'Achat' },
      inventoryUnit: { 'zh-CN': '数量', 'zh-TW': '數量', en: 'units', ja: '単位', ko: '단위', fr: 'unités' },
    },
    dashboardSections: ['profit_loss', 'profit_margins', 'vat_summary', 'tax_inclusive_summary'],
    reportTypes: ['income-statement', 'vat-summary', 'tax-inclusive'],
    aiContext: 'Use Chinese VAT accounting concepts (Input VAT vs Output VAT, the VAT surcharge, and corporate income tax). Use the tax rates the user configured in settings rather than assuming fixed rates, and treat all figures as management estimates, not statutory amounts.',
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
      plOperatingExpenses: { 'zh-CN': '期间费用', 'zh-TW': '期間費用', en: 'Operating Expenses', ja: '営業費用', ko: '영업비용', fr: "Charges d'exploitation" },
      plOperatingProfit: { 'zh-CN': '经营利润', 'zh-TW': '經營利潤', en: 'Operating Profit', ja: '営業利益', ko: '영업이익', fr: "Résultat d'exploitation" },
      plAdmin:       { 'zh-CN': '办公费用 (Line 18)', 'zh-TW': '辦公費用 (Line 18)', en: 'Office Expense (Line 18)', ja: '事務費 (Line 18)', ko: '사무비 (Line 18)', fr: 'Frais de bureau (Line 18)' },
      plIncomeTax:   { 'zh-CN': '联邦所得税', 'zh-TW': '聯邦所得稅', en: 'Federal Income Tax', ja: '連邦所得税', ko: '연방 소득세', fr: 'Impôt fédéral' },
      plNetProfit:   { 'zh-CN': '净利润', 'zh-TW': '淨利潤', en: 'Net Profit', ja: '純利益', ko: '순이익', fr: 'Bénéfice net' },
      plPeriodPrefix:{ 'zh-CN': '币种：美元 | 会计期间：', 'zh-TW': '幣種：美元 | 會計期間：', en: 'Currency: USD | Period: ', ja: '通貨：USD | 期間：', ko: '통화: USD | 기간: ', fr: 'Devise : USD | Période : ' },
      plTitle:       { 'zh-CN': '经营损益概览（Schedule C 科目）', 'zh-TW': '經營損益概覽（Schedule C 科目）', en: 'Management P&L (Schedule C basis)', ja: '経営損益サマリー（Schedule C）', ko: '경영 손익 개요 (Schedule C)', fr: 'Aperçu du résultat (Schedule C)' },
      tabPlLabel:    { 'zh-CN': 'Schedule C', 'zh-TW': 'Schedule C', en: 'Schedule C', ja: 'Schedule C', ko: 'Schedule C', fr: 'Schedule C' },
      formTaxRate:   { 'zh-CN': 'Sales Tax（销售税）税率', 'zh-TW': 'Sales Tax（銷售稅）稅率', en: 'Sales Tax Rate', ja: '売上税率', ko: '판매세율', fr: 'Taux de taxe de vente' },
      kpiGrossIncome:{ 'zh-CN': '总收入', 'zh-TW': '總收入', en: 'Gross Income', ja: '総所得', ko: '총소득', fr: 'Revenu brut' },
      kpiQuarterlyTax:{ 'zh-CN': '预估季度税', 'zh-TW': '預估季度稅', en: 'Est. Quarterly Tax', ja: '四半期予定税', ko: '예상 분기 세금', fr: 'Acompte trimestriel' },
      profitMargins: { 'zh-CN': '利润率指标', 'zh-TW': '利潤率指標', en: 'Profit Margins', ja: '利益率指標', ko: '이익률 지표', fr: 'Marges bénéficiaires' },
      grossMargin:   { 'zh-CN': '毛利率', 'zh-TW': '毛利率', en: 'Gross Margin', ja: '粗利率', ko: '매출총이익률', fr: 'Marge brute' },
      netMargin:     { 'zh-CN': '净利率', 'zh-TW': '淨利率', en: 'Net Margin', ja: '純利益率', ko: '순이익률', fr: 'Marge nette' },
      socialSecurity:{ 'zh-CN': '社会保障税（Social Security，12.4%）', 'zh-TW': '社會保障稅（Social Security，12.4%）', en: 'Social Security (12.4%)', ja: 'Social Security（社会保障税） (12.4%)', ko: 'Social Security (사회보장세) (12.4%)', fr: 'Social Security (sécurité sociale) (12.4%)' },
      medicare:      { 'zh-CN': '医疗保险税（Medicare，2.9%）', 'zh-TW': '醫療保險稅（Medicare，2.9%）', en: 'Medicare (2.9%)', ja: 'Medicare（医療保険税） (2.9%)', ko: 'Medicare (의료보험세) (2.9%)', fr: 'Medicare (assurance maladie) (2.9%)' },
      additionalMedicare: { 'zh-CN': 'Additional Medicare（附加医疗保险税）', 'zh-TW': 'Additional Medicare（附加醫療保險稅）', en: 'Additional Medicare', ja: 'Additional Medicare（追加医療保険税）', ko: 'Additional Medicare (추가 의료보험세)', fr: 'Additional Medicare (taxe additionnelle)' },
      dueLabel:      { 'zh-CN': '到期日', 'zh-TW': '到期日', en: 'Due', ja: '期限', ko: '납기', fr: 'Échéance' },
      pageTitlePurchase:  { 'zh-CN': '采购与费用', 'zh-TW': '採購與費用', en: 'Purchases & Expenses', ja: '仕入と経費', ko: '매입 및 비용', fr: 'Achats & dépenses' },
      uploadTitle:        { 'zh-CN': '拖放或点击上传收据、账单或发票', 'zh-TW': '拖放或點擊上傳收據、帳單或發票', en: 'Drag and drop or click to upload a receipt, bill or invoice', ja: 'レシート・請求書・伝票をドラッグまたはクリックでアップロード', ko: '영수증, 청구서 또는 인보이스를 드래그하거나 클릭해 업로드', fr: 'Glissez ou cliquez pour téléverser un reçu, une facture ou un justificatif' },
      uploadSubtitle:     { 'zh-CN': '自动提取日期、金额、收款方及票据号码', 'zh-TW': '自動擷取日期、金額、收款方及票據號碼', en: 'Auto-extract date, amount, vendor and receipt/invoice number', ja: '日付、金額、仕入先、伝票番号を自動抽出', ko: '날짜, 금액, 공급업체, 영수증 번호를 자동 추출', fr: 'Extraction automatique de la date, du montant, du fournisseur et du numéro' },
      headerUnitPrice:    { 'zh-CN': '单价', 'zh-TW': '單價', en: 'Unit Price', ja: '単価', ko: '단가', fr: 'Prix unitaire' },
      headerAmount:       { 'zh-CN': '金额', 'zh-TW': '金額', en: 'Amount', ja: '金額', ko: '금액', fr: 'Montant' },
      headerTaxAmount:    { 'zh-CN': '税额', 'zh-TW': '稅額', en: 'Tax', ja: '税額', ko: '세액', fr: 'Taxe' },
      headerTotalWithTax: { 'zh-CN': '总额', 'zh-TW': '總額', en: 'Total', ja: '合計', ko: '총액', fr: 'Total' },
      headerInvoiceNo:    { 'zh-CN': '票据号码', 'zh-TW': '票據號碼', en: 'Receipt / Invoice #', ja: '伝票番号', ko: '영수증 번호', fr: 'N° de pièce' },
      modalTitlePurchase: { 'zh-CN': '新增支出记录', 'zh-TW': '新增支出記錄', en: 'New Purchase / Expense', ja: '仕入・経費を追加', ko: '매입 및 비용 추가', fr: 'Nouvel achat / dépense' },
      modalSubtitlePurchase: { 'zh-CN': '请手动输入支出明细', 'zh-TW': '請手動輸入支出明細', en: 'Enter purchase or expense details manually', ja: '仕入または経費の詳細を入力', ko: '매입 또는 비용 세부 정보를 입력하세요', fr: 'Saisir les détails de l\'achat ou de la dépense' },
      pageTitleSales:     { 'zh-CN': '销售与收入', 'zh-TW': '銷售與收入', en: 'Sales & Revenue', ja: '売上と収入', ko: '매출 및 수입', fr: 'Ventes & revenus' },
      uploadTitleSales:   { 'zh-CN': '拖放或点击上传收据、账单或发票', 'zh-TW': '拖放或點擊上傳收據、帳單或發票', en: 'Drag and drop or click to upload a receipt, bill or invoice', ja: 'レシート・請求書・伝票をドラッグまたはクリックでアップロード', ko: '영수증, 청구서 또는 인보이스를 드래그하거나 클릭해 업로드', fr: 'Glissez ou cliquez pour téléverser un reçu, une facture ou un justificatif' },
      uploadSubtitleSales:{ 'zh-CN': '支持图片或 PDF，使用 AI 智能识别', 'zh-TW': '支援圖片或 PDF，使用 AI 智慧識別', en: 'Supports images or PDF, recognized by AI', ja: '画像またはPDFに対応、AIで自動認識', ko: '이미지 또는 PDF 지원, AI 자동 인식', fr: 'Images ou PDF, reconnaissance IA' },
      // OCR scanning-state text — generic 票据/往来单位 wording (US is not spread from NON_CN_GENERIC).
      scanningTitle:      { 'zh-CN': '正在分析票据…', 'zh-TW': '正在分析票據…', en: 'Analyzing document…', ja: '伝票を解析中…', ko: '문서 분석 중…', fr: 'Analyse du document…' },
      scanningSubtitle:   { 'zh-CN': 'AI 正在提取日期、金额、往来单位与税额…', 'zh-TW': 'AI 正在擷取日期、金額、往來單位與稅額…', en: 'AI is extracting date, amount, party and tax…', ja: 'AIが日付・金額・取引先・税額を抽出中…', ko: 'AI가 날짜·금액·거래처·세액을 추출 중…', fr: 'L’IA extrait la date, le montant, le tiers et la taxe…' },
      emptySales:         { 'zh-CN': '暂无销售或收入记录，请上传收据、账单或发票，或手动新增。', 'zh-TW': '暫無銷售或收入記錄，請上傳收據、帳單或發票，或手動新增。', en: 'No sales or revenue records yet. Upload a receipt, bill or invoice, or add one manually.', ja: '売上・収入の記録がありません。レシート・請求書・伝票をアップロードするか手動で追加してください。', ko: '매출 또는 수입 기록이 없습니다. 영수증, 청구서, 인보이스를 업로드하거나 수동으로 추가하세요.', fr: 'Aucune vente ni recette. Téléversez un reçu, une facture ou ajoutez manuellement.' },
      emptyPurchase:      { 'zh-CN': '暂无采购或费用记录，请上传收据、账单、发票或手动新增。', 'zh-TW': '暫無採購或費用記錄，請上傳收據、帳單、發票或手動新增。', en: 'No purchase or expense records yet. Upload a receipt, bill, invoice, or add one manually.', ja: '仕入・経費の記録がありません。レシート・請求書・伝票をアップロードするか手動で追加してください。', ko: '매입/비용 기록이 없습니다. 영수증, 청구서, 인보이스를 업로드하거나 수동으로 추가하세요.', fr: 'Aucun achat/dépense. Téléversez un reçu, une facture ou ajoutez manuellement.' },
      // Sales-page inventory banner totals — US frames them as quantity stats, not
      // the CN 总采购/总销售 commodity-inventory wording (US-only; CN/JP/KR/TW/EU keep sales.inventory*).
      salesBannerPurchaseQty: { 'zh-CN': '采购数量', 'zh-TW': '採購數量', en: 'Purchase Qty', ja: '仕入数量', ko: '매입 수량', fr: 'Quantité achats' },
      salesBannerSalesQty:    { 'zh-CN': '销售数量', 'zh-TW': '銷售數量', en: 'Sales Qty', ja: '売上数量', ko: '매출 수량', fr: 'Quantité ventes' },
      newPurchaseButton:  { 'zh-CN': '新增支出', 'zh-TW': '新增支出', en: 'New Purchase', ja: 'New Purchase', ko: 'New Purchase', fr: 'New Purchase' },
      modalTitleSales:    { 'zh-CN': '新增收入记录', 'zh-TW': '新增收入記錄', en: 'New Sale / Revenue', ja: '売上・収入を追加', ko: '매출 및 수입 추가', fr: 'Nouvelle vente / revenu' },
      modalSubtitleSales: { 'zh-CN': '请手动输入收入明细', 'zh-TW': '請手動輸入收入明細', en: 'Enter sale or revenue details manually', ja: '売上または収入の詳細を入力', ko: '매출 또는 수입 세부 정보를 입력하세요', fr: 'Saisir les détails de la vente ou du revenu' },
      // US 采购与费用 / 销售与收入 表单 — 收款方/数量 用词，仅在 accLocale==='US' && uiLang∈zh 时显示；
      // en/ja/ko/fr 不经此键渲染（页面仍走各自 i18n 标签），此处值仅供 matrix presence/ban 检查。
      setHeaderPayee:     { 'zh-CN': '收款方', 'zh-TW': '收款方', en: 'Payee', ja: '支払先', ko: '지급처', fr: 'Bénéficiaire' },
      setFormPayeeLabel:  { 'zh-CN': '收款方名称', 'zh-TW': '收款方名稱', en: 'Payee Name', ja: '支払先名', ko: '지급처명', fr: 'Nom du bénéficiaire' },
      setFormPayeePh:     { 'zh-CN': '请输入收款方名称', 'zh-TW': '請輸入收款方名稱', en: 'Enter payee name', ja: '支払先名を入力', ko: '지급처명 입력', fr: 'Saisir le bénéficiaire' },
      setFormCustomerPh:  { 'zh-CN': '请输入客户名称', 'zh-TW': '請輸入客戶名稱', en: 'Enter customer name', ja: '顧客名を入力', ko: '고객명 입력', fr: 'Saisir le nom du client' },
      setFormQtyLabel:    { 'zh-CN': '数量（可选）', 'zh-TW': '數量（可選）', en: 'Quantity (optional)', ja: '数量（任意）', ko: '수량(선택)', fr: 'Quantité (facultatif)' },
      setFormQtyPh:       { 'zh-CN': '例如：1', 'zh-TW': '例如：1', en: 'e.g. 1', ja: '例：1', ko: '예: 1', fr: 'ex. : 1' },
      navSales:           { 'zh-CN': '销售与收入', 'zh-TW': '銷售與收入', en: 'Sales & Revenue', ja: '売上・収入', ko: '매출 및 수입', fr: 'Ventes & revenus' },
      navPurchase:        { 'zh-CN': '采购与费用', 'zh-TW': '採購與費用', en: 'Purchases & Expenses', ja: '仕入・経費', ko: '매입 및 비용', fr: 'Achats & dépenses' },
      invQueryTitle:      { 'zh-CN': '票据查询', 'zh-TW': '票據查詢', en: 'Document Search', ja: '伝票検索', ko: '문서 조회', fr: 'Recherche de pièces' },
      invSearchPlaceholder:{ 'zh-CN': '搜索票据号码或往来单位...', 'zh-TW': '搜尋票據號碼或往來單位...', en: 'Search by document number or party...', ja: '伝票番号または取引先で検索...', ko: '문서 번호 또는 거래처로 검색...', fr: 'Rechercher par n° de pièce ou tiers...' },
      invFilterAll:       { 'zh-CN': '全部票据', 'zh-TW': '全部票據', en: 'All Documents', ja: 'すべての伝票', ko: '전체 문서', fr: 'Toutes les pièces' },
      invFilterInput:     { 'zh-CN': '采购与费用', 'zh-TW': '採購與費用', en: 'Purchases & Expenses', ja: '仕入・経費', ko: '매입 및 비용', fr: 'Achats & dépenses' },
      invFilterOutput:    { 'zh-CN': '销售与收入', 'zh-TW': '銷售與收入', en: 'Sales & Revenue', ja: '売上・収入', ko: '매출 및 수입', fr: 'Ventes & revenus' },
      invTotalInput:      { 'zh-CN': '累计采购/费用票据', 'zh-TW': '累計採購/費用票據', en: 'Total Purchase/Expense Documents', ja: '仕入・経費伝票数', ko: '매입/비용 문서 합계', fr: 'Total pièces achats/dépenses' },
      invTotalOutput:     { 'zh-CN': '累计销售/收入票据', 'zh-TW': '累計銷售/收入票據', en: 'Total Sales/Revenue Documents', ja: '売上・収入伝票数', ko: '매출/수입 문서 합계', fr: 'Total pièces ventes/revenus' },
      invPendingTax:      { 'zh-CN': '待处理税额', 'zh-TW': '待處理稅額', en: 'Pending Tax Amount', ja: '未処理税額', ko: '미처리 세액', fr: 'Taxe en attente' },
      invPendingTaxSub:   { 'zh-CN': '预计可处理税额', 'zh-TW': '預計可處理稅額', en: 'Estimated processable tax', ja: '処理予定税額', ko: '처리 예정 세액', fr: 'Taxe estimée à traiter' },
      invTableTitle:      { 'zh-CN': '票据流转全景视图', 'zh-TW': '票據流轉全景視圖', en: 'Document Flow Overview', ja: '伝票フロー全体ビュー', ko: '문서 흐름 개요', fr: 'Vue d\'ensemble des pièces' },
      invTableSubtitle:   { 'zh-CN': '核对票据流与库存/交易记录一致性', 'zh-TW': '核對票據流與庫存/交易記錄一致性', en: 'Reconcile document flow with inventory / transaction records', ja: '伝票フローと在庫・取引記録の整合性を確認', ko: '문서 흐름과 재고/거래 기록의 일관성 확인', fr: 'Rapprocher les pièces avec les stocks / transactions' },
      invHeaderDate:      { 'zh-CN': '业务日期', 'zh-TW': '業務日期', en: 'Date', ja: '取引日', ko: '거래일', fr: 'Date' },
      invHeaderWeight:    { 'zh-CN': '数量', 'zh-TW': '數量', en: 'Quantity', ja: '数量', ko: '수량', fr: 'Quantité' },
      invHeaderAmount:    { 'zh-CN': '金额', 'zh-TW': '金額', en: 'Amount', ja: '金額', ko: '금액', fr: 'Montant' },
      invHeaderInvoiceNo: { 'zh-CN': '票据号码', 'zh-TW': '票據號碼', en: 'Document #', ja: '伝票番号', ko: '문서 번호', fr: 'N° de pièce' },
      invEmpty:           { 'zh-CN': '未找到匹配的票据记录', 'zh-TW': '未找到匹配的票據記錄', en: 'No matching documents found', ja: '一致する伝票が見つかりません', ko: '일치하는 문서가 없습니다', fr: 'Aucune pièce correspondante' },
      invNoInput:         { 'zh-CN': '暂无采购/费用记录', 'zh-TW': '暫無採購/費用記錄', en: 'No purchase/expense records', ja: '仕入・経費の記録なし', ko: '매입/비용 기록 없음', fr: 'Aucun achat/dépense' },
      invNoOutput:        { 'zh-CN': '暂无销售/收入记录', 'zh-TW': '暫無銷售/收入記錄', en: 'No sales/revenue records', ja: '売上・収入の記録なし', ko: '매출/수입 기록 없음', fr: 'Aucune vente/revenu' },
      invDateRange:       { 'zh-CN': '业务日期范围', 'zh-TW': '業務日期範圍', en: 'Date Range', ja: '取引日範囲', ko: '거래일 범위', fr: 'Plage de dates' },
      invStatusFilter:    { 'zh-CN': '票据状态', 'zh-TW': '票據狀態', en: 'Document Status', ja: '伝票ステータス', ko: '문서 상태', fr: 'Statut de la pièce' },
      invWeightRange:     { 'zh-CN': '数量范围', 'zh-TW': '數量範圍', en: 'Quantity Range', ja: '数量範囲', ko: '수량 범위', fr: 'Plage de quantité' },
      // US document-status filter options — generic receipt/document statuses,
      // NOT CN-VAT 认证/抵扣/进项/销项 wording.
      invStatusAll:       { 'zh-CN': '全部状态', 'zh-TW': '全部狀態', en: 'All Statuses', ja: 'すべてのステータス', ko: '전체 상태', fr: 'Tous les statuts' },
      invStatusVerified:  { 'zh-CN': '已核验', 'zh-TW': '已核驗', en: 'Verified', ja: '確認済み', ko: '확인됨', fr: 'Vérifié' },
      invStatusCertified: { 'zh-CN': '已记录', 'zh-TW': '已記錄', en: 'Recorded', ja: '記録済み', ko: '기록됨', fr: 'Enregistré' },
      invStatusDeducted:  { 'zh-CN': '已处理', 'zh-TW': '已處理', en: 'Processed', ja: '処理済み', ko: '처리됨', fr: 'Traité' },
      invStatusPendingCert:{ 'zh-CN': '待处理', 'zh-TW': '待處理', en: 'Pending', ja: '保留中', ko: '대기 중', fr: 'En attente' },
      invStatusPendingIssue:{ 'zh-CN': '待票据', 'zh-TW': '待票據', en: 'Awaiting Document', ja: '伝票待ち', ko: '문서 대기', fr: 'En attente de pièce' },
      invStatusIssued:    { 'zh-CN': '已开票', 'zh-TW': '已開票', en: 'Issued', ja: '発行済み', ko: '발행됨', fr: 'Émis' },
      // Interpolated count templates ({count} substituted at render). US receipt/
      // document context — never 进项/销项/认证/抵扣/发票/开票 wording.
      invAdvFilterActive: { 'zh-CN': '已启用筛选，找到 {count} 条票据记录', 'zh-TW': '已啟用篩選，找到 {count} 筆票據記錄', en: 'Filter active — {count} document(s) found', ja: 'フィルター適用中 — {count} 件の伝票', ko: '필터 적용됨 — 문서 {count}건', fr: 'Filtre actif — {count} pièce(s)' },
      invInputRecordCount:{ 'zh-CN': '{count} 条采购/费用记录', 'zh-TW': '{count} 筆採購/費用記錄', en: '{count} purchase/expense record(s)', ja: '仕入・経費 {count} 件', ko: '매입/비용 {count}건', fr: '{count} achat(s)/dépense(s)' },
      invOutputRecordCount:{ 'zh-CN': '{count} 条销售/收入记录', 'zh-TW': '{count} 筆銷售/收入記錄', en: '{count} sales/revenue record(s)', ja: '売上・収入 {count} 件', ko: '매출/수입 {count}건', fr: '{count} vente(s)/revenu(s)' },
      // AI assistant document-extraction result — generic 票据 wording (US is not spread from NON_CN_GENERIC).
      chatExtractResult:  {
        'zh-CN': '票据识别成功！\n\n日期: {date}\n客户/供应商: {partner}\n数量: {quantity}\n金额: {amount}\n运费: {shipping}\n票据号码: {invoiceNo}\n\n以上信息已从票据中提取。如需记账，请前往「采购与费用」或「销售与收入」页面录入。',
        'zh-TW': '票據辨識成功！\n\n日期: {date}\n客戶/供應商: {partner}\n數量: {quantity}\n金額: {amount}\n運費: {shipping}\n票據號碼: {invoiceNo}\n\n以上資訊已從票據中擷取。如需記帳，請前往「採購與費用」或「銷售與收入」頁面錄入。',
        en: 'Document extracted successfully!\n\nDate: {date}\nCustomer/Supplier: {partner}\nQuantity: {quantity}\nAmount: {amount}\nShipping: {shipping}\nDocument #: {invoiceNo}\n\nGo to Purchases & Expenses or Sales & Revenue to record this transaction.',
        ja: '伝票の認識に成功しました！\n\n日付: {date}\n顧客/仕入先: {partner}\n数量: {quantity}\n金額: {amount}\n送料: {shipping}\n伝票番号: {invoiceNo}\n\n仕入・経費または売上・収入のページから記帳できます。',
        ko: '문서 인식 성공!\n\n날짜: {date}\n고객/공급업체: {partner}\n수량: {quantity}\n금액: {amount}\n배송비: {shipping}\n문서 번호: {invoiceNo}\n\n매입 및 비용 또는 매출 및 수입 페이지로 이동하여 기록하세요.',
        fr: 'Pièce extraite avec succès !\n\nDate : {date}\nClient/Fournisseur : {partner}\nQuantité : {quantity}\nMontant : {amount}\nFrais de port : {shipping}\nN° de pièce : {invoiceNo}\n\nAllez sur Achats & dépenses ou Ventes & revenus pour enregistrer.',
      },
      // Accounts (应收应付) page — US frames receivables/payables by customer/
      // supplier rather than the traditional 应收账款/应付账款 ledger terms.
      acctReceivableTab:  { 'zh-CN': '客户应收', 'zh-TW': '客戶應收', en: 'Customer Receivables', ja: '顧客売掛金', ko: '고객 미수금', fr: 'Créances clients' },
      acctPayableTab:     { 'zh-CN': '供应商应付', 'zh-TW': '供應商應付', en: 'Supplier Payables', ja: '仕入先買掛金', ko: '공급업체 미지급금', fr: 'Dettes fournisseurs' },
      acctTotalReceivable:{ 'zh-CN': '客户应收总额', 'zh-TW': '客戶應收總額', en: 'Total Customer Receivables', ja: '売掛金合計', ko: '고객 미수금 합계', fr: 'Total créances clients' },
      acctTotalPayable:   { 'zh-CN': '供应商应付总额', 'zh-TW': '供應商應付總額', en: 'Total Supplier Payables', ja: '買掛金合計', ko: '공급업체 미지급금 합계', fr: 'Total dettes fournisseurs' },
      // Finance report (财务报表) — US balance-sheet / cash-flow wording. zh-CN/
      // zh-TW use US framing (customer/supplier, owner's-equity, 留存收益); other
      // languages match the existing finance.* values so only Chinese changes.
      balRecvLabel:       { 'zh-CN': '客户应收', 'zh-TW': '客戶應收', en: 'Accounts Receivable', ja: '売掛金', ko: '매출채권', fr: 'Créances clients' },
      balPayLabel:        { 'zh-CN': '供应商应付', 'zh-TW': '供應商應付', en: 'Accounts Payable', ja: '買掛金', ko: '매입채무', fr: 'Dettes fournisseurs' },
      balTaxPayLabel:     { 'zh-CN': '估算应付税款', 'zh-TW': '估算應付稅款', en: 'Estimated Tax Payable', ja: '推定未払税金', ko: '추정 미지급세금', fr: 'Dettes fiscales estimées' },
      balPaidInCapital:   { 'zh-CN': '所有者投入', 'zh-TW': '所有者投入', en: 'Paid-in Capital', ja: '資本金', ko: '납입자본금', fr: 'Capital social' },
      balRetainedEarnings:{ 'zh-CN': '留存收益', 'zh-TW': '留存收益', en: 'Retained Earnings', ja: '利益剰余金', ko: '이익잉여금', fr: 'Résultat reporté' },
      balLiabEquityHeader:{ 'zh-CN': '负债和所有者权益', 'zh-TW': '負債和所有者權益', en: 'Liabilities & Equity', ja: '負債及び純資産', ko: '부채 및 자본', fr: 'Passif' },
      balEquityHeader:    { 'zh-CN': '所有者权益', 'zh-TW': '所有者權益', en: 'Equity', ja: '純資産', ko: '자본', fr: 'Capitaux propres' },
      balTotalLiabEquity: { 'zh-CN': '负债和所有者权益总计', 'zh-TW': '負債和所有者權益總計', en: 'Total Liabilities & Equity', ja: '負債及び純資産合計', ko: '부채 및 자본 총계', fr: 'Total passif' },
      balCashflowAdd:     { 'zh-CN': '添加收支记录', 'zh-TW': '新增收支記錄', en: 'Add Transaction', ja: '取引を追加', ko: '거래 추가', fr: 'Ajouter une opération' },
      // Transactions (收支记录) page — the report-line column reads as 账户
      // (the Schedule C line is the US expense account); US only.
      txnAccountHeader:   { 'zh-CN': '账户', 'zh-TW': '帳戶', en: 'Account', ja: '勘定科目', ko: '계정', fr: 'Compte' },
      // Settings page (系统设置) — US framing. zh-CN/zh-TW use US terminology;
      // other languages mirror sensible US-context values. CN/EU/JP/KR/TW keep
      // their existing settings.* i18n / profile data untouched.
      setCreditCodeLabel: { 'zh-CN': 'EIN / 税号', 'zh-TW': 'EIN / 稅號', en: 'EIN / Tax ID', ja: 'EIN／納税者番号', ko: 'EIN / 납세자번호', fr: 'EIN / N° fiscal' },
      setLegalPersonLabel:{ 'zh-CN': '负责人', 'zh-TW': '負責人', en: 'Responsible Party', ja: '代表者', ko: '대표자', fr: 'Responsable' },
      setCreditCodePh:    { 'zh-CN': '例如：12-3456789', 'zh-TW': '例如：12-3456789', en: 'e.g. 12-3456789', ja: '例：12-3456789', ko: '예: 12-3456789', fr: 'ex. : 12-3456789' },
      setAddressPh:       { 'zh-CN': '例如：123 Main St, Los Angeles, CA', 'zh-TW': '例如：123 Main St, Los Angeles, CA', en: 'e.g. 123 Main St, Los Angeles, CA', ja: '例：123 Main St, Los Angeles, CA', ko: '예: 123 Main St, Los Angeles, CA', fr: 'ex. : 123 Main St, Los Angeles, CA' },
      setVatRateLabel:    { 'zh-CN': '销售税税率（Sales Tax）', 'zh-TW': '銷售稅稅率（Sales Tax）', en: 'Sales Tax Rate', ja: '売上税率', ko: '판매세율', fr: 'Taux de taxe de vente' },
      setRateByState:     { 'zh-CN': '按州设置', 'zh-TW': '按州設置', en: 'By state', ja: '州別', ko: '주별', fr: 'Par État' },
      setRateCustom:      { 'zh-CN': '自定义税率', 'zh-TW': '自訂稅率', en: 'Custom rate', ja: 'カスタム税率', ko: '사용자 지정 세율', fr: 'Taux personnalisé' },
      setRateZero:        { 'zh-CN': '0%', 'zh-TW': '0%', en: '0%', ja: '0%', ko: '0%', fr: '0%' },
      setAutoAuthLabel:   { 'zh-CN': '票据自动处理', 'zh-TW': '票據自動處理', en: 'Auto-process documents', ja: '伝票の自動処理', ko: '문서 자동 처리', fr: 'Traitement auto des pièces' },
      setAutoAuthDesc:    { 'zh-CN': '上传后自动用于分类、归档和报表统计', 'zh-TW': '上傳後自動用於分類、歸檔和報表統計', en: 'Uploaded documents are auto-categorized, filed, and included in reports', ja: 'アップロード後、自動的に分類・保管・集計', ko: '업로드 후 자동 분류·보관·집계', fr: 'Pièces classées, archivées et comptabilisées automatiquement' },
      setAdminExpenseLabel:{ 'zh-CN': '年度经营费用', 'zh-TW': '年度經營費用', en: 'Annual Operating Expenses', ja: '年間運営費', ko: '연간 운영비', fr: "Charges annuelles d'exploitation" },
      setPerYear:         { 'zh-CN': '美元/年', 'zh-TW': '美元/年', en: 'USD/yr', ja: '米ドル/年', ko: '미국 달러/년', fr: 'USD/an' },
      setTaxHint:         { 'zh-CN': '销售税按州规则估算；经营费用用于净利润计算。', 'zh-TW': '銷售稅按州規則估算；經營費用用於淨利計算。', en: "Note: sales tax and expenses follow your state's rules; net profit = gross income − expenses.", ja: '注：売上税と費用は州の規則に従います。純利益 = 総収入 − 費用。', ko: '참고: 판매세와 비용은 주 규정을 따릅니다. 순이익 = 총수입 − 비용.', fr: "Note : la sales tax et les charges suivent les règles de votre État ; bénéfice net = revenu brut − charges." },
      setDeductibleHeader:{ 'zh-CN': '可扣除', 'zh-TW': '可扣除', en: 'Deductible', ja: '控除可', ko: '공제 가능', fr: 'Déductible' },
      setDeductiblePctLabel:{ 'zh-CN': '可扣除比例 (%)', 'zh-TW': '可扣除比例 (%)', en: 'Deductible %', ja: '控除割合 (%)', ko: '공제 비율 (%)', fr: 'Part déductible (%)' },
      setCatGrossReceipts:{ 'zh-CN': '总收入 / 销售额', 'zh-TW': '總收入 / 銷售額', en: 'Gross Receipts', ja: '総収入', ko: '총수입', fr: 'Recettes brutes' },
      setCatHomeOffice:   { 'zh-CN': '家庭办公室', 'zh-TW': '家庭辦公室', en: 'Home Office', ja: '在宅オフィス', ko: '재택사무실', fr: 'Bureau à domicile' },
      setCatUtilities:    { 'zh-CN': '水电及网络', 'zh-TW': '水電及網路', en: 'Utilities', ja: '水道光熱費', ko: '수도광열비', fr: 'Énergie' },
      setNavAi:           { 'zh-CN': 'AI 服务商（BYOK）', 'zh-TW': 'AI 服務商（BYOK）', en: 'AI Providers (BYOK)', ja: 'AIプロバイダー（BYOK）', ko: 'AI 공급자(BYOK)', fr: 'Fournisseurs IA (BYOK)' },
      setAddKey:          { 'zh-CN': '添加密钥', 'zh-TW': '新增密鑰', en: 'Add Key', ja: 'キーを追加', ko: '키 추가', fr: 'Ajouter la clé' },
      setEditKey:         { 'zh-CN': '修改密钥', 'zh-TW': '修改密鑰', en: 'Edit Key', ja: 'キーを編集', ko: '키 편집', fr: 'Modifier la clé' },
      setWebGrounding:    { 'zh-CN': '支持联网检索', 'zh-TW': '支援聯網檢索', en: 'Supports web search', ja: 'ウェブ検索対応', ko: '웹 검색 지원', fr: 'Recherche web prise en charge' },
      // Company-info example placeholders — US sample values.
      setCompanyNamePh:   { 'zh-CN': '例如：ABC Trading LLC', 'zh-TW': '例如：ABC Trading LLC', en: 'e.g. ABC Trading LLC', ja: '例：ABC Trading LLC', ko: '예: ABC Trading LLC', fr: 'ex. : ABC Trading LLC' },
      setLegalPersonPh:   { 'zh-CN': '例如：张三 / John Smith', 'zh-TW': '例如：王小明 / John Smith', en: 'e.g. John Smith', ja: '例：John Smith', ko: '예: John Smith', fr: 'ex. : John Smith' },
      setIndustryPh:      { 'zh-CN': '例如：咨询 / 零售 / 服务', 'zh-TW': '例如：顧問 / 零售 / 服務', en: 'e.g. Consulting / Retail / Services', ja: '例：Consulting / Retail / Services', ko: '예: Consulting / Retail / Services', fr: 'ex. : Consulting / Retail / Services' },
      // Data-migration page (设置→数据迁移) — user-facing wording, no internal
      // table/field/JSON names (sales/purchases/transaction/source_meta/etc.).
      dmSubtitle:         { 'zh-CN': '将旧版本销售和采购数据迁移为新的收入与费用记录。旧表仅保留备份，30 天内可回滚。', 'zh-TW': '將舊版本銷售和採購資料遷移為新的收入與費用記錄。舊表僅保留備份，30 天內可回復。', en: 'Migrate legacy sales & purchase data into the new income & expense records. Old data is kept as a backup and can be rolled back within 30 days.', ja: '旧版の売上・仕入データを新しい収入・費用の記録へ移行します。旧データはバックアップとして保持され、30日以内に元に戻せます。', ko: '이전 버전의 판매·구매 데이터를 새 수입·비용 기록으로 이전합니다. 기존 데이터는 백업으로 보관되며 30일 이내 되돌릴 수 있습니다.', fr: 'Migrez les anciennes données de ventes et achats vers les nouveaux enregistrements de revenus et dépenses. Les anciennes données sont conservées en sauvegarde et réversibles sous 30 jours.' },
      dmCardSales:        { 'zh-CN': '销售记录（旧版）→ 收入记录', 'zh-TW': '銷售記錄（舊版）→ 收入記錄', en: 'Sales records (legacy) → Income', ja: '売上記録（旧版）→ 収入', ko: '판매 기록(이전) → 수입', fr: 'Ventes (ancien) → Revenus' },
      dmCardPurchases:    { 'zh-CN': '采购记录（旧版）→ 费用记录', 'zh-TW': '採購記錄（舊版）→ 費用記錄', en: 'Purchase records (legacy) → Expenses', ja: '仕入記録（旧版）→ 費用', ko: '구매 기록(이전) → 비용', fr: 'Achats (ancien) → Dépenses' },
      dmNoLegacy:         { 'zh-CN': '没有需要迁移的旧版数据。', 'zh-TW': '沒有需要遷移的舊版資料。', en: 'No legacy data to migrate.', ja: '移行が必要な旧データはありません。', ko: '이전할 이전 데이터가 없습니다.', fr: 'Aucune ancienne donnée à migrer.' },
      dmResultIncome:     { 'zh-CN': '收入记录已迁移', 'zh-TW': '收入記錄已遷移', en: 'Income records migrated', ja: '収入の記録を移行しました', ko: '수입 기록 이전 완료', fr: 'Revenus migrés' },
      dmResultExpense:    { 'zh-CN': '费用记录已迁移', 'zh-TW': '費用記錄已遷移', en: 'Expense records migrated', ja: '費用の記録を移行しました', ko: '비용 기록 이전 완료', fr: 'Dépenses migrées' },
      dmRollbackConfirm:  { 'zh-CN': '确认回滚？这将删除 {count} 条已迁移的记录，旧数据保持不变。', 'zh-TW': '確認回復？這將刪除 {count} 筆已遷移的記錄，舊資料保持不變。', en: 'Roll back? This removes {count} migrated records; your old data stays unchanged.', ja: '元に戻しますか？移行済みの記録 {count} 件を削除します。旧データは変更されません。', ko: '되돌리시겠습니까? 이전된 기록 {count}건이 삭제되며 기존 데이터는 그대로 유지됩니다.', fr: 'Annuler ? Cela supprime {count} enregistrements migrés ; vos anciennes données restent intactes.' },
      dmRollback:         { 'zh-CN': '回滚迁移（删除已迁移的 {count} 条记录）', 'zh-TW': '回復遷移（刪除已遷移的 {count} 筆記錄）', en: 'Roll back migration (remove {count} migrated records)', ja: '移行を元に戻す（移行済み {count} 件を削除）', ko: '이전 되돌리기(이전된 {count}건 삭제)', fr: 'Annuler la migration (supprimer {count} enregistrements)' },
      dmNote1:            { 'zh-CN': '销售记录将迁移为收入记录，采购记录将迁移为费用记录。', 'zh-TW': '銷售記錄將遷移為收入記錄，採購記錄將遷移為費用記錄。', en: 'Sales records become income records; purchase records become expense records.', ja: '売上記録は収入に、仕入記録は費用に移行されます。', ko: '판매 기록은 수입으로, 구매 기록은 비용으로 이전됩니다.', fr: 'Les ventes deviennent des revenus ; les achats deviennent des dépenses.' },
      dmNote2:            { 'zh-CN': '旧表数据会保留，可随时回滚。', 'zh-TW': '舊表資料會保留，可隨時回復。', en: 'Old data is preserved and can be rolled back at any time.', ja: '旧データは保持され、いつでも元に戻せます。', ko: '기존 데이터는 보존되며 언제든 되돌릴 수 있습니다.', fr: 'Les anciennes données sont conservées et réversibles à tout moment.' },
      dmNote3:            { 'zh-CN': '迁移记录会保存原始记录快照，不会丢失。', 'zh-TW': '遷移記錄會保存原始記錄快照，不會遺失。', en: 'Each migration keeps a snapshot of the original record, so nothing is lost.', ja: '移行ごとに元の記録のスナップショットを保存するため、データは失われません。', ko: '이전 시 원본 기록 스냅샷을 저장하므로 데이터가 손실되지 않습니다.', fr: 'Chaque migration conserve un instantané de l’enregistrement d’origine ; rien n’est perdu.' },
      dmNote4:            { 'zh-CN': '原始的数量、单价、运费等明细会随记录一并保留。', 'zh-TW': '原始的數量、單價、運費等明細會隨記錄一併保留。', en: 'Original details such as quantity, unit price and shipping are preserved with each record.', ja: '数量・単価・送料などの元の明細も記録と共に保持されます。', ko: '수량·단가·배송비 등 원본 세부 정보도 기록과 함께 보존됩니다.', fr: 'Les détails d’origine (quantité, prix unitaire, frais de port) sont conservés avec chaque enregistrement.' },
      // Alerts & notifications page — US wording (threshold-based stock; 税款 not 税收).
      notifStockZero:     { 'zh-CN': '库存低于阈值提醒', 'zh-TW': '庫存低於閾值提醒', en: 'Low-stock alert (below threshold)', ja: '在庫が閾値を下回ったら通知', ko: '재고 임계값 미만 알림', fr: 'Alerte stock sous le seuil' },
      notifTaxDeviation:  { 'zh-CN': '税款偏差超过 15% 预警', 'zh-TW': '稅款偏差超過 15% 預警', en: 'Tax deviation over 15% alert', ja: '税額の乖離が15%を超えたら警告', ko: '세액 편차 15% 초과 경고', fr: 'Alerte écart de taxe supérieur à 15 %' },
      notifPriceVolatility:{ 'zh-CN': '异常价格波动提醒', 'zh-TW': '異常價格波動提醒', en: 'Unusual price movement alert', ja: '異常な価格変動を通知', ko: '비정상 가격 변동 알림', fr: 'Alerte de variation de prix inhabituelle' },
      notifMonthlyReport: { 'zh-CN': '月度财务报告推送', 'zh-TW': '月度財務報告推送', en: 'Monthly financial report', ja: '月次財務レポートの配信', ko: '월간 재무 보고서 발송', fr: 'Rapport financier mensuel' },
      newSaleButton:      { 'zh-CN': '新增收入', 'zh-TW': '新增收入', en: 'New Sale', ja: '売上を追加', ko: '매출 추가', fr: 'Nouvelle vente' },
      invoiceInputLabel: { 'zh-CN': '费用凭证数', 'zh-TW': '費用憑證數', en: 'Expense Receipts', ja: '経費レシート', ko: '비용 영수증', fr: 'Reçus de dépenses' },
      invoiceOutputLabel: { 'zh-CN': '收入凭证数', 'zh-TW': '收入憑證數', en: 'Income Receipts', ja: '収入レシート', ko: '수입 영수증', fr: 'Reçus de revenus' },
      invoicePendingTax: { 'zh-CN': '待处理税务凭证', 'zh-TW': '待處理稅務憑證', en: 'Pending Tax Documents', ja: '未処理税務書類', ko: '미처리 세무 서류', fr: 'Documents fiscaux à traiter' },
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
    aiContext: 'Use US Schedule C sole-proprietor accounting concepts (no VAT; Sales Tax only where applicable; Self-Employment Tax = Social Security + Medicare; quarterly estimated tax). Use the tax rates the user configured rather than assuming fixed rates, and treat figures as management estimates, not statutory or filing amounts.',
  },

  JP: {
    id: 'JP',
    defaultCurrency: 'JPY',
    currencySymbol: '¥',
    taxRegime: 'consumption_tax',
    taxConcepts: {
      ...NON_CN_GENERIC,
      // System Settings (系统设置) — JP regime: 法人番号, consumption tax, JPY.
      setCreditCodeLabel: { 'zh-CN': '法人编号 / 税号', 'zh-TW': '法人編號 / 稅號', en: 'Corporate Number / Tax ID', ja: '法人番号／税番号', ko: '법인번호 / 세금번호', fr: "Numéro d'entreprise / N° fiscal" },
      setCreditCodePh:    { 'zh-CN': '例如：1234567890123', 'zh-TW': '例如：1234567890123', en: 'e.g. 1234567890123', ja: '例：1234567890123', ko: '예: 1234567890123', fr: 'ex. : 1234567890123' },
      setAddressPh:       { 'zh-CN': '例如：东京都千代田区…', 'zh-TW': '例如：東京都千代田區…', en: 'e.g. Chiyoda-ku, Tokyo', ja: '例：東京都千代田区…', ko: '예: 도쿄도 지요다구…', fr: 'ex. : Chiyoda-ku, Tokyo' },
      setVatRateLabel:    { 'zh-CN': '消费税率', 'zh-TW': '消費稅率', en: 'Consumption Tax Rate', ja: '消費税率', ko: '소비세율', fr: 'Taux de taxe à la consommation' },
      setPerYear:         { 'zh-CN': '日元/年', 'zh-TW': '日圓/年', en: 'JPY/yr', ja: '円/年', ko: '엔/년', fr: 'JPY/an' },
      setTaxHint:         { 'zh-CN': '提示：消费税标准 10% / 轻减 8%；所得税/法人税按利润计算。', 'zh-TW': '提示：消費稅標準 10% / 輕減 8%；所得稅/法人稅按利潤計算。', en: 'Note: consumption tax 10% standard / 8% reduced; income/corporate tax on profit.', ja: '注：消費税は標準10%／軽減8%。所得税・法人税は利益に対して課税。', ko: '참고: 소비세 표준 10% / 경감 8%; 소득세/법인세는 이익 기준.', fr: 'Note : taxe à la consommation 10 % / 8 % réduit ; impôt sur le revenu/sociétés sur le bénéfice.' },
      taxTitle:      { 'zh-CN': '消费税统计', 'zh-TW': '消費稅統計', en: 'Consumption Tax Summary', ja: '消費税集計', ko: '소비세 통계', fr: 'Résumé taxe consommation' },
      // Finance-report (财务报表) consumption-tax section title — reconciliation/
      // statement framing (汇总) vs the 经营看板 card's 统计. JP-only: FinancePage
      // gates on locale === 'JP'; the 经营看板 VATStatistics keeps taxTitle (消费税统计),
      // and CN/US/EU/KR/TW finance pages keep their own taxTitle untouched. zh-CN/zh-TW
      // differ from taxTitle; en/ja/ko/fr mirror taxTitle (already summary-framed).
      taxReportTitle:{ 'zh-CN': '消费税汇总', 'zh-TW': '消費稅彙總', en: 'Consumption Tax Summary', ja: '消費税集計', ko: '소비세 통계', fr: 'Résumé taxe consommation' },
      inputTax:      { 'zh-CN': '采购消费税', 'zh-TW': '採購消費稅', en: 'Consumption Tax Paid (Input)', ja: '仕入税額', ko: '매입 소비세', fr: 'Taxe payée (achats)' },
      outputTax:     { 'zh-CN': '销售消费税', 'zh-TW': '銷售消費稅', en: 'Consumption Tax Collected (Output)', ja: '売上税額', ko: '매출 소비세', fr: 'Taxe collectée (ventes)' },
      estimatedTax:  { 'zh-CN': '消费税估算额', 'zh-TW': '消費稅估算額', en: 'Estimated Consumption Tax', ja: '消費税の試算額', ko: '소비세 추정액', fr: 'Taxe à la consommation estimée' },
      certifiedInput:{ 'zh-CN': '采购消费税额合计', 'zh-TW': '採購消費稅額合計', en: 'Total Input Consumption Tax', ja: '仕入消費税額合計', ko: '매입 소비세액 합계', fr: 'Taxe sur achats (total)' },
      invoicedOutput:{ 'zh-CN': '销售消费税额合计', 'zh-TW': '銷售消費稅額合計', en: 'Total Output Consumption Tax', ja: '売上消費税額合計', ko: '매출 소비세액 합계', fr: 'Taxe sur ventes (total)' },
      plRevenue:     { 'zh-CN': '营业收入', 'zh-TW': '營業收入', en: 'Sales Revenue', ja: '売上高', ko: '매출', fr: 'Chiffre d\'affaires' },
      plCost:        { 'zh-CN': '营业成本', 'zh-TW': '營業成本', en: 'Cost of Sales', ja: '売上原価', ko: '매출원가', fr: 'Coût des ventes' },
      plGrossProfit: { 'zh-CN': '毛利', 'zh-TW': '毛利', en: 'Gross Profit', ja: '売上総利益', ko: '매출총이익', fr: 'Marge brute' },
      plOperatingExpenses: { 'zh-CN': '期间费用', 'zh-TW': '期間費用', en: 'Operating Expenses', ja: '営業費用', ko: '영업비용', fr: "Charges d'exploitation" },
      plOperatingProfit: { 'zh-CN': '经营利润', 'zh-TW': '經營利潤', en: 'Operating Profit', ja: '営業利益', ko: '영업이익', fr: "Résultat d'exploitation" },
      plAdmin:       { 'zh-CN': '销售及管理费用', 'zh-TW': '銷售及管理費用', en: 'SG&A Expense', ja: '販売費及び一般管理費', ko: '판관비', fr: 'Frais généraux' },
      // No entityType in the data model → use the generic income/corporate framing
      // so sole proprietors aren't shown 法人税 (which only applies to 法人/corporations).
      plIncomeTax:   { 'zh-CN': '所得税/法人税', 'zh-TW': '所得稅/法人稅', en: 'Income / Corporate Tax', ja: '所得税・法人税', ko: '소득세/법인세', fr: 'Impôt sur le revenu/sociétés' },
      plNetProfit:   { 'zh-CN': '当期净利润', 'zh-TW': '當期淨利潤', en: 'Net Income', ja: '当期純利益', ko: '당기순이익', fr: 'Résultat net' },
      plPeriodPrefix:{ 'zh-CN': '币种：日元 | 会计期间：', 'zh-TW': '幣種：日圓 | 會計期間：', en: 'Currency: JPY | Period: ', ja: '通貨：円 | 期間：', ko: '통화: JPY | 기간: ', fr: 'Devise : JPY | Période : ' },
      plTitle:       { 'zh-CN': '经营损益概览', 'zh-TW': '經營損益概覽', en: 'Management P&L', ja: '経営損益サマリー', ko: '경영 손익 개요', fr: 'Aperçu du résultat (gestion)' },
      tabPlLabel:    { 'zh-CN': '经营损益', 'zh-TW': '經營損益', en: 'Operating P&L', ja: '経営損益', ko: '경영 손익', fr: 'Résultat (gestion)' },
      formTaxRate:   { 'zh-CN': '消费税率', 'zh-TW': '消費稅率', en: 'Consumption Tax Rate', ja: '消費税率', ko: '소비세율', fr: 'Taux taxe consommation' },
      invoiceInputLabel: { 'zh-CN': '采购发票数', 'zh-TW': '採購發票數', en: 'Purchase Invoices', ja: '仕入請求書数', ko: '매입계산서', fr: 'Factures achats' },
      invoiceOutputLabel: { 'zh-CN': '销售发票数', 'zh-TW': '銷售發票數', en: 'Sales Invoices', ja: '売上請求書数', ko: '매출계산서', fr: 'Factures ventes' },
      invoicePendingTax: { 'zh-CN': '待处理消费税', 'zh-TW': '待處理消費稅', en: 'Pending Consumption Tax', ja: '未処理消費税', ko: '미처리 소비세', fr: 'Taxe à la consommation à traiter' },
      invoiceTypeOutput: { 'zh-CN': '销售', 'zh-TW': '銷售', en: 'Sales', ja: '売上', ko: '매출', fr: 'Vente' },
      invoiceTypeInput: { 'zh-CN': '采购', 'zh-TW': '採購', en: 'Purchase', ja: '仕入', ko: '매입', fr: 'Achat' },
      inventoryUnit: { 'zh-CN': '单位', 'zh-TW': '單位', en: 'units', ja: '単位', ko: '단위', fr: 'unités' },
      taxSummaryTitle:{ 'zh-CN': '消费税含税汇总 (对账用)', 'zh-TW': '消費稅含稅匯總 (對帳用)', en: 'Tax-Inclusive Summary (Reconciliation)', ja: '税込金額集計（照合用）', ko: '소비세 포함 요약 (대조용)', fr: 'Résumé TTC (rapprochement)' },
      purchaseTotal: { 'zh-CN': '采购含税总额', 'zh-TW': '採購含稅總額', en: 'Purchase Total (Incl. Tax)', ja: '仕入税込合計', ko: '매입 세금포함 총액', fr: 'Total achats TTC' },
      salesTotal:    { 'zh-CN': '销售含税总额', 'zh-TW': '銷售含稅總額', en: 'Sales Total (Incl. Tax)', ja: '売上税込合計', ko: '매출 세금포함 총액', fr: 'Total ventes TTC' },
      taxDifference: { 'zh-CN': '消费税差额', 'zh-TW': '消費稅差額', en: 'Consumption Tax Difference', ja: '消費税差額', ko: '소비세 차액', fr: 'Différence taxe consommation' },
      // ── Invoice-query (票据查询) JP-specific overrides ──
      // Refine the shared NON_CN_GENERIC document wording to JP consumption-tax /
      // pre-tax framing (mainly zh-CN/zh-TW; en/ja/ko/fr keep the generic base where
      // already correct). No CN-VAT 进项/销项/认证/电子发票 terms. EU/KR/TW are NOT
      // affected — they keep the NON_CN_GENERIC values (these overrides live in JP only).
      invTableSubtitle:   { 'zh-CN': '核对票据、库存与交易记录的一致性', 'zh-TW': '核對票據、庫存與交易記錄的一致性', en: 'Reconcile document flow with inventory / transaction records', ja: '伝票フローと在庫・取引記録の整合性を確認', ko: '문서 흐름과 재고/거래 기록의 일관성 확인', fr: 'Rapprocher les pièces avec les stocks / transactions' },
      invPendingTax:      { 'zh-CN': '待处理消费税额', 'zh-TW': '待處理消費稅額', en: 'Pending Consumption Tax', ja: '未処理消費税額', ko: '미처리 소비세액', fr: 'Taxe à la consommation en attente' },
      invHeaderAmount:    { 'zh-CN': '税前金额', 'zh-TW': '稅前金額', en: 'Amount (pre-tax)', ja: '金額（税抜）', ko: '금액(세전)', fr: 'Montant (HT)' },
      // Amount-range filter — JP labels it pre-tax to match invHeaderAmount (税前金额).
      // JP-only: the component gates this on accLocale === 'JP'; CN/US/EU/KR/TW keep
      // the shared invoices.amountRange i18n value untouched.
      invAmountRange:     { 'zh-CN': '税前金额范围', 'zh-TW': '稅前金額範圍', en: 'Amount Range (pre-tax)', ja: '金額範囲（税抜）', ko: '금액 범위(세전)', fr: 'Plage de montant (HT)' },
      invStatusPendingIssue:{ 'zh-CN': '待补票据', 'zh-TW': '待補票據', en: 'Awaiting Document', ja: '伝票待ち', ko: '문서 대기', fr: 'En attente de pièce' },
      invEmpty:           { 'zh-CN': '未找到匹配的票据记录', 'zh-TW': '未找到相符的票據記錄', en: 'No matching documents found', ja: '一致する伝票が見つかりません', ko: '일치하는 문서가 없습니다', fr: 'Aucune pièce correspondante' },
    },
    dashboardSections: ['profit_loss', 'profit_margins', 'consumption_tax_summary', 'tax_inclusive_summary'],
    reportTypes: ['income-statement', 'consumption-tax'],
    aiContext: 'Use Japanese accounting with Consumption Tax (消費税) concepts for a one-person company (ひとり会社). Use the tax rates the user configured rather than assuming fixed rates, and treat figures as management estimates.',
  },

  EU: {
    id: 'EU',
    defaultCurrency: 'EUR',
    currencySymbol: '€',
    taxRegime: 'vat',
    taxConcepts: {
      ...NON_CN_GENERIC,
      // System Settings (系统设置) — EU regime: VAT ID, VAT, EUR.
      setCreditCodeLabel: { 'zh-CN': 'VAT ID / 税号', 'zh-TW': 'VAT ID / 稅號', en: 'VAT ID / Tax No.', ja: 'VAT ID／税番号', ko: 'VAT ID / 세금번호', fr: 'N° de TVA / N° fiscal' },
      setCreditCodePh:    { 'zh-CN': '例如：DE123456789', 'zh-TW': '例如：DE123456789', en: 'e.g. DE123456789', ja: '例：DE123456789', ko: '예: DE123456789', fr: 'ex. : DE123456789' },
      setAddressPh:       { 'zh-CN': '例如：柏林米特区…', 'zh-TW': '例如：柏林米特區…', en: 'e.g. Mitte, Berlin', ja: '例：ベルリン・ミッテ…', ko: '예: 베를린 미테…', fr: 'ex. : Mitte, Berlin' },
      setVatRateLabel:    { 'zh-CN': 'VAT 税率', 'zh-TW': 'VAT 稅率', en: 'VAT Rate', ja: 'VAT率', ko: 'VAT 세율', fr: 'Taux de TVA' },
      setPerYear:         { 'zh-CN': '欧元/年', 'zh-TW': '歐元/年', en: 'EUR/yr', ja: 'ユーロ/年', ko: '유로/년', fr: 'EUR/an' },
      setTaxHint:         { 'zh-CN': '提示：VAT 标准约 20%（各国不同）；所得税按利润计算。', 'zh-TW': '提示：VAT 標準約 20%（各國不同）；所得稅按利潤計算。', en: 'Note: VAT ~20% standard (varies by country); income tax on profit.', ja: '注：VAT標準約20%（国により異なる）；所得税は利益に対して課税。', ko: '참고: VAT 표준 약 20%(국가별 상이); 소득세는 이익 기준.', fr: 'Note : TVA ~20 % (selon le pays) ; impôt sur le bénéfice.' },
      taxTitle:      { 'zh-CN': 'VAT 统计', 'zh-TW': 'VAT 統計', en: 'VAT Summary', ja: 'VAT集計', ko: 'VAT 통계', fr: 'Résumé TVA' },
      // EU frames VAT cards as 采购/销售 (purchase/sales) rather than the CN/JP-VAT
      // ledger 进项/销项 (input/output). zh-CN/zh-TW only; en/ja/ko/fr keep the
      // standard Input/Output VAT accounting terms. Currency stays EUR (€).
      inputTax:      { 'zh-CN': '采购 VAT', 'zh-TW': '採購 VAT', en: 'Input VAT', ja: '仕入VAT', ko: '매입 VAT', fr: 'TVA déductible' },
      outputTax:     { 'zh-CN': '销售 VAT', 'zh-TW': '銷售 VAT', en: 'Output VAT', ja: '売上VAT', ko: '매출 VAT', fr: 'TVA collectée' },
      estimatedTax:  { 'zh-CN': 'VAT 估算额', 'zh-TW': 'VAT 估算額', en: 'Estimated VAT', ja: 'VATの試算額', ko: 'VAT 추정액', fr: 'TVA estimée' },
      certifiedInput:{ 'zh-CN': '采购 VAT 合计', 'zh-TW': '採購 VAT 合計', en: 'Total Input VAT', ja: '仕入VAT合計', ko: '매입 VAT 합계', fr: 'TVA déductible (total)' },
      invoicedOutput:{ 'zh-CN': '销售 VAT 合计', 'zh-TW': '銷售 VAT 合計', en: 'Total Output VAT', ja: '売上VAT合計', ko: '매출 VAT 합계', fr: 'TVA collectée (total)' },
      plRevenue:     { 'zh-CN': '营业收入', 'zh-TW': '營業收入', en: 'Revenue', ja: '売上', ko: '매출', fr: 'Chiffre d\'affaires' },
      plCost:        { 'zh-CN': '营业成本', 'zh-TW': '營業成本', en: 'Cost of Sales', ja: '売上原価', ko: '매출원가', fr: 'Coût des ventes' },
      plGrossProfit: { 'zh-CN': '毛利', 'zh-TW': '毛利', en: 'Gross Profit', ja: '粗利益', ko: '매출총이익', fr: 'Marge brute' },
      plOperatingExpenses: { 'zh-CN': '期间费用', 'zh-TW': '期間費用', en: 'Operating Expenses', ja: '営業費用', ko: '영업비용', fr: "Charges d'exploitation" },
      plOperatingProfit: { 'zh-CN': '经营利润', 'zh-TW': '經營利潤', en: 'Operating Profit', ja: '営業利益', ko: '영업이익', fr: "Résultat d'exploitation" },
      plAdmin:       { 'zh-CN': '管理费用', 'zh-TW': '管理費用', en: 'Admin Expense', ja: '一般管理費', ko: '관리비', fr: 'Frais administratifs' },
      plIncomeTax:   { 'zh-CN': '所得税', 'zh-TW': '所得稅', en: 'Income Tax', ja: '法人税', ko: '법인세', fr: 'Impôt sur le revenu' },
      plNetProfit:   { 'zh-CN': '净利润', 'zh-TW': '淨利潤', en: 'Net Profit', ja: '純利益', ko: '순이익', fr: 'Bénéfice net' },
      plPeriodPrefix:{ 'zh-CN': '币种：欧元 | 会计期间：', 'zh-TW': '幣種：歐元 | 會計期間：', en: 'Currency: EUR | Period: ', ja: '通貨：EUR | 期間：', ko: '통화: EUR | 기간: ', fr: 'Devise : EUR | Période : ' },
      plTitle:       { 'zh-CN': '经营损益概览', 'zh-TW': '經營損益概覽', en: 'Management P&L', ja: '経営損益サマリー', ko: '경영 손익 개요', fr: 'Aperçu du résultat (gestion)' },
      tabPlLabel:    { 'zh-CN': '经营损益', 'zh-TW': '經營損益', en: 'Operating P&L', ja: '経営損益', ko: '경영 손익', fr: 'Résultat (gestion)' },
      formTaxRate:   { 'zh-CN': 'VAT 税率', 'zh-TW': 'VAT 稅率', en: 'VAT Rate', ja: 'VAT率', ko: 'VAT 세율', fr: 'Taux TVA' },
      // ── Invoice-query (票据查询) EU-specific overrides ──
      // Use the 采购与费用 / 销售与收入 wording (matching the left-nav + tabs) instead
      // of the shared NON_CN_GENERIC 采购/费用 · 销售/收入 slash form, and 待补票据
      // instead of 待票据. zh-CN/zh-TW only; en/ja/ko/fr keep the generic base. JP/KR/TW
      // are NOT affected (these overrides live in the EU block only).
      invTotalInput:       { 'zh-CN': '累计采购与费用票据', 'zh-TW': '累計採購與費用票據', en: 'Total Purchase/Expense Documents', ja: '仕入・経費伝票数', ko: '매입/비용 문서 합계', fr: 'Total pièces achats/dépenses' },
      invTotalOutput:      { 'zh-CN': '累计销售与收入票据', 'zh-TW': '累計銷售與收入票據', en: 'Total Sales/Revenue Documents', ja: '売上・収入伝票数', ko: '매출/수입 문서 합계', fr: 'Total pièces ventes/revenus' },
      invNoInput:          { 'zh-CN': '暂无采购与费用记录', 'zh-TW': '暫無採購與費用記錄', en: 'No purchase/expense records', ja: '仕入・経費の記録なし', ko: '매입/비용 기록 없음', fr: 'Aucun achat/dépense' },
      invNoOutput:         { 'zh-CN': '暂无销售与收入记录', 'zh-TW': '暫無銷售與收入記錄', en: 'No sales/revenue records', ja: '売上・収入の記録なし', ko: '매출/수입 기록 없음', fr: 'Aucune vente/revenu' },
      invInputRecordCount: { 'zh-CN': '{count} 条采购与费用记录', 'zh-TW': '{count} 筆採購與費用記錄', en: '{count} purchase/expense record(s)', ja: '仕入・経費 {count} 件', ko: '매입/비용 {count}건', fr: '{count} achat(s)/dépense(s)' },
      invOutputRecordCount:{ 'zh-CN': '{count} 条销售与收入记录', 'zh-TW': '{count} 筆銷售與收入記錄', en: '{count} sales/revenue record(s)', ja: '売上・収入 {count} 件', ko: '매출/수입 {count}건', fr: '{count} vente(s)/revenu(s)' },
      invStatusPendingIssue:{ 'zh-CN': '待补票据', 'zh-TW': '待補票據', en: 'Awaiting Document', ja: '伝票待ち', ko: '문서 대기', fr: 'En attente de pièce' },
      invoiceInputLabel: { 'zh-CN': '采购 VAT 单据', 'zh-TW': '採購 VAT 單據', en: 'Input VAT Documents', ja: '仕入VAT書類', ko: '매입 VAT 서류', fr: 'Documents TVA achats' },
      invoiceOutputLabel: { 'zh-CN': '销售 VAT 单据', 'zh-TW': '銷售 VAT 單據', en: 'Output VAT Documents', ja: '売上VAT書類', ko: '매출 VAT 서류', fr: 'Documents TVA ventes' },
      invoicePendingTax: { 'zh-CN': '待处理 VAT', 'zh-TW': '待處理 VAT', en: 'Pending VAT', ja: '未処理VAT', ko: '미처리 VAT', fr: 'TVA à traiter' },
      invoiceTypeOutput: { 'zh-CN': '销售', 'zh-TW': '銷售', en: 'Sales', ja: '売上', ko: '매출', fr: 'Vente' },
      invoiceTypeInput: { 'zh-CN': '采购', 'zh-TW': '採購', en: 'Purchase', ja: '仕入', ko: '매입', fr: 'Achat' },
      inventoryUnit: { 'zh-CN': '单位', 'zh-TW': '單位', en: 'units', ja: '単位', ko: '단위', fr: 'unités' },
      taxSummaryTitle:{ 'zh-CN': 'VAT 含税汇总 (对账用)', 'zh-TW': 'VAT 含稅匯總 (對帳用)', en: 'VAT-Inclusive Summary (Reconciliation)', ja: 'VAT税込集計（照合用）', ko: 'VAT 세금포함 요약 (대조용)', fr: 'Résumé TTC TVA (rapprochement)' },
      purchaseTotal: { 'zh-CN': '采购含税总额', 'zh-TW': '採購含稅總額', en: 'Purchase Total (Incl. VAT)', ja: '仕入VAT込合計', ko: '매입 VAT포함 총액', fr: 'Total achats TTC' },
      salesTotal:    { 'zh-CN': '销售含税总额', 'zh-TW': '銷售含稅總額', en: 'Sales Total (Incl. VAT)', ja: '売上VAT込合計', ko: '매출 VAT포함 총액', fr: 'Total ventes TTC' },
      taxDifference: { 'zh-CN': 'VAT 差额', 'zh-TW': 'VAT 差額', en: 'VAT Difference', ja: 'VAT差額', ko: 'VAT 차액', fr: 'Différence TVA' },
    },
    dashboardSections: ['profit_loss', 'profit_margins', 'vat_summary', 'tax_inclusive_summary'],
    reportTypes: ['profit-loss', 'vat-return'],
    aiContext: 'Use EU VAT accounting concepts (Input VAT deducted from Output VAT). VAT rates vary by member state — use the rate the user configured rather than assuming one, and treat figures as management estimates.',
  },

  KR: {
    id: 'KR',
    defaultCurrency: 'KRW',
    currencySymbol: '₩',
    taxRegime: 'vat',
    taxConcepts: {
      ...NON_CN_GENERIC,
      // System Settings (系统设置) — KR regime: 营业登记号, VAT, KRW.
      setCreditCodeLabel: { 'zh-CN': '营业登记号 / 税号', 'zh-TW': '營業登記號 / 稅號', en: 'Business Registration No. / Tax ID', ja: '事業者登録番号／税番号', ko: '사업자등록번호 / 세금번호', fr: "N° d'enregistrement / N° fiscal" },
      setCreditCodePh:    { 'zh-CN': '例如：123-45-67890', 'zh-TW': '例如：123-45-67890', en: 'e.g. 123-45-67890', ja: '例：123-45-67890', ko: '예: 123-45-67890', fr: 'ex. : 123-45-67890' },
      setAddressPh:       { 'zh-CN': '例如：首尔特别市江南区…', 'zh-TW': '例如：首爾特別市江南區…', en: 'e.g. Gangnam-gu, Seoul', ja: '例：ソウル特別市江南区…', ko: '예: 서울특별시 강남구…', fr: 'ex. : Gangnam-gu, Séoul' },
      setVatRateLabel:    { 'zh-CN': '韩国 VAT 税率', 'zh-TW': '韓國 VAT 稅率', en: 'Korean VAT Rate', ja: '韓国VAT率', ko: '부가가치세율', fr: 'Taux de TVA (Corée)' },
      setPerYear:         { 'zh-CN': '韩元/年', 'zh-TW': '韓元/年', en: 'KRW/yr', ja: 'ウォン/年', ko: '원/년', fr: 'KRW/an' },
      setTaxHint:         { 'zh-CN': '提示：VAT 标准 10%；法人税按利润计算。', 'zh-TW': '提示：VAT 標準 10%；法人稅按利潤計算。', en: 'Note: VAT 10% standard; corporate tax on profit.', ja: '注：VAT標準10%；法人税は利益に対して課税。', ko: '참고: 부가가치세 표준 10%; 법인세는 이익 기준.', fr: 'Note : TVA 10 % ; impôt sur les sociétés sur le bénéfice.' },
      // Purchase/Sales OCR scan button — KR uses generic 票据 wording instead of the
      // CN 税控发票 framing (扫描发票). zh-CN/zh-TW only; en/ja/ko/fr keep the existing
      // scanInvoice i18n value so non-Chinese UIs are unchanged. The component gates
      // this on accLocale === 'KR'; CN/EU/JP/US/TW keep the purchases/sales.scanInvoice i18n.
      scanDocButton: { 'zh-CN': '扫描票据', 'zh-TW': '掃描票據', en: 'Scan Invoice', ja: 'Scan Invoice', ko: 'Scan Invoice', fr: 'Scan Invoice' },
      taxTitle:      { 'zh-CN': '韩国 VAT 统计', 'zh-TW': '韓國 VAT 統計', en: 'Korean VAT Summary', ja: '韓国VAT集計', ko: '부가가치세 요약', fr: 'Résumé TVA (Corée)' },
      // KR frames VAT cards as 采购/销售 (purchase/sales) rather than the CN/JP-VAT
      // ledger 进项/销项. zh-CN/zh-TW only; en/ja/ko keep the standard accounting
      // terms (ko: 매입세액/매출세액). Currency stays KRW (₩).
      inputTax:      { 'zh-CN': '采购 VAT', 'zh-TW': '採購 VAT', en: 'Input VAT', ja: '仕入VAT', ko: '매입세액', fr: 'TVA déductible' },
      outputTax:     { 'zh-CN': '销售 VAT', 'zh-TW': '銷售 VAT', en: 'Output VAT', ja: '売上VAT', ko: '매출세액', fr: 'TVA collectée' },
      estimatedTax:  { 'zh-CN': 'VAT 估算额', 'zh-TW': 'VAT 估算額', en: 'Estimated VAT', ja: 'VATの試算額', ko: '부가가치세 추정액', fr: 'TVA estimée' },
      certifiedInput:{ 'zh-CN': '采购 VAT 合计', 'zh-TW': '採購 VAT 合計', en: 'Total Input VAT', ja: '仕入VAT合計', ko: '매입세액 합계', fr: 'TVA déductible (total)' },
      invoicedOutput:{ 'zh-CN': '销售 VAT 合计', 'zh-TW': '銷售 VAT 合計', en: 'Total Output VAT', ja: '売上VAT合計', ko: '매출세액 합계', fr: 'TVA collectée (total)' },
      plRevenue:     { 'zh-CN': '营业收入', 'zh-TW': '營業收入', en: 'Revenue', ja: '売上', ko: '매출', fr: 'Chiffre d\'affaires' },
      plCost:        { 'zh-CN': '营业成本', 'zh-TW': '營業成本', en: 'Cost of Sales', ja: '売上原価', ko: '매출원가', fr: 'Coût des ventes' },
      plGrossProfit: { 'zh-CN': '毛利', 'zh-TW': '毛利', en: 'Gross Profit', ja: '売上総利益', ko: '매출총이익', fr: 'Marge brute' },
      plOperatingExpenses: { 'zh-CN': '期间费用', 'zh-TW': '期間費用', en: 'Operating Expenses', ja: '営業費用', ko: '영업비용', fr: "Charges d'exploitation" },
      plOperatingProfit: { 'zh-CN': '经营利润', 'zh-TW': '經營利潤', en: 'Operating Profit', ja: '営業利益', ko: '영업이익', fr: "Résultat d'exploitation" },
      plAdmin:       { 'zh-CN': '销售及管理费用', 'zh-TW': '銷售及管理費用', en: 'SG&A Expense', ja: '販売費及び一般管理費', ko: '판매비와관리비', fr: 'Frais généraux' },
      plIncomeTax:   { 'zh-CN': '法人税', 'zh-TW': '法人稅', en: 'Corporate Tax', ja: '法人税', ko: '법인세', fr: 'Impôt sur les sociétés' },
      plNetProfit:   { 'zh-CN': '当期净利润', 'zh-TW': '當期淨利潤', en: 'Net Income', ja: '当期純利益', ko: '당기순이익', fr: 'Résultat net' },
      plPeriodPrefix:{ 'zh-CN': '币种：韩元 | 会计期间：', 'zh-TW': '幣種：韓元 | 會計期間：', en: 'Currency: KRW | Period: ', ja: '通貨：KRW | 期間：', ko: '통화: KRW | 기간: ', fr: 'Devise : KRW | Période : ' },
      plTitle:       { 'zh-CN': '经营损益概览', 'zh-TW': '經營損益概覽', en: 'Management P&L', ja: '経営損益サマリー', ko: '경영 손익 개요', fr: 'Aperçu du résultat (gestion)' },
      tabPlLabel:    { 'zh-CN': '经营损益', 'zh-TW': '經營損益', en: 'Operating P&L', ja: '経営損益', ko: '경영 손익', fr: 'Résultat (gestion)' },
      formTaxRate:   { 'zh-CN': '韩国 VAT 税率', 'zh-TW': '韓國 VAT 稅率', en: 'Korean VAT Rate', ja: '韓国VAT率', ko: '부가가치세율', fr: 'Taux TVA (Corée)' },
      // ── Invoice-query (票据查询) KR-specific overrides ──
      // Use the 采购与费用 / 销售与收入 wording (matching nav + tabs) instead of the
      // shared NON_CN_GENERIC 采购/费用 · 销售/收入 slash form, and 待补票据 instead of
      // 待票据. zh-CN/zh-TW only; en/ja/ko/fr keep the generic base. JP/EU/TW are NOT
      // affected (these overrides live in the KR block only).
      invTotalInput:       { 'zh-CN': '累计采购与费用票据', 'zh-TW': '累計採購與費用票據', en: 'Total Purchase/Expense Documents', ja: '仕入・経費伝票数', ko: '매입/비용 문서 합계', fr: 'Total pièces achats/dépenses' },
      invTotalOutput:      { 'zh-CN': '累计销售与收入票据', 'zh-TW': '累計銷售與收入票據', en: 'Total Sales/Revenue Documents', ja: '売上・収入伝票数', ko: '매출/수입 문서 합계', fr: 'Total pièces ventes/revenus' },
      invNoInput:          { 'zh-CN': '暂无采购与费用记录', 'zh-TW': '暫無採購與費用記錄', en: 'No purchase/expense records', ja: '仕入・経費の記録なし', ko: '매입/비용 기록 없음', fr: 'Aucun achat/dépense' },
      invNoOutput:         { 'zh-CN': '暂无销售与收入记录', 'zh-TW': '暫無銷售與收入記錄', en: 'No sales/revenue records', ja: '売上・収入の記録なし', ko: '매출/수입 기록 없음', fr: 'Aucune vente/revenu' },
      invInputRecordCount: { 'zh-CN': '{count} 条采购与费用记录', 'zh-TW': '{count} 筆採購與費用記錄', en: '{count} purchase/expense record(s)', ja: '仕入・経費 {count} 件', ko: '매입/비용 {count}건', fr: '{count} achat(s)/dépense(s)' },
      invOutputRecordCount:{ 'zh-CN': '{count} 条销售与收入记录', 'zh-TW': '{count} 筆銷售與收入記錄', en: '{count} sales/revenue record(s)', ja: '売上・収入 {count} 件', ko: '매출/수입 {count}건', fr: '{count} vente(s)/revenu(s)' },
      invStatusPendingIssue:{ 'zh-CN': '待补票据', 'zh-TW': '待補票據', en: 'Awaiting Document', ja: '伝票待ち', ko: '문서 대기', fr: 'En attente de pièce' },
      invoiceInputLabel: { 'zh-CN': '进项税金计算书', 'zh-TW': '進項稅金計算書', en: 'Input Tax Invoices', ja: '仕入税金計算書', ko: '매입세금계산서', fr: 'Factures TVA achats' },
      invoiceOutputLabel: { 'zh-CN': '销项税金计算书', 'zh-TW': '銷項稅金計算書', en: 'Output Tax Invoices', ja: '売上税金計算書', ko: '매출세금계산서', fr: 'Factures TVA ventes' },
      invoicePendingTax: { 'zh-CN': '待处理 VAT', 'zh-TW': '待處理 VAT', en: 'Pending VAT', ja: '未処理VAT', ko: '미처리 부가가치세', fr: 'TVA à traiter' },
      invoiceTypeOutput: { 'zh-CN': '销售', 'zh-TW': '銷售', en: 'Sales', ja: '売上', ko: '매출', fr: 'Vente' },
      invoiceTypeInput: { 'zh-CN': '采购', 'zh-TW': '採購', en: 'Purchase', ja: '仕入', ko: '매입', fr: 'Achat' },
      inventoryUnit: { 'zh-CN': '单位', 'zh-TW': '單位', en: 'units', ja: '単位', ko: '단위', fr: 'unités' },
      taxSummaryTitle:{ 'zh-CN': '韩国 VAT 含税汇总（对账用）', 'zh-TW': '韓國 VAT 含稅彙總（對帳用）', en: 'Korean VAT-Inclusive Summary (Reconciliation)', ja: '韓国VAT税込集計（照合用）', ko: '한국 부가가치세 포함 요약 (대조용)', fr: 'Résumé TTC TVA Corée (rapprochement)' },
      purchaseTotal: { 'zh-CN': '采购含税总额', 'zh-TW': '採購含稅總額', en: 'Purchase Total (Incl. VAT)', ja: '仕入VAT込合計', ko: '매입 세금포함 총액', fr: 'Total achats TTC' },
      salesTotal:    { 'zh-CN': '销售含税总额', 'zh-TW': '銷售含稅總額', en: 'Sales Total (Incl. VAT)', ja: '売上VAT込合計', ko: '매출 세금포함 총액', fr: 'Total ventes TTC' },
      taxDifference: { 'zh-CN': 'VAT 差额', 'zh-TW': 'VAT 差額', en: 'VAT Difference', ja: 'VAT差額', ko: '부가가치세 차액', fr: 'Différence TVA' },
    },
    dashboardSections: ['profit_loss', 'profit_margins', 'vat_summary', 'tax_inclusive_summary'],
    reportTypes: ['income-statement', 'vat-summary'],
    aiContext: 'Use Korean VAT (부가가치세) and corporate income tax (법인세) concepts. Use the tax rates the user configured rather than assuming fixed rates, and treat figures as management estimates.',
  },

  TW: {
    id: 'TW',
    defaultCurrency: 'TWD',
    currencySymbol: 'NT$',
    taxRegime: 'business_tax',
    taxConcepts: {
      ...NON_CN_GENERIC,
      // System Settings (系统设置) — TW regime: 统一编号, business tax, TWD.
      setCreditCodeLabel: { 'zh-CN': '统一编号', 'zh-TW': '統一編號', en: 'Unified Business No.', ja: '統一番号', ko: '통일사업자번호', fr: "N° unifié d'entreprise" },
      setCreditCodePh:    { 'zh-CN': '例如：12345678', 'zh-TW': '例如：12345678', en: 'e.g. 12345678', ja: '例：12345678', ko: '예: 12345678', fr: 'ex. : 12345678' },
      setAddressPh:       { 'zh-CN': '例如：台北市信义区…', 'zh-TW': '例如：臺北市信義區…', en: 'e.g. Xinyi District, Taipei', ja: '例：台北市信義区…', ko: '예: 타이베이시 신이구…', fr: 'ex. : District de Xinyi, Taipei' },
      setVatRateLabel:    { 'zh-CN': '营业税率', 'zh-TW': '營業稅率', en: 'Business Tax Rate', ja: '営業税率', ko: '영업세율', fr: "Taux de taxe sur les activités" },
      setPerYear:         { 'zh-CN': '新台币/年', 'zh-TW': '新臺幣/年', en: 'TWD/yr', ja: '台湾ドル/年', ko: '대만 달러/년', fr: 'TWD/an' },
      setTaxHint:         { 'zh-CN': '提示：营业税 5%；营利事业所得税 20%。', 'zh-TW': '提示：營業稅 5%；營利事業所得稅 20%。', en: 'Note: business tax 5%; profit-seeking enterprise income tax 20%.', ja: '注：営業税5%；営利事業所得税20%。', ko: '참고: 영업세 5%; 영리사업소득세 20%.', fr: 'Note : taxe sur les activités 5 % ; impôt sur les bénéfices 20 %.' },
      // TW frames the dashboard tax cards with explicit 台湾营业税 + 采购进项/销售销项
      // wording. zh-CN must stay simplified (the UI is simplified Chinese); zh-TW is
      // traditional; en/ja/ko/fr keep the standard Business Tax terms. Currency NT$.
      taxTitle:      { 'zh-CN': '台湾营业税统计', 'zh-TW': '台灣營業稅統計', en: 'Business Tax Summary', ja: '営業税集計', ko: '영업세 통계', fr: 'Résumé taxe activité' },
      inputTax:      { 'zh-CN': '采购进项营业税', 'zh-TW': '採購進項營業稅', en: 'Input Business Tax', ja: '仕入営業税', ko: '매입 영업세', fr: 'Taxe payée' },
      outputTax:     { 'zh-CN': '销售销项营业税', 'zh-TW': '銷售銷項營業稅', en: 'Output Business Tax', ja: '売上営業税', ko: '매출 영업세', fr: 'Taxe collectée' },
      estimatedTax:  { 'zh-CN': '营业税估算额', 'zh-TW': '營業稅估算額', en: 'Estimated Business Tax', ja: '営業税の試算額', ko: '영업세 추정액', fr: 'Taxe sur activité estimée' },
      certifiedInput:{ 'zh-CN': '进项营业税额合计', 'zh-TW': '進項營業稅額合計', en: 'Total Input Business Tax', ja: '仕入営業税額合計', ko: '매입 영업세액 합계', fr: 'Taxe sur achats (total)' },
      invoicedOutput:{ 'zh-CN': '销项营业税额合计', 'zh-TW': '銷項營業稅額合計', en: 'Total Output Business Tax', ja: '売上営業税額合計', ko: '매출 영업세액 합계', fr: 'Taxe sur ventes (total)' },
      plRevenue:     { 'zh-CN': '销售收入', 'zh-TW': '銷售收入', en: 'Sales Revenue', ja: '売上', ko: '매출', fr: 'Chiffre d\'affaires' },
      plCost:        { 'zh-CN': '销货成本', 'zh-TW': '銷貨成本', en: 'COGS', ja: '売上原価', ko: '매출원가', fr: 'Coût des ventes' },
      plGrossProfit: { 'zh-CN': '毛利', 'zh-TW': '毛利', en: 'Gross Profit', ja: '粗利益', ko: '매출총이익', fr: 'Marge brute' },
      plOperatingExpenses: { 'zh-CN': '期间费用', 'zh-TW': '期間費用', en: 'Operating Expenses', ja: '営業費用', ko: '영업비용', fr: "Charges d'exploitation" },
      plOperatingProfit: { 'zh-CN': '经营利润', 'zh-TW': '經營利潤', en: 'Operating Profit', ja: '営業利益', ko: '영업이익', fr: "Résultat d'exploitation" },
      plAdmin:       { 'zh-CN': '管理费用', 'zh-TW': '管理費用', en: 'Admin Expense', ja: '一般管理費', ko: '관리비', fr: 'Frais admin' },
      plIncomeTax:   { 'zh-CN': '营利事业所得税', 'zh-TW': '營利事業所得稅', en: 'Business Income Tax', ja: '営利事業所得税', ko: '영리사업 소득세', fr: 'Impôt sur les bénéfices' },
      plNetProfit:   { 'zh-CN': '净利润', 'zh-TW': '淨利潤', en: 'Net Profit', ja: '純利益', ko: '순이익', fr: 'Bénéfice net' },
      plPeriodPrefix:{ 'zh-CN': '币种：新台币 | 会计期间：', 'zh-TW': '幣種：新臺幣 | 會計期間：', en: 'Currency: TWD | Period: ', ja: '通貨：TWD | 期間：', ko: '통화: TWD | 기간: ', fr: 'Devise : TWD | Période : ' },
      plTitle:       { 'zh-CN': '经营损益概览', 'zh-TW': '經營損益概覽', en: 'Management P&L', ja: '経営損益サマリー', ko: '경영 손익 개요', fr: 'Aperçu du résultat (gestion)' },
      tabPlLabel:    { 'zh-CN': '经营损益', 'zh-TW': '經營損益', en: 'Operating P&L', ja: '経営損益', ko: '경영 손익', fr: 'Résultat (gestion)' },
      formTaxRate:   { 'zh-CN': '营业税率', 'zh-TW': '營業稅率', en: 'Business Tax Rate', ja: '営業税率', ko: '영업세율', fr: 'Taux taxe activité' },
      // ── Purchase/Sales 发票/凭证 wording (TW business-tax context) ──
      // TW frames the document number as 发票/凭证号码 (统一发票/凭证) rather than the
      // generic 票据号码, and the upload/empty hints reference 发票…收据…凭证. zh-CN/
      // zh-TW only; en/ja/ko/fr keep the NON_CN_GENERIC values (TW non-Chinese UI
      // unchanged). CN/US/EU/JP/KR are not affected (these overrides live in TW only).
      headerInvoiceNo:    { 'zh-CN': '发票/凭证号码', 'zh-TW': '發票/憑證號碼', en: 'Receipt / Document #', ja: '伝票番号', ko: '전표 번호', fr: 'N° de pièce' },
      uploadTitle:        { 'zh-CN': '拖放或点击上传发票、收据或凭证', 'zh-TW': '拖放或點擊上傳發票、收據或憑證', en: 'Drag and drop or click to upload a receipt, bill or document', ja: 'レシート・請求書・伝票をドラッグまたはクリックでアップロード', ko: '영수증, 청구서 또는 전표를 드래그하거나 클릭해 업로드', fr: 'Glissez ou cliquez pour téléverser un reçu, une facture ou un justificatif' },
      uploadTitleSales:   { 'zh-CN': '拖放或点击上传发票、收据或凭证', 'zh-TW': '拖放或點擊上傳發票、收據或憑證', en: 'Drag and drop or click to upload a receipt, bill or document', ja: 'レシート・請求書・伝票をドラッグまたはクリックでアップロード', ko: '영수증, 청구서 또는 전표를 드래그하거나 클릭해 업로드', fr: 'Glissez ou cliquez pour téléverser un reçu, une facture ou un justificatif' },
      uploadSubtitle:     { 'zh-CN': '自动提取日期、金额、供应商及发票/凭证号码', 'zh-TW': '自動擷取日期、金額、供應商及發票/憑證號碼', en: 'Auto-extract date, amount, vendor and document number', ja: '日付、金額、仕入先、伝票番号を自動抽出', ko: '날짜, 금액, 공급업체, 전표 번호를 자동 추출', fr: 'Extraction automatique de la date, du montant, du fournisseur et du numéro' },
      uploadSubtitleSales:{ 'zh-CN': '自动提取日期、金额、客户及发票/凭证号码', 'zh-TW': '自動擷取日期、金額、客戶及發票/憑證號碼', en: 'Supports images or PDF, recognized by AI', ja: '画像またはPDFに対応、AIで自動認識', ko: '이미지 또는 PDF 지원, AI 자동 인식', fr: 'Images ou PDF, reconnaissance IA' },
      emptyPurchase:      { 'zh-CN': '暂无采购或费用记录，请上传发票、收据或凭证，或手动新增。', 'zh-TW': '暫無採購或費用記錄，請上傳發票、收據或憑證，或手動新增。', en: 'No purchase or expense records yet. Upload a receipt, bill or document, or add one manually.', ja: '仕入・経費の記録がありません。レシート・請求書・伝票をアップロードするか手動で追加してください。', ko: '매입/비용 기록이 없습니다. 영수증, 청구서, 전표를 업로드하거나 수동으로 추가하세요.', fr: 'Aucun achat/dépense. Téléversez un reçu, une facture ou ajoutez manuellement.' },
      emptySales:         { 'zh-CN': '暂无销售记录，请上传发票、收据或凭证，或手动新增。', 'zh-TW': '暫無銷售記錄，請上傳發票、收據或憑證，或手動新增。', en: 'No sales records yet. Upload a receipt, bill or document, or add one manually.', ja: '売上記録がありません。レシート・請求書・伝票をアップロードするか手動で追加してください。', ko: '매출 기록이 없습니다. 영수증, 청구서, 전표를 업로드하거나 수동으로 추가하세요.', fr: 'Aucune vente. Téléversez un reçu, une facture ou ajoutez manuellement.' },
      // ── 票据查询 / 状态 / OCR：TW 用「凭证」语境（不把「票据」作通用主词）──
      // zh-CN/zh-TW only; en/ja/ko/fr keep the NON_CN_GENERIC values (TW non-Chinese UI
      // unchanged). CN/JP/EU/KR are not affected (these overrides live in the TW block).
      invQueryTitle:      { 'zh-CN': '凭证查询', 'zh-TW': '憑證查詢', en: 'Document Search', ja: '伝票検索', ko: '문서 조회', fr: 'Recherche de pièces' },
      scanningTitle:      { 'zh-CN': '正在分析凭证…', 'zh-TW': '正在分析憑證…', en: 'Analyzing document…', ja: '伝票を解析中…', ko: '문서 분석 중…', fr: 'Analyse du document…' },
      invSearchPlaceholder:{ 'zh-CN': '搜索发票/凭证号码或往来单位...', 'zh-TW': '搜尋發票/憑證號碼或往來單位...', en: 'Search by document number or party...', ja: '伝票番号または取引先で検索...', ko: '문서 번호 또는 거래처로 검색...', fr: 'Rechercher par n° de pièce ou tiers...' },
      invFilterAll:       { 'zh-CN': '全部凭证', 'zh-TW': '全部憑證', en: 'All Documents', ja: 'すべての伝票', ko: '전체 문서', fr: 'Toutes les pièces' },
      invTableTitle:      { 'zh-CN': '凭证流转全景视图', 'zh-TW': '憑證流轉全景視圖', en: 'Document Flow Overview', ja: '伝票フロー全体ビュー', ko: '문서 흐름 개요', fr: "Vue d'ensemble des pièces" },
      invTableSubtitle:   { 'zh-CN': '核对凭证流与库存/交易记录一致性', 'zh-TW': '核對憑證流與庫存/交易記錄一致性', en: 'Reconcile document flow with inventory / transaction records', ja: '伝票フローと在庫・取引記録の整合性を確認', ko: '문서 흐름과 재고/거래 기록의 일관성 확인', fr: 'Rapprocher les pièces avec les stocks / transactions' },
      invHeaderInvoiceNo: { 'zh-CN': '发票/凭证号码', 'zh-TW': '發票/憑證號碼', en: 'Document #', ja: '伝票番号', ko: '문서 번호', fr: 'N° de pièce' },
      invEmpty:           { 'zh-CN': '未找到匹配的凭证记录', 'zh-TW': '未找到匹配的憑證記錄', en: 'No matching documents found', ja: '一致する伝票が見つかりません', ko: '일치하는 문서가 없습니다', fr: 'Aucune pièce correspondante' },
      invTotalInput:      { 'zh-CN': '累计采购/费用凭证', 'zh-TW': '累計採購/費用憑證', en: 'Total Purchase/Expense Documents', ja: '仕入・経費伝票数', ko: '매입/비용 문서 합계', fr: 'Total pièces achats/dépenses' },
      invTotalOutput:     { 'zh-CN': '累计销售/收入凭证', 'zh-TW': '累計銷售/收入憑證', en: 'Total Sales/Revenue Documents', ja: '売上・収入伝票数', ko: '매출/수입 문서 합계', fr: 'Total pièces ventes/revenus' },
      invStatusFilter:    { 'zh-CN': '凭证状态', 'zh-TW': '憑證狀態', en: 'Document Status', ja: '伝票ステータス', ko: '문서 상태', fr: 'Statut de la pièce' },
      invStatusVerified:  { 'zh-CN': '已确认', 'zh-TW': '已確認', en: 'Verified', ja: '確認済み', ko: '확인됨', fr: 'Vérifié' },
      invStatusPendingIssue:{ 'zh-CN': '待补凭证', 'zh-TW': '待補憑證', en: 'Awaiting Document', ja: '伝票待ち', ko: '문서 대기', fr: 'En attente de pièce' },
      invStatusIssued:    { 'zh-CN': '已开立发票', 'zh-TW': '已開立發票', en: 'Issued', ja: '発行済み', ko: '발행됨', fr: 'Émis' },
      // ── 应收应付 (AccountsPage) TW wording ── 帐龄 (not 账龄) + tab-specific 明细/空状态.
      // Applied only for TW + zh-CN/zh-TW (component gates on accLocale==='TW' && zh);
      // en/ja/ko/fr are present for safety but unused (TW non-Chinese UI keeps i18n).
      acctAgingTitle:          { 'zh-CN': '帐龄分析', 'zh-TW': '帳齡分析', en: 'Aging Analysis', ja: 'エイジング分析', ko: '채권 연령 분석', fr: "Analyse d'ancienneté" },
      acctDetailsReceivable:   { 'zh-CN': '未收款明细', 'zh-TW': '未收款明細', en: 'Outstanding Receivables', ja: '未収金明細', ko: '미수금 내역', fr: 'Créances en attente' },
      acctDetailsPayable:      { 'zh-CN': '未付款明细', 'zh-TW': '未付款明細', en: 'Outstanding Payables', ja: '未払金明細', ko: '미지급금 내역', fr: 'Dettes en attente' },
      acctAllClearedReceivable:{ 'zh-CN': '所有应收款项已结清', 'zh-TW': '所有應收款項已結清', en: 'All receivables settled', ja: '売掛金はすべて回収済み', ko: '모든 미수금 정산 완료', fr: 'Toutes les créances réglées' },
      acctAllClearedPayable:   { 'zh-CN': '所有应付款项已结清', 'zh-TW': '所有應付款項已結清', en: 'All payables settled', ja: '買掛金はすべて支払済み', ko: '모든 미지급금 정산 완료', fr: 'Toutes les dettes réglées' },
      invoiceInputLabel: { 'zh-CN': '进项发票数', 'zh-TW': '進項發票數', en: 'Input Invoices', ja: '仕入請求書', ko: '매입계산서', fr: 'Factures achats' },
      invoiceOutputLabel: { 'zh-CN': '销项发票数', 'zh-TW': '銷項發票數', en: 'Output Invoices', ja: '売上請求書', ko: '매출계산서', fr: 'Factures ventes' },
      invoicePendingTax: { 'zh-CN': '待处理营业税', 'zh-TW': '待處理營業稅', en: 'Pending Business Tax', ja: '未処理営業税', ko: '미처리 영업세', fr: 'Taxe sur activité à traiter' },
      invoiceTypeOutput: { 'zh-CN': '销售', 'zh-TW': '銷售', en: 'Sales', ja: '売上', ko: '매출', fr: 'Vente' },
      invoiceTypeInput: { 'zh-CN': '采购', 'zh-TW': '採購', en: 'Purchase', ja: '仕入', ko: '매입', fr: 'Achat' },
      inventoryUnit: { 'zh-CN': '单位', 'zh-TW': '單位', en: 'units', ja: '単位', ko: '단위', fr: 'unités' },
      // ── 收支记录 (TransactionsPage) 表头：台湾会计制度的正式字段 ──
      // 仅 zh-CN/zh-TW 生效（组件按 accLocale==='TW' && zh 选择）；en/ja/ko/fr 保留 i18n
      // (transactions.category / transactions.scheduleLine / tableHeaders.status)，TW 非
      // 中文 UI 不变。CN 不受影响。付款/收款状态按收支 tab 选择。UI 仍是简体（zh-CN）。
      txnCategoryHeader:      { 'zh-CN': '类别', 'zh-TW': '類別', en: 'Category', ja: 'カテゴリ', ko: '분류', fr: 'Catégorie' },
      txnScheduleHeader:      { 'zh-CN': '会计科目', 'zh-TW': '會計科目', en: 'Account', ja: '勘定科目', ko: '계정', fr: 'Compte' },
      txnPaymentStatusHeader: { 'zh-CN': '付款状态', 'zh-TW': '付款狀態', en: 'Payment Status', ja: '支払ステータス', ko: '결제 상태', fr: 'Statut de paiement' },
      txnReceiptStatusHeader: { 'zh-CN': '收款状态', 'zh-TW': '收款狀態', en: 'Receipt Status', ja: '入金ステータス', ko: '수금 상태', fr: "Statut d'encaissement" },
      // ── 财务报表 资产负债表 (TW)：台湾会计制度用语，仅 zh-CN/zh-TW 覆盖 ──
      // 负债及权益 / 权益 / 资本 / 保留盈余 / 应收帐款（台湾用 帐·帳，非大陆 账）。
      // en/ja/ko/fr 沿用 NON_CN_GENERIC 基值（TW 非中文 UI 不变）；CN/US/JP/EU/KR
      // 不受影响（覆盖只在 TW 块内，spread 后置生效）。货币资金按用户口径保留不动。
      balRecvLabel:       { 'zh-CN': '应收帐款', 'zh-TW': '應收帳款', en: 'Accounts Receivable', ja: '売掛金', ko: '매출채권', fr: 'Créances clients' },
      balPaidInCapital:   { 'zh-CN': '资本', 'zh-TW': '資本', en: 'Paid-in Capital', ja: '資本金', ko: '납입자본금', fr: 'Capital social' },
      balRetainedEarnings:{ 'zh-CN': '保留盈余', 'zh-TW': '保留盈餘', en: 'Retained Earnings', ja: '利益剰余金', ko: '이익잉여금', fr: 'Résultat reporté' },
      balEquityHeader:    { 'zh-CN': '权益', 'zh-TW': '權益', en: 'Equity', ja: '純資産', ko: '자본', fr: 'Capitaux propres' },
      balLiabEquityHeader:{ 'zh-CN': '负债及权益', 'zh-TW': '負債及權益', en: 'Liabilities & Equity', ja: '負債及び純資産', ko: '부채 및 자본', fr: 'Passif' },
      balTotalLiabEquity: { 'zh-CN': '负债及权益总计', 'zh-TW': '負債及權益總計', en: 'Total Liabilities & Equity', ja: '負債及び純資産合計', ko: '부채 및 자본 총계', fr: 'Total passif' },
      taxSummaryTitle:{ 'zh-CN': '台湾营业税汇总（对账用）', 'zh-TW': '臺灣營業稅彙總（對帳用）', en: 'Tax-Inclusive Summary (Reconciliation)', ja: '税込金額集計（照合用）', ko: '세금포함 요약 (대조용)', fr: 'Résumé TTC (rapprochement)' },
      purchaseTotal: { 'zh-CN': '采购含税总额', 'zh-TW': '採購含稅總額', en: 'Purchase Total (Incl. Tax)', ja: '仕入税込合計', ko: '매입 세금포함 총액', fr: 'Total achats TTC' },
      salesTotal:    { 'zh-CN': '销售含税总额', 'zh-TW': '銷售含稅總額', en: 'Sales Total (Incl. Tax)', ja: '売上税込合計', ko: '매출 세금포함 총액', fr: 'Total ventes TTC' },
      taxDifference: { 'zh-CN': '营业税差额', 'zh-TW': '營業稅差額', en: 'Business Tax Difference', ja: '営業税差額', ko: '영업세 차액', fr: 'Différence taxe activité' },
    },
    dashboardSections: ['profit_loss', 'profit_margins', 'business_tax_summary', 'tax_inclusive_summary'],
    reportTypes: ['income-statement', 'business-tax'],
    aiContext: 'Use Taiwan Business Tax (營業稅) and profit-seeking enterprise income tax (營利事業所得稅) concepts. Use the tax rates the user configured rather than assuming fixed rates, and treat figures as management estimates.',
  },
};

export function getAccountingLocale(id: string): AccountingLocaleConfig {
  return ACCOUNTING_LOCALES[id as AccountingLocaleId] || ACCOUNTING_LOCALES.CN;
}

// ─── JP transaction-category labels for the Chinese UI (收支记录 分类下拉) ───
// Under JP accountingLocale + zh-CN/zh-TW UI, the transaction category dropdown
// must read as Chinese main wording with the Japanese formal account name in
// parentheses — never the raw Japanese report headers (損益計算書 / 販管費 /
// 売上原価 …) as the primary text. Keyed by the stable category slug so this also
// corrects stale-DB rows (e.g. a 売上原価/COGS row mislabeled 广告费): services/
// api.ts applies it on read. Display only — category id/slug and the backend
// report mapping (by slug) are unchanged. zh-CN/zh-TW only; en/ja/ko/fr keep the
// seeded label + schedule_line. Slugs mirror electron/db/seedCategories.js JP rows.
export const JP_TXN_CATEGORY_LABELS: Record<string, { label: Record<'zh-CN' | 'zh-TW', string>; scheduleLine: Record<'zh-CN' | 'zh-TW', string> }> = {
  // income
  sales:         { label: { 'zh-CN': '销售收入',   'zh-TW': '銷售收入' },   scheduleLine: { 'zh-CN': '经营损益-营业收入（売上高）',     'zh-TW': '經營損益-營業收入（売上高）' } },
  other:         { label: { 'zh-CN': '营业外收入', 'zh-TW': '營業外收入' }, scheduleLine: { 'zh-CN': '经营损益-营业外收入（営業外収益）', 'zh-TW': '經營損益-營業外收入（営業外収益）' } },
  // expense
  cogs:          { label: { 'zh-CN': '销售成本',   'zh-TW': '銷售成本' },   scheduleLine: { 'zh-CN': '经营损益-销售成本（売上原価）',   'zh-TW': '經營損益-銷售成本（売上原価）' } },
  salary:        { label: { 'zh-CN': '工资',       'zh-TW': '工資' },       scheduleLine: { 'zh-CN': '经营损益-工资薪金（給料手当）',   'zh-TW': '經營損益-薪資薪金（給料手当）' } },
  travel:        { label: { 'zh-CN': '差旅交通',   'zh-TW': '差旅交通' },   scheduleLine: { 'zh-CN': '经营损益-差旅交通费（旅費交通費）', 'zh-TW': '經營損益-差旅交通費（旅費交通費）' } },
  communication: { label: { 'zh-CN': '通信费',     'zh-TW': '通訊費' },     scheduleLine: { 'zh-CN': '经营损益-通信费（通信費）',       'zh-TW': '經營損益-通訊費（通信費）' } },
  utilities:     { label: { 'zh-CN': '水电费',     'zh-TW': '水電費' },     scheduleLine: { 'zh-CN': '经营损益-水电光热费（水道光熱費）', 'zh-TW': '經營損益-水電光熱費（水道光熱費）' } },
  supplies:      { label: { 'zh-CN': '消耗品',     'zh-TW': '消耗品' },     scheduleLine: { 'zh-CN': '经营损益-消耗品费（消耗品費）',   'zh-TW': '經營損益-消耗品費（消耗品費）' } },
  entertain:     { label: { 'zh-CN': '招待交际费', 'zh-TW': '招待交際費' }, scheduleLine: { 'zh-CN': '经营损益-交际费（接待交際費）',   'zh-TW': '經營損益-交際費（接待交際費）' } },
  advertising:   { label: { 'zh-CN': '广告费',     'zh-TW': '廣告費' },     scheduleLine: { 'zh-CN': '经营损益-广告宣传费（広告宣伝費）', 'zh-TW': '經營損益-廣告宣傳費（広告宣伝費）' } },
  rent:          { label: { 'zh-CN': '租金',       'zh-TW': '租金' },       scheduleLine: { 'zh-CN': '经营损益-地租家租（地代家賃）',   'zh-TW': '經營損益-地租家租（地代家賃）' } },
  tax:           { label: { 'zh-CN': '税金',       'zh-TW': '稅金' },       scheduleLine: { 'zh-CN': '经营损益-税金公课（租税公課）',   'zh-TW': '經營損益-稅金公課（租税公課）' } },
  depreciation:  { label: { 'zh-CN': '折旧',       'zh-TW': '折舊' },       scheduleLine: { 'zh-CN': '经营损益-折旧费（減価償却費）',   'zh-TW': '經營損益-折舊費（減価償却費）' } },
  misc:          { label: { 'zh-CN': '其他费用',   'zh-TW': '其他費用' },   scheduleLine: { 'zh-CN': '经营损益-杂费（雑費）',         'zh-TW': '經營損益-雜費（雑費）' } },
};

// ─── EU transaction-category labels for the Chinese UI (收支记录 分类下拉) ───
// Under EU accountingLocale + zh-CN/zh-TW UI the category dropdown must read as
// Chinese (经营损益-… / VAT 待处理), never the seeded English report lines (P&L - … /
// VAT Return). Keyed by the stable category slug so it also corrects stale-DB rows;
// services/api.ts applies it on read. Display only — id/slug and the backend report
// mapping (by slug) are unchanged. zh-CN/zh-TW only; en/ja/ko/fr keep the seeded
// label + schedule_line. Slugs mirror electron/db/seedCategories.js EU rows.
export const EU_TXN_CATEGORY_LABELS: Record<string, { label: Record<'zh-CN' | 'zh-TW', string>; scheduleLine: Record<'zh-CN' | 'zh-TW', string> }> = {
  // income
  revenue:        { label: { 'zh-CN': '营业收入', 'zh-TW': '營業收入' }, scheduleLine: { 'zh-CN': '经营损益-营业收入', 'zh-TW': '經營損益-營業收入' } },
  financial:      { label: { 'zh-CN': '财务收入', 'zh-TW': '財務收入' }, scheduleLine: { 'zh-CN': '经营损益-财务收入', 'zh-TW': '經營損益-財務收入' } },
  // expense
  purchases:      { label: { 'zh-CN': '采购',     'zh-TW': '採購' },     scheduleLine: { 'zh-CN': '经营损益-采购',     'zh-TW': '經營損益-採購' } },
  rent:           { label: { 'zh-CN': '租金',     'zh-TW': '租金' },     scheduleLine: { 'zh-CN': '经营损益-租金',     'zh-TW': '經營損益-租金' } },
  salaries:       { label: { 'zh-CN': '工资',     'zh-TW': '工資' },     scheduleLine: { 'zh-CN': '经营损益-工资',     'zh-TW': '經營損益-工資' } },
  'social-charges':{ label: { 'zh-CN': '社会保险', 'zh-TW': '社會保險' }, scheduleLine: { 'zh-CN': '经营损益-社会保险费', 'zh-TW': '經營損益-社會保險費' } },
  travel:         { label: { 'zh-CN': '差旅',     'zh-TW': '差旅' },     scheduleLine: { 'zh-CN': '经营损益-差旅费',   'zh-TW': '經營損益-差旅費' } },
  professional:   { label: { 'zh-CN': '专业服务', 'zh-TW': '專業服務' }, scheduleLine: { 'zh-CN': '经营损益-专业服务费', 'zh-TW': '經營損益-專業服務費' } },
  marketing:      { label: { 'zh-CN': '市场推广', 'zh-TW': '市場推廣' }, scheduleLine: { 'zh-CN': '经营损益-市场推广费', 'zh-TW': '經營損益-市場推廣費' } },
  energy:         { label: { 'zh-CN': '能源',     'zh-TW': '能源' },     scheduleLine: { 'zh-CN': '经营损益-能源费用',   'zh-TW': '經營損益-能源費用' } },
  amortization:   { label: { 'zh-CN': '摊销',     'zh-TW': '攤銷' },     scheduleLine: { 'zh-CN': '经营损益-摊销',     'zh-TW': '經營損益-攤銷' } },
  'vat-net':      { label: { 'zh-CN': 'VAT 应纳', 'zh-TW': 'VAT 應納' }, scheduleLine: { 'zh-CN': 'VAT 待处理',       'zh-TW': 'VAT 待處理' } },
};

// ─── KR transaction-category labels for the Chinese UI (收支记录 分类下拉) ───
// Under KR accountingLocale + zh-CN/zh-TW UI the category dropdown must read as
// Chinese main wording with the Korean formal account name in parentheses, never
// the seeded Korean report lines (손익계산서-… / 판관비-…) as the primary text. Keyed
// by the stable category slug so it also corrects stale-DB rows; services/api.ts
// applies it on read. Display only — id/slug and the backend report mapping (by
// slug) are unchanged. zh-CN/zh-TW only; en/ja/ko/fr keep the seeded label +
// schedule_line. Slugs mirror electron/db/seedCategories.js KR rows.
export const KR_TXN_CATEGORY_LABELS: Record<string, { label: Record<'zh-CN' | 'zh-TW', string>; scheduleLine: Record<'zh-CN' | 'zh-TW', string> }> = {
  // income
  sales:           { label: { 'zh-CN': '营业收入',   'zh-TW': '營業收入' }, scheduleLine: { 'zh-CN': '经营损益-营业收入（매출）',   'zh-TW': '經營損益-營業收入（매출）' } },
  'non-operating': { label: { 'zh-CN': '营业外收入', 'zh-TW': '營業外收入' }, scheduleLine: { 'zh-CN': '经营损益-营业外收入（영업외수익）', 'zh-TW': '經營損益-營業外收入（영업외수익）' } },
  // expense
  cogs:            { label: { 'zh-CN': '销售成本',   'zh-TW': '銷售成本' }, scheduleLine: { 'zh-CN': '经营损益-销售成本（매출원가）', 'zh-TW': '經營損益-銷售成本（매출원가）' } },
  salary:          { label: { 'zh-CN': '工资',       'zh-TW': '工資' },     scheduleLine: { 'zh-CN': '经营损益-工资薪金（급여）',   'zh-TW': '經營損益-薪資薪金（급여）' } },
  welfare:         { label: { 'zh-CN': '福利',       'zh-TW': '福利' },     scheduleLine: { 'zh-CN': '经营损益-福利费（복리후생비）', 'zh-TW': '經營損益-福利費（복리후생비）' } },
  travel:          { label: { 'zh-CN': '差旅',       'zh-TW': '差旅' },     scheduleLine: { 'zh-CN': '经营损益-差旅费（여비교통비）', 'zh-TW': '經營損益-差旅費（여비교통비）' } },
  communication:   { label: { 'zh-CN': '通讯',       'zh-TW': '通訊' },     scheduleLine: { 'zh-CN': '经营损益-通信费（통신비）',   'zh-TW': '經營損益-通訊費（통신비）' } },
  utilities:       { label: { 'zh-CN': '水电费',     'zh-TW': '水電費' },   scheduleLine: { 'zh-CN': '经营损益-水电费（수도광열비）', 'zh-TW': '經營損益-水電費（수도광열비）' } },
  supplies:        { label: { 'zh-CN': '消耗品',     'zh-TW': '消耗品' },   scheduleLine: { 'zh-CN': '经营损益-消耗品费（소모품비）', 'zh-TW': '經營損益-消耗品費（소모품비）' } },
  entertain:       { label: { 'zh-CN': '招待',       'zh-TW': '招待' },     scheduleLine: { 'zh-CN': '经营损益-招待费（접대비）',   'zh-TW': '經營損益-招待費（접대비）' } },
  advertising:     { label: { 'zh-CN': '广告',       'zh-TW': '廣告' },     scheduleLine: { 'zh-CN': '经营损益-广告宣传费（광고선전비）', 'zh-TW': '經營損益-廣告宣傳費（광고선전비）' } },
  rent:            { label: { 'zh-CN': '租金',       'zh-TW': '租金' },     scheduleLine: { 'zh-CN': '经营损益-租赁费（임차료）',   'zh-TW': '經營損益-租賃費（임차료）' } },
  depreciation:    { label: { 'zh-CN': '折旧',       'zh-TW': '折舊' },     scheduleLine: { 'zh-CN': '经营损益-折旧费（감가상각비）', 'zh-TW': '經營損益-折舊費（감가상각비）' } },
};

// ─── TW transaction-category labels for the Chinese UI (收支记录 分类下拉) ───
// Under TW accountingLocale + zh-CN/zh-TW UI the category dropdown shows
// `displayLabel → schedule_line` with the Taiwan report-line wording in 中文冒号
// format (经营损益：… / 經營損益：…), NOT the half-width-hyphen seed form (经营损益-…).
// 口径 corrections vs the raw seed: 营业税 (税款：营业税) and 营利事业所得税 (税款：营利事业
// 所得税) are 税务 filing lines, NOT ordinary 损益表 expense lines; the 'sales' label reads
// 销货收入 and 'selling' reads 销售费用. Keyed by the stable slug (applied read-time in
// services/api.ts) so it also fixes stale-DB rows; id/slug + backend report mapping
// (by slug) are unchanged — display only. zh-CN/zh-TW only.
export const TW_TXN_CATEGORY_LABELS: Record<string, { label: Record<'zh-CN' | 'zh-TW', string>; scheduleLine: Record<'zh-CN' | 'zh-TW', string> }> = {
  // income
  sales:          { label: { 'zh-CN': '销货收入',     'zh-TW': '銷貨收入' },     scheduleLine: { 'zh-CN': '经营损益：营业收入',       'zh-TW': '經營損益：營業收入' } },
  other:          { label: { 'zh-CN': '其他营业收入', 'zh-TW': '其他營業收入' }, scheduleLine: { 'zh-CN': '经营损益：其他营业收入',   'zh-TW': '經營損益：其他營業收入' } },
  // expense
  cogs:           { label: { 'zh-CN': '销货成本',     'zh-TW': '銷貨成本' },     scheduleLine: { 'zh-CN': '经营损益：销货成本',       'zh-TW': '經營損益：銷貨成本' } },
  selling:        { label: { 'zh-CN': '销售费用',     'zh-TW': '銷售費用' },     scheduleLine: { 'zh-CN': '经营损益：销售费用',       'zh-TW': '經營損益：銷售費用' } },
  admin:          { label: { 'zh-CN': '管理费用',     'zh-TW': '管理費用' },     scheduleLine: { 'zh-CN': '经营损益：管理费用',       'zh-TW': '經營損益：管理費用' } },
  rd:             { label: { 'zh-CN': '研究发展费用', 'zh-TW': '研究發展費用' }, scheduleLine: { 'zh-CN': '经营损益：研究发展费用',   'zh-TW': '經營損益：研究發展費用' } },
  'business-tax': { label: { 'zh-CN': '营业税',       'zh-TW': '營業稅' },       scheduleLine: { 'zh-CN': '税款：营业税',           'zh-TW': '稅款：營業稅' } },
  'income-tax':   { label: { 'zh-CN': '营利事业所得税', 'zh-TW': '營利事業所得稅' }, scheduleLine: { 'zh-CN': '税款：营利事业所得税', 'zh-TW': '稅款：營利事業所得稅' } },
};

// ─── CN transaction-category labels for the Chinese UI (收支记录 分类下拉) ───
// Under CN accountingLocale + zh-CN/zh-TW UI the category dropdown shows the China-GAAP
// report-line name as 利润表 / 利潤表 (the mainland P&L title, matching the CN block
// plTitle) instead of the seed's 经营损益-…, and the surcharge category reads 税金及附加
// (not 营业税金及附加). Keyed by the stable slug (applied read-time in services/api.ts) so
// it also fixes stale-DB rows; id/slug + backend report mapping (by slug) are unchanged —
// display only. zh-CN/zh-TW only; en/ja/ko/fr keep the seed values.
// schedule_line is keyed by slug; the en/ja/ko/fr values use a conservative bilingual
// style — the management-basis Chinese original (经营损益-…) is kept verbatim and a
// bracketed translation is appended (consistent with the accounting-profile notes in
// #286). DISPLAY ONLY: the stored value and the backend report mapping (by slug) are
// unchanged; this only localizes what CategoriesSection / TransactionsPage render.
export const CN_TXN_CATEGORY_LABELS: Record<string, { label: Record<'zh-CN' | 'zh-TW', string>; scheduleLine: Record<'zh-CN' | 'zh-TW' | 'en' | 'ja' | 'ko' | 'fr', string> }> = {
  // income
  sales:           { label: { 'zh-CN': '主营业务收入', 'zh-TW': '主營業務收入' }, scheduleLine: { 'zh-CN': '经营损益-营业收入',     'zh-TW': '經營損益-營業收入', en: '经营损益-营业收入 (P&L · Operating Revenue)', ja: '经营损益-营业收入（経営損益・営業収益）', ko: '经营损益-营业收入(경영손익·영업수익)', fr: '经营损益-营业收入 (Résultat · Produits d\'exploitation)' } },
  'other-revenue': { label: { 'zh-CN': '其他业务收入', 'zh-TW': '其他業務收入' }, scheduleLine: { 'zh-CN': '经营损益-其他业务收入', 'zh-TW': '經營損益-其他業務收入', en: '经营损益-其他业务收入 (P&L · Other Operating Revenue)', ja: '经营损益-其他业务收入（経営損益・その他営業収益）', ko: '经营损益-其他业务收入(경영손익·기타영업수익)', fr: '经营损益-其他业务收入 (Résultat · Autres produits d\'exploitation)' } },
  interest:        { label: { 'zh-CN': '利息收入',     'zh-TW': '利息收入' },     scheduleLine: { 'zh-CN': '经营损益-财务收入',     'zh-TW': '經營損益-財務收入', en: '经营损益-财务收入 (P&L · Financial Income)', ja: '经营损益-财务收入（経営損益・財務収益）', ko: '经营损益-财务收入(경영손익·재무수익)', fr: '经营损益-财务收入 (Résultat · Produits financiers)' } },
  // expense
  cogs:            { label: { 'zh-CN': '营业成本',     'zh-TW': '營業成本' },     scheduleLine: { 'zh-CN': '经营损益-营业成本',     'zh-TW': '經營損益-營業成本', en: '经营损益-营业成本 (P&L · Cost of Sales)', ja: '经营损益-营业成本（経営損益・売上原価）', ko: '经营损益-营业成本(경영손익·매출원가)', fr: '经营损益-营业成本 (Résultat · Coût des ventes)' } },
  selling:         { label: { 'zh-CN': '销售费用',     'zh-TW': '銷售費用' },     scheduleLine: { 'zh-CN': '经营损益-销售费用',     'zh-TW': '經營損益-銷售費用', en: '经营损益-销售费用 (P&L · Selling Expenses)', ja: '经营损益-销售费用（経営損益・販売費）', ko: '经营损益-销售费用(경영손익·판매비)', fr: '经营损益-销售费用 (Résultat · Frais de vente)' } },
  admin:           { label: { 'zh-CN': '管理费用',     'zh-TW': '管理費用' },     scheduleLine: { 'zh-CN': '经营损益-管理费用',     'zh-TW': '經營損益-管理費用', en: '经营损益-管理费用 (P&L · Administrative Expenses)', ja: '经营损益-管理费用（経営損益・一般管理費）', ko: '经营损益-管理费用(경영손익·관리비)', fr: '经营损益-管理费用 (Résultat · Frais administratifs)' } },
  financial:       { label: { 'zh-CN': '财务费用',     'zh-TW': '財務費用' },     scheduleLine: { 'zh-CN': '经营损益-财务费用',     'zh-TW': '經營損益-財務費用', en: '经营损益-财务费用 (P&L · Financial Expenses)', ja: '经营损益-财务费用（経営損益・財務費用）', ko: '经营损益-财务费用(경영손익·재무비용)', fr: '经营损益-财务费用 (Résultat · Charges financières)' } },
  'tax-surcharge': { label: { 'zh-CN': '税金及附加',   'zh-TW': '稅金及附加' },   scheduleLine: { 'zh-CN': '经营损益-税金及附加',   'zh-TW': '經營損益-稅金及附加', en: '经营损益-税金及附加 (P&L · Taxes & Surcharges)', ja: '经营损益-税金及附加（経営損益・租税公課）', ko: '经营损益-税金及附加(경영손익·세금과공과)', fr: '经营损益-税金及附加 (Résultat · Taxes et surtaxes)' } },
  'income-tax':    { label: { 'zh-CN': '所得税',       'zh-TW': '所得稅' },       scheduleLine: { 'zh-CN': '经营损益-所得税',       'zh-TW': '經營損益-所得稅', en: '经营损益-所得税 (P&L · Corporate Income Tax)', ja: '经营损益-所得税（経営損益・法人税等）', ko: '经营损益-所得税(경영손익·법인세)', fr: '经营损益-所得税 (Résultat · Impôt sur les sociétés)' } },
};
