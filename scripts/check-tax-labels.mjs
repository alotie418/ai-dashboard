#!/usr/bin/env node
// Tax-label guard (PR-E3): user-visible tax-amount labels must read as management
// estimates — NOT as formal tax filing / certification / statutory liability. Scans the
// de-escalated keys only and bans the over-claiming wording.
//
// Scope (scanned): taxConcepts estimatedTax / invoicePendingTax / certifiedInput /
// invoicedOutput (all locales) + the CN invoice-query / settings auto-process i18n labels.
// Out of scope (NOT scanned): balTaxPayLabel & finance.balanceTax (balance-sheet account →
// PR-E4), invoices.statusDeducted (已抵扣, not in this PR), disclaimers / ai.boundaryDirective
// (intentional "consult a tax professional" wording). scripts/ is excluded by other guards.

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = join(__dirname, '..');
const LOCALES = ['zh-CN', 'zh-TW', 'en', 'ja', 'ko', 'fr'];

// Over-claiming wording the de-escalated tax labels must not contain.
const BANNED = [
  /申报/, /申報/, /报税/, /報稅/, /认证/, /認證/,
  /已开票/, /已開票/, /可抵扣/,
  /\bFiling\b/i, /\bCertified\b/i, /Invoiced (?:Input|Output)/i, /\bDeductible\b/i, /Auto-certify/i,
  /应交/, /應交/, /应缴/, /應繳/, /\bPayable\b/i,
  /同步.{0,4}税务系统/, /同步.{0,4}稅務系統/, /sync to tax system/i,
];

const TAXCONCEPT_KEYS = ['estimatedTax', 'invoicePendingTax', 'certifiedInput', 'invoicedOutput'];
const I18N_KEYS = [
  'invoices.pendingTax', 'invoices.statusCertified', 'invoices.statusPendingCert', 'invoices.deductible',
  'invoices.statusAuthenticated', 'invoices.statusUnauthenticated', 'invoices.authenticated',
  'settings.tax.autoAuth', 'settings.tax.autoAuthDesc',
  'dashboard.vatInputCertified', 'dashboard.vatOutputInvoiced', 'dashboard.vatEstimated',
];

const findings = [];
const get = (o, p) => p.split('.').reduce((a, k) => (a == null ? undefined : a[k]), o);
const scan = (where, text) => { for (const re of BANNED) { const m = text.match(re); if (m) findings.push(`${where}: banned "${m[0]}"`); } };

// taxConcepts: scan only the value side of each key's line (skip the key name).
const cfgLines = readFileSync(join(ROOT, 'components/accountingLocaleConfig.ts'), 'utf8').split('\n');
let tcCount = 0;
for (const line of cfgLines) {
  for (const k of TAXCONCEPT_KEYS) {
    const m = line.match(new RegExp(`^\\s*${k}:\\s*(\\{.*)$`));
    if (m) { tcCount++; scan(`accountingLocaleConfig ${k}`, m[1]); }
  }
}

// i18n keys: scan the string value.
for (const l of LOCALES) {
  const obj = JSON.parse(readFileSync(join(ROOT, 'i18n/locales', `${l}.json`), 'utf8'));
  for (const k of I18N_KEYS) { const v = get(obj, k); if (typeof v === 'string') scan(`${l}.json ${k}`, v); }
}

console.log('=== Tax-Label Guard (no filing / certification / statutory-liability wording) ===\n');
console.log(`Scanned: ${tcCount} taxConcept label lines + ${I18N_KEYS.length}×${LOCALES.length} i18n labels`);
console.log(`Findings: ${findings.length}\n`);

if (findings.length) {
  for (const f of findings) console.error(`  ✗ ${f}`);
  console.error('\n❌ Tax labels must read as management estimates, not formal filing / certification / statutory liability.');
  process.exit(1);
}

console.log('✓ No filing / certification / statutory-liability wording in the de-escalated tax labels.');
