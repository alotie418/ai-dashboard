#!/usr/bin/env node
// Locale matrix validator
//
// Verifies that the entire UI Language × Accounting Locale matrix
// (6 × 6 = 36 combinations) returns:
//   - no raw i18n keys
//   - locale-appropriate currency symbols
//   - tax labels matching the accountingLocale's tax regime
//   - inventory unit labels driven by uiLanguage (not accountingLocale)
//   - AI voice labels driven by uiLanguage
//   - AI prompts that inject both accountingLocale and uiLanguage
//
// Exit code: 0 = all pass, 1 = any failure.

import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = join(__dirname, '..');

const UI_LANGUAGES = ['zh-CN', 'zh-TW', 'en', 'ja', 'ko', 'fr'];
const ACCOUNTING_LOCALES = ['CN', 'US', 'EU', 'JP', 'KR', 'TW'];

// Currency expectations
const EXPECTED_CURRENCY = {
  CN: { code: 'CNY', symbol: '¥' },
  US: { code: 'USD', symbol: '$' },
  EU: { code: 'EUR', symbol: '€' },
  JP: { code: 'JPY', symbol: '¥' },
  KR: { code: 'KRW', symbol: '₩' },
  TW: { code: 'TWD', symbol: 'NT$' },
};

// Tax keys each accountingLocale should provide in taxConcepts
const COMMON_TAX_KEYS = ['plRevenue', 'plCost', 'plNetProfit', 'plTitle', 'tabPlLabel', 'taxSummaryTitle', 'purchaseTotal', 'salesTotal', 'taxDifference', 'invoiceTypeOutput', 'invoiceTypeInput', 'formTaxRate'];
const VAT_FAMILY_KEYS = ['taxTitle', 'inputTax', 'outputTax', 'estimatedTax', 'certifiedInput', 'invoicedOutput'];
const REQUIRED_TAX_KEYS_BY_LOCALE = {
  CN: [...COMMON_TAX_KEYS, ...VAT_FAMILY_KEYS],
  EU: [...COMMON_TAX_KEYS, ...VAT_FAMILY_KEYS],
  JP: [...COMMON_TAX_KEYS, ...VAT_FAMILY_KEYS, 'navSales', 'navPurchase', 'invQueryTitle',
    'pageTitlePurchase', 'uploadTitle', 'uploadSubtitle', 'headerUnitPrice', 'headerAmount',
    'headerInvoiceNo', 'modalTitlePurchase', 'modalSubtitlePurchase', 'newPurchaseButton'],
  KR: [...COMMON_TAX_KEYS, ...VAT_FAMILY_KEYS],
  TW: [...COMMON_TAX_KEYS, ...VAT_FAMILY_KEYS],
  US: [...COMMON_TAX_KEYS, 'grossReceipts', 'totalExpenses', 'netProfit', 'taxTitle', 'kpiGrossIncome', 'kpiQuarterlyTax',
    'profitMargins', 'grossMargin', 'netMargin',
    'socialSecurity', 'medicare', 'additionalMedicare', 'dueLabel',
    'pageTitlePurchase', 'uploadTitle', 'uploadSubtitle',
    'headerUnitPrice', 'headerAmount', 'headerTaxAmount',
    'headerTotalWithTax', 'headerInvoiceNo',
    'modalTitlePurchase', 'modalSubtitlePurchase',
    'pageTitleSales', 'uploadTitleSales', 'uploadSubtitleSales',
    'emptySales', 'modalTitleSales', 'modalSubtitleSales',
    'navSales', 'newSaleButton', 'navPurchase',
    'invQueryTitle', 'invSearchPlaceholder', 'invFilterAll', 'invFilterInput',
    'invFilterOutput', 'invTotalInput', 'invTotalOutput', 'invPendingTax',
    'invTableTitle', 'invTableSubtitle', 'invHeaderDate', 'invHeaderWeight',
    'invHeaderAmount', 'invHeaderInvoiceNo', 'invEmpty',
    'invNoInput', 'invNoOutput',
    'invDateRange', 'invStatusFilter', 'invWeightRange',
    'invStatusAll', 'invStatusVerified', 'invStatusCertified', 'invStatusDeducted',
    'invStatusPendingCert', 'invStatusPendingIssue', 'invStatusIssued',
    'invAdvFilterActive', 'invInputRecordCount', 'invOutputRecordCount',
    'acctReceivableTab', 'acctPayableTab', 'acctTotalReceivable', 'acctTotalPayable',
    'balRecvLabel', 'balPayLabel', 'balTaxPayLabel', 'balPaidInCapital',
    'balRetainedEarnings', 'balLiabEquityHeader', 'balTotalLiabEquity', 'balCashflowAdd',
    'txnAccountHeader',
    'setCreditCodeLabel', 'setLegalPersonLabel', 'setCreditCodePh', 'setAddressPh',
    'setVatRateLabel', 'setRateByState', 'setRateCustom', 'setRateZero',
    'setAutoAuthLabel', 'setAutoAuthDesc', 'setAdminExpenseLabel', 'setPerYear', 'setTaxHint',
    'setDeductibleHeader', 'setDeductiblePctLabel', 'setCatGrossReceipts', 'setCatHomeOffice',
    'setNavAi', 'setAddKey', 'setEditKey', 'setWebGrounding',
    'setCompanyNamePh', 'setLegalPersonPh', 'setIndustryPh',
    'dmSubtitle', 'dmCardSales', 'dmCardPurchases', 'dmNoLegacy', 'dmResultIncome', 'dmResultExpense',
    'dmRollbackConfirm', 'dmRollback', 'dmNote1', 'dmNote2', 'dmNote3', 'dmNote4',
    'notifStockZero', 'notifTaxDeviation', 'notifPriceVolatility', 'notifMonthlyReport'],
};

// Banned cross-regime terminology
// For US, must not use VAT-specific Chinese terms
const BANNED_TERMS_BY_LOCALE = {
  US: {
    description: 'US uses Schedule C / sales tax, not VAT',
    forbidden: [/增值税/, /進項稅(?!額)/, /銷項稅(?!額)/, /\bVAT\b/i],
    // VAT is OK if quoting CN terms, but US labels should NOT contain VAT
    allowedExceptionFields: [],
  },
};

// usSchedule i18n keys (all locales need them; Schedule C is US-specific
// but the user may have accountingLocale=US with any uiLanguage)
const US_SCHEDULE_LINE_KEYS = [
  'line1', 'line2', 'line6', 'line7', 'line8', 'line9', 'line10', 'line11',
  'line13', 'line15', 'line16b', 'line17', 'line18', 'line20', 'line21', 'line22',
  'line23', 'line24a', 'line24b', 'line25', 'line26', 'line27a', 'line30',
  'line28', 'line31',
].map(k => `usSchedule.${k}`);

// i18n keys that MUST exist in every locale file
const REQUIRED_I18N_KEYS = [
  // chat panel
  'chat.title', 'chat.status', 'chat.welcome', 'chat.welcomeDesc', 'chat.placeholder',
  'chat.uploadInvoice', 'chat.financeQuery', 'chat.trendAnalysis', 'chat.marketAnalysis', 'chat.inventoryQuery',
  'chat.thinking', 'chat.resize', 'chat.playVoice', 'chat.liveConnecting', 'chat.liveListening',
  'chat.liveResponding', 'chat.liveHint', 'chat.emptyReply', 'chat.requestError',
  'chat.uploadInvoiceMsg', 'chat.fileReadTimeout', 'chat.fileFormatUnsupported', 'chat.fileReadFailed',
  'chat.notInvoice', 'chat.invoiceExtractResult', 'chat.invoiceRecognizeFailed',
  'chat.quickPromptUploadInvoice', 'chat.quickPromptFinanceQuery', 'chat.quickPromptTrend',
  'chat.quickPromptMarket', 'chat.quickPromptInventory',
  // voice
  'voice.aoede', 'voice.puck', 'voice.charon', 'voice.kore', 'voice.fenrir',
  // ai
  'ai.chatSystemPrompt', 'ai.liveSystemPrompt', 'ai.contextFallback', 'ai.analyzeSystemPrompt',
  // purchases & sales form
  'purchases.title', 'purchases.formCancel', 'purchases.formSubmit',
  'purchases.taxStandard', 'purchases.taxNone', 'purchases.taxJpStandard',
  'purchases.taxEuStandard', 'purchases.taxKrStandard', 'purchases.taxTwStandard',
  'purchases.notInvoiceWarning',
  'sales.title', 'sales.formCancel', 'sales.formSubmitNew', 'sales.formSubmitEdit',
  'sales.notInvoiceWarning',
  // invoice-query advanced-filter "clear all" button (was leaking as raw key
  // invoices.clearAll because it was undefined in every locale file)
  'invoices.advancedFilter', 'invoices.clearAll',
  // tableHeaders
  'tableHeaders.date', 'tableHeaders.taxAmount', 'tableHeaders.totalTax',
  'tableHeaders.totalWithTax', 'tableHeaders.amountWithoutTax',
  // finance balance sheet
  'finance.balanceAssets', 'finance.balanceLiabilities', 'finance.balanceCurrentAssets',
  'finance.balanceNonCurrentAssets', 'finance.balanceCurrentLiabilities',
  'finance.balanceEquity', 'finance.balanceTotalAssets',
  // finance tabs
  'finance.tabBalance', 'finance.tabCashflow', 'finance.tabPl',
  // cashflow empty state
  'finance.cashflowTitle', 'finance.cashflowDesc', 'finance.cashflowSync',
  // Data Analysis page — formerly hardcoded English / missing keys
  'analysis.aiDashboard', 'analysis.avgYoy', 'analysis.avgMom',
  'analysis.subtitleRevenueCost', 'analysis.subtitleYoyMom',
  'analysis.subtitleLogistics', 'analysis.subtitleEfficiency',
  'analysis.matrixBadgeSteady', 'analysis.matrixBadgeBalance',
  'analysis.chartTons', 'analysis.chartAvgRevenue', 'analysis.chartMonthlyData',
  'analysis.waitingData', 'analysis.dimSwitch', 'analysis.realtimeProcessing',
  'analysis.progress', 'analysis.peakMonthSub',
  'analysis.severityLow', 'analysis.severityMid', 'analysis.severityHigh',
  'analysis.corrStrong', 'analysis.corrModerate', 'analysis.corrWeak',
  // US Tax Tools — required in all 6 locales (page may render under US locale + any uiLanguage)
  'usTax.title', 'usTax.notApplicable', 'usTax.mileage', 'usTax.homeOffice',
  'usTax.totalTrips', 'usTax.totalMiles', 'usTax.deduction', 'usTax.addTrip',
  'usTax.newTrip', 'usTax.miles', 'usTax.from', 'usTax.to', 'usTax.purpose',
  'usTax.roundTrip', 'usTax.route', 'usTax.deductionShort', 'usTax.noTrips',
  'usTax.fromPlaceholder', 'usTax.toPlaceholder', 'usTax.purposePlaceholder', 'usTax.milesPlaceholder',
  'usTax.mileageNote', 'usTax.homeOfficeDeduction', 'usTax.scheduleC30',
  'usTax.simplified', 'usTax.actual', 'usTax.simplifiedTitle', 'usTax.officeSqft',
  'usTax.ratePerSqft', 'usTax.simplifiedCalc', 'usTax.actualTitle',
  'usTax.totalHomeSqft', 'usTax.annualRent', 'usTax.annualUtilities',
  'usTax.annualInsurance', 'usTax.annualDepreciation', 'usTax.actualCalc',
  'usTax.homeOfficeNote',
  // US Schedule C line descriptions (any uiLanguage may render US locale)
  ...US_SCHEDULE_LINE_KEYS,
];

// Forbid English-only labels in non-English locales for these specific keys
const NO_ENGLISH_FALLBACK_KEYS = {
  'zh-CN': [
    'finance.balanceAssets',         // must be Chinese, not "Assets"
    'finance.balanceLiabilities',
    'finance.balanceCurrentAssets',
    'finance.balanceEquity',
    'finance.balanceTotalAssets',
    'finance.balanceCapital',
    'finance.balanceRetained',
  ],
  'zh-TW': [
    'finance.balanceAssets',
    'finance.balanceLiabilities',
    'finance.balanceCurrentAssets',
    'finance.balanceEquity',
    'finance.balanceTotalAssets',
    'finance.balanceCapital',
    'finance.balanceRetained',
  ],
  ja: [
    'finance.balanceAssets', 'finance.balanceLiabilities', 'finance.balanceCurrentAssets',
    'finance.balanceEquity', 'finance.balanceTotalAssets',
  ],
  ko: [
    'finance.balanceAssets', 'finance.balanceLiabilities', 'finance.balanceCurrentAssets',
    'finance.balanceEquity', 'finance.balanceTotalAssets',
  ],
  // fr/en use Latin chars; "English-only" check doesn't apply
};

// zh-TW must not contain simplified-only characters
// (a partial list of characters that exist only in simplified Chinese)
const SIMPLIFIED_ONLY_CHARS = /[国对资产负债权应账户单业务时备纸压务师录运战让会议讲读这当时间体语义价当为标题]/;

const RESULTS = { pass: [], fail: [] };
function pass(name) { RESULTS.pass.push(name); }
function fail(name, reasons) { RESULTS.fail.push({ name, reasons: Array.isArray(reasons) ? reasons : [reasons] }); }

// ─── Load data ───
async function loadLocaleJson(lang) {
  const p = join(ROOT, 'i18n/locales', `${lang}.json`);
  const txt = await readFile(p, 'utf8');
  return JSON.parse(txt);
}

function get(obj, path) {
  return path.split('.').reduce((o, k) => (o && o[k] !== undefined) ? o[k] : undefined, obj);
}

