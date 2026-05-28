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
const REQUIRED_TAX_KEYS_BY_LOCALE = {
  CN: ['taxTitle', 'inputTax', 'outputTax', 'estimatedTax', 'certifiedInput', 'invoicedOutput', 'plRevenue', 'plCost', 'plNetProfit', 'taxSummaryTitle', 'purchaseTotal', 'salesTotal', 'taxDifference', 'invoiceTypeOutput', 'invoiceTypeInput'],
  EU: ['taxTitle', 'inputTax', 'outputTax', 'estimatedTax', 'certifiedInput', 'invoicedOutput', 'plRevenue', 'plCost', 'plNetProfit', 'taxSummaryTitle', 'purchaseTotal', 'salesTotal', 'taxDifference', 'invoiceTypeOutput', 'invoiceTypeInput'],
  JP: ['taxTitle', 'inputTax', 'outputTax', 'estimatedTax', 'certifiedInput', 'invoicedOutput', 'plRevenue', 'plCost', 'plNetProfit', 'taxSummaryTitle', 'purchaseTotal', 'salesTotal', 'taxDifference', 'invoiceTypeOutput', 'invoiceTypeInput'],
  KR: ['taxTitle', 'inputTax', 'outputTax', 'estimatedTax', 'certifiedInput', 'invoicedOutput', 'plRevenue', 'plCost', 'plNetProfit', 'taxSummaryTitle', 'purchaseTotal', 'salesTotal', 'taxDifference', 'invoiceTypeOutput', 'invoiceTypeInput'],
  TW: ['taxTitle', 'inputTax', 'outputTax', 'estimatedTax', 'certifiedInput', 'invoicedOutput', 'plRevenue', 'plCost', 'plNetProfit', 'taxSummaryTitle', 'purchaseTotal', 'salesTotal', 'taxDifference', 'invoiceTypeOutput', 'invoiceTypeInput'],
  US: ['taxTitle', 'grossReceipts', 'totalExpenses', 'netProfit', 'plRevenue', 'plCost', 'plNetProfit', 'taxSummaryTitle', 'purchaseTotal', 'salesTotal', 'taxDifference', 'invoiceTypeOutput', 'invoiceTypeInput'],
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
