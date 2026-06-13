#!/usr/bin/env node
// Report-title guard (PR-E4): financial report titles must read as management views, not
// statutory financial statements / tax-filing forms.
//   - P&L title / tab + Balance / Cash Flow tab titles must NOT be the bare statutory
//     statement names (利润表 / 损益表 / 资产负债表 / 现金流量表 / Income Statement /
//     Balance Sheet / Cash Flow Statement / Profit & Loss Statement, etc.).
//   - the tax-payable line (balTaxPayLabel / finance.balanceTaxPayable) must carry an
//     estimate marker (估算 / Estimated / 推定 / 추정 / estimé).
//   - the tax-inclusive summary title must not imply filing (申报 / Filing).
//
// "Schedule C" is allowed as a *basis* reference in US titles (E1 already disclaims it as
// an estimate, not a filing). P&L LINE items (营业收入/营业成本/毛利/净利润) and asset/equity
// line labels are out of scope. scripts/ is excluded by the other guards.

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = join(__dirname, '..');
const LOCALES = ['zh-CN', 'zh-TW', 'en', 'ja', 'ko', 'fr'];

const STMT_NAMES = [
  /利润表/, /利潤表/, /损益表/, /損益表/,
  /资产负债表/, /資產負債表/, /貸借対照表/, /재무상태표/,
  /现金流量表/, /現金流量表/,
  /Income Statement/i, /Balance Sheet/i, /Cash Flow Statement/i,
  /Profit\s*&?\s*Loss\s+Statement/i, /Profit and Loss Statement/i,
];
const ESTIMATE = /估算|Estimated|推定|추정|estimé/i;
const FILING = /申报|申報|报税|報稅|Filing/i;

const TITLE_TC = ['plTitle', 'tabPlLabel'];          // taxConcepts (ban statement names)
const TITLE_I18N = ['finance.tabBalance', 'finance.tabCashflow'];
const TAXPAY_TC = ['balTaxPayLabel'];                 // require estimate marker
const TAXPAY_I18N = ['finance.balanceTaxPayable', 'finance.balanceTax'];
const SUMMARY_TC = ['taxSummaryTitle'];               // ban filing

const findings = [];
const get = (o, p) => p.split('.').reduce((a, k) => (a == null ? undefined : a[k]), o);

// accountingLocaleConfig taxConcepts (line-based; scan the value side)
let tcCount = 0;
for (const line of readFileSync(join(ROOT, 'components/accountingLocaleConfig.ts'), 'utf8').split('\n')) {
  for (const k of TITLE_TC) {
    const m = line.match(new RegExp(`^\\s*${k}:\\s*(\\{.*)$`));
    if (m) { tcCount++; for (const re of STMT_NAMES) { const h = m[1].match(re); if (h) findings.push(`accountingLocaleConfig ${k}: statutory name "${h[0]}"`); } }
  }
  for (const k of TAXPAY_TC) {
    const m = line.match(new RegExp(`^\\s*${k}:\\s*(\\{.*)$`));
    if (m) { tcCount++; if (!ESTIMATE.test(m[1])) findings.push(`accountingLocaleConfig ${k}: missing estimate marker`); }
  }
  for (const k of SUMMARY_TC) {
    const m = line.match(new RegExp(`^\\s*${k}:\\s*(\\{.*)$`));
    if (m) { tcCount++; const h = m[1].match(FILING); if (h) findings.push(`accountingLocaleConfig ${k}: filing wording "${h[0]}"`); }
  }
}

// i18n
for (const l of LOCALES) {
  const obj = JSON.parse(readFileSync(join(ROOT, 'i18n/locales', `${l}.json`), 'utf8'));
  for (const k of TITLE_I18N) { const v = get(obj, k); if (typeof v === 'string') for (const re of STMT_NAMES) { const h = v.match(re); if (h) findings.push(`${l}.json ${k}: statutory name "${h[0]}"`); } }
  for (const k of TAXPAY_I18N) { const v = get(obj, k); if (typeof v === 'string' && !ESTIMATE.test(v)) findings.push(`${l}.json ${k}: missing estimate marker ("${v}")`); }
}

console.log('=== Report-Title Guard (management views, not statutory statements) ===\n');
console.log(`Scanned: ${tcCount} taxConcept title lines + i18n finance titles × ${LOCALES.length}`);
console.log(`Findings: ${findings.length}\n`);

if (findings.length) {
  for (const f of findings) console.error(`  ✗ ${f}`);
  console.error('\n❌ Report titles must read as management views (经营损益概览 / 经营资产概览), not statutory statements; the tax-payable line must be marked as an estimate.');
  process.exit(1);
}

console.log('✓ Report titles are management views; tax-payable is estimate-marked; no filing wording.');
