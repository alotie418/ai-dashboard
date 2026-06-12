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
  'chat.thinking', 'chat.resize', 'chat.emptyReply', 'chat.requestError',
  'chat.uploadInvoiceMsg', 'chat.fileReadTimeout', 'chat.fileFormatUnsupported', 'chat.fileReadFailed',
  'chat.notInvoice', 'chat.invoiceExtractResult', 'chat.invoiceRecognizeFailed',
  'chat.quickPromptUploadInvoice', 'chat.quickPromptFinanceQuery', 'chat.quickPromptTrend',
  'chat.quickPromptMarket', 'chat.quickPromptInventory',
  // ai （语音已移除：voice.* 与 ai.liveSystemPrompt 不再要求）
  'ai.chatSystemPrompt', 'ai.contextFallback', 'ai.analyzeSystemPrompt',
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
  // R3b: data-analysis forecast — idle CTA + i18n-driven prompt prose (follows uiLanguage)
  'analysis.forecastIdle', 'analysis.runForecast',
  'analysis.forecastPromptIntro', 'analysis.forecastPromptHistoryTitle', 'analysis.forecastPromptHistoryLegend',
  'analysis.forecastPromptFinTitle', 'analysis.forecastPromptFeaturesTitle', 'analysis.forecastPromptFeaturesLegend',
  'analysis.forecastPromptVarTitle', 'analysis.forecastPromptVarLegend',
  'analysis.forecastPromptMcTitle', 'analysis.forecastPromptMcLegend', 'analysis.forecastPromptRequirements',
  // R3c: AI error codes — stable code → i18n message (all surfaces, follows uiLanguage)
  'aiError.noProvider', 'aiError.auth', 'aiError.permission', 'aiError.quota',
  'aiError.modelNotFound', 'aiError.badRequest', 'aiError.serverError',
  'aiError.parseFailed', 'aiError.network', 'aiError.timeout', 'aiError.unknown',
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
              setVatRateLabel: '销售税税率（Sales Tax）', setRateByState: '按州设置', setRateCustom: '自定义税率', setRateZero: '0%',
              setAutoAuthLabel: '票据自动处理', setAdminExpenseLabel: '年度经营费用', setPerYear: '美元/年',
              setDeductibleHeader: '可扣除', setCatGrossReceipts: '总收入 / 销售额', setCatHomeOffice: '家庭办公室',
              setNavAi: 'AI 服务商（BYOK）', setAddKey: '添加密钥', setEditKey: '修改密钥', setWebGrounding: '支持联网检索',
              setCompanyNamePh: '例如：ABC Trading LLC', setLegalPersonPh: '例如：张三 / John Smith', setIndustryPh: '例如：咨询 / 零售 / 服务',
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
              setVatRateLabel: '銷售稅稅率（Sales Tax）', setRateByState: '按州設置', setRateCustom: '自訂稅率', setRateZero: '0%',
              setAutoAuthLabel: '票據自動處理', setAdminExpenseLabel: '年度經營費用', setPerYear: '美元/年',
              setDeductibleHeader: '可扣除', setCatGrossReceipts: '總收入 / 銷售額', setCatHomeOffice: '家庭辦公室',
              setNavAi: 'AI 服務商（BYOK）', setAddKey: '新增密鑰', setEditKey: '修改密鑰', setWebGrounding: '支援聯網檢索',
              setCompanyNamePh: '例如：ABC Trading LLC', setLegalPersonPh: '例如：王小明 / John Smith', setIndustryPh: '例如：顧問 / 零售 / 服務',
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
          // 自雇税 module: zh labels read Chinese-first — 中文术语（English，rate）.
          if (uiLang === 'zh-CN') {
            if (helpers.getTaxLabel(accId, uiLang, 'socialSecurity') !== '社会保障税（Social Security，12.4%）') reasons.push(`US socialSecurity[zh-CN] should be 社会保障税（Social Security，12.4%）, got "${helpers.getTaxLabel(accId, uiLang, 'socialSecurity')}"`);
            if (helpers.getTaxLabel(accId, uiLang, 'medicare') !== '医疗保险税（Medicare，2.9%）') reasons.push(`US medicare[zh-CN] should be 医疗保险税（Medicare，2.9%）, got "${helpers.getTaxLabel(accId, uiLang, 'medicare')}"`);
          }
          if (uiLang === 'zh-TW') {
            if (helpers.getTaxLabel(accId, uiLang, 'socialSecurity') !== '社會保障稅（Social Security，12.4%）') reasons.push(`US socialSecurity[zh-TW] should be 社會保障稅（Social Security，12.4%）, got "${helpers.getTaxLabel(accId, uiLang, 'socialSecurity')}"`);
            if (helpers.getTaxLabel(accId, uiLang, 'medicare') !== '醫療保險稅（Medicare，2.9%）') reasons.push(`US medicare[zh-TW] should be 醫療保險稅（Medicare，2.9%）, got "${helpers.getTaxLabel(accId, uiLang, 'medicare')}"`);
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
  // No hardcoded default unit: legacy 'ton' and the generic 'unit' (and null/unset)
  // render as NO label (pure quantity). Only an explicit real unit (e.g. bag) shows.
  const unitExpectations = {
    'zh-CN': { unit: '', ton: '', bag: '袋' },
    'zh-TW': { unit: '', ton: '', bag: '袋' },
    en: { unit: '', ton: '', bag: 'bags' },
    ja: { unit: '', ton: '', bag: '袋' },
    ko: { unit: '', ton: '', bag: '포대' },
    fr: { unit: '', ton: '', bag: 'sacs' },
  };
  for (const uiLang of UI_LANGUAGES) {
    const reasons = [];
    for (const [unitKey, expected] of Object.entries(unitExpectations[uiLang])) {
      const got = helpers.getInventoryUnitLabel(unitKey, uiLang);
      if (got !== expected) reasons.push(`unit ${unitKey} expected "${expected}", got "${got}"`);
    }
    // null/undefined/unset → no unit label (pure quantity)
    const nullFallback = helpers.getInventoryUnitLabel(null, uiLang);
    if (nullFallback !== '') reasons.push(`null/unset should have no unit label, got "${nullFallback}"`);
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
    const usP = accProfiles.getProfile('US');
    // Notes shown under en/ja/ko/fr fall back to `.notes`; zh-CN/zh-TW use `notesByLang`.
    // Each variant must keep the same accounting intent regardless of wording.
    const usNotesVariants = [
      usP.notes || '',
      usP.notesByLang?.['zh-CN'] || '',
      usP.notesByLang?.['zh-TW'] || '',
    ].filter(Boolean);
    for (const usNotes of usNotesVariants) {
      // never read as if the US has a federal VAT
      if (/美国联邦\s*VAT|美國聯邦\s*VAT/.test(usNotes)) reasons.push(`US profile.notes implies a US federal VAT: "${usNotes}"`);
      // must state the US has NO federal VAT (either 无联邦 VAT or 没有联邦增值税)
      if (!/无联邦\s*VAT|無聯邦\s*VAT|没有联邦增值税|沒有聯邦增值稅/.test(usNotes)) reasons.push(`US profile.notes should state the US has no federal VAT: "${usNotes}"`);
      // must mention the federal corporate income tax (21%)
      if (!/Federal Corporate Tax|联邦公司所得税|聯邦公司所得稅/.test(usNotes)) reasons.push(`US profile.notes should mention federal corporate income tax: "${usNotes}"`);
      // must not import CN-specific input/output-tax surcharge wording
      if (/进项|進項|销项|銷項|税金及附加|稅金及附加|抵扣/.test(usNotes)) reasons.push(`US profile.notes uses CN-VAT wording: "${usNotes}"`);
    }
    // US card shows a "by state" hint instead of a misleading 0%, plus a local-tax label (zh only)
    if (usP.vatRateDisplay?.['zh-CN'] !== '按州设置') reasons.push(`US card vatRateDisplay[zh-CN] should be 按州设置: "${usP.vatRateDisplay?.['zh-CN']}"`);
    if (usP.vatRateDisplay?.['zh-TW'] !== '按州設定') reasons.push(`US card vatRateDisplay[zh-TW] should be 按州設定: "${usP.vatRateDisplay?.['zh-TW']}"`);
    if (usP.surchargeLabel?.['zh-CN'] !== '地方税率') reasons.push(`US surchargeLabel[zh-CN] should be 地方税率: "${usP.surchargeLabel?.['zh-CN']}"`);
    if (usP.surchargeLabel?.['zh-TW'] !== '地方稅率') reasons.push(`US surchargeLabel[zh-TW] should be 地方稅率: "${usP.surchargeLabel?.['zh-TW']}"`);
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
    // reverse guards: JP/TW keep the shared slash form (EU override must not leak to them).
    // KR has its own invoice-query override (guarded in krInvoiceQuery), so it is not checked here.
    if (helpers.getTaxLabel('JP', 'zh-CN', 'invTotalInput') !== '累计采购/费用票据') reasons.push(`JP invTotalInput[zh-CN] should stay 累计采购/费用票据 (NON_CN_GENERIC), got "${helpers.getTaxLabel('JP', 'zh-CN', 'invTotalInput')}"`);
    if (helpers.getTaxLabel('TW', 'zh-CN', 'invTotalInput') !== '累计采购/费用凭证') reasons.push(`TW invTotalInput[zh-CN] should stay 累计采购/费用凭证 (TW voucher override), got "${helpers.getTaxLabel('TW', 'zh-CN', 'invTotalInput')}"`);
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
  // PART G0u: KR 票据查询 (invoice-query) page wording.
  //   KR uses the 采购与费用 / 销售与收入 wording (matching nav + tabs), not the shared
  //   采购/费用 · 销售/收入 slash form, and 待补票据 (not 待票据). Pins the rendered
  //   票据查询 keys and bans the slash form, 待票据, CN-VAT (进项/销项/增值税/认证), JP
  //   消费税, US Sales Tax, and non-KRW currency. (库存/交易 in the table subtitle is
  //   allowed — only 采购/费用 · 销售/收入 are banned.)
  // ────────────────────────────────────────────────
  {
    const reasons = [];
    const KR_INV_PIN = {
      'zh-CN': {
        invQueryTitle: '票据查询', invFilterAll: '全部票据', invFilterInput: '采购与费用', invFilterOutput: '销售与收入',
        invTotalInput: '累计采购与费用票据', invTotalOutput: '累计销售与收入票据',
        invHeaderInvoiceNo: '票据号码', invEmpty: '未找到匹配的票据记录',
        invStatusVerified: '已核验', invStatusCertified: '已记录', invStatusDeducted: '已处理',
        invStatusPendingCert: '待处理', invStatusPendingIssue: '待补票据', invStatusIssued: '已开票',
        invoiceTypeInput: '采购', invoiceTypeOutput: '销售',
      },
      'zh-TW': {
        invQueryTitle: '票據查詢', invFilterAll: '全部票據', invFilterInput: '採購與費用', invFilterOutput: '銷售與收入',
        invTotalInput: '累計採購與費用票據', invTotalOutput: '累計銷售與收入票據',
        invHeaderInvoiceNo: '票據號碼', invEmpty: '未找到匹配的票據記錄',
        invStatusVerified: '已核驗', invStatusCertified: '已記錄', invStatusDeducted: '已處理',
        invStatusPendingCert: '待處理', invStatusPendingIssue: '待補票據', invStatusIssued: '已開票',
        invoiceTypeInput: '採購', invoiceTypeOutput: '銷售',
      },
    };
    const KR_INV_KEYS = [
      'invQueryTitle', 'invSearchPlaceholder', 'invFilterAll', 'invFilterInput', 'invFilterOutput',
      'invTotalInput', 'invTotalOutput', 'invPendingTax', 'invPendingTaxSub', 'invNoInput', 'invNoOutput',
      'invInputRecordCount', 'invOutputRecordCount', 'invTableTitle', 'invTableSubtitle',
      'invHeaderDate', 'invHeaderWeight', 'invHeaderAmount', 'invHeaderInvoiceNo', 'invEmpty',
      'invDateRange', 'invWeightRange', 'invStatusFilter', 'invStatusAll', 'invStatusVerified',
      'invStatusCertified', 'invStatusDeducted', 'invStatusPendingCert', 'invStatusPendingIssue',
      'invStatusIssued', 'invAdvFilterActive', 'invoiceTypeInput', 'invoiceTypeOutput',
    ];
    const KR_INV_BAN = /采购\/费用|採購\/費用|销售\/收入|銷售\/收入|待票据|待票據|进项|進項|销项|銷項|增值税|增值稅|消费税|消費稅|Sales Tax|人民币|人民幣|CNY|欧元|歐元|EUR|€|日元|日圓|JPY|美元|USD|\$/;
    for (const lang of ['zh-CN', 'zh-TW']) {
      for (const key of KR_INV_KEYS) {
        const v = helpers.getTaxLabel('KR', lang, key);
        if (v === key) reasons.push(`KR ${key}[${lang}] missing (raw key)`);
        if (typeof v === 'string' && KR_INV_BAN.test(v)) reasons.push(`KR ${key}[${lang}] uses banned 票据查询 wording: "${v}"`);
      }
      for (const [key, want] of Object.entries(KR_INV_PIN[lang])) {
        const got = helpers.getTaxLabel('KR', lang, key);
        if (got !== want) reasons.push(`KR ${key}[${lang}] should be "${want}", got "${got}"`);
      }
    }
    // reverse guards: JP/EU keep their own invoice-query wording (KR override must not leak)
    if (helpers.getTaxLabel('JP', 'zh-CN', 'invTotalInput') !== '累计采购/费用票据') reasons.push(`JP invTotalInput[zh-CN] should stay 累计采购/费用票据 (NON_CN_GENERIC), got "${helpers.getTaxLabel('JP', 'zh-CN', 'invTotalInput')}"`);
    if (helpers.getTaxLabel('EU', 'zh-CN', 'invTotalInput') !== '累计采购与费用票据') reasons.push(`EU invTotalInput[zh-CN] should stay 累计采购与费用票据 (EU override), got "${helpers.getTaxLabel('EU', 'zh-CN', 'invTotalInput')}"`);
    if (helpers.getTaxLabel('TW', 'zh-CN', 'invTotalInput') !== '累计采购/费用凭证') reasons.push(`TW invTotalInput[zh-CN] should stay 累计采购/费用凭证 (TW voucher override), got "${helpers.getTaxLabel('TW', 'zh-CN', 'invTotalInput')}"`);
    if (reasons.length) fail(`krInvoiceQuery`, reasons); else pass(`krInvoiceQuery`);
  }

  // ────────────────────────────────────────────────
  // PART G0v: 数据分析中心 compact money format (formatCompactMoney).
  //   The 数据分析 cards/axes use a compact `${symbol}${value/1000}k` formatter. Under
  //   Chinese UI (zh-CN/zh-TW) a value that rounds to zero shows a plain `${symbol}0`
  //   (¥0 / ₩0 / €0 / $0 / NT$0) — no English 'k' suffix, not ¥0k / ¥0.0k — for EVERY
  //   accountingLocale. Non-zero values keep the …k form, and non-Chinese UI (en/ja/ko/
  //   fr) keeps the …k form for zero too (unchanged). Symbol follows accountingLocale.
  // ────────────────────────────────────────────────
  {
    const reasons = [];
    const ZERO = { CN: '¥0', US: '$0', JP: '¥0', EU: '€0', KR: '₩0', TW: 'NT$0' };
    for (const loc of ['CN', 'US', 'JP', 'EU', 'KR', 'TW']) {
      for (const lang of ['zh-CN', 'zh-TW']) {
        for (const digits of [0, 1]) {
          const got = helpers.formatCompactMoney(0, loc, lang, digits);
          if (got !== ZERO[loc]) reasons.push(`${loc} formatCompactMoney(0,${lang},${digits}) should be "${ZERO[loc]}", got "${got}"`);
        }
        // a tiny value that rounds to zero also collapses to the plain symbol
        const tiny = helpers.formatCompactMoney(4, loc, lang, 1);
        if (tiny !== ZERO[loc]) reasons.push(`${loc} formatCompactMoney(4,${lang},1) should round to "${ZERO[loc]}", got "${tiny}"`);
        // non-zero keeps the compact …k form (do not over-collapse)
        const nz = helpers.formatCompactMoney(1234567, loc, lang, 1);
        if (!/k$/.test(nz)) reasons.push(`${loc} non-zero compact money[${lang}] should keep …k: "${nz}"`);
      }
    }
    // KR zero must not leak the 'k' suffix or a non-₩ currency token
    for (const lang of ['zh-CN', 'zh-TW']) {
      const z = helpers.formatCompactMoney(0, 'KR', lang, 1);
      if (/[kK]|¥|€|\$|CNY|EUR|JPY|USD|人民币|人民幣|欧元|歐元|日元|日圓|美元/.test(z)) reasons.push(`KR zero compact money[${lang}] must be ₩0 only: "${z}"`);
    }
    // reverse: non-Chinese UI keeps the …k compact form for zero (unchanged)
    for (const loc of ['KR', 'CN']) {
      for (const lang of ['en', 'ja', 'ko', 'fr']) {
        const got = helpers.formatCompactMoney(0, loc, lang, 1);
        if (!/k$/.test(got)) reasons.push(`${loc} formatCompactMoney(0,${lang},1) should keep …k (non-Chinese UI unchanged), got "${got}"`);
      }
    }
    if (reasons.length) fail(`analyticsCompactMoneyZero`, reasons); else pass(`analyticsCompactMoneyZero`);
  }

  // ────────────────────────────────────────────────
  // PART G0w: KR transaction-category labels (收支记录 分类下拉).
  //   Under KR accountingLocale + zh-CN/zh-TW UI the category dropdown shows
  //   `displayLabel → schedule_line`, localized via KR_TXN_CATEGORY_LABELS (applied
  //   read-time in services/api.ts, keyed by slug). Guard: every KR category slug
  //   resolves zh-CN/zh-TW label + report-line; the report-line main text (before the
  //   parens) is Chinese (损益表-…), never the Korean headers 손익계산서-/판관비-/판매비-;
  //   Korean is allowed ONLY inside （） as the formal account name. No CN-VAT
  //   (进项/销项/增值税/认证), JP 消费税, US Sales Tax, or non-KRW currency.
  // ────────────────────────────────────────────────
  {
    const reasons = [];
    const M = config.KR_TXN_CATEGORY_LABELS || {};
    const REQUIRED_SLUGS = ['sales', 'non-operating', 'cogs', 'salary', 'welfare', 'travel', 'communication', 'utilities', 'supplies', 'entertain', 'advertising', 'rent', 'depreciation'];
    const HANGUL = /[가-힣]/;
    const KR_HEADER_BAN = /손익계산서-|판관비-|판매비-/;
    const KR_CAT_BAN = /进项|進項|销项|銷項|增值税|增值稅|消费税|消費稅|认证|認證|Sales Tax|人民币|人民幣|CNY|欧元|歐元|EUR|€|日元|日圓|JPY|美元|USD|\$/;
    // exact pins (the agreed KR 收支记录 wording)
    const LABEL_PIN = {
      'zh-CN': { sales: '营业收入', 'non-operating': '营业外收入', cogs: '销售成本', salary: '工资', welfare: '福利', travel: '差旅', communication: '通讯', utilities: '水电费', supplies: '消耗品', entertain: '招待', advertising: '广告', rent: '租金', depreciation: '折旧' },
      'zh-TW': { sales: '營業收入', 'non-operating': '營業外收入', cogs: '銷售成本', salary: '工資', welfare: '福利', travel: '差旅', communication: '通訊', utilities: '水電費', supplies: '消耗品', entertain: '招待', advertising: '廣告', rent: '租金', depreciation: '折舊' },
    };
    const LINE_PIN = {
      'zh-CN': { sales: '损益表-营业收入（매출）', 'non-operating': '损益表-营业外收入（영업외수익）', cogs: '损益表-销售成本（매출원가）', salary: '损益表-工资薪金（급여）', welfare: '损益表-福利费（복리후생비）', travel: '损益表-差旅费（여비교통비）', communication: '损益表-通信费（통신비）', utilities: '损益表-水电费（수도광열비）', supplies: '损益表-消耗品费（소모품비）', entertain: '损益表-招待费（접대비）', advertising: '损益表-广告宣传费（광고선전비）', rent: '损益表-租赁费（임차료）', depreciation: '损益表-折旧费（감가상각비）' },
      'zh-TW': { sales: '損益表-營業收入（매출）', 'non-operating': '損益表-營業外收入（영업외수익）', cogs: '損益表-銷售成本（매출원가）', salary: '損益表-薪資薪金（급여）', welfare: '損益表-福利費（복리후생비）', travel: '損益表-差旅費（여비교통비）', communication: '損益表-通訊費（통신비）', utilities: '損益表-水電費（수도광열비）', supplies: '損益表-消耗品費（소모품비）', entertain: '損益表-招待費（접대비）', advertising: '損益表-廣告宣傳費（광고선전비）', rent: '損益表-租賃費（임차료）', depreciation: '損益表-折舊費（감가상각비）' },
    };
    for (const slug of REQUIRED_SLUGS) {
      const e = M[slug];
      if (!e) { reasons.push(`KR_TXN_CATEGORY_LABELS missing slug "${slug}"`); continue; }
      for (const lang of ['zh-CN', 'zh-TW']) {
        const label = e.label && e.label[lang];
        const line = e.scheduleLine && e.scheduleLine[lang];
        if (label !== LABEL_PIN[lang][slug]) reasons.push(`KR cat ${slug}.label[${lang}] should be "${LABEL_PIN[lang][slug]}", got "${label}"`);
        if (line !== LINE_PIN[lang][slug]) reasons.push(`KR cat ${slug}.scheduleLine[${lang}] should be "${LINE_PIN[lang][slug]}", got "${line}"`);
        for (const [field, v] of [['label', label], ['scheduleLine', line]]) {
          if (typeof v !== 'string') continue;
          if (KR_HEADER_BAN.test(v)) reasons.push(`KR cat ${slug}.${field}[${lang}] uses Korean report header (should be 损益表-…): "${v}"`);
          if (KR_CAT_BAN.test(v)) reasons.push(`KR cat ${slug}.${field}[${lang}] uses CN-VAT/JP/US/non-KRW wording: "${v}"`);
        }
        // report-line MAIN text (before the parens) must be Chinese — no Korean as main
        if (typeof line === 'string') {
          const main = line.split('（')[0];
          if (HANGUL.test(main)) reasons.push(`KR cat ${slug}.scheduleLine[${lang}] has Korean as main text (only allowed inside （）): "${line}"`);
          if (!/^损益表-|^損益表-/.test(line)) reasons.push(`KR cat ${slug}.scheduleLine[${lang}] should start with 损益表-/損益表-: "${line}"`);
        }
        // the label (left side) must be pure Chinese — no Korean
        if (typeof label === 'string' && HANGUL.test(label)) reasons.push(`KR cat ${slug}.label[${lang}] must not contain Korean: "${label}"`);
      }
    }
    if (reasons.length) fail(`krTxnCategoryLabels`, reasons); else pass(`krTxnCategoryLabels`);
  }

  // ────────────────────────────────────────────────
  // PART G13: TW transaction page (收支记录) wording.
  //   Under TW accountingLocale + zh-CN/zh-TW UI: (a) the table headers read the formal
  //   类别 / 会计科目 / 付款状态·收款状态 (taxConcepts txnCategoryHeader / txnScheduleHeader /
  //   txnPaymentStatusHeader / txnReceiptStatusHeader), never 报表行 / 对应报表行 / 状态;
  //   (b) the category dropdown shows `displayLabel → schedule_line` via
  //   TW_TXN_CATEGORY_LABELS in 中文冒号 format (损益表：… / 税务：…) — NEVER the
  //   half-width-hyphen seed form (损益表-…); (c) 营业税 → 税务：营业税 and 营利事业所得税 →
  //   税务：营利事业所得税 are 税务 filing lines, NOT 损益表 lines. No CN-VAT / non-TWD /
  //   营利事业所得-without-税. UI stays Simplified. CN i18n (报表项目 / 对应报表项目 / 状态) and
  //   the global header year label ({{year}} 年, no 年度) are guarded too.
  // ────────────────────────────────────────────────
  {
    const reasons = [];
    const M = config.TW_TXN_CATEGORY_LABELS || {};
    const REQUIRED_SLUGS = ['sales', 'other', 'cogs', 'selling', 'admin', 'rd', 'business-tax', 'income-tax'];
    const TW_TXN_BAN = /增值税|增值稅|消费税|消費稅|VAT|Sales Tax|人民币|人民幣|CNY|欧元|歐元|EUR|€|日元|日圓|JPY|韩元|韓元|KRW|₩|美元|USD|\$|营利事业所得(?!税)|營利事業所得(?!稅)/;
    const LABEL_PIN = {
      'zh-CN': { sales: '销货收入', other: '其他营业收入', cogs: '销货成本', selling: '销售费用', admin: '管理费用', rd: '研究发展费用', 'business-tax': '营业税', 'income-tax': '营利事业所得税' },
      'zh-TW': { sales: '銷貨收入', other: '其他營業收入', cogs: '銷貨成本', selling: '銷售費用', admin: '管理費用', rd: '研究發展費用', 'business-tax': '營業稅', 'income-tax': '營利事業所得稅' },
    };
    const LINE_PIN = {
      'zh-CN': { sales: '损益表：营业收入', other: '损益表：其他营业收入', cogs: '损益表：销货成本', selling: '损益表：销售费用', admin: '损益表：管理费用', rd: '损益表：研究发展费用', 'business-tax': '税务：营业税', 'income-tax': '税务：营利事业所得税' },
      'zh-TW': { sales: '損益表：營業收入', other: '損益表：其他營業收入', cogs: '損益表：銷貨成本', selling: '損益表：銷售費用', admin: '損益表：管理費用', rd: '損益表：研究發展費用', 'business-tax': '稅務：營業稅', 'income-tax': '稅務：營利事業所得稅' },
    };
    for (const slug of REQUIRED_SLUGS) {
      const e = M[slug];
      if (!e) { reasons.push(`TW_TXN_CATEGORY_LABELS missing slug "${slug}"`); continue; }
      for (const lang of ['zh-CN', 'zh-TW']) {
        const label = e.label && e.label[lang];
        const line = e.scheduleLine && e.scheduleLine[lang];
        if (label !== LABEL_PIN[lang][slug]) reasons.push(`TW cat ${slug}.label[${lang}] should be "${LABEL_PIN[lang][slug]}", got "${label}"`);
        if (line !== LINE_PIN[lang][slug]) reasons.push(`TW cat ${slug}.scheduleLine[${lang}] should be "${LINE_PIN[lang][slug]}", got "${line}"`);
        for (const [field, v] of [['label', label], ['scheduleLine', line]]) {
          if (typeof v !== 'string') continue;
          if (TW_TXN_BAN.test(v)) reasons.push(`TW cat ${slug}.${field}[${lang}] uses banned (CN-VAT/non-TWD/营利事业所得-without-税) wording: "${v}"`);
        }
        // report-line must use 中文冒号 (：), never the half-width-hyphen seed form
        if (typeof line === 'string') {
          if (/-/.test(line)) reasons.push(`TW cat ${slug}.scheduleLine[${lang}] uses half-width hyphen (should be 中文冒号 ：): "${line}"`);
          if (!line.includes('：')) reasons.push(`TW cat ${slug}.scheduleLine[${lang}] should use 中文冒号 ：: "${line}"`);
        }
      }
    }
    // 营业税 / 营利事业所得税 are 税务 filing lines — NOT ordinary 损益表 expense lines
    for (const slug of ['business-tax', 'income-tax']) {
      for (const lang of ['zh-CN', 'zh-TW']) {
        const v = M[slug] && M[slug].scheduleLine && M[slug].scheduleLine[lang];
        if (typeof v !== 'string') continue;
        if (/^损益表|^損益表/.test(v)) reasons.push(`TW cat ${slug}.scheduleLine[${lang}] must not be a 损益表 line (should start 税务：/稅務：): "${v}"`);
        if (!/^税务：|^稅務：/.test(v)) reasons.push(`TW cat ${slug}.scheduleLine[${lang}] should start with 税务：/稅務：: "${v}"`);
      }
    }
    // formal table-header taxConcepts: present for every UI language + pinned zh values
    const HEADER_PIN = {
      txnCategoryHeader:      { 'zh-CN': '类别',     'zh-TW': '類別' },
      txnScheduleHeader:      { 'zh-CN': '会计科目', 'zh-TW': '會計科目' },
      txnPaymentStatusHeader: { 'zh-CN': '付款状态', 'zh-TW': '付款狀態' },
      txnReceiptStatusHeader: { 'zh-CN': '收款状态', 'zh-TW': '收款狀態' },
    };
    for (const [key, pin] of Object.entries(HEADER_PIN)) {
      for (const uiLang of UI_LANGUAGES) {
        if (helpers.getTaxLabel('TW', uiLang, key) === key) reasons.push(`TW ${key}[${uiLang}] missing (raw key)`);
      }
      for (const lang of ['zh-CN', 'zh-TW']) {
        const v = helpers.getTaxLabel('TW', lang, key);
        if (v !== pin[lang]) reasons.push(`TW ${key}[${lang}] should be "${pin[lang]}", got "${v}"`);
      }
    }
    // 会计科目 must not regress to the generic 报表行 / 对应科目
    for (const lang of ['zh-CN', 'zh-TW']) {
      const v = helpers.getTaxLabel('TW', lang, 'txnScheduleHeader');
      if (/报表行|報表行|对应科目|對應科目/.test(v)) reasons.push(`TW txnScheduleHeader[${lang}] should be 会计科目/會計科目: "${v}"`);
    }
    // reverse: CN keeps its own 收支记录 i18n (报表项目 / 对应报表项目 / 状态) — TW change must not leak
    if (get(locales['zh-CN'], 'transactions.scheduleLine') !== '报表项目') reasons.push(`CN transactions.scheduleLine should stay 报表项目, got "${get(locales['zh-CN'], 'transactions.scheduleLine')}"`);
    if (get(locales['zh-CN'], 'transactions.mapsToLine') !== '对应报表项目') reasons.push(`CN transactions.mapsToLine should stay 对应报表项目, got "${get(locales['zh-CN'], 'transactions.mapsToLine')}"`);
    if (get(locales['zh-CN'], 'tableHeaders.status') !== '状态') reasons.push(`CN tableHeaders.status should stay 状态, got "${get(locales['zh-CN'], 'tableHeaders.status')}"`);
    // global header year label simplified to {{year}} 年 (no 年度) for both Chinese UIs
    for (const lang of ['zh-CN', 'zh-TW']) {
      const yl = get(locales[lang], 'header.yearLabel');
      if (yl !== '{{year}} 年') reasons.push(`${lang} header.yearLabel should be "{{year}} 年" (no 年度), got "${yl}"`);
    }
    if (reasons.length) fail(`twTransactionsWording`, reasons); else pass(`twTransactionsWording`);
  }

  // ────────────────────────────────────────────────
  // PART G17: CN transaction-category labels (收支记录 分类下拉).
  //   Under CN accountingLocale + zh-CN/zh-TW UI the dropdown shows `label → schedule_line`
  //   via CN_TXN_CATEGORY_LABELS (read-time, by slug). The report-line uses the mainland
  //   P&L name 利润表 / 利潤表 — never the seed's 损益表 / 損益表 — and the surcharge category
  //   reads 税金及附加 / 稅金及附加, never 营业税金及附加 / 營業稅金及附加.
  // ────────────────────────────────────────────────
  {
    const reasons = [];
    const M = config.CN_TXN_CATEGORY_LABELS || {};
    const REQUIRED_SLUGS = ['sales', 'other-revenue', 'interest', 'cogs', 'selling', 'admin', 'financial', 'tax-surcharge', 'income-tax'];
    const LABEL_PIN = {
      'zh-CN': { sales: '主营业务收入', 'other-revenue': '其他业务收入', interest: '利息收入', cogs: '营业成本', selling: '销售费用', admin: '管理费用', financial: '财务费用', 'tax-surcharge': '税金及附加', 'income-tax': '所得税' },
      'zh-TW': { sales: '主營業務收入', 'other-revenue': '其他業務收入', interest: '利息收入', cogs: '營業成本', selling: '銷售費用', admin: '管理費用', financial: '財務費用', 'tax-surcharge': '稅金及附加', 'income-tax': '所得稅' },
    };
    const LINE_PIN = {
      'zh-CN': { sales: '利润表-营业收入', 'other-revenue': '利润表-其他业务收入', interest: '利润表-财务收入', cogs: '利润表-营业成本', selling: '利润表-销售费用', admin: '利润表-管理费用', financial: '利润表-财务费用', 'tax-surcharge': '利润表-税金及附加', 'income-tax': '利润表-所得税' },
      'zh-TW': { sales: '利潤表-營業收入', 'other-revenue': '利潤表-其他業務收入', interest: '利潤表-財務收入', cogs: '利潤表-營業成本', selling: '利潤表-銷售費用', admin: '利潤表-管理費用', financial: '利潤表-財務費用', 'tax-surcharge': '利潤表-稅金及附加', 'income-tax': '利潤表-所得稅' },
    };
    for (const slug of REQUIRED_SLUGS) {
      const e = M[slug];
      if (!e) { reasons.push(`CN_TXN_CATEGORY_LABELS missing slug "${slug}"`); continue; }
      for (const lang of ['zh-CN', 'zh-TW']) {
        const label = e.label && e.label[lang];
        const line = e.scheduleLine && e.scheduleLine[lang];
        if (label !== LABEL_PIN[lang][slug]) reasons.push(`CN cat ${slug}.label[${lang}] should be "${LABEL_PIN[lang][slug]}", got "${label}"`);
        if (line !== LINE_PIN[lang][slug]) reasons.push(`CN cat ${slug}.scheduleLine[${lang}] should be "${LINE_PIN[lang][slug]}", got "${line}"`);
        for (const [field, v] of [['label', label], ['scheduleLine', line]]) {
          if (typeof v !== 'string') continue;
          if (/损益表|損益表/.test(v)) reasons.push(`CN cat ${slug}.${field}[${lang}] must use 利润表/利潤表, not 损益表/損益表: "${v}"`);
          if (/营业税金及附加|營業稅金及附加/.test(v)) reasons.push(`CN cat ${slug}.${field}[${lang}] should be 税金及附加/稅金及附加 (drop 营业): "${v}"`);
        }
      }
    }
    if (reasons.length) fail(`cnTxnCategoryLabels`, reasons); else pass(`cnTxnCategoryLabels`);
  }

  // ────────────────────────────────────────────────
  // PART G14: CN finance tax-inclusive summary title — zh-TW wording.
  //   Under CN accountingLocale + zh-TW UI the 含税金额汇总 title reads the more formal
  //   含稅金額統計 (the old 含稅金額匯總 (對帳用) was stiff/repetitive). zh-CN keeps its own
  //   value; en/ja/ko/fr unchanged. China-GAAP VAT口径 must stay (the title must NOT
  //   adopt Taiwan wording 营业税 / 营利事业所得税 / 销货收入). Display only.
  // ────────────────────────────────────────────────
  {
    const reasons = [];
    const TW_VOCAB_BAN = /营业税|營業稅|营利事业所得|營利事業所得|销货收入|銷貨收入/;
    const tw = helpers.getTaxLabel('CN', 'zh-TW', 'taxSummaryTitle');
    const cn = helpers.getTaxLabel('CN', 'zh-CN', 'taxSummaryTitle');
    if (tw !== '含稅金額統計') reasons.push(`CN taxSummaryTitle[zh-TW] should be "含稅金額統計", got "${tw}"`);
    if (cn !== '含税金额汇总 (对账用)') reasons.push(`CN taxSummaryTitle[zh-CN] should stay "含税金额汇总 (对账用)", got "${cn}"`);
    for (const lang of ['zh-CN', 'zh-TW']) {
      const v = helpers.getTaxLabel('CN', lang, 'taxSummaryTitle');
      if (typeof v === 'string' && TW_VOCAB_BAN.test(v)) reasons.push(`CN taxSummaryTitle[${lang}] must not use Taiwan wording (营业税/营利事业所得/销货收入): "${v}"`);
    }
    // CN VAT口径 elsewhere stays China-GAAP (regression guard): 进项/销项/应交增值税
    if (!/进项税额|進項稅額/.test(helpers.getTaxLabel('CN', 'zh-CN', 'inputTax') + helpers.getTaxLabel('CN', 'zh-TW', 'inputTax'))) reasons.push(`CN inputTax should keep 进项税额/進項稅額`);
    // The admin-expense settings hint serves every accountingLocale under each Chinese
    // UI, so it must not embed a regime-specific report name (mainland 利润表 vs TW/JP
    // 损益表) — keep it regime-neutral so 损益表 never shows under CN nor 利润表 under TW.
    for (const lang of ['zh-CN', 'zh-TW']) {
      const desc = get(locales[lang], 'settings.tax.adminExpenseDesc');
      if (typeof desc === 'string' && /损益表|損益表|利润表|利潤表/.test(desc)) reasons.push(`${lang} settings.tax.adminExpenseDesc should stay regime-neutral (no 损益表/利润表): "${desc}"`);
    }
    if (reasons.length) fail(`cnTaxSummaryTitleZhTw`, reasons); else pass(`cnTaxSummaryTitleZhTw`);
  }

  // ────────────────────────────────────────────────
  // PART G0x: TW dashboard business-tax section (经营看板 营业税 + P&L).
  //   TW accountingLocale uses Taiwan 营业税 wording (台湾营业税统计 / 采购进项营业税 /
  //   销售销项营业税 / 营利事业所得税). 进项/销项 ARE allowed for TW (本地营业税口径);
  //   what's banned is 增值税 / 消费税 / VAT / Sales Tax / 进项·销项 VAT and any
  //   non-TWD currency, plus 营利事业所得 without the trailing 税. Under zh-CN the main
  //   text must be simplified Chinese. Money stays NT$. CN/JP/EU/KR/US guarded the
  //   other way.
  // ────────────────────────────────────────────────
  {
    const reasons = [];
    const cfgTW = config.getAccountingLocale('TW');
    const TW_PIN = {
      'zh-CN': {
        taxTitle: '台湾营业税统计', inputTax: '采购进项营业税', outputTax: '销售销项营业税',
        certifiedInput: '可抵扣采购进项营业税', invoicedOutput: '已开票销售销项营业税', estimatedTax: '预计应缴营业税',
        taxSummaryTitle: '台湾营业税申报汇总（对账用）', purchaseTotal: '采购含税总额', salesTotal: '销售含税总额', taxDifference: '营业税差额',
        plIncomeTax: '营利事业所得税', plRevenue: '销售收入', plCost: '销货成本', plAdmin: '管理费用',
      },
      'zh-TW': {
        taxTitle: '台灣營業稅統計', inputTax: '採購進項營業稅', outputTax: '銷售銷項營業稅',
        certifiedInput: '可抵扣採購進項營業稅', invoicedOutput: '已開票銷售銷項營業稅', estimatedTax: '預計應繳營業稅',
        taxSummaryTitle: '臺灣營業稅申報彙總（對帳用）', purchaseTotal: '採購含稅總額', salesTotal: '銷售含稅總額', taxDifference: '營業稅差額',
        plIncomeTax: '營利事業所得稅', plRevenue: '銷售收入', plCost: '銷貨成本', plAdmin: '管理費用',
      },
    };
    // 进项/销项 (plain) are allowed for TW; ban only the VAT-suffixed / other-regime
    // forms, non-TWD currency, and 营利事业所得 without 税.
    const TW_BAN = /增值税|增值稅|消费税|消費稅|VAT|Sales Tax|人民币|人民幣|CNY|欧元|歐元|EUR|€|日元|日圓|JPY|韩元|韓元|KRW|₩|美元|USD|\$|营利事业所得(?!税)|營利事業所得(?!稅)/;
    for (const lang of ['zh-CN', 'zh-TW']) {
      for (const [key, want] of Object.entries(TW_PIN[lang])) {
        const got = helpers.getTaxLabel('TW', lang, key);
        if (got !== want) reasons.push(`TW ${key}[${lang}] should be "${want}", got "${got}"`);
      }
      // ban wrong口径 / non-TWD currency / 营利事业所得-without-税 across ALL TW taxConcepts
      for (const [key, labels] of Object.entries(cfgTW.taxConcepts)) {
        const v = labels[lang];
        if (typeof v === 'string' && TW_BAN.test(v)) reasons.push(`TW ${key}[${lang}] uses banned (增值税/消费税/VAT/Sales Tax/non-TWD/营利事业所得-without-税) wording: "${v}"`);
      }
    }
    // reverse guards: other regimes keep their own口径 (TW changes must not leak)
    if (helpers.getTaxLabel('CN', 'zh-CN', 'inputTax') !== '累计进项税额') reasons.push(`CN inputTax[zh-CN] should stay 累计进项税额`);
    if (!/消费税/.test(helpers.getTaxLabel('JP', 'zh-CN', 'inputTax'))) reasons.push(`JP inputTax[zh-CN] should keep 消费税`);
    if (helpers.getTaxLabel('EU', 'zh-CN', 'inputTax') !== '采购 VAT') reasons.push(`EU inputTax[zh-CN] should stay 采购 VAT`);
    if (helpers.getTaxLabel('KR', 'zh-CN', 'inputTax') !== '采购 VAT') reasons.push(`KR inputTax[zh-CN] should stay 采购 VAT`);
    if (reasons.length) fail(`twDashboardBusinessTax`, reasons); else pass(`twDashboardBusinessTax`);
  }

  // ────────────────────────────────────────────────
  // PART G0y: TW purchase/sales modal titles — no word-break space.
  //   The add-record modal titles must be intact single phrases with no embedded
  //   whitespace (a stray space rendered as 采购与费 用 / 销售与收 入). Pin the TW
  //   values and forbid any whitespace inside them. (The h2 also carries
  //   whitespace-nowrap so CJK never wraps mid-character at render.)
  // ────────────────────────────────────────────────
  {
    const reasons = [];
    const PIN = {
      'zh-CN': { modalTitlePurchase: '新增采购与费用记录', modalTitleSales: '新增销售与收入记录' },
      'zh-TW': { modalTitlePurchase: '新增採購與費用記錄', modalTitleSales: '新增銷售與收入記錄' },
    };
    const BREAK_BAN = /采购与费 用|採購與費 用|销售与收 入|銷售與收 入|费 用|費 用|收 入/;
    for (const lang of ['zh-CN', 'zh-TW']) {
      for (const [key, want] of Object.entries(PIN[lang])) {
        const got = helpers.getTaxLabel('TW', lang, key);
        if (got !== want) reasons.push(`TW ${key}[${lang}] should be "${want}", got "${got}"`);
        if (/\s/.test(got)) reasons.push(`TW ${key}[${lang}] must contain no whitespace (word-break): "${got}"`);
        if (BREAK_BAN.test(got)) reasons.push(`TW ${key}[${lang}] has a 费 用 / 收 入 word-break: "${got}"`);
      }
    }
    if (reasons.length) fail(`twModalTitleNoBreak`, reasons); else pass(`twModalTitleNoBreak`);
  }

  // ────────────────────────────────────────────────
  // PART G0z: TW purchase/sales 发票/凭证 wording.
  //   On the 采购与费用 / 销售与收入 pages, TW frames the document number as 发票/凭证
  //   号码 (not the generic 票据号码), and the upload/empty hints reference 发票…凭证.
  //   zh-CN/zh-TW only; JP/EU/KR keep the shared 票据号码 (guarded the other way).
  //   No CN-VAT (增值税/进项/销项) or non-TWD currency (人民币/CNY/RMB) on these keys.
  //   (The 票据查询 page keeps 票据号码 — out of this scope.)
  // ────────────────────────────────────────────────
  {
    const reasons = [];
    const PS_KEYS = ['headerInvoiceNo', 'uploadTitle', 'uploadTitleSales', 'uploadSubtitle', 'uploadSubtitleSales', 'emptyPurchase', 'emptySales'];
    // ban the generic 票据号码 / 账单或票据 framing + CN-VAT / non-TWD currency on these keys
    const PS_BAN = /票据号码|票據號碼|账单或票据|帳單或票據|增值税|增值稅|进项|進項|销项|銷項|人民币|人民幣|CNY|RMB/;
    const PIN = { 'zh-CN': { headerInvoiceNo: '发票/凭证号码' }, 'zh-TW': { headerInvoiceNo: '發票/憑證號碼' } };
    const VOUCHER = /发票\/凭证|發票\/憑證/;
    const HAS_INVOICE = /发票|發票/;
    for (const lang of ['zh-CN', 'zh-TW']) {
      for (const [k, want] of Object.entries(PIN[lang])) {
        const got = helpers.getTaxLabel('TW', lang, k);
        if (got !== want) reasons.push(`TW ${k}[${lang}] should be "${want}", got "${got}"`);
      }
      for (const k of PS_KEYS) {
        const v = helpers.getTaxLabel('TW', lang, k);
        if (typeof v === 'string' && PS_BAN.test(v)) reasons.push(`TW ${k}[${lang}] uses banned (票据号码/账单或票据/增值税/进项/销项/人民币/CNY/RMB) wording: "${v}"`);
      }
      // 发票/凭证 must surface in the document-number field + both upload subtitles
      for (const k of ['headerInvoiceNo', 'uploadSubtitle', 'uploadSubtitleSales']) {
        const v = helpers.getTaxLabel('TW', lang, k);
        if (!VOUCHER.test(v)) reasons.push(`TW ${k}[${lang}] should contain 发票/凭证: "${v}"`);
      }
      // the upload dropzone titles must reference 发票 (发票、收据或凭证), not 账单或票据
      for (const k of ['uploadTitle', 'uploadTitleSales']) {
        const v = helpers.getTaxLabel('TW', lang, k);
        if (!HAS_INVOICE.test(v)) reasons.push(`TW ${k}[${lang}] should reference 发票 (发票、收据或凭证): "${v}"`);
      }
    }
    // reverse: JP/EU/KR keep the shared 票据号码 (TW override must not leak)
    for (const loc of ['JP', 'EU', 'KR']) {
      if (helpers.getTaxLabel(loc, 'zh-CN', 'headerInvoiceNo') !== '票据号码') reasons.push(`${loc} headerInvoiceNo[zh-CN] should stay 票据号码, got "${helpers.getTaxLabel(loc, 'zh-CN', 'headerInvoiceNo')}"`);
    }
    if (reasons.length) fail(`twInvoiceVoucherWording`, reasons); else pass(`twInvoiceVoucherWording`);
  }

  // ────────────────────────────────────────────────
  // PART G10: TW 凭证 wording (票据查询 / 状态 / OCR), zh-CN/zh-TW.
  //   TW normalizes the mainland 票据 framing to 凭证 (凭证查询 / 全部凭证 / 凭证状态 /
  //   凭证流转全景视图 / 未找到匹配的凭证记录), status 待票据→待补凭证, 已核验→已确认,
  //   已开票→已开立发票, and the OCR/分类号码 use 凭证/发票. Bans 票据/待票据/已核验/
  //   已开票/账单或票据 across the 票据查询 + 采购/销售 rendered keys (发票 is allowed).
  //   zh-CN main text stays simplified. JP/EU/KR/CN keep their own wording.
  // ────────────────────────────────────────────────
  {
    const reasons = [];
    const PIN = {
      'zh-CN': {
        invQueryTitle: '凭证查询', invFilterAll: '全部凭证', invStatusFilter: '凭证状态',
        invTableTitle: '凭证流转全景视图', invTableSubtitle: '核对凭证流与库存/交易记录一致性',
        invEmpty: '未找到匹配的凭证记录', invHeaderInvoiceNo: '发票/凭证号码',
        invSearchPlaceholder: '搜索发票/凭证号码或往来单位...', scanningTitle: '正在分析凭证…',
        invTotalInput: '累计采购/费用凭证', invTotalOutput: '累计销售/收入凭证',
        invStatusVerified: '已确认', invStatusPendingIssue: '待补凭证', invStatusIssued: '已开立发票',
      },
      'zh-TW': {
        invQueryTitle: '憑證查詢', invFilterAll: '全部憑證', invStatusFilter: '憑證狀態',
        invTableTitle: '憑證流轉全景視圖', invTableSubtitle: '核對憑證流與庫存/交易記錄一致性',
        invEmpty: '未找到匹配的憑證記錄', invHeaderInvoiceNo: '發票/憑證號碼',
        invSearchPlaceholder: '搜尋發票/憑證號碼或往來單位...', scanningTitle: '正在分析憑證…',
        invTotalInput: '累計採購/費用憑證', invTotalOutput: '累計銷售/收入憑證',
        invStatusVerified: '已確認', invStatusPendingIssue: '待補憑證', invStatusIssued: '已開立發票',
      },
    };
    // all 票据查询 + 采购/销售 rendered keys — none may carry 票据/待票据/已核验/已开票
    const TW_VOUCHER_KEYS = [
      'invQueryTitle', 'invSearchPlaceholder', 'invFilterAll', 'invFilterInput', 'invFilterOutput',
      'invTableTitle', 'invTableSubtitle', 'invHeaderInvoiceNo', 'invHeaderDate', 'invHeaderWeight',
      'invHeaderAmount', 'invEmpty', 'invTotalInput', 'invTotalOutput', 'invPendingTax', 'invPendingTaxSub',
      'invStatusFilter', 'invStatusAll', 'invStatusVerified', 'invStatusCertified', 'invStatusDeducted',
      'invStatusPendingCert', 'invStatusPendingIssue', 'invStatusIssued', 'scanningTitle', 'scanningSubtitle',
      'uploadTitle', 'uploadTitleSales', 'uploadSubtitle', 'uploadSubtitleSales', 'headerInvoiceNo',
      'emptyPurchase', 'emptySales',
    ];
    const TW_VOUCHER_BAN = /票据|票據|待票据|待票據|待凭证|待憑證|已核验|已核驗|已开票|已開票|账单或票据|帳單或票據/;
    for (const lang of ['zh-CN', 'zh-TW']) {
      for (const [k, want] of Object.entries(PIN[lang])) {
        const got = helpers.getTaxLabel('TW', lang, k);
        if (got !== want) reasons.push(`TW ${k}[${lang}] should be "${want}", got "${got}"`);
      }
      for (const k of TW_VOUCHER_KEYS) {
        const v = helpers.getTaxLabel('TW', lang, k);
        if (typeof v === 'string' && TW_VOUCHER_BAN.test(v)) reasons.push(`TW ${k}[${lang}] uses banned 票据/待票据/已核验/已开票/账单或票据 wording (use 凭证/发票): "${v}"`);
      }
    }
    // reverse: JP keeps NON_CN_GENERIC 票据 wording (TW 凭证 override must not leak)
    if (helpers.getTaxLabel('JP', 'zh-CN', 'invQueryTitle') !== '票据查询') reasons.push(`JP invQueryTitle[zh-CN] should stay 票据查询, got "${helpers.getTaxLabel('JP', 'zh-CN', 'invQueryTitle')}"`);
    if (helpers.getTaxLabel('JP', 'zh-CN', 'invFilterAll') !== '全部票据') reasons.push(`JP invFilterAll[zh-CN] should stay 全部票据, got "${helpers.getTaxLabel('JP', 'zh-CN', 'invFilterAll')}"`);
    if (reasons.length) fail(`twVoucherWording`, reasons); else pass(`twVoucherWording`);
  }

  // ────────────────────────────────────────────────
  // PART G11: TW 应收应付 (AccountsPage) wording.
  //   TW uses 帐龄 (not the mainland 账龄) and tab-specific 未收款/未付款明细 +
  //   所有应收/应付款项已结清. Pins the TW acct* keys (zh-CN/zh-TW) and bans 账龄/帳齡
  //   on the aging title. CN/EU/JP/KR keep the shared accounts.* i18n (guarded below).
  // ────────────────────────────────────────────────
  {
    const reasons = [];
    const PIN = {
      'zh-CN': {
        acctAgingTitle: '帐龄分析', acctDetailsReceivable: '未收款明细', acctDetailsPayable: '未付款明细',
        acctAllClearedReceivable: '所有应收款项已结清', acctAllClearedPayable: '所有应付款项已结清',
      },
      'zh-TW': {
        acctAgingTitle: '帳齡分析', acctDetailsReceivable: '未收款明細', acctDetailsPayable: '未付款明細',
        acctAllClearedReceivable: '所有應收款項已結清', acctAllClearedPayable: '所有應付款項已結清',
      },
    };
    for (const lang of ['zh-CN', 'zh-TW']) {
      for (const [k, want] of Object.entries(PIN[lang])) {
        const got = helpers.getTaxLabel('TW', lang, k);
        if (got !== want) reasons.push(`TW ${k}[${lang}] should be "${want}", got "${got}"`);
      }
      // TW aging title must use 帐龄/帳齡, never the mainland 账龄
      const aging = helpers.getTaxLabel('TW', lang, 'acctAgingTitle');
      if (/账龄/.test(aging)) reasons.push(`TW acctAgingTitle[${lang}] should use 帐龄/帳齡, not 账龄: "${aging}"`);
    }
    // reverse: CN keeps the shared accounts.* i18n (mainland 账龄 / 未结清明细 / 所有款项已结清)
    const cn = locales['zh-CN'];
    if (get(cn, 'accounts.agingTitle') !== '账龄分析') reasons.push(`CN accounts.agingTitle should stay 账龄分析, got "${get(cn, 'accounts.agingTitle')}"`);
    if (get(cn, 'accounts.details') !== '未结清明细') reasons.push(`CN accounts.details should stay 未结清明细, got "${get(cn, 'accounts.details')}"`);
    if (get(cn, 'accounts.allCleared') !== '所有款项已结清') reasons.push(`CN accounts.allCleared should stay 所有款项已结清, got "${get(cn, 'accounts.allCleared')}"`);
    if (reasons.length) fail(`twAccountsWording`, reasons); else pass(`twAccountsWording`);
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
      'balRetainedEarnings', 'balEquityHeader', 'balLiabEquityHeader', 'balTotalLiabEquity', 'balCashflowAdd',
    ];
    const CN_GAAP_BAN = /应收账款|應收帳款|应付账款|應付帳款|应交税费|應交稅費|实收资本|實收資本|未分配利润|未分配利潤|股东权益|股東權益/;
    // TW uses the Taiwan ledger term 應收帳款/應付帳款 (帐·帳, 巾字旁) legitimately, so
    // its ban drops those traditional forms but still forbids the Mainland 账款 (账,
    // 贝字旁) form and the equity-GAAP terms. TW's finance wording is pinned in G12.
    const TW_GAAP_BAN = /应收账款|应付账款|应交税费|應交稅費|实收资本|實收資本|未分配利润|未分配利潤|股东权益|股東權益/;
    const PIN = {
      'zh-CN': {
        acctReceivableTab: '客户应收', acctPayableTab: '供应商应付',
        acctTotalReceivable: '客户应收总额', acctTotalPayable: '供应商应付总额',
        balRecvLabel: '客户应收', balPayLabel: '供应商应付', balTaxPayLabel: '应付税款',
        balPaidInCapital: '所有者投入', balRetainedEarnings: '留存收益', balEquityHeader: '所有者权益',
        balLiabEquityHeader: '负债和所有者权益', balTotalLiabEquity: '负债和所有者权益总计',
      },
      'zh-TW': {
        acctReceivableTab: '客戶應收', acctPayableTab: '供應商應付',
        acctTotalReceivable: '客戶應收總額', acctTotalPayable: '供應商應付總額',
        balRecvLabel: '客戶應收', balPayLabel: '供應商應付', balTaxPayLabel: '應付稅款',
        balPaidInCapital: '所有者投入', balRetainedEarnings: '留存收益', balEquityHeader: '所有者權益',
        balLiabEquityHeader: '負債和所有者權益', balTotalLiabEquity: '負債和所有者權益總計',
      },
    };
    for (const accId of ['US', 'JP', 'KR', 'TW', 'EU']) {
      const reasons = [];
      const ban = accId === 'TW' ? TW_GAAP_BAN : CN_GAAP_BAN;
      for (const key of ACCT_FIN_KEYS) {
        // presence: every non-CN locale must resolve the key (no raw-key fallback)
        for (const lang of UI_LANGUAGES) {
          const v = helpers.getTaxLabel(accId, lang, key);
          if (v === key) reasons.push(`${key}[${lang}] missing (raw key) for ${accId}`);
        }
        // ban China-GAAP / China-VAT wording on the Chinese display strings
        for (const lang of ['zh-CN', 'zh-TW']) {
          const v = helpers.getTaxLabel(accId, lang, key);
          if (typeof v === 'string' && ban.test(v)) {
            reasons.push(`${accId} ${key}[${lang}] uses China-GAAP wording: "${v}"`);
          }
        }
      }
      // pin the corrected non-CN wording (also asserts US fixes keep appearing).
      // TW finance wording differs (Taiwan-GAAP) and is pinned in PART G12.
      if (accId !== 'TW') {
        for (const lang of ['zh-CN', 'zh-TW']) {
          for (const [key, want] of Object.entries(PIN[lang])) {
            const got = helpers.getTaxLabel(accId, lang, key);
            if (got !== want) reasons.push(`${accId} ${key}[${lang}] should be "${want}", got "${got}"`);
          }
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
  // PART G12: TW finance report (财务报表) balance-sheet + business-tax wording.
  //   Under TW accountingLocale the balance sheet uses Taiwan-GAAP terms:
  //   负债及权益 / 权益 / 资本 / 保留盈余 / 负债及权益总计 / 应收帐款 (帐·帳, 巾字旁 —
  //   NOT the Mainland 账款 贝字旁), and the business-tax block reads 申报汇总 (not the
  //   old 含税汇总). zh-CN/zh-TW only; en/ja/ko/fr keep the NON_CN_GENERIC values. JP/EU/KR
  //   keep the generic 所有者投入/留存收益/客户应收/所有者权益; CN keeps its own i18n.
  // ────────────────────────────────────────────────
  {
    const reasons = [];
    const TW_FIN_PIN = {
      'zh-CN': {
        balRecvLabel: '应收帐款', balPaidInCapital: '资本', balRetainedEarnings: '保留盈余',
        balEquityHeader: '权益', balLiabEquityHeader: '负债及权益', balTotalLiabEquity: '负债及权益总计',
        taxSummaryTitle: '台湾营业税申报汇总（对账用）',
      },
      'zh-TW': {
        balRecvLabel: '應收帳款', balPaidInCapital: '資本', balRetainedEarnings: '保留盈餘',
        balEquityHeader: '權益', balLiabEquityHeader: '負債及權益', balTotalLiabEquity: '負債及權益總計',
        taxSummaryTitle: '臺灣營業稅申報彙總（對帳用）',
      },
    };
    // Mainland-GAAP / pre-fix drift forbidden on TW finance keys. 应收账款 here is the
    // Mainland 账 (贝字旁) form — TW's legit 应收帐款/應收帳款 (帐·帳, 巾字旁) is NOT matched.
    const TW_FIN_BAN = /应收账款|股东权益|股東權益|实收资本|實收資本|未分配利润|未分配利潤|含税汇总|含稅匯總|含稅彙總/;
    const TW_FIN_KEYS = ['balRecvLabel', 'balPaidInCapital', 'balRetainedEarnings', 'balEquityHeader', 'balLiabEquityHeader', 'balTotalLiabEquity', 'taxSummaryTitle'];
    for (const lang of ['zh-CN', 'zh-TW']) {
      for (const [key, want] of Object.entries(TW_FIN_PIN[lang])) {
        const got = helpers.getTaxLabel('TW', lang, key);
        if (got !== want) reasons.push(`TW ${key}[${lang}] should be "${want}", got "${got}"`);
      }
      for (const key of TW_FIN_KEYS) {
        const v = helpers.getTaxLabel('TW', lang, key);
        if (typeof v === 'string' && TW_FIN_BAN.test(v)) reasons.push(`TW ${key}[${lang}] uses forbidden (Mainland-GAAP / old 含税汇总) wording: "${v}"`);
      }
    }
    // reverse: JP/EU/KR keep the generic non-CN balance-sheet wording (TW change must not leak)
    for (const acc of ['JP', 'EU', 'KR']) {
      if (helpers.getTaxLabel(acc, 'zh-CN', 'balPaidInCapital') !== '所有者投入') reasons.push(`${acc} balPaidInCapital[zh-CN] should stay 所有者投入`);
      if (helpers.getTaxLabel(acc, 'zh-CN', 'balRetainedEarnings') !== '留存收益') reasons.push(`${acc} balRetainedEarnings[zh-CN] should stay 留存收益`);
      if (helpers.getTaxLabel(acc, 'zh-CN', 'balRecvLabel') !== '客户应收') reasons.push(`${acc} balRecvLabel[zh-CN] should stay 客户应收`);
      if (helpers.getTaxLabel(acc, 'zh-CN', 'balEquityHeader') !== '所有者权益') reasons.push(`${acc} balEquityHeader[zh-CN] should stay 所有者权益`);
    }
    // reverse: CN keeps its own balance-sheet i18n (equity sub-header = 所有者权益)
    if (get(locales['zh-CN'], 'finance.balanceEquity') !== '所有者权益') reasons.push(`CN finance.balanceEquity should stay 所有者权益`);
    if (reasons.length) fail(`twFinanceBalanceWording`, reasons); else pass(`twFinanceBalanceWording`);
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
    // Categories page (会计类别) wording: friendly Slug header (分类代码) + 报表项目
    // (matching the 收支记录 page), plus US category display labels (gross-receipts /
    // utilities) rendered via getTaxLabel. zh only; en/ja/ko/fr untouched.
    {
      const cn = locales['zh-CN'], tw = locales['zh-TW'];
      const reasons = [];
      if (get(cn, 'settings.categories.slug') !== '分类代码') reasons.push(`categories.slug[zh-CN] should be 分类代码, got "${get(cn, 'settings.categories.slug')}"`);
      if (get(tw, 'settings.categories.slug') !== '分類代碼') reasons.push(`categories.slug[zh-TW] should be 分類代碼, got "${get(tw, 'settings.categories.slug')}"`);
      if (get(cn, 'settings.categories.scheduleLine') !== '报表项目') reasons.push(`categories.scheduleLine[zh-CN] should be 报表项目, got "${get(cn, 'settings.categories.scheduleLine')}"`);
      if (get(tw, 'settings.categories.scheduleLine') !== '報表項目') reasons.push(`categories.scheduleLine[zh-TW] should be 報表項目, got "${get(tw, 'settings.categories.scheduleLine')}"`);
      if (helpers.getTaxLabel('US', 'zh-CN', 'setCatGrossReceipts') !== '总收入 / 销售额') reasons.push(`US setCatGrossReceipts[zh-CN] should be 总收入 / 销售额, got "${helpers.getTaxLabel('US','zh-CN','setCatGrossReceipts')}"`);
      if (helpers.getTaxLabel('US', 'zh-TW', 'setCatGrossReceipts') !== '總收入 / 銷售額') reasons.push(`US setCatGrossReceipts[zh-TW] should be 總收入 / 銷售額, got "${helpers.getTaxLabel('US','zh-TW','setCatGrossReceipts')}"`);
      if (helpers.getTaxLabel('US', 'zh-CN', 'setCatUtilities') !== '水电及网络') reasons.push(`US setCatUtilities[zh-CN] should be 水电及网络, got "${helpers.getTaxLabel('US','zh-CN','setCatUtilities')}"`);
      if (helpers.getTaxLabel('US', 'zh-TW', 'setCatUtilities') !== '水電及網路') reasons.push(`US setCatUtilities[zh-TW] should be 水電及網路, got "${helpers.getTaxLabel('US','zh-TW','setCatUtilities')}"`);
      // systemNote must match the header wording (报表项目, not the old 报表行)
      if (!/官方报表项目/.test(get(cn, 'settings.categories.systemNote') || '') || /报表行/.test(get(cn, 'settings.categories.systemNote') || '')) reasons.push(`categories.systemNote[zh-CN] should say 官方报表项目 (not 报表行), got "${get(cn, 'settings.categories.systemNote')}"`);
      if (!/官方報表項目/.test(get(tw, 'settings.categories.systemNote') || '') || /報表行/.test(get(tw, 'settings.categories.systemNote') || '')) reasons.push(`categories.systemNote[zh-TW] should say 官方報表項目 (not 報表行), got "${get(tw, 'settings.categories.systemNote')}"`);
      if (reasons.length) fail(`categoriesWording`, reasons); else pass(`categoriesWording`);
    }
    // 采购与费用 / 销售与收入 (US) wording — expense/income-first + payee/quantity (zh only).
    {
      const reasons = [];
      const want = {
        'zh-CN': { newPurchaseButton: '新增支出', newSaleButton: '新增收入', modalTitlePurchase: '新增支出记录', modalSubtitlePurchase: '请手动输入支出明细', modalTitleSales: '新增收入记录', modalSubtitleSales: '请手动输入收入明细', setHeaderPayee: '收款方', setFormPayeeLabel: '收款方名称', setFormPayeePh: '请输入收款方名称', setFormCustomerPh: '请输入客户名称', setFormQtyLabel: '数量（可选）', setFormQtyPh: '例如：1' },
        'zh-TW': { newPurchaseButton: '新增支出', newSaleButton: '新增收入', modalTitlePurchase: '新增支出記錄', modalSubtitlePurchase: '請手動輸入支出明細', modalTitleSales: '新增收入記錄', modalSubtitleSales: '請手動輸入收入明細', setHeaderPayee: '收款方', setFormPayeeLabel: '收款方名稱', setFormPayeePh: '請輸入收款方名稱', setFormCustomerPh: '請輸入客戶名稱', setFormQtyLabel: '數量（可選）', setFormQtyPh: '例如：1' },
      };
      for (const lang of ['zh-CN', 'zh-TW']) {
        for (const [key, exp] of Object.entries(want[lang])) {
          const got = helpers.getTaxLabel('US', lang, key);
          if (got !== exp) reasons.push(`US ${key}[${lang}] should be "${exp}", got "${got}"`);
        }
        // upload-area subtitle uses 收款方 (page is expense-context), never 供应商
        const sub = helpers.getTaxLabel('US', lang, 'uploadSubtitle');
        if (/供应商|供應商/.test(sub) || !/收款方/.test(sub)) reasons.push(`US uploadSubtitle[${lang}] should say 收款方 (not 供应商): "${sub}"`);
      }
      if (reasons.length) fail(`usPurchaseSalesWording`, reasons); else pass(`usPurchaseSalesWording`);
    }
    // PART H: Products / service-items UI strings (Phase 1) — uiLanguage-only, regime-decoupled.
    //   Every locale carries the full products.* + settings.nav.products set; strings carry NO
    //   tax/regime wording (products UI must not vary by accountingLocale); unit picker resolves
    //   a real label for all 11 units × 6 langs.
    {
      const reasons = [];
      const PRODUCT_KEYS = [
        'products.title', 'products.subtitle', 'products.name', 'products.namePlaceholder',
        'products.unit', 'products.cost', 'products.type', 'products.product', 'products.service',
        'products.isService', 'products.status', 'products.active', 'products.inactive',
        'products.addButton', 'products.addTitle', 'products.empty', 'settings.nav.products',
        'products.selectLabel', 'products.unassigned',
        'inventory.inStockCount', 'inventory.totalCost', 'inventory.detailTitle',
        'inventory.colProduct', 'inventory.colQty', 'inventory.colCost',
      ];
      const TAX_WORDS = /增值税|增值稅|营业税|營業稅|消费税|消費稅|Sales Tax|进项|進項|销项|銷項|VAT|Schedule C/;
      for (const lang of UI_LANGUAGES) {
        const loc = locales[lang];
        for (const key of PRODUCT_KEYS) {
          const v = get(loc, key);
          if (v === undefined || v === null || v === '') reasons.push(`${lang}: ${key} missing/empty`);
          else if (TAX_WORDS.test(v)) reasons.push(`${lang}: ${key} must not carry tax/regime wording: "${v}"`);
        }
        for (const u of ['piece', 'box', 'bag', 'kg', 'ton', 'liter', 'bottle', 'pack', 'session', 'hour', 'month']) {
          if (!helpers.getProductUnitLabel(u, lang)) reasons.push(`${lang}: product unit "${u}" has no picker label`);
        }
      }
      if (reasons.length) fail(`productLabels`, reasons); else pass(`productLabels`);
    }

    // PART H2: Data backup / restore UI strings — uiLanguage-only, regime-decoupled.
    //   Every locale carries the full settings.dataBackup.* set + settings.nav.dataBackup;
    //   strings carry NO tax/regime wording (backup UI must not vary by accountingLocale).
    {
      const reasons = [];
      const BACKUP_KEYS = [
        'settings.nav.dataBackup',
        'settings.dataBackup.title', 'settings.dataBackup.subtitle',
        'settings.dataBackup.backupTitle', 'settings.dataBackup.backupHint',
        'settings.dataBackup.backupButton', 'settings.dataBackup.backupSuccess',
        'settings.dataBackup.restoreTitle', 'settings.dataBackup.restoreHint',
        'settings.dataBackup.restoreButton', 'settings.dataBackup.restoreWarning',
        'settings.dataBackup.restoreConfirm', 'settings.dataBackup.restoreSuccess',
        'settings.dataBackup.restartRequired', 'settings.dataBackup.restartNow',
        'settings.dataBackup.invalidFile', 'settings.dataBackup.newerVersion',
        'settings.dataBackup.autoBackupFailed', 'settings.dataBackup.desktopOnly',
        'settings.dataBackup.devModeRestart', 'settings.dataBackup.error',
      ];
      const TAX_WORDS = /增值税|增值稅|营业税|營業稅|消费税|消費稅|Sales Tax|进项|進項|销项|銷項|VAT|Schedule C/;
      for (const lang of UI_LANGUAGES) {
        const loc = locales[lang];
        for (const key of BACKUP_KEYS) {
          const v = get(loc, key);
          if (v === undefined || v === null || v === '') reasons.push(`${lang}: ${key} missing/empty`);
          else if (TAX_WORDS.test(v)) reasons.push(`${lang}: ${key} must not carry tax/regime wording: "${v}"`);
        }
      }
      if (reasons.length) fail(`dataBackupLabels`, reasons); else pass(`dataBackupLabels`);
    }

    // PART H3: Finance PDF-export UI strings — uiLanguage-only, regime-decoupled.
    //   Button + status + PDF header field labels; report name/口径 still come from
    //   getTaxLabel, so these strings carry NO tax/regime wording.
    {
      const reasons = [];
      const PDF_KEYS = [
        'finance.exportPdf', 'finance.pdfExported', 'finance.pdfDesktopOnly', 'finance.pdfFailed',
        'finance.pdfRegime', 'finance.pdfPeriod', 'finance.pdfCurrency', 'finance.pdfGeneratedAt',
      ];
      const TAX_WORDS = /增值税|增值稅|营业税|營業稅|消费税|消費稅|Sales Tax|进项|進項|销项|銷項|VAT|Schedule C/;
      for (const lang of UI_LANGUAGES) {
        const loc = locales[lang];
        for (const key of PDF_KEYS) {
          const v = get(loc, key);
          if (v === undefined || v === null || v === '') reasons.push(`${lang}: ${key} missing/empty`);
          else if (TAX_WORDS.test(v)) reasons.push(`${lang}: ${key} must not carry tax/regime wording: "${v}"`);
        }
      }
      if (reasons.length) fail(`financePdfLabels`, reasons); else pass(`financePdfLabels`);
    }

    // PART H4: Finance report TAB labels follow uiLanguage. Balance Sheet / Cash Flow are
    //   universal report types (regime-neutral) rendered via t('finance.tabBalance'|'tabCashflow');
    //   they must be present in all 6 langs AND must NOT stay the English fallback in non-en
    //   (the ja/ko/fr "Balance Sheet" / "Cash Flow" regression). P&L tab is regime-driven via
    //   getTaxLabel('tabPlLabel') and is checked elsewhere, not here.
    {
      const reasons = [];
      for (const lang of UI_LANGUAGES) {
        const loc = locales[lang];
        const bal = get(loc, 'finance.tabBalance');
        const cf = get(loc, 'finance.tabCashflow');
        if (!bal) reasons.push(`${lang}: finance.tabBalance missing/empty`);
        if (!cf) reasons.push(`${lang}: finance.tabCashflow missing/empty`);
        if (lang !== 'en') {
          if (bal === 'Balance Sheet') reasons.push(`${lang}: finance.tabBalance still English "Balance Sheet" (must follow UI language)`);
          if (cf === 'Cash Flow') reasons.push(`${lang}: finance.tabCashflow still English "Cash Flow" (must follow UI language)`);
        }
      }
      if (reasons.length) fail(`financeTabLabels`, reasons); else pass(`financeTabLabels`);
    }

    // PART H6: AI Assistant standalone page (R2a) nav + header labels — uiLanguage-only,
    //   regime-neutral (decoupled like nav.documents). nav.assistant / headerTitle.assistant
    //   must be present in all 6 langs, carry NO tax/regime wording, AND must NOT stay the
    //   English fallback in non-en (the same non-fallback lock financeTabLabels uses). The
    //   standalone page reuses the floating widget's ChatPanel, so its chat body strings are
    //   the already-locked chat.* set (REQUIRED_I18N_KEYS) — only the new nav/header keys here.
    {
      const reasons = [];
      const ASSIST_TAX_WORDS = /增值税|增值稅|营业税|營業稅|消费税|消費稅|Sales Tax|销售税|銷售稅|进项|進項|销项|銷項|統一發票|适格請求書|インボイス/;
      const ASSIST_KEYS = ['nav.assistant', 'headerTitle.assistant'];
      for (const lang of UI_LANGUAGES) {
        const loc = locales[lang];
        for (const key of ASSIST_KEYS) {
          const v = get(loc, key);
          if (v === undefined || v === null || v === '') { reasons.push(`${lang}: ${key} missing/empty`); continue; }
          if (ASSIST_TAX_WORDS.test(v)) reasons.push(`${lang}: ${key} must not carry tax/regime wording: "${v}"`);
          if (lang !== 'en' && v === get(locales['en'], key)) reasons.push(`${lang}: ${key} still English fallback "${v}" (must follow UI language)`);
        }
      }
      if (reasons.length) fail(`assistantNavLabels`, reasons); else pass(`assistantNavLabels`);
    }

    // PART H7: AI assistant read-only tool-trace labels (R2b-1) — uiLanguage-only, regime-neutral.
    //   The "已查询/Queried" trace title + per-tool labels render in the assistant chat after a
    //   tool-backed answer; they must be present in all 6 langs and carry NO tax/regime wording
    //   (the labels are generic business areas like 销售记录/库存, decoupled like nav.assistant).
    {
      const reasons = [];
      const TOOL_NAMES = ['get_dashboard','get_sales','get_purchases','get_transactions','get_inventory','get_products','get_receivables','get_payables','get_documents','get_alerts'];
      const KEYS = ['chat.toolTraceTitle', 'chat.toolTruncated', ...TOOL_NAMES.map(n => `chat.toolLabel.${n}`)];
      const TOOL_TAX_WORDS = /增值税|增值稅|营业税|營業稅|消费税|消費稅|Sales Tax|销售税|銷售稅|进项税|進項稅|销项税|銷項稅|統一發票|適格請求書|インボイス/;
      for (const lang of UI_LANGUAGES) {
        const loc = locales[lang];
        for (const key of KEYS) {
          const v = get(loc, key);
          if (v === undefined || v === null || v === '') reasons.push(`${lang}: ${key} missing/empty`);
          else if (TOOL_TAX_WORDS.test(v)) reasons.push(`${lang}: ${key} must not carry tax/regime wording: "${v}"`);
        }
      }
      if (reasons.length) fail(`assistantToolLabels`, reasons); else pass(`assistantToolLabels`);
    }

    // PART H5: Business documents UI strings (Phase A) — uiLanguage-only, regime-decoupled.
    //   Every locale carries the full documents.* set + nav/headerTitle entries; strings
    //   carry NO tax/regime wording (regime tax labels on the page come from getTaxLabel
    //   with the document's frozen acc_locale, never from these keys). Extra bans beyond
    //   the usual TAX_WORDS: 统一发票/統一發票 (CN forbidden word + official TW invoice
    //   claim), 適格請求書/インボイス (ja qualified-invoice claim), 数电票 (CN e-invoice
    //   claim) — the feature must never present itself as formal tax-invoice issuance.
    //   The 5 doc-type names must not stay the English fallback in non-en locales
    //   (financeTabLabels precedent).
    {
      const reasons = [];
      const DOC_KEYS = [
        'nav.documents', 'headerTitle.documents',
        'documents.title', 'documents.subtitle', 'documents.desktopOnly',
        'documents.addButton', 'documents.empty', 'documents.filterAll',
        'documents.typeQuotation', 'documents.typeSalesOrder', 'documents.typeProforma',
        'documents.typeCommercial', 'documents.typeStatement',
        'documents.colNumber', 'documents.colType', 'documents.colDate',
        'documents.colCustomer', 'documents.colTotal', 'documents.colStatus',
        'documents.statusDraft', 'documents.statusIssued', 'documents.statusVoid',
        'documents.markIssued', 'documents.voidAction', 'documents.voidConfirm',
        'documents.deleteConfirm', 'documents.numberConflict', 'documents.saveFailed',
        'documents.loadFailed', 'documents.itemsRequired',
        'documents.formTitle', 'documents.formEditTitle', 'documents.formType',
        'documents.formNumber', 'documents.formNumberHint', 'documents.formDate',
        'documents.formValidUntil', 'documents.formCustomer', 'documents.formCustomerPlaceholder',
        'documents.formCustomerTaxId', 'documents.formCustomerAddress', 'documents.formCustomerContact',
        'documents.formNotes', 'documents.itemsTitle', 'documents.itemDescription',
        'documents.itemQty', 'documents.itemUnit', 'documents.noUnit',
        'documents.itemUnitPrice', 'documents.itemAmount', 'documents.addItem',
        'documents.removeItem', 'documents.subtotal', 'documents.saveButton',
        'documents.exportPdf', 'documents.pdfExported', 'documents.pdfDesktopOnly',
        'documents.pdfFailed', 'documents.pdfGeneratedAt', 'documents.pdfDisclaimer',
        'documents.generateFromSale', 'documents.generatedOk', 'documents.stmtCustomer',
        'documents.stmtPeriodStart', 'documents.stmtPeriodEnd', 'documents.stmtGenerate',
        'documents.stmtNoRecords', 'documents.stmtNeedInput', 'documents.pdfPeriod',
        // Phase D: 正式税务发票关联（仅记录外部开具的发票；TAX_WORDS 禁词同时锁住
        // 统一发票/数电票/適格請求書/インボイス 等开票措辞，确保该功能永不自称开票）
        'documents.colTaxInvoice', 'documents.taxInvoiceAction', 'documents.taxInvoiceTitle',
        'documents.taxInvoiceIssuedLabel', 'documents.taxInvoiceNumberLabel', 'documents.taxInvoiceNumberHint',
        'documents.taxInvoiceDateLabel', 'documents.taxInvoiceAttachmentLabel',
        'documents.attachmentPick', 'documents.attachmentOpen', 'documents.attachmentRemove',
        'documents.attachmentMissing', 'documents.attachmentTooLarge', 'documents.attachmentFailed',
        'documents.attachmentInvalidType', 'documents.attachmentNotBackedUp', 'documents.taxInvoiceCompliance',
        'documents.taxInvoiceVoidReadOnly', 'documents.taxInvoiceYes', 'documents.taxInvoiceNo',
      ];
      const TAX_WORDS = /增值税|增值稅|营业税|營業稅|消费税|消費稅|Sales Tax|进项|進項|销项|銷項|VAT|Schedule C|统一发票|統一發票|適格請求書|インボイス|数电票|數電票/;
      const TYPE_EN = {
        'documents.typeQuotation': 'Quotation',
        'documents.typeSalesOrder': 'Sales Order',
        'documents.typeProforma': 'Proforma Invoice',
        'documents.typeCommercial': 'Commercial Invoice',
        'documents.typeStatement': 'Statement of Account',
      };
      for (const lang of UI_LANGUAGES) {
        const loc = locales[lang];
        for (const key of DOC_KEYS) {
          const v = get(loc, key);
          if (v === undefined || v === null || v === '') reasons.push(`${lang}: ${key} missing/empty`);
          else if (TAX_WORDS.test(v)) reasons.push(`${lang}: ${key} must not carry tax/regime or invoice-issuance wording: "${v}"`);
        }
        if (lang !== 'en') {
          for (const [key, en] of Object.entries(TYPE_EN)) {
            if (get(loc, key) === en) reasons.push(`${lang}: ${key} still English "${en}" (must follow UI language)`);
          }
        }
      }
      // pdfExported must keep the {{path}} token in every language — a success
      // banner without the saved path is a silent regression (G0j COUNT_KEYS precedent).
      for (const lang of UI_LANGUAGES) {
        const v = get(locales[lang], 'documents.pdfExported');
        if (v && !v.includes('{{path}}')) reasons.push(`${lang}: documents.pdfExported lost the {{path}} token`);
      }
      // The documents modal borrows regime keys via getTaxLabel with the document's
      // frozen acc_locale: formTaxRate must resolve for all 6 regimes, header* for
      // the 5 non-CN regimes (CN gates to tableHeaders.*). getTaxLabel returns the
      // bare key on a miss and the raw-key scanner can't see dot-less keys, so the
      // resolution is locked here (header* live only in NON_CN_GENERIC + US inline
      // and were previously matrix-required for US alone).
      for (const lang of UI_LANGUAGES) {
        for (const accId of ACCOUNTING_LOCALES) {
          if (helpers.getTaxLabel(accId, lang, 'formTaxRate') === 'formTaxRate') {
            reasons.push(`${accId}/${lang}: taxConcepts.formTaxRate unresolved (documents modal would leak the bare key)`);
          }
          if (accId !== 'CN') {
            for (const k of ['headerTaxAmount', 'headerTotalWithTax']) {
              if (helpers.getTaxLabel(accId, lang, k) === k) reasons.push(`${accId}/${lang}: taxConcepts.${k} unresolved (documents modal would leak the bare key)`);
            }
          }
        }
        for (const k of ['tableHeaders.taxAmount', 'tableHeaders.totalWithTax']) {
          if (!get(locales[lang], k)) reasons.push(`${lang}: ${k} missing (documents modal CN gate)`);
        }
      }
      if (reasons.length) fail(`documentLabels`, reasons); else pass(`documentLabels`);
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
      if (get(cn, 'invoices.totalInput') !== '累计进项数量') reasons.push(`CN invoices.totalInput should stay 累计进项数量 (进项 kept, no 吨), got "${get(cn, 'invoices.totalInput')}"`);
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
    // R3b: data-analysis forecast prompt prose (moved to i18n, follows uiLanguage) —
    //   (a) NO industry hardcode in any locale (软水盐 / soft water / brine);
    //   (b) non-en locale must not be a byte-identical untranslated English fallback.
    const FORECAST_PROMPT_KEYS = [
      'forecastPromptIntro', 'forecastPromptHistoryTitle', 'forecastPromptHistoryLegend',
      'forecastPromptFinTitle', 'forecastPromptFeaturesTitle', 'forecastPromptFeaturesLegend',
      'forecastPromptVarTitle', 'forecastPromptVarLegend',
      'forecastPromptMcTitle', 'forecastPromptMcLegend', 'forecastPromptRequirements',
    ];
    for (const key of FORECAST_PROMPT_KEYS) {
      const v = get(data, `analysis.${key}`);
      if (typeof v !== 'string') continue;
      if (/软水盐|軟水鹽|soft[\s-]?water|brine/i.test(v)) {
        reasons.push(`analysis.${key} hardcodes an industry (软水盐/soft water/brine) in ${lang}: "${v}"`);
      }
      if (lang !== 'en') {
        const enV = get(locales['en'], `analysis.${key}`);
        if (typeof enV === 'string' && v.trim() === enV.trim()) {
          reasons.push(`analysis.${key} is an untranslated English fallback in ${lang}`);
        }
      }
    }
    if (reasons.length) fail(`analysisWording:${lang}`, reasons); else pass(`analysisWording:${lang}`);
  }

  // ────────────────────────────────────────────────
  // PART G1.4: AI error codes (R3c) — aiError.* messages must be localized
  //   per uiLanguage. Presence/non-empty is covered by PART G (REQUIRED_I18N_KEYS);
  //   here we lock that non-en locales are NOT a byte-identical English fallback.
  // ────────────────────────────────────────────────
  {
    const AI_ERROR_KEYS = [
      'noProvider', 'auth', 'permission', 'quota', 'modelNotFound', 'badRequest',
      'serverError', 'parseFailed', 'network', 'timeout', 'unknown',
    ];
    for (const lang of UI_LANGUAGES) {
      if (lang === 'en') { pass(`aiErrorCodes:${lang}`); continue; }
      const reasons = [];
      for (const key of AI_ERROR_KEYS) {
        const v = get(locales[lang], `aiError.${key}`);
        const enV = get(locales['en'], `aiError.${key}`);
        if (typeof v === 'string' && typeof enV === 'string' && v.trim() === enV.trim()) {
          reasons.push(`aiError.${key} is an untranslated English fallback in ${lang}`);
        }
      }
      if (reasons.length) fail(`aiErrorCodes:${lang}`, reasons); else pass(`aiErrorCodes:${lang}`);
    }
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
    const sectionsToCheck = ['finance', 'tableHeaders', 'chat', 'purchases', 'sales', 'invoices', 'dashboard'];
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
  // PART G15: full 6×6 = 36-combination sweep (accountingLocale × uiLanguage).
  //   For every combo, resolve the tax-口径 labels via getTaxLabel and assert:
  //     (a) no cross-regime wording (per-accountingLocale forbidden list),
  //     (b) uiLanguage script integrity — zh-CN Simplified only / zh-TW Traditional only,
  //     (c) the regime summary title (taxTitle) carries the expected regime concept.
  //   accountingLocale decides 口径 (taxConcepts); uiLanguage decides script only.
  //   Failures print ui / acc / module / field / actual / forbidden / expected / file.
  // ────────────────────────────────────────────────
  {
    // Regime cross-contamination — what each accountingLocale must NEVER show, in any UI language.
    const FORBIDDEN_BY_LOCALE = {
      CN: ['营业税', '營業稅', '统一发票', '統一發票', 'Sales Tax', '消费税', '消費稅'],
      US: ['增值税', '增值稅', '营业税', '營業稅', '进项税额', '進項稅額', '销项税额', '銷項稅額', '消费税', '消費稅'],
      JP: ['增值税', '增值稅', '营业税', '營業稅', 'Sales Tax', '销售税', '銷售稅', '应交增值税', '應交增值稅'],
      EU: ['营业税', '營業稅', '消费税', '消費稅', 'Sales Tax', '销售税', '銷售稅', '已认证进项税额', '已認證進項稅額'],
      KR: ['营业税', '營業稅', '消费税', '消費稅', 'Sales Tax', '销售税', '銷售稅', '已认证进项税额', '已認證進項稅額'],
      TW: ['增值税', '增值稅', '应交增值税', '應交增值稅', '已认证', '已認證'],
    };
    // Variant-only characters (simplified-only / traditional-only; excludes chars common
    // to both scripts such as 售/支/持/收 — those are NOT leaks).
    const SIMP_ONLY = '务报单发资应进销项额总户营关转库类数据显实现产业会计帐账团价风财购费贵质软输边过还这远连选录钱错门问间队页题验证设论说请读谢识译试详语调谈课规视见觉访评诺贸贺贴赞跃较递邮钟铁银锁难韩顺颗颜饭饮馆骤东车书长岁两广严丰临为乌乐习乡买乱争亏阳';
    const TRAD_ONLY = '務報單發資應進銷項額總戶營關轉庫類數據顯實現產業會計帳賬團價風財購費貴質軟輸邊過還這遠連選錄錢錯門問間隊頁題驗證設論說請讀謝識譯試詳語調談課規視見覺訪評諾貿賀貼讚躍較遞郵鐘鐵銀鎖難韓順顆顏飯飲館驟東車書長歲兩廣嚴豐臨為烏樂習鄉買亂爭虧陽';
    // The regime concept that MUST appear in the summary title (taxTitle), in any language form.
    const CONCEPT_BY_LOCALE = {
      CN: /增值税|增值稅|増値税|VAT|TVA|부가가치세/,
      US: /Schedule C|Sales Tax|销售税|銷售稅|판매세|taxe de vente/i,
      JP: /消费税|消費稅|消費税|Consumption|소비세|consommation/i,
      EU: /VAT|TVA/,
      KR: /VAT|TVA|부가가치세/,
      TW: /营业税|營業稅|営業税|Business Tax|영업세|activité/i,
    };
    // Representative 口径-bearing fields rendered across the pages (raw/undefined keys skipped).
    const SWEEP_KEYS = [
      'taxTitle', 'inputTax', 'outputTax', 'certifiedInput', 'invoicedOutput', 'estimatedTax',
      'taxSummaryTitle', 'purchaseTotal', 'salesTotal', 'taxDifference',
      'invoiceInputLabel', 'invoiceOutputLabel', 'formTaxRate', 'plTitle', 'plRevenue', 'plNetProfit',
    ];
    for (const accId of ACCOUNTING_LOCALES) {
      for (const uiLang of UI_LANGUAGES) {
        const reasons = [];
        for (const key of SWEEP_KEYS) {
          const v = helpers.getTaxLabel(accId, uiLang, key);
          if (typeof v !== 'string' || v === key) continue; // key not defined for this locale → not rendered
          for (const w of FORBIDDEN_BY_LOCALE[accId]) {
            if (v.includes(w)) reasons.push(`module=TaxLabels field=${key} actual="${v}" forbidden="${w}" expected="${accId} 口径 wording" suggested=components/accountingLocaleConfig.ts`);
          }
          if (uiLang === 'zh-CN') {
            const bad = [...v].filter((c) => TRAD_ONLY.includes(c));
            if (bad.length) reasons.push(`module=TaxLabels field=${key} actual="${v}" forbidden="${[...new Set(bad)].join('')}"(繁体字) expected="Simplified Chinese" suggested=components/accountingLocaleConfig.ts`);
          }
          if (uiLang === 'zh-TW') {
            const bad = [...v].filter((c) => SIMP_ONLY.includes(c));
            if (bad.length) reasons.push(`module=TaxLabels field=${key} actual="${v}" forbidden="${[...new Set(bad)].join('')}"(简体字) expected="Traditional Chinese" suggested=components/accountingLocaleConfig.ts`);
          }
        }
        // regime concept must be present in the summary title
        const title = helpers.getTaxLabel(accId, uiLang, 'taxTitle');
        if (typeof title === 'string' && title !== 'taxTitle' && !CONCEPT_BY_LOCALE[accId].test(title)) {
          reasons.push(`module=TaxSummary field=taxTitle actual="${title}" forbidden="(missing concept)" expected="${accId} regime concept (${CONCEPT_BY_LOCALE[accId]})" suggested=components/accountingLocaleConfig.ts`);
        }
        if (reasons.length) fail(`matrix36:${accId}/${uiLang}`, reasons.map((r) => `[ui=${uiLang} acc=${accId}] ${r}`)); else pass(`matrix36:${accId}/${uiLang}`);
      }
    }
    // i18n script integrity over the whole tree (uiLanguage-only chrome: nav / dashboard /
    // settings / AI panel / page labels). zh-CN must be Simplified, zh-TW Traditional.
    const walkStrings = (obj, prefix, fn) => {
      if (obj && typeof obj === 'object') { for (const k of Object.keys(obj)) walkStrings(obj[k], prefix ? `${prefix}.${k}` : k, fn); }
      else if (typeof obj === 'string') fn(prefix, obj);
    };
    // Word-level variant bans catch regional word choices the char sweep misses
    // (e.g. 支持/支援 — both made of common chars). Mirrors the page-level E2E lists.
    const ZH_CN_BAN_WORDS = ['資料', '採購', '銷售', '進項', '銷項', '簡報', '支援', '統計', '應納', '營業'];
    const ZH_TW_BAN_WORDS = ['资料', '采购', '销售', '进项', '销项', '简报', '支持', '统计', '应纳', '营业'];
    {
      const reasons = [];
      walkStrings(locales['zh-CN'], '', (path, v) => {
        const bad = [...v].filter((c) => TRAD_ONLY.includes(c));
        if (bad.length) reasons.push(`module=i18n field=${path} actual="${v.slice(0, 40)}" forbidden="${[...new Set(bad)].join('')}"(繁体字) expected="Simplified Chinese" suggested=i18n/locales/zh-CN.json`);
        for (const w of ZH_CN_BAN_WORDS) if (v.includes(w)) reasons.push(`module=i18n field=${path} actual="${v.slice(0, 40)}" forbidden="${w}"(繁体词) expected="Simplified Chinese" suggested=i18n/locales/zh-CN.json`);
      });
      if (reasons.length) fail(`i18nScript:zh-CN`, reasons); else pass(`i18nScript:zh-CN`);
    }
    {
      const reasons = [];
      walkStrings(locales['zh-TW'], '', (path, v) => {
        const bad = [...v].filter((c) => SIMP_ONLY.includes(c));
        if (bad.length) reasons.push(`module=i18n field=${path} actual="${v.slice(0, 40)}" forbidden="${[...new Set(bad)].join('')}"(简体字) expected="Traditional Chinese" suggested=i18n/locales/zh-TW.json`);
        for (const w of ZH_TW_BAN_WORDS) if (v.includes(w)) reasons.push(`module=i18n field=${path} actual="${v.slice(0, 40)}" forbidden="${w}"(简体词) expected="Traditional Chinese" suggested=i18n/locales/zh-TW.json`);
      });
      if (reasons.length) fail(`i18nScript:zh-TW`, reasons); else pass(`i18nScript:zh-TW`);
    }
  }

  // ────────────────────────────────────────────────
  // PART G16: System Settings notification wording — tax-deviation term.
  //   The 系统设置 tax-deviation toggle (settings.notifications.taxDeviation, the
  //   i18n shown under CN accountingLocale) must use the concrete 税款 (tax due),
  //   matching the canonical notifTaxDeviation taxConcept — never the macro 税收
  //   (government tax revenue), which would mismatch the actual alert wording.
  // ────────────────────────────────────────────────
  {
    const reasons = [];
    for (const lang of ['zh-CN', 'zh-TW']) {
      const v = get(locales[lang], 'settings.notifications.taxDeviation');
      if (typeof v === 'string') {
        if (/税收|稅收/.test(v)) reasons.push(`${lang} settings.notifications.taxDeviation uses macro 税收 (should be 税款), got "${v}"`);
        if (!/税款|稅款/.test(v)) reasons.push(`${lang} settings.notifications.taxDeviation should use 税款/稅款, got "${v}"`);
      }
    }
    if (reasons.length) fail(`settingsTaxDeviationWording`, reasons); else pass(`settingsTaxDeviationWording`);
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
