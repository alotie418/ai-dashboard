#!/usr/bin/env node
// English-placeholder regression guard (UI-05A).
//
// The Purchase / Sales main-page labels existed in every locale file but their
// ja/ko/fr values were English copies (value === en value), so a CN-accounting
// + ja/ko/fr UI rendered English. check:i18n-keys cannot catch this (the keys
// exist and are non-empty); only a value-vs-en comparison does.
//
// Scope: this guard ONLY pins the keys fixed in UI-05A. It deliberately does
// NOT scan the whole app (ja/ko/fr still carry ~300 untranslated placeholders
// elsewhere — a separate, larger effort). It just locks THIS fix from
// regressing.
//
// Rules:
//   - ja / ko: every pinned key MUST differ from the en value (CJK/Hangul never
//     legitimately equals English here).
//   - fr: every pinned key MUST differ from en, EXCEPT the documented
//     French/English cognates in FR_ALLOW_EQ_EN (Date, Total) which are correct
//     French as-is.

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const load = (l) => JSON.parse(readFileSync(join(ROOT, 'i18n/locales', `${l}.json`), 'utf8'));
const en = load('en'), ja = load('ja'), ko = load('ko'), fr = load('fr');
const get = (o, k) => k.split('.').reduce((a, c) => (a && typeof a === 'object' ? a[c] : undefined), o);

// The 71 keys corrected in UI-05A (purchase / sales main page + shared common2).
const PINNED = [
  'common2.delete', 'common2.edit', 'common2.optional',
  'purchases.title', 'purchases.batchImport', 'purchases.scanInvoice', 'purchases.newPurchase',
  'purchases.scanning', 'purchases.recognitionMode', 'purchases.modeAi', 'purchases.modeOcr',
  'purchases.aiStatus', 'purchases.uploadTitle', 'purchases.uploadSubtitle', 'purchases.uploadScanning',
  'purchases.uploadAnalyzing', 'purchases.empty', 'purchases.summary', 'purchases.loading',
  'purchases.modalTitle', 'purchases.modalSubtitle', 'purchases.errorDeleteFailed', 'purchases.errorFailed',
  'purchases.errorRequiredFields', 'purchases.errorSaveFailed', 'purchases.formCancel', 'purchases.formDate',
  'purchases.formInvoiceNo', 'purchases.formQuantity', 'purchases.formSubmit', 'purchases.formSupplier',
  'purchases.formSupplierPlaceholder', 'purchases.formTaxAmount', 'purchases.taxStandard', 'purchases.taxTransport',
  'purchases.taxService', 'purchases.taxSmall',
  'sales.title', 'sales.batchImport', 'sales.scanInvoice', 'sales.newSale', 'sales.scanning',
  'sales.recognitionMode', 'sales.modeAi', 'sales.modeOcr', 'sales.aiStatus', 'sales.uploadTitle',
  'sales.uploadSubtitle', 'sales.uploadAnalyzing', 'sales.empty', 'sales.summary', 'sales.loading',
  'sales.modalTitle', 'sales.modalSubtitle', 'sales.modalTitleEdit', 'sales.modalSubtitleEdit',
  'sales.formCancel', 'sales.formCustomer', 'sales.formCustomerPlaceholder', 'sales.formDate',
  'sales.formInvoiceNo', 'sales.formQuantity', 'sales.formShipping', 'sales.formSubmitEdit',
  'sales.formSubmitNew', 'sales.formTaxAmount', 'sales.inventoryCurrent', 'sales.inventoryLow',
  'sales.inventorySufficient', 'sales.inventoryTotalPurchase', 'sales.inventoryTotalSales',
];

// fr keys that are legitimately identical to en (cognates) — allowed to equal en.
const FR_ALLOW_EQ_EN = new Set([
  'purchases.formDate', 'sales.formDate',   // "Date"
  'purchases.summary', 'sales.summary',     // "Total"
]);

const dicts = { ja, ko, fr };
const violations = [];
for (const key of PINNED) {
  const e = get(en, key);
  for (const l of ['ja', 'ko', 'fr']) {
    const v = get(dicts[l], key);
    if (v === undefined || (typeof v === 'string' && v.trim() === '')) {
      violations.push(`${l}: ${key} — MISSING/empty`);
      continue;
    }
    if (v === e) {
      if (l === 'fr' && FR_ALLOW_EQ_EN.has(key)) continue; // documented cognate
      violations.push(`${l}: ${key} — still equals en ("${e}") → English placeholder`);
    }
  }
}

console.log('\n=== i18n English-placeholder Guard (UI-05A pinned keys) ===\n');
console.log(`Pinned keys      : ${PINNED.length} (purchase/sales main page + common2)`);
console.log(`Checked locales  : ja, ko, fr (vs en)`);
console.log(`fr cognate allows: ${[...FR_ALLOW_EQ_EN].join(', ')}`);
console.log(`Violations       : ${violations.length}\n`);

if (violations.length === 0) {
  console.log('✓ No English placeholders among the UI-05A pinned keys.');
  process.exit(0);
}
for (const v of violations) console.log('  ✗ ' + v);
console.log('');
process.exit(1);
