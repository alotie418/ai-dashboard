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
  // UI-05B: remaining hardcoded-string cleanup (DataAnalysisPage / USDashboardCards / App.tsx).
  'usDashboard.scMeals', 'usDashboard.scCarTruck', 'usDashboard.scOffice', 'usDashboard.mileageTrips',
  'header.refreshData',
  // UI-05B (follow-up): DataAnalysisPage analysis.* labels (tabs / chart titles / series / metrics / table).
  'analysis.panorama', 'analysis.trends', 'analysis.table',
  'analysis.revenueStructure', 'analysis.growthTrend', 'analysis.logistics', 'analysis.efficiency',
  'analysis.deflator', 'analysis.chartRevenue', 'analysis.chartProfit', 'analysis.chartPurchase',
  'analysis.chartSales', 'analysis.chartMom', 'analysis.chartYoy', 'analysis.dimSwitch',
  'analysis.dimAmount', 'analysis.dimVolume', 'analysis.dimEfficiency', 'analysis.trendFinancial',
  'analysis.trendVolume', 'analysis.trendEfficiency', 'analysis.trendSubtitle', 'analysis.matrixTitle',
  'analysis.matrixSubtitle', 'analysis.anomalyTitle', 'analysis.anomalyHigh', 'analysis.anomalyMid',
  'analysis.anomalyLow', 'analysis.peakMonth', 'analysis.fastest', 'analysis.fastestSub',
  'analysis.tableMonth', 'analysis.tableExport',
  'analysis.tableExportFilename', 'analysis.tableHeaderMom', 'analysis.tableHeaderYoy',
];

// fr keys that are legitimately identical to en (cognates) — allowed to equal en.
const FR_ALLOW_EQ_EN = new Set([
  'purchases.formDate', 'sales.formDate',   // "Date"
  'purchases.summary', 'sales.summary',     // "Total"
  // DataAnalysisPage cognates / international finance abbreviations kept in fr.
  'analysis.chartMom', 'analysis.chartYoy',           // "MoM" / "YoY"
  'analysis.tableHeaderMom', 'analysis.tableHeaderYoy', // "MoM" / "YoY"
  'analysis.dimVolume',                                // "Volume"
  'analysis.dimSwitch',                                // "Dimension"
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

console.log('\n=== i18n English-placeholder Guard (pinned keys) ===\n');
console.log(`Pinned keys      : ${PINNED.length} (UI-05A purchase/sales + common2; UI-05B analysis/usDashboard/header)`);
console.log(`Checked locales  : ja, ko, fr (vs en)`);
console.log(`fr cognate allows: ${[...FR_ALLOW_EQ_EN].join(', ')}`);
console.log(`Violations       : ${violations.length}\n`);

if (violations.length === 0) {
  console.log('✓ No English placeholders among the pinned keys.');
  process.exit(0);
}
for (const v of violations) console.log('  ✗ ' + v);
console.log('');
process.exit(1);
