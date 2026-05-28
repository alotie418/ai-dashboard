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
  JP: [...COMMON_TAX_KEYS, ...VAT_FAMILY_KEYS],
  KR: [...COMMON_TAX_KEYS, ...VAT_FAMILY_KEYS],
  TW: [...COMMON_TAX_KEYS, ...VAT_FAMILY_KEYS],
  US: [...COMMON_TAX_KEYS, 'grossReceipts', 'totalExpenses', 'netProfit', 'taxTitle', 'kpiGrossIncome', 'kpiQuarterlyTax',
    'profitMargins', 'grossMargin', 'netMargin',
    'socialSecurity', 'medicare', 'additionalMedicare', 'dueLabel',
    'pageTitlePurchase', 'uploadTitle', 'uploadSubtitle',
    'headerUnitPrice', 'headerAmount', 'headerTaxAmount',
    'headerTotalWithTax', 'headerInvoiceNo'],
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
                           'headerTotalWithTax', 'headerInvoiceNo']) {
          const label = helpers.getTaxLabel(accId, uiLang, key);
          for (const pattern of US_FORBIDDEN_CN_TERMS) {
            if (pattern.test(label)) {
              reasons.push(`US ${key}[${uiLang}] uses China-VAT term ${pattern}: "${label}"`);
            }
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