async function main() {
  const config = await import(join(ROOT, 'components/accountingLocaleConfig.ts'));
  const accProfiles = await import(join(ROOT, 'components/accountingProfiles.ts'));
  const helpers = await import(join(ROOT, 'components/accountingHelpers.ts'));
  const invoiceProfiles = await import(join(ROOT, 'electron/ai/invoiceProfiles.js'));
  const promptBuilder = await import(join(ROOT, 'electron/ai/ocrPromptBuilder.js'));

  const locales = {};
  for (const lang of UI_LANGUAGES) {
    locales[lang] = await loadLocaleJson(lang);
  }

  // ────────────────────────────────────────────────
  // PART A: accountingLocaleConfig structural checks
  // ────────────────────────────────────────────────
  for (const accId of ACCOUNTING_LOCALES) {
    const cfg = config.getAccountingLocale(accId);
    const reasons = [];

    if (cfg.id !== accId) reasons.push(`id mismatch: got ${cfg.id}, expected ${accId}`);
    if (cfg.defaultCurrency !== EXPECTED_CURRENCY[accId].code) {
      reasons.push(`defaultCurrency ${cfg.defaultCurrency} != expected ${EXPECTED_CURRENCY[accId].code}`);
    }
    if (cfg.currencySymbol !== EXPECTED_CURRENCY[accId].symbol) {
      reasons.push(`currencySymbol ${cfg.currencySymbol} != expected ${EXPECTED_CURRENCY[accId].symbol}`);
    }
    // Required tax keys
    const missing = REQUIRED_TAX_KEYS_BY_LOCALE[accId].filter(k => !cfg.taxConcepts[k]);
    if (missing.length) reasons.push(`missing taxConcepts keys: ${missing.join(', ')}`);

    // Each taxConcept must have all 6 UI languages
    for (const [key, labels] of Object.entries(cfg.taxConcepts)) {
      if (typeof labels !== 'object' || labels === null) {
        reasons.push(`taxConcepts.${key} is not an object`);
        continue;
      }
      const missingLangs = UI_LANGUAGES.filter(l => !labels[l]);
      if (missingLangs.length) {
        reasons.push(`taxConcepts.${key} missing langs: ${missingLangs.join(', ')}`);
      }
    }

    if (reasons.length) fail(`config:${accId}`, reasons); else pass(`config:${accId}`);
  }

  // ────────────────────────────────────────────────
  // PART A2: No cross-script leakage in taxConcepts
  //   - non-ko fields must not contain Hangul (가-힯)
  //   - non-ja fields must not contain hiragana (ぁ-ゟ) or katakana (゠-ヿ)
  //   - non-zh-TW Chinese fields with simplified-only chars are caught in zh-TW check below
  // ────────────────────────────────────────────────
  const HANGUL = /[가-힯]/;
  const HIRAGANA = /[ぁ-ゟ]/;
  const KATAKANA = /[゠-ヿ]/;
  // Japanese-only kanji that are NOT used in modern Chinese (simplified or traditional)
  // - 売 is Japanese for 賣/卖
  // - 働 (Japanese-coined kanji), 込 (Japanese-only), 畳, 駅, 嬢, 処 (Chinese uses 處/处)
  // - 価 is Japanese for 價/价
  // Note: 圓 圖 團 縣 are ALSO valid traditional Chinese — don't include.
  // Note: 仕 alone exists in Chinese (仕途); detection of compounds like 仕入 needs separate logic.
  const JA_ONLY_KANJI = /[売働込畳駅嬢処価]/;
  for (const accId of ACCOUNTING_LOCALES) {
    const cfg = config.getAccountingLocale(accId);
    const reasons = [];
    for (const [key, labels] of Object.entries(cfg.taxConcepts)) {
      for (const lang of UI_LANGUAGES) {
        const val = labels[lang];
        if (typeof val !== 'string') continue;
        if (lang !== 'ko' && HANGUL.test(val)) {
          reasons.push(`${key}[${lang}] contains Hangul: "${val}"`);
        }
        if (lang !== 'ja' && (HIRAGANA.test(val) || KATAKANA.test(val) || JA_ONLY_KANJI.test(val))) {
          reasons.push(`${key}[${lang}] contains Japanese-only script: "${val}"`);
        }
      }
    }
    if (reasons.length) fail(`crossScript:${accId}`, reasons); else pass(`crossScript:${accId}`);
  }

  // ────────────────────────────────────────────────
  // PART B: getTaxLabel matrix (6 × 6)
  // ────────────────────────────────────────────────
  for (const accId of ACCOUNTING_LOCALES) {
    for (const uiLang of UI_LANGUAGES) {
      const cfg = config.getAccountingLocale(accId);
      const reasons = [];

      for (const key of Object.keys(cfg.taxConcepts)) {
        const label = helpers.getTaxLabel(accId, uiLang, key);
        if (label === key) {
          reasons.push(`getTaxLabel returned raw key for "${key}"`);
        }
        if (!label || label.length === 0) {
          reasons.push(`getTaxLabel empty for "${key}"`);
        }
      }

      // US specific: tax labels should not contain China VAT terms
      if (accId === 'US') {
        for (const key of Object.keys(cfg.taxConcepts)) {
          const label = helpers.getTaxLabel(accId, uiLang, key);
          for (const pattern of BANNED_TERMS_BY_LOCALE.US.forbidden) {
            if (pattern.test(label)) {
              reasons.push(`US tax label "${key}" contains forbidden ${pattern}: "${label}"`);
            }
          }
        }
        // "Schedule C" is the official IRS form name and must be exactly
        // capitalized — never "schedule C", "schedule c", "SCHEDULE C", etc.
        // Applies to any taxConcept value that mentions Schedule C.
        for (const key of Object.keys(cfg.taxConcepts)) {
          const label = helpers.getTaxLabel(accId, uiLang, key);
          if (/schedule\s+c|SCHEDULE\s+C/i.test(label) && !/Schedule C/.test(label)) {
            reasons.push(`US ${key}[${uiLang}] uses non-canonical Schedule C capitalization: "${label}"`);
          }
        }
        // US purchase-page labels must not import China-VAT terminology
        // (进项 / 進項 / 电子发票 / 電子發票 / 销项 / 銷項 / 增值税 / 增值稅).
        // These are CN-specific and inappropriate for US Schedule C context.
        const US_FORBIDDEN_CN_TERMS = [/进项/, /進項/, /销项/, /銷項/, /增值税/, /增值稅/, /电子发票/, /電子發票/];
        for (const key of ['pageTitlePurchase', 'uploadTitle', 'uploadSubtitle',
                           'headerUnitPrice', 'headerAmount', 'headerTaxAmount',
                           'headerTotalWithTax', 'headerInvoiceNo',
                           'modalTitlePurchase', 'modalSubtitlePurchase',
                           'pageTitleSales', 'uploadTitleSales', 'uploadSubtitleSales',
                           'emptySales', 'modalTitleSales', 'modalSubtitleSales',
                           'navSales', 'newSaleButton', 'navPurchase',
                           'invQueryTitle', 'invSearchPlaceholder', 'invFilterAll', 'invFilterInput',
                           'invFilterOutput', 'invTotalInput', 'invTotalOutput', 'invPendingTax',
                           'invTableTitle', 'invTableSubtitle', 'invHeaderDate', 'invHeaderWeight',
                           'invHeaderAmount', 'invHeaderInvoiceNo', 'invEmpty',
                           'invNoInput', 'invNoOutput',
                           'invDateRange', 'invStatusFilter', 'invWeightRange',
                           'invStatusAll', 'invStatusVerified', 'invStatusCertified', 'invStatusDeducted',
                           'invStatusPendingCert', 'invStatusPendingIssue', 'invStatusIssued',
                           'invAdvFilterActive', 'invInputRecordCount', 'invOutputRecordCount',
                           'acctReceivableTab', 'acctPayableTab', 'acctTotalReceivable', 'acctTotalPayable',
                           'balRecvLabel', 'balPayLabel', 'balTaxPayLabel', 'balPaidInCapital',
                           'balRetainedEarnings', 'balLiabEquityHeader', 'balTotalLiabEquity', 'balCashflowAdd',
                           'txnAccountHeader',
                           'setCreditCodeLabel', 'setLegalPersonLabel', 'setVatRateLabel', 'setRateByState',
                           'setRateCustom', 'setRateZero', 'setAutoAuthLabel', 'setAutoAuthDesc',
                           'setAdminExpenseLabel', 'setPerYear', 'setTaxHint', 'setDeductibleHeader',
                           'setDeductiblePctLabel', 'setCatGrossReceipts', 'setCatHomeOffice',
                           'setNavAi', 'setAddKey', 'setEditKey', 'setWebGrounding',
                           'setCompanyNamePh', 'setLegalPersonPh', 'setIndustryPh',
                           'notifStockZero', 'notifTaxDeviation', 'notifPriceVolatility', 'notifMonthlyReport']) {
          const label = helpers.getTaxLabel(accId, uiLang, key);
          for (const pattern of US_FORBIDDEN_CN_TERMS) {
            if (pattern.test(label)) {
              reasons.push(`US ${key}[${uiLang}] uses China-VAT term ${pattern}: "${label}"`);
            }
          }
        }
        // US advanced-filter labels (票据查询 advanced panel) must not import
        // CN-VAT-specific wording: invDateRange must not say 开票/開票
        // (invoice-issuance date), invStatusFilter must not say 发票/發票
        // (invoice status), invWeightRange must not say 重量/吨/噸 (US ledger
        // is document-count based, not commodity-weight based).
        {
          const dr = helpers.getTaxLabel(accId, uiLang, 'invDateRange');
          if (/开票|開票/.test(dr)) reasons.push(`US invDateRange[${uiLang}] uses 开票 (CN invoice-issuance wording): "${dr}"`);
          const sf = helpers.getTaxLabel(accId, uiLang, 'invStatusFilter');
          if (/发票|發票/.test(sf)) reasons.push(`US invStatusFilter[${uiLang}] uses 发票 (CN VAT-invoice wording): "${sf}"`);
          const wr = helpers.getTaxLabel(accId, uiLang, 'invWeightRange');
          if (/重量|吨|噸/.test(wr)) reasons.push(`US invWeightRange[${uiLang}] hardcodes weight/吨: "${wr}"`);
        }
        // US document-status filter options must NOT use CN-VAT
        // 认证/認證/抵扣 (certification/deduction) wording, and must never be a
        // raw key (this is the dropdown that was leaking invoices.status*).
        for (const key of ['invStatusAll', 'invStatusVerified', 'invStatusCertified', 'invStatusDeducted',
                           'invStatusPendingCert', 'invStatusPendingIssue', 'invStatusIssued']) {
          const v = helpers.getTaxLabel(accId, uiLang, key);
          if (v === key) reasons.push(`US ${key}[${uiLang}] is a raw key (status dropdown leak): "${v}"`);
          if (/认证|認證|抵扣/.test(v)) reasons.push(`US ${key}[${uiLang}] uses CN-VAT 认证/抵扣 wording: "${v}"`);
        }
        // US interpolated count templates (stat-card subtitles + active-filter
        // line). Must NOT be a raw key, must carry the literal {count} token (so
        // the count actually renders), must not leave a stray token after
        // substitution, and must avoid CN-VAT wording (认证/抵扣/发票/开票 — these
        // count strings are never about VAT invoices).
        for (const key of ['invAdvFilterActive', 'invInputRecordCount', 'invOutputRecordCount']) {
          const v = helpers.getTaxLabel(accId, uiLang, key);
          if (v === key) reasons.push(`US ${key}[${uiLang}] is a raw key (interpolated label leak): "${v}"`);
          if (!v.includes('{count}')) reasons.push(`US ${key}[${uiLang}] missing {count} token: "${v}"`);
          if (/认证|認證|抵扣|发票|發票|开票|開票/.test(v)) reasons.push(`US ${key}[${uiLang}] uses CN-VAT wording: "${v}"`);
          // simulate render: substituting {count} must leave no leftover brace token
          const rendered = v.replace(/\{count\}/g, '7');
          if (/\{count\}|\{\{|\}\}/.test(rendered)) reasons.push(`US ${key}[${uiLang}] has malformed interpolation token: "${v}"`);
        }
        // US settings page: keep CN tax/company wording out of the re-flagged fields.
        {
          const hint = helpers.getTaxLabel(accId, uiLang, 'setTaxHint');
          if (/增值税|增值稅|税金及附加|稅金及附加|所得税|所得稅/.test(hint)) reasons.push(`US setTaxHint[${uiLang}] uses CN-tax wording: "${hint}"`);
          const auto = helpers.getTaxLabel(accId, uiLang, 'setAutoAuthLabel') + ' / ' + helpers.getTaxLabel(accId, uiLang, 'setAutoAuthDesc');
          if (/认证|認證|进项|進項|税务系统|稅務系統/.test(auto)) reasons.push(`US setAutoAuth[${uiLang}] uses CN-VAT wording: "${auto}"`);
          const credit = helpers.getTaxLabel(accId, uiLang, 'setCreditCodeLabel') + ' / ' + helpers.getTaxLabel(accId, uiLang, 'setCreditCodePh');
          if (/统一社会信用代码|統一社會信用代碼|91110000/.test(credit)) reasons.push(`US creditCode[${uiLang}] uses CN business-code wording: "${credit}"`);
          const vat = helpers.getTaxLabel(accId, uiLang, 'setVatRateLabel');
          if (/增值税|增值稅/.test(vat)) reasons.push(`US setVatRateLabel[${uiLang}] still says 增值税: "${vat}"`);
          // US sales-page inventory banner: quantity-stat wording, not the CN
          // 总采购/总销售/库存 commodity-inventory口径 (and never a raw key).
          for (const k of ['salesBannerPurchaseQty', 'salesBannerSalesQty']) {
            const v = helpers.getTaxLabel(accId, uiLang, k);
            if (v === k) reasons.push(`US ${k}[${uiLang}] is a raw key`);
            if (/总采购|總採購|总销售|總銷售|库存|庫存/.test(v)) reasons.push(`US ${k}[${uiLang}] uses CN inventory wording: "${v}"`);
          }
        }
        // US data-migration page: no internal table/field/JSON names should leak
        // into the Chinese UI; the rollback strings must keep the {count} token.
        if (uiLang === 'zh-CN' || uiLang === 'zh-TW') {
          const INTERNAL = /sales|purchases|transaction|source_meta|legacy_migrations|cogs|\bincome\b|\bexpense\b/i;
          for (const key of ['dmSubtitle', 'dmCardSales', 'dmCardPurchases', 'dmNoLegacy', 'dmResultIncome',
                             'dmResultExpense', 'dmRollbackConfirm', 'dmRollback', 'dmNote1', 'dmNote2', 'dmNote3', 'dmNote4']) {
            const v = helpers.getTaxLabel(accId, uiLang, key);
            if (INTERNAL.test(v)) reasons.push(`US ${key}[${uiLang}] exposes internal term: "${v}"`);
          }
        }
        for (const key of ['dmRollbackConfirm', 'dmRollback']) {
          const v = helpers.getTaxLabel(accId, uiLang, key);
          if (!v.includes('{count}')) reasons.push(`US ${key}[${uiLang}] missing {count} token: "${v}"`);
        }
        // US notifications: tax alert uses 税款 (concrete tax due), not the macro
        // 税收 wording; stock alert is threshold-based, not zero-based.
        if (uiLang === 'zh-CN' || uiLang === 'zh-TW') {
          const td = helpers.getTaxLabel(accId, uiLang, 'notifTaxDeviation');
          if (/税收|稅收/.test(td)) reasons.push(`US notifTaxDeviation[${uiLang}] uses macro 税收 (should be 税款): "${td}"`);
          const sz = helpers.getTaxLabel(accId, uiLang, 'notifStockZero');
          if (/跌至零值|跌至零|零值/.test(sz)) reasons.push(`US notifStockZero[${uiLang}] still says 零值 (should be 阈值): "${sz}"`);
        }
        // Exact-string lock-in for the search placeholder + "all documents" tab.
        // These regressed by silently losing a trailing character (码/据 →
        // "搜索票据号..." / "全部票"); pin the full expected strings so any future
        // truncation or rewording fails here. (zh-CN / zh-TW only — these are the
        // CJK display strings the US localization task fixed.)
        {
          const EXPECT = {
            'zh-CN': {
              invSearchPlaceholder: '搜索票据号码或往来单位...', invFilterAll: '全部票据',
              invStatusAll: '全部状态', invStatusVerified: '已核验', invStatusCertified: '已记录',
              invStatusDeducted: '已处理', invStatusPendingCert: '待处理',
              invStatusPendingIssue: '待票据', invStatusIssued: '已开票',
              invAdvFilterActive: '已启用筛选，找到 {count} 条票据记录',
              invInputRecordCount: '{count} 条采购/费用记录',
              invOutputRecordCount: '{count} 条销售/收入记录',
              acctReceivableTab: '客户应收', acctPayableTab: '供应商应付',
              acctTotalReceivable: '客户应收总额', acctTotalPayable: '供应商应付总额',
              balRecvLabel: '客户应收', balPayLabel: '供应商应付', balTaxPayLabel: '应付税款',
              balPaidInCapital: '所有者投入', balRetainedEarnings: '留存收益',
              balLiabEquityHeader: '负债和所有者权益', balTotalLiabEquity: '负债和所有者权益总计',
              balCashflowAdd: '添加收支记录',
              kpiGrossIncome: '总收入',
              txnAccountHeader: '账户',
              setCreditCodeLabel: 'EIN / 税号', setLegalPersonLabel: '负责人',
              setVatRateLabel: 'Sales Tax 税率', setRateByState: '按州设置', setRateCustom: '自定义税率', setRateZero: '0%',
              setAutoAuthLabel: '票据自动处理', setAdminExpenseLabel: '年度运营费用', setPerYear: '美元/年',
              setDeductibleHeader: '可扣除', setCatGrossReceipts: '总收入或销售额', setCatHomeOffice: '家庭办公室',
              setNavAi: 'AI 服务商（BYOK）', setAddKey: '添加密钥', setEditKey: '修改密钥', setWebGrounding: '支持联网检索',
              setCompanyNamePh: '例如：ABC Trading LLC', setLegalPersonPh: '例如：John Smith', setIndustryPh: '例如：Consulting / Retail / Services',
              dmCardSales: '销售记录（旧版）→ 收入记录', dmCardPurchases: '采购记录（旧版）→ 费用记录',
              dmNoLegacy: '没有需要迁移的旧版数据。',
              dmNote1: '销售记录将迁移为收入记录，采购记录将迁移为费用记录。',
              dmNote2: '旧表数据会保留，可随时回滚。',
              dmNote3: '迁移记录会保存原始记录快照，不会丢失。',
              notifStockZero: '库存低于阈值提醒', notifTaxDeviation: '税款偏差超过 15% 预警',
              notifPriceVolatility: '异常价格波动提醒', notifMonthlyReport: '月度财务报告推送',
            },
            'zh-TW': {
              invSearchPlaceholder: '搜尋票據號碼或往來單位...', invFilterAll: '全部票據',
              invStatusAll: '全部狀態', invStatusVerified: '已核驗', invStatusCertified: '已記錄',
              invStatusDeducted: '已處理', invStatusPendingCert: '待處理',
              invStatusPendingIssue: '待票據', invStatusIssued: '已開票',
              invAdvFilterActive: '已啟用篩選，找到 {count} 筆票據記錄',
              invInputRecordCount: '{count} 筆採購/費用記錄',
              invOutputRecordCount: '{count} 筆銷售/收入記錄',
              acctReceivableTab: '客戶應收', acctPayableTab: '供應商應付',
              acctTotalReceivable: '客戶應收總額', acctTotalPayable: '供應商應付總額',
              balRecvLabel: '客戶應收', balPayLabel: '供應商應付', balTaxPayLabel: '應付稅款',
              balPaidInCapital: '所有者投入', balRetainedEarnings: '留存收益',
              balLiabEquityHeader: '負債和所有者權益', balTotalLiabEquity: '負債和所有者權益總計',
              balCashflowAdd: '新增收支記錄',
              kpiGrossIncome: '總收入',
              txnAccountHeader: '帳戶',
              setCreditCodeLabel: 'EIN / 稅號', setLegalPersonLabel: '負責人',
              setVatRateLabel: 'Sales Tax 稅率', setRateByState: '按州設置', setRateCustom: '自訂稅率', setRateZero: '0%',
              setAutoAuthLabel: '票據自動處理', setAdminExpenseLabel: '年度營運費用', setPerYear: '美元/年',
              setDeductibleHeader: '可扣除', setCatGrossReceipts: '總收入或銷售額', setCatHomeOffice: '家庭辦公室',
              setNavAi: 'AI 服務商（BYOK）', setAddKey: '新增密鑰', setEditKey: '修改密鑰', setWebGrounding: '支援聯網檢索',
              setCompanyNamePh: '例如：ABC Trading LLC', setLegalPersonPh: '例如：John Smith', setIndustryPh: '例如：Consulting / Retail / Services',
              dmCardSales: '銷售記錄（舊版）→ 收入記錄', dmCardPurchases: '採購記錄（舊版）→ 費用記錄',
              dmNoLegacy: '沒有需要遷移的舊版資料。',
              dmNote1: '銷售記錄將遷移為收入記錄，採購記錄將遷移為費用記錄。',
              dmNote2: '舊表資料會保留，可隨時回復。',
              dmNote3: '遷移記錄會保存原始記錄快照，不會遺失。',
              notifStockZero: '庫存低於閾值提醒', notifTaxDeviation: '稅款偏差超過 15% 預警',
              notifPriceVolatility: '異常價格波動提醒', notifMonthlyReport: '月度財務報告推送',
            },
          };
          if (EXPECT[uiLang]) {
            for (const [key, want] of Object.entries(EXPECT[uiLang])) {
              const got = helpers.getTaxLabel(accId, uiLang, key);
              if (got !== want) reasons.push(`US ${key}[${uiLang}] should be exactly "${want}", got "${got}"`);
            }
          }
        }
        // US formTaxRate / modalTitlePurchase under CJK UIs must include
        // native-script content (cannot be bare "SALES TAX 税率"-style with
        // no Chinese explanation). Require at least one CJK Han char.
        if (['zh-CN', 'zh-TW', 'ja', 'ko'].includes(uiLang)) {
          for (const key of ['formTaxRate', 'modalTitlePurchase', 'modalSubtitlePurchase']) {
            const v = helpers.getTaxLabel(accId, uiLang, key);
            if (!/[一-鿿가-힯]/.test(v)) {
              reasons.push(`US ${key}[${uiLang}] should include native-language explanation: "${v}"`);
            }
          }
          // formTaxRate zh-CN/zh-TW must specifically include "销售税" / "銷售稅"
          // when "Sales Tax" appears, so the term is unambiguous.
          const rateLabel = helpers.getTaxLabel(accId, uiLang, 'formTaxRate');
          if (/Sales Tax/i.test(rateLabel)) {
            if (uiLang === 'zh-CN' && !/销售税/.test(rateLabel)) {
              reasons.push(`US formTaxRate zh-CN should include 销售税 explanation: "${rateLabel}"`);
            }
            if (uiLang === 'zh-TW' && !/銷售稅/.test(rateLabel)) {
              reasons.push(`US formTaxRate zh-TW should include 銷售稅 explanation: "${rateLabel}"`);
            }
            // Bare "SALES TAX" all-caps is not allowed in label data (CSS
            // uppercasing the label is handled separately by removing the
            // uppercase utility from that specific label).
            if (/^SALES TAX/.test(rateLabel)) {
              reasons.push(`US formTaxRate[${uiLang}] should use mixed-case "Sales Tax", not "SALES TAX": "${rateLabel}"`);
            }
          }
          // modalTitlePurchase zh-CN/zh-TW must use "与" / "與" instead of
          // slash "/" between 采购 and 费用 for natural Chinese reading.
          const modalTitle = helpers.getTaxLabel(accId, uiLang, 'modalTitlePurchase');
          if (uiLang === 'zh-CN' && /采购\/费用|采购\s*\/\s*费用/.test(modalTitle)) {
            reasons.push(`US modalTitlePurchase zh-CN should say 采购与费用, not slash form: "${modalTitle}"`);
          }
          if (uiLang === 'zh-TW' && /採購\/費用|採購\s*\/\s*費用/.test(modalTitle)) {
            reasons.push(`US modalTitlePurchase zh-TW should say 採購與費用, not slash form: "${modalTitle}"`);
          }
        }
        // US dashboard cards: profitMargins / grossMargin / netMargin must
        // contain native script when uiLanguage is CJK (not be plain English).
        if (['zh-CN', 'zh-TW', 'ja', 'ko'].includes(uiLang)) {
          for (const key of ['profitMargins', 'grossMargin', 'netMargin']) {
            const v = helpers.getTaxLabel(accId, uiLang, key);
            if (/^[A-Za-z\s&]+$/.test(v)) {
              reasons.push(`US ${key} in ${uiLang} is plain English: "${v}"`);
            }
          }
          // socialSecurity / medicare / additionalMedicare must include native
          // script after the official English name (parenthetical explanation).
          for (const key of ['socialSecurity', 'medicare', 'additionalMedicare']) {
            const v = helpers.getTaxLabel(accId, uiLang, key);
            // Require non-Latin char (kanji/hangul) somewhere in the label
            if (!/[　-鿿가-힯]/.test(v)) {
              reasons.push(`US ${key} in ${uiLang} should include native-language explanation: "${v}"`);
            }
          }
        }
      }

      if (reasons.length) fail(`taxLabels:${accId}+${uiLang}`, reasons); else pass(`taxLabels:${accId}+${uiLang}`);
    }
  }

  // ────────────────────────────────────────────────
  // PART C: formatMoney returns correct currency symbol
  // ────────────────────────────────────────────────
  for (const accId of ACCOUNTING_LOCALES) {
    for (const uiLang of UI_LANGUAGES) {
      const formatted = helpers.formatMoney(1234.56, accId, uiLang);
      const expected = EXPECTED_CURRENCY[accId].symbol;
      if (!formatted.includes(expected)) {
        fail(`formatMoney:${accId}+${uiLang}`, `expected symbol "${expected}" in "${formatted}"`);
      } else {
        pass(`formatMoney:${accId}+${uiLang}`);
      }
      // Also verify zero values render with currency symbol (regression guard
      // for finance summary cards which often show 0 before data loads)
      const zeroFmt = helpers.formatMoney(0, accId, uiLang);
      if (!zeroFmt.includes(expected)) {
        fail(`formatMoney(0):${accId}+${uiLang}`, `zero-value formatting missing symbol "${expected}": "${zeroFmt}"`);
      } else {
        pass(`formatMoney(0):${accId}+${uiLang}`);
      }
    }
  }

  // ────────────────────────────────────────────────
  // PART D: getInventoryUnitLabel driven by uiLanguage only
  // ────────────────────────────────────────────────
  const unitExpectations = {
    'zh-CN': { unit: '单位', ton: '吨', bag: '袋' },
    'zh-TW': { unit: '單位', ton: '噸', bag: '袋' },
    en: { unit: 'units', ton: 'tons', bag: 'bags' },
    ja: { unit: '単位', ton: 'トン', bag: '袋' },
    ko: { unit: '단위', ton: '톤', bag: '포대' },
    fr: { unit: 'unités', ton: 'tonnes', bag: 'sacs' },
  };
  for (const uiLang of UI_LANGUAGES) {
    const reasons = [];
    for (const [unitKey, expected] of Object.entries(unitExpectations[uiLang])) {
      const got = helpers.getInventoryUnitLabel(unitKey, uiLang);
      if (got !== expected) reasons.push(`unit ${unitKey} expected "${expected}", got "${got}"`);
    }
    // null/undefined should fall back to 'unit'
    const nullFallback = helpers.getInventoryUnitLabel(null, uiLang);
    if (nullFallback !== unitExpectations[uiLang].unit) {
      reasons.push(`null fallback expected "${unitExpectations[uiLang].unit}", got "${nullFallback}"`);
    }
    if (reasons.length) fail(`inventoryUnit:${uiLang}`, reasons); else pass(`inventoryUnit:${uiLang}`);
  }

  // ────────────────────────────────────────────────
  // PART E0: AI briefing prompt construction
  //   Verifies the wire-up in App.tsx — performAnalysis() must construct
  //   systemPrompt as `${t('ai.analyzeSystemPrompt')}\n\n${buildAIFinanceContext(...)}`.
  //   Static check: ensure App.tsx invokes buildAIFinanceContext() in the
  //   analysis path so the AI briefing receives accountingLocale + uiLanguage.
  // ────────────────────────────────────────────────
  {
    const { readFile: rf } = await import('node:fs/promises');
    const appTsx = await rf(join(ROOT, 'App.tsx'), 'utf8');
    const reasons = [];
    // performAnalysis must build systemPrompt via buildAIFinanceContext
    const m = appTsx.match(/performAnalysis\s*=\s*useCallback[\s\S]{0,2000}?fetchAIAnalysis/);
    if (!m) {
      reasons.push('Could not locate performAnalysis → fetchAIAnalysis block in App.tsx');
    } else {
      const block = m[0];
      if (!/buildAIFinanceContext\s*\(/.test(block)) {
        reasons.push('performAnalysis does not call buildAIFinanceContext; AI briefing missing accountingLocale context');
      }
      if (!/i18n\.language|uiLanguage/.test(block)) {
        reasons.push('performAnalysis does not include uiLanguage in the AI briefing prompt');
      }
    }
    if (reasons.length) fail(`aiBriefingWiring`, reasons); else pass(`aiBriefingWiring`);
  }

  // ────────────────────────────────────────────────
  // PART E: buildAIFinanceContext includes both accountingLocale + uiLanguage
  // ────────────────────────────────────────────────
  for (const accId of ACCOUNTING_LOCALES) {
    for (const uiLang of UI_LANGUAGES) {
      const ctx = helpers.buildAIFinanceContext(accId, uiLang);
      const reasons = [];
      if (!ctx || ctx.length === 0) reasons.push('empty context');
      // Must contain a language instruction (sample words)
      const langMarkers = {
        'zh-CN': /简体中文|请使用/,
        'zh-TW': /繁體中文|請使用/,
        en: /English|respond in english/i,
        ja: /日本語/,
        ko: /한국어/,
        fr: /français/i,
      };
      if (!langMarkers[uiLang].test(ctx)) {
        reasons.push(`missing uiLanguage instruction for ${uiLang}`);
      }
      // Must mention accounting regime
      const accMarkers = {
        CN: /VAT|Chinese|增值税/i,
        US: /Schedule C|sole proprietor|US/,
        EU: /VAT|EU/,
        JP: /Consumption Tax|消費税|Japan/i,
        KR: /Korean VAT|부가가치세/,
        TW: /Business Tax|營業稅|Taiwan/,
      };
      if (!accMarkers[accId].test(ctx)) {
        reasons.push(`missing accountingLocale context for ${accId}`);
      }
      if (reasons.length) fail(`aiContext:${accId}+${uiLang}`, reasons); else pass(`aiContext:${accId}+${uiLang}`);
    }
  }

  // ────────────────────────────────────────────────
  // PART F: OCR prompt builder includes both accountingLocale + uiLanguage
  // ────────────────────────────────────────────────
  for (const accId of ACCOUNTING_LOCALES) {
    for (const uiLang of UI_LANGUAGES) {
      const prompt = promptBuilder.buildPrompt(accId, uiLang);
      const reasons = [];
      // Must contain locale tax regime context (promptContext, not taxRegime literal)
      const profile = invoiceProfiles.getProfile(accId);
      // Spot-check: the first line of promptContext should appear
      const firstLine = profile.promptContext.split('\n')[0].trim();
      if (!prompt.includes(firstLine)) {
        reasons.push(`OCR prompt missing taxRegime context line "${firstLine}"`);
      }
      // Must contain default currency
      if (!prompt.includes(profile.defaultCurrency)) {
        reasons.push(`OCR prompt missing currency "${profile.defaultCurrency}"`);
      }
      // Must include isInvoiceLike for non-invoice protection
      if (!prompt.includes('isInvoiceLike')) {
        reasons.push('OCR prompt missing non-invoice protection (isInvoiceLike)');
      }
      // Must include uiLanguage instruction
      const langMarkers = {
        'zh-CN': /简体中文/,
        'zh-TW': /繁體中文/,
        en: /English/,
        ja: /日本語/,
        ko: /한국어/,
        fr: /français/i,
      };
      if (!langMarkers[uiLang].test(prompt)) {
        reasons.push(`OCR prompt missing uiLanguage instruction for ${uiLang}`);
      }
      if (reasons.length) fail(`ocrPrompt:${accId}+${uiLang}`, reasons); else pass(`ocrPrompt:${accId}+${uiLang}`);
    }
  }

  // ────────────────────────────────────────────────
  // PART F2: Finance report — tab label + tax module visibility per locale
  // ────────────────────────────────────────────────
  for (const accId of ACCOUNTING_LOCALES) {
    for (const uiLang of UI_LANGUAGES) {
      const reasons = [];
      // P&L tab label must resolve
      const plTab = helpers.getTaxLabel(accId, uiLang, 'tabPlLabel');
      if (!plTab || plTab === 'tabPlLabel') reasons.push(`tabPlLabel raw/empty`);
      // PL title must resolve
      const plTitle = helpers.getTaxLabel(accId, uiLang, 'plTitle');
      if (!plTitle || plTitle === 'plTitle') reasons.push(`plTitle raw/empty`);

      // US: Schedule C name should appear in plTabLabel; not include "增值税" etc.
      if (accId === 'US') {
        if (!/Schedule C/i.test(plTab)) reasons.push(`US plTabLabel missing "Schedule C": "${plTab}"`);
        if (/增值税|进项税|销项税|进项 VAT|销项 VAT|VAT/i.test(plTitle)) {
          reasons.push(`US plTitle contains VAT/进项/销项 terminology: "${plTitle}"`);
        }
        // shouldShowTaxModule must be false
        if (helpers.shouldShowTaxModule(accId) !== false) {
          reasons.push(`shouldShowTaxModule(US) should be false`);
        }
      } else {
        // shouldShowTaxModule should be true for VAT-style locales
        if (helpers.shouldShowTaxModule(accId) !== true) {
          reasons.push(`shouldShowTaxModule(${accId}) should be true`);
        }
      }

      // Locale-specific tax-module terminology checks (label content)
      if (accId === 'CN') {
        const t = helpers.getTaxLabel(accId, uiLang, 'taxTitle');
        const expected = { 'zh-CN': /增值税/, 'zh-TW': /增值稅/, en: /VAT/i };
        if (expected[uiLang] && !expected[uiLang].test(t)) reasons.push(`CN taxTitle missing expected term in ${uiLang}: "${t}"`);
        // formTaxRate for CN must say 增值税率 (Chinese VAT context)
        const rateLabel = helpers.getTaxLabel(accId, uiLang, 'formTaxRate');
        if (uiLang === 'zh-CN' && !/增值税/.test(rateLabel)) reasons.push(`CN formTaxRate zh-CN should say 增值税率: "${rateLabel}"`);
        // CN certifiedInput / invoicedOutput must use the refined wording
        // ("已认证进项税额" / "已开票销项税额"), not the older
        // "已收进项税额 (已认证)" / "已开销项税额 (已开票)" form.
        const certInput = helpers.getTaxLabel(accId, uiLang, 'certifiedInput');
        const invOutput = helpers.getTaxLabel(accId, uiLang, 'invoicedOutput');
        if (uiLang === 'zh-CN') {
          if (!/已认证.*进项税额|已认证进项/.test(certInput)) reasons.push(`CN certifiedInput zh-CN should say 已认证进项税额: "${certInput}"`);
          if (!/已开票.*销项税额|已开票销项/.test(invOutput)) reasons.push(`CN invoicedOutput zh-CN should say 已开票销项税额: "${invOutput}"`);
          if (/已收|已开销/.test(certInput) || /已收|已开销/.test(invOutput)) {
            reasons.push(`CN labels use deprecated 已收/已开销 wording`);
          }
        }
        if (uiLang === 'zh-TW') {
          if (!/已認證.*進項稅額|已認證進項/.test(certInput)) reasons.push(`CN certifiedInput zh-TW should say 已認證進項稅額: "${certInput}"`);
          if (!/已開票.*銷項稅額|已開票銷項/.test(invOutput)) reasons.push(`CN invoicedOutput zh-TW should say 已開票銷項稅額: "${invOutput}"`);
        }
      }
      // formTaxRate cross-regime checks: non-CN locales must NOT say "增值税率"
      if (accId !== 'CN') {
        const rateLabel = helpers.getTaxLabel(accId, uiLang, 'formTaxRate');
        if (uiLang === 'zh-CN' && /增值税率/.test(rateLabel)) {
          reasons.push(`${accId} formTaxRate zh-CN incorrectly uses 中国增值税率: "${rateLabel}"`);
        }
      }
      // formTaxRate per-regime expected terms
      if (accId === 'US') {
        const rateLabel = helpers.getTaxLabel(accId, uiLang, 'formTaxRate');
        if (!/Sales Tax|sales tax/i.test(rateLabel)) reasons.push(`US formTaxRate missing Sales Tax in ${uiLang}: "${rateLabel}"`);
      }
      if (accId === 'EU') {
        const rateLabel = helpers.getTaxLabel(accId, uiLang, 'formTaxRate');
        if (!/VAT|TVA/i.test(rateLabel)) reasons.push(`EU formTaxRate missing VAT/TVA in ${uiLang}: "${rateLabel}"`);
      }
      if (accId === 'KR') {
        const rateLabel = helpers.getTaxLabel(accId, uiLang, 'formTaxRate');
        if (!/VAT|TVA|부가가치세/i.test(rateLabel)) reasons.push(`KR formTaxRate missing VAT/TVA in ${uiLang}: "${rateLabel}"`);
      }
      if (accId === 'TW') {
        const rateLabel = helpers.getTaxLabel(accId, uiLang, 'formTaxRate');
        const expected = { 'zh-CN': /营业税率/, 'zh-TW': /營業稅率/ };
        if (expected[uiLang] && !expected[uiLang].test(rateLabel)) reasons.push(`TW formTaxRate missing 营业税率 in ${uiLang}: "${rateLabel}"`);
      }
      if (accId === 'JP') {
        const t = helpers.getTaxLabel(accId, uiLang, 'taxTitle');
        const expected = { 'zh-CN': /消费税/, 'zh-TW': /消費稅/, ja: /消費税/ };
        if (expected[uiLang] && !expected[uiLang].test(t)) reasons.push(`JP taxTitle missing 消费税 in ${uiLang}: "${t}"`);
      }
      if (accId === 'EU') {
        const t = helpers.getTaxLabel(accId, uiLang, 'taxTitle');
        if (!/VAT|TVA/i.test(t)) reasons.push(`EU taxTitle missing VAT/TVA in ${uiLang}: "${t}"`);
      }
      if (accId === 'TW') {
        const t = helpers.getTaxLabel(accId, uiLang, 'taxTitle');
        const expected = { 'zh-CN': /营业税/, 'zh-TW': /營業稅/ };
        if (expected[uiLang] && !expected[uiLang].test(t)) reasons.push(`TW taxTitle missing 营业税 in ${uiLang}: "${t}"`);
      }

      if (reasons.length) fail(`financeReport:${accId}+${uiLang}`, reasons); else pass(`financeReport:${accId}+${uiLang}`);
    }
  }

  // ────────────────────────────────────────────────
  // PART G: i18n locale files completeness
  // ────────────────────────────────────────────────
  for (const lang of UI_LANGUAGES) {
    const data = locales[lang];
    const reasons = [];
    for (const key of REQUIRED_I18N_KEYS) {
      const val = get(data, key);
      if (val === undefined) {
        reasons.push(`missing key: ${key}`);
      } else if (typeof val === 'string' && val.trim() === '') {
        reasons.push(`empty value: ${key}`);
      }
    }
    if (reasons.length) fail(`i18nKeys:${lang}`, reasons); else pass(`i18nKeys:${lang}`);
  }

  // ────────────────────────────────────────────────
  // PART G0b: US Schedule C line 1 / line 7 wording lock-in.
  //   These i18n keys only render under accountingLocale=US (the Schedule C
  //   P&L view), so they carry US gross-receipts / gross-income wording, not
  //   the Chinese 营业总收入/营业总所得 phrasing. Pin the zh-CN/zh-TW strings so
  //   they can't drift back. (en/ja/ko/fr are left to the presence check above.)
  // ────────────────────────────────────────────────
  {
    const SCHED_C_PIN = {
      'zh-CN': { 'usSchedule.line1': 'Line 1 — 总收入或销售额', 'usSchedule.line7': 'Line 7 — 总收入' },
      'zh-TW': { 'usSchedule.line1': 'Line 1 — 總收入或銷售額', 'usSchedule.line7': 'Line 7 — 總收入' },
    };
    for (const [lang, pins] of Object.entries(SCHED_C_PIN)) {
      const reasons = [];
      for (const [path, want] of Object.entries(pins)) {
        const got = get(locales[lang], path);
        if (got !== want) reasons.push(`${path} should be "${want}", got "${got}"`);
      }
      // must NOT revert to the old 营业 phrasing
      for (const path of ['usSchedule.line1', 'usSchedule.line7']) {
        const got = get(locales[lang], path);
        if (typeof got === 'string' && /营业总|營業總/.test(got)) {
          reasons.push(`${path} uses old 营业总 phrasing: "${got}"`);
        }
      }
      if (reasons.length) fail(`scheduleCWording:${lang}`, reasons); else pass(`scheduleCWording:${lang}`);
    }
  }

  // ────────────────────────────────────────────────
  // PART G0c: US Tax Tools (usTax.*) wording lock-in.
  //   Page renders only under accountingLocale=US (defensive guard otherwise).
  //   - use 扣除/扣除额, never 抵扣 (抵扣 reads as CN-VAT credit wording)
  //   - mileage-form placeholders must be localized (no English in zh-CN/zh-TW)
  //   - keep official form names in canonical case (no all-caps SCHEDULE C /
  //     FORM 8829 in the string data; CSS uppercasing was removed in the page)
  // ────────────────────────────────────────────────
  {
    const US_TAX_PIN = {
      'zh-CN': {
        'usTax.deduction': '扣除额（Schedule C 第 9 行）', 'usTax.deductionShort': '扣除额',
        'usTax.homeOfficeDeduction': '家庭办公室扣除（Form 8829）',
        'usTax.fromPlaceholder': '办公室', 'usTax.toPlaceholder': '客户地点', 'usTax.purposePlaceholder': '例如：拜访客户',
      },
      'zh-TW': {
        'usTax.deduction': '扣除額（Schedule C 第 9 行）', 'usTax.deductionShort': '扣除額',
        'usTax.homeOfficeDeduction': '家庭辦公室扣除（Form 8829）',
        'usTax.fromPlaceholder': '辦公室', 'usTax.toPlaceholder': '客戶地點', 'usTax.purposePlaceholder': '例如：拜訪客戶',
      },
    };
    for (const [lang, pins] of Object.entries(US_TAX_PIN)) {
      const reasons = [];
      for (const [path, want] of Object.entries(pins)) {
        const got = get(locales[lang], path);
        if (got !== want) reasons.push(`${path} should be "${want}", got "${got}"`);
      }
      // unify on 扣除 — these labels/notes must not use 抵扣
      for (const path of ['usTax.deduction', 'usTax.deductionShort', 'usTax.homeOfficeDeduction', 'usTax.mileageNote']) {
        const got = get(locales[lang], path);
        if (typeof got === 'string' && /抵扣/.test(got)) reasons.push(`${path} uses 抵扣 (should be 扣除): "${got}"`);
      }
      // zh placeholders must not contain English letters
      for (const path of ['usTax.fromPlaceholder', 'usTax.toPlaceholder', 'usTax.purposePlaceholder', 'usTax.milesPlaceholder']) {
        const got = get(locales[lang], path);
        if (typeof got === 'string' && /[A-Za-z]/.test(got)) reasons.push(`${path} contains English in ${lang}: "${got}"`);
      }
      // official form names must stay canonical case in the string data
      for (const path of ['usTax.deduction', 'usTax.homeOfficeDeduction', 'usTax.scheduleC30', 'usTax.mileageNote', 'usTax.homeOfficeNote']) {
        const got = get(locales[lang], path);
        if (typeof got === 'string') {
          if (/SCHEDULE C/.test(got)) reasons.push(`${path} has all-caps SCHEDULE C: "${got}"`);
          if (/FORM 8829/.test(got)) reasons.push(`${path} has all-caps FORM 8829: "${got}"`);
        }
      }
      if (reasons.length) fail(`usTaxWording:${lang}`, reasons); else pass(`usTaxWording:${lang}`);
    }
  }

  // ────────────────────────────────────────────────
  // PART G0d: US accounting-profile notes (会计制度 page description).
  //   Must state the US has NO federal VAT (无联邦 VAT), never read as if the
  //   US has a federal VAT (美国联邦 VAT), and must keep the official terms.
  // ────────────────────────────────────────────────
  {
    const reasons = [];
    const usNotes = accProfiles.getProfile('US').notes || '';
    if (/美国联邦\s*VAT|美國聯邦\s*VAT/.test(usNotes)) reasons.push(`US profile.notes implies a US federal VAT: "${usNotes}"`);
    if (!/无联邦\s*VAT|無聯邦\s*VAT/.test(usNotes)) reasons.push(`US profile.notes should state 无联邦 VAT: "${usNotes}"`);
    if (!/Federal Corporate Tax/.test(usNotes)) reasons.push(`US profile.notes should mention Federal Corporate Tax: "${usNotes}"`);
    if (/增值税|增值稅|进项|進項|税金及附加|稅金及附加/.test(usNotes)) reasons.push(`US profile.notes uses CN-VAT wording: "${usNotes}"`);
    if (reasons.length) fail(`usProfileNotes:US`, reasons); else pass(`usProfileNotes:US`);
  }

  // ────────────────────────────────────────────────
  // PART G0e: JP accountingLocale Chinese-UI wording.
  //   消费税 (Japanese consumption tax) is fine, but the Chinese UI must not use
  //   进项/销项 as the primary wording — use 采购/销售. Pin the 经营看板 tax cards
  //   and the left-nav labels.
  // ────────────────────────────────────────────────
  {
    const cfg = config.getAccountingLocale('JP');
    const JP_PIN = {
      'zh-CN': { inputTax: '采购消费税', outputTax: '销售消费税', navPurchase: '采购与费用', navSales: '销售与收入', invQueryTitle: '票据查询', invoiceTypeInput: '采购', invoiceTypeOutput: '销售',
                 pageTitlePurchase: '采购与费用', headerInvoiceNo: '票据号码', headerAmount: '税前金额', headerUnitPrice: '税前单价', modalTitlePurchase: '新增采购与费用记录', newPurchaseButton: '新增采购记录',
                 plIncomeTax: '所得税/法人税', certifiedInput: '可抵扣采购消费税额', invoicedOutput: '已开票销售消费税额',
                 invFilterAll: '全部票据', invFilterInput: '采购与费用', invFilterOutput: '销售与收入',
                 invTableTitle: '票据流转全景视图', invTableSubtitle: '核对票据、库存与交易记录的一致性',
                 invPendingTax: '待处理消费税额', invHeaderAmount: '税前金额', invStatusPendingIssue: '待补票据', invEmpty: '未找到匹配的票据记录', invAmountRange: '税前金额范围',
                 taxTitle: '消费税统计', taxReportTitle: '消费税汇总' },
      'zh-TW': { inputTax: '採購消費稅', outputTax: '銷售消費稅', navPurchase: '採購與費用', navSales: '銷售與收入', invQueryTitle: '票據查詢', invoiceTypeInput: '採購', invoiceTypeOutput: '銷售',
                 pageTitlePurchase: '採購與費用', headerInvoiceNo: '票據號碼', headerAmount: '稅前金額', headerUnitPrice: '稅前單價', modalTitlePurchase: '新增採購與費用記錄', newPurchaseButton: '新增採購記錄',
                 plIncomeTax: '所得稅/法人稅', certifiedInput: '可抵扣採購消費稅額', invoicedOutput: '已開票銷售消費稅額',
                 invFilterAll: '全部票據', invFilterInput: '採購與費用', invFilterOutput: '銷售與收入',
                 invTableTitle: '票據流轉全景視圖', invTableSubtitle: '核對票據、庫存與交易記錄的一致性',
                 invPendingTax: '待處理消費稅額', invHeaderAmount: '稅前金額', invStatusPendingIssue: '待補票據', invEmpty: '未找到相符的票據記錄', invAmountRange: '稅前金額範圍',
                 taxTitle: '消費稅統計', taxReportTitle: '消費稅彙總' },
    };
    // JP money semantics are JPY — no 人民币/人民幣 may leak into any JP wording.
    const JP_UNIT = { 'zh-CN': /日元/, 'zh-TW': /日圓/ };
    for (const lang of ['zh-CN', 'zh-TW']) {
      const reasons = [];
      // ban CN-VAT wording across ALL JP taxConcepts: 进项/销项 (use 采购/销售),
      // 电子发票 / 发票号码 (use 票据), 增值税 and 认证 (CN-VAT only). 消费税 itself is
      // allowed. Money must be JPY — ban 人民币/RMB/CNY.
      for (const [key, labels] of Object.entries(cfg.taxConcepts)) {
        const v = labels[lang];
        if (typeof v !== 'string') continue;
        if (/进项|進項|销项|銷項/.test(v)) reasons.push(`JP ${key}[${lang}] uses 进项/销项 (should be 采购/销售): "${v}"`);
        if (/电子发票|電子發票/.test(v)) reasons.push(`JP ${key}[${lang}] uses 电子发票 (should be 票据): "${v}"`);
        if (/发票号码|發票號碼/.test(v)) reasons.push(`JP ${key}[${lang}] uses 发票号码 (should be 票据号码): "${v}"`);
        if (/发票查询|發票查詢/.test(v)) reasons.push(`JP ${key}[${lang}] uses 发票查询 (should be 票据查询): "${v}"`);
        if (/增值税|增值稅/.test(v)) reasons.push(`JP ${key}[${lang}] uses 增值税 (JP is 消费税): "${v}"`);
        if (/认证|認證/.test(v)) reasons.push(`JP ${key}[${lang}] uses 认证 (CN-VAT only): "${v}"`);
        if (/人民币|人民幣|RMB|CNY/.test(v)) reasons.push(`JP ${key}[${lang}] uses 人民币/RMB/CNY (JP money is 日元/JPY): "${v}"`);
      }
      // the P&L period subtitle (单位/币种 说明) must state 日元/日圓, never 人民币
      const period = helpers.getTaxLabel('JP', lang, 'plPeriodPrefix');
      if (!JP_UNIT[lang].test(period)) reasons.push(`JP plPeriodPrefix[${lang}] should state ${lang === 'zh-CN' ? '日元' : '日圓'}: "${period}"`);
      // pin the 经营看板 tax cards + nav wording
      for (const [key, want] of Object.entries(JP_PIN[lang])) {
        const got = helpers.getTaxLabel('JP', lang, key);
        if (got !== want) reasons.push(`JP ${key}[${lang}] should be "${want}", got "${got}"`);
      }
      // 消费税 should still be present in the tax cards (JP keeps consumption tax)
      if (!/消费税|消費稅/.test(helpers.getTaxLabel('JP', lang, 'inputTax'))) {
        reasons.push(`JP inputTax[${lang}] should keep 消费税: "${helpers.getTaxLabel('JP', lang, 'inputTax')}"`);
      }
      if (reasons.length) fail(`jpWording:${lang}`, reasons); else pass(`jpWording:${lang}`);
    }
  }

  // ────────────────────────────────────────────────
  // PART G0n: JP transaction-category labels (收支记录 分类下拉).
  //   Under JP accountingLocale + zh-CN/zh-TW UI the category dropdown shows
  //   `displayLabel → schedule_line`, localized via JP_TXN_CATEGORY_LABELS (applied
  //   read-time in services/api.ts, keyed by slug). Guard: every JP category slug
  //   resolves zh-CN/zh-TW label + report-line; the report-line stays Chinese-main
  //   (损益表-… , never the raw Japanese 損益計算書/販管費) with the formal Japanese
  //   account name in parens; no CN-VAT (进项/销项/增值税/认证/电子发票) or non-JPY
  //   (人民币/RMB/CNY); and COGS↔売上原価 / advertising↔広告宣伝費 mappings hold
  //   (guards against the 广告费→売上原価 regression).
  // ────────────────────────────────────────────────
  {
    const reasons = [];
    const M = config.JP_TXN_CATEGORY_LABELS || {};
    const REQUIRED_SLUGS = ['sales', 'other', 'cogs', 'salary', 'travel', 'communication', 'utilities', 'supplies', 'entertain', 'advertising', 'rent', 'tax', 'depreciation', 'misc'];
    // raw Japanese report headers must not be the zh main text; no CN-VAT / non-JPY
    const JP_HEADER_BAN = /損益計算書|损益计算书|販管費|贩管费/;
    const CN_VAT_MONEY_BAN = /进项|進項|销项|銷項|增值税|增值稅|认证|認證|电子发票|電子發票|人民币|人民幣|RMB|CNY/;
    for (const slug of REQUIRED_SLUGS) {
      const e = M[slug];
      if (!e) { reasons.push(`JP_TXN_CATEGORY_LABELS missing slug "${slug}"`); continue; }
      for (const lang of ['zh-CN', 'zh-TW']) {
        const label = e.label && e.label[lang];
        const line = e.scheduleLine && e.scheduleLine[lang];
        if (!label) reasons.push(`JP cat ${slug}.label[${lang}] missing`);
        if (!line) reasons.push(`JP cat ${slug}.scheduleLine[${lang}] missing`);
        for (const [field, v] of [['label', label], ['scheduleLine', line]]) {
          if (typeof v !== 'string') continue;
          if (JP_HEADER_BAN.test(v)) reasons.push(`JP cat ${slug}.${field}[${lang}] uses raw JP report header (should be 损益表-…): "${v}"`);
          if (CN_VAT_MONEY_BAN.test(v)) reasons.push(`JP cat ${slug}.${field}[${lang}] uses CN-VAT/non-JPY term: "${v}"`);
        }
        // report-line must be Chinese-main (损益表/損益表 prefix)
        if (typeof line === 'string' && !/^损益表-|^損益表-/.test(line)) {
          reasons.push(`JP cat ${slug}.scheduleLine[${lang}] should start with 损益表-/損益表-: "${line}"`);
        }
      }
    }
    // mapping integrity: COGS ↔ 売上原価 (label 销售成本, NOT 广告), advertising ↔ 広告宣伝費
    const cogs = M.cogs, ad = M.advertising;
    if (cogs) {
      if (cogs.label['zh-CN'] !== '销售成本') reasons.push(`JP cat cogs.label[zh-CN] should be 销售成本, got "${cogs.label['zh-CN']}"`);
      if (!/売上原価/.test(cogs.scheduleLine['zh-CN'] || '')) reasons.push(`JP cat cogs.scheduleLine[zh-CN] should map to 売上原価: "${cogs.scheduleLine['zh-CN']}"`);
      if (/广告|廣告|広告/.test(cogs.label['zh-CN'] + cogs.scheduleLine['zh-CN'])) reasons.push(`JP cat cogs must NOT be advertising (广告费→売上原価 regression)`);
    }
    if (ad) {
      if (ad.label['zh-CN'] !== '广告费') reasons.push(`JP cat advertising.label[zh-CN] should be 广告费, got "${ad.label['zh-CN']}"`);
      if (!/広告宣伝費/.test(ad.scheduleLine['zh-CN'] || '')) reasons.push(`JP cat advertising.scheduleLine[zh-CN] should map to 広告宣伝費: "${ad.scheduleLine['zh-CN']}"`);
    }
    if (reasons.length) fail(`jpTxnCategoryLabels`, reasons); else pass(`jpTxnCategoryLabels`);
  }

  // ────────────────────────────────────────────────
  // PART G0o: EU dashboard tax section (经营看板 VAT 统计 + 含税汇总).
  //   EU accountingLocale uses generic VAT wording (采购/销售 VAT), NOT the CN/JP-VAT
  //   ledger 进项/销项 nor JP 消费税. Under zh-CN/zh-TW the 经营看板 tax cards
  //   (VATStatistics) and the tax-inclusive summary (TaxInclusiveSummary) must pin
  //   the agreed VAT wording and never leak 消费税 / 进项 / 销项 or a non-EUR currency
  //   (人民币/CNY/日元/JPY/美元/USD). en/ja/ko/fr keep the standard Input/Output VAT
  //   terms (not checked here). CN keeps 进项/销项/增值税; JP keeps 消费税 (guarded
  //   elsewhere) — both unaffected.
  // ────────────────────────────────────────────────
  {
    const reasons = [];
    const EU_PIN = {
      'zh-CN': {
        taxTitle: 'VAT 统计', inputTax: '采购 VAT', outputTax: '销售 VAT',
        certifiedInput: '可抵扣采购 VAT', invoicedOutput: '已开票销售 VAT', estimatedTax: '预计应缴 VAT',
        taxSummaryTitle: 'VAT 含税汇总 (对账用)', purchaseTotal: '采购含税总额', salesTotal: '销售含税总额', taxDifference: 'VAT 差额',
      },
      'zh-TW': {
        taxTitle: 'VAT 統計', inputTax: '採購 VAT', outputTax: '銷售 VAT',
        certifiedInput: '可抵扣採購 VAT', invoicedOutput: '已開票銷售 VAT', estimatedTax: '預計應繳 VAT',
        taxSummaryTitle: 'VAT 含稅匯總 (對帳用)', purchaseTotal: '採購含稅總額', salesTotal: '銷售含稅總額', taxDifference: 'VAT 差額',
      },
    };
    // dashboard tax-section keys (VATStatistics + TaxInclusiveSummary)
    const EU_DASH_TAX_KEYS = Object.keys(EU_PIN['zh-CN']);
    const EU_TAX_BAN = /消费税|消費稅|进项|進項|销项|銷項|人民币|人民幣|CNY|日元|日圓|JPY|美元|USD/;
    for (const lang of ['zh-CN', 'zh-TW']) {
      for (const [key, want] of Object.entries(EU_PIN[lang])) {
        const got = helpers.getTaxLabel('EU', lang, key);
        if (got !== want) reasons.push(`EU ${key}[${lang}] should be "${want}", got "${got}"`);
      }
      // ban CN/JP-VAT wording + non-EUR currency on the dashboard tax-section keys
      for (const key of EU_DASH_TAX_KEYS) {
        const v = helpers.getTaxLabel('EU', lang, key);
        if (typeof v === 'string' && EU_TAX_BAN.test(v)) reasons.push(`EU ${key}[${lang}] uses 消费税/进项/销项/non-EUR currency: "${v}"`);
      }
    }
    // regression guards the other way: CN keeps 进项/销项/增值税; JP keeps 消费税
    if (helpers.getTaxLabel('CN', 'zh-CN', 'inputTax') !== '累计进项税额') reasons.push(`CN inputTax[zh-CN] should stay 累计进项税额, got "${helpers.getTaxLabel('CN', 'zh-CN', 'inputTax')}"`);
    if (!/消费税/.test(helpers.getTaxLabel('JP', 'zh-CN', 'inputTax'))) reasons.push(`JP inputTax[zh-CN] should keep 消费税, got "${helpers.getTaxLabel('JP', 'zh-CN', 'inputTax')}"`);
    if (reasons.length) fail(`euDashboardVat`, reasons); else pass(`euDashboardVat`);
  }

  // ────────────────────────────────────────────────
  // PART G0p: EU accountingLocale full wording audit (rendered pages).
  //   Across 经营看板 / 采购与费用 / 销售与收入 / 票据查询 / 应收应付 / 财务报表 /
  //   收支记录, the EU Chinese UI must never carry CN-VAT (进项/销项/增值税/认证),
  //   JP 消费税, US Sales Tax, or a non-EUR currency (人民币/CNY/¥/日元/JPY/美元/USD).
  //   Bans those across ALL EU taxConcepts (zh-CN/zh-TW) and pins the key page
  //   wording. Reverse guards confirm CN/JP/US口径 are not collaterally changed.
  // ────────────────────────────────────────────────
  {
    const reasons = [];
    const cfgEU = config.getAccountingLocale('EU');
    // Currency is rendered via formatMoney(accLocale)=€, never inside these strings.
    const EU_BAN = /进项|進項|销项|銷項|增值税|增值稅|消费税|消費稅|认证|認證|Sales Tax|人民币|人民幣|CNY|日元|日圓|JPY|美元|USD|¥/;
    for (const lang of ['zh-CN', 'zh-TW']) {
      for (const [key, labels] of Object.entries(cfgEU.taxConcepts)) {
        const v = labels[lang];
        if (typeof v === 'string' && EU_BAN.test(v)) {
          reasons.push(`EU ${key}[${lang}] uses banned (CN-VAT/JP/US/non-EUR) wording: "${v}"`);
        }
      }
    }
    // pin key rendered wording across the EU pages (zh-CN / zh-TW)
    const EU_PAGE_PIN = {
      'zh-CN': {
        pageTitlePurchase: '采购与费用', pageTitleSales: '销售与收入', invQueryTitle: '票据查询',
        headerInvoiceNo: '票据号码', headerUnitPrice: '税前单价', headerAmount: '税前金额',
        formTaxRate: 'VAT 税率', setVatRateLabel: 'VAT 税率', plIncomeTax: '所得税',
        acctReceivableTab: '客户应收', acctPayableTab: '供应商应付',
        invoiceTypeInput: '采购', invoiceTypeOutput: '销售',
      },
      'zh-TW': {
        pageTitlePurchase: '採購與費用', pageTitleSales: '銷售與收入', invQueryTitle: '票據查詢',
        headerInvoiceNo: '票據號碼', headerUnitPrice: '稅前單價', headerAmount: '稅前金額',
        formTaxRate: 'VAT 稅率', setVatRateLabel: 'VAT 稅率', plIncomeTax: '所得稅',
        acctReceivableTab: '客戶應收', acctPayableTab: '供應商應付',
        invoiceTypeInput: '採購', invoiceTypeOutput: '銷售',
      },
    };
    for (const lang of ['zh-CN', 'zh-TW']) {
      for (const [key, want] of Object.entries(EU_PAGE_PIN[lang])) {
        const got = helpers.getTaxLabel('EU', lang, key);
        if (got !== want) reasons.push(`EU ${key}[${lang}] should be "${want}", got "${got}"`);
      }
    }
    // reverse guards: CN/JP/US口径 must remain intact (not collaterally changed)
    if (helpers.getTaxLabel('CN', 'zh-CN', 'inputTax') !== '累计进项税额') reasons.push(`CN inputTax[zh-CN] should stay 累计进项税额`);
    if (helpers.getTaxLabel('CN', 'zh-CN', 'formTaxRate') !== '增值税率') reasons.push(`CN formTaxRate[zh-CN] should stay 增值税率`);
    if (!/消费税/.test(helpers.getTaxLabel('JP', 'zh-CN', 'inputTax'))) reasons.push(`JP inputTax[zh-CN] should keep 消费税`);
    if (!/Sales Tax/.test(helpers.getTaxLabel('US', 'zh-CN', 'formTaxRate'))) reasons.push(`US formTaxRate[zh-CN] should keep Sales Tax`);
    if (reasons.length) fail(`euAccountingWording`, reasons); else pass(`euAccountingWording`);
  }

  // ────────────────────────────────────────────────
  // PART G0q: EU 票据查询 (invoice-query) page wording.
  //   EU uses the 采购与费用 / 销售与收入 wording (matching nav + tabs), not the shared
  //   采购/费用 · 销售/收入 slash form, and 待补票据 (not 待票据). Pins the rendered
  //   票据查询 keys and bans the slash form, 待票据, CN-VAT (进项/销项/增值税/认证), JP
  //   消费税, US Sales Tax, and non-EUR currency across the page's key set. (库存/交易
  //   in the table subtitle is allowed — only 采购/费用 · 销售/收入 are banned.)
  // ────────────────────────────────────────────────
  {
    const reasons = [];
    const EU_INV_PIN = {
      'zh-CN': {
        invQueryTitle: '票据查询', invFilterAll: '全部票据', invFilterInput: '采购与费用', invFilterOutput: '销售与收入',
        invTotalInput: '累计采购与费用票据', invTotalOutput: '累计销售与收入票据',
        invTableTitle: '票据流转全景视图', invHeaderInvoiceNo: '票据号码', invEmpty: '未找到匹配的票据记录',
        invStatusVerified: '已核验', invStatusCertified: '已记录', invStatusDeducted: '已处理',
        invStatusPendingCert: '待处理', invStatusPendingIssue: '待补票据', invStatusIssued: '已开票',
        invoiceTypeInput: '采购', invoiceTypeOutput: '销售',
      },
      'zh-TW': {
        invQueryTitle: '票據查詢', invFilterAll: '全部票據', invFilterInput: '採購與費用', invFilterOutput: '銷售與收入',
        invTotalInput: '累計採購與費用票據', invTotalOutput: '累計銷售與收入票據',
        invTableTitle: '票據流轉全景視圖', invHeaderInvoiceNo: '票據號碼', invEmpty: '未找到匹配的票據記錄',
        invStatusVerified: '已核驗', invStatusCertified: '已記錄', invStatusDeducted: '已處理',
        invStatusPendingCert: '待處理', invStatusPendingIssue: '待補票據', invStatusIssued: '已開票',
        invoiceTypeInput: '採購', invoiceTypeOutput: '銷售',
      },
    };
    // rendered 票据查询 key set (InventoryPage stat cards / filters / table / statuses)
    const EU_INV_KEYS = [
      'invQueryTitle', 'invSearchPlaceholder', 'invFilterAll', 'invFilterInput', 'invFilterOutput',
      'invTotalInput', 'invTotalOutput', 'invPendingTax', 'invPendingTaxSub', 'invNoInput', 'invNoOutput',
      'invInputRecordCount', 'invOutputRecordCount', 'invTableTitle', 'invTableSubtitle',
      'invHeaderDate', 'invHeaderWeight', 'invHeaderAmount', 'invHeaderInvoiceNo', 'invEmpty',
      'invDateRange', 'invWeightRange', 'invStatusFilter', 'invStatusAll', 'invStatusVerified',
      'invStatusCertified', 'invStatusDeducted', 'invStatusPendingCert', 'invStatusPendingIssue',
      'invStatusIssued', 'invAdvFilterActive', 'invoiceTypeInput', 'invoiceTypeOutput',
    ];
    const EU_INV_BAN = /待补采购|待補採購|采购\/费用|採購\/費用|销售\/收入|銷售\/收入|待票据|待票據|进项|進項|销项|銷項|增值税|增值稅|消费税|消費稅|Sales Tax|人民币|人民幣|CNY|日元|日圓|JPY|美元|USD/;
    for (const lang of ['zh-CN', 'zh-TW']) {
      for (const key of EU_INV_KEYS) {
        const v = helpers.getTaxLabel('EU', lang, key);
        if (v === key) reasons.push(`EU ${key}[${lang}] missing (raw key)`);
        if (typeof v === 'string' && EU_INV_BAN.test(v)) reasons.push(`EU ${key}[${lang}] uses banned 票据查询 wording: "${v}"`);
      }
      for (const [key, want] of Object.entries(EU_INV_PIN[lang])) {
        const got = helpers.getTaxLabel('EU', lang, key);
        if (got !== want) reasons.push(`EU ${key}[${lang}] should be "${want}", got "${got}"`);
      }
    }
    // reverse guards: JP/KR keep the shared slash form (EU override must not leak to them)
    if (helpers.getTaxLabel('JP', 'zh-CN', 'invTotalInput') !== '累计采购/费用票据') reasons.push(`JP invTotalInput[zh-CN] should stay 累计采购/费用票据 (NON_CN_GENERIC), got "${helpers.getTaxLabel('JP', 'zh-CN', 'invTotalInput')}"`);
    if (helpers.getTaxLabel('KR', 'zh-CN', 'invTotalInput') !== '累计采购/费用票据') reasons.push(`KR invTotalInput[zh-CN] should stay 累计采购/费用票据 (NON_CN_GENERIC), got "${helpers.getTaxLabel('KR', 'zh-CN', 'invTotalInput')}"`);
    if (reasons.length) fail(`euInvoiceQuery`, reasons); else pass(`euInvoiceQuery`);
  }

  // ────────────────────────────────────────────────
  // PART G0r: EU transaction-category labels (收支记录 分类下拉).
  //   Under EU accountingLocale + zh-CN/zh-TW UI the category dropdown shows
  //   `displayLabel → schedule_line`, localized via EU_TXN_CATEGORY_LABELS (applied
  //   read-time in services/api.ts, keyed by slug). Guard: every EU category slug
  //   resolves zh-CN/zh-TW label + report-line; the report-line is Chinese (损益表-…
  //   or VAT 申报), never the seeded English P&L - … / VAT Return; no CN-VAT
  //   (进项/销项/增值税/认证), JP 消费税, US Sales Tax, or non-EUR currency.
  // ────────────────────────────────────────────────
  {
    const reasons = [];
    const M = config.EU_TXN_CATEGORY_LABELS || {};
    const REQUIRED_SLUGS = ['revenue', 'financial', 'purchases', 'rent', 'salaries', 'social-charges', 'travel', 'professional', 'marketing', 'energy', 'amortization', 'vat-net'];
    const EU_CAT_BAN = /P&L|VAT Return|进项|進項|销项|銷項|增值税|增值稅|消费税|消費稅|认证|認證|Sales Tax|人民币|人民幣|CNY|日元|日圓|JPY|美元|USD/i;
    // exact report-line pins (the agreed EU 收支记录 wording)
    const LINE_PIN = {
      'zh-CN': { revenue: '损益表-营业收入', financial: '损益表-财务收入', purchases: '损益表-采购', rent: '损益表-租金', salaries: '损益表-工资', 'social-charges': '损益表-社会保险费', travel: '损益表-差旅费', professional: '损益表-专业服务费', marketing: '损益表-市场推广费', energy: '损益表-能源费用', amortization: '损益表-摊销', 'vat-net': 'VAT 申报' },
      'zh-TW': { revenue: '損益表-營業收入', financial: '損益表-財務收入', purchases: '損益表-採購', rent: '損益表-租金', salaries: '損益表-工資', 'social-charges': '損益表-社會保險費', travel: '損益表-差旅費', professional: '損益表-專業服務費', marketing: '損益表-市場推廣費', energy: '損益表-能源費用', amortization: '損益表-攤銷', 'vat-net': 'VAT 申報' },
    };
    for (const slug of REQUIRED_SLUGS) {
      const e = M[slug];
      if (!e) { reasons.push(`EU_TXN_CATEGORY_LABELS missing slug "${slug}"`); continue; }
      for (const lang of ['zh-CN', 'zh-TW']) {
        const label = e.label && e.label[lang];
        const line = e.scheduleLine && e.scheduleLine[lang];
        if (!label) reasons.push(`EU cat ${slug}.label[${lang}] missing`);
        if (!line) reasons.push(`EU cat ${slug}.scheduleLine[${lang}] missing`);
        for (const [field, v] of [['label', label], ['scheduleLine', line]]) {
          if (typeof v === 'string' && EU_CAT_BAN.test(v)) reasons.push(`EU cat ${slug}.${field}[${lang}] uses banned (English P&L/VAT Return/CN-VAT/JP/US/non-EUR) wording: "${v}"`);
        }
        if (typeof line === 'string' && LINE_PIN[lang][slug] && line !== LINE_PIN[lang][slug]) {
          reasons.push(`EU cat ${slug}.scheduleLine[${lang}] should be "${LINE_PIN[lang][slug]}", got "${line}"`);
        }
      }
    }
    if (reasons.length) fail(`euTxnCategoryLabels`, reasons); else pass(`euTxnCategoryLabels`);
  }

  // ────────────────────────────────────────────────
  // PART G0s: KR dashboard tax section + AI briefing wording.
  //   KR accountingLocale uses Korean VAT wording in Chinese (韩国 VAT 统计 / 采购 VAT
  //   / 销售 VAT), NOT the CN/JP-VAT ledger 进项/销项 nor 消费税. Under zh-CN/zh-TW the
  //   经营看板 tax cards (VATStatistics) + tax-inclusive summary (TaxInclusiveSummary)
  //   are pinned, and the AI briefing prompt (buildAIFinanceContext) steers the same
  //   wording. Money stays KRW (₩) — ban 人民币/CNY/欧元/EUR/€/日元/JPY/美元/USD. CN/JP/
  //   EU/US口径 are guarded the other way.
  // ────────────────────────────────────────────────
  {
    const reasons = [];
    const KR_PIN = {
      'zh-CN': {
        taxTitle: '韩国 VAT 统计', inputTax: '采购 VAT', outputTax: '销售 VAT',
        certifiedInput: '可抵扣采购 VAT', invoicedOutput: '已开票销售 VAT', estimatedTax: '预计应缴 VAT',
        taxSummaryTitle: '韩国 VAT 含税汇总（对账用）', purchaseTotal: '采购含税总额', salesTotal: '销售含税总额', taxDifference: 'VAT 差额',
      },
      'zh-TW': {
        taxTitle: '韓國 VAT 統計', inputTax: '採購 VAT', outputTax: '銷售 VAT',
        certifiedInput: '可抵扣採購 VAT', invoicedOutput: '已開票銷售 VAT', estimatedTax: '預計應繳 VAT',
        taxSummaryTitle: '韓國 VAT 含稅彙總（對帳用）', purchaseTotal: '採購含稅總額', salesTotal: '銷售含稅總額', taxDifference: 'VAT 差額',
      },
    };
    const KR_DASH_TAX_KEYS = Object.keys(KR_PIN['zh-CN']);
    const KR_TAX_BAN = /进项|進項|销项|銷項|增值税|增值稅|消费税|消費稅|Sales Tax|人民币|人民幣|CNY|欧元|歐元|EUR|€|日元|日圓|JPY|美元|USD|\$/;
    for (const lang of ['zh-CN', 'zh-TW']) {
      for (const [key, want] of Object.entries(KR_PIN[lang])) {
        const got = helpers.getTaxLabel('KR', lang, key);
        if (got !== want) reasons.push(`KR ${key}[${lang}] should be "${want}", got "${got}"`);
      }
      for (const key of KR_DASH_TAX_KEYS) {
        const v = helpers.getTaxLabel('KR', lang, key);
        if (typeof v === 'string' && KR_TAX_BAN.test(v)) reasons.push(`KR ${key}[${lang}] uses 进项/销项/消费税/non-KRW currency: "${v}"`);
      }
      // AI briefing prompt: steers 采购/销售 VAT, never 进项/销项/增值税/消费税
      const ctx = helpers.buildAIFinanceContext('KR', lang);
      const wantIn = lang === 'zh-CN' ? '采购 VAT' : '採購 VAT';
      const wantOut = lang === 'zh-CN' ? '销售 VAT' : '銷售 VAT';
      if (!ctx.includes(wantIn) || !ctx.includes(wantOut)) reasons.push(`KR AI context[${lang}] should steer 采购/销售 VAT wording`);
      if (/进项|進項|销项|銷項|增值税|增值稅|消费税|消費稅/.test(ctx)) reasons.push(`KR AI context[${lang}] must not contain CN-VAT/JP wording: "${ctx}"`);
    }
    // reverse guards: CN/JP/EU/US口径 unchanged; AI directive does not leak to CN
    if (helpers.getTaxLabel('CN', 'zh-CN', 'inputTax') !== '累计进项税额') reasons.push(`CN inputTax[zh-CN] should stay 累计进项税额`);
    if (!/消费税/.test(helpers.getTaxLabel('JP', 'zh-CN', 'inputTax'))) reasons.push(`JP inputTax[zh-CN] should keep 消费税`);
    if (helpers.getTaxLabel('EU', 'zh-CN', 'inputTax') !== '采购 VAT') reasons.push(`EU inputTax[zh-CN] should stay 采购 VAT`);
    if (/采购 VAT|销售 VAT/.test(helpers.buildAIFinanceContext('CN', 'zh-CN'))) reasons.push(`CN AI context should not carry KR VAT directive`);
    if (reasons.length) fail(`krDashboardVat`, reasons); else pass(`krDashboardVat`);
  }

  // ────────────────────────────────────────────────
  // PART G0t: KR purchase/sales OCR scan button.
  //   Under KR accountingLocale + zh-CN/zh-TW UI the 采购与费用 / 销售与收入 scan
  //   button uses generic 票据 wording (扫描票据 / 掃描票據), not the CN 税控发票
  //   framing (扫描发票 / 掃描發票). Resolved via the KR scanDocButton taxConcept,
  //   gated on accLocale === 'KR'. Reverse guard: the shared purchases/sales.scanInvoice
  //   i18n stays 扫描发票 / 掃描發票 (still used by CN/EU/JP/US/TW).
  // ────────────────────────────────────────────────
  {
    const reasons = [];
    const PIN = { 'zh-CN': '扫描票据', 'zh-TW': '掃描票據' };
    for (const lang of ['zh-CN', 'zh-TW']) {
      const got = helpers.getTaxLabel('KR', lang, 'scanDocButton');
      if (got !== PIN[lang]) reasons.push(`KR scanDocButton[${lang}] should be "${PIN[lang]}", got "${got}"`);
      if (/扫描发票|掃描發票/.test(got)) reasons.push(`KR scanDocButton[${lang}] must not say 扫描发票/掃描發票: "${got}"`);
    }
    // reverse: the shared scan-button i18n keeps the CN 税控发票 wording (CN display)
    const cn = locales['zh-CN'], tw = locales['zh-TW'];
    if (get(cn, 'purchases.scanInvoice') !== '扫描发票') reasons.push(`CN purchases.scanInvoice should stay 扫描发票, got "${get(cn, 'purchases.scanInvoice')}"`);
    if (get(cn, 'sales.scanInvoice') !== '扫描发票') reasons.push(`CN sales.scanInvoice should stay 扫描发票, got "${get(cn, 'sales.scanInvoice')}"`);
    if (get(tw, 'purchases.scanInvoice') !== '掃描發票') reasons.push(`CN(zh-TW) purchases.scanInvoice should stay 掃描發票, got "${get(tw, 'purchases.scanInvoice')}"`);
    if (get(tw, 'sales.scanInvoice') !== '掃描發票') reasons.push(`CN(zh-TW) sales.scanInvoice should stay 掃描發票, got "${get(tw, 'sales.scanInvoice')}"`);
    if (reasons.length) fail(`krScanDocButton`, reasons); else pass(`krScanDocButton`);
  }

  // ────────────────────────────────────────────────
  // PART G0f: Non-CN generic business taxConcepts (PR-A shared base).
  //   The nav / page-title / upload / table-header / modal / button / empty /
  //   invoice-query-basics labels must be present for every non-CN locale
  //   (US/JP/KR/TW/EU) and, under zh-CN/zh-TW, must NOT carry China-VAT wording
  //   (采购与进项 / 销售与销项 / 发票查询 / 进项 / 销项 / 电子发票 / 发票号码 /
  //   增值税). CN is exempt (its VAT wording is intended).
  // ────────────────────────────────────────────────
  {
    const GENERIC_KEYS = [
      'navPurchase', 'navSales', 'invQueryTitle', 'pageTitlePurchase', 'pageTitleSales',
      'uploadTitle', 'uploadSubtitle', 'uploadTitleSales', 'uploadSubtitleSales',
      'scanningTitle', 'scanningSubtitle',
      'headerUnitPrice', 'headerAmount', 'headerTaxAmount', 'headerTotalWithTax', 'headerInvoiceNo',
      'modalTitlePurchase', 'modalSubtitlePurchase', 'modalTitleSales', 'modalSubtitleSales',
      'newPurchaseButton', 'newSaleButton', 'emptyPurchase', 'emptySales',
      'invSearchPlaceholder', 'invFilterAll', 'invFilterInput', 'invFilterOutput',
      'invTableTitle', 'invTableSubtitle', 'invHeaderDate', 'invHeaderWeight',
      'invHeaderAmount', 'invHeaderInvoiceNo', 'invEmpty',
    ];
    // 发票号(码) is banned for non-CN (use 票据号码); the bare 发票号 form also
    // covers the 发票号码 variant. Plain 发票 stays allowed (US uploadTitle uses it).
    const CN_VAT_BAN = /采购与进项|採購與進項|销售与销项|銷售與銷項|发票查询|發票查詢|进项|進項|销项|銷項|电子发票|電子發票|发票号|發票號|增值税|增值稅/;
    for (const accId of ['US', 'JP', 'KR', 'TW', 'EU']) {
      const reasons = [];
      for (const key of GENERIC_KEYS) {
        for (const lang of UI_LANGUAGES) {
          const v = helpers.getTaxLabel(accId, lang, key);
          if (v === key) reasons.push(`${key}[${lang}] missing (raw key) for ${accId}`);
        }
        // CN-VAT ban only on the Chinese display strings
        for (const lang of ['zh-CN', 'zh-TW']) {
          const v = helpers.getTaxLabel(accId, lang, key);
          if (typeof v === 'string' && CN_VAT_BAN.test(v)) {
            reasons.push(`${accId} ${key}[${lang}] uses China-VAT wording: "${v}"`);
          }
        }
      }
      if (reasons.length) fail(`genericNonCn:${accId}`, reasons); else pass(`genericNonCn:${accId}`);
    }
    // CN must KEEP its VAT wording (regression guard the other way): CN nav i18n
    // should still read 采购与进项 / 销售与销项 / 发票查询.
    {
      const cn = locales['zh-CN'];
      const reasons = [];
      if (get(cn, 'nav.purchase') !== '采购与进项') reasons.push(`CN nav.purchase should stay 采购与进项, got "${get(cn, 'nav.purchase')}"`);
      if (get(cn, 'nav.sales') !== '销售与销项') reasons.push(`CN nav.sales should stay 销售与销项, got "${get(cn, 'nav.sales')}"`);
      if (reasons.length) fail(`cnVatPreserved`, reasons); else pass(`cnVatPreserved`);
    }
  }

  // ────────────────────────────────────────────────
  // PART G0g: Accounts (应收应付) + Finance balance-sheet non-CN wording.
  //   For every non-CN accountingLocale (US/JP/KR/TW/EU) the AR/AP ledger,
  //   tax-payable and owner-equity labels must use generic business wording, NOT
  //   China-GAAP (应收账款 / 应付账款 / 应交税费 / 实收资本 / 未分配利润 / 股东权益).
  //   These keys are present for all non-CN locales (raw-key guard) and the
  //   zh-CN/zh-TW display strings are pinned to the agreed terms so AccountsPage /
  //   FinancePage can no longer fall back to the CN i18n values. CN is exempt and
  //   guarded the other way below.
  // ────────────────────────────────────────────────
  {
    const ACCT_FIN_KEYS = [
      'acctReceivableTab', 'acctPayableTab', 'acctTotalReceivable', 'acctTotalPayable',
      'balRecvLabel', 'balPayLabel', 'balTaxPayLabel', 'balPaidInCapital',
      'balRetainedEarnings', 'balLiabEquityHeader', 'balTotalLiabEquity', 'balCashflowAdd',
    ];
    const CN_GAAP_BAN = /应收账款|應收帳款|应付账款|應付帳款|应交税费|應交稅費|实收资本|實收資本|未分配利润|未分配利潤|股东权益|股東權益/;
    const PIN = {
      'zh-CN': {
        acctReceivableTab: '客户应收', acctPayableTab: '供应商应付',
        acctTotalReceivable: '客户应收总额', acctTotalPayable: '供应商应付总额',
        balRecvLabel: '客户应收', balPayLabel: '供应商应付', balTaxPayLabel: '应付税款',
        balPaidInCapital: '所有者投入', balRetainedEarnings: '留存收益',
        balLiabEquityHeader: '负债和所有者权益', balTotalLiabEquity: '负债和所有者权益总计',
      },
      'zh-TW': {
        acctReceivableTab: '客戶應收', acctPayableTab: '供應商應付',
        acctTotalReceivable: '客戶應收總額', acctTotalPayable: '供應商應付總額',
        balRecvLabel: '客戶應收', balPayLabel: '供應商應付', balTaxPayLabel: '應付稅款',
        balPaidInCapital: '所有者投入', balRetainedEarnings: '留存收益',
        balLiabEquityHeader: '負債和所有者權益', balTotalLiabEquity: '負債和所有者權益總計',
      },
    };
    for (const accId of ['US', 'JP', 'KR', 'TW', 'EU']) {
      const reasons = [];
      for (const key of ACCT_FIN_KEYS) {
        // presence: every non-CN locale must resolve the key (no raw-key fallback)
        for (const lang of UI_LANGUAGES) {
          const v = helpers.getTaxLabel(accId, lang, key);
          if (v === key) reasons.push(`${key}[${lang}] missing (raw key) for ${accId}`);
        }
        // ban China-GAAP / China-VAT wording on the Chinese display strings
        for (const lang of ['zh-CN', 'zh-TW']) {
          const v = helpers.getTaxLabel(accId, lang, key);
          if (typeof v === 'string' && CN_GAAP_BAN.test(v)) {
            reasons.push(`${accId} ${key}[${lang}] uses China-GAAP wording: "${v}"`);
          }
        }
      }
      // pin the corrected non-CN wording (also asserts US fixes keep appearing)
      for (const lang of ['zh-CN', 'zh-TW']) {
        for (const [key, want] of Object.entries(PIN[lang])) {
          const got = helpers.getTaxLabel(accId, lang, key);
          if (got !== want) reasons.push(`${accId} ${key}[${lang}] should be "${want}", got "${got}"`);
        }
      }
      if (reasons.length) fail(`acctFinNonCn:${accId}`, reasons); else pass(`acctFinNonCn:${accId}`);
    }
    // CN regression guard: AccountsPage CN fallback i18n must KEEP China-GAAP
    // ledger wording (FinancePage balance-sheet zh-CN is locked in PART G1.5).
    {
      const cn = locales['zh-CN'];
      const reasons = [];
      if (get(cn, 'accounts.receivable') !== '应收账款') reasons.push(`CN accounts.receivable should stay 应收账款, got "${get(cn, 'accounts.receivable')}"`);
      if (get(cn, 'accounts.payable') !== '应付账款') reasons.push(`CN accounts.payable should stay 应付账款, got "${get(cn, 'accounts.payable')}"`);
      if (reasons.length) fail(`cnGaapAccountsPreserved`, reasons); else pass(`cnGaapAccountsPreserved`);
    }
  }

  // ────────────────────────────────────────────────
  // PART G0m: Accounts (应收应付) page — JP accountingLocale + Chinese UI.
  //   JP frames AR/AP by customer/supplier (taxConcept acct*), while the page's
  //   generic finance terms (page title / overdue / unpaid-count / rates / aging)
  //   come from the shared accounts.* / nav.* i18n and stay simplified/traditional
  //   Chinese under zh-CN/zh-TW (UI language ≠ accountingLocale). Guard: the
  //   displayed terms must surface, and neither the JP acct*/bal* taxConcepts nor
  //   the accounts.* i18n may carry CN-VAT (进项/销项/增值税/认证/电子发票) or non-JPY
  //   money (人民币/RMB/CNY). Money itself is formatted via accountingLocale (¥).
  // ────────────────────────────────────────────────
  {
    const reasons = [];
    // JP taxConcept AR/AP labels — customer/supplier framing (not 应收账款/应付账款).
    const ACCT_PIN = {
      'zh-CN': { acctReceivableTab: '客户应收', acctPayableTab: '供应商应付' },
      'zh-TW': { acctReceivableTab: '客戶應收', acctPayableTab: '供應商應付' },
    };
    // Generic AR/AP page terms (i18n) shown verbatim under the zh-CN/zh-TW UI.
    const I18N_PIN = {
      'zh-CN': { 'nav.accounts': '应收应付', 'accounts.overdueAmount': '逾期金额', 'accounts.unpaidCount': '未付笔数' },
      'zh-TW': { 'nav.accounts': '應收應付', 'accounts.overdueAmount': '逾期金額', 'accounts.unpaidCount': '未付筆數' },
    };
    const AR_AP_BAN = /进项|進項|销项|銷項|增值税|增值稅|认证|認證|电子发票|電子發票|人民币|人民幣|RMB|CNY/;
    const ACCT_TAX_KEYS = ['acctReceivableTab', 'acctPayableTab', 'acctTotalReceivable', 'acctTotalPayable', 'balRecvLabel', 'balPayLabel', 'balTaxPayLabel'];
    for (const lang of ['zh-CN', 'zh-TW']) {
      for (const [k, want] of Object.entries(ACCT_PIN[lang])) {
        const got = helpers.getTaxLabel('JP', lang, k);
        if (got !== want) reasons.push(`JP ${k}[${lang}] should be "${want}", got "${got}"`);
      }
      for (const [path, want] of Object.entries(I18N_PIN[lang])) {
        const got = get(locales[lang], path);
        if (got !== want) reasons.push(`accounts ${path}[${lang}] should be "${want}", got "${got}"`);
      }
      // ban CN-VAT / non-JPY money across the JP acct*/bal* taxConcepts
      for (const k of ACCT_TAX_KEYS) {
        const v = helpers.getTaxLabel('JP', lang, k);
        if (typeof v === 'string' && AR_AP_BAN.test(v)) reasons.push(`JP ${k}[${lang}] uses CN-VAT/non-JPY term: "${v}"`);
      }
      // ban CN-VAT / non-JPY money across the accounts.* i18n block (AR/AP page text)
      const acc = (locales[lang] || {}).accounts || {};
      for (const [k, v] of Object.entries(acc)) {
        if (typeof v === 'string' && AR_AP_BAN.test(v)) reasons.push(`accounts.${k}[${lang}] uses CN-VAT/non-JPY term: "${v}"`);
      }
    }
    if (reasons.length) fail(`arApJpWording`, reasons); else pass(`arApJpWording`);
  }

  // ────────────────────────────────────────────────
  // PART G0h: US Schedule C P&L line wording must keep appearing (the US
  //   财务报表页 income statement is Schedule C). Guards against regression of the
  //   already-fixed key lines (substring match — tolerant of the "Line N — " /
  //   "(or Loss)" formatting and em-dash).
  // ────────────────────────────────────────────────
  {
    const SC_PIN = {
      'zh-CN': { line1: '总收入或销售额', line7: '总收入', line28: '费用总额', line31: '净利润或亏损' },
      'zh-TW': { line1: '總收入或銷售額', line7: '總收入', line28: '費用總額', line31: '淨利潤或虧損' },
    };
    const reasons = [];
    for (const lang of ['zh-CN', 'zh-TW']) {
      for (const [k, want] of Object.entries(SC_PIN[lang])) {
        const v = get(locales[lang], `usSchedule.${k}`);
        if (typeof v !== 'string' || !v.includes(want)) {
          reasons.push(`usSchedule.${k}[${lang}] should contain "${want}", got "${v}"`);
        }
      }
    }
    if (reasons.length) fail(`usScheduleCPreserved`, reasons); else pass(`usScheduleCPreserved`);
  }

  // ────────────────────────────────────────────────
  // PART G0i: System Settings (系统设置) non-CN wording.
  //   For every non-CN accountingLocale (US/JP/KR/TW/EU) the company-info,
  //   tax-rule, accounting-category and data-migration labels must use the
  //   locale's own regime wording — never China company/tax口径 (统一社会信用代码 /
  //   法定代表人 / 增值税 / 进项 / 销项 / 认证 / 税金及附加 / 可抵扣 / 91110000 /
  //   北京市朝阳区) and never internal engineering terms in the Chinese migration
  //   copy (sales/purchases/transaction/source_meta/legacy_migrations/COGS/
  //   income/expense). JP/KR/TW/EU must surface their own tax / currency / tax-ID
  //   口径; US keeps its already-fixed wording. CN is guarded the other way below.
  // ────────────────────────────────────────────────
  {
    const SETTINGS_KEYS = [
      'setNavAi', 'setCompanyNamePh', 'setCreditCodeLabel', 'setCreditCodePh',
      'setLegalPersonLabel', 'setLegalPersonPh', 'setIndustryPh', 'setAddressPh',
      'setVatRateLabel', 'setRateByState', 'setRateCustom', 'setRateZero',
      'setAutoAuthLabel', 'setAutoAuthDesc', 'setAdminExpenseLabel', 'setPerYear',
      'setTaxHint', 'setDeductibleHeader', 'setDeductiblePctLabel',
      'notifStockZero', 'notifTaxDeviation', 'notifPriceVolatility', 'notifMonthlyReport',
    ];
    const DM_KEYS = [
      'dmSubtitle', 'dmCardSales', 'dmCardPurchases', 'dmNoLegacy', 'dmResultIncome',
      'dmResultExpense', 'dmRollbackConfirm', 'dmRollback', 'dmNote1', 'dmNote2', 'dmNote3', 'dmNote4',
    ];
    // China company / VAT / GAAP wording forbidden on non-CN settings strings.
    const CN_SETTINGS_BAN = /统一社会信用代码|統一社會信用代碼|法定代表人|增值税|增值稅|进项|進項|销项|銷項|认证|認證|税金及附加|稅金及附加|抵扣|91110000|北京市朝阳区|北京市朝陽區/;
    // Internal engineering terms forbidden in the Chinese migration copy (these
    // are normal words in English, so only the zh-CN / zh-TW strings are checked).
    const INTERNAL_BAN = /sales|purchases|transaction|source_meta|legacy_migrations|cogs|\bincome\b|\bexpense\b/i;
    // Each non-CN locale must surface its own regime wording (zh-CN display).
    const REGIME = {
      US: { vat: /Sales Tax/i, cur: /美元|USD/, id: /EIN/ },
      JP: { vat: /消费税|消費税/, cur: /日元|日圓|円|JPY/, id: /法人(编号|番号)/ },
      KR: { vat: /VAT/i, cur: /韩元|韓元|원|KRW/, id: /营业登记|營業登記|사업자등록/ },
      TW: { vat: /营业税|營業稅/, cur: /新台币|新臺幣|TWD/, id: /统一编号|統一編號/ },
      EU: { vat: /VAT/i, cur: /欧元|歐元|EUR/, id: /VAT ID/i },
    };
    for (const accId of ['US', 'JP', 'KR', 'TW', 'EU']) {
      const reasons = [];
      // presence (no raw key) for every settings + migration key, all UI languages
      for (const key of [...SETTINGS_KEYS, ...DM_KEYS]) {
        for (const lang of UI_LANGUAGES) {
          const v = helpers.getTaxLabel(accId, lang, key);
          if (v === key) reasons.push(`${key}[${lang}] missing (raw key) for ${accId}`);
        }
      }
      // ban China company/tax wording on the Chinese settings display strings
      for (const key of SETTINGS_KEYS) {
        for (const lang of ['zh-CN', 'zh-TW']) {
          const v = helpers.getTaxLabel(accId, lang, key);
          if (typeof v === 'string' && CN_SETTINGS_BAN.test(v)) {
            reasons.push(`${accId} ${key}[${lang}] uses China company/tax wording: "${v}"`);
          }
        }
      }
      // ban internal engineering terms in the Chinese migration copy
      for (const key of DM_KEYS) {
        for (const lang of ['zh-CN', 'zh-TW']) {
          const v = helpers.getTaxLabel(accId, lang, key);
          if (typeof v === 'string' && INTERNAL_BAN.test(v)) {
            reasons.push(`${accId} ${key}[${lang}] leaks internal term: "${v}"`);
          }
        }
      }
      // each locale must surface its own regime wording (tax / currency / tax-ID)
      const r = REGIME[accId];
      const vat = helpers.getTaxLabel(accId, 'zh-CN', 'setVatRateLabel');
      const cur = helpers.getTaxLabel(accId, 'zh-CN', 'setPerYear');
      const id = helpers.getTaxLabel(accId, 'zh-CN', 'setCreditCodeLabel');
      if (!r.vat.test(vat)) reasons.push(`${accId} setVatRateLabel[zh-CN] should match ${r.vat}: "${vat}"`);
      if (!r.cur.test(cur)) reasons.push(`${accId} setPerYear[zh-CN] should match ${r.cur}: "${cur}"`);
      if (!r.id.test(id)) reasons.push(`${accId} setCreditCodeLabel[zh-CN] should match ${r.id}: "${id}"`);
      if (reasons.length) fail(`settingsNonCn:${accId}`, reasons); else pass(`settingsNonCn:${accId}`);
    }
    // CN regression guard: CN settings i18n must KEEP China company/tax wording.
    {
      const cn = locales['zh-CN'];
      const reasons = [];
      if (get(cn, 'settings.company.creditCode') !== '统一社会信用代码') reasons.push(`CN settings.company.creditCode should stay 统一社会信用代码, got "${get(cn, 'settings.company.creditCode')}"`);
      if (get(cn, 'settings.company.legalPerson') !== '法定代表人') reasons.push(`CN settings.company.legalPerson should stay 法定代表人, got "${get(cn, 'settings.company.legalPerson')}"`);
      if (!/增值税/.test(get(cn, 'settings.tax.vatRate') || '')) reasons.push(`CN settings.tax.vatRate should keep 增值税, got "${get(cn, 'settings.tax.vatRate')}"`);
      if (get(cn, 'settings.tax.autoAuth') !== '进项发票自动认证') reasons.push(`CN settings.tax.autoAuth should stay 进项发票自动认证, got "${get(cn, 'settings.tax.autoAuth')}"`);
      if (!/税金及附加/.test(get(cn, 'settings.tax.hint') || '')) reasons.push(`CN settings.tax.hint should keep 税金及附加, got "${get(cn, 'settings.tax.hint')}"`);
      if (reasons.length) fail(`cnSettingsPreserved`, reasons); else pass(`cnSettingsPreserved`);
    }
  }

  // ────────────────────────────────────────────────
  // PART G0j: Invoice-query (票据查询) non-CN wording.
  //   For every non-CN accountingLocale (US/JP/KR/TW/EU) the stat cards, status
  //   filter/badges, record-count subtitles and the table type column must use
  //   generic document wording — never CN-VAT 进项/销项/认证/抵扣/待认证/已认证/
  //   已抵扣/预计可抵扣/发票号(码). JP/KR/TW/EU/US share the NON_CN_GENERIC document
  //   framing (采购/费用·销售/收入·票据·待处理). US keeps income/expense framing for
  //   the type column. CN keeps its VAT-invoice口径 (guarded the other way below).
  // ────────────────────────────────────────────────
  {
    const INV_KEYS = [
      'invTotalInput', 'invTotalOutput', 'invPendingTax', 'invPendingTaxSub',
      'invNoInput', 'invNoOutput', 'invDateRange', 'invWeightRange', 'invStatusFilter',
      'invStatusAll', 'invStatusVerified', 'invStatusCertified', 'invStatusDeducted',
      'invStatusPendingCert', 'invStatusPendingIssue', 'invStatusIssued',
      'invAdvFilterActive', 'invInputRecordCount', 'invOutputRecordCount',
      'invoiceTypeInput', 'invoiceTypeOutput',
    ];
    const COUNT_KEYS = ['invAdvFilterActive', 'invInputRecordCount', 'invOutputRecordCount'];
    const CN_INV_BAN = /进项|進項|销项|銷項|认证|認證|抵扣|发票号|發票號|电子发票|電子發票/;
    for (const accId of ['US', 'JP', 'KR', 'TW', 'EU']) {
      const reasons = [];
      for (const key of INV_KEYS) {
        for (const lang of UI_LANGUAGES) {
          const v = helpers.getTaxLabel(accId, lang, key);
          if (v === key) reasons.push(`${key}[${lang}] missing (raw key) for ${accId}`);
        }
        for (const lang of ['zh-CN', 'zh-TW']) {
          const v = helpers.getTaxLabel(accId, lang, key);
          if (typeof v === 'string' && CN_INV_BAN.test(v)) {
            reasons.push(`${accId} ${key}[${lang}] uses CN-VAT invoice wording: "${v}"`);
          }
        }
      }
      // interpolated count templates must keep the {count} token
      for (const key of COUNT_KEYS) {
        for (const lang of ['zh-CN', 'zh-TW', 'en']) {
          const v = helpers.getTaxLabel(accId, lang, key);
          if (typeof v === 'string' && !v.includes('{count}')) {
            reasons.push(`${accId} ${key}[${lang}] missing {count} token: "${v}"`);
          }
        }
      }
      // positive: generic document framing must surface (zh-CN display)
      const totIn = helpers.getTaxLabel(accId, 'zh-CN', 'invTotalInput');
      const pend = helpers.getTaxLabel(accId, 'zh-CN', 'invPendingTax');
      const tin = helpers.getTaxLabel(accId, 'zh-CN', 'invoiceTypeInput');
      const tout = helpers.getTaxLabel(accId, 'zh-CN', 'invoiceTypeOutput');
      if (!/采购|费用/.test(totIn)) reasons.push(`${accId} invTotalInput[zh-CN] should use 采购/费用: "${totIn}"`);
      if (!/待处理/.test(pend)) reasons.push(`${accId} invPendingTax[zh-CN] should use 待处理: "${pend}"`);
      if (accId === 'US') {
        // US frames the type column as income/expense, not 采购/销售.
        if (!/费用/.test(tin)) reasons.push(`US invoiceTypeInput[zh-CN] should be 费用-framed: "${tin}"`);
        if (!/收入/.test(tout)) reasons.push(`US invoiceTypeOutput[zh-CN] should be 收入-framed: "${tout}"`);
      } else {
        if (!/采购/.test(tin)) reasons.push(`${accId} invoiceTypeInput[zh-CN] should be 采购: "${tin}"`);
        if (!/销售/.test(tout)) reasons.push(`${accId} invoiceTypeOutput[zh-CN] should be 销售: "${tout}"`);
      }
      if (reasons.length) fail(`invoiceQueryNonCn:${accId}`, reasons); else pass(`invoiceQueryNonCn:${accId}`);
    }
    // CN regression guard: CN keeps its VAT-invoice口径 (config type labels + i18n).
    {
      const cn = locales['zh-CN'];
      const reasons = [];
      if (helpers.getTaxLabel('CN', 'zh-CN', 'invoiceTypeInput') !== '进项') reasons.push(`CN invoiceTypeInput should stay 进项`);
      if (helpers.getTaxLabel('CN', 'zh-CN', 'invoiceTypeOutput') !== '销项') reasons.push(`CN invoiceTypeOutput should stay 销项`);
      if (get(cn, 'invoices.totalInput') !== '累计进项吨数') reasons.push(`CN invoices.totalInput should stay 累计进项吨数, got "${get(cn, 'invoices.totalInput')}"`);
      if (get(cn, 'invoices.pendingTax') !== '待认证进项额') reasons.push(`CN invoices.pendingTax should stay 待认证进项额, got "${get(cn, 'invoices.pendingTax')}"`);
      if (!/抵扣/.test(get(cn, 'invoices.deductible') || '')) reasons.push(`CN invoices.deductible should keep 抵扣, got "${get(cn, 'invoices.deductible')}"`);
      if (!/认证/.test(get(cn, 'invoices.authenticated') || '')) reasons.push(`CN invoices.authenticated should keep 认证, got "${get(cn, 'invoices.authenticated')}"`);
      if (reasons.length) fail(`cnInvoiceQueryPreserved`, reasons); else pass(`cnInvoiceQueryPreserved`);
    }
  }

  // ────────────────────────────────────────────────
  // PART G0k: Invoice-query status dropdown localization.
  //   CN accountingLocale renders the dropdown from the invoices.* i18n keys, so
  //   each status MUST resolve in every UI language — a missing key leaked the raw
  //   invoices.statusVerified / statusCertified / statusDeducted / statusPendingCert
  //   / statusPendingInvoice in the CN dropdown. CN keeps China-VAT status wording;
  //   non-CN renders the generic invStatus* taxConcepts (must differ from CN's
  //   认证/抵扣 wording — also guarded in PART G0j).
  // ────────────────────────────────────────────────
  {
    const STATUS_I18N = ['allStatus', 'statusVerified', 'statusCertified', 'statusDeducted', 'statusPendingCert', 'statusPendingInvoice', 'statusIssued'];
    const reasons = [];
    // CN dropdown: every status option resolves (non-empty, no raw key) in all langs
    for (const lang of UI_LANGUAGES) {
      const inv = (locales[lang] || {}).invoices || {};
      for (const k of STATUS_I18N) {
        const v = inv[k];
        if (v === undefined || (typeof v === 'string' && v.trim() === '')) {
          reasons.push(`invoices.${k} missing/empty in ${lang} (CN status dropdown would render raw key)`);
        }
      }
    }
    // CN zh-CN must keep the China-VAT status wording
    const cnInv = (locales['zh-CN'] || {}).invoices || {};
    const CN_PIN = {
      allStatus: '全部状态', statusVerified: '已核验', statusCertified: '已认证',
      statusDeducted: '已抵扣', statusPendingCert: '待认证', statusPendingInvoice: '待开票', statusIssued: '已开票',
    };
    for (const [k, want] of Object.entries(CN_PIN)) {
      if (cnInv[k] !== want) reasons.push(`CN invoices.${k} should be "${want}", got "${cnInv[k]}"`);
    }
    if (reasons.length) fail(`cnStatusDropdown`, reasons); else pass(`cnStatusDropdown`);
  }
  {
    // non-CN dropdown: the generic invStatus* taxConcepts resolve and must NOT
    // carry CN-VAT 认证/抵扣 wording, so each non-CN locale shows document statuses.
    const STATUS_TAX = ['invStatusAll', 'invStatusVerified', 'invStatusCertified', 'invStatusDeducted', 'invStatusPendingCert', 'invStatusPendingIssue', 'invStatusIssued'];
    for (const accId of ['US', 'JP', 'KR', 'TW', 'EU']) {
      const reasons = [];
      for (const key of STATUS_TAX) {
        for (const lang of ['zh-CN', 'zh-TW']) {
          const v = helpers.getTaxLabel(accId, lang, key);
          if (v === key) reasons.push(`${accId} ${key}[${lang}] raw key (non-CN status dropdown)`);
          if (typeof v === 'string' && /认证|認證|抵扣/.test(v)) reasons.push(`${accId} ${key}[${lang}] uses CN-VAT 认证/抵扣: "${v}"`);
        }
      }
      if (reasons.length) fail(`nonCnStatusDropdown:${accId}`, reasons); else pass(`nonCnStatusDropdown:${accId}`);
    }
  }

  // ────────────────────────────────────────────────
  // PART G0l: AI assistant document-extraction result (chat.invoiceExtractResult).
  //   CN renders the chat.invoiceExtractResult i18n message (keeps 发票 / 采购与进项
  //   / 销售与销项 / 发票号). Non-CN renders the chatExtractResult taxConcept, which
  //   must use the generic 票据 / 采购与费用 / 销售与收入 framing — never CN-VAT
  //   采购与进项 / 销售与销项 / 进项 / 销项 / 增值税 / 电子发票 / 发票号(码) — and must
  //   keep all six {date/partner/quantity/amount/shipping/invoiceNo} tokens so the
  //   substituted message renders no leftover placeholder.
  // ────────────────────────────────────────────────
  {
    const TOKENS = ['{date}', '{partner}', '{quantity}', '{amount}', '{shipping}', '{invoiceNo}'];
    const CHAT_BAN = /采购与进项|採購與進項|销售与销项|銷售與銷項|进项|進項|销项|銷項|增值税|增值稅|电子发票|電子發票|发票号|發票號/;
    for (const accId of ['US', 'JP', 'KR', 'TW', 'EU']) {
      const reasons = [];
      for (const lang of UI_LANGUAGES) {
        const v = helpers.getTaxLabel(accId, lang, 'chatExtractResult');
        if (v === 'chatExtractResult') { reasons.push(`chatExtractResult[${lang}] missing (raw key) for ${accId}`); continue; }
        for (const tok of TOKENS) {
          if (!v.includes(tok)) reasons.push(`${accId} chatExtractResult[${lang}] missing ${tok} token`);
        }
        // after substituting every token, no stray {…} placeholder should remain
        let rendered = v;
        for (const tok of TOKENS) rendered = rendered.split(tok).join('X');
        if (/\{[a-zA-Z]+\}/.test(rendered)) reasons.push(`${accId} chatExtractResult[${lang}] has an unsubstituted placeholder: "${v}"`);
      }
      // Chinese display must avoid CN-VAT wording and surface the generic 票据 framing
      for (const lang of ['zh-CN', 'zh-TW']) {
        const v = helpers.getTaxLabel(accId, lang, 'chatExtractResult');
        if (typeof v === 'string' && CHAT_BAN.test(v)) reasons.push(`${accId} chatExtractResult[${lang}] uses CN-VAT invoice wording: "${v}"`);
        if (typeof v === 'string' && !/票据|票據/.test(v)) reasons.push(`${accId} chatExtractResult[${lang}] should use 票据 wording: "${v}"`);
      }
      // zh-CN must reference the non-CN nav names, not 采购与进项 / 销售与销项
      const zh = helpers.getTaxLabel(accId, 'zh-CN', 'chatExtractResult');
      if (typeof zh === 'string') {
        if (!/采购与费用/.test(zh)) reasons.push(`${accId} chatExtractResult[zh-CN] should reference 采购与费用: "${zh}"`);
        if (!/销售与收入/.test(zh)) reasons.push(`${accId} chatExtractResult[zh-CN] should reference 销售与收入: "${zh}"`);
      }
      if (reasons.length) fail(`chatExtractNonCn:${accId}`, reasons); else pass(`chatExtractNonCn:${accId}`);
    }
    // CN regression guard: CN keeps its VAT-invoice chat message + nav口径.
    {
      const cn = locales['zh-CN'];
      const reasons = [];
      const msg = get(cn, 'chat.invoiceExtractResult');
      if (typeof msg !== 'string') reasons.push(`CN chat.invoiceExtractResult missing`);
      else {
        if (!/采购与进项/.test(msg)) reasons.push(`CN chat.invoiceExtractResult should keep 采购与进项, got "${msg}"`);
        if (!/销售与销项/.test(msg)) reasons.push(`CN chat.invoiceExtractResult should keep 销售与销项, got "${msg}"`);
      }
      if (reasons.length) fail(`cnChatExtractPreserved`, reasons); else pass(`cnChatExtractPreserved`);
    }
  }

  // ────────────────────────────────────────────────
  // PART G1: Data Analysis page subtitles — must not contain hardcoded
  // English "TONS" or "吨" since the inventory unit comes from
  // product_unit (uiLanguage-driven via getInventoryUnitLabel).
  // ────────────────────────────────────────────────
  for (const lang of UI_LANGUAGES) {
    const data = locales[lang];
    const reasons = [];
    const subtitleLog = get(data, 'analysis.subtitleLogistics');
    if (typeof subtitleLog === 'string') {
      if (/\bTONS\b|\bTons\b/.test(subtitleLog)) reasons.push(`analysis.subtitleLogistics hardcodes TONS: "${subtitleLog}"`);
      if (lang === 'zh-CN' && /吨/.test(subtitleLog)) reasons.push(`analysis.subtitleLogistics hardcodes 吨: "${subtitleLog}"`);
      if (lang === 'zh-TW' && /噸/.test(subtitleLog)) reasons.push(`analysis.subtitleLogistics hardcodes 噸: "${subtitleLog}"`);
    }
    // aiDashboard heading should not be uppercase English in CJK locales
    const aiDash = get(data, 'analysis.aiDashboard');
    if (typeof aiDash === 'string' && ['zh-CN', 'zh-TW', 'ja', 'ko'].includes(lang)) {
      // The "AI" prefix is OK; the rest must contain native script
      if (/^[A-Z\s]+$/.test(aiDash)) reasons.push(`analysis.aiDashboard is all-caps English in ${lang}: "${aiDash}"`);
    }
    // severity / correlation labels: non-en locales must not be English literals
    if (lang !== 'en') {
      const englishLiterals = {
        severityLow: /^Low$/i,
        severityMid: /^Mid$/i,
        severityHigh: /^High$/i,
        corrStrong: /^Strong$/i,
        corrModerate: /^Moderate$/i,
        corrWeak: /^Weak$/i,
      };
      for (const [key, pattern] of Object.entries(englishLiterals)) {
        const v = get(data, `analysis.${key}`);
        if (typeof v === 'string' && pattern.test(v.trim())) {
          reasons.push(`analysis.${key} is English literal in ${lang}: "${v}"`);
        }
      }
    }
    if (reasons.length) fail(`analysisWording:${lang}`, reasons); else pass(`analysisWording:${lang}`);
  }

  // ────────────────────────────────────────────────
  // PART G1.5: zh-CN balance sheet labels lock-in.
  //   Pin specific Chinese-GAAP accounting terminology so future edits
  //   can't drift to colloquial or shareholder-equity wording.
  // ────────────────────────────────────────────────
  {
    const data = locales['zh-CN'];
    const reasons = [];
    const PINNED = {
      'finance.balanceCash': '货币资金',
      'finance.balanceReceivable': '应收账款',
      'finance.balanceReceivables': '应收账款',
      'finance.balanceInventory': '存货',
      'finance.balanceFixed': '固定资产',
      'finance.balanceFixedAssets': '固定资产',
      'finance.balancePayable': '应付账款',
      'finance.balancePayables': '应付账款',
      'finance.balanceTax': '应交税费',
      'finance.balanceTaxPayable': '应交税费',
      'finance.balanceCapital': '实收资本',
      'finance.balancePaidInCapital': '实收资本',
      'finance.balanceRetained': '未分配利润',
      'finance.balanceRetainedEarnings': '未分配利润',
      'finance.balanceEquity': '所有者权益',
      'finance.balanceTotalLiab': '负债及所有者权益总计',
      'finance.balanceTotalLiabilitiesEquity': '负债及所有者权益总计',
    };
    for (const [path, expected] of Object.entries(PINNED)) {
      const v = get(data, path);
      if (v !== expected) reasons.push(`${path} should be "${expected}", got "${v}"`);
    }
    // Forbidden colloquial / corporate-only variants
    const FORBIDDEN = [
      { pattern: /应交税款/, msg: '应交税款 — use the GAAP-standard 应交税费 instead' },
      { pattern: /股东权益/, msg: '股东权益 — use 所有者权益 (Chinese accounting standard) unless explicitly modeling a 公司制 entity' },
    ];
    for (const path of [
      'finance.balanceTax', 'finance.balanceTaxPayable',
      'finance.balanceEquity', 'finance.balanceLiabilitiesEquity',
      'finance.balanceTotalLiab', 'finance.balanceTotalLiabilitiesEquity',
    ]) {
      const v = get(data, path);
      if (typeof v !== 'string') continue;
      for (const rule of FORBIDDEN) {
        if (rule.pattern.test(v)) reasons.push(`${path} contains forbidden term: ${rule.msg} (got: "${v}")`);
      }
    }
    if (reasons.length) fail(`balanceSheetLockIn:zh-CN`, reasons); else pass(`balanceSheetLockIn:zh-CN`);
  }

  // ────────────────────────────────────────────────
  // PART G2: Cashflow empty-state wording — must NOT imply third-party sync.
  //   SoloLedger is a standalone ledger; the empty state should ask the user
  //   to add records, not connect to "accounting software API".
  // ────────────────────────────────────────────────
  const FORBIDDEN_CASHFLOW_PHRASES = [
    /会计软件\s*API|财务软件\s*API/,           // zh-CN
    /會計軟體\s*API|財務軟體\s*API/,           // zh-TW
    /accounting (software|API)/i,               // en
    /会計ソフト/,                                 // ja
    /회계 소프트웨어/,                            // ko
    /logiciel comptable/i,                       // fr
    /同步现金流|同步現金流|sync.*cash flow|キャッシュフロー.*同期/i,
    /模拟预览|模擬預覽|preview mode|プレビューモード|미리보기 모드|mode aperçu/i,
  ];
  for (const lang of UI_LANGUAGES) {
    const data = locales[lang];
    const reasons = [];
    for (const key of ['cashflowTitle', 'cashflowDesc', 'cashflowSubtitle', 'cashflowSync']) {
      const val = get(data, `finance.${key}`);
      if (typeof val !== 'string') continue;
      for (const pattern of FORBIDDEN_CASHFLOW_PHRASES) {
        if (pattern.test(val)) {
          reasons.push(`finance.${key} contains forbidden phrase ${pattern}: "${val}"`);
          break;
        }
      }
    }
    if (reasons.length) fail(`cashflowWording:${lang}`, reasons); else pass(`cashflowWording:${lang}`);
  }

  // ────────────────────────────────────────────────
  // PART G3: tableHeaders amount-without-tax wording
  //   zh-CN must say "不含税单价 / 合计不含税金额", not the older
  //   "无税单价 / 合计无税金额". zh-TW must say "不含稅單價 /
  //   合計不含稅金額", not "未稅單價 / 未稅合計".
  // ────────────────────────────────────────────────
  {
    const zhCN = locales['zh-CN'];
    const zhTW = locales['zh-TW'];
    const reasonsCN = [];
    const reasonsTW = [];
    for (const key of ['unitPrice', 'unitPriceWithoutTax']) {
      const v = get(zhCN, `tableHeaders.${key}`);
      if (typeof v === 'string') {
        if (!/不含税单价/.test(v)) reasonsCN.push(`tableHeaders.${key} should say 不含税单价: "${v}"`);
        if (/无税单价/.test(v)) reasonsCN.push(`tableHeaders.${key} uses deprecated 无税 wording: "${v}"`);
      }
      const vw = get(zhTW, `tableHeaders.${key}`);
      if (typeof vw === 'string') {
        if (!/不含稅單價/.test(vw)) reasonsTW.push(`tableHeaders.${key} should say 不含稅單價: "${vw}"`);
        if (/未稅單價/.test(vw)) reasonsTW.push(`tableHeaders.${key} uses deprecated 未稅 wording: "${vw}"`);
      }
    }
    for (const key of ['amount', 'amountWithoutTax', 'totalAmountWithoutTax']) {
      const v = get(zhCN, `tableHeaders.${key}`);
      if (typeof v === 'string') {
        if (!/合计不含税金额|不含税金额/.test(v)) reasonsCN.push(`tableHeaders.${key} should say 合计不含税金额: "${v}"`);
        if (/合计无税金额|无税金额/.test(v)) reasonsCN.push(`tableHeaders.${key} uses deprecated 无税 wording: "${v}"`);
      }
      const vw = get(zhTW, `tableHeaders.${key}`);
      if (typeof vw === 'string') {
        if (!/合計不含稅金額|不含稅金額/.test(vw)) reasonsTW.push(`tableHeaders.${key} should say 合計不含稅金額: "${vw}"`);
        if (/未稅合計|未稅金額/.test(vw)) reasonsTW.push(`tableHeaders.${key} uses deprecated 未稅 wording: "${vw}"`);
      }
    }
    if (reasonsCN.length) fail(`tableHeadersWording:zh-CN`, reasonsCN); else pass(`tableHeadersWording:zh-CN`);
    if (reasonsTW.length) fail(`tableHeadersWording:zh-TW`, reasonsTW); else pass(`tableHeadersWording:zh-TW`);
  }

  // ────────────────────────────────────────────────
  // PART H: No English fallback in non-English locales for balance-sheet keys
  // ────────────────────────────────────────────────
  for (const [lang, keys] of Object.entries(NO_ENGLISH_FALLBACK_KEYS)) {
    const data = locales[lang];
    const reasons = [];
    for (const key of keys) {
      const val = get(data, key);
      if (val === undefined) continue; // already reported in PART G
      // English-only pattern: all latin letters / spaces / punctuation
      if (/^[A-Za-z\s&\-()'.]+$/.test(val)) {
        reasons.push(`${key} is English-only in ${lang}: "${val}"`);
      }
      // Mixed-language hard-coded pattern: contains Chinese + parenthesized English
      if (lang === 'zh-CN' || lang === 'zh-TW') {
        if (/[一-鿿].*\([A-Za-z\s]+\)/.test(val) || /\([A-Za-z\s]+\).*[一-鿿]/.test(val)) {
          reasons.push(`${key} mixes Chinese with English parenthetical: "${val}"`);
        }
      }
    }
    if (reasons.length) fail(`noEnglishFallback:${lang}`, reasons); else pass(`noEnglishFallback:${lang}`);
  }

  // ────────────────────────────────────────────────
  // PART I: zh-TW must not contain simplified-only characters in core sections
  // ────────────────────────────────────────────────
  {
    const data = locales['zh-TW'];
    const sectionsToCheck = ['finance', 'tableHeaders', 'chat', 'voice', 'purchases', 'sales', 'invoices', 'dashboard'];
    const reasons = [];
    for (const sec of sectionsToCheck) {
      const section = data[sec];
      if (!section) continue;
      for (const [k, v] of Object.entries(section)) {
        if (typeof v !== 'string') continue;
        const m = v.match(SIMPLIFIED_ONLY_CHARS);
        if (m) reasons.push(`zh-TW.${sec}.${k} contains simplified char "${m[0]}": "${v}"`);
      }
    }
    if (reasons.length) fail(`zh-TW-simplified-chars`, reasons); else pass(`zh-TW-simplified-chars`);
  }

  // ────────────────────────────────────────────────
  // Report
  // ────────────────────────────────────────────────
  console.log(`\n=== Locale Matrix Check ===\n`);
  console.log(`UI Languages:        ${UI_LANGUAGES.join(', ')}`);
  console.log(`Accounting Locales:  ${ACCOUNTING_LOCALES.join(', ')}`);
  console.log(`Total checks: ${RESULTS.pass.length + RESULTS.fail.length}`);
  console.log(`  PASS: ${RESULTS.pass.length}`);
  console.log(`  FAIL: ${RESULTS.fail.length}\n`);

  if (RESULTS.fail.length === 0) {
    console.log('✓ All checks passed.');
    process.exit(0);
  }

  console.log('--- Failures ---\n');
  for (const f of RESULTS.fail) {
    console.log(`FAIL ${f.name}`);
    for (const r of f.reasons) console.log(`  - ${r}`);
  }
  process.exit(1);
}

main().catch(e => {
  console.error('Checker crashed:', e);
  process.exit(2);
});
